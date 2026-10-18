//! Bytevector primitives (R7RS 6.9), and the two that carry strings to and from bytevectors
//! (`utf8->string` and `string->utf8`, R7RS 6.9).
//!
//! バイトベクタは 0 から 255 までの整数の並びで、長さは作ったときに決まる。バイトは整数の
//! 型の一種として扱う。整数でないものも、範囲外の整数(256 や -1)も、型の誤りである。
//! 位置(`k` `start` `end` `at`)の誤りは範囲の誤りで、型の検査をすべて済ませたあとに調べる。
//!
//! 変更する手続き(`bytevector-u8-set!` `bytevector-copy!`)は、型を検査したあと、範囲を検査する
//! 前に、引数が定数でないことを検査する(`immutable.requireMutable`)。範囲が空でも、定数なら
//! 断る。
//!
//! 入力の大きさに比例して確保するもの(`make-bytevector` `bytevector-append` `utf8->string`
//! `string->utf8` `bytevector-copy`)は、確保する領域を先に上限に照らして検査し、領域へ直接書く。
//! 一時の領域は作らない(`Heap.createBytevectorFilled`)。

const std = @import("std");
const value = @import("../value.zig");
const Value = value.Value;
const Primitive = value.Primitive;
const Services = value.Services;
const PrimitiveError = value.PrimitiveError;
const immutable = @import("immutable.zig");
const range_mod = @import("range.zig");
const RangeOperands = range_mod.RangeOperands;
const resolveRange = range_mod.resolveRange;

pub const Error = PrimitiveError;

pub const primitives = [_]Primitive{
    .{ .name = "bytevector?", .min_args = 1, .max_args = 1, .body = .{ .pure = &isBytevector } },
    .{ .name = "make-bytevector", .min_args = 1, .max_args = 2, .body = .{ .pure = &makeBytevector } },
    .{ .name = "bytevector", .min_args = 0, .max_args = null, .body = .{ .pure = &bytevector } },
    .{ .name = "bytevector-length", .min_args = 1, .max_args = 1, .body = .{ .pure = &bytevectorLength } },
    .{ .name = "bytevector-u8-ref", .min_args = 2, .max_args = 2, .body = .{ .pure = &bytevectorRef } },
    .{ .name = "bytevector-u8-set!", .min_args = 3, .max_args = 3, .body = .{ .pure = &bytevectorSet } },
    .{ .name = "bytevector-copy", .min_args = 1, .max_args = 3, .body = .{ .pure = &bytevectorCopy } },
    .{ .name = "bytevector-copy!", .min_args = 3, .max_args = 5, .body = .{ .pure = &bytevectorCopyInto } },
    .{ .name = "bytevector-append", .min_args = 0, .max_args = null, .body = .{ .pure = &bytevectorAppend } },
    .{ .name = "utf8->string", .min_args = 1, .max_args = 3, .body = .{ .pure = &utf8ToString } },
    .{ .name = "string->utf8", .min_args = 1, .max_args = 3, .body = .{ .pure = &stringToUtf8 } },
};

/// The byte that `v` is, or null when `v` is not an exact integer from 0 to 255.
fn byteOf(v: Value) ?u8 {
    return std.math.cast(u8, v.asFixnum() orelse return null);
}

/// `(bytevector? obj)`.
fn isBytevector(_: *const Services, args: []const Value) Error!Value {
    return .fromBool(args[0].asBytevector() != null);
}

/// Writes `byte` in every place.
const RepeatFiller = struct {
    byte: u8,

    pub fn fill(self: RepeatFiller, bytes: []u8) void {
        @memset(bytes, self.byte);
    }
};

/// `(make-bytevector k)` and `(make-bytevector k byte)`: a new bytevector of `k` bytes, all
/// `byte` (R7RS 6.9).
///
/// R7RS 6.9 は、`byte` がなければ中身を未規定としている。ここでは 0 で埋める。大きさは、
/// 一時の領域を経ずに直接確保し、上限に収まらなければ `HeapLimit` である。`usize` に収まらない
/// 大きさは、範囲の誤りでなく、上限超過として扱う(`make-string` と同じ)。
fn makeBytevector(services: *const Services, args: []const Value) Error!Value {
    const k = args[0].asFixnum() orelse return error.WrongType;
    const fill: u8 = if (args.len > 1) byteOf(args[1]) orelse return error.WrongType else 0;
    if (k < 0) return error.OutOfRange;
    const len = std.math.cast(usize, k) orelse return error.HeapLimit;
    return .fromBytevector(try services.heap.createBytevectorFilled(len, RepeatFiller{ .byte = fill }));
}

/// `(bytevector byte ...)`: a new bytevector of the arguments, in order (R7RS 6.9).
///
/// 引数がすべてバイトであることを、確保の前に検査する。確保する量は、引数の個数に比例する。
fn bytevector(services: *const Services, args: []const Value) Error!Value {
    for (args) |a| _ = byteOf(a) orelse return error.WrongType;
    return .fromBytevector(try services.heap.createBytevectorFilled(args.len, ArgsFiller{ .args = args }));
}

/// Writes the bytes that `args`, which are all bytes, are.
const ArgsFiller = struct {
    args: []const Value,

    pub fn fill(self: ArgsFiller, bytes: []u8) void {
        for (bytes, self.args) |*slot, a| slot.* = byteOf(a).?;
    }
};

/// `(bytevector-length bytevector)`.
fn bytevectorLength(_: *const Services, args: []const Value) Error!Value {
    const b = args[0].asBytevector() orelse return error.WrongType;
    // 要素の数は、確保できた大きさを超えないので、i64 に収まる。
    return .fromFixnum(@intCast(b.bytes.len));
}

