//! Reading from and writing to ports (R7RS 6.13).
//!
//! ポートの手続き(`prim/port.zig`)と、後のスライスの `read`(5l)とプリンタ(5j)が、ここを通して
//! ポートを読み書きする。今の裏付けは、文字列ポートとバイトベクタポートの `memory` と、コンソールの
//! `console` と、ファイルの `file` である(docs/plans/0019-phase5-ports-and-io.md)。
//!
//! ファイルのポートは、固定の大きさのバッファを通して、ホストの表(`Heap.files`)のファイルを
//! 読み書きする。入力は、バッファが尽きたら `fill` で足す。出力は、バッファが満ちたとき、
//! `flush` のとき、閉じるときに書き出す。`Port.File` の `pos <= len <= buffer.len` は、
//! ここの関数が保つ。
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
    /// The host could not read from or write to the file of a file port.
    Io,
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

/// The character that stands for bytes that are not UTF-8.
pub const replacement_char: u21 = 0xFFFD;

/// The next character and the bytes it takes.
/// 文字列ポートのバイト列は、開いたときに妥当な UTF-8 である(`Heap.createMemoryPort`)。
/// ファイルの中身は選べないので、UTF-8 として読めないバイトは、1バイトずつ置換文字
/// (U+FFFD)として読む。ファイルの末尾で途切れた列も同じである。ファイルのポートは、
/// 1文字のバイトが手元にそろうまで `fill` で足す。
fn peekCharWidth(heap: *Heap, port: *Port) Error!?struct { char: u21, width: usize } {
    try check(port, .input, .textual);
    var rest = pending(port);
    if (rest.len == 0) {
        if (!try fill(heap, port)) return null;
        rest = pending(port);
    }
    const width = std.unicode.utf8ByteSequenceLength(rest[0]) catch return .{ .char = replacement_char, .width = 1 };
    while (rest.len < width) {
        if (!try fill(heap, port)) return .{ .char = replacement_char, .width = 1 };
        rest = pending(port);
    }
    const char = std.unicode.utf8Decode(rest[0..width]) catch return .{ .char = replacement_char, .width = 1 };
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
    try check(port, .input, .binary);
    var rest = pending(port);
    if (rest.len == 0) {
        if (!try fill(heap, port)) return null;
        rest = pending(port);
    }
    return rest[0];
}

/// The bytes of the input port `port` that have not been read, of those it holds.
/// 向きと開閉は、呼び出し側が先に検査する。ファイルのポートでは、バッファにある分だけで、
/// 空でもファイルの終わりとは限らない(`fill` で足す)。
pub fn pending(port: *const Port) []const u8 {
    return switch (port.backing) {
        .memory => |*memory| memory.bytes[memory.pos..memory.len],
        // 標準入力は、5i では最初から終わりにある。
        .console => "",
        .file => |*file| file.buffer[file.pos..file.len],
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
        .file => |*file| {
            std.debug.assert(n <= file.len - file.pos);
            file.pos += n;
        },
    }
}

