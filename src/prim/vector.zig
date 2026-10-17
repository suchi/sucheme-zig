//! Vector primitives (R7RS 6.8).
//!
//! `vector->string` と `string->vector` は文字列の族(`string.zig`)にある。ベクタを引数に
//! 取る高階の手続き(`vector-map` `vector-for-each`)は、段階3の別のスライスが Scheme で書く。
//!
//! 変更する手続き(`vector-set!` `vector-fill!` `vector-copy!`)は、型を検査したあと、範囲を
//! 検査する前に、引数が定数でないことを検査する(`immutable.requireMutable`)。範囲が空でも、
//! 定数なら断る。`make-vector` `vector-copy` `vector-append` `list->vector` は、確保する領域を
//! 先に上限に照らして検査し、領域へ直接書く(`Heap.createVectorFilled`)。`vector` は引数を並べて
//! 作るだけで、確保する量は引数の個数に比例する。
//!
//! `vector->list` は、要素の数だけペアを作る。1回の呼び出しの中で個数に比例して確保し、その間に
//! GC は走らない(ADR-0031)。`string->list` と同じ種類の制約である。

const std = @import("std");
const value = @import("../value.zig");
const Value = value.Value;
const Primitive = value.Primitive;
const Services = value.Services;
const PrimitiveError = value.PrimitiveError;
const immutable = @import("immutable.zig");
const pair_mod = @import("pair.zig");
const range_mod = @import("range.zig");
const RangeOperands = range_mod.RangeOperands;
const resolveRange = range_mod.resolveRange;

pub const Error = PrimitiveError;

