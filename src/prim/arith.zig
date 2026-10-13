//! Arithmetic primitives.
//!
//! 段階4までは固定長の整数だけを扱う(docs/design/runtime.md, ADR-0007)。

const std = @import("std");
const value = @import("../value.zig");
const Value = value.Value;
const Primitive = value.Primitive;
const Services = value.Services;
const PrimitiveError = value.PrimitiveError;

pub const Error = PrimitiveError;

pub const primitives = [_]Primitive{
    .{ .name = "+", .min_args = 0, .max_args = null, .body = .{ .pure = &add } },
    .{ .name = "-", .min_args = 1, .max_args = null, .body = .{ .pure = &subtract } },
    .{ .name = "*", .min_args = 0, .max_args = null, .body = .{ .pure = &multiply } },
    .{ .name = "=", .min_args = 1, .max_args = null, .body = .{ .pure = comparison(.eq) } },
    .{ .name = "<", .min_args = 1, .max_args = null, .body = .{ .pure = comparison(.lt) } },
    .{ .name = ">", .min_args = 1, .max_args = null, .body = .{ .pure = comparison(.gt) } },
    .{ .name = "<=", .min_args = 1, .max_args = null, .body = .{ .pure = comparison(.lte) } },
    .{ .name = ">=", .min_args = 1, .max_args = null, .body = .{ .pure = comparison(.gte) } },
    .{ .name = "quotient", .min_args = 2, .max_args = 2, .body = .{ .pure = division(.quotient) } },
    .{ .name = "remainder", .min_args = 2, .max_args = 2, .body = .{ .pure = division(.remainder) } },
    .{ .name = "modulo", .min_args = 2, .max_args = 2, .body = .{ .pure = division(.modulo) } },
    .{ .name = "number?", .min_args = 1, .max_args = 1, .body = .{ .pure = &isNumber } },
};

/// A result of the wide arithmetic, as a fixnum if it fits.
///
/// R7RS 6.2.3 は、表現できない正確な結果を、実装上の制限の違反として報告する
/// ことを実装に許している。多倍長整数は段階4で入る。
fn fromWide(n: i128) Error!Value {
    return .fromFixnum(std.math.cast(i64, n) orelse return error.IntegerOverflow);
}

/// `(+ z1 ...)`.
///
/// 引数がなければ和は 0 である(R7RS 6.2.6)。
fn add(_: *const Services, args: []const Value) Error!Value {
    // プログラムが作れるどの引数リストでもあふれない幅にしてある。このため
    // fixnum の範囲に収めるのは結果だけで、`(+ max 1 -1)` は `max` になる。
    var sum: i128 = 0;
    for (args) |a| sum += a.asFixnum() orelse return error.WrongType;
    return .fromFixnum(std.math.cast(i64, sum) orelse return error.IntegerOverflow);
}

/// `(- z)` negates, and `(- z1 z2 ...)` subtracts the rest from the first
/// (R7RS 6.2.6).
///
/// 引数は1つ以上要る。個数は機械が表の下限で検査するので、`args[0]` を読んでよい。
fn subtract(_: *const Services, args: []const Value) Error!Value {
    const first = args[0].asFixnum() orelse return error.WrongType;
    // 最小の fixnum の符号反転は収まらない。`(- 0 min)` も同じである。
    if (args.len == 1) return fromWide(-@as(i128, first));
    var difference: i128 = first;
    for (args[1..]) |a| difference -= a.asFixnum() orelse return error.WrongType;
    return fromWide(difference);
}

/// `(* z1 ...)`.
///
/// 引数がなければ積は 1 である(R7RS 6.2.6)。
///
/// 積は128ビットで保持する。fixnum に収まらない部分積を、`(* big big 0)` のように
/// 後の因数で収まる値に戻せるようにするためである。128ビットに収まらない部分積は、
/// 後に 0 が来れば結果が収まる場合でも、エラーとして報告する。
fn multiply(_: *const Services, args: []const Value) Error!Value {
    // 先にすべての引数を検査する。エラーが、前の因数がすでにあふれたかどうかに
    // 左右されないようにするためである。
    for (args) |a| _ = a.asFixnum() orelse return error.WrongType;
    var product: i128 = 1;
    for (args) |a| {
        const r = @mulWithOverflow(product, @as(i128, a.asFixnum().?));
        if (r[1] != 0) return error.IntegerOverflow;
        product = r[0];
    }
    return fromWide(product);
}

