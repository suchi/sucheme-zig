//! The external representation of a string (R7RS 6.7, 7.1.1): what the reader
//! reads between double quotes and what `write` writes. Reading and writing are
//! here together, so the table of escapes is one table.
//!
//! Slice 1h, the strings. Not written yet: the reader's `"` and the printer
//! both call into this file, which is where they are filled in.

const std = @import("std");
const Value = @import("value.zig").Value;
const Heap = @import("heap.zig").Heap;
const Mode = @import("printer.zig").Mode;

pub const ReadError = error{
    OutOfMemory,
    /// The string does not fit in the heap.
    HeapLimit,
    /// The input ended before the closing quote. The REPL can ask for another
    /// line on this (ADR-0014).
    Incomplete,
    /// A backslash followed by something that is not an escape, or a `\x`
    /// escape whose value is not a scalar value.
    InvalidEscape,
};

/// Reads the string literal that starts at `src[pos.*]`, which is the opening
/// `"`, and moves `pos` past the closing one. The string is made in `heap`;
/// `scratch` holds its bytes while they are collected.
pub fn read(src: []const u8, pos: *usize, scratch: std.mem.Allocator, heap: *Heap) ReadError!Value {
    _ = src;
    _ = pos;
    _ = scratch;
    _ = heap;
    return error.InvalidEscape;
}

/// Writes the string `bytes` as `write` (in quotes, with escapes) or as
/// `display` (the bytes as they are) would.
pub fn write(out: *std.Io.Writer, mode: Mode, bytes: []const u8) std.Io.Writer.Error!void {
    _ = out;
    _ = mode;
    _ = bytes;
    @panic("slice 1h: writing a string is not written yet");
}

test {
    std.testing.refAllDecls(@This());
}
