//! Arithmetic and comparison on the real numbers
//! (docs/design/numerics-and-unicode.md の「演算の階層と伝播」).
//!
//! 二項演算は、両オペランドの階層のうち高い方に揃えてから計算する。階層は fixnum、bignum、
//! ratnum、flonum の順である。正確な数と不正確な数の演算は、正確な側を flonum にして計算
//! する(不正確さの伝播。R7RS 6.2.2)。結果の正規化は `number.zig` の生成関数が行うので、
//! このファイルは `Value` の数のバリアントを直接作らない(flonum を除く)。
//!
//! 引数は数(fixnum、bignum、ratnum、flonum、compnum)である。型の検査は呼び出し側
//! (`src/prim/arith.zig`)が行う。順序の比較(`compare`)は実数だけを扱う。
//!
//! 作業領域は、`Heap.Charged` から取り、演算の間だけ上限に照らす(計画書 0018 の
//! 「演算の作業領域」)。断られたら `HeapLimit` になる。作業領域を使わない経路
//! (fixnum 同士、flonum が絡む fixnum)は、計上の準備もしない。

const std = @import("std");
const value_mod = @import("../value.zig");
const heap_mod = @import("../heap.zig");
const bigint = @import("bigint.zig");
const exact = @import("exact.zig");
const number = @import("number.zig");
const tier = @import("../tier.zig");

const Value = value_mod.Value;
const Heap = heap_mod.Heap;
const Const = bigint.Const;
const Managed = bigint.Managed;
const Limb = bigint.Limb;
const Mutable = std.math.big.int.Mutable;

pub const Error = heap_mod.Error || error{DivisionByZero};

/// The four arithmetic operations.
pub const Op = enum { add, sub, mul, div };

/// `a op b`, for numbers of any of the five kinds.
///
/// 除数が正確な0なら、被除数が不正確でも `DivisionByZero` である。`(/ 1 0.0)` は `+inf.0`。
/// 正確な数と不正確な数の積は、正確な側が0でも不正確になる(`(* 0 +inf.0)` は `+nan.0`。
/// R7RS 6.2.6 は0と `+nan.0` のどちらも許す)。
///
/// 複素数は、実部と虚部を実数の演算で計算し、`number.makeRectangular` で正規化する(虚部が
/// 正確な0なら実数、部分の正確性はそろえる)。和と差は部分ごと、積は `(a+bi)(c+di) =
/// (ac-bd) + (ad+bc)i`、商は分母の共役を掛けて `|c+di|^2` で割る。片方が実数のときは、
/// 実数を各部に掛けるか割る(`(* +inf.0+1.0i 2)` が `+inf.0+2.0i` になり、`inf * 0` の
/// `+nan.0` を作らない)。
pub fn apply(h: *Heap, op: Op, a: Value, b: Value) Error!Value {
    std.debug.assert(number.isNumber(a) and number.isNumber(b));
    if (try fastApply(op, a, b)) |v| return v;
    return counted(Value, applyWork, h, .{ op, a, b });
}

fn applyWork(h: *Heap, gpa: std.mem.Allocator, op: Op, a: Value, b: Value) Error!Value {
    if (a.kind() == .compnum or b.kind() == .compnum) return complexApply(h, gpa, op, a, b);
    return applyIn(h, gpa, op, a, b);
}

/// Runs `f(h, gpa, args...)` with a work area from `Heap.Charged`, held to the limit while it
/// runs; a refusal of the work area is `HeapLimit`.
///
/// Why: 作業領域の計上は入れ子になる(`Heap.beginCounting`)。この関数は、作業領域を使う
/// 入口だけが呼ぶ。
fn counted(comptime T: type, comptime f: anytype, h: *Heap, args: anytype) Error!T {
    h.external_refused = false;
    const before = h.beginCounting(true);
    defer h.endCounting(before);
    var charged: heap_mod.Charged = .{ .heap = h, .backing = h.backing };
    return @call(.auto, f, .{ h, charged.allocator() } ++ args) catch |e| switch (e) {
        error.OutOfMemory => if (h.external_refused) error.HeapLimit else error.OutOfMemory,
        else => |other| other,
    };
}

/// The result of an operation on two real numbers that takes no work area (two fixnums with a
/// fixnum result, or a flonum with a number that is exactly an `f64`), or null.
fn fastApply(op: Op, a: Value, b: Value) Error!?Value {
    if (a.asFixnum()) |x| if (b.asFixnum()) |y| if (fixnumOp(op, x, y)) |v| return v;
    if (fastFloat(a)) |x| if (fastFloat(b)) |y| if (a.asFlonum() != null or b.asFlonum() != null) {
        if (op == .div and isExactZero(b)) return error.DivisionByZero;
        return .fromFlonum(floatOp(op, x, y));
    };
    return null;
}

/// `a op b` for two real numbers, inside a work area.
fn realApply(h: *Heap, gpa: std.mem.Allocator, op: Op, a: Value, b: Value) Error!Value {
    if (try fastApply(op, a, b)) |v| return v;
    return applyIn(h, gpa, op, a, b);
}

