//! Parses the Unicode Character Database files into per-code-point arrays.
//!
//! 入力は UnicodeData.txt、DerivedCoreProperties.txt、PropList.txt、SpecialCasing.txt、
//! CaseFolding.txt の5つである。ここは文字列を受け取って配列に直すだけで、ファイルも
//! 出力も扱わない。入力は外部から取り込んだデータなので、形が想定と違えば黙って
//! 読み飛ばさず、誤りで止める。

const std = @import("std");

pub const code_point_count = 0x110000;

/// The bits of `Data.flags`, one per property R7RS 6.6 asks for.
pub const flag = struct {
    pub const alphabetic: u16 = 1 << 0;
    pub const numeric: u16 = 1 << 1;
    pub const white_space: u16 = 1 << 2;
    pub const uppercase: u16 = 1 << 3;
    pub const lowercase: u16 = 1 << 4;
    /// R7RS 7.1.1 で、ASCII でない文字が識別子の最初の文字になれる。ASCII では常に0。
    pub const identifier_initial: u16 = 1 << 5;
    /// R7RS 7.1.1 で、ASCII でない文字が識別子の2文字目以降になれる。ASCII では常に0。
    pub const identifier_subsequent: u16 = 1 << 6;
};

/// A code point whose full mapping is more than one code point.
pub const FullMapping = struct {
    cp: u21,
    len: u8,
    out: [3]u21,
};

pub const Error = error{
    MalformedLine,
    MalformedCodePoint,
    MissingVersion,
    VersionMismatch,
    PropertyNotFound,
    NonStandardDigitRun,
    UnpairedRange,
    UnknownCategory,
    UnknownCaseFoldingStatus,
    BadMappingLength,
    DuplicateMapping,
    SpecialCasingDisagrees,
} || std.mem.Allocator.Error;

pub const Inputs = struct {
    unicode_data: []const u8,
    derived_core_properties: []const u8,
    prop_list: []const u8,
    special_casing: []const u8,
    case_folding: []const u8,
};

pub const Data = struct {
    /// 例: "17.0.0"。入力の先頭行から読む。
    version: []const u8,
    flags: []u16,
    /// 単純写像。値は「写像先 - 元の符号位置」で、写像が無ければ0。
    upper: []i32,
    lower: []i32,
    fold: []i32,
    /// 十進数字の並びの先頭。各並びは10個で、値は先頭からの距離に等しい。
    digit_starts: []const u21,
    /// 完全写像のうち、結果が2文字以上のもの。符号位置の昇順。
    full_upper: []const FullMapping,
    full_lower: []const FullMapping,
    full_fold: []const FullMapping,
};

/// Parses all five files. The result lives as long as `gpa`'s allocations do.
pub fn parseAll(gpa: std.mem.Allocator, in: Inputs) Error!Data {
    const version = try parseVersion(in.derived_core_properties, "DerivedCoreProperties");
    for ([_]struct { []const u8, []const u8 }{
        .{ in.prop_list, "PropList" },
        .{ in.special_casing, "SpecialCasing" },
        .{ in.case_folding, "CaseFolding" },
    }) |f| {
        const v = try parseVersion(f[0], f[1]);
        if (!std.mem.eql(u8, v, version)) return error.VersionMismatch;
    }

    const flags = try gpa.alloc(u16, code_point_count);
    @memset(flags, 0);
    const upper = try gpa.alloc(i32, code_point_count);
    @memset(upper, 0);
    const lower = try gpa.alloc(i32, code_point_count);
    @memset(lower, 0);
    const fold = try gpa.alloc(i32, code_point_count);
    @memset(fold, 0);

    const digit_starts = try parseUnicodeData(gpa, in.unicode_data, flags, upper, lower);
    try parseProperties(in.derived_core_properties, flags, &.{
        .{ "Alphabetic", flag.alphabetic },
        .{ "Uppercase", flag.uppercase },
        .{ "Lowercase", flag.lowercase },
    });
    try parseProperties(in.prop_list, flags, &.{
        .{ "White_Space", flag.white_space },
    });
    const full_fold = try parseCaseFolding(gpa, in.case_folding, fold);
    const special = try parseSpecialCasing(gpa, in.special_casing, upper, lower);

    return .{
        .version = version,
        .flags = flags,
        .upper = upper,
        .lower = lower,
        .fold = fold,
        .digit_starts = digit_starts,
        .full_upper = special.upper,
        .full_lower = special.lower,
        .full_fold = full_fold,
    };
}