/// `(bytevector-u8-ref bytevector k)`: the `k`th byte, counted from 0 (R7RS 6.9).
///
/// Why: 引数は 64 ビットの整数なので、`usize` に変えられるかを先に調べる(`vector-ref` と同じ)。
fn bytevectorRef(_: *const Services, args: []const Value) Error!Value {
    const b = args[0].asBytevector() orelse return error.WrongType;
    const k = args[1].asFixnum() orelse return error.WrongType;
    const index = std.math.cast(usize, k) orelse return error.OutOfRange;
    if (index >= b.bytes.len) return error.OutOfRange;
    return .fromFixnum(b.bytes[index]);
}

/// `(bytevector-u8-set! bytevector k byte)`: stores `byte` as the `k`th byte (R7RS 6.9).
///
/// 定数のバイトベクタは書き換えない(R7RS 3.4)。検査の順序は、型、不変、範囲である。
fn bytevectorSet(_: *const Services, args: []const Value) Error!Value {
    const b = args[0].asBytevector() orelse return error.WrongType;
    const k = args[1].asFixnum() orelse return error.WrongType;
    const byte = byteOf(args[2]) orelse return error.WrongType;
    try immutable.requireMutable(args[0]);
    const index = std.math.cast(usize, k) orelse return error.OutOfRange;
    if (index >= b.bytes.len) return error.OutOfRange;
    b.bytes[index] = byte;
    return .unspecified_value;
}

/// `(bytevector-copy bytevector)`, `(bytevector-copy bytevector start)` and
/// `(bytevector-copy bytevector start end)`: a new bytevector of the bytes from `start` up
/// to `end` (R7RS 6.9).
///
/// 結果は新しいバイトベクタで、定数ではない。元が定数でも、写しは書き換えられる。
fn bytevectorCopy(services: *const Services, args: []const Value) Error!Value {
    const b = args[0].asBytevector() orelse return error.WrongType;
    const operands = try RangeOperands.of(args, 1);
    const range = try resolveRange(operands, b.bytes.len);
    return .fromBytevector(try services.heap.createBytevector(b.bytes[range.start..range.end]));
}

/// `(bytevector-copy! to at from)`, `(bytevector-copy! to at from start)` and
/// `(bytevector-copy! to at from start end)`: copies the bytes of `from` from `start` up to
/// `end` into `to`, from position `at` (R7RS 6.9).
///
/// 重なる場合は、一時のバイトベクタに写してから書いたように振る舞う(`@memmove`)。`to` が
/// 定数なら断る。範囲が空でも断る。`from` は定数でもよい。
fn bytevectorCopyInto(_: *const Services, args: []const Value) Error!Value {
    const to = args[0].asBytevector() orelse return error.WrongType;
    const at_n = args[1].asFixnum() orelse return error.WrongType;
    const from = args[2].asBytevector() orelse return error.WrongType;
    const operands = try RangeOperands.of(args, 3);
    try immutable.requireMutable(args[0]);
    const plan = try range_mod.resolveCopy(at_n, to.bytes.len, operands, from.bytes.len);
    const source = from.bytes[plan.range.start..plan.range.end];
    @memmove(to.bytes[plan.at..][0..source.len], source);
    return .unspecified_value;
}

/// Writes the bytes of the bytevectors in `parts`.
const AppendFiller = struct {
    parts: []const Value,

    pub fn fill(self: AppendFiller, bytes: []u8) void {
        var i: usize = 0;
        for (self.parts) |part| {
            const b = part.asBytevector().?.bytes;
            @memcpy(bytes[i..][0..b.len], b);
            i += b.len;
        }
    }
};

/// `(bytevector-append bytevector ...)`: a new bytevector of the bytes of the bytevectors, in
/// order (R7RS 6.9). The result is a new bytevector even for one argument.
fn bytevectorAppend(services: *const Services, args: []const Value) Error!Value {
    var total: usize = 0;
    for (args) |a| {
        const b = a.asBytevector() orelse return error.WrongType;
        total = std.math.add(usize, total, b.bytes.len) catch return error.HeapLimit;
    }
    return .fromBytevector(try services.heap.createBytevectorFilled(total, AppendFiller{ .parts = args }));
}

/// Writes `bytes`.
const BytesFiller = struct {
    bytes: []const u8,

    pub fn fill(self: BytesFiller, bytes: []u8) void {
        @memcpy(bytes, self.bytes);
    }
};

/// `(utf8->string bytevector)`, `(utf8->string bytevector start)` and
/// `(utf8->string bytevector start end)`: a new string of the characters that the bytes from
/// `start` up to `end` encode (R7RS 6.9). `start` and `end` count bytes.
///
/// R7RS 6.9 は、妥当でない UTF-8 の並びを誤りとしている。文字列は妥当な UTF-8 であること
/// を前提とする(ADR-0008)ので、確保の前に検査し、妥当でなければ範囲の誤りにする。型は
/// 正しく、値がこの手続きの受け付ける範囲の外にあるからである。サロゲート、冗長な符号化、
/// 文字の途中で切れた範囲は、どれも妥当でない。
fn utf8ToString(services: *const Services, args: []const Value) Error!Value {
    const b = args[0].asBytevector() orelse return error.WrongType;
    const operands = try RangeOperands.of(args, 1);
    const range = try resolveRange(operands, b.bytes.len);
    const span = b.bytes[range.start..range.end];
    if (!std.unicode.utf8ValidateSlice(span)) return error.OutOfRange;
    return .fromString(try services.heap.createStringFilled(span.len, BytesFiller{ .bytes = span }));
}

