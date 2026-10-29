//! Runs the Scheme code blocks of the user documentation and compares their output.
//!
//! `zig build check-examples` で走らせる。docs/manual/ の下の `.md` をすべて読み、
//! その中の `scheme` のコードブロックを、REPL と同じ入口 `sucheme.Interpreter.evalPrint`
//! でプロセスの中で評価し、直後の `output` のブロックと比べる。計画書は
//! docs/plans/0027-user-documentation.md、決定は docs/adr/0048-run-the-examples-of-the-user-documentation.md
//! にある。
//!
//! 文書の形式は次のとおりである。
//!
//! - フェンスは行頭から書く。情報文字列の最初の語が、ブロックの種類である。
//! - `scheme`: 走らせる。後ろに `fresh` の語があると、新しいインタプリタで走らせる。
//!   同じファイルのほかのブロックは、1つのインタプリタで上から順に走り、前のブロックの
//!   定義を引き継ぐ。
//! - `output`: 直前の `scheme` のブロック(空行だけを挟んでよい)の、期待する出力。
//!   値は REPL と同じく1行ずつ、`display` などの出力は書いた順に、誤りは `error: ` と
//!   メッセージで書く。`output` が続かない `scheme` のブロックは、出力が空であることを
//!   求める。
//! - `text`: 走らせない。文法の型など、Scheme として読めない断片のためにある。
//!
//! 検査の外に黙って出るブロックを残さないため、次を誤りとして報告する。情報文字列の
//! 無いフェンス、知らない種類と語、行頭から書かれていないフェンス、閉じていない
//! フェンス、`scheme` の後ろでない `output`、フェンスの外の、空白4つかタブで始まる行
//! (インデントされたコードブロックになりうる)、引用(`>` で始まる行)の中のフェンス、
//! `<pre>` と `<code>` で始まる HTML のブロック。この道具は CommonMark のリストと引用の
//! 中のフェンスを読まないので、それらを断ることで、読み違えを防ぐ。
//!
//! docs/manual/ の下の `.md` でないファイル、`.md` が無いこと、`scheme` のブロックが
//! 1つも無いことも、失敗とする。引数は取らない。範囲を狭める引数は、検査を減らした
//! まま緑にする手段になるからである(tools/test-scheme と同じ理由)。

const std = @import("std");
const sucheme = @import("sucheme");

/// Where the documents are.
const manual_dir = "docs/manual";

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.arena.allocator();
    const io = init.io;

    var buf: [4096]u8 = undefined;
    // tools/test-scheme と同じ理由でストリーミングにする。位置指定のライタは、
    // 追記されるログの先頭を上書きしてしまう。
    var stderr = std.Io.File.Writer.initStreaming(.stderr(), io, &buf);
    const err = &stderr.interface;

    const argv = try init.minimal.args.toSlice(gpa);
    if (argv.len > 1) {
        try err.print("check-examples: takes no arguments, got {s}\n", .{argv[1]});
        try err.flush();
        return 2;
    }

    var dir = std.Io.Dir.cwd().openDir(io, manual_dir, .{ .iterate = true }) catch |e| {
        try err.print("check-examples: cannot open {s} ({t})\n", .{ manual_dir, e });
        try err.flush();
        return 1;
    };
    defer dir.close(io);
    const counts = try run(gpa, io, dir, manual_dir, err);
    try err.print("check-examples: {d} blocks passed, {d} failed\n", .{ counts.passed, counts.failed });
    try err.flush();
    // Why: 終了コードは `main` の戻り値で返す。`exit` の呼び出しを条件に置くと、その1行を
    // 消すだけで、失敗を報告しながら 0 で終わる形になった(D1 のミューテーションの査読)。
    return exitStatus(counts);
}

/// The exit status for a run with `counts`.
fn exitStatus(counts: Counts) u8 {
    return if (counts.failed != 0) 1 else 0;
}

