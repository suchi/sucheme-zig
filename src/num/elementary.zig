//! Elementary functions of the real numbers whose argument can lie beyond an `f64`
//! (docs/design/numerics-and-unicode.md の「超越関数と平方根」).
//!
//! 引数は実数(fixnum、bignum、ratnum、flonum)である。正確な数を先に `f64` にすると、`f64` の
//! 範囲を超える数(`(expt 10 400)` など)が無限大になり、対数や逆正接が誤った値になる。この
//! ファイルの関数は、そうした数を整数の演算で縮めてから `f64` の関数に渡す。作業領域は
//! `ops.counted` を通して、ヒープの上限に計上する。

const std = @import("std");
const value_mod = @import("../value.zig");
const heap_mod = @import("../heap.zig");
const bigint = @import("bigint.zig");
const number = @import("number.zig");
const ops = @import("ops.zig");
const power = @import("power.zig");

const Value = value_mod.Value;
const Heap = heap_mod.Heap;
const Managed = bigint.Managed;

pub const Error = power.Error;

/// The `f64` nearest to the real number `v`.
pub fn toF64(h: *Heap, v: Value) Error!f64 {
    if (v.asFlonum()) |x| return x;
    if (v.asFixnum()) |n| return @floatFromInt(n);
    return ops.counted(f64, toF64Work, h, .{v});
}

fn toF64Work(_: *Heap, gpa: std.mem.Allocator, v: Value) number.Error!f64 {
    return number.toFlonum(gpa, v);
}

// ---- sqrt ----

/// The integer square root of an exact non-negative integer, and whether it is exact.
const Root = struct {
    root: Value,
    exact: bool,

    fn of(h: *Heap, n: Value) Error!Root {
        const root = try power.integerSqrt(h, n);
        const square = try ops.apply(h, .mul, root, root);
        return .{ .root = root, .exact = try ops.numEqual(h, square, n) };
    }

    /// The root of the integer `n` as an `f64`. `f64` に収まらない整数は、整数の平方根を
    /// `f64` にする(根の誤差は相対で 2^-53 以下)。
    fn approximate(self: Root, h: *Heap, n: Value) Error!f64 {
        const x = try toF64(h, n);
        if (std.math.isFinite(x)) return @sqrt(x);
        return toF64(h, self.root);
    }
};

/// The square root of the non-negative real number `v`: exact when `v` is an exact square (an
/// integer, or a ratio of two squares), and a flonum otherwise.
///
/// 整数の平方根は1回だけ求める。比が `f64` で無限大か 0 になる有理数は、分子と分母の根を別々に
/// `f64` にして割る(`(sqrt (/ (expt 10 400) 3))` は約 5.77e199)。
pub fn sqrt(h: *Heap, v: Value) Error!Value {
    if (v.asFlonum()) |x| return .fromFlonum(@sqrt(x));
    if (v.asRatnum()) |r| {
        const numerator = try Root.of(h, r.numerator);
        const denominator = try Root.of(h, r.denominator);
        if (numerator.exact and denominator.exact) return ops.apply(h, .div, numerator.root, denominator.root);
        const x = try toF64(h, v);
        if (std.math.isFinite(x) and x != 0) return .fromFlonum(@sqrt(x));
        const top = try numerator.approximate(h, r.numerator);
        const bottom = try denominator.approximate(h, r.denominator);
        return .fromFlonum(top / bottom);
    }
    const root = try Root.of(h, v);
    if (root.exact) return root.root;
    return .fromFlonum(try root.approximate(h, v));
}

/// The exact square root of the exact non-negative rational number `v`, or null if it has none.
pub fn exactSqrt(h: *Heap, v: Value) Error!?Value {
    if (v.asRatnum()) |r| {
        const numerator = try Root.of(h, r.numerator);
        const denominator = try Root.of(h, r.denominator);
        if (!numerator.exact or !denominator.exact) return null;
        return try ops.apply(h, .div, numerator.root, denominator.root);
    }
    const root = try Root.of(h, v);
    return if (root.exact) root.root else null;
}

// ---- log ----

