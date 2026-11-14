//! Line reader of the REPL: the plain reader and the editing reader.
//!
//! REPL が1行ずつ読む入口(7j、ADR-0014、ADR-0049)。`LineReader` は2つの形を持つ。
//!
//! - `dumb`: これまでの素朴な読み取り。プロンプトを書き、改行までを読む。Windows と、端末で
//!   ない入力(パイプ、ファイル)はこちらである。
//! - `rich`: 端末の生モードで1バイトずつ読み、Emacs の標準のキー割り当てで1行を編集する。
//!   入力と出力の両方が POSIX の端末のときに使う。
//!
//! 完結判定(`sucheme.isIncomplete`)は、どちらの形でも REPL が行う。ここは1行を返すだけで
//! ある。核の編集バッファは1行なので、式が閉じていないときは、REPL が継続行のプロンプトで
//! 次の行を読む。確定した前の行には戻れない(複数行の編集は 7m)。
//!
//! 生モードは、1行を読む間だけ有効にする。評価の間は元の端末の設定に戻すので、プログラムの
//! 出力と `read` は、これまでどおりの端末で動き、`Ctrl-C` は評価を止める信号になる。
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
    /// 改行を除いた1行。次の `read` まで有効である。
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
                .up => try self.recallOlder(),
                .down => try self.recallNewer(),
            },
            .home => self.move(Buffer.moveToStart),
            .end => self.move(Buffer.moveToEnd),
            .delete => try self.deleteRange(self.buf.rangeForwardChar()),
            // 括弧つき貼り付けは有効にしていない。割り当ての無い列は無視する。
            .paste_begin, .paste_end, .unknown => return .none,
        }
        return .redraw;
    }

    fn handleCtrl(self: *Editor, c: u8) Allocator.Error!Action {
        switch (c) {
            0x01 => self.move(Buffer.moveToStart), // Ctrl-A
            0x02 => self.move(Buffer.moveBackwardChar), // Ctrl-B
            0x03 => return .interrupt, // Ctrl-C
            0x04 => { // Ctrl-D
                if (self.buf.text().len == 0) return .end;
                try self.deleteRange(self.buf.rangeForwardChar());
            },
            0x05 => self.move(Buffer.moveToEnd), // Ctrl-E
            0x06 => self.move(Buffer.moveForwardChar), // Ctrl-F
            0x08, 0x7F => try self.deleteRange(self.buf.rangeBackwardChar()), // Backspace
            0x0A, 0x0D => return .accept, // Enter
            0x0B => try check(self.kill.killToEnd(&self.buf, &self.undo)), // Ctrl-K
            0x0E => try self.recallNewer(), // Ctrl-N
            0x10 => try self.recallOlder(), // Ctrl-P
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
            // `ESC` のあとの `Ctrl-C` も、行を捨てる操作として効かせる(`ESC` に時間切れが無いため)。
            0x03 => return .interrupt,
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
            // 履歴の項目は、呼び出せるもの(改行を含まない)だけが来る。来たら行を変えない。
            error.InvalidUtf8, error.LineBreak, error.InvalidRange => {},
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

/// The editing reader: the editor, the terminal, and the plain reader to fall back on.
pub const Rich = struct {
    editor: Editor,
    terminal: Terminal,
    /// 生モードに入れなかったときに使う。
    fallback: Dumb,

    pub fn read(self: *Rich, out: *std.Io.Writer, prompt: []const u8) ReadError!Result {
        self.terminal.begin() catch return self.fallback.read(out, prompt);
        defer self.terminal.finish();
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
    var run = try runScript(&editor, "ab\x04\r\x04", 5);
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

test "the history skips an entry with a newline, which the core cannot show" {
    var editor: Editor = .init(testing.allocator);
    defer editor.deinit();
    try editor.addHistory("one");
    try editor.addHistory("(+ 1\n2)\n");
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
    var pt: PosixTerminal = .{ .in = &in, .in_fd = -1, .out_fd = -1 };
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
    try testing.expect(std.mem.endsWith(u8, run.out.written(), "\r> \x1b[K\r\x1b[2C^C\n"));
}
