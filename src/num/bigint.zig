//! A thin layer over `std.math.big.int` for the numeric tower's bignums
//! (docs/plans/0018-phase4-numeric-tower-unicode.md, slice 4c).
//!
//! 入力は `Const`、出力は呼び出し側が渡した割り当て器で確保した `Managed` である。
//! ヒープにも `Value` にも触れない純粋な層で、結果を `Value` に写すのは
//! `src/num/number.zig` の仕事になる。この層が std をそのまま使わずに包む理由は
//! 次の3つである。
//!
//! - std の `Managed` の演算は `*const Managed` を取り、`Const` を渡せない。
//! - 多桁の積など、零を負の符号で返しうる演算がある。この層の結果は、零を常に
//!   正にそろえる。
//! - 結果の大きさを確保の前に見積もる関数は std に無い。ヒープの上限に照らして
//!   から確保するために要る。

const std = @import("std");
const tier = @import("../tier.zig");

const Allocator = std.mem.Allocator;

pub const Limb = std.math.big.Limb;
pub const Const = std.math.big.int.Const;
pub const Managed = std.math.big.int.Managed;
pub const Error = Allocator.Error;

/// How a quotient is rounded (R7RS 6.2.6: `floor/` and `truncate/`).
pub const Rounding = enum { floor, truncate };

/// The quotient and remainder of `divide`.
pub const DivResult = struct { q: Managed, r: Managed };

const limb_bits = @bitSizeOf(Limb);

/// The number of limbs of the shorter factor above which the standard library multiplies by
/// Karatsuba's method (`llmulacc` in std/math/big/int.zig).
const karatsuba_threshold = 48;

/// The limbs the temporaries of the recursion may take beyond the sum of the factors' limbs: one
/// limb of rounding at each level of the recursion.
const karatsuba_slack = 64;

/// 長さ capacity の限界値列を持つ零を作る。
fn zeroed(gpa: Allocator, capacity: usize) Error!Managed {
    return Managed.initCapacity(gpa, capacity);
}

/// 演算の結果を r に書き戻す。
///
/// Why: 多桁の積などは、零を負の符号で返しうる。この層の結果は、零を常に正にそろえる。
fn finish(r: *Managed, m: std.math.big.int.Mutable) void {
    r.setMetadata(m.positive or m.eqlZero(), m.len);
}

/// Returns `a + b`.
pub fn add(gpa: Allocator, a: Const, b: Const) Error!Managed {
    var r = try zeroed(gpa, @max(a.limbs.len, b.limbs.len) + 1);
    errdefer r.deinit();
    var m = r.toMutable();
    m.add(a, b);
    finish(&r, m);
    return r;
}

/// Returns `a - b`.
pub fn sub(gpa: Allocator, a: Const, b: Const) Error!Managed {
    var r = try zeroed(gpa, @max(a.limbs.len, b.limbs.len) + 1);
    errdefer r.deinit();
    var m = r.toMutable();
    m.sub(a, b);
    finish(&r, m);
    return r;
}

/// Returns `a * b`.
///
/// Why: 標準ライブラリの乗算は、桁数が `karatsuba_threshold` を超えると Karatsuba 法で一時領域を
/// 確保するが、その確保が断られると、エラーにせず 2乗の学校式に黙って切り替える。ヒープの上限
/// が一時領域を断る場面では、結果の確保も断られるので、長い時間を使ったあとに失敗する
/// (上限の近くの 18万バイト級の平方で、成功なら約2秒のところ、断るまでに約15秒かかった。
/// 2026-10-23 の独立レビュー)。そこで、先頭の段の一時領域(2つの因数の桁数の和に収まる)を
/// 先に試し取りして、断られたら計算の前に `OutOfMemory` にする。
///
/// 保証するのは先頭の段の分だけである。因数の桁数が偏ると、再帰の入れ子の段の一時領域の
/// 合計が桁数の和を超える(2026-10-23 の独立レビューの測定では、10万桁と1万桁で、一時領域の
/// 最大が約74万桁で、和の約6.7倍)。入れ子の段が断られたら、その部分積だけが標準ライブラリの
/// 学校式に切り替わる。結果は正しく、測定した遅さは小さかった(3万桁と2万桁で、約417ミリ秒対
/// 約315ミリ秒)。釣り合った因数(2万桁どうし)では、一時領域は桁数の和に収まる。
pub fn mul(gpa: Allocator, a: Const, b: Const) Error!Managed {
    var r = try zeroed(gpa, a.limbs.len + b.limbs.len);
    errdefer r.deinit();
    if (@min(a.limbs.len, b.limbs.len) > karatsuba_threshold) {
        const probe = try gpa.alloc(Limb, a.limbs.len + b.limbs.len + karatsuba_slack);
        gpa.free(probe);
    }
    var m = r.toMutable();
    m.mulNoAlias(a, b, gpa);
    finish(&r, m);
    return r;
}

