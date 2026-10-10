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
    /// The input ends right after `#\`; the REPL can ask for another line.
    Incomplete,
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

const Case = struct { src: []const u8, c: u21 };

fn readAll(src: []const u8) !u21 {
    var pos: usize = 0;
    const c = try read(src, &pos);
    try std.testing.expectEqual(src.len, pos);
    return c;
}

fn render(mode: Mode, c: u21, buf: []u8) ![]const u8 {
    var w: std.Io.Writer = .fixed(buf);
    try write(&w, mode, c);
    return w.buffered();
}

test "the nine names read as their characters and write back as their names" {
    const cases = [_]Case{
        .{ .src = "#\\alarm", .c = 7 },
        .{ .src = "#\\backspace", .c = 8 },
        .{ .src = "#\\delete", .c = 0x7f },
        .{ .src = "#\\escape", .c = 0x1b },
        .{ .src = "#\\newline", .c = 0xa },
        .{ .src = "#\\null", .c = 0 },
        .{ .src = "#\\return", .c = 0xd },
        .{ .src = "#\\space", .c = 0x20 },
        .{ .src = "#\\tab", .c = 9 },
    };
    var buf: [32]u8 = undefined;
    for (cases) |case| {
        try std.testing.expectEqual(case.c, try readAll(case.src));
        try std.testing.expectEqualStrings(case.src, try render(.write, case.c, &buf));
    }
}

test "names are case sensitive" {
    try std.testing.expectError(error.InvalidCharacter, readAll("#\\Space"));
    try std.testing.expectError(error.InvalidCharacter, readAll("#\\NEWLINE"));
}

test "hexadecimal form reads digits in either case" {
    try std.testing.expectEqual(@as(u21, 0x41), try readAll("#\\x41"));
    try std.testing.expectEqual(@as(u21, 0x3bb), try readAll("#\\x3bb"));
    try std.testing.expectEqual(@as(u21, 0x3bb), try readAll("#\\x3BB"));
    try std.testing.expectEqual(@as(u21, 0x3bb), try readAll("#\\x3Bb"));
    try std.testing.expectEqual(@as(u21, 0x10ffff), try readAll("#\\x10FFFF"));
    try std.testing.expectEqual(@as(u21, 0x41), try readAll("#\\x0000041"));
    try std.testing.expectEqual(@as(u21, 0), try readAll("#\\x0"));
}

test "x alone is the character x" {
    try std.testing.expectEqual(@as(u21, 'x'), try readAll("#\\x"));
    var pos: usize = 0;
    try std.testing.expectEqual(@as(u21, 'x'), try read("#\\x)", &pos));
    try std.testing.expectEqual(@as(usize, 3), pos);
}

test "hexadecimal values that are not scalar values are rejected" {
    try std.testing.expectError(error.InvalidCharacter, readAll("#\\xD800"));
    try std.testing.expectError(error.InvalidCharacter, readAll("#\\xDFFF"));
    try std.testing.expectError(error.InvalidCharacter, readAll("#\\x110000"));
    try std.testing.expectError(error.InvalidCharacter, readAll("#\\xFFFFFFFFFFFFFFFFFFFF"));
    try std.testing.expectEqual(@as(u21, 0xD7FF), try readAll("#\\xD7FF"));
    try std.testing.expectEqual(@as(u21, 0xE000), try readAll("#\\xE000"));
}

test "unknown names and trailing junk are rejected" {
    try std.testing.expectError(error.InvalidCharacter, readAll("#\\foo"));
    try std.testing.expectError(error.InvalidCharacter, readAll("#\\x41g"));
    try std.testing.expectError(error.InvalidCharacter, readAll("#\\ab"));
    try std.testing.expectError(error.InvalidCharacter, readAll("#\\spaces"));
    try std.testing.expectError(error.InvalidCharacter, readAll("#\\x+41"));
    try std.testing.expectError(error.InvalidCharacter, readAll("#\\x4_1"));
}

test "a delimiter right after the backslash is the character" {
    try std.testing.expectEqual(@as(u21, '('), try readAll("#\\("));
    try std.testing.expectEqual(@as(u21, ')'), try readAll("#\\)"));
    try std.testing.expectEqual(@as(u21, ' '), try readAll("#\\ "));
    try std.testing.expectEqual(@as(u21, '"'), try readAll("#\\\""));
    try std.testing.expectEqual(@as(u21, ';'), try readAll("#\\;"));
    try std.testing.expectEqual(@as(u21, '|'), try readAll("#\\|"));
    try std.testing.expectEqual(@as(u21, '\n'), try readAll("#\\\n"));
    try std.testing.expectEqual(@as(u21, '\\'), try readAll("#\\\\"));
    try std.testing.expectEqual(@as(u21, '#'), try readAll("#\\#"));
}

