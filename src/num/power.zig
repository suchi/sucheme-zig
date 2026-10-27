//! Powers, integer square roots and rationalization of the real numbers
//! (docs/design/numerics-and-unicode.md の「べき乗と平方根と rationalize」).
//!
//! 計算は `ops.zig` の演算と `bigint.zig` の上に書く。作業領域は `ops.counted` が `Heap.Charged`
//! から取り、演算の間だけヒープの上限に照らす。引数は数で、型の検査は呼び出し側
//! (`src/prim/number.zig`)が行う。

const std = @import("std");
const value_mod = @import("../value.zig");
const heap_mod = @import("../heap.zig");
const bigint = @import("bigint.zig");
const number = @import("number.zig");
const ops = @import("ops.zig");
const complex = @import("complex.zig");

const Value = value_mod.Value;
const Heap = heap_mod.Heap;
const Const = bigint.Const;
const Limb = bigint.Limb;

/// `WrongType` is an argument of a kind the operation does not take, such as a complex
/// exponent that is not an integer.
pub const Error = ops.Error || error{WrongType};

/// `(expt z1 z2)`: `z1` raised to the power `z2` (R7RS 6.2.6).
///
/// 指数が正確な整数のときは、底の種類によらず計算する。正確な底はべき乗を正確な数で、
/// flonum の底は `std.math.pow` で、複素数の底は2乗の繰り返しで求める。指数が正確な0なら、
/// 底によらず正確な 1 である(R7RS 6.2.6 の `(expt z 0)`)。
///
/// 指数が有理数か flonum なら、底の実数を flonum にして `std.math.pow` で計算する(結果は
/// 不正確な数)。負の底と整数でない指数は、極形式で複素数になる。複素数の指数と、複素数の
/// 底に対する整数でない指数は、`exp(z2 log z1)` で計算する(`complex.expt`)。
///
/// 結果が上限を超える正確なべき乗は、`HeapLimit` である。確保の前に大きさを見積もるので、
/// `(expt 2 (expt 10 12))` で長い計算を続けない。断るのはメモリの上限だけで、上限に収まる
/// 範囲の時間は、結果の桁数の約2乗で伸びる(docs/design/open-questions.md)。
pub fn expt(h: *Heap, base: Value, exponent: Value) Error!Value {
    std.debug.assert(number.isNumber(base) and number.isNumber(exponent));
    if (exponent.asFixnum()) |n| if (n == 0) return .fromFixnum(1);
    if (exponent.kind() == .compnum) return complex.expt(h, base, exponent);
    if (ops.isExactInteger(exponent)) return exptInteger(h, base, exponent);
    if (base.kind() == .compnum) return exptComplexByFloat(h, base, exponent);
    return ops.counted(Value, exptRealWork, h, .{ base, exponent });
}

fn exptInteger(h: *Heap, base: Value, exponent: Value) Error!Value {
    if (base.asFlonum()) |x| {
        const y = (try ops.toInexact(h, exponent)).asFlonum().?;
        return .fromFlonum(std.math.pow(f64, x, y));
    }
    const negative = isNegativeInteger(exponent);
    if (base.kind() == .compnum) {
        const n = exponent.asFixnum() orelse return error.OutOfRange;
        return exptComplex(h, base, n);
    }
    if (isZero(base)) return if (negative) error.DivisionByZero else base;
    if (base.asFixnum()) |b| {
        if (b == 1) return base;
        if (b == -1) return .fromFixnum(if (isOddInteger(exponent)) -1 else 1);
    }
    const magnitude: u64 = if (exponent.asFixnum()) |n|
        @abs(n)
    else
        exponent.asBignum().?.toConst().abs().toInt(u64) catch return error.HeapLimit;
    return ops.counted(Value, exptExactWork, h, .{ base, magnitude, negative });
}

fn exptExactWork(h: *Heap, gpa: std.mem.Allocator, base: Value, magnitude: u64, negative: bool) ops.Error!Value {
    var r: ops.Rational = undefined;
    r.set(base);
    // 見積りが null なら、指数が u32 を超え、結果は確保できる大きさではない。
    _ = bigint.limbsForPow(r.n, magnitude) orelse return error.HeapLimit;
    if (!r.integer) _ = bigint.limbsForPow(r.d, magnitude) orelse return error.HeapLimit;
    var n = try bigint.pow(gpa, r.n, magnitude);
    defer n.deinit();
    if (r.integer) {
        if (!negative) return number.fromInteger(h, n.toConst());
        return number.makeRatio(h, gpa, ops.one, n.toConst());
    }
    var d = try bigint.pow(gpa, r.d, magnitude);
    defer d.deinit();
    if (negative) return number.makeRatio(h, gpa, d.toConst(), n.toConst());
    return number.makeRatio(h, gpa, n.toConst(), d.toConst());
}

