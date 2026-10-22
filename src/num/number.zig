//! Numbers: making them, reading them, and writing them
//! (docs/design/numerics-and-unicode.md).
//!
//! 数を作る関数と正規化は、このファイルに閉じる。ほかのファイルは、`Value` の数の
//! 変種を直接作らない。リーダ(src/reader.zig)は `parse` を、プリンタ(src/printer.zig)
//! は `write` を呼ぶ。署名は docs/plans/0018-phase4-numeric-tower-unicode.md の
//! 「レーンの間の関数の署名」が正である。
//!
//! スライス 4e-1 は、複素数を除く4種(fixnum、bignum、ratnum、flonum)の `parse` と
//! `write` を入れる。複素数の構文と書き出し(compnum)は、スライス 4e-2 で入れる。

const std = @import("std");
const value_mod = @import("../value.zig");
const heap_mod = @import("../heap.zig");
const bigint = @import("bigint.zig");
const exact = @import("exact.zig");
const flonum = @import("flonum.zig");
const syntax = @import("syntax.zig");
const tier = @import("../tier.zig");

const Value = value_mod.Value;
const Ratnum = value_mod.Ratnum;
const Heap = heap_mod.Heap;
const Const = bigint.Const;
const Managed = bigint.Managed;

pub const Error = heap_mod.Error;

/// Whether `v` is a number.
pub fn isNumber(v: Value) bool {
    return switch (v.kind()) {
        .fixnum, .flonum, .bignum, .ratnum, .compnum => true,
        else => false,
    };
}

/// The integer `n` as a fixnum when it fits one, and as a bignum otherwise.
///
/// 整数を作る入口は、正規化(`i64` に収まる bignum は fixnum にする)をここで行う。
pub fn fromInteger(h: *Heap, n: Const) Error!Value {
    if (n.toInt(i64)) |small| return .fromFixnum(small) else |_| {}
    return .fromBignum(try h.createBignum(n));
}

/// The ratio `numerator / denominator` in lowest terms, with a positive denominator, as an
/// integer when the denominator comes to 1.
///
/// `denominator` は 0 でない。符号はどちらにあってもよい。作業領域は `gpa` から取り、
/// 返る前に返す。
pub fn makeRatio(h: *Heap, gpa: std.mem.Allocator, numerator: Const, denominator: Const) Error!Value {
    std.debug.assert(!denominator.eqlZero());
    var g = try bigint.gcd(gpa, numerator, denominator);
    defer g.deinit();
    var n = try bigint.divide(gpa, numerator, g.toConst(), .truncate);
    defer n.q.deinit();
    defer n.r.deinit();
    var d = try bigint.divide(gpa, denominator, g.toConst(), .truncate);
    defer d.q.deinit();
    defer d.r.deinit();
    if (!d.q.isPositive()) {
        d.q.negate();
        if (!n.q.eqlZero()) n.q.negate();
    }
    if (d.q.toConst().orderAgainstScalar(1) == .eq) return fromInteger(h, n.q.toConst());
    const numerator_value = try fromInteger(h, n.q.toConst());
    const denominator_value = try fromInteger(h, d.q.toConst());
    const ratnum = try h.create(Ratnum, .{ .numerator = numerator_value, .denominator = denominator_value });
    return .fromRatnum(ratnum);
}

/// Reads `text` as a number of R7RS 7.1.1 and returns it, normalized, or null if it is not one.
///
/// `default_radix`(2、8、10、16)は、基数の接頭辞が無いときの基数である。数でないか、表せない
/// 大きさ(置けない大きさの正確な整数、`#e+inf.0`、分母が0の `1/0`)なら null を返し、内容を
/// 理由に誤りを送出しない(R7RS 6.2.7)。複素数の綴りは、スライス 4e-2 までは null になる。
///
/// 作業領域はヒープの上限に計上する。結果の大きさは、確保の前に(綴りの写しの確保も
/// 含めて)桁数と指数から見積もり、置けない大きさなら確保せずに null を返す。見積りは、
/// 読む数の限界値数に、作業用の `Managed`、除算の商と余りと作業用、`pow` の作業用、
/// ペイロードの写しを見込んだ倍率(`work_factor` と `work_slack`)で、上限の残りと比べる。
/// 上限にほかの作業が数えられていて断られたときだけ、`HeapLimit` になる。
pub fn parse(h: *Heap, text: []const u8, default_radix: u8) Error!?Value {
    const literal = syntax.scan(text, default_radix) orelse return null;
    const real = switch (literal.shape) {
        .real => |r| r,
        .rectangular, .polar => return null,
    };
    h.external_refused = false;
    const before = h.beginCounting(true);
    defer h.endCounting(before);
    var charged: heap_mod.Charged = .{ .heap = h, .backing = h.backing };
    return parseReal(h, charged.allocator(), text, literal, real) catch |e| switch (e) {
        error.OutOfMemory => if (h.external_refused) error.HeapLimit else error.OutOfMemory,
        error.HeapLimit => error.HeapLimit,
    };
}

