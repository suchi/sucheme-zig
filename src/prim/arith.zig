//! Arithmetic primitives.
//!
//! 段階4までは固定長の整数だけを扱う(docs/design/runtime.md, ADR-0007)。

const std = @import("std");
const value = @import("../value.zig");
const Value = value.Value;
const Primitive = value.Primitive;
const PrimitiveError = value.PrimitiveError;

pub const Error = PrimitiveError;

pub const primitives = [_]Primitive{
    .{ .name = "+", .call = &add },
    .{ .name = "-", .call = &subtract },
    .{ .name = "*", .call = &multiply },
    .{ .name = "=", .call = comparison(.eq) },
    .{ .name = "<", .call = comparison(.lt) },
    .{ .name = ">", .call = comparison(.gt) },
    .{ .name = "<=", .call = comparison(.lte) },
    .{ .name = ">=", .call = comparison(.gte) },
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
fn add(args: []const Value) Error!Value {
    // プログラムが作れるどの引数リストでもあふれない幅にしてある。このため
    // fixnum の範囲に収めるのは結果だけで、`(+ max 1 -1)` は `max` になる。
    var sum: i128 = 0;
    for (args) |a| sum += a.asFixnum() orelse return error.WrongType;
    return .fromFixnum(std.math.cast(i64, sum) orelse return error.IntegerOverflow);
}

/// `(- z)` negates, and `(- z1 z2 ...)` subtracts the rest from the first
/// (R7RS 6.2.6).
///
/// 引数は1つ以上要る。
fn subtract(args: []const Value) Error!Value {
    if (args.len == 0) return error.WrongArgumentCount;
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
fn multiply(args: []const Value) Error!Value {
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
/// 引数が1つなら真、なしならエラーである。最初に成り立たなかった組より後の
/// ものも含め、すべての引数が数であることを検査する。エラーが値に左右されない
/// ようにするためである。
fn comparison(comptime op: std.math.CompareOperator) *const fn ([]const Value) Error!Value {
    return &struct {
        fn call(args: []const Value) Error!Value {
            if (args.len == 0) return error.WrongArgumentCount;
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

fn addAll(ns: []const i64) Error!i64 {
    var args: [8]Value = undefined;
    for (ns, 0..) |n, i| args[i] = .fromFixnum(n);
    return (try primitives[0].call(args[0..ns.len])).asFixnum().?;
}

test "+ adds its arguments, and of none is 0" {
    try std.testing.expectEqual(0, try addAll(&.{}));
    try std.testing.expectEqual(1, try addAll(&.{1}));
    try std.testing.expectEqual(15, try addAll(&.{ 1, 2, 3, 4, 5 }));
    try std.testing.expectEqual(-5, try addAll(&.{ 2, -7 }));
}

test "+ reports a sum that does not fit rather than wrapping" {
    try std.testing.expectError(error.IntegerOverflow, addAll(&.{ std.math.maxInt(i64), 1 }));
    try std.testing.expectError(error.IntegerOverflow, addAll(&.{ std.math.minInt(i64), -1 }));
}

test "+ holds only the result to the fixnum range, not a partial sum" {
    try std.testing.expectEqual(std.math.maxInt(i64), try addAll(&.{ std.math.maxInt(i64), 1, -1 }));
}

test "+ reports an argument that is not a number" {
    const args = [_]Value{ .fromFixnum(1), .unspecified_value };
    try std.testing.expectError(error.WrongType, primitives[0].call(&args));
}

/// Calls the primitive called `name` with fixnum arguments.
fn call(name: []const u8, ns: []const i64) Error!Value {
    var args: [8]Value = undefined;
    for (ns, 0..) |n, i| args[i] = .fromFixnum(n);
    for (primitives) |p| {
        if (std.mem.eql(u8, p.name, name)) return p.call(args[0..ns.len]);
    }
    unreachable;
}

fn callInt(name: []const u8, ns: []const i64) Error!i64 {
    return (try call(name, ns)).asFixnum().?;
}

fn callBool(name: []const u8, ns: []const i64) !bool {
    const v = try call(name, ns);
    try std.testing.expectEqual(.boolean, v.kind());
    return v.isTrue();
}

test "- negates one argument and subtracts the rest from the first" {
    try std.testing.expectEqual(-5, try callInt("-", &.{5}));
    try std.testing.expectEqual(0, try callInt("-", &.{0}));
    try std.testing.expectEqual(2, try callInt("-", &.{ 5, 3 }));
    try std.testing.expectEqual(4, try callInt("-", &.{ 10, 1, 2, 3 }));
    try std.testing.expectEqual(-5, try callInt("-", &.{ 0, 5 }));
}

test "- reports a result that does not fit, and needs an argument" {
    try std.testing.expectError(error.IntegerOverflow, call("-", &.{std.math.minInt(i64)}));
    try std.testing.expectError(error.IntegerOverflow, call("-", &.{ 0, std.math.minInt(i64) }));
    try std.testing.expectError(error.IntegerOverflow, call("-", &.{ std.math.maxInt(i64), -1 }));
    try std.testing.expectError(error.WrongArgumentCount, call("-", &.{}));
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
    const mul = primitives[2];
    try std.testing.expectEqualStrings("*", mul.name);
    try std.testing.expectError(error.WrongType, mul.call(&args));
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

test "a comparison of one number is true, of none is an error" {
    for ([_][]const u8{ "=", "<", ">", "<=", ">=" }) |name| {
        try std.testing.expect(try callBool(name, &.{5}));
        try std.testing.expectError(error.WrongArgumentCount, call(name, &.{}));
    }
}

test "a comparison checks the type of every argument, however the pairs came out" {
    for ([_][]const u8{ "=", "<", ">", "<=", ">=" }) |name| {
        for (primitives) |p| {
            if (!std.mem.eql(u8, p.name, name)) continue;
            // 最初の組ですでに答えは決まっている。3番目は数ではない。

            const args = [_]Value{ .fromFixnum(2), .fromFixnum(1), .unspecified_value };
            try std.testing.expectError(error.WrongType, p.call(&args));
        }
    }
}
