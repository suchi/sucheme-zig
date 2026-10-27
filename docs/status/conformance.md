# R7RS 準拠マトリクス

このファイルは生成物である。手で編集しない。`zig build report` で生成し、`zig build check-report` が生成し直した結果との一致を検査する。生成元は [tools/coverage-report/main.zig](../../tools/coverage-report/main.zig) である。

- 「束縛済み」は、その標準ライブラリを `import` したとき、その識別子が束縛される(手続き、または特殊形式)ことを指す。標準ライブラリは、実行ファイルに埋め込んだ `lib/` の `.sld` である。埋め込みに無いライブラリは、0 と数える。準拠を意味しない。たとえば算術は固定長整数だけで、仕様が求める数値塔はない。
- ここでいう「ライブラリ」は、`tests/r7rs-required/` の分け方、つまり R7RS 付録Aが定める標準ライブラリである。ライブラリごとに、何も束縛していない最上位でそのライブラリだけを `import` して数える。ほかのライブラリが束縛している名前は数えない。
- `(scheme r5rs)` は他のライブラリの識別子を再エクスポートする。このため、ライブラリごとの数は同じ識別子を重複して含み、その和は一意の識別子の合計と一致しない。

| ライブラリ | 束縛済み | 全体 |
| --- | ---: | ---: |
| `(scheme base)` | 202 | 238 |
| `(scheme case-lambda)` | 1 | 1 |
| `(scheme char)` | 0 | 22 |
| `(scheme complex)` | 6 | 6 |
| `(scheme cxr)` | 24 | 24 |
| `(scheme eval)` | 0 | 2 |
| `(scheme file)` | 0 | 10 |
| `(scheme inexact)` | 12 | 12 |
| `(scheme lazy)` | 5 | 5 |
| `(scheme load)` | 0 | 1 |
| `(scheme process-context)` | 0 | 5 |
| `(scheme r5rs)` | 0 | 222 |
| `(scheme read)` | 0 | 1 |
| `(scheme repl)` | 0 | 1 |
| `(scheme time)` | 0 | 3 |
| `(scheme write)` | 0 | 4 |
| 一意の識別子の合計 | 250 | 339 |

## 準拠スイートの結果

取り込んだ準拠スイート `tests/vendor/r7rs-tests.scm` を、節ごとに走らせた結果である。取り込んだ版は [tests/vendor/README.md](../../tests/vendor/README.md) にある。分類の定義は [docs/plans/0020-conformance-harness-early.md](../plans/0020-conformance-harness-early.md) の「分類」にあり、落ちたものと走らせなかったものの一覧は `zig build test-conformance` が出す。

- 「通った」と「落ちた」はテストの数である。ほかの列は、走らせなかったか、それ自体が誤りを上げた最上位の形式の数である。ただし「連鎖」は、同じ外側の節(入れ子の節を含む)に評価しなかったか誤りで終わった形式があるときにテストの中で上がった未束縛の誤りを、テストの数で含む。単位が違うので足さない。
- 入れ子の節(「Read syntax」と「Numeric syntax」)は、親の節(6.13)と別の行に数える。

| 節 | 通った | 落ちた | 誤り | 読めない | 未実装 | 連鎖 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 4.1 Primitive expression types | 27 | 0 | 0 | 0 | 0 | 0 |
| 4.2 Derived expression types | 70 | 4 | 0 | 0 | 0 | 0 |
| 4.3 Macros | 26 | 0 | 0 | 0 | 0 | 0 |
| 5 Program structure | 15 | 0 | 0 | 0 | 0 | 0 |
| 6.1 Equivalence Predicates | 25 | 0 | 0 | 0 | 0 | 0 |
| 6.2 Numbers | 193 | 26 | 0 | 0 | 0 | 0 |
| 6.3 Booleans | 18 | 0 | 0 | 0 | 0 | 0 |
| 6.4 Lists | 64 | 0 | 0 | 0 | 1 | 0 |
| 6.5 Symbols | 17 | 0 | 0 | 0 | 0 | 0 |
| 6.6 Characters | 20 | 0 | 0 | 0 | 59 | 0 |
| 6.7 Strings | 78 | 0 | 0 | 0 | 52 | 0 |
| 6.8 Vectors | 43 | 0 | 0 | 0 | 0 | 0 |
| 6.9 Bytevectors | 39 | 0 | 0 | 0 | 0 | 0 |
| 6.10 Control Features | 31 | 0 | 0 | 0 | 3 | 0 |
| 6.11 Exceptions | 17 | 0 | 0 | 0 | 10 | 0 |
| 6.12 Environments and evaluation | 0 | 0 | 0 | 0 | 4 | 0 |
| 6.13 Input and output | 1 | 0 | 0 | 0 | 59 | 0 |
| Read syntax | 0 | 0 | 0 | 0 | 72 | 24 |
| Numeric syntax | 0 | 0 | 0 | 0 | 2 | 110 |
| 6.14 System interface | 2 | 0 | 0 | 0 | 10 | 0 |
| 合計 | 686 | 30 | 0 | 0 | 272 | 134 |

スイートが `import` するライブラリのうち、解決できなかったもの: `(scheme char)` `(scheme time)` `(scheme file)` `(scheme read)` `(scheme write)` `(scheme eval)` `(scheme process-context)` `(scheme r5rs)`
