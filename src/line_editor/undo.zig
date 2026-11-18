//! Undo records for the line editor.
//!
//! 編集を1つずつ取り消すための記録(7c)。入出力にも端末にも触れない。やり直し(redo)は
//! 核に含めない。
//!
//! 記録は、`buffer.Edit` と、その編集で取り除かれたテキストの複製である(`Edit` は取り除かれた
//! テキストを持たないので、操作の前に写す必要がある)。そのため、バッファを変える操作は、この
//! 型のラッパ(`insertTyped`、`insertSlice`、`replaceRange`、`deleteRange`、`transpose`)を
//! 通して行う。ラッパは、記録に要る確保をバッファの変更の前に済ませるので、失敗したときは
//! バッファも記録も変わらない。
//!
//! まとめ方: `insertTyped` で入れた、隣り合う文字の挿入は、1つの記録にまとめる(Emacs 風)。
//! まとまりは、他の記録の追加、`breakGroup`、`undo`、`clear` のどれかで閉じる。カーソルの移動や
//! 履歴の移動など、この型を通らない操作のとき、呼び出し側(7j)は `breakGroup` を呼ぶ。
//! 呼び忘れても、挿入の位置が前の挿入の直後でなければまとめない。
//!
//! メモリの上限: 記録の項目数に上限を置く。超えたら、最も古い項目から捨てる。

const std = @import("std");
const buffer = @import("buffer.zig");

const Buffer = buffer.Buffer;
const Edit = buffer.Edit;
const Range = buffer.Range;

pub const default_max_entries: usize = 200;

pub const Entry = struct {
    edit: Edit,
    /// 取り除かれたテキストの複製。`edit.removed_len` バイトである。
    removed: []const u8,
};

pub const RecordError = error{OutOfMemory};
pub const EditError = RecordError || buffer.InsertError || buffer.RangeError;
pub const UndoError = RecordError || buffer.RangeError;