pub const primitives = [_]Primitive{
    .{ .name = "vector?", .min_args = 1, .max_args = 1, .body = .{ .pure = &isVector } },
    .{ .name = "vector", .min_args = 0, .max_args = null, .body = .{ .pure = &vector } },
    .{ .name = "vector-length", .min_args = 1, .max_args = 1, .body = .{ .pure = &vectorLength } },
    .{ .name = "vector-ref", .min_args = 2, .max_args = 2, .body = .{ .pure = &vectorRef } },
    .{ .name = "make-vector", .min_args = 1, .max_args = 2, .body = .{ .pure = &makeVector } },
    .{ .name = "vector-set!", .min_args = 3, .max_args = 3, .body = .{ .pure = &vectorSet } },
    .{ .name = "vector->list", .min_args = 1, .max_args = 3, .body = .{ .pure = &vectorToList } },
    .{ .name = "list->vector", .min_args = 1, .max_args = 1, .body = .{ .pure = &listToVector } },
    .{ .name = "vector-fill!", .min_args = 2, .max_args = 4, .body = .{ .pure = &vectorFill } },
    .{ .name = "vector-copy", .min_args = 1, .max_args = 3, .body = .{ .pure = &vectorCopy } },
    .{ .name = "vector-copy!", .min_args = 3, .max_args = 5, .body = .{ .pure = &vectorCopyInto } },
    .{ .name = "vector-append", .min_args = 0, .max_args = null, .body = .{ .pure = &vectorAppend } },
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

/// Writes `item` in every place.
const RepeatFiller = struct {
    item: Value,

    pub fn fill(self: RepeatFiller, items: []Value) void {
        @memset(items, self.item);
    }
};

/// `(make-vector k)` and `(make-vector k fill)`: a new vector of `k` elements, all `fill`
/// (R7RS 6.8).
///
/// R7RS 6.8 は、`fill` がなければ中身を未規定としている。ここでは `#f` で埋める。大きさは、
/// 一時の領域を経ずに直接確保し、上限に収まらなければ `HeapLimit` である。`usize` に収まらない
/// 大きさは、範囲の誤りでなく、上限超過として扱う(`make-string` と同じ)。
fn makeVector(services: *const Services, args: []const Value) Error!Value {
    const k = args[0].asFixnum() orelse return error.WrongType;
    const fill: Value = if (args.len > 1) args[1] else .fromBool(false);
    if (k < 0) return error.OutOfRange;
    const len = std.math.cast(usize, k) orelse return error.HeapLimit;
    return .fromVector(try services.heap.createVectorFilled(len, RepeatFiller{ .item = fill }));
}

/// `(vector-set! vector k obj)`: stores `obj` in the `k`th element (R7RS 6.8).
///
/// 定数のベクタは書き換えない(R7RS 3.4。`(vector-set! '#(0 1 2) 1 "doe")` は誤りである)。
/// 検査の順序は、型、不変、範囲である。
fn vectorSet(_: *const Services, args: []const Value) Error!Value {
    const v = args[0].asVector() orelse return error.WrongType;
    const k = args[1].asFixnum() orelse return error.WrongType;
    try immutable.requireMutable(args[0]);
    const index = std.math.cast(usize, k) orelse return error.OutOfRange;
    if (index >= v.items.len) return error.OutOfRange;
    v.items[index] = args[2];
    return .unspecified_value;
}

/// `(vector->list vector)`, `(vector->list vector start)` and
/// `(vector->list vector start end)`: a new list of the elements from `start` up to `end`
/// (R7RS 6.8).
///
/// 要素の数だけペアを作る。確保が失敗したときの途中のペアはゴミで、次の境目で回収される。
/// 後ろから作るので、尾へのポインタを持たない。
fn vectorToList(services: *const Services, args: []const Value) Error!Value {
    const v = args[0].asVector() orelse return error.WrongType;
    const operands = try RangeOperands.of(args, 1);
    const range = try resolveRange(operands, v.items.len);
    var list: Value = .empty_list_value;
    var i = range.end;
    while (i > range.start) {
        i -= 1;
        list = try services.heap.cons(v.items[i], list);
    }
    return list;
}

/// Writes the elements of the list `list`, which is a proper list.
const ListFiller = struct {
    list: Value,

    pub fn fill(self: ListFiller, items: []Value) void {
        var rest = self.list;
        for (items) |*slot| {
            const p = rest.asPair().?;
            slot.* = p.car;
            rest = p.cdr;
        }
    }
};

/// `(list->vector list)`: a new vector of the elements of the list (R7RS 6.8).
///
/// 先にリストを検査する。リストでないもの(末尾が空リストでない鎖と、輪になった鎖)は、
/// 型の誤りである。輪は `properLength` が止める。
fn listToVector(services: *const Services, args: []const Value) Error!Value {
    const len = pair_mod.properLength(args[0]) orelse return error.WrongType;
    return .fromVector(try services.heap.createVectorFilled(len, ListFiller{ .list = args[0] }));
}

/// `(vector-fill! vector fill)`, `(vector-fill! vector fill start)` and
/// `(vector-fill! vector fill start end)`: stores `fill` in the elements from `start` up to
/// `end` (R7RS 6.8).
fn vectorFill(_: *const Services, args: []const Value) Error!Value {
    const v = args[0].asVector() orelse return error.WrongType;
    const operands = try RangeOperands.of(args, 2);
    try immutable.requireMutable(args[0]);
    const range = try resolveRange(operands, v.items.len);
    @memset(v.items[range.start..range.end], args[1]);
    return .unspecified_value;
}

/// `(vector-copy vector)`, `(vector-copy vector start)` and `(vector-copy vector start end)`:
/// a new vector of the elements from `start` up to `end` (R7RS 6.8).
///
/// 結果は新しいベクタで、定数ではない。元の定数でも、写しは書き換えられる(R7RS 6.8 の例が、
/// そう書いている)。要素そのものは写さない。
fn vectorCopy(services: *const Services, args: []const Value) Error!Value {
    const v = args[0].asVector() orelse return error.WrongType;
    const operands = try RangeOperands.of(args, 1);
    const range = try resolveRange(operands, v.items.len);
    return .fromVector(try services.heap.createVector(v.items[range.start..range.end]));
}

/// `(vector-copy! to at from)`, `(vector-copy! to at from start)` and
/// `(vector-copy! to at from start end)`: copies the elements of `from` from `start` up to
/// `end` into `to`, from position `at` (R7RS 6.8).
///
/// 重なる場合は、一時のベクタに写してから書いたように振る舞う(`@memmove`)。`to` が定数なら
/// 断る。範囲が空でも断る。`from` は定数でもよい。
fn vectorCopyInto(_: *const Services, args: []const Value) Error!Value {
    const to = args[0].asVector() orelse return error.WrongType;
    const at_n = args[1].asFixnum() orelse return error.WrongType;
    const from = args[2].asVector() orelse return error.WrongType;
    const operands = try RangeOperands.of(args, 3);
    try immutable.requireMutable(args[0]);
    const plan = try range_mod.resolveCopy(at_n, to.items.len, operands, from.items.len);
    const source = from.items[plan.range.start..plan.range.end];
    @memmove(to.items[plan.at..][0..source.len], source);
    return .unspecified_value;
}

/// Writes the elements of the vectors in `parts`.
const AppendFiller = struct {
    parts: []const Value,

    pub fn fill(self: AppendFiller, items: []Value) void {
        var i: usize = 0;
        for (self.parts) |part| {
            const v = part.asVector().?.items;
            @memcpy(items[i..][0..v.len], v);
            i += v.len;
        }
    }
};

/// `(vector-append vector ...)`: a new vector of the elements of the vectors, in order
/// (R7RS 6.8). The result is a new vector even for one argument.
fn vectorAppend(services: *const Services, args: []const Value) Error!Value {
    var total: usize = 0;
    for (args) |a| {
        const v = a.asVector() orelse return error.WrongType;
        total = std.math.add(usize, total, v.items.len) catch return error.HeapLimit;
    }
    return .fromVector(try services.heap.createVectorFilled(total, AppendFiller{ .parts = args }));
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
        .{ .name = "make-vector", .min = 1, .max = 2 },
        .{ .name = "vector-set!", .min = 3, .max = 3 },
        .{ .name = "vector->list", .min = 1, .max = 3 },
        .{ .name = "list->vector", .min = 1, .max = 1 },
        .{ .name = "vector-fill!", .min = 2, .max = 4 },
        .{ .name = "vector-copy", .min = 1, .max = 3 },
        .{ .name = "vector-copy!", .min = 3, .max = 5 },
        .{ .name = "vector-append", .min = 0, .max = null },
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

fn call(f: *test_support.Fixture, name: []const u8, args: []const Value) Error!Value {
    return f.call(&primitives, name, args);
}

fn fix(n: i64) Value {
    return .fromFixnum(n);
}

/// A new vector of the integers `ints`.
fn ints(f: *test_support.Fixture, items: []const i64) !Value {
    var buf: [16]Value = undefined;
    for (items, 0..) |n, i| buf[i] = fix(n);
    return .fromVector(try f.heap.createVector(buf[0..items.len]));
}

/// A constant vector of the integers `items`, as a literal is.
fn constant(f: *test_support.Fixture, items: []const i64) !Value {
    const v = try ints(f, items);
    heap_mod.makeImmutable(v);
    return v;
}

fn expectInts(expected: []const i64, result: Value) !void {
    try std.testing.expectEqual(value.Kind.vector, result.kind());
    const items = result.asVector().?.items;
    try std.testing.expectEqual(expected.len, items.len);
    for (expected, items) |e, item| try std.testing.expectEqual(e, item.asFixnum().?);
}

fn expectList(expected: []const i64, result: Value) !void {
    var rest = result;
    for (expected) |e| {
        const p = rest.asPair() orelse return error.TestExpectedEqual;
        try std.testing.expectEqual(e, p.car.asFixnum().?);
        rest = p.cdr;
    }
    try std.testing.expectEqual(value.Kind.empty_list, rest.kind());
}

fn listOf(f: *test_support.Fixture, items: []const i64) !Value {
    var list: Value = .empty_list_value;
    var i = items.len;
    while (i > 0) {
        i -= 1;
        list = try f.heap.cons(fix(items[i]), list);
    }
    return list;
}

test "make-vector gives k copies of the fill, or of false" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    try expectInts(&.{}, try call(&f, "make-vector", &.{fix(0)}));
    try expectInts(&.{}, try call(&f, "make-vector", &.{ fix(0), fix(7) }));
    try expectInts(&.{ 7, 7, 7 }, try call(&f, "make-vector", &.{ fix(3), fix(7) }));
    const plain = (try call(&f, "make-vector", &.{fix(2)})).asVector().?;
    try std.testing.expectEqual(2, plain.items.len);
    for (plain.items) |item| {
        try std.testing.expectEqual(value.Kind.boolean, item.kind());
        try std.testing.expect(!item.isTrue());
    }
    // 同じ要素のオブジェクトを並べる。写しではない。
    const inner = try ints(&f, &.{1});
    const shared = (try call(&f, "make-vector", &.{ fix(2), inner })).asVector().?;
    try std.testing.expectEqual(inner.asVector().?, shared.items[0].asVector().?);
    try std.testing.expectEqual(inner.asVector().?, shared.items[1].asVector().?);
    // 呼ぶたびに新しいベクタで、定数ではない。
    const a = try call(&f, "make-vector", &.{fix(1)});
    const b = try call(&f, "make-vector", &.{fix(1)});
    try std.testing.expect(a.asVector().? != b.asVector().?);
    try std.testing.expect(!heap_mod.isImmutable(a));
}

test "make-vector reports a length that is not a count, and a negative one as out of range" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    try std.testing.expectError(error.WrongType, call(&f, "make-vector", &.{.fromCharacter('a')}));
    try std.testing.expectError(error.WrongType, call(&f, "make-vector", &.{ .empty_list_value, fix(0) }));
    try std.testing.expectError(error.OutOfRange, call(&f, "make-vector", &.{fix(-1)}));
    try std.testing.expectError(error.OutOfRange, call(&f, "make-vector", &.{ fix(std.math.minInt(i64)), fix(0) }));
}

