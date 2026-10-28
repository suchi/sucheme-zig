//! Native entry point.
//!
//! この doc コメントがコマンドラインと終了ステータスの契約である。
//! AGENTS.md と段階の計画書は、これを書き写さずに参照する。
//!
//! | 引数 | 振る舞い | 終了ステータス |
//! | --- | --- | --- |
//! | `--version` | 名前とバージョンを stdout に出す | 0 |
//! | `--help`, `-h` | 使い方を stdout に出す | 0 |
//! | 未知のオプション(2文字以上で `-` から始まるもの) | stderr にその名前を出す | 64 |
//! | `-I` が最後の引数で、ディレクトリが続かない | stderr にそのオプションの名前を出す | 64 |
//! | なし、または `-I <dir>` だけ(繰り返せる) | stdin が尽きるまで REPL を走らせる | 0 |
//! | `<file>`(`-I <dir>` が前にあってもよい) | ファイルのプログラムを最後まで実行する | 0 |
//! | 同上で、実行時エラーが起きた | stderr に `error: ` と説明を出して、そこで止める | 1 |
//! | 同上で、ファイルを開けない・読めない・大きすぎる | stderr に `cannot read <file>: ` と理由を出す | 66 |
//! | `<file>` の後ろに引数が続く | stderr に説明を出す(プログラムへの引数は段階5) | 64 |
//! | `-` だけ | オプションでなく名前として扱う。標準入力のプログラムは未実装と伝える | 69 |
//!
//! 要求を決める最初の引数が優先される。このため `--version --bogus` はバージョンを
//! 出し、`--bogus --version` は未知のオプションとしてその名前を出す。未知の
//! オプションも要求を決める。それ以降の引数は調べない。
//!
//! `-I <dir>` は、ライブラリのファイルの探索ルートを足す。`import` が名指すライブラリは、
//! 登録表に無ければ、探索ルートの配下の `foo/bar.sld`(`(foo bar)` の場合)から読まれる。
//! 探索ルートは、作業ディレクトリが先頭で、`-I` の指定が書いた順に続く。ファイルは、
//! 先に持っているルートのものが使われる。`-I` の次の引数は、`-` で始まっていても
//! ディレクトリの名前である。`-I<dir>` の続けた形は無く、未知のオプションになる。
//! 開けないルートは、何も持たないものとして読み飛ばす。環境変数は読まない。
//! ルートの配下のリンクは辿らない。ルートそのものはリンクでもよい。
//!
//! ファイルのプログラムは、REPL と同じ初期環境(`(scheme base)`)で、先頭から1つずつ
//! 評価する。R7RS 5.1 のプログラムは `import` で始まるが、始まらなくてもよい。式の値は
//! 出力しない。出力の手段(`display`)は段階5で入る。標準ライブラリのファイルは `-I` の
//! 探索ルートから読まれる(作業ディレクトリが先頭で、プログラムのファイルのあるディレクトリは
//! 足されない)。ファイルの大きさの上限は 1 MiB(`max_program_bytes`)で、
//! UTF-8 でなければ実行時エラーである。
//!
//! 診断は stderr に出し、この段階で応えられない要求は非ゼロで終了する。
//! `sucheme prog.scm && echo ok` が、プログラムを実行しないまま ok を出すことを
//! 防ぐためである。
//!
//! REPL は、プロンプト `> ` と各結果を stdout に、エラーを stderr に
//! `error: ` と `unbound variable: foo` のようなメッセージとして書く。エラーが
//! 終わらせるのはその式の評価であり、REPL ではない。`;` から行末までは行コメント
//! で、コメントだけの行は何も出力しない。式が複数の値を返したときは、1行に1つずつ書く。
//! 0個なら何も書かず、未規定値の要素も、最上位の未規定値と同じく書かない。
//!
//! 閉じていない式(リストやベクタの途中、`'` の直後、ドットの直後、閉じていない
//! 文字列)で終わる行は、継続行になる(ADR-0014)。継続行のプロンプトは
//! `... ` で、次の行が、保留している入力の続きとして足される。足すとき改行を
//! 戻すので、複数行の文字列リテラルは改行を含む。式が閉じたところで、保留の全体を
//! 評価する。複数の式を含む行は、最後の式が閉じるまで評価されない。閉じた先頭の
//! 式の出力も、そのときまで遅れる。継続を取り消す手段は無い。
//!
//! 構文エラー(`)` だけの行、`(a . )`、`#z`)は、続きを足しても直らないので、
//! 継続行にならずにその行で報告される。
//!
//! 行がエスケープや文字の途中で終わっても、継続行にならないことがある。REPL は
//! 保留に必ず改行を足すので、その改行がエスケープや文字の一部として読まれるからである。
//! 最上位の行末の `#\` は、改行文字 `#\newline` になる(R7RS 7.1.1 の
//! `#\<any character>` は改行を許す)。文字列の行末の `\` と `\x41` は、`\` + 改行、
//! `\x41` + 改行として読まれて、`error: invalid escape in string` になる。リーダは
//! 文字列の行継続 `\<行末>` をまだ読めない。
//!
//! 保留の合計は、改行を含めて 65536 バイト(`max_line`)までである。超えたら
//! `error: the input does not fit in 65536 bytes, newline included` を報告して、
//! 保留を捨てる。捨てた式の残りの行は新しい入力として読まれる。その中で完結した
//! 断片は、そのまま評価される(`set!` や `define` の副作用も起きる)。閉じていない
//! 断片は継続行になり、構文エラーの断片はエラーを報告する。上限を超えさせた行
//! そのものも、丸ごと捨てられる。その行に、保留が閉じたあとの新しい入力になる
//! はずだった部分があっても失われる(保留が上限の直前のとき、行 `) 7` は
//! `)` で保留を閉じ、`7` を新しい入力にするはずだが、行ごと捨てられて `7` は評価されない)。
//! 1行が `max_line` に収まらないときも、報告して読み飛ばし、保留を捨てる。
//!
//! 入力が尽きたとき、保留が残っていれば `error: unexpected end of input` を
//! stderr に書いて終わる。保留が無ければ何も書かない。どちらの場合も、
//! プロンプトの行を終わらせる改行を stdout に書く。
//!
//! エラーのあとも終了ステータスは 0 のままである。REPL は入力の残りを読み進めた
//! からである。入力が尽きたときの `unexpected end of input` も同じである。

const std = @import("std");
const sucheme = @import("sucheme");

