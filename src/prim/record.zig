//! Record primitives: what the expansion of `define-record-type` (R7RS 5.5)
//! uses.
//!
//! 段階3の `define-record-type` は `syntax-rules` で書かれ、これらに展開される。
//! 形は低水準で、型を作る、フィールドの値を並べてレコードを作る、型を判定する、
//! 添字でフィールドを読み書きする、の5つである。フィールドの名前から添字を求めるのは
//! 展開の側である。生成子や取り出しの手続きを返す形にしない理由は、
//! docs/plans/0014-phase2-core-language.md の 2h の節にある。
//!
//! 名前は `%` で始め、利用者の名前と衝突しにくくする。段階2の間は、ほかのプリミティブと
//! 同じく大域環境に束縛され、REPL から呼べる。段階3で `(scheme base)` を構成するとき、
//! これらを `(scheme base)` に入れない(R7RS 5.6.1 は、`scheme` で始まるライブラリに
//! 独自の識別子を足すことを禁じる)。
//!
//! 読み書きと判定は、レコードと一緒に型を受け取り、同じ型(同じオブジェクト)かを
//! 確かめる。名前が同じでも、別々に作った型は別の型である。

const std = @import("std");
const value = @import("../value.zig");
const Value = value.Value;
const Primitive = value.Primitive;
const Services = value.Services;
const PrimitiveError = value.PrimitiveError;

pub const Error = PrimitiveError;

pub const primitives = [_]Primitive{
    .{ .name = "%make-record-type", .min_args = 2, .max_args = 2, .body = .{ .pure = &makeRecordType } },
    .{ .name = "%make-record", .min_args = 1, .max_args = null, .body = .{ .pure = &makeRecord } },
    .{ .name = "%record?", .min_args = 2, .max_args = 2, .body = .{ .pure = &isRecord } },
    .{ .name = "%record-ref", .min_args = 3, .max_args = 3, .body = .{ .pure = &recordRef } },
    .{ .name = "%record-set!", .min_args = 4, .max_args = 4, .body = .{ .pure = &recordSet } },
};

/// `(%make-record-type name field-count)`: a new record type, different from
/// every other.
/// 名前はシンボルで、プリンタが使う。フィールドの数は 0 以上の整数である。
fn makeRecordType(services: *const Services, args: []const Value) Error!Value {
    const name = args[0].asSymbol() orelse return error.WrongType;
    const n = args[1].asFixnum() orelse return error.WrongType;
    const count = std.math.cast(u32, n) orelse return error.OutOfRange;
    return .fromRecordType(try services.heap.create(value.RecordType, .{ .name = name, .field_count = count }));
}

/// `(%make-record type field ...)`: a new record of `type` whose fields hold
/// the arguments after the type, in order.
/// 値は、型のフィールドの数とちょうど同じ個数でなければならない。
fn makeRecord(services: *const Services, args: []const Value) Error!Value {
    const record_type = args[0].asRecordType() orelse return error.WrongType;
    const fields = args[1..];
    if (fields.len != record_type.field_count) return error.WrongArgumentCount;
    return .fromRecord(try services.heap.createRecord(record_type, fields));
}

/// `(%record? obj type)`: whether `obj` is a record of `type`.
fn isRecord(_: *const Services, args: []const Value) Error!Value {
    const record_type = args[1].asRecordType() orelse return error.WrongType;
    const record = args[0].asRecord() orelse return .fromBool(false);
    return .fromBool(record.record_type == record_type);
}

/// `(%record-ref record type k)`: field `k` of `record`, counted from 0.
fn recordRef(_: *const Services, args: []const Value) Error!Value {
    return (try field(args)).*;
}

/// `(%record-set! record type k obj)`: puts `obj` in field `k` of `record`.
fn recordSet(_: *const Services, args: []const Value) Error!Value {
    (try field(args)).* = args[3];
    return .unspecified_value;
}

/// The field that `(record type k ...)` names.
/// 型の誤りを、添字の範囲の誤りより先に報告する(`vector-ref` と同じ)。添字は 64 ビット
/// の整数なので、`usize` に変えられるかを先に調べる(`vector-ref` の Why を参照)。
fn field(args: []const Value) Error!*Value {
    const record_type = args[1].asRecordType() orelse return error.WrongType;
    const record = args[0].asRecord() orelse return error.WrongType;
    if (record.record_type != record_type) return error.WrongType;
    const k = args[2].asFixnum() orelse return error.WrongType;
    const index = std.math.cast(usize, k) orelse return error.OutOfRange;
    if (index >= record.fields.len) return error.OutOfRange;
    return &record.fields[index];
}

test {
    std.testing.refAllDecls(@This());
}

const test_support = @import("test_support.zig");
const heap_mod = @import("../heap.zig");

