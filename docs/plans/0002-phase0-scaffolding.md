# 段階0の実装計画: 足場

手順2(具体的実装計画)の成果物。対象は [../roadmap.md](../roadmap.md) の段階0である。

この段階ではインタプリタの機能を作らない。ビルドと検証の足場を作り、段階1以降の作業が「`zig build test` を通す」という形で進められる状態にする。

本計画は敵対的レビューを1巡受けて改訂した。レビューで偽と判明した前提は、実機で確認した事実に置き換えてある。実機確認の結果は各節に書く。

## 完了条件

[../roadmap.md](../roadmap.md) の段階0の完了条件が正である。ここに再掲しない。チェックボックスの全項目と完了条件の全節を満たした時点で完了とする。

## この段階で決めること

[../design/open-questions.md](../design/open-questions.md) の段階0の3行を、この計画で決める。決めたら同ファイルから消す(段階0の完了時に実施済み)。決めた内容は本計画書の該当する節に書き、段階0の完了時に open-questions.md から該当行を消す。

| 事項 | 決める節 |
| --- | --- |
| `build.zig` の step の名前と依存関係 | ビルドスクリプト |
| CI のジョブ構成と、段階ごとに増える検証の扱い | CI ワークフロー |
| R7RS 付録Aの識別子一覧の抽出方法 | 必須識別子の一覧の抽出 |

## 追加・変更するファイル

| ファイル | 責務 | 新規/変更 |
| --- | --- | --- |
| `.zigversion` | 固定している Zig のバージョンの唯一の正。`0.17.0` の1行 | 新規 |
| `build.zig.zon` | パッケージの宣言 | 新規 |
| `build.zig` | 版の強制と、ビルド・検証の step の定義 | 新規 |
| `src/sucheme.zig` | 公開 API のモジュールのルート | 新規 |
| `src/main.zig` | ネイティブの実行ファイルのエントリ | 新規 |
| `tools/check-docs/main.zig` | ドキュメントとビルド設定の機械検査 | 新規 |
| `tools/extract-r7rs-required/main.zig` | 付録Aの HTML から必須識別子を抽出する | 新規 |
| `tools/extract-r7rs-required/appendix-a.html` | 抽出の入力。出典と取得日を `SOURCE.md` に記録する | 新規 |
| `tools/extract-r7rs-required/SOURCE.md` | 取得元 URL、取得日、複製の許諾の根拠 | 新規 |
| `tests/r7rs-required/*.txt` | 付録Aの識別子一覧。16ファイル | 新規 |
| `.github/workflows/ci.yml` | push と PR での検証 | 新規 |
| `.gitignore` | `zig-out/` と `.zig-cache/` を追記 | 変更 |
| `.gitattributes` | `*.wasm binary` を追記 | 変更 |
| `.editorconfig` | Scheme のファイル(`.scm` `.sld` `.ss`)の2スペース設定を追記 | 変更 |
| `.github/dependabot.yml` | 担当者の修正と `TODO(project):` の解消 | 変更 |
| `AGENTS.md` | 検証コマンド表に3行追加(後述) | 変更 |
| `README.md` | 段階0完了後に偽になる現在形の記述を直す | 変更 |
| `docs/onboarding.md` | 同上。`.zigversion` の不在を前提にした記述を直す | 変更 |
| `docs/design/architecture.md` | 確保点の一元化の不変条件の範囲を直す(後述) | 変更 |
| `docs/design/zig-api-notes.md` | `minimum_zig_version` の誤りと check-docs の検査項目を直す | 変更 |
| `docs/roadmap.md` | 現在地とチェックボックスの更新 | 変更 |
| `docs/design/open-questions.md` | 段階0の行を削除 | 変更 |

`.gitattributes` と `.editorconfig` の変更が小さいのは、既存の設定が既に大部分を覆っているためである。`.gitattributes` の `* text=auto eol=lf` が `.zig` と `.scm` と `.sld` を覆い、`.editorconfig` の既定(4スペース・LF・末尾改行)が Zig の慣習と一致する。実態を確認せずに「追記する」と書くと、何も変わらない変更になる。

`src/` の中身は段階0では最小にとどめる。値表現やヒープは段階1の計画で設計ドキュメントから起こす。段階0で先回りして骨組みを作らない(YAGNI)。

## 版の強制

`build.zig` が `.zigversion` を読み、`builtin.zig_version` と比較して不一致ならビルドを止める。

`build.zig.zon` の `minimum_zig_version` にバージョン検査を期待してはならない。Zig 0.17.0 では検査されない。実機で確認した。`minimum_zig_version = "0.99.0"` のまま `zig build` と `zig build test` を実行すると、警告も出さずに exit 0 になる。`lib/compiler/` に `builtin.zig_version` との比較は存在しない。`minimum_zig_version` は記録としてのみ書き、強制は `build.zig` が行う。

実機で動作を確認した形。

