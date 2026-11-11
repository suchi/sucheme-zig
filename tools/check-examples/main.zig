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
//! プログラムは、実行ごとに作る空の一時ディレクトリ(`.zig-cache/tmp/` の下)を作業
//! ディレクトリにして起動し、終わったら、標準ライブラリの API で消す。補助のファイルは、
//! 同名で隣に置く(計画書 0027 の「D9 で決めること」)。
//!
//! - `名前.args`: 実行ファイルへの引数を、1行に空白で区切って書く。無ければ、`@prog` だけと
//!   同じである。`@prog` は `名前.scm` の絶対パスで、ちょうど1回書く。`@files/` で始まる
//!   引数は、`名前.files/` の絶対パスに置き換わる。文字の規則は `console` のブロックの引数と同じ。
//! - `名前.in`: 標準入力に渡す。無ければ、標準入力は空である。
//! - `名前.files/`: `.args` が `@files/` で指す、補助のファイル(`-I` で読む `.sld` と、
//!   プログラムが読む入力)を置く。
//! - `名前.out` の最後の行が `[exit N]` なら、終了コード N を求め、その行は標準出力の比べから
//!   外す。無ければ 0 を求める。
//!
//! `.in` と `.args` と `.files/` は、同名の `.scm` が無ければ失敗とする。`.files/` は、`.args`
//! が使わなければ失敗とし、`.args` が `@files/` を使うのに `.files/` が無いことも失敗とする。
//!
//! ライブラリの索引(docs/manual/reference/scheme-*.md)は、`lib/scheme/*.sld` の `export` と
//! 双方向に突き合わせる。ライブラリごとに `reference/<名前をつないだもの>.md` が要り、その表の
//! 行(`| `識別子` | R7RS の節 | 項目 |`)と輸出が一致しなければ失敗とする。ライブラリの置き場が
//! 無いこと、ライブラリが1つも無いこと、ライブラリの無い索引も失敗である。
//!
//! docs/manual/ の下の、上のどれでもないファイル、`.md` が無いこと、`scheme` のブロックが
//! 1つも無いことも、失敗とする。引数は、実行ファイルのパスの1つだけである。範囲を狭める
//! 引数は、検査を減らしたまま緑にする手段になるからである(tools/test-scheme と同じ理由)。

const std = @import("std");
const sucheme = @import("sucheme");

/// Where the documents are.
const manual_dir = "docs/manual";

/// Where the libraries that a program can `import` are, from the repository root.
const lib_dir = "lib/scheme";

/// The directory of the indexes of the libraries, under the documents.
const reference_dir = "reference";

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
    // ライブラリの置き場が開けなくても、文書の検査は続ける(索引の検査が失敗として数える)。
    // ここで戻ると、文書の検査を減らしたまま、別の理由で赤になる。
    var libs: ?std.Io.Dir = std.Io.Dir.cwd().openDir(io, lib_dir, .{ .iterate = true }) catch |e| blk: {
        try err.print("check-examples: cannot open {s} ({t})\n", .{ lib_dir, e });
        break :blk null;
    };
    defer if (libs) |*l| l.close(io);
    const counts = try run(gpa, io, dir, manual_dir, libs, exec, err);
    try err.print("check-examples: {d} checks passed, {d} failed ({d} blocks, {d} commands, {d} programs, {d} libraries)\n", .{ counts.passed, counts.failed, counts.blocks, counts.commands, counts.programs, counts.libraries });
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
    /// Runs a program as `launch` says, and returns what it gave. `dir` is the directory of the documents.
    runFn: *const fn (gpa: std.mem.Allocator, io: std.Io, exec: Exec, dir: std.Io.Dir, launch: Launch) anyerror!Outcome,
    /// Runs the executable with `args` (without the program name), with `dir` as the working directory.
    commandFn: *const fn (gpa: std.mem.Allocator, io: std.Io, exec: Exec, dir: std.Io.Dir, args: []const []const u8) anyerror!Outcome,
};

/// How one program is run.
const Launch = struct {
    /// The program's `.scm`, relative to the directory of the documents (a stand-in reads the source from it).
    rel_scm: []const u8,
    /// The arguments of the executable, without its name. The paths in them are absolute.
    args: []const []const u8,
    /// The file to give as standard input, relative to the directory of the documents, or null for none.
    stdin: ?[]const u8,
    /// The working directory: a new empty directory that the caller removes after the run.
    cwd: std.Io.Dir,
    /// The program's name in the report.
    shown: []const u8,
};

/// The exit code of a process that ended as `term`, or null when it did not exit by itself (a signal, a stop).
fn exitCode(term: std.process.Child.Term) ?u8 {
    return switch (term) {
        .exited => |c| c,
        else => null,
    };
}

/// Runs the real executable as `launch` says.
fn runExecutable(gpa: std.mem.Allocator, io: std.Io, exec: Exec, dir: std.Io.Dir, launch: Launch) anyerror!Outcome {
    const argv = try gpa.alloc([]const u8, launch.args.len + 1);
    argv[0] = exec.exe;
    @memcpy(argv[1..], launch.args);
    // 標準入力は、パイプに書かず、開いたファイルをそのまま渡す。パイプに書くと、子が入力を
    // 読み切る前に出力で詰まったときに、こちらも書き込みで止まる。
    var stdin_file: ?std.Io.File = null;
    defer if (stdin_file) |f| f.close(io);
    if (launch.stdin) |p| stdin_file = try dir.openFile(io, p, .{});
    return runProcess(gpa, io, argv, launch.cwd, stdin_file);
}

/// Runs `argv` in `cwd` with `stdin` as its standard input (none when null), and collects its output.
///
/// `std.process.run` の写しである。`run` は標準入力を無視に固定するので、ファイルを渡せない。
fn runProcess(gpa: std.mem.Allocator, io: std.Io, argv: []const []const u8, cwd: std.Io.Dir, stdin: ?std.Io.File) anyerror!Outcome {
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .cwd = .{ .dir = cwd },
        .stdin = if (stdin) |f| .{ .file = f } else .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    defer child.kill(io);

    var multi_reader_buffer: std.Io.File.MultiReader.Buffer(2) = undefined;
    var multi_reader: std.Io.File.MultiReader = undefined;
    multi_reader.init(gpa, io, multi_reader_buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer multi_reader.deinit();

    // 暴走するプログラムが検査を止めたままにしないよう、時間に上限を置く。
    const timeout: std.Io.Timeout = .{ .duration = .{ .raw = .fromSeconds(120), .clock = .awake } };
    while (multi_reader.fill(64, timeout)) |_| {} else |err| switch (err) {
        error.EndOfStream => {},
        else => |e| return e,
    }
    try multi_reader.checkAnyError();
    const term = try child.wait(io);
    return .{
        .code = exitCode(term),
        .stdout = try multi_reader.toOwnedSlice(0),
        .stderr = try multi_reader.toOwnedSlice(1),
    };
}

/// Where the working directories of the programs are made, under the working directory of this process.
const temp_root = ".zig-cache/tmp";

/// A new empty directory under `temp_root`.
const TempDir = struct {
    dir: std.Io.Dir,
    /// The path from the working directory of this process, to remove it.
    sub_path: []const u8,
};

/// Makes a new empty directory with a random name. It fails when the name is taken.
fn makeTempDir(gpa: std.mem.Allocator, io: std.Io) !TempDir {
    var bytes: [8]u8 = undefined;
    io.random(&bytes);
    const hex = std.fmt.bytesToHex(bytes, .lower);
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, temp_root);
    const sub_path = try std.fmt.allocPrint(gpa, "{s}/check-examples-{s}", .{ temp_root, hex });
    try cwd.createDir(io, sub_path, .default_dir);
    return .{ .dir = try cwd.openDir(io, sub_path, .{ .iterate = true }), .sub_path = sub_path };
}

/// Closes `temp` and removes it with what is in it.
///
/// Why: 開いたままのディレクトリは Windows で消せないので、先に閉じる。消せなければ、
/// 残骸を黙って残さず、呼び出し側が失敗として数える。
fn removeTempDir(io: std.Io, temp: TempDir) !void {
    temp.dir.close(io);
    try std.Io.Dir.cwd().deleteTree(io, temp.sub_path);
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
        .code = exitCode(result.term),
        .stdout = result.stdout,
        .stderr = result.stderr,
    };
}

/// A program of `programs/`: the files of one name that were found.
const Program = struct {
    name: []const u8,
    has_scm: bool = false,
    has_out: bool = false,
    has_in: bool = false,
    has_args: bool = false,
    /// Whether the directory `名前.files/` (or something in it) was found.
    has_files: bool = false,
};

/// The part of `path` below `programs/`, or null when `path` is not under it.
fn belowPrograms(path: []const u8) ?[]const u8 {
    // Windows の歩き方は `\\` で区切る(path.sep)ので、区切りは両方を受け付ける。
    const dir_name = programs_dir[0 .. programs_dir.len - 1];
    if (!std.mem.startsWith(u8, path, dir_name)) return null;
    if (path.len == dir_name.len or (path[dir_name.len] != '/' and path[dir_name.len] != '\\')) return null;
    return path[dir_name.len + 1 ..];
}

/// The extensions of the files of a program, directly under `programs/`.
const program_exts = [_][]const u8{ ".scm", ".out", ".in", ".args" };

/// The suffix of the directory of the auxiliary files of a program.
const files_suffix = ".files";

/// The extension of `name` when it is `<stem><ext>` with a stem and one of `program_exts`.
fn programExt(name: []const u8) ?[]const u8 {
    for (program_exts) |ext| {
        if (name.len > ext.len and std.mem.endsWith(u8, name, ext)) return ext;
    }
    return null;
}

/// Whether `path` is a `.scm`, `.out`, `.in` or `.args` file directly under `programs/`.
fn isProgramFile(path: []const u8) bool {
    const rest = belowPrograms(path) orelse return false;
    // サブディレクトリの中は、プログラムとして読まない。
    if (std.mem.indexOfAny(u8, rest, "/\\") != null) return false;
    return programExt(rest) != null;
}