/// `(string->utf8 string)`, `(string->utf8 string start)` and
/// `(string->utf8 string start end)`: a new bytevector of the UTF-8 encoding of the characters
/// from `start` up to `end` (R7RS 6.9). `start` and `end` count characters.
fn stringToUtf8(services: *const Services, args: []const Value) Error!Value {
    const s = args[0].asString() orelse return error.WrongType;
    const operands = try RangeOperands.of(args, 1);
    const range = try resolveRange(operands, s.length());
    const span = s.byteSpan(range.start, range.end);
    return .fromBytevector(try services.heap.createBytevector(s.bytes[span.from..span.to]));
}

test {
    std.testing.refAllDecls(@This());
}

const test_support = @import("test_support.zig");
const heap_mod = @import("../heap.zig");
const Bytevector = value.Bytevector;

fn call(f: *test_support.Fixture, name: []const u8, args: []const Value) Error!Value {
    return f.call(&primitives, name, args);
}

fn fix(n: i64) Value {
    return .fromFixnum(n);
}

/// A new bytevector of `octets`.
fn bv(f: *test_support.Fixture, octets: []const u8) !Value {
    return .fromBytevector(try f.heap.createBytevector(octets));
}

/// A constant bytevector of `octets`, as a literal is.
fn constant(f: *test_support.Fixture, octets: []const u8) !Value {
    const v = try bv(f, octets);
    heap_mod.makeImmutable(v);
    return v;
}

fn str(f: *test_support.Fixture, content: []const u8) !Value {
    return .fromString(try f.heap.createString(content));
}

fn expectBytes(expected: []const u8, result: Value) !void {
    try std.testing.expectEqual(value.Kind.bytevector, result.kind());
    try std.testing.expectEqualSlices(u8, expected, result.asBytevector().?.bytes);
}

test "the primitives take the numbers of arguments the language gives them" {
    const Arity = struct { name: []const u8, min: u8, max: ?u8 };
    const expected = [_]Arity{
        .{ .name = "bytevector?", .min = 1, .max = 1 },
        .{ .name = "make-bytevector", .min = 1, .max = 2 },
        .{ .name = "bytevector", .min = 0, .max = null },
        .{ .name = "bytevector-length", .min = 1, .max = 1 },
        .{ .name = "bytevector-u8-ref", .min = 2, .max = 2 },
        .{ .name = "bytevector-u8-set!", .min = 3, .max = 3 },
        .{ .name = "bytevector-copy", .min = 1, .max = 3 },
        .{ .name = "bytevector-copy!", .min = 3, .max = 5 },
        .{ .name = "bytevector-append", .min = 0, .max = null },
        .{ .name = "utf8->string", .min = 1, .max = 3 },
        .{ .name = "string->utf8", .min = 1, .max = 3 },
    };
    try std.testing.expectEqual(expected.len, primitives.len);
    for (expected, primitives) |e, p| {
        try std.testing.expectEqualStrings(e.name, p.name);
        try std.testing.expectEqual(e.min, p.min_args);
        try std.testing.expectEqual(e.max, p.max_args);
    }
}

test "bytevector? is true of a bytevector, the empty one included, and of nothing else" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    try std.testing.expect((try call(&f, "bytevector?", &.{try bv(&f, &.{})})).isTrue());
    try std.testing.expect((try call(&f, "bytevector?", &.{try bv(&f, &.{1})})).isTrue());
    const vector: Value = .fromVector(try f.heap.createVector(&.{fix(1)}));
    const pair = try f.heap.cons(fix(1), .empty_list_value);
    for ([_]Value{ vector, pair, try str(&f, "a"), fix(1), .empty_list_value, .fromCharacter('a'), .fromBool(true) }) |v| {
        const r = try call(&f, "bytevector?", &.{v});
        try std.testing.expectEqual(value.Kind.boolean, r.kind());
        try std.testing.expect(!r.isTrue());
    }
}

test "make-bytevector gives k copies of the byte, or of zero" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    try expectBytes(&.{}, try call(&f, "make-bytevector", &.{fix(0)}));
    try expectBytes(&.{ 0, 0, 0 }, try call(&f, "make-bytevector", &.{fix(3)}));
    try expectBytes(&.{ 12, 12 }, try call(&f, "make-bytevector", &.{ fix(2), fix(12) }));
    try expectBytes(&.{}, try call(&f, "make-bytevector", &.{ fix(0), fix(12) }));
    try expectBytes(&.{ 255, 255 }, try call(&f, "make-bytevector", &.{ fix(2), fix(255) }));
    try expectBytes(&.{ 0, 0 }, try call(&f, "make-bytevector", &.{ fix(2), fix(0) }));
    // 呼ぶたびに新しいバイトベクタで、定数ではない。
    const a = try call(&f, "make-bytevector", &.{fix(1)});
    const b = try call(&f, "make-bytevector", &.{fix(1)});
    try std.testing.expect(a.asBytevector().? != b.asBytevector().?);
    try std.testing.expect(!heap_mod.isImmutable(a));
}

