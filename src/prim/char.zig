//! Character primitives (R7RS 6.6).
//!
//! 大文字小文字の変換などの属性は、このファイルにまだ無い。Unicode の表が入る段階4で足す。
//! 大文字小文字を区別しない比較(`char-ci=?` など)も、畳み込みの表が要るので段階4である。

const std = @import("std");
const value = @import("../value.zig");
const Value = value.Value;
const Primitive = value.Primitive;
const Services = value.Services;
const PrimitiveError = value.PrimitiveError;

pub const Error = PrimitiveError;

pub const primitives = [_]Primitive{
    .{ .name = "char?", .min_args = 1, .max_args = 1, .body = .{ .pure = &isChar } },
    .{ .name = "char->integer", .min_args = 1, .max_args = 1, .body = .{ .pure = &charToInteger } },
    .{ .name = "integer->char", .min_args = 1, .max_args = 1, .body = .{ .pure = &integerToChar } },
    .{ .name = "char=?", .min_args = 1, .max_args = null, .body = .{ .pure = comparison(.eq) } },
    .{ .name = "char<?", .min_args = 1, .max_args = null, .body = .{ .pure = comparison(.lt) } },
    .{ .name = "char>?", .min_args = 1, .max_args = null, .body = .{ .pure = comparison(.gt) } },
    .{ .name = "char<=?", .min_args = 1, .max_args = null, .body = .{ .pure = comparison(.lte) } },
    .{ .name = "char>=?", .min_args = 1, .max_args = null, .body = .{ .pure = comparison(.gte) } },
};

/// `(char? obj)`.
fn isChar(_: *const Services, args: []const Value) Error!Value {
    return .fromBool(args[0].asCharacter() != null);
}

/// `(char->integer char)`: the code point of the character (R7RS 6.6).
fn charToInteger(_: *const Services, args: []const Value) Error!Value {
    const c = args[0].asCharacter() orelse return error.WrongType;
    return .fromFixnum(c);
}

/// `(integer->char n)`: the character with code point `n` (R7RS 6.6).
///
/// Why: R7RS 6.6 は、`integer->char` が受け付ける整数を、0 から #xD7FF、または #xE000
/// から #x10FFFF までとしている。サロゲートと #x10FFFF を超える整数は文字にならない。
/// 引数は 64 ビットの整数なので、`u32` に収まるかを先に調べる。`wasm32` でも幅が同じで、
/// 切り捨てて範囲内に戻ってしまうことがない。
fn integerToChar(_: *const Services, args: []const Value) Error!Value {
    const n = args[0].asFixnum() orelse return error.WrongType;
    const code_point = std.math.cast(u32, n) orelse return error.OutOfRange;
    if (!value.isScalarValue(code_point)) return error.OutOfRange;
    return .fromCharacter(@intCast(code_point));
}

/// `(char=? char1 char2 char3 ...)` and the other four comparisons (R7RS 6.6): whether
/// every neighboring pair of the arguments is in the order, by code point.
///
/// 整数の比較(`src/prim/arith.zig` の `comparison`)と同じ形である。引数が1つなら真、
/// なしならエラー(機械が表の下限で報告する)。最初に成り立たなかった組より後のものも含め、
/// すべての引数が文字であることを検査する。エラーが値に左右されないようにするためである。
/// 順序は、`char->integer` の結果の順序である(R7RS 6.6 がそう定めている。原文は取得できて
/// いない)。
fn comparison(comptime op: std.math.CompareOperator) Primitive.Fn {
    return &struct {
        fn call(_: *const Services, args: []const Value) Error!Value {
            for (args) |a| _ = a.asCharacter() orelse return error.WrongType;
            var holds = true;
            for (args[0 .. args.len - 1], args[1..]) |a, b| {
                if (!std.math.compare(a.asCharacter().?, op, b.asCharacter().?)) holds = false;
            }
            return .fromBool(holds);
        }
    }.call;
}

test {
    std.testing.refAllDecls(@This());
}

const test_support = @import("test_support.zig");

fn call(name: []const u8, args: []const Value) Error!Value {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    return f.call(&primitives, name, args);
}

