//! Number primitives of R7RS 6.2.6 that look at one number (or at the extremes of several):
//! the type predicates, `exact` and `inexact`, the roundings, `numerator` and `denominator`,
//! `max` and `min`, `expt`, `rationalize`, and the root behind `exact-integer-sqrt`.
//!
//! 計算は `num/ops.zig` が行う。ここは、引数の型の検査と、誤りの対応を持つ。型の述語は
//! 数でない引数にも使え、偽を返す。そのほかは、数でない引数を `WrongType` にする。
//! 引数の型は、値によらず、すべての引数について先に検査する(`arith.zig` の方針)。

const std = @import("std");
const value = @import("../value.zig");
const Value = value.Value;
const Primitive = value.Primitive;
const Services = value.Services;
const PrimitiveError = value.PrimitiveError;
const number = @import("../num/number.zig");
const ops = @import("../num/ops.zig");
const power = @import("../num/power.zig");

pub const Error = PrimitiveError;

pub const primitives = [_]Primitive{
    .{ .name = "complex?", .min_args = 1, .max_args = 1, .body = .{ .pure = &isComplex } },
    .{ .name = "real?", .min_args = 1, .max_args = 1, .body = .{ .pure = &isReal } },
    .{ .name = "rational?", .min_args = 1, .max_args = 1, .body = .{ .pure = &isRational } },
    .{ .name = "integer?", .min_args = 1, .max_args = 1, .body = .{ .pure = &isInteger } },
    .{ .name = "exact-integer?", .min_args = 1, .max_args = 1, .body = .{ .pure = &isExactInteger } },
    .{ .name = "exact?", .min_args = 1, .max_args = 1, .body = .{ .pure = &isExact } },
    .{ .name = "inexact?", .min_args = 1, .max_args = 1, .body = .{ .pure = &isInexact } },
    .{ .name = "exact", .min_args = 1, .max_args = 1, .body = .{ .pure = &exactOf } },
    .{ .name = "inexact", .min_args = 1, .max_args = 1, .body = .{ .pure = &inexactOf } },
    .{ .name = "floor", .min_args = 1, .max_args = 1, .body = .{ .pure = rounding(.floor) } },
    .{ .name = "ceiling", .min_args = 1, .max_args = 1, .body = .{ .pure = rounding(.ceiling) } },
    .{ .name = "truncate", .min_args = 1, .max_args = 1, .body = .{ .pure = rounding(.truncate) } },
    .{ .name = "round", .min_args = 1, .max_args = 1, .body = .{ .pure = rounding(.round) } },
    .{ .name = "numerator", .min_args = 1, .max_args = 1, .body = .{ .pure = &numeratorOf } },
    .{ .name = "denominator", .min_args = 1, .max_args = 1, .body = .{ .pure = &denominatorOf } },
    .{ .name = "max", .min_args = 1, .max_args = null, .body = .{ .pure = extremeOf(.max) } },
    .{ .name = "min", .min_args = 1, .max_args = null, .body = .{ .pure = extremeOf(.min) } },
    .{ .name = "expt", .min_args = 2, .max_args = 2, .body = .{ .pure = &exptOf } },
    .{ .name = "rationalize", .min_args = 2, .max_args = 2, .body = .{ .pure = &rationalizeOf } },
    .{ .name = "%exact-integer-sqrt", .min_args = 1, .max_args = 1, .body = .{ .pure = &integerSqrtOf } },
};

/// `(complex? obj)`: true of every number. A real number is complex (R7RS 6.2.6).
fn isComplex(_: *const Services, args: []const Value) Error!Value {
    return .fromBool(number.isNumber(args[0]));
}

/// `(real? obj)`: true of a number with no imaginary part.
///
/// 虚部が不正確な0の複素数は、実数でない(`(real? -2.5+0.0i)` は偽。R7RS 6.2.6)。
fn isReal(_: *const Services, args: []const Value) Error!Value {
    return .fromBool(ops.isRealNumber(args[0]));
}

/// `(rational? obj)`: true of an exact real number and of a finite flonum.
fn isRational(_: *const Services, args: []const Value) Error!Value {
    return .fromBool(ops.isRationalNumber(args[0]));
}

/// `(integer? obj)`: true of an exact integer and of a finite flonum with an integral value.
fn isInteger(_: *const Services, args: []const Value) Error!Value {
    return .fromBool(ops.isIntegerNumber(args[0]));
}