```zig
const pinned_raw = @embedFile(".zigversion");

fn checkZigVersion() void {
    const pinned = std.mem.trim(u8, pinned_raw, &std.ascii.whitespace);
    const want = std.SemanticVersion.parse(pinned) catch @panic("bad .zigversion");
    const have = builtin.zig_version;
    if (want.major != have.major or want.minor != have.minor or want.patch != have.patch) {
        std.debug.print("[sucheme] .zigversion pins {f} but Zig {f} is in use.\n", .{ want, have });
        std.process.exit(1);
    }
}
```

`.zigversion` を `0.99.0` にすると `[sucheme] .zigversion pins 0.99.0 but Zig 0.17.0 is in use.` を表示して configure 段で止まり、`0.17.0` に戻すと通ることを確認した。`@embedFile` のパスは `build.zig` のあるディレクトリ、すなわちリポジトリルートからの相対である。

完全一致を要求する。`minimum` ではなく固定なので、新しい版でも止める。[ADR-0001](../adr/0001-zig-version-pinning.md) の「0.17.0 に固定する」を機械的に強制するためである。緩めると、新しい版で API が変わった箇所だけが壊れて原因が分かりにくくなる。

## ビルドスクリプト

### step の一覧と依存関係

`AGENTS.md` の検証コマンド表が `zig build <名前>` の形で呼ぶ step の正である。表の各行が「使えるようになる段階」を持つので、段階0では段階0の行の step だけを定義する。存在しない step を呼ばない形にするためである。

段階0で定義する step。

| step | 内容 | 依存 |
| --- | --- | --- |
| 既定(`zig build`) | `sucheme` 実行ファイルのインストール | `installArtifact` |
| `run` | 実行ファイルを起動する。`--` 以降を転送する | 既定の install step |
| `test` | ネイティブ対象のモジュールのテスト | なし |
| `check-docs` | `tools/check-docs` を実行する | なし |

`run` を `AGENTS.md` の検証コマンド表に追加する。表が step の正であると宣言している以上、表外の step を作ると検査もレビューの対象外になる。表には「CIで実行: -」として、検証コマンドではないことを示す。

段階1以降で追加する step と段階の対応は `AGENTS.md` の表が正とし、`build.zig` のコメントには書かない。コメントに書くと同じ対応表が3箇所になり、段階が進むたびに取り残しが出る。

### 検証コードを検証する

`tools/` の2つのプログラムは段階0の新規ロジックの大半を占める。これらが黙って壊れると、検査が働いていないことに気づけない。したがって次の2つを行う。

- `tools/` の各モジュールを `test` step の対象にする。
- 純粋な判定関数に単体テストを置く。`check-docs` の `fenceRun` `atxHeadingText` `hasUriScheme` `linkDestination` `zigImports` `hasRefAllDeclsTest` `workflowZigVersions` `pathIn` `normalizePath`、`extract-r7rs-required` の `decode` `codePointOf` `isPlainLibraryName` が対象である。

テストの中身は、レビューが実際に作った迂回入力をそのまま使う。仮想の入力ではなく、一度通ってしまった穴を回帰として固定する。ハーネスだけを足して中身を空にすると、「テストが走る仕組みはある」という主張だけが残って実体がない。

### テストが黙って走らない経路への対処

Zig 0.17.0 では、モジュールの非ルートファイルの `test` ブロックは、ルートから参照されない限り1件も実行されない。実機で確認した。`src/sucheme.zig` に `pub const reader = @import("reader.zig");` と書き、`src/reader.zig` に必ず失敗するテストを置いても `2/2 tests passed` で exit 0 になる。失敗するテストが実行されていない。

`std.testing.refAllDeclsRecursive` は Zig 0.17.0 に存在しない(`error: root source file struct 'testing' has no member named 'refAllDeclsRecursive'`)。`refAllDecls` は1段しか辿らない。ルートだけに置いても入れ子のディレクトリには届かないことを確認した。

したがって規約を次のとおり定める。

- 他の `.zig` を `@import` するファイル(`src/` と `tools/` の両方)は、`test { std.testing.refAllDecls(@This()); }` を持つ。
- これにより各階層で1段ずつ参照が連鎖し、`src/syntax/expand.zig` のような入れ子のテストまで実行される。実機で、各階層に置いた場合に `3 pass, 1 fail (4 total)` となり入れ子の失敗が検出されることを確認した。

`tools/check-docs` がこの規約を検査する(後述)。規約だけでは守られない。

### 対象モジュールとパスの対応

`test` step の対象モジュールと、`check-docs` に渡す `--root` のパスは1つの値(`TestTarget`)にまとめ、同じループで両方に使う。さらに `TestTarget.check` が、モジュールの `root_source_file` がそのパスから作られたことを configure 段で照合する。

照合を入れるのは、struct にまとめるだけでは対応の正しさを誰も見ないためである。`.{ .path = "src/main.zig", .mod = sucheme }` のように片方だけ取り違えた値は、構文上は1つの値でありながら `src/main.zig` のテストを1件も実行しない状態を作る。実機でこの状態を再現し、`zig fmt --check` と `zig build` と `zig build test` と `zig build check-docs` のすべてが緑になることを確認した。

