//! Port primitives (R7RS 6.13): the predicates, closing, string and bytevector ports, the
//! current ports, reading and writing, and `write`, `write-shared`, `write-simple` and
//! `display` (R7RS 6.13.3, `(scheme write)`).
//!
//! ポートの引数を省略すると、現在のポートを使う(R7RS 6.13.2、6.13.3)。現在のポートは
//! パラメータで(`current-input-port` と `current-output-port`)、その時点の値を、呼び出しの
//! 動的点から引く(`Services.dyn`、`argPort`)。パラメータは `Context` が作り、`%console-parameter`
//! が返す。`lib/sucheme/procedures.scm` が、それを名前に束縛する。
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
const Heap = @import("../heap.zig").Heap;
const reader = @import("../reader.zig");
const printer = @import("../printer.zig");
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
    .{ .name = "read-char", .min_args = 0, .max_args = 1, .body = .{ .pure = &readChar } },
    .{ .name = "peek-char", .min_args = 0, .max_args = 1, .body = .{ .pure = &peekChar } },
    .{ .name = "read-line", .min_args = 0, .max_args = 1, .body = .{ .pure = &readLine } },
    .{ .name = "char-ready?", .min_args = 0, .max_args = 1, .body = .{ .pure = &isCharReady } },
    .{ .name = "read-string", .min_args = 1, .max_args = 2, .body = .{ .pure = &readString } },
    .{ .name = "read-u8", .min_args = 0, .max_args = 1, .body = .{ .pure = &readU8 } },
    .{ .name = "peek-u8", .min_args = 0, .max_args = 1, .body = .{ .pure = &peekU8 } },
    .{ .name = "u8-ready?", .min_args = 0, .max_args = 1, .body = .{ .pure = &isU8Ready } },
    .{ .name = "read-bytevector", .min_args = 1, .max_args = 2, .body = .{ .pure = &readBytevector } },
    .{ .name = "read-bytevector!", .min_args = 1, .max_args = 4, .body = .{ .pure = &readBytevectorInto } },
    .{ .name = "newline", .min_args = 0, .max_args = 1, .body = .{ .pure = &newline } },
    .{ .name = "write-char", .min_args = 1, .max_args = 2, .body = .{ .pure = &writeChar } },
    .{ .name = "write-string", .min_args = 1, .max_args = 4, .body = .{ .pure = &writeString } },
    .{ .name = "write-u8", .min_args = 1, .max_args = 2, .body = .{ .pure = &writeU8 } },
    .{ .name = "write-bytevector", .min_args = 1, .max_args = 4, .body = .{ .pure = &writeBytevector } },
    .{ .name = "flush-output-port", .min_args = 0, .max_args = 1, .body = .{ .pure = &flushOutputPort } },
    .{ .name = "write", .min_args = 1, .max_args = 2, .body = .{ .pure = &write } },
    .{ .name = "write-shared", .min_args = 1, .max_args = 2, .body = .{ .pure = &writeShared } },
    .{ .name = "write-simple", .min_args = 1, .max_args = 2, .body = .{ .pure = &writeSimple } },
    .{ .name = "display", .min_args = 1, .max_args = 2, .body = .{ .pure = &display } },
    .{ .name = "%console-parameter", .min_args = 1, .max_args = 1, .body = .{ .pure = &consoleParameter } },
    .{ .name = "open-input-file", .min_args = 1, .max_args = 1, .body = .{ .pure = &openInputFile } },
    .{ .name = "open-binary-input-file", .min_args = 1, .max_args = 1, .body = .{ .pure = &openBinaryInputFile } },
    .{ .name = "open-output-file", .min_args = 1, .max_args = 1, .body = .{ .pure = &openOutputFile } },
    .{ .name = "open-binary-output-file", .min_args = 1, .max_args = 1, .body = .{ .pure = &openBinaryOutputFile } },
    .{ .name = "file-exists?", .min_args = 1, .max_args = 1, .body = .{ .pure = &fileExists } },
    .{ .name = "delete-file", .min_args = 1, .max_args = 1, .body = .{ .pure = &deleteFile } },
    .{ .name = "read", .min_args = 0, .max_args = 1, .body = .{ .pure = &read } },
};

/// The error a failure of the port functions is to a primitive.
/// 向きと種類の違いは、引数の型の誤りである。閉じたポートは、型は合っているので、別の誤り
/// (`PortClosed`)にして、閉じたことが文言で分かるようにする。
fn portFailure(e: port_mod.Error) Error {
    return switch (e) {
        error.WrongDirection, error.WrongKind => error.WrongType,
        error.PortClosed => error.PortClosed,
        error.WriteFailed => error.WriteFailed,
        error.Io => error.FileError,
        error.HeapLimit, error.OutOfMemory => |heap_error| heap_error,
    };
}

/// The port `args[index]` is, or the current port of `direction` when the argument is
/// left out (R7RS 6.13.2, 6.13.3); either must flow in `direction` and carry `element`.
/// 現在のポートは、パラメータの、呼び出しの動的点での値である(`parameterize` が差し替えた
/// 値を含む)。パラメータの値がポートでなければ、型の誤りである(`parameterize` は値を検査しない)。
/// コンソールを持たない呼び出し(プリミティブの単体テスト)では、省略は型の誤りである。
fn argPort(services: *const Services, args: []const Value, index: usize, direction: Port.Direction, element: Port.Element) Error!*Port {
    if (index < args.len) return portOf(args[index], direction, element);
    const console = services.console orelse return error.WrongType;
    const param = try consoleParameterOf(services.heap, console, if (direction == .input) .input else .output);
    return portOf(value.parameterValue(services.dyn, param), direction, element);
}

