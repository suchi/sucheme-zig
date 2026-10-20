# 取り込んだ第三者のファイル

このディレクトリには、外部の準拠テストスイートを、改変せずに置く。取り込みの方針は [ADR-0013](../../docs/adr/0013-testing-strategy-and-conformance-suite.md) にあり、取り込みの計画は [docs/plans/0020-conformance-harness-early.md](../../docs/plans/0020-conformance-harness-early.md) にある。

## ライセンス

リポジトリの根の `LICENSE`(UNLICENSED、[ADR-0022](../../docs/adr/0022-unlicensed-proprietary.md))は、このディレクトリのファイルを覆わない。このディレクトリのファイルには、同梱した許諾文が適用される。

| ファイル | 許諾 |
| --- | --- |
| `r7rs-tests.scm` | `COPYING`(chibi-scheme のリポジトリの根にある許諾文。BSD 3条項の形) |
| `COPYING` | 同上(許諾文そのもの) |
| `README.md` | この記録は sucheme-zig 自身の文書で、根の `LICENSE` に従う |

`r7rs-tests.scm` の中には、著作権表示と許諾の文が無い。上流のリポジトリの根の `COPYING` が、このファイルを覆うと読んで、同じ版の `COPYING` を同梱した。上流がそう明言しているかは、確かめていない(未確認)。

## 取得の記録

| 項目 | 内容 |
| --- | --- |
| 取得元のリポジトリ | <https://github.com/ashinn/chibi-scheme> |
| 上流の中のパス | `tests/r7rs-tests.scm` と `COPYING` |
| コミット | `b2087f3a320a56f79ede5c546fd45fdde582c4ed` |
| コミットの日時 | 2026-10-12 21:43:53 +0900 |
| 取得日 | 2026-10-20 |
| ライセンスの名前 | BSD 3条項の形(著作権表示は「Copyright (c) 2009-2021 Alex Shinn」) |
| 同梱した許諾文 | `COPYING` |

取得の時点で、このコミットは上流の `master` の先頭だった(`git ls-remote https://github.com/ashinn/chibi-scheme.git refs/heads/master`)。コミットから7日以上たった版を選ぶ規則([AGENTS.md](../../AGENTS.md) の「手で固定する外部依存」)を満たしている。

## ハッシュ

取り込んだファイルの SHA-256 である。準拠スイートの実行器(スライス 6e、`tools/conformance-run/`)ができたら、値の正は実行器の定数に移し、ここからは値を消して、定数の場所だけを書く。同じ値を2か所に置かないためである。

| ファイル | SHA-256 |
| --- | --- |
| `r7rs-tests.scm` | `004d215a38f990bbf2bfaa8b4a395aa59ef98d155096f8e31cc361b7812f7d6a` |
| `COPYING` | `86805fe7af1bd20d5f5050d86c61d6fe038452cb08c6106a08761e010d37da43` |

確かめ方: `sha256sum tests/vendor/r7rs-tests.scm tests/vendor/COPYING`。

## 改変しないこと

取り込んだファイル(`r7rs-tests.scm` と `COPYING`)は、改変しない。処理系の制約で実行できない部分は、ファイルを書き換えずに、除外の一覧(別のファイル。スライス 6e で置く)で扱う。

## 更新の手順

1. 上流の `master` のうち、コミットから7日以上たった版を選ぶ。コミットの日時は、`https://github.com/ashinn/chibi-scheme/commit/<SHA>.patch` の `Date:` の行で確かめる。
2. その版の `tests/r7rs-tests.scm` と `COPYING` を、`https://raw.githubusercontent.com/ashinn/chibi-scheme/<SHA>/<パス>` から取得して、このディレクトリのファイルを置き換える。
3. 差分をレビューする。`COPYING` が変わっていたら、許諾の条文を読み直し、[ADR-0022](../../docs/adr/0022-unlicensed-proprietary.md) と第3条項の ADR の前提が変わっていないかを確かめる。
4. この README の「取得の記録」と、ハッシュ(上の表、または実行器の定数)を、同じコミットで更新する。
