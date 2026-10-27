//! The primitives of `(scheme inexact)` (R7RS 6.2.6): `finite?` `infinite?` `nan?`, `exp` `log`,
//! `sin` `cos` `tan` `asin` `acos` `atan`, and `sqrt`.
//!
//! 計算は `f64` で行い、結果は flonum である。例外は、正確な引数の特別な点(`(exp 0)` など)と、
//! 正確な平方数の `sqrt` で、結果は正確な数になる。複素数の引数は `WrongType` にする(複素数の
//! `sqrt` `exp` `log` などは、スライス 4i が置き換える)。実数の引数で結果が実数にならない
//! 場合は、`sqrt` と `log` が複素数を返し、`asin` と `acos` は `OutOfRange` にする。
//! 引数の型は、値によらず、すべての引数について先に検査する(`arith.zig` の方針)。

const std = @import("std");
const value = @import("../value.zig");
const Value = value.Value;
const Primitive = value.Primitive;
const Services = value.Services;
const PrimitiveError = value.PrimitiveError;
const heap_mod = @import("../heap.zig");
const Heap = heap_mod.Heap;
const number = @import("../num/number.zig");
const ops = @import("../num/ops.zig");
const power = @import("../num/power.zig");

pub const Error = PrimitiveError;

pub const primitives = [_]Primitive{
    .{ .name = "finite?", .min_args = 1, .max_args = 1, .body = .{ .pure = classify(.finite) } },
    .{ .name = "infinite?", .min_args = 1, .max_args = 1, .body = .{ .pure = classify(.infinite) } },
    .{ .name = "nan?", .min_args = 1, .max_args = 1, .body = .{ .pure = classify(.nan) } },
    .{ .name = "exp", .min_args = 1, .max_args = 1, .body = .{ .pure = unary(expF64, .{ 0, 1 }) } },
    .{ .name = "log", .min_args = 1, .max_args = 2, .body = .{ .pure = &logOf } },
    .{ .name = "sin", .min_args = 1, .max_args = 1, .body = .{ .pure = unary(sinF64, .{ 0, 0 }) } },
    .{ .name = "cos", .min_args = 1, .max_args = 1, .body = .{ .pure = unary(cosF64, .{ 0, 1 }) } },
    .{ .name = "tan", .min_args = 1, .max_args = 1, .body = .{ .pure = unary(tanF64, .{ 0, 0 }) } },
    .{ .name = "asin", .min_args = 1, .max_args = 1, .body = .{ .pure = unary(asinF64, .{ 0, 0 }) } },
    .{ .name = "acos", .min_args = 1, .max_args = 1, .body = .{ .pure = unary(acosF64, .{ 1, 0 }) } },
    .{ .name = "atan", .min_args = 1, .max_args = 2, .body = .{ .pure = &atanOf } },
    .{ .name = "sqrt", .min_args = 1, .max_args = 1, .body = .{ .pure = &sqrtOf } },
};

fn expF64(x: f64) f64 {
    return @exp(x);
}
fn sinF64(x: f64) f64 {
    return @sin(x);
}
fn cosF64(x: f64) f64 {
    return @cos(x);
}
fn tanF64(x: f64) f64 {
    return @tan(x);
}
fn asinF64(x: f64) f64 {
    return std.math.asin(x);
}
fn acosF64(x: f64) f64 {
    return std.math.acos(x);
}

const Class = enum { finite, infinite, nan };

/// `(finite? z)`, `(infinite? z)` and `(nan? z)`: `z` is a number (R7RS 6.2.6).
///
/// 複素数は、`finite?` が両方の部分が有限のとき真、`infinite?` が少なくとも一方が無限大のとき真、
/// `nan?` が少なくとも一方が NaN のとき真である。正確な数は有限である。
fn classify(comptime class: Class) Primitive.Fn {
    return &struct {
        fn call(_: *const Services, args: []const Value) Error!Value {
            const v = args[0];
            if (!number.isNumber(v)) return error.WrongType;
            if (v.asCompnum()) |c| {
                const re = partClass(class, c.real);
                const im = partClass(class, c.imag);
                return .fromBool(if (class == .finite) re and im else re or im);
            }
            return .fromBool(partClass(class, v));
        }
    }.call;
}

