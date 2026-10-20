//! Splits Scheme source text into its top-level forms by bracket balance.
//!
//! 準拠スイート(tests/vendor/r7rs-tests.scm)を最上位の形式ごとに切り出す、純粋な走査器である。
//! インタプリタのリーダには頼らない。リーダが読めない字句(数の構文、データラベルなど)が
//! あると、REPL と同じ入口に流したとき、そのあとの入力がまとめてずれるからである
//! (docs/plans/0020-conformance-harness-early.md の「字句の切り出し」)。
//!
//! 知っている字句は、文字列、行コメント、入れ子のブロックコメント(`#|...|#`)、データの
//! コメント(`#;`)、文字(`#\(` など)、縦棒の識別子(`|...|`)、括弧(`(` `)` `[` `]`)
//! だけである。数やデータラベルの中身は読まず、区切りまでの1つの字句として飛ばす。
//! 字句として正しいかは見ない。それはリーダの仕事で、実行器がリーダの読んだ範囲と
//! この走査器の範囲を突き合わせる。

const std = @import("std");

/// One top-level form: where it is in the text.
pub const Chunk = struct {
    /// 形式の先頭の、テキストの中のバイトの位置。
    start: usize,
    /// 形式の末尾の次の位置(末尾は含まない)。
    end: usize,
    /// 形式の先頭の行の番号(1から)。
    line: u32,
};

/// Why the text cannot be split.
pub const SplitError = error{
    /// 閉じ括弧が開き括弧より多いか、テキストが括弧の内側で終わった。
    Unbalanced,
    UnterminatedString,
    UnterminatedBlockComment,
    /// `|` で始まる識別子が閉じない。
    UnterminatedIdentifier,
};

/// Returns the next top-level form at or after `pos`, or null when only
/// whitespace and comments remain.
pub fn next(text: []const u8, pos: usize) SplitError!?Chunk {
    const start = try skipAtmosphere(text, pos);
    if (start >= text.len) return null;
    const end = try datumEnd(text, start);
    // 1件ごとに先頭から数え直す。スイートの大きさでは費用が目立たず、状態を持たずに済む。
    const line = 1 + std.mem.count(u8, text[0..start], "\n");
    return .{ .start = start, .end = end, .line = @intCast(line) };
}

/// Skips whitespace, comments and datum comments, and returns where the next
/// datum or closing bracket starts, or the end of the text.
fn skipAtmosphere(text: []const u8, pos: usize) SplitError!usize {
    var i = pos;
    while (i < text.len) {
        const c = text[i];
        if (std.ascii.isWhitespace(c)) {
            i += 1;
        } else if (c == ';') {
            i = std.mem.indexOfScalarPos(u8, text, i, '\n') orelse text.len;
        } else if (startsWith(text, i, "#|")) {
            i = try blockCommentEnd(text, i);
        } else if (startsWith(text, i, "#;")) {
            // データのコメントは、次の1つのデータを、間の空白やコメントごと飛ばす。
            const d = try skipAtmosphere(text, i + 2);
            if (d >= text.len) return error.Unbalanced;
            i = try datumEnd(text, d);
        } else break;
    }
    return i;
}

/// Returns the end of the block comment that starts at `pos`, which nests.
fn blockCommentEnd(text: []const u8, pos: usize) SplitError!usize {
    var depth: usize = 0;
    var i = pos;
    while (i + 1 < text.len) {
        if (startsWith(text, i, "#|")) {
            depth += 1;
            i += 2;
        } else if (startsWith(text, i, "|#")) {
            depth -= 1;
            i += 2;
            if (depth == 0) return i;
        } else i += 1;
    }
    return error.UnterminatedBlockComment;
}

/// Returns the end of the datum that starts at `pos`, which is not atmosphere.
/// 終わりは必ず `pos` より後ろにある。長さ0のデータを返すと、呼び出し側のループが
/// 同じ位置で回り続けるので、ここで確かめて、止まらない走査を失敗に変える。
fn datumEnd(text: []const u8, pos: usize) SplitError!usize {
    const end = try datumEndUnchecked(text, pos);
    std.debug.assert(end > pos);
    return end;
}

