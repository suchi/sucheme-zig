//! Looks up Unicode character properties and case mappings in the generated tables
//! (docs/plans/0018-phase4-numeric-tower-unicode.md, slice 4u2).
//!
//! 表は `tables.zig` にあり、`tools/unicode-gen` が UCD のファイルから作る。ここは引く側で、
//! 手で書く。符号位置は Unicode のスカラ値を想定するが、範囲外の値(0x10FFFF より大きい
//! 値)は、属性を持たず写像されない文字として扱う。サロゲートの範囲は表の中にあり、
//! 属性を持たず写像されない。

const std = @import("std");
const tables = @import("tables.zig");

/// The Unicode version the tables were generated from, e.g. "18.0.0".
pub const unicode_version = tables.unicode_version;

/// The properties R7RS 6.6 asks the character predicates to follow.
pub const Property = enum {
    /// Alphabetic。`char-alphabetic?`
    alphabetic,
    /// Numeric_Type=Decimal(一般カテゴリ Nd)。`char-numeric?`
    numeric,
    /// White_Space。`char-whitespace?`
    white_space,
    /// Uppercase。`char-upper-case?`
    uppercase,
    /// Lowercase。`char-lower-case?`
    lowercase,
};

const max_code_point: u21 = 0x10FFFF;

const block_size = 1 << tables.block_shift;

/// Reads the value for `c` out of a two-stage table. Zero for a value above U+10FFFF.
fn lookup(comptime T: type, stage1: []const u16, stage2: []const T, c: u21) T {
    if (c > max_code_point) return 0;
    const block: usize = stage1[c >> tables.block_shift];
    return stage2[block * block_size + (c & (block_size - 1))];
}

fn flagBit(p: Property) u16 {
    return switch (p) {
        .alphabetic => tables.flag_alphabetic,
        .numeric => tables.flag_numeric,
        .white_space => tables.flag_white_space,
        .uppercase => tables.flag_uppercase,
        .lowercase => tables.flag_lowercase,
    };
}

/// Whether `c` has the property `p`.
pub fn has(c: u21, p: Property) bool {
    return lookup(u16, &tables.flags_stage1, &tables.flags_stage2, c) & flagBit(p) != 0;
}

/// 表の値は「写像先 - 元の符号位置」の差である。
fn shifted(c: u21, delta: i32) u21 {
    return @intCast(@as(i32, c) + delta);
}

/// The simple uppercase mapping of `c`, or `c` itself if it has none.
pub fn simpleUpcase(c: u21) u21 {
    return shifted(c, lookup(i32, &tables.upper_stage1, &tables.upper_stage2, c));
}

/// The simple lowercase mapping of `c`, or `c` itself if it has none.
pub fn simpleDowncase(c: u21) u21 {
    return shifted(c, lookup(i32, &tables.lower_stage1, &tables.lower_stage2, c));
}

/// The simple case folding of `c`, or `c` itself if it has none.
pub fn simpleFoldcase(c: u21) u21 {
    return shifted(c, lookup(i32, &tables.fold_stage1, &tables.fold_stage2, c));
}

/// Binary search over a table ordered by `cp`.
fn findFull(table: []const tables.FullMapping, c: u21) ?tables.FullMapping {
    var lo: usize = 0;
    var hi: usize = table.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (table[mid].cp == c) return table[mid];
        if (table[mid].cp < c) lo = mid + 1 else hi = mid;
    }
    return null;
}

fn full(table: []const tables.FullMapping, simple: u21, c: u21, out: *[3]u21) u2 {
    if (findFull(table, c)) |m| {
        out.* = m.out;
        return @intCast(m.len);
    }
    out[0] = simple;
    return 1;
}

/// The full uppercase mapping of `c` (SpecialCasing.txt, unconditional rows).
///
/// 結果は1から3文字で、`out` の先頭から書き、書いた数を返す。残りの要素は書き換えない場合がある。
/// 完全写像を持たない文字は、単純写像の1文字を返す。
pub fn fullUpcase(c: u21, out: *[3]u21) u2 {
    return full(&tables.full_upper, simpleUpcase(c), c, out);
}

/// The full lowercase mapping of `c`. See `fullUpcase`.
pub fn fullDowncase(c: u21, out: *[3]u21) u2 {
    return full(&tables.full_lower, simpleDowncase(c), c, out);
}

/// The full case folding of `c` (CaseFolding.txt, status C, S and F). See `fullUpcase`.
pub fn fullFoldcase(c: u21, out: *[3]u21) u2 {
    return full(&tables.full_fold, simpleFoldcase(c), c, out);
}