/// `-a`.
///
/// 不正確な0の符号を保つ(`(- 0.0)` は `-0.0`)。`0 - a` では `0.0` になってしまう。
/// 複素数は、実部と虚部のそれぞれを反転する。
pub fn negate(h: *Heap, a: Value) Error!Value {
    std.debug.assert(number.isNumber(a));
    if (a.asFlonum()) |x| return .fromFlonum(-x);
    if (a.kind() == .compnum) return counted(Value, negateComplex, h, .{a});
    return apply(h, .sub, .fromFixnum(0), a);
}

fn negateComplex(h: *Heap, gpa: std.mem.Allocator, a: Value) Error!Value {
    const c = a.asCompnum().?;
    return number.makeRectangular(h, gpa, try negateReal(h, gpa, c.real), try negateReal(h, gpa, c.imag));
}

fn negateReal(h: *Heap, gpa: std.mem.Allocator, v: Value) Error!Value {
    if (v.asFlonum()) |x| return .fromFlonum(-x);
    return realApply(h, gpa, .sub, .fromFixnum(0), v);
}

/// How `a` and `b` order, or null if they do not (a NaN is among them). Both are real numbers.
///
/// 正確な数と不正確な数は、flonum を正確な有理数にして比べる。`f64` に寄せて比べると、
/// `=` が推移的でなくなる(R7RS 6.2.2 は推移的であることを求める)。
pub fn compare(h: *Heap, a: Value, b: Value) Error!?std.math.Order {
    std.debug.assert(isReal(a) and isReal(b));
    if (a.asFixnum()) |x| if (b.asFixnum()) |y| return std.math.order(x, y);
    if (fastFloat(a)) |x| if (fastFloat(b)) |y| return orderFloat(x, y);
    return counted(?std.math.Order, compareWork, h, .{ a, b });
}

fn compareWork(_: *Heap, gpa: std.mem.Allocator, a: Value, b: Value) Error!?std.math.Order {
    return compareIn(gpa, a, b);
}

/// Whether `a` and `b` are `=` (R7RS 6.2.6), for numbers of any of the five kinds.
///
/// 複素数は、実部どうしと虚部どうしが、どちらも正確な値で等しいときに等しい。実数の虚部は
/// 正確な0である(`(= 1.0+0.0i 1.0)` は真)。NaN を含む部分は等しくない。
pub fn numEqual(h: *Heap, a: Value, b: Value) Error!bool {
    std.debug.assert(number.isNumber(a) and number.isNumber(b));
    if (a.kind() != .compnum and b.kind() != .compnum) return (try compare(h, a, b)) == .eq;
    return counted(bool, numEqualComplex, h, .{ a, b });
}

fn numEqualComplex(_: *Heap, gpa: std.mem.Allocator, a: Value, b: Value) Error!bool {
    const x = partsOf(a);
    const y = partsOf(b);
    if ((try compareIn(gpa, x.re, y.re)) != .eq) return false;
    return (try compareIn(gpa, x.im, y.im)) == .eq;
}

/// The real and the imaginary part of a number; a real number has an exact zero for its
/// imaginary part.
const Parts = struct { re: Value, im: Value };

fn partsOf(v: Value) Parts {
    if (v.asCompnum()) |c| return .{ .re = c.real, .im = c.imag };
    return .{ .re = v, .im = .fromFixnum(0) };
}

fn complexApply(h: *Heap, gpa: std.mem.Allocator, op: Op, a: Value, b: Value) Error!Value {
    const x = partsOf(a);
    const y = partsOf(b);
    const a_complex = a.kind() == .compnum;
    const b_complex = b.kind() == .compnum;
    var re: Value = undefined;
    var im: Value = undefined;
    switch (op) {
        .add, .sub => {
            re = try realApply(h, gpa, op, x.re, y.re);
            // 実数の虚部は正確な0である。0 を足し引きすると、-0.0 の符号が変わるので、
            // 複素数でない側の虚部は演算に加えない。
            im = if (!b_complex)
                x.im
            else if (!a_complex)
                (if (op == .add) y.im else try negateReal(h, gpa, y.im))
            else
                try realApply(h, gpa, op, x.im, y.im);
        },
        .mul => {
            if (!b_complex) {
                re = try realApply(h, gpa, .mul, x.re, b);
                im = try realApply(h, gpa, .mul, x.im, b);
            } else if (!a_complex) {
                re = try realApply(h, gpa, .mul, a, y.re);
                im = try realApply(h, gpa, .mul, a, y.im);
            } else {
                const ac = try realApply(h, gpa, .mul, x.re, y.re);
                const bd = try realApply(h, gpa, .mul, x.im, y.im);
                const ad = try realApply(h, gpa, .mul, x.re, y.im);
                const bc = try realApply(h, gpa, .mul, x.im, y.re);
                re = try realApply(h, gpa, .sub, ac, bd);
                im = try realApply(h, gpa, .add, ad, bc);
            }
        },
        .div => {
            if (!b_complex) {
                re = try realApply(h, gpa, .div, x.re, b);
                im = try realApply(h, gpa, .div, x.im, b);
            } else {
                // (a+bi)/(c+di) = ((ac+bd) + (bc-ad)i) / (c^2+d^2)
                const cc = try realApply(h, gpa, .mul, y.re, y.re);
                const dd = try realApply(h, gpa, .mul, y.im, y.im);
                const norm = try realApply(h, gpa, .add, cc, dd);
                const ac = try realApply(h, gpa, .mul, x.re, y.re);
                const bd = try realApply(h, gpa, .mul, x.im, y.im);
                const bc = try realApply(h, gpa, .mul, x.im, y.re);
                const ad = try realApply(h, gpa, .mul, x.re, y.im);
                re = try realApply(h, gpa, .div, try realApply(h, gpa, .add, ac, bd), norm);
                im = try realApply(h, gpa, .div, try realApply(h, gpa, .sub, bc, ad), norm);
            }
        },
    }
    return number.makeRectangular(h, gpa, re, im);
}

