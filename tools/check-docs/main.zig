//! Machine checks over the repository's documentation and build settings.
//!
//! `zig build check-docs` で実行する。テストのルートと除外するソースファイルは
//! build.zig が渡す。テスト構成の唯一の情報源を build.zig に置くためで、ここに
//! ハードコードすると両者がずれていく。
//!
//! Zig のソースはトークン化し、build.zig.zon は ZON としてパースする。文字列
//! 検索はしない。生の検索では、コメント内の `// @import("orphan.zig")` を本物の
//! import と取り違え、コメントアウトされた `.version` が本物を隠してしまう。
//!
//! 失敗はすべて報告してから非ゼロで終了する。最初の失敗で止めると、1回の実行で
//! 1件ずつしか直せない。実行全体で書き出し口(writer)を1つだけ使う。診断ごとに
//! `File.Writer` を作ると毎回オフセット0に巻き戻り、`2> log` には最後の1行しか
//! 残らない。
//!
//! 検査するのは、コードと生成物についての事実に限る。検証が黙って止まらないこと、
//! 生成物に記録されたハッシュと件数がその生成物と一致すること、固定した版がどこ
//! でも一致すること、相対リンクが解決できること。生成物がまだ入力から導かれて
//! いるかどうかは、抽出プログラム自身の比較モードが見ており、`zig build
//! check-extract` が実行する。ここでは見ない。文章の書き方も検査しない。その線
//! 引きと、線を引くために取り下げた検査は
//! docs/adr/0026-verify-facts-about-code-not-prose.md にある。
//!
//! 文書が固定した Zig の版を宣言しているかも検査しない。「宣言」「参照」「検証の
//! 記録」は数字の一致では区別できず、試みると誤検出(版を含むドキュメントの
//! URL)と見逃し(裸の「0.17」)の両方が出た。docs/design/zig-api-notes.md は、
//! これを版上げ手順の中の人が行う手順として残している。

const std = @import("std");

/// Directories never walked when collecting files, beyond what `.gitignore`
/// already excludes.
///
/// `.git` は Git 自身のもの、`node_modules` はパッケージマネージャのもので、
/// どちらも `.gitignore` に書かれていない。歩くと、このリポジトリが持たない
/// ファイルを検査してしまう。それ以外の飛ばすべきものは `.gitignore` に名前が
/// あるから飛ばされる。そのためこの一覧は `zig-out/`・`.zig-cache/`・`_work` を
/// 繰り返さない。
const skipped_dirs = [_][]const u8{ ".git", "node_modules" };

/// Collects diagnostics on one writer so a redirect keeps all of them.
///
/// 書き出し口を1つにまとめ、リダイレクトしても全件が残るようにする。
const Reporter = struct {
    w: *std.Io.Writer,
    count: usize = 0,

    fn fail(self: *Reporter, comptime fmt: []const u8, args: anytype) void {
        self.count += 1;
        self.w.print("check-docs: " ++ fmt ++ "\n", args) catch {};
    }
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();
    const io = init.io;
    const cwd = std.Io.Dir.cwd();

    var buf: [8192]u8 = undefined;
    // 既定の位置指定(positional)モードでなくストリーミングにする。位置指定の
    // writer はオフセット0から書き始めるので、追記先や共有のファイルの先頭を
    // 上書きし、`zig build check-docs >> ci.log 2>&1` が以前の出力を消してしまう。
    var stderr = std.Io.File.Writer.initStreaming(.stderr(), io, &buf);
    var rep: Reporter = .{ .w = &stderr.interface };

    const argv = try init.minimal.args.toSlice(gpa);
    var roots: std.ArrayList([]const u8) = .empty;
    var excluded: std.ArrayList([]const u8) = .empty;
    // `build.zig` が存在を保証するコマンド。それぞれ、提供する step の名前で
    // 呼ぶ。名前を挙げる側がビルドでなければならない理由は、build.zig の
    // `--requires` の一覧にある。
    var required: std.ArrayList([]const u8) = .empty;
    var bad_args = false;
    var stage: ?usize = null;
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        if (std.mem.eql(u8, argv[i], "--stage")) {
            if (i + 1 >= argv.len or std.mem.startsWith(u8, argv[i + 1], "--")) {
                rep.fail("--stage needs a value", .{});
                bad_args = true;
                break;
            }
            i += 1;
            stage = std.fmt.parseInt(usize, argv[i], 10) catch {
                rep.fail("--stage {s} is not a number", .{argv[i]});
                bad_args = true;
                break;
            };
            continue;
        }
        const which: ?*std.ArrayList([]const u8) =
            if (std.mem.eql(u8, argv[i], "--root")) &roots else if (std.mem.eql(u8, argv[i], "--exclude")) &excluded else if (std.mem.eql(u8, argv[i], "--requires")) &required else null;
        if (which) |list| {
            // 次の引数は別のフラグでなく値でなければならない。そうしないと
            // `--root --exclude x` が "--exclude" をルートとして登録し、原因でなく
            // その結果を報告してしまう。
            if (i + 1 >= argv.len or std.mem.startsWith(u8, argv[i + 1], "--")) {
                rep.fail("{s} needs a value", .{argv[i]});
                bad_args = true;
                break;
            }
            i += 1;
            try list.append(gpa, argv[i]);
        } else {
            rep.fail("unknown argument {s}", .{argv[i]});
            bad_args = true;
            break;
        }
    }
    if (roots.items.len == 0 and !bad_args) {
        rep.fail("build.zig passed no --root", .{});
        bad_args = true;
    }
    if (stage == null and !bad_args) {
        rep.fail("build.zig passed no --stage", .{});
        bad_args = true;
    }
    if (required.items.len == 0 and !bad_args) {
        rep.fail("build.zig passed no --requires", .{});
        bad_args = true;
    }

    // コマンドラインが不正だと、後の検査は原因でなく結果を報告する。ここで止める。
    if (!bad_args) {
        // .gitignore が無いときの診断を検査ごとの複数件でなく1件にするため、
        // ここで1回だけ読む。空の集合は全エントリを対象にすることを意味し、これが
        // 厳しい側である。
        const ignore = read(gpa, io, cwd, &rep, ".gitignore") orelse "";

        try checkZigVersionAgreement(gpa, io, cwd, &rep, ignore);
        try checkCiRunsTheTable(gpa, io, cwd, &rep, ignore, stage.?, required.items);
        try checkVendoredHashes(gpa, io, cwd, &rep);
        try checkGeneratedHashes(gpa, io, cwd, &rep, ignore);
        try checkRecordedCounts(gpa, io, cwd, &rep, ignore);
        try checkSources(gpa, io, cwd, &rep, ignore, roots.items, excluded.items);
        try checkMarkdown(gpa, io, cwd, &rep, ignore);
        try checkAdrRules(gpa, io, cwd, &rep, ignore);
    }

    if (rep.count == 0) {
        try rep.w.print("check-docs: all checks passed\n", .{});
    } else {
        try rep.w.print("check-docs: {d} problem(s) found\n", .{rep.count});
    }
    try stderr.interface.flush();
    if (rep.count != 0) std.process.exit(1);
}

/// Reads a file, reporting rather than swallowing a failure.
///
/// 読めないファイルはどの検査からも抜け落ちる。そこで黙ると「all checks passed」
/// と報告されてしまう。
fn read(gpa: std.mem.Allocator, io: std.Io, cwd: std.Io.Dir, rep: *Reporter, path: []const u8) ?[:0]u8 {
    return cwd.readFileAllocOptions(io, path, gpa, .unlimited, .of(u8), 0) catch |err| {
        rep.fail("{s} cannot be read ({t}), so it is unchecked", .{ path, err });
        return null;
    };
}

// ---------------------------------------------------------------------------
// 1. 固定した Zig の版が、機械が読む3箇所で一致する。
// ---------------------------------------------------------------------------

/// The one field of build.zig.zon this check reads.
///
/// この検査が読む build.zig.zon のフィールドはこの1つだけである。
const Manifest = struct { minimum_zig_version: []const u8 };

fn checkZigVersionAgreement(
    gpa: std.mem.Allocator,
    io: std.Io,
    cwd: std.Io.Dir,
    rep: *Reporter,
    ignore: []const u8,
) !void {
    // 失敗は read が報告する。ここで2つ目のメッセージを足すと、原因1つが問題2件に
    // 見えた。
    const pinned_raw = read(gpa, io, cwd, rep, ".zigversion") orelse return;
    const pinned = std.mem.trim(u8, pinned_raw, &std.ascii.whitespace);

    if (read(gpa, io, cwd, rep, "build.zig.zon")) |source| {
        var diagnostics: std.zon.parse.Diagnostics = undefined;
        if (std.zon.parse.fromSlice(Manifest, .{
            .gpa = gpa,
            .arena = gpa,
            .source = source,
            .diagnostics = &diagnostics,
            .ignore_unknown_fields = true,
        })) |m| {
            if (!std.mem.eql(u8, m.minimum_zig_version, pinned))
                rep.fail(
                    "build.zig.zon minimum_zig_version is {s}, .zigversion is {s}",
                    .{ m.minimum_zig_version, pinned },
                );
        } else |_| rep.fail("build.zig.zon could not be parsed as ZON", .{});
    }

    // 実行されるのは .github/workflows 直下のワークフローだけである。サブ
    // ディレクトリのファイルは動かないので、その版を検査しても何も失敗しない。
    var workflows: std.ArrayList([]const u8) = .empty;
    try collectFiles(gpa, io, cwd, ignore, ".github/workflows", ".yml", &workflows, .flat);
    try collectFiles(gpa, io, cwd, ignore, ".github/workflows", ".yaml", &workflows, .flat);
    if (workflows.items.len == 0) {
        rep.fail(".github/workflows has no workflow file; the CI copy of the Zig version cannot be checked", .{});
        return;
    }

    var setups_per_commit: usize = 0;
    for (workflows.items) |path| {
        const body = read(gpa, io, cwd, rep, path) orelse continue;
        var found: std.ArrayList(StepVersion) = .empty;
        try workflowZigVersions(gpa, body, &found);
        if (std.mem.eql(u8, path, per_commit_workflow)) setups_per_commit += found.items.len;
        // 最初の setup step だけでなく全部を検査する。そうしないと、2つ目のジョブが
        // 別の Zig を入れられる。setup step が無いワークフローは問題ない。すべての
        // ワークフローに Zig が要るわけではない。
        for (found.items) |step| {
            const version = step.version;
            if (version == null or step.extra) {
                rep.fail(
                    "{s}: a setup-zig step has no single readable version; write one `version:` on a line of its own under that step's `with:`",
                    .{path},
                );
                continue;
            }
            if (!std.mem.eql(u8, version.?, pinned))
                rep.fail("{s} sets up Zig {s}, .zigversion is {s}", .{ path, version.?, pinned });
        }
    }
    // 全ワークフローの合計でなく、コミットごとのワークフローの中で数える。合計だと
    // setup step を、何も起動しないワークフローに移せてしまう。版は検査されたまま、
    // Zig を要するコマンドには Zig が入っていない状態になる。run 行も同じ理由で、
    // 同じワークフローに限る。
    if (setups_per_commit == 0) rep.fail(
        "{s} has no setup-zig step, so the commands it runs have no pinned Zig",
        .{per_commit_workflow},
    );
}

// ---------------------------------------------------------------------------
// すべての ADR が索引に行を持ち、すべての行がファイルを持つ。
//
// 検査するのは対の存在だけである。行が ADR について述べること(状態、置き換え先、
// 補足の置き場所)は、数巡のあいだここで照合していた。それは Markdown の散文から
// 記録を読み出すことを意味した。ADR-0026 がこれを取り下げた。索引の古い状態は
// 読み手が気づく誤りであり、機械で捕まえるための特例は誤りそのものより高くつく。
// ---------------------------------------------------------------------------

const adr_dir = "docs/adr";
const adr_index = "docs/adr/README.md";

fn checkAdrRules(
    gpa: std.mem.Allocator,
    io: std.Io,
    cwd: std.Io.Dir,
    rep: *Reporter,
    ignore: []const u8,
) !void {
    var files: std.ArrayList([]const u8) = .empty;
    try collectFiles(gpa, io, cwd, ignore, adr_dir, ".md", &files, .flat);

    // 読み手に見える形で読む。生のファイルを取ると、索引全体を HTML コメントで
    // 包めてしまう。描画されたページからは全行が消えるのに、この検査は全行を
    // 見つけ続ける。
    const raw_index = read(gpa, io, cwd, rep, adr_index) orelse return;
    const index = try visibleMarkdown(gpa, rep, adr_index, raw_index);

    for (files.items) |path| {
        const name = std.fs.path.basename(path);
        // 索引とテンプレートは決定ではない。
        if (std.mem.eql(u8, name, "README.md") or std.mem.startsWith(u8, name, "0000-")) continue;
        switch (adrRow(index, name)) {
            .one => {},
            .none => rep.fail("{s} has no row opening with a link to {s}", .{ adr_index, name }),
            .many => |n| rep.fail(
                "{s} has {d} rows for {s}; one ADR has one row",
                .{ adr_index, n, name },
            ),
        }
    }

    // ファイルが無くなった行。
    var lines = std.mem.splitScalar(u8, index, '\n');
    while (lines.next()) |raw| {
        const row = std.mem.trim(u8, raw, &std.ascii.whitespace);
        if (row.len == 0 or row[0] != '|') continue;
        const target = linkTargetInRow(row) orelse continue;
        const joined = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ adr_dir, target });
        if (!pathIn(files.items, joined)) rep.fail(
            "{s} lists {s}, which does not exist",
            .{ adr_index, target },
        );
    }
}

/// The index row whose first cell links to `name`.
///
/// 見つけるのでなく数える。表は ADR ごとに1行と定めている。古い行が本物の行の
/// 下に残ると、索引が1つの ADR に2つの答えを示す。
const IndexRow = union(enum) {
    one: []const u8,
    none,
    many: usize,
};

fn adrRow(index: []const u8, name: []const u8) IndexRow {
    var found: ?[]const u8 = null;
    var count: usize = 0;
    var lines = std.mem.splitScalar(u8, index, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, &std.ascii.whitespace);
        if (line.len == 0 or line[0] != '|') continue;
        const first = cellAt(line, 0) orelse continue;
        const target = linkTargetInRow(first) orelse continue;
        if (!std.mem.eql(u8, target, name)) continue;
        count += 1;
        if (found == null) found = line;
    }
    if (count > 1) return .{ .many = count };
    return if (found) |line| .{ .one = line } else .none;
}

/// The first `](...)` target in a row, when it names a sibling Markdown file.
///
/// 先頭の `./` とリンクのタイトルは落とす。どちらも同じファイルを指すのに、
/// 以前は認識されなかった。`[0017](./0017-x.md)` と書くと、行を数える検査から
/// 索引の重複行が見えなくなった。
fn linkTargetInRow(row: []const u8) ?[]const u8 {
    const open = std.mem.indexOf(u8, row, "](") orelse return null;
    const rest = row[open + 2 ..];
    const close = std.mem.indexOfScalar(u8, rest, ')') orelse return null;
    var target = rest[0..close];

    // `[text](path "title")`
    if (std.mem.indexOfScalar(u8, target, ' ')) |space| target = target[0..space];
    // `[text](<path>)`
    if (target.len >= 2 and target[0] == '<' and target[target.len - 1] == '>')
        target = target[1 .. target.len - 1];
    if (std.mem.startsWith(u8, target, "./")) target = target[2..];

    if (!std.mem.endsWith(u8, target, ".md")) return null;
    if (std.mem.indexOfScalar(u8, target, '/') != null) return null;
    return target;
}

// ---------------------------------------------------------------------------
// CI ワークフローは、AGENTS.md が全コミットと印を付けた行を実行する。
//
// .github/workflows/ci.yml は、その表を実行内容の唯一の情報源だと宣言している。
// 両者を突き合わせるものが無かったため、`- run:` を1行消すだけで、その検証が
// 黙って止まった。ワークフロー自身のコメントが、避けるために書かれたと述べる
// 状態である。
// ---------------------------------------------------------------------------

/// The workflow that runs on every commit.
///
/// 名前で指定する。「全コミット」はトリガの性質であり、トリガがコミットである
/// ワークフローはこれだけだからである。表が全コミットと印を付けたコマンドは、
/// どこかで走るだけでなく、ここで走らなければならない。どのワークフローでも
/// 一致を受理すると、コマンドを定期実行のワークフローに移しても緑のままになる。
const per_commit_workflow = ".github/workflows/ci.yml";

/// The workflow that runs the slow tier (docs/plans/0007-test-tiers.md).
const slow_workflow = ".github/workflows/full.yml";

/// The commands of the table's rows that run in the slow tier, which
/// `slow_workflow` has to run.
///
/// この行は全コミットと印が付いていないので、コミットごとのワークフローとの
/// 照合はこれを読まない。ここで名指しするのはそのためである。名指ししないと、
/// ワークフローから `-Dslow=true` を落としても、step を消しても、全コマンドが
/// 緑のまま、規模を試すテストがどこでも走らなくなる。名前は `build.zig` が
/// `slow` オプションとテスト step に付けたものなので、1つ落とすことは、
/// それが走らせるものを落とすことになる。
///
/// `zig build dist` は規模を試すテストではないが、表の CI の列が「PR を ready に
/// するとき、手動、タグの push」を含むので、同じ形で名指しする。落とすと、
/// リリースの成果物の組み立てが、タグを打つまでどこでも走らなくなる。
const slow_commands = [_][]const u8{
    "zig build test -Dslow=true",
    "zig build test-scheme -Dslow=true",
    "zig build test-wasm -Dslow=true",
    "zig build dist",
};

/// A row of the verification command table, as this check reads it.
///
/// この検査が読み取る、検証コマンド表の1行。
const CommandRow = struct {
    command: []const u8,
    /// The whole command cell, for rows that name more than one command.
    ///
    /// 複数のコマンドを名指しする行のために、コマンドのセル全体を持つ。
    cell: []const u8,
    /// The stage the command starts existing at, or null if the cell is not a
    /// number.
    ///
    /// セットアップの行は `-` と書くので null になる。
    stage: ?usize,
    every_commit: bool,
};

