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
//! - `console`: コマンドの例。`$ ` で始まる行は、`sucheme` の実行ファイルの呼び出しに限り、
//!   シェルを通さず、空白で区切った引数で直接起動する。任意のシェルのコマンドは走らせない。
//!   続く行(次の `$ ` の行か、ブロックの終わりまで)が、標準出力のあとに標準エラーを続けた
//!   期待する出力である。終了コードが 0 でないときは、出力の最後に `[exit N]` の行を書く
//!   (無ければ 0 を求める)。作業ディレクトリは、文書と同じ場所の `examples/` で、入力の
//!   ファイルはそこに置く。
//!
//! 検査の外に黙って出るブロックを残さないため、次を誤りとして報告する。情報文字列の
//! 無いフェンス、知らない種類と語、行頭から書かれていないフェンス、閉じていない
//! フェンス、`scheme` の後ろでない `output`、`sucheme` でない `$ ` の行、シェルの記号を含む
//! 引数、フェンスの外の、空白4つかタブで始まる行
//! (インデントされたコードブロックになりうる)、引用(`>` で始まる行)の中のフェンス、
//! `<pre>` と `<code>` で始まる HTML のブロック。この道具は CommonMark のリストと引用の
//! 中のフェンスを読まないので、それらを断ることで、読み違えを防ぐ。
//!
//! プログラム集(docs/manual/programs/)は、`名前.scm` と期待する標準出力 `名前.out` の組で
//! 置く。`.scm` を、引数で渡された実行ファイルに、ファイルの実行として渡し、標準出力と
//! 終了コード 0 を `.out` と比べる(利用者が実際に打つ経路を通すため、プロセスの中では
//! 評価しない)。組になっていないファイル、プログラムが1つも無いことは、失敗とする。
//! 入力を渡す `.in` と一時ディレクトリは、前提のスライスが無いので、まだ足していない。
//!
//! docs/manual/ の下の、上のどれでもないファイル、`.md` が無いこと、`scheme` のブロックが
//! 1つも無いことも、失敗とする。引数は、実行ファイルのパスの1つだけである。範囲を狭める
//! 引数は、検査を減らしたまま緑にする手段になるからである(tools/test-scheme と同じ理由)。

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
    if (argv.len != 2) {
        try err.print("check-examples: takes exactly one argument, the path of the sucheme executable\n", .{});
        try err.flush();
        return 2;
    }
    // コマンドの例は作業ディレクトリを変えて起動するので、相対のパスのままだと見つからない。
    const exe_path = std.Io.Dir.cwd().realPathFileAlloc(io, argv[1], gpa) catch |e| {
        try err.print("check-examples: cannot find the executable {s} ({t})\n", .{ argv[1], e });
        try err.flush();
        return 2;
    };
    const exec: Exec = .{ .exe = exe_path, .runFn = runExecutable, .commandFn = runCommand };

    var dir = std.Io.Dir.cwd().openDir(io, manual_dir, .{ .iterate = true }) catch |e| {
        try err.print("check-examples: cannot open {s} ({t})\n", .{ manual_dir, e });
        try err.flush();
        return 1;
    };
    defer dir.close(io);
    const counts = try run(gpa, io, dir, manual_dir, exec, err);
    try err.print("check-examples: {d} checks passed, {d} failed ({d} blocks, {d} commands, {d} programs)\n", .{ counts.passed, counts.failed, counts.blocks, counts.commands, counts.programs });
    try err.flush();
    // Why: 終了コードは `main` の戻り値で返す。`exit` の呼び出しを条件に置くと、その1行を
    // 消すだけで、失敗を報告しながら 0 で終わる形になった(D1 のミューテーションの査読)。
    return exitStatus(counts);
}

/// The exit status for a run with `counts`.
fn exitStatus(counts: Counts) u8 {
    return if (counts.failed != 0) 1 else 0;
}

/// The directory of the programs, under the documents.
const programs_dir = "programs/";

/// What running one program gave.
const Outcome = struct {
    /// The exit code, or null when the process did not exit by itself (a signal, a timeout).
    code: ?u8,
    stdout: []const u8,
    /// What the process wrote to standard error. Programs are compared by standard output only.
    stderr: []const u8 = "",
};

/// How a program is run. The tests put a stand-in for the executable here.
const Exec = struct {
    /// The path of the executable.
    exe: []const u8,
    /// Runs the program at `path`, relative to the working directory, and returns what it gave.
    runFn: *const fn (gpa: std.mem.Allocator, io: std.Io, exec: Exec, dir: std.Io.Dir, path: []const u8, shown: []const u8) anyerror!Outcome,
    /// Runs the executable with `args` (without the program name), with `dir` as the working directory.
    commandFn: *const fn (gpa: std.mem.Allocator, io: std.Io, exec: Exec, dir: std.Io.Dir, args: []const []const u8) anyerror!Outcome,
};

/// Runs `shown` (the program's path from the working directory) with the real executable.
fn runExecutable(gpa: std.mem.Allocator, io: std.Io, exec: Exec, dir: std.Io.Dir, path: []const u8, shown: []const u8) anyerror!Outcome {
    _ = dir;
    _ = path;
    // 暴走するプログラムが検査を止めたままにしないよう、時間に上限を置く。
    const result = try std.process.run(gpa, io, .{
        .argv = &.{ exec.exe, shown },
        .timeout = .{ .duration = .{ .raw = .fromSeconds(120), .clock = .awake } },
    });
    return .{
        .code = switch (result.term) {
            .exited => |c| c,
            else => null,
        },
        .stdout = result.stdout,
    };
}