fn isReal(v: Value) bool {
    return switch (v.kind()) {
        .fixnum, .bignum, .ratnum, .flonum => true,
        else => false,
    };
}

fn isExactZero(v: Value) bool {
    return if (v.asFixnum()) |n| n == 0 else false;
}

/// The value of `v` as an `f64` when that takes no allocation and no rounding: a flonum, or a
/// fixnum that is exactly representable.
fn fastFloat(v: Value) ?f64 {
    if (v.asFlonum()) |x| return x;
    if (v.asFixnum()) |n| {
        if (n >= -max_exact_float and n <= max_exact_float) return @floatFromInt(n);
    }
    return null;
}

/// The largest magnitude up to which every integer is an `f64`.
const max_exact_float: i64 = 1 << 53;

fn floatOp(op: Op, x: f64, y: f64) f64 {
    return switch (op) {
        .add => x + y,
        .sub => x - y,
        .mul => x * y,
        .div => x / y,
    };
}

fn orderFloat(x: f64, y: f64) ?std.math.Order {
    if (std.math.isNan(x) or std.math.isNan(y)) return null;
    return std.math.order(x, y);
}

/// `x op y` as a fixnum, or null when the result is not one (an overflow, an inexact quotient, or
/// a zero divisor, which the general path reports).
fn fixnumOp(op: Op, x: i64, y: i64) ?Value {
    switch (op) {
        .add => {
            const r = @addWithOverflow(x, y);
            return if (r[1] == 0) .fromFixnum(r[0]) else null;
        },
        .sub => {
            const r = @subWithOverflow(x, y);
            return if (r[1] == 0) .fromFixnum(r[0]) else null;
        },
        .mul => {
            const r = @mulWithOverflow(x, y);
            return if (r[1] == 0) .fromFixnum(r[0]) else null;
        },
        .div => {
            if (y == 0 or (x == std.math.minInt(i64) and y == -1)) return null;
            return if (@rem(x, y) == 0) .fromFixnum(@divExact(x, y)) else null;
        },
    }
}

fn applyIn(h: *Heap, gpa: std.mem.Allocator, op: Op, a: Value, b: Value) Error!Value {
    if (a.asFlonum() != null or b.asFlonum() != null) {
        // 正確な0の除数は fixnum なので、`apply` の速い経路がすでに断っている。
        std.debug.assert(!(op == .div and isExactZero(b)));
        const x = try number.toFlonum(gpa, a);
        const y = try number.toFlonum(gpa, b);
        return .fromFlonum(floatOp(op, x, y));
    }
    var ra: Rational = undefined;
    ra.set(a);
    var rb: Rational = undefined;
    rb.set(b);
    switch (op) {
        .add, .sub => {
            if (ra.integer and rb.integer) return fromManaged(h, try addOrSub(gpa, op, ra.n, rb.n));
            var left = try bigint.mul(gpa, ra.n, rb.d);
            defer left.deinit();
            var right = try bigint.mul(gpa, rb.n, ra.d);
            defer right.deinit();
            var sum = try addOrSub(gpa, op, left.toConst(), right.toConst());
            defer sum.deinit();
            var d = try bigint.mul(gpa, ra.d, rb.d);
            defer d.deinit();
            return number.makeRatio(h, gpa, sum.toConst(), d.toConst());
        },
        .mul => {
            if (ra.integer and rb.integer) return fromManaged(h, try bigint.mul(gpa, ra.n, rb.n));
            var n = try bigint.mul(gpa, ra.n, rb.n);
            defer n.deinit();
            var d = try bigint.mul(gpa, ra.d, rb.d);
            defer d.deinit();
            return number.makeRatio(h, gpa, n.toConst(), d.toConst());
        },
        .div => {
            if (rb.n.eqlZero()) return error.DivisionByZero;
            var n = try bigint.mul(gpa, ra.n, rb.d);
            defer n.deinit();
            var d = try bigint.mul(gpa, ra.d, rb.n);
            defer d.deinit();
            return number.makeRatio(h, gpa, n.toConst(), d.toConst());
        },
    }
}

fn addOrSub(gpa: std.mem.Allocator, op: Op, a: Const, b: Const) bigint.Error!Managed {
    return if (op == .add) bigint.add(gpa, a, b) else bigint.sub(gpa, a, b);
}

/// The integer in `m` as a number, and `m` given back.
fn fromManaged(h: *Heap, m: Managed) Error!Value {
    var owned = m;
    defer owned.deinit();
    return number.fromInteger(h, owned.toConst());
}

