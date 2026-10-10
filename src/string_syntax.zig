//! The external representation of a string (R7RS 6.7, 7.1.1): what the reader
//! reads between double quotes and what `write` writes. Reading and writing are
//! here together, so the table of escapes is one table.
//!
//! Slice 1h, the strings. Not written yet: the reader's `"` and the printer
//! both call into this file, which is where they are filled in.

const std = @import("std");
const value = @import("value.zig");
const Value = value.Value;
const isScalarValue = value.isScalarValue;
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
/// `scratch` holds its bytes while they are collected. On an error `pos` is
/// where it was.
///
/// The input is valid UTF-8 (the interpreter checks it as a whole), so a byte
/// that is not an escape is copied as it is: a raw newline, a tab and the bytes
/// of a non-ASCII character all belong to the string.
pub fn read(src: []const u8, pos: *usize, scratch: std.mem.Allocator, heap: *Heap) ReadError!Value {
    std.debug.assert(src[pos.*] == '"');
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(scratch);
    var i = pos.* + 1;
    while (true) {
        if (i >= src.len) return error.Incomplete;
        const c = src[i];
        i += 1;
        switch (c) {
            '"' => break,
            '\\' => try readEscape(src, &i, scratch, &bytes),
            else => try bytes.append(scratch, c),
        }
    }
    const s = try heap.createString(bytes.items);
    pos.* = i;
    return .fromString(s);
}

/// Reads the escape whose backslash has just been read, and appends what it
/// stands for to `bytes`. `i` is the index after the backslash.
fn readEscape(src: []const u8, i: *usize, scratch: std.mem.Allocator, bytes: *std.ArrayList(u8)) ReadError!void {
    if (i.* >= src.len) return error.Incomplete;
    const c = src[i.*];
    i.* += 1;
    const byte: u8 = switch (c) {
        'a' => 7,
        'b' => 8,
        't' => '\t',
        'n' => '\n',
        'r' => '\r',
        '"', '\\', '|' => c,
        'x' => return readHexEscape(src, i, scratch, bytes),
        else => return error.InvalidEscape,
    };
    try bytes.append(scratch, byte);
}

/// Reads the rest of `\x<hex>;`, after the `x`, and appends the character's
/// UTF-8 encoding to `bytes`.
fn readHexEscape(src: []const u8, i: *usize, scratch: std.mem.Allocator, bytes: *std.ArrayList(u8)) ReadError!void {
    var code: u32 = 0;
    var digits: usize = 0;
    while (true) {
        if (i.* >= src.len) return error.Incomplete;
        const c = src[i.*];
        i.* += 1;
        if (c == ';') break;
        const digit = std.fmt.charToDigit(c, 16) catch return error.InvalidEscape;
        // Once the value is past the last scalar value it stays there, so a
        // long run of digits cannot overflow and wrap around into range.
        if (code <= max_scalar_value) code = code * 16 + digit;
        digits += 1;
    }
    if (digits == 0 or !isScalarValue(code)) return error.InvalidEscape;
    var encoded: [4]u8 = undefined;
    const len = std.unicode.utf8Encode(@intCast(code), &encoded) catch unreachable;
    try bytes.appendSlice(scratch, encoded[0..len]);
}

const max_scalar_value = 0x10FFFF;

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

/// Reads the literal at the start of `src` into `heap` and returns its bytes.
fn readBytes(heap: *Heap, src: []const u8) ReadError![]const u8 {
    var pos: usize = 0;
    const v = try read(src, &pos, std.testing.allocator, heap);
    return v.asString().?.bytes;
}

fn expectRead(expected: []const u8, src: []const u8) !void {
    var heap: Heap = .init(std.testing.allocator, .{});
    defer heap.deinit();
    try std.testing.expectEqualStrings(expected, try readBytes(&heap, src));
}

fn expectReadError(expected: ReadError, src: []const u8) !void {
    var heap: Heap = .init(std.testing.allocator, .{});
    defer heap.deinit();
    var pos: usize = 0;
    try std.testing.expectError(expected, read(src, &pos, std.testing.allocator, &heap));
    try std.testing.expectEqual(0, pos);
}

test "read: an empty string and a plain one" {
    try expectRead("", "\"\"");
    try expectRead("abc", "\"abc\"");
    try expectRead("hello world", "\"hello world\"");
}

test "read: every escape of R7RS" {
    try expectRead("\x07", "\"\\a\"");
    try expectRead("\x08", "\"\\b\"");
    try expectRead("\t", "\"\\t\"");
    try expectRead("\n", "\"\\n\"");
    try expectRead("\r", "\"\\r\"");
    try expectRead("\"", "\"\\\"\"");
    try expectRead("\\", "\"\\\\\"");
    try expectRead("|", "\"\\|\"");
    try expectRead("a\tb\"c\\d", "\"a\\tb\\\"c\\\\d\"");
}

test "read: a hex escape is the character with that code, in either case" {
    try expectRead("A", "\"\\x41;\"");
    try expectRead("\u{3bb}", "\"\\x3bb;\"");
    try expectRead("\u{3bb}", "\"\\x3BB;\"");
    try expectRead("a\u{3bb}b", "\"a\\x3Bb;b\"");
    try expectRead("\x00", "\"\\x0;\"");
    try expectRead("\u{10FFFF}", "\"\\x10ffff;\"");
    try expectRead("\u{7ff}\u{800}", "\"\\x7ff;\\x800;\"");
    // Leading zeros are digits like the others, however many there are.
    try expectRead("A", "\"\\x0000000000000000000000041;\"");
}

