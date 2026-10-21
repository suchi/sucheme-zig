//! Generates docs/status/conformance.md: for each R7RS standard library, how
//! many of its required identifiers the interpreter binds, and for each section of
//! the vendored conformance suite, how its tests came out.
//!
//! 1つ目の表の入力は `tests/r7rs-required/*.txt` で、各識別子が束縛済みかは、そのライブラリだけを
//! `import` した空の最上位で `sucheme.Interpreter.isBound` に尋ねる(埋め込みの `lib/` の
//! 輸出を見る)。エラー文言の分類では答えない。
//!
//! 2つ目の表は、取り込んだ準拠スイート(tests/vendor/r7rs-tests.scm)を、準拠スイートの実行器
//! (tools/conformance-run の run.zig)と同じ `runVendored` で走らせた節ごとの数である(スライス 6f)。
//! スイートの SHA-256 が実行器の定数と違うか、実行器が自分の誤りを報告したら、表を作らずに
//! 非ゼロで終わる。
//!
//! 既定の動作は比較である。生成し直した結果を現在のファイルと照らし合わせ、
//! 差があれば非ゼロで終了して直し方を標準エラーに出す。`zig build
//! check-report` がこれを走らせる。書き込みは `--write` で行う(`zig build
//! report` がそうする)。
//!
//! 比較を既定にしたのは tools/extract-r7rs-required と同じ理由である。逆にすると、
//! build.zig から引数を1つ消すだけで、検査が書き換えに変わり、失敗しえなくなる。
//!
//! 意味論テストの結果は読まない。これが入る段階は docs/design/r7rs-coverage.md にある。

const std = @import("std");
const sucheme = @import("sucheme");
const conformance = @import("conformance");

const required_dir = "tests/r7rs-required";
const report_path = "docs/status/conformance.md";

const usage = "usage: coverage-report [--check | --write]\n";

/// What the program is asked to do.
const Mode = enum { check, write };

/// What the arguments ask for: a mode, or the first argument this program does
/// not know.
const Parsed = union(enum) {
    mode: Mode,
    unknown: []const u8,
};

/// Reads the arguments after the program name.
/// 既定は比較である。書き込みになるのは `--write` があるときだけで、これを純粋な
/// 関数にして単体テストで固定するのは、ここを1トークン書き換えるだけで、検査が
/// 黙って書き換えに変わるからである(build.zig の引数の検査はこの内側を見ない)。
fn parseArgs(args: []const [:0]const u8) Parsed {
    var mode: Mode = .check;
    for (args) |arg| {
        // `--check` は受け付け、既定と同じ意味にする。
        if (std.mem.eql(u8, arg, "--check")) continue;
        if (std.mem.eql(u8, arg, "--write")) {
            mode = .write;
            continue;
        }
        return .{ .unknown = arg };
    }
    return .{ .mode = mode };
}

