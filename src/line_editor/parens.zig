//! Matching parentheses in the text being edited (docs/plans/0021-stage7-8-early-parts.md, 7e).
//!
//! 編集中のテキストとカーソルの位置から、対応する括弧の位置を求める純粋な関数である。
//! 表示の補助であり、入力が完結したかの判定ではない。判定はこれまでどおりリーダが行う
//! (`sucheme.isIncomplete`。ADR-0014)。ここは、リーダの字句の規則(`src/reader.zig` の
//! `next` と `skipAtmosphere`、`src/char_syntax.zig`、`src/string_syntax.zig`)のうち、
//! 括弧を数えるのに要る部分だけを写している。リーダが育ててこの規則が変わったら、
//! ここも追従する。食い違わないことは、下のテストが `isIncomplete` と同じ入力で照合する。

const std = @import("std");

/// Returns the index of the parenthesis that matches the one next to `cursor`.
///
/// `cursor` は、バイトの位置である(文字と文字の間)。カーソルの直前の文字が `)` なら、
/// 対応する `(` の位置を返す。そうでなく、カーソルの位置の文字が `(` なら、対応する `)`
/// の位置を返す。直前を先に見るのは、閉じ括弧を打った直後に、その対応を示すためである。
/// 直前の `)` に相手が無いときは、カーソルの位置の `(` を見る。
/// 隣が括弧でない場合、対応する相手が無い場合、括弧が文字列、文字、コメント、縦棒の識別子の
/// 中にある場合は null を返す。`#(` と `#u8(` の開き括弧は、`(` の位置で数える。
/// `cursor` が `text.len` を超えるときも null である。確保はしない。
pub fn matching(text: []const u8, cursor: usize) ?usize {
    if (cursor > text.len) return null;
    if (cursor > 0 and text[cursor - 1] == ')') {
        if (openerOf(text, cursor - 1)) |open| return open;
    }
    if (cursor < text.len and text[cursor] == '(') return closerOf(text, cursor);
    return null;
}

/// A parenthesis outside strings, characters, comments and identifiers.
const Paren = struct { index: usize, kind: enum { open, close } };

/// What the scan of `text` has to say about the text as a whole.
const Balance = struct {
    /// `(` で、対応する `)` が無いものの数。
    open: usize = 0,
    /// `)` で、対応する `(` が無いものの数。
    extra_close: usize = 0,
    /// 文字列、縦棒の識別子、ブロックコメント、文字の本体のどれかが、閉じる前に入力が尽きた。
    unterminated: bool = false,
};

/// The index of the `(` that the `)` at `close` closes.
///
/// 2回走査する。1回目で、`close` の深さ D を求める。2回目で、深さが D-1 から D に
/// 上がった最後の `(` を拾う。それが対応する `(` である。確保する並び(スタック)を
/// 持たずに済む。
fn openerOf(text: []const u8, close: usize) ?usize {
    var depth: usize = 0;
    var scan: Scanner = .{ .text = text };
    while (scan.next()) |p| {
        if (p.index > close) return null;
        switch (p.kind) {
            .open => depth += 1,
            .close => {
                if (p.index == close) break;
                if (depth == 0) continue; // 対応する `(` の無い `)` は、深さを変えない。
                depth -= 1;
            },
        }
    } else return null; // `close` は、括弧として数えない位置にある。
    if (depth == 0) return null;

    var level: usize = 0;
    var candidate: ?usize = null;
    scan = .{ .text = text };
    while (scan.next()) |p| {
        if (p.index >= close) break;
        switch (p.kind) {
            .open => {
                level += 1;
                if (level == depth) candidate = p.index;
            },
            .close => if (level > 0) {
                level -= 1;
            },
        }
    }
    return candidate;
}

/// The index of the `)` that closes the `(` at `open`.
fn closerOf(text: []const u8, open: usize) ?usize {
    var depth: usize = 0;
    var scan: Scanner = .{ .text = text };
    while (scan.next()) |p| {
        if (p.index < open) {
            // `open` より前の括弧は、`open` が括弧として数えられるかを見る前に、
            // 深さの外に置く。`(` の中にいても、`open` の相手は `open` からの深さで決まる。
            continue;
        }
        if (p.index == open) {
            depth = 1;
            continue;
        }
        if (depth == 0) return null; // `open` を通り過ぎた。括弧として数えない位置にある。
        switch (p.kind) {
            .open => depth += 1,
            .close => {
                depth -= 1;
                if (depth == 0) return p.index;
            },
        }
    }
    return null;
}

