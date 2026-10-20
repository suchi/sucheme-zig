//! Numbers: making them, reading them, and writing them
//! (docs/design/numerics-and-unicode.md).
//!
//! 数を作る関数と正規化は、このファイルに閉じる。ほかのファイルは、`Value` の数の
//! 変種を直接作らない。リーダ(src/reader.zig)は `parse` を、プリンタ(src/printer.zig)
//! は `write` を呼ぶ。署名は docs/plans/0018-phase4-numeric-tower-unicode.md の
//! 「レーンの間の関数の署名」が正である。
//!
//! スライス 4d は型の骨格だけを入れ、ここには仮の `write` だけを置く。`parse` と
//! 正規化は、スライス 4e で入れる。

const std = @import("std");
const value_mod = @import("../value.zig");
const Value = value_mod.Value;

/// Whether `v` is a number.
pub fn isNumber(v: Value) bool {
    return switch (v.kind()) {
        .fixnum, .flonum, .bignum, .ratnum, .compnum => true,
        else => false,
    };
}

/// Writes the number `v` in the external representation of `radix`, which is
/// 2, 8, 10 or 16 (R7RS 6.2.7).
/// `scratch` は作業領域で、戻る前に取ったものを返す。
///
/// Why: スライス 4d では、固定長の整数のほかを、読み戻せない仮の表記で書く。数を
/// 作るのはまだ単体テストだけで、書式の本体(スライス 4b の浮動小数点数と 4c の
/// 多倍長整数)が無いからである。プリンタを触るのは 4d の1回だけにし、4e がこの関数の
/// 中身だけを替える。
pub fn write(out: *std.Io.Writer, scratch: std.mem.Allocator, v: Value, radix: u8) (std.Io.Writer.Error || error{OutOfMemory})!void {
    _ = scratch;
    std.debug.assert(isNumber(v));
    std.debug.assert(radix == 2 or radix == 8 or radix == 10 or radix == 16);
    if (v.asFixnum()) |n| return out.printInt(n, radix, .lower, .{});
    try out.writeAll("#<number>");
}

test {
    std.testing.refAllDecls(@This());
}

test "isNumber answers for the five kinds of number and nothing else" {
    var limbs = [_]value_mod.Limb{1};
    var b: value_mod.Bignum = .{ .limbs = &limbs, .positive = true };
    var r: value_mod.Ratnum = .{ .numerator = .fromFixnum(1), .denominator = .fromFixnum(2) };
    var c: value_mod.Compnum = .{ .real = .fromFixnum(1), .imag = .fromFixnum(1) };
    for ([_]Value{ .fromFixnum(0), .fromFlonum(0.5), .fromBignum(&b), .fromRatnum(&r), .fromCompnum(&c) }) |v| {
        try std.testing.expect(isNumber(v));
    }
    var p: value_mod.Pair = .{ .car = .fromFixnum(1), .cdr = .empty_list_value };
    var bytes = "1".*;
    var s: value_mod.String = .{ .bytes = &bytes, .is_ascii = true };
    var items = [_]Value{.fromFixnum(1)};
    var vec: value_mod.Vector = .{ .items = &items };
    for ([_]Value{ .fromBool(false), .empty_list_value, .fromCharacter('1'), .unspecified_value, .eof_value, .fromSymbol(@fromBackingInt(@intCast(0))), .{ .pair = &p }, .fromString(&s), .fromVector(&vec) }) |v| {
        try std.testing.expect(!isNumber(v));
    }
}

test "write writes a fixnum in the radix, and the other numbers as a placeholder until slice 4e" {
    var buf: [64]u8 = undefined;
    for ([_]struct { radix: u8, text: []const u8 }{
        .{ .radix = 10, .text = "-255" },
        .{ .radix = 16, .text = "-ff" },
        .{ .radix = 8, .text = "-377" },
        .{ .radix = 2, .text = "-11111111" },
    }) |case| {
        var out: std.Io.Writer = .fixed(&buf);
        try write(&out, std.testing.allocator, .fromFixnum(-255), case.radix);
        try std.testing.expectEqualStrings(case.text, out.buffered());
    }
    var out: std.Io.Writer = .fixed(&buf);
    try write(&out, std.testing.allocator, .fromFlonum(0.5), 10);
    try std.testing.expectEqualStrings("#<number>", out.buffered());
}