/// The name of the program when `path` is the directory `programs/<name>.files`, or something in it.
fn programFilesStem(path: []const u8) ?[]const u8 {
    const rest = belowPrograms(path) orelse return null;
    const first = rest[0 .. std.mem.indexOfAny(u8, rest, "/\\") orelse rest.len];
    if (first.len <= files_suffix.len or !std.mem.endsWith(u8, first, files_suffix)) return null;
    return first[0 .. first.len - files_suffix.len];
}

/// Whether `path` is inside a directory `programs/<name>.files` (not the directory itself).
fn isInProgramFilesDir(path: []const u8) bool {
    const rest = belowPrograms(path) orelse return false;
    return programFilesStem(path) != null and std.mem.indexOfAny(u8, rest, "/\\") != null;
}

/// What `buildArgs` refuses.
const ArgsError = error{
    /// The line has no `@prog`.
    NoProgram,
    /// The line has `@prog` more than once.
    ManyPrograms,
    /// The text is more than one line.
    MoreThanOneLine,
    /// An argument has a character this tool does not run as written, is an absolute path, or has `..`.
    NotPlain,
    /// An argument starts with `@` and is neither `@prog` nor `@files/...`.
    UnknownPlaceholder,
    OutOfMemory,
};

/// The arguments of a program's run, read from the line of its `.args` file.
const BuiltArgs = struct {
    args: []const []const u8,
    /// Whether an argument names something in the directory of auxiliary files.
    uses_files: bool,
};

/// Reads the line `text` of a `.args` file into the arguments of the executable.
///
/// `text` が null(`.args` が無い)なら、引数は `prog` だけである。`@prog` は `prog`、
/// `@files/<x>` は `files` と `/` と `<x>` に置き換える。置き換えの前の綴りで、`console` の
/// ブロックと同じ文字の規則(`isPlainArgument`)を検査する。`@files/../x` は `..` で断られる。
fn buildArgs(gpa: std.mem.Allocator, text: ?[]const u8, prog: []const u8, files: []const u8) ArgsError!BuiltArgs {
    const line = text orelse return .{ .args = try gpa.dupe([]const u8, &.{prog}), .uses_files = false };
    // 末尾の改行(と CRLF の CR)は許す。途中の改行は、複数の行である。
    const trimmed = std.mem.trimEnd(u8, line, " \r\n");
    if (std.mem.indexOfScalar(u8, trimmed, '\n') != null) return error.MoreThanOneLine;
    var args: std.ArrayList([]const u8) = .empty;
    var progs: usize = 0;
    var uses_files = false;
    var words = std.mem.tokenizeScalar(u8, trimmed, ' ');
    while (words.next()) |word| {
        if (!isPlainArgument(word)) return error.NotPlain;
        if (std.mem.eql(u8, word, "@prog")) {
            progs += 1;
            try args.append(gpa, prog);
        } else if (std.mem.startsWith(u8, word, "@files/")) {
            uses_files = true;
            try args.append(gpa, try std.fmt.allocPrint(gpa, "{s}/{s}", .{ files, word["@files/".len..] }));
        } else if (word[0] == '@') {
            return error.UnknownPlaceholder;
        } else {
            try args.append(gpa, word);
        }
    }
    if (progs == 0) return error.NoProgram;
    if (progs > 1) return error.ManyPrograms;
    return .{ .args = try args.toOwnedSlice(gpa), .uses_files = uses_files };
}

/// An expected output of a program, split into the standard output and the exit code.
const ExpectedOutput = struct {
    stdout: []const u8,
    code: u8,
};

