//! Arithmetic primitives.
//!
//! 四則と比較と `number?` は数値塔の実数(fixnum、bignum、ratnum、flonum)を扱い、
//! 計算は `num/ops.zig` が行う(docs/design/numerics-and-unicode.md)。整数除算の
//! `quotient` `remainder` `modulo` は、スライス 4g まで fixnum だけを扱う。

const std = @import("std");
const value = @import("../value.zig");
const Value = value.Value;
const Primitive = value.Primitive;
const Services = value.Services;
const PrimitiveError = value.PrimitiveError;
const number = @import("../num/number.zig");
const ops = @import("../num/ops.zig");

pub const Error = PrimitiveError;

pub const primitives = [_]Primitive{
    .{ .name = "+", .min_args = 0, .max_args = null, .body = .{ .pure = &add } },
    .{ .name = "-", .min_args = 1, .max_args = null, .body = .{ .pure = &subtract } },
    .{ .name = "*", .min_args = 0, .max_args = null, .body = .{ .pure = &multiply } },
    .{ .name = "/", .min_args = 1, .max_args = null, .body = .{ .pure = &divide } },
    .{ .name = "=", .min_args = 1, .max_args = null, .body = .{ .pure = comparison(.eq) } },
    .{ .name = "<", .min_args = 1, .max_args = null, .body = .{ .pure = comparison(.lt) } },
    .{ .name = ">", .min_args = 1, .max_args = null, .body = .{ .pure = comparison(.gt) } },
    .{ .name = "<=", .min_args = 1, .max_args = null, .body = .{ .pure = comparison(.lte) } },
    .{ .name = ">=", .min_args = 1, .max_args = null, .body = .{ .pure = comparison(.gte) } },
    .{ .name = "quotient", .min_args = 2, .max_args = 2, .body = .{ .pure = division(.quotient) } },
    .{ .name = "remainder", .min_args = 2, .max_args = 2, .body = .{ .pure = division(.remainder) } },
    .{ .name = "modulo", .min_args = 2, .max_args = 2, .body = .{ .pure = division(.modulo) } },
    .{ .name = "number?", .min_args = 1, .max_args = 1, .body = .{ .pure = &isNumber } },
};

/// A result of the wide arithmetic, as a fixnum if it fits.
///
/// 整数除算(`quotient` など)は、スライス 4g まで fixnum だけを扱う。R7RS 6.2.3 は、
/// 表現できない正確な結果を、実装上の制限の違反として報告することを実装に許している。
fn fromWide(n: i128) Error!Value {
    return .fromFixnum(std.math.cast(i64, n) orelse return error.IntegerOverflow);
}

/// Checks that every argument is a number the operation takes.
///
/// 値によらず、すべての引数の型を先に検査する。エラーが、前の引数まででもう答えが決まった
/// かどうかや、途中の計算の結果に左右されないようにするためである。
fn requireReals(args: []const Value) Error!void {
    for (args) |a| switch (a.kind()) {
        .fixnum, .bignum, .ratnum, .flonum => {},
        else => return error.WrongType,
    };
}

/// `(+ z1 ...)`.
///
/// 引数がなければ和は 0 である(R7RS 6.2.6)。1つなら、その引数そのもの(`(+ -0.0)` は
/// `-0.0`)。
fn add(services: *const Services, args: []const Value) Error!Value {
    try requireReals(args);
    if (args.len == 0) return .fromFixnum(0);
    var sum = args[0];
    for (args[1..]) |a| sum = try ops.apply(services.heap, .add, sum, a);
    return sum;
}

/// `(- z)` negates, and `(- z1 z2 ...)` subtracts the rest from the first
/// (R7RS 6.2.6).
///
/// 引数は1つ以上要る。個数は機械が表の下限で検査するので、`args[0]` を読んでよい。
fn subtract(services: *const Services, args: []const Value) Error!Value {
    try requireReals(args);
    if (args.len == 1) return ops.negate(services.heap, args[0]);
    var difference = args[0];
    for (args[1..]) |a| difference = try ops.apply(services.heap, .sub, difference, a);
    return difference;
}