/// How many times the bytes of the limbs that a number is read from the work of reading
/// it may take at the most, and the bytes it takes whatever the size.
/// Why: 実測した(2026-10-22、ヒープの上限を二分探索して、読み込みが成功する最小の上限を
/// 求めた)。桁数が 2000 から 20000 の乱数で、整数は 2.0 倍、`#i` の整数は 1.0 倍、分数は
/// 分子と分母の合計の 5.0 倍(約分と除算の商と余りと作業用)、`#e1e-N` は冪の 4.4 倍、
/// `#e1eN` は 2.7 倍だった。小さい入力には約 700 バイトの固定費がある。そこで 8 倍と
/// 2048 バイトを見込む。見積りを通ったあとで確保が断られないことは、テストが上限を
/// 掃引して固定する。
const work_factor = 8;
const work_slack = 2048;

/// Whether a number read from `limbs` limbs can be made in what room the heap has left.
fn fitsInHeap(h: *const Heap, limbs: usize) bool {
    const room = h.options.limit -| h.held();
    return limbs *| @sizeOf(value_mod.Limb) *| work_factor +| work_slack <= room;
}

const one_limbs = [_]value_mod.Limb{1};
const one: Const = .{ .limbs = &one_limbs, .positive = true };
const ten_limbs = [_]value_mod.Limb{10};
const ten: Const = .{ .limbs = &ten_limbs, .positive = true };

fn parseReal(h: *Heap, gpa: std.mem.Allocator, text: []const u8, literal: syntax.Literal, real: syntax.Real) Error!?Value {
    const inexact = literal.exactness == .inexact;
    switch (real) {
        .infnan => |kind| {
            if (literal.exactness == .exact) return null;
            return .fromFlonum(switch (kind) {
                .positive_infinity => std.math.inf(f64),
                .negative_infinity => -std.math.inf(f64),
                .positive_nan, .negative_nan => std.math.nan(f64),
            });
        },
        .integer => |i| {
            if (!fitsInHeap(h, bigint.limbsForDigits(i.digits.len, literal.radix))) return null;
            var n = try bigint.parseDigits(gpa, i.digits, literal.radix);
            defer n.deinit();
            // Why: `#i-0` は -0.0 である。基数10以外で -0.0 を書くと `#i-0` になる(`write`)ので、
            // これを -0.0 と読まないと、R7RS 6.2.7 の往復条件 `(eqv? z (string->number
            // (number->string z radix) radix))` が -0.0 で成り立たない。小数点の綴りは基数10に限る。
            if (inexact) return .fromFlonum(signedF64(i.sign, try exact.ratioToF64(gpa, n.toConst(), one)));
            applySign(&n, i.sign);
            return try fromInteger(h, n.toConst());
        },
        .ratio => |r| {
            if (!fitsInHeap(h, bigint.limbsForDigits(r.numerator.len, literal.radix) +| bigint.limbsForDigits(r.denominator.len, literal.radix))) return null;
            var d = try bigint.parseDigits(gpa, r.denominator, literal.radix);
            defer d.deinit();
            if (d.eqlZero()) return null;
            var n = try bigint.parseDigits(gpa, r.numerator, literal.radix);
            defer n.deinit();
            if (inexact) return .fromFlonum(signedF64(r.sign, try exact.ratioToF64(gpa, n.toConst(), d.toConst())));
            applySign(&n, r.sign);
            return try makeRatio(h, gpa, n.toConst(), d.toConst());
        },
        .decimal => |d| {
            if (literal.exactness == .exact) return try parseExactDecimal(h, gpa, d);
            // 符号を除いた綴りは、接頭辞と符号のあとの全体である(複素数ではない)。
            const x = flonum.parseDecimal(unsignedSpelling(text)) catch return null;
            return .fromFlonum(signedF64(d.sign, x));
        },
    }
}

/// The text of a real number without its prefixes (`#x`, `#e`, ...) and its sign.
fn unsignedSpelling(text: []const u8) []const u8 {
    var i: usize = 0;
    while (i + 1 < text.len and text[i] == '#') i += 2;
    if (i < text.len and (text[i] == '+' or text[i] == '-')) i += 1;
    return text[i..];
}

fn signedF64(sign: syntax.Sign, magnitude: f64) f64 {
    return if (sign == .negative) -magnitude else magnitude;
}

/// Gives `n` the sign, unless it is zero.
fn applySign(n: *Managed, sign: syntax.Sign) void {
    if (sign == .negative and !n.eqlZero()) n.negate();
}

/// The largest magnitude an exponent is read as; a larger one is read as this.
/// Why: 指数部の桁数に上限は無い(`1e99999999999999999999`)。読んだ値が `i64` からあふれ
/// ないよう、ここで頭打ちにする。この大きさの指数は、どのヒープの上限にも収まらない。
const max_exponent: i64 = 1 << 40;

fn parseExponent(text: []const u8) i64 {
    var i: usize = 0;
    var negative = false;
    if (i < text.len and (text[i] == '+' or text[i] == '-')) {
        negative = text[i] == '-';
        i += 1;
    }
    var value: i64 = 0;
    for (text[i..]) |c| value = @min(value *| 10 +| (c - '0'), max_exponent);
    return if (negative) -value else value;
}