/// Whether `p` is a string or a bytevector port, which `get-output-string` and
/// `get-output-bytevector` take.
fn isMemory(p: *const Port) bool {
    return p.backing == .memory;
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
/// ファイルの出力ポートは、ためた出力を書き出してから閉じる。書き出せなければ、閉じたうえで
/// `file-error` を送出する。
fn closePort(services: *const Services, args: []const Value) Error!Value {
    port_mod.close(services.heap, args[0].asPort() orelse return error.WrongType) catch |e| return portFailure(e);
    return .unspecified_value;
}

/// `(close-input-port port)`: `close-port` for an input port only.
fn closeInputPort(services: *const Services, args: []const Value) Error!Value {
    const p = args[0].asPort() orelse return error.WrongType;
    if (p.direction != .input) return error.WrongType;
    port_mod.close(services.heap, p) catch |e| return portFailure(e);
    return .unspecified_value;
}

/// `(close-output-port port)`: `close-port` for an output port only.
fn closeOutputPort(services: *const Services, args: []const Value) Error!Value {
    const p = args[0].asPort() orelse return error.WrongType;
    if (p.direction != .output) return error.WrongType;
    port_mod.close(services.heap, p) catch |e| return portFailure(e);
    return .unspecified_value;
}

/// The size of the buffer of a file port.
/// Why: 大きさは、`ReleaseSafe` で測って決めた(docs/plans/0019-phase5-ports-and-io.md の合意を
/// 求める点の1)。測り方: 候補(256、1024、4096、16384、65536)ごとに実行ファイルを作り、
/// `write-char` で1文字ずつ書くプログラム、`read-char` で1文字ずつ読むプログラム、`write-string`
/// で100文字ずつ書くプログラムを、それぞれ数メガバイトのファイルに対して3回走らせ、最短の時間を
/// 比べた。1文字ずつの読み書きは、評価器の費用が大半で、候補の間に差が見えなかった。
/// `write-string` では、256 だけが遅く、1024 以上はそろった。そろった中から、多くのシステムの
/// ページの大きさと同じ 4096 を選んだ。これより大きくしても速くならず、開いたファイルごとに
/// 計上する量だけが増える。
pub const file_buffer_size = 4096;

/// A new open port of `direction` and `element` on the file `args[0]` names
/// (R7RS 6.13.1 `open-input-file` and the like).
/// ポートを先に作ってから開く(`Heap.createFilePort`)。ファイルを開けるホストを持たない
/// とき(WASM)と、開けなかったときは、`file-error` である。記述子が尽きたときは
/// `FilesExhausted` を返し、機械が回収してから1回だけ呼び直す(`Machine.apply`)。作りかけの
/// ポートは閉じたまま、その回収で返る。
fn openFile(services: *const Services, args: []const Value, direction: Port.Direction, element: Port.Element) Error!Value {
    const name = args[0].asString() orelse return error.WrongType;
    const host = services.heap.files orelse return error.FileError;
    const p = try services.heap.createFilePort(direction, element, file_buffer_size);
    p.backing.file.id = host.open(host.context, name.bytes, direction) catch |e| return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        error.Exhausted => error.FilesExhausted,
        error.Refused => error.FileError,
    };
    p.open = true;
    return .fromPort(p);
}

/// `(open-input-file string)`: a textual input port that reads the file `string` names.
fn openInputFile(services: *const Services, args: []const Value) Error!Value {
    return openFile(services, args, .input, .textual);
}

/// `(open-binary-input-file string)`.
fn openBinaryInputFile(services: *const Services, args: []const Value) Error!Value {
    return openFile(services, args, .input, .binary);
}

/// `(open-output-file string)`: a textual output port that writes the file `string`
/// names, which is made, or emptied when it is there.
/// R7RS 6.13.1 は、既にあるファイルへの影響を定めていない。中身を空にして書く。
fn openOutputFile(services: *const Services, args: []const Value) Error!Value {
    return openFile(services, args, .output, .textual);
}

/// `(open-binary-output-file string)`.
fn openBinaryOutputFile(services: *const Services, args: []const Value) Error!Value {
    return openFile(services, args, .output, .binary);
}

/// `(file-exists? string)`: whether the file `string` names is there (R7RS 6.14).
/// ファイルを開けるホストを持たないとき(WASM)は、偽である(docs/design/frontend.md)。
fn fileExists(services: *const Services, args: []const Value) Error!Value {
    const name = args[0].asString() orelse return error.WrongType;
    const host = services.heap.files orelse return .fromBool(false);
    return .fromBool(host.exists(host.context, name.bytes));
}

/// `(delete-file string)`: deletes the file `string` names; a file that is not
/// there, or cannot be deleted, is a `file-error` (R7RS 6.14).
fn deleteFile(services: *const Services, args: []const Value) Error!Value {
    const name = args[0].asString() orelse return error.WrongType;
    const host = services.heap.files orelse return error.FileError;
    host.delete(host.context, name.bytes) catch return error.FileError;
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
    // コンソールの出力ポートは、書いたものを持たない(R7RS 6.13.1 は open-output-string の
    // ポートに限る)。
    if (!isMemory(p)) return error.WrongType;
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
    if (!isMemory(p)) return error.WrongType;
    return .fromBytevector(try services.heap.createBytevector(port_mod.written(p)));
}

/// `(read-char port)`: the next character, or an end-of-file object (R7RS 6.13.2).
fn readChar(services: *const Services, args: []const Value) Error!Value {
    const p = try argPort(services, args, 0, .input, .textual);
    const c = port_mod.readChar(services.heap, p) catch |e| return portFailure(e);
    return if (c) |char| .fromCharacter(char) else .eof_value;
}

/// `(peek-char port)`: the next character, without reading past it.
fn peekChar(services: *const Services, args: []const Value) Error!Value {
    const p = try argPort(services, args, 0, .input, .textual);
    const c = port_mod.peekChar(services.heap, p) catch |e| return portFailure(e);
    return if (c) |char| .fromCharacter(char) else .eof_value;
}

/// Checks that the input port `p` is open, without reading past anything.
/// 開閉の検査は、1つを覗く関数に任せる。覗くだけで位置は動かない。
fn checkReadable(services: *const Services, p: *Port) Error!void {
    switch (p.element) {
        .textual => _ = port_mod.peekChar(services.heap, p) catch |e| return portFailure(e),
        .binary => _ = port_mod.peekByte(services.heap, p) catch |e| return portFailure(e),
    }
}

/// Where the procedures that read many characters or bytes collect them before they
/// make the result: room counted against the limit of the heap (`Heap.residentAllocator`).
/// Why: ファイルのポートは、まだ読んでいない入力のうち、バッファにある分しか手元に持たない。
/// 結果はバッファより長くなりうるので、読み足しながら、ここにためる。ためる量は読む量に
/// 比例するので、上限に数える。ためたものは、結果のオブジェクトを作ったら返す。
const Collected = struct {
    bytes: std.ArrayList(u8) = .empty,
    heap: *Heap,
    was_refused: bool,

    fn init(heap: *Heap) Collected {
        const was_refused = heap.external_refused;
        heap.external_refused = false;
        return .{ .heap = heap, .was_refused = was_refused };
    }

    fn deinit(self: *Collected) void {
        self.bytes.deinit(self.heap.residentAllocator());
        self.heap.external_refused = self.was_refused;
    }

    fn append(self: *Collected, bytes: []const u8) Error!void {
        self.bytes.appendSlice(self.heap.residentAllocator(), bytes) catch
            return if (self.heap.external_refused) error.HeapLimit else error.OutOfMemory;
    }

    fn appendChar(self: *Collected, c: u21) Error!void {
        var buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(c, &buf) catch unreachable;
        return self.append(buf[0..n]);
    }
};