fn compareIn(gpa: std.mem.Allocator, a: Value, b: Value) Error!?std.math.Order {
    if (a.asFlonum()) |x| {
        if (b.asFlonum()) |y| return orderFloat(x, y);
        const reversed = try compareFloatWithExact(gpa, x, b) orelse return null;
        return reversed;
    }
    if (b.asFlonum()) |y| {
        const o = try compareFloatWithExact(gpa, y, a) orelse return null;
        return o.invert();
    }
    var ra: Rational = undefined;
    ra.set(a);
    var rb: Rational = undefined;
    rb.set(b);
    return try orderRational(gpa, ra, rb);
}

/// How the flonum `x` orders against the exact number `e`, or null if `x` is a NaN.
fn compareFloatWithExact(gpa: std.mem.Allocator, x: f64, e: Value) Error!?std.math.Order {
    if (std.math.isNan(x)) return null;
    if (std.math.isInf(x)) return if (x > 0) .gt else .lt;
    var magnitude = try exact.fromF64(gpa, x);
    defer magnitude.deinit();
    if (std.math.signbit(x) and !magnitude.numerator.eqlZero()) magnitude.numerator.negate();
    const rx: Rational = .{ .n = magnitude.numerator.toConst(), .d = magnitude.denominator.toConst(), .integer = false };
    var re: Rational = undefined;
    re.set(e);
    return try orderRational(gpa, rx, re);
}

fn orderRational(gpa: std.mem.Allocator, a: Rational, b: Rational) Error!std.math.Order {
    if (a.integer and b.integer) return a.n.order(b.n);
    var left = try bigint.mul(gpa, a.n, b.d);
    defer left.deinit();
    var right = try bigint.mul(gpa, b.n, a.d);
    defer right.deinit();
    return left.toConst().order(right.toConst());
}

const fixnum_limbs = std.math.big.int.calcTwosCompLimbCount(@bitSizeOf(i64));
const one_limbs = [_]Limb{1};
const one: Const = .{ .limbs = &one_limbs, .positive = true };

/// An exact real number as a numerator and a positive denominator, not necessarily in lowest
/// terms; the limbs of a fixnum are kept in the struct.
const Rational = struct {
    n: Const,
    d: Const,
    integer: bool,
    n_limbs: [fixnum_limbs]Limb = undefined,
    d_limbs: [fixnum_limbs]Limb = undefined,

    /// Makes `self` the exact number `v`: a fixnum, a bignum or a ratnum.
    fn set(self: *Rational, v: Value) void {
        if (v.asRatnum()) |r| {
            self.n = integerConst(r.numerator, &self.n_limbs);
            self.d = integerConst(r.denominator, &self.d_limbs);
            self.integer = false;
        } else {
            self.n = integerConst(v, &self.n_limbs);
            self.d = one;
            self.integer = true;
        }
    }
};

fn integerConst(v: Value, buffer: *[fixnum_limbs]Limb) Const {
    if (v.asFixnum()) |n| return Mutable.init(buffer, n).toConst();
    return v.asBignum().?.toConst();
}

// ---- tests ----

test {
    std.testing.refAllDecls(@This());
}

const testing = std.testing;

fn read(h: *Heap, text: []const u8) !Value {
    return (try number.parse(h, text, 10)) orelse return error.NotANumber;
}

fn show(v: Value) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    errdefer aw.deinit();
    try number.write(&aw.writer, testing.allocator, v, 10);
    return try aw.toOwnedSlice();
}

fn expectOp(h: *Heap, op: Op, a: []const u8, b: []const u8, expected: []const u8) !void {
    const got = try apply(h, op, try read(h, a), try read(h, b));
    const text = try show(got);
    defer testing.allocator.free(text);
    testing.expectEqualStrings(expected, text) catch |e| {
        std.debug.print("({s} {s} {s}): expected {s}, got {s}\n", .{ @tagName(op), a, b, expected, text });
        return e;
    };
}

fn expectOrder(h: *Heap, a: []const u8, b: []const u8, expected: ?std.math.Order) !void {
    const got = try compare(h, try read(h, a), try read(h, b));
    testing.expectEqual(expected, got) catch |e| {
        std.debug.print("(compare {s} {s}): expected {any}, got {any}\n", .{ a, b, expected, got });
        return e;
    };
}

test "fixnum arithmetic stays a fixnum, and overflows into a bignum" {
    var h: Heap = .init(testing.allocator, .{});
    defer h.deinit();
    try expectOp(&h, .add, "1", "2", "3");
    try expectOp(&h, .sub, "1", "2", "-1");
    try expectOp(&h, .mul, "6", "7", "42");
    try expectOp(&h, .add, "9223372036854775807", "1", "9223372036854775808");
    try expectOp(&h, .sub, "-9223372036854775808", "1", "-9223372036854775809");
    try expectOp(&h, .mul, "4294967296", "4294967296", "18446744073709551616");
    try expectOp(&h, .mul, "-9223372036854775808", "-1", "9223372036854775808");
    try expectOp(&h, .div, "-9223372036854775808", "-1", "9223372036854775808");
}