/// `(exact-integer? obj)`: true of a fixnum and of a bignum.
fn isExactInteger(_: *const Services, args: []const Value) Error!Value {
    return .fromBool(ops.isExactInteger(args[0]));
}

/// `(exact? z)`: it is an error if `z` is not a number (R7RS 6.2.6).
fn isExact(_: *const Services, args: []const Value) Error!Value {
    if (!number.isNumber(args[0])) return error.WrongType;
    return .fromBool(ops.isExact(args[0]));
}

/// `(inexact? z)`: it is an error if `z` is not a number.
fn isInexact(_: *const Services, args: []const Value) Error!Value {
    if (!number.isNumber(args[0])) return error.WrongType;
    return .fromBool(!ops.isExact(args[0]));
}

/// `(exact z)`: an infinity and a NaN have no exact value, which is `OutOfRange`.
fn exactOf(services: *const Services, args: []const Value) Error!Value {
    if (!number.isNumber(args[0])) return error.WrongType;
    return ops.toExact(services.heap, args[0]);
}

/// `(inexact z)`.
fn inexactOf(services: *const Services, args: []const Value) Error!Value {
    if (!number.isNumber(args[0])) return error.WrongType;
    return ops.toInexact(services.heap, args[0]);
}

/// `(floor x)`, `(ceiling x)`, `(truncate x)` and `(round x)`: `x` is a real number.
fn rounding(comptime mode: ops.Rounding) Primitive.Fn {
    return &struct {
        fn call(services: *const Services, args: []const Value) Error!Value {
            if (!ops.isRealNumber(args[0])) return error.WrongType;
            return ops.roundNumber(services.heap, mode, args[0]);
        }
    }.call;
}

/// `(numerator q)`: `q` is a rational number. A flonum that is not finite is `OutOfRange`.
fn numeratorOf(services: *const Services, args: []const Value) Error!Value {
    try requireRational(args[0]);
    return ops.numeratorOf(services.heap, args[0]);
}

/// `(denominator q)`.
fn denominatorOf(services: *const Services, args: []const Value) Error!Value {
    try requireRational(args[0]);
    return ops.denominatorOf(services.heap, args[0]);
}

/// A rational number is taken. An infinity and a NaN are the right type but have no numerator,
/// which is `OutOfRange`; anything that is not a real number is `WrongType`.
fn requireRational(v: Value) Error!void {
    if (!ops.isRealNumber(v)) return error.WrongType;
    if (!ops.isRationalNumber(v)) return error.OutOfRange;
}

/// `(max x1 x2 ...)` and `(min x1 x2 ...)`: the arguments are real numbers.
fn extremeOf(comptime end: ops.End) Primitive.Fn {
    return &struct {
        fn call(services: *const Services, args: []const Value) Error!Value {
            for (args) |a| if (!ops.isRealNumber(a)) return error.WrongType;
            return ops.extreme(services.heap, end, args);
        }
    }.call;
}

/// `(expt z1 z2)`: both are numbers.
fn exptOf(services: *const Services, args: []const Value) Error!Value {
    for (args) |a| if (!number.isNumber(a)) return error.WrongType;
    return power.expt(services.heap, args[0], args[1]);
}

/// `(rationalize x y)`: both are real numbers.
fn rationalizeOf(services: *const Services, args: []const Value) Error!Value {
    for (args) |a| if (!ops.isRealNumber(a)) return error.WrongType;
    return power.rationalize(services.heap, args[0], args[1]);
}

/// `(%exact-integer-sqrt k)`: the root of the exact non-negative integer `k`.
///
/// 2つの値を返す `exact-integer-sqrt` は、純粋なプリミティブでは書けないので、
/// `lib/sucheme/procedures.scm` が、この根と `k - root * root` を `values` に包む。
fn integerSqrtOf(services: *const Services, args: []const Value) Error!Value {
    const k = args[0];
    if (!ops.isExactInteger(k)) return error.WrongType;
    if ((try ops.compare(services.heap, k, .fromFixnum(0))).? == .lt) return error.WrongType;
    return power.integerSqrt(services.heap, k);
}

test {
    std.testing.refAllDecls(@This());
}

const test_support = @import("test_support.zig");

