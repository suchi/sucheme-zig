//! The lexical syntax of numbers (R7RS 7.1.1 `<number>`), checked and split
//! into its parts (docs/plans/0018-phase4-numeric-tower-unicode.md, slice 4a).
//!
//! 数かどうかの判定だけを行い、値は作らない。確保もしない。結果の切片は、渡した
//! 文字列の中を指す。値を作るのは `src/num/number.zig` の仕事で、リーダ
//! (`src/reader.zig`)と `string->number` は同じ判定を通る(R7RS 6.2.7)。
//!
//! `std.fmt.parseFloat` は、Scheme の数ではない綴り(`inf`、`nan`、`0x10`、`1_000`)を
//! 受理し、`+inf.0` などを拒否する(docs/design/numerics-and-unicode.md)。そのため
//! 受理する集合は、この関数が先に決める。

const std = @import("std");

/// The exactness prefix of a number: `#e`, `#i`, or none.
pub const Exactness = enum { unmarked, exact, inexact };

pub const Sign = enum { positive, negative };

/// The four `<infnan>` spellings.
pub const InfNan = enum { positive_infinity, negative_infinity, positive_nan, negative_nan };

/// One `<real R>` without its position in a complex number.
pub const Real = union(enum) {
    /// `<uinteger R>`。digits は空でなく、入力の綴りのまま(大文字を含みうる)。
    integer: struct { sign: Sign, digits: []const u8 },
    /// `<uinteger R> / <uinteger R>`。分母が0でも、ここでは受理する。
    ratio: struct { sign: Sign, numerator: []const u8, denominator: []const u8 },
    /// `<decimal 10>`。基数10のときだけ現れる。`.` か指数部のどちらかを持つ。
    /// whole と fraction のどちらかは空でない。exponent は指数部の `e` の後ろの綴り
    /// (符号を含む)で、指数部が無ければ空。
    decimal: struct { sign: Sign, whole: []const u8, fraction: []const u8, exponent: []const u8 },
    infnan: InfNan,
};

pub const Shape = union(enum) {
    real: Real,
    /// `a+bi` と `+bi`。real が null なら実部は正確な0。`+i` と `-i` の虚部は、
    /// 符号つきの integer "1" である(その "1" だけは入力の中を指さない)。
    rectangular: struct { real: ?Real, imag: Real },
    /// `a@b`
    polar: struct { magnitude: Real, angle: Real },
};

pub const Literal = struct {
    /// 接頭辞があればその基数、無ければ `scan` に渡した既定の基数。
    radix: u8,
    exactness: Exactness,
    shape: Shape,
};

/// Checks `text` as an R7RS 7.1.1 `<number>` and splits it. Returns null if it is not one.
///
/// `default_radix`(2、8、10、16)は、基数の接頭辞が無いときの基数である。大文字小文字を
/// 区別しない(R7RS 7.1.1)。小数と指数は基数10のときだけ受理する(`<decimal 2>` などの
/// 規則が無いため)。確保しない。
pub fn scan(text: []const u8, default_radix: u8) ?Literal {
    std.debug.assert(default_radix == 2 or default_radix == 8 or default_radix == 10 or default_radix == 16);
    var radix: ?u8 = null;
    var exactness: ?Exactness = null;
    var pos: usize = 0;
    // 接頭辞は基数と正確性の高々1つずつなので、2つを超えると重複で止まる。
    while (pos < text.len and text[pos] == '#') : (pos += 2) {
        if (pos + 1 >= text.len) return null;
        switch (std.ascii.toLower(text[pos + 1])) {
            'b', 'o', 'd', 'x' => |c| {
                if (radix != null) return null;
                radix = switch (c) {
                    'b' => 2,
                    'o' => 8,
                    'd' => 10,
                    else => 16,
                };
            },
            'e', 'i' => |c| {
                if (exactness != null) return null;
                exactness = if (c == 'e') .exact else .inexact;
            },
            else => return null,
        }
    }
    var s: Scanner = .{ .text = text[pos..], .radix = radix orelse default_radix };
    const shape = s.complex() orelse return null;
    return .{ .radix = s.radix, .exactness = exactness orelse .unmarked, .shape = shape };
}

