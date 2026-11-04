//! Numbers: making them, reading them, and writing them
//! (docs/design/numerics-and-unicode.md).
//!
//! 数を作る関数と正規化は、このファイルに閉じる。ほかのファイルは、`Value` の数の
//! 変種を直接作らない。リーダ(src/reader.zig)は `parse` を、プリンタ(src/printer.zig)
//! は `write` を呼ぶ。署名は docs/plans/0018-phase4-numeric-tower-unicode.md の
//! 「レーンの間の関数の署名」が正である。
//!
//! スライス 4e-1 は、複素数を除く4種(fixnum、bignum、ratnum、flonum)の `parse` と
//! `write` を入れた。スライス 4e-2 は、複素数(compnum)の構文と書き出しと、その正規化
//! (`makeRectangular`)を入れる。

const std = @import("std");
const value_mod = @import("../value.zig");
const heap_mod = @import("../heap.zig");
const bigint = @import("bigint.zig");
const exact = @import("exact.zig");
const flonum = @import("flonum.zig");
const syntax = @import("syntax.zig");
const tier = @import("../tier.zig");

const Value = value_mod.Value;
const Ratnum = value_mod.Ratnum;
const Compnum = value_mod.Compnum;
const Heap = heap_mod.Heap;
const Const = bigint.Const;
const Managed = bigint.Managed;

pub const Error = heap_mod.Error;

/// Whether `v` is a number.
pub fn isNumber(v: Value) bool {
    return switch (v.kind()) {
        .fixnum, .flonum, .bignum, .ratnum, .compnum => true,
        else => false,
    };
}

/// The integer `n` as a fixnum when it fits one, and as a bignum otherwise.
///
/// 整数を作る入口は、正規化(`i64` に収まる bignum は fixnum にする)をここで行う。
pub fn fromInteger(h: *Heap, n: Const) Error!Value {
    if (n.toInt(i64)) |small| return .fromFixnum(small) else |_| {}
    return .fromBignum(try h.createBignum(n));
}

/// The ratio `numerator / denominator` in lowest terms, with a positive denominator, as an
/// integer when the denominator comes to 1.
///
/// `denominator` は 0 でない。符号はどちらにあってもよい。作業領域は `gpa` から取り、
/// 返る前に返す。
pub fn makeRatio(h: *Heap, gpa: std.mem.Allocator, numerator: Const, denominator: Const) Error!Value {
    std.debug.assert(!denominator.eqlZero());
    var g = try bigint.gcd(gpa, numerator, denominator);
    defer g.deinit();
    var n = try bigint.divide(gpa, numerator, g.toConst(), .truncate);
    defer n.q.deinit();
    defer n.r.deinit();
    var d = try bigint.divide(gpa, denominator, g.toConst(), .truncate);
    defer d.q.deinit();
    defer d.r.deinit();
    if (!d.q.isPositive()) {
        d.q.negate();
        if (!n.q.eqlZero()) n.q.negate();
    }
    if (d.q.toConst().orderAgainstScalar(1) == .eq) return fromInteger(h, n.q.toConst());
    const numerator_value = try fromInteger(h, n.q.toConst());
    const denominator_value = try fromInteger(h, d.q.toConst());
    const ratnum = try h.create(Ratnum, .{ .numerator = numerator_value, .denominator = denominator_value });
    return .fromRatnum(ratnum);
}

/// The complex number `real` + `imag` i, as a real number when `imag` is an exact zero, and as a
/// compnum otherwise.
///
/// `real` と `imag` は、複素数でない数(fixnum、bignum、ratnum、flonum)である。部分の
/// 正確性が混ざるときは、正確なほうを不正確にして、両方をそろえる。そのため compnum の
/// 実部と虚部は、どちらも正確か、どちらも flonum である。虚部が不正確な0(`0.0`、`-0.0`)の
/// ものは、複素数のまま残す(R7RS 6.2.6 の `(real? -2.5+0.0i)` は偽)。
/// 作業領域は `gpa` から取り、返る前に返す。
///
/// Why: 部分の正確性の混在の扱いは、2026-10-22 に、そろえる案で決まった(設計文書
/// docs/design/numerics-and-unicode.md の複素数の節)。R7RS 6.2.1 は、正確な複素数は正確な
/// 実部と正確な虚部を持ち、それ以外は不正確な複素数とするだけである。6.2.6 は、
/// `real-part` と `imag-part` が、`make-rectangular` に正確な引数が渡された不正確な複素数に
/// 対して、正確な実数を返してよいとする。混在した部分は仕様が許すだけで必須ではないので、
/// そろえても仕様に反しない。
pub fn makeRectangular(h: *Heap, gpa: std.mem.Allocator, real: Value, imag: Value) Error!Value {
    std.debug.assert(isNumber(real) and isNumber(imag));
    std.debug.assert(real.kind() != .compnum and imag.kind() != .compnum);
    if (imag.asFixnum()) |n| if (n == 0) return real;
    var re = real;
    var im = imag;
    const real_exact = real.asFlonum() == null;
    const imag_exact = imag.asFlonum() == null;
    if (real_exact and !imag_exact) re = .fromFlonum(try toFlonum(gpa, real));
    if (!real_exact and imag_exact) im = .fromFlonum(try toFlonum(gpa, imag));
    const compnum = try h.create(Compnum, .{ .real = re, .imag = im });
    return .fromCompnum(compnum);
}

/// The complex number of magnitude `magnitude` and angle `angle` (R7RS 6.2.6 `make-polar`), or
/// null if `exact_required` and it has no exact value.
///
/// 角が正確な0なら、結果は大きさそのもの(正確さも保つ)。大きさが正確な0なら、正確な0。
/// それ以外は、`magnitude * cos(angle)` と `magnitude * sin(angle)` を `f64` で計算した、
/// 不正確な数である(虚部が不正確な0になれば、複素数のまま残る)。
pub fn makePolar(h: *Heap, gpa: std.mem.Allocator, magnitude: Value, angle: Value, exact_required: bool) Error!?Value {
    if (magnitude.asFixnum()) |n| if (n == 0) return magnitude;
    if (angle.asFixnum()) |n| if (n == 0) return magnitude;
    if (exact_required) return null;
    const m = try toFlonum(gpa, magnitude);
    const a = try toFlonum(gpa, angle);
    return try makeRectangular(h, gpa, .fromFlonum(m * @cos(a)), .fromFlonum(m * @sin(a)));
}

/// The `f64` nearest to the real number `v`.
pub fn toFlonum(gpa: std.mem.Allocator, v: Value) Error!f64 {
    if (v.asFlonum()) |x| return x;
    if (v.asFixnum()) |n| return @floatFromInt(n);
    if (v.asBignum()) |big| return exact.ratioToF64(gpa, big.toConst(), one);
    const ratnum = v.asRatnum().?;
    var numerator = try integerOf(gpa, ratnum.numerator);
    defer numerator.deinit();
    var denominator = try integerOf(gpa, ratnum.denominator);
    defer denominator.deinit();
    return exact.ratioToF64(gpa, numerator.toConst(), denominator.toConst());
}

/// A copy of the integer `v`, a fixnum or a bignum.
fn integerOf(gpa: std.mem.Allocator, v: Value) Error!Managed {
    if (v.asFixnum()) |n| return Managed.initSet(gpa, n);
    var copy = try Managed.init(gpa);
    errdefer copy.deinit();
    try copy.copy(v.asBignum().?.toConst());
    return copy;
}

/// Reads `text` as a number of R7RS 7.1.1 and returns it, normalized, or null if it is not one.
///
/// `default_radix`(2、8、10、16)は、基数の接頭辞が無いときの基数である。数でないか、表せない
/// 大きさ(置けない大きさの正確な整数、`#e+inf.0`、分母が0の `1/0`)なら null を返し、内容を
/// 理由に誤りを送出しない(R7RS 6.2.7)。複素数は、直交形式(`a+bi`、`+bi`、`+i`)と極形式
/// (`a@b`)を読む。部分の正確性が混ざるものは、両方を不正確にそろえる(`makeRectangular`)。
/// 極形式の角が正確な0でも大きさが0でもなければ、結果は不正確になるので、`#e` の綴りは null になる。
/// 綴りの桁数が `max_spelling_digits` を超えるもの(整数、分子、分母、0 でない正確な小数)と、
/// 0 でない正確な小数の10進指数の絶対値が `max_spelling_exponent` を超えるものも null である
/// (時間の上限。部分ごとに見る)。不正確な小数と正確な 0 は、読む費用が小さいので掛けない。
///
/// 作業領域はヒープの上限に計上する。結果の大きさは、確保の前に(綴りの写しの確保も
/// 含めて)桁数と指数から見積もり、置けない大きさなら確保せずに null を返す。見積りは、
/// 読む数の限界値数に、作業用の `Managed`、除算の商と余りと作業用、`pow` の作業用、
/// ペイロードの写しを見込んだ倍率(`work_factor` と `work_slack`)で、上限の残りと比べる。
/// 上限にほかの作業が数えられていて断られたときだけ、`HeapLimit` になる。
pub fn parse(h: *Heap, text: []const u8, default_radix: u8) Error!?Value {
    const literal = syntax.scan(text, default_radix) orelse return null;
    h.external_refused = false;
    const before = h.beginCounting(true);
    defer h.endCounting(before);
    var charged: heap_mod.Charged = .{ .heap = h, .backing = h.backing };
    return parseShape(h, charged.allocator(), literal) catch |e| switch (e) {
        error.OutOfMemory => if (h.external_refused) error.HeapLimit else error.OutOfMemory,
        error.HeapLimit => error.HeapLimit,
    };
}

