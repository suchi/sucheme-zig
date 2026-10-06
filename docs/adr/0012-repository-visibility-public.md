# ADR-0012: リポジトリを public にする

- ステータス: ~~採用~~ 非推奨 → [ADR-0020: repository-visibility-private](0020-repository-visibility-private.md) に置き換え
- 日付: 2026-10-04

> 非推奨理由: 段階0で public にしたが、ユーザーの判断で private に戻した。公開の是非はリポジトリオーナーの判断である。

## 背景

要件として GitHub Pages での Web UI 公開が求められている。GitHub Pages を private リポジトリで公開するには GitHub Pro 以上の有料プランが必要である。また GitHub Actions の実行分数も、public リポジトリでは標準ランナーが無料枠の対象になる。

選択肢は次の3つだった。

- public にする。Pages と Actions と Copilot レビューの制約がなくなる。開発途中のコードが公開される。
- private のまま有料プランを使う。非公開を維持できるが課金が必要で、Actions の実行分数に上限がある。
- private のまま Pages を使わない。課金不要だが「PR 時に動作を試せる」「Pages で試せる」という要件を満たせない。

## 決定

リポジトリを public にする。段階0の作業として実施する。

R7RS Scheme の実装は公開して参照される価値があり、要件との相性も最も良い。

ライセンスの選択は本ADRでは決めない。public 化と同時に `LICENSE` ファイルを置く必要があるため、ライセンスの決定を段階0の前提条件とし、別のADRとして記録する。ライセンスを置かない public リポジトリは全権利保留と解釈されるため、公開の意図と矛盾する。

外部から取り込むテストスイートのライセンス(BSD 3条項)との両立を確認する([ADR-0013](0013-testing-strategy-and-conformance-suite.md))。

## 結果

- メリット: Pages、Actions、Copilot レビューがいずれも制約なく使える。PR ごとのプレビュー URL を無料で提供できる。実装の参照先として公開できる。
- デメリット・受け入れたトレードオフ: 開発途中の状態が公開される。issue や PR の議論も公開される。公開されている前提で、シークレットの取り扱いに一層の注意が必要になる。
- 将来の見直し条件: public から private への変更は、Pages と Actions の条件が変わるため実質的に行わない。行う場合は本ADRを非推奨にして新ADRを書く。
