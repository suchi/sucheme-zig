//! Reading from and writing to ports (R7RS 6.13).
//!
//! ポートの手続き(`prim/port.zig`)と、後のスライスの `read`(5l)とプリンタ(5j)が、ここを通して
//! ポートを読み書きする。今の裏付けは、文字列ポートとバイトベクタポートの `memory` と、コンソールの
//! `console` である(docs/plans/0019-phase5-ports-and-io.md)。
//!
//! コンソールの出力ポート(標準出力と標準エラー)は、書いたバイトを、そのまま `sink` に書く。
//! 領域を持たないので、評価の結果の表示と同じ書き手に、書いた順に並ぶ。コンソールの入力ポートは、
//! スライス 5i では、最初から終わりにある(標準入力を読むのは 5l)。
//!
//! `Port.Memory` の `pos <= len <= bytes.len` は、型では保証されない。ここの関数が保つ。
//! 入力のポートは、開いたときの写しを最後まで使い、伸ばさない。出力のポートは、書くたびに
//! `Heap.growPortBytes` で領域を伸ばし、`len` までがデータである。`len` より後ろは初期化されて
//! いない。

const std = @import("std");
const value = @import("value.zig");
const Port = value.Port;
const heap_mod = @import("heap.zig");
const Heap = heap_mod.Heap;

pub const Error = heap_mod.Error || error{
    /// The port has been closed (R7RS 6.13.1 `close-port`).
    PortClosed,
    /// An input operation on an output port, or the other way round.
    WrongDirection,
    /// A character operation on a binary port, or a byte operation on a textual one.
    WrongKind,
    /// The writer the console writes to could not take the bytes.
    WriteFailed,
};

/// Checks that `port` is open, flows in `direction` and carries `element`.
/// 検査の順序は、向き、種類、開閉である。閉じた出力ポートに読みに行ったら、向きの誤りになる。
fn check(port: *const Port, direction: Port.Direction, element: Port.Element) Error!void {
    if (port.direction != direction) return error.WrongDirection;
    if (port.element != element) return error.WrongKind;
    if (!port.open) return error.PortClosed;
}

/// The next character of the textual input port `port`, which it reads past, or
/// null at the end.
/// `heap` は、ファイルのポートが入力を足すとき(5k)に使う。文字列ポートでは使わない。
pub fn readChar(heap: *Heap, port: *Port) Error!?u21 {
    const next = try peekCharWidth(heap, port) orelse return null;
    consume(port, next.width);
    return next.char;
}

/// The next character of the textual input port `port`, without reading past it,
/// or null at the end.
pub fn peekChar(heap: *Heap, port: *Port) Error!?u21 {
    const next = try peekCharWidth(heap, port) orelse return null;
    return next.char;
}

/// The next character and the bytes it takes.
/// テキストのポートのバイト列は、開いたときに妥当な UTF-8 である(`Heap.createMemoryPort`)。
/// 読む位置は文字の境目にしか置かないので、ここで復号に失敗することはない。
fn peekCharWidth(heap: *Heap, port: *Port) Error!?struct { char: u21, width: usize } {
    _ = heap;
    try check(port, .input, .textual);
    const rest = pending(port);
    if (rest.len == 0) return null;
    const width = std.unicode.utf8ByteSequenceLength(rest[0]) catch unreachable;
    const char = std.unicode.utf8Decode(rest[0..width]) catch unreachable;
    return .{ .char = char, .width = width };
}

/// The next byte of the binary input port `port`, which it reads past, or null at
/// the end.
pub fn readByte(heap: *Heap, port: *Port) Error!?u8 {
    const byte = try peekByte(heap, port) orelse return null;
    consume(port, 1);
    return byte;
}

/// The next byte of the binary input port `port`, without reading past it, or
/// null at the end.
pub fn peekByte(heap: *Heap, port: *Port) Error!?u8 {
    _ = heap;
    try check(port, .input, .binary);
    const rest = pending(port);
    if (rest.len == 0) return null;
    return rest[0];
}