/// The digit `index` places from the start of the whole part, over the whole part and the
/// fraction part taken as one run of digits.
fn digitAt(whole: []const u8, fraction: []const u8, index: usize) u8 {
    return if (index < whole.len) whole[index] else fraction[index - whole.len];
}

/// The exact value of a decimal that `#e` is on: the digits, times a power of ten.
fn parseExactDecimal(h: *Heap, gpa: std.mem.Allocator, d: anytype) Error!?Value {
    // 桁は整数部と小数部を続けて数える。先頭の0を飛ばして有効桁の数を決め、見積りを通って
    // から、有効桁だけを写す(桁数に比例する確保も、見積りの前には行わない)。
    const total = d.whole.len + d.fraction.len;
    var start: usize = 0;
    while (start < total and digitAt(d.whole, d.fraction, start) == '0') start += 1;
    // 0 は、どんな指数でも 0 である。
    if (start == total) return .fromFixnum(0);
    const exponent10 = parseExponent(d.exponent) - @as(i64, @intCast(d.fraction.len));
    const power_limbs = bigint.limbsForPow(ten, @abs(exponent10)) orelse return null;
    if (!fitsInHeap(h, bigint.limbsForDigits(total - start, 10) +| power_limbs)) return null;
    const significant = try gpa.alloc(u8, total - start);
    defer gpa.free(significant);
    for (significant, start..) |*c, i| c.* = digitAt(d.whole, d.fraction, i);
    var m = try bigint.parseDigits(gpa, significant, 10);
    defer m.deinit();
    var power = try bigint.pow(gpa, ten, @abs(exponent10));
    defer power.deinit();
    if (exponent10 >= 0) {
        var product = try bigint.mul(gpa, m.toConst(), power.toConst());
        defer product.deinit();
        applySign(&product, d.sign);
        return try fromInteger(h, product.toConst());
    }
    applySign(&m, d.sign);
    return try makeRatio(h, gpa, m.toConst(), power.toConst());
}

/// Writes the number `v` in the external representation of `radix`, which is
/// 2, 8, 10 or 16 (R7RS 6.2.7).
/// `scratch` は作業領域で、戻る前に取ったものを返す。
///
/// 基数10以外の有限の浮動小数点数は、正確な有理数に直して `#i` を前に付ける(`#i1/10`)。
/// 無限大と NaN は、基数によらず `+inf.0` `-inf.0` `+nan.0` と書く。それらを基数10以外で
/// 書くのを誤りにするのは、`number->string`(スライス 4g)の仕事である。
/// 複素数は、スライス 4e-2 までは仮の表記 `#<number>` で書く。
pub fn write(out: *std.Io.Writer, scratch: std.mem.Allocator, v: Value, radix: u8) (std.Io.Writer.Error || error{OutOfMemory})!void {
    std.debug.assert(isNumber(v));
    std.debug.assert(radix == 2 or radix == 8 or radix == 10 or radix == 16);
    switch (v.kind()) {
        .fixnum, .bignum => try writeInteger(out, scratch, v, radix),
        .ratnum => {
            const ratnum = v.asRatnum().?;
            try writeInteger(out, scratch, ratnum.numerator, radix);
            try out.writeByte('/');
            try writeInteger(out, scratch, ratnum.denominator, radix);
        },
        .flonum => try writeFlonum(out, scratch, v.asFlonum().?, radix),
        else => try out.writeAll("#<number>"),
    }
}

fn writeInteger(out: *std.Io.Writer, scratch: std.mem.Allocator, v: Value, radix: u8) (std.Io.Writer.Error || error{OutOfMemory})!void {
    if (v.asFixnum()) |n| return out.printInt(n, radix, .lower, .{});
    const text = try bigint.toString(scratch, v.asBignum().?.toConst(), radix);
    defer scratch.free(text);
    try out.writeAll(text);
}

fn writeFlonum(out: *std.Io.Writer, scratch: std.mem.Allocator, x: f64, radix: u8) (std.Io.Writer.Error || error{OutOfMemory})!void {
    if (radix == 10 or !std.math.isFinite(x)) return flonum.write(out, x);
    var value = try exact.fromF64(scratch, x);
    defer value.deinit();
    try out.writeAll("#i");
    if (std.math.signbit(x)) try out.writeByte('-');
    const numerator = try bigint.toString(scratch, value.numerator.toConst(), radix);
    defer scratch.free(numerator);
    try out.writeAll(numerator);
    if (value.denominator.toConst().orderAgainstScalar(1) != .eq) {
        const denominator = try bigint.toString(scratch, value.denominator.toConst(), radix);
        defer scratch.free(denominator);
        try out.writeByte('/');
        try out.writeAll(denominator);
    }
}