/// `(* z1 ...)`.
///
/// 引数がなければ積は 1 である(R7RS 6.2.6)。
fn multiply(services: *const Services, args: []const Value) Error!Value {
    try requireReals(args);
    if (args.len == 0) return .fromFixnum(1);
    var product = args[0];
    for (args[1..]) |a| product = try ops.apply(services.heap, .mul, product, a);
    return product;
}

/// `(/ z)` is the reciprocal, and `(/ z1 z2 ...)` divides the first by the rest (R7RS 6.2.6).
///
/// 正確な0で割ると `DivisionByZero` である。被除数が不正確でも同じ。引数は1つ以上要る。
fn divide(services: *const Services, args: []const Value) Error!Value {
    try requireReals(args);
    if (args.len == 1) return ops.apply(services.heap, .div, .fromFixnum(1), args[0]);
    var quotient = args[0];
    for (args[1..]) |a| quotient = try ops.apply(services.heap, .div, quotient, a);
    return quotient;
}

/// `(= z1 z2 z3 ...)` and its relatives (R7RS 6.2.6): true when `op` holds for
/// every neighbouring pair.
///
/// 引数が1つなら真、なしならエラー(機械が表の下限で報告する)である。最初に成り
/// 立たなかった組より後のものも含め、すべての引数が数であることを検査する。エラーが
/// 値に左右されないようにするためである。NaN を含む組は、どの比較でも偽である。
fn comparison(comptime op: std.math.CompareOperator) Primitive.Fn {
    return &struct {
        fn call(services: *const Services, args: []const Value) Error!Value {
            try requireReals(args);
            var holds = true;
            for (args[0 .. args.len - 1], args[1..]) |a, b| {
                const order = try ops.compare(services.heap, a, b);
                if (order == null or !orderHolds(order.?, op)) holds = false;
            }
            return .fromBool(holds);
        }
    }.call;
}

fn orderHolds(order: std.math.Order, comptime op: std.math.CompareOperator) bool {
    return switch (op) {
        .eq => order == .eq,
        .neq => order != .eq,
        .lt => order == .lt,
        .lte => order != .gt,
        .gt => order == .gt,
        .gte => order != .lt,
    };
}

/// Which of the integer divisions a primitive computes.
const Division = enum { quotient, remainder, modulo };

/// `(quotient n d)`, `(remainder n d)` and `(modulo n d)` (R7RS 6.2.6).
///
/// `quotient` と `remainder` は0に向かって丸める除算(`truncate-quotient` と
/// `truncate-remainder`)で、`remainder` の符号は被除数に従う。`modulo` は床除算の
/// 剰余(`floor-remainder`)で、符号は除数に従う。
///
/// 128ビットで計算する。最小の fixnum を -1 で割ると、商の 2^63 は64ビットに収まらないが、
/// 128ビットなら除算そのものは正しく終わる。収まるかどうかは結果で決め、`quotient` だけが
/// あふれる。
///
/// Why: 最小の fixnum を -1 で割ったときの `remainder` と `modulo` は、数学的な値の 0 を
/// 返し、エラーにしない。0 は収まるので、R7RS 6.2.3 の「表現できない結果」に当たらない。
///
/// 検査の順序は、型、除数の 0 である。両方の引数の型を先に検査し、エラーが値に左右
/// されないようにする(`*` と比較の方針)。個数は機械が表で検査する。
fn division(comptime kind: Division) Primitive.Fn {
    return &struct {
        fn call(_: *const Services, args: []const Value) Error!Value {
            const dividend = args[0].asFixnum() orelse return error.WrongType;
            const divisor = args[1].asFixnum() orelse return error.WrongType;
            if (divisor == 0) return error.DivisionByZero;
            const n: i128 = dividend;
            const d: i128 = divisor;
            return fromWide(switch (kind) {
                .quotient => @divTrunc(n, d),
                .remainder => @rem(n, d),
                // R7RS の modulo は floor-remainder で、n - d * floor(n / d) と定義される。その定義のまま書く。
                .modulo => n - d * @divFloor(n, d),
            });
        }
    }.call;
}