/// How many times the bytes of the limbs that a number is read from the work of reading
/// it may take at the most, and the bytes it takes whatever the size.
/// Why: 実測した(2026-10-22、ヒープの上限を二分探索して、読み込みが成功する最小の上限を
/// 求めた)。桁数が 2000 から 20000 の乱数で、整数は 2.0 倍、`#i` の整数は 1.0 倍、分数は
/// 分子と分母の合計の 5.0 倍(約分と除算の商と余りと作業用)、`#e1e-N` は冪の 4.4 倍、
/// `#e1eN` は 2.7 倍だった。小さい入力には約 700 バイトの固定費がある。そこで 8 倍と
/// 2048 バイトを見込む。見積りを通ったあとで確保が断られないことは、テストが上限を
/// 掃引して固定する。
///
/// 倍率を一律にした理由: 種類ごとに倍率を分けると、分岐が増え、倍率が足りない種類で
/// `HeapLimit` の誤りが出る(R7RS 6.2.7 は内容を理由に誤りを出さない)。大きめの見積りは、
/// 置ける数が `#f` になる側に倒れ、「ヒープに収まらない数は `#f`」という方針の内側に
/// 収まる。受け入れた制約として、独立レビューの実測(2026-10-22)では、見積りが実際の
/// ピークの何倍かは、整数が 4.1、`#i` の整数が 8.2 から 9.3、同程度の桁の分数が 1.6 から
/// 1.7、10進小数が 1.4、`#e1eN` が 3.0、`#e1.5e4000` が 3.3 である。したがって、`#i` の
/// 整数と偏った分数は、実際に要る上限の約 8 から 9 倍、整数は約 4 倍の余地が無いと `#f`
/// になる。
const work_factor = 8;
const work_slack = 2048;

/// Whether a number read from `limbs` limbs can be made in what room the heap has left.
fn fitsInHeap(h: *const Heap, limbs: usize) bool {
    const room = h.options.limit -| h.held();
    return limbs *| @sizeOf(value_mod.Limb) *| work_factor +| work_slack <= room;
}

/// The most digits a spelling may have (a whole number, a numerator, a denominator, or the
/// whole part and the fraction part of an exact decimal together, leading zeros counted), and
/// the largest size of the exponent of an exact decimal; a spelling over either is not read.
/// An inexact decimal and an exact zero are not limited.
///
/// Why: 読む時間は、桁数と指数に対して2乗に近く伸びる(`bigint` の桁の読み取り、累乗、
/// 約分の gcd、除算)。ヒープの上限に収まる綴りでも、既定の上限(256MiB)では、読むのに
/// 数十秒かかる(ReleaseSafe で `#e1e10000000` が約30秒)。そこで綴りの大きさに上限を置く。
/// 値は、2026-10-23 に、実測を示して決まった(いずれも ReleaseSafe で、WASM は未測定)。
/// 1つの実数で、桁数10万と指数±100万のとき、数字が同じ並び(9だけなど)なら約0.6秒、
/// 乱数の桁なら約1.7秒(`#e` + 乱数99,999桁 + `e-1000000` が1.6秒、乱数100,000桁の分数が
/// 1.1秒)かかる。複素数と極形式は部分ごとに見るので、部分の数だけ増え、両部が最悪の綴りなら
/// 約3秒になる。R7RS 6.2.7 は内容を理由に誤りを出さないので、超えた綴りは
/// 数でないものと同じく null を返す(`string->number` は `#f`)。ヒープの上限と同じ側に倒れる。
/// 後から緩めるのは、互換を壊さない。
///
/// 不正確な小数(`1e999999999`、桁数が多い `1.5`)と、仮数が0の正確な小数(`#e0e999999999`)は
/// 掛けない。読む費用が桁数に線形で、桁数1000万の小数でも約20ミリ秒だった(2026-10-23、
/// ReleaseSafe)ので、時間の理由が無い。掛けると、`+inf.0` や 0 と読むのが標準の綴りが
/// `#f` になる。`#i` つきの整数と有理数は、内部で正確な数を通るので掛ける。
const max_spelling_digits = 100_000;
const max_spelling_exponent = 1_000_000;

const one_limbs = [_]value_mod.Limb{1};
const one: Const = .{ .limbs = &one_limbs, .positive = true };
const ten_limbs = [_]value_mod.Limb{10};
const ten: Const = .{ .limbs = &ten_limbs, .positive = true };

fn parseShape(h: *Heap, gpa: std.mem.Allocator, literal: syntax.Literal) Error!?Value {
    switch (literal.shape) {
        .real => |r| return parseReal(h, gpa, literal, r),
        .rectangular => |c| {
            // 実部が書かれていなければ、正確な0である(`+2.5i` は 0 + 2.5i)。
            const real: Value = if (c.real) |r| (try parseReal(h, gpa, literal, r)) orelse return null else .fromFixnum(0);
            const imag = (try parseReal(h, gpa, literal, c.imag)) orelse return null;
            return try makeRectangular(h, gpa, real, imag);
        },
        .polar => |p| {
            const magnitude = (try parseReal(h, gpa, literal, p.magnitude)) orelse return null;
            const angle = (try parseReal(h, gpa, literal, p.angle)) orelse return null;
            return try makePolar(h, gpa, magnitude, angle, literal.exactness == .exact);
        },
    }
}

fn parseReal(h: *Heap, gpa: std.mem.Allocator, literal: syntax.Literal, real: syntax.Real) Error!?Value {
    const inexact = literal.exactness == .inexact;
    switch (real) {
        .infnan => |kind| {
            if (literal.exactness == .exact) return null;
            return .fromFlonum(switch (kind) {
                .positive_infinity => std.math.inf(f64),
                .negative_infinity => -std.math.inf(f64),
                .positive_nan, .negative_nan => std.math.nan(f64),
            });
        },
        .integer => |i| {
            if (i.digits.len > max_spelling_digits) return null;
            if (!fitsInHeap(h, bigint.limbsForDigits(i.digits.len, literal.radix))) return null;
            var n = try bigint.parseDigits(gpa, i.digits, literal.radix);
            defer n.deinit();
            // Why: `#i-0` は -0.0 である。基数10以外で -0.0 を書くと `#i-0` になる(`write`)ので、
            // これを -0.0 と読まないと、R7RS 6.2.7 の往復条件 `(eqv? z (string->number
            // (number->string z radix) radix))` が -0.0 で成り立たない。小数点の綴りは基数10に限る。
            // 往復条件の式と、「結果は明示的な基数接頭辞を含まない」という文は、
            // docs/spec/errata-corrected-r7rs.pdf の 6.2.7 の原文で照合した(2026-10-22)。
            if (inexact) return .fromFlonum(signedF64(i.sign, try exact.ratioToF64(gpa, n.toConst(), one)));
            applySign(&n, i.sign);
            return try fromInteger(h, n.toConst());
        },
        .ratio => |r| {
            if (r.numerator.len > max_spelling_digits or r.denominator.len > max_spelling_digits) return null;
            if (!fitsInHeap(h, bigint.limbsForDigits(r.numerator.len, literal.radix) +| bigint.limbsForDigits(r.denominator.len, literal.radix))) return null;
            var d = try bigint.parseDigits(gpa, r.denominator, literal.radix);
            defer d.deinit();
            if (d.eqlZero()) return null;
            var n = try bigint.parseDigits(gpa, r.numerator, literal.radix);
            defer n.deinit();
            if (inexact) return .fromFlonum(signedF64(r.sign, try exact.ratioToF64(gpa, n.toConst(), d.toConst())));
            applySign(&n, r.sign);
            return try makeRatio(h, gpa, n.toConst(), d.toConst());
        },
        .decimal => |d| {
            if (literal.exactness == .exact) return try parseExactDecimal(h, gpa, d);
            const x = (try parseInexactDecimal(gpa, d)) orelse return null;
            return .fromFlonum(signedF64(d.sign, x));
        },
    }
}

/// The spelling of a decimal as written, without its sign: the whole part, the point, the
/// fraction part and the exponent.
///
/// Why: `syntax.scan` は、綴りの全体を渡さず、整数部、小数部、指数部の切片に分ける。
/// 整数部は常に入力の中を指し(空でも、その位置を指す)、小数部は小数点があれば入力の
/// 中を、指数部は書かれていれば入力の中を指す。綴りの終わりは、指数部があればその終わり、
/// 無ければ小数部の終わり(指数部が無い decimal は小数点を持つ)である。この前提は、
/// このファイルのテスト(「decimalSpelling」)が、書き方ごとに固定する。
fn decimalSpelling(d: anytype) []const u8 {
    const start = @intFromPtr(d.whole.ptr);
    const end = if (d.exponent.len != 0)
        @intFromPtr(d.exponent.ptr) + d.exponent.len
    else
        @intFromPtr(d.fraction.ptr) + d.fraction.len;
    const first: [*]const u8 = d.whole.ptr;
    return first[0 .. end - start];
}

/// The value of an inexact decimal as a double.
///
/// Why: 指数の印は `e` のほかに `s` `f` `d` `l` を受け付ける(`syntax.scan`)。`std.fmt.parseFloat`
/// は `e` しか指数の印として読まないので、ほかの印のときだけ、印を `e` に置いた写しを渡す。
/// 短い綴りはスタックの領域に写す。長い綴りは `gpa`(ヒープの上限に計上される)に写す。
/// 印が `e` か指数部が無い綴りは、写さない。
fn parseInexactDecimal(gpa: std.mem.Allocator, d: anytype) Error!?f64 {
    const text = decimalSpelling(d);
    if (d.exponent.len == 0) return flonum.parseDecimal(text) catch null;
    const marker = @intFromPtr(d.exponent.ptr) - @intFromPtr(text.ptr) - 1;
    if (text[marker] == 'e' or text[marker] == 'E') return flonum.parseDecimal(text) catch null;
    var stack: [256]u8 = undefined;
    const heap_copy: ?[]u8 = if (text.len <= stack.len) null else try gpa.alloc(u8, text.len);
    defer if (heap_copy) |c| gpa.free(c);
    const copy = heap_copy orelse stack[0..text.len];
    @memcpy(copy, text);
    copy[marker] = 'e';
    return flonum.parseDecimal(copy) catch null;
}

fn signedF64(sign: syntax.Sign, magnitude: f64) f64 {
    return if (sign == .negative) -magnitude else magnitude;
}

/// Gives `n` the sign, unless it is zero.
fn applySign(n: *Managed, sign: syntax.Sign) void {
    if (sign == .negative and !n.eqlZero()) n.negate();
}

