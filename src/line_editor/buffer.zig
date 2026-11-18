//! Edit buffer for the line editor.
//!
//! UTF-8 の文字列とカーソルを持つ編集バッファ(7b、複数行は 7m)。入出力にも
//! 端末にも触れない。キー割り当て(7j)、キルリングと取り消し(7c)、再描画(7g)が使う。
//!
//! 不変条件(どの操作の前後でも成り立つ):
//! - `text()` は正しい UTF-8 である。不正なバイト列を挿入する操作は、バッファを変えずに
//!   `error.InvalidUtf8` を返す。
//! - `text()` は `\r` を含まない。論理行の区切りは `\n` だけである(7m)。`\r` を含む文字列の
//!   挿入は、バッファを変えずに `error.CarriageReturn` を返す。
//! - `cursor` は、`0` から `text().len` までの、文字の境界である(文字の途中にならない)。
//!
//! 論理行は、`\n` で区切られた部分である(`\n` は直前の行に属さず、行の外にある)。行頭と
//! 行末の移動、行をまたぐ上下の移動(`moveUpLine` と `moveDownLine`)は、論理行で動く。
//! 上下の移動の「列」は、行頭からの文字数(符号位置の数)である。全角の文字を含む行で、
//! 画面の桁とずれる(表示の幅は 7g が `width.zig` から求め、ここは使わない)。
//!
//! カーソルと範囲は、すべてバイト位置である。表示の列(文字幅)は 7g が `width.zig` から求める。
//! 「文字」は符号位置1つである。結合文字は、基底の文字と別の文字として動く。
//!
//! 変更する操作は、`Edit` を返す。`Edit` は、操作の逆を作れるだけの情報を持つ(下の
//! `Edit` の doc コメント)。取り消しの記録とキルリングの設計は 7c が決める。ここでは、
//! 情報を返すところまでにとどめる。

const std = @import("std");

/// A half-open byte range `[start, end)` of the buffer text.
/// 両端は文字の境界である。`start == end` は空の範囲で、何も指さない。
pub const Range = struct {
    start: usize,
    end: usize,

    pub fn len(self: Range) usize {
        return self.end - self.start;
    }

    pub fn isEmpty(self: Range) bool {
        return self.start == self.end;
    }
};

/// A record of one mutation, enough to build its inverse.
///
/// 変更の前は、`pos` から `removed_len` バイトが、`inserted_len` バイトに入れ替わった。
/// 変更のあと、`text()[pos .. pos + inserted_len]` が入れ替わった側のテキストである。
///
/// 逆の操作は `replaceRange(.{ .start = pos, .end = pos + inserted_len }, 取り除かれた
/// テキスト)` のあと、`setCursor(cursor_before)` である。取り除かれたテキストは、`Edit`
/// には入れない(長さが決まらず、確保が要るため)。取り除かれる範囲は、操作の前に分かる
/// (`rangeBackwardWord` などが返す)ので、必要な呼び出し側は、操作の前に
/// `text()[range.start..range.end]` を写す。`Ctrl-T` の `transpose` は、`transposeRange`
/// が返す範囲を同じように写す。
///
/// `removed_len` と `inserted_len` がともに 0 の `Edit` は、テキストを変えなかった操作である。
/// テキストの取り消しの記録には積まなくてよい。カーソルだけは動いていることがある
/// (空の範囲 `.{ .start = 2, .end = 2 }` の削除など)ので、戻したいときは `cursor_before` を使う。
pub const Edit = struct {
    pos: usize,
    removed_len: usize,
    inserted_len: usize,
    /// The cursor before the mutation.
    cursor_before: usize,

    pub fn isNoop(self: Edit) bool {
        return self.removed_len == 0 and self.inserted_len == 0;
    }
};

pub const InsertError = error{
    OutOfMemory,
    /// 挿入する文字列が正しい UTF-8 でない、または符号位置が不正(サロゲート、U+10FFFF 超)。
    InvalidUtf8,
    /// 挿入する文字列が `\r` を含む。行の区切りは `\n` だけで、`\r` は端末でカーソルを行頭へ
    /// 戻すので、バッファに入れない。
    CarriageReturn,
};

pub const RangeError = error{
    /// 範囲が、バッファの外か、文字の境界にない。
    InvalidRange,
};