test {
    std.testing.refAllDecls(@This());
    // Why: 純粋な層のテストを単体テストの集合に載せる。`syntax.zig` は `parse` が呼ぶので
    // 要らないが、`exact.zig` と `flonum.zig` の参照は、ここと src/sucheme.zig の両方にある。
    _ = @import("syntax.zig");
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

const testing = std.testing;

fn zeros(comptime n: usize) [n]u8 {
    return @splat('0');
}

const zeros_100000 = zeros(100000);

/// Reads `text` and writes the result in radix 10, or returns null if it is not a number.
fn readWrite(h: *Heap, text: []const u8, default_radix: u8, out_radix: u8) !?[]u8 {
    const v = (try parse(h, text, default_radix)) orelse return null;
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    errdefer aw.deinit();
    try write(&aw.writer, testing.allocator, v, out_radix);
    return try aw.toOwnedSlice();
}

fn expectReads(h: *Heap, expected: ?[]const u8, text: []const u8) !void {
    const got = try readWrite(h, text, 10, 10);
    defer if (got) |g| testing.allocator.free(g);
    if (expected) |e| {
        try testing.expect(got != null);
        try testing.expectEqualStrings(e, got.?);
    } else {
        try testing.expect(got == null);
    }
}

test "parse reads the integers of the four radixes, with prefixes in either case" {
    var h: Heap = .init(testing.allocator, .{});
    defer h.deinit();
    try expectReads(&h, "0", "0");
    try expectReads(&h, "0", "-0");
    try expectReads(&h, "42", "+42");
    try expectReads(&h, "-17", "-17");
    try expectReads(&h, "255", "#xff");
    try expectReads(&h, "255", "#XFF");
    try expectReads(&h, "-255", "#x-Ff");
    try expectReads(&h, "5", "#b101");
    try expectReads(&h, "15", "#o17");
    try expectReads(&h, "10", "#d10");
    try expectReads(&h, "10", "#e10");
    try expectReads(&h, "10.0", "#i10");
    try expectReads(&h, "255", "#e#xff");
    try expectReads(&h, "255.0", "#x#iff");
    // 既定の基数は、接頭辞が無いときだけ効く。
    const got = (try readWrite(&h, "ff", 16, 10)).?;
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("255", got);
    const prefixed = (try readWrite(&h, "#o177", 2, 10)).?;
    defer testing.allocator.free(prefixed);
    try testing.expectEqualStrings("127", prefixed);
}

test "parse makes a fixnum for every integer that fits an i64, and a bignum for the rest" {
    var h: Heap = .init(testing.allocator, .{});
    defer h.deinit();
    for ([_]struct { text: []const u8, kind: value_mod.Kind }{
        .{ .text = "9223372036854775807", .kind = .fixnum },
        .{ .text = "9223372036854775808", .kind = .bignum },
        .{ .text = "-9223372036854775808", .kind = .fixnum },
        .{ .text = "-9223372036854775809", .kind = .bignum },
        .{ .text = "00000000000000000000000000000000000000000012", .kind = .fixnum },
        .{ .text = "123456789012345678901234567890", .kind = .bignum },
        .{ .text = "#e1e30", .kind = .bignum },
        .{ .text = "#e9223372036854775808e0", .kind = .bignum },
    }) |case| {
        const v = (try parse(&h, case.text, 10)).?;
        try testing.expectEqual(case.kind, v.kind());
        if (v.asBignum()) |big| {
            // 上位の限界値は0でなく、符号は値と合っている。
            try testing.expect(big.limbs[big.limbs.len - 1] != 0);
            try testing.expectEqual(case.text[0] != '-', big.positive);
        }
    }
    try expectReads(&h, "123456789012345678901234567890", "123456789012345678901234567890");
    try expectReads(&h, "-123456789012345678901234567890", "-123456789012345678901234567890");
    try expectReads(&h, "1208925819614629174706175", "#xFFFFFFFFFFFFFFFFFFFF");
    try expectReads(&h, "1000000000000000000000000000000", "#e1e30");
}

test "parse reduces a ratio to lowest terms with a positive denominator, and makes an integer of x/1" {
    var h: Heap = .init(testing.allocator, .{});
    defer h.deinit();
    try expectReads(&h, "1/2", "1/2");
    try expectReads(&h, "-3/2", "-6/4");
    try expectReads(&h, "3/2", "+6/4");
    try expectReads(&h, "2", "4/2");
    try expectReads(&h, "0", "0/5");
    try expectReads(&h, "0", "-0/5");
    try expectReads(&h, "1/3", "#x2/6");
    try expectReads(&h, "1/2", "#b1/10");
    try expectReads(&h, "12345678901234567890/7", "12345678901234567890/7");
    try expectReads(&h, "1/12345678901234567890123", "1000000/12345678901234567890123000000");
    const r = (try parse(&h, "1/2", 10)).?;
    try testing.expectEqual(value_mod.Kind.ratnum, r.kind());
    // 分母が0は、数でない(誤りにしない)。
    try expectReads(&h, null, "1/0");
    try expectReads(&h, null, "-1/0");
    try expectReads(&h, null, "#i1/0");
    try expectReads(&h, null, "0/0");
}

test "parse reads a decimal as a flonum, and as an exact ratio after #e" {
    var h: Heap = .init(testing.allocator, .{});
    defer h.deinit();
    try expectReads(&h, "1.5", "1.5");
    try expectReads(&h, "1.0", "1.");
    try expectReads(&h, "0.5", ".5");
    try expectReads(&h, "100.0", "1e2");
    try expectReads(&h, "100.0", "1E2");
    try expectReads(&h, "0.0015", "1.5e-3");
    try expectReads(&h, "-0.0", "-0.0");
    try expectReads(&h, "-0.0", "#i-0");
    try expectReads(&h, "0.1", "#i0.1");
    try expectReads(&h, "+inf.0", "1e400");
    try expectReads(&h, "-inf.0", "-1e400");
    try expectReads(&h, "0.0", "1e-400");
    try expectReads(&h, "3/2", "#e1.5");
    try expectReads(&h, "1/2", "#e.5");
    try expectReads(&h, "1", "#e1.");
    try expectReads(&h, "1000", "#e1e3");
    try expectReads(&h, "3/2000", "#e1.5e-3");
    try expectReads(&h, "-3/2", "#e-1.5");
    try expectReads(&h, "1/10", "#e0.1");
    try expectReads(&h, "0", "#e-0.0");
    try expectReads(&h, "0", "#e0e999999999");
    try expectReads(&h, "0", "#e0.000e-999999999");
    try expectReads(&h, "100", "#e1.00e2");
    try expectReads(&h, "1", "#e1000e-3");
    // 符号は、整数にも分数にも付く。
    try expectReads(&h, "-1000", "#e-1e3");
    try expectReads(&h, "-1500", "#e-1.5e3");
    try expectReads(&h, "-12", "#e-12.");
    try expectReads(&h, "-1/8", "#e-0.125");
    try expectReads(&h, "1000", "#e+1e3");
}

test "parse reads a ratio or an integer as a flonum after #i, with the nearest value" {
    var h: Heap = .init(testing.allocator, .{});
    defer h.deinit();
    try expectReads(&h, "0.3333333333333333", "#i1/3");
    try expectReads(&h, "-0.3333333333333333", "#i-1/3");
    try expectReads(&h, "0.5", "#x#i1/2");
    try expectReads(&h, "9007199254740992.0", "#i9007199254740993");
    try expectReads(&h, "1.2345678901234568e29", "#i123456789012345678901234567890");
    try expectReads(&h, "+inf.0", "#i1000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000");
}

test "parse reads the infinities and NaN, and refuses them after #e" {
    var h: Heap = .init(testing.allocator, .{});
    defer h.deinit();
    try expectReads(&h, "+inf.0", "+inf.0");
    try expectReads(&h, "-inf.0", "-inf.0");
    try expectReads(&h, "+nan.0", "+nan.0");
    try expectReads(&h, "+nan.0", "-nan.0");
    try expectReads(&h, "+inf.0", "#i+inf.0");
    try expectReads(&h, "+inf.0", "+INF.0");
    try expectReads(&h, null, "#e+inf.0");
    try expectReads(&h, null, "#e-inf.0");
    try expectReads(&h, null, "#e+nan.0");
}

test "parse says no to what is not a number, and to a complex number until slice 4e-2" {
    var h: Heap = .init(testing.allocator, .{});
    defer h.deinit();
    for ([_][]const u8{ "", "abc", "+", "-", "...", "1/2/3", "--1", "1e", "e1", "inf", "nan", "1_000", "0x10", "#", "#x", "#xg", "#e#e1", "#b2", "1.5/2", "#x1.5" }) |text| {
        try expectReads(&h, null, text);
    }
    for ([_][]const u8{ "1+2i", "+i", "-i", "1@2", "+inf.0i", "1.5-2.5i" }) |text| {
        try expectReads(&h, null, text);
    }
}

test "parse says no to an exact number too large for the heap, before it allocates" {
    var h: Heap = .init(testing.allocator, .{ .limit = 64 * 1024 });
    defer h.deinit();
    try expectReads(&h, null, "#e1e999999999");
    try expectReads(&h, null, "#e1e99999999999999999999");
    try expectReads(&h, null, "#e1e-999999999");
    try expectReads(&h, null, "#e1.5e1000000");
    try expectReads(&h, null, "#e0.0001e-1000000");
    // 桁数が大きい整数も同じ。
    var digits: [100000]u8 = undefined;
    @memset(&digits, '9');
    try expectReads(&h, null, &digits);
    // 分数は、分子と分母の合計で見積もる。
    const big_numerator = try std.fmt.allocPrint(testing.allocator, "{s}/1", .{&digits});
    defer testing.allocator.free(big_numerator);
    try expectReads(&h, null, big_numerator);
    const big_denominator = try std.fmt.allocPrint(testing.allocator, "1/{s}", .{&digits});
    defer testing.allocator.free(big_denominator);
    try expectReads(&h, null, big_denominator);
    try testing.expectEqual(0, h.external);
    try testing.expectEqual(0, h.accounted);
    try testing.expect(!h.external_enforced);
    // 桁数が大きい `#e` の小数も、綴りを写す前に見積もって、null になる(整数と同じ)。
    const big_decimal = try std.fmt.allocPrint(testing.allocator, "#e{s}.5", .{&digits});
    defer testing.allocator.free(big_decimal);
    try expectReads(&h, null, big_decimal);
    try testing.expectEqual(0, h.external);
    // 桁は先頭の0を数えない。0が大きいだけの綴りは、小さい数として読める。
    const zeros_text = try std.fmt.allocPrint(testing.allocator, "#e0.{s}1e{d}", .{ &zeros_100000, 100000 });
    defer testing.allocator.free(zeros_text);
    try expectReads(&h, "1/10", zeros_text);
    // 指数部が大きすぎても、整数があふれない。
    try expectReads(&h, null, "#e1.55e-99999999999999999999");
    try expectReads(&h, null, "#e-1.55e99999999999999999999");
    // 収まる大きさは読める。
    const expected = "1" ++ zeros(300);
    try expectReads(&h, expected, "#e1e300");
    try testing.expectEqual(0, h.external);
}

test "parse compares the estimate with the room that is left, not with the limit" {
    var h: Heap = .init(testing.allocator, .{ .limit = 64 * 1024 });
    defer h.deinit();
    try expectReads(&h, "1" ++ zeros(3000), "#e1e3000");
    var filler: [55000]u8 = undefined;
    @memset(&filler, 'x');
    _ = try h.createString(&filler);
    try expectReads(&h, null, "#e1e3000");
    try expectReads(&h, "12", "12");
}

/// Reads a number of each kind at `digits` digits, at limits from none up to well past what
/// the estimate asks, and checks that no limit makes the reading fail: a limit lets the number
/// through or it does not, and from the least limit that lets it through every limit does.
fn expectEstimateHolds(digits: usize, steps: usize) !void {
    var prng: std.Random.DefaultPrng = .init(0x4e5);
    const random = prng.random();
    const a = try testing.allocator.alloc(u8, digits);
    defer testing.allocator.free(a);
    const b = try testing.allocator.alloc(u8, digits);
    defer testing.allocator.free(b);
    for (a) |*c| c.* = '1' + random.uintLessThan(u8, 9);
    for (b) |*c| c.* = '1' + random.uintLessThan(u8, 9);
    const texts = [_][]const u8{
        try std.fmt.allocPrint(testing.allocator, "{s}", .{a}),
        try std.fmt.allocPrint(testing.allocator, "#i{s}", .{a}),
        try std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ a, b }),
        try std.fmt.allocPrint(testing.allocator, "#i{s}/{s}", .{ a, b }),
        try std.fmt.allocPrint(testing.allocator, "#e1e{d}", .{digits * 4}),
        try std.fmt.allocPrint(testing.allocator, "#e1e-{d}", .{digits * 4}),
        try std.fmt.allocPrint(testing.allocator, "#e{s}.{s}e-{d}", .{ a, b, digits }),
    };
    defer for (texts) |t| testing.allocator.free(t);
    for (texts) |text| {
        var read = false;
        var limit: usize = 0;
        const top = digits * 70 + 8192;
        while (limit <= top) : (limit += top / steps + 1) {
            var h: Heap = .init(testing.allocator, .{ .limit = limit });
            defer h.deinit();
            const result = try parse(&h, text, 10);
            if (result != null) read = true else try testing.expect(!read);
        }
        try testing.expect(read);
    }
}

