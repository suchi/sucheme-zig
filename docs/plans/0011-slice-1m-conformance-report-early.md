# 0011: スライス 1m の実装計画 — 準拠マトリクスの最小版を段階1に前倒しする

- 対応する決定: [ADR-0013](../adr/0013-testing-strategy-and-conformance-suite.md), [ADR-0018](../adr/0018-incremental-vertical-slices.md), [ADR-0026](../adr/0026-verify-facts-about-code-not-prose.md), [ADR-0027](../adr/0027-severity-by-consequence-and-a-cost-side-stop.md)
- 段階: 1(スライス 1m)。スライスの全体は [0003-phase1-minimal-slice.md](0003-phase1-minimal-slice.md) が正
- 日付: 2026-10-11
- 状態: 合意済み(2026-10-11)。後述の案Bを、勧める最小の形で承認した。`ci.yml` に `zig build check-report` を1行足すことも承認した。実装済みで、PR のレビュー待ち

## 解こうとしている問題

準拠マトリクス(`docs/status/conformance.md`)は、R7RS 付録Aの識別子のうちインタプリタがいくつ束縛しているかを表にした、進捗の生成物である。これまでの計画は、生成を段階3に置いていた([0003](0003-phase1-minimal-slice.md) の検証コマンドの追加)。突き合わせる相手の `lib/` のエクスポート節が段階3まで無いからである。

その間に、次の困りごとが残る。

- 段階1の残り(1k のプリミティブの拡充など)が、必須の識別子の分母に対して何を進めたのかを、リポジトリから読み取れない。進捗の単一の表は [roadmap.md](../roadmap.md) のチェックボックスだけで、識別子の単位では見えない。
- [0002](0002-phase0-scaffolding.md) は `report` と `check-report` を段階1で作る計画だった。実装は 1a で外し、段階3へ延ばした。計画書どうしが食い違ったままになっている。
- 準拠の分母は `tests/r7rs-required/*.txt` で既にある。インタプリタに識別子が束縛済みかを尋ねるだけで、`lib/` が無くても、意味のある数が出せる。

そこで、最小の形のマトリクスを段階1に前倒しする。

## 決定

案Bを、勧める最小の形で入れる。

- 入力は `tests/r7rs-required/*.txt` だけである。`lib/` のエクスポート節は読まない。
- 判定は、インタプリタに「その名前は束縛済みか」と尋ねる関数 `Interpreter.isBound`(`src/sucheme.zig`)で行う。大域環境の束縛か、展開器の特殊形式(`expand.isKeyword`)であれば真である。エラー文言の分類では代用しない。読まれただけでインターンされた名前は束縛ではない。
- 表は、ライブラリごとの「束縛済み」と「全体」、および一意の識別子の合計である。`(scheme r5rs)` は他のライブラリの識別子を再エクスポートするので、ライブラリごとの数の和は一意の合計と一致しない。生成物の冒頭にこのことを書く。
- 「束縛済み」は準拠を意味しない。たとえば算術は固定長整数だけである。これも生成物の冒頭に書く。
- 生成器は `tools/coverage-report/main.zig` である。既定の動作は比較で、`--write` を渡したときだけ書く。`zig build report` が書き、`zig build check-report` が比較する。既定を比較にした理由は [tools/extract-r7rs-required/main.zig](../../tools/extract-r7rs-required/main.zig) の冒頭にある。引数を1つ落とすだけで検査が書き換えに変わる穴を、最初から持たない。
- `check-report` は `build.zig` の `required_steps` に入れる。表と `ci.yml` の対の外にある、第3の点である。`check-extract` と同じ configure 段の検査(`checkStepRuns`。step が自分の run を実行し、終了コードが結果を決め、引数を取らないこと)を足す。
- CI には `zig build check-report` を1行だけ足す。`zig build report` は CI で実行しない。
- 生成物を更新する責任は、束縛を増やす PR にある。1k が入るとき、その PR が `zig build report` を実行して生成物を更新する。更新を忘れると `check-report` が落ち、直し方を標準エラーに出す。

数値を散文に書かない。束縛済みの数は表が正である。この計画書にも、他の文書にも、件数を書き写さない([AGENTS.md](../../AGENTS.md))。

重複の扱いも、この決定に含む。[tools/extract-r7rs-required/SOURCE.md](../../tools/extract-r7rs-required/SOURCE.md) の識別子数の合計は、`(scheme r5rs)` の再エクスポートを重複して数えている。それは抽出の件数として正しいままで、書き換えない。マトリクスは一意の合計を併記し、段階6で準拠スイートの結果の列を足すときに、重複を解いた形にする([roadmap.md](../roadmap.md) の段階6)。