pub const Buffer = struct {
    gpa: std.mem.Allocator,
    bytes: std.ArrayList(u8),
    /// Byte offset of the cursor. Read it directly; change it with the move
    /// operations or `setCursor`.
    cursor: usize,

    pub fn init(gpa: std.mem.Allocator) Buffer {
        return .{ .gpa = gpa, .bytes = .empty, .cursor = 0 };
    }

    pub fn deinit(self: *Buffer) void {
        self.bytes.deinit(self.gpa);
        self.* = undefined;
    }

    /// The text of the buffer. The slice is invalidated by the next mutation.
    pub fn text(self: *const Buffer) []const u8 {
        return self.bytes.items;
    }

    /// Sets the cursor to `pos`, which must be a character boundary.
    pub fn setCursor(self: *Buffer, pos: usize) RangeError!void {
        if (!self.isBoundary(pos)) return error.InvalidRange;
        self.cursor = pos;
    }

    pub fn isBoundary(self: *const Buffer, pos: usize) bool {
        const t = self.bytes.items;
        if (pos > t.len) return false;
        return pos == t.len or !isContinuation(t[pos]);
    }

    // -----------------------------------------------------------------------
    // 変更
    // -----------------------------------------------------------------------

    /// Replaces `range` with `new_text`, and puts the cursor after the new text.
    ///
    /// 挿入(空の範囲)、削除(空の `new_text`)、取り消しと貼り付けの基本の操作である。
    /// 失敗したときは、バッファを変えない。`new_text` は、このバッファ自身の `text()` の
    /// 一部でもよい(重なるときは、内部で複製してから置き換える)。
    ///
    /// 空の範囲に空の文字列を入れる操作(何も変えない操作)でも、カーソルは `range.start` に
    /// 動く。返す `Edit` は `isNoop` だが、`cursor_before` が元の位置を持つ。
    pub fn replaceRange(self: *Buffer, range: Range, new_text: []const u8) (InsertError || RangeError)!Edit {
        if (range.start > range.end or !self.isBoundary(range.start) or !self.isBoundary(range.end))
            return error.InvalidRange;
        if (!std.unicode.utf8ValidateSlice(new_text)) return error.InvalidUtf8;
        if (std.mem.indexOfScalar(u8, new_text, '\r') != null) return error.CarriageReturn;
        const items = self.bytes.items;
        const lo = @intFromPtr(items.ptr);
        const at = @intFromPtr(new_text.ptr);
        if (new_text.len > 0 and at < lo + items.len and at + new_text.len > lo) {
            // Why: 置き換えの途中で自分の領域を読むと、再確保や移動で壊れる。
            const copy = try self.gpa.dupe(u8, new_text);
            defer self.gpa.free(copy);
            return self.replaceRange(range, copy);
        }
        const edit: Edit = .{
            .pos = range.start,
            .removed_len = range.len(),
            .inserted_len = new_text.len,
            .cursor_before = self.cursor,
        };
        try self.bytes.replaceRange(self.gpa, range.start, range.len(), new_text);
        self.cursor = range.start + new_text.len;
        return edit;
    }

    /// Inserts `s` at the cursor. The cursor ends up after the inserted text.
    pub fn insertSlice(self: *Buffer, s: []const u8) InsertError!Edit {
        return self.replaceRange(.{ .start = self.cursor, .end = self.cursor }, s) catch |e| switch (e) {
            // カーソルは常に境界にあり、範囲は空なので、起こらない。
            error.InvalidRange => unreachable,
            else => |other| other,
        };
    }

    /// Inserts one code point at the cursor.
    pub fn insertCodepoint(self: *Buffer, cp: u21) InsertError!Edit {
        var tmp: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(cp, &tmp) catch return error.InvalidUtf8;
        return self.insertSlice(tmp[0..n]);
    }

    /// Deletes `range`. The cursor moves to `range.start`.
    pub fn deleteRange(self: *Buffer, range: Range) RangeError!Edit {
        return self.replaceRange(range, "") catch |e| switch (e) {
            // 空の文字列の挿入は、確保も検査も要らない。
            error.OutOfMemory, error.InvalidUtf8, error.CarriageReturn => unreachable,
            error.InvalidRange => error.InvalidRange,
        };
    }

    /// The two characters that `transpose` swaps, as one range, or null when it does nothing.
    ///
    /// `Ctrl-T` の意味(GNU Readline と同じ)。カーソルが論理行の末尾にあるときは、その行の
    /// 最後の2文字。それ以外は、カーソルの前の文字と、カーソルの位置の文字。カーソルが行頭か、
    /// 行の文字が2つ未満のときは、何もしない。改行は入れ替えない(行の区切りが動くため)。
    pub fn transposeRange(self: *const Buffer) ?Range {
        const t = self.bytes.items;
        const at_line_end = self.cursor == t.len or t[self.cursor] == '\n';
        if (self.cursor == 0 or t[self.cursor - 1] == '\n') return null;
        if (at_line_end) {
            const second = prevStart(t, self.cursor);
            if (second == 0 or t[second - 1] == '\n') return null;
            return .{ .start = prevStart(t, second), .end = self.cursor };
        }
        const first = prevStart(t, self.cursor);
        return .{ .start = first, .end = nextEnd(t, self.cursor) };
    }

    /// Swaps two characters (`Ctrl-T`); see `transposeRange` for which. The
    /// cursor ends up after the pair, so repeated calls drag a character forward.
    /// 何もしないときは null を返す。
    pub fn transpose(self: *Buffer) ?Edit {
        const r = self.transposeRange() orelse return null;
        const t = self.bytes.items;
        // 2文字は、4バイト2つまでである。
        var tmp: [8]u8 = undefined;
        const mid = splitAfterFirstChar(t, r);
        const first = t[r.start..mid];
        const second = t[mid..r.end];
        @memcpy(tmp[0..second.len], second);
        @memcpy(tmp[second.len..][0..first.len], first);
        // 同じ長さの入れ替えで、確保は要らず、2文字は正しい UTF-8 で、改行を含まない。
        const edit: Edit = .{
            .pos = r.start,
            .removed_len = r.len(),
            .inserted_len = r.len(),
            .cursor_before = self.cursor,
        };
        @memcpy(self.bytes.items[r.start..r.end], tmp[0..r.len()]);
        self.cursor = r.end;
        return edit;
    }

    // -----------------------------------------------------------------------
    // 範囲(カーソルの隣にあるもの。バッファは変えない)
    // -----------------------------------------------------------------------
    //
    // 削除や切り取りの対象を、操作の前に知るための関数である。範囲が空のときは、その向きに
    // 何も無い(行頭や行末にいる)。移動の関数も、同じ範囲から作る。

    /// The character before the cursor (`Backspace`, `Ctrl-B`).
    pub fn rangeBackwardChar(self: *const Buffer) Range {
        return .{ .start = prevStart(self.bytes.items, self.cursor), .end = self.cursor };
    }

    /// The character at the cursor (`Delete`, `Ctrl-D`, `Ctrl-F`).
    pub fn rangeForwardChar(self: *const Buffer) Range {
        return .{ .start = self.cursor, .end = nextEnd(self.bytes.items, self.cursor) };
    }

    /// From the start of the previous word to the cursor (`Alt-B`, `Alt-Backspace`).
    /// 単語は、ASCII の英数字と、ASCII でない文字の並びである。
    pub fn rangeBackwardWord(self: *const Buffer) Range {
        const t = self.bytes.items;
        var i = self.cursor;
        while (i > 0) {
            const p = prevStart(t, i);
            if (isWordChar(t, p)) break;
            i = p;
        }
        while (i > 0) {
            const p = prevStart(t, i);
            if (!isWordChar(t, p)) break;
            i = p;
        }
        return .{ .start = i, .end = self.cursor };
    }

    /// From the cursor to the end of the next word (`Alt-F`, `Alt-D`).
    pub fn rangeForwardWord(self: *const Buffer) Range {
        const t = self.bytes.items;
        var i = self.cursor;
        while (i < t.len) {
            if (isWordChar(t, i)) break;
            i = nextEnd(t, i);
        }
        while (i < t.len) {
            if (!isWordChar(t, i)) break;
            i = nextEnd(t, i);
        }
        return .{ .start = self.cursor, .end = i };
    }

    /// From the start of the previous run of non-space characters to the cursor (`Ctrl-W`).
    /// 区切りは ASCII の空白、タブ、改行だけである。`Alt-Backspace` の単語より広い。
    pub fn rangeBackwardSpaceWord(self: *const Buffer) Range {
        const t = self.bytes.items;
        var i = self.cursor;
        while (i > 0 and isSpace(t[i - 1])) i -= 1;
        while (i > 0 and !isSpace(t[i - 1])) i -= 1;
        return .{ .start = i, .end = self.cursor };
    }

    /// From the start of the logical line to the cursor (`Ctrl-U`).
    pub fn rangeToStart(self: *const Buffer) Range {
        return .{ .start = self.lineStart(self.cursor), .end = self.cursor };
    }

    /// From the cursor to the end of the logical line (`Ctrl-K`).
    ///
    /// 行末にいて、次の行があるときは、その改行1つの範囲を返す(Emacs と同じ。行が結合する)。
    pub fn rangeToEnd(self: *const Buffer) Range {
        const end = self.lineEnd(self.cursor);
        if (end == self.cursor and end < self.bytes.items.len) return .{ .start = end, .end = end + 1 };
        return .{ .start = self.cursor, .end = end };
    }

    // -----------------------------------------------------------------------
    // 論理行(`\n` で区切られた部分)
    // -----------------------------------------------------------------------

    /// The start of the logical line that contains `pos` (just after the previous `\n`, or 0).
    pub fn lineStart(self: *const Buffer, pos: usize) usize {
        return if (std.mem.lastIndexOfScalar(u8, self.bytes.items[0..pos], '\n')) |i| i + 1 else 0;
    }

    /// The end of the logical line that contains `pos` (the next `\n`, or the end of the text).
    pub fn lineEnd(self: *const Buffer, pos: usize) usize {
        return std.mem.indexOfScalarPos(u8, self.bytes.items, pos, '\n') orelse self.bytes.items.len;
    }

    /// The number of characters between the start of the line and `pos`.
    pub fn column(self: *const Buffer, pos: usize) usize {
        var n: usize = 0;
        var i = self.lineStart(pos);
        while (i < pos) : (i = nextEnd(self.bytes.items, i)) n += 1;
        return n;
    }

    // -----------------------------------------------------------------------
    // 移動(カーソルだけを動かす)
    // -----------------------------------------------------------------------

    pub fn moveBackwardChar(self: *Buffer) void {
        self.cursor = self.rangeBackwardChar().start;
    }

    pub fn moveForwardChar(self: *Buffer) void {
        self.cursor = self.rangeForwardChar().end;
    }

    pub fn moveBackwardWord(self: *Buffer) void {
        self.cursor = self.rangeBackwardWord().start;
    }

    pub fn moveForwardWord(self: *Buffer) void {
        self.cursor = self.rangeForwardWord().end;
    }

    /// Moves to the start of the whole text.
    pub fn moveToStart(self: *Buffer) void {
        self.cursor = 0;
    }

    /// Moves to the end of the whole text.
    pub fn moveToEnd(self: *Buffer) void {
        self.cursor = self.bytes.items.len;
    }

    /// Moves to the start of the logical line (`Ctrl-A`, `Home`).
    pub fn moveToLineStart(self: *Buffer) void {
        self.cursor = self.lineStart(self.cursor);
    }

    /// Moves to the end of the logical line (`Ctrl-E`, `End`).
    pub fn moveToLineEnd(self: *Buffer) void {
        self.cursor = self.lineEnd(self.cursor);
    }

    /// Moves to the previous logical line, to character column `goal` or the end of that line if it
    /// is shorter. Returns false, and does not move, on the first line.
    ///
    /// 呼び出し側が、上下の移動を続けるあいだ `goal` を保つ(短い行を通っても、元の列に戻れる)。
    pub fn moveUpLine(self: *Buffer, goal: usize) bool {
        const start = self.lineStart(self.cursor);
        if (start == 0) return false;
        // 前の行は `start - 1`(`\n`)で終わる。
        self.cursor = self.columnPos(self.lineStart(start - 1), start - 1, goal);
        return true;
    }

    /// Moves to the next logical line; see `moveUpLine`. Returns false on the last line.
    pub fn moveDownLine(self: *Buffer, goal: usize) bool {
        const end = self.lineEnd(self.cursor);
        if (end == self.bytes.items.len) return false;
        self.cursor = self.columnPos(end + 1, self.lineEnd(end + 1), goal);
        return true;
    }

    /// The position `goal` characters after `start`, but not past `end`.
    fn columnPos(self: *const Buffer, start: usize, end: usize, goal: usize) usize {
        var i = start;
        var n: usize = 0;
        while (n < goal and i < end) : (n += 1) i = nextEnd(self.bytes.items, i);
        return i;
    }
};