/// Checks every document under `dir`, named `name` in the report, and writes what failed to `w`.
///
/// `.md` でないファイル、`.md` が無いこと、`scheme` のブロックが1つも走らないことも、
/// 失敗として数える。
fn run(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, name: []const u8, w: *std.Io.Writer) !Counts {
    var counts: Counts = .{};
    var paths: std.ArrayList([]const u8) = .empty;
    var walker = try dir.walk(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind == .directory) continue;
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".md")) {
            try w.print("{s}/{s}: not a `.md` file, so nothing here checks it\n", .{ name, entry.path });
            counts.failed += 1;
            continue;
        }
        try paths.append(gpa, try gpa.dupe(u8, entry.path));
    }
    // ディレクトリの順序はホストごとに違う。ソートして報告を安定させる。
    std.mem.sort([]const u8, paths.items, {}, lessThan);
    if (paths.items.len == 0) {
        try w.print("check-examples: no `.md` file under {s}\n", .{name});
        counts.failed += 1;
    }

    for (paths.items) |path| {
        const shown = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ name, path });
        const body = dir.readFileAlloc(io, path, gpa, .unlimited) catch |e| {
            try w.print("{s}: cannot be read ({t})\n", .{ shown, e });
            counts.failed += 1;
            continue;
        };
        try checkFile(gpa, shown, body, w, &counts);
    }

    if (counts.blocks == 0) {
        try w.print("check-examples: no `scheme` block was run\n", .{});
        counts.failed += 1;
    }
    return counts;
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// The counts of a run.
const Counts = struct {
    /// The `scheme` blocks run, passed or not.
    blocks: usize = 0,
    passed: usize = 0,
    failed: usize = 0,
};

/// Reads one document, runs its blocks and writes what failed to `w`.
fn checkFile(gpa: std.mem.Allocator, path: []const u8, body: []const u8, w: *std.Io.Writer, counts: *Counts) !void {
    var problems: std.ArrayList(Problem) = .empty;
    const blocks = try parse(gpa, body, &problems);
    for (problems.items) |p| {
        try w.print("{s}:{d}: {s}\n", .{ path, p.line, p.message });
        counts.failed += 1;
    }
    // 読み取りに誤りがあるファイルは走らせない。どのブロックを走らせるべきかが
    // 確かでないからである。誤りは上で数えたので、黙って飛ばしたことにはならない。
    if (problems.items.len != 0) return;

    var interp: ?sucheme.Interpreter = null;
    defer if (interp) |*i| i.deinit();
    for (blocks) |block| {
        if (interp == null or block.fresh) {
            if (interp) |*i| i.deinit();
            interp = null;
            var fresh: sucheme.Interpreter = undefined;
            try fresh.init(std.heap.smp_allocator);
            interp = fresh;
        }
        counts.blocks += 1;
        const got = try evaluate(gpa, &interp.?, block.source);
        if (std.mem.eql(u8, got, block.expected)) {
            counts.passed += 1;
        } else {
            try w.print(
                "{s}:{d}: the output differs\n  expected: {s}\n  got:      {s}\n",
                .{ path, block.line, block.expected, got },
            );
            counts.failed += 1;
        }
    }
}

/// The text `source` prints in `interp`: what it writes, then the error if it ends with one.
///
/// tools/test-scheme の `evaluate` と同じ形にする(計画書 0027 の合意を求める点の3)。
/// 最後の改行は除く。期待する出力も、最後の行の後に改行を持たない。
fn evaluate(gpa: std.mem.Allocator, interp: *sucheme.Interpreter, source: []const u8) error{OutOfMemory}![]const u8 {
    var arena: std.heap.ArenaAllocator = .init(std.heap.smp_allocator);
    defer arena.deinit();
    var out: std.Io.Writer.Allocating = .init(std.heap.smp_allocator);
    defer out.deinit();
    interp.evalPrint(arena.allocator(), source, &out.writer) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        // ライタは確保を行うので、失敗するのはメモリ不足のときだけである。
        error.WriteFailed => return error.OutOfMemory,
        // REPL が出すとおりに出力する。そのブロックが失敗する前に書いたものの後に置く。
        // 説明は `arena` の中にあるので、ここで写す。
        else => out.writer.print("error: {s}\n", .{interp.diagnostic()}) catch return error.OutOfMemory,
    };
    return try gpa.dupe(u8, std.mem.trimEnd(u8, out.written(), "\n"));
}