fn sym(n: u32) Value {
    return .fromSymbol(@fromBackingInt(n));
}

test "the primitives take the numbers of arguments their forms give them" {
    const Arity = struct { name: []const u8, min: u8, max: ?u8 };
    const expected = [_]Arity{
        .{ .name = "%make-record-type", .min = 2, .max = 2 },
        .{ .name = "%make-record", .min = 1, .max = null },
        .{ .name = "%record?", .min = 2, .max = 2 },
        .{ .name = "%record-ref", .min = 3, .max = 3 },
        .{ .name = "%record-set!", .min = 4, .max = 4 },
    };
    try std.testing.expectEqual(expected.len, primitives.len);
    for (expected, primitives) |e, p| {
        try std.testing.expectEqualStrings(e.name, p.name);
        try std.testing.expectEqual(e.min, p.min_args);
        try std.testing.expectEqual(e.max, p.max_args);
    }
}

test "a record holds the values it was made with, in order, and its fields can be written" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    const t = try f.call(&primitives, "%make-record-type", &.{ sym(0), .fromFixnum(3) });
    const r = try f.call(&primitives, "%make-record", &.{ t, .fromFixnum(10), .fromCharacter('b'), .empty_list_value });
    try std.testing.expectEqual(10, (try f.call(&primitives, "%record-ref", &.{ r, t, .fromFixnum(0) })).asFixnum().?);
    try std.testing.expectEqual('b', (try f.call(&primitives, "%record-ref", &.{ r, t, .fromFixnum(1) })).asCharacter().?);
    try std.testing.expectEqual(value.Kind.empty_list, (try f.call(&primitives, "%record-ref", &.{ r, t, .fromFixnum(2) })).kind());
    const set = try f.call(&primitives, "%record-set!", &.{ r, t, .fromFixnum(1), .fromFixnum(-4) });
    try std.testing.expectEqual(value.Kind.unspecified, set.kind());
    try std.testing.expectEqual(-4, (try f.call(&primitives, "%record-ref", &.{ r, t, .fromFixnum(1) })).asFixnum().?);
    // ほかのフィールドは変わらない。
    try std.testing.expectEqual(10, (try f.call(&primitives, "%record-ref", &.{ r, t, .fromFixnum(0) })).asFixnum().?);
    try std.testing.expectEqual(value.Kind.empty_list, (try f.call(&primitives, "%record-ref", &.{ r, t, .fromFixnum(2) })).kind());
    // 書き込みは、そのレコードだけを変える。
    const s = try f.call(&primitives, "%make-record", &.{ t, .fromFixnum(10), .fromCharacter('b'), .empty_list_value });
    try std.testing.expectEqual('b', (try f.call(&primitives, "%record-ref", &.{ s, t, .fromFixnum(1) })).asCharacter().?);
}

test "a record is a copy of the arguments, not the arguments themselves" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    const t = try f.call(&primitives, "%make-record-type", &.{ sym(0), .fromFixnum(1) });
    var args = [_]Value{ t, .fromFixnum(1) };
    const r = try f.call(&primitives, "%make-record", &args);
    args[1] = .fromFixnum(2);
    try std.testing.expectEqual(1, (try f.call(&primitives, "%record-ref", &.{ r, t, .fromFixnum(0) })).asFixnum().?);
    try std.testing.expect(r.asRecord().?.fields.ptr != args[1..].ptr);
}

test "a record type of no fields makes records of no fields" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    const t = try f.call(&primitives, "%make-record-type", &.{ sym(0), .fromFixnum(0) });
    const r = try f.call(&primitives, "%make-record", &.{t});
    try std.testing.expect((try f.call(&primitives, "%record?", &.{ r, t })).isTrue());
    try std.testing.expectError(error.OutOfRange, f.call(&primitives, "%record-ref", &.{ r, t, .fromFixnum(0) }));
    try std.testing.expectError(error.WrongArgumentCount, f.call(&primitives, "%make-record", &.{ t, .fromFixnum(1) }));
}

test "%make-record takes exactly as many values as the type has fields" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    const t = try f.call(&primitives, "%make-record-type", &.{ sym(0), .fromFixnum(2) });
    const one = [_]Value{ .fromFixnum(1), .fromFixnum(1), .fromFixnum(1) };
    try std.testing.expectError(error.WrongArgumentCount, f.call(&primitives, "%make-record", &.{t}));
    try std.testing.expectError(error.WrongArgumentCount, f.call(&primitives, "%make-record", &.{ t, one[0] }));
    try std.testing.expectError(error.WrongArgumentCount, f.call(&primitives, "%make-record", &.{ t, one[0], one[1], one[2] }));
    _ = try f.call(&primitives, "%make-record", &.{ t, one[0], one[1] });
    // 失敗した呼び出しは、何も確保しない。型とレコードが1つずつある。
    try std.testing.expectEqual(2, f.heap.count);
}