/// Adds to what the open input port `port` holds from its source, and gives
/// whether it added anything: false at the end.
/// 文字列ポートとバイトベクタポートは、開いたときにすべてを持つので、足すものが無い。
/// ファイルのポートは、読んでいない分をバッファの頭に寄せてから、空いた所に読む。
/// バッファが読んでいない分で埋まっていてはならない(`peekCharWidth` は高々4バイトを待つ)。
/// 終わりに着いたあとは、ファイルを読まずに false を返す。
pub fn fill(heap: *Heap, port: *Port) Error!bool {
    const file = switch (port.backing) {
        .memory, .console => return false,
        .file => |*file| file,
    };
    if (file.at_end) return false;
    const unread = file.len - file.pos;
    std.mem.copyForwards(u8, file.buffer[0..unread], file.buffer[file.pos..file.len]);
    file.pos = 0;
    file.len = unread;
    std.debug.assert(file.len < file.buffer.len);
    const host = heap.files.?;
    const n = try host.read(host.context, file.id, file.buffer[file.len..]);
    if (n == 0) {
        file.at_end = true;
        return false;
    }
    file.len += n;
    return true;
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
        .file => |*file| return writeFile(heap, file, bytes),
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

/// Puts `bytes` in the buffer of a file output port, writing out the buffer first
/// when they do not fit.
/// バッファより大きい書き込みは、バッファを書き出してから、写さずに直接書く。
fn writeFile(heap: *Heap, file: *Port.File, bytes: []const u8) Error!void {
    if (bytes.len <= file.buffer.len - file.len) {
        @memcpy(file.buffer[file.len..][0..bytes.len], bytes);
        file.len += bytes.len;
        return;
    }
    try writeOut(heap, file);
    if (bytes.len < file.buffer.len) {
        @memcpy(file.buffer[0..bytes.len], bytes);
        file.len = bytes.len;
        return;
    }
    const host = heap.files.?;
    try host.write(host.context, file.id, bytes);
}

/// Writes what the buffer of a file output port holds to its file, and empties
/// the buffer.
/// 書けなかったときは、バッファをそのまま残す。
fn writeOut(heap: *Heap, file: *Port.File) Error!void {
    if (file.len == 0) return;
    const host = heap.files.?;
    try host.write(host.context, file.id, file.buffer[0..file.len]);
    file.len = 0;
}

/// Writes out what the open output port `port` holds for its destination
/// (R7RS 6.13.3 `flush-output-port`).
/// ためておくのは、ファイルのポートだけである。コンソールの書き手を書き出すのは、呼び出し側
/// である(`prim/port.zig` の `flush-output-port`)。
pub fn flush(heap: *Heap, port: *Port) Error!void {
    if (port.direction != .output) return error.WrongDirection;
    if (!port.open) return error.PortClosed;
    switch (port.backing) {
        .memory, .console => {},
        .file => |*file| try writeOut(heap, file),
    }
}

/// Closes `port`; closing a closed port does nothing (R7RS 6.13.1).
/// 文字列ポートとバイトベクタポートの領域は、閉じても回収まで残る。`get-output-string` は、
/// 閉じたあとも読める。ファイルのポートは、ためた出力を書き出してから、ファイルを閉じる。
/// 書き出せなかったときも、ファイルは閉じ、ためた出力は捨てて、`Io` を返す。
pub fn close(heap: *Heap, port: *Port) Error!void {
    if (!port.open) return;
    switch (port.backing) {
        .memory, .console => port.open = false,
        .file => |*file| {
            const written_out = if (port.direction == .output) writeOut(heap, file) else {};
            file.len = 0;
            heap.closeFile(port);
            try written_out;
        },
    }
}

/// A `std.Io.Writer` that writes to the output port `port` through `writeBytes`, for
/// the printer (`display`, and `write` in slice 5j).
/// Why: プリンタの出力を作業領域にまとめてから写すと、大きなデータの `display` が、その大きさの
/// 領域をヒープの計上の外に取る。書き手の小さな領域(`buffer`)にためては、ポートに書く。
/// `writeBytes` の失敗は `failure` に残し、書き手には `WriteFailed` として返す。呼び出し側は、
/// `failure` を見て、元の誤り(上限、閉じたポートなど)を報告する。終わりに `interface.flush()` を
/// 呼ぶこと。
pub const Writer = struct {
    heap: *Heap,
    sink: ?*std.Io.Writer,
    port: *Port,
    failure: ?Error = null,
    interface: std.Io.Writer,

    pub fn init(heap: *Heap, sink: ?*std.Io.Writer, port: *Port, buffer: []u8) Writer {
        return .{ .heap = heap, .sink = sink, .port = port, .interface = .{ .vtable = &.{ .drain = drain }, .buffer = buffer } };
    }

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *Writer = @alignCast(@fieldParentPtr("interface", w));
        try self.put(w.buffered());
        w.end = 0;
        var n: usize = 0;
        for (data[0 .. data.len - 1]) |bytes| {
            try self.put(bytes);
            n += bytes.len;
        }
        const pattern = data[data.len - 1];
        for (0..splat) |_| {
            try self.put(pattern);
            n += pattern.len;
        }
        return n;
    }

    fn put(self: *Writer, bytes: []const u8) std.Io.Writer.Error!void {
        if (bytes.len == 0) return;
        writeBytes(self.heap, self.sink, self.port, bytes) catch |e| {
            self.failure = e;
            return error.WriteFailed;
        };
    }
};

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
    try close(&f.heap, text);
    try std.testing.expectError(error.PortClosed, readChar(&f.heap, text));
    try std.testing.expectError(error.PortClosed, peekChar(&f.heap, text));
    try close(&f.heap, bytes);
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
    try close(&f.heap, out);
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
    try close(&f.heap, in);
    try close(&f.heap, in);
    try close(&f.heap, out);
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
    try close(&f.heap, out);
    // 閉じた出力のポートは、向きの誤りである。
    try std.testing.expectError(error.WrongDirection, readChar(&f.heap, out));
    const bytes = try f.input(.binary, "a");
    try close(&f.heap, bytes);
    try std.testing.expectError(error.WrongKind, readChar(&f.heap, bytes));
    const text = try f.input(.textual, "a");
    try close(&f.heap, text);
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
    try close(&f.heap, out);
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

