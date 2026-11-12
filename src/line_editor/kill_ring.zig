//! Kill ring for the line editor.
//!
//! 切り取ったテキストを溜め、貼り付けと回転(7c)をする。入出力にも端末にも触れない。
//! キー割り当て(どのキーでどの関数を呼ぶか)は 7j が決める。
//!
//! 切り取りは、`Ctrl-K`(`killToEnd`)、`Ctrl-U`(`killToStart`)、`Ctrl-W`
//! (`killBackwardSpaceWord`)、`Alt-D`(`killForwardWord`)である。Emacs の規則に従い、
//! 切り取りが続けて行われたときは、1つの項目にまとめる。向きが前(カーソルから後ろへ向かう)
//! ならリングの先頭の項目の後ろに足し、向きが後ろ(カーソルから前へ向かう)なら前に足す。
//! 切り取りと貼り付け以外の操作が間に入ったら、まとめない。呼び出し側(7j)は、その操作の
//! たびに `breakChain` を呼ぶ。`Alt-Y` は、直前の操作が `yank` か `yankPop` のときだけ働く。
//! これも `breakChain` で無効になる。
//!
//! リングは、項目数に上限を置く。超えたら最も古い項目から捨てる。リングは、行をまたいで残す。
//!
//! バッファの変更を取り消せるようにするには、各操作の `undo` に `UndoStack` を渡す。
//! 渡さなければ、バッファを直接変える。

const std = @import("std");
const buffer = @import("buffer.zig");
const undo_mod = @import("undo.zig");

const Buffer = buffer.Buffer;
const Edit = buffer.Edit;
const Range = buffer.Range;
const UndoStack = undo_mod.UndoStack;

pub const default_max_entries: usize = 32;

/// 切り取りの向き。`forward` は、カーソルから後ろ(行末の側)の範囲を切り取る。
pub const Direction = enum { forward, backward };

pub const Error = undo_mod.EditError;

const Yank = struct {
    /// 貼り付けたテキストのバッファ内の位置。
    start: usize,
    len: usize,
};