/// Returns the quotient and the remainder of `a / b`.
///
/// `b` は0でない。`.floor` の剰余は `b` と同じ符号、`.truncate` の剰余は `a` と
/// 同じ符号になる(R7RS 6.2.6 の `floor/` と `truncate/`)。
pub fn divide(gpa: Allocator, a: Const, b: Const, rounding: Rounding) Error!DivResult {
    std.debug.assert(!b.eqlZero());
    // std が示す上限である。商は a の限界値数、剰余は b の限界値数に収まる(floor で
    // 商を1つ戻しても、商の大きさは a を超えない)。
    var q = try zeroed(gpa, a.limbs.len);
    errdefer q.deinit();
    var r = try zeroed(gpa, b.limbs.len);
    errdefer r.deinit();
    const scratch = try gpa.alloc(Limb, std.math.big.int.calcDivLimbsBufferLen(a.limbs.len, b.limbs.len));
    defer gpa.free(scratch);
    var mq = q.toMutable();
    var mr = r.toMutable();
    switch (rounding) {
        .floor => mq.divFloor(&mr, a, b, scratch),
        .truncate => mq.divTrunc(&mr, a, b, scratch),
    }
    finish(&q, mq);
    finish(&r, mr);
    return .{ .q = q, .r = r };
}

/// Returns the greatest common divisor of `a` and `b`, never negative.
///
/// `gcd(0, 0)` は0である(R7RS 6.2.6)。
pub fn gcd(gpa: Allocator, a: Const, b: Const) Error!Managed {
    var r = try zeroed(gpa, @max(a.limbs.len, b.limbs.len));
    errdefer r.deinit();
    var scratch: std.array_list.Managed(Limb) = .init(gpa);
    defer scratch.deinit();
    var m = r.toMutable();
    try m.gcd(a, b, &scratch);
    finish(&r, m);
    return r;
}

/// Returns `base` raised to `exponent`.
///
/// 0、1、-1 の底は、どんな指数でも計算できる。それ以外の底は、`limbsForPow` が
/// null を返さない指数に限る(u32 に収まる指数)。
///
/// 確保は、結果用と作業用に、同じ大きさ(std の `calcPowLimbsBufferLen`)を取る。
/// 作業用は返る前に解放するが、ピークは結果の大きさ(`limbsForPow`)の約2倍になる。
/// 上限との照合に `limbsForPow` だけを使う呼び出し側(4d、4e)は、ピークの分を
/// 見込むこと。
pub fn pow(gpa: Allocator, base: Const, exponent: u64) Error!Managed {
    if (exponent == 0 or isUnit(base)) {
        // 0^0 = 1、0^n = 0、1^n = 1、(-1)^n = ±1。std の pow は指数を u32 で受け取る。
        const odd = exponent & 1 == 1;
        const v: i8 = if (exponent == 0) 1 else if (base.eqlZero()) 0 else if (!base.positive and odd) -1 else 1;
        return Managed.initSet(gpa, v);
    }
    std.debug.assert(limbsForPow(base, exponent) != null);
    const e: u32 = @intCast(exponent);
    const needed = std.math.big.int.calcPowLimbsBufferLen(base.bitCountAbs(), e);
    var r = try zeroed(gpa, @max(needed, base.limbs.len));
    errdefer r.deinit();
    const scratch = try gpa.alloc(Limb, needed);
    defer gpa.free(scratch);
    var m = r.toMutable();
    m.pow(base, e, scratch);
    finish(&r, m);
    return r;
}

/// Returns the integer square root of `a`: the largest `s` with `s * s <= a`.
///
/// `a` は負でない。確保は、結果用(`a` の限界値数の約半分)と、std が示す作業用で、
/// 作業用は返る前に解放する。
pub fn sqrt(gpa: Allocator, a: Const) Error!Managed {
    std.debug.assert(a.positive or a.eqlZero());
    if (a.eqlZero()) return Managed.initSet(gpa, 0);
    var r = try zeroed(gpa, (a.limbs.len - 1) / 2 + 1);
    errdefer r.deinit();
    const scratch = try gpa.alloc(Limb, std.math.big.int.calcSqrtLimbsBufferLen(a.bitCountAbs()));
    defer gpa.free(scratch);
    var m = r.toMutable();
    m.sqrt(a, scratch);
    finish(&r, m);
    return r;
}

/// 0、1、-1 のいずれか。
fn isUnit(a: Const) bool {
    return a.eqlZero() or (a.limbs.len == 1 and a.limbs[0] == 1);
}

/// Reads an unsigned digit string in `radix` (2 to 36).
///
/// 数字は呼び出し側(`src/num/syntax.zig` の `scan`)が検査済みでなければならない。
/// 大文字と小文字を区別しない。先頭の0は許す。符号と区切りは受け付けない。
///
/// 時間は桁数の2乗に比例する(40万桁の10進で、実測は数百ミリ秒の桁)。入力の長さの
/// 上限は呼び出し側が持つこと。
pub fn parseDigits(gpa: Allocator, digits: []const u8, radix: u8) Error!Managed {
    std.debug.assert(radix >= 2 and radix <= 36);
    for (digits) |ch| std.debug.assert(if (std.fmt.charToDigit(ch, radix)) |_| true else |_| false);
    var r = try zeroed(gpa, limbsForDigits(digits.len, radix) + 1);
    errdefer r.deinit();
    var m = r.toMutable();
    m.setString(radix, digits) catch unreachable;
    finish(&r, m);
    return r;
}

/// Writes `a` in `radix` (2 to 36) with lowercase digits and a leading `-`
/// for a negative value.
///
/// 2のべき以外の基数では、時間が限界値数の2乗に比例する(40万桁の10進で、実測は
/// 数秒の桁)。結果の大きさに上限を置くのは呼び出し側の役目である。
pub fn toString(gpa: Allocator, a: Const, radix: u8) Error![]u8 {
    std.debug.assert(radix >= 2 and radix <= 36);
    if (std.math.isPowerOfTwo(radix)) return toStringPowerOfTwo(gpa, a, radix);
    return a.toStringAlloc(gpa, radix, .lower);
}