## 選ばなかった案

以下の案の名前は、案Bを選んだときの比較に使った記号である。

- 案A: 計画どおり、段階3まで何も入れない。段階1から3の間、識別子の単位で進捗が読めない。0002 と 0003 の食い違いも残る。費用は最小だが、1k がプリミティブを増やしても、その効果を示す表がない。
- 案C: `lib/` のエクスポート節の読み取りまで含めて、完全な形を段階1で作る。突き合わせる `lib/` は段階2のライブラリシステムの後に初めて実在する。1e の時点で延期した理由と同じで、いま作ると、読み取る相手の無い解析器を書くことになる。
- 案D: 意味論テストの結果や準拠スイートの結果の列まで、段階1で入れる。これらの列は、テストの群や `r7rs-tests.scm` の取り込みが入るまで空である。空の列を持つ生成器と、その検査を、製品より先に育てることになる。[ADR-0026](../adr/0026-verify-facts-about-code-not-prose.md) と [ADR-0027](../adr/0027-severity-by-consequence-and-a-cost-side-stop.md) が戒める形である。

## 変更するファイル

| ファイル | 責務 | 変更 |
| --- | --- | --- |
| `src/sucheme.zig` | `Interpreter.isBound` とそのテスト | 変更 |
| `src/syntax/expand.zig` | `isKeyword`(特殊形式の名前の判定)とそのテスト | 変更 |
| `tools/coverage-report/main.zig` | 入力の読み取り、束縛済みの数え上げ、Markdown の生成、比較と書き込み | 新規 |
| `build.zig` | ツールの Compile、`report` と `check-report` の step、`required_steps` への追加、`checkStepRuns` | 変更 |
| `docs/status/conformance.md` | 生成物 | 新規 |
| `AGENTS.md` | 検証コマンド表に `check-report`(全コミット)と `report`(CI では「-」)の行 | 変更 |
| `.github/workflows/ci.yml` | `zig build check-report` を1行 | 変更(承認済み) |
| `docs/roadmap.md`、`docs/status/README.md`、`docs/design/r7rs-coverage.md`、`docs/onboarding.md`、`README.md`、`docs/plans/0003-phase1-minimal-slice.md`、`docs/plans/README.md` | 現在地と、段階1の形の記述 | 変更 |

## 検証

テストの層([0007](0007-test-tiers.md))の割り当て:

- 層1: `zig build test`(`isBound`、`isKeyword`、ツールの純粋な関数のテスト)、`zig build check-report`、`zig build check-docs`。`check-docs` が、表の行と `ci.yml` の対応を見る。
- ミューテーションテスト: `isBound` と `isKeyword`、ツールの数え上げと並べ替えを機械的に変えて、テストが落ちることを確かめた。`build.zig` の `check-report` について、step が run を持たない、引数を取る、終了コードが読まれない、の3つの編集で configure が止まることを確かめた。
- 手作業の確認: 生成物の数値を書き換える、生成物を消す、`tests/r7rs-required` から識別子を1つ消す、のそれぞれで `check-report` が落ちる。`ci.yml` から足した行を消すと `check-docs` が落ちる。
- Windows: 改行は `.gitattributes` が LF に固定する。ツールは `/` のパスだけを使う。CI の Windows のジョブで確かめる。作業した環境では確かめられない。

## 費用側の評価

[ADR-0027](../adr/0027-severity-by-consequence-and-a-cost-side-stop.md) の費用側の規則に従い、検査ツールを育てない線を先に引く。

- ツールは 200 行前後に収める。それを大きく超えるなら、範囲を狭める。
- 列は「束縛済み」と「全体」だけにする。列を足す変更は、その列の入力が実在する段階で行う。
- `lib/` を解析しない。ライブラリの定義を読む処理は、段階3で `lib/` のエクスポート節が実在してから足す。
- レビューが収束しないときは、次を上から順に外してやり残しに記録する。(1)一意の合計の行。(2)`check-report` の `checkStepRuns`(引数の個数の検査)。外しても、`check-report` が比較をすることと、CI がそれを走らせることは残る。

## 次にやること

1. この PR のレビューとマージ。
2. 1k の PR で、束縛が増えたあとに `zig build report` を実行して生成物を更新する。
3. 段階3で、`lib/` のエクスポート節を入力に足す。段階6で、準拠スイートの結果の列を足す([roadmap.md](../roadmap.md))。