/// What the command line asked for.
pub const Request = union(enum) {
    version,
    help,
    repl,
    /// Run the program in the file named by the argument at this index.
    run_file: usize,
    /// Arguments follow the name of the program, which nothing can read yet.
    program_arguments,
    /// A valid request this stage cannot serve yet.
    not_implemented,
    /// An option this program does not know.
    ///
    /// 診断がその名前を出せるように運ぶ。「未実装」と「打ち間違い」は別の
    /// 失敗であり、1つの状態では区別できない。
    unknown_option: []const u8,
    /// An option that needs a directory after it and has none.
    missing_argument: []const u8,
};

/// Entry layer.
///
/// ここで確保するものは、docs/design/architecture.md の計上の不変条件の対象外である。
/// アリーナが持つのは引数ベクタと出力バッファで、どちらも起動と終了にしか要らない。
/// Scheme の値はここでは確保しない。REPL は `sucheme` に、1行の評価中に要るものの
/// ための行ごとのアリーナを渡す。また `Interpreter` には、プログラムのオブジェクト
/// (ペア、クロージャ、呼び出しのフレーム、継続。コレクタが解放し、`Options.limit`
/// の上限内に収まる)を汎用アロケータから確保させ、シンボル・定義・コードのための
/// 専用のアリーナも持たせる。アリーナの中身はセッションが終わるまで解放されない。
pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    var out_buf: [512]u8 = undefined;
    var err_buf: [512]u8 = undefined;
    // 既定の位置指定モードでなくストリーミングを使う。位置指定モードは
    // オフセット 0 から始まるので、`sucheme --version >> log` の先頭を
    // 上書きしてしまう。

    var stdout = std.Io.File.Writer.initStreaming(.stdout(), io, &out_buf);
    var stderr = std.Io.File.Writer.initStreaming(.stderr(), io, &err_buf);
    const out = &stdout.interface;
    const err = &stderr.interface;

    // 診断は stderr に出し、終了ステータスは非ゼロにする。`sucheme prog.scm &&
    // echo ok` が、プログラムを実行しないまま ok を出してはならない。
    // `args` は空になりうる。POSIX は argc = 0 の execve を許す。その場合
    // `args[1..]` は境界違反のパニックになり、上の契約が「なし」に約束する
    // 終了にならない。
    const rest = if (args.len > 1) args[1..] else &[_][]const u8{};
    switch (classify(rest)) {
        .version => {
            try out.print("{s} {s}\n", .{ sucheme.name, sucheme.version });
            try out.flush();
        },
        .help => {
            try out.print(
                "{s} {s}\n\nUsage: {s} [--version] [--help|-h] [-I <dir>]... [<file>]\n\n" ++
                    "With no argument, reads expressions from stdin and prints their values.\n" ++
                    "With a file, runs the program in it and prints nothing but errors.\n" ++
                    "-I <dir> adds a directory to search for the files of libraries; the working\n" ++
                    "directory is searched first.\n" ++
                    "Only the core of the language is bound for now; see docs/roadmap.md.\n",
                .{ sucheme.name, sucheme.version, sucheme.name },
            );
            try out.flush();
        },
        .repl => {
            var in_buf: [max_line]u8 = undefined;
            var stdin = std.Io.File.Reader.initStreaming(.stdin(), io, &in_buf);
            const roots = try searchRoots(init.arena.allocator(), rest);
            // Why: `init.gpa` は Debug と ReleaseSafe で `SafeAllocator` になり、確保ごとに
            // `mmap` する。ヒープの掃引で解放すると領域が断片化し、`vm.max_map_count`(Linux の
            // 既定は 65530)を超えて `munmap` が `ENOMEM` を返す。標準ライブラリの `munmap` は
            // それを `unreachable` として扱うので、大きなリストを複数リストの `map` に渡すだけで
            // 異常終了した(tests/cli-slow/multi-list-map.scm)。上限はヒープの `Options.limit` が
            // 見るので、ここでは確保の速さと断片化に強い `smp_allocator` を使う。
            // 代償として、Debug でも二重解放や範囲外の検出と、終了時のリーク検査は失う
            // (単体テストは `std.testing.allocator` のままなので、リーク検査は残る)。
            // `smp_allocator` は複数スレッドのターゲットだけで使える。WASI のような単一
            // スレッドのターゲットは、この実行ファイルの対象ではない(docs/adr/0009)。
            try repl(std.heap.smp_allocator, .{ .io = io, .roots = roots }, &stdin.interface, out, err);
        },
        .run_file => |index| {
            const roots = try searchRoots(init.arena.allocator(), rest[0..index]);
            const status = try runFile(std.heap.smp_allocator, .{ .io = io, .roots = roots }, rest[index], out, err);
            if (status != 0) std.process.exit(status);
        },
        .program_arguments => {
            try err.print(
                "{s}: arguments for the program are not supported yet.\n" ++
                    "Run with --help for the options available now.\n",
                .{sucheme.name},
            );
            try err.flush();
            std.process.exit(exit_usage);
        },
        .not_implemented => {
            try err.print(
                "{s}: reading a program from stdin is not implemented yet.\n" ++
                    "Run with --help for the options available now.\n",
                .{sucheme.name},
            );
            try err.flush();
            std.process.exit(exit_not_implemented);
        },
        .missing_argument => |opt| {
            try err.print("{s}: option {s} needs a directory\n", .{ sucheme.name, opt });
            try err.print("Run with --help for the options available now.\n", .{});
            try err.flush();
            std.process.exit(exit_usage);
        },
        .unknown_option => |opt| {
            try err.print("{s}: unknown option {s}\n", .{ sucheme.name, opt });
            try err.print("Run with --help for the options available now.\n", .{});
            try err.flush();
            std.process.exit(exit_usage);
        },
    }
}

/// Exit status for a request this stage cannot serve.
pub const exit_not_implemented: u8 = 69;

/// Exit status for a program that stopped with an error.
pub const exit_runtime_error: u8 = 1;

/// Exit status for a program file that cannot be read.
///
/// 66 は sysexits.h の EX_NOINPUT である。
pub const exit_no_input: u8 = 66;

/// Exit status for a command line this program cannot parse.
///
/// 64 は sysexits.h の EX_USAGE で、ここで慣習に最も近いものである。
pub const exit_usage: u8 = 64;

/// The option that adds a directory to search for the files of libraries.
pub const include_option = "-I";

