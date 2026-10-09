//! Writes values in their external representation.
//!
//! Slice 1a prints integers only. `write` and `display` differ first for
//! strings and characters, which arrive in slice 1h.

const std = @import("std");
const Value = @import("value.zig").Value;

/// Writes `v` as `write` would (R7RS 6.13.3).
pub fn write(out: *std.Io.Writer, v: Value) std.Io.Writer.Error!void {
    switch (v.kind()) {
        .fixnum => try out.print("{d}", .{v.asFixnum().?}),
    }
}

test {
    std.testing.refAllDecls(@This());
}

fn written(v: Value) ![]const u8 {
    const S = struct {
        var buf: [64]u8 = undefined;
    };
    var w: std.Io.Writer = .fixed(&S.buf);
    try write(&w, v);
    return w.buffered();
}

test "write prints an integer in decimal with its sign" {
    try std.testing.expectEqualStrings("42", try written(.fromFixnum(42)));
    try std.testing.expectEqualStrings("-7", try written(.fromFixnum(-7)));
    try std.testing.expectEqualStrings("0", try written(.fromFixnum(0)));
}

test "write prints the extremes of a fixnum" {
    try std.testing.expectEqualStrings("-9223372036854775808", try written(.fromFixnum(std.math.minInt(i64))));
    try std.testing.expectEqualStrings("9223372036854775807", try written(.fromFixnum(std.math.maxInt(i64))));
}