/// Runs the executable with `args` in `dir`, without a shell.
fn runCommand(gpa: std.mem.Allocator, io: std.Io, exec: Exec, dir: std.Io.Dir, args: []const []const u8) anyerror!Outcome {
    const argv = try gpa.alloc([]const u8, args.len + 1);
    argv[0] = exec.exe;
    @memcpy(argv[1..], args);
    const result = try std.process.run(gpa, io, .{
        .argv = argv,
        .cwd = .{ .dir = dir },
        .timeout = .{ .duration = .{ .raw = .fromSeconds(120), .clock = .awake } },
    });
    return .{
        .code = switch (result.term) {
            .exited => |c| c,
            else => null,
        },
        .stdout = result.stdout,
        .stderr = result.stderr,
    };
}

/// A program of `programs/`: the files of one name that were found.
const Program = struct {
    name: []const u8,
    has_scm: bool = false,
    has_out: bool = false,
};

/// Whether `path` is a `.scm` or `.out` file directly under `programs/`.
fn isProgramFile(path: []const u8) bool {
    // Windows の歩き方は `\\` で区切る(path.sep)ので、区切りは両方を受け付ける。
    const dir_name = programs_dir[0 .. programs_dir.len - 1];
    if (!std.mem.startsWith(u8, path, dir_name)) return false;
    if (path.len == dir_name.len or (path[dir_name.len] != '/' and path[dir_name.len] != '\\')) return false;
    const rest = path[dir_name.len + 1 ..];
    // サブディレクトリの中は、プログラムとして読まない。
    if (std.mem.indexOfAny(u8, rest, "/\\") != null) return false;
    return std.mem.endsWith(u8, rest, ".scm") or std.mem.endsWith(u8, rest, ".out");
}

/// Whether `path` is a file other than a `.md` under a directory named `examples`.
///
/// `console` のブロックの作業ディレクトリである。入力のファイル(`.scm` と、`-I` で読む
/// `.sld` など)をここに置く。`.md` は、ここにあっても文書として検査する。
fn isExampleInput(path: []const u8) bool {
    if (std.mem.endsWith(u8, path, ".md")) return false;
    var parts = std.mem.tokenizeAny(u8, path, "/\\");
    // 最後の要素はファイルの名前なので、ディレクトリの名前としては見ない。
    var prev: ?[]const u8 = null;
    while (parts.next()) |part| {
        if (prev) |d| {
            if (std.mem.eql(u8, d, examples_dir)) return true;
        }
        prev = part;
    }
    return false;
}

/// The directory of the input files of the commands, next to a document.
const examples_dir = "examples";

/// Checks every document and program under `dir`, named `name` in the report, and writes what failed to `w`.
///
/// 上のどれでもないファイル、`.md` が無いこと、`scheme` のブロックが1つも走らないこと、
/// プログラムが1つも無いことも、失敗として数える。
fn run(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, name: []const u8, exec: Exec, w: *std.Io.Writer) !Counts {
    var counts: Counts = .{};
    var paths: std.ArrayList([]const u8) = .empty;
    var programs: std.ArrayList(Program) = .empty;
    var walker = try dir.walk(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind == .directory) continue;
        if (entry.kind == .file and isProgramFile(entry.path)) {
            const stem = entry.basename[0 .. entry.basename.len - 4];
            const is_scm = std.mem.endsWith(u8, entry.basename, ".scm");
            var found = false;
            for (programs.items) |*pr| {
                if (std.mem.eql(u8, pr.name, stem)) {
                    if (is_scm) pr.has_scm = true else pr.has_out = true;
                    found = true;
                }
            }
            if (!found) try programs.append(gpa, .{
                .name = try gpa.dupe(u8, stem),
                .has_scm = is_scm,
                .has_out = !is_scm,
            });
            continue;
        }
        if (entry.kind == .file and isExampleInput(entry.path)) continue;
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

    std.mem.sort(Program, programs.items, {}, programLessThan);
    if (programs.items.len == 0) {
        try w.print("check-examples: no program (`.scm` and `.out` pair) under {s}/{s}\n", .{ name, programs_dir });
        counts.failed += 1;
    }
    for (programs.items) |pr| try checkProgram(gpa, io, dir, name, pr, exec, w, &counts);

    for (paths.items) |path| {
        const shown = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ name, path });
        const body = dir.readFileAlloc(io, path, gpa, .unlimited) catch |e| {
            try w.print("{s}: cannot be read ({t})\n", .{ shown, e });
            counts.failed += 1;
            continue;
        };
        try checkFile(gpa, io, dir, path, shown, body, exec, w, &counts);
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

fn programLessThan(_: void, a: Program, b: Program) bool {
    return std.mem.lessThan(u8, a.name, b.name);
}

