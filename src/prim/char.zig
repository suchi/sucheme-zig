//! Character primitives (R7RS 6.6).
//!
//! 文字の比較(`char=?` など)と、大文字小文字の変換などの属性は、このファイルに
//! まだ無い。比較は段階3、属性は Unicode の表が入る段階4で足す。

const std = @import("std");
const value = @import("../value.zig");
const Value = value.Value;
const Primitive = value.Primitive;
const Services = value.Services;
const PrimitiveError = value.PrimitiveError;

pub const Error = PrimitiveError;

pub const primitives = [_]Primitive{
    .{ .name = "char?", .min_args = 1, .max_args = 1, .call = &isChar },
    .{ .name = "char->integer", .min_args = 1, .max_args = 1, .call = &charToInteger },
    .{ .name = "integer->char", .min_args = 1, .max_args = 1, .call = &integerToChar },
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
