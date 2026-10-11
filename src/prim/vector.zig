//! Vector primitives (R7RS 6.8).
//!
//! 変更する手続き(`vector-set!` `vector-fill!`)と、大きさを数で決める生成
//! (`make-vector`)は、段階3に送った。`vector` は引数を並べて作るだけで、確保する
//! 量は引数の個数に比例する。

const std = @import("std");
const value = @import("../value.zig");
const Value = value.Value;
const Primitive = value.Primitive;
const Services = value.Services;
const PrimitiveError = value.PrimitiveError;

pub const Error = PrimitiveError;

pub const primitives = [_]Primitive{
    .{ .name = "vector?", .min_args = 1, .max_args = 1, .call = &isVector },
    .{ .name = "vector", .min_args = 0, .max_args = null, .call = &vector },
    .{ .name = "vector-length", .min_args = 1, .max_args = 1, .call = &vectorLength },
    .{ .name = "vector-ref", .min_args = 2, .max_args = 2, .call = &vectorRef },
};

/// `(vector? obj)`.
fn isVector(_: *const Services, args: []const Value) Error!Value {
    return .fromBool(args[0].asVector() != null);
}

/// `(vector obj ...)`: a new vector of the arguments, in order (R7RS 6.8).
///
/// ヒープがコピーを作る。`args` は機械が用意した一時領域にあり、返したあとは使われない。
fn vector(services: *const Services, args: []const Value) Error!Value {
    return .fromVector(try services.heap.createVector(args));
}

/// `(vector-length vector)`.
fn vectorLength(_: *const Services, args: []const Value) Error!Value {
    const v = args[0].asVector() orelse return error.WrongType;
    // 要素の数は、確保できた大きさを超えないので、i64 に収まる。
    return .fromFixnum(@intCast(v.items.len));
}

/// `(vector-ref vector k)`: the `k`th element, counted from 0 (R7RS 6.8).
///
/// Why: R7RS 6.8 は、`k` が妥当な添字でなければ誤りとしている。引数は 64 ビットの整数
/// なので、`usize` に変えられるかを先に調べる。`wasm32` で `@intCast` すると、大きな値
/// の検査でパニックするか、切り捨てて範囲内に戻ってしまう。
fn vectorRef(_: *const Services, args: []const Value) Error!Value {
    const v = args[0].asVector() orelse return error.WrongType;
    const k = args[1].asFixnum() orelse return error.WrongType;
    const index = std.math.cast(usize, k) orelse return error.OutOfRange;
    if (index >= v.items.len) return error.OutOfRange;
    return v.items[index];
}

test {
    std.testing.refAllDecls(@This());
}

const test_support = @import("test_support.zig");
const heap_mod = @import("../heap.zig");

test "the primitives take the numbers of arguments the language gives them" {
    const Arity = struct { name: []const u8, min: u8, max: ?u8 };
    const expected = [_]Arity{
        .{ .name = "vector?", .min = 1, .max = 1 },
        .{ .name = "vector", .min = 0, .max = null },
        .{ .name = "vector-length", .min = 1, .max = 1 },
        .{ .name = "vector-ref", .min = 2, .max = 2 },
    };
    try std.testing.expectEqual(expected.len, primitives.len);
    for (expected, primitives) |e, p| {
        try std.testing.expectEqualStrings(e.name, p.name);
        try std.testing.expectEqual(e.min, p.min_args);
        try std.testing.expectEqual(e.max, p.max_args);
    }
}

test "vector? is true of a vector, the empty one included, and of nothing else" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    const empty = try f.call(&primitives, "vector", &.{});
    const some = try f.call(&primitives, "vector", &.{.fromFixnum(1)});
    try std.testing.expect((try f.call(&primitives, "vector?", &.{empty})).isTrue());
    try std.testing.expect((try f.call(&primitives, "vector?", &.{some})).isTrue());
    const pair = try f.heap.cons(.fromFixnum(1), .empty_list_value);
    const string: Value = .fromString(try f.heap.createString("abc"));
    for ([_]Value{ pair, string, .fromFixnum(1), .empty_list_value, .fromCharacter('a'), .fromBool(true) }) |v| {
        const r = try f.call(&primitives, "vector?", &.{v});
        try std.testing.expectEqual(value.Kind.boolean, r.kind());
        try std.testing.expect(!r.isTrue());
    }
}

test "vector gathers its arguments in order" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    const none = (try f.call(&primitives, "vector", &.{})).asVector().?;
    try std.testing.expectEqual(0, none.items.len);
    const args = [_]Value{ .fromFixnum(1), .fromBool(true), .fromCharacter('c'), .empty_list_value, .fromFixnum(-5) };
    const v = (try f.call(&primitives, "vector", &args)).asVector().?;
    try std.testing.expectEqual(args.len, v.items.len);
    try std.testing.expectEqual(1, v.items[0].asFixnum().?);
    try std.testing.expect(v.items[1].isTrue() and v.items[1].kind() == .boolean);
    try std.testing.expectEqual('c', v.items[2].asCharacter().?);
    try std.testing.expectEqual(value.Kind.empty_list, v.items[3].kind());
    try std.testing.expectEqual(-5, v.items[4].asFixnum().?);
    // 結果は引数の配列の写しで、同じ配列ではない。
    try std.testing.expect(v.items.ptr != &args);
}

test "vector holds many arguments, each in its place" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    var args: [300]Value = undefined;
    for (&args, 0..) |*a, i| a.* = .fromFixnum(@intCast(i));
    const v = (try f.call(&primitives, "vector", &args)).asVector().?;
    try std.testing.expectEqual(300, v.items.len);
    for (v.items, 0..) |item, i| try std.testing.expectEqual(@as(i64, @intCast(i)), item.asFixnum().?);
}