/// 基数が2のべきのときの `toString`。
///
/// Why: Zig 0.17.0 の `Const.toString` は、2のべきの基数で、限界値ごとに桁を切り出し、
/// 限界値の境目を桁が跨ぐ場合(64 が log2(基数) で割り切れない基数8と32)を扱わない。
/// 基数8で3限界値の値を書くと、2限界値目以降の桁がずれた別の列になる(実機で確認した。
/// `parseDigits` の結果を16進で書くと正しいので、誤りは書き出しの側にある)。上流で
/// 直っているかは未確認である。直っても、この関数は桁の切り出しを限界値の境目をまたいで
/// 行うだけなので、残して害はない。基数2と16は std でも正しいが、経路を1つにするため
/// 2のべきは全部ここを通す。
fn toStringPowerOfTwo(gpa: Allocator, a: Const, radix: u8) Error![]u8 {
    if (a.eqlZero()) return gpa.dupe(u8, "0");
    const width: usize = std.math.log2_int(u8, radix);
    const digit_count = (a.bitCountAbs() + width - 1) / width;
    const sign_len: usize = @intFromBool(!a.positive);
    const out = try gpa.alloc(u8, sign_len + digit_count);
    if (sign_len == 1) out[0] = '-';
    for (0..digit_count) |i| {
        const offset = (digit_count - 1 - i) * width;
        out[sign_len + i] = std.fmt.digitToChar(bitsAt(a.limbs, offset, width), .lower);
    }
    return out;
}

/// `limbs` を下位から並べたビット列の、offset ビット目から width ビット(width は limb_bits 未満)。
fn bitsAt(limbs: []const Limb, offset: usize, width: usize) u8 {
    const index = offset / limb_bits;
    const bit: std.math.Log2Int(Limb) = @intCast(offset % limb_bits);
    var v: Limb = limbs[index] >> bit;
    if (bit != 0 and index + 1 < limbs.len) {
        v |= limbs[index + 1] << @intCast(limb_bits - @as(usize, bit));
    }
    const mask = (@as(Limb, 1) << @intCast(width)) - 1;
    return @intCast(v & mask);
}

/// log2(radix) を 1024 倍して切り上げた値。`limbsForDigits` が整数だけで上限を求める。
const log2_radix_x1024: [37]u32 = blk: {
    var t: [37]u32 = @splat(0);
    for (2..37) |r| t[r] = @intFromFloat(@ceil(@log2(@as(f64, @floatFromInt(r))) * 1024));
    break :blk t;
};

/// An upper bound on the limbs of the value `digit_count` digits in `radix` can have.
///
/// 基数が2のべきなら誤差は高々1限界値、10では約0.1%である。桁数が `usize` の
/// 上限に近くてもあふれない。
pub fn limbsForDigits(digit_count: usize, radix: u8) usize {
    std.debug.assert(radix >= 2 and radix <= 36);
    const bits = @as(u128, digit_count) * log2_radix_x1024[radix] / 1024;
    return @intCast(bits / limb_bits + 1);
}

/// An upper bound on the limbs of `base ^ exponent`, or null when `pow` cannot compute it.
///
/// 0、1、-1 の底は指数によらず1を返す。それ以外の底は、指数が u32 に収まり、
/// 大きさが `usize` に収まるときだけ値を返す。上限は、底のビット数 × 指数を使うので、
/// 実際より最大で指数ビットだけ大きい(3 の累乗なら約26%)。見積りは確保の上限との
/// 照合に使うだけなので、大きめに出てよい。数えるのは結果の限界値数だけで、`pow` の
/// 作業用の確保は含まない(`pow` の doc コメントを参照)。
pub fn limbsForPow(base: Const, exponent: u64) ?usize {
    if (exponent == 0 or isUnit(base)) return 1;
    if (exponent > std.math.maxInt(u32)) return null;
    const bits = std.math.mul(usize, base.bitCountAbs(), @intCast(exponent)) catch return null;
    return bits / limb_bits + 1;
}

test {
    std.testing.refAllDecls(@This());
}

const testing = std.testing;
const tgpa = testing.allocator;

const edge_values = [_]i64{
    0,                        1,                        -1,
    2,                        -2,                       3,
    -3,                       7,                        -7,
    10,                       -10,                      255,
    256,                      65535,                    65536,
    1 << 32,                  -(1 << 32),               1_000_000_007,
    -999_999_999_999,         std.math.maxInt(i64),     std.math.minInt(i64),
    std.math.maxInt(i64) - 1, std.math.minInt(i64) + 1,
};

fn fromInt(v: anytype) !Managed {
    return Managed.initSet(tgpa, v);
}

/// 零は長さ1の正の値で、最上位の限界値は0でない。
fn expectNormalized(m: Managed) !void {
    const c = m.toConst();
    if (c.eqlZero()) {
        try testing.expect(m.isPositive());
        try testing.expectEqual(@as(usize, 1), c.limbs.len);
    } else {
        try testing.expect(c.limbs[c.limbs.len - 1] != 0);
    }
}

fn expectValue(want: i128, got: Managed) !void {
    try expectNormalized(got);
    try testing.expectEqual(want, try got.toInt(i128));
}

