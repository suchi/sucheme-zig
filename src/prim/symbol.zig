//! Symbol primitives (R7RS 6.5): `symbol?`.
//!
//! シンボルを作る・名前を取る手続きは、シンボル表を弱い表にする判断(docs/design/runtime.md)と
//! 同時に、段階3で決める。

const std = @import("std");
const value = @import("../value.zig");
const Value = value.Value;
const Primitive = value.Primitive;
const Services = value.Services;
const PrimitiveError = value.PrimitiveError;

pub const Error = PrimitiveError;

pub const primitives = [_]Primitive{
    .{ .name = "symbol?", .min_args = 1, .max_args = 1, .call = &isSymbol },
};

/// `(symbol? obj)`: true of symbols only (R7RS 6.5).
fn isSymbol(_: *const Services, args: []const Value) Error!Value {
    return .fromBool(args[0].kind() == .symbol);
}

test {
    std.testing.refAllDecls(@This());
}

const test_support = @import("test_support.zig");

fn callWith(arg: Value) !bool {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    const v = try f.call(&primitives, "symbol?", &.{arg});
    try std.testing.expectEqual(.boolean, v.kind());
    return v.isTrue();
}

test "symbol? takes one argument" {
    try std.testing.expectEqual(1, primitives.len);
    try std.testing.expectEqualStrings("symbol?", primitives[0].name);
    try std.testing.expectEqual(1, primitives[0].min_args);
    try std.testing.expectEqual(1, primitives[0].max_args.?);
}

test "symbol? is true of symbols and of nothing else" {
    try std.testing.expect(try callWith(.fromSymbol(@fromBackingInt(@intCast(0)))));
    try std.testing.expect(try callWith(.fromSymbol(@fromBackingInt(@intCast(7)))));
    try std.testing.expect(!try callWith(.fromFixnum(0)));
    try std.testing.expect(!try callWith(.fromBool(false)));
    try std.testing.expect(!try callWith(.fromBool(true)));
    try std.testing.expect(!try callWith(.empty_list_value));
    try std.testing.expect(!try callWith(.fromCharacter('a')));
    try std.testing.expect(!try callWith(.unspecified_value));
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    // 名前が同じでも、文字列はシンボルではない。
    try std.testing.expect(!try callWith(.fromString(try f.heap.createString("a"))));
    try std.testing.expect(!try callWith(.fromVector(try f.heap.createVector(&.{.fromSymbol(@fromBackingInt(@intCast(0)))}))));
    try std.testing.expect(!try callWith(try f.heap.cons(.fromSymbol(@fromBackingInt(@intCast(0))), .empty_list_value)));
}