/// Reports disagreement between the table and the workflow that runs per commit.
///
/// 双方向で見る。表が要求するのにワークフローが実行しないコマンドと、ワーク
/// フローが実行するのに表がこの段階で印を付けていないコマンドである。片方向だけ
/// だと表を正確に読む必要があった。行を隠す、あるいは `全コミット` にゼロ幅
/// スペースを混ぜると要求が消え、誰も気づかない。両方向なら、検査から見えない行が
/// あっても、ワークフローの step が表のどこにも対応しない形で現れる。そのため
/// セルの綴りは問題でなくなる。
fn checkCiRunsTheTable(
    gpa: std.mem.Allocator,
    io: std.Io,
    cwd: std.Io.Dir,
    rep: *Reporter,
    ignore: []const u8,
    stage: usize,
    required_commands: []const []const u8,
) !void {
    const raw_table = read(gpa, io, cwd, rep, "AGENTS.md") orelse return;
    const table = try visibleMarkdown(gpa, rep, "AGENTS.md", raw_table);

    var workflows: std.ArrayList([]const u8) = .empty;
    try collectFiles(gpa, io, cwd, ignore, ".github/workflows", ".yml", &workflows, .flat);
    try collectFiles(gpa, io, cwd, ignore, ".github/workflows", ".yaml", &workflows, .flat);

    // キーは全ワークフローで検査する。どこかに読めないキーがあれば、そのファイルに
    // 対するこの検査の読み取りが信用できなくなるからである。コマンドを集めるのは、
    // コミットごとに走るワークフローからだけである。
    var run_lines: std.ArrayList([]const u8) = .empty;
    var slow_run_lines: std.ArrayList([]const u8) = .empty;
    // コミットごとのワークフローが実際に持つキーと値。ワークフローが走るかどうかを
    // 決めるものを、閉じた集合に固定できるようにする。
    var seen: std.ArrayList(struct { key: []const u8, value: []const u8 }) = .empty;
    // 層2のワークフローが持つキーと値。Windows のテストと、層2が走る時機を固定する。
    var slow_seen: std.ArrayList(struct { key: []const u8, value: []const u8 }) = .empty;
    for (workflows.items) |path| {
        const per_commit = std.mem.eql(u8, path, per_commit_workflow);
        const is_slow = std.mem.eql(u8, path, slow_workflow);
        const body = read(gpa, io, cwd, rep, path) orelse continue;
        // step 自身のキーが置かれる桁。直近のリスト項目から求める。
        var step_keys_at: ?usize = null;
        var lines = std.mem.splitScalar(u8, body, '\n');
        var lineno: usize = 0;
        while (lines.next()) |raw| {
            lineno += 1;
            var line = std.mem.trim(u8, raw, &std.ascii.whitespace);
            line = std.mem.trim(u8, stripComment(line), &std.ascii.whitespace);
            if (line.len == 0) continue;

            const is_item = std.mem.startsWith(u8, line, "- ");
            const key_column = if (is_item) indentOf(raw) + 2 else indentOf(raw);
            if (is_item) {
                step_keys_at = key_column;
                line = std.mem.trim(u8, line[2..], &std.ascii.whitespace);
            }

            const key = yamlKey(line) orelse {
                // `key: value` として読めない行は、飛ばさず報告する。飛ばすと、
                // 引用符付きのキーとコロンの前の空白が素通りした。どちらも Actions
                // は裸のキーと同じ綴りとして扱う。ジョブに `'if': false` と書くと、
                // 全 step が飛ばされるのに全コマンドが緑のままだった。
                //
                // コロンの有無にかかわらず報告する。コロンを要求すると、複数行の
                // plain スカラーが素通りした。継続行にはコロンが無いからである。
                // `- run: zig fmt --check .` の次に字下げした `--help` があると、
                // ここでは裸のコマンドと読まれるが、YAML は両者を
                // `zig fmt --check . --help` に畳む。これは何も検査せず、ゼロで
                // 終了する。
                rep.fail(
                    "{s}:{d}: `{s}` is not a key this check can read; write every line as a bare `key: value`, with no quotes, no space before the colon and no continuation line",
                    .{ path, lineno, line },
                );
                continue;
            };
            if (!keyIsAllowed(key)) {
                rep.fail(
                    "{s}:{d}: `{s}` is not a key this check knows; add it to allowed_workflow_keys after deciding what it means for the verification",
                    .{ path, lineno, key },
                );
                continue;
            }
            // Why: `types:` はトリガが発火するイベントを絞り、`workflow_dispatch`
            // は手動のイベントを足す。低速階層のワークフロー(full.yml)は両方を
            // 使うが、全コミットで走るワークフローは使ってはならない。どちらも、
            // 表が全コミットで走ると言っているのに、コミットの検査が走る時機を
            // 変えてしまう。`env` は step のシェルの動作を変えられるので、同じく置かせない。
            if (per_commit and isForbiddenInPerCommit(key)) {
                rep.fail(
                    "{s}:{d}: `{s}` is not allowed in the workflow that runs on every commit; it changes when or how the commit's checks run",
                    .{ path, lineno, key },
                );
                continue;
            }
            if (per_commit) try seen.append(gpa, .{
                .key = key,
                .value = std.mem.trim(u8, line[key.len + 1 ..], &std.ascii.whitespace),
            });
            if (is_slow) try slow_seen.append(gpa, .{
                .key = key,
                .value = std.mem.trim(u8, line[key.len + 1 ..], &std.ascii.whitespace),
            });
            if (!std.mem.eql(u8, key, "run")) continue;

            // 何かを実行するのは step 自身の `run` だけである。`with:` の下に置いた
            // `run` はアクションの入力であり、Actions は警告して無視する。それを数えると、
            // コマンドが CI から消えているのに、検査は実行されていると報告した。
            if (step_keys_at == null or key_column != step_keys_at.?) {
                rep.fail(
                    "{s}:{d}: this `run:` is not a step's own key, so it runs nothing",
                    .{ path, lineno },
                );
                continue;
            }

            var value = std.mem.trim(u8, line[key.len + 1 ..], &std.ascii.whitespace);
            if (value.len == 0) {
                // `defaults:` が開くマッピングの `run:` はコマンドでなく設定を
                // 持つ。「この行にコマンドを書け」と言うと、原因を取り違える。
                rep.fail(
                    "{s}:{d}: this `run:` opens a mapping. A command belongs on the `run:` line itself",
                    .{ path, lineno },
                );
                continue;
            }
            if (value[0] == '|' or value[0] == '>') {
                rep.fail(
                    "{s}:{d}: write the command on the `run:` line. A block scalar's lines are not keys, so nothing here can tell them from a neighbouring value",
                    .{ path, lineno },
                );
                continue;
            }
            // 引用符付きのスカラーも同じコマンドである。引用符を残したままだと、
            // 正しいワークフローが何も実行しないものと読まれた。
            if (value.len >= 2 and (value[0] == '"' or value[0] == '\'') and
                value[value.len - 1] == value[0])
            {
                value = value[1 .. value.len - 1];
            }
            if (per_commit) try run_lines.append(gpa, value);
            if (is_slow) try slow_run_lines.append(gpa, value);
        }
    }

    // コミットごとのワークフローが走るかどうかを決めるキーと、それに与えてよい値。
    //
    // キーの集合を閉じても、値については何も言えなかった。`on:` ブロックの削除、
    // マトリクスがジョブを展開しないよう `os: []` と書くこと、存在しないランナーを
    // 指名することは、どれも `run:` 行を全部残し、全検証コマンドを緑のままにして、
    // CI は何も実行しなかった。このリポジトリが選ぶ値はキーと同じく有限なので、
    // 値も列挙する。
    for ([_]struct { key: []const u8, value: ?[]const u8 }{
        .{ .key = "on", .value = "" },
        // `jobs:` は許可集合にあったが必須ではなかった。そのため、これを消して
        // ジョブの字下げを戻すと、ジョブの無いワークフローが残り、`run:` 行は
        // 全部そのままだった。
        .{ .key = "jobs", .value = "" },
        .{ .key = "push", .value = "" },
        .{ .key = "branches", .value = "[main]" },
        .{ .key = "pull_request", .value = "" },
        .{ .key = "steps", .value = "" },
        .{ .key = "runs-on", .value = "${{ matrix.os }}" },
        .{ .key = "strategy", .value = "" },
        .{ .key = "matrix", .value = "" },
        .{ .key = "os", .value = "[ubuntu-latest]" },
    }) |want| {
        var found = false;
        for (seen.items) |got| {
            if (!std.mem.eql(u8, got.key, want.key)) continue;
            found = true;
            const expected = want.value orelse continue;
            if (!std.mem.eql(u8, got.value, expected)) rep.fail(
                "{s}: `{s}:` is `{s}`, and this check only knows `{s}`; decide what the new value means for the verification before changing it",
                .{ per_commit_workflow, want.key, got.value, expected },
            );
        }
        if (!found) rep.fail(
            "{s} has no `{s}:`, so the workflow does not run what the table requires",
            .{ per_commit_workflow, want.key },
        );
    }

    // 表の行として読める行をすべて集める。AGENTS.md の他の表はセルが少ないか、
    // バッククォートで囲んだコマンドが無いので、ここで落ちる。
    var table_rows: std.ArrayList(CommandRow) = .empty;
    var lines = std.mem.splitScalar(u8, table, '\n');
    while (lines.next()) |raw| {
        const row = std.mem.trim(u8, raw, &std.ascii.whitespace);
        if (row.len == 0 or row[0] != '|') continue;
        if (cellCount(row) < 4) continue;
        const command_cell = cellAt(row, 1).?;
        const command = backtickedSpan(command_cell) orelse continue;
        const stage_cell = std.mem.trim(u8, cellAt(row, 2).?, &std.ascii.whitespace);
        const ci_cell = std.mem.trim(u8, cellAt(row, 3).?, &std.ascii.whitespace);
        try table_rows.append(gpa, .{
            .command = command,
            .cell = command_cell,
            .stage = std.fmt.parseInt(usize, stage_cell, 10) catch null,
            .every_commit = std.mem.eql(u8, ci_cell, "全コミット"),
        });
    }

    // 層2には全コミットと印を付けた行がないので、下のループはそれを読まない。
    // その行は各コマンドを名指しし、層2のワークフローはそれを実行しなければならない。
    for (slow_commands) |command| {
        var in_table = false;
        for (table_rows.items) |row| {
            if (hasBacktickedSpan(row.cell, command)) in_table = true;
        }
        if (!in_table) rep.fail(
            "AGENTS.md's table has no row naming `{s}`, the slow tier's command",
            .{command},
        );
        var ran = false;
        for (slow_run_lines.items) |line| {
            if (runsCommand(line, command)) ran = true;
        }
        if (!ran) rep.fail(
            "the slow tier's command `{s}` is not run by {s}",
            .{ command, slow_workflow },
        );
    }

    // Windows のテストは層2のワークフローの windows ジョブで走る(ADR-0036)。
    // 移す前は ci.yml の `os` の値が Windows を固定していたが、移したあとは何も
    // 固定していなかった。ジョブを消す、Linux で走らせる、step を1つ落とす、
    // 自動の起動を外す、のどれも1箇所の編集で、全コマンドが緑のまま Windows の
    // テストが走らなくなった。
    //
    // 値は、どこか1箇所に現れればよい。`runs-on` は slow と dist の
    // `ubuntu-latest` もあるので、全部が一致することは求められない。2つのジョブの
    // `runs-on` を入れ替える編集はこれで見えないが、2箇所の編集を要する。
    // 綴りの一致なので、windows ジョブを matrix の形(`runs-on: ${{ matrix.os }}` と
    // `os: [windows-latest]`)に書き換える正当な編集も赤になり、そのときのメッセージは
    // Windows のテストが走らないと言うが、実際は走る。
    for ([_]struct { key: []const u8, value: []const u8 }{
        .{ .key = "pull_request", .value = "" },
        .{ .key = "types", .value = "[ready_for_review]" },
        .{ .key = "workflow_dispatch", .value = "" },
        .{ .key = "runs-on", .value = "windows-latest" },
    }) |want| {
        var found = false;
        for (slow_seen.items) |got| {
            if (std.mem.eql(u8, got.key, want.key) and std.mem.eql(u8, got.value, want.value)) found = true;
        }
        if (!found) rep.fail(
            "{s} has no `{s}: {s}`, so the Windows tests or the slow tier do not run when AGENTS.md says they do",
            .{ slow_workflow, want.key, want.value },
        );
    }

    // windows ジョブは ci.yml の test ジョブと同じ step を走らせる(ADR-0036)。
    // `runsCommand` でなく綴りの完全な一致で比べる。接尾辞を受理すると、
    // `--test-timeout` を落とした step も同じと読む。ci.yml に Linux だけで
    // 走らせる step を足すときは、ここで赤になる。そのときは、Windows で走らせない
    // ことの意味を決めてから、この照合を変える。
    for (run_lines.items) |line| {
        var ran = false;
        for (slow_run_lines.items) |slow| {
            if (std.mem.eql(u8, slow, line)) ran = true;
        }
        if (!ran) rep.fail(
            "{s} runs `{s}`, and {s} does not; its windows job runs the same steps as the per-commit job",
            .{ per_commit_workflow, line, slow_workflow },
        );
    }

    // ビルドが提供するから、表がそれを要求し、ワークフローがそれを実行する。
    //
    // これは3つ目の拠り所である。表とワークフローは互いにしか比べられておらず、
    // 両方を同時に弱めると緑のままだった。行をその step ごと消すと要求が消え、
    // 4つのコマンドのうち3つがこの形で消せた。`build.zig` はこれらを、提供する
    // step の名前で呼ぶ。1つ落とすには、その step を落とすことになる。
    for (required_commands) |command| {
        var in_table = false;
        for (table_rows.items) |row| {
            if (!std.mem.eql(u8, row.command, command)) continue;
            if (!row.every_commit) continue;
            const needed_at = row.stage orelse continue;
            if (needed_at > stage) continue;
            in_table = true;
        }
        if (!in_table) rep.fail(
            "build.zig provides `{s}`, and no row of AGENTS.md's table marks it 全コミット at stage {d} or below",
            .{ command, stage },
        );
        var ran = false;
        for (run_lines.items) |line| {
            if (runsCommand(line, command)) ran = true;
        }
        if (!ran) rep.fail(
            "build.zig provides `{s}`, and {s} does not run it",
            .{ command, per_commit_workflow },
        );
    }

    // 表が要求するから、ワークフローが実行する。
    var required: usize = 0;
    for (table_rows.items) |row| {
        if (!row.every_commit) continue;
        const needed_at = row.stage orelse continue;
        if (needed_at > stage) continue;
        required += 1;
        var ran = false;
        for (run_lines.items) |line| {
            if (runsCommand(line, row.command)) ran = true;
        }
        if (!ran) rep.fail(
            "AGENTS.md requires `{s}` on every commit at stage {d}, and {s} does not run it",
            .{ row.command, stage, per_commit_workflow },
        );
    }
    if (required == 0) rep.fail(
        "AGENTS.md has no command marked for every commit at stage {d}; the table was not read",
        .{stage},
    );

    // ワークフローが実行するから、表が要求する。この向きがあるから、先の向きは
    // セルを正確に読まなくても成り立つ。検査から見えない行は、裏付けの無い step
    // として現れる。
    for (run_lines.items) |line| {
        var accounted = false;
        for (table_rows.items) |row| {
            if (!runsCommand(line, row.command)) continue;
            if (!row.every_commit) continue;
            const needed_at = row.stage orelse continue;
            if (needed_at > stage) continue;
            accounted = true;
        }
        if (!accounted) rep.fail(
            "{s} runs `{s}`, and no row of AGENTS.md's table marks it 全コミット at stage {d} or below",
            .{ per_commit_workflow, line, stage },
        );
    }
}

/// The first text between backticks, which is where the table puts the command.
///
/// 型チェックの行のように、セルはコマンドの後ろに注記を持つことがある。
fn backtickedSpan(cell: []const u8) ?[]const u8 {
    const open = std.mem.indexOfScalar(u8, cell, '`') orelse return null;
    const rest = cell[open + 1 ..];
    const close = std.mem.indexOfScalar(u8, rest, '`') orelse return null;
    return if (close == 0) null else rest[0..close];
}

/// Whether `command` is one of the spans between backticks in `cell`.
///
/// 1つの行が2つのコマンドを名指しすることがあり、`backtickedSpan` は最初の1つしか
/// 読まない。
fn hasBacktickedSpan(cell: []const u8, command: []const u8) bool {
    var rest = cell;
    while (std.mem.indexOfScalar(u8, rest, '`')) |open| {
        const after = rest[open + 1 ..];
        const close = std.mem.indexOfScalar(u8, after, '`') orelse return false;
        if (std.mem.eql(u8, after[0..close], command)) return true;
        rest = after[close + 1 ..];
    }
    return false;
}

/// Keys a workflow may use. Anything else is reported.
///
/// 4巡のレビューが、この検査が読み違える YAML の綴りをそれぞれ別に見つけた。
/// step の最初のキーとして書いた `if:`、`env:` の下の `run` というキー、中身が
/// 実は兄弟の値だったブロックスカラー、キーの順序が違う step である。1つ塞ぐと
/// 次が現れた。任意の YAML に文字列照合を当てる限り、負ける綴りは尽きないからで
/// ある。
///
/// そこで集合を閉じる。未知のキーは穴でなく診断になり、1つ足すことは、それが
/// 検証に何をするかを決めることになる。`if:` と `continue-on-error:` は意図して
/// 入れていない。ワークフロー自身のコメントがこれを禁じている。飛ばされたり
/// 見逃されたりする検証は、走るのをやめているからである。
const allowed_workflow_keys = [_][]const u8{
    // ワークフローのレベル。
    "name",
    "on",
    "permissions",
    "concurrency",
    "jobs",
    "push",
    "pull_request",
    "branches",
    "contents",
    "group",
    "cancel-in-progress",
    "types",
    "workflow_dispatch",
    // 変更したファイルがすべて一致する PR では、ワークフローを起動しない。full.yml と
    // preview.yml が、文書だけの PR を外すために使う(docs/adr/0046-skip-slow-tier-for-docs-only-prs.md)。
    // 時機を絞るキーなので、コミットごとのワークフローには置けない(`isTriggerNarrowing`)。
    // `paths` は入れていない。どのワークフローにも置けず、置くと未知のキーとして赤になる。
    "paths-ignore",
    // 定期実行。fuzz.yml が使う。`cron` は `schedule` の下にだけ置ける。
    "schedule",
    "cron",
    // ジョブのレベル。
    "runs-on",
    "strategy",
    "fail-fast",
    "matrix",
    "steps",
    "os",
    // ジョブの時間の上限。上限を超えたジョブは失敗になるので、検証を黙って
    // 止めるのでなく、赤にする。
    "timeout-minutes",
    // step のレベル。
    "uses",
    "with",
    "version",
    "run",
    // actions/cache の入力と、setup-zig の自動キャッシュを切る入力。ADR-0032。
    "path",
    "key",
    "use-cache",
    // actions/upload-artifact の入力。ファイルが無いときは何も上げず、隠し
    // ディレクトリ(`.zig-cache`)の下のファイルも上げる。
    "retention-days",
    "if-no-files-found",
    "include-hidden-files",
    // タグの push を契機にする。release.yml が使う。`tags` は `push` の下にだけ置ける。
    "tags",
    // 環境変数。release.yml が使う。タグの名前は任意の文字を含みうるので、`run:` の行に
    // 式として埋め込むと、シェルの構文として読まれる。環境変数に入れて渡す。
    // `env` の下の `run` というキーは、step 自身のキーの桁にないので、`run:` として
    // 数えない(下の step の読み取りが見る)。
    "env",
    "TAG",
    "GH_TOKEN",
    // actions/checkout の入力。release.yml が、書き込み権限のトークンを後続の step に
    // 残さないために使う(`false`)。
    "persist-credentials",
};

/// Whether `key` is one of the allowed keys, or a job name.
///
/// ジョブ名はこのリポジトリが決めるので、一覧にできない。`jobs:` の下のジョブの
/// 字下げにあるキーは、その深さに紛らわしいものが他に無いワークフローでは受理
/// する。名前は `allowed_job_names` が持つ。
fn keyIsAllowed(key: []const u8) bool {
    for (allowed_workflow_keys) |allowed| {
        if (std.mem.eql(u8, key, allowed)) return true;
    }
    for (allowed_job_names) |job| {
        if (std.mem.eql(u8, key, job)) return true;
    }
    return false;
}