/// Classifies the arguments after the program name.
pub fn classify(args: []const []const u8) Request {
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--version")) return .version;
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) return .help;
        if (std.mem.eql(u8, arg, include_option)) {
            // 次の引数は、`-` で始まっていても、ディレクトリの名前である。
            if (i + 1 == args.len) return .{ .missing_argument = arg };
            i += 1;
            continue;
        }
        // 先頭が `-` で一致しないものは、ファイル名でなく打ち間違いである。
        if (arg.len > 1 and arg[0] == '-') return .{ .unknown_option = arg };
        // `-` だけは、慣習では標準入力のプログラムを指す。まだ応えられない。
        if (std.mem.eql(u8, arg, "-")) return .not_implemented;
        // 最初の名前がプログラムのファイルで、その後ろは、プログラムへの引数である。
        // 読む手段(`command-line`)が段階5で入るまで、黙って捨てずに断る。
        if (i + 1 < args.len) return .program_arguments;
        return .{ .run_file = i };
    }
    return .repl;
}

/// The directories the files of libraries are searched in: the working directory,
/// then each `-I` of `args`, in order.
/// `args` は、`classify` が REPL と判定したもの、またはファイルの実行と判定したときのファイル名の前までである。
pub fn searchRoots(arena: std.mem.Allocator, args: []const []const u8) error{OutOfMemory}![]const []const u8 {
    var roots: std.ArrayList([]const u8) = .empty;
    try roots.append(arena, ".");
    var i: usize = 0;
    while (i + 1 < args.len) : (i += 1) {
        if (!std.mem.eql(u8, args[i], include_option)) continue;
        i += 1;
        try roots.append(arena, args[i]);
    }
    return roots.items;
}

/// The size of the REPL's line buffer, newline included.
///
/// 収まらない行は、報告してから読み飛ばす。継続行で保留する入力の合計の上限も、
/// これと同じ値である。
pub const max_line = 64 * 1024;

/// The prompt for the first line of an expression.
pub const prompt = "> ";

/// The prompt for the lines that follow while an expression is open.
pub const continuation_prompt = "... ";

/// Reads lines from `in` until it ends, and evaluates and prints each expression.
///
/// 閉じていない式の行は、`sucheme.isIncomplete` が偽になるまで保留に足して
/// 続きを読み、完結したところで評価する。各回には、評価中に要るものためのまっさらな
/// アリーナを使う。リーダが作るものと定義が保持するものはそこに入らず、
/// インタプリタの中でセッションの終わりまで生きる。
pub fn repl(gpa: std.mem.Allocator, files: ?sucheme.resolve.Files, in: *std.Io.Reader, out: *std.Io.Writer, err: *std.Io.Writer) !void {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var interp: sucheme.Interpreter = undefined;
    try interp.initWithFiles(gpa, .{}, files);
    defer interp.deinit();
    // 継続行の保留。エントリ層は確保を起動と終了に限るので、固定長にする。
    var pending: [max_line]u8 = undefined;
    var kept: usize = 0;
    while (true) {
        try out.writeAll(if (kept == 0) prompt else continuation_prompt);
        try out.flush();
        const line = in.takeDelimiter('\n') catch |e| switch (e) {
            error.StreamTooLong => {
                try err.print("error: the line does not fit in {d} bytes, newline included\n", .{max_line});
                try err.flush();
                // 続きを読んでも、保留していた式の残りが分からない。保留も捨てる。
                kept = 0;
                _ = in.discardDelimiterInclusive('\n') catch |d| switch (d) {
                    error.EndOfStream => break,
                    error.ReadFailed => return d,
                };
                continue;
            },
            error.ReadFailed => return e,
        } orelse break;
        // `takeDelimiter` は改行を落とす。複数行の文字列リテラルが改行を含むように戻す。
        if (kept + line.len + 1 > max_line) {
            try err.print("error: the input does not fit in {d} bytes, newline included\n", .{max_line});
            try err.flush();
            kept = 0;
            continue;
        }
        @memcpy(pending[kept..][0..line.len], line);
        pending[kept + line.len] = '\n';
        kept += line.len + 1;
        // 足すたびに保留の全体を読み直す。費用は上限の2乗に抑えられる。
        if (try sucheme.isIncomplete(gpa, pending[0..kept])) continue;
        _ = arena.reset(.retain_capacity);
        interp.evalPrint(arena.allocator(), pending[0..kept], out) catch |e| switch (e) {
            error.WriteFailed => return e,
            else => {
                // エラーより前に書いた結果を先に出す。端末で2つのストリームの
                // 順序が保たれるようにするためである。
                try out.flush();
                try err.print("error: {s}\n", .{interp.diagnostic()});
                try err.flush();
            },
        };
        kept = 0;
    }
    // プロンプトの行を終わらせる。シェルのプロンプトがその行に続かないようにするためである。
    try out.writeAll("\n");
    try out.flush();
    // 入力が尽きたとき保留が残っていれば、その式はもう閉じられない。
    // 終了ステータスは変えない。エラーで終わったのは、REPL でなくその式である。
    if (kept != 0) {
        try err.writeAll("error: unexpected end of input\n");
        try err.flush();
    }
}

/// The size of the largest program file, in bytes.
///
/// Why: ライブラリのファイルの上限(`library.max_file_bytes`)と同じ値にする。ファイルは
/// 全体をメモリに読むので、上限が要る。
pub const max_program_bytes = 1024 * 1024;

/// The text of the file `path`, which the caller frees.
///
/// Why: `readFileAlloc` の上限は、ちょうど上限の大きさのファイルを断った。ライブラリの
/// ファイルの読み取り(src/syntax/source.zig)と同じ、開いて `allocRemaining` する形にする。
fn readProgram(gpa: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var buffer: [4096]u8 = undefined;
    var reader: std.Io.File.Reader = .init(file, io, &buffer);
    return reader.interface.allocRemaining(gpa, .limited(max_program_bytes)) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.StreamTooLong => return error.StreamTooLong,
        error.ReadFailed => return reader.err orelse error.ReadFailed,
    };
}