/// One standard library and the identifiers R7RS requires it to export.
const Library = struct {
    /// The file name without `.txt`, such as `base` for `(scheme base)`.
    name: []const u8,
    ids: []const []const u8,
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();
    const io = init.io;
    const cwd = std.Io.Dir.cwd();

    var ebuf: [4096]u8 = undefined;
    var stderr = std.Io.File.Writer.initStreaming(.stderr(), io, &ebuf);
    const err = &stderr.interface;

    const argv = try init.minimal.args.toSlice(gpa);
    const mode: Mode = switch (parseArgs(argv[1..])) {
        .mode => |m| m,
        .unknown => |arg| {
            // 綴りを間違えたフラグを無視すると、呼び出し側は、得られていないものを
            // 頼んだつもりになってしまう。
            try err.print("unknown argument {s}\n{s}", .{ arg, usage });
            try err.flush();
            std.process.exit(2);
        },
    };

    var libs: std.ArrayList(Library) = .empty;
    var dir = cwd.openDir(io, required_dir, .{ .iterate = true }) catch |e| {
        try err.print("cannot open {s}: {t}\nrun this from the repository root\n", .{ required_dir, e });
        try err.flush();
        std.process.exit(1);
    };
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".txt")) continue;
        const stem = try gpa.dupe(u8, entry.name[0 .. entry.name.len - ".txt".len]);
        const body = try dir.readFileAlloc(io, entry.name, gpa, .unlimited);
        const ids = try parseIdentifiers(gpa, body);
        // 識別子が0個のライブラリは「0 / 0」と読まれ、何も要求していないことに
        // なる。分母が黙って消えるので、失敗にする。
        if (ids.len == 0) {
            try err.print("{s}/{s} lists no identifier\n", .{ required_dir, entry.name });
            try err.flush();
            std.process.exit(1);
        }
        try libs.append(gpa, .{ .name = stem, .ids = ids });
    }
    if (libs.items.len == 0) {
        try err.print("{s} holds no `.txt` file\n", .{required_dir});
        try err.flush();
        std.process.exit(1);
    }
    // ディレクトリの順序はホストごとに違う。ソートして出力を安定させる。
    std.mem.sort(Library, libs.items, {}, libraryLessThan);

    const suite = try runVendoredSuite(gpa, io, cwd, err, libs.items);

    var report: std.Io.Writer.Allocating = .init(gpa);
    try render(gpa, &report.writer, libs.items);
    try renderSuite(&report.writer, suite);
    const generated = report.written();

    if (mode == .check) {
        const existing = cwd.readFileAlloc(io, report_path, gpa, .unlimited) catch |e| {
            try err.print("cannot read {s}: {t}\n", .{ report_path, e });
            try staleHelp(err);
            std.process.exit(1);
        };
        if (!std.mem.eql(u8, existing, generated)) {
            try err.print("{s} is not what this program generates\n", .{report_path});
            try staleHelp(err);
            std.process.exit(1);
        }
        return;
    }

    var file = try cwd.createFile(io, report_path, .{});
    defer file.close(io);
    var wbuf: [4096]u8 = undefined;
    var fw = file.writer(io, &wbuf);
    try fw.interface.writeAll(generated);
    try fw.interface.flush();
}

fn staleHelp(err: *std.Io.Writer) !void {
    try err.print("run `zig build report` and commit the result\n", .{});
    try err.flush();
}

/// Runs the vendored suite after checking its digest, or exits with the reason.
fn runVendoredSuite(
    gpa: std.mem.Allocator,
    io: std.Io,
    cwd: std.Io.Dir,
    err: *std.Io.Writer,
    libs: []const Library,
) !conformance.SuiteResult {
    const path = conformance.suite_path;
    const text = cwd.readFileAlloc(io, path, gpa, .unlimited) catch |e| {
        try err.print("cannot read {s}: {t}\n", .{ path, e });
        try err.flush();
        std.process.exit(1);
    };
    var required: std.ArrayList([]const u8) = .empty;
    for (libs) |lib| try required.appendSlice(gpa, lib.ids);
    return conformance.runVendored(gpa, text, required.items) catch |e| {
        if (e == error.NotVendored) {
            try err.print("{s} has SHA-256 {s}, not the vendored {s}\nthe vendored file must not be modified (tests/vendor/README.md)\n", .{ path, &conformance.hexDigest(text), conformance.suite_sha256 });
            try err.flush();
            std.process.exit(1);
        }
        try err.print("the conformance runner cannot trust this run: {t}\nrun `zig build test-conformance` to see where\n", .{e});
        try err.flush();
        std.process.exit(1);
    };
}

/// Writes the table of the conformance suite: one row a section, then the total and the
/// libraries the suite imports that cannot be resolved.
fn renderSuite(w: *std.Io.Writer, r: conformance.SuiteResult) !void {
    try w.writeAll(suite_preamble);
    var total: conformance.Counts = .{};
    for (r.sections) |s| {
        const c = s.counts;
        try w.print("| {s} | {d} | {d} | {d} | {d} | {d} | {d} |\n", .{ s.name, c.passed, c.failed, c.errored, c.unreadable, c.unimplemented, c.cascaded });
        total.passed += c.passed;
        total.failed += c.failed;
        total.errored += c.errored;
        total.unreadable += c.unreadable;
        total.unimplemented += c.unimplemented;
        total.cascaded += c.cascaded;
    }
    try w.print("| 合計 | {d} | {d} | {d} | {d} | {d} | {d} |\n", .{ total.passed, total.failed, total.errored, total.unreadable, total.unimplemented, total.cascaded });
    if (r.missing_libraries.len > 0) {
        try w.writeAll("\nスイートが `import` するライブラリのうち、解決できなかったもの:");
        for (r.missing_libraries) |l| try w.print(" `{s}`", .{l});
        try w.writeAll("\n");
    }
}

