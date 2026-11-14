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
//! | 同上で、実行時エラーが起きた | stderr に `error: ` と説明を出して、そこで止める。プログラムの出力も stdout に書けなければ、続けて `error: cannot write to standard output` を出す | 1 |
//! | 同上で、プログラムの出力を stdout に書けない(閉じている、満杯、パイプの先が閉じた) | stderr に `error: cannot write to standard output` を出して、そこで止める | 74 |
//! | 同上で、ファイルを開けない・読めない・大きすぎる | stderr に `cannot read <file>: ` と理由を出す | 66 |
//! | 同上で、プログラムが `exit` か `emergency-exit` を呼んだ | プログラムの出力を書き出して、そこで止める(`exit` は `dynamic-wind` の `after` を呼んでから) | `exit` の引数から決まる値(docs/design/platform-and-web.md の表)の下位8ビット |
//! | `<file>` の後ろに引数が続く | 引数を、`-` で始まるものも含めて、プログラムへの引数として `(command-line)` に渡し、ファイルのプログラムを実行する | 上の行と同じ |
//! | `<file>` かプログラムへの引数が UTF-8 でない | stderr に、何番目の引数かを出す | 64 |
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
//! 出力しない。プログラムが現在の出力ポートに書いたもの(`display`、`write-string` など)は
//! stdout に出る。`current-error-port` への書き込みは stderr に出る(スライス 5t)。書くたびに、
//! 先にそれまでの stdout への出力を書き出すので、端末の上では書いた順に並ぶ。REPL でも同じである。
//! プログラムの `read` や `read-char` は、標準入力から読む(スライス 5l)。
//! `(command-line)` は、ファイルの名前とプログラムへの引数の文字列のリストで、`sucheme prog.scm a b`
//! なら `("prog.scm" "a" "b")` である。`get-environment-variable` はプロセスの環境変数を読み、
//! 値が UTF-8 でなければ条件を送出する(docs/design/platform-and-web.md の検証の表)。標準ライブラリのファイルは `-I` の
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
//! 式の出力も、そのときまで遅れる。端末でない入力では、継続を取り消す手段は無い。
//!
//! 標準入力と標準出力の両方が POSIX の端末のときは、行を編集できる読み手で読む
//! (ADR-0049、`src/line_editor/line_reader.zig`)。1行を読む間だけ端末を生モードにし、
//! 評価の間は元に戻す。プロンプトと行は、再描画のエスケープシーケンスつきで stdout に書く。
//! 空の行の `Ctrl-D` は入力の終わりで、`Ctrl-C` は編集中の行と保留を捨てて、新しい
//! プロンプトに戻る(終了ステータスは変わらない)。評価中の `Ctrl-C` は、これまでどおり信号で
//! sucheme を終える。評価の出力が改行で終わらなかったときは、改行を足してからプロンプトを
//! 描く(出力を上書きしないため)。閉じた式は、継続行を改行でつないだ1項目
//! として、記憶上の履歴に残る。それ以外(Windows、パイプ、ファイル)は、行をそのまま読む。
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
//!
//! `exit` か `emergency-exit` を呼んだ式は、REPL を終わらせる。それまでの出力を書き出し、
//! 残りの入力は読まない。終了ステータスは、ファイルの実行と同じく、`exit` の引数から決まる。
//! REPL の `(command-line)` は、処理系の名前だけの `("sucheme")` である(WASM でコマンドラインが
//! 設定されていないときと同じ形)。

const std = @import("std");
const sucheme = @import("sucheme");
const line_editor = @import("line_editor/root.zig");
const LineReader = line_editor.line_reader.LineReader;

/// The panic handler: puts the terminal back from raw mode, then panics as usual.
///
/// 行の編集中(生モードの間)に panic すると、端末が生モードのまま残る(7h の残り)。
pub const panic = std.debug.FullPanic(panicRestoringTerminal);

fn panicRestoringTerminal(msg: []const u8, first_trace_addr: ?usize) noreturn {
    line_editor.term_posix.restoreActive();
    std.debug.defaultPanic(msg, first_trace_addr);
}

