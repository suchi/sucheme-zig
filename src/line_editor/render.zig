//! Single-line redraw for the line editor.
//!
//! 編集バッファ(テキストとカーソル)、プロンプト、端末の幅から、1行を描くエスケープ
//! シーケンスを作る純粋な関数 `render` を提供する(7g)。入出力にも端末にも触れない。
//! 書き込み先は呼び出し側が渡す `std.Io.Writer` である。
//!
//! 方針(ADR-0049 の決定5):
//! - 毎回、行全体を書き直す。`CR`、プロンプト、テキストの見える窓、`CSI K`(行末まで消去)、
//!   `CR`、`CSI n C`(カーソルを右へ n 桁)の順に出す。前回の描画の内容は要らない。
//! - 折り返さない。プロンプトとテキストが幅に収まらないときは、テキストを横にずらして
//!   表示する。カーソルを上へ戻す操作(`CSI A`)は使わない。複数行と折り返しは 7m が足す。
//! - 描く桁数は `cols - 1` までにして、最後の桁に文字を置かない。最後の桁に書いたあとの
//!   「次の文字で折り返す」状態は、端末ごとに挙動が違うためである。カーソルは最後の桁まで
//!   行ける。
//!
//! 表示:
//! - 文字の幅は `width` 経由でしか求めない。制御文字は `^A` のように2桁の記号で、不正な
//!   UTF-8 と C1 制御文字は U+FFFD(1桁)で描く。端末に生の制御文字を渡さないためである。
//! - プロンプトは、エスケープシーケンスを含まない平文として扱う(色づけは未対応)。
//!   プロンプトが `cols - 1` の半分を超えるときは、末尾の側だけを描く。
//! - 逐次検索中(`View.search`)は、プロンプトの代わりに `(reverse-i-search)`問い合わせ': `
//!   を描く。テキストは、呼び出し側(履歴の部品)が渡す、見つかった履歴の項目である。

const std = @import("std");

/// The state kept between redraws. 窓の先頭を安定させるために使う(横ずらしの量を最小に保つ)。
pub const State = struct {
    /// 前回の窓の先頭(テキストのバイト位置)。
    start: usize = 0,
};

/// An incremental search being shown in place of the prompt.
pub const Search = struct {
    query: []const u8,
    /// 見つからなかったとき `true`。ラベルが `(failed reverse-i-search)` になる。
    failed: bool = false,
};

/// What to draw.
pub const View = struct {
    prompt: []const u8,
    /// 改行を含まない UTF-8(`Buffer.text()`)。
    text: []const u8,
    /// `text` の中のバイト位置。文字の境界でなければならない。
    cursor: usize,
    /// 端末の桁数。
    cols: usize,
    search: ?Search = null,
};

/// Writes the escape sequence that redraws the line, and returns the state for the next call.
pub fn render(w: *std.Io.Writer, view: View, prev: State) std.Io.Writer.Error!State {
    return renderWith(width, w, view, prev);
}

const search_head = "(reverse-i-search)`";
const search_head_failed = "(failed reverse-i-search)`";
const search_tail = "': ";

const Parts = struct {
    items: [3][]const u8,
    n: usize,
};

fn labelParts(view: View) Parts {
    if (view.search) |s| {
        return .{
            .items = .{ if (s.failed) search_head_failed else search_head, s.query, search_tail },
            .n = 3,
        };
    }
    return .{ .items = .{ view.prompt, "", "" }, .n = 1 };
}

const Repr = enum { raw, caret, replacement };

const Glyph = struct {
    len: usize,
    cells: u2,
    repr: Repr,
    /// `caret` のときの、`^` の次の文字。
    ch: u8 = 0,
};

/// `s[i]` から始まる文字の、バイト数と桁数と描き方を返す。`i < s.len` でなければならない。
fn glyphAt(comptime widthFn: fn (u21) u2, s: []const u8, i: usize) Glyph {
    const b = s[i];
    if (b < 0x20 or b == 0x7f) {
        return .{ .len = 1, .cells = 2, .repr = .caret, .ch = if (b == 0x7f) '?' else b + 64 };
    }
    if (b < 0x80) return .{ .len = 1, .cells = widthFn(b), .repr = .raw };
    const bad: Glyph = .{ .len = 1, .cells = 1, .repr = .replacement };
    const n = std.unicode.utf8ByteSequenceLength(b) catch return bad;
    if (i + n > s.len) return bad;
    const cp = std.unicode.utf8Decode(s[i .. i + n]) catch return bad;
    if (cp >= 0x80 and cp <= 0x9f) return .{ .len = n, .cells = 1, .repr = .replacement };
    return .{ .len = n, .cells = widthFn(cp), .repr = .raw };
}

