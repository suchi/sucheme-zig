# ADR-0056: Web UI を GitHub Pages に、リリースの公開と手動の起動で配置する

- ステータス: 採用
- 日付: 2026-11-22
- 置き換え: [ADR-0021: no-github-pages-defer-hosting](0021-no-github-pages-defer-hosting.md) を非推奨とし、本ADRが最新の決定となる

> 2026-11-23 追記: 試験の配置の結果で、本ADRの「未確認」のうち、Content-Type とシークレットが確かめられ、保護規則は、`main` からの手動の起動が許された範囲だけが確かめられた(`release: published` の起動と、配置元の設定の画面の手順は、確かめていない)。決定は変わらない。リポジトリの設定(Pages の配置元を GitHub Actions にすること、環境 `github-pages` の保護規則)は、ユーザーが済ませた。`pages.yml` を、`main` のコミット `b65b484` に対して `workflow_dispatch` で起動した(実行 45125110732。`build` と `deploy` の2ジョブとも success)。公開の URL は `https://suchi.github.io/sucheme-zig/` である。
>
> - Content-Type: `sucheme.wasm` は `application/wasm`、`sucheme.js` は `application/javascript; charset=utf-8`、`index.html` は `text/html; charset=utf-8` で返る(2026-11-23 に、レスポンスのヘッダを取得して確かめた)。
> - シークレット: 新しい設定なしで成功した。使ったのは `GITHUB_TOKEN` とジョブごとの OIDC トークンだけである。
> - 保護規則: `main` からの手動の起動で、配置が許された。`release: published` の起動(ref がタグ)が許されるかは、まだ確かめていない。最初のリリースの公開で確かめる。
> - 手動の起動が任意のブランチから走れることと、配置元の設定の画面の手順は、確かめていない。
> - 公開の URL での動作: Chromium(Playwright)で、公開の URL と、同じ `main` から作った成果物をローカルで配ったものを開き、ページの全サンプル(11個)を実行して、出力と誤りの表示が一致することを確かめた。ページのエラー(例外とコンソールのエラー)は0件で、画面の版は `1.2.0-dev` だった。ほかのブラウザは確かめていない。なお、ローカルの `zig build wasm` が作った `sucheme.wasm` は 4507461 バイトで、公開のもの(後述)と 151 バイト違う。原因は調べていない(推測: ビルドの環境による差。出力は一致した)。
> - WASM の大きさ(決定4の測定): `sucheme.wasm` は、生で 4507612 バイト、`Accept-Encoding: gzip` で 1375972 バイトで返る(`Content-Length`、2026-11-23)。brotli を求めても、圧縮されずに返る。ReleaseSafe のビルドである。Unicode の表を含む現在の値である。この値を受けて、許容基準は、gzip の転送量で 2 MiB の上限(仮の値)に決まった。超えたときは、表の見直しを諮る(計画書 0030 の決定4)。配置の決定そのものは変わらない。
>
> 2026-11-23 追記: 配置の運用。サイトは、リリースの公開(`release: published`)と、手動の起動でだけ更新される。`main` への push では更新されない。このため、サイトの版は、最後の配置の時点のものである(画面のタイトルの横に版が出る)。リリース前の版が、手動の起動で載ることもある。利用者向けの文書は、[docs/manual/guide/06-web-ui.md](../manual/guide/06-web-ui.md) にある。

## 背景

[ADR-0021](0021-no-github-pages-defer-hosting.md) は、リポジトリが private である間、GitHub Pages を使わず、配置先を段階8まで選ばないと決めた。根拠は、Pages のサイトが、リポジトリを private にしても公開されることだった。リポジトリは public になった([ADR-0052](0052-repository-visibility-public-again.md))。この矛盾は無くなり、配置先の選定は、段階8の作業項目([plans/0030-phase8-web-ui.md](../plans/0030-phase8-web-ui.md)の決定1、スライス 8h-1)として残っていた。

ADR-0021 の配置先の要件のうち、「private にアクセス制限できる」は、public では必須でなくなった。残る要件は次の3つである。

- 静的ファイルの配信だけでよい([ADR-0009](0009-wasm-freestanding-and-zero-dependency-web-ui.md))。
- `application/wasm` の Content-Type で `.wasm` を返せる。
- `.wasm` を Web UI と同じオリジンから配れる。

## 決定

GitHub Pages を、GitHub Actions による配置(Pages の配置元を「GitHub Actions」にする方式)で使う。ワークフローは `.github/workflows/pages.yml` に置く。