/// Splits the text of a `.out` file at its last line, when that line is `[exit N]`.
///
/// 最後の行が `[exit` で始まるのに `[exit N]` の形でなければ、`error.BadExitLine` である。
/// 行は、標準出力の比べから外す。無ければ、終了コードは 0 である(`console` のブロックと同じ)。
fn splitExitMarker(text: []const u8) error{BadExitLine}!ExpectedOutput {
    const body = if (std.mem.endsWith(u8, text, "\n")) text[0 .. text.len - 1] else text;
    const line_start = if (std.mem.lastIndexOfScalar(u8, body, '\n')) |i| i + 1 else 0;
    const line = std.mem.trimEnd(u8, body[line_start..], " \t");
    if (!std.mem.startsWith(u8, line, "[exit")) return .{ .stdout = text, .code = 0 };
    const code = parseExit(line) orelse return error.BadExitLine;
    return .{ .stdout = text[0..line_start], .code = code };
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
fn run(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, name: []const u8, libs: ?std.Io.Dir, exec: Exec, w: *std.Io.Writer) !Counts {
    var counts: Counts = .{};
    var paths: std.ArrayList([]const u8) = .empty;
    var programs: std.ArrayList(Program) = .empty;
    var walker = try dir.walk(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        // `名前.files/` は、ディレクトリそのものと、その中のすべてが、その名前のプログラムの
        // 補助のファイルである。中は種類を問わず受け付ける(`examples/` と同じ)。
        if (programFilesStem(entry.path)) |stem| {
            (try programNamed(gpa, &programs, stem)).has_files = true;
            continue;
        }
        if (entry.kind == .directory) continue;
        if (entry.kind == .file and isProgramFile(entry.path)) {
            const ext = programExt(entry.basename).?;
            const pr = try programNamed(gpa, &programs, entry.basename[0 .. entry.basename.len - ext.len]);
            if (std.mem.eql(u8, ext, ".scm")) pr.has_scm = true;
            if (std.mem.eql(u8, ext, ".out")) pr.has_out = true;
            if (std.mem.eql(u8, ext, ".in")) pr.has_in = true;
            if (std.mem.eql(u8, ext, ".args")) pr.has_args = true;
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

    try checkIndexes(gpa, io, dir, name, libs, paths.items, w, &counts);

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

/// The entry of `programs` named `name`, added when there is none.
fn programNamed(gpa: std.mem.Allocator, programs: *std.ArrayList(Program), name: []const u8) error{OutOfMemory}!*Program {
    for (programs.items) |*pr| {
        if (std.mem.eql(u8, pr.name, name)) return pr;
    }
    try programs.append(gpa, .{ .name = try gpa.dupe(u8, name) });
    return &programs.items[programs.items.len - 1];
}

/// What running a program in a temporary directory gave, and whether removing the directory failed.
const TempRun = struct {
    outcome: anyerror!Outcome,
    removed: ?anyerror,
};

/// Makes the working directory of a program, runs it there, and removes the directory.
///
/// 失敗しても、タイムアウトで止められても、ディレクトリは消す。
fn runInTempDir(gpa: std.mem.Allocator, io: std.Io, exec: Exec, dir: std.Io.Dir, launch: Launch) !TempRun {
    const temp = try makeTempDir(gpa, io);
    var with_cwd = launch;
    with_cwd.cwd = temp.dir;
    const outcome = exec.runFn(gpa, io, exec, dir, with_cwd);
    const removed: ?anyerror = if (removeTempDir(io, temp)) |_| null else |e| e;
    return .{ .outcome = outcome, .removed = removed };
}

/// Runs one program and compares its standard output and exit code with its `.out` file (the exit code is 0 unless the file ends with `[exit N]`).
///
/// 引数は `.args`、標準入力は `.in`、補助のファイルは `.files/` から取り、作業ディレクトリは、
/// 実行ごとに作る空の一時ディレクトリにする。
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
    const rel_args = try std.fmt.allocPrint(gpa, "{s}{s}.args", .{ programs_dir, pr.name });
    const rel_in = try std.fmt.allocPrint(gpa, "{s}{s}.in", .{ programs_dir, pr.name });
    const rel_files = try std.fmt.allocPrint(gpa, "{s}{s}{s}", .{ programs_dir, pr.name, files_suffix });
    const shown = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ name, rel_scm });
    const expected_raw = dir.readFileAlloc(io, rel_out, gpa, .unlimited) catch |e| {
        try w.print("{s}/{s}: cannot be read ({t})\n", .{ name, rel_out, e });
        counts.failed += 1;
        return;
    };
    // Git の改行の変換でチェックアウトした `.out` も、LF のものと同じに読む。
    const expected_text = try std.mem.replaceOwned(u8, gpa, expected_raw, "\r\n", "\n");
    const expected = splitExitMarker(expected_text) catch {
        try w.print("{s}/{s}: the last line starts with `[exit` but is not `[exit N]` with N from 0 to 255\n", .{ name, rel_out });
        counts.failed += 1;
        return;
    };

    // 実行ファイルへの引数。`.args` の中の `@prog` と `@files/` を、絶対パスに置き換える。
    const prog_path = try dir.realPathFileAlloc(io, rel_scm, gpa);
    const files_path: []const u8 = if (pr.has_files) try dir.realPathFileAlloc(io, rel_files, gpa) else "";
    var args_text: ?[]const u8 = null;
    if (pr.has_args) {
        const raw = dir.readFileAlloc(io, rel_args, gpa, .unlimited) catch |e| {
            try w.print("{s}/{s}: cannot be read ({t})\n", .{ name, rel_args, e });
            counts.failed += 1;
            return;
        };
        args_text = try std.mem.replaceOwned(u8, gpa, raw, "\r\n", "\n");
    }
    const built = buildArgs(gpa, args_text, prog_path, files_path) catch |e| {
        const why = switch (e) {
            error.NoProgram => "it needs `@prog`, the program itself, exactly once",
            error.ManyPrograms => "it has `@prog` more than once",
            error.MoreThanOneLine => "it must be one line",
            error.NotPlain => "an argument has a character a shell would read, is an absolute path, or has `..`",
            error.UnknownPlaceholder => "an argument starts with `@` but is neither `@prog` nor `@files/...`",
            error.OutOfMemory => return error.OutOfMemory,
        };
        try w.print("{s}/{s}: {s}\n", .{ name, rel_args, why });
        counts.failed += 1;
        return;
    };
    // 補助のディレクトリは、`.args` が使うときだけ置く(迷子も、足りないのも断る)。
    if (built.uses_files and !pr.has_files) {
        try w.print("{s}/{s}: it names `@files/`, but the directory {s}{s} does not exist\n", .{ name, rel_args, pr.name, files_suffix });
        counts.failed += 1;
        return;
    }
    if (pr.has_files and !built.uses_files) {
        try w.print("{s}/{s}{s}{s}: no `.args` argument names it with `@files/`, so nothing here checks it\n", .{ name, programs_dir, pr.name, files_suffix });
        counts.failed += 1;
        return;
    }

    const launch: Launch = .{
        .rel_scm = rel_scm,
        .args = built.args,
        .stdin = if (pr.has_in) rel_in else null,
        .cwd = undefined, // runInTempDir が、実行ごとの一時ディレクトリを入れる。
        .shown = shown,
    };
    const ran = try runInTempDir(gpa, io, exec, dir, launch);
    if (ran.removed) |e| {
        try w.print("{s}: cannot remove its temporary directory ({t})\n", .{ shown, e });
        counts.failed += 1;
    }
    const outcome = ran.outcome catch |e| {
        try w.print("{s}: cannot be run ({t})\n", .{ shown, e });
        counts.failed += 1;
        return;
    };
    if (outcome.code != expected.code) {
        if (outcome.code) |c| {
            try w.print("{s}: exit code {d}, expected {d}\n", .{ shown, c, expected.code });
        } else {
            try w.print("{s}: the process did not exit by itself\n", .{shown});
        }
        counts.failed += 1;
        return;
    }
    if (!std.mem.eql(u8, outcome.stdout, expected.stdout)) {
        try w.print("{s}: the output differs\n  expected: {s}\n  got:      {s}\n", .{ shown, expected.stdout, outcome.stdout });
        counts.failed += 1;
        return;
    }
    if (ran.removed == null) counts.passed += 1;
}

/// A library under `lib/scheme/`: its name (`scheme base`, the words joined by a space) and what it exports.
const Library = struct {
    name: []const u8,
    exports: []const []const u8,
};

/// Why the file of a library cannot be read for its exports.
const LibraryError = error{ NoLibrary, NoExport, NonSymbolExport, CondExpand, Unbalanced };

/// What a token of a library file is.
const TokenKind = enum { open, close, atom };

const Token = struct { kind: TokenKind, text: []const u8 = "" };

/// Splits `src` into parentheses and atoms, without comments.
///
/// 読むのは、`(define-library (名前) (export ...) ...)` の形に要る範囲だけである。行コメント、
/// 文字列、`#\(` のような文字、`#| |#` を、括弧の数えを狂わせないよう飛ばす。
fn tokenize(gpa: std.mem.Allocator, src: []const u8) error{OutOfMemory}![]Token {
    var tokens: std.ArrayList(Token) = .empty;
    var i: usize = 0;
    while (i < src.len) {
        const ch = src[i];
        switch (ch) {
            ' ', '\t', '\r', '\n' => i += 1,
            ';' => {
                while (i < src.len and src[i] != '\n') i += 1;
            },
            '(' => {
                try tokens.append(gpa, .{ .kind = .open });
                i += 1;
            },
            ')' => {
                try tokens.append(gpa, .{ .kind = .close });
                i += 1;
            },
            '"' => {
                const start = i;
                i += 1;
                while (i < src.len and src[i] != '"') i += if (src[i] == '\\') 2 else 1;
                i = @min(i + 1, src.len);
                try tokens.append(gpa, .{ .kind = .atom, .text = src[start..i] });
            },
            else => {
                if (ch == '#' and i + 1 < src.len and src[i + 1] == '|') {
                    // 入れ子にしないブロックコメント。閉じが無ければ、残りを読み捨てる。
                    const end = std.mem.indexOfPos(u8, src, i + 2, "|#") orelse src.len;
                    i = @min(end + 2, src.len);
                    continue;
                }
                const start = i;
                // `#\(` のように、文字の名前の最初の1字は区切りでも atom に含める。
                if (ch == '#' and i + 2 < src.len and src[i + 1] == '\\') i += 3;
                while (i < src.len and std.mem.indexOfScalar(u8, " \t\r\n();\"", src[i]) == null) i += 1;
                try tokens.append(gpa, .{ .kind = .atom, .text = src[start..i] });
            },
        }
    }
    return try tokens.toOwnedSlice(gpa);
}

/// Reads the name and the exports of the library `src` defines.
///
/// 輸出は、`(export ...)` の宣言のすべてから集める。`(rename a b)` のような、識別子でない要素は、
/// この道具が読まないので誤りにする(読み飛ばすと、索引との突き合わせが黙って抜ける)。
fn parseLibrary(gpa: std.mem.Allocator, src: []const u8) (error{OutOfMemory} || LibraryError)!Library {
    const tokens = try tokenize(gpa, src);
    if (tokens.len < 4 or tokens[0].kind != .open or tokens[1].kind != .atom or
        !std.mem.eql(u8, tokens[1].text, "define-library") or tokens[2].kind != .open)
    {
        return error.NoLibrary;
    }
    var name: std.ArrayList(u8) = .empty;
    var i: usize = 3;
    while (i < tokens.len and tokens[i].kind == .atom) : (i += 1) {
        if (name.items.len != 0) try name.append(gpa, ' ');
        try name.appendSlice(gpa, tokens[i].text);
    }
    if (name.items.len == 0 or i >= tokens.len or tokens[i].kind != .close) return error.NoLibrary;
    i += 1;
    var exports: std.ArrayList([]const u8) = .empty;
    var saw_export = false;
    // `depth` は、define-library の中を 0 とした、いまの括弧の深さである。
    var depth: usize = 0;
    while (i < tokens.len) : (i += 1) {
        const t = tokens[i];
        switch (t.kind) {
            .close => {
                if (depth == 0) {
                    if (!saw_export) return error.NoExport;
                    return .{ .name = try name.toOwnedSlice(gpa), .exports = try exports.toOwnedSlice(gpa) };
                }
                depth -= 1;
            },
            .atom => {},
            .open => {
                const head_atom = depth == 0 and i + 1 < tokens.len and tokens[i + 1].kind == .atom;
                // `cond-expand` の中の `export` は、条件で輸出が変わる。ランタイムは処理するが、
                // この道具は条件を解釈しないので、読み飛ばさず断る。
                if (head_atom and std.mem.eql(u8, tokens[i + 1].text, "cond-expand")) return error.CondExpand;
                const is_export = head_atom and std.mem.eql(u8, tokens[i + 1].text, "export");
                if (!is_export) {
                    depth += 1;
                    continue;
                }
                saw_export = true;
                i += 2;
                while (i < tokens.len and tokens[i].kind != .close) : (i += 1) {
                    if (tokens[i].kind == .open) return error.NonSymbolExport;
                    try exports.append(gpa, tokens[i].text);
                }
                if (i >= tokens.len) return error.Unbalanced;
            },
        }
    }
    return error.Unbalanced;
}

/// A row of an index: an identifier and the section of R7RS that defines it.
const IndexRow = struct {
    line: usize,
    ident: []const u8,
    section: []const u8,
};

/// Whether `s` is a section number of R7RS: one to three groups of digits joined by dots (`6`, `6.4`, `6.13.1`).
fn isSectionNumber(s: []const u8) bool {
    var groups: usize = 0;
    var parts = std.mem.splitScalar(u8, s, '.');
    while (parts.next()) |part| {
        if (part.len == 0) return false;
        for (part) |ch| if (!std.ascii.isDigit(ch)) return false;
        groups += 1;
    }
    return groups >= 1 and groups <= 3;
}

/// Whether `line` is the separator row of a Markdown table (`| --- | --- |`).
fn isTableSeparator(line: []const u8) bool {
    if (line.len == 0 or line[0] != '|') return false;
    return std.mem.indexOf(u8, line, "---") != null and
        std.mem.indexOfNone(u8, line, "|-: \t") == null;
}

/// Reads the rows of the table of an index document, and reports a row it cannot read.
///
/// 表は、区切りの行(`| --- |`)のあとの、`|` で始まる行である。区切りより前の行(見出しの行と
/// 地の文)は読まない。1行は `| `識別子` | 節番号 | 項目 |` の形で、節番号は R7RS の節の番号である。
/// 表のあとの空行から先に `|` で始まる行があれば、2つ目の表なので、断る。
fn parseIndex(gpa: std.mem.Allocator, body: []const u8, problems: *std.ArrayList(Problem)) error{OutOfMemory}![]IndexRow {
    var rows: std.ArrayList(IndexRow) = .empty;
    const State = enum { before, inside, after };
    var state: State = .before;
    var lineno: usize = 0;
    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |raw| {
        lineno += 1;
        const line = std.mem.trim(u8, raw, " \t\r");
        switch (state) {
            .before => if (isTableSeparator(line)) {
                state = .inside;
            },
            .inside => {
                if (line.len == 0 or line[0] != '|') {
                    state = .after;
                    continue;
                }
                var cells = std.mem.splitScalar(u8, line, '|');
                // 先頭の `|` の前と、末尾の `|` の後ろは空で、間に3つのセルがある。
                const first = cells.next().?;
                const ident_cell = std.mem.trim(u8, cells.next() orelse "", " \t");
                const section_cell = std.mem.trim(u8, cells.next() orelse "", " \t");
                _ = cells.next();
                const last = cells.next() orelse "x";
                if (first.len != 0 or last.len != 0 or cells.next() != null) {
                    try problems.append(gpa, .{ .line = lineno, .message = "this table row must have the form `| `identifier` | section | item |`, with three cells" });
                    continue;
                }
                if (ident_cell.len < 3 or ident_cell[0] != '`' or ident_cell[ident_cell.len - 1] != '`' or
                    std.mem.indexOfAny(u8, ident_cell[1 .. ident_cell.len - 1], "` \t") != null)
                {
                    try problems.append(gpa, .{ .line = lineno, .message = "the first cell of this row must be one identifier in backticks" });
                    continue;
                }
                if (!isSectionNumber(section_cell)) {
                    try problems.append(gpa, .{ .line = lineno, .message = "the second cell of this row must be a section number of R7RS such as `6.4` or `6.13.1`" });
                }
                try rows.append(gpa, .{ .line = lineno, .ident = ident_cell[1 .. ident_cell.len - 1], .section = section_cell });
            },
            .after => if (line.len != 0 and line[0] == '|') {
                try problems.append(gpa, .{ .line = lineno, .message = "this table row comes after the end of the index table; keep the rows of an index in one table" });
            },
        }
    }
    if (state == .before) {
        try problems.append(gpa, .{ .line = 1, .message = "this index has no table; it needs a table whose separator row is `| --- | --- | --- |`" });
    }
    return try rows.toOwnedSlice(gpa);
}

/// Compares the identifiers `library` exports with the rows of its index at `path`, and reports every difference.
///
/// 双方向に比べる。輸出されるのに行が無い識別子と、行があるのに輸出されない識別子と、同じ識別子の
/// 2つ目の行を、それぞれ失敗として数える。差が1つも無く、`read_cleanly` のときに、成功を1つ数える。
fn compareIndex(path: []const u8, library: Library, rows: []const IndexRow, read_cleanly: bool, w: *std.Io.Writer, counts: *Counts) !void {
    // 行を読むときに断ったものがあれば、差が無くても成功にしない。
    var clean = read_cleanly;
    for (rows, 0..) |row, k| {
        for (rows[0..k]) |earlier| {
            if (std.mem.eql(u8, earlier.ident, row.ident)) {
                try w.print("{s}:{d}: `{s}` is listed twice (first at line {d})\n", .{ path, row.line, row.ident, earlier.line });
                counts.failed += 1;
                clean = false;
                break;
            }
        }
        const found = for (library.exports) |id| {
            if (std.mem.eql(u8, id, row.ident)) break true;
        } else false;
        if (!found) {
            try w.print("{s}:{d}: `{s}` is not exported by ({s})\n", .{ path, row.line, row.ident, library.name });
            counts.failed += 1;
            clean = false;
        }
    }
    for (library.exports) |id| {
        const listed = for (rows) |row| {
            if (std.mem.eql(u8, row.ident, id)) break true;
        } else false;
        if (!listed) {
            try w.print("{s}: `{s}` is exported by ({s}) but has no row in the index\n", .{ path, id, library.name });
            counts.failed += 1;
            clean = false;
        }
    }
    if (clean) counts.passed += 1;
}

/// The path of the index of `library`, under the documents: `reference/scheme-base.md` for `(scheme base)`.
fn indexPath(gpa: std.mem.Allocator, library_name: []const u8) error{OutOfMemory}![]const u8 {
    const dashed = try gpa.dupe(u8, library_name);
    std.mem.replaceScalar(u8, dashed, ' ', '-');
    return try std.fmt.allocPrint(gpa, "{s}/{s}.md", .{ reference_dir, dashed });
}

/// Whether the document at `path` is named like the index of a library: `reference/scheme-*.md`, directly under `reference/`.
fn isIndexFile(path: []const u8) bool {
    const prefix = reference_dir ++ "/scheme-";
    // 接頭辞と `.md` の間に、ライブラリの名前の綴りが1字以上要る。
    if (path.len < prefix.len + 4 or !std.mem.endsWith(u8, path, ".md")) return false;
    // Windows の歩き方は `\\` で区切る。
    for (path[0..prefix.len], prefix) |a, b| {
        if (a != b and !(a == '\\' and b == '/')) return false;
    }
    return std.mem.indexOfAny(u8, path[prefix.len..], "/\\") == null;
}

/// Compares the index of every library under `lib/scheme/` with its exports.
///
/// ライブラリの置き場が開けないこと、ライブラリが1つも無いこと、読めないライブラリがあることは、
/// 失敗として数える。どのライブラリの索引でもない `reference/scheme-*.md` も、失敗として数える
/// (ライブラリを消したのに索引が残ること、名前の綴りの食い違いを黙って残さない)。
fn checkIndexes(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, name: []const u8, libs: ?std.Io.Dir, paths: []const []const u8, w: *std.Io.Writer, counts: *Counts) !void {
    const lib_dir_handle = libs orelse {
        try w.print("check-examples: no library directory {s}, so no index was compared with the exports\n", .{lib_dir});
        counts.failed += 1;
        return;
    };
    var libraries: std.ArrayList(Library) = .empty;
    var files: usize = 0;
    var walker = try lib_dir_handle.walk(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".sld")) continue;
        // サブディレクトリの中は、`lib/scheme` の識別子として読まない。
        if (std.mem.indexOfAny(u8, entry.path, "/\\") != null) continue;
        files += 1;
        const src = lib_dir_handle.readFileAlloc(io, entry.path, gpa, .unlimited) catch |e| {
            try w.print("{s}/{s}: cannot be read ({t})\n", .{ lib_dir, entry.path, e });
            counts.failed += 1;
            continue;
        };
        const library = parseLibrary(gpa, src) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.NoLibrary => {
                try w.print("{s}/{s}: not of the form `(define-library (name) ...)`\n", .{ lib_dir, entry.path });
                counts.failed += 1;
                continue;
            },
            error.NoExport => {
                try w.print("{s}/{s}: no `(export ...)` declaration\n", .{ lib_dir, entry.path });
                counts.failed += 1;
                continue;
            },
            error.NonSymbolExport => {
                try w.print("{s}/{s}: an `(export ...)` declaration has an element that is not an identifier (a `rename`?), which this tool does not read\n", .{ lib_dir, entry.path });
                counts.failed += 1;
                continue;
            },
            error.CondExpand => {
                try w.print("{s}/{s}: a `cond-expand` declaration, whose exports depend on a condition this tool does not read\n", .{ lib_dir, entry.path });
                counts.failed += 1;
                continue;
            },
            error.Unbalanced => {
                try w.print("{s}/{s}: the parentheses do not balance\n", .{ lib_dir, entry.path });
                counts.failed += 1;
                continue;
            },
        };
        try libraries.append(gpa, library);
    }
    if (files == 0) {
        try w.print("check-examples: no `.sld` file under {s}, so no index was compared with the exports\n", .{lib_dir});
        counts.failed += 1;
    }
    std.mem.sort(Library, libraries.items, {}, libraryLessThan);

    var expected_paths: std.ArrayList([]const u8) = .empty;
    for (libraries.items) |library| {
        counts.libraries += 1;
        const rel = try indexPath(gpa, library.name);
        try expected_paths.append(gpa, rel);
        const shown = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ name, rel });
        const body = dir.readFileAlloc(io, rel, gpa, .unlimited) catch |e| {
            try w.print("{s}: no index of ({s}) ({t})\n", .{ shown, library.name, e });
            counts.failed += 1;
            continue;
        };
        var problems: std.ArrayList(Problem) = .empty;
        const rows = try parseIndex(gpa, body, &problems);
        for (problems.items) |p| {
            try w.print("{s}:{d}: {s}\n", .{ shown, p.line, p.message });
            counts.failed += 1;
        }
        try compareIndex(shown, library, rows, problems.items.len == 0, w, counts);
    }
    for (paths) |path| {
        if (!isIndexFile(path)) continue;
        const normal = try gpa.dupe(u8, path);
        std.mem.replaceScalar(u8, normal, '\\', '/');
        const known = for (expected_paths.items) |p| {
            if (std.mem.eql(u8, p, normal)) break true;
        } else false;
        if (!known) {
            try w.print("{s}/{s}: the index of no library under {s}\n", .{ name, normal, lib_dir });
            counts.failed += 1;
        }
    }
}

