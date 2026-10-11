//! Boolean primitives (R7RS 6.3): `not` and `boolean?`.

const std = @import("std");
const value = @import("../value.zig");
const Value = value.Value;
const Primitive = value.Primitive;
const Services = value.Services;
const PrimitiveError = value.PrimitiveError;

pub const Error = PrimitiveError;

pub const primitives = [_]Primitive{
    .{ .name = "not", .min_args = 1, .max_args = 1, .call = &not },
    .{ .name = "boolean?", .min_args = 1, .max_args = 1, .call = &isBoolean },
};

/// `(not obj)`: true only of `#f` (R7RS 6.3).
fn not(_: *const Services, args: []const Value) Error!Value {
    return .fromBool(!args[0].isTrue());
}

/// `(boolean? obj)`: true of `#t` and `#f` only (R7RS 6.3).
fn isBoolean(_: *const Services, args: []const Value) Error!Value {
    return .fromBool(args[0].kind() == .boolean);
}

test {
    std.testing.refAllDecls(@This());
}

const test_support = @import("test_support.zig");

fn callWith(name: []const u8, arg: Value) !bool {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    const v = try f.call(&primitives, name, &.{arg});
    try std.testing.expectEqual(.boolean, v.kind());
    return v.isTrue();
}

/// A value of each kind a program can hold, except the two booleans.
fn others(f: *test_support.Fixture) ![8]Value {
    const nop = struct {
        fn call(_: *const Services, _: []const Value) PrimitiveError!Value {
            return .unspecified_value;
        }
    }.call;
    const prim = struct {
        const p: Primitive = .{ .name = "p", .min_args = 0, .max_args = 0, .call = &nop };
    };
    return .{
        .fromFixnum(0),
        .empty_list_value,
        .fromSymbol(@fromBackingInt(@intCast(0))),
        .fromCharacter('f'),
        .unspecified_value,
        .fromPrimitive(&prim.p),
        .fromString(try f.heap.createString("")),
        try f.heap.cons(.fromBool(false), .fromBool(false)),
    };
}

test "the primitives take one argument" {
    const expected = [_][]const u8{ "not", "boolean?" };
    try std.testing.expectEqual(expected.len, primitives.len);
    for (expected, primitives) |name, p| {
        try std.testing.expectEqualStrings(name, p.name);
        try std.testing.expectEqual(1, p.min_args);
        try std.testing.expectEqual(1, p.max_args.?);
    }
}

test "not is true of #f and of nothing else" {
    try std.testing.expect(try callWith("not", .fromBool(false)));
    try std.testing.expect(!try callWith("not", .fromBool(true)));
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    for (try others(&f)) |v| {
        try std.testing.expect(!try callWith("not", v));
    }
}

test "boolean? is true of #t and #f and of nothing else" {
    try std.testing.expect(try callWith("boolean?", .fromBool(false)));
    try std.testing.expect(try callWith("boolean?", .fromBool(true)));
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    for (try others(&f)) |v| {
        try std.testing.expect(!try callWith("boolean?", v));
    }
}