- 起動: リリースの公開(`release: published`)と、手動の起動(`workflow_dispatch`)。main への push と PR では起動しない。実行分数の節約([AGENTS.md](../../AGENTS.md) の「Actions の分数」)と、公開される中身をリリースと食い違わせないための選択である。
- 中身: [preview.yml](../../.github/workflows/preview.yml) が成果物 `sucheme-web` に上げるものと同じ並び(`web/` の中身と `sucheme.wasm`)に、`LICENSE` と `THIRD-PARTY-NOTICES.txt` を足す。リリースの Web UI の zip([ADR-0034](0034-release-shape.md))も同じ2つのファイルを含む。公開する中身に第三者の表示が付くようにする。組み立ての手順は、`preview.yml` を変えずに済ませるため、`pages.yml` に写してある。
- 権限: 組み立てのジョブは `contents: read` だけで、配置のジョブだけが `pages: write` と `id-token: write` を持つ。配置は環境 `github-pages` を対象にする。
- シークレット: 新しいシークレットを置かない。使うのは `GITHUB_TOKEN` と、ジョブごとの OIDC トークンだけである。
- 外部のアクション: 公開から7日以上たった版を、コミット SHA で固定する([AGENTS.md](../../AGENTS.md) のセキュリティの節)。日付は、タグが指すコミットの日時を、公式リポジトリから取得して確かめた(2026-11-22)。

| アクション | 版 | コミット SHA | 日時 |
| --- | --- | --- | --- |
| `actions/upload-pages-artifact` | v5.0.0 | `fc324d3547104276b827a68afc52ff2a11cc49c9` | 2026-04-08 14:09 -0500 |
| `actions/deploy-pages` | v5.0.1 | `368f82528645a54fb793d4d04e342629a3f51346` | 2026-09-01 14:29 -0700 |

`actions/configure-pages` は使わない。この action は、静的サイトの生成ツールに、サイトの基点の URL などを渡すためのものである。このサイトは、`web/app.js` が `.wasm` を相対パスで取る作りで、生成ツールを持たないので、渡す先が無い。必要になったら足す。

ADR-0021 の次の決定は、本ADRでも変わらない。

- `web/` と `wasm32-freestanding` のビルドは、配置とは別に、ローカルで開けることで要件を満たす。`file://` で直接開けない理由と、`web/serve.mjs` を使う手段は、ADR-0021 の記述と [design/platform-and-web.md](../design/platform-and-web.md) のとおりである。
- PR ごとのプレビューは行わない。PR では、`preview.yml` の成果物を展開して確かめる。Pages は、PR の中身を載せない。

### 採らなかった案

- Cloudflare Pages と Azure Static Web Apps は、外部のアカウントと配置用のトークンが増える。新しいシークレットを増やす扱いを、別に諮る必要が生じる。Azure の利点だったアクセス制限は、public では要らない。
- main への push ごとに配置する案は、Actions の分数を消費し、公開の中身がリリースの版と食い違う。

## 結果

- メリット: 追加のサービスとアカウントが要らない。配置用のシークレットを増やさない。`.wasm` と Web UI が同じオリジンから配られる。
- デメリット・受け入れたトレードオフ: 公開の中身は、リリースの公開か手動の起動までは更新されない。Pages の配置元と環境 `github-pages` の保護規則は、リポジトリの設定で、このワークフローの外にある。手で設定が要る。
- 受け入れたトレードオフ(手動の起動の範囲): `workflow_dispatch` は、任意のブランチを選んで起動できる。環境 `github-pages` の保護規則が緩いと、feature ブランチの中身が公開される。緩和は、保護規則で、配置できるブランチとタグを、main とリリースのタグだけに明示することである(リポジトリの設定。ユーザーが行う。画面の手順は未確認)。`release: published` の起動は、ref がタグになるので、既定の保護規則が配置を拒む可能性がある(下の未確認)。
- 機械が固定していないこと: 起動の絞り込み(main への push と PR で起動しないこと)と、環境の保護規則は、機械が見ていない。`tools/check-docs` は、`pages.yml` のキーを受理するだけで、`on:` の中身を見ない。人の読みとレビューだけが守る。固定が要ると判断したときは、別のスライスで扱う([ADR-0026](0026-verify-facts-about-code-not-prose.md) の、検査ツールを育てすぎない方針による)。`pages.yml` のキーの受理が、検証のワークフローに紛れ込まないことは、`tools/review-harness/scenarios/pages-workflow.py` が、穴と対照とミューテーションで確かめる。
- 未確認(試験の配置で確かめ、結果を [plans/0030-phase8-web-ui.md](../plans/0030-phase8-web-ui.md) の進捗の表と、8h-1 の PR に残す):
  - 配置された `.wasm` の Content-Type が `application/wasm` であること。
  - 配置にシークレットが要らないこと。
  - リリースの公開と手動の起動から、環境の保護規則が配置を許すこと。保護規則の既定は、配置できるブランチやタグを制限することがある、という記憶がある。公式文書に届かないので、未確認である。
  - 配置元の設定の画面の手順。公式文書に届かず、確かめていない。
- 将来の見直し条件: 上の未確認の点が、前提と食い違ったとき。配置の頻度を変える(main への push ごとなど)とき。
