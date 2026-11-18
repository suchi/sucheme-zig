//! POSIX terminal boundary of the line editor: raw mode, byte input, terminal width.
//!
//! 行編集(docs/plans/0021-stage7-8-early-parts.md の 7h、ADR-0049)の中で、OS に触れる
//! コードはこのファイルに閉じる。境界は次の4つである。Windows 版(7i の `term_windows.zig`)は、
//! 同じ形の関数を持つ(`RawMode.enter` だけ、入力と出力の2つのハンドルを取る)。
//!
//! - `isInteractive`: 入力と出力の両方が端末か。端末でなければ、呼び出し側は `dumb` を使う。
//! - `RawMode.enter` と `RawMode.leave`: 生モードに入る、元に戻す。
//! - `RawMode.read`: 入力から複数バイトを読む。
//! - `columns`: 端末の幅(列数)を取る。
//!
//! Windows などの未対応の OS では、コンパイルは通り、`isInteractive` は常に false、
//! `RawMode.enter` は `error.Unsupported` を返す。
//!
//! 生モードで端末が戻らなくなることが、このファイルで一番の危険である。元に戻す経路は4つある。
//!
//! - 正常: 呼び出し側が `defer raw.leave()` を置く。`leave` は何度呼んでも安全である。
//! - 信号: `SIGINT` `SIGTERM` `SIGHUP` `SIGQUIT` のハンドラが、端末を戻し、既定の動作に戻して
//!   自分に同じ信号を送り直す(終了の状態は、信号で死んだものになる)。
//! - panic: `restoreActive` が信号のハンドラと同じ復元を行う。`src/main.zig` の panic
//!   ハンドラから呼ぶ(組み込みは 7j)。
//! - 異常終了(`SIGKILL` など): 捕まえられないので戻せない。端末を使う側のシェルで `stty sane`
//!   が要る。ここでは対策できない。

const std = @import("std");
const builtin = @import("builtin");

const posix = std.posix;

/// Whether this OS has a raw mode implementation here.
///
/// Why: Windows のコンソールは termios を持たない。`term_windows.zig`(7i)が受け持つので、ここでは
/// コンパイルだけを通す。wasm の実行ファイルはこのファイルに届かないが、届いても通るようにしておく。
pub const supported = switch (builtin.os.tag) {
    .windows, .wasi, .freestanding => false,
    else => true,
};

/// 端末の幅が分からないときに、呼び出し側が使う列数。
pub const default_columns: u16 = 80;

pub const EnterError = error{
    /// この OS では生モードを実装していない。
    Unsupported,
    /// 入力が端末でない。
    NotATerminal,
    /// すでに別の `RawMode` が有効である(戻す対象を1つに保つため、同時には1つだけ持てる)。
    AlreadyActive,
    /// 端末の属性を読み書きできなかった(端末が切れた場合を含む)。
    Unexpected,
};

pub const ReadError = error{
    /// 読み取りに失敗した(端末が切れたなど)。呼び出し側は入力の終わりとして扱ってよい。
    InputOutput,
    Unexpected,
};

const Termios = if (supported) posix.termios else void;

/// Whether both stdin and stdout are terminals, which is when the rich editor can run.
///
/// Why: 入力だけが端末で出力がパイプのとき(`sucheme | tee log`)、エスケープシーケンスが
/// ログに混ざる。両方が端末のときだけ使う。`File.isTty` の失敗(取り消し)は、端末でないとみなす。
pub fn isInteractive(io: std.Io) bool {
    if (!supported) return false;
    const in_tty = std.Io.File.stdin().isTty(io) catch return false;
    const out_tty = std.Io.File.stdout().isTty(io) catch return false;
    return in_tty and out_tty;
}

/// Returns the width in columns of the terminal behind `fd`, or null when it cannot be told
/// (not a terminal, or the terminal reports 0).
pub fn columns(fd: posix.fd_t) ?u16 {
    if (!supported) return null;
    var ws: posix.winsize = undefined;
    const rc = ioctlWinsize(fd, &ws);
    if (rc != 0) return null;
    if (ws.col == 0) return null;
    return ws.col;
}

