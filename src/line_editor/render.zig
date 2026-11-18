//! Redraw of the edit line for the line editor: several lines, wrapped at the terminal width.
//!
//! 編集バッファ(テキストとカーソル)、プロンプト、端末の幅から、編集中の行全体を描く
//! エスケープシーケンスを作る純粋な関数 `render` を提供する(7g、複数行と折り返しは 7m)。
//! 入出力にも端末にも触れない。書き込み先は呼び出し側が渡す `std.Io.Writer` である。
//!
//! 方針(ADR-0049 の決定5):
//! - 毎回、全体を書き直す。前回の描画の先頭へ戻り(`CSI n A`、`CR`)、画面の下端まで消し
//!   (`CSI J`)、プロンプトとテキストを描き、最後にカーソルを置く。前回の描画で覚えておくのは、
//!   カーソルが先頭の行から何行下にあったか(`State.cursor_row`)だけである。
//! - 端末の自動の折り返しに頼らない。行が端末の幅に達したら、次の文字を描く前に `CR LF` を出す。
//!   最後の桁まで埋めた直後は「次の文字で折り返す」状態(端末ごとに挙動が違う)なので、その状態の
//!   ままでは `CSI J` も消去も使わない(先に消してから描く)。全角の文字が行末に収まらないときは、
//!   その文字を次の行の先頭に置く。
//! - テキストの `\n` は論理行の区切りである。次の論理行は、`View.continuation` のプロンプトで
//!   始める。最後の桁まで埋めた行が `\n` で終わるときは、空の行を足さない(`\n` の `CR LF` が
//!   そのまま次の行へ進める)。カーソルがその行末にあるときだけは、カーソルを置く行が要るので、
//!   1行足す。
//!
//! 表示:
//! - 文字の幅は `width` 経由でしか求めない。制御文字は `^A` のように2桁の記号で、不正な
//!   UTF-8 と C1 制御文字は U+FFFD(1桁)で描く。端末に生の制御文字を渡さないためである。
//! - プロンプトは、エスケープシーケンスを含まない平文として扱う(色づけは未対応)。長いプロンプトも
//!   テキストと同じく折り返す。
//! - 逐次検索中(`View.search`)は、先頭の行のプロンプトの代わりに `(reverse-i-search)`問い合わせ': `
//!   を描く。テキストは、呼び出し側(履歴の部品)が渡す、見つかった履歴の項目である。
//! - 画面が下端にあって描画で上へスクロールしたときは、`CSI n A` が画面の上端で止まる端末に
//!   依らず、行数の数え方が合うよう、移動はいつも描画した行数以内にする。

const std = @import("std");
const width = @import("width.zig").width;

/// The state kept between redraws.
pub const State = struct {
    /// 前回の描画を終えたとき、カーソルが描画の先頭の行から何行下にあったか。
    cursor_row: usize = 0,
};

/// An incremental search being shown in place of the prompt.
pub const Search = struct {
    query: []const u8,
    /// 見つからなかったとき `true`。ラベルが `(failed reverse-i-search)` になる。
    failed: bool = false,
};

/// What to draw.
pub const View = struct {
    /// 先頭の論理行のプロンプト。
    prompt: []const u8,
    /// 2行目以降の論理行のプロンプト。
    continuation: []const u8 = "",
    /// UTF-8。`\n` で論理行に分かれる(`Buffer.text()`)。
    text: []const u8,
    /// `text` の中のバイト位置。文字の境界でなければならない。
    cursor: usize,
    /// 端末の桁数。
    cols: usize,
    search: ?Search = null,
    /// 反転表示する文字の `text` の中のバイト位置(対応する括弧。7e)。文字の先頭でなければ、
    /// 何も強調しない。窓の外にあれば、描かない。
    highlight: ?usize = null,
};

/// Writes the escape sequence that redraws the lines, and returns the state for the next call.
pub fn render(w: *std.Io.Writer, view: View, prev: State) std.Io.Writer.Error!State {
    return renderWith(width, w, view, prev);
}

const search_head = "(reverse-i-search)`";
const search_head_failed = "(failed reverse-i-search)`";
const search_tail = "': ";

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

