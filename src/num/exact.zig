//! Conversions between exact rationals and `f64`
//! (docs/plans/0018-phase4-numeric-tower-unicode.md, slice 4e-1).
//!
//! ヒープにも `Value` にも触れない純粋な層で、作業領域は呼び出し側が渡した割り当て器から
//! 取り、返る前に返す。`#i1/3` の読み込み、`inexact`、基数10以外の浮動小数点数の書き出し
//! (`#i1/10`)が使う。

const std = @import("std");
const bigint = @import("bigint.zig");

const Allocator = std.mem.Allocator;
const Const = bigint.Const;
const Managed = bigint.Managed;
pub const Error = bigint.Error;

/// The `f64` nearest to `numerator / denominator`, and the even one of two that are equally near.
///
/// `denominator` は正である。大きさが `f64` の範囲を超えれば無限大に、非正規化数の半分より
/// 小さければ0になる(誤りにしない)。結果の符号は `numerator` の符号で、0 は +0.0 を返す。
/// 作業領域は、浮動小数点数の範囲が決める大きさで、入力の大きさの 2 倍に収まる。
pub fn ratioToF64(gpa: Allocator, numerator: Const, denominator: Const) Error!f64 {
    std.debug.assert(denominator.positive and !denominator.eqlZero());
    if (numerator.eqlZero()) return 0.0;
    const negative = !numerator.positive;
    const la: i64 = @intCast(numerator.bitCountAbs());
    const lb: i64 = @intCast(denominator.bitCountAbs());
    // 値は 2^(la-lb-1) より大きく 2^(la-lb+1) より小さい。範囲の外は、割る前に決まる。
    if (la - lb > 1025) return signed(std.math.inf(f64), negative);
    if (la - lb < -1075) return signed(0.0, negative);

    // 商が [2^54, 2^56) に入るよう、k ビットだけ分子(k が負なら分母)を左へ動かす。
    const k: i64 = 55 - (la - lb);
    var a = try Managed.init(gpa);
    defer a.deinit();
    var b = try Managed.init(gpa);
    defer b.deinit();
    var magnitude = try Managed.init(gpa);
    defer magnitude.deinit();
    try magnitude.copy(numerator);
    magnitude.setSign(true);
    var other = try Managed.init(gpa);
    defer other.deinit();
    try other.copy(denominator);
    if (k >= 0) {
        try a.shiftLeft(&magnitude, @intCast(k));
        try b.copy(other.toConst());
    } else {
        try a.copy(magnitude.toConst());
        try b.shiftLeft(&other, @intCast(-k));
    }
    var division = try bigint.divide(gpa, a.toConst(), b.toConst(), .truncate);
    defer division.q.deinit();
    defer division.r.deinit();
    const q: u64 = division.q.toInt(u64) catch unreachable;
    const sticky = !division.r.eqlZero();

    // q のビット数 n(55 か 56)と、先頭のビットの2を底とする指数 e から、残す桁数 p を決める。
    const n: i64 = 64 - @clz(q);
    const e = n - 1 - k;
    const p: i64 = if (e >= -1022) 53 else e + 1075;
    const shift = n - p;
    var m: u64 = 0;
    if (shift < 64) {
        const s: u6 = @intCast(shift);
        m = q >> s;
        const rest = q & ((@as(u64, 1) << s) - 1);
        const half = @as(u64, 1) << (s - 1);
        if (rest > half or (rest == half and (sticky or m & 1 == 1))) m += 1;
    }
    // m は p ビット以下(桁上がりで 2^p ちょうどになりうる)で、m × 2^(shift-k) が結果である。
    const exponent: i32 = @intCast(shift - k);
    return signed(std.math.ldexp(@as(f64, @floatFromInt(m)), exponent), negative);
}

fn signed(x: f64, negative: bool) f64 {
    return if (negative) -x else x;
}

/// A non-negative rational in lowest terms, with a positive denominator.
pub const Exact = struct {
    numerator: Managed,
    denominator: Managed,

    pub fn deinit(self: *Exact) void {
        self.numerator.deinit();
        self.denominator.deinit();
    }
};

/// The magnitude of `x` as an exact rational in lowest terms.
///
/// `x` は有限である。符号は返さない(呼び出し側が `std.math.signbit` で見る)。-0.0 と +0.0 は
/// どちらも 0/1 になる。
pub fn fromF64(gpa: Allocator, x: f64) Error!Exact {
    std.debug.assert(std.math.isFinite(x));
    const bits: u64 = @bitCast(x);
    const biased: i32 = @intCast((bits >> 52) & 0x7ff);
    var m: u64 = bits & ((@as(u64, 1) << 52) - 1);
    var e: i32 = -1074;
    if (biased != 0) {
        m |= @as(u64, 1) << 52;
        e = biased - 1075;
    }
    var numerator = try Managed.initSet(gpa, 0);
    errdefer numerator.deinit();
    var denominator = try Managed.initSet(gpa, 1);
    errdefer denominator.deinit();
    if (m == 0) return .{ .numerator = numerator, .denominator = denominator };
    // 約分は、分母が2のべきなので、仮数の末尾の0ビットを落とすだけで済む。
    if (e < 0) {
        const drop: i32 = @min(@as(i32, @ctz(m)), -e);
        m >>= @intCast(drop);
        e += drop;
    }
    try numerator.set(m);
    if (e >= 0) {
        var shifted = try Managed.init(gpa);
        defer shifted.deinit();
        try shifted.shiftLeft(&numerator, @intCast(e));
        numerator.swap(&shifted);
    } else {
        var one = try Managed.initSet(gpa, 1);
        defer one.deinit();
        try denominator.shiftLeft(&one, @intCast(-e));
    }
    return .{ .numerator = numerator, .denominator = denominator };
}

