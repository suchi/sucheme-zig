# ADR-0046: 文書だけの PR では、層2 と Preview を起動しない

- ステータス: 採用
- 日付: 2026-10-24

## 背景

このリポジトリは private で、ワークフローの実行時間が月の枠に計上される([ADR-0020](0020-repository-visibility-private.md))。[ADR-0036](0036-windows-tests-in-the-slow-tier.md) で、Windows のテストを層2(`full.yml`)に移し、層2 は PR を ready にしたときと手動でだけ走らせることにした。

2026-10-24 に、2026-10-05 から 10-24 の実行を、実行とジョブの一覧から概算した(Billing の値ではない。数字と導き方は [計画 0015](../plans/0015-ci-minutes-reduction.md) の「2026-10-24 の追補」にある)。層2 が合計の約半分を占め、どのワークフローにも変更ファイルによる絞り込みが無かった。`docs/` で始まるブランチの PR だけで、合計の約4分の1を使っていた。文書だけの PR では、層2 と Preview が作るもの(規模を試すテスト、Windows のテスト、リリースの成果物の組み立て、Web UI の成果物)は、`main` と変わらない。

## 決定

`full.yml` と `preview.yml` の `pull_request` に `paths-ignore` を足し、変更したファイルがすべて一致する PR では起動しないようにする。ユーザーが 2026-10-24 に承認した(計画 0015 の案 2)。

- 一覧は `docs/**`、`**/*.md`、`.agents/**` とする。実行ファイル、テスト、検査の結果に影響しない文書だけを入れる。`src/`、`lib/`、`tests/`、`tools/`、`web/`、`build.zig`、`build.zig.zon`、`.zigversion`、`.github/workflows/` の `.yml` は一致しない。
- 一覧の正は `full.yml` である。`preview.yml` は同じ一覧を持つ。AGENTS.md は綴りを複製せず、`full.yml` を参照する。
- `ci.yml`(層1)には絞り込みを付けない。文書だけの PR でも、`check-docs`、`check-extract`、`check-report` が走る必要があるからである。`tools/check-docs` は、`paths-ignore` を、走る時機を変えるキーとして扱い、`ci.yml` が持つと赤にする。`paths` は、どのワークフローにも置けない(許可キーの集合の外にある)。
- 文書だけの PR では、マージの承認を求める前の層2 の確認を求めない。報告には「層2 は走らない(`paths-ignore` による)」と書く。

一覧に `.md` 全体を入れる根拠。

- `tools/extract-r7rs-required/SOURCE.md` は、`check-extract` が読む記録である。`check-extract` は層1 で走る。
- `docs/status/conformance.md` は、`check-report` が比べる生成物である。`check-report` は層1 で走る。
- AGENTS.md の検証コマンド表は、`check-docs` が `ci.yml` と照合する。`check-docs` は層1 で走る。
- `tools/release/package.py` は `.md` を読まない。`lib/` と `web/` に `.md` は無い。
- `.gitattributes` が `* text=auto eol=lf` を置くので、Windows の作業ツリーでも `.md` の改行は LF である。層2 の Windows のジョブで走る `check-docs` が、Linux と違う結果を出す経路は見つけていない。

選ばなかった案。

- `main` への push の CI を、日次の定期実行に変える(計画 0015 の案 3): マージのたびの層1 が無くなり、`main` が壊れたことに気づくのが最大で1日遅れる。採らない。
- 層2 の規模を試すテストを `-Doptimize=ReleaseSafe` で走らせる(計画 0015 の案 1): 層2 の所要時間が伸びた主因に効く見込みだが、テストの意味(Debug の安全検査で見つける不具合)が変わりうる。別に計測し、その結果を見てからユーザーに諮る。
- 一覧を `paths`(含めるもの)で書く: 新しいディレクトリを足すたびに一覧を直す必要があり、直し忘れると、コードの PR で層2 が黙って起動しない。除くもので書けば、直し忘れは層2 が余分に走る側に倒れる。

## 結果

- メリット: 文書だけの PR で、層2(約 50 分)と Preview(約 2 分)が走らなくなる。2026-10-05 から 10-24 の実績に当てはめると、`docs/` のブランチの PR の層2 と Preview の分(約 1,350 分)が減る見込みである(見込み。ブランチ名で数えたので、文書だけでない `docs/` のブランチも含む)。
- デメリット・受け入れたトレードオフ:
  - 公式文書(docs.github.com)に、この環境から到達できなかった(2026-10-24)。次の3点は未確認である。`paths-ignore` が `pull_request` の `ready_for_review` でも効くこと。変更したファイルがすべて一致したときにワークフローが起動しないこと(1つでも一致しなければ起動すること)。`workflow_dispatch` には効かないこと。最初の文書だけの PR で確かめる手順を、計画 0015 の追補に書いた。
  - ブランチ保護で、層2 か Preview のジョブを必須のチェックにしているときは、起動しない PR でチェックが保留のまま残り、マージできなくなるおそれがある(未確認)。必須のチェックの設定は、この環境から見えない。
  - `tools/check-docs` は、`full.yml` の `paths-ignore` の値を固定しない。一覧を `**` のように広げると、コードの PR でも層2 が起動しなくなるが、検査は緑のままである。AGENTS.md は、マージの承認を求める前に層2 の結果を確かめることを求めるので、層2 が走っていないことは、そこで見える(運用で守る)。[design/open-questions.md](../design/open-questions.md) の「CI が表の行を走らせることの検査の範囲」の行に記録した。
  - 文書だけの PR が、Windows でだけ表れる文書の検査の不具合を持ち込んでも、層2 では見つからない。次にコードの PR を ready にしたときに見つかる。
- 将来の見直し条件: 文書だけの PR で、層2 か Preview が起動したとき、または必須のチェックが保留のまま残ったとき。一覧に入れた種類のファイルを、ビルドかテストが読むようになったとき。
