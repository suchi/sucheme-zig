//! Builds the two-stage tables and renders them as Zig source.
//!
//! 属性の束と単純写像(大文字、小文字、畳み込み)は、符号位置の上位ビットで区画を引き、
//! 同じ内容の区画を共有する2段の表にする。完全写像と十進数字の並びは、例外が少ないので
//! 整列した表のまま出す(引く側が二分探索する)。段数と区画の大きさは、4u2 の実測で
//! 見直す(docs/plans/0018-phase4-numeric-tower-unicode.md の合意を求める点の1)。

const std = @import("std");
const ucd = @import("ucd.zig");

/// 区画の大きさの2を底とする対数。符号位置の下位 block_shift ビットが区画の中の位置になる。
pub const block_shift = 7;
const block_size = 1 << block_shift;

pub fn TwoStage(comptime T: type) type {
    return struct {
        /// 区画の番号。添字は符号位置 >> block_shift。
        stage1: []const u16,
        /// 区画を並べたもの。区画 b の位置 i は stage2[b * block_size + i]。
        stage2: []const T,
    };
}

const BlockSet = struct {
    fn Context(comptime T: type) type {
        return struct {
            pub fn hash(_: @This(), key: []const T) u64 {
                return std.hash.Wyhash.hash(0, std.mem.sliceAsBytes(key));
            }
            pub fn eql(_: @This(), a: []const T, b: []const T) bool {
                return std.mem.eql(T, a, b);
            }
        };
    }
};

/// Splits `values` into blocks and shares the ones with equal contents.
pub fn buildTwoStage(comptime T: type, gpa: std.mem.Allocator, values: []const T) !TwoStage(T) {
    std.debug.assert(values.len % block_size == 0);
    const block_count = values.len / block_size;
    var stage1 = try gpa.alloc(u16, block_count);
    errdefer gpa.free(stage1);
    var stage2: std.ArrayList(T) = .empty;
    errdefer stage2.deinit(gpa);

    var seen: std.HashMapUnmanaged([]const T, u16, BlockSet.Context(T), 80) = .empty;
    defer seen.deinit(gpa);
    for (0..block_count) |b| {
        const block = values[b * block_size ..][0..block_size];
        const entry = try seen.getOrPut(gpa, block);
        if (!entry.found_existing) {
            const id = stage2.items.len / block_size;
            // u16 に収まらないほど区画が増えることは、符号位置の数からありえない。
            entry.value_ptr.* = @intCast(id);
            try stage2.appendSlice(gpa, block);
        }
        stage1[b] = entry.value_ptr.*;
    }
    return .{ .stage1 = stage1, .stage2 = try stage2.toOwnedSlice(gpa) };
}

pub fn lookup(comptime T: type, t: TwoStage(T), cp: u21) T {
    const block = t.stage1[cp >> block_shift];
    return t.stage2[@as(usize, block) * block_size + (cp & (block_size - 1))];
}

/// Renders the whole of src/unicode/tables.zig.
///
/// 出力は `zig fmt` を通しても変わらない形でなければならない。変わると `zig fmt --check .` が
/// 赤になる。`zig fmt` は配列の桁をそろえて書き直すので、その規則を真似ずに、組み立てた
/// ソースを標準ライブラリの整形器に通す。
pub fn render(gpa: std.mem.Allocator, d: ucd.Data) ![]u8 {
    const raw = try renderRaw(gpa, d);
    defer gpa.free(raw);
    const source = try gpa.dupeSentinel(u8, raw, 0);
    defer gpa.free(source);
    var tree = try std.zig.Ast.parse(gpa, source, .{});
    defer tree.deinit(gpa);
    if (tree.errors.len != 0) return error.GeneratedSourceDoesNotParse;
    return tree.renderAlloc(gpa);
}

fn renderRaw(gpa: std.mem.Allocator, d: ucd.Data) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    const w = &aw.writer;

    try w.print(
        \\//! Generated Unicode tables. Do not edit by hand.
        \\//!
        \\//! 生成元: Unicode Character Database {s}
        \\//! 入力: UnicodeData.txt, DerivedCoreProperties.txt, PropList.txt, SpecialCasing.txt, CaseFolding.txt
        \\//! 生成: tools/unicode-gen。取得元と版の固定は tools/unicode-gen/ucd/SOURCE.md にある。
        \\//! 引く関数は props.zig に置く。
        \\
        \\
    , .{d.version});
    try w.print("pub const unicode_version = \"{s}\";\n\n", .{d.version});
    try w.print("pub const block_shift = {d};\n\n", .{block_shift});

    try w.writeAll("pub const flag_alphabetic: u16 = 1 << 0;\n" ++
        "pub const flag_numeric: u16 = 1 << 1;\n" ++
        "pub const flag_white_space: u16 = 1 << 2;\n" ++
        "pub const flag_uppercase: u16 = 1 << 3;\n" ++
        "pub const flag_lowercase: u16 = 1 << 4;\n\n");

    try w.writeAll("// 単純写像の表の値は、写像先から元の符号位置を引いた差である。\n\n");
    try twoStage(u16, gpa, w, "flags", d.flags);
    try twoStage(i32, gpa, w, "upper", d.upper);
    try twoStage(i32, gpa, w, "lower", d.lower);
    try twoStage(i32, gpa, w, "fold", d.fold);

    try w.writeAll("/// 十進数字の並びの先頭。各並びは10個で、値は先頭からの距離に等しい。\n");
    try w.writeAll("pub const digit_starts = [_]u21{\n");
    try codePoints(w, d.digit_starts);
    try w.writeAll("};\n\n");

    try w.writeAll("/// 結果が2文字以上になる完全写像。符号位置の昇順で、len が out の有効な長さ。\n");
    try w.writeAll("pub const FullMapping = struct { cp: u21, len: u8, out: [3]u21 };\n\n");
    try fullTable(w, "full_upper", d.full_upper);
    try fullTable(w, "full_lower", d.full_lower);
    try fullTable(w, "full_fold", d.full_fold);

    // 各表のあとに空行を置くので、末尾の余分な空行を落とす。zig fmt は末尾の空行を残さない。
    const text = std.mem.trimEnd(u8, aw.written(), "\n");
    return std.mem.concat(gpa, u8, &.{ text, "\n" });
}