const suite_preamble =
    \\
    \\## 準拠スイートの結果
    \\
    \\取り込んだ準拠スイート `tests/vendor/r7rs-tests.scm` を、節ごとに走らせた結果である。取り込んだ版は [tests/vendor/README.md](../../tests/vendor/README.md) にある。分類の定義は [docs/plans/0020-conformance-harness-early.md](../plans/0020-conformance-harness-early.md) の「分類」にあり、落ちたものと走らせなかったものの一覧は `zig build test-conformance` が出す。
    \\
    \\- 「通った」と「落ちた」はテストの数である。ほかの列は、走らせなかったか、それ自体が誤りを上げた最上位の形式の数である。ただし「連鎖」は、同じ外側の節(入れ子の節を含む)に評価しなかったか誤りで終わった形式があるときにテストの中で上がった未束縛の誤りを、テストの数で含む。単位が違うので足さない。
    \\- 入れ子の節(「Read syntax」と「Numeric syntax」)は、親の節(6.13)と別の行に数える。
    \\
    \\| 節 | 通った | 落ちた | 誤り | 読めない | 未実装 | 連鎖 |
    \\| --- | ---: | ---: | ---: | ---: | ---: | ---: |
    \\
;

fn libraryLessThan(_: void, a: Library, b: Library) bool {
    return std.mem.lessThan(u8, a.name, b.name);
}

/// Reads the identifiers of one `tests/r7rs-required` file.
///
/// 1行1識別子で、`;` で始まる行はコメントである。空行は読み飛ばす。改行が CRLF の
/// チェックアウトでも同じに読めるよう、行末の空白を取り除く。結果は `text` の中を指す。
fn parseIdentifiers(gpa: std.mem.Allocator, text: []const u8) error{OutOfMemory}![]const []const u8 {
    var ids: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, &std.ascii.whitespace);
        if (line.len == 0 or line[0] == ';') continue;
        try ids.append(gpa, line);
    }
    return ids.toOwnedSlice(gpa);
}

/// Whether `(scheme <name>)` exports `identifier`, in an interpreter that has imported that
/// library and nothing else.
fn exportsFrom(gpa: std.mem.Allocator, name: []const u8, identifiers: []const []const u8, bound: []bool) !void {
    var interp: sucheme.Interpreter = undefined;
    try interp.initBare(gpa, .{});
    defer interp.deinit();
    const request = try std.fmt.allocPrint(gpa, "(import (scheme {s}))", .{name});
    defer gpa.free(request);
    var discard: std.Io.Writer.Discarding = .init(&.{});
    // 埋め込みのライブラリが無いか、読み込めないなら、1つも輸出していない。
    interp.evalPrint(gpa, request, &discard.writer) catch {
        @memset(bound, false);
        return;
    };
    for (identifiers, bound) |id, *b| b.* = interp.isBound(id);
}

/// The text of docs/status/conformance.md.
///
/// 識別子の総数は一意に数える。`(scheme r5rs)` は他のライブラリの識別子を再エクスポート
/// するので、ライブラリごとの数を足すと同じ識別子を重複して数える。一意の識別子は、どれか
/// のライブラリが輸出していれば束縛済みと数える。
fn render(
    gpa: std.mem.Allocator,
    w: *std.Io.Writer,
    libs: []const Library,
) !void {
    try w.writeAll(preamble);

    // 一意の識別子の集合。値は、どれかのライブラリが輸出しているかどうか。
    var unique: std.StringHashMapUnmanaged(bool) = .empty;
    for (libs) |lib| {
        const flags = try gpa.alloc(bool, lib.ids.len);
        defer gpa.free(flags);
        try exportsFrom(gpa, lib.name, lib.ids, flags);
        var bound: usize = 0;
        for (lib.ids, flags) |id, is_bound| {
            if (is_bound) bound += 1;
            const entry = try unique.getOrPut(gpa, id);
            entry.value_ptr.* = is_bound or (entry.found_existing and entry.value_ptr.*);
        }
        try w.print("| `(scheme {s})` | {d} | {d} |\n", .{ lib.name, bound, lib.ids.len });
    }

    var unique_bound: usize = 0;
    var values = unique.valueIterator();
    while (values.next()) |is_bound| {
        if (is_bound.*) unique_bound += 1;
    }
    try w.print("| 一意の識別子の合計 | {d} | {d} |\n", .{ unique_bound, unique.count() });
}

