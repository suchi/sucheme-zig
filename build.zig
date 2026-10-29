const std = @import("std");
const builtin = @import("builtin");

/// The pinned Zig version.
/// `.zigversion` が唯一の情報源である(ADR-0001)。build.zig.zon の
/// `minimum_zig_version` はその複製で、tools/check-docs が一致を検査する。
/// Zig 自身は一致を強制しない。
const pinned_zig_version = @embedFile(".zigversion");

/// Repository-relative paths that must not become `addTest` targets.
/// 基本名ではなく完全なパスで書く。`wasm.zig` だけでは src/platform/wasm.zig
/// まで除外してしまう。
///
/// 段階0では空である。段階1が "src/wasm.zig" を足す。wasm32-freestanding 向けの
/// テストランナーはコンパイルできない。std のランナーが、その対象にない posix の
/// 宣言に届くからである。存在しないファイルを挙げた項目は tools/check-docs が
/// 拒むので、項目はファイルと同時に足し、先回りして足さない。
///
/// これは逃げ道であり、項目がそれに値するかを確かめる検査はない。ここに名前を足し、
/// 同じモジュールを `targets` から外すと、検査がすべて緑のまま、そのファイルの
/// テストが走らなくなる。そのため項目には、テストの対象にできない理由を添える。
/// 理由は、不便なだけのものではなく、テストを不可能にしているものを名指す。
/// 理由を機械で検査できるようにするかは、docs/design/open-questions.md に
/// 実装時の問いとして記録してあり、最初の実際の項目が来たときに決める。
const test_excluded = [_][]const u8{
    // wasm32-freestanding ビルドのルート。このファイルのテストは、ネイティブの
    // 対象にできない(ネイティブのリンカにない `extern "env"` 関数を宣言している)
    // うえ、wasm32-freestanding のテストランナーもコンパイルできない。
    // `zig build test-wasm` が Node.js からこのファイルのエクスポートを呼んで
    // 検証する。
    "src/wasm.zig",
};

/// The stage this repository has reached, as docs/roadmap.md numbers them.
///
/// tools/check-docs に渡される。AGENTS.md の検証コマンド表のどの行を CI
/// ワークフローがすでに実行していなければならないかを、その検査が決めるのに
/// 使う。値を上げると検査は新しい行を要求するので、ワークフローを更新するまで
/// 落ちる。
const current_stage = 4;

/// A module whose tests `zig build test` runs.
///
/// パスはモジュールから読み戻し、隣に書き並べない。そうすれば、あるファイルを
/// 指すリテラルがありながらモジュールは別のファイルから作られている、という
/// ことが起こらず、check-docs が受け取る `--root` 引数は、テストが走る
/// ファイルを指す。次の3つの編集は、いずれも検査が緑のまま、ソースファイルの
/// テストを黙って走らなくした: テストのループからモジュールを外す、1つの
/// モジュールを重複させてもう1つを失う、あるファイルのパスを別のファイルの
/// モジュールと組にする。
const TestTarget = struct {
    mod: *std.Build.Module,
    /// Read out of `mod` when the target was recorded.
    path: []const u8,
    /// The test binary built from `mod`, filled in when the test is added.
    /// 最後の検査が、どう設定されたかを見られるように残す。
    unit: ?*std.Build.Step.Compile = null,

    fn of(b: *std.Build, mod: *std.Build.Module) TestTarget {
        return .{ .mod = mod, .path = sourcePath(b, mod) };
    }

    /// Fails the configure step when this target's tests would not all run.
    ///
    /// run step を数えるだけでは足りない。`b.addTest(.{ ..., .filters = &.{"x"}
    /// })` は1フィールドの編集で、run step を残したまま、どのテストも選ばなくする。
    /// すると `zig build test` は、src/sucheme.zig にわざと落ちるテストがあっても
    /// exit 0 になり、検証コマンドはすべて緑のままで、`--summary all` もテスト件数を
    /// 出さなくなるので、ログにも痕跡が残らない。独自の `test_runner` も同じことを
    /// 決められる。ここではどちらも要らないので、調べずに両方を拒む。
    fn checkRunsEveryTest(self: TestTarget) void {
        const unit = self.unit orelse {
            std.debug.print("[sucheme] test target {s} has no test binary\n", .{self.path});
            std.process.exit(1);
        };
        if (unit.filters.len != 0) {
            std.debug.print(
                "[sucheme] test target {s} has {d} test filter(s); a filter can select no test at all\n",
                .{ self.path, unit.filters.len },
            );
            std.process.exit(1);
        }
        if (unit.test_runner != null) {
            std.debug.print(
                "[sucheme] test target {s} has a custom test runner; it decides what runs\n",
                .{self.path},
            );
            std.process.exit(1);
        }
    }

    /// Fails the configure step when the module no longer reports the path its
    /// test and its `--root` argument were made from.
    ///
    /// `addTest` はコンパイルするときにモジュールの `root_source_file` を解決する。
    /// そのため、テストを足したあとの編集は、check-docs に伝えたのとは別のファイルを
    /// コンパイルし、そのファイルのテストは走らないまま、コマンドはすべて緑になる。
    /// `build` の中の他のすべての編集のあとにこれを呼べば、その隙は閉じる。あとに
    /// configure 時のコードは続かず、グラフを作る間にモジュールを書き換える step も
    /// ないからである。
    fn recheck(self: TestTarget, b: *std.Build) void {
        // テストがコンパイルするモジュールを見る。記録したモジュールではない。
        // `addTest` は自分のモジュールを Compile step の公開された可変フィールドに
        // 持つので、`unit.root_module = other` は `self.mod` に触れないまま別の
        // ファイルをコンパイルさせる。unit 越しに読めば、それと、モジュール自身の
        // `root_source_file` への代入の両方に対応できる。
        const unit = self.unit orelse return; // checkRunsEveryTest が報告する
        const now = sourcePath(b, unit.root_module);
        if (std.mem.eql(u8, now, self.path)) return;
        std.debug.print(
            "[sucheme] test target {s} was rebound to {s} after its test was added\n",
            .{ self.path, now },
        );
        std.process.exit(1);
    }
};

