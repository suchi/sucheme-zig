//! End-of-file object primitives (R7RS 6.13.2): `eof-object` and `eof-object?`.
//!
//! EOF の値は `Value` の即値で、どの EOF の値も同じである(R7RS は一意であることを
//! 求めない)。ポートを読む手続きが返す値で、`read` が読める値ではないので、リーダは
//! 作らない。ポートの手続きは段階5で入る。

const std = @import("std");
const value = @import("../value.zig");
const Value = value.Value;
const Primitive = value.Primitive;
const Services = value.Services;
const PrimitiveError = value.PrimitiveError;

pub const Error = PrimitiveError;

pub const primitives = [_]Primitive{
    .{ .name = "eof-object", .min_args = 0, .max_args = 0, .body = .{ .pure = &eofObject } },
    .{ .name = "eof-object?", .min_args = 1, .max_args = 1, .body = .{ .pure = &isEofObject } },
};

/// `(eof-object)`: an end-of-file object.
fn eofObject(_: *const Services, _: []const Value) Error!Value {
    return .eof_value;
}

/// `(eof-object? obj)`: whether `obj` is an end-of-file object.
fn isEofObject(_: *const Services, args: []const Value) Error!Value {
    return .fromBool(args[0].kind() == .eof);
}

test {
    std.testing.refAllDecls(@This());
}

const test_support = @import("test_support.zig");

test "eof-object takes no arguments and eof-object? takes one" {
    try std.testing.expectEqual(2, primitives.len);
    try std.testing.expectEqualStrings("eof-object", primitives[0].name);
    try std.testing.expectEqual(0, primitives[0].min_args);
    try std.testing.expectEqual(0, primitives[0].max_args.?);
    try std.testing.expectEqualStrings("eof-object?", primitives[1].name);
    try std.testing.expectEqual(1, primitives[1].min_args);
    try std.testing.expectEqual(1, primitives[1].max_args.?);
}

test "eof-object returns the end-of-file object, which eof-object? is true of" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    const eof = try f.call(&primitives, "eof-object", &.{});
    try std.testing.expectEqual(value.Kind.eof, eof.kind());
    try std.testing.expect((try f.call(&primitives, "eof-object?", &.{eof})).isTrue());
    // どの EOF の値も同じである。
    const again = try f.call(&primitives, "eof-object", &.{});
    try std.testing.expect(eof.isEqv(again));
    try std.testing.expect(eof.isEq(again));
    // 何も確保しない。
    try std.testing.expectEqual(0, f.heap.count);
}

test "eof-object? is false of everything that is not the end-of-file object" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    const not_eof = [_]Value{
        .fromFixnum(0),
        .fromBool(false),
        .fromBool(true),
        .empty_list_value,
        .unspecified_value,
        .uninitialized_value,
        .fromCharacter('a'),
        .fromSymbol(@fromBackingInt(@intCast(0))),
        try f.heap.cons(.eof_value, .eof_value),
        .fromString(try f.heap.createString("")),
        .fromVector(try f.heap.createVector(&.{.eof_value})),
    };
    for (not_eof) |v| {
        const answer = try f.call(&primitives, "eof-object?", &.{v});
        try std.testing.expectEqual(value.Kind.boolean, answer.kind());
        try std.testing.expect(!answer.isTrue());
    }
}

test "the end-of-file object is not equal to the values it could be taken for" {
    const eof: Value = .eof_value;
    try std.testing.expect(!eof.isEqv(.empty_list_value));
    try std.testing.expect(!eof.isEqv(.fromBool(false)));
    try std.testing.expect(!eof.isEqv(.unspecified_value));
    try std.testing.expect(!eof.isEqv(.uninitialized_value));
    try std.testing.expect(!eof.isEqv(.fromFixnum(0)));
    try std.testing.expect(!Value.empty_list_value.isEqv(eof));
    try std.testing.expect(!Value.fromBool(false).isEqv(eof));
    try std.testing.expect(!Value.unspecified_value.isEqv(eof));
    try std.testing.expect(!Value.uninitialized_value.isEqv(eof));
    try std.testing.expect(!Value.fromFixnum(0).isEqv(eof));
}