/// `(number? obj)`: true when `obj` is a number (R7RS 6.2.6).
///
/// 数の型の述語は、数でない引数にも使え、偽を返す。
fn isNumber(_: *const Services, args: []const Value) Error!Value {
    return .fromBool(number.isNumber(args[0]));
}

test {
    std.testing.refAllDecls(@This());
}

const test_support = @import("test_support.zig");

/// Calls the primitive called `name` with fixnum arguments.
fn call(name: []const u8, ns: []const i64) Error!Value {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    var args: [8]Value = undefined;
    for (ns, 0..) |n, i| args[i] = .fromFixnum(n);
    return f.call(&primitives, name, args[0..ns.len]);
}

fn callInt(name: []const u8, ns: []const i64) Error!i64 {
    return (try call(name, ns)).asFixnum().?;
}

fn callBool(name: []const u8, ns: []const i64) !bool {
    const v = try call(name, ns);
    try std.testing.expectEqual(.boolean, v.kind());
    return v.isTrue();
}

/// Calls the primitive called `name` with `args`, which are not all fixnums.
fn callWith(name: []const u8, args: []const Value) Error!Value {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    return f.call(&primitives, name, args);
}

/// Whether the number `v` is written as `expected`.
fn expectShown(expected: []const u8, v: Value) !void {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try number.write(&aw.writer, std.testing.allocator, v, 10);
    try std.testing.expectEqualStrings(expected, aw.written());
}

/// Calls `name` with the fixnums `ns`, and expects the result to be written as `expected`.
/// 結果の bignum は、ヒープが生きている間に確かめる。
fn expectCallInts(expected: []const u8, name: []const u8, ns: []const i64) !void {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    var args: [8]Value = undefined;
    for (ns, 0..) |n, i| args[i] = .fromFixnum(n);
    try expectShown(expected, try f.call(&primitives, name, args[0..ns.len]));
}

/// Calls `name` with the numbers written as `texts`, and expects the result to be written as
/// `expected`; or, for `expected` of `#t` or `#f`, to be that boolean.
fn expectCall(expected: []const u8, name: []const u8, texts: []const []const u8) !void {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    var args: [8]Value = undefined;
    for (texts, 0..) |t, i| args[i] = (try number.parse(f.services.heap, t, 10)) orelse return error.NotANumber;
    const v = try f.call(&primitives, name, args[0..texts.len]);
    if (v.kind() == .boolean) {
        try std.testing.expectEqualStrings(expected, if (v.isTrue()) "#t" else "#f");
        return;
    }
    try expectShown(expected, v);
}

test "the primitives take the numbers of arguments the language gives them" {
    const Arity = struct { name: []const u8, min: u8, max: ?u8 };
    const expected = [_]Arity{
        .{ .name = "+", .min = 0, .max = null },
        .{ .name = "-", .min = 1, .max = null },
        .{ .name = "*", .min = 0, .max = null },
        .{ .name = "/", .min = 1, .max = null },
        .{ .name = "=", .min = 1, .max = null },
        .{ .name = "<", .min = 1, .max = null },
        .{ .name = ">", .min = 1, .max = null },
        .{ .name = "<=", .min = 1, .max = null },
        .{ .name = ">=", .min = 1, .max = null },
        .{ .name = "quotient", .min = 2, .max = 2 },
        .{ .name = "remainder", .min = 2, .max = 2 },
        .{ .name = "modulo", .min = 2, .max = 2 },
        .{ .name = "number?", .min = 1, .max = 1 },
    };
    try std.testing.expectEqual(expected.len, primitives.len);
    // 長さの食い違いは、上の比較で報告する。ここは添字で進めるので、食い違っても
    // コンパイルエラーでなくテストの失敗になる。
    for (expected, 0..) |e, i| {
        try std.testing.expect(i < primitives.len);
        const p = primitives[i];
        try std.testing.expectEqualStrings(e.name, p.name);
        try std.testing.expectEqual(e.min, p.min_args);
        try std.testing.expectEqual(e.max, p.max_args);
    }
}