/// The repository-relative path a module was built from, spelled the way this
/// repository spells paths: with `/`.
///
/// `b.path` はホストの区切りをそのまま保つので、Windows ではモジュールが
/// `src\main.zig` を返す。このスクリプトにパスが入るここで正規化するから、
/// 以降は1つの綴りで比較し、表示できる。`test_excluded`、`--root` 引数、文書は
/// すべて `/` を使い、check-docs はバックスラッシュで名付けた root を開けなかった。
fn sourcePath(b: *std.Build, mod: *std.Build.Module) []const u8 {
    const lazy = mod.root_source_file orelse {
        std.debug.print("[sucheme] a test target module has no root source file\n", .{});
        std.process.exit(1);
    };
    switch (lazy) {
        .src_path => |sp| {
            const out = b.allocator.dupe(u8, sp.sub_path) catch @panic("OOM");
            // ホストの区切りがすでに `/` なら、何もしない。
            std.mem.replaceScalar(u8, out, std.fs.path.sep, '/');
            return out;
        },
        else => {
            std.debug.print("[sucheme] a test target module is not built from a repository path\n", .{});
            std.process.exit(1);
        },
    }
}

/// The most bytes of a file under `lib/`.
/// `src/syntax/source.zig` の `max_file_bytes` と同じ値で、実行時にも同じ上限を検査する。
const embedded_max_bytes = 1024 * 1024;