### テスト対象から除くもの

`wasm32-freestanding` を対象とするモジュールに `addTest` を作ってはならない。実機で確認したところ、テストランナーが freestanding で成立せず4件のコンパイルエラーになる(`posix.system.getrandom`、`IOV_MAX`、`STDIN_FILENO`、`process/Args.zig` のフィールドアクセス)。

したがって `test` step の対象はネイティブ対象のモジュールに限る。段階1で `src/wasm.zig` を追加するときは、`wasm` step でビルドするだけとし、`test` step には入れない。WASM の振る舞いの検証は Node.js 上での往復テストで行う([ADR-0010](../adr/0010-ci-cd-and-release-strategy.md))。

この除外の規則を `tools/check-docs` の検査にも反映する。除外対象のファイル名を `build.zig` に列挙し、check-docs がその列挙を読む。

### プロジェクト版数

`build.zig.zon` の `.version` を正とし、`src/` には定数として複製しない。`build.zig` が `b.addOptions` でビルドオプションとして渡し、`src/sucheme.zig` が `@import("build_options")` から読む。段階0でこの経路を作る。

当初は段階0では定数で書いて段階1でオプション経由に変える計画だったが、その間はプロジェクト版数が2箇所にあり、段階2で `.version` を上げて定数を忘れると `sucheme --version` が古い版を表示したまま配布される。2箇所に置く期間を作らない。

`build.zig.zon` の `fingerprint` は初回のビルドでエラーメッセージが正しい値を教えるので、それを貼って確定させる。一度決めたら変更しない。実機で `error: invalid fingerprint: 0x0; if this is a new or forked package, use this value: 0x...` の形で教えられることを確認した。

## src の最小構成

`src/sucheme.zig` は公開 API のモジュールのルートとする。段階0では処理系の名前と、ビルドオプションから読んだバージョンを `pub const` として公開する。関数にしない。段階0の段階では値が定数であり、関数にすると呼び出し側に無意味な括弧を書かせる。

`src/main.zig` は `sucheme` モジュールをインポートし、引数を解釈する。引数と終了コードの契約は `src/main.zig` の doc コメントに置き、ここには複製しない。診断は標準エラーに書き、要求に応えられない場合は非ゼロで終わる。`sucheme prog.scm && echo ok` が ok を表示してはならない。Zig 0.17.0 のエントリポイントは `pub fn main(init: std.process.Init)` であり、標準出力は `std.Io` 経由で取る。書き込み後に `flush()` を呼ぶ([../design/zig-api-notes.md](../design/zig-api-notes.md))。

両ファイルに `test` ブロックを置く。`src/sucheme.zig` はバージョンが空でないことを、`src/main.zig` は引数の解釈の関数が `--version` を認識することを確かめる。`test` step は対象モジュールごとに `addTest` を作る。段階0の対象は `sucheme`、実行ファイルの `root_module`、`tools/` の2つで計4つである。件数は `build.zig` の `targets` が正であり、ここに複製しない。

### エントリポイントとアロケータ

`src/main.zig` はコマンドライン引数を読むために `init.arena.allocator()` を使う。これは `std.mem.Allocator` である。

[../design/architecture.md](../design/architecture.md) の確保点の一元化は「`std.mem.Allocator` の直接使用は `src/` の全モジュールで禁止する。モジュール名による例外は置かない」と書いており、例外は `heap.zig` と `tools/` の2つである。この書き方のままでは `src/main.zig` が実装できない。段階0では `heap.zig` がまだ存在しないので迂回もできない。

不変条件の意図は「計上すべき確保を `heap.zig` の外で行わせない」ことである。エントリポイントがホストのアロケータを受け取って `heap.zig` に渡す経路は、計上の対象を確保していない。この区別を architecture.md に書く。範囲を「GC オブジェクトとそのヒープ外ペイロード、および計上の対象に挙げたものの確保」に限り、エントリ層(`main.zig` と `wasm.zig`)がホストのアロケータを受け取って基盤へ渡すことを明示的に許す。

これは不変条件の文面の変更である。意図を変えるものではないが、[../design/architecture.md](../design/architecture.md) は実装者が判断に迷ったときに優先する文書なので、変更をユーザーに報告する。

## tools/check-docs

`build.zig` が実行ファイルとして組み立て、`check-docs` step で走らせる。

検査する項目。