/// Keys that change when a workflow runs, which the per-commit workflow may not
/// carry.
///
/// ワークフローが走る時機を変えるキー。コミットごとのワークフローは持てない。
fn isTriggerNarrowing(key: []const u8) bool {
    return std.mem.eql(u8, key, "types") or
        std.mem.eql(u8, key, "workflow_dispatch") or
        std.mem.eql(u8, key, "paths-ignore") or
        std.mem.eql(u8, key, "schedule") or
        std.mem.eql(u8, key, "tags");
}

/// Keys the per-commit workflow may not carry: the ones that change when it runs,
/// and `env`.
///
/// コミットごとのワークフローが持てないキー。走る時機を変えるキーと `env` である。
/// `env` はブロック形では許可キー(`TAG` と `GH_TOKEN`)しか書けないが、フロー形と
/// 式の形は値を読まないので、`BASH_ENV` などでシェルの動作を変えて検査を黙って
/// 止める綴りが通る。ほかのワークフロー(`release.yml`)は `env` を持てる。
fn isForbiddenInPerCommit(key: []const u8) bool {
    return isTriggerNarrowing(key) or std.mem.eql(u8, key, "env");
}

/// The job names this repository's workflows define.
///
/// このリポジトリのワークフローが定義するジョブ名。
const allowed_job_names = [_][]const u8{ "test", "slow", "fuzz", "preview", "dist", "release", "windows" };

/// The key a mapping line declares, or null when the line is not `key: ...`.
///
/// 裸のキーだけを数える。引用符もコロンの前の空白も認めない。マッピングに見える
/// それ以外は呼び出し側が報告する。引用符付きのキーは Actions にとって同じキー
/// だからである。null を返して呼び出し側に飛ばさせたせいで、
/// `"continue-on-error": true` と `continue-on-error : true` がどちらも通った。
fn yamlKey(line: []const u8) ?[]const u8 {
    const colon = std.mem.indexOfScalar(u8, line, ':') orelse return null;
    if (colon == 0) return null;
    const key = line[0..colon];
    for (key) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_') return null;
    }
    return key;
}

/// Suffixes a workflow may add to a command from the table.
///
/// 形でなく一覧にする。フラグに見えるものを何でも受理すると、コマンドを打ち消す
/// フラグまで受理した。`zig build test --help` はテストを走らせずに0で終了する。
/// 検証コマンドをすべてその綴りにすると、ソースがパースできないリポジトリでも
/// 全行が実行されたと報告された。コマンドの動作を変える接尾辞は、ここに意図して
/// 足さなければならない。
///
/// `--test-timeout` は、1件のテストが値を超えたとき、そのテストを名指しして失敗に
/// する。通常の実行の無限ループが、ジョブの時間切れまで黙って待たせるのを防ぐ。
/// 値は ci.yml が使うものを綴りごと固定する。値を変えるときは、ここを意図して
/// 変える。
const allowed_run_suffixes = [_][]const u8{
    "--summary all",
    "--summary all --test-timeout 60s",
};

/// Whether a workflow's `run:` value runs `command`.
///
/// ワークフローの `run:` の値が `command` を実行するか。
fn runsCommand(line: []const u8, command: []const u8) bool {
    if (std.mem.eql(u8, line, command)) return true;
    if (!std.mem.startsWith(u8, line, command)) return false;
    if (line.len == command.len or line[command.len] != ' ') return false;
    const rest = std.mem.trimStart(u8, line[command.len..], " ");
    for (allowed_run_suffixes) |suffix| {
        if (std.mem.eql(u8, rest, suffix)) return true;
    }
    return false;
}

/// How deeply a line is indented, in columns.
///
/// 何を字下げと数えるか、またその理由は `indentRun` が持つ。ここで言い直すと
/// 両者がずれた。実装がタブを数え始めた後も、このコメントはタブを数えないと言い
/// 続け、1つの関数の挙動をファイルが同時に2通りに説明していた。
fn indentOf(raw: []const u8) usize {
    return indentRun(raw).cols;
}

/// The run of leading whitespace: how many columns a reader sees, and how many
/// bytes it occupies.
///
/// 両方が要る。桁数は字下げの意味を決め、バイト数は行の内容が始まる位置である。
///
/// 数えるのは空白とタブだけである。YAML が字下げに認めるのは空白だけで、読み手が
/// 字下げと取り違えうるほかの文字は、ADR-0026 が取り下げた検査のためにここに
/// あった。
fn indentRun(raw: []const u8) struct { cols: usize, bytes: usize } {
    var cols: usize = 0;
    var i: usize = 0;
    while (i < raw.len) : (i += 1) {
        if (raw[i] == ' ') {
            cols += 1;
            continue;
        }
        // タブは、CommonMark の定義どおり、次の4桁の区切りまで進める。
        if (raw[i] == '\t') {
            cols += 4 - cols % 4;
            continue;
        }
        break;
    }
    return .{ .cols = cols, .bytes = i };
}

/// Removes a trailing YAML comment. A `#` opens a comment at the start of the
/// line or after whitespace, and not inside a quoted scalar.
///
/// 行から何かを取り出す前に、すべての行でコメントを除く。そうしないと、`uses:`
/// 行のコメントに書いた `version:` が検査される版になり、次の行にある本物は読まれ
/// なかった。`uses: ...setup-zig@v2  # version: 0.17.0` と書いた step の下に
/// `version: 0.18.1` があると、検査は通るのに CI は 0.18.1 を入れた。
///
/// `#` の前に閉じていない引用符があると、コメントは残る。これは置き換え前の挙動に
/// 戻るだけである。そのような行は YAML としても不正で、Actions はワークフローを
/// 拒否するから、入れる版は問題にならない。
///
/// `#` の前にあった空白は結果に残る。呼び出し側が trim する。
fn stripComment(line: []const u8) []const u8 {
    var quote: ?u8 = null;
    for (line, 0..) |c, i| {
        if (quote) |q| {
            if (c == q) quote = null;
            continue;
        }
        switch (c) {
            '\'', '"' => quote = c,
            '#' => if (i == 0 or std.ascii.isWhitespace(line[i - 1])) return line[0..i],
            else => {},
        }
    }
    return line;
}

/// Counts non-overlapping occurrences of `needle` in `haystack`.
///
/// `haystack` の中の `needle` の出現を、重ならないように数える。
fn countOccurrences(haystack: []const u8, needle: []const u8) usize {
    var found: usize = 0;
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, from, needle)) |at| {
        found += 1;
        from = at + needle.len;
    }
    return found;
}

/// What one setup-zig step installs.
///
/// setup-zig の1つの step が入れるもの。
const StepVersion = struct {
    /// Null when this parser could not read a version for the step.
    version: ?[]const u8 = null,
    /// Another `version:` appeared under the same `with:`.
    ///
    /// その step は読めないものとして扱う。アクションがどちらを採るかは、この
    /// パーサが推測すべきことでない。
    extra: bool = false,
};

/// Collects what each setup-zig step installs, one entry per step in document
/// order.
///
/// step は、行のどこかにある `setup-zig@` の参照で認識する。step のどんな YAML
/// 綴りも見えるようにするためである。リスト項目レベルのフローマッピングと、
/// 引用符付きの `uses:` キーは、どちらも Zig を入れるのに、`uses:` で始まる
/// 照合では見落とす。`@` を要求するから、名前が「prepare for setup-zig」という
/// だけの step が、検査される版を供給することはない。
///
/// 版として数えるのは、step 自身の `with:` の直下で、1行を独立して使っている
/// ものだけである。もっと弱い規則を2つ先に試し、どちらもおとりを通した。step の
/// 行にある任意の `version:` と、step より深く字下げされた任意の `version:` で
/// ある。後者は `env:` など、step が持ちうるほかのキーまで受理した。また版は、
/// 数えるのでなく、それを読んだ step に結びつける。step が2つあると、片方の版が
/// 2という数を満たし、もう片方は何を入れてもよくなった。
fn workflowZigVersions(
    gpa: std.mem.Allocator,
    body: []const u8,
    out: *std.ArrayList(StepVersion),
) !void {
    // 版を探している step を持つ項目の字下げ、その step の `with:` の字下げ、
    // そのマッピング自身のキーの字下げ。どれも、その中にいないときは null。
    var step_indent: ?usize = null;
    var with_indent: ?usize = null;
    var input_indent: ?usize = null;
    // 読んでいるリスト項目の字下げ。これが step 自身の字下げである。
    var item_indent: usize = 0;
    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |raw| {
        const indent = indentOf(raw);
        var line = std.mem.trim(u8, raw, &std.ascii.whitespace);
        line = std.mem.trim(u8, stripComment(line), &std.ascii.whitespace);
        if (line.len == 0) continue;

        const is_item = std.mem.startsWith(u8, line, "- ");
        const body_of_item = if (is_item) std.mem.trim(u8, line[2..], &std.ascii.whitespace) else line;
        // step はリスト項目であり、そのキーはどんな順序でもよい。`setup-zig@` を
        // 持つ行の字下げを取ると、`name:` を先に書いたときに step が自分の
        // `with:` で終わってしまった。これは普通の綴りである。版が読めないと判定され、
        // 正しいワークフローが、すでに正しい位置にある `version:` を動かせと言われた。
        if (is_item) item_indent = indent;

        // step 自身の項目より深く字下げされていない行は、その step の外である。
        // `with:` より深くない行は、そのマッピングの外である。
        if (step_indent) |si| if (indent <= si) {
            step_indent = null;
            with_indent = null;
            input_indent = null;
        };
        if (with_indent) |wi| if (indent <= wi) {
            with_indent = null;
            input_indent = null;
        };
        // 行が setup-zig の参照を持てば、それを保持する YAML の綴りが何であれ、
        // step として数える。行が `uses:` で始まることを要求すると、リスト項目
        // レベルのフローマッピングと引用符付きのキーを見落とす。どちらも、この
        // パーサに見えない Zig を入れる。
        //
        // 参照は最初の1つだけでなく、行にある全部を数える。1行に setup-zig の step を2つ
        // 持つフローシーケンスは1つの step と読まれ、2つ目の step の版は検査され
        // なかった。全部数えると、呼び出し側の step 対 version の比較がその行を
        // 拒否する。
        //
        // この行からは、何が書かれていても版を読まない。版を読むことが、これまで
        // 見つかったおとりすべての担い手だった。コメント内の `version:`、本物の前に
        // ある `name:` の値の中の `version:`、本物が無いのに `name:` の値の中にある
        // `version:` である。1つ塞ぐと次が現れた。アクションを名指す行は、任意の
        // 文章を載せられる行でもあるからである。そのため受理する綴りは、step の下の
        // 独立した行の `version:` だけにした。フローマッピングはすべて呼び出し側の
        // 比較で、まさにそう言う診断とともに失敗する。
        const refs = countOccurrences(line, "setup-zig@");
        if (refs != 0) {
            for (0..refs) |_| try out.append(gpa, .{});
            step_indent = item_indent;
            with_indent = null;
            input_indent = null;
            continue;
        }
        // 別の `uses:` は別の step である。この step より深く入れ子になっていても
        // 同じである。
        if (std.mem.startsWith(u8, body_of_item, "uses:")) {
            step_indent = null;
            with_indent = null;
            input_indent = null;
            continue;
        }
        if (step_indent == null) continue;
        if (std.mem.eql(u8, body_of_item, "with:")) {
            with_indent = indent;
            input_indent = null;
            continue;
        }
        if (with_indent == null) continue;
        // 入力は `with:` の直下のキーであり、アクションが `version` を読む場所で
        // ある。もっと深く字下げされた行を何でも取ると、入力の下に入れ子になった
        // キーが版を供給でき、アクション自身の `version` 入力は未設定のままだった。
        if (input_indent == null) input_indent = indent;
        if (indent != input_indent.?) continue;
        if (std.mem.startsWith(u8, body_of_item, "version:")) {
            const scalar = std.mem.trim(u8, body_of_item["version:".len..], &std.ascii.whitespace);
            const value = std.mem.trim(u8, scalar, "\"'");
            if (value.len == 0) continue;
            const step = &out.items[out.items.len - 1];
            if (step.version == null) step.version = value else step.extra = true;
        }
    }
}

// ---------------------------------------------------------------------------
// 2. ベンダリングした入力が、来歴ファイルの記録するハッシュと一致する。
//
// SOURCE.md はこのハッシュを、ADR-0013 の「取り込んだファイルを変更しない」を
// 検証する手段と呼ぶ。何も照合しない表に記録しただけでは、主張に仕組みが無い。
// HTML を編集して再抽出しても、全検査が緑のままだった。
// ---------------------------------------------------------------------------

/// Files whose content is fixed by a recorded hash, with the document that
/// records it.
///
/// ハッシュはその文書から読むので、写しは1つしかない。
const vendored = [_]Record{
    .{
        .path = "tools/extract-r7rs-required/appendix-a.html",
        .provenance = "tools/extract-r7rs-required/SOURCE.md",
        .label = "入力の SHA-256",
    },
};

/// Directories whose generated contents are fixed as a whole by one recorded
/// hash, with the file extension that selects them.
///
/// 入力のハッシュだけでは、出力が守られなかった。`base.txt` から `dynamic-wind`
/// と `call-with-current-continuation` を消し、でっち上げた名前を足しても、入力の
/// ハッシュは変わらず、全検査が緑のままだった。これらのファイルは、生成物であり
/// 手で編集してはならないと自称するが、それを強制するものが無かった。これらは
/// 段階6の準拠マトリクスの分母である。
///
/// ハッシュ1つがディレクトリ全体を覆うので、再生成で更新する値はファイルごとで
/// なく1つで済む。各ファイル名は内容とともにハッシュし、両方に長さ接頭辞を付ける。
/// これで符号化が単射になる。ファイルの追加・削除・改名、ファイル境界をまたぐ
/// バイトの移動は、いずれも値を変える。
///
/// 長さ接頭辞が無いときは、そうならなかった。バイト列は
/// `name "\n" body name "\n" body ...` で、本体の後に区切りが無かった。そのため
/// `inexact.txt` の末尾に `lazy.txt` 自身の名前と内容を足して `lazy.txt` を消して
/// も、ハッシュは変わらなかった。16ファイルでなく15ファイルで全検査が通り、
/// `(scheme lazy)` の5つの識別子が `(scheme inexact)` に付け替えられた。16個
/// すべてを `base.txt` にまとめても通った。
const generated = [_]struct {
    dir: []const u8,
    extension: []const u8,
    provenance: []const u8,
    label: []const u8,
    /// The row label in `provenance` carrying the total of the per-file counts.
    ///
    /// `provenance` の中で、ファイルごとの件数の合計を持つ行のラベル。
    total_label: []const u8,
    /// The row label carrying how many files there should be.
    ///
    /// これが無いと、ファイル数と記録された行は互いに一致すればよいだけで、
    /// ファイルとその行を一緒に消しても通った。
    count_label: []const u8,
}{
    .{
        .dir = "tests/r7rs-required",
        .extension = ".txt",
        .provenance = "tools/extract-r7rs-required/SOURCE.md",
        .label = "抽出結果の SHA-256",
        .total_label = "| 合計 |",
        .count_label = "| ライブラリ数 |",
    },
};

/// One hash record: what is hashed, which document records it, and the table
/// label that carries the value.
///
/// ハッシュ1件の記録。何をハッシュするか、どの文書が記録するか、値を持つ表の
/// ラベルは何か。
const Record = struct {
    path: []const u8,
    provenance: []const u8,
    /// Looked up verbatim, so it is spelled as the document spells it.
    ///
    /// 同じ文書の2つの記録には、互いの部分文字列にならないラベルが要る。そうで
    /// ないと、それぞれが相手の値まで見つけてしまう。
    label: []const u8,
};

fn checkVendoredHashes(
    gpa: std.mem.Allocator,
    io: std.Io,
    cwd: std.Io.Dir,
    rep: *Reporter,
) !void {
    for (vendored) |v| {
        const body = read(gpa, io, cwd, rep, v.path) orelse continue;
        const raw_doc = read(gpa, io, cwd, rep, v.provenance) orelse continue;
        const doc = try visibleMarkdown(gpa, rep, v.provenance, raw_doc);

        const recorded = switch (sha256InMarkdown(doc, v.label)) {
            .one => |h| h,
            .ambiguous => {
                rep.fail(
                    "{s}: the {s} row holds more than one hash; leave exactly one",
                    .{ v.provenance, v.label },
                );
                continue;
            },
            .none => {
                rep.fail("{s} records no {s} for {s}", .{ v.provenance, v.label, v.path });
                continue;
            },
        };

        var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(body, &digest, .{});
        var hex: [digest.len * 2]u8 = undefined;
        _ = std.fmt.bufPrint(&hex, "{x}", .{&digest}) catch unreachable;

        // 大文字小文字はハッシュの一部でないから、大文字で書いた記録は、変更された
        // 入力ではない。
        if (!std.ascii.eqlIgnoreCase(&hex, recorded))
            rep.fail(
                "{s} is {s} but {s} records {s}",
                .{ v.path, hex[0..16], v.provenance, recorded[0..@min(16, recorded.len)] },
            );
    }
}

