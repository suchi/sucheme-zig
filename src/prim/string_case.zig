//! Case conversion and case-insensitive comparison of strings (R7RS 6.7, the strings of
//! `(scheme char)`).
//!
//! `string-upcase` `string-downcase` `string-foldcase` は、Unicode の完全な大文字小文字の
//! 写像(`src/unicode/props.zig` の `fullUpcase` など)を文字ごとに当てる。結果の文字数は、
//! 元の文字数と違いうる(`ß` の大文字は `SS` の2文字、`İ` の小文字は `i` と結合文字の2文字)。
//! `string-ci=?` などは、`string-foldcase` を当てた文字列を比べるのと同じ答えを、畳み込んだ
//! 文字列を作らずに返す。
//!
//! R7RS 6.7 は、言語に依存する写像を使わないことと、`string-downcase` が語末のシグマ(`Σ`
//! の小文字は語末で `ς`)を扱わなくてよいことを定めている。ここでは扱わず、`Σ` はいつも `σ`
//! になる。表(`SpecialCasing.txt`)の条件つきの行は読んでいない。
//!
//! 結果は、元と等しくても新しい文字列である(R7RS 6.7 は、等しければ元の文字列を返してよい、
//! としている)。入力の大きさに比例して確保するので、`string.zig` と同じく、確保する領域を先に
//! 上限に照らして検査し、領域へ直接書く。

const std = @import("std");
const value = @import("../value.zig");
const Value = value.Value;
const Primitive = value.Primitive;
const Services = value.Services;
const PrimitiveError = value.PrimitiveError;
const props = @import("../unicode/props.zig");

pub const Error = PrimitiveError;

pub const primitives = [_]Primitive{
    .{ .name = "string-upcase", .min_args = 1, .max_args = 1, .body = .{ .pure = convert(.upcase) } },
    .{ .name = "string-downcase", .min_args = 1, .max_args = 1, .body = .{ .pure = convert(.downcase) } },
    .{ .name = "string-foldcase", .min_args = 1, .max_args = 1, .body = .{ .pure = convert(.foldcase) } },
    .{ .name = "string-ci=?", .min_args = 1, .max_args = null, .body = .{ .pure = foldedComparison(.eq) } },
    .{ .name = "string-ci<?", .min_args = 1, .max_args = null, .body = .{ .pure = foldedComparison(.lt) } },
    .{ .name = "string-ci>?", .min_args = 1, .max_args = null, .body = .{ .pure = foldedComparison(.gt) } },
    .{ .name = "string-ci<=?", .min_args = 1, .max_args = null, .body = .{ .pure = foldedComparison(.lte) } },
    .{ .name = "string-ci>=?", .min_args = 1, .max_args = null, .body = .{ .pure = foldedComparison(.gte) } },
};

const Conversion = enum { upcase, downcase, foldcase };

/// Writes the full mapping of `c` under `conv` to `out`, and returns how many characters it has.
fn mapped(conv: Conversion, c: u21, out: *[3]u21) u2 {
    return switch (conv) {
        .upcase => props.fullUpcase(c, out),
        .downcase => props.fullDowncase(c, out),
        .foldcase => props.fullFoldcase(c, out),
    };
}

/// The bytes the converted `source` takes.
fn convertedWidth(source: []const u8, conv: Conversion) Error!usize {
    var total: usize = 0;
    var it = std.unicode.Utf8View.initUnchecked(source).iterator();
    var out: [3]u21 = undefined;
    while (it.nextCodepoint()) |c| {
        const n = mapped(conv, c, &out);
        for (out[0..n]) |m| {
            total = std.math.add(usize, total, std.unicode.utf8CodepointSequenceLength(m) catch unreachable) catch return error.HeapLimit;
        }
    }
    return total;
}

/// Writes `source` converted under `conv` as UTF-8, into the bytes that `convertedWidth` counted.
const Converter = struct {
    source: []const u8,
    conv: Conversion,

    pub fn fill(self: Converter, bytes: []u8) void {
        var it = std.unicode.Utf8View.initUnchecked(self.source).iterator();
        var out: [3]u21 = undefined;
        var i: usize = 0;
        while (it.nextCodepoint()) |c| {
            const n = mapped(self.conv, c, &out);
            for (out[0..n]) |m| i += std.unicode.utf8Encode(m, bytes[i..]) catch unreachable;
        }
    }
};