fn libraryLessThan(_: void, a: Library, b: Library) bool {
    return std.mem.lessThan(u8, a.name, b.name);
}

/// The counts of a run.
const Counts = struct {
    /// The libraries whose index was compared with their exports, passed or not.
    libraries: usize = 0,
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

/// Whether `arg` may be an argument of a command: letters, digits and `._/-=+,:@%`, not an absolute path, with no `..` element.
///
/// 絶対パスと `..` は、`examples/` の外のファイルを走らせられるので断る。文書の例は、
/// `examples/` の中だけを使う。
///
/// 引数はシェルを通さずに渡すので、引用符、空白、リダイレクト、`$`、`*` などは、書いたとおりの
/// 意味にならない。書けないようにして、読者がシェルの意味で読む例を断る。
fn isPlainArgument(arg: []const u8) bool {
    if (arg.len == 0 or arg[0] == '/') return false;
    var parts = std.mem.tokenizeScalar(u8, arg, '/');
    while (parts.next()) |part| if (std.mem.eql(u8, part, "..")) return false;
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
/// `crlf` writes lines ending in CRLF; `fail` writes `boom` to standard error and exits with 3; `both` writes to both streams;
/// `signal` does not exit by itself; `error` cannot be run.
fn echoCommand(gpa: std.mem.Allocator, io: std.Io, exec: Exec, dir: std.Io.Dir, args: []const []const u8) anyerror!Outcome {
    _ = exec;
    if (args.len > 0 and std.mem.eql(u8, args[0], "cat")) {
        return .{ .code = 0, .stdout = try dir.readFileAlloc(io, args[1], gpa, .unlimited) };
    }
    if (args.len > 0 and std.mem.eql(u8, args[0], "fail")) return .{ .code = 3, .stdout = "", .stderr = "boom\n" };
    if (args.len > 0 and std.mem.eql(u8, args[0], "both")) return .{ .code = 0, .stdout = "out\n", .stderr = "err\n" };
    if (args.len > 0 and std.mem.eql(u8, args[0], "crlf")) return .{ .code = 0, .stdout = "a\r\nb\r\n", .stderr = "c\r\n" };
    if (args.len > 0 and std.mem.eql(u8, args[0], "signal")) return .{ .code = null, .stdout = "" };
    if (args.len > 0 and std.mem.eql(u8, args[0], "error")) return error.FileNotFound;
    const joined = try std.mem.join(gpa, " ", args);
    return .{ .code = 0, .stdout = try std.fmt.allocPrint(gpa, "{s}\n", .{joined}) };
}

const stand_in: Exec = .{ .exe = "stand-in", .runFn = echoProgram, .commandFn = echoCommand };

/// The working directory the last `CWD` program of `echoProgram` ran in (a path), for the tests that look at it afterwards.
var seen_cwd: []const u8 = "";

/// A stand-in for the executable: the "output" of a program is its own source, and it exits
/// with 1 when the source starts with `FAIL`, with N when it starts with `EXIT N`, or does not exit by itself when it starts with `SIGNAL`.
///
/// `STDIN` で始まるソースは、標準入力の中身(無ければ `none`)を出す。`ARGS` で始まるものは、
/// 引数を空白で区切って出す(絶対パスは、`<` と基本名と `>` にする)。`CWD` で始まるものは、
/// 作業ディレクトリの中の項目の数を出し、`scratch.txt` を書く。`ERROR` で始まるものは、実行できない。
fn echoProgram(gpa: std.mem.Allocator, io: std.Io, exec: Exec, dir: std.Io.Dir, launch: Launch) anyerror!Outcome {
    _ = exec;
    const source = try dir.readFileAlloc(io, launch.rel_scm, gpa, .unlimited);
    if (std.mem.startsWith(u8, source, "ERROR")) return error.FileNotFound;
    if (std.mem.startsWith(u8, source, "STDIN")) {
        const text = if (launch.stdin) |p| try dir.readFileAlloc(io, p, gpa, .unlimited) else "none\n";
        return .{ .code = 0, .stdout = text };
    }
    if (std.mem.startsWith(u8, source, "ARGS")) {
        var shown_args: std.ArrayList([]const u8) = .empty;
        for (launch.args) |arg| {
            try shown_args.append(gpa, if (std.fs.path.isAbsolute(arg))
                try std.fmt.allocPrint(gpa, "<{s}>", .{std.fs.path.basename(arg)})
            else
                arg);
        }
        return .{ .code = 0, .stdout = try std.fmt.allocPrint(gpa, "{s}\n", .{try std.mem.join(gpa, " ", shown_args.items)}) };
    }
    if (std.mem.startsWith(u8, source, "CWD")) {
        var entries: usize = 0;
        var it = launch.cwd.iterate();
        while (try it.next(io)) |_| entries += 1;
        try launch.cwd.writeFile(io, .{ .sub_path = "scratch.txt", .data = "written by the program\n" });
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const n = try launch.cwd.realPath(io, &buf);
        seen_cwd = try std.heap.page_allocator.dupe(u8, buf[0..n]);
        return .{ .code = 0, .stdout = try std.fmt.allocPrint(gpa, "entries {d}\n", .{entries}) };
    }
    var code: ?u8 = 0;
    if (std.mem.startsWith(u8, source, "SIGNAL")) code = null;
    if (std.mem.startsWith(u8, source, "FAIL")) code = 1;
    if (std.mem.startsWith(u8, source, "EXIT ")) code = try std.fmt.parseInt(u8, std.mem.trimEnd(u8, source["EXIT ".len..], "\n"), 10);
    return .{ .code = code, .stdout = source };
}

/// Writes `files` into a new directory of documents and `libs` into a new directory of libraries,
/// runs them, and returns the counts and the report.
fn runForTestLibs(arena: std.mem.Allocator, files: []const TestFile, libs: []const TestFile) !TestRun {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    for (files) |f| {
        if (std.fs.path.dirname(f.path)) |d| try tmp.dir.createDirPath(std.testing.io, d);
        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = f.path, .data = f.data });
    }
    var lib_tmp = std.testing.tmpDir(.{ .iterate = true });
    defer lib_tmp.cleanup();
    for (libs) |f| {
        if (std.fs.path.dirname(f.path)) |d| try lib_tmp.dir.createDirPath(std.testing.io, d);
        try lib_tmp.dir.writeFile(std.testing.io, .{ .sub_path = f.path, .data = f.data });
    }
    var report: std.Io.Writer.Allocating = .init(arena);
    const counts = try run(arena, std.testing.io, tmp.dir, "manual", lib_tmp.dir, stand_in, &report.writer);
    // Why: walker のパスは、Windows では `\` で区切られる。報告の文字列を `/` で書いた
    // 期待と比べるので、区切りをそろえる(Windows の層2で、この比較だけが落ちた)。
    const written = try arena.dupe(u8, report.written());
    std.mem.replaceScalar(u8, written, '\\', '/');
    return .{ .counts = counts, .report = written };
}

