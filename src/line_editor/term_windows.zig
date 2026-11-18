//! Windows console boundary of the line editor: raw mode, byte input, terminal width.
//!
//! 行編集(docs/plans/0021-stage7-8-early-parts.md の 7i、ADR-0049)の中で、Windows の OS に
//! 触れるコードはこのファイルに閉じる。境界は `term_posix.zig`(7h)と同じ4つである。
//!
//! - `isInteractive`: 入力と出力の両方がコンソールか。そうでなければ、呼び出し側は `dumb` を使う。
//! - `RawMode.enter` と `RawMode.leave`: 生モードに入る、元に戻す。
//! - `RawMode.read`: 入力から複数バイトを読む。
//! - `columns`: コンソールの幅(列数)を取る。
//!
//! 違いは `RawMode.enter` の引数だけである。Windows のコンソールは、入力と出力のハンドルが別の
//! モードを持つので、両方を受け取る。
//!
//! Windows 以外では、コンパイルは通り、`isInteractive` は常に false、`RawMode.enter` は
//! `error.Unsupported` を返す。モードの計算(`rawInputMode` など)は純粋な関数なので、どの OS でも
//! テストできる。
//!
//! 元に戻す経路は3つある。正常(`defer raw.leave()`)、コンソールの終了イベント(`Ctrl-Break`、
//! ウィンドウを閉じる、ログオフ、シャットダウン。ハンドラが戻してから既定の処理に任せる)、panic
//! (`restoreActive`)である。コンソールのモードは、プロセスが終わっても親のシェルに残りうる。

const std = @import("std");
const builtin = @import("builtin");

/// Whether this OS has a raw mode implementation here.
pub const supported = builtin.os.tag == .windows;

/// 端末の幅が分からないときに、呼び出し側が使う列数。
pub const default_columns: u16 = 80;

/// Windows の `HANDLE`(`std.os.windows.HANDLE` と同じ型)。Windows 以外でも宣言できるよう、
/// 標準ライブラリの型名を使わずに書く。
pub const Handle = *anyopaque;

pub const EnterError = error{
    /// この OS では生モードを実装していない。
    Unsupported,
    /// 入力か出力が、コンソールでない。
    NotATerminal,
    /// すでに別の `RawMode` が有効である(戻す対象を1つに保つため、同時には1つだけ持てる)。
    AlreadyActive,
    /// コンソールのモードを読み書きできなかった。
    Unexpected,
};

pub const ReadError = error{
    /// 読み取りに失敗した(コンソールが切れたなど)。呼び出し側は入力の終わりとして扱ってよい。
    InputOutput,
    Unexpected,
};

const ENABLE_PROCESSED_INPUT: u32 = 0x0001;
const ENABLE_LINE_INPUT: u32 = 0x0002;
const ENABLE_ECHO_INPUT: u32 = 0x0004;
const ENABLE_VIRTUAL_TERMINAL_INPUT: u32 = 0x0200;
const ENABLE_PROCESSED_OUTPUT: u32 = 0x0001;
const ENABLE_VIRTUAL_TERMINAL_PROCESSING: u32 = 0x0004;

/// UTF-8 のコードページ。
const CP_UTF8: u32 = 65001;

/// The input mode that raw mode sets. Kept as a pure function so it can be tested on any OS.
///
/// Why: 行入力(`ENABLE_LINE_INPUT`)とエコーを切り、`ENABLE_PROCESSED_INPUT` も切る。切ると
/// `Ctrl-C` は、シグナル(コンソールの終了イベント)にならず 0x03 のバイトで届く(7h の
/// `ISIG` と同じ。7j が、編集中の行を捨てる操作に割り当てる)。`ENABLE_VIRTUAL_TERMINAL_INPUT` を
/// 立てると、矢印キーなどが VT のシーケンス(`ESC [ A` など)で届き、7a のキー解読がそのまま読める。
/// 他のビット(`ENABLE_QUICK_EDIT_MODE` など)は、利用者の設定なので変えない。
pub fn rawInputMode(base: u32) u32 {
    var m = base;
    m &= ~(ENABLE_PROCESSED_INPUT | ENABLE_LINE_INPUT | ENABLE_ECHO_INPUT);
    m |= ENABLE_VIRTUAL_TERMINAL_INPUT;
    return m;
}

