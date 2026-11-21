# ADR-0046: 文書だけの PR では、層2 と Preview を起動しない

- ステータス: 採用
- 日付: 2026-10-24

## 背景

このリポジトリは private で、ワークフローの実行時間が月の枠に計上される([ADR-0020](0020-repository-visibility-private.md))。[ADR-0036](0036-windows-tests-in-the-slow-tier.md) で、Windows のテストを層2(`full.yml`)に移し、層2 は PR を ready にしたときと手動でだけ走らせることにした。

2026-10-24 に、2026-10-05 から 10-24 の実行を、実行とジョブの一覧から概算した(Billing の値ではない。数字と導き方は [計画 0015](../plans/0015-ci-minutes-reduction.md) の「2026-10-24 の追補」にある)。層2 が合計の約半分を占め、どのワークフローにも変更ファイルによる絞り込みが無かった。`docs/` で始まるブランチの PR だけで、合計の約4分の1を使っていた。文書だけの PR では、層2 と Preview が作るもの(規模を試すテスト、Windows のテスト、リリースの成果物の組み立て、Web UI の成果物)は、`main` と変わらない。

## 決定

`full.yml` と `preview.yml` の `pull_request` に `paths-ignore` を足し、変更したファイルがすべて一致する PR では起動しないようにする。2026-10-24 に決めた(計画 0015 の案 2)。

- 文書だけの PR は、変更したファイルが `docs/` の下、`.agents/` の下、拡張子 `.md` のファイルだけの PR とする。AGENTS.md がこの定義を持ち、PR の変更ファイルの一覧で判断する。ワークフローの設定からは導かない。設定から導くと、一覧を広げたときに、すべての PR が文書だけになり、層2 の確認の規則まで外れるからである。
- `full.yml` と `preview.yml` の一覧は、この定義に合わせて `docs/**`、`**/*.md`、`.agents/**` とする。`.md` でないコード、テストの入力、ワークフロー、`build.zig` などは、`docs/` と `.agents/` の外にあれば一致しない。`tools/` や `tests/` の下の `.md`(`tools/extract-r7rs-required/SOURCE.md`、`tests/vendor/README.md`)は一致し、文書に数える(下の根拠)。
- `tools/check-docs` は、`full.yml` の `paths-ignore` の値を綴りごと固定する(`types` と同じ照合)。一覧を変えるときは赤になるので、新しい一覧が文書だけの PR の意味をどう変えるかを決めてから、検査と AGENTS.md の定義を合わせて変える。
- `ci.yml`(層1)には絞り込みを付けない。文書だけの PR でも、`check-docs`、`check-extract`、`check-report` が走る必要があるからである。`tools/check-docs` は、`paths-ignore` を、走る時機を変えるキーとして扱い、`ci.yml` が持つと赤にする。`paths` は、どのワークフローにも置けない(許可キーの集合の外にある)。
- 文書だけの PR では、マージの承認を求める前の層2 の確認を求めない。報告には「層2 は走らない(`paths-ignore` による)」と書く。文書だけでない PR で層2 が起動しないときは、手動で走らせ、一覧の食い違いを報告する。

一覧に `.md` 全体を入れる根拠。

- `tools/extract-r7rs-required/SOURCE.md` は、`check-extract` が読む記録である。`check-extract` は層1 で走る。
- `docs/status/conformance.md` は、`check-report` が比べる生成物である。`check-report` は層1 で走る。
- AGENTS.md の検証コマンド表は、`check-docs` が `ci.yml` と照合する。`check-docs` は層1 で走る。
- `tools/release/package.py` は `.md` を読まない。`lib/` と `web/` に `.md` は無い。
- `.gitattributes` が `* text=auto eol=lf` を置くので、Windows の作業ツリーでも `.md` の改行は LF である。層2 の Windows のジョブで走る `check-docs` が、Linux と違う結果を出す経路は見つけていない。

選ばなかった案。

- `main` への push の CI を、日次の定期実行に変える(計画 0015 の案 3): マージのたびの層1 が無くなり、`main` が壊れたことに気づくのが最大で1日遅れる。採らない。
- 一覧を `paths`(含めるもの)で書く: 新しいディレクトリを足すたびに一覧を直す必要があり、直し忘れると、コードの PR で層2 が黙って起動しない。除くもので書けば、直し忘れは層2 が余分に走る側に倒れる。

