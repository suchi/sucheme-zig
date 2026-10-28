//! Generates src/unicode/tables.zig from the Unicode Character Database files in
//! tools/unicode-gen/ucd/.
//!
//! 既定の動作は比較である。入力から生成した結果を、コミット済みの src/unicode/tables.zig と
//! 照らし合わせ、差があれば非ゼロで終了する。`zig build check-unicode` がこれを走らせる。
//! 書き込みは `--write` で行う(`zig build generate-unicode` が渡す)。
//! 比較を既定にするのは、tools/extract-r7rs-required と同じ理由である。引数を1つ落とした
//! 呼び出しが、検査から書き換えに変わってはならない。
//!
//! 入力のファイルは、ucd/SHA256SUMS に記録したハッシュと照合してから読む。ハッシュを
//! 照合しないと、入力を書き換えて生成物も合わせて書き換えた変更が、比較を通ってしまう。
//! ビルド時にネットワークへは出ない(docs/design/numerics-and-unicode.md)。
//!
//! 判断(引数の読み方、ハッシュの照合、比較、書き込む内容)は入出力を持たない関数
//! (`parseArgs`、`execute`)に置き、`main` はファイルを読み書きして結果を表示するだけにする。
//! 判断を単体テストで固定するためである。固定しないと、比較の既定を書き込みに変えても、比較を
//! 先頭の半分だけにしても、ハッシュの不一致を無視しても、`check-unicode` は緑のまま通る。

const std = @import("std");
const ucd = @import("ucd.zig");
const emit = @import("emit.zig");

const ucd_dir = "tools/unicode-gen/ucd";
const sums_name = "SHA256SUMS";
const out_path = "src/unicode/tables.zig";

/// The input files, in the order SHA256SUMS lists them.
const input_names = [_][]const u8{
    "UnicodeData.txt",
    "DerivedCoreProperties.txt",
    "PropList.txt",
    "SpecialCasing.txt",
    "CaseFolding.txt",
};

pub const Verdict = enum { ok, missing, mismatch };

/// Looks `name` up in a `sha256sum` listing ("<hex>  <name>" per line) and checks `data` against it.
pub fn verifySum(sums: []const u8, name: []const u8, data: []const u8) Verdict {
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &digest, .{});
    const actual = std.fmt.bytesToHex(digest, .lower);

    var found = false;
    var lines = std.mem.splitScalar(u8, sums, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        // "<64 桁の16進>  <名前>"。区切りは空白2つ(sha256sum のテキストモード)。
        if (line.len < actual.len + 3) continue;
        if (!std.mem.eql(u8, line[actual.len .. actual.len + 2], "  ")) continue;
        if (!std.mem.eql(u8, line[actual.len + 2 ..], name)) continue;
        found = true;
        if (std.mem.eql(u8, line[0..actual.len], &actual)) return .ok;
    }
    return if (found) .mismatch else .missing;
}

pub const Mode = enum { check, write };

pub const Args = union(enum) {
    mode: Mode,
    /// The first argument that is neither `--check` nor `--write`.
    unknown: []const u8,
};

/// Reads the arguments after the program name. Without `--write` the mode is a comparison.
pub fn parseArgs(args: []const []const u8) Args {
    var mode: Mode = .check;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--check")) continue;
        if (std.mem.eql(u8, arg, "--write")) {
            mode = .write;
            continue;
        }
        return .{ .unknown = arg };
    }
    return .{ .mode = mode };
}

/// The contents of the input files, in the order of `input_names`.
pub const Texts = [input_names.len][]const u8;