| 項目 | 検査の内容 |
| --- | --- |
| バージョンの3箇所の一致 | `.zigversion` の値が `build.zig.zon` の `minimum_zig_version` と `.github/workflows/*.yml` のリテラルに一致する |
| ベンダリングした入力のハッシュ | 出所の文書が記録した SHA-256 と内容が一致する |
| テストの到達性 | `src/` と `tools/` の全 `.zig` が、`test` step の対象モジュールのルートから `@import` の連鎖で到達できる。除外リストにあるものを除く |
| `refAllDecls` の規約 | 他の `.zig` を `@import` するファイルが `refAllDecls(@This())` を呼ぶ `test` を持つ。呼び出しは修飾され、引数は `@This()` である |
| 相対リンクの到達性 | Markdown の相対リンクが実在するファイルを指す。コードフェンス内のリンクは対象外 |
| 見出しの重複 | 1つの Markdown ファイル内に同じ見出しが2つない |
| コードフェンスの閉じ忘れ | 開いたフェンスが閉じられている。閉じ忘れると以降のリンクと見出しが検査されなくなる |
| 読み取れないファイル | 走査対象のファイルがすべて読めた。読めないファイルは検査から抜けるので報告する |

後の2項目は、設計フェーズで手作業で回していた検査である。段階0で機械化しておかないと、段階が進むにつれて壊れる。導入時点のリポジトリに対して走らせた結果、到達しないリンクは `docs/adr/README.md` の2件(非推奨化手順の雛形として置かれたプレースホルダ)だけで、どちらもコードフェンス内にある。フェンスを除外すれば緑になる。重複見出しは0件である。ファイル数は変更とともに動くので書かない。

### バージョン宣言の不在の検査は置かない

当初は「README・ロードマップ・オンボーディング・SOW に版数の宣言が現れない」ことを検査する計画だったが、置かない。機械検査にできない。

実際に走らせると偽陽性と偽陰性が同時に出る。`docs/onboarding.md` には `[0.17.0 の言語リファレンス](https://ziglang.org/documentation/0.17.0/)` という参照の URL があり、これは宣言ではないのに `0.17.0` に一致する。同じファイルの落とし穴の表には `0.17 では std.Io.Dir.cwd()` と書かれており、こちらは版を上げたときに古くなる記述なのに `0.17.0` には一致しない。「宣言」と「参照」と「確認の記録」を文字列で区別できない。

対象ファイルを列挙する形にすると、列挙に載っていないファイルが黙って対象外になる。リポジトリの追跡 Markdown は数十ファイルあり、列挙は4ファイルだった。本計画書自身も `0.17.0` を含み、列挙の外にある。件数は変更とともに動くので書かない。

版数の記述の扱いは [../design/zig-api-notes.md](../design/zig-api-notes.md) の更新手順に人手の作業として残す。同ファイルの「`tools/check-docs` が検査するのは第1種だけである」という記述を、本計画の検査項目に合わせて書き換える。機械検査するのは3箇所の一致だけであり、宣言の不在は人手で確認する。

### 報告の形

失敗した項目をすべて報告してから非ゼロで終わる。最初の失敗で止めると、1回の実行で1件しか直せない。

リポジトリルートの特定は、`build.zig` が `run.setCwd(b.path("."))` を設定して行う。実機で確認したところ、Run step の作業ディレクトリは `zig build` を起動したディレクトリであり、ビルドルートではない。設定しないと、別のディレクトリから `zig build --build-file <path>/build.zig check-docs` を実行したときに `FileNotFound` で落ち、検査結果ではなく I/O エラーが返る。

`.github/workflows/*.yml` が0個の場合は不合格とする。作業順序では check-docs が CI より先に作られるので、この状態を必ず通過する。通過させるために「0個なら読み飛ばす」と実装すると、以後 `ci.yml` を誤って削除しても検査が通り続ける。したがって作業順序を変え、`ci.yml` を check-docs より先に作る。

## 必須識別子の一覧の抽出

`tests/r7rs-required/<library>.txt` を作る。1行1識別子、ライブラリごとに1ファイル、計16ファイルである。

### 入力

入力は次の URL のページである。

```
https://standards.scheme.org/corrected-r7rs/r7rs-Z-H-10.html
```

これを `tools/extract-r7rs-required/appendix-a.html` として保存し、コミットする。ビルド時にネットワークから取得しない([ADR-0013](../adr/0013-testing-strategy-and-conformance-suite.md) と同じ理由)。再現可能にするためと、抽出結果を後から検証できるようにするためである。

[../design/r7rs-coverage.md](../design/r7rs-coverage.md) と [../onboarding.md](../onboarding.md) が挙げている `https://standards.scheme.org/corrected-r7rs/r7rs.html` は分割 HTML の表紙である。実機で取得したところ 7,888 バイトで、`(scheme ` の出現は0件、識別子一覧も0件である。付録Aは上の `r7rs-Z-H-10.html`(67,552 バイト)にある。表紙の URL を入力にすると、抽出プログラムは0ライブラリを報告する。

### 保存する文書の出典

67KB の第三者文書の逐語コピーをリポジトリに入れるので、[ADR-0013](../adr/0013-testing-strategy-and-conformance-suite.md) のベンダリングの規律に従う。`tools/extract-r7rs-required/SOURCE.md` に取得元 URL、取得日、複製の許諾の根拠を記録する。

