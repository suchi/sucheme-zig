//! Arithmetic primitives.
//!
//! 四則と比較と `number?` は数値塔の実数(fixnum、bignum、ratnum、flonum)を扱い、
//! 計算は `num/ops.zig` が行う(docs/design/numerics-and-unicode.md)。整数除算の
//! 7個と `abs` も同じである。

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
    .{ .name = "quotient", .min_args = 2, .max_args = 2, .body = .{ .pure = division(.truncate_quotient) } },
    .{ .name = "remainder", .min_args = 2, .max_args = 2, .body = .{ .pure = division(.truncate_remainder) } },
    .{ .name = "modulo", .min_args = 2, .max_args = 2, .body = .{ .pure = division(.floor_remainder) } },
    .{ .name = "truncate-quotient", .min_args = 2, .max_args = 2, .body = .{ .pure = division(.truncate_quotient) } },
    .{ .name = "truncate-remainder", .min_args = 2, .max_args = 2, .body = .{ .pure = division(.truncate_remainder) } },
    .{ .name = "floor-quotient", .min_args = 2, .max_args = 2, .body = .{ .pure = division(.floor_quotient) } },
    .{ .name = "floor-remainder", .min_args = 2, .max_args = 2, .body = .{ .pure = division(.floor_remainder) } },
    .{ .name = "abs", .min_args = 1, .max_args = 1, .body = .{ .pure = &abs } },
    .{ .name = "number?", .min_args = 1, .max_args = 1, .body = .{ .pure = &isNumber } },
};

/// Checks that every argument is a real number: a fixnum, a bignum, a ratnum or a flonum.
///
/// 値によらず、すべての引数の型を先に検査する。エラーが、前の引数まででもう答えが決まった
/// かどうかや、途中の計算の結果に左右されないようにするためである。
fn requireReals(args: []const Value) Error!void {
    for (args) |a| switch (a.kind()) {
        .fixnum, .bignum, .ratnum, .flonum => {},
        else => return error.WrongType,
    };
}

/// Checks that every argument is a number, a complex one included.
fn requireNumbers(args: []const Value) Error!void {
    for (args) |a| if (!number.isNumber(a)) return error.WrongType;
}

/// `(+ z1 ...)`.
///
/// 引数がなければ和は 0 である(R7RS 6.2.6)。1つなら、その引数そのもの(`(+ -0.0)` は
/// `-0.0`)。
fn add(services: *const Services, args: []const Value) Error!Value {
    try requireNumbers(args);
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
    try requireNumbers(args);
    if (args.len == 1) return ops.negate(services.heap, args[0]);
    var difference = args[0];
    for (args[1..]) |a| difference = try ops.apply(services.heap, .sub, difference, a);
    return difference;
}

/// `(* z1 ...)`.
///
/// 引数がなければ積は 1 である(R7RS 6.2.6)。
fn multiply(services: *const Services, args: []const Value) Error!Value {
    try requireNumbers(args);
    if (args.len == 0) return .fromFixnum(1);
    var product = args[0];
    for (args[1..]) |a| product = try ops.apply(services.heap, .mul, product, a);
    return product;
}