/// Reads "# <stem>-<version>.txt" from the first line.
pub fn parseVersion(text: []const u8, stem: []const u8) Error![]const u8 {
    const end = std.mem.indexOfScalar(u8, text, '\n') orelse text.len;
    const line = std.mem.trim(u8, text[0..end], " \t\r");
    if (!std.mem.startsWith(u8, line, "# ")) return error.MissingVersion;
    const name = line[2..];
    if (!std.mem.startsWith(u8, name, stem)) return error.MissingVersion;
    const rest = name[stem.len..];
    if (rest.len < 2 or rest[0] != '-' or !std.mem.endsWith(u8, rest, ".txt")) return error.MissingVersion;
    const version = rest[1 .. rest.len - ".txt".len];
    if (version.len == 0) return error.MissingVersion;
    return version;
}

/// The part of `line` before a '#', trimmed. Empty for blank and comment lines.
fn content(line: []const u8) []const u8 {
    const end = std.mem.indexOfScalar(u8, line, '#') orelse line.len;
    return std.mem.trim(u8, line[0..end], " \t\r");
}

fn parseCodePoint(text: []const u8) Error!u21 {
    const s = std.mem.trim(u8, text, " \t");
    const v = std.fmt.parseInt(u32, s, 16) catch return error.MalformedCodePoint;
    if (v > 0x10FFFF) return error.MalformedCodePoint;
    return @intCast(v);
}

const Range = struct { lo: u21, hi: u21 };

fn parseRange(text: []const u8) Error!Range {
    const s = std.mem.trim(u8, text, " \t");
    if (std.mem.indexOf(u8, s, "..")) |dots| {
        const lo = try parseCodePoint(s[0..dots]);
        const hi = try parseCodePoint(s[dots + 2 ..]);
        if (hi < lo) return error.MalformedCodePoint;
        return .{ .lo = lo, .hi = hi };
    }
    const cp = try parseCodePoint(s);
    return .{ .lo = cp, .hi = cp };
}

/// Splits a mapping such as "0053 0053" into at most 3 code points.
fn parseSequence(text: []const u8) Error!struct { len: u8, out: [3]u21 } {
    var out: [3]u21 = .{ 0, 0, 0 };
    var len: u8 = 0;
    var it = std.mem.tokenizeAny(u8, text, " \t");
    while (it.next()) |tok| {
        if (len == 3) return error.BadMappingLength;
        out[len] = try parseCodePoint(tok);
        len += 1;
    }
    if (len == 0) return error.BadMappingLength;
    return .{ .len = len, .out = out };
}

fn delta(from: u21, to: u21) i32 {
    return @as(i32, to) - @as(i32, from);
}

/// 一般カテゴリの全30種。これ以外が来たら入力が想定と違うので止める。
const general_categories = [_][]const u8{
    "Lu", "Ll", "Lt", "Lm", "Lo", "Mn", "Mc", "Me", "Nd", "Nl",
    "No", "Pc", "Pd", "Ps", "Pe", "Pi", "Pf", "Po", "Sm", "Sc",
    "Sk", "So", "Zs", "Zl", "Zp", "Cc", "Cf", "Cs", "Co", "Cn",
};

/// R7RS 7.1.1 の <subsequent> に、ASCII でない文字として入れてよい一般カテゴリ。
const identifier_categories = [_][]const u8{
    "Lu", "Ll", "Lt", "Lm", "Lo", "Mn", "Mc", "Me", "Nd", "Nl",
    "No", "Pd", "Pc", "Po", "Sc", "Sm", "Sk", "So", "Co",
};

/// <initial> から外れる一般カテゴリ(<subsequent> には入る)。
const not_initial_categories = [_][]const u8{ "Nd", "Mc", "Me" };

fn inCategories(set: []const []const u8, gc: []const u8) bool {
    for (set) |c| if (std.mem.eql(u8, c, gc)) return true;
    return false;
}