pub const Result = union(enum) {
    /// A comparison found the table equal to what the input generates. The payload is the Unicode version.
    matches: []const u8,
    /// A write was asked for. `source` is what the table file must contain.
    generated: struct { version: []const u8, source: []const u8 },
    /// SHA256SUMS does not list the file. The payload is the file name.
    sum_missing: []const u8,
    /// The file differs from its hash in SHA256SUMS. The payload is the file name.
    sum_mismatch: []const u8,
    /// The files do not read as the Unicode data.
    unreadable: ucd.Error,
    /// A comparison found no table.
    table_missing,
    /// A comparison found a table that is not what the input generates.
    table_differs,

    /// Whether the program exits with status 0.
    pub fn succeeded(self: Result) bool {
        return switch (self) {
            .matches, .generated => true,
            else => false,
        };
    }
};

/// Decides what a run does with the input files and the table already in the repository.
///
/// 入力はハッシュを照合してから読む。比較では、表の全体が生成結果と一致することを求める。
/// 書き込みでは、`existing` を見ない。
pub fn execute(
    gpa: std.mem.Allocator,
    mode: Mode,
    sums: []const u8,
    texts: Texts,
    existing: ?[]const u8,
) !Result {
    for (input_names, texts) |name, text| {
        switch (verifySum(sums, name, text)) {
            .ok => {},
            .missing => return .{ .sum_missing = name },
            .mismatch => return .{ .sum_mismatch = name },
        }
    }
    const data = ucd.parseAll(gpa, .{
        .unicode_data = texts[0],
        .derived_core_properties = texts[1],
        .prop_list = texts[2],
        .special_casing = texts[3],
        .case_folding = texts[4],
    }) catch |err| return .{ .unreadable = err };
    const generated = try emit.render(gpa, data);

    switch (mode) {
        .check => {
            const have = existing orelse return .table_missing;
            if (!std.mem.eql(u8, have, generated)) return .table_differs;
            return .{ .matches = data.version };
        },
        .write => return .{ .generated = .{ .version = data.version, .source = generated } },
    }
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();
    const io = init.io;
    const cwd = std.Io.Dir.cwd();

    var buf: [4096]u8 = undefined;
    var stdout = std.Io.File.Writer.initStreaming(.stdout(), io, &buf);
    const out = &stdout.interface;

    const argv = try init.minimal.args.toSlice(gpa);
    const mode = switch (parseArgs(argv[1..])) {
        .mode => |m| m,
        .unknown => |arg| {
            try out.print("unknown argument {s}\n", .{arg});
            try out.print("usage: unicode-gen [--check | --write]\n", .{});
            try out.flush();
            std.process.exit(2);
        },
    };

    var dir = cwd.openDir(io, ucd_dir, .{}) catch |err| {
        try out.print("cannot open {s}: {t}\n", .{ ucd_dir, err });
        try out.print("run this from the repository root\n", .{});
        try out.flush();
        std.process.exit(1);
    };
    defer dir.close(io);

    const sums = dir.readFileAlloc(io, sums_name, gpa, .unlimited) catch |err| {
        try out.print("cannot read {s}/{s}: {t}\n", .{ ucd_dir, sums_name, err });
        try out.flush();
        std.process.exit(1);
    };

    var texts: Texts = undefined;
    for (input_names, 0..) |name, i| {
        texts[i] = dir.readFileAlloc(io, name, gpa, .unlimited) catch |err| {
            try out.print("cannot read {s}/{s}: {t}\n", .{ ucd_dir, name, err });
            try out.flush();
            std.process.exit(1);
        };
    }

    // 書き込みでは、いまの表を読まない。読めなかった理由は、比較の失敗を表示するときに使う。
    var read_error: ?anyerror = null;
    const existing: ?[]const u8 = if (mode == .check)
        cwd.readFileAlloc(io, out_path, gpa, .unlimited) catch |err| blk: {
            read_error = err;
            break :blk null;
        }
    else
        null;

    const result = try execute(gpa, mode, sums, texts, existing);
    switch (result) {
        .sum_missing => |name| try out.print("{s}/{s} does not list {s}\n", .{ ucd_dir, sums_name, name }),
        .sum_mismatch => |name| try out.print("{s}/{s} differs from the hash in {s}\n", .{ ucd_dir, name, sums_name }),
        .unreadable => |err| try out.print("cannot read the Unicode data: {t}\n", .{err}),
        .table_missing => {
            if (read_error) |err| {
                try out.print("cannot read {s}: {t}\n", .{ out_path, err });
            } else {
                try out.print("cannot read {s}\n", .{out_path});
            }
            try out.print("run `zig build generate-unicode` and commit the result\n", .{});
        },
        .table_differs => {
            try out.print("{s} is not what {s} generates\n", .{ out_path, ucd_dir });
            try out.print("run `zig build generate-unicode` and commit the result\n", .{});
        },
        .matches => |version| try out.print("{s} matches Unicode {s}\n", .{ out_path, version }),
        .generated => |g| {
            try cwd.createDirPath(io, "src/unicode");
            var file = try cwd.createFile(io, out_path, .{});
            defer file.close(io);
            var wbuf: [4096]u8 = undefined;
            var fw = file.writer(io, &wbuf);
            try fw.interface.writeAll(g.source);
            try fw.interface.flush();
            try out.print("wrote {s} from Unicode {s}\n", .{ out_path, g.version });
        },
    }
    try out.flush();
    if (!result.succeeded()) std.process.exit(1);
}

