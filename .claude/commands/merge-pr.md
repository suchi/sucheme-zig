---
description: 承認済みPRのマージ・ブランチ削除・mainの同期
argument-hint: <PR番号> [バージョンタグ]
---

$ARGUMENTS の第1引数で指定されたPRを、最終チェックのうえマージする。

前提条件 — すべて確認し、1つでも満たさなければマージせず停止して報告する:

1. レビュー完了: 自前の敵対的レビューで必須の新規指摘ゼロ([ADR-0027](../../docs/adr/0027-severity-by-consequence-and-a-cost-side-stop.md))。推奨と任意は `docs/review/` に記録済みであること。外部レビューの可否はマージの条件に含めない。未解決スレッドがあればすべて解決済みであること。条件の正は `AGENTS.md` の「PR・レビュー・マージ」の節である。
2. CIの全ジョブがグリーン。あわせて、層2(`full.yml` の実行。`slow`、`dist`、`windows`)が、PR の先頭のコミットに対して緑であること。層2 は PR を ready にしたときと手動でしか起動しないので、ready の後に push していれば、先頭のコミットの層2 は無い。その場合は、`workflow_dispatch` で先頭のコミットに対して走らせ、緑になってから判定する([ADR-0036](../../docs/adr/0036-windows-tests-in-the-slow-tier.md))。層2 の実行のコミットと PR の先頭のコミットが一致しなければ、マージせず停止して報告する。ただし、文書だけの PR(定義は `AGENTS.md` の検証コマンドの節にある、文書だけの PR の例外)では層2 は走らないので、層2 の結果は求めず、層1 の全ジョブが緑であることで判定する([ADR-0046](../../docs/adr/0046-skip-slow-tier-for-docs-only-prs.md))。
3. ユーザー承認(ユーザーによるこのコマンドの実行は承認とみなす)。

手順:

1. `gh pr merge <PR番号> --merge --delete-branch`
2. `git checkout main && git pull`
3. バージョンタグ指定があれば: `git tag -a <バージョン> -m "<バージョン>"`のうえ、そのタグだけを`git push origin <バージョン>`で push する(`--tags` は他のタグも送り、`release.yml` を意図せず起動しうる)
4. ローカルのフィーチャーブランチが残っていれば削除し、日本語で完了報告する。