fn datumEndUnchecked(text: []const u8, pos: usize) SplitError!usize {
    switch (text[pos]) {
        '(', '[' => return listEnd(text, pos),
        ')', ']' => return error.Unbalanced,
        '\'', '`' => return prefixedEnd(text, pos + 1),
        ',' => return prefixedEnd(text, if (startsWith(text, pos, ",@")) pos + 2 else pos + 1),
        '"' => return quotedEnd(text, pos, '"') orelse error.UnterminatedString,
        '|' => return quotedEnd(text, pos, '|') orelse error.UnterminatedIdentifier,
        '#' => return hashEnd(text, pos),
        else => return atomEnd(text, pos),
    }
}

/// Returns the end of the list or vector body whose opening bracket is at `pos`.
fn listEnd(text: []const u8, pos: usize) SplitError!usize {
    const close: u8 = if (text[pos] == '(') ')' else ']';
    var i = pos + 1;
    while (true) {
        i = try skipAtmosphere(text, i);
        if (i >= text.len) return error.Unbalanced;
        switch (text[i]) {
            ')', ']' => return if (text[i] == close) i + 1 else error.Unbalanced,
            else => i = try datumEnd(text, i),
        }
    }
}

/// Returns the end of the datum that a prefix such as `'` or a label applies to,
/// which starts at or after `pos`.
fn prefixedEnd(text: []const u8, pos: usize) SplitError!usize {
    const d = try skipAtmosphere(text, pos);
    if (d >= text.len) return error.Unbalanced;
    return datumEnd(text, d);
}

/// Returns the end of a string or a vertical-bar identifier that starts at
/// `pos`, or null when it does not close. A backslash escapes the next byte.
fn quotedEnd(text: []const u8, pos: usize, quote: u8) ?usize {
    var i = pos + 1;
    while (i < text.len) : (i += 1) {
        if (text[i] == '\\') {
            i += 1;
        } else if (text[i] == quote) return i + 1;
    }
    return null;
}

/// Returns the end of a datum that starts with `#` and is not a comment.
fn hashEnd(text: []const u8, pos: usize) SplitError!usize {
    if (pos + 1 >= text.len) return pos + 1;
    switch (text[pos + 1]) {
        // ベクタ。
        '(' => return listEnd(text, pos + 1),
        // 文字。`\` の次の1バイトは、区切りの文字でも文字の一部である(`#\(`)。
        '\\' => return if (pos + 2 >= text.len) pos + 2 else atomEnd(text, pos + 3),
        else => {},
    }
    const end = atomEnd(text, pos);
    const word = text[pos..end];
    // バイトベクタ(`#u8(`)と、データラベルの定義(`#0=`)は、後ろのデータまでが1つの形式である。
    if (std.mem.eql(u8, word, "#u8") and end < text.len and text[end] == '(') return listEnd(text, end);
    if (word.len > 2 and word[word.len - 1] == '=' and allDigits(word[1 .. word.len - 1])) return prefixedEnd(text, end);
    return end;
}

/// Returns the end of the run of bytes from `pos` up to a delimiter.
fn atomEnd(text: []const u8, pos: usize) usize {
    var i = pos;
    while (i < text.len and !isDelimiter(text[i])) i += 1;
    return i;
}

fn isDelimiter(c: u8) bool {
    return std.ascii.isWhitespace(c) or switch (c) {
        '(', ')', '[', ']', '"', ';', '|' => true,
        else => false,
    };
}