fn emit(w: *std.Io.Writer, s: []const u8, i: usize, g: Glyph) std.Io.Writer.Error!void {
    switch (g.repr) {
        .raw => try w.writeAll(s[i .. i + g.len]),
        .caret => {
            try w.writeByte('^');
            try w.writeByte(g.ch);
        },
        .replacement => try w.writeAll("\u{FFFD}"),
    }
}

/// `i` の1つ前の文字の境界。`i > 0` でなければならない。
fn prevBoundary(s: []const u8, i: usize) usize {
    var j = i - 1;
    while (j > 0 and (s[j] & 0xC0) == 0x80) j -= 1;
    return j;
}

/// `s[a..b]` の表示の桁数。
fn span(comptime widthFn: fn (u21) u2, s: []const u8, a: usize, b: usize) usize {
    var total: usize = 0;
    var i = a;
    while (i < b) {
        const g = glyphAt(widthFn, s, i);
        total += g.cells;
        i += g.len;
    }
    return total;
}

fn partsWidth(comptime widthFn: fn (u21) u2, parts: Parts) usize {
    var total: usize = 0;
    for (parts.items[0..parts.n]) |p| total += span(widthFn, p, 0, p.len);
    return total;
}

/// 幅の関数を差し替えられる本体。テストが、表を引く実装に依らずに、全角と結合文字を試す。
fn renderWith(
    comptime widthFn: fn (u21) u2,
    w: *std.Io.Writer,
    view: View,
    prev: State,
) std.Io.Writer.Error!State {
    std.debug.assert(view.cursor <= view.text.len);
    const text = view.text;

    // 描いてよい桁数。最後の桁には文字を置かない。
    const avail: usize = if (view.cols < 2) 1 else view.cols - 1;

    // プロンプトの見せる範囲。長すぎるときは、先頭の側を捨てる。
    const parts = labelParts(view);
    const full_pw = partsWidth(widthFn, parts);
    const prompt_budget = avail / 2;
    const skip: usize = if (full_pw > prompt_budget) full_pw - prompt_budget else 0;

    try w.writeByte('\r');

    var pw: usize = 0;
    var skipped: usize = 0;
    for (parts.items[0..parts.n]) |p| {
        var i: usize = 0;
        while (i < p.len) {
            const g = glyphAt(widthFn, p, i);
            if (skipped < skip) {
                skipped += g.cells;
            } else {
                try emit(w, p, i, g);
                pw += g.cells;
            }
            i += g.len;
        }
    }

    // テキストの窓。`s` から始め、`tw` 桁に収める。
    const tw = avail - pw;
    var s: usize = @min(prev.start, text.len);
    while (s > 0 and s < text.len and (text[s] & 0xC0) == 0x80) s -= 1;
    s = @min(s, view.cursor);

    const cursor_cells: usize = if (view.cursor < text.len)
        glyphAt(widthFn, text, view.cursor).cells
    else
        0;
    var before = span(widthFn, text, s, view.cursor);
    // カーソルと、その下の文字が窓に入るまで、窓を右へずらす。
    while (s < view.cursor and before + cursor_cells > tw) {
        const g = glyphAt(widthFn, text, s);
        before -= g.cells;
        s += g.len;
    }
    // 末尾までが余裕をもって収まるなら、左の隠れた部分を引き戻す。
    var tail = before + span(widthFn, text, view.cursor, text.len);
    while (s > 0) {
        const p = prevBoundary(text, s);
        const g = glyphAt(widthFn, text, p);
        if (tail + g.cells > tw) break;
        tail += g.cells;
        before += g.cells;
        s = p;
    }

    var used: usize = 0;
    var i = s;
    while (i < text.len) {
        const g = glyphAt(widthFn, text, i);
        if (used + g.cells > tw) break;
        try emit(w, text, i, g);
        used += g.cells;
        i += g.len;
    }

    try w.writeAll("\x1b[K\r");
    const col = pw + before;
    if (col > 0) try w.print("\x1b[{d}C", .{col});
    return .{ .start = s };
}

