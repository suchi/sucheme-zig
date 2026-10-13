//! String primitives (R7RS 6.7).
//!
//! 文字列は UTF-8 のバイト列で、全部が ASCII かどうかのフラグを持つ(ADR-0008)。
//! 長さと位置は文字(Unicode スカラ値)で数える。バイトでは数えない。数え方は
//! `value.String` にあり、ここは型と範囲を検査して呼ぶだけである。
//! 変更する手続き(`string-set!`)と、大きさを数で決める生成(`make-string`)は、
//! 段階3に送った。

const std = @import("std");
const value = @import("../value.zig");
const Value = value.Value;
const Primitive = value.Primitive;
const Services = value.Services;
const PrimitiveError = value.PrimitiveError;

pub const Error = PrimitiveError;

pub const primitives = [_]Primitive{
    .{ .name = "string?", .min_args = 1, .max_args = 1, .body = .{ .pure = &isString } },
    .{ .name = "string-length", .min_args = 1, .max_args = 1, .body = .{ .pure = &stringLength } },
    .{ .name = "string-ref", .min_args = 2, .max_args = 2, .body = .{ .pure = &stringRef } },
};

/// `(string? obj)`.
fn isString(_: *const Services, args: []const Value) Error!Value {
    return .fromBool(args[0].asString() != null);
}

/// `(string-length string)`: the number of characters (R7RS 6.7).
///
/// 長さは文字の数で、バイトの数ではない。`"あいう"` は 3 である。
fn stringLength(_: *const Services, args: []const Value) Error!Value {
    const s = args[0].asString() orelse return error.WrongType;
    // 文字の数は、バイトの数を超えず、バイトの数は確保できた大きさなので、i64 に収まる。
    return .fromFixnum(@intCast(s.length()));
}

/// `(string-ref string k)`: the `k`th character, counted from 0 (R7RS 6.7).
///
/// Why: R7RS 6.7 は、`k` が妥当な添字でなければ誤りとしている。`k` は文字の位置で
/// ある。添字の検査は、型の検査のあとに行う。引数は 64 ビットの整数なので、`usize` に
/// 変えられるかを先に調べる。`wasm32` で `@intCast` すると、大きな値の検査で
/// パニックするか、切り捨てて範囲内に戻ってしまう。
fn stringRef(_: *const Services, args: []const Value) Error!Value {
    const s = args[0].asString() orelse return error.WrongType;
    const k = args[1].asFixnum() orelse return error.WrongType;
    const index = std.math.cast(usize, k) orelse return error.OutOfRange;
    return .fromCharacter(s.charAt(index) orelse return error.OutOfRange);
}

test {
    std.testing.refAllDecls(@This());
}

const test_support = @import("test_support.zig");
const string_syntax = @import("../string_syntax.zig");

/// A heap, and the `Services` over it, with the string `text` made in it.
const Probe = struct {
    fixture: test_support.Fixture,
    string: Value,

    fn init(self: *Probe, text: []const u8) !void {
        self.fixture.init();
        self.string = .fromString(try self.fixture.heap.createString(text));
    }

    fn deinit(self: *Probe) void {
        self.fixture.deinit();
    }

    fn call(self: *Probe, name: []const u8, args: []const Value) Error!Value {
        return self.fixture.call(&primitives, name, args);
    }

    /// `(string-length s)`.
    fn length(self: *Probe) !i64 {
        return (try self.call("string-length", &.{self.string})).asFixnum().?;
    }

    /// `(string-ref s k)`.
    fn ref(self: *Probe, k: i64) Error!Value {
        return self.call("string-ref", &.{ self.string, .fromFixnum(k) });
    }
};

test "the primitives take the numbers of arguments the language gives them" {
    const Arity = struct { name: []const u8, min: u8, max: ?u8 };
    const expected = [_]Arity{
        .{ .name = "string?", .min = 1, .max = 1 },
        .{ .name = "string-length", .min = 1, .max = 1 },
        .{ .name = "string-ref", .min = 2, .max = 2 },
    };
    try std.testing.expectEqual(expected.len, primitives.len);
    for (expected, primitives) |e, p| {
        try std.testing.expectEqualStrings(e.name, p.name);
        try std.testing.expectEqual(e.min, p.min_args);
        try std.testing.expectEqual(e.max, p.max_args);
    }
}

