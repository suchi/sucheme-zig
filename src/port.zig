//! Reading from and writing to ports (R7RS 6.13).
//!
//! ポートの手続き(`prim/port.zig`)と、後のスライスの `read`(5l)とプリンタ(5j)が、ここを通して
//! ポートを読み書きする。今の裏付けは、文字列ポートとバイトベクタポートの `memory` だけである
//! (docs/plans/0019-phase5-ports-and-io.md)。
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
    port.backing.memory.pos += next.width;
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
    port.backing.memory.pos += 1;
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
    const memory = &port.backing.memory;
    return memory.bytes[memory.pos..memory.len];
}

/// Reads past `n` of the bytes `pending` gives, which for a textual port must end
/// at the boundary of a character.
pub fn consume(port: *Port, n: usize) void {
    const memory = &port.backing.memory;
    std.debug.assert(n <= memory.len - memory.pos);
    memory.pos += n;
}

/// Appends `bytes` to the output port `port`; for a textual port they must be
/// valid UTF-8, which the caller has checked.
///
/// Why: 領域は倍ずつ伸ばす。1文字ずつ書くプログラムでも、写しの量が書いた量に比例する。
/// 倍に伸ばすと上限を超えるときは、要る分だけで伸ばし直す。上限の近くで、収まるはずの
/// 書き込みが断られないようにするためである。どちらの失敗でも、ポートは元のままである
/// (`Heap.growPortBytes`)。
pub fn writeBytes(heap: *Heap, port: *Port, bytes: []const u8) Error!void {
    if (port.direction != .output) return error.WrongDirection;
    if (!port.open) return error.PortClosed;
    const memory = &port.backing.memory;
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

/// What has been written to the output port `port`.
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
    try writeBytes(&f.heap, p, "ab");
    try writeBytes(&f.heap, p, "");
    try writeBytes(&f.heap, p, "λ");
    try std.testing.expectEqualStrings("abλ", written(p));
    // 1バイトずつ多く書いても、伸ばすのは倍ずつなので、確保の回数は書いた量の対数で済む。
    const q = try f.output(.binary);
    for (0..1000) |i| try writeBytes(&f.heap, q, &.{@truncate(i)});
    try std.testing.expectEqual(1000, written(q).len);
    for (written(q), 0..) |b, i| try std.testing.expectEqual(@as(u8, @truncate(i)), b);
    try std.testing.expect(q.backing.memory.bytes.len < 2 * 1000 + 64);
}

test "writeBytes refuses an input port and a closed port, and leaves the port as it was" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    const in = try f.input(.binary, "a");
    try std.testing.expectError(error.WrongDirection, writeBytes(&f.heap, in, "x"));
    const out = try f.output(.binary);
    try writeBytes(&f.heap, out, "a");
    close(out);
    try std.testing.expectError(error.PortClosed, writeBytes(&f.heap, out, "x"));
    try std.testing.expectEqualStrings("a", written(out));
}

test "writeBytes at the limit of the heap reports the limit and keeps what was written" {
    const limit = heap_mod.cellBytes(Port) + 16;
    var heap: Heap = .init(std.testing.allocator, .{ .limit = limit });
    defer heap.deinit();
    const p = try heap.createMemoryPort(.output, .binary, "");
    try writeBytes(&heap, p, "0123456789");
    // 倍の 20 バイトには伸ばせないが、要る 16 バイトなら上限に収まるので、書き込みは通る。
    try writeBytes(&heap, p, "abcdef");
    try std.testing.expectEqualStrings("0123456789abcdef", written(p));
    try std.testing.expectEqual(limit, heap.accounted);
    try std.testing.expectError(error.HeapLimit, writeBytes(&heap, p, "x"));
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