test "+ adds its arguments, and of none is 0" {
    try std.testing.expectEqual(0, try callInt("+", &.{}));
    try std.testing.expectEqual(1, try callInt("+", &.{1}));
    try std.testing.expectEqual(15, try callInt("+", &.{ 1, 2, 3, 4, 5 }));
    try std.testing.expectEqual(-5, try callInt("+", &.{ 2, -7 }));
}

test "+ makes a bignum of a sum that does not fit, rather than wrapping" {
    try expectCallInts("9223372036854775808", "+", &.{ std.math.maxInt(i64), 1 });
    try expectCallInts("-9223372036854775809", "+", &.{ std.math.minInt(i64), -1 });
}

test "+ holds only the result to the fixnum range, not a partial sum" {
    try std.testing.expectEqual(std.math.maxInt(i64), try callInt("+", &.{ std.math.maxInt(i64), 1, -1 }));
}

test "+ reports an argument that is not a number" {
    const args = [_]Value{ .fromFixnum(1), .unspecified_value };
    try std.testing.expectError(error.WrongType, callWith("+", &args));
}

test "- negates one argument and subtracts the rest from the first" {
    try std.testing.expectEqual(-5, try callInt("-", &.{5}));
    try std.testing.expectEqual(0, try callInt("-", &.{0}));
    try std.testing.expectEqual(2, try callInt("-", &.{ 5, 3 }));
    try std.testing.expectEqual(4, try callInt("-", &.{ 10, 1, 2, 3 }));
    try std.testing.expectEqual(-5, try callInt("-", &.{ 0, 5 }));
}

test "- makes a bignum of a result that does not fit" {
    try expectCallInts("9223372036854775808", "-", &.{std.math.minInt(i64)});
    try expectCallInts("9223372036854775808", "-", &.{ 0, std.math.minInt(i64) });
    try expectCallInts("9223372036854775808", "-", &.{ std.math.maxInt(i64), -1 });
    // 結果が範囲に戻るなら、途中の差は fixnum の範囲を出てよく、結果は fixnum である。
    try std.testing.expectEqual(std.math.maxInt(i64), try callInt("-", &.{ std.math.maxInt(i64), -1, 1 }));
}

test "* multiplies, and of none is 1" {
    try std.testing.expectEqual(1, try callInt("*", &.{}));
    try std.testing.expectEqual(7, try callInt("*", &.{7}));
    try std.testing.expectEqual(24, try callInt("*", &.{ 2, 3, 4 }));
    try std.testing.expectEqual(-6, try callInt("*", &.{ -2, 3 }));
    try std.testing.expectEqual(0, try callInt("*", &.{ 0, 5 }));
}

test "* makes a bignum of a product that does not fit, and a zero brings a partial one back" {
    try expectCallInts("18446744073709551614", "*", &.{ std.math.maxInt(i64), 2 });
    try expectCallInts("9223372036854775808", "*", &.{ std.math.minInt(i64), -1 });
    const big = std.math.maxInt(i64);
    try std.testing.expectEqual(0, try callInt("*", &.{ big, big, 0 }));
    try expectCallInts("784637716923335095224261902710254454442933591094742482943", "*", &.{ big, big, big });
    // 2^128 は128ビットでは 0 に巻き戻って fixnum に収まるが、bignum では巻き戻らない。
    const two_32 = 1 << 32;
    try expectCallInts("340282366920938463463374607431768211456", "*", &.{ two_32, two_32, two_32, two_32 });
}