const preamble =
    \\# R7RS 準拠マトリクス
    \\
    \\このファイルは生成物である。手で編集しない。`zig build report` で生成し、`zig build check-report` が生成し直した結果との一致を検査する。生成元は [tools/coverage-report/main.zig](../../tools/coverage-report/main.zig) である。
    \\
    \\- 「束縛済み」は、その標準ライブラリを `import` したとき、その識別子が束縛される(手続き、または特殊形式)ことを指す。標準ライブラリは、実行ファイルに埋め込んだ `lib/` の `.sld` である。埋め込みに無いライブラリは、0 と数える。準拠を意味しない。たとえば算術は固定長整数だけで、仕様が求める数値塔はない。
    \\- ここでいう「ライブラリ」は、`tests/r7rs-required/` の分け方、つまり R7RS 付録Aが定める標準ライブラリである。ライブラリごとに、何も束縛していない最上位でそのライブラリだけを `import` して数える。ほかのライブラリが束縛している名前は数えない。
    \\- `(scheme r5rs)` は他のライブラリの識別子を再エクスポートする。このため、ライブラリごとの数は同じ識別子を重複して含み、その和は一意の識別子の合計と一致しない。
    \\
    \\| ライブラリ | 束縛済み | 全体 |
    \\| --- | ---: | ---: |
    \\
;

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "parseIdentifiers skips comments and blank lines and trims line ends" {
    const gpa = std.testing.allocator;
    const ids = try parseIdentifiers(gpa, "; comment\r\n+\r\n\n  call/cc \n;; another\n=>\n");
    defer gpa.free(ids);
    try std.testing.expectEqual(3, ids.len);
    try std.testing.expectEqualStrings("+", ids[0]);
    try std.testing.expectEqualStrings("call/cc", ids[1]);
    try std.testing.expectEqualStrings("=>", ids[2]);
}

test "parseIdentifiers keeps an identifier that merely contains a semicolon" {
    const gpa = std.testing.allocator;
    const ids = try parseIdentifiers(gpa, "a;b\n");
    defer gpa.free(ids);
    try std.testing.expectEqual(1, ids.len);
    try std.testing.expectEqualStrings("a;b", ids[0]);
}

test "render counts what each library exports, and counts the shared ones once in the total" {
    // `+` と `define` は `(scheme base)` が輸出し、`no-such-procedure` は輸出しない。
    // `(scheme no-such-library)` は埋め込みに無いので、何も輸出していない。`+` は両方の
    // ライブラリにあり、合計では1回だけ数える。
    // Why: 未束縛の例は、どの段階でも束縛されない名前でなければならない。R7RS の名前は
    // いつか束縛される(`car` はスライス 1k で、`call/cc` は段階2で束縛される)ので、
    // 例に使うとそのたびにテストが落ちる。
    const libs = [_]Library{
        .{ .name = "base", .ids = &.{ "+", "define", "no-such-procedure" } },
        .{ .name = "no-such-library", .ids = &.{ "+", "no-such-procedure", "no-such-syntax" } },
    };
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    try render(arena.allocator(), &out.writer, &libs);

    const got = out.written();
    try std.testing.expect(std.mem.indexOf(u8, got, "| `(scheme base)` | 2 | 3 |\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "| `(scheme no-such-library)` | 0 | 3 |\n") != null);
    // 一意の識別子は {+, define, no-such-procedure, no-such-syntax} の4個で、輸出されているのは {+, define} の2個。
    try std.testing.expect(std.mem.endsWith(u8, got, "| 一意の識別子の合計 | 2 | 4 |\n"));
}

test "a library counts only what it exports, not what another library binds" {
    // `(scheme lazy)` は `+` を輸出しない。`(scheme base)` が別に輸出していても、数えない。
    const libs = [_]Library{
        .{ .name = "lazy", .ids = &.{ "+", "force" } },
    };
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    try render(arena.allocator(), &out.writer, &libs);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "| `(scheme lazy)` | 1 | 2 |\n") != null);
}

