//! Equivalence predicates (R7RS 6.1): `eq?`, `eqv?` and `equal?`.
//!
//! `eq?` と `eqv?` の実体は `Value` の関数である(値の表現を隠す、ADR-0002)。`equal?`
//! は構造を比べるのでここに置く。
//!
//! 訪問済みの集合の実装は、番地の union-find である(選んだ理由は `isEqual` の doc コメント)。

const std = @import("std");
const value = @import("../value.zig");
const heap_mod = @import("../heap.zig");
const Value = value.Value;
const Primitive = value.Primitive;
const Services = value.Services;
const PrimitiveError = value.PrimitiveError;

pub const Error = PrimitiveError;

pub const primitives = [_]Primitive{
    .{ .name = "eq?", .min_args = 2, .max_args = 2, .body = .{ .pure = &eq } },
    .{ .name = "eqv?", .min_args = 2, .max_args = 2, .body = .{ .pure = &eqv } },
    .{ .name = "equal?", .min_args = 2, .max_args = 2, .body = .{ .pure = &equal } },
};

/// `(eq? obj1 obj2)` (R7RS 6.1).
fn eq(_: *const Services, args: []const Value) Error!Value {
    return .fromBool(args[0].isEq(args[1]));
}

/// `(eqv? obj1 obj2)` (R7RS 6.1).
fn eqv(_: *const Services, args: []const Value) Error!Value {
    return .fromBool(args[0].isEqv(args[1]));
}

/// `(equal? obj1 obj2)` (R7RS 6.1).
fn equal(services: *const Services, args: []const Value) Error!Value {
    const heap = services.heap;
    // Why: 訪問済みの集合は、比べるデータの大きさとともに伸びる作業領域なので、ヒープの
    // 上限に計上する(`heap.Charged`。docs/design/runtime.md の計上の対象)。計上は、
    // ふつうは数えるだけで、上限の検査は展開の間だけ効く(`external_enforced`)ので、
    // この間も検査を入れる。確保を断られたことは、`external_refused` で見分ける。
    // 比較は機械のステップの外で走らず、展開と重ならないので、前の値を戻せば足りる。
    const was_enforced = heap.external_enforced;
    const was_refused = heap.external_refused;
    heap.external_enforced = true;
    heap.external_refused = false;
    defer {
        heap.external_enforced = was_enforced;
        heap.external_refused = was_refused;
    }
    var charged: heap_mod.Charged = .{ .heap = heap, .backing = heap.backing };
    const result = isEqual(services.scratch, charged.allocator(), args[0], args[1]) catch
        return if (heap.external_refused) error.HeapLimit else error.OutOfMemory;
    return .fromBool(result);
}

/// What is left to compare once the pair or vector being compared is descended
/// into.
const Work = union(enum) {
    /// Two values: the cdrs of two pairs whose cars are being compared.
    values: struct { a: Value, b: Value },
    /// The elements of two vectors of the same length, from `next` on.
    elements: struct { a: []const Value, b: []const Value, next: usize },
};

/// A stack of `Work` that lives in the Zig stack while it is small and moves to
/// the scratch space when it is not.
///
/// 深い入れ子の `equal?` が Zig の再帰でスタックを使い切らないようにするための作業
/// スタックである。数が少ないうちは一時領域を使わない。`deinit` が、取った領域を返す。
const Stack = struct {
    const inline_capacity = 8;

    inline_items: [inline_capacity]Work = undefined,
    /// Empty while `inline_items` is in use.
    spill: []Work = &.{},
    len: usize = 0,
    scratch: std.mem.Allocator,

    fn items(self: *Stack) []Work {
        return if (self.spill.len == 0) &self.inline_items else self.spill;
    }

    fn push(self: *Stack, work: Work) error{OutOfMemory}!void {
        if (self.len == self.items().len) try self.grow();
        self.items()[self.len] = work;
        self.len += 1;
    }

    fn pop(self: *Stack) ?Work {
        if (self.len == 0) return null;
        self.len -= 1;
        return self.items()[self.len];
    }

    /// Doubles the capacity.
    /// 失敗したときは、`spill` を変えない。`deinit` が持っているものを返せるようにする。
    fn grow(self: *Stack) error{OutOfMemory}!void {
        if (self.spill.len == 0) {
            const bigger = try self.scratch.alloc(Work, inline_capacity * 2);
            @memcpy(bigger[0..self.len], self.inline_items[0..self.len]);
            self.spill = bigger;
        } else {
            self.spill = try self.scratch.realloc(self.spill, self.spill.len *| 2);
        }
    }

    /// Returns what the stack took from the scratch space.
    /// 一時領域から取るのは、常に高々1つの領域である。
    fn deinit(self: *Stack) void {
        if (self.spill.len != 0) self.scratch.free(self.spill);
    }
};

