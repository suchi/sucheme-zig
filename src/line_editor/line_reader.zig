//! Line reader of the REPL: the plain reader and the editing reader.
//!
//! REPL が1行ずつ読む入口(7j、ADR-0014、ADR-0049)。`LineReader` は2つの形を持つ。
//!
//! - `dumb`: これまでの素朴な読み取り。プロンプトを書き、改行までを読む。Windows と、端末で
//!   ない入力(パイプ、ファイル)はこちらである。
//! - `rich`: 端末の生モードで1バイトずつ読み、Emacs の標準のキー割り当てで1行を編集する。
//!   入力と出力の両方が POSIX の端末のときに使う。
//!
//! 完結判定(`sucheme.isIncomplete`)の呼び出しは、どちらの形でも REPL が持つ。`dumb` は1行を
//! 返し、式が閉じていないときは、REPL が継続行のプロンプトで次の行を読む。
//!
//! `rich` の編集バッファは複数行である(7m)。`Enter` で式が閉じていないときは、バッファに改行を
//! 挿入して編集を続け、確定した前の行にもカーソルで戻れる。閉じたかどうかは、REPL が渡す
//! 判定(`Incomplete`、`LineReader.setIncomplete`)に問い合わせる。判定は REPL が `repl` の保留に
//! 使うのと同じ関数(`sucheme.isIncomplete`)を、同じ形(全体と末尾の改行)で呼ぶ。判定を渡さない
//! ときは、`Enter` はいつも行を確定し、`dumb` と同じく REPL が続きを読む。返す `Result.line` は、
//! 閉じた式の全体で、論理行の間に `\n` を含みうる(末尾の改行は含まない)。REPL は、`dumb` の1行と
//! 同じに保留へ足し、`isIncomplete` を呼ぶ。判定が同じなので、閉じていないと返ることは無い。
//!
//! 生モードは、1行を読む間だけ有効にする。評価の間は元の端末の設定に戻すので、プログラムの
//! 出力と `read` は、これまでどおりの端末で動く。評価中の `Ctrl-C` は、これまでどおり
//! `SIGINT` になり、sucheme を終える(評価だけを止める仕組みは無い)。
//!
//! 単独の `ESC` に時間切れを置かない。`ESC` は、次のキーと組で `Alt` の列として読む
//! (`ESC b` は `Alt-B` と同じ)。Emacs の `ESC` の前置と同じ振る舞いである。
//! Why: 時間切れには、入力を待つ時間を区切る OS の呼び出しが要り、それは 7h の境界
//! (`term_posix.zig`)の外になる。核の割り当てには、単独の `Esc` を使うキーが無い。

const std = @import("std");
const Allocator = std.mem.Allocator;

const keys = @import("keys.zig");
const Key = keys.Key;
const buffer = @import("buffer.zig");
const Buffer = buffer.Buffer;
const kill_ring = @import("kill_ring.zig");
const KillRing = kill_ring.KillRing;
const undo_mod = @import("undo.zig");
const UndoStack = undo_mod.UndoStack;
const history_mod = @import("history.zig");
const History = history_mod.History;
const render = @import("render.zig");
const term_posix = @import("term_posix.zig");

/// What one call of `read` gives.
pub const Result = union(enum) {
    /// 末尾の改行を除いた入力。`rich` では、閉じた式の全体で、論理行の間に `\n` を含みうる。
    /// 次の `read` まで有効である。
    line: []const u8,
    /// 入力の終わり(`dumb` で入力が尽きた、`rich` で空の行の `Ctrl-D`)。
    end,
    /// `Ctrl-C` で、編集中の行が捨てられた。REPL は保留も捨てて、新しいプロンプトに戻る。
    interrupted,
    /// 行が読み取りの上限に収まらず、読み飛ばした(`dumb` だけ)。
    too_long,
};

pub const ReadError = std.Io.Reader.Error || std.Io.Writer.Error || Allocator.Error;

/// The plain reader: writes the prompt and reads up to the newline.
pub const Dumb = struct {
    in: *std.Io.Reader,
    /// 長すぎる行を読み飛ばす途中で入力が尽きた。次の `read` は、プロンプトを書かずに終わる。
    ended: bool = false,

    pub fn read(self: *Dumb, out: *std.Io.Writer, prompt: []const u8) ReadError!Result {
        if (self.ended) return .end;
        try out.writeAll(prompt);
        try out.flush();
        const line = self.in.takeDelimiter('\n') catch |e| switch (e) {
            error.StreamTooLong => {
                // 続きを読んでも、その行の残りは使えない。改行まで捨てる。
                _ = self.in.discardDelimiterInclusive('\n') catch |d| switch (d) {
                    error.EndOfStream => self.ended = true,
                    error.ReadFailed => return error.ReadFailed,
                };
                return .too_long;
            },
            error.ReadFailed => return error.ReadFailed,
        } orelse return .end;
        return .{ .line = line };
    }
};

/// The terminal under the editing reader. 生モードの出入り、1バイトの読み取り、幅を受け持つ。
///
/// 本物の端末(`PosixTerminal`)と、テストの台本の端末の、2つの実装がある。
pub const Terminal = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// 生モードに入る。入れなければ `error.Unavailable` を返し、呼び出し側は `dumb` で読む。
        begin: *const fn (ctx: *anyopaque) error{Unavailable}!void,
        /// 生モードを出る。
        finish: *const fn (ctx: *anyopaque) void,
        /// 1バイトを読む。入力の終わりは null である。
        readByte: *const fn (ctx: *anyopaque) error{ReadFailed}!?u8,
        /// 端末の桁数。
        columns: *const fn (ctx: *anyopaque) usize,
    };

    fn begin(self: Terminal) error{Unavailable}!void {
        return self.vtable.begin(self.ctx);
    }
    fn finish(self: Terminal) void {
        self.vtable.finish(self.ctx);
    }
    fn readByte(self: Terminal) error{ReadFailed}!?u8 {
        return self.vtable.readByte(self.ctx);
    }
    fn columns(self: Terminal) usize {
        return self.vtable.columns(self.ctx);
    }
};

/// The POSIX terminal behind stdin and stdout.
pub const PosixTerminal = struct {
    /// REPL の標準入力の読み手。評価中のプログラムの `read` がここに読み溜めたバイトを、
    /// 端末から読む前に使う(先に打たれた入力を失わないため)。
    in: *std.Io.Reader,
    in_fd: std.posix.fd_t,
    out_fd: std.posix.fd_t,
    raw: ?term_posix.RawMode = null,

    pub fn terminal(self: *PosixTerminal) Terminal {
        return .{ .ctx = self, .vtable = &vtable };
    }

    const vtable: Terminal.VTable = .{
        .begin = beginFn,
        .finish = finishFn,
        .readByte = readByteFn,
        .columns = columnsFn,
    };

    fn beginFn(ctx: *anyopaque) error{Unavailable}!void {
        const self: *PosixTerminal = @ptrCast(@alignCast(ctx));
        self.raw = term_posix.RawMode.enter(self.in_fd) catch return error.Unavailable;
    }

    fn finishFn(ctx: *anyopaque) void {
        const self: *PosixTerminal = @ptrCast(@alignCast(ctx));
        if (self.raw) |*r| r.leave();
        self.raw = null;
    }

    fn readByteFn(ctx: *anyopaque) error{ReadFailed}!?u8 {
        const self: *PosixTerminal = @ptrCast(@alignCast(ctx));
        if (self.in.bufferedLen() > 0) {
            const b = self.in.buffered()[0];
            self.in.toss(1);
            return b;
        }
        const raw = &(self.raw orelse return null);
        // Why: 1バイトずつ読む。`Enter` のあとに続けて届いたバイト(貼り付けた複数の行)を、
        // ここに読み溜めずに端末に残すと、評価中のプログラムの `read` が、その続きを読める。
        var b: [1]u8 = undefined;
        const n = raw.read(&b) catch |e| switch (e) {
            // 端末が切れた。入力の終わりとして扱う(`term_posix.ReadError` の約束)。
            error.InputOutput => return null,
            error.Unexpected => return error.ReadFailed,
        };
        if (n == 0) return null;
        return b[0];
    }

    fn columnsFn(ctx: *anyopaque) usize {
        const self: *PosixTerminal = @ptrCast(@alignCast(ctx));
        return term_posix.columns(self.out_fd) orelse term_posix.default_columns;
    }
};