/// Calls `name` with the numbers written as `texts`, and expects the result to be written as
/// `expected`; or, for `expected` of `#t` or `#f`, to be that boolean.
fn expectCall(expected: []const u8, name: []const u8, texts: []const []const u8) !void {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    var args: [8]Value = undefined;
    for (texts, 0..) |t, i| args[i] = (try number.parse(f.services.heap, t, 10)) orelse return error.NotANumber;
    const v = try f.call(&primitives, name, args[0..texts.len]);
    if (v.kind() == .boolean) {
        try std.testing.expectEqualStrings(expected, if (v.isTrue()) "#t" else "#f");
        return;
    }
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try number.write(&aw.writer, std.testing.allocator, v, 10);
    try std.testing.expectEqualStrings(expected, aw.written());
}

/// Calls `name` with `args`, which are not all numbers.
fn callWith(name: []const u8, args: []const Value) Error!Value {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    return f.call(&primitives, name, args);
}

test "the primitives take the numbers of arguments the language gives them" {
    const Arity = struct { name: []const u8, min: u8, max: ?u8 };
    const expected = [_]Arity{
        .{ .name = "complex?", .min = 1, .max = 1 },
        .{ .name = "real?", .min = 1, .max = 1 },
        .{ .name = "rational?", .min = 1, .max = 1 },
        .{ .name = "integer?", .min = 1, .max = 1 },
        .{ .name = "exact-integer?", .min = 1, .max = 1 },
        .{ .name = "exact?", .min = 1, .max = 1 },
        .{ .name = "inexact?", .min = 1, .max = 1 },
        .{ .name = "exact", .min = 1, .max = 1 },
        .{ .name = "inexact", .min = 1, .max = 1 },
        .{ .name = "floor", .min = 1, .max = 1 },
        .{ .name = "ceiling", .min = 1, .max = 1 },
        .{ .name = "truncate", .min = 1, .max = 1 },
        .{ .name = "round", .min = 1, .max = 1 },
        .{ .name = "numerator", .min = 1, .max = 1 },
        .{ .name = "denominator", .min = 1, .max = 1 },
        .{ .name = "max", .min = 1, .max = null },
        .{ .name = "min", .min = 1, .max = null },
        .{ .name = "expt", .min = 2, .max = 2 },
        .{ .name = "rationalize", .min = 2, .max = 2 },
        .{ .name = "%exact-integer-sqrt", .min = 1, .max = 1 },
    };
    try std.testing.expectEqual(expected.len, primitives.len);
    for (expected, 0..) |e, i| {
        try std.testing.expect(i < primitives.len);
        const p = primitives[i];
        try std.testing.expectEqualStrings(e.name, p.name);
        try std.testing.expectEqual(e.min, p.min_args);
        try std.testing.expectEqual(e.max, p.max_args);
    }
}

test "the type predicates are true or false of anything, and agree with R7RS 6.2.6" {
    // R7RS 6.2.6 の例。
    try expectCall("#t", "complex?", &.{"3+4i"});
    try expectCall("#t", "complex?", &.{"3"});
    try expectCall("#t", "real?", &.{"3"});
    try expectCall("#t", "real?", &.{"-2.5"});
    try expectCall("#f", "real?", &.{"-2.5+0.0i"});
    try expectCall("#f", "real?", &.{"3+4i"});
    try expectCall("#t", "real?", &.{"+inf.0"});
    try expectCall("#t", "rational?", &.{"6/10"});
    try expectCall("#f", "rational?", &.{"-inf.0"});
    try expectCall("#f", "rational?", &.{"+nan.0"});
    try expectCall("#t", "rational?", &.{"3.5"});
    try expectCall("#t", "integer?", &.{"3+0i"});
    try expectCall("#t", "integer?", &.{"3.0"});
    try expectCall("#t", "integer?", &.{"8/4"});
    try expectCall("#f", "integer?", &.{"3.5"});
    try expectCall("#f", "integer?", &.{"+inf.0"});
    try expectCall("#t", "exact-integer?", &.{"32"});
    try expectCall("#t", "exact-integer?", &.{"18446744073709551616"});
    try expectCall("#f", "exact-integer?", &.{"32.0"});
    try expectCall("#f", "exact-integer?", &.{"32/5"});
    for ([_]Value{ .unspecified_value, .fromBool(true), .empty_list_value, .fromCharacter('a') }) |v| {
        for ([_][]const u8{ "complex?", "real?", "rational?", "integer?", "exact-integer?" }) |name| {
            const r = try callWith(name, &.{v});
            try std.testing.expectEqual(.boolean, r.kind());
            try std.testing.expect(!r.isTrue());
        }
    }
}