/// The bytes of the input port `port` that have not been read.
/// 向きと開閉は、呼び出し側が先に検査する。
pub fn pending(port: *const Port) []const u8 {
    return switch (port.backing) {
        .memory => |*memory| memory.bytes[memory.pos..memory.len],
        // 標準入力は、5i では最初から終わりにある。
        .console => "",
    };
}

/// Reads past `n` of the bytes `pending` gives, which for a textual port must end
/// at the boundary of a character.
pub fn consume(port: *Port, n: usize) void {
    switch (port.backing) {
        .memory => |*memory| {
            std.debug.assert(n <= memory.len - memory.pos);
            memory.pos += n;
        },
        .console => std.debug.assert(n == 0),
    }
}

/// Appends `bytes` to the output port `port`; for a textual port they must be
/// valid UTF-8, which the caller has checked.
///
/// Why: 領域は倍ずつ伸ばす。1文字ずつ書くプログラムでも、写しの量が書いた量に比例する。
/// 倍に伸ばすと上限を超えるときは、要る分だけで伸ばし直す。上限の近くで、収まるはずの
/// 書き込みが断られないようにするためである。どちらの失敗でも、ポートは元のままである
/// (`Heap.growPortBytes`)。
///
/// コンソールのポートは、`sink` に書く。`sink` が null(コンソールを持たない単体テスト)なら、
/// 書いたものは捨てる。
pub fn writeBytes(heap: *Heap, sink: ?*std.Io.Writer, port: *Port, bytes: []const u8) Error!void {
    if (port.direction != .output) return error.WrongDirection;
    if (!port.open) return error.PortClosed;
    const memory = switch (port.backing) {
        .memory => |*memory| memory,
        .console => {
            if (sink) |w| w.writeAll(bytes) catch return error.WriteFailed;
            return;
        },
    };
    const needed = std.math.add(usize, memory.len, bytes.len) catch return error.HeapLimit;
    if (needed > memory.bytes.len) {
        const doubled = std.math.mul(usize, memory.bytes.len, 2) catch needed;
        heap.growPortBytes(port, @max(needed, doubled)) catch |e| switch (e) {
            error.HeapLimit => try heap.growPortBytes(port, needed),
            error.OutOfMemory => return e,
        };
    }
    @memcpy(memory.bytes[memory.len..needed], bytes);
    memory.len = needed;
}

/// What has been written to the output port `port`, which must be a string or a
/// bytevector port.
pub fn written(port: *const Port) []const u8 {
    const memory = &port.backing.memory;
    return memory.bytes[0..memory.len];
}

/// Closes `port`; closing a closed port does nothing (R7RS 6.13.1).
/// 文字列ポートとバイトベクタポートの領域は、閉じても回収まで残る。`get-output-string` は、
/// 閉じたあとも読める。
pub fn close(port: *Port) void {
    port.open = false;
}

test {
    std.testing.refAllDecls(@This());
}

/// An open input port of `element` holding `contents`, made on a heap that `deinit` frees.
const Fixture = struct {
    heap: Heap,

    fn init(self: *Fixture) void {
        self.heap = .init(std.testing.allocator, .{});
    }

    fn deinit(self: *Fixture) void {
        self.heap.deinit();
    }

    fn input(self: *Fixture, element: Port.Element, contents: []const u8) !*Port {
        return self.heap.createMemoryPort(.input, element, contents);
    }

    fn output(self: *Fixture, element: Port.Element) !*Port {
        return self.heap.createMemoryPort(.output, element, "");
    }
};

test "readChar reads the characters of a textual input port in order, and null at the end" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    const p = try f.input(.textual, "aλ😀");
    try std.testing.expectEqual('a', (try readChar(&f.heap, p)).?);
    try std.testing.expectEqual(0x3BB, (try readChar(&f.heap, p)).?);
    try std.testing.expectEqual(0x1F600, (try readChar(&f.heap, p)).?);
    try std.testing.expectEqual(null, try readChar(&f.heap, p));
    // 終わりに着いたあとも、null を返し続ける。
    try std.testing.expectEqual(null, try readChar(&f.heap, p));
}