/// Whether the real number `v` is of `class`. An exact number is finite.
fn partClass(class: Class, v: Value) bool {
    const x = v.asFlonum() orelse return class == .finite;
    return switch (class) {
        .finite => std.math.isFinite(x),
        .infinite => std.math.isInf(x),
        .nan => std.math.isNan(x),
    };
}

/// The `f64` nearest to the real number `v`.
fn flonumOf(h: *Heap, v: Value) Error!f64 {
    if (v.asFlonum()) |x| return x;
    if (v.asFixnum()) |n| return @floatFromInt(n);
    return ops.counted(f64, flonumWork, h, .{v});
}

fn flonumWork(_: *Heap, gpa: std.mem.Allocator, v: Value) number.Error!f64 {
    return number.toFlonum(gpa, v);
}

/// Checks every argument is a real number, before anything is computed.
fn requireReals(args: []const Value) Error!void {
    for (args) |a| if (!ops.isRealNumber(a)) return error.WrongType;
}

/// `f` of a real number. `special` is the exact argument whose result is exact, and that result
/// (`(exp 0)` is 1, `(acos 1)` is 0): the other exact arguments give a flonum.
fn unary(comptime f: fn (f64) f64, comptime special: [2]i64) Primitive.Fn {
    return &struct {
        fn call(services: *const Services, args: []const Value) Error!Value {
            try requireReals(args);
            if (args[0].asFixnum()) |n| if (n == special[0]) return .fromFixnum(special[1]);
            const x = try flonumOf(services.heap, args[0]);
            // asin と acos の定義域は [-1, 1] である。外では結果が複素数になる(スライス 4i が扱う)。
            if (f == asinF64 or f == acosF64) if (@abs(x) > 1.0) return error.OutOfRange;
            return .fromFlonum(f(x));
        }
    }.call;
}

/// Whether the real number `v` is below zero. `-0.0` is not.
fn isNegative(h: *Heap, v: Value) Error!bool {
    if (v.asFlonum()) |x| return x < 0;
    return (try ops.compare(h, v, .fromFixnum(0))).? == .lt;
}

fn makeRectangularWork(h: *Heap, gpa: std.mem.Allocator, re: Value, im: Value) number.Error!Value {
    return number.makeRectangular(h, gpa, re, im);
}

/// `(log z)` and `(log z1 z2)`: the natural logarithm, and the logarithm of `z1` to the base `z2`.
///
/// 負の実数の自然対数は `log |x| + pi i` の複素数である(`(log -1)` は `0.0+3.141592653589793i`)。
/// 2引数は、2つの自然対数の商を、`f64` で計算する。2引数の負の実数は `OutOfRange` にする
/// (複素数の商は、スライス 4i が扱う)。`f64` に収まらない正確な数の対数は、無限大になる。
fn logOf(services: *const Services, args: []const Value) Error!Value {
    try requireReals(args);
    const h = services.heap;
    if (args.len == 2) {
        if (try isNegative(h, args[0]) or try isNegative(h, args[1])) return error.OutOfRange;
        const x = try flonumOf(h, args[0]);
        const base = try flonumOf(h, args[1]);
        return .fromFlonum(@log(x) / @log(base));
    }
    const v = args[0];
    if (v.asFixnum()) |n| if (n == 1) return .fromFixnum(0);
    if (!try isNegative(h, v)) return .fromFlonum(@log(try flonumOf(h, v)));
    const magnitude = @log(-(try flonumOf(h, v)));
    return ops.counted(Value, makeRectangularWork, h, .{ Value.fromFlonum(magnitude), Value.fromFlonum(std.math.pi) });
}