/// The largest magnitude an exponent is read as; a larger one is read as this.
/// Why: 指数部の桁数に上限は無い(`1e99999999999999999999`)。読んだ値が `i64` からあふれ
/// ないよう、ここで頭打ちにする。この大きさの指数は、どのヒープの上限にも収まらない。
const max_exponent: i64 = 1 << 40;

fn parseExponent(text: []const u8) i64 {
    var i: usize = 0;
    var negative = false;
    if (i < text.len and (text[i] == '+' or text[i] == '-')) {
        negative = text[i] == '-';
        i += 1;
    }
    var value: i64 = 0;
    for (text[i..]) |c| value = @min(value *| 10 +| (c - '0'), max_exponent);
    return if (negative) -value else value;
}

/// The digit `index` places from the start of the whole part, over the whole part and the
/// fraction part taken as one run of digits.
fn digitAt(whole: []const u8, fraction: []const u8, index: usize) u8 {
    return if (index < whole.len) whole[index] else fraction[index - whole.len];
}

/// The exact value of a decimal that `#e` is on: the digits, times a power of ten.
fn parseExactDecimal(h: *Heap, gpa: std.mem.Allocator, d: anytype) Error!?Value {
    // 桁は整数部と小数部を続けて数える。先頭の0を飛ばして有効桁の数を決め、見積りを通って
    // から、有効桁だけを写す(桁数に比例する確保も、見積りの前には行わない)。
    const total = d.whole.len + d.fraction.len;
    var start: usize = 0;
    while (start < total and digitAt(d.whole, d.fraction, start) == '0') start += 1;
    // 0 は、どんな指数でも 0 である。
    if (start == total) return .fromFixnum(0);
    if (total > max_spelling_digits or @abs(parseExponent(d.exponent)) > max_spelling_exponent) return null;
    const exponent10 = parseExponent(d.exponent) - @as(i64, @intCast(d.fraction.len));
    const power_limbs = bigint.limbsForPow(ten, @abs(exponent10)) orelse return null;
    if (!fitsInHeap(h, bigint.limbsForDigits(total - start, 10) +| power_limbs)) return null;
    const significant = try gpa.alloc(u8, total - start);
    defer gpa.free(significant);
    for (significant, start..) |*c, i| c.* = digitAt(d.whole, d.fraction, i);
    var m = try bigint.parseDigits(gpa, significant, 10);
    defer m.deinit();
    var power = try bigint.pow(gpa, ten, @abs(exponent10));
    defer power.deinit();
    if (exponent10 >= 0) {
        var product = try bigint.mul(gpa, m.toConst(), power.toConst());
        defer product.deinit();
        applySign(&product, d.sign);
        return try fromInteger(h, product.toConst());
    }
    applySign(&m, d.sign);
    return try makeRatio(h, gpa, m.toConst(), power.toConst());
}

/// Writes the number `v` in the external representation of `radix`, which is
/// 2, 8, 10 or 16 (R7RS 6.2.7).
/// `scratch` は作業領域で、戻る前に取ったものを返す。
///
/// 基数10以外の有限の浮動小数点数は、正確な有理数に直して `#i` を前に付ける(`#i1/10`)。
/// 無限大と NaN は、基数によらず `+inf.0` `-inf.0` `+nan.0` と書く(`number->string` も、
/// 基数10以外で誤りにせず、この綴りを返す。`string->number` はどの基数でも読み戻せる)。
///
/// 複素数は、実部、符号つきの虚部、`i` の順に書く(`1+2i`、`1.5-2.5i`)。実部が正確な0なら実部を
/// 書かず(`+2i`)、虚部が正確な1と-1なら数を書かない(`+i`、`-i`)。部分が flonum で基数が
/// 10以外のときは、先頭に `#i` を1つだけ置き、部分は接頭辞なしの正確な有理数で書く
/// (`#i1/10+1/100i`)。読み戻すと、`#i` が両方の部分に効く。
pub fn write(out: *std.Io.Writer, scratch: std.mem.Allocator, v: Value, radix: u8) (std.Io.Writer.Error || error{OutOfMemory})!void {
    std.debug.assert(isNumber(v));
    std.debug.assert(radix == 2 or radix == 8 or radix == 10 or radix == 16);
    switch (v.kind()) {
        .fixnum, .bignum => try writeInteger(out, scratch, v, radix),
        .ratnum => {
            const ratnum = v.asRatnum().?;
            try writeInteger(out, scratch, ratnum.numerator, radix);
            try out.writeByte('/');
            try writeInteger(out, scratch, ratnum.denominator, radix);
        },
        .flonum => try writeFlonum(out, scratch, v.asFlonum().?, radix),
        .compnum => try writeComplex(out, scratch, v.asCompnum().?, radix),
        else => unreachable,
    }
}

fn writeComplex(out: *std.Io.Writer, scratch: std.mem.Allocator, c: *const Compnum, radix: u8) (std.Io.Writer.Error || error{OutOfMemory})!void {
    const inexact = c.real.asFlonum() != null;
    // 部分の `#i` は、全体の先頭に1つだけ置く。基数10の flonum は接頭辞を持たない。
    if (inexact and radix != 10) try out.writeAll("#i");
    if (c.real.asFixnum() != 0) try writePart(out, scratch, c.real, radix);
    if (c.imag.asFixnum()) |n| {
        if (n == 1) return out.writeAll("+i");
        if (n == -1) return out.writeAll("-i");
    }
    var imag: std.Io.Writer.Allocating = .init(scratch);
    defer imag.deinit();
    try writePart(&imag.writer, scratch, c.imag, radix);
    const text = imag.written();
    // 符号の無い虚部(`1/10`、`2.5`)には `+` を付ける。`+inf.0` と負の数は、符号を持っている。
    if (text[0] != '+' and text[0] != '-') try out.writeByte('+');
    try out.writeAll(text);
    try out.writeByte('i');
}

fn writePart(out: *std.Io.Writer, scratch: std.mem.Allocator, v: Value, radix: u8) (std.Io.Writer.Error || error{OutOfMemory})!void {
    if (v.asFlonum()) |x| return writeFlonumIn(out, scratch, x, radix, false);
    try write(out, scratch, v, radix);
}

fn writeInteger(out: *std.Io.Writer, scratch: std.mem.Allocator, v: Value, radix: u8) (std.Io.Writer.Error || error{OutOfMemory})!void {
    if (v.asFixnum()) |n| return out.printInt(n, radix, .lower, .{});
    const text = try bigint.toString(scratch, v.asBignum().?.toConst(), radix);
    defer scratch.free(text);
    try out.writeAll(text);
}

fn writeFlonum(out: *std.Io.Writer, scratch: std.mem.Allocator, x: f64, radix: u8) (std.Io.Writer.Error || error{OutOfMemory})!void {
    return writeFlonumIn(out, scratch, x, radix, true);
}

/// `x` を書く。`with_prefix` が偽なら、基数10以外の `#i` を書かない。
fn writeFlonumIn(out: *std.Io.Writer, scratch: std.mem.Allocator, x: f64, radix: u8, with_prefix: bool) (std.Io.Writer.Error || error{OutOfMemory})!void {
    if (radix == 10 or !std.math.isFinite(x)) return flonum.write(out, x);
    var value = try exact.fromF64(scratch, x);
    defer value.deinit();
    if (with_prefix) try out.writeAll("#i");
    if (std.math.signbit(x)) try out.writeByte('-');
    const numerator = try bigint.toString(scratch, value.numerator.toConst(), radix);
    defer scratch.free(numerator);
    try out.writeAll(numerator);
    if (value.denominator.toConst().orderAgainstScalar(1) != .eq) {
        const denominator = try bigint.toString(scratch, value.denominator.toConst(), radix);
        defer scratch.free(denominator);
        try out.writeByte('/');
        try out.writeAll(denominator);
    }
}

test {
    std.testing.refAllDecls(@This());
    // Why: 純粋な層のテストを単体テストの集合に載せる。`syntax.zig` は `parse` が呼ぶので
    // 要らないが、`exact.zig` と `flonum.zig` の参照は、ここと src/sucheme.zig の両方にある。
    _ = @import("syntax.zig");
}

test "isNumber answers for the five kinds of number and nothing else" {
    var limbs = [_]value_mod.Limb{1};
    var b: value_mod.Bignum = .{ .limbs = &limbs, .positive = true };
    var r: value_mod.Ratnum = .{ .numerator = .fromFixnum(1), .denominator = .fromFixnum(2) };
    var c: value_mod.Compnum = .{ .real = .fromFixnum(1), .imag = .fromFixnum(1) };
    for ([_]Value{ .fromFixnum(0), .fromFlonum(0.5), .fromBignum(&b), .fromRatnum(&r), .fromCompnum(&c) }) |v| {
        try std.testing.expect(isNumber(v));
    }
    var p: value_mod.Pair = .{ .car = .fromFixnum(1), .cdr = .empty_list_value };
    var bytes = "1".*;
    var s: value_mod.String = .{ .bytes = &bytes, .is_ascii = true };
    var items = [_]Value{.fromFixnum(1)};
    var vec: value_mod.Vector = .{ .items = &items };
    for ([_]Value{ .fromBool(false), .empty_list_value, .fromCharacter('1'), .unspecified_value, .eof_value, .fromSymbol(@fromBackingInt(@intCast(0))), .{ .pair = &p }, .fromString(&s), .fromVector(&vec) }) |v| {
        try std.testing.expect(!isNumber(v));
    }
}

const testing = std.testing;

fn zeros(comptime n: usize) [n]u8 {
    return @splat('0');
}

const zeros_90000 = zeros(90000);

/// Reads `text` and writes the result in radix 10, or returns null if it is not a number.
fn readWrite(h: *Heap, text: []const u8, default_radix: u8, out_radix: u8) !?[]u8 {
    const v = (try parse(h, text, default_radix)) orelse return null;
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    errdefer aw.deinit();
    try write(&aw.writer, testing.allocator, v, out_radix);
    return try aw.toOwnedSlice();
}