/// Runs one program and compares its standard output with the `.out` file and its exit code with 0.
fn checkProgram(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, name: []const u8, pr: Program, exec: Exec, w: *std.Io.Writer, counts: *Counts) !void {
    counts.programs += 1;
    if (!pr.has_scm or !pr.has_out) {
        try w.print("{s}/{s}{s}: the {s} file of the pair is missing\n", .{
            name, programs_dir, pr.name, if (pr.has_scm) "`.out`" else "`.scm`",
        });
        counts.failed += 1;
        return;
    }
    const rel_scm = try std.fmt.allocPrint(gpa, "{s}{s}.scm", .{ programs_dir, pr.name });
    const rel_out = try std.fmt.allocPrint(gpa, "{s}{s}.out", .{ programs_dir, pr.name });
    const shown = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ name, rel_scm });
    const expected_raw = dir.readFileAlloc(io, rel_out, gpa, .unlimited) catch |e| {
        try w.print("{s}/{s}: cannot be read ({t})\n", .{ name, rel_out, e });
        counts.failed += 1;
        return;
    };
    // Git の改行の変換でチェックアウトした `.out` も、LF のものと同じに読む。
    const expected = try std.mem.replaceOwned(u8, gpa, expected_raw, "\r\n", "\n");
    const outcome = exec.runFn(gpa, io, exec, dir, rel_scm, shown) catch |e| {
        try w.print("{s}: cannot be run ({t})\n", .{ shown, e });
        counts.failed += 1;
        return;
    };
    if (outcome.code != 0) {
        if (outcome.code) |c| {
            try w.print("{s}: exit code {d}, expected 0\n", .{ shown, c });
        } else {
            try w.print("{s}: the process did not exit by itself\n", .{shown});
        }
        counts.failed += 1;
        return;
    }
    if (!std.mem.eql(u8, outcome.stdout, expected)) {
        try w.print("{s}: the output differs\n  expected: {s}\n  got:      {s}\n", .{ shown, expected, outcome.stdout });
        counts.failed += 1;
        return;
    }
    counts.passed += 1;
}

/// The counts of a run.
const Counts = struct {
    /// The `scheme` blocks run, passed or not.
    blocks: usize = 0,
    /// The commands of `console` blocks run, passed or not.
    commands: usize = 0,
    /// The programs of `programs/` run (or found incomplete), passed or not.
    programs: usize = 0,
    passed: usize = 0,
    failed: usize = 0,
};