/// `(atan z)` and `(atan y x)`: the angle of the point `(x, y)`, in radians (R7RS 6.2.6).
///
/// 2引数の `(atan 0 x)` は、`x` が正確な正の数なら正確な 0 である。両方が正確な 0 なら、
/// 原文が角を定めないので `OutOfRange` にする。
fn atanOf(services: *const Services, args: []const Value) Error!Value {
    try requireReals(args);
    const h = services.heap;
    if (args.len == 1) {
        if (args[0].asFixnum()) |n| if (n == 0) return .fromFixnum(0);
        return .fromFlonum(std.math.atan(try flonumOf(h, args[0])));
    }
    if (args[0].asFixnum()) |y| if (y == 0 and ops.isExact(args[1])) {
        if (args[1].asFixnum()) |x| if (x == 0) return error.OutOfRange;
        if (!try isNegative(h, args[1])) return .fromFixnum(0);
    };
    const y = try flonumOf(h, args[0]);
    const x = try flonumOf(h, args[1]);
    return .fromFlonum(std.math.atan2(y, x));
}

/// `(sqrt z)`: the principal square root of a real number.
///
/// 正確な平方数(整数と、分子と分母がどちらも平方数の有理数)は、正確な根を返す。それ以外は
/// flonum である。負の数は `i` 倍の複素数になる(`(sqrt -4)` は `+2i`、`(sqrt -2)` は
/// `0.0+1.4142135623730951i`)。`f64` に収まらない平方数でない整数は、根を整数の平方根で求める。
fn sqrtOf(services: *const Services, args: []const Value) Error!Value {
    try requireReals(args);
    const h = services.heap;
    const v = args[0];
    const negative = try isNegative(h, v);
    const magnitude = if (negative) try ops.negate(h, v) else v;
    const root: Value = if (magnitude.asFlonum()) |x| .fromFlonum(@sqrt(x)) else try exactRoot(h, magnitude) orelse
        .fromFlonum(try inexactRoot(h, magnitude));
    if (!negative) return root;
    return ops.counted(Value, makeRectangularWork, h, .{ Value.fromFixnum(0), root });
}

/// The exact square root of the exact non-negative rational number `v`, or null if it has none.
fn exactRoot(h: *Heap, v: Value) Error!?Value {
    if (v.asRatnum()) |r| {
        const numerator = try exactRoot(h, r.numerator) orelse return null;
        const denominator = try exactRoot(h, r.denominator) orelse return null;
        return try ops.apply(h, .div, numerator, denominator);
    }
    const root = try power.integerSqrt(h, v);
    const square = try ops.apply(h, .mul, root, root);
    return if (try ops.numEqual(h, square, v)) root else null;
}

/// The square root of the exact non-negative rational number `v` as an `f64`.
fn inexactRoot(h: *Heap, v: Value) Error!f64 {
    const x = try flonumOf(h, v);
    if (std.math.isFinite(x) or v.asRatnum() != null) return @sqrt(x);
    // 整数が `f64` の範囲を超えるときは、整数の平方根を `f64` にする(根の誤差は相対で 2^-53 以下)。
    return flonumOf(h, try power.integerSqrt(h, v));
}

test {
    std.testing.refAllDecls(@This());
}

const test_support = @import("test_support.zig");

/// Calls `name` on the numbers `texts` spell, and checks the printed result (a boolean as `#t`/`#f`).
fn expectCall(expected: []const u8, name: []const u8, texts: []const []const u8) !void {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    var args: [4]Value = undefined;
    for (texts, 0..) |t, i| args[i] = (try number.parse(f.services.heap, t, 10)) orelse return error.NotANumber;
    const v = try f.call(&primitives, name, args[0..texts.len]);
    if (v.kind() == .boolean) {
        try std.testing.expectEqualStrings(expected, if (v.isTrue()) "#t" else "#f");
        return;
    }
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try number.write(&aw.writer, std.testing.allocator, v, 10);
    try std.testing.expectEqualStrings(expected, aw.written());
}