/// The cursor of `scan`. 各関数は、失敗したら位置を戻して null を返す。
const Scanner = struct {
    text: []const u8,
    radix: u8,
    pos: usize = 0,

    fn atEnd(s: *const Scanner) bool {
        return s.pos == s.text.len;
    }

    fn peek(s: *const Scanner) ?u8 {
        return if (s.pos < s.text.len) std.ascii.toLower(s.text[s.pos]) else null;
    }

    /// 基数 radix の数字の列(空でもよい)。
    fn digits(s: *Scanner) []const u8 {
        const start = s.pos;
        while (s.pos < s.text.len) : (s.pos += 1) {
            _ = std.fmt.charToDigit(s.text[s.pos], s.radix) catch break;
        }
        return s.text[start..s.pos];
    }

    /// `+inf.0` `-inf.0` `+nan.0` `-nan.0`。
    fn infnan(s: *Scanner) ?InfNan {
        const rest = s.text[s.pos..];
        if (rest.len < 6) return null;
        const negative = switch (rest[0]) {
            '+' => false,
            '-' => true,
            else => return null,
        };
        var word: [5]u8 = undefined;
        for (&word, rest[1..6]) |*d, c| d.* = std.ascii.toLower(c);
        const is_inf = std.mem.eql(u8, &word, "inf.0");
        if (!is_inf and !std.mem.eql(u8, &word, "nan.0")) return null;
        s.pos += 6;
        return if (is_inf)
            (if (negative) .negative_infinity else .positive_infinity)
        else
            (if (negative) .negative_nan else .positive_nan);
    }

    /// `<ureal R>`: 整数、有理数、(基数10のとき)小数。符号は呼び出し側が先に読んである。
    fn ureal(s: *Scanner, sign: Sign) ?Real {
        const start = s.pos;
        const whole = s.digits();
        if (s.radix == 10) {
            var fraction: []const u8 = "";
            var has_point = false;
            if (s.peek() == '.') {
                s.pos += 1;
                has_point = true;
                fraction = s.digits();
            }
            if (whole.len == 0 and fraction.len == 0) {
                s.pos = start;
                return null;
            }
            var exponent: []const u8 = "";
            if (s.peek() == 'e') {
                const marker = s.pos;
                s.pos += 1;
                const exponent_start = s.pos;
                if (s.peek() == '+' or s.peek() == '-') s.pos += 1;
                if (s.digits().len == 0) {
                    s.pos = marker;
                } else {
                    exponent = s.text[exponent_start..s.pos];
                }
            }
            if (has_point or exponent.len != 0) {
                return .{ .decimal = .{ .sign = sign, .whole = whole, .fraction = fraction, .exponent = exponent } };
            }
        } else if (whole.len == 0) {
            return null;
        }
        if (s.peek() == '/') {
            s.pos += 1;
            const denominator = s.digits();
            if (denominator.len == 0) {
                s.pos = start;
                return null;
            }
            return .{ .ratio = .{ .sign = sign, .numerator = whole, .denominator = denominator } };
        }
        return .{ .integer = .{ .sign = sign, .digits = whole } };
    }

    const SignedReal = struct {
        real: Real,
        /// 符号が書かれていたか。`<infnan>` は常に書かれている。
        explicit_sign: bool,
    };

    /// `<real R>`: 省略できる符号つきの `<ureal R>`、または `<infnan>`。
    fn real(s: *Scanner) ?SignedReal {
        if (s.infnan()) |v| return .{ .real = .{ .infnan = v }, .explicit_sign = true };
        const start = s.pos;
        var sign: Sign = .positive;
        const explicit = s.peek() == '+' or s.peek() == '-';
        if (explicit) {
            if (s.peek() == '-') sign = .negative;
            s.pos += 1;
        }
        const v = s.ureal(sign) orelse {
            s.pos = start;
            return null;
        };
        return .{ .real = v, .explicit_sign = explicit };
    }

    /// 末尾の虚数単位 `i` を読み、入力の終わりであることを確かめる。
    fn finishImaginary(s: *Scanner) bool {
        if (s.peek() != 'i') return false;
        s.pos += 1;
        return s.atEnd();
    }

    /// `<complex R>`
    fn complex(s: *Scanner) ?Shape {
        const first = s.real() orelse return s.unitImaginary();
        if (s.atEnd()) return .{ .real = first.real };
        switch (s.peek().?) {
            '@' => {
                s.pos += 1;
                const angle = s.real() orelse return null;
                if (!s.atEnd()) return null;
                return .{ .polar = .{ .magnitude = first.real, .angle = angle.real } };
            },
            // 実部の無い `+ureal i` と `<infnan> i`。符号が要る。
            'i' => {
                if (!first.explicit_sign or !s.finishImaginary()) return null;
                return .{ .rectangular = .{ .real = null, .imag = first.real } };
            },
            '+', '-' => {
                const imag = s.imaginary() orelse return null;
                return .{ .rectangular = .{ .real = first.real, .imag = imag } };
            },
            else => return null,
        }
    }

    /// 実部のあとの `+ureal i`、`-ureal i`、`+i`、`-i`、`<infnan> i`。
    fn imaginary(s: *Scanner) ?Real {
        if (s.infnan()) |v| {
            if (!s.finishImaginary()) return null;
            return .{ .infnan = v };
        }
        const sign: Sign = if (s.peek() == '-') .negative else .positive;
        s.pos += 1;
        if (s.peek() == 'i') {
            if (!s.finishImaginary()) return null;
            return .{ .integer = .{ .sign = sign, .digits = "1" } };
        }
        const v = s.ureal(sign) orelse return null;
        if (!s.finishImaginary()) return null;
        return v;
    }

    /// 全体が `+i` か `-i` のとき。
    fn unitImaginary(s: *Scanner) ?Shape {
        if (s.pos != 0 or s.text.len != 2) return null;
        const sign: Sign = switch (s.text[0]) {
            '+' => .positive,
            '-' => .negative,
            else => return null,
        };
        if (std.ascii.toLower(s.text[1]) != 'i') return null;
        return .{ .rectangular = .{ .real = null, .imag = .{ .integer = .{ .sign = sign, .digits = "1" } } } };
    }
};