fn ioctlWinsize(fd: posix.fd_t, ws: *posix.winsize) usize {
    // Why: libc を使わない Linux(musl の静的ビルド)では `system.ioctl` は生のシステムコールで、
    // 戻り値は errno 込みの `usize` である。libc を使う OS では可変長引数の C 関数で、失敗は
    // -1 を返す。どちらも「0 なら成功」で揃える。
    if (builtin.os.tag == .linux and !builtin.link_libc) {
        const rc = std.os.linux.ioctl(fd, posix.T.IOCGWINSZ, @intFromPtr(ws));
        return if (posix.errno(rc) == .SUCCESS) 0 else 1;
    } else {
        const rc = posix.system.ioctl(fd, @as(c_int, @intCast(posix.T.IOCGWINSZ)), ws);
        return if (rc == 0) 0 else 1;
    }
}

/// The input flags that raw mode turns off or sets. Kept as a pure function so it can be tested
/// without a terminal.
///
/// Why: 出力の加工(`OPOST`)は残す。再描画以外の出力(評価結果や `display`)が、これまでどおり
/// `\n` で改行できるようにするためである。`ICRNL` は切るので、Enter は 0x0D で届く
/// (Ctrl-J は 0x0A)。7a のキー解読は、両方を Enter として扱う。`ISIG` を切るので、Ctrl-C は
/// 信号にならず 0x03 のバイトで届く(7j が、編集中の行を捨てる操作に割り当てる)。
pub fn makeRaw(base: Termios) Termios {
    if (!supported) return base;
    var t = base;
    t.iflag.BRKINT = false;
    t.iflag.ICRNL = false;
    t.iflag.INPCK = false;
    t.iflag.ISTRIP = false;
    t.iflag.IXON = false;
    t.cflag.CSIZE = .CS8;
    t.lflag.ECHO = false;
    t.lflag.ICANON = false;
    t.lflag.IEXTEN = false;
    t.lflag.ISIG = false;
    // 1バイトが届くまで待つ(時間切れなし)。Esc だけのキーと、Esc で始まる列の区別は、
    // 7a が「続きを待つ」で扱う。
    t.cc[@backingInt(posix.V.MIN)] = 1;
    t.cc[@backingInt(posix.V.TIME)] = 0;
    return t;
}

/// The terminal state that signal handlers and `restoreActive` put back.
///
/// Why: 信号のハンドラは引数を持てないので、戻す対象はプロセス全体の状態に置く。同時に有効に
/// できるのは1つだけにして、`enter` が `AlreadyActive` で拒む。`active_fd` が -1 でない間だけ、
/// `active_saved` は有効である。
var active_fd: std.atomic.Value(i32) = .init(-1);
var active_saved: Termios = undefined;

/// Signals that restore the terminal and then end the process.
const fatal_signals = [_]posix.SIG{ .INT, .TERM, .HUP, .QUIT };

var previous_actions: [fatal_signals.len]posix.Sigaction = undefined;

/// Puts the terminal back to the state `RawMode.enter` saved, when raw mode is active.
///
/// 信号のハンドラからも呼ばれるので、メモリの確保や標準ライブラリの入出力を使わない。
/// 有効でなければ何もしない。
pub fn restoreActive() void {
    if (!supported) return;
    const fd = active_fd.load(.acquire);
    if (fd < 0) return;
    posix.tcsetattr(fd, .DRAIN, active_saved) catch {};
}