/// What the command line asked for.
pub const Request = union(enum) {
    version,
    help,
    repl,
    /// Run the program in the file named by the argument at this index; the
    /// arguments after it are the program's.
    run_file: usize,
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
                    "With a file, runs the program in it; what the program writes goes to stdout,\n" ++
                    "and the values of its expressions are not printed.\n" ++
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
            // 入力と出力の両方が POSIX の端末なら、行を編集できる読み手を使う(ADR-0049)。
            var terminal: line_editor.line_reader.PosixTerminal = .{
                .in = &stdin.interface,
                .in_fd = std.Io.File.stdin().handle,
                .out_fd = std.Io.File.stdout().handle,
            };
            // `rich` は、端末への書き込みが行の途中で終わったかを覚えるため、stdout と stderr を
            // `LineTracker` に通す(`line_reader.LineStart` の Why)。
            const interactive = line_editor.term_posix.isInteractive(io);
            var line_start: line_editor.line_reader.LineStart = .{};
            var out_tracker: line_editor.line_reader.LineTracker = .init(out, &line_start);
            var err_tracker: line_editor.line_reader.LineTracker = .init(err, &line_start);
            var reader: LineReader = if (interactive) .{ .rich = .{
                .editor = .init(std.heap.smp_allocator),
                .terminal = terminal.terminal(),
                .fallback = .{ .in = &stdin.interface },
                .line_start = &line_start,
            } } else .{ .dumb = .{ .in = &stdin.interface } };
            defer reader.deinit();
            const repl_out = if (interactive) &out_tracker.interface else out;
            const repl_err = if (interactive) &err_tracker.interface else err;
            const status = try replLines(std.heap.smp_allocator, .{ .io = io, .roots = roots }, .{ .variables = init.environ_map }, &reader, &stdin.interface, repl_out, repl_err);
            if (status != 0) std.process.exit(status);
        },
        .run_file => |index| {
            const command_line = programCommandLine(rest, index);
            if (firstInvalidArgument(command_line)) |i| {
                // 番号は、プログラムの名前を 0 とする引数の位置である(`rest` は argv[1..])。
                try err.print("{s}: argument {d} is not valid UTF-8\n", .{ sucheme.name, index + 1 + i });
                try err.flush();
                std.process.exit(exit_usage);
            }
            const roots = try searchRoots(init.arena.allocator(), rest[0..index]);
            const status = try runFile(std.heap.smp_allocator, .{ .io = io, .roots = roots }, rest[index], .{ .command_line = command_line, .variables = init.environ_map }, out, err);
            if (status != 0) std.process.exit(status);
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

/// Exit status for a program whose output could not be written to stdout.
///
/// 74 は sysexits.h の EX_IOERR である。
pub const exit_io_error: u8 = 74;

/// What the program sees of its process: its command line, and the variables
/// of its environment (R7RS 6.14).
pub const Process = struct {
    /// The file of the program and the arguments after it, each valid UTF-8, or
    /// just the name of the interpreter for the REPL.
    command_line: []const []const u8 = &.{sucheme.name},
    /// The variables of the environment, or null for none (the tests).
    variables: ?*const std.process.Environ.Map = null,

    /// Puts them where the primitives of `interp` read them.
    fn give(self: Process, interp: *sucheme.Interpreter) void {
        interp.ctx.heap.command_line = self.command_line;
        interp.ctx.heap.process_environ = self.variables;
    }
};

/// What `(command-line)` gives for the arguments after the program name, `rest`,
/// when `classify` found the program's file at `index`: the file and every
/// argument after it.
pub fn programCommandLine(rest: []const []const u8, index: usize) []const []const u8 {
    return rest[index..];
}

/// The index in `command_line` of the first argument that is not valid UTF-8,
/// or null when they all are.
/// Why: 引数は Scheme の文字列になるので、起動時に UTF-8 を検査する
/// (docs/design/platform-and-web.md の検証の表)。Windows で対になっていない
/// サロゲートは、Zig が WTF-8 の3バイトで渡すので、ここで断られる。
pub fn firstInvalidArgument(command_line: []const []const u8) ?usize {
    for (command_line, 0..) |arg, i| {
        if (!std.unicode.utf8ValidateSlice(arg)) return i;
    }
    return null;
}

/// The exit status for the exit code `code` of `exit`: its low 8 bits, which is
/// what the system keeps of it (docs/design/platform-and-web.md, the table of
/// `exit`).
fn exitStatus(code: i32) u8 {
    return @truncate(@as(u32, @bitCast(code)));
}

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
        // 最初の名前がプログラムのファイルで、その後ろは、プログラムへの引数である
        // (`command-line`)。オプションとしては読まない。
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
/// 返すのは終了ステータスで、`exit` で終わったときのほかは 0 である。
pub fn repl(gpa: std.mem.Allocator, files: ?sucheme.resolve.Files, process: Process, in: *std.Io.Reader, out: *std.Io.Writer, err: *std.Io.Writer) !u8 {
    var reader: LineReader = .{ .dumb = .{ .in = in } };
    defer reader.deinit();
    return replLines(gpa, files, process, &reader, in, out, err);
}

/// Runs the REPL over the lines `reader` gives; `in` is what the program's `read` reads.
///
/// `reader` が `rich` のときは、閉じた式を、行を改行でつないだ1項目として履歴に記録する。
/// `Ctrl-C`(`interrupted`)は、保留を捨てて新しいプロンプトに戻る。
pub fn replLines(gpa: std.mem.Allocator, files: ?sucheme.resolve.Files, process: Process, reader: *LineReader, in: *std.Io.Reader, out: *std.Io.Writer, err: *std.Io.Writer) !u8 {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var interp: sucheme.Interpreter = undefined;
    try interp.initWithFiles(gpa, .{}, files);
    defer interp.deinit();
    process.give(&interp);
    // プログラムの `read` は、REPL がまだ読んでいない行から読む(suchi/sucheme-zig#230)。
    interp.console_in = in;
    // `current-error-port` への書き込みは、診断と同じ stderr に出す(スライス 5t)。
    interp.console_err = err;
    // 継続行の保留。エントリ層は確保を起動と終了に限るので、固定長にする。
    var pending: [max_line]u8 = undefined;
    var kept: usize = 0;
    while (true) {
        const line = switch (try reader.read(out, if (kept == 0) prompt else continuation_prompt)) {
            .line => |l| l,
            .end => break,
            .interrupted => {
                kept = 0;
                continue;
            },
            .too_long => {
                try err.print("error: the line does not fit in {d} bytes, newline included\n", .{max_line});
                try err.flush();
                // 続きを読んでも、保留していた式の残りが分からない。保留も捨てる。
                kept = 0;
                continue;
            },
        };
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
        try reader.addHistory(pending[0..kept]);
        _ = arena.reset(.retain_capacity);
        interp.evalPrint(arena.allocator(), pending[0..kept], out) catch |e| switch (e) {
            error.WriteFailed => return e,
            // `exit` は REPL を終わらせる。それまでの出力を書き出し、残りの入力は読まない。
            error.Exited => {
                try out.flush();
                return exitStatus(interp.ctx.exit_code);
            },
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
    return 0;
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
pub fn runFile(gpa: std.mem.Allocator, files: sucheme.resolve.Files, path: []const u8, process: Process, out: *std.Io.Writer, err: *std.Io.Writer) !u8 {
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
    // `current-error-port` への書き込みは、stderr に出す(スライス 5t)。
    interp.console_err = err;
    // プログラムの `read` と `read-char` は、標準入力から読む(suchi/sucheme-zig#230)。
    var in_buf: [max_line]u8 = undefined;
    var stdin = std.Io.File.Reader.initStreaming(.stdin(), files.io, &in_buf);
    interp.console_in = &stdin.interface;
    process.give(&interp);
    var discard: std.Io.Writer.Discarding = .init(&.{});
    interp.evalPrint(arena.allocator(), source, &discard.writer) catch |e| switch (e) {
        // 式の値は捨てているので、ここに来る書き込みの失敗は、プログラムの出力の標準出力である。
        error.WriteFailed => return cannotWriteOutput(err),
        // Why: 書き出せなければ、それを伝える。`exit` が伝えた値は、正常な終了を示していても、
        // 出力が失われたことを隠すので使わない(`exit 0` で 74 にする)。
        error.Exited => {
            out.flush() catch return cannotWriteOutput(err);
            return exitStatus(interp.ctx.exit_code);
        },
        else => {
            // 端末では、プログラムの出力がエラーの説明より前に見えるよう、先に書き出す。
            // 書き出せなくても、元のエラーの説明は隠さない。終了コードは実行時エラーのままにする。
            const flushed = if (out.flush()) true else |_| false;
            try err.print("error: {s}\n", .{interp.diagnostic()});
            if (!flushed) try err.writeAll(cannot_write_output);
            try err.flush();
            return exit_runtime_error;
        },
    };
    out.flush() catch return cannotWriteOutput(err);
    return 0;
}

/// What the diagnostic is when the program's output cannot be written to stdout.
const cannot_write_output = "error: cannot write to standard output\n";

/// Reports that the program's output could not be written, and gives the exit status.
/// Why: 標準出力が閉じているか満杯か、パイプの先が読み終えている(`| head -c 0`)。どれも
/// プログラムの誤りでなく出力先の失敗なので、実行時エラー(1)と分けて、入出力の誤り(74)にする。
/// パイプの先が閉じた場合も、黙らずに同じ診断を出す。失敗の種類を見分けずに済み、出力が
/// 欠けたことが分かるからである。
fn cannotWriteOutput(err: *std.Io.Writer) !u8 {
    try err.writeAll(cannot_write_output);
    try err.flush();
    return exit_io_error;
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
    try std.testing.expectEqual(@as(usize, 0), classify(&.{ "prog.scm", "-I", "lib" }).run_file);
    try std.testing.expectEqual(@as(usize, 0), classify(&.{ "prog.scm", "--version" }).run_file);
    try std.testing.expectEqual(@as(usize, 2), classify(&.{ "-I", "lib", "prog.scm", "x", "-" }).run_file);
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
    _ = try repl(std.testing.allocator, null, .{}, &in, &out, &err);
    return .{ .out = out.buffered(), .err = err.buffered() };
}

test "exit in the repl ends it, after the output so far and the after of dynamic-wind, with the status it gives" {
    var ob: [256]u8 = undefined;
    var eb: [256]u8 = undefined;
    var in: std.Io.Reader = .fixed("(import (scheme process-context) (scheme write))\n(display \"a\")\n(dynamic-wind (lambda () #f) (lambda () (exit 300)) (lambda () (display \"b\")))\n(display \"never\")\n");
    var out: std.Io.Writer = .fixed(&ob);
    var err: std.Io.Writer = .fixed(&eb);
    // 300 の下位8ビットは 44 である。
    try std.testing.expectEqual(@as(u8, 44), try repl(std.testing.allocator, null, .{}, &in, &out, &err));
    try std.testing.expectEqualStrings("> > a> b", out.buffered());
    try std.testing.expectEqualStrings("", err.buffered());
    // 引数の無い REPL の `command-line` は、処理系の名前だけである。
    const r = try replOver("(import (scheme process-context)) (command-line)\n", &ob, &eb);
    try std.testing.expectEqualStrings("> (\"sucheme\")\n> \n", r.out);
}

test "runFile gives the program its command line and its variables, and ends with the status exit gives" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "prog.scm", .data =
        \\(import (scheme base) (scheme write) (scheme process-context))
        \\(write (command-line))
        \\(write (get-environment-variable "SUCHEME_TEST"))
        \\(write (get-environment-variable "SUCHEME_NONE"))
        \\(write (assoc "SUCHEME_TEST" (get-environment-variables)))
        \\(exit (length (command-line)))
        \\(display "never")
    });
    const dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(dir);
    const path = try std.fs.path.join(std.testing.allocator, &.{ dir, "prog.scm" });
    defer std.testing.allocator.free(path);
    var variables: std.process.Environ.Map = .init(std.testing.allocator);
    defer variables.deinit();
    try variables.put("SUCHEME_TEST", "値");
    // 値が UTF-8 でない項目は、複数形の結果から除かれる。
    try variables.put("SUCHEME_BAD", "\xff");
    var ob: [256]u8 = undefined;
    var out: std.Io.Writer = .fixed(&ob);
    var eb: [256]u8 = undefined;
    var err: std.Io.Writer = .fixed(&eb);
    const command_line = [_][]const u8{ "prog.scm", "a", "-I" };
    const status = try runFile(std.testing.allocator, .{ .io = std.testing.io, .roots = &.{dir} }, path, .{ .command_line = &command_line, .variables = &variables }, &out, &err);
    try std.testing.expectEqual(@as(u8, 3), status);
    try std.testing.expectEqualStrings("(\"prog.scm\" \"a\" \"-I\")\"値\"#f(\"SUCHEME_TEST\" . \"値\")", out.buffered());
    try std.testing.expectEqualStrings("", err.buffered());
}

test "a variable whose value is not UTF-8 raises from get-environment-variable" {
    var variables: std.process.Environ.Map = .init(std.testing.allocator);
    defer variables.deinit();
    try variables.put("SUCHEME_BAD", "\xff");
    // 名前が UTF-8 でない項目も、複数形の結果から除かれる。残るのは妥当な1件だけである。
    // Why: 名前は、対になっていないサロゲート(WTF-8 では妥当で、UTF-8 では不正)にする。
    // Windows の `Environ.Map.put` は、名前が WTF-8 として妥当であることを表明するので、`"\xff"` は
    // 置けない(層2 の Windows のジョブで表明に当たった)。Windows で実際に渡りうる不正な名前もこの形である。
    try variables.put("\xed\xa0\x80", "ok");
    try variables.put("SUCHEME_GOOD", "ok");
    var ob: [256]u8 = undefined;
    var eb: [256]u8 = undefined;
    var in: std.Io.Reader = .fixed("(import (scheme process-context)) (get-environment-variable \"SUCHEME_BAD\")\n(get-environment-variables)\n");
    var out: std.Io.Writer = .fixed(&ob);
    var err: std.Io.Writer = .fixed(&eb);
    try std.testing.expectEqual(@as(u8, 0), try repl(std.testing.allocator, null, .{ .variables = &variables }, &in, &out, &err));
    try std.testing.expectEqualStrings("> > ((\"SUCHEME_GOOD\" . \"ok\"))\n> \n", out.buffered());
    try std.testing.expectEqualStrings("error: value is not valid UTF-8 in get-environment-variable \"SUCHEME_BAD\"\n", err.buffered());
}

test "the command line of a program is its file and every argument after it, and an argument that is not UTF-8 is found" {
    const rest = [_][]const u8{ "-I", "lib", "prog.scm", "a", "-" };
    const index = classify(&rest).run_file;
    const command_line = programCommandLine(&rest, index);
    try std.testing.expectEqual(@as(usize, 3), command_line.len);
    for ([_][]const u8{ "prog.scm", "a", "-" }, command_line) |want, got| try std.testing.expectEqualStrings(want, got);
    try std.testing.expectEqual(@as(?usize, null), firstInvalidArgument(&.{ "prog.scm", "α" }));
    try std.testing.expectEqual(@as(?usize, 2), firstInvalidArgument(&.{ "prog.scm", "a", "\xff" }));
    try std.testing.expectEqual(@as(?usize, 0), firstInvalidArgument(&.{ "\xed\xa0\x80", "a" }));
    // 断るときの終了ステータスは、sysexits.h の EX_USAGE である(doc コメントの契約の表)。
    try std.testing.expectEqual(@as(u8, 64), exit_usage);
}

test "runFile reports that stdout could not take the output when the program exits, even with 0" {
    var room: [64]u8 = undefined;
    var out = failingStdout(&room);
    var eb: [256]u8 = undefined;
    const r = try runProgramTo("(import (scheme base) (scheme write) (scheme process-context))\n(display \"hi\")\n(exit 0)\n", &out, &eb);
    try std.testing.expectEqual(exit_io_error, r.status);
    try std.testing.expectEqualStrings("error: cannot write to standard output\n", r.err);
}

test "the exit status of exit is the low 8 bits of its code" {
    try std.testing.expectEqual(@as(u8, 0), exitStatus(0));
    try std.testing.expectEqual(@as(u8, 255), exitStatus(-1));
    try std.testing.expectEqual(@as(u8, 0), exitStatus(256));
    try std.testing.expectEqual(@as(u8, 255), exitStatus(std.math.maxInt(i32)));
}

test "read and read-line in the repl take the lines the repl has not read yet" {
    var ob: [256]u8 = undefined;
    var eb: [256]u8 = undefined;
    // `(read)` は次の行のデータを取り、REPL はその行を評価しない。データの後ろの改行は残るので、
    // REPL は次に空の行を読み、プロンプトだけを出す。
    const r = try replOver("(import (scheme read)) (read)\n(a b)\n(read-line)\nthe line\n(eof-object? (read))\n", &ob, &eb);
    try std.testing.expectEqualStrings("> (a b)\n> > \"the line\"\n> #t\n> \n", r.out);
    try std.testing.expectEqualStrings("", r.err);
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
    _ = try repl(std.testing.allocator, null, .{}, &in.interface, &out, &err);
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
    _ = try repl(std.testing.allocator, null, .{}, &in.interface, &out, &err);
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
    _ = try repl(std.testing.allocator, null, .{}, &in.interface, &out, &err);
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
    _ = try repl(std.testing.allocator, .{ .io = std.testing.io, .roots = &tree.roots }, .{}, &input, &out, &err);
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
    var out: std.Io.Writer = .fixed(out_buf);
    const r = try runProgramTo(text, &out, err_buf);
    return .{ .status = r.status, .out = out.buffered(), .err = r.err };
}

/// Writes `text` to a file in a fresh directory and runs it with `out` as stdout;
/// returns the status and stderr.
fn runProgramTo(text: []const u8, out: *std.Io.Writer, err_buf: []u8) !struct { status: u8, err: []const u8 } {
    var err: std.Io.Writer = .fixed(err_buf);
    const status = try runProgramToBoth(text, out, &err);
    return .{ .status = status, .err = err.buffered() };
}

/// A writer that keeps up to `buffer` bytes and fails when it has to write them out,
/// like stdout that is closed or full.
fn failingStdout(buffer: []u8) std.Io.Writer {
    const failing = struct {
        fn drain(_: *std.Io.Writer, _: []const []const u8, _: usize) std.Io.Writer.Error!usize {
            return error.WriteFailed;
        }
    };
    return .{ .vtable = &.{ .drain = failing.drain }, .buffer = buffer };
}

/// What reaches a terminal, in the order the writers write it out.
const Terminal = struct {
    bytes: [512]u8 = undefined,
    len: usize = 0,

    fn shown(self: *const Terminal) []const u8 {
        return self.bytes[0..self.len];
    }

    fn append(self: *Terminal, bytes: []const u8) void {
        @memcpy(self.bytes[self.len..][0..bytes.len], bytes);
        self.len += bytes.len;
    }
};

/// A writer that keeps up to `buffer` bytes and puts them on `terminal` only when it writes
/// them out, like stdout or stderr that is buffered.
/// Why: `std.Io.Writer.fixed` の `flush` は何もしないので、書き出しを忘れても、書き出しの
/// 順序を誤っても、テストに見えない。
const TerminalWriter = struct {
    terminal: *Terminal,
    interface: std.Io.Writer,

    fn init(terminal: *Terminal, buffer: []u8) TerminalWriter {
        return .{ .terminal = terminal, .interface = .{ .vtable = &.{ .drain = drain }, .buffer = buffer } };
    }

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *TerminalWriter = @alignCast(@fieldParentPtr("interface", w));
        self.terminal.append(w.buffered());
        w.end = 0;
        var n: usize = 0;
        for (data[0 .. data.len - 1]) |bytes| {
            self.terminal.append(bytes);
            n += bytes.len;
        }
        for (0..splat) |_| {
            self.terminal.append(data[data.len - 1]);
            n += data[data.len - 1].len;
        }
        return n;
    }
};