test "make-vector past the limit is a heap limit before any element is made, whatever the size" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    f.heap.deinit();
    f.heap = .init(std.testing.allocator, .{ .limit = heap_mod.cellBytes(value.Vector) + 2 * @sizeOf(Value) });
    try std.testing.expectError(error.HeapLimit, call(&f, "make-vector", &.{fix(3)}));
    try std.testing.expectError(error.HeapLimit, call(&f, "make-vector", &.{ fix(1 << 40), fix(1) }));
    try std.testing.expectError(error.HeapLimit, call(&f, "make-vector", &.{fix(std.math.maxInt(i64))}));
    // 要素の大きさを掛けて桁があふれる大きさ。
    try std.testing.expectError(error.HeapLimit, call(&f, "make-vector", &.{ fix(std.math.maxInt(i64) / 4), fix(1) }));
    try std.testing.expectEqual(0, f.heap.accounted);
    try expectInts(&.{ 7, 7 }, try call(&f, "make-vector", &.{ fix(2), fix(7) }));
    try std.testing.expectEqual(heap_mod.cellBytes(value.Vector) + 2 * @sizeOf(Value), f.heap.accounted);
}

test "vector-set! stores an object in place, and any object" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    const v = try ints(&f, &.{ 1, 2, 3 });
    const r = try call(&f, "vector-set!", &.{ v, fix(1), fix(9) });
    try std.testing.expectEqual(value.Kind.unspecified, r.kind());
    try expectInts(&.{ 1, 9, 3 }, v);
    _ = try call(&f, "vector-set!", &.{ v, fix(0), v });
    try std.testing.expectEqual(v.asVector().?, v.asVector().?.items[0].asVector().?);
    _ = try call(&f, "vector-set!", &.{ v, fix(2), .empty_list_value });
    try std.testing.expectEqual(value.Kind.empty_list, v.asVector().?.items[2].kind());
    try std.testing.expectEqual(heap_mod.cellBytes(value.Vector) + 3 * @sizeOf(Value), f.heap.accounted);
}