// Why: 文字幅の仮の実装。符号位置が制御文字なら 0、それ以外は 1 を返す。表(東アジアの
// 全角を2、結合文字を0)は L4 の `src/unicode/` に入ってから引く。7f(`width.zig`)が
// main に入ったら、この定義を消して `@import("width.zig").width` に差し替える(計画書 0021)。
fn width(cp: u21) u2 {
    if (cp < 0x20 or (cp >= 0x7f and cp < 0xa0)) return 0;
    return 1;
}

// ---- テスト ----

const testing = std.testing;

/// テスト用の幅: U+0300 から U+036F は 0、U+3000 から U+9FFF と U+FF00 から U+FF60 は 2、
/// それ以外は 1。
fn testWidth(cp: u21) u2 {
    if (cp >= 0x300 and cp <= 0x36f) return 0;
    if ((cp >= 0x3000 and cp <= 0x9fff) or (cp >= 0xff00 and cp <= 0xff60)) return 2;
    return 1;
}

/// 仮想の画面。シーケンスを適用して、行の内容とカーソルを返す。折り返しは、起きたら
/// `wrapped` を立てる(核の再描画は、折り返さないはずである)。
const Screen = struct {
    cols: usize,
    cells: [256]u21 = @splat(' '),
    /// 直前に描いた文字に重なる結合文字(桁ごとに1つ)。
    marks: [256]u21 = @splat(0),
    last: usize = 0,
    col: usize = 0,
    wrapped: bool = false,

    fn init(cols: usize) Screen {
        return .{ .cols = cols };
    }

    fn apply(self: *Screen, bytes: []const u8) !void {
        var i: usize = 0;
        while (i < bytes.len) {
            const b = bytes[i];
            if (b == '\r') {
                self.col = 0;
                i += 1;
            } else if (b == 0x1b) {
                // CSI の parameter と final だけを解釈する。
                try testing.expect(i + 1 < bytes.len and bytes[i + 1] == '[');
                var j = i + 2;
                var n: usize = 0;
                var has_n = false;
                while (bytes[j] >= '0' and bytes[j] <= '9') : (j += 1) {
                    n = n * 10 + (bytes[j] - '0');
                    has_n = true;
                }
                switch (bytes[j]) {
                    'K' => {
                        var c = self.col;
                        while (c < self.cols) : (c += 1) self.cells[c] = ' ';
                    },
                    'C' => self.col = @min(self.col + (if (has_n and n > 0) n else 1), self.cols - 1),
                    else => return error.UnsupportedSequence,
                }
                i = j + 1;
            } else {
                try testing.expect(b >= 0x20); // 生の制御文字は画面に出さない
                const len = try std.unicode.utf8ByteSequenceLength(b);
                const cp = try std.unicode.utf8Decode(bytes[i .. i + len]);
                i += len;
                const cw = testWidth(cp);
                if (cw == 0) {
                    self.marks[self.last] = cp; // 結合文字は、直前の文字に重なり、桁を進めない。
                    continue;
                }
                if (self.col + cw > self.cols) self.wrapped = true;
                self.cells[self.col] = cp;
                self.marks[self.col] = 0;
                self.last = self.col;
                if (cw == 2) self.cells[self.col + 1] = 0; // 全角の2桁目
                self.col += cw;
            }
        }
    }

    /// 行の内容(末尾の空白を除く)。全角の2桁目は含めない。
    fn line(self: *const Screen, out: *std.ArrayList(u8), gpa: std.mem.Allocator) !void {
        var end: usize = self.cols;
        while (end > 0 and self.cells[end - 1] == ' ') end -= 1;
        for (self.cells[0..end], self.marks[0..end]) |cp, mark| {
            if (cp == 0) continue;
            var buf: [4]u8 = undefined;
            const n = try std.unicode.utf8Encode(cp, &buf);
            try out.appendSlice(gpa, buf[0..n]);
            if (mark != 0) try out.appendSlice(gpa, buf[0..try std.unicode.utf8Encode(mark, &buf)]);
        }
    }
};

