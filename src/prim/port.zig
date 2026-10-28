//! Port primitives (R7RS 6.13): the predicates, closing, string and bytevector ports, and
//! reading and writing on a port given explicitly.
//!
//! ポートの引数は、今は省略できない。省略したときの既定の現在のポート(`current-input-port`
//! など)は、スライス 5i が入れ、そこで個数の範囲を広げる(docs/plans/0019-phase5-ports-and-io.md)。
//!
//! 検査の順序は、型、不変(`read-bytevector!`)、範囲、ポートの状態(向き、種類、開閉)である。
//! 向きか種類の違うポートは、型の誤りである。閉じたポートへの読み書きは、R7RS 6.13 が誤りとする
//! もので、`PortClosed` を返す(`portFailure`)。閉じたポートの `get-output-string` と
//! `get-output-bytevector` は誤りにせず、書いたものを返す。

const std = @import("std");
const value = @import("../value.zig");
const Value = value.Value;
const Port = value.Port;
const Primitive = value.Primitive;
const Services = value.Services;
const PrimitiveError = value.PrimitiveError;
const port_mod = @import("../port.zig");
const immutable = @import("immutable.zig");
const range_mod = @import("range.zig");
const RangeOperands = range_mod.RangeOperands;
const resolveRange = range_mod.resolveRange;

pub const Error = PrimitiveError;

pub const primitives = [_]Primitive{
    .{ .name = "port?", .min_args = 1, .max_args = 1, .body = .{ .pure = &isPort } },
    .{ .name = "input-port?", .min_args = 1, .max_args = 1, .body = .{ .pure = &isInputPort } },
    .{ .name = "output-port?", .min_args = 1, .max_args = 1, .body = .{ .pure = &isOutputPort } },
    .{ .name = "textual-port?", .min_args = 1, .max_args = 1, .body = .{ .pure = &isTextualPort } },
    .{ .name = "binary-port?", .min_args = 1, .max_args = 1, .body = .{ .pure = &isBinaryPort } },
    .{ .name = "input-port-open?", .min_args = 1, .max_args = 1, .body = .{ .pure = &isInputPortOpen } },
    .{ .name = "output-port-open?", .min_args = 1, .max_args = 1, .body = .{ .pure = &isOutputPortOpen } },
    .{ .name = "close-port", .min_args = 1, .max_args = 1, .body = .{ .pure = &closePort } },
    .{ .name = "close-input-port", .min_args = 1, .max_args = 1, .body = .{ .pure = &closeInputPort } },
    .{ .name = "close-output-port", .min_args = 1, .max_args = 1, .body = .{ .pure = &closeOutputPort } },
    .{ .name = "open-input-string", .min_args = 1, .max_args = 1, .body = .{ .pure = &openInputString } },
    .{ .name = "open-output-string", .min_args = 0, .max_args = 0, .body = .{ .pure = &openOutputString } },
    .{ .name = "get-output-string", .min_args = 1, .max_args = 1, .body = .{ .pure = &getOutputString } },
    .{ .name = "open-input-bytevector", .min_args = 1, .max_args = 1, .body = .{ .pure = &openInputBytevector } },
    .{ .name = "open-output-bytevector", .min_args = 0, .max_args = 0, .body = .{ .pure = &openOutputBytevector } },
    .{ .name = "get-output-bytevector", .min_args = 1, .max_args = 1, .body = .{ .pure = &getOutputBytevector } },
    .{ .name = "read-char", .min_args = 1, .max_args = 1, .body = .{ .pure = &readChar } },
    .{ .name = "peek-char", .min_args = 1, .max_args = 1, .body = .{ .pure = &peekChar } },
    .{ .name = "read-line", .min_args = 1, .max_args = 1, .body = .{ .pure = &readLine } },
    .{ .name = "char-ready?", .min_args = 1, .max_args = 1, .body = .{ .pure = &isCharReady } },
    .{ .name = "read-string", .min_args = 2, .max_args = 2, .body = .{ .pure = &readString } },
    .{ .name = "read-u8", .min_args = 1, .max_args = 1, .body = .{ .pure = &readU8 } },
    .{ .name = "peek-u8", .min_args = 1, .max_args = 1, .body = .{ .pure = &peekU8 } },
    .{ .name = "u8-ready?", .min_args = 1, .max_args = 1, .body = .{ .pure = &isU8Ready } },
    .{ .name = "read-bytevector", .min_args = 2, .max_args = 2, .body = .{ .pure = &readBytevector } },
    .{ .name = "read-bytevector!", .min_args = 2, .max_args = 4, .body = .{ .pure = &readBytevectorInto } },
    .{ .name = "newline", .min_args = 1, .max_args = 1, .body = .{ .pure = &newline } },
    .{ .name = "write-char", .min_args = 2, .max_args = 2, .body = .{ .pure = &writeChar } },
    .{ .name = "write-string", .min_args = 2, .max_args = 4, .body = .{ .pure = &writeString } },
    .{ .name = "write-u8", .min_args = 2, .max_args = 2, .body = .{ .pure = &writeU8 } },
    .{ .name = "write-bytevector", .min_args = 2, .max_args = 4, .body = .{ .pure = &writeBytevector } },
    .{ .name = "flush-output-port", .min_args = 1, .max_args = 1, .body = .{ .pure = &flushOutputPort } },
};