/// The pen: where the next character goes, and the wrapping.
const Pen = struct {
    w: *std.Io.Writer,
    cols: usize,
    /// 描画の先頭からの行。
    row: usize = 0,
    /// 次の文字を置く桁。`pending` のときは `cols` である。
    col: usize = 0,
    /// 最後の桁まで埋めた。次の文字を置く前に、改行が要る。
    pending: bool = false,

    fn newline(self: *Pen) std.Io.Writer.Error!void {
        try self.w.writeAll("\r\n");
        self.row += 1;
        self.col = 0;
        self.pending = false;
    }

    /// 幅 `cells`(1以上)の文字を置く場所を決める。行末に収まらなければ、次の行へ進む。
    fn reserve(self: *Pen, cells: usize) std.Io.Writer.Error!void {
        if (self.pending or (self.col > 0 and self.col + cells > self.cols)) try self.newline();
    }

    fn advance(self: *Pen, cells: usize) void {
        self.col += cells;
        if (self.col >= self.cols) {
            self.col = self.cols;
            self.pending = true;
        }
    }

    /// 1文字を描く。幅 0 の文字(結合文字)は、桁を進めず、折り返しも起こさない。
    ///
    /// Why: 反転と解除は、1文字を挟むだけで、桁を進めない。折り返しの `CR LF` のあとに入れて、
    /// 前の行の末尾を反転のまま残さない。解除は `27`(反転だけを戻す)にして、ほかの属性に触れない。
    fn put(self: *Pen, s: []const u8, i: usize, g: Glyph, lit: bool) std.Io.Writer.Error!void {
        if (g.cells > 0) try self.reserve(g.cells);
        if (lit) try self.w.writeAll("\x1b[7m");
        try emit(self.w, s, i, g);
        if (lit) try self.w.writeAll("\x1b[27m");
        if (g.cells > 0) self.advance(g.cells);
    }

    /// 平文(プロンプト)を描く。
    fn text(self: *Pen, comptime widthFn: fn (u21) u2, s: []const u8) std.Io.Writer.Error!void {
        var i: usize = 0;
        while (i < s.len) {
            const g = glyphAt(widthFn, s, i);
            try self.put(s, i, g, false);
            i += g.len;
        }
    }
};

/// 幅の関数を差し替えられる本体。テストが、表を引く実装に依らずに、全角と結合文字を試す。
fn renderWith(
    comptime widthFn: fn (u21) u2,
    w: *std.Io.Writer,
    view: View,
    prev: State,
) std.Io.Writer.Error!State {
    std.debug.assert(view.cursor <= view.text.len);
    const text = view.text;
    var pen: Pen = .{ .w = w, .cols = @max(view.cols, 1) };

    // 前回の描画の先頭へ戻って、下端まで消す。最後の桁まで埋めた状態の `CSI J` が、最後の文字を
    // 消さないよう、描く前に消す。
    if (prev.cursor_row > 0) try w.print("\x1b[{d}A", .{prev.cursor_row});
    try w.writeAll("\r\x1b[J");

    if (view.search) |s| {
        try pen.text(widthFn, if (s.failed) search_head_failed else search_head);
        try pen.text(widthFn, s.query);
        try pen.text(widthFn, search_tail);
    } else {
        try pen.text(widthFn, view.prompt);
    }

    var cursor_row: usize = 0;
    var cursor_col: usize = 0;
    var i: usize = 0;
    while (true) {
        if (i == view.cursor) {
            // カーソルは、その位置の文字が置かれる場所(文字が無ければ、行末の次の桁)にある。
            const cells: usize = if (i == text.len or text[i] == '\n') 1 else glyphAt(widthFn, text, i).cells;
            if (cells > 0) {
                try pen.reserve(cells);
                cursor_row = pen.row;
                cursor_col = pen.col;
            } else {
                // 幅 0 の文字(結合文字)の上は、直前の文字のある桁である。
                cursor_row = pen.row;
                cursor_col = @min(pen.col, pen.cols - 1);
            }
        }
        if (i >= text.len) break;
        if (text[i] == '\n') {
            try pen.newline();
            try pen.text(widthFn, view.continuation);
            i += 1;
            continue;
        }
        const g = glyphAt(widthFn, text, i);
        try pen.put(text, i, g, view.highlight == i);
        i += g.len;
    }

    // カーソルを置く。`CR` が「次の文字で折り返す」状態も解く。
    try w.writeByte('\r');
    if (pen.row > cursor_row) try w.print("\x1b[{d}A", .{pen.row - cursor_row});
    if (cursor_col > 0) try w.print("\x1b[{d}C", .{cursor_col});
    return .{ .cursor_row = cursor_row };
}

// ---- テスト ----

const testing = std.testing;