fn onFatalSignal(sig: posix.SIG) callconv(.c) void {
    restoreActive();
    // 既定の動作に戻して、同じ信号を自分に送り直す。ハンドラの中で `exit` を呼ぶより、
    // 親のシェルから見た終了の状態が、信号で死んだものになる。
    const dfl: posix.Sigaction = .{
        .handler = .{ .handler = posix.SIG.DFL },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(sig, &dfl, null);
    posix.raise(sig) catch {};
}

/// A terminal in raw mode.
pub const RawMode = struct {
    fd: posix.fd_t,
    saved: Termios,
    left: bool = false,

    /// Puts the terminal behind `fd` (normally stdin) in raw mode and installs the signal handlers
    /// that put it back.
    pub fn enter(fd: posix.fd_t) EnterError!RawMode {
        if (!supported) return error.Unsupported;
        if (active_fd.load(.acquire) >= 0) return error.AlreadyActive;
        const saved = posix.tcgetattr(fd) catch |e| switch (e) {
            error.NotATerminal => return error.NotATerminal,
            else => return error.Unexpected,
        };
        active_saved = saved;
        active_fd.store(fd, .release);
        errdefer active_fd.store(-1, .release);
        posix.tcsetattr(fd, .DRAIN, makeRaw(saved)) catch return error.Unexpected;
        installHandlers();
        return .{ .fd = fd, .saved = saved };
    }

    /// Puts the terminal back and restores the signal handlers. Safe to call more than once.
    pub fn leave(self: *RawMode) void {
        if (!supported) return;
        if (self.left) return;
        self.left = true;
        posix.tcsetattr(self.fd, .DRAIN, self.saved) catch {};
        removeHandlers();
        active_fd.store(-1, .release);
    }

    /// Reads at least one byte, up to `buf.len`. Returns 0 at the end of input.
    pub fn read(self: *const RawMode, buf: []u8) ReadError!usize {
        if (!supported) return 0;
        return posix.read(self.fd, buf) catch |e| switch (e) {
            error.InputOutput, error.NotOpenForReading, error.ConnectionResetByPeer, error.SocketUnconnected => error.InputOutput,
            else => error.Unexpected,
        };
    }
};

/// どの信号に、このファイルのハンドラを入れたか。`leave` が戻す対象である。
var installed: [fatal_signals.len]bool = @splat(false);

/// Installs the handlers, except for a signal the process was told to ignore.
///
/// Why: `nohup` や、シェルのバックグラウンド実行は、`SIGHUP` や `SIGINT` を無視にして起動する。
/// 無視を上書きすると、利用者が頼んだ振る舞い(端末が閉じても死なない)を、行編集が壊す。
/// 無視されている信号は、そのままにする(端末は、通常の終了では `leave` が戻す)。
fn installHandlers() void {
    const act: posix.Sigaction = .{
        .handler = .{ .handler = onFatalSignal },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    for (fatal_signals, 0..) |sig, i| {
        posix.sigaction(sig, null, &previous_actions[i]);
        if (previous_actions[i].handler.handler == posix.SIG.IGN) {
            installed[i] = false;
            continue;
        }
        posix.sigaction(sig, &act, null);
        installed[i] = true;
    }
}

fn removeHandlers() void {
    for (fatal_signals, 0..) |sig, i| {
        if (!installed[i]) continue;
        posix.sigaction(sig, &previous_actions[i], null);
        installed[i] = false;
    }
}

// ---- tests ----

const testing = std.testing;

test "makeRaw turns off echo, line mode, signals and input translation, and keeps output processing" {
    if (!supported) return error.SkipZigTest;
    var base = std.mem.zeroes(posix.termios);
    base.iflag.BRKINT = true;
    base.iflag.ICRNL = true;
    base.iflag.INPCK = true;
    base.iflag.ISTRIP = true;
    base.iflag.IXON = true;
    base.oflag.OPOST = true;
    base.lflag.ECHO = true;
    base.lflag.ICANON = true;
    base.lflag.IEXTEN = true;
    base.lflag.ISIG = true;
    const raw = makeRaw(base);
    try testing.expect(!raw.iflag.BRKINT);
    try testing.expect(!raw.iflag.ICRNL);
    try testing.expect(!raw.iflag.INPCK);
    try testing.expect(!raw.iflag.ISTRIP);
    try testing.expect(!raw.iflag.IXON);
    try testing.expect(raw.oflag.OPOST);
    try testing.expect(!raw.lflag.ECHO);
    try testing.expect(!raw.lflag.ICANON);
    try testing.expect(!raw.lflag.IEXTEN);
    try testing.expect(!raw.lflag.ISIG);
    try testing.expectEqual(posix.CSIZE.CS8, raw.cflag.CSIZE);
    try testing.expectEqual(@as(u8, 1), raw.cc[@backingInt(posix.V.MIN)]);
    try testing.expectEqual(@as(u8, 0), raw.cc[@backingInt(posix.V.TIME)]);
}

test "enter refuses an input that is not a terminal, and leaves nothing active" {
    if (!supported) return error.SkipZigTest;
    // /dev/null は端末ではない。
    const fd = try posix.openatZ(posix.AT.FDCWD, "/dev/null", .{ .ACCMODE = .RDWR }, 0);
    defer _ = posix.system.close(fd);
    try testing.expectError(error.NotATerminal, RawMode.enter(fd));
    try testing.expect(active_fd.load(.acquire) < 0);
    try testing.expectEqual(@as(?u16, null), columns(fd));
}

/// A pseudo terminal pair for the tests (Linux only). The slave side is the terminal under test.
const Pty = struct {
    master: posix.fd_t,
    slave: posix.fd_t,

    fn open() !Pty {
        if (builtin.os.tag != .linux) return error.SkipZigTest;
        const master = posix.openatZ(posix.AT.FDCWD, "/dev/ptmx", .{ .ACCMODE = .RDWR, .NOCTTY = true }, 0) catch return error.SkipZigTest;
        errdefer _ = posix.system.close(master);
        var unlock: c_int = 0;
        if (std.os.linux.ioctl(master, std.os.linux.T.IOCSPTLCK, @intFromPtr(&unlock)) != 0) return error.SkipZigTest;
        var n: c_uint = 0;
        if (std.os.linux.ioctl(master, std.os.linux.T.IOCGPTN, @intFromPtr(&n)) != 0) return error.SkipZigTest;
        var path_buf: [32]u8 = undefined;
        const path = std.fmt.bufPrintSentinel(&path_buf, "/dev/pts/{d}", .{n}, 0) catch unreachable;
        const slave = posix.openatZ(posix.AT.FDCWD, path, .{ .ACCMODE = .RDWR, .NOCTTY = true }, 0) catch return error.SkipZigTest;
        return .{ .master = master, .slave = slave };
    }

    fn close(self: Pty) void {
        _ = posix.system.close(self.slave);
        _ = posix.system.close(self.master);
    }

    fn setSize(self: Pty, rows: u16, cols: u16) !void {
        var ws: posix.winsize = .{ .row = rows, .col = cols, .xpixel = 0, .ypixel = 0 };
        if (std.os.linux.ioctl(self.slave, posix.T.IOCSWINSZ, @intFromPtr(&ws)) != 0) return error.SkipZigTest;
    }
};

test "on a pseudo terminal, enter switches to raw mode and leave restores every attribute" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const pty = try Pty.open();
    defer pty.close();
    const before = try posix.tcgetattr(pty.slave);
    var raw = try RawMode.enter(pty.slave);
    const during = try posix.tcgetattr(pty.slave);
    try testing.expect(!during.lflag.ICANON);
    try testing.expect(!during.lflag.ECHO);
    try testing.expect(!during.lflag.ISIG);
    try testing.expect(!during.iflag.ICRNL);
    // 二重に有効にはできない。
    try testing.expectError(error.AlreadyActive, RawMode.enter(pty.slave));
    raw.leave();
    const after = try posix.tcgetattr(pty.slave);
    try testing.expectEqualSlices(u8, std.mem.asBytes(&before), std.mem.asBytes(&after));
    // leave は何度でも呼べ、そのあとにまた入れる。
    raw.leave();
    var again = try RawMode.enter(pty.slave);
    again.leave();
}

test "on a pseudo terminal, read returns the bytes typed, unchanged, without waiting for a newline" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const pty = try Pty.open();
    defer pty.close();
    var raw = try RawMode.enter(pty.slave);
    defer raw.leave();
    // Ctrl-C(0x03)、Ctrl-A、Enter(0x0D)は、変換も信号もなしにそのまま届く。
    const typed = "\x03\x01\r\x1b[A";
    try testing.expectEqual(typed.len, std.os.linux.write(pty.master, typed.ptr, typed.len));
    var buf: [16]u8 = undefined;
    var got: usize = 0;
    while (got < typed.len) got += try raw.read(buf[got..]);
    try testing.expectEqualSlices(u8, typed, buf[0..got]);
}

