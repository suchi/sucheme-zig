//! Native entry point.
//!
//! Stage 0 answers `--version` and `--help` and otherwise explains that the
//! REPL arrives in stage 1.

const std = @import("std");
const sucheme = @import("sucheme");

/// What the command line asked for.
pub const Request = enum { version, help, not_implemented };

/// Entry layer: receives the host allocator and passes it on. It allocates no
/// accounted objects, so the allocation-point invariant in
/// docs/design/architecture.md does not apply here.
pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    var buf: [512]u8 = undefined;
    var stdout = std.Io.File.Writer.init(.stdout(), io, &buf);
    const w = &stdout.interface;

    switch (classify(args[1..])) {
        .version => try w.print("{s} {s}\n", .{ sucheme.name, sucheme.version }),
        .help => try w.print(
            "{s} {s}\n\nUsage: sucheme [--version] [--help]\n\n" ++
                "The REPL arrives in stage 1; see docs/roadmap.md.\n",
            .{ sucheme.name, sucheme.version },
        ),
        .not_implemented => try w.print(
            "{s} {s}: the REPL is not implemented yet (stage 1).\n" ++
                "Run with --help for the options available now.\n",
            .{ sucheme.name, sucheme.version },
        ),
    }
    try w.flush();
}

/// Classifies the arguments after the program name.
pub fn classify(args: []const []const u8) Request {
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--version")) return .version;
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) return .help;
    }
    return .not_implemented;
}

test "classify recognises --version" {
    try std.testing.expectEqual(Request.version, classify(&.{"--version"}));
}

test "classify recognises --help and -h" {
    try std.testing.expectEqual(Request.help, classify(&.{"--help"}));
    try std.testing.expectEqual(Request.help, classify(&.{"-h"}));
}

test "classify falls back to not_implemented" {
    try std.testing.expectEqual(Request.not_implemented, classify(&.{}));
    try std.testing.expectEqual(Request.not_implemented, classify(&.{"foo.scm"}));
}