/// The number of descents into pairs and vectors that are not recorded.
/// 短いデータの比較で、訪問済みの集合の確保を避けるための数である。これを超えて降りる
/// 比較だけが、集合を引き始める。
const unrecorded_steps = 256;

/// The pairs and vectors, by address, that `isEqual` has taken to be equal, as a
/// union-find: the ones that fall in one class are taken to be equal.
///
/// 木の根を持つ表だけを持ち、親のない節点は表に載せない(自分が根である)。
const Visited = struct {
    parent: std.AutoHashMapUnmanaged(usize, usize) = .empty,
    alloc: std.mem.Allocator,

    fn deinit(self: *Visited) void {
        self.parent.deinit(self.alloc);
    }

    /// The root of the class of `node`. 道の半分を縮める(path halving)。
    fn find(self: *Visited, node: usize) usize {
        var n = node;
        while (self.parent.getPtr(n)) |parent| {
            if (self.parent.get(parent.*)) |grand| parent.* = grand;
            n = parent.*;
        }
        return n;
    }

    /// Whether `x` and `y` are in one class already. If not, puts them in one.
    /// 併合のたびに根が1つ減るので、表の項目の数は、比べた節点の数を超えない。
    fn seen(self: *Visited, x: usize, y: usize) error{OutOfMemory}!bool {
        const rx = self.find(x);
        const ry = self.find(y);
        if (rx == ry) return true;
        try self.parent.put(self.alloc, rx, ry);
        return false;
    }
};

/// Whether `a` and `b` are `equal?`: pairs and vectors compared by their parts,
/// strings by their characters, everything else by `eqv?` (R7RS 6.1).
///
/// Zig の再帰を使わず、`Stack` に未比較の組を積んで進める。ペアは car を先に降り、
/// cdr を積む。長いリストは cdr を積んでは取り出すので、積みは深くならない。ベクタは、
/// 次の要素の位置を積む。
///
/// 循環したデータと、同じ部分を何度も指すデータ(共有構造)のために、訪問済みの集合
/// (`Visited`、番地の union-find)を持つ。比べる2つのペア(ベクタ)を併合し、同じ類に
/// 再び出会ったら、等しいとして打ち切る。等しいという仮定の下で比べて矛盾が無ければ
/// 等しい、という扱いで、循環したデータでも止まり、共有構造の比較は節点の数に比例する
/// 時間で終わる。先頭の `unrecorded_steps` 回の降下は記録しないので、短いデータの比較は
/// 集合を確保しない。
///
/// 選んだ理由は、集合の大きさの増え方である。組を鍵にしたハッシュ表では、長さの互いに
/// 素な2つの輪の比較が、長さの積だけの項目を持つ。union-find は和に収まる。再現の手順は、
/// テスト `equal? of two rings of coprime lengths keeps the visited set in proportion to
/// their total length` で、集合の確保の総量が、輪の長さの和に比例する上限に収まることを
/// 確かめる。組を鍵にした実装に替えると、このテストが落ちる。2つの実装を、長い非循環
/// リスト・共有構造・互いに素な輪で比べた計測は、コミット 7d169b7 の
/// `BENCH visited structures`(`-Dslow=true`)にある。
///
/// `visited` は集合の確保元で、呼び出し側が計上に通す(`equal` は `heap.Charged` を通す)。
/// `scratch` は作業スタックだけに使う。
///
/// 同じペアやベクタの比較は、中を見ずに真とする。`eqv?` が真なら `equal?` も真だからである。
pub fn isEqual(scratch: std.mem.Allocator, visited_alloc: std.mem.Allocator, a: Value, b: Value) error{OutOfMemory}!bool {
    var stack: Stack = .{ .scratch = scratch };
    defer stack.deinit();
    var visited: Visited = .{ .alloc = visited_alloc };
    defer visited.deinit();
    var steps: usize = 0;
    var left = a;
    var right = b;
    while (true) {
        switch (left.kind()) {
            .pair => {
                const x = left.asPair().?;
                const y = right.asPair() orelse return false;
                if (x != y) {
                    steps +|= 1;
                    if (steps <= unrecorded_steps or !try visited.seen(@intFromPtr(x), @intFromPtr(y))) {
                        try stack.push(.{ .values = .{ .a = x.cdr, .b = y.cdr } });
                        left = x.car;
                        right = y.car;
                        continue;
                    }
                }
            },
            .vector => {
                const x = left.asVector().?;
                const y = right.asVector() orelse return false;
                if (x.items.len != y.items.len) return false;
                if (x != y and x.items.len > 0) {
                    steps +|= 1;
                    if (steps <= unrecorded_steps or !try visited.seen(@intFromPtr(x), @intFromPtr(y))) {
                        if (x.items.len > 1) try stack.push(.{ .elements = .{ .a = x.items, .b = y.items, .next = 1 } });
                        left = x.items[0];
                        right = y.items[0];
                        continue;
                    }
                }
            },
            .string => {
                const y = right.asString() orelse return false;
                if (!std.mem.eql(u8, left.asString().?.bytes, y.bytes)) return false;
            },
            .bytevector => {
                const y = right.asBytevector() orelse return false;
                if (!std.mem.eql(u8, left.asBytevector().?.bytes, y.bytes)) return false;
            },
            // Why: `else` にしない。`Kind` に種別を足したとき、ここがコンパイルエラーになって、
            // `equal?` が中身を比べるべき種別を見落とさないようにする。
            .fixnum, .boolean, .empty_list, .symbol, .primitive, .closure, .unspecified, .uninitialized, .condition, .character, .alias, .record, .record_type, .continuation, .multiple_values, .parameter, .eof, .promise, .flonum, .bignum, .ratnum, .compnum, .port => {
                if (!left.isEqv(right)) return false;
            },
        }
        const work = stack.pop() orelse return true;
        switch (work) {
            .values => |v| {
                left = v.a;
                right = v.b;
            },
            .elements => |e| {
                if (e.next + 1 < e.a.len) try stack.push(.{ .elements = .{ .a = e.a, .b = e.b, .next = e.next + 1 } });
                left = e.a[e.next];
                right = e.b[e.next];
            },
        }
    }
}

