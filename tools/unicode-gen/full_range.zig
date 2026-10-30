//! Checks the lookup functions in src/unicode/props.zig against the parsed UCD at every code point.
//!
//! 期待値は、生成器が UCD から読んだ配列(`ucd.Data`)から、表を経由せずに求める。表の符号化と
//! 引く関数の誤り(区画の指し方、差の符号、二分探索の端)は、全符号位置の比較で見つかる。
//! 表そのものが入力から導かれたことは、`zig build check-unicode` が見る。

const std = @import("std");
const ucd = @import("ucd.zig");
const real_data = @import("real_data.zig");
const props = @import("unicode_props");

fn delta(c: u21, d: i32) u21 {
    return @intCast(@as(i32, c) + d);
}

test "every code point agrees with the parsed UCD: properties and simple mappings" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const d = try real_data.load(arena_state.allocator());

    const all = [_]struct { props.Property, u16 }{
        .{ .alphabetic, ucd.flag.alphabetic },
        .{ .numeric, ucd.flag.numeric },
        .{ .white_space, ucd.flag.white_space },
        .{ .uppercase, ucd.flag.uppercase },
        .{ .lowercase, ucd.flag.lowercase },
    };
    for (0..ucd.code_point_count) |i| {
        const c: u21 = @intCast(i);
        errdefer std.debug.print("at U+{X:0>4}\n", .{c});
        for (all) |p| {
            try std.testing.expectEqual(d.flags[c] & p[1] != 0, props.has(c, p[0]));
        }
        try std.testing.expectEqual(delta(c, d.upper[c]), props.simpleUpcase(c));
        try std.testing.expectEqual(delta(c, d.lower[c]), props.simpleDowncase(c));
        try std.testing.expectEqual(delta(c, d.fold[c]), props.simpleFoldcase(c));
    }
}

test "every code point agrees with the parsed UCD: full mappings" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const d = try real_data.load(arena_state.allocator());

    const Case = struct {
        table: []const ucd.FullMapping,
        simple: []const i32,
        f: *const fn (u21, *[3]u21) u2,
    };
    const cases = [_]Case{
        .{ .table = d.full_upper, .simple = d.upper, .f = props.fullUpcase },
        .{ .table = d.full_lower, .simple = d.lower, .f = props.fullDowncase },
        .{ .table = d.full_fold, .simple = d.fold, .f = props.fullFoldcase },
    };
    for (cases) |case| {
        // 完全写像の表は昇順なので、符号位置を進めながら先頭から対応づける。
        var next: usize = 0;
        for (0..ucd.code_point_count) |i| {
            const c: u21 = @intCast(i);
            errdefer std.debug.print("at U+{X:0>4}\n", .{c});
            var out: [3]u21 = @splat(0);
            const n = case.f(c, &out);
            if (next < case.table.len and case.table[next].cp == c) {
                const m = case.table[next];
                next += 1;
                try std.testing.expectEqual(m.len, n);
                try std.testing.expectEqualSlices(u21, m.out[0..m.len], out[0..n]);
            } else {
                try std.testing.expectEqual(@as(u2, 1), n);
                try std.testing.expectEqual(delta(c, case.simple[c]), out[0]);
            }
        }
        try std.testing.expectEqual(case.table.len, next);
    }
}

test "every code point agrees with the parsed UCD: digit values" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const d = try real_data.load(arena_state.allocator());

    // 並びの10個ずつに値を割り当てて、符号位置ごとの期待値の配列にする。
    const want = try arena_state.allocator().alloc(?u4, ucd.code_point_count);
    @memset(want, null);
    for (d.digit_starts) |start| {
        for (0..10) |k| want[start + k] = @intCast(k);
    }
    for (want, 0..) |w, i| {
        const c: u21 = @intCast(i);
        errdefer std.debug.print("at U+{X:0>4}\n", .{c});
        try std.testing.expectEqual(w, props.digitValue(c));
    }
}

/// 期待値の元になる一般カテゴリを、生成器の読み方(ucd.zig)を使わずに UnicodeData.txt から取り直す。
/// 範囲の行(First と Last)は、間の符号位置の全部にカテゴリを広げる。
fn readCategories(arena: std.mem.Allocator) ![]const [2]u8 {
    const gc = try arena.alloc([2]u8, ucd.code_point_count);
    @memset(gc, .{ 'C', 'n' }); // 載っていない符号位置は Cn(未割り当て)
    var first: ?usize = null;
    var lines = std.mem.splitScalar(u8, real_data.inputs.unicode_data, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var it = std.mem.splitScalar(u8, line, ';');
        const cp = try std.fmt.parseInt(usize, it.next().?, 16);
        const name = it.next().?;
        const cat = it.next().?;
        gc[cp] = .{ cat[0], cat[1] };
        if (std.mem.endsWith(u8, name, ", First>")) {
            first = cp;
        } else if (std.mem.endsWith(u8, name, ", Last>")) {
            for (first.?..cp) |i| gc[i] = .{ cat[0], cat[1] };
            first = null;
        }
    }
    return gc;
}

test "every code point agrees with the general category: identifier bits (R7RS 7.1.1)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const gc = try readCategories(arena_state.allocator());

    // <subsequent> に入る一般カテゴリ。最初の文字は、このうち Nd, Mc, Me を除く。
    const allowed = "Lu Ll Lt Lm Lo Mn Mc Me Nd Nl No Pd Pc Po Sc Sm Sk So Co";
    var allowed_count: usize = 0;
    for (0..ucd.code_point_count) |i| {
        const c: u21 = @intCast(i);
        errdefer std.debug.print("at U+{X:0>4}\n", .{c});
        var subsequent = std.mem.indexOf(u8, allowed, &gc[i]) != null;
        var initial = subsequent and !std.mem.eql(u8, &gc[i], "Nd") and !std.mem.eql(u8, &gc[i], "Mc") and
            !std.mem.eql(u8, &gc[i], "Me");
        if (c == 0x200C or c == 0x200D) {
            subsequent = true;
            initial = true;
        }
        if (c < 0x80) {
            subsequent = false;
            initial = false;
        }
        if (subsequent) allowed_count += 1;
        try std.testing.expectEqual(initial, props.isIdentifierInitial(c));
        try std.testing.expectEqual(subsequent, props.isIdentifierSubsequent(c));
    }
    // 期待値の計算が空振りしていない(全部 false の比較で緑にならない)。
    try std.testing.expect(allowed_count > 100_000);
}

test "code points above U+10FFFF have no property and no mapping" {
    try std.testing.expect(!props.isIdentifierInitial(0x110000));
    try std.testing.expect(!props.isIdentifierSubsequent(0x110000));
    try std.testing.expect(!props.isIdentifierInitial(0x1FFFFF));
    try std.testing.expect(!props.isIdentifierSubsequent(0x1FFFFF));
    const samples = [_]u21{ 0x110000, 0x110001, 0x1FFFFF, 0x1FFF80, 0x180000 };
    for (samples) |c| {
        for (std.enums.values(props.Property)) |p| try std.testing.expect(!props.has(c, p));
        try std.testing.expectEqual(c, props.simpleUpcase(c));
        try std.testing.expectEqual(c, props.simpleDowncase(c));
        try std.testing.expectEqual(c, props.simpleFoldcase(c));
        try std.testing.expectEqual(@as(?u4, null), props.digitValue(c));
        var out: [3]u21 = @splat(0);
        try std.testing.expectEqual(@as(u2, 1), props.fullUpcase(c, &out));
        try std.testing.expectEqual(c, out[0]);
    }
}

test {
    std.testing.refAllDecls(@This());
}