/// The characters of the textual input port `p` up to `limit` of them, or, when `line`
/// is true, up to the end of the line, which is read past but not kept; null when the
/// port is at its end before any character.
/// Why: 1文字ずつ `port.readChar` で読む。ファイルのポートでは、バッファの境目で分かれた文字を
/// 読み足してつなぎ、UTF-8 として読めないバイトを U+FFFD にする(src/port.zig の
/// `peekCharWidth`)。バッファのバイト列を切り出して文字列にすると、境目で分かれた文字や
/// 読めないバイトが、検査されないまま文字列に入る。ためたものは、文字を符号化し直したもの
/// なので、妥当な UTF-8 である(ADR-0008)。
fn readText(services: *const Services, p: *Port, limit: usize, line: bool) Error!?Value {
    var collected: Collected = .init(services.heap);
    defer collected.deinit();
    var count: usize = 0;
    var read_any = false;
    while (count < limit) : (count += 1) {
        const c = (port_mod.readChar(services.heap, p) catch |e| return portFailure(e)) orelse break;
        read_any = true;
        if (line and c == '\n') break;
        if (line and c == '\r') {
            const next = port_mod.peekChar(services.heap, p) catch |e| return portFailure(e);
            if (next == '\n') _ = port_mod.readChar(services.heap, p) catch |e| return portFailure(e);
            break;
        }
        try collected.appendChar(c);
    }
    if (!read_any) return null;
    return .fromString(try services.heap.createString(collected.bytes.items));
}

/// `(read-line port)`: the characters up to the end of the line, without the end, or an
/// end-of-file object when nothing is left (R7RS 6.13.2).
/// 行の終わりは、改行、復帰、復帰に続く改行のどれかである。
fn readLine(services: *const Services, args: []const Value) Error!Value {
    const p = try argPort(services, args, 0, .input, .textual);
    return try readText(services, p, std.math.maxInt(usize), true) orelse .eof_value;
}

/// `(char-ready? port)`: whether a character can be read without waiting (R7RS 6.13.2).
/// 文字列ポートは、終わりにあっても、待たずに答えられるので真である。ファイルのポートも、
/// 読み足しは待たずに終わるものとして、真と答える。
fn isCharReady(services: *const Services, args: []const Value) Error!Value {
    const p = try argPort(services, args, 0, .input, .textual);
    try checkReadable(services, p);
    return .fromBool(true);
}

/// `(read-string k port)`: a new string of the next `k` characters, or of as many as are
/// left, or an end-of-file object when none is left (R7RS 6.13.2).
/// `k` が 0 なら、何も読まずに空の文字列を返す。
fn readString(services: *const Services, args: []const Value) Error!Value {
    const n = args[0].asFixnum() orelse return error.WrongType;
    const p = try argPort(services, args, 1, .input, .textual);
    const k = try countOf(n);
    try checkReadable(services, p);
    if (k == 0) return .fromString(try services.heap.createString(""));
    return try readText(services, p, k, false) orelse .eof_value;
}

/// `(read port)`: the next datum of the textual input port `port`, or an end-of-file
/// object when only atmosphere is left (R7RS 6.13.2).
/// ポートの手元の入力を `Reader` に渡し、読めたバイトの数だけポートを進める。データとして読む
/// ので、リテラルの外の循環も許す(`Reader.code` を偽にする)。`#!fold-case` と
/// `#!no-fold-case` で変わった畳み込みの状態は、ポートに書き戻し、次の `read` に残す
/// (R7RS 2.1)。手元の入力の終わりでデータが終わっていない(`Incomplete`)か、終わりまで
/// 読んだ(最後のトークンが切れている恐れがある)ときは、ポートが足せる限り読み足して、
/// データの頭から読み直す(docs/plans/0019-phase5-ports-and-io.md の 5l の中身)。
///
/// Why: ファイルのポートの手元の入力は、末尾で文字が分かれていることがあり、UTF-8 として
/// 読めないバイトを含みうる(0019 の「5h と 5k が守る約束」)。`Reader` は、文字列リテラルの
/// 外の読めないバイトを読んだ結果が正しいことまでは保証しない(src/reader.zig のファズ)。
/// そのため、`Reader` には妥当な UTF-8 の前置部分(`validPrefix`)だけを渡す。その先が、
/// 終わりで分かれた文字なら読み足し、読めないバイトなら、データがそこに掛かったときに
/// `read-error` にする(`invalid UTF-8 input`。親のセッションの決定)。
fn read(services: *const Services, args: []const Value) Error!Value {
    const p = try argPort(services, args, 0, .input, .textual);
    try checkReadable(services, p);
    const heap = services.heap;
    // Why: `Reader` が読んでいる間に開いているリストの枠は、入れ子の深さに比例するので、
    // ヒープの上限に数える(`Collected` と同じ理由)。
    const was_refused = heap.external_refused;
    heap.external_refused = false;
    defer heap.external_refused = was_refused;
    // 長いデータのために伸ばしたバッファは、戻るときに元の大きさに戻す(`makeRoom`)。
    defer restoreBuffer(heap, p);
    // Why: 検査する範囲(窓)を区切り、データが窓の終わりに達したときだけ倍に広げる。呼ぶたびに
    // 手元の全体を検査すると、大きな手元から小さなデータを繰り返し読む費用が、読む回数の2乗に
    // なる(5l の査読で見つかった)。文字列ポートの中身は、作るときに検査した UTF-8 なので
    // (`Heap.createMemoryPort`)、検査しない。
    var window: usize = initial_window;
    while (true) {
        const all = port_mod.pending(services.heap, p);
        const checked = if (p.backing == .memory) all else all[0..@min(all.len, window)];
        const valid: ValidPrefix = if (p.backing == .memory) .{ .len = all.len, .cut = false } else validPrefix(checked);
        const held = checked[0..valid.len];
        // 前置部分の後ろに読めないバイトがある。読み足しても、窓を広げても、そこは変わらない。
        const blocked = valid.len < checked.len and !valid.cut;
        // 手元には、窓の外にまだ続きがある。読み足す前に、窓を広げて読み直す。
        const widen = checked.len < all.len;
        var r: reader.Reader = .{ .src = held, .fold_case = p.fold_case, .code = false };
        var arena: std.heap.ArenaAllocator = .init(heap.residentAllocator());
        defer arena.deinit();
        const datum = r.next(arena.allocator(), .{ .heap = heap }) catch |e| switch (e) {
            error.Incomplete => {
                if (blocked) return unreadable(services, error.InvalidUtf8);
                if (widen) {
                    window *|= 2;
                    continue;
                }
                switch (try addInput(services, p)) {
                    .added => continue,
                    .full => if (try makeRoom(services, p, held)) continue else return tooLong(services),
                    .none => return unreadable(services, if (valid.cut) error.InvalidUtf8 else error.Incomplete),
                }
            },
            error.OutOfMemory => return if (heap.external_refused) error.HeapLimit else error.OutOfMemory,
            error.HeapLimit => return error.HeapLimit,
            // Why: 手元の終わりで切れたトークン(`#!fold-ca` など)は、`Incomplete` でなく、
            // ほかの構文の誤りになりうる。読み足せる限り読み足して読み直し、読み足せない
            // ときだけ、その誤りを報告する。
            else => |syntax| {
                if (blocked) return unreadable(services, syntax);
                if (widen) {
                    window *|= 2;
                    continue;
                }
                switch (try addInput(services, p)) {
                    .added => continue,
                    .full => if (try makeRoom(services, p, held)) continue else return unreadable(services, syntax),
                    .none => return unreadable(services, if (valid.cut) error.InvalidUtf8 else syntax),
                }
            },
        };
        if (datum) |d| {
            // 手元の終わりまで読んだデータは、終わりの文字で閉じていなければ、続きが
            // トークンの続きでありうる。
            if (r.pos == held.len and !closesItself(held)) {
                if (blocked) return unreadable(services, error.InvalidUtf8);
                if (widen) {
                    window *|= 2;
                    continue;
                }
                switch (try addInput(services, p)) {
                    .added => continue,
                    .full => if (try makeRoom(services, p, held)) continue else return tooLong(services),
                    .none => if (valid.cut) return unreadable(services, error.InvalidUtf8),
                }
            }
            port_mod.consume(services.heap, p, r.pos);
            p.fold_case = r.fold_case;
            return d;
        }
        // 空白とコメントだけで手元が尽きた。最後の行コメントや指令が切れていることがあるので、
        // 何も読み終えたことにせず、読み足して頭から読み直す。読み足せないときだけ、全部を
        // 読み終えて EOF を返す。
        // Why: 途中までを読み終えたことにすると、その切れ目が、改行をまたぐ閉じたブロック
        // コメントの中に落ちうる(5l の査読で見つかった)。データの前の空白は、バッファが
        // 埋まったときに `makeRoom` が読み飛ばす。
        if (blocked) return unreadable(services, error.InvalidUtf8);
        if (widen) {
            window *|= 2;
            continue;
        }
        switch (try addInput(services, p)) {
            .added => continue,
            .full => if (try makeRoom(services, p, held)) continue else return tooLong(services),
            .none => {
                if (valid.cut) return unreadable(services, error.InvalidUtf8);
                port_mod.consume(services.heap, p, r.pos);
                p.fold_case = r.fold_case;
                return .eof_value;
            },
        }
    }
}

