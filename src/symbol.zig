//! The symbol table: each distinct name is interned once and named by a
//! `SymbolId`, so comparing two symbols is comparing two integers.
//!
//! 弱い表である(docs/design/runtime.md の「インターン表を弱い表にする」)。GC のマークが
//! 出会った ID に印を立て(`mark`)、スイープが印の無い ID の名前を解放して ID を再利用
//! 可能にする(`sweep`)。起動時に Zig が登録する名前は固定し、回収しない(`internFixed`)。
//! 表はルートではない。ID を保持するものは、保持している間、GC に ID を知らせなければ
//! ならない。知らせないと、ID は別の名前に再利用され、保持していたものが別のシンボルを
//! 指す。

const std = @import("std");

/// A symbol, by its index in the table that interned it.
///
/// 32 ビットである。生きている名前はすべて表に場所を取り、ヒープの上限が計上するので、
/// 2^32 個の異なる名前に達するよりずっと前に上限に当たる。
pub const SymbolId = enum(u32) { _ };

/// The bytes the account holds for a symbol whose name is `name_len` long: the
/// name, and the entry of the table and the slot of the index that go with it.
/// Why: 表と索引の記憶域が伸びるときの余りは、数えない。数えるのは、名前の長さに比例する
/// 部分と、1つの名前ごとの定数の部分である。入力が名前を増やす速さは、この定数で上限に
/// 結びつく。
pub fn charge(name_len: usize) error{Overflow}!usize {
    const per_symbol = @sizeOf(Table.Entry) + @sizeOf([]const u8) + @sizeOf(SymbolId) + 1;
    return std.math.add(usize, name_len, per_symbol);
}

pub const Table = struct {
    /// The state of each id.
    entries: std.ArrayList(Entry) = .empty,
    index: std.StringHashMapUnmanaged(SymbolId) = .empty,
    /// The first of the ids that no name has, each leading to the next.
    /// Why: スイープは確保しない。空きの鎖を表の項目の中に持つので、スイープは失敗しない。
    free_head: u32 = no_link,
    /// The bytes held for the symbols that a collection may reclaim (`charge`).
    /// ヒープが、上限と GC の起動に使う。
    charged: usize = 0,

    const no_link = std.math.maxInt(u32);

    pub const Entry = struct {
        /// The name, while `live`. The table owns it.
        name: []u8 = &.{},
        /// The next id without a name, while not `live`; `no_link` at the end.
        next_free: u32 = no_link,
        live: bool = false,
        /// Set by the marking of a collection, and cleared before the next.
        referenced: bool = false,
        /// Never reclaimed.
        fixed: bool = false,
    };

    /// The id for `name`, interning it first if it is new.
    ///
    /// テーブルは `name` の自前のコピーを持つので、呼び出し側のバッファはなくなってもよい。
    /// 失敗したときは、表も計上も呼ぶ前のままである。`alloc` は、同じ表に対して常に同じ
    /// ものを渡す。
    pub fn intern(self: *Table, alloc: std.mem.Allocator, name: []const u8) error{OutOfMemory}!SymbolId {
        if (self.index.get(name)) |id| return id;
        const owned = try alloc.dupe(u8, name);
        errdefer alloc.free(owned);
        const bytes = charge(name.len) catch return error.OutOfMemory;
        const reuse = self.free_head != no_link;
        // 新しい ID を作る確保は、索引に載せる前に済ませる。載せたあとに失敗すると、戻す
        // 手間が要る。
        if (!reuse) {
            if (self.entries.items.len >= no_link) return error.OutOfMemory;
            try self.entries.ensureUnusedCapacity(alloc, 1);
        }
        const id: SymbolId = if (reuse) @fromBackingInt(self.free_head) else @fromBackingInt(@intCast(self.entries.items.len));
        // キーはテーブル自前のコピーであり、テーブルが育っても有効なままである。
        try self.index.put(alloc, owned, id);
        if (reuse) {
            const entry = &self.entries.items[@backingInt(id)];
            self.free_head = entry.next_free;
            entry.* = .{ .name = owned, .live = true };
        } else {
            self.entries.appendAssumeCapacity(.{ .name = owned, .live = true });
        }
        self.charged += bytes;
        return id;
    }

    /// The id for `name`, which no collection reclaims, interning it first if
    /// it is new.
    /// 固定した名前は `charged` に入らない。起動時に、Zig のコードが定数として ID を持つ名前
    /// のためにある。
    pub fn internFixed(self: *Table, alloc: std.mem.Allocator, name: []const u8) error{OutOfMemory}!SymbolId {
        const id = try self.intern(alloc, name);
        const entry = &self.entries.items[@backingInt(id)];
        if (!entry.fixed) {
            entry.fixed = true;
            self.charged -= charge(entry.name.len) catch unreachable;
        }
        return id;
    }

    /// The name of `id`, which must have one.
    /// 返す記憶域は、その ID がスイープに回収されるまで有効である。
    pub fn nameOf(self: *const Table, id: SymbolId) []const u8 {
        const entry = &self.entries.items[@backingInt(id)];
        std.debug.assert(entry.live);
        return entry.name;
    }

    /// The id of `name` if it has been interned, without interning it.
    pub fn lookup(self: *const Table, name: []const u8) ?SymbolId {
        return self.index.get(name);
    }

    /// Clears the marks, before the marking of a collection.
    pub fn clearMarks(self: *Table) void {
        for (self.entries.items) |*entry| entry.referenced = false;
    }

    /// Notes that `id` is reachable.
    /// 発行されていない ID は、無視する。テストが、表に無い ID を値に入れる。
    pub fn mark(self: *Table, id: SymbolId) void {
        const i = @backingInt(id);
        if (i < self.entries.items.len) self.entries.items[i].referenced = true;
    }

    /// Reclaims every name that is neither marked nor fixed: takes it out of the
    /// index, then frees its bytes, then lets its id be used again.
    /// Why: 索引からの削除は、キーの内容を読んでハッシュを求めるので、名前の解放より先に行う。
    /// 順序を逆にすると、削除が解放済みの記憶域を読む。
    pub fn sweep(self: *Table, alloc: std.mem.Allocator) void {
        for (self.entries.items, 0..) |*entry, i| {
            if (!entry.live or entry.referenced or entry.fixed) continue;
            const removed = self.index.remove(entry.name);
            std.debug.assert(removed);
            self.charged -= charge(entry.name.len) catch unreachable;
            alloc.free(entry.name);
            entry.* = .{ .next_free = self.free_head };
            self.free_head = @intCast(i);
        }
    }

    /// Gives back every name and the table's own storage; `alloc` is the one
    /// `intern` took.
    pub fn deinit(self: *Table, alloc: std.mem.Allocator) void {
        for (self.entries.items) |entry| {
            if (entry.live) alloc.free(entry.name);
        }
        self.entries.deinit(alloc);
        self.index.deinit(alloc);
        self.* = .{};
    }
};