test {
    std.testing.refAllDecls(@This());
}

const test_support = @import("test_support.zig");
const tier = @import("../tier.zig");

fn callWith(f: *test_support.Fixture, name: []const u8, a: Value, b: Value) !bool {
    const v = try f.call(&primitives, name, &.{ a, b });
    try std.testing.expectEqual(.boolean, v.kind());
    return v.isTrue();
}

fn str(f: *test_support.Fixture, bytes: []const u8) !Value {
    return .fromString(try f.heap.createString(bytes));
}

fn vec(f: *test_support.Fixture, items: []const Value) !Value {
    return .fromVector(try f.heap.createVector(items));
}

fn cons(f: *test_support.Fixture, car: Value, cdr: Value) !Value {
    return f.heap.cons(car, cdr);
}

fn int(n: i64) Value {
    return .fromFixnum(n);
}

test "the primitives take the numbers of arguments the language gives them" {
    const expected = [_][]const u8{ "eq?", "eqv?", "equal?" };
    try std.testing.expectEqual(expected.len, primitives.len);
    for (expected, primitives) |name, p| {
        try std.testing.expectEqualStrings(name, p.name);
        try std.testing.expectEqual(2, p.min_args);
        try std.testing.expectEqual(2, p.max_args.?);
    }
}

test "eq? and eqv? compare numbers and characters by value and pairs by place" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    for ([_][]const u8{ "eq?", "eqv?" }) |name| {
        try std.testing.expect(try callWith(&f, name, int(5), int(5)));
        try std.testing.expect(!try callWith(&f, name, int(5), int(6)));
        try std.testing.expect(try callWith(&f, name, .fromCharacter('a'), .fromCharacter('a')));
        try std.testing.expect(!try callWith(&f, name, int(97), .fromCharacter('a')));
        const p = try cons(&f, int(1), .empty_list_value);
        const q = try cons(&f, int(1), .empty_list_value);
        try std.testing.expect(try callWith(&f, name, p, p));
        try std.testing.expect(!try callWith(&f, name, p, q));
        const s = try str(&f, "abc");
        const t = try str(&f, "abc");
        try std.testing.expect(try callWith(&f, name, s, s));
        try std.testing.expect(!try callWith(&f, name, s, t));
        const v = try vec(&f, &.{int(1)});
        const w = try vec(&f, &.{int(1)});
        try std.testing.expect(try callWith(&f, name, v, v));
        try std.testing.expect(!try callWith(&f, name, v, w));
    }
}

