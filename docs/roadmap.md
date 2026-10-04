# ロードマップと進捗

リポジトリから進捗が読み取れるようにするための単一の表。段階の完了条件を満たしたらチェックを入れ、同じ PR でこのファイルを更新する。

作業範囲の全体は [plans/0001-sow.md](plans/0001-sow.md) にある。設計は [design/](design/) に、決定は [adr/](adr/) にある。

## 現在地

| 項目 | 状態 |
| --- | --- |
| 現在の段階 | 設計フェーズ(手順1)完了。段階0 は未着手 |
| 最新リリース | なし |
| 固定 Zig バージョン | `.zigversion` を参照 |
| R7RS 準拠マトリクス | [status/](status/)(段階1から生成される) |

## 手順と担当モデル

実装は3手順で進める。各手順の区切りでドキュメントを残し、別の環境でも継続できる状態にする。

| 手順 | 内容 | 担当 | 成果物 |
| --- | --- | --- | --- |
| 1 | 設計 | Opus | [design/](design/) と [adr/](adr/) |
| 2 | 具体的実装計画 | Opus | `plans/` の段階ごとの計画書 |
| 3 | 実装 | Sonnet(簡単なものは Haiku) | コードとテスト |

## 段階

### 段階0: 足場

- [ ] `build.zig` と `build.zig.zon` と `.zigversion`
- [ ] Zig 向けの `.gitignore` 追記と `.editorconfig` と `.gitattributes` の追補
- [x] `AGENTS.md` の検証コマンド表を埋める
- [x] ライセンスの決定と `LICENSE` の配置([ADR-0015](adr/0015-mit-license.md))
- [ ] リポジトリの public 化([ADR-0012](adr/0012-repository-visibility-public.md))
- [ ] CI ワークフロー(`zig fmt --check` と `zig build test`)
- [ ] `tests/r7rs-required/*.txt` を R7RS 付録Aから抽出
- [ ] `.github/dependabot.yml` の担当者をテンプレート由来の値から修正

完了条件: CI が ubuntu と windows の両方でグリーンになり、`zig build test` がローカルでも通る。

### 段階1: 最小REPL

- [ ] 値表現とシンボルのインターン
- [ ] GCヒープの骨格とマーク・スイープ
- [ ] リーダの最小集合(行コメント、真偽値、10進整数、識別子、文字列、リスト、ベクタ、`'`)
- [ ] プリンタ(`write` と `display`)
- [ ] コアIRと展開器の最小集合(`quote` `if` `lambda` `set!` `define` `begin` と呼び出し)
- [ ] CEK機械の実行ループ
- [ ] プリミティブ約30個
- [ ] REPL(素朴な行読み取り、完結判定による継続行)
- [ ] WASM のエクスポートと Web UI の最小版
- [ ] GitHub Pages への配置と PR プレビュー

完了条件: 階乗の定義と呼び出しがネイティブとブラウザの両方で動く。100万回の末尾再帰が一定のメモリで完了する。エラーが未処理例外の経路で報告され、REPL が停止しない。リリース v0.1.0 を出す。

### 段階2: コア言語の完成

- [ ] 精密GCの完成とルート管理規約の確立
- [ ] 完全な `call/cc` と `dynamic-wind`
- [ ] `values` と `call-with-values`
- [ ] 例外(`raise` `raise-continuable` `with-exception-handler` と条件オブジェクト)
- [ ] 衛生的マクロ展開器(`syntax-rules` `let-syntax` `letrec-syntax`)
- [ ] ライブラリシステム(`define-library` `import` `export` `begin` `cond-expand` `include` `include-library-declarations`)
- [ ] ポートごとのケースフォールディング状態と `include-ci`。リーダの `#!fold-case` 指令は段階5だが、ポートの状態と `include-ci` はここで実装する。機構がないまま `include-ci` を提供すると `include` に退化し、畳み込みを期待したファイルが未束縛識別子のエラーになる
- [ ] 第1類(処理系がソースとして読む)のファイル経路をリゾルバに通す([design/frontend.md](design/frontend.md) のファイルを開く経路の数え上げ)
- [ ] 機械操作プリミティブ(`apply` `call/cc` `call-with-values` `values` `dynamic-wind` `with-exception-handler` `raise` `raise-continuable` `make-parameter` `eval`)と `parameterize`
- [ ] `define-record-type` の基盤