test "make-bytevector reports a length that is not a count and a fill that is not a byte" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    try std.testing.expectError(error.WrongType, call(&f, "make-bytevector", &.{.fromCharacter('a')}));
    try std.testing.expectError(error.WrongType, call(&f, "make-bytevector", &.{try str(&f, "3")}));
    try std.testing.expectError(error.WrongType, call(&f, "make-bytevector", &.{ fix(3), .fromCharacter('a') }));
    // バイトでない整数も、型の誤りである。
    try std.testing.expectError(error.WrongType, call(&f, "make-bytevector", &.{ fix(3), fix(256) }));
    try std.testing.expectError(error.WrongType, call(&f, "make-bytevector", &.{ fix(3), fix(-1) }));
    try std.testing.expectError(error.WrongType, call(&f, "make-bytevector", &.{ fix(3), fix(std.math.maxInt(i64)) }));
    // 型の誤りは、範囲の誤りより先に報告される。
    try std.testing.expectError(error.WrongType, call(&f, "make-bytevector", &.{ fix(-1), fix(256) }));
    try std.testing.expectError(error.OutOfRange, call(&f, "make-bytevector", &.{fix(-1)}));
    try std.testing.expectError(error.OutOfRange, call(&f, "make-bytevector", &.{ fix(std.math.minInt(i64)), fix(0) }));
}

test "make-bytevector past the limit is a heap limit before any bytes are made, whatever the size" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    f.heap.deinit();
    f.heap = .init(std.testing.allocator, .{ .limit = heap_mod.cellBytes(Bytevector) + 4 });
    try std.testing.expectError(error.HeapLimit, call(&f, "make-bytevector", &.{fix(5)}));
    try std.testing.expectError(error.HeapLimit, call(&f, "make-bytevector", &.{ fix(1 << 40), fix(1) }));
    try std.testing.expectError(error.HeapLimit, call(&f, "make-bytevector", &.{fix(std.math.maxInt(i64))}));
    try std.testing.expectError(error.HeapLimit, call(&f, "make-bytevector", &.{ fix(std.math.maxInt(i64)), fix(7) }));
    try std.testing.expectEqual(0, f.heap.accounted);
    // 収まる大きさは作れ、失敗は計上を動かさなかった。
    try expectBytes(&.{ 7, 7, 7, 7 }, try call(&f, "make-bytevector", &.{ fix(4), fix(7) }));
    try std.testing.expectEqual(heap_mod.cellBytes(Bytevector) + 4, f.heap.accounted);
}

test "bytevector gives a bytevector of its arguments, which are bytes" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    try expectBytes(&.{}, try call(&f, "bytevector", &.{}));
    try expectBytes(&.{ 1, 3, 5, 1, 3, 5 }, try call(&f, "bytevector", &.{ fix(1), fix(3), fix(5), fix(1), fix(3), fix(5) }));
    try expectBytes(&.{ 0, 255 }, try call(&f, "bytevector", &.{ fix(0), fix(255) }));
    try std.testing.expectError(error.WrongType, call(&f, "bytevector", &.{ fix(1), fix(256) }));
    try std.testing.expectError(error.WrongType, call(&f, "bytevector", &.{ fix(-1), fix(1) }));
    try std.testing.expectError(error.WrongType, call(&f, "bytevector", &.{ fix(1), .fromCharacter('a') }));
    try std.testing.expectError(error.WrongType, call(&f, "bytevector", &.{try str(&f, "1")}));
    // 失敗した呼び出しは、何も確保しない。
    const before = f.heap.accounted;
    try std.testing.expectError(error.WrongType, call(&f, "bytevector", &.{ fix(1), fix(2), fix(300) }));
    try std.testing.expectEqual(before, f.heap.accounted);
    // 多くの引数も、順に並ぶ。
    var many: [300]Value = undefined;
    for (&many, 0..) |*a, i| a.* = fix(@intCast(i % 256));
    const big = (try call(&f, "bytevector", &many)).asBytevector().?;
    try std.testing.expectEqual(300, big.bytes.len);
    for (big.bytes, 0..) |b, i| try std.testing.expectEqual(@as(u8, @intCast(i % 256)), b);
}

test "bytevector-length gives the number of bytes" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    const octets = [_]u8{ 1, 2, 3, 4, 5 };
    for (0..octets.len + 1) |n| {
        const len = try call(&f, "bytevector-length", &.{try bv(&f, octets[0..n])});
        try std.testing.expectEqual(@as(i64, @intCast(n)), len.asFixnum().?);
    }
    try std.testing.expectError(error.WrongType, call(&f, "bytevector-length", &.{try str(&f, "abc")}));
    try std.testing.expectError(error.WrongType, call(&f, "bytevector-length", &.{.fromVector(try f.heap.createVector(&.{}))}));
    try std.testing.expectError(error.WrongType, call(&f, "bytevector-length", &.{.empty_list_value}));
}

test "bytevector-u8-ref gives the byte at a position as an integer" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    const b = try bv(&f, &.{ 1, 1, 2, 3, 5, 8, 13, 21, 255, 0 });
    try std.testing.expectEqual(8, (try call(&f, "bytevector-u8-ref", &.{ b, fix(5) })).asFixnum().?);
    try std.testing.expectEqual(1, (try call(&f, "bytevector-u8-ref", &.{ b, fix(0) })).asFixnum().?);
    try std.testing.expectEqual(255, (try call(&f, "bytevector-u8-ref", &.{ b, fix(8) })).asFixnum().?);
    try std.testing.expectEqual(0, (try call(&f, "bytevector-u8-ref", &.{ b, fix(9) })).asFixnum().?);
}