/// The module that carries the files under `lib/` (docs/design/frontend.md, 埋め込み).
///
/// `lib/` を走査してパス名順に並べ、`@embedFile` で取り込んだファイルの一覧を持つ Zig の
/// ソースを作る。ネイティブも WASM も同じ一覧を使う。内容はビルド時に検証し、不正なものが
/// あればビルドを失敗させる(docs/design/platform-and-web.md の入力の検証の表)。
/// 一覧は `lib/` の実態から作るので、手で保守する記録ではない。ファイルを足すと、
/// 次の `zig build` が走査し直す。
///
/// 一覧が持つのはパスの索引だけである。`define-library` の名前の索引は、パスに対応付け
/// られない名前のライブラリが `lib/` に現れたときに足す(docs/plans/0016-phase3-scheme-stdlib.md)。
fn embeddedLib(b: *std.Build) *std.Build.Module {
    const io = b.graph.io;
    const a = b.allocator;
    var paths: std.ArrayList([]const u8) = .empty;
    // Why: Zig 0.17 は、build.zig が読んだものを宣言しないと、構成の結果を使い回す。
    // 走査したディレクトリとファイルを宣言して、`lib/` の変更(足す、消す、書き換える)で
    // 構成をやり直させる。宣言しないと、ファイルを足しても次の `zig build` が気づかない。
    b.dependOnDirectoryContents(b.path("lib"));
    if (b.root.openDir(io, "lib", .{ .iterate = true })) |opened| {
        var dir = opened;
        defer dir.close(io);
        var walker = dir.walk(a) catch @panic("OOM");
        defer walker.deinit();
        while (walker.next(io) catch |e| embeddedFail("cannot walk lib/: {s}", .{@errorName(e)})) |entry| {
            switch (entry.kind) {
                .directory => {
                    const path = a.dupe(u8, entry.path) catch @panic("OOM");
                    std.mem.replaceScalar(u8, path, std.fs.path.sep, '/');
                    b.dependOnDirectoryContents(b.path(b.fmt("lib/{s}", .{path})));
                },
                .file => {
                    const path = a.dupe(u8, entry.path) catch @panic("OOM");
                    std.mem.replaceScalar(u8, path, std.fs.path.sep, '/');
                    checkEmbeddedPath(path);
                    b.dependOnFileContents(b.path(b.fmt("lib/{s}", .{path})));
                    const data = dir.readFileAlloc(io, entry.path, a, .limited(embedded_max_bytes)) catch |e|
                        embeddedFail("cannot read lib/{s}: {s}", .{ path, @errorName(e) });
                    if (!std.unicode.utf8ValidateSlice(data)) embeddedFail("lib/{s} is not valid UTF-8", .{path});
                    paths.append(a, path) catch @panic("OOM");
                },
                // リンクなどは、埋め込みの対象にしない。
                else => embeddedFail("lib/{s} is neither a file nor a directory", .{entry.path}),
            }
        }
    } else |e| switch (e) {
        error.FileNotFound => {},
        else => embeddedFail("cannot open lib/: {s}", .{@errorName(e)}),
    }
    std.mem.sort([]const u8, paths.items, {}, struct {
        fn lessThan(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.lessThan);

    var text: std.ArrayList(u8) = .empty;
    text.appendSlice(a, "pub const File = struct { path: []const u8, data: []const u8 };\n\npub const files = [_]File{\n") catch @panic("OOM");
    for (paths.items) |p| {
        text.appendSlice(a, b.fmt("    .{{ .path = \"{s}\", .data = @embedFile(\"lib/{s}\") }},\n", .{ p, p })) catch @panic("OOM");
    }
    text.appendSlice(a, "};\n") catch @panic("OOM");

    const write = b.addWriteFiles();
    const mod = b.createModule(.{ .root_source_file = write.add("embedded_lib.zig", text.items) });
    // 各ファイルは、`lib/` のパスを名前にした import として足す。`@embedFile` は
    // import の名前でファイルを指せる。
    for (paths.items) |p| {
        const name = b.fmt("lib/{s}", .{p});
        mod.addAnonymousImport(name, .{ .root_source_file = b.path(name) });
    }
    return mod;
}

/// Fails the configure step for a file under `lib/` that must not be embedded.
///
/// 名前の成分は、ライブラリ名からファイル名への対応(src/resolve.zig の `checkComponent`)
/// が通す文字だけにする。拡張子は、ライブラリの定義(`.sld`)と、`include` が読む
/// ソース(`.scm`)だけである。
fn checkEmbeddedPath(path: []const u8) void {
    const extension = std.fs.path.extension(path);
    if (!std.mem.eql(u8, extension, ".sld") and !std.mem.eql(u8, extension, ".scm"))
        embeddedFail("lib/{s} is neither a .sld nor a .scm file", .{path});
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |component| {
        if (component.len == 0 or component[0] == '.' or component[component.len - 1] == '.')
            embeddedFail("lib/{s} has a component that is empty or starts or ends with a dot", .{path});
        for (component) |c| {
            const ok = std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.';
            if (!ok) embeddedFail("lib/{s} has a character other than A-Z a-z 0-9 - _ .", .{path});
        }
    }
}

fn embeddedFail(comptime format: []const u8, args: anytype) noreturn {
    std.debug.print("[sucheme] " ++ format ++ "\n", args);
    std.process.exit(1);
}

pub fn build(b: *std.Build) void {
    enforcePinnedZigVersion();

    // マニフェストは文字列検索ではなくパースする。生の検索では、コメントアウトした
    // `.version` が本物を覆い隠してしまう。
    const manifest = parseManifest(b);

    const target = b.standardTargetOptions(.{});

    // Why: 規模を確かめるテスト(10万段の再帰、100万ステップ)は、実行時間の大半を
    // 占め、入力の大きさとともに増える誤りを見つける。これらは `-Dslow=true` で
    // 走らせる。全コミットの実行はこれらを外し、それぞれの縮小版を残す
    // (docs/plans/0007-test-tiers.md)。飛ばしたテストの数は、
    // `zig build test --summary all` の概要に出る。
    const slow = b.option(bool, "slow", "also run the tests that check a scale (slow)") orelse false;
    // Why: `-Dslow=true` で `-Doptimize` を付けないときは、ReleaseSafe を既定にする
    // (ADR-0047)。規模を試す単体テストは Debug では数倍遅く、ReleaseSafe は安全検査を残す。
    // Debug の未初期化メモリの埋め込みは、Debug のまま走る全コミットの縮小版が受け持つ。
    // `-Doptimize` を付けたときは、その値が優先する。`--release` は、slow のときは読まない。
    const optimize: std.builtin.OptimizeMode = if (slow)
        b.option(std.builtin.OptimizeMode, "optimize", "Prioritize performance, safety, or binary size") orelse .ReleaseSafe
    else
        b.standardOptimizeOption(.{});

    const options = b.addOptions();
    options.addOption(bool, "slow", slow);
    options.addOption([]const u8, "name", @tagName(manifest.name));
    options.addOption([]const u8, "version", manifest.version);

    const sucheme = b.addModule("sucheme", .{
        .root_source_file = b.path("src/sucheme.zig"),
        .target = target,
        .optimize = optimize,
    });
    sucheme.addOptions("build_options", options);
    // `lib/` の埋め込み。`sucheme` のモジュールを作るたびに足す(下の host、wasm、dist)。
    const embedded = embeddedLib(b);
    sucheme.addImport("embedded_lib", embedded);

    const exe = b.addExecutable(.{
        .name = @tagName(manifest.name),
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "sucheme", .module = sucheme }},
        }),
    });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    run.addPassthruArgs();
    b.step("run", "run the sucheme executable").dependOn(&run.step);

    // ツールごとに Compile を1つ作り、すべての run step とテストの対象で使い回す。
    // 使う箇所ごとに tool() を呼ぶと、同じファイルから Compile step が2つできた。
    const check_docs = tool(b, "check-docs", .Debug);
    const extractor = tool(b, "extract-r7rs-required", .Debug);
    const coverage = tool(b, "coverage-report", .Debug);
    // Unicode の表の生成器(スライス 4u1)。全符号位置の配列を作るので、ReleaseSafe にする。
    const unicode_gen = tool(b, "unicode-gen", .ReleaseSafe);
    // 生成器のテストは、引く関数(src/unicode/props.zig)が全符号位置で生成器の入力と
    // 一致するかを見る(スライス 4u2)。props.zig は sucheme モジュールからも相対パスで
    // 読まれるが、2つは別のコンパイルなので、同じファイルが2つのモジュールに属する誤りにならない。
    unicode_gen.root_module.addImport("unicode_props", b.createModule(.{
        .root_source_file = b.path("src/unicode/props.zig"),
        .target = b.graph.host,
        .optimize = .ReleaseSafe,
    }));
    // Why: ランナーは100万ステップのプログラムを評価するので、Debug ビルドでは
    // 数分かかる。ReleaseSafe は検査(境界・オーバーフロー・アサーション)を残したまま、
    // インタプリタを数倍速く動かす。下のモジュールは、それを import する
    // 実行ファイルの最適化モードを取る。
    const test_scheme = tool(b, "test-scheme", .ReleaseSafe);
    // ランナーは各ケースをプロセス内で評価するので、実行ファイルと同じソースに対して
    // ビルドする。向ける先は `target` ではなくホストである。ランナーはここで走り、
    // `-Dtarget` は実行ファイルが走る場所を指すからである。
    const sucheme_host = b.createModule(.{
        .root_source_file = b.path("src/sucheme.zig"),
        .target = b.graph.host,
        .optimize = .ReleaseSafe,
    });
    sucheme_host.addOptions("build_options", options);
    sucheme_host.addImport("embedded_lib", embedded);
    test_scheme.root_module.addImport("sucheme", sucheme_host);
    // ランナーは、規模を試す層が求められたときは tests/scheme-slow/ も読む。
    const tier_options = b.addOptions();
    tier_options.addOption(bool, "slow", slow);
    test_scheme.root_module.addOptions("tier", tier_options);
    // 準拠マトリクスの生成器は、必須の識別子が束縛済みかをインタプリタに尋ねる。
    // そのため、実行ファイルと同じソースに対して、ホスト向けに作る。
    coverage.root_module.addImport("sucheme", sucheme_host);
    // 準拠スイートの実行器(スライス 6e)。スイートの全節を評価するので、test-scheme と同じ理由で
    // ReleaseSafe にし、実行ファイルと同じソースに対してホスト向けに作る。
    const conformance = tool(b, "conformance-run", .ReleaseSafe);
    conformance.root_module.addImport("sucheme", sucheme_host);
    // 準拠マトリクスの生成器は、実行器と同じ runSuite で節ごとの数を出す(スライス 6f)。
    // run.zig のテストは、実行器の main.zig から届くので、このモジュールはテストの対象にしない。
    const conformance_run = b.createModule(.{
        .root_source_file = b.path("tools/conformance-run/run.zig"),
        .target = b.graph.host,
        .optimize = .ReleaseSafe,
    });
    conformance_run.addImport("sucheme", sucheme_host);
    coverage.root_module.addImport("conformance", conformance_run);
    const tools = [_]*std.Build.Step.Compile{ check_docs, extractor, test_scheme, coverage, conformance, unicode_gen };

    const run_check_docs = b.addRunArtifact(check_docs);
    // run step が引き継ぐのは build root ではなく `zig build` を起動したディレクトリ
    // なので、--build-file を使うと相対パスの読み取りは失敗する。
    run_check_docs.setCwd(b.path("."));

    // 生成された一覧を、コミット済みの入力から抽出プログラムが作るものと比べる。
    // SOURCE.md に貼った SHA-256 とだけ比べると、対が固定されなかった。一覧を編集して
    // 新しいハッシュを貼っても検証コマンドはすべて緑のままで、準拠の分母から
    // 識別子が1つ消えた。
    const run_check_extract = b.addRunArtifact(extractor);
    run_check_extract.setCwd(b.path("."));
    const check_extract_step = b.step("check-extract", "check the generated lists against the input");
    check_extract_step.dependOn(&run_check_extract.step);

    // Unicode の表(src/unicode/tables.zig)。`check-unicode` は、コミット済みの UCD の
    // ファイルから生成器が作るものと比べる。書き込むのは `generate-unicode` だけで、
    // `--write` を渡す。比較が既定なので、引数を落としても検査が書き換えに変わらない
    // (check-extract と同じ形)。
    const run_check_unicode = b.addRunArtifact(unicode_gen);
    run_check_unicode.setCwd(b.path("."));
    const check_unicode_step = b.step("check-unicode", "check src/unicode/tables.zig against the vendored UCD files");
    check_unicode_step.dependOn(&run_check_unicode.step);

    const run_generate_unicode = b.addRunArtifact(unicode_gen);
    run_generate_unicode.setCwd(b.path("."));
    run_generate_unicode.addArg("--write");
    const generate_unicode_step = b.step("generate-unicode", "write src/unicode/tables.zig from the vendored UCD files");
    generate_unicode_step.dependOn(&run_generate_unicode.step);

    // 準拠マトリクス(docs/status/conformance.md)。`check-report` はツールの既定の
    // 動作である比較を走らせ、コミット済みのファイルがツールの生成結果と違えば
    // 非ゼロで終わる。書き込むのは `report` だけで、`--write` を渡す。上の抽出
    // プログラムと同じ形で、理由も同じである。比較が既定なので、引数を1つ落とした
    // だけでは検査が書き換えに変わらない。
    const run_check_report = b.addRunArtifact(coverage);
    run_check_report.setCwd(b.path("."));
    const check_report_step = b.step("check-report", "check docs/status/conformance.md against the interpreter");
    check_report_step.dependOn(&run_check_report.step);

    // 準拠スイート(tests/vendor/r7rs-tests.scm)の実行。ランナーは引数を取らず、スイートを
    // 自分で読む。段階6までは CI で走らせない(AGENTS.md の検証コマンド表の「使えるようになる
    // 段階」)。末尾の checkStepRuns の呼び出しを参照。
    const run_conformance = b.addRunArtifact(conformance);
    run_conformance.setCwd(b.path("."));
    const test_conformance_step = b.step("test-conformance", "run the vendored R7RS conformance suite");
    test_conformance_step.dependOn(&run_conformance.step);

    const run_report = b.addRunArtifact(coverage);
    run_report.setCwd(b.path("."));
    run_report.addArg("--write");
    const report_step = b.step("report", "write docs/status/conformance.md");
    report_step.dependOn(&run_report.step);

    // ランナーは引数を取らず、tests/scheme/ を自分で読む。だからここに引数を足すのは、
    // 走らせる範囲を狭める唯一の手段になる。末尾の checkStepRuns の呼び出しを参照。
    const run_test_scheme = b.addRunArtifact(test_scheme);
    run_test_scheme.setCwd(b.path("."));
    const test_scheme_step = b.step("test-scheme", "run the Scheme behaviour tests");
    test_scheme_step.dependOn(&run_test_scheme.step);

    // WebAssembly ビルド(docs/plans/0008-slice-1i-wasm-web-ui.md)。モジュールの
    // ターゲットは1つなので、wasm 用のインタプリタは専用のモジュールにする。
    // ReleaseSafe にしている。Debug はホストが読めないスタックトレースを持つ大きな
    // モジュールになり、ReleaseSmall は検査を落とす。
    const wasm_target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding });
    const sucheme_wasm = b.createModule(.{
        .root_source_file = b.path("src/sucheme.zig"),
        .target = wasm_target,
        .optimize = .ReleaseSafe,
    });
    sucheme_wasm.addOptions("build_options", options);
    sucheme_wasm.addImport("embedded_lib", embedded);
    const wasm_exe = b.addExecutable(.{
        .name = "sucheme",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/wasm.zig"),
            .target = wasm_target,
            .optimize = .ReleaseSafe,
            .imports = &.{.{ .name = "sucheme", .module = sucheme_wasm }},
        }),
    });
    // エクスポートした関数のライブラリ。`main` はなく、エクスポートは残す。
    wasm_exe.entry = .disabled;
    wasm_exe.rdynamic = true;
    const install_wasm = b.addInstallArtifact(wasm_exe, .{ .dest_dir = .{ .override = .{ .custom = "web" } } });
    const wasm_step = b.step("wasm", "build web/sucheme.wasm under zig-out");
    wasm_step.dependOn(&install_wasm.step);

    // リリースの成果物(docs/adr/0034-release-shape.md)。`-Dtarget` と `-Doptimize`
    // は見ない。ターゲットの一覧はここだけが持ち、tools/release/package.py は
    // `zig-out/dist/` の下のディレクトリ名からそれを導く。wasm は上の `wasm` と同じ
    // インストールに依存する(Web UI の zip の材料になる)。
    const dist_step = b.step("dist", "build the release executables for every target under zig-out/dist");
    for (dist_targets) |dist_name| {
        const dist_query = std.Target.Query.parse(.{ .arch_os_abi = dist_name }) catch
            std.debug.panic("dist target {s} is not a target", .{dist_name});
        const dist_target = b.resolveTargetQuery(dist_query);
        const sucheme_dist = b.createModule(.{
            .root_source_file = b.path("src/sucheme.zig"),
            .target = dist_target,
            .optimize = dist_optimize,
        });
        sucheme_dist.addOptions("build_options", options);
        sucheme_dist.addImport("embedded_lib", embedded);
        const dist_exe = b.addExecutable(.{
            .name = @tagName(manifest.name),
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/main.zig"),
                .target = dist_target,
                .optimize = dist_optimize,
                .imports = &.{.{ .name = "sucheme", .module = sucheme_dist }},
            }),
        });
        // Why: Windows のビルドは実行ファイルの隣に .pdb を作る。アーカイブには
        // 入れない(docs/adr/0034-release-shape.md)ので、インストールしない。
        const install_dist = b.addInstallArtifact(dist_exe, .{
            .dest_dir = .{ .override = .{ .custom = b.fmt("dist/{s}", .{dist_name}) } },
            .pdb_dir = .disabled,
        });
        dist_step.dependOn(&install_dist.step);
    }
    dist_step.dependOn(&install_wasm.step);

    // エクスポートの往復テスト。Node.js で走らせる(tools/test-wasm/)。
    // インストールしたファイルを読むので、インストールの step が先に来る。
    // 実行はキャッシュしない。出力の引数を持たないシステムコマンドは、ビルドグラフから
    // 見れば副作用を持つからである。checkSystemStepRuns が、`build` の末尾で
    // step をその形に保つ。
    const run_test_wasm = b.addSystemCommand(&.{ "node", test_wasm_script });
    run_test_wasm.setCwd(b.path("."));
    run_test_wasm.addFileArg(.{ .relative = .{ .base = .install_prefix, .sub_path = "web/sucheme.wasm" } });
    run_test_wasm.step.dependOn(&install_wasm.step);
    // Why: ヒープを上限まで使い切るテストは時間がかかるので、規模を試す他のテストと
    // 同じオプションに従わせる。引数でなく環境変数にするのは、checkSystemStepRuns が
    // 引数列を1つの形に固定しているからである。
    if (slow) run_test_wasm.setEnvironmentVariable("SUCHEME_SLOW", "1");
    const test_wasm_step = b.step("test-wasm", "call the wasm exports from Node.js");
    test_wasm_step.dependOn(&run_test_wasm.step);

    const test_step = b.step("test", "run the unit tests");

    var targets: std.ArrayList(TestTarget) = .empty;
    targets.append(b.allocator, .of(b, sucheme)) catch @panic("OOM");
    targets.append(b.allocator, .of(b, exe.root_module)) catch @panic("OOM");
    // ツールは検証のコードである。test step に自分のテストがなければ、ツールの中の
    // 失敗するアサーションは走らない。段階0では、新しいロジックの大半がここにある。
    for (tools) |t| {
        targets.append(b.allocator, .of(b, t.root_module)) catch @panic("OOM");
    }
    // 評価器のファジング(計画書 0025)。テストだけのモジュールで、実行ファイルは作らない。
    // リーダのファジングと別のバイナリにするのは、1つのバイナリに `std.testing.fuzz` を呼ぶ
    // テストを2つ置くと、探索の実行でファザーが進まなくなるからである。`-Doptimize` に従うので、
    // fuzz.yml の `-Doptimize=ReleaseSafe` がこのバイナリにも効く。
    const fuzz_eval = b.createModule(.{
        .root_source_file = b.path("tools/fuzz-eval/fuzz.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "sucheme", .module = sucheme }},
    });
    targets.append(b.allocator, .of(b, fuzz_eval)) catch @panic("OOM");

    // ループも一覧も1つ。テストと check-docs に伝えるパスは同じモジュールから来るので、
    // どちらか一方だけを落としたり重複させたりできない。
    for (targets.items) |*t| {
        const unit = b.addTest(.{ .root_module = t.mod });
        t.unit = unit;
        test_step.dependOn(&b.addRunArtifact(unit).step);
        run_check_docs.addArg("--root");
        run_check_docs.addArg(t.path);
    }
    // 生成器の `main` が `run` の戻り値を終了コードにしていることの検査。単体テストは `run` を
    // 呼ぶので、`main` が戻り値を捨てて 0 を返しても落ちず、表が違う状態の `check-unicode` が
    // 緑になる。未知の引数は、入力にも表にも触れずに 2 で終わるので、この run だけで確かめられる。
    const run_unicode_exit = b.addRunArtifact(unicode_gen);
    run_unicode_exit.addArg("--bogus");
    run_unicode_exit.expectExitCode(2);
    test_step.dependOn(&run_unicode_exit.step);
    // 実行ファイルそのものに大きなリストを通す。単体テストと Scheme のテストは、実行ファイルの
    // `main` が選ぶアロケータを通らないので、そこに起因する誤りを見つけられない(大きなリストを
    // 複数リストの `map` に渡すと、`SafeAllocator` の `munmap` が失敗して落ちた)。
    // 規模を試す層でだけ走らせる。判定は終了コードだけである(標準出力を検査する run は、
    // 終了コードを読まなくなるので、checkRunIsHeard が拒む)。異常終了は失敗になる。
    if (slow) {
        const run_cli_scale = b.addRunArtifact(exe);
        run_cli_scale.setStdIn(.{ .lazy_path = b.path("tests/cli-slow/multi-list-map.scm") });
        test_step.dependOn(&run_cli_scale.step);
    }
    for (test_excluded) |path| {
        run_check_docs.addArg("--exclude");
        run_check_docs.addArg(path);
    }
    run_check_docs.addArg("--stage");
    run_check_docs.addArg(b.fmt("{d}", .{current_stage}));

    // AGENTS.md の表と全コミットのワークフローの両方に現れなければならないコマンド。
    // それを提供する step の名前で挙げる。
    //
    // 表とワークフローは互いとだけ比べられていて、ほかとは比べられていなかった。
    // そのため両方を同時に弱めても緑だった。行とその step をいっしょに削れば要件が
    // 消え、4つのコマンドのうち3つがその形で消せた。この一覧が3つめの点である。
    // 手で揃えるべき別の記録ではない。各項目はそれを実行する step そのものなので、
    // 要件を落とすことは step を落とすことであり、そうすればコマンド自体が動かなく
    // なる。`zig fmt --check .` は build の step ではないので、表とワークフローだけが
    // 守っている。
    const required_steps = [_]*std.Build.Step{
        b.getInstallStep(),
        test_step,
        test_scheme_step,
        wasm_step,
        test_wasm_step,
        check_extract_step,
        check_report_step,
        check_unicode_step,
    };
    for (required_steps) |s| {
        run_check_docs.addArg("--requires");
        // install step は素の `zig build` が走らせるもので、表はそう名付けている。
        run_check_docs.addArg(if (s == b.getInstallStep())
            "zig build"
        else
            b.fmt("zig build {s}", .{s.name}));
    }
    const check_docs_step = b.step("check-docs", "check the docs and build settings");
    check_docs_step.dependOn(&run_check_docs.step);
    // 自分の step ができてから足す。このプログラムが走る step が、ほかと同じ要件を
    // 課されるようにするためである。
    run_check_docs.addArg("--requires");
    run_check_docs.addArg(b.fmt("zig build {s}", .{check_docs_step.name}));

    // `build` の最後に置く。これより後で、モジュールを付け替えたり、足したあとの
    // テストを設定し直したりできないようにするためである。TestTarget.recheck と
    // checkRunsEveryTest を参照。
    for (targets.items) |t| {
        t.recheck(b);
        t.checkRunsEveryTest();
    }
    checkTestsAreRun(test_step, targets.items);
    checkStepRuns(check_docs_step, check_docs, null);
    // ちょうどその artifact だけ。ここに引数を足すと、比較を書き換えに変える唯一の
    // 手段になる理由は、checkStepRuns を参照。
    checkStepRuns(check_extract_step, extractor, 1);
    // Unicode の表の比較も、ちょうどその artifact だけ。書き込みの `--write` は別の step が持つ。
    checkStepRuns(check_unicode_step, unicode_gen, 1);
    // 引数なしで、成果物だけを走らせる。理由は同じで、比較が生成器の既定であり、
    // 書き込みには `--write` が要る。
    checkStepRuns(check_report_step, coverage, 1);
    // これもちょうどその artifact だけ。フィルタや狭いディレクトリは、引数から
    // 入り込む。
    checkStepRuns(test_scheme_step, test_scheme, 1);
    // 準拠スイートの実行も、ちょうどその artifact だけ。理由は test-scheme と同じである。
    checkStepRuns(test_conformance_step, conformance, 1);
    // wasm のファイルは引数で、スクリプトは固定である。3つめの引数は、より狭い
    // テストの選択を入り込ませる手段になる。
    checkSystemStepRuns(test_wasm_step, test_wasm_script, &install_wasm.step, 3);
    // 実行ファイルに大きな入力を通す step。`dependOn` の1行を消すと、`zig build test
    // -Dslow=true` は何も走らせないまま緑になる。引数は artifact だけである。入力は標準入力で
    // 渡すので、ここに足した引数は、検査を弱める書き換えになる。
    if (slow) checkStepRuns(test_step, exe, 1);
}

