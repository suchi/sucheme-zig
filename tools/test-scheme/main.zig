//! Runs the Scheme behaviour tests under tests/scheme/.
//!
//! `zig build test-scheme` で走らせる。tests/scheme/ の `*.txt` ファイルをすべて
//! 読み、その中の各ケースを、REPL と同じ入口 `sucheme.Interpreter.evalPrint`
//! を通してプロセス内で評価する。このため1つのケースが、リーダ、評価器、
//! プリンタをまとめて試す。
//!
//! ファイルの形式は次のとおりである。
//!
//! - `#` だけの行、または `# ` で始まる行はコメントである。行頭が `#` なだけでは
//!   足りない。`#t`、`#(1 2)`、`#\a` はデータだからである。
//! - 空行はケースを終わらせる。
//! - ケースの最初のコメントでない行が入力である。その後ろから空行までの
//!   各行が期待する出力で、改行でつないで1つにする。
//!
//! 何も出力しないケースは、期待する行として `<no output>` と書く。
//!
//! ファイルのどこかに `# env: core` だけの行があると、そのファイルのケースはすべて、
//! `(sucheme core)` を直接見る最上位で走る。標準ライブラリが輸出しない内部の名前
//! (`%make-record-type` など)を直接呼ぶ、低水準のプリミティブのテストのためである。
//! 指示のないファイルは、REPL と同じ標準の環境(`(scheme base)`)で走る。
//!
//! エラーは出力の一部である。その行がエラーより前に出力したものの後に、
//! REPL が出すとおり、`error: ` とインタプリタのメッセージが続く。
//!
//! 入力があって期待する出力がないケースは、読み飛ばさず報告する。行が
//! 欠けていると、そのケースは何とも比較されなくなるからである。
//!
//! 引数は取らない。build.zig が、引数が渡されていないことを検査する。より狭い
//! ディレクトリやフィルタを指す引数は、実行するケースを減らしたままこの step を
//! 通す、1行で済む手口になるからである。同じ理由で、tests/scheme/ の中の
//! `.txt` でないエントリ、ケースのないファイル、ケースが1つもない実行は、
//! 失敗とする。

const std = @import("std");
const sucheme = @import("sucheme");

const tier = @import("tier");

/// Where the cases of every run are.
///
/// 規模を確かめるケースは2つ目のディレクトリにある。これを読むのは、遅い段を
/// 求められた実行(`-Dslow=true`)だけである。docs/plans/0007-test-tiers.md を
/// 参照。
const tests_dir = "tests/scheme";
const slow_dir = "tests/scheme-slow";