/// A `scheme` block to run, with the output it should produce.
const Block = struct {
    /// The 1-based line of the opening fence, for the report.
    line: usize,
    source: []const u8,
    /// The lines of the `output` block joined with `\n`, or "" when none follows.
    expected: []const u8,
    /// Whether the block runs in a new interpreter (`scheme fresh`).
    fresh: bool,
};

/// Something in a document that stops it from being checked.
const Problem = struct {
    line: usize,
    message: []const u8,
};

/// The kind of a fenced block, from the first word of its info string.
const Kind = enum { scheme, output, text };

/// Splits a document into the `scheme` blocks to run, and reports what it cannot classify.
///
/// 形式はファイルの doc コメントを参照。返すブロックと `problems` は `gpa` の中にある。
fn parse(gpa: std.mem.Allocator, body: []const u8, problems: *std.ArrayList(Problem)) error{OutOfMemory}![]Block {
    var blocks: std.ArrayList(Block) = .empty;
    // 開いているフェンスと、その中身。
    var open: ?struct { ch: u8, len: usize, kind: Kind, fresh: bool, line: usize, start: usize } = null;
    var content: std.ArrayList(u8) = .empty;
    // 直前に閉じた `scheme` のブロックの添字。空行でない地の文が来たら、`output` を
    // 受け付けなくなる。
    var last_scheme: ?usize = null;

    var lines = std.mem.splitScalar(u8, body, '\n');
    var lineno: usize = 0;
    while (lines.next()) |raw| {
        lineno += 1;
        // CRLF でチェックアウトしたものも、LF のものと同じに読めなければならない。
        const line = std.mem.trimEnd(u8, raw, "\r");
        const trimmed = std.mem.trimStart(u8, line, " \t");
        const indented = trimmed.len != line.len;

        if (open) |o| {
            if (fenceRun(trimmed)) |f| {
                if (f.bare and f.ch == o.ch and f.len >= o.len) {
                    if (indented) {
                        // CommonMark では字下げした閉じる行も閉じるが、この道具は行頭の
                        // ものだけを閉じるとして読む。食い違いを黙って残さない。
                        try problems.append(gpa, .{ .line = lineno, .message = "this closing fence is indented; write it at the start of the line" });
                    }
                    const text = try gpa.dupe(u8, content.items);
                    content.clearRetainingCapacity();
                    switch (o.kind) {
                        .scheme => {
                            try blocks.append(gpa, .{ .line = o.line, .source = text, .expected = "", .fresh = o.fresh });
                            last_scheme = blocks.items.len - 1;
                        },
                        .output => blocks.items[o.start].expected = std.mem.trimEnd(u8, text, "\n"),
                        .text => {},
                    }
                    open = null;
                    continue;
                }
            }
            try content.appendSlice(gpa, line);
            try content.append(gpa, '\n');
            continue;
        }

        if (trimmed.len == 0) continue;
        if (fenceRun(trimmed)) |f| {
            if (indented) {
                try problems.append(gpa, .{ .line = lineno, .message = "this fence is indented; write fences at the start of the line, outside lists" });
                return try blocks.toOwnedSlice(gpa);
            }
            const kind = classify(f.info) catch |e| {
                try problems.append(gpa, .{ .line = lineno, .message = switch (e) {
                    error.NoInfo => "this fence names no kind; use `scheme`, `output` or `text`",
                    error.UnknownKind => "this fence names a kind other than `scheme`, `output` or `text`",
                    error.UnknownWord => "this fence has a word this tool does not know after its kind",
                } });
                return try blocks.toOwnedSlice(gpa);
            };
            var start: usize = 0;
            if (kind.kind == .output) {
                const s = last_scheme orelse {
                    try problems.append(gpa, .{ .line = lineno, .message = "this `output` block does not follow a `scheme` block" });
                    return try blocks.toOwnedSlice(gpa);
                };
                start = s;
            }
            open = .{ .ch = f.ch, .len = f.len, .kind = kind.kind, .fresh = kind.fresh, .line = lineno, .start = start };
            last_scheme = null;
            continue;
        }
        // 引用の中のフェンスと、HTML の整形済みのブロックは、この道具が読まない場所に
        // コードを置く。どちらも断る(D1 のミューテーションの査読)。
        if (trimmed[0] == '>' and (std.mem.indexOf(u8, trimmed, "```") != null or std.mem.indexOf(u8, trimmed, "~~~") != null)) {
            try problems.append(gpa, .{ .line = lineno, .message = "this fence is inside a block quote, which this tool does not read; write fences outside quotes" });
        } else if (startsWithIgnoreCase(trimmed, "<pre") or startsWithIgnoreCase(trimmed, "<code")) {
            try problems.append(gpa, .{ .line = lineno, .message = "this HTML block may hold code this tool does not read; use a fenced block" });
        }
        // フェンスの外の、空白4つかタブで始まる行は、インデントされたコードブロックに
        // なりうる。リストの深さを読まずに、すべて断る。
        if (line[0] == '\t' or std.mem.startsWith(u8, line, "    ")) {
            try problems.append(gpa, .{ .line = lineno, .message = "this line starts with four spaces or a tab, which may make an indented code block nothing checks" });
        }
        last_scheme = null;
    }
    if (open) |o| {
        try problems.append(gpa, .{ .line = o.line, .message = "this fence is never closed" });
    }
    return try blocks.toOwnedSlice(gpa);
}