/// Reads one document, runs its blocks and writes what failed to `w`.
///
/// `rel` は、`dir` から見た文書のパスで、`console` のブロックの作業ディレクトリ(同じ場所の
/// `examples/`)を決める。`shown` は報告に出す名前である。
fn checkFile(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, rel: []const u8, shown: []const u8, body: []const u8, exec: Exec, w: *std.Io.Writer, counts: *Counts) !void {
    const path = shown;
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
    // `console` のブロックが初めて要るときに開く。
    var examples: ?std.Io.Dir = null;
    defer if (examples) |*d| d.close(io);
    for (blocks) |block| {
        if (block.commands.len != 0) {
            if (examples == null) {
                const sub = if (std.fs.path.dirname(rel)) |d|
                    try std.fmt.allocPrint(gpa, "{s}/{s}", .{ d, examples_dir })
                else
                    examples_dir;
                examples = dir.openDir(io, sub, .{}) catch |e| {
                    try w.print("{s}:{d}: cannot open the examples directory {s}/{s} ({t})\n", .{ path, block.line, "docs/manual", sub, e });
                    counts.failed += 1;
                    continue;
                };
            }
            for (block.commands) |c| try checkCommand(gpa, io, examples.?, path, c, exec, w, counts);
            continue;
        }
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

/// Runs one command of a `console` block and compares what it wrote and its exit code.
fn checkCommand(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, path: []const u8, c: Command, exec: Exec, w: *std.Io.Writer, counts: *Counts) !void {
    counts.commands += 1;
    const outcome = exec.commandFn(gpa, io, exec, dir, c.args[1..]) catch |e| {
        try w.print("{s}:{d}: cannot be run ({t})\n", .{ path, c.line, e });
        counts.failed += 1;
        return;
    };
    const got_code = outcome.code orelse {
        try w.print("{s}:{d}: the process did not exit by itself\n", .{ path, c.line });
        counts.failed += 1;
        return;
    };
    if (got_code != c.code) {
        try w.print("{s}:{d}: exit code {d}, expected {d}\n", .{ path, c.line, got_code, c.code });
        counts.failed += 1;
        return;
    }
    // 標準出力のあとに標準エラーを続ける。Git の改行の変換でも、LF のものと同じに読む。
    const both = try std.mem.concat(gpa, u8, &.{ outcome.stdout, outcome.stderr });
    const got = std.mem.trimEnd(u8, try std.mem.replaceOwned(u8, gpa, both, "\r\n", "\n"), "\n");
    if (std.mem.eql(u8, got, c.expected)) {
        counts.passed += 1;
    } else {
        try w.print("{s}:{d}: the output differs\n  expected: {s}\n  got:      {s}\n", .{ path, c.line, c.expected, got });
        counts.failed += 1;
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
    /// The commands of a `console` block. A block with commands is not a `scheme` block.
    commands: []const Command = &.{},
};

/// A command of a `console` block, with what it should write.
const Command = struct {
    /// The 1-based line of the `$ ` line, for the report.
    line: usize,
    /// The program name `sucheme`, then its arguments.
    args: []const []const u8,
    /// The lines after the command joined with `\n`, without the `[exit N]` line.
    expected: []const u8,
    /// The expected exit code.
    code: u8,
};

/// Something in a document that stops it from being checked.
const Problem = struct {
    line: usize,
    message: []const u8,
};

/// The kind of a fenced block, from the first word of its info string.
const Kind = enum { scheme, output, text, console };

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
                        .console => try blocks.append(gpa, .{
                            .line = o.line,
                            .source = "",
                            .expected = "",
                            .fresh = false,
                            .commands = try parseConsole(gpa, text, o.line, problems),
                        }),
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
                    error.NoInfo => "this fence names no kind; use `scheme`, `output`, `text` or `console`",
                    error.UnknownKind => "this fence names a kind other than `scheme`, `output`, `text` or `console`",
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

/// Whether `arg` may be an argument of a command: letters, digits and `._/-=+,:@%`.
///
/// 引数はシェルを通さずに渡すので、引用符、空白、リダイレクト、`$`、`*` などは、書いたとおりの
/// 意味にならない。書けないようにして、読者がシェルの意味で読む例を断る。
fn isPlainArgument(arg: []const u8) bool {
    if (arg.len == 0) return false;
    for (arg) |ch| {
        if (!std.ascii.isAlphanumeric(ch) and std.mem.indexOfScalar(u8, "._/-=+,:@%", ch) == null) return false;
    }
    return true;
}

/// Reads the body of a `console` block that opened at line `open_line`.
fn parseConsole(gpa: std.mem.Allocator, text: []const u8, open_line: usize, problems: *std.ArrayList(Problem)) error{OutOfMemory}![]const Command {
    var commands: std.ArrayList(Command) = .empty;
    // 読んでいるコマンドの出力の行と、`[exit N]` を読んだかどうか。
    var lines: std.ArrayList([]const u8) = .empty;
    var exited = false;
    var current: ?Command = null;
    // 読めなかったコマンドも数える。その出力を、コマンドの前の出力として重ねて報告しない。
    var seen_command = false;
    const problems_before = problems.items.len;
    var lineno = open_line;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        lineno += 1;
        if (std.mem.startsWith(u8, line, "$ ") or std.mem.eql(u8, line, "$")) {
            if (current) |*c| {
                c.expected = std.mem.trimEnd(u8, try std.mem.join(gpa, "\n", lines.items), "\n");
                try commands.append(gpa, c.*);
            }
            lines.clearRetainingCapacity();
            exited = false;
            current = null;
            seen_command = true;
            var words = std.mem.tokenizeScalar(u8, line[1..], ' ');
            var args: std.ArrayList([]const u8) = .empty;
            while (words.next()) |word| try args.append(gpa, word);
            if (args.items.len == 0 or !std.mem.eql(u8, args.items[0], "sucheme")) {
                try problems.append(gpa, .{ .line = lineno, .message = "this tool runs only `sucheme` commands; start the line with `$ sucheme`" });
                continue;
            }
            var plain = true;
            for (args.items) |arg| plain = plain and isPlainArgument(arg);
            if (!plain) {
                try problems.append(gpa, .{ .line = lineno, .message = "this command has an argument with a character a shell would read (quotes, `|`, `>`, `$`, `*`, a tab and so on); this tool runs the arguments as written, split at spaces, without a shell" });
                continue;
            }
            current = .{ .line = lineno, .args = try args.toOwnedSlice(gpa), .expected = "", .code = 0 };
            continue;
        }
        const body = std.mem.trimEnd(u8, line, " \t");
        if (current == null) {
            // コマンドの前の空行は許す。出力は、コマンドの無いところに書けない。
            if (body.len != 0 and !seen_command) {
                try problems.append(gpa, .{ .line = lineno, .message = "this line comes before any `$ sucheme` command in the console block" });
            }
            continue;
        }
        if (std.mem.startsWith(u8, body, "[exit")) {
            if (exited) {
                try problems.append(gpa, .{ .line = lineno, .message = "this command already has an `[exit N]` line" });
                continue;
            }
            const code = parseExit(body) orelse {
                try problems.append(gpa, .{ .line = lineno, .message = "this `[exit` line is not `[exit N]` with N from 0 to 255" });
                continue;
            };
            current.?.code = code;
            exited = true;
            continue;
        }
        if (exited) {
            if (body.len != 0) try problems.append(gpa, .{ .line = lineno, .message = "the `[exit N]` line must be the last line of a command's output" });
            continue;
        }
        try lines.append(gpa, line);
    }
    if (current) |*c| {
        c.expected = std.mem.trimEnd(u8, try std.mem.join(gpa, "\n", lines.items), "\n");
        try commands.append(gpa, c.*);
    }
    if (commands.items.len == 0 and problems.items.len == problems_before) {
        try problems.append(gpa, .{ .line = open_line, .message = "this `console` block has no `$ sucheme` command" });
    }
    return try commands.toOwnedSlice(gpa);
}

/// The N of an `[exit N]` line, or null when the line has another form.
fn parseExit(line: []const u8) ?u8 {
    if (!std.mem.startsWith(u8, line, "[exit ") or !std.mem.endsWith(u8, line, "]")) return null;
    const digits = line["[exit ".len .. line.len - 1];
    if (digits.len == 0) return null;
    for (digits) |ch| if (!std.ascii.isDigit(ch)) return null;
    return std.fmt.parseInt(u8, digits, 10) catch null;
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

/// The counts and the report of a run in a test.
const TestRun = struct { counts: Counts, report: []const u8 };

/// Runs `body` as the document `doc.md`, next to an `examples/` directory holding `files`
/// (each path is relative to `examples/`), and returns its counts and report.
fn checkForTestIn(arena: std.mem.Allocator, body: []const u8, files: []const TestFile) !TestRun {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "examples");
    for (files) |f| {
        const rel = try std.fmt.allocPrint(arena, "examples/{s}", .{f.path});
        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = rel, .data = f.data });
    }
    var report: std.Io.Writer.Allocating = .init(arena);
    var counts: Counts = .{};
    try checkFile(arena, std.testing.io, tmp.dir, "doc.md", "doc.md", body, stand_in, &report.writer, &counts);
    return .{ .counts = counts, .report = report.written() };
}

