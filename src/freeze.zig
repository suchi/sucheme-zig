//! Marking the data of a literal as a constant (R7RS 3.4, 4.1.2).
//!
//! `quote` したデータと、自己評価するリテラルは定数であり、そこから到達できるペアと
//! ベクタと文字列のすべてが定数である。展開器が、リテラルを定数の節点にする地点で
//! `freezeGraph` を呼ぶ。docs/design/runtime.md の「リテラルの不変性」を参照。

const std = @import("std");
const value = @import("value.zig");
const Value = value.Value;
const heap = @import("heap.zig");

/// Marks every pair, string and vector that `root` reaches as a constant
/// (`heap.makeImmutable`), and does nothing to anything else.
///
/// グラフは循環と共有を含みうるので、訪問済みの集合を持つ。作業はデータの深さに依らず、
/// 明示的なスタックで進める(再帰しない)。すでに印のあるオブジェクトには降りない。
/// 印は、このグラフの全体を一度に立てるので、印のあるオブジェクトから到達できるものは、
/// すべて印がある(印のあるオブジェクトは書き換えられないので、あとから印のないものを
/// 指すこともない)。そのため、同じデータを何度リテラルにしても、1回分の仕事で済む。
///
/// Why: 見つける作業と印を立てる作業を分ける。作業領域を確保できず途中で失敗しても、
/// どのオブジェクトにも印を立てていない。途中まで立てると、次にそのデータを定数にするとき、
/// 「印があれば降りない」ために、印のない残りが取り残される。`allocator` が失敗するのは
/// 確保だけである。作業領域(スタックと訪問済みの集合)は、展開の作業領域として呼び出し側が
/// 上限に計上する。展開の途中では GC が走らない(ADR-0031)ので、見つけたオブジェクトを
/// ルートにする必要はない。
pub fn freezeGraph(allocator: std.mem.Allocator, root: Value) error{OutOfMemory}!void {
    var found: std.AutoArrayHashMapUnmanaged(usize, Value) = .empty;
    defer found.deinit(allocator);
    var stack: std.ArrayList(Value) = .empty;
    defer stack.deinit(allocator);
    try stack.append(allocator, root);
    while (stack.pop()) |x| {
        const address: usize = switch (x.kind()) {
            .pair => @intFromPtr(x.asPair().?),
            .vector => @intFromPtr(x.asVector().?),
            .string => @intFromPtr(x.asString().?),
            else => continue,
        };
        if (heap.isImmutable(x)) continue;
        const entry = try found.getOrPut(allocator, address);
        if (entry.found_existing) continue;
        entry.value_ptr.* = x;
        switch (x.kind()) {
            .pair => {
                const p = x.asPair().?;
                try stack.append(allocator, p.cdr);
                try stack.append(allocator, p.car);
            },
            .vector => try stack.appendSlice(allocator, x.asVector().?.items),
            else => {},
        }
    }
    for (found.values()) |v| heap.makeImmutable(v);
}

test {
    std.testing.refAllDecls(@This());
}

const test_support = @import("prim/test_support.zig");

fn fix(n: i64) Value {
    return .fromFixnum(n);
}

test "a literal list is a constant in every pair, and so is a string and a vector inside it" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    const string: Value = .fromString(try f.heap.createString("abc"));
    const vector: Value = .fromVector(try f.heap.createVector(&.{ fix(1), string }));
    const tail = try f.heap.cons(vector, .empty_list_value);
    const list = try f.heap.cons(fix(1), tail);
    try freezeGraph(std.testing.allocator, list);
    for ([_]Value{ list, tail, vector, string }) |v| try std.testing.expect(heap.isImmutable(v));
}