/// Calls `name` on the numbers `texts` spell, and checks the flonum result is within 1e-15 (relative)
/// of `expected`. 超越関数の最後の桁は、`libm` の実装で1だけずれうるので、桁の一致を要求しない。
fn expectNear(expected: f64, name: []const u8, texts: []const []const u8) !void {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    var args: [4]Value = undefined;
    for (texts, 0..) |t, i| args[i] = (try number.parse(f.services.heap, t, 10)) orelse return error.NotANumber;
    const v = try f.call(&primitives, name, args[0..texts.len]);
    const x = v.asFlonum() orelse return error.NotAFlonum;
    try std.testing.expect(@abs(x - expected) <= 1e-15 * @abs(expected));
}

fn expectError(expected: anyerror, name: []const u8, texts: []const []const u8) !void {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    var args: [4]Value = undefined;
    for (texts, 0..) |t, i| args[i] = (try number.parse(f.services.heap, t, 10)) orelse return error.NotANumber;
    try std.testing.expectError(expected, f.call(&primitives, name, args[0..texts.len]));
}

test "the primitives take the numbers of arguments the language gives them" {
    const Arity = struct { name: []const u8, min: u8, max: ?u8 };
    const expected = [_]Arity{
        .{ .name = "finite?", .min = 1, .max = 1 },
        .{ .name = "infinite?", .min = 1, .max = 1 },
        .{ .name = "nan?", .min = 1, .max = 1 },
        .{ .name = "exp", .min = 1, .max = 1 },
        .{ .name = "log", .min = 1, .max = 2 },
        .{ .name = "sin", .min = 1, .max = 1 },
        .{ .name = "cos", .min = 1, .max = 1 },
        .{ .name = "tan", .min = 1, .max = 1 },
        .{ .name = "asin", .min = 1, .max = 1 },
        .{ .name = "acos", .min = 1, .max = 1 },
        .{ .name = "atan", .min = 1, .max = 2 },
        .{ .name = "sqrt", .min = 1, .max = 1 },
    };
    try std.testing.expectEqual(expected.len, primitives.len);
    for (expected, 0..) |e, i| {
        try std.testing.expectEqualStrings(e.name, primitives[i].name);
        try std.testing.expectEqual(e.min, primitives[i].min_args);
        try std.testing.expectEqual(e.max, primitives[i].max_args);
    }
}

test "finite? infinite? and nan? agree with R7RS 6.2.6" {
    try expectCall("#t", "finite?", &.{"3"});
    try expectCall("#f", "finite?", &.{"+inf.0"});
    try expectCall("#f", "finite?", &.{"+nan.0"});
    try expectCall("#t", "finite?", &.{"3.5"});
    try expectCall("#t", "finite?", &.{"1/3"});
    try expectCall("#f", "infinite?", &.{"3"});
    try expectCall("#t", "infinite?", &.{"-inf.0"});
    try expectCall("#f", "infinite?", &.{"+nan.0"});
    try expectCall("#t", "infinite?", &.{"+inf.0+nan.0i"});
    try expectCall("#f", "nan?", &.{"3"});
    try expectCall("#f", "nan?", &.{"+inf.0"});
    try expectCall("#t", "nan?", &.{"+nan.0"});
    try expectCall("#t", "nan?", &.{"+nan.0+i"});
    try expectCall("#t", "nan?", &.{"1.0+nan.0i"});
    // 複素数は、両方の部分が有限のときだけ有限である。
    try expectCall("#t", "finite?", &.{"1.0+2.0i"});
    try expectCall("#f", "finite?", &.{"1.0+inf.0i"});
    try expectCall("#f", "finite?", &.{"+inf.0+2.0i"});
    try expectCall("#f", "finite?", &.{"1.0+nan.0i"});
    try expectCall("#f", "infinite?", &.{"1.0+2.0i"});
    try expectCall("#t", "infinite?", &.{"1.0+inf.0i"});
    try expectCall("#t", "infinite?", &.{"-inf.0+2.0i"});
    try expectCall("#f", "nan?", &.{"1.0+inf.0i"});
}