/// The check the editor asks on `Enter`: is the text typed so far an unfinished expression?
///
/// REPL が `sucheme.isIncomplete` を包んで渡す。`text` は、REPL が保留に持つ形と同じ、編集中の
/// 全体と末尾の改行である。確保などで判定できなかったときは、偽(閉じたとみなす)を返す。
/// そのとき行は確定し、REPL が同じ判定を行って、エラーを出す。
pub const Incomplete = struct {
    ctx: *anyopaque,
    func: *const fn (ctx: *anyopaque, text: []const u8) bool,

    fn isIncomplete(self: Incomplete, text: []const u8) bool {
        return self.func(self.ctx, text);
    }
};

/// The editing state that lives across lines: the history and the kill ring.
pub const Editor = struct {
    gpa: Allocator,
    history: History,
    kill: KillRing,
    buf: Buffer,
    undo: UndoStack,
    /// 1行の間だけの状態。`read` の中で作って捨てる。
    browser: ?history_mod.Browser = null,
    search: ?history_mod.Search = null,
    view: render.State = .{},
    /// `Enter` で、式が閉じたかを問い合わせる。null なら、いつも行を確定する。
    incomplete: ?Incomplete = null,
    /// 2行目以降の論理行のプロンプト。
    continuation_prompt: []const u8 = "... ",
    /// 上下の移動を続けるあいだ保つ列(文字数)。ほかのキーで捨てる。
    goal_col: ?usize = null,

    pub fn init(gpa: Allocator) Editor {
        return .{
            .gpa = gpa,
            .history = .init(gpa, history_mod.default_max_items),
            .kill = .init(gpa, kill_ring.default_max_entries),
            .buf = .init(gpa),
            .undo = .init(gpa, undo_mod.default_max_entries),
        };
    }

    pub fn deinit(self: *Editor) void {
        self.endSearch();
        if (self.browser) |*b| b.deinit();
        self.undo.deinit();
        self.buf.deinit();
        self.kill.deinit();
        self.history.deinit();
        self.* = undefined;
    }

    /// Records one closed expression in the history. 行を改行でつないだ全体を1項目にする。
    pub fn addHistory(self: *Editor, text: []const u8) Allocator.Error!void {
        _ = try self.history.add(text);
    }

    /// Reads one line from `term`, which is already in raw mode, drawing on `out`.
    pub fn read(self: *Editor, term: Terminal, out: *std.Io.Writer, prompt: []const u8) (ReadError || error{ReadFailed})!Result {
        try self.setText("");
        self.kill.breakChain();
        self.view = .{};
        self.goal_col = null;
        self.browser = .init(self.gpa, &self.history);
        defer {
            self.endSearch();
            if (self.browser) |*b| b.deinit();
            self.browser = null;
        }
        // 解読の途中のバイト。`keys.decode` は、`max_csi_len` を超える前に必ず決着する。
        var pending: [keys.max_csi_len]u8 = undefined;
        var n: usize = 0;
        try self.draw(term, out, prompt);
        while (true) {
            const byte = try term.readByte() orelse {
                // 入力が尽きた(端末が切れた)。編集中の行は捨てて終わる。
                return .end;
            };
            pending[n] = byte;
            n += 1;
            while (n > 0) {
                switch (keys.decode(pending[0..n])) {
                    .need_more => break,
                    .invalid => |k| shift(&pending, &n, k),
                    .key => |d| {
                        shift(&pending, &n, d.consumed);
                        switch (try self.handleKey(d.key)) {
                            .none => {},
                            .redraw => try self.draw(term, out, prompt),
                            .accept => {
                                self.buf.moveToEnd();
                                try self.draw(term, out, prompt);
                                try out.writeAll("\n");
                                try out.flush();
                                return .{ .line = self.buf.text() };
                            },
                            .end => return .end,
                            .interrupt => {
                                self.endSearch();
                                self.buf.moveToEnd();
                                try self.draw(term, out, prompt);
                                try out.writeAll("^C\n");
                                try out.flush();
                                return .interrupted;
                            },
                        }
                    },
                }
            }
        }
    }

    const Action = enum { none, redraw, accept, end, interrupt };

    fn shift(pending: *[keys.max_csi_len]u8, n: *usize, k: usize) void {
        std.mem.copyForwards(u8, pending[0 .. n.* - k], pending[k..n.*]);
        n.* -= k;
    }

    fn draw(self: *Editor, term: Terminal, out: *std.Io.Writer, prompt: []const u8) std.Io.Writer.Error!void {
        var v: render.View = .{
            .prompt = prompt,
            .continuation = self.continuation_prompt,
            .text = self.buf.text(),
            .cursor = self.buf.cursor,
            .cols = term.columns(),
        };
        if (self.search) |*s| {
            const query = s.text();
            if (s.current()) |entry| {
                v.text = entry;
                v.cursor = s.matchOffset() orelse 0;
            }
            v.search = .{ .query = query, .failed = query.len > 0 and s.current() == null };
        }
        self.view = try render.render(out, v, self.view);
        try out.flush();
    }

    fn handleKey(self: *Editor, key: Key) Allocator.Error!Action {
        const vertical = switch (key) {
            .arrow => |a| a == .up or a == .down,
            .ctrl => |c| c == 0x0E or c == 0x10,
            else => false,
        };
        if (!vertical) self.goal_col = null;
        if (self.search != null) {
            if (try self.handleSearchKey(key)) |action| return action;
        }
        switch (key) {
            .insert => |cp| {
                var tmp: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(cp, &tmp) catch return .none;
                try check(self.undo.insertTyped(&self.buf, tmp[0..len]));
                self.kill.breakChain();
            },
            .ctrl => |c| return self.handleCtrl(c),
            .alt => |c| return self.handleAlt(c),
            .arrow => |a| switch (a) {
                .left => self.move(Buffer.moveBackwardChar),
                .right => self.move(Buffer.moveForwardChar),
                .up => try self.moveVertical(.up),
                .down => try self.moveVertical(.down),
            },
            .home => self.move(Buffer.moveToLineStart),
            .end => self.move(Buffer.moveToLineEnd),
            .delete => try self.deleteRange(self.buf.rangeForwardChar()),
            // 括弧つき貼り付けは有効にしていない。割り当ての無い列は無視する。
            .paste_begin, .paste_end, .unknown => return .none,
        }
        return .redraw;
    }

    fn handleCtrl(self: *Editor, c: u8) Allocator.Error!Action {
        switch (c) {
            0x01 => self.move(Buffer.moveToLineStart), // Ctrl-A
            0x02 => self.move(Buffer.moveBackwardChar), // Ctrl-B
            0x03 => return .interrupt, // Ctrl-C
            0x04 => { // Ctrl-D
                if (self.buf.text().len == 0) return .end;
                try self.deleteRange(self.buf.rangeForwardChar());
            },
            0x05 => self.move(Buffer.moveToLineEnd), // Ctrl-E
            0x06 => self.move(Buffer.moveForwardChar), // Ctrl-F
            0x08, 0x7F => try self.deleteRange(self.buf.rangeBackwardChar()), // Backspace
            0x0A, 0x0D => return self.enter(), // Enter
            0x0B => try check(self.kill.killToEnd(&self.buf, &self.undo)), // Ctrl-K
            0x0E => try self.moveVertical(.down), // Ctrl-N
            0x10 => try self.moveVertical(.up), // Ctrl-P
            0x12 => { // Ctrl-R
                self.breakChains();
                self.search = .init(self.gpa, &self.history);
            },
            0x14 => { // Ctrl-T
                _ = try self.undo.transpose(&self.buf);
                self.kill.breakChain();
            },
            0x15 => try check(self.kill.killToStart(&self.buf, &self.undo)), // Ctrl-U
            0x17 => try check(self.kill.killBackwardSpaceWord(&self.buf, &self.undo)), // Ctrl-W
            0x19 => try check(self.kill.yank(&self.buf, &self.undo)), // Ctrl-Y
            0x1F => { // Ctrl-_
                _ = self.undo.undo(&self.buf) catch |e| switch (e) {
                    error.OutOfMemory => return error.OutOfMemory,
                    // 記録が合わなくなった。`undo` が記録を捨てたので、続けられる。
                    error.InvalidRange => {},
                };
                self.kill.breakChain();
            },
            // Tab は、補完(7k)までは文字として入れる。貼り付けたコードの字下げを残すため。
            0x09 => {
                try check(self.undo.insertTyped(&self.buf, "\t"));
                self.kill.breakChain();
            },
            else => return .none,
        }
        return .redraw;
    }

    fn handleAlt(self: *Editor, c: u21) Allocator.Error!Action {
        switch (c) {
            'b' => self.move(Buffer.moveBackwardWord),
            'f' => self.move(Buffer.moveForwardWord),
            'd' => try check(self.kill.killForwardWord(&self.buf, &self.undo)),
            'y' => try check(self.kill.yankPop(&self.buf, &self.undo)),
            0x7F, 0x08 => try check(self.kill.kill(&self.buf, self.buf.rangeBackwardWord(), .backward, &self.undo)), // Alt-Backspace
            // `ESC` のあとの制御キー(`Enter`、`Ctrl-C` など)は、そのキーとして効かせる。
            // Why: `ESC` に時間切れが無いので、`Esc` を押したあとの次のキーが消えないようにする。
            0...0x07, 0x09...0x1A, 0x1C...0x1F => return self.handleCtrl(@intCast(c)),
            else => return .none,
        }
        return .redraw;
    }

    /// 逐次検索の間のキー。検索を続けるなら、その動作を返す。検索を終えて、キーを通常の
    /// 割り当てで処理させるなら null を返す。
    fn handleSearchKey(self: *Editor, key: Key) Allocator.Error!?Action {
        const s = &self.search.?;
        switch (key) {
            .insert => |cp| {
                var tmp: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(cp, &tmp) catch return .none;
                try s.append(tmp[0..len]);
                return .redraw;
            },
            .ctrl => |c| switch (c) {
                0x12 => {
                    s.olderMatch();
                    return .redraw;
                },
                0x08, 0x7F => {
                    s.backspace();
                    return .redraw;
                },
                0x07 => { // Ctrl-G: 検索をやめ、元の行に戻る。
                    self.endSearch();
                    return .redraw;
                },
                0x03 => return .interrupt,
                else => {},
            },
            else => {},
        }
        // それ以外のキーは、見つかった項目を行に入れて検索を終え、通常の割り当てで処理する。
        if (s.current()) |entry| {
            const at = s.matchOffset() orelse 0;
            try self.setText(entry);
            self.buf.setCursor(at) catch {};
        }
        self.endSearch();
        return null;
    }

    fn endSearch(self: *Editor) void {
        if (self.search) |*s| s.deinit();
        self.search = null;
    }

    /// `Enter`: 式が閉じていれば行を確定し、閉じていなければ、カーソルの位置に改行を入れて続ける。
    fn enter(self: *Editor) Allocator.Error!Action {
        const hook = self.incomplete orelse return .accept;
        const text = self.buf.text();
        // REPL が保留に持つ形(全体と末尾の改行)で問い合わせる。
        const whole = try self.gpa.alloc(u8, text.len + 1);
        defer self.gpa.free(whole);
        @memcpy(whole[0..text.len], text);
        whole[text.len] = '\n';
        if (!hook.isIncomplete(whole)) return .accept;
        try check(self.undo.insertSlice(&self.buf, "\n"));
        self.kill.breakChain();
        return .redraw;
    }

    const Direction = enum { up, down };

    /// 上下の矢印と `Ctrl-P` `Ctrl-N`: 論理行をまたいで動く。先頭の行の上、最後の行の下では、
    /// 履歴を呼び出す(呼び出した複数行の項目の中も、行をまたいで動ける)。
    fn moveVertical(self: *Editor, dir: Direction) Allocator.Error!void {
        const goal = self.goal_col orelse self.buf.column(self.buf.cursor);
        const moved = switch (dir) {
            .up => self.buf.moveUpLine(goal),
            .down => self.buf.moveDownLine(goal),
        };
        if (moved) {
            self.goal_col = goal;
            self.breakChains();
            return;
        }
        self.goal_col = null;
        switch (dir) {
            .up => try self.recallOlder(),
            .down => try self.recallNewer(),
        }
    }

    fn recallOlder(self: *Editor) Allocator.Error!void {
        const b = &(self.browser orelse return);
        if (try b.older(self.buf.text())) |entry| try self.setText(entry);
        self.breakChains();
    }

    fn recallNewer(self: *Editor) Allocator.Error!void {
        const b = &(self.browser orelse return);
        if (b.newer()) |entry| try self.setText(entry);
        self.breakChains();
    }

    /// 行を置き換える(履歴の呼び出し)。取り消しの記録は捨てる。
    fn setText(self: *Editor, s: []const u8) Allocator.Error!void {
        self.undo.clear();
        _ = self.buf.replaceRange(.{ .start = 0, .end = self.buf.text().len }, s) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            // 履歴の項目は、呼び出せるもの(`\r` を含まない)だけが来る。来たら行を変えない。
            error.InvalidUtf8, error.CarriageReturn, error.InvalidRange => {},
        };
    }

    fn move(self: *Editor, f: *const fn (*Buffer) void) void {
        f(&self.buf);
        self.breakChains();
    }

    fn deleteRange(self: *Editor, range: buffer.Range) Allocator.Error!void {
        if (!range.isEmpty()) try check(self.undo.deleteRange(&self.buf, range));
        self.kill.breakChain();
    }

    /// 2つの部品(キルリングと取り消し)を通らない操作のあとに、両方の連なりを切る。
    fn breakChains(self: *Editor) void {
        self.kill.breakChain();
        self.undo.breakGroup();
    }
};