test "a bignum result that fits a fixnum becomes one" {
    var h: Heap = .init(testing.allocator, .{});
    defer h.deinit();
    const big = try read(&h, "9223372036854775808");
    const back = try apply(&h, .sub, big, .fromFixnum(1));
    try testing.expectEqual(value_mod.Kind.fixnum, back.kind());
    try expectOp(&h, .sub, "18446744073709551616", "18446744073709551615", "1");
    try expectOp(&h, .add, "-9223372036854775809", "1", "-9223372036854775808");
    const min = try apply(&h, .add, try read(&h, "-9223372036854775809"), .fromFixnum(1));
    try testing.expectEqual(value_mod.Kind.fixnum, min.kind());
}

test "division of exact numbers makes a ratio in lowest terms, and an integer when it comes to one" {
    var h: Heap = .init(testing.allocator, .{});
    defer h.deinit();
    try expectOp(&h, .div, "1", "2", "1/2");
    try expectOp(&h, .div, "6", "4", "3/2");
    try expectOp(&h, .div, "6", "3", "2");
    try expectOp(&h, .div, "6", "-4", "-3/2");
    try expectOp(&h, .div, "-6", "-4", "3/2");
    try expectOp(&h, .div, "0", "5", "0");
    try expectOp(&h, .div, "18446744073709551616", "18446744073709551616", "1");
    try expectOp(&h, .div, "18446744073709551616", "4", "4611686018427387904");
    try expectOp(&h, .div, "1", "18446744073709551616", "1/18446744073709551616");
    try expectOp(&h, .div, "1/2", "1/3", "3/2");
    try expectOp(&h, .div, "1/2", "-1/2", "-1");
    try expectOp(&h, .div, "3", "1/3", "9");
}

test "addition and multiplication of ratios" {
    var h: Heap = .init(testing.allocator, .{});
    defer h.deinit();
    try expectOp(&h, .add, "1/3", "2/3", "1");
    try expectOp(&h, .add, "1/2", "1/3", "5/6");
    try expectOp(&h, .sub, "1/2", "1/3", "1/6");
    try expectOp(&h, .sub, "1/2", "1/2", "0");
    try expectOp(&h, .add, "1/2", "1", "3/2");
    try expectOp(&h, .add, "1", "-1/2", "1/2");
    try expectOp(&h, .mul, "2/3", "3/2", "1");
    try expectOp(&h, .mul, "2/3", "3", "2");
    try expectOp(&h, .mul, "-1/2", "-1/2", "1/4");
    try expectOp(&h, .mul, "1/18446744073709551616", "18446744073709551616", "1");
    try expectOp(&h, .add, "1/18446744073709551616", "1/18446744073709551616", "1/9223372036854775808");
}

test "an exact number and an inexact number give an inexact number" {
    var h: Heap = .init(testing.allocator, .{});
    defer h.deinit();
    try expectOp(&h, .add, "1", "0.5", "1.5");
    try expectOp(&h, .add, "0.5", "1/2", "1.0");
    try expectOp(&h, .mul, "18446744073709551616", "0.5", "9223372036854776000.0");
    try expectOp(&h, .sub, "1/3", "0.5", "-0.16666666666666669");
    try expectOp(&h, .div, "1", "0.5", "2.0");
    try expectOp(&h, .div, "1", "0.0", "+inf.0");
    try expectOp(&h, .div, "-1", "0.0", "-inf.0");
    try expectOp(&h, .div, "0.0", "0.0", "+nan.0");
    try expectOp(&h, .mul, "0", "+inf.0", "+nan.0");
    try expectOp(&h, .mul, "0", "1.5", "0.0");
    try expectOp(&h, .add, "+inf.0", "-inf.0", "+nan.0");
    try expectOp(&h, .add, "9007199254740993", "0.0", "9007199254740992.0");
}

test "a zero divisor that is exact is an error, whatever the dividend" {
    var h: Heap = .init(testing.allocator, .{});
    defer h.deinit();
    for ([_][]const u8{ "1", "0", "1/2", "1.5", "0.0", "+inf.0", "18446744073709551616" }) |dividend| {
        try testing.expectError(error.DivisionByZero, apply(&h, .div, try read(&h, dividend), .fromFixnum(0)));
    }
    try testing.expectEqual(0, h.external);
    try testing.expect(!h.external_enforced);
}

test "negate keeps the sign of an inexact zero" {
    var h: Heap = .init(testing.allocator, .{});
    defer h.deinit();
    for ([_]struct { []const u8, []const u8 }{
        .{ "0.0", "-0.0" },
        .{ "-0.0", "0.0" },
        .{ "5", "-5" },
        .{ "-9223372036854775808", "9223372036854775808" },
        .{ "9223372036854775808", "-9223372036854775808" },
        .{ "1/2", "-1/2" },
        .{ "0", "0" },
    }) |case| {
        const got = try negate(&h, try read(&h, case[0]));
        const text = try show(got);
        defer testing.allocator.free(text);
        try testing.expectEqualStrings(case[1], text);
    }
}

