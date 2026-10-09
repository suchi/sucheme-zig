//! Reads the external representation of data (R7RS 7.1.2).
//!
//! Slice 1c reads decimal integers, booleans, identifiers, parenthesised lists
//! and the `'` abbreviation. It builds `Value`s directly: pairs are allocated
//! with the allocator it is given, and identifiers are interned in the symbol
//! table it is given. Both outlive the line until the GC heap arrives (slice
//! 1g), because `quote` can hand a datum to a definition.
//!
//! Nesting is handled with an explicit stack, not Zig recursion: the depth of
//! the input decides how deep it goes (docs/design/runtime.md).

const std = @import("std");
const Value = @import("value.zig").Value;
const symbol = @import("symbol.zig");

pub const Error = error{
    OutOfMemory,
    /// The input ended inside a list or after a `'`. The REPL can ask for
    /// another line on this (ADR-0014), so it is kept apart from the other
    /// syntax errors.
    Incomplete,
    UnexpectedCloseParen,
    /// A `'` followed by `)`: there is nothing to quote.
    MissingDatum,
    /// Text this reader cannot read as a datum.
    InvalidToken,
    /// A decimal integer outside the fixnum range. R7RS 6.2.3 lets this be
    /// reported as an implementation restriction until bignums in stage 4.
    IntegerOutOfRange,
};

/// Where what the reader builds goes. These outlive the call.
pub const Sink = struct {
    alloc: std.mem.Allocator,
    symbols: *symbol.Table,
};

/// What is open at this point of the input.
const Frame = union(enum) {
    /// A list whose elements so far are these.
    list: std.ArrayList(Value),
    /// A `'` waiting for its datum.
    quote,
};

pub const Reader = struct {
    src: []const u8,
    pos: usize = 0,

    pub fn init(src: []const u8) Reader {
        return .{ .src = src };
    }

    /// Reads the next datum, or returns null at the end of the input.
    ///
    /// The datum is allocated in `sink`. `scratch` holds what is open while a
    /// datum is read, and the caller frees it as a whole.
    pub fn next(self: *Reader, scratch: std.mem.Allocator, sink: Sink) Error!?Value {
        var open: std.ArrayList(Frame) = .empty;
        while (true) {
            self.skipWhitespace();
            if (self.pos == self.src.len) {
                if (open.items.len == 0) return null;
                return error.Incomplete;
            }
            var datum: Value = switch (self.src[self.pos]) {
                '(' => {
                    self.pos += 1;
                    try open.append(scratch, .{ .list = .empty });
                    continue;
                },
                '\'' => {
                    self.pos += 1;
                    try open.append(scratch, .quote);
                    continue;
                },
                ')' => blk: {
                    self.pos += 1;
                    if (open.items.len == 0) return error.UnexpectedCloseParen;
                    switch (open.pop().?) {
                        .quote => return error.MissingDatum,
                        .list => |items| break :blk try listOf(sink, items.items),
                    }
                },
                else => try self.atom(sink),
            };
            // A finished datum closes every `'` waiting for it.
            while (open.items.len != 0 and open.items[open.items.len - 1] == .quote) {
                _ = open.pop();
                datum = try quoted(sink, datum);
            }
            if (open.items.len == 0) return datum;
            try open.items[open.items.len - 1].list.append(scratch, datum);
        }
    }

    fn skipWhitespace(self: *Reader) void {
        while (self.pos < self.src.len and isWhitespace(self.src[self.pos])) self.pos += 1;
    }

    /// Reads one token up to the next delimiter and classifies it.
    fn atom(self: *Reader, sink: Sink) Error!Value {
        const start = self.pos;
        while (self.pos < self.src.len and !isDelimiter(self.src[self.pos])) self.pos += 1;
        if (self.pos == start) {
            // A delimiter this slice does not read: `"`, `;` or `|`.
            self.pos += 1;
            return error.InvalidToken;
        }
        const token = self.src[start..self.pos];
        if (booleanOf(token)) |b| return .fromBool(b);
        if (isDecimalInteger(token)) {
            const n = std.fmt.parseInt(i64, token, 10) catch return error.IntegerOutOfRange;
            return .fromFixnum(n);
        }
        if (isUnsupportedNumber(token)) return error.InvalidToken;
        if (isIdentifier(token)) return .fromSymbol(try sink.symbols.intern(sink.alloc, token));
        return error.InvalidToken;
    }
};

/// The list of `items`, as pairs allocated in `sink`.
fn listOf(sink: Sink, items: []const Value) Error!Value {
    var result: Value = Value.empty_list_value;
    var i = items.len;
    while (i > 0) {
        i -= 1;
        result = try Value.cons(sink.alloc, items[i], result);
    }
    return result;
}