/// Reads past the spaces, line endings and line comments at the start of `held`, what
/// `p` holds, and gives whether there were any.
/// Why: データの前の空白で手元のバッファが埋まると、データの続きを読み足す余地が無い。
/// 空白と、行の終わりまで閉じた行コメントだけを数えるのは、`Reader` の空白の読み飛ばしが
/// 外から呼べず(src/reader.zig は L2 の所有)、この2つなら、読み飛ばしても `fold_case` も
/// データも変わらないからである。ブロックコメントと指令の前では止まる。
fn dropLeadingSpace(heap: *Heap, p: *Port, held: []const u8) bool {
    var i: usize = 0;
    while (i < held.len) {
        switch (held[i]) {
            ' ', '\t', '\n', '\r' => i += 1,
            ';' => i = (std.mem.indexOfAnyPos(u8, held, i, "\n\r") orelse break) + 1,
            else => break,
        }
    }
    if (i == 0) return false;
    port_mod.consume(heap, p, i);
    return true;
}

/// Makes room to add input to `p`, whose buffer is full of what it has not read,
/// `held`: by reading past the spaces before the datum, or else, for a file port, by
/// doubling its buffer; false when there is no way (the console).
/// Why: 1つのデータがバッファより長いときだけ、バッファを倍に伸ばし、`read` が戻るときに
/// 元の大きさに戻す(suchi/sucheme-zig#230 の決定。`restoreBuffer`)。伸ばす分は上限に数え、
/// 上限に収まらなければ `HeapLimit` である。コンソールの読み手のバッファは、REPL と共有で、
/// 伸ばせない。
fn makeRoom(services: *const Services, p: *Port, held: []const u8) Error!bool {
    if (dropLeadingSpace(services.heap, p, held)) return true;
    switch (p.backing) {
        .file => |*file| {
            const doubled = std.math.mul(usize, file.buffer.len, 2) catch return error.HeapLimit;
            try services.heap.resizeFileBuffer(p, doubled);
            return true;
        },
        .memory, .console => return false,
    }
}

/// Gives the file port `p` back a buffer of its usual size, if `read` made it larger
/// and what it has not read fits.
/// 戻せないとき(読んでいない分が多い、確保に失敗した)は、大きいまま残す。計上は残るが、
/// 次の `read` がまた戻す。
fn restoreBuffer(heap: *Heap, p: *Port) void {
    if (p.backing != .file) return;
    const file = &p.backing.file;
    if (file.buffer.len <= file_buffer_size) return;
    const unread = file.len - file.pos;
    if (unread > file_buffer_size) return;
    heap.resizeFileBuffer(p, file_buffer_size) catch {};
}

/// `Unreadable` for a datum that does not fit in what the console's reader can hold.
fn tooLong(services: *const Services) Error {
    if (services.reason) |reason| reason.* = "datum longer than the input buffer";
    return error.Unreadable;
}

/// How many bytes `read` checks as UTF-8 before it reads, at first; it doubles them
/// when the datum reaches their end.
const initial_window = 1024;

/// How much at the start of some bytes is valid UTF-8 (`validPrefix`).
const ValidPrefix = struct {
    len: usize,
    /// Whether what follows is a character cut off by the end of the bytes, rather
    /// than bytes that are not UTF-8.
    cut: bool,
};

/// How many bytes at the start of `bytes` are valid UTF-8, and whether what follows
/// them is a character cut off by the end of `bytes`, rather than bytes that are not
/// UTF-8.
fn validPrefix(bytes: []const u8) ValidPrefix {
    var i: usize = 0;
    while (i < bytes.len) {
        const width = std.unicode.utf8ByteSequenceLength(bytes[i]) catch return .{ .len = i, .cut = false };
        if (i + width > bytes.len) {
            // 揃っている続きのバイトが正しければ、終わりで切れた文字である。
            for (bytes[i + 1 ..]) |b| if (b & 0xC0 != 0x80) return .{ .len = i, .cut = false };
            return .{ .len = i, .cut = true };
        }
        _ = std.unicode.utf8Decode(bytes[i..][0..width]) catch return .{ .len = i, .cut = false };
        i += width;
    }
    return .{ .len = i, .cut = false };
}

/// Whether the datum that `held` ends with is closed by its last character: a `)`
/// or a `"`, after which nothing can continue it.
fn closesItself(held: []const u8) bool {
    return held.len > 0 and (held[held.len - 1] == ')' or held[held.len - 1] == '"');
}

/// Adds to what the textual input port `p` holds: whether it added anything, or
/// could not because what it holds fills its buffer.
/// 読んでいない分でバッファが埋まっていると、ファイルのポートもコンソールも読み足せない
/// (`port.fill`)。そのときは `makeRoom` が場所を作る。
fn addInput(services: *const Services, p: *Port) Error!enum { added, full, none } {
    switch (p.backing) {
        .file => |*file| if (file.pos == 0 and file.len == file.buffer.len and !file.at_end) return .full,
        .console => if (port_mod.consoleFull(services.heap)) return .full,
        .memory => {},
    }
    const added = port_mod.fill(services.heap, p) catch |e| return portFailure(e);
    return if (added) .added else .none;
}

/// `Unreadable`, with the text of what the reader could not read put where the
/// machine takes it.
fn unreadable(services: *const Services, e: reader.SyntaxError) Error {
    if (services.reason) |reason| reason.* = reader.describe(e);
    return error.Unreadable;
}

