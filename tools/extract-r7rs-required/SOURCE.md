# appendix-a.html の出典

`tests/r7rs-required/*.txt` を生成するための入力。手で編集しない。

| 項目 | 値 |
| --- | --- |
| 取得元 | <https://standards.scheme.org/corrected-r7rs/r7rs-Z-H-10.html> |
| 内容 | R7RS 誤記修正版 HTML の付録A(Standard Libraries) |
| 取得日 | 2026-10-06 |
| サイズ | 67,552 バイト |
| 入力の SHA-256 | `d20241aed9d26e0f32644040359613ab4fde27fc69a154042b5bf7bc6629e47b` |
| 抽出プログラム | [main.zig](main.zig) |

ネットワークから取得せずリポジトリに置くのは、再現可能なビルドを保ち、抽出結果を後から検証できるようにするためである([ADR-0013](../../docs/adr/0013-testing-strategy-and-conformance-suite.md))。

[docs/design/r7rs-coverage.md](../../docs/design/r7rs-coverage.md) と [docs/onboarding.md](../../docs/onboarding.md) が挙げている `https://standards.scheme.org/corrected-r7rs/r7rs.html` は分割 HTML の表紙であり、識別子を1件も含まない。付録Aは上の URL にある。

## 抽出結果の固定

`tests/r7rs-required/*.txt` は生成物であり手で編集しない。入力のハッシュだけではこれを守れない。`appendix-a.html` を変えずに `base.txt` から識別子を削っても、入力のハッシュは一致したままである。実際に `dynamic-wind` と `call-with-current-continuation` を削って作り物の名前を1つ足したところ、検証コマンドはすべて通った。これらのファイルは段階6で準拠マトリクスの分母になる。

16ファイルをまとめた1つのハッシュで固定し、`zig build check-docs` が照合する。1ファイルずつ記録しないのは、再抽出のときに更新する値を1つに保つためである。

ファイル名と内容をそれぞれ長さ付きでハッシュする。これで読み方が1通りに定まり、ファイルの追加・削除・改名と、ファイル境界をまたいだ内容の移動が値を変える。単純に連結するだけでは足りない。境界に区切りがないと、`lazy.txt` の名前と内容を `inexact.txt` の末尾に書き写して `lazy.txt` を消しても値が変わらず、16ファイルが15ファイルになって `(scheme lazy)` の5識別子が `(scheme inexact)` のものになる。`check-docs` はこのディレクトリに `*.txt` 以外のものが無いことも検査する。記録が覆う範囲とディレクトリの中身を一致させるためである。

| 項目 | 値 |
| --- | --- |
| 抽出結果の SHA-256 | `100125a808eec8a246837c4911e7728623cba534db565ff12866a0ffc27bae13` |

記録と一致しないとき、`zig build check-docs` は計算した値を全桁表示する。再抽出したあとはその値をここに貼り替える。

## 複製の許諾

R7RS は全文または一部の複製を許諾している。Introduction の Background 節の原文。

> We intend this report to belong to the entire Scheme community, and so we grant permission to copy it in whole or in part without fee.

出典: <https://standards.scheme.org/corrected-r7rs/r7rs-Z-H-2.html>

本リポジトリのライセンス([LICENSE](../../LICENSE))は sucheme-zig 自身の成果物に適用されるものであり、このファイルには適用されない。

## 抽出結果

| ライブラリ | 識別子数 | ライブラリ | 識別子数 |
| --- | --- | --- | --- |
| `(scheme base)` | 238 | `(scheme load)` | 1 |
| `(scheme case-lambda)` | 1 | `(scheme process-context)` | 5 |
| `(scheme char)` | 22 | `(scheme read)` | 1 |
| `(scheme complex)` | 6 | `(scheme repl)` | 1 |
| `(scheme cxr)` | 24 | `(scheme time)` | 3 |
| `(scheme eval)` | 2 | `(scheme write)` | 4 |
| `(scheme file)` | 10 | `(scheme r5rs)` | 222 |
| `(scheme inexact)` | 12 | 合計 | 557 |
| `(scheme lazy)` | 5 | | |