test {
    // 他のファイルを読み込むファイルは、自分の宣言のテストを走らせる(`check-docs` の規則)。
    std.testing.refAllDecls(@This());
}

/// テスト用の幅: U+0300 から U+036F は 0、U+3000 から U+9FFF と U+FF00 から U+FF60 は 2、
/// それ以外は 1。
fn testWidth(cp: u21) u2 {
    if (cp >= 0x300 and cp <= 0x36f) return 0;
    if ((cp >= 0x3000 and cp <= 0x9fff) or (cp >= 0xff00 and cp <= 0xff60)) return 2;
    return 1;
}

const screen_rows = 160;
const screen_cols = 48;

/// 仮想の画面。シーケンスを適用して、各行の内容とカーソルを返す。端末の「最後の桁を埋めたあと、
/// 次の文字で折り返す」状態を、実際の端末と同じに持つ。描画の側が折り返しを済ませていないとき
/// (行に収まらない文字を置いたとき)は、`bad` を立てる。
const Screen = struct {
    cols: usize,
    cells: [screen_rows][screen_cols]u21 = @splat(@splat(' ')),
    /// 直前に描いた文字に重なる結合文字(桁ごとに1つ)。
    marks: [screen_rows][screen_cols]u21 = @splat(@splat(0)),
    row: usize = 0,
    col: usize = 0,
    /// 直前に描いた文字(結合文字が重なる先)。
    last_row: usize = 0,
    last_col: usize = 0,
    pending: bool = false,
    bad: bool = false,
    /// 反転して描かれた桁(`CSI 7 m` から `CSI 27 m` まで)。
    inverse: [screen_rows][screen_cols]bool = @splat(@splat(false)),
    reverse_on: bool = false,
    /// 行頭に、基底の文字を持たない結合文字が置かれたとき。
    orphan: bool = false,

    fn init(cols: usize) Screen {
        return .{ .cols = cols };
    }

    fn apply(self: *Screen, bytes: []const u8) !void {
        var i: usize = 0;
        while (i < bytes.len) {
            const b = bytes[i];
            if (b == '\r') {
                self.col = 0;
                self.pending = false;
                i += 1;
            } else if (b == '\n') {
                self.row += 1;
                self.pending = false;
                try testing.expect(self.row < screen_rows);
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
                const count = if (has_n and n > 0) n else 1;
                switch (bytes[j]) {
                    'J' => {
                        // カーソルから画面の下端まで。
                        var r = self.row;
                        while (r < screen_rows) : (r += 1) {
                            const from = if (r == self.row) self.col else 0;
                            for (from..screen_cols) |c| {
                                self.cells[r][c] = ' ';
                                self.marks[r][c] = 0;
                            }
                        }
                    },
                    'A' => {
                        self.row -|= count;
                        self.pending = false;
                    },
                    'C' => {
                        self.col = @min(self.col + count, self.cols - 1);
                        self.pending = false;
                    },
                    'm' => switch (n) {
                        7 => self.reverse_on = true,
                        27 => self.reverse_on = false,
                        else => return error.UnsupportedSequence,
                    },
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
                    if (self.col == 0 and !self.pending) self.orphan = true;
                    self.marks[self.last_row][self.last_col] = cp; // 結合文字は、直前の文字に重なる。
                    continue;
                }
                if (self.pending) {
                    self.row += 1;
                    self.col = 0;
                    self.pending = false;
                    try testing.expect(self.row < screen_rows);
                }
                // 描画の側が、収まらない文字を先に次の行へ送っているはずである。
                // 幅が桁数より広い(桁数 1 の全角)ときだけは、行の先頭に置く。
                if (self.col + cw > self.cols and self.col > 0) self.bad = true;
                self.cells[self.row][self.col] = cp;
                self.inverse[self.row][self.col] = self.reverse_on;
                self.marks[self.row][self.col] = 0;
                self.last_row = self.row;
                self.last_col = self.col;
                if (cw == 2 and self.col + 1 < screen_cols) self.cells[self.row][self.col + 1] = 0; // 全角の2桁目
                self.col += cw;
                if (self.col >= self.cols) {
                    self.col = self.cols - 1;
                    self.pending = true;
                }
            }
        }
    }

    /// 1行の内容(末尾の空白を除く)。全角の2桁目は含めない。
    fn rowText(self: *const Screen, r: usize, out: *std.ArrayList(u8), gpa: std.mem.Allocator) !void {
        var end: usize = screen_cols;
        while (end > 0 and self.cells[r][end - 1] == ' ') end -= 1;
        for (self.cells[r][0..end], self.marks[r][0..end]) |cp, mark| {
            if (cp == 0) continue;
            var buf: [4]u8 = undefined;
            const n = try std.unicode.utf8Encode(cp, &buf);
            try out.appendSlice(gpa, buf[0..n]);
            if (mark != 0) try out.appendSlice(gpa, buf[0..try std.unicode.utf8Encode(mark, &buf)]);
        }
    }

    /// 内容のある最後の行の次(行数)。
    fn usedRows(self: *const Screen) usize {
        var r: usize = screen_rows;
        while (r > 0) : (r -= 1) {
            for (self.cells[r - 1]) |cp| if (cp != ' ') return r;
        }
        return 0;
    }

    fn expectRows(self: *const Screen, expected: []const []const u8) !void {
        try testing.expectEqual(expected.len, self.usedRows());
        for (expected, 0..) |line, r| {
            var got: std.ArrayList(u8) = .empty;
            defer got.deinit(testing.allocator);
            try self.rowText(r, &got, testing.allocator);
            try testing.expectEqualStrings(std.mem.trimEnd(u8, line, " "), got.items);
        }
    }
};