/// `(string-upcase string)`, `(string-downcase string)` and `(string-foldcase string)` (R7RS
/// 6.7): a new string of the characters under the full mapping.
fn convert(comptime conv: Conversion) Primitive.Fn {
    return &struct {
        fn call(services: *const Services, args: []const Value) Error!Value {
            const s = args[0].asString() orelse return error.WrongType;
            const width = try convertedWidth(s.bytes, conv);
            return .fromString(try services.heap.createStringFilled(width, Converter{ .source = s.bytes, .conv = conv }));
        }
    }.call;
}

/// The characters of a string under the full case folding, one at a time.
const FoldedChars = struct {
    it: std.unicode.Utf8Iterator,
    pending: [3]u21 = undefined,
    count: u2 = 0,
    next_index: u2 = 0,

    fn init(bytes: []const u8) FoldedChars {
        return .{ .it = std.unicode.Utf8View.initUnchecked(bytes).iterator() };
    }

    fn next(self: *FoldedChars) ?u21 {
        if (self.next_index == self.count) {
            const c = self.it.nextCodepoint() orelse return null;
            self.count = props.fullFoldcase(c, &self.pending);
            self.next_index = 0;
        }
        const folded = self.pending[self.next_index];
        self.next_index += 1;
        return folded;
    }
};

/// The order of two strings after `string-foldcase` is applied to them: lexicographic by
/// character, and a string that is a prefix of the other is the smaller.
fn foldedOrder(a: []const u8, b: []const u8) std.math.Order {
    var x: FoldedChars = .init(a);
    var y: FoldedChars = .init(b);
    while (true) {
        const p = x.next();
        const q = y.next();
        if (p == null and q == null) return .eq;
        if (p == null) return .lt;
        if (q == null) return .gt;
        const order = std.math.order(p.?, q.?);
        if (order != .eq) return order;
    }
}

/// `(string-ci=? string1 string2 string3 ...)` and the other four comparisons (R7RS 6.7): the
/// same as `string=?` and the others, after `string-foldcase` is applied to the arguments.
///
/// `string.zig` の `comparison` と同じ形である。最初に成り立たなかった組より後のものも含め、
/// すべての引数が文字列であることを検査する。
fn foldedComparison(comptime op: std.math.CompareOperator) Primitive.Fn {
    return &struct {
        fn call(_: *const Services, args: []const Value) Error!Value {
            for (args) |a| _ = a.asString() orelse return error.WrongType;
            var holds = true;
            for (args[0 .. args.len - 1], args[1..]) |a, b| {
                const order = foldedOrder(a.asString().?.bytes, b.asString().?.bytes);
                if (!order.compare(op)) holds = false;
            }
            return .fromBool(holds);
        }
    }.call;
}

test {
    std.testing.refAllDecls(@This());
}

const test_support = @import("test_support.zig");
const heap_mod = @import("../heap.zig");

fn call(f: *test_support.Fixture, name: []const u8, args: []const Value) Error!Value {
    return f.call(&primitives, name, args);
}

fn str(f: *test_support.Fixture, content: []const u8) !Value {
    return .fromString(try f.heap.createString(content));
}

/// Checks that `result` is the string `expected`, with the flag its characters call for.
fn expectString(expected: []const u8, result: Value) !void {
    try std.testing.expectEqual(value.Kind.string, result.kind());
    try std.testing.expectEqualStrings(expected, result.asString().?.bytes);
    try std.testing.expectEqual(value.allAscii(expected), result.asString().?.is_ascii);
}

/// `name` applied to the string with the contents `content`.
fn convertString(f: *test_support.Fixture, name: []const u8, content: []const u8) !Value {
    return call(f, name, &.{try str(f, content)});
}

test "the primitives take the numbers of arguments the language gives them" {
    const Arity = struct { name: []const u8, min: u8, max: ?u8 };
    const expected = [_]Arity{
        .{ .name = "string-upcase", .min = 1, .max = 1 },
        .{ .name = "string-downcase", .min = 1, .max = 1 },
        .{ .name = "string-foldcase", .min = 1, .max = 1 },
        .{ .name = "string-ci=?", .min = 1, .max = null },
        .{ .name = "string-ci<?", .min = 1, .max = null },
        .{ .name = "string-ci>?", .min = 1, .max = null },
        .{ .name = "string-ci<=?", .min = 1, .max = null },
        .{ .name = "string-ci>=?", .min = 1, .max = null },
    };
    try std.testing.expectEqual(expected.len, primitives.len);
    for (expected, primitives) |e, p| {
        try std.testing.expectEqualStrings(e.name, p.name);
        try std.testing.expectEqual(e.min, p.min_args);
        try std.testing.expectEqual(e.max, p.max_args);
    }
}