/// Counts the unmatched parentheses of `text`, and whether it ends inside a token.
///
/// リーダとの照合のテストが使う。
fn balance(text: []const u8) Balance {
    var result: Balance = .{};
    var scan: Scanner = .{ .text = text };
    while (scan.next()) |p| switch (p.kind) {
        .open => result.open += 1,
        .close => if (result.open > 0) {
            result.open -= 1;
        } else {
            result.extra_close += 1;
        },
    };
    result.unterminated = scan.unterminated;
    return result;
}

/// Walks `text` once from the front and yields the parentheses that count.
///
/// リーダの `next` と同じ順に、区切り文字で字句を分ける。`pos` は、トークンの先頭か、
/// 括弧の次を指す。
const Scanner = struct {
    text: []const u8,
    pos: usize = 0,
    unterminated: bool = false,

    fn next(self: *Scanner) ?Paren {
        const text = self.text;
        while (self.pos < text.len) {
            const c = text[self.pos];
            switch (c) {
                '(' => {
                    self.pos += 1;
                    return .{ .index = self.pos - 1, .kind = .open };
                },
                ')' => {
                    self.pos += 1;
                    return .{ .index = self.pos - 1, .kind = .close };
                },
                ';' => self.skipLine(),
                '"', '|' => self.skipQuoted(c),
                '#' => self.skipHash(),
                else => if (isWhitespace(c)) {
                    self.pos += 1;
                } else self.skipAtom(),
            }
        }
        return null;
    }

    /// `;` から行の終わり(改行か CR)の手前まで。
    fn skipLine(self: *Scanner) void {
        while (self.pos < self.text.len and self.text[self.pos] != '\n' and self.text[self.pos] != '\r') self.pos += 1;
    }

    /// 文字列(`"`)か縦棒の識別子(`|`)。バックスラッシュは次のバイトを読み飛ばす。
    /// どちらの終わりの印も ASCII なので、マルチバイトの途中では止まらない。
    fn skipQuoted(self: *Scanner, mark: u8) void {
        const text = self.text;
        self.pos += 1;
        while (self.pos < text.len) {
            const c = text[self.pos];
            self.pos += 1;
            if (c == mark) return;
            if (c == '\\') self.pos += 1;
        }
        self.pos = text.len;
        self.unterminated = true;
    }

    /// `#` で始まるもの。`#|`(ブロックコメント)、`#;`(データコメントの印)、`#\`(文字)は、
    /// トークンの先頭でだけ特別である。それ以外(`#(`、`#u8(`、`#t`、`#0=`、`#!fold-case`)は、
    /// `#` だけを進めて、続きを通常の字句として読む。
    fn skipHash(self: *Scanner) void {
        const text = self.text;
        const n: u8 = if (self.pos + 1 < text.len) text[self.pos + 1] else 0;
        switch (n) {
            '|' => self.skipBlockComment(),
            // Why: `#;` の `;` は行コメントを始めない。捨てられるデータは、通常どおり読む
            // (その中の括弧は数える。リーダも `#;` の後のデータを読んで捨てる)。
            ';' => self.pos += 2,
            '\\' => self.skipCharacter(),
            else => self.pos += 1,
        }
    }

    /// ネストするブロックコメント。リーダの `skipBlockComment` と同じ走り方をする。
    fn skipBlockComment(self: *Scanner) void {
        const text = self.text;
        var depth: usize = 0;
        while (self.pos + 1 < text.len) {
            if (text[self.pos] == '#' and text[self.pos + 1] == '|') {
                depth += 1;
                self.pos += 2;
            } else if (text[self.pos] == '|' and text[self.pos + 1] == '#') {
                depth -= 1;
                self.pos += 2;
                if (depth == 0) return;
            } else {
                self.pos += 1;
            }
        }
        self.pos = text.len;
        self.unterminated = true;
    }

    /// `#\` と、その次の1文字と、区切り文字までの続き(`#\space`、`#\x41`)。
    /// 次の1文字が `(` や `)` でも、文字の一部である(`#\(`)。
    fn skipCharacter(self: *Scanner) void {
        const text = self.text;
        const start = self.pos + 2;
        if (start >= text.len) {
            self.pos = text.len;
            self.unterminated = true;
            return;
        }
        const first_len = std.unicode.utf8ByteSequenceLength(text[start]) catch 1;
        self.pos = @min(start + first_len, text.len);
        self.skipAtom();
    }

    /// 区切り文字の手前まで。
    fn skipAtom(self: *Scanner) void {
        while (self.pos < self.text.len and !isDelimiter(self.text[self.pos])) self.pos += 1;
    }
};

