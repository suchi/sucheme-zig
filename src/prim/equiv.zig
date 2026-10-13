//! Equivalence predicates (R7RS 6.1): `eq?`, `eqv?` and `equal?`.
//!
//! `eq?` と `eqv?` の実体は `Value` の関数である(値の表現を隠す、ADR-0002)。`equal?`
//! は構造を比べるのでここに置く。

const std = @import("std");
const value = @import("../value.zig");
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
    return .fromBool(try isEqual(services.scratch, args[0], args[1]));
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

/// Whether `a` and `b` are `equal?`: pairs and vectors compared by their parts,
/// strings by their characters, everything else by `eqv?` (R7RS 6.1).
///
/// Zig の再帰を使わず、`Stack` に未比較の組を積んで進める。ペアは car を先に降り、
/// cdr を積む。長いリストは cdr を積んでは取り出すので、積みは深くならない。ベクタは、
/// 次の要素の位置を積む。データの変更が無いので循環は作れず、止まらなくなることはない。
/// 訪問済みの集合は持たない。そのため、同じ部分を何度も指すデータ(共有構造)では、
/// 比較の回数が深さに対して指数に増える。循環の停止と合わせて、データの変更が入る
/// 段階3の最初のスライスで入れる(docs/plans/0010-slices-1k-1l-primitives-and-repl-continuation.md)。
///
/// 同じペアやベクタの比較は、中を見ずに真とする。`eqv?` が真なら `equal?` も真だからである。
fn isEqual(scratch: std.mem.Allocator, a: Value, b: Value) error{OutOfMemory}!bool {
    var stack: Stack = .{ .scratch = scratch };
    defer stack.deinit();
    var left = a;
    var right = b;
    while (true) {
        switch (left.kind()) {
            .pair => {
                const x = left.asPair().?;
                const y = right.asPair() orelse return false;
                if (x != y) {
                    try stack.push(.{ .values = .{ .a = x.cdr, .b = y.cdr } });
                    left = x.car;
                    right = y.car;
                    continue;
                }
            },
            .vector => {
                const x = left.asVector().?;
                const y = right.asVector() orelse return false;
                if (x.items.len != y.items.len) return false;
                if (x != y and x.items.len > 0) {
                    if (x.items.len > 1) try stack.push(.{ .elements = .{ .a = x.items, .b = y.items, .next = 1 } });
                    left = x.items[0];
                    right = y.items[0];
                    continue;
                }
            },
            .string => {
                const y = right.asString() orelse return false;
                if (!std.mem.eql(u8, left.asString().?.bytes, y.bytes)) return false;
            },
            // Why: `else` にしない。`Kind` に種別を足したとき、ここがコンパイルエラーになって、
            // `equal?` が中身を比べるべき種別(バイトベクタなど)を見落とさないようにする。
            .fixnum, .boolean, .empty_list, .symbol, .primitive, .closure, .unspecified, .uninitialized, .condition, .character, .record, .record_type => {
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