test "string-upcase applies the full uppercase mapping, and the length can change" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    try expectString("", try convertString(&f, "string-upcase", ""));
    try expectString("ABC DEF 123!", try convertString(&f, "string-upcase", "abc dEf 123!"));
    // ß は SS になり、文字数が増える。
    const sharp = try convertString(&f, "string-upcase", "straße");
    try expectString("STRASSE", sharp);
    try std.testing.expectEqual(7, sharp.asString().?.length());
    // 結果が3文字になる文字、結合文字が付く文字、合字。
    try expectString("\u{399}\u{308}\u{301}", try convertString(&f, "string-upcase", "\u{390}"));
    try expectString("\u{2BC}N", try convertString(&f, "string-upcase", "\u{149}"));
    try expectString("FFI", try convertString(&f, "string-upcase", "\u{FB03}"));
    // 幅の違う文字が混ざる。
    try expectString("AΛ\u{10400}", try convertString(&f, "string-upcase", "aλ\u{10428}"));
    // 語末のシグマの小文字は、大文字では普通のシグマと同じ大文字になる。
    try expectString("ΧΑΟΣ", try convertString(&f, "string-upcase", "χαος"));
}

test "string-downcase applies the full lowercase mapping and does not treat the final sigma" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    try expectString("abc def", try convertString(&f, "string-downcase", "ABC dEf"));
    // İ は i と結合文字(U+0307)の2文字になる。
    try expectString("i\u{307}", try convertString(&f, "string-downcase", "\u{130}"));
    // R7RS 6.7: 語末のシグマを特別に扱わなくてよい。ここでは、いつも σ になる。
    try expectString("χαοσ", try convertString(&f, "string-downcase", "ΧΑΟΣ"));
    try expectString("σ σσ", try convertString(&f, "string-downcase", "Σ ΣΣ"));
    // 小文字の ς は、そのまま残る。
    try expectString("χαος", try convertString(&f, "string-downcase", "χαος"));
}

test "string-foldcase applies the full case folding" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    try expectString("strasse", try convertString(&f, "string-foldcase", "Straße"));
    try expectString("strasse", try convertString(&f, "string-foldcase", "STRASSE"));
    try expectString("ss", try convertString(&f, "string-foldcase", "\u{1E9E}"));
    // 語末のシグマも、σ に畳み込まれる。
    try expectString("σασ", try convertString(&f, "string-foldcase", "ΣΑΣ"));
    try expectString("σασ", try convertString(&f, "string-foldcase", "σας"));
    try expectString("i\u{307}", try convertString(&f, "string-foldcase", "\u{130}"));
    try expectString("ff", try convertString(&f, "string-foldcase", "\u{FB00}"));
    try expectString("", try convertString(&f, "string-foldcase", ""));
}

test "the conversions give a new string that can be written, even for a constant" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    const constant = try str(&f, "abc");
    heap_mod.makeImmutable(constant);
    for ([_][]const u8{ "string-upcase", "string-downcase", "string-foldcase" }) |name| {
        const r = try call(&f, name, &.{constant});
        try std.testing.expect(r.asString() != constant.asString());
        try std.testing.expect(!heap_mod.isImmutable(r));
        try std.testing.expect(heap_mod.isImmutable(constant));
    }
    // 元は変わらない。
    try expectString("abc", constant);
}

test "the conversions report an argument that is not a string" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    for ([_][]const u8{ "string-upcase", "string-downcase", "string-foldcase" }) |name| {
        try std.testing.expectError(error.WrongType, call(&f, name, &.{.fromCharacter('a')}));
        try std.testing.expectError(error.WrongType, call(&f, name, &.{.fromFixnum(97)}));
        try std.testing.expectError(error.WrongType, call(&f, name, &.{.empty_list_value}));
    }
}