/// The output mode that raw mode sets.
///
/// Why: 再描画が出す `CSI` のシーケンスを解釈させるために、`ENABLE_VIRTUAL_TERMINAL_PROCESSING` を
/// 立てる。`DISABLE_NEWLINE_AUTO_RETURN` は立てない(`\n` で行頭へ戻る既存の出力を保つ。標準ライブラリの
/// `enableAnsiEscapeCodes` も同じ理由で立てない)。
pub fn rawOutputMode(base: u32) u32 {
    return base | ENABLE_PROCESSED_OUTPUT | ENABLE_VIRTUAL_TERMINAL_PROCESSING;
}

/// `GetConsoleScreenBufferInfo` の結果。
const ScreenBufferInfo = extern struct {
    size_x: i16,
    size_y: i16,
    cursor_x: i16,
    cursor_y: i16,
    attributes: u16,
    window_left: i16,
    window_top: i16,
    window_right: i16,
    window_bottom: i16,
    max_x: i16,
    max_y: i16,
};

/// The visible width of the console window, or null when the info is not usable.
///
/// Why: バッファの幅(`size_x`)ではなく、見えているウィンドウの幅を使う。バッファは、ウィンドウより
/// 広いことがある(横にスクロールする設定)。そのとき、バッファの幅で描くと、行が見える範囲を超える。
fn visibleColumns(info: ScreenBufferInfo) ?u16 {
    const w = @as(i32, info.window_right) - @as(i32, info.window_left) + 1;
    if (w <= 0) return null;
    return @intCast(w);
}

const Bool = i32;

/// kernel32 の関数。`std.os.windows` は、これらのコンソール関数を公開していない(0.17.0)。
/// Why: 宣言は、参照されたときだけ解析される。Windows 以外のビルドは、ここに届かない。
const k32 = struct {
    extern "kernel32" fn GetConsoleMode(console: Handle, mode: *u32) callconv(.winapi) Bool;
    extern "kernel32" fn SetConsoleMode(console: Handle, mode: u32) callconv(.winapi) Bool;
    extern "kernel32" fn GetConsoleCP() callconv(.winapi) u32;
    extern "kernel32" fn SetConsoleCP(cp: u32) callconv(.winapi) Bool;
    extern "kernel32" fn GetConsoleOutputCP() callconv(.winapi) u32;
    extern "kernel32" fn SetConsoleOutputCP(cp: u32) callconv(.winapi) Bool;
    extern "kernel32" fn GetConsoleScreenBufferInfo(console: Handle, info: *ScreenBufferInfo) callconv(.winapi) Bool;
    extern "kernel32" fn ReadFile(file: Handle, buf: [*]u8, len: u32, read: ?*u32, overlapped: ?*anyopaque) callconv(.winapi) Bool;
    extern "kernel32" fn GetLastError() callconv(.winapi) u32;
    extern "kernel32" fn SetConsoleCtrlHandler(handler: ?*const fn (u32) callconv(.winapi) Bool, add: Bool) callconv(.winapi) Bool;
};

const ERROR_BROKEN_PIPE: u32 = 109;

fn stdHandle(comptime which: enum { in, out }) Handle {
    const file = switch (which) {
        .in => std.Io.File.stdin(),
        .out => std.Io.File.stdout(),
    };
    return file.handle;
}

fn isConsole(h: Handle) bool {
    if (!supported) return false;
    var mode: u32 = undefined;
    return k32.GetConsoleMode(h, &mode) != 0;
}

/// Whether both stdin and stdout are consoles, which is when the rich editor can run.
///
/// Why: mintty や Cygwin の疑似端末、パイプ、ファイルは、コンソールではない。そこでは `dumb` を使う。
pub fn isInteractive(io: std.Io) bool {
    _ = io;
    if (!supported) return false;
    return isConsole(stdHandle(.in)) and isConsole(stdHandle(.out));
}