/// The expected text of a case that prints nothing, such as a definition.
///
/// ケースには期待する行が要るので、空の出力は書き表す必要がある。値のプリンタは
/// これを書かない。空白を含むシンボルは縦棒付きで書かれるからである。値でない
/// 出力、たとえばスライス1h で入る `display` が書くテキストは、これと同じに
/// なりうる。それが入るときは、この印を、どの出力にもなりえない綴りに移さ
/// なければならない。
const no_output = "<no output>";

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();
    const io = init.io;
    const cwd = std.Io.Dir.cwd();

    var buf: [4096]u8 = undefined;
    // src/main.zig が述べる理由でストリーミングにする。位置指定のライタは、
    // 追記されるログの先頭を上書きしてしまう。
    var stderr = std.Io.File.Writer.initStreaming(.stderr(), io, &buf);
    const err = &stderr.interface;

    const argv = try init.minimal.args.toSlice(gpa);
    if (argv.len > 1) {
        try err.print("test-scheme: takes no arguments, got {s}\n", .{argv[1]});
        try err.flush();
        std.process.exit(2);
    }

    var failed: usize = 0;
    var passed: usize = 0;
    const dirs: []const []const u8 = if (tier.slow) &.{ tests_dir, slow_dir } else &.{tests_dir};
    for (dirs) |dir_name| {
        var names: std.ArrayList([]const u8) = .empty;
        var dir = cwd.openDir(io, dir_name, .{ .iterate = true }) catch |e| {
            try err.print("test-scheme: cannot open {s} ({t})\n", .{ dir_name, e });
            try err.flush();
            std.process.exit(1);
        };
        defer dir.close(io);
        var it = dir.iterate();
        while (try it.next(io)) |entry| {
            // `.txt` ファイルでないものは、読み飛ばさず報告する。`0002.TXT` や
            // `0002.scm` として、あるいはサブディレクトリの中に保存されたテストは、
            // 報告しなければ、step が緑のまま一度も走らない。
            if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".txt")) {
                try err.print("{s}/{s}: not a `.txt` file, so its cases would never run\n", .{ dir_name, entry.name });
                failed += 1;
                continue;
            }
            try names.append(gpa, try gpa.dupe(u8, entry.name));
        }
        // ディレクトリの順序はホストごとに違う。ソートして報告を安定させる。
        std.mem.sort([]const u8, names.items, {}, lessThan);

        for (names.items) |name| {
            const path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ dir_name, name });
            const body = cwd.readFileAlloc(io, path, gpa, .unlimited) catch |e| {
                try err.print("{s}: cannot be read ({t})\n", .{ path, e });
                failed += 1;
                continue;
            };
            var cases: std.ArrayList(Case) = .empty;
            parse(gpa, body, &cases) catch |e| switch (e) {
                error.MissingExpected => {
                    try err.print("{s}: a case has an input and no expected output\n", .{path});
                    failed += 1;
                    continue;
                },
                error.OutOfMemory => return e,
            };
            if (hasCoreDirective(body)) for (cases.items) |*c| {
                c.core = true;
            };
            // ケースのないファイルは、ファイルが欠けているのと同じくらい疑わしい。
            // コメントだけのファイルや、すべてをコメントとして解析してしまう形式の
            // 変更が考えられる。
            if (cases.items.len == 0) {
                try err.print("{s}: no case found in this file\n", .{path});
                failed += 1;
            }
            for (cases.items) |c| {
                for (modes) |mode| {
                    if (try runCaseWith(gpa, mode.options, c)) |got| {
                        try err.print(
                            "{s}:{d}: {s}\n  mode:     {s}\n  expected: {s}\n  got:      {s}\n",
                            .{ path, c.line, c.input, mode.name, c.expected, got },
                        );
                        failed += 1;
                    } else passed += 1;
                }
            }
        }
    }

    const mutation = try checkMutators(gpa, io, err);
    passed += mutation.passed;
    failed += mutation.failed;

    try err.print("test-scheme: {d} passed, {d} failed\n", .{ passed, failed });
    try err.flush();
    const status = exitStatus(passed, failed);
    if (status != 0) std.process.exit(status);
}