/// Runs `text` from a file with `out` as stdout and `err` as stderr; returns the status.
fn runProgramToBoth(text: []const u8, out: *std.Io.Writer, err: *std.Io.Writer) !u8 {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "prog.scm", .data = text });
    const dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(dir);
    const path = try std.fs.path.join(std.testing.allocator, &.{ dir, "prog.scm" });
    defer std.testing.allocator.free(path);
    return runFile(std.testing.allocator, .{ .io = std.testing.io, .roots = &.{dir} }, path, .{}, out, err);
}

test "runFile writes stderr out, after what the program wrote to stdout" {
    // 実行時エラー: プログラムの出力が先に見え、説明がそのあとに続く。
    // 標準エラーの領域は、説明が書き出すまで残るよう、説明より大きくする。
    var t1: Terminal = .{};
    var ob1: [16]u8 = undefined;
    var eb1: [128]u8 = undefined;
    var out1: TerminalWriter = .init(&t1, &ob1);
    var err1: TerminalWriter = .init(&t1, &eb1);
    const s1 = try runProgramToBoth("(import (scheme base) (scheme write))\n(display \"hello\")\n(car 1)\n", &out1.interface, &err1.interface);
    try std.testing.expectEqual(exit_runtime_error, s1);
    try std.testing.expectEqualStrings("helloerror: wrong type of argument to car 1\n", t1.shown());
    // 標準出力に書けない: 診断は書き出されている。
    var t2: Terminal = .{};
    var ob2: [4]u8 = undefined;
    var eb2: [128]u8 = undefined;
    var out2 = failingStdout(&ob2);
    var err2: TerminalWriter = .init(&t2, &eb2);
    const s2 = try runProgramToBoth("(import (scheme base) (scheme write))\n(display \"hello\")\n", &out2, &err2.interface);
    try std.testing.expectEqual(exit_io_error, s2);
    try std.testing.expectEqualStrings("error: cannot write to standard output\n", t2.shown());
    // 実行時エラーと重なる: 2つの説明が、どちらも書き出されている。
    var t3: Terminal = .{};
    var ob3: [64]u8 = undefined;
    var eb3: [128]u8 = undefined;
    var out3 = failingStdout(&ob3);
    var err3: TerminalWriter = .init(&t3, &eb3);
    const s3 = try runProgramToBoth("(import (scheme base) (scheme write))\n(display \"hello\")\n(car 1)\n", &out3, &err3.interface);
    try std.testing.expectEqual(exit_runtime_error, s3);
    try std.testing.expectEqualStrings("error: wrong type of argument to car 1\nerror: cannot write to standard output\n", t3.shown());
}

