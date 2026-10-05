//! sucheme: an R7RS-small Scheme interpreter.
//!
//! Stage 0 only establishes the build and verification scaffold. The value
//! representation, heap, and machine arrive in stage 1; see
//! docs/design/architecture.md and docs/plans/.

const std = @import("std");
const build_options = @import("build_options");

/// Implementation name reported by `(features)` and the `--version` output.
pub const name = "sucheme";

/// Project version. build.zig.zon's `.version` is the single source of truth;
/// build.zig passes it through as a build option.
pub const version = build_options.version;

test "version is non-empty" {
    try std.testing.expect(version.len > 0);
}

test "name is the implementation name" {
    try std.testing.expectEqualStrings("sucheme", name);
}