/// `base` to the power `n` by repeated squaring, for a complex `base`.
fn exptComplex(h: *Heap, base: Value, n: i64) Error!Value {
    var result: Value = .fromFixnum(1);
    var square = base;
    var k: u64 = @abs(n);
    while (k > 0) {
        if (k & 1 == 1) result = try ops.apply(h, .mul, result, square);
        k >>= 1;
        if (k > 0) square = try ops.apply(h, .mul, square, square);
    }
    if (n < 0) return ops.apply(h, .div, .fromFixnum(1), result);
    return result;
}

/// A complex `base` to a rational or inexact power: an integral flonum is taken by repeated
/// squaring, anything else by `exp` and `log`.
fn exptComplexByFloat(h: *Heap, base: Value, exponent: Value) Error!Value {
    const y = exponent.asFlonum() orelse return complex.expt(h, base, exponent);
    if (!std.math.isFinite(y) or y != @floor(y) or @abs(y) >= 9223372036854775808.0) return complex.expt(h, base, exponent);
    const power = try exptComplex(h, base, @intFromFloat(y));
    return ops.toInexact(h, power);
}

/// A real `base` to a rational or inexact power.
fn exptRealWork(h: *Heap, gpa: std.mem.Allocator, base: Value, exponent: Value) ops.Error!Value {
    const x = try number.toFlonum(gpa, base);
    const y = try number.toFlonum(gpa, exponent);
    if (std.math.isNan(y)) return .fromFlonum(y);
    if (isZero(base)) {
        // 0 の正の累乗は 0、負の累乗は正確な 0 による除算である。
        if (y < 0) return error.DivisionByZero;
        if (y == 0) return .fromFlonum(1.0);
        return if (ops.isExact(exponent)) base else .fromFlonum(0.0);
    }
    if (x < 0 and std.math.isFinite(y) and y != @floor(y)) {
        // 負の実数の整数でない累乗は、極形式 |x|^y (cos(pi y) + i sin(pi y)) の複素数である。
        const magnitude = std.math.pow(f64, -x, y);
        const angle = std.math.pi * y;
        return number.makeRectangular(h, gpa, .fromFlonum(magnitude * @cos(angle)), .fromFlonum(magnitude * @sin(angle)));
    }
    return .fromFlonum(std.math.pow(f64, x, y));
}

fn isZero(v: Value) bool {
    return if (v.asFixnum()) |n| n == 0 else false;
}

fn isNegativeInteger(v: Value) bool {
    if (v.asFixnum()) |n| return n < 0;
    return !v.asBignum().?.toConst().positive;
}

fn isOddInteger(v: Value) bool {
    if (v.asFixnum()) |n| return n & 1 == 1;
    return v.asBignum().?.toConst().limbs[0] & 1 == 1;
}

/// The integer square root of the exact integer `n`, which is not negative: the largest `s`
/// with `s * s <= n` (R7RS 6.2.6 `exact-integer-sqrt`, whose second value is `n - s * s`).
pub fn integerSqrt(h: *Heap, n: Value) Error!Value {
    std.debug.assert(ops.isExactInteger(n));
    std.debug.assert(!isNegativeInteger(n));
    if (n.asFixnum()) |small| return .fromFixnum(smallSqrt(@intCast(small)));
    return ops.counted(Value, integerSqrtWork, h, .{n});
}

/// The integer square root of a number of 63 bits or fewer.
fn smallSqrt(n: u64) i64 {
    var s: u64 = @intFromFloat(@sqrt(@as(f64, @floatFromInt(n))));
    // 浮動小数点の平方根は、平方数の1つ手前の数で、根を1だけ大きく返しうる
    // (9223372030926249000 は 3037000498 の2乗を超えるが、`f64` に丸めると 3037000499 の2乗になる)。
    // 小さく返すことは、63ビット以下の数では起きない(平方数が `f64` に丸められても、
    // 平方根の丸めが根に戻す)。
    while (@as(u128, s) * s > n) s -= 1;
    return @intCast(s);
}

