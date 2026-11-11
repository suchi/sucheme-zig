# ロードマップと進捗

リポジトリから進捗が読み取れるようにするための単一の表。段階の完了条件を満たしたらチェックを入れ、同じ PR でこのファイルを更新する。

各段階は、リーダからプリンタまでネイティブとブラウザの両方で通しで動く状態を作る([ADR-0018](adr/0018-incremental-vertical-slices.md))。層を1つずつ完成させる進め方は採らない。段階の終わりに「確定したこと」と「残していること」を記録する。

「残していること」の欄は、その段階で決めずに後の段階へ回した事項を指す([design/open-questions.md](design/open-questions.md) の行)。未着手の作業項目のことではない。作業の進み具合は各段階のチェックボックスが正である。

作業範囲の全体は [plans/0001-sow.md](plans/0001-sow.md) にある。設計は [design/](design/) に、決定は [adr/](adr/) に、実装時に決めることは [design/open-questions.md](design/open-questions.md) にある。

## 現在地

| 項目 | 状態 |
| --- | --- |
| 現在の段階 | 段階7(REPLの編集機能)。段階7の計画書はまだ無く、実装は始めていない(計画書のない段階の実装は始めない)。段階1は v0.1.0 で、段階2は v0.2.0 で、段階3は v0.3.0 で、段階4は v0.4.0 で、段階5は v0.5.0 で、段階6は v1.0.0 で完了した(段階1のスライスは [plans/0003-phase1-minimal-slice.md](plans/0003-phase1-minimal-slice.md)、完了の手続きは [plans/0013-stage1-completion.md](plans/0013-stage1-completion.md)。段階2の実装計画と進捗は [plans/0014-phase2-core-language.md](plans/0014-phase2-core-language.md)、段階3は [plans/0016-phase3-scheme-stdlib.md](plans/0016-phase3-scheme-stdlib.md)、段階4は [plans/0018-phase4-numeric-tower-unicode.md](plans/0018-phase4-numeric-tower-unicode.md)、段階5は [plans/0019-phase5-ports-and-io.md](plans/0019-phase5-ports-and-io.md) が正である)。段階6の全体の計画書は [plans/0028-phase6-conformance.md](plans/0028-phase6-conformance.md) で、スライス 6j から 6r と 6z のリリースの準備が済み、v1.0.0 が公開された(タグは、準備の PR のマージコミット `5c91951`(コミットは 2026-11-08 06:08 JST)を指し、2026-11-09 06:53 JST に作られ、2026-11-09 07:07 JST に公開された)。段階6の一部(準拠スイートの取り込み、ファジング)は、並行のレーンで先に進めている([plans/0020-conformance-harness-early.md](plans/0020-conformance-harness-early.md)、[plans/0025-fuzzing-the-evaluator.md](plans/0025-fuzzing-the-evaluator.md)。レーンの運用は [plans/0017-parallel-lanes.md](plans/0017-parallel-lanes.md))。計画書のない段階の実装は始めない([plans/README.md](plans/README.md))。段階の数値は `build.zig` の `current_stage` が正で、直前のリリースの次の段階を表す。上げると `zig build check-docs` が新しい行をCIに要求する。`current_stage` は 7 である。検証コマンドの表に、段階7の行はまだ無いので、7 に上げても CI に要求される行は増えない。段階7の行は、その行が指す step が `build.zig` に実在するときに足す(AGENTS.md の検証コマンドの節)。段階6の行(`zig build test-conformance`)は、`ci.yml` の `test` ジョブと `full.yml` の `windows` ジョブにある(ワークフローの変更は suchi/sucheme-zig#250 で承認された) |
| 最新リリース | [v1.0.0](https://github.com/suchi/sucheme-zig/releases/tag/v1.0.0)([リリースノート](releases/v1.0.0.md)) |
| 固定 Zig バージョン | `.zigversion` を参照 |
| R7RS 準拠マトリクス | [status/](status/)(生成されている。1つ目の表は、必須の識別子ごとに、そのライブラリを `import` したときに束縛されるかを見る。`lib/` のエクスポートはスライス 3l で入った。2つ目の表は、準拠スイートの節ごとの結果で、スライス 6f で入った) |

段階ごとの進み具合は下の段階の節のチェックボックスが正である。ここに件数や割合を書くと必ず古くなる。

## 手順と担当モデル

実装は3手順で進める。各手順の区切りでドキュメントを残し、別の環境でも継続できる状態にする。

| 手順 | 内容 | 担当 | 成果物 |
| --- | --- | --- | --- |
| 1 | 設計 | Opus | [design/](design/) と [adr/](adr/) |
| 2 | 具体的実装計画 | Opus | `plans/` の段階ごとの計画書 |
| 3 | 実装 | Sonnet(簡単なものは Haiku) | コードとテスト |

手順1は全体整合性に必要な範囲までとし、1つのモジュールに閉じた詳細は手順3で決める。どちらに属するかの線引きは [ADR-0018](adr/0018-incremental-vertical-slices.md) にある。

## 段階

### 段階0: 足場

- [x] `build.zig` と `build.zig.zon` と `.zigversion`
- [x] Zig 向けの `.gitignore` 追記と `.editorconfig` と `.gitattributes` の追補
- [x] `AGENTS.md` の検証コマンド表を埋める
- [x] ライセンスの決定と `LICENSE` の配置。MIT で始め、private 化の後に UNLICENSED に変えた([ADR-0022](adr/0022-unlicensed-proprietary.md))
- [x] リポジトリの可視性の決定。public にしたのち private に戻した([ADR-0020](adr/0020-repository-visibility-private.md))
- [x] CI ワークフロー(`AGENTS.md` の検証コマンド表で CI 実行が「全コミット」の行のうち、段階0で使えるもの)
- [x] CI の雛形に、段階1で足すファジングのワークフローの置き場所を決める(定期実行と手動起動。全コミットの CI には入れない)
- [x] `tests/r7rs-required/*.txt` を R7RS 付録Aから抽出
- [x] `.github/dependabot.yml` の担当者をテンプレート由来の値から修正

完了条件: CI が ubuntu と windows の両方でグリーンになり、`zig build test` がローカルでも通る。**2026-10-08 に PR #2 のマージで満たした。** `main` の CI がグリーンになったことを確認済みである。

確定したこと: リポジトリは private とする(2026-10-06、[ADR-0020](adr/0020-repository-visibility-private.md))。GitHub Pages は使わず、Web UI の配置は段階8で行う([ADR-0021](adr/0021-no-github-pages-defer-hosting.md))。`build.zig` の step は既定・`run`・`test`・`check-docs`・`check-extract` である。どれが毎コミットで要るかは `AGENTS.md` の表が正で、`zig build check-docs` が表と `ci.yml` と `build.zig` の3つを突き合わせる。版の強制は `build.zig` が `.zigversion` と `builtin.zig_version` を比較して行う(`build.zig.zon` の `minimum_zig_version` は Zig が検査しない)。CI は `ubuntu-latest` と `windows-latest` のマトリクス1ジョブで、Zig は `mlugg/setup-zig` を SHA でピン留めして入れる。付録Aの識別子は `tools/extract-r7rs-required` で機械抽出し、`tests/r7rs-required/` に置いた。ライブラリ数と識別子数は [extract-r7rs-required/SOURCE.md](../tools/extract-r7rs-required/SOURCE.md) の表が正で、`zig build check-docs` が実物と照合する。

残していること: なし。段階0で決めた3事項は open-questions.md から消し、決めた内容は上の「確定したこと」と [plans/0002-phase0-scaffolding.md](plans/0002-phase0-scaffolding.md) にある。未着手の作業項目はチェックボックスを参照する。

### 段階1: 通しで動く最小の縦切り

作業は [plans/0003-phase1-minimal-slice.md](plans/0003-phase1-minimal-slice.md) がスライスに割っている。下のチェックボックスは段階の全体で、スライスごとの完了条件はその計画書が正である。1つの PR に段階1の全部を入れると段階0の経緯が繰り返されるので、スライスごとにマージする。

意図的に小さくする。10進整数と記号と手続き呼び出しだけで `(define (fact n) ...)` が動く状態を目標にする。この時点で値表現、ヒープ、GC、機械、リーダ、プリンタ、REPL、WASM、Web UI、CI がすべて最小の形でそろう。以降の段階はこの縦切りを太らせる作業になる。

- [x] 値表現とシンボルのインターン([design/runtime.md](design/runtime.md) の値の表現の段階1の行) (スライス 1a・1b・1h)
- [x] GCヒープの骨格とマーク・スイープ、ルート登録 API (スライス 1g)
- [x] リーダの最小集合(行コメント、真偽値、10進整数、識別子、文字列、リスト、ベクタ、`'`) (スライス 1a・1c・1h・1l の L1)
- [x] プリンタ(`write` と `display`) (スライス 1a・1h)
- [x] コアIRと展開器の最小集合(`quote` `if` `lambda` `set!` `define` `begin` と呼び出し) (スライス 1f)
- [x] CEK機械の実行ループと、段階1の機構に必要な継続フレーム([design/runtime.md](design/runtime.md) の必要なフレームの種類の段階1の行) (スライス 1f)
- [x] 最外の継続への脱出による未処理例外の報告(継続と条件オブジェクトの最小形) (スライス 1b・1f)
- [x] プリミティブ約30個。算術は固定長整数に限る (スライス 1a・1d・1e・1k。一覧は [plans/0010-slices-1k-1l-primitives-and-repl-continuation.md](plans/0010-slices-1k-1l-primitives-and-repl-continuation.md) の 1k の一覧が正で、個数はここに書かない)
- [x] REPL(素朴な行読み取り、完結判定による継続行) (スライス 1a は素朴な行読み取り、スライス 1l が継続行。継続行の判定の費用は、段階 7 の項目に受け入れた制約として記録した)
- [x] リーダのファジングのワークフローの追加(定期実行と手動起動) (スライス 1j-1。リーダのファジングのテストが `src/reader.zig`、ワークフローが `.github/workflows/fuzz.yml`)
- [x] `fuzz.yml` の GitHub 上での動作の確認のうち、手動起動(`workflow_dispatch`)で 1 回動かし、ジョブが時間の上限の内で終わり、失敗した入力が無いときに検査の手順が緑のまま通ること (スライス 1j-1 のマージ後)
- [x] `fuzz.yml` が失敗した入力を見つけたときに、入力が成果物に上がること(`.zig-cache/f/crash` の場所と `include-hidden-files` の要否を含む)。2026-10-12 に、使い捨てのブランチで欠陥(900 バイトを超える入力で失敗)を仕込んで確かめた。ファジングの手順は終了コード 0 で終わり、`fuzz-crash` の成果物が上がり、検査の手順が失敗してジョブが赤になった([実行](https://github.com/suchi/sucheme-zig/actions/runs/38252355736)) (スライス 1j-1 のマージ後)
- [x] WASM のエクスポート([design/platform-and-web.md](design/platform-and-web.md) のエクスポート)と Web UI の最小版 (スライス 1i)
- [x] Web UI をローカルで開く手段(`file://` から始まる取得は Fetch の対象外のため、手段は段階1の計画で決める) (スライス 1i)
- [x] aarch64 を自動テストの対象に加えるかの判断と ADR の作成。判断は加えないで、[ADR-0033](adr/0033-aarch64-built-but-not-tested.md) に書いた([ADR-0010](adr/0010-ci-cd-and-release-strategy.md) の追記が見直しの時点をこの段階と定めた。値表現とGCが入り、アライメント・ポインタ幅・エンディアンに依存する判断が初めてコードに現れる) (スライス 1j-2)
- [x] 準拠マトリクスの最小版(`zig build report` が `docs/status/conformance.md` を生成し、`zig build check-report` が生成し直した結果との一致を検査する)。必須の識別子ごとに、インタプリタが束縛しているかだけを見る。計画は [plans/0011-slice-1m-conformance-report-early.md](plans/0011-slice-1m-conformance-report-early.md) (スライス 1m)
- [x] PR で Web UI を確認するための成果物の添付のワークフロー(`preview.yml`)。`sucheme.wasm` と `web/` を並べたディレクトリを、CI が `upload-artifact` で上げる([ADR-0021](adr/0021-no-github-pages-defer-hosting.md) が配置の代わりに定めた手段)。`.github/workflows/` の変更なのでユーザーの承認を得てから行う (スライス 1j-3b)
- [x] 上がった成果物を人が展開し、`node serve.mjs` で開いて `(fact 10)` が動くことの確認。2026-10-12 に、ユーザーが PR #70 の preview の成果物で確かめた (スライス 1j-3b のマージ後)
- [x] リリース成果物の組み立て。`zig build dist` が ADR-0010 の一覧の全ターゲットを `ReleaseSafe` で作り、`tools/release/package.py` がアーカイブと `SHA256SUMS` を作って読み直す。`THIRD-PARTY-NOTICES.txt` と、リリースの形の [ADR-0034](adr/0034-release-shape.md) を含む。`full.yml` の `dist` ジョブがリハーサルとして走らせる。`.github/workflows/` の変更なのでユーザーの承認を得てから行う (スライス 1j-3a)
- [x] `full.yml` の `dist` ジョブが GitHub のランナー上で通ること(`python3` の有無、所要時間、キャッシュの挙動を含む)。PR を ready にしたときの実行と、`main` での手動起動で通った。測定値は [plans/0009-slice-1j-release-v0-1-0.md](plans/0009-slice-1j-release-v0-1-0.md) の「確かめた事実」の表にある (スライス 1j-3a)
- [x] リリースのワークフロー(`release.yml`)を足す。タグの push から、版の確認とスモークテストのあとに、下書きのリリースを作る。`.github/workflows/` の変更なのでユーザーの承認を得てから行う (スライス 1j-3c)
- [x] `release.yml` がタグの push で動き、下書きのリリースができること。最初のタグ v0.1.0 で、全手順が成功し、下書きができた([実行](https://github.com/suchi/sucheme-zig/actions/runs/38257497672)) (スライス 1j-4 のタグの push)

完了条件: 階乗の定義と呼び出しがネイティブとブラウザの両方で動く。ブラウザはローカルで開いたもので判定し、配置は行わない([ADR-0021](adr/0021-no-github-pages-defer-hosting.md))。100万回の末尾再帰が一定のメモリで完了する。エラーが未処理例外の経路で報告され、REPL が停止しない。リリース v0.1.0 を出す。

残していること: [design/open-questions.md](design/open-questions.md) の「段階を定めずに保留しているもの」の行。段階1までに決めるとしていた行は、段階1の終わりにそこへ移した。件数と内容をここに複製しない。

### 段階2: コア言語の完成

動的状態の機構と衛生的マクロとライブラリシステムを入れる。この3つは互いに依存するため同じ段階に置く。

- [x] 正確なGCの完成とルート管理規約の確立(範囲は [plans/0014-phase2-core-language.md](plans/0014-phase2-core-language.md) の合意を求める点の5。コアIRのヒープ化と弱いシンボル表は段階3) (スライス 2b。新しいヒープの型は、それを入れる各スライス)
- [x] 完全な `call/cc` と `dynamic-wind` (スライス 2e)
- [x] `values` と `call-with-values`、複数値のオブジェクト (スライス 2f)
- [x] 例外(`raise` `raise-continuable` `with-exception-handler` と条件オブジェクト) (スライス 2b・2d)
- [x] 動的点の単一リストと `handler_shift`([ADR-0016](adr/0016-exception-handler-as-dynamic-point.md)) (スライス 2d・2e・2g)
- [x] `make-parameter` と `parameterize`。動的点の3つめの利用者として同じ段階でそろえる (スライス 2g)
- [x] 衛生的マクロ展開器(`syntax-rules` `let-syntax` `letrec-syntax`) (スライス 2i から 2l)
- [x] マクロの展開のメモリを有界にする(展開の作業領域と節点を、ヒープの上限に計上する)。止まらないマクロの適用が、ヒープの上限を大きく超えて伸びていた。保証するのは1行の中の展開で、残りは下の「マクロの展開の有界化の残り」の項目にある([ADR-0031](adr/0031-gc-at-machine-step-boundaries.md) の 2026-10-13 のスライス 2k の追記と、2026-10-14 のスライス 2l の追記) (スライス 2l)
- [x] ライブラリシステム(`define-library` `import` `export` `begin` `cond-expand` `include` `include-library-declarations`)
- [x] ポートごとのケースフォールディング状態と `include-ci`。リーダの `#!fold-case` ディレクティブは段階5だが、ポートの状態と `include-ci` はここで実装する。機構がないまま `include-ci` を提供すると `include` に退化し、畳み込みを期待したファイルが未束縛識別子のエラーになる
- [x] 第1類(処理系がソースとして読む)のファイル経路をリゾルバに通す([design/frontend.md](design/frontend.md) のファイルを開く経路) (スライス 2n・2o)
- [x] 機械操作プリミティブ9個(`apply` `call/cc` `call-with-values` `values` `dynamic-wind` `with-exception-handler` `raise` `raise-continuable` `make-parameter`)。`eval` と `exit` は環境の値とプロセス文脈が必要なので段階5 (スライス 2c から 2g)
- [x] `define-record-type` の基盤(レコードとレコード型のプリミティブ)。スライス 2h
- [x] 可変個引数の `lambda`(`(lambda args ...)` と `(lambda (a . rest) ...)`、`define` の略記を含む)。スライス 2a

完了条件: [design/frontend.md](design/frontend.md) の衛生性の検証項目のうち、段階2で入力を書けるものがすべて通る。[design/runtime.md](design/runtime.md) のテストに含める事例のうち、段階2で入力を書けるものがすべて通る(書けない事例は、段階3と段階5の完了条件に移した。[plans/0014-phase2-core-language.md](plans/0014-phase2-core-language.md) の合意を求める点の9)。継続の多重起動と `dynamic-wind` の相互作用のテストが通る。`include-ci` が対象ファイルを畳み込んで読む。リリース v0.2.0 を出す。

衛生性の検証項目のうち2つは段階2では入力を書けない。`cond` のリテラル `else` の項目は `cond` が段階3の `lib/sucheme/derived.scm` で定義されるため、循環データの `quote` の項目はデータラベルの記法が段階5だからである。この2つは、それぞれ段階3と段階5の完了条件に含める。

残していること: [design/open-questions.md](design/open-questions.md) の「段階を定めずに保留しているもの」の行のうち、段階2の終わりに移したもの。段階2までに決めるとしていた行は、決めたものを設計文書に書いて消し、決めなかったものを移した。件数と内容をここに複製しない。

### 段階3: Schemeによる標準ライブラリ

- [x] リーダに `` ` `` `,` `,@` の略記を追加(`quasiquote` の定義に必要。文字リテラルはスライス 1h から読める)。スライス 3h。`'` と同じ形で `quasiquote` `unquote` `unquote-splicing` の形になり、データが続かないときの誤りは `'` と同じである。テストは `src/reader.zig` の単体テストと `tests/scheme/0240-reader-abbreviations.txt`
- [x] 文字列のプリミティブ(R7RS 6.7): `make-string` `string` `string-set!` `string-copy` `string-copy!` `string-fill!` `substring` `string-append` `string=?` `string<?` `string>?` `string<=?` `string>=?` `string->list` `list->string` と、ベクタとの変換の `string->vector` `vector->string`(スライス 3d)。大文字小文字を畳み込む手続き(`string-ci=?` `string-upcase` など)は、Unicode の表が入る段階4に置く。3d が入れた: 幅の変わる書き込み(`string-set!` `string-fill!` `string-copy!`)は、新しいバイト列を先に確保して差し替え、計上と ASCII の印を保つ。入力の大きさに比例して確保するもの(`make-string` `string-append` `list->string` `string->vector` `vector->string`)は、バイト列と要素の領域を、書く前に上限に照らして検査し、領域へ直接書く。`string->list` が作るペアは、個数に比例して1ステップの中で確保する(ADR-0031 の 2026-10-15 の追記(3)の「残るもの」と同じ種類で、GC は境目でしか走らない)。テストは `src/prim/string.zig` と `src/heap.zig` の単体テスト、`tests/scheme/0261-string-constants.txt` から `0266-string-limits.txt`、`tests/scheme-slow/0021-string-scale.txt`
- [x] リテラルの不変性([design/runtime.md](design/runtime.md) の「リテラルの不変性」)。`quote` したデータと自己評価するリテラルから到達できるペアと文字列とベクタ、および `symbol->string` の結果に不変の印を立て、書き込む手続きが断る。ユーザーが 2026-10-16 に、基盤を 3d が入れる案を選んだ。3d が入れた: ヘッダの不変の印(`heap.isImmutable` と `heap.makeImmutable`)、リテラルを定数にする1か所(`Expander.constant`)での印の付与(`freeze.freezeGraph`)、`symbol->string` の印、共通の検査 `prim/immutable.zig` の `requireMutable`、それを呼ぶ `set-car!` `set-cdr!` `string-set!` `string-fill!` `string-copy!`(と、それを呼ぶ `list-set!`)。3e が、ベクタとバイトベクタの手続き(`vector-set!` `vector-fill!` `vector-copy!` `bytevector-u8-set!` `bytevector-copy!`)から同じ `requireMutable` を呼び、バイトベクタの型を `heap.isImmutable` と `heap.makeImmutable` と `freezeGraph` の対象に足す。`read-bytevector!` は段階5。3e が入れた: ベクタの `vector-set!` `vector-fill!` `vector-copy!` と、バイトベクタの `bytevector-u8-set!` `bytevector-copy!` が `requireMutable` を呼ぶ。テストは `tests/scheme/0285` から `0288`。ほかのテストは `tests/scheme/0260-literal-constants.txt` と `0261-string-constants.txt`
- [x] `!` で終わる手続きの一覧(runtime.md の「リテラルの不変性」の12個)を、検査にかける。スライス 3l が入れた: `tools/test-scheme` のランナーが、`tests/r7rs-required` の `!` で終わる名前(`set!` を除く)のうち束縛済みのものに、定数に書き込む呼び出しの表(`mutators`)があることと、その呼び出しが定数への書き込みを断ることを、`zig build test-scheme` のたびに検査する。表にない名前が束縛されると失敗する。文章の一覧と原文の抽出の一致を見る検査は、[ADR-0026](adr/0026-verify-facts-about-code-not-prose.md) の線引きに合わないので、束縛済みの手続きがコードの事実として定数を断ることを見る。`read-bytevector!` は段階5で束縛されたとき、表に足さないと失敗する。`list-set!` は Scheme で書いてあるため、断るのは内部の `set-car!` である(表の `refused_by`)
- [x] EOF の値、バイトベクタと約束の値(文字の値はスライス 1h で入った。EOF の値と約束の値はスライス 3f で、バイトベクタはスライス 3e で入った)。3e が入れた: ヒープの型 `Bytevector`(`#u8(...)` のリーダと印字、`equal?`、不変の印の対象)、`bytevector?` `make-bytevector` `bytevector` `bytevector-length` `bytevector-u8-ref` `bytevector-u8-set!` `bytevector-copy` `bytevector-copy!` `bytevector-append` `utf8->string` `string->utf8`。テストは `tests/scheme/0280` から `0284`、`tests/scheme-slow/0023-bytevector-vector-scale.txt`
- [x] 派生構文を `lib/sucheme/derived.scm` に `syntax-rules` で定義。仕組みと `when` `unless` はスライス 3a、`cond` `case` `and` `or` `let`(名前つきを含む)`let*` `letrec` `letrec*` `do` `quasiquote` はスライス 3h で入れた(テストは `tests/scheme/0241-derived-cond.txt` から `0248-derived-scale-small.txt` と `tests/scheme-slow/0021-derived-scale.txt`)。`define-record-type` `let-values` `let*-values` `define-values` `guard` `case-lambda` はスライス 3i で入れた(テストは `tests/scheme/0270-define-record-type.txt` から `0277-derived-scale-small.txt` と `tests/scheme-slow/0022-derived-scale-2.txt`)。`delay` と `delay-force` はスライス 3j で入れた(テストは `tests/scheme/0291-delay.txt`)。`delay-force` は R7RS 7.3 の定義どおり `%make-promise` に展開し、連鎖が一定の空間で終わることは 3f の `force` が保つ
- [x] リストと文字列とベクタの高階手続きを Scheme で実装。リストの `map` `for-each` はスライス 3g、`vector-map` `vector-for-each` `string-map` `string-for-each` はスライス 3j で入れた(`lib/sucheme/procedures.scm`。テストは `tests/scheme/0290-vector-string-higher-order.txt` と `tests/scheme-slow/0024-higher-order-and-delay-scale.txt`)。`vector-map` は専用のベクタに書いてから複製して返し、継続の再入で前の結果が書き換わらない。文字列の手続きは、リストに直して `map` と `for-each` に渡す
- [x] `(scheme base)` の骨格、`(scheme case-lambda)`、`(scheme cxr)`、`(scheme lazy)`。スライス 3k で `lib/scheme/` に入れた(テストは `tests/scheme/0292-scheme-libraries.txt`)。`(scheme base)` は実装のある必須識別子だけをエクスポートする。REPL の初期環境の切り替えは次の項目(3l)で行う
- [x] Web UI にサンプルと共有リンク(スライス 3n。サンプル6個と、URL フラグメントの共有リンク。リンクを開いても自動では実行しない。仕様の4点は、ユーザーが 2026-10-19 に承認した。[design/platform-and-web.md](design/platform-and-web.md) の「段階ごとの範囲」)
- [x] 本体の先頭の `include` と `cond-expand` が持つ定義を、定義の並びとして展開する(R7RS 7.1.3、7.1.6、5.3.2、4.1.7、4.2.1)。本体の先頭の `begin`(定義を含むもの、空の `(begin)` を含む)は、スライス 3i が展開するようにした(`define-record-type` と `define-values` が本体で使えるために必要だった)。残りは、スライス 3p に割り当てた([plans/0016-phase3-scheme-stdlib.md](plans/0016-phase3-scheme-stdlib.md)) (スライス 3p-1。`(lambda () (cond-expand (r7rs (define x 1))) x)` と、定義を含むファイルの本体の先頭の `include` が動く。テストは `tests/scheme/0310-body-definitions.txt` と `src/sucheme.zig` の単体テスト)
- [x] ライブラリの表と `import` の作業領域を、ヒープの上限に計上するか、表を共有する形にする。今は、ライブラリごとのトップレベルの環境の表(インポートした名前の全部を持つ)が永続アリーナにあり、失敗した定義の表も残るので、約 100 KB の入力で上限(256 MiB)を超えるメモリを使いうる。入れ子の `prefix` の `import` も、1 行の中で計上されない量を確保する。2n のファイルの読み取りでは、リーダの作業領域も計上されない(上限は `max_file_bytes` の 1 MiB に下げて抑えた)。結果は正しい。ユーザーが 2026-10-15 に、2m では直さず、受け入れた制約として扱うと判断した。直す時期は、段階3のコアIRと構文環境を GC ヒープに移すスライスと同時に決める([design/open-questions.md](design/open-questions.md) の「ライブラリの表と `import` の作業領域が、ヒープの上限の外にある」)。スライス 3o に割り当てた([plans/0016-phase3-scheme-stdlib.md](plans/0016-phase3-scheme-stdlib.md))。2026-10-20 に、表の複製を残して計上する案に決まった([ADR-0040](adr/0040-core-ir-in-the-gc-heap.md))。表と `import` の作業領域の計上は 3o-1、失敗した定義の表を手放すのは 3o-4 である([plans/0023-slice-3o-ir-to-gc-heap.md](plans/0023-slice-3o-ir-to-gc-heap.md))。3o-1 と 3o-4 で、この2つは済んだ。残るのは、リーダの作業領域である([design/open-questions.md](design/open-questions.md) の同じ行)。2026-10-23 に、リーダの作業領域の計上は段階5へ送った(ユーザーが承認した。段階5の節の項目)
- [x] マクロの展開の有界化の残り。(1) 入れ子の `lambda` を重ねる止まらないマクロは、構文環境の探索が深さに比例して重くなり、時間で終わらない(例: `(define-syntax f (syntax-rules () ((_) (lambda () (f)))))` の `(f)`)。環境の探索を深さに依存しない形にするか、展開の深さの上限を置く。(2) 失敗した展開の節点は行をまたいで残り、失敗を繰り返すと上限の外のメモリが増える。節点を GC ヒープへ移すときに外れる。経緯は [ADR-0031](adr/0031-gc-at-machine-step-boundaries.md) の 2026-10-14 のスライス 2l の追記にある。(1) はスライス 3p、(2) はスライス 3o に割り当てた([plans/0016-phase3-scheme-stdlib.md](plans/0016-phase3-scheme-stdlib.md))。(2) はスライス 3o-3 で外れた(失敗した展開の節点は次の GC で回収される。テストは `src/syntax/expand.zig` の単体テスト)。(1) はスライス 3p-2 で、展開器が作る構文環境の入れ子の深さ(環境の鎖の長さ)に上限(`src/syntax/expand.zig` の `max_depth`)を置き、超えたら実装制限の誤りにした。`lambda` の入れ子と、rib を持たない `let-syntax` の入れ子の両方を数える。例の `(f)` と、`let-syntax` を重ねる同じ形は、ReleaseSafe でどちらも約1秒で終わる(テストは `tests/scheme/0311-expansion-depth.txt`、`tests/scheme-slow/0025-expansion-depth-scale.txt`、`src/syntax/expand.zig` の単体テスト)
- [x] `let-syntax` と `letrec-syntax` の本体に `define` と `define-syntax` を置けるようにする(R7RS 4.3.1 の本体は定義を許す)。スライス 3p に割り当てた([plans/0016-phase3-scheme-stdlib.md](plans/0016-phase3-scheme-stdlib.md)) (スライス 3p-1。本体は自分の有効範囲を持ち、定義は本体の局所変数になる。外側の並びには繋ぎ込まない。[design/frontend.md](design/frontend.md) の展開器の節)
- [x] 整数の手続き(R7RS 6.2.6)のうち、数値塔を要らない `abs` `even?` `odd?` `zero?` `positive?` `negative?` `square` `gcd` `lcm` `floor/` `floor-quotient` `floor-remainder` `truncate/` `truncate-quotient` `truncate-remainder` を、Scheme の手続きとして `(scheme base)` に入れる。計画書 0016 の合意を求める点の2で段階3に入れると決まったが、スライスに割り当てられないまま残っていたので、2026-10-23 にスライス 3s に割り当てた([plans/0016-phase3-scheme-stdlib.md](plans/0016-phase3-scheme-stdlib.md)) (スライス 3s。`lib/sucheme/procedures.scm` に、`quotient` `remainder` `modulo` と比較の上に書いた。テストは `tests/scheme/0330-integer-procedures.txt`。不正確な数の扱いは段階4で足す)
- [x] REPL で解決した名前ごとに残る未束縛のセルの回収(または数の上限)。トップレベルで解決した未知の名前は、実行されなくても REPL 自身の未束縛のセルになり、GC ヒープの上限に計上され続ける([design/open-questions.md](design/open-questions.md))。スライス 3o に割り当てた([plans/0016-phase3-scheme-stdlib.md](plans/0016-phase3-scheme-stdlib.md)) (スライス 3o-5。トップレベルの表は、値の無い自分のセルを弱く持ち、コードが指していないものは GC の掃除の前に表から外れる。定義の途中のライブラリの表だけは、本体の終わりの未束縛の検査のために強く持つ。[plans/0023-slice-3o-ir-to-gc-heap.md](plans/0023-slice-3o-ir-to-gc-heap.md))
- [x] 準拠マトリクスの入力に、`lib/` のエクスポート節を足す。`lib/` のエクスポート節が実在するこの段階で入れる。段階1の最小版は、`tests/r7rs-required` の識別子をインタプリタが束縛しているかだけを見ている (スライス 3l。準拠マトリクスの入力を `lib/` のエクスポートに替えた。[plans/0016-phase3-scheme-stdlib.md](plans/0016-phase3-scheme-stdlib.md) の進捗の 3l の行)
- [x] `equal?` の循環したデータでの停止と、共有構造(同じ部分を何度も指すデータ)で比較回数が深さに対して指数に増える問題への対応(訪問済みの集合)。循環は、データの変更(`set-car!` など)が入ると作れるので、その最初のスライスと同時に要る。共有構造での指数時間は、変更が無くても Scheme から作れる(再現入力は計画書 0010 の `equal?` の注に書いた)。段階1では、この既知の制約を受け入れた(ユーザーが 2026-10-12 に判断した)。`src/prim/equiv.zig` の `isEqual` の doc コメントが参照している。スライス 3b に割り当てた([plans/0016-phase3-scheme-stdlib.md](plans/0016-phase3-scheme-stdlib.md))(3b が訪問済みの集合を入れた: 番地の union-find で、循環したデータで止まり、共有構造の比較は節点の数に比例する時間で終わる。集合の確保はヒープの上限に計上する。テストは `tests/scheme/0211-equal-circular.txt`、`0212-equal-shared.txt`、`tests/scheme-slow/0018-equal-scale.txt`。3b の他の項目が終わるまで、チェックは入れない)。3b はマージ済みで(suchi/sucheme-zig#110)、`equal?` の項目はこれで済んだ。3b の複数値の項目に残るものは、その項目に書いてある
- [x] ファイルの実行(`sucheme prog.scm`)。R7RS 5.1 のプログラムは `import` で始まるので、`(scheme base)` ができてから入れる([plans/0014-phase2-core-language.md](plans/0014-phase2-core-language.md) の合意を求める点の6)。スライス 3m が入れた: `sucheme [-I <dir>]... <file>` が、REPL と同じ初期環境でファイルの式を先頭から評価する。式の値は出さない(`display` は段階5)。実行時エラーは stderr に `error: ...` を出して終了ステータス 1、読めないファイルは 66、ファイルの後ろの引数は 64(プログラムへの引数は段階5)。`import` で始まらないプログラムも動く。標準入力のプログラム(`-`)は 69 のまま。ユーザーが 2026-10-19 に、この3点の仕様を承認した。テストは `src/main.zig` の単体テスト
- [x] シンボル表を弱い表にする。`string->symbol` が入るスライスで、シンボルの操作と同時に決める([plans/0014-phase2-core-language.md](plans/0014-phase2-core-language.md) の合意を求める点の5) (スライス 3c。3c が入れた: 表を `Heap` が持ち、マークが出会った ID に印を立て、スイープが印も固定も無い名前を、索引の削除、名前の解放、ID の再利用の順で手放す。名前の長さに比例する量は上限に計上する。GC が辿らない生の ID の所有者は、ルートに挙げた(束縛の表のキー、コードの定数のシンボル、局所変数の節点の名前、保留中のエクスポートの名前)。コアIRの節点がヒープに移るまで、節点の名前は `Context.code_roots` が持つ。テストは `src/symbol.zig`、`src/heap.zig`、`src/sucheme.zig` の単体テストと `tests/scheme/0220-string-symbol.txt`)
- [x] コアIRを GC ヒープに移し、`Context.code_roots` を要らなくする([plans/0014-phase2-core-language.md](plans/0014-phase2-core-language.md) の合意を求める点の5)。スライス 3c が、弱いシンボル表のために、シンボルの定数と局所の名前と保留中のエクスポート名を `code_roots` に挙げる項目を足した(セッションの終わりまで残る)。ヒープへ移すときに、まとめて外す([design/runtime.md](design/runtime.md) のインターン表の節) (スライス 3o-3。節点を `heap_types` に移し、機械のルートに制御を足し、`code_roots` を外した。保留中のエクスポート名はレジストリの `pending_names` が持つ。深いコードのマークが2乗に伸びないよう、マークのワークリストを満杯のときに伸ばす形にした。[ADR-0040](adr/0040-core-ir-in-the-gc-heap.md)、[plans/0023-slice-3o-ir-to-gc-heap.md](plans/0023-slice-3o-ir-to-gc-heap.md))
- [x] `(sucheme core)` を利用者から隠し、REPL の初期環境を `(scheme base)` などに替える(スライス 3l。[ADR-0039](adr/0039-standard-environment-installed-at-init.md)。標準環境の読み込みはヒープの上限に計上するので、小さすぎる上限は WASM で -7 になる)。段階2に書いた `(import (sucheme core))` を含むテストを書き換える。v0.2.0 のノートはこの名前の取り消しに触れていないので、段階3のリリースのノートに取り消しを書く([ADR-0037](adr/0037-core-library-exposed-in-stage-2.md) の 2026-10-15 の追記、[plans/0014-phase2-core-language.md](plans/0014-phase2-core-language.md) の合意を求める点の3)
- [x] `apply` の周回を、ステップの境目を通る形にする([ADR-0031](adr/0031-gc-at-machine-step-boundaries.md) の 2026-10-13 の追記)。今は、`apply` が並べ直した引数の鎖と、`apply` で `apply` を呼ぶ入れ子の周回が、1ステップの中で確保され、その間は GC が走らない。`set-car!` などが入る最初のスライスまでに要る。自分を指す引数のリストで、1ステップの中で終わらない周回が作れるようになるためである (スライス 3b。3b が入れた: 並べ直しを継続のフレーム `Kont.Step.spread` に持たせ、周回のたびに境目を通す。並べる量も、一定の個数ずつのステップに分ける。ルートの一覧は変わらない。テストは `src/machine.zig` の単体テストと `tests/scheme/0213-apply-rounds.txt`、`0214-apply-circular-arguments.txt`、`0217-apply-values-scale-small.txt`、`tests/scheme-slow/0019-apply-values-scale.txt`。リストの前の引数と余りを受けるクロージャの余りの引数のリストは、個数に比例する確保が1ステップに残る。下の複数値の項と同じ扱いで、ADR-0031 の 2026-10-15 の追記(3)に書いた)
- [x] 複数値の確保(`values` と継続の多値での起動の `Machine.valuesOf`、`call-with-values` の `Machine.receiverCall`)を、個数に比例する量を1ステップの中で確保しない形にする([ADR-0031](adr/0031-gc-at-machine-step-boundaries.md) の 2026-10-14 の追記のスライス 2f の項)。上の `apply` の項と同じ直し方で、同じスライスで扱える (スライス 3b。3b が入れた: `call-with-values` の受け手の引数の鎖を、複数値のオブジェクトが届いたとき、`apply` と同じフレームで一定の個数ずつ並べる。テストは `tests/scheme/0215-values-many.txt`、`0216-values-continuation.txt`、`0217-apply-values-scale-small.txt`、`tests/scheme-slow/0019-apply-values-scale.txt`。残り: `Machine.valuesOf` が作る複数値のオブジェクトの本体は、個数に比例するペイロード1つで、ステップに分けられない。確保の前に必要な量を境目で確かめる形か、表現の変更が要るので、ユーザーに諮る。3d から 3f の、入力に比例して確保するプリミティブと同じ種類である。そのため、チェックは入れない)。2026-10-23 に、残りのペイロードの扱いを段階6へ送った(ユーザーが承認した。ユーザーに諮る点は、これで済んだ。段階6の節の項目)

完了条件: `(scheme base)` のエクスポート一覧が揃い、未実装の識別子が準拠マトリクスに正しく表れる。衛生性の検証項目のうち `cond` のリテラル `else` の項目が通る。[design/runtime.md](design/runtime.md) の事例のうち、段階2で入力を書けなかったもの(容量0で `string->symbol` が成立し続ける事例と、`let` と `when` を使う複数値の事例の元の形)が通る。リリース v0.3.0 を出す。

この段階で未実装として表れてよいのは、後の段階の機能を必要とする識別子である。数値塔を必要とするもの(`/` `exact` `inexact` `sqrt` など)は段階4、ポートを引数に取るか返すもの(`read-char` `write-string` `open-input-string` など)は段階5である。どの族にも属さず後の段階にも割り当てられない識別子が残っていれば、それは [ADR-0006](adr/0006-library-system-and-scheme-level-stdlib.md) の族の一覧の漏れである。

残していること: [design/open-questions.md](design/open-questions.md) の「段階3までに決める」の行。件数と内容をここに複製しない。

### 段階4: 数値塔とUnicode

- [x] 浮動小数点数、bignum、ratnum、compnum(スライス 4d・4e・4f・4i。`eqv?` と `equal?` の値による比較は 4j)
- [x] `number->string` と `string->number` の全範囲(スライス 4a・4b・4e・4g-4。リーダの数の綴りは 4r)
- [x] リーダに基数接頭辞、正確性接頭辞、分数、小数、指数、`+inf.0` 系、複素数を追加(スライス 4r)
- [x] リーダが ASCII でない文字の識別子を読み、畳み込む読み手の畳み込みに Unicode の表を使う(スライス 4u4。テストは `tests/scheme/0740-unicode-identifiers.txt` と `tests/scheme/0741-unicode-fold-case.txt`。[plans/0014-phase2-core-language.md](plans/0014-phase2-core-language.md) の合意を求める点の8)。`full-unicode` フィーチャも 4u4 で足した
- [x] Unicode テーブルの生成ツールと生成結果(スライス 4u1・4u2。`tools/unicode-gen/`、`src/unicode/`。`zig build check-unicode` は、全コミットの検査に入れた)
- [x] `(scheme inexact)`(スライス 4h。12個の識別子が束縛される。テストは `tests/scheme/0460-inexact.txt`)
- [x] `(scheme complex)`(スライス 4i。6個の識別子が束縛される。テストは `tests/scheme/0470-complex.txt`)
- [x] `(scheme char)`(スライス 4u3。22個の識別子が束縛される。テストは `tests/scheme/0700-char-procedures.txt` と `tests/scheme/0720-string-case.txt`)
- [x] (スライス 4j。テストは `tests/scheme/0480-eq-eqv.txt`)`eq?` と `eqv?` が別の関数になるとき(浮動小数点数と bignum が入るとき)、`lib/sucheme/procedures.scm` の `memq` と `memv`、`assq` と `assv` の区別を固定するテストを足す。今は `eq?` と `eqv?` が同じ関数なので、入れ替えるミューテーションを検出するテストが書けない(スライス 3g のレビューの指摘)

完了条件: `exact-closed` `ratios` `exact-complex` `ieee-float` のフィーチャを真にできる。浮動小数点数のラウンドトリップ性テストが通る。リリース v0.4.0 を出す。

`full-unicode` は、Unicode テーブルを入れた場合に真になる。WASM のサイズが許容できず文字レパートリを ASCII に制限する退避案を採る場合は偽のままになる。判断は実測で行い、採る場合はユーザーの承認を得て ADR を書く(退避案は採らず、4u4 で `full-unicode` を真にした。表の大きさの許容基準は [design/open-questions.md](design/open-questions.md) の段階8の行)。したがって `full-unicode` を完了条件に含めない。

残していること: [design/open-questions.md](design/open-questions.md) の「段階4までに決める」の行は、いまは残っていない。Unicode の表の大きさの許容基準は、段階4の完了のとき(スライス 4z)に、同じファイルの「段階8までに決める」へ送った。段階4のスライスの後に残った、直していないものは、段階6の作業項目に「スライス未割り当て」として置いた。

### 段階5: ポートと入出力

- [x] テキストポートとバイナリポート、文字列ポート、バイトベクタポート、ファイルポート([plans/0019-phase5-ports-and-io.md](plans/0019-phase5-ports-and-io.md) の 5g、5h、5i、5k。ポートの型の骨格は 5g で入れた)
- [x] 第2類(利用者プログラムのファイル入出力)の経路を同じリゾルバに通す。探索ルートの制約はかけず、失敗は `file-error` で報告する。スライス 5k([design/frontend.md](design/frontend.md) の「現状(スライス 5k)」)
- [x] リーダの完全化(データラベル、ブロックコメント、`#;`、縦棒識別子、`#!fold-case` と `#!no-fold-case` ディレクティブ、文字列の行継続)。`#u8` と16進エスケープは、段階3までに入った([plans/0019-phase5-ports-and-io.md](plans/0019-phase5-ports-and-io.md) の 5a から 5c。3つともマージ済み)
- [x] リーダの位置情報の副表([design/frontend.md](design/frontend.md) の位置情報)。リーダの完全化と同じ段階に置く([plans/0014-phase2-core-language.md](plans/0014-phase2-core-language.md))。スライス 5d([plans/0019-phase5-ports-and-io.md](plans/0019-phase5-ports-and-io.md))。展開時の誤りに、ファイルと行と桁を前置する
- [x] 位置情報の残り(1): ライブラリのファイルと、ライブラリの宣言(`include` など)が読むファイルの位置の記録([design/frontend.md](design/frontend.md) の「現状(スライス 5d)」)。スライス 5s([plans/0019-phase5-ports-and-io.md](plans/0019-phase5-ports-and-io.md) の「位置情報の残りの割り当て」)
- [x] `write` と `write-shared` と `write-simple`(循環構造のデータラベル)。スライス 5j([plans/0019-phase5-ports-and-io.md](plans/0019-phase5-ports-and-io.md))
- [x] 機械操作プリミティブの残り(`eval` `exit`)と `eval` 用の環境の値。`eval` が入るときに、`Expander.constant` が EOF の値と約束を定数として扱う分岐(`src/syntax/expand.zig`)を、Scheme から通すテストを足す(3f のレビューで、Scheme のソースにこれらの値が入る経路が無いため、この分岐を壊してもテストが落ちないと分かった)。スライス 5m(`exit`)と 5o(`eval`、環境の値、`tests/scheme/0680-eval.txt` の定数の分岐のテスト)
- [x] `(scheme file)` `(scheme read)` `(scheme write)` `(scheme load)` `(scheme eval)` `(scheme repl)` `(scheme process-context)` `(scheme time)` `(scheme r5rs)`。スライス 5i から 5q([plans/0019-phase5-ports-and-io.md](plans/0019-phase5-ports-and-io.md))。`(scheme load)` は 5p、`(scheme r5rs)` は 5q
- [x] ネイティブの `current-error-port` を、標準出力と分けて標準エラーに書く。5i では、標準出力と同じ書き先に書く(既知の制限。[plans/0019-phase5-ports-and-io.md](plans/0019-phase5-ports-and-io.md) の 5i の中身)。WASM は段階5では分けない(同じ計画書の「ホスト側のインポートの設計」)。スライス 5t(`Interpreter` の `console_err` の欄と `Console.error_sink`。同じ計画書の「5t で決めたこと」。テストは `src/main.zig` と `src/prim/port.zig` の単体テスト)

完了条件: 循環リストの `write` がデータラベル付きで出力される。`#!fold-case` ディレクティブが入力の途中で有効になる。衛生性の検証項目のうち循環データの `quote` の項目が通る。[design/runtime.md](design/runtime.md) の例外の節の事例12(`exit` と `dynamic-wind`)が通る。R7RS 付録Aのライブラリすべてが読み込める。リリース v0.5.0 を出す。

残していること: [design/open-questions.md](design/open-questions.md) の「段階5までに決める」の行。件数と内容をここに複製しない。

### 段階6: 準拠検証

- [x] `(chibi test)` 互換の最小実装
- [x] `r7rs-tests.scm` の取り込みと実行
- [x] 準拠マトリクスに、準拠スイート(`r7rs-tests.scm`)の結果の表を足す。`(scheme r5rs)` の再エクスポートによる識別子の重複は、この表を足すときに解く(スライス 6f。結果は節ごとに出るので、列でなく別の表にした。重複は、表を分けずに注記で示すと決めた)
- [x] ファジングの入力コーパスの拡充と、見つかった不具合の解消([計画書 0025](plans/0025-fuzzing-the-evaluator.md)。スライス 6i-1 から 6i-3。評価器の対象を足し、リーダの初期入力を拡充した。6i-2 の手元の実行と `fuzz.yml` の手動起動では、失敗する入力は見つからなかった)
- [ ] パラメータの読み出しは、動的点の列の長さに比例して遅くなる(毎段、別のパラメータを `parameterize` する深い再帰で、束縛していないパラメータを読むと、深さの2乗になる)。結果は正しく、メモリは有界である。パラメータごとの束縛の索引を持つかどうかは、実際のプログラムで読み出しが支配的になったときに決める([design/open-questions.md](design/open-questions.md) の「パラメータの読み出しの費用」)。受け入れた制約として残している([plans/0016-phase3-scheme-stdlib.md](plans/0016-phase3-scheme-stdlib.md) の合意を求める点の6。ユーザーが 2026-10-16 に承認した)。段階3から送った(2026-10-23 にユーザーが承認した)。準拠テストの後の性能の見直しと同じ時期に見る。段階6の外へ送った。送り先は [design/open-questions.md](design/open-questions.md) の「パラメータの読み出しの費用」の行(段階を定めない保留)で、受け入れた制約のまま残す(2026-11-04 にユーザーが承認した。[計画書 0028](plans/0028-phase6-conformance.md) の「未割り当ての項目の行き先」)
- [x] 複数値のオブジェクトの本体(`Machine.valuesOf` が作る、個数に比例するペイロード)を、1ステップの中で個数に比例する量を確保しない形にする。確保の前に必要な量を境目で確かめる形か、表現の変更が要る。確かめる形で閉じた(スライス 6o)([ADR-0031](adr/0031-gc-at-machine-step-boundaries.md) の 2026-10-15 の追記(3))。段階3のスライス 3b が `call-with-values` の受け手の並べ方を直した残りである。段階3から送った(2026-10-23 にユーザーが承認した)。スライス 6o に割り当てた(2026-11-04 に合意。[計画書 0028](plans/0028-phase6-conformance.md) の「未割り当ての項目の行き先」)
- [ ] マクロが導入したトップレベルの `define` と `define-syntax` を、衛生的にする。今は、名前が別名なら、元のシンボルの名前を REPL の表に束縛するので、マクロが導入したトップレベルの定義が、利用側の同じ綴りのトップレベルの変数を書き換える(例は [design/frontend.md](design/frontend.md) の解決規則の節)。v0.2.0 に既知の制限として入れた(ユーザーが 2026-10-15 に判断した)。経緯は [design/open-questions.md](design/open-questions.md) の「マクロが導入した名前のトップレベルの定義」の行にある。段階3でスライス 3q に割り当てたが、2026-10-22 に段階6へ送った(ユーザーが判断した。[plans/0016-phase3-scheme-stdlib.md](plans/0016-phase3-scheme-stdlib.md) の合意を求める点の5)。v0.3.0 にも既知の制限として入れ、リリースノートに書く(スライス 3r)。衛生的にするには、識別子の解決の最終段の前に、トップレベルの表を別名そのもので引く段を足すことになり、[ADR-0019](adr/0019-denotations-and-identifier-resolution.md) の解決規則を変える。計画書 0016 の「範囲を狭める線」は、この場合に段階6へ送ると定めていた。R7RS 4.3 は、トップレベルの変数の定義が束縛を導入するかどうかを、実装に委ねている(原文で確かめた)。段階6の準拠検証で必要になったときに、新しい ADR とともに直す。段階6では直さず、v1.0.0 にも既知の制限として入れる。段階6の外へ送り、[design/open-questions.md](design/open-questions.md) の「マクロが導入した名前のトップレベルの定義」の行(段階を定めない保留)へ寄せた(2026-11-04 にユーザーが承認した。[計画書 0028](plans/0028-phase6-conformance.md) の「未割り当ての項目の行き先」)
- [x] `environment`(と `scheme-report-environment`、`null-environment`)を繰り返し呼んでも、常駐のメモリが一定に収まるようにする。以前は繰り返し呼ぶと常駐のメモリが伸び、ヒープの上限で止まらなかった(5q の独立査読で見つかった)。査読の推測(表が圧力に数えられていない)は、5u の着手時の確認で外れた。計上は一定で、伸びは `smp_allocator` を裏にしたときの RSS の伸びである(機序の仮説は未確認。事実と実験は計画書 0019 の同じ節にある)。`Heap.residentAllocator` の 4096 バイト以上の確保を `page_allocator` に回して直した(スライス 5u の PR。マージで完了)。スライス 5u に割り当てた([plans/0019-phase5-ports-and-io.md](plans/0019-phase5-ports-and-io.md) の「環境の表の GC の圧力の割り当て」)。段階5の作業項目に置いていたが、2026-11-02 に v0.5.0 の前提から外して v0.5.0 の後に送ったので、ここに移した(スライス 5t の PR)。v0.4.0 と v0.5.0 のリリースノートに、既知の制限として書く。[計画書 0028](plans/0028-phase6-conformance.md) で、5u のまま v1.0.0 の前提に入れた(2026-11-04 に合意)
- [x] プリンタが、リーダの読める ASCII でない識別子(`λ` など)を縦棒なしで書く。いまは縦棒で囲んで書き、読み戻すと同じシンボルになる。`src/printer.zig` の判定を、リーダの `readsAsIdentifier` に替える形になる([plans/0018-phase4-numeric-tower-unicode.md](plans/0018-phase4-numeric-tower-unicode.md) の「次にやること」の、4u4 のあとに残るもの(1))。段階4の完了のとき(スライス 4z)に段階6へ置いた。スライス 6q に割り当てた(2026-11-04 に合意。[計画書 0028](plans/0028-phase6-conformance.md) の「未割り当ての項目の行き先」)
- [x] `#!fold-case` の畳み込みを、R7RS 2.1 の文言どおりの完全な畳み込みにするかを決める。いまは単純な畳み込みで、`ß` が残る(2026-10-31 に、単純な畳み込みのままにすると決めた。同じ計画書の 4u4 の行)。準拠検証で必要になったときに直す。段階4の完了のとき(スライス 4z)に段階6へ置いた。決めたこと: 2026-10-31 の決定(単純な畳み込み)を正とし、完全な畳み込みにはしない(2026-11-04 にユーザーが承認した。[計画書 0028](plans/0028-phase6-conformance.md) の「未割り当ての項目の行き先」)
- [x] `src/num/power.zig` の `exptComplexByFloat` の `!std.math.isFinite(y)` のガードは、前の2つの条件のために到達しない。外して簡素にする(同じ計画書の「次にやること」の、複素数のテスト強化のミューテーション査読の記録(1))。段階4の完了のとき(スライス 4z)に段階6へ置いた。スライス 6l に含め、6l で外した(2026-11-04 に合意。[計画書 0028](plans/0028-phase6-conformance.md) の「未割り当ての項目の行き先」)
- [ ] 位置情報の残り(2): コアIRの節点への位置の複写と、実行時の誤りへの位置の表示。L7 の「エラー位置の表示」の計画書で割り当てる([plans/0017-parallel-lanes.md](plans/0017-parallel-lanes.md))。段階5の作業項目に置いていたが、段階5の完了のとき(スライス 5r)にここへ移した。v0.5.0 のリリースノートに、既知の制限として書く。段階8へ送った。L7 の「エラー位置の表示」の計画書で割り当てる(2026-11-04 にユーザーが承認した。[計画書 0028](plans/0028-phase6-conformance.md) の「未割り当ての項目の行き先」)
- [x] ファイルを読むときのリーダの作業領域(未閉じの括弧ごとの枠)を、ヒープの上限に計上する。今は計上の外にあり、ファイルの大きさの上限(`max_file_bytes` の 1 MiB)で最悪の場合を抑えている([design/open-questions.md](design/open-questions.md) の「ライブラリの表と `import` の作業領域が、ヒープの上限の外にある」)。段階3から送った(2026-10-23 にユーザーが承認した)。段階5の完了のとき(スライス 5r)に、段階5からここへ移した。スライス 6p に割り当てた(2026-11-04 に合意。[計画書 0028](plans/0028-phase6-conformance.md) の「未割り当ての項目の行き先」)
- [x] REPL のソースの読み取りに、`#!fold-case` の状態を残す。`Interpreter` が畳み込みの状態を持ち、`evalPrint` のたびに `Reader` へ渡して書き戻す形になる。今は `evalPrint` が呼び出しごとに新しい `Reader` を作るので、REPL では、ディレクティブが次の行に効かない(1回の `evalPrint` で全体を読むファイルの実行では効く)。R7RS 2.1 は、ディレクティブが同じポートから読む後続のデータに効くとする。計画書 0019 の 5a の行は、入力をまたいで残すのを 5i と 5l に予定していたが、5l は `read` のポートだけに入れ、REPL のソースの読み取りは、どのスライスにも割り当てられていなかった。段階5の完了の監査(スライス 5r)で見つかった。v0.5.0 のリリースノートに、既知の制限として書く。スライス 6r に割り当てた(2026-11-04 に合意。[計画書 0028](plans/0028-phase6-conformance.md) の「未割り当ての項目の行き先」)
- [x] 不合格項目の issue 化と解消(issue 化はスライス 6g で済んだ。レーンごとの issue は [計画書 0020](plans/0020-conformance-harness-early.md) の進捗の表にある。解消は各レーンで行う。残りの解消は [計画書 0028](plans/0028-phase6-conformance.md) のスライス 6j から 6n)
- [x] `tests/vendor/README.md` の作成。[ADR-0013](adr/0013-testing-strategy-and-conformance-suite.md) の記録項目に加えて、`LICENSE` がこのディレクトリを覆わないことを明記する([ADR-0022](adr/0022-unlicensed-proprietary.md))
- [x] BSD 3条項の第3条項(名前の宣伝利用)について、出典として述べることと推奨として用いることの線を引く新ADRの作成([ADR-0022](adr/0022-unlicensed-proprietary.md))。記録形式が2つ併存することを定める件も同じ ADR で扱う。[ADR-0041](adr/0041-bsd-name-clause-attribution-not-endorsement.md) で決めた

完了条件: 準拠マトリクスに `r7rs-tests.scm` の結果の表があり、その不合格項目がゼロか、残りすべてに根拠が記録されている。リリース v1.0.0 を出す。[ADR-0010](adr/0010-ci-cd-and-release-strategy.md) が「段階ごとにマイナーバージョンを上げる」としているが、R7RS 準拠の達成を v1.0.0 とする規則が優先する。

残していること: [design/open-questions.md](design/open-questions.md) の「段階を定めずに保留しているもの」のうち、性能測定を根拠にする行。

### 段階7: REPLの編集機能

- [ ] 行編集の実装方式の決定(選択肢とトレードオフを提示して判断を得る)
- [ ] Emacs バインディング、複数行編集、履歴、括弧の対応表示、補完
- [ ] REPL の継続行の判定を、保留を毎行読み直す方式から、読み取りの状態を保って続きから読む方式(差分読み取り)に替える。スライス 1l が入れる判定は、継続のたびに保留の全体を読み直すので、費用が保留の大きさの2乗に比例する。ユーザーは保留の上限(64 KiB)を下げず、この制約を受け入れた。再現の仕方: 閉じ忘れの `define` を1つ含み、正しい `define` を多数並べた、上限(64 KiB)に近い入力を REPL に貼り、所要時間を測る。Debug ビルドでは数分かかり、ReleaseSafe でも待たされる。数値は環境で変わるので、ここには書かない。この項目に着手するときに測り直す (スライス未割り当て)

完了条件: 要件どおりの編集操作ができる。リリース v1.1.0 を出す。

残していること: [design/open-questions.md](design/open-questions.md) の「段階7までに決める」の行。件数と内容をここに複製しない。

### 段階8: Web UIの本格化

- [ ] `read` による対話
- [ ] エラー位置の表示と処理の中断。段階6から、位置情報の残り(2)(コアIRの節点への位置の複写と、実行時の誤りへの位置の表示)を送った(2026-11-04 にユーザーが承認した。[計画書 0028](plans/0028-phase6-conformance.md))
- [ ] 編集の補助とサンプルの充実
- [ ] Web UI の配置先の選定と配置([ADR-0021](adr/0021-no-github-pages-defer-hosting.md))。private にアクセス制限でき、静的ファイルを `application/wasm` で配信できるサービスを選ぶ

完了条件: ブラウザで R7RS のサンプルが一通り動く。配置した URL でも動く。リリース v1.2.0 を出す。

残していること: [design/open-questions.md](design/open-questions.md) の「段階8までに決める」の行。件数と内容をここに複製しない。ここが最終段階である。

## 利用者向けの文書(段階をまたぐ)

段階に属さず、レーン L9 で進める。計画は [plans/0027-user-documentation.md](plans/0027-user-documentation.md) が正で、2026-10-29 に合意された。

- [x] 文書のコードブロックを走らせて、期待する出力と比べる検査(`tools/check-examples/`、`zig build check-examples`。計画書の D1。決定は [ADR-0048](adr/0048-run-the-examples-of-the-user-documentation.md))。プログラム集の `.scm` を走らせる部分は D7a で足す
- [x] チュートリアル(Lisp 系の言語が初めての読者向け)。計画書の D2 と D4 と D8(1 から 19 章を書き終えた。`eval` と `load` の章は、計画書の章立てにないので、足すかは計画書の「次にやること」で扱う)
- [x] ユーザーズガイド(実行ファイル、REPL、ファイルの実行、ライブラリ、終了コード、Web UI、既知の制限)。計画書の D3。1 から 7 章を書き、コマンドの例を `console` のブロックで走らせる検査を足した。前提のある内容(REPL の行編集、標準入力のプログラム、Web UI の対話と配置)は、前提のスライスのあとに足す
- [x] リファレンスマニュアル(R7RS の節への索引と、sucheme に固有の項目と例。原文で足りるものは節の参照で済ませる)。計画書の D5 と D6(ライブラリの索引と、索引と輸出を突き合わせる検査、固有の項目として、上限、REPL とコマンドライン、誤りの文面、表示の書式、まだ無い機能、R7RS と食い違う箇所を足した。後のスライスが識別子や機能を足したときは、そのスライスが索引の行と項目を直す)
- [ ] プログラム集(実行ファイルで走らせて確かめる `.scm`。分野ごとの目標の本数は計画書の「プログラム集」の表)と、それを走らせる検査。計画書の D7a と D7b と D8 と D9。D9 で、検査が `-I`、引数、標準入力、一時ディレクトリを扱えるようになり、`define-library` の例とファイルを読み書きする例を足した(設計は計画書の「D9 で決めること」)。残り: 計画書の表の分野ごとの目標の本数に足りているかは、確かめていない

完了条件: 文書の中の Scheme のコードと、プログラム集のすべてが、全コミットの CI で走って期待どおりの出力になる。段階8の完了の時点で、計画書の章と項目がそろっている。

## 横断的に続ける作業

- ドキュメントとコードの整合性チェックを節目ごとに実施する。
- PR は自前の敵対的レビューを実行し、必須の新規指摘ゼロになるまで修正する([ADR-0027](adr/0027-severity-by-consequence-and-a-cost-side-stop.md))。推奨と任意は `docs/review/` に記録して該当する段階の作業項目に回す。手順の正は `AGENTS.md` の「PR・レビュー・マージ」の節である。「この詳細が未規定である」という指摘のうち実装時に決めると判断したものは [design/open-questions.md](design/open-questions.md) に記録して閉じる([ADR-0018](adr/0018-incremental-vertical-slices.md))。
- 技術選択と設計判断、およびレビュー提案をあえて採用しない場合は ADR に記録する。
- 段階の完了時に、確定したことを設計ドキュメントまたはコードのコメントに書き、[design/open-questions.md](design/open-questions.md) から該当する行を消す。
- 1コミット=1論理変更を守る。コミットは節目ごとに作り、push はまとめる(`AGENTS.md` の進め方の「Actions の分数」の規則)。

- [ ] ヒープの上限に届くまでの時間(小さなセルを重ねる入力で 40 秒を超える)の調査と対策。計画書 [0029](plans/0029-heap-limit-slow-exhaustion.md) のスライス H1(再測定と仮説)と H2(内訳の計測)は書いた。残りは H3(対策の実装。案の選択はユーザーの判断で、計画書の「判断を求める点」にある)。Issue は [suchi/sucheme-zig#291](https://github.com/suchi/sucheme-zig/issues/291)

## 未確定の事項

[design/open-questions.md](design/open-questions.md) が正である。決める段階と、何を根拠に決めるかをそこに記録する。このファイルには複製しない。