test "a non-ASCII character is one code point" {
    try std.testing.expectEqual(@as(u21, 0x3bb), try readAll("#\\λ"));
    try std.testing.expectEqual(@as(u21, 0x10000), try readAll("#\\𐀀"));
    try std.testing.expectError(error.InvalidCharacter, readAll("#\\λλ"));
}

test "the literal ends at a delimiter and pos stops before it" {
    const cases = [_]struct { src: []const u8, c: u21, end: usize }{
        .{ .src = "#\\a)", .c = 'a', .end = 3 },
        .{ .src = "#\\a b", .c = 'a', .end = 3 },
        .{ .src = "#\\a(", .c = 'a', .end = 3 },
        .{ .src = "#\\a\"", .c = 'a', .end = 3 },
        .{ .src = "#\\a;x", .c = 'a', .end = 3 },
        .{ .src = "#\\a|", .c = 'a', .end = 3 },
        .{ .src = "#\\a\n", .c = 'a', .end = 3 },
        .{ .src = "#\\space)", .c = ' ', .end = 7 },
        .{ .src = "#\\x41 ", .c = 'A', .end = 5 },
        .{ .src = "#\\()", .c = '(', .end = 3 },
    };
    for (cases) |case| {
        var pos: usize = 0;
        try std.testing.expectEqual(case.c, try read(case.src, &pos));
        try std.testing.expectEqual(case.end, pos);
    }
}

test "read starts at pos" {
    var pos: usize = 3;
    try std.testing.expectEqual(@as(u21, 'b'), try read("(a #\\b)", &pos));
    try std.testing.expectEqual(@as(usize, 6), pos);
}

test "input that ends right after the backslash is incomplete" {
    var pos: usize = 0;
    try std.testing.expectError(error.Incomplete, read("#\\", &pos));
    pos = 3;
    try std.testing.expectError(error.Incomplete, read("(a #\\", &pos));
}

test "write writes the other control characters in hexadecimal" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("#\\x1", try render(.write, 1, &buf));
    try std.testing.expectEqualStrings("#\\x10", try render(.write, 0x10, &buf));
    try std.testing.expectEqualStrings("#\\x1f", try render(.write, 0x1f, &buf));
}

test "write writes printable and non-ASCII characters as they are" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("#\\a", try render(.write, 'a', &buf));
    try std.testing.expectEqualStrings("#\\(", try render(.write, '(', &buf));
    try std.testing.expectEqualStrings("#\\x", try render(.write, 'x', &buf));
    try std.testing.expectEqualStrings("#\\λ", try render(.write, 0x3bb, &buf));
    try std.testing.expectEqualStrings("#\\𐀀", try render(.write, 0x10000, &buf));
    try std.testing.expectEqualStrings("#\\\u{80}", try render(.write, 0x80, &buf));
}

test "display writes the character itself" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("a", try render(.display, 'a', &buf));
    try std.testing.expectEqualStrings(" ", try render(.display, ' ', &buf));
    try std.testing.expectEqualStrings("\n", try render(.display, '\n', &buf));
    try std.testing.expectEqualStrings("\x00", try render(.display, 0, &buf));
    try std.testing.expectEqualStrings("λ", try render(.display, 0x3bb, &buf));
    try std.testing.expectEqualStrings("𐀀", try render(.display, 0x10000, &buf));
}

test "write then read then write is the identity" {
    var buf: [32]u8 = undefined;
    var buf2: [32]u8 = undefined;
    const extra = [_]u21{ 0x80, 0xa0, 0x3bb, 0x3042, 0xD7FF, 0xE000, 0xFFFD, 0x10000, 0x10FFFF };
    var i: u32 = 0;
    while (i < 0x80 + extra.len) : (i += 1) {
        const c: u21 = if (i < 0x80) @intCast(i) else extra[i - 0x80];
        const first = try render(.write, c, &buf);
        const back = try readAll(first);
        try std.testing.expectEqual(c, back);
        try std.testing.expectEqualStrings(first, try render(.write, back, &buf2));
    }
}