/// Runs the program in the file `path`, and returns the exit status.
///
/// ファイルの全体を読み、先頭から1つずつ評価する。式の値は出力しない。最初のエラーで
/// 止め、エラーより前の評価の副作用はそのまま残る。プログラムがコンソールに書いたもの
/// (`display` など)は `out` に書き、エラーの説明は `err` に書く。
pub fn runFile(gpa: std.mem.Allocator, files: sucheme.resolve.Files, path: []const u8, out: *std.Io.Writer, err: *std.Io.Writer) !u8 {
    const source = readProgram(gpa, files.io, path) catch |e| {
        try err.print("error: cannot read {s}: {s}\n", .{ path, if (e == error.StreamTooLong) "the file is larger than 1 MiB" else @errorName(e) });
        try err.flush();
        return exit_no_input;
    };
    defer gpa.free(source);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var interp: sucheme.Interpreter = undefined;
    try interp.initWithFiles(gpa, .{}, files);
    defer interp.deinit();
    // 展開時のエラーには、ファイルの中の位置を前置する(docs/design/frontend.md の位置情報)。
    interp.file_name = path;
    // 式の値は捨て、プログラムの出力だけを `out` に書く(スライス 5i)。
    interp.console_out = out;
    var discard: std.Io.Writer.Discarding = .init(&.{});
    interp.evalPrint(arena.allocator(), source, &discard.writer) catch |e| switch (e) {
        error.WriteFailed => return e,
        else => {
            // 端末では、プログラムの出力がエラーの説明より前に見えるよう、先に書き出す。
            try out.flush();
            try err.print("error: {s}\n", .{interp.diagnostic()});
            try err.flush();
            return exit_runtime_error;
        },
    };
    try out.flush();
    return 0;
}

test "classify recognises --version" {
    try std.testing.expect(classify(&.{"--version"}) == .version);
}

test "classify recognises --help and -h" {
    try std.testing.expect(classify(&.{"--help"}) == .help);
    try std.testing.expect(classify(&.{"-h"}) == .help);
}

test "classify runs the REPL with no argument and the file for a name" {
    try std.testing.expect(classify(&.{}) == .repl);
    try std.testing.expectEqual(@as(usize, 0), classify(&.{"foo.scm"}).run_file);
}

test "classify treats a bare dash as a name that is not served yet, not an unknown option" {
    try std.testing.expect(classify(&.{"-"}) == .not_implemented);
    try std.testing.expect(classify(&.{ "-", "x" }) == .not_implemented);
    // 1文字増えると、またオプションになる。
    try std.testing.expect(classify(&.{"-x"}) == .unknown_option);
}

test "classify distinguishes a mistyped option from a file name" {
    const r = classify(&.{"--verison"});
    try std.testing.expect(r == .unknown_option);
    try std.testing.expectEqualStrings("--verison", r.unknown_option);
}

test "classify prefers a recognised option over a later unknown one" {
    try std.testing.expect(classify(&.{ "--version", "--bogus" }) == .version);
}

test "classify takes -I and the directory after it as the search roots, not as a request" {
    try std.testing.expect(classify(&.{ "-I", "lib" }) == .repl);
    try std.testing.expect(classify(&.{ "-I", "a", "-I", "b" }) == .repl);
    // 次の引数は、`-` で始まっていても、ディレクトリの名前である。
    try std.testing.expect(classify(&.{ "-I", "--version" }) == .repl);
    try std.testing.expect(classify(&.{ "-I", "-x" }) == .repl);
    // 名前が続けば、ファイルの実行を求めている。名前の位置が、検索ルートの終わりである。
    try std.testing.expectEqual(@as(usize, 2), classify(&.{ "-I", "lib", "prog.scm" }).run_file);
    // 名前の後ろは、プログラムへの引数である。`-I` も、その1つになる。
    try std.testing.expect(classify(&.{ "prog.scm", "-I", "lib" }) == .program_arguments);
    try std.testing.expect(classify(&.{ "prog.scm", "--version" }) == .program_arguments);
    try std.testing.expect(classify(&.{ "prog.scm", "x" }) == .program_arguments);
    // 要求を決める最初の引数が優先される。
    try std.testing.expect(classify(&.{ "-I", "lib", "--version" }) == .version);
    try std.testing.expect(classify(&.{ "-I", "lib", "-h" }) == .help);
    const unknown = classify(&.{ "-I", "lib", "--bogus" });
    try std.testing.expectEqualStrings("--bogus", unknown.unknown_option);
    try std.testing.expect(classify(&.{ "--version", "-I" }) == .version);
}

test "classify reports -I without a directory, and does not accept the attached form" {
    const last = classify(&.{"-I"});
    try std.testing.expectEqualStrings("-I", last.missing_argument);
    try std.testing.expectEqualStrings("-I", classify(&.{ "-I", "a", "-I" }).missing_argument);
    // `-I` の次の引数が、ディレクトリとして使われるので、`-I -I` は欠けていない。
    try std.testing.expect(classify(&.{ "-I", "-I" }) == .repl);
    // 続けた形は、未知のオプションである。
    try std.testing.expectEqualStrings("-Ilib", classify(&.{"-Ilib"}).unknown_option);
}

test "searchRoots puts the working directory first, then each -I in order" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const none = try searchRoots(arena.allocator(), &.{});
    try std.testing.expectEqual(1, none.len);
    try std.testing.expectEqualStrings(".", none[0]);
    const roots = try searchRoots(arena.allocator(), &.{ "-I", "b", "-I", "a", "-I", "b" });
    try std.testing.expectEqual(4, roots.len);
    for ([_][]const u8{ ".", "b", "a", "b" }, roots) |want, have| try std.testing.expectEqualStrings(want, have);
    // ディレクトリの名前が `-I` でも、2つめの `-I` は新しい指定ではない。
    const odd = try searchRoots(arena.allocator(), &.{ "-I", "-I", "x" });
    try std.testing.expectEqual(2, odd.len);
    try std.testing.expectEqualStrings("-I", odd[1]);
}

/// Runs the REPL over `input` and returns what it wrote to stdout and stderr.
fn replOver(input: []const u8, out_buf: []u8, err_buf: []u8) !struct { out: []const u8, err: []const u8 } {
    var in: std.Io.Reader = .fixed(input);
    var out: std.Io.Writer = .fixed(out_buf);
    var err: std.Io.Writer = .fixed(err_buf);
    try repl(std.testing.allocator, null, &in, &out, &err);
    return .{ .out = out.buffered(), .err = err.buffered() };
}

test "repl prints each line's results after a prompt" {
    var ob: [256]u8 = undefined;
    var eb: [256]u8 = undefined;
    const r = try replOver("(+ 1 2)\n1 2\n", &ob, &eb);
    try std.testing.expectEqualStrings("> 3\n> 1\n2\n> \n", r.out);
    try std.testing.expectEqualStrings("", r.err);
}

test "repl reads a last line with no newline" {
    var ob: [256]u8 = undefined;
    var eb: [256]u8 = undefined;
    const r = try replOver("(+ 1 2)", &ob, &eb);
    try std.testing.expectEqualStrings("> 3\n> \n", r.out);
}

