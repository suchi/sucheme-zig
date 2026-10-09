//! The Scheme value.
//!
//! A tagged union (ADR-0002). The full set of kinds is the table in
//! docs/design/runtime.md; each arrives with the slice that first creates it.
//! Slice 1a had fixed-length integers; slice 1b adds the unspecified value that
//! `define` returns. A symbol arrives with `quote` in slice 1c.
//!
//! Code outside this file does not switch on the union's tag. It asks `kind`
//! and reads through the accessors, which keeps the representation replaceable
//! while still letting a `switch` on `Kind` list every place a new kind has to
//! be handled.

const std = @import("std");

pub const Value = union(enum) {
    fixnum: i64,
    /// What an expression with no useful value returns, such as `define`. It
    /// has no external representation.
    unspecified,

    /// The unspecified value. Named apart from the variant, which a constant of
    /// the same name would clash with.
    pub const unspecified_value: Value = .unspecified;

    pub fn fromFixnum(n: i64) Value {
        return .{ .fixnum = n };
    }

    pub fn kind(self: Value) Kind {
        return switch (self) {
            .fixnum => .fixnum,
            .unspecified => .unspecified,
        };
    }

    /// The integer, or null when the value is not a fixnum.
    pub fn asFixnum(self: Value) ?i64 {
        return switch (self) {
            .fixnum => |n| n,
            .unspecified => null,
        };
    }
};

/// What a value is, without how it is stored.
pub const Kind = enum { fixnum, unspecified };

test "a fixnum reads back as itself" {
    const v: Value = .fromFixnum(-7);
    try std.testing.expectEqual(Kind.fixnum, v.kind());
    try std.testing.expectEqual(-7, v.asFixnum().?);
}

test "a fixnum holds the full i64 range" {
    try std.testing.expectEqual(std.math.maxInt(i64), Value.fromFixnum(std.math.maxInt(i64)).asFixnum().?);
    try std.testing.expectEqual(std.math.minInt(i64), Value.fromFixnum(std.math.minInt(i64)).asFixnum().?);
}

test "the unspecified value is not a fixnum" {
    const v = Value.unspecified_value;
    try std.testing.expectEqual(Kind.unspecified, v.kind());
    try std.testing.expect(v.asFixnum() == null);
}