複製は許諾されている。R7RS の Introduction の Background 節が「We intend this report to belong to the entire Scheme community, and so we grant permission to copy it in whole or in part without fee.」と述べている。この原文を SOURCE.md に引用する。

`README.md` のライセンスの節は、外部由来のライセンス物の置き場所を `tests/vendor/` に限定して書いている。`tools/extract-r7rs-required/` を加える。

### 抽出

抽出プログラムが HTML からライブラリの節と識別子の列を読む。節の区切りは `(scheme X)` の出現である。実機で確認したところ、付録A 内に `(scheme X)` は16回、重複なく文書順に現れる。

識別子を正規化する。付録Aの HTML には識別子にゼロ幅空白(U+200B)が混入している。`?` や `<` の直後に挿入されているため、`binary-port?` や `char<?` のような識別子がそのままでは壊れる。U+200B を除去し、前後の空白を落とす。正規化しないと、`zig build report` が `lib/**/*.sld` のエクスポート節と突き合わせたときに該当する識別子が1件も一致せず、実装済みでも恒久的に未実装として準拠マトリクスに表示される。

各ファイルの先頭に、出典の URL、取得日、抽出プログラムのパスをコメント行(`;` で始まる)として書く。

### 抽出結果の妥当性検査

抽出プログラムが次を確認し、満たさなければ非ゼロで終わる。

| 検査 | 内容 |
| --- | --- |
| ライブラリ数 | 16個であること |
| 補助構文 | `(scheme base)` が `...` `=>` `_` `else` `unquote` `unquote-splicing` の6個を含むこと |
| 識別子の形 | どの識別子にも空白と U+200B が含まれないこと |

識別子の総数は標準出力に報告するだけとし、閾値の検査にはしない。

当初は「`(scheme base)` の識別子数が他のライブラリの合計より多い」ことを検査する計画だったが、これは偽である。`(scheme r5rs)` が R5RS のほぼ全体を再エクスポートするため、他15ライブラリの合計は `(scheme base)` を上回る。この検査を入れると、正しく抽出したときに必ず失敗し、実装者が正しい結果を壊すまでパーサを「修正」することになる。

補助構文の6個を検査対象にするのは、[../design/frontend.md](../design/frontend.md) の意味の種類の決定がこの6個の存在に依拠しているためである。抽出が構造を読み違えると、まずここが欠ける。

### 起動手段

`build.zig` に名前付きの step を作らない。`zig run tools/extract-r7rs-required/main.zig` で走らせる。生成結果をコミットし、R7RS の版が上がったときだけ再実行する。

step を作らない理由は、`build.zig` を触ることで作業の並行条件が崩れることである。手で走らせる道具なので CI の対象にもしない。再抽出の結果が正しいことは、`check-docs` が `appendix-a.html` のハッシュを照合することで担保する。実機で、`pub fn main(init: std.process.Init)` 形式のプログラムが `zig run` で動作することを確認した。

記憶や他の処理系の実装からの推測で書かない。設計フェーズで、存在しない引用と存在しない手続き名をそれぞれ1件書いた経緯がある([../review/adversarial-review-baseline.md](../review/adversarial-review-baseline.md))。抽出を機械化するのはその再発を防ぐためである。入力ページの URL と妥当性検査の内容も、上のとおり実機と一次情報で確認したものに置き換えた。

## CI ワークフロー

### ジョブ構成

`.github/workflows/ci.yml` を作る。契機は push と PR([ADR-0010](../adr/0010-ci-cd-and-release-strategy.md))。

| ジョブ | ランナー | 内容 |
| --- | --- | --- |
| `test` | `ubuntu-latest` と `windows-latest` のマトリクス | Zig のセットアップ、`zig fmt --check .`、`zig build`、`zig build test`、`zig build check-docs` |

段階0のジョブは1つだけにする。`AGENTS.md` の検証コマンド表で CI 実行が「全コミット」かつ使えるようになる段階が0の行がこれだけだからである。独立に数え上げた結果、該当するのは5行で重複を除いたコマンドは4つである。

`zig fmt --check .` は両方のランナーで走らせる。CRLF の `.zig` ファイルを `zig fmt --check` が不合格にすることを実機で確認したので、Windows で改行が壊れた場合に検出できる。

ワークフローのコメントは英語で書く。`AGENTS.md` の言語ルールがコード内コメントを英語と定めており、ワークフローもコードとして保守する。`build.zig` の step の説明も英語にする。`zig build --help` に表示される UI ラベルであり、同ルールが UI ラベルを英語と定めている。

Zig のバージョンは `ci.yml` にリテラルで書く。`tools/check-docs` が `.zigversion` との一致を検査する。`.zigversion` を読む形にすると、check-docs が比較対象を見つけられず、[../design/zig-api-notes.md](../design/zig-api-notes.md) が定める「3箇所の一致」が2箇所に退化する。

ワークフローに `permissions: contents: read` を置き、`concurrency` で同じブランチの先行実行を打ち切る。既定の権限より狭くするためと、連続プッシュで課金を無駄にしないためである。