/// 部品の編集の失敗のうち、確保の失敗だけを伝える。
///
/// Why: ほかの失敗(不正な UTF-8、改行、範囲の外)は、入力が解読済みの1文字で、範囲が部品の
/// 返した境界なので起きない。起きたときは、部品がバッファを変えない約束なので、無視して続ける。
fn check(result: anytype) Allocator.Error!void {
    _ = result catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {},
    };
}

/// Whether the last byte written to the terminal ended a line.
///
/// Why: 再描画は行頭(`CR`)から描き直すので、改行で終わらない出力(`(display "a")`)のあとに
/// そのまま描くと、その出力を上書きして消す。`rich` は、端末への書き込み(stdout と stderr)を
/// `LineTracker` に通して、行の途中で終わっていたら、改行を足してからプロンプトを描く。
pub const LineStart = struct {
    at_start: bool = true,
};

/// A writer that passes bytes to `inner` and records in `state` whether the last one was `\n`.
///
/// 自分の緩衝は持たない(書いた順に `inner` へ渡すので、最後のバイトが正しく決まる)。
/// `flush` は `inner` を書き出す。`interface` は動かさずに使う(`@fieldParentPtr` で戻るため)。
pub const LineTracker = struct {
    inner: *std.Io.Writer,
    state: *LineStart,
    interface: std.Io.Writer,

    pub fn init(inner: *std.Io.Writer, state: *LineStart) LineTracker {
        return .{ .inner = inner, .state = state, .interface = .{ .buffer = &.{}, .vtable = &vtable } };
    }

    const vtable: std.Io.Writer.VTable = .{ .drain = drain, .flush = flush };

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *LineTracker = @fieldParentPtr("interface", w);
        var n: usize = 0;
        for (data[0 .. data.len - 1]) |d| {
            try self.inner.writeAll(d);
            self.note(d);
            n += d.len;
        }
        const last = data[data.len - 1];
        for (0..splat) |_| {
            try self.inner.writeAll(last);
            self.note(last);
            n += last.len;
        }
        return n;
    }

    fn flush(w: *std.Io.Writer) std.Io.Writer.Error!void {
        const self: *LineTracker = @fieldParentPtr("interface", w);
        try self.inner.flush();
    }

    fn note(self: *LineTracker, d: []const u8) void {
        if (d.len > 0) self.state.at_start = d[d.len - 1] == '\n';
    }
};