/// Whether `text` starts with `prefix`, ignoring ASCII case.
fn startsWithIgnoreCase(text: []const u8, prefix: []const u8) bool {
    return text.len >= prefix.len and std.ascii.eqlIgnoreCase(text[0..prefix.len], prefix);
}

/// Recognises a fence line: a run of at least three backticks or tildes, and what follows it.
fn fenceRun(trimmed: []const u8) ?struct { ch: u8, len: usize, info: []const u8, bare: bool } {
    if (trimmed.len < 3) return null;
    const ch = trimmed[0];
    if (ch != '`' and ch != '~') return null;
    var n: usize = 0;
    while (n < trimmed.len and trimmed[n] == ch) n += 1;
    if (n < 3) return null;
    const info = std.mem.trim(u8, trimmed[n..], " \t");
    // CommonMark: バッククォートのフェンスの情報文字列は、バッククォートを含まない。
    // 含む行は、コードスパンを含む段落である(tools/check-docs の fenceRun と同じ)。
    if (ch == '`' and std.mem.indexOfScalar(u8, info, '`') != null) return null;
    return .{ .ch = ch, .len = n, .info = info, .bare = info.len == 0 };
}

/// The kind of a block and whether it asks for a new interpreter, from its info string.
fn classify(info: []const u8) error{ NoInfo, UnknownKind, UnknownWord }!struct { kind: Kind, fresh: bool } {
    var words = std.mem.tokenizeAny(u8, info, " \t");
    const first = words.next() orelse return error.NoInfo;
    const kind = std.meta.stringToEnum(Kind, first) orelse return error.UnknownKind;
    var fresh = false;
    while (words.next()) |word| {
        if (kind == .scheme and !fresh and std.mem.eql(u8, word, "fresh")) {
            fresh = true;
            continue;
        }
        return error.UnknownWord;
    }
    return .{ .kind = kind, .fresh = fresh };
}

/// What `parse` returns for `body`, in an arena the caller frees.
const Parsed = struct {
    arena: std.heap.ArenaAllocator,
    blocks: []Block,
    problems: []Problem,

    fn of(body: []const u8) !Parsed {
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        errdefer arena.deinit();
        var problems: std.ArrayList(Problem) = .empty;
        const blocks = try parse(arena.allocator(), body, &problems);
        return .{ .arena = arena, .blocks = blocks, .problems = problems.items };
    }

    fn deinit(self: *Parsed) void {
        self.arena.deinit();
    }
};