/// 1回描いて、画面の各行とカーソルの位置を比べる。同じ画面を引き継ぎたいときは `screen` を渡す。
fn expectDraw(
    screen: *Screen,
    view: View,
    prev: State,
    expected_rows: []const []const u8,
    expected_row: usize,
    expected_col: usize,
) !State {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    const next = try renderWith(testWidth, &aw.writer, view, prev);
    try screen.apply(aw.written());
    try screen.expectRows(expected_rows);
    try testing.expectEqual(expected_row, screen.row);
    try testing.expectEqual(expected_col, screen.col);
    try testing.expect(!screen.pending);
    try testing.expectEqual(expected_row, next.cursor_row);
    try testing.expect(!screen.bad);
    try testing.expect(!screen.orphan);
    return next;
}

fn draw(
    cols: usize,
    prompt: []const u8,
    text: []const u8,
    cursor: usize,
    expected_rows: []const []const u8,
    expected_row: usize,
    expected_col: usize,
) !void {
    var screen = Screen.init(cols);
    _ = try expectDraw(&screen, .{ .prompt = prompt, .continuation = "... ", .text = text, .cursor = cursor, .cols = cols }, .{}, expected_rows, expected_row, expected_col);
}

test "empty buffer shows only the prompt" {
    try draw(20, "> ", "", 0, &.{"> "}, 0, 2);
}

test "short line fits, cursor at end and in the middle" {
    try draw(20, "> ", "(+ 1 2)", 7, &.{"> (+ 1 2)"}, 0, 9);
    try draw(20, "> ", "(+ 1 2)", 3, &.{"> (+ 1 2)"}, 0, 5);
    try draw(20, "> ", "(+ 1 2)", 0, &.{"> (+ 1 2)"}, 0, 2);
}

test "the sequence of a first draw: clear, text, then the cursor" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    _ = try render(&aw.writer, .{ .prompt = "> ", .text = "abc", .cursor = 3, .cols = 80 }, .{});
    try testing.expectEqualStrings("\r\x1b[J> abc\r\x1b[5C", aw.written());
    // 先頭の桁では、カーソルの移動を出さない。
    aw.clearRetainingCapacity();
    _ = try render(&aw.writer, .{ .prompt = "", .text = "abc", .cursor = 0, .cols = 80 }, .{});
    try testing.expectEqualStrings("\r\x1b[Jabc\r", aw.written());
}

test "a line longer than the width wraps onto the next row" {
    // cols 10: "> " + "abcdefgh" で 10 桁を埋め、残りは次の行。
    try draw(10, "> ", "abcdefghijkl", 12, &.{ "> abcdefgh", "ijkl" }, 1, 4);
    try draw(10, "> ", "abcdefghijkl", 3, &.{ "> abcdefgh", "ijkl" }, 0, 5);
    try draw(10, "> ", "abcdefghijkl", 8, &.{ "> abcdefgh", "ijkl" }, 1, 0);
}

