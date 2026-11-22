//! The input the host gives the console, which the program reads when it asks.
//!
//! ブラウザ(WASM)には、標準入力を読む口が無い。ホストが `sucheme_provide_input` で渡した
//! バイト列を、ここに置く。コンソールの入力ポートは、ここから読む(`src/port.zig`)。読み取りの
//! プリミティブは、ここが空で、終端も受け取っていなければ「入力待ち」を返す
//! (docs/design/platform-and-web.md の再開可能性、ADR-0055)。
//!
//! 持つのは、渡されて、まだ読まれていないバイト列と、終端を受け取ったかどうかだけである。
//! バイト列の領域は、呼び出し側が渡す割り当て器から取る。インタプリタは、ヒープの常駐の
//! 割り当て器(`Heap.residentAllocator`)を渡し、領域は上限に計上される。評価をまたいで
//! 残る(読まれなかった分は、次の評価が読む)。

const std = @import("std");

pub const HostInput = struct {
    /// Where the bytes the host gave are; the ones not yet read are `bytes.items[pos..]`.
    bytes: std.ArrayList(u8) = .empty,
    /// How many bytes at the start of `bytes` have been read.
    pos: usize = 0,
    /// Whether the host has said there is no more input. After that every read gets the end,
    /// once what is held is read.
    /// Why: 終端のあとに `provide` されたバイト列は捨てる。終端のあとの読み取りは、すべて
    /// 終端を返す(設計文書)。続きを受け付けると、同じ読み取りが、前は終端を返し、後は文字を
    /// 返すことになる。
    ended: bool = false,

    /// The bytes given and not yet read.
    pub fn pending(self: *const HostInput) []const u8 {
        return self.bytes.items[self.pos..];
    }

    /// Reads past `n` of the bytes `pending` gives.
    /// 読み終えたら、領域を手放す。入力の大きさに比例した領域を、次の入力まで持ち越さない。
    pub fn consume(self: *HostInput, a: std.mem.Allocator, n: usize) void {
        std.debug.assert(n <= self.bytes.items.len - self.pos);
        self.pos += n;
        if (self.pos == self.bytes.items.len) {
            self.bytes.clearAndFree(a);
            self.pos = 0;
        }
    }

    /// Adds `data` after what is held. Fails with `OutOfMemory` when `a` refuses the room,
    /// and then holds what it held. The bytes given after the end are dropped.
    pub fn provide(self: *HostInput, a: std.mem.Allocator, data: []const u8) error{OutOfMemory}!void {
        if (self.ended or data.len == 0) return;
        // 読み終えた先頭は、足す前に詰める。詰めないと、読んだ分が領域に残り続ける。
        if (self.pos > 0) {
            const unread = self.bytes.items.len - self.pos;
            std.mem.copyForwards(u8, self.bytes.items[0..unread], self.bytes.items[self.pos..]);
            self.bytes.shrinkRetainingCapacity(unread);
            self.pos = 0;
        }
        try self.bytes.appendSlice(a, data);
    }

    /// Records that no more input comes.
    pub fn end(self: *HostInput) void {
        self.ended = true;
    }

    /// Gives back the room, and forgets the end.
    pub fn deinit(self: *HostInput, a: std.mem.Allocator) void {
        self.bytes.deinit(a);
        self.* = .{};
    }
};

test "bytes given are read in order and the room is given back once they are read" {
    const a = std.testing.allocator;
    var input: HostInput = .{};
    defer input.deinit(a);
    try input.provide(a, "ab");
    try input.provide(a, "cd");
    try std.testing.expectEqualStrings("abcd", input.pending());
    input.consume(a, 3);
    try std.testing.expectEqualStrings("d", input.pending());
    // 足す前に、読み終えた先頭を詰める。
    try input.provide(a, "ef");
    try std.testing.expectEqual(@as(usize, 0), input.pos);
    try std.testing.expectEqualStrings("def", input.pending());
    input.consume(a, 3);
    try std.testing.expectEqual(@as(usize, 0), input.bytes.capacity);
    try std.testing.expectEqualStrings("", input.pending());
}

test "nothing given after the end is kept, and deinit forgets the end" {
    const a = std.testing.allocator;
    var input: HostInput = .{};
    defer input.deinit(a);
    try input.provide(a, "x");
    input.end();
    try input.provide(a, "late");
    try std.testing.expectEqualStrings("x", input.pending());
    try std.testing.expect(input.ended);
    input.deinit(a);
    try std.testing.expect(!input.ended);
}

test "a refused provide leaves what was held" {
    var room: [256]u8 = undefined;
    var fixed: std.heap.FixedBufferAllocator = .init(&room);
    const a = fixed.allocator();
    var input: HostInput = .{};
    defer input.deinit(a);
    try input.provide(a, "ab");
    input.consume(a, 1);
    const big: [1024]u8 = @splat('x');
    try std.testing.expectError(error.OutOfMemory, input.provide(a, &big));
    try std.testing.expectEqualStrings("b", input.pending());
}