test "a conversion that does not fit the limit leaves the heap as it was" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    const s = try str(&f, "ßß");
    const before = f.heap.accounted;
    // 結果は 4 バイトで、元の 4 バイトと同じ。上限を、結果の領域に 1 バイト足りなくする。
    f.heap.options.limit = before + heap_mod.cellBytes(value.String) + 3;
    try std.testing.expectError(error.HeapLimit, call(&f, "string-upcase", &.{s}));
    try std.testing.expectEqual(before, f.heap.accounted);
    f.heap.options.limit = before + heap_mod.cellBytes(value.String) + 4;
    try expectString("SSSS", try call(&f, "string-upcase", &.{s}));
}

/// The result of the comparison `name` of the strings with the contents `contents`.
fn compareStrings(f: *test_support.Fixture, name: []const u8, contents: []const []const u8) !bool {
    var args: [8]Value = undefined;
    for (contents, 0..) |c, i| args[i] = try str(f, c);
    const r = try call(f, name, args[0..contents.len]);
    try std.testing.expectEqual(value.Kind.boolean, r.kind());
    return r.isTrue();
}

test "the case-insensitive comparisons ignore the case" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    try std.testing.expect(try compareStrings(&f, "string-ci=?", &.{ "abc", "ABC", "aBc" }));
    try std.testing.expect(!try compareStrings(&f, "string-ci=?", &.{ "abc", "abd" }));
    try std.testing.expect(try compareStrings(&f, "string-ci=?", &.{ "", "" }));
    // 長さが違えば等しくない。
    try std.testing.expect(!try compareStrings(&f, "string-ci=?", &.{ "abc", "abcd" }));
    // 畳み込みの結果で比べる。ß は ss に、語末のシグマは σ に畳み込まれる。
    try std.testing.expect(try compareStrings(&f, "string-ci=?", &.{ "Straße", "STRASSE", "strasse" }));
    try std.testing.expect(try compareStrings(&f, "string-ci=?", &.{ "ΣΑΣ", "σας", "σασ" }));
    // 畳み込んだ文字列が途中で分かれても、先頭の文字だけで決まらない。
    try std.testing.expect(!try compareStrings(&f, "string-ci=?", &.{ "ß", "s" }));
    try std.testing.expect(try compareStrings(&f, "string-ci>?", &.{ "ß", "s" }));
    try std.testing.expect(try compareStrings(&f, "string-ci<?", &.{ "ß", "st" }));
}

test "the case-insensitive orderings follow the folded characters" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    const Row = struct { name: []const u8, less: bool, equal: bool, greater: bool };
    const rows = [_]Row{
        .{ .name = "string-ci=?", .less = false, .equal = true, .greater = false },
        .{ .name = "string-ci<?", .less = true, .equal = false, .greater = false },
        .{ .name = "string-ci>?", .less = false, .equal = false, .greater = true },
        .{ .name = "string-ci<=?", .less = true, .equal = true, .greater = false },
        .{ .name = "string-ci>=?", .less = false, .equal = true, .greater = true },
    };
    const Pair = struct { small: []const u8, big: []const u8 };
    const pairs = [_]Pair{
        .{ .small = "a", .big = "B" },
        .{ .small = "Abc", .big = "abd" },
        // 短いほうが小さい。
        .{ .small = "ab", .big = "ABC" },
        .{ .small = "", .big = "a" },
        // '_' (0x5F) は、畳み込むと小文字になる 'A' (0x41 → 0x61) より前になる。
        .{ .small = "_", .big = "A" },
        // ASCII の外も、畳み込んだ文字のコードポイントの順である。
        .{ .small = "z", .big = "Ω" },
        .{ .small = "Σ", .big = "ω" },
    };
    for (rows) |r| {
        for (pairs) |p| {
            errdefer std.debug.print("{s} {s} {s}\n", .{ r.name, p.small, p.big });
            try std.testing.expectEqual(r.less, try compareStrings(&f, r.name, &.{ p.small, p.big }));
            try std.testing.expectEqual(r.greater, try compareStrings(&f, r.name, &.{ p.big, p.small }));
            try std.testing.expectEqual(r.equal, try compareStrings(&f, r.name, &.{ p.small, p.small }));
        }
    }
}