fn allDigits(s: []const u8) bool {
    for (s) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

fn startsWith(text: []const u8, pos: usize, prefix: []const u8) bool {
    return std.mem.startsWith(u8, text[pos..], prefix);
}

/// Collects every top-level form, for the tests.
fn splitAll(gpa: std.mem.Allocator, text: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var pos: usize = 0;
    while (try next(text, pos)) |c| {
        try out.append(gpa, text[c.start..c.end]);
        pos = c.end;
    }
    return out.toOwnedSlice(gpa);
}

fn expectForms(text: []const u8, want: []const []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const got = try splitAll(arena.allocator(), text);
    try std.testing.expectEqual(want.len, got.len);
    for (want, got) |w, g| try std.testing.expectEqualStrings(w, g);
}

test "forms are split at their balanced end, not at a line that starts with (" {
    // r7rs-tests.scm には、複数行の形式の途中で行頭に `(` が来る箇所がある。
    try expectForms("(test #f\n(letrec ((f 1))\n f))\n(test 1 1)\n", &.{
        "(test #f\n(letrec ((f 1))\n f))",
        "(test 1 1)",
    });
}

test "atoms and abbreviations at the top level are forms" {
    try expectForms("x 'y `(a ,b ,@c) #t 12 \"s\"", &.{ "x", "'y", "`(a ,b ,@c)", "#t", "12", "\"s\"" });
}

test "brackets count like parentheses" {
    try expectForms("(let [(x 1)] x) (y)", &.{ "(let [(x 1)] x)", "(y)" });
}

test "a bracket inside a string does not count" {
    try expectForms("(display \"(\") (x \"a\\\")\")", &.{ "(display \"(\")", "(x \"a\\\")\")" });
}

test "a bracket inside a line comment does not count" {
    try expectForms("(a ; (\n b) ; )\n(c)", &.{ "(a ; (\n b)", "(c)" });
}

test "a bracket character does not count" {
    try expectForms("(list #\\( #\\) #\\x28) (b)", &.{ "(list #\\( #\\) #\\x28)", "(b)" });
}

test "a bracket character alone does not open or close a list" {
    try expectForms("(a #\\() (b)", &.{ "(a #\\()", "(b)" });
    try expectForms("(#\\)) (b)", &.{ "(#\\))", "(b)" });
}

test "a vertical bar ends an atom" {
    try expectForms("a|b|", &.{ "a", "|b|" });
    try expectForms("(a|)|) (b)", &.{ "(a|)|)", "(b)" });
}

test "a character name ends at a delimiter" {
    try expectForms("(#\\space)#\\a(b)", &.{ "(#\\space)", "#\\a", "(b)" });
}

test "a bracket inside a vertical-bar identifier does not count" {
    try expectForms("(quote |a(b|) (c)", &.{ "(quote |a(b|)", "(c)" });
    try expectForms("'|a\\|(|", &.{"'|a\\|(|"});
}

test "block comments nest and are skipped" {
    try expectForms("#| ( #| ) |# ( |# (a #| ) |# b)", &.{"(a #| ) |# b)"});
}

test "a datum comment skips the next datum, at the top level and inside" {
    try expectForms("#;(a (b)) (c) (d #;(e) f)", &.{ "(c)", "(d #;(e) f)" });
    try expectForms("#; #;a b c", &.{"c"});
}

test "vectors, bytevectors, labels and directives are single forms" {
    try expectForms("#(1 (2)) #u8(1 2) #0=(a . #0#) #!fold-case (x)", &.{
        "#(1 (2))", "#u8(1 2)", "#0=(a . #0#)", "#!fold-case", "(x)",
    });
}

test "the line is the line of the start of the form" {
    const text = "; c\n\n  (a\n b)\n(c)";
    const first = (try next(text, 0)).?;
    try std.testing.expectEqual(@as(u32, 3), first.line);
    const second = (try next(text, first.end)).?;
    try std.testing.expectEqual(@as(u32, 5), second.line);
    try std.testing.expectEqual(@as(?Chunk, null), try next(text, second.end));
}

test "only whitespace and comments is no form" {
    try std.testing.expectEqual(@as(?Chunk, null), try next(" ; x\n #| y |# \n", 0));
    try std.testing.expectEqual(@as(?Chunk, null), try next("", 0));
}

test "unbalanced and unterminated text is an error" {
    try std.testing.expectError(error.Unbalanced, next("(a (b)", 0));
    try std.testing.expectError(error.Unbalanced, next(")", 0));
    try std.testing.expectError(error.Unbalanced, next("(a]", 0));
    try std.testing.expectError(error.UnterminatedString, next("(a \"b)", 0));
    try std.testing.expectError(error.UnterminatedBlockComment, next("#| a #| b |#", 0));
    try std.testing.expectError(error.UnterminatedIdentifier, next("(|a)", 0));
    try std.testing.expectError(error.Unbalanced, next("#;", 0));
}