/// Blanks out what a reader of the rendered document does not see: HTML
/// comments and fenced code blocks.
///
/// このプログラムが読む表は、読み手がすべてこの結果を通す。ハッシュの行、件数の
/// 表、検証コマンドの表、ADR の索引である。記録は、人が最新に保つよう言われる
/// ものだから、誰にも見えない場所にしか無いものは記録でない。識別子の件数表を
/// `<!--` と `-->` で包むと、描画されたページから表が消えるのに全検査が緑の
/// ままだった。ADR の索引を包んでも同じだった。削除でなく空白化するのは、行と
/// バイトのオフセットを保ち、診断が正しい位置を指し続けるためである。
///
/// 閉じていない開始記号は報告し、走査はそれを越えて進める。そうすれば、その下の
/// 行は読めるままになる。代わりに文書の末尾まで空白化すると、下の行がすべて
/// 無いものとして読まれ、理由を言う検査も無かった。そこで走査を止めると、以降の
/// コメントがすべて空白化されないまま残った。
///
/// 開始記号は、行の先頭だけでなく、行のどこにあっても数える。CommonMark は
/// インラインの生 HTML コメントをそのまま出力し、ブラウザはブロックのコメントと
/// 同じように隠す。そのため、コメントアウトした値を、見える値の前に置いた行は、
/// 読み手には見える値を見せ、検査には隠れた値を渡した。代わりに、記号がコード
/// スパンの中にあるかを判定するには、このプログラムが持たないインラインパーサが
/// 要る。試みは2回失敗した。対にならないバッククォート1つでコメントを隠してしまう
/// ものと、バッククォート2つのスパンを空のスパンと開始記号として読むものである。
/// そのためコードスパンの例外は設けず、代償として、このリポジトリの Markdown の
/// 散文はリテラルの記号を書けない。閉じていないものは報告されるので、代償は黙って
/// でなく診断として支払われる。
fn visibleMarkdown(
    gpa: std.mem.Allocator,
    rep: *Reporter,
    path: []const u8,
    doc: []const u8,
) ![]u8 {
    const out = try gpa.dupe(u8, doc);
    var fence: ?struct { ch: u8, len: usize, indent: usize } = null;
    var i: usize = 0;
    while (i < out.len) {
        // 1行ずつ見る。フェンスが開く位置でフェンスと認識するためである。
        const end = std.mem.indexOfScalarPos(u8, out, i, '\n') orelse out.len;
        const line = out[i..end];
        const run = indentRun(line);

        var blank_line = false;
        if (fenceRun(line[run.bytes..])) |f| {
            if (fence) |open| {
                if (f.bare and f.ch == open.ch and f.len >= open.len) fence = null;
            } else {
                fence = .{ .ch = f.ch, .len = f.len, .indent = run.cols };
            }
            blank_line = true;
        } else if (fence) |open| {
            // フェンスの中と見なすのは、フェンス以上に字下げされている間だけである。
            // フェンスを見せているインデントされたコードブロックはフェンスでない。
            // そのため、そうした2行の間にある桁0の行は読み手に見える内容であり、
            // それを空白化すると、件数表がそれを読む検査から隠れた。
            blank_line = run.cols >= open.indent;
        }
        if (blank_line) blankExceptNewlines(line);
        i = end + 1;
    }

    // HTML コメントは複数行にわたるので、文書全体で空白化する。字下げされた行を
    // 空白化した後でなく、前に行う。先に空白化すると、1〜3桁字下げされた開始記号が
    // 空白になって見つからず、読み手から隠れているはずの表が、あるものとして
    // 読まれた。
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, out, from, "<!--")) |open| {
        const close = std.mem.indexOfPos(u8, out, open, "-->") orelse {
            rep.fail(
                "{s}:{d}: this HTML comment is never closed, which would hide every record below it",
                .{ path, lineOf(out, open) },
            );
            // ループを抜けず、この開始記号を越えて進む。止めると以降のコメントが
            // すべて空白化されないまま残り、閉じていない記号が1つあるだけで、閉じた
            // コメントが隠す記録が、読まれる記録に戻ってしまった。
            from = open + 4;
            continue;
        };
        blankExceptNewlines(out[open .. close + 3]);
        from = close + 3;
    }

    blankIndentedCode(out);
    return out;
}

/// The 1-based line number of `offset`.
fn lineOf(doc: []const u8, offset: usize) usize {
    var n: usize = 1;
    for (doc[0..@min(offset, doc.len)]) |c| {
        if (c == '\n') n += 1;
    }
    return n;
}

/// The number of cells a table row declares, counting an escaped pipe as text.
///
/// GFM は行を開くパイプと閉じるパイプを任意にしている。そのため、残りを区切りと
/// して数える前に、この2つを取り除く。パイプを数えて1を引く方法は、両方を持つ行
/// でしか正しくなかった。この数は、AGENTS.md の表の行が、このプログラムの読む
/// 4つのセルを持つかを決める。
///
/// `line` は trim 済みを前提とするので、閉じるパイプは最後のバイトである。
fn cellCount(line: []const u8) usize {
    var body = line;
    if (body.len != 0 and body[0] == '|') body = body[1..];

    var cells: usize = 1;
    var closed = false;
    var i: usize = 0;
    while (i < body.len) : (i += 1) {
        if (body[i] == '\\') {
            i += 1; // エスケープされた文字。パイプでもそうでなくても飛ばす
            closed = false;
            continue;
        }
        if (body[i] != '|') {
            closed = false;
            continue;
        }
        cells += 1;
        closed = i + 1 == body.len;
    }
    return if (closed) cells - 1 else cells;
}

/// The cell at `index` of a table row, counting from zero, untrimmed.
///
/// 分割は `cellCount` に従う。開くパイプと閉じるパイプは任意で、エスケープされた
/// パイプは文字である。`splitScalar(u8, row, '|')` でセルを読むと、同じ行で
/// 数と異なる答えが出た。
fn cellAt(row: []const u8, index: usize) ?[]const u8 {
    var body = row;
    if (body.len != 0 and body[0] == '|') body = body[1..];

    var at: usize = 0;
    var start: usize = 0;
    var i: usize = 0;
    while (i < body.len) : (i += 1) {
        if (body[i] == '\\') {
            i += 1; // エスケープされた文字。パイプでもそうでなくても飛ばす
            continue;
        }
        if (body[i] != '|') continue;
        if (at == index) return body[start..i];
        at += 1;
        start = i + 1;
        // 末尾のパイプは行を閉じるので、その後にセルは無い。
        if (i + 1 == body.len) return null;
    }
    return if (at == index) body[start..] else null;
}

test "cellCount: the pipes that open and close a row are optional" {
    try std.testing.expectEqual(@as(usize, 2), cellCount("| a | b |"));
    try std.testing.expectEqual(@as(usize, 2), cellCount("| a | b"));
    try std.testing.expectEqual(@as(usize, 2), cellCount("a | b"));
    try std.testing.expectEqual(@as(usize, 1), cellCount("| a |"));
    // これが固定する欠陥: 閉じるパイプを省いた行は、省かない行と同じ数のセルを
    // 持つ。そのため、数はパイプだけからは読み取れない。
    try std.testing.expectEqual(@as(usize, 3), cellCount("| a | b | c"));
    // エスケープされたパイプはセルの文字である。
    try std.testing.expectEqual(@as(usize, 1), cellCount("| a \\| b |"));
}

test "cellAt: reads the same cells cellCount counts" {
    try std.testing.expectEqualStrings(" a ", cellAt("| a | b |", 0).?);
    try std.testing.expectEqualStrings(" b ", cellAt("| a | b |", 1).?);
    try std.testing.expectEqual(@as(?[]const u8, null), cellAt("| a | b |", 2));
    // cellCount と同じく、開くパイプと閉じるパイプは任意である。
    try std.testing.expectEqualStrings("a ", cellAt("a | b", 0).?);
    try std.testing.expectEqualStrings(" b", cellAt("a | b", 1).?);
    try std.testing.expectEqualStrings(" b", cellAt("| a | b", 1).?);
    // エスケープされたパイプは、そのセルの中にとどまる。
    try std.testing.expectEqualStrings(" a \\| b ", cellAt("| a \\| b |", 0).?);
}

/// Blanks every indented line, so that only column zero carries a record.
///
/// 4つの空白が何を意味するかは、それを含むブロックで決まる。最上位では
/// コードブロックを開く。リスト項目の中では項目の続きになるか、入れ子のリストを
/// 開き、テキストとして描画される。CommonMark は次のように述べる。"The position of the
/// text after the list marker determines how much indentation is needed in
/// subsequent blocks in the list item." この2つを見分ける試みは2回とも、どちらかの
/// 向きで失敗した。すべてを空白化すると見える注記が隠れ、空行の後のものだけを
/// 空白化すると入れ子のおとりを状態として読んだ。
///
/// そこで字下げはまったく解釈しない。記録は、人が最新に保つよう言われるものであり、
/// このリポジトリが持つ記録は、ハッシュの行、件数の表、コマンドの表、ADR の
/// メタデータと索引の行のすべてが桁0にある。桁0にない行は、描画結果が何で
/// あっても読まない。代償として、記録をリストの中に入れ子にはできない。
fn blankIndentedCode(out: []u8) void {
    var line_start: usize = 0;
    while (line_start < out.len) {
        const line_end = std.mem.indexOfScalarPos(u8, out, line_start, '\n') orelse out.len;
        const line = out[line_start..line_end];
        if (indentOf(line) != 0 and std.mem.trim(u8, line, &std.ascii.whitespace).len != 0)
            blankExceptNewlines(line);
        line_start = line_end + 1;
    }
}

fn blankExceptNewlines(span: []u8) void {
    for (span) |*c| {
        if (c.* != '\n' and c.* != '\r') c.* = ' ';
    }
}

/// What a Markdown document records as the SHA-256 of a vendored input.
///
/// Markdown 文書がベンダリングした入力の SHA-256 として記録しているもの。
const RecordedHash = union(enum) {
    /// One value appears on the lines naming SHA-256.
    one: []const u8,
    none,
    /// Several differing values appear, so which one is the record cannot be
    /// decided from the document.
    ///
    /// 異なる値が複数あるので、どれが記録なのかは文書から決められない。
    ambiguous,
};

/// Finds the SHA-256 a Markdown document records under `label`.
///
/// `label` を含む行をすべて走査し、各行の64桁の16進数の連なりをすべて集める。
/// 最初の行の最初の連なりを返すのではない。最初のものを返すと、おとりが値を
/// 供給できた。同じ表の行で本物の前に、HTML コメントの中に2つ目の64桁の16進数を
/// 置くと、描画された表は本物のハッシュを見せるのに、この関数は隠れた方を返した。
/// すり替えた入力が緑で比較を通り、そのすり替えは文書を読む誰にも見えなかった。
/// 古いハッシュを書いた2つ目の行も同じだった。
fn sha256InMarkdown(doc: []const u8, label: []const u8) RecordedHash {
    var found: ?[]const u8 = null;
    var lines = std.mem.splitScalar(u8, doc, '\n');
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, label) == null) continue;
        var i: usize = 0;
        while (i + 64 <= line.len) : (i += 1) {
            const candidate = line[i .. i + 64];
            var all_hex = true;
            for (candidate) |c| {
                if (!std.ascii.isHex(c)) all_hex = false;
            }
            if (!all_hex) continue;
            if (found) |first| {
                if (!std.ascii.eqlIgnoreCase(first, candidate)) return .ambiguous;
            } else found = candidate;
        }
    }
    return if (found) |h| .{ .one = h } else .none;
}

// ---------------------------------------------------------------------------
// 3 と 4. src/ のすべてのファイルがテストルートから到達でき、兄弟を import する
// すべてのファイルが refAllDecls で参照を張り直す。
//
// Zig がファイルの `test` ブロックを解析するのは、そのファイルにテストルートから
// 到達したときだけである。参照されないファイルのテストは黙って飛ばされる。
// refAllDecls は1段しか下りず、refAllDeclsRecursive は Zig 0.17.0 に存在しない。
// そのため参照は、各段で張り直さなければならない。
// ---------------------------------------------------------------------------

/// Checks one hash over all the generated files in a directory.
///
/// 診断は、接頭辞でなく、計算したハッシュ全体を出力する。ファイルを再生成する
/// とは、その値を来歴文書に貼ることである。接頭辞では、読み手がもう一度手で
/// 計算しに行くことになる。
fn checkGeneratedHashes(
    gpa: std.mem.Allocator,
    io: std.Io,
    cwd: std.Io.Dir,
    rep: *Reporter,
    ignore: []const u8,
) !void {
    for (generated) |g| {
        try checkNothingElseInDir(io, cwd, rep, ignore, g.dir, g.extension);
        var files: std.ArrayList([]const u8) = .empty;
        try collectFiles(gpa, io, cwd, ignore, g.dir, g.extension, &files, .flat);
        if (files.items.len == 0) {
            rep.fail("{s} holds no {s} file, so the generated lists are unchecked", .{ g.dir, g.extension });
            continue;
        }
        // ディレクトリの順序はファイルシステムが返すままなので、整列する。同じ内容は
        // どのホストでも同じハッシュにならなければならない。
        std.mem.sort([]const u8, files.items, {}, lessThanPath);

        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        var unread = false;
        for (files.items) |path| {
            const body = read(gpa, io, cwd, rep, path) orelse {
                unread = true;
                continue;
            };
            hashLengthPrefixed(&hasher, path);
            hashLengthPrefixed(&hasher, body);
        }
        // このプログラムが読めなかったファイルは報告済みである。残りから計算した
        // ハッシュを比べると、紛らわしい2つ目の問題を足すことになる。
        if (unread) continue;

        var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
        hasher.final(&digest);
        var hex: [digest.len * 2]u8 = undefined;
        _ = std.fmt.bufPrint(&hex, "{x}", .{&digest}) catch unreachable;

        const raw_doc = read(gpa, io, cwd, rep, g.provenance) orelse continue;
        const doc = try visibleMarkdown(gpa, rep, g.provenance, raw_doc);
        switch (sha256InMarkdown(doc, g.label)) {
            .one => |recorded| if (!std.ascii.eqlIgnoreCase(&hex, recorded)) rep.fail(
                "{s}/*{s} hashes to {s} but {s} records {s}",
                .{ g.dir, g.extension, &hex, g.provenance, recorded },
            ),
            .ambiguous => rep.fail(
                "{s}: the {s} row holds more than one hash; leave exactly one",
                .{ g.provenance, g.label },
            ),
            .none => rep.fail(
                "{s} records no {s}; {s}/*{s} hashes to {s}",
                .{ g.provenance, g.label, g.dir, g.extension, &hex },
            ),
        }
    }
}

fn lessThanPath(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// Feeds `bytes` to `hasher` behind its length, so that a sequence of such
/// calls has exactly one reading.
///
/// 連結だけではそうならない。2つの断片の境界を動かしても、同じバイト列が残る。
fn hashLengthPrefixed(hasher: *std.crypto.hash.sha2.Sha256, bytes: []const u8) void {
    var len: [8]u8 = undefined;
    std.mem.writeInt(u64, &len, bytes.len, .little);
    hasher.update(&len);
    hasher.update(bytes);
}

/// Whether the source declares at least one `test` block at container level.
///
/// 検索でなく字句解析で見る。「test」という語はこのリポジトリのパス、コメント、
/// 文字列のいたるところに現れ、生の検索では、1つも宣言していないファイルまで
/// 受理してしまう。
fn hasTestBlock(source: [:0]const u8) bool {
    var tok = std.zig.Tokenizer.init(source);
    var depth: usize = 0;
    while (true) {
        const t = tok.next();
        switch (t.tag) {
            .eof => return false,
            .l_brace => depth += 1,
            .r_brace => if (depth > 0) {
                depth -= 1;
            },
            .keyword_test => if (depth == 0) return true,
            else => {},
        }
    }
}

/// Checks the identifier counts a provenance document records against the
/// generated files.
///
/// ハッシュが言うのは、ファイルが変わったことであって、その横に書かれた数が今も
/// 成り立つことではない。その数は手で更新する(再抽出手順の手順5)ものであり、
/// 照合するものが無かった。そのため、エクスポート一覧のパースが止まったライブラリが、
/// 文書では識別子1個、ファイルでは0個と読めてしまう。段階6の準拠マトリクスは
/// これらのファイルを分母にするので、この食い違いは完全準拠として読まれる。
fn checkRecordedCounts(
    gpa: std.mem.Allocator,
    io: std.Io,
    cwd: std.Io.Dir,
    rep: *Reporter,
    ignore: []const u8,
) !void {
    for (generated) |g| {
        const raw_doc = read(gpa, io, cwd, rep, g.provenance) orelse continue;
        const doc = try visibleMarkdown(gpa, rep, g.provenance, raw_doc);
        var files: std.ArrayList([]const u8) = .empty;
        try collectFiles(gpa, io, cwd, ignore, g.dir, g.extension, &files, .flat);

        var total: usize = 0;
        for (files.items) |path| {
            const body = read(gpa, io, cwd, rep, path) orelse continue;
            const count = identifierCount(body);
            total += count;

            const stem = std.fs.path.stem(path);
            const label = try std.fmt.allocPrint(gpa, "`(scheme {s})`", .{stem});
            switch (integerAfter(doc, label)) {
                .one => |recorded| if (recorded != count) rep.fail(
                    "{s} holds {d} identifier(s) but {s} records {d}",
                    .{ path, count, g.provenance, recorded },
                ),
                .none => rep.fail(
                    "{s} records no identifier count for {s}",
                    .{ g.provenance, label },
                ),
                .ambiguous => rep.fail(
                    "{s} records more than one count for {s}; leave exactly one",
                    .{ g.provenance, label },
                ),
            }
        }

        // 逆の向き。ファイルだけを歩くと、ファイルの裏付けが無い記録済みの行が
        // 調べられないままだった。`lazy.txt` を消し、診断が報告するハッシュを貼り、
        // 合計を直すと、全検査が通った。表には行が残り、散文は16ファイルと言った
        // ままで、ディスク上は15ファイルだった。段階6のマトリクスはこのディレクトリを
        // 分母にするので、そのライブラリの識別子は、未実装として現れるのでなく、
        // 分母から消える。
        var rows: usize = 0;
        var lines = std.mem.splitScalar(u8, doc, '\n');
        while (lines.next()) |raw| {
            const row = std.mem.trim(u8, raw, &std.ascii.whitespace);
            if (row.len == 0 or row[0] != '|') continue;
            var from: usize = 0;
            while (std.mem.indexOfPos(u8, row, from, "`(scheme ")) |at| {
                const name_start = at + "`(scheme ".len;
                const close = std.mem.indexOfPos(u8, row, name_start, ")`") orelse break;
                from = close + 2;
                const name = row[name_start..close];
                rows += 1;
                const want = try std.fmt.allocPrint(gpa, "{s}/{s}{s}", .{ g.dir, name, g.extension });
                if (!pathIn(files.items, want)) rep.fail(
                    "{s} records `(scheme {s})` but {s} does not exist",
                    .{ g.provenance, name, want },
                );
            }
        }
        switch (integerAfter(doc, g.count_label)) {
            .one => |recorded| if (recorded != files.items.len) rep.fail(
                "{s} records {d} librar(ies) but {s} holds {d} *{s} file(s)",
                .{ g.provenance, recorded, g.dir, files.items.len, g.extension },
            ),
            .none => rep.fail("{s} records no {s}", .{ g.provenance, g.count_label }),
            .ambiguous => rep.fail(
                "{s} records more than one {s}; leave exactly one",
                .{ g.provenance, g.count_label },
            ),
        }
        if (rows != files.items.len) rep.fail(
            "{s} records {d} librar(ies) but {s} holds {d} *{s} file(s)",
            .{ g.provenance, rows, g.dir, files.items.len, g.extension },
        );

        switch (integerAfter(doc, g.total_label)) {
            .one => |recorded| if (recorded != total) rep.fail(
                "{s}/*{s} hold {d} identifier(s) in all but {s} records {d}",
                .{ g.dir, g.extension, total, g.provenance, recorded },
            ),
            .none => rep.fail("{s} records no {s}", .{ g.provenance, g.total_label }),
            .ambiguous => rep.fail(
                "{s} records more than one {s}; leave exactly one",
                .{ g.provenance, g.total_label },
            ),
        }
    }
}

/// Counts the identifier lines of a generated list: the lines that are neither
/// blank nor a `;` comment.
fn identifierCount(body: []const u8) usize {
    var found: usize = 0;
    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, &std.ascii.whitespace);
        if (line.len == 0 or line[0] == ';') continue;
        found += 1;
    }
    return found;
}

/// What a document records as a count under `label`.
const RecordedCount = union(enum) {
    one: usize,
    none,
    /// The label appears on more than one row, with values that disagree.
    ambiguous,
};

