# ADR-0021: GitHub Pages は使わず、Web UI の配置は計画の後半まで行わない

- ステータス: 採用
- 日付: 2026-10-06
- 置き換え: [ADR-0011: github-pages-pr-preview](0011-github-pages-pr-preview.md) を非推奨とし、本ADRが最新の決定となる

## 背景

ADR-0011 は `gh-pages` ブランチ方式で、リリース版・main・PR ごとのプレビューを配信すると決めた。前提は public リポジトリで GitHub Pages が無償で使えることだった。

[ADR-0020](0020-repository-visibility-private.md) でリポジトリを private にしたため、この前提が変わった。private リポジトリからでも Pages のサイトは公開できるが、公開されたサイト自体は private にならない。「GitHub Pages sites are publicly available on the internet, even if the repository for the site is private (if your plan or organization allows it).」([Creating a GitHub Pages site](https://docs.github.com/en/pages/getting-started-with-github-pages/creating-a-github-pages-site))。サイトをアクセス制限するには組織アカウントで Enterprise Cloud が必要であり、「To publish a GitHub Pages site privately, your organization must use GitHub Enterprise Cloud.」([Changing the visibility of your GitHub Pages site](https://docs.github.com/en/enterprise-cloud@latest/pages/getting-started-with-github-pages/changing-the-visibility-of-your-github-pages-site))。本リポジトリは個人アカウントなのでこれを満たせない。

つまり Pages を使うと、リポジトリを private にしたのに Web UI だけが公開される。ADR-0011 が前提にしていたのは公開して構わない成果物であり、その前提が成り立たなくなった。

あわせてユーザーから、配置は計画の後半でよく、どこかのクラウドに private に置ければ十分という判断を受けた。

## 決定

GitHub Pages を使わない。Web UI の配置は計画の後半まで行わない。

### Web UI そのものは残す

`web/` のサブプロジェクトと `wasm32-freestanding` のビルドは要件のまま残す。「いずれの段階でも簡単な Web の UI から実行できる仕組み」という要件は配置とは別のものであり、ローカルで開けることで満たす。[ADR-0009](0009-wasm-freestanding-and-zero-dependency-web-ui.md) の決定(freestanding、依存パッケージを持たない Web UI)は変えない。

ローカルで開く手段は、ブラウザが `file://` から `.wasm` を取得できない制約を受ける。`fetch` が同一オリジンポリシーで拒まれるためである。手段は段階1の計画で決める([design/open-questions.md](../design/open-questions.md))。候補は、`zig build` の step でローカルの HTTP サーバを立てる形と、`.wasm` をデータ URI として HTML に埋め込む形である。

### 配置は段階8で行う

配置先は段階8(Web UI の本格化)の作業とする。段階1から段階7では配置しない。

配置先のサービスは決めない。段階8の時点で選ぶ([design/open-questions.md](../design/open-questions.md))。要件は次の3つである。

- private にアクセス制限できる。
- 静的ファイルの配信だけでよい。サーバ側の実行環境を必要としない([ADR-0009](0009-wasm-freestanding-and-zero-dependency-web-ui.md) の依存ゼロの方針から、ビルド成果物は静的ファイルだけである)。
- `application/wasm` の Content-Type を返せる。`WebAssembly.instantiateStreaming` がこれを要求する。

シークレットを CI に持ち込む必要が生じる場合は、その時点で `AGENTS.md` のセキュリティの節に従い、扱いを決めてユーザーの承認を得る。段階7までシークレットを増やさない。

### PR ごとのプレビューは行わない

PR で動作を確認する手段は、CI の成果物として `sucheme.wasm` と `web/` を zip で添付する形にする。レビュアは zip を展開してローカルで開く。

ライブプレビューの URL は得られない。これは受け入れるトレードオフである。配置先が private である以上、PR ごとに URL を配っても外部のレビュアは開けない。

## 結果

- メリット: private リポジトリと両立する。シークレットを段階7まで増やさない。配置先の選定を、実際に配置したい時点の事情で決められる。`gh-pages` ブランチの履歴が膨らむ問題も起きない。
- デメリット・受け入れたトレードオフ: PR で URL を開いて確認できない。zip を展開してローカルサーバを立てる手間がレビュアに残る。配置先が未定のまま段階8まで進むので、段階8の作業量が見積もりにくい。
- 将来の見直し条件: リポジトリを public に戻す判断が出た場合、サイトが公開されることが問題でなくなるので、GitHub Pages と ADR-0011 の構成を再検討する。段階8より前に配置が必要になった場合、本ADRを非推奨にして新ADRを書く。