/// `(read-u8 port)`: the next byte, or an end-of-file object (R7RS 6.13.2).
fn readU8(services: *const Services, args: []const Value) Error!Value {
    const p = try argPort(services, args, 0, .input, .binary);
    const b = port_mod.readByte(services.heap, p) catch |e| return portFailure(e);
    return if (b) |byte| .fromFixnum(byte) else .eof_value;
}

/// `(peek-u8 port)`: the next byte, without reading past it.
fn peekU8(services: *const Services, args: []const Value) Error!Value {
    const p = try argPort(services, args, 0, .input, .binary);
    const b = port_mod.peekByte(services.heap, p) catch |e| return portFailure(e);
    return if (b) |byte| .fromFixnum(byte) else .eof_value;
}

/// `(u8-ready? port)`: whether a byte can be read without waiting.
fn isU8Ready(services: *const Services, args: []const Value) Error!Value {
    const p = try argPort(services, args, 0, .input, .binary);
    try checkReadable(services, p);
    return .fromBool(true);
}

/// The bytes the binary input port `p` holds, after adding to them from its source
/// when it holds none; empty at the end.
fn nextBytes(services: *const Services, p: *Port) Error![]const u8 {
    const rest = port_mod.pending(services.heap, p);
    if (rest.len != 0) return rest;
    _ = port_mod.fill(services.heap, p) catch |e| return portFailure(e);
    return port_mod.pending(services.heap, p);
}

/// `(read-bytevector k port)`: a new bytevector of the next `k` bytes, or of as many as
/// are left, or an end-of-file object when none is left (R7RS 6.13.2).
/// `k` が 0 なら、何も読まずに空のバイトベクタを返す。
fn readBytevector(services: *const Services, args: []const Value) Error!Value {
    const n = args[0].asFixnum() orelse return error.WrongType;
    const p = try argPort(services, args, 1, .input, .binary);
    const k = try countOf(n);
    try checkReadable(services, p);
    if (k == 0) return .fromBytevector(try services.heap.createBytevector(""));
    // Why: ファイルのポートは、バッファにある分しか手元に持たないので、読み足しながら
    // ためる(`readText` と同じ理由)。
    var collected: Collected = .init(services.heap);
    defer collected.deinit();
    while (collected.bytes.items.len < k) {
        const rest = try nextBytes(services, p);
        if (rest.len == 0) break;
        const taken = @min(k - collected.bytes.items.len, rest.len);
        try collected.append(rest[0..taken]);
        port_mod.consume(services.heap, p, taken);
    }
    if (collected.bytes.items.len == 0) return .eof_value;
    return .fromBytevector(try services.heap.createBytevector(collected.bytes.items));
}

/// `(read-bytevector! bytevector port)`, `(read-bytevector! bytevector port start)` and
/// `(read-bytevector! bytevector port start end)`: reads the next bytes into `bytevector`
/// from `start` up to `end`, and gives how many it read, or an end-of-file object when
/// none is left (R7RS 6.13.2).
/// 定数のバイトベクタは、範囲が空でも断る。範囲が空なら、何も読まずに 0 を返す。終わりに
/// あっても、範囲が空なら EOF でなく 0 である(R7RS 6.13.2 は、この境界を書き分けていない。
/// `read-bytevector` の `k` が 0 のときと同じく、何も求めない呼び出しは何も返さない形にした)。
fn readBytevectorInto(services: *const Services, args: []const Value) Error!Value {
    const target = args[0].asBytevector() orelse return error.WrongType;
    const p = try argPort(services, args, 1, .input, .binary);
    const operands = try RangeOperands.of(args, 2);
    try immutable.requireMutable(args[0]);
    const range = try resolveRange(operands, target.bytes.len);
    try checkReadable(services, p);
    if (range.start == range.end) return .fromFixnum(0);
    // ファイルのポートは、範囲が埋まるか終わりに着くまで、読み足す。
    var n: usize = 0;
    while (range.start + n < range.end) {
        const rest = try nextBytes(services, p);
        if (rest.len == 0) break;
        const taken = @min(range.end - range.start - n, rest.len);
        @memcpy(target.bytes[range.start + n ..][0..taken], rest[0..taken]);
        port_mod.consume(services.heap, p, taken);
        n += taken;
    }
    if (n == 0) return .eof_value;
    return .fromFixnum(@intCast(n));
}

/// Writes `bytes` to `p`, which the caller has checked to be an output port of the
/// right kind.
fn put(services: *const Services, p: *Port, bytes: []const u8) Error!Value {
    const sink = if (services.console) |console| console.sink else null;
    port_mod.writeBytes(services.heap, sink, p, bytes) catch |e| return portFailure(e);
    return .unspecified_value;
}

/// `(newline port)`: writes an end of line, which is a linefeed (R7RS 6.13.3).
fn newline(services: *const Services, args: []const Value) Error!Value {
    return put(services, try argPort(services, args, 0, .output, .textual), "\n");
}

/// `(write-char char port)`: writes `char` (R7RS 6.13.3).
fn writeChar(services: *const Services, args: []const Value) Error!Value {
    const c = args[0].asCharacter() orelse return error.WrongType;
    const p = try argPort(services, args, 1, .output, .textual);
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
    const p = try argPort(services, args, 1, .output, .textual);
    const operands = try RangeOperands.of(args, 2);
    const range = try resolveRange(operands, s.length());
    const span = s.byteSpan(range.start, range.end);
    return put(services, p, s.bytes[span.from..span.to]);
}

/// `(write-u8 byte port)`: writes `byte` (R7RS 6.13.3).
fn writeU8(services: *const Services, args: []const Value) Error!Value {
    const byte = byteOf(args[0]) orelse return error.WrongType;
    const p = try argPort(services, args, 1, .output, .binary);
    return put(services, p, &.{byte});
}

/// `(write-bytevector bytevector port)`, `(write-bytevector bytevector port start)` and
/// `(write-bytevector bytevector port start end)`: writes the bytes of `bytevector` from
/// `start` up to `end` (R7RS 6.13.3).
fn writeBytevector(services: *const Services, args: []const Value) Error!Value {
    const b = args[0].asBytevector() orelse return error.WrongType;
    const p = try argPort(services, args, 1, .output, .binary);
    const operands = try RangeOperands.of(args, 2);
    const range = try resolveRange(operands, b.bytes.len);
    return put(services, p, b.bytes[range.start..range.end]);
}

/// `(flush-output-port)` and `(flush-output-port port)`: writes out what the port holds
/// (R7RS 6.13.3).
/// 文字列ポートとバイトベクタポートは、書き出す先が無いので、開いているかだけを確かめる。
/// コンソールのポートは、書き手の中にためたものを書き出す(REPL の途中の出力を見せるため)。
/// ファイルのポートは、バッファにためたものをファイルに書く。
fn flushOutputPort(services: *const Services, args: []const Value) Error!Value {
    const p = if (args.len > 0) args[0].asPort() orelse return error.WrongType else try argPort(services, args, 0, .output, .textual);
    if (p.direction != .output) return error.WrongType;
    port_mod.flush(services.heap, p) catch |e| return portFailure(e);
    if (p.backing == .console) {
        if (services.console) |console| if (console.sink) |sink| sink.flush() catch return error.WriteFailed;
    }
    return .unspecified_value;
}