fn expectReads(h: *Heap, expected: ?[]const u8, text: []const u8) !void {
    const got = try readWrite(h, text, 10, 10);
    defer if (got) |g| testing.allocator.free(g);
    if (expected) |e| {
        try testing.expect(got != null);
        try testing.expectEqualStrings(e, got.?);
    } else {
        try testing.expect(got == null);
    }
}

test "parse reads the integers of the four radixes, with prefixes in either case" {
    var h: Heap = .init(testing.allocator, .{});
    defer h.deinit();
    try expectReads(&h, "0", "0");
    try expectReads(&h, "0", "-0");
    try expectReads(&h, "42", "+42");
    try expectReads(&h, "-17", "-17");
    try expectReads(&h, "255", "#xff");
    try expectReads(&h, "255", "#XFF");
    try expectReads(&h, "-255", "#x-Ff");
    try expectReads(&h, "5", "#b101");
    try expectReads(&h, "15", "#o17");
    try expectReads(&h, "10", "#d10");
    try expectReads(&h, "10", "#e10");
    try expectReads(&h, "10.0", "#i10");
    try expectReads(&h, "255", "#e#xff");
    try expectReads(&h, "255.0", "#x#iff");
    // 既定の基数は、接頭辞が無いときだけ効く。
    const got = (try readWrite(&h, "ff", 16, 10)).?;
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("255", got);
    const prefixed = (try readWrite(&h, "#o177", 2, 10)).?;
    defer testing.allocator.free(prefixed);
    try testing.expectEqualStrings("127", prefixed);
}

test "parse makes a fixnum for every integer that fits an i64, and a bignum for the rest" {
    var h: Heap = .init(testing.allocator, .{});
    defer h.deinit();
    for ([_]struct { text: []const u8, kind: value_mod.Kind }{
        .{ .text = "9223372036854775807", .kind = .fixnum },
        .{ .text = "9223372036854775808", .kind = .bignum },
        .{ .text = "-9223372036854775808", .kind = .fixnum },
        .{ .text = "-9223372036854775809", .kind = .bignum },
        .{ .text = "00000000000000000000000000000000000000000012", .kind = .fixnum },
        .{ .text = "123456789012345678901234567890", .kind = .bignum },
        .{ .text = "#e1e30", .kind = .bignum },
        .{ .text = "#e9223372036854775808e0", .kind = .bignum },
    }) |case| {
        const v = (try parse(&h, case.text, 10)).?;
        try testing.expectEqual(case.kind, v.kind());
        if (v.asBignum()) |big| {
            // 上位の限界値は0でなく、符号は値と合っている。
            try testing.expect(big.limbs[big.limbs.len - 1] != 0);
            try testing.expectEqual(case.text[0] != '-', big.positive);
        }
    }
    try expectReads(&h, "123456789012345678901234567890", "123456789012345678901234567890");
    try expectReads(&h, "-123456789012345678901234567890", "-123456789012345678901234567890");
    try expectReads(&h, "1208925819614629174706175", "#xFFFFFFFFFFFFFFFFFFFF");
    try expectReads(&h, "1000000000000000000000000000000", "#e1e30");
}

test "parse reduces a ratio to lowest terms with a positive denominator, and makes an integer of x/1" {
    var h: Heap = .init(testing.allocator, .{});
    defer h.deinit();
    try expectReads(&h, "1/2", "1/2");
    try expectReads(&h, "-3/2", "-6/4");
    try expectReads(&h, "3/2", "+6/4");
    try expectReads(&h, "2", "4/2");
    try expectReads(&h, "0", "0/5");
    try expectReads(&h, "0", "-0/5");
    try expectReads(&h, "1/3", "#x2/6");
    try expectReads(&h, "1/2", "#b1/10");
    try expectReads(&h, "12345678901234567890/7", "12345678901234567890/7");
    try expectReads(&h, "1/12345678901234567890123", "1000000/12345678901234567890123000000");
    const r = (try parse(&h, "1/2", 10)).?;
    try testing.expectEqual(value_mod.Kind.ratnum, r.kind());
    // 分母が0は、数でない(誤りにしない)。
    try expectReads(&h, null, "1/0");
    try expectReads(&h, null, "-1/0");
    try expectReads(&h, null, "#i1/0");
    try expectReads(&h, null, "0/0");
}

test "parse reads a decimal as a flonum, and as an exact ratio after #e" {
    var h: Heap = .init(testing.allocator, .{});
    defer h.deinit();
    try expectReads(&h, "1.5", "1.5");
    try expectReads(&h, "1.0", "1.");
    try expectReads(&h, "0.5", ".5");
    try expectReads(&h, "100.0", "1e2");
    try expectReads(&h, "100.0", "1E2");
    try expectReads(&h, "0.0015", "1.5e-3");
    try expectReads(&h, "-0.0", "-0.0");
    try expectReads(&h, "-0.0", "#i-0");
    try expectReads(&h, "0.1", "#i0.1");
    try expectReads(&h, "+inf.0", "1e400");
    try expectReads(&h, "-inf.0", "-1e400");
    try expectReads(&h, "0.0", "1e-400");
    try expectReads(&h, "3/2", "#e1.5");
    try expectReads(&h, "1/2", "#e.5");
    try expectReads(&h, "1", "#e1.");
    try expectReads(&h, "1000", "#e1e3");
    try expectReads(&h, "3/2000", "#e1.5e-3");
    try expectReads(&h, "-3/2", "#e-1.5");
    try expectReads(&h, "1/10", "#e0.1");
    try expectReads(&h, "0", "#e-0.0");
    try expectReads(&h, "0", "#e0e999999999");
    try expectReads(&h, "0", "#e0.000e-999999999");
    try expectReads(&h, "100", "#e1.00e2");
    try expectReads(&h, "1", "#e1000e-3");
    // 符号は、整数にも分数にも付く。
    try expectReads(&h, "-1000", "#e-1e3");
    try expectReads(&h, "-1500", "#e-1.5e3");
    try expectReads(&h, "-12", "#e-12.");
    try expectReads(&h, "-1/8", "#e-0.125");
    try expectReads(&h, "1000", "#e+1e3");
}

test "parse reads a ratio or an integer as a flonum after #i, with the nearest value" {
    var h: Heap = .init(testing.allocator, .{});
    defer h.deinit();
    try expectReads(&h, "0.3333333333333333", "#i1/3");
    try expectReads(&h, "-0.3333333333333333", "#i-1/3");
    try expectReads(&h, "0.5", "#x#i1/2");
    try expectReads(&h, "9007199254740992.0", "#i9007199254740993");
    try expectReads(&h, "1.2345678901234568e+29", "#i123456789012345678901234567890");
    try expectReads(&h, "+inf.0", "#i1000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000");
}

test "parse reads the infinities and NaN, and refuses them after #e" {
    var h: Heap = .init(testing.allocator, .{});
    defer h.deinit();
    try expectReads(&h, "+inf.0", "+inf.0");
    try expectReads(&h, "-inf.0", "-inf.0");
    try expectReads(&h, "+nan.0", "+nan.0");
    try expectReads(&h, "+nan.0", "-nan.0");
    try expectReads(&h, "+inf.0", "#i+inf.0");
    try expectReads(&h, "+inf.0", "+INF.0");
    try expectReads(&h, null, "#e+inf.0");
    try expectReads(&h, null, "#e-inf.0");
    try expectReads(&h, null, "#e+nan.0");
}

test "parse says no to what is not a number, including what looks like a complex number" {
    var h: Heap = .init(testing.allocator, .{});
    defer h.deinit();
    for ([_][]const u8{ "", "abc", "+", "-", "...", "1/2/3", "--1", "1e", "e1", "inf", "nan", "1_000", "0x10", "#", "#x", "#xg", "#e#e1", "#b2", "1.5/2", "#x1.5" }) |text| {
        try expectReads(&h, null, text);
    }
    for ([_][]const u8{ "i", "1+2", "1+2j", "1+i+i", "1+2i3", "@", "1@", "@1", "1@2@3", "+i2", "i+1", "1 +2i", "1+ 2i", "1+-2i", "1++2i", "1+2ii", "1i", "1+2I3", "#e+inf.0i", "#e1+nan.0i", "1/0+i", "1+1/0i", "1@1/0", "1/0@1" }) |text| {
        try expectReads(&h, null, text);
    }
}

test "parse reads complex numbers in the rectangular form" {
    var h: Heap = .init(testing.allocator, .{});
    defer h.deinit();
    for ([_]struct { text: []const u8, expected: []const u8 }{
        .{ .text = "1+2i", .expected = "1+2i" },
        .{ .text = "1-2i", .expected = "1-2i" },
        .{ .text = "-1+2i", .expected = "-1+2i" },
        .{ .text = "+2i", .expected = "+2i" },
        .{ .text = "-2i", .expected = "-2i" },
        .{ .text = "+i", .expected = "+i" },
        .{ .text = "-i", .expected = "-i" },
        .{ .text = "+I", .expected = "+i" },
        .{ .text = "1+i", .expected = "1+i" },
        .{ .text = "1-i", .expected = "1-i" },
        .{ .text = "1/2+3/4i", .expected = "1/2+3/4i" },
        .{ .text = "-1/2-3/4i", .expected = "-1/2-3/4i" },
        .{ .text = "+1/2i", .expected = "+1/2i" },
        .{ .text = "6/4+10/4i", .expected = "3/2+5/2i" },
        .{ .text = "123456789012345678901234567890+98765432109876543210987654321i", .expected = "123456789012345678901234567890+98765432109876543210987654321i" },
        .{ .text = "1.5+2.5i", .expected = "1.5+2.5i" },
        .{ .text = "1.5-2.5i", .expected = "1.5-2.5i" },
        .{ .text = "1e2+3.5e1i", .expected = "100.0+35.0i" },
        .{ .text = "1E2+3.5E1I", .expected = "100.0+35.0i" },
        .{ .text = "+1.5i", .expected = "0.0+1.5i" },
        .{ .text = "-.5e2i", .expected = "0.0-50.0i" },
        .{ .text = "#x1+eei", .expected = "1+238i" },
        .{ .text = "#b1+1i", .expected = "1+i" },
        .{ .text = "#b+i", .expected = "+i" },
        .{ .text = "#o7-10i", .expected = "7-8i" },
    }) |case| try expectReads(&h, case.expected, case.text);
    const z = (try parse(&h, "1+2i", 10)).?;
    try testing.expectEqual(value_mod.Kind.compnum, z.kind());
}

