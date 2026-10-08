# ADR(アーキテクチャ決定記録)

技術選択・設計判断を記録する。1決定=1ファイルで`NNNN-title.md`(4桁ゼロ埋め連番・タイトルは英語kebab-case)、本文は日本語。テンプレート: [0000-template.md](0000-template.md)。

## 運用ルール

- 技術選択・設計判断をしたら必ずADRを残す。番号は既存の最大値+1。作成したら下の一覧に追加する。
- 既存ADRの決定内容の書き換えは禁止。本文の加筆・削除・取り消し線による差し替えを行わない。許される編集は次の2つに限る。
  1. 下の非推奨化手順(ステータス変更と冒頭への追記)。
  2. 決定を変えない追記。前提が変わったことや、別のADRが一部を置き換えたことを知らせる場合に使う。ステータスは変えない。書く位置と形は1つに決める。冒頭のメタデータ行の直後に空行をはさみ、`> YYYY-MM-DD 追記: ...` の引用ブロックで書く。本文中には書かない。複数回追記する場合は同じブロックに段落を足し(`>` だけの行で区切る)、段落ごとに `YYYY-MM-DD 追記:` を書く。ブロックの先頭の日付だけでは、後から足した段落がいつ書かれたか分からなくなる。
- 非推奨のADRにも2の追記を足してよい。その場合、`> 非推奨理由: ...` のブロックを先に、`> YYYY-MM-DD 追記: ...` のブロックを後に置く。非推奨になった理由が最初に読まれるようにするためである。追記を消して非推奨理由に置き換えてはならない。本文の削除と同じく記録を失う。
- 上の形に合っていない既存の追記を、形だけ上に合わせる編集は許す。中身を変えない場合に限る。
- 「既存」は `main` にある ADR の、`main` にある記述を指す。次の2つはその PR がマージされるまで直してよい。同じ PR の中で作った ADR の本文と、同じ PR の中で足した追記の文面である。レビュー指摘への対応で未マージの記述に追記の履歴を残すと、決定が変わっていないのに変わったように読める。`main` にある記述は引き続き直せない。
- 決定が変わったら:
  1. 旧ADRのステータスを`採用`から`非推奨`に変え、冒頭に追記する:

     ```markdown
     - ステータス: ~~採用~~ 非推奨 → [ADR-NNNN: new-title](NNNN-new-title.md) に置き換え

     > 非推奨理由: ...
     ```

  2. 次の番号で新ADRを作成し、置き換えを明記する:

     ```markdown
     - 置き換え: [ADR-NNNN: old-title](NNNN-old-title.md) を非推奨とし、本ADRが最新の決定となる
     ```

  3. 下の一覧を更新し、非推奨を明示する。
- レビュー指摘を受けても技術的・環境的理由で現状を維持する場合は、該当コードに1〜3行の`Why:`コメント(ADR番号を参照)を書き、ADRにも記録する。

## 一覧

| 番号 | タイトル | ステータス | 日付 |
| --- | --- | --- | --- |
| [0000](0000-template.md) | テンプレート | - | - |
| [0001](0001-zig-version-pinning.md) | Zig 0.17.0 への固定と API ノートの整備 | 採用 | 2026-10-04 |
| [0002](0002-value-representation.md) | Scheme値は Zig のタグ付き union で表現する | 採用 | 2026-10-04 |
| [0003](0003-precise-mark-sweep-gc.md) | 非移動型の精密マーク・スイープGCを採用する | 採用 | 2026-10-04 |
| [0004](0004-cek-machine-evaluator.md) | 評価器は明示的な継続を持つCEK機械とする | 採用 | 2026-10-04 |
| [0005](0005-hygienic-expander-by-renaming.md) | 衛生性は構文環境と別名による改名で実現する | 非推奨([0019](0019-denotations-and-identifier-resolution.md)に置き換え) | 2026-10-04 |
| [0006](0006-library-system-and-scheme-level-stdlib.md) | 標準ライブラリは可能な限り Scheme で書く | 採用 | 2026-10-04 |
| [0007](0007-numeric-tower-scope.md) | 完全な数値塔を実装する | 採用 | 2026-10-04 |
| [0008](0008-string-representation.md) | 文字列は UTF-8 バイト列と ASCII 判定フラグで表現する | 採用 | 2026-10-04 |
| [0009](0009-wasm-freestanding-and-zero-dependency-web-ui.md) | WASM は freestanding とし、Web UI は依存パッケージを持たない | 採用 | 2026-10-04 |
| [0010](0010-ci-cd-and-release-strategy.md) | CIのテストは Linux と Windows に限り、macOS はビルド保証のみとする | 採用 | 2026-10-04 |
| [0011](0011-github-pages-pr-preview.md) | GitHub Pages は gh-pages ブランチ方式とし、PRごとのプレビューを配置する | 非推奨([0021](0021-no-github-pages-defer-hosting.md)に置き換え) | 2026-10-04 |
| [0012](0012-repository-visibility-public.md) | リポジトリを public にする | 非推奨([0020](0020-repository-visibility-private.md)に置き換え) | 2026-10-04 |
| [0013](0013-testing-strategy-and-conformance-suite.md) | テストは3層構成とし、外部の準拠スイートをベンダリングする | 採用 | 2026-10-04 |
| [0014](0014-repl-line-editor-boundary.md) | 行編集は抽象境界のみ先に定め、実装方式は段階7で決める | 採用 | 2026-10-04 |
| [0015](0015-mit-license.md) | MIT ライセンスを採用する | 非推奨([0022](0022-unlicensed-proprietary.md)に置き換え) | 2026-10-04 |
| [0016](0016-exception-handler-as-dynamic-point.md) | 例外ハンドラの切り替えを動的状態の点として表す | 採用 | 2026-10-04 |
| [0017](0017-self-hosted-adversarial-review.md) | レビューは自前の敵対的レビューを主とする | 非推奨([0023](0023-mandatory-zero-convergence.md)に置き換え) | 2026-10-04 |
| [0018](0018-incremental-vertical-slices.md) | 通しで動く縦切りを積み上げ、やり残しを明示して漸進的に進める | 採用 | 2026-10-05 |
| [0019](0019-denotations-and-identifier-resolution.md) | 衛生性は構文環境と別名による改名で実現し、意味は6種とする | 採用 | 2026-10-05 |
| [0020](0020-repository-visibility-private.md) | リポジトリを private にする | 採用 | 2026-10-06 |
| [0021](0021-no-github-pages-defer-hosting.md) | GitHub Pages は使わず、Web UI の配置は計画の後半まで行わない | 採用 | 2026-10-06 |
| [0022](0022-unlicensed-proprietary.md) | ライセンスを付与せず UNLICENSED として非公開を明示する | 採用 | 2026-10-07 |
| [0023](0023-mandatory-zero-convergence.md) | 自前の敵対的レビューの収束条件を必須の新規指摘ゼロとする | 採用 | 2026-10-07 |
| [0024](0024-closed-spelling-sets.md) | 検証ツールは受理する綴りの集合を閉じ、知らない綴りを報告する | 非推奨([0026](0026-verify-facts-about-code-not-prose.md)に置き換え) | 2026-10-08 |
| [0025](0025-permission-policy-guard-in-hooks.md) | 承認の判断はフックに置き、許可リストは日常操作まで広げる | 採用 | 2026-10-08 |
| [0026](0026-verify-facts-about-code-not-prose.md) | 機械検査の対象をコードと生成物についての事実に限る | 採用 | 2026-10-08 |