/// The identifier bits R7RS 7.1.1 gives a non-ASCII code point of category `gc`.
///
/// ASCII は字句規則が別にあるので、ここでは常に0を返す。U+200C と U+200D は
/// 一般カテゴリ Cf だが、規則が名指しで許し、最初の文字にも置ける。
fn identifierBits(cp: u21, gc: []const u8) Error!u16 {
    if (!inCategories(&general_categories, gc)) return error.UnknownCategory;
    if (cp < 0x80) return 0;
    if (cp == 0x200C or cp == 0x200D) return flag.identifier_initial | flag.identifier_subsequent;
    if (!inCategories(&identifier_categories, gc)) return 0;
    if (inCategories(&not_initial_categories, gc)) return flag.identifier_subsequent;
    return flag.identifier_initial | flag.identifier_subsequent;
}

/// Fills `flags` (numeric, identifier bits) and the simple upper/lower deltas. Returns the digit run starts.
fn parseUnicodeData(
    gpa: std.mem.Allocator,
    text: []const u8,
    flags: []u16,
    upper: []i32,
    lower: []i32,
) Error![]const u21 {
    const Digit = struct { cp: u21, value: u8 };
    var digits: std.ArrayList(Digit) = .empty;
    defer digits.deinit(gpa);

    const Open = struct { cp: u21, stem: []const u8, gc: []const u8 };
    var open: ?Open = null;

    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        var fields: [15][]const u8 = undefined;
        var it = std.mem.splitScalar(u8, line, ';');
        for (&fields) |*f| f.* = it.next() orelse return error.MalformedLine;
        const cp = try parseCodePoint(fields[0]);
        const name = fields[1];
        const gc = fields[2];
        // 範囲の端(CJK や Hangul など)。写像も十進数字も持たない。First の次の行は、
        // 同じ名前と同じカテゴリの Last でなければならない。範囲の中の符号位置は、
        // 一般カテゴリを範囲と共有する。
        const is_first = std.mem.endsWith(u8, name, ", First>");
        const is_last = std.mem.endsWith(u8, name, ", Last>");
        if (is_first or is_last) {
            if (std.mem.eql(u8, gc, "Nd")) return error.NonStandardDigitRun;
            if (is_first) {
                if (open != null) return error.UnpairedRange;
                open = .{ .cp = cp, .stem = name[0 .. name.len - ", First>".len], .gc = gc };
                continue;
            }
            const first = open orelse return error.UnpairedRange;
            open = null;
            const stem = name[0 .. name.len - ", Last>".len];
            if (!std.mem.eql(u8, first.stem, stem) or !std.mem.eql(u8, first.gc, gc) or cp < first.cp)
                return error.UnpairedRange;
            for (first.cp..@as(usize, cp) + 1) |c| flags[c] |= try identifierBits(@intCast(c), gc);
            continue;
        }
        if (open != null) return error.UnpairedRange;
        flags[cp] |= try identifierBits(cp, gc);
        if (std.mem.eql(u8, gc, "Nd")) {
            flags[cp] |= flag.numeric;
            const value = std.fmt.parseInt(u8, fields[6], 10) catch return error.MalformedLine;
            if (value > 9) return error.MalformedLine;
            try digits.append(gpa, .{ .cp = cp, .value = value });
        }
        if (fields[12].len != 0) upper[cp] = delta(cp, try parseCodePoint(fields[12]));
        if (fields[13].len != 0) lower[cp] = delta(cp, try parseCodePoint(fields[13]));
    }

    if (open != null) return error.UnpairedRange;

    // 十進数字は、値0から9まで連続する10個の並びでできている。そうでない並びが来たら、
    // 先頭からの距離で値を引く表現が成り立たないので、止める。
    if (digits.items.len % 10 != 0) return error.NonStandardDigitRun;
    var starts: std.ArrayList(u21) = .empty;
    errdefer starts.deinit(gpa);
    var i: usize = 0;
    while (i < digits.items.len) : (i += 10) {
        const start = digits.items[i].cp;
        for (0..10) |k| {
            const d = digits.items[i + k];
            if (d.cp != start + k or d.value != k) return error.NonStandardDigitRun;
        }
        if (starts.items.len != 0 and start <= starts.items[starts.items.len - 1]) return error.NonStandardDigitRun;
        try starts.append(gpa, start);
    }
    return starts.toOwnedSlice(gpa);
}

const Wanted = struct { []const u8, u16 };