test "the highlighted character is wrapped in reverse video and takes no column of its own" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    _ = try render(&aw.writer, .{ .prompt = "> ", .text = "(a)", .cursor = 0, .cols = 80, .highlight = 2 }, .{});
    try testing.expectEqualStrings("\r\x1b[J> (a\x1b[7m)\x1b[27m\r\x1b[2C", aw.written());
    // 仮想の画面で、反転した桁を見る。内容と、カーソルの桁は変わらない。
    var screen = Screen.init(20);
    _ = try expectDraw(&screen, .{ .prompt = "> ", .text = "(a (b))", .cursor = 7, .cols = 20, .highlight = 0 }, .{}, &.{"> (a (b))"}, 0, 9);
    for (screen.inverse[0][0..12], 0..) |on, col| try testing.expectEqual(col == 2, on);
}

test "a highlight inside a character is not drawn, and a wide character is reversed whole" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    // 「あ」の2バイト目(継続バイト)は、文字の先頭ではない。
    _ = try render(&aw.writer, .{ .prompt = "> ", .text = "あい", .cursor = 0, .cols = 20, .highlight = 1 }, .{});
    try testing.expect(std.mem.indexOf(u8, aw.written(), "\x1b[7m") == null);
    aw.clearRetainingCapacity();
    _ = try render(&aw.writer, .{ .prompt = "", .text = "あい", .cursor = 0, .cols = 20, .highlight = 3 }, .{});
    try testing.expectEqualStrings("\r\x1b[Jあ\x1b[7mい\x1b[27m\r", aw.written());
}

test "the highlight is drawn on a wrapped row and on a later logical line, after the wrap" {
    // 折り返したあとの行の文字を反転する。反転は、折り返しの `CR LF` の後ろに入る(行頭の桁を汚さない)。
    var screen = Screen.init(10);
    _ = try expectDraw(&screen, .{ .prompt = "> ", .text = "abcdefghijkl", .cursor = 0, .cols = 10, .highlight = 8 }, .{}, &.{ "> abcdefgh", "ijkl" }, 0, 2);
    try testing.expect(screen.inverse[1][0] and !screen.inverse[0][9] and !screen.inverse[1][1]);
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    _ = try render(&aw.writer, .{ .prompt = "> ", .continuation = "... ", .text = "(a\n b)", .cursor = 0, .cols = 80, .highlight = 5 }, .{});
    try testing.expect(std.mem.indexOf(u8, aw.written(), "\r\n...  b\x1b[7m)\x1b[27m") != null);
    // 行をまたいで対応する括弧どうしを、続けて強調できる(1回に1つずつ描く)。
    var screen2 = Screen.init(20);
    _ = try expectDraw(&screen2, .{ .prompt = "> ", .continuation = "... ", .text = "(a\n b)", .cursor = 6, .cols = 20, .highlight = 0 }, .{}, &.{ "> (a", "...  b)" }, 1, 7);
    try testing.expect(screen2.inverse[0][2]);
}

test "a row filled to the last column does not add a row unless the cursor is after it" {
    // ちょうど 10 桁。カーソルが途中なら、行は増えない。
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    _ = try render(&aw.writer, .{ .prompt = "> ", .text = "abcdefgh", .cursor = 3, .cols = 10 }, .{});
    try testing.expect(std.mem.indexOfScalar(u8, aw.written(), '\n') == null);
    try draw(10, "> ", "abcdefgh", 3, &.{"> abcdefgh"}, 0, 5);
    // カーソルが末尾にあるときは、カーソルを置く次の行が出る。
    try draw(10, "> ", "abcdefgh", 8, &.{"> abcdefgh"}, 1, 0);
}

test "a wide character that does not fit at the end of the row goes to the next row whole" {
    // "> " + "abcdefg"(9桁)のあと、全角(2桁)は 11 桁になるので、次の行へ。
    try draw(10, "> ", "abcdefgあい", 6, &.{ "> abcdefg", "あい" }, 0, 8);
    try draw(10, "> ", "abcdefgあい", 7, &.{ "> abcdefg", "あい" }, 1, 0);
    try draw(10, "> ", "abcdefgあい", 10, &.{ "> abcdefg", "あい" }, 1, 2);
    try draw(10, "> ", "abcdefgあい", 13, &.{ "> abcdefg", "あい" }, 1, 4);
}

test "wide characters count two columns" {
    try draw(20, "> ", "あい", 6, &.{"> あい"}, 0, 6);
    try draw(20, "> ", "あい", 3, &.{"> あい"}, 0, 4);
    // 2つ目の全角がちょうど最後の桁までを埋める。
    try draw(6, "> ", "ああ", 3, &.{"> ああ"}, 0, 4);
}

