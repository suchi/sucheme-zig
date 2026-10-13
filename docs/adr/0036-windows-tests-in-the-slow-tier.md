# ADR-0036: Windows のテストは層2 で走らせ、層2 は main への push で走らせない

- ステータス: 採用
- 日付: 2026-10-13

## 背景

[ADR-0010](0010-ci-cd-and-release-strategy.md) は、CI の自動テストを `ubuntu-latest` と `windows-latest` に限り、全コミットの CI(`ci.yml`)で両方を走らせると定めた。層2(`full.yml`)は、PR を ready にしたときと `main` への push で走っていた。

このリポジトリは private で、標準ランナーの実行分数が月の枠に計上される([ADR-0020](0020-repository-visibility-private.md))。段階2は、複数のスライスを並行して進め、PR ごとに push を重ねたため、月の途中で枠を超えた。2026-10-01 以降の使用量の見積りでは、Windows の test ジョブ(Linux の2倍で数える)が合計の半分を超えていた。見積りと案は [計画 0015](../plans/0015-ci-minutes-reduction.md) にある。枠の大きさと倍率は、公式文書に到達できず未確認である。

## 決定

次の2つを決める。ADR-0010 の「テスト対象は Linux と Windows」は変えない。変えるのは、走る時機である。

1. Windows の test ジョブを、`ci.yml`(全 push)から外し、`full.yml` の `windows` ジョブに移す。step の並びは移す前と同じにする。`ci.yml` の matrix は `ubuntu-latest` だけになる。
2. `full.yml` の `main` への push の起動を外す。起動は `pull_request` の `ready_for_review` と `workflow_dispatch` だけにする。`main` への push では `ci.yml`(Linux)が走る。

選ばなかった案。

- Windows のジョブの step を、プラットフォームに依存するものに絞る: `ci.yml` の step を OS ごとに分ける必要があり、`if:` を使わない規則と衝突する。ジョブを分ける形になり、変更が大きい。削減も小さい。
- 支出の上限やプランの変更だけで解く: ユーザーの設定であり、コードの変更で下げられる分を下げないまま残す。
- リポジトリを public にする: [ADR-0020](0020-repository-visibility-private.md) と [ADR-0022](0022-unlicensed-proprietary.md) の判断に関わるので、この決定の範囲に入れない。

## 結果

- メリット: 全 push の CI が、Linux のジョブと preview だけになる。見積りでは、同じ作業量に対して実行分数がおよそ半分になる(計画 0015)。
- デメリット・受け入れたトレードオフ:
  - draft の間の push では、Windows でしか起きない不具合が見えない。PR を ready にしたときに初めて見つかる。
  - `main` への push で層2 が走らない。PR が最新の `main` を取り込まないまま ready になり、マージ後の組み合わせで壊れても、層2 はそれを見ない。`ci.yml`(Linux)は走る。リリースのタグの push では `release.yml` が `dist` を組み立て直す。
  - Windows の Zig キャッシュは `full.yml` だけが作る。PR の ready ごとに、キャッシュが空の回がありうる。
- 将来の見直し条件: 使用量レポートで、枠に収まることを確かめる。Windows でしか起きない不具合が ready の後に繰り返し見つかるなら、Windows の step を絞って `ci.yml` に戻す案を検討する。