/// The targets `zig build dist` builds, spelled as `-Dtarget` spells them.
///
/// docs/adr/0010-ci-cd-and-release-strategy.md の一覧が正である。綴りはそのまま
/// `zig-out/dist/` の下のディレクトリ名とアーカイブ名になる。
const dist_targets = [_][]const u8{
    "x86_64-linux-musl",
    "aarch64-linux-musl",
    "x86_64-macos",
    "aarch64-macos",
    "x86_64-windows",
    "aarch64-windows",
};

/// The optimize mode of `zig build dist`, which `-Doptimize` does not change.
///
/// `test-scheme` と wasm が使う設定と同じなので、動かして確かめた設定を配る
/// (docs/adr/0034-release-shape.md)。
const dist_optimize: std.builtin.OptimizeMode = .ReleaseSafe;

/// The script `zig build test-wasm` hands to Node.js.
const test_wasm_script = "tools/test-wasm/main.mjs";

/// Fails the configure step unless `step` runs `node <script>` after
/// `installed` and lets the result of that run decide whether the step succeeds.
///
/// `checkStepRuns` は run を、それを作った artifact で見つけるが、システムコマンドには
/// それがない。それでも、同じ編集で step を空にすることはできる。
/// `test_wasm_step.dependOn(&run_test_wasm.step)` を消すと、`zig build test-wasm` は
/// 何も走らせないまま exit 0 になる。`stdio = .{ .check = .empty }` は、run を残した
/// まま、終了コードを読まなくする。run は install の step のあとに来なければならない。
/// そうでないと、古いファイルをテストするか、テストするファイルがないことになる。
///
/// `want_argv` は引数をすべて数える。`node` とスクリプトも含む。
fn checkSystemStepRuns(
    step: *std.Build.Step,
    script: []const u8,
    installed: *std.Build.Step,
    want_argv: usize,
) void {
    var found = false;
    for (step.dependencies.items) |dep| {
        const run = dep.cast(std.Build.Step.Run) orelse continue;
        if (run.producer != null) continue;
        if (run.argv.items.len < 2) continue;
        const arg = run.argv.items[1];
        if (arg != .bytes or !std.mem.eql(u8, arg.bytes, script)) continue;
        found = true;
        // プログラムは Node.js でなければならない。`true` に差し替えても、引数の数と
        // スクリプト名は変わらず、step は何も走らせないまま exit 0 になった。
        const program = run.argv.items[0];
        if (program != .bytes or !std.mem.eql(u8, program.bytes, "node")) {
            std.debug.print(
                "[sucheme] the {s} step runs {s} with a program other than node\n",
                .{ step.name, script },
            );
            std.process.exit(1);
        }
        checkRunIsHeard(step, run);
        if (run.argv.items.len != want_argv) {
            std.debug.print(
                "[sucheme] the {s} step runs {s} with {d} argument(s), not {d}\n",
                .{ step.name, script, run.argv.items.len, want_argv },
            );
            std.process.exit(1);
        }
        var after_install = false;
        for (run.step.dependencies.items) |d| {
            if (d == installed) after_install = true;
        }
        if (!after_install) {
            std.debug.print(
                "[sucheme] the run of {s} in the {s} step does not wait for the install of the wasm file\n",
                .{ script, step.name },
            );
            std.process.exit(1);
        }
    }
    if (found) return;
    std.debug.print("[sucheme] the {s} step does not run {s}\n", .{ step.name, script });
    std.process.exit(1);
}

