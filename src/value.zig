//! The Scheme value.
//!
//! A tagged union (ADR-0002). The full set of kinds is the table in
//! docs/design/runtime.md; each arrives with the slice that first creates it,
//! so slice 1a has fixed-length integers and nothing else.
//!
//! Code outside this file does not switch on the union's tag. It asks `kind`
//! and reads through the accessors, which keeps the representation replaceable
//! while still letting a `switch` on `Kind` list every place a new kind has to
//! be handled.

const std = @import("std");

pub const Value = union(enum) {
    fixnum: i64,

    pub fn fromFixnum(n: i64) Value {
        return .{ .fixnum = n };
    }

    pub fn kind(self: Value) Kind {
        return switch (self) {
            .fixnum => .fixnum,
        };
    }

    /// The integer, or null when the value is not a fixnum.
    pub fn asFixnum(self: Value) ?i64 {
        return switch (self) {
            .fixnum => |n| n,
        };
    }
};

/// What a value is, without how it is stored.
pub const Kind = enum { fixnum };

test "a fixnum reads back as itself" {
    const v: Value = .fromFixnum(-7);
    try std.testing.expectEqual(Kind.fixnum, v.kind());
    try std.testing.expectEqual(-7, v.asFixnum().?);
}

test "a fixnum holds the full i64 range" {
    try std.testing.expectEqual(std.math.maxInt(i64), Value.fromFixnum(std.math.maxInt(i64)).asFixnum().?);
    try std.testing.expectEqual(std.math.minInt(i64), Value.fromFixnum(std.math.minInt(i64)).asFixnum().?);
}
