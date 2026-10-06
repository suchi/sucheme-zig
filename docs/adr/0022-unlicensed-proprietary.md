# ADR-0022: ライセンスを付与せず UNLICENSED として非公開を明示する

- ステータス: 採用
- 日付: 2026-10-07
- 置き換え: [ADR-0015: mit-license](0015-mit-license.md) を非推奨とし、本ADRが最新の決定となる

## 背景

ADR-0015 は MIT ライセンスを採用した。前提は public リポジトリで、「ライセンスを置かない public リポジトリは全権利保留と解釈されるため、公開の意図と矛盾する」ことだった。

[ADR-0020](0020-repository-visibility-private.md) でリポジトリを private にした。ADR-0020 はその時点で「MIT のまま変えない。将来公開する場合に判断をやり直さずに済む」と帰結を書いたが、ユーザーの判断により、MIT をやめて非公開であることを明示する。

MIT を置いたままにすると、リポジトリにアクセスできる人は成果物を自由に再配布・改変・販売できる。private にした判断と組み合わせたときに、アクセス制限の意図とライセンスの許諾範囲が食い違う。公開するかどうかは権利者の判断であり、技術的な検討から導かれるものではない。

## 決定

ライセンスを付与しない。`LICENSE` には全権利保留と、いかなる許諾も与えないことを書く。

### 宣言の綴りを UNLICENSED とする

宣言の語は `UNLICENSED` とする。npm の `license` フィールドの慣行に従う。原文は「if you do not wish to grant others the right to use a private or unpublished package under any terms: `{ "license": "UNLICENSED" }`」である([npm Docs, package.json](https://docs.npmjs.com/cli/v11/configuring-npm/package-json))。SPDX の識別子ではなく、許諾を与えない場合の宣言としてこの語が使われている。

Unlicense(<https://unlicense.org/>)とは逆の意味である。Unlicense はパブリックドメインへの献呈であり、名前が似ているため取り違えると許諾範囲が正反対になる。`LICENSE` にこの区別を明記する。

Zig のマニフェスト(`build.zig.zon`)には 0.17.0 時点で `license` フィールドが無い。宣言の正は `LICENSE` であり、README がそれを参照する。機械が読む複製を増やさない。

### 第三者由来のものは対象外

`LICENSE` は sucheme-zig 自身の成果物に適用される。次は対象外で、それぞれの条件に従う。

- `tools/extract-r7rs-required/appendix-a.html`。R7RS 付録Aの逐語コピーで、R7RS 自身が全文または一部の複製を許諾している([SOURCE.md](../../tools/extract-r7rs-required/SOURCE.md))。
- 段階6で `tests/vendor/` に取り込む準拠スイート。BSD 3条項である([ADR-0013](0013-testing-strategy-and-conformance-suite.md))。

BSD 3条項は許諾の範囲が広く、プロプライエタリな成果物に取り込むことを禁じていない。表示義務は再配布時に生じる。private かつ無許諾のうちは再配布していないので義務は発生しないが、リリース成果物をアクセス権のある人に渡す経路があるため、記載は維持する([ADR-0020](0020-repository-visibility-private.md))。この方針は ADR-0013 から変わらない。

## 結果

- メリット: アクセス制限の意図とライセンスの許諾範囲が一致する。リポジトリにアクセスできる人が成果物を再配布できる状態をなくす。
- デメリット・受け入れたトレードオフ: 第三者が参照も利用もできない。オープンソースの処理系として扱われず、外部から貢献を受ける道が閉じる。公開に転じるときはライセンスの選定をやり直す必要がある。ADR-0015 が確認した BSD 3条項との両立の検討は、無許諾でも成り立つので無駄にはならない。
- 将来の見直し条件: 公開する判断に変わった場合、本ADRを非推奨にして新ADRを書き、ライセンスを選び直す。ADR-0015 が整理した制約(BSD 3条項との両立、R7RS 付録Aの扱い)はそのとき再利用できる。