fn checkPair(a: i64, b: i64) !void {
    var ma = try fromInt(a);
    defer ma.deinit();
    var mb = try fromInt(b);
    defer mb.deinit();
    const wa: i128 = a;
    const wb: i128 = b;

    var s = try add(tgpa, ma.toConst(), mb.toConst());
    defer s.deinit();
    try expectValue(wa + wb, s);

    var d = try sub(tgpa, ma.toConst(), mb.toConst());
    defer d.deinit();
    try expectValue(wa - wb, d);

    var p = try mul(tgpa, ma.toConst(), mb.toConst());
    defer p.deinit();
    try expectValue(wa * wb, p);

    if (b != 0) {
        var f = try divide(tgpa, ma.toConst(), mb.toConst(), .floor);
        defer f.q.deinit();
        defer f.r.deinit();
        try expectValue(@divFloor(wa, wb), f.q);
        try expectValue(@mod(wa, wb), f.r);

        var t = try divide(tgpa, ma.toConst(), mb.toConst(), .truncate);
        defer t.q.deinit();
        defer t.r.deinit();
        try expectValue(@divTrunc(wa, wb), t.q);
        try expectValue(@rem(wa, wb), t.r);
    }

    var g = try gcd(tgpa, ma.toConst(), mb.toConst());
    defer g.deinit();
    try expectValue(refGcd(@abs(wa), @abs(wb)), g);
}

fn refGcd(a: u128, b: u128) i128 {
    var x = a;
    var y = b;
    while (y != 0) {
        const t = x % y;
        x = y;
        y = t;
    }
    return @intCast(x);
}

test "mul refuses before it computes when the temporaries of Karatsuba's method are refused" {
    // 結果の確保(1回目)は通り、一時領域(2回目)は断られる。断られたら、2乗の方法に黙って
    // 切り替えず、エラーにする。
    const limbs = 100;
    var storage: [limbs]Limb = undefined;
    @memset(&storage, std.math.maxInt(Limb));
    const a: Const = .{ .limbs = &storage, .positive = true };
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 1 });
    try std.testing.expectError(error.OutOfMemory, mul(failing.allocator(), a, a));
    // 小さい乗算は一時領域を取らないので、同じ条件でも通る。
    var small_failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 1 });
    var small = try mul(small_failing.allocator(), .{ .limbs = storage[0..48], .positive = true }, .{ .limbs = storage[0..48], .positive = true });
    small.deinit();
    // 断られなければ、積は正しい: (2^(64n) - 1)^2 = 2^(128n) - 2^(64n+1) + 1。
    var product = try mul(std.testing.allocator, a, a);
    defer product.deinit();
    try std.testing.expectEqual(2 * limbs, product.len());
    try std.testing.expectEqual(@as(Limb, 1), product.limbs[0]);
    try std.testing.expectEqual(@as(Limb, 0), product.limbs[1]);
    try std.testing.expectEqual(std.math.maxInt(Limb) - 1, product.limbs[limbs]);
    try std.testing.expectEqual(std.math.maxInt(Limb), product.limbs[2 * limbs - 1]);
}

test "mul asks for the whole probe, and only when the shorter factor is long enough" {
    // 大きさで断る割り当て器(250 limb 分の固定の領域。`Limb` の幅によらない)を使い、試し取りの
    // 大きさと条件を固定する。
    var storage: [100]Limb = undefined;
    @memset(&storage, std.math.maxInt(Limb));
    const long: Const = .{ .limbs = &storage, .positive = true };
    const short: Const = .{ .limbs = storage[0..10], .positive = true };
    const budget_limbs = 250;
    var buffer: [budget_limbs * @sizeOf(Limb)]u8 align(@alignOf(Limb)) = undefined;
    // 100 桁 x 100 桁: 結果は 200 桁で入るが、試し取り(264 桁)は入らない。
    {
        var fixed = std.heap.FixedBufferAllocator.init(&buffer);
        try std.testing.expectError(error.OutOfMemory, mul(fixed.allocator(), long, long));
    }
    // 100 桁 x 10 桁: 短い方が閾値以下なので、試し取りをしない。学校式で、領域は結果の分だけ。
    {
        var fixed = std.heap.FixedBufferAllocator.init(&buffer);
        var product = try mul(fixed.allocator(), long, short);
        defer product.deinit();
        try std.testing.expectEqual(110, product.len());
    }
}

test "add, sub, mul, divide and gcd agree with i128 on the edge values" {
    for (edge_values) |a| {
        for (edge_values) |b| try checkPair(a, b);
    }
}

test "add, sub, mul, divide and gcd agree with i128 on random i64 values" {
    var prng: std.Random.DefaultPrng = .init(0x4c4c_0001);
    const rand = prng.random();
    for (0..2000) |_| {
        const a = rand.int(i64);
        // 桁数の違う組と、同じ符号の組が偏らないよう、小さい値も混ぜる。
        const b = if (rand.boolean()) rand.int(i64) else rand.intRangeAtMost(i64, -1000, 1000);
        try checkPair(a, b);
        try checkPair(b, a);
    }
}