test "equal? compares both the car and the cdr of a pair" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    const base = try cons(&f, int(1), int(2));
    try std.testing.expect(try callWith(&f, "equal?", base, try cons(&f, int(1), int(2))));
    try std.testing.expect(!try callWith(&f, "equal?", base, try cons(&f, int(0), int(2))));
    try std.testing.expect(!try callWith(&f, "equal?", base, try cons(&f, int(1), int(3))));
    try std.testing.expect(!try callWith(&f, "equal?", base, int(1)));
    try std.testing.expect(!try callWith(&f, "equal?", int(1), base));
}

test "equal? compares the cdr of a pair after it has compared a car that is a pair" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    const inner = try cons(&f, int(1), .empty_list_value);
    const same = try cons(&f, try cons(&f, int(1), .empty_list_value), int(2));
    const other_cdr = try cons(&f, try cons(&f, int(1), .empty_list_value), int(3));
    const other_car = try cons(&f, try cons(&f, int(9), .empty_list_value), int(2));
    const base = try cons(&f, inner, int(2));
    try std.testing.expect(try callWith(&f, "equal?", base, same));
    try std.testing.expect(!try callWith(&f, "equal?", base, other_cdr));
    try std.testing.expect(!try callWith(&f, "equal?", base, other_car));
}

test "equal? tells a list that ends sooner from one that goes on" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    const two = try cons(&f, int(1), try cons(&f, int(2), .empty_list_value));
    const three = try cons(&f, int(1), try cons(&f, int(2), try cons(&f, int(3), .empty_list_value)));
    try std.testing.expect(!try callWith(&f, "equal?", two, three));
    try std.testing.expect(!try callWith(&f, "equal?", three, two));
    try std.testing.expect(!try callWith(&f, "equal?", two, .empty_list_value));
    try std.testing.expect(!try callWith(&f, "equal?", .empty_list_value, two));
    try std.testing.expect(try callWith(&f, "equal?", .empty_list_value, .empty_list_value));
}

test "equal? compares the length and the elements of vectors" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    const base = try vec(&f, &.{ int(1), int(2), int(3) });
    try std.testing.expect(try callWith(&f, "equal?", base, try vec(&f, &.{ int(1), int(2), int(3) })));
    try std.testing.expect(!try callWith(&f, "equal?", base, try vec(&f, &.{ int(0), int(2), int(3) })));
    try std.testing.expect(!try callWith(&f, "equal?", base, try vec(&f, &.{ int(1), int(0), int(3) })));
    try std.testing.expect(!try callWith(&f, "equal?", base, try vec(&f, &.{ int(1), int(2), int(0) })));
    // 一方が他方の先頭部分のとき、どちらが長くても偽になる。
    try std.testing.expect(!try callWith(&f, "equal?", base, try vec(&f, &.{ int(1), int(2) })));
    try std.testing.expect(!try callWith(&f, "equal?", try vec(&f, &.{ int(1), int(2) }), base));
    try std.testing.expect(!try callWith(&f, "equal?", try vec(&f, &.{}), try vec(&f, &.{int(1)})));
    try std.testing.expect(!try callWith(&f, "equal?", try vec(&f, &.{int(1)}), try vec(&f, &.{})));
    try std.testing.expect(try callWith(&f, "equal?", try vec(&f, &.{}), try vec(&f, &.{})));
    try std.testing.expect(!try callWith(&f, "equal?", base, .empty_list_value));
}

fn bvec(f: *test_support.Fixture, octets: []const u8) !Value {
    return .fromBytevector(try f.heap.createBytevector(octets));
}