pub const KillRing = struct {
    gpa: std.mem.Allocator,
    /// 新しい順。`entries.items[0]` が、最後に切り取った項目である。
    entries: std.ArrayList([]u8),
    max_entries: usize,
    /// 直前の操作が切り取りだった。
    chain: bool,
    /// 直前の操作が貼り付けだったときの、貼り付けた範囲。
    last_yank: ?Yank,
    /// `yank` が貼り付ける項目の番号(0 が最新)。`yankPop` が進め、切り取りが 0 に戻す。
    pointer: usize,

    /// `max_entries` は 1 以上である。
    pub fn init(gpa: std.mem.Allocator, max_entries: usize) KillRing {
        std.debug.assert(max_entries >= 1);
        return .{
            .gpa = gpa,
            .entries = .empty,
            .max_entries = max_entries,
            .chain = false,
            .last_yank = null,
            .pointer = 0,
        };
    }

    pub fn deinit(self: *KillRing) void {
        for (self.entries.items) |e| self.gpa.free(e);
        self.entries.deinit(self.gpa);
        self.* = undefined;
    }

    pub fn len(self: *const KillRing) usize {
        return self.entries.items.len;
    }

    /// 最新の項目。空なら null。
    pub fn top(self: *const KillRing) ?[]const u8 {
        if (self.entries.items.len == 0) return null;
        return self.entries.items[0];
    }

    /// Ends the current run of kills and the chance to rotate with `yankPop`.
    /// 切り取りと貼り付け以外の操作(移動、挿入、削除、取り消し、履歴の呼び出し)のたびに呼ぶ。
    pub fn breakChain(self: *KillRing) void {
        self.chain = false;
        self.last_yank = null;
    }

    // -----------------------------------------------------------------------
    // 切り取り
    // -----------------------------------------------------------------------

    /// `Ctrl-K`: from the cursor to the end of the line.
    pub fn killToEnd(self: *KillRing, buf: *Buffer, undo: ?*UndoStack) Error!?Edit {
        return self.kill(buf, buf.rangeToEnd(), .forward, undo);
    }

    /// `Ctrl-U`: from the start of the line to the cursor.
    pub fn killToStart(self: *KillRing, buf: *Buffer, undo: ?*UndoStack) Error!?Edit {
        return self.kill(buf, buf.rangeToStart(), .backward, undo);
    }

    /// `Ctrl-W`: the run of non-space characters before the cursor.
    pub fn killBackwardSpaceWord(self: *KillRing, buf: *Buffer, undo: ?*UndoStack) Error!?Edit {
        return self.kill(buf, buf.rangeBackwardSpaceWord(), .backward, undo);
    }

    /// `Alt-D`: to the end of the next word.
    pub fn killForwardWord(self: *KillRing, buf: *Buffer, undo: ?*UndoStack) Error!?Edit {
        return self.kill(buf, buf.rangeForwardWord(), .forward, undo);
    }

    /// Cuts `range` out of `buf` and puts it in the ring. 範囲が空なら、何もせず null を返す
    /// (リングも、切り取りの連なりも変えない)。失敗したときは、バッファもリングも変えない。
    pub fn kill(self: *KillRing, buf: *Buffer, range: Range, dir: Direction, undo: ?*UndoStack) Error!?Edit {
        if (range.start > range.end or !buf.isBoundary(range.start) or !buf.isBoundary(range.end))
            return error.InvalidRange;
        if (range.isEmpty()) return null;
        const cut = buf.text()[range.start..range.end];

        // バッファを変える前に、リングに要る確保をすべて済ませる。
        const merge = self.chain and self.entries.items.len > 0;
        var item: []u8 = undefined;
        if (merge) {
            const old = self.entries.items[0];
            item = try self.gpa.alloc(u8, old.len + cut.len);
            switch (dir) {
                .forward => {
                    @memcpy(item[0..old.len], old);
                    @memcpy(item[old.len..], cut);
                },
                .backward => {
                    @memcpy(item[0..cut.len], cut);
                    @memcpy(item[cut.len..], old);
                },
            }
        } else {
            item = try self.gpa.dupe(u8, cut);
        }
        errdefer self.gpa.free(item);
        if (!merge) try self.entries.ensureUnusedCapacity(self.gpa, 1);

        const edit = if (undo) |u|
            try u.deleteRange(buf, range)
        else
            buf.deleteRange(range) catch |e| switch (e) {
                error.InvalidRange => return error.InvalidRange,
            };

        // ここから先は失敗しない。
        if (merge) {
            self.gpa.free(self.entries.items[0]);
            self.entries.items[0] = item;
        } else {
            self.entries.insertAssumeCapacity(0, item);
            if (self.entries.items.len > self.max_entries) {
                self.gpa.free(self.entries.pop().?);
            }
        }
        self.pointer = 0;
        self.chain = true;
        self.last_yank = null;
        return edit;
    }

    // -----------------------------------------------------------------------
    // 貼り付け
    // -----------------------------------------------------------------------

    /// `Ctrl-Y`: inserts the ring entry at the pointer at the cursor.
    /// リングが空なら、何もせず null を返す。
    pub fn yank(self: *KillRing, buf: *Buffer, undo: ?*UndoStack) Error!?Edit {
        if (self.entries.items.len == 0) return null;
        const item = self.entries.items[self.pointer];
        const start = buf.cursor;
        const edit = try insertEdit(buf, undo, item);
        self.chain = false;
        self.last_yank = .{ .start = start, .len = item.len };
        return edit;
    }

    /// `Alt-Y`: replaces the text just yanked with the next older entry.
    /// 直前の操作が貼り付けでないとき(間に別の操作が入った、カーソルが貼り付けの直後に無い)や、
    /// 回転する先が無い(項目が1つ以下)ときは、何もせず null を返す。
    pub fn yankPop(self: *KillRing, buf: *Buffer, undo: ?*UndoStack) Error!?Edit {
        const y = self.last_yank orelse return null;
        if (self.entries.items.len < 2) return null;
        if (buf.cursor != y.start + y.len or y.start + y.len > buf.text().len) return null;
        const next = (self.pointer + 1) % self.entries.items.len;
        const item = self.entries.items[next];
        const range: Range = .{ .start = y.start, .end = y.start + y.len };
        const edit = if (undo) |u|
            try u.replaceRange(buf, range, item)
        else
            try buf.replaceRange(range, item);
        self.pointer = next;
        self.last_yank = .{ .start = y.start, .len = item.len };
        self.chain = false;
        return edit;
    }

    fn insertEdit(buf: *Buffer, undo: ?*UndoStack, s: []const u8) Error!Edit {
        if (undo) |u| return u.insertSlice(buf, s);
        return buf.insertSlice(s);
    }
};