/// The exit status for a run.
///
/// ケースが1つも見つからないのは失敗である。何も読まなかった実行器は、何も
/// 検証していないからである。
fn exitStatus(passed: usize, failed: usize) u8 {
    if (failed != 0 or passed == 0) return 1;
    return 0;
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// One input and the output it should produce.
const Case = struct {
    /// The 1-based line of the input, for the report.
    line: usize,
    input: []const u8,
    /// The expected lines joined with `\n`, without a trailing newline.
    expected: []const u8,
    /// Whether the case runs at a top level that sees `(sucheme core)` itself
    /// (`# env: core` in its file), and not the standard environment.
    core: bool = false,
};

/// The line of a test file that asks for the top level that sees `(sucheme core)`.
const core_directive = "# env: core";

/// Whether `body` has the line `core_directive`.
fn hasCoreDirective(body: []const u8) bool {
    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |l| {
        if (std.mem.eql(u8, std.mem.trimEnd(u8, l, "\r"), core_directive)) return true;
    }
    return false;
}

/// Splits a test file into its cases.
///
/// 形式はファイルの doc コメントを参照。
fn parse(gpa: std.mem.Allocator, body: []const u8, out: *std.ArrayList(Case)) error{ OutOfMemory, MissingExpected }!void {
    var input: ?[]const u8 = null;
    var input_line: usize = 0;
    var expected: std.ArrayList(u8) = .empty;
    var expected_lines: usize = 0;

    var lines = std.mem.splitScalar(u8, body, '\n');
    var lineno: usize = 0;
    while (true) {
        const next = lines.next();
        lineno += 1;
        // CRLF でチェックアウトしたものも、LF のものと同じに読めなければならない。
        const line = if (next) |l| std.mem.trimEnd(u8, l, "\r") else "";
        if (next != null and isComment(line)) continue;
        if (line.len == 0) {
            if (input) |in| {
                if (expected_lines == 0) return error.MissingExpected;
                var text = try expected.toOwnedSlice(gpa);
                if (std.mem.eql(u8, text, no_output)) {
                    gpa.free(text);
                    text = "";
                }
                try out.append(gpa, .{ .line = input_line, .input = in, .expected = text });
                input = null;
                expected_lines = 0;
            }
            if (next == null) return;
            continue;
        }
        if (input == null) {
            input = line;
            input_line = lineno;
            continue;
        }
        if (expected_lines != 0) try expected.append(gpa, '\n');
        try expected.appendSlice(gpa, line);
        expected_lines += 1;
    }
}

fn isComment(line: []const u8) bool {
    return std.mem.eql(u8, line, "#") or std.mem.startsWith(u8, line, "# ");
}

/// The ways every case is run.
///
/// 2つ目は、ケースが短い間、機械の1ステップごとに GC を走らせる。機械がコレクタに
/// 知らせていないルートは、運によってではなく、すぐに解放される(ADR-0031)。
/// 1つ目でしか通らないケースには、1つ目が隠しているバグがある。どちらも、ヒープの
/// 上限を既定より小さくする。戻らない再帰は、エラーになる前にそれを埋めなければ
/// ならない。一方で上限は、ケースの最も深い再帰が必要とする量より上に保つ。
const modes = [_]struct { name: []const u8, options: sucheme.heap.Options }{
    .{ .name = "default", .options = .{ .limit = 64 * 1024 * 1024 } },
    .{ .name = "collect at every step", .options = .{ .limit = 64 * 1024 * 1024, .stress = true } },
};

/// Evaluates one case.
///
/// 出力が一致すれば null を返し、そうでなければ代わりに出力されたものを返す。
/// 報告に示すためである。結果は呼び出し側が所有する。
fn runCase(gpa: std.mem.Allocator, c: Case) error{OutOfMemory}!?[]const u8 {
    return runCaseWith(gpa, modes[0].options, c);
}

fn runCaseWith(gpa: std.mem.Allocator, options: sucheme.heap.Options, c: Case) error{OutOfMemory}!?[]const u8 {
    const got = try evaluate(gpa, options, c);
    if (std.mem.eql(u8, got, c.expected)) {
        gpa.free(got);
        return null;
    }
    return got;
}

/// The text a case prints: what the input writes, then the error if it ends with one.
/// The result is a copy in `gpa`.
fn evaluate(gpa: std.mem.Allocator, options: sucheme.heap.Options, c: Case) error{OutOfMemory}![]const u8 {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var interp: sucheme.Interpreter = undefined;
    // ヒープはコレクタが死んでいると判断したものを解放するので、メモリを返す
    // アロケータが要る。`gpa` はアリーナであり、返さない。デバッグビルドの
    // 汎用アロケータは確保のたびにスタックトレースを記録し、100万回の呼び出しの
    // ループに数分かかってしまう。
    if (c.core) try interp.initCoreWithOptions(std.heap.smp_allocator, options) else try interp.initWithOptions(std.heap.smp_allocator, options);
    defer interp.deinit();
    interp.evalPrint(arena.allocator(), c.input, &out.writer) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        // ライタは確保を行うので、失敗するのはメモリ不足のときだけである。
        error.WriteFailed => return error.OutOfMemory,
        // REPL が出すとおりに出力する。その行が失敗する前に書いたものの後に置く。
        else => out.writer.print("error: {s}\n", .{interp.diagnostic()}) catch return error.OutOfMemory,
    };
    // evalPrint はすべての結果を改行で終える。期待するテキストは、最後の行の
    // 後に改行を持たない。
    return try gpa.dupe(u8, std.mem.trimEnd(u8, out.written(), "\n"));
}

/// One mutation procedure of R7RS chapter 6 with a call that writes into a constant.
const Mutator = struct {
    name: []const u8,
    input: []const u8,
    /// The procedure the refusal names, when it is not `name`: `list-set!` is written in
    /// Scheme, and the `set-car!` it calls refuses.
    refused_by: ?[]const u8 = null,
};