test "finite? infinite? and nan? take only a number" {
    for ([_][]const u8{ "finite?", "infinite?", "nan?" }) |name| {
        var f: test_support.Fixture = undefined;
        f.init();
        defer f.deinit();
        try std.testing.expectError(error.WrongType, f.call(&primitives, name, &.{.unspecified_value}));
        try std.testing.expectError(error.WrongType, f.call(&primitives, name, &.{.fromBool(false)}));
    }
}

test "sqrt of an exact square is exact" {
    try expectCall("3", "sqrt", &.{"9"});
    try expectCall("0", "sqrt", &.{"0"});
    try expectCall("1", "sqrt", &.{"1"});
    try expectCall("1/2", "sqrt", &.{"1/4"});
    try expectCall("3/4", "sqrt", &.{"9/16"});
    try expectCall("100000000000000000000", "sqrt", &.{"10000000000000000000000000000000000000000"});
    try expectCall("3037000500", "sqrt", &.{"9223372037000250000"});
}

test "sqrt of anything else is a flonum" {
    try expectCall("1.4142135623730951", "sqrt", &.{"2"});
    try expectCall("0.5", "sqrt", &.{"0.25"});
    try expectCall("3.0", "sqrt", &.{"9.0"});
    try expectCall("0.7071067811865476", "sqrt", &.{"1/2"});
    try expectCall("+inf.0", "sqrt", &.{"+inf.0"});
    try expectCall("+nan.0", "sqrt", &.{"+nan.0"});
    try expectCall("-0.0", "sqrt", &.{"-0.0"});
    // 63 ビットを超えるが平方数でない整数。
    try expectCall("3037000499.97605", "sqrt", &.{"9223372036854775808"});
    // f64 の範囲を超える整数は、根が有限の flonum になる(10 の 399 乗の根は 3.16...e199)。
    var digits: [400]u8 = undefined;
    @memset(&digits, '0');
    digits[0] = '1';
    try expectNear(3.1622776601683795e199, "sqrt", &.{&digits});
}

test "sqrt of a negative real number is an imaginary number" {
    try expectCall("+i", "sqrt", &.{"-1"});
    try expectCall("+2i", "sqrt", &.{"-4"});
    try expectCall("+1/2i", "sqrt", &.{"-1/4"});
    try expectCall("0.0+1.4142135623730951i", "sqrt", &.{"-2"});
    try expectCall("0.0+2.0i", "sqrt", &.{"-4.0"});
    try expectCall("0.0+inf.0i", "sqrt", &.{"-inf.0"});
}

test "sqrt takes a number that is real" {
    try expectError(error.WrongType, "sqrt", &.{"1+2i"});
    try expectError(error.WrongType, "sqrt", &.{"1.0+2.0i"});
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    try std.testing.expectError(error.WrongType, f.call(&primitives, "sqrt", &.{.unspecified_value}));
}

test "exp log and the trigonometric functions of an exact argument are exact at their special points" {
    try expectCall("1", "exp", &.{"0"});
    try expectCall("0", "log", &.{"1"});
    try expectCall("0", "sin", &.{"0"});
    try expectCall("1", "cos", &.{"0"});
    try expectCall("0", "tan", &.{"0"});
    try expectCall("0", "asin", &.{"0"});
    try expectCall("0", "acos", &.{"1"});
    try expectCall("0", "atan", &.{"0"});
    try expectCall("0", "atan", &.{ "0", "1" });
    try expectCall("0", "atan", &.{ "0", "5/2" });
}

test "an inexact point is not special" {
    try expectCall("1.0", "exp", &.{"0.0"});
    try expectCall("0.0", "sin", &.{"0.0"});
    try expectCall("-0.0", "sin", &.{"-0.0"});
    try expectCall("1.0", "cos", &.{"0.0"});
    try expectCall("0.0", "log", &.{"1.0"});
    try expectCall("0.0", "acos", &.{"1.0"});
}