test "comparing exact numbers" {
    var h: Heap = .init(testing.allocator, .{});
    defer h.deinit();
    try expectOrder(&h, "1", "2", .lt);
    try expectOrder(&h, "2", "1", .gt);
    try expectOrder(&h, "2", "2", .eq);
    try expectOrder(&h, "18446744073709551616", "18446744073709551617", .lt);
    try expectOrder(&h, "-18446744073709551616", "9223372036854775807", .lt);
    try expectOrder(&h, "9223372036854775808", "9223372036854775807", .gt);
    try expectOrder(&h, "1/3", "1/2", .lt);
    try expectOrder(&h, "-1/3", "-1/2", .gt);
    try expectOrder(&h, "1/2", "1", .lt);
    try expectOrder(&h, "3/2", "1", .gt);
    try expectOrder(&h, "18446744073709551616", "37/2", .gt);
    try expectOrder(&h, "1/3", "1/3", .eq);
}

test "comparing exactly across exactness, so that = is transitive" {
    var h: Heap = .init(testing.allocator, .{});
    defer h.deinit();
    // 2^53 + 1 は f64 で表せない。f64 に寄せて比べると、これらが等しくなる。
    try expectOrder(&h, "9007199254740993", "9007199254740992.0", .gt);
    try expectOrder(&h, "9007199254740992.0", "9007199254740993", .lt);
    try expectOrder(&h, "9007199254740992", "9007199254740992.0", .eq);
    // 負の側の境界。-2^53 - 1 も、f64 に寄せると -2^53 と等しくなってしまう。
    try expectOrder(&h, "-9007199254740993", "-9007199254740992.0", .lt);
    try expectOrder(&h, "-9007199254740992.0", "-9007199254740993", .gt);
    try expectOrder(&h, "-9007199254740992", "-9007199254740992.0", .eq);
    try expectOrder(&h, "18446744073709551616", "1.8446744073709552e19", .eq);
    try expectOrder(&h, "18446744073709551617", "1.8446744073709552e19", .gt);
    try expectOrder(&h, "1/3", "0.3333333333333333", .gt);
    try expectOrder(&h, "1/2", "0.5", .eq);
    try expectOrder(&h, "-1/2", "-0.5", .eq);
    try expectOrder(&h, "0", "-0.0", .eq);
    try expectOrder(&h, "0.0", "-0.0", .eq);
    try expectOrder(&h, "1", "1.5", .lt);
    try expectOrder(&h, "-1", "-1.5", .gt);
}

test "comparing with infinities and NaN" {
    var h: Heap = .init(testing.allocator, .{});
    defer h.deinit();
    try expectOrder(&h, "+inf.0", "18446744073709551616", .gt);
    try expectOrder(&h, "-inf.0", "-18446744073709551616", .lt);
    try expectOrder(&h, "18446744073709551616", "+inf.0", .lt);
    try expectOrder(&h, "1/2", "+inf.0", .lt);
    try expectOrder(&h, "5", "-inf.0", .gt);
    try expectOrder(&h, "+inf.0", "+inf.0", .eq);
    try expectOrder(&h, "+inf.0", "-inf.0", .gt);
    try expectOrder(&h, "+nan.0", "1", null);
    try expectOrder(&h, "1", "+nan.0", null);
    try expectOrder(&h, "+nan.0", "+nan.0", null);
    try expectOrder(&h, "+nan.0", "18446744073709551616", null);
    try expectOrder(&h, "1/2", "+nan.0", null);
}

fn expectEqual(h: *Heap, a: []const u8, b: []const u8, expected: bool) !void {
    const got = try numEqual(h, try read(h, a), try read(h, b));
    testing.expectEqual(expected, got) catch |e| {
        std.debug.print("(= {s} {s}): expected {any}, got {any}\n", .{ a, b, expected, got });
        return e;
    };
}

fn expectNegate(h: *Heap, a: []const u8, expected: []const u8) !void {
    const text = try show(try negate(h, try read(h, a)));
    defer testing.allocator.free(text);
    try testing.expectEqualStrings(expected, text);
}

test "complex numbers add and subtract part by part, and become real when the imaginary part is zero" {
    var h: Heap = .init(testing.allocator, .{});
    defer h.deinit();
    try expectOp(&h, .add, "1+2i", "3+4i", "4+6i");
    try expectOp(&h, .sub, "1+2i", "3+4i", "-2-2i");
    try expectOp(&h, .add, "1+2i", "1-2i", "2");
    try expectOp(&h, .sub, "1+2i", "1+2i", "0");
    try expectOp(&h, .add, "1+2i", "3", "4+2i");
    try expectOp(&h, .add, "3", "1+2i", "4+2i");
    try expectOp(&h, .sub, "3", "1+2i", "2-2i");
    try expectOp(&h, .sub, "1+2i", "3", "-2+2i");
    try expectOp(&h, .add, "1/2+1/3i", "1/2-1/3i", "1");
    try expectOp(&h, .add, "18446744073709551616+i", "18446744073709551616-i", "36893488147419103232");
}

test "a complex number with an inexact part gives an inexact one, and an inexact zero part stays" {
    var h: Heap = .init(testing.allocator, .{});
    defer h.deinit();
    try expectOp(&h, .add, "1+2i", "0.5", "1.5+2.0i");
    try expectOp(&h, .add, "1.5+2.5i", "1", "2.5+2.5i");
    try expectOp(&h, .sub, "1.5+2.5i", "1.5+2.5i", "0.0+0.0i");
    try expectOp(&h, .add, "1+2i", "0.5+0.5i", "1.5+2.5i");
    // 複素数でない側の虚部は演算に加えないので、虚部の -0.0 の符号が変わらない。
    try expectOp(&h, .add, "1.0-0.0i", "2", "3.0-0.0i");
    try expectOp(&h, .sub, "1.0-0.0i", "2", "-1.0-0.0i");
    try expectOp(&h, .sub, "2", "1.0+3.0i", "1.0-3.0i");
}