test "combining characters take no column and never start a row" {
    try draw(20, "> ", "e\u{301}x", 4, &.{"> e\u{301}x"}, 0, 4);
    // 基底の文字が最後の桁にあるとき、結合文字は同じ行に残る。
    try draw(5, "> ", "abe\u{301}c", 3, &.{ "> abe\u{301}", "c" }, 0, 4);
    try draw(5, "> ", "abe\u{301}c", 5, &.{ "> abe\u{301}", "c" }, 1, 0);
    try draw(5, "> ", "abe\u{301}c", 6, &.{ "> abe\u{301}", "c" }, 1, 1);
}

test "lines separated by newlines get the continuation prompt" {
    try draw(20, "> ", "(define\n  x)", 0, &.{ "> (define", "...   x)" }, 0, 2);
    try draw(20, "> ", "(define\n  x)", 7, &.{ "> (define", "...   x)" }, 0, 9); // 先頭の行の末尾
    try draw(20, "> ", "(define\n  x)", 8, &.{ "> (define", "...   x)" }, 1, 4);
    try draw(20, "> ", "(define\n  x)", 10, &.{ "> (define", "...   x)" }, 1, 6);
    try draw(20, "> ", "(define\n  x)", 12, &.{ "> (define", "...   x)" }, 1, 8);
}

test "empty logical lines are drawn as the continuation prompt alone" {
    try draw(20, "> ", "a\n\nb", 2, &.{ "> a", "...", "... b" }, 1, 4);
    try draw(20, "> ", "a\n\nb", 3, &.{ "> a", "...", "... b" }, 2, 4);
}

test "a logical line that fills the row exactly is followed by the next one without a blank row" {
    // "> " + 8 = 10 桁で、次の論理行が始まる。
    try draw(10, "> ", "abcdefgh\nx", 10, &.{ "> abcdefgh", "... x" }, 1, 5);
    // カーソルがその行の末尾にあるときは、カーソルの行が1つ要る(空の行が増える)。
    try draw(10, "> ", "abcdefgh\nx", 8, &.{ "> abcdefgh", "", "... x" }, 1, 0);
}

test "the cursor at the end of a line counts one column, not the width of a newline" {
    // "> abcdefg" は 9 桁。行末の位置(改行の上)は 1 桁で、行に収まる。
    try draw(10, "> ", "abcdefg\nx", 7, &.{ "> abcdefg", "... x" }, 0, 9);
}

test "a wrapped logical line and the continuation prompt together" {
    try draw(10, "> ", "ab\ncdefghijklmn", 15, &.{ "> ab", "... cdefgh", "ijklmn" }, 2, 6);
}

test "redrawing a shorter text over a longer one erases the old rows" {
    var screen = Screen.init(10);
    var st: State = .{};
    var v: View = .{ .prompt = "> ", .continuation = "... ", .text = "a\nb\nc", .cursor = 5, .cols = 10 };
    st = try expectDraw(&screen, v, st, &.{ "> a", "... b", "... c" }, 2, 5);
    try testing.expectEqual(@as(usize, 2), st.cursor_row);
    // カーソルが2行目にあるまま、1行に縮める。
    v.text = "a";
    v.cursor = 1;
    st = try expectDraw(&screen, v, st, &.{"> a"}, 0, 3);
    try testing.expectEqual(@as(usize, 0), st.cursor_row);
}

test "redrawing starts from the cursor row, wherever the cursor was left" {
    var screen = Screen.init(10);
    var st: State = .{};
    var v: View = .{ .prompt = "> ", .continuation = "... ", .text = "ab\ncd\nef", .cursor = 3, .cols = 10 };
    // カーソルを途中の行に置いたまま、何度も描き直す。
    for ([_]usize{ 3, 0, 8, 6, 3 }) |c| {
        v.cursor = c;
        st = try expectDraw(&screen, v, st, &.{ "> ab", "... cd", "... ef" }, rowOf(v.text, c), colOf(c));
    }
    // 折り返しが起きる幅に縮めても、前の行を残さない。
    screen = Screen.init(10);
    st = .{};
    v = .{ .prompt = "> ", .continuation = "... ", .text = "abcdefghijklmnopqrstuvwxyz", .cursor = 26, .cols = 10 };
    st = try expectDraw(&screen, v, st, &.{ "> abcdefgh", "ijklmnopqr", "stuvwxyz" }, 2, 8);
    v.text = "abc";
    v.cursor = 3;
    _ = try expectDraw(&screen, v, st, &.{"> abc"}, 0, 5);
}