pub const UndoStack = struct {
    gpa: std.mem.Allocator,
    /// 古い順。最後が、次に取り消される項目である。
    entries: std.ArrayList(Entry),
    max_entries: usize,
    /// 最後の項目が、`insertTyped` のまとまりで、まだ閉じていない。
    typing: bool,

    /// `max_entries` は 1 以上である。
    pub fn init(gpa: std.mem.Allocator, max_entries: usize) UndoStack {
        std.debug.assert(max_entries >= 1);
        return .{ .gpa = gpa, .entries = .empty, .max_entries = max_entries, .typing = false };
    }

    pub fn deinit(self: *UndoStack) void {
        self.clear();
        self.entries.deinit(self.gpa);
        self.* = undefined;
    }

    /// Drops every record. 新しい行を読み始めるときや、履歴の項目でバッファを置き換えるときに呼ぶ。
    pub fn clear(self: *UndoStack) void {
        for (self.entries.items) |e| self.gpa.free(e.removed);
        self.entries.clearRetainingCapacity();
        self.typing = false;
    }

    pub fn len(self: *const UndoStack) usize {
        return self.entries.items.len;
    }

    /// Closes the current group of typed insertions.
    pub fn breakGroup(self: *UndoStack) void {
        self.typing = false;
    }

    // -----------------------------------------------------------------------
    // 記録つきの変更
    // -----------------------------------------------------------------------

    /// Inserts typed text at the cursor, merging with the previous typed insertion
    /// when it ends exactly where this one starts.
    pub fn insertTyped(self: *UndoStack, buf: *Buffer, s: []const u8) EditError!Edit {
        try self.entries.ensureUnusedCapacity(self.gpa, 1);
        const edit = buf.insertSlice(s) catch |e| switch (e) {
            error.OutOfMemory, error.InvalidUtf8, error.CarriageReturn => |other| return other,
        };
        if (edit.isNoop()) return edit;
        if (self.typing and self.entries.items.len > 0) {
            // `typing` が真のとき、最後の項目は、`insertTyped` が積んだ挿入だけの項目である
            // (他の項目を積む操作は、`typing` を偽にする)。
            const last = &self.entries.items[self.entries.items.len - 1];
            std.debug.assert(last.edit.removed_len == 0);
            if (last.edit.pos + last.edit.inserted_len == edit.pos) {
                last.edit.inserted_len += edit.inserted_len;
                return edit;
            }
        }
        self.push(.{ .edit = edit, .removed = &.{} });
        self.typing = true;
        return edit;
    }

    /// Inserts `s` at the cursor as its own record (a paste does not merge with typing).
    pub fn insertSlice(self: *UndoStack, buf: *Buffer, s: []const u8) EditError!Edit {
        return self.replaceRange(buf, .{ .start = buf.cursor, .end = buf.cursor }, s);
    }

    pub fn deleteRange(self: *UndoStack, buf: *Buffer, range: Range) EditError!Edit {
        return self.replaceRange(buf, range, "");
    }

    /// Replaces `range` with `new_text` and records it as one entry.
    pub fn replaceRange(self: *UndoStack, buf: *Buffer, range: Range, new_text: []const u8) EditError!Edit {
        if (range.start > range.end or !buf.isBoundary(range.start) or !buf.isBoundary(range.end))
            return error.InvalidRange;
        try self.entries.ensureUnusedCapacity(self.gpa, 1);
        const removed = try self.gpa.dupe(u8, buf.text()[range.start..range.end]);
        errdefer self.gpa.free(removed);
        const edit = try buf.replaceRange(range, new_text);
        return self.commit(edit, removed);
    }

    /// Swaps two characters (`Ctrl-T`) and records it. 何もしないときは null を返す。
    pub fn transpose(self: *UndoStack, buf: *Buffer) RecordError!?Edit {
        const r = buf.transposeRange() orelse return null;
        try self.entries.ensureUnusedCapacity(self.gpa, 1);
        const removed = try self.gpa.dupe(u8, buf.text()[r.start..r.end]);
        errdefer self.gpa.free(removed);
        const edit = buf.transpose() orelse unreachable;
        return self.commit(edit, removed);
    }

    /// Records an edit that was made without this type. `removed` is copied.
    /// 低水準の入口で、取り除かれたテキストは、呼び出し側が操作の前に写したものを渡す。
    pub fn record(self: *UndoStack, edit: Edit, removed: []const u8) RecordError!void {
        if (edit.isNoop()) return;
        std.debug.assert(removed.len == edit.removed_len);
        try self.entries.ensureUnusedCapacity(self.gpa, 1);
        const copy = try self.gpa.dupe(u8, removed);
        self.push(.{ .edit = edit, .removed = copy });
        self.typing = false;
    }

    // -----------------------------------------------------------------------
    // 取り消し
    // -----------------------------------------------------------------------

    /// Undoes the newest record (`Ctrl-_`). 取り消すものが無いときは null を返す。
    ///
    /// バッファが、記録の通らない方法で変えられていて、記録が合わなくなったときは、
    /// 記録をすべて捨てて `error.InvalidRange` を返す(以後の取り消しが、同じ誤りで
    /// 止まり続けないようにする)。取り消しの結果は、記録に積まない。
    pub fn undo(self: *UndoStack, buf: *Buffer) UndoError!?Edit {
        self.typing = false;
        if (self.entries.items.len == 0) return null;
        const last = self.entries.items[self.entries.items.len - 1];
        const e = last.edit;
        const range: Range = .{ .start = e.pos, .end = e.pos + e.inserted_len };
        const result = buf.replaceRange(range, last.removed) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            // 記録は、バッファの中のテキストを写したものなので、不正な UTF-8 にも改行にもならない。
            // 起こるのは、範囲が合わないときだけである。
            error.InvalidRange, error.InvalidUtf8, error.CarriageReturn => {
                self.clear();
                return error.InvalidRange;
            },
        };
        buf.setCursor(e.cursor_before) catch {
            self.clear();
            return error.InvalidRange;
        };
        self.gpa.free(last.removed);
        self.entries.items.len -= 1;
        return result;
    }

    fn commit(self: *UndoStack, edit: Edit, removed: []const u8) Edit {
        if (edit.isNoop()) {
            // 何も変えなかった。記録に積まず、取り除いたテキストの複製(空)を捨てる。
            self.gpa.free(removed);
            return edit;
        }
        self.push(.{ .edit = edit, .removed = removed });
        self.typing = false;
        return edit;
    }

    /// 容量は、呼び出しの前に確保してある。
    fn push(self: *UndoStack, entry: Entry) void {
        self.entries.appendAssumeCapacity(entry);
        if (self.entries.items.len > self.max_entries) {
            self.gpa.free(self.entries.items[0].removed);
            _ = self.entries.orderedRemove(0);
        }
    }
};