fn isContinuation(b: u8) bool {
    return b & 0xC0 == 0x80;
}

/// The start of the character that ends at `pos` (0 when `pos` is 0). `pos` is a boundary of valid UTF-8.
fn prevStart(t: []const u8, pos: usize) usize {
    if (pos == 0) return 0;
    var i = pos - 1;
    while (i > 0 and isContinuation(t[i])) i -= 1;
    return i;
}

/// The end of the character that starts at `pos` (`t.len` when `pos` is `t.len`).
fn nextEnd(t: []const u8, pos: usize) usize {
    if (pos >= t.len) return t.len;
    var i = pos + 1;
    while (i < t.len and isContinuation(t[i])) i += 1;
    return i;
}

fn splitAfterFirstChar(t: []const u8, r: Range) usize {
    return nextEnd(t, r.start);
}

/// `Ctrl-W` の区切り: 空白、タブ、改行。改行は空白と同じに数えるので、行頭の `Ctrl-W` は、
/// 直前の改行と、その前の語までを切る。
fn isSpace(b: u8) bool {
    return b == ' ' or b == '\t' or b == '\n';
}

/// ASCII の英数字と、ASCII でない文字を、単語の文字とする。
///
/// Why: 表の引ける Unicode の一般カテゴリ(`src/unicode/props.zig`)を使えば、ASCII でない
/// 句読点を区切りにできる。核は、ASCII でない文字をすべて単語の文字とする仮の実装で
/// 入れる(日本語の文は、区切りなしで1語として動く)。
fn isWordChar(t: []const u8, pos: usize) bool {
    const b = t[pos];
    if (b >= 0x80) return true;
    return std.ascii.isAlphanumeric(b);
}