test "bytevector-u8-ref refuses a position outside the bytevector, and an argument of the wrong type first" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    const empty = try bv(&f, &.{});
    const three = try bv(&f, &.{ 1, 2, 3 });
    const positions = [_]i64{ 0, 1, 3, 4, 100, -1, std.math.minInt(i64), std.math.maxInt(i64), 1 << 32, (1 << 32) + 1 };
    for (positions) |k| try std.testing.expectError(error.OutOfRange, call(&f, "bytevector-u8-ref", &.{ empty, fix(k) }));
    for (positions[2..]) |k| try std.testing.expectError(error.OutOfRange, call(&f, "bytevector-u8-ref", &.{ three, fix(k) }));
    try std.testing.expectEqual(3, (try call(&f, "bytevector-u8-ref", &.{ three, fix(2) })).asFixnum().?);
    const pair = try f.heap.cons(fix(1), .empty_list_value);
    try std.testing.expectError(error.WrongType, call(&f, "bytevector-u8-ref", &.{ pair, fix(100) }));
    try std.testing.expectError(error.WrongType, call(&f, "bytevector-u8-ref", &.{ try str(&f, "abc"), fix(0) }));
    try std.testing.expectError(error.WrongType, call(&f, "bytevector-u8-ref", &.{ three, .fromCharacter('a') }));
    try std.testing.expectError(error.WrongType, call(&f, "bytevector-u8-ref", &.{ three, .empty_list_value }));
}

test "bytevector-u8-set! stores a byte in place" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    const b = try bv(&f, &.{ 1, 2, 3, 4 });
    const r = try call(&f, "bytevector-u8-set!", &.{ b, fix(1), fix(3) });
    try std.testing.expectEqual(value.Kind.unspecified, r.kind());
    try expectBytes(&.{ 1, 3, 3, 4 }, b);
    _ = try call(&f, "bytevector-u8-set!", &.{ b, fix(3), fix(255) });
    _ = try call(&f, "bytevector-u8-set!", &.{ b, fix(0), fix(0) });
    try expectBytes(&.{ 0, 3, 3, 255 }, b);
    // 長さと計上は変わらない。
    try std.testing.expectEqual(heap_mod.cellBytes(Bytevector) + 4, f.heap.accounted);
}

test "bytevector-u8-set! refuses what it cannot use, and leaves the bytevector as it was" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    const b = try bv(&f, &.{ 1, 2, 3 });
    for ([_]i64{ 3, 4, -1, std.math.minInt(i64), std.math.maxInt(i64), 1 << 32 }) |k| {
        try std.testing.expectError(error.OutOfRange, call(&f, "bytevector-u8-set!", &.{ b, fix(k), fix(9) }));
    }
    try std.testing.expectError(error.OutOfRange, call(&f, "bytevector-u8-set!", &.{ try bv(&f, &.{}), fix(0), fix(9) }));
    // バイトでない値は型の誤りで、範囲の誤りより先に報告される。
    try std.testing.expectError(error.WrongType, call(&f, "bytevector-u8-set!", &.{ b, fix(0), fix(256) }));
    try std.testing.expectError(error.WrongType, call(&f, "bytevector-u8-set!", &.{ b, fix(0), fix(-1) }));
    try std.testing.expectError(error.WrongType, call(&f, "bytevector-u8-set!", &.{ b, fix(9), fix(256) }));
    try std.testing.expectError(error.WrongType, call(&f, "bytevector-u8-set!", &.{ b, fix(0), .fromCharacter('a') }));
    try std.testing.expectError(error.WrongType, call(&f, "bytevector-u8-set!", &.{ b, .fromCharacter('a'), fix(1) }));
    try std.testing.expectError(error.WrongType, call(&f, "bytevector-u8-set!", &.{ try str(&f, "abc"), fix(0), fix(1) }));
    try expectBytes(&.{ 1, 2, 3 }, b);
}

test "bytevector-u8-set! refuses a constant, after the types and before the range" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    const c = try constant(&f, &.{ 1, 2, 3 });
    try std.testing.expectError(error.Immutable, call(&f, "bytevector-u8-set!", &.{ c, fix(0), fix(9) }));
    try expectBytes(&.{ 1, 2, 3 }, c);
    // 型の誤りが先、不変の誤りが範囲の誤りより先。
    try std.testing.expectError(error.WrongType, call(&f, "bytevector-u8-set!", &.{ c, fix(0), fix(256) }));
    try std.testing.expectError(error.WrongType, call(&f, "bytevector-u8-set!", &.{ c, .fromCharacter('a'), fix(1) }));
    try std.testing.expectError(error.Immutable, call(&f, "bytevector-u8-set!", &.{ c, fix(99), fix(9) }));
    try std.testing.expectError(error.Immutable, call(&f, "bytevector-u8-set!", &.{ c, fix(-1), fix(9) }));
    // 空の定数も断る。
    try std.testing.expectError(error.Immutable, call(&f, "bytevector-u8-set!", &.{ try constant(&f, &.{}), fix(0), fix(9) }));
}

test "bytevector-copy gives a new bytevector of the bytes in the range, a constant source included" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    const a = try constant(&f, &.{ 1, 2, 3, 4, 5 });
    try expectBytes(&.{ 1, 2, 3, 4, 5 }, try call(&f, "bytevector-copy", &.{a}));
    try expectBytes(&.{ 3, 4, 5 }, try call(&f, "bytevector-copy", &.{ a, fix(2) }));
    try expectBytes(&.{ 3, 4 }, try call(&f, "bytevector-copy", &.{ a, fix(2), fix(4) }));
    try expectBytes(&.{}, try call(&f, "bytevector-copy", &.{ a, fix(5) }));
    try expectBytes(&.{}, try call(&f, "bytevector-copy", &.{ a, fix(2), fix(2) }));
    // 写しは新しいオブジェクトで、定数ではない。書き換えても元は変わらない。
    const c = try call(&f, "bytevector-copy", &.{a});
    try std.testing.expect(c.asBytevector().? != a.asBytevector().?);
    try std.testing.expect(!heap_mod.isImmutable(c));
    _ = try call(&f, "bytevector-u8-set!", &.{ c, fix(0), fix(9) });
    try expectBytes(&.{ 1, 2, 3, 4, 5 }, a);
    try expectBytes(&.{ 9, 2, 3, 4, 5 }, c);
}