test "what a program writes to stdout and to the error port shows on the terminal in the order it was written" {
    // 標準出力の領域は、書き出さなければ全部ためられる大きさにする。順序が保たれるのは、
    // 標準エラーへの書き込みの前に標準出力を書き出すからで、領域が満ちたからではない。
    var t: Terminal = .{};
    var ob: [128]u8 = undefined;
    var eb: [128]u8 = undefined;
    var out: TerminalWriter = .init(&t, &ob);
    var err: TerminalWriter = .init(&t, &eb);
    const s = try runProgramToBoth("(import (scheme base) (scheme write))\n(display \"a\")\n(write-string \"B\" (current-error-port))\n(display \"c\")\n(write 'D (current-error-port))\n(display \"e\")\n", &out.interface, &err.interface);
    try std.testing.expectEqual(@as(u8, 0), s);
    try std.testing.expectEqualStrings("aBcDe", t.shown());
}

test "the repl writes what goes to the error port to stderr, in order with the prompts and the results" {
    var ob: [256]u8 = undefined;
    var eb: [256]u8 = undefined;
    const r = try replOver("(import (scheme base) (scheme write))\n(begin (display \"a\") (write-string \"B\" (current-error-port)) 1)\n", &ob, &eb);
    try std.testing.expectEqualStrings("> > a1\n> \n", r.out);
    try std.testing.expectEqualStrings("B", r.err);
    // 端末の上では、結果の前に、書いた順に並ぶ。
    var t: Terminal = .{};
    var tob: [256]u8 = undefined;
    var teb: [256]u8 = undefined;
    var out: TerminalWriter = .init(&t, &tob);
    var err: TerminalWriter = .init(&t, &teb);
    var in: std.Io.Reader = .fixed("(import (scheme base) (scheme write))\n(begin (display \"a\") (write-string \"B\" (current-error-port)) (display \"c\") 1)\n");
    _ = try repl(std.testing.allocator, null, .{}, &in, &out.interface, &err.interface);
    try std.testing.expectEqualStrings("> > aBc1\n> \n", t.shown());
}