// ---------------------------------------------------------------------------
// テスト
// ---------------------------------------------------------------------------

const testing = std.testing;

/// `|` の位置にカーソルを置いた、テスト用のバッファを作る。`|` はテキストに入らない。
fn fromMarked(marked: []const u8) !Buffer {
    var b: Buffer = .init(testing.allocator);
    errdefer b.deinit();
    const bar = std.mem.indexOfScalar(u8, marked, '|').?;
    _ = try b.insertSlice(marked[0..bar]);
    _ = try b.insertSlice(marked[bar + 1 ..]);
    try b.setCursor(bar);
    return b;
}

/// バッファを `|` つきの文字列にして、期待と比べる。
fn expectMarked(expected: []const u8, b: *const Buffer) !void {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try out.appendSlice(testing.allocator, b.text()[0..b.cursor]);
    try out.append(testing.allocator, '|');
    try out.appendSlice(testing.allocator, b.text()[b.cursor..]);
    try testing.expectEqualStrings(expected, out.items);
}

fn expectInvariants(b: *const Buffer) !void {
    try testing.expect(std.unicode.utf8ValidateSlice(b.text()));
    try testing.expect(std.mem.indexOfScalar(u8, b.text(), '\r') == null);
    try testing.expect(b.isBoundary(b.cursor));
}

test "insert at the end, in the middle and at the start" {
    var b: Buffer = .init(testing.allocator);
    defer b.deinit();
    const e1 = try b.insertSlice("abc");
    try testing.expectEqualDeep(Edit{ .pos = 0, .removed_len = 0, .inserted_len = 3, .cursor_before = 0 }, e1);
    try expectMarked("abc|", &b);
    b.moveToStart();
    _ = try b.insertCodepoint('X');
    try expectMarked("X|abc", &b);
    b.moveForwardChar();
    const e2 = try b.insertCodepoint(0x3042);
    try testing.expectEqualDeep(Edit{ .pos = 2, .removed_len = 0, .inserted_len = 3, .cursor_before = 2 }, e2);
    try expectMarked("Xaあ|bc", &b);
    try expectInvariants(&b);
}

test "inserting nothing is a no-op edit" {
    var b = try fromMarked("a|b");
    defer b.deinit();
    const e = try b.insertSlice("");
    try testing.expect(e.isNoop());
    try expectMarked("a|b", &b);
}

test "insert rejects invalid UTF-8, bad code points and carriage returns without changing the buffer" {
    var b = try fromMarked("ab|c");
    defer b.deinit();
    try testing.expectError(error.InvalidUtf8, b.insertSlice("\xFF"));
    try testing.expectError(error.InvalidUtf8, b.insertSlice("\xE3\x81")); // 途中で切れた文字
    try testing.expectError(error.InvalidUtf8, b.insertSlice("\xC0\x80")); // 過長
    try testing.expectError(error.InvalidUtf8, b.insertSlice("\xED\xA0\x80")); // サロゲート
    try testing.expectError(error.InvalidUtf8, b.insertCodepoint(0xD800));
    try testing.expectError(error.InvalidUtf8, b.insertCodepoint(0x110000));
    try testing.expectError(error.CarriageReturn, b.insertSlice("x\ry"));
    try testing.expectError(error.CarriageReturn, b.insertSlice("\r"));
    try testing.expectError(error.CarriageReturn, b.insertCodepoint('\r'));
    try expectMarked("ab|c", &b);
    try expectInvariants(&b);
}