test "bytevector-copy checks the range" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    const a = try bv(&f, &.{ 1, 2, 3 });
    const bad = [_][2]?i64{ .{ 4, null }, .{ 0, 4 }, .{ 2, 1 }, .{ -1, null }, .{ 0, -1 }, .{ std.math.minInt(i64), null }, .{ 0, std.math.maxInt(i64) }, .{ 1 << 32, 1 << 32 } };
    for (bad) |r| {
        var args: [3]Value = .{ a, fix(r[0].?), undefined };
        var n: usize = 2;
        if (r[1]) |e| {
            args[2] = fix(e);
            n = 3;
        }
        try std.testing.expectError(error.OutOfRange, call(&f, "bytevector-copy", args[0..n]));
    }
    try std.testing.expectError(error.WrongType, call(&f, "bytevector-copy", &.{ try str(&f, "abc"), fix(5) }));
    try std.testing.expectError(error.WrongType, call(&f, "bytevector-copy", &.{ a, .fromCharacter('a') }));
    try std.testing.expectError(error.WrongType, call(&f, "bytevector-copy", &.{ a, fix(0), .fromCharacter('a') }));
    // 型の誤りは範囲の誤りより先に報告される。
    try std.testing.expectError(error.WrongType, call(&f, "bytevector-copy", &.{ a, fix(9), .fromCharacter('a') }));
}

test "bytevector-copy! copies the bytes of the range to the position, as the report's example does" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    const a = try bv(&f, &.{ 1, 2, 3, 4, 5 });
    const b = try bv(&f, &.{ 10, 20, 30, 40, 50 });
    const r = try call(&f, "bytevector-copy!", &.{ b, fix(1), a, fix(0), fix(2) });
    try std.testing.expectEqual(value.Kind.unspecified, r.kind());
    try expectBytes(&.{ 10, 1, 2, 40, 50 }, b);
    try expectBytes(&.{ 1, 2, 3, 4, 5 }, a);
    // 省略した範囲は、始まりが 0、終わりが長さである。
    const c = try bv(&f, &.{ 0, 0, 0, 0, 0 });
    _ = try call(&f, "bytevector-copy!", &.{ c, fix(0), a });
    try expectBytes(&.{ 1, 2, 3, 4, 5 }, c);
    _ = try call(&f, "bytevector-copy!", &.{ c, fix(0), try bv(&f, &.{ 9, 8, 7 }), fix(1) });
    try expectBytes(&.{ 8, 7, 3, 4, 5 }, c);
    // 定数の元から写せる。
    _ = try call(&f, "bytevector-copy!", &.{ c, fix(3), try constant(&f, &.{ 6, 6 }) });
    try expectBytes(&.{ 8, 7, 3, 6, 6 }, c);
}

test "bytevector-copy! of ranges that overlap acts as if the source were copied first" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    // 前へ重なる(コピー先が元より後ろ)ときと、後ろへ重なるとき。
    const a = try bv(&f, &.{ 1, 2, 3, 4, 5 });
    _ = try call(&f, "bytevector-copy!", &.{ a, fix(1), a, fix(0), fix(4) });
    try expectBytes(&.{ 1, 1, 2, 3, 4 }, a);
    const b = try bv(&f, &.{ 1, 2, 3, 4, 5 });
    _ = try call(&f, "bytevector-copy!", &.{ b, fix(0), b, fix(1), fix(5) });
    try expectBytes(&.{ 2, 3, 4, 5, 5 }, b);
    // 同じ位置への写しは変えない。
    const c = try bv(&f, &.{ 1, 2, 3 });
    _ = try call(&f, "bytevector-copy!", &.{ c, fix(1), c, fix(1) });
    try expectBytes(&.{ 1, 2, 3 }, c);
}

test "bytevector-copy! reports the arguments it cannot use, before it changes anything" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    const to = try bv(&f, &.{ 1, 2, 3 });
    const from = try bv(&f, &.{ 7, 8, 9, 10 });
    // 範囲の誤り: `at`、元の範囲、残りの不足。
    const cases = [_][]const Value{
        &.{ to, fix(4), from, fix(0), fix(0) },
        &.{ to, fix(-1), from },
        &.{ to, fix(std.math.maxInt(i64)), from },
        &.{ to, fix(0), from, fix(0), fix(5) },
        &.{ to, fix(0), from, fix(3), fix(2) },
        &.{ to, fix(0), from, fix(-1) },
        &.{ to, fix(0), from, fix(0), fix(4) },
        &.{ to, fix(1), from, fix(0), fix(3) },
        &.{ to, fix(3), from, fix(0), fix(1) },
        &.{ to, fix(0), from, fix(1 << 32) },
    };
    for (cases) |args| try std.testing.expectError(error.OutOfRange, call(&f, "bytevector-copy!", args));
    // 型の誤り。範囲が正しくない引数があっても、型が先に報告される。
    try std.testing.expectError(error.WrongType, call(&f, "bytevector-copy!", &.{ try str(&f, "abc"), fix(0), from }));
    try std.testing.expectError(error.WrongType, call(&f, "bytevector-copy!", &.{ to, .fromCharacter('a'), from }));
    try std.testing.expectError(error.WrongType, call(&f, "bytevector-copy!", &.{ to, fix(0), try str(&f, "abc") }));
    try std.testing.expectError(error.WrongType, call(&f, "bytevector-copy!", &.{ to, fix(0), from, .fromCharacter('a') }));
    try std.testing.expectError(error.WrongType, call(&f, "bytevector-copy!", &.{ to, fix(0), from, fix(0), .fromCharacter('a') }));
    try std.testing.expectError(error.WrongType, call(&f, "bytevector-copy!", &.{ to, fix(99), from, fix(99), .fromCharacter('a') }));
    try expectBytes(&.{ 1, 2, 3 }, to);
    // ちょうど収まるものは通る。何も写さないときは、末尾の位置から始めてよい。
    _ = try call(&f, "bytevector-copy!", &.{ to, fix(3), from, fix(1), fix(1) });
    _ = try call(&f, "bytevector-copy!", &.{ to, fix(0), from, fix(1), fix(4) });
    try expectBytes(&.{ 8, 9, 10 }, to);
}