// Why: `src/reader.zig` の `isWhitespace` と `isDelimiter` と同じである。リーダの関数は
// 公開されていないので写している。食い違いは、下の `isIncomplete` との照合が見つける。
fn isWhitespace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}

fn isDelimiter(c: u8) bool {
    return isWhitespace(c) or c == '|' or c == '(' or c == ')' or c == '"' or c == ';';
}

// ここから、テスト。

/// The match of the parenthesis at `at`, with the cursor on its near side.
fn matchAt(text: []const u8, at: usize) ?usize {
    // 開きなら、その手前(カーソルは `at`)。閉じなら、その次(カーソルは `at + 1`)。
    return if (text[at] == '(') matching(text, at) else matching(text, at + 1);
}

fn expectPair(text: []const u8, open: usize, close: usize) !void {
    try std.testing.expectEqual(@as(u8, '('), text[open]);
    try std.testing.expectEqual(@as(u8, ')'), text[close]);
    try std.testing.expectEqual(@as(?usize, close), matching(text, open));
    try std.testing.expectEqual(@as(?usize, open), matching(text, close + 1));
}

test "a pair of parentheses matches from either side" {
    try expectPair("()", 0, 1);
    try expectPair("(a b)", 0, 4);
    try expectPair("(a (b) c)", 0, 8);
    try expectPair("(a (b) c)", 3, 5);
    try expectPair("((()))", 0, 5);
    try expectPair("((()))", 1, 4);
    try expectPair("((()))", 2, 3);
    try expectPair("(a) (b)", 4, 6);
}

test "the cursor on a character that is not next to a parenthesis finds nothing" {
    try std.testing.expectEqual(@as(?usize, null), matching("(a b)", 2));
    try std.testing.expectEqual(@as(?usize, null), matching("", 0));
    try std.testing.expectEqual(@as(?usize, null), matching("(a)", 4)); // 範囲外
    try std.testing.expectEqual(@as(?usize, null), matching("(a)", 100));
}

test "the character before the cursor is looked at before the one after it" {
    // `)(` の間: 直前の `)` が先に効く。
    try std.testing.expectEqual(@as(?usize, 0), matching("(a)(b)", 3));
    // 直前が括弧でも、`)` でなければ、カーソルの位置の `(` を見る。
    try std.testing.expectEqual(@as(?usize, 3), matching("((a))", 1));
    // 直前が `)` でも、その相手が無ければ、カーソルの位置の `(` を見る。
    try std.testing.expectEqual(@as(?usize, 4), matching("a)(b)", 2));
}

test "an unmatched parenthesis finds nothing" {
    try std.testing.expectEqual(@as(?usize, null), matching("(a", 0));
    try std.testing.expectEqual(@as(?usize, null), matching("a)", 2));
    try std.testing.expectEqual(@as(?usize, null), matching("(a (b)", 0));
    try expectPair("(a (b)", 3, 5);
    try std.testing.expectEqual(@as(?usize, null), matching("a))", 3));
    try std.testing.expectEqual(@as(?usize, 0), matching("())", 2));
    try std.testing.expectEqual(@as(?usize, null), matching("())", 3));
    // 余分な `)` のあとの `(` は、そのあとの `)` と対応する。
    try expectPair(")(a)", 1, 3);
}

test "a vector and a bytevector open with the parenthesis after the hash" {
    try expectPair("#(1 2)", 1, 5);
    try expectPair("#u8(1 2)", 3, 7);
    try expectPair("(a #(b (c)) d)", 0, 13);
    try expectPair("(a #(b (c)) d)", 4, 10);
}