/// The value 0 to 9 of a decimal digit, or null (`digit-value`, R7RS 6.6).
pub fn digitValue(c: u21) ?u4 {
    // 先頭が c 以下の最後の並びを探す。並びは10個ずつで、重ならず昇順である。
    var lo: usize = 0;
    var hi: usize = tables.digit_starts.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (tables.digit_starts[mid] <= c) lo = mid + 1 else hi = mid;
    }
    if (lo == 0) return null;
    const start = tables.digit_starts[lo - 1];
    if (c - start >= 10) return null;
    return @intCast(c - start);
}

// 以下のテストは、定義から選んだ既知の符号位置の答えを固定する。全符号位置が生成器の入力と
// 一致することは、tools/unicode-gen/full_range.zig が見る。

fn expectHas(c: u21, want: []const Property) !void {
    errdefer std.debug.print("properties of U+{X:0>4}\n", .{c});
    for (std.enums.values(Property)) |p| {
        const expected = std.mem.indexOfScalar(Property, want, p) != null;
        try std.testing.expectEqual(expected, has(c, p));
    }
}

test "has: ASCII letters, digits and white space" {
    try expectHas('A', &.{ .alphabetic, .uppercase });
    try expectHas('a', &.{ .alphabetic, .lowercase });
    try expectHas('0', &.{.numeric});
    try expectHas('!', &.{});
    try expectHas(' ', &.{.white_space});
    try expectHas('\t', &.{.white_space});
    try expectHas('\n', &.{.white_space});
    try expectHas(0x0D, &.{.white_space});
    try expectHas(0x08, &.{});
    try expectHas(0x0E, &.{});
}

test "has: non-ASCII characters" {
    // R7RS 6.6 の例。ギリシャ文字のアルファは Alphabetic である。
    try expectHas(0x03B1, &.{ .alphabetic, .lowercase });
    try expectHas(0x0391, &.{ .alphabetic, .uppercase });
    // Lt は大文字でも小文字でもない。
    try expectHas(0x01C5, &.{.alphabetic});
    // Other_Lowercase と Other_Uppercase。
    try expectHas(0x00AA, &.{ .alphabetic, .lowercase });
    try expectHas(0x2160, &.{ .alphabetic, .uppercase });
    // Numeric は十進数字(Nd)だけである。
    try expectHas(0x0660, &.{.numeric});
    try expectHas(0xFF10, &.{.numeric});
    try expectHas(0x00B2, &.{});
    try expectHas(0x00BD, &.{});
    // White_Space の端と外。U+180E は Unicode 6.3 で外れた。
    try expectHas(0x0085, &.{.white_space});
    try expectHas(0x00A0, &.{.white_space});
    try expectHas(0x2028, &.{.white_space});
    try expectHas(0x3000, &.{.white_space});
    try expectHas(0x180E, &.{});
    try expectHas(0x200B, &.{});
}

test "has: the ends of the range and the surrogates have no property" {
    try expectHas(0, &.{});
    try expectHas(0xD800, &.{});
    try expectHas(0xDFFF, &.{});
    try expectHas(0x10FFFF, &.{});
    try expectHas(0x110000, &.{});
    try expectHas(0x1FFFFF, &.{});
}

test "simple mappings" {
    try std.testing.expectEqual(@as(u21, 'A'), simpleUpcase('a'));
    try std.testing.expectEqual(@as(u21, 'A'), simpleUpcase('A'));
    try std.testing.expectEqual(@as(u21, 'a'), simpleDowncase('A'));
    try std.testing.expectEqual(@as(u21, 'a'), simpleFoldcase('A'));
    try std.testing.expectEqual(@as(u21, '0'), simpleUpcase('0'));
    // ß は単純な大文字を持たない。
    try std.testing.expectEqual(@as(u21, 0x00DF), simpleUpcase(0x00DF));
    // İ の単純な小文字は i。単純な畳み込みは無い。
    try std.testing.expectEqual(@as(u21, 'i'), simpleDowncase(0x0130));
    try std.testing.expectEqual(@as(u21, 0x0130), simpleFoldcase(0x0130));
    // 語末のシグマは、大文字と畳み込みでシグマに戻る。
    try std.testing.expectEqual(@as(u21, 0x03A3), simpleUpcase(0x03C2));
    try std.testing.expectEqual(@as(u21, 0x03C3), simpleFoldcase(0x03C2));
    // Lt の二重字。
    try std.testing.expectEqual(@as(u21, 0x01C4), simpleUpcase(0x01C5));
    try std.testing.expectEqual(@as(u21, 0x01C6), simpleDowncase(0x01C5));
    // 負の差と、区画をまたぐ値。
    try std.testing.expectEqual(@as(u21, 0x00DF), simpleFoldcase(0x1E9E));
    try std.testing.expectEqual(@as(u21, 0x2170), simpleDowncase(0x2160));
    // 範囲外は写像されない。
    try std.testing.expectEqual(@as(u21, 0x10FFFF), simpleUpcase(0x10FFFF));
    try std.testing.expectEqual(@as(u21, 0x110000), simpleDowncase(0x110000));
    try std.testing.expectEqual(@as(u21, 0x1FFFFF), simpleFoldcase(0x1FFFFF));
}