test "once the estimate lets a number through, the work of reading it does not run out" {
    try expectEstimateHolds(3, 30);
    try expectEstimateHolds(150, 30);
    try expectEstimateHolds(500, 12);
}

test "once the estimate lets a number through, the work of reading it does not run out at a large scale" {
    try tier.slow();
    try expectEstimateHolds(2000, 40);
    try expectEstimateHolds(20000, 60);
}

test "parse leaves the count of work as it found it, and gives OutOfMemory when the backing refuses" {
    var h: Heap = .init(testing.allocator, .{ .limit = 1 << 20 });
    defer h.deinit();
    var filler: [100]u8 = undefined;
    @memset(&filler, '7');
    _ = try h.createString(&filler);
    const before = h.held();
    const v = (try parse(&h, "123456789012345678901234567890", 10)).?;
    try testing.expectEqual(value_mod.Kind.bignum, v.kind());
    try testing.expect(h.held() > before);
    try testing.expectEqual(0, h.external);
    try testing.expect(!h.external_enforced);
    // 下の割り当て器が断れば、ヒープの上限の誤りでなく OutOfMemory である。
    var failing: std.testing.FailingAllocator = .init(testing.allocator, .{ .fail_index = 0 });
    var h2: Heap = .init(failing.allocator(), .{});
    defer h2.deinit();
    try testing.expectError(error.OutOfMemory, parse(&h2, "123456789012345678901234567890", 10));
    try testing.expectEqual(0, h2.external);
    try testing.expect(!h2.external_enforced);
}