test "a parenthesis inside a string is not counted" {
    try expectPair("(a \"(\" b)", 0, 8);
    try expectPair("(a \")\" b)", 0, 8);
    try expectPair("(a \"\\\"(\" b)", 0, 10); // `\"` のあとの `(`
    try expectPair("(a \"\\\\\" b)", 0, 9); // `\\` で文字列が終わる
    // 文字列の中の括弧は、自分では何も見つけない。
    try std.testing.expectEqual(@as(?usize, null), matching("\"(\"", 1));
    try std.testing.expectEqual(@as(?usize, null), matching("\")\"", 2));
    // 閉じていない文字列は、入力の終わりまで続く。
    try std.testing.expectEqual(@as(?usize, null), matching("(a \"b)", 0));
    try std.testing.expectEqual(@as(?usize, null), matching("(a \"b)", 6));
    // 文字列は行をまたぐ。
    try expectPair("(a \"x\n)\" b)", 0, 10);
}

test "a parenthesis inside a vertical-bar identifier is not counted" {
    try expectPair("(a |(| b)", 0, 8);
    try expectPair("(a |)| b)", 0, 8);
    try expectPair("(a |\\|(| b)", 0, 10);
    try std.testing.expectEqual(@as(?usize, null), matching("(a |b)", 0));
    // `|` は区切り文字である。`a|(|b` は `a`、`(`、`b` の識別子である。
    try expectPair("(a|(|b)", 0, 6);
}

test "a character literal hides its own parenthesis" {
    try expectPair("(a #\\( b)", 0, 8);
    try expectPair("(a #\\) b)", 0, 8);
    try expectPair("(#\\()", 0, 4);
    try expectPair("(#\\))", 0, 4);
    try expectPair("(#\\space)", 0, 8);
    try expectPair("(#\\x41 (b))", 0, 10);
    try expectPair("(#\\あ)", 0, 6);
    // 文字の次の括弧は数える。
    try expectPair("(#\\a(b))", 0, 7);
    try expectPair("(#\\a(b))", 4, 6);
    try std.testing.expectEqual(@as(?usize, null), matching("#\\(", 2));
    try std.testing.expectEqual(@as(?usize, null), matching("#\\)", 3));
    // 本体の無い `#\` は、入力の終わりまでを覆う。
    try std.testing.expectEqual(@as(?usize, null), matching("(a #\\", 0));
    // 文字の続きは、区切り文字まで文字の一部である。`#|` は、トークンの途中ではコメントを始めない。
    try expectPair("(#\\a#| ) | )", 0, 11);
    // タブも空白で、文字の名前を終える。
    try expectPair("(#\\a\t(b))", 0, 8);
    // `#\;` の `;` は行コメントを始めない。
    try expectPair("(a #\\; b)", 0, 8);
    // `#\"` の `"` は文字列を始めない。
    try expectPair("(a #\\\" b)", 0, 8);
    // `#\|` の `|` は識別子を始めない。
    try expectPair("(a #\\| b)", 0, 8);
}

test "a tab separates tokens like a space" {
    try expectPair("(a\t)", 0, 3);
    try expectPair("(a\t(b)\t)", 0, 7);
    // タブが区切りなら、`#|` はトークンの先頭なのでコメントを始め、閉じないまま入力が尽きる。
    // 区切りでなければ、`a\t#` が1つのトークンになり、縦棒の識別子が `) |` を覆って、`)` が閉じる。
    try std.testing.expectEqual(@as(?usize, null), matching("(a\t#| ) | )", 0));
    try std.testing.expectEqual(@as(?usize, null), matching("(a #| ) | )", 0));
}

test "a parenthesis inside a line comment is not counted" {
    try expectPair("(a ; )\n b)", 0, 9);
    try expectPair("(a ; (\n b)", 0, 9);
    try std.testing.expectEqual(@as(?usize, null), matching("(a ; )", 0));
    try std.testing.expectEqual(@as(?usize, null), matching("; (a)", 2));
    // CR も行の終わりである。
    try expectPair("(a ; )\r b)", 0, 9);
    // 文字列の中の `;` は、コメントを始めない。
    try expectPair("(a \";\" b)", 0, 8);
    // 区切り文字の `;` は、トークンを終えてコメントを始める。
    try expectPair("(a;b)\n)", 0, 6);
}

