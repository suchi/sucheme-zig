//! The symbol table: each distinct name is interned once and named by a
//! `SymbolId`, so comparing two symbols is comparing two integers.
//!
//! The reader interns every symbol it reads, so a name that is only ever
//! referred to still takes a place in the table. The table lives as long as the
//! interpreter and is never collected, not even by the GC of slice 1g; the weak
//! table of docs/design/runtime.md replaces it in a later slice.

const std = @import("std");

/// A symbol, by its index in the table that interned it.
///
/// 32 bits: the table holds every name it interned, so it would exhaust memory
/// long before 2^32 distinct names.
pub const SymbolId = enum(u32) { _ };

pub const Table = struct {
    /// The name of each symbol, by id. The slices are owned by the table.
    names: std.ArrayList([]const u8) = .empty,
    index: std.StringHashMapUnmanaged(SymbolId) = .empty,

    /// The id for `name`, interning it first if it is new. The table keeps its
    /// own copy of `name`, so the caller's buffer can go away.
    pub fn intern(self: *Table, alloc: std.mem.Allocator, name: []const u8) error{OutOfMemory}!SymbolId {
        if (self.index.get(name)) |id| return id;
        const owned = try alloc.dupe(u8, name);
        const id: SymbolId = @fromBackingInt(@intCast(self.names.items.len));
        try self.names.append(alloc, owned);
        // The key is the table's own copy, which stays valid as the table grows.
        try self.index.put(alloc, owned, id);
        return id;
    }

    pub fn nameOf(self: *const Table, id: SymbolId) []const u8 {
        return self.names.items[@backingInt(id)];
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
    // Names differing in case or by a prefix are different names.
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