test {
    std.testing.refAllDecls(@This());
}

test "intern gives one id to one name and different ids to different names" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var t: Table = .{};
    const x = try t.intern(a, "x");
    const y = try t.intern(a, "y");
    try std.testing.expect(x != y);
    try std.testing.expectEqual(x, try t.intern(a, "x"));
    try std.testing.expectEqual(y, try t.intern(a, "y"));
    // 大文字小文字だけが違う名前や、接頭辞だけが違う名前は、別の名前である。

    try std.testing.expect(x != try t.intern(a, "X"));
    try std.testing.expect(x != try t.intern(a, "xx"));
}

test "name reads back what was interned" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var t: Table = .{};
    const id = try t.intern(arena.allocator(), "list->vector");
    try std.testing.expectEqualStrings("list->vector", t.nameOf(id));
}

test "the table keeps its own copy of a name" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var t: Table = .{};
    var buf = "abc".*;
    const id = try t.intern(a, &buf);
    buf[0] = 'z';
    try std.testing.expectEqualStrings("abc", t.nameOf(id));
    try std.testing.expectEqual(id, try t.intern(a, "abc"));
}

test "ids stay valid as the table grows" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var t: Table = .{};
    var ids: [200]SymbolId = undefined;
    var buf: [8]u8 = undefined;
    for (&ids, 0..) |*id, i| id.* = try t.intern(a, std.fmt.bufPrint(&buf, "s{d}", .{i}) catch unreachable);
    for (ids, 0..) |id, i| {
        try std.testing.expectEqualStrings(std.fmt.bufPrint(&buf, "s{d}", .{i}) catch unreachable, t.nameOf(id));
        try std.testing.expectEqual(id, try t.intern(a, t.nameOf(id)));
    }
}

/// 名前を番号付きで作る。`buf` は呼び出し側が持つ。
fn numbered(buf: []u8, i: usize) []const u8 {
    return std.fmt.bufPrint(buf, "name-{d}", .{i}) catch unreachable;
}

test "a sweep reclaims the names nothing marked, and keeps the marked and the fixed" {
    const gpa = std.testing.allocator;
    var t: Table = .{};
    defer t.deinit(gpa);
    const fixed = try t.internFixed(gpa, "fixed");
    const kept = try t.intern(gpa, "kept");
    const dropped = try t.intern(gpa, "dropped");
    const baseline = t.charged;
    try std.testing.expectEqual(try charge(4) + try charge(7), baseline);
    t.clearMarks();
    t.mark(kept);
    t.sweep(gpa);
    try std.testing.expectEqualStrings("fixed", t.nameOf(fixed));
    try std.testing.expectEqualStrings("kept", t.nameOf(kept));
    try std.testing.expectEqual(kept, t.lookup("kept").?);
    try std.testing.expectEqual(fixed, t.lookup("fixed").?);
    try std.testing.expect(t.lookup("dropped") == null);
    try std.testing.expectEqual(try charge(4), t.charged);
    // 回収した ID は、次の新しい名前が使う。別の名前を返した ID を、前の名前の保持者が
    // 持ち続けると、その名前に化ける。
    const reused = try t.intern(gpa, "another");
    try std.testing.expectEqual(dropped, reused);
    try std.testing.expectEqualStrings("another", t.nameOf(reused));
    try std.testing.expect(t.lookup("dropped") == null);
}