test "vector-set! refuses what it cannot use, and leaves the vector as it was" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    const v = try ints(&f, &.{ 1, 2, 3 });
    for ([_]i64{ 3, 4, -1, std.math.minInt(i64), std.math.maxInt(i64), 1 << 32 }) |k| {
        try std.testing.expectError(error.OutOfRange, call(&f, "vector-set!", &.{ v, fix(k), fix(9) }));
    }
    try std.testing.expectError(error.OutOfRange, call(&f, "vector-set!", &.{ try ints(&f, &.{}), fix(0), fix(9) }));
    try std.testing.expectError(error.WrongType, call(&f, "vector-set!", &.{ v, .fromCharacter('a'), fix(1) }));
    try std.testing.expectError(error.WrongType, call(&f, "vector-set!", &.{ .empty_list_value, fix(0), fix(1) }));
    try std.testing.expectError(error.WrongType, call(&f, "vector-set!", &.{ try f.heap.cons(fix(1), fix(2)), fix(99), fix(1) }));
    try expectInts(&.{ 1, 2, 3 }, v);
}

test "vector-set! refuses a constant, after the types and before the range" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    const c = try constant(&f, &.{ 0, 1, 2 });
    try std.testing.expectError(error.Immutable, call(&f, "vector-set!", &.{ c, fix(1), fix(9) }));
    try expectInts(&.{ 0, 1, 2 }, c);
    try std.testing.expectError(error.WrongType, call(&f, "vector-set!", &.{ c, .fromCharacter('a'), fix(1) }));
    try std.testing.expectError(error.Immutable, call(&f, "vector-set!", &.{ c, fix(99), fix(9) }));
    try std.testing.expectError(error.Immutable, call(&f, "vector-set!", &.{ c, fix(-1), fix(9) }));
    try std.testing.expectError(error.Immutable, call(&f, "vector-set!", &.{ try constant(&f, &.{}), fix(0), fix(9) }));
}

