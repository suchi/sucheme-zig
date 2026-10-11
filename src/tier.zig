//! Which tier a test runs in (docs/plans/0007-test-tiers.md).
//!
//! `zig build test` is the tier that runs on every commit, and has to stay
//! quick. A test that checks a scale (a recursion a hundred thousand deep, a
//! loop of a million steps) finds the faults that grow with the size of the
//! input, and finds almost none of the logic faults a small input does not
//! find; it waits for `zig build test -Dslow=true`. Each such test keeps a
//! smaller twin in the quick tier that runs the same logic.
//!
//! A test that is skipped is counted as skipped in the summary that
//! `zig build test --summary all` prints. A plain `zig build test` prints
//! nothing when it succeeds, so the count shows only when that flag is given.

const build_options = @import("build_options");

/// Skips the test that calls it, unless the slow tier was asked for.
pub fn slow() error{SkipZigTest}!void {
    if (!build_options.slow) return error.SkipZigTest;
}

/// Whether the slow tier was asked for.
pub const slow_enabled = build_options.slow;

test {
    @import("std").testing.refAllDecls(@This());
}