test "a datum comment does not start a line comment, and its parentheses count" {
    // `#;` の `;` は行コメントではない。次のデータ `(b)` が捨てられるデータである。
    try expectPair("(a #;(b) c)", 0, 10);
    try expectPair("(a #;(b) c)", 5, 7);
    try expectPair("(#;)", 0, 3); // `isIncomplete` も、`#;` の直後の `)` は誤りとして完結とする。
}

test "a parenthesis inside a block comment is not counted, and the comments nest" {
    try expectPair("(a #| ( |# b)", 0, 12);
    try expectPair("(a #| ) |# b)", 0, 12);
    try expectPair("(a #| #| ( |# ) |# b)", 0, 20);
    try expectPair("(a #|#||#|# b)", 0, 13);
    try std.testing.expectEqual(@as(?usize, null), matching("(a #| ( |# b", 0));
    // 閉じていないコメントは、入力の終わりまで続く。
    try std.testing.expectEqual(@as(?usize, null), matching("(a #| )", 0));
    // 内側だけが閉じても、外側が閉じるまでコメントである。
    try std.testing.expectEqual(@as(?usize, null), matching("(a #| #| |# )", 0));
    // `#|` はトークンの先頭でだけコメントを始める。`a#` で識別子が `|` で終わり、縦棒の識別子が始まる。
    try expectPair("(a#| ) |)", 0, 8);
    // `|#` は、コメントの外では縦棒の識別子の始まりである。
    try std.testing.expectEqual(@as(?usize, null), matching("(a |# )", 0));
}

test "a directive and a label do not hide a parenthesis" {
    try expectPair("(#!fold-case (a))", 0, 16);
    try expectPair("#0=(a #0#)", 3, 9);
    try expectPair("(#t #f)", 0, 6);
}

test "only the parentheses the reader reads as parentheses count" {
    // 角括弧と波括弧は、リーダにとって括弧ではない。
    try std.testing.expectEqual(@as(?usize, null), matching("[a]", 0));
    try std.testing.expectEqual(@as(?usize, null), matching("{a}", 3));
    try expectPair("(a [ b)", 0, 6);
    // 引用の印は、括弧の対応を変えない。
    try expectPair("'(a ,(b) `(c ,@(d)))", 1, 19);
}

test "the result is the byte index of the parenthesis, also after multibyte characters" {
    try expectPair("(あ (い) う)", 0, 14);
    try expectPair("(あ (い) う)", 5, 9);
    try std.testing.expectEqual(@as(?usize, 0), matching("(あ)", 5));
}

test "a text that ends inside a token leaves the parentheses before it matched" {
    try expectPair("(a) \"x", 0, 2);
    try expectPair("(a) #| (", 0, 2);
    try expectPair("(a) ; (", 0, 2);
}

// `isIncomplete` との照合。

/// An input, the unmatched parentheses it has, and whether it ends inside a token.
const Row = struct { text: []const u8, open: usize, extra_close: usize, unterminated: bool = false };

