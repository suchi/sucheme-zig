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
//! | なし | stdin が尽きるまで REPL を走らせる | 0 |
//! | `-` だけ | オプションでなく名前として扱う | 69 |
//! | それ以外 | ファイルの実行は未実装だと伝える | 69 |
//!
//! 要求を決める最初の引数が優先される。このため `--version --bogus` はバージョンを
//! 出し、`--bogus --version` は未知のオプションとしてその名前を出す。未知の
//! オプションも要求を決める。それ以降の引数は調べない。
//!
//! 診断は stderr に出し、この段階で応えられない要求は非ゼロで終了する。
//! `sucheme prog.scm && echo ok` が、プログラムを実行しないまま ok を出すことを
//! 防ぐためである。
//!
//! REPL は、プロンプト `> ` と各結果を stdout に、エラーを stderr に
//! `error: ` と `unbound variable: foo` のようなメッセージとして書く。エラーが
//! 終わらせるのはその式の評価であり、REPL ではない。`;` から行末までは行コメント
//! で、コメントだけの行は何も出力しない。
//!
//! 閉じていない式(リストやベクタの途中、`'` の直後、文字列や `#\` の途中、
//! ドットの直後)で終わる行は、継続行になる(ADR-0014)。継続行のプロンプトは
//! `... ` で、次の行が、保留している入力の続きとして足される。足すとき改行を
//! 戻すので、複数行の文字列リテラルは改行を含む。式が閉じたところで、保留の全体を
//! 評価する。複数の式を含む行は、最後の式が閉じるまで評価されない。閉じた先頭の
//! 式の出力も、そのときまで遅れる。継続を取り消す手段は無い。
//!
//! 構文エラー(`)` だけの行、`(a . )`、`#z`)は、続きを足しても直らないので、
//! 継続行にならずにその行で報告される。
//!
//! 保留の合計は、改行を含めて 65536 バイト(`max_line`)までである。超えたら
//! `error: the input does not fit in 65536 bytes, newline included` を報告して、
//! 保留を捨てる。同じ式の残りの行は新しい入力として読まれるので、エラーが続きうる。
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
    /// A valid request this stage cannot serve yet.
    not_implemented,
    /// An option this program does not know.
    ///
    /// 診断がその名前を出せるように運ぶ。「未実装」と「打ち間違い」は別の
    /// 失敗であり、1つの状態では区別できない。
    unknown_option: []const u8,
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
                "{s} {s}\n\nUsage: {s} [--version] [--help|-h]\n\n" ++
                    "With no argument, reads expressions from stdin and prints their values.\n" ++
                    "Integers, booleans, lists, variables, procedures and arithmetic only for now;\n" ++
                    "see docs/roadmap.md.\n",
                .{ sucheme.name, sucheme.version, sucheme.name },
            );
            try out.flush();
        },
        .repl => {
            var in_buf: [max_line]u8 = undefined;
            var stdin = std.Io.File.Reader.initStreaming(.stdin(), io, &in_buf);
            try repl(init.gpa, &stdin.interface, out, err);
        },
        .not_implemented => {
            try err.print(
                "{s}: running a file is not implemented yet.\n" ++
                    "Run with --help for the options available now.\n",
                .{sucheme.name},
            );
            try err.flush();
            std.process.exit(exit_not_implemented);
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

/// Exit status for a command line this program cannot parse.
///
/// 64 は sysexits.h の EX_USAGE で、ここで慣習に最も近いものである。
pub const exit_usage: u8 = 64;

/// Classifies the arguments after the program name.
pub fn classify(args: []const []const u8) Request {
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--version")) return .version;
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) return .help;
        // 先頭が `-` で一致しないものは、ファイル名でなく打ち間違いである。
        // ただし `-` だけは別で、慣習では標準入力を指す。これは名前の側に
        // 落ち、段階1で意味が与えられる。
        if (arg.len > 1 and arg[0] == '-') return .{ .unknown_option = arg };
    }
    return if (args.len == 0) .repl else .not_implemented;
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
pub fn repl(gpa: std.mem.Allocator, in: *std.Io.Reader, out: *std.Io.Writer, err: *std.Io.Writer) !void {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var interp: sucheme.Interpreter = undefined;
    try interp.init(gpa);
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

test "classify recognises --version" {
    try std.testing.expect(classify(&.{"--version"}) == .version);
}

test "classify recognises --help and -h" {
    try std.testing.expect(classify(&.{"--help"}) == .help);
    try std.testing.expect(classify(&.{"-h"}) == .help);
}

test "classify runs the REPL with no argument and nothing yet for a name" {
    try std.testing.expect(classify(&.{}) == .repl);
    try std.testing.expect(classify(&.{"foo.scm"}) == .not_implemented);
}

test "classify treats a bare dash as a name, not an unknown option" {
    try std.testing.expect(classify(&.{"-"}) == .not_implemented);
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

/// Runs the REPL over `input` and returns what it wrote to stdout and stderr.
fn replOver(input: []const u8, out_buf: []u8, err_buf: []u8) !struct { out: []const u8, err: []const u8 } {
    var in: std.Io.Reader = .fixed(input);
    var out: std.Io.Writer = .fixed(out_buf);
    var err: std.Io.Writer = .fixed(err_buf);
    try repl(std.testing.allocator, &in, &out, &err);
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
    try repl(std.testing.allocator, &in.interface, &out, &err);
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
    try repl(std.testing.allocator, &in.interface, &out, &err);
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
    try repl(std.testing.allocator, &in.interface, &out, &err);
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