test "peekChar gives the next character without moving past it" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    const p = try f.input(.textual, "λb");
    try std.testing.expectEqual(0x3BB, (try peekChar(&f.heap, p)).?);
    try std.testing.expectEqual(0x3BB, (try peekChar(&f.heap, p)).?);
    try std.testing.expectEqual(0x3BB, (try readChar(&f.heap, p)).?);
    try std.testing.expectEqual('b', (try peekChar(&f.heap, p)).?);
    try std.testing.expectEqual('b', (try readChar(&f.heap, p)).?);
    try std.testing.expectEqual(null, try peekChar(&f.heap, p));
}

test "readByte and peekByte read the bytes of a binary input port, and null at the end" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    const p = try f.input(.binary, &.{ 0, 255 });
    try std.testing.expectEqual(0, (try peekByte(&f.heap, p)).?);
    try std.testing.expectEqual(0, (try readByte(&f.heap, p)).?);
    try std.testing.expectEqual(255, (try readByte(&f.heap, p)).?);
    try std.testing.expectEqual(null, try peekByte(&f.heap, p));
    try std.testing.expectEqual(null, try readByte(&f.heap, p));
}

test "the reading functions refuse a port of the other kind, an output port and a closed port" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    const text = try f.input(.textual, "a");
    const bytes = try f.input(.binary, "a");
    try std.testing.expectError(error.WrongKind, readByte(&f.heap, text));
    try std.testing.expectError(error.WrongKind, peekByte(&f.heap, text));
    try std.testing.expectError(error.WrongKind, readChar(&f.heap, bytes));
    try std.testing.expectError(error.WrongKind, peekChar(&f.heap, bytes));
    const out = try f.output(.textual);
    try std.testing.expectError(error.WrongDirection, readChar(&f.heap, out));
    try std.testing.expectError(error.WrongDirection, peekChar(&f.heap, out));
    close(text);
    try std.testing.expectError(error.PortClosed, readChar(&f.heap, text));
    try std.testing.expectError(error.PortClosed, peekChar(&f.heap, text));
    close(bytes);
    try std.testing.expectError(error.PortClosed, readByte(&f.heap, bytes));
    try std.testing.expectError(error.PortClosed, peekByte(&f.heap, bytes));
    // 何も読まなかったので、位置は動いていない。
    try std.testing.expectEqual(0, text.backing.memory.pos);
}

test "pending is what is left to read, and consume moves past part of it" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    const p = try f.input(.textual, "abc");
    try std.testing.expectEqualStrings("abc", pending(p));
    consume(p, 2);
    try std.testing.expectEqualStrings("c", pending(p));
    try std.testing.expectEqual('c', (try readChar(&f.heap, p)).?);
    try std.testing.expectEqualStrings("", pending(p));
}

test "writeBytes appends to an output port, growing it, and keeps what was written" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    const p = try f.output(.textual);
    try writeBytes(&f.heap, null, p, "ab");
    try writeBytes(&f.heap, null, p, "");
    try writeBytes(&f.heap, null, p, "λ");
    try std.testing.expectEqualStrings("abλ", written(p));
    // 1バイトずつ多く書いても、伸ばすのは倍ずつなので、確保の回数は書いた量の対数で済む。
    const q = try f.output(.binary);
    for (0..1000) |i| try writeBytes(&f.heap, null, q, &.{@truncate(i)});
    try std.testing.expectEqual(1000, written(q).len);
    for (written(q), 0..) |b, i| try std.testing.expectEqual(@as(u8, @truncate(i)), b);
    try std.testing.expect(q.backing.memory.bytes.len < 2 * 1000 + 64);
}

test "writeBytes refuses an input port and a closed port, and leaves the port as it was" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    const in = try f.input(.binary, "a");
    try std.testing.expectError(error.WrongDirection, writeBytes(&f.heap, null, in, "x"));
    const out = try f.output(.binary);
    try writeBytes(&f.heap, null, out, "a");
    close(out);
    try std.testing.expectError(error.PortClosed, writeBytes(&f.heap, null, out, "x"));
    try std.testing.expectEqualStrings("a", written(out));
}