/// The error a failure of the port functions is to a primitive.
/// 向きと種類の違いは、引数の型の誤りである。閉じたポートは、型は合っているので、別の誤り
/// (`PortClosed`)にして、閉じたことが文言で分かるようにする。
fn portFailure(e: port_mod.Error) Error {
    return switch (e) {
        error.WrongDirection, error.WrongKind => error.WrongType,
        error.PortClosed => error.PortClosed,
        error.HeapLimit, error.OutOfMemory => |heap_error| heap_error,
    };
}

/// The port `v` is, which must flow in `direction` and carry `element`.
/// 開閉は見ない。閉じたポートの扱いは、読み書きの関数(`port.zig`)が決める。
fn portOf(v: Value, direction: Port.Direction, element: Port.Element) Error!*Port {
    const p = v.asPort() orelse return error.WrongType;
    if (p.direction != direction or p.element != element) return error.WrongType;
    return p;
}

/// The byte that `v` is, or null when `v` is not an exact integer from 0 to 255.
fn byteOf(v: Value) ?u8 {
    return std.math.cast(u8, v.asFixnum() orelse return null);
}

/// A count of elements to read, `k` in `(read-string k port)`: an exact integer that is
/// not negative.
/// `usize` に収まらない大きさは、残りの全部を読むのと同じなので、最大の値にする。
/// 型の検査(整数か)は、ほかの引数の型と一緒に、呼び出し側が先に済ませる。
fn countOf(k: i64) Error!usize {
    if (k < 0) return error.OutOfRange;
    return std.math.cast(usize, k) orelse std.math.maxInt(usize);
}

/// `(port? obj)`.
fn isPort(_: *const Services, args: []const Value) Error!Value {
    return .fromBool(args[0].asPort() != null);
}

/// `(input-port? obj)`.
fn isInputPort(_: *const Services, args: []const Value) Error!Value {
    const p = args[0].asPort() orelse return .fromBool(false);
    return .fromBool(p.direction == .input);
}

/// `(output-port? obj)`.
fn isOutputPort(_: *const Services, args: []const Value) Error!Value {
    const p = args[0].asPort() orelse return .fromBool(false);
    return .fromBool(p.direction == .output);
}

/// `(textual-port? obj)`.
fn isTextualPort(_: *const Services, args: []const Value) Error!Value {
    const p = args[0].asPort() orelse return .fromBool(false);
    return .fromBool(p.element == .textual);
}

/// `(binary-port? obj)`.
fn isBinaryPort(_: *const Services, args: []const Value) Error!Value {
    const p = args[0].asPort() orelse return .fromBool(false);
    return .fromBool(p.element == .binary);
}

/// `(input-port-open? port)`: whether `port` is open and can be read from (R7RS 6.13.1).
/// 出力のポートは、開いていても偽である。
fn isInputPortOpen(_: *const Services, args: []const Value) Error!Value {
    const p = args[0].asPort() orelse return error.WrongType;
    return .fromBool(p.direction == .input and p.open);
}

/// `(output-port-open? port)`.
fn isOutputPortOpen(_: *const Services, args: []const Value) Error!Value {
    const p = args[0].asPort() orelse return error.WrongType;
    return .fromBool(p.direction == .output and p.open);
}

/// `(close-port port)`: closes `port`; a closed port is left as it is (R7RS 6.13.1).
fn closePort(_: *const Services, args: []const Value) Error!Value {
    port_mod.close(args[0].asPort() orelse return error.WrongType);
    return .unspecified_value;
}

/// `(close-input-port port)`: `close-port` for an input port only.
fn closeInputPort(_: *const Services, args: []const Value) Error!Value {
    const p = args[0].asPort() orelse return error.WrongType;
    if (p.direction != .input) return error.WrongType;
    port_mod.close(p);
    return .unspecified_value;
}

/// `(close-output-port port)`: `close-port` for an output port only.
fn closeOutputPort(_: *const Services, args: []const Value) Error!Value {
    const p = args[0].asPort() orelse return error.WrongType;
    if (p.direction != .output) return error.WrongType;
    port_mod.close(p);
    return .unspecified_value;
}

/// `(open-input-string string)`: a textual input port that reads the characters of
/// `string` (R7RS 6.13.1).
/// 文字列のバイト列は妥当な UTF-8 である(ADR-0008)。ポートはその写しを持つ。
fn openInputString(services: *const Services, args: []const Value) Error!Value {
    const s = args[0].asString() orelse return error.WrongType;
    return .fromPort(try services.heap.createMemoryPort(.input, .textual, s.bytes));
}

/// `(open-output-string)`: a textual output port whose characters `get-output-string` gives.
fn openOutputString(services: *const Services, _: []const Value) Error!Value {
    return .fromPort(try services.heap.createMemoryPort(.output, .textual, ""));
}

