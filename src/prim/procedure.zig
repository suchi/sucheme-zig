//! Procedure primitives (R7RS 6.10): `procedure?`, `apply`, `call/cc`,
//! `dynamic-wind`, `values`, `call-with-values` and `make-parameter` (R7RS 4.2.6).
//!
//! `apply`、`call/cc`(`call-with-current-continuation`)、`dynamic-wind`、`values`、
//! `call-with-values`、`make-parameter`、`features` は機械操作プリミティブである。ここには名前と引数の個数の範囲だけを置き、操作は `Machine.apply`
//! が行う。`apply` は並べ直した呼び出しを、同じ関数の中の周回で適用し、継続のフレームを
//! 積まない。`call/cc` も同じく、捕捉した継続を渡す呼び出しをフレームを積まずに適用する。ほかの機械操作プリミティブ(段階5の `eval` と `exit` を
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
    .{ .name = "call-with-current-continuation", .min_args = 1, .max_args = 1, .body = .{ .machine = .call_cc } },
    .{ .name = "call/cc", .min_args = 1, .max_args = 1, .body = .{ .machine = .call_cc } },
    .{ .name = "dynamic-wind", .min_args = 3, .max_args = 3, .body = .{ .machine = .dynamic_wind } },
    .{ .name = "values", .min_args = 0, .max_args = null, .body = .{ .machine = .values } },
    .{ .name = "call-with-values", .min_args = 2, .max_args = 2, .body = .{ .machine = .call_with_values } },
    // `(make-parameter init [converter])`: 変換手続きは省ける。
    .{ .name = "make-parameter", .min_args = 1, .max_args = 2, .body = .{ .machine = .make_parameter } },
    // `(features)`: 引数は取らない。シンボル表に触れるので、機械が作る。
    .{ .name = "features", .min_args = 0, .max_args = 0, .body = .{ .machine = .features } },
};

/// `(procedure? obj)`: true of the procedures made by `lambda`, of the ones
/// implemented in Zig, of the continuations `call/cc` captures (R7RS 6.10), and of
/// the parameter objects `make-parameter` makes (R7RS 4.2.6).
fn isProcedure(_: *const Services, args: []const Value) Error!Value {
    return .fromBool(switch (args[0].kind()) {
        .primitive, .closure, .continuation, .parameter => true,
        .fixnum, .boolean, .empty_list, .symbol, .pair, .unspecified, .uninitialized, .condition, .character, .string, .vector, .bytevector, .alias, .record, .record_type, .multiple_values, .eof, .promise, .flonum, .bignum, .ratnum, .compnum, .port => false,
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

test "procedure? takes one argument, apply two or more, call/cc one, dynamic-wind three, values any number, call-with-values two and make-parameter one or two" {
    try std.testing.expectEqual(9, primitives.len);
    try std.testing.expectEqualStrings("procedure?", primitives[0].name);
    try std.testing.expectEqual(1, primitives[0].min_args);
    try std.testing.expectEqual(1, primitives[0].max_args.?);
    try std.testing.expectEqualStrings("apply", primitives[1].name);
    try std.testing.expectEqual(2, primitives[1].min_args);
    try std.testing.expectEqual(null, primitives[1].max_args);
    try std.testing.expectEqual(value.MachineOp.apply, primitives[1].body.machine);
    // 2つの名前は同じ操作である(R7RS 6.10)。
    for ([_][]const u8{ "call-with-current-continuation", "call/cc" }, primitives[2..4]) |name, p| {
        try std.testing.expectEqualStrings(name, p.name);
        try std.testing.expectEqual(1, p.min_args);
        try std.testing.expectEqual(1, p.max_args.?);
        try std.testing.expectEqual(value.MachineOp.call_cc, p.body.machine);
    }
    try std.testing.expectEqualStrings("dynamic-wind", primitives[4].name);
    try std.testing.expectEqual(3, primitives[4].min_args);
    try std.testing.expectEqual(3, primitives[4].max_args.?);
    try std.testing.expectEqual(value.MachineOp.dynamic_wind, primitives[4].body.machine);
    // `values` は何個でも受け取り、`call-with-values` は生産者と受け手の2つを受け取る。
    try std.testing.expectEqualStrings("values", primitives[5].name);
    try std.testing.expectEqual(0, primitives[5].min_args);
    try std.testing.expectEqual(null, primitives[5].max_args);
    try std.testing.expectEqual(value.MachineOp.values, primitives[5].body.machine);
    try std.testing.expectEqualStrings("call-with-values", primitives[6].name);
    try std.testing.expectEqual(2, primitives[6].min_args);
    try std.testing.expectEqual(2, primitives[6].max_args.?);
    try std.testing.expectEqual(value.MachineOp.call_with_values, primitives[6].body.machine);
    try std.testing.expectEqualStrings("make-parameter", primitives[7].name);
    try std.testing.expectEqual(1, primitives[7].min_args);
    try std.testing.expectEqual(2, primitives[7].max_args.?);
    try std.testing.expectEqual(value.MachineOp.make_parameter, primitives[7].body.machine);
}

test "procedure? is true of a primitive, of a machine operation and of a closure" {
    try std.testing.expect(try callWith(.fromPrimitive(&primitives[0])));
    try std.testing.expect(try callWith(.fromPrimitive(&primitives[1])));
    const body: value.Node = .{ .constant = .unspecified_value };
    const lambda: value.Lambda = .{ .arity = 0, .frame_size = 0, .body = &body };
    var closure: value.Closure = .{ .lambda = &lambda, .env = null };
    try std.testing.expect(try callWith(.fromClosure(&closure)));
    var k: value.Continuation = .{ .kont = null, .dyn = null };
    try std.testing.expect(try callWith(.fromContinuation(&k)));
    var param: value.Parameter = .{ .value = .fromFixnum(1), .converter = null };
    try std.testing.expect(try callWith(.fromParameter(&param)));
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
    var items = [_]Value{ .fromFixnum(1), .fromFixnum(2) };
    var multiple: value.MultipleValues = .{ .items = &items };
    try std.testing.expect(!try callWith(.fromMultipleValues(&multiple)));
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    try std.testing.expect(!try callWith(.fromString(try f.heap.createString("car"))));
    try std.testing.expect(!try callWith(.fromVector(try f.heap.createVector(&.{}))));
    try std.testing.expect(!try callWith(.fromBytevector(try f.heap.createBytevector(&.{}))));
    try std.testing.expect(!try callWith(try f.heap.cons(.fromFixnum(1), .fromFixnum(2))));
    try std.testing.expect(!try callWith(.fromPort(try f.heap.createMemoryPort(.output, .textual, ""))));
}
