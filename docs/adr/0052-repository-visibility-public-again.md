# ADR-0052: リポジトリを public にする

- ステータス: 採用
- 日付: 2026-11-21
- 置き換え: [ADR-0020: repository-visibility-private](0020-repository-visibility-private.md) を非推奨とし、本ADRが最新の決定となる

## 背景

[ADR-0020](0020-repository-visibility-private.md) は、リポジトリを private にすると決め、公開に転じる場合は ADR を非推奨にして新しい ADR を書くことを見直し条件としていた。リポジトリは public になり、v1.1.0 が公開された。本ADRは、その決定と、ADR-0020 の表に挙げた項目の技術的な帰結を記録する。

## 決定

リポジトリを public にする。

ADR-0020 の表の主な項目は、次のとおり変わる。

| 項目 | 帰結 |
| --- | --- |
| GitHub Pages | 使える。Free プランでは、public リポジトリに限って使える(ADR-0020 が引いた [Creating a GitHub Pages site](https://docs.github.com/en/pages/getting-started-with-github-pages/creating-a-github-pages-site) の記述)。ADR-0021 が Pages を使わない根拠にした「private にしたのにサイトだけ公開される」という矛盾は、無くなる。配置先は再決定しない。段階8の作業項目として残す |
| 標準ランナーの Actions の分数 | ADR-0020 は、public では標準ランナーの実行分数が課金されず、private ではプランに含まれる分数に計上される、と記録している。private での計上は、ADR-0020 が引いた [GitHub Changelog 2026-01-29](https://github.blog/changelog/2026-01-29-arm64-standard-runners-are-now-available-in-private-repositories/) の「Because these are standard GitHub-hosted runners, usage counts towards the free minutes included in your plan.」で確かめてある。public で課金されないことの原文は、本ADRの作成時に、この環境から公式文書へ届かなかったので、確かめていない。AGENTS.md の「Actions の分数」の規則の前提(月の枠に計上される)は、この記録のとおりなら、標準ランナーについては成り立たなくなる。規則を見直すかは、本ADRでは決めない |
| arm64 ランナー | 使える。vCPU は、private が2、public が4である(ADR-0020 が引いた [GitHub Changelog 2026-01-29](https://github.blog/changelog/2026-01-29-arm64-standard-runners-are-now-available-in-private-repositories/) の記述)。aarch64 を自動テストの対象に加えない理由のうち、分数の計上に依存する部分は、標準ランナーでは無くなる。対象に加えるかは再決定しない。[ADR-0033](0033-aarch64-built-but-not-tested.md) の決定は変わらない |
| リリース成果物 | GitHub Release の成果物を、アクセス権の無い人も取得できる |
| 準拠マトリクス | `docs/status/` にコミットした内容を、アクセス権の無い人も読める |
| issue と PR | 議論の内容を、アクセス権の無い人も読める。issue を、アクセス権の無い人も扱える範囲は、GitHub の既定の設定による |
| Copilot のコードレビュー | ADR-0020 は、private では実行が Actions の分数を消費すると記録している。公開後の消費がどうなるかは、確かめていない。依頼を自前のレビューの収束後に1回にする運用(AGENTS.md)は、変えない |
| 外部スイートのライセンス | BSD 3条項の表示義務は、再配布時に生じる(ADR-0020 の記録)。公開後は、成果物が誰にでも取得できる状態になる。表示は、これまでどおり維持する |
| ライセンス | MIT である([ADR-0050](0050-relicense-under-mit.md))。ADR-0050 が受け入れた「アクセスできる人が再配布できる」点は、公開によって、誰にでも当てはまる |

## 結果

- メリット: 標準ランナーの分数の制約が、無くなると見込まれる(上の表のとおり、public での扱いは未確認)。Pages が使える。成果物と準拠マトリクスを、アクセス権の無い人が取得、参照できる。
- デメリット・受け入れたトレードオフ: 開発の途中の状態と、issue、PR の議論が、誰にでも読める。シークレットの扱いに、一層の注意が要る。
- この ADR が決めないこと: AGENTS.md の「Actions の分数」の規則を見直すか。AGENTS.md のほかの分数に触れる記述(ファジングを全コミットの CI に入れない理由、`full.yml` の起動条件)も、この ADR では変えない。ワークフローの変更(層2 の起動条件など)を伴う案は、承認が要る。タグの保護([design/open-questions.md](../design/open-questions.md) の行に、公開に転じるときに設定を決めるとある)。Web UI の配置先(段階8)。
- 将来の見直し条件: 公開の範囲を変える判断になったとき、本ADRを非推奨にして新ADRを書く。