/// The integer recorded beside `label` in a Markdown table row.
///
/// 対象は表の行で始まる行だけである。文書全体から探すと、ラベルが先に地の文で
/// 見つかり、その後ろにたまたま続く数を読んでしまった。ハッシュの符号化を説明する
/// 文が2つのライブラリを挙げていて、その一方の後ろに、そのライブラリ自身の件数が
/// 言葉で続いていたためである。一致する行はすべて読み、値が一致していなければ
/// ならない。複数あるうちの1つを選ぶことを `sha256InMarkdown` が拒むのと同じ理由
/// である。
fn integerAfter(doc: []const u8, label: []const u8) RecordedCount {
    var found: ?usize = null;
    var lines = std.mem.splitScalar(u8, doc, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, &std.ascii.whitespace);
        if (line.len == 0 or line[0] != '|') continue;
        const at = std.mem.indexOf(u8, line, label) orelse continue;

        var i = at + label.len;
        while (i < line.len and !std.ascii.isDigit(line[i])) : (i += 1) {}
        const digits_at = i;
        while (i < line.len and std.ascii.isDigit(line[i])) : (i += 1) {}
        if (i == digits_at) continue;
        // 手で桁を累積せず、パースする。累積すると長い数字列でオーバーフローして
        // パニックし、それまでに集めた診断がすべて失われた。パースできない値も
        // 読み飛ばさない。読み飛ばすと、件数としては大きすぎる記録が、記録なしと
        // 同じに読まれてしまう。
        const value = std.fmt.parseInt(usize, line[digits_at..i], 10) catch return .ambiguous;

        if (found) |first| {
            if (first != value) return .ambiguous;
        } else found = value;
    }
    return if (found) |v| .{ .one = v } else .none;
}

/// Reports anything in `dir` that the recorded hash does not cover.
///
/// フラットモードの `collectFiles` は、ディレクトリ直下の、拡張子が合うファイル
/// だけを返す。そのため、サブディレクトリや別の拡張子のファイルは、生成された
/// リストの隣にあっても、ハッシュに覆われないまま残る。出自の文書は、記録が
/// ディレクトリの中身を固定すると主張している。だからディレクトリには、それ以外
/// を置かない。
///
/// ただし、リポジトリの一部であるものに限る。`.gitignore` が無視するエントリは
/// 除く。macOS が `.DS_Store` を書いたり、エディタが `base.txt~` を残したりした
/// だけで、正しいリポジトリが赤くなってはならないからである。
///
/// 無視の判定は、拡張子の判定の後ではなく前に行う。拡張子が合わなかった
/// エントリにだけ無視の判定を当てていたときは、macOS が追跡対象のファイルの
/// 隣に書く `._base.txt`(`.gitignore` が名指ししているもの)が、生成された
/// リストとして通ってしまった。それがハッシュと識別子の件数に入り、正しい
/// リポジトリが3件の問題を報告した。同じ順序にするために、`collectFiles` も
/// 無視の集合を受け取る。この検査が受け入れるファイルと、ハッシュが覆う
/// ファイルが、同じ集合になる。
fn checkNothingElseInDir(
    io: std.Io,
    cwd: std.Io.Dir,
    rep: *Reporter,
    ignore: []const u8,
    path: []const u8,
    extension: []const u8,
) !void {
    var dir = cwd.openDir(io, path, .{ .iterate = true }) catch return;
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (isIgnored(ignore, entry.name, entry.kind == .directory)) continue;
        if (entry.kind == .file and std.mem.endsWith(u8, entry.name, extension)) continue;
        rep.fail(
            "{s}/{s} is not a generated *{s} file, so the recorded hash does not cover it",
            .{ path, entry.name, extension },
        );
    }
}

/// Whether `.gitignore` ignores an entry of this name.
///
/// 解釈するのは、このリポジトリが書くパターンの形だけである。完全一致の名前、
/// ディレクトリを表す末尾の `/`、先頭か末尾に1つだけ付く `*` の3つ。この集合の
/// 外の形は決して一致しない。そのため、解釈できないパターンがあっても、検査は
/// それまでと同じ厳しさのままになる。そちらに倒すのは、新しい形のパターンが
/// 検査の失敗として表に出て確認されるようにするためで、記録したハッシュが
/// 覆う範囲に黙って穴があくことを避けるためである。
///
/// すべての名前に一致するパターンも、解釈しない形に入れている。素の `*` は、
/// この関数を参照するすべての検査を一度に無効にした。これは、特定の名前1つが
/// あける穴より大きい。
///
/// 否定も解釈しない形に入る。`!` で始まる行は読み飛ばす。その行が再び
/// 含めるはずのパターンは、無視されたままになる。ここにある否定は
/// `.env.example` を再び含めるものだけで、これは生成物のディレクトリには
/// 現れない。
fn isIgnored(gitignore: []const u8, name: []const u8, is_dir: bool) bool {
    var lines = std.mem.splitScalar(u8, gitignore, '\n');
    while (lines.next()) |raw| {
        var pattern = std.mem.trim(u8, raw, &std.ascii.whitespace);
        if (pattern.len == 0 or pattern[0] == '#' or pattern[0] == '!') continue;

        // 末尾の `/` は、パターンの対象をディレクトリに限る。
        if (pattern[pattern.len - 1] == '/') {
            if (!is_dir) continue;
            pattern = pattern[0 .. pattern.len - 1];
            if (pattern.len == 0) continue;
        }

        // パス形のパターンは位置が固定される。ここで比べるのはエントリ名1つだけ。
        if (std.mem.indexOfScalar(u8, pattern, '/') != null) continue;

        const stars = countOccurrences(pattern, "*");
        if (stars == 0) {
            if (std.mem.eql(u8, pattern, name)) return true;
        } else if (stars == 1 and pattern[0] == '*') {
            const suffix = pattern[1..];
            if (suffix.len != 0 and std.mem.endsWith(u8, name, suffix)) return true;
        } else if (stars == 1 and pattern[pattern.len - 1] == '*') {
            const prefix = pattern[0 .. pattern.len - 1];
            if (prefix.len != 0 and std.mem.startsWith(u8, name, prefix)) return true;
        }
    }
    return false;
}

fn checkSources(
    gpa: std.mem.Allocator,
    io: std.Io,
    cwd: std.Io.Dir,
    rep: *Reporter,
    ignore: []const u8,
    roots: []const []const u8,
    excluded: []const []const u8,
) !void {
    var files: std.ArrayList([]const u8) = .empty;
    // tools/ には段階0のロジックの大半があり、それ自体が検証用のコードでもある。
    // そのため src/ と同じ到達可能性と refAllDecls の規則を適用する。
    for ([_][]const u8{ "src", "tools" }) |root|
        try collectFiles(gpa, io, cwd, ignore, root, ".zig", &files, .recursive);

    var reachable: std.StringHashMapUnmanaged(void) = .empty;
    for (roots) |r| {
        if (!pathIn(files.items, r)) rep.fail("test root {s} does not exist", .{r});
        try reachable.put(gpa, r, {});
    }
    // 自前の test ブロックを持たないルートでも、run step は1つ増える。すると、
    // build.zig の run step の数は満たされたまま、そのモジュールは何も実行
    // しない。数が示すのはテストが起動されたことで、ここで検査するのは、
    // 起動すべきテストが存在したことである。
    for (roots) |r| {
        const body = read(gpa, io, cwd, rep, r) orelse continue;
        if (!hasTestBlock(body))
            rep.fail("test root {s} declares no test, so its run step executes nothing", .{r});
    }
    for (excluded) |e| {
        if (!pathIn(files.items, e)) rep.fail("excluded file {s} does not exist", .{e});
    }

    // 各ファイルは、以下の2つのループより前に1回だけ読む。不動点ループの中で
    // 読むと、読めないファイル1つが複数の問題として報告された。そのループは
    // 1周ごとに到達可能なすべてのパスをもう一度たどるためである。除外は、
    // ファイルをテスト対象から外すだけで、読めなくするわけではない。したがって
    // 読み取りの失敗は、パスが除外されているかどうかに関わらず報告する。
    // 番兵があるから、zigImports は本文を std.zig.Tokenizer に渡せる。
    var bodies: std.StringHashMapUnmanaged([:0]const u8) = .empty;
    for (files.items) |path| {
        if (read(gpa, io, cwd, rep, path)) |body| try bodies.put(gpa, path, body);
    }

    // 新たに到達するものがなくなるまで繰り返す。インポートは深さの分からない
    // DAG を成すためである。
    var changed = true;
    while (changed) {
        changed = false;
        for (files.items) |path| {
            if (!reachable.contains(path)) continue;
            const body = bodies.get(path) orelse continue;
            const dir = std.fs.path.dirnamePosix(path) orelse "src";
            var imports: std.ArrayList([]const u8) = .empty;
            try zigImports(gpa, body, &imports);
            for (imports.items) |name| {
                const joined = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ dir, name });
                // 正規化する。しないと、"../other.zig" と書かれたインポートが
                // src/sub/../other.zig になり、集めた src/other.zig と一致しない。
                // そのせいで、テストが実際に走っているファイルが、到達不能と
                // 報告されてしまう。
                const key = try normalizePath(gpa, joined);
                if (!reachable.contains(key)) {
                    try reachable.put(gpa, key, {});
                    changed = true;
                }
            }
        }
    }

    for (files.items) |path| {
        // 除外は、リポジトリからの相対パス全体で指定する。基底名だけで照合すると、
        // src/platform/wasm.zig まで除外されてしまう。
        if (pathIn(excluded, path)) continue;

        if (!reachable.contains(path))
            rep.fail("{s} is not reached from any test root; its tests would be skipped", .{path});

        const body = bodies.get(path) orelse continue;
        var imports: std.ArrayList([]const u8) = .empty;
        try zigImports(gpa, body, &imports);
        if (imports.items.len == 0) continue;
        if (!hasRefAllDeclsTest(body))
            rep.fail(
                "{s} imports other source files but has no top-level `test` calling refAllDecls(@This())",
                .{path},
            );
    }
}

/// Resolves `.` and `..` segments so two spellings of one path compare equal.
/// 区切り文字は `/` に正規化する。
fn normalizePath(gpa: std.mem.Allocator, path: []const u8) ![]const u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    defer parts.deinit(gpa);
    var it = std.mem.tokenizeAny(u8, path, "/\\");
    while (it.next()) |seg| {
        if (std.mem.eql(u8, seg, ".")) continue;
        if (std.mem.eql(u8, seg, "..")) {
            if (parts.items.len != 0) {
                _ = parts.pop();
                continue;
            }
        }
        try parts.append(gpa, seg);
    }
    return std.mem.join(gpa, "/", parts.items);
}

fn pathIn(haystack: []const []const u8, needle: []const u8) bool {
    for (haystack) |h| if (std.mem.eql(u8, h, needle)) return true;
    return false;
}

/// Collects the `*.zig` paths named by real `@import` expressions.
/// トークン化するので、コメントアウトされたものや文字列に埋め込まれたものは
/// 結果に入らない。Zig は被演算子に文字列リテラルを要求するため、定数の陰に
/// インポートを隠す方法はない。
fn zigImports(gpa: std.mem.Allocator, source: [:0]const u8, out: *std.ArrayList([]const u8)) !void {
    var tok = std.zig.Tokenizer.init(source);
    var state: enum { idle, saw_import, saw_paren } = .idle;
    while (true) {
        const t = tok.next();
        if (t.tag == .eof) break;
        const text = source[t.loc.start..t.loc.end];
        switch (state) {
            .idle => if (t.tag == .builtin and std.mem.eql(u8, text, "@import")) {
                state = .saw_import;
            },
            .saw_import => state = if (t.tag == .l_paren) .saw_paren else .idle,
            .saw_paren => {
                state = .idle;
                if (t.tag != .string_literal or text.len < 2) continue;
                const name = text[1 .. text.len - 1];
                if (std.mem.endsWith(u8, name, ".zig")) try out.append(gpa, name);
            },
        }
    }
}

/// True when a top-level `test` block contains the call `refAllDecls(@This())`.
///
/// 引数は `@This()` でなければならない。別のコンテナを渡してもコンパイルは
/// 通り、慣習どおりに見えるが、参照されるのは別の宣言になる。その結果、
/// インポートされたファイルのテストは、やはり一度も走らない。
///
/// 呼び出しは修飾されていなければならない。std のものを覆い隠すローカルの
/// `fn refAllDecls` は、素の名前だけを見る検査を通るが、何も参照しない。
///
/// この関数は、呼び出しに到達することまでは証明できない。test ブロックの中の
/// `comptime { if (false) ... }` は検査を通るが、何の効果もない。修飾子が
/// std.testing に解決されることも証明できない。ローカルの
/// `const fake = struct { fn refAllDecls(_: type) void {} };` を
/// `fake.refAllDecls(@This())` として参照しても通る。この2つの限界は、
/// docs/design/open-questions.md に、実装時の問いとして記録してある。
fn hasRefAllDeclsTest(source: [:0]const u8) bool {
    var tok = std.zig.Tokenizer.init(source);
    var depth: usize = 0;
    var test_depth: ?usize = null;
    // 呼び出しは5トークンである。refAllDecls ( @This ( ) で、この後に
    // refAllDecls の閉じ括弧が続く。
    var seen: usize = 0;
    while (true) {
        const t = tok.next();
        if (t.tag == .eof) return false;
        const text = source[t.loc.start..t.loc.end];

        switch (t.tag) {
            .l_brace => depth += 1,
            .r_brace => {
                if (depth > 0) depth -= 1;
                if (test_depth) |d| if (depth <= d) {
                    test_depth = null;
                };
            },
            .keyword_test => if (depth == 0) {
                test_depth = depth;
            },
            else => {},
        }
        if (test_depth == null) {
            seen = 0;
            continue;
        }

        seen = switch (seen) {
            // ピリオドの後の `.refAllDecls`。呼び出しは修飾されていなければ
            // ならないので、同名のローカル関数では条件を満たさない。
            0 => if (t.tag == .period) 1 else 0,
            1 => if (t.tag == .identifier and std.mem.eql(u8, text, "refAllDecls")) 2 else 0,
            2 => if (t.tag == .l_paren) 3 else 0,
            3 => if (t.tag == .builtin and std.mem.eql(u8, text, "@This")) 4 else 0,
            4 => if (t.tag == .l_paren) 5 else 0,
            5 => if (t.tag == .r_paren) 6 else 0,
            else => 6,
        };
        if (seen == 6) return true;
    }
}

// ---------------------------------------------------------------------------
// 4. Markdown: 相対リンクが解決できる。
//
// フェンス付きコードブロックの中のリンクは読み飛ばす。docs/adr/README.md には
// 非推奨化のテンプレートがあり、そのリンクは仕様上プレースホルダだからである。
// 閉じていないフェンスは、ファイルの残りをそのブロックに巻き込んでしまうので、
// 報告する。
// ---------------------------------------------------------------------------

fn checkMarkdown(
    gpa: std.mem.Allocator,
    io: std.Io,
    cwd: std.Io.Dir,
    rep: *Reporter,
    ignore: []const u8,
) !void {
    // リポジトリ全体をたどる。ディレクトリを固定のリストで指定すると、.agents/、
    // .claude/、.github/ が検査されずに残った。これは Markdown の4分の1にあたる。
    var files: std.ArrayList([]const u8) = .empty;
    try collectFiles(gpa, io, cwd, ignore, ".", ".md", &files, .recursive);

    for (files.items) |path| {
        const body = read(gpa, io, cwd, rep, path) orelse continue;
        const dir = std.fs.path.dirnamePosix(path) orelse ".";

        // フェンスは、開く側と同じ文字で、開く側以上の長さの連なりで閉じる。
        // したがって、```` のブロックの中の ``` はブロックを終わらせない。
        var fence: ?struct { ch: u8, len: usize } = null;
        var fence_line: usize = 0;
        // 開いている最も内側のリスト項目の、内容が始まる桁。CommonMark は
        // インデントをこの桁を基準にして測る。
        var content_col: usize = 0;
        var lines = std.mem.splitScalar(u8, body, '\n');
        var lineno: usize = 0;
        while (lines.next()) |raw| {
            lineno += 1;
            const line = std.mem.trimEnd(u8, raw, "\r");
            const run = indentRun(line);
            const trimmed = line[run.bytes..];

            if (fence == null and trimmed.len != 0) {
                if (listContentColumn(run.cols, trimmed)) |col| {
                    content_col = col;
                } else if (run.cols < content_col) {
                    // 項目の内容より浅い行は、その項目を閉じる。
                    content_col = 0;
                }
            }
            // 含んでいるブロックの内容より4桁以上深ければ、インデントされた
            // コードブロックであり、フェンスでも地の文でもない。どの深さの
            // フェンスも許すと、4スペースのフェンスが2つあるとき、その間の段落が
            // 隠れた。2行はフェンス付きブロックとして読まれ、中の段落はリンクを
            // 検査されず、フェンスは閉じているので何も報告されなかった。リスト
            // 項目の内容の桁を基準に測れば、docs/adr/README.md が番号付きの項目の
            // 中に書くフェンス(5スペース入っているが、内容の桁からは0桁しか
            // 深くない)は、フェンスとして残る。
            const relative = run.cols - @min(run.cols, content_col);
            if (relative >= 4) continue;

            if (fenceRun(trimmed)) |opener| {
                if (fence) |open| {
                    // 閉じるのは、同じ文字で同じ長さ以上の、何も続かない連なり
                    // だけである。それ以外は中身。
                    if (opener.bare and opener.ch == open.ch and opener.len >= open.len) {
                        fence = null;
                        continue;
                    }
                } else {
                    fence = .{ .ch = opener.ch, .len = opener.len };
                    fence_line = lineno;
                    continue;
                }
            }
            if (fence != null) continue;

            if (referenceDefinition(trimmed)) |def| switch (def) {
                .target => |target| try checkLinkTarget(gpa, io, cwd, rep, path, lineno, dir, target),
                .unreadable => rep.fail(
                    "{s}:{d}: this link definition names no destination on its own line; write `[label]: path` on one line",
                    .{ path, lineno },
                ),
            };
            try checkLinksOnLine(gpa, io, cwd, rep, path, lineno, dir, line);
        }
        // リンクの検査は、開いたままのフェンスで止まるので、報告する。ADR-0026 は
        // 相対リンクの到達可能性を検査の対象に残している。フェンスを閉じ忘れると、
        // ファイルの残りがその検査から外れるのに、何も言われない。これは、
        // ADR-0026 の3つの事実の1つ目が禁じていることである。
        if (fence) |open| rep.fail(
            "{s}:{d}: this code fence of {d} '{c}' is never closed, so the links below it are not checked",
            .{ path, fence_line, open.len, open.ch },
        );
    }
}

/// Recognises a fence line: a run of at least three backticks or tildes, plus
/// whether anything other than whitespace follows it.
fn fenceRun(trimmed: []const u8) ?struct { ch: u8, len: usize, bare: bool } {
    if (trimmed.len < 3) return null;
    const ch = trimmed[0];
    if (ch != '`' and ch != '~') return null;
    var n: usize = 0;
    while (n < trimmed.len and trimmed[n] == ch) n += 1;
    if (n < 3) return null;
    // CommonMark: "The closing code fence ... may be followed only by spaces or
    // tabs". ```zig のような行はブロックを開く。これを閉じる行として扱うと、
    // 正しい文書1つが2件の誤検知になる。
    const rest = std.mem.trim(u8, trimmed[n..], " \t");
    // CommonMark: "If the info string comes after a backtick fence, it may not
    // contain any backtick characters." したがって ```a`b` は、コードスパンを
    // 含む段落であり、フェンスではない。これをフェンスとして読むと、閉じる
    // ものがないブロックが開く。存在しないフェンスを報告し、しかもその下の
    // すべてのリンクが検査から外れた。
    if (ch == '`' and std.mem.indexOfScalar(u8, rest, '`') != null) return null;
    return .{ .ch = ch, .len = n, .bare = rest.len == 0 };
}

