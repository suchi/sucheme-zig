//! The external representation of a character (R7RS 6.6, 7.1.1): what the
//! reader reads after `#\` and what `write` writes. Reading and writing are
//! here together, so the table of names is one table.
//!
//! Slice 1h, the characters. Not written yet: the reader's `#\` and the
//! printer both call into this file, which is where they are filled in.

const std = @import("std");
const Mode = @import("printer.zig").Mode;

pub const ReadError = error{
    /// The text after `#\` is not a character: an unknown name, a hexadecimal
    /// value that is not a scalar value, or a character run into text that
    /// follows it.
    InvalidCharacter,
};

/// Reads the character literal that starts at `src[pos.*]`, which is the `#` of
/// `#\`, and moves `pos` past it. The literal ends at a delimiter or the end of
/// the input.
pub fn read(src: []const u8, pos: *usize) ReadError!u21 {
    _ = src;
    _ = pos;
    return error.InvalidCharacter;
}

/// Writes `c` as `write` (`#\a`, `#\space`, `#\x7f`) or as `display` (the
/// character itself, as UTF-8) would.
pub fn write(out: *std.Io.Writer, mode: Mode, c: u21) std.Io.Writer.Error!void {
    _ = out;
    _ = mode;
    _ = c;
    @panic("slice 1h: writing a character is not written yet");
}

test {
    std.testing.refAllDecls(@This());
}