/// `(get-output-string port)`: a new string of the characters written to `port`, which
/// `open-output-string` made (R7RS 6.13.1).
/// 閉じたあとも、書いたものを返す。テキストのポートに書くのは妥当な UTF-8 だけなので、
/// 文字列にできる。
fn getOutputString(services: *const Services, args: []const Value) Error!Value {
    const p = try portOf(args[0], .output, .textual);
    return .fromString(try services.heap.createString(port_mod.written(p)));
}

/// `(open-input-bytevector bytevector)`: a binary input port that reads the bytes of
/// `bytevector`.
fn openInputBytevector(services: *const Services, args: []const Value) Error!Value {
    const b = args[0].asBytevector() orelse return error.WrongType;
    return .fromPort(try services.heap.createMemoryPort(.input, .binary, b.bytes));
}

/// `(open-output-bytevector)`: a binary output port whose bytes `get-output-bytevector` gives.
fn openOutputBytevector(services: *const Services, _: []const Value) Error!Value {
    return .fromPort(try services.heap.createMemoryPort(.output, .binary, ""));
}

/// `(get-output-bytevector port)`: a new bytevector of the bytes written to `port`, which
/// `open-output-bytevector` made.
fn getOutputBytevector(services: *const Services, args: []const Value) Error!Value {
    const p = try portOf(args[0], .output, .binary);
    return .fromBytevector(try services.heap.createBytevector(port_mod.written(p)));
}

/// `(read-char port)`: the next character, or an end-of-file object (R7RS 6.13.2).
fn readChar(services: *const Services, args: []const Value) Error!Value {
    const p = try portOf(args[0], .input, .textual);
    const c = port_mod.readChar(services.heap, p) catch |e| return portFailure(e);
    return if (c) |char| .fromCharacter(char) else .eof_value;
}

/// `(peek-char port)`: the next character, without reading past it.
fn peekChar(services: *const Services, args: []const Value) Error!Value {
    const p = try portOf(args[0], .input, .textual);
    const c = port_mod.peekChar(services.heap, p) catch |e| return portFailure(e);
    return if (c) |char| .fromCharacter(char) else .eof_value;
}

/// The bytes of the input port `p` that have not been read, after checking that it is
/// open.
fn pendingOf(services: *const Services, p: *Port) Error![]const u8 {
    // 開閉の検査は、1バイトを覗く関数に任せる。覗くだけで位置は動かない。
    switch (p.element) {
        .textual => _ = port_mod.peekChar(services.heap, p) catch |e| return portFailure(e),
        .binary => _ = port_mod.peekByte(services.heap, p) catch |e| return portFailure(e),
    }
    return port_mod.pending(p);
}

/// `(read-line port)`: the characters up to the end of the line, without the end, or an
/// end-of-file object when nothing is left (R7RS 6.13.2).
/// 行の終わりは、改行、復帰、復帰に続く改行のどれかである。どれも ASCII なので、バイト列を
/// 走査して探してよい。
fn readLine(services: *const Services, args: []const Value) Error!Value {
    const p = try portOf(args[0], .input, .textual);
    const rest = try pendingOf(services, p);
    if (rest.len == 0) return .eof_value;
    const end = std.mem.indexOfAny(u8, rest, "\n\r") orelse rest.len;
    const line = try services.heap.createString(rest[0..end]);
    var skip = end;
    if (end < rest.len) {
        skip += 1;
        if (rest[end] == '\r' and end + 1 < rest.len and rest[end + 1] == '\n') skip += 1;
    }
    port_mod.consume(p, skip);
    return .fromString(line);
}

/// `(char-ready? port)`: whether a character can be read without waiting (R7RS 6.13.2).
/// 文字列ポートは、終わりにあっても、待たずに答えられるので真である。
fn isCharReady(services: *const Services, args: []const Value) Error!Value {
    const p = try portOf(args[0], .input, .textual);
    _ = try pendingOf(services, p);
    return .fromBool(true);
}

/// `(read-string k port)`: a new string of the next `k` characters, or of as many as are
/// left, or an end-of-file object when none is left (R7RS 6.13.2).
/// `k` が 0 なら、何も読まずに空の文字列を返す。
fn readString(services: *const Services, args: []const Value) Error!Value {
    const n = args[0].asFixnum() orelse return error.WrongType;
    const p = try portOf(args[1], .input, .textual);
    const k = try countOf(n);
    const rest = try pendingOf(services, p);
    if (k == 0) return .fromString(try services.heap.createString(""));
    if (rest.len == 0) return .eof_value;
    var end: usize = 0;
    var count: usize = 0;
    while (end < rest.len and count < k) : (count += 1) {
        end += std.unicode.utf8ByteSequenceLength(rest[end]) catch unreachable;
    }
    const s = try services.heap.createString(rest[0..end]);
    port_mod.consume(p, end);
    return .fromString(s);
}

/// `(read-u8 port)`: the next byte, or an end-of-file object (R7RS 6.13.2).
fn readU8(services: *const Services, args: []const Value) Error!Value {
    const p = try portOf(args[0], .input, .binary);
    const b = port_mod.readByte(services.heap, p) catch |e| return portFailure(e);
    return if (b) |byte| .fromFixnum(byte) else .eof_value;
}