test "repl prints nothing for a line of only a comment and goes on" {
    var ob: [256]u8 = undefined;
    var eb: [256]u8 = undefined;
    const r = try replOver("; コメント\n(+ 1 2) ; 足す\n;\n\n  ; 空白つき\n42\n", &ob, &eb);
    try std.testing.expectEqualStrings("> > 3\n> > > > 42\n> \n", r.out);
    try std.testing.expectEqualStrings("", r.err);
}

test "repl reports an error and goes on to the next line" {
    var ob: [256]u8 = undefined;
    var eb: [256]u8 = undefined;
    // 閉じていない式は継続行になるので、ここでは使わない。構文エラーは継続せず、
    // その行で報告される。
    const r = try replOver("(foo)\n)\n42\n", &ob, &eb);
    try std.testing.expectEqualStrings("> > > 42\n> \n", r.out);
    try std.testing.expectEqualStrings("error: unbound variable: foo\nerror: unexpected )\n", r.err);
}

test "repl joins the lines of an unfinished expression and prompts for each" {
    var ob: [256]u8 = undefined;
    var eb: [256]u8 = undefined;
    const r = try replOver("(+ 1\n2)\n", &ob, &eb);
    try std.testing.expectEqualStrings("> ... 3\n> \n", r.out);
    try std.testing.expectEqualStrings("", r.err);
}

test "repl reads a definition over several lines, then goes on" {
    var ob: [256]u8 = undefined;
    var eb: [256]u8 = undefined;
    const r = try replOver("(define (f x)\n  (+ x 1))\n(f 1)\n", &ob, &eb);
    try std.testing.expectEqualStrings("> ... > 2\n> \n", r.out);
    try std.testing.expectEqualStrings("", r.err);
}

test "repl keeps asking while the expression stays open" {
    var ob: [256]u8 = undefined;
    var eb: [256]u8 = undefined;
    // 入れ子と空行。空行も継続の一部である。
    const r = try replOver("(+ 1\n\n  (+ 2\n3))\n", &ob, &eb);
    try std.testing.expectEqualStrings("> ... ... ... 6\n> \n", r.out);
    try std.testing.expectEqualStrings("", r.err);
    // `'` の直後。
    const q = try replOver("'\n(a)\n", &ob, &eb);
    try std.testing.expectEqualStrings("> ... (a)\n> \n", q.out);
    // ドットの直後。
    const d = try replOver("'(1 .\n2)\n", &ob, &eb);
    try std.testing.expectEqualStrings("> ... (1 . 2)\n> \n", d.out);
    // ベクタの途中。
    const v = try replOver("'#(1\n2)\n", &ob, &eb);
    try std.testing.expectEqualStrings("> ... #(1 2)\n> \n", v.out);
    try std.testing.expectEqualStrings("", v.err);
}

test "repl keeps the newline between lines, so a string can span them" {
    var ob: [256]u8 = undefined;
    var eb: [256]u8 = undefined;
    const r = try replOver("\"a\nb\"\n", &ob, &eb);
    try std.testing.expectEqualStrings("> ... \"a\\nb\"\n> \n", r.out);
    try std.testing.expectEqualStrings("", r.err);
}

test "repl does not count a paren in a comment or a string when it decides to continue" {
    var ob: [256]u8 = undefined;
    var eb: [256]u8 = undefined;
    const r = try replOver("(+ 1 ; )\n2)\n(quote \")\"\n)\n", &ob, &eb);
    try std.testing.expectEqualStrings("> ... 3\n> ... \")\"\n> \n", r.out);
    try std.testing.expectEqualStrings("", r.err);
}

test "repl reports a syntax error at once instead of asking for more" {
    var ob: [256]u8 = undefined;
    var eb: [256]u8 = undefined;
    const r = try replOver(")\n(a . )\n#z\n(a ')\n(+ 1 2)\n", &ob, &eb);
    try std.testing.expectEqualStrings("> > > > > 3\n> \n", r.out);
    try std.testing.expectEqualStrings(
        "error: unexpected )\nerror: unexpected .\nerror: unreadable token\nerror: quote needs a datum\n",
        r.err,
    );
}

test "repl drops what it kept when the expression ends in an error" {
    var ob: [256]u8 = undefined;
    var eb: [256]u8 = undefined;
    const r = try replOver("(foo\n)\n42\n", &ob, &eb);
    try std.testing.expectEqualStrings("> ... > 42\n> \n", r.out);
    try std.testing.expectEqualStrings("error: unbound variable: foo\n", r.err);
}

test "repl prints nothing for a comment or a blank line while no expression is open" {
    var ob: [256]u8 = undefined;
    var eb: [256]u8 = undefined;
    const r = try replOver("\n; c\n  \n(+ 1\n; c\n2)\n", &ob, &eb);
    try std.testing.expectEqualStrings("> > > > ... ... 3\n> \n", r.out);
    try std.testing.expectEqualStrings("", r.err);
}

test "repl evaluates a line with several expressions only once it is closed" {
    var ob: [256]u8 = undefined;
    var eb: [256]u8 = undefined;
    // 閉じた先頭の式の出力も、行全体が閉じるまで出ない。
    const r = try replOver("1 (+ 1\n2)\n", &ob, &eb);
    try std.testing.expectEqualStrings("> ... 1\n3\n> \n", r.out);
    try std.testing.expectEqualStrings("", r.err);
}

test "repl does not continue a line that ends inside a character or a hex escape" {
    var ob: [256]u8 = undefined;
    var eb: [256]u8 = undefined;
    // REPL は保留に改行を足すので、行末の `#\` は改行文字になる。
    const c = try replOver("#\\\n(+ 1 2)\n", &ob, &eb);
    try std.testing.expectEqualStrings("> #\\newline\n> 3\n> \n", c.out);
    try std.testing.expectEqualStrings("", c.err);
    // 行末の `\x41` は、改行と合わせて不正なエスケープになる。継続行にならず、
    // 次の行は新しい入力である。
    var ob2: [256]u8 = undefined;
    var eb2: [256]u8 = undefined;
    const x = try replOver("\"a\\x41\n(+ 1 2)\n", &ob2, &eb2);
    try std.testing.expectEqualStrings("> > 3\n> \n", x.out);
    try std.testing.expectEqualStrings("error: invalid escape in string\n", x.err);
}

test "repl continues a string whose line ends in a line continuation" {
    var ob: [256]u8 = undefined;
    var eb: [256]u8 = undefined;
    // 行末の `\` は、保留に足した改行と合わせて行継続になる(R7RS 6.7)。文字列は閉じて
    // いないので、次の行を求め、次の行の先頭の空白は文字列に入らない。
    const b = try replOver("\"a\\\n   b\"\n", &ob, &eb);
    try std.testing.expectEqualStrings("> ... \"ab\"\n> \n", b.out);
    try std.testing.expectEqualStrings("", b.err);
}