// ---------------------------------------------------------------------------
// テスト
// ---------------------------------------------------------------------------

const testing = std.testing;

test {
    std.testing.refAllDecls(@This());
}

fn expectMarked(expected: []const u8, b: *const Buffer) !void {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try out.appendSlice(testing.allocator, b.text()[0..b.cursor]);
    try out.append(testing.allocator, '|');
    try out.appendSlice(testing.allocator, b.text()[b.cursor..]);
    try testing.expectEqualStrings(expected, out.items);
}

fn typeString(u: *UndoStack, b: *Buffer, s: []const u8) !void {
    var it = (try std.unicode.Utf8View.init(s)).iterator();
    while (it.nextCodepointSlice()) |c| _ = try u.insertTyped(b, c);
}

test "consecutive typed characters undo as one step" {
    var b: Buffer = .init(testing.allocator);
    defer b.deinit();
    var u: UndoStack = .init(testing.allocator, 10);
    defer u.deinit();
    try typeString(&u, &b, "abc");
    try testing.expectEqual(@as(usize, 1), u.len());
    try expectMarked("abc|", &b);
    const e = (try u.undo(&b)).?;
    try testing.expectEqual(@as(usize, 3), e.removed_len);
    try expectMarked("|", &b);
    try testing.expect((try u.undo(&b)) == null);
}

test "breakGroup splits typed groups" {
    var b: Buffer = .init(testing.allocator);
    defer b.deinit();
    var u: UndoStack = .init(testing.allocator, 10);
    defer u.deinit();
    try typeString(&u, &b, "ab");
    u.breakGroup();
    try typeString(&u, &b, "cd");
    try testing.expectEqual(@as(usize, 2), u.len());
    _ = try u.undo(&b);
    try expectMarked("ab|", &b);
    _ = try u.undo(&b);
    try expectMarked("|", &b);
}

test "typed insertions that are not adjacent do not merge even without breakGroup" {
    var b: Buffer = .init(testing.allocator);
    defer b.deinit();
    var u: UndoStack = .init(testing.allocator, 10);
    defer u.deinit();
    try typeString(&u, &b, "ab");
    b.moveToStart();
    try typeString(&u, &b, "X");
    try testing.expectEqual(@as(usize, 2), u.len());
    _ = try u.undo(&b);
    try expectMarked("|ab", &b);
}

test "typing after an undo does not merge into the earlier group" {
    var b: Buffer = .init(testing.allocator);
    defer b.deinit();
    var u: UndoStack = .init(testing.allocator, 10);
    defer u.deinit();
    try typeString(&u, &b, "ab");
    u.breakGroup();
    try typeString(&u, &b, "cd");
    _ = try u.undo(&b);
    try expectMarked("ab|", &b);
    try typeString(&u, &b, "e");
    try testing.expectEqual(@as(usize, 2), u.len());
    _ = try u.undo(&b);
    try expectMarked("ab|", &b);
}