test "complex numbers multiply by the four products, and by a real number part by part" {
    var h: Heap = .init(testing.allocator, .{});
    defer h.deinit();
    try expectOp(&h, .mul, "1+2i", "3+4i", "-5+10i");
    try expectOp(&h, .mul, "1+2i", "1-2i", "5");
    try expectOp(&h, .mul, "+i", "+i", "-1");
    try expectOp(&h, .mul, "1+2i", "2", "2+4i");
    try expectOp(&h, .mul, "2", "1+2i", "2+4i");
    try expectOp(&h, .mul, "1+2i", "0", "0");
    try expectOp(&h, .mul, "0", "1+2i", "0");
    try expectOp(&h, .mul, "1/2+1/3i", "6", "3+2i");
    try expectOp(&h, .mul, "1.5+2.5i", "2", "3.0+5.0i");
    try expectOp(&h, .mul, "18446744073709551616+i", "18446744073709551616-i", "340282366920938463463374607431768211457");
    // 実数を掛けるときは各部に掛けるので、無限大と 0 の積の `+nan.0` を作らない。
    try expectOp(&h, .mul, "+inf.0+1.0i", "2", "+inf.0+2.0i");
    try expectOp(&h, .mul, "2", "+inf.0+1.0i", "+inf.0+2.0i");
}

test "complex numbers divide by the conjugate, and by a real number part by part" {
    var h: Heap = .init(testing.allocator, .{});
    defer h.deinit();
    try expectOp(&h, .div, "1+2i", "3+4i", "11/25+2/25i");
    try expectOp(&h, .div, "1", "+i", "-i");
    try expectOp(&h, .div, "+i", "+i", "1");
    try expectOp(&h, .div, "1+2i", "2", "1/2+i");
    try expectOp(&h, .div, "1+2i", "1+2i", "1");
    try expectOp(&h, .div, "5", "1+2i", "1-2i");
    try expectOp(&h, .div, "1.0+2.0i", "3.0+4.0i", "0.44+0.08i");
    try expectOp(&h, .div, "1.0+2.0i", "2", "0.5+1.0i");
}

test "dividing a complex number by an exact zero is an error, and by an inexact zero is not" {
    var h: Heap = .init(testing.allocator, .{});
    defer h.deinit();
    for ([_][]const u8{ "1+2i", "1.5+2.5i", "18446744073709551616+i" }) |dividend| {
        try testing.expectError(error.DivisionByZero, apply(&h, .div, try read(&h, dividend), .fromFixnum(0)));
    }
    try expectOp(&h, .div, "1.5+2.5i", "0.0", "+inf.0+inf.0i");
    try testing.expectEqual(0, h.external);
    try testing.expect(!h.external_enforced);
}

test "complex arithmetic gives +nan.0 where an exact zero part meets an infinity, and where it divides by a complex zero" {
    // 設計文書に記録した、R7RS が規定しない結果。実数との積の `(* 0 +inf.0)` と同じ扱いである。
    var h: Heap = .init(testing.allocator, .{});
    defer h.deinit();
    try expectOp(&h, .mul, "+i", "+inf.0+1.0i", "+nan.0+inf.0i");
    try expectOp(&h, .div, "+inf.0", "+i", "+nan.0-inf.0i");
    try expectOp(&h, .div, "1+2i", "0.0+0.0i", "+nan.0+nan.0i");
}

test "negating a complex number negates both parts, and keeps the sign of an inexact zero" {
    var h: Heap = .init(testing.allocator, .{});
    defer h.deinit();
    try expectNegate(&h, "1+2i", "-1-2i");
    try expectNegate(&h, "+i", "-i");
    try expectNegate(&h, "1.5-2.5i", "-1.5+2.5i");
    try expectNegate(&h, "1.0+0.0i", "-1.0-0.0i");
    try expectNegate(&h, "1/2+1/3i", "-1/2-1/3i");
    // 実部が不正確な 0 のときも符号を反転する(`0 - z` では 0.0 のままになる)。
    try expectNegate(&h, "0.0+1.0i", "-0.0-1.0i");
}

test "= on complex numbers compares both parts exactly" {
    var h: Heap = .init(testing.allocator, .{});
    defer h.deinit();
    try expectEqual(&h, "1+2i", "1+2i", true);
    try expectEqual(&h, "1+2i", "1+3i", false);
    try expectEqual(&h, "1+2i", "2+2i", false);
    try expectEqual(&h, "1+2i", "1", false);
    try expectEqual(&h, "1", "1+2i", false);
    try expectEqual(&h, "1+2i", "1.0+2.0i", true);
    try expectEqual(&h, "1.0+0.0i", "1.0", true);
    try expectEqual(&h, "1.0-0.0i", "1.0", true);
    try expectEqual(&h, "1", "1.0+0.0i", true);
    try expectEqual(&h, "+nan.0+1.0i", "+nan.0+1.0i", false);
    try expectEqual(&h, "1.0+nan.0i", "1.0+nan.0i", false);
    try expectEqual(&h, "1/2+1/3i", "0.5+0.3333333333333333i", false);
    try expectEqual(&h, "18446744073709551616+i", "18446744073709551616+i", true);
    try expectEqual(&h, "18446744073709551616+i", "18446744073709551617+i", false);
    // 実数どうしは `compare` と同じである。
    try expectEqual(&h, "1", "1.0", true);
    try expectEqual(&h, "+nan.0", "+nan.0", false);
    try expectEqual(&h, "9007199254740993", "9007199254740992.0", false);
}

