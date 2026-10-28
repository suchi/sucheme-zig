//! Pins the answers of the vendored UCD files at code points whose properties are known
//! independently of this generator.
//!
//! 期待値は生成器の出力から写したものではなく、Unicode の定義から選んだ。版をまたいで
//! 変わらない符号位置だけを使う。合成した小さな入力では、読み方の取り違え(プロパティ名の
//! 部分一致、欄の取り違え、範囲の端)が緑のまま通るので、取り込んだ実物でも固定する。

const std = @import("std");
const ucd = @import("ucd.zig");

const flag = ucd.flag;

fn load(arena: std.mem.Allocator) !ucd.Data {
    return ucd.parseAll(arena, .{
        .unicode_data = @embedFile("ucd/UnicodeData.txt"),
        .derived_core_properties = @embedFile("ucd/DerivedCoreProperties.txt"),
        .prop_list = @embedFile("ucd/PropList.txt"),
        .special_casing = @embedFile("ucd/SpecialCasing.txt"),
        .case_folding = @embedFile("ucd/CaseFolding.txt"),
    });
}

fn delta(from: u21, to: u21) i32 {
    return @as(i32, to) - @as(i32, from);
}

fn expectFull(table: []const ucd.FullMapping, cp: u21, want: []const u21) !void {
    for (table) |m| {
        if (m.cp != cp) continue;
        try std.testing.expectEqual(want.len, @as(usize, m.len));
        try std.testing.expectEqualSlices(u21, want, m.out[0..m.len]);
        return;
    }
    return error.MappingNotFound;
}

fn expectNoFull(table: []const ucd.FullMapping, cp: u21) !void {
    for (table) |m| try std.testing.expect(m.cp != cp);
}

test "real data: properties of known code points" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const d = try load(arena_state.allocator());

    const alpha = flag.alphabetic;
    const known = [_]struct { cp: u21, flags: u16 }{
        .{ .cp = 'A', .flags = alpha | flag.uppercase },
        .{ .cp = 'a', .flags = alpha | flag.lowercase },
        .{ .cp = 0x00DF, .flags = alpha | flag.lowercase },
        .{ .cp = 0x0130, .flags = alpha | flag.uppercase },
        .{ .cp = 0x03B1, .flags = alpha | flag.lowercase },
        .{ .cp = 0x03C2, .flags = alpha | flag.lowercase },
        // Lt: 大文字でも小文字でもない。
        .{ .cp = 0x01C5, .flags = alpha },
        // Other_Lowercase / Other_Uppercase で Lowercase / Uppercase になるもの。
        .{ .cp = 0x00AA, .flags = alpha | flag.lowercase },
        .{ .cp = 0x2160, .flags = alpha | flag.uppercase },
        // Nd だけが Numeric_Type=Decimal である。
        .{ .cp = '0', .flags = flag.numeric },
        .{ .cp = '9', .flags = flag.numeric },
        .{ .cp = 0x0660, .flags = flag.numeric },
        .{ .cp = 0xFF10, .flags = flag.numeric },
        .{ .cp = 0x1D7CE, .flags = flag.numeric },
        .{ .cp = 0x00B2, .flags = 0 },
        .{ .cp = 0x00BD, .flags = 0 },
        // White_Space の端と、その外。
        .{ .cp = 0x0008, .flags = 0 },
        .{ .cp = 0x0009, .flags = flag.white_space },
        .{ .cp = 0x000A, .flags = flag.white_space },
        .{ .cp = 0x000D, .flags = flag.white_space },
        .{ .cp = 0x000E, .flags = 0 },
        .{ .cp = 0x001F, .flags = 0 },
        .{ .cp = ' ', .flags = flag.white_space },
        .{ .cp = 0x0085, .flags = flag.white_space },
        .{ .cp = 0x00A0, .flags = flag.white_space },
        .{ .cp = 0x1680, .flags = flag.white_space },
        .{ .cp = 0x180E, .flags = 0 },
        .{ .cp = 0x2000, .flags = flag.white_space },
        .{ .cp = 0x200A, .flags = flag.white_space },
        .{ .cp = 0x200B, .flags = 0 },
        .{ .cp = 0x2028, .flags = flag.white_space },
        .{ .cp = 0x2029, .flags = flag.white_space },
        .{ .cp = 0x202F, .flags = flag.white_space },
        .{ .cp = 0x205F, .flags = flag.white_space },
        .{ .cp = 0x3000, .flags = flag.white_space },
        // 属性を持たないもの。
        .{ .cp = '!', .flags = 0 },
        .{ .cp = 0x10FFFF, .flags = 0 },
    };
    for (known) |k| {
        std.testing.expectEqual(k.flags, d.flags[k.cp]) catch |err| {
            std.debug.print("flags of U+{X:0>4}\n", .{k.cp});
            return err;
        };
    }
}

