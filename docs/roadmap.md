# ロードマップと進捗

リポジトリから進捗が読み取れるようにするための単一の表。段階の完了条件を満たしたらチェックを入れ、同じ PR でこのファイルを更新する。

各段階は、リーダからプリンタまでネイティブとブラウザの両方で通しで動く状態を作る([ADR-0018](adr/0018-incremental-vertical-slices.md))。層を1つずつ完成させる進め方は採らない。段階の終わりに「確定したこと」と「残していること」を記録する。

「残していること」の欄は、その段階で決めずに後の段階へ回した事項を指す([design/open-questions.md](design/open-questions.md) の行)。未着手の作業項目のことではない。作業の進み具合は各段階のチェックボックスが正である。

作業範囲の全体は [plans/0001-sow.md](plans/0001-sow.md) にある。設計は [design/](design/) に、決定は [adr/](adr/) に、実装時に決めることは [design/open-questions.md](design/open-questions.md) にある。

## 現在地

| 項目 | 状態 |
| --- | --- |
| 現在の段階 | 段階0(足場)進行中。リポジトリの public 化と、`main` での CI グリーンの確認が未了 |
| 最新リリース | なし |
| 固定 Zig バージョン | `.zigversion` を参照 |
| R7RS 準拠マトリクス | [status/](status/)(段階1から生成される) |

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
- [x] ライセンスの決定と `LICENSE` の配置([ADR-0015](adr/0015-mit-license.md))
- [ ] リポジトリの public 化([ADR-0012](adr/0012-repository-visibility-public.md))。GitHub の設定変更なのでユーザーが実行する
- [x] CI ワークフロー(`AGENTS.md` の検証コマンド表で CI 実行が「全コミット」の行のうち、段階0で使えるもの)
- [x] CI の雛形に、段階1で足すファジングのワークフローの置き場所を決める(定期実行と手動起動。全コミットの CI には入れない)
- [x] `tests/r7rs-required/*.txt` を R7RS 付録Aから抽出
- [x] `.github/dependabot.yml` の担当者をテンプレート由来の値から修正

完了条件: CI が ubuntu と windows の両方でグリーンになり、`zig build test` がローカルでも通る。

確定したこと: `build.zig` の step は段階0の4つ(既定・`run`・`test`・`check-docs`)。版の強制は `build.zig` が `.zigversion` と `builtin.zig_version` を比較して行う(`build.zig.zon` の `minimum_zig_version` は Zig が検査しない)。CI は `ubuntu-latest` と `windows-latest` のマトリクス1ジョブで、Zig は `mlugg/setup-zig` を SHA でピン留めして入れる。付録Aの識別子は `tools/extract-r7rs-required` で機械抽出し、16ライブラリ・557識別子を `tests/r7rs-required/` に置いた。

残していること: なし。段階0で決めた3事項は open-questions.md から消し、決めた内容は上の「確定したこと」と [plans/0002-phase0-scaffolding.md](plans/0002-phase0-scaffolding.md) にある。未着手の作業項目はチェックボックスを参照する。

### 段階1: 通しで動く最小の縦切り

意図的に小さくする。10進整数と記号と手続き呼び出しだけで `(define (fact n) ...)` が動く状態を目標にする。この時点で値表現、ヒープ、GC、機械、リーダ、プリンタ、REPL、WASM、Web UI、CI がすべて最小の形でそろう。以降の段階はこの縦切りを太らせる作業になる。

- [ ] 値表現とシンボルのインターン([design/runtime.md](design/runtime.md) の値の表現の段階1の行)
- [ ] GCヒープの骨格とマーク・スイープ、ルート登録 API
- [ ] リーダの最小集合(行コメント、真偽値、10進整数、識別子、文字列、リスト、ベクタ、`'`)
- [ ] プリンタ(`write` と `display`)
- [ ] コアIRと展開器の最小集合(`quote` `if` `lambda` `set!` `define` `begin` と呼び出し)
- [ ] CEK機械の実行ループと、段階1の機構に必要な継続フレーム([design/runtime.md](design/runtime.md) の必要なフレームの種類の段階1の行)
- [ ] 最外の継続への脱出による未処理例外の報告(継続と条件オブジェクトの最小形)
- [ ] プリミティブ約30個。算術は固定長整数に限る
- [ ] REPL(素朴な行読み取り、完結判定による継続行)
- [ ] リーダのファジングのワークフロー(定期実行と手動起動)
- [ ] WASM のエクスポート([design/platform-and-web.md](design/platform-and-web.md) のエクスポート)と Web UI の最小版
- [ ] GitHub Pages への配置と PR プレビュー

