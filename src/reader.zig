//! Reads the external representation of data (R7RS 7.1.2).
//!
//! Slice 1a reads decimal integers, identifiers and parenthesised lists. Its
//! output is `Datum`, a tree local to this file, because the value
//! representation has neither pairs nor symbols yet. Slices 1b and 1c bring
//! symbols and pairs, and then the reader returns `Value` and `Datum` goes.
//!
//! Nesting is handled with an explicit stack, not Zig recursion: the depth of
//! the input decides how deep it goes (docs/design/runtime.md).

const std = @import("std");

pub const Datum = union(enum) {
    integer: i64,
    /// The identifier as written. Slice 1a has no case folding.
    identifier: []const u8,
    list: []const Datum,
};

pub const Error = error{
    OutOfMemory,
    /// The input ended inside a list. The REPL can ask for another line on
    /// this (ADR-0014), so it is kept apart from the other syntax errors.
    Incomplete,
    UnexpectedCloseParen,
    /// Text this reader cannot read as a datum.
    InvalidToken,
    /// A decimal integer outside the fixnum range. R7RS 6.2.3 lets this be
    /// reported as an implementation restriction until bignums in stage 4.
    IntegerOutOfRange,
};

pub const Reader = struct {
    src: []const u8,
    pos: usize = 0,

    pub fn init(src: []const u8) Reader {
        return .{ .src = src };
    }

    /// Reads the next datum, or returns null at the end of the input.
    ///
    /// Everything returned is allocated in `arena`, which the caller frees as
    /// a whole.
    pub fn next(self: *Reader, arena: std.mem.Allocator) Error!?Datum {
        // One entry per list opened and not yet closed.
        var open: std.ArrayList(std.ArrayList(Datum)) = .empty;
        while (true) {
            self.skipWhitespace();
            if (self.pos == self.src.len) {
                if (open.items.len == 0) return null;
                return error.Incomplete;
            }
            const datum: Datum = switch (self.src[self.pos]) {
                '(' => {
                    self.pos += 1;
                    try open.append(arena, .empty);
                    continue;
                },
                ')' => blk: {
                    self.pos += 1;
                    var items = open.pop() orelse return error.UnexpectedCloseParen;
                    break :blk .{ .list = try items.toOwnedSlice(arena) };
                },
                else => try self.atom(),
            };
            if (open.items.len == 0) return datum;
            try open.items[open.items.len - 1].append(arena, datum);
        }
    }

    fn skipWhitespace(self: *Reader) void {
        while (self.pos < self.src.len and isWhitespace(self.src[self.pos])) self.pos += 1;
    }

    /// Reads one token up to the next delimiter and classifies it.
    fn atom(self: *Reader) Error!Datum {
        const start = self.pos;
        while (self.pos < self.src.len and !isDelimiter(self.src[self.pos])) self.pos += 1;
        if (self.pos == start) {
            // A delimiter this slice does not read: `"`, `;` or `|`.
            self.pos += 1;
            return error.InvalidToken;
        }
        const token = self.src[start..self.pos];
        if (isDecimalInteger(token)) {
            const n = std.fmt.parseInt(i64, token, 10) catch return error.IntegerOutOfRange;
            return .{ .integer = n };
        }
        if (isUnsupportedNumber(token)) return error.InvalidToken;
        if (isIdentifier(token)) return .{ .identifier = token };
        return error.InvalidToken;
    }
};

// Why: R7RS 7.1.1 defines whitespace as intraline whitespace (space, tab) and
// line endings; a CR is part of a CRLF line ending.
fn isWhitespace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}

// Why: R7RS 7.1.1 <delimiter> is whitespace, a vertical line, a parenthesis, a
// double quote or a semicolon.
fn isDelimiter(c: u8) bool {
    return isWhitespace(c) or c == '|' or c == '(' or c == ')' or c == '"' or c == ';';
}