test "a scheme block takes the output block that follows it, across blank lines" {
    var p = try Parsed.of(
        \\# Title
        \\
        \\```scheme
        \\(+ 1 2)
        \\```
        \\
        \\```output
        \\3
        \\```
        \\
    );
    defer p.deinit();
    try std.testing.expectEqual(@as(usize, 0), p.problems.len);
    try std.testing.expectEqual(@as(usize, 1), p.blocks.len);
    try std.testing.expectEqualStrings("(+ 1 2)\n", p.blocks[0].source);
    try std.testing.expectEqualStrings("3", p.blocks[0].expected);
    try std.testing.expectEqual(@as(usize, 3), p.blocks[0].line);
    try std.testing.expect(!p.blocks[0].fresh);
}

test "a scheme block with no output block expects no output, and a text block is not run" {
    var p = try Parsed.of(
        \\```scheme fresh
        \\(define x 1)
        \\```
        \\
        \\```text
        \\(if <test> <consequent>)
        \\```
        \\
        \\~~~~scheme
        \\x
        \\```
        \\~~~~
        \\
    );
    defer p.deinit();
    try std.testing.expectEqual(@as(usize, 0), p.problems.len);
    try std.testing.expectEqual(@as(usize, 2), p.blocks.len);
    try std.testing.expectEqualStrings("", p.blocks[0].expected);
    try std.testing.expect(p.blocks[0].fresh);
    // 開く側と違う文字の連なりは、ブロックを閉じない。
    try std.testing.expectEqualStrings("x\n```\n", p.blocks[1].source);
    try std.testing.expect(!p.blocks[1].fresh);
}

test "an output block that does not follow a scheme block is refused" {
    for ([_][]const u8{
        "```output\n1\n```\n",
        "```scheme\n1\n```\nprose\n```output\n1\n```\n",
        "```scheme\n1\n```\n```text\na\n```\n```output\n1\n```\n",
        "```scheme\n1\n```\n```output\n1\n```\n```output\n1\n```\n",
    }) |doc| {
        var p = try Parsed.of(doc);
        defer p.deinit();
        try std.testing.expectEqual(@as(usize, 1), p.problems.len);
        try std.testing.expectEqualStrings("this `output` block does not follow a `scheme` block", p.problems[0].message);
    }
}

test "a fence this tool cannot classify is refused" {
    for ([_]struct { doc: []const u8, line: usize }{
        .{ .doc = "```\n(+ 1 2)\n```\n", .line = 1 },
        .{ .doc = "text\n\n```lisp\n(+ 1 2)\n```\n", .line = 3 },
        .{ .doc = "```scheme run\n(+ 1 2)\n```\n", .line = 1 },
        .{ .doc = "```scheme fresh fresh\n(+ 1 2)\n```\n", .line = 1 },
        .{ .doc = "```output fresh\n1\n```\n", .line = 1 },
        .{ .doc = "- item\n\n  ```scheme\n  (+ 1 2)\n  ```\n", .line = 3 },
        .{ .doc = "```scheme\n(+ 1 2)\n", .line = 1 },
        .{ .doc = "para\n\n    (car '())\n", .line = 3 },
        .{ .doc = "para\n\n\t(car '())\n", .line = 3 },
    }) |c| {
        var p = try Parsed.of(c.doc);
        defer p.deinit();
        try std.testing.expectEqual(@as(usize, 1), p.problems.len);
        try std.testing.expectEqual(c.line, p.problems[0].line);
    }
}

test "an indented closing fence is reported, and short runs and code spans are not fences" {
    var p = try Parsed.of("```scheme\n1\n  ```\n");
    defer p.deinit();
    try std.testing.expectEqual(@as(usize, 1), p.problems.len);
    try std.testing.expectEqual(@as(usize, 3), p.problems[0].line);

    var q = try Parsed.of("``scheme``\n\n```a`b`\n\n   three spaces is prose\n");
    defer q.deinit();
    try std.testing.expectEqual(@as(usize, 0), q.problems.len);
    try std.testing.expectEqual(@as(usize, 0), q.blocks.len);
}

test "a CRLF document reads as its LF form" {
    var p = try Parsed.of("```scheme\r\n(+ 1 2)\r\n```\r\n```output\r\n3\r\n```\r\n");
    defer p.deinit();
    try std.testing.expectEqual(@as(usize, 0), p.problems.len);
    try std.testing.expectEqualStrings("(+ 1 2)\n", p.blocks[0].source);
    try std.testing.expectEqualStrings("3", p.blocks[0].expected);
}

/// Runs `body` as the document `doc.md` and returns its counts and report.
fn checkForTest(arena: std.mem.Allocator, body: []const u8) !struct { counts: Counts, report: []const u8 } {
    var report: std.Io.Writer.Allocating = .init(arena);
    var counts: Counts = .{};
    try checkFile(arena, "doc.md", body, &report.writer, &counts);
    return .{ .counts = counts, .report = report.written() };
}

test "blocks of a file share one interpreter until a fresh block" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const r = try checkForTest(arena.allocator(),
        \\```scheme
        \\(define x 41)
        \\```
        \\
        \\```scheme
        \\(+ x 1)
        \\```
        \\
        \\```output
        \\42
        \\```
        \\
        \\```scheme fresh
        \\x
        \\```
        \\
        \\```output
        \\error: unbound variable: x
        \\```
        \\
    );
    try std.testing.expectEqualStrings("", r.report);
    try std.testing.expectEqual(Counts{ .blocks = 3, .passed = 3, .failed = 0 }, r.counts);
}