test {
    std.testing.refAllDecls(@This());
}

const testing = std.testing;
const tgpa = testing.allocator;

fn ratio(n: i64, d: i64) !f64 {
    var nm = try Managed.initSet(tgpa, n);
    defer nm.deinit();
    var dm = try Managed.initSet(tgpa, d);
    defer dm.deinit();
    return ratioToF64(tgpa, nm.toConst(), dm.toConst());
}

fn bitsOf(x: f64) u64 {
    return @bitCast(x);
}

test "ratioToF64 gives the nearest f64 for simple ratios, with the sign of the numerator" {
    try testing.expectEqual(@as(f64, 0.5), try ratio(1, 2));
    try testing.expectEqual(@as(f64, -0.5), try ratio(-1, 2));
    try testing.expectEqual(@as(f64, 1.0 / 3.0), try ratio(1, 3));
    try testing.expectEqual(@as(f64, 100.0), try ratio(100, 1));
    try testing.expectEqual(@as(f64, 0.1), try ratio(1, 10));
    try testing.expectEqual(@as(u64, 0), bitsOf(try ratio(0, 5)));
    try testing.expectEqual(@as(f64, 2.5), try ratio(10, 4));
}

test "ratioToF64 rounds a tie to even, and a near-tie by the sticky remainder" {
    // 2^53 + 1 は偶数の 2^53 へ、2^53 + 3 は偶数の 2^53 + 4 へ。
    try testing.expectEqual(@as(f64, 9007199254740992.0), try ratio((1 << 53) + 1, 1));
    try testing.expectEqual(@as(f64, 9007199254740996.0), try ratio((1 << 53) + 3, 1));
    // 分母が2でも同じ。2^52 + 0.5 は偶数の 2^52 へ、2^52 + 1.5 は偶数の 2^52 + 2 へ。
    try testing.expectEqual(@as(f64, 4503599627370496.0), try ratio((1 << 53) + 1, 2));
    try testing.expectEqual(@as(f64, 4503599627370498.0), try ratio((1 << 53) + 3, 2));
    // ちょうど中間(2^53 + 1)より、わずかに大きければ、剰余が残るので切り上がる。
    try testing.expectEqual(@as(f64, 9007199254740994.0), try ratio(9007199254740993 * 1000 + 1, 1000));
    try testing.expectEqual(@as(f64, 9007199254740992.0), try ratio(9007199254740993 * 1000 - 1, 1000));
}

test "ratioToF64 reaches the subnormal numbers and the edges of the range" {
    var one = try Managed.initSet(tgpa, 1);
    defer one.deinit();
    var den = try Managed.init(tgpa);
    defer den.deinit();
    // 2^-1074 は最小の非正規化数。
    try den.shiftLeft(&one, 1074);
    try testing.expectEqual(@as(u64, 1), bitsOf(try ratioToF64(tgpa, one.toConst(), den.toConst())));
    // 2^-1075 はその半分で、偶数(0)へ。ちょうど中間より少し大きければ最小の非正規化数へ。
    var half = try Managed.init(tgpa);
    defer half.deinit();
    try half.shiftLeft(&one, 1075);
    try testing.expectEqual(@as(u64, 0), bitsOf(try ratioToF64(tgpa, one.toConst(), half.toConst())));
    var two = try Managed.initSet(tgpa, 3);
    defer two.deinit();
    var half3 = try Managed.init(tgpa);
    defer half3.deinit();
    try half3.shiftLeft(&one, 1076);
    try testing.expectEqual(@as(u64, 1), bitsOf(try ratioToF64(tgpa, two.toConst(), half3.toConst())));
    // 負の最小の非正規化数。
    var neg = try Managed.initSet(tgpa, -1);
    defer neg.deinit();
    try testing.expectEqual(@as(u64, 1 | (1 << 63)), bitsOf(try ratioToF64(tgpa, neg.toConst(), den.toConst())));
    // 2^1024 は無限大、2^1024 - 2^970 は最大値と2^1024の中間で偶数の無限大へ、それより小さければ最大値。
    var top = try Managed.init(tgpa);
    defer top.deinit();
    try top.shiftLeft(&one, 1024);
    try testing.expect(std.math.isPositiveInf(try ratioToF64(tgpa, top.toConst(), one.toConst())));
    var below = try Managed.init(tgpa);
    defer below.deinit();
    try below.shiftLeft(&one, 970);
    var max_plus_half_ulp_minus_one = try Managed.init(tgpa);
    defer max_plus_half_ulp_minus_one.deinit();
    try max_plus_half_ulp_minus_one.sub(&top, &below);
    try testing.expect(std.math.isPositiveInf(try ratioToF64(tgpa, max_plus_half_ulp_minus_one.toConst(), one.toConst())));
    var just_below = try Managed.initSet(tgpa, 1);
    defer just_below.deinit();
    try just_below.sub(&max_plus_half_ulp_minus_one, &just_below);
    try testing.expectEqual(std.math.floatMax(f64), try ratioToF64(tgpa, just_below.toConst(), one.toConst()));
    // 範囲のはるか外は、割らずに決まる。
    var huge = try Managed.init(tgpa);
    defer huge.deinit();
    try huge.shiftLeft(&one, 5000);
    try testing.expect(std.math.isPositiveInf(try ratioToF64(tgpa, huge.toConst(), one.toConst())));
    try testing.expectEqual(@as(u64, 0), bitsOf(try ratioToF64(tgpa, one.toConst(), huge.toConst())));
}

