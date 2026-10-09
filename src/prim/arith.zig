//! Arithmetic primitives. Fixed-length integers only until stage 4
//! (docs/design/runtime.md, ADR-0007).

const std = @import("std");
const Value = @import("../value.zig").Value;

pub const Error = error{
    /// An argument is not a number.
    WrongType,
    /// The exact result does not fit a fixnum. R7RS 6.2.3 lets an
    /// implementation report this as a violation of an implementation
    /// restriction; bignums arrive in stage 4.
    IntegerOverflow,
};

/// A procedure implemented in Zig.
///
/// Slice 1a has no procedure values, so a primitive is found by name where a
/// call names it. It becomes a heap object in value.zig when slice 1d brings
/// procedures as values.
pub const Primitive = struct {
    name: []const u8,
    call: *const fn (args: []const Value) Error!Value,
};

pub const primitives = [_]Primitive{
    .{ .name = "+", .call = add },
};

/// The primitive named `name`, or null.
pub fn lookup(name: []const u8) ?*const Primitive {
    for (&primitives) |*p| {
        if (std.mem.eql(u8, p.name, name)) return p;
    }
    return null;
}

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
    return (try lookup("+").?.call(args[0..ns.len])).asFixnum().?;
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
    try std.testing.expectError(error.WrongType, lookup("+").?.call(&args));
}

test "lookup finds + and nothing it does not define" {
    try std.testing.expect(lookup("+") != null);
    try std.testing.expect(lookup("-") == null);
    try std.testing.expect(lookup("") == null);
}