fn integerSqrtWork(h: *Heap, gpa: std.mem.Allocator, n: Value) ops.Error!Value {
    var root = try bigint.sqrt(gpa, n.asBignum().?.toConst());
    defer root.deinit();
    return number.fromInteger(h, root.toConst());
}

/// `(rationalize x y)`: the simplest rational number that differs from `x` by no more than `y`
/// (R7RS 6.2.6).
///
/// 「最も単純」は、分母が最小で、同じ分母なら分子の絶対値が最小の有理数である。`x - |y|` から
/// `x + |y|` までの区間の連分数展開で求める。区間が0をまたぐなら 0 である。引数に flonum が
/// あれば、正確に計算して結果を flonum にする。`y` が無限大なら、`x` が有限のとき 0.0 で、
/// `x` も無限大なら NaN である。`x` が無限大で `y` が有限なら `x` で、NaN があれば NaN である
/// (原文は規定しない)。
pub fn rationalize(h: *Heap, x: Value, y: Value) Error!Value {
    const inexact = x.asFlonum() != null or y.asFlonum() != null;
    if (inexact) {
        const fx = x.asFlonum();
        const fy = y.asFlonum();
        if ((fx != null and std.math.isNan(fx.?)) or (fy != null and std.math.isNan(fy.?))) return .fromFlonum(std.math.nan(f64));
        if (fy != null and std.math.isInf(fy.?)) {
            if (fx != null and std.math.isInf(fx.?)) return .fromFlonum(std.math.nan(f64));
            return .fromFlonum(0.0);
        }
        if (fx != null and std.math.isInf(fx.?)) return x;
    }
    const exact_x = try ops.toExact(h, x);
    var exact_y = try ops.toExact(h, y);
    if ((try ops.compare(h, exact_y, .fromFixnum(0))).? == .lt) exact_y = try ops.negate(h, exact_y);
    const lo = try ops.apply(h, .sub, exact_x, exact_y);
    const hi = try ops.apply(h, .add, exact_x, exact_y);
    const zero: Value = .fromFixnum(0);
    const result: Value = blk: {
        if ((try ops.compare(h, lo, zero)).? == .gt) break :blk try simplestBetween(h, lo, hi);
        if ((try ops.compare(h, hi, zero)).? == .lt) break :blk try ops.negate(h, try simplestBetween(h, try ops.negate(h, hi), try ops.negate(h, lo)));
        break :blk zero;
    };
    return if (inexact) ops.toInexact(h, result) else result;
}

/// The simplest rational number in the closed interval from `lo` to `hi`, `0 < lo <= hi`.
///
/// 連分数の項を前から集め、最後に後ろから畳む。再帰にしないのは、巨大な有理数の連分数が
/// 長く、再帰の深さが入力の大きさに比例するためである。時間の上限ではない(上限に収まる範囲の
/// 時間は、項数と項ごとの簡約の積で伸びる。docs/design/open-questions.md)。
fn simplestBetween(h: *Heap, lo_start: Value, hi_start: Value) Error!Value {
    var terms: std.ArrayList(Value) = .empty;
    defer terms.deinit(h.backing);
    var lo = lo_start;
    var hi = hi_start;
    const one_value: Value = .fromFixnum(1);
    while (true) {
        const floor_lo = try ops.roundNumber(h, .floor, lo);
        if (try ops.numEqual(h, floor_lo, lo)) {
            try terms.append(h.backing, floor_lo);
            break;
        }
        const floor_hi = try ops.roundNumber(h, .floor, hi);
        if ((try ops.compare(h, floor_lo, floor_hi)).? == .lt) {
            try terms.append(h.backing, try ops.apply(h, .add, floor_lo, one_value));
            break;
        }
        // 区間が整数部を共有するなら、小数部の逆数の区間で続ける。
        try terms.append(h.backing, floor_lo);
        const next_lo = try ops.apply(h, .div, one_value, try ops.apply(h, .sub, hi, floor_lo));
        const next_hi = try ops.apply(h, .div, one_value, try ops.apply(h, .sub, lo, floor_lo));
        lo = next_lo;
        hi = next_hi;
    }
    var result = terms.items[terms.items.len - 1];
    var i = terms.items.len - 1;
    while (i > 0) {
        i -= 1;
        result = try ops.apply(h, .add, terms.items[i], try ops.apply(h, .div, one_value, result));
    }
    return result;
}

test {
    std.testing.refAllDecls(@This());
}