test "render starts with the generated-file notice and ends every line with LF" {
    const libs = [_]Library{.{ .name = "base", .ids = &.{"+"} }};
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    try render(arena.allocator(), &out.writer, &libs);

    const got = out.written();
    try std.testing.expect(std.mem.startsWith(u8, got, "# R7RS 準拠マトリクス"));
    try std.testing.expect(std.mem.indexOfScalar(u8, got, '\r') == null);
    try std.testing.expect(std.mem.endsWith(u8, got, "\n"));
}

test "libraries are ordered by name" {
    var libs = [_]Library{
        .{ .name = "write", .ids = &.{} },
        .{ .name = "base", .ids = &.{} },
        .{ .name = "r5rs", .ids = &.{} },
    };
    std.mem.sort(Library, &libs, {}, libraryLessThan);
    try std.testing.expectEqualStrings("base", libs[0].name);
    try std.testing.expectEqualStrings("r5rs", libs[1].name);
    try std.testing.expectEqualStrings("write", libs[2].name);
}

test "parseArgs defaults to the comparison, and only --write writes" {
    const none = parseArgs(&.{});
    try std.testing.expectEqual(Mode.check, none.mode);
    const check = parseArgs(&.{"--check"});
    try std.testing.expectEqual(Mode.check, check.mode);
    const write = parseArgs(&.{"--write"});
    try std.testing.expectEqual(Mode.write, write.mode);
    // 順序によらず、`--write` があれば書き込みである。
    const both = parseArgs(&.{ "--write", "--check" });
    try std.testing.expectEqual(Mode.write, both.mode);
}

test "parseArgs names the first argument it does not know" {
    const bogus = parseArgs(&.{"--bogus"});
    try std.testing.expectEqualStrings("--bogus", bogus.unknown);
    // 綴りを間違えた `--write` を、既定の比較として黙って受け付けない。
    const typo = parseArgs(&.{ "--check", "--wirte", "--write" });
    try std.testing.expectEqualStrings("--wirte", typo.unknown);
}

test "the suite table has one row a section in order, the column sums, and the missing libraries" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    // 列の取り違えが表に出るよう、行の中でも合計でも、6つの数をすべて違う値にする。
    const sections = [_]conformance.SectionResult{
        .{ .name = "4.1 a", .counts = .{ .passed = 2, .failed = 6, .errored = 7, .unreadable = 3, .unimplemented = 4, .cascaded = 5 } },
        .{ .name = "6.2 b", .counts = .{ .passed = 10, .failed = 20, .errored = 30, .unreadable = 40, .unimplemented = 1, .cascaded = 50 } },
    };
    try renderSuite(&out.writer, .{
        .sections = &sections,
        .failures = &.{},
        .missing_libraries = &.{ "(scheme char)", "(scheme r5rs)" },
    });
    const text = out.written();
    try std.testing.expect(std.mem.startsWith(u8, text, suite_preamble));
    const rows = text[suite_preamble.len..];
    try std.testing.expectEqualStrings(
        \\| 4.1 a | 2 | 6 | 7 | 3 | 4 | 5 |
        \\| 6.2 b | 10 | 20 | 30 | 40 | 1 | 50 |
        \\| 合計 | 12 | 26 | 37 | 43 | 5 | 55 |
        \\
        \\スイートが `import` するライブラリのうち、解決できなかったもの: `(scheme char)` `(scheme r5rs)`
        \\
    , rows);
}

test "the suite table has no missing-library line when every library resolves" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try renderSuite(&out.writer, .{ .sections = &.{}, .failures = &.{}, .missing_libraries = &.{} });
    try std.testing.expectEqualStrings(suite_preamble ++ "| 合計 | 0 | 0 | 0 | 0 | 0 | 0 |\n", out.written());
}

test "the suite table has the missing-library line for a single library" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try renderSuite(&out.writer, .{ .sections = &.{}, .failures = &.{}, .missing_libraries = &.{"(scheme time)"} });
    try std.testing.expectEqualStrings(suite_preamble ++ "| 合計 | 0 | 0 | 0 | 0 | 0 | 0 |\n" ++
        "\nスイートが `import` するライブラリのうち、解決できなかったもの: `(scheme time)`\n", out.written());
}