/// The library and the index that most tests carry along, so that the index check passes.
const default_lib: TestFile = .{ .path = "t.sld", .data = "(define-library (scheme t) (import (sucheme core)) (export a b))\n" };
const default_index: TestFile = .{
    .path = "reference/scheme-t.md",
    .data = "# index\n\n| id | section | item |\n| --- | --- | --- |\n| `a` | 6.4 | |\n| `b` | 6.13.1 | |\n",
};

/// Like `runForTestLibs` with `default_lib`, and `default_index` added to the documents.
fn runForTest(arena: std.mem.Allocator, files: []const TestFile) !TestRun {
    return runForTestLibs(arena, try std.mem.concat(arena, TestFile, &.{ files, &.{default_index} }), &.{default_lib});
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
    // 補助のファイルも、直下にあれば、プログラムの一部である。名前のない拡張子だけのものは違う。
    try std.testing.expect(isProgramFile("programs/wc.in"));
    try std.testing.expect(isProgramFile("programs\\wc.args"));
    try std.testing.expect(!isProgramFile("programs/.in"));
    try std.testing.expect(!isProgramFile("programs/.args"));
    try std.testing.expect(!isProgramFile("programs/wc.files/a.in"));
}

test "the directory of auxiliary files and what is in it belong to the program of that name" {
    try std.testing.expectEqualStrings("wc", programFilesStem("programs/wc.files").?);
    try std.testing.expectEqualStrings("wc", programFilesStem("programs/wc.files/lib/a.sld").?);
    try std.testing.expectEqualStrings("wc", programFilesStem("programs\\wc.files\\a.txt").?);
    try std.testing.expect(programFilesStem("programs/.files") == null);
    try std.testing.expect(programFilesStem("programs/wc.txt") == null);
    try std.testing.expect(programFilesStem("programs/sub/wc.files") == null);
    try std.testing.expect(programFilesStem("other/wc.files") == null);
    try std.testing.expect(isInProgramFilesDir("programs/wc.files/a.txt"));
    try std.testing.expect(isInProgramFilesDir("programs\\wc.files\\lib\\a.sld"));
    // ディレクトリそのものは、中ではない。
    try std.testing.expect(!isInProgramFilesDir("programs/wc.files"));
    try std.testing.expect(!isInProgramFilesDir("programs/wc.scm"));
    try std.testing.expect(!isInProgramFilesDir("other/wc.files/a.txt"));
}

test "an args line becomes the arguments, with the program and the auxiliary directory put in" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const prog = "/m/programs/p.scm";
    const files = "/m/programs/p.files";
    // `.args` が無ければ、プログラムのパスだけである。
    const none = try buildArgs(a, null, prog, files);
    try std.testing.expectEqual(@as(usize, 1), none.args.len);
    try std.testing.expectEqualStrings(prog, none.args[0]);
    try std.testing.expect(!none.uses_files);
    // `-I` の後ろの補助ディレクトリと、プログラムへの引数。
    const lib = try buildArgs(a, "-I @files/lib @prog 3 -x\n", prog, files);
    try std.testing.expectEqual(@as(usize, 5), lib.args.len);
    try std.testing.expectEqualStrings("-I", lib.args[0]);
    try std.testing.expectEqualStrings("/m/programs/p.files/lib", lib.args[1]);
    try std.testing.expectEqualStrings(prog, lib.args[2]);
    try std.testing.expectEqualStrings("3", lib.args[3]);
    try std.testing.expectEqualStrings("-x", lib.args[4]);
    try std.testing.expect(lib.uses_files);
    // CRLF の行末と、続く空白も読める。補助のファイルを使わなければ、`uses_files` は偽である。
    const crlf = try buildArgs(a, "@prog a.txt  \r\n", prog, files);
    try std.testing.expectEqual(@as(usize, 2), crlf.args.len);
    try std.testing.expect(!crlf.uses_files);
    // 補助ディレクトリそのもの(`@files/` だけ)も指せる。
    const dirarg = try buildArgs(a, "@prog @files/", prog, files);
    try std.testing.expectEqualStrings("/m/programs/p.files/", dirarg.args[1]);
    try std.testing.expect(dirarg.uses_files);
}

test "an args line this tool cannot run as written is refused" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cases = [_]struct { text: []const u8, err: ArgsError }{
        .{ .text = "", .err = error.NoProgram },
        .{ .text = "-I @files/lib\n", .err = error.NoProgram },
        .{ .text = "@prog @prog\n", .err = error.ManyPrograms },
        .{ .text = "@prog\n@prog\n", .err = error.MoreThanOneLine },
        .{ .text = "@prog a\nb\n", .err = error.MoreThanOneLine },
        .{ .text = "@prog \"a b\"", .err = error.NotPlain },
        .{ .text = "@prog a|b", .err = error.NotPlain },
        .{ .text = "@prog $HOME", .err = error.NotPlain },
        .{ .text = "@prog\ta", .err = error.NotPlain },
        .{ .text = "@prog /etc/passwd", .err = error.NotPlain },
        .{ .text = "@prog ../x", .err = error.NotPlain },
        .{ .text = "@prog @files/../x", .err = error.NotPlain },
        .{ .text = "@prog @file/x", .err = error.UnknownPlaceholder },
        .{ .text = "@prog @progx", .err = error.UnknownPlaceholder },
        .{ .text = "@prog @files", .err = error.UnknownPlaceholder },
    };
    for (cases) |c| {
        try std.testing.expectError(c.err, buildArgs(a, c.text, "/p.scm", "/p.files"));
    }
}