test "parse makes an exact zero imaginary part a real number, and an inexact one not" {
    var h: Heap = .init(testing.allocator, .{});
    defer h.deinit();
    for ([_]struct { text: []const u8, expected: []const u8, kind: value_mod.Kind }{
        .{ .text = "3+0i", .expected = "3", .kind = .fixnum },
        .{ .text = "3-0i", .expected = "3", .kind = .fixnum },
        .{ .text = "1/2+0i", .expected = "1/2", .kind = .ratnum },
        .{ .text = "3.5+0i", .expected = "3.5", .kind = .flonum },
        .{ .text = "+0i", .expected = "0", .kind = .fixnum },
        .{ .text = "123456789012345678901234567890+0i", .expected = "123456789012345678901234567890", .kind = .bignum },
        .{ .text = "#e3.5+0.0i", .expected = "7/2", .kind = .ratnum },
        .{ .text = "3+0.0i", .expected = "3.0+0.0i", .kind = .compnum },
        .{ .text = "3.5+0.0i", .expected = "3.5+0.0i", .kind = .compnum },
        .{ .text = "3.5-0.0i", .expected = "3.5-0.0i", .kind = .compnum },
        .{ .text = "+0.0i", .expected = "0.0+0.0i", .kind = .compnum },
        .{ .text = "#i3+0i", .expected = "3.0+0.0i", .kind = .compnum },
    }) |case| {
        const v = (try parse(&h, case.text, 10)).?;
        try testing.expectEqual(case.kind, v.kind());
        var aw: std.Io.Writer.Allocating = .init(testing.allocator);
        defer aw.deinit();
        try write(&aw.writer, testing.allocator, v, 10);
        try testing.expectEqualStrings(case.expected, aw.written());
    }
}

test "parse makes both parts inexact when only one is, and keeps both exact when neither is" {
    var h: Heap = .init(testing.allocator, .{});
    defer h.deinit();
    for ([_]struct { text: []const u8, expected: []const u8 }{
        .{ .text = "1.5+2i", .expected = "1.5+2.0i" },
        .{ .text = "1+2.5i", .expected = "1.0+2.5i" },
        .{ .text = "1/3+2.5i", .expected = "0.3333333333333333+2.5i" },
        .{ .text = "1.5-1/4i", .expected = "1.5-0.25i" },
        .{ .text = "123456789012345678901234567890+1.5i", .expected = "1.2345678901234568e+29+1.5i" },
        .{ .text = "1+inf.0i", .expected = "1.0+inf.0i" },
        .{ .text = "+inf.0i", .expected = "0.0+inf.0i" },
        .{ .text = "-inf.0+nan.0i", .expected = "-inf.0+nan.0i" },
        .{ .text = "+nan.0i", .expected = "0.0+nan.0i" },
        .{ .text = "1-inf.0i", .expected = "1.0-inf.0i" },
        .{ .text = "#i1+2i", .expected = "1.0+2.0i" },
        .{ .text = "#i+i", .expected = "0.0+1.0i" },
        .{ .text = "#i1/2+1/4i", .expected = "0.5+0.25i" },
        .{ .text = "#e1.5+2i", .expected = "3/2+2i" },
        .{ .text = "#e1.5-2.5i", .expected = "3/2-5/2i" },
        .{ .text = "#e+1.5i", .expected = "+3/2i" },
        .{ .text = "1+2i", .expected = "1+2i" },
        // fixnum の実部の変換(2^53 を超えると丸める)。
        .{ .text = "4294967296+1.5i", .expected = "4294967296.0+1.5i" },
        .{ .text = "9007199254740993+0.5i", .expected = "9007199254740992.0+0.5i" },
    }) |case| try expectReads(&h, case.expected, case.text);
    // 部分の型を、数ごとに確かめる。
    const z = (try parse(&h, "1+2.5i", 10)).?.asCompnum().?;
    try testing.expectEqual(value_mod.Kind.flonum, z.real.kind());
    try testing.expectEqual(value_mod.Kind.flonum, z.imag.kind());
    const w = (try parse(&h, "1/2+3i", 10)).?.asCompnum().?;
    try testing.expectEqual(value_mod.Kind.ratnum, w.real.kind());
    try testing.expectEqual(value_mod.Kind.fixnum, w.imag.kind());
}

test "parse reads the polar form with the nearest values, and an exact number when the angle is exact zero" {
    var h: Heap = .init(testing.allocator, .{});
    defer h.deinit();
    try expectReads(&h, "1", "1@0");
    try expectReads(&h, "-3/2", "-3/2@0");
    try expectReads(&h, "1.5", "1.5@0");
    try expectReads(&h, "0", "0@5");
    try expectReads(&h, "0", "0@1.5");
    try expectReads(&h, "3/2", "#e1.5@0");
    try expectReads(&h, "0", "#e0@2");
    try expectReads(&h, "1.0+0.0i", "1@0.0");
    try expectReads(&h, "1.0+0.0i", "#i1@0");
    try expectReads(&h, "0.5403023058681398+0.8414709848078965i", "1@1");
    try expectReads(&h, "-0.4161468365471424+0.9092974268256817i", "1@2");
    try expectReads(&h, "1.0806046117362795+1.682941969615793i", "2@1");
    try expectReads(&h, "0.5403023058681398+0.8414709848078965i", "#i1@1");
    // 不正確な数は、`#e` では表せない。
    try expectReads(&h, null, "#e1@1");
    try expectReads(&h, null, "#e1.5@2");
    // 大きさと角の型は何でもよい。
    const z = (try parse(&h, "1/2@1/3", 10)).?.asCompnum().?;
    try testing.expectApproxEqAbs(0.5 * @cos(1.0 / 3.0), z.real.asFlonum().?, 1e-15);
    try testing.expectApproxEqAbs(0.5 * @sin(1.0 / 3.0), z.imag.asFlonum().?, 1e-15);
    // 無限大と NaN の大きさと角でも、読める(結果に NaN を含みうる)。
    try testing.expect((try parse(&h, "+inf.0@1", 10)) != null);
    try testing.expect((try parse(&h, "1@+inf.0", 10)) != null);
}

test "makeRectangular makes a real number of an exact zero imaginary part, and unifies the exactness of the parts" {
    var h: Heap = .init(testing.allocator, .{});
    defer h.deinit();
    const gpa = testing.allocator;
    // 虚部が正確な0なら、実部そのもの(型も保つ)。
    try testing.expectEqual(Value.fromFixnum(3), try makeRectangular(&h, gpa, .fromFixnum(3), .fromFixnum(0)));
    try testing.expectEqual(Value.fromFlonum(1.5), try makeRectangular(&h, gpa, .fromFlonum(1.5), .fromFixnum(0)));
    const half = (try parse(&h, "1/2", 10)).?;
    try testing.expectEqual(half, try makeRectangular(&h, gpa, half, .fromFixnum(0)));
    // 虚部が不正確な0なら、複素数のまま。
    const z = try makeRectangular(&h, gpa, .fromFixnum(3), .fromFlonum(0.0));
    try testing.expectEqual(value_mod.Kind.compnum, z.kind());
    try testing.expectEqual(Value.fromFlonum(3.0), z.asCompnum().?.real);
    try testing.expect(std.math.signbit(z.asCompnum().?.imag.asFlonum().?) == false);
    const n = try makeRectangular(&h, gpa, .fromFixnum(3), .fromFlonum(-0.0));
    try testing.expect(std.math.signbit(n.asCompnum().?.imag.asFlonum().?));
    // 実部だけが不正確なら虚部を、虚部だけが不正確なら実部を、不正確にする。
    const big = (try parse(&h, "123456789012345678901234567890", 10)).?;
    const mixed = try makeRectangular(&h, gpa, big, .fromFlonum(1.5));
    try testing.expectEqual(value_mod.Kind.flonum, mixed.asCompnum().?.real.kind());
    try testing.expectEqual(@as(f64, 1.2345678901234568e29), mixed.asCompnum().?.real.asFlonum().?);
    const other = try makeRectangular(&h, gpa, .fromFlonum(2.5), half);
    try testing.expectEqual(Value.fromFlonum(0.5), other.asCompnum().?.imag);
    // 両方が正確なら、正確なまま(型もそのまま)。
    const exact_pair = try makeRectangular(&h, gpa, half, big);
    try testing.expectEqual(half, exact_pair.asCompnum().?.real);
    try testing.expectEqual(big, exact_pair.asCompnum().?.imag);
    // 両方が不正確なら、そのまま。
    const inexact_pair = try makeRectangular(&h, gpa, .fromFlonum(1.0), .fromFlonum(2.0));
    try testing.expectEqual(Value.fromFlonum(1.0), inexact_pair.asCompnum().?.real);
    try testing.expectEqual(Value.fromFlonum(2.0), inexact_pair.asCompnum().?.imag);
}

test "a complex number is as large as its parts, and a part too large for the heap makes it no number" {
    var h: Heap = .init(testing.allocator, .{ .limit = 64 * 1024 });
    defer h.deinit();
    try expectReads(&h, null, "#e1e999999999+1i");
    try expectReads(&h, null, "1+#e1e999999999i");
    try expectReads(&h, null, "#e1e999999999@1");
    try expectReads(&h, null, "#e1+1e999999999i");
    try testing.expectEqual(0, h.external);
    try testing.expect(!h.external_enforced);
    // 不正確な部分は、どんなに大きくても、無限大になるだけで、ヒープを使わない。
    try expectReads(&h, "+inf.0+inf.0i", "1e999999999+1e999999999i");
    try expectReads(&h, "0.0+0.0i", "1e-999999999+1e-999999999i");
}