/// Fails the configure step unless `step` runs the artifact built from `exe` and
/// lets the result of that run decide whether the step succeeds.
///
/// `check_docs_step.dependOn(&run_check_docs.step)` を消すと、何もつながっていない
/// step が残る。すると `zig build check-docs` は何も出力しないまま exit 0 になる。
/// `all checks passed` すら出ないので、ログには検証が止まった痕跡がない。
/// `zig build check-extract` も同じ形だった。
///
/// 走らせるだけでは足りない。`run.stdio = .{ .check = .empty }` は、依存と producer を
/// 残したまま、終了コードを読まなくする。check-docs は診断を出したのに、step は
/// 成功した。StdIo の形のうち終了コードを無視できるのは `.check` だけであり、
/// `skip_foreign_checks` は実行できない run を成功にしてしまうので、両方を拒む。
/// run があることだけを確かめて、その答えが聞かれていることを確かめないのは、
/// ビルドだけを確かめてワークフローを確かめないのと同じ、対の片側だけを見る
/// 誤りだった。
///
/// `want_argv` は run が持つべき引数の数で、artifact 自身も数える。null なら引数には
/// 触れない。`check-extract` はちょうど artifact だけを要求する。比較が抽出
/// プログラムの既定であり、書き込みは `--write` を取るので、ここに足した引数は、
/// 出力が同じになる書き換えに検査を変える唯一の手段になる。
///
/// artifact は依存の producer から探し、数えない。ほかの run step に依存するだけの
/// step は、自分では何も走らせないまま、数だけを合わせてしまう。
fn checkStepRuns(step: *std.Build.Step, exe: *std.Build.Step.Compile, want_argv: ?usize) void {
    var found = false;
    // 最初の1つではなく、一致するすべての run を調べる。最初で返すと、同じ artifact の
    // 2つめの run を調べないままにする。`checkTestsAreRun` はすでにすべてを調べて
    // いたので、この対の関数は強さが揃っていなかった。
    for (step.dependencies.items) |dep| {
        const run = dep.cast(std.Build.Step.Run) orelse continue;
        const producer = run.producer orelse continue;
        if (producer != exe) continue;
        found = true;
        checkRunIsHeard(step, run);
        if (want_argv) |n| {
            if (run.argv.items.len != n) {
                std.debug.print(
                    "[sucheme] the {s} step runs {s} with {d} argument(s), not {d}\n",
                    .{ step.name, exe.name, run.argv.items.len, n },
                );
                std.process.exit(1);
            }
        }
    }
    if (found) return;
    std.debug.print(
        "[sucheme] the {s} step does not run {s}\n",
        .{ step.name, exe.name },
    );
    std.process.exit(1);
}