層2 の時間を縮める別の案(規模を試す層の単体テストを ReleaseSafe で走らせる。計画 0015 の追補の案 1)は、この ADR では扱わない。2026-10-24 に決め、[ADR-0047](0047-slow-unit-tests-default-to-releasesafe.md) で採った。

## 結果

- メリット: 文書だけの PR で、層2 と Preview(約 2 分)が走らなくなる。層2 は、1 実行のジョブ時間の合計で約 50 分、壁時計で約 33 分だった(2026-10-23 と 10-24 の実行。[ADR-0047](0047-slow-unit-tests-default-to-releasesafe.md) の ReleaseSafe 化の前の値)。2026-10-05 から 10-24 の実績に当てはめると、`docs/` のブランチの PR の層2 と Preview の分(約 1,350 分)が減る見込みである(見込み。ブランチ名で数えたので、文書だけでない `docs/` のブランチも含む。ADR-0047 の後は、層2 の1実行が短くなるので、減る分も小さくなる)。
- 公式文書で確かめたこと(2026-10-24。docs.github.com にはこの環境から到達できなかったので、そのソースである github/docs リポジトリの `main` を raw.githubusercontent.com から読んだ):
  - パスのフィルタは `push` と `pull_request` のイベントで評価される。変更したファイルがすべて `paths-ignore` に一致するときは、ワークフローは起動しない。1つでも一致しなければ起動する(`data/reusables/actions/workflows/triggering-a-workflow-paths1.md`、`triggering-a-workflow-paths3.md`)。
  - PR の変更ファイルは、3点の差分(トピックブランチの先頭と、ベースと最後に同期した点の比較)で求める。差分が 3,000 件(版によっては 300 件)を超え、一致するファイルがその中に無いときは起動しない(`triggering-a-workflow-paths5.md`)。
  - パスのフィルタでスキップされたワークフローのチェックは「Pending」のまま残り、それを必須にしている PR はマージできない(`content/actions/how-tos/manage-workflow-runs/skip-workflow-runs.md`)。
- デメリット・受け入れたトレードオフ:
  - 未確認のまま残る点。`pull_request` の `types: [ready_for_review]` と組み合わせたときにフィルタが効くことは、読んだ範囲に個別の記述が無い。`workflow_dispatch` にフィルタが効かないことは、フィルタが `push` と `pull_request` の下にだけ置けるキーであることからの推測で、明記は見つけていない。最初の文書だけの PR で確かめる手順を、計画 0015 の追補に書いた。
  - ブランチ保護で、層2 か Preview のジョブを必須のチェックにしていると、起動しない PR でチェックが保留のまま残り、マージできなくなる(上の公式文書の記述)。この ADR を入れた PR の独立レビューの担当は、その環境の読み取り API で、2026-10-24 の時点で `main` のブランチ保護は無く(API が 404)、ルールセットも空だった、と報告した。この PR を作った環境では、同じ API が 403 になり、確かめられていない。ブランチ保護の有無は、確認できていないものとして扱う。必須のチェックを足すときは、この ADR を見直す。
  - 文書だけの PR が、Windows でだけ表れる文書の検査の不具合を持ち込んでも、層2 では見つからない。次にコードの PR を ready にしたときに見つかる。
  - `preview.yml` の一覧が `full.yml` と同じであることは、検査していない。食い違うと、文書だけの PR で Preview だけが走るか、コードの PR で Preview だけが走らない。後者は成果物の添付が無くなるだけで、検証は止まらない。
  - リリースノート(`docs/releases/<タグ>.md`)だけを足す PR では、`dist` が走らない。ただし `full.yml` の `dist` ジョブはリリースノートを読まないので、リリースノートの有無と中身は、この決定の前から、タグの push で `release.yml` が走ったときに初めて確かめられる。この点は変わらない。
- 将来の見直し条件: 文書だけの PR で、層2 か Preview が起動したとき、または必須のチェックが保留のまま残ったとき。ブランチ保護に必須のチェックを足すとき。一覧に入れた種類のファイルを、ビルドかテストが読むようになったとき。