test "a zero result is positive even when the operand signs differ" {
    var big = try parseDigits(tgpa, "123456789012345678901234567890", 10);
    defer big.deinit();
    big.negate();
    var zero = try fromInt(0);
    defer zero.deinit();

    var p = try mul(tgpa, zero.toConst(), big.toConst());
    defer p.deinit();
    try expectValue(0, p);

    var q = try mul(tgpa, big.toConst(), zero.toConst());
    defer q.deinit();
    try expectValue(0, q);

    var s = try sub(tgpa, big.toConst(), big.toConst());
    defer s.deinit();
    try expectValue(0, s);

    var d = try divide(tgpa, big.toConst(), big.toConst(), .floor);
    defer d.q.deinit();
    defer d.r.deinit();
    try expectValue(1, d.q);
    try expectValue(0, d.r);

    var g = try gcd(tgpa, zero.toConst(), zero.toConst());
    defer g.deinit();
    try expectValue(0, g);
}

test "gcd with zero and with a multi-limb operand" {
    var big = try parseDigits(tgpa, "340282366920938463463374607431768211456", 10); // 2^128
    defer big.deinit();
    big.negate();
    var zero = try fromInt(0);
    defer zero.deinit();
    var twelve = try fromInt(12);
    defer twelve.deinit();

    var g1 = try gcd(tgpa, zero.toConst(), big.toConst());
    defer g1.deinit();
    try expectNormalized(g1);
    try testing.expect(g1.toConst().eql(big.toConst().abs()));

    var g2 = try gcd(tgpa, big.toConst(), twelve.toConst());
    defer g2.deinit();
    try expectValue(4, g2);
}

test "divide by a multi-limb divisor rounds as R7RS 6.2.6 describes" {
    // -(2^100 + 1) を 2^64 で割る。
    var a = try parseDigits(tgpa, "1267650600228229401496703205377", 10);
    defer a.deinit();
    a.negate();
    var b = try fromInt(@as(u128, 1) << 64);
    defer b.deinit();

    var f = try divide(tgpa, a.toConst(), b.toConst(), .floor);
    defer f.q.deinit();
    defer f.r.deinit();
    // floor: q = -(2^36) - 1、r = 2^64 - 1
    try expectValue(-(@as(i128, 1) << 36) - 1, f.q);
    try expectValue((@as(i128, 1) << 64) - 1, f.r);

    var t = try divide(tgpa, a.toConst(), b.toConst(), .truncate);
    defer t.q.deinit();
    defer t.r.deinit();
    try expectValue(-(@as(i128, 1) << 36), t.q);
    try expectValue(-1, t.r);
}

/// 10進の乱数列から、桁数 digit_count の符号つきの値を作る。
fn randomValue(rand: std.Random, digit_count: usize) !Managed {
    const text = try tgpa.alloc(u8, digit_count);
    defer tgpa.free(text);
    for (text, 0..) |*ch, i| ch.* = '0' + rand.intRangeAtMost(u8, if (i == 0) 1 else 0, 9);
    var m = try parseDigits(tgpa, text, 10);
    if (rand.boolean()) m.negate();
    return m;
}

fn expectSignOf(want_positive: bool, m: Managed) !void {
    if (!m.eqlZero()) try testing.expectEqual(want_positive, m.isPositive());
}

test "divide of multi-limb values satisfies q * b + r == a with the rounding's remainder sign" {
    var prng: std.Random.DefaultPrng = .init(0x4c4c_0005);
    const rand = prng.random();
    for (0..300) |_| {
        // Managed の最小の確保は4限界値なので、それを超える桁数も混ぜる。
        var a = try randomValue(rand, rand.intRangeAtMost(usize, 1, 200));
        defer a.deinit();
        var b = try randomValue(rand, rand.intRangeAtMost(usize, 1, 120));
        defer b.deinit();
        inline for (.{ Rounding.floor, Rounding.truncate }) |mode| {
            var d = try divide(tgpa, a.toConst(), b.toConst(), mode);
            defer d.q.deinit();
            defer d.r.deinit();
            try expectNormalized(d.q);
            try expectNormalized(d.r);
            var qb = try mul(tgpa, d.q.toConst(), b.toConst());
            defer qb.deinit();
            var sum = try add(tgpa, qb.toConst(), d.r.toConst());
            defer sum.deinit();
            try testing.expect(sum.toConst().eql(a.toConst()));
            try testing.expectEqual(std.math.Order.lt, d.r.toConst().orderAbs(b.toConst()));
            try expectSignOf(if (mode == .floor) b.isPositive() else a.isPositive(), d.r);
        }
    }
}

test "gcd of multi-limb values divides both and is divisible by the common factor" {
    var prng: std.Random.DefaultPrng = .init(0x4c4c_0006);
    const rand = prng.random();
    for (0..100) |_| {
        var f = try randomValue(rand, rand.intRangeAtMost(usize, 1, 80));
        defer f.deinit();
        var x = try randomValue(rand, rand.intRangeAtMost(usize, 1, 80));
        defer x.deinit();
        var y = try randomValue(rand, rand.intRangeAtMost(usize, 1, 80));
        defer y.deinit();
        var fx = try mul(tgpa, f.toConst(), x.toConst());
        defer fx.deinit();
        var fy = try mul(tgpa, f.toConst(), y.toConst());
        defer fy.deinit();
        var g = try gcd(tgpa, fx.toConst(), fy.toConst());
        defer g.deinit();
        try expectNormalized(g);
        try testing.expect(g.isPositive());
        // gcd(f x, f y) は f の倍数で、f x と f y を割り切る。
        for ([_]Managed{ f, fx, fy }, 0..) |m, i| {
            var d = try divide(tgpa, if (i == 0) g.toConst() else m.toConst(), if (i == 0) f.toConst() else g.toConst(), .truncate);
            defer d.q.deinit();
            defer d.r.deinit();
            try testing.expect(d.r.eqlZero());
        }
        // 0 との gcd は絶対値になる。
        var zero = try fromInt(0);
        defer zero.deinit();
        var g0 = try gcd(tgpa, zero.toConst(), fx.toConst());
        defer g0.deinit();
        try testing.expect(g0.toConst().eql(fx.toConst().abs()));
    }
}

