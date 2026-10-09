//! Native entry point.
//!
//! This doc comment is the contract for the command line and the exit status;
//! AGENTS.md and the stage plan reference it rather than restating it.
//!
//! | Arguments | Behaviour | Exit |
//! | --- | --- | --- |
//! | `--version` | prints name and version to stdout | 0 |
//! | `--help`, `-h` | prints usage to stdout | 0 |
//! | an unknown option, two or more characters long and starting with `-` | names it on stderr | 64 |
//! | none | runs the REPL on stdin until it ends | 0 |
//! | `-` on its own | treated as a name, not an option | 69 |
//! | anything else | says running a file is not implemented | 69 |
//!
//! The first argument that settles the request wins, so `--version --bogus`
//! prints the version while `--bogus --version` names the unknown option. An
//! unknown option settles the request too. Later arguments are not inspected.
//!
//! Diagnostics go to stderr and a request this stage cannot serve exits
//! non-zero, so `sucheme prog.scm && echo ok` does not print ok while the
//! program never ran.
//!
//! The REPL writes a `> ` prompt and each result to stdout, and an error to
//! stderr as `error: ` and a message such as `unbound variable: foo`; an error ends that line's evaluation and
//! not the REPL. A line holds whole data: one that ends inside a list is an
//! error, until continuation lines arrive (ADR-0014). The status stays 0
//! after an error, because the REPL went on to read the rest of its input.

const std = @import("std");
const sucheme = @import("sucheme");

/// What the command line asked for.
pub const Request = union(enum) {
    version,
    help,
    repl,
    /// A valid request this stage cannot serve yet.
    not_implemented,
    /// An option this program does not know. Carried so the diagnostic can
    /// name it: "not implemented" and "you typed it wrong" are different
    /// failures, and a single state could not tell them apart.
    unknown_option: []const u8,
};

/// Entry layer. What it allocates is not subject to the accounting invariant in
/// docs/design/architecture.md: the arena holds the argument vector and the
/// output buffer, both needed only to start up and shut down. No Scheme value
/// is allocated here. The REPL gives `sucheme` a per-line arena for what one
/// line needs and an `Interpreter`, which keeps its own arena for the symbols
/// and definitions that outlive a line, until the heap arrives in slice 1g.
pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    var out_buf: [512]u8 = undefined;
    var err_buf: [512]u8 = undefined;
    // Streaming, not the default positional mode: positional starts at
    // offset 0 and would overwrite the head of `sucheme --version >> log`.
    var stdout = std.Io.File.Writer.initStreaming(.stdout(), io, &out_buf);
    var stderr = std.Io.File.Writer.initStreaming(.stderr(), io, &err_buf);
    const out = &stdout.interface;
    const err = &stderr.interface;

    // Diagnostics go to stderr and the status is non-zero: `sucheme prog.scm &&
    // echo ok` must not print ok while the program never ran.
    // `args` can be empty. POSIX allows execve with argc = 0, and `args[1..]`
    // is a bounds panic in that case rather than the exit the contract above
    // promises for "none".
    const rest = if (args.len > 1) args[1..] else &[_][]const u8{};
    switch (classify(rest)) {
        .version => {
            try out.print("{s} {s}\n", .{ sucheme.name, sucheme.version });
            try out.flush();
        },
        .help => {
            try out.print(
                "{s} {s}\n\nUsage: {s} [--version] [--help|-h]\n\n" ++
                    "With no argument, reads expressions from stdin and prints their values.\n" ++
                    "Integers, global variables, define and + only for now; see docs/roadmap.md.\n",
                .{ sucheme.name, sucheme.version, sucheme.name },
            );
            try out.flush();
        },
        .repl => {
            var in_buf: [max_line]u8 = undefined;
            var stdin = std.Io.File.Reader.initStreaming(.stdin(), io, &in_buf);
            try repl(init.gpa, &stdin.interface, out, err);
        },
        .not_implemented => {
            try err.print(
                "{s}: running a file is not implemented yet.\n" ++
                    "Run with --help for the options available now.\n",
                .{sucheme.name},
            );
            try err.flush();
            std.process.exit(exit_not_implemented);
        },
        .unknown_option => |opt| {
            try err.print("{s}: unknown option {s}\n", .{ sucheme.name, opt });
            try err.print("Run with --help for the options available now.\n", .{});
            try err.flush();
            std.process.exit(exit_usage);
        },
    }
}