test "equal? compares the bytes of bytevectors, and eqv? and eq? the objects" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    const base = try bvec(&f, &.{ 1, 2, 3 });
    try std.testing.expect(try callWith(&f, "equal?", base, try bvec(&f, &.{ 1, 2, 3 })));
    try std.testing.expect(try callWith(&f, "equal?", base, base));
    try std.testing.expect(try callWith(&f, "equal?", try bvec(&f, &.{}), try bvec(&f, &.{})));
    try std.testing.expect(!try callWith(&f, "equal?", base, try bvec(&f, &.{ 0, 2, 3 })));
    try std.testing.expect(!try callWith(&f, "equal?", base, try bvec(&f, &.{ 1, 2, 0 })));
    // 一方が他方の先頭部分のとき、どちらが長くても偽になる。
    try std.testing.expect(!try callWith(&f, "equal?", base, try bvec(&f, &.{ 1, 2 })));
    try std.testing.expect(!try callWith(&f, "equal?", try bvec(&f, &.{ 1, 2 }), base));
    try std.testing.expect(!try callWith(&f, "equal?", try bvec(&f, &.{}), try bvec(&f, &.{0})));
    // 同じ中身のベクタや文字列とは等しくない。
    try std.testing.expect(!try callWith(&f, "equal?", try bvec(&f, &.{1}), try vec(&f, &.{int(1)})));
    try std.testing.expect(!try callWith(&f, "equal?", try vec(&f, &.{int(1)}), try bvec(&f, &.{1})));
    try std.testing.expect(!try callWith(&f, "equal?", try bvec(&f, "a"), .fromString(try f.heap.createString("a"))));
    try std.testing.expect(!try callWith(&f, "equal?", base, .empty_list_value));
    // `eqv?` と `eq?` は同一性である。
    try std.testing.expect(try callWith(&f, "eqv?", base, base));
    try std.testing.expect(!try callWith(&f, "eqv?", base, try bvec(&f, &.{ 1, 2, 3 })));
    try std.testing.expect(!try callWith(&f, "eq?", base, try bvec(&f, &.{ 1, 2, 3 })));
    // ベクタの中のバイトベクタも中身で比べる。
    try std.testing.expect(try callWith(&f, "equal?", try vec(&f, &.{try bvec(&f, &.{ 1, 2 })}), try vec(&f, &.{try bvec(&f, &.{ 1, 2 })})));
    try std.testing.expect(!try callWith(&f, "equal?", try vec(&f, &.{try bvec(&f, &.{ 1, 2 })}), try vec(&f, &.{try bvec(&f, &.{ 1, 3 })})));
}

test "equal? looks inside the vectors that are inside vectors and pairs, and past them" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    const base = try vec(&f, &.{ int(1), try vec(&f, &.{ int(2), int(3) }), int(4) });
    try std.testing.expect(try callWith(&f, "equal?", base, try vec(&f, &.{ int(1), try vec(&f, &.{ int(2), int(3) }), int(4) })));
    try std.testing.expect(!try callWith(&f, "equal?", base, try vec(&f, &.{ int(1), try vec(&f, &.{ int(2), int(9) }), int(4) })));
    try std.testing.expect(!try callWith(&f, "equal?", base, try vec(&f, &.{ int(1), try vec(&f, &.{ int(2), int(3) }), int(9) })));
    // 要素の途中にあるベクタの後ろに、ペアのさらに後ろの要素が続く。
    const listed = try cons(&f, try vec(&f, &.{int(1)}), try cons(&f, int(2), .empty_list_value));
    try std.testing.expect(try callWith(&f, "equal?", listed, try cons(&f, try vec(&f, &.{int(1)}), try cons(&f, int(2), .empty_list_value))));
    try std.testing.expect(!try callWith(&f, "equal?", listed, try cons(&f, try vec(&f, &.{int(1)}), try cons(&f, int(3), .empty_list_value))));
    try std.testing.expect(!try callWith(&f, "equal?", listed, try cons(&f, try vec(&f, &.{int(9)}), try cons(&f, int(2), .empty_list_value))));
}

test "equal? compares strings by their characters and tells the kinds apart" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    try std.testing.expect(try callWith(&f, "equal?", try str(&f, "abc"), try str(&f, "abc")));
    try std.testing.expect(!try callWith(&f, "equal?", try str(&f, "abc"), try str(&f, "abd")));
    try std.testing.expect(!try callWith(&f, "equal?", try str(&f, "abc"), try str(&f, "ab")));
    try std.testing.expect(!try callWith(&f, "equal?", try str(&f, "ab"), try str(&f, "abc")));
    try std.testing.expect(try callWith(&f, "equal?", try str(&f, ""), try str(&f, "")));
    try std.testing.expect(try callWith(&f, "equal?", try str(&f, "あい"), try str(&f, "あい")));
    try std.testing.expect(!try callWith(&f, "equal?", try str(&f, "あい"), try str(&f, "あう")));
    try std.testing.expect(!try callWith(&f, "equal?", try str(&f, "a"), .fromCharacter('a')));
    try std.testing.expect(!try callWith(&f, "equal?", .fromCharacter('a'), try str(&f, "a")));
    try std.testing.expect(!try callWith(&f, "equal?", try str(&f, "a"), try vec(&f, &.{.fromCharacter('a')})));
}

