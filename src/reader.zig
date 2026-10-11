//! Reads the external representation of data (R7RS 7.1.2).
//!
//! スライス 1c が読むのは、10 進整数、真偽値、識別子、丸括弧のリスト、`'` の略記である。
//! `Value` を直接作る。ペアは渡された GC ヒープに確保し、識別子は渡されたシンボル表に
//! インターンする。読み取りの途中でヒープは GC しないので、`next` が返した時点で
//! データは完全な形をしている。何からも参照されなくなればすぐにゴミになるが、
//! `quote` が、参照を持つ定義にデータを渡すことはある。
//!
//! ベクタ `#(` ... `)` はリストと同じように集め、閉じたときにヒープに作る。
//! ベクタの中のドットはエラーである。
//!
//! ネストは Zig の再帰でなく、明示的なスタックで処理する。どこまで深く進めるかは
//! 入力の深さで決まる(docs/design/runtime.md)。

const std = @import("std");
const Value = @import("value.zig").Value;
const symbol = @import("symbol.zig");
const Heap = @import("heap.zig").Heap;
const char_syntax = @import("char_syntax.zig");
const string_syntax = @import("string_syntax.zig");

pub const Error = error{
    OutOfMemory,
    /// The pairs of the datum do not fit in the heap.
    HeapLimit,
    /// The input ended inside a list or after a `'`.
    /// REPL はこれを見て、続きの 1 行を求められる(ADR-0014)。そのため、ほかの構文
    /// エラーとは分けてある。
    Incomplete,
    UnexpectedCloseParen,
    /// A `'` followed by `)`: there is nothing to quote.
    MissingDatum,
    /// A `.` that does not stand between the last element of a list and the
    /// one datum that ends it: at the top level, first in a list, after a `'`,
    /// before the `)`, or followed by more than one datum.
    UnexpectedDot,
    /// Text this reader cannot read as a datum.
    InvalidToken,
    /// A string with a backslash that begins no escape (src/string_syntax.zig).
    InvalidEscape,
    /// A `#\` that does not begin a character (src/char_syntax.zig).
    InvalidCharacter,
    /// Input that is not valid UTF-8.
    /// 文字列・文字・シンボル名はテキストなので、何かを読む前に、入力全体を拒否する。
    InvalidUtf8,
    /// A decimal integer outside the fixnum range.
    /// R7RS 6.2.3 は、段階4で多倍長整数(bignum)を入れるまで、これを実装上の制限として
    /// 報告してよいとしている。
    IntegerOutOfRange,
};

/// Where what the reader builds goes.
/// これらは呼び出しより長く生きる。
pub const Sink = struct {
    /// Where the names of new symbols are kept.
    alloc: std.mem.Allocator,
    /// Where the pairs go.
    /// 読み取りの途中でヒープは GC しないので、呼び出し側が受け取る時点でデータは
    /// 完全な形をしている。
    heap: *Heap,
    symbols: *symbol.Table,
};

/// What is open at this point of the input.
const Frame = union(enum) {
    list: List,
    /// A `#(` whose elements so far are these.
    /// ドットはベクタの中では意味を持たないので、持っておくのは要素だけでよい。
    vector: std.ArrayList(Value),
    /// A `'` waiting for its datum.
    quote,

    const List = struct {
        /// The elements so far.
        items: std.ArrayList(Value) = .empty,
        /// Whether a `.` has been read, so that the next datum is the tail.
        dot: bool = false,
        /// The datum after the dot, once it has been read.
        tail: ?Value = null,

        /// Takes a finished datum as the next element, or as the tail if a dot
        /// came before it.
        /// ドットの後の 2 つ目のデータは、エラーである。
        fn add(self: *List, scratch: std.mem.Allocator, datum: Value) Error!void {
            if (!self.dot) return self.items.append(scratch, datum);
            if (self.tail != null) return error.UnexpectedDot;
            self.tail = datum;
        }
    };
};

