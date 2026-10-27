//! The primitives of `(scheme complex)` (R7RS 6.2.6): `make-rectangular` `make-polar`
//! `real-part` `imag-part` `magnitude` `angle`.
//!
//! 部分の取り出しと組み立てだけを持つ。複素数の四則と比較は `ops.zig`(スライス 4f)、
//! `sqrt` `exp` `log` などの複素数への拡張は `inexact.zig`(スライス 4i)が持つ。数の
//! 計算は `src/num/complex.zig` にある。名前の並びは `tests/r7rs-required/complex.txt` の順である。
//! 引数の型は、値によらず、すべての引数について先に検査する(`arith.zig` の方針)。

const std = @import("std");
const value = @import("../value.zig");
const Value = value.Value;
const Primitive = value.Primitive;
const Services = value.Services;
const PrimitiveError = value.PrimitiveError;
const Heap = @import("../heap.zig").Heap;
const number = @import("../num/number.zig");
const ops = @import("../num/ops.zig");
const complex = @import("../num/complex.zig");

pub const Error = PrimitiveError;

pub const primitives = [_]Primitive{
    .{ .name = "angle", .min_args = 1, .max_args = 1, .body = .{ .pure = &angle } },
    .{ .name = "imag-part", .min_args = 1, .max_args = 1, .body = .{ .pure = &imagPart } },
    .{ .name = "magnitude", .min_args = 1, .max_args = 1, .body = .{ .pure = &magnitude } },
    .{ .name = "make-polar", .min_args = 2, .max_args = 2, .body = .{ .pure = &makePolar } },
    .{ .name = "make-rectangular", .min_args = 2, .max_args = 2, .body = .{ .pure = &makeRectangular } },
    .{ .name = "real-part", .min_args = 1, .max_args = 1, .body = .{ .pure = &realPart } },
};

fn requireNumber(v: Value) Error!void {
    if (!number.isNumber(v)) return error.WrongType;
}

/// Checks both arguments are real numbers, before anything is computed.
fn requireReals(args: []const Value) Error!void {
    for (args) |a| if (!ops.isRealNumber(a)) return error.WrongType;
}

/// `(real-part z)`: the real part of `z`; a real number is its own real part.
fn realPart(_: *const Services, args: []const Value) Error!Value {
    try requireNumber(args[0]);
    return if (args[0].asCompnum()) |c| c.real else args[0];
}

/// `(imag-part z)`: the imaginary part of `z`; a real number has an exact 0.
fn imagPart(_: *const Services, args: []const Value) Error!Value {
    try requireNumber(args[0]);
    return if (args[0].asCompnum()) |c| c.imag else .fromFixnum(0);
}

/// `(magnitude z)`: `|z|`; the same as `abs` for a real number.
fn magnitude(services: *const Services, args: []const Value) Error!Value {
    try requireNumber(args[0]);
    return complex.magnitude(services.heap, args[0]);
}

/// `(angle z)`: the angle of `z` in radians, from `-pi` to `pi`.
fn angle(services: *const Services, args: []const Value) Error!Value {
    try requireNumber(args[0]);
    return complex.angle(services.heap, args[0]);
}

/// `(make-rectangular x1 x2)`: the number `x1 + x2 i`, a real number if `x2` is an exact 0.
fn makeRectangular(services: *const Services, args: []const Value) Error!Value {
    try requireReals(args);
    return complex.rectangular(services.heap, args[0], args[1]);
}

/// `(make-polar x3 x4)`: the number `x3 e^(i x4)`.
///
/// 大きさか角が正確な 0 なら、結果は(大きさが 0 なら 0、角が 0 なら大きさそのもので)正確な
/// 数である。それ以外は不正確な複素数になる(R7RS 6.2.6)。
fn makePolar(services: *const Services, args: []const Value) Error!Value {
    try requireReals(args);
    return ops.counted(Value, makePolarWork, services.heap, .{ args[0], args[1] });
}

fn makePolarWork(h: *Heap, gpa: std.mem.Allocator, m: Value, a: Value) number.Error!Value {
    return (try number.makePolar(h, gpa, m, a, false)).?;
}

test {
    std.testing.refAllDecls(@This());
}

const test_support = @import("test_support.zig");

/// Calls `name` on the numbers `texts` spell, and checks the printed result (a boolean as `#t`/`#f`).
fn expectCall(expected: []const u8, name: []const u8, texts: []const []const u8) !void {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    var args: [2]Value = undefined;
    for (texts, 0..) |t, i| args[i] = (try number.parse(f.services.heap, t, 10)) orelse return error.NotANumber;
    const v = try f.call(&primitives, name, args[0..texts.len]);
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try number.write(&aw.writer, std.testing.allocator, v, 10);
    try std.testing.expectEqualStrings(expected, aw.written());
}

fn expectError(expected: anyerror, name: []const u8, args: []const Value) !void {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    try std.testing.expectError(expected, f.call(&primitives, name, args));
}

test "the primitives take the numbers of arguments the language gives them" {
    const Arity = struct { name: []const u8, count: u8 };
    const expected = [_]Arity{
        .{ .name = "angle", .count = 1 },
        .{ .name = "imag-part", .count = 1 },
        .{ .name = "magnitude", .count = 1 },
        .{ .name = "make-polar", .count = 2 },
        .{ .name = "make-rectangular", .count = 2 },
        .{ .name = "real-part", .count = 1 },
    };
    try std.testing.expectEqual(expected.len, primitives.len);
    for (expected, 0..) |e, i| {
        try std.testing.expectEqualStrings(e.name, primitives[i].name);
        try std.testing.expectEqual(e.count, primitives[i].min_args);
        try std.testing.expectEqual(e.count, primitives[i].max_args.?);
    }
}