test "equal? is true of the same pair or vector without looking inside it" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    const p = try cons(&f, int(1), try cons(&f, int(2), .empty_list_value));
    try std.testing.expect(try callWith(&f, "equal?", p, p));
    const v = try vec(&f, &.{ int(1), p });
    try std.testing.expect(try callWith(&f, "equal?", v, v));
}

test "equal? holds eqv? things equal" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    try std.testing.expect(try callWith(&f, "equal?", int(7), int(7)));
    try std.testing.expect(!try callWith(&f, "equal?", int(7), int(8)));
    try std.testing.expect(!try callWith(&f, "equal?", int(97), .fromCharacter('a')));
    try std.testing.expect(try callWith(&f, "equal?", .fromBool(true), .fromBool(true)));
    try std.testing.expect(!try callWith(&f, "equal?", .fromBool(false), .empty_list_value));
    try std.testing.expect(try callWith(&f, "equal?", .fromPrimitive(&primitives[0]), .fromPrimitive(&primitives[0])));
    try std.testing.expect(!try callWith(&f, "equal?", .fromPrimitive(&primitives[0]), .fromPrimitive(&primitives[1])));
}

/// A circular list holding `items` in turn, from the first pair on.
fn ringOf(f: *test_support.Fixture, items: []const Value) !Value {
    const head = try cons(f, items[0], .empty_list_value);
    var last = head;
    for (items[1..]) |item| {
        const next = try cons(f, item, .empty_list_value);
        last.asPair().?.cdr = next;
        last = next;
    }
    last.asPair().?.cdr = head;
    return head;
}

/// A circular list of `length` pairs that all hold `item`.
fn ring(f: *test_support.Fixture, length: usize, item: Value) !Value {
    const items = try std.testing.allocator.alloc(Value, length);
    defer std.testing.allocator.free(items);
    @memset(items, item);
    return ringOf(f, items);
}

test "equal? stops on circular lists, and tells the ones that differ from the ones that do not" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    // 長さを変える。比べる降下の数が、記録を始める数(`unrecorded_steps`)の前後に渡る。
    for ([_]usize{ 1, 2, 3, unrecorded_steps - 1, unrecorded_steps, unrecorded_steps + 1, 1000 }) |n| {
        try std.testing.expect(try callWith(&f, "equal?", try ring(&f, n, int(1)), try ring(&f, n, int(1))));
        try std.testing.expect(!try callWith(&f, "equal?", try ring(&f, n, int(1)), try ring(&f, n, int(2))));
    }
    // 長さが違っても、同じ無限のリストを表すなら等しい。
    try std.testing.expect(try callWith(&f, "equal?", try ring(&f, 2, int(1)), try ring(&f, 3, int(1))));
    try std.testing.expect(try callWith(&f, "equal?", try ringOf(&f, &.{ int(1), int(2) }), try ringOf(&f, &.{ int(1), int(2), int(1), int(2) })));
    try std.testing.expect(!try callWith(&f, "equal?", try ringOf(&f, &.{ int(1), int(2) }), try ringOf(&f, &.{ int(1), int(2), int(1), int(3) })));
    // 終わりのあるリストと輪は、輪の先が続く分だけ違う。
    const finite = try nest(&f, .cdr, 1000, .empty_list_value);
    try std.testing.expect(!try callWith(&f, "equal?", finite, try ring(&f, 3, int(1))));
    try std.testing.expect(!try callWith(&f, "equal?", try ring(&f, 3, int(1)), finite));
}

test "equal? stops on a pair or a vector that holds itself" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    const p = try cons(&f, int(1), .empty_list_value);
    p.asPair().?.car = p;
    const q = try cons(&f, int(1), .empty_list_value);
    q.asPair().?.car = q;
    try std.testing.expect(try callWith(&f, "equal?", p, q));
    const v = try vec(&f, &.{ int(1), int(2) });
    v.asVector().?.items[0] = v;
    const w = try vec(&f, &.{ int(1), int(2) });
    w.asVector().?.items[0] = w;
    try std.testing.expect(try callWith(&f, "equal?", v, w));
    // 自分を含むものと、含まないものは、別のものである。
    w.asVector().?.items[1] = int(3);
    try std.testing.expect(!try callWith(&f, "equal?", v, w));
}