/// `(= z1 z2 z3 ...)` and its relatives (R7RS 6.2.6): true when `op` holds for
/// every neighbouring pair.
///
/// 引数が1つなら真、なしならエラー(機械が表の下限で報告する)である。最初に成り
/// 立たなかった組より後のものも含め、すべての引数が数であることを検査する。エラーが
/// 値に左右されないようにするためである。
fn comparison(comptime op: std.math.CompareOperator) Primitive.Fn {
    return &struct {
        fn call(_: *const Services, args: []const Value) Error!Value {
            for (args) |a| _ = a.asFixnum() orelse return error.WrongType;
            var holds = true;
            for (args[0 .. args.len - 1], args[1..]) |a, b| {
                if (!std.math.compare(a.asFixnum().?, op, b.asFixnum().?)) holds = false;
            }
            return .fromBool(holds);
        }
    }.call;
}

/// Which of the integer divisions a primitive computes.
const Division = enum { quotient, remainder, modulo };

/// `(quotient n d)`, `(remainder n d)` and `(modulo n d)` (R7RS 6.2.6).
///
/// `quotient` と `remainder` は0に向かって丸める除算(`truncate-quotient` と
/// `truncate-remainder`)で、`remainder` の符号は被除数に従う。`modulo` は床除算の
/// 剰余(`floor-remainder`)で、符号は除数に従う。
///
/// 128ビットで計算する。最小の fixnum を -1 で割ると、商の 2^63 は64ビットに収まらないが、
/// 128ビットなら除算そのものは正しく終わる。収まるかどうかは結果で決め、`quotient` だけが
/// あふれる。
///
/// Why: 最小の fixnum を -1 で割ったときの `remainder` と `modulo` は、数学的な値の 0 を
/// 返し、エラーにしない。0 は収まるので、R7RS 6.2.3 の「表現できない結果」に当たらない。
///
/// 検査の順序は、型、除数の 0 である。両方の引数の型を先に検査し、エラーが値に左右
/// されないようにする(`*` と比較の方針)。個数は機械が表で検査する。
fn division(comptime kind: Division) Primitive.Fn {
    return &struct {
        fn call(_: *const Services, args: []const Value) Error!Value {
            const dividend = args[0].asFixnum() orelse return error.WrongType;
            const divisor = args[1].asFixnum() orelse return error.WrongType;
            if (divisor == 0) return error.DivisionByZero;
            const n: i128 = dividend;
            const d: i128 = divisor;
            return fromWide(switch (kind) {
                .quotient => @divTrunc(n, d),
                .remainder => @rem(n, d),
                // R7RS の modulo は floor-remainder で、n - d * floor(n / d) と定義される。その定義のまま書く。
                .modulo => n - d * @divFloor(n, d),
            });
        }
    }.call;
}

/// `(number? obj)`: true when `obj` is a number (R7RS 6.2.6).
///
/// 数の型の述語は、数でない引数にも使え、偽を返す。段階4までは数が fixnum だけなので、
/// fixnum なら真である。数値塔が入っても意味は変わらない(docs/plans/0010)。
fn isNumber(_: *const Services, args: []const Value) Error!Value {
    return .fromBool(args[0].asFixnum() != null);
}

test {
    std.testing.refAllDecls(@This());
}

const test_support = @import("test_support.zig");

/// Calls the primitive called `name` with fixnum arguments.
fn call(name: []const u8, ns: []const i64) Error!Value {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    var args: [8]Value = undefined;
    for (ns, 0..) |n, i| args[i] = .fromFixnum(n);
    return f.call(&primitives, name, args[0..ns.len]);
}

fn callInt(name: []const u8, ns: []const i64) Error!i64 {
    return (try call(name, ns)).asFixnum().?;
}

fn callBool(name: []const u8, ns: []const i64) !bool {
    const v = try call(name, ns);
    try std.testing.expectEqual(.boolean, v.kind());
    return v.isTrue();
}

/// Calls the primitive called `name` with `args`, which are not all fixnums.
fn callWith(name: []const u8, args: []const Value) Error!Value {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    return f.call(&primitives, name, args);
}