test "an exit line at the end of an expected output gives the exit code and is not part of the output" {
    const plain = try splitExitMarker("a\nb\n");
    try std.testing.expectEqualStrings("a\nb\n", plain.stdout);
    try std.testing.expectEqual(@as(u8, 0), plain.code);
    const with_code = try splitExitMarker("a\n[exit 3]\n");
    try std.testing.expectEqualStrings("a\n", with_code.stdout);
    try std.testing.expectEqual(@as(u8, 3), with_code.code);
    // 標準出力が空で、終了コードだけを期待するときも、書ける。末尾の改行が無くてもよい。
    const alone = try splitExitMarker("[exit 255]");
    try std.testing.expectEqualStrings("", alone.stdout);
    try std.testing.expectEqual(@as(u8, 255), alone.code);
    const spaces = try splitExitMarker("x\n[exit 1]  \n");
    try std.testing.expectEqual(@as(u8, 1), spaces.code);
    // 最後の行でない `[exit N]` は、出力の一部である。
    const middle = try splitExitMarker("[exit 2]\nafter\n");
    try std.testing.expectEqualStrings("[exit 2]\nafter\n", middle.stdout);
    try std.testing.expectEqual(@as(u8, 0), middle.code);
    // `[exit` で始まるのに、形が違う最後の行は、誤りである。
    try std.testing.expectError(error.BadExitLine, splitExitMarker("a\n[exit]\n"));
    try std.testing.expectError(error.BadExitLine, splitExitMarker("a\n[exit 256]\n"));
    try std.testing.expectError(error.BadExitLine, splitExitMarker("a\n[exit x]\n"));
    try std.testing.expectError(error.BadExitLine, splitExitMarker("a\n[exit 1] more\n"));
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
    try std.testing.expectEqual(Counts{ .libraries = 1, .blocks = 3, .programs = 2, .passed = 6, .failed = 0 }, r.counts);
    try std.testing.expectEqual(@as(u8, 0), exitStatus(r.counts));
}

test "a run with no document, no block, no program, a failing block or a stray file fails" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cases = [_]struct { files: []const TestFile, says: []const u8, bare: bool = false }{
        // 索引の `.md` も文書なので、「文書が無い」ことは、索引を足さずに試す。
        .{ .files = &.{ prog_scm, prog_out }, .says = "check-examples: no `.md` file under manual\n", .bare = true },
        .{ .files = &.{ .{ .path = "a.md", .data = "# Only prose\n" }, prog_scm, prog_out }, .says = "check-examples: no `scheme` block was run\n" },
        .{ .files = &.{.{ .path = "a.md", .data = passing_doc }}, .says = "check-examples: no program (`.scm` and `.out` pair) under manual/programs/\n" },
        .{ .files = &.{ .{ .path = "a.md", .data = passing_doc }, prog_scm, prog_out, .{ .path = "x.scm", .data = "(car 1)\n" } }, .says = "manual/x.scm: not a `.md` file, so nothing here checks it\n" },
        .{ .files = &.{ .{ .path = "a.md", .data = passing_doc }, prog_scm, prog_out, .{ .path = "programs/x.txt", .data = "" } }, .says = "manual/programs/x.txt: not a `.md` file" },
        .{ .files = &.{ .{ .path = "a.md", .data = passing_doc }, prog_scm, prog_out, .{ .path = "programs/sub/y.scm", .data = "" } }, .says = "manual/programs/sub/y.scm: not a `.md` file" },
        .{ .files = &.{ .{ .path = "a.md", .data = "```scheme\n(+ 1 2)\n```\n\n```output\n4\n```\n" }, prog_scm, prog_out }, .says = "manual/a.md:1: the output differs\n" },
        .{ .files = &.{ .{ .path = "a.md", .data = "```lisp\n1\n```\n" }, prog_scm, prog_out }, .says = "manual/a.md:1: this fence names a kind other than" },
    };
    for (cases) |c| {
        const r = if (c.bare) try runForTestLibs(a, c.files, &.{default_lib}) else try runForTest(a, c.files);
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
        try std.testing.expectEqual(@as(usize, 0), r.counts.passed - r.counts.blocks - r.counts.libraries);
        try std.testing.expectEqual(@as(u8, 1), exitStatus(r.counts));
        try std.testing.expect(std.mem.indexOf(u8, r.report, c.says) != null);
    }
}

test "a program gets its arguments, its standard input and an empty working directory that is removed afterwards" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const r = try runForTest(arena.allocator(), &.{
        .{ .path = "a.md", .data = passing_doc },
        // 引数: `@prog` と `@files/` は絶対パスになり、ほかの語はそのまま渡る。
        .{ .path = "programs/a.scm", .data = "ARGS\n" },
        .{ .path = "programs/a.args", .data = "-I @files/lib @prog 3 -x\r\n" },
        .{ .path = "programs/a.files/lib/x.sld", .data = "" },
        .{ .path = "programs/a.out", .data = "-I <lib> <a.scm> 3 -x\n" },
        // 標準入力: `.in` の中身が渡り、無ければ空(ここでは `none`)である。
        .{ .path = "programs/b.scm", .data = "STDIN\n" },
        .{ .path = "programs/b.in", .data = "line one\nline two\n" },
        .{ .path = "programs/b.out", .data = "line one\nline two\n" },
        .{ .path = "programs/c.scm", .data = "STDIN\n" },
        .{ .path = "programs/c.out", .data = "none\n" },
        // 作業ディレクトリ: 空で渡り、プログラムが書いたファイルごと、実行のあとに消える。
        .{ .path = "programs/d.scm", .data = "CWD\n" },
        .{ .path = "programs/d.out", .data = "entries 0\n" },
    });
    try std.testing.expectEqualStrings("", r.report);
    try std.testing.expectEqual(Counts{ .libraries = 1, .blocks = 1, .programs = 4, .passed = 6, .failed = 0 }, r.counts);
    try std.testing.expect(seen_cwd.len != 0);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().openDir(std.testing.io, seen_cwd, .{}));
}

test "a program is run in a new working directory each time" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    // 前の実行が書いた `scratch.txt` が残っていれば、2つ目の `entries` は 1 になる。
    const r = try runForTest(arena.allocator(), &.{
        .{ .path = "a.md", .data = passing_doc },
        .{ .path = "programs/d1.scm", .data = "CWD\n" },
        .{ .path = "programs/d1.out", .data = "entries 0\n" },
        .{ .path = "programs/d2.scm", .data = "CWD\n" },
        .{ .path = "programs/d2.out", .data = "entries 0\n" },
    });
    try std.testing.expectEqualStrings("", r.report);
    try std.testing.expectEqual(@as(usize, 0), r.counts.failed);
}

test "an exit line of the expected output sets the exit code that is expected" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const doc: TestFile = .{ .path = "a.md", .data = passing_doc };
    const exit3: TestFile = .{ .path = "programs/p.scm", .data = "EXIT 3\n" };
    const ok = try runForTest(a, &.{ doc, exit3, .{ .path = "programs/p.out", .data = "EXIT 3\n[exit 3]\n" } });
    try std.testing.expectEqualStrings("", ok.report);
    try std.testing.expectEqual(@as(usize, 0), ok.counts.failed);
    const cases = [_]struct { out: []const u8, says: []const u8 }{
        .{ .out = "EXIT 3\n", .says = "manual/programs/p.scm: exit code 3, expected 0\n" },
        .{ .out = "EXIT 3\n[exit 4]\n", .says = "manual/programs/p.scm: exit code 3, expected 4\n" },
        .{ .out = "EXIT 3\n[exit x]\n", .says = "manual/programs/p.out: the last line starts with `[exit` but is not `[exit N]`" },
        // 終了コードが合っても、標準出力が違えば失敗である。
        .{ .out = "other\n[exit 3]\n", .says = "manual/programs/p.scm: the output differs\n  expected: other\n\n  got:      EXIT 3\n" },
    };
    for (cases) |c| {
        const r = try runForTest(a, &.{ doc, exit3, .{ .path = "programs/p.out", .data = c.out } });
        try std.testing.expectEqual(@as(usize, 1), r.counts.failed);
        try std.testing.expect(std.mem.indexOf(u8, r.report, c.says) != null);
    }
}

