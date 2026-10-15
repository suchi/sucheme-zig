//! Pairs and lists (R7RS 6.4).
//!
//! 段階1のペアとリストの手続きである。データを変更する手続き(`set-car!` など)は
//! 段階3で入る(docs/roadmap.md の段階3)。

const std = @import("std");
const value = @import("../value.zig");
const Value = value.Value;
const Primitive = value.Primitive;
const Services = value.Services;
const PrimitiveError = value.PrimitiveError;

pub const Error = PrimitiveError;

pub const primitives = [_]Primitive{
    .{ .name = "cons", .min_args = 2, .max_args = 2, .body = .{ .pure = &cons } },
    .{ .name = "car", .min_args = 1, .max_args = 1, .body = .{ .pure = &car } },
    .{ .name = "cdr", .min_args = 1, .max_args = 1, .body = .{ .pure = &cdr } },
    .{ .name = "pair?", .min_args = 1, .max_args = 1, .body = .{ .pure = &isPair } },
    .{ .name = "null?", .min_args = 1, .max_args = 1, .body = .{ .pure = &isNull } },
    .{ .name = "list", .min_args = 0, .max_args = null, .body = .{ .pure = &list } },
    .{ .name = "length", .min_args = 1, .max_args = 1, .body = .{ .pure = &length } },
    .{ .name = "list?", .min_args = 1, .max_args = 1, .body = .{ .pure = &isList } },
};

/// The number of pairs in the chain `v`, or null when `v` is not a list: when the
/// chain ends in something other than the empty list, or never ends.
///
/// R7RS 6.4 は、リストを有限の長さを持ち空リストで終わるものと定めている。輪になった
/// 鎖は、尾を無限に進むので、リストではない。段階1の Scheme からは輪を作れない
/// (変更する手続きが無い)が、段階3の変更操作が入ったとき `length` と `list?` が止まる
/// ことを、ここで保っておく。
///
/// 速い印は2歩ずつ、遅い印は1歩ずつ進める(Floyd の方法)。輪があれば2つの印はいずれ
/// 同じペアで出会う。作業領域を使わず、長さに比例する時間で終わる。
pub fn properLength(v: Value) ?usize {
    var count: usize = 0;
    var slow = v;
    var fast = v;
    while (true) {
        for (0..2) |_| {
            switch (fast.kind()) {
                .empty_list => return count,
                .pair => {
                    fast = fast.asPair().?.cdr;
                    count += 1;
                },
                else => return null,
            }
        }
        slow = slow.asPair().?.cdr;
        // 速い印が空リストに着いていれば、次の周回で `count` を返す。
        if (fast.asPair()) |p| {
            if (p == slow.asPair().?) return null;
        }
    }
}

/// `(length list)`: the number of elements of `list`.
///
/// R7RS 6.4 は `list` がリストでないときの動作を定めていない(誤りである)。ここでは、
/// 末尾が空リストでない鎖と輪になった鎖を、型エラーにする。
fn length(_: *const Services, args: []const Value) Error!Value {
    const n = properLength(args[0]) orelse return error.WrongType;
    return .fromFixnum(@intCast(n));
}

/// `(list? obj)`: whether `obj` is a list (R7RS 6.4).
fn isList(_: *const Services, args: []const Value) Error!Value {
    return .fromBool(properLength(args[0]) != null);
}

/// `(cons obj1 obj2)`: a new pair of `obj1` and `obj2`.
///
/// 呼ぶたびに新しいペアを作る(R7RS 6.4)。
fn cons(services: *const Services, args: []const Value) Error!Value {
    return services.heap.cons(args[0], args[1]);
}

/// `(car pair)`: the first half of `pair`.
///
/// 空リストはペアではないので、型エラーである(R7RS 6.4)。
fn car(_: *const Services, args: []const Value) Error!Value {
    const p = args[0].asPair() orelse return error.WrongType;
    return p.car;
}