fn twoStage(comptime T: type, gpa: std.mem.Allocator, w: *std.Io.Writer, name: []const u8, values: []const T) !void {
    const t = try buildTwoStage(T, gpa, values);
    defer gpa.free(t.stage1);
    defer gpa.free(t.stage2);
    try w.print("pub const {s}_stage1 = [_]u16{{\n", .{name});
    try numbers(u16, w, t.stage1);
    try w.writeAll("};\n\n");
    try w.print("pub const {s}_stage2 = [_]{s}{{\n", .{ name, @typeName(T) });
    try numbers(T, w, t.stage2);
    try w.writeAll("};\n\n");
}

const per_line = 16;

fn numbers(comptime T: type, w: *std.Io.Writer, items: []const T) !void {
    var i: usize = 0;
    while (i < items.len) : (i += per_line) {
        try w.writeAll("   ");
        for (items[i..@min(i + per_line, items.len)]) |v| try w.print(" {d},", .{v});
        try w.writeAll("\n");
    }
}

fn codePoints(w: *std.Io.Writer, items: []const u21) !void {
    var i: usize = 0;
    while (i < items.len) : (i += per_line) {
        try w.writeAll("   ");
        for (items[i..@min(i + per_line, items.len)]) |v| try w.print(" 0x{X:0>4},", .{v});
        try w.writeAll("\n");
    }
}

fn fullTable(w: *std.Io.Writer, name: []const u8, items: []const ucd.FullMapping) !void {
    try w.print("pub const {s} = [_]FullMapping{{\n", .{name});
    for (items) |m| {
        try w.print("    .{{ .cp = 0x{X:0>4}, .len = {d}, .out = .{{ 0x{X:0>4}, 0x{X:0>4}, 0x{X:0>4} }} }},\n", .{
            m.cp, m.len, m.out[0], m.out[1], m.out[2],
        });
    }
    try w.writeAll("};\n\n");
}

test "buildTwoStage returns every value and shares equal blocks" {
    const gpa = std.testing.allocator;
    const values = try gpa.alloc(i32, ucd.code_point_count);
    defer gpa.free(values);
    @memset(values, 0);
    values[0x41] = 32;
    values[0x1F600] = -7;
    values[0x10FFFF] = 5;
    const t = try buildTwoStage(i32, gpa, values);
    defer gpa.free(t.stage1);
    defer gpa.free(t.stage2);
    for (values, 0..) |v, cp| {
        try std.testing.expectEqual(v, lookup(i32, t, @intCast(cp)));
    }
    // 空でない区画は3つ、全部0の区画は1つにまとまる。
    try std.testing.expectEqual(@as(usize, 4 * block_size), t.stage2.len);
}

fn emptyData(gpa: std.mem.Allocator) !ucd.Data {
    const flags = try gpa.alloc(u16, ucd.code_point_count);
    @memset(flags, 0);
    const upper = try gpa.alloc(i32, ucd.code_point_count);
    @memset(upper, 0);
    const lower = try gpa.alloc(i32, ucd.code_point_count);
    @memset(lower, 0);
    const fold = try gpa.alloc(i32, ucd.code_point_count);
    @memset(fold, 0);
    return .{
        .version = "99.0.0",
        .flags = flags,
        .upper = upper,
        .lower = lower,
        .fold = fold,
        .digit_starts = &.{ 0x30, 0x660 },
        .full_upper = &.{.{ .cp = 0xDF, .len = 2, .out = .{ 0x53, 0x53, 0 } }},
        .full_lower = &.{},
        .full_fold = &.{},
    };
}