/// A call for every procedure whose name ends with `!` in `tests/r7rs-required`, except
/// the syntax `set!`, that the interpreter binds.
/// Why: 定数への書き込みを断る検査を、1つの手続きに入れ忘れても、どのテストも落ちない。
/// 束縛済みの `!` 付き手続きがこの表にそろっていることを、`checkMutators` が毎回見る。
/// 表にない手続きが束縛されたら、実行が失敗する。
const mutators = [_]Mutator{
    .{ .name = "bytevector-copy!", .input = "(bytevector-copy! #u8(1 2) 0 #u8(3))" },
    .{ .name = "bytevector-u8-set!", .input = "(bytevector-u8-set! #u8(1 2) 0 0)" },
    .{ .name = "list-set!", .input = "(list-set! '(0 1 2) 1 \"oops\")", .refused_by = "set-car!" },
    .{ .name = "set-car!", .input = "(set-car! '(1 2) 0)" },
    .{ .name = "set-cdr!", .input = "(set-cdr! '(1 2) 0)" },
    .{ .name = "string-copy!", .input = "(string-copy! \"abc\" 0 \"xy\")" },
    .{ .name = "string-fill!", .input = "(string-fill! \"abc\" #\\x)" },
    .{ .name = "string-set!", .input = "(string-set! \"abc\" 0 #\\x)" },
    .{ .name = "vector-copy!", .input = "(vector-copy! #(1 2) 0 #(3))" },
    .{ .name = "vector-fill!", .input = "(vector-fill! #(1 2) 0)" },
    .{ .name = "vector-set!", .input = "(vector-set! #(1 2) 0 0)" },
};

/// Whether `id` names a mutation procedure: it ends with `!`, and it is not the syntax `set!`.
fn isMutatorName(id: []const u8) bool {
    return std.mem.endsWith(u8, id, "!") and !std.mem.eql(u8, id, "set!");
}

/// The report of a call that must refuse to write into a constant, or null when it does.
fn mutatorFailure(got: []const u8, name: []const u8, buf: []u8) ?[]const u8 {
    const expected = std.fmt.bufPrint(buf, "error: cannot modify a constant in {s} ", .{name}) catch return "name too long";
    if (std.mem.startsWith(u8, got, expected)) return null;
    return got;
}

/// Checks that every bound mutation procedure refuses a constant, and that the table
/// `mutators` has a call for each.
///
/// 入力は `tests/r7rs-required/*.txt` の、`!` で終わる名前である。名前が束縛済みで表になければ、
/// 表が古い。表にあって入力に無い名前も、表が古い。ADR-0026 の線引きに従い、散文の一覧ではなく、
/// 束縛済みのものがコードの事実として定数を断ることを見る。戻り値は、数えた成功と失敗である。
fn checkMutators(
    gpa: std.mem.Allocator,
    io: std.Io,
    err: *std.Io.Writer,
) !struct { passed: usize, failed: usize } {
    var passed: usize = 0;
    var failed: usize = 0;
    var required: std.StringHashMapUnmanaged(void) = .empty;
    var dir = std.Io.Dir.cwd().openDir(io, "tests/r7rs-required", .{ .iterate = true }) catch |e| {
        try err.print("test-scheme: cannot open tests/r7rs-required ({t})\n", .{e});
        return .{ .passed = 0, .failed = 1 };
    };
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".txt")) continue;
        const text = try dir.readFileAlloc(io, entry.name, gpa, .unlimited);
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |raw| {
            const id = std.mem.trim(u8, raw, &std.ascii.whitespace);
            if (id.len == 0 or id[0] == ';' or !isMutatorName(id)) continue;
            try required.put(gpa, id, {});
        }
    }
    if (required.count() == 0) {
        try err.print("test-scheme: tests/r7rs-required lists no procedure that ends with `!`\n", .{});
        return .{ .passed = 0, .failed = 1 };
    }

    // 束縛済みかは、標準の環境を作って尋ねる。
    var probe: sucheme.Interpreter = undefined;
    try probe.init(std.heap.smp_allocator);
    defer probe.deinit();
    var names = required.keyIterator();
    while (names.next()) |name| {
        if (!probe.isBound(name.*)) continue;
        const listed = for (mutators) |m| {
            if (std.mem.eql(u8, m.name, name.*)) break true;
        } else false;
        if (!listed) {
            try err.print("test-scheme: {s} is bound, and `mutators` has no call that writes into a constant\n", .{name.*});
            failed += 1;
        }
    }
    for (mutators) |m| {
        if (!required.contains(m.name)) {
            try err.print("test-scheme: `mutators` names {s}, which tests/r7rs-required does not list\n", .{m.name});
            failed += 1;
            continue;
        }
        for (modes) |mode| {
            const got = try evaluate(gpa, mode.options, .{ .line = 0, .input = m.input, .expected = "" });
            var buf: [128]u8 = undefined;
            if (mutatorFailure(got, m.refused_by orelse m.name, &buf)) |bad| {
                try err.print(
                    "{s}\n  mode:     {s}\n  expected: error: cannot modify a constant in {s} ...\n  got:      {s}\n",
                    .{ m.input, mode.name, m.refused_by orelse m.name, bad },
                );
                failed += 1;
            } else passed += 1;
        }
    }
    return .{ .passed = passed, .failed = failed };
}