test "parse gives a heap limit error when the work area is refused, and gives the count back" {
    var h: Heap = .init(testing.allocator, .{ .limit = 1 << 20 });
    defer h.deinit();
    // 外側の作業が上限のすぐ手前まで数えているところへ、読む。作業領域の確保が断られる。
    h.external = h.options.limit - 8;
    try testing.expectError(error.HeapLimit, parse(&h, "123456789012345678901234567890", 10));
    try testing.expect(h.external_refused);
    try testing.expectEqual(h.options.limit - 8, h.external);
    try testing.expect(!h.external_enforced);
    // 作業領域は通り、結果のセルが断られる場合も、同じ誤りで、数えた分は戻る。
    h.external = h.options.limit - 64;
    try testing.expectError(error.HeapLimit, parse(&h, "123456789012345678901234567890", 10));
    try testing.expectEqual(h.options.limit - 64, h.external);
    try testing.expectEqual(0, h.accounted);
    // 次の読み取りは、断りの印を下ろしてから始める。
    h.external = 0;
    try testing.expect((try parse(&h, "12", 10)) != null);
    try testing.expect(!h.external_refused);
}

test "parse with any limit gives a number, no, or a heap limit error, and leaves nothing counted" {
    const texts = [_][]const u8{ "123456789012345678901234567890", "12345678901234567890/7", "#e1.5e300", "#e1e-300", "#i1/3", "1.5", "#xFFFFFFFFFFFFFFFFFFFFFFFF" };
    var limit: usize = 0;
    while (limit <= 6000) : (limit += 53) {
        var h: Heap = .init(testing.allocator, .{ .limit = limit });
        defer h.deinit();
        for (texts) |text| {
            if (parse(&h, text, 10)) |_| {} else |e| try testing.expectEqual(error.HeapLimit, e);
            try testing.expectEqual(0, h.external);
            try testing.expect(!h.external_enforced);
        }
    }
}