test "equal? compares data that shares its parts in time that follows the depth" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    // 各段が、次の段を2回指す。記録が無ければ、比べる回数は2の段数乗になる。
    for ([_]bool{ false, true }) |as_vector| {
        var x: Value = int(1);
        var y: Value = int(1);
        var z: Value = int(2);
        for (0..3000) |_| {
            x = if (as_vector) try vec(&f, &.{ x, x }) else try cons(&f, x, x);
            y = if (as_vector) try vec(&f, &.{ y, y }) else try cons(&f, y, y);
            z = if (as_vector) try vec(&f, &.{ z, z }) else try cons(&f, z, z);
        }
        try std.testing.expect(try callWith(&f, "equal?", x, y));
        try std.testing.expect(!try callWith(&f, "equal?", x, z));
    }
}

test "equal? of two rings of coprime lengths keeps the visited set in proportion to their total length" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    const n = 1000;
    const m = 999;
    const a = try ring(&f, n, int(1));
    const b = try ring(&f, m, int(1));
    var counting = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    try std.testing.expect(try isEqual(std.testing.allocator, counting.allocator(), a, b));
    // 組を鍵にすると、n と m の積の項目を持つので、この上限を大きく超える。
    // 表は倍々に伸びるので、確保の総量は最後の大きさの2倍に収まり、1項目は鍵と値で
    // 16 バイトである。上限は、それに十分な余裕を見た値である。
    try std.testing.expect(counting.allocated_bytes <= 128 * (n + m));
    try std.testing.expectEqual(counting.allocated_bytes, counting.freed_bytes);
}

/// The bytes of `f`'s heap that the objects hold, plus `spare`, as its limit.
fn limitAbove(f: *test_support.Fixture, spare: usize) void {
    f.heap.options.limit = f.heap.accounted + spare;
}

test "equal? counts its visited set against the limit of the heap, and gives it back" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    const a = try nest(&f, .cdr, 5000, .empty_list_value);
    const b = try nest(&f, .cdr, 5000, .empty_list_value);
    // 数千のペアを比べる表は、数百バイトの余裕には収まらない。
    limitAbove(&f, 256);
    try std.testing.expectError(error.HeapLimit, callWith(&f, "equal?", a, b));
    try std.testing.expectEqual(0, f.heap.external);
    try std.testing.expect(!f.heap.external_enforced);
    try std.testing.expect(!f.heap.external_refused);
    // 余裕があれば通り、通ったあとに数えたものは戻る。
    limitAbove(&f, 1024 * 1024);
    try std.testing.expect(try callWith(&f, "equal?", a, b));
    try std.testing.expectEqual(0, f.heap.external);
    try std.testing.expect(!f.heap.external_enforced);
    // 短いデータの比較は、表を確保しないので、余裕が無くても通る。
    const c = try nest(&f, .cdr, unrecorded_steps - 1, .empty_list_value);
    const d = try nest(&f, .cdr, unrecorded_steps - 1, .empty_list_value);
    limitAbove(&f, 0);
    try std.testing.expect(try callWith(&f, "equal?", c, d));
}

test "equal? starts to record exactly after unrecorded_steps descents" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    // ちょうど `unrecorded_steps` 回降りる比較は、表を確保しない。1回多いと確保する。
    const exact_a = try nest(&f, .cdr, unrecorded_steps, .empty_list_value);
    const exact_b = try nest(&f, .cdr, unrecorded_steps, .empty_list_value);
    const over_a = try nest(&f, .cdr, unrecorded_steps + 1, .empty_list_value);
    const over_b = try nest(&f, .cdr, unrecorded_steps + 1, .empty_list_value);
    limitAbove(&f, 0);
    try std.testing.expect(try callWith(&f, "equal?", exact_a, exact_b));
    try std.testing.expectError(error.HeapLimit, callWith(&f, "equal?", over_a, over_b));
}

test "equal? leaves the flags of the account as it found them" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    const a = try nest(&f, .cdr, 5000, .empty_list_value);
    const b = try nest(&f, .cdr, 5000, .empty_list_value);
    f.heap.external_enforced = true;
    f.heap.external_refused = true;
    try std.testing.expect(try callWith(&f, "equal?", a, b));
    try std.testing.expect(f.heap.external_enforced);
    try std.testing.expect(f.heap.external_refused);
    try std.testing.expectEqual(0, f.heap.external);
}