// `src/reader.zig` の判定表(`isIncomplete asks for more input only for an unfinished datum`)の
// 括弧に関わる行を、そのまま写している。写した行は、`isIncomplete` が真か偽かを、
// この走査の結果から言える行である。引用の印やドットなどの、括弧と無関係に続きを求める行
// (`'`、`(a . `、`#0=`)は、ここでは照合できないので写していない。
const rows = [_]Row{
    // リストかベクタが閉じていない。
    .{ .text = "(+ 1", .open = 1, .extra_close = 0 },
    .{ .text = "(a (b)", .open = 1, .extra_close = 0 },
    .{ .text = "#(1 2", .open = 1, .extra_close = 0 },
    .{ .text = "(", .open = 1, .extra_close = 0 },
    .{ .text = "#(", .open = 1, .extra_close = 0 },
    .{ .text = "((a) (b", .open = 2, .extra_close = 0 },
    .{ .text = "(a '", .open = 1, .extra_close = 0 },
    .{ .text = "1 (a", .open = 1, .extra_close = 0 },
    // 文字列が閉じていない。
    .{ .text = "\"abc", .open = 0, .extra_close = 0, .unterminated = true },
    .{ .text = "\"a\\", .open = 0, .extra_close = 0, .unterminated = true },
    .{ .text = "\"a\\\"", .open = 0, .extra_close = 0, .unterminated = true },
    .{ .text = "\"a\nb", .open = 0, .extra_close = 0, .unterminated = true },
    // 文字の本体が無い。
    .{ .text = "#\\", .open = 0, .extra_close = 0, .unterminated = true },
    .{ .text = "(a #\\", .open = 1, .extra_close = 0, .unterminated = true },
    // コメントの中の `)` は数えない。
    .{ .text = "(a ; )\n", .open = 1, .extra_close = 0 },
    .{ .text = "(a ; )", .open = 1, .extra_close = 0 },
    .{ .text = "(+ 1 2 ;)\n", .open = 1, .extra_close = 0 },
    .{ .text = "#(1 ; )\n", .open = 1, .extra_close = 0 },
    .{ .text = "(a;b\n", .open = 1, .extra_close = 0 },
    // 閉じた式。
    .{ .text = "(+ 1 2)", .open = 0, .extra_close = 0 },
    .{ .text = "1 2", .open = 0, .extra_close = 0 },
    .{ .text = "(a (b) c)", .open = 0, .extra_close = 0 },
    .{ .text = "#(1 2)", .open = 0, .extra_close = 0 },
    .{ .text = "(a . b)", .open = 0, .extra_close = 0 },
    .{ .text = "\"a\\\"\"", .open = 0, .extra_close = 0 },
    .{ .text = "\"a\nb\"", .open = 0, .extra_close = 0 },
    .{ .text = "#\\a", .open = 0, .extra_close = 0 },
    .{ .text = "#\\space", .open = 0, .extra_close = 0 },
    // 文字列、文字、コメントの中の括弧は、何も開かず閉じない。
    .{ .text = "\"(\"", .open = 0, .extra_close = 0 },
    .{ .text = "\")\"", .open = 0, .extra_close = 0 },
    .{ .text = "#\\(", .open = 0, .extra_close = 0 },
    .{ .text = "#\\)", .open = 0, .extra_close = 0 },
    .{ .text = "(a #\\()", .open = 0, .extra_close = 0 },
    .{ .text = "(a \"(\")", .open = 0, .extra_close = 0 },
    .{ .text = "(a #\\( 1", .open = 1, .extra_close = 0 },
    .{ .text = "(a) ; (", .open = 0, .extra_close = 0 },
    .{ .text = "(a ; (\n)", .open = 0, .extra_close = 0 },
    .{ .text = "\"a;b\"", .open = 0, .extra_close = 0 },
    // 構文エラー。`)` が余ると、リーダは誤りで止まり、続きを求めない。
    .{ .text = ")", .open = 0, .extra_close = 1 },
    .{ .text = "(a))", .open = 0, .extra_close = 1 },
    .{ .text = "(a . b c)", .open = 0, .extra_close = 0 },
    .{ .text = ") (a", .open = 1, .extra_close = 1 },
    // ブロックコメントと縦棒の識別子。
    .{ .text = "#| x", .open = 0, .extra_close = 0, .unterminated = true },
    .{ .text = "#|", .open = 0, .extra_close = 0, .unterminated = true },
    .{ .text = "#| #| x |#", .open = 0, .extra_close = 0, .unterminated = true },
    .{ .text = "#| ( |#", .open = 0, .extra_close = 0 },
    .{ .text = "#;(a) b", .open = 0, .extra_close = 0 },
    .{ .text = "|abc", .open = 0, .extra_close = 0, .unterminated = true },
    .{ .text = "(a |b c", .open = 1, .extra_close = 0, .unterminated = true },
    .{ .text = "|a b|", .open = 0, .extra_close = 0 },
    .{ .text = "(a |b) c|", .open = 1, .extra_close = 0, .unterminated = false },
    .{ .text = "#!fold-case (a", .open = 1, .extra_close = 0 },
    // 何も無い入力。
    .{ .text = "", .open = 0, .extra_close = 0 },
    .{ .text = "; コメント", .open = 0, .extra_close = 0 },
};