/// `(peek-u8 port)`: the next byte, without reading past it.
fn peekU8(services: *const Services, args: []const Value) Error!Value {
    const p = try portOf(args[0], .input, .binary);
    const b = port_mod.peekByte(services.heap, p) catch |e| return portFailure(e);
    return if (b) |byte| .fromFixnum(byte) else .eof_value;
}

/// `(u8-ready? port)`: whether a byte can be read without waiting.
fn isU8Ready(services: *const Services, args: []const Value) Error!Value {
    const p = try portOf(args[0], .input, .binary);
    _ = try pendingOf(services, p);
    return .fromBool(true);
}

/// `(read-bytevector k port)`: a new bytevector of the next `k` bytes, or of as many as
/// are left, or an end-of-file object when none is left (R7RS 6.13.2).
/// `k` が 0 なら、何も読まずに空のバイトベクタを返す。
fn readBytevector(services: *const Services, args: []const Value) Error!Value {
    const n = args[0].asFixnum() orelse return error.WrongType;
    const p = try portOf(args[1], .input, .binary);
    const k = try countOf(n);
    const rest = try pendingOf(services, p);
    if (k == 0) return .fromBytevector(try services.heap.createBytevector(""));
    if (rest.len == 0) return .eof_value;
    const taken = @min(k, rest.len);
    const b = try services.heap.createBytevector(rest[0..taken]);
    port_mod.consume(p, taken);
    return .fromBytevector(b);
}

/// `(read-bytevector! bytevector port)`, `(read-bytevector! bytevector port start)` and
/// `(read-bytevector! bytevector port start end)`: reads the next bytes into `bytevector`
/// from `start` up to `end`, and gives how many it read, or an end-of-file object when
/// none is left (R7RS 6.13.2).
/// 定数のバイトベクタは、範囲が空でも断る。範囲が空なら、何も読まずに 0 を返す。
fn readBytevectorInto(services: *const Services, args: []const Value) Error!Value {
    const target = args[0].asBytevector() orelse return error.WrongType;
    const p = try portOf(args[1], .input, .binary);
    const operands = try RangeOperands.of(args, 2);
    try immutable.requireMutable(args[0]);
    const range = try resolveRange(operands, target.bytes.len);
    const rest = try pendingOf(services, p);
    if (range.start == range.end) return .fromFixnum(0);
    if (rest.len == 0) return .eof_value;
    const n = @min(range.end - range.start, rest.len);
    @memcpy(target.bytes[range.start..][0..n], rest[0..n]);
    port_mod.consume(p, n);
    return .fromFixnum(@intCast(n));
}

/// Writes `bytes` to `p`, which the caller has checked to be an output port of the
/// right kind.
fn put(services: *const Services, p: *Port, bytes: []const u8) Error!Value {
    port_mod.writeBytes(services.heap, p, bytes) catch |e| return portFailure(e);
    return .unspecified_value;
}

/// `(newline port)`: writes an end of line, which is a linefeed (R7RS 6.13.3).
fn newline(services: *const Services, args: []const Value) Error!Value {
    return put(services, try portOf(args[0], .output, .textual), "\n");
}

/// `(write-char char port)`: writes `char` (R7RS 6.13.3).
fn writeChar(services: *const Services, args: []const Value) Error!Value {
    const c = args[0].asCharacter() orelse return error.WrongType;
    const p = try portOf(args[1], .output, .textual);
    var buf: [4]u8 = undefined;
    // 文字はスカラー値なので、符号化に失敗しない。
    const n = std.unicode.utf8Encode(c, &buf) catch unreachable;
    return put(services, p, buf[0..n]);
}

/// `(write-string string port)`, `(write-string string port start)` and
/// `(write-string string port start end)`: writes the characters of `string` from `start`
/// up to `end` (R7RS 6.13.3).
fn writeString(services: *const Services, args: []const Value) Error!Value {
    const s = args[0].asString() orelse return error.WrongType;
    const p = try portOf(args[1], .output, .textual);
    const operands = try RangeOperands.of(args, 2);
    const range = try resolveRange(operands, s.length());
    const span = s.byteSpan(range.start, range.end);
    return put(services, p, s.bytes[span.from..span.to]);
}

/// `(write-u8 byte port)`: writes `byte` (R7RS 6.13.3).
fn writeU8(services: *const Services, args: []const Value) Error!Value {
    const byte = byteOf(args[0]) orelse return error.WrongType;
    const p = try portOf(args[1], .output, .binary);
    return put(services, p, &.{byte});
}

/// `(write-bytevector bytevector port)`, `(write-bytevector bytevector port start)` and
/// `(write-bytevector bytevector port start end)`: writes the bytes of `bytevector` from
/// `start` up to `end` (R7RS 6.13.3).
fn writeBytevector(services: *const Services, args: []const Value) Error!Value {
    const b = args[0].asBytevector() orelse return error.WrongType;
    const p = try portOf(args[1], .output, .binary);
    const operands = try RangeOperands.of(args, 2);
    const range = try resolveRange(operands, b.bytes.len);
    return put(services, p, b.bytes[range.start..range.end]);
}

