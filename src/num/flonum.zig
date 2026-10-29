//! The decimal spelling of flonums: writing (R7RS 6.2.7 `number->string`) and parsing
//! (docs/plans/0018-phase4-numeric-tower-unicode.md, slice 4b).
//!
//! 純粋な層で、ヒープにも `Value` にも触れず、確保もしない。書式は、最短の往復する
//! 桁列を Zig の標準ライブラリから取り、小数点の位置と指数表記への切り替えを自前で
//! 決める(docs/design/numerics-and-unicode.md)。切り替えの範囲は ECMA-262 の
//! Number::toString と同じである(`write` の doc コメント)。

const std = @import("std");
const syntax = @import("syntax.zig");
const tier = @import("../tier.zig");

/// Writes `x` in the base-10 spelling of R7RS 6.2.7.
///
/// 有限の値は、最短の往復する桁列に小数点を必ず置いて書く(`100.0`、`0.5`)。
/// ECMA-262 の Number::toString(確認の記録は docs/plans/0018 の「ECMA-262 の Number::toString の確認」)の
/// n を、`x = s × 10^(n-k)`(s は k 桁の整数で10で割り切れない)を満たす整数とし、
/// n が -5 以上 21 以下なら小数で、それ以外なら指数表記で書く。指数表記の仮数部にも
/// 小数点を置く(`1.0e+21`、`1.5e-7`)。指数部の符号は、正でも負でも書く(ECMA-262 と
/// R7RS の準拠スイートの綴りに合わせる)。`+inf.0` `-inf.0`
/// `+nan.0` と `-0.0` は専用に書く。確保しない。
pub fn write(out: *std.Io.Writer, x: f64) std.Io.Writer.Error!void {
    if (std.math.isNan(x)) return out.writeAll("+nan.0");
    const negative = std.math.signbit(x);
    if (std.math.isInf(x)) return out.writeAll(if (negative) "-inf.0" else "+inf.0");
    if (negative) try out.writeByte('-');
    if (x == 0) return out.writeAll("0.0");

    const decimal = shortestDigits(@abs(x));
    const digits = decimal.digits[0..decimal.len];
    const k: i32 = decimal.len;
    // ECMA-262 の n。x = s × 10^(n-k) で、s は digits が表す k 桁の整数。
    const n: i32 = k + decimal.exponent;

    if (n >= -5 and n <= 21) {
        if (n >= k) {
            // 整数値: 桁列、0 を n-k 個、`.0`。
            try out.writeAll(digits);
            try out.splatByteAll('0', @intCast(n - k));
            try out.writeAll(".0");
        } else if (n > 0) {
            const point: usize = @intCast(n);
            try out.writeAll(digits[0..point]);
            try out.writeByte('.');
            try out.writeAll(digits[point..]);
        } else {
            try out.writeAll("0.");
            try out.splatByteAll('0', @intCast(-n));
            try out.writeAll(digits);
        }
        return;
    }

    // 指数表記。仮数部にも小数点を置く(`1.0e+21`)。指数部の符号は常に書く。
    try out.writeByte(digits[0]);
    try out.writeByte('.');
    if (digits.len == 1) {
        try out.writeByte('0');
    } else {
        try out.writeAll(digits[1..]);
    }
    try out.print("e{c}{d}", .{ @as(u8, if (n - 1 < 0) '-' else '+'), @abs(n - 1) });
}

/// The shortest digits that read back to the same `f64`, with the power of ten they scale by.
const Decimal = struct {
    /// 先頭が0でない十進の桁(ASCII)。`len` 桁。末尾は0でない。
    digits: [20]u8,
    len: u8,
    /// 値は、digits が表す整数に 10 の `exponent` 乗を掛けたもの。
    exponent: i32,
};

/// `x` は有限で、0 でなく、正である。
///
/// Why: 最短の桁列は `std.fmt.float.binaryToDecimal` から取る。この関数は公開されているが、
/// 文書のある利用者向けの API かは確かめていない。Zig の版を上げるときに名前や引数が
/// 変わりうるので、呼び出しをここ1つに閉じる(docs/plans/0018 の実験の1)。
/// 表の選び方は `std.fmt.float.render` と同じである。
fn shortestDigits(x: f64) Decimal {
    std.debug.assert(std.math.isFinite(x) and x > 0);
    const float = std.fmt.float;
    const tables = if (@import("builtin").mode == .small) &float.Backend64_TablesSmall else &float.Backend64_TablesFull;
    const d = float.binaryToDecimal(u64, @bitCast(x), std.math.floatMantissaBits(f64), std.math.floatExponentBits(f64), false, tables);
    var result: Decimal = .{ .digits = undefined, .len = 0, .exponent = d.exponent };
    var rest = d.mantissa;
    // 仮数は17桁までに収まる。末尾から埋めて、あとで前に寄せる。
    var reversed: [20]u8 = undefined;
    while (rest != 0) : (rest /= 10) {
        reversed[result.len] = '0' + @as(u8, @intCast(rest % 10));
        result.len += 1;
    }
    for (0..result.len) |i| result.digits[i] = reversed[result.len - 1 - i];
    return result;
}