/// The natural logarithm of the positive real number `v`.
///
/// `f64` に収まる数(最小の正規化数以上、無限大でない)は、`f64` の対数である。それ以外の
/// 整数と有理数は、整数の上位 64 ビットの対数に、捨てたビット数の `log 2` 倍を足して求める
/// (ratnum は分子の対数から分母の対数を引く)。
pub fn ln(h: *Heap, v: Value) Error!f64 {
    if (v.asFlonum()) |x| return @log(x);
    const x = try toF64(h, v);
    if (std.math.isFinite(x) and x >= std.math.floatMin(f64)) return @log(x);
    return ops.counted(f64, lnWork, h, .{v});
}

fn lnWork(_: *Heap, gpa: std.mem.Allocator, v: Value) number.Error!f64 {
    if (v.asRatnum()) |r| return try lnInteger(gpa, r.numerator) - try lnInteger(gpa, r.denominator);
    return lnInteger(gpa, v);
}

/// The natural logarithm of the positive integer `v`.
fn lnInteger(gpa: std.mem.Allocator, v: Value) number.Error!f64 {
    if (v.asFixnum()) |n| return @log(@as(f64, @floatFromInt(n)));
    const big = v.asBignum().?.toConst();
    const shift = big.bitCountAbs() - 64;
    var whole = try Managed.init(gpa);
    defer whole.deinit();
    try whole.copy(big);
    var top = try Managed.init(gpa);
    defer top.deinit();
    try top.shiftRight(&whole, shift);
    const leading: u64 = top.toInt(u64) catch unreachable;
    return @log(@as(f64, @floatFromInt(leading))) + @as(f64, @floatFromInt(shift)) * std.math.ln2;
}

// ---- atan2 ----

/// The angle of the point `(x, y)` in radians (R7RS 6.2.6 `(atan y x)`), for real numbers.
///
/// 両方が正確な数で、少なくとも一方が fixnum でないときは、小さい方を大きい方で割った正確な
/// 比の逆正接から求める。`f64` に収まらない数どうしの比が有限になる(`(atan (expt 10 400)
/// (expt 10 399))` は約 1.4711276743037347)。それ以外は `f64` の `atan2` である。
/// 両方が正確な 0 のとき、角は定まらない(呼び出し側が断る)。結果は 0 になる。
pub fn atan2(h: *Heap, y: Value, x: Value) Error!f64 {
    const both_exact = y.asFlonum() == null and x.asFlonum() == null;
    const both_small = y.asFixnum() != null and x.asFixnum() != null;
    if (!both_exact or both_small) return std.math.atan2(try toF64(h, y), try toF64(h, x));

    const zero: Value = .fromFixnum(0);
    const y_order = (try ops.compare(h, y, zero)).?;
    const x_order = (try ops.compare(h, x, zero)).?;
    if (y_order == .eq) return if (x_order == .lt) std.math.pi else 0.0;
    if (x_order == .eq) return if (y_order == .lt) -std.math.pi / 2.0 else std.math.pi / 2.0;
    const ay = try ops.absNumber(h, y);
    const ax = try ops.absNumber(h, x);
    // 第一象限の角 θ = atan(|y| / |x|)。比が 1 を超えるときは、π/2 - atan(|x| / |y|) にする。
    const theta = if ((try ops.compare(h, ay, ax)).? != .gt)
        std.math.atan(try toF64(h, try ops.apply(h, .div, ay, ax)))
    else
        std.math.pi / 2.0 - std.math.atan(try toF64(h, try ops.apply(h, .div, ax, ay)));
    const in_plane = if (x_order == .lt) std.math.pi - theta else theta;
    return if (y_order == .lt) -in_plane else in_plane;
}

test {
    std.testing.refAllDecls(@This());
}

const test_support = @import("../prim/test_support.zig");

fn parseNumber(h: *Heap, text: []const u8) !Value {
    return (try number.parse(h, text, 10)) orelse error.NotANumber;
}