test "%make-record-type takes a symbol and a count that fits" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    const string: Value = .fromString(try f.heap.createString("point"));
    try std.testing.expectError(error.WrongType, f.call(&primitives, "%make-record-type", &.{ string, .fromFixnum(1) }));
    try std.testing.expectError(error.WrongType, f.call(&primitives, "%make-record-type", &.{ .fromFixnum(1), .fromFixnum(1) }));
    try std.testing.expectError(error.WrongType, f.call(&primitives, "%make-record-type", &.{ sym(0), sym(1) }));
    try std.testing.expectError(error.WrongType, f.call(&primitives, "%make-record-type", &.{ sym(0), .fromCharacter('a') }));
    // 負の数と、`u32` に収まらない数は範囲の誤りである。
    for ([_]i64{ -1, std.math.minInt(i64), @as(i64, std.math.maxInt(u32)) + 1, std.math.maxInt(i64) }) |n| {
        try std.testing.expectError(error.OutOfRange, f.call(&primitives, "%make-record-type", &.{ sym(0), .fromFixnum(n) }));
    }
    // `u32` の最大は受け付ける。型はフィールドの領域を持たないので、作るのは安い。
    const wide = try f.call(&primitives, "%make-record-type", &.{ sym(0), .fromFixnum(std.math.maxInt(u32)) });
    try std.testing.expectEqual(std.math.maxInt(u32), wide.asRecordType().?.field_count);
    try std.testing.expectEqual(@as(@import("../symbol.zig").SymbolId, @fromBackingInt(0)), wide.asRecordType().?.name);
}

test "each record type is a type of its own, even under the same name" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    const a = try f.call(&primitives, "%make-record-type", &.{ sym(0), .fromFixnum(1) });
    const b = try f.call(&primitives, "%make-record-type", &.{ sym(0), .fromFixnum(1) });
    try std.testing.expect(!a.isEqv(b));
    const ra = try f.call(&primitives, "%make-record", &.{ a, .fromFixnum(1) });
    const rb = try f.call(&primitives, "%make-record", &.{ b, .fromFixnum(2) });
    try std.testing.expect((try f.call(&primitives, "%record?", &.{ ra, a })).isTrue());
    try std.testing.expect(!(try f.call(&primitives, "%record?", &.{ ra, b })).isTrue());
    try std.testing.expect(!(try f.call(&primitives, "%record?", &.{ rb, a })).isTrue());
    try std.testing.expect((try f.call(&primitives, "%record?", &.{ rb, b })).isTrue());
    try std.testing.expectError(error.WrongType, f.call(&primitives, "%record-ref", &.{ ra, b, .fromFixnum(0) }));
    try std.testing.expectError(error.WrongType, f.call(&primitives, "%record-set!", &.{ rb, a, .fromFixnum(0), .fromFixnum(3) }));
    // 失敗した書き込みは、何も変えない。
    try std.testing.expectEqual(2, (try f.call(&primitives, "%record-ref", &.{ rb, b, .fromFixnum(0) })).asFixnum().?);
}

test "%record? is false of what is not a record, and needs a record type" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    const t = try f.call(&primitives, "%make-record-type", &.{ sym(0), .fromFixnum(1) });
    const v: Value = .fromVector(try f.heap.createVector(&.{.fromFixnum(1)}));
    const pair = try f.heap.cons(.fromFixnum(1), .empty_list_value);
    for ([_]Value{ v, pair, t, .fromFixnum(1), .empty_list_value, sym(0), .fromBool(false) }) |obj| {
        const answer = try f.call(&primitives, "%record?", &.{ obj, t });
        try std.testing.expectEqual(value.Kind.boolean, answer.kind());
        try std.testing.expect(!answer.isTrue());
    }
    const r = try f.call(&primitives, "%make-record", &.{ t, .fromFixnum(1) });
    // 型の引数が型でなければ、型の誤りである。
    try std.testing.expectError(error.WrongType, f.call(&primitives, "%record?", &.{ r, r }));
    try std.testing.expectError(error.WrongType, f.call(&primitives, "%record?", &.{ r, sym(0) }));
    try std.testing.expectError(error.WrongType, f.call(&primitives, "%record?", &.{ .fromFixnum(1), .fromFixnum(1) }));
}