test "ratioToF64 agrees with the division of f64, which rounds correctly when both are exact" {
    var prng: std.Random.DefaultPrng = .init(0x4e1);
    const random = prng.random();
    for (0..20000) |_| {
        const a = random.int(u53) | 1;
        const b = random.int(u53) | 1;
        const expected = @as(f64, @floatFromInt(a)) / @as(f64, @floatFromInt(b));
        try testing.expectEqual(bitsOf(expected), bitsOf(try ratio(@intCast(a), @intCast(b))));
    }
    // 整数だけでも、i64 の変換は丸めが正しい。
    for (0..20000) |_| {
        const a = random.int(i64);
        const expected: f64 = @floatFromInt(a);
        try testing.expectEqual(bitsOf(expected), bitsOf(try ratio(a, 1)));
    }
}

test "ratioToF64 agrees with the reading of 1e<k> and 1e-<k> for powers of ten" {
    var ten = try Managed.initSet(tgpa, 10);
    defer ten.deinit();
    var one = try Managed.initSet(tgpa, 1);
    defer one.deinit();
    var buf: [16]u8 = undefined;
    var k: u64 = 0;
    while (k <= 400) : (k += 1) {
        var p = try bigint.pow(tgpa, ten.toConst(), k);
        defer p.deinit();
        const up = try std.fmt.parseFloat(f64, try std.fmt.bufPrint(&buf, "1e{d}", .{k}));
        try testing.expectEqual(bitsOf(up), bitsOf(try ratioToF64(tgpa, p.toConst(), one.toConst())));
        const down = try std.fmt.parseFloat(f64, try std.fmt.bufPrint(&buf, "1e-{d}", .{k}));
        try testing.expectEqual(bitsOf(down), bitsOf(try ratioToF64(tgpa, one.toConst(), p.toConst())));
    }
}

test "fromF64 gives the exact value in lowest terms, and ratioToF64 takes it back" {
    var x = try fromF64(tgpa, 0.5);
    defer x.deinit();
    try testing.expectEqual(@as(i64, 1), try x.numerator.toInt(i64));
    try testing.expectEqual(@as(i64, 2), try x.denominator.toInt(i64));
    var four = try fromF64(tgpa, 4.0);
    defer four.deinit();
    try testing.expectEqual(@as(i64, 4), try four.numerator.toInt(i64));
    try testing.expectEqual(@as(i64, 1), try four.denominator.toInt(i64));
    var zero = try fromF64(tgpa, -0.0);
    defer zero.deinit();
    try testing.expect(zero.numerator.eqlZero());
    try testing.expectEqual(@as(i64, 1), try zero.denominator.toInt(i64));
    var tenth = try fromF64(tgpa, 0.1);
    defer tenth.deinit();
    // 0.1 は 3602879701896397 / 2^55。
    try testing.expectEqual(@as(i64, 3602879701896397), try tenth.numerator.toInt(i64));
    try testing.expectEqual(@as(i64, 1) << 55, try tenth.denominator.toInt(i64));
}

test "fromF64 then ratioToF64 returns every finite f64 as it was" {
    var prng: std.Random.DefaultPrng = .init(0x4e2);
    const random = prng.random();
    var done: usize = 0;
    while (done < 20000) {
        const x: f64 = @bitCast(random.int(u64));
        if (!std.math.isFinite(x)) continue;
        var exact = try fromF64(tgpa, @abs(x));
        defer exact.deinit();
        const back = try ratioToF64(tgpa, exact.numerator.toConst(), exact.denominator.toConst());
        try testing.expectEqual(bitsOf(@abs(x)), bitsOf(back));
        done += 1;
    }
    for ([_]f64{ std.math.floatMax(f64), std.math.floatMin(f64), std.math.floatTrueMin(f64), 1.0, 0.0 }) |x| {
        var exact = try fromF64(tgpa, x);
        defer exact.deinit();
        try testing.expectEqual(bitsOf(x), bitsOf(try ratioToF64(tgpa, exact.numerator.toConst(), exact.denominator.toConst())));
    }
}