test "vector->list and list->vector carry the elements in order, and the range of vector->list is checked" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    const v = try ints(&f, &.{ 1, 2, 3, 4, 5 });
    try expectList(&.{ 1, 2, 3, 4, 5 }, try call(&f, "vector->list", &.{v}));
    try expectList(&.{ 3, 4, 5 }, try call(&f, "vector->list", &.{ v, fix(2) }));
    try expectList(&.{ 2, 3 }, try call(&f, "vector->list", &.{ v, fix(1), fix(3) }));
    try expectList(&.{}, try call(&f, "vector->list", &.{ v, fix(5) }));
    try expectList(&.{}, try call(&f, "vector->list", &.{ v, fix(2), fix(2) }));
    try expectList(&.{}, try call(&f, "vector->list", &.{try ints(&f, &.{})}));
    // 要素そのものがペアに入る。
    const inner = try ints(&f, &.{9});
    const holder: Value = .fromVector(try f.heap.createVector(&.{inner}));
    try std.testing.expectEqual(inner.asVector().?, (try call(&f, "vector->list", &.{holder})).asPair().?.car.asVector().?);
    // 定数のベクタから作ったリストは定数ではない。
    const from_constant = try call(&f, "vector->list", &.{try constant(&f, &.{1})});
    try std.testing.expect(!heap_mod.isImmutable(from_constant));
    try expectInts(&.{ 1, 2, 3 }, try call(&f, "list->vector", &.{try listOf(&f, &.{ 1, 2, 3 })}));
    try expectInts(&.{}, try call(&f, "list->vector", &.{.empty_list_value}));
    const made = try call(&f, "list->vector", &.{try listOf(&f, &.{1})});
    try std.testing.expect(!heap_mod.isImmutable(made));
    const bad = [_][2]?i64{ .{ 6, null }, .{ 0, 6 }, .{ 3, 2 }, .{ -1, null }, .{ 0, -1 }, .{ std.math.minInt(i64), null }, .{ 0, std.math.maxInt(i64) }, .{ 1 << 32, 1 << 32 } };
    for (bad) |r| {
        var args: [3]Value = .{ v, fix(r[0].?), undefined };
        var n: usize = 2;
        if (r[1]) |e| {
            args[2] = fix(e);
            n = 3;
        }
        try std.testing.expectError(error.OutOfRange, call(&f, "vector->list", args[0..n]));
    }
    try std.testing.expectError(error.WrongType, call(&f, "vector->list", &.{ .empty_list_value, fix(9) }));
    try std.testing.expectError(error.WrongType, call(&f, "vector->list", &.{ v, .fromCharacter('a') }));
    try std.testing.expectError(error.WrongType, call(&f, "vector->list", &.{ v, fix(9), .fromCharacter('a') }));
}

test "list->vector reports what is not a list, and a list that never ends" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    try std.testing.expectError(error.WrongType, call(&f, "list->vector", &.{fix(1)}));
    try std.testing.expectError(error.WrongType, call(&f, "list->vector", &.{try ints(&f, &.{1})}));
    try std.testing.expectError(error.WrongType, call(&f, "list->vector", &.{try f.heap.cons(fix(1), fix(2))}));
    const ring = try listOf(&f, &.{ 1, 2, 3 });
    ring.asPair().?.cdr.asPair().?.cdr.asPair().?.cdr = ring;
    try std.testing.expectError(error.WrongType, call(&f, "list->vector", &.{ring}));
    // 失敗は何も確保しない。
    try std.testing.expectEqual(heap_mod.cellBytes(value.Pair) * 4 + heap_mod.cellBytes(value.Vector) + @sizeOf(Value), f.heap.accounted);
}

test "vector-fill! stores the object in the range, and in the whole vector by default" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    const a = try ints(&f, &.{ 1, 2, 3, 4, 5 });
    const r = try call(&f, "vector-fill!", &.{ a, fix(0), fix(2), fix(4) });
    try std.testing.expectEqual(value.Kind.unspecified, r.kind());
    try expectInts(&.{ 1, 2, 0, 0, 5 }, a);
    _ = try call(&f, "vector-fill!", &.{ a, fix(7), fix(3) });
    try expectInts(&.{ 1, 2, 0, 7, 7 }, a);
    _ = try call(&f, "vector-fill!", &.{ a, fix(8) });
    try expectInts(&.{ 8, 8, 8, 8, 8 }, a);
    _ = try call(&f, "vector-fill!", &.{ a, fix(1), fix(5), fix(5) });
    _ = try call(&f, "vector-fill!", &.{ a, fix(1), fix(2), fix(2) });
    try expectInts(&.{ 8, 8, 8, 8, 8 }, a);
    // 任意の値を並べてよい。
    _ = try call(&f, "vector-fill!", &.{ a, a, fix(1), fix(2) });
    try std.testing.expectEqual(a.asVector().?, a.asVector().?.items[1].asVector().?);
}