test "set! is the syntax, and the other names that end with ! are mutation procedures" {
    try std.testing.expect(!isMutatorName("set!"));
    try std.testing.expect(isMutatorName("set-car!"));
    try std.testing.expect(isMutatorName("vector-fill!"));
    try std.testing.expect(!isMutatorName("string-copy"));
    try std.testing.expect(!isMutatorName("!"[0..0]));
}

test "a call that is refused names its procedure, and any other text is a failure" {
    var buf: [128]u8 = undefined;
    try std.testing.expect(mutatorFailure("error: cannot modify a constant in set-car! (1 2) 0", "set-car!", &buf) == null);
    try std.testing.expect(mutatorFailure("error: cannot modify a constant in set-cdr! (1 2) 0", "set-car!", &buf) != null);
    try std.testing.expect(mutatorFailure("(1 2)", "set-car!", &buf) != null);
    try std.testing.expect(mutatorFailure("error: unbound variable: set-car!", "set-car!", &buf) != null);
}

test "the table has one call for each name, and each name is a mutation procedure" {
    for (mutators, 0..) |m, i| {
        try std.testing.expect(isMutatorName(m.name));
        for (mutators[0..i]) |earlier| try std.testing.expect(!std.mem.eql(u8, earlier.name, m.name));
    }
}

test "a file asks for the top level that sees core with a line of its own" {
    try std.testing.expect(hasCoreDirective("# comment\n# env: core\n\n(+ 1 2)\n3\n"));
    try std.testing.expect(hasCoreDirective("# env: core\r\n(+ 1 2)\r\n3\r\n"));
    try std.testing.expect(!hasCoreDirective("# env: core and more\n(+ 1 2)\n3\n"));
    try std.testing.expect(!hasCoreDirective("(+ 1 2)\n3\n"));
}

test "parse reads an input and its expected line" {
    var cases: std.ArrayList(Case) = .empty;
    try parse(std.testing.allocator, "# comment\n\n(+ 1 2)\n3\n", &cases);
    defer {
        for (cases.items) |c| std.testing.allocator.free(c.expected);
        cases.deinit(std.testing.allocator);
    }
    try std.testing.expectEqual(1, cases.items.len);
    try std.testing.expectEqualStrings("(+ 1 2)", cases.items[0].input);
    try std.testing.expectEqualStrings("3", cases.items[0].expected);
    try std.testing.expectEqual(3, cases.items[0].line);
}

test "parse separates cases on a blank line and keeps the last without one" {
    var cases: std.ArrayList(Case) = .empty;
    try parse(std.testing.allocator, "1\n1\n\n2\n2", &cases);
    defer {
        for (cases.items) |c| std.testing.allocator.free(c.expected);
        cases.deinit(std.testing.allocator);
    }
    try std.testing.expectEqual(2, cases.items.len);
    try std.testing.expectEqualStrings("2", cases.items[1].input);
    try std.testing.expectEqual(4, cases.items[1].line);
}

test "parse joins several expected lines" {
    var cases: std.ArrayList(Case) = .empty;
    try parse(std.testing.allocator, "1 2\n1\n2\n", &cases);
    defer {
        for (cases.items) |c| std.testing.allocator.free(c.expected);
        cases.deinit(std.testing.allocator);
    }
    try std.testing.expectEqualStrings("1\n2", cases.items[0].expected);
}

test "parse reads a CRLF file the same as an LF one" {
    var cases: std.ArrayList(Case) = .empty;
    try parse(std.testing.allocator, "# c\r\n\r\n(+ 1 2)\r\n3\r\n", &cases);
    defer {
        for (cases.items) |c| std.testing.allocator.free(c.expected);
        cases.deinit(std.testing.allocator);
    }
    try std.testing.expectEqual(1, cases.items.len);
    try std.testing.expectEqualStrings("(+ 1 2)", cases.items[0].input);
    try std.testing.expectEqualStrings("3", cases.items[0].expected);
}