fn checkLinksOnLine(
    gpa: std.mem.Allocator,
    io: std.Io,
    cwd: std.Io.Dir,
    rep: *Reporter,
    path: []const u8,
    lineno: usize,
    dir: []const u8,
    line: []const u8,
) !void {
    var i: usize = 0;
    // コードスパンは、CommonMark 自身の規則で読み飛ばす。バッククォートの
    // 連なりがスパンを開き、同じ長さの連なりだけがそれを閉じる。バック
    // スラッシュは直後の文字をエスケープする。
    //
    // これより弱い規則が2つ先にあり、どちらも黙って失敗した。バッククォート
    // のたびに切り替える方式では、行内の個数の偶奇で決まるため、リンクの前に
    // 対応のないバッククォートが1つあるだけで、そのリンクが検査から外れた。
    // 行のどこかに閉じるバッククォートがあることを要求する方式は、その場合は
    // 直したが、あと2つ残した。1つは `\`` で、これはエスケープされたリテラル
    // なのに、切り替え方式は数えていた。もう1つは、3個や5個の連なりが1個
    // とは対にならないことである。連なりの長さを合わせるのはレンダラが使う
    // 規則そのものなので、これより短い綴りで見つかる穴はもう残っていない。
    while (i < line.len) {
        if (line[i] == '\\') {
            i += 2; // エスケープされた文字(バッククォートかどうかを問わない)
            continue;
        }
        if (line[i] == '`') {
            var run = i;
            while (run < line.len and line[run] == '`') run += 1;
            const len = run - i;
            if (closingBacktickRun(line, run, len)) |close| {
                i = close + len;
            } else {
                // 同じ長さの連なりが後に続かないので、このバッククォートは
                // ただの文字である。後ろは通常どおりに読む。
                i = run;
            }
            continue;
        }
        if (i + 1 >= line.len or line[i] != ']' or line[i + 1] != '(') {
            i += 1;
            continue;
        }
        i += 2;
        const dest = linkDestination(line[i..]) orelse {
            // 読み飛ばさず、報告する。CommonMark は括弧の間に改行を置くことを
            // 許す。そのため、リンク先や閉じ括弧が次の行にあるリンクは、リンク
            // として描画されるのに、1行ずつ読むこの検査には読めない。読み飛ばす
            // と、描画されるリンクについて黙ることになる。これは、このプログラム
            // にあった穴のすべてに共通する形で、参照形式についても同じ判断を
            // すでにしている。
            rep.fail(
                "{s}:{d}: this link does not close on its own line; write `[text](path)` on one line",
                .{ path, lineno },
            );
            continue;
        };
        i += dest.consumed;
        try checkLinkTarget(gpa, io, cwd, rep, path, lineno, dir, dest.target);
    }
}

/// The column a list item's content starts at, when `trimmed` opens one.
///
/// `indent` はマーカーが始まる桁で、`trimmed` はそこから先の行である。
/// CommonMark は項目の中のすべてをこの桁を基準に測る。内容がそこから
/// 始まる項目の中にあれば、5スペース入ったフェンスがフェンスになるのは
/// このためである。
fn listContentColumn(indent: usize, trimmed: []const u8) ?usize {
    if (trimmed.len < 2) return null;
    var marker: usize = 0;
    if (trimmed[0] == '-' or trimmed[0] == '*' or trimmed[0] == '+') {
        marker = 1;
    } else {
        while (marker < trimmed.len and std.ascii.isDigit(trimmed[marker])) marker += 1;
        if (marker == 0 or marker >= trimmed.len) return null;
        if (trimmed[marker] != '.' and trimmed[marker] != ')') return null;
        marker += 1;
    }
    if (marker >= trimmed.len) return null;
    if (trimmed[marker] != ' ' and trimmed[marker] != '\t') return null;
    var spaces = marker;
    while (spaces < trimmed.len and (trimmed[spaces] == ' ' or trimmed[spaces] == '\t')) spaces += 1;
    return indent + spaces;
}

/// Where a run of exactly `len` backticks starts, searching from `from`.
///
/// ちょうどその長さであること。CommonMark はコードスパンを同じ大きさの
/// 連なりでしか閉じないので、1個のバッククォートは3個の連なりを閉じない。
/// より長い連なりは、一致ではないので、一致として扱わず通り過ぎる。
fn closingBacktickRun(line: []const u8, from: usize, len: usize) ?usize {
    var i = from;
    while (i < line.len) {
        if (line[i] != '`') {
            i += 1;
            continue;
        }
        var run = i;
        while (run < line.len and line[run] == '`') run += 1;
        if (run - i == len) return i;
        i = run;
    }
    return null;
}

/// What a reference link definition names, `[label]: dest`.
///
/// `checkLinksOnLine` は `](` を探すが、定義にはそれがない。そのため、参照
/// 形式で書いたリンクは、リンク先を誰も読まなかった。描画されたページは
/// 存在しないファイルを指すのに、何も報告されなかった。
const Definition = union(enum) {
    /// The link target on the same line as the label.
    target: []const u8,
    /// A definition this check cannot read.
    /// CommonMark はリンク先を次の行に置くことを許すが、この検査は1行ずつ読む
    /// ためである。読み飛ばさず、報告する。
    /// 読み飛ばすと、描画されるリンクについて黙ることになる。これは、
    /// このプログラムにあった穴のすべてに共通する形である。
    unreadable,
};

fn referenceDefinition(raw: []const u8) ?Definition {
    // 引用ブロックやリスト項目の中の定義も定義であり、レンダラはそれに対する
    // 参照を解決する。行をそのまま読むだけでは、`> [label]: dest` と
    // `- [label]: dest` が読まれず、報告もされなかった。
    var line = raw;
    while (true) {
        const before = line;
        // 引用のマーカーの後ろには空白がなくてよく、リストのマーカーは数でも
        // よい。`> `、`- `、`* `、`+ ` だけを取り除くと、`>[label]:`、
        // `>> [label]:`、`1. [label]:`、マーカーの後ろのタブが、読まれず報告も
        // されなかった。これは、閉じた集合の規律が開いたまま失敗する例である。
        if (line.len != 0 and line[0] == '>') {
            line = std.mem.trimStart(u8, line[1..], " \t");
        } else if (line.len >= 2 and
            (line[0] == '-' or line[0] == '*' or line[0] == '+') and
            (line[1] == ' ' or line[1] == '\t'))
        {
            line = std.mem.trimStart(u8, line[1..], " \t");
        } else {
            var digits: usize = 0;
            while (digits < line.len and std.ascii.isDigit(line[digits])) digits += 1;
            if (digits != 0 and digits + 1 < line.len and
                (line[digits] == '.' or line[digits] == ')') and
                (line[digits + 1] == ' ' or line[digits + 1] == '\t'))
            {
                line = std.mem.trimStart(u8, line[digits + 1 ..], " \t");
            }
        }
        if (line.len == before.len) break;
    }

    if (line.len == 0 or line[0] != '[') return null;
    // ラベルは、CommonMark の読み方に従い、エスケープされていない最初の `]` で
    // 終わる。括弧を含むラベルをすべて退けると、`[a\]b]: dest` が読まれずに
    // 通り抜けた。レンダラはこれを定義として扱うが、この検査は扱わなかった。
    var close: ?usize = null;
    var i: usize = 1;
    while (i < line.len) : (i += 1) {
        if (line[i] == '\\') {
            i += 1;
            continue;
        }
        if (line[i] == '[') return null; // エスケープされていない `[` を含むものはラベルではない
        if (line[i] == ']') {
            close = i;
            break;
        }
    }
    const label_end = close orelse return null;
    if (label_end + 1 >= line.len or line[label_end + 1] != ':') return null;
    var rest = std.mem.trimStart(u8, line[label_end + 2 ..], " \t");
    if (rest.len == 0) return .unreadable;
    // リンク先の後ろに、同じ行でタイトルが続くことがある。
    if (std.mem.indexOfAny(u8, rest, " \t")) |space| rest = rest[0..space];
    if (rest.len >= 2 and rest[0] == '<' and rest[rest.len - 1] == '>')
        rest = rest[1 .. rest.len - 1];
    return if (rest.len == 0) .unreadable else .{ .target = rest };
}

/// Reports a relative link whose target is not a file in the repository.
fn checkLinkTarget(
    gpa: std.mem.Allocator,
    io: std.Io,
    cwd: std.Io.Dir,
    rep: *Reporter,
    path: []const u8,
    lineno: usize,
    dir: []const u8,
    target: []const u8,
) !void {
    if (target.len == 0) return;
    // 任意の URI スキームを、大文字小文字を区別せずに照合する。RFC 3986 は
    // スキームの大文字小文字を区別しないと定めている。また、単に "http" で
    // 始まるかどうかを見ると、相対パスの http-guide.md まで読み飛ばしてしまう。
    if (hasUriScheme(target)) return;
    if (target[0] == '#') return;
    const file_part = std.mem.sliceTo(target, '#');
    if (file_part.len == 0) return;
    // ファイルシステムに触れる前に、パスに含められない文字を退ける。
    // std.Io.Dir.access は、Windows では不正な名前に対してエラーを返さず
    // パニックする。それでは、悪いリンク1つがクラッシュになり、ほかの
    // すべての診断が失われる。
    if (std.mem.indexOfAny(u8, file_part, "<>:\"|?*") != null or
        std.mem.indexOfScalar(u8, file_part, 0) != null)
    {
        rep.fail("{s}:{d}: link target {s} is not a usable path", .{ path, lineno, target });
        return;
    }
    const joined = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ dir, file_part });
    cwd.access(io, joined, .{}) catch {
        rep.fail("{s}:{d}: link target {s} does not exist", .{ path, lineno, target });
    };
}

/// Splits a CommonMark inline link destination from its optional title.
/// 扱う形は `<dest>`、`dest`、`dest "title"`、`dest 'title'`、`dest (title)`。
fn linkDestination(rest: []const u8) ?struct { target: []const u8, consumed: usize } {
    if (rest.len == 0) return null;
    if (rest[0] == '<') {
        const close = std.mem.indexOfScalar(u8, rest, '>') orelse return null;
        const end = std.mem.indexOfScalarPos(u8, rest, close, ')') orelse return null;
        return .{ .target = rest[1..close], .consumed = end };
    }
    const close = std.mem.indexOfScalar(u8, rest, ')') orelse return null;
    var target = std.mem.trim(u8, rest[0..close], " \t");
    // タイトルを取り除く。バックスラッシュのエスケープは扱わない。`a\ b.md`
    // のようなリンク先は、切り詰められた名前で報告される。このリポジトリの
    // ファイルにエスケープが必要なものはなく、扱うには CommonMark の
    // エスケープ規則を実装することになる。
    if (std.mem.indexOfAny(u8, target, " \t")) |space|
        target = std.mem.trimEnd(u8, target[0..space], " \t");
    return .{ .target = target, .consumed = close };
}

/// True when the text starts with a URI scheme (`scheme:`), per RFC 3986:
/// ALPHA followed by ALPHA / DIGIT / "+" / "-" / "." and then a colon.
fn hasUriScheme(text: []const u8) bool {
    if (text.len == 0 or !std.ascii.isAlphabetic(text[0])) return false;
    for (text[1..], 1..) |c, idx| {
        if (c == ':') return idx >= 1;
        if (!std.ascii.isAlphanumeric(c) and c != '+' and c != '-' and c != '.') return false;
    }
    return false;
}

// ---------------------------------------------------------------------------

const Walk = enum { flat, recursive };

/// Collects the files under `root` whose name ends in `suffix`.
/// パスはリポジトリからの相対で、どのプラットフォームでも `/` を使う。
///
/// `.gitignore` が名指しするエントリは、ファイルもディレクトリも除く。追跡
/// されていないので、検査の対象ではないからである。無視されたディレクトリ
/// の下のメモが Markdown の検査を落としていたし、macOS が追跡対象のファイル
/// の隣に書く AppleDouble ファイルが、生成されたリストのハッシュに入って
/// いた。無視の集合をここで読むことで、すべての検査が見るファイルの集合が
/// 同じになり、それを宣言する場所も `.gitignore` 1か所のままになる。
fn collectFiles(
    gpa: std.mem.Allocator,
    io: std.Io,
    cwd: std.Io.Dir,
    ignore: []const u8,
    root: []const u8,
    suffix: []const u8,
    out: *std.ArrayList([]const u8),
    walk: Walk,
) !void {
    var dir = cwd.openDir(io, root, .{ .iterate = true }) catch return;
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        const path = if (std.mem.eql(u8, root, "."))
            try gpa.dupe(u8, entry.name)
        else
            try std.fmt.allocPrint(gpa, "{s}/{s}", .{ root, entry.name });
        if (isIgnored(ignore, entry.name, entry.kind == .directory)) continue;
        switch (entry.kind) {
            .file => if (std.mem.endsWith(u8, entry.name, suffix)) try out.append(gpa, path),
            .directory => {
                if (walk == .flat) continue;
                var skip = false;
                for (skipped_dirs) |s| if (std.mem.eql(u8, entry.name, s)) {
                    skip = true;
                };
                if (!skip) try collectFiles(gpa, io, cwd, ignore, path, suffix, out, walk);
            },
            else => {},
        }
    }
}
// ---------------------------------------------------------------------------
// テスト
//
// ここで扱うのは、純粋な判定関数である。ここを間違えると、検査が黙って何も
// 捉えなくなる。以下のケースはどれも、このファイルの以前の版に対して敵対的
// レビューが実際に出したものである。そのため、回帰が起きれば、仮定の穴では
// なく、既知の穴が戻ってくる。
// ---------------------------------------------------------------------------

test "fenceRun: an info string means the line opens, never closes" {
    // ```zig を閉じるフェンスとして読んではならない。読むと、正しい文書1つが、
    // 迷子のリンクと閉じていないフェンスを報告した。
    const open = fenceRun("```zig").?;
    try std.testing.expect(!open.bare);
    const close = fenceRun("```").?;
    try std.testing.expect(close.bare);
    try std.testing.expectEqual(@as(usize, 3), close.len);
    try std.testing.expectEqual(@as(u8, '`'), close.ch);
}

test "fenceRun: a backtick in the info string means it is not a fence" {
    // このテストが固定する欠陥。CommonMark はバッククォートのフェンスの
    // 情報文字列にバッククォートを含めることを禁じているので、```a`b は
    // コードスパンを含む段落である。これをフェンスとして読むと、閉じる
    // ものがないブロックが開き、その下のすべてのリンクが検査から外れた。
    try std.testing.expect(fenceRun("```a`b") == null);
    try std.testing.expect(fenceRun("```[x](d.md)```") == null);
    try std.testing.expect(fenceRun("```zig") != null);
    // チルダのフェンスは、情報文字列にバッククォートを含んでよい。
    try std.testing.expect(fenceRun("~~~a`b") != null);
}

test "closingBacktickRun: only a run of the same length closes a span" {
    // このテストが固定する欠陥。1個のバッククォートは3個の連なりを閉じない。
    // バッククォートを1個ずつ数える方式では、エスケープされた連なりや、より
    // 長い連なりがあると、走査が行末までスパンの内側に取り残された。
    try std.testing.expectEqual(@as(?usize, 4), closingBacktickRun("a `b` c", 3, 1));
    try std.testing.expectEqual(@as(?usize, null), closingBacktickRun("``` x ` y", 3, 3));
    try std.testing.expectEqual(@as(?usize, 6), closingBacktickRun("``` x ``` y", 3, 3));
    // より長い連なりは、一致として扱わず通り過ぎる。
    try std.testing.expectEqual(@as(?usize, 9), closingBacktickRun("a ```` b ` c", 2, 1));
    try std.testing.expectEqual(@as(?usize, null), closingBacktickRun("no ticks", 0, 1));
}

test "listContentColumn: where an item's content starts" {
    // 項目の中のフェンスは、この桁を基準に測る。これがないと、4スペース入った
    // 2つのフェンスがフェンス付きブロックとして読まれ、その間の段落がリンクの
    // 検査から隠れた。
    try std.testing.expectEqual(@as(?usize, 2), listContentColumn(0, "- a"));
    try std.testing.expectEqual(@as(?usize, 5), listContentColumn(2, "1. a"));
    try std.testing.expectEqual(@as(?usize, 3), listContentColumn(0, "1) a"));
    try std.testing.expectEqual(@as(?usize, 4), listContentColumn(0, "-   a"));
    try std.testing.expectEqual(@as(?usize, null), listContentColumn(0, "-a"));
    try std.testing.expectEqual(@as(?usize, null), listContentColumn(0, "a - b"));
    try std.testing.expectEqual(@as(?usize, null), listContentColumn(0, "1.a"));
}

test "referenceDefinition: the markers a definition may sit behind" {
    // このテストが固定する欠陥。引用のマーカーの後ろには空白がなくてよく、
    // リストのマーカーは数でもよい。したがって `>[l]:`、`>> [l]:`、
    // `1. [l]:` は、レンダラが解決する定義である。`> `、`- `、`* `、`+ ` だけを
    // 取り除くと、これらは読まれず、報告もされなかった。
    try std.testing.expectEqualStrings("d.md", referenceDefinition("[l]: d.md").?.target);
    try std.testing.expectEqualStrings("d.md", referenceDefinition(">[l]: d.md").?.target);
    try std.testing.expectEqualStrings("d.md", referenceDefinition(">> [l]: d.md").?.target);
    try std.testing.expectEqualStrings("d.md", referenceDefinition("1. [l]: d.md").?.target);
    try std.testing.expectEqualStrings("d.md", referenceDefinition("- [l]: d.md").?.target);
    // ラベルは、CommonMark の読み方に従い、エスケープされていない最初の括弧で終わる。
    try std.testing.expectEqualStrings("d.md", referenceDefinition("[a\\]b]: d.md").?.target);
    // リンク先の後ろのタイトルはリンク先に含まれない。`<d>` の `d` は含まれる。
    try std.testing.expectEqualStrings("d.md", referenceDefinition("[l]: d.md \"t\"").?.target);
    try std.testing.expectEqualStrings("d.md", referenceDefinition("[l]: <d.md>").?.target);
    // その行にリンク先がないものは、読み飛ばさず報告する。
    try std.testing.expect(referenceDefinition("[l]:").? == .unreadable);
    try std.testing.expect(referenceDefinition("[l]:   ").? == .unreadable);
    // 括弧とコロンを含むだけの地の文は、定義ではない。
    try std.testing.expect(referenceDefinition("[参考] 次の節: 使い方") == null);
    try std.testing.expect(referenceDefinition("see [a](b.md): yes") == null);
    try std.testing.expect(referenceDefinition("no bracket here") == null);
}

test "yamlKey: the spellings Actions treats as a bare key are refused" {
    try std.testing.expectEqualStrings("run", yamlKey("run: zig build").?);
    try std.testing.expectEqualStrings("on", yamlKey("on:").?);
    // 引用符付きのキーと、コロンの前の空白は、Actions が受け入れる綴りだが、
    // この検査は拒む。誤読せずに報告するためである。
    try std.testing.expect(yamlKey("'if': false") == null);
    try std.testing.expect(yamlKey("run : zig build") == null);
    try std.testing.expect(yamlKey("- not a key") == null);
    try std.testing.expect(yamlKey("no colon") == null);
}