/// Sets the bit of each wanted property over its ranges. Every wanted property must occur.
fn parseProperties(text: []const u8, flags: []u16, wanted: []const Wanted) Error!void {
    var seen: [8]bool = @splat(false);
    std.debug.assert(wanted.len <= seen.len);
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = content(raw);
        if (line.len == 0) continue;
        var it = std.mem.splitScalar(u8, line, ';');
        const range_text = it.next() orelse return error.MalformedLine;
        const name = std.mem.trim(u8, it.next() orelse return error.MalformedLine, " \t");
        for (wanted, 0..) |w, k| {
            if (!std.mem.eql(u8, name, w[0])) continue;
            const r = try parseRange(range_text);
            for (r.lo..@as(usize, r.hi) + 1) |cp| flags[cp] |= w[1];
            seen[k] = true;
        }
    }
    for (wanted, 0..) |_, k| if (!seen[k]) return error.PropertyNotFound;
}

fn lessThan(_: void, a: FullMapping, b: FullMapping) bool {
    return a.cp < b.cp;
}

/// 昇順に並べ、符号位置の重複を拒む。
fn finishFull(gpa: std.mem.Allocator, list: *std.ArrayList(FullMapping)) Error![]const FullMapping {
    std.mem.sort(FullMapping, list.items, {}, lessThan);
    for (list.items[1..], 0..) |m, i| {
        if (m.cp == list.items[i].cp) return error.DuplicateMapping;
    }
    return list.toOwnedSlice(gpa);
}

/// Fills the simple fold deltas (status C and S). Returns the full foldings (status F).
fn parseCaseFolding(gpa: std.mem.Allocator, text: []const u8, fold: []i32) Error![]const FullMapping {
    var full: std.ArrayList(FullMapping) = .empty;
    errdefer full.deinit(gpa);
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = content(raw);
        if (line.len == 0) continue;
        var it = std.mem.splitScalar(u8, line, ';');
        const cp = try parseCodePoint(it.next() orelse return error.MalformedLine);
        const status = std.mem.trim(u8, it.next() orelse return error.MalformedLine, " \t");
        const seq = try parseSequence(it.next() orelse return error.MalformedLine);
        if (std.mem.eql(u8, status, "C") or std.mem.eql(u8, status, "S")) {
            if (seq.len != 1) return error.BadMappingLength;
            if (fold[cp] != 0) return error.DuplicateMapping;
            fold[cp] = delta(cp, seq.out[0]);
        } else if (std.mem.eql(u8, status, "F")) {
            if (seq.len < 2) return error.BadMappingLength;
            try full.append(gpa, .{ .cp = cp, .len = seq.len, .out = seq.out });
        } else if (!std.mem.eql(u8, status, "T")) {
            return error.UnknownCaseFoldingStatus;
        }
    }
    return finishFull(gpa, &full);
}

/// Returns the unconditional full upper/lower mappings that are longer than one code point.
///
/// 条件つきの行(Final_Sigma や言語依存)は読み飛ばす。R7RS 6.7 は言語に依存しない写像を
/// 求めるので、条件つきの写像は表に入れない。結果が1文字の行は単純写像と同じはずなので、
/// 食い違えば止める。
fn parseSpecialCasing(
    gpa: std.mem.Allocator,
    text: []const u8,
    upper: []const i32,
    lower: []const i32,
) Error!struct { upper: []const FullMapping, lower: []const FullMapping } {
    var up: std.ArrayList(FullMapping) = .empty;
    errdefer up.deinit(gpa);
    var low: std.ArrayList(FullMapping) = .empty;
    errdefer low.deinit(gpa);
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = content(raw);
        if (line.len == 0) continue;
        var it = std.mem.splitScalar(u8, line, ';');
        const cp = try parseCodePoint(it.next() orelse return error.MalformedLine);
        const lower_text = it.next() orelse return error.MalformedLine;
        _ = it.next() orelse return error.MalformedLine; // title
        const upper_text = it.next() orelse return error.MalformedLine;
        if (it.next()) |condition| {
            if (std.mem.trim(u8, condition, " \t").len != 0) continue;
        }
        const l = try parseSequence(lower_text);
        const u = try parseSequence(upper_text);
        if (l.len > 1)
            try low.append(gpa, .{ .cp = cp, .len = l.len, .out = l.out })
        else if (@as(i32, l.out[0]) != @as(i32, cp) + lower[cp]) return error.SpecialCasingDisagrees;
        if (u.len > 1)
            try up.append(gpa, .{ .cp = cp, .len = u.len, .out = u.out })
        else if (@as(i32, u.out[0]) != @as(i32, cp) + upper[cp]) return error.SpecialCasingDisagrees;
    }
    return .{ .upper = try finishFull(gpa, &up), .lower = try finishFull(gpa, &low) };
}