test "log2_radix_x1024 is the smallest upper bound of log2(radix) * 1024" {
    // radix^1024 <= 2^table[radix] < 2 * radix^1024 を、整数だけで確かめる。
    for (2..37) |r| {
        var base = try fromInt(r);
        defer base.deinit();
        var p = try pow(tgpa, base.toConst(), 1024);
        defer p.deinit();
        var upper = try fromInt(1);
        defer upper.deinit();
        try upper.shiftLeft(&upper, log2_radix_x1024[r]);
        var lower = try fromInt(1);
        defer lower.deinit();
        try lower.shiftLeft(&lower, log2_radix_x1024[r] - 1);
        try testing.expect(p.toConst().order(upper.toConst()) != .gt);
        try testing.expectEqual(std.math.Order.gt, p.toConst().order(lower.toConst()));
    }
}

test "sqrt gives the largest root whose square does not exceed the number" {
    var zero = try fromInt(@as(i64, 0));
    defer zero.deinit();
    var r0 = try sqrt(tgpa, zero.toConst());
    defer r0.deinit();
    try expectValue(0, r0);
    var k: i128 = 1;
    while (k < (1 << 60)) : (k = k * 3 + 1) {
        for ([_]i128{ k * k - 1, k * k, k * k + 1 }) |n| {
            var mn = try Managed.initSet(tgpa, n);
            defer mn.deinit();
            var r = try sqrt(tgpa, mn.toConst());
            defer r.deinit();
            const expected: i128 = @intCast(std.math.sqrt(@as(u128, @intCast(n))));
            try expectValue(expected, r);
        }
    }
}

test "pow agrees with repeated multiplication in i128" {
    var base: i64 = -9;
    while (base <= 9) : (base += 1) {
        var mb = try fromInt(base);
        defer mb.deinit();
        var expected: i128 = 1;
        var exp: u64 = 0;
        while (exp <= 40) : (exp += 1) {
            var p = try pow(tgpa, mb.toConst(), exp);
            defer p.deinit();
            try expectValue(expected, p);
            expected = std.math.mul(i128, expected, base) catch break;
        }
    }
}

test "pow of zero, one and minus one accepts any exponent" {
    var zero = try fromInt(0);
    defer zero.deinit();
    var one = try fromInt(1);
    defer one.deinit();
    var minus_one = try fromInt(-1);
    defer minus_one.deinit();
    const huge: u64 = (1 << 40) + 1;

    var p0 = try pow(tgpa, zero.toConst(), 0);
    defer p0.deinit();
    try expectValue(1, p0);
    var p1 = try pow(tgpa, zero.toConst(), huge);
    defer p1.deinit();
    try expectValue(0, p1);
    var p2 = try pow(tgpa, one.toConst(), huge);
    defer p2.deinit();
    try expectValue(1, p2);
    var p3 = try pow(tgpa, minus_one.toConst(), huge);
    defer p3.deinit();
    try expectValue(-1, p3);
    var p4 = try pow(tgpa, minus_one.toConst(), huge - 1);
    defer p4.deinit();
    try expectValue(1, p4);
}

test "pow of a multi-limb base equals repeated multiplication" {
    var base = try parseDigits(tgpa, "123456789012345678901234567890", 10);
    defer base.deinit();
    base.negate();
    var acc = try fromInt(1);
    defer acc.deinit();
    for (0..12) |e| {
        var p = try pow(tgpa, base.toConst(), e);
        defer p.deinit();
        try expectNormalized(p);
        try testing.expect(p.toConst().eql(acc.toConst()));
        const next = try mul(tgpa, acc.toConst(), base.toConst());
        acc.deinit();
        acc = next;
    }
}

fn refToString(buf: []u8, v: i128, radix: u8) []const u8 {
    var i: usize = buf.len;
    var rest: u128 = @abs(v);
    if (rest == 0) {
        i -= 1;
        buf[i] = '0';
    }
    while (rest != 0) {
        i -= 1;
        buf[i] = std.fmt.digitToChar(@intCast(rest % radix), .lower);
        rest /= radix;
    }
    if (v < 0) {
        i -= 1;
        buf[i] = '-';
    }
    return buf[i..];
}

test "toString and parseDigits round-trip i64 values in radix 2, 8, 10 and 16" {
    for ([_]u8{ 2, 8, 10, 16 }) |radix| {
        var prng: std.Random.DefaultPrng = .init(@as(u64, 0x4c4c_0002) + radix);
        const rand = prng.random();
        var samples: [edge_values.len + 500]i64 = undefined;
        @memcpy(samples[0..edge_values.len], &edge_values);
        for (samples[edge_values.len..]) |*s| s.* = rand.int(i64) >> rand.intRangeAtMost(u6, 0, 62);

        for (samples) |v| {
            var m = try fromInt(v);
            defer m.deinit();
            const s = try toString(tgpa, m.toConst(), radix);
            defer tgpa.free(s);
            var buf: [130]u8 = undefined;
            try testing.expectEqualStrings(refToString(&buf, v, radix), s);

            const digits = if (v < 0) s[1..] else s;
            var back = try parseDigits(tgpa, digits, radix);
            defer back.deinit();
            if (v < 0) back.negate();
            try expectValue(v, back);
        }
    }
}