/// `(flush-output-port port)`: writes out what the port holds (R7RS 6.13.3).
/// 文字列ポートとバイトベクタポートは、書き出す先が無いので、開いているかだけを確かめる。
fn flushOutputPort(services: *const Services, args: []const Value) Error!Value {
    const p = args[0].asPort() orelse return error.WrongType;
    if (p.direction != .output) return error.WrongType;
    return put(services, p, "");
}

test {
    std.testing.refAllDecls(@This());
}

const test_support = @import("test_support.zig");

fn call(f: *test_support.Fixture, name: []const u8, args: []const Value) Error!Value {
    return f.call(&primitives, name, args);
}

fn str(f: *test_support.Fixture, content: []const u8) !Value {
    return .fromString(try f.heap.createString(content));
}

fn bv(f: *test_support.Fixture, content: []const u8) !Value {
    return .fromBytevector(try f.heap.createBytevector(content));
}

fn fix(n: i64) Value {
    return .fromFixnum(n);
}

fn chr(c: u21) Value {
    return .fromCharacter(c);
}

fn expectString(expected: []const u8, v: Value) !void {
    try std.testing.expectEqualStrings(expected, v.asString().?.bytes);
}

fn expectBytes(expected: []const u8, v: Value) !void {
    try std.testing.expectEqualSlices(u8, expected, v.asBytevector().?.bytes);
}

fn expectTrue(v: Value) !void {
    try std.testing.expectEqual(Value.fromBool(true), v);
}

fn expectFalse(v: Value) !void {
    try std.testing.expectEqual(Value.fromBool(false), v);
}

fn expectEof(v: Value) !void {
    try std.testing.expectEqual(.eof, v.kind());
}

/// Four ports: a string input port on "a", a bytevector input port on #u8(1), and a string
/// and a bytevector output port.
const Ports = struct {
    text_in: Value,
    bytes_in: Value,
    text_out: Value,
    bytes_out: Value,

    fn make(f: *test_support.Fixture) !Ports {
        return .{
            .text_in = try call(f, "open-input-string", &.{try str(f, "a")}),
            .bytes_in = try call(f, "open-input-bytevector", &.{try bv(f, &.{1})}),
            .text_out = try call(f, "open-output-string", &.{}),
            .bytes_out = try call(f, "open-output-bytevector", &.{}),
        };
    }
};

test "the primitives take the numbers of arguments the language gives them, with the port required for now" {
    const expected = [_]struct { []const u8, u8, ?u8 }{
        .{ "port?", 1, 1 },                 .{ "input-port?", 1, 1 },           .{ "output-port?", 1, 1 },
        .{ "textual-port?", 1, 1 },         .{ "binary-port?", 1, 1 },          .{ "input-port-open?", 1, 1 },
        .{ "output-port-open?", 1, 1 },     .{ "close-port", 1, 1 },            .{ "close-input-port", 1, 1 },
        .{ "close-output-port", 1, 1 },     .{ "open-input-string", 1, 1 },     .{ "open-output-string", 0, 0 },
        .{ "get-output-string", 1, 1 },     .{ "open-input-bytevector", 1, 1 }, .{ "open-output-bytevector", 0, 0 },
        .{ "get-output-bytevector", 1, 1 }, .{ "read-char", 1, 1 },             .{ "peek-char", 1, 1 },
        .{ "read-line", 1, 1 },             .{ "char-ready?", 1, 1 },           .{ "read-string", 2, 2 },
        .{ "read-u8", 1, 1 },               .{ "peek-u8", 1, 1 },               .{ "u8-ready?", 1, 1 },
        .{ "read-bytevector", 2, 2 },       .{ "read-bytevector!", 2, 4 },      .{ "newline", 1, 1 },
        .{ "write-char", 2, 2 },            .{ "write-string", 2, 4 },          .{ "write-u8", 2, 2 },
        .{ "write-bytevector", 2, 4 },      .{ "flush-output-port", 1, 1 },
    };
    try std.testing.expectEqual(expected.len, primitives.len);
    for (expected, primitives) |e, p| {
        try std.testing.expectEqualStrings(e[0], p.name);
        try std.testing.expectEqual(e[1], p.min_args);
        try std.testing.expectEqual(e[2], p.max_args);
    }
}

test "the predicates tell ports by direction and kind, and other values are not ports" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    const p = try Ports.make(&f);
    for ([_]Value{ p.text_in, p.bytes_in, p.text_out, p.bytes_out }) |port| try expectTrue(try call(&f, "port?", &.{port}));
    try expectFalse(try call(&f, "port?", &.{try str(&f, "a")}));
    try expectFalse(try call(&f, "port?", &.{.eof_value}));
    try expectTrue(try call(&f, "input-port?", &.{p.text_in}));
    try expectTrue(try call(&f, "input-port?", &.{p.bytes_in}));
    try expectFalse(try call(&f, "input-port?", &.{p.text_out}));
    try expectFalse(try call(&f, "input-port?", &.{fix(0)}));
    try expectTrue(try call(&f, "output-port?", &.{p.bytes_out}));
    try expectFalse(try call(&f, "output-port?", &.{p.bytes_in}));
    try expectFalse(try call(&f, "output-port?", &.{fix(0)}));
    try expectTrue(try call(&f, "textual-port?", &.{p.text_in}));
    try expectTrue(try call(&f, "textual-port?", &.{p.text_out}));
    try expectFalse(try call(&f, "textual-port?", &.{p.bytes_in}));
    try expectFalse(try call(&f, "textual-port?", &.{fix(0)}));
    try expectTrue(try call(&f, "binary-port?", &.{p.bytes_out}));
    try expectFalse(try call(&f, "binary-port?", &.{p.text_out}));
    try expectFalse(try call(&f, "binary-port?", &.{fix(0)}));
}