test {
    std.testing.refAllDecls(@This());
}

const testing = std.testing;

fn int(sign: Sign, digits: []const u8) Real {
    return .{ .integer = .{ .sign = sign, .digits = digits } };
}

fn dec(sign: Sign, whole: []const u8, fraction: []const u8, exponent: []const u8) Real {
    return .{ .decimal = .{ .sign = sign, .whole = whole, .fraction = fraction, .exponent = exponent } };
}

fn expectScan(text: []const u8, default_radix: u8, want: Literal) !void {
    const got = scan(text, default_radix) orelse {
        std.debug.print("scan(\"{s}\", {d}) = null\n", .{ text, default_radix });
        return error.TestUnexpectedResult;
    };
    try testing.expectEqualDeep(want, got);
}

fn expectReal(text: []const u8, want: Real) !void {
    try expectScan(text, 10, .{ .radix = 10, .exactness = .unmarked, .shape = .{ .real = want } });
}

fn expectNot(text: []const u8, default_radix: u8) !void {
    if (scan(text, default_radix)) |got| {
        std.debug.print("scan(\"{s}\", {d}) = {any}\n", .{ text, default_radix, got });
        return error.TestUnexpectedResult;
    }
}

test "integers keep their sign and their digits as written" {
    try expectReal("42", int(.positive, "42"));
    try expectReal("+42", int(.positive, "42"));
    try expectReal("-42", int(.negative, "42"));
    try expectReal("0", int(.positive, "0"));
    try expectReal("007", int(.positive, "007"));
    try expectReal("-0", int(.negative, "0"));
}