/// The editing reader: the editor, the terminal, and the plain reader to fall back on.
pub const Rich = struct {
    editor: Editor,
    terminal: Terminal,
    /// 生モードに入れなかったときに使う。
    fallback: Dumb,
    /// 端末への書き込みが行の途中で終わっているか。null なら調べない(改行を足さない)。
    line_start: ?*const LineStart = null,

    pub fn read(self: *Rich, out: *std.Io.Writer, prompt: []const u8) ReadError!Result {
        self.terminal.begin() catch return self.fallback.read(out, prompt);
        defer self.terminal.finish();
        if (self.line_start) |ls| {
            if (!ls.at_start) try out.writeAll("\n");
        }
        return self.editor.read(self.terminal, out, prompt);
    }
};

/// The reader the REPL uses: `dumb` or `rich`.
pub const LineReader = union(enum) {
    dumb: Dumb,
    rich: Rich,

    pub fn deinit(self: *LineReader) void {
        switch (self.*) {
            .dumb => {},
            .rich => |*r| r.editor.deinit(),
        }
    }

    /// Reads one line after writing `prompt`.
    pub fn read(self: *LineReader, out: *std.Io.Writer, prompt: []const u8) ReadError!Result {
        return switch (self.*) {
            .dumb => |*d| d.read(out, prompt),
            .rich => |*r| r.read(out, prompt),
        };
    }

    /// Sets the check `rich` asks on `Enter` (see `Incomplete`). `dumb` has no use for it.
    pub fn setIncomplete(self: *LineReader, hook: Incomplete) void {
        switch (self.*) {
            .dumb => {},
            .rich => |*r| r.editor.incomplete = hook,
        }
    }

    /// Sets the prompt of the second and later lines of an expression that `rich` edits.
    pub fn setContinuationPrompt(self: *LineReader, prompt: []const u8) void {
        switch (self.*) {
            .dumb => {},
            .rich => |*r| r.editor.continuation_prompt = prompt,
        }
    }

    /// Records a closed expression in the history. `dumb` keeps none.
    pub fn addHistory(self: *LineReader, text: []const u8) Allocator.Error!void {
        switch (self.*) {
            .dumb => {},
            .rich => |*r| try r.editor.addHistory(text),
        }
    }
};

// ---- tests ----

const testing = std.testing;

/// A scripted terminal for the tests.
///
/// 打つバイト列を先頭から1つずつ返し、幅は固定である。`src/main.zig` の REPL のテストも使う。
pub const Script = struct {
    bytes: []const u8,
    pos: usize = 0,
    cols: usize = 80,
    began: usize = 0,
    finished: usize = 0,
    refuse: bool = false,

    pub fn terminal(self: *Script) Terminal {
        return .{ .ctx = self, .vtable = &vtable };
    }

    const vtable: Terminal.VTable = .{
        .begin = beginFn,
        .finish = finishFn,
        .readByte = readByteFn,
        .columns = columnsFn,
    };

    fn beginFn(ctx: *anyopaque) error{Unavailable}!void {
        const self: *Script = @ptrCast(@alignCast(ctx));
        if (self.refuse) return error.Unavailable;
        self.began += 1;
    }
    fn finishFn(ctx: *anyopaque) void {
        const self: *Script = @ptrCast(@alignCast(ctx));
        self.finished += 1;
    }
    fn readByteFn(ctx: *anyopaque) error{ReadFailed}!?u8 {
        const self: *Script = @ptrCast(@alignCast(ctx));
        if (self.pos >= self.bytes.len) return null;
        defer self.pos += 1;
        return self.bytes[self.pos];
    }
    fn columnsFn(ctx: *anyopaque) usize {
        const self: *Script = @ptrCast(@alignCast(ctx));
        return self.cols;
    }
};

/// 台本を打ち、返った結果を集める。`.line` の中身は複製して返す。
const Run = struct {
    results: std.ArrayList(Outcome) = .empty,
    out: std.Io.Writer.Allocating,

    const Outcome = union(enum) { line: []u8, end, interrupted, too_long };

    fn deinit(self: *Run) void {
        for (self.results.items) |r| switch (r) {
            .line => |l| testing.allocator.free(l),
            else => {},
        };
        self.results.deinit(testing.allocator);
        self.out.deinit();
    }

    fn line(self: *const Run, i: usize) []const u8 {
        return switch (self.results.items[i]) {
            .line => |l| l,
            else => "<not a line>",
        };
    }
};

/// 台本が尽きるまで(または `max` 回)読む。各行の閉じた全体を履歴に記録する。
fn runScript(editor: *Editor, bytes: []const u8, max: usize) !Run {
    var script: Script = .{ .bytes = bytes };
    var run: Run = .{ .out = .init(testing.allocator) };
    errdefer run.deinit();
    var i: usize = 0;
    while (i < max) : (i += 1) {
        const r = try editor.read(script.terminal(), &run.out.writer, "> ");
        switch (r) {
            .line => |l| {
                try editor.addHistory(l);
                try run.results.append(testing.allocator, .{ .line = try testing.allocator.dupe(u8, l) });
            },
            .end => {
                try run.results.append(testing.allocator, .end);
                break;
            },
            .interrupted => try run.results.append(testing.allocator, .interrupted),
            .too_long => try run.results.append(testing.allocator, .too_long),
        }
    }
    return run;
}

fn expectLines(bytes: []const u8, expected: []const []const u8) !void {
    var editor: Editor = .init(testing.allocator);
    defer editor.deinit();
    var run = try runScript(&editor, bytes, expected.len);
    defer run.deinit();
    try testing.expectEqual(expected.len, run.results.items.len);
    for (expected, 0..) |e, i| try testing.expectEqualStrings(e, run.line(i));
}

test "typed characters make the line, and Enter as CR or LF ends it" {
    try expectLines("abc\r(+ 1 2)\n", &.{ "abc", "(+ 1 2)" });
}

test "the line accepts UTF-8 characters" {
    try expectLines("λx\r", &.{"λx"});
}

test "Ctrl-A, Ctrl-E, Ctrl-B and Ctrl-F move the cursor" {
    // abc で Ctrl-A して x、Ctrl-E して y、Ctrl-B して z、Ctrl-A Ctrl-F して w。
    try expectLines("abc\x01x\x05y\x02z\x01\x06w\r", &.{"xwabczy"});
}