test "exact? and inexact? are R7RS 6.2.6's, and an error for what is not a number" {
    try expectCall("#f", "exact?", &.{"3.0+4i"});
    try expectCall("#t", "exact?", &.{"3+4i"});
    try expectCall("#t", "exact?", &.{"1/3"});
    try expectCall("#f", "exact?", &.{"3.0"});
    try expectCall("#t", "inexact?", &.{"3.0"});
    try expectCall("#f", "inexact?", &.{"18446744073709551616"});
    try std.testing.expectError(error.WrongType, callWith("exact?", &.{.unspecified_value}));
    try std.testing.expectError(error.WrongType, callWith("inexact?", &.{.empty_list_value}));
}

test "exact and inexact convert, and exact refuses what has no exact value" {
    try expectCall("1/2", "exact", &.{"0.5"});
    try expectCall("3/2+5/2i", "exact", &.{"1.5+2.5i"});
    try expectCall("7", "exact", &.{"7"});
    try expectCall("0.3333333333333333", "inexact", &.{"1/3"});
    try expectCall("1.0+2.0i", "inexact", &.{"1+2i"});
    try expectCall("9007199254740992.0", "inexact", &.{"9007199254740993"});
    for ([_][]const u8{ "+inf.0", "-inf.0", "+nan.0" }) |text| {
        var f: test_support.Fixture = undefined;
        f.init();
        defer f.deinit();
        const v = (try number.parse(f.services.heap, text, 10)).?;
        try std.testing.expectError(error.OutOfRange, f.call(&primitives, "exact", &.{v}));
    }
    try std.testing.expectError(error.WrongType, callWith("exact", &.{.unspecified_value}));
    try std.testing.expectError(error.WrongType, callWith("inexact", &.{.fromBool(false)}));
}

test "the roundings, with the examples of R7RS 6.2.6" {
    try expectCall("-5.0", "floor", &.{"-4.3"});
    try expectCall("-4.0", "ceiling", &.{"-4.3"});
    try expectCall("-4.0", "truncate", &.{"-4.3"});
    try expectCall("-4.0", "round", &.{"-4.3"});
    try expectCall("3.0", "floor", &.{"3.5"});
    try expectCall("4.0", "ceiling", &.{"3.5"});
    try expectCall("3.0", "truncate", &.{"3.5"});
    try expectCall("4.0", "round", &.{"3.5"});
    try expectCall("4", "round", &.{"7/2"});
    try expectCall("7", "round", &.{"7"});
    try expectCall("2", "round", &.{"5/2"});
    try expectCall("3", "floor", &.{"7/2"});
    try expectCall("-4", "floor", &.{"-7/2"});
}

test "the roundings take a real number only" {
    for ([_][]const u8{ "floor", "ceiling", "truncate", "round" }) |name| {
        try std.testing.expectError(error.WrongType, callWith(name, &.{.unspecified_value}));
        var f: test_support.Fixture = undefined;
        f.init();
        defer f.deinit();
        const z = (try number.parse(f.services.heap, "1+2i", 10)).?;
        try std.testing.expectError(error.WrongType, f.call(&primitives, name, &.{z}));
    }
}

test "numerator and denominator, with the examples of R7RS 6.2.6" {
    try expectCall("3", "numerator", &.{"6/4"});
    try expectCall("2", "denominator", &.{"6/4"});
    try expectCall("2.0", "denominator", &.{"0.5"});
    try expectCall("1.0", "denominator", &.{"6.0"});
    try expectCall("1", "denominator", &.{"0"});
    try expectCall("1", "denominator", &.{"3"});
    try expectCall("0", "numerator", &.{"0"});
    for ([_][]const u8{ "numerator", "denominator" }) |name| {
        var f: test_support.Fixture = undefined;
        f.init();
        defer f.deinit();
        for ([_][]const u8{ "+inf.0", "-inf.0", "+nan.0" }) |text| {
            const bad = (try number.parse(f.services.heap, text, 10)).?;
            try std.testing.expectError(error.OutOfRange, f.call(&primitives, name, &.{bad}));
        }
        const z = (try number.parse(f.services.heap, "1+2i", 10)).?;
        try std.testing.expectError(error.WrongType, f.call(&primitives, name, &.{z}));
        try std.testing.expectError(error.WrongType, callWith(name, &.{.unspecified_value}));
    }
}