/// Runs `body` as the document `doc.md` and returns its counts and report.
fn checkForTest(arena: std.mem.Allocator, body: []const u8) !TestRun {
    return checkForTestIn(arena, body, &.{});
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

/// A stand-in for the executable, for `console` blocks. It writes its arguments, joined by
/// spaces, to standard output; `cat <file>` writes the file of the working directory instead;
/// `fail` writes `boom` to standard error and exits with 3; `both` writes to both streams;
/// `signal` does not exit by itself; `error` cannot be run.
fn echoCommand(gpa: std.mem.Allocator, io: std.Io, exec: Exec, dir: std.Io.Dir, args: []const []const u8) anyerror!Outcome {
    _ = exec;
    if (args.len > 0 and std.mem.eql(u8, args[0], "cat")) {
        return .{ .code = 0, .stdout = try dir.readFileAlloc(io, args[1], gpa, .unlimited) };
    }
    if (args.len > 0 and std.mem.eql(u8, args[0], "fail")) return .{ .code = 3, .stdout = "", .stderr = "boom\n" };
    if (args.len > 0 and std.mem.eql(u8, args[0], "both")) return .{ .code = 0, .stdout = "out\n", .stderr = "err\n" };
    if (args.len > 0 and std.mem.eql(u8, args[0], "signal")) return .{ .code = null, .stdout = "" };
    if (args.len > 0 and std.mem.eql(u8, args[0], "error")) return error.FileNotFound;
    const joined = try std.mem.join(gpa, " ", args);
    return .{ .code = 0, .stdout = try std.fmt.allocPrint(gpa, "{s}\n", .{joined}) };
}

const stand_in: Exec = .{ .exe = "stand-in", .runFn = echoProgram, .commandFn = echoCommand };

/// A stand-in for the executable: the "output" of a program is its own source, and it exits
/// with 1 when the source starts with `FAIL`, or does not exit by itself when it starts with `SIGNAL`.
fn echoProgram(gpa: std.mem.Allocator, io: std.Io, exec: Exec, dir: std.Io.Dir, path: []const u8, shown: []const u8) anyerror!Outcome {
    _ = exec;
    _ = shown;
    const source = try dir.readFileAlloc(io, path, gpa, .unlimited);
    const code: ?u8 = if (std.mem.startsWith(u8, source, "SIGNAL")) null else if (std.mem.startsWith(u8, source, "FAIL")) 1 else 0;
    return .{ .code = code, .stdout = source };
}

/// Writes `files` into a new directory, runs it, and returns the counts and the report.
fn runForTest(arena: std.mem.Allocator, files: []const TestFile) !TestRun {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    for (files) |f| {
        if (std.fs.path.dirname(f.path)) |d| try tmp.dir.createDirPath(std.testing.io, d);
        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = f.path, .data = f.data });
    }
    var report: std.Io.Writer.Allocating = .init(arena);
    const counts = try run(arena, std.testing.io, tmp.dir, "manual", stand_in, &report.writer);
    // Why: walker のパスは、Windows では `\` で区切られる。報告の文字列を `/` で書いた
    // 期待と比べるので、区切りをそろえる(Windows の層2で、この比較だけが落ちた)。
    const written = try arena.dupe(u8, report.written());
    std.mem.replaceScalar(u8, written, '\\', '/');
    return .{ .counts = counts, .report = written };
}

const passing_doc = "```scheme\n(+ 1 2)\n```\n\n```output\n3\n```\n";
const prog_scm: TestFile = .{ .path = "programs/p.scm", .data = "(display 1)\n" };
const prog_out: TestFile = .{ .path = "programs/p.out", .data = "(display 1)\n" };

test "a program file is recognised under either path separator, and only directly under programs" {
    try std.testing.expect(isProgramFile("programs/tak.scm"));
    try std.testing.expect(isProgramFile("programs\\tak.out"));
    try std.testing.expect(!isProgramFile("programs/sub/y.scm"));
    try std.testing.expect(!isProgramFile("programs\\sub\\y.scm"));
    try std.testing.expect(!isProgramFile("programs/README.md"));
    try std.testing.expect(!isProgramFile("programsx/y.scm"));
    try std.testing.expect(!isProgramFile("other/y.scm"));
    try std.testing.expect(!isProgramFile("programs"));
}

