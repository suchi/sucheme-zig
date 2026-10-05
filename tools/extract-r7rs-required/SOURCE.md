# appendix-a.html の出典

`tests/r7rs-required/*.txt` を生成するための入力。手で編集しない。

| 項目 | 値 |
| --- | --- |
| 取得元 | <https://standards.scheme.org/corrected-r7rs/r7rs-Z-H-10.html> |
| 内容 | R7RS 誤記修正版 HTML の付録A(Standard Libraries) |
| 取得日 | 2026-10-06 |
| サイズ | 67,552 バイト |
| 抽出プログラム | [main.zig](main.zig) |

ネットワークから取得せずリポジトリに置くのは、再現可能なビルドを保ち、抽出結果を後から検証できるようにするためである([ADR-0013](../../docs/adr/0013-testing-strategy-and-conformance-suite.md))。

[docs/design/r7rs-coverage.md](../../docs/design/r7rs-coverage.md) と [docs/onboarding.md](../../docs/onboarding.md) が挙げている `https://standards.scheme.org/corrected-r7rs/r7rs.html` は分割 HTML の表紙であり、識別子を1件も含まない。付録Aは上の URL にある。

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

1. 上の URL からページを取得して `appendix-a.html` を置き換える。
2. 本ファイルの取得日とサイズを更新する。取得日はここだけに書く。生成されるファイルは本ファイルを参照するだけなので、更新箇所は1つである。
3. R7RS の版が変わってライブラリ数が16でなくなった場合は、`main.zig` の `expected_library_count` を更新する。同じ数が報告と検査の両方に使われる。
4. `zig run tools/extract-r7rs-required/main.zig` を実行する。
5. 報告されたライブラリ数と識別子数を上の表に反映する。
6. `tests/r7rs-required/*.txt` の差分をレビューする。識別子の増減は準拠マトリクスに直接影響する。