test "max and min, with the examples of R7RS 6.2.6" {
    try expectCall("4", "max", &.{ "3", "4" });
    try expectCall("4.0", "max", &.{ "3", "4.0" });
    try expectCall("3", "min", &.{ "3", "4" });
    try expectCall("3.0", "min", &.{ "3", "4.0" });
    try expectCall("5", "max", &.{"5"});
    try expectCall("1/3", "min", &.{ "1/2", "1/3", "1/2" });
}

test "max and min check the type of every argument first" {
    for ([_][]const u8{ "max", "min" }) |name| {
        const args = [_]Value{ .fromFixnum(2), .fromFixnum(1), .unspecified_value };
        try std.testing.expectError(error.WrongType, callWith(name, &args));
        var f: test_support.Fixture = undefined;
        f.init();
        defer f.deinit();
        const z = (try number.parse(f.services.heap, "1+2i", 10)).?;
        try std.testing.expectError(error.WrongType, f.call(&primitives, name, &.{ .fromFixnum(1), z }));
    }
}

const big_odd = "18446744073709551617"; // 2^64 + 1
const big_even = "18446744073709551616"; // 2^64

test "expt of an exact base and an exact integer exponent is exact" {
    try expectCall("1024", "expt", &.{ "2", "10" });
    try expectCall("1/1024", "expt", &.{ "2", "-10" });
    try expectCall("1/4", "expt", &.{ "1/2", "2" });
    try expectCall("4", "expt", &.{ "1/2", "-2" });
    try expectCall("-8", "expt", &.{ "-2", "3" });
    try expectCall("16", "expt", &.{ "-2", "4" });
    try expectCall("-1/8", "expt", &.{ "-2", "-3" });
    try expectCall("1267650600228229401496703205376", "expt", &.{ "2", "100" });
    try expectCall("100000000000000000000", "expt", &.{ "10", "20" });
    try expectCall("9/4", "expt", &.{ "-3/2", "2" });
    try expectCall("-27/8", "expt", &.{ "-3/2", "3" });
    try expectCall("4/9", "expt", &.{ "-3/2", "-2" });
    try expectCall("-8/27", "expt", &.{ "-3/2", "-3" });
}

test "expt of any base to the exact power 0 is the exact 1" {
    for ([_][]const u8{ "5", "0", "-3", "1/2", "2.5", "+nan.0", "+inf.0", "1+2i", big_even }) |base| {
        try expectCall("1", "expt", &.{ base, "0" });
    }
}

test "expt of 0, 1 and -1 is computed for any integer exponent" {
    try expectCall("0", "expt", &.{ "0", "5" });
    try expectCall("0", "expt", &.{ "0", big_even });
    try expectCall("1", "expt", &.{ "1", big_even });
    try expectCall("1", "expt", &.{ "1", "-" ++ big_even });
    try expectCall("1", "expt", &.{ "-1", big_even });
    try expectCall("-1", "expt", &.{ "-1", big_odd });
    try expectCall("-1", "expt", &.{ "-1", "-" ++ big_odd });
    try expectCall("-1", "expt", &.{ "-1", "7" });
    try expectCall("1", "expt", &.{ "-1", "-8" });
}

test "expt of exact 0 to a negative power is a division by zero" {
    for ([_][]const u8{ "-1", "-" ++ big_even, "-1/2" }) |e| {
        var f: test_support.Fixture = undefined;
        f.init();
        defer f.deinit();
        const zero: Value = .fromFixnum(0);
        const exponent = (try number.parse(f.services.heap, e, 10)).?;
        try std.testing.expectError(error.DivisionByZero, f.call(&primitives, "expt", &.{ zero, exponent }));
    }
}