test "closing a port makes it no longer open in its direction, and closing again does nothing" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    const p = try Ports.make(&f);
    try expectTrue(try call(&f, "input-port-open?", &.{p.text_in}));
    // 出力のポートは、開いていても入力はできない(R7RS 6.13.1)。
    try expectFalse(try call(&f, "input-port-open?", &.{p.text_out}));
    try expectTrue(try call(&f, "output-port-open?", &.{p.text_out}));
    try expectFalse(try call(&f, "output-port-open?", &.{p.text_in}));
    try std.testing.expectEqual(Value.unspecified_value, try call(&f, "close-port", &.{p.text_in}));
    try expectFalse(try call(&f, "input-port-open?", &.{p.text_in}));
    _ = try call(&f, "close-port", &.{p.text_in});
    _ = try call(&f, "close-input-port", &.{p.bytes_in});
    try expectFalse(try call(&f, "input-port-open?", &.{p.bytes_in}));
    _ = try call(&f, "close-output-port", &.{p.text_out});
    try expectFalse(try call(&f, "output-port-open?", &.{p.text_out}));
    // 向きの違うポートを閉じるのは誤りである(R7RS 6.13.1)。
    try std.testing.expectError(error.WrongType, call(&f, "close-input-port", &.{p.bytes_out}));
    try std.testing.expectError(error.WrongType, call(&f, "close-output-port", &.{p.bytes_in}));
    try expectTrue(try call(&f, "output-port-open?", &.{p.bytes_out}));
    for ([_][]const u8{ "input-port-open?", "output-port-open?", "close-port", "close-input-port", "close-output-port" }) |name| {
        try std.testing.expectError(error.WrongType, call(&f, name, &.{fix(0)}));
    }
}

test "a string input port reads the characters of the string it was opened on" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    // 計画書の完了条件の例: `(#\a #\b #\b #t)`。
    const p = try call(&f, "open-input-string", &.{try str(&f, "ab")});
    try std.testing.expectEqual(chr('a'), try call(&f, "read-char", &.{p}));
    try std.testing.expectEqual(chr('b'), try call(&f, "peek-char", &.{p}));
    try std.testing.expectEqual(chr('b'), try call(&f, "read-char", &.{p}));
    try expectEof(try call(&f, "read-char", &.{p}));
    try expectEof(try call(&f, "peek-char", &.{p}));
    try std.testing.expectError(error.WrongType, call(&f, "open-input-string", &.{fix(0)}));
}

test "a string input port keeps the characters it was opened on when the string changes" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    const s = try str(&f, "ab");
    const p = try call(&f, "open-input-string", &.{s});
    // 文字列を書き換えても、開いたときの写しを読む(計画書 0019 の合意を求める点の3)。
    s.asString().?.bytes[0] = 'x';
    try std.testing.expectEqual(chr('a'), try call(&f, "read-char", &.{p}));
}

test "read-line reads up to the end of a line, which a linefeed, a return, or both end" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    const p = try call(&f, "open-input-string", &.{try str(&f, "ab\ncd\r\nλ\r\n\rlast")});
    try expectString("ab", try call(&f, "read-line", &.{p}));
    try expectString("cd", try call(&f, "read-line", &.{p}));
    try expectString("λ", try call(&f, "read-line", &.{p}));
    // 復帰だけの行は、空の行である。
    try expectString("", try call(&f, "read-line", &.{p}));
    // 最後の行は、行の終わりが無くても読める。
    try expectString("last", try call(&f, "read-line", &.{p}));
    try expectEof(try call(&f, "read-line", &.{p}));
}

test "read-string reads as many characters as it is asked for, or as are left" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    const p = try call(&f, "open-input-string", &.{try str(&f, "aλcde")});
    try expectString("aλ", try call(&f, "read-string", &.{ fix(2), p }));
    try expectString("", try call(&f, "read-string", &.{ fix(0), p }));
    try expectString("cde", try call(&f, "read-string", &.{ fix(10), p }));
    try expectEof(try call(&f, "read-string", &.{ fix(1), p }));
    try std.testing.expectError(error.OutOfRange, call(&f, "read-string", &.{ fix(-1), p }));
    try std.testing.expectError(error.WrongType, call(&f, "read-string", &.{ chr('a'), p }));
}