test "repl reports unexpected end of input when the input ends inside an expression" {
    var ob: [256]u8 = undefined;
    var eb: [256]u8 = undefined;
    const r = try replOver("(+ 1\n", &ob, &eb);
    try std.testing.expectEqualStrings("> ... \n", r.out);
    try std.testing.expectEqualStrings("error: unexpected end of input\n", r.err);
    // 最後の行に改行が無くても、同じである。
    var ob2: [256]u8 = undefined;
    var eb2: [256]u8 = undefined;
    const r2 = try replOver("1\n(+ 1\n 2", &ob2, &eb2);
    try std.testing.expectEqualStrings("> 1\n> ... ... \n", r2.out);
    try std.testing.expectEqualStrings("error: unexpected end of input\n", r2.err);
}

test "repl does not report the end of input after a finished expression" {
    var ob: [256]u8 = undefined;
    var eb: [256]u8 = undefined;
    const r = try replOver("(+ 1\n2)", &ob, &eb);
    try std.testing.expectEqualStrings("> ... 3\n> \n", r.out);
    try std.testing.expectEqualStrings("", r.err);
}

/// `n` spaces.
fn spaces(n: usize) ![]u8 {
    const s = try std.testing.allocator.alloc(u8, n);
    @memset(s, ' ');
    return s;
}

test "repl keeps an expression of exactly max_line bytes, newline included" {
    var ob: [256]u8 = undefined;
    var eb: [256]u8 = undefined;
    // "(+ 1\n" の 5 バイトと、空白と ")" と改行を足して max_line になる。
    const pad = try spaces(max_line - 7);
    defer std.testing.allocator.free(pad);
    const input = try std.mem.concat(std.testing.allocator, u8, &.{ "(+ 1\n", pad, ")\n" });
    defer std.testing.allocator.free(input);
    const r = try replOver(input, &ob, &eb);
    try std.testing.expectEqualStrings("> ... 1\n> \n", r.out);
    try std.testing.expectEqualStrings("", r.err);
}

test "repl drops an expression that is one byte over max_line and reports it" {
    var ob: [256]u8 = undefined;
    var eb: [256]u8 = undefined;
    const pad = try spaces(max_line - 6);
    defer std.testing.allocator.free(pad);
    const input = try std.mem.concat(std.testing.allocator, u8, &.{ "(+ 1\n", pad, ")\n7\n" });
    defer std.testing.allocator.free(input);
    const r = try replOver(input, &ob, &eb);
    try std.testing.expectEqualStrings("> ... > 7\n> \n", r.out);
    try std.testing.expectEqualStrings("error: the input does not fit in 65536 bytes, newline included\n", r.err);
}

test "repl reads the lines after a dropped expression as new input" {
    var ob: [1024]u8 = undefined;
    var eb: [256]u8 = undefined;
    // 1024 バイトの空白の行を続けると、64 行目で上限を超える。残りの行は新しい入力になる。
    const blank = try spaces(1023);
    defer std.testing.allocator.free(blank);
    var input: std.ArrayList(u8) = .empty;
    defer input.deinit(std.testing.allocator);
    try input.appendSlice(std.testing.allocator, "(\n");
    for (0..70) |_| {
        try input.appendSlice(std.testing.allocator, blank);
        try input.append(std.testing.allocator, '\n');
    }
    try input.appendSlice(std.testing.allocator, "7\n");
    const r = try replOver(input.items, &ob, &eb);
    try std.testing.expectEqualStrings("error: the input does not fit in 65536 bytes, newline included\n", r.err);
    try std.testing.expectEqual(64, std.mem.count(u8, r.out, "... "));
    try std.testing.expect(std.mem.endsWith(u8, r.out, "> 7\n> \n"));
}

test "repl drops the line that goes over max_line whole, even its part after the close" {
    var ob: [256]u8 = undefined;
    var eb: [256]u8 = undefined;
    // 保留が max_line - 4 バイトのとき、行 ") 7" は改行を含めて 4 バイトで、ちょうど収まる。
    // `)` が式を閉じて 1 を出し、7 が評価される。
    const fits_pad = try spaces(max_line - 10);
    defer std.testing.allocator.free(fits_pad);
    const fits_input = try std.mem.concat(std.testing.allocator, u8, &.{ "(+ 1\n", fits_pad, "\n) 7\n" });
    defer std.testing.allocator.free(fits_input);
    const fits = try replOver(fits_input, &ob, &eb);
    try std.testing.expectEqualStrings("> ... ... 1\n7\n> \n", fits.out);
    try std.testing.expectEqualStrings("", fits.err);
    // 保留が 1 バイト増えると同じ行が超え、行ごと捨てられる。7 は評価されない。
    const over_pad = try spaces(max_line - 9);
    defer std.testing.allocator.free(over_pad);
    const over_input = try std.mem.concat(std.testing.allocator, u8, &.{ "(+ 1\n", over_pad, "\n) 7\n8\n" });
    defer std.testing.allocator.free(over_input);
    const over = try replOver(over_input, &ob, &eb);
    try std.testing.expectEqualStrings("> ... ... > 8\n> \n", over.out);
    try std.testing.expectEqualStrings("error: the input does not fit in 65536 bytes, newline included\n", over.err);
}

test "repl evaluates the finished pieces of a dropped expression" {
    var ob: [1024]u8 = undefined;
    var eb: [256]u8 = undefined;
    const blank = try spaces(1023);
    defer std.testing.allocator.free(blank);
    var input: std.ArrayList(u8) = .empty;
    defer input.deinit(std.testing.allocator);
    try input.appendSlice(std.testing.allocator, "(define total 5)\n(begin\n");
    for (0..70) |_| {
        try input.appendSlice(std.testing.allocator, blank);
        try input.append(std.testing.allocator, '\n');
    }
    // 捨てた式 `(begin ...)` の尾である。`(set! total 0)` は完結しているので最上位で
    // 評価され、total が変わる。閉じ括弧は構文エラーとして報告される。
    try input.appendSlice(std.testing.allocator, "(set! total 0)\n)\ntotal\n");
    const r = try replOver(input.items, &ob, &eb);
    try std.testing.expectEqualStrings(
        "error: the input does not fit in 65536 bytes, newline included\nerror: unexpected )\n",
        r.err,
    );
    try std.testing.expect(std.mem.endsWith(u8, r.out, "> > > 0\n> \n"));
}

