//! Arithmetic primitives. Fixed-length integers only until stage 4
//! (docs/design/runtime.md, ADR-0007).

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

/// A result of the wide arithmetic, as a fixnum if it fits (R7RS 6.2.3 lets an
/// implementation report an exact result it cannot represent as a violation of
/// an implementation restriction; bignums arrive in stage 4).
fn fromWide(n: i128) Error!Value {
    return .fromFixnum(std.math.cast(i64, n) orelse return error.IntegerOverflow);
}

/// `(+ z1 ...)`. With no argument the sum is 0 (R7RS 6.2.6).
fn add(args: []const Value) Error!Value {
    // Wide enough that no argument list a program can build overflows it, so
    // only the result is held to the fixnum range: `(+ max 1 -1)` is `max`.
    var sum: i128 = 0;
    for (args) |a| sum += a.asFixnum() orelse return error.WrongType;
    return .fromFixnum(std.math.cast(i64, sum) orelse return error.IntegerOverflow);
}

/// `(- z)` negates, and `(- z1 z2 ...)` subtracts the rest from the first
/// (R7RS 6.2.6). It takes at least one argument.
fn subtract(args: []const Value) Error!Value {
    if (args.len == 0) return error.WrongArgumentCount;
    const first = args[0].asFixnum() orelse return error.WrongType;
    // Negating the smallest fixnum does not fit, and nor does `(- 0 min)`.
    if (args.len == 1) return fromWide(-@as(i128, first));
    var difference: i128 = first;
    for (args[1..]) |a| difference -= a.asFixnum() orelse return error.WrongType;
    return fromWide(difference);
}

/// `(* z1 ...)`. With no argument the product is 1 (R7RS 6.2.6).
///
/// The product is kept in 128 bits so that a partial product that does not fit
/// a fixnum can still be brought back by a later factor, as in `(* big big 0)`.
/// A partial product that does not fit 128 bits is reported, even if a later
/// zero would have made the result fit.
fn multiply(args: []const Value) Error!Value {
    // Every argument is checked first, so the error does not depend on whether
    // an earlier factor already overflowed.
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
/// every neighbouring pair. One argument is true, none is an error. Every
/// argument is checked to be a number, including those after the first pair
/// that fails, so the error does not depend on the values.
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
    // A partial difference may leave the fixnum range if the result returns.
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
    // 2^128 wraps to 0 in 128 bits, which would fit a fixnum.
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
            // The first pair already decides the answer; the third is no number.
            const args = [_]Value{ .fromFixnum(2), .fromFixnum(1), .unspecified_value };
            try std.testing.expectError(error.WrongType, p.call(&args));
        }
    }
}

test "the table names each primitive once" {
    for (primitives, 0..) |p, i| {
        try std.testing.expect(p.name.len > 0);
        for (primitives[i + 1 ..]) |q| try std.testing.expect(!std.mem.eql(u8, p.name, q.name));
    }
    try std.testing.expectEqualStrings("+", primitives[0].name);
}
