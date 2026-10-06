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

### 適用されるのは本変更以後の版である

本決定は、すでに与えた許諾を取り消すものではない。取り消せない。

リポジトリは 2026-10-04 から 2026-10-06 まで public であり([ADR-0020](0020-repository-visibility-private.md))、その期間の木には MIT の `LICENSE` が入っていた。MIT を追加したコミット `bcbc79c`(2026-10-04)は `main` の祖先である。MIT に終了条項は無いので、その期間に複製を得た者が受けた許諾は `LICENSE` の差し替えでは戻らない。

その期間に第三者が複製を得たかは確定できない。確認できた事実は次のとおりである。

- fork は 0 件である(2026-10-07 時点、GitHub API)。public から private に変えても fork は残る。「Current forks will remain public and will be detached from this repository.」([Setting repository visibility](https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/managing-repository-settings/setting-repository-visibility))。fork が 0 件であることは、fork 経由の複製が無いことを示す。
- clone の計数は 2026-10-04 に10件(uniques 2)、2026-10-05 に21件(uniques 2)である(GitHub の traffic API、14日分)。この計数には本プロジェクトの CI のチェックアウトと権利者自身の clone が含まれるため、第三者が複製を得たことを示すものではない。示せるのは、示せないということである。

したがって `LICENSE` には、本通知が本変更以後の版に適用され、すでに与えたものを撤回しないことを書く。「許諾を与えた状態をなくす」とは書かない。リポジトリ自身の履歴と矛盾するからである。

### 第三者由来のものは対象外

`LICENSE` は sucheme-zig 自身の成果物に適用される。次は対象外で、それぞれの条件に従う。

- `tools/extract-r7rs-required/appendix-a.html`。R7RS 付録Aの逐語コピーで、R7RS 自身が全文または一部の複製を許諾している([SOURCE.md](../../tools/extract-r7rs-required/SOURCE.md))。
- `tests/r7rs-required/*.txt`。上のコピーから機械抽出した R7RS の内容であり、同じ許諾に依拠する。各ファイルが2行目で出典を名乗っている。生成物だからといって R7RS 由来でなくなるわけではない。
- 段階6で `tests/vendor/` に取り込む準拠スイート。BSD 3条項である([ADR-0013](0013-testing-strategy-and-conformance-suite.md))。

非推奨にした ADR-0015 は「リポジトリ全体のライセンスが MIT であることと、`tests/vendor/` 以下が BSD 3条項であることを `tests/vendor/README.md` に明記する」という要件を持っていた。この要件を引き継ぐ。段階6で `tests/vendor/README.md` を書くとき、ADR-0013 が定める記録項目(取得元・コミットハッシュ・取得日・ライセンス名・ライセンス全文)に加えて、本 `LICENSE` がそのディレクトリを覆わないことを明記する。

BSD 3条項の条件は3つあり、再配布を条件とするのは第1と第2だけである。原文は次のとおり([The 3-Clause BSD License, Open Source Initiative](https://opensource.org/license/bsd-3-clause))。

> 1. Redistributions of source code must retain the above copyright notice, this list of conditions and the following disclaimer.
> 2. Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the following disclaimer in the documentation and/or other materials provided with the distribution.
> 3. Neither the name of the copyright holder nor the names of its contributors may be used to endorse or promote products derived from this software without specific prior written permission.

第3条項に再配布の限定が無い。したがって「private のうちは義務が発生しない」は第1と第2についてのみ成り立つ。第3条項は、準拠の達成を示す文面(リリースノート、`docs/status/` の準拠マトリクス、README)で chibi-scheme や維持者の名前を本処理系の裏づけとして用いることを制限する。出典として事実を述べることと、推奨・宣伝として用いることの線は段階6で引く([ADR-0013](0013-testing-strategy-and-conformance-suite.md) を更新する)。

許諾の範囲が広く、プロプライエタリな成果物への取り込みを禁じていない点は変わらない。第1と第2の表示は、private かつ無許諾のうちは再配布していないので発生しないが、リリース成果物をアクセス権のある人に渡す経路があるため記載は維持する([ADR-0020](0020-repository-visibility-private.md))。この方針は ADR-0013 から変わらない。

## 結果

- メリット: アクセス制限の意図とライセンスの許諾範囲が一致する。本変更以後の版について、リポジトリにアクセスできる人への許諾を与えない。
- デメリット・受け入れたトレードオフ: 第三者が参照も利用もできない。オープンソースの処理系として扱われず、外部から貢献を受ける道が閉じる。public だった期間の版に対する MIT の許諾は撤回できないので、ライセンスの状態が版によって2つに分かれる。公開に転じるときはライセンスの選定をやり直す必要がある。ADR-0015 が確認した BSD 3条項との両立の検討は、無許諾でも成り立つので無駄にはならない。
- 将来の見直し条件: 公開する判断に変わった場合、本ADRを非推奨にして新ADRを書き、ライセンスを選び直す。ADR-0015 が整理した制約(BSD 3条項との両立、R7RS 付録Aの扱い)はそのとき再利用できる。