test "parse rejects an input with no expected output" {
    var cases: std.ArrayList(Case) = .empty;
    defer cases.deinit(std.testing.allocator);
    try std.testing.expectError(error.MissingExpected, parse(std.testing.allocator, "(+ 1 2)\n\n", &cases));
    try std.testing.expectError(error.MissingExpected, parse(std.testing.allocator, "(+ 1 2)", &cases));
}

test "parse reads a line starting with a datum's # as part of a case" {
    var cases: std.ArrayList(Case) = .empty;
    try parse(std.testing.allocator, "#\n#t\n#t\n", &cases);
    defer {
        for (cases.items) |c| std.testing.allocator.free(c.expected);
        cases.deinit(std.testing.allocator);
    }
    try std.testing.expectEqual(1, cases.items.len);
    try std.testing.expectEqualStrings("#t", cases.items[0].input);
    try std.testing.expectEqualStrings("#t", cases.items[0].expected);
}

test "parse finds no case in a file of comments" {
    var cases: std.ArrayList(Case) = .empty;
    defer cases.deinit(std.testing.allocator);
    try parse(std.testing.allocator, "# only\n# comments\n", &cases);
    try std.testing.expectEqual(0, cases.items.len);
}

test "runCase returns null when the output matches and what it got when not" {
    const gpa = std.testing.allocator;
    try std.testing.expect(try runCase(gpa, .{ .line = 1, .input = "(+ 1 2)", .expected = "3" }) == null);
    const got = (try runCase(gpa, .{ .line = 1, .input = "(+ 1 2)", .expected = "4" })).?;
    defer gpa.free(got);
    try std.testing.expectEqualStrings("3", got);
}

test "runCase reports an error as a mismatch, and does not match its own text by accident" {
    const gpa = std.testing.allocator;
    const got = (try runCase(gpa, .{ .line = 1, .input = "(foo)", .expected = "3" })).?;
    defer gpa.free(got);
    try std.testing.expectEqualStrings("error: unbound variable: foo", got);
}

test "runCase matches an error with the output that came before it" {
    const gpa = std.testing.allocator;
    try std.testing.expect(try runCase(gpa, .{
        .line = 1,
        .input = "1 (foo)",
        .expected = "1\nerror: unbound variable: foo",
    }) == null);
}

test "runCase compares the whole output, not a prefix or a trimmed form" {
    const gpa = std.testing.allocator;
    for ([_][]const u8{ "", "3 ", " 3", "3\n3" }) |expected| {
        const got = try runCase(gpa, .{ .line = 1, .input = "(+ 1 2)", .expected = expected });
        defer if (got) |g| gpa.free(g);
        try std.testing.expect(got != null);
    }
}

test "exitStatus fails on a failure and on a run that read no case" {
    try std.testing.expectEqual(0, exitStatus(7, 0));
    try std.testing.expectEqual(1, exitStatus(7, 1));
    try std.testing.expectEqual(1, exitStatus(0, 1));
    try std.testing.expectEqual(1, exitStatus(0, 0));
}

test "parse reads <no output> as an empty expectation" {
    var cases: std.ArrayList(Case) = .empty;
    try parse(std.testing.allocator, "(define x 1)\n<no output>\n\n(+ 1 2)\n3\n", &cases);
    defer {
        for (cases.items) |c| if (c.expected.len != 0) std.testing.allocator.free(c.expected);
        cases.deinit(std.testing.allocator);
    }
    try std.testing.expectEqual(2, cases.items.len);
    try std.testing.expectEqualStrings("", cases.items[0].expected);
    try std.testing.expectEqualStrings("3", cases.items[1].expected);
}

test "<no output> only stands alone: with other lines it is text" {
    var cases: std.ArrayList(Case) = .empty;
    try parse(std.testing.allocator, "1\n<no output>\n2\n", &cases);
    defer {
        for (cases.items) |c| std.testing.allocator.free(c.expected);
        cases.deinit(std.testing.allocator);
    }
    try std.testing.expectEqualStrings("<no output>\n2", cases.items[0].expected);
}

test "runCase matches an empty expectation only against no output" {
    const gpa = std.testing.allocator;
    try std.testing.expect(try runCase(gpa, .{ .line = 1, .input = "  ", .expected = "" }) == null);
    const got = (try runCase(gpa, .{ .line = 1, .input = "1", .expected = "" })).?;
    defer gpa.free(got);
    try std.testing.expectEqualStrings("1", got);
}