test "a directory of passing documents and programs passes, nested ones included" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const r = try runForTest(arena.allocator(), &.{
        .{ .path = "a.md", .data = passing_doc },
        .{ .path = "sub/b.md", .data = passing_doc },
        .{ .path = "x/y/z/c.md", .data = passing_doc },
        .{ .path = "programs/README.md", .data = "# Programs\n" },
        prog_scm,
        prog_out,
        .{ .path = "programs/q.scm", .data = "two\n" },
        .{ .path = "programs/q.out", .data = "two\r\n" },
    });
    try std.testing.expectEqualStrings("", r.report);
    try std.testing.expectEqual(Counts{ .blocks = 3, .programs = 2, .passed = 5, .failed = 0 }, r.counts);
    try std.testing.expectEqual(@as(u8, 0), exitStatus(r.counts));
}

test "a run with no document, no block, no program, a failing block or a stray file fails" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cases = [_]struct { files: []const TestFile, says: []const u8 }{
        .{ .files = &.{ prog_scm, prog_out }, .says = "check-examples: no `.md` file under manual\n" },
        .{ .files = &.{ .{ .path = "a.md", .data = "# Only prose\n" }, prog_scm, prog_out }, .says = "check-examples: no `scheme` block was run\n" },
        .{ .files = &.{.{ .path = "a.md", .data = passing_doc }}, .says = "check-examples: no program (`.scm` and `.out` pair) under manual/programs/\n" },
        .{ .files = &.{ .{ .path = "a.md", .data = passing_doc }, prog_scm, prog_out, .{ .path = "x.scm", .data = "(car 1)\n" } }, .says = "manual/x.scm: not a `.md` file, so nothing here checks it\n" },
        .{ .files = &.{ .{ .path = "a.md", .data = passing_doc }, prog_scm, prog_out, .{ .path = "programs/x.txt", .data = "" } }, .says = "manual/programs/x.txt: not a `.md` file" },
        .{ .files = &.{ .{ .path = "a.md", .data = passing_doc }, prog_scm, prog_out, .{ .path = "programs/sub/y.scm", .data = "" } }, .says = "manual/programs/sub/y.scm: not a `.md` file" },
        .{ .files = &.{ .{ .path = "a.md", .data = "```scheme\n(+ 1 2)\n```\n\n```output\n4\n```\n" }, prog_scm, prog_out }, .says = "manual/a.md:1: the output differs\n" },
        .{ .files = &.{ .{ .path = "a.md", .data = "```lisp\n1\n```\n" }, prog_scm, prog_out }, .says = "manual/a.md:1: this fence names a kind other than" },
    };
    for (cases) |c| {
        const r = try runForTest(a, c.files);
        try std.testing.expect(r.counts.failed >= 1);
        try std.testing.expectEqual(@as(u8, 1), exitStatus(r.counts));
        try std.testing.expect(std.mem.indexOf(u8, r.report, c.says) != null);
    }
}

test "a program fails when its pair is incomplete, its output differs, or its exit is not 0" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const doc: TestFile = .{ .path = "a.md", .data = passing_doc };
    const cases = [_]struct { files: []const TestFile, says: []const u8 }{
        .{ .files = &.{ doc, prog_scm }, .says = "manual/programs/p: the `.out` file of the pair is missing\n" },
        .{ .files = &.{ doc, prog_out }, .says = "manual/programs/p: the `.scm` file of the pair is missing\n" },
        .{ .files = &.{ doc, prog_scm, .{ .path = "programs/p.out", .data = "other\n" } }, .says = "manual/programs/p.scm: the output differs\n  expected: other\n\n  got:      (display 1)\n" },
        // 長さが同じで中身が違う出力も、差として数える。
        .{ .files = &.{ doc, .{ .path = "programs/p.scm", .data = "y\n" }, .{ .path = "programs/p.out", .data = "x\n" } }, .says = "manual/programs/p.scm: the output differs" },
        // 末尾の改行の違いも、差として数える。
        .{ .files = &.{ doc, prog_scm, .{ .path = "programs/p.out", .data = "(display 1)" } }, .says = "manual/programs/p.scm: the output differs" },
        .{ .files = &.{ doc, .{ .path = "programs/p.scm", .data = "FAIL\n" }, .{ .path = "programs/p.out", .data = "FAIL\n" } }, .says = "manual/programs/p.scm: exit code 1, expected 0\n" },
        .{ .files = &.{ doc, .{ .path = "programs/p.scm", .data = "SIGNAL\n" }, .{ .path = "programs/p.out", .data = "SIGNAL\n" } }, .says = "manual/programs/p.scm: the process did not exit by itself\n" },
    };
    for (cases) |c| {
        const r = try runForTest(a, c.files);
        try std.testing.expectEqual(@as(usize, 1), r.counts.failed);
        try std.testing.expectEqual(@as(usize, 0), r.counts.passed - r.counts.blocks);
        try std.testing.expectEqual(@as(u8, 1), exitStatus(r.counts));
        try std.testing.expect(std.mem.indexOf(u8, r.report, c.says) != null);
    }
}

