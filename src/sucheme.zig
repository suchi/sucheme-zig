//! sucheme: an R7RS-small Scheme interpreter.
//!
//! Stage 0 only establishes the build and verification scaffold. The value
//! representation, heap, and machine arrive in stage 1; see
//! docs/design/architecture.md and docs/plans/.

const std = @import("std");
const build_options = @import("build_options");

/// Implementation name reported by `(features)` and the `--version` output.
pub const name = build_options.name;

/// Project version. build.zig.zon's `.version` is the single source of truth;
/// build.zig passes it through as a build option.
pub const version = build_options.version;

pub const Error = error{ OutOfMemory, WriteFailed, NotImplemented };

/// Reads every datum in `source`, evaluates each in turn, and writes each
/// result followed by a newline to `out`.
///
/// Not implemented yet; tests/scheme/0001-integer-arithmetic.txt fails
/// against this.
pub fn evalPrint(arena: std.mem.Allocator, source: []const u8, out: *std.Io.Writer) Error!void {
    _ = arena;
    _ = source;
    _ = out;
    return error.NotImplemented;
}

test "version is non-empty" {
    try std.testing.expect(version.len > 0);
}

test "name is non-empty" {
    try std.testing.expect(name.len > 0);
}