test "render is stable and already formatted" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var d = try emptyData(arena);
    d.flags[0x41] = ucd.flag.alphabetic | ucd.flag.uppercase;
    d.lower[0x41] = 0x20;

    const first = try render(arena, d);
    const second = try render(arena, d);
    try std.testing.expectEqualStrings(first, second);
    try std.testing.expect(std.mem.indexOf(u8, first, "Unicode Character Database 99.0.0") != null);
    try std.testing.expect(std.mem.indexOf(u8, first, ".cp = 0x00DF, .len = 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, first, "pub const digit_starts = [_]u21{\n    0x0030, 0x0660,\n};") != null);

    // 整形し直しても変わらない(`zig fmt --check` が通る)。
    const source = try arena.dupeSentinel(u8, first, 0);
    var tree = try std.zig.Ast.parse(arena, source, .{});
    try std.testing.expectEqual(@as(usize, 0), tree.errors.len);
    try std.testing.expectEqualStrings(first, try tree.renderAlloc(arena));
}

/// Reads the integers of `pub const <name> = [_]...{ ... };` from rendered source.
fn readArray(comptime T: type, arena: std.mem.Allocator, source: []const u8, name: []const u8) ![]T {
    const head = try std.fmt.allocPrint(arena, "pub const {s} = [_]", .{name});
    const start = std.mem.indexOf(u8, source, head) orelse return error.ArrayNotFound;
    const open = std.mem.indexOfScalarPos(u8, source, start, '{') orelse return error.ArrayNotFound;
    const close = std.mem.indexOfPos(u8, source, open, "};") orelse return error.ArrayNotFound;
    var out: std.ArrayList(T) = .empty;
    var it = std.mem.tokenizeAny(u8, source[open + 1 .. close], ", \n");
    while (it.next()) |tok| try out.append(arena, try std.fmt.parseInt(T, tok, 10));
    return out.items;
}

test "render names every table after its own data and agrees with the flags and the block size" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var d = try emptyData(arena);
    // 4つの表が互いに違う値を持つようにして、名前の取り違えを見つける。
    d.flags[0x41] = ucd.flag.alphabetic | ucd.flag.uppercase;
    d.flags[0x30] = ucd.flag.numeric;
    d.flags[0x20] = ucd.flag.white_space;
    d.flags[0x61] = ucd.flag.lowercase;
    d.upper[0x61] = -0x20;
    d.lower[0x41] = 0x20;
    d.fold[0x1E9E] = 0x00DF - 0x1E9E;
    d.fold[0x10FFFF] = 7;
    d.full_lower = &.{.{ .cp = 0x130, .len = 2, .out = .{ 0x69, 0x307, 0 } }};
    d.full_fold = &.{.{ .cp = 0xDF, .len = 2, .out = .{ 0x73, 0x74, 0 } }};

    const source = try render(arena, d);

    // 印の名前と値は ucd.flag と同じ。
    const flag_values = [_]struct { []const u8, u16 }{
        .{ "alphabetic", ucd.flag.alphabetic },
        .{ "numeric", ucd.flag.numeric },
        .{ "white_space", ucd.flag.white_space },
        .{ "uppercase", ucd.flag.uppercase },
        .{ "lowercase", ucd.flag.lowercase },
    };
    for (flag_values) |f| {
        const line = try std.fmt.allocPrint(arena, "pub const flag_{s}: u16 = 1 << {d};\n", .{ f[0], @ctz(f[1]) });
        try std.testing.expect(std.mem.indexOf(u8, source, line) != null);
    }
    const shift = try std.fmt.allocPrint(arena, "pub const block_shift = {d};\n", .{block_shift});
    try std.testing.expect(std.mem.indexOf(u8, source, shift) != null);

    // 出力の stage1 と stage2 から引いた値が、元の配列と同じ。
    const names = [_][]const u8{ "flags", "upper", "lower", "fold" };
    const probes = [_]u21{ 0x00, 0x20, 0x30, 0x41, 0x61, 0xDF, 0x130, 0x1E9E, 0x10FFFF };
    inline for (names, .{ d.flags, d.upper, d.lower, d.fold }) |name, values| {
        const T = @typeInfo(@TypeOf(values)).pointer.child;
        const stage1 = try readArray(u16, arena, source, name ++ "_stage1");
        const stage2 = try readArray(T, arena, source, name ++ "_stage2");
        try std.testing.expectEqual(ucd.code_point_count >> block_shift, stage1.len);
        for (probes) |cp| {
            const got = stage2[@as(usize, stage1[cp >> block_shift]) * block_size + (cp & (block_size - 1))];
            try std.testing.expectEqual(values[cp], got);
        }
    }

    // 完全写像は、表の名前ごとに、自分の入力の out の並びのまま出る。
    try std.testing.expect(std.mem.indexOf(u8, source, "pub const full_upper = [_]FullMapping{\n    .{ .cp = 0x00DF, .len = 2, .out = .{ 0x0053, 0x0053, 0x0000 } },\n};") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "pub const full_lower = [_]FullMapping{\n    .{ .cp = 0x0130, .len = 2, .out = .{ 0x0069, 0x0307, 0x0000 } },\n};") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "pub const full_fold = [_]FullMapping{\n    .{ .cp = 0x00DF, .len = 2, .out = .{ 0x0073, 0x0074, 0x0000 } },\n};") != null);
}

test {
    std.testing.refAllDecls(@This());
}
