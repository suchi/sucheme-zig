//! Elementary functions of the complex numbers, and the parts of a complex number
//! (docs/design/numerics-and-unicode.md の「複素数の初等関数」).
//!
//! 計算は `f64` の対 `std.math.complex.Complex(f64)` で行い、結果は部分が flonum の複素数
//! (`number.makeRectangular` が正規化する)である。例外は、正確な複素数の `sqrt` と
//! `magnitude` で、結果が正確な数になるときは正確な数を返す。実数の引数で結果が実数に
//! ならないときの関数(負の数の `log`、`[-1, 1]` の外の `asin` と `acos`)も、ここが担う。
//!
//! 引数は数である(型の検査は呼び出し側 `src/prim/` が行う)。作業領域は `ops.counted` を
//! 通して、ヒープの上限に計上する。

const std = @import("std");
const value_mod = @import("../value.zig");
const heap_mod = @import("../heap.zig");
const number = @import("number.zig");
const ops = @import("ops.zig");
const elementary = @import("elementary.zig");

const Value = value_mod.Value;
const Heap = heap_mod.Heap;
const cx = std.math.complex;

pub const Error = elementary.Error;

/// A complex number as a pair of `f64`.
pub const C = cx.Complex(f64);

/// The functions `apply` computes.
pub const Fn = enum { sqrt, exp, log, sin, cos, tan, asin, acos, atan };

/// `f(z)` for a number `z`, as a complex number whose parts are flonums, except that the square
/// root of an exact complex number is exact when it has an exact root.
///
/// 実数の `z` は、結果が複素数になるときだけ渡す(負の数の `log`、`[-1, 1]` の外の `asin` と
/// `acos`、負の数の `sqrt` は呼び出し側が実数の経路で扱う)。実数の `asin` と `acos` の定義域の
/// 外は、R7RS 6.2.6 の式 `-i log(iz + sqrt(1 - z^2))` に実数の `sqrt` と `log` を当てた値を返す
/// (`(asin 2)` は `1.5707963267948966-1.3169578969248166i`)。複素数の型の引数(虚部が不正確な
/// 0 を含む)は、`std.math.complex` の値である。
pub fn apply(h: *Heap, f: Fn, z: Value) Error!Value {
    if (f == .sqrt) if (z.asCompnum()) |c| {
        if (try sqrtExact(h, c.real, c.imag)) |root| return root;
    };
    const is_real = z.kind() != .compnum;
    const c = try toC(h, z);
    const r: C = switch (f) {
        .sqrt => cx.sqrt(c),
        .exp => cx.exp(c),
        .log => try logOf(h, z),
        .sin => cx.sin(c),
        .cos => cx.cos(c),
        .tan => cx.tan(c),
        .atan => cx.atan(c),
        .asin => if (is_real and @abs(c.re) > 1.0) asinOutside(c.re) else cx.asin(c),
        .acos => if (is_real and @abs(c.re) > 1.0) acosOutside(c.re) else cx.acos(c),
    };
    return fromC(h, r);
}

/// `asin x` for a real `x` with `|x| > 1`: `±pi/2 - i sgn(x) acosh |x|`.
fn asinOutside(x: f64) C {
    return .init(std.math.copysign(@as(f64, std.math.pi / 2.0), x), -std.math.copysign(std.math.acosh(@abs(x)), x));
}

/// `acos x` for a real `x` with `|x| > 1`: `pi/2 - asin x`.
fn acosOutside(x: f64) C {
    return .init(if (x > 0) 0.0 else std.math.pi, std.math.copysign(std.math.acosh(@abs(x)), x));
}