test "runFile reports output it cannot write to stdout, and exits 74" {
    // 書き手の領域より多く書くと、プログラムの途中で書けなくなる。
    var small: [4]u8 = undefined;
    var out = failingStdout(&small);
    var eb: [256]u8 = undefined;
    const r = try runProgramTo("(import (scheme base) (scheme write))\n(display \"hello\")\n(display \"never\")\n", &out, &eb);
    try std.testing.expectEqual(exit_io_error, r.status);
    try std.testing.expectEqual(@as(u8, 74), exit_io_error);
    try std.testing.expectEqualStrings("error: cannot write to standard output\n", r.err);
    // 書いたものが領域に収まっても、終わりの書き出しで失敗すれば、同じである。
    var room: [64]u8 = undefined;
    var out2 = failingStdout(&room);
    const r2 = try runProgramTo("(import (scheme base) (scheme write))\n(display \"hi\")\n", &out2, &eb);
    try std.testing.expectEqual(exit_io_error, r2.status);
    try std.testing.expectEqualStrings("error: cannot write to standard output\n", r2.err);
}

test "runFile keeps the description of a runtime error when stdout cannot be written either" {
    var room: [64]u8 = undefined;
    var out = failingStdout(&room);
    var eb: [256]u8 = undefined;
    const r = try runProgramTo("(import (scheme base) (scheme write))\n(display \"hi\")\n(car 1)\n", &out, &eb);
    try std.testing.expectEqual(exit_runtime_error, r.status);
    try std.testing.expectEqualStrings("error: wrong type of argument to car 1\nerror: cannot write to standard output\n", r.err);
}

