//! Runs the Scheme behaviour tests under tests/scheme/.
//!
//! Run as `zig build test-scheme`. Every `*.txt` file in tests/scheme/ is read
//! and each case in it is evaluated in-process through `sucheme.evalPrint`, the
//! same entry the REPL uses, so a case exercises the reader, the evaluator and
//! the printer together.
//!
//! The file format:
//!
//! - A line that is `#` alone or starts with `# ` is a comment. A bare leading
//!   `#` is not enough, because `#t`, `#(1 2)` and `#\a` are data.
//! - A blank line ends a case.
//! - The first other line of a case is the input. Every line after it, up to
//!   the blank line, is the expected output, joined with newlines.
//!
//! A case with an input and no expected output is reported, not skipped: a
//! missing line would otherwise make the case compare against nothing.
//!
//! No arguments are taken. build.zig checks that none are passed, because an
//! argument naming a narrower directory or a filter would be the one-line way
//! to make this step pass while running fewer cases. Finding no case at all is
//! a failure for the same reason.

const std = @import("std");
const sucheme = @import("sucheme");

const tests_dir = "tests/scheme";

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();
    const io = init.io;
    const cwd = std.Io.Dir.cwd();

    var buf: [4096]u8 = undefined;
    // Streaming, for the reason src/main.zig gives: a positional writer would
    // overwrite the head of an appended log.
    var stderr = std.Io.File.Writer.initStreaming(.stderr(), io, &buf);
    const err = &stderr.interface;

    const argv = try init.minimal.args.toSlice(gpa);
    if (argv.len > 1) {
        try err.print("test-scheme: takes no arguments, got {s}\n", .{argv[1]});
        try err.flush();
        std.process.exit(2);
    }

    var names: std.ArrayList([]const u8) = .empty;
    var dir = cwd.openDir(io, tests_dir, .{ .iterate = true }) catch |e| {
        try err.print("test-scheme: cannot open {s} ({t})\n", .{ tests_dir, e });
        try err.flush();
        std.process.exit(1);
    };
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".txt")) continue;
        try names.append(gpa, try gpa.dupe(u8, entry.name));
    }
    // Directory order differs between hosts; sorting keeps the report stable.
    std.mem.sort([]const u8, names.items, {}, lessThan);

    var passed: usize = 0;
    var failed: usize = 0;
    for (names.items) |name| {
        const path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ tests_dir, name });
        const body = cwd.readFileAlloc(io, path, gpa, .unlimited) catch |e| {
            try err.print("{s}: cannot be read ({t})\n", .{ path, e });
            failed += 1;
            continue;
        };
        var cases: std.ArrayList(Case) = .empty;
        parse(gpa, body, &cases) catch |e| switch (e) {
            error.MissingExpected => {
                try err.print("{s}: a case has an input and no expected output\n", .{path});
                failed += 1;
                continue;
            },
            error.OutOfMemory => return e,
        };
        for (cases.items) |c| {
            if (try runCase(gpa, c)) |got| {
                try err.print(
                    "{s}:{d}: {s}\n  expected: {s}\n  got:      {s}\n",
                    .{ path, c.line, c.input, c.expected, got },
                );
                failed += 1;
            } else passed += 1;
        }
    }

    if (passed + failed == 0) {
        try err.print("test-scheme: no case found under {s}\n", .{tests_dir});
        try err.flush();
        std.process.exit(1);
    }
    try err.print("test-scheme: {d} passed, {d} failed\n", .{ passed, failed });
    try err.flush();
    if (failed != 0) std.process.exit(1);
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// One input and the output it should produce.
const Case = struct {
    /// The 1-based line of the input, for the report.
    line: usize,
    input: []const u8,
    /// The expected lines joined with `\n`, without a trailing newline.
    expected: []const u8,
};

/// Splits a test file into its cases. See the file doc comment for the format.
fn parse(gpa: std.mem.Allocator, body: []const u8, out: *std.ArrayList(Case)) error{ OutOfMemory, MissingExpected }!void {
    var input: ?[]const u8 = null;
    var input_line: usize = 0;
    var expected: std.ArrayList(u8) = .empty;
    var expected_lines: usize = 0;

    var lines = std.mem.splitScalar(u8, body, '\n');
    var lineno: usize = 0;
    while (true) {
        const next = lines.next();
        lineno += 1;
        // A CRLF checkout must read the same as an LF one.
        const line = if (next) |l| std.mem.trimEnd(u8, l, "\r") else "";
        if (next != null and isComment(line)) continue;
        if (line.len == 0) {
            if (input) |in| {
                if (expected_lines == 0) return error.MissingExpected;
                try out.append(gpa, .{
                    .line = input_line,
                    .input = in,
                    .expected = try expected.toOwnedSlice(gpa),
                });
                input = null;
                expected_lines = 0;
            }
            if (next == null) return;
            continue;
        }
        if (input == null) {
            input = line;
            input_line = lineno;
            continue;
        }
        if (expected_lines != 0) try expected.append(gpa, '\n');
        try expected.appendSlice(gpa, line);
        expected_lines += 1;
    }
}