test "isTriggerNarrowing: the keys that change when a workflow runs" {
    try std.testing.expect(isTriggerNarrowing("types"));
    try std.testing.expect(isTriggerNarrowing("workflow_dispatch"));
    try std.testing.expect(!isTriggerNarrowing("push"));
    try std.testing.expect(!isTriggerNarrowing("branches"));
    // 既知のキーである。低速の段のワークフローが使えるようにするため。
    try std.testing.expect(keyIsAllowed("types"));
    try std.testing.expect(keyIsAllowed("workflow_dispatch"));
}

test "keyIsAllowed: the set is closed and holds no conditional" {
    try std.testing.expect(keyIsAllowed("run"));
    try std.testing.expect(keyIsAllowed("jobs"));
    try std.testing.expect(keyIsAllowed("test")); // 許されるジョブ名はこれだけ
    // 意図して含めない。スキップされたり大目に見られたりする検証は、止まっている。
    try std.testing.expect(!keyIsAllowed("if"));
    try std.testing.expect(!keyIsAllowed("continue-on-error"));
    try std.testing.expect(!keyIsAllowed("needs"));
    try std.testing.expect(!keyIsAllowed("verify"));
}

test "isTriggerNarrowing: a schedule is a trigger, and the per-commit workflow may not have one" {
    try std.testing.expect(isTriggerNarrowing("schedule"));
    // `cron` は `schedule` の下にしか置けないので、それ自体は時機を変えるキーではない。
    try std.testing.expect(!isTriggerNarrowing("cron"));
    try std.testing.expect(keyIsAllowed("schedule"));
    try std.testing.expect(keyIsAllowed("cron"));
}

test "keyIsAllowed: the keys of the fuzzing workflow are known" {
    // ファジングのワークフロー(fuzz.yml)が使うジョブ名とキー。
    try std.testing.expect(keyIsAllowed("fuzz"));
    try std.testing.expect(keyIsAllowed("timeout-minutes"));
    try std.testing.expect(keyIsAllowed("retention-days"));
    try std.testing.expect(keyIsAllowed("if-no-files-found"));
    try std.testing.expect(keyIsAllowed("include-hidden-files"));
    // 条件の禁止は変わらない。
    try std.testing.expect(!keyIsAllowed("if"));
    try std.testing.expect(!keyIsAllowed("needs"));
}

test "keyIsAllowed: the job of the release assembly rehearsal is known" {
    // リリースの成果物の組み立てを、タグの前に full.yml が試す。そのジョブの名前。
    try std.testing.expect(keyIsAllowed("dist"));
    // ジョブ名を足しても、依存と条件のキーは通らない。
    try std.testing.expect(!keyIsAllowed("needs"));
    try std.testing.expect(!keyIsAllowed("if"));
    // 名前の一部では通らない。
    try std.testing.expect(!keyIsAllowed("dist2"));
    try std.testing.expect(!keyIsAllowed("distribute"));
}

test "keyIsAllowed: the keys of the release workflow are known, and a tag trigger narrows when it runs" {
    // リリースのワークフロー(release.yml)が使うジョブ名とキー。契機はタグの push
    // で、タグは `push` の下にだけ置ける。
    try std.testing.expect(keyIsAllowed("release"));
    try std.testing.expect(keyIsAllowed("tags"));
    // タグの名前とトークンは、`run:` の行に式を埋め込まず、環境変数で渡す。
    // 埋め込むと、タグの名前がシェルの構文として読まれる。
    try std.testing.expect(keyIsAllowed("env"));
    try std.testing.expect(keyIsAllowed("TAG"));
    try std.testing.expect(keyIsAllowed("GH_TOKEN"));
    // タグは検証が走る時機を変えるので、コミットごとのワークフローには置けない。
    try std.testing.expect(isTriggerNarrowing("tags"));
    // 近い綴りと、条件や依存のキーは通らない。
    try std.testing.expect(!keyIsAllowed("releases"));
    try std.testing.expect(!keyIsAllowed("tag"));
    try std.testing.expect(!keyIsAllowed("tags-ignore"));
    try std.testing.expect(!keyIsAllowed("GITHUB_TOKEN"));
    try std.testing.expect(!keyIsAllowed("needs"));
    try std.testing.expect(!keyIsAllowed("if"));
}

test "isForbiddenInPerCommit: env changes how the shell runs, so the per-commit workflow may not have it" {
    // `env` は step のシェルの動作を変えられる(`BASH_ENV`、`PATH`)。ブロック形では
    // 許可キーの `TAG` と `GH_TOKEN` しか書けないが、`env: { … }` と式の形は値を
    // 読まないので、全コミットの検査を黙って止める綴りが通ってしまう。
    // コミットごとのワークフローには置かせない。
    try std.testing.expect(isForbiddenInPerCommit("env"));
    // 時機を変えるキーも、引き続き置かせない。
    try std.testing.expect(isForbiddenInPerCommit("types"));
    try std.testing.expect(isForbiddenInPerCommit("tags"));
    // 他のワークフローは env を持てる。許可キーのままである。
    try std.testing.expect(keyIsAllowed("env"));
    // 通常のキーは置ける。
    try std.testing.expect(!isForbiddenInPerCommit("run"));
    try std.testing.expect(!isForbiddenInPerCommit("with"));
    try std.testing.expect(!isForbiddenInPerCommit("TAG"));
}

test "keyIsAllowed: persist-credentials is known, so the release workflow can stop keeping the token" {
    try std.testing.expect(keyIsAllowed("persist-credentials"));
    try std.testing.expect(!keyIsAllowed("persist_credentials"));
    try std.testing.expect(!keyIsAllowed("fetch-depth"));
}

test "slow_commands: the dist command is one the slow tier's workflow has to run" {
    var found = false;
    for (slow_commands) |command| {
        if (std.mem.eql(u8, command, "zig build dist")) found = true;
    }
    try std.testing.expect(found);
    // 既存の3つは残る。
    try std.testing.expectEqual(@as(usize, 4), slow_commands.len);
}

test "runsCommand: dist is told apart from the plain build and from other flags" {
    try std.testing.expect(runsCommand("zig build dist", "zig build dist"));
    // 素の build の行が、dist の行の代わりになってはならない。
    try std.testing.expect(!runsCommand("zig build", "zig build dist"));
    try std.testing.expect(!runsCommand("zig build wasm", "zig build dist"));
    // 名前が長い step や、動作を変える接尾辞は、dist ではない。
    try std.testing.expect(!runsCommand("zig build distribute", "zig build dist"));
    try std.testing.expect(!runsCommand("zig build dist --help", "zig build dist"));
    // dist の行が、素の build の行の代わりになってもならない。
    try std.testing.expect(!runsCommand("zig build dist", "zig build"));
}

test "keyIsAllowed: the job of the preview workflow is known, and its trigger narrows nothing" {
    // PR への成果物の添付(preview.yml)のジョブ名。キーは ci.yml と fuzz.yml が
    // すでに使うものだけで足りるので、足したのはジョブ名だけである。
    try std.testing.expect(keyIsAllowed("preview"));
    // 契機は `pull_request` で、ci.yml と同じ。時機を絞るキーではないので、
    // どのワークフローにも置けるし、コミットごとのワークフローが持っていても
    // 禁じられない。
    try std.testing.expect(keyIsAllowed("pull_request"));
    try std.testing.expect(!isTriggerNarrowing("pull_request"));
    // ジョブ名の追加は、条件や依存のキーを通さない。
    try std.testing.expect(!keyIsAllowed("if"));
    try std.testing.expect(!keyIsAllowed("needs"));
    try std.testing.expect(!keyIsAllowed("continue-on-error"));
    // 近い綴りは通らない。
    try std.testing.expect(!keyIsAllowed("previews"));
    try std.testing.expect(!keyIsAllowed("Preview"));
}

test "isForbiddenInPerCommit: a path filter may skip the slow tier, not the per-commit checks" {
    // full.yml と preview.yml は、文書だけの PR で起動しないように `paths-ignore` を持つ。
    try std.testing.expect(keyIsAllowed("paths-ignore"));
    // コミットごとのワークフローが持つと、文書だけの PR で check-docs などが黙って
    // 走らなくなる。
    try std.testing.expect(isTriggerNarrowing("paths-ignore"));
    try std.testing.expect(isForbiddenInPerCommit("paths-ignore"));
    // `paths` は、どのワークフローにも置けない。置くと未知のキーとして報告される。
    try std.testing.expect(!keyIsAllowed("paths"));
    // 近い綴りは通らない。
    try std.testing.expect(!keyIsAllowed("paths_ignore"));
    try std.testing.expect(!keyIsAllowed("branches-ignore"));
}

test "keyIsAllowed: the inputs of the cache step are known" {
    try std.testing.expect(keyIsAllowed("path"));
    try std.testing.expect(keyIsAllowed("key"));
    try std.testing.expect(keyIsAllowed("use-cache"));
    // 古いキャッシュへの復元は、不完全な保存を拾う道なので、許可に入れない。
    try std.testing.expect(!keyIsAllowed("restore-keys"));
}

test "identifierCount: comments and blank lines are not identifiers" {
    try std.testing.expectEqual(@as(usize, 2), identifierCount("; a\n; b\ncar\ncdr\n"));
    try std.testing.expectEqual(@as(usize, 0), identifierCount("; only a comment\n"));
    try std.testing.expectEqual(@as(usize, 1), identifierCount("car\n\n\n"));
    try std.testing.expectEqual(@as(usize, 0), identifierCount(""));
}

test "hasTestBlock: a top-level test, not the word in prose" {
    try std.testing.expect(hasTestBlock("test \"a\" {}"));
    try std.testing.expect(hasTestBlock("const x = 1;\ntest {}\n"));
    try std.testing.expect(!hasTestBlock("// test \"a\" {}"));
    try std.testing.expect(!hasTestBlock("const testing = 1;"));
    try std.testing.expect(!hasTestBlock(""));
}

test "fenceRun: tildes and longer runs" {
    try std.testing.expectEqual(@as(u8, '~'), fenceRun("~~~").?.ch);
    try std.testing.expectEqual(@as(usize, 4), fenceRun("````").?.len);
    try std.testing.expect(fenceRun("``") == null);
    try std.testing.expect(fenceRun("not a fence") == null);
    // 末尾の空白があっても閉じる。
    try std.testing.expect(fenceRun("```   ").?.bare);
}

test "hasUriScheme: a scheme needs a colon, and matching is case-insensitive" {
    try std.testing.expect(hasUriScheme("https://example.com"));
    try std.testing.expect(hasUriScheme("HTTPS://example.com"));
    try std.testing.expect(hasUriScheme("ftp://example.com"));
    try std.testing.expect(hasUriScheme("mailto:a@b"));
    // 単なる "http" の接頭辞が、相対パスを巻き込んではならない。
    try std.testing.expect(!hasUriScheme("http-guide.md"));
    try std.testing.expect(!hasUriScheme("docs/x.md"));
    try std.testing.expect(!hasUriScheme(""));
}

test "linkDestination: a title is not part of the destination" {
    // タイトル付きのリンクは標準的な CommonMark である。タイトルをそのまま
    // ファイルシステムに渡すと、Windows でクラッシュした。
    try std.testing.expectEqualStrings("README.md", linkDestination("README.md \"The readme\")").?.target);
    try std.testing.expectEqualStrings("README.md", linkDestination("README.md 'x')").?.target);
    try std.testing.expectEqualStrings("README.md", linkDestination("<README.md>)").?.target);
    try std.testing.expectEqualStrings("a.md", linkDestination("a.md)").?.target);
    try std.testing.expect(linkDestination("no-close") == null);
}

test "zigImports: only real import expressions count" {
    const gpa = std.testing.allocator;
    var out: std.ArrayList([]const u8) = .empty;
    defer out.deinit(gpa);
    // コメントアウトされたインポートのせいで、どこからも参照されないファイルが
    // 到達可能に見えたことがある。
    try zigImports(gpa,
        \\const a = @import("real.zig");
        \\// @import("commented.zig")
        \\const s = "@import(\"instring.zig\")";
        \\const std = @import("std");
    , &out);
    try std.testing.expectEqual(@as(usize, 1), out.items.len);
    try std.testing.expectEqualStrings("real.zig", out.items[0]);
}

test "hasRefAllDeclsTest: the argument must be @This()" {
    // 別のコンテナを渡してもコンパイルは通り、慣習どおりに見えるが、参照される
    // のは別の宣言になる。
    try std.testing.expect(hasRefAllDeclsTest("test { std.testing.refAllDecls(@This()); }"));
    try std.testing.expect(!hasRefAllDeclsTest("test { std.testing.refAllDecls(std.ascii); }"));
    try std.testing.expect(!hasRefAllDeclsTest("// refAllDecls(@This())"));
    try std.testing.expect(!hasRefAllDeclsTest("comptime { refAllDecls(@This()); }"));
}

test "workflowZigVersions: every setup-zig step gets its own entry" {
    const gpa = std.testing.allocator;
    var out: std.ArrayList(StepVersion) = .empty;
    defer out.deinit(gpa);
    try workflowZigVersions(gpa,
        \\jobs:
        \\  a:
        \\    steps:
        \\      - uses: mlugg/setup-zig@abc
        \\        with:
        \\          version: 0.17.0
        \\  b:
        \\    steps:
        \\      - uses: mlugg/setup-zig@abc
        \\        with:
        \\          version: 0.18.0
    , &out);
    try std.testing.expectEqual(@as(usize, 2), out.items.len);
    try std.testing.expectEqualStrings("0.17.0", out.items[0].version.?);
    try std.testing.expectEqualStrings("0.18.0", out.items[1].version.?);
}

test "workflowZigVersions: only a version under the step's own with: counts" {
    // このテストが固定する欠陥。ステップより深くインデントされた行なら
    // 何でも受け入れていたので、`env:` など、ステップが持つ他のあらゆる
    // キーが、検査されるバージョンを供給できた。
    const gpa = std.testing.allocator;
    var out: std.ArrayList(StepVersion) = .empty;
    defer out.deinit(gpa);
    try workflowZigVersions(gpa,
        \\    steps:
        \\      - uses: mlugg/setup-zig@abc
        \\        with: { version: 0.18.1 }
        \\        env:
        \\          version: 0.17.0
    , &out);
    try std.testing.expectEqual(@as(usize, 1), out.items.len);
    try std.testing.expect(out.items[0].version == null);
}

test "workflowZigVersions: each step keeps its own version" {
    // このテストが固定する欠陥。バージョンを1つの平らなリストに集めて件数で
    // 比べていたので、一方のステップが、もう一方を満たすエントリを供給でき、
    // 実際には何をインストールしていてもよかった。
    const gpa = std.testing.allocator;
    var out: std.ArrayList(StepVersion) = .empty;
    defer out.deinit(gpa);
    try workflowZigVersions(gpa,
        \\    steps:
        \\      - uses: mlugg/setup-zig@abc
        \\        with: { version: 0.18.1 }
        \\      - uses: mlugg/setup-zig@abc
        \\        with:
        \\          version: 0.17.0
    , &out);
    try std.testing.expectEqual(@as(usize, 2), out.items.len);
    try std.testing.expect(out.items[0].version == null);
    try std.testing.expectEqualStrings("0.17.0", out.items[1].version.?);
}

test "workflowZigVersions: two versions under one with: make the step unreadable" {
    const gpa = std.testing.allocator;
    var out: std.ArrayList(StepVersion) = .empty;
    defer out.deinit(gpa);
    try workflowZigVersions(gpa,
        \\    steps:
        \\      - uses: mlugg/setup-zig@abc
        \\        with:
        \\          version: 0.17.0
        \\          version: 0.18.1
    , &out);
    try std.testing.expectEqual(@as(usize, 1), out.items.len);
    try std.testing.expect(out.items[0].extra);
}

test "workflowZigVersions: a step merely named after setup-zig supplies nothing" {
    const gpa = std.testing.allocator;
    var out: std.ArrayList(StepVersion) = .empty;
    defer out.deinit(gpa);
    try workflowZigVersions(gpa,
        \\    steps:
        \\      - name: prepare for setup-zig
        \\        uses: actions/checkout@abc
        \\        with:
        \\          version: 0.18.0
    , &out);
    try std.testing.expectEqual(@as(usize, 0), out.items.len);
}

test "workflowZigVersions: comments and decoys on the step line supply nothing" {
    const gpa = std.testing.allocator;
    var out: std.ArrayList(StepVersion) = .empty;
    defer out.deinit(gpa);
    // バージョンを含むコメントと、その下にある本物のバージョン。
    try workflowZigVersions(gpa,
        \\    steps:
        \\      - uses: mlugg/setup-zig@abc  # version: 0.17.0
        \\        with:
        \\          version: 0.18.0
    , &out);
    try std.testing.expectEqual(@as(usize, 1), out.items.len);
    try std.testing.expectEqualStrings("0.18.0", out.items[0].version.?);

    // フローマッピング。バージョンが独立した行に現れない。
    out.clearRetainingCapacity();
    try workflowZigVersions(gpa,
        \\    steps:
        \\      - { uses: "mlugg/setup-zig@abc", name: "pin version: 0.17.0" }
    , &out);
    try std.testing.expectEqual(@as(usize, 1), out.items.len);
    try std.testing.expect(out.items[0].version == null);
}

test "workflowZigVersions: a version outside the step is not the step's" {
    const gpa = std.testing.allocator;
    var out: std.ArrayList(StepVersion) = .empty;
    defer out.deinit(gpa);
    try workflowZigVersions(gpa,
        \\jobs:
        \\  fuzz:
        \\    steps:
        \\      - uses: mlugg/setup-zig@abc
        \\        with: { version: 0.18.1 }
        \\  matrix-job:
        \\    strategy:
        \\      matrix:
        \\        version: 0.17.0
        \\    steps:
        \\      - run: echo hi
    , &out);
    try std.testing.expectEqual(@as(usize, 1), out.items.len);
    try std.testing.expect(out.items[0].version == null);
}

test "workflowZigVersions: a name holding version: does not shadow the real one" {
    const gpa = std.testing.allocator;
    var out: std.ArrayList(StepVersion) = .empty;
    defer out.deinit(gpa);
    try workflowZigVersions(gpa,
        \\    steps:
        \\      - uses: mlugg/setup-zig@abc
        \\        name: "install the pinned version: see .zigversion"
        \\        with:
        \\          version: 0.17.0
    , &out);
    try std.testing.expectEqual(@as(usize, 1), out.items.len);
    try std.testing.expectEqualStrings("0.17.0", out.items[0].version.?);
}