/// Exit status for a request this stage cannot serve.
pub const exit_not_implemented: u8 = 69;

/// Exit status for a command line this program cannot parse. 64 is EX_USAGE in
/// sysexits.h, the closest thing to a convention here.
pub const exit_usage: u8 = 64;

/// Classifies the arguments after the program name.
pub fn classify(args: []const []const u8) Request {
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--version")) return .version;
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) return .help;
        // A leading dash with no match is a typo, not a file name -- except
        // for `-` on its own, which by convention names standard input. It
        // falls through to the name side, where stage 1 will give it a meaning.
        if (arg.len > 1 and arg[0] == '-') return .{ .unknown_option = arg };
    }
    return if (args.len == 0) .repl else .not_implemented;
}

/// The size of the REPL's line buffer, newline included. A line that does not
/// fit is reported and skipped.
pub const max_line = 64 * 1024;

/// Reads lines from `in` until it ends, and evaluates and prints each.
///
/// Every line gets a fresh arena, so what one line allocates is gone before the
/// next is read.
pub fn repl(gpa: std.mem.Allocator, in: *std.Io.Reader, out: *std.Io.Writer, err: *std.Io.Writer) !void {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var interp: sucheme.Interpreter = undefined;
    interp.init(gpa);
    defer interp.deinit();
    while (true) {
        try out.writeAll("> ");
        try out.flush();
        const line = in.takeDelimiter('\n') catch |e| switch (e) {
            error.StreamTooLong => {
                try err.print("error: the line does not fit in {d} bytes, newline included\n", .{max_line});
                try err.flush();
                _ = in.discardDelimiterInclusive('\n') catch |d| switch (d) {
                    error.EndOfStream => break,
                    error.ReadFailed => return d,
                };
                continue;
            },
            error.ReadFailed => return e,
        } orelse break;
        _ = arena.reset(.retain_capacity);
        interp.evalPrint(arena.allocator(), line, out) catch |e| switch (e) {
            error.WriteFailed => return e,
            else => {
                // Results written before the error go out first, so the two
                // streams stay in order on a terminal.
                try out.flush();
                try err.print("error: {s}\n", .{interp.diagnostic()});
                try err.flush();
            },
        };
    }
    // End the prompt's line, so the shell's prompt does not follow it.
    try out.writeAll("\n");
    try out.flush();
}

test "classify recognises --version" {
    try std.testing.expect(classify(&.{"--version"}) == .version);
}

test "classify recognises --help and -h" {
    try std.testing.expect(classify(&.{"--help"}) == .help);
    try std.testing.expect(classify(&.{"-h"}) == .help);
}

test "classify runs the REPL with no argument and nothing yet for a name" {
    try std.testing.expect(classify(&.{}) == .repl);
    try std.testing.expect(classify(&.{"foo.scm"}) == .not_implemented);
}

test "classify treats a bare dash as a name, not an unknown option" {
    try std.testing.expect(classify(&.{"-"}) == .not_implemented);
    // One character more and it is an option again.
    try std.testing.expect(classify(&.{"-x"}) == .unknown_option);
}

test "classify distinguishes a mistyped option from a file name" {
    const r = classify(&.{"--verison"});
    try std.testing.expect(r == .unknown_option);
    try std.testing.expectEqualStrings("--verison", r.unknown_option);
}

test "classify prefers a recognised option over a later unknown one" {
    try std.testing.expect(classify(&.{ "--version", "--bogus" }) == .version);
}