/// Returns the visible width in columns of the console behind `out`, or null when it cannot be told.
pub fn columns(out: Handle) ?u16 {
    if (!supported) return null;
    var info: ScreenBufferInfo = undefined;
    if (k32.GetConsoleScreenBufferInfo(out, &info) == 0) return null;
    return visibleColumns(info);
}

/// 戻す対象。コンソールの終了イベントのハンドラは引数を持てないので、プロセス全体の状態に置く。
/// `active` が true の間だけ、他の値は有効である。同時に有効にできるのは1つだけで、`enter` が
/// `AlreadyActive` で拒む。
const Saved = struct {
    in: Handle,
    out: Handle,
    in_mode: u32,
    out_mode: u32,
    in_cp: u32,
    out_cp: u32,
};

var active: std.atomic.Value(bool) = .init(false);
var active_saved: Saved = undefined;
var ctrl_handler_installed: bool = false;

fn restore(s: Saved) void {
    _ = k32.SetConsoleMode(s.in, s.in_mode);
    _ = k32.SetConsoleMode(s.out, s.out_mode);
    _ = k32.SetConsoleCP(s.in_cp);
    _ = k32.SetConsoleOutputCP(s.out_cp);
}

/// Puts the console back to the state `RawMode.enter` saved, when raw mode is active.
///
/// 終了イベントのハンドラ(別のスレッドで走る)からも呼ばれるので、メモリの確保や標準ライブラリの
/// 入出力を使わない。有効でなければ何もしない。
pub fn restoreActive() void {
    if (!supported) return;
    if (!active.load(.acquire)) return;
    restore(active_saved);
}

/// Restores the console on `Ctrl-Break`, closing the window, logoff and shutdown, then lets the
/// default handling end the process (returns FALSE).
fn onCtrlEvent(event: u32) callconv(.winapi) Bool {
    switch (event) {
        1, 2, 5, 6 => restoreActive(),
        else => {},
    }
    return 0;
}

/// A console in raw mode.
pub const RawMode = struct {
    saved: Saved,
    left: bool = false,

    /// Puts the console in raw mode. `in` is the input handle (normally stdin) and `out` the output
    /// handle (normally stdout).
    pub fn enter(in: Handle, out: Handle) EnterError!RawMode {
        if (!supported) return error.Unsupported;
        if (active.load(.acquire)) return error.AlreadyActive;
        var in_mode: u32 = undefined;
        var out_mode: u32 = undefined;
        if (k32.GetConsoleMode(in, &in_mode) == 0) return error.NotATerminal;
        if (k32.GetConsoleMode(out, &out_mode) == 0) return error.NotATerminal;
        const saved: Saved = .{
            .in = in,
            .out = out,
            .in_mode = in_mode,
            .out_mode = out_mode,
            .in_cp = k32.GetConsoleCP(),
            .out_cp = k32.GetConsoleOutputCP(),
        };
        active_saved = saved;
        active.store(true, .release);
        errdefer {
            restore(saved);
            active.store(false, .release);
        }
        // Why: VT の入力は、入力のコードページの文字として届く。UTF-8 にしないと、ASCII でない文字が
        // 7a のキー解読に届かない。出力も、再描画が UTF-8 で書くので揃える。どちらも、`leave` が戻す。
        _ = k32.SetConsoleCP(CP_UTF8);
        _ = k32.SetConsoleOutputCP(CP_UTF8);
        if (k32.SetConsoleMode(in, rawInputMode(in_mode)) == 0) return error.Unexpected;
        if (k32.SetConsoleMode(out, rawOutputMode(out_mode)) == 0) return error.Unexpected;
        if (k32.SetConsoleCtrlHandler(onCtrlEvent, 1) != 0) ctrl_handler_installed = true;
        return .{ .saved = saved };
    }

    /// Puts the console back and removes the event handler. Safe to call more than once.
    pub fn leave(self: *RawMode) void {
        if (!supported) return;
        if (self.left) return;
        self.left = true;
        restore(self.saved);
        if (ctrl_handler_installed) {
            _ = k32.SetConsoleCtrlHandler(onCtrlEvent, 0);
            ctrl_handler_installed = false;
        }
        active.store(false, .release);
    }

    /// Reads at least one byte, up to `buf.len`. Returns 0 at the end of input.
    pub fn read(self: *const RawMode, buf: []u8) ReadError!usize {
        if (!supported) return 0;
        if (buf.len == 0) return 0;
        var n: u32 = 0;
        const len: u32 = @intCast(@min(buf.len, std.math.maxInt(u32)));
        if (k32.ReadFile(self.saved.in, buf.ptr, len, &n, null) == 0) {
            return switch (k32.GetLastError()) {
                ERROR_BROKEN_PIPE => 0,
                else => error.InputOutput,
            };
        }
        return n;
    }
};

