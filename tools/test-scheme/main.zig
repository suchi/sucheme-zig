//! Runs the Scheme behaviour tests under tests/scheme/.
//!
//! Run as `zig build test-scheme`. Every `*.txt` file in tests/scheme/ is read
//! and each case in it is evaluated in-process through `sucheme.Interpreter.evalPrint`, the
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
//! A case that prints nothing says `<no output>` as its expected line.
//!
//! An error is part of the output: after what the line printed before it, the
//! text is `error: ` and the interpreter's message, as the REPL prints it.
//!
//! A case with an input and no expected output is reported, not skipped: a
//! missing line would otherwise make the case compare against nothing.
//!
//! No arguments are taken. build.zig checks that none are passed, because an
//! argument naming a narrower directory or a filter would be the one-line way
//! to make this step pass while running fewer cases. For the same reason an
//! entry of tests/scheme/ that is not a `.txt` file, a file with no case and a
//! run with no case at all are failures.

const std = @import("std");
const sucheme = @import("sucheme");

const tests_dir = "tests/scheme";

/// The expected text of a case that prints nothing, such as a definition. A
/// case needs an expected line, so an empty output has to be written down.
/// The value printer never writes this: a symbol with a space in it would be
/// written with bars. Output that is not a value, such as the text `display`
/// writes in slice 1h, can say it; when that arrives, this marker has to move
/// to a spelling no output can have.
const no_output = "<no output>";

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
    var failed: usize = 0;
    while (try it.next(io)) |entry| {
        // Anything that is not a `.txt` file is reported, not skipped: a test
        // saved as `0002.TXT`, `0002.scm` or inside a subdirectory would
        // otherwise never run while the step stays green.
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".txt")) {
            try err.print("{s}/{s}: not a `.txt` file, so its cases would never run\n", .{ tests_dir, entry.name });
            failed += 1;
            continue;
        }
        try names.append(gpa, try gpa.dupe(u8, entry.name));
    }
    // Directory order differs between hosts; sorting keeps the report stable.
    std.mem.sort([]const u8, names.items, {}, lessThan);

    var passed: usize = 0;
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
        // A file with no case is as suspect as a missing one: a comment-only
        // file, or a format change that parses everything as comments.
        if (cases.items.len == 0) {
            try err.print("{s}: no case found in this file\n", .{path});
            failed += 1;
        }
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

    try err.print("test-scheme: {d} passed, {d} failed\n", .{ passed, failed });
    try err.flush();
    const status = exitStatus(passed, failed);
    if (status != 0) std.process.exit(status);
}

/// The exit status for a run. Finding no case at all is a failure, because a
/// runner that read nothing has verified nothing.
fn exitStatus(passed: usize, failed: usize) u8 {
    if (failed != 0 or passed == 0) return 1;
    return 0;
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
                var text = try expected.toOwnedSlice(gpa);
                if (std.mem.eql(u8, text, no_output)) {
                    gpa.free(text);
                    text = "";
                }
                try out.append(gpa, .{ .line = input_line, .input = in, .expected = text });
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
/// was produced instead, so the report can show it. The caller owns the result.
fn runCase(gpa: std.mem.Allocator, c: Case) error{OutOfMemory}!?[]const u8 {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var interp: sucheme.Interpreter = undefined;
    try interp.init(gpa);
    defer interp.deinit();
    interp.evalPrint(arena.allocator(), c.input, &out.writer) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        // The writer allocates, so it can only fail for want of memory.
        error.WriteFailed => return error.OutOfMemory,
        // Printed the way the REPL prints it, after what the line wrote
        // before it failed.
        else => out.writer.print("error: {s}\n", .{interp.diagnostic()}) catch return error.OutOfMemory,
    };
    // evalPrint ends every result with a newline; the expected text has none
    // after its last line.
    const got = std.mem.trimEnd(u8, out.written(), "\n");
    if (std.mem.eql(u8, got, c.expected)) return null;
    return try gpa.dupe(u8, got);
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

test "runCase returns null when the output matches and what it got when not" {
    const gpa = std.testing.allocator;
    try std.testing.expect(try runCase(gpa, .{ .line = 1, .input = "(+ 1 2)", .expected = "3" }) == null);
    const got = (try runCase(gpa, .{ .line = 1, .input = "(+ 1 2)", .expected = "4" })).?;
    defer gpa.free(got);
    try std.testing.expectEqualStrings("3", got);
}

test "runCase reports an error as a mismatch, and does not match its own text by accident" {
    const gpa = std.testing.allocator;
    const got = (try runCase(gpa, .{ .line = 1, .input = "(foo)", .expected = "3" })).?;
    defer gpa.free(got);
    try std.testing.expectEqualStrings("error: unbound variable: foo", got);
}

test "runCase matches an error with the output that came before it" {
    const gpa = std.testing.allocator;
    try std.testing.expect(try runCase(gpa, .{
        .line = 1,
        .input = "1 (foo)",
        .expected = "1\nerror: unbound variable: foo",
    }) == null);
}

test "runCase compares the whole output, not a prefix or a trimmed form" {
    const gpa = std.testing.allocator;
    for ([_][]const u8{ "", "3 ", " 3", "3\n3" }) |expected| {
        const got = try runCase(gpa, .{ .line = 1, .input = "(+ 1 2)", .expected = expected });
        defer if (got) |g| gpa.free(g);
        try std.testing.expect(got != null);
    }
}

test "exitStatus fails on a failure and on a run that read no case" {
    try std.testing.expectEqual(0, exitStatus(7, 0));
    try std.testing.expectEqual(1, exitStatus(7, 1));
    try std.testing.expectEqual(1, exitStatus(0, 1));
    try std.testing.expectEqual(1, exitStatus(0, 0));
}

test "parse reads <no output> as an empty expectation" {
    var cases: std.ArrayList(Case) = .empty;
    try parse(std.testing.allocator, "(define x 1)\n<no output>\n\n(+ 1 2)\n3\n", &cases);
    defer {
        for (cases.items) |c| if (c.expected.len != 0) std.testing.allocator.free(c.expected);
        cases.deinit(std.testing.allocator);
    }
    try std.testing.expectEqual(2, cases.items.len);
    try std.testing.expectEqualStrings("", cases.items[0].expected);
    try std.testing.expectEqualStrings("3", cases.items[1].expected);
}

test "<no output> only stands alone: with other lines it is text" {
    var cases: std.ArrayList(Case) = .empty;
    try parse(std.testing.allocator, "1\n<no output>\n2\n", &cases);
    defer {
        for (cases.items) |c| std.testing.allocator.free(c.expected);
        cases.deinit(std.testing.allocator);
    }
    try std.testing.expectEqualStrings("<no output>\n2", cases.items[0].expected);
}

test "runCase matches an empty expectation only against no output" {
    const gpa = std.testing.allocator;
    try std.testing.expect(try runCase(gpa, .{ .line = 1, .input = "  ", .expected = "" }) == null);
    const got = (try runCase(gpa, .{ .line = 1, .input = "1", .expected = "" })).?;
    defer gpa.free(got);
    try std.testing.expectEqualStrings("1", got);
}