/// 1回描いて、画面の行とカーソルの桁を比べる。同じ画面を引き継ぎたいときは `screen` を渡す。
fn expectDraw(
    screen: *Screen,
    view: View,
    prev: State,
    expected_line: []const u8,
    expected_col: usize,
) !State {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    const next = try renderWith(testWidth, &aw.writer, view, prev);
    try screen.apply(aw.written());
    var got: std.ArrayList(u8) = .empty;
    defer got.deinit(testing.allocator);
    try screen.line(&got, testing.allocator);
    // 画面の行は末尾の空白を除いて比べる(消去と空白の区別は、別のテストが見る)。
    try testing.expectEqualStrings(std.mem.trimEnd(u8, expected_line, " "), got.items);
    try testing.expectEqual(expected_col, screen.col);
    try testing.expect(!screen.wrapped);
    return next;
}

fn draw(
    cols: usize,
    prompt: []const u8,
    text: []const u8,
    cursor: usize,
    expected_line: []const u8,
    expected_col: usize,
) !void {
    var screen = Screen.init(cols);
    _ = try expectDraw(&screen, .{ .prompt = prompt, .text = text, .cursor = cursor, .cols = cols }, .{}, expected_line, expected_col);
}

test "empty buffer shows only the prompt" {
    try draw(20, "> ", "", 0, "> ", 2);
}

test "short line fits, cursor at end and in the middle" {
    try draw(20, "> ", "(+ 1 2)", 7, "> (+ 1 2)", 9);
    try draw(20, "> ", "(+ 1 2)", 3, "> (+ 1 2)", 5);
    try draw(20, "> ", "(+ 1 2)", 0, "> (+ 1 2)", 2);
}

test "sequence does not move up or wrap" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    _ = try render(&aw.writer, .{ .prompt = "> ", .text = "abc", .cursor = 3, .cols = 80 }, .{});
    try testing.expectEqualStrings("\r> abc\x1b[K\r\x1b[5C", aw.written());
    // 先頭の桁では、カーソルの移動を出さない。
    aw.clearRetainingCapacity();
    _ = try render(&aw.writer, .{ .prompt = "", .text = "abc", .cursor = 0, .cols = 80 }, .{});
    try testing.expectEqualStrings("\rabc\x1b[K\r", aw.written());
}

test "width boundary: exactly fits, and one more" {
    // cols 10 なので、描ける桁は 9。プロンプト2 + テキスト7 でちょうど収まる。
    try draw(10, "> ", "abcdefg", 7, "> abcdefg", 9);
    // 1文字増えると、左へずらす。カーソルは最後の桁(9)に残る。
    try draw(10, "> ", "abcdefgh", 8, "> bcdefgh", 9);
}

test "cursor in the middle of a long line keeps the cursor character visible" {
    // 窓は先頭から。カーソルが 'f'(位置5)にあり、収まるので、ずらさない。
    try draw(10, "> ", "abcdefghij", 5, "> abcdefg", 7);
    // 'g'(位置6)ではまだ収まる(2+6=8 で、'g' は桁8、窓は桁2から8)。
    try draw(10, "> ", "abcdefghij", 6, "> abcdefg", 8);
    // 'h'(位置7)では、カーソルの文字が窓に入るよう、1つずらす。
    try draw(10, "> ", "abcdefghij", 7, "> bcdefgh", 8);
}

test "window start is kept stable while the cursor moves inside the window" {
    var screen = Screen.init(10);
    const text = "abcdefghij";
    var st: State = .{};
    // 末尾へ行く。
    st = try expectDraw(&screen, .{ .prompt = "> ", .text = text, .cursor = 10, .cols = 10 }, st, "> defghij", 9);
    try testing.expectEqual(@as(usize, 3), st.start);
    // 左へ動いても、窓は動かない(桁だけが動く)。
    st = try expectDraw(&screen, .{ .prompt = "> ", .text = text, .cursor = 9, .cols = 10 }, st, "> defghij", 8);
    try testing.expectEqual(@as(usize, 3), st.start);
    st = try expectDraw(&screen, .{ .prompt = "> ", .text = text, .cursor = 3, .cols = 10 }, st, "> defghij", 2);
    try testing.expectEqual(@as(usize, 3), st.start);
    // 窓の左へ出ると、カーソルの位置まで窓を戻す。
    st = try expectDraw(&screen, .{ .prompt = "> ", .text = text, .cursor = 2, .cols = 10 }, st, "> cdefghi", 2);
    try testing.expectEqual(@as(usize, 2), st.start);
}