test "the primitives take the numbers of arguments the language gives them" {
    const Arity = struct { name: []const u8, min: u8, max: ?u8 };
    const expected = [_]Arity{
        .{ .name = "+", .min = 0, .max = null },
        .{ .name = "-", .min = 1, .max = null },
        .{ .name = "*", .min = 0, .max = null },
        .{ .name = "=", .min = 1, .max = null },
        .{ .name = "<", .min = 1, .max = null },
        .{ .name = ">", .min = 1, .max = null },
        .{ .name = "<=", .min = 1, .max = null },
        .{ .name = ">=", .min = 1, .max = null },
        .{ .name = "quotient", .min = 2, .max = 2 },
        .{ .name = "remainder", .min = 2, .max = 2 },
        .{ .name = "modulo", .min = 2, .max = 2 },
        .{ .name = "number?", .min = 1, .max = 1 },
    };
    try std.testing.expectEqual(expected.len, primitives.len);
    // 長さの食い違いは、上の比較で報告する。ここは添字で進めるので、食い違っても
    // コンパイルエラーでなくテストの失敗になる。
    for (expected, 0..) |e, i| {
        try std.testing.expect(i < primitives.len);
        const p = primitives[i];
        try std.testing.expectEqualStrings(e.name, p.name);
        try std.testing.expectEqual(e.min, p.min_args);
        try std.testing.expectEqual(e.max, p.max_args);
    }
}

test "+ adds its arguments, and of none is 0" {
    try std.testing.expectEqual(0, try callInt("+", &.{}));
    try std.testing.expectEqual(1, try callInt("+", &.{1}));
    try std.testing.expectEqual(15, try callInt("+", &.{ 1, 2, 3, 4, 5 }));
    try std.testing.expectEqual(-5, try callInt("+", &.{ 2, -7 }));
}

test "+ reports a sum that does not fit rather than wrapping" {
    try std.testing.expectError(error.IntegerOverflow, call("+", &.{ std.math.maxInt(i64), 1 }));
    try std.testing.expectError(error.IntegerOverflow, call("+", &.{ std.math.minInt(i64), -1 }));
}

test "+ holds only the result to the fixnum range, not a partial sum" {
    try std.testing.expectEqual(std.math.maxInt(i64), try callInt("+", &.{ std.math.maxInt(i64), 1, -1 }));
}

test "+ reports an argument that is not a number" {
    const args = [_]Value{ .fromFixnum(1), .unspecified_value };
    try std.testing.expectError(error.WrongType, callWith("+", &args));
}

test "- negates one argument and subtracts the rest from the first" {
    try std.testing.expectEqual(-5, try callInt("-", &.{5}));
    try std.testing.expectEqual(0, try callInt("-", &.{0}));
    try std.testing.expectEqual(2, try callInt("-", &.{ 5, 3 }));
    try std.testing.expectEqual(4, try callInt("-", &.{ 10, 1, 2, 3 }));
    try std.testing.expectEqual(-5, try callInt("-", &.{ 0, 5 }));
}

test "- reports a result that does not fit" {
    try std.testing.expectError(error.IntegerOverflow, call("-", &.{std.math.minInt(i64)}));
    try std.testing.expectError(error.IntegerOverflow, call("-", &.{ 0, std.math.minInt(i64) }));
    try std.testing.expectError(error.IntegerOverflow, call("-", &.{ std.math.maxInt(i64), -1 }));
    // 結果が範囲に戻るなら、途中の差は fixnum の範囲を出てよい。
    try std.testing.expectEqual(std.math.maxInt(i64), try callInt("-", &.{ std.math.maxInt(i64), -1, 1 }));
}

test "* multiplies, and of none is 1" {
    try std.testing.expectEqual(1, try callInt("*", &.{}));
    try std.testing.expectEqual(7, try callInt("*", &.{7}));
    try std.testing.expectEqual(24, try callInt("*", &.{ 2, 3, 4 }));
    try std.testing.expectEqual(-6, try callInt("*", &.{ -2, 3 }));
    try std.testing.expectEqual(0, try callInt("*", &.{ 0, 5 }));
}

test "* reports a product that does not fit, but lets a zero bring a partial one back" {
    try std.testing.expectError(error.IntegerOverflow, call("*", &.{ std.math.maxInt(i64), 2 }));
    try std.testing.expectError(error.IntegerOverflow, call("*", &.{ std.math.minInt(i64), -1 }));
    const big = std.math.maxInt(i64);
    try std.testing.expectEqual(0, try callInt("*", &.{ big, big, 0 }));
    try std.testing.expectError(error.IntegerOverflow, call("*", &.{ big, big, big }));
    // 2^128 は128ビットでは 0 に巻き戻り、fixnum に収まってしまう。
    const two_32 = 1 << 32;
    try std.testing.expectError(error.IntegerOverflow, call("*", &.{ two_32, two_32, two_32, two_32 }));
}

test "* checks every argument before it multiplies" {
    const big = std.math.maxInt(i64);
    const args = [_]Value{ .fromFixnum(big), .fromFixnum(big), .fromFixnum(big), .unspecified_value };
    try std.testing.expectError(error.WrongType, callWith("*", &args));
}