test "visibleMarkdown: a record hidden from the reader is not a record" {
    const gpa = std.testing.allocator;
    var sink: std.Io.Writer.Discarding = .init(&.{});
    var rep: Reporter = .{ .w = &sink.writer };
    const doc =
        \\| 合計 | 557 |
        \\<!-- | 合計 | 99 | -->
        \\```
        \\| 合計 | 42 |
        \\```
        \\    | 合計 | 7 |
    ;
    const seen = try visibleMarkdown(gpa, &rep, "t.md", doc);
    defer gpa.free(seen);
    // 見える行は残る。コメントの中、フェンスの中、インデントされた行は残らない。
    switch (integerAfter(seen, "| 合計 |")) {
        .one => |v| try std.testing.expectEqual(@as(usize, 557), v),
        else => return error.TestExpectedOne,
    }
    // 診断の行がずれないように、行の構造は保つ。
    try std.testing.expectEqual(doc.len, seen.len);
    try std.testing.expectEqual(@as(usize, 0), rep.count);
}

test "visibleMarkdown: a comment in a code span is reported, not obeyed" {
    const gpa = std.testing.allocator;
    var sink: std.Io.Writer.Discarding = .init(&.{});
    var rep: Reporter = .{ .w = &sink.writer };
    // コードスパンには例外がないので、そのマーカーを含む地の文は、閉じていない
    // コメントになる。報告するのは、文書の残りが黙ってしまうのではなく、
    // 著者に文を別の書き方にするよう伝えるためである。
    const doc =
        \\HTML コメントは `<!--` で開く。
        \\| 合計 | 557 |
    ;
    const seen = try visibleMarkdown(gpa, &rep, "t.md", doc);
    defer gpa.free(seen);
    try std.testing.expectEqual(@as(usize, 1), rep.count);
    switch (integerAfter(seen, "| 合計 |")) {
        .one => |v| try std.testing.expectEqual(@as(usize, 557), v),
        else => return error.TestExpectedOne,
    }
}

test "visibleMarkdown: a comment part way along a line hides what it wraps" {
    const gpa = std.testing.allocator;
    var sink: std.Io.Writer.Discarding = .init(&.{});
    var rep: Reporter = .{ .w = &sink.writer };
    // ブラウザはブロックのコメントと同じように行内のコメントも隠すので、
    // 読者にはここで99が見える。16を読むと、誰にも見えない値を記録として
    // 採ることになる。
    const doc = "| 合計 | <!--16--> 99 |";
    const seen = try visibleMarkdown(gpa, &rep, "t.md", doc);
    defer gpa.free(seen);
    switch (integerAfter(seen, "| 合計 |")) {
        .one => |v| try std.testing.expectEqual(@as(usize, 99), v),
        else => return error.TestExpectedOne,
    }
    try std.testing.expectEqual(@as(usize, 0), rep.count);
}

test "visibleMarkdown: an opener indented under four spaces still opens" {
    const gpa = std.testing.allocator;
    var sink: std.Io.Writer.Discarding = .init(&.{});
    var rep: Reporter = .{ .w = &sink.writer };
    // インデントされた行を先に空白で潰すと、この開始が空白になり、読者には
    // 隠れている行が、あるものとして読まれた。
    const doc =
        \\  <!--
        \\| 合計 | 557 |
        \\-->
    ;
    const seen = try visibleMarkdown(gpa, &rep, "t.md", doc);
    defer gpa.free(seen);
    try std.testing.expectEqual(RecordedCount.none, integerAfter(seen, "| 合計 |"));
    try std.testing.expectEqual(@as(usize, 0), rep.count);
}

test "visibleMarkdown: a record shallower than an indented fence is kept" {
    const gpa = std.testing.allocator;
    var sink: std.Io.Writer.Discarding = .init(&.{});
    var rep: Reporter = .{ .w = &sink.writer };
    // このフェンスはフェンスではなく、インデントされたコードブロックの中身
    // なので、2つの間の行は表の行として描画される。ここで潰すと、ページに
    // 表示される表を、誰も読まないことになる。
    const doc =
        \\    ```
        \\| 合計 | 557 |
        \\    ```
    ;
    const seen = try visibleMarkdown(gpa, &rep, "t.md", doc);
    defer gpa.free(seen);
    switch (integerAfter(seen, "| 合計 |")) {
        .one => |v| try std.testing.expectEqual(@as(usize, 557), v),
        else => return error.TestExpectedOne,
    }
    try std.testing.expectEqual(@as(usize, 0), rep.count);
}

test "visibleMarkdown: an unclosed comment is reported, not obeyed" {
    const gpa = std.testing.allocator;
    var sink: std.Io.Writer.Discarding = .init(&.{});
    var rep: Reporter = .{ .w = &sink.writer };
    const doc =
        \\<!-- opened and never closed
        \\| 合計 | 557 |
    ;
    const seen = try visibleMarkdown(gpa, &rep, "t.md", doc);
    defer gpa.free(seen);
    try std.testing.expectEqual(@as(usize, 1), rep.count);
    // 文書の残りは読める状態で残す。その下の記録が黙って消えるのではなく、
    // 引き続き照合される。
    switch (integerAfter(seen, "| 合計 |")) {
        .one => |v| try std.testing.expectEqual(@as(usize, 557), v),
        else => return error.TestExpectedOne,
    }
}

test "adrRow: the row is found by the link that opens it" {
    const index =
        \\| [0005](0005-old.md) | ... | 非推奨([0019](0019-new.md)に置き換え) | 2026-10-04 |
        \\| [0019](0019-new.md) | ... | 採用 | 2026-10-05 |
    ;
    // 非推奨の行は置き換え先へのリンクも持つ。行のどのリンクでも一致とすると、
    // 0019 について2つの行が見つかってしまう。
    const row = adrRow(index, "0019-new.md").one;
    try std.testing.expect(std.mem.indexOf(u8, row, "採用") != null);
    try std.testing.expect(std.mem.indexOf(u8, row, "非推奨") == null);
    try std.testing.expect(adrRow(index, "0021-absent.md") == .none);
}

test "adrRow: a stale row left below the real one is reported" {
    // このテストが固定する欠陥。最初に一致した行が採用されたので、古い行が
    // 同じ ADR に別の状態を示していても、誰もそれを読まなかった。
    const index =
        \\| [0017](0017-a.md) | ... | 非推奨([0023](0023-b.md)に置き換え) | 2026-10-04 |
        \\| [0017](0017-a.md) | 古い行 | 採用 | 2026-10-04 |
    ;
    switch (adrRow(index, "0017-a.md")) {
        .many => |n| try std.testing.expectEqual(@as(usize, 2), n),
        else => return error.TestExpectedMany,
    }
}

test "runsCommand: extra text is accepted only as a flag" {
    try std.testing.expect(runsCommand("zig build", "zig build"));
    try std.testing.expect(runsCommand("zig build test --summary all", "zig build test"));
    // test の行が、素の build の行の代わりになってはならない。
    try std.testing.expect(!runsCommand("zig build test --summary all", "zig build"));
    try std.testing.expect(!runsCommand("zig build check-docs", "zig build check"));
    try std.testing.expect(runsCommand("zig fmt --check .", "zig fmt --check ."));
}

test "runsCommand: the per-test time limit is a suffix only with the value CI uses" {
    try std.testing.expect(runsCommand("zig build test --summary all --test-timeout 60s", "zig build test"));
    // 値を変えるなら、この検査の接尾辞の一覧を意図して変える。
    try std.testing.expect(!runsCommand("zig build test --summary all --test-timeout 1h", "zig build test"));
    try std.testing.expect(!runsCommand("zig build test --test-timeout 60s --summary all", "zig build test"));
    try std.testing.expect(!runsCommand("zig build test --test-timeout 60s", "zig build test --summary all"));
    // 時間切れの値だけを足しても、素の build の行の代わりにならない。
    try std.testing.expect(!runsCommand("zig build test --summary all --test-timeout 60s", "zig build"));
    // 従来の接尾辞は変わらず受理される。
    try std.testing.expect(runsCommand("zig build test --summary all", "zig build test"));
}

test "backtickedSpan: the command, not the note beside it" {
    try std.testing.expectEqualStrings(
        "zig build test",
        backtickedSpan(" `zig build test`(コンパイルに含まれる) ").?,
    );
    try std.testing.expect(backtickedSpan(" no backticks ") == null);
    try std.testing.expect(backtickedSpan(" `` ") == null);
}

test "hasBacktickedSpan: every span of the cell counts, not only the first" {
    const cell = " `zig build test -Dslow=true` と `zig build test-scheme -Dslow=true` ";
    try std.testing.expect(hasBacktickedSpan(cell, "zig build test -Dslow=true"));
    try std.testing.expect(hasBacktickedSpan(cell, "zig build test-scheme -Dslow=true"));
    // スパンの前半や、バッククォートの外の文字列は、コマンドではない。
    try std.testing.expect(!hasBacktickedSpan(cell, "zig build test"));
    try std.testing.expect(!hasBacktickedSpan(" zig build test `other` ", "zig build test"));
    try std.testing.expect(!hasBacktickedSpan(" `unclosed", "unclosed"));
}

test "runsCommand: the slow commands are told apart from the plain ones" {
    try std.testing.expect(runsCommand("zig build test -Dslow=true --summary all", "zig build test -Dslow=true"));
    try std.testing.expect(!runsCommand("zig build test --summary all", "zig build test -Dslow=true"));
    try std.testing.expect(!runsCommand("zig build test-scheme -Dslow=true", "zig build test -Dslow=true"));
    try std.testing.expect(!runsCommand("zig build test-scheme", "zig build test-scheme -Dslow=true"));
    try std.testing.expect(runsCommand("zig build test-wasm -Dslow=true", "zig build test-wasm -Dslow=true"));
    try std.testing.expect(!runsCommand("zig build test-wasm", "zig build test-wasm -Dslow=true"));
}

test "stripComment: a hash opens a comment only at the start or after whitespace" {
    try std.testing.expectEqualStrings("", stripComment("# all of it"));
    try std.testing.expectEqualStrings("a: ", stripComment("a: # b"));
    try std.testing.expectEqualStrings("a: b", stripComment("a: b"));
    // 前が空白ではないので、スカラーの一部である。
    try std.testing.expectEqualStrings("- name: step#3", stripComment("- name: step#3"));
}

test "stripComment: a hash inside a quoted scalar is not a comment" {
    try std.testing.expectEqualStrings("- name: \"a # b\"", stripComment("- name: \"a # b\""));
    try std.testing.expectEqualStrings("- name: 'a # b'", stripComment("- name: 'a # b'"));
    // 引用符が閉じているので、次の # はコメントを開く。
    try std.testing.expectEqualStrings("- name: \"a\" ", stripComment("- name: \"a\" # b"));
}

test "hashLengthPrefixed: moving a boundary changes the digest" {
    const Sha256 = std.crypto.hash.sha2.Sha256;
    var a = Sha256.init(.{});
    hashLengthPrefixed(&a, "x");
    hashLengthPrefixed(&a, "yz");
    var b = Sha256.init(.{});
    hashLengthPrefixed(&b, "xy");
    hashLengthPrefixed(&b, "z");
    var da: [Sha256.digest_length]u8 = undefined;
    var db: [Sha256.digest_length]u8 = undefined;
    a.final(&da);
    b.final(&db);
    // 単純に連結すると、この2つは同じバイト列になる。これは、あるファイルの
    // 内容が、記録を変えないまま、その前のファイルへ移れる仕組みである。
    try std.testing.expect(!std.mem.eql(u8, &da, &db));
}

test "isIgnored: the shapes this repository writes" {
    const patterns =
        \\# a comment
        \\_work
        \\.env.*
        \\!.env.example
        \\zig-out/
        \\.DS_Store
        \\._*
        \\*~
    ;
    try std.testing.expect(isIgnored(patterns, ".DS_Store", false));
    try std.testing.expect(isIgnored(patterns, "._base.txt", false));
    try std.testing.expect(isIgnored(patterns, "base.txt~", false));
    try std.testing.expect(isIgnored(patterns, "_work", false));
    // 末尾の `/` はディレクトリにだけ一致する。
    try std.testing.expect(isIgnored(patterns, "zig-out", true));
    try std.testing.expect(!isIgnored(patterns, "zig-out", false));
    // 記録が引き続き覆わなければならないもの。
    try std.testing.expect(!isIgnored(patterns, "base.txt", false));
    try std.testing.expect(!isIgnored(patterns, "notes.md", false));
    try std.testing.expect(!isIgnored(patterns, "sub", true));
    // コメントはパターンではない。
    try std.testing.expect(!isIgnored(patterns, "# a comment", false));
    // `!` の行は読み飛ばすので、それが再び含めるはずのものは、無視されたまま
    // になる。これは記録された上限であり、後で直したときにテストの結果が
    // 目に見えて反転するように固定してある。`.env.example` は生成物の
    // ディレクトリには現れないので、この上限は許容できる。
    try std.testing.expect(isIgnored(patterns, ".env.example", false));
}

test "isIgnored: an unrecognised shape leaves the check strict" {
    // 途中に `*` があるパターンや、`*` が複数あるパターンは解釈しない。
    // 一致してはならない。一致すると、記録がそれの名指すものを覆わなくなる。
    try std.testing.expect(!isIgnored("ba*.txt", "base.txt", false));
    try std.testing.expect(!isIgnored("*ase*", "base.txt", false));
    try std.testing.expect(!isIgnored("tests/*.txt", "base.txt", false));
}

test "countOccurrences: every non-overlapping match counts" {
    try std.testing.expectEqual(@as(usize, 0), countOccurrences("abc", "x"));
    try std.testing.expectEqual(@as(usize, 1), countOccurrences("abc", "b"));
    try std.testing.expectEqual(@as(usize, 2), countOccurrences("abab", "ab"));
    // 重ならない一致だけを数える。"aaa" に "aa" は1つあり、2つではない。
    try std.testing.expectEqual(@as(usize, 1), countOccurrences("aaa", "aa"));
}

test "hasRefAllDeclsTest: the call must be qualified" {
    // ピリオドの要件を緩めても、ほかのテストはすべて緑のままだった。そのため、
    // doc コメントが挙げているその理由が固定されていなかった。同名のローカル
    // 関数は、素の名前だけを見る検査を満たすが、何も参照しない。
    try std.testing.expect(!hasRefAllDeclsTest(
        \\test {
        \\    refAllDecls(@This());
        \\}
    ));
}

test "hasRefAllDeclsTest: a container expression is not @This()" {
    // 既存の否定例は、@This の検査ではなくトークン列の段階で落ちる。そのため、
    // 手順3を緩めて任意の識別子を受け入れるようにしても、すべてのテストが
    // 緑のままだった。このテストは、@This が要求されている間だけ失敗する。
    try std.testing.expect(!hasRefAllDeclsTest(
        \\test {
        \\    std.testing.refAllDecls(Container());
        \\}
    ));
    try std.testing.expect(hasRefAllDeclsTest(
        \\test {
        \\    std.testing.refAllDecls(@This());
        \\}
    ));
}

test "hasRefAllDeclsTest: a local qualifier passes, which is the recorded limit" {
    // 字句解析では、`fake` が何に解決されるかを判別できない。何も参照して
    // いなくても、検査は満たされる。これは open-questions.md が記録している
    // 2つの限界の1つである。後で直したときにテストの結果が目に見えて反転
    // するように、このテストを置いてある。
    try std.testing.expect(hasRefAllDeclsTest(
        \\const fake = struct {
        \\    fn refAllDecls(_: type) void {}
        \\};
        \\test {
        \\    fake.refAllDecls(@This());
        \\}
    ));
}

test "sha256InMarkdown: the recorded hash is the one the row shows" {
    const recorded = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    switch (sha256InMarkdown("| 入力の SHA-256 | `" ++ recorded ++ "` |", "入力の SHA-256")) {
        .one => |h| try std.testing.expectEqualStrings(recorded, h),
        else => return error.TestExpectedOne,
    }
}

test "sha256InMarkdown: nothing to record" {
    try std.testing.expect(sha256InMarkdown("| size | 67552 |", "入力の SHA-256") == .none);
    // 記録の名前はあるが、ハッシュが示されていない。
    try std.testing.expect(sha256InMarkdown("| 入力の SHA-256 | pending |", "入力の SHA-256") == .none);
}

test "sha256InMarkdown: a decoy makes the record ambiguous, not silently wrong" {
    const real = "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd";
    const decoy = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
    // 同じ行で、本物の前に隠してある。描画された表には、本物のハッシュが
    // そのまま表示される。
    try std.testing.expect(sha256InMarkdown(
        "| 入力の SHA-256 | <!-- " ++ decoy ++ " --> `" ++ real ++ "` |",
        "入力の SHA-256",
    ) == .ambiguous);
    // 同じラベルで、古いハッシュを持つ2つ目の行。
    const two_rows = "| 入力の SHA-256 | `" ++ decoy ++ "` |\n| 入力の SHA-256 | `" ++ real ++ "` |";
    try std.testing.expect(sha256InMarkdown(two_rows, "入力の SHA-256") == .ambiguous);
}

test "sha256InMarkdown: each label finds its own record" {
    // 1つの文書に2つのハッシュがある。SHA-256 という語だけで行を探すと、
    // 両方が見つかり、どの文書も曖昧と判定されてしまう。
    const input = "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd";
    const output = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
    const doc = "| 入力の SHA-256 | `" ++ input ++ "` |\n| 抽出結果の SHA-256 | `" ++ output ++ "` |";
    switch (sha256InMarkdown(doc, "入力の SHA-256")) {
        .one => |h| try std.testing.expectEqualStrings(input, h),
        else => return error.TestExpectedOne,
    }
    switch (sha256InMarkdown(doc, "抽出結果の SHA-256")) {
        .one => |h| try std.testing.expectEqualStrings(output, h),
        else => return error.TestExpectedOne,
    }
}

test "sha256InMarkdown: case is not part of the record" {
    const lower = "abcdef01abcdef01abcdef01abcdef01abcdef01abcdef01abcdef01abcdef01";
    const upper = "ABCDEF01ABCDEF01ABCDEF01ABCDEF01ABCDEF01ABCDEF01ABCDEF01ABCDEF01";
    // 同じハッシュが大文字小文字を変えて2回書かれていても、記録は2つではなく1つである。
    switch (sha256InMarkdown("| 入力の SHA-256 | `" ++ lower ++ "` and `" ++ upper ++ "` |", "入力の SHA-256")) {
        .one => {},
        else => return error.TestExpectedOne,
    }
}

test "fenceRun: a run of two is not a fence" {
    // 行は十分に長いが、連なりが短いときにだけ到達する。長さのガードだけでは
    // 覆えない経路である。
    try std.testing.expect(fenceRun("``x") == null);
    try std.testing.expect(fenceRun("~~x") == null);
    try std.testing.expect(fenceRun("```") != null);
}

test "pathIn compares whole paths" {
    const haystack = [_][]const u8{ "src/wasm.zig", "src/main.zig" };
    try std.testing.expect(pathIn(&haystack, "src/wasm.zig"));
    // 基底名で照合すると、src/platform/wasm.zig まで除外してしまう。
    try std.testing.expect(!pathIn(&haystack, "src/platform/wasm.zig"));
    try std.testing.expect(!pathIn(&haystack, "wasm.zig"));
}

test "normalizePath resolves . and .. so an import chain matches" {
    const gpa = std.testing.allocator;
    const a = try normalizePath(gpa, "src/sub/../other.zig");
    defer gpa.free(a);
    try std.testing.expectEqualStrings("src/other.zig", a);
    const b = try normalizePath(gpa, "src/./x.zig");
    defer gpa.free(b);
    try std.testing.expectEqualStrings("src/x.zig", b);
}