/// The spelling given to `parseDecimal` is not an unsigned `<decimal 10>`.
pub const ParseError = error{InvalidSpelling};

/// Parses an unsigned `<decimal 10>` spelling (`1.`, `.5`, `1e10`, `1.5E-3`) to the nearest `f64`.
///
/// `text` は、`syntax.scan` が decimal と判定した綴りから符号を除いたもの(整数部、
/// 小数点、小数部、指数部が続いて並ぶ切片)である。範囲を超える大きさは無限大に、
/// 小さすぎるものは0になる(誤りにしない)。受理する集合は `syntax.scan` が先に絞る。
/// この関数は `std.fmt.parseFloat` に渡すだけで、Scheme の数でない綴りが紛れ込んだとき
/// (`inf`、`0x10`、`1_0`)に備えて `error.InvalidSpelling` を返す。確保しない。
pub fn parseDecimal(text: []const u8) ParseError!f64 {
    if (!isDecimalSpelling(text)) return error.InvalidSpelling;
    return std.fmt.parseFloat(f64, text) catch error.InvalidSpelling;
}

/// `<digit>* [. <digit>*] [e [+-] <digit>*]` の形である。桁が足りない綴り(`.`、`1e`)は、
/// ここでは通し、`std.fmt.parseFloat` の拒否に任せる(テストが固定する)。
///
/// Why: `std.fmt.parseFloat` は符号、`inf`、`nan`、`0x` の16進、`_` の区切りも受理する
/// (docs/design/numerics-and-unicode.md)。`syntax.scan` を通ったものしか来ない約束だが、
/// 約束が破れたときに別の値を黙って返さないよう、渡す前にここで形を確かめる。
fn isDecimalSpelling(text: []const u8) bool {
    var i: usize = 0;
    while (i < text.len and std.ascii.isDigit(text[i])) i += 1;
    if (i < text.len and text[i] == '.') {
        i += 1;
        while (i < text.len and std.ascii.isDigit(text[i])) i += 1;
    }
    if (i < text.len and (text[i] == 'e' or text[i] == 'E')) {
        i += 1;
        if (i < text.len and (text[i] == '+' or text[i] == '-')) i += 1;
        while (i < text.len and std.ascii.isDigit(text[i])) i += 1;
    }
    return i == text.len;
}

test {
    std.testing.refAllDecls(@This());
}

fn expectWrites(expected: []const u8, x: f64) !void {
    var buf: [400]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buf);
    try write(&out, x);
    try std.testing.expectEqualStrings(expected, out.buffered());
}

test "write puts a decimal point in every finite number, and writes zeros, infinities and NaN specially" {
    try expectWrites("0.0", 0.0);
    try expectWrites("-0.0", -0.0);
    try expectWrites("1.0", 1.0);
    try expectWrites("-1.0", -1.0);
    try expectWrites("100.0", 100.0);
    try expectWrites("0.5", 0.5);
    try expectWrites("-0.5", -0.5);
    try expectWrites("123.456", 123.456);
    try expectWrites("0.3333333333333333", 1.0 / 3.0);
    try expectWrites("+inf.0", std.math.inf(f64));
    try expectWrites("-inf.0", -std.math.inf(f64));
    try expectWrites("+nan.0", std.math.nan(f64));
    try expectWrites("+nan.0", -std.math.nan(f64));
}

test "write switches to exponent notation just outside n in [-5, 21] (ECMA-262 Number::toString)" {
    // 上側の境界: 1e20 は n = 21、1e21 は n = 22。
    try expectWrites("100000000000000000000.0", 1e20);
    try expectWrites("1.0e+21", 1e21);
    try expectWrites("123456789012345680000.0", 123456789012345680000.0);
    try expectWrites("1.2345678901234568e+21", 1.2345678901234568e21);
    // 下側の境界: 1e-6 は n = -5、1e-7 は n = -6。
    try expectWrites("0.000001", 1e-6);
    try expectWrites("1.0e-7", 1e-7);
    try expectWrites("0.0000015", 1.5e-6);
    try expectWrites("1.5e-7", 1.5e-7);
    try expectWrites("-1.0e+21", -1e21);
    try expectWrites("-1.0e-7", -1e-7);
}

test "write gives the shortest digits for the extreme values" {
    try expectWrites("1.7976931348623157e+308", std.math.floatMax(f64));
    try expectWrites("5.0e-324", std.math.floatTrueMin(f64));
    try expectWrites("2.2250738585072014e-308", std.math.floatMin(f64));
    try expectWrites("9007199254740992.0", 9007199254740992.0);
}