/// `[+-]?[0-9]+`. Other number syntax arrives with the numeric tower.
fn isDecimalInteger(token: []const u8) bool {
    const digits = if (token[0] == '+' or token[0] == '-') token[1..] else token;
    if (digits.len == 0) return false;
    for (digits) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

/// Numbers whose syntax matches a <peculiar identifier> but which R7RS 7.1.1
/// reads as numbers: <infnan> and the complex units `+i` and `-i`. They arrive
/// with the numeric tower in stage 4; until then they are rejected, not read as
/// identifiers a program could bind. Other number syntax (`1.5`, `1/2`, `#x1F`)
/// does not look like an identifier, so `isIdentifier` already refuses it.
fn isUnsupportedNumber(token: []const u8) bool {
    for ([_][]const u8{ "+inf.0", "-inf.0", "+nan.0", "-nan.0", "+i", "-i" }) |n| {
        if (std.ascii.eqlIgnoreCase(token, n)) return true;
    }
    return false;
}

// Why: R7RS 7.1.1 <identifier>, restricted to ASCII and without the
// `|...|` form: an <initial> followed by <subsequent>s, or a <peculiar
// identifier>. Integers are recognised before this is asked, and
// `isUnsupportedNumber` takes the other numbers that look like one.
fn isIdentifier(token: []const u8) bool {
    if (isInitial(token[0])) return allSubsequent(token[1..]);
    // <peculiar identifier>
    var rest = token;
    if (rest[0] == '+' or rest[0] == '-') {
        rest = rest[1..];
        if (rest.len == 0) return true; // <explicit sign>
        if (isSignSubsequent(rest[0])) return allSubsequent(rest[1..]);
        if (rest[0] != '.') return false;
    }
    // `.` <dot subsequent> <subsequent>*, with or without a sign before it.
    if (rest[0] != '.' or rest.len < 2) return false;
    if (!isSignSubsequent(rest[1]) and rest[1] != '.') return false;
    return allSubsequent(rest[2..]);
}

fn isInitial(c: u8) bool {
    return std.ascii.isAlphabetic(c) or std.mem.indexOfScalar(u8, "!$%&*/:<=>?^_~", c) != null;
}

fn isSignSubsequent(c: u8) bool {
    return isInitial(c) or c == '+' or c == '-' or c == '@';
}

fn allSubsequent(s: []const u8) bool {
    for (s) |c| {
        if (!(isInitial(c) or std.ascii.isDigit(c) or c == '+' or c == '-' or c == '.' or c == '@')) return false;
    }
    return true;
}

test {
    std.testing.refAllDecls(@This());
}

fn readOne(arena: std.mem.Allocator, src: []const u8) Error!Datum {
    var r: Reader = .init(src);
    const d = (try r.next(arena)) orelse return error.Incomplete;
    if (try r.next(arena) != null) return error.InvalidToken;
    return d;
}

test "next reads integers with and without a sign" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqual(42, (try readOne(a, "42")).integer);
    try std.testing.expectEqual(-7, (try readOne(a, "-7")).integer);
    try std.testing.expectEqual(5, (try readOne(a, "+5")).integer);
    try std.testing.expectEqual(std.math.minInt(i64), (try readOne(a, "-9223372036854775808")).integer);
}

test "next reports an integer outside the fixnum range" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.IntegerOutOfRange, readOne(arena.allocator(), "9223372036854775808"));
}

test "next reads a nested list" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const d = try readOne(arena.allocator(), " (+ 1\t(+ 2 3)\r\n) ");
    try std.testing.expectEqual(3, d.list.len);
    try std.testing.expectEqualStrings("+", d.list[0].identifier);
    try std.testing.expectEqual(1, d.list[1].integer);
    try std.testing.expectEqual(2, d.list[2].list[1].integer);
    try std.testing.expectEqual(0, (try readOne(arena.allocator(), "()")).list.len);
}

test "next returns the data of one source in turn, then null" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var r: Reader = .init("1 (2)3");
    try std.testing.expectEqual(1, (try r.next(arena.allocator())).?.integer);
    try std.testing.expectEqual(1, (try r.next(arena.allocator())).?.list.len);
    try std.testing.expectEqual(3, (try r.next(arena.allocator())).?.integer);
    try std.testing.expect(try r.next(arena.allocator()) == null);
    var empty: Reader = .init("  \n");
    try std.testing.expect(try empty.next(arena.allocator()) == null);
}

test "next tells an unfinished list from a stray close paren" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    // `next` itself, not readOne, which turns a missing datum into Incomplete.
    var r: Reader = .init("(+ 1 (2)");
    try std.testing.expectError(error.Incomplete, r.next(arena.allocator()));
    try std.testing.expectError(error.UnexpectedCloseParen, readOne(arena.allocator(), ")"));
}

test "next rejects text that is neither an integer nor an identifier" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    for ([_][]const u8{ "1+", "12a", "#t", "\"s\"", ";", "|x|", ".", "+.1", "'a" }) |src| {
        try std.testing.expectError(error.InvalidToken, readOne(arena.allocator(), src));
    }
}

test "next rejects the numbers that are spelled like peculiar identifiers" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    for ([_][]const u8{ "+inf.0", "-inf.0", "+nan.0", "-nan.0", "+i", "-i", "+INF.0" }) |src| {
        try std.testing.expectError(error.InvalidToken, readOne(arena.allocator(), src));
    }
    // Close neighbours stay identifiers.
    for ([_][]const u8{ "+in", "-inf", "+inf.01", "+ia", "i" }) |src| {
        _ = try readOne(arena.allocator(), src);
    }
}

test "isIdentifier follows the R7RS grammar, peculiar identifiers included" {
    for ([_][]const u8{ "+", "-", "...", "x", "list->vector", "<=?", "a.b", "+a", "-@", "+.a", "..", ".a", "->x" }) |s| {
        if (!isIdentifier(s)) {
            std.debug.print("rejected {s}\n", .{s});
            return error.TestUnexpectedResult;
        }
    }
    for ([_][]const u8{ ".", "+.", "+.1", ".1", "1a", "a#", "@a" }) |s| {
        if (isIdentifier(s)) {
            std.debug.print("accepted {s}\n", .{s});
            return error.TestUnexpectedResult;
        }
    }
}

test "next reads nesting far deeper than a recursive reader could" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const depth = 100_000;
    const src = try arena.allocator().alloc(u8, depth * 2);
    @memset(src[0..depth], '(');
    @memset(src[depth..], ')');
    var d = try readOne(arena.allocator(), src);
    var n: usize = 1;
    while (d.list.len == 1) : (n += 1) d = d.list[0];
    try std.testing.expectEqual(depth, n);
}