完了条件: [design/frontend.md](design/frontend.md) の衛生性の検証項目がすべて通る。継続の多重起動と `dynamic-wind` の相互作用のテストが通る。`include-ci` が対象ファイルを畳み込んで読む。リリース v0.2.0 を出す。

### 段階3: Schemeによる標準ライブラリ

- [ ] リーダに `` ` `` `,` `,@` の略記と文字リテラルを追加(段階3の `quasiquote` の定義に必要)
- [ ] 派生構文を `lib/sucheme/derived.scm` に `syntax-rules` で定義
- [ ] リストと文字列とベクタの高階手続きを Scheme で実装
- [ ] `(scheme base)` の骨格、`(scheme case-lambda)`、`(scheme cxr)`、`(scheme lazy)`
- [ ] Web UI にサンプルと共有リンク

完了条件: `(scheme base)` のエクスポート一覧が揃い、未実装の識別子が準拠マトリクスに正しく表れる。リリース v0.3.0 を出す。

### 段階4: 数値塔とUnicode

- [ ] bignum、ratnum、compnum
- [ ] `number->string` と `string->number` の全範囲
- [ ] Unicode テーブルの生成器と生成結果
- [ ] `(scheme char)` `(scheme complex)` `(scheme inexact)`

完了条件: `exact-closed` `ratios` `exact-complex` `full-unicode` `ieee-float` のフィーチャを真にできる。浮動小数点数の往復性テストが通る。リリース v0.4.0 を出す。

### 段階5: ポートと入出力

- [ ] テキストポートとバイナリポート、文字列ポート、バイトベクタポート、ファイルポート
- [ ] 第2類(利用者プログラムのファイル入出力)の経路を同じリゾルバに通す。探索ルートの制約はかけず、失敗は `file-error` で報告する
- [ ] リーダの完全化(データラベル、ブロックコメント、`#;`、縦棒識別子、`#u8`、16進エスケープ、`#!fold-case` と `#!no-fold-case` 指令)
- [ ] `write` と `write-shared` と `write-simple`(循環構造のデータラベル)
- [ ] `(scheme file)` `(scheme read)` `(scheme write)` `(scheme load)` `(scheme eval)` `(scheme repl)` `(scheme process-context)` `(scheme time)` `(scheme r5rs)`

完了条件: 循環リストの `write` がデータラベル付きで出力される。`#!fold-case` 指令が入力の途中で有効になる。16ライブラリすべてが読み込める。リリース v0.5.0 を出す。

### 段階6: 準拠検証

- [ ] `(chibi test)` 互換の最小実装
- [ ] `r7rs-tests.scm` の取り込みと実行
- [ ] 準拠マトリクスの生成と公開、CI による同期検査
- [ ] リーダのファジング
- [ ] 不合格項目の issue 化と解消

完了条件: 準拠マトリクスが公開され、`r7rs-tests.scm` の不合格項目がゼロか、残りすべてに根拠が記録されている。リリース v1.0.0 を出す。

### 段階7: REPLの編集機能

- [ ] 行編集の実装方式の決定(選択肢とトレードオフを提示して判断を得る)
- [ ] Emacs バインディング、複数行編集、履歴、括弧の対応表示、補完

完了条件: 要件どおりの編集操作ができる。リリース v1.1.0 を出す。

### 段階8: Web UIの本格化

- [ ] `read` による対話
- [ ] エラー位置の表示と処理の中断
- [ ] 編集の補助とサンプルの充実

完了条件: ブラウザで R7RS のサンプルが一通り動く。リリース v1.2.0 を出す。

## 横断的に続ける作業

- ドキュメントとコードの整合性チェックを節目ごとに実施する。
- PR は自前の敵対的レビューを実行し、新規指摘ゼロになるまで修正する([ADR-0017](adr/0017-self-hosted-adversarial-review.md))。
- 技術選択と設計判断、およびレビュー提案をあえて採用しない場合は ADR に記録する。
- 1コミット=1論理変更を守り、節目ごとにプッシュする。

## 未決の事項

| 事項 | 必要な判断 | 期限 |
| --- | --- | --- |
| 行編集の実装方式 | 自前実装か C ライブラリの取り込みか | 段階7の開始時 |
| 複素数の段階 | 段階4の作業量が過大な場合に段階5以降へ繰り延べるか | 段階4の計画時 |