test "delete backward and forward through ranges" {
    var b = try fromMarked("aあb|cい");
    defer b.deinit();
    var r = b.rangeBackwardChar();
    try testing.expectEqualStrings("b", b.text()[r.start..r.end]);
    var e = try b.deleteRange(r);
    try testing.expectEqualDeep(Edit{ .pos = 4, .removed_len = 1, .inserted_len = 0, .cursor_before = 5 }, e);
    try expectMarked("aあ|cい", &b);
    r = b.rangeBackwardChar();
    try testing.expectEqualStrings("あ", b.text()[r.start..r.end]);
    _ = try b.deleteRange(r);
    try expectMarked("a|cい", &b);
    r = b.rangeForwardChar();
    try testing.expectEqualStrings("c", b.text()[r.start..r.end]);
    e = try b.deleteRange(r);
    try testing.expectEqualDeep(Edit{ .pos = 1, .removed_len = 1, .inserted_len = 0, .cursor_before = 1 }, e);
    try expectMarked("a|い", &b);
    _ = try b.deleteRange(b.rangeForwardChar());
    try expectMarked("a|", &b);
    try expectInvariants(&b);
}

test "delete at the edges is an empty range" {
    var b = try fromMarked("|ab");
    defer b.deinit();
    try testing.expect(b.rangeBackwardChar().isEmpty());
    try testing.expect(b.rangeBackwardWord().isEmpty());
    try testing.expect(b.rangeBackwardSpaceWord().isEmpty());
    try testing.expect(b.rangeToStart().isEmpty());
    const e = try b.deleteRange(b.rangeBackwardChar());
    try testing.expect(e.isNoop());
    b.moveToEnd();
    try testing.expect(b.rangeForwardChar().isEmpty());
    try testing.expect(b.rangeForwardWord().isEmpty());
    try testing.expect(b.rangeToEnd().isEmpty());
    try expectMarked("ab|", &b);
}

test "an empty buffer: every range is empty and every move stays put" {
    var b: Buffer = .init(testing.allocator);
    defer b.deinit();
    inline for (.{ "rangeBackwardChar", "rangeForwardChar", "rangeBackwardWord", "rangeForwardWord", "rangeBackwardSpaceWord", "rangeToStart", "rangeToEnd" }) |name| {
        try testing.expect(@field(Buffer, name)(&b).isEmpty());
    }
    b.moveBackwardChar();
    b.moveForwardChar();
    b.moveBackwardWord();
    b.moveForwardWord();
    b.moveToStart();
    b.moveToEnd();
    try testing.expectEqual(0, b.cursor);
    try testing.expect(b.transpose() == null);
}

test "character moves step over whole UTF-8 characters" {
    var b = try fromMarked("|aあ😀b");
    defer b.deinit();
    b.moveForwardChar();
    try expectMarked("a|あ😀b", &b);
    b.moveForwardChar();
    try expectMarked("aあ|😀b", &b);
    b.moveForwardChar();
    try expectMarked("aあ😀|b", &b);
    b.moveForwardChar();
    b.moveForwardChar(); // 行末で止まる
    try expectMarked("aあ😀b|", &b);
    b.moveBackwardChar();
    b.moveBackwardChar();
    try expectMarked("aあ|😀b", &b);
    b.moveBackwardChar();
    b.moveBackwardChar();
    b.moveBackwardChar(); // 行頭で止まる
    try expectMarked("|aあ😀b", &b);
}

test "word moves: forward goes to the end of the word, backward to its start" {
    var b = try fromMarked("|  foo-bar  (baz)");
    defer b.deinit();
    b.moveForwardWord();
    try expectMarked("  foo|-bar  (baz)", &b);
    b.moveForwardWord();
    try expectMarked("  foo-bar|  (baz)", &b);
    b.moveForwardWord();
    try expectMarked("  foo-bar  (baz|)", &b);
    b.moveForwardWord(); // 単語が無ければ行末へ
    try expectMarked("  foo-bar  (baz)|", &b);
    b.moveBackwardWord();
    try expectMarked("  foo-bar  (|baz)", &b);
    b.moveBackwardWord();
    try expectMarked("  foo-|bar  (baz)", &b);
    b.moveBackwardWord();
    try expectMarked("  |foo-bar  (baz)", &b);
    b.moveBackwardWord(); // 単語が無ければ行頭へ
    try expectMarked("|  foo-bar  (baz)", &b);
}

test "word moves from the middle of a word" {
    var b = try fromMarked("foo ba|r baz");
    defer b.deinit();
    try testing.expectEqualStrings("ba", b.text()[b.rangeBackwardWord().start..b.rangeBackwardWord().end]);
    try testing.expectEqualStrings("r", b.text()[b.rangeForwardWord().start..b.rangeForwardWord().end]);
}

test "non-ASCII characters belong to words" {
    var b = try fromMarked("|abc あいう def");
    defer b.deinit();
    b.moveForwardWord();
    b.moveForwardWord();
    try expectMarked("abc あいう| def", &b);
    b.moveBackwardWord();
    try expectMarked("abc |あいう def", &b);
}

test "the space word (Ctrl-W) stops only at spaces and tabs" {
    var b = try fromMarked("(define foo-bar|");
    defer b.deinit();
    var r = b.rangeBackwardSpaceWord();
    try testing.expectEqualStrings("foo-bar", b.text()[r.start..r.end]);
    _ = try b.deleteRange(r);
    try expectMarked("(define |", &b);
    r = b.rangeBackwardSpaceWord(); // 末尾の空白を越えて前の語まで
    try testing.expectEqualStrings("(define ", b.text()[r.start..r.end]);
    _ = try b.deleteRange(r);
    try expectMarked("|", &b);
}

test "the space word treats a tab as a separator" {
    var b = try fromMarked("a\tb|");
    defer b.deinit();
    const r = b.rangeBackwardSpaceWord();
    try testing.expectEqualStrings("b", b.text()[r.start..r.end]);
}