test "arrows, Home and End move the cursor" {
    try expectLines("abc\x1b[D\x1b[Dx\x1b[Hy\x1b[Fz\x1b[C\x1bOHw\r", &.{"wyaxbcz"});
}

test "Backspace and Delete remove a character, and do nothing at the edge" {
    // Backspace は 0x7F と 0x08 の両方。行頭の Backspace と行末の Delete は何もしない。
    try expectLines("abcd\x7f\x08\x01\x7f\x1b[3~\r", &.{"b"});
}

test "Ctrl-D deletes the character at the cursor on a line with text" {
    try expectLines("abc\x01\x04\r", &.{"bc"});
}

test "Ctrl-D on an empty line ends the input, and at the end of a line with text does nothing" {
    var editor: Editor = .init(testing.allocator);
    defer editor.deinit();
    // Ctrl-D のあとにも打鍵を残す。台本の終わりで止まったのと区別するため。
    var run = try runScript(&editor, "ab\x04\r\x04x\r", 5);
    defer run.deinit();
    try testing.expectEqual(@as(usize, 2), run.results.items.len);
    try testing.expectEqualStrings("ab", run.line(0));
    try testing.expect(run.results.items[1] == .end);
}

test "Ctrl-C drops the line and reports the interrupt, and the next line starts empty" {
    var editor: Editor = .init(testing.allocator);
    defer editor.deinit();
    var run = try runScript(&editor, "abc\x03x\r", 5);
    defer run.deinit();
    try testing.expect(run.results.items[0] == .interrupted);
    try testing.expectEqualStrings("x", run.line(1));
    try testing.expect(std.mem.indexOf(u8, run.out.written(), "^C\n") != null);
}

test "the end of input in the middle of a line ends the input" {
    var editor: Editor = .init(testing.allocator);
    defer editor.deinit();
    var run = try runScript(&editor, "abc", 5);
    defer run.deinit();
    try testing.expectEqual(@as(usize, 1), run.results.items.len);
    try testing.expect(run.results.items[0] == .end);
}

test "Ctrl-K and Ctrl-Y cut to the end and paste it back" {
    try expectLines("abcd\x01\x06\x0b\x01\x19\r", &.{"bcda"});
}

test "Ctrl-U cuts to the start, Ctrl-W cuts the word before the cursor" {
    try expectLines("ab cd\x17\x19\x19\r", &.{"ab cdcd"});
    try expectLines("ab cd\x02\x15\x05\x19\r", &.{"dab c"});
}

test "consecutive kills join in one entry, and a move between them splits it" {
    // Ctrl-W を2回続けると、"ab cd" 全体が1項目になる。
    try expectLines("ab cd\x17\x17\x19\r", &.{"ab cd"});
    // 間に移動(Ctrl-E)が入ると、2項目になり、Ctrl-Y は最後の "ab " だけを貼る。
    try expectLines("ab cd\x17\x05\x17\x19\r", &.{"ab "});
}

test "a typed character between kills splits them" {
    try expectLines("ab cd\x17x\x7f\x17\x19\r", &.{"ab "});
}

test "Alt-Y after Ctrl-Y replaces the paste with the older entry" {
    try expectLines("one\x15two\x15\x19\x1by\r", &.{"one"});
}

test "Ctrl-T swaps the characters around the cursor" {
    try expectLines("abc\x02\x14\r", &.{"acb"});
}

test "Alt-B, Alt-F, Alt-D and Alt-Backspace work on words, and ESC then a key is the same as Alt" {
    try expectLines("foo bar\x1bbx\r", &.{"foo xbar"});
    try expectLines("foo bar\x01\x1bfx\r", &.{"foox bar"});
    try expectLines("foo bar\x01\x1bd\r", &.{" bar"});
    try expectLines("foo bar\x1b\x7f\r", &.{"foo "});
}

test "Ctrl-_ undoes typing as one group, and a move closes the group" {
    try expectLines("abc\x1f\r", &.{""});
    try expectLines("ab\x02\x06c\x1f\r", &.{"ab"});
}

test "Ctrl-_ undoes a kill" {
    try expectLines("abc\x15\x1f\r", &.{"abc"});
}

test "Tab goes into the line as a character" {
    try expectLines("a\tb\r", &.{"a\tb"});
}

test "keys with no binding and invalid bytes leave the line as it is" {
    try expectLines("a\x1b[1;5C\x1b[2~\x00\xffb\r", &.{"ab"});
}

test "Up and Ctrl-P go to older entries, Down and Ctrl-N come back to the line being typed" {
    // 4行目のあとの履歴は one、two、one なので、最後は two に上がって one に下りる。
    try expectLines("one\rtwo\r\x1b[A\r\x10\x10\r\x10\x10\x0e\r", &.{ "one", "two", "two", "one", "one" });
    // 履歴を出て、打ちかけの行に戻る。
    try expectLines("one\rdraft\x1b[A\x1b[B\r", &.{ "one", "draft" });
}

test "Up with no history leaves the line as it is" {
    try expectLines("ab\x1b[A\r", &.{"ab"});
}

test "the history skips an entry with a carriage return, which the buffer cannot hold" {
    var editor: Editor = .init(testing.allocator);
    defer editor.deinit();
    try editor.addHistory("one");
    try editor.addHistory("(display \"a\rb\")");
    var run = try runScript(&editor, "\x1b[A\r", 1);
    defer run.deinit();
    try testing.expectEqualStrings("one", run.line(0));
    try testing.expectEqual(@as(usize, 3), editor.history.len());
}

test "Ctrl-R finds the newest entry with the text, again goes older, and Enter takes it" {
    try expectLines("(car x)\r(cdr x)\r\x12x)\r", &.{ "(car x)", "(cdr x)", "(cdr x)" });
    try expectLines("(car x)\r(cdr x)\r\x12x)\x12\r", &.{ "(car x)", "(cdr x)", "(car x)" });
}

test "Ctrl-R then a move key takes the entry and moves in it" {
    // 見つかった "(cdr x)" の一致の位置(x の前)にカーソルを置き、Ctrl-E で行末へ動いて足す。
    try expectLines("(cdr x)\r\x12cdr\x05 ;\r", &.{ "(cdr x)", "(cdr x) ;" });
}

test "Ctrl-G leaves the search and goes back to the line" {
    try expectLines("(cdr x)\rab\x12cdr\x07c\r", &.{ "(cdr x)", "abc" });
}

test "Backspace in the search shortens the query" {
    try expectLines("(car x)\r(cdr x)\r\x12ca\x7f\x7fcd\r", &.{ "(car x)", "(cdr x)", "(cdr x)" });
}

test "Ctrl-C in the search drops the line" {
    var editor: Editor = .init(testing.allocator);
    defer editor.deinit();
    var run = try runScript(&editor, "x\r\x12x\x03", 3);
    defer run.deinit();
    try testing.expect(run.results.items[1] == .interrupted);
}

test "the search shows its label and the query" {
    var editor: Editor = .init(testing.allocator);
    defer editor.deinit();
    var run = try runScript(&editor, "(cdr x)\r\x12cd\x12zz\r", 2);
    defer run.deinit();
    try testing.expect(std.mem.indexOf(u8, run.out.written(), "(reverse-i-search)`cd': (cdr x)") != null);
    try testing.expect(std.mem.indexOf(u8, run.out.written(), "(failed reverse-i-search)`cdzz'") != null);
}

test "the line is drawn after the prompt, and Enter ends it with a newline" {
    var editor: Editor = .init(testing.allocator);
    defer editor.deinit();
    var run = try runScript(&editor, "ab\r", 1);
    defer run.deinit();
    const w = run.out.written();
    try testing.expect(std.mem.indexOf(u8, w, "> ab") != null);
    try testing.expect(std.mem.endsWith(u8, w, "\n"));
}