test "makeRatio puts the sign on the numerator, reduces, and makes an integer of a unit denominator" {
    var h: Heap = .init(testing.allocator, .{});
    defer h.deinit();
    for ([_]struct { n: i64, d: i64, expected: []const u8 }{
        .{ .n = 1, .d = 2, .expected = "1/2" },
        .{ .n = 1, .d = -2, .expected = "-1/2" },
        .{ .n = -1, .d = -2, .expected = "1/2" },
        .{ .n = -6, .d = 4, .expected = "-3/2" },
        .{ .n = 6, .d = -4, .expected = "-3/2" },
        .{ .n = 0, .d = -5, .expected = "0" },
        .{ .n = 4, .d = -2, .expected = "-2" },
        .{ .n = 7, .d = 1, .expected = "7" },
        .{ .n = std.math.minInt(i64), .d = -1, .expected = "9223372036854775808" },
    }) |case| {
        var n = try Managed.initSet(testing.allocator, case.n);
        defer n.deinit();
        var d = try Managed.initSet(testing.allocator, case.d);
        defer d.deinit();
        const v = try makeRatio(&h, testing.allocator, n.toConst(), d.toConst());
        var aw: std.Io.Writer.Allocating = .init(testing.allocator);
        defer aw.deinit();
        try write(&aw.writer, testing.allocator, v, 10);
        try testing.expectEqualStrings(case.expected, aw.written());
        // 分母は、正の整数の bignum か fixnum で、1 ではない。
        if (v.asRatnum()) |r| {
            try testing.expect(r.denominator.kind() == .fixnum or r.denominator.kind() == .bignum);
            try testing.expect(r.denominator.asFixnum() != 1);
        }
    }
}

test "write writes a fixnum or a bignum in the radix, and a ratnum as two integers" {
    var h: Heap = .init(testing.allocator, .{});
    defer h.deinit();
    for ([_]struct { text: []const u8, radix: u8, expected: []const u8 }{
        .{ .text = "-255", .radix = 10, .expected = "-255" },
        .{ .text = "-255", .radix = 16, .expected = "-ff" },
        .{ .text = "-255", .radix = 8, .expected = "-377" },
        .{ .text = "-255", .radix = 2, .expected = "-11111111" },
        .{ .text = "18446744073709551616", .radix = 16, .expected = "10000000000000000" },
        .{ .text = "18446744073709551616", .radix = 8, .expected = "2000000000000000000000" },
        .{ .text = "-18446744073709551616", .radix = 2, .expected = "-1" ++ zeros(64) },
        .{ .text = "1/2", .radix = 2, .expected = "1/10" },
        .{ .text = "-255/16", .radix = 16, .expected = "-ff/10" },
        .{ .text = "18446744073709551617/3", .radix = 16, .expected = "10000000000000001/3" },
    }) |case| {
        const got = (try readWrite(&h, case.text, 10, case.radix)).?;
        defer testing.allocator.free(got);
        try testing.expectEqualStrings(case.expected, got);
    }
}

test "write writes a flonum in radix 10 with a point, and in the other radixes as an exact ratio after #i" {
    var h: Heap = .init(testing.allocator, .{});
    defer h.deinit();
    for ([_]struct { text: []const u8, radix: u8, expected: []const u8 }{
        .{ .text = "0.5", .radix = 10, .expected = "0.5" },
        .{ .text = "0.5", .radix = 2, .expected = "#i1/10" },
        .{ .text = "-0.5", .radix = 2, .expected = "#i-1/10" },
        .{ .text = "0.5", .radix = 8, .expected = "#i1/2" },
        .{ .text = "0.5", .radix = 16, .expected = "#i1/2" },
        .{ .text = "4.0", .radix = 2, .expected = "#i100" },
        .{ .text = "255.0", .radix = 16, .expected = "#iff" },
        .{ .text = "0.0", .radix = 8, .expected = "#i0" },
        .{ .text = "-0.0", .radix = 16, .expected = "#i-0" },
        .{ .text = "0.125", .radix = 2, .expected = "#i1/1000" },
        .{ .text = "+inf.0", .radix = 2, .expected = "+inf.0" },
        .{ .text = "-inf.0", .radix = 16, .expected = "-inf.0" },
        .{ .text = "+nan.0", .radix = 8, .expected = "+nan.0" },
    }) |case| {
        const got = (try readWrite(&h, case.text, 10, case.radix)).?;
        defer testing.allocator.free(got);
        try testing.expectEqualStrings(case.expected, got);
    }
}