test "shrinking text pulls the window back and erases the old tail" {
    var screen = Screen.init(10);
    var st: State = .{};
    st = try expectDraw(&screen, .{ .prompt = "> ", .text = "abcdefghij", .cursor = 10, .cols = 10 }, st, "> defghij", 9);
    // 3文字消すと、全体が収まる。窓は先頭に戻り、右端の古い文字は消える。
    st = try expectDraw(&screen, .{ .prompt = "> ", .text = "abcdefg", .cursor = 7, .cols = 10 }, st, "> abcdefg", 9);
    try testing.expectEqual(@as(usize, 0), st.start);
    st = try expectDraw(&screen, .{ .prompt = "> ", .text = "ab", .cursor = 2, .cols = 10 }, st, "> ab", 4);
}

test "stale or out-of-range previous start is repaired" {
    var screen = Screen.init(10);
    // 前回の位置がテキストより後ろ。
    _ = try expectDraw(&screen, .{ .prompt = "> ", .text = "abc", .cursor = 3, .cols = 10 }, .{ .start = 50 }, "> abc", 5);
    // 前回の位置が全角文字の途中(継続バイト)。
    var s2 = Screen.init(10);
    _ = try expectDraw(&s2, .{ .prompt = "> ", .text = "あいう", .cursor = 9, .cols = 10 }, .{ .start = 1 }, "> あいう", 8);
}

test "wide characters count two columns" {
    try draw(20, "> ", "あい", 6, "> あい", 6);
    try draw(20, "> ", "あい", 3, "> あい", 4);
}

test "wide character straddling the right edge is not drawn half" {
    // 描ける桁は 9。プロンプト2 + 'a' 'b' 'c' 'd'(4) = 6、全角(2)で 8、次の全角は 10 > 9 で切る。
    // カーソルは先頭にあるので、窓は動かない。
    try draw(10, "> ", "abcdあいう", 0, "> abcdあ", 2);
    // 7桁の窓に、全角が1桁だけ余る位置: "abcdef" + 全角。
    try draw(10, "> ", "abcdefあ", 0, "> abcdef", 2);
}

test "cursor on a wide character at the edge shifts the window" {
    // 全角の 'あ'(桁6から7)にカーソルがあり、窓に入るようにずらす。
    // text = "abcdefあ"、カーソルは 'あ'(バイト位置6)。2 + 6 + 2 = 10 > 9 なので、1文字ずらす。
    try draw(10, "> ", "abcdefあ", 6, "> bcdefあ", 7);
}

test "cursor at the end after a wide character" {
    // "abcdefg" + "あ" は 9 桁で、窓(7桁)に収まらない。先頭の2文字を落とす。
    try draw(10, "> ", "abcdefgあ", 10, "> cdefgあ", 9);
}

test "combining characters take no column" {
    // 'e' + U+0301(2バイト)。桁数は 1。
    try draw(20, "> ", "e\u{301}x", 4, "> e\u{301}x", 4);
}

test "long prompt is cut to its tail, text keeps room" {
    // 描ける桁は 9、プロンプトの上限は 4。"abcdefgh> " は 10 桁なので、末尾4桁 "gh> " に切る。
    // テキストは 9 - 4 = 5 桁。
    try draw(10, "abcdefgh> ", "xyz", 3, "gh> xyz", 7);
    try draw(10, "abcdefgh> ", "uvwxyz", 6, "gh> vwxyz", 9);
}

test "prompt exactly at the budget is kept whole" {
    // 描ける桁 9 の半分は 4。プロンプト4桁はそのまま。
    try draw(10, "abc>", "x", 1, "abc>x", 5);
    // 5桁は切る。
    try draw(10, "abcd> ", "x", 1, "cd> x", 5);
}