test "writeBytes at the limit of the heap reports the limit and keeps what was written" {
    const limit = heap_mod.cellBytes(Port) + 16;
    var heap: Heap = .init(std.testing.allocator, .{ .limit = limit });
    defer heap.deinit();
    const p = try heap.createMemoryPort(.output, .binary, "");
    try writeBytes(&heap, null, p, "0123456789");
    // 倍の 20 バイトには伸ばせないが、要る 16 バイトなら上限に収まるので、書き込みは通る。
    try writeBytes(&heap, null, p, "abcdef");
    try std.testing.expectEqualStrings("0123456789abcdef", written(p));
    try std.testing.expectEqual(limit, heap.accounted);
    try std.testing.expectError(error.HeapLimit, writeBytes(&heap, null, p, "x"));
    try std.testing.expectEqualStrings("0123456789abcdef", written(p));
    try std.testing.expectEqual(limit, heap.accounted);
}

test "close closes a port of either direction, and closing it again does nothing" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    const in = try f.input(.textual, "a");
    const out = try f.output(.textual);
    close(in);
    close(in);
    close(out);
    try std.testing.expect(!in.open);
    try std.testing.expect(!out.open);
}

test "writeBytes regrows the storage a number of times that is logarithmic in what was written" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    const p = try f.output(.binary);
    var regrowths: usize = 0;
    var capacity = p.backing.memory.bytes.len;
    for (0..1000) |_| {
        try writeBytes(&f.heap, null, p, "x");
        if (p.backing.memory.bytes.len != capacity) {
            regrowths += 1;
            capacity = p.backing.memory.bytes.len;
        }
    }
    // 倍ずつなら 1、2、4、...、1024 の 11 回である。要る分だけ伸ばすと 1000 回になる。
    try std.testing.expect(regrowths <= 16);
}

test "the reading functions check the direction, then the kind, then whether the port is open" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    const out = try f.output(.binary);
    close(out);
    // 閉じた出力のポートは、向きの誤りである。
    try std.testing.expectError(error.WrongDirection, readChar(&f.heap, out));
    const bytes = try f.input(.binary, "a");
    close(bytes);
    try std.testing.expectError(error.WrongKind, readChar(&f.heap, bytes));
    const text = try f.input(.textual, "a");
    close(text);
    try std.testing.expectError(error.WrongKind, readByte(&f.heap, text));
}

test "a console output port writes to the sink as it is written to, and to nothing without one" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    const out = try f.heap.createConsolePort(.output);
    const err = try f.heap.createConsolePort(.error_output);
    var buf: [16]u8 = undefined;
    var sink: std.Io.Writer = .fixed(&buf);
    try writeBytes(&f.heap, &sink, out, "ab");
    try writeBytes(&f.heap, &sink, err, "λ");
    try writeBytes(&f.heap, &sink, out, "c");
    try std.testing.expectEqualStrings("abλc", sink.buffered());
    // 書き手が無ければ捨てる。領域を持たないので、計上は変わらない。
    const before = f.heap.accounted;
    try writeBytes(&f.heap, null, out, "dropped");
    try std.testing.expectEqual(before, f.heap.accounted);
    try std.testing.expectEqualStrings("abλc", sink.buffered());
    // 閉じたら書けない。
    close(out);
    try std.testing.expectError(error.PortClosed, writeBytes(&f.heap, &sink, out, "x"));
}

test "a console output port reports a writer that cannot take the bytes" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    const out = try f.heap.createConsolePort(.output);
    var buf: [2]u8 = undefined;
    var sink: std.Io.Writer = .fixed(&buf);
    try std.testing.expectError(error.WriteFailed, writeBytes(&f.heap, &sink, out, "abc"));
}

test "the console input port is at its end from the start" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    const in = try f.heap.createConsolePort(.input);
    try std.testing.expectEqual(null, try readChar(&f.heap, in));
    try std.testing.expectEqual(null, try peekChar(&f.heap, in));
    try std.testing.expectEqualStrings("", pending(in));
    consume(in, 0);
    try std.testing.expectError(error.WrongKind, readByte(&f.heap, in));
    try std.testing.expectError(error.WrongDirection, writeBytes(&f.heap, null, in, "x"));
}