test "string? is true of a string, the empty one included, and of nothing else" {
    var p: Probe = undefined;
    try p.init("");
    defer p.deinit();
    try std.testing.expect((try p.call("string?", &.{p.string})).isTrue());
    const other = [_]Value{ .fromCharacter('a'), .fromFixnum(1), .empty_list_value, .fromBool(true), .unspecified_value };
    for (other) |v| {
        const r = try p.call("string?", &.{v});
        try std.testing.expectEqual(value.Kind.boolean, r.kind());
        try std.testing.expect(!r.isTrue());
    }
    const vector: Value = .fromVector(try p.fixture.heap.createVector(&.{}));
    try std.testing.expect(!(try p.call("string?", &.{vector})).isTrue());
}

test "string-length counts characters, not bytes" {
    const Case = struct { text: []const u8, length: i64 };
    const cases = [_]Case{
        .{ .text = "", .length = 0 },
        .{ .text = "a", .length = 1 },
        .{ .text = "hello", .length = 5 },
        .{ .text = "あ", .length = 1 },
        .{ .text = "あいう", .length = 3 },
        .{ .text = "aあb", .length = 3 },
        .{ .text = "aλあ𐀀z", .length = 5 },
        .{ .text = "𐀀𐀀𐀀", .length = 3 },
        .{ .text = "\u{80}", .length = 1 },
        .{ .text = "\x00\x7f", .length = 2 },
    };
    for (cases) |c| {
        var p: Probe = undefined;
        try p.init(c.text);
        defer p.deinit();
        try std.testing.expectEqual(c.length, try p.length());
    }
}

test "string-length does not take a string for the flag it carries" {
    // フラグが立っていても立っていなくても、答えは同じ文字の数である。ASCII の文字列で
    // フラグを下ろして走査の経路を通し、立てた経路と一致することを確かめる。
    var p: Probe = undefined;
    try p.init("hello");
    defer p.deinit();
    try std.testing.expect(p.string.asString().?.is_ascii);
    try std.testing.expectEqual(5, try p.length());
    p.string.asString().?.is_ascii = false;
    try std.testing.expectEqual(5, try p.length());
}

test "string-ref gives the character at a position counted in characters" {
    var p: Probe = undefined;
    try p.init("aλあ𐀀z");
    defer p.deinit();
    const expected = [_]u21{ 'a', 0x3BB, 0x3042, 0x10000, 'z' };
    for (expected, 0..) |c, i| {
        const r = try p.ref(@intCast(i));
        try std.testing.expectEqual(value.Kind.character, r.kind());
        try std.testing.expectEqual(c, r.asCharacter().?);
    }
}

test "string-ref of an ASCII string is the byte at that position" {
    var p: Probe = undefined;
    try p.init("abc");
    defer p.deinit();
    try std.testing.expect(p.string.asString().?.is_ascii);
    try std.testing.expectEqual('a', (try p.ref(0)).asCharacter().?);
    try std.testing.expectEqual('c', (try p.ref(2)).asCharacter().?);
}

test "string-ref refuses a position outside the string" {
    const texts = [_][]const u8{ "", "abc", "あいう", "aあb", "𐀀" };
    for (texts) |text| {
        var p: Probe = undefined;
        try p.init(text);
        defer p.deinit();
        const n = try p.length();
        // 長さちょうどと、その先。バイトの数に届かない位置も範囲外である。
        try std.testing.expectError(error.OutOfRange, p.ref(n));
        try std.testing.expectError(error.OutOfRange, p.ref(n + 1));
        try std.testing.expectError(error.OutOfRange, p.ref(100));
        try std.testing.expectError(error.OutOfRange, p.ref(-1));
        try std.testing.expectError(error.OutOfRange, p.ref(std.math.minInt(i64)));
        try std.testing.expectError(error.OutOfRange, p.ref(std.math.maxInt(i64)));
        // `usize` が 32 ビットでも、切り捨てて範囲内に戻らない値。
        try std.testing.expectError(error.OutOfRange, p.ref(1 << 32));
        try std.testing.expectError(error.OutOfRange, p.ref((1 << 32) + 1));
        // 最後の文字までは読める。
        if (n > 0) _ = try p.ref(n - 1);
    }
}