test "vector-fill! refuses what it cannot use, a constant before the range, and leaves the vector as it was" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    const a = try ints(&f, &.{ 1, 2, 3 });
    for ([_][2]i64{ .{ 4, 4 }, .{ 0, 4 }, .{ 2, 1 }, .{ -1, 2 }, .{ 0, -1 }, .{ 0, std.math.maxInt(i64) }, .{ 1 << 32, 1 << 32 } }) |r| {
        try std.testing.expectError(error.OutOfRange, call(&f, "vector-fill!", &.{ a, fix(0), fix(r[0]), fix(r[1]) }));
    }
    try std.testing.expectError(error.OutOfRange, call(&f, "vector-fill!", &.{ a, fix(0), fix(4) }));
    try std.testing.expectError(error.WrongType, call(&f, "vector-fill!", &.{ .empty_list_value, fix(0) }));
    try std.testing.expectError(error.WrongType, call(&f, "vector-fill!", &.{ a, fix(0), .fromCharacter('a') }));
    try std.testing.expectError(error.WrongType, call(&f, "vector-fill!", &.{ a, fix(0), fix(9), .fromCharacter('a') }));
    try expectInts(&.{ 1, 2, 3 }, a);
    const c = try constant(&f, &.{ 1, 2, 3 });
    try std.testing.expectError(error.Immutable, call(&f, "vector-fill!", &.{ c, fix(0) }));
    try std.testing.expectError(error.Immutable, call(&f, "vector-fill!", &.{ c, fix(0), fix(1), fix(1) }));
    try std.testing.expectError(error.Immutable, call(&f, "vector-fill!", &.{ c, fix(0), fix(9) }));
    try std.testing.expectError(error.Immutable, call(&f, "vector-fill!", &.{ try constant(&f, &.{}), fix(0) }));
    try std.testing.expectError(error.WrongType, call(&f, "vector-fill!", &.{ c, fix(0), .fromCharacter('a') }));
    try expectInts(&.{ 1, 2, 3 }, c);
}

test "vector-copy gives a new vector of the elements in the range, a constant source included" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    const a = try constant(&f, &.{ 1, 8, 2, 8 });
    try expectInts(&.{ 1, 8, 2, 8 }, try call(&f, "vector-copy", &.{a}));
    try expectInts(&.{ 2, 8 }, try call(&f, "vector-copy", &.{ a, fix(2) }));
    try expectInts(&.{ 8, 2 }, try call(&f, "vector-copy", &.{ a, fix(1), fix(3) }));
    try expectInts(&.{}, try call(&f, "vector-copy", &.{ a, fix(4) }));
    try expectInts(&.{}, try call(&f, "vector-copy", &.{ a, fix(2), fix(2) }));
    // 写しは新しいオブジェクトで、定数ではなく、書き換えても元は変わらない(原文の例)。
    const b = try call(&f, "vector-copy", &.{a});
    try std.testing.expect(b.asVector().? != a.asVector().?);
    try std.testing.expect(!heap_mod.isImmutable(b));
    _ = try call(&f, "vector-set!", &.{ b, fix(0), fix(3) });
    try expectInts(&.{ 3, 8, 2, 8 }, b);
    try expectInts(&.{ 1, 8, 2, 8 }, a);
    // 要素は写さない(`eqv?` で同じ)。
    const inner = try ints(&f, &.{1});
    const holder: Value = .fromVector(try f.heap.createVector(&.{inner}));
    try std.testing.expectEqual(inner.asVector().?, (try call(&f, "vector-copy", &.{holder})).asVector().?.items[0].asVector().?);
    const bad = [_][2]i64{ .{ 5, 5 }, .{ 0, 5 }, .{ 3, 2 }, .{ -1, 2 }, .{ 0, -1 }, .{ 0, std.math.maxInt(i64) }, .{ 1 << 32, 1 << 32 } };
    for (bad) |r| try std.testing.expectError(error.OutOfRange, call(&f, "vector-copy", &.{ a, fix(r[0]), fix(r[1]) }));
    try std.testing.expectError(error.OutOfRange, call(&f, "vector-copy", &.{ a, fix(5) }));
    try std.testing.expectError(error.WrongType, call(&f, "vector-copy", &.{ .empty_list_value, fix(5) }));
    try std.testing.expectError(error.WrongType, call(&f, "vector-copy", &.{ a, fix(9), .fromCharacter('a') }));
}

