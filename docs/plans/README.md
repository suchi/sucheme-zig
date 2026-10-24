# 作業計画

作業範囲の合意(SOW)と、段階ごとの具体的実装計画を置く。

| 文書 | 内容 |
| --- | --- |
| [0001-sow.md](0001-sow.md) | プロジェクト全体の作業範囲、成果物、進め方、リスク |
| [0002-phase0-scaffolding.md](0002-phase0-scaffolding.md) | 段階0(足場)の実装計画 |
| [0003-phase1-minimal-slice.md](0003-phase1-minimal-slice.md) | 段階1(最小の縦切り)のスライスへの分割と進捗 |
| [0004-slice-1f-cek-machine.md](0004-slice-1f-cek-machine.md) | スライス 1f(CEK 機械への移行)の実装計画 |
| [0005-slice-1g-gc-heap.md](0005-slice-1g-gc-heap.md) | スライス 1g(GC ヒープ)の実装計画 |
| [0006-slice-1h-strings-chars-vectors.md](0006-slice-1h-strings-chars-vectors.md) | スライス 1h(文字・文字列・ベクタ・ドット対)の実装計画 |
| [0007-test-tiers.md](0007-test-tiers.md) | テストの層と実行タイミングの設計(リードタイムの短縮) |
| [0008-slice-1i-wasm-web-ui.md](0008-slice-1i-wasm-web-ui.md) | スライス 1i(WASM と Web UI の最小版)の実装計画 |
| [0009-slice-1j-release-v0-1-0.md](0009-slice-1j-release-v0-1-0.md) | スライス 1j(リリース v0.1.0)の実装計画 |
| [0010-slices-1k-1l-primitives-and-repl-continuation.md](0010-slices-1k-1l-primitives-and-repl-continuation.md) | スライス 1k(プリミティブ)と 1l(REPL の継続行)の実装計画 |
| [0011-slice-1m-conformance-report-early.md](0011-slice-1m-conformance-report-early.md) | スライス 1m(準拠マトリクスの最小版の前倒し)の実装計画 |
| [0012-schedule-estimates-and-actuals.md](0012-schedule-estimates-and-actuals.md) | 完了時期の見積りと実績、段階ごとの補正の記録 |
| [0013-stage1-completion.md](0013-stage1-completion.md) | 段階1の完了の手続き(`current_stage`、実績の記録、日付の訂正) |
| [0014-phase2-core-language.md](0014-phase2-core-language.md) | 段階2(コア言語の完成)のスライスへの分割と実装計画 |
| [0015-ci-minutes-reduction.md](0015-ci-minutes-reduction.md) | GitHub Actions の実行分数を抑える運用と、ワークフローの変更案 |
| [0016-phase3-scheme-stdlib.md](0016-phase3-scheme-stdlib.md) | 段階3(Scheme による標準ライブラリ)のスライスへの分割と実装計画 |
| [0017-parallel-lanes.md](0017-parallel-lanes.md) | 段階3の残りから段階8までを、レーンに分けて並行に進める再計画 |
| [0018-phase4-numeric-tower-unicode.md](0018-phase4-numeric-tower-unicode.md) | 段階4(数値塔と Unicode)のスライスへの分割、レーンの間の関数の署名、計上の設計 |
| [0019-phase5-ports-and-io.md](0019-phase5-ports-and-io.md) | 段階5(ポートと入出力)のスライスへの分割と実装計画。0017 の L3 と、L2 のリーダの完全化 |
| [0020-conformance-harness-early.md](0020-conformance-harness-early.md) | 段階6の前倒し(レーン L5): 準拠スイートの取り込み、`(chibi test)` の最小実装、ランナー、準拠マトリクスへの結果 |
| [0021-stage7-8-early-parts.md](0021-stage7-8-early-parts.md) | 段階7(REPL の行編集)と段階8(Web UI)のうち、先に始める部分の実装計画と、実装方式と配置先の比較 |
| [0022-layer2-measurement.md](0022-layer2-measurement.md) | 層2の `test-scheme -Dslow=true` の1件あたりの時間の測定と、短縮案ごとの効果の見積り |
| [0023-slice-3o-ir-to-gc-heap.md](0023-slice-3o-ir-to-gc-heap.md) | スライス 3o(コアIRを GC ヒープへ移し、上限の外の確保を閉じる)の設計と PR の分け方 |
| [0024-step-limit-for-the-conformance-run.md](0024-step-limit-for-the-conformance-run.md) | 機械の歩数の上限: 準拠スイートの実行で止まらない形式を打ち切る設計と、L0 と L3 との調整(レーン L5) |
| [0025-fuzzing-the-evaluator.md](0025-fuzzing-the-evaluator.md) | ファジングの拡充: 評価器を通しで試す対象と、入力コーパス(レーン L5) |
| [0026-shorten-slow-tier.md](0026-shorten-slow-tier.md) | 層2の slow tests を、検査を減らさずに短くする案(単体テストの最適化、test-scheme のランナーの遅れと並列の実行) |

段階ごとの実装計画は、その段階の実装を始める前に手順2(Opus)で作成し、`NNNN-phaseN-title.md` として追加する。計画書のない段階の実装は始めない。

計画書に書くこと。

- 対象とする段階と、[../roadmap.md](../roadmap.md) の完了条件
- 追加・変更するファイルの一覧と、それぞれの責務
- モジュール間のインタフェース(関数シグネチャの水準まで)
- 作業の順序と、並行できる単位
- 各作業に対応するテストと、Red から始める手順
- 参照すべき設計ドキュメントと ADR