/// Fails the configure step if `run`'s exit code would not decide its outcome.
fn checkRunIsHeard(step: *std.Build.Step, run: *std.Build.Step.Run) void {
    if (run.stdio == .check) {
        std.debug.print(
            "[sucheme] a run in the {s} step checks its own conditions, so a non-zero exit would not fail it\n",
            .{step.name},
        );
        std.process.exit(1);
    }
    if (run.skip_foreign_checks) {
        std.debug.print(
            "[sucheme] a run in the {s} step may be skipped as foreign, which would pass without running\n",
            .{step.name},
        );
        std.process.exit(1);
    }
    // どちらかのストリームを捕捉すると、run がキャッシュ可能になる。run に副作用が
    // あるかどうかは、グラフを作るときに `.infer_from_args` と捕捉の有無から計算される。
    // そのため捕捉があると、run は manifest に argv と artifact だけを持つものになり、
    // リポジトリを読む検証は、中身が何を変えようと2回目には飛ばされる。
    // `has_side_effects` 自体には触れない。false がその通常の状態であり、意味があるのは
    // 計算された値だけだからである。
    if (run.captured_stdout != null or run.captured_stderr != null) {
        std.debug.print(
            "[sucheme] a run in the {s} step captures its output, which makes it cacheable and so skippable\n",
            .{step.name},
        );
        std.process.exit(1);
    }
}

