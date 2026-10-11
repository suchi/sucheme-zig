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
//! 終わらせるのはその行の評価であり、REPL ではない。1行は完結したデータを含む。
//! リストの途中や `'` の直後で終わる行は、継続行が入るまでエラーになる
//! (ADR-0014)。エラーのあとも終了ステータスは 0 のままである。REPL は入力の
//! 残りを読み進めたからである。

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
/// 収まらない行は、報告してから読み飛ばす。
pub const max_line = 64 * 1024;

/// Reads lines from `in` until it ends, and evaluates and prints each.
///
/// 各行には、評価中に要るものためのまっさらなアリーナを使う。リーダが作るものと
/// 定義が保持するものはそこに入らず、インタプリタの中でセッションの終わりまで
/// 生きる。
pub fn repl(gpa: std.mem.Allocator, in: *std.Io.Reader, out: *std.Io.Writer, err: *std.Io.Writer) !void {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var interp: sucheme.Interpreter = undefined;
    try interp.init(gpa);
    defer interp.deinit();
    while (true) {
        try out.writeAll("> ");
        try out.flush();
        const line = in.takeDelimiter('\n') catch |e| switch (e) {
            error.StreamTooLong => {
                try err.print("error: the line does not fit in {d} bytes, newline included\n", .{max_line});
                try err.flush();
                _ = in.discardDelimiterInclusive('\n') catch |d| switch (d) {
                    error.EndOfStream => break,
                    error.ReadFailed => return d,
                };
                continue;
            },
            error.ReadFailed => return e,
        } orelse break;
        _ = arena.reset(.retain_capacity);
        interp.evalPrint(arena.allocator(), line, out) catch |e| switch (e) {
            error.WriteFailed => return e,
            else => {
                // エラーより前に書いた結果を先に出す。端末で2つのストリームの
                // 順序が保たれるようにするためである。
                try out.flush();
                try err.print("error: {s}\n", .{interp.diagnostic()});
                try err.flush();
            },
        };
    }
    // プロンプトの行を終わらせる。シェルのプロンプトがその行に続かないようにするためである。
    try out.writeAll("\n");
    try out.flush();
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

test "repl reports an error and goes on to the next line" {
    var ob: [256]u8 = undefined;
    var eb: [256]u8 = undefined;
    const r = try replOver("(foo)\n(+ 1\n42\n", &ob, &eb);
    try std.testing.expectEqualStrings("> > > 42\n> \n", r.out);
    try std.testing.expectEqualStrings("error: unbound variable: foo\nerror: unexpected end of input\n", r.err);
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