// 以下のテストは、実物の UCD の一部を写した小さな入力で、各ファイルの読み方を固定する。

test "parseVersion reads the first line" {
    try std.testing.expectEqualStrings("17.0.0", try parseVersion("# CaseFolding-17.0.0.txt\n# x", "CaseFolding"));
    try std.testing.expectError(error.MissingVersion, parseVersion("CaseFolding-17.0.0.txt", "CaseFolding"));
    try std.testing.expectError(error.MissingVersion, parseVersion("# PropList-17.0.0.txt", "CaseFolding"));
    try std.testing.expectError(error.MissingVersion, parseVersion("# CaseFolding-.txt", "CaseFolding"));
}

test "parseUnicodeData sets numeric, simple mappings and digit runs" {
    const gpa = std.testing.allocator;
    const flags = try gpa.alloc(u16, code_point_count);
    defer gpa.free(flags);
    const upper = try gpa.alloc(i32, code_point_count);
    defer gpa.free(upper);
    const lower = try gpa.alloc(i32, code_point_count);
    defer gpa.free(lower);
    @memset(flags, 0);
    @memset(upper, 0);
    @memset(lower, 0);

    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(gpa);
    try text.appendSlice(gpa, "0041;LATIN CAPITAL LETTER A;Lu;0;L;;;;;N;;;;0061;\n" ++
        "0061;LATIN SMALL LETTER A;Ll;0;L;;;;;N;;;0041;;0041\n" ++
        "4E00;<CJK Ideograph, First>;Lo;0;L;;;;;N;;;;;\n" ++
        "9FFF;<CJK Ideograph, Last>;Lo;0;L;;;;;N;;;;;\n");
    for (0..10) |k| {
        try text.print(gpa, "{X:0>4};ARABIC-INDIC DIGIT;Nd;0;AN;;{d};{d};{d};N;;;;;\n", .{ 0x660 + k, k, k, k });
    }
    const starts = try parseUnicodeData(gpa, text.items, flags, upper, lower);
    defer gpa.free(starts);
    try std.testing.expectEqualSlices(u21, &.{0x660}, starts);
    try std.testing.expectEqual(flag.numeric | flag.identifier_subsequent, flags[0x664]);
    try std.testing.expectEqual(@as(u16, 0), flags[0x41]);
    try std.testing.expectEqual(@as(i32, 0x20), lower[0x41]);
    try std.testing.expectEqual(@as(i32, -0x20), upper[0x61]);
    try std.testing.expectEqual(@as(i32, 0), upper[0x41]);
    // 範囲の端の行は、範囲の中の全符号位置に一般カテゴリを広げる。数字や写像は持たない。
    try std.testing.expectEqual(flag.identifier_initial | flag.identifier_subsequent, flags[0x4E00]);
    try std.testing.expectEqual(flag.identifier_initial | flag.identifier_subsequent, flags[0x7000]);
    try std.testing.expectEqual(flag.identifier_initial | flag.identifier_subsequent, flags[0x9FFF]);
    try std.testing.expectEqual(@as(u16, 0), flags[0x9FFF + 1]);
    try std.testing.expectEqual(@as(i32, 0), lower[0x7000]);
}

fn parseForIdentifierBits(gpa: std.mem.Allocator, text: []const u8, flags: []u16) Error!void {
    const upper = try gpa.alloc(i32, code_point_count);
    defer gpa.free(upper);
    const lower = try gpa.alloc(i32, code_point_count);
    defer gpa.free(lower);
    @memset(flags, 0);
    @memset(upper, 0);
    @memset(lower, 0);
    const starts = try parseUnicodeData(gpa, text, flags, upper, lower);
    gpa.free(starts);
}