test "columns reads the width of a pseudo terminal, and null when it reports 0" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const pty = try Pty.open();
    defer pty.close();
    try pty.setSize(24, 132);
    try testing.expectEqual(@as(?u16, 132), columns(pty.slave));
    try pty.setSize(24, 0);
    try testing.expectEqual(@as(?u16, null), columns(pty.slave));
}

test "restoreActive puts the terminal back, as the signal handler and a panic hook do" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const pty = try Pty.open();
    defer pty.close();
    const before = try posix.tcgetattr(pty.slave);
    var raw = try RawMode.enter(pty.slave);
    defer raw.leave();
    restoreActive();
    const after = try posix.tcgetattr(pty.slave);
    try testing.expectEqualSlices(u8, std.mem.asBytes(&before), std.mem.asBytes(&after));
}

test "restoreActive does nothing when raw mode is not active" {
    restoreActive();
}

test "a second leave on a finished RawMode does not disturb the raw mode that is active now" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const pty = try Pty.open();
    defer pty.close();
    var first = try RawMode.enter(pty.slave);
    first.leave();
    var second = try RawMode.enter(pty.slave);
    defer second.leave();
    first.leave();
    try testing.expect(active_fd.load(.acquire) >= 0);
    try testing.expect(!(try posix.tcgetattr(pty.slave)).lflag.ICANON);
}