/// The decimal that stands at `place` in the number `text`, which is spelled the same way as
/// `expected` says it is.
fn expectSpelling(text: []const u8, place: enum { whole, real, imag, magnitude, angle }, expected: []const u8) !void {
    const literal = syntax.scan(text, 10).?;
    const part: syntax.Real = switch (place) {
        .whole => literal.shape.real,
        .real => literal.shape.rectangular.real.?,
        .imag => literal.shape.rectangular.imag,
        .magnitude => literal.shape.polar.magnitude,
        .angle => literal.shape.polar.angle,
    };
    try testing.expectEqualStrings(expected, decimalSpelling(part.decimal));
}

test "decimalSpelling gives the spelling of a decimal, from the pieces that scan hands over" {
    // 整数部が空、小数点だけ、指数部だけ、すべてあり、のそれぞれを、数の中の各位置で。
    for ([_][]const u8{ "1.", ".5", "1.5", "1e10", "1E10", "1e-3", "1e+3", "1.e2", ".5e1", "0.0", "123456.789e-12", "1.5e300" }) |spelling| {
        var buf: [64]u8 = undefined;
        try expectSpelling(try std.fmt.bufPrint(&buf, "{s}", .{spelling}), .whole, spelling);
        try expectSpelling(try std.fmt.bufPrint(&buf, "+{s}", .{spelling}), .whole, spelling);
        try expectSpelling(try std.fmt.bufPrint(&buf, "-{s}", .{spelling}), .whole, spelling);
        try expectSpelling(try std.fmt.bufPrint(&buf, "#e{s}", .{spelling}), .whole, spelling);
        try expectSpelling(try std.fmt.bufPrint(&buf, "#i-{s}", .{spelling}), .whole, spelling);
        try expectSpelling(try std.fmt.bufPrint(&buf, "{s}+1i", .{spelling}), .real, spelling);
        try expectSpelling(try std.fmt.bufPrint(&buf, "1+{s}i", .{spelling}), .imag, spelling);
        try expectSpelling(try std.fmt.bufPrint(&buf, "1-{s}i", .{spelling}), .imag, spelling);
        try expectSpelling(try std.fmt.bufPrint(&buf, "+{s}i", .{spelling}), .imag, spelling);
        try expectSpelling(try std.fmt.bufPrint(&buf, "{s}@1", .{spelling}), .magnitude, spelling);
        try expectSpelling(try std.fmt.bufPrint(&buf, "1@{s}", .{spelling}), .angle, spelling);
        try expectSpelling(try std.fmt.bufPrint(&buf, "1@-{s}", .{spelling}), .angle, spelling);
    }
}

test "parse says no to an exact number too large for the heap, before it allocates" {
    var h: Heap = .init(testing.allocator, .{ .limit = 64 * 1024 });
    defer h.deinit();
    try expectReads(&h, null, "#e1e999999999");
    try expectReads(&h, null, "#e1e99999999999999999999");
    try expectReads(&h, null, "#e1e-999999999");
    try expectReads(&h, null, "#e1.5e1000000");
    try expectReads(&h, null, "#e0.0001e-1000000");
    // 桁数が大きい整数も同じ。
    var digits: [100000]u8 = undefined;
    @memset(&digits, '9');
    try expectReads(&h, null, &digits);
    // 分数は、分子と分母の合計で見積もる。
    const big_numerator = try std.fmt.allocPrint(testing.allocator, "{s}/1", .{&digits});
    defer testing.allocator.free(big_numerator);
    try expectReads(&h, null, big_numerator);
    const big_denominator = try std.fmt.allocPrint(testing.allocator, "1/{s}", .{&digits});
    defer testing.allocator.free(big_denominator);
    try expectReads(&h, null, big_denominator);
    try testing.expectEqual(0, h.external);
    try testing.expectEqual(0, h.accounted);
    try testing.expect(!h.external_enforced);
    // 桁数が大きい `#e` の小数も、綴りを写す前に見積もって、null になる(整数と同じ)。
    const big_decimal = try std.fmt.allocPrint(testing.allocator, "#e{s}.5", .{digits[0..99_999]});
    defer testing.allocator.free(big_decimal);
    try expectReads(&h, null, big_decimal);
    try testing.expectEqual(0, h.external);
    // ヒープの見積りは先頭の0を数えない。0が大きいだけの綴りは、小さい数として読める。
    // (綴りの長さの上限には数える。上限は「parse says no to an exact spelling over the limits」が固定する)
    const zeros_text = try std.fmt.allocPrint(testing.allocator, "#e0.{s}1e{d}", .{ &zeros_90000, 90000 });
    defer testing.allocator.free(zeros_text);
    try expectReads(&h, "1/10", zeros_text);
    // 指数部が大きすぎても、整数があふれない。
    try expectReads(&h, null, "#e1.55e-99999999999999999999");
    try expectReads(&h, null, "#e-1.55e99999999999999999999");
    // 収まる大きさは読める。
    const expected = "1" ++ zeros(300);
    try expectReads(&h, expected, "#e1e300");
    try testing.expectEqual(0, h.external);
}

fn filled(len: usize, c: u8) ![]u8 {
    const s = try testing.allocator.alloc(u8, len);
    @memset(s, c);
    return s;
}

fn expectReadsFormatted(h: *Heap, expected: ?[]const u8, comptime fmt: []const u8, args: anytype) !void {
    const text = try std.fmt.allocPrint(testing.allocator, fmt, args);
    defer testing.allocator.free(text);
    try expectReads(h, expected, text);
}

test "parse says no to an exact spelling over the limits, wherever the heap has room" {
    // ヒープの上限は既定(十分に大きい)。断る理由は、綴りの長さと指数の上限だけである。
    var h: Heap = .init(testing.allocator, .{});
    defer h.deinit();
    const over = try filled(max_spelling_digits + 1, '7');
    defer testing.allocator.free(over);
    const at = over[1..];
    // 整数、分子、分母。基数と符号と正確さによらない(`#i` も内部で正確な数を作る)。
    try expectReadsFormatted(&h, null, "{s}", .{over});
    try expectReadsFormatted(&h, null, "-{s}", .{over});
    try expectReadsFormatted(&h, null, "#x{s}", .{over});
    try expectReadsFormatted(&h, null, "#b{s}", .{over});
    try expectReadsFormatted(&h, null, "#i{s}", .{over});
    try expectReadsFormatted(&h, null, "#e{s}", .{over});
    try expectReadsFormatted(&h, null, "{s}/3", .{over});
    try expectReadsFormatted(&h, null, "3/{s}", .{over});
    try expectReadsFormatted(&h, null, "#i{s}/3", .{over});
    try expectReadsFormatted(&h, null, "#i3/{s}", .{over});
    // 正確な小数の仮数は、整数部と小数部の長さの合計で見る。先頭の0も数える。
    try expectReadsFormatted(&h, null, "#e{s}.5", .{at});
    try expectReadsFormatted(&h, null, "#e1.{s}", .{at});
    try expectReadsFormatted(&h, null, "#e0.{s}", .{over});
    // 先頭の0も数える: 0 が上限の個数あって 1 が続く綴りは、整数部の 0 と合わせて上限を超える。
    const zeros_max = try filled(max_spelling_digits, '0');
    defer testing.allocator.free(zeros_max);
    try expectReadsFormatted(&h, null, "#e0.{s}1", .{zeros_max});
    try expectReadsFormatted(&h, null, "#e-0.{s}1", .{zeros_max});
    // 正確な小数の指数の絶対値。符号によらない。
    try expectReads(&h, null, "#e1e1000001");
    try expectReads(&h, null, "#e1e-1000001");
    try expectReads(&h, null, "#e-1.5e1000001");
    try expectReads(&h, null, "#e1.5e-1000001");
    try expectReads(&h, null, "#e1e99999999999999999999");
    // 複素数の各部と極形式の各部も、それぞれ見る。
    try expectReadsFormatted(&h, null, "{s}+1i", .{over});
    try expectReadsFormatted(&h, null, "1+{s}i", .{over});
    try expectReadsFormatted(&h, null, "+{s}i", .{over});
    try expectReadsFormatted(&h, null, "#i{s}/3+1i", .{over});
    try expectReadsFormatted(&h, null, "{s}@1", .{over});
    try expectReadsFormatted(&h, null, "1@{s}", .{over});
    try expectReads(&h, null, "#e1e1000001+1i");
    try expectReads(&h, null, "#e1+1e-1000001i");
    try expectReads(&h, null, "#e1e1000001@0");
    // 断ったあとに、数えたものを残さない。
    try testing.expectEqual(0, h.external);
    try testing.expectEqual(0, h.accounted);
}

test "the limits of a spelling are the values the design decided" {
    // 値を変えるのは設計の判断である(docs/design/numerics-and-unicode.md)。
    try testing.expectEqual(100_000, max_spelling_digits);
    try testing.expectEqual(1_000_000, max_spelling_exponent);
}

test "parse reads the exponent markers s, f, d and l as e, short and long" {
    var h: Heap = .init(testing.allocator, .{});
    defer h.deinit();
    for ([_][]const u8{ "s", "f", "d", "l", "S", "F", "D", "L" }) |m| {
        try expectReadsFormatted(&h, "100.0", "1{s}2", .{m});
        try expectReadsFormatted(&h, "0.0015", "1.5{s}-3", .{m});
        try expectReadsFormatted(&h, "-250.0", "-.25{s}+3", .{m});
        try expectReadsFormatted(&h, "+inf.0", "1{s}400", .{m});
        try expectReadsFormatted(&h, "100.0", "#i1{s}2", .{m});
        try expectReadsFormatted(&h, "1000", "#e1{s}3", .{m});
        try expectReadsFormatted(&h, "100.0+15.0i", "1{s}2+1.5{s}1i", .{ m, m });
    }
    // 256 バイトを超える綴りは、スタックでなく gpa に写して読む。
    const long = try filled(300, '0');
    defer testing.allocator.free(long);
    try expectReadsFormatted(&h, "1.0", "1.{s}d0", .{long});
    try expectReadsFormatted(&h, "1.0", "1.{s}D0", .{long});
}