test "a console block splits into commands, their output and their exit code" {
    var p = try Parsed.of(
        \\```console
        \\$ sucheme hello.scm
        \\Hello
        \\world
        \\$ sucheme -I lib missing.scm
        \\error: cannot read missing.scm
        \\[exit 66]
        \\$ sucheme quiet.scm
        \\```
        \\
    );
    defer p.deinit();
    try std.testing.expectEqual(@as(usize, 0), p.problems.len);
    try std.testing.expectEqual(@as(usize, 1), p.blocks.len);
    const cs = p.blocks[0].commands;
    try std.testing.expectEqual(@as(usize, 3), cs.len);
    try std.testing.expectEqual(@as(usize, 2), cs[0].line);
    try std.testing.expectEqual(@as(usize, 2), cs[0].args.len);
    try std.testing.expectEqualStrings("sucheme", cs[0].args[0]);
    try std.testing.expectEqualStrings("hello.scm", cs[0].args[1]);
    try std.testing.expectEqualStrings("Hello\nworld", cs[0].expected);
    try std.testing.expectEqual(@as(u8, 0), cs[0].code);
    try std.testing.expectEqual(@as(usize, 5), cs[1].line);
    try std.testing.expectEqual(@as(usize, 4), cs[1].args.len);
    try std.testing.expectEqualStrings("-I", cs[1].args[1]);
    try std.testing.expectEqualStrings("error: cannot read missing.scm", cs[1].expected);
    try std.testing.expectEqual(@as(u8, 66), cs[1].code);
    try std.testing.expectEqualStrings("", cs[2].expected);
    try std.testing.expectEqual(@as(u8, 0), cs[2].code);
}

test "an exit line may stand alone, and repeated spaces and trailing blank lines are ignored" {
    var p = try Parsed.of("```console\n$ sucheme   a.scm  b\n[exit 7]\n\n```\n");
    defer p.deinit();
    try std.testing.expectEqual(@as(usize, 0), p.problems.len);
    const c = p.blocks[0].commands[0];
    try std.testing.expectEqual(@as(usize, 3), c.args.len);
    try std.testing.expectEqualStrings("b", c.args[2]);
    try std.testing.expectEqualStrings("", c.expected);
    try std.testing.expectEqual(@as(u8, 7), c.code);
}

test "a console block this tool cannot run as written is refused" {
    for ([_]struct { doc: []const u8, line: usize }{
        // `sucheme` 以外のコマンドは走らせない。
        .{ .doc = "```console\n$ ls\n```\n", .line = 2 },
        .{ .doc = "```console\n$ echo sucheme\n```\n", .line = 2 },
        .{ .doc = "```console\n$ sucheme-extra a.scm\n```\n", .line = 2 },
        .{ .doc = "```console\n$ \n```\n", .line = 2 },
        // シェルの記号。シェルを通さないので、書いても意味が変わる。
        .{ .doc = "```console\n$ sucheme a.scm | cat\n```\n", .line = 2 },
        .{ .doc = "```console\n$ sucheme a.scm > out.txt\n```\n", .line = 2 },
        .{ .doc = "```console\n$ sucheme a.scm; rm x\n```\n", .line = 2 },
        .{ .doc = "```console\n$ sucheme a.scm && sucheme b.scm\n```\n", .line = 2 },
        .{ .doc = "```console\n$ sucheme \"a b.scm\"\n```\n", .line = 2 },
        .{ .doc = "```console\n$ sucheme 'a.scm'\n```\n", .line = 2 },
        .{ .doc = "```console\n$ sucheme $HOME\n```\n", .line = 2 },
        .{ .doc = "```console\n$ sucheme `x`\n```\n", .line = 2 },
        .{ .doc = "```console\n$ sucheme a\\ b.scm\n```\n", .line = 2 },
        .{ .doc = "```console\n$ sucheme *.scm\n```\n", .line = 2 },
        .{ .doc = "```console\n$ sucheme\ta.scm\n```\n", .line = 2 },
        // コマンドより前の出力、`[exit N]` のあとの出力、番号の誤り。
        .{ .doc = "```console\nHello\n$ sucheme a.scm\n```\n", .line = 2 },
        .{ .doc = "```console\n$ sucheme a.scm\n[exit 1]\nmore\n```\n", .line = 4 },
        .{ .doc = "```console\n$ sucheme a.scm\n[exit 1]\n[exit 2]\n```\n", .line = 4 },
        .{ .doc = "```console\n$ sucheme a.scm\n[exit 256]\n```\n", .line = 3 },
        .{ .doc = "```console\n$ sucheme a.scm\n[exit x]\n```\n", .line = 3 },
        .{ .doc = "```console\n$ sucheme a.scm\n[exit -1]\n```\n", .line = 3 },
        .{ .doc = "```console\n$ sucheme a.scm\n[exit ]\n```\n", .line = 3 },
        // コマンドの無いブロック、種類の後ろの語、`console` のあとの `output`。
        .{ .doc = "```console\n```\n", .line = 1 },
        .{ .doc = "```console\n\n```\n", .line = 1 },
        .{ .doc = "```console fresh\n$ sucheme a.scm\n```\n", .line = 1 },
        .{ .doc = "```console\n$ sucheme a.scm\n```\n```output\nx\n```\n", .line = 4 },
    }) |c| {
        var p = try Parsed.of(c.doc);
        defer p.deinit();
        try std.testing.expect(p.problems.len >= 1);
        try std.testing.expectEqual(c.line, p.problems[0].line);
    }
}

test "a dollar sign outside a console block is prose" {
    var p = try Parsed.of("$ sucheme x\n\n```scheme\n1\n```\n");
    defer p.deinit();
    try std.testing.expectEqual(@as(usize, 0), p.problems.len);
    try std.testing.expectEqual(@as(usize, 1), p.blocks.len);
}