test "balance agrees with isIncomplete on the rows of the judgement table" {
    for (rows) |row| {
        const got = balance(row.text);
        std.testing.expectEqual(row.open, got.open) catch |e| {
            std.debug.print("open of {f}\n", .{std.zig.fmtString(row.text)});
            return e;
        };
        std.testing.expectEqual(row.extra_close, got.extra_close) catch |e| {
            std.debug.print("extra_close of {f}\n", .{std.zig.fmtString(row.text)});
            return e;
        };
        std.testing.expectEqual(row.unterminated, got.unterminated) catch |e| {
            std.debug.print("unterminated of {f}\n", .{std.zig.fmtString(row.text)});
            return e;
        };
        // 括弧が余らず、開いたままのもの(か、途中で切れたトークン)があれば、続きを求める。
        // `)` が余れば、リーダは誤りで止まるので、求めない。
        const expected = got.extra_close == 0 and (got.open > 0 or got.unterminated);
        // 構文エラー(ドットの後が2つなど)で、括弧が閉じていても続きを求めない行は、
        // 上の式で偽になる。`(a . b c)` がその例である。
        std.testing.expectEqual(expected, try @import("sucheme").isIncomplete(std.testing.allocator, row.text)) catch |e| {
            std.debug.print("isIncomplete of {f}\n", .{std.zig.fmtString(row.text)});
            return e;
        };
    }
}

/// Builds a text from the pieces that cannot make the reader fail except by an unmatched `)`.
///
/// `#` で始まる部品は、前を空白で区切る。`a#` や `|#` のあとの `#` が、リーダにとって
/// 読めないトークンになり、続きを求めない(括弧と無関係の誤り)のを避けるためである。
fn compose(random: std.Random, buffer: []u8) []const u8 {
    const pieces = [_][]const u8{ "(", ")", "\"", "|", ";", " #| ", " #|x|# ", " #(", "a", " ", "\n", "(", ")" };
    var len: usize = 0;
    const count = random.uintLessThan(usize, 14);
    for (0..count) |_| {
        const piece = pieces[random.uintLessThan(usize, pieces.len)];
        @memcpy(buffer[len..][0..piece.len], piece);
        len += piece.len;
    }
    return buffer[0..len];
}

test "balance agrees with isIncomplete on random texts" {
    var prng: std.Random.DefaultPrng = .init(0x7e7e);
    var buffer: [64]u8 = undefined;
    for (0..4000) |_| {
        const text = compose(prng.random(), &buffer);
        const got = balance(text);
        const expected = got.extra_close == 0 and (got.open > 0 or got.unterminated);
        std.testing.expectEqual(expected, try @import("sucheme").isIncomplete(std.testing.allocator, text)) catch |e| {
            std.debug.print("isIncomplete of {f}\n", .{std.zig.fmtString(text)});
            return e;
        };
    }
}

// 不変条件。

/// Checks what `matching` promises about `text`, for every cursor.
fn checkMatching(text: []const u8) !void {
    for (0..text.len + 1) |cursor| {
        const found = matching(text, cursor) orelse continue;
        try std.testing.expect(found < text.len);
        // 相手は、反対の種類の括弧である。見つけたのが `(` なら、こちらはカーソルの直前の `)` で、
        // `)` なら、こちらはカーソルの位置の `(` である。
        const here = if (text[found] == '(') cursor - 1 else cursor;
        try std.testing.expect(text[found] == '(' or text[found] == ')');
        try std.testing.expect(text[here] != text[found]);
        // 相手から見ても、こちらが相手である(`)(` の間のカーソルを避けるため、内部の関数で見る)。
        const back = if (text[found] == '(') closerOf(text, found) else openerOf(text, found);
        try std.testing.expectEqual(@as(?usize, here), back);
        // 開きは閉じより前にある。
        if (text[here] == '(') try std.testing.expect(found > here) else try std.testing.expect(found < here);
    }
}

test "a match is symmetric, in range and the opposite kind, for every cursor of random texts" {
    var prng: std.Random.DefaultPrng = .init(0x7e);
    var buffer: [64]u8 = undefined;
    for (0..2000) |_| try checkMatching(compose(prng.random(), &buffer));
}

fn fuzzMatching(_: void, smith: *std.testing.Smith) anyerror!void {
    var buffer: [256]u8 = undefined;
    const len = smith.slice(&buffer);
    try checkMatching(buffer[0..len]);
}

test "fuzz: matching never reads out of range and its matches are symmetric" {
    try std.testing.fuzz({}, fuzzMatching, .{});
}
