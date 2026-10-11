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

/// A row of the verification command table, as this check reads it.
///
/// この検査が読み取る、検証コマンド表の1行。
const CommandRow = struct {
    command: []const u8,
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
    // コミットごとのワークフローが実際に持つキーと値。ワークフローが走るかどうかを
    // 決めるものを、閉じた集合に固定できるようにする。
    var seen: std.ArrayList(struct { key: []const u8, value: []const u8 }) = .empty;
    for (workflows.items) |path| {
        const per_commit = std.mem.eql(u8, path, per_commit_workflow);
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
            // 変えてしまう。
            if (per_commit and isTriggerNarrowing(key)) {
                rep.fail(
                    "{s}:{d}: `{s}` is not allowed in the workflow that runs on every commit; it changes when the commit's checks run",
                    .{ path, lineno, key },
                );
                continue;
            }
            if (per_commit) try seen.append(gpa, .{
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
        .{ .key = "os", .value = "[ubuntu-latest, windows-latest]" },
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
        const command = backtickedSpan(cellAt(row, 1).?) orelse continue;
        const stage_cell = std.mem.trim(u8, cellAt(row, 2).?, &std.ascii.whitespace);
        const ci_cell = std.mem.trim(u8, cellAt(row, 3).?, &std.ascii.whitespace);
        try table_rows.append(gpa, .{
            .command = command,
            .stage = std.fmt.parseInt(usize, stage_cell, 10) catch null,
            .every_commit = std.mem.eql(u8, ci_cell, "全コミット"),
        });
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
    "name",               "on",           "permissions",       "concurrency", "jobs",
    "push",               "pull_request", "branches",          "contents",    "group",
    "cancel-in-progress", "types",        "workflow_dispatch",
    // ジョブのレベル。
    "runs-on",     "strategy",
    "fail-fast",          "matrix",       "steps",             "os",
    // step のレベル。
             "uses",
    "with",               "version",      "run",
};

/// Whether `key` is one of the allowed keys, or a job name.
///
/// ジョブ名はこのリポジトリが決めるので、一覧にできない。`jobs:` の下のジョブの
/// 字下げにあるキーは、その深さに紛らわしいものが他に無いワークフローでは受理
/// する。現状は `test` だけである。
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
    return std.mem.eql(u8, key, "types") or std.mem.eql(u8, key, "workflow_dispatch");
}

/// The job names this repository's workflows define.
///
/// このリポジトリのワークフローが定義するジョブ名。
const allowed_job_names = [_][]const u8{ "test", "slow" };

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
const allowed_run_suffixes = [_][]const u8{"--summary all"};

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
    /// The label appears in several rows with differing values.
    ambiguous,
};

/// The integer recorded beside `label` in a Markdown table row.
///
/// Only lines that open a table row are considered. Searching the whole
/// document found the label in prose first and read whatever number happened
/// to follow it: the sentence explaining the hash encoding names two
/// libraries, and one of them is followed by its own count in words. Every
/// matching row is read and the values must agree, for the same reason
/// `sha256InMarkdown` refuses to pick one of several.
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
        // Parsed rather than accumulated by hand: accumulating overflowed on a
        // long run of digits and panicked, losing every diagnostic gathered so
        // far. A value that does not parse is not skipped either, or a record
        // too large to be a count would read as no record at all.
        const value = std.fmt.parseInt(usize, line[digits_at..i], 10) catch return .ambiguous;

        if (found) |first| {
            if (first != value) return .ambiguous;
        } else found = value;
    }
    return if (found) |v| .{ .one = v } else .none;
}

