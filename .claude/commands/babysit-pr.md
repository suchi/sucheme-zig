---
description: PRを監視し、レビュー指摘の修正を必須の新規指摘ゼロまでループする
argument-hint: <PR番号>
---

PR #$ARGUMENTS の未解決レビュースレッドと最新レビューを確認し、対応する。

## 手順

1. 最新レビューを取得: `gh api repos/{owner}/{repo}/pulls/$ARGUMENTS/reviews`
2. `gh api graphql`で未解決スレッド(`isResolved: false`)を一覧取得
3. 各指摘について:
   a. コードを修正し、AGENTS.mdの検証コマンドを実行する
   b. コミット(形式はAGENTS.mdに従う)してプッシュする
   c. スレッドに対応内容を日本語で返信する
      (`gh api repos/{owner}/{repo}/pulls/$ARGUMENTS/comments --method POST -f body="修正しました: ..." -F in_reply_to=COMMENT_ID`)
   d. `resolveReviewThread` GraphQL mutationでスレッドを解決する
4. Copilotに再レビューを依頼する: 必ず`gh pr edit $ARGUMENTS --add-reviewer @copilot`(gh 2.88.0以上が必要)。REST APIの`.../requested_reviewers`はレビュー済みPRの再レビューをトリガーしない。
5. 下記「レビュー完了の判定」を満たすまで待ってから、未解決スレッドと新規コメントを確認する。未解決スレッドがなく、必須の新規指摘もなければ「必須の新規指摘ゼロ」と報告する([ADR-0023](../../docs/adr/0023-mandatory-zero-convergence.md))。マージはしない — マージには明示的なユーザー承認が必要(/merge-pr)。

## レビュー完了の判定

マージの条件としての「レビュー完了」は、自前の敵対的レビューで必須の新規指摘ゼロになったことを指す([ADR-0023](../../docs/adr/0023-mandatory-zero-convergence.md))。外部レビューの可否は含めない。下の2条件は、Copilot にレビューを依頼した場合に「その依頼の応答が返ったか」を判定するためのものであり、マージの条件ではない。Copilot が応答しない場合はマージの条件にしないので、ここで待ち続けない。

Copilot に依頼したとき、次の両方を満たすまで「その依頼の応答が返った」と判定しない(監視ループはこの2条件をポーリングする):

- `gh api repos/{owner}/{repo}/pulls/$ARGUMENTS/requested_reviewers`の`users`からCopilotが消えている。
- 依頼時刻より後に提出された、本文が非空のCopilotレビュー(総評)が存在する。判定は本文長のみで行い、見出し文字列には依存しない(見出しはフォーマット変更・言語設定で変わりうるため)。

注意: Copilotは1回のレビューで複数のレビューレコードを生成する。本文が空のCOMMENTEDレビューはインラインコメントの器(中間生成物)であり、完了シグナルとして扱わない。新しいレビューレコードが1件現れただけで完了と判定すると、総評レビュー到着前の中間レコードを「新規指摘なし」と誤読する。

## 環境への適応

- ローカルのClaude Code(ghあり): 上記の手順をそのまま実行する。必須の新規指摘がゼロになるまで修正のたびにループを回す。
- claude.ai/code(Web、ghなし): 同じ手順をGitHub MCPツールで実行し、`subscribe_pr_activity`ツールでPRを購読してレビューコメント・CIイベントを自動で受け取る。再レビュー依頼は`request_copilot_review` MCPツールで行う(手順4のghコマンドはここでは使えず、REST `requested_reviewers`での代用は不可)。各イベントを上記ループで処理し、PRのマージ/クローズ時またはユーザーの停止指示で購読を解除する。

## 重要ルール

- スレッドをresolveする前に返信を投稿する(Copilotが同じ指摘を繰り返すのを防ぐ)。
- 再レビュー目的でPRをクローズ/リオープン・再作成しない(効果がなく履歴が壊れる)。
- `DELETE .../requested_reviewers`は絶対に使わない(レビュアー状態を壊す)。