test "expt of a flonum, or to a flonum or a rational power, is a flonum" {
    try expectCall("8.0", "expt", &.{ "2.0", "3" });
    try expectCall("0.125", "expt", &.{ "2.0", "-3" });
    try expectCall("6.25", "expt", &.{ "2.5", "2" });
    try expectCall("1.4142135623730951", "expt", &.{ "2", "0.5" });
    try expectCall("2.0", "expt", &.{ "4", "1/2" });
    try expectCall("8.0", "expt", &.{ "2", "3.0" });
    try expectCall("-8.0", "expt", &.{ "-2", "3.0" });
    try expectCall("4.0", "expt", &.{ "-2.0", "2" });
    try expectCall("+inf.0", "expt", &.{ "+inf.0", "2" });
    try expectCall("0.0", "expt", &.{ "+inf.0", "-2" });
    try expectCall("+nan.0", "expt", &.{ "2", "+nan.0" });
    try expectCall("+nan.0", "expt", &.{ "1", "+nan.0" });
    try expectCall("+nan.0", "expt", &.{ "0", "+nan.0" });
    try expectCall("0.0", "expt", &.{ "-0.0", "1/2" });
    try expectCall("+inf.0", "expt", &.{ "10.0", "400" });
    try expectCall("+inf.0", "expt", &.{ "10.0", big_even });
}

test "expt of exact 0 to a positive rational or inexact power" {
    try expectCall("0", "expt", &.{ "0", "1/2" });
    try expectCall("0.0", "expt", &.{ "0", "0.5" });
    try expectCall("1.0", "expt", &.{ "0", "0.0" });
    try expectCall("0.0", "expt", &.{ "0.0", "2" });
}

test "expt of a negative number to a power that is not an integer is a complex number" {
    // 負の数の累乗は、極形式 |x|^y (cos(pi y) + i sin(pi y)) である。
    try expectCall("6.123233995736766e-17+1.0i", "expt", &.{ "-1", "1/2" });
    try expectCall("-1.0", "expt", &.{ "-1", "1.0" });
}

test "expt of a complex base is repeated multiplication for an integer power" {
    try expectCall("-3+4i", "expt", &.{ "1+2i", "2" });
    try expectCall("1/5-2/5i", "expt", &.{ "1+2i", "-1" });
    try expectCall("1", "expt", &.{ "+i", "4" });
    try expectCall("-i", "expt", &.{ "+i", "3" });
    try expectCall("-3.0+4.0i", "expt", &.{ "1+2i", "2.0" });
    try expectCall("-3.0+4.0i", "expt", &.{ "1.0+2.0i", "2" });
}

test "expt takes only a few kinds of complex arguments" {
    for ([_][2][]const u8{
        .{ "1+2i", "0.5" },
        .{ "1+2i", "1/2" },
        .{ "1+2i", "+inf.0" },
        .{ "1+2i", "1+i" },
        .{ "2", "+i" },
        .{ "1+2i", "2.5" },
    }) |case| {
        var f: test_support.Fixture = undefined;
        f.init();
        defer f.deinit();
        const a = (try number.parse(f.services.heap, case[0], 10)).?;
        const b = (try number.parse(f.services.heap, case[1], 10)).?;
        try std.testing.expectError(error.WrongType, f.call(&primitives, "expt", &.{ a, b }));
    }
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    const z = (try number.parse(f.services.heap, "+i", 10)).?;
    try std.testing.expectError(error.OutOfRange, f.call(&primitives, "expt", &.{ z, (try number.parse(f.services.heap, big_even, 10)).? }));
    try std.testing.expectError(error.WrongType, callWith("expt", &.{ .unspecified_value, .fromFixnum(2) }));
    try std.testing.expectError(error.WrongType, callWith("expt", &.{ .fromFixnum(2), .fromBool(true) }));
}

test "expt refuses a power too large to hold before it allocates" {
    for ([_][2][]const u8{
        .{ "2", "1000000000000" },
        .{ "2", big_even },
        .{ "-3", big_odd },
        .{ "1/2", "1000000000000" },
        .{ "2", "4000000000" },
        .{ "3", "-4000000000" },
    }) |case| {
        var f: test_support.Fixture = undefined;
        f.init();
        defer f.deinit();
        const a = (try number.parse(f.services.heap, case[0], 10)).?;
        const b = (try number.parse(f.services.heap, case[1], 10)).?;
        try std.testing.expectError(error.HeapLimit, f.call(&primitives, "expt", &.{ a, b }));
    }
}