/// Reports anything in `dir` that the recorded hash does not cover.
///
/// `collectFiles` in flat mode returns the directory's own files with the right
/// extension, so a subdirectory or another extension would sit beside the
/// generated lists uncovered. The provenance document claims the record fixes
/// the directory, so the directory holds nothing else.
///
/// Nothing else that is part of the repository, that is. An entry `.gitignore`
/// ignores is left out, because a correct repository should not go red when
/// macOS writes a `.DS_Store` or an editor leaves a `base.txt~`.
///
/// The ignore test comes before the extension test, not after. Applying it only
/// to entries whose extension did not match left `._base.txt` -- what macOS
/// writes beside a tracked file, and what `.gitignore` names -- passing as a
/// generated list: it entered the hash and the identifier counts, and a correct
/// repository reported three problems. The same order is why `collectFiles`
/// takes the ignore set too, so the file this check accepts and the files the
/// hash covers are the same set.
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
/// Only the pattern shapes this repository writes are understood: an exact
/// name, a trailing `/` for a directory, and a single leading or trailing `*`.
/// A shape outside that set never matches, so an unrecognised pattern leaves
/// the check as strict as it was. Erring that way means a new pattern shape
/// shows up as a check failure to be looked at, not as a silent hole in what
/// the recorded hash covers.
///
/// A pattern that would match every name is one of the shapes left out. A bare
/// `*` turned every check that consults this function off at once, which is a
/// larger hole than any single name could open.
///
/// Negations are among the shapes left out: a `!` line is skipped, which keeps
/// a pattern it re-includes ignored. The only negation here re-includes
/// `.env.example`, which belongs in no generated directory.
fn isIgnored(gitignore: []const u8, name: []const u8, is_dir: bool) bool {
    var lines = std.mem.splitScalar(u8, gitignore, '\n');
    while (lines.next()) |raw| {
        var pattern = std.mem.trim(u8, raw, &std.ascii.whitespace);
        if (pattern.len == 0 or pattern[0] == '#' or pattern[0] == '!') continue;

        // A trailing slash restricts the pattern to directories.
        if (pattern[pattern.len - 1] == '/') {
            if (!is_dir) continue;
            pattern = pattern[0 .. pattern.len - 1];
            if (pattern.len == 0) continue;
        }

        // A path-shaped pattern is anchored, and this compares one entry name.
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
    // tools/ holds most of stage 0's logic and is verification code itself, so
    // it is subject to the same reachability and refAllDecls rules as src/.
    for ([_][]const u8{ "src", "tools" }) |root|
        try collectFiles(gpa, io, cwd, ignore, root, ".zig", &files, .recursive);

    var reachable: std.StringHashMapUnmanaged(void) = .empty;
    for (roots) |r| {
        if (!pathIn(files.items, r)) rep.fail("test root {s} does not exist", .{r});
        try reachable.put(gpa, r, {});
    }
    // A root with no test block of its own still contributes a run step, so
    // build.zig's count of run steps would be satisfied while that module runs
    // nothing. The count says a test was launched; this says there was a test
    // to launch.
    for (roots) |r| {
        const body = read(gpa, io, cwd, rep, r) orelse continue;
        if (!hasTestBlock(body))
            rep.fail("test root {s} declares no test, so its run step executes nothing", .{r});
    }
    for (excluded) |e| {
        if (!pathIn(files.items, e)) rep.fail("excluded file {s} does not exist", .{e});
    }

    // Every file is read once, before either loop below. Reading inside the
    // fixpoint loop reported one unreadable file as several problems, because
    // that loop revisits every reachable path on each pass. An exclusion keeps
    // a file from being a test target; it does not make the file unreadable, so
    // a read failure is reported whether or not the path is excluded.
    // The sentinel is what lets zigImports hand a body to std.zig.Tokenizer.
    var bodies: std.StringHashMapUnmanaged([:0]const u8) = .empty;
    for (files.items) |path| {
        if (read(gpa, io, cwd, rep, path)) |body| try bodies.put(gpa, path, body);
    }

    // Repeat until nothing new is reached: imports form a DAG of unknown depth.
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
                // Normalise: an import written as "../other.zig" would
                // otherwise produce src/sub/../other.zig and never match the
                // collected src/other.zig, reporting a file whose tests do run
                // as unreachable.
                const key = try normalizePath(gpa, joined);
                if (!reachable.contains(key)) {
                    try reachable.put(gpa, key, {});
                    changed = true;
                }
            }
        }
    }

    for (files.items) |path| {
        // Exclusions are full repository-relative paths: matching on the base
        // name alone would also exclude src/platform/wasm.zig.
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
/// Separators are normalised to `/`.
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

/// Collects the `*.zig` paths named by real `@import` expressions. Tokenizing
/// keeps commented-out and string-embedded occurrences out of the result.
/// Zig requires a string literal as the operand, so there is no way to hide an
/// import behind a constant.
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
/// The argument must be `@This()`: passing another container compiles and reads
/// like the convention but references the wrong declarations, so the imported
/// file's tests still never run.
///
/// The call must also be qualified: a local `fn refAllDecls` shadowing the std
/// one passes a bare-name check while referencing nothing.
///
/// This cannot prove the call is reached. `comptime { if (false) ... }` inside a
/// test block passes the check and has no effect. Nor can it prove the qualifier
/// resolves to std.testing: a local `const fake = struct { fn refAllDecls(_:
/// type) void {} };` referenced as `fake.refAllDecls(@This())` passes. Both
/// limits are recorded as implementation-time questions in
/// docs/design/open-questions.md.
fn hasRefAllDeclsTest(source: [:0]const u8) bool {
    var tok = std.zig.Tokenizer.init(source);
    var depth: usize = 0;
    var test_depth: ?usize = null;
    // The call is five tokens: refAllDecls ( @This ( ) — the closing paren of
    // refAllDecls follows.
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
            // `.refAllDecls` after a period: the call has to be qualified, so a
            // locally defined function of the same name does not satisfy it.
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
// 4. Markdown: relative links resolve.
//
// Links inside fenced code blocks are skipped: docs/adr/README.md shows a
// deprecation template whose links are placeholders by design. An unclosed
// fence would take the rest of the file with them, so it is reported.
// ---------------------------------------------------------------------------

fn checkMarkdown(
    gpa: std.mem.Allocator,
    io: std.Io,
    cwd: std.Io.Dir,
    rep: *Reporter,
    ignore: []const u8,
) !void {
    // Walk the whole repository: a fixed directory list left .agents/,
    // .claude/ and .github/ unchecked, which is a quarter of the Markdown.
    var files: std.ArrayList([]const u8) = .empty;
    try collectFiles(gpa, io, cwd, ignore, ".", ".md", &files, .recursive);

    for (files.items) |path| {
        const body = read(gpa, io, cwd, rep, path) orelse continue;
        const dir = std.fs.path.dirnamePosix(path) orelse ".";

        // A fence is closed by a run of the same character at least as long as
        // the opener, so ``` inside a ```` block does not end it.
        var fence: ?struct { ch: u8, len: usize } = null;
        var fence_line: usize = 0;
        // The column the innermost open list item's content starts at, which is
        // what CommonMark measures indentation against.
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
                    // A line shallower than the item's content closes it.
                    content_col = 0;
                }
            }
            // Four columns past the containing block's content is an indented
            // code block, not a fence and not prose. Allowing a fence at any
            // indentation let a pair of them at four spaces hide the paragraph
            // between them: the lines read as a fenced block, the paragraph
            // inside it was never checked for links, and the fences were closed
            // so nothing was reported. Measuring against the list item's
            // content column keeps the fences docs/adr/README.md writes inside
            // a numbered item, which sit five spaces in and zero columns past
            // their content.
            const relative = run.cols - @min(run.cols, content_col);
            if (relative >= 4) continue;

            if (fenceRun(trimmed)) |opener| {
                if (fence) |open| {
                    // Only a bare run of the same character, at least as long,
                    // closes the block. Anything else is content.
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
        // Reported because the link check stops at an open fence. ADR-0026 keeps
        // the reachability of relative links; leaving a fence unclosed took the
        // rest of the file out of that check and said nothing, which is the one
        // thing the first of its three facts forbids.
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
    // tabs". A line like ```zig opens a block; treating it as a close turns one
    // valid document into two false positives.
    const rest = std.mem.trim(u8, trimmed[n..], " \t");
    // CommonMark: "If the info string comes after a backtick fence, it may not
    // contain any backtick characters." So ```a`b` is a paragraph holding a code
    // span, not a fence. Reading it as a fence opened a block that nothing
    // closed, which both reported a fence that is not there and took every link
    // below it out of the check.
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
    // Code spans are skipped by CommonMark's own rule: a run of backticks opens
    // a span that only a run of the same length closes, and a backslash escapes
    // the character after it.
    //
    // Two weaker rules came before this one and both failed silently. Toggling
    // on every backtick let the parity of the line decide, so one unmatched
    // backtick before a link took the link out of the check. Requiring a closing
    // backtick anywhere on the line fixed that case and left two more: `\`` is
    // an escaped literal that the toggle still counted, and a run of three or
    // five backticks does not pair with a single one. Matching run lengths is
    // the rule the renderer uses, so there is no shorter spelling left to find.
    while (i < line.len) {
        if (line[i] == '\\') {
            i += 2; // the escaped character, backtick or not
            continue;
        }
        if (line[i] == '`') {
            var run = i;
            while (run < line.len and line[run] == '`') run += 1;
            const len = run - i;
            if (closingBacktickRun(line, run, len)) |close| {
                i = close + len;
            } else {
                // No run of the same length follows, so these backticks are
                // text and what comes after them is read as usual.
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
            // Reported rather than skipped. CommonMark lets a newline sit
            // between the parentheses, so a link whose destination or closing
            // parenthesis is on the next line renders as a link while one line
            // at a time cannot read it. Skipping it was silence on a link that
            // renders, which is the shape of every hole this program has had,
            // and the same decision was already taken for the reference form.
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
/// `indent` is where the marker starts and `trimmed` is the line from there.
/// CommonMark measures everything inside an item against this column, which is
/// why a fence five spaces in is a fence when it sits in an item whose content
/// starts there.
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
/// Exactly that length: CommonMark closes a code span only with a run of the
/// same size, so a single backtick does not close a run of three. A longer run
/// is passed over rather than treated as a match, because it is not one.
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
/// `checkLinksOnLine` looks for `](`, which a definition does not carry, so a
/// link written in the reference form had its destination read by nobody: the
/// rendered page pointed at a file that is not there and nothing said so.
const Definition = union(enum) {
    /// The destination, on the same line as the label.
    target: []const u8,
    /// A definition this check cannot read, because CommonMark allows the
    /// destination on the next line and this reads one line at a time.
    /// Reported rather than skipped: skipping it was silence on a link that
    /// renders, which is the shape of every hole this program has had.
    unreadable,
};

fn referenceDefinition(raw: []const u8) ?Definition {
    // A definition inside a block quote or a list item is still a definition,
    // and the renderer resolves a reference to it. Reading only the line as it
    // stands left `> [label]: dest` and `- [label]: dest` unread and unreported.
    var line = raw;
    while (true) {
        const before = line;
        // A quote marker takes no space after it, and a list marker may be a
        // number. Stripping only `> `, `- `, `* ` and `+ ` left `>[label]:`,
        // `>> [label]:`, `1. [label]:` and a tab after the marker unread and
        // unreported, which is the closed-set discipline failing open.
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
    // The label ends at the first `]` that is not escaped, as CommonMark reads
    // it. Rejecting a label that holds any bracket let `[a\]b]: dest` through
    // unread: the renderer takes it as a definition and this did not.
    var close: ?usize = null;
    var i: usize = 1;
    while (i < line.len) : (i += 1) {
        if (line[i] == '\\') {
            i += 1;
            continue;
        }
        if (line[i] == '[') return null; // an unescaped bracket is not a label
        if (line[i] == ']') {
            close = i;
            break;
        }
    }
    const label_end = close orelse return null;
    if (label_end + 1 >= line.len or line[label_end + 1] != ':') return null;
    var rest = std.mem.trimStart(u8, line[label_end + 2 ..], " \t");
    if (rest.len == 0) return .unreadable;
    // A title may follow the destination on the same line.
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
    // Any URI scheme, matched case-insensitively: RFC 3986 makes schemes
    // case-insensitive, and a bare "http" prefix would also skip the
    // relative path http-guide.md.
    if (hasUriScheme(target)) return;
    if (target[0] == '#') return;
    const file_part = std.mem.sliceTo(target, '#');
    if (file_part.len == 0) return;
    // Reject characters a path cannot hold before touching the file system:
    // std.Io.Dir.access panics on Windows for an invalid name rather than
    // returning an error, which would turn one bad link into a crash that
    // loses every other diagnostic.
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
/// Handles `<dest>`, `dest`, `dest "title"`, `dest 'title'` and `dest (title)`.
fn linkDestination(rest: []const u8) ?struct { target: []const u8, consumed: usize } {
    if (rest.len == 0) return null;
    if (rest[0] == '<') {
        const close = std.mem.indexOfScalar(u8, rest, '>') orelse return null;
        const end = std.mem.indexOfScalarPos(u8, rest, close, ')') orelse return null;
        return .{ .target = rest[1..close], .consumed = end };
    }
    const close = std.mem.indexOfScalar(u8, rest, ')') orelse return null;
    var target = std.mem.trim(u8, rest[0..close], " \t");
    // Strip a title. Backslash escapes are not handled: a destination such as
    // `a\ b.md` is reported under the truncated name. No file in this
    // repository needs one, and handling them means implementing CommonMark's
    // escape rules.
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

/// Collects paths under `root` whose name ends with `suffix`. Paths are
/// repository-relative and use `/` on every platform.
/// Collects the files under `root` whose name ends in `suffix`.
///
/// Entries `.gitignore` names are left out, files and directories alike. They
/// are not tracked, so they are not what the checks are about: a scratch note
/// under an ignored directory was failing the Markdown checks, and an
/// AppleDouble file macOS writes beside a tracked one was entering the
/// generated lists' hash. Reading the ignore set here keeps the set of files
/// every check sees the same, and keeps `.gitignore` the one place that
/// declares it.
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
// Tests
//
// These cover the pure decision functions: the parts whose mistakes show up as
// a check that quietly stops catching things. Every case below is one that an
// adversarial review actually produced against an earlier version of this
// file, so a regression reintroduces a known hole rather than a hypothetical.
// ---------------------------------------------------------------------------

test "fenceRun: an info string means the line opens, never closes" {
    // ```zig must not be read as a closing fence; doing so made one valid
    // document report a stray link plus an unclosed fence.
    const open = fenceRun("```zig").?;
    try std.testing.expect(!open.bare);
    const close = fenceRun("```").?;
    try std.testing.expect(close.bare);
    try std.testing.expectEqual(@as(usize, 3), close.len);
    try std.testing.expectEqual(@as(u8, '`'), close.ch);
}

test "fenceRun: a backtick in the info string means it is not a fence" {
    // The defect this pins: CommonMark forbids a backtick in a backtick fence's
    // info string, so ```a`b is a paragraph holding a code span. Reading it as a
    // fence opened a block nothing closed, which took every link below it out of
    // the check.
    try std.testing.expect(fenceRun("```a`b") == null);
    try std.testing.expect(fenceRun("```[x](d.md)```") == null);
    try std.testing.expect(fenceRun("```zig") != null);
    // A tilde fence may hold a backtick in its info string.
    try std.testing.expect(fenceRun("~~~a`b") != null);
}

test "closingBacktickRun: only a run of the same length closes a span" {
    // The defect this pins: a single backtick does not close a run of three, and
    // counting backticks one at a time let an escaped or longer run leave the
    // scan inside a span for the rest of the line.
    try std.testing.expectEqual(@as(?usize, 4), closingBacktickRun("a `b` c", 3, 1));
    try std.testing.expectEqual(@as(?usize, null), closingBacktickRun("``` x ` y", 3, 3));
    try std.testing.expectEqual(@as(?usize, 6), closingBacktickRun("``` x ``` y", 3, 3));
    // A longer run is passed over, not taken as a match.
    try std.testing.expectEqual(@as(?usize, 9), closingBacktickRun("a ```` b ` c", 2, 1));
    try std.testing.expectEqual(@as(?usize, null), closingBacktickRun("no ticks", 0, 1));
}

test "listContentColumn: where an item's content starts" {
    // The column a fence inside the item is measured against. Without it, a pair
    // of fences four spaces in read as a fenced block and hid the paragraph
    // between them from the link check.
    try std.testing.expectEqual(@as(?usize, 2), listContentColumn(0, "- a"));
    try std.testing.expectEqual(@as(?usize, 5), listContentColumn(2, "1. a"));
    try std.testing.expectEqual(@as(?usize, 3), listContentColumn(0, "1) a"));
    try std.testing.expectEqual(@as(?usize, 4), listContentColumn(0, "-   a"));
    try std.testing.expectEqual(@as(?usize, null), listContentColumn(0, "-a"));
    try std.testing.expectEqual(@as(?usize, null), listContentColumn(0, "a - b"));
    try std.testing.expectEqual(@as(?usize, null), listContentColumn(0, "1.a"));
}

test "referenceDefinition: the markers a definition may sit behind" {
    // The defect this pins: a quote marker takes no space after it and a list
    // marker may be a number, so `>[l]:`, `>> [l]:` and `1. [l]:` are
    // definitions the renderer resolves. Stripping only `> `, `- `, `* ` and
    // `+ ` left them unread and unreported.
    try std.testing.expectEqualStrings("d.md", referenceDefinition("[l]: d.md").?.target);
    try std.testing.expectEqualStrings("d.md", referenceDefinition(">[l]: d.md").?.target);
    try std.testing.expectEqualStrings("d.md", referenceDefinition(">> [l]: d.md").?.target);
    try std.testing.expectEqualStrings("d.md", referenceDefinition("1. [l]: d.md").?.target);
    try std.testing.expectEqualStrings("d.md", referenceDefinition("- [l]: d.md").?.target);
    // The label ends at the first unescaped bracket, as CommonMark reads it.
    try std.testing.expectEqualStrings("d.md", referenceDefinition("[a\\]b]: d.md").?.target);
    // A title after the destination is not part of it, and `<d>` is.
    try std.testing.expectEqualStrings("d.md", referenceDefinition("[l]: d.md \"t\"").?.target);
    try std.testing.expectEqualStrings("d.md", referenceDefinition("[l]: <d.md>").?.target);
    // No destination on the line is reported, not skipped.
    try std.testing.expect(referenceDefinition("[l]:").? == .unreadable);
    try std.testing.expect(referenceDefinition("[l]:   ").? == .unreadable);
    // Prose that merely holds a bracket and a colon is not a definition.
    try std.testing.expect(referenceDefinition("[参考] 次の節: 使い方") == null);
    try std.testing.expect(referenceDefinition("see [a](b.md): yes") == null);
    try std.testing.expect(referenceDefinition("no bracket here") == null);
}

test "yamlKey: the spellings Actions treats as a bare key are refused" {
    try std.testing.expectEqualStrings("run", yamlKey("run: zig build").?);
    try std.testing.expectEqualStrings("on", yamlKey("on:").?);
    // A quoted key and a space before the colon are spellings Actions accepts
    // and this check refuses, so that they are reported rather than misread.
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
    // Known keys, so the slow-tier workflow can use them.
    try std.testing.expect(keyIsAllowed("types"));
    try std.testing.expect(keyIsAllowed("workflow_dispatch"));
}

test "keyIsAllowed: the set is closed and holds no conditional" {
    try std.testing.expect(keyIsAllowed("run"));
    try std.testing.expect(keyIsAllowed("jobs"));
    try std.testing.expect(keyIsAllowed("test")); // the one allowed job name
    // Absent on purpose: a verification that is skipped or forgiven has stopped.
    try std.testing.expect(!keyIsAllowed("if"));
    try std.testing.expect(!keyIsAllowed("continue-on-error"));
    try std.testing.expect(!keyIsAllowed("needs"));
    try std.testing.expect(!keyIsAllowed("verify"));
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
    // Trailing whitespace still closes.
    try std.testing.expect(fenceRun("```   ").?.bare);
}

test "hasUriScheme: a scheme needs a colon, and matching is case-insensitive" {
    try std.testing.expect(hasUriScheme("https://example.com"));
    try std.testing.expect(hasUriScheme("HTTPS://example.com"));
    try std.testing.expect(hasUriScheme("ftp://example.com"));
    try std.testing.expect(hasUriScheme("mailto:a@b"));
    // A bare "http" prefix must not swallow a relative path.
    try std.testing.expect(!hasUriScheme("http-guide.md"));
    try std.testing.expect(!hasUriScheme("docs/x.md"));
    try std.testing.expect(!hasUriScheme(""));
}

test "linkDestination: a title is not part of the destination" {
    // A titled link is standard CommonMark; passing the title through to the
    // file system crashed on Windows.
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
    // A commented-out import once made an unreferenced file look reachable.
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
    // Passing another container compiles and reads like the convention but
    // references the wrong declarations.
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
    // The defect this pins: any line indented deeper than the step was
    // accepted, so `env:` and every other key a step carries could supply
    // the version that got checked.
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
    // The defect this pins: versions were collected into one flat list and
    // compared by count, so one step could supply the entry that satisfied
    // the other while installing anything.
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
    // A comment carrying a version, and the real one below it.
    try workflowZigVersions(gpa,
        \\    steps:
        \\      - uses: mlugg/setup-zig@abc  # version: 0.17.0
        \\        with:
        \\          version: 0.18.0
    , &out);
    try std.testing.expectEqual(@as(usize, 1), out.items.len);
    try std.testing.expectEqualStrings("0.18.0", out.items[0].version.?);

    // A flow mapping, which keeps the version off a line of its own.
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
    // The visible row survives; the commented, fenced and indented ones do not.
    switch (integerAfter(seen, "| 合計 |")) {
        .one => |v| try std.testing.expectEqual(@as(usize, 557), v),
        else => return error.TestExpectedOne,
    }
    // Line structure is kept so diagnostics still line up.
    try std.testing.expectEqual(doc.len, seen.len);
    try std.testing.expectEqual(@as(usize, 0), rep.count);
}

test "visibleMarkdown: a comment in a code span is reported, not obeyed" {
    const gpa = std.testing.allocator;
    var sink: std.Io.Writer.Discarding = .init(&.{});
    var rep: Reporter = .{ .w = &sink.writer };
    // There is no exception for code spans, so prose carrying the marker is an
    // unclosed comment. Reporting it is what tells the author to write the
    // sentence another way, instead of the rest of the document going quiet.
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
    // A browser hides an inline comment as it hides a block one, so a reader
    // sees 99 here. Reading 16 took a value nobody could see as the record.
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
    // Blanking the indented lines first turned this opener into spaces, so the
    // row it hides from the reader was read as present.
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
    // The fence is an indented code block's content rather than a fence, so the
    // row between the two renders as a row. Blanking it here left nobody
    // reading a table the page shows.
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
    // The rest of the document is left readable, so the records below are still
    // compared rather than silently absent.
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
    // A 非推奨 row also links to its replacement, so matching any link on
    // the row would find two rows for 0019.
    const row = adrRow(index, "0019-new.md").one;
    try std.testing.expect(std.mem.indexOf(u8, row, "採用") != null);
    try std.testing.expect(std.mem.indexOf(u8, row, "非推奨") == null);
    try std.testing.expect(adrRow(index, "0021-absent.md") == .none);
}

test "adrRow: a stale row left below the real one is reported" {
    // The defect this pins: the first match won, so an outdated row showed
    // a second status for the same ADR and nothing read it.
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
    // The test line must not stand in for the plain build row.
    try std.testing.expect(!runsCommand("zig build test --summary all", "zig build"));
    try std.testing.expect(!runsCommand("zig build check-docs", "zig build check"));
    try std.testing.expect(runsCommand("zig fmt --check .", "zig fmt --check ."));
}

test "backtickedSpan: the command, not the note beside it" {
    try std.testing.expectEqualStrings(
        "zig build test",
        backtickedSpan(" `zig build test`(コンパイルに含まれる) ").?,
    );
    try std.testing.expect(backtickedSpan(" no backticks ") == null);
    try std.testing.expect(backtickedSpan(" `` ") == null);
}

test "stripComment: a hash opens a comment only at the start or after whitespace" {
    try std.testing.expectEqualStrings("", stripComment("# all of it"));
    try std.testing.expectEqualStrings("a: ", stripComment("a: # b"));
    try std.testing.expectEqualStrings("a: b", stripComment("a: b"));
    // Not whitespace before it, so it belongs to the scalar.
    try std.testing.expectEqualStrings("- name: step#3", stripComment("- name: step#3"));
}

test "stripComment: a hash inside a quoted scalar is not a comment" {
    try std.testing.expectEqualStrings("- name: \"a # b\"", stripComment("- name: \"a # b\""));
    try std.testing.expectEqualStrings("- name: 'a # b'", stripComment("- name: 'a # b'"));
    // The quote closes, so the next hash does open a comment.
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
    // Plain concatenation gives these two the same bytes, which is how one
    // file's content moved into the file before it with the record unchanged.
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
    // A trailing slash matches a directory and nothing else.
    try std.testing.expect(isIgnored(patterns, "zig-out", true));
    try std.testing.expect(!isIgnored(patterns, "zig-out", false));
    // What the record must keep covering.
    try std.testing.expect(!isIgnored(patterns, "base.txt", false));
    try std.testing.expect(!isIgnored(patterns, "notes.md", false));
    try std.testing.expect(!isIgnored(patterns, "sub", true));
    // A comment is not a pattern.
    try std.testing.expect(!isIgnored(patterns, "# a comment", false));
    // A `!` line is skipped, so what it re-includes stays ignored. This is the
    // recorded limit, pinned so a later fix flips it visibly. `.env.example`
    // belongs in no generated directory, which is why the limit is acceptable.
    try std.testing.expect(isIgnored(patterns, ".env.example", false));
}

test "isIgnored: an unrecognised shape leaves the check strict" {
    // A pattern with a star in the middle, or more than one, is not understood.
    // It must not match, or the record would stop covering what it names.
    try std.testing.expect(!isIgnored("ba*.txt", "base.txt", false));
    try std.testing.expect(!isIgnored("*ase*", "base.txt", false));
    try std.testing.expect(!isIgnored("tests/*.txt", "base.txt", false));
}

test "countOccurrences: every non-overlapping match counts" {
    try std.testing.expectEqual(@as(usize, 0), countOccurrences("abc", "x"));
    try std.testing.expectEqual(@as(usize, 1), countOccurrences("abc", "b"));
    try std.testing.expectEqual(@as(usize, 2), countOccurrences("abab", "ab"));
    // Non-overlapping: "aaa" holds one "aa", not two.
    try std.testing.expectEqual(@as(usize, 1), countOccurrences("aaa", "aa"));
}

test "hasRefAllDeclsTest: the call must be qualified" {
    // Loosening the period requirement left all other tests green, so the
    // reason the doc comment gives for it was unpinned: a local fn of the same
    // name satisfies a bare-name check while referencing nothing.
    try std.testing.expect(!hasRefAllDeclsTest(
        \\test {
        \\    refAllDecls(@This());
        \\}
    ));
}

test "hasRefAllDeclsTest: a container expression is not @This()" {
    // The existing negative example falls at the token sequence rather than at
    // the @This check, so loosening step 3 to accept any identifier left every
    // test green. This one fails only while @This is required.
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
    // Lexing cannot tell what `fake` resolves to. The check is satisfied while
    // nothing is referenced. This is one of the two limits open-questions.md
    // records; the test is here so a later fix flips it visibly.
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
    // Names the record but shows no hash.
    try std.testing.expect(sha256InMarkdown("| 入力の SHA-256 | pending |", "入力の SHA-256") == .none);
}

test "sha256InMarkdown: a decoy makes the record ambiguous, not silently wrong" {
    const real = "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd";
    const decoy = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
    // Hidden ahead of the real one on the same row, where the rendered table
    // still shows the real hash.
    try std.testing.expect(sha256InMarkdown(
        "| 入力の SHA-256 | <!-- " ++ decoy ++ " --> `" ++ real ++ "` |",
        "入力の SHA-256",
    ) == .ambiguous);
    // A second row carrying the same label with an older hash.
    const two_rows = "| 入力の SHA-256 | `" ++ decoy ++ "` |\n| 入力の SHA-256 | `" ++ real ++ "` |";
    try std.testing.expect(sha256InMarkdown(two_rows, "入力の SHA-256") == .ambiguous);
}

test "sha256InMarkdown: each label finds its own record" {
    // One document holds two hashes. Looking a row up by the word SHA-256
    // alone would find both and call every document ambiguous.
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
    // One hash written twice in different case is one record, not two.
    switch (sha256InMarkdown("| 入力の SHA-256 | `" ++ lower ++ "` and `" ++ upper ++ "` |", "入力の SHA-256")) {
        .one => {},
        else => return error.TestExpectedOne,
    }
}

test "fenceRun: a run of two is not a fence" {
    // Reached only when the line is long enough but the run is not, which the
    // length guard alone does not cover.
    try std.testing.expect(fenceRun("``x") == null);
    try std.testing.expect(fenceRun("~~x") == null);
    try std.testing.expect(fenceRun("```") != null);
}

test "pathIn compares whole paths" {
    const haystack = [_][]const u8{ "src/wasm.zig", "src/main.zig" };
    try std.testing.expect(pathIn(&haystack, "src/wasm.zig"));
    // A base-name match would also exclude src/platform/wasm.zig.
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