test "what a literal does not reach is left alone" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    const inside = try f.heap.cons(fix(1), .empty_list_value);
    const outside = try f.heap.cons(fix(2), .empty_list_value);
    const holder = try f.heap.cons(inside, .empty_list_value);
    // `outside` が `inside` を指しても、`inside` から `outside` へは行けない。
    _ = try f.heap.cons(outside, inside);
    try freezeGraph(std.testing.allocator, holder);
    try std.testing.expect(heap.isImmutable(holder));
    try std.testing.expect(heap.isImmutable(inside));
    try std.testing.expect(!heap.isImmutable(outside));
}

test "the roots that are not pairs, strings or vectors have nothing to mark" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    for ([_]Value{ fix(1), .fromBool(false), .empty_list_value, .fromCharacter('a'), .unspecified_value }) |v| {
        try freezeGraph(std.testing.allocator, v);
        try std.testing.expect(!heap.isImmutable(v));
    }
}

test "a literal that loops back on itself is marked once and the marking stops" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    const a = try f.heap.cons(fix(1), .empty_list_value);
    const b = try f.heap.cons(fix(2), a);
    a.asPair().?.cdr = b;
    const vector: Value = .fromVector(try f.heap.createVector(&.{ fix(0), .empty_list_value }));
    vector.asVector().?.items[1] = vector;
    const holder = try f.heap.cons(vector, b);
    try freezeGraph(std.testing.allocator, holder);
    for ([_]Value{ a, b, vector, holder }) |v| try std.testing.expect(heap.isImmutable(v));
}

test "a pair shared by two places is marked, and marking the data again changes nothing" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    const shared = try f.heap.cons(fix(1), .empty_list_value);
    const list = try f.heap.cons(shared, try f.heap.cons(shared, .empty_list_value));
    try freezeGraph(std.testing.allocator, list);
    try std.testing.expect(heap.isImmutable(shared));
    // 印のあるオブジェクトには降りない。印のあるデータを含む新しいデータも、新しい部分だけが
    // 印を受ける。
    const fresh = try f.heap.cons(fix(2), .empty_list_value);
    const wrapper = try f.heap.cons(list, fresh);
    try freezeGraph(std.testing.allocator, wrapper);
    try std.testing.expect(heap.isImmutable(wrapper));
    try std.testing.expect(heap.isImmutable(fresh));
    try freezeGraph(std.testing.allocator, wrapper);
}

test "the marking of deep data and of long data does not use the stack of the program" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    // car の側に深い入れ子と、cdr の側に長いリスト。再帰なら、数十万段でスタックが溢れる。
    var deep: Value = .empty_list_value;
    for (0..200_000) |_| deep = try f.heap.cons(deep, .empty_list_value);
    var long: Value = .empty_list_value;
    for (0..200_000) |_| long = try f.heap.cons(fix(1), long);
    try freezeGraph(std.testing.allocator, deep);
    try freezeGraph(std.testing.allocator, long);
    try std.testing.expect(heap.isImmutable(deep));
    try std.testing.expect(heap.isImmutable(long));
    try std.testing.expect(heap.isImmutable(long.asPair().?.cdr.asPair().?.cdr));
}

test "when the work area cannot be had, nothing is marked, and the next marking marks all of it" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    const string: Value = .fromString(try f.heap.createString("abc"));
    const inner = try f.heap.cons(string, .empty_list_value);
    const list = try f.heap.cons(fix(1), try f.heap.cons(inner, .empty_list_value));
    // 確保の失敗を、1回目から順に起こす。失敗した呼び出しは、どれにも印を立てない。
    var failed: usize = 0;
    var fail_index: usize = 0;
    while (true) : (fail_index += 1) {
        var failing: std.testing.FailingAllocator = .init(std.testing.allocator, .{ .fail_index = fail_index });
        freezeGraph(failing.allocator(), list) catch |e| {
            try std.testing.expectEqual(error.OutOfMemory, e);
            failed += 1;
            for ([_]Value{ list, inner, string }) |v| try std.testing.expect(!heap.isImmutable(v));
            continue;
        };
        break;
    }
    try std.testing.expect(failed > 0);
    for ([_]Value{ list, inner, string }) |v| try std.testing.expect(heap.isImmutable(v));
}