/// `(write obj)` and `(write obj port)`: writes `obj` with labels for its cycles only
/// (R7RS 6.13.3, `(scheme write)`).
fn write(services: *const Services, args: []const Value) Error!Value {
    return writeAs(services, args, .write);
}

/// `(write-shared obj)` and `(write-shared obj port)`: writes `obj` with labels for all
/// the pairs and vectors that appear more than once (R7RS 6.13.3).
fn writeShared(services: *const Services, args: []const Value) Error!Value {
    return writeAs(services, args, .shared);
}

/// `(write-simple obj)` and `(write-simple obj port)`: writes `obj` with no labels
/// (R7RS 6.13.3). It does not end on a cycle.
fn writeSimple(services: *const Services, args: []const Value) Error!Value {
    return writeAs(services, args, .simple);
}

/// `(display obj)` and `(display obj port)`: writes `obj` as `display` shows it
/// (R7RS 6.13.3, `(scheme write)`).
fn display(services: *const Services, args: []const Value) Error!Value {
    return writeAs(services, args, .display);
}

/// Writes `args[0]` to the port `args[1]`, or to the current output port, in the form
/// of `mode`.
/// 書く形はプリンタが決め、ポートの書き手(`port.Writer`)を通して、ポートに直接書く。何も
/// 書かない値(空の文字列)でも、閉じたポートは断るので、先に空の書き込みで確かめる。
/// プリンタの作業領域はヒープの上限に数え、収まらなければ `HeapLimit` である。
fn writeAs(services: *const Services, args: []const Value, mode: printer.Mode) Error!Value {
    const p = try argPort(services, args, 1, .output, .textual);
    _ = try put(services, p, "");
    const sink = if (services.console) |console| console.sink else null;
    var buffer: [256]u8 = undefined;
    var w: port_mod.Writer = .init(services.heap, sink, p, &buffer);
    printer.print(&w.interface, services.heap, &services.heap.symbols, args[0], mode) catch |e| switch (e) {
        error.WriteFailed => return portFailure(w.failure.?),
        error.OutOfMemory => return error.OutOfMemory,
        error.HeapLimit => return error.HeapLimit,
    };
    w.interface.flush() catch return portFailure(w.failure.?);
    return .unspecified_value;
}

/// `(%console-parameter k)`: the parameter that is the current input port (0), output
/// port (1) or error port (2).
/// `lib/sucheme/procedures.scm` が、`current-input-port` などの名前に束縛する。
fn consoleParameter(services: *const Services, args: []const Value) Error!Value {
    const console = services.console orelse return error.WrongType;
    const k = args[0].asFixnum() orelse return error.WrongType;
    const stream: Port.Stream = switch (k) {
        0 => .input,
        1 => .output,
        2 => .error_output,
        else => return error.OutOfRange,
    };
    return .fromParameter(try consoleParameterOf(services.heap, console, stream));
}

/// The parameter of `console` for `stream`, made with a new console port the first time
/// it is asked for.
/// Why: 初期化で作ると、コンテキストを作るだけのテストが、ヒープの中身を数え直すことになる。
/// 標準ライブラリを読み込むと `lib/sucheme/procedures.scm` が3つとも求めるので、利用者の
/// プログラムが走る前に、必ず作られている。作ったあとは `Context.mark` がルートにする。
/// GC は機械のステップの境目でしか走らない(ADR-0031)ので、ポートとパラメータの2回の確保の
/// 間に回収されることはない。
fn consoleParameterOf(heap: *@import("../heap.zig").Heap, console: *value.Console, stream: Port.Stream) Error!*value.Parameter {
    const slot = switch (stream) {
        .input => &console.input,
        .output => &console.output,
        .error_output => &console.error_output,
    };
    if (slot.*) |param| return param;
    const port = try heap.createConsolePort(stream);
    const param = try heap.create(value.Parameter, .{ .value = .fromPort(port), .converter = null });
    slot.* = param;
    return param;
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

test "the primitives take the numbers of arguments the language gives them, with the port left out or given" {
    const expected = [_]struct { []const u8, u8, ?u8 }{
        .{ "port?", 1, 1 },                 .{ "input-port?", 1, 1 },             .{ "output-port?", 1, 1 },
        .{ "textual-port?", 1, 1 },         .{ "binary-port?", 1, 1 },            .{ "input-port-open?", 1, 1 },
        .{ "output-port-open?", 1, 1 },     .{ "close-port", 1, 1 },              .{ "close-input-port", 1, 1 },
        .{ "close-output-port", 1, 1 },     .{ "open-input-string", 1, 1 },       .{ "open-output-string", 0, 0 },
        .{ "get-output-string", 1, 1 },     .{ "open-input-bytevector", 1, 1 },   .{ "open-output-bytevector", 0, 0 },
        .{ "get-output-bytevector", 1, 1 }, .{ "read-char", 0, 1 },               .{ "peek-char", 0, 1 },
        .{ "read-line", 0, 1 },             .{ "char-ready?", 0, 1 },             .{ "read-string", 1, 2 },
        .{ "read-u8", 0, 1 },               .{ "peek-u8", 0, 1 },                 .{ "u8-ready?", 0, 1 },
        .{ "read-bytevector", 1, 2 },       .{ "read-bytevector!", 1, 4 },        .{ "newline", 0, 1 },
        .{ "write-char", 1, 2 },            .{ "write-string", 1, 4 },            .{ "write-u8", 1, 2 },
        .{ "write-bytevector", 1, 4 },      .{ "flush-output-port", 0, 1 },       .{ "write", 1, 2 },
        .{ "write-shared", 1, 2 },          .{ "write-simple", 1, 2 },            .{ "display", 1, 2 },
        .{ "%console-parameter", 1, 1 },    .{ "open-input-file", 1, 1 },         .{ "open-binary-input-file", 1, 1 },
        .{ "open-output-file", 1, 1 },      .{ "open-binary-output-file", 1, 1 }, .{ "file-exists?", 1, 1 },
        .{ "delete-file", 1, 1 },           .{ "read", 0, 1 },
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

test "read-line reads a blank line as an empty line, whichever ends it" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    const p = try call(&f, "open-input-string", &.{try str(&f, "a\n\nb\r\r\nc\n\r\n")});
    for ([_][]const u8{ "a", "", "b", "", "c", "" }) |line| try expectString(line, try call(&f, "read-line", &.{p}));
    try expectEof(try call(&f, "read-line", &.{p}));
}

test "read-line ends a line at a return that is the last character" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    for ([_][]const u8{ "a\rb\n", "c\r", "\r" }) |input| {
        const p = try call(&f, "open-input-string", &.{try str(&f, input)});
        _ = try call(&f, "read-line", &.{p});
        if (std.mem.eql(u8, input, "a\rb\n")) try expectString("b", try call(&f, "read-line", &.{p}));
        try expectEof(try call(&f, "read-line", &.{p}));
    }
}

test "a count of zero reads nothing, but a closed port is still refused, and at the end the result is empty" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    const text = try call(&f, "open-input-string", &.{try str(&f, "a")});
    const bytes = try call(&f, "open-input-bytevector", &.{try bv(&f, &.{1})});
    try expectString("", try call(&f, "read-string", &.{ fix(0), text }));
    try expectBytes(&.{}, try call(&f, "read-bytevector", &.{ fix(0), bytes }));
    // 0 個を求めても、読み進めない。
    try std.testing.expectEqual(chr('a'), try call(&f, "read-char", &.{text}));
    try std.testing.expectEqual(fix(1), try call(&f, "read-u8", &.{bytes}));
    // 終わりでも、0 個を求めたら空である(EOF でない)。read-bytevector! の空の範囲も 0 である。
    try expectString("", try call(&f, "read-string", &.{ fix(0), text }));
    try expectBytes(&.{}, try call(&f, "read-bytevector", &.{ fix(0), bytes }));
    const target = try bv(&f, &.{0});
    try std.testing.expectEqual(fix(0), try call(&f, "read-bytevector!", &.{ target, bytes, fix(0), fix(0) }));
    _ = try call(&f, "close-port", &.{text});
    _ = try call(&f, "close-port", &.{bytes});
    try std.testing.expectError(error.PortClosed, call(&f, "read-string", &.{ fix(0), text }));
    try std.testing.expectError(error.PortClosed, call(&f, "read-bytevector", &.{ fix(0), bytes }));
    try std.testing.expectError(error.PortClosed, call(&f, "read-bytevector!", &.{ target, bytes, fix(0), fix(0) }));
}