test "runFile writes what the program writes to the console to stdout, and not the values" {
    var ob: [256]u8 = undefined;
    var eb: [256]u8 = undefined;
    const r = try runProgramWithOutput("(import (scheme base) (scheme write))\n(display \"hi\")\n(newline)\n42\n(write-string \"x\" (current-error-port))\n", &ob, &eb);
    try std.testing.expectEqual(@as(u8, 0), r.status);
    // 式の値 42 は書かない。標準エラーへの書き込みは、標準エラーに出る(スライス 5t)。
    try std.testing.expectEqualStrings("hi\n", r.out);
    try std.testing.expectEqualStrings("x", r.err);
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
    const status = try runFile(std.testing.allocator, .{ .io = std.testing.io, .roots = &.{dir} }, path, .{}, &out.writer, &err);
    // `(f)` は 7 を返し、`(car 7)` が誤りになる。ライブラリが読めたことは、その誤りの種類で分かる。
    try std.testing.expectEqual(exit_runtime_error, status);
    try std.testing.expectEqualStrings("error: wrong type of argument to car 7\n", err.buffered());
}

test "runFile returns 66 for a file that is missing, and for a directory" {
    var eb: [256]u8 = undefined;
    var err: std.Io.Writer = .fixed(&eb);
    var out: std.Io.Writer.Discarding = .init(&.{});
    const missing = try runFile(std.testing.allocator, .{ .io = std.testing.io, .roots = &.{"."} }, "no-such-dir/no-such-file.scm", .{}, &out.writer, &err);
    try std.testing.expectEqual(exit_no_input, missing);
    try std.testing.expect(std.mem.startsWith(u8, err.buffered(), "error: cannot read no-such-dir/no-such-file.scm: "));
    var err2: std.Io.Writer = .fixed(&eb);
    const directory = try runFile(std.testing.allocator, .{ .io = std.testing.io, .roots = &.{"."} }, ".", .{}, &out.writer, &err2);
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
        try std.testing.expectEqual(c.want, try runFile(std.testing.allocator, files, path, .{}, &out.writer, &err));
    }
}