fn tenPow(comptime n: usize) *const [n + 1]u8 {
    comptime {
        var digits: [n + 1]u8 = @splat('0');
        digits[0] = '1';
        const spelled = digits;
        return &spelled;
    }
}

const ten_320 = tenPow(320);
const ten_399 = tenPow(399);
const ten_400 = tenPow(400);

test "atan2 of exact numbers lies in the quadrant of the point" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    const h = &f.heap;
    const big = try parseNumber(h, ten_400);
    const neg_big = try ops.negate(h, big);
    const one: Value = .fromFixnum(1);
    const third = try parseNumber(h, "1/3");
    const pi = std.math.pi;
    // (y, x) が大きい数のとき、各象限と軸。
    try std.testing.expectEqual(pi / 4.0, try atan2(h, big, big));
    try std.testing.expectEqual(3.0 * pi / 4.0, try atan2(h, big, neg_big));
    try std.testing.expectEqual(-3.0 * pi / 4.0, try atan2(h, neg_big, neg_big));
    try std.testing.expectEqual(-pi / 4.0, try atan2(h, neg_big, big));
    try std.testing.expectEqual(pi / 2.0, try atan2(h, big, .fromFixnum(0)));
    try std.testing.expectEqual(-pi / 2.0, try atan2(h, neg_big, .fromFixnum(0)));
    try std.testing.expectEqual(pi, try atan2(h, .fromFixnum(0), neg_big));
    try std.testing.expectEqual(0.0, try atan2(h, .fromFixnum(0), big));
    // 比が 1 より大きい側と小さい側は、同じ点を足して π/2 になる。
    const above = try atan2(h, big, one);
    const below = try atan2(h, one, big);
    try std.testing.expectEqual(pi / 2.0, above);
    try std.testing.expectEqual(0.0, below);
    // 有理数。
    try std.testing.expect(@abs(try atan2(h, third, one) - std.math.atan(@as(f64, 1.0) / 3.0)) < 1e-16);
    // 比が `f64` に収まる大きな数。
    const nine = try parseNumber(h, ten_399);
    try std.testing.expect(@abs(try atan2(h, big, nine) - std.math.atan(@as(f64, 10.0))) < 1e-15);
}

test "ln is exact around the edge of the f64 range" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    const h = &f.heap;
    // 63 ビットの境目の前後の整数(fixnum と bignum)。
    const below = try parseNumber(h, "9223372036854775807");
    const above = try parseNumber(h, "9223372036854775808");
    try std.testing.expect(@abs(try ln(h, below) - 43.66827237527655) < 1e-12);
    try std.testing.expect(@abs(try ln(h, above) - 43.66827237527655) < 1e-12);
    // f64 を超える整数は、桁数に比例する。
    const e400 = try parseNumber(h, ten_400);
    try std.testing.expect(@abs(try ln(h, e400) - 400.0 * @log(10.0)) < 1e-11);
    // 分母が大きい有理数は、逆符号になる。
    const tiny = try parseNumber(h, "1/" ++ ten_400);
    try std.testing.expect(@abs(try ln(h, tiny) + 400.0 * @log(10.0)) < 1e-11);
    // 正規化数の下限を割る有理数も、精度を保つ(5e-324 は 1 ビットしか持たない)。
    const subnormal = try parseNumber(h, "1/" ++ ten_320);
    try std.testing.expect(@abs(try ln(h, subnormal) + 320.0 * @log(10.0)) < 1e-12);
}

test "sqrt keeps the root of an exact square exact and rounds the others" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    const h = &f.heap;
    const exact_square = try sqrt(h, try parseNumber(h, "1" ++ "00"));
    try std.testing.expectEqual(10, exact_square.asFixnum().?);
    const half = try sqrt(h, try parseNumber(h, "1/4"));
    try std.testing.expect(half.asRatnum() != null);
    try std.testing.expectEqual(1.4142135623730951, (try sqrt(h, .fromFixnum(2))).asFlonum().?);
    try std.testing.expect((try exactSqrt(h, .fromFixnum(2))) == null);
    try std.testing.expectEqual(3, (try exactSqrt(h, .fromFixnum(9))).?.asFixnum().?);
}