test "a count far larger than what is left allocates only what is left" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    const text = try call(&f, "open-input-string", &.{try str(&f, "abc")});
    const bytes = try call(&f, "open-input-bytevector", &.{try bv(&f, &.{ 1, 2 })});
    const before = f.heap.accounted;
    try expectString("abc", try call(&f, "read-string", &.{ fix(std.math.maxInt(i64)), text }));
    try expectBytes(&.{ 1, 2 }, try call(&f, "read-bytevector", &.{ fix(std.math.maxInt(i64)), bytes }));
    // 確保したのは、読んだ 3 文字の文字列と 2 バイトのバイトベクタだけである。
    const heap_mod = @import("../heap.zig");
    try std.testing.expectEqual(before + heap_mod.cellBytes(value.String) + 3 + heap_mod.cellBytes(value.Bytevector) + 2, f.heap.accounted);
}

test "display writes what the printer's display shows to the port, and refuses a closed port" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    const p = try call(&f, "open-output-string", &.{});
    const list = try f.heap.cons(try str(&f, "a"), try f.heap.cons(chr('b'), .empty_list_value));
    _ = try call(&f, "display", &.{ list, p });
    _ = try call(&f, "display", &.{ try str(&f, "λ"), p });
    try expectString("(a b)λ", try call(&f, "get-output-string", &.{p}));
    _ = try call(&f, "close-port", &.{p});
    try std.testing.expectError(error.PortClosed, call(&f, "display", &.{ try str(&f, ""), p }));
    try std.testing.expectError(error.PortClosed, call(&f, "display", &.{ list, p }));
    // 省略したポートは現在の出力ポートで、コンソールを持たない呼び出しでは型の誤りである。
    try std.testing.expectError(error.WrongType, call(&f, "display", &.{fix(1)}));
}

test "write, write-shared and write-simple write to the port in their forms, and refuse a closed port" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    const p = try call(&f, "open-output-string", &.{});
    // (s s) の s は共有され、c は自分に戻る。
    const s = try f.heap.cons(try str(&f, "a"), .empty_list_value);
    const shared = try f.heap.cons(s, try f.heap.cons(s, .empty_list_value));
    const c = try f.heap.cons(fix(1), .empty_list_value);
    c.asPair().?.cdr = c;
    _ = try call(&f, "write", &.{ shared, p });
    _ = try call(&f, "write-shared", &.{ shared, p });
    _ = try call(&f, "write-simple", &.{ shared, p });
    _ = try call(&f, "write", &.{ c, p });
    _ = try call(&f, "write-shared", &.{ c, p });
    _ = try call(&f, "display", &.{ c, p });
    try expectString("((\"a\") (\"a\"))(#0=(\"a\") #0#)((\"a\") (\"a\"))#0=(1 . #0#)#0=(1 . #0#)#0=(1 . #0#)", try call(&f, "get-output-string", &.{p}));
    _ = try call(&f, "close-port", &.{p});
    for ([_][]const u8{ "write", "write-shared", "write-simple" }) |name| {
        try std.testing.expectError(error.PortClosed, call(&f, name, &.{ fix(1), p }));
    }
}

test "write-simple writes no label for a cycle, and runs into the limit where write stops" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    const c = try f.heap.cons(fix(1), .empty_list_value);
    c.asPair().?.cdr = c;
    const p = try call(&f, "open-output-string", &.{});
    // 文字列ポートの領域が伸び続けるので、上限で止まる。
    const limit = f.heap.options.limit;
    f.heap.options.limit = f.heap.held() + 64 * 1024;
    try std.testing.expectError(error.HeapLimit, call(&f, "write-simple", &.{ c, p }));
    f.heap.options.limit = limit;
    const q = try call(&f, "open-output-string", &.{});
    _ = try call(&f, "write", &.{ c, q });
    try expectString("#0=(1 . #0#)", try call(&f, "get-output-string", &.{q}));
}

test "write fails with HeapLimit when the printer's table does not fit in the heap" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    const p = try call(&f, "open-output-string", &.{});
    var l: Value = .empty_list_value;
    for (0..32) |_| l = try f.heap.cons(fix(1), l);
    f.heap.options.limit = f.heap.held() + 16;
    const before = f.heap.resident;
    try std.testing.expectError(error.HeapLimit, call(&f, "write", &.{ l, p }));
    try std.testing.expectEqual(before, f.heap.resident);
    // 数の書式の作業領域が断られても、ポートの失敗でなく上限の誤りである。
    var c: value.Compnum = .{ .real = fix(1), .imag = fix(2) };
    f.heap.options.limit = f.heap.held() + 8;
    try std.testing.expectError(error.HeapLimit, call(&f, "write", &.{ .fromCompnum(&c), p }));
}

test "display of a long string goes to the port without the whole text in the scratch space" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    const long = try f.heap.createStringFilled(10_000, struct {
        pub fn fill(_: @This(), bytes: []u8) void {
            @memset(bytes, 'x');
        }
    }{});
    const p = try call(&f, "open-output-string", &.{});
    // 作業領域を、全体の写しが入らない大きさに絞る。プリンタの作業スタックはヒープの上限に
    // 数える確保で持つので、作業領域を使わない(スライス 5j)。
    var small: [4096]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&small);
    f.services.scratch = fba.allocator();
    _ = try call(&f, "display", &.{ .fromString(long), p });
    try std.testing.expectEqual(10_000, (try call(&f, "get-output-string", &.{p})).asString().?.bytes.len);
}