test "parse does not limit what costs little: an inexact decimal and an exact zero" {
    // 不正確な小数は、桁数と指数が線形に読まれるので、上限の外でも読む(`#i` の小数も)。
    // 正確な 0 は、どんな桁数と指数でも 0 である。
    var h: Heap = .init(testing.allocator, .{});
    defer h.deinit();
    const over = try filled(max_spelling_digits + 1, '7');
    defer testing.allocator.free(over);
    const zeros_over = try filled(max_spelling_digits + 1, '0');
    defer testing.allocator.free(zeros_over);
    try expectReads(&h, "+inf.0", "1e1000000");
    try expectReads(&h, "0.0", "1e-1000000");
    try expectReads(&h, "+inf.0", "1e1000001");
    try expectReads(&h, "0.0", "1e-1000001");
    try expectReads(&h, "+inf.0", "#i1e1000001");
    try expectReads(&h, "0.0", "#i1.5e-1000001");
    try expectReads(&h, "+inf.0", "1e999999999");
    try expectReads(&h, "0.0", "1e-999999999");
    try expectReads(&h, "+inf.0", "1e99999999999999999999");
    try expectReadsFormatted(&h, "+inf.0", "{s}.5", .{over});
    try expectReadsFormatted(&h, "+inf.0", "#i{s}.5", .{over});
    try expectReadsFormatted(&h, "0.0", "#i0.{s}", .{zeros_over});
    // 複素数と極形式の部分でも同じである。
    try expectReads(&h, "+inf.0+0.0i", "1e999999999+1e-999999999i");
    try expectReadsFormatted(&h, "+inf.0+inf.0i", "{s}.5+{s}.5i", .{ over, over });
    // 正確な 0 は、上限を超える桁数と指数でも 0 である。
    try expectReads(&h, "0", "#e0e1000001");
    try expectReads(&h, "0", "#e0e-1000001");
    try expectReads(&h, "0", "#e0e999999999");
    try expectReadsFormatted(&h, "0", "#e0.{s}", .{zeros_over});
    try expectReadsFormatted(&h, "0", "#e0.{s}e1000001", .{zeros_over});
    try expectReads(&h, "0", "#e0e999999999+0e999999999i");
    try testing.expectEqual(0, h.external);
}

test "parse reads an exact spelling just within the limits" {
    try tier.slow();
    // 費用は桁数と指数の2乗に比例する。上限ちょうどの正確な数を、縮小せずに読む。
    var h: Heap = .init(testing.allocator, .{});
    defer h.deinit();
    const nines = try filled(max_spelling_digits, '9');
    defer testing.allocator.free(nines);
    {
        const v = (try parse(&h, nines, 10)).?;
        try testing.expectEqual(value_mod.Kind.bignum, v.kind());
    }
    {
        const text = try std.fmt.allocPrint(testing.allocator, "{s}/7", .{nines});
        defer testing.allocator.free(text);
        try testing.expect((try parse(&h, text, 10)) != null);
    }
    {
        const text = try std.fmt.allocPrint(testing.allocator, "3/{s}", .{nines});
        defer testing.allocator.free(text);
        try testing.expect((try parse(&h, text, 10)) != null);
    }
    {
        const text = try std.fmt.allocPrint(testing.allocator, "#e{s}", .{nines});
        defer testing.allocator.free(text);
        try testing.expect((try parse(&h, text, 10)) != null);
    }
    {
        // 正確な小数の仮数が上限ちょうど(整数部の 0 と、小数部の 99,999 桁)。
        const lead = try filled(max_spelling_digits - 2, '0');
        defer testing.allocator.free(lead);
        const text = try std.fmt.allocPrint(testing.allocator, "#e0.{s}1", .{lead});
        defer testing.allocator.free(text);
        try testing.expect((try parse(&h, text, 10)) != null);
    }
    {
        // 分子と分母がともに上限ちょうど(約分の gcd が最も重い形に近い)。
        const denominator = try filled(max_spelling_digits, '7');
        defer testing.allocator.free(denominator);
        denominator[max_spelling_digits - 1] = '3';
        const text = try std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ nines, denominator });
        defer testing.allocator.free(text);
        try testing.expect((try parse(&h, text, 10)) != null);
    }
    {
        // 仮数が上限ちょうどで、指数も上限ちょうど。
        const fraction = try filled(max_spelling_digits - 2, '1');
        defer testing.allocator.free(fraction);
        const text = try std.fmt.allocPrint(testing.allocator, "#e1.{s}e-1000000", .{fraction});
        defer testing.allocator.free(text);
        try testing.expect((try parse(&h, text, 10)) != null);
    }
    try testing.expect((try parse(&h, "#e1e1000000", 10)) != null);
    try testing.expect((try parse(&h, "#e1e-1000000", 10)) != null);
}

test "parse compares the estimate with the room that is left, not with the limit" {
    var h: Heap = .init(testing.allocator, .{ .limit = 64 * 1024 });
    defer h.deinit();
    try expectReads(&h, "1" ++ zeros(3000), "#e1e3000");
    var filler: [55000]u8 = undefined;
    @memset(&filler, 'x');
    _ = try h.createString(&filler);
    try expectReads(&h, null, "#e1e3000");
    try expectReads(&h, "12", "12");
}

/// Reads a number of each kind at `digits` digits, at limits from none up to well past what
/// the estimate asks, and checks that no limit makes the reading fail: a limit lets the number
/// through or it does not, and from the least limit that lets it through every limit does.
fn expectEstimateHolds(digits: usize, steps: usize) !void {
    var prng: std.Random.DefaultPrng = .init(0x4e5);
    const random = prng.random();
    const a = try testing.allocator.alloc(u8, digits);
    defer testing.allocator.free(a);
    const b = try testing.allocator.alloc(u8, digits);
    defer testing.allocator.free(b);
    for (a) |*c| c.* = '1' + random.uintLessThan(u8, 9);
    for (b) |*c| c.* = '1' + random.uintLessThan(u8, 9);
    const texts = [_][]const u8{
        try std.fmt.allocPrint(testing.allocator, "{s}", .{a}),
        try std.fmt.allocPrint(testing.allocator, "#i{s}", .{a}),
        try std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ a, b }),
        try std.fmt.allocPrint(testing.allocator, "#i{s}/{s}", .{ a, b }),
        try std.fmt.allocPrint(testing.allocator, "#e1e{d}", .{digits * 4}),
        try std.fmt.allocPrint(testing.allocator, "#e1e-{d}", .{digits * 4}),
        try std.fmt.allocPrint(testing.allocator, "#e{s}.{s}e-{d}", .{ a, b, digits }),
        try std.fmt.allocPrint(testing.allocator, "{s}/{s}+{s}/{s}i", .{ a, b, b, a }),
        try std.fmt.allocPrint(testing.allocator, "#i{s}+{s}i", .{ a, b }),
    };
    defer for (texts) |t| testing.allocator.free(t);
    for (texts) |text| {
        var read = false;
        var limit: usize = 0;
        const top = digits * 70 + 8192;
        while (limit <= top) : (limit += top / steps + 1) {
            var h: Heap = .init(testing.allocator, .{ .limit = limit });
            defer h.deinit();
            const result = try parse(&h, text, 10);
            if (result != null) read = true else try testing.expect(!read);
        }
        try testing.expect(read);
    }
}

test "once the estimate lets a number through, the work of reading it does not run out" {
    try expectEstimateHolds(3, 30);
    try expectEstimateHolds(150, 30);
    try expectEstimateHolds(500, 12);
}

test "once the estimate lets a number through, the work of reading it does not run out at a large scale" {
    try tier.slow();
    try expectEstimateHolds(2000, 30);
}

test "parse leaves the count of work as it found it, and gives OutOfMemory when the backing refuses" {
    var h: Heap = .init(testing.allocator, .{ .limit = 1 << 20 });
    defer h.deinit();
    var filler: [100]u8 = undefined;
    @memset(&filler, '7');
    _ = try h.createString(&filler);
    const before = h.held();
    const v = (try parse(&h, "123456789012345678901234567890", 10)).?;
    try testing.expectEqual(value_mod.Kind.bignum, v.kind());
    try testing.expect(h.held() > before);
    try testing.expectEqual(0, h.external);
    try testing.expect(!h.external_enforced);
    // 下の割り当て器が断れば、ヒープの上限の誤りでなく OutOfMemory である。
    var failing: std.testing.FailingAllocator = .init(testing.allocator, .{ .fail_index = 0 });
    var h2: Heap = .init(failing.allocator(), .{});
    defer h2.deinit();
    try testing.expectError(error.OutOfMemory, parse(&h2, "123456789012345678901234567890", 10));
    try testing.expectEqual(0, h2.external);
    try testing.expect(!h2.external_enforced);
}

test "parse gives a heap limit error when the work area is refused, and gives the count back" {
    var h: Heap = .init(testing.allocator, .{ .limit = 1 << 20 });
    defer h.deinit();
    // 外側の作業が上限のすぐ手前まで数えているところへ、読む。作業領域の確保が断られる。
    h.external = h.options.limit - 8;
    try testing.expectError(error.HeapLimit, parse(&h, "123456789012345678901234567890", 10));
    try testing.expect(h.external_refused);
    try testing.expectEqual(h.options.limit - 8, h.external);
    try testing.expect(!h.external_enforced);
    // 作業領域は通り、結果のセルが断られる場合も、同じ誤りで、数えた分は戻る。
    h.external = h.options.limit - 64;
    try testing.expectError(error.HeapLimit, parse(&h, "123456789012345678901234567890", 10));
    try testing.expectEqual(h.options.limit - 64, h.external);
    try testing.expectEqual(0, h.accounted);
    // 次の読み取りは、断りの印を下ろしてから始める。
    h.external = 0;
    try testing.expect((try parse(&h, "12", 10)) != null);
    try testing.expect(!h.external_refused);
}

test "parse with any limit gives a number, no, or a heap limit error, and leaves nothing counted" {
    const texts = [_][]const u8{ "123456789012345678901234567890", "12345678901234567890/7", "#e1.5e300", "#e1e-300", "#i1/3", "1.5", "#xFFFFFFFFFFFFFFFFFFFFFFFF" };
    var limit: usize = 0;
    while (limit <= 6000) : (limit += 53) {
        var h: Heap = .init(testing.allocator, .{ .limit = limit });
        defer h.deinit();
        for (texts) |text| {
            if (parse(&h, text, 10)) |_| {} else |e| try testing.expectEqual(error.HeapLimit, e);
            try testing.expectEqual(0, h.external);
            try testing.expect(!h.external_enforced);
        }
    }
}