test "radix and exactness prefixes, in either order, in either case" {
    try expectScan("#xFF", 10, .{ .radix = 16, .exactness = .unmarked, .shape = .{ .real = int(.positive, "FF") } });
    try expectScan("#XfF", 10, .{ .radix = 16, .exactness = .unmarked, .shape = .{ .real = int(.positive, "fF") } });
    try expectScan("#b101", 10, .{ .radix = 2, .exactness = .unmarked, .shape = .{ .real = int(.positive, "101") } });
    try expectScan("#o-17", 10, .{ .radix = 8, .exactness = .unmarked, .shape = .{ .real = int(.negative, "17") } });
    try expectScan("#d10", 16, .{ .radix = 10, .exactness = .unmarked, .shape = .{ .real = int(.positive, "10") } });
    try expectScan("#e#x10", 10, .{ .radix = 16, .exactness = .exact, .shape = .{ .real = int(.positive, "10") } });
    try expectScan("#X#E10", 10, .{ .radix = 16, .exactness = .exact, .shape = .{ .real = int(.positive, "10") } });
    try expectScan("#x#i10", 10, .{ .radix = 16, .exactness = .inexact, .shape = .{ .real = int(.positive, "10") } });
    try expectScan("#i10", 8, .{ .radix = 8, .exactness = .inexact, .shape = .{ .real = int(.positive, "10") } });
}

test "malformed prefixes are not numbers" {
    for ([_][]const u8{ "#x#x1", "#e#i1", "#e#e1", "#x#b1", "#e#x#d1", "#z1", "#", "#e", "#x", "#e#x", "# x1", "#x 1", "##x1" }) |text| {
        try expectNot(text, 10);
    }
}

test "the default radix applies without a prefix, and a prefix overrides it" {
    try expectScan("ff", 16, .{ .radix = 16, .exactness = .unmarked, .shape = .{ .real = int(.positive, "ff") } });
    try expectNot("ff", 10);
    try expectNot("12", 2);
    try expectNot("19", 8);
    try expectScan("#b101", 16, .{ .radix = 2, .exactness = .unmarked, .shape = .{ .real = int(.positive, "101") } });
    // 16進では e は桁で、指数部ではない。
    try expectScan("1e2", 16, .{ .radix = 16, .exactness = .unmarked, .shape = .{ .real = int(.positive, "1e2") } });
    // 小数は基数10のときだけ。
    try expectNot("1.5", 16);
    try expectNot("1.5", 2);
    try expectNot("#x1.5", 10);
    try expectNot("#b.1", 10);
}

test "ratios, including a zero denominator" {
    try expectReal("1/2", .{ .ratio = .{ .sign = .positive, .numerator = "1", .denominator = "2" } });
    try expectReal("-3/4", .{ .ratio = .{ .sign = .negative, .numerator = "3", .denominator = "4" } });
    try expectReal("+10/20", .{ .ratio = .{ .sign = .positive, .numerator = "10", .denominator = "20" } });
    try expectReal("1/0", .{ .ratio = .{ .sign = .positive, .numerator = "1", .denominator = "0" } });
    try expectScan("#xA/b", 10, .{ .radix = 16, .exactness = .unmarked, .shape = .{ .real = .{ .ratio = .{ .sign = .positive, .numerator = "A", .denominator = "b" } } } });
    for ([_][]const u8{ "1/", "/2", "1/2/3", "1/-2", "1/+2", "-/2", "1.5/2", "1/2.5", "1e2/3", "1/2e3", "1 /2", "1/ 2" }) |text| {
        try expectNot(text, 10);
    }
}

test "decimals with a point, an exponent, or both" {
    try expectReal("1.", dec(.positive, "1", "", ""));
    try expectReal(".5", dec(.positive, "", "5", ""));
    try expectReal("1.5", dec(.positive, "1", "5", ""));
    try expectReal("-1.5e10", dec(.negative, "1", "5", "10"));
    try expectReal("1E10", dec(.positive, "1", "", "10"));
    try expectReal("1e-3", dec(.positive, "1", "", "-3"));
    try expectReal("+.5e+2", dec(.positive, "", "5", "+2"));
    try expectReal("1.e2", dec(.positive, "1", "", "2"));
    try expectReal("0.0", dec(.positive, "0", "0", ""));
    for ([_][]const u8{ ".", "+.", "-.", ".e2", "1e", "1e+", "1e-", "e5", "1.5.2", "1e2.5", "1.5e", "1..5", "1e2e3", "1ee2" }) |text| {
        try expectNot(text, 10);
    }
}