二重実行はトリガのフィルタで止める。`push` を `branches: [main]` に絞ると、フィーチャーブランチへのプッシュは `pull_request` の実行だけ、`main` へのプッシュは `push` の実行だけになり、どちらも1回で済む。

group の共有では解決しない。打ち切りは group 単位でイベント単位ではないので、2つの実行を同じ group に入れると片方が打ち切られるだけであり、PR のチェック一覧に打ち切られた実行が残る。group は `github.workflow` と `github.ref` の組にして、同じブランチの先行実行を新しいコミットが追い越す用途に限る。

追い越しの帰結として、古いコミットの実行は cancelled で終わり緑にならない。読まれない実行に課金しないための意図した取引であり、「CI全ジョブグリーン」は PR の head コミットについて判定する。中間のコミット1つずつではない。`AGENTS.md` の検証コマンド表の「CIで実行: 全コミット」は、どのコミットでも同じ検証が走る対象であることを指し、すべての中間コミットの実行を緑のまま残すことを求めてはいない。

### Zig のセットアップ手段

`AGENTS.md` の検証コマンド表のセットアップ行は `scoop install zig` で、これは Windows 専用である。CI の ubuntu では使えない。手段をユーザーに確認してから決める(後述の「ユーザーに確認すること」)。

決まるまで `ci.yml` を作らない。第三者製の GitHub Action を選ぶ場合は新しいサプライチェーン上の依存になり、`AGENTS.md` の進め方の節が実行前のユーザー確認を求める範囲に入る。

### 段階ごとに増える検証の扱い

ワークフローのファイルは段階ごとに書き換える。条件分岐や「step があれば実行する」という形にはしない。存在しない step を呼ぶと失敗し、失敗を無視する形にすると検証が無効になったことに気づけない。

各段階の計画書で、その段階で CI に追加する行を明示する。追加する対象は、`AGENTS.md` の表の行である。表が CI 検証の正であるためには、ADR と設計ドキュメントが要求している CI 検証も表に行を持たなければならない。段階0で次の3行を `AGENTS.md` の表に足す。

| 用途 | コマンド | 使えるようになる段階 | CIで実行 |
| --- | --- | --- | --- |
| 実行(REPL) | `zig build run` | 0 | - |
| テスト(WASM の往復) | `zig build test-wasm` | 1 | 全コミット |
| 準拠マトリクスの同期検査 | `zig build check-report` | 1 | 全コミット |

`test-wasm` は [ADR-0010](../adr/0010-ci-cd-and-release-strategy.md) が要求する「Node.js 上でのエクスポート呼び出しの往復テスト」である。行がないと、`README.md` が謳う WebAssembly の動作保証を検証する経路が CI に入らず、`sucheme.wasm` が一度も実行されずに出荷される。

`check-report` は [../design/r7rs-coverage.md](../design/r7rs-coverage.md) が要求する「生成し直した結果が現在のファイルと一致するかを検査し、一致しない場合は失敗させる」である。`zig build report` は生成するだけで同期を検査しない。行がないと、[0001-sow.md](0001-sow.md) のリスク対策と段階6の「CI による同期検査」が成立しない。

段階ごとに CI に追加する検証は次のとおりになる。

| 段階 | CI に追加する検証 |
| --- | --- |
| 1 | `zig build test-scheme`、`zig build wasm`、`zig build test-wasm`、`zig build report`、`zig build check-report` |
| 6 | `zig build test-conformance` |

### ファジングのワークフローの置き場所

ファジングは `--fuzz` が自律的に停止しないため、全コミットの CI に入れない(`AGENTS.md`)。段階1でリーダができた時点で `.github/workflows/fuzz.yml` を作り、`schedule` と `workflow_dispatch` の2つを契機にする。段階0ではファイルを作らない。対象が存在しないワークフローを置くと、毎回失敗するか何も検査しない。

この決定を `ci.yml` の先頭コメントに書き、段階1の担当者が別ファイルを作ることが分かるようにする。

## 文書の現在形の記述

段階0の成果物は、`README.md` と `docs/onboarding.md` の記述を偽にする。同じコミットで直す。

| 箇所 | 現在の記述 | 段階0完了後の実態 |
| --- | --- | --- |
| `README.md` の冒頭 | 設計のみで実行できる成果物はない | `sucheme --version` が動く |
| `README.md` の状況 | 設計フェーズが完了し実装の開始を待っている | 段階0が完了し段階1に着手できる |
| `README.md` の対応プラットフォームの前置き | `build.zig` も CI もまだ存在しない | 両方存在し、x86_64 の Linux と Windows でテストが走る |
| `docs/onboarding.md` の前提表 | 段階0の完了まで `.zigversion` は存在しない | 存在する |

リポジトリの入口が自分の CI の存在を否定する状態を作らない。

## リポジトリの可視性と dependabot

リポジトリの可視性は GitHub の設定であり、コードの変更を伴わない。エージェントが可視性を変更しない。実行はユーザーに依頼する。段階0の作業中に public にしたのち private に戻し、現行の決定は [ADR-0020](../adr/0020-repository-visibility-private.md) が持つ。