test "bytevector-copy! refuses a destination that is a constant, even to copy nothing, and takes a constant source" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    const c = try constant(&f, &.{ 1, 2, 3 });
    const from = try bv(&f, &.{ 7, 8 });
    try std.testing.expectError(error.Immutable, call(&f, "bytevector-copy!", &.{ c, fix(0), from }));
    try std.testing.expectError(error.Immutable, call(&f, "bytevector-copy!", &.{ c, fix(0), from, fix(1), fix(1) }));
    try std.testing.expectError(error.Immutable, call(&f, "bytevector-copy!", &.{ try constant(&f, &.{}), fix(0), try bv(&f, &.{}) }));
    // 型の誤りが先、不変の誤りが範囲の誤りより先。
    try std.testing.expectError(error.WrongType, call(&f, "bytevector-copy!", &.{ c, fix(0), try str(&f, "ab") }));
    try std.testing.expectError(error.Immutable, call(&f, "bytevector-copy!", &.{ c, fix(99), from }));
    try std.testing.expectError(error.Immutable, call(&f, "bytevector-copy!", &.{ c, fix(0), from, fix(5) }));
    try expectBytes(&.{ 1, 2, 3 }, c);
}

test "bytevector-append gives a new bytevector of the bytes in order, and of one bytevector a copy of it" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    try expectBytes(&.{}, try call(&f, "bytevector-append", &.{}));
    try expectBytes(&.{ 0, 1, 2, 3, 4, 5 }, try call(&f, "bytevector-append", &.{ try bv(&f, &.{ 0, 1, 2 }), try bv(&f, &.{ 3, 4, 5 }) }));
    try expectBytes(&.{ 1, 2 }, try call(&f, "bytevector-append", &.{ try bv(&f, &.{}), try bv(&f, &.{ 1, 2 }), try bv(&f, &.{}) }));
    const only = try constant(&f, &.{ 1, 2 });
    const copy = try call(&f, "bytevector-append", &.{only});
    try expectBytes(&.{ 1, 2 }, copy);
    try std.testing.expect(copy.asBytevector().? != only.asBytevector().?);
    try std.testing.expect(!heap_mod.isImmutable(copy));
    // 同じ引数を何度並べてもよい。
    try expectBytes(&.{ 1, 2, 1, 2 }, try call(&f, "bytevector-append", &.{ only, only }));
    try std.testing.expectError(error.WrongType, call(&f, "bytevector-append", &.{ only, try str(&f, "ab") }));
    try std.testing.expectError(error.WrongType, call(&f, "bytevector-append", &.{ .empty_list_value, only }));
}

test "bytevector-append is held to the limit by the bytes of the whole result" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    const a = try bv(&f, &.{ 1, 2, 3 });
    const b = try bv(&f, &.{ 4, 5, 6 });
    const empty = try bv(&f, &.{});
    const c = try bv(&f, &.{ 4, 5 });
    const used = f.heap.accounted;
    f.heap.options.limit = used + heap_mod.cellBytes(Bytevector) + 5;
    // 引数は1つずつ収まるが、結果は1バイト足りない。
    try std.testing.expectError(error.HeapLimit, call(&f, "bytevector-append", &.{ a, b }));
    try std.testing.expectEqual(used, f.heap.accounted);
    try expectBytes(&.{ 1, 2, 3, 4, 5 }, try call(&f, "bytevector-append", &.{ a, empty, c }));
}

test "utf8->string and string->utf8 carry the characters of a range between a string and its bytes" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    // 原文の例。
    const a = try call(&f, "utf8->string", &.{try bv(&f, &.{0x41})});
    try std.testing.expectEqualStrings("A", a.asString().?.bytes);
    try std.testing.expect(a.asString().?.is_ascii);
    try expectBytes(&.{ 0xCE, 0xBB }, try call(&f, "string->utf8", &.{try str(&f, "λ")}));
    // 幅の違う文字。`string->utf8` の範囲は文字で数え、`utf8->string` の範囲はバイトで数える。
    const text = try str(&f, "aλあ𐀀z");
    const encoded = try call(&f, "string->utf8", &.{text});
    try expectBytes("aλあ𐀀z", encoded);
    try expectBytes("λあ", try call(&f, "string->utf8", &.{ text, fix(1), fix(3) }));
    try expectBytes("あ𐀀z", try call(&f, "string->utf8", &.{ text, fix(2) }));
    try expectBytes("", try call(&f, "string->utf8", &.{ text, fix(5) }));
    try expectBytes("", try call(&f, "string->utf8", &.{ text, fix(2), fix(2) }));
    const back = try call(&f, "utf8->string", &.{encoded});
    try std.testing.expectEqualStrings("aλあ𐀀z", back.asString().?.bytes);
    try std.testing.expect(!back.asString().?.is_ascii);
    try std.testing.expectEqual(5, back.asString().?.length());
    // `a` が 1 バイト、`λ` が 2 バイト(1 から 3)、`あ` が 3 バイト(3 から 6)。
    const mid = try call(&f, "utf8->string", &.{ encoded, fix(1), fix(6) });
    try std.testing.expectEqualStrings("λあ", mid.asString().?.bytes);
    const tail = try call(&f, "utf8->string", &.{ encoded, fix(6) });
    try std.testing.expectEqualStrings("𐀀z", tail.asString().?.bytes);
    const empty = try call(&f, "utf8->string", &.{ encoded, fix(3), fix(3) });
    try std.testing.expectEqualStrings("", empty.asString().?.bytes);
    try std.testing.expect(empty.asString().?.is_ascii);
    // 結果は新しいオブジェクトで、定数ではない(元が定数でも)。
    const k = try call(&f, "string->utf8", &.{text});
    try std.testing.expect(!heap_mod.isImmutable(k));
    const kc = try call(&f, "utf8->string", &.{try constant(&f, "abc")});
    try std.testing.expect(!heap_mod.isImmutable(kc));
}