/// 編集できる読み手で、台本の打鍵を REPL に通す。返すのは、REPL の出力(再描画の列を含む)と診断と、
/// 終わったあとの履歴の項目数である。
fn replRich(typed: []const u8, out: *std.Io.Writer.Allocating, err: *std.Io.Writer.Allocating) !usize {
    var script: line_editor.line_reader.Script = .{ .bytes = typed };
    var in: std.Io.Reader = .fixed("");
    var reader: LineReader = .{ .rich = .{
        .editor = .init(std.testing.allocator),
        .terminal = script.terminal(),
        .fallback = .{ .in = &in },
    } };
    defer reader.deinit();
    _ = try replLines(std.testing.allocator, null, .{}, &reader, &in, &out.writer, &err.writer);
    // 生モードは、読んだ行ごとに入って出る。
    try std.testing.expectEqual(script.began, script.finished);
    return reader.rich.editor.history.len();
}

test "the editing repl evaluates an edited line, and continues an open expression on the next line" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var err: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer err.deinit();
    // "(+ 1 2)" の 2 を Backspace で消して 3 にし、続く行で式を閉じる。
    const n = try replRich("(+ 1 2\x7f3\r)\r\x04", &out, &err);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "... ") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\n4\n") != null);
    try std.testing.expectEqualStrings("", err.written());
    // 閉じた式は、2行をつないだ1項目として記録される。
    try std.testing.expectEqual(@as(usize, 1), n);
}