test "a block whose output differs fails, and so does output where none is expected" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const r = try checkForTest(arena.allocator(),
        \\```scheme
        \\(+ 1 2)
        \\```
        \\
        \\```output
        \\4
        \\```
        \\
        \\```scheme
        \\(+ 1 2)
        \\```
        \\
    );
    try std.testing.expectEqual(Counts{ .blocks = 2, .passed = 0, .failed = 2 }, r.counts);
    try std.testing.expect(std.mem.indexOf(u8, r.report, "doc.md:1: the output differs\n  expected: 4\n  got:      3\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.report, "doc.md:9: the output differs\n  expected: \n  got:      3\n") != null);
}

test "what a block writes comes before its values and its error" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const r = try checkForTest(arena.allocator(),
        \\```scheme
        \\(import (scheme write))
        \\(display "hi")
        \\1
        \\(car '())
        \\2
        \\```
        \\
        \\```output
        \\hi1
        \\error: wrong type of argument to car ()
        \\```
        \\
    );
    try std.testing.expectEqualStrings("", r.report);
    try std.testing.expectEqual(Counts{ .blocks = 1, .passed = 1, .failed = 0 }, r.counts);
}

test "a file that cannot be read in full runs none of its blocks" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const r = try checkForTest(arena.allocator(), "```scheme\n(+ 1 2)\n```\n```lisp\n1\n```\n");
    try std.testing.expectEqual(Counts{ .blocks = 0, .passed = 0, .failed = 1 }, r.counts);
}

test "a quoted fence and an HTML code block are refused" {
    for ([_]struct { doc: []const u8, line: usize }{
        .{ .doc = "> ```scheme\n> (car 1)\n> ```\n", .line = 1 },
        .{ .doc = "text\n\n> ~~~\n", .line = 3 },
        .{ .doc = "<pre>\n(car 2)\n</pre>\n", .line = 1 },
        .{ .doc = "<PRE class=\"x\">\n", .line = 1 },
        .{ .doc = "<code>(car 3)</code>\n", .line = 1 },
        .{ .doc = "<CODE>(car 3)</CODE>\n", .line = 1 },
        .{ .doc = "  <pre>\n(car 4)\n", .line = 1 },
        .{ .doc = ">```scheme\n>(car 5)\n>```\n", .line = 1 },
        .{ .doc = ">> ```scheme\n>> (car 6)\n>> ```\n", .line = 1 },
    }) |c| {
        var p = try Parsed.of(c.doc);
        defer p.deinit();
        try std.testing.expect(p.problems.len >= 1);
        try std.testing.expectEqual(c.line, p.problems[0].line);
    }
    // 引用の地の文と、ほかの HTML は断らない。
    var q = try Parsed.of("> a quote with `code`\n\n<details>\n");
    defer q.deinit();
    try std.testing.expectEqual(@as(usize, 0), q.problems.len);
}