pub const Reader = struct {
    src: []const u8,
    pos: usize = 0,

    pub fn init(src: []const u8) Reader {
        return .{ .src = src };
    }

    /// Reads the next datum, or returns null at the end of the input.
    ///
    /// データは `sink` に確保する。`scratch` は、データを読んでいる間に開いているものを
    /// 持ち、呼び出し側がまとめて解放する。
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
                    try open.append(scratch, .{ .list = .{} });
                    continue;
                },
                '.' => if (self.atDot()) {
                    self.pos += 1;
                    // Why: R7RS 7.1.2 の <list> が `.` を許すのは、1 つ以上の要素と、
                    // リストを終える 1 つだけのデータとの間である。
                    if (open.items.len == 0) return error.UnexpectedDot;
                    switch (open.items[open.items.len - 1]) {
                        // Why: R7RS 7.1.2 の <vector> は `#(` <datum>* `)` で、
                        // ドットを置く場所がない。
                        .quote, .vector => return error.UnexpectedDot,
                        .list => |*l| {
                            if (l.dot or l.items.items.len == 0) return error.UnexpectedDot;
                            l.dot = true;
                        },
                    }
                    continue;
                } else try self.atom(sink),
                '"' => try string_syntax.read(self.src, &self.pos, scratch, sink.heap),
                '#' => if (self.atCharacter()) .fromCharacter(try char_syntax.read(self.src, &self.pos)) else if (self.atVectorOpen()) {
                    self.pos += 2;
                    try open.append(scratch, .{ .vector = .empty });
                    continue;
                } else try self.atom(sink),
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
                        .list => |l| {
                            if (l.dot and l.tail == null) return error.UnexpectedDot;
                            break :blk try listOf(sink, l.items.items, l.tail orelse Value.empty_list_value);
                        },
                        .vector => |items| break :blk .fromVector(try sink.heap.createVector(items.items)),
                    }
                },
                else => try self.atom(sink),
            };
            // 完成したデータは、それを待っているすべての `'` を閉じる。
            while (open.items.len != 0 and open.items[open.items.len - 1] == .quote) {
                _ = open.pop();
                datum = try quoted(sink, datum);
            }
            if (open.items.len == 0) return datum;
            switch (open.items[open.items.len - 1]) {
                .list => |*l| try l.add(scratch, datum),
                .vector => |*items| try items.append(scratch, datum),
                .quote => unreachable,
            }
        }
    }

    /// Whether the input is at the `#(` that begins a vector.
    fn atVectorOpen(self: *const Reader) bool {
        return self.pos + 1 < self.src.len and self.src[self.pos + 1] == '(';
    }

    /// Whether the input is at a `.` that stands alone: the next character is a
    /// delimiter or the end.
    /// `...` と `.a` は識別子であり、ドットではない。
    fn atDot(self: *const Reader) bool {
        const after = self.pos + 1;
        return after == self.src.len or isDelimiter(self.src[after]);
    }

    /// Whether the input is at the `#\` that begins a character.
    fn atCharacter(self: *const Reader) bool {
        return self.pos + 1 < self.src.len and self.src[self.pos + 1] == '\\';
    }

    /// Skips whitespace and line comments.
    /// 行コメントは `;` から行末の改行の手前までである。改行は空白として次の周で
    /// 読み飛ばす。文字列の中の `;` と `#\;` は、それぞれの読み取りが先に処理する
    /// ので、ここには届かない。ブロックコメント `#|` とデータコメント `#;` は
    /// 段階5で入る。
    fn skipWhitespace(self: *Reader) void {
        while (self.pos < self.src.len) {
            const c = self.src[self.pos];
            if (c == ';') {
                while (self.pos < self.src.len and self.src[self.pos] != '\n') self.pos += 1;
            } else if (isWhitespace(c)) {
                self.pos += 1;
            } else {
                return;
            }
        }
    }

    /// Reads one token up to the next delimiter and classifies it.
    fn atom(self: *Reader, sink: Sink) Error!Value {
        const start = self.pos;
        while (self.pos < self.src.len and !isDelimiter(self.src[self.pos])) self.pos += 1;
        if (self.pos == start) {
            // このスライスが読まない区切り文字: `|`。
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

/// The pairs of `items` ending in `tail`, allocated in `sink`.
/// `tail` が `()` ならリストになる。
fn listOf(sink: Sink, items: []const Value, tail: Value) Error!Value {
    var result = tail;
    var i = items.len;
    while (i > 0) {
        i -= 1;
        result = try sink.heap.cons(items[i], result);
    }
    return result;
}

/// `(quote datum)`, which `'datum` abbreviates (R7RS 2.4).
fn quoted(sink: Sink, datum: Value) Error!Value {
    const quote_symbol: Value = .fromSymbol(try sink.symbols.intern(sink.alloc, "quote"));
    const tail = try sink.heap.cons(datum, Value.empty_list_value);
    return sink.heap.cons(quote_symbol, tail);
}

// Why: R7RS 7.1.1 の <boolean> は `#t`、`#f`、`#true`、`#false` である。
fn booleanOf(token: []const u8) ?bool {
    if (std.mem.eql(u8, token, "#t") or std.mem.eql(u8, token, "#true")) return true;
    if (std.mem.eql(u8, token, "#f") or std.mem.eql(u8, token, "#false")) return false;
    return null;
}

// Why: R7RS 7.1.1 は、空白を、行内の空白(スペース、タブ)と改行とに定めている。
// CR は CRLF による改行の一部である。
fn isWhitespace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}

// Why: R7RS 7.1.1 の <delimiter> は、空白、縦線、丸括弧、二重引用符、セミコロンである。
fn isDelimiter(c: u8) bool {
    return isWhitespace(c) or c == '|' or c == '(' or c == ')' or c == '"' or c == ';';
}

/// `[+-]?[0-9]+`.
/// ほかの数の構文は、数値タワーと一緒に入る。
fn isDecimalInteger(token: []const u8) bool {
    const digits = if (token[0] == '+' or token[0] == '-') token[1..] else token;
    if (digits.len == 0) return false;
    for (digits) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

/// Numbers whose syntax matches a <peculiar identifier> but which R7RS 7.1.1
/// reads as numbers: <infnan> and the complex units `+i` and `-i`.
/// これらは段階4で数値タワーと一緒に入る。それまでは、プログラムが束縛できる識別子として
/// 読まずに、拒否する。ほかの数の構文(`1.5`、`1/2`、`#x1F`)は識別子の形をしていないので、
/// `isIdentifier` がすでに拒否している。
fn isUnsupportedNumber(token: []const u8) bool {
    for ([_][]const u8{ "+inf.0", "-inf.0", "+nan.0", "-nan.0", "+i", "-i" }) |n| {
        if (std.ascii.eqlIgnoreCase(token, n)) return true;
    }
    return false;
}

// Why: R7RS 7.1.1 の <identifier> を、ASCII に限り、`|...|` の形を除いて実装している。
// <initial> に <subsequent> が続くものか、<peculiar identifier> である。整数は、
// これを尋ねる前に判別してあり、識別子の形をしたほかの数は `isUnsupportedNumber` が
// 引き受ける。
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
    // `.` <dot subsequent> <subsequent>*。手前の符号はあってもなくてもよい。
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
    heap: Heap,
    symbols: symbol.Table = .{},

    fn init() Fixture {
        return .{ .arena = .init(std.testing.allocator), .heap = .init(std.heap.smp_allocator, .{}) };
    }

    fn deinit(self: *Fixture) void {
        self.heap.deinit();
        self.arena.deinit();
    }

    fn sink(self: *Fixture) Sink {
        return .{ .alloc = self.arena.allocator(), .heap = &self.heap, .symbols = &self.symbols };
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
    // 識別子は大文字と小文字を区別する(R7RS 2.1)。
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
    // `'a` と `(quote a)` は同じデータである。
    try std.testing.expectEqualStrings(try f.roundTrip("(quote a)", &buf), "(quote a)");
}

test "next reads a dotted pair and a dotted tail" {
    var f: Fixture = .init();
    defer f.deinit();
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("(1 . 2)", try f.roundTrip("(1 . 2)", &buf));
    try std.testing.expectEqualStrings("(1 2 . 3)", try f.roundTrip("(1 2 . 3)", &buf));
    try std.testing.expectEqualStrings("(a b c)", try f.roundTrip("(a . (b c))", &buf));
    try std.testing.expectEqualStrings("(a)", try f.roundTrip("(a . ())", &buf));
    try std.testing.expectEqualStrings("(1 2)", try f.roundTrip("(1 .(2))", &buf));
    try std.testing.expectEqualStrings("(a quote b)", try f.roundTrip("(a . 'b)", &buf));
    // ドットは単独のトークンである。これらは識別子だ。
    try std.testing.expectEqualStrings("(a ... .b)", try f.roundTrip("(a ... .b)", &buf));
    const pair = (try f.readOne("(1 . 2)")).asPair().?;
    try std.testing.expectEqual(1, pair.car.asFixnum().?);
    try std.testing.expectEqual(2, pair.cdr.asFixnum().?);
}

test "next rejects a dot that is not between an element and one datum" {
    var f: Fixture = .init();
    defer f.deinit();
    for ([_][]const u8{ ".", "'.", "( . 1)", "(1 . )", "(1 . 2 3)", "(1 . . 2)", "(1 . 2 .)", "(. )", "(1 . ' )" }) |src| {
        if (f.readOne(src)) |_| {
            std.debug.print("accepted {s}\n", .{src});
            return error.TestUnexpectedResult;
        } else |e| {
            if (e != error.UnexpectedDot and e != error.MissingDatum) {
                std.debug.print("{s}: {s}\n", .{ src, @errorName(e) });
                return error.TestUnexpectedResult;
            }
        }
    }
    // 未完了は誤りではない。
    var r: Reader = .init("(1 . 2");
    try std.testing.expectError(error.Incomplete, r.next(f.arena.allocator(), f.sink()));
    var r2: Reader = .init("(1 .");
    try std.testing.expectError(error.Incomplete, r2.next(f.arena.allocator(), f.sink()));
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
    // readOne ではなく `next` そのものを使う。readOne は、データがないことを Incomplete にしてしまう。
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
    for ([_][]const u8{ "1+", "12a", "#tru", "#T", "#", "#)", "|x|", "+.1", "a'b" }) |src| {
        try std.testing.expectError(error.InvalidToken, f.readOne(src));
    }
}

test "next skips a line comment up to the end of the line" {
    var f: Fixture = .init();
    defer f.deinit();
    var buf: [64]u8 = undefined;
    try std.testing.expectEqual(1, (try f.readOne("1 ; コメント")).asFixnum().?);
    try std.testing.expectEqual(1, (try f.readOne("; 前\n1")).asFixnum().?);
    // コメントを終わらせるのは改行だけで、そこで読み取りは続きから再開する。
    try std.testing.expectEqualStrings("(+ 1 2)", try f.roundTrip("(+ 1 ; ここ\n 2)", &buf));
    try std.testing.expectEqualStrings("(+ 1 2)", try f.roundTrip("(+ 1 ; ここ\r\n 2)", &buf));
    // コメントの中の括弧・引用符・`;` は何も開閉しない。
    try std.testing.expectEqualStrings("(a b)", try f.roundTrip("(a ; ( ) \" ' ; #|\nb)", &buf));
    // コメントは、データのあいだのどこにでも置ける。
    try std.testing.expectEqualStrings("(quote a)", try f.roundTrip("'; c\na", &buf));
    try std.testing.expectEqualStrings("(1 . 2)", try f.roundTrip("(1 ;a\n. ;b\n2 ;c\n)", &buf));
    try std.testing.expectEqualStrings("#(1 2)", try f.roundTrip("#(1 ;a\n2)", &buf));
    // 空白だけの行とコメントだけの行が続いても、次のデータに届く。
    try std.testing.expectEqualStrings("x", try f.roundTrip(";a\n\n  ;b\n\t;c\nx", &buf));
}

test "next ends an identifier, a number and a boolean at a semicolon" {
    var f: Fixture = .init();
    defer f.deinit();
    const a = f.arena.allocator();
    // `;` は区切り文字なので、トークンはそこで終わり、残りはコメントである。
    try std.testing.expectEqualStrings("abc", f.symbols.nameOf((try f.readOne("abc;コメント")).asSymbol().?));
    try std.testing.expectEqual(12, (try f.readOne("12;コメント")).asFixnum().?);
    try std.testing.expect((try f.readOne("#t;コメント")).isTrue());
    var r: Reader = .init("a;b\nc");
    try std.testing.expectEqualStrings("a", f.symbols.nameOf((try r.next(a, f.sink())).?.asSymbol().?));
    try std.testing.expectEqualStrings("c", f.symbols.nameOf((try r.next(a, f.sink())).?.asSymbol().?));
    try std.testing.expect(try r.next(a, f.sink()) == null);
}

test "next reads an input of nothing but comments as no data" {
    var f: Fixture = .init();
    defer f.deinit();
    const a = f.arena.allocator();
    for ([_][]const u8{ ";", "; コメント", ";\n", "; a\n; b\n", "  ;a\n\n;b", ";\r\n;" }) |src| {
        var r: Reader = .init(src);
        try std.testing.expect(try r.next(a, f.sink()) == null);
    }
}

test "next reports an unfinished datum when a comment hides the rest" {
    var f: Fixture = .init();
    defer f.deinit();
    const a = f.arena.allocator();
    // `)` がコメントの中にあれば、閉じていない。
    for ([_][]const u8{ "(+ 1 ; )", "(+ 1 2 ;)\n", "'; a", "(1 . ; c", "#(1 ; )" }) |src| {
        var r: Reader = .init(src);
        try std.testing.expectError(error.Incomplete, r.next(a, f.sink()));
    }
    // コメントは行の終わりまでなので、次の行の `)` は閉じる。
    try std.testing.expectEqual(.pair, (try f.readOne("(+ 1 ; (\n)")).kind());
}

test "next does not read a semicolon in a string or a character as a comment" {
    var f: Fixture = .init();
    defer f.deinit();
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("\"a;b\"", try f.roundTrip("\"a;b\"", &buf));
    try std.testing.expectEqualStrings("\";\"", try f.roundTrip("\";\" ; 後", &buf));
    // 文字列は複数行にまたがってよく、その中の `;` は行末まででも文字列の一部である。
    try std.testing.expectEqualStrings("\"a ; b\\nc\"", try f.roundTrip("\"a ; b\nc\"", &buf));
    try std.testing.expectEqual(';', (try f.readOne("#\\;")).asCharacter().?);
    try std.testing.expectEqual(';', (try f.readOne("#\\; ; 後")).asCharacter().?);
    try std.testing.expectEqualStrings("(#\\; 1)", try f.roundTrip("(#\\; 1)", &buf));
    try std.testing.expectEqualStrings("(\"x\" 1)", try f.roundTrip("(\"x\" ; ( \n 1)", &buf));
    // 文字や文字列のすぐ後の `;` は、やはりコメントを始める。
    try std.testing.expectEqual(';', (try f.readOne("#\\;;後")).asCharacter().?);
    try std.testing.expectEqual('a', (try f.readOne("#\\a;後")).asCharacter().?);
    try std.testing.expectEqualStrings("\"x\"", try f.roundTrip("\"x\";後", &buf));
    try std.testing.expectEqualStrings("(\"x\" #\\;)", try f.roundTrip("(\"x\";(\n#\\;)", &buf));
}

test "next still rejects block comments and datum comments" {
    var f: Fixture = .init();
    defer f.deinit();
    // 段階5まで入らない。行コメントの導入で、読めるようになってはならない。
    for ([_][]const u8{ "#|x|#", "#| x", "#;1", "#; 1", "(#;1)" }) |src| {
        try std.testing.expectError(error.InvalidToken, f.readOne(src));
    }
}

test "next rejects the numbers that are spelled like peculiar identifiers" {
    var f: Fixture = .init();
    defer f.deinit();
    for ([_][]const u8{ "+inf.0", "-inf.0", "+nan.0", "-nan.0", "+i", "-i", "+INF.0" }) |src| {
        try std.testing.expectError(error.InvalidToken, f.readOne(src));
    }
    // 綴りの近いものは、識別子のままである。
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
    // 一番内側の `()` は空リストなので、ペアの数は括弧の対の数より 1 つ少ない。
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

test "next reads a vector of data, the empty vector and nesting" {
    var f: Fixture = .init();
    defer f.deinit();
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("#(1 2 3)", try f.roundTrip(" #(1\t2\r\n3) ", &buf));
    try std.testing.expectEqualStrings("#()", try f.roundTrip("#()", &buf));
    try std.testing.expectEqualStrings("#()", try f.roundTrip("#( )", &buf));
    try std.testing.expectEqualStrings("#(a #t -1)", try f.roundTrip("#(a #t -1)", &buf));
    try std.testing.expectEqualStrings("#(1 #(2 3) ())", try f.roundTrip("#(1 #(2 3) ())", &buf));
    try std.testing.expectEqualStrings("#(#(#()))", try f.roundTrip("#(#(#()))", &buf));
    try std.testing.expectEqualStrings("(1 #(2) (3 #()))", try f.roundTrip("(1 #(2) (3 #()))", &buf));
    try std.testing.expectEqualStrings("#((1 . 2) (3 4 . 5))", try f.roundTrip("#((1 . 2) (3 4 . 5))", &buf));
    try std.testing.expectEqualStrings("(a . #(1))", try f.roundTrip("(a . #(1))", &buf));
    // `(` は区切り文字なので、ベクタは別のデータのすぐ後に続けてよい。
    try std.testing.expectEqualStrings("(#(1) #(2))", try f.roundTrip("(#(1)#(2))", &buf));
    const v = try f.readOne("#(1 2)");
    try std.testing.expectEqual(.vector, v.kind());
    try std.testing.expectEqual(2, v.asVector().?.items.len);
    try std.testing.expectEqual(2, v.asVector().?.items[1].asFixnum().?);
}

test "next reads a quote before and inside a vector" {
    var f: Fixture = .init();
    defer f.deinit();
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("(quote #(1 2))", try f.roundTrip("'#(1 2)", &buf));
    try std.testing.expectEqualStrings("#((quote a) b)", try f.roundTrip("#('a b)", &buf));
    try std.testing.expectEqualStrings("#((quote #(1)))", try f.roundTrip("#('#(1))", &buf));
    try std.testing.expectEqualStrings("(quote (quote #()))", try f.roundTrip("''#()", &buf));
}

test "next reports a dot in a vector" {
    var f: Fixture = .init();
    defer f.deinit();
    for ([_][]const u8{ "#(1 . 2)", "#(. 1)", "#(1 .)", "#(.)", "'#(a . b)", "#(1 (2) . 3)", "(#(1 . 2))" }) |src| {
        try std.testing.expectError(error.UnexpectedDot, f.readOne(src));
    }
    // ベクタの中のリストにあるドットは、やはりそのリスト自身のものである。
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("#((1 . 2))", try f.roundTrip("#((1 . 2))", &buf));
    // `...` と `.a` は、ベクタの中でも識別子である。
    try std.testing.expectEqualStrings("#(... .a)", try f.roundTrip("#(... .a)", &buf));
}

test "next tells an unclosed vector from a stray close paren" {
    var f: Fixture = .init();
    defer f.deinit();
    const a = f.arena.allocator();
    for ([_][]const u8{ "#(", "#(1 2", "#(1 (2)", "(#(1)", "#(#(1)", "#('", "#(1 'a" }) |src| {
        var r: Reader = .init(src);
        try std.testing.expectError(error.Incomplete, r.next(a, f.sink()));
    }
    try std.testing.expectError(error.UnexpectedCloseParen, f.readOne("#(1 2))"));
    try std.testing.expectError(error.MissingDatum, f.readOne("#(')"));
    // `#(` でも `#\` でもない `#` は、やはりデータではない。
    try std.testing.expectError(error.InvalidToken, f.readOne("#"));
    try std.testing.expectError(error.InvalidToken, f.readOne("#)"));
    try std.testing.expectError(error.InvalidToken, f.readOne("#u8(1)"));
}

test "next reads vectors nested far deeper than a recursive reader could" {
    var f: Fixture = .init();
    defer f.deinit();
    const depth = 100_000;
    const src = try f.arena.allocator().alloc(u8, depth * 3);
    for (0..depth) |k| @memcpy(src[2 * k ..][0..2], "#(");
    @memset(src[depth * 2 ..], ')');
    var d = try f.readOne(src);
    // 一番内側の `#()` には要素がないので、連なるベクタは `depth` 個で、その間の
    // つながりは 1 つ少ない。
    var vectors: usize = 0;
    while (d.asVector()) |v| : (vectors += 1) {
        if (v.items.len == 0) break;
        d = v.items[0];
    }
    try std.testing.expectEqual(depth - 1, vectors);
    try std.testing.expectEqual(.vector, d.kind());
}

test "next reads a long vector" {
    var f: Fixture = .init();
    defer f.deinit();
    const n = 100_000;
    const src = try f.arena.allocator().alloc(u8, 2 * n + 3);
    @memcpy(src[0..2], "#(");
    for (0..n) |k| {
        src[2 + 2 * k] = '1';
        src[3 + 2 * k] = ' ';
    }
    src[2 * n + 2] = ')';
    const v = try f.readOne(src);
    try std.testing.expectEqual(n, v.asVector().?.items.len);
}