fn rowOf(text: []const u8, cursor: usize) usize {
    return std.mem.count(u8, text[0..cursor], "\n");
}

fn colOf(cursor: usize) usize {
    // "ab\ncd\nef": 先頭の行は 2、後ろの行は "... " の4桁。
    return switch (cursor) {
        0 => 2,
        3 => 4,
        6 => 4,
        8 => 6,
        else => unreachable,
    };
}

test "the cursor sits where the character at the cursor is drawn" {
    // 全角が行末に収まらず次の行へ送られるとき、カーソルもその行にある。
    try draw(10, "> ", "abcdefgあ", 7, &.{ "> abcdefg", "あ" }, 1, 0);
    try draw(10, "> ", "abcdefgあ", 10, &.{ "> abcdefg", "あ" }, 1, 2);
}

test "incremental search replaces the first prompt with a label" {
    var screen = Screen.init(80);
    const view: View = .{
        .prompt = "> ",
        .continuation = "... ",
        .text = "(define x 1)",
        .cursor = 8,
        .cols = 80,
        .search = .{ .query = "def" },
    };
    // ラベルは 25 桁。
    _ = try expectDraw(&screen, view, .{}, &.{"(reverse-i-search)`def': (define x 1)"}, 0, 25 + 8);
}

test "incremental search shows a multi-line entry, and the match in it" {
    var screen = Screen.init(40);
    const view: View = .{
        .prompt = "> ",
        .continuation = "... ",
        .text = "(define (f)\n  (g))",
        .cursor = 15, // 2行目の "(g" の手前
        .cols = 40,
        .search = .{ .query = "g" },
    };
    _ = try expectDraw(&screen, view, .{}, &.{ "(reverse-i-search)`g': (define (f)", "...   (g))" }, 1, 7);
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
    _ = try expectDraw(&screen, view, .{}, &.{"(failed reverse-i-search)`zz': "}, 0, 31);
}

test "a long prompt wraps like the text" {
    try draw(10, "abcdefgh> ", "xyz", 3, &.{ "abcdefgh> ", "xyz" }, 1, 3);
    // 先頭の行を埋めきったあと、次の文字から次の行になる。
    try draw(10, "abcdefgh> ", "", 0, &.{"abcdefgh> "}, 1, 0);
}

test "tiny terminal widths do not crash" {
    for ([_]usize{ 0, 1, 2 }) |cols| {
        var aw: std.Io.Writer.Allocating = .init(testing.allocator);
        defer aw.deinit();
        _ = try renderWith(testWidth, &aw.writer, .{ .prompt = "> ", .continuation = "... ", .text = "ab\nあc", .cursor = 4, .cols = cols }, .{});
    }
    // 1桁の端末は、1文字ずつ行を替える。
    try draw(1, "", "abc", 3, &.{ "a", "b", "c" }, 3, 0);
    try draw(1, "", "abc", 1, &.{ "a", "b", "c" }, 1, 0);
}

test "control characters and invalid bytes are drawn safely" {
    try draw(20, "> ", "a\tb", 3, &.{"> a^Ib"}, 0, 6);
    try draw(20, "> ", "a\x7fb", 0, &.{"> a^?b"}, 0, 2);
    try draw(20, "> ", "a\u{85}b", 0, &.{"> a\u{FFFD}b"}, 0, 2);
    // プロンプトにも不正な UTF-8 が入りうる。
    try draw(20, "\xff> ", "", 0, &.{"\u{FFFD}> "}, 0, 3);
    try draw(20, "> \xe3\x81", "", 0, &.{"> \u{FFFD}\u{FFFD}"}, 0, 4);
    try draw(20, "\x80> ", "", 0, &.{"\u{FFFD}> "}, 0, 3);
    try draw(20, "\xe3az> ", "", 0, &.{"\u{FFFD}az> "}, 0, 5);
    try draw(20, "> ", "a\x1fb", 0, &.{"> a^_b"}, 0, 2);
}

test "C1 control character at the upper bound is replaced" {
    try draw(20, "> ", "\u{9f}", 0, &.{"> \u{FFFD}"}, 0, 2);
    try draw(20, "> ", "\u{80}", 0, &.{"> \u{FFFD}"}, 0, 2);
    try draw(20, "> ", "\u{a0}", 0, &.{"> \u{a0}"}, 0, 2);
}