test "rationalize finds the simplest rational within the distance" {
    try expectCall("1/3", "rationalize", &.{ "3/10", "1/10" });
    try expectCall("1/3", "rationalize", &.{ "1/3", "0" });
    try expectCall("0", "rationalize", &.{ "1/3", "1/3" });
    try expectCall("0", "rationalize", &.{ "1/10", "1/2" });
    try expectCall("1", "rationalize", &.{ "3/4", "1/4" });
    try expectCall("-1/3", "rationalize", &.{ "-3/10", "1/10" });
    try expectCall("1/3", "rationalize", &.{ "3/10", "-1/10" });
    try expectCall("7", "rationalize", &.{ "7", "0" });
    try expectCall("22/7", "rationalize", &.{ "314/100", "1/100" });
    try expectCall("333/106", "rationalize", &.{ "3141592/1000000", "1/10000" });
    try expectCall("5", "rationalize", &.{ "11/2", "1/2" });
}

test "rationalize of an inexact argument is inexact" {
    // R7RS 6.2.6 の例。
    try expectCall("0.3333333333333333", "rationalize", &.{ "0.3", "1/10" });
    try expectCall("1/3", "rationalize", &.{ "3/10", "1/10" });
    try expectCall("0.0", "rationalize", &.{ "0.5", "1.0" });
    try expectCall("0.5", "rationalize", &.{ "1/2", "0.0" });
    try expectCall("+nan.0", "rationalize", &.{ "+nan.0", "1" });
    try expectCall("+nan.0", "rationalize", &.{ "1", "+nan.0" });
    try expectCall("0.0", "rationalize", &.{ "5", "+inf.0" });
    try expectCall("+nan.0", "rationalize", &.{ "+inf.0", "+inf.0" });
    try expectCall("+inf.0", "rationalize", &.{ "+inf.0", "3" });
    try expectCall("-inf.0", "rationalize", &.{ "-inf.0", "3.0" });
}

test "rationalize takes only real numbers" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    const z = (try number.parse(f.services.heap, "1+2i", 10)).?;
    try std.testing.expectError(error.WrongType, f.call(&primitives, "rationalize", &.{ z, .fromFixnum(1) }));
    try std.testing.expectError(error.WrongType, f.call(&primitives, "rationalize", &.{ .fromFixnum(1), z }));
    try std.testing.expectError(error.WrongType, callWith("rationalize", &.{ .fromBool(true), .fromFixnum(1) }));
}

test "the root behind exact-integer-sqrt is the integer square root" {
    try expectCall("0", "%exact-integer-sqrt", &.{"0"});
    try expectCall("1", "%exact-integer-sqrt", &.{"1"});
    try expectCall("1", "%exact-integer-sqrt", &.{"3"});
    try expectCall("2", "%exact-integer-sqrt", &.{"4"});
    try expectCall("2", "%exact-integer-sqrt", &.{"8"});
    try expectCall("3", "%exact-integer-sqrt", &.{"9"});
    try expectCall("4", "%exact-integer-sqrt", &.{"17"});
    try expectCall("3037000499", "%exact-integer-sqrt", &.{"9223372036854775807"});
    // 平方数の1つ手前の数は、`f64` に丸めると平方数になる。根は1小さい。
    try expectCall("3037000498", "%exact-integer-sqrt", &.{"9223372030926249000"});
    try expectCall("3037000499", "%exact-integer-sqrt", &.{"9223372030926249001"});
    try expectCall("4294967296", "%exact-integer-sqrt", &.{big_even});
    try expectCall("4294967296", "%exact-integer-sqrt", &.{big_odd});
    try expectCall("4294967295", "%exact-integer-sqrt", &.{"18446744073709551615"});
    // 10^40 の根は 10^20、10^40 より1小さい数の根は 10^20 より1小さい。
    try expectCall("100000000000000000000", "%exact-integer-sqrt", &.{"10000000000000000000000000000000000000000"});
    try expectCall("99999999999999999999", "%exact-integer-sqrt", &.{"9999999999999999999999999999999999999999"});
}

test "the root behind exact-integer-sqrt takes only a non-negative exact integer" {
    for ([_][]const u8{ "-1", "-" ++ big_even, "1.0", "4.0", "1/2", "1+2i", "+nan.0" }) |text| {
        var f: test_support.Fixture = undefined;
        f.init();
        defer f.deinit();
        const v = (try number.parse(f.services.heap, text, 10)).?;
        try std.testing.expectError(error.WrongType, f.call(&primitives, "%exact-integer-sqrt", &.{v}));
    }
    try std.testing.expectError(error.WrongType, callWith("%exact-integer-sqrt", &.{.unspecified_value}));
}