test "the primitives take the numbers of arguments the language gives them" {
    const Arity = struct { name: []const u8, min: u8, max: ?u8 };
    const expected = [_]Arity{
        .{ .name = "char?", .min = 1, .max = 1 },
        .{ .name = "char->integer", .min = 1, .max = 1 },
        .{ .name = "integer->char", .min = 1, .max = 1 },
        .{ .name = "char=?", .min = 1, .max = null },
        .{ .name = "char<?", .min = 1, .max = null },
        .{ .name = "char>?", .min = 1, .max = null },
        .{ .name = "char<=?", .min = 1, .max = null },
        .{ .name = "char>=?", .min = 1, .max = null },
    };
    try std.testing.expectEqual(expected.len, primitives.len);
    for (expected, primitives) |e, p| {
        try std.testing.expectEqualStrings(e.name, p.name);
        try std.testing.expectEqual(e.min, p.min_args);
        try std.testing.expectEqual(e.max, p.max_args);
    }
}

test "char? is true of a character and of nothing else" {
    try std.testing.expect((try call("char?", &.{.fromCharacter('a')})).isTrue());
    try std.testing.expect((try call("char?", &.{.fromCharacter(0)})).isTrue());
    try std.testing.expect((try call("char?", &.{.fromCharacter(0x10FFFF)})).isTrue());
    for ([_]Value{ .fromFixnum(97), .fromBool(true), .empty_list_value, .unspecified_value }) |v| {
        const r = try call("char?", &.{v});
        try std.testing.expectEqual(value.Kind.boolean, r.kind());
        try std.testing.expect(!r.isTrue());
    }
}

test "char->integer gives the code point" {
    for ([_]u21{ 0, 'a', 0x7F, 0x80, 0x3BB, 0xD7FF, 0xE000, 0xFFFF, 0x10000, 0x10FFFF }) |c| {
        try std.testing.expectEqual(c, (try call("char->integer", &.{.fromCharacter(c)})).asFixnum().?);
    }
}

test "char->integer reports an argument that is not a character" {
    try std.testing.expectError(error.WrongType, call("char->integer", &.{.fromFixnum(97)}));
    try std.testing.expectError(error.WrongType, call("char->integer", &.{.fromBool(false)}));
    try std.testing.expectError(error.WrongType, call("char->integer", &.{.empty_list_value}));
}

test "integer->char makes the character with the code point" {
    for ([_]u21{ 0, 'a', 0x7F, 0x80, 0x3BB, 0xD7FF, 0xE000, 0xFFFF, 0x10000, 0x10FFFF }) |c| {
        const r = try call("integer->char", &.{.fromFixnum(c)});
        try std.testing.expectEqual(value.Kind.character, r.kind());
        try std.testing.expectEqual(c, r.asCharacter().?);
    }
}

test "integer->char refuses the surrogates and what is past the range" {
    const out_of_range = [_]i64{
        0xD800,
        0xDBFF,
        0xDC00,
        0xDFFF,
        0x110000,
        // 32 ビットに切り捨てると範囲内に戻る値。
        0x1_0000_0041,
        std.math.maxInt(u32),
        std.math.maxInt(u32) + 1,
        std.math.maxInt(i64),
        -1,
        std.math.minInt(i32),
        std.math.minInt(i64),
    };
    for (out_of_range) |n| {
        try std.testing.expectError(error.OutOfRange, call("integer->char", &.{.fromFixnum(n)}));
    }
}

test "integer->char reports an argument that is not an integer, before it looks at the range" {
    try std.testing.expectError(error.WrongType, call("integer->char", &.{.fromCharacter('a')}));
    try std.testing.expectError(error.WrongType, call("integer->char", &.{.fromBool(true)}));
    try std.testing.expectError(error.WrongType, call("integer->char", &.{.empty_list_value}));
}

/// Calls the comparison `name` on the characters with the code points `points`.
fn compareCodePoints(name: []const u8, points: []const u21) !bool {
    var args: [8]Value = undefined;
    for (points, 0..) |c, i| args[i] = .fromCharacter(c);
    const r = try call(name, args[0..points.len]);
    try std.testing.expectEqual(value.Kind.boolean, r.kind());
    return r.isTrue();
}