/// A host with one file in memory, which gives at most `chunk` bytes a read, for the
/// tests of `read` on a file port.
const OneFile = struct {
    contents: []const u8,
    at: usize = 0,
    chunk: usize = 1000,
    reads: usize = 0,

    fn host(self: *OneFile) Heap.FileHost {
        return .{ .context = self, .open = open, .delete = delete, .exists = exists, .read = readFile, .write = writeFile, .close = closeFile };
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

    fn readFile(context: *anyopaque, _: u32, buffer: []u8) error{Io}!usize {
        const self: *OneFile = @ptrCast(@alignCast(context));
        const n = @min(buffer.len, self.chunk, self.contents.len - self.at);
        @memcpy(buffer[0..n], self.contents[self.at..][0..n]);
        self.at += n;
        self.reads += 1;
        return n;
    }

    fn writeFile(_: *anyopaque, _: u32, _: []const u8) error{Io}!void {}

    fn closeFile(_: *anyopaque, _: u32) void {}
};

test "read gives the buffer of a file port back its usual size after a datum longer than it" {
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(std.testing.allocator);
    try list.append(std.testing.allocator, '(');
    for (0..3 * file_buffer_size / 5) |_| try list.appendSlice(std.testing.allocator, "1234 ");
    try list.appendSlice(std.testing.allocator, ") 7");
    var file: OneFile = .{ .contents = list.items };
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    f.heap.files = file.host();
    const p = try f.heap.createFilePort(.input, .textual, file_buffer_size);
    p.open = true;
    const before = f.heap.accounted;
    const objects_before = f.heap.count;
    const datum = try call(&f, "read", &.{.fromPort(p)});
    try std.testing.expectEqual(3 * file_buffer_size / 5, @import("pair.zig").properLength(datum).?);
    // 読むために伸ばしたバッファは、元の大きさに戻り、その分の計上も戻る。増えた計上は、
    // 読んだリストのペアの分だけである(数は fixnum で、確保しない)。
    try std.testing.expectEqual(file_buffer_size, p.backing.file.buffer.len);
    const pairs = f.heap.count - objects_before;
    try std.testing.expectEqual(3 * file_buffer_size / 5, pairs);
    try std.testing.expectEqual(before + pairs * @import("../heap.zig").cellBytes(value.Pair), f.heap.accounted);
    try std.testing.expectEqual(7, (try call(&f, "read", &.{.fromPort(p)})).asFixnum().?);
    try std.testing.expect((try call(&f, "read", &.{.fromPort(p)})).isEqv(.eof_value));
    _ = try call(&f, "close-port", &.{.fromPort(p)});
}

test "read takes a datum many times longer than the buffer with a number of reads that grows with its logarithm" {
    // Why: バッファを倍ずつ伸ばすので、読み足す回数はデータの長さの対数に比例する。少しずつ
    // 伸ばす形に戻ると、データの長さに比例する回数になる。ホストが1回に満たせる量に上限を
    // 置かないので、読み足しの回数がそのまま伸ばした回数の目安になる。
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(std.testing.allocator);
    try list.append(std.testing.allocator, '(');
    for (0..16 * file_buffer_size / 5) |_| try list.appendSlice(std.testing.allocator, "1234 ");
    try list.appendSlice(std.testing.allocator, ")");
    var file: OneFile = .{ .contents = list.items, .chunk = std.math.maxInt(usize) };
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    f.heap.files = file.host();
    const p = try f.heap.createFilePort(.input, .textual, file_buffer_size);
    p.open = true;
    const datum = try call(&f, "read", &.{.fromPort(p)});
    try std.testing.expectEqual(16 * file_buffer_size / 5, @import("pair.zig").properLength(datum).?);
    try std.testing.expect(file.reads <= 8);
}

test "read gives the buffer back its usual size when what is left to read fills it exactly" {
    // 12288 バイトのデータを読むと、バッファは 16384 バイトまで伸び、読み終えたあとの残りは、
    // ちょうど元の大きさ(4096 バイト)である。残りが収まる限り、元の大きさに戻す。
    comptime std.debug.assert(file_buffer_size == 4096);
    var contents: std.ArrayList(u8) = .empty;
    defer contents.deinit(std.testing.allocator);
    try contents.append(std.testing.allocator, '(');
    while (contents.items.len < 3 * file_buffer_size - 1) try contents.append(std.testing.allocator, ' ');
    try contents.append(std.testing.allocator, ')');
    while (contents.items.len < 4 * file_buffer_size - 1) try contents.append(std.testing.allocator, ' ');
    try contents.append(std.testing.allocator, '7');
    var file: OneFile = .{ .contents = contents.items, .chunk = std.math.maxInt(usize) };
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    f.heap.files = file.host();
    const p = try f.heap.createFilePort(.input, .textual, file_buffer_size);
    p.open = true;
    const before = f.heap.accounted;
    try std.testing.expect((try call(&f, "read", &.{.fromPort(p)})).isEqv(.empty_list_value));
    try std.testing.expectEqual(file_buffer_size, p.backing.file.len - p.backing.file.pos);
    try std.testing.expectEqual(file_buffer_size, p.backing.file.buffer.len);
    try std.testing.expectEqual(before, f.heap.accounted);
    try std.testing.expectEqual(7, (try call(&f, "read", &.{.fromPort(p)})).asFixnum().?);
}

test "read on the console reads past the spaces before a datum that fill its buffer, and finds bytes that are not UTF-8 at their end" {
    // Why: コンソールの読み手のバッファは伸ばせないので、満杯のときに場所を作れるのは、データの
    // 前の空白と行コメントの読み飛ばしだけである。読み飛ばせば、続きが無いことが分かり、閉じて
    // いないデータの誤りになる。読み飛ばさなければ、長すぎるデータの誤りになる。`.fixed` の
    // 読み手は、最初からバッファが満杯である。
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    var reason: []const u8 = "";
    f.services.reason = &reason;
    const p = try f.heap.createConsolePort(.input);
    for ([_][]const u8{ "  (a", "\t(a", "\r(a", "; c\n(a" }) |input| {
        var source: std.Io.Reader = .fixed(input);
        f.heap.console_input = &source;
        try std.testing.expectError(error.Unreadable, call(&f, "read", &.{.fromPort(p)}));
        try std.testing.expectEqualStrings("unexpected end of input", reason);
    }
    // 満杯のバッファの終わりのバイトが、切れた文字でなく、UTF-8 として読めないもの(先頭の
    // バイトに、続きのバイトでないものが続く)なら、読み足すまでもなく読めない入力である。
    var source: std.Io.Reader = .fixed("ab\xe3\xc3");
    f.heap.console_input = &source;
    try std.testing.expectError(error.Unreadable, call(&f, "read", &.{.fromPort(p)}));
    try std.testing.expectEqualStrings("invalid UTF-8 input", reason);
}