/// `(cdr pair)`: the second half of `pair`.
fn cdr(_: *const Services, args: []const Value) Error!Value {
    const p = args[0].asPair() orelse return error.WrongType;
    return p.cdr;
}

/// `(pair? obj)`: whether `obj` is a pair.
/// 空リストはペアではない(R7RS 6.4)。
fn isPair(_: *const Services, args: []const Value) Error!Value {
    return .fromBool(args[0].asPair() != null);
}

/// `(null? obj)`: whether `obj` is the empty list.
fn isNull(_: *const Services, args: []const Value) Error!Value {
    return .fromBool(args[0].kind() == .empty_list);
}

/// `(list obj ...)`: a new list of the arguments, in order.
///
/// 引数の個数だけペアを作る。GC は機械のステップの境目でしか走らない(ADR-0031)ので、
/// 途中までのペアを Zig のローカル変数で持ってよい。確保が失敗したときの途中のペアは
/// ゴミで、次の境目で回収される。
fn list(services: *const Services, args: []const Value) Error!Value {
    var result: Value = .empty_list_value;
    var i = args.len;
    while (i > 0) {
        i -= 1;
        result = try services.heap.cons(args[i], result);
    }
    return result;
}

test {
    std.testing.refAllDecls(@This());
}

const test_support = @import("test_support.zig");
const Heap = @import("../heap.zig").Heap;

fn fix(n: i64) Value {
    return .fromFixnum(n);
}

/// The values of every kind a pair is not, to try the primitives that check
/// their argument with.
fn notPairs(f: *test_support.Fixture) ![5]Value {
    return .{
        fix(1),
        .fromBool(false),
        .fromCharacter('a'),
        .fromString(try f.heap.createString("ab")),
        .fromVector(try f.heap.createVector(&.{fix(1)})),
    };
}

test "the pair primitives take the numbers of arguments the language gives them" {
    const Arity = struct { name: []const u8, min: u8, max: ?u8 };
    const expected = [_]Arity{
        .{ .name = "cons", .min = 2, .max = 2 },
        .{ .name = "car", .min = 1, .max = 1 },
        .{ .name = "cdr", .min = 1, .max = 1 },
        .{ .name = "pair?", .min = 1, .max = 1 },
        .{ .name = "null?", .min = 1, .max = 1 },
        .{ .name = "list", .min = 0, .max = null },
        .{ .name = "length", .min = 1, .max = 1 },
        .{ .name = "list?", .min = 1, .max = 1 },
    };
    try std.testing.expectEqual(expected.len, primitives.len);
    for (expected, primitives) |e, p| {
        try std.testing.expectEqualStrings(e.name, p.name);
        try std.testing.expectEqual(e.min, p.min_args);
        try std.testing.expectEqual(e.max, p.max_args);
    }
}

test "cons makes one pair of its two arguments" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    const p = try f.call(&primitives, "cons", &.{ fix(1), fix(2) });
    try std.testing.expectEqual(.pair, p.kind());
    try std.testing.expectEqual(1, p.asPair().?.car.asFixnum().?);
    try std.testing.expectEqual(2, p.asPair().?.cdr.asFixnum().?);
    try std.testing.expectEqual(1, f.heap.count);
    // 2回呼ぶと別のペアである。
    const q = try f.call(&primitives, "cons", &.{ fix(1), fix(2) });
    try std.testing.expect(p.asPair().? != q.asPair().?);
    try std.testing.expectEqual(2, f.heap.count);
}

test "cons keeps the order of its arguments, and any value can be a half" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    const inner = try f.call(&primitives, "cons", &.{ fix(1), Value.empty_list_value });
    const p = try f.call(&primitives, "cons", &.{ inner, Value.unspecified_value });
    try std.testing.expect(p.asPair().?.car.asPair().? == inner.asPair().?);
    try std.testing.expectEqual(.unspecified, p.asPair().?.cdr.kind());
}