test "read: a hex escape that is not a scalar value, or not an escape, is invalid" {
    try expectReadError(error.InvalidEscape, "\"\\x41\"");
    try expectReadError(error.InvalidEscape, "\"\\x41 \"");
    try expectReadError(error.InvalidEscape, "\"\\xD800;\"");
    try expectReadError(error.InvalidEscape, "\"\\xDFFF;\"");
    try expectReadError(error.InvalidEscape, "\"\\x110000;\"");
    try expectReadError(error.InvalidEscape, "\"\\x;\"");
    try expectReadError(error.InvalidEscape, "\"\\xg;\"");
    // So many digits that a 32-bit value would wrap around into range.
    try expectReadError(error.InvalidEscape, "\"\\x100000041;\"");
    try expectReadError(error.InvalidEscape, "\"\\x1000000000000000041;\"");
}

test "read: a backslash that begins no escape is invalid" {
    try expectReadError(error.InvalidEscape, "\"\\q\"");
    try expectReadError(error.InvalidEscape, "\"a\\zb\"");
    try expectReadError(error.InvalidEscape, "\"\\X41;\"");
    // A line continuation is not read yet (slice 1h).
    try expectReadError(error.InvalidEscape, "\"a\\\nb\"");
}

test "read: a string that does not close is incomplete" {
    try expectReadError(error.Incomplete, "\"");
    try expectReadError(error.Incomplete, "\"abc");
    try expectReadError(error.Incomplete, "\"a\\\"");
    try expectReadError(error.Incomplete, "\"a\\");
    try expectReadError(error.Incomplete, "\"\\x");
    try expectReadError(error.Incomplete, "\"\\x4");
    try expectReadError(error.Incomplete, "\"\\x41");
}

test "read: a raw newline, a tab and non-ASCII bytes belong to the string" {
    try expectRead("a\nb", "\"a\nb\"");
    try expectRead("\t\r", "\"\t\r\"");
    try expectRead("\u{3053}\u{3093}\u{306b}\u{3061}\u{306f}", "\"\u{3053}\u{3093}\u{306b}\u{3061}\u{306f}\"");
    try expectRead("a \u{3bb} \u{1F600}", "\"a \u{3bb} \u{1F600}\"");
}

test "read: the position is left after the closing quote, and what follows is not read" {
    var heap: Heap = .init(std.testing.allocator, .{});
    defer heap.deinit();
    const src = "(\"ab\" \"cd\")";
    var pos: usize = 1;
    const first = try read(src, &pos, std.testing.allocator, &heap);
    try std.testing.expectEqualStrings("ab", first.asString().?.bytes);
    try std.testing.expectEqual(5, pos);
    pos = 6;
    const second = try read(src, &pos, std.testing.allocator, &heap);
    try std.testing.expectEqualStrings("cd", second.asString().?.bytes);
    try std.testing.expectEqual(10, pos);
    // A quote that is escaped does not close the string.
    pos = 0;
    const third = try read("\"a\\\"\" b", &pos, std.testing.allocator, &heap);
    try std.testing.expectEqualStrings("a\"", third.asString().?.bytes);
    try std.testing.expectEqual(5, pos);
}

test "read: a string that does not fit under the limit gives the accounting back" {
    // What a two-byte string accounts for, taken from a heap of its own.
    var probe: Heap = .init(std.testing.allocator, .{});
    defer probe.deinit();
    _ = try probe.createString("ok");
    var heap: Heap = .init(std.testing.allocator, .{ .limit = probe.accounted });
    defer heap.deinit();
    try expectReadErrorIn(&heap, error.HeapLimit, "\"a long string\"");
    try std.testing.expectEqual(0, heap.accounted);
    // The small one still fits, so the failure left the heap usable.
    try std.testing.expectEqualStrings("ok", try readBytes(&heap, "\"ok\""));
}

fn expectReadErrorIn(heap: *Heap, expected: ReadError, src: []const u8) !void {
    var pos: usize = 0;
    try std.testing.expectError(expected, read(src, &pos, std.testing.allocator, heap));
    try std.testing.expectEqual(0, pos);
}

test "read: a scratch allocation that fails is an out of memory, and nothing leaks" {
    // The first allocation is the byte list, the second the string's copy; the
    // heap has its own allocator, so only the list is made to fail.
    var heap: Heap = .init(std.testing.allocator, .{});
    defer heap.deinit();
    var failing: std.testing.FailingAllocator = .init(std.testing.allocator, .{ .fail_index = 0 });
    var pos: usize = 0;
    try std.testing.expectError(error.OutOfMemory, read("\"abc\"", &pos, failing.allocator(), &heap));
    try std.testing.expectEqual(0, pos);
    try std.testing.expectEqual(0, heap.accounted);
    // A failure later, while the list grows, frees what the list had.
    // (The list's first allocation is 128 bytes, so the string is longer.)
    var long: [302]u8 = undefined;
    @memset(&long, 'x');
    long[0] = '"';
    long[301] = '"';
    // Growing in place is refused, so it takes a second allocation, which fails.
    var later: std.testing.FailingAllocator = .init(std.testing.allocator, .{ .fail_index = 1, .resize_fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, read(&long, &pos, later.allocator(), &heap));
    try std.testing.expectEqual(1, later.allocations);
    try std.testing.expectEqual(later.allocated_bytes, later.freed_bytes);
    // The scratch is given back on success too.
    var ok: std.testing.FailingAllocator = .init(std.testing.allocator, .{});
    _ = try read("\"abc\"", &pos, ok.allocator(), &heap);
    try std.testing.expectEqual(ok.allocated_bytes, ok.freed_bytes);
}