/// The kinds of nesting the tests below build.
const Nesting = enum {
    /// Each pair holds the next one in its car: `((((1))))`.
    car,
    /// Each pair holds the next one in its cdr: the list `(1 1 1 ...)`.
    cdr,
    /// Each vector holds the next one as its only element.
    vector,
    /// Each vector holds, besides the next one, an element to compare after it.
    vector_with_tail,
};

/// A structure `depth` levels deep, with `innermost` at the bottom.
fn nest(f: *test_support.Fixture, kind: Nesting, depth: usize, innermost: Value) !Value {
    var v = innermost;
    for (0..depth) |_| {
        v = switch (kind) {
            .car => try cons(f, v, .empty_list_value),
            .cdr => try cons(f, int(1), v),
            .vector => try vec(f, &.{v}),
            .vector_with_tail => try vec(f, &.{ v, int(1) }),
        };
    }
    return v;
}

/// Checks that two structures of `depth` levels are `equal?` when they have the
/// same bottom and not when they have different ones, and that nothing is left
/// in the scratch space.
fn expectDeepComparison(kind: Nesting, depth: usize) !void {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    // 一時領域が返されたかを調べるため、最後の確保しか返せない領域にする。
    const buffer = try std.testing.allocator.alloc(u8, 4 * depth * @sizeOf(Work) + 4096);
    defer std.testing.allocator.free(buffer);
    var fixed: std.heap.FixedBufferAllocator = .init(buffer);
    f.services.scratch = fixed.allocator();
    const a = try nest(&f, kind, depth, int(1));
    const b = try nest(&f, kind, depth, int(1));
    const c = try nest(&f, kind, depth, int(2));
    try std.testing.expect(try callWith(&f, "equal?", a, b));
    try std.testing.expectEqual(0, fixed.end_index);
    try std.testing.expect(!try callWith(&f, "equal?", a, c));
    try std.testing.expectEqual(0, fixed.end_index);
}

test "equal? compares structures thousands of levels deep, and returns what it took" {
    for ([_]Nesting{ .car, .cdr, .vector, .vector_with_tail }) |kind| {
        try expectDeepComparison(kind, 5000);
    }
}

test "equal? compares structures hundreds of thousands of levels deep without the Zig stack" {
    try tier.slow();
    for ([_]Nesting{ .car, .cdr, .vector, .vector_with_tail }) |kind| {
        try expectDeepComparison(kind, 300_000);
    }
}

test "equal? compares a long list without more than a few entries on its stack" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    // 一時領域は使えない。リストの長さに伴って積みが増えるなら、確保に失敗する。
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    f.services.scratch = failing.allocator();
    const a = try nest(&f, .cdr, 10_000, .empty_list_value);
    const b = try nest(&f, .cdr, 10_000, .empty_list_value);
    try std.testing.expect(try callWith(&f, "equal?", a, b));
    const zeros: [1000]Value = @splat(int(0));
    const x = try vec(&f, &zeros);
    const y = try vec(&f, &zeros);
    try std.testing.expect(try callWith(&f, "equal?", x, y));
    try std.testing.expect(!failing.has_induced_failure);
}

test "equal? uses the scratch space only when the nesting outgrows the small stack" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    f.services.scratch = failing.allocator();
    const shallow_a = try nest(&f, .car, 3, int(1));
    const shallow_b = try nest(&f, .car, 3, int(1));
    try std.testing.expect(try callWith(&f, "equal?", shallow_a, shallow_b));
    try std.testing.expect(!failing.has_induced_failure);
    const deep_a = try nest(&f, .car, 100, int(1));
    const deep_b = try nest(&f, .car, 100, int(1));
    try std.testing.expectError(error.OutOfMemory, callWith(&f, "equal?", deep_a, deep_b));
}

test "equal? returns the scratch space it took when the scratch space fails while it grows" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    // 最初の確保は通り、2回目の確保(拡張)が失敗する。testing.allocator が、最初の
    // 領域が返されたことを確かめる。
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 1 });
    f.services.scratch = failing.allocator();
    const a = try nest(&f, .car, 100, int(1));
    const b = try nest(&f, .car, 100, int(1));
    try std.testing.expectError(error.OutOfMemory, callWith(&f, "equal?", a, b));
}