test "the kill ring lasts across lines" {
    try expectLines("abc\x15\rx\x19\r", &.{ "", "xabc" });
}

test "Rich enters raw mode for each line and leaves it, even at the end" {
    var script: Script = .{ .bytes = "a\r\x04" };
    var in: std.Io.Reader = .fixed("");
    var lr: LineReader = .{ .rich = .{ .editor = .init(testing.allocator), .terminal = script.terminal(), .fallback = .{ .in = &in } } };
    defer lr.deinit();
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try testing.expectEqualStrings("a", (try lr.read(&out.writer, "> ")).line);
    try testing.expect(try lr.read(&out.writer, "> ") == .end);
    try testing.expectEqual(@as(usize, 2), script.began);
    try testing.expectEqual(@as(usize, 2), script.finished);
}

test "Rich reads with the plain reader when the terminal refuses raw mode" {
    var script: Script = .{ .bytes = "", .refuse = true };
    var in: std.Io.Reader = .fixed("plain\n");
    var lr: LineReader = .{ .rich = .{ .editor = .init(testing.allocator), .terminal = script.terminal(), .fallback = .{ .in = &in } } };
    defer lr.deinit();
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try testing.expectEqualStrings("plain", (try lr.read(&out.writer, "> ")).line);
    try testing.expectEqualStrings("> ", out.written());
    try testing.expectEqual(@as(usize, 0), script.finished);
}

test "Dumb writes the prompt, reads lines, and ends with the input" {
    var in: std.Io.Reader = .fixed("a\nb");
    var lr: LineReader = .{ .dumb = .{ .in = &in } };
    defer lr.deinit();
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try testing.expectEqualStrings("a", (try lr.read(&out.writer, "> ")).line);
    try testing.expectEqualStrings("b", (try lr.read(&out.writer, "... ")).line);
    try testing.expect(try lr.read(&out.writer, "> ") == .end);
    try testing.expectEqualStrings("> ... > ", out.written());
    // dumb は履歴を持たない。
    try lr.addHistory("a");
}

test "Dumb skips a line too long for its buffer, and ends without a prompt when the input ends in it" {
    var src: std.Io.Reader = .fixed("0123456789\nok\n0123456789");
    // 読み取りの窓を小さくするため、短い緩衝の読み手を重ねる。
    var small_buf: [4]u8 = undefined;
    var limited = src.limited(.unlimited, &small_buf);
    var lr: LineReader = .{ .dumb = .{ .in = &limited.interface } };
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try testing.expect(try lr.read(&out.writer, "> ") == .too_long);
    try testing.expectEqualStrings("ok", (try lr.read(&out.writer, "> ")).line);
    try testing.expect(try lr.read(&out.writer, "> ") == .too_long);
    try testing.expect(try lr.read(&out.writer, "> ") == .end);
    try testing.expectEqualStrings("> > > ", out.written());
}

test "PosixTerminal reads the bytes buffered in the reader before the terminal" {
    var in: std.Io.Reader = .fixed("xy");
    try in.fill(2);
    // 開いていない fd。Windows の `fd_t` はハンドルなので、整数の -1 は書けない。
    const no_fd: std.posix.fd_t = if (@import("builtin").os.tag == .windows) std.os.windows.INVALID_HANDLE_VALUE else -1;
    var pt: PosixTerminal = .{ .in = &in, .in_fd = no_fd, .out_fd = no_fd };
    const t = pt.terminal();
    try testing.expectEqual(@as(?u8, 'x'), try t.readByte());
    try testing.expectEqual(@as(?u8, 'y'), try t.readByte());
    // 生モードでないとき(端末を読まない)は、入力の終わりである。
    try testing.expectEqual(@as(?u8, null), try t.readByte());
    try testing.expectEqual(@as(usize, term_posix.default_columns), t.columns());
}

test "Ctrl-D on a line of one character deletes it, and does not end the input" {
    try expectLines("a\x01\x04\r", &.{""});
}

test "Enter in the middle of the line leaves the cursor after the whole line" {
    var editor: Editor = .init(testing.allocator);
    defer editor.deinit();
    var run = try runScript(&editor, "abc\x01\r", 1);
    defer run.deinit();
    // プロンプト "> " の2桁と "abc" の3桁のあと(5桁目)に、カーソルを置いてから改行する。
    try testing.expect(std.mem.endsWith(u8, run.out.written(), "\r\x1b[5C\n"));
}

test "the search with an empty query is not shown as failed" {
    var editor: Editor = .init(testing.allocator);
    defer editor.deinit();
    var run = try runScript(&editor, "x\r\x12\x07\r", 2);
    defer run.deinit();
    try testing.expect(std.mem.indexOf(u8, run.out.written(), "(reverse-i-search)`': ") != null);
    try testing.expect(std.mem.indexOf(u8, run.out.written(), "failed") == null);
}

test "ESC then Ctrl-C drops the line too" {
    var editor: Editor = .init(testing.allocator);
    defer editor.deinit();
    var run = try runScript(&editor, "ab\x1b\x03", 1);
    defer run.deinit();
    try testing.expect(run.results.items[0] == .interrupted);
}

test "Ctrl-C in the search draws the line, not the search, before it is dropped" {
    var editor: Editor = .init(testing.allocator);
    defer editor.deinit();
    var run = try runScript(&editor, "x\r\x12x\x03", 2);
    defer run.deinit();
    try testing.expect(std.mem.endsWith(u8, run.out.written(), "\r\x1b[J> \r\x1b[2C^C\n"));
}

test "every edit that is not a kill or a yank ends the run of kills" {
    try expectLines("ab cd\x17\x12\x07\x17\x19\r", &.{"ab "}); // Ctrl-R と Ctrl-G
    try expectLines("ab cd\x17\x14\x17\x19\r", &.{"a b"}); // Ctrl-T
    try expectLines("ab cd\x17\x1f\x17\x19\r", &.{"ab cd"}); // Ctrl-_
    try expectLines("ab cd\x17\t\x17\x19\r", &.{"ab \t"}); // Tab
    try expectLines("ab cd\x17\x7f\x17\x19\r", &.{"ab"}); // Backspace
    try expectLines("ab cd\x17\x1b[3~\x17\x19\r", &.{"ab "}); // Delete
    try expectLines("xy z\rab\x17\x1b[A\x17\x19\r", &.{ "xy z", "xy z" }); // Up
    try expectLines("one\rab\x1b[A\x17\x1b[B\x17\x19\r", &.{ "one", "ab" }); // Down
}

test "Ctrl-W cuts back to a space, past other punctuation" {
    try expectLines("a foo-bar\x17\r", &.{"a "});
}

test "Alt-Backspace also comes as ESC 0x08, and repeated ones join backwards" {
    try expectLines("foo bar\x1b\x08\r", &.{"foo "});
    try expectLines("foo bar\x1b\x7f\x1b\x7f\x19\r", &.{"foo bar"});
}

test "Backspace as 0x08 shortens the search query too" {
    try expectLines("(car x)\r(cdr x)\r\x12ca\x08\x08cd\r", &.{ "(car x)", "(cdr x)", "(cdr x)" });
}

test "leaving the search puts the cursor where the query matched" {
    try expectLines("(cdr x)\r\x12x\x06Z\r", &.{ "(cdr x)", "(cdr xZ)" });
}

test "the search draws the cursor at the match" {
    var editor: Editor = .init(testing.allocator);
    defer editor.deinit();
    var run = try runScript(&editor, "(cdr x)\r\x12x\x07\r", 2);
    defer run.deinit();
    // ラベル "(reverse-i-search)`x': " の23桁に、一致の位置5を足した28桁。
    try testing.expect(std.mem.indexOf(u8, run.out.written(), "\r\x1b[28C") != null);
}