test "the marks of one collection do not carry into the next" {
    const gpa = std.testing.allocator;
    var t: Table = .{};
    defer t.deinit(gpa);
    const id = try t.intern(gpa, "once");
    t.clearMarks();
    t.mark(id);
    t.sweep(gpa);
    try std.testing.expect(t.lookup("once") != null);
    // 次の回では、印を消してから始めるので、印の無い名前は回収される。
    t.clearMarks();
    t.sweep(gpa);
    try std.testing.expect(t.lookup("once") == null);
    try std.testing.expectEqual(0, t.charged);
}

test "a sweep gives back every id it frees, each once, and the ids come back in use" {
    const gpa = std.testing.allocator;
    var t: Table = .{};
    defer t.deinit(gpa);
    var buf: [16]u8 = undefined;
    var ids: [40]SymbolId = undefined;
    for (&ids, 0..) |*id, i| id.* = try t.intern(gpa, numbered(&buf, i));
    // 奇数番だけ残す。
    t.clearMarks();
    for (ids, 0..) |id, i| if (i % 2 == 1) t.mark(id);
    t.sweep(gpa);
    for (ids, 0..) |id, i| {
        if (i % 2 == 1) try std.testing.expectEqualStrings(numbered(&buf, i), t.nameOf(id));
        try std.testing.expectEqual(i % 2 == 1, t.lookup(numbered(&buf, i)) != null);
    }
    // 空いた20個の ID だけが再利用され、表は伸びない。
    const length = t.entries.items.len;
    var seen = std.AutoHashMap(SymbolId, void).init(gpa);
    defer seen.deinit();
    for (0..20) |i| {
        const id = try t.intern(gpa, std.fmt.bufPrint(&buf, "new-{d}", .{i}) catch unreachable);
        try std.testing.expect(@backingInt(id) < length);
        try std.testing.expect(!(try seen.getOrPut(id)).found_existing);
        try std.testing.expect(@backingInt(id) % 2 == 0);
    }
    try std.testing.expectEqual(length, t.entries.items.len);
    // 21個目は、新しい ID である。
    try std.testing.expectEqual(length, @backingInt(try t.intern(gpa, "extra")));
}

test "marking an id the table never issued is ignored" {
    var t: Table = .{};
    t.mark(@fromBackingInt(@intCast(5)));
}

test "a fixed name is not counted, and one that was counted stops being counted when it is fixed" {
    const gpa = std.testing.allocator;
    var t: Table = .{};
    defer t.deinit(gpa);
    _ = try t.internFixed(gpa, "quote");
    try std.testing.expectEqual(0, t.charged);
    const id = try t.intern(gpa, "later");
    try std.testing.expectEqual(try charge(5), t.charged);
    try std.testing.expectEqual(id, try t.internFixed(gpa, "later"));
    try std.testing.expectEqual(0, t.charged);
    t.clearMarks();
    t.sweep(gpa);
    try std.testing.expectEqualStrings("later", t.nameOf(id));
}

test "an intern that fails leaves the table, the account and the memory as they were" {
    const check = struct {
        fn run(gpa: std.mem.Allocator) !void {
            var t: Table = .{};
            defer t.deinit(gpa);
            const keep = try t.intern(gpa, "keep");
            // 空きの ID を再利用する経路と、新しい ID を作る経路の、両方を通す。
            const drop = try t.intern(gpa, "drop");
            t.clearMarks();
            t.mark(keep);
            t.sweep(gpa);
            const before = t.charged;
            const length = t.entries.items.len;
            const result = t.intern(gpa, "fresh");
            if (result) |id| {
                try std.testing.expectEqual(drop, id);
                const second = t.intern(gpa, "second") catch |e| {
                    try std.testing.expectEqual(error.OutOfMemory, e);
                    try std.testing.expect(t.lookup("second") == null);
                    try std.testing.expectEqual(before + try charge(5), t.charged);
                    try std.testing.expectEqual(length, t.entries.items.len);
                    return error.OutOfMemory;
                };
                try std.testing.expectEqualStrings("second", t.nameOf(second));
            } else |e| {
                try std.testing.expectEqual(error.OutOfMemory, e);
                try std.testing.expect(t.lookup("fresh") == null);
                try std.testing.expectEqual(before, t.charged);
                try std.testing.expectEqual(length, t.entries.items.len);
                try std.testing.expectEqualStrings("keep", t.nameOf(keep));
                // 失敗のあとも、空いた ID は空いたまま使える。
                return error.OutOfMemory;
            }
        }
    }.run;
    try std.testing.checkAllAllocationFailures(std.testing.allocator, check, .{});
}