test "parseUnicodeData sets the identifier bits by general category (R7RS 7.1.1)" {
    const gpa = std.testing.allocator;
    const flags = try gpa.alloc(u16, code_point_count);
    defer gpa.free(flags);
    const both = flag.identifier_initial | flag.identifier_subsequent;
    const sub = flag.identifier_subsequent;
    const text =
        "0021;EXCLAMATION MARK;Po;0;ON;;;;;N;;;;;\n" ++
        "0061;LATIN SMALL LETTER A;Ll;0;L;;;;;N;;;0041;;0041\n" ++
        "00A0;NO-BREAK SPACE;Zs;0;CS;<noBreak> 0020;;;;N;NON-BREAKING SPACE;;;;\n" ++
        "00A9;COPYRIGHT SIGN;So;0;ON;;;;;N;;;;;\n" ++
        "00AD;SOFT HYPHEN;Cf;0;BN;;;;;N;;;;;\n" ++
        "0300;COMBINING GRAVE ACCENT;Mn;230;NSM;;;;;N;;;;;\n" ++
        "0903;DEVANAGARI SIGN VISARGA;Mc;0;L;;;;;N;;;;;\n" ++
        "20DD;COMBINING ENCLOSING CIRCLE;Me;0;NSM;;;;;N;;;;;\n" ++
        "2018;LEFT SINGLE QUOTATION MARK;Pi;0;ON;;;;;N;;;;;\n" ++
        "200C;ZERO WIDTH NON-JOINER;Cf;0;BN;;;;;N;;;;;\n" ++
        "200D;ZERO WIDTH JOINER;Cf;0;BN;;;;;N;;;;;\n" ++
        "E000;<Private Use, First>;Co;0;L;;;;;N;;;;;\n" ++
        "F8FF;<Private Use, Last>;Co;0;L;;;;;N;;;;;\n" ++
        "D800;<Non Private Use High Surrogate, First>;Cs;0;L;;;;;N;;;;;\n" ++
        "DB7F;<Non Private Use High Surrogate, Last>;Cs;0;L;;;;;N;;;;;\n";
    try parseForIdentifierBits(gpa, text, flags);
    try std.testing.expectEqual(@as(u16, 0), flags[0x21]); // ASCII は常に0
    try std.testing.expectEqual(@as(u16, 0), flags[0x61]);
    try std.testing.expectEqual(@as(u16, 0), flags[0xA0]);
    try std.testing.expectEqual(both, flags[0xA9]);
    try std.testing.expectEqual(@as(u16, 0), flags[0xAD]);
    try std.testing.expectEqual(both, flags[0x300]); // Mn は最初の文字にも置ける
    try std.testing.expectEqual(sub, flags[0x903]);
    try std.testing.expectEqual(sub, flags[0x20DD]);
    try std.testing.expectEqual(@as(u16, 0), flags[0x2018]);
    try std.testing.expectEqual(both, flags[0x200C]);
    try std.testing.expectEqual(both, flags[0x200D]);
    try std.testing.expectEqual(both, flags[0xE000]);
    try std.testing.expectEqual(both, flags[0xF000]);
    try std.testing.expectEqual(both, flags[0xF8FF]);
    try std.testing.expectEqual(@as(u16, 0), flags[0xF900]);
    try std.testing.expectEqual(@as(u16, 0), flags[0xD800]);
    try std.testing.expectEqual(@as(u16, 0), flags[0xDB7F]);
}

test "parseUnicodeData keeps the identifier bits of a decimal digit out of the initial set" {
    const gpa = std.testing.allocator;
    const flags = try gpa.alloc(u16, code_point_count);
    defer gpa.free(flags);
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(gpa);
    for (0..10) |k| {
        try text.print(gpa, "{X:0>4};ARABIC-INDIC DIGIT;Nd;0;AN;;{d};{d};{d};N;;;;;\n", .{ 0x660 + k, k, k, k });
    }
    try parseForIdentifierBits(gpa, text.items, flags);
    try std.testing.expectEqual(flag.identifier_subsequent, flags[0x660] & (flag.identifier_initial | flag.identifier_subsequent));
    try std.testing.expectEqual(flag.numeric | flag.identifier_subsequent, flags[0x669]);
}