fn expectFull(comptime f: anytype, c: u21, want: []const u21) !void {
    errdefer std.debug.print("full mapping of U+{X:0>4}\n", .{c});
    var out: [3]u21 = @splat(0);
    const n = f(c, &out);
    try std.testing.expectEqualSlices(u21, want, out[0..n]);
}

test "full mappings" {
    try expectFull(fullUpcase, 0x00DF, &.{ 'S', 'S' });
    try expectFull(fullUpcase, 0x0149, &.{ 0x02BC, 'N' });
    try expectFull(fullUpcase, 0x0390, &.{ 0x0399, 0x0308, 0x0301 });
    try expectFull(fullUpcase, 0xFB00, &.{ 'F', 'F' });
    // 完全写像の表の最後の行(二分探索の端)。
    try expectFull(fullUpcase, 0x1DF95, &.{ 'S', 'S' });
    // 完全写像を持たない文字は、単純写像の1文字になる。
    try expectFull(fullUpcase, 'a', &.{'A'});
    try expectFull(fullUpcase, '1', &.{'1'});
    try expectFull(fullUpcase, 0x03C2, &.{0x03A3});

    try expectFull(fullDowncase, 0x0130, &.{ 'i', 0x0307 });
    try expectFull(fullDowncase, 'A', &.{'a'});
    // 語末のシグマの規則(条件つき)は表に無い。
    try expectFull(fullDowncase, 0x03A3, &.{0x03C3});

    try expectFull(fullFoldcase, 0x00DF, &.{ 's', 's' });
    try expectFull(fullFoldcase, 0x1E9E, &.{ 's', 's' });
    try expectFull(fullFoldcase, 0x0130, &.{ 'i', 0x0307 });
    try expectFull(fullFoldcase, 0xFB00, &.{ 'f', 'f' });
    // 完全写像の表の最後の行(二分探索の端)。
    try expectFull(fullFoldcase, 0x1DF95, &.{ 's', 's' });
    try expectFull(fullFoldcase, 'A', &.{'a'});
    try expectFull(fullFoldcase, 0x03C2, &.{0x03C3});
    try expectFull(fullFoldcase, 0x10FFFF, &.{0x10FFFF});
}

test "digitValue" {
    try std.testing.expectEqual(@as(?u4, 0), digitValue('0'));
    try std.testing.expectEqual(@as(?u4, 9), digitValue('9'));
    try std.testing.expectEqual(@as(?u4, null), digitValue('/'));
    try std.testing.expectEqual(@as(?u4, null), digitValue(':'));
    try std.testing.expectEqual(@as(?u4, 0), digitValue(0x0660));
    try std.testing.expectEqual(@as(?u4, 7), digitValue(0x0667));
    try std.testing.expectEqual(@as(?u4, 9), digitValue(0x0669));
    try std.testing.expectEqual(@as(?u4, null), digitValue(0x066A));
    try std.testing.expectEqual(@as(?u4, 0), digitValue(0xFF10));
    try std.testing.expectEqual(@as(?u4, 9), digitValue(0xFF19));
    try std.testing.expectEqual(@as(?u4, 0), digitValue(0x1D7CE));
    try std.testing.expectEqual(@as(?u4, 9), digitValue(0x1D7FF));
    // 並びの表の最後の2つ。二分探索の端である。
    try std.testing.expectEqual(@as(?u4, 0), digitValue(0x1E950));
    try std.testing.expectEqual(@as(?u4, 9), digitValue(0x1E959));
    try std.testing.expectEqual(@as(?u4, null), digitValue(0x1E95A));
    try std.testing.expectEqual(@as(?u4, 0), digitValue(0x1FBF0));
    try std.testing.expectEqual(@as(?u4, 9), digitValue(0x1FBF9));
    try std.testing.expectEqual(@as(?u4, null), digitValue(0x1FBFA));
    // Nd でない数。
    try std.testing.expectEqual(@as(?u4, null), digitValue(0x00B2));
    try std.testing.expectEqual(@as(?u4, null), digitValue(0x2160));
    try std.testing.expectEqual(@as(?u4, null), digitValue('A'));
    try std.testing.expectEqual(@as(?u4, null), digitValue(0));
    try std.testing.expectEqual(@as(?u4, null), digitValue(0x10FFFF));
    try std.testing.expectEqual(@as(?u4, null), digitValue(0x1FFFFF));
}

test "the tables were generated from the expected version" {
    try std.testing.expectEqualStrings("18.0.0", unicode_version);
}

test {
    std.testing.refAllDecls(@This());
}