test "parseDigits accepts upper case, leading zeros and the empty-looking zero" {
    var a = try parseDigits(tgpa, "FfA0", 16);
    defer a.deinit();
    try expectValue(0xffa0, a);

    var b = try parseDigits(tgpa, "000", 10);
    defer b.deinit();
    try expectValue(0, b);

    var c = try parseDigits(tgpa, "0001011", 2);
    defer c.deinit();
    try expectValue(11, c);
}

fn roundTripLong(rand: std.Random, digit_count: usize, radix: u8) !void {
    const text = try tgpa.alloc(u8, digit_count);
    defer tgpa.free(text);
    for (text, 0..) |*ch, i| {
        const lo: u8 = if (i == 0) 1 else 0;
        ch.* = std.fmt.digitToChar(rand.intRangeAtMost(u8, lo, radix - 1), .lower);
    }
    var m = try parseDigits(tgpa, text, radix);
    defer m.deinit();
    try expectNormalized(m);
    try testing.expect(m.len() <= limbsForDigits(digit_count, radix));
    const s = try toString(tgpa, m.toConst(), radix);
    defer tgpa.free(s);
    try testing.expectEqualStrings(text, s);
}

test "long digit strings round-trip in radix 2, 8, 10 and 16" {
    var prng: std.Random.DefaultPrng = .init(0x4c4c_0003);
    const rand = prng.random();
    // 8 と 32 は、桁が限界値の境目を跨ぐ(toStringPowerOfTwo の Why を参照)。
    for ([_]u8{ 2, 4, 8, 10, 16, 32, 36 }) |radix| {
        for ([_]usize{ 1, 2, 18, 19, 20, 21, 22, 23, 63, 64, 65, 200 }) |n| try roundTripLong(rand, n, radix);
    }
}

test "limbsForDigits is an upper bound and is not wasteful" {
    var prng: std.Random.DefaultPrng = .init(0x4c4c_0004);
    const rand = prng.random();
    for ([_]u8{ 2, 8, 10, 16 }) |radix| {
        for ([_]usize{ 1, 10, 64, 1000 }) |n| {
            // 最大の値(全桁が最大の数字)で、見積りが足りるかを見る。
            const text = try tgpa.alloc(u8, n);
            defer tgpa.free(text);
            @memset(text, std.fmt.digitToChar(radix - 1, .lower));
            var m = try parseDigits(tgpa, text, radix);
            defer m.deinit();
            const bound = limbsForDigits(n, radix);
            try testing.expect(m.len() <= bound);
            // 余りは数限界値以内。大きな n では、真の値の 2% 未満の余裕に収まる。
            if (n >= 1000) try testing.expect(bound <= m.len() + m.len() / 50 + 1);
        }
    }
    _ = rand;
    try testing.expectEqual(@as(usize, 1), limbsForDigits(0, 10));
    // 桁数が極端に大きくても、あふれずに大きな値を返す。
    try testing.expect(limbsForDigits(std.math.maxInt(usize), 10) > std.math.maxInt(usize) / 128);
}

test "limbsForDigits covers the largest value of every radix and length" {
    for (2..37) |r| {
        const radix: u8 = @intCast(r);
        const text = try tgpa.alloc(u8, 400);
        defer tgpa.free(text);
        @memset(text, std.fmt.digitToChar(radix - 1, .lower));
        for (1..401) |n| {
            var m = try parseDigits(tgpa, text[0..n], radix);
            defer m.deinit();
            try testing.expect(m.len() <= limbsForDigits(n, radix));
        }
    }
}

test "add and sub carry across more than the minimum allocation" {
    // 2^320 - 1 は5限界値で、1を足すと6限界値になる(Managed の最小の確保は4限界値)。
    var f_digits: [80]u8 = undefined;
    @memset(&f_digits, 'f');
    var max = try parseDigits(tgpa, &f_digits, 16);
    defer max.deinit();
    var one = try fromInt(1);
    defer one.deinit();
    var pow2 = try fromInt(1);
    defer pow2.deinit();
    try pow2.shiftLeft(&pow2, 320);

    var s = try add(tgpa, max.toConst(), one.toConst());
    defer s.deinit();
    try expectNormalized(s);
    try testing.expect(s.toConst().eql(pow2.toConst()));

    var s2 = try add(tgpa, one.toConst(), max.toConst());
    defer s2.deinit();
    try testing.expect(s2.toConst().eql(pow2.toConst()));

    // 1 - (-(2^320 - 1)) = 2^320、-(2^320 - 1) - 1 = -2^320
    var neg_max = try max.clone();
    defer neg_max.deinit();
    neg_max.negate();
    var d = try sub(tgpa, one.toConst(), neg_max.toConst());
    defer d.deinit();
    try testing.expect(d.toConst().eql(pow2.toConst()));

    var d2 = try sub(tgpa, neg_max.toConst(), one.toConst());
    defer d2.deinit();
    try expectNormalized(d2);
    try testing.expect(d2.toConst().eql(pow2.toConst().negate()));
}