test "vector-copy! copies the elements of the range to the position, as the report's example does" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    const a = try ints(&f, &.{ 1, 2, 3, 4, 5 });
    const b = try ints(&f, &.{ 10, 20, 30, 40, 50 });
    const r = try call(&f, "vector-copy!", &.{ b, fix(1), a, fix(0), fix(2) });
    try std.testing.expectEqual(value.Kind.unspecified, r.kind());
    try expectInts(&.{ 10, 1, 2, 40, 50 }, b);
    try expectInts(&.{ 1, 2, 3, 4, 5 }, a);
    const c = try ints(&f, &.{ 0, 0, 0, 0, 0 });
    _ = try call(&f, "vector-copy!", &.{ c, fix(0), a });
    try expectInts(&.{ 1, 2, 3, 4, 5 }, c);
    _ = try call(&f, "vector-copy!", &.{ c, fix(0), try ints(&f, &.{ 9, 8, 7 }), fix(1) });
    try expectInts(&.{ 8, 7, 3, 4, 5 }, c);
    // 定数の元から写せる。
    _ = try call(&f, "vector-copy!", &.{ c, fix(3), try constant(&f, &.{ 6, 6 }) });
    try expectInts(&.{ 8, 7, 3, 6, 6 }, c);
}

test "vector-copy! of ranges that overlap acts as if the source were copied first" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    const a = try ints(&f, &.{ 1, 2, 3, 4, 5 });
    _ = try call(&f, "vector-copy!", &.{ a, fix(1), a, fix(0), fix(4) });
    try expectInts(&.{ 1, 1, 2, 3, 4 }, a);
    const b = try ints(&f, &.{ 1, 2, 3, 4, 5 });
    _ = try call(&f, "vector-copy!", &.{ b, fix(0), b, fix(1), fix(5) });
    try expectInts(&.{ 2, 3, 4, 5, 5 }, b);
    const c = try ints(&f, &.{ 1, 2, 3 });
    _ = try call(&f, "vector-copy!", &.{ c, fix(1), c, fix(1) });
    try expectInts(&.{ 1, 2, 3 }, c);
}

test "vector-copy! reports the arguments it cannot use, before it changes anything" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    const to = try ints(&f, &.{ 1, 2, 3 });
    const from = try ints(&f, &.{ 7, 8, 9, 10 });
    const cases = [_][]const Value{
        &.{ to, fix(4), from, fix(0), fix(0) },
        &.{ to, fix(-1), from },
        &.{ to, fix(std.math.maxInt(i64)), from },
        &.{ to, fix(0), from, fix(0), fix(5) },
        &.{ to, fix(0), from, fix(3), fix(2) },
        &.{ to, fix(0), from, fix(-1) },
        &.{ to, fix(0), from, fix(0), fix(4) },
        &.{ to, fix(1), from, fix(0), fix(3) },
        &.{ to, fix(3), from, fix(0), fix(1) },
        &.{ to, fix(0), from, fix(1 << 32) },
    };
    for (cases) |args| try std.testing.expectError(error.OutOfRange, call(&f, "vector-copy!", args));
    try std.testing.expectError(error.WrongType, call(&f, "vector-copy!", &.{ .empty_list_value, fix(0), from }));
    try std.testing.expectError(error.WrongType, call(&f, "vector-copy!", &.{ to, .fromCharacter('a'), from }));
    try std.testing.expectError(error.WrongType, call(&f, "vector-copy!", &.{ to, fix(0), .empty_list_value }));
    try std.testing.expectError(error.WrongType, call(&f, "vector-copy!", &.{ to, fix(0), from, .fromCharacter('a') }));
    try std.testing.expectError(error.WrongType, call(&f, "vector-copy!", &.{ to, fix(99), from, fix(99), .fromCharacter('a') }));
    try expectInts(&.{ 1, 2, 3 }, to);
    _ = try call(&f, "vector-copy!", &.{ to, fix(3), from, fix(1), fix(1) });
    _ = try call(&f, "vector-copy!", &.{ to, fix(0), from, fix(1), fix(4) });
    try expectInts(&.{ 8, 9, 10 }, to);
}