test "car and cdr take a pair apart" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    const p = try f.call(&primitives, "cons", &.{ fix(1), fix(2) });
    try std.testing.expectEqual(1, (try f.call(&primitives, "car", &.{p})).asFixnum().?);
    try std.testing.expectEqual(2, (try f.call(&primitives, "cdr", &.{p})).asFixnum().?);
    // 取り出しは確保しない。
    try std.testing.expectEqual(1, f.heap.count);
}

test "car and cdr of what is not a pair is a wrong type, the empty list included" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    for (try notPairs(&f)) |v| {
        try std.testing.expectError(error.WrongType, f.call(&primitives, "car", &.{v}));
        try std.testing.expectError(error.WrongType, f.call(&primitives, "cdr", &.{v}));
    }
    try std.testing.expectError(error.WrongType, f.call(&primitives, "car", &.{Value.empty_list_value}));
    try std.testing.expectError(error.WrongType, f.call(&primitives, "cdr", &.{Value.empty_list_value}));
}

test "pair? is true of a pair and of nothing else" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    const p = try f.heap.cons(fix(1), fix(2));
    const t = try f.call(&primitives, "pair?", &.{p});
    try std.testing.expectEqual(.boolean, t.kind());
    try std.testing.expect(t.isTrue());
    for (try notPairs(&f)) |v| {
        const r = try f.call(&primitives, "pair?", &.{v});
        try std.testing.expectEqual(.boolean, r.kind());
        try std.testing.expect(!r.isTrue());
    }
    const e = try f.call(&primitives, "pair?", &.{Value.empty_list_value});
    try std.testing.expectEqual(.boolean, e.kind());
    try std.testing.expect(!e.isTrue());
}

test "null? is true of the empty list and of nothing else" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    const t = try f.call(&primitives, "null?", &.{Value.empty_list_value});
    try std.testing.expectEqual(.boolean, t.kind());
    try std.testing.expect(t.isTrue());
    const p = try f.heap.cons(fix(1), fix(2));
    const others = try notPairs(&f);
    for (others ++ [_]Value{p}) |v| {
        const r = try f.call(&primitives, "null?", &.{v});
        try std.testing.expectEqual(.boolean, r.kind());
        try std.testing.expect(!r.isTrue());
    }
}

test "list of no arguments is the empty list, and makes no pair" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    const l = try f.call(&primitives, "list", &.{});
    try std.testing.expectEqual(.empty_list, l.kind());
    try std.testing.expectEqual(0, f.heap.count);
}

test "list makes one pair for each argument, in the order of the arguments" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    const l = try f.call(&primitives, "list", &.{ fix(10), fix(20), fix(30) });
    try std.testing.expectEqual(3, f.heap.count);
    var rest = l;
    for ([_]i64{ 10, 20, 30 }) |expected| {
        const p = rest.asPair().?;
        try std.testing.expectEqual(expected, p.car.asFixnum().?);
        rest = p.cdr;
    }
    try std.testing.expectEqual(.empty_list, rest.kind());
}

test "list of one argument is a list of one element, even if the element is a list" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    const empty = Value.empty_list_value;
    const l = try f.call(&primitives, "list", &.{empty});
    try std.testing.expectEqual(.empty_list, l.asPair().?.car.kind());
    try std.testing.expectEqual(.empty_list, l.asPair().?.cdr.kind());
}

test "list takes as many arguments as the machine can pass" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    var args: [1000]Value = undefined;
    for (&args, 0..) |*a, i| a.* = fix(@intCast(i));
    const l = try f.call(&primitives, "list", &args);
    try std.testing.expectEqual(1000, f.heap.count);
    var rest = l;
    for (0..1000) |i| {
        try std.testing.expectEqual(@as(i64, @intCast(i)), rest.asPair().?.car.asFixnum().?);
        rest = rest.asPair().?.cdr;
    }
    try std.testing.expectEqual(.empty_list, rest.kind());
}