`.github/dependabot.yml` の担当者をテンプレート由来の値から修正する。修正後の値はユーザーに確認する(後述)。

あわせて `TODO(project):` のコメントを解消する。コメント済みのエコシステムは npm、uv(Python)、gomod(Go)、bundler(Ruby)、nuget(.NET)の5件で、本リポジトリはいずれも使わない。Web UI も依存パッケージを持たない([ADR-0009](../adr/0009-wasm-freestanding-and-zero-dependency-web-ui.md))。コメント自体を削除し、GitHub Actions のみを対象とする形を明示する。

`cooldown` の設定はサプライチェーン攻撃対策である。`AGENTS.md` のセキュリティの節に従い、削除も無効化もしない。

`.github/workflows/` と `.github/dependabot.yml` の変更はユーザーの承認を得てから行う(`AGENTS.md`)。本計画書の承認をもって、本計画に明記した内容の範囲での変更の承認とする。計画に値が書かれていない項目(Zig のセットアップ手段、dependabot の担当者)は別に確認する。

## ユーザーに確認して決めたこと

計画書に値を書けなかった2点を、実装に入る前にユーザーに確認して決めた。

| 事項 | 決定 |
| --- | --- |
| CI での Zig のセットアップ手段 | `mlugg/setup-zig` を使う。コミットの SHA でピン留めし、`.github/dependabot.yml` の `github-actions` エコシステムの更新対象にする |
| `.github/dependabot.yml` の担当者 | `suchi` |

`mlugg/setup-zig` を選んだのは、キャッシュとチェックサム検証を内蔵しており、ubuntu と windows で同じ記述が使えるためである。受け入れたトレードオフは、サプライチェーン上の面が1つ増えることである。これを次の2つで抑える。

- バージョン参照をタグではなくコミットの SHA にする。タグは付け替えられる。
- `dependabot.yml` の `github-actions` エコシステムの対象に含め、`cooldown` の期間を経た更新として受け取る。

自前で ziglang.org から取得する案も検討した。第三者 Action への依存がなくなる代わりに、ubuntu と windows で別のコマンドを書き、キャッシュも自前で持つことになる。検証する範囲が増えるほうが面としては大きいと判断した。

## 作業の順序

依存関係があるため逐次で進める。

1. `.zigversion`、`build.zig.zon`、`src/sucheme.zig`、`src/main.zig`、`build.zig`(版の強制とビルドオプションを含む)を作り、`zig build` と `zig build test` がローカルで通ることを確認する。`fingerprint` をここで確定させる。
2. `.gitignore`、`.gitattributes`、`.editorconfig` に追記する。1と並行できる。
3. `AGENTS.md` の検証コマンド表に3行を足す。`docs/design/architecture.md` の確保点の一元化の範囲を直す。`docs/design/zig-api-notes.md` の `minimum_zig_version` と check-docs の記述を直す。1と並行できる。
4. `.github/workflows/ci.yml` を作る。1の完了後、かつ Zig のセットアップ手段が決まった後。
5. `tools/check-docs` を作り、`check-docs` step を追加する。1と3と4の完了後。CI より後にするのは、ワークフローが0個の状態で版の一致検査を通過させないためである。
6. `tools/extract-r7rs-required` と `appendix-a.html` と `SOURCE.md` を作り、`zig run` で走らせて `tests/r7rs-required/*.txt` をコミットする。1の完了後。4と5と並行できる。
7. `.github/dependabot.yml` を修正する。担当者が決まった後。どの段とも独立。
8. `README.md` と `docs/onboarding.md` の現在形の記述を直す。4と5の完了後(CI が実際に緑になったことを確認してから書く)。
9. ロードマップのチェックと現在地を更新し、open-questions.md の段階0の行を消す。すべての完了後。

6と5は触るファイルが重複せず、互いのインタフェースに依存しない。並行させてよい([0001-sow.md](0001-sow.md) のマルチエージェントの使い方)。6が `build.zig` に step を作らないと決めたのは、この並行条件を保つためでもある。

## テストと Red からの手順

段階0の成果物はビルドの足場なので、「検証が働くことの検証」が中心になる。各作業で Red を作る手順を定める。作業2・7・9には Red を置かず、代わりの確認手段を書く。

