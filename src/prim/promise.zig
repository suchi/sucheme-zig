//! Promise primitives (R7RS 4.2.5): `make-promise`, `promise?` and `force`.
//!
//! `delay` と `delay-force` の構文は段階3のスライス 3j が `(sucheme derived)` に足した。R7RS 7.3 は、`delay-force` を
//! `(make-promise #f (lambda () expression))`、`delay` を `(delay-force (make-promise #t
//! expression))` と定義している。この `make-promise` は、強制済みかの印と、値か手続きを取る
//! 2引数の内部の手続きで、(scheme lazy) の `make-promise`(値を1つ取る)とは別のものである。
//! ここでは前者を `%make-promise` として足す。名前は `%` で始め、(scheme lazy) に入れない
//! (R7RS 5.6.1)。
//!
//! `force` は機械操作プリミティブで、強制していない約束の手続きを呼ぶので、機械が行う
//! (`Machine.apply`)。ここには名前と引数の個数だけを置く。

const std = @import("std");
const value = @import("../value.zig");
const Value = value.Value;
const Primitive = value.Primitive;
const Services = value.Services;
const PrimitiveError = value.PrimitiveError;

pub const Error = PrimitiveError;

pub const primitives = [_]Primitive{
    .{ .name = "make-promise", .min_args = 1, .max_args = 1, .body = .{ .pure = &makePromise } },
    .{ .name = "promise?", .min_args = 1, .max_args = 1, .body = .{ .pure = &isPromise } },
    .{ .name = "force", .min_args = 1, .max_args = 1, .body = .{ .machine = .force } },
    .{ .name = "%make-promise", .min_args = 2, .max_args = 2, .body = .{ .pure = &makeInternalPromise } },
};

/// `(make-promise obj)`: a promise that is done, whose value is `obj`; `obj` itself
/// when it is already a promise (R7RS 4.2.5).
fn makePromise(services: *const Services, args: []const Value) Error!Value {
    if (args[0].asPromise() != null) return args[0];
    return .fromPromise(try services.heap.create(value.Promise, .{ .done = true, .value = args[0], .forward = null }));
}

/// `(promise? obj)`: whether `obj` is a promise.
fn isPromise(_: *const Services, args: []const Value) Error!Value {
    return .fromBool(args[0].asPromise() != null);
}

/// `(%make-promise done? obj)`: a promise that is done with the value `obj` when
/// `done?` is true, and otherwise one that is not, whose procedure of no arguments
/// is `obj`, and which returns a promise (R7RS 7.3).
/// 値を作る手続きは、強制するときでなく、ここで型を検査する。誤りを、作った場所に近い
/// ところで報告するためである。
fn makeInternalPromise(services: *const Services, args: []const Value) Error!Value {
    const done = switch (args[0]) {
        .boolean => |b| b,
        else => return error.WrongType,
    };
    if (!done and !isProcedure(args[1])) return error.WrongType;
    return .fromPromise(try services.heap.create(value.Promise, .{ .done = done, .value = args[1], .forward = null }));
}

/// Whether `v` can be called with no arguments by `force`.
/// `procedure?` と同じ集合である。
fn isProcedure(v: Value) bool {
    // Why: `else` にしない。`Kind` に種別を足したとき、ここがコンパイルエラーになって、
    // 手続きの種別を見落とさないようにする。
    return switch (v.kind()) {
        .primitive, .closure, .continuation, .parameter => true,
        .fixnum, .boolean, .empty_list, .symbol, .pair, .unspecified, .uninitialized, .condition, .character, .string, .vector, .bytevector, .alias, .record, .record_type, .multiple_values, .eof, .promise => false,
    };
}

test {
    std.testing.refAllDecls(@This());
}

const test_support = @import("test_support.zig");
const heap_mod = @import("../heap.zig");

test "make-promise and promise? take one argument, force one, %make-promise two" {
    const Arity = struct { name: []const u8, min: u8, max: u8 };
    const expected = [_]Arity{
        .{ .name = "make-promise", .min = 1, .max = 1 },
        .{ .name = "promise?", .min = 1, .max = 1 },
        .{ .name = "force", .min = 1, .max = 1 },
        .{ .name = "%make-promise", .min = 2, .max = 2 },
    };
    try std.testing.expectEqual(expected.len, primitives.len);
    for (expected, primitives) |e, p| {
        try std.testing.expectEqualStrings(e.name, p.name);
        try std.testing.expectEqual(e.min, p.min_args);
        try std.testing.expectEqual(e.max, p.max_args.?);
    }
    try std.testing.expectEqual(value.MachineOp.force, primitives[2].body.machine);
}

