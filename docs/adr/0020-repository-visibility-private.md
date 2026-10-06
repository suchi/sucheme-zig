# ADR-0020: リポジトリを private にする

- ステータス: 採用
- 日付: 2026-10-06
- 置き換え: [ADR-0012: repository-visibility-public](0012-repository-visibility-public.md) を非推奨とし、本ADRが最新の決定となる

## 背景

ADR-0012 はリポジトリを public にすると決め、段階0で実施した。実施後、ユーザーの判断で private に戻した。

公開の是非はリポジトリオーナーの判断であり、技術的な検討から導かれるものではない。本ADRは判断を記録し、その帰結を他の決定に反映するために書く。

## 決定

リポジトリを private にする。

公開を前提にしていた決定を見直した。可用性の主張はいずれも一次情報で確認した。

| 項目 | 帰結 |
| --- | --- |
| GitHub Pages | サイトは private リポジトリからでも公開できるが、公開されたサイト自体が private にはならない。private にした判断と両立しないので、配置先を変える([ADR-0021](0021-no-github-pages-defer-hosting.md)) |
| arm64 ランナー | 影響を受けない。arm64 の標準ランナーは private リポジトリでも使える。aarch64 をテスト対象に加えるかは可視性とは独立の判断で、[ADR-0010](0010-ci-cd-and-release-strategy.md) の範囲を変えない |
| ライセンス | MIT のまま変えない([ADR-0015](0015-mit-license.md))。private であってもライセンスファイルを置く意味は失われない。将来公開する場合に判断をやり直さずに済む |
| 外部スイートのライセンス | BSD 3条項の表示義務は再配布時に生じる。private のうちは配布していないが、記載は維持する([ADR-0013](0013-testing-strategy-and-conformance-suite.md)) |

Pages について確認した事実は3つである。1つ目、Free では public リポジトリに限られる。「If the account that owns the repository uses GitHub Free or GitHub Free for organizations, the repository must be public.」([Creating a GitHub Pages site](https://docs.github.com/en/pages/getting-started-with-github-pages/creating-a-github-pages-site))。2つ目、private リポジトリから公開した場合もサイトはインターネットに公開される。「GitHub Pages sites are publicly available on the internet, even if the repository for the site is private (if your plan or organization allows it).」(同)。3つ目、サイトをアクセス制限するには組織アカウントで Enterprise Cloud が必要である。「To publish a GitHub Pages site privately, your organization must use GitHub Enterprise Cloud.」([Changing the visibility of your GitHub Pages site](https://docs.github.com/en/enterprise-cloud@latest/pages/getting-started-with-github-pages/changing-the-visibility-of-your-github-pages-site))。本リポジトリは個人アカウントなので3つ目を満たせない。

arm64 については、2026-01-29 に private リポジトリでの提供が始まっている。「Linux and Windows arm64 standard hosted runners are now supported in all repositories.」「In private repositories, these runners have two vCPUs; in public repositories, they have four vCPUs.」「Because these are standard GitHub-hosted runners, usage counts towards the free minutes included in your plan.」([GitHub Changelog 2026-01-29](https://github.blog/changelog/2026-01-29-arm64-standard-runners-are-now-available-in-private-repositories/))。private 化が aarch64 の可否を変えるという想定は誤りだった。

Actions は private リポジトリでも動く。public では標準ランナーの実行分数が課金されないのに対し、private ではプランに含まれる分数に計上される。全コミットで走らせる検証を増やすときは使用量を見る。

## 結果

- メリット: ユーザーの意図に沿う。公開の判断を後からやり直せる。
- デメリット・受け入れたトレードオフ: Web UI の配置先を Pages 以外に用意する必要がある。Actions の実行分数がプランの枠に計上される。実装の参照先として公開できない。
- 将来の見直し条件: 公開する判断に変わった場合、本ADRを非推奨にして新ADRを書く。そのとき ADR-0021 の配置先の決定も見直す。
