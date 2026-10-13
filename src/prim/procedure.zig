//! Procedure primitives (R7RS 6.10): `procedure?` and `apply`.
//!
//! `apply` は機械操作プリミティブである。ここには名前と引数の個数の範囲だけを置き、
//! 操作は `Machine.apply` が行う。並べ直した呼び出しを、同じ関数の中の周回で適用し、
//! 継続のフレームを積まない。ほかの機械操作プリミティブ(段階5の `eval` と `exit` を
//! 含む)と、それぞれが入る段階は、docs/design/runtime.md の「機械操作プリミティブと
//! 末尾呼び出し」にある。`map` などは段階3で入る。

const std = @import("std");
const value = @import("../value.zig");
const Value = value.Value;
const Primitive = value.Primitive;
const Services = value.Services;
const PrimitiveError = value.PrimitiveError;

pub const Error = PrimitiveError;

pub const primitives = [_]Primitive{
    .{ .name = "procedure?", .min_args = 1, .max_args = 1, .body = .{ .pure = &isProcedure } },
    // `(apply proc arg1 ... args)`: 手続きと最後のリストは省けない。
    .{ .name = "apply", .min_args = 2, .max_args = null, .body = .{ .machine = .apply } },
};

/// `(procedure? obj)`: true of the procedures made by `lambda` and of the ones
/// implemented in Zig (R7RS 6.10).
fn isProcedure(_: *const Services, args: []const Value) Error!Value {
    return .fromBool(switch (args[0].kind()) {
        .primitive, .closure => true,
        .fixnum, .boolean, .empty_list, .symbol, .pair, .unspecified, .uninitialized, .condition, .character, .string, .vector, .alias => false,
    });
}

test {
    std.testing.refAllDecls(@This());
}

const test_support = @import("test_support.zig");

fn callWith(arg: Value) !bool {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    const v = try f.call(&primitives, "procedure?", &.{arg});
    try std.testing.expectEqual(.boolean, v.kind());
    return v.isTrue();
}

test "procedure? takes one argument, and apply two or more" {
    try std.testing.expectEqual(2, primitives.len);
    try std.testing.expectEqualStrings("procedure?", primitives[0].name);
    try std.testing.expectEqual(1, primitives[0].min_args);
    try std.testing.expectEqual(1, primitives[0].max_args.?);
    try std.testing.expectEqualStrings("apply", primitives[1].name);
    try std.testing.expectEqual(2, primitives[1].min_args);
    try std.testing.expectEqual(null, primitives[1].max_args);
    try std.testing.expectEqual(value.MachineOp.apply, primitives[1].body.machine);
}

test "procedure? is true of a primitive, of a machine operation and of a closure" {
    try std.testing.expect(try callWith(.fromPrimitive(&primitives[0])));
    try std.testing.expect(try callWith(.fromPrimitive(&primitives[1])));
    const body: value.Node = .{ .constant = .unspecified_value };
    const lambda: value.Lambda = .{ .arity = 0, .frame_size = 0, .body = &body };
    var closure: value.Closure = .{ .lambda = &lambda, .env = null };
    try std.testing.expect(try callWith(.fromClosure(&closure)));
}

test "procedure? is false of everything that is not a procedure" {
    try std.testing.expect(!try callWith(.fromFixnum(0)));
    try std.testing.expect(!try callWith(.fromBool(false)));
    try std.testing.expect(!try callWith(.fromBool(true)));
    try std.testing.expect(!try callWith(.empty_list_value));
    try std.testing.expect(!try callWith(.fromSymbol(@fromBackingInt(@intCast(0)))));
    try std.testing.expect(!try callWith(.fromCharacter('a')));
    try std.testing.expect(!try callWith(.unspecified_value));
    var condition: value.Condition = .{ .kind = .@"error", .message = .empty_list_value, .irritants = .empty_list_value };
    try std.testing.expect(!try callWith(.fromCondition(&condition)));
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    try std.testing.expect(!try callWith(.fromString(try f.heap.createString("car"))));
    try std.testing.expect(!try callWith(.fromVector(try f.heap.createVector(&.{}))));
    try std.testing.expect(!try callWith(try f.heap.cons(.fromFixnum(1), .fromFixnum(2))));
}