/// `(/ z)` is the reciprocal, and `(/ z1 z2 ...)` divides the first by the rest (R7RS 6.2.6).
///
/// 正確な0で割ると `DivisionByZero` である。被除数が不正確でも同じ。引数は1つ以上要る。
fn divide(services: *const Services, args: []const Value) Error!Value {
    try requireNumbers(args);
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
/// `=` は複素数も取る。順序を決める `<` `>` `<=` `>=` は実数だけで、複素数は `WrongType`。
fn comparison(comptime op: std.math.CompareOperator) Primitive.Fn {
    return &struct {
        fn call(services: *const Services, args: []const Value) Error!Value {
            if (op == .eq) try requireNumbers(args) else try requireReals(args);
            var holds = true;
            for (args[0 .. args.len - 1], args[1..]) |a, b| {
                if (op == .eq) {
                    if (!try ops.numEqual(services.heap, a, b)) holds = false;
                    continue;
                }
                const order = try ops.compare(services.heap, a, b);
                if (order == null or !orderHolds(order.?, op)) holds = false;
            }
            return .fromBool(holds);
        }
    }.call;
}

fn orderHolds(order: std.math.Order, comptime op: std.math.CompareOperator) bool {
    return switch (op) {
        // `=` は `numEqual` で比べるので、順序を決める演算子だけがここに来る。
        .eq, .neq => unreachable,
        .lt => order == .lt,
        .lte => order != .gt,
        .gt => order == .gt,
        .gte => order != .lt,
    };
}

/// An integer division primitive of the kind `kind` (R7RS 6.2.6).
///
/// 整数は、正確な整数と、整数値の flonum である。どちらかが不正確なら結果も不正確で、
/// 除数が正確な0でも不正確な0でも `DivisionByZero` になる。bignum も扱う。
///
/// 検査の順序は、型、除数の 0 である。両方の引数の型を先に検査し、エラーが値に左右
/// されないようにする(`*` と比較の方針)。個数は機械が表で検査する。
fn division(comptime kind: ops.Division) Primitive.Fn {
    return &struct {
        fn call(s: *const Services, args: []const Value) Error!Value {
            if (!ops.isIntegerNumber(args[0]) or !ops.isIntegerNumber(args[1])) return error.WrongType;
            return ops.integerDivide(s.heap, kind, args[0], args[1]);
        }
    }.call;
}

/// `(abs x)`: the absolute value of the real number `x` (R7RS 6.2.6).
fn abs(s: *const Services, args: []const Value) Error!Value {
    try requireReals(args);
    return ops.absNumber(s.heap, args[0]);
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
        .{ .name = "truncate-quotient", .min = 2, .max = 2 },
        .{ .name = "truncate-remainder", .min = 2, .max = 2 },
        .{ .name = "floor-quotient", .min = 2, .max = 2 },
        .{ .name = "floor-remainder", .min = 2, .max = 2 },
        .{ .name = "abs", .min = 1, .max = 1 },
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

test "+ - * / take complex numbers, and the result is real when the imaginary part comes to zero" {
    try expectCall("4+6i", "+", &.{ "1+2i", "3+4i" });
    try expectCall("3+3i", "+", &.{ "1+2i", "1", "1+i" });
    try expectCall("2", "+", &.{ "1+2i", "1-2i" });
    try expectCall("-5+10i", "*", &.{ "1+2i", "3+4i" });
    try expectCall("5", "*", &.{ "1+2i", "1-2i" });
    try expectCall("-2-2i", "-", &.{ "1+2i", "3+4i" });
    try expectCall("-1-2i", "-", &.{"1+2i"});
    try expectCall("1+2i", "+", &.{"1+2i"});
    try expectCall("11/25+2/25i", "/", &.{ "1+2i", "3+4i" });
    try expectCall("-i", "/", &.{"+i"});
    try expectCall("1/5-2/5i", "/", &.{"1+2i"});
    try expectCall("1.5+2.0i", "+", &.{ "1+2i", "0.5" });
}

test "= takes complex numbers, and the order comparisons take real numbers only" {
    try expectCall("#t", "=", &.{ "1+2i", "1+2i", "1+2i" });
    try expectCall("#f", "=", &.{ "1+2i", "1+2i", "1+3i" });
    try expectCall("#f", "=", &.{ "1+2i", "1" });
    try expectCall("#t", "=", &.{ "1+2i", "1.0+2.0i" });
    try expectCall("#t", "=", &.{"1+2i"});
    for ([_][]const u8{ "<", ">", "<=", ">=" }) |name| {
        var f: test_support.Fixture = undefined;
        f.init();
        defer f.deinit();
        const z = (try number.parse(f.services.heap, "1+2i", 10)).?;
        try std.testing.expectError(error.WrongType, f.call(&primitives, name, &.{ .fromFixnum(0), z }));
        try std.testing.expectError(error.WrongType, f.call(&primitives, name, &.{z}));
        // 型は、組の答えが決まっていても、すべての引数について検査する。
        try std.testing.expectError(error.WrongType, f.call(&primitives, name, &.{ .fromFixnum(2), .fromFixnum(1), z }));
    }
}

test "a complex number divided by an exact zero is an error" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    const z = (try number.parse(f.services.heap, "1+2i", 10)).?;
    try std.testing.expectError(error.DivisionByZero, f.call(&primitives, "/", &.{ z, .fromFixnum(0) }));
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

test "the quotient of the least fixnum and -1 is a bignum, and the remainders are zero" {
    try expectCallInts("9223372036854775808", "quotient", &.{ min_i64, -1 });
    try expectCallInts("9223372036854775808", "floor-quotient", &.{ min_i64, -1 });
    try expectCallInts("9223372036854775808", "truncate-quotient", &.{ min_i64, -1 });
    for ([_][]const u8{ "remainder", "modulo", "floor-remainder", "truncate-remainder" }) |name| {
        try expectCallInts("0", name, &.{ min_i64, -1 });
    }
    // 隣の値は fixnum に収まる。
    try std.testing.expectEqual(max_i64, try callInt("quotient", &.{ -max_i64, -1 }));
    try std.testing.expectEqual(-max_i64, try callInt("quotient", &.{ max_i64, -1 }));
}

test "the division primitives take bignums" {
    const big = "18446744073709551616"; // 2^64
    try expectCall("4611686018427387904", "quotient", &.{ big, "4" });
    try expectCall("0", "remainder", &.{ big, "4" });
    try expectCall("-4611686018427387904", "floor-quotient", &.{ "-" ++ big, "4" });
    try expectCall("-4611686018427387905", "floor-quotient", &.{ "-18446744073709551617", "4" });
    try expectCall("-4611686018427387904", "truncate-quotient", &.{ "-18446744073709551617", "4" });
    try expectCall("3", "modulo", &.{ "-18446744073709551617", "4" });
    try expectCall("-1", "remainder", &.{ "-18446744073709551617", "4" });
    try expectCall("-3", "modulo", &.{ "18446744073709551617", "-4" });
    try expectCall("0", "quotient", &.{ "5", big });
    try expectCall("5", "remainder", &.{ "5", big });
    try expectCall("18446744073709551611", "modulo", &.{ "-5", big });
    try expectCall("-18446744073709551611", "modulo", &.{ "5", "-" ++ big });
    try expectCall("1", "quotient", &.{ big, big });
}

test "the division primitives take integral flonums, and give flonums" {
    // R7RS 6.2.6: (truncate/ -5.0 -2) は 2.0 と -1.0 を返す。
    try expectCall("2.0", "truncate-quotient", &.{ "-5.0", "-2" });
    try expectCall("-1.0", "truncate-remainder", &.{ "-5.0", "-2" });
    try expectCall("2.0", "floor-quotient", &.{ "-5.0", "-2" });
    try expectCall("-3.0", "floor-quotient", &.{ "5.0", "-2.0" });
    try expectCall("-1.0", "floor-remainder", &.{ "5.0", "-2.0" });
    try expectCall("1.0", "modulo", &.{ "-5", "2.0" });
    try expectCall("-2.0", "quotient", &.{ "-5", "2.0" });
    try expectCall("3.0", "quotient", &.{ "7.0", "2" });
}

test "the division primitives give the signed zero the rules of the signs give" {
    try expectCall("0.0", "quotient", &.{ "1.0", "5.0" });
    try expectCall("-0.0", "quotient", &.{ "1.0", "-5.0" });
    try expectCall("-0.0", "quotient", &.{ "-1.0", "5.0" });
    try expectCall("0.0", "quotient", &.{ "-1.0", "-5.0" });
    try expectCall("0.0", "remainder", &.{ "4.0", "2.0" });
    try expectCall("-0.0", "remainder", &.{ "-4.0", "2.0" });
    try expectCall("0.0", "modulo", &.{ "4.0", "2.0" });
    try expectCall("-0.0", "modulo", &.{ "4.0", "-2.0" });
    try expectCall("-0.0", "modulo", &.{ "-4.0", "-2.0" });
    try expectCall("0.0", "modulo", &.{ "-0.0", "2.0" });
    try expectCall("0.0", "quotient", &.{ "-0.0", "-2.0" });
    try expectCall("-0.0", "quotient", &.{ "-0.0", "2.0" });
    try expectCall("0.0", "modulo", &.{ "-4", "2.0" });
}

test "a floor remainder that a flonum cannot hold is rounded" {
    // 真の値 1e25 - 5 は flonum で表せないので、補正した余りは 1e25 に丸まる。
    try expectCall("1.0e25", "modulo", &.{ "-5", "1e25" });
    try expectCall("-1.0e25", "modulo", &.{ "5", "-1e25" });
    // 結果が除数と等しくなる(0 <= r < |d| に反する)。
    try expectCall("18446744073709552000.0", "modulo", &.{ "-5.0", "18446744073709551616" });
    // truncate 系の余りは、この場合も正確である。
    try expectCall("-5.0", "remainder", &.{ "-5.0", "18446744073709551616" });
}

test "the division primitives are exact for flonums beyond 2^53" {
    // 2^60 は flonum に正確に表せる。
    // 2^60 mod 3 = 1。2^60 / 3 は正確には表せないが、剰余は正確である。
    try expectCall("1.0", "remainder", &.{ "1152921504606846976.0", "3.0" });
    try expectCall("-1.0", "remainder", &.{ "-1152921504606846976.0", "3.0" });
    try expectCall("2.0", "modulo", &.{ "-1152921504606846976.0", "3.0" });
    try expectCall("-2.0", "modulo", &.{ "1152921504606846976.0", "-3.0" });
    try expectCall("0.0", "remainder", &.{ "1152921504606846976.0", "1024.0" });
    try expectCall("1125899906842624.0", "quotient", &.{ "1152921504606846976.0", "1024" });
    try expectCall("0.0", "quotient", &.{ "5.0", "1152921504606846976.0" });
    try expectCall("-0.0", "quotient", &.{ "-5.0", "1152921504606846976.0" });
    try expectCall("-1.0", "floor-quotient", &.{ "-5.0", "1152921504606846976.0" });
}

test "floor-quotient rounds down for fixnums of every sign" {
    try expectCallInts("-3", "floor-quotient", &.{ -5, 2 });
    try expectCallInts("-3", "floor-quotient", &.{ 5, -2 });
    try expectCallInts("2", "floor-quotient", &.{ -5, -2 });
    try expectCallInts("2", "floor-quotient", &.{ 5, 2 });
    try expectCallInts("-1", "floor-quotient", &.{ -1, 5 });
    try expectCallInts("-3", "truncate-quotient", &.{ -7, 2 });
}

test "a flonum above 2^53 is divided exactly, not by the flonum quotient" {
    // 2^60 / 1025 は、浮動小数点の商 2^60 / 1025 では整数にならない。
    try expectCall("1124801467909119.0", "quotient", &.{ "1152921504606846976.0", "1025.0" });
    try expectCall("1.0", "remainder", &.{ "1152921504606846976.0", "1025.0" });
    // 2^54 の近くでは、被除数から余りを引く浮動小数点の引き算が丸められ、商が整数にならない。
    try expectCall("3002399751580331.0", "quotient", &.{ "18014398509481988.0", "6.0" });
    try expectCall("2.0", "remainder", &.{ "18014398509481988.0", "6.0" });
    // 除数だけが 2^53 以上の場合は、被除数が小さい。
    try expectCall("0.0", "quotient", &.{ "1025.0", "1152921504606846976.0" });
}

test "the signed zero of a division through the exact path follows the signs" {
    const two60 = "1152921504606846976.0";
    const two61 = "2305843009213693952.0";
    try expectCall("-0.0", "quotient", &.{ "-" ++ two60, two61 });
    try expectCall("-0.0", "quotient", &.{ two60, "-" ++ two61 });
    try expectCall("0.0", "quotient", &.{ "-" ++ two60, "-" ++ two61 });
    try expectCall("0.0", "quotient", &.{ two60, two61 });
    try expectCall("-0.0", "remainder", &.{ "-" ++ two61, two60 });
    try expectCall("0.0", "remainder", &.{ two61, "-" ++ two60 });
    try expectCall("0.0", "modulo", &.{ "-" ++ two61, two60 });
    try expectCall("-0.0", "modulo", &.{ two61, "-" ++ two60 });
    try expectCall("-0.0", "modulo", &.{ "-" ++ two61, "-" ++ two60 });
    // 被除数が bignum(正確)のとき。
    try expectCall("-0.0", "quotient", &.{ "-18446744073709551616", "1180591620717411303424.0" });
    try expectCall("0.0", "quotient", &.{ "18446744073709551616", "1180591620717411303424.0" });
}

test "the division primitives reject a non-integer, an infinity and a NaN" {
    for ([_][]const u8{ "quotient", "remainder", "modulo", "floor-quotient", "truncate-remainder" }) |name| {
        for ([_][]const u8{ "1.5", "1/2", "+inf.0", "-inf.0", "+nan.0", "1+2i" }) |bad| {
            var f: test_support.Fixture = undefined;
            f.init();
            defer f.deinit();
            const v = (try number.parse(f.services.heap, bad, 10)).?;
            try std.testing.expectError(error.WrongType, f.call(&primitives, name, &.{ v, .fromFixnum(2) }));
            try std.testing.expectError(error.WrongType, f.call(&primitives, name, &.{ .fromFixnum(2), v }));
            try std.testing.expectError(error.WrongType, f.call(&primitives, name, &.{ v, .fromFixnum(0) }));
        }
    }
}

test "a zero divisor, exact or not, is an error for every kind of dividend" {
    for ([_][]const u8{ "quotient", "remainder", "modulo", "floor-quotient", "floor-remainder", "truncate-quotient", "truncate-remainder" }) |name| {
        for ([_][]const u8{ "0", "5", "-5.0", "18446744073709551616" }) |n| {
            for ([_][]const u8{ "0", "0.0", "-0.0" }) |z| {
                var f: test_support.Fixture = undefined;
                f.init();
                defer f.deinit();
                const a = (try number.parse(f.services.heap, n, 10)).?;
                const b = (try number.parse(f.services.heap, z, 10)).?;
                try std.testing.expectError(error.DivisionByZero, f.call(&primitives, name, &.{ a, b }));
            }
        }
    }
}

test "abs gives the magnitude of any real number" {
    try expectCall("5", "abs", &.{"-5"});
    try expectCall("5", "abs", &.{"5"});
    try expectCall("0", "abs", &.{"0"});
    try expectCall("9223372036854775808", "abs", &.{"-9223372036854775808"});
    try expectCall("18446744073709551616", "abs", &.{"-18446744073709551616"});
    try expectCall("18446744073709551616", "abs", &.{"18446744073709551616"});
    try expectCall("1/3", "abs", &.{"-1/3"});
    try expectCall("1/3", "abs", &.{"1/3"});
    try expectCall("2.5", "abs", &.{"-2.5"});
    try expectCall("0.0", "abs", &.{"-0.0"});
    try expectCall("+inf.0", "abs", &.{"-inf.0"});
    try expectCall("+nan.0", "abs", &.{"+nan.0"});
}

test "abs rejects a complex number" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    const z = (try number.parse(f.services.heap, "1+2i", 10)).?;
    try std.testing.expectError(error.WrongType, f.call(&primitives, "abs", &.{z}));
    try std.testing.expectError(error.WrongType, f.call(&primitives, "abs", &.{.fromBool(true)}));
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