test "a closing fence needs the same character, at least the same length, and nothing after it" {
    var p = try Parsed.of("````scheme\n```\n```x\n~~~~\n`````\n");
    defer p.deinit();
    try std.testing.expectEqual(@as(usize, 0), p.problems.len);
    try std.testing.expectEqual(@as(usize, 1), p.blocks.len);
    try std.testing.expectEqualStrings("```\n```x\n~~~~\n", p.blocks[0].source);

    // 後ろに語のある連なりは、長さが足りても閉じない。
    var q = try Parsed.of("```scheme\n```x\n```\n");
    defer q.deinit();
    try std.testing.expectEqual(@as(usize, 0), q.problems.len);
    try std.testing.expectEqualStrings("```x\n", q.blocks[0].source);
}

test "the exit status is 1 exactly when something failed" {
    try std.testing.expectEqual(@as(u8, 0), exitStatus(.{ .blocks = 3, .passed = 3, .failed = 0 }));
    try std.testing.expectEqual(@as(u8, 1), exitStatus(.{ .blocks = 3, .passed = 2, .failed = 1 }));
    try std.testing.expectEqual(@as(u8, 1), exitStatus(.{ .blocks = 0, .passed = 0, .failed = 1 }));
    // 256 件の失敗も 1 になる(件数を u8 に切り詰めると 0 になる)。
    try std.testing.expectEqual(@as(u8, 1), exitStatus(.{ .blocks = 256, .passed = 0, .failed = 256 }));
}

/// A file of a directory a test writes.
const TestFile = struct { path: []const u8, data: []const u8 };

/// Writes `files` into a new directory, runs it, and returns the counts and the report.
fn runForTest(arena: std.mem.Allocator, files: []const TestFile) !struct { counts: Counts, report: []const u8 } {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    for (files) |f| {
        if (std.fs.path.dirname(f.path)) |d| try tmp.dir.createDirPath(std.testing.io, d);
        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = f.path, .data = f.data });
    }
    var report: std.Io.Writer.Allocating = .init(arena);
    const counts = try run(arena, std.testing.io, tmp.dir, "manual", &report.writer);
    return .{ .counts = counts, .report = report.written() };
}

const passing_doc = "```scheme\n(+ 1 2)\n```\n\n```output\n3\n```\n";

test "a directory of passing documents passes, nested ones included" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const r = try runForTest(arena.allocator(), &.{
        .{ .path = "a.md", .data = passing_doc },
        .{ .path = "sub/b.md", .data = passing_doc },
        .{ .path = "x/y/z/c.md", .data = passing_doc },
    });
    try std.testing.expectEqualStrings("", r.report);
    try std.testing.expectEqual(Counts{ .blocks = 3, .passed = 3, .failed = 0 }, r.counts);
    try std.testing.expectEqual(@as(u8, 0), exitStatus(r.counts));
}

test "a run with no document, no block, a failing block or a file that is not Markdown fails" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cases = [_]struct { files: []const TestFile, says: []const u8 }{
        .{ .files = &.{}, .says = "check-examples: no `.md` file under manual\n" },
        .{ .files = &.{.{ .path = "a.md", .data = "# Only prose\n" }}, .says = "check-examples: no `scheme` block was run\n" },
        .{ .files = &.{ .{ .path = "a.md", .data = passing_doc }, .{ .path = "x.scm", .data = "(car 1)\n" } }, .says = "manual/x.scm: not a `.md` file, so nothing here checks it\n" },
        .{ .files = &.{.{ .path = "a.md", .data = "```scheme\n(+ 1 2)\n```\n\n```output\n4\n```\n" }}, .says = "manual/a.md:1: the output differs\n" },
        .{ .files = &.{.{ .path = "a.md", .data = "```lisp\n1\n```\n" }}, .says = "manual/a.md:1: this fence names a kind other than" },
    };
    for (cases) |c| {
        const r = try runForTest(a, c.files);
        try std.testing.expect(r.counts.failed >= 1);
        try std.testing.expectEqual(@as(u8, 1), exitStatus(r.counts));
        try std.testing.expect(std.mem.indexOf(u8, r.report, c.says) != null);
    }
}