test "* checks every argument before it multiplies" {
    const big = std.math.maxInt(i64);
    const args = [_]Value{ .fromFixnum(big), .fromFixnum(big), .fromFixnum(big), .unspecified_value };
    try std.testing.expectError(error.WrongType, callWith("*", &args));
}

test "comparisons chain over neighbouring pairs" {
    try std.testing.expect(try callBool("=", &.{ 1, 1, 1 }));
    try std.testing.expect(!try callBool("=", &.{ 1, 1, 2 }));
    try std.testing.expect(!try callBool("=", &.{ 2, 1, 1 }));
    try std.testing.expect(try callBool("<", &.{ 1, 2, 3 }));
    try std.testing.expect(!try callBool("<", &.{ 1, 3, 2 }));
    try std.testing.expect(!try callBool("<", &.{ 1, 1 }));
    try std.testing.expect(try callBool(">", &.{ 3, 2, 1 }));
    try std.testing.expect(!try callBool(">", &.{ 1, 2, 3 }));
    try std.testing.expect(try callBool("<=", &.{ 1, 2, 2 }));
    try std.testing.expect(!try callBool("<=", &.{ 2, 1 }));
    try std.testing.expect(try callBool(">=", &.{ 3, 2, 2 }));
    try std.testing.expect(!try callBool(">=", &.{ 1, 2 }));
}

test "a comparison of one number is true" {
    for ([_][]const u8{ "=", "<", ">", "<=", ">=" }) |name| {
        try std.testing.expect(try callBool(name, &.{5}));
    }
}

test "a comparison checks the type of every argument, however the pairs came out" {
    for ([_][]const u8{ "=", "<", ">", "<=", ">=" }) |name| {
        // 最初の組ですでに答えは決まっている。3番目は数ではない。
        const args = [_]Value{ .fromFixnum(2), .fromFixnum(1), .unspecified_value };
        try std.testing.expectError(error.WrongType, callWith(name, &args));
    }
}

test "/ divides exact numbers into a ratio, and takes the reciprocal of one argument" {
    try expectCall("1/2", "/", &.{ "1", "2" });
    try expectCall("2", "/", &.{"1/2"});
    try expectCall("1/3", "/", &.{"3"});
    try expectCall("-1/3", "/", &.{"-3"});
    // R7RS 6.2.6 の例。
    try expectCall("3/20", "/", &.{ "3", "4", "5" });
    try expectCall("1/3", "/", &.{ "1", "3" });
    try expectCall("3", "/", &.{ "6", "2" });
    try expectCall("1/18446744073709551616", "/", &.{"18446744073709551616"});
}

test "/ gives an inexact result when an argument is inexact, and an infinity for an inexact zero" {
    try expectCall("0.5", "/", &.{ "1", "2.0" });
    try expectCall("+inf.0", "/", &.{ "1", "0.0" });
    try expectCall("-inf.0", "/", &.{ "1", "-0.0" });
    try expectCall("+inf.0", "/", &.{"0.0"});
    try expectCall("2.0", "/", &.{"0.5"});
}

test "/ reports an exact zero divisor, whatever the dividend, and checks the types first" {
    for ([_][]const []const u8{
        &.{"0"},
        &.{ "1", "0" },
        &.{ "1.5", "0" },
        &.{ "1/2", "0" },
        &.{ "18446744073709551616", "0" },
        &.{ "1", "2", "0" },
        &.{ "0.0", "0" },
    }) |texts| {
        var f: test_support.Fixture = undefined;
        f.init();
        defer f.deinit();
        var args: [4]Value = undefined;
        for (texts, 0..) |t, i| args[i] = (try number.parse(f.services.heap, t, 10)).?;
        try std.testing.expectError(error.DivisionByZero, f.call(&primitives, "/", args[0..texts.len]));
    }
    const bad = [_]Value{ .fromFixnum(1), .fromFixnum(0), .unspecified_value };
    try std.testing.expectError(error.WrongType, callWith("/", &bad));
}