test "make-promise makes a promise that is done, holding the value, and returns a promise as it is" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    const list = try f.heap.cons(.fromFixnum(1), .empty_list_value);
    const made = try f.call(&primitives, "make-promise", &.{list});
    const p = made.asPromise().?;
    try std.testing.expect(p.done);
    try std.testing.expect(p.forward == null);
    try std.testing.expect(p.value.isEqv(list));
    // 値が `#f` でも、強制済みである。
    const falsy = (try f.call(&primitives, "make-promise", &.{.fromBool(false)})).asPromise().?;
    try std.testing.expect(falsy.done);
    try std.testing.expectEqual(value.Kind.boolean, falsy.value.kind());
    // すでに約束なら、新しく作らない。
    const count = f.heap.count;
    const again = try f.call(&primitives, "make-promise", &.{made});
    try std.testing.expect(again.isEqv(made));
    try std.testing.expectEqual(count, f.heap.count);
    // 強制済みの約束を包む約束も、同じ約束である。
    try std.testing.expect((try f.call(&primitives, "make-promise", &.{again})).isEqv(made));
}

test "promise? is true of promises only" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    const made = try f.call(&primitives, "make-promise", &.{.fromFixnum(1)});
    try std.testing.expect((try f.call(&primitives, "promise?", &.{made})).isTrue());
    const lazy = try f.call(&primitives, "%make-promise", &.{ .fromBool(false), .fromPrimitive(&primitives[0]) });
    try std.testing.expect((try f.call(&primitives, "promise?", &.{lazy})).isTrue());
    const not_promises = [_]Value{
        .fromFixnum(0),
        .fromBool(false),
        .empty_list_value,
        .unspecified_value,
        .eof_value,
        .fromPrimitive(&primitives[0]),
        try f.heap.cons(made, made),
        .fromVector(try f.heap.createVector(&.{made})),
    };
    for (not_promises) |v| {
        const answer = try f.call(&primitives, "promise?", &.{v});
        try std.testing.expectEqual(value.Kind.boolean, answer.kind());
        try std.testing.expect(!answer.isTrue());
    }
}

test "%make-promise makes a promise that is done or one with a procedure, as the mark says" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    const procedure: Value = .fromPrimitive(&primitives[0]);
    const lazy = (try f.call(&primitives, "%make-promise", &.{ .fromBool(false), procedure })).asPromise().?;
    try std.testing.expect(!lazy.done);
    try std.testing.expect(lazy.forward == null);
    try std.testing.expect(lazy.value.isEqv(procedure));
    const done = (try f.call(&primitives, "%make-promise", &.{ .fromBool(true), .fromFixnum(7) })).asPromise().?;
    try std.testing.expect(done.done);
    try std.testing.expectEqual(7, done.value.asFixnum().?);
    // 強制済みなら、値は手続きでなくてよい。
    const done_with_false = (try f.call(&primitives, "%make-promise", &.{ .fromBool(true), .fromBool(false) })).asPromise().?;
    try std.testing.expect(done_with_false.done);
}

test "%make-promise takes a boolean mark, and a procedure when the promise is not done" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    try std.testing.expectError(error.WrongType, f.call(&primitives, "%make-promise", &.{ .fromFixnum(1), .fromFixnum(2) }));
    try std.testing.expectError(error.WrongType, f.call(&primitives, "%make-promise", &.{ .empty_list_value, .fromPrimitive(&primitives[0]) }));
    try std.testing.expectError(error.WrongType, f.call(&primitives, "%make-promise", &.{ .fromBool(false), .fromFixnum(5) }));
    try std.testing.expectError(error.WrongType, f.call(&primitives, "%make-promise", &.{ .fromBool(false), try f.heap.cons(.fromFixnum(1), .empty_list_value) }));
}

test "a promise made at the limit of the heap reports the limit and makes nothing" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    // 1つも確保できない上限にする。`services` は `f.heap` を指したままである。
    f.heap.deinit();
    f.heap = heap_mod.Heap.init(std.testing.allocator, .{ .limit = 1 });
    try std.testing.expectError(error.HeapLimit, f.call(&primitives, "make-promise", &.{.fromFixnum(1)}));
    try std.testing.expectError(error.HeapLimit, f.call(&primitives, "%make-promise", &.{ .fromBool(true), .fromFixnum(1) }));
    try std.testing.expectEqual(0, f.heap.count);
    // 約束を渡す呼び出しは、確保しないので、満杯のヒープでも成り立つ。
    var done: value.Promise = .{ .done = true, .value = .fromFixnum(1), .forward = null };
    const p: Value = .fromPromise(&done);
    try std.testing.expect((try f.call(&primitives, "make-promise", &.{p})).isEqv(p));
}