test "console commands run in the examples directory and their standard output and error are joined" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const r = try checkForTestIn(arena.allocator(),
        \\```console
        \\$ sucheme hello world
        \\hello world
        \\$ sucheme cat hello.scm
        \\(display "hi")
        \\$ sucheme both
        \\out
        \\err
        \\$ sucheme fail
        \\boom
        \\[exit 3]
        \\```
        \\
    , &.{.{ .path = "hello.scm", .data = "(display \"hi\")\n" }});
    try std.testing.expectEqualStrings("", r.report);
    try std.testing.expectEqual(Counts{ .blocks = 0, .commands = 4, .passed = 4, .failed = 0 }, r.counts);
}

test "a console command whose output or exit code differs fails" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cases = [_]struct { doc: []const u8, says: []const u8 }{
        .{ .doc = "```console\n$ sucheme a\nb\n```\n", .says = "doc.md:2: the output differs\n  expected: b\n  got:      a\n" },
        // 期待が空でも、出力があれば差になる。
        .{ .doc = "```console\n$ sucheme a\n```\n", .says = "doc.md:2: the output differs\n  expected: \n  got:      a\n" },
        // 標準エラーの出力も数える。順序は、標準出力のあとである。
        .{ .doc = "```console\n$ sucheme both\nerr\nout\n```\n", .says = "doc.md:2: the output differs\n" },
        .{ .doc = "```console\n$ sucheme both\nout\n```\n", .says = "doc.md:2: the output differs\n" },
        // 終了コードが 0 でないのに書いていない、書いたのに違う、書いたのに 0 で終わる。
        .{ .doc = "```console\n$ sucheme fail\nboom\n```\n", .says = "doc.md:2: exit code 3, expected 0\n" },
        .{ .doc = "```console\n$ sucheme fail\nboom\n[exit 4]\n```\n", .says = "doc.md:2: exit code 3, expected 4\n" },
        .{ .doc = "```console\n$ sucheme a\na\n[exit 1]\n```\n", .says = "doc.md:2: exit code 0, expected 1\n" },
        .{ .doc = "```console\n$ sucheme signal\n```\n", .says = "doc.md:2: the process did not exit by itself\n" },
        .{ .doc = "```console\n$ sucheme error\n```\n", .says = "doc.md:2: cannot be run (FileNotFound)\n" },
        // 2 つ目のコマンドの行番号で報告する。
        .{ .doc = "```console\n$ sucheme a\na\n$ sucheme b\nc\n```\n", .says = "doc.md:4: the output differs\n" },
    };
    for (cases) |c| {
        const r = try checkForTest(a, c.doc);
        try std.testing.expect(r.counts.failed >= 1);
        try std.testing.expect(std.mem.indexOf(u8, r.report, c.says) != null);
    }
}

test "a console block and a scheme block of one file are both run, and a bad console block stops the file" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ok = try checkForTest(a, "```scheme\n(+ 1 2)\n```\n\n```output\n3\n```\n\n```console\n$ sucheme a\na\n```\n");
    try std.testing.expectEqual(Counts{ .blocks = 1, .commands = 1, .passed = 2, .failed = 0 }, ok.counts);
    const bad = try checkForTest(a, "```scheme\n(+ 1 2)\n```\n\n```console\n$ ls\n```\n");
    try std.testing.expectEqual(Counts{ .blocks = 0, .commands = 0, .passed = 0, .failed = 1 }, bad.counts);
}

test "a document with a console block needs its examples directory, and inputs there are not stray files" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const console_doc: TestFile = .{ .path = "g/a.md", .data = passing_doc ++ "\n```console\n$ sucheme cat in.scm\nx\n```\n" };
    // examples/ が無い。
    const missing = try runForTest(a, &.{ console_doc, prog_scm, prog_out });
    try std.testing.expect(missing.counts.failed >= 1);
    try std.testing.expect(std.mem.indexOf(u8, missing.report, "manual/g/a.md:") != null);
    try std.testing.expect(std.mem.indexOf(u8, missing.report, "examples") != null);
    // examples/ の入力のファイルは、`.md` でなくても、迷子として数えない。
    const ok = try runForTest(a, &.{ console_doc, prog_scm, prog_out, .{ .path = "g/examples/in.scm", .data = "x" }, .{ .path = "g/examples/lib/m/n.sld", .data = "y" } });
    try std.testing.expectEqualStrings("", ok.report);
    try std.testing.expectEqual(Counts{ .blocks = 1, .commands = 1, .programs = 1, .passed = 3, .failed = 0 }, ok.counts);
    // examples/ の外の同じ種類のファイルは、迷子である。
    const stray = try runForTest(a, &.{ console_doc, prog_scm, prog_out, .{ .path = "g/examples/in.scm", .data = "x" }, .{ .path = "g/other/in.scm", .data = "x" } });
    try std.testing.expect(std.mem.indexOf(u8, stray.report, "manual/g/other/in.scm: not a `.md` file") != null);
    // examples/ の下の `.md` は、入力でなく文書として検査する。
    const md = try runForTest(a, &.{ console_doc, prog_scm, prog_out, .{ .path = "g/examples/in.scm", .data = "x" }, .{ .path = "g/examples/n.md", .data = "```lisp\n1\n```\n" } });
    try std.testing.expect(std.mem.indexOf(u8, md.report, "manual/g/examples/n.md:1: this fence names a kind other than") != null);
}