完了条件: 階乗の定義と呼び出しがネイティブとブラウザの両方で動く。100万回の末尾再帰が一定のメモリで完了する。エラーが未処理例外の経路で報告され、REPL が停止しない。リリース v0.1.0 を出す。

残していること: [design/open-questions.md](design/open-questions.md) の「段階1までに決める」の行。件数と内容をここに複製しない。

### 段階2: コア言語の完成

動的状態の機構と衛生的マクロとライブラリシステムを入れる。この3つは互いに依存するため同じ段階に置く。

- [ ] 精密GCの完成とルート管理規約の確立
- [ ] 完全な `call/cc` と `dynamic-wind`
- [ ] `values` と `call-with-values`、複数値のオブジェクト
- [ ] 例外(`raise` `raise-continuable` `with-exception-handler` と条件オブジェクト)
- [ ] 動的点の単一リストと `handler_shift`([ADR-0016](adr/0016-exception-handler-as-dynamic-point.md))
- [ ] `make-parameter` と `parameterize`。動的点の3つめの利用者として同じ段階でそろえる
- [ ] 衛生的マクロ展開器(`syntax-rules` `let-syntax` `letrec-syntax`)
- [ ] ライブラリシステム(`define-library` `import` `export` `begin` `cond-expand` `include` `include-library-declarations`)
- [ ] ポートごとのケースフォールディング状態と `include-ci`。リーダの `#!fold-case` 指令は段階5だが、ポートの状態と `include-ci` はここで実装する。機構がないまま `include-ci` を提供すると `include` に退化し、畳み込みを期待したファイルが未束縛識別子のエラーになる
- [ ] 第1類(処理系がソースとして読む)のファイル経路をリゾルバに通す([design/frontend.md](design/frontend.md) のファイルを開く経路)
- [ ] 機械操作プリミティブ9個(`apply` `call/cc` `call-with-values` `values` `dynamic-wind` `with-exception-handler` `raise` `raise-continuable` `make-parameter`)。`eval` と `exit` は環境の値とプロセス文脈が必要なので段階5
- [ ] `define-record-type` の基盤(レコードとレコード型のプリミティブ)

完了条件: [design/frontend.md](design/frontend.md) の衛生性の検証項目のうち、段階2で入力を書けるものがすべて通る。[design/runtime.md](design/runtime.md) のテストに含める事例がすべて通る。継続の多重起動と `dynamic-wind` の相互作用のテストが通る。`include-ci` が対象ファイルを畳み込んで読む。リリース v0.2.0 を出す。

衛生性の検証項目のうち2つは段階2では入力を書けない。`cond` のリテラル `else` の項目は `cond` が段階3の `lib/sucheme/derived.scm` で定義されるため、循環データの `quote` の項目はデータラベルの記法が段階5だからである。この2つは、それぞれ段階3と段階5の完了条件に含める。

残していること: [design/open-questions.md](design/open-questions.md) の「段階2までに決める」の行。件数と内容をここに複製しない。

### 段階3: Schemeによる標準ライブラリ

- [ ] リーダに `` ` `` `,` `,@` の略記と文字リテラルを追加(`quasiquote` の定義に必要)
- [ ] 文字と EOF の値、バイトベクタと約束の値
- [ ] 派生構文を `lib/sucheme/derived.scm` に `syntax-rules` で定義
- [ ] リストと文字列とベクタの高階手続きを Scheme で実装
- [ ] `(scheme base)` の骨格、`(scheme case-lambda)`、`(scheme cxr)`、`(scheme lazy)`
- [ ] Web UI にサンプルと共有リンク

完了条件: `(scheme base)` のエクスポート一覧が揃い、未実装の識別子が準拠マトリクスに正しく表れる。衛生性の検証項目のうち `cond` のリテラル `else` の項目が通る。リリース v0.3.0 を出す。

この段階で未実装として表れてよいのは、後の段階の機能を必要とする識別子である。数値塔を必要とするもの(`/` `exact` `inexact` `sqrt` など)は段階4、ポートを引数に取るか返すもの(`read-char` `write-string` `open-input-string` など)は段階5である。どの族にも属さず後の段階にも割り当てられない識別子が残っていれば、それは [ADR-0006](adr/0006-library-system-and-scheme-level-stdlib.md) の族の一覧の漏れである。

残していること: なし。open-questions.md に段階3の節はない。

### 段階4: 数値塔とUnicode

- [ ] 浮動小数点数、bignum、ratnum、compnum
- [ ] `number->string` と `string->number` の全範囲
- [ ] リーダに基数接頭辞、正確性接頭辞、分数、小数、指数、`+inf.0` 系、複素数を追加
- [ ] Unicode テーブルの生成器と生成結果
- [ ] `(scheme char)` `(scheme complex)` `(scheme inexact)`

完了条件: `exact-closed` `ratios` `exact-complex` `ieee-float` のフィーチャを真にできる。浮動小数点数の往復性テストが通る。リリース v0.4.0 を出す。

`full-unicode` は、Unicode テーブルを入れた場合に真になる。WASM のサイズが許容できず文字レパートリを ASCII に制限する退避案を採る場合は偽のままになる。判断は実測で行い、採る場合はユーザーの承認を得て ADR を書く([design/open-questions.md](design/open-questions.md) の段階4の行)。したがって `full-unicode` を完了条件に含めない。

残していること: [design/open-questions.md](design/open-questions.md) の「段階4までに決める」の行。件数と内容をここに複製しない。

### 段階5: ポートと入出力

- [ ] テキストポートとバイナリポート、文字列ポート、バイトベクタポート、ファイルポート
- [ ] 第2類(利用者プログラムのファイル入出力)の経路を同じリゾルバに通す。探索ルートの制約はかけず、失敗は `file-error` で報告する
- [ ] リーダの完全化(データラベル、ブロックコメント、`#;`、縦棒識別子、`#u8`、16進エスケープ、`#!fold-case` と `#!no-fold-case` 指令)
- [ ] `write` と `write-shared` と `write-simple`(循環構造のデータラベル)
- [ ] 機械操作プリミティブの残り(`eval` `exit`)と `eval` 用の環境の値
- [ ] `(scheme file)` `(scheme read)` `(scheme write)` `(scheme load)` `(scheme eval)` `(scheme repl)` `(scheme process-context)` `(scheme time)` `(scheme r5rs)`