/// Reads `text` in `radix`, writes the number in `radix`, reads that again in `radix`, and
/// checks that the two numbers write the same in radix 10.
fn expectRoundTrip(h: *Heap, text: []const u8, radix: u8) !void {
    const first = (try parse(h, text, 10)).?;
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try write(&aw.writer, testing.allocator, first, radix);
    const second = (try parse(h, aw.written(), radix)) orelse return error.NotReadBack;
    var a: std.Io.Writer.Allocating = .init(testing.allocator);
    defer a.deinit();
    var b: std.Io.Writer.Allocating = .init(testing.allocator);
    defer b.deinit();
    try write(&a.writer, testing.allocator, first, 10);
    try write(&b.writer, testing.allocator, second, 10);
    try testing.expectEqualStrings(a.written(), b.written());
}

test "write then parse gives the same number in every radix, for the boundary values" {
    var h: Heap = .init(testing.allocator, .{});
    defer h.deinit();
    for ([_][]const u8{ "0", "1", "-1", "255", "9223372036854775807", "-9223372036854775808", "9223372036854775808", "123456789012345678901234567890", "1/3", "-22/7", "123456789012345678901234567890/7", "0.1", "-0.1", "0.5", "100.0", "1e21", "1e-7", "-0.0", "5e-324", "1.7976931348623157e308", "2.2250738585072014e-308", "4.35", "+inf.0", "-inf.0", "#e1.5", "#i1/3" }) |text| {
        for ([_]u8{ 2, 8, 10, 16 }) |radix| {
            // 無限大は基数10以外で書けない約束だが、`write` は基数によらず同じ綴りを書く。
            try expectRoundTrip(&h, text, radix);
        }
    }
}

test "write then parse gives the same number for random integers, ratios and flonums" {
    var h: Heap = .init(testing.allocator, .{});
    defer h.deinit();
    var prng: std.Random.DefaultPrng = .init(0x4e3);
    const random = prng.random();
    var buf: [128]u8 = undefined;
    for (0..2000) |_| {
        const radixes = [_]u8{ 2, 8, 10, 16 };
        const radix = radixes[random.uintLessThan(usize, 4)];
        const n = random.int(i64);
        const d = random.intRangeAtMost(i64, 1, std.math.maxInt(i64));
        try expectRoundTrip(&h, try std.fmt.bufPrint(&buf, "{d}", .{n}), radix);
        try expectRoundTrip(&h, try std.fmt.bufPrint(&buf, "{d}/{d}", .{ n, d }), radix);
        const x: f64 = @bitCast(random.int(u64));
        if (!std.math.isFinite(x)) continue;
        var aw: std.Io.Writer.Allocating = .init(testing.allocator);
        defer aw.deinit();
        try flonum.write(&aw.writer, x);
        try expectRoundTrip(&h, aw.written(), radix);
    }
}

test "write then parse gives the same number for random integers, ratios and flonums at a large scale" {
    try tier.slow();
    var h: Heap = .init(testing.allocator, .{});
    defer h.deinit();
    var prng: std.Random.DefaultPrng = .init(0x4e4);
    const random = prng.random();
    var buf: [128]u8 = undefined;
    for (0..200_000) |i| {
        // Why: `testing.allocator` は確保ごとに別のメモリ領域(ページ)を割り当てる。ヒープに
        // 残る数のセルが、プロセスの領域の数の上限(`vm.max_map_count`)に達すると、
        // `munmap` が失敗して `unreachable` に当たり、約7万回目の反復で落ちる(実装の
        // 不具合ではない)。ヒープを定期的に作り直して、残るセルの数を抑える。
        if (i % 5000 == 0) {
            h.deinit();
            h = .init(testing.allocator, .{});
        }
        const radixes = [_]u8{ 2, 8, 10, 16 };
        const radix = radixes[random.uintLessThan(usize, 4)];
        const n = random.int(i64);
        const d = random.intRangeAtMost(i64, 1, std.math.maxInt(i64));
        try expectRoundTrip(&h, try std.fmt.bufPrint(&buf, "{d}/{d}", .{ n, d }), radix);
        const x: f64 = @bitCast(random.int(u64));
        if (!std.math.isFinite(x)) continue;
        var aw: std.Io.Writer.Allocating = .init(testing.allocator);
        defer aw.deinit();
        try flonum.write(&aw.writer, x);
        try expectRoundTrip(&h, aw.written(), radix);
    }
}