test "the four infnan spellings, in either case, and nothing near them" {
    try expectReal("+inf.0", .{ .infnan = .positive_infinity });
    try expectReal("-inf.0", .{ .infnan = .negative_infinity });
    try expectReal("+nan.0", .{ .infnan = .positive_nan });
    try expectReal("-nan.0", .{ .infnan = .negative_nan });
    try expectReal("+INF.0", .{ .infnan = .positive_infinity });
    try expectReal("-NaN.0", .{ .infnan = .negative_nan });
    for ([_][]const u8{ "inf", "INF", "infinity", "nan", "NaN", "inf.0", "nan.0", "+inf", "+inf.", "+inf.00", "+inf.1", "-nan", "+infinity", "+inf.0.", "+ inf.0", "+inf.0 ", "++inf.0", "+inf.0e1" }) |text| {
        try expectNot(text, 10);
    }
}

test "spellings that std.fmt.parseFloat accepts but Scheme does not" {
    for ([_][]const u8{ "0x10", "0x1p3", "+0x1p-1", "1_000", "1_0.5", "0b1", "1p3", "infinity", "1e1_0" }) |text| {
        try expectNot(text, 10);
    }
}

test "complex numbers in rectangular form" {
    const one = Real{ .integer = .{ .sign = .positive, .digits = "1" } };
    try expectScan("1+2i", 10, .{ .radix = 10, .exactness = .unmarked, .shape = .{ .rectangular = .{ .real = int(.positive, "1"), .imag = int(.positive, "2") } } });
    try expectScan("1-2i", 10, .{ .radix = 10, .exactness = .unmarked, .shape = .{ .rectangular = .{ .real = int(.positive, "1"), .imag = int(.negative, "2") } } });
    try expectScan("+2i", 10, .{ .radix = 10, .exactness = .unmarked, .shape = .{ .rectangular = .{ .real = null, .imag = int(.positive, "2") } } });
    try expectScan("-2i", 10, .{ .radix = 10, .exactness = .unmarked, .shape = .{ .rectangular = .{ .real = null, .imag = int(.negative, "2") } } });
    try expectScan("+i", 10, .{ .radix = 10, .exactness = .unmarked, .shape = .{ .rectangular = .{ .real = null, .imag = one } } });
    try expectScan("-i", 10, .{ .radix = 10, .exactness = .unmarked, .shape = .{ .rectangular = .{ .real = null, .imag = int(.negative, "1") } } });
    try expectScan("1+i", 10, .{ .radix = 10, .exactness = .unmarked, .shape = .{ .rectangular = .{ .real = int(.positive, "1"), .imag = one } } });
    try expectScan("1-i", 10, .{ .radix = 10, .exactness = .unmarked, .shape = .{ .rectangular = .{ .real = int(.positive, "1"), .imag = int(.negative, "1") } } });
    try expectScan("+1+2I", 10, .{ .radix = 10, .exactness = .unmarked, .shape = .{ .rectangular = .{ .real = int(.positive, "1"), .imag = int(.positive, "2") } } });
    try expectScan("1/2+3/4i", 10, .{ .radix = 10, .exactness = .unmarked, .shape = .{ .rectangular = .{
        .real = .{ .ratio = .{ .sign = .positive, .numerator = "1", .denominator = "2" } },
        .imag = .{ .ratio = .{ .sign = .positive, .numerator = "3", .denominator = "4" } },
    } } });
    try expectScan("1e2+3.5e1i", 10, .{ .radix = 10, .exactness = .unmarked, .shape = .{ .rectangular = .{
        .real = dec(.positive, "1", "", "2"),
        .imag = dec(.positive, "3", "5", "1"),
    } } });
    try expectScan("#x1+eei", 10, .{ .radix = 16, .exactness = .unmarked, .shape = .{ .rectangular = .{ .real = int(.positive, "1"), .imag = int(.positive, "ee") } } });
    try expectScan("#e1.5-2i", 10, .{ .radix = 10, .exactness = .exact, .shape = .{ .rectangular = .{ .real = dec(.positive, "1", "5", ""), .imag = int(.negative, "2") } } });
}

