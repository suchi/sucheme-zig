//! The symbol table: each distinct name is interned once and named by a
//! `SymbolId`, so comparing two symbols is comparing two integers.
//!
//! リーダは読んだシンボルをすべてインターンする。そのため、参照されるだけの名前
//! もテーブルに場所を取る。テーブルはインタプリタと同じ寿命で、スライス1g の GC
//! でも回収されない。docs/design/runtime.md の弱テーブルが、後のスライスでこれを
//! 置き換える。

const std = @import("std");

/// A symbol, by its index in the table that interned it.
///
/// 32 ビットである。テーブルはインターンした名前をすべて保持するので、2^32 個の
/// 異なる名前に達するよりずっと前にメモリを使い果たす。
pub const SymbolId = enum(u32) { _ };

pub const Table = struct {
    /// The name of each symbol, by id.
    ///
    /// スライスはテーブルが所有する。
    names: std.ArrayList([]const u8) = .empty,
    index: std.StringHashMapUnmanaged(SymbolId) = .empty,

    /// The id for `name`, interning it first if it is new.
    ///
    /// テーブルは `name` の自前のコピーを持つので、呼び出し側のバッファは
    /// なくなってもよい。
    pub fn intern(self: *Table, alloc: std.mem.Allocator, name: []const u8) error{OutOfMemory}!SymbolId {
        if (self.index.get(name)) |id| return id;
        const owned = try alloc.dupe(u8, name);
        errdefer alloc.free(owned);
        const id: SymbolId = @fromBackingInt(@intCast(self.names.items.len));
        try self.names.append(alloc, owned);
        errdefer _ = self.names.pop();
        // キーはテーブル自前のコピーであり、テーブルが育っても有効なままである。
        try self.index.put(alloc, owned, id);
        return id;
    }

    pub fn nameOf(self: *const Table, id: SymbolId) []const u8 {
        return self.names.items[@backingInt(id)];
    }

    /// The id of `name` if it has been interned, without interning it.
    pub fn lookup(self: *const Table, name: []const u8) ?SymbolId {
        return self.index.get(name);
    }

    /// Gives back every name and the table's own storage; `alloc` is the one
    /// `intern` took.
    pub fn deinit(self: *Table, alloc: std.mem.Allocator) void {
        for (self.names.items) |name| alloc.free(name);
        self.names.deinit(alloc);
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