完了条件: 循環リストの `write` がデータラベル付きで出力される。`#!fold-case` 指令が入力の途中で有効になる。衛生性の検証項目のうち循環データの `quote` の項目が通る。R7RS 付録Aのライブラリすべてが読み込める。リリース v0.5.0 を出す。

残していること: [design/open-questions.md](design/open-questions.md) の「段階5までに決める」の行。件数と内容をここに複製しない。

### 段階6: 準拠検証

- [ ] `(chibi test)` 互換の最小実装
- [ ] `r7rs-tests.scm` の取り込みと実行
- [ ] 準拠マトリクスの生成と公開、CI による同期検査
- [ ] ファジングの入力コーパスの拡充と、見つかった不具合の解消
- [ ] 不合格項目の issue 化と解消

完了条件: 準拠マトリクスが公開され、`r7rs-tests.scm` の不合格項目がゼロか、残りすべてに根拠が記録されている。リリース v1.0.0 を出す。[ADR-0010](adr/0010-ci-cd-and-release-strategy.md) が「段階ごとにマイナーバージョンを上げる」としているが、R7RS 準拠の達成を v1.0.0 とする規則が優先する。

残していること: [design/open-questions.md](design/open-questions.md) の「段階を定めずに保留しているもの」のうち、性能測定を根拠にする行。

### 段階7: REPLの編集機能

- [ ] 行編集の実装方式の決定(選択肢とトレードオフを提示して判断を得る)
- [ ] Emacs バインディング、複数行編集、履歴、括弧の対応表示、補完

完了条件: 要件どおりの編集操作ができる。リリース v1.1.0 を出す。

残していること: [design/open-questions.md](design/open-questions.md) の「段階7までに決める」の行。件数と内容をここに複製しない。

### 段階8: Web UIの本格化

- [ ] `read` による対話
- [ ] エラー位置の表示と処理の中断
- [ ] 編集の補助とサンプルの充実

完了条件: ブラウザで R7RS のサンプルが一通り動く。リリース v1.2.0 を出す。

残していること: なし。ここが最終段階である。

## 横断的に続ける作業

- ドキュメントとコードの整合性チェックを節目ごとに実施する。
- PR は自前の敵対的レビューを実行し、新規指摘ゼロになるまで修正する([ADR-0017](adr/0017-self-hosted-adversarial-review.md))。「この詳細が未規定である」という指摘のうち実装時に決めると判断したものは [design/open-questions.md](design/open-questions.md) に記録して閉じる([ADR-0018](adr/0018-incremental-vertical-slices.md))。
- 技術選択と設計判断、およびレビュー提案をあえて採用しない場合は ADR に記録する。
- 段階の完了時に、確定したことを設計ドキュメントまたはコードのコメントに書き、[design/open-questions.md](design/open-questions.md) から該当する行を消す。
- 1コミット=1論理変更を守り、節目ごとにプッシュする。

## 未確定の事項

[design/open-questions.md](design/open-questions.md) が正である。決める段階と、何を根拠に決めるかをそこに記録する。このファイルには複製しない。