/// The natural logarithm of the number `z`, as a pair of `f64`.
///
/// 負の実数は `log |x| + pi i`、`-0.0` も同じ(R7RS 6.2.6 は `(log -0.0)` を `-inf.0+πi` とする)。
/// 正の実数と正確な 0 は、虚部が `0.0` である(`log 0` は `-inf.0`)。複素数は、`log |z|` と
/// 角を成分にする。
pub fn logOf(h: *Heap, z: Value) Error!C {
    if (z.asCompnum()) |c| {
        const re = try elementary.toF64(h, c.real);
        const im = try elementary.toF64(h, c.imag);
        return .init(logAbs(re, im), try elementary.atan2(h, c.imag, c.real));
    }
    const negative = if (z.asFlonum()) |x|
        std.math.signbit(x) and !std.math.isNan(x)
    else
        (try ops.compare(h, z, .fromFixnum(0))).? == .lt;
    const imag: f64 = if (negative) std.math.pi else 0.0;
    if (z.asFlonum()) |x| return .init(@log(@abs(x)), imag);
    if (z.asFixnum()) |n| if (n == 0) return .init(-std.math.inf(f64), imag);
    return .init(try elementary.ln(h, if (negative) try ops.negate(h, z) else z), imag);
}

/// `log |re + im i|`, without overflowing in the sum of the squares.
fn logAbs(re: f64, im: f64) f64 {
    const a = @max(@abs(re), @abs(im));
    const b = @min(@abs(re), @abs(im));
    if (std.math.isNan(re) or std.math.isNan(im)) return if (std.math.isInf(a)) std.math.inf(f64) else std.math.nan(f64);
    if (a == 0) return -std.math.inf(f64);
    if (std.math.isInf(a)) return std.math.inf(f64);
    const ratio = b / a;
    return @log(a) + 0.5 * std.math.log1p(ratio * ratio);
}

/// `log z1 / log z2`, for numbers of which at least one is not a non-negative real number.
pub fn logBase(h: *Heap, z: Value, base: Value) Error!Value {
    return fromC(h, (try logOf(h, z)).div(try logOf(h, base)));
}

/// `z1` raised to the power `z2`, for numbers of which at least one is complex, or the power is not
/// an integer: `exp(z2 log z1)` (R7RS 6.2.6). The result is inexact.
///
/// 底が 0 のとき、指数の実部が正なら 0 で、それ以外は `DivisionByZero` にする(原文は、
/// 0 の `z` 乗を『実部が正なら 0、そうでなければ誤り』とする)。正確な 0 は正確な 0、不正確な 0 は
/// 0.0 を返す。
pub fn expt(h: *Heap, base: Value, exponent: Value) Error!Value {
    if (isZero(base)) {
        const re = if (exponent.asCompnum()) |c| c.real else exponent;
        if ((try ops.compare(h, re, .fromFixnum(0))) != .gt) return error.DivisionByZero;
        return if (base.asFlonum() != null) .fromFlonum(0.0) else base;
    }
    const logarithm = try logOf(h, base);
    return fromC(h, cx.exp(logarithm.mul(try toC(h, exponent))));
}

fn isZero(v: Value) bool {
    if (v.asFlonum()) |x| return x == 0;
    return if (v.asFixnum()) |n| n == 0 else false;
}

/// The exact square root of the exact complex number `re + im i` (`im` is not zero), or null if
/// a part of it is not rational.
///
/// 根は `sqrt((m + re) / 2) + sgn(im) sqrt((m - re) / 2) i` で、`m = sqrt(re^2 + im^2)`。
/// `m` と2つの根がすべて正確な数のときだけ、正確な数を返す。
fn sqrtExact(h: *Heap, re: Value, im: Value) Error!?Value {
    if (re.asFlonum() != null) return null;
    const m = try elementary.exactSqrt(h, try sumOfSquares(h, re, im)) orelse return null;
    const two: Value = .fromFixnum(2);
    const p = try ops.apply(h, .div, try ops.apply(h, .add, m, re), two);
    const q = try ops.apply(h, .div, try ops.apply(h, .sub, m, re), two);
    const real = try elementary.exactSqrt(h, p) orelse return null;
    var imag = try elementary.exactSqrt(h, q) orelse return null;
    if ((try ops.compare(h, im, .fromFixnum(0))).? == .lt) imag = try ops.negate(h, imag);
    return try rectangular(h, real, imag);
}