test "the comparisons of two characters follow their code points" {
    // 小さい、等しい、大きい、の3通りに対する5つの比較の答え。
    const Row = struct { name: []const u8, less: bool, equal: bool, greater: bool };
    const rows = [_]Row{
        .{ .name = "char=?", .less = false, .equal = true, .greater = false },
        .{ .name = "char<?", .less = true, .equal = false, .greater = false },
        .{ .name = "char>?", .less = false, .equal = false, .greater = true },
        .{ .name = "char<=?", .less = true, .equal = true, .greater = false },
        .{ .name = "char>=?", .less = false, .equal = true, .greater = true },
    };
    for (rows) |r| {
        try std.testing.expectEqual(r.less, try compareCodePoints(r.name, &.{ 'a', 'b' }));
        try std.testing.expectEqual(r.equal, try compareCodePoints(r.name, &.{ 'a', 'a' }));
        try std.testing.expectEqual(r.greater, try compareCodePoints(r.name, &.{ 'b', 'a' }));
        // 大文字は小文字より前にある。大文字小文字は区別される。
        try std.testing.expectEqual(r.less, try compareCodePoints(r.name, &.{ 'Z', 'a' }));
        // ASCII の外も、コードポイントの順である。UTF-8 のバイト列の順とは別の根拠で、
        // 最大の文字と、サロゲートの前後の文字を含む。
        try std.testing.expectEqual(r.less, try compareCodePoints(r.name, &.{ 0xD7FF, 0xE000 }));
        try std.testing.expectEqual(r.greater, try compareCodePoints(r.name, &.{ 0x10FFFF, 0xFFFF }));
        try std.testing.expectEqual(r.less, try compareCodePoints(r.name, &.{ 0, 1 }));
        try std.testing.expectEqual(r.equal, try compareCodePoints(r.name, &.{ 0x10FFFF, 0x10FFFF }));
    }
}

test "the comparisons take any number of characters, and hold when every neighboring pair does" {
    try std.testing.expect(try compareCodePoints("char=?", &.{ 'a', 'a', 'a', 'a' }));
    try std.testing.expect(!try compareCodePoints("char=?", &.{ 'a', 'a', 'b' }));
    try std.testing.expect(!try compareCodePoints("char=?", &.{ 'b', 'a', 'a' }));
    try std.testing.expect(try compareCodePoints("char<?", &.{ 'a', 'b', 'c', 'd' }));
    try std.testing.expect(!try compareCodePoints("char<?", &.{ 'a', 'b', 'b' }));
    try std.testing.expect(!try compareCodePoints("char<?", &.{ 'a', 'c', 'b' }));
    try std.testing.expect(try compareCodePoints("char>?", &.{ 'd', 'c', 'b' }));
    try std.testing.expect(!try compareCodePoints("char>?", &.{ 'd', 'b', 'c' }));
    try std.testing.expect(try compareCodePoints("char<=?", &.{ 'a', 'a', 'b', 'b' }));
    try std.testing.expect(!try compareCodePoints("char<=?", &.{ 'a', 'b', 'a' }));
    try std.testing.expect(try compareCodePoints("char>=?", &.{ 'c', 'c', 'b', 'a' }));
    try std.testing.expect(!try compareCodePoints("char>=?", &.{ 'c', 'b', 'c' }));
    // 1つの引数は、比べる相手が無いので真である(`=` と同じ)。
    for ([_][]const u8{ "char=?", "char<?", "char>?", "char<=?", "char>=?" }) |name| {
        try std.testing.expect(try compareCodePoints(name, &.{'a'}));
    }
}

test "the comparisons check every argument for being a character, after the first pair that fails too" {
    for ([_][]const u8{ "char=?", "char<?", "char>?", "char<=?", "char>=?" }) |name| {
        try std.testing.expectError(error.WrongType, call(name, &.{ .fromCharacter('a'), .fromFixnum(97) }));
        try std.testing.expectError(error.WrongType, call(name, &.{ .fromFixnum(97), .fromCharacter('a') }));
        try std.testing.expectError(error.WrongType, call(name, &.{.fromFixnum(97)}));
        try std.testing.expectError(error.WrongType, call(name, &.{.empty_list_value}));
        // 最初の組が成り立たなくても、3つ目の誤りが報告される。エラーは値に左右されない。
        try std.testing.expectError(error.WrongType, call(name, &.{ .fromCharacter('b'), .fromCharacter('a'), .fromCharacter('a'), .fromBool(true) }));
        try std.testing.expectError(error.WrongType, call(name, &.{ .fromCharacter('a'), .fromCharacter('b'), .fromBool(false) }));
    }
}