test "repl drops what it kept when a line is longer than it reads" {
    var ob: [256]u8 = undefined;
    var eb: [256]u8 = undefined;
    const long = try std.testing.allocator.alloc(u8, max_line + 1);
    defer std.testing.allocator.free(long);
    @memset(long, '1');
    const input = try std.mem.concat(std.testing.allocator, u8, &.{ "(\n", long, "\n7\n" });
    defer std.testing.allocator.free(input);
    var in_buf: [max_line]u8 = undefined;
    var src: std.Io.Reader = .fixed(input);
    var in = src.limited(.unlimited, &in_buf);
    var out: std.Io.Writer = .fixed(&ob);
    var err: std.Io.Writer = .fixed(&eb);
    try repl(std.testing.allocator, null, &in.interface, &out, &err);
    // 保留の "(" は捨てられるので、7 は新しい入力として評価され、終わりでも報告されない。
    try std.testing.expectEqualStrings("> ... > 7\n> \n", out.buffered());
    try std.testing.expectEqualStrings("error: the line does not fit in 65536 bytes, newline included\n", err.buffered());
}

test "repl skips a line longer than it reads and goes on" {
    var ob: [256]u8 = undefined;
    var eb: [256]u8 = undefined;
    const long = try std.testing.allocator.alloc(u8, max_line + 1);
    defer std.testing.allocator.free(long);
    @memset(long, '1');
    const input = try std.mem.concat(std.testing.allocator, u8, &.{ long, "\n7\n" });
    defer std.testing.allocator.free(input);
    // 固定リーダのバッファは入力の全体なので、上限になるのはリーダのではなく
    // stdin のバッファである。リーダに max_line のバッファを与える。

    var in_buf: [max_line]u8 = undefined;
    var src: std.Io.Reader = .fixed(input);
    var in = src.limited(.unlimited, &in_buf);
    var out: std.Io.Writer = .fixed(&ob);
    var err: std.Io.Writer = .fixed(&eb);
    try repl(std.testing.allocator, null, &in.interface, &out, &err);
    try std.testing.expectEqualStrings("> > 7\n> \n", out.buffered());
    try std.testing.expectEqualStrings("error: the line does not fit in 65536 bytes, newline included\n", err.buffered());
}

test "repl reads the longest line that fits, newline included" {
    var ob: [256]u8 = undefined;
    var eb: [256]u8 = undefined;
    const fits = try std.testing.allocator.alloc(u8, max_line);
    defer std.testing.allocator.free(fits);
    @memset(fits, ' ');
    fits[max_line - 2] = '5';
    fits[max_line - 1] = '\n';
    var in_buf: [max_line]u8 = undefined;
    var src: std.Io.Reader = .fixed(fits);
    var in = src.limited(.unlimited, &in_buf);
    var out: std.Io.Writer = .fixed(&ob);
    var err: std.Io.Writer = .fixed(&eb);
    try repl(std.testing.allocator, null, &in.interface, &out, &err);
    try std.testing.expectEqualStrings("> 5\n> \n", out.buffered());
    try std.testing.expectEqualStrings("", err.buffered());
}

test "repl keeps a definition for the lines after it" {
    var ob: [256]u8 = undefined;
    var eb: [256]u8 = undefined;
    const r = try replOver("(define x 40)\n(+ x 2)\n(+ y 1)\n(define y 1)\n(+ x y)\n", &ob, &eb);
    try std.testing.expectEqualStrings("> > 42\n> > > 41\n> \n", r.out);
    try std.testing.expectEqualStrings("error: unbound variable: y\n", r.err);
}

test "repl imports a library from a file beneath the roots it is given, and reports one that is not there" {
    var tree: sucheme.resolve.Tree = undefined;
    try tree.init(std.testing.allocator);
    defer tree.deinit(std.testing.allocator);
    try tree.write("foo/bar.sld", "(define-library (foo bar) (export f) (import (scheme base)) (begin (define (f) 7)))");
    var input: std.Io.Reader = .fixed("(import (foo bar))\n(f)\n(import (foo baz))\n(f)\n");
    var ob: [128]u8 = undefined;
    var eb: [128]u8 = undefined;
    var out: std.Io.Writer = .fixed(&ob);
    var err: std.Io.Writer = .fixed(&eb);
    try repl(std.testing.allocator, .{ .io = std.testing.io, .roots = &tree.roots }, &input, &out, &err);
    try std.testing.expectEqualStrings("> > 7\n> > 7\n> \n", out.buffered());
    try std.testing.expectEqualStrings("error: unknown library: (foo baz)\n", err.buffered());
}

/// Writes `text` to a file in a fresh directory and runs it; returns the status and stderr.
fn runProgram(text: []const u8, err_buf: []u8) !struct { status: u8, err: []const u8 } {
    var ob: [256]u8 = undefined;
    const r = try runProgramWithOutput(text, &ob, err_buf);
    return .{ .status = r.status, .err = r.err };
}

/// Writes `text` to a file in a fresh directory and runs it; returns the status, stdout
/// and stderr.
fn runProgramWithOutput(text: []const u8, out_buf: []u8, err_buf: []u8) !struct { status: u8, out: []const u8, err: []const u8 } {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "prog.scm", .data = text });
    const dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(dir);
    const path = try std.fs.path.join(std.testing.allocator, &.{ dir, "prog.scm" });
    defer std.testing.allocator.free(path);
    var out: std.Io.Writer = .fixed(out_buf);
    var err: std.Io.Writer = .fixed(err_buf);
    const status = try runFile(std.testing.allocator, .{ .io = std.testing.io, .roots = &.{dir} }, path, &out, &err);
    return .{ .status = status, .out = out.buffered(), .err = err.buffered() };
}

test "runFile writes what the program writes to the console to stdout, and not the values" {
    var ob: [256]u8 = undefined;
    var eb: [256]u8 = undefined;
    const r = try runProgramWithOutput("(import (scheme base) (scheme write))\n(display \"hi\")\n(newline)\n42\n(write-string \"x\" (current-error-port))\n", &ob, &eb);
    try std.testing.expectEqual(@as(u8, 0), r.status);
    // 式の値 42 は書かない。標準エラーへの書き込みも、5i では標準出力に出る(既知の制限)。
    try std.testing.expectEqualStrings("hi\nx", r.out);
    try std.testing.expectEqualStrings("", r.err);
}