// ---------------------------------------------------------------------------
// テスト
// ---------------------------------------------------------------------------

const testing = std.testing;

test {
    std.testing.refAllDecls(@This());
}

fn fromMarked(marked: []const u8) !Buffer {
    var b: Buffer = .init(testing.allocator);
    errdefer b.deinit();
    const bar = std.mem.indexOfScalar(u8, marked, '|').?;
    _ = try b.insertSlice(marked[0..bar]);
    _ = try b.insertSlice(marked[bar + 1 ..]);
    try b.setCursor(bar);
    return b;
}

fn expectMarked(expected: []const u8, b: *const Buffer) !void {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try out.appendSlice(testing.allocator, b.text()[0..b.cursor]);
    try out.append(testing.allocator, '|');
    try out.appendSlice(testing.allocator, b.text()[b.cursor..]);
    try testing.expectEqualStrings(expected, out.items);
}

fn expectTop(expected: []const u8, r: *const KillRing) !void {
    try testing.expectEqualStrings(expected, r.top().?);
}

test "Ctrl-K kills to the end and Ctrl-Y puts it back" {
    var b = try fromMarked("foo| bar");
    defer b.deinit();
    var r: KillRing = .init(testing.allocator, 4);
    defer r.deinit();
    const e = (try r.killToEnd(&b, null)).?;
    try testing.expectEqual(@as(usize, 4), e.removed_len);
    try expectMarked("foo|", &b);
    try expectTop(" bar", &r);
    _ = try r.yank(&b, null);
    try expectMarked("foo bar|", &b);
    _ = try r.yank(&b, null);
    try expectMarked("foo bar bar|", &b);
}

test "Ctrl-U kills to the start" {
    var b = try fromMarked("foo |bar");
    defer b.deinit();
    var r: KillRing = .init(testing.allocator, 4);
    defer r.deinit();
    _ = try r.killToStart(&b, null);
    try expectMarked("|bar", &b);
    try expectTop("foo ", &r);
}

test "Ctrl-W kills the space-delimited word before the cursor" {
    var b = try fromMarked("(define x|)");
    defer b.deinit();
    var r: KillRing = .init(testing.allocator, 4);
    defer r.deinit();
    _ = try r.killBackwardSpaceWord(&b, null);
    try expectMarked("(define |)", &b);
    try expectTop("x", &r);
    // 空白を飛ばして、前の語まで届く。区切りは空白だけなので、括弧も語に入る。
    _ = try r.killBackwardSpaceWord(&b, null);
    try expectMarked("|)", &b);
    try expectTop("(define x", &r);
}

test "Alt-D kills the next word" {
    var b = try fromMarked("|foo bar baz");
    defer b.deinit();
    var r: KillRing = .init(testing.allocator, 4);
    defer r.deinit();
    _ = try r.killForwardWord(&b, null);
    try expectMarked("| bar baz", &b);
    try expectTop("foo", &r);
}

test "consecutive forward kills append" {
    var b = try fromMarked("|foo bar baz");
    defer b.deinit();
    var r: KillRing = .init(testing.allocator, 4);
    defer r.deinit();
    _ = try r.killForwardWord(&b, null);
    _ = try r.killForwardWord(&b, null);
    try expectMarked("| baz", &b);
    try testing.expectEqual(@as(usize, 1), r.len());
    try expectTop("foo bar", &r);
}