fn sumOfSquares(h: *Heap, re: Value, im: Value) Error!Value {
    return ops.apply(h, .add, try ops.apply(h, .mul, re, re), try ops.apply(h, .mul, im, im));
}

/// The magnitude of the number `z` (R7RS 6.2.6 `magnitude`).
///
/// 実数は `abs` と同じ。正確な複素数は `sqrt(re^2 + im^2)` で、平方数なら正確な数(`(magnitude 3+4i)`
/// は 5)。不正確な複素数は `hypot`。
pub fn magnitude(h: *Heap, z: Value) Error!Value {
    const c = z.asCompnum() orelse return ops.absNumber(h, z);
    if (c.real.asFlonum()) |re| return .fromFlonum(std.math.hypot(re, c.imag.asFlonum().?));
    return elementary.sqrt(h, try sumOfSquares(h, c.real, c.imag));
}

/// The angle of the number `z` in radians, from `-pi` to `pi` (R7RS 6.2.6 `angle`).
///
/// 正の実数と 0 の角は、正確な数なら正確な 0、flonum なら `0.0` である。負の実数の角は
/// `pi`(flonum)。`-0.0` の角は `pi`(原文の `(atan` の表で `y = +0.0`、`x = -0.0` の行)。
pub fn angle(h: *Heap, z: Value) Error!Value {
    if (z.asCompnum()) |c| return .fromFlonum(try elementary.atan2(h, c.imag, c.real));
    // `atan2(+0.0, x)`。定数の引数で `atan2` を展開すると、wasm32 の LLVM が定数プールを選べず
    // 異常終了するので、場合分けで書く。
    if (z.asFlonum()) |x| return .fromFlonum(if (std.math.isNan(x)) x else if (std.math.signbit(x)) std.math.pi else 0.0);
    if ((try ops.compare(h, z, .fromFixnum(0))).? == .lt) return .fromFlonum(std.math.pi);
    return .fromFixnum(0);
}

/// The `f64` pair of the number `z`.
fn toC(h: *Heap, z: Value) Error!C {
    if (z.asCompnum()) |c| return .init(try elementary.toF64(h, c.real), try elementary.toF64(h, c.imag));
    return .init(try elementary.toF64(h, z), 0.0);
}

/// The complex number with the flonum parts of `c`.
fn fromC(h: *Heap, c: C) Error!Value {
    return rectangular(h, .fromFlonum(c.re), .fromFlonum(c.im));
}

pub fn rectangular(h: *Heap, re: Value, im: Value) Error!Value {
    return ops.counted(Value, rectangularWork, h, .{ re, im });
}

fn rectangularWork(h: *Heap, gpa: std.mem.Allocator, re: Value, im: Value) number.Error!Value {
    return number.makeRectangular(h, gpa, re, im);
}

test {
    std.testing.refAllDecls(@This());
}

const test_support = @import("../prim/test_support.zig");

test "the exact square root of an exact complex number is exact only when its parts are rational" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    const h = &f.heap;
    const exact = (try number.parse(h, "3+4i", 10)).?;
    const root = try apply(h, .sqrt, exact);
    try std.testing.expect(root.asCompnum().?.real.asFlonum() == null);
    const inexact = (try number.parse(h, "1+2i", 10)).?;
    try std.testing.expect((try apply(h, .sqrt, inexact)).asCompnum().?.real.asFlonum() != null);
}

test "the angle of a real number follows its sign" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    const h = &f.heap;
    try std.testing.expectEqual(0, (try angle(h, .fromFixnum(3))).asFixnum().?);
    try std.testing.expectEqual(std.math.pi, (try angle(h, .fromFixnum(-3))).asFlonum().?);
    try std.testing.expectEqual(std.math.pi, (try angle(h, .fromFlonum(-0.0))).asFlonum().?);
    try std.testing.expect(std.math.isNan((try angle(h, .fromFlonum(std.math.nan(f64)))).asFlonum().?));
}