test "make-rectangular builds a number from two real numbers" {
    try expectCall("1+2i", "make-rectangular", &.{ "1", "2" });
    try expectCall("1", "make-rectangular", &.{ "1", "0" });
    try expectCall("1/2-3/4i", "make-rectangular", &.{ "1/2", "-3/4" });
    // 虚部が不正確な 0 なら複素数のまま、部分の正確性はそろう。
    try expectCall("1.0+0.0i", "make-rectangular", &.{ "1.0", "0.0" });
    try expectCall("1.0+2.0i", "make-rectangular", &.{ "1", "2.0" });
    try expectCall("1.0", "make-rectangular", &.{ "1.0", "0" });
}

test "real-part and imag-part split a number" {
    try expectCall("1", "real-part", &.{"1+2i"});
    try expectCall("2", "imag-part", &.{"1+2i"});
    try expectCall("1.5", "real-part", &.{"1.5+2.5i"});
    try expectCall("2.5", "imag-part", &.{"1.5+2.5i"});
    try expectCall("5", "real-part", &.{"5"});
    try expectCall("0", "imag-part", &.{"5"});
    try expectCall("0", "imag-part", &.{"-1.5"});
    try expectCall("-1.5", "real-part", &.{"-1.5"});
}

test "magnitude of a real number is its absolute value" {
    try expectCall("5", "magnitude", &.{"-5"});
    try expectCall("5", "magnitude", &.{"5"});
    try expectCall("1/3", "magnitude", &.{"-1/3"});
    try expectCall("2.5", "magnitude", &.{"-2.5"});
    try expectCall("+inf.0", "magnitude", &.{"-inf.0"});
}

test "magnitude of a complex number" {
    try expectCall("5", "magnitude", &.{"3+4i"});
    try expectCall("5", "magnitude", &.{"-3-4i"});
    try expectCall("1", "magnitude", &.{"5/13+12/13i"});
    try expectCall("1", "magnitude", &.{"+i"});
    try expectCall("2.23606797749979", "magnitude", &.{"1+2i"});
    try expectCall("5.0", "magnitude", &.{"3.0+4.0i"});
    try expectCall("+inf.0", "magnitude", &.{"+inf.0+1.0i"});
    // 部分の二乗が `f64` を超えても、有限になる。
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    const z = (try number.parse(f.services.heap, "1e200+1e200i", 10)).?;
    const m = (try f.call(&primitives, "magnitude", &.{z})).asFlonum().?;
    try std.testing.expect(@abs(m - 1.4142135623730951e200) <= 1e-15 * m);
}

test "angle of a real number" {
    try expectCall("0", "angle", &.{"1"});
    try expectCall("0", "angle", &.{"0"});
    try expectCall("0", "angle", &.{"1/2"});
    try expectCall("3.141592653589793", "angle", &.{"-1"});
    try expectCall("0.0", "angle", &.{"1.0"});
    try expectCall("0.0", "angle", &.{"0.0"});
    try expectCall("3.141592653589793", "angle", &.{"-1.0"});
    try expectCall("3.141592653589793", "angle", &.{"-0.0"});
}

test "angle of a complex number" {
    try expectCall("1.5707963267948966", "angle", &.{"+i"});
    try expectCall("-1.5707963267948966", "angle", &.{"-i"});
    try expectCall("0.7853981633974483", "angle", &.{"1+i"});
    try expectCall("2.356194490192345", "angle", &.{"-1+i"});
    try expectCall("-2.356194490192345", "angle", &.{"-1-i"});
    try expectCall("1.1071487177940904", "angle", &.{"1+2i"});
    try expectCall("0.7853981633974483", "angle", &.{"1.0+1.0i"});
}

test "make-polar builds a number from a magnitude and an angle" {
    try expectCall("1", "make-polar", &.{ "1", "0" });
    try expectCall("0", "make-polar", &.{ "0", "5" });
    try expectCall("2.5", "make-polar", &.{ "2.5", "0" });
    try expectCall("0.5403023058681398+0.8414709848078965i", "make-polar", &.{ "1", "1" });
    try expectCall("-1.0+1.2246467991473532e-16i", "make-polar", &.{ "1", "3.141592653589793" });
}

test "the primitives take only a number, or a real number for the builders" {
    const symbol: Value = .unspecified_value;
    for ([_][]const u8{ "angle", "imag-part", "magnitude", "real-part" }) |name| {
        try expectError(error.WrongType, name, &.{symbol});
    }
    try expectError(error.WrongType, "make-rectangular", &.{ .fromFixnum(1), symbol });
    try expectError(error.WrongType, "make-polar", &.{ symbol, .fromFixnum(1) });
    // 型は、値によらず、すべての引数について先に検査する。
    try expectError(error.WrongType, "make-rectangular", &.{ symbol, .fromFixnum(1) });
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    const z = (try number.parse(f.services.heap, "1+2i", 10)).?;
    try std.testing.expectError(error.WrongType, f.call(&primitives, "make-rectangular", &.{ z, .fromFixnum(1) }));
    try std.testing.expectError(error.WrongType, f.call(&primitives, "make-polar", &.{ .fromFixnum(1), z }));
}
