//! The primitives of `(scheme inexact)` (R7RS 6.2.6): `finite?` `infinite?` `nan?`, `exp` `log`,
//! `sin` `cos` `tan` `asin` `acos` `atan`, and `sqrt`.
//!
//! 計算は `f64` で行い、結果は flonum である。例外は、正確な引数の特別な点(`(exp 0)` など)と、
//! 正確な平方数の `sqrt` で、結果は正確な数になる。引数は複素数でもよい(`sqrt` `exp` `log`
//! `sin` `cos` `tan` `asin` `acos` `atan` の1引数)。複素数の計算は `src/num/complex.zig` が
//! 行う。実数の引数で結果が実数にならない場合(負の数の `sqrt` と `log`、`[-1, 1]` の外の
//! `asin` と `acos`)も、結果は複素数である。2引数の `atan` は実数だけを取る。
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
const complex = @import("../num/complex.zig");
const elementary = @import("../num/elementary.zig");

pub const Error = PrimitiveError;

pub const primitives = [_]Primitive{
    .{ .name = "finite?", .min_args = 1, .max_args = 1, .body = .{ .pure = classify(.finite) } },
    .{ .name = "infinite?", .min_args = 1, .max_args = 1, .body = .{ .pure = classify(.infinite) } },
    .{ .name = "nan?", .min_args = 1, .max_args = 1, .body = .{ .pure = classify(.nan) } },
    .{ .name = "exp", .min_args = 1, .max_args = 1, .body = .{ .pure = unary(.exp, expF64, .{ 0, 1 }) } },
    .{ .name = "log", .min_args = 1, .max_args = 2, .body = .{ .pure = &logOf } },
    .{ .name = "sin", .min_args = 1, .max_args = 1, .body = .{ .pure = unary(.sin, sinF64, .{ 0, 0 }) } },
    .{ .name = "cos", .min_args = 1, .max_args = 1, .body = .{ .pure = unary(.cos, cosF64, .{ 0, 1 }) } },
    .{ .name = "tan", .min_args = 1, .max_args = 1, .body = .{ .pure = unary(.tan, tanF64, .{ 0, 0 }) } },
    .{ .name = "asin", .min_args = 1, .max_args = 1, .body = .{ .pure = unary(.asin, asinF64, .{ 0, 0 }) } },
    .{ .name = "acos", .min_args = 1, .max_args = 1, .body = .{ .pure = unary(.acos, acosF64, .{ 1, 0 }) } },
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

/// Checks every argument is a number, before anything is computed.
fn requireNumbers(args: []const Value) Error!void {
    for (args) |a| if (!number.isNumber(a)) return error.WrongType;
}

/// Checks every argument is a real number, before anything is computed.
fn requireReals(args: []const Value) Error!void {
    for (args) |a| if (!ops.isRealNumber(a)) return error.WrongType;
}

/// `f` of a number. `special` is the exact argument whose result is exact, and that result
/// (`(exp 0)` is 1, `(acos 1)` is 0): the other exact arguments give a flonum.
///
/// 複素数の引数と、`asin` と `acos` の定義域 `[-1, 1]` の外の実数は、結果が複素数になるので、
/// `complex.apply` が計算する。
fn unary(comptime tag: complex.Fn, comptime f: fn (f64) f64, comptime special: [2]i64) Primitive.Fn {
    return &struct {
        fn call(services: *const Services, args: []const Value) Error!Value {
            try requireNumbers(args);
            const h = services.heap;
            const v = args[0];
            if (v.asFixnum()) |n| if (n == special[0]) return .fromFixnum(special[1]);
            if (v.kind() == .compnum) return complex.apply(h, tag, v);
            const x = try elementary.toF64(h, v);
            if ((tag == .asin or tag == .acos) and @abs(x) > 1.0) return complex.apply(h, tag, v);
            return .fromFlonum(f(x));
        }
    }.call;
}

/// Whether the real number `v` is below zero. `-0.0` is not.
fn isBelowZero(h: *Heap, v: Value) Error!bool {
    if (v.asFlonum()) |x| return x < 0;
    return (try ops.compare(h, v, .fromFixnum(0))).? == .lt;
}

/// Whether the sign of the real number `v` is negative. `-0.0` is (a NaN is not).
fn isSignedNegative(h: *Heap, v: Value) Error!bool {
    if (v.asFlonum()) |x| return std.math.signbit(x) and !std.math.isNan(x);
    return isBelowZero(h, v);
}

/// `(log z)` and `(log z1 z2)`: the natural logarithm, and the logarithm of `z1` to the base `z2`.
///
/// 負の実数と `-0.0` の自然対数は `log |x| + pi i` の複素数である(`(log -1)` は
/// `0.0+3.141592653589793i`、`(log -0.0)` は `-inf.0+3.141592653589793i`。原文のとおり)。
/// 2引数は、2つの自然対数の商である。底が 10 と 2 のときは `log10` と `log2` を使い、
/// `(log 1000 10)` が `3.0` になる。どちらかが複素数か負の数なら、複素数の商である。
/// `f64` に収まらない正確な数の対数は、整数の演算で求める(`(log (expt 10 400))` は約 921.03)。
fn logOf(services: *const Services, args: []const Value) Error!Value {
    try requireNumbers(args);
    const h = services.heap;
    const v = args[0];
    if (args.len == 2) return logToBase(h, v, args[1]);
    if (v.asFixnum()) |n| if (n == 1) return .fromFixnum(0);
    if (v.kind() == .compnum or try isSignedNegative(h, v)) return complex.apply(h, .log, v);
    return .fromFlonum(try elementary.ln(h, v));
}

fn logToBase(h: *Heap, v: Value, base: Value) Error!Value {
    if (v.kind() == .compnum or base.kind() == .compnum) return complex.logBase(h, v, base);
    if (try isSignedNegative(h, v) or try isSignedNegative(h, base)) return complex.logBase(h, v, base);
    const b = try elementary.toF64(h, base);
    const x = try elementary.toF64(h, v);
    if (std.math.isFinite(x) and x >= std.math.floatMin(f64)) {
        if (b == 10.0) return .fromFlonum(@log10(x));
        if (b == 2.0) return .fromFlonum(@log2(x));
    }
    return .fromFlonum(try elementary.ln(h, v) / try elementary.ln(h, base));
}

/// `(atan z)` and `(atan y x)`: the arctangent of `z`, and the angle of the point `(x, y)`, in
/// radians (R7RS 6.2.6).
///
/// 2引数の `(atan 0 x)` は、`x` が正確な正の数なら正確な 0 である。両方が正確な 0 なら、
/// 原文が角を定めないので `OutOfRange` にする。2引数は実数だけを取る。
fn atanOf(services: *const Services, args: []const Value) Error!Value {
    const h = services.heap;
    if (args.len == 1) {
        try requireNumbers(args);
        const v = args[0];
        if (v.asFixnum()) |n| if (n == 0) return .fromFixnum(0);
        if (v.kind() == .compnum) return complex.apply(h, .atan, v);
        return .fromFlonum(std.math.atan(try elementary.toF64(h, v)));
    }
    try requireReals(args);
    if (args[0].asFixnum()) |y| if (y == 0 and ops.isExact(args[1])) {
        if (args[1].asFixnum()) |x| if (x == 0) return error.OutOfRange;
        if (!try isBelowZero(h, args[1])) return .fromFixnum(0);
    };
    return .fromFlonum(try elementary.atan2(h, args[0], args[1]));
}

/// `(sqrt z)`: the principal square root of a number.
///
/// 正確な平方数(整数と、分子と分母がどちらも平方数の有理数)は、正確な根を返す。それ以外は
/// flonum である。負の実数は `i` 倍の複素数になる(`(sqrt -4)` は `+2i`、`(sqrt -2)` は
/// `0.0+1.4142135623730951i`)。複素数の根は `complex.apply` が求める。
fn sqrtOf(services: *const Services, args: []const Value) Error!Value {
    try requireNumbers(args);
    const h = services.heap;
    const v = args[0];
    if (v.kind() == .compnum) return complex.apply(h, .sqrt, v);
    const negative = try isBelowZero(h, v);
    const root = try elementary.sqrt(h, if (negative) try ops.negate(h, v) else v);
    if (!negative) return root;
    return complex.rectangular(h, .fromFixnum(0), root);
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

/// Calls `name` on the numbers `texts` spell, and checks the result is a complex number whose
/// parts are within 1e-14 (relative to the larger of the part and 1) of `re` and `im`.
fn expectNearComplex(re: f64, im: f64, name: []const u8, texts: []const []const u8) !void {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    var args: [4]Value = undefined;
    for (texts, 0..) |t, i| args[i] = (try number.parse(f.services.heap, t, 10)) orelse return error.NotANumber;
    const v = try f.call(&primitives, name, args[0..texts.len]);
    const c = v.asCompnum() orelse return error.NotAComplex;
    const got_re = c.real.asFlonum() orelse return error.NotAFlonum;
    const got_im = c.imag.asFlonum() orelse return error.NotAFlonum;
    try std.testing.expect(@abs(got_re - re) <= 1e-14 * @max(1.0, @abs(re)));
    try std.testing.expect(@abs(got_im - im) <= 1e-14 * @max(1.0, @abs(im)));
}

fn expectError(expected: anyerror, name: []const u8, texts: []const []const u8) !void {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    var args: [4]Value = undefined;
    for (texts, 0..) |t, i| args[i] = (try number.parse(f.services.heap, t, 10)) orelse return error.NotANumber;
    try std.testing.expectError(expected, f.call(&primitives, name, args[0..texts.len]));
}

/// The spelling of 10^n.
fn tenPow(comptime n: usize) *const [n + 1]u8 {
    comptime {
        var digits: [n + 1]u8 = @splat('0');
        digits[0] = '1';
        const spelled = digits;
        return &spelled;
    }
}

const ten_399 = tenPow(399);
const ten_400 = tenPow(400);

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

test "sqrt of a rational number that does not fit an f64 is finite" {
    const gpa = std.testing.allocator;
    var zeros: [400]u8 = undefined;
    @memset(&zeros, '0');
    // 10^400 / 3 の根は 1e200 / sqrt(3)。比が `f64` で無限大になる。
    const big = try std.fmt.allocPrint(gpa, "1{s}/3", .{zeros[0..400]});
    defer gpa.free(big);
    try expectNear(5.773502691896258e199, "sqrt", &.{big});
    // 1 / (10^400 + 1) の根は約 1e-200。比が `f64` で 0 になる。
    const small = try std.fmt.allocPrint(gpa, "1/1{s}1", .{zeros[0..399]});
    defer gpa.free(small);
    try expectNear(1.0e-200, "sqrt", &.{small});
    // (10^400 + 1) / 3 も同じ。
    const odd = try std.fmt.allocPrint(gpa, "1{s}1/3", .{zeros[0..399]});
    defer gpa.free(odd);
    try expectNear(5.773502691896258e199, "sqrt", &.{odd});
}

test "sqrt of a negative real number is an imaginary number" {
    try expectCall("+i", "sqrt", &.{"-1"});
    try expectCall("+2i", "sqrt", &.{"-4"});
    try expectCall("+1/2i", "sqrt", &.{"-1/4"});
    try expectCall("0.0+1.4142135623730951i", "sqrt", &.{"-2"});
    try expectCall("0.0+2.0i", "sqrt", &.{"-4.0"});
    try expectCall("0.0+inf.0i", "sqrt", &.{"-inf.0"});
}

test "sqrt of a complex number" {
    // 平方根が正確な数になる複素数は、正確な数を返す。
    try expectCall("2+i", "sqrt", &.{"3+4i"});
    try expectCall("1+i", "sqrt", &.{"+2i"});
    try expectCall("1-2i", "sqrt", &.{"-3-4i"});
    try expectCall("1+2i", "sqrt", &.{"-3+4i"});
    try expectCall("1/2+1/2i", "sqrt", &.{"+1/2i"});
    try expectCall("2.0+1.0i", "sqrt", &.{"3.0+4.0i"});
    try expectNearComplex(0.7071067811865476, 0.7071067811865476, "sqrt", &.{"+i"});
    try expectNearComplex(1.272019649514069, 0.7861513777574233, "sqrt", &.{"1+2i"});
    try expectNearComplex(0.0, 1.0, "sqrt", &.{"-1.0+0.0i"});
    // 虚部が -0.0 でも、R7RS 6.2.6 の「実部が0なら虚部は非負」に従い、+i 側の根になる。
    try expectNearComplex(0.0, 1.0, "sqrt", &.{"-1.0-0.0i"});
}

test "sqrt takes only a number" {
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
    // 原文は `(log -0.0)` を `-inf.0+πi` とする。
    try expectCall("-inf.0+3.141592653589793i", "log", &.{"-0.0"});
    try expectCall("-inf.0", "log", &.{"0.0"});
    try expectCall("-inf.0", "log", &.{"0"});
}

test "log of a complex number" {
    try expectNearComplex(0.0, 1.5707963267948966, "log", &.{"+i"});
    try expectNearComplex(0.34657359027997264, 0.7853981633974483, "log", &.{"1+i"});
    try expectNearComplex(0.8047189562170503, 1.1071487177940904, "log", &.{"1+2i"});
    try expectNearComplex(1.6094379124341003, -0.9272952180016122, "log", &.{"3-4i"});
}

test "log with a base that is negative or complex divides the complex logarithms" {
    // log(-8) / log(2) = (log 8 + pi i) / log 2
    try expectNearComplex(3.0, 4.532360141827194, "log", &.{ "-8", "2" });
    // log(8) / log(-2) = log 8 / (log 2 + pi i)
    try expectNearComplex(0.1392609706362244, -0.6311808726237906, "log", &.{ "8", "-2" });
    try expectNearComplex(1.0, 0.0, "log", &.{ "+i", "+i" });
}

test "log of a number beyond an f64" {
    // 10^400 の自然対数は 400 ln 10。
    try expectNear(921.0340371976183, "log", &.{ten_400});
    try expectNear(-921.0340371976183, "log", &.{"1/" ++ ten_400});
    // 比が `f64` に収まるときは、`f64` の対数と同じ値になる。
    try expectNear(0.6931471805599453, "log", &.{"2" ++ ten_400[1..] ++ "/" ++ ten_400});
    try expectNear(400.0, "log", &.{ ten_400, "10" });
}

test "log to base 10 and 2 is exact at the powers" {
    try expectCall("3.0", "log", &.{ "1000", "10" });
    try expectCall("-2.0", "log", &.{ "1/100", "10" });
    try expectCall("10.0", "log", &.{ "1024", "2" });
    try expectCall("-inf.0", "log", &.{ "0.0", "2" });
    try expectCall("-inf.0", "log", &.{ "0", "10" });
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

test "asin and acos outside [-1, 1] are complex" {
    try expectNearComplex(1.5707963267948966, -1.3169578969248166, "asin", &.{"2"});
    try expectNearComplex(-1.5707963267948966, 1.3169578969248166, "asin", &.{"-2"});
    try expectNearComplex(0.0, 1.3169578969248166, "acos", &.{"2"});
    try expectNearComplex(3.141592653589793, -1.3169578969248166, "acos", &.{"-2"});
    try expectNearComplex(1.5707963267948966, -1.762747174039086, "asin", &.{"3.0"});
    try expectCall("1.5707963267948966-inf.0i", "asin", &.{"+inf.0"});
    try expectCall("+nan.0", "asin", &.{"+nan.0"});
    try expectCall("+nan.0", "acos", &.{"+nan.0"});
    // 定義域の中は実数のまま。
    try expectNear(0.5235987755982989, "asin", &.{"1/2"});
}

test "the functions of a complex number" {
    try expectNearComplex(1.2984575814159773, 0.6349639147847361, "sin", &.{"1+i"});
    try expectNearComplex(0.8337300251311491, -0.9888977057628651, "cos", &.{"1+i"});
    try expectNearComplex(0.2717525853195118, 1.0839233273386946, "tan", &.{"1+i"});
    try expectNearComplex(1.0172219678978514, 0.4023594781085251, "atan", &.{"1+i"});
    try expectNearComplex(-1.1312043837568138, 2.471726672004819, "exp", &.{"1+2i"});
    try expectNearComplex(0.5403023058681398, 0.8414709848078965, "exp", &.{"+i"});
    try expectNearComplex(0.6662394324925153, 1.0612750619050357, "asin", &.{"1+i"});
    try expectNearComplex(0.9045568943023814, -1.0612750619050357, "acos", &.{"1+i"});
}

test "an exact complex argument of an exact special point is not special" {
    try expectNearComplex(0.0, 1.1752011936438014, "sin", &.{"+i"});
    try expectNearComplex(1.5430806348152437, 0.0, "cos", &.{"+i"});
}

test "the functions take only a number" {
    for ([_][]const u8{ "exp", "log", "sin", "cos", "tan", "asin", "acos", "atan" }) |name| {
        var f: test_support.Fixture = undefined;
        f.init();
        defer f.deinit();
        try std.testing.expectError(error.WrongType, f.call(&primitives, name, &.{.unspecified_value}));
    }
    // 2引数の `atan` は実数だけを取る。
    try expectError(error.WrongType, "atan", &.{ "1+2i", "1" });
    try expectError(error.WrongType, "atan", &.{ "1", "1+2i" });
    // 型は、値によらず、すべての引数について先に検査する。
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    try std.testing.expectError(error.WrongType, f.call(&primitives, "atan", &.{ .fromFixnum(0), .unspecified_value }));
    try std.testing.expectError(error.WrongType, f.call(&primitives, "log", &.{ .fromFixnum(1), .unspecified_value }));
}

test "atan of numbers beyond an f64" {
    try expectNear(1.4711276743037347, "atan", &.{ ten_400, ten_399 });
    try expectNear(0.7853981633974483, "atan", &.{ ten_400, ten_400 });
    try expectNear(3.141592653589793, "atan", &.{ "1/" ++ ten_400, "-1" });
    try expectNear(-1.5707963267948966, "atan", &.{ "-" ++ ten_400, "1" });
}