test "recalling an entry drops the undo records of the line typed before" {
    try expectLines("one\rabc\x1b[A\x1f\r", &.{ "one", "one" });
}

test "an invalid CSI is dropped up to the offending byte, which is then read as a key" {
    try expectLines("a\x1b[1\x01b\r", &.{"ba"});
}

test "after ESC ESC, the second ESC starts the next key" {
    try expectLines("foo bar\x1b\x1bbx\r", &.{"foo xbar"});
}

test "Ctrl-C puts the cursor after the line before it writes ^C" {
    var editor: Editor = .init(testing.allocator);
    defer editor.deinit();
    var run = try runScript(&editor, "abc\x01\x03", 1);
    defer run.deinit();
    try testing.expect(std.mem.endsWith(u8, run.out.written(), "\r\x1b[5C^C\n"));
}

test "ESC then a control key works as that key, so Enter after Esc still ends the line" {
    try expectLines("ab\x1b\r", &.{"ab"});
    try expectLines("ab\x1b\x01x\r", &.{"xab"});
}

test "LineTracker passes the bytes on and records whether the last one ended a line" {
    var sink: std.Io.Writer.Allocating = .init(testing.allocator);
    defer sink.deinit();
    var state: LineStart = .{};
    var t: LineTracker = .init(&sink.writer, &state);
    const w = &t.interface;
    try w.writeAll("tail");
    try testing.expect(!state.at_start);
    try w.print("{d}\n", .{42});
    try testing.expect(state.at_start);
    try w.writeAll("");
    try testing.expect(state.at_start);
    try w.splatByteAll('x', 3);
    try testing.expect(!state.at_start);
    try w.flush();
    try testing.expectEqualStrings("tail42\nxxx", sink.written());
}

test "Rich starts a new line before the prompt when the output so far ends inside a line" {
    var script: Script = .{ .bytes = "a\rb\r" };
    var in: std.Io.Reader = .fixed("");
    var state: LineStart = .{};
    var lr: LineReader = .{ .rich = .{ .editor = .init(testing.allocator), .terminal = script.terminal(), .fallback = .{ .in = &in }, .line_start = &state } };
    defer lr.deinit();
    var sink: std.Io.Writer.Allocating = .init(testing.allocator);
    defer sink.deinit();
    var t: LineTracker = .init(&sink.writer, &state);
    _ = try lr.read(&t.interface, "> ");
    // 行の確定は改行で終わるので、次のプロンプトの前には何も足さない。
    try t.interface.writeAll("out\n");
    const before = sink.written().len;
    _ = try lr.read(&t.interface, "> ");
    try testing.expect(std.mem.startsWith(u8, sink.written()[before..], "\r\x1b[J> "));
    // 改行で終わらない出力のあとは、改行を足してから描く。
    try t.interface.writeAll("tail");
    script.bytes = "c\r";
    script.pos = 0;
    const before2 = sink.written().len;
    _ = try lr.read(&t.interface, "> ");
    try testing.expect(std.mem.startsWith(u8, sink.written()[before2..], "\n\r\x1b[J> "));
}

test "LineTracker.drain writes the last slice splat times, and an empty slice leaves the state" {
    var sink: std.Io.Writer.Allocating = .init(testing.allocator);
    defer sink.deinit();
    var state: LineStart = .{};
    var t: LineTracker = .init(&sink.writer, &state);
    const w = &t.interface;
    try testing.expectEqual(@as(usize, 5), try w.vtable.drain(w, &.{ "ab", "c" }, 3));
    try testing.expectEqualStrings("abccc", sink.written());
    try testing.expect(!state.at_start);
    // 最後の要素が改行で終わり、続く空の要素は状態を変えない。
    try testing.expectEqual(@as(usize, 2), try w.vtable.drain(w, &.{ "d\n", "" }, 1));
    try testing.expect(state.at_start);
    // splat が 0 なら、最後の要素は書かれない。
    try testing.expectEqual(@as(usize, 1), try w.vtable.drain(w, &.{ "e", "\n" }, 0));
    try testing.expect(!state.at_start);
    try testing.expectEqualStrings("abcccd\ne", sink.written());
}

// ---- 複数行の編集(7m) ----

/// テスト用の判定。開き括弧が閉じ括弧より多ければ、閉じていないとする。受け取った最後の
/// テキストを覚える。
const ParenCheck = struct {
    last: [256]u8 = undefined,
    last_len: usize = 0,
    calls: usize = 0,

    fn incomplete(self: *ParenCheck) Incomplete {
        return .{ .ctx = self, .func = isOpen };
    }

    fn isOpen(ctx: *anyopaque, text: []const u8) bool {
        const self: *ParenCheck = @ptrCast(@alignCast(ctx));
        self.calls += 1;
        @memcpy(self.last[0..text.len], text);
        self.last_len = text.len;
        var depth: isize = 0;
        for (text) |c| switch (c) {
            '(' => depth += 1,
            ')' => depth -= 1,
            else => {},
        };
        return depth > 0;
    }

    fn lastText(self: *const ParenCheck) []const u8 {
        return self.last[0..self.last_len];
    }
};

fn expectMultiLines(bytes: []const u8, expected: []const []const u8) !void {
    var editor: Editor = .init(testing.allocator);
    defer editor.deinit();
    var paren: ParenCheck = .{};
    editor.incomplete = paren.incomplete();
    var run = try runScript(&editor, bytes, expected.len);
    defer run.deinit();
    try testing.expectEqual(expected.len, run.results.items.len);
    for (expected, 0..) |e, i| try testing.expectEqualStrings(e, run.line(i));
}

test "Enter on an unfinished expression inserts a newline and goes on editing" {
    try expectMultiLines("(+ 1\r2\r3)\r", &.{"(+ 1\n2\n3)"});
    try expectMultiLines("(a)\r(b\rc)\r", &.{ "(a)", "(b\nc)" });
}

test "the check gets the whole text and a final newline, as the REPL keeps its pending text" {
    var editor: Editor = .init(testing.allocator);
    defer editor.deinit();
    var paren: ParenCheck = .{};
    editor.incomplete = paren.incomplete();
    var run = try runScript(&editor, "(a\rb)\r", 1);
    defer run.deinit();
    try testing.expectEqual(@as(usize, 2), paren.calls);
    try testing.expectEqualStrings("(a\nb)\n", paren.lastText());
}

test "Enter in the middle of an unfinished expression splits the line at the cursor" {
    try expectMultiLines("(ab\x02\r\x05)\r", &.{"(a\nb)"});
}

test "with no check, Enter always ends the line, as for the plain reader" {
    try expectLines("(a\rb)\r", &.{ "(a", "b)" });
}

test "the second and later lines are drawn after the continuation prompt" {
    var editor: Editor = .init(testing.allocator);
    defer editor.deinit();
    var paren: ParenCheck = .{};
    editor.incomplete = paren.incomplete();
    var run = try runScript(&editor, "(a\rb)\r", 1);
    defer run.deinit();
    try testing.expect(std.mem.indexOf(u8, run.out.written(), "\r\n... b") != null);
    editor.continuation_prompt = ">> ";
    var run2 = try runScript(&editor, "(a\rb)\r", 1);
    defer run2.deinit();
    try testing.expect(std.mem.indexOf(u8, run2.out.written(), "\r\n>> b") != null);
}

test "Up and Down move between the lines of the buffer, before and after the history" {
    // 2行目から上へ動いて 1 行目の末尾に "!"、下へ戻って 2 行目の末尾に "?"。
    try expectMultiLines("(f\rxyz\x1b[A!\x1b[B?)\r", &.{"(f!\nxyz?)"});
    try expectMultiLines("(f\rxyz\x10!\x0e?)\r", &.{"(f!\nxyz?)"}); // Ctrl-P と Ctrl-N
}