test "consecutive backward kills prepend" {
    var b = try fromMarked("foo bar baz|");
    defer b.deinit();
    var r: KillRing = .init(testing.allocator, 4);
    defer r.deinit();
    _ = try r.killBackwardSpaceWord(&b, null);
    _ = try r.killBackwardSpaceWord(&b, null);
    try expectMarked("foo |", &b);
    try testing.expectEqual(@as(usize, 1), r.len());
    try expectTop("bar baz", &r);
}

test "a kill in the other direction joins on the matching side" {
    var b = try fromMarked("aa bb| cc dd");
    defer b.deinit();
    var r: KillRing = .init(testing.allocator, 4);
    defer r.deinit();
    _ = try r.killBackwardSpaceWord(&b, null); // "bb"
    try expectTop("bb", &r);
    _ = try r.killForwardWord(&b, null); // " cc" は後ろに足す
    try expectTop("bb cc", &r);
    _ = try r.killBackwardSpaceWord(&b, null); // "aa " を前に足す
    try expectTop("aa bb cc", &r);
    try testing.expectEqual(@as(usize, 1), r.len());
}

test "Ctrl-K and Ctrl-U join on the side they cut from" {
    var r: KillRing = .init(testing.allocator, 4);
    defer r.deinit();
    var b = try fromMarked("ab|cd");
    defer b.deinit();
    _ = try r.killToEnd(&b, null);
    _ = try r.killToStart(&b, null);
    try expectTop("abcd", &r);
    try expectMarked("|", &b);
    r.breakChain();
    var c = try fromMarked("ab|cd");
    defer c.deinit();
    _ = try r.killToStart(&c, null);
    _ = try r.killToEnd(&c, null);
    try expectTop("abcd", &r);
}

test "breakChain starts a new entry" {
    var b = try fromMarked("|foo bar baz");
    defer b.deinit();
    var r: KillRing = .init(testing.allocator, 4);
    defer r.deinit();
    _ = try r.killForwardWord(&b, null);
    r.breakChain();
    _ = try r.killForwardWord(&b, null);
    try testing.expectEqual(@as(usize, 2), r.len());
    try expectTop(" bar", &r);
}

test "a yank between kills breaks the run" {
    var b = try fromMarked("|foo bar baz");
    defer b.deinit();
    var r: KillRing = .init(testing.allocator, 4);
    defer r.deinit();
    _ = try r.killForwardWord(&b, null);
    _ = try r.yank(&b, null);
    _ = try r.killForwardWord(&b, null);
    try testing.expectEqual(@as(usize, 2), r.len());
}

test "killing an empty range does nothing" {
    var b = try fromMarked("foo|");
    defer b.deinit();
    var r: KillRing = .init(testing.allocator, 4);
    defer r.deinit();
    try testing.expect((try r.killToEnd(&b, null)) == null);
    try testing.expectEqual(@as(usize, 0), r.len());
    // 空の切り取りは、続いている切り取りの連なりを切らない。
    var c = try fromMarked("|ab");
    defer c.deinit();
    _ = try r.kill(&c, .{ .start = 0, .end = 1 }, .forward, null);
    try testing.expect((try r.kill(&c, .{ .start = 0, .end = 0 }, .forward, null)) == null);
    _ = try r.kill(&c, .{ .start = 0, .end = 1 }, .forward, null);
    try expectTop("ab", &r);
    try testing.expectEqual(@as(usize, 1), r.len());
}

test "kill rejects an invalid range without changing anything" {
    var b = try fromMarked("あい|");
    defer b.deinit();
    var r: KillRing = .init(testing.allocator, 4);
    defer r.deinit();
    try testing.expectError(error.InvalidRange, r.kill(&b, .{ .start = 1, .end = 3 }, .forward, null));
    try testing.expectError(error.InvalidRange, r.kill(&b, .{ .start = 0, .end = 99 }, .forward, null));
    try testing.expectError(error.InvalidRange, r.kill(&b, .{ .start = 3, .end = 0 }, .forward, null));
    try testing.expectEqual(@as(usize, 0), r.len());
    try expectMarked("あい|", &b);
}

