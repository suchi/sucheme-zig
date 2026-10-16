# ロードマップと進捗

リポジトリから進捗が読み取れるようにするための単一の表。段階の完了条件を満たしたらチェックを入れ、同じ PR でこのファイルを更新する。

各段階は、リーダからプリンタまでネイティブとブラウザの両方で通しで動く状態を作る([ADR-0018](adr/0018-incremental-vertical-slices.md))。層を1つずつ完成させる進め方は採らない。段階の終わりに「確定したこと」と「残していること」を記録する。

「残していること」の欄は、その段階で決めずに後の段階へ回した事項を指す([design/open-questions.md](design/open-questions.md) の行)。未着手の作業項目のことではない。作業の進み具合は各段階のチェックボックスが正である。

作業範囲の全体は [plans/0001-sow.md](plans/0001-sow.md) にある。設計は [design/](design/) に、決定は [adr/](adr/) に、実装時に決めることは [design/open-questions.md](design/open-questions.md) にある。

## 現在地

| 項目 | 状態 |
| --- | --- |
| 現在の段階 | 段階3(Schemeによる標準ライブラリ)。段階1は v0.1.0 で、段階2は v0.2.0 で完了した(段階1のスライスは [plans/0003-phase1-minimal-slice.md](plans/0003-phase1-minimal-slice.md)、完了の手続きは [plans/0013-stage1-completion.md](plans/0013-stage1-completion.md)。段階2の実装計画と進捗は [plans/0014-phase2-core-language.md](plans/0014-phase2-core-language.md) が正である)。段階3の実装計画は [plans/0016-phase3-scheme-stdlib.md](plans/0016-phase3-scheme-stdlib.md) が合意済みで、スライス 3a から順に実装する。計画書のない段階の実装は始めない([plans/README.md](plans/README.md))。段階の数値は `build.zig` の `current_stage` が正で、上げると `zig build check-docs` が新しい行をCIに要求する |
| 最新リリース | [v0.2.0](https://github.com/suchi/sucheme-zig/releases/tag/v0.2.0)([リリースノート](releases/v0.2.0.md)) |
| 固定 Zig バージョン | `.zigversion` を参照 |
| R7RS 準拠マトリクス | [status/](status/)(段階1の最小版が生成されている。必須の識別子ごとに、インタプリタが束縛しているかだけを見る。`lib/` のエクスポートは段階3、準拠スイートの結果は段階6で足す) |

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
- [x] `fuzz.yml` が失敗した入力を見つけたときに、入力が成果物に上がること(`.zig-cache/f/crash` の場所と `include-hidden-files` の要否を含む)。2026-10-12 に、使い捨てのブランチで欠陥(900 バイトを超える入力で失敗)を仕込んで確かめた。ファジングの手順は終了コード 0 で終わり、`fuzz-crash` の成果物が上がり、検査の手順が失敗してジョブが赤になった([ラン](https://github.com/suchi/sucheme-zig/actions/runs/38252355736)) (スライス 1j-1 のマージ後)
- [x] WASM のエクスポート([design/platform-and-web.md](design/platform-and-web.md) のエクスポート)と Web UI の最小版 (スライス 1i)
- [x] Web UI をローカルで開く手段(`file://` から始まる取得は Fetch の対象外のため、手段は段階1の計画で決める) (スライス 1i)
- [x] aarch64 を自動テストの対象に加えるかの判断と ADR の作成。判断は加えないで、[ADR-0033](adr/0033-aarch64-built-but-not-tested.md) に書いた([ADR-0010](adr/0010-ci-cd-and-release-strategy.md) の追記が見直しの時点をこの段階と定めた。値表現とGCが入り、アライメント・ポインタ幅・エンディアンに依存する判断が初めてコードに現れる) (スライス 1j-2)
- [x] 準拠マトリクスの最小版(`zig build report` が `docs/status/conformance.md` を生成し、`zig build check-report` が生成し直した結果との一致を検査する)。必須の識別子ごとに、インタプリタが束縛しているかだけを見る。計画は [plans/0011-slice-1m-conformance-report-early.md](plans/0011-slice-1m-conformance-report-early.md) (スライス 1m)
- [x] PR で Web UI を確認するための成果物の添付のワークフロー(`preview.yml`)。`sucheme.wasm` と `web/` を並べたディレクトリを、CI が `upload-artifact` で上げる([ADR-0021](adr/0021-no-github-pages-defer-hosting.md) が配置の代わりに定めた手段)。`.github/workflows/` の変更なのでユーザーの承認を得てから行う (スライス 1j-3b)
- [x] 上がった成果物を人が展開し、`node serve.mjs` で開いて `(fact 10)` が動くことの確認。2026-10-12 に、ユーザーが PR #70 の preview の成果物で確かめた (スライス 1j-3b のマージ後)
- [x] リリース成果物の組み立て。`zig build dist` が ADR-0010 の一覧の全ターゲットを `ReleaseSafe` で作り、`tools/release/package.py` がアーカイブと `SHA256SUMS` を作って読み直す。`THIRD-PARTY-NOTICES.txt` と、リリースの形の [ADR-0034](adr/0034-release-shape.md) を含む。`full.yml` の `dist` ジョブがリハーサルとして走らせる。`.github/workflows/` の変更なのでユーザーの承認を得てから行う (スライス 1j-3a)
- [x] `full.yml` の `dist` ジョブが GitHub のランナー上で通ること(`python3` の有無、所要時間、キャッシュの挙動を含む)。PR を ready にしたときの実行と、`main` での手動起動で通った。測定値は [plans/0009-slice-1j-release-v0-1-0.md](plans/0009-slice-1j-release-v0-1-0.md) の「確かめた事実」の表にある (スライス 1j-3a)
- [x] リリースのワークフロー(`release.yml`)を足す。タグの push から、版の確認とスモークテストのあとに、下書きのリリースを作る。`.github/workflows/` の変更なのでユーザーの承認を得てから行う (スライス 1j-3c)
- [x] `release.yml` がタグの push で動き、下書きのリリースができること。最初のタグ v0.1.0 で、全手順が成功し、下書きができた([ラン](https://github.com/suchi/sucheme-zig/actions/runs/38257497672)) (スライス 1j-4 のタグの push)

完了条件: 階乗の定義と呼び出しがネイティブとブラウザの両方で動く。ブラウザはローカルで開いたもので判定し、配置は行わない([ADR-0021](adr/0021-no-github-pages-defer-hosting.md))。100万回の末尾再帰が一定のメモリで完了する。エラーが未処理例外の経路で報告され、REPL が停止しない。リリース v0.1.0 を出す。

残していること: [design/open-questions.md](design/open-questions.md) の「段階を定めずに保留しているもの」の行。段階1までに決めるとしていた行は、段階1の終わりにそこへ移した。件数と内容をここに複製しない。

### 段階2: コア言語の完成

動的状態の機構と衛生的マクロとライブラリシステムを入れる。この3つは互いに依存するため同じ段階に置く。

- [x] 精密GCの完成とルート管理規約の確立(範囲は [plans/0014-phase2-core-language.md](plans/0014-phase2-core-language.md) の合意を求める点の5。コアIRのヒープ化と弱いシンボル表は段階3) (スライス 2b。新しいヒープの型は、それを入れる各スライス)
- [x] 完全な `call/cc` と `dynamic-wind` (スライス 2e)
- [x] `values` と `call-with-values`、複数値のオブジェクト (スライス 2f)
- [x] 例外(`raise` `raise-continuable` `with-exception-handler` と条件オブジェクト) (スライス 2b・2d)
- [x] 動的点の単一リストと `handler_shift`([ADR-0016](adr/0016-exception-handler-as-dynamic-point.md)) (スライス 2d・2e・2g)
- [x] `make-parameter` と `parameterize`。動的点の3つめの利用者として同じ段階でそろえる (スライス 2g)
- [x] 衛生的マクロ展開器(`syntax-rules` `let-syntax` `letrec-syntax`) (スライス 2i から 2l)
- [x] マクロの展開のメモリを有界にする(展開の作業領域と節点を、ヒープの上限に計上する)。止まらないマクロの適用が、ヒープの上限を大きく超えて伸びていた。保証するのは1行の中の展開で、残りは下の「マクロの展開の有界化の残り」の項目にある([ADR-0031](adr/0031-gc-at-machine-step-boundaries.md) の 2026-10-13 のスライス 2k の追記と、2026-10-14 のスライス 2l の追記) (スライス 2l)
- [x] ライブラリシステム(`define-library` `import` `export` `begin` `cond-expand` `include` `include-library-declarations`)
- [x] ポートごとのケースフォールディング状態と `include-ci`。リーダの `#!fold-case` 指令は段階5だが、ポートの状態と `include-ci` はここで実装する。機構がないまま `include-ci` を提供すると `include` に退化し、畳み込みを期待したファイルが未束縛識別子のエラーになる
- [x] 第1類(処理系がソースとして読む)のファイル経路をリゾルバに通す([design/frontend.md](design/frontend.md) のファイルを開く経路) (スライス 2n・2o)
- [x] 機械操作プリミティブ9個(`apply` `call/cc` `call-with-values` `values` `dynamic-wind` `with-exception-handler` `raise` `raise-continuable` `make-parameter`)。`eval` と `exit` は環境の値とプロセス文脈が必要なので段階5 (スライス 2c から 2g)
- [x] `define-record-type` の基盤(レコードとレコード型のプリミティブ)。スライス 2h
- [x] 可変個引数の `lambda`(`(lambda args ...)` と `(lambda (a . rest) ...)`、`define` の略記を含む)。スライス 2a

完了条件: [design/frontend.md](design/frontend.md) の衛生性の検証項目のうち、段階2で入力を書けるものがすべて通る。[design/runtime.md](design/runtime.md) のテストに含める事例のうち、段階2で入力を書けるものがすべて通る(書けない事例は、段階3と段階5の完了条件に移した。[plans/0014-phase2-core-language.md](plans/0014-phase2-core-language.md) の合意を求める点の9)。継続の多重起動と `dynamic-wind` の相互作用のテストが通る。`include-ci` が対象ファイルを畳み込んで読む。リリース v0.2.0 を出す。

衛生性の検証項目のうち2つは段階2では入力を書けない。`cond` のリテラル `else` の項目は `cond` が段階3の `lib/sucheme/derived.scm` で定義されるため、循環データの `quote` の項目はデータラベルの記法が段階5だからである。この2つは、それぞれ段階3と段階5の完了条件に含める。

残していること: [design/open-questions.md](design/open-questions.md) の「段階を定めずに保留しているもの」の行のうち、段階2の終わりに移したもの。段階2までに決めるとしていた行は、決めたものを設計文書に書いて消し、決めなかったものを移した。件数と内容をここに複製しない。

### 段階3: Schemeによる標準ライブラリ

- [ ] リーダに `` ` `` `,` `,@` の略記を追加(`quasiquote` の定義に必要。文字リテラルはスライス 1h から読める)
- [ ] EOF の値、バイトベクタと約束の値(文字の値はスライス 1h で入った)
- [ ] 派生構文を `lib/sucheme/derived.scm` に `syntax-rules` で定義
- [ ] リストと文字列とベクタの高階手続きを Scheme で実装
- [ ] `(scheme base)` の骨格、`(scheme case-lambda)`、`(scheme cxr)`、`(scheme lazy)`
- [ ] Web UI にサンプルと共有リンク
- [ ] 本体の先頭に置かれた `begin`(定義だけを含むもの、空の `(begin)` を含む)と、本体の先頭の `include` と `cond-expand` が持つ定義を、定義の並びとして展開する(R7RS 7.1.3、7.1.6、5.3.2、4.1.7、4.2.1)。今は、空の `(begin)` は `bad begin: expected (begin expression ...)` になる(例: `(lambda () (begin) 1)`)。定義を含む `begin`、定義を含むファイルの `include`、定義を含む節の `cond-expand` は、`bad define: a definition is only allowed at the top level or at the start of a body` になる(例: `(lambda () (begin (define x 1)) x)` と `(lambda () (cond-expand (r7rs (define x 1))) x)`)。式だけを含む `begin` と `include` は、本体の先頭でも動く。スライス 3p に割り当てた([plans/0016-phase3-scheme-stdlib.md](plans/0016-phase3-scheme-stdlib.md))
- [ ] パラメータの読み出しは、動的点の列の長さに比例して遅くなる(毎段、別のパラメータを `parameterize` する深い再帰で、束縛していないパラメータを読むと、深さの2乗になる)。結果は正しく、メモリは有界である。パラメータごとの束縛の索引を持つかどうかは、実際のプログラムで読み出しが支配的になったときに決める([design/open-questions.md](design/open-questions.md) の「パラメータの読み出しの費用」)。スライスは割り当てず、受け入れた制約として残す。見直す条件は、実際のプログラムで読み出しが支配的になったときである([plans/0016-phase3-scheme-stdlib.md](plans/0016-phase3-scheme-stdlib.md) の合意を求める点の6。ユーザーが 2026-10-16 に承認した)
- [ ] ライブラリの表と `import` の作業領域を、ヒープの上限に計上するか、表を共有する形にする。今は、ライブラリごとの最上位の環境の表(インポートした名前の全部を持つ)が永続アリーナにあり、失敗した定義の表も残るので、約 100 KB の入力で上限(256 MiB)を超えるメモリを使いうる。入れ子の `prefix` の `import` も、1 行の中で計上されない量を確保する。2n のファイルの読み取りでは、リーダの作業領域も計上されない(上限は `max_file_bytes` の 1 MiB に下げて抑えた)。結果は正しい。ユーザーが 2026-10-15 に、2m では直さず、受け入れた制約として扱うと判断した。直す時期は、段階3のコアIRと構文環境を GC ヒープに移すスライスと同時に決める([design/open-questions.md](design/open-questions.md) の「ライブラリの表と `import` の作業領域が、ヒープの上限の外にある」)。スライス 3o に割り当てた([plans/0016-phase3-scheme-stdlib.md](plans/0016-phase3-scheme-stdlib.md))
- [ ] マクロの展開の有界化の残り。(1) 入れ子の `lambda` を重ねる止まらないマクロは、構文環境の探索が深さに比例して重くなり、時間で終わらない(例: `(define-syntax f (syntax-rules () ((_) (lambda () (f)))))` の `(f)`)。環境の探索を深さに依存しない形にするか、展開の深さの上限を置く。(2) 失敗した展開の節点は行をまたいで残り、失敗を繰り返すと上限の外のメモリが増える。節点を GC ヒープへ移すときに外れる。経緯は [ADR-0031](adr/0031-gc-at-machine-step-boundaries.md) の 2026-10-14 のスライス 2l の追記にある。(1) はスライス 3p、(2) はスライス 3o に割り当てた([plans/0016-phase3-scheme-stdlib.md](plans/0016-phase3-scheme-stdlib.md))
- [ ] `let-syntax` と `letrec-syntax` の本体に `define` と `define-syntax` を置けるようにする(R7RS 4.3.1 の本体は定義を許す)。今は `bad define-syntax: a definition is only allowed at the top level or at the start of a body` になる。スライス 3p に割り当てた([plans/0016-phase3-scheme-stdlib.md](plans/0016-phase3-scheme-stdlib.md))
- [ ] REPL で解決した名前ごとに残る未束縛のセルの回収(または数の上限)。最上位で解決した未知の名前は、実行されなくても REPL 自身の未束縛のセルになり、GC ヒープの上限に計上され続ける([design/open-questions.md](design/open-questions.md))。スライス 3o に割り当てた([plans/0016-phase3-scheme-stdlib.md](plans/0016-phase3-scheme-stdlib.md))
- [ ] 準拠マトリクスの入力に、`lib/` のエクスポート節を足す。`lib/` のエクスポート節が実在するこの段階で入れる。段階1の最小版は、`tests/r7rs-required` の識別子をインタプリタが束縛しているかだけを見ている
- [ ] `equal?` の循環したデータでの停止と、共有構造(同じ部分を何度も指すデータ)で比較回数が深さに対して指数に増える問題への対応(訪問済みの集合)。循環は、データの変更(`set-car!` など)が入ると作れるので、その最初のスライスと同時に要る。共有構造での指数時間は、変更が無くても Scheme から作れる(再現入力は計画書 0010 の `equal?` の注に書いた)。段階1では、この既知の制約を受け入れた(ユーザーが 2026-10-12 に判断した)。`src/prim/equiv.zig` の `isEqual` の doc コメントが参照している。スライス 3b に割り当てた([plans/0016-phase3-scheme-stdlib.md](plans/0016-phase3-scheme-stdlib.md))(3b が訪問済みの集合を入れた: 番地の union-find で、循環したデータで止まり、共有構造の比較は節点の数に比例する時間で終わる。集合の確保はヒープの上限に計上する。テストは `tests/scheme/0211-equal-circular.txt`、`0212-equal-shared.txt`、`tests/scheme-slow/0018-equal-scale.txt`。3b の他の項目が終わるまで、チェックは入れない)
- [ ] マクロが導入した最上位の `define` と `define-syntax` を、衛生的にする。今は、名前が別名なら、元のシンボルの名前を REPL の表に束縛するので、マクロが導入した最上位の定義が、利用側の同じ綴りの最上位の変数を書き換える(例は [design/frontend.md](design/frontend.md) の解決規則の節)。v0.2.0 に既知の制限として入れた(ユーザーが 2026-10-15 に判断した)。経緯は [design/open-questions.md](design/open-questions.md) の「マクロが導入した名前の最上位の定義」の行にある。スライス 3q に割り当てた(設計から始める。[plans/0016-phase3-scheme-stdlib.md](plans/0016-phase3-scheme-stdlib.md) の合意を求める点の5)
- [ ] ファイルの実行(`sucheme prog.scm`)。R7RS 5.1 のプログラムは `import` で始まるので、`(scheme base)` ができてから入れる([plans/0014-phase2-core-language.md](plans/0014-phase2-core-language.md) の合意を求める点の6)
- [ ] シンボル表を弱い表にする。`string->symbol` が入るスライスで、シンボルの操作と同時に決める([plans/0014-phase2-core-language.md](plans/0014-phase2-core-language.md) の合意を求める点の5)
- [ ] コアIRを GC ヒープに移し、`Context.code_roots` を要らなくする([plans/0014-phase2-core-language.md](plans/0014-phase2-core-language.md) の合意を求める点の5)
- [ ] `(sucheme core)` を利用者から隠し、REPL の初期環境を `(scheme base)` などに替える。段階2に書いた `(import (sucheme core))` を含むテストを書き換える。v0.2.0 のノートはこの名前の取り消しに触れていないので、段階3のリリースのノートに取り消しを書く([ADR-0037](adr/0037-core-library-exposed-in-stage-2.md) の 2026-10-15 の追記、[plans/0014-phase2-core-language.md](plans/0014-phase2-core-language.md) の合意を求める点の3)
- [x] `apply` の周回を、ステップの境目を通る形にする([ADR-0031](adr/0031-gc-at-machine-step-boundaries.md) の 2026-10-13 の追記)。今は、`apply` が並べ直した引数の鎖と、`apply` で `apply` を呼ぶ入れ子の周回が、1ステップの中で確保され、その間は GC が走らない。`set-car!` などが入る最初のスライスまでに要る。自分を指す引数のリストで、1ステップの中で終わらない周回が作れるようになるためである (スライス 3b。3b が入れた: 並べ直しを継続のフレーム `Kont.Step.spread` に持たせ、周回のたびに境目を通す。並べる量も、一定の個数ずつのステップに分ける。ルートの一覧は変わらない。テストは `src/machine.zig` の単体テストと `tests/scheme/0213-apply-rounds.txt`、`0214-apply-circular-arguments.txt`、`0217-apply-values-scale-small.txt`、`tests/scheme-slow/0019-apply-values-scale.txt`。リストの前の引数と余りを受けるクロージャの余りの引数のリストは、個数に比例する確保が1ステップに残る。下の複数値の項と同じ扱いで、ADR-0031 の 2026-10-15 の追記(3)に書いた)
- [ ] 複数値の確保(`values` と継続の多値での起動の `Machine.valuesOf`、`call-with-values` の `Machine.receiverCall`)を、個数に比例する量を1ステップの中で確保しない形にする([ADR-0031](adr/0031-gc-at-machine-step-boundaries.md) の 2026-10-14 の追記のスライス 2f の項)。上の `apply` の項と同じ直し方で、同じスライスで扱える (スライス 3b。3b が入れた: `call-with-values` の受け手の引数の鎖を、複数値のオブジェクトが届いたとき、`apply` と同じフレームで一定の個数ずつ並べる。テストは `tests/scheme/0215-values-many.txt`、`0216-values-continuation.txt`、`0217-apply-values-scale-small.txt`、`tests/scheme-slow/0019-apply-values-scale.txt`。残り: `Machine.valuesOf` が作る複数値のオブジェクトの本体は、個数に比例するペイロード1つで、ステップに分けられない。確保の前に必要な量を境目で確かめる形か、表現の変更が要るので、ユーザーに諮る。3d から 3f の、入力に比例して確保するプリミティブと同じ種類である。そのため、チェックは入れない)

完了条件: `(scheme base)` のエクスポート一覧が揃い、未実装の識別子が準拠マトリクスに正しく表れる。衛生性の検証項目のうち `cond` のリテラル `else` の項目が通る。[design/runtime.md](design/runtime.md) の事例のうち、段階2で入力を書けなかったもの(容量0で `string->symbol` が成立し続ける事例と、`let` と `when` を使う複数値の事例の元の形)が通る。リリース v0.3.0 を出す。

この段階で未実装として表れてよいのは、後の段階の機能を必要とする識別子である。数値塔を必要とするもの(`/` `exact` `inexact` `sqrt` など)は段階4、ポートを引数に取るか返すもの(`read-char` `write-string` `open-input-string` など)は段階5である。どの族にも属さず後の段階にも割り当てられない識別子が残っていれば、それは [ADR-0006](adr/0006-library-system-and-scheme-level-stdlib.md) の族の一覧の漏れである。

残していること: [design/open-questions.md](design/open-questions.md) の「段階3までに決める」の行。件数と内容をここに複製しない。

### 段階4: 数値塔とUnicode

- [ ] 浮動小数点数、bignum、ratnum、compnum
- [ ] `number->string` と `string->number` の全範囲
- [ ] リーダに基数接頭辞、正確性接頭辞、分数、小数、指数、`+inf.0` 系、複素数を追加
- [ ] リーダが ASCII でない文字の識別子を読めるようにするとき、畳み込む読み手の畳み込みに Unicode の表を使う(段階4。それまで、リーダはそうした識別子を読めず、畳み込む読み手の `folded` が ASCII だけを assert する。[plans/0014-phase2-core-language.md](plans/0014-phase2-core-language.md) の合意を求める点の8)
- [ ] Unicode テーブルの生成器と生成結果
- [ ] `(scheme char)` `(scheme complex)` `(scheme inexact)`

完了条件: `exact-closed` `ratios` `exact-complex` `ieee-float` のフィーチャを真にできる。浮動小数点数の往復性テストが通る。リリース v0.4.0 を出す。

`full-unicode` は、Unicode テーブルを入れた場合に真になる。WASM のサイズが許容できず文字レパートリを ASCII に制限する退避案を採る場合は偽のままになる。判断は実測で行い、採る場合はユーザーの承認を得て ADR を書く([design/open-questions.md](design/open-questions.md) の段階4の行)。したがって `full-unicode` を完了条件に含めない。

残していること: [design/open-questions.md](design/open-questions.md) の「段階4までに決める」の行。件数と内容をここに複製しない。

### 段階5: ポートと入出力

- [ ] テキストポートとバイナリポート、文字列ポート、バイトベクタポート、ファイルポート
- [ ] 第2類(利用者プログラムのファイル入出力)の経路を同じリゾルバに通す。探索ルートの制約はかけず、失敗は `file-error` で報告する
- [ ] リーダの完全化(データラベル、ブロックコメント、`#;`、縦棒識別子、`#u8`、16進エスケープ、`#!fold-case` と `#!no-fold-case` 指令)
- [ ] リーダの位置情報の副表([design/frontend.md](design/frontend.md) の位置情報)。スライス未割り当て。リーダの完全化と同じ段階に置く([plans/0014-phase2-core-language.md](plans/0014-phase2-core-language.md))
- [ ] `write` と `write-shared` と `write-simple`(循環構造のデータラベル)
- [ ] 機械操作プリミティブの残り(`eval` `exit`)と `eval` 用の環境の値
- [ ] `(scheme file)` `(scheme read)` `(scheme write)` `(scheme load)` `(scheme eval)` `(scheme repl)` `(scheme process-context)` `(scheme time)` `(scheme r5rs)`

完了条件: 循環リストの `write` がデータラベル付きで出力される。`#!fold-case` 指令が入力の途中で有効になる。衛生性の検証項目のうち循環データの `quote` の項目が通る。[design/runtime.md](design/runtime.md) の例外の節の事例12(`exit` と `dynamic-wind`)が通る。R7RS 付録Aのライブラリすべてが読み込める。リリース v0.5.0 を出す。

残していること: [design/open-questions.md](design/open-questions.md) の「段階5までに決める」の行。件数と内容をここに複製しない。

### 段階6: 準拠検証

- [ ] `(chibi test)` 互換の最小実装
- [ ] `r7rs-tests.scm` の取り込みと実行
- [ ] 準拠マトリクスに、準拠スイート(`r7rs-tests.scm`)の結果の列を足す。`(scheme r5rs)` の再エクスポートによる識別子の重複は、この列を足すときに解く
- [ ] ファジングの入力コーパスの拡充と、見つかった不具合の解消
- [ ] 不合格項目の issue 化と解消
- [ ] `tests/vendor/README.md` の作成。[ADR-0013](adr/0013-testing-strategy-and-conformance-suite.md) の記録項目に加えて、`LICENSE` がこのディレクトリを覆わないことを明記する([ADR-0022](adr/0022-unlicensed-proprietary.md))
- [ ] BSD 3条項の第3条項(名前の宣伝利用)について、出典として述べることと推奨として用いることの線を引く新ADRの作成([ADR-0022](adr/0022-unlicensed-proprietary.md))。記録形式が2つ併存することを定める件も同じ ADR で扱う

完了条件: 準拠マトリクスに `r7rs-tests.scm` の結果の列があり、その不合格項目がゼロか、残りすべてに根拠が記録されている。リリース v1.0.0 を出す。[ADR-0010](adr/0010-ci-cd-and-release-strategy.md) が「段階ごとにマイナーバージョンを上げる」としているが、R7RS 準拠の達成を v1.0.0 とする規則が優先する。

残していること: [design/open-questions.md](design/open-questions.md) の「段階を定めずに保留しているもの」のうち、性能測定を根拠にする行。

### 段階7: REPLの編集機能

- [ ] 行編集の実装方式の決定(選択肢とトレードオフを提示して判断を得る)
- [ ] Emacs バインディング、複数行編集、履歴、括弧の対応表示、補完
- [ ] REPL の継続行の判定を、保留を毎行読み直す方式から、読み取りの状態を保って続きから読む方式(差分読み取り)に替える。スライス 1l が入れる判定は、継続のたびに保留の全体を読み直すので、費用が保留の大きさの2乗に比例する。ユーザーは保留の上限(64 KiB)を下げず、この制約を受け入れた。再現の仕方: 閉じ忘れの `define` を1つ含み、正しい `define` を多数並べた、上限(64 KiB)に近い入力を REPL に貼り、所要時間を測る。Debug ビルドでは数分かかり、ReleaseSafe でも待たされる。数値は環境で変わるので、ここには書かない。この項目に着手するときに測り直す (スライス未割り当て)

完了条件: 要件どおりの編集操作ができる。リリース v1.1.0 を出す。

残していること: [design/open-questions.md](design/open-questions.md) の「段階7までに決める」の行。件数と内容をここに複製しない。

### 段階8: Web UIの本格化

- [ ] `read` による対話
- [ ] エラー位置の表示と処理の中断
- [ ] 編集の補助とサンプルの充実
- [ ] Web UI の配置先の選定と配置([ADR-0021](adr/0021-no-github-pages-defer-hosting.md))。private にアクセス制限でき、静的ファイルを `application/wasm` で配信できるサービスを選ぶ

完了条件: ブラウザで R7RS のサンプルが一通り動く。配置した URL でも動く。リリース v1.2.0 を出す。

残していること: [design/open-questions.md](design/open-questions.md) の「段階8までに決める」の行。件数と内容をここに複製しない。ここが最終段階である。

## 横断的に続ける作業

- ドキュメントとコードの整合性チェックを節目ごとに実施する。
- PR は自前の敵対的レビューを実行し、必須の新規指摘ゼロになるまで修正する([ADR-0027](adr/0027-severity-by-consequence-and-a-cost-side-stop.md))。推奨と任意は `docs/review/` に記録して該当する段階の作業項目に回す。手順の正は `AGENTS.md` の「PR・レビュー・マージ」の節である。「この詳細が未規定である」という指摘のうち実装時に決めると判断したものは [design/open-questions.md](design/open-questions.md) に記録して閉じる([ADR-0018](adr/0018-incremental-vertical-slices.md))。
- 技術選択と設計判断、およびレビュー提案をあえて採用しない場合は ADR に記録する。
- 段階の完了時に、確定したことを設計ドキュメントまたはコードのコメントに書き、[design/open-questions.md](design/open-questions.md) から該当する行を消す。
- 1コミット=1論理変更を守る。コミットは節目ごとに作り、push はまとめる(`AGENTS.md` の進め方の「Actions の分数」の規則)。

## 未確定の事項

[design/open-questions.md](design/open-questions.md) が正である。決める段階と、何を根拠に決めるかをそこに記録する。このファイルには複製しない。