test "exp log and the trigonometric functions give flonums" {
    try expectNear(2.718281828459045, "exp", &.{"1"});
    try expectNear(7.38905609893065, "exp", &.{"2"});
    try expectNear(0.36787944117144233, "exp", &.{"-1"});
    try expectCall("+inf.0", "exp", &.{"+inf.0"});
    try expectCall("0.0", "exp", &.{"-inf.0"});
    try expectNear(0.6931471805599453, "log", &.{"2"});
    try expectNear(1.0, "log", &.{"2.718281828459045"});
    try expectCall("-inf.0", "log", &.{"0"});
    try expectCall("+inf.0", "log", &.{"+inf.0"});
    try expectNear(0.8414709848078965, "sin", &.{"1"});
    try expectNear(0.5403023058681398, "cos", &.{"1"});
    try expectNear(1.5574077246549023, "tan", &.{"1"});
    try expectNear(1.5707963267948966, "asin", &.{"1"});
    try expectNear(-1.5707963267948966, "asin", &.{"-1"});
    try expectNear(3.141592653589793, "acos", &.{"-1"});
    try expectNear(1.5707963267948966, "acos", &.{"0"});
    try expectNear(0.7853981633974483, "atan", &.{"1"});
    try expectNear(1.5707963267948966, "atan", &.{"+inf.0"});
    try expectCall("+nan.0", "sin", &.{"+inf.0"});
    try expectCall("+nan.0", "sin", &.{"+nan.0"});
}

test "log with a base divides the logarithms" {
    try expectCall("3.0", "log", &.{ "8", "2" });
    try expectCall("2.0", "log", &.{ "100", "10" });
    try expectCall("+inf.0", "log", &.{ "2", "1" });
}

test "log of a negative number is complex" {
    try expectCall("0.0+3.141592653589793i", "log", &.{"-1"});
    try expectCall("0.6931471805599453+3.141592653589793i", "log", &.{"-2"});
    try expectCall("+inf.0+3.141592653589793i", "log", &.{"-inf.0"});
    try expectError(error.OutOfRange, "log", &.{ "-2", "10" });
    try expectError(error.OutOfRange, "log", &.{ "2", "-10" });
}

test "atan with two arguments is the angle of the point" {
    try expectCall("0.7853981633974483", "atan", &.{ "1", "1" });
    try expectCall("2.356194490192345", "atan", &.{ "1", "-1" });
    try expectCall("-0.7853981633974483", "atan", &.{ "-1", "1" });
    try expectCall("1.5707963267948966", "atan", &.{ "1", "0" });
    try expectCall("3.141592653589793", "atan", &.{ "0", "-1" });
    try expectCall("0.0", "atan", &.{ "0.0", "1" });
    try expectCall("0.0", "atan", &.{ "0", "1.0" });
    try expectError(error.OutOfRange, "atan", &.{ "0", "0" });
}

test "asin and acos are not defined outside [-1, 1] for a real number" {
    try expectError(error.OutOfRange, "asin", &.{"2"});
    try expectError(error.OutOfRange, "acos", &.{"-1.5"});
    try expectError(error.OutOfRange, "asin", &.{"+inf.0"});
    try expectCall("+nan.0", "asin", &.{"+nan.0"});
}

test "the functions take only a real number" {
    for ([_][]const u8{ "exp", "log", "sin", "cos", "tan", "asin", "acos", "atan" }) |name| {
        try expectError(error.WrongType, name, &.{"1+2i"});
        var f: test_support.Fixture = undefined;
        f.init();
        defer f.deinit();
        try std.testing.expectError(error.WrongType, f.call(&primitives, name, &.{.unspecified_value}));
    }
    // 型は、値によらず、すべての引数について先に検査する。
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    try std.testing.expectError(error.WrongType, f.call(&primitives, "atan", &.{ .fromFixnum(0), .unspecified_value }));
    try std.testing.expectError(error.WrongType, f.call(&primitives, "log", &.{ .fromFixnum(1), .unspecified_value }));
}