test "enter installs the signal handlers and leave puts the previous ones back" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const pty = try Pty.open();
    defer pty.close();
    // 前のテストの影響を受けないよう、既定の動作に揃えてから始める。
    const dfl: posix.Sigaction = .{ .handler = .{ .handler = posix.SIG.DFL }, .mask = posix.sigemptyset(), .flags = 0 };
    posix.sigaction(.TERM, &dfl, null);
    var raw = try RawMode.enter(pty.slave);
    var during: posix.Sigaction = undefined;
    posix.sigaction(.TERM, null, &during);
    try testing.expect(during.handler.handler == onFatalSignal);
    raw.leave();
    var after: posix.Sigaction = undefined;
    posix.sigaction(.TERM, null, &after);
    try testing.expect(after.handler.handler == posix.SIG.DFL);
}

test "a signal that was ignored when raw mode began stays ignored, during and after" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const pty = try Pty.open();
    defer pty.close();
    const ign: posix.Sigaction = .{ .handler = .{ .handler = posix.SIG.IGN }, .mask = posix.sigemptyset(), .flags = 0 };
    const dfl: posix.Sigaction = .{ .handler = .{ .handler = posix.SIG.DFL }, .mask = posix.sigemptyset(), .flags = 0 };
    posix.sigaction(.HUP, &ign, null);
    defer posix.sigaction(.HUP, &dfl, null);
    var raw = try RawMode.enter(pty.slave);
    var during: posix.Sigaction = undefined;
    posix.sigaction(.HUP, null, &during);
    try testing.expect(during.handler.handler == posix.SIG.IGN);
    raw.leave();
    var after: posix.Sigaction = undefined;
    posix.sigaction(.HUP, null, &after);
    try testing.expect(after.handler.handler == posix.SIG.IGN);
}

test "a fatal signal puts the terminal back and then ends the process by that signal" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const linux = std.os.linux;
    // 一覧を `fatal_signals` から取らない(一覧から信号が落ちたときに、このテストが落ちるように)。
    for ([_]posix.SIG{ .INT, .TERM, .HUP, .QUIT }) |sig| {
        const pty = try Pty.open();
        defer pty.close();
        const before = try posix.tcgetattr(pty.slave);
        const rc = linux.fork();
        if (posix.errno(rc) != .SUCCESS) return error.SkipZigTest;
        if (rc == 0) {
            // 子: 生モードに入り、自分に信号を送る。ハンドラが戻して、同じ信号で死ぬはずである。
            // 何かが違えば、信号で死なずに、終了の状態 99 で終わる。
            _ = RawMode.enter(pty.slave) catch linux.exit_group(98);
            _ = linux.kill(linux.getpid(), sig);
            linux.exit_group(99);
        }
        var status: i32 = 0;
        try testing.expectEqual(rc, linux.waitpid(@intCast(rc), &status, 0));
        const st: u32 = @bitCast(status);
        try testing.expect(linux.W.IFSIGNALED(st));
        try testing.expectEqual(sig, linux.W.TERMSIG(st));
        const after = try posix.tcgetattr(pty.slave);
        try testing.expectEqualSlices(u8, std.mem.asBytes(&before), std.mem.asBytes(&after));
    }
}