test "reading and writing refuse what is not a record, and a type that is not one" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    const t = try f.call(&primitives, "%make-record-type", &.{ sym(0), .fromFixnum(1) });
    const r = try f.call(&primitives, "%make-record", &.{ t, .fromFixnum(1) });
    const v: Value = .fromVector(try f.heap.createVector(&.{.fromFixnum(1)}));
    for ([_]Value{ v, t, .fromFixnum(1), .empty_list_value }) |obj| {
        try std.testing.expectError(error.WrongType, f.call(&primitives, "%record-ref", &.{ obj, t, .fromFixnum(0) }));
        try std.testing.expectError(error.WrongType, f.call(&primitives, "%record-set!", &.{ obj, t, .fromFixnum(0), .fromFixnum(0) }));
    }
    for ([_]Value{ r, v, sym(0), .fromFixnum(1) }) |not_type| {
        try std.testing.expectError(error.WrongType, f.call(&primitives, "%record-ref", &.{ r, not_type, .fromFixnum(0) }));
        try std.testing.expectError(error.WrongType, f.call(&primitives, "%record-set!", &.{ r, not_type, .fromFixnum(0), .fromFixnum(0) }));
    }
    // 整数でない添字。
    for ([_]Value{ .fromCharacter('a'), sym(0), .empty_list_value }) |k| {
        try std.testing.expectError(error.WrongType, f.call(&primitives, "%record-ref", &.{ r, t, k }));
        try std.testing.expectError(error.WrongType, f.call(&primitives, "%record-set!", &.{ r, t, k, .fromFixnum(0) }));
    }
    // 型の誤りは、添字が範囲外でも型の誤りとして報告する。
    try std.testing.expectError(error.WrongType, f.call(&primitives, "%record-ref", &.{ v, t, .fromFixnum(100) }));
    try std.testing.expectError(error.WrongType, f.call(&primitives, "%record-ref", &.{ r, v, .fromFixnum(-1) }));
}

test "reading and writing refuse a position outside the record" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    const t = try f.call(&primitives, "%make-record-type", &.{ sym(0), .fromFixnum(3) });
    const r = try f.call(&primitives, "%make-record", &.{ t, .fromFixnum(1), .fromFixnum(2), .fromFixnum(3) });
    // 個数ちょうどと、その先。最後のフィールドまでは読める。
    const positions = [_]i64{ 3, 4, 100, -1, std.math.minInt(i64), std.math.maxInt(i64), 1 << 32, (1 << 32) + 1 };
    for (positions) |k| {
        try std.testing.expectError(error.OutOfRange, f.call(&primitives, "%record-ref", &.{ r, t, .fromFixnum(k) }));
        try std.testing.expectError(error.OutOfRange, f.call(&primitives, "%record-set!", &.{ r, t, .fromFixnum(k), .fromFixnum(0) }));
    }
    try std.testing.expectEqual(3, (try f.call(&primitives, "%record-ref", &.{ r, t, .fromFixnum(2) })).asFixnum().?);
    _ = try f.call(&primitives, "%record-set!", &.{ r, t, .fromFixnum(2), .fromFixnum(9) });
    try std.testing.expectEqual(9, (try f.call(&primitives, "%record-ref", &.{ r, t, .fromFixnum(2) })).asFixnum().?);
}

test "%make-record fails at the limit, leaving the account as it was" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    f.heap.deinit();
    // 型と、フィールド1つのレコードには足りるが、2つには足りない上限。
    var probe: heap_mod.Heap = .init(std.testing.allocator, .{});
    defer probe.deinit();
    const pt = try probe.create(value.RecordType, .{ .name = @fromBackingInt(0), .field_count = 1 });
    _ = try probe.createRecord(pt, &.{.fromFixnum(1)});
    f.heap = .init(std.testing.allocator, .{ .limit = probe.accounted + @sizeOf(Value) - 1 });
    const t = try f.call(&primitives, "%make-record-type", &.{ sym(0), .fromFixnum(2) });
    const accounted = f.heap.accounted;
    try std.testing.expectError(error.HeapLimit, f.call(&primitives, "%make-record", &.{ t, .fromFixnum(1), .fromFixnum(2) }));
    try std.testing.expectEqual(accounted, f.heap.accounted);
}

test "a collection keeps the type and the fields of a record the roots reach" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    const t = try f.call(&primitives, "%make-record-type", &.{ sym(0), .fromFixnum(2) });
    const s: Value = .fromString(try f.heap.createString("あいう"));
    const r = try f.call(&primitives, "%make-record", &.{ t, s, .fromFixnum(1) });
    _ = try f.heap.createString("garbage");
    const Roots = struct {
        v: Value,
        pub fn mark(self: @This(), marker: *heap_mod.Marker) void {
            marker.value(self.v);
        }
    };
    f.heap.collect(Roots{ .v = r });
    try std.testing.expectEqual(3, f.heap.count);
    try std.testing.expectEqual(1, f.heap.countOf(value.RecordType));
    const kept = (try f.call(&primitives, "%record-ref", &.{ r, t, .fromFixnum(0) })).asString().?;
    try std.testing.expectEqualStrings("あいう", kept.bytes);
}