fn isComment(line: []const u8) bool {
    return std.mem.eql(u8, line, "#") or std.mem.startsWith(u8, line, "# ");
}

/// Evaluates one case. Returns null when the output matches, and otherwise what
/// was produced instead, so the report can show it.
fn runCase(gpa: std.mem.Allocator, c: Case) error{OutOfMemory}!?[]const u8 {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var out: std.Io.Writer.Allocating = .init(gpa);
    sucheme.evalPrint(arena.allocator(), c.input, &out.writer) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return try std.fmt.allocPrint(gpa, "error.{t}", .{e}),
    };
    // evalPrint ends every result with a newline; the expected text has none
    // after its last line.
    const got = std.mem.trimEnd(u8, out.written(), "\n");
    if (std.mem.eql(u8, got, c.expected)) return null;
    return got;
}

test "parse reads an input and its expected line" {
    var cases: std.ArrayList(Case) = .empty;
    try parse(std.testing.allocator, "# comment\n\n(+ 1 2)\n3\n", &cases);
    defer {
        for (cases.items) |c| std.testing.allocator.free(c.expected);
        cases.deinit(std.testing.allocator);
    }
    try std.testing.expectEqual(1, cases.items.len);
    try std.testing.expectEqualStrings("(+ 1 2)", cases.items[0].input);
    try std.testing.expectEqualStrings("3", cases.items[0].expected);
    try std.testing.expectEqual(3, cases.items[0].line);
}

test "parse separates cases on a blank line and keeps the last without one" {
    var cases: std.ArrayList(Case) = .empty;
    try parse(std.testing.allocator, "1\n1\n\n2\n2", &cases);
    defer {
        for (cases.items) |c| std.testing.allocator.free(c.expected);
        cases.deinit(std.testing.allocator);
    }
    try std.testing.expectEqual(2, cases.items.len);
    try std.testing.expectEqualStrings("2", cases.items[1].input);
    try std.testing.expectEqual(4, cases.items[1].line);
}

test "parse joins several expected lines" {
    var cases: std.ArrayList(Case) = .empty;
    try parse(std.testing.allocator, "1 2\n1\n2\n", &cases);
    defer {
        for (cases.items) |c| std.testing.allocator.free(c.expected);
        cases.deinit(std.testing.allocator);
    }
    try std.testing.expectEqualStrings("1\n2", cases.items[0].expected);
}

test "parse reads a CRLF file the same as an LF one" {
    var cases: std.ArrayList(Case) = .empty;
    try parse(std.testing.allocator, "# c\r\n\r\n(+ 1 2)\r\n3\r\n", &cases);
    defer {
        for (cases.items) |c| std.testing.allocator.free(c.expected);
        cases.deinit(std.testing.allocator);
    }
    try std.testing.expectEqual(1, cases.items.len);
    try std.testing.expectEqualStrings("(+ 1 2)", cases.items[0].input);
    try std.testing.expectEqualStrings("3", cases.items[0].expected);
}

test "parse rejects an input with no expected output" {
    var cases: std.ArrayList(Case) = .empty;
    defer cases.deinit(std.testing.allocator);
    try std.testing.expectError(error.MissingExpected, parse(std.testing.allocator, "(+ 1 2)\n\n", &cases));
    try std.testing.expectError(error.MissingExpected, parse(std.testing.allocator, "(+ 1 2)", &cases));
}

test "parse reads a line starting with a datum's # as part of a case" {
    var cases: std.ArrayList(Case) = .empty;
    try parse(std.testing.allocator, "#\n#t\n#t\n", &cases);
    defer {
        for (cases.items) |c| std.testing.allocator.free(c.expected);
        cases.deinit(std.testing.allocator);
    }
    try std.testing.expectEqual(1, cases.items.len);
    try std.testing.expectEqualStrings("#t", cases.items[0].input);
    try std.testing.expectEqualStrings("#t", cases.items[0].expected);
}

test "parse finds no case in a file of comments" {
    var cases: std.ArrayList(Case) = .empty;
    defer cases.deinit(std.testing.allocator);
    try parse(std.testing.allocator, "# only\n# comments\n", &cases);
    try std.testing.expectEqual(0, cases.items.len);
}