test "digits belong to words" {
    var b = try fromMarked("|a1 22 b");
    defer b.deinit();
    b.moveForwardWord();
    try expectMarked("a1| 22 b", &b);
    b.moveForwardWord();
    try expectMarked("a1 22| b", &b);
    b.moveBackwardWord();
    try expectMarked("a1 |22 b", &b);
}

test "the space word skips trailing tabs" {
    var b = try fromMarked("foo\t|");
    defer b.deinit();
    const r = b.rangeBackwardSpaceWord();
    try testing.expectEqualStrings("foo\t", b.text()[r.start..r.end]);
}

test "an underscore separates words" {
    var b = try fromMarked("|foo_bar");
    defer b.deinit();
    b.moveForwardWord();
    try expectMarked("foo|_bar", &b);
}

test "transpose of two 4-byte characters at the end" {
    var b = try fromMarked("😀😁|");
    defer b.deinit();
    const e = b.transpose().?;
    try testing.expectEqual(8, e.removed_len);
    try expectMarked("😁😀|", &b);
}

test "isNoop is false for a deletion and an insertion" {
    var b = try fromMarked("ab|");
    defer b.deinit();
    try testing.expect(!(try b.deleteRange(b.rangeBackwardChar())).isNoop());
    try testing.expect(!(try b.insertSlice("x")).isNoop());
}

test "an empty deletion elsewhere is a no-op edit that still reports the old cursor" {
    var b = try fromMarked("|abc");
    defer b.deinit();
    const e = try b.deleteRange(.{ .start = 2, .end = 2 });
    try testing.expect(e.isNoop());
    try testing.expectEqual(0, e.cursor_before);
    try testing.expectEqual(2, b.cursor);
}

test "inserting a slice of the buffer's own text works, even when it must grow" {
    var b = try fromMarked("abcd|");
    defer b.deinit();
    _ = try b.insertSlice(b.text()[0..4]);
    try expectMarked("abcdabcd|", &b);
    // 容量を超えるまで繰り返しても壊れない。
    for (0..8) |_| _ = try b.insertSlice(b.text());
    try testing.expectEqual(8 * 256, b.text().len);
    try expectInvariants(&b);
}

test "kill ranges to the line start and end" {
    var b = try fromMarked("ab|cd");
    defer b.deinit();
    try testing.expectEqualStrings("ab", b.text()[b.rangeToStart().start..b.rangeToStart().end]);
    try testing.expectEqualStrings("cd", b.text()[b.rangeToEnd().start..b.rangeToEnd().end]);
    _ = try b.deleteRange(b.rangeToEnd());
    try expectMarked("ab|", &b);
    _ = try b.deleteRange(b.rangeToStart());
    try expectMarked("|", &b);
}

test "transpose swaps the characters around the cursor and moves past them" {
    var b = try fromMarked("a|bc");
    defer b.deinit();
    const e = b.transpose().?;
    try testing.expectEqualDeep(Edit{ .pos = 0, .removed_len = 2, .inserted_len = 2, .cursor_before = 1 }, e);
    try expectMarked("ba|c", &b);
    _ = b.transpose();
    try expectMarked("bca|", &b);
    // 行末では、最後の2文字を入れ替え、カーソルは行末のまま。
    _ = b.transpose();
    try expectMarked("bac|", &b);
    try expectInvariants(&b);
}

test "transpose with multi-byte characters keeps UTF-8 valid" {
    var b = try fromMarked("あ|い😀");
    defer b.deinit();
    const e = b.transpose().?;
    try testing.expectEqual(6, e.removed_len);
    try expectMarked("いあ|😀", &b);
    _ = b.transpose();
    try expectMarked("い😀あ|", &b);
    _ = b.transpose();
    try expectMarked("いあ😀|", &b);
    try expectInvariants(&b);
}

test "transpose does nothing at the start or with fewer than two characters" {
    var b = try fromMarked("|ab");
    defer b.deinit();
    try testing.expect(b.transpose() == null);
    try expectMarked("|ab", &b);
    var one = try fromMarked("a|");
    defer one.deinit();
    try testing.expect(one.transpose() == null);
    try expectMarked("a|", &one);
    var one_start = try fromMarked("|a");
    defer one_start.deinit();
    try testing.expect(one_start.transpose() == null);
}

test "an Edit lets a caller build the inverse" {
    var b = try fromMarked("hello |world");
    defer b.deinit();
    // 削除して、取り除かれたテキストを写してから、逆を適用する。
    const r = b.rangeForwardWord();
    const removed = try testing.allocator.dupe(u8, b.text()[r.start..r.end]);
    defer testing.allocator.free(removed);
    const e = try b.deleteRange(r);
    try expectMarked("hello |", &b);
    _ = try b.replaceRange(.{ .start = e.pos, .end = e.pos + e.inserted_len }, removed);
    try b.setCursor(e.cursor_before);
    try expectMarked("hello |world", &b);
    // 挿入の逆は、挿入した範囲の削除である。
    const ins = try b.insertSlice("big ");
    _ = try b.deleteRange(.{ .start = ins.pos, .end = ins.pos + ins.inserted_len });
    try b.setCursor(ins.cursor_before);
    try expectMarked("hello |world", &b);
}

test "replaceRange replaces, and puts the cursor after the new text" {
    var b = try fromMarked("ab|cd");
    defer b.deinit();
    const e = try b.replaceRange(.{ .start = 1, .end = 3 }, "XYZ");
    try testing.expectEqualDeep(Edit{ .pos = 1, .removed_len = 2, .inserted_len = 3, .cursor_before = 2 }, e);
    try expectMarked("aXYZ|d", &b);
}