test "char-ready? and u8-ready? are true of an open input port of their kind" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    const p = try Ports.make(&f);
    try expectTrue(try call(&f, "char-ready?", &.{p.text_in}));
    try expectTrue(try call(&f, "u8-ready?", &.{p.bytes_in}));
    // 終わりにあっても真である(R7RS 6.13.2)。
    _ = try call(&f, "read-char", &.{p.text_in});
    try expectTrue(try call(&f, "char-ready?", &.{p.text_in}));
    try std.testing.expectError(error.WrongType, call(&f, "char-ready?", &.{p.bytes_in}));
    try std.testing.expectError(error.WrongType, call(&f, "u8-ready?", &.{p.text_in}));
}

test "a bytevector input port reads the bytes of the bytevector it was opened on" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    const p = try call(&f, "open-input-bytevector", &.{try bv(&f, &.{ 1, 2, 3, 4, 5 })});
    try std.testing.expectEqual(fix(1), try call(&f, "peek-u8", &.{p}));
    try std.testing.expectEqual(fix(1), try call(&f, "read-u8", &.{p}));
    try expectBytes(&.{ 2, 3 }, try call(&f, "read-bytevector", &.{ fix(2), p }));
    try expectBytes(&.{}, try call(&f, "read-bytevector", &.{ fix(0), p }));
    try expectBytes(&.{ 4, 5 }, try call(&f, "read-bytevector", &.{ fix(9), p }));
    try expectEof(try call(&f, "read-bytevector", &.{ fix(1), p }));
    try expectEof(try call(&f, "read-u8", &.{p}));
    try expectEof(try call(&f, "peek-u8", &.{p}));
    try std.testing.expectError(error.WrongType, call(&f, "open-input-bytevector", &.{try str(&f, "a")}));
    try std.testing.expectError(error.OutOfRange, call(&f, "read-bytevector", &.{ fix(-1), p }));
}

test "read-bytevector! reads into the range it is given, and counts what it read" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    const p = try call(&f, "open-input-bytevector", &.{try bv(&f, &.{ 1, 2, 3 })});
    const target = try bv(&f, &.{ 0, 0, 0, 0 });
    try std.testing.expectEqual(fix(2), try call(&f, "read-bytevector!", &.{ target, p, fix(1), fix(3) }));
    try expectBytes(&.{ 0, 1, 2, 0 }, target);
    // 範囲が空なら、何も読まず 0 である。
    try std.testing.expectEqual(fix(0), try call(&f, "read-bytevector!", &.{ target, p, fix(2), fix(2) }));
    try std.testing.expectEqual(fix(1), try call(&f, "read-bytevector!", &.{ target, p }));
    try expectBytes(&.{ 3, 1, 2, 0 }, target);
    try expectEof(try call(&f, "read-bytevector!", &.{ target, p }));
    try std.testing.expectError(error.OutOfRange, call(&f, "read-bytevector!", &.{ target, p, fix(3), fix(5) }));
}

test "read-bytevector! refuses a constant bytevector, even for an empty range" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    const p = try call(&f, "open-input-bytevector", &.{try bv(&f, &.{1})});
    const target = try bv(&f, &.{0});
    @import("../heap.zig").makeImmutable(target);
    try std.testing.expectError(error.Immutable, call(&f, "read-bytevector!", &.{ target, p }));
    try std.testing.expectError(error.Immutable, call(&f, "read-bytevector!", &.{ target, p, fix(0), fix(0) }));
    // 断ったので、何も読んでいない。
    try std.testing.expectEqual(fix(1), try call(&f, "read-u8", &.{p}));
}

test "get-output-string gives what was written to a string output port, and goes on giving it" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    const p = try call(&f, "open-output-string", &.{});
    try expectString("", try call(&f, "get-output-string", &.{p}));
    _ = try call(&f, "write-char", &.{ chr('a'), p });
    _ = try call(&f, "write-char", &.{ chr(0x3BB), p });
    _ = try call(&f, "write-string", &.{ try str(&f, "bc"), p });
    _ = try call(&f, "newline", &.{p});
    _ = try call(&f, "write-string", &.{ try str(&f, "xλyz"), p, fix(1) });
    _ = try call(&f, "write-string", &.{ try str(&f, "xλyz"), p, fix(1), fix(2) });
    const first = try call(&f, "get-output-string", &.{p});
    try expectString("aλbc\nλyzλ", first);
    // 返すのは新しい文字列で、ポートに書き足しても変わらない。
    _ = try call(&f, "write-char", &.{ chr('!'), p });
    try expectString("aλbc\nλyzλ", first);
    try expectString("aλbc\nλyzλ!", try call(&f, "get-output-string", &.{p}));
    // 閉じたあとも、書いたものは読める。
    _ = try call(&f, "close-port", &.{p});
    try expectString("aλbc\nλyzλ!", try call(&f, "get-output-string", &.{p}));
    try std.testing.expectError(error.OutOfRange, call(&f, "write-string", &.{ try str(&f, "ab"), try call(&f, "open-output-string", &.{}), fix(2), fix(1) }));
}