/// Fails the configure step unless the test step runs each target's test
/// binary.
///
/// `TestTarget` は各テストがどのファイルから作られるかを守るが、テストが実行される
/// ことについては何も言わない。`test_step.dependOn(&b.addRunArtifact(unit).step)` の
/// 代わりに `test_step.dependOn(&unit.step)` と書くのは1トークンの編集で、すべての
/// テストをビルドして1つも走らせない。`zig build test` は、src/sucheme.zig にわざと
/// 落ちるテストがあっても exit 0 になり、`zig build`、`zig build check-docs`、
/// `zig fmt --check .` も緑のままである。check-docs はこれを見られない。渡されるのは
/// パスであり、何かが実行されたかどうかではないからである。
///
/// 各 target は、run step を数える代わりに、run step の producer から名前で探す。
/// 数は対応ではない。ある target の run step を別の artifact に向けても数は同じ
/// ままで、その target のテストは、検証コマンドがすべて緑のまま、一度もコンパイル
/// されなかった。数は、この step にテスト以外のものがつながった時点で、まっとうな
/// 理由でも壊れる。
///
/// run step が何を選ぶかは `TestTarget.checkRunsEveryTest` の領分であり、すべての
/// root に選ぶべきテストがあることは check-docs の領分である。
fn checkTestsAreRun(test_step: *std.Build.Step, targets: []const TestTarget) void {
    for (targets) |t| {
        const unit = t.unit orelse continue; // checkRunsEveryTest が報告する
        var ran = false;
        for (test_step.dependencies.items) |dep| {
            const run = dep.cast(std.Build.Step.Run) orelse continue;
            const producer = run.producer orelse continue;
            if (producer != unit) continue;
            // run があることは、その答えが聞かれていることと同じではない。
            // `stdio = .{ .check = .empty }` では、わざと落ちるテストが `1 failed` を出したのに
            // `zig build test` は exit 0 になった。これは、この関数自身のコメントが閉じたと
            // 主張している状態である。
            checkRunIsHeard(test_step, run);
            ran = true;
        }
        if (ran) continue;
        std.debug.print(
            "[sucheme] the test step does not run the test built from {s}\n",
            .{t.path},
        );
        std.process.exit(1);
    }
}