test "typing after a delete or a paste starts a new group" {
    var b: Buffer = .init(testing.allocator);
    defer b.deinit();
    var u: UndoStack = .init(testing.allocator, 10);
    defer u.deinit();
    try typeString(&u, &b, "ab");
    _ = try u.insertSlice(&b, "PP"); // 貼り付けは、入力の続きにまとめない
    try typeString(&u, &b, "c");
    try testing.expectEqual(@as(usize, 3), u.len());
    _ = try u.deleteRange(&b, b.rangeBackwardChar());
    try typeString(&u, &b, "d"); // 削除の直後の入力は、削除の記録にまとめない
    try testing.expectEqual(@as(usize, 5), u.len());
    try expectMarked("abPPd|", &b);
}

test "undo restores deleted text and the cursor" {
    var b: Buffer = .init(testing.allocator);
    defer b.deinit();
    var u: UndoStack = .init(testing.allocator, 10);
    defer u.deinit();
    _ = try u.insertSlice(&b, "hello world");
    b.cursor = 5;
    _ = try u.deleteRange(&b, b.rangeToEnd());
    try expectMarked("hello|", &b);
    _ = try u.undo(&b);
    try expectMarked("hello| world", &b);
    // 取り消しの結果は積まれない。もう1つ取り消すと、最初の挿入が戻る。
    _ = try u.undo(&b);
    try expectMarked("|", &b);
}

test "undo restores the cursor of a backward delete" {
    var b: Buffer = .init(testing.allocator);
    defer b.deinit();
    var u: UndoStack = .init(testing.allocator, 10);
    defer u.deinit();
    _ = try u.insertSlice(&b, "foo bar");
    u.breakGroup();
    _ = try u.deleteRange(&b, b.rangeBackwardWord());
    try expectMarked("foo |", &b);
    _ = try u.undo(&b);
    try expectMarked("foo bar|", &b);
}

test "multi-byte characters are grouped and restored" {
    var b: Buffer = .init(testing.allocator);
    defer b.deinit();
    var u: UndoStack = .init(testing.allocator, 10);
    defer u.deinit();
    try typeString(&u, &b, "あい");
    try testing.expectEqual(@as(usize, 1), u.len());
    _ = try u.deleteRange(&b, b.rangeBackwardChar());
    try expectMarked("あ|", &b);
    _ = try u.undo(&b);
    try expectMarked("あい|", &b);
    _ = try u.undo(&b);
    try expectMarked("|", &b);
}

test "transpose is undoable" {
    var b: Buffer = .init(testing.allocator);
    defer b.deinit();
    var u: UndoStack = .init(testing.allocator, 10);
    defer u.deinit();
    _ = try u.insertSlice(&b, "abc");
    try testing.expect((try u.transpose(&b)) != null);
    try expectMarked("acb|", &b);
    _ = try u.undo(&b);
    try expectMarked("abc|", &b);
    b.moveToStart();
    try testing.expect((try u.transpose(&b)) == null); // 何もしない操作は記録しない
    try testing.expectEqual(@as(usize, 1), u.len());
}

test "replaceRange records the replaced text" {
    var b: Buffer = .init(testing.allocator);
    defer b.deinit();
    var u: UndoStack = .init(testing.allocator, 10);
    defer u.deinit();
    _ = try u.insertSlice(&b, "one two");
    _ = try u.replaceRange(&b, .{ .start = 0, .end = 3 }, "1");
    try expectMarked("1| two", &b);
    _ = try u.undo(&b);
    try expectMarked("one two|", &b);
}