test "sidecar files without their program, an unused or missing auxiliary directory and a bad args line fail" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const doc: TestFile = .{ .path = "a.md", .data = passing_doc };
    const cases = [_]struct { files: []const TestFile, says: []const u8 }{
        .{ .files = &.{ doc, prog_scm, prog_out, .{ .path = "programs/q.in", .data = "x\n" } }, .says = "manual/programs/q: the `.scm` file of the pair is missing\n" },
        .{ .files = &.{ doc, prog_scm, prog_out, .{ .path = "programs/q.args", .data = "@prog\n" } }, .says = "manual/programs/q: the `.scm` file of the pair is missing\n" },
        .{ .files = &.{ doc, prog_scm, prog_out, .{ .path = "programs/q.files/x.txt", .data = "x\n" } }, .says = "manual/programs/q: the `.scm` file of the pair is missing\n" },
        .{ .files = &.{ doc, prog_scm, prog_out, .{ .path = "programs/p.files/x.txt", .data = "x\n" } }, .says = "manual/programs/p.files: no `.args` argument names it with `@files/`" },
        .{ .files = &.{ doc, prog_scm, prog_out, .{ .path = "programs/p.args", .data = "@prog\n" }, .{ .path = "programs/p.files/x.txt", .data = "x\n" } }, .says = "manual/programs/p.files: no `.args` argument names it" },
        .{ .files = &.{ doc, prog_scm, prog_out, .{ .path = "programs/p.args", .data = "@prog @files/x.txt\n" } }, .says = "manual/programs/p.args: it names `@files/`, but the directory p.files does not exist\n" },
        .{ .files = &.{ doc, prog_scm, prog_out, .{ .path = "programs/p.args", .data = "-I x\n" } }, .says = "manual/programs/p.args: it needs `@prog`" },
        .{ .files = &.{ doc, prog_scm, prog_out, .{ .path = "programs/p.args", .data = "@prog @prog\n" } }, .says = "manual/programs/p.args: it has `@prog` more than once\n" },
        .{ .files = &.{ doc, prog_scm, prog_out, .{ .path = "programs/p.args", .data = "@prog\n@prog\n" } }, .says = "manual/programs/p.args: it must be one line\n" },
        .{ .files = &.{ doc, prog_scm, prog_out, .{ .path = "programs/p.args", .data = "@prog $HOME\n" } }, .says = "manual/programs/p.args: an argument has a character a shell would read" },
        .{ .files = &.{ doc, prog_scm, prog_out, .{ .path = "programs/p.args", .data = "@prog @files/../x\n" } }, .says = "manual/programs/p.args: an argument has a character a shell would read" },
        .{ .files = &.{ doc, prog_scm, prog_out, .{ .path = "programs/p.args", .data = "@prog @other\n" } }, .says = "manual/programs/p.args: an argument starts with `@` but is neither" },
        // 実行できないプログラムも、失敗として数える。
        .{ .files = &.{ doc, .{ .path = "programs/p.scm", .data = "ERROR\n" }, .{ .path = "programs/p.out", .data = "ERROR\n" } }, .says = "manual/programs/p.scm: cannot be run (FileNotFound)\n" },
    };
    for (cases) |c| {
        const r = try runForTest(a, c.files);
        try std.testing.expectEqual(@as(usize, 1), r.counts.failed);
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
        // `examples/` の外へ出る引数。
        .{ .doc = "```console\n$ sucheme ../a.scm\n```\n", .line = 2 },
        .{ .doc = "```console\n$ sucheme lib/../../a.scm\n```\n", .line = 2 },
        .{ .doc = "```console\n$ sucheme /etc/hostname\n```\n", .line = 2 },
        .{ .doc = "```console\n$ sucheme -I /tmp a.scm\n```\n", .line = 2 },
        .{ .doc = "```console\n$ sucheme ..\n```\n", .line = 2 },
        // `$` だけの行は、コマンドの無い呼び出しである。
        .{ .doc = "```console\n$\n```\n", .line = 2 },
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

test "console output with CRLF line ends reads as its LF form" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const r = try checkForTest(arena.allocator(), "```console\n$ sucheme crlf\na\nb\nc\n```\n");
    try std.testing.expectEqualStrings("", r.report);
    try std.testing.expectEqual(Counts{ .blocks = 0, .commands = 1, .passed = 1, .failed = 0 }, r.counts);
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
    try std.testing.expectEqual(Counts{ .libraries = 1, .blocks = 1, .commands = 1, .programs = 1, .passed = 4, .failed = 0 }, ok.counts);
    // examples/ の外の同じ種類のファイルは、迷子である。
    const stray = try runForTest(a, &.{ console_doc, prog_scm, prog_out, .{ .path = "g/examples/in.scm", .data = "x" }, .{ .path = "g/other/in.scm", .data = "x" } });
    try std.testing.expect(std.mem.indexOf(u8, stray.report, "manual/g/other/in.scm: not a `.md` file") != null);
    // examples/ の下の `.md` は、入力でなく文書として検査する。
    const md = try runForTest(a, &.{ console_doc, prog_scm, prog_out, .{ .path = "g/examples/in.scm", .data = "x" }, .{ .path = "g/examples/n.md", .data = "```lisp\n1\n```\n" } });
    try std.testing.expect(std.mem.indexOf(u8, md.report, "manual/g/examples/n.md:1: this fence names a kind other than") != null);
}

test "dots and slashes inside an argument are fine, and an exit is read from how the process ended" {
    var p = try Parsed.of("```console\n$ sucheme -I lib sub/a.b.scm ./c.scm ..d ...\n```\n");
    defer p.deinit();
    try std.testing.expectEqual(@as(usize, 0), p.problems.len);
    try std.testing.expectEqual(@as(usize, 7), p.blocks[0].commands[0].args.len);

    try std.testing.expectEqual(@as(?u8, 0), exitCode(.{ .exited = 0 }));
    try std.testing.expectEqual(@as(?u8, 66), exitCode(.{ .exited = 66 }));
    try std.testing.expectEqual(@as(?u8, null), exitCode(.{ .signal = .SEGV }));
    try std.testing.expectEqual(@as(?u8, null), exitCode(.{ .stopped = .SEGV }));
    try std.testing.expectEqual(@as(?u8, null), exitCode(.{ .unknown = 0 }));
}

test "trailing spaces of an expected line are kept, and the exit line is read without them" {
    var p = try Parsed.of("```console\n$ sucheme a\nx  \n[exit 2]  \n```\n");
    defer p.deinit();
    try std.testing.expectEqual(@as(usize, 0), p.problems.len);
    try std.testing.expectEqualStrings("x  ", p.blocks[0].commands[0].expected);
    try std.testing.expectEqual(@as(u8, 2), p.blocks[0].commands[0].code);
}

/// What `parseLibrary` reads from `src`, in an arena the caller frees.
fn libraryOf(arena: std.mem.Allocator, src: []const u8) (error{OutOfMemory} || LibraryError)!Library {
    return parseLibrary(arena, src);
}

test "a library gives its name and the identifiers of all its export declarations" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const l = try libraryOf(arena.allocator(),
        \\;; a comment with (parentheses and (export x)) and "quotes
        \\(define-library (scheme base) ; (export y)
        \\  (import (sucheme core))
        \\  (export car cdr
        \\          ;; (export z)
        \\          + ... =>)
        \\  (export set!)
        \\  (begin (define (f) (export w) "a ) b" #\) #\( )))
        \\
    );
    try std.testing.expectEqualStrings("scheme base", l.name);
    try std.testing.expectEqual(@as(usize, 6), l.exports.len);
    for ([_][]const u8{ "car", "cdr", "+", "...", "=>", "set!" }, l.exports) |want, got| try std.testing.expectEqualStrings(want, got);
}

test "an export declaration may be empty, and a block comment hides what it holds" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const l = try libraryOf(arena.allocator(), "#| (export a |# (define-library (x) (export) #| ) |#)\n");
    try std.testing.expectEqualStrings("x", l.name);
    try std.testing.expectEqual(@as(usize, 0), l.exports.len);
}

test "a file that is not read as a library with exports is refused" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectError(error.NoLibrary, libraryOf(a, ""));
    try std.testing.expectError(error.NoLibrary, libraryOf(a, "(define x 1)\n"));
    try std.testing.expectError(error.NoLibrary, libraryOf(a, "(define-library () (export a))\n"));
    try std.testing.expectError(error.NoLibrary, libraryOf(a, "(define-library x (export a))\n"));
    try std.testing.expectError(error.NoExport, libraryOf(a, "(define-library (x) (import (y)))\n"));
    // `(export` は、define-library の直下にあるものだけを読む。
    try std.testing.expectError(error.NoExport, libraryOf(a, "(define-library (x) (begin (export a)))\n"));
    try std.testing.expectError(error.NonSymbolExport, libraryOf(a, "(define-library (x) (export a (rename b c)))\n"));
    // `cond-expand` の中の `export` は、条件を読まないので断る(輸出を黙って読み飛ばさない)。
    try std.testing.expectError(error.CondExpand, libraryOf(a, "(define-library (x) (export a) (cond-expand (sucheme (export b))))\n"));
    try std.testing.expectError(error.CondExpand, libraryOf(a, "(define-library (x) (cond-expand (else)) (export a))\n"));
    // 本体の中の `cond-expand` は、輸出に関わらない。
    _ = try libraryOf(a, "(define-library (x) (export a) (begin (cond-expand (else (define a 1)))))\n");
    try std.testing.expectError(error.Unbalanced, libraryOf(a, "(define-library (x) (export a)\n"));
    try std.testing.expectError(error.Unbalanced, libraryOf(a, "(define-library (x) (export a\n"));
}

test "a section number is one to three groups of digits" {
    for ([_][]const u8{ "6", "6.4", "6.13.1", "4.2.9", "10" }) |s| try std.testing.expect(isSectionNumber(s));
    for ([_][]const u8{ "", ".", "6.", ".6", "6..4", "6.4.1.1", "a", "6.x", "6 4", " 6" }) |s| try std.testing.expect(!isSectionNumber(s));
}

test "a table separator is a row of pipes, dashes, colons and spaces with a dash run" {
    try std.testing.expect(isTableSeparator("| --- | --- |"));
    try std.testing.expect(isTableSeparator("|---|:---:|"));
    try std.testing.expect(!isTableSeparator("| id | section |"));
    try std.testing.expect(!isTableSeparator("--- | ---"));
    try std.testing.expect(!isTableSeparator("| -- | -- |"));
    try std.testing.expect(!isTableSeparator(""));
}

test "an index gives the rows after the separator, whatever the lines before it say" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var problems: std.ArrayList(Problem) = .empty;
    const rows = try parseIndex(arena.allocator(),
        \\# Title
        \\
        \\| `fake` | 1 | |
        \\| id | section | item |
        \\| --- | --- | --- |
        \\| `car` | 6.4 | |
        \\| `...` | 4.3.2 | [x](y.md) |
        \\
        \\prose
        \\
    , &problems);
    try std.testing.expectEqual(@as(usize, 0), problems.items.len);
    try std.testing.expectEqual(@as(usize, 2), rows.len);
    try std.testing.expectEqualStrings("car", rows[0].ident);
    try std.testing.expectEqualStrings("6.4", rows[0].section);
    try std.testing.expectEqual(@as(usize, 6), rows[0].line);
    try std.testing.expectEqualStrings("...", rows[1].ident);
}

test "an index row this tool cannot read is reported with its line" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const head = "| id | s | i |\n| --- | --- | --- |\n";
    const cases = [_]struct { doc: []const u8, line: usize }{
        // 行の形。
        .{ .doc = head ++ "| `a` | 6.4 |\n", .line = 3 },
        .{ .doc = head ++ "| `a` | 6.4 | | |\n", .line = 3 },
        .{ .doc = head ++ "| `a` | 6.4\n", .line = 3 },
        // 識別子のセル。
        .{ .doc = head ++ "| a | 6.4 | |\n", .line = 3 },
        .{ .doc = head ++ "| `` | 6.4 | |\n", .line = 3 },
        .{ .doc = head ++ "| `a b` | 6.4 | |\n", .line = 3 },
        .{ .doc = head ++ "| `a` `b` | 6.4 | |\n", .line = 3 },
        // 節番号のセル。
        .{ .doc = head ++ "| `a` | | |\n", .line = 3 },
        .{ .doc = head ++ "| `a` | 6.x | |\n", .line = 3 },
        .{ .doc = head ++ "| `a` | 6.4.1.1 | |\n", .line = 3 },
        // 表のあとの行。
        .{ .doc = head ++ "| `a` | 6.4 | |\n\n| `b` | 6.4 | |\n", .line = 5 },
        .{ .doc = head ++ "| `a` | 6.4 | |\nprose\n| `b` | 6.4 | |\n", .line = 5 },
        // 表が無い。
        .{ .doc = "# only prose\n", .line = 1 },
        .{ .doc = "| id | s | i |\n| `a` | 6.4 | |\n", .line = 1 },
    };
    for (cases) |c| {
        var problems: std.ArrayList(Problem) = .empty;
        _ = try parseIndex(arena.allocator(), c.doc, &problems);
        try std.testing.expect(problems.items.len >= 1);
        try std.testing.expectEqual(c.line, problems.items[0].line);
    }
}