test "the port writer writes what goes through it to the port, in order, past its small buffer" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    const p = try f.output(.textual);
    var buf: [4]u8 = undefined;
    var w: Writer = .init(&f.heap, null, p, &buf);
    try w.interface.writeAll("ab");
    try w.interface.writeAll("cdefgh");
    try w.interface.print("{d}", .{12345});
    try w.interface.splatByteAll('z', 3);
    try w.interface.flush();
    try std.testing.expectEqualStrings("abcdefgh12345zzz", written(p));
    try std.testing.expectEqual(null, w.failure);
}

test "the port writer writes a vector and a splat larger than its buffer once each" {
    // `drain` が、繰り返しの全回と、繰り返しより前の要素を書き、その数を返すことを固定する。
    // 返す数が足りないと、`writeVecAll` と `writeSplatAll` が同じ要素を二度書く。
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    const p = try f.output(.textual);
    var buf: [4]u8 = undefined;
    var w: Writer = .init(&f.heap, null, p, &buf);
    var vec = [_][]const u8{ "12", "345", "6789" };
    try w.interface.writeVecAll(&vec);
    var splat = [_][]const u8{ "x", "ab" };
    try w.interface.writeSplatAll(&splat, 5);
    try w.interface.flush();
    try std.testing.expectEqualStrings("123456789xababababab", written(p));
    try std.testing.expectEqual(null, w.failure);
    // バッファに残っていた分は、返す数に入れない。入れると、呼び出し側が繰り返しの残りを
    // 数え誤る(安全検査のある版では整数の桁あふれで止まる)。
    const q = try f.output(.textual);
    var w2: Writer = .init(&f.heap, null, q, &buf);
    try w2.interface.writeAll("ab");
    try w2.interface.splatByteAll('z', 10);
    try w2.interface.flush();
    try std.testing.expectEqualStrings("abzzzzzzzzzz", written(q));
}

test "the port writer keeps the error of the port, and reports WriteFailed to the printer" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    const p = try f.output(.textual);
    try close(&f.heap, p);
    var buf: [4]u8 = undefined;
    var w: Writer = .init(&f.heap, null, p, &buf);
    try std.testing.expectError(error.WriteFailed, w.interface.writeAll("abcdef"));
    try std.testing.expectEqual(error.PortClosed, w.failure.?);
    // 上限で伸ばせないときも、上限の誤りが残る。
    var heap: Heap = .init(std.testing.allocator, .{ .limit = heap_mod.cellBytes(Port) + 4 });
    defer heap.deinit();
    const q = try heap.createMemoryPort(.output, .binary, "");
    var w2: Writer = .init(&heap, null, q, &buf);
    try w2.interface.writeAll("abc");
    try std.testing.expectError(error.WriteFailed, w2.interface.writeAll("defgh"));
    try std.testing.expectEqual(error.HeapLimit, w2.failure.?);
}