test "get-output-bytevector gives what was written to a bytevector output port" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    const p = try call(&f, "open-output-bytevector", &.{});
    _ = try call(&f, "write-u8", &.{ fix(1), p });
    _ = try call(&f, "write-bytevector", &.{ try bv(&f, &.{ 2, 3 }), p });
    _ = try call(&f, "write-bytevector", &.{ try bv(&f, &.{ 4, 5, 6 }), p, fix(1), fix(2) });
    try expectBytes(&.{ 1, 2, 3, 5 }, try call(&f, "get-output-bytevector", &.{p}));
    _ = try call(&f, "flush-output-port", &.{p});
    try std.testing.expectError(error.WrongType, call(&f, "write-u8", &.{ fix(256), p }));
    try std.testing.expectError(error.WrongType, call(&f, "write-u8", &.{ fix(-1), p }));
}

test "get-output-string and get-output-bytevector take only an output port of their kind" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    const p = try Ports.make(&f);
    try std.testing.expectError(error.WrongType, call(&f, "get-output-string", &.{p.bytes_out}));
    try std.testing.expectError(error.WrongType, call(&f, "get-output-string", &.{p.text_in}));
    try std.testing.expectError(error.WrongType, call(&f, "get-output-bytevector", &.{p.text_out}));
    try std.testing.expectError(error.WrongType, call(&f, "get-output-bytevector", &.{p.bytes_in}));
    try std.testing.expectError(error.WrongType, call(&f, "get-output-string", &.{fix(0)}));
}

test "reading and writing refuse a port of the other direction or kind as the wrong type" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    const p = try Ports.make(&f);
    const target = try bv(&f, &.{0});
    const cases = [_]struct { []const u8, []const Value }{
        .{ "read-char", &.{p.bytes_in} },                  .{ "read-char", &.{p.text_out} },
        .{ "peek-char", &.{p.bytes_in} },                  .{ "read-line", &.{p.bytes_in} },
        .{ "read-string", &.{ fix(1), p.bytes_in } },      .{ "read-u8", &.{p.text_in} },
        .{ "peek-u8", &.{p.text_in} },                     .{ "read-bytevector", &.{ fix(1), p.text_in } },
        .{ "read-bytevector!", &.{ target, p.text_in } },  .{ "read-u8", &.{p.bytes_out} },
        .{ "write-char", &.{ chr('a'), p.bytes_out } },    .{ "write-char", &.{ chr('a'), p.text_in } },
        .{ "newline", &.{p.bytes_out} },                   .{ "write-u8", &.{ fix(1), p.text_out } },
        .{ "write-bytevector", &.{ target, p.text_out } }, .{ "write-u8", &.{ fix(1), p.bytes_in } },
        .{ "flush-output-port", &.{p.text_in} },           .{ "read-char", &.{fix(0)} },
        .{ "write-char", &.{ fix(0), p.text_out } },       .{ "write-string", &.{ chr('a'), p.text_out } },
    };
    for (cases) |c| try std.testing.expectError(error.WrongType, call(&f, c[0], c[1]));
}

test "reading and writing a closed port of the right direction and kind is refused as closed" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    const p = try Ports.make(&f);
    for ([_]Value{ p.text_in, p.bytes_in, p.text_out, p.bytes_out }) |port| _ = try call(&f, "close-port", &.{port});
    const target = try bv(&f, &.{0});
    const cases = [_]struct { []const u8, []const Value }{
        .{ "read-char", &.{p.text_in} },                    .{ "peek-char", &.{p.text_in} },
        .{ "read-line", &.{p.text_in} },                    .{ "char-ready?", &.{p.text_in} },
        .{ "read-string", &.{ fix(1), p.text_in } },        .{ "read-u8", &.{p.bytes_in} },
        .{ "peek-u8", &.{p.bytes_in} },                     .{ "u8-ready?", &.{p.bytes_in} },
        .{ "read-bytevector", &.{ fix(1), p.bytes_in } },   .{ "read-bytevector!", &.{ target, p.bytes_in } },
        .{ "write-char", &.{ chr('a'), p.text_out } },      .{ "write-string", &.{ try str(&f, "a"), p.text_out } },
        .{ "newline", &.{p.text_out} },                     .{ "write-u8", &.{ fix(1), p.bytes_out } },
        .{ "write-bytevector", &.{ target, p.bytes_out } }, .{ "flush-output-port", &.{p.text_out} },
    };
    for (cases) |c| try std.testing.expectError(error.PortClosed, call(&f, c[0], c[1]));
    // 何も書いていないので、書いたものは空のままである。
    try expectString("", try call(&f, "get-output-string", &.{p.text_out}));
    try expectBytes(&.{}, try call(&f, "get-output-bytevector", &.{p.bytes_out}));
}

test "read-string and read-bytevector check the type of the port before the range of the count" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    const p = try Ports.make(&f);
    try std.testing.expectError(error.WrongType, call(&f, "read-string", &.{ fix(-1), p.bytes_in }));
    try std.testing.expectError(error.WrongType, call(&f, "read-bytevector", &.{ fix(-1), p.text_in }));
    try std.testing.expectError(error.OutOfRange, call(&f, "read-bytevector", &.{ fix(-1), p.bytes_in }));
}