`(scheme r5rs)` が R5RS のほぼ全体を再エクスポートするため、`(scheme base)` の 238 は他15ライブラリの合計 319 を下回る。「`(scheme base)` が最大」という形の妥当性検査は成立しない。

## 再抽出の手順

R7RS の版が上がった場合、または誤記修正が入った場合に行う。

ハッシュを記録するのは、入力が「corrected-r7rs」すなわち誤記修正が入り続ける生きた版であり、サイズだけでは改変を検出できないためである。[ADR-0013](../../docs/adr/0013-testing-strategy-and-conformance-suite.md) は取り込んだファイルを改変しないことを求めており、その検証手段がこれである。`zig build check-docs` が本ファイルの記録と実物を照合する。入力と抽出結果の両方を照合するので、記録は2つある。

### 手順

1. 上の URL からページを取得して `appendix-a.html` を置き換える。
2. 本ファイルの取得日・サイズ・入力の SHA-256 を更新する。取得日はここだけに書く。入力のハッシュは次で求める。

   ```
   $ sha256sum tools/extract-r7rs-required/appendix-a.html
   ```

3. R7RS の版が変わってライブラリ数が16でなくなった場合は、`main.zig` の `expected_library_count` を更新する。同じ数が報告と検査の両方に使われる。
4. `zig run tools/extract-r7rs-required/main.zig` を実行する。
5. 報告されたライブラリ数と識別子数を上の表に反映する。`zig build check-docs` が表の各行と合計を実物と照合するので、忘れると赤になる。
6. `zig build check-docs` を実行し、報告された抽出結果の SHA-256 を「抽出結果の固定」の表に貼り替える。
7. `tests/r7rs-required/*.txt` の差分をレビューする。識別子の増減は準拠マトリクスに直接影響する。
8. サイズと識別子数を引用している文書を更新する。[docs/plans/0002-phase0-scaffolding.md](../../docs/plans/0002-phase0-scaffolding.md) は入力の選定を裏づける実測として、[docs/roadmap.md](../../docs/roadmap.md) は段階0の到達点としてこれらの数を書いている。どちらも段階0の記録なので、値が変わったことを追記する形でよい。

### ADR-0013 の記録項目との対応

[ADR-0013](../../docs/adr/0013-testing-strategy-and-conformance-suite.md) は `tests/vendor/` に置く外部スイートを対象に、取得元のリポジトリ・取得時のコミットハッシュ・取得日・ライセンス名の記録と、ライセンス全文の同梱を求めている。本ファイルの対応は次のとおりで、そのまま対応するのは取得日だけ、残る4点は形を変えている。

| ADR-0013 の項目 | 本ファイル |
| --- | --- |
| 取得元のリポジトリ | 取得元の URL。R7RS はリポジトリとして配布されていない |
| 取得時のコミットハッシュ | 内容のハッシュ。版管理されていない静的ページなのでコミットが存在しない |
| 取得日 | あり |
| ライセンス名 | 名前のあるライセンスではないため、複製の許諾の原文を引用する |
| ライセンス全文の同梱 | 許諾は R7RS 本文の一部であり、`appendix-a.html` と同じ文書に含まれる |

置き場所も `tests/vendor/` ではなく `tools/extract-r7rs-required/` である。これは抽出プログラムの入力であってテストスイートではないため、使う場所の隣に置いた。

段階6で `r7rs-tests.scm` を取り込むときは ADR-0013 の形をそのまま使う。2つの記録形式が併存することになるので、そのときに新ADRを書いて両方の形を定める。ADR の運用ルールにより既存ADRの本文は書き換えられない([docs/adr/README.md](../../docs/adr/README.md))。