test "parseUnicodeData rejects a range line without its partner and an unknown category" {
    const gpa = std.testing.allocator;
    const flags = try gpa.alloc(u16, code_point_count);
    defer gpa.free(flags);
    const first = "4E00;<CJK Ideograph, First>;Lo;0;L;;;;;N;;;;;\n";
    const last = "9FFF;<CJK Ideograph, Last>;Lo;0;L;;;;;N;;;;;\n";
    const other = "0061;LATIN SMALL LETTER A;Ll;0;L;;;;;N;;;0041;;0041\n";
    try std.testing.expectError(error.UnpairedRange, parseForIdentifierBits(gpa, first, flags));
    try std.testing.expectError(error.UnpairedRange, parseForIdentifierBits(gpa, last, flags));
    try std.testing.expectError(error.UnpairedRange, parseForIdentifierBits(gpa, first ++ other ++ last, flags));
    try std.testing.expectError(error.UnpairedRange, parseForIdentifierBits(gpa, first ++ first ++ last, flags));
    try std.testing.expectError(
        error.UnpairedRange,
        parseForIdentifierBits(gpa, first ++ "9FFF;<Hangul Syllable, Last>;Lo;0;L;;;;;N;;;;;\n", flags),
    );
    try std.testing.expectError(
        error.UnpairedRange,
        parseForIdentifierBits(gpa, first ++ "9FFF;<CJK Ideograph, Last>;Ll;0;L;;;;;N;;;;;\n", flags),
    );
    try std.testing.expectError(
        error.UnpairedRange,
        parseForIdentifierBits(gpa, "9FFF;<CJK Ideograph, First>;Lo;0;L;;;;;N;;;;;\n" ++ "4E00;<CJK Ideograph, Last>;Lo;0;L;;;;;N;;;;;\n", flags),
    );
    try std.testing.expectError(
        error.UnknownCategory,
        parseForIdentifierBits(gpa, "00E9;X;Xx;0;L;;;;;N;;;;;\n", flags),
    );
}

test "parseUnicodeData rejects a digit run that is not 0 to 9" {
    const gpa = std.testing.allocator;
    const flags = try gpa.alloc(u16, code_point_count);
    defer gpa.free(flags);
    const upper = try gpa.alloc(i32, code_point_count);
    defer gpa.free(upper);
    const lower = try gpa.alloc(i32, code_point_count);
    defer gpa.free(lower);
    @memset(flags, 0);
    @memset(upper, 0);
    @memset(lower, 0);
    try std.testing.expectError(
        error.NonStandardDigitRun,
        parseUnicodeData(gpa, "0660;D;Nd;0;AN;;0;0;0;N;;;;;\n", flags, upper, lower),
    );
}

test "parseProperties sets bits over ranges and requires each property" {
    const gpa = std.testing.allocator;
    const flags = try gpa.alloc(u16, code_point_count);
    defer gpa.free(flags);
    @memset(flags, 0);
    const text =
        "# PropList-17.0.0.txt\n" ++
        "0009..000D    ; White_Space # Cc   [5] <control-0009>..<control-000D>\n" ++
        "0020          ; White_Space # Zs       SPACE\n" ++
        "0041..005A    ; Other_Thing # Lu\n";
    try parseProperties(text, flags, &.{.{ "White_Space", flag.white_space }});
    try std.testing.expectEqual(flag.white_space, flags[0x0B]);
    try std.testing.expectEqual(flag.white_space, flags[0x20]);
    try std.testing.expectEqual(@as(u16, 0), flags[0x0E]);
    try std.testing.expectEqual(@as(u16, 0), flags[0x41]);
    try std.testing.expectError(
        error.PropertyNotFound,
        parseProperties(text, flags, &.{.{ "Alphabetic", flag.alphabetic }}),
    );
}