test "real data: simple mappings of known code points" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const d = try load(arena_state.allocator());

    const known = [_]struct { cp: u21, upper: u21, lower: u21, fold: u21 }{
        .{ .cp = 'A', .upper = 'A', .lower = 'a', .fold = 'a' },
        .{ .cp = 'a', .upper = 'A', .lower = 'a', .fold = 'a' },
        .{ .cp = 'Z', .upper = 'Z', .lower = 'z', .fold = 'z' },
        .{ .cp = '0', .upper = '0', .lower = '0', .fold = '0' },
        // ß は単純な大文字を持たない。
        .{ .cp = 0x00DF, .upper = 0x00DF, .lower = 0x00DF, .fold = 0x00DF },
        // İ の単純な小文字は i で、単純な畳み込みは無い(完全な畳み込みと T だけ)。
        .{ .cp = 0x0130, .upper = 0x0130, .lower = 'i', .fold = 0x0130 },
        // ı の単純な大文字は I。
        .{ .cp = 0x0131, .upper = 'I', .lower = 0x0131, .fold = 0x0131 },
        .{ .cp = 0x03A3, .upper = 0x03A3, .lower = 0x03C3, .fold = 0x03C3 },
        // 語末のシグマも σ と同じ大文字と畳み込みを持つ。
        .{ .cp = 0x03C2, .upper = 0x03A3, .lower = 0x03C2, .fold = 0x03C3 },
        .{ .cp = 0x03C3, .upper = 0x03A3, .lower = 0x03C3, .fold = 0x03C3 },
        // Lt: 大文字と小文字が違う二重字。UnicodeData の欄は 大文字;小文字;タイトルケース の順。
        .{ .cp = 0x01C5, .upper = 0x01C4, .lower = 0x01C6, .fold = 0x01C6 },
        .{ .cp = 0x01C4, .upper = 0x01C4, .lower = 0x01C6, .fold = 0x01C6 },
        .{ .cp = 0x01C6, .upper = 0x01C4, .lower = 0x01C6, .fold = 0x01C6 },
        .{ .cp = 0x1E9E, .upper = 0x1E9E, .lower = 0x00DF, .fold = 0x00DF },
        .{ .cp = 0x2160, .upper = 0x2160, .lower = 0x2170, .fold = 0x2170 },
        .{ .cp = 0x0410, .upper = 0x0410, .lower = 0x0430, .fold = 0x0430 },
        // 符号位置の最後の面には写像が無い。
        .{ .cp = 0x10FFFF, .upper = 0x10FFFF, .lower = 0x10FFFF, .fold = 0x10FFFF },
    };
    for (known) |k| {
        errdefer std.debug.print("simple mappings of U+{X:0>4}\n", .{k.cp});
        try std.testing.expectEqual(delta(k.cp, k.upper), d.upper[k.cp]);
        try std.testing.expectEqual(delta(k.cp, k.lower), d.lower[k.cp]);
        try std.testing.expectEqual(delta(k.cp, k.fold), d.fold[k.cp]);
    }
}

test "real data: full mappings of known code points" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const d = try load(arena_state.allocator());

    try expectFull(d.full_upper, 0x00DF, &.{ 'S', 'S' });
    try expectFull(d.full_upper, 0xFB00, &.{ 'F', 'F' });
    try expectFull(d.full_upper, 0x0149, &.{ 0x02BC, 'N' });
    try expectFull(d.full_upper, 0x0390, &.{ 0x0399, 0x0308, 0x0301 });
    try expectNoFull(d.full_upper, 'a');

    try expectFull(d.full_lower, 0x0130, &.{ 'i', 0x0307 });
    try expectNoFull(d.full_lower, 'A');
    // Final_Sigma などの条件つきの行は入らない。
    try expectNoFull(d.full_lower, 0x03A3);

    try expectFull(d.full_fold, 0x00DF, &.{ 's', 's' });
    try expectFull(d.full_fold, 0x1E9E, &.{ 's', 's' });
    try expectFull(d.full_fold, 0x0130, &.{ 'i', 0x0307 });
    try expectFull(d.full_fold, 0xFB00, &.{ 'f', 'f' });
    try expectNoFull(d.full_fold, 'A');

    // 昇順で、重複が無い。
    for ([_][]const ucd.FullMapping{ d.full_upper, d.full_lower, d.full_fold }) |t| {
        try std.testing.expect(t.len > 0);
        for (t[1..], 0..) |m, i| try std.testing.expect(m.cp > t[i].cp);
    }
}

test "real data: decimal digit runs agree with the Numeric flag" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const d = try load(arena_state.allocator());

    const wanted = [_]u21{ 0x0030, 0x0660, 0x06F0, 0x0966, 0xFF10, 0x1D7CE };
    for (wanted) |w| {
        errdefer std.debug.print("digit run at U+{X:0>4}\n", .{w});
        try std.testing.expect(std.mem.indexOfScalar(u21, d.digit_starts, w) != null);
    }
    try std.testing.expect(std.mem.indexOfScalar(u21, d.digit_starts, 0x0031) == null);

    // Numeric の印が付く符号位置は、並びの10個ずつと過不足なく一致する。
    var numeric: usize = 0;
    for (d.flags) |f| {
        if (f & flag.numeric != 0) numeric += 1;
    }
    try std.testing.expectEqual(d.digit_starts.len * 10, numeric);
    for (d.digit_starts, 0..) |s, i| {
        if (i > 0) try std.testing.expect(s > d.digit_starts[i - 1]);
        for (0..10) |k| try std.testing.expect(d.flags[s + k] & flag.numeric != 0);
    }
}

test "real data: two-stage tables return every value" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const d = try load(arena);
    const emit = @import("emit.zig");
    // 合成した入力では区画が数個しかなく、区画の同一判定の誤りが出ない。実データの全符号位置で戻す。
    inline for (.{ d.flags, d.upper, d.lower, d.fold }) |values| {
        const T = @typeInfo(@TypeOf(values)).pointer.child;
        const t = try emit.buildTwoStage(T, arena, values);
        for (values, 0..) |v, cp| try std.testing.expectEqual(v, emit.lookup(T, t, @intCast(cp)));
    }
}

test "real data: the version is the vendored one" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const d = try load(arena_state.allocator());
    try std.testing.expectEqualStrings("18.0.0", d.version);
}

test {
    std.testing.refAllDecls(@This());
}
