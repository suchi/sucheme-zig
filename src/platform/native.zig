//! The host's means that differ between the executable and WebAssembly: here, the
//! table of the files the file ports have open (docs/plans/0019-phase5-ports-and-io.md).
//!
//! 表は、ファイルを開けるホスト(ネイティブ)だけが持つ。WASM は実ファイルシステムを持たない
//! ので表を作らず、`Heap.files` が null のままである。このとき、ファイルを開く手続きと
//! `delete-file` は `file-error` を送出し、`file-exists?` は `#f` を返す(docs/design/frontend.md
//! の第2類)。差がこの有無だけなので、WASM の側のファイルは作らない。
//!
//! 表の欄は、ファイルポートが開いている間だけ埋まる。ポートは欄の番号を持ち(`Port.File.id`)、
//! 閉じると欄が空き、次に開くファイルが使う。

const std = @import("std");
const heap_mod = @import("../heap.zig");
const Heap = heap_mod.Heap;
const Port = @import("../value.zig").Port;
const resolve = @import("../resolve.zig");
const File = std.Io.File;

/// The files the file ports have open, each in a slot that its port names.
/// Why: 欄の配列は、ヒープの計上の外(`gpa`)に置く。欄の数は、開いているファイルポートの数を
/// 超えず、ポートはそれぞれバッファを計上しているので、欄の分はその小さな付け足しである。
/// 計上つきの確保にすると、上限に当たったヒープの回収(`free` が閉じる)の途中で、表を縮める
/// 確保が断られる経路を考える必要が出る。
pub const FileTable = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    slots: std.ArrayList(?File) = .empty,

    pub fn init(io: std.Io, gpa: std.mem.Allocator) FileTable {
        return .{ .io = io, .gpa = gpa };
    }

    /// Closes the files that are still open, and frees the table.
    /// 開いたままのファイルは、ふつうは残らない。ヒープの `deinit` が、開いたポートを書き出して
    /// 閉じるからである。そのため、ヒープより後に呼ぶ。
    pub fn deinit(self: *FileTable) void {
        for (self.slots.items) |slot| if (slot) |file| file.close(self.io);
        self.slots.deinit(self.gpa);
    }

    /// The means the heap and the file procedures reach the table with.
    pub fn host(self: *FileTable) Heap.FileHost {
        return .{ .context = self, .open = open, .delete = delete, .exists = exists, .read = read, .write = write, .close = close };
    }

    fn of(context: *anyopaque) *FileTable {
        return @ptrCast(@alignCast(context));
    }

    fn open(context: *anyopaque, path: []const u8, direction: Port.Direction) error{ Exhausted, Refused, OutOfMemory }!u32 {
        const self = of(context);
        const id = try self.freeSlot();
        self.slots.items[id] = try resolve.openUserFile(self.io, path, direction);
        return id;
    }

    /// The first empty slot, made when there is none.
    /// 欄を先に用意してから開く。開いたあとで欄の確保に失敗すると、開いたファイルを閉じる
    /// 手当てが要るからである。
    fn freeSlot(self: *FileTable) error{OutOfMemory}!u32 {
        for (self.slots.items, 0..) |slot, i| if (slot == null) return @intCast(i);
        if (self.slots.items.len == std.math.maxInt(u32)) return error.OutOfMemory;
        try self.slots.append(self.gpa, null);
        return @intCast(self.slots.items.len - 1);
    }

    fn delete(context: *anyopaque, path: []const u8) error{Refused}!void {
        return resolve.deleteUserFile(of(context).io, path);
    }

    fn exists(context: *anyopaque, path: []const u8) bool {
        return resolve.userFileExists(of(context).io, path);
    }

    fn read(context: *anyopaque, id: u32, buffer: []u8) error{Io}!usize {
        const self = of(context);
        const file = self.slots.items[id].?;
        return file.readStreaming(self.io, &.{buffer}) catch |e| switch (e) {
            error.EndOfStream => 0,
            else => error.Io,
        };
    }

    fn write(context: *anyopaque, id: u32, bytes: []const u8) error{Io}!void {
        const self = of(context);
        const file = self.slots.items[id].?;
        file.writeStreamingAll(self.io, bytes) catch return error.Io;
    }

    fn close(context: *anyopaque, id: u32) void {
        const self = of(context);
        self.slots.items[id].?.close(self.io);
        self.slots.items[id] = null;
    }
};

test {
    std.testing.refAllDecls(@This());
}

test "a file written through the table is read back through it, and its slot is used again" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var table: FileTable = .init(std.testing.io, std.testing.allocator);
    defer table.deinit();
    const h = table.host();
    const path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(path);
    const name = try std.fs.path.join(std.testing.allocator, &.{ path, "a.txt" });
    defer std.testing.allocator.free(name);

    try std.testing.expect(!h.exists(h.context, name));
    const out = try h.open(h.context, name, .output);
    try h.write(h.context, out, "hello");
    h.close(h.context, out);
    try std.testing.expect(h.exists(h.context, name));

    const in = try h.open(h.context, name, .input);
    try std.testing.expectEqual(out, in);
    var buf: [16]u8 = undefined;
    const n = try h.read(h.context, in, &buf);
    try std.testing.expectEqualStrings("hello", buf[0..n]);
    try std.testing.expectEqual(0, try h.read(h.context, in, &buf));
    // 開いたままの2つ目は、別の欄に入る。
    const second = try h.open(h.context, name, .input);
    try std.testing.expect(second != in);
    h.close(h.context, in);
    h.close(h.context, second);

    try h.delete(h.context, name);
    try std.testing.expect(!h.exists(h.context, name));
    try std.testing.expectError(error.Refused, h.delete(h.context, name));
    try std.testing.expectError(error.Refused, h.open(h.context, name, .input));
    // 開けなかった欄は、空いたままである。
    for (table.slots.items) |slot| try std.testing.expectEqual(null, slot);
}

test "a directory is not opened as a file to read, and the table closes what is left open" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var table: FileTable = .init(std.testing.io, std.testing.allocator);
    const h = table.host();
    const path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(path);
    try std.testing.expectError(error.Refused, h.open(h.context, path, .input));
    try std.testing.expectError(error.Refused, h.open(h.context, path, .output));
    try std.testing.expect(h.exists(h.context, path));
    const name = try std.fs.path.join(std.testing.allocator, &.{ path, "b.txt" });
    defer std.testing.allocator.free(name);
    _ = try h.open(h.context, name, .output);
    // 閉じ忘れた欄は、`deinit` が閉じる(閉じなければ、テストの割り当て器が漏れを報告しないが、
    // 記述子が残る。ここでは落ちないことだけを見る)。
    table.deinit();
}
