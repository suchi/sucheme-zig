//! sucheme: an R7RS-small Scheme interpreter.
//!
//! The public entry to the interpreter. Slice 1a of stage 1 reads integers and
//! calls to `+`; docs/plans/0003-phase1-minimal-slice.md lists what each slice
//! adds, and docs/design/architecture.md the modules it grows into.

const std = @import("std");
const build_options = @import("build_options");

/// Implementation name reported by `(features)` and the `--version` output.
pub const name = build_options.name;

/// Project version. build.zig.zon's `.version` is the single source of truth;
/// build.zig passes it through as a build option.
pub const version = build_options.version;

const reader = @import("reader.zig");
const eval = @import("eval.zig");
const printer = @import("printer.zig");

/// Every way `evalPrint` can fail. Until slice 1b reports Scheme errors as
/// conditions, a Scheme error is one of these too.
pub const Error = reader.Error || eval.Error || std.Io.Writer.Error;

/// Reads every datum in `source`, evaluates each in turn, and writes each
/// result followed by a newline to `out`.
///
/// Stops at the first error. The results written before it stay written.
/// Everything allocated comes from `arena`, which the caller frees as a whole.
pub fn evalPrint(arena: std.mem.Allocator, source: []const u8, out: *std.Io.Writer) Error!void {
    var r: reader.Reader = .init(source);
    while (try r.next(arena)) |d| {
        const v = try eval.eval(arena, d);
        try printer.write(out, v);
        try out.writeByte('\n');
    }
}

test {
    std.testing.refAllDecls(@This());
}

fn evalPrinted(src: []const u8) ![]const u8 {
    const S = struct {
        var buf: [256]u8 = undefined;
    };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var w: std.Io.Writer = .fixed(&S.buf);
    try evalPrint(arena.allocator(), src, &w);
    return w.buffered();
}

test "evalPrint writes each result on its own line" {
    try std.testing.expectEqualStrings("3\n", try evalPrinted("(+ 1 2)"));
    try std.testing.expectEqualStrings("1\n-2\n", try evalPrinted("1 -2"));
    try std.testing.expectEqualStrings("", try evalPrinted("  "));
}

test "evalPrint stops at the first error" {
    try std.testing.expectError(error.UnboundVariable, evalPrinted("1 (foo) 2"));
}

test "version is non-empty" {
    try std.testing.expect(version.len > 0);
}

test "name is non-empty" {
    try std.testing.expect(name.len > 0);
}
