//! Generates docs/status/conformance.md: for each R7RS standard library, how
//! many of its required identifiers the interpreter binds.
//!
//! 入力は `tests/r7rs-required/*.txt` で、各識別子が束縛済みかは
//! `sucheme.Interpreter.isBound` に尋ねる。エラー文言の分類では答えない。
//!
//! 既定の動作は比較である。生成し直した結果を現在のファイルと照らし合わせ、
//! 差があれば非ゼロで終了して直し方を標準エラーに出す。`zig build
//! check-report` がこれを走らせる。書き込みは `--write` で行う(`zig build
//! report` がそうする)。
//!
//! 比較を既定にしたのは tools/extract-r7rs-required と同じ理由である。逆にすると、
//! build.zig から引数を1つ消すだけで、検査が書き換えに変わり、失敗しえなくなる。
//!
//! 段階1の最小版である。列は「束縛済み」と「全体」だけで、`lib/` のエクスポートも、
//! 意味論テストや準拠スイートの結果も読まない。これらが入る段階は
//! docs/design/r7rs-coverage.md にある。

const std = @import("std");
const sucheme = @import("sucheme");

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

    var interp: sucheme.Interpreter = undefined;
    try interp.init(gpa);
    defer interp.deinit();

    var report: std.Io.Writer.Allocating = .init(gpa);
    try render(gpa, &report.writer, &interp, libs.items);
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

/// The text of docs/status/conformance.md.
///
/// 識別子の総数は一意に数える。`(scheme r5rs)` は他のライブラリの識別子を再エクスポート
/// するので、ライブラリごとの数を足すと同じ識別子を重複して数える。
fn render(
    gpa: std.mem.Allocator,
    w: *std.Io.Writer,
    interp: *const sucheme.Interpreter,
    libs: []const Library,
) !void {
    try w.writeAll(preamble);

    // 一意の識別子の集合。値は束縛済みかどうか。
    var unique: std.StringHashMapUnmanaged(bool) = .empty;
    for (libs) |lib| {
        var bound: usize = 0;
        for (lib.ids) |id| {
            const is_bound = interp.isBound(id);
            if (is_bound) bound += 1;
            try unique.put(gpa, id, is_bound);
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
    \\# R7RS 準拠マトリクス(段階1の最小版)
    \\
    \\このファイルは生成物である。手で編集しない。`zig build report` で生成し、`zig build check-report` が生成し直した結果との一致を検査する。生成元は [tools/coverage-report/main.zig](../../tools/coverage-report/main.zig) である。
    \\
    \\- 「束縛済み」は、その識別子がインタプリタの大域環境に束縛されている、または特殊形式であることを指す。準拠を意味しない。たとえば算術は固定長整数だけで、仕様が求める数値塔はない。
    \\- ここでいう「ライブラリ」は、`tests/r7rs-required/` の分け方、つまり R7RS 付録Aが定める標準ライブラリである。インタプリタの `define-library` が作るライブラリとは別のもので、「束縛済み」は、REPL の最上位から見える束縛を数える。
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

test "render counts bound identifiers per library and counts the shared ones once in the total" {
    var interp: sucheme.Interpreter = undefined;
    try interp.init(std.testing.allocator);
    defer interp.deinit();

    // `+` と `define` は束縛済み、`no-such-procedure` と `no-such-syntax` は未束縛である。
    // `+` は両方のライブラリにあり、合計では1回だけ数える。
    // Why: 未束縛の例は、どの段階でも束縛されない名前でなければならない。R7RS の名前は
    // いつか束縛される(`car` はスライス 1k で、`call/cc` は段階2で束縛される)ので、
    // 例に使うとそのたびにテストが落ちる。
    const libs = [_]Library{
        .{ .name = "base", .ids = &.{ "+", "define", "no-such-procedure" } },
        .{ .name = "r5rs", .ids = &.{ "+", "no-such-procedure", "no-such-syntax" } },
    };
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    try render(arena.allocator(), &out.writer, &interp, &libs);

    const got = out.written();
    try std.testing.expect(std.mem.indexOf(u8, got, "| `(scheme base)` | 2 | 3 |\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "| `(scheme r5rs)` | 1 | 3 |\n") != null);
    // 一意の識別子は {+, define, no-such-procedure, no-such-syntax} の4個で、束縛済みは {+, define} の2個。
    try std.testing.expect(std.mem.endsWith(u8, got, "| 一意の識別子の合計 | 2 | 4 |\n"));
}

test "render starts with the generated-file notice and ends every line with LF" {
    var interp: sucheme.Interpreter = undefined;
    try interp.init(std.testing.allocator);
    defer interp.deinit();
    const libs = [_]Library{.{ .name = "base", .ids = &.{"+"} }};
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    try render(arena.allocator(), &out.writer, &interp, &libs);

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