test "parseCaseFolding separates simple and full foldings" {
    const gpa = std.testing.allocator;
    const fold = try gpa.alloc(i32, code_point_count);
    defer gpa.free(fold);
    @memset(fold, 0);
    const text =
        "# CaseFolding-17.0.0.txt\n" ++
        "0041; C; 0061; # LATIN CAPITAL LETTER A\n" ++
        "00DF; F; 0073 0073; # LATIN SMALL LETTER SHARP S\n" ++
        "1E9E; F; 0073 0073; # LATIN CAPITAL LETTER SHARP S\n" ++
        "1E9E; S; 00DF; # LATIN CAPITAL LETTER SHARP S\n" ++
        "0049; T; 0131; # LATIN CAPITAL LETTER I\n";
    const full = try parseCaseFolding(gpa, text, fold);
    defer gpa.free(full);
    try std.testing.expectEqual(@as(i32, 0x20), fold[0x41]);
    try std.testing.expectEqual(@as(i32, 0x00DF - 0x1E9E), fold[0x1E9E]);
    try std.testing.expectEqual(@as(i32, 0), fold[0x49]);
    try std.testing.expectEqual(@as(usize, 2), full.len);
    try std.testing.expectEqual(@as(u21, 0x00DF), full[0].cp);
    try std.testing.expectEqual(@as(u8, 2), full[0].len);
    try std.testing.expectEqual(@as(u21, 0x73), full[0].out[1]);
    try std.testing.expectError(error.UnknownCaseFoldingStatus, parseCaseFolding(gpa, "0041; X; 0061;\n", fold));
}

test "parseCaseFolding sorts full foldings into ascending order and rejects a duplicate" {
    const gpa = std.testing.allocator;
    const fold = try gpa.alloc(i32, code_point_count);
    defer gpa.free(fold);
    @memset(fold, 0);
    // 入力は降順。引く側が二分探索するので、出力は昇順でなければならない。
    const text =
        "# CaseFolding-17.0.0.txt\n" ++
        "FB00; F; 0066 0066;\n" ++
        "1E9E; F; 0073 0073;\n" ++
        "00DF; F; 0073 0073;\n";
    const full = try parseCaseFolding(gpa, text, fold);
    defer gpa.free(full);
    try std.testing.expectEqual(@as(usize, 3), full.len);
    try std.testing.expectEqual(@as(u21, 0x00DF), full[0].cp);
    try std.testing.expectEqual(@as(u21, 0x1E9E), full[1].cp);
    try std.testing.expectEqual(@as(u21, 0xFB00), full[2].cp);

    try std.testing.expectError(
        error.DuplicateMapping,
        parseCaseFolding(gpa, "00DF; F; 0073 0073;\n00DF; F; 0073 0073;\n", fold),
    );
}

test "parseSpecialCasing keeps only unconditional multi-character mappings" {
    const gpa = std.testing.allocator;
    const upper = try gpa.alloc(i32, code_point_count);
    defer gpa.free(upper);
    const lower = try gpa.alloc(i32, code_point_count);
    defer gpa.free(lower);
    @memset(upper, 0);
    @memset(lower, 0);
    lower[0x130] = 0x69 - 0x130;
    const text =
        "# SpecialCasing-17.0.0.txt\n" ++
        "00DF; 00DF; 0053 0073; 0053 0053; # LATIN SMALL LETTER SHARP S\n" ++
        "0130; 0069 0307; 0130; 0130; # LATIN CAPITAL LETTER I WITH DOT ABOVE\n" ++
        "03A3; 03C3; 03A3; 03A3; Final_Sigma; # GREEK CAPITAL LETTER SIGMA\n" ++
        "0130; 0069; 0130; 0130; tr; # LATIN CAPITAL LETTER I WITH DOT ABOVE\n";
    const got = try parseSpecialCasing(gpa, text, upper, lower);
    defer gpa.free(got.upper);
    defer gpa.free(got.lower);
    try std.testing.expectEqual(@as(usize, 1), got.upper.len);
    try std.testing.expectEqual(@as(u21, 0x00DF), got.upper[0].cp);
    try std.testing.expectEqual(@as(u21, 0x53), got.upper[0].out[1]);
    try std.testing.expectEqual(@as(usize, 1), got.lower.len);
    try std.testing.expectEqual(@as(u21, 0x130), got.lower[0].cp);
    try std.testing.expectEqual(@as(u8, 2), got.lower[0].len);
}

test "parseSpecialCasing rejects a single-character mapping that differs from the simple one" {
    const gpa = std.testing.allocator;
    const upper = try gpa.alloc(i32, code_point_count);
    defer gpa.free(upper);
    const lower = try gpa.alloc(i32, code_point_count);
    defer gpa.free(lower);
    @memset(upper, 0);
    @memset(lower, 0);
    try std.testing.expectError(
        error.SpecialCasingDisagrees,
        parseSpecialCasing(gpa, "0041; 0062; 0041; 0041; # x\n", upper, lower),
    );
}
