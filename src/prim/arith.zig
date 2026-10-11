//! Arithmetic primitives.
//!
//! 段階4までは固定長の整数だけを扱う(docs/design/runtime.md, ADR-0007)。

const std = @import("std");
const value = @import("../value.zig");
const Value = value.Value;
const Primitive = value.Primitive;
const Services = value.Services;
const PrimitiveError = value.PrimitiveError;

pub const Error = PrimitiveError;

pub const primitives = [_]Primitive{
    .{ .name = "+", .min_args = 0, .max_args = null, .call = &add },
    .{ .name = "-", .min_args = 1, .max_args = null, .call = &subtract },
    .{ .name = "*", .min_args = 0, .max_args = null, .call = &multiply },
    .{ .name = "=", .min_args = 1, .max_args = null, .call = comparison(.eq) },
    .{ .name = "<", .min_args = 1, .max_args = null, .call = comparison(.lt) },
    .{ .name = ">", .min_args = 1, .max_args = null, .call = comparison(.gt) },
    .{ .name = "<=", .min_args = 1, .max_args = null, .call = comparison(.lte) },
    .{ .name = ">=", .min_args = 1, .max_args = null, .call = comparison(.gte) },
};

/// A result of the wide arithmetic, as a fixnum if it fits.
///
/// R7RS 6.2.3 は、表現できない正確な結果を、実装上の制限の違反として報告する
/// ことを実装に許している。多倍長整数は段階4で入る。
fn fromWide(n: i128) Error!Value {
    return .fromFixnum(std.math.cast(i64, n) orelse return error.IntegerOverflow);
}

/// `(+ z1 ...)`.
///
/// 引数がなければ和は 0 である(R7RS 6.2.6)。
fn add(_: *const Services, args: []const Value) Error!Value {
    // プログラムが作れるどの引数リストでもあふれない幅にしてある。このため
    // fixnum の範囲に収めるのは結果だけで、`(+ max 1 -1)` は `max` になる。
    var sum: i128 = 0;
    for (args) |a| sum += a.asFixnum() orelse return error.WrongType;
    return .fromFixnum(std.math.cast(i64, sum) orelse return error.IntegerOverflow);
}

/// `(- z)` negates, and `(- z1 z2 ...)` subtracts the rest from the first
/// (R7RS 6.2.6).
///
/// 引数は1つ以上要る。個数は機械が表の下限で検査するので、`args[0]` を読んでよい。
fn subtract(_: *const Services, args: []const Value) Error!Value {
    const first = args[0].asFixnum() orelse return error.WrongType;
    // 最小の fixnum の符号反転は収まらない。`(- 0 min)` も同じである。
    if (args.len == 1) return fromWide(-@as(i128, first));
    var difference: i128 = first;
    for (args[1..]) |a| difference -= a.asFixnum() orelse return error.WrongType;
    return fromWide(difference);
}

/// `(* z1 ...)`.
///
/// 引数がなければ積は 1 である(R7RS 6.2.6)。
///
/// 積は128ビットで保持する。fixnum に収まらない部分積を、`(* big big 0)` のように
/// 後の因数で収まる値に戻せるようにするためである。128ビットに収まらない部分積は、
/// 後に 0 が来れば結果が収まる場合でも、エラーとして報告する。
fn multiply(_: *const Services, args: []const Value) Error!Value {
    // 先にすべての引数を検査する。エラーが、前の因数がすでにあふれたかどうかに
    // 左右されないようにするためである。
    for (args) |a| _ = a.asFixnum() orelse return error.WrongType;
    var product: i128 = 1;
    for (args) |a| {
        const r = @mulWithOverflow(product, @as(i128, a.asFixnum().?));
        if (r[1] != 0) return error.IntegerOverflow;
        product = r[0];
    }
    return fromWide(product);
}

/// `(= z1 z2 z3 ...)` and its relatives (R7RS 6.2.6): true when `op` holds for
/// every neighbouring pair.
///
/// 引数が1つなら真、なしならエラー(機械が表の下限で報告する)である。最初に成り
/// 立たなかった組より後のものも含め、すべての引数が数であることを検査する。エラーが
/// 値に左右されないようにするためである。
fn comparison(comptime op: std.math.CompareOperator) Primitive.Fn {
    return &struct {
        fn call(_: *const Services, args: []const Value) Error!Value {
            for (args) |a| _ = a.asFixnum() orelse return error.WrongType;
            var holds = true;
            for (args[0 .. args.len - 1], args[1..]) |a, b| {
                if (!std.math.compare(a.asFixnum().?, op, b.asFixnum().?)) holds = false;
            }
            return .fromBool(holds);
        }
    }.call;
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

test "the primitives take the numbers of arguments the language gives them" {
    const Arity = struct { name: []const u8, min: u8, max: ?u8 };
    const expected = [_]Arity{
        .{ .name = "+", .min = 0, .max = null },
        .{ .name = "-", .min = 1, .max = null },
        .{ .name = "*", .min = 0, .max = null },
        .{ .name = "=", .min = 1, .max = null },
        .{ .name = "<", .min = 1, .max = null },
        .{ .name = ">", .min = 1, .max = null },
        .{ .name = "<=", .min = 1, .max = null },
        .{ .name = ">=", .min = 1, .max = null },
    };
    try std.testing.expectEqual(expected.len, primitives.len);
    for (expected, primitives) |e, p| {
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

test "+ reports a sum that does not fit rather than wrapping" {
    try std.testing.expectError(error.IntegerOverflow, call("+", &.{ std.math.maxInt(i64), 1 }));
    try std.testing.expectError(error.IntegerOverflow, call("+", &.{ std.math.minInt(i64), -1 }));
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

test "- reports a result that does not fit" {
    try std.testing.expectError(error.IntegerOverflow, call("-", &.{std.math.minInt(i64)}));
    try std.testing.expectError(error.IntegerOverflow, call("-", &.{ 0, std.math.minInt(i64) }));
    try std.testing.expectError(error.IntegerOverflow, call("-", &.{ std.math.maxInt(i64), -1 }));
    // 結果が範囲に戻るなら、途中の差は fixnum の範囲を出てよい。
    try std.testing.expectEqual(std.math.maxInt(i64), try callInt("-", &.{ std.math.maxInt(i64), -1, 1 }));
}

test "* multiplies, and of none is 1" {
    try std.testing.expectEqual(1, try callInt("*", &.{}));
    try std.testing.expectEqual(7, try callInt("*", &.{7}));
    try std.testing.expectEqual(24, try callInt("*", &.{ 2, 3, 4 }));
    try std.testing.expectEqual(-6, try callInt("*", &.{ -2, 3 }));
    try std.testing.expectEqual(0, try callInt("*", &.{ 0, 5 }));
}

test "* reports a product that does not fit, but lets a zero bring a partial one back" {
    try std.testing.expectError(error.IntegerOverflow, call("*", &.{ std.math.maxInt(i64), 2 }));
    try std.testing.expectError(error.IntegerOverflow, call("*", &.{ std.math.minInt(i64), -1 }));
    const big = std.math.maxInt(i64);
    try std.testing.expectEqual(0, try callInt("*", &.{ big, big, 0 }));
    try std.testing.expectError(error.IntegerOverflow, call("*", &.{ big, big, big }));
    // 2^128 は128ビットでは 0 に巻き戻り、fixnum に収まってしまう。
    const two_32 = 1 << 32;
    try std.testing.expectError(error.IntegerOverflow, call("*", &.{ two_32, two_32, two_32, two_32 }));
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