test "comparisons chain over neighbouring pairs" {
    try std.testing.expect(try callBool("=", &.{ 1, 1, 1 }));
    try std.testing.expect(!try callBool("=", &.{ 1, 1, 2 }));
    try std.testing.expect(!try callBool("=", &.{ 2, 1, 1 }));
    try std.testing.expect(try callBool("<", &.{ 1, 2, 3 }));
    try std.testing.expect(!try callBool("<", &.{ 1, 3, 2 }));
    try std.testing.expect(!try callBool("<", &.{ 1, 1 }));
    try std.testing.expect(try callBool(">", &.{ 3, 2, 1 }));
    try std.testing.expect(!try callBool(">", &.{ 1, 2, 3 }));
    try std.testing.expect(try callBool("<=", &.{ 1, 2, 2 }));
    try std.testing.expect(!try callBool("<=", &.{ 2, 1 }));
    try std.testing.expect(try callBool(">=", &.{ 3, 2, 2 }));
    try std.testing.expect(!try callBool(">=", &.{ 1, 2 }));
}

test "a comparison of one number is true" {
    for ([_][]const u8{ "=", "<", ">", "<=", ">=" }) |name| {
        try std.testing.expect(try callBool(name, &.{5}));
    }
}

test "a comparison checks the type of every argument, however the pairs came out" {
    for ([_][]const u8{ "=", "<", ">", "<=", ">=" }) |name| {
        // 最初の組ですでに答えは決まっている。3番目は数ではない。
        const args = [_]Value{ .fromFixnum(2), .fromFixnum(1), .unspecified_value };
        try std.testing.expectError(error.WrongType, callWith(name, &args));
    }
}

const min_i64 = std.math.minInt(i64);
const max_i64 = std.math.maxInt(i64);

/// A pair of operands, and what each division primitive gives for it.
const DivisionCase = struct { n: i64, d: i64, quotient: i64, remainder: i64, modulo: i64 };

test "the division primitives round as the report says in all four combinations of signs" {
    // 原文(R7RS 6.2.6)の例は、13 と 4 の符号違いの4通りである。
    const cases = [_]DivisionCase{
        .{ .n = 13, .d = 4, .quotient = 3, .remainder = 1, .modulo = 1 },
        .{ .n = -13, .d = 4, .quotient = -3, .remainder = -1, .modulo = 3 },
        .{ .n = 13, .d = -4, .quotient = -3, .remainder = 1, .modulo = -3 },
        .{ .n = -13, .d = -4, .quotient = 3, .remainder = -1, .modulo = -1 },
    };
    for (cases) |c| {
        try std.testing.expectEqual(c.quotient, try callInt("quotient", &.{ c.n, c.d }));
        try std.testing.expectEqual(c.remainder, try callInt("remainder", &.{ c.n, c.d }));
        try std.testing.expectEqual(c.modulo, try callInt("modulo", &.{ c.n, c.d }));
    }
}

test "the division primitives agree when the division is exact, whatever the signs" {
    for ([_]i64{ 12, -12 }) |n| {
        for ([_]i64{ 4, -4 }) |d| {
            try std.testing.expectEqual(@divExact(n, d), try callInt("quotient", &.{ n, d }));
            try std.testing.expectEqual(0, try callInt("remainder", &.{ n, d }));
            try std.testing.expectEqual(0, try callInt("modulo", &.{ n, d }));
        }
    }
}

test "the division primitives give a dividend smaller than the divisor in the way their rules say" {
    try std.testing.expectEqual(0, try callInt("quotient", &.{ -3, 7 }));
    try std.testing.expectEqual(-3, try callInt("remainder", &.{ -3, 7 }));
    try std.testing.expectEqual(4, try callInt("modulo", &.{ -3, 7 }));
    try std.testing.expectEqual(-4, try callInt("modulo", &.{ 3, -7 }));
    try std.testing.expectEqual(3, try callInt("modulo", &.{ 3, 7 }));
}

test "the division primitives satisfy their defining identities over a range of operands" {
    var n: i64 = -20;
    while (n <= 20) : (n += 1) {
        var d: i64 = -7;
        while (d <= 7) : (d += 1) {
            if (d == 0) continue;
            const q = try callInt("quotient", &.{ n, d });
            const r = try callInt("remainder", &.{ n, d });
            const m = try callInt("modulo", &.{ n, d });
            // n = d * q + r で、r の符号は n に従い、絶対値は d より小さい。
            try std.testing.expectEqual(n, d * q + r);
            try std.testing.expect(@abs(r) < @abs(d));
            try std.testing.expect(r == 0 or (r < 0) == (n < 0));
            // m は n と d の倍数だけ違い、符号は d に従い、絶対値は d より小さい。
            try std.testing.expectEqual(0, @rem(m - n, d));
            try std.testing.expect(@abs(m) < @abs(d));
            try std.testing.expect(m == 0 or (m < 0) == (d < 0));
        }
    }
}