test "an exact and an inexact number give an inexact result, and the sign of an inexact zero is kept" {
    try expectCall("3.0", "+", &.{ "1.5", "1", "1/2" });
    try expectCall("2", "*", &.{ "1/2", "4" });
    try expectCall("-1.5", "-", &.{"1.5"});
    try expectCall("-0.0", "-", &.{"0.0"});
    try expectCall("0.0", "-", &.{"-0.0"});
    try expectCall("-0.0", "+", &.{"-0.0"});
    try expectCall("-0.0", "*", &.{"-0.0"});
    try expectCall("0.0", "+", &.{ "-0.0", "0" });
    try expectCall("19/2", "-", &.{ "10", "1/2" });
    try expectCall("9.5", "-", &.{ "10", "0.5" });
    try expectCall("+nan.0", "*", &.{ "0", "+inf.0" });
}

test "an operation on bignums and ratios stays exact, and normalizes" {
    try expectCall("18446744073709551616", "*", &.{ "4294967296", "4294967296" });
    try expectCall("1", "-", &.{ "18446744073709551617", "18446744073709551616" });
    try expectCall("1", "+", &.{ "1/3", "1/3", "1/3" });
    try expectCall("5/6", "+", &.{ "1/2", "1/3" });
    try expectCall("0", "*", &.{ "1/3", "0", "18446744073709551616" });
}

test "comparisons are exact across exactness, so that = is transitive" {
    try expectCall("#t", "=", &.{ "1", "1.0", "2/2" });
    try expectCall("#f", "=", &.{ "9007199254740993", "9007199254740992.0" });
    try expectCall("#t", "<", &.{ "9007199254740992.0", "9007199254740993" });
    try expectCall("#t", "<", &.{ "1", "2.5", "3", "7/2", "+inf.0" });
    try expectCall("#f", "<", &.{ "1", "2.5", "2.5" });
    try expectCall("#t", "<=", &.{ "1", "1.0", "3/2" });
    try expectCall("#t", ">", &.{ "+inf.0", "18446744073709551616", "1/2", "-0.5", "-inf.0" });
    try expectCall("#t", ">=", &.{ "2", "2.0", "1" });
    try expectCall("#t", "=", &.{ "0", "-0.0", "0.0" });
    try expectCall("#t", "=", &.{ "18446744073709551616", "1.8446744073709552e19" });
}

test "a comparison with a NaN is false, whatever the operator and the other arguments" {
    for ([_][]const u8{ "=", "<", ">", "<=", ">=" }) |name| {
        try expectCall("#f", name, &.{ "+nan.0", "+nan.0" });
        try expectCall("#f", name, &.{ "1", "+nan.0" });
        try expectCall("#f", name, &.{ "+nan.0", "18446744073709551616" });
        try expectCall("#f", name, &.{ "1", "+nan.0", "1" });
    }
    // 組が1つでも成り立たなければ偽。NaN が前にあっても、後の組を含めて検査する。
    try expectCall("#f", "<", &.{ "1", "+nan.0", "3" });
}

test "arithmetic checks the type of every argument" {
    for ([_][]const u8{ "-", "/", "*", "+" }) |name| {
        const args = [_]Value{ .fromFixnum(1), .fromFixnum(2), .unspecified_value };
        try std.testing.expectError(error.WrongType, callWith(name, &args));
        const first = [_]Value{.empty_list_value};
        try std.testing.expectError(error.WrongType, callWith(name, &first));
    }
}

const min_i64 = std.math.minInt(i64);
const max_i64 = std.math.maxInt(i64);