test "the entry limit drops the oldest records" {
    var b: Buffer = .init(testing.allocator);
    defer b.deinit();
    var u: UndoStack = .init(testing.allocator, 2);
    defer u.deinit();
    _ = try u.insertSlice(&b, "a");
    _ = try u.insertSlice(&b, "b");
    _ = try u.insertSlice(&b, "c");
    try testing.expectEqual(@as(usize, 2), u.len());
    _ = try u.undo(&b);
    _ = try u.undo(&b);
    try testing.expect((try u.undo(&b)) == null);
    try expectMarked("a|", &b);
}

test "a limit of one keeps only the newest record" {
    var b: Buffer = .init(testing.allocator);
    defer b.deinit();
    var u: UndoStack = .init(testing.allocator, 1);
    defer u.deinit();
    _ = try u.insertSlice(&b, "a");
    _ = try u.deleteRange(&b, b.rangeBackwardChar());
    try testing.expectEqual(@as(usize, 1), u.len());
    _ = try u.undo(&b);
    try expectMarked("a|", &b);
}

test "failed operations record nothing and leave the buffer unchanged" {
    var b: Buffer = .init(testing.allocator);
    defer b.deinit();
    var u: UndoStack = .init(testing.allocator, 10);
    defer u.deinit();
    _ = try u.insertSlice(&b, "ab");
    try testing.expectError(error.InvalidUtf8, u.insertTyped(&b, "\xFF"));
    try testing.expectError(error.CarriageReturn, u.insertSlice(&b, "x\ry"));
    try testing.expectError(error.InvalidRange, u.deleteRange(&b, .{ .start = 1, .end = 9 }));
    try testing.expectError(error.InvalidRange, u.deleteRange(&b, .{ .start = 2, .end = 1 }));
    try testing.expectEqual(@as(usize, 1), u.len());
    try expectMarked("ab|", &b);
}

test "an empty edit is not recorded" {
    var b: Buffer = .init(testing.allocator);
    defer b.deinit();
    var u: UndoStack = .init(testing.allocator, 10);
    defer u.deinit();
    _ = try u.insertTyped(&b, "");
    _ = try u.insertSlice(&b, "");
    _ = try u.deleteRange(&b, b.rangeToEnd());
    try testing.expectEqual(@as(usize, 0), u.len());
}

test "record accepts an edit made without the wrappers" {
    var b: Buffer = .init(testing.allocator);
    defer b.deinit();
    var u: UndoStack = .init(testing.allocator, 10);
    defer u.deinit();
    _ = try b.insertSlice("abc");
    const removed = try testing.allocator.dupe(u8, b.text()[1..3]);
    defer testing.allocator.free(removed);
    const e = try b.deleteRange(.{ .start = 1, .end = 3 });
    try u.record(e, removed);
    _ = try u.undo(&b);
    try expectMarked("abc|", &b);
}

test "dropping the oldest record frees its removed text" {
    var b: Buffer = .init(testing.allocator);
    defer b.deinit();
    var u: UndoStack = .init(testing.allocator, 2);
    defer u.deinit();
    _ = try b.insertSlice("abcdef");
    _ = try u.deleteRange(&b, .{ .start = 0, .end = 2 });
    _ = try u.deleteRange(&b, .{ .start = 0, .end = 1 });
    _ = try u.deleteRange(&b, .{ .start = 0, .end = 1 });
    try testing.expectEqual(@as(usize, 2), u.len());
}

test "a failed replaceRange frees the copy of the removed text" {
    var b: Buffer = .init(testing.allocator);
    defer b.deinit();
    var u: UndoStack = .init(testing.allocator, 10);
    defer u.deinit();
    _ = try b.insertSlice("abcd");
    try testing.expectError(error.CarriageReturn, u.replaceRange(&b, .{ .start = 0, .end = 2 }, "x\ry"));
    try testing.expectEqual(@as(usize, 0), u.len());
    try expectMarked("abcd|", &b);
}