test "yank on an empty ring does nothing" {
    var b = try fromMarked("a|");
    defer b.deinit();
    var r: KillRing = .init(testing.allocator, 4);
    defer r.deinit();
    try testing.expect((try r.yank(&b, null)) == null);
    try testing.expect((try r.yankPop(&b, null)) == null);
    try expectMarked("a|", &b);
}

fn ringWith(r: *KillRing, items: []const []const u8) !void {
    for (items) |s| {
        var b = try fromMarked("|");
        defer b.deinit();
        _ = try b.insertSlice(s);
        b.moveToStart();
        _ = try r.killToEnd(&b, null);
        r.breakChain();
    }
}

test "Alt-Y rotates through older entries and wraps around" {
    var r: KillRing = .init(testing.allocator, 8);
    defer r.deinit();
    try ringWith(&r, &.{ "one", "two", "three" }); // 新しい順: three, two, one
    var b = try fromMarked("[|]");
    defer b.deinit();
    _ = try r.yank(&b, null);
    try expectMarked("[three|]", &b);
    _ = try r.yankPop(&b, null);
    try expectMarked("[two|]", &b);
    _ = try r.yankPop(&b, null);
    try expectMarked("[one|]", &b);
    _ = try r.yankPop(&b, null);
    try expectMarked("[three|]", &b);
}

test "Alt-Y only works right after a yank" {
    var r: KillRing = .init(testing.allocator, 8);
    defer r.deinit();
    try ringWith(&r, &.{ "one", "two" });
    var b = try fromMarked("[|]");
    defer b.deinit();
    try testing.expect((try r.yankPop(&b, null)) == null); // 貼り付けの前
    _ = try r.yank(&b, null);
    r.breakChain();
    try testing.expect((try r.yankPop(&b, null)) == null); // 別の操作のあと
    try expectMarked("[two|]", &b);
    _ = try r.yank(&b, null);
    b.moveBackwardChar(); // カーソルを動かすと、貼り付けの直後ではなくなる
    try testing.expect((try r.yankPop(&b, null)) == null);
}

test "a kill after a yank or a rotation disables Alt-Y and starts a new entry" {
    var r: KillRing = .init(testing.allocator, 8);
    defer r.deinit();
    try ringWith(&r, &.{ "one", "two" });
    var b = try fromMarked("|");
    defer b.deinit();
    _ = try r.yank(&b, null);
    _ = try r.killBackwardSpaceWord(&b, null); // 貼り付けた "two" を切り取る
    _ = try r.yank(&b, null);
    try testing.expectEqual(@as(usize, 3), r.len());
    _ = try r.yankPop(&b, null);
    // 回転のあとの切り取りは、先頭の項目に連結せず、新しい項目になる。
    _ = try r.killBackwardSpaceWord(&b, null);
    try testing.expectEqual(@as(usize, 4), r.len());
    try testing.expect((try r.yankPop(&b, null)) == null);
}

test "Alt-Y with a single entry does nothing" {
    var r: KillRing = .init(testing.allocator, 8);
    defer r.deinit();
    try ringWith(&r, &.{"only"});
    var b = try fromMarked("|");
    defer b.deinit();
    _ = try r.yank(&b, null);
    try testing.expect((try r.yankPop(&b, null)) == null);
    try expectMarked("only|", &b);
}

test "the rotated entry is what the next Ctrl-Y inserts, until a new kill" {
    var r: KillRing = .init(testing.allocator, 8);
    defer r.deinit();
    try ringWith(&r, &.{ "one", "two" }); // two, one
    var b = try fromMarked("|");
    defer b.deinit();
    _ = try r.yank(&b, null);
    _ = try r.yankPop(&b, null);
    try expectMarked("one|", &b);
    r.breakChain();
    _ = try r.yank(&b, null);
    try expectMarked("oneone|", &b);
    // 新しい切り取りは、先頭に戻す。
    b.moveToStart();
    _ = try r.killToEnd(&b, null);
    _ = try r.yank(&b, null);
    try expectMarked("oneone|", &b);
    try testing.expectEqual(@as(usize, 3), r.len());
}