test "utf8->string refuses bytes that are not UTF-8, and a range that cuts a character" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    const invalid = [_][]const u8{
        &.{0xFF},
        &.{0x80},
        &.{ 0xC0, 0x80 }, // 冗長な符号化
        &.{ 0xED, 0xA0, 0x80 }, // サロゲート
        &.{0xCE}, // 途中で切れた並び
        &.{ 0xF4, 0x90, 0x80, 0x80 }, // 範囲外の値
        &.{ 'a', 0xE3, 0x81 },
    };
    var inputs: [invalid.len]Value = undefined;
    for (invalid, &inputs) |octets, *input| input.* = try bv(&f, octets);
    const lambda = try bv(&f, "aλb");
    const before = f.heap.accounted;
    for (inputs) |input| try std.testing.expectError(error.OutOfRange, call(&f, "utf8->string", &.{input}));
    // 範囲が文字の途中で切れる。
    try std.testing.expectError(error.OutOfRange, call(&f, "utf8->string", &.{ lambda, fix(2) }));
    try std.testing.expectError(error.OutOfRange, call(&f, "utf8->string", &.{ lambda, fix(0), fix(2) }));
    // 失敗は何も確保しない。
    try std.testing.expectEqual(before, f.heap.accounted);
    try std.testing.expectEqualStrings("λ", (try call(&f, "utf8->string", &.{ lambda, fix(1), fix(3) })).asString().?.bytes);
}

test "utf8->string and string->utf8 check the types and the range" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    const b = try bv(&f, "abc");
    const s = try str(&f, "abc");
    try std.testing.expectError(error.WrongType, call(&f, "utf8->string", &.{s}));
    try std.testing.expectError(error.WrongType, call(&f, "string->utf8", &.{b}));
    try std.testing.expectError(error.WrongType, call(&f, "utf8->string", &.{ b, .fromCharacter('a') }));
    try std.testing.expectError(error.WrongType, call(&f, "string->utf8", &.{ s, fix(0), .fromCharacter('a') }));
    try std.testing.expectError(error.WrongType, call(&f, "string->utf8", &.{ s, fix(9), .fromCharacter('a') }));
    for ([_][2]i64{ .{ 4, 4 }, .{ 0, 4 }, .{ 2, 1 }, .{ -1, 2 }, .{ 0, -1 }, .{ 0, std.math.maxInt(i64) }, .{ 1 << 32, 1 << 32 } }) |r| {
        try std.testing.expectError(error.OutOfRange, call(&f, "utf8->string", &.{ b, fix(r[0]), fix(r[1]) }));
        try std.testing.expectError(error.OutOfRange, call(&f, "string->utf8", &.{ s, fix(r[0]), fix(r[1]) }));
    }
    try std.testing.expectError(error.OutOfRange, call(&f, "utf8->string", &.{ b, fix(4) }));
    try std.testing.expectError(error.OutOfRange, call(&f, "string->utf8", &.{ s, fix(4) }));
}

test "utf8->string and string->utf8 are held to the limit by their payload" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    const big = try bv(&f, "abcdef");
    const text = try str(&f, "abcdef");
    const used = f.heap.accounted;
    f.heap.options.limit = used + heap_mod.cellBytes(Bytevector) + 5;
    try std.testing.expectError(error.HeapLimit, call(&f, "string->utf8", &.{text}));
    try std.testing.expectError(error.HeapLimit, call(&f, "bytevector-copy", &.{big}));
    f.heap.options.limit = used + heap_mod.cellBytes(value.String) + 5;
    try std.testing.expectError(error.HeapLimit, call(&f, "utf8->string", &.{big}));
    try std.testing.expectEqual(used, f.heap.accounted);
    _ = try call(&f, "utf8->string", &.{ big, fix(0), fix(5) });
}

test "a collection keeps the bytes of a bytevector the roots reach, and frees the rest" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    const kept = try call(&f, "bytevector", &.{ fix(1), fix(2), fix(3) });
    _ = try call(&f, "make-bytevector", &.{fix(100)});
    const appended = try call(&f, "bytevector-append", &.{ kept, kept });
    const Roots = struct {
        values: []const Value,
        pub fn mark(self: @This(), marker: *heap_mod.Marker) void {
            for (self.values) |v| marker.value(v);
        }
    };
    f.heap.collect(Roots{ .values = &.{ kept, appended } });
    try std.testing.expectEqual(2, f.heap.count);
    try std.testing.expectEqual(heap_mod.cellBytes(Bytevector) * 2 + 3 + 6, f.heap.accounted);
    try expectBytes(&.{ 1, 2, 3 }, kept);
    try expectBytes(&.{ 1, 2, 3, 1, 2, 3 }, appended);
}
