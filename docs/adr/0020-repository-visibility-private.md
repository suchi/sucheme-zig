# ADR-0020: リポジトリを private にする

- ステータス: ~~採用~~ 非推奨 → [ADR-0052: repository-visibility-public-again](0052-repository-visibility-public-again.md) に置き換え
- 日付: 2026-10-06
- 置き換え: [ADR-0012: repository-visibility-public](0012-repository-visibility-public.md) を非推奨とし、本ADRが最新の決定となる

> 非推奨理由: リポジトリが public になった。本ADRの「将来の見直し条件」(公開に転じた場合)に当たる。

> 2026-10-07 追記: 本ADRの決定(リポジトリを private にする)は変わらない。以下の影響表はライセンスについて「MIT のまま変えない」と書いているが、その後 MIT をやめて許諾を与えないことになった([ADR-0022](0022-unlicensed-proprietary.md))。MIT のままではアクセスできる人が成果物を再配布できるため、private にした意図と食い違うという判断である。外部スイートのライセンスの行は変わらない。BSD 3条項はプロプライエタリな成果物への取り込みを禁じていない。表示義務は再配布時に生じるが、名前の宣伝利用の制限は再配布に依らない。条文の数と文面は変種によって違うので、義務の数え上げは取り込む版の許諾文で行う([ADR-0022](0022-unlicensed-proprietary.md))。

## 背景

ADR-0012 はリポジトリを public にすると決め、段階0で実施した。実施後、private に戻した。

本ADRは、この決定を記録し、その帰結を他の決定に反映するために書く。

## 決定

リポジトリを private にする。

公開を前提にしていた決定を見直した。可用性の主張はいずれも一次情報で確認した。

| 項目 | 帰結 |
| --- | --- |
| GitHub Pages | サイトは private リポジトリからでも公開できるが、公開されたサイト自体が private にはならない。private にした判断と両立しないので、配置先を変える([ADR-0021](0021-no-github-pages-defer-hosting.md)) |
| arm64 ランナー | 使えるかどうかは影響を受けない。arm64 の標準ランナーは private リポジトリでも使える。ただし private では実行分数がプランの枠に計上されるので、対象に加えない理由の一部は可視性に依存する。理由と見直しの時点は [ADR-0010](0010-ci-cd-and-release-strategy.md) の追記が持つ。本ADRの見直し(公開に転じる判断)はその理由の一方を消すので、そのとき ADR-0010 もあわせて見直す |
| Copilot のコードレビュー | private でも使える。ただしレビューの実行が Actions の分数をプランの枠から消費する。依頼は自前のレビューが収束してから1回にする(`AGENTS.md`、[ADR-0023](0023-mandatory-zero-convergence.md)) |
| 準拠マトリクス | 公開はしない。`docs/status/` にコミットし、リポジトリにアクセスできる人が見る形にする([design/r7rs-coverage.md](../design/r7rs-coverage.md)) |
| リリースの配布 | GitHub Release は private リポジトリでも作れるが、取得できるのはアクセス権のある人だけである。第三者への配布は公開するまで行わない |
| ライセンス | MIT のまま変えない([ADR-0015](0015-mit-license.md))。private であってもライセンスファイルを置く意味は失われない。将来公開する場合に判断をやり直さずに済む |
| 外部スイートのライセンス | BSD 3条項の表示義務は再配布時に生じる。private のうちは配布していないが、記載は維持する([ADR-0013](0013-testing-strategy-and-conformance-suite.md)) |

Pages について確認した事実は3つである。1つ目、Free では public リポジトリに限られる。「If the account that owns the repository uses GitHub Free or GitHub Free for organizations, the repository must be public.」([Creating a GitHub Pages site](https://docs.github.com/en/pages/getting-started-with-github-pages/creating-a-github-pages-site))。2つ目、private リポジトリから公開した場合もサイトはインターネットに公開される。「GitHub Pages sites are publicly available on the internet, even if the repository for the site is private (if your plan or organization allows it).」(同)。3つ目、サイトをアクセス制限するには組織アカウントで Enterprise Cloud が必要である。「To publish a GitHub Pages site privately, your organization must use GitHub Enterprise Cloud.」([Changing the visibility of your GitHub Pages site](https://docs.github.com/en/enterprise-cloud@latest/pages/getting-started-with-github-pages/changing-the-visibility-of-your-github-pages-site))。本リポジトリは個人アカウントなので3つ目を満たせない。

arm64 については、2026-01-29 に private リポジトリでの提供が始まっている。「Linux and Windows arm64 standard hosted runners are now supported in all repositories.」「In private repositories, these runners have two vCPUs; in public repositories, they have four vCPUs.」「Because these are standard GitHub-hosted runners, usage counts towards the free minutes included in your plan.」([GitHub Changelog 2026-01-29](https://github.blog/changelog/2026-01-29-arm64-standard-runners-are-now-available-in-private-repositories/))。private 化が aarch64 の可否を変えるという想定は誤りだった。

Copilot については2点を確認した。プランの条件は「This is available on the Copilot Pro, Copilot Pro+, and Copilot Max plans, and with a Copilot Business or Copilot Enterprise license.」([About GitHub Copilot code review](https://docs.github.com/en/copilot/concepts/agents/code-review))。分数の扱いは「Actions minutes are consumed from your account or organization's existing plan entitlement for reviews on private repositories, with any usage beyond your included minutes billed at standard GitHub Actions rates.」([Configuring runners for GitHub Copilot code review](https://docs.github.com/en/copilot/how-tos/copilot-on-github/set-up-copilot/configure-runners))。2026-10-04 に Copilot Pro の上限の90%に達した経緯があるので、依頼を1回に抑える運用の根拠が1つ増えた。

Actions は private リポジトリでも動く。public では標準ランナーの実行分数が課金されないのに対し、private ではプランに含まれる分数に計上される。全コミットで走らせる検証を増やすときは使用量を見る。

非推奨にした ADR-0012 が public の利点として挙げていたのは Pages・Actions・Copilot レビューの3つである。上の表はその3つに加えて、公開を前提にしていた準拠マトリクスの公開とリリースの配布を含む。

## 結果

- メリット: 公開の判断を後からやり直せる。
- デメリット・受け入れたトレードオフ: Web UI の配置先を Pages 以外に用意する必要がある。Actions の実行分数がプランの枠に計上され、Copilot のレビューもそこから消費する。準拠マトリクスとリリース成果物はアクセス権のある人にしか届かない。実装の参照先として公開できない。
- 将来の見直し条件: 公開する判断に変わった場合、本ADRを非推奨にして新ADRを書く。そのとき ADR-0021 の配置先の決定も見直す。