test "an index file is named scheme-*.md directly under reference, under either separator" {
    try std.testing.expect(isIndexFile("reference/scheme-base.md"));
    try std.testing.expect(isIndexFile("reference\\scheme-base.md"));
    try std.testing.expect(isIndexFile("reference/scheme-r5rs.md"));
    try std.testing.expect(!isIndexFile("reference/README.md"));
    try std.testing.expect(!isIndexFile("reference/scheme-base.txt"));
    try std.testing.expect(!isIndexFile("reference/scheme-.md"));
    try std.testing.expect(!isIndexFile("reference/sub/scheme-base.md"));
    try std.testing.expect(!isIndexFile("reference\\sub\\scheme-base.md"));
    try std.testing.expect(!isIndexFile("other/scheme-base.md"));
    try std.testing.expect(!isIndexFile("scheme-base.md"));
}

/// An index document with `rows` as the rows of its table.
fn indexDoc(comptime rows: []const u8) []const u8 {
    return "# index\n\n| id | section | item |\n| --- | --- | --- |\n" ++ rows;
}

test "an index that matches the exports in both directions passes" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const r = try runForTestLibs(arena.allocator(), &.{
        .{ .path = "a.md", .data = passing_doc },
        prog_scm,
        prog_out,
        .{ .path = "reference/scheme-t.md", .data = indexDoc("| `b` | 6 | |\n| `a` | 6.4 | |\n") },
    }, &.{default_lib});
    try std.testing.expectEqualStrings("", r.report);
    try std.testing.expectEqual(Counts{ .libraries = 1, .blocks = 1, .programs = 1, .passed = 3, .failed = 0 }, r.counts);
}

test "an index that differs from the exports fails, naming the identifier and the side" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cases = [_]struct { index: []const u8, says: []const u8 }{
        // 輸出されるのに行が無い。
        .{ .index = "| `a` | 6.4 | |\n", .says = "manual/reference/scheme-t.md: `b` is exported by (scheme t) but has no row in the index\n" },
        .{ .index = "| `b` | 6.4 | |\n", .says = "manual/reference/scheme-t.md: `a` is exported by (scheme t) but has no row in the index\n" },
        .{ .index = "", .says = "`a` is exported by (scheme t) but has no row" },
        // 行があるのに輸出されない。
        .{ .index = "| `a` | 6.4 | |\n| `b` | 6.4 | |\n| `c` | 6.4 | |\n", .says = "manual/reference/scheme-t.md:7: `c` is not exported by (scheme t)\n" },
        // 綴りの違い(大文字小文字、前後の空白は無視して、中身は同じでなければならない)。
        .{ .index = "| `a` | 6.4 | |\n| `B` | 6.4 | |\n", .says = "`B` is not exported" },
        // 同じ識別子の2行目。
        .{ .index = "| `a` | 6.4 | |\n| `b` | 6.4 | |\n| `a` | 6.5 | |\n", .says = "manual/reference/scheme-t.md:7: `a` is listed twice (first at line 5)\n" },
        // 節番号の誤り。
        .{ .index = "| `a` | 6.4 | |\n| `b` | six | |\n", .says = "manual/reference/scheme-t.md:6: the second cell of this row must be a section number" },
        // 行が読めない。
        .{ .index = "| `a` | 6.4 | |\n| `b` | 6.4 |\n", .says = "manual/reference/scheme-t.md:6: this table row must have the form" },
    };
    inline for (cases) |c| {
        const r = try runForTestLibs(a, &.{
            .{ .path = "a.md", .data = passing_doc },
            prog_scm,
            prog_out,
            .{ .path = "reference/scheme-t.md", .data = indexDoc(c.index) },
        }, &.{default_lib});
        try std.testing.expect(r.counts.failed >= 1);
        // 食い違う索引は、成功として数えない(ブロックとプログラムの 2 つだけが成功)。
        try std.testing.expectEqual(@as(usize, 2), r.counts.passed);
        try std.testing.expectEqual(@as(u8, 1), exitStatus(r.counts));
        try std.testing.expect(std.mem.indexOf(u8, r.report, c.says) != null);
    }
}

test "a library without an index, an index of no library, and an unreadable library fail" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const base = [_]TestFile{ .{ .path = "a.md", .data = passing_doc }, prog_scm, prog_out };
    const index: TestFile = .{ .path = "reference/scheme-t.md", .data = indexDoc("| `a` | 6.4 | |\n| `b` | 6.4 | |\n") };
    const other_lib: TestFile = .{ .path = "u.sld", .data = "(define-library (scheme u) (export))\n" };
    const cases = [_]struct { files: []const TestFile, libs: []const TestFile, says: []const u8 }{
        // ライブラリの索引が無い。
        .{ .files = &base, .libs = &.{default_lib}, .says = "manual/reference/scheme-t.md: no index of (scheme t) (FileNotFound)\n" },
        // 2つ目のライブラリの索引だけが無い。
        .{ .files = &(base ++ [_]TestFile{index}), .libs = &.{ default_lib, other_lib }, .says = "manual/reference/scheme-u.md: no index of (scheme u)" },
        // ライブラリの無い索引。名前を取り違えた綴りも、ここで見つかる。
        .{ .files = &(base ++ [_]TestFile{ index, .{ .path = "reference/scheme-x.md", .data = indexDoc("") } }), .libs = &.{default_lib}, .says = "manual/reference/scheme-x.md: the index of no library under lib/scheme\n" },
        // ライブラリが無い。
        .{ .files = &(base ++ [_]TestFile{index}), .libs = &.{}, .says = "check-examples: no `.sld` file under lib/scheme, so no index was compared with the exports\n" },
        // `.sld` でないファイルと、サブディレクトリの中の `.sld` は、ライブラリでない。
        .{ .files = &(base ++ [_]TestFile{index}), .libs = &.{ .{ .path = "t.txt", .data = default_lib.data }, .{ .path = "sub/t.sld", .data = default_lib.data } }, .says = "no `.sld` file under lib/scheme" },
        // 読めないライブラリ。
        .{ .files = &(base ++ [_]TestFile{index}), .libs = &.{ default_lib, .{ .path = "v.sld", .data = "(define x 1)\n" } }, .says = "lib/scheme/v.sld: not of the form `(define-library (name) ...)`\n" },
        .{ .files = &(base ++ [_]TestFile{index}), .libs = &.{ default_lib, .{ .path = "v.sld", .data = "(define-library (v) (import (w)))\n" } }, .says = "lib/scheme/v.sld: no `(export ...)` declaration\n" },
        .{ .files = &(base ++ [_]TestFile{index}), .libs = &.{ default_lib, .{ .path = "v.sld", .data = "(define-library (v) (export (rename a b)))\n" } }, .says = "lib/scheme/v.sld: an `(export ...)` declaration has an element that is not an identifier" },
        .{ .files = &(base ++ [_]TestFile{index}), .libs = &.{ default_lib, .{ .path = "v.sld", .data = "(define-library (v) (export a\n" } }, .says = "lib/scheme/v.sld: the parentheses do not balance\n" },
        .{ .files = &(base ++ [_]TestFile{index}), .libs = &.{ default_lib, .{ .path = "v.sld", .data = "(define-library (v) (export a)\n" } }, .says = "lib/scheme/v.sld: the parentheses do not balance\n" },
        .{ .files = &(base ++ [_]TestFile{index}), .libs = &.{ default_lib, .{ .path = "v.sld", .data = "(define-library (v) (export a) (cond-expand (x (export b))))\n" } }, .says = "lib/scheme/v.sld: a `cond-expand` declaration" },
    };
    for (cases) |c| {
        const r = try runForTestLibs(a, c.files, c.libs);
        try std.testing.expect(r.counts.failed >= 1);
        try std.testing.expectEqual(@as(u8, 1), exitStatus(r.counts));
        try std.testing.expect(std.mem.indexOf(u8, r.report, c.says) != null);
    }
}

test "a missing library directory fails, and the documents are still checked" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "a.md", .data = "```scheme\n(+ 1 2)\n```\n\n```output\n4\n```\n" });
    var report: std.Io.Writer.Allocating = .init(a);
    const counts = try run(a, std.testing.io, tmp.dir, "manual", null, stand_in, &report.writer);
    try std.testing.expect(std.mem.indexOf(u8, report.written(), "no library directory lib/scheme") != null);
    // 文書のブロックの失敗も数える(ライブラリの置き場が無いことで、検査が止まらない)。
    try std.testing.expect(std.mem.indexOf(u8, report.written(), "a.md:1: the output differs") != null);
    try std.testing.expectEqual(@as(u8, 1), exitStatus(counts));
}

test "the library of one file is counted once, and every library is compared" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const r = try runForTestLibs(arena.allocator(), &.{
        .{ .path = "a.md", .data = passing_doc },
        prog_scm,
        prog_out,
        default_index,
        .{ .path = "reference/scheme-u.md", .data = indexDoc("") },
    }, &.{ default_lib, .{ .path = "u.sld", .data = "(define-library (scheme u) (export))\n" } });
    try std.testing.expectEqualStrings("", r.report);
    try std.testing.expectEqual(@as(usize, 2), r.counts.libraries);
    try std.testing.expectEqual(@as(usize, 4), r.counts.passed);
}