test "Ctrl-C in the editing repl drops what it kept, and the next expression starts afresh" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var err: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer err.deinit();
    // "(+ 1" の保留は Ctrl-C で捨てられるので、"5" は継続でなく新しい式として評価される。
    const n = try replRich("(+ 1\r\x03" ++ "5\r\x04", &out, &err);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "^C\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\n5\n") != null);
    try std.testing.expectEqualStrings("", err.written());
    try std.testing.expectEqual(@as(usize, 1), n);
}

test "Ctrl-D on an empty continuation line in the editing repl ends the input with the open expression reported" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var err: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer err.deinit();
    // Ctrl-D のあとの打鍵は読まれない(台本の終わりで止まったのではないことを示す)。
    _ = try replRich("(+ 1\r\x04" ++ "1)\r", &out, &err);
    try std.testing.expectEqualStrings("error: unexpected end of input\n", err.written());
}

test "the editing repl recalls the previous expression with Up" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var err: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer err.deinit();
    _ = try replRich("(define x 1)\r(set! x (+ x 1))\r\x1b[A\rx\r\x04", &out, &err);
    // set! を2回評価したので 3 になる。
    try std.testing.expect(std.mem.endsWith(u8, out.written(), "\n3\n\r> \x1b[K\r\x1b[2C\n"));
}

test "the editing repl keeps output that does not end a line, by starting the prompt on a new line" {
    var sink: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer sink.deinit();
    var err: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer err.deinit();
    var line_start: line_editor.line_reader.LineStart = .{};
    var out: line_editor.line_reader.LineTracker = .init(&sink.writer, &line_start);
    var script: line_editor.line_reader.Script = .{ .bytes = "(import (scheme write))\r(display \"tail\")\r\x04" };
    var in: std.Io.Reader = .fixed("");
    var reader: LineReader = .{ .rich = .{
        .editor = .init(std.testing.allocator),
        .terminal = script.terminal(),
        .fallback = .{ .in = &in },
        .line_start = &line_start,
    } };
    defer reader.deinit();
    _ = try replLines(std.testing.allocator, null, .{}, &reader, &in, &out.interface, &err.writer);
    // "tail" のあとに改行が入ってから、次のプロンプトが行頭から描かれる。
    try std.testing.expect(std.mem.indexOf(u8, sink.written(), "tail\n\r> ") != null);
}

test {
    std.testing.refAllDecls(@This());
}