| 作業 | Red の作り方 | Green の判定 |
| --- | --- | --- |
| 1(版の強制) | `.zigversion` を `0.99.0` にして `zig build` が診断を出して止まることを確認する | 戻すと通る。実機で確認済み |
| 1(`test` step) | `src/sucheme.zig` に必ず失敗する `test` を書き、`zig build test` が非ゼロで終わることを確認する | 直すと通る。実機で確認済み |
| 1(ビルドオプション) | `build.zig.zon` の `.version` を変えて `zig build run -- --version` の出力が変わることを確認する | 変わる |
| 5(テストの到達性) | `src/` に `@import` されない `.zig` を置き、`zig build check-docs` が失敗することを確認する | `@import` すると通る |
| 5(`refAllDecls` の規約) | 他を `@import` するファイルから `refAllDecls` を消して失敗することを確認する | 戻すと通る |
| 5(版の3箇所の一致) | `build.zig.zon` の `minimum_zig_version` を違う値にして失敗することを確認する | 戻すと通る |
| 5(相対リンク) | Markdown に存在しないファイルへのリンクを書いて失敗することを確認する。コードフェンス内に同じリンクを書くと失敗しないことも確認する | 両方の挙動が一致する |
| 5(見出しの重複) | 同じ見出しを2つ書いて失敗することを確認する | 消すと通る |
| 6(識別子の抽出) | `appendix-a.html` の一部を壊してライブラリ数が16でなくなり、非ゼロで終わることを確認する | 戻すと16ファイルが生成される |
| 6(識別子の正規化) | 生成された `base.txt` を機械的に走査し、U+200B と空白を含む行が0件であることを確認する | 0件 |
| 4(CI) | 後述 | 後述 |

作業2(git 設定)の確認: `zig build` の後に `git status --porcelain` が空であることを確認する。`.gitignore` に `zig-out/` と `.zig-cache/` を足し忘れると、ここに数百件の未追跡ファイルが出る。`.zig-cache` は隠しディレクトリなので `zig fmt --check .` は走査せず、CI は緑のまま通ることを実機で確認した。この確認を作業2の完了条件とする。

作業7(dependabot)の確認: `gh api` で dependabot の設定が解釈できているかを確認する。構文エラーは GitHub 側のログにしか出ない。

作業9(ロードマップ)の確認: `zig build check-docs` の相対リンク検査が通ること。

作業4(CI)の確認: CI が実際に赤を出せることを一度確認する。意図的に `zig fmt` 違反をコミットする形は採らない。`AGENTS.md` が「コミット前に必ずテスト・リントを実行する」としており、`.claude/hooks/` にもコミット前の保護がある。代わりに、作業2の `.gitignore` 追記より前の状態で CI を1回走らせ、`git status` が汚れることによる失敗を確認する。あるいは作業用のブランチで確認して PR には載せない。どちらを採るかは実装者が選ぶ。確認したことを PR 本文に書く。

## 参照する設計ドキュメントと ADR

| 文書 | 参照する内容 |
| --- | --- |
| [../design/zig-api-notes.md](../design/zig-api-notes.md) | `build.zig` と `build.zig.zon` の記法、エントリポイント、標準出力、版数の更新手順 |
| [../design/architecture.md](../design/architecture.md) | ディレクトリの役割、横断的な不変条件 |
| [../design/r7rs-coverage.md](../design/r7rs-coverage.md) | 必須識別子の一覧の扱い |
| [ADR-0001](../adr/0001-zig-version-pinning.md) | Zig のバージョン固定と API ノートの運用 |
| [ADR-0010](../adr/0010-ci-cd-and-release-strategy.md) | CI のジョブ構成、ランナー、WASM の往復テスト、ファジングの扱い |
| [ADR-0020](../adr/0020-repository-visibility-private.md) | リポジトリの可視性 |
| [ADR-0013](../adr/0013-testing-strategy-and-conformance-suite.md) | テストの3層構成、ベンダリングの規律 |
| [ADR-0015](../adr/0015-mit-license.md) | ライセンス |
| [ADR-0018](../adr/0018-incremental-vertical-slices.md) | 実装時に決めることの記録先 |

## この計画で決めなかったこと

段階1以降に属するものを列挙する。段階0の作業中にこれらを先回りで作らない。

- `src/` のモジュール分割。[../design/architecture.md](../design/architecture.md) のモジュールマップが設計だが、ファイルを作るのは段階1である。
- WASM のビルド step と `web/`、および `test-wasm` の中身。段階1で作る。
- `lib/` の埋め込みの仕組み。段階2のライブラリシステムとともに作る。
- 準拠マトリクスの生成と同期検査(`report` と `check-report`)。段階1で作る。
- リリースのワークフロー。段階1完了時の v0.1.0 のリリースで作る。配置のワークフローは作らない([ADR-0021](../adr/0021-no-github-pages-defer-hosting.md))。
- ファジングのワークフロー。段階1で作る。

## 担当モデル

手順3の実装は Sonnet とする([0001-sow.md](0001-sow.md))。`build.zig`、`tools/check-docs`、`tools/extract-r7rs-required` はいずれも定型的な作業であり、本計画書と [../design/zig-api-notes.md](../design/zig-api-notes.md) に記法が揃っている。本計画書に書いた実機確認の結果は、そのまま実装の雛形として使える。

本計画書に書かれていない判断が必要になった場合は、実装を止めてユーザーに確認する。設計ドキュメントと本計画書のどちらにも根拠がない決定を実装の中で行わない([ADR-0018](../adr/0018-incremental-vertical-slices.md))。