test "an undo whose cursor cannot be restored clears the stack" {
    var b: Buffer = .init(testing.allocator);
    defer b.deinit();
    var u: UndoStack = .init(testing.allocator, 10);
    defer u.deinit();
    const e = try b.insertSlice("a");
    try u.record(.{ .pos = e.pos, .removed_len = 0, .inserted_len = 1, .cursor_before = 99 }, "");
    try testing.expectError(error.InvalidRange, u.undo(&b));
    try testing.expectEqual(@as(usize, 0), u.len());
}

test "transpose as the first record on a fresh stack" {
    var b: Buffer = .init(testing.allocator);
    defer b.deinit();
    var u: UndoStack = .init(testing.allocator, 10);
    defer u.deinit();
    _ = try b.insertSlice("abc");
    try testing.expect((try u.transpose(&b)) != null);
    try testing.expectEqual(@as(usize, 1), u.len());
    _ = try u.undo(&b);
    try expectMarked("abc|", &b);
}

test "record ignores an empty edit and closes the typed group" {
    var b: Buffer = .init(testing.allocator);
    defer b.deinit();
    var u: UndoStack = .init(testing.allocator, 10);
    defer u.deinit();
    try u.record(.{ .pos = 0, .removed_len = 0, .inserted_len = 0, .cursor_before = 0 }, "");
    try testing.expectEqual(@as(usize, 0), u.len());
    try typeString(&u, &b, "ab");
    // 記録の通らない挿入を、直後に記録する。そのあとの入力は、この記録にまとめない。
    const e = try b.insertSlice("X");
    try u.record(e, "");
    try typeString(&u, &b, "c");
    try testing.expectEqual(@as(usize, 3), u.len());
    _ = try u.undo(&b);
    try expectMarked("abX|", &b);
}

test "an inconsistent record clears the stack and reports InvalidRange" {
    var b: Buffer = .init(testing.allocator);
    defer b.deinit();
    var u: UndoStack = .init(testing.allocator, 10);
    defer u.deinit();
    _ = try u.insertSlice(&b, "abcdef");
    _ = try u.insertSlice(&b, "gh");
    // 記録の通らない方法で、バッファを縮める。
    _ = try b.deleteRange(.{ .start = 0, .end = 7 });
    try testing.expectError(error.InvalidRange, u.undo(&b));
    try testing.expectEqual(@as(usize, 0), u.len());
    try testing.expect((try u.undo(&b)) == null);
}

test "clear drops everything and closes the group" {
    var b: Buffer = .init(testing.allocator);
    defer b.deinit();
    var u: UndoStack = .init(testing.allocator, 10);
    defer u.deinit();
    try typeString(&u, &b, "ab");
    u.clear();
    try testing.expectEqual(@as(usize, 0), u.len());
    try typeString(&u, &b, "c");
    try testing.expectEqual(@as(usize, 1), u.len());
    _ = try u.undo(&b);
    try expectMarked("ab|", &b);
}

test "allocation failure at any point leaves the buffer and the stack consistent" {
    var fail_at: usize = 0;
    while (fail_at < 12) : (fail_at += 1) {
        var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = fail_at });
        const gpa = failing.allocator();
        var b: Buffer = .init(testing.allocator);
        defer b.deinit();
        _ = try b.insertSlice("hello");
        var u: UndoStack = .init(gpa, 10);
        defer u.deinit();

        const before_text = try testing.allocator.dupe(u8, b.text());
        defer testing.allocator.free(before_text);
        const before_cursor = b.cursor;
        if (u.deleteRange(&b, b.rangeBackwardChar())) |_| {
            try testing.expectEqual(@as(usize, 1), u.len());
        } else |err| {
            try testing.expectEqual(error.OutOfMemory, err);
            try testing.expectEqual(@as(usize, 0), u.len());
            try testing.expectEqualStrings(before_text, b.text());
            try testing.expectEqual(before_cursor, b.cursor);
        }
        if (u.insertTyped(&b, "x")) |_| {} else |err| {
            try testing.expectEqual(error.OutOfMemory, err);
        }
    }
}
