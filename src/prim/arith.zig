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
};

/// `(+ z1 ...)`. With no argument the sum is 0 (R7RS 6.2.6).
fn add(args: []const Value) Error!Value {
    // Wide enough that no argument list a program can build overflows it, so
    // only the result is held to the fixnum range: `(+ max 1 -1)` is `max`.
    var sum: i128 = 0;
    for (args) |a| sum += a.asFixnum() orelse return error.WrongType;
    return .fromFixnum(std.math.cast(i64, sum) orelse return error.IntegerOverflow);
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

test "the table names each primitive once" {
    for (primitives, 0..) |p, i| {
        try std.testing.expect(p.name.len > 0);
        for (primitives[i + 1 ..]) |q| try std.testing.expect(!std.mem.eql(u8, p.name, q.name));
    }
    try std.testing.expectEqualStrings("+", primitives[0].name);
}