// ---- tests ----

const testing = std.testing;

test "rawInputMode turns off line input, echo and processed input, turns on VT input, and keeps the rest" {
    const quick_edit: u32 = 0x0040;
    const base = ENABLE_PROCESSED_INPUT | ENABLE_LINE_INPUT | ENABLE_ECHO_INPUT | quick_edit;
    const raw = rawInputMode(base);
    try testing.expectEqual(@as(u32, 0), raw & ENABLE_PROCESSED_INPUT);
    try testing.expectEqual(@as(u32, 0), raw & ENABLE_LINE_INPUT);
    try testing.expectEqual(@as(u32, 0), raw & ENABLE_ECHO_INPUT);
    try testing.expect(raw & ENABLE_VIRTUAL_TERMINAL_INPUT != 0);
    try testing.expect(raw & quick_edit != 0);
    // すでに立っていても、そのままである。
    try testing.expectEqual(raw, rawInputMode(raw));
}

test "rawOutputMode turns on VT processing and keeps the rest" {
    const wrap_at_eol: u32 = 0x0002;
    const raw = rawOutputMode(wrap_at_eol);
    try testing.expect(raw & ENABLE_VIRTUAL_TERMINAL_PROCESSING != 0);
    try testing.expect(raw & ENABLE_PROCESSED_OUTPUT != 0);
    try testing.expect(raw & wrap_at_eol != 0);
    // DISABLE_NEWLINE_AUTO_RETURN(0x8)は立てない。
    try testing.expectEqual(@as(u32, 0), raw & 0x8);
}

test "visibleColumns uses the window, not the buffer, and rejects an empty window" {
    var info = std.mem.zeroes(ScreenBufferInfo);
    info.size_x = 300;
    info.window_left = 10;
    info.window_right = 129;
    try testing.expectEqual(@as(?u16, 120), visibleColumns(info));
    info.window_left = 0;
    info.window_right = 79;
    try testing.expectEqual(@as(?u16, 80), visibleColumns(info));
    info.window_right = -1;
    try testing.expectEqual(@as(?u16, null), visibleColumns(info));
}

test "ScreenBufferInfo has the layout of CONSOLE_SCREEN_BUFFER_INFO" {
    try testing.expectEqual(@as(usize, 22), @sizeOf(ScreenBufferInfo));
    try testing.expectEqual(@as(usize, 10), @offsetOf(ScreenBufferInfo, "window_left"));
    try testing.expectEqual(@as(usize, 14), @offsetOf(ScreenBufferInfo, "window_right"));
}

test "on an OS without this backend, nothing is interactive and enter is unsupported" {
    if (supported) return error.SkipZigTest;
    try testing.expect(!isInteractive(testing.io));
    try testing.expectError(error.Unsupported, RawMode.enter(@ptrFromInt(8), @ptrFromInt(8)));
    try testing.expectEqual(@as(?u16, null), columns(@ptrFromInt(8)));
    restoreActive();
}

test "on Windows, enter refuses a handle that is not a console, and leaves nothing active" {
    if (!supported) return error.SkipZigTest;
    const bad: Handle = std.os.windows.INVALID_HANDLE_VALUE;
    try testing.expectError(error.NotATerminal, RawMode.enter(bad, bad));
    try testing.expect(!active.load(.acquire));
    try testing.expectEqual(@as(?u16, null), columns(bad));
}

test "restoreActive does nothing when raw mode is not active" {
    restoreActive();
}