test "cons and list report a heap that is full" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    // 1つも確保できない上限にする。`services` は `f.heap` を指したままである。
    f.heap.deinit();
    f.heap = Heap.init(std.testing.allocator, .{ .limit = 1 });
    try std.testing.expectError(error.HeapLimit, f.call(&primitives, "cons", &.{ fix(1), fix(2) }));
    try std.testing.expectError(error.HeapLimit, f.call(&primitives, "list", &.{fix(1)}));
    // 確保しない呼び出しは、満杯のヒープでも成り立つ。
    const l = try f.call(&primitives, "list", &.{});
    try std.testing.expectEqual(.empty_list, l.kind());
}

/// The list of `items` ending in `tail`.
fn listOf(f: *test_support.Fixture, items: []const i64, tail: Value) !Value {
    var result = tail;
    var i = items.len;
    while (i > 0) {
        i -= 1;
        result = try f.heap.cons(fix(items[i]), result);
    }
    return result;
}

/// The length `length` gives, or null if it reports a wrong type.
fn lengthOf(f: *test_support.Fixture, v: Value) !?i64 {
    const r = f.call(&primitives, "length", &.{v}) catch |e| switch (e) {
        error.WrongType => return null,
        else => return e,
    };
    return r.asFixnum().?;
}

fn isListTrue(f: *test_support.Fixture, v: Value) !bool {
    const r = try f.call(&primitives, "list?", &.{v});
    try std.testing.expectEqual(.boolean, r.kind());
    return r.isTrue();
}

/// The last pair of the chain `v`, which must be a pair.
fn lastPair(v: Value) *value.Pair {
    var p = v.asPair().?;
    while (p.cdr.asPair()) |next| p = next;
    return p;
}

test "length counts the elements of a list, and makes nothing" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    try std.testing.expectEqual(0, (try lengthOf(&f, Value.empty_list_value)).?);
    try std.testing.expectEqual(1, (try lengthOf(&f, try listOf(&f, &.{7}, Value.empty_list_value))).?);
    try std.testing.expectEqual(3, (try lengthOf(&f, try listOf(&f, &.{ 1, 2, 3 }, Value.empty_list_value))).?);
    const before = f.heap.count;
    _ = try lengthOf(&f, Value.empty_list_value);
    try std.testing.expectEqual(before, f.heap.count);
}

test "length counts the pairs, not what they hold" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    // 要素がリストでも、数えるのは外側の鎖である。
    const inner = try listOf(&f, &.{ 1, 2, 3 }, Value.empty_list_value);
    const outer = try f.heap.cons(inner, try f.heap.cons(Value.empty_list_value, Value.empty_list_value));
    try std.testing.expectEqual(2, (try lengthOf(&f, outer)).?);
}

test "length of a chain that does not end in the empty list is a wrong type" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    try std.testing.expectEqual(null, try lengthOf(&f, try f.heap.cons(fix(1), fix(2))));
    try std.testing.expectEqual(null, try lengthOf(&f, try listOf(&f, &.{ 1, 2, 3 }, fix(4))));
    try std.testing.expectEqual(null, try lengthOf(&f, try listOf(&f, &.{ 1, 2 }, Value.unspecified_value)));
    try std.testing.expectEqual(null, try lengthOf(&f, try listOf(&f, &.{1}, .fromBool(false))));
    for (try notPairs(&f)) |v| try std.testing.expectEqual(null, try lengthOf(&f, v));
}

test "length of a list that loops back on itself is a wrong type, and ends" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    // 段階1の Scheme からは循環が作れない。ここでは Zig でペアを書き換えて作る。
    const self_loop = try f.heap.cons(fix(1), Value.empty_list_value);
    self_loop.asPair().?.cdr = self_loop;
    try std.testing.expectEqual(null, try lengthOf(&f, self_loop));

    const two = try listOf(&f, &.{ 1, 2 }, Value.empty_list_value);
    lastPair(two).cdr = two;
    try std.testing.expectEqual(null, try lengthOf(&f, two));

    // 輪に入る前に長い尾がある形。
    const loop = try listOf(&f, &.{ 10, 11, 12 }, Value.empty_list_value);
    lastPair(loop).cdr = loop;
    const with_tail = try listOf(&f, &.{ 1, 2, 3, 4, 5, 6, 7 }, loop);
    try std.testing.expectEqual(null, try lengthOf(&f, with_tail));
    // 輪の途中を指す形。
    const mid = try listOf(&f, &.{ 1, 2, 3, 4 }, Value.empty_list_value);
    lastPair(mid).cdr = mid.asPair().?.cdr.asPair().?.cdr;
    try std.testing.expectEqual(null, try lengthOf(&f, mid));
}

