# ADR-0020: リポジトリを private にする

- ステータス: 採用
- 日付: 2026-10-06
- 置き換え: [ADR-0012: repository-visibility-public](0012-repository-visibility-public.md) を非推奨とし、本ADRが最新の決定となる

## 背景

ADR-0012 はリポジトリを public にすると決め、段階0で実施した。実施後、ユーザーの判断で private に戻した。

公開の是非はリポジトリオーナーの判断であり、技術的な検討から導かれるものではない。本ADRは判断を記録し、その帰結を他の決定に反映するために書く。

## 決定

リポジトリを private にする。

公開を前提にしていた決定のうち、次が影響を受ける。

| 影響を受けるもの | 帰結 |
| --- | --- |
| GitHub Pages | private リポジトリでは GitHub Enterprise Cloud でないと使えない。Web UI の配置先を変える([ADR-0021](0021-no-github-pages-defer-hosting.md)) |
| arm64 ランナー | 無償提供は public リポジトリに限られる。CI のテスト対象は x86_64 の2ランナーのまま([ADR-0010](0010-ci-cd-and-release-strategy.md)の範囲を変えない) |
| ライセンス | MIT のまま変えない([ADR-0015](0015-mit-license.md))。private であってもライセンスファイルを置く意味は失われない。将来公開する場合に判断をやり直さずに済む |
| 外部スイートのライセンス | BSD 3条項の表示義務は再配布時に生じる。private のうちは配布していないが、記載は維持する([ADR-0013](0013-testing-strategy-and-conformance-suite.md)) |

Actions は private リポジトリでも動く。使用量の無料枠が public より小さいため、全コミットで走らせる検証を増やすときは課金への影響を見る。

## 結果

- メリ: ユーザーの意図に沿う。公開の判断を後からやり直せる。
- デメリット・受け入れたトレードオフ: GitHub Pages が使えないため Web UI の配置先を別に用意する必要がある。arm64 ランナーが使えないため、aarch64 の動作保証は引き続き行わない。Actions の無料枠が小さい。実装の参照先として公開できない。
- 将来の見直し条件: 公開する判断に変わった場合、本ADRを非推奨にして新ADRを書く。そのとき ADR-0021 の配置先の決定も見直す。