/// A pair of operands, and what each division primitive gives for it.
const DivisionCase = struct { n: i64, d: i64, quotient: i64, remainder: i64, modulo: i64 };

test "the division primitives round as the report says in all four combinations of signs" {
    // 原文(R7RS 6.2.6)の例は、13 と 4 の符号違いの4通りである。
    const cases = [_]DivisionCase{
        .{ .n = 13, .d = 4, .quotient = 3, .remainder = 1, .modulo = 1 },
        .{ .n = -13, .d = 4, .quotient = -3, .remainder = -1, .modulo = 3 },
        .{ .n = 13, .d = -4, .quotient = -3, .remainder = 1, .modulo = -3 },
        .{ .n = -13, .d = -4, .quotient = 3, .remainder = -1, .modulo = -1 },
    };
    for (cases) |c| {
        try std.testing.expectEqual(c.quotient, try callInt("quotient", &.{ c.n, c.d }));
        try std.testing.expectEqual(c.remainder, try callInt("remainder", &.{ c.n, c.d }));
        try std.testing.expectEqual(c.modulo, try callInt("modulo", &.{ c.n, c.d }));
    }
}

test "the division primitives agree when the division is exact, whatever the signs" {
    for ([_]i64{ 12, -12 }) |n| {
        for ([_]i64{ 4, -4 }) |d| {
            try std.testing.expectEqual(@divExact(n, d), try callInt("quotient", &.{ n, d }));
            try std.testing.expectEqual(0, try callInt("remainder", &.{ n, d }));
            try std.testing.expectEqual(0, try callInt("modulo", &.{ n, d }));
        }
    }
}

test "the division primitives give a dividend smaller than the divisor in the way their rules say" {
    try std.testing.expectEqual(0, try callInt("quotient", &.{ -3, 7 }));
    try std.testing.expectEqual(-3, try callInt("remainder", &.{ -3, 7 }));
    try std.testing.expectEqual(4, try callInt("modulo", &.{ -3, 7 }));
    try std.testing.expectEqual(-4, try callInt("modulo", &.{ 3, -7 }));
    try std.testing.expectEqual(3, try callInt("modulo", &.{ 3, 7 }));
}

test "the division primitives satisfy their defining identities over a range of operands" {
    var n: i64 = -20;
    while (n <= 20) : (n += 1) {
        var d: i64 = -7;
        while (d <= 7) : (d += 1) {
            if (d == 0) continue;
            const q = try callInt("quotient", &.{ n, d });
            const r = try callInt("remainder", &.{ n, d });
            const m = try callInt("modulo", &.{ n, d });
            // n = d * q + r で、r の符号は n に従い、絶対値は d より小さい。
            try std.testing.expectEqual(n, d * q + r);
            try std.testing.expect(@abs(r) < @abs(d));
            try std.testing.expect(r == 0 or (r < 0) == (n < 0));
            // m は n と d の倍数だけ違い、符号は d に従い、絶対値は d より小さい。
            try std.testing.expectEqual(0, @rem(m - n, d));
            try std.testing.expect(@abs(m) < @abs(d));
            try std.testing.expect(m == 0 or (m < 0) == (d < 0));
        }
    }
}