test "runFile keeps what the program wrote before an error, ahead of the description" {
    var ob: [256]u8 = undefined;
    var eb: [256]u8 = undefined;
    const r = try runProgramWithOutput("(import (scheme base) (scheme write))\n(display \"before\")\n(car 1)\n(display \"after\")\n", &ob, &eb);
    try std.testing.expectEqual(exit_runtime_error, r.status);
    try std.testing.expectEqualStrings("before", r.out);
    try std.testing.expectEqualStrings("error: wrong type of argument to car 1\n", r.err);
}

test "runFile runs a program that starts with an import, prints nothing, and exits 0" {
    var eb: [256]u8 = undefined;
    const r = try runProgram("(import (scheme base))\n(define x 41)\n(+ x 1)\n", &eb);
    try std.testing.expectEqual(@as(u8, 0), r.status);
    try std.testing.expectEqualStrings("", r.err);
}

test "runFile runs a program that does not start with an import, in the REPL's environment" {
    var eb: [256]u8 = undefined;
    const r = try runProgram("(define (f n) (if (= n 0) 0 (+ 1 (f (- n 1)))))\n(f 10)\n", &eb);
    try std.testing.expectEqual(@as(u8, 0), r.status);
    try std.testing.expectEqualStrings("", r.err);
}

test "runFile stops at the first error with status 1, after the effects before it" {
    var eb: [256]u8 = undefined;
    const r = try runProgram("(define x 1)\n(car x)\n(undefined-after-the-error)\n", &eb);
    try std.testing.expectEqual(exit_runtime_error, r.status);
    try std.testing.expectEqualStrings("error: wrong type of argument to car 1\n", r.err);
}

test "runFile reports an unbound variable and a syntax error with status 1" {
    var eb: [256]u8 = undefined;
    const unbound = try runProgram("(foo)\n", &eb);
    try std.testing.expectEqual(exit_runtime_error, unbound.status);
    try std.testing.expectEqualStrings("error: unbound variable: foo\n", unbound.err);
    const unclosed = try runProgram("(define x 1\n", &eb);
    try std.testing.expectEqual(exit_runtime_error, unclosed.status);
    try std.testing.expect(std.mem.startsWith(u8, unclosed.err, "error: "));
}

test "runFile puts the place in the file before an error the expander raises" {
    var eb: [256]u8 = undefined;
    const r = try runProgram("(define x 1)\n(define (f)\n  (if))\n", &eb);
    try std.testing.expectEqual(exit_runtime_error, r.status);
    // パスは一時ディレクトリの絶対パスで、形が OS で違う(Windows はドライブ文字で始まる)ので、
    // 名前のあとだけを見る。行と桁は、`(if)` の `(` の位置である。
    try std.testing.expect(std.mem.startsWith(u8, r.err, "error: "));
    try std.testing.expect(std.mem.indexOf(u8, r.err, "error: prog.scm") == null);
    try std.testing.expect(std.mem.endsWith(u8, r.err, "prog.scm:3:3: bad if: expected (if test consequent) or (if test consequent alternative)\n"));
}

test "runFile reports a program that is not valid UTF-8 with status 1" {
    var eb: [256]u8 = undefined;
    const r = try runProgram("(define x \"\xff\")\n", &eb);
    try std.testing.expectEqual(exit_runtime_error, r.status);
    try std.testing.expect(std.mem.startsWith(u8, r.err, "error: "));
}

test "runFile rejects (sucheme core), like the REPL does" {
    var eb: [256]u8 = undefined;
    const r = try runProgram("(import (sucheme core))\n", &eb);
    try std.testing.expectEqual(exit_runtime_error, r.status);
    try std.testing.expect(std.mem.indexOf(u8, r.err, "(sucheme core)") != null);
}

test "runFile finds a library under a search root" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "foo");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "foo/bar.sld",
        .data = "(define-library (foo bar) (export f) (import (scheme base)) (begin (define (f) 7)))",
    });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "prog.scm", .data = "(import (scheme base) (foo bar))\n(car (f))\n" });
    const dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(dir);
    const path = try std.fs.path.join(std.testing.allocator, &.{ dir, "prog.scm" });
    defer std.testing.allocator.free(path);
    var eb: [256]u8 = undefined;
    var err: std.Io.Writer = .fixed(&eb);
    var out: std.Io.Writer.Discarding = .init(&.{});
    const status = try runFile(std.testing.allocator, .{ .io = std.testing.io, .roots = &.{dir} }, path, &out.writer, &err);
    // `(f)` は 7 を返し、`(car 7)` が誤りになる。ライブラリが読めたことは、その誤りの種類で分かる。
    try std.testing.expectEqual(exit_runtime_error, status);
    try std.testing.expectEqualStrings("error: wrong type of argument to car 7\n", err.buffered());
}

test "runFile returns 66 for a file that is missing, and for a directory" {
    var eb: [256]u8 = undefined;
    var err: std.Io.Writer = .fixed(&eb);
    var out: std.Io.Writer.Discarding = .init(&.{});
    const missing = try runFile(std.testing.allocator, .{ .io = std.testing.io, .roots = &.{"."} }, "no-such-dir/no-such-file.scm", &out.writer, &err);
    try std.testing.expectEqual(exit_no_input, missing);
    try std.testing.expect(std.mem.startsWith(u8, err.buffered(), "error: cannot read no-such-dir/no-such-file.scm: "));
    var err2: std.Io.Writer = .fixed(&eb);
    const directory = try runFile(std.testing.allocator, .{ .io = std.testing.io, .roots = &.{"."} }, ".", &out.writer, &err2);
    try std.testing.expectEqual(exit_no_input, directory);
}

test "runFile returns 66 for a file larger than the limit, and runs one at the limit" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const filler = try std.testing.allocator.alloc(u8, max_program_bytes + 1);
    defer std.testing.allocator.free(filler);
    @memset(filler, ' ');
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "over.scm", .data = filler });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "fits.scm", .data = filler[0..max_program_bytes] });
    const dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(dir);
    const files: sucheme.resolve.Files = .{ .io = std.testing.io, .roots = &.{dir} };
    var eb: [256]u8 = undefined;
    for ([_]struct { name: []const u8, want: u8 }{ .{ .name = "over.scm", .want = exit_no_input }, .{ .name = "fits.scm", .want = 0 } }) |c| {
        const path = try std.fs.path.join(std.testing.allocator, &.{ dir, c.name });
        defer std.testing.allocator.free(path);
        var err: std.Io.Writer = .fixed(&eb);
        var out: std.Io.Writer.Discarding = .init(&.{});
        try std.testing.expectEqual(c.want, try runFile(std.testing.allocator, files, path, &out.writer, &err));
    }
}