/// `(quote datum)`, which `'datum` abbreviates (R7RS 2.4).
fn quoted(sink: Sink, datum: Value) Error!Value {
    const quote_symbol: Value = .fromSymbol(try sink.symbols.intern(sink.alloc, "quote"));
    const tail = try Value.cons(sink.alloc, datum, Value.empty_list_value);
    return Value.cons(sink.alloc, quote_symbol, tail);
}

// Why: R7RS 7.1.1 <boolean>: `#t`, `#f`, `#true` and `#false`.
fn booleanOf(token: []const u8) ?bool {
    if (std.mem.eql(u8, token, "#t") or std.mem.eql(u8, token, "#true")) return true;
    if (std.mem.eql(u8, token, "#f") or std.mem.eql(u8, token, "#false")) return false;
    return null;
}

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

const printer = @import("printer.zig");

/// A reader test's fixture: where data goes, and how it is printed back.
const Fixture = struct {
    arena: std.heap.ArenaAllocator,
    symbols: symbol.Table = .{},

    fn init() Fixture {
        return .{ .arena = .init(std.testing.allocator) };
    }

    fn deinit(self: *Fixture) void {
        self.arena.deinit();
    }

    fn sink(self: *Fixture) Sink {
        return .{ .alloc = self.arena.allocator(), .symbols = &self.symbols };
    }

    /// Reads the only datum of `src`; any other count is an error.
    fn readOne(self: *Fixture, src: []const u8) Error!Value {
        var r: Reader = .init(src);
        const d = (try r.next(self.arena.allocator(), self.sink())) orelse return error.Incomplete;
        if (try r.next(self.arena.allocator(), self.sink()) != null) return error.InvalidToken;
        return d;
    }

    /// What `src` reads as, written back.
    fn roundTrip(self: *Fixture, src: []const u8, buf: []u8) ![]const u8 {
        const d = try self.readOne(src);
        var w: std.Io.Writer = .fixed(buf);
        try printer.write(&w, std.testing.allocator, &self.symbols, d);
        return w.buffered();
    }
};

test "next reads integers with and without a sign" {
    var f: Fixture = .init();
    defer f.deinit();
    try std.testing.expectEqual(42, (try f.readOne("42")).asFixnum().?);
    try std.testing.expectEqual(-7, (try f.readOne("-7")).asFixnum().?);
    try std.testing.expectEqual(5, (try f.readOne("+5")).asFixnum().?);
    try std.testing.expectEqual(std.math.minInt(i64), (try f.readOne("-9223372036854775808")).asFixnum().?);
}

test "next reports an integer outside the fixnum range" {
    var f: Fixture = .init();
    defer f.deinit();
    try std.testing.expectError(error.IntegerOutOfRange, f.readOne("9223372036854775808"));
}

test "next reads the four spellings of a boolean" {
    var f: Fixture = .init();
    defer f.deinit();
    try std.testing.expect((try f.readOne("#t")).isTrue());
    try std.testing.expect((try f.readOne("#true")).isTrue());
    try std.testing.expect(!(try f.readOne("#f")).isTrue());
    try std.testing.expect(!(try f.readOne("#false")).isTrue());
    try std.testing.expectEqual(.boolean, (try f.readOne("#f")).kind());
}

test "next reads an identifier as the one symbol of its name" {
    var f: Fixture = .init();
    defer f.deinit();
    const a = (try f.readOne("abc")).asSymbol().?;
    try std.testing.expectEqual(a, (try f.readOne("abc")).asSymbol().?);
    try std.testing.expect(a != (try f.readOne("abd")).asSymbol().?);
    // Identifiers are case sensitive (R7RS 2.1).
    try std.testing.expect(a != (try f.readOne("ABC")).asSymbol().?);
    try std.testing.expectEqualStrings("abc", f.symbols.nameOf(a));
}

test "next reads lists, the empty list and nesting" {
    var f: Fixture = .init();
    defer f.deinit();
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("(+ 1 (+ 2 3))", try f.roundTrip(" (+ 1\t(+ 2 3)\r\n) ", &buf));
    try std.testing.expectEqualStrings("()", try f.roundTrip("()", &buf));
    try std.testing.expectEqualStrings("(())", try f.roundTrip("(())", &buf));
    try std.testing.expectEqualStrings("(a (b c) ())", try f.roundTrip("(a (b c) ())", &buf));
    try std.testing.expectEqual(.empty_list, (try f.readOne("()")).kind());
    try std.testing.expectEqual(.pair, (try f.readOne("(1)")).kind());
}