test "vector-copy! refuses a destination that is a constant, even to copy nothing, and takes a constant source" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    const c = try constant(&f, &.{ 1, 2, 3 });
    const from = try ints(&f, &.{ 7, 8 });
    try std.testing.expectError(error.Immutable, call(&f, "vector-copy!", &.{ c, fix(0), from }));
    try std.testing.expectError(error.Immutable, call(&f, "vector-copy!", &.{ c, fix(0), from, fix(1), fix(1) }));
    try std.testing.expectError(error.Immutable, call(&f, "vector-copy!", &.{ try constant(&f, &.{}), fix(0), try ints(&f, &.{}) }));
    try std.testing.expectError(error.WrongType, call(&f, "vector-copy!", &.{ c, fix(0), .empty_list_value }));
    try std.testing.expectError(error.Immutable, call(&f, "vector-copy!", &.{ c, fix(99), from }));
    try std.testing.expectError(error.Immutable, call(&f, "vector-copy!", &.{ c, fix(0), from, fix(5) }));
    try expectInts(&.{ 1, 2, 3 }, c);
}

test "vector-append gives a new vector of the elements in order, and of one vector a copy of it" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    try expectInts(&.{}, try call(&f, "vector-append", &.{}));
    try expectInts(&.{ 1, 2, 3, 4 }, try call(&f, "vector-append", &.{ try ints(&f, &.{ 1, 2 }), try ints(&f, &.{ 3, 4 }) }));
    try expectInts(&.{ 1, 2 }, try call(&f, "vector-append", &.{ try ints(&f, &.{}), try ints(&f, &.{ 1, 2 }), try ints(&f, &.{}) }));
    const only = try constant(&f, &.{ 1, 2 });
    const copy = try call(&f, "vector-append", &.{only});
    try expectInts(&.{ 1, 2 }, copy);
    try std.testing.expect(copy.asVector().? != only.asVector().?);
    try std.testing.expect(!heap_mod.isImmutable(copy));
    try expectInts(&.{ 1, 2, 1, 2 }, try call(&f, "vector-append", &.{ only, only }));
    try std.testing.expectError(error.WrongType, call(&f, "vector-append", &.{ only, .empty_list_value }));
    try std.testing.expectError(error.WrongType, call(&f, "vector-append", &.{ .fromFixnum(1), only }));
}

test "vector-append is held to the limit by the elements of the whole result" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    const a = try ints(&f, &.{ 1, 2, 3 });
    const b = try ints(&f, &.{ 4, 5, 6 });
    const empty = try ints(&f, &.{});
    const c = try ints(&f, &.{ 4, 5 });
    const used = f.heap.accounted;
    f.heap.options.limit = used + heap_mod.cellBytes(value.Vector) + 5 * @sizeOf(Value);
    try std.testing.expectError(error.HeapLimit, call(&f, "vector-append", &.{ a, b }));
    try std.testing.expectEqual(used, f.heap.accounted);
    try expectInts(&.{ 1, 2, 3, 4, 5 }, try call(&f, "vector-append", &.{ a, empty, c }));
}

test "list->vector and vector-copy are held to the limit by their elements" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    const list = try listOf(&f, &.{ 1, 2, 3 });
    const v = try ints(&f, &.{ 1, 2, 3 });
    const used = f.heap.accounted;
    f.heap.options.limit = used + heap_mod.cellBytes(value.Vector) + 2 * @sizeOf(Value);
    try std.testing.expectError(error.HeapLimit, call(&f, "list->vector", &.{list}));
    try std.testing.expectError(error.HeapLimit, call(&f, "vector-copy", &.{v}));
    try std.testing.expectEqual(used, f.heap.accounted);
    try expectInts(&.{ 1, 2 }, try call(&f, "vector-copy", &.{ v, fix(0), fix(2) }));
}

test "a collection keeps the elements of the vectors the primitives made" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    const s: Value = .fromString(try f.heap.createString("あ"));
    const filled = try call(&f, "make-vector", &.{ fix(2), s });
    const appended = try call(&f, "vector-append", &.{ filled, filled });
    _ = try call(&f, "make-vector", &.{fix(100)});
    const Roots = struct {
        values: []const Value,
        pub fn mark(self: @This(), marker: *heap_mod.Marker) void {
            for (self.values) |v| marker.value(v);
        }
    };
    f.heap.collect(Roots{ .values = &.{appended} });
    // 残るのは、結合したベクタと、その要素の文字列である。元のベクタは、要素の写しを
    // 取ったあとは指されないので回収される。
    try std.testing.expectEqual(2, f.heap.count);
    for (appended.asVector().?.items) |item| try std.testing.expectEqualStrings("あ", item.asString().?.bytes);
}