test "length counts a list longer than the machine's arguments" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    const n = 10_000;
    var l: Value = Value.empty_list_value;
    for (0..n) |i| l = try f.heap.cons(fix(@intCast(i)), l);
    try std.testing.expectEqual(n, (try lengthOf(&f, l)).?);
    try std.testing.expect(try isListTrue(&f, l));
    // 末尾だけが違う長い鎖は、数え終わってから偽になる。
    lastPair(l).cdr = fix(0);
    try std.testing.expectEqual(null, try lengthOf(&f, l));
    try std.testing.expect(!try isListTrue(&f, l));
}

test "list? is true of the empty list and of a chain that ends in it" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    try std.testing.expect(try isListTrue(&f, Value.empty_list_value));
    try std.testing.expect(try isListTrue(&f, try listOf(&f, &.{1}, Value.empty_list_value)));
    try std.testing.expect(try isListTrue(&f, try listOf(&f, &.{ 1, 2, 3 }, Value.empty_list_value)));
}

test "list? is false of a chain that ends in anything else, and of what is not a pair" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    try std.testing.expect(!try isListTrue(&f, try f.heap.cons(fix(1), fix(2))));
    try std.testing.expect(!try isListTrue(&f, try listOf(&f, &.{ 1, 2 }, fix(3))));
    try std.testing.expect(!try isListTrue(&f, try listOf(&f, &.{1}, Value.unspecified_value)));
    for (try notPairs(&f)) |v| try std.testing.expect(!try isListTrue(&f, v));
}

test "list? is false of a list that loops back on itself, and ends" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    const self_loop = try f.heap.cons(fix(1), Value.empty_list_value);
    self_loop.asPair().?.cdr = self_loop;
    try std.testing.expect(!try isListTrue(&f, self_loop));

    const two = try listOf(&f, &.{ 1, 2 }, Value.empty_list_value);
    lastPair(two).cdr = two;
    try std.testing.expect(!try isListTrue(&f, two));

    const loop = try listOf(&f, &.{ 10, 11, 12 }, Value.empty_list_value);
    lastPair(loop).cdr = loop;
    try std.testing.expect(!try isListTrue(&f, try listOf(&f, &.{ 1, 2, 3, 4, 5, 6, 7 }, loop)));
}

test "list? and length agree on every shape" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    // 長さ 0 から 39 の、真のリストと、末尾が違う鎖と、輪。
    for (0..40) |n| {
        var items: [40]i64 = undefined;
        for (items[0..n], 0..) |*it, i| it.* = @intCast(i);
        const proper = try listOf(&f, items[0..n], Value.empty_list_value);
        try std.testing.expect(try isListTrue(&f, proper));
        try std.testing.expectEqual(@as(i64, @intCast(n)), (try lengthOf(&f, proper)).?);

        const improper = try listOf(&f, items[0..n], fix(0));
        // n が 0 のときは、鎖でなく数 0 そのものである。
        try std.testing.expect(!try isListTrue(&f, improper));
        try std.testing.expectEqual(null, try lengthOf(&f, improper));

        if (n == 0) continue;
        const ring = try listOf(&f, items[0..n], Value.empty_list_value);
        lastPair(ring).cdr = ring;
        try std.testing.expect(!try isListTrue(&f, ring));
        try std.testing.expectEqual(null, try lengthOf(&f, ring));
    }
}
