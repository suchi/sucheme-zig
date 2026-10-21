//! Runs the vendored R7RS conformance suite and reports what passed, section by section.
//!
//! `zig build test-conformance` で走らせる。tests/vendor/r7rs-tests.scm を読み、SHA-256 を
//! run.zig の定数と照らしてから、run.zig で節ごとに実行する。節ごとの数と、落ちたもの・走らせ
//! なかったものの一覧を標準出力に出す。設計は docs/plans/0020-conformance-harness-early.md
//! の「実行器の設計」にある。
//!
//! 終了コードは、段階6より前は、実行器自身の誤り(ハッシュの不一致、切り出せない、節の
//! 対が合わない、記録を読めない、節をまたぐ参照)のときだけ非0にする。テストが落ちても0
//! である。段階6の完了の時点で、落ちたものを非0にする規則に切り替える。
//!
//! 引数は取らない。より狭い入力を指す引数は、実行する範囲を減らしたまま通す手口になるからで
//! ある(tools/test-scheme と同じ理由)。

const std = @import("std");
const run = @import("run.zig");

const suite_path = run.suite_path;
const required_dir = "tests/r7rs-required";

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();
    const io = init.io;
    const cwd = std.Io.Dir.cwd();

    var obuf: [4096]u8 = undefined;
    var stdout = std.Io.File.Writer.initStreaming(.stdout(), io, &obuf);
    const out = &stdout.interface;
    var ebuf: [4096]u8 = undefined;
    var stderr = std.Io.File.Writer.initStreaming(.stderr(), io, &ebuf);
    const err = &stderr.interface;

    const argv = try init.minimal.args.toSlice(gpa);
    if (unexpectedArgument(argv)) |arg| {
        try err.print("conformance-run: takes no arguments, got {s}\n", .{arg});
        try err.flush();
        std.process.exit(2);
    }

    const text = cwd.readFileAlloc(io, suite_path, gpa, .unlimited) catch |e| {
        try err.print("cannot read {s}: {t}\nrun this from the repository root\n", .{ suite_path, e });
        try err.flush();
        std.process.exit(1);
    };
    const required = try readRequired(gpa, io, cwd, err);
    const result = run.runVendored(gpa, text, required) catch |e| {
        if (e == error.NotVendored) {
            try err.print("{s} has SHA-256 {s}, not the vendored {s}\nthe vendored file must not be modified (tests/vendor/README.md)\n", .{ suite_path, &run.hexDigest(text), run.suite_sha256 });
            try err.flush();
            std.process.exit(1);
        }
        try err.print("conformance-run: the runner cannot trust this run: {t}\n", .{e});
        try err.flush();
        std.process.exit(1);
    };
    try report(out, result);
    try out.flush();
}

/// The first argument after the program name, which this program does not take, or null.
fn unexpectedArgument(argv: []const [:0]const u8) ?[]const u8 {
    return if (argv.len > 1) argv[1] else null;
}

/// Every identifier `tests/r7rs-required/*.txt` lists.
fn readRequired(gpa: std.mem.Allocator, io: std.Io, cwd: std.Io.Dir, err: *std.Io.Writer) ![]const []const u8 {
    var ids: std.ArrayList([]const u8) = .empty;
    var dir = cwd.openDir(io, required_dir, .{ .iterate = true }) catch |e| {
        try err.print("cannot open {s}: {t}\n", .{ required_dir, e });
        try err.flush();
        std.process.exit(1);
    };
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".txt")) continue;
        const body = try dir.readFileAlloc(io, entry.name, gpa, .unlimited);
        try appendIdentifiers(gpa, body, &ids);
    }
    // 一覧が空だと、未実装の判定が黙って働かなくなる。
    if (ids.items.len == 0) {
        try err.print("{s} lists no identifier\n", .{required_dir});
        try err.flush();
        std.process.exit(1);
    }
    return ids.toOwnedSlice(gpa);
}

/// Appends the identifiers of one `tests/r7rs-required/*.txt`: one per line, skipping blank
/// lines and the `;` comments of its header.
fn appendIdentifiers(gpa: std.mem.Allocator, body: []const u8, ids: *std.ArrayList([]const u8)) !void {
    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, &std.ascii.whitespace);
        if (line.len == 0 or line[0] == ';') continue;
        try ids.append(gpa, line);
    }
}

/// Writes the counts of each section, then every failure, then the missing libraries.
fn report(out: *std.Io.Writer, r: run.SuiteResult) !void {
    try out.print("{s:<36} {s:>6} {s:>6} {s:>6} {s:>10} {s:>13} {s:>8}\n", .{ "section", "passed", "failed", "errors", "unreadable", "unimplemented", "cascaded" });
    var total: run.Counts = .{};
    for (r.sections) |s| {
        const c = s.counts;
        try out.print("{s:<36} {d:>6} {d:>6} {d:>6} {d:>10} {d:>13} {d:>8}\n", .{ s.name, c.passed, c.failed, c.errored, c.unreadable, c.unimplemented, c.cascaded });
        total.passed += c.passed;
        total.failed += c.failed;
        total.errored += c.errored;
        total.unreadable += c.unreadable;
        total.unimplemented += c.unimplemented;
        total.cascaded += c.cascaded;
    }
    try out.print("{s:<36} {d:>6} {d:>6} {d:>6} {d:>10} {d:>13} {d:>8}\n", .{ "total", total.passed, total.failed, total.errored, total.unreadable, total.unimplemented, total.cascaded });
    try out.print("\npassed and failed count tests; the other columns count top-level forms that were not run or that raised,\nexcept that cascaded also counts tests that raised an unbound error in a section with a broken form.\n", .{});

    if (r.failures.len > 0) try out.print("\n", .{});
    for (r.failures) |f| {
        try out.print("{s}:{d}: [{t}] {s}: {s}\n", .{ "tests/vendor/r7rs-tests.scm", f.line, f.kind, f.section, f.detail });
    }
    if (r.missing_libraries.len > 0) {
        try out.print("\nlibraries the suite imports that cannot be resolved:", .{});
        for (r.missing_libraries) |l| try out.print(" {s}", .{l});
        try out.print("\n", .{});
    }
}

test {
    std.testing.refAllDecls(@This());
}

test "any argument is refused, and none is accepted" {
    try std.testing.expectEqual(@as(?[]const u8, null), unexpectedArgument(&.{"conformance-run"}));
    try std.testing.expectEqualStrings("--filter", unexpectedArgument(&.{ "conformance-run", "--filter" }).?);
}

test "the required lists are read one identifier a line, without comments or blank lines" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var ids: std.ArrayList([]const u8) = .empty;
    try appendIdentifiers(arena.allocator(), "; header\r\n; more\n\ncar\r\n  call/cc \n", &ids);
    try std.testing.expectEqual(@as(usize, 2), ids.items.len);
    try std.testing.expectEqualStrings("car", ids.items[0]);
    try std.testing.expectEqualStrings("call/cc", ids.items[1]);
}