test "up and down keep the column through a short line" {
    // 6 列目から、1 文字の行を通って、先頭の行の同じ列へ。
    try expectMultiLines("(abcdef\rx\rabcdef\x1b[A\x1b[A!\x05)\r", &.{"(abcde!f)\nx\nabcdef"});
    // 列の記憶は、ほかのキーで捨てる。`Ctrl-B` のあとの上矢印は、動いた先の列(0)から始まる。
    try expectMultiLines("(abcdef\rx\rabcdef\x1b[A\x02\x1b[A!\x05)\r", &.{"!(abcdef)\nx\nabcdef"});
}

test "the column is kept through Down and Ctrl-P and Ctrl-N, not only Up" {
    try expectMultiLines("(abcdef\rx\rabcdef\x1b[A\x1b[A\x1b[B\x1b[B!)\r", &.{"(abcdef\nx\nabcdef!)"});
    try expectMultiLines("(abcdef\rx\rabcdef\x10\x10\x0e\x0e!)\r", &.{"(abcdef\nx\nabcdef!)"});
}

test "End goes to the end of its own line, not of the text" {
    try expectMultiLines("(ab\rcd\x10\x1b[F)\r", &.{"(ab)\ncd"});
}

test "the newline that Enter inserts, and a move between lines, end a run of kills" {
    // Ctrl-W で "b" を切り、Enter で改行を入れてから Ctrl-W。2つは1項目にならない。
    try expectMultiLines("(a b\x17\r\x17\x19)\r", &.{"(a \n)"});
    // 行をまたぐ移動のあとの切り取りも、前の切り取りとは別の項目である。
    try expectMultiLines("(x\ry z\x17\x1b[A\x17\x19)\r", &.{"(x)\ny "});
}

test "Ctrl-A and Ctrl-E, Home and End go to the start and end of the line" {
    try expectMultiLines("(ab\rcd\x01!\x05?\x1b[H<\x1b[F>\x1b[A\x1b[A)\r", &.{"(ab)\n<!cd?>"});
}

test "Backspace at the start of a line joins it to the line before" {
    try expectMultiLines("(a\rb\x01\x7f)\r", &.{"(a)b"});
}

test "Delete at the end of a line joins the next line, and Ctrl-K takes the newline there" {
    try expectMultiLines("(a\rb\x10\x05\x1b[3~)\r", &.{"(a)b"});
    try expectMultiLines("(a\rb\x10\x05\x0b)\r", &.{"(a)b"});
    // 行の途中では、行末までだけを切る。
    try expectMultiLines("(ab\rcd\x10\x01\x06\x0b)\r", &.{"()\ncd"});
}

test "Ctrl-U cuts to the start of the line only, and Ctrl-W stops at a line's words" {
    try expectMultiLines("(f\rab cd\x15)\r", &.{"(f\n)"});
    try expectMultiLines("(f\rab cd\x17)\r", &.{"(f\nab )"});
}

test "an entry of several lines in the history comes back whole, and can be edited line by line" {
    try expectMultiLines("(f\r1)\r\x1b[A\r", &.{ "(f\n1)", "(f\n1)" });
    // 呼び出した直後はカーソルが末尾にあり、次の上矢印は項目の中の前の行へ動く。
    try expectMultiLines("(f\r1)\r\x1b[A\x1b[A!\x1b[B\r", &.{ "(f\n1)", "(f!\n1)" });
    // 項目の先頭の行からさらに上へ動くと、1つ古い項目になる。
    try expectMultiLines("(old)\r(f\r1)\r\x1b[A\x1b[A\x1b[A\r", &.{ "(old)", "(f\n1)", "(old)" });
    // 下へ動くと、新しい側へ戻り、打ちかけの行に着く。
    try expectMultiLines("(f\r1)\rx\x1b[A\x1b[B\r", &.{ "(f\n1)", "x" });
}

test "Ctrl-R finds a multi-line entry and takes it" {
    try expectMultiLines("(f\r(g 1))\r\x12g\x05\r", &.{ "(f\n(g 1))", "(f\n(g 1))" });
}

test "Ctrl-D in a buffer of several lines deletes a character, and Ctrl-C drops all of it" {
    try expectMultiLines("(a\rb\x10\x04)\r", &.{"()\nb"});
    var editor: Editor = .init(testing.allocator);
    defer editor.deinit();
    var paren: ParenCheck = .{};
    editor.incomplete = paren.incomplete();
    var run = try runScript(&editor, "(a\rb\x03x)\r", 2);
    defer run.deinit();
    try testing.expect(run.results.items[0] == .interrupted);
    try testing.expectEqualStrings("x)", run.line(1));
}

test "undo takes back the newline that Enter inserted" {
    try expectMultiLines("(a\rb\x1f\x1f)\r", &.{"(a)"});
}

test "a recalled multi-line entry is drawn on as many rows as it has lines" {
    var editor: Editor = .init(testing.allocator);
    defer editor.deinit();
    try editor.addHistory("(f\n 1\n 2)");
    var run = try runScript(&editor, "\x1b[A\r", 1);
    defer run.deinit();
    // 先頭へ戻る移動は、描いた行数に合わせる(3行を描いたあと、カーソルは 3 行目にある)。
    try testing.expect(std.mem.indexOf(u8, run.out.written(), "> (f\r\n...  1\r\n...  2)") != null);
}

test "the redraw after moving up goes back to the first row" {
    var editor: Editor = .init(testing.allocator);
    defer editor.deinit();
    var paren: ParenCheck = .{};
    editor.incomplete = paren.incomplete();
    var run = try runScript(&editor, "(f\r1\x1b[A", 1);
    defer run.deinit();
    // 上へ動いたあとの再描画は、カーソルが 2 行目にいた分(1行)だけ上へ戻ってから描く。
    try testing.expect(std.mem.indexOf(u8, run.out.written(), "\x1b[1A\r\x1b[J> (f") != null);
}

test "random keys keep the buffer valid and the editor away from crashing" {
    var prng: std.Random.DefaultPrng = .init(0x7e);
    const random = prng.random();
    const pieces = [_][]const u8{ "a", "(", ")", "あ", "\r", "\r", "\x1b[A", "\x1b[B", "\x01", "\x05", "\x0b", "\x15", "\x17", "\x19", "\x1f", "\x7f", "\x14", "\x04", "\x1b[3~", "\x02", "\x06", "\x12", "\x07" };
    var script_bytes: std.ArrayList(u8) = .empty;
    defer script_bytes.deinit(testing.allocator);
    for (0..40) |_| {
        script_bytes.clearRetainingCapacity();
        for (0..60) |_| try script_bytes.appendSlice(testing.allocator, pieces[random.uintLessThan(usize, pieces.len)]);
        try script_bytes.append(testing.allocator, '\x03'); // 最後は必ず終える
        var editor: Editor = .init(testing.allocator);
        defer editor.deinit();
        var paren: ParenCheck = .{};
        editor.incomplete = paren.incomplete();
        var script: Script = .{ .bytes = script_bytes.items, .cols = random.intRangeAtMost(usize, 5, 40) };
        var out: std.Io.Writer.Allocating = .init(testing.allocator);
        defer out.deinit();
        while (true) {
            const r = try editor.read(script.terminal(), &out.writer, "> ");
            switch (r) {
                .line => |l| {
                    try testing.expect(std.unicode.utf8ValidateSlice(l));
                    try testing.expect(std.mem.indexOfScalar(u8, l, '\r') == null);
                    try editor.addHistory(l);
                },
                .end => break,
                .interrupted, .too_long => {},
            }
        }
    }
}

test {
    std.testing.refAllDecls(@This());
}