test "the case-insensitive comparisons take any number of strings" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    try std.testing.expect(try compareStrings(&f, "string-ci<?", &.{ "a", "B", "c", "D" }));
    try std.testing.expect(!try compareStrings(&f, "string-ci<?", &.{ "a", "B", "b" }));
    try std.testing.expect(try compareStrings(&f, "string-ci<=?", &.{ "a", "A", "b", "B" }));
    try std.testing.expect(try compareStrings(&f, "string-ci>=?", &.{ "D", "c", "C", "a" }));
    try std.testing.expect(!try compareStrings(&f, "string-ci>?", &.{ "d", "b", "c" }));
    for ([_][]const u8{ "string-ci=?", "string-ci<?", "string-ci>?", "string-ci<=?", "string-ci>=?" }) |name| {
        try std.testing.expect(try compareStrings(&f, name, &.{"a"}));
    }
}

test "the case-insensitive comparisons of strings that fold to the same string" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    const same = [_][2][]const u8{
        .{ "a", "A" },
        .{ "ΣΑΣ", "σας" },
        .{ "Straße", "STRASSE" },
        .{ "\u{FB03}", "ffi" },
    };
    for (same) |p| {
        errdefer std.debug.print("{s} {s}\n", .{ p[0], p[1] });
        try std.testing.expect(!try compareStrings(&f, "string-ci<?", &p));
        try std.testing.expect(!try compareStrings(&f, "string-ci>?", &p));
        try std.testing.expect(try compareStrings(&f, "string-ci<=?", &p));
        try std.testing.expect(try compareStrings(&f, "string-ci>=?", &p));
        try std.testing.expect(try compareStrings(&f, "string-ci=?", &p));
    }
}

test "a case-insensitive comparison needs every neighboring pair to hold, not only the last" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    // 成り立たない組のあとに、成り立つ組が来る。
    try std.testing.expect(!try compareStrings(&f, "string-ci<?", &.{ "b", "a", "c" }));
    try std.testing.expect(!try compareStrings(&f, "string-ci=?", &.{ "a", "b", "b" }));
    try std.testing.expect(!try compareStrings(&f, "string-ci>?", &.{ "a", "b", "a" }));
    try std.testing.expect(!try compareStrings(&f, "string-ci<=?", &.{ "b", "a", "c" }));
    try std.testing.expect(!try compareStrings(&f, "string-ci>=?", &.{ "a", "b", "a" }));
    // 成り立つ組のあとに、成り立たない組が来る。
    try std.testing.expect(!try compareStrings(&f, "string-ci<?", &.{ "a", "c", "b" }));
    try std.testing.expect(!try compareStrings(&f, "string-ci=?", &.{ "a", "A", "b" }));
}

test "a ligature that folds to three characters" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    // U+FB03 (ffi の合字)は、畳み込むと f、f、i の3文字になる。
    const folded = try convertString(&f, "string-foldcase", "\u{FB03}");
    try expectString("ffi", folded);
    try std.testing.expectEqual(3, folded.asString().?.length());
    try std.testing.expect(try compareStrings(&f, "string-ci=?", &.{ "\u{FB03}", "ffi" }));
    try std.testing.expect(!try compareStrings(&f, "string-ci=?", &.{ "\u{FB03}", "ff" }));
    try std.testing.expect(!try compareStrings(&f, "string-ci=?", &.{ "\u{FB03}", "ffij" }));
    // 畳み込んだ文字列が、短いほうが小さい順序で並ぶ。
    try std.testing.expect(try compareStrings(&f, "string-ci>?", &.{ "\u{FB03}", "ff" }));
    try std.testing.expect(try compareStrings(&f, "string-ci<?", &.{ "\u{FB03}", "ffj" }));
}

test "the case-insensitive comparisons check every argument for being a string" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    for ([_][]const u8{ "string-ci=?", "string-ci<?", "string-ci>?", "string-ci<=?", "string-ci>=?" }) |name| {
        const a = try str(&f, "a");
        const b = try str(&f, "b");
        try std.testing.expectError(error.WrongType, call(&f, name, &.{ a, .fromFixnum(97) }));
        try std.testing.expectError(error.WrongType, call(&f, name, &.{.fromFixnum(97)}));
        try std.testing.expectError(error.WrongType, call(&f, name, &.{.fromCharacter('a')}));
        // 最初の組が成り立たなくても、3つ目の誤りが報告される。エラーは値に左右されない。
        try std.testing.expectError(error.WrongType, call(&f, name, &.{ b, a, a, .fromBool(true) }));
    }
}