test "replaceRange and setCursor reject ranges that are out of bounds or inside a character" {
    var b = try fromMarked("あ|い");
    defer b.deinit();
    try testing.expectError(error.InvalidRange, b.replaceRange(.{ .start = 1, .end = 3 }, "x"));
    try testing.expectError(error.InvalidRange, b.replaceRange(.{ .start = 0, .end = 4 }, "x"));
    try testing.expectError(error.InvalidRange, b.replaceRange(.{ .start = 3, .end = 0 }, "x"));
    try testing.expectError(error.InvalidRange, b.deleteRange(.{ .start = 0, .end = 7 }));
    try testing.expectError(error.InvalidRange, b.setCursor(1));
    try testing.expectError(error.InvalidRange, b.setCursor(7));
    try b.setCursor(6);
    try expectMarked("あい|", &b);
    // 失敗しても、バッファは変わらない。
    try testing.expectEqualStrings("あい", b.text());
}

test "a failing allocation leaves the buffer unchanged" {
    var failing: std.testing.FailingAllocator = .init(testing.allocator, .{ .fail_index = 1 });
    var b: Buffer = .init(failing.allocator());
    defer b.deinit();
    _ = try b.insertSlice("abc");
    const big: [4096]u8 = @splat('x');
    try testing.expectError(error.OutOfMemory, b.insertSlice(&big));
    try expectMarked("abc|", &b);
}

test "random edits keep the invariants" {
    var prng: std.Random.DefaultPrng = .init(0xb7);
    const random = prng.random();
    var b: Buffer = .init(testing.allocator);
    defer b.deinit();
    const pieces = [_][]const u8{ "a", "Z", " ", "-", "あ", "é", "😀", "(", "foo", "い う" };
    for (0..3000) |_| {
        switch (random.uintLessThan(u8, 14)) {
            0, 1, 2 => _ = try b.insertSlice(pieces[random.uintLessThan(usize, pieces.len)]),
            3 => b.moveBackwardChar(),
            4 => b.moveForwardChar(),
            5 => b.moveBackwardWord(),
            6 => b.moveForwardWord(),
            7 => b.moveToStart(),
            8 => b.moveToEnd(),
            9 => _ = try b.deleteRange(b.rangeBackwardChar()),
            10 => _ = try b.deleteRange(b.rangeForwardWord()),
            11 => _ = try b.deleteRange(b.rangeBackwardSpaceWord()),
            12 => _ = b.transpose(),
            else => _ = try b.deleteRange(if (random.boolean()) b.rangeToEnd() else b.rangeToStart()),
        }
        try expectInvariants(&b);
        // 範囲は、いつも境界で、カーソルに接している。
        for ([_]Range{ b.rangeBackwardChar(), b.rangeForwardChar(), b.rangeBackwardWord(), b.rangeForwardWord(), b.rangeBackwardSpaceWord() }) |r| {
            try testing.expect(r.start <= r.end and r.end <= b.text().len);
            try testing.expect(b.isBoundary(r.start) and b.isBoundary(r.end));
            try testing.expect(r.start == b.cursor or r.end == b.cursor);
        }
    }
}

test "a newline is an ordinary character: it splits lines and joins them again" {
    var b = try fromMarked("ab|cd");
    defer b.deinit();
    _ = try b.insertSlice("\n");
    try expectMarked("ab\n|cd", &b);
    // 行頭の Backspace は、直前の改行を消して、行を結合する。
    const r = b.rangeBackwardChar();
    try testing.expectEqualStrings("\n", b.text()[r.start..r.end]);
    _ = try b.deleteRange(r);
    try expectMarked("ab|cd", &b);
    // 行末の Delete も、次の行を結合する。
    var c = try fromMarked("ab|\ncd");
    defer c.deinit();
    _ = try c.deleteRange(c.rangeForwardChar());
    try expectMarked("ab|cd", &c);
}

test "line start, end and column are per logical line" {
    // "ab\n" は 0..3、"あいう\n" は 3..13(あ3 い6 う9、改行12)、"xyz" は 13..16。
    var b = try fromMarked("ab\nあいう\n|xyz");
    defer b.deinit();
    try testing.expectEqual(13, b.lineStart(b.cursor));
    try testing.expectEqual(16, b.lineEnd(b.cursor));
    try testing.expectEqual(0, b.column(b.cursor));
    try b.setCursor(9); // 'う' の手前
    try testing.expectEqual(3, b.lineStart(b.cursor));
    try testing.expectEqual(12, b.lineEnd(b.cursor));
    try testing.expectEqual(2, b.column(b.cursor));
    b.moveToLineStart();
    try expectMarked("ab\n|あいう\nxyz", &b);
    b.moveToLineEnd();
    try expectMarked("ab\nあいう|\nxyz", &b);
    // 改行の位置は、直前の行の末尾である。
    try b.setCursor(2);
    try testing.expectEqual(0, b.lineStart(2));
    try testing.expectEqual(2, b.lineEnd(2));
    b.moveToStart();
    b.moveToEnd();
}

test "up and down keep the column, clamp on short lines and report the edges" {
    var b = try fromMarked("abcd\nx\nabcdef|");
    defer b.deinit();
    const goal = b.column(b.cursor);
    try testing.expectEqual(6, goal);
    try testing.expect(b.moveUpLine(goal));
    try expectMarked("abcd\nx|\nabcdef", &b); // 短い行の末尾で止まる
    try testing.expect(b.moveUpLine(goal));
    try expectMarked("abcd|\nx\nabcdef", &b);
    try testing.expect(!b.moveUpLine(goal)); // 先頭の行では動かない
    try expectMarked("abcd|\nx\nabcdef", &b);
    try testing.expect(b.moveDownLine(2));
    try expectMarked("abcd\nx|\nabcdef", &b);
    try testing.expect(b.moveDownLine(2));
    try expectMarked("abcd\nx\nab|cdef", &b);
    try testing.expect(!b.moveDownLine(2));
    try expectMarked("abcd\nx\nab|cdef", &b);
}