test "four-byte characters are stepped over as one" {
    try draw(20, "> ", "\u{1F600}\u{1F600}", 4, &.{"> \u{1F600}\u{1F600}"}, 0, 3);
}

test "same text redrawn twice gives the same sequence" {
    var a: std.Io.Writer.Allocating = .init(testing.allocator);
    defer a.deinit();
    var b: std.Io.Writer.Allocating = .init(testing.allocator);
    defer b.deinit();
    const view: View = .{ .prompt = "> ", .text = "abcdefghijkl", .cursor = 12, .cols = 10 };
    const st = try render(&a.writer, view, .{});
    _ = try render(&b.writer, view, st);
    // 2回目は、前回の描画の先頭へ戻る分だけ違う。
    try testing.expectEqualStrings("\x1b[1A", b.written()[0..4]);
    try testing.expectEqualStrings(a.written(), b.written()[4..]);
}

test "random texts: no overflow, and a redraw over any earlier drawing equals a fresh one" {
    var prng = std.Random.DefaultPrng.init(0x7a67);
    const rand = prng.random();
    const alphabet = [_][]const u8{ "a", "b", "(", ")", " ", "あ", "い", "e\u{301}", "\t", "\u{85}", "\n", "\n" };
    var buf: [512]u8 = undefined;
    var other: [512]u8 = undefined;
    for (0..1500) |_| {
        const cols = rand.intRangeAtMost(usize, 2, 30);
        var views: [2]View = undefined;
        var storage = [2][]u8{ &buf, &other };
        for (&views, 0..) |*v, k| {
            var len: usize = 0;
            var offsets: [81]usize = undefined;
            var n: usize = 0;
            const count = rand.intRangeAtMost(usize, 0, 80);
            for (0..count) |_| {
                offsets[n] = len;
                n += 1;
                const piece = alphabet[rand.uintLessThan(usize, alphabet.len)];
                @memcpy(storage[k][len .. len + piece.len], piece);
                len += piece.len;
            }
            offsets[n] = len;
            v.* = .{
                .prompt = "> "[0..rand.intRangeAtMost(usize, 0, 2)],
                .continuation = "... "[0..rand.intRangeAtMost(usize, 0, 4)],
                .text = storage[k][0..len],
                .cursor = offsets[rand.uintAtMost(usize, n)],
                .cols = cols,
            };
        }
        // 画面 A: 1つ目の次に2つ目を描く。画面 B: 2つ目だけを描く。
        var a = Screen.init(cols);
        var aw: std.Io.Writer.Allocating = .init(testing.allocator);
        defer aw.deinit();
        const st1 = try renderWith(testWidth, &aw.writer, views[0], .{});
        _ = try renderWith(testWidth, &aw.writer, views[1], st1);
        try a.apply(aw.written());
        var b = Screen.init(cols);
        var bw: std.Io.Writer.Allocating = .init(testing.allocator);
        defer bw.deinit();
        _ = try renderWith(testWidth, &bw.writer, views[1], .{});
        try b.apply(bw.written());
        try testing.expect(!a.bad and !b.bad);
        try testing.expectEqual(b.row, a.row);
        try testing.expectEqual(b.col, a.col);
        try testing.expect(a.col < cols);
        try testing.expectEqualDeep(b.cells, a.cells);
        try testing.expectEqualDeep(b.marks, a.marks);
    }
}

test "a text at the REPL's size limit is drawn in one pass per redraw" {
    // 64 KiB は REPL の保留の上限である。1回の描画の費用が、テキストの大きさに比例して、
    // 短い時間で済むことを見る(行の数が多くても、前回の描画の行数に依らない)。
    // Why: `line_editor` のテストの根は `src/tier.zig` を取り込めず、層の分け(`tier.slow()`)が
    // 使えない。1回に数ミリ秒で、層1に置ける大きさである。
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    const text = try testing.allocator.alloc(u8, 64 * 1024);
    defer testing.allocator.free(text);
    for (text, 0..) |*b, i| b.* = if (i % 80 == 79) '\n' else 'x';
    var st: State = .{};
    for (0..4) |_| {
        aw.clearRetainingCapacity();
        st = try render(&aw.writer, .{ .prompt = "> ", .continuation = "... ", .text = text, .cursor = text.len, .cols = 100 }, st);
    }
    try testing.expectEqual(@as(usize, 64 * 1024 / 80), st.cursor_row);
    try testing.expect(aw.written().len < text.len * 3);
}