/// A host with one file in memory, which gives at most `chunk` bytes a read and
/// records what is written, for the tests of file ports.
/// ヒープより先に作り、後で解放する。ヒープの解放が、開いたポートを書き出して閉じるからである。
const FakeHost = struct {
    contents: []const u8 = "",
    at: usize = 0,
    chunk: usize = 3,
    reads: usize = 0,
    written: std.ArrayList(u8) = .empty,
    writes: usize = 0,
    closed: usize = 0,
    fail: bool = false,

    fn deinit(self: *FakeHost) void {
        self.written.deinit(std.testing.allocator);
    }

    fn host(self: *FakeHost) Heap.FileHost {
        return .{ .context = self, .open = open, .delete = delete, .exists = exists, .read = read, .write = write, .close = closeIt };
    }

    fn open(_: *anyopaque, _: []const u8, _: Port.Direction) error{ Exhausted, Refused, OutOfMemory }!u32 {
        return error.Refused;
    }

    fn delete(_: *anyopaque, _: []const u8) error{Refused}!void {
        return error.Refused;
    }

    fn exists(_: *anyopaque, _: []const u8) bool {
        return false;
    }

    fn read(context: *anyopaque, _: u32, buffer: []u8) error{Io}!usize {
        const self: *FakeHost = @ptrCast(@alignCast(context));
        if (self.fail) return error.Io;
        self.reads += 1;
        const n = @min(buffer.len, self.chunk, self.contents.len - self.at);
        @memcpy(buffer[0..n], self.contents[self.at..][0..n]);
        self.at += n;
        return n;
    }

    fn write(context: *anyopaque, _: u32, bytes: []const u8) error{Io}!void {
        const self: *FakeHost = @ptrCast(@alignCast(context));
        if (self.fail) return error.Io;
        self.writes += 1;
        self.written.appendSlice(std.testing.allocator, bytes) catch return error.Io;
    }

    fn closeIt(context: *anyopaque, _: u32) void {
        const self: *FakeHost = @ptrCast(@alignCast(context));
        self.closed += 1;
    }
};

/// An open file port with a buffer of `size` bytes on `heap`, which reads from and
/// writes to `fake`.
fn openFake(heap: *Heap, fake: *FakeHost, direction: Port.Direction, element: Port.Element, size: usize) !*Port {
    heap.files = fake.host();
    const p = try heap.createFilePort(direction, element, size);
    p.open = true;
    return p;
}

test "a textual file port reads characters that cross the end of what its buffer holds" {
    var fake: FakeHost = .{ .contents = "aλ😀b" };
    defer fake.deinit();
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    const p = try openFake(&f.heap, &fake, .input, .textual, 4);
    try std.testing.expectEqual('a', (try readChar(&f.heap, p)).?);
    try std.testing.expectEqual(0x3BB, (try peekChar(&f.heap, p)).?);
    try std.testing.expectEqual(0x3BB, (try readChar(&f.heap, p)).?);
    try std.testing.expectEqual(0x1F600, (try readChar(&f.heap, p)).?);
    try std.testing.expectEqual('b', (try readChar(&f.heap, p)).?);
    try std.testing.expectEqual(null, try readChar(&f.heap, p));
    // 終わりに着いたあとは、ファイルを読まない。
    const reads = fake.reads;
    try std.testing.expectEqual(null, try peekChar(&f.heap, p));
    try std.testing.expectEqual(reads, fake.reads);
}

test "a textual file port reads each byte that is not UTF-8 as the replacement character" {
    // 続きのバイトで始まる列、続きのバイトでない後続、末尾で途切れた列。
    var fake: FakeHost = .{ .contents = "\x80a\xCE\x41\xF0\x9F" };
    defer fake.deinit();
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    const p = try openFake(&f.heap, &fake, .input, .textual, 8);
    const expected = [_]u21{ replacement_char, 'a', replacement_char, 'A', replacement_char, replacement_char };
    for (expected) |c| try std.testing.expectEqual(c, (try readChar(&f.heap, p)).?);
    try std.testing.expectEqual(null, try readChar(&f.heap, p));
}

test "a binary file port reads its bytes through a small buffer, and null at the end" {
    var fake: FakeHost = .{ .contents = &.{ 1, 2, 3, 4, 5 }, .chunk = 2 };
    defer fake.deinit();
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    const p = try openFake(&f.heap, &fake, .input, .binary, 2);
    for (1..6) |b| {
        try std.testing.expectEqual(@as(u8, @intCast(b)), (try peekByte(&f.heap, p)).?);
        try std.testing.expectEqual(@as(u8, @intCast(b)), (try readByte(&f.heap, p)).?);
    }
    try std.testing.expectEqual(null, try readByte(&f.heap, p));
    try std.testing.expect(p.backing.file.at_end);
}

test "fill keeps what has not been read, and adds nothing to a memory port" {
    var fake: FakeHost = .{ .contents = "abcdef", .chunk = 4 };
    defer fake.deinit();
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    const p = try openFake(&f.heap, &fake, .input, .binary, 5);
    try std.testing.expect(try fill(&f.heap, p));
    try std.testing.expectEqualStrings("abcd", pending(p));
    consume(p, 3);
    try std.testing.expect(try fill(&f.heap, p));
    try std.testing.expectEqualStrings("def", pending(p));
    try std.testing.expect(!try fill(&f.heap, p));
    try std.testing.expectEqualStrings("def", pending(p));
    const m = try f.input(.binary, "xy");
    try std.testing.expect(!try fill(&f.heap, m));
    try std.testing.expectEqualStrings("xy", pending(m));
}