test "string-ref and string-length report an argument of the wrong type, before the range" {
    var p: Probe = undefined;
    try p.init("abc");
    defer p.deinit();
    try std.testing.expectError(error.WrongType, p.call("string-length", &.{.fromFixnum(1)}));
    try std.testing.expectError(error.WrongType, p.call("string-length", &.{.fromCharacter('a')}));
    try std.testing.expectError(error.WrongType, p.call("string-length", &.{.empty_list_value}));
    // 文字列でない最初の引数は、添字が範囲外でも型のエラーになる。
    try std.testing.expectError(error.WrongType, p.call("string-ref", &.{ .fromFixnum(1), .fromFixnum(0) }));
    try std.testing.expectError(error.WrongType, p.call("string-ref", &.{ .fromFixnum(1), .fromFixnum(100) }));
    try std.testing.expectError(error.WrongType, p.call("string-ref", &.{ .fromFixnum(1), .fromFixnum(-1) }));
    // 整数でない添字。
    try std.testing.expectError(error.WrongType, p.call("string-ref", &.{ p.string, .fromCharacter('a') }));
    try std.testing.expectError(error.WrongType, p.call("string-ref", &.{ p.string, p.string }));
    try std.testing.expectError(error.WrongType, p.call("string-ref", &.{ p.string, .empty_list_value }));
}

test "a string the reader makes has the flag set by what it holds" {
    // リテラルとエスケープ。ソースは ASCII でも、エスケープが ASCII でない文字を作る。
    const Case = struct { source: []const u8, ascii: bool, length: i64 };
    const cases = [_]Case{
        .{ .source = "\"\"", .ascii = true, .length = 0 },
        .{ .source = "\"abc\"", .ascii = true, .length = 3 },
        .{ .source = "\"a\\tb\"", .ascii = true, .length = 3 },
        .{ .source = "\"\\x41;\"", .ascii = true, .length = 1 },
        .{ .source = "\"\\x7f;\"", .ascii = true, .length = 1 },
        .{ .source = "\"\\x80;\"", .ascii = false, .length = 1 },
        .{ .source = "\"\\x3bb;\"", .ascii = false, .length = 1 },
        .{ .source = "\"a\\x3bb;b\"", .ascii = false, .length = 3 },
        .{ .source = "\"あいう\"", .ascii = false, .length = 3 },
        .{ .source = "\"abc\\x10ffff;\"", .ascii = false, .length = 4 },
    };
    for (cases) |c| {
        var f: test_support.Fixture = undefined;
        f.init();
        defer f.deinit();
        var pos: usize = 0;
        const v = try string_syntax.read(c.source, &pos, std.testing.allocator, &f.heap);
        try std.testing.expectEqual(c.ascii, v.asString().?.is_ascii);
        const n = try f.call(&primitives, "string-length", &.{v});
        try std.testing.expectEqual(c.length, n.asFixnum().?);
    }
}

test "a collection keeps the flag and the characters of a string the roots reach" {
    var p: Probe = undefined;
    try p.init("あいう");
    defer p.deinit();
    const garbage = try p.fixture.heap.createString("garbage あ");
    _ = garbage;
    const Roots = struct {
        v: Value,
        pub fn mark(self: @This(), marker: *@import("../heap.zig").Marker) void {
            marker.value(self.v);
        }
    };
    p.fixture.heap.collect(Roots{ .v = p.string });
    try std.testing.expectEqual(1, p.fixture.heap.count);
    try std.testing.expectEqual(3, try p.length());
    try std.testing.expectEqual(0x3046, (try p.ref(2)).asCharacter().?);
    try std.testing.expect(!p.string.asString().?.is_ascii);
}