test "the division primitives hold at the ends of the fixnum range" {
    try std.testing.expectEqual(max_i64, try callInt("quotient", &.{ max_i64, 1 }));
    try std.testing.expectEqual(min_i64, try callInt("quotient", &.{ min_i64, 1 }));
    try std.testing.expectEqual(-max_i64, try callInt("quotient", &.{ max_i64, -1 }));
    try std.testing.expectEqual(0, try callInt("quotient", &.{ max_i64, min_i64 }));
    try std.testing.expectEqual(-1, try callInt("quotient", &.{ min_i64, max_i64 }));
    try std.testing.expectEqual(1, try callInt("quotient", &.{ min_i64, min_i64 }));
    try std.testing.expectEqual(max_i64, try callInt("remainder", &.{ max_i64, min_i64 }));
    try std.testing.expectEqual(-1, try callInt("remainder", &.{ min_i64, max_i64 }));
    try std.testing.expectEqual(0, try callInt("remainder", &.{ min_i64, min_i64 }));
    try std.testing.expectEqual(-1, try callInt("modulo", &.{ max_i64, min_i64 }));
    try std.testing.expectEqual(max_i64 - 1, try callInt("modulo", &.{ min_i64, max_i64 }));
    try std.testing.expectEqual(0, try callInt("modulo", &.{ min_i64, min_i64 }));
    try std.testing.expectEqual(1, try callInt("modulo", &.{ min_i64, 3 }));
    try std.testing.expectEqual(-2, try callInt("remainder", &.{ min_i64, 3 }));
}

test "quotient reports the one quotient that does not fit, and the others give zero" {
    // Why: 最小の整数を -1 で割った商は 2^63 で、固定長整数に収まらない。R7RS 6.2.3 は
    // 表現できない正確な結果を、実装上の制限の違反として報告することを許す。
    // 剰余は数学的に 0 で収まるので、エラーにしない。
    try std.testing.expectError(error.IntegerOverflow, call("quotient", &.{ min_i64, -1 }));
    try std.testing.expectEqual(0, try callInt("remainder", &.{ min_i64, -1 }));
    try std.testing.expectEqual(0, try callInt("modulo", &.{ min_i64, -1 }));
    // 隣の値は収まる。
    try std.testing.expectEqual(max_i64, try callInt("quotient", &.{ -max_i64, -1 }));
    try std.testing.expectEqual(-max_i64, try callInt("quotient", &.{ max_i64, -1 }));
}

test "the division primitives report a zero divisor, whatever the dividend" {
    for ([_][]const u8{ "quotient", "remainder", "modulo" }) |name| {
        for ([_]i64{ 0, 1, -1, 13, min_i64, max_i64 }) |n| {
            try std.testing.expectError(error.DivisionByZero, call(name, &.{ n, 0 }));
        }
    }
}

test "the division primitives check the type of both arguments before the divisor" {
    for ([_][]const u8{ "quotient", "remainder", "modulo" }) |name| {
        const bad_first = [_]Value{ .unspecified_value, .fromFixnum(0) };
        try std.testing.expectError(error.WrongType, callWith(name, &bad_first));
        const bad_second = [_]Value{ .fromFixnum(0), .fromBool(true) };
        try std.testing.expectError(error.WrongType, callWith(name, &bad_second));
        const bad_both = [_]Value{ .empty_list_value, .fromBool(false) };
        try std.testing.expectError(error.WrongType, callWith(name, &bad_both));
        // 型が正しいときに限って、0 除算になる。
        const good = [_]Value{ .fromFixnum(5), .fromFixnum(0) };
        try std.testing.expectError(error.DivisionByZero, callWith(name, &good));
    }
}

test "number? is true of a fixnum and false of anything else" {
    for ([_]i64{ 0, 1, -1, min_i64, max_i64 }) |n| {
        try std.testing.expect(try callBool("number?", &.{n}));
    }
    const others = [_]Value{ .unspecified_value, .fromBool(true), .fromBool(false), .empty_list_value };
    for (others) |v| {
        const r = try callWith("number?", &.{v});
        try std.testing.expectEqual(.boolean, r.kind());
        try std.testing.expect(!r.isTrue());
    }
}