test "complex numbers with infnan parts" {
    try expectScan("+inf.0i", 10, .{ .radix = 10, .exactness = .unmarked, .shape = .{ .rectangular = .{ .real = null, .imag = .{ .infnan = .positive_infinity } } } });
    try expectScan("-nan.0i", 10, .{ .radix = 10, .exactness = .unmarked, .shape = .{ .rectangular = .{ .real = null, .imag = .{ .infnan = .negative_nan } } } });
    try expectScan("1+inf.0i", 10, .{ .radix = 10, .exactness = .unmarked, .shape = .{ .rectangular = .{ .real = int(.positive, "1"), .imag = .{ .infnan = .positive_infinity } } } });
    try expectScan("1-nan.0i", 10, .{ .radix = 10, .exactness = .unmarked, .shape = .{ .rectangular = .{ .real = int(.positive, "1"), .imag = .{ .infnan = .negative_nan } } } });
    try expectScan("-inf.0+inf.0i", 10, .{ .radix = 10, .exactness = .unmarked, .shape = .{ .rectangular = .{ .real = .{ .infnan = .negative_infinity }, .imag = .{ .infnan = .positive_infinity } } } });
    try expectNot("inf.0i", 10);
    try expectNot("1+inf.0", 10);
    try expectNot("1+inf.0ii", 10);
}

test "complex numbers in polar form" {
    try expectScan("1@2", 10, .{ .radix = 10, .exactness = .unmarked, .shape = .{ .polar = .{ .magnitude = int(.positive, "1"), .angle = int(.positive, "2") } } });
    try expectScan("1.5@-2", 10, .{ .radix = 10, .exactness = .unmarked, .shape = .{ .polar = .{ .magnitude = dec(.positive, "1", "5", ""), .angle = int(.negative, "2") } } });
    try expectScan("+inf.0@1/2", 10, .{ .radix = 10, .exactness = .unmarked, .shape = .{ .polar = .{
        .magnitude = .{ .infnan = .positive_infinity },
        .angle = .{ .ratio = .{ .sign = .positive, .numerator = "1", .denominator = "2" } },
    } } });
    try expectScan("#b1@10", 10, .{ .radix = 2, .exactness = .unmarked, .shape = .{ .polar = .{ .magnitude = int(.positive, "1"), .angle = int(.positive, "10") } } });
}

test "malformed complex numbers" {
    for ([_][]const u8{
        "i", "I", "5i", "1+2", "1+2j", "1++2i", "+-i", "-+i", "1+i2", "1@", "@1", "@", "1@2@3", "1@2i", "1+2i3", "1 +2i", "1+ 2i", "1+2 i", "+", "-", "1+", "1-", "1+2ii", "1i+2", "1+2i+3i", "1+-2i", "1@+i", "+i@1", "+i+i", "+1i2", "1i", "+1.i.",
    }) |text| {
        try expectNot(text, 10);
    }
}

test "empty text, white space and non-ASCII digits are not numbers" {
    for ([_][]const u8{ "", " ", " 1", "1 ", "1\n", "\t1", "１", "+１", "1\xff", "\x001" }) |text| {
        try expectNot(text, 10);
    }
}

test "the slices point into the text that was scanned" {
    const text = "#x-Ab/cD";
    const got = scan(text, 10).?;
    const ratio = got.shape.real.ratio;
    const base = @intFromPtr(text.ptr);
    try testing.expect(@intFromPtr(ratio.numerator.ptr) >= base);
    try testing.expect(@intFromPtr(ratio.denominator.ptr) + ratio.denominator.len <= base + text.len);
    try testing.expectEqualStrings("Ab", ratio.numerator);
    try testing.expectEqualStrings("cD", ratio.denominator);
}

test "scan does not allocate and agrees on every prefix of a long input" {
    // 先頭からの各接頭辞を渡して、範囲外参照や停止しない読みが無いことを見る。
    const text = "#e#x-ABC/def+12/3Ei";
    for (0..text.len + 1) |n| _ = scan(text[0..n], 10);
    const dec_text = "-123.456e+78+9.0e-1i";
    for (0..dec_text.len + 1) |n| _ = scan(dec_text[0..n], 10);
}