test "the work area of a complex operation is given back" {
    var h: Heap = .init(testing.allocator, .{});
    defer h.deinit();
    const text = try googol(300);
    defer testing.allocator.free(text);
    const z = try apply(&h, .add, try read(&h, text), try read(&h, "+i"));
    const w = try read(&h, "1/3+1/7i");
    var i: usize = 0;
    while (i < 30) : (i += 1) {
        _ = try apply(&h, .mul, z, z);
        _ = try apply(&h, .div, z, w);
        _ = try apply(&h, .add, z, w);
        _ = try negate(&h, z);
        _ = try numEqual(&h, z, w);
    }
    try testing.expectEqual(0, h.external);
    try testing.expect(!h.external_enforced);
}

fn googol(len: usize) ![]u8 {
    const s = try testing.allocator.alloc(u8, len + 1);
    @memset(s, '0');
    s[0] = '1';
    return s;
}

test "the work area is given back" {
    var h: Heap = .init(testing.allocator, .{});
    defer h.deinit();
    const text = try googol(400);
    defer testing.allocator.free(text);
    const big = try read(&h, text);
    const seven = try read(&h, "7");
    const third = try read(&h, "1/3");
    var i: usize = 0;
    while (i < 50) : (i += 1) {
        _ = try apply(&h, .mul, big, big);
        _ = try apply(&h, .div, big, seven);
        _ = try apply(&h, .add, big, third);
        _ = try compare(&h, big, third);
        _ = try compare(&h, big, try read(&h, "1e300"));
    }
    try testing.expectEqual(0, h.external);
    try testing.expect(!h.external_enforced);
}

test "a limit that refuses the work area gives HeapLimit, and leaves nothing counted" {
    var h: Heap = .init(testing.allocator, .{ .limit = 64 * 1024 });
    defer h.deinit();
    const text = try googol(5000);
    defer testing.allocator.free(text);
    const big = try read(&h, text);
    // 積は、2倍の大きさのlimbsを要する。上限の残りに入らない大きさまで、くり返し掛ける。
    var x = big;
    var refused = false;
    var i: usize = 0;
    while (i < 12) : (i += 1) {
        x = apply(&h, .mul, x, x) catch |e| {
            try testing.expectEqual(error.HeapLimit, e);
            refused = true;
            break;
        };
    }
    try testing.expect(refused);
    try testing.expectEqual(0, h.external);
    try testing.expect(!h.external_enforced);
}

test "a work area beyond the limit is refused even when the result is small" {
    var h: Heap = .init(testing.allocator, .{});
    defer h.deinit();
    const text = try googol(3000);
    defer testing.allocator.free(text);
    const a = try read(&h, text);
    const b = try read(&h, text);
    const ratio_text = try std.fmt.allocPrint(testing.allocator, "1/{s}", .{text});
    defer testing.allocator.free(ratio_text);
    const ratio = try read(&h, ratio_text);
    // 結果(0 と比較の答え)は小さいが、作業領域(limbs)は上限に入らない。
    h.options.limit = h.held() + 256;
    try testing.expectError(error.HeapLimit, apply(&h, .sub, a, b));
    try testing.expectError(error.HeapLimit, compare(&h, a, ratio));
    try testing.expectEqual(0, h.external);
    try testing.expect(!h.external_enforced);
    h.options.limit = heap_mod.default_limit;
    try expectOp(&h, .sub, text, text, "0");
    try testing.expectEqual(std.math.Order.gt, (try compare(&h, a, ratio)).?);
}

test "a backing allocator that fails is OutOfMemory, even after a refusal by the limit" {
    var failing = std.testing.FailingAllocator.init(testing.allocator, .{});
    var h: Heap = .init(failing.allocator(), .{});
    defer h.deinit();
    const text = try googol(3000);
    defer testing.allocator.free(text);
    const a = try read(&h, text);
    const b = try read(&h, text);
    // 数を読むのは、`fail_index` を決める前に済ませる(あとでは読むこと自体が失敗する)。
    const third = try read(&h, "1/3");
    h.options.limit = h.held() + 256;
    try testing.expectError(error.HeapLimit, apply(&h, .mul, a, b));
    h.options.limit = heap_mod.default_limit;
    failing.fail_index = failing.alloc_index;
    try testing.expectError(error.OutOfMemory, apply(&h, .mul, a, b));
    h.options.limit = h.held() + 256;
    try testing.expectError(error.HeapLimit, compare(&h, a, third));
    h.options.limit = heap_mod.default_limit;
    failing.fail_index = failing.alloc_index;
    try testing.expectError(error.OutOfMemory, compare(&h, a, third));
}