test "parseDecimal reads the spellings of <decimal 10>" {
    try std.testing.expectEqual(@as(f64, 1.0), try parseDecimal("1."));
    try std.testing.expectEqual(@as(f64, 0.5), try parseDecimal(".5"));
    try std.testing.expectEqual(@as(f64, 100.0), try parseDecimal("1.e2"));
    try std.testing.expectEqual(@as(f64, 5.0), try parseDecimal(".5e1"));
    try std.testing.expectEqual(@as(f64, 1e10), try parseDecimal("1E10"));
    try std.testing.expectEqual(@as(f64, 1.5e-3), try parseDecimal("1.5e-3"));
    try std.testing.expectEqual(@as(f64, 1500.0), try parseDecimal("1.5e+3"));
    try std.testing.expectEqual(@as(f64, 0.0), try parseDecimal("0.0"));
    // 数字だけの綴りも受理する。`syntax.scan` はそれを integer と判定するので、呼び出し側は decimal にだけ渡す約束だが、この関数の契約として固定する。
    try std.testing.expectEqual(@as(f64, 11.0), try parseDecimal("11"));
}

test "parseDecimal rounds to nearest even, and saturates instead of failing" {
    // 最大の非正規化数と、2^53 + 1 の偶数への丸め。
    try std.testing.expectEqual(@as(u64, 0x000fffffffffffff), @as(u64, @bitCast(try parseDecimal("2.2250738585072011e-308"))));
    try std.testing.expectEqual(@as(f64, 9007199254740992.0), try parseDecimal("9007199254740993."));
    try std.testing.expectEqual(@as(u64, 1), @as(u64, @bitCast(try parseDecimal("4.9e-324"))));
    try std.testing.expectEqual(std.math.floatMax(f64), try parseDecimal("1.7976931348623157e308"));
    // 指数部の `+` は付いても付かなくても同じ値を読む(`write` は `+` を書く)。
    try std.testing.expectEqual(std.math.floatMax(f64), try parseDecimal("1.7976931348623157e+308"));
    try std.testing.expectEqual(@as(f64, 1e21), try parseDecimal("1.0e+21"));
    try std.testing.expectEqual(@as(f64, 1e21), try parseDecimal("1.0e21"));
    try std.testing.expect(std.math.isPositiveInf(try parseDecimal("1e400")));
    try std.testing.expectEqual(@as(f64, 0.0), try parseDecimal("1e-400"));
    // 長い桁列と、大きな指数部も、誤りにならない。
    var long: [2001 + 8]u8 = undefined;
    @memset(&long, '0');
    long[0] = '1';
    @memcpy(long[2001..], ".5e-2000");
    try std.testing.expectEqual(@as(f64, 1.0), try parseDecimal(&long));
    try std.testing.expect(std.math.isPositiveInf(try parseDecimal("1e99999999999999999999")));
}

test "parseDecimal refuses what is not a <decimal 10>" {
    for ([_][]const u8{ "", ".", "e5", ".e5", "1e", "1e+", "inf", "nan", "0x10", "1_0", "+1.0", "-1.0", "1.0f", "+inf.0", "1 " }) |text| {
        try std.testing.expectError(error.InvalidSpelling, parseDecimal(text));
    }
}

/// Checks that `write`'s output for `x` is a `<decimal 10>` that `syntax.scan` accepts, and that
/// reading it back gives the same bits.
fn expectRoundTrip(x: f64) !void {
    var buf: [400]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buf);
    try write(&out, x);
    const text = out.buffered();
    const literal = syntax.scan(text, 10) orelse return error.NotANumber;
    const unsigned = if (text[0] == '-') text[1..] else text;
    switch (literal.shape) {
        .real => |real| switch (real) {
            .decimal => |d| {
                try std.testing.expectEqual(text[0] == '-', d.sign == .negative);
                const back = try parseDecimal(unsigned);
                const magnitude: f64 = @abs(x);
                try std.testing.expectEqual(@as(u64, @bitCast(magnitude)), @as(u64, @bitCast(back)));
            },
            else => return error.NotADecimal,
        },
        else => return error.NotADecimal,
    }
}

fn roundTripRandom(count: usize, seed: u64) !void {
    var prng: std.Random.DefaultPrng = .init(seed);
    const random = prng.random();
    var done: usize = 0;
    while (done < count) {
        const x: f64 = @bitCast(random.int(u64));
        if (!std.math.isFinite(x)) continue;
        try expectRoundTrip(x);
        done += 1;
    }
}

test "write then scan then parseDecimal gives the same bits for the boundary values" {
    for ([_]f64{ 1e20, 1e21, 1e-6, 1e-7, 0.1, 0.2, 0.3, 100.0, 5e-324, std.math.floatMax(f64), std.math.floatMin(f64), 9007199254740993.0, -1e21, -1e-7, 123456789.123456789 }) |x| {
        try expectRoundTrip(x);
    }
}

test "write round-trips random finite bit patterns at a small scale" {
    try roundTripRandom(20_000, 0x5eed);
}

test "write round-trips random finite bit patterns at a large scale" {
    try tier.slow();
    try roundTripRandom(5_000_000, 0xfeed);
}