test "vector accounts for its elements, and fails at the limit leaving the account as it was" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    f.heap.deinit();
    // 要素1つのベクタには足りるが、3つには足りない上限。
    const one = @sizeOf(Value);
    var probe: heap_mod.Heap = .init(std.testing.allocator, .{});
    defer probe.deinit();
    _ = try probe.createVector(&.{.fromFixnum(1)});
    f.heap = .init(std.testing.allocator, .{ .limit = probe.accounted + one });
    const args = [_]Value{ .fromFixnum(1), .fromFixnum(2), .fromFixnum(3) };
    try std.testing.expectError(error.HeapLimit, f.call(&primitives, "vector", &args));
    try std.testing.expectEqual(0, f.heap.accounted);
    _ = try f.call(&primitives, "vector", args[0..1]);
    try std.testing.expectEqual(probe.accounted, f.heap.accounted);
}

test "vector-length gives the number of elements" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    const items = [_]Value{ .fromFixnum(1), .fromFixnum(2), .fromFixnum(3), .fromFixnum(4), .fromFixnum(5) };
    for (0..items.len + 1) |n| {
        const v = try f.call(&primitives, "vector", items[0..n]);
        const len = try f.call(&primitives, "vector-length", &.{v});
        try std.testing.expectEqual(@as(i64, @intCast(n)), len.asFixnum().?);
    }
}

test "vector-ref gives the element at a position" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    const inner = try f.call(&primitives, "vector", &.{.fromFixnum(9)});
    const v = try f.call(&primitives, "vector", &.{ .fromFixnum(10), inner, .fromCharacter('x') });
    try std.testing.expectEqual(10, (try f.call(&primitives, "vector-ref", &.{ v, .fromFixnum(0) })).asFixnum().?);
    // 要素そのもの(同じオブジェクト)が返る。
    try std.testing.expectEqual(inner.asVector().?, (try f.call(&primitives, "vector-ref", &.{ v, .fromFixnum(1) })).asVector().?);
    try std.testing.expectEqual('x', (try f.call(&primitives, "vector-ref", &.{ v, .fromFixnum(2) })).asCharacter().?);
}

test "vector-ref refuses a position outside the vector" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    const empty = try f.call(&primitives, "vector", &.{});
    const three = try f.call(&primitives, "vector", &.{ .fromFixnum(1), .fromFixnum(2), .fromFixnum(3) });
    const positions = [_]i64{ 0, 1, 3, 4, 100, -1, std.math.minInt(i64), std.math.maxInt(i64), 1 << 32, (1 << 32) + 1 };
    for (positions) |k| {
        try std.testing.expectError(error.OutOfRange, f.call(&primitives, "vector-ref", &.{ empty, .fromFixnum(k) }));
    }
    // 長さちょうどと、その先。最後の要素までは読める。
    for (positions[2..]) |k| {
        try std.testing.expectError(error.OutOfRange, f.call(&primitives, "vector-ref", &.{ three, .fromFixnum(k) }));
    }
    try std.testing.expectEqual(3, (try f.call(&primitives, "vector-ref", &.{ three, .fromFixnum(2) })).asFixnum().?);
}

test "vector-ref and vector-length report an argument of the wrong type, before the range" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    const v = try f.call(&primitives, "vector", &.{.fromFixnum(1)});
    const string: Value = .fromString(try f.heap.createString("abc"));
    const pair = try f.heap.cons(.fromFixnum(1), .empty_list_value);
    try std.testing.expectError(error.WrongType, f.call(&primitives, "vector-length", &.{string}));
    try std.testing.expectError(error.WrongType, f.call(&primitives, "vector-length", &.{pair}));
    try std.testing.expectError(error.WrongType, f.call(&primitives, "vector-length", &.{.empty_list_value}));
    // ベクタでない最初の引数は、添字が範囲外でも型のエラーになる。
    try std.testing.expectError(error.WrongType, f.call(&primitives, "vector-ref", &.{ string, .fromFixnum(0) }));
    try std.testing.expectError(error.WrongType, f.call(&primitives, "vector-ref", &.{ pair, .fromFixnum(100) }));
    try std.testing.expectError(error.WrongType, f.call(&primitives, "vector-ref", &.{ pair, .fromFixnum(-1) }));
    // 整数でない添字。
    try std.testing.expectError(error.WrongType, f.call(&primitives, "vector-ref", &.{ v, .fromCharacter('a') }));
    try std.testing.expectError(error.WrongType, f.call(&primitives, "vector-ref", &.{ v, string }));
    try std.testing.expectError(error.WrongType, f.call(&primitives, "vector-ref", &.{ v, .empty_list_value }));
}

test "a collection keeps the elements of a vector the roots reach" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    const s: Value = .fromString(try f.heap.createString("あいう"));
    const v = try f.call(&primitives, "vector", &.{ s, .fromFixnum(1) });
    _ = try f.heap.createString("garbage");
    const Roots = struct {
        v: Value,
        pub fn mark(self: @This(), marker: *heap_mod.Marker) void {
            marker.value(self.v);
        }
    };
    f.heap.collect(Roots{ .v = v });
    try std.testing.expectEqual(2, f.heap.count);
    const kept = (try f.call(&primitives, "vector-ref", &.{ v, .fromFixnum(0) })).asString().?;
    try std.testing.expectEqualStrings("あいう", kept.bytes);
    try std.testing.expectEqual(3, kept.length());
}