test "verifySum accepts the matching line only" {
    const data = "abc";
    // sha256("abc")
    const hex = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad";
    const sums = "# comment\n" ++ hex ++ "  A.txt\n" ++ hex ++ "  B.txt\n";
    try std.testing.expectEqual(Verdict.ok, verifySum(sums, "A.txt", data));
    try std.testing.expectEqual(Verdict.mismatch, verifySum(sums, "A.txt", "abd"));
    try std.testing.expectEqual(Verdict.missing, verifySum(sums, "C.txt", data));
    // 名前の前方一致や、区切りの空白が1つの行は受け付けない。
    try std.testing.expectEqual(Verdict.missing, verifySum(sums, "A", data));
    try std.testing.expectEqual(Verdict.missing, verifySum(hex ++ " A.txt\n", "A.txt", data));
}

test "parseArgs: without --write the mode is a comparison" {
    try std.testing.expectEqual(Mode.check, parseArgs(&.{}).mode);
    try std.testing.expectEqual(Mode.check, parseArgs(&.{"--check"}).mode);
    try std.testing.expectEqual(Mode.write, parseArgs(&.{"--write"}).mode);
    // --check は書き込みを取り消さない。
    try std.testing.expectEqual(Mode.write, parseArgs(&.{ "--write", "--check" }).mode);
    try std.testing.expectEqualStrings("--wite", parseArgs(&.{"--wite"}).unknown);
    try std.testing.expectEqualStrings("x", parseArgs(&.{ "--check", "x", "--write" }).unknown);
}

const real_data = @import("real_data.zig");

fn realTexts() Texts {
    const in = real_data.inputs;
    return .{ in.unicode_data, in.derived_core_properties, in.prop_list, in.special_casing, in.case_folding };
}

/// The table the vendored input generates.
fn generatedTable(arena: std.mem.Allocator) ![]const u8 {
    const r = try execute(arena, .write, real_data.sums, realTexts(), null);
    return r.generated.source;
}

test "execute: a comparison accepts the table the input generates" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const table = try generatedTable(arena);

    const r = try execute(arena, .check, real_data.sums, realTexts(), table);
    try std.testing.expectEqualStrings("18.0.0", r.matches);
    try std.testing.expect(r.succeeded());
}