/// Runs the REPL over `input` and returns what it wrote to stdout and stderr.
fn replOver(input: []const u8, out_buf: []u8, err_buf: []u8) !struct { out: []const u8, err: []const u8 } {
    var in: std.Io.Reader = .fixed(input);
    var out: std.Io.Writer = .fixed(out_buf);
    var err: std.Io.Writer = .fixed(err_buf);
    try repl(std.testing.allocator, &in, &out, &err);
    return .{ .out = out.buffered(), .err = err.buffered() };
}

test "repl prints each line's results after a prompt" {
    var ob: [256]u8 = undefined;
    var eb: [256]u8 = undefined;
    const r = try replOver("(+ 1 2)\n1 2\n", &ob, &eb);
    try std.testing.expectEqualStrings("> 3\n> 1\n2\n> \n", r.out);
    try std.testing.expectEqualStrings("", r.err);
}

test "repl reads a last line with no newline" {
    var ob: [256]u8 = undefined;
    var eb: [256]u8 = undefined;
    const r = try replOver("(+ 1 2)", &ob, &eb);
    try std.testing.expectEqualStrings("> 3\n> \n", r.out);
}

test "repl reports an error and goes on to the next line" {
    var ob: [256]u8 = undefined;
    var eb: [256]u8 = undefined;
    const r = try replOver("(foo)\n(+ 1\n42\n", &ob, &eb);
    try std.testing.expectEqualStrings("> > > 42\n> \n", r.out);
    try std.testing.expectEqualStrings("error: unbound variable: foo\nerror: unexpected end of input\n", r.err);
}

test "repl skips a line longer than it reads and goes on" {
    var ob: [256]u8 = undefined;
    var eb: [256]u8 = undefined;
    const long = try std.testing.allocator.alloc(u8, max_line + 1);
    defer std.testing.allocator.free(long);
    @memset(long, '1');
    const input = try std.mem.concat(std.testing.allocator, u8, &.{ long, "\n7\n" });
    defer std.testing.allocator.free(input);
    // A fixed reader's buffer is its whole input, so the limit is the stdin
    // buffer's, not the reader's. Give the reader a buffer of max_line.
    var in_buf: [max_line]u8 = undefined;
    var src: std.Io.Reader = .fixed(input);
    var in = src.limited(.unlimited, &in_buf);
    var out: std.Io.Writer = .fixed(&ob);
    var err: std.Io.Writer = .fixed(&eb);
    try repl(std.testing.allocator, &in.interface, &out, &err);
    try std.testing.expectEqualStrings("> > 7\n> \n", out.buffered());
    try std.testing.expectEqualStrings("error: the line does not fit in 65536 bytes, newline included\n", err.buffered());
}

test "repl reads the longest line that fits, newline included" {
    var ob: [256]u8 = undefined;
    var eb: [256]u8 = undefined;
    const fits = try std.testing.allocator.alloc(u8, max_line);
    defer std.testing.allocator.free(fits);
    @memset(fits, ' ');
    fits[max_line - 2] = '5';
    fits[max_line - 1] = '\n';
    var in_buf: [max_line]u8 = undefined;
    var src: std.Io.Reader = .fixed(fits);
    var in = src.limited(.unlimited, &in_buf);
    var out: std.Io.Writer = .fixed(&ob);
    var err: std.Io.Writer = .fixed(&eb);
    try repl(std.testing.allocator, &in.interface, &out, &err);
    try std.testing.expectEqualStrings("> 5\n> \n", out.buffered());
    try std.testing.expectEqualStrings("", err.buffered());
}

test "repl keeps a definition for the lines after it" {
    var ob: [256]u8 = undefined;
    var eb: [256]u8 = undefined;
    const r = try replOver("(define x 40)\n(+ x 2)\n(+ y 1)\n(define y 1)\n(+ x y)\n", &ob, &eb);
    try std.testing.expectEqualStrings("> > 42\n> > > 41\n> \n", r.out);
    try std.testing.expectEqualStrings("error: unbound variable: y\n", r.err);
}