test "makeRatio puts the sign on the numerator, reduces, and makes an integer of a unit denominator" {
    var h: Heap = .init(testing.allocator, .{});
    defer h.deinit();
    for ([_]struct { n: i64, d: i64, expected: []const u8 }{
        .{ .n = 1, .d = 2, .expected = "1/2" },
        .{ .n = 1, .d = -2, .expected = "-1/2" },
        .{ .n = -1, .d = -2, .expected = "1/2" },
        .{ .n = -6, .d = 4, .expected = "-3/2" },
        .{ .n = 6, .d = -4, .expected = "-3/2" },
        .{ .n = 0, .d = -5, .expected = "0" },
        .{ .n = 4, .d = -2, .expected = "-2" },
        .{ .n = 7, .d = 1, .expected = "7" },
        .{ .n = std.math.minInt(i64), .d = -1, .expected = "9223372036854775808" },
    }) |case| {
        var n = try Managed.initSet(testing.allocator, case.n);
        defer n.deinit();
        var d = try Managed.initSet(testing.allocator, case.d);
        defer d.deinit();
        const v = try makeRatio(&h, testing.allocator, n.toConst(), d.toConst());
        var aw: std.Io.Writer.Allocating = .init(testing.allocator);
        defer aw.deinit();
        try write(&aw.writer, testing.allocator, v, 10);
        try testing.expectEqualStrings(case.expected, aw.written());
        // 分母は、正の整数の bignum か fixnum で、1 ではない。
        if (v.asRatnum()) |r| {
            try testing.expect(r.denominator.kind() == .fixnum or r.denominator.kind() == .bignum);
            try testing.expect(r.denominator.asFixnum() != 1);
        }
    }
}

test "write writes a fixnum or a bignum in the radix, and a ratnum as two integers" {
    var h: Heap = .init(testing.allocator, .{});
    defer h.deinit();
    for ([_]struct { text: []const u8, radix: u8, expected: []const u8 }{
        .{ .text = "-255", .radix = 10, .expected = "-255" },
        .{ .text = "-255", .radix = 16, .expected = "-ff" },
        .{ .text = "-255", .radix = 8, .expected = "-377" },
        .{ .text = "-255", .radix = 2, .expected = "-11111111" },
        .{ .text = "18446744073709551616", .radix = 16, .expected = "10000000000000000" },
        .{ .text = "18446744073709551616", .radix = 8, .expected = "2000000000000000000000" },
        .{ .text = "-18446744073709551616", .radix = 2, .expected = "-1" ++ zeros(64) },
        .{ .text = "1/2", .radix = 2, .expected = "1/10" },
        .{ .text = "-255/16", .radix = 16, .expected = "-ff/10" },
        .{ .text = "18446744073709551617/3", .radix = 16, .expected = "10000000000000001/3" },
    }) |case| {
        const got = (try readWrite(&h, case.text, 10, case.radix)).?;
        defer testing.allocator.free(got);
        try testing.expectEqualStrings(case.expected, got);
    }
}

test "write writes a flonum in radix 10 with a point, and in the other radixes as an exact ratio after #i" {
    var h: Heap = .init(testing.allocator, .{});
    defer h.deinit();
    for ([_]struct { text: []const u8, radix: u8, expected: []const u8 }{
        .{ .text = "0.5", .radix = 10, .expected = "0.5" },
        .{ .text = "0.5", .radix = 2, .expected = "#i1/10" },
        .{ .text = "-0.5", .radix = 2, .expected = "#i-1/10" },
        .{ .text = "0.5", .radix = 8, .expected = "#i1/2" },
        .{ .text = "0.5", .radix = 16, .expected = "#i1/2" },
        .{ .text = "4.0", .radix = 2, .expected = "#i100" },
        .{ .text = "255.0", .radix = 16, .expected = "#iff" },
        .{ .text = "0.0", .radix = 8, .expected = "#i0" },
        .{ .text = "-0.0", .radix = 16, .expected = "#i-0" },
        .{ .text = "0.125", .radix = 2, .expected = "#i1/1000" },
        .{ .text = "+inf.0", .radix = 2, .expected = "+inf.0" },
        .{ .text = "-inf.0", .radix = 16, .expected = "-inf.0" },
        .{ .text = "+nan.0", .radix = 8, .expected = "+nan.0" },
    }) |case| {
        const got = (try readWrite(&h, case.text, 10, case.radix)).?;
        defer testing.allocator.free(got);
        try testing.expectEqualStrings(case.expected, got);
    }
}

/// Reads `text` in `radix`, writes the number in `radix`, reads that again in `radix`, and
/// checks that the two numbers write the same in radix 10.
fn expectRoundTrip(h: *Heap, text: []const u8, radix: u8) !void {
    const first = (try parse(h, text, 10)).?;
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try write(&aw.writer, testing.allocator, first, radix);
    const second = (try parse(h, aw.written(), radix)) orelse return error.NotReadBack;
    var a: std.Io.Writer.Allocating = .init(testing.allocator);
    defer a.deinit();
    var b: std.Io.Writer.Allocating = .init(testing.allocator);
    defer b.deinit();
    try write(&a.writer, testing.allocator, first, 10);
    try write(&b.writer, testing.allocator, second, 10);
    try testing.expectEqualStrings(a.written(), b.written());
}

test "write then parse gives the same number in every radix, for the boundary values" {
    var h: Heap = .init(testing.allocator, .{});
    defer h.deinit();
    for ([_][]const u8{ "0", "1", "-1", "255", "9223372036854775807", "-9223372036854775808", "9223372036854775808", "123456789012345678901234567890", "1/3", "-22/7", "123456789012345678901234567890/7", "0.1", "-0.1", "0.5", "100.0", "1e21", "1e-7", "-0.0", "5e-324", "1.7976931348623157e308", "2.2250738585072014e-308", "4.35", "+inf.0", "-inf.0", "#e1.5", "#i1/3", "1+2i", "1-2i", "+2i", "-2i", "+i", "-i", "1+i", "1-i", "1/2-3/4i", "-1/2+3/4i", "123456789012345678901234567890+98765432109876543210987654321i", "1.5+2.5i", "0.5-0.25i", "1+2.5i", "1.5+2i", "+0.5i", "1+0.0i", "1-0.0i", "-0.0+0.0i", "0.1+0.2i", "1e21+1e-7i", "5e-324-1.7976931348623157e308i", "1+inf.0i", "-inf.0+inf.0i", "+nan.0+1.5i", "1.5-nan.0i", "1@1", "2@-1.5", "#i1+2i", "#e1.5-2.5i" }) |text| {
        for ([_]u8{ 2, 8, 10, 16 }) |radix| {
            // 無限大と NaN は、基数によらず同じ綴りで書かれ、読み戻せる。
            try expectRoundTrip(&h, text, radix);
        }
    }
}

test "write then parse gives the same number for random integers, ratios and flonums" {
    var h: Heap = .init(testing.allocator, .{});
    defer h.deinit();
    var prng: std.Random.DefaultPrng = .init(0x4e3);
    const random = prng.random();
    var buf: [128]u8 = undefined;
    for (0..2000) |_| {
        const radixes = [_]u8{ 2, 8, 10, 16 };
        const radix = radixes[random.uintLessThan(usize, 4)];
        const n = random.int(i64);
        const d = random.intRangeAtMost(i64, 1, std.math.maxInt(i64));
        try expectRoundTrip(&h, try std.fmt.bufPrint(&buf, "{d}", .{n}), radix);
        try expectRoundTrip(&h, try std.fmt.bufPrint(&buf, "{d}/{d}", .{ n, d }), radix);
        const x: f64 = @bitCast(random.int(u64));
        if (!std.math.isFinite(x)) continue;
        var aw: std.Io.Writer.Allocating = .init(testing.allocator);
        defer aw.deinit();
        try flonum.write(&aw.writer, x);
        try expectRoundTrip(&h, aw.written(), radix);
        // 実部が分数、虚部が flonum の複素数(部分の正確性が混ざる)。
        const sign: []const u8 = if (aw.written()[0] == '-') "" else "+";
        const complex = try std.fmt.bufPrint(&buf, "{d}/{d}{s}{s}i", .{ n, d, sign, aw.written() });
        try expectRoundTrip(&h, complex, radix);
    }
}

test "write then parse gives the same number for random integers, ratios and flonums at a large scale" {
    try tier.slow();
    var h: Heap = .init(testing.allocator, .{});
    defer h.deinit();
    var prng: std.Random.DefaultPrng = .init(0x4e4);
    const random = prng.random();
    var buf: [128]u8 = undefined;
    for (0..20_000) |i| {
        // Why: `testing.allocator` は確保ごとに別のメモリ領域(ページ)を割り当てる。ヒープに
        // 残る数のセルが、プロセスの領域の数の上限(`vm.max_map_count`)に達すると、
        // `munmap` が失敗して `unreachable` に当たり、約7万回目の反復で落ちる(実装の
        // 不具合ではない)。ヒープを定期的に作り直して、残るセルの数を抑える。
        if (i % 5000 == 0) {
            h.deinit();
            h = .init(testing.allocator, .{});
        }
        const radixes = [_]u8{ 2, 8, 10, 16 };
        const radix = radixes[random.uintLessThan(usize, 4)];
        const n = random.int(i64);
        const d = random.intRangeAtMost(i64, 1, std.math.maxInt(i64));
        try expectRoundTrip(&h, try std.fmt.bufPrint(&buf, "{d}/{d}", .{ n, d }), radix);
        const x: f64 = @bitCast(random.int(u64));
        if (!std.math.isFinite(x)) continue;
        var aw: std.Io.Writer.Allocating = .init(testing.allocator);
        defer aw.deinit();
        try flonum.write(&aw.writer, x);
        try expectRoundTrip(&h, aw.written(), radix);
    }
}