/// Builds one of the helper programs under tools/.
fn tool(b: *std.Build, name: []const u8, optimize: std.builtin.OptimizeMode) *std.Build.Step.Compile {
    return b.addExecutable(.{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = b.path(b.fmt("tools/{s}/main.zig", .{name})),
            .target = b.graph.host,
            .optimize = optimize,
        }),
    });
}

fn enforcePinnedZigVersion() void {
    const text = std.mem.trim(u8, pinned_zig_version, &std.ascii.whitespace);
    const want = std.SemanticVersion.parse(text) catch
        @panic(".zigversion is not a semantic version");
    const have = builtin.zig_version;
    // 完全な一致で、プレリリースとビルドメタデータも含める。0.17.0-dev の master ビルドは
    // 0.17.0 のリリースではなく、ADR-0001 が固定するのはリリースである。
    //
    // これが走るのは、build.zig 自体がコンパイルできたあとだけである。std の違いが
    // 大きすぎる Zig では、それより前の configure のコンパイルで、この診断ではなく
    // std のエラーで失敗する。docs/design/zig-api-notes.md がこの限界を記録している。
    if (want.order(have) == .eq and
        optionalStringsEqual(want.pre, have.pre) and
        optionalStringsEqual(want.build, have.build)) return;
    std.debug.print("\n[sucheme] .zigversion pins Zig {f} but {f} is in use.\n", .{ want, have });
    std.debug.print("          Install the pinned version; see docs/adr/0001-zig-version-pinning.md\n\n", .{});
    std.process.exit(1);
}

fn optionalStringsEqual(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return std.mem.eql(u8, a.?, b.?);
}

/// The fields of build.zig.zon this build script reads.
const Manifest = struct {
    name: enum { sucheme },
    version: []const u8,
};

fn parseManifest(b: *std.Build) Manifest {
    var diagnostics: std.zon.parse.Diagnostics = undefined;
    return std.zon.parse.fromSlice(Manifest, .{
        .gpa = b.allocator,
        .arena = b.allocator,
        .source = @embedFile("build.zig.zon"),
        .diagnostics = &diagnostics,
        .ignore_unknown_fields = true,
    }) catch {
        diagnostics.log("build.zig.zon");
        std.process.exit(1);
    };
}