test "limbsForPow is an upper bound and reports what pow cannot compute" {
    var base = try fromInt(@as(i128, -3));
    defer base.deinit();
    for ([_]u64{ 0, 1, 2, 63, 64, 65, 100, 1000 }) |e| {
        var p = try pow(tgpa, base.toConst(), e);
        defer p.deinit();
        const bound = limbsForPow(base.toConst(), e).?;
        try testing.expect(p.len() <= bound);
        // 底のビット数で見積もるので、3 のようにビット数が log2 より大きい底では緩い。
        try testing.expect(bound <= p.len() + p.len() / 3 + 2);
    }

    var wide = try parseDigits(tgpa, "340282366920938463463374607431768211456", 10);
    defer wide.deinit();
    // 2^128 の 2^40 乗は、指数が u32 に収まらないので、pow は計算できない。
    try testing.expectEqual(@as(?usize, null), limbsForPow(wide.toConst(), 1 << 40));
    // 指数が u32 に収まれば、ビット数 × 指数から求める。usize が32ビットなら、あふれて null。
    const max_exp = std.math.maxInt(u32);
    const expected: ?usize = if (@sizeOf(usize) == 8) 129 * max_exp / limb_bits + 1 else null;
    try testing.expectEqual(expected, limbsForPow(wide.toConst(), max_exp));

    var one = try fromInt(1);
    defer one.deinit();
    try testing.expectEqual(@as(?usize, 1), limbsForPow(one.toConst(), std.math.maxInt(u64)));
    var zero = try fromInt(0);
    defer zero.deinit();
    try testing.expectEqual(@as(?usize, 1), limbsForPow(zero.toConst(), std.math.maxInt(u64)));
}

test "allocation failure in every operation leaves nothing behind" {
    try testing.checkAllAllocationFailures(tgpa, allocationProbe, .{});
}

fn allocationProbe(alloc: Allocator) !void {
    var a = try parseDigits(alloc, "123456789012345678901234567890123", 10);
    defer a.deinit();
    var b = try parseDigits(alloc, "-0"[1..], 10);
    defer b.deinit();
    var seven = try Managed.initSet(alloc, 7);
    defer seven.deinit();

    var s = try add(alloc, a.toConst(), seven.toConst());
    defer s.deinit();
    var d = try sub(alloc, a.toConst(), seven.toConst());
    defer d.deinit();
    var p = try mul(alloc, a.toConst(), a.toConst());
    defer p.deinit();
    var f = try divide(alloc, p.toConst(), seven.toConst(), .floor);
    defer f.q.deinit();
    defer f.r.deinit();
    var t = try divide(alloc, p.toConst(), seven.toConst(), .truncate);
    defer t.q.deinit();
    defer t.r.deinit();
    var g = try gcd(alloc, p.toConst(), a.toConst());
    defer g.deinit();
    var w = try pow(alloc, a.toConst(), 5);
    defer w.deinit();
    const text = try toString(alloc, w.toConst(), 10);
    defer alloc.free(text);
}

/// n! を計算し、n! / (n - 1)! が n に、gcd(n!, (n - 1)!) が (n - 1)! になることを確かめる。
fn factorialChecks(n: u64) !void {
    var fact = try fromInt(1);
    defer fact.deinit();
    var prev = try fromInt(1);
    defer prev.deinit();
    var k: u64 = 2;
    while (k <= n) : (k += 1) {
        var m = try fromInt(k);
        defer m.deinit();
        const next = try mul(tgpa, fact.toConst(), m.toConst());
        prev.deinit();
        prev = fact;
        fact = next;
    }
    var nn = try fromInt(n);
    defer nn.deinit();
    var d = try divide(tgpa, fact.toConst(), prev.toConst(), .truncate);
    defer d.q.deinit();
    defer d.r.deinit();
    try testing.expect(d.q.toConst().eql(nn.toConst()));
    try testing.expect(d.r.toConst().eqlZero());

    var g = try gcd(tgpa, fact.toConst(), prev.toConst());
    defer g.deinit();
    try testing.expect(g.toConst().eql(prev.toConst()));

    const s = try toString(tgpa, fact.toConst(), 10);
    defer tgpa.free(s);
    var back = try parseDigits(tgpa, s, 10);
    defer back.deinit();
    try testing.expect(back.toConst().eql(fact.toConst()));
}

/// 3^e の10進の桁数は floor(e * log10(3)) + 1 で、toString と parseDigits が往復する。
fn powerOfThreeChecks(e: u32, expected_digits: usize) !void {
    var three = try fromInt(3);
    defer three.deinit();
    var p = try pow(tgpa, three.toConst(), e);
    defer p.deinit();
    try testing.expect(p.len() <= limbsForPow(three.toConst(), e).?);
    const s = try toString(tgpa, p.toConst(), 10);
    defer tgpa.free(s);
    try testing.expectEqual(expected_digits, s.len);
    var back = try parseDigits(tgpa, s, 10);
    defer back.deinit();
    try testing.expect(back.toConst().eql(p.toConst()));
}

test "factorial and power of three at a small scale" {
    try factorialChecks(60);
    // 3^1000 は478桁(1000 * log10(3) = 477.12...)。
    try powerOfThreeChecks(1000, 478);
}

test "factorial and power of three at a large scale" {
    try tier.slow();
    try factorialChecks(3000);
    // 3^100000 は47713桁(100000 * log10(3) = 47712.12...)。
    try powerOfThreeChecks(100_000, 47713);
}