test "next reads ' as a quote form, and nests it" {
    var f: Fixture = .init();
    defer f.deinit();
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("(quote a)", try f.roundTrip("'a", &buf));
    try std.testing.expectEqualStrings("(quote (1 2))", try f.roundTrip("'(1 2)", &buf));
    try std.testing.expectEqualStrings("(quote (quote a))", try f.roundTrip("''a", &buf));
    try std.testing.expectEqualStrings("(a (quote b) c)", try f.roundTrip("(a 'b c)", &buf));
    try std.testing.expectEqualStrings("(quote ())", try f.roundTrip("'()", &buf));
    // `'a` and `(quote a)` are the same datum.
    try std.testing.expectEqualStrings(try f.roundTrip("(quote a)", &buf), "(quote a)");
}

test "next reads the data of one source in turn, then null" {
    var f: Fixture = .init();
    defer f.deinit();
    var r: Reader = .init("1 (2)3 'x");
    const a = f.arena.allocator();
    try std.testing.expectEqual(1, (try r.next(a, f.sink())).?.asFixnum().?);
    try std.testing.expectEqual(.pair, (try r.next(a, f.sink())).?.kind());
    try std.testing.expectEqual(3, (try r.next(a, f.sink())).?.asFixnum().?);
    try std.testing.expectEqual(.pair, (try r.next(a, f.sink())).?.kind());
    try std.testing.expect(try r.next(a, f.sink()) == null);
    var empty: Reader = .init("  \n");
    try std.testing.expect(try empty.next(a, f.sink()) == null);
}

test "next tells an unfinished input from a stray close paren" {
    var f: Fixture = .init();
    defer f.deinit();
    const a = f.arena.allocator();
    // `next` itself, not readOne, which turns a missing datum into Incomplete.
    var r: Reader = .init("(+ 1 (2)");
    try std.testing.expectError(error.Incomplete, r.next(a, f.sink()));
    var q: Reader = .init("'");
    try std.testing.expectError(error.Incomplete, q.next(a, f.sink()));
    var q2: Reader = .init("(a '");
    try std.testing.expectError(error.Incomplete, q2.next(a, f.sink()));
    try std.testing.expectError(error.UnexpectedCloseParen, f.readOne(")"));
    try std.testing.expectError(error.UnexpectedCloseParen, f.readOne("(1))"));
}

test "next reports a quote with nothing to quote" {
    var f: Fixture = .init();
    defer f.deinit();
    try std.testing.expectError(error.MissingDatum, f.readOne("')"));
    try std.testing.expectError(error.MissingDatum, f.readOne("(a ')"));
    try std.testing.expectError(error.MissingDatum, f.readOne("(a '' )"));
}

test "next rejects text that is neither an integer, a boolean nor an identifier" {
    var f: Fixture = .init();
    defer f.deinit();
    for ([_][]const u8{ "1+", "12a", "#tru", "#T", "#", "#(1)", "\"s\"", ";", "|x|", ".", "+.1", "a'b" }) |src| {
        try std.testing.expectError(error.InvalidToken, f.readOne(src));
    }
}

test "next rejects the numbers that are spelled like peculiar identifiers" {
    var f: Fixture = .init();
    defer f.deinit();
    for ([_][]const u8{ "+inf.0", "-inf.0", "+nan.0", "-nan.0", "+i", "-i", "+INF.0" }) |src| {
        try std.testing.expectError(error.InvalidToken, f.readOne(src));
    }
    // Close neighbours stay identifiers.
    for ([_][]const u8{ "+in", "-inf", "+inf.01", "+ia", "i" }) |src| {
        _ = try f.readOne(src);
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
    var f: Fixture = .init();
    defer f.deinit();
    const depth = 100_000;
    const src = try f.arena.allocator().alloc(u8, depth * 2);
    @memset(src[0..depth], '(');
    @memset(src[depth..], ')');
    var d = try f.readOne(src);
    // The innermost `()` is the empty list, so there is one pair fewer than
    // there are pairs of parentheses.
    var pairs: usize = 0;
    while (d.asPair()) |p| : (pairs += 1) d = p.car;
    try std.testing.expectEqual(depth - 1, pairs);
    try std.testing.expectEqual(.empty_list, d.kind());
}

test "next reads a long chain of quotes and a long list" {
    var f: Fixture = .init();
    defer f.deinit();
    const n = 100_000;
    const quotes = try f.arena.allocator().alloc(u8, n + 1);
    @memset(quotes[0..n], '\'');
    quotes[n] = '1';
    var d = try f.readOne(quotes);
    var depth: usize = 0;
    while (d.asPair()) |p| : (depth += 1) d = p.cdr.asPair().?.car;
    try std.testing.expectEqual(n, depth);

    const list = try f.arena.allocator().alloc(u8, 2 * n + 2);
    list[0] = '(';
    for (0..n) |k| {
        list[1 + 2 * k] = '1';
        list[2 + 2 * k] = ' ';
    }
    list[2 * n + 1] = ')';
    var l = try f.readOne(list);
    var count: usize = 0;
    while (l.asPair()) |p| : (count += 1) l = p.cdr;
    try std.testing.expectEqual(n, count);
}