test "execute: a comparison rejects a table that differs anywhere" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const table = try generatedTable(arena);
    try std.testing.expect(table.len > 1000);

    // 先頭、前半の最後、後半の最初、最後の1バイトを書き換える。比較が一部だけを見ても通らない。
    const positions = [_]usize{ 0, table.len / 2 - 1, table.len / 2, table.len - 1 };
    for (positions) |at| {
        const copy = try arena.dupe(u8, table);
        copy[at] ^= 1;
        const r = try execute(arena, .check, real_data.sums, realTexts(), copy);
        errdefer std.debug.print("byte {d}\n", .{at});
        try std.testing.expect(r == .table_differs);
        try std.testing.expect(!r.succeeded());
    }
    // 短くなった表と、長くなった表。
    const shorter = try execute(arena, .check, real_data.sums, realTexts(), table[0 .. table.len - 1]);
    try std.testing.expect(shorter == .table_differs);
    const longer = try execute(arena, .check, real_data.sums, realTexts(), try std.mem.concat(arena, u8, &.{ table, "\n" }));
    try std.testing.expect(longer == .table_differs);
    const empty = try execute(arena, .check, real_data.sums, realTexts(), "");
    try std.testing.expect(empty == .table_differs);
}

test "execute: a comparison finds no table" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const r = try execute(arena_state.allocator(), .check, real_data.sums, realTexts(), null);
    try std.testing.expect(r == .table_missing);
    try std.testing.expect(!r.succeeded());
}

test "execute: a write returns the source whatever the table holds" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const table = try generatedTable(arena);

    const r = try execute(arena, .write, real_data.sums, realTexts(), "not the table");
    try std.testing.expect(r.succeeded());
    try std.testing.expectEqualStrings(table, r.generated.source);
    try std.testing.expectEqualStrings("18.0.0", r.generated.version);
}

test "execute: an input that differs from its hash stops both modes" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const table = try generatedTable(arena);

    for (input_names, 0..) |name, i| {
        var texts = realTexts();
        // 末尾の1バイトだけを変える。ハッシュは全体を覆うので、構文を壊さない変更でも止まる。
        const copy = try arena.dupe(u8, texts[i]);
        copy[copy.len - 1] ^= 1;
        texts[i] = copy;
        errdefer std.debug.print("{s}\n", .{name});
        for ([_]Mode{ .check, .write }) |mode| {
            const r = try execute(arena, mode, real_data.sums, texts, table);
            try std.testing.expectEqualStrings(name, r.sum_mismatch);
            try std.testing.expect(!r.succeeded());
        }
    }
}

test "execute: a hash that does not match the input stops, and so does a missing line" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const table = try generatedTable(arena);

    // 記録の側を変える。先頭の1桁を書き換えた行は、入力と合わなくなる。
    const bad = try arena.dupe(u8, real_data.sums);
    bad[0] = if (bad[0] == '0') '1' else '0';
    const r = try execute(arena, .check, bad, realTexts(), table);
    try std.testing.expectEqualStrings(input_names[0], r.sum_mismatch);

    // 一覧に載っていないファイル。先頭の行を落とす。
    const rest = real_data.sums[std.mem.indexOfScalar(u8, real_data.sums, '\n').? + 1 ..];
    const m = try execute(arena, .write, rest, realTexts(), null);
    try std.testing.expectEqualStrings(input_names[0], m.sum_missing);
    try std.testing.expect(!m.succeeded());
}

test "execute: an input that is not the Unicode data is reported" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // ハッシュを合わせた偽の入力。版の行が無いので、読み取りが止まる。
    var texts = realTexts();
    texts[1] = "not a UCD file\n";
    var sums: std.ArrayList(u8) = .empty;
    for (input_names, texts) |name, text| {
        var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(text, &digest, .{});
        try sums.print(arena, "{x}  {s}\n", .{ &digest, name });
    }
    const r = try execute(arena, .check, sums.items, texts, "x");
    try std.testing.expect(r == .unreadable);
    try std.testing.expect(!r.succeeded());
}

test {
    std.testing.refAllDecls(@This());
    _ = ucd;
    _ = emit;
    _ = real_data;
    _ = @import("full_range.zig");
}