test "tiny terminal widths do not crash" {
    // 桁数が 2 未満は、描ける桁を 1 として、異常終了しないことだけを確かめる。
    for ([_]usize{ 0, 1 }) |cols| {
        var aw: std.Io.Writer.Allocating = .init(testing.allocator);
        defer aw.deinit();
        _ = try renderWith(testWidth, &aw.writer, .{ .prompt = "> ", .text = "abc", .cursor = 3, .cols = cols }, .{});
    }
    // 描ける桁は 1。プロンプトは全部捨て、テキストに1桁を使う。
    try draw(2, "> ", "abc", 3, "c", 1);
    // 描ける桁は 2、プロンプトの上限は 1。プロンプトは末尾の1桁だけ。
    try draw(3, "> ", "abc", 3, " c", 2);
}

test "control characters and invalid bytes are drawn safely" {
    try draw(20, "> ", "a\tb", 3, "> a^Ib", 6);
    try draw(20, "> ", "a\x7fb", 0, "> a^?b", 2);
    try draw(20, "> ", "a\u{85}b", 0, "> a\u{FFFD}b", 2);
    // プロンプトにも不正な UTF-8 が入りうる。
    try draw(20, "\xff> ", "", 0, "\u{FFFD}> ", 3);
}

test "incremental search replaces the prompt with a label" {
    var screen = Screen.init(80);
    const view: View = .{
        .prompt = "> ",
        .text = "(define x 1)",
        .cursor = 8,
        .cols = 80,
        .search = .{ .query = "def" },
    };
    // ラベルは 25 桁。
    _ = try expectDraw(&screen, view, .{}, "(reverse-i-search)`def': (define x 1)", 25 + 8);
}

test "failed incremental search uses the failed label" {
    var screen = Screen.init(80);
    const view: View = .{
        .prompt = "> ",
        .text = "",
        .cursor = 0,
        .cols = 80,
        .search = .{ .query = "zz", .failed = true },
    };
    _ = try expectDraw(&screen, view, .{}, "(failed reverse-i-search)`zz': ", 31);
}

test "incremental search label is cut to its tail on a narrow terminal" {
    // 描ける桁は 29、ラベルの上限は 14。"(reverse-i-search)`ab': " は 24 桁なので、末尾14桁に切る。
    var screen = Screen.init(30);
    const view: View = .{
        .prompt = "> ",
        .text = "abc",
        .cursor = 3,
        .cols = 30,
        .search = .{ .query = "ab" },
    };
    _ = try expectDraw(&screen, view, .{}, "-search)`ab': abc", 17);
}

test "same text redrawn twice gives the same sequence" {
    var a: std.Io.Writer.Allocating = .init(testing.allocator);
    defer a.deinit();
    var b: std.Io.Writer.Allocating = .init(testing.allocator);
    defer b.deinit();
    const view: View = .{ .prompt = "> ", .text = "abcdefghijkl", .cursor = 12, .cols = 10 };
    const st = try render(&a.writer, view, .{});
    _ = try render(&b.writer, view, st);
    try testing.expectEqualStrings(a.written(), b.written());
}

test "random edits never wrap, never overflow the line, and keep the cursor visible" {
    var prng = std.Random.DefaultPrng.init(0x7a67);
    const rand = prng.random();
    const alphabet = [_][]const u8{ "a", "b", "(", ")", " ", "あ", "い", "e\u{301}", "\t", "\u{85}" };
    var buf: [256]u8 = undefined;
    for (0..2000) |_| {
        const cols = rand.intRangeAtMost(usize, 3, 40);
        var len: usize = 0;
        var offsets: [65]usize = undefined;
        var n: usize = 0;
        const count = rand.intRangeAtMost(usize, 0, 60);
        for (0..count) |_| {
            offsets[n] = len;
            n += 1;
            const piece = alphabet[rand.uintLessThan(usize, alphabet.len)];
            @memcpy(buf[len .. len + piece.len], piece);
            len += piece.len;
        }
        offsets[n] = len;
        const cursor = offsets[rand.uintAtMost(usize, n)];
        const prompt = "> "[0..rand.intRangeAtMost(usize, 0, 2)];
        var screen = Screen.init(cols);
        var aw: std.Io.Writer.Allocating = .init(testing.allocator);
        defer aw.deinit();
        const view: View = .{ .prompt = prompt, .text = buf[0..len], .cursor = cursor, .cols = cols };
        _ = try renderWith(testWidth, &aw.writer, view, .{ .start = rand.uintAtMost(usize, len + 3) });
        try screen.apply(aw.written());
        try testing.expect(!screen.wrapped);
        try testing.expect(screen.col <= cols - 1);
    }
}