test "a file input port reports a failure to read as Io" {
    var fake: FakeHost = .{ .contents = "a", .fail = true };
    defer fake.deinit();
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    const p = try openFake(&f.heap, &fake, .input, .textual, 4);
    try std.testing.expectError(error.Io, readChar(&f.heap, p));
    const q = try openFake(&f.heap, &fake, .input, .binary, 4);
    try std.testing.expectError(error.Io, peekByte(&f.heap, q));
}

test "a file output port keeps small writes in its buffer until it is full, flushed or closed" {
    var fake: FakeHost = .{};
    defer fake.deinit();
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    const p = try openFake(&f.heap, &fake, .output, .textual, 4);
    try writeBytes(&f.heap, null, p, "ab");
    try writeBytes(&f.heap, null, p, "cd");
    try std.testing.expectEqual(0, fake.writes);
    // 収まらない書き込みは、先にバッファを書き出す。
    try writeBytes(&f.heap, null, p, "e");
    try std.testing.expectEqualStrings("abcd", fake.written.items);
    try flush(&f.heap, p);
    try std.testing.expectEqualStrings("abcde", fake.written.items);
    // 空のバッファの書き出しは、ファイルに書かない。
    const writes = fake.writes;
    try flush(&f.heap, p);
    try std.testing.expectEqual(writes, fake.writes);
    try writeBytes(&f.heap, null, p, "f");
    try close(&f.heap, p);
    try std.testing.expectEqualStrings("abcdef", fake.written.items);
    try std.testing.expectEqual(1, fake.closed);
    try std.testing.expect(!p.open);
    // 閉じたポートを閉じても、何もしない。
    try close(&f.heap, p);
    try std.testing.expectEqual(1, fake.closed);
}

test "a write as large as the buffer of a file port goes to the file after what the buffer holds" {
    var fake: FakeHost = .{};
    defer fake.deinit();
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    const p = try openFake(&f.heap, &fake, .output, .binary, 4);
    try writeBytes(&f.heap, null, p, "a");
    try writeBytes(&f.heap, null, p, "bcde");
    try std.testing.expectEqualStrings("abcde", fake.written.items);
    try std.testing.expectEqual(0, p.backing.file.len);
    // バッファより1バイト小さい書き込みは、書き出したあとのバッファに入る。
    try writeBytes(&f.heap, null, p, "x");
    try writeBytes(&f.heap, null, p, "yzw");
    try writeBytes(&f.heap, null, p, "v");
    try std.testing.expectEqualStrings("abcdexyzw", fake.written.items);
    try std.testing.expectEqual(1, p.backing.file.len);
}

test "a file output port that cannot write keeps its buffer, and closing it closes the file all the same" {
    var fake: FakeHost = .{};
    defer fake.deinit();
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    const p = try openFake(&f.heap, &fake, .output, .textual, 4);
    try writeBytes(&f.heap, null, p, "abc");
    fake.fail = true;
    try std.testing.expectError(error.Io, flush(&f.heap, p));
    try std.testing.expectEqual(3, p.backing.file.len);
    try std.testing.expectError(error.Io, writeBytes(&f.heap, null, p, "de"));
    try std.testing.expectEqual(3, p.backing.file.len);
    try std.testing.expectError(error.Io, close(&f.heap, p));
    try std.testing.expect(!p.open);
    try std.testing.expectEqual(1, fake.closed);
    try std.testing.expectEqual(0, fake.written.items.len);
    try std.testing.expectError(error.PortClosed, flush(&f.heap, p));
}

test "flush refuses an input port and a closed port, and does nothing to a memory port" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    const in = try f.input(.textual, "a");
    try std.testing.expectError(error.WrongDirection, flush(&f.heap, in));
    const out = try f.output(.textual);
    try writeBytes(&f.heap, null, out, "a");
    try flush(&f.heap, out);
    try std.testing.expectEqualStrings("a", written(out));
    try close(&f.heap, out);
    try std.testing.expectError(error.PortClosed, flush(&f.heap, out));
}