test "the division primitives hold at the ends of the fixnum range" {
    try std.testing.expectEqual(max_i64, try callInt("quotient", &.{ max_i64, 1 }));
    try std.testing.expectEqual(min_i64, try callInt("quotient", &.{ min_i64, 1 }));
    try std.testing.expectEqual(-max_i64, try callInt("quotient", &.{ max_i64, -1 }));
    try std.testing.expectEqual(0, try callInt("quotient", &.{ max_i64, min_i64 }));
    try std.testing.expectEqual(-1, try callInt("quotient", &.{ min_i64, max_i64 }));
    try std.testing.expectEqual(1, try callInt("quotient", &.{ min_i64, min_i64 }));
    try std.testing.expectEqual(max_i64, try callInt("remainder", &.{ max_i64, min_i64 }));
    try std.testing.expectEqual(-1, try callInt("remainder", &.{ min_i64, max_i64 }));
    try std.testing.expectEqual(0, try callInt("remainder", &.{ min_i64, min_i64 }));
    try std.testing.expectEqual(-1, try callInt("modulo", &.{ max_i64, min_i64 }));
    try std.testing.expectEqual(max_i64 - 1, try callInt("modulo", &.{ min_i64, max_i64 }));
    try std.testing.expectEqual(0, try callInt("modulo", &.{ min_i64, min_i64 }));
    try std.testing.expectEqual(1, try callInt("modulo", &.{ min_i64, 3 }));
    try std.testing.expectEqual(-2, try callInt("remainder", &.{ min_i64, 3 }));
}

test "quotient reports the one quotient that does not fit, and the others give zero" {
    // Why: 最小の整数を -1 で割った商は 2^63 で、固定長整数に収まらない。R7RS 6.2.3 は
    // 表現できない正確な結果を、実装上の制限の違反として報告することを許す。
    // 剰余は数学的に 0 で収まるので、エラーにしない。
    try std.testing.expectError(error.IntegerOverflow, call("quotient", &.{ min_i64, -1 }));
    try std.testing.expectEqual(0, try callInt("remainder", &.{ min_i64, -1 }));
    try std.testing.expectEqual(0, try callInt("modulo", &.{ min_i64, -1 }));
    // 隣の値は収まる。
    try std.testing.expectEqual(max_i64, try callInt("quotient", &.{ -max_i64, -1 }));
    try std.testing.expectEqual(-max_i64, try callInt("quotient", &.{ max_i64, -1 }));
}

test "the division primitives report a zero divisor, whatever the dividend" {
    for ([_][]const u8{ "quotient", "remainder", "modulo" }) |name| {
        for ([_]i64{ 0, 1, -1, 13, min_i64, max_i64 }) |n| {
            try std.testing.expectError(error.DivisionByZero, call(name, &.{ n, 0 }));
        }
    }
}

test "the division primitives check the type of both arguments before the divisor" {
    for ([_][]const u8{ "quotient", "remainder", "modulo" }) |name| {
        const bad_first = [_]Value{ .unspecified_value, .fromFixnum(0) };
        try std.testing.expectError(error.WrongType, callWith(name, &bad_first));
        const bad_second = [_]Value{ .fromFixnum(0), .fromBool(true) };
        try std.testing.expectError(error.WrongType, callWith(name, &bad_second));
        const bad_both = [_]Value{ .empty_list_value, .fromBool(false) };
        try std.testing.expectError(error.WrongType, callWith(name, &bad_both));
        // 型が正しいときに限って、0 除算になる。
        const good = [_]Value{ .fromFixnum(5), .fromFixnum(0) };
        try std.testing.expectError(error.DivisionByZero, callWith(name, &good));
    }
}

test "number? is true of every number of the tower and false of anything else" {
    for ([_]i64{ 0, 1, -1, min_i64, max_i64 }) |n| {
        try std.testing.expect(try callBool("number?", &.{n}));
    }
    for ([_][]const u8{ "1.5", "18446744073709551616", "1/3", "1+2i", "+inf.0", "+nan.0" }) |text| {
        var f: test_support.Fixture = undefined;
        f.init();
        defer f.deinit();
        const v = (try number.parse(f.services.heap, text, 10)).?;
        const r = try f.call(&primitives, "number?", &.{v});
        try std.testing.expect(r.isTrue());
    }
    const others = [_]Value{ .unspecified_value, .fromBool(true), .fromBool(false), .empty_list_value };
    for (others) |v| {
        const r = try callWith("number?", &.{v});
        try std.testing.expectEqual(.boolean, r.kind());
        try std.testing.expect(!r.isTrue());
    }
}