test "up and down count characters, not bytes, and land on character boundaries" {
    var b = try fromMarked("あいう\nabcdef|");
    defer b.deinit();
    try testing.expect(b.moveUpLine(6));
    try expectMarked("あいう|\nabcdef", &b);
    try testing.expect(b.moveDownLine(1));
    try expectMarked("あいう\na|bcdef", &b);
    try testing.expect(b.moveUpLine(1));
    try expectMarked("あ|いう\nabcdef", &b);
    try expectInvariants(&b);
}

test "up and down onto an empty line" {
    var b = try fromMarked("ab\n\ncd|");
    defer b.deinit();
    try testing.expect(b.moveUpLine(2));
    try expectMarked("ab\n|\ncd", &b);
    try testing.expect(b.moveUpLine(2));
    try expectMarked("ab|\n\ncd", &b);
    try testing.expect(b.moveDownLine(2));
    try testing.expect(b.moveDownLine(2));
    try expectMarked("ab\n\ncd|", &b);
}

test "kill to the end stops at the line end, and at the line end takes the newline" {
    var b = try fromMarked("a|b\ncd");
    defer b.deinit();
    var r = b.rangeToEnd();
    try testing.expectEqualStrings("b", b.text()[r.start..r.end]);
    _ = try b.deleteRange(r);
    try expectMarked("a|\ncd", &b);
    r = b.rangeToEnd(); // 行末では、改行を取って次の行を結合する
    try testing.expectEqualStrings("\n", b.text()[r.start..r.end]);
    _ = try b.deleteRange(r);
    try expectMarked("a|cd", &b);
    try testing.expect(b.rangeToEnd().len() == 2);
    b.moveToEnd();
    try testing.expect(b.rangeToEnd().isEmpty());
}

test "kill to the start stops at the line start and takes nothing there" {
    var b = try fromMarked("ab\ncd|e");
    defer b.deinit();
    var r = b.rangeToStart();
    try testing.expectEqualStrings("cd", b.text()[r.start..r.end]);
    _ = try b.deleteRange(r);
    try expectMarked("ab\n|e", &b);
    try testing.expect(b.rangeToStart().isEmpty());
    r = b.rangeBackwardChar(); // 改行を消すのは Backspace である
    try testing.expectEqualStrings("\n", b.text()[r.start..r.end]);
}

test "the space word takes a newline as a space" {
    var b = try fromMarked("foo\nbar|");
    defer b.deinit();
    var r = b.rangeBackwardSpaceWord();
    try testing.expectEqualStrings("bar", b.text()[r.start..r.end]);
    _ = try b.deleteRange(r);
    try expectMarked("foo\n|", &b);
    r = b.rangeBackwardSpaceWord();
    try testing.expectEqualStrings("foo\n", b.text()[r.start..r.end]);
}

test "words stop at a newline" {
    var b = try fromMarked("|ab\ncd");
    defer b.deinit();
    b.moveForwardWord();
    try expectMarked("ab|\ncd", &b);
    b.moveForwardWord();
    try expectMarked("ab\ncd|", &b);
    b.moveBackwardWord();
    try expectMarked("ab\n|cd", &b);
}

test "transpose never swaps a newline, and works on the line at the cursor" {
    var b = try fromMarked("ab\n|cd");
    defer b.deinit();
    try testing.expect(b.transpose() == null); // 行頭
    try b.setCursor(2); // 行末(改行の手前)は、その行の最後の2文字
    _ = b.transpose();
    try expectMarked("ba|\ncd", &b);
    var c = try fromMarked("a|\nb");
    defer c.deinit();
    try testing.expect(c.transpose() == null); // 行に文字が1つ
    var d = try fromMarked("ab\nc|");
    defer d.deinit();
    try testing.expect(d.transpose() == null);
    var e = try fromMarked("x\nc|de");
    defer e.deinit();
    _ = e.transpose();
    try expectMarked("x\ndc|e", &e);
}

test "random edits with newlines keep the invariants" {
    var prng: std.Random.DefaultPrng = .init(0x7a);
    const random = prng.random();
    var b: Buffer = .init(testing.allocator);
    defer b.deinit();
    const pieces = [_][]const u8{ "a", "あ", "\n", "\n", " ", "(", "😀", "foo" };
    var goal: usize = 0;
    for (0..3000) |_| {
        switch (random.uintLessThan(u8, 12)) {
            0, 1, 2 => _ = try b.insertSlice(pieces[random.uintLessThan(usize, pieces.len)]),
            3 => _ = b.moveUpLine(goal),
            4 => _ = b.moveDownLine(goal),
            5 => b.moveToLineStart(),
            6 => b.moveToLineEnd(),
            7 => _ = try b.deleteRange(b.rangeBackwardChar()),
            8 => _ = try b.deleteRange(b.rangeToEnd()),
            9 => _ = try b.deleteRange(b.rangeToStart()),
            10 => _ = b.transpose(),
            else => b.moveForwardChar(),
        }
        goal = b.column(b.cursor);
        try expectInvariants(&b);
        const ls = b.lineStart(b.cursor);
        const le = b.lineEnd(b.cursor);
        try testing.expect(ls <= b.cursor and b.cursor <= le);
        try testing.expect(std.mem.indexOfScalar(u8, b.text()[ls..le], '\n') == null);
    }
}

test "down onto an empty last line moves, and down from it does not" {
    var b = try fromMarked("ab|\n");
    defer b.deinit();
    try testing.expect(b.moveDownLine(2));
    try expectMarked("ab\n|", &b);
    try testing.expect(!b.moveDownLine(2));
}