test "Alt-Y replaces text with different lengths and multi-byte entries" {
    var r: KillRing = .init(testing.allocator, 8);
    defer r.deinit();
    try ringWith(&r, &.{ "あいう", "x" }); // x, あいう
    var b = try fromMarked("<|>");
    defer b.deinit();
    _ = try r.yank(&b, null);
    try expectMarked("<x|>", &b);
    _ = try r.yankPop(&b, null);
    try expectMarked("<あいう|>", &b);
    _ = try r.yankPop(&b, null);
    try expectMarked("<x|>", &b);
}

test "the ring drops the oldest entry past its limit" {
    var r: KillRing = .init(testing.allocator, 2);
    defer r.deinit();
    try ringWith(&r, &.{ "a", "b", "c" });
    try testing.expectEqual(@as(usize, 2), r.len());
    var b = try fromMarked("|");
    defer b.deinit();
    _ = try r.yank(&b, null);
    _ = try r.yankPop(&b, null);
    try expectMarked("b|", &b);
    _ = try r.yankPop(&b, null);
    try expectMarked("c|", &b);
}

test "a limit of one keeps the newest entry" {
    var r: KillRing = .init(testing.allocator, 1);
    defer r.deinit();
    try ringWith(&r, &.{ "a", "b" });
    try testing.expectEqual(@as(usize, 1), r.len());
    try expectTop("b", &r);
}

test "merging into the top entry does not count against the limit" {
    var b = try fromMarked("|abc def");
    defer b.deinit();
    var r: KillRing = .init(testing.allocator, 1);
    defer r.deinit();
    _ = try r.killForwardWord(&b, null);
    _ = try r.killForwardWord(&b, null);
    try expectTop("abc def", &r);
}

test "kills, yanks and Alt-Y are undoable one step at a time" {
    var r: KillRing = .init(testing.allocator, 8);
    defer r.deinit();
    var u: UndoStack = .init(testing.allocator, 20);
    defer u.deinit();
    var b = try fromMarked("one |two three");
    defer b.deinit();
    _ = try r.killToEnd(&b, &u);
    try expectMarked("one |", &b);
    r.breakChain();
    b.moveToStart();
    _ = try r.killForwardWord(&b, &u);
    try expectMarked("| ", &b);
    r.breakChain();
    _ = try r.yank(&b, &u); // "one"
    _ = try r.yankPop(&b, &u); // "two three"
    try expectMarked("two three| ", &b);
    _ = try u.undo(&b); // Alt-Y の取り消し
    try expectMarked("one| ", &b);
    _ = try u.undo(&b); // 貼り付けの取り消し
    try expectMarked("| ", &b);
    _ = try u.undo(&b);
    try expectMarked("|one ", &b);
    _ = try u.undo(&b);
    try expectMarked("one |two three", &b);
}

test "allocation failure leaves the buffer and the ring unchanged" {
    var fail_at: usize = 0;
    while (fail_at < 10) : (fail_at += 1) {
        var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = fail_at });
        var r: KillRing = .init(failing.allocator(), 4);
        defer r.deinit();
        var b = try fromMarked("|foo bar");
        defer b.deinit();
        if (r.killForwardWord(&b, null)) |_| {
            try expectMarked("| bar", &b);
            try testing.expectEqual(@as(usize, 1), r.len());
        } else |err| {
            try testing.expectEqual(error.OutOfMemory, err);
            try expectMarked("|foo bar", &b);
            try testing.expectEqual(@as(usize, 0), r.len());
            continue;
        }
        if (r.killForwardWord(&b, null)) |_| {} else |_| {
            // 連結の確保に失敗しても、バッファとリングは前のまま。
            try testing.expectEqual(@as(usize, 1), r.len());
            try expectTop("foo", &r);
            try expectMarked("| bar", &b);
        }
    }
}
