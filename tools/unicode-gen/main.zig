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

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();
    const io = init.io;
    const cwd = std.Io.Dir.cwd();

    var buf: [4096]u8 = undefined;
    var stdout = std.Io.File.Writer.initStreaming(.stdout(), io, &buf);
    const out = &stdout.interface;

    const argv = try init.minimal.args.toSlice(gpa);
    var check_only = true;
    for (argv[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--check")) continue;
        if (std.mem.eql(u8, arg, "--write")) {
            check_only = false;
            continue;
        }
        try out.print("unknown argument {s}\n", .{arg});
        try out.print("usage: unicode-gen [--check | --write]\n", .{});
        try out.flush();
        std.process.exit(2);
    }

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

    var texts: [input_names.len][]const u8 = undefined;
    for (input_names, 0..) |name, i| {
        texts[i] = dir.readFileAlloc(io, name, gpa, .unlimited) catch |err| {
            try out.print("cannot read {s}/{s}: {t}\n", .{ ucd_dir, name, err });
            try out.flush();
            std.process.exit(1);
        };
        switch (verifySum(sums, name, texts[i])) {
            .ok => {},
            .missing => {
                try out.print("{s}/{s} does not list {s}\n", .{ ucd_dir, sums_name, name });
                try out.flush();
                std.process.exit(1);
            },
            .mismatch => {
                try out.print("{s}/{s} differs from the hash in {s}\n", .{ ucd_dir, name, sums_name });
                try out.flush();
                std.process.exit(1);
            },
        }
    }

    const data = ucd.parseAll(gpa, .{
        .unicode_data = texts[0],
        .derived_core_properties = texts[1],
        .prop_list = texts[2],
        .special_casing = texts[3],
        .case_folding = texts[4],
    }) catch |err| {
        try out.print("cannot read the Unicode data: {t}\n", .{err});
        try out.flush();
        std.process.exit(1);
    };
    const generated = try emit.render(gpa, data);

    if (check_only) {
        const existing = cwd.readFileAlloc(io, out_path, gpa, .unlimited) catch |err| {
            try out.print("cannot read {s}: {t}\n", .{ out_path, err });
            try out.print("run `zig build generate-unicode` and commit the result\n", .{});
            try out.flush();
            std.process.exit(1);
        };
        if (!std.mem.eql(u8, existing, generated)) {
            try out.print("{s} is not what {s} generates\n", .{ out_path, ucd_dir });
            try out.print("run `zig build generate-unicode` and commit the result\n", .{});
            try out.flush();
            std.process.exit(1);
        }
        try out.print("{s} matches Unicode {s}\n", .{ out_path, data.version });
    } else {
        try cwd.createDirPath(io, "src/unicode");
        var file = try cwd.createFile(io, out_path, .{});
        defer file.close(io);
        var wbuf: [4096]u8 = undefined;
        var fw = file.writer(io, &wbuf);
        try fw.interface.writeAll(generated);
        try fw.interface.flush();
        try out.print("wrote {s} from Unicode {s}\n", .{ out_path, data.version });
    }
    try out.flush();
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

test {
    std.testing.refAllDecls(@This());
    _ = ucd;
    _ = emit;
}
