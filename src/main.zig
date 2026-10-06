//! Native entry point.
//!
//! Stage 0 answers `--version` and `--help` and otherwise explains that the
//! REPL arrives in stage 1.

const std = @import("std");
const sucheme = @import("sucheme");

/// What the command line asked for.
pub const Request = union(enum) {
    version,
    help,
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
/// is allocated here.
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
    switch (classify(args[1..])) {
        .version => {
            try out.print("{s} {s}\n", .{ sucheme.name, sucheme.version });
            try out.flush();
        },
        .help => {
            try out.print(
                "{s} {s}\n\nUsage: {s} [--version] [--help]\n\n" ++
                    "The REPL arrives in stage 1; see docs/roadmap.md.\n",
                .{ sucheme.name, sucheme.version, sucheme.name },
            );
            try out.flush();
        },
        .not_implemented => {
            try err.print(
                "{s}: the REPL is not implemented yet (stage 1).\n" ++
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
        // A leading dash with no match is a typo, not a file name.
        if (arg.len > 1 and arg[0] == '-') return .{ .unknown_option = arg };
    }
    return .not_implemented;
}

test "classify recognises --version" {
    try std.testing.expect(classify(&.{"--version"}) == .version);
}

test "classify recognises --help and -h" {
    try std.testing.expect(classify(&.{"--help"}) == .help);
    try std.testing.expect(classify(&.{"-h"}) == .help);
}

test "classify falls back to not_implemented" {
    try std.testing.expect(classify(&.{}) == .not_implemented);
    try std.testing.expect(classify(&.{"foo.scm"}) == .not_implemented);
}

test "classify distinguishes a mistyped option from a file name" {
    const r = classify(&.{"--verison"});
    try std.testing.expect(r == .unknown_option);
    try std.testing.expectEqualStrings("--verison", r.unknown_option);
}

test "classify prefers a recognised option over a later unknown one" {
    try std.testing.expect(classify(&.{ "--version", "--bogus" }) == .version);
}
