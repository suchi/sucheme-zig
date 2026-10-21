//! Where the pairs the reader read from a file came from, for the messages of errors.
//!
//! 位置は、ファイルと行と桁の3つである(docs/design/frontend.md の「位置情報」)。表は、
//! 1つのトップレベルフォームを読んでから展開し終えるまでの作業表で、その間は鍵のペアを
//! GC のルートにする(`mark`)。鍵はペアの番地なので、ルートにしないと、回収されたペアの
//! 番地が新しいペアに使い回され、無関係な位置を指す。

const std = @import("std");
const value_mod = @import("value.zig");
const Value = value_mod.Value;
const Pair = value_mod.Pair;
const heap_mod = @import("heap.zig");

/// A place in a file: a line and a column, both counted from 1.
/// 桁は文字(コードポイント)で数える。行の終わりは LF、CR LF、CR のどれでもよい
/// (R7RS 7.1.1 の <line ending>)。
pub const Location = struct {
    line: u32 = 1,
    column: u32 = 1,
};

/// Where a pair was read: the file, and the place of its first character in it.
pub const Position = struct {
    /// The place of the file's name in `Table.files`.
    file: u32,
    location: Location,
};

/// The positions of the pairs read for one top-level form.
pub const Table = struct {
    gpa: std.mem.Allocator,
    /// The names of the files the pairs were read from, as the messages show them.
    files: std.ArrayList([]const u8) = .empty,
    by_pair: std.AutoHashMapUnmanaged(*const Pair, Position) = .empty,

    pub fn init(gpa: std.mem.Allocator) Table {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Table) void {
        for (self.files.items) |name| self.gpa.free(name);
        self.files.deinit(self.gpa);
        self.by_pair.deinit(self.gpa);
    }

    /// The number of the file named `name`, for `Position.file`.
    /// 名前は写して持つ。同じ名前のファイルを2回読めば、2つの番号になる。
    pub fn addFile(self: *Table, name: []const u8) error{OutOfMemory}!u32 {
        const number = std.math.cast(u32, self.files.items.len) orelse return error.OutOfMemory;
        const copy = try self.gpa.dupe(u8, name);
        errdefer self.gpa.free(copy);
        try self.files.append(self.gpa, copy);
        return number;
    }

    /// Keeps that `pair` was read at `position`.
    pub fn record(self: *Table, pair: *const Pair, position: Position) error{OutOfMemory}!void {
        try self.by_pair.put(self.gpa, pair, position);
    }

    /// Where `form` was read, or null when it is not a pair the reader read.
    pub fn of(self: *const Table, form: Value) ?Position {
        const pair = form.asPair() orelse return null;
        return self.by_pair.get(pair);
    }

    /// The name of the file `file` numbers.
    pub fn fileName(self: *const Table, file: u32) []const u8 {
        return self.files.items[file];
    }

    /// Tells the collector that the pairs of the table are live.
    pub fn mark(self: *const Table, marker: *heap_mod.Marker) void {
        var keys = self.by_pair.keyIterator();
        while (keys.next()) |pair| marker.value(.{ .pair = @constCast(pair.*) });
    }
};

/// Counts lines and columns through a text, from its start towards its end.
/// 読み手は位置を先頭から順に問うので、全体で1回だけ辿る。
pub const Cursor = struct {
    offset: usize = 0,
    location: Location = .{},

    /// The place of the byte at `offset` in `text`, which is no earlier than
    /// the offset asked before.
    pub fn locate(self: *Cursor, text: []const u8, offset: usize) Location {
        std.debug.assert(offset >= self.offset and offset <= text.len);
        while (self.offset < offset) : (self.offset += 1) {
            const c = text[self.offset];
            switch (c) {
                '\n' => self.newLine(),
                // CR LF は1つの行の終わりで、LF の側で数える。
                '\r' => if (self.offset + 1 < text.len and text[self.offset + 1] == '\n') {} else self.newLine(),
                else => {
                    // 文字の2バイト目以降(10xxxxxx)は、桁を進めない。
                    if (c & 0xC0 != 0x80) self.location.column +|= 1;
                },
            }
        }
        return self.location;
    }

    fn newLine(self: *Cursor) void {
        self.location.line +|= 1;
        self.location.column = 1;
    }
};

test "locate counts lines with each line ending, and columns in characters" {
    const text = "ab\ncd\r\nef\rg\u{3042}h";
    var c: Cursor = .{};
    try std.testing.expectEqual(Location{ .line = 1, .column = 1 }, c.locate(text, 0));
    try std.testing.expectEqual(Location{ .line = 1, .column = 2 }, c.locate(text, 1));
    try std.testing.expectEqual(Location{ .line = 2, .column = 1 }, c.locate(text, 3));
    // CR LF の LF の位置はまだ2行目で、その次が3行目である。
    try std.testing.expectEqual(Location{ .line = 2, .column = 3 }, c.locate(text, 5));
    try std.testing.expectEqual(Location{ .line = 3, .column = 1 }, c.locate(text, 7));
    try std.testing.expectEqual(Location{ .line = 4, .column = 1 }, c.locate(text, 10));
    // `あ` は3バイトで1文字である。
    try std.testing.expectEqual(Location{ .line = 4, .column = 3 }, c.locate(text, 14));
}

test "a table keeps the position of each pair and the names of the files" {
    var heap: heap_mod.Heap = .init(std.testing.allocator, .{});
    defer heap.deinit();
    var t: Table = .init(std.testing.allocator);
    defer t.deinit();
    const a = try t.addFile("a.scm");
    const b = try t.addFile("b.scm");
    const p = try heap.cons(.fromFixnum(1), Value.empty_list_value);
    const q = try heap.cons(.fromFixnum(2), Value.empty_list_value);
    try t.record(p.asPair().?, .{ .file = b, .location = .{ .line = 3, .column = 4 } });
    try std.testing.expectEqual(Position{ .file = b, .location = .{ .line = 3, .column = 4 } }, t.of(p).?);
    try std.testing.expectEqualStrings("b.scm", t.fileName(t.of(p).?.file));
    try std.testing.expectEqualStrings("a.scm", t.fileName(a));
    try std.testing.expect(t.of(q) == null);
    try std.testing.expect(t.of(.fromFixnum(1)) == null);
}

test "the pairs of a table survive a collection that the table is a root of" {
    var heap: heap_mod.Heap = .init(std.testing.allocator, .{});
    defer heap.deinit();
    var t: Table = .init(std.testing.allocator);
    defer t.deinit();
    const file = try t.addFile("a.scm");
    const kept = try heap.cons(.fromFixnum(1), Value.empty_list_value);
    _ = try heap.cons(.fromFixnum(2), Value.empty_list_value);
    try t.record(kept.asPair().?, .{ .file = file, .location = .{} });
    heap.collect(TableRoots{ .table = &t });
    try std.testing.expectEqual(1, heap.count);
    try std.testing.expectEqual(1, kept.asPair().?.car.asFixnum().?);
}

const TableRoots = struct {
    table: *const Table,

    pub fn mark(self: TableRoots, marker: *heap_mod.Marker) void {
        self.table.mark(marker);
    }
};
