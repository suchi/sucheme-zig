# R7RS 準拠マトリクス

このファイルは生成物である。手で編集しない。`zig build report` で生成し、`zig build check-report` が生成し直した結果との一致を検査する。生成元は [tools/coverage-report/main.zig](../../tools/coverage-report/main.zig) である。

- 「束縛済み」は、その標準ライブラリを `import` したとき、その識別子が束縛される(手続き、または特殊形式)ことを指す。標準ライブラリは、実行ファイルに埋め込んだ `lib/` の `.sld` である。埋め込みに無いライブラリは、0 と数える。準拠を意味しない。たとえば算術は固定長整数だけで、仕様が求める数値塔はない。
- ここでいう「ライブラリ」は、`tests/r7rs-required/` の分け方、つまり R7RS 付録Aが定める標準ライブラリである。ライブラリごとに、何も束縛していない最上位でそのライブラリだけを `import` して数える。ほかのライブラリが束縛している名前は数えない。
- `(scheme r5rs)` は他のライブラリの識別子を再エクスポートする。このため、ライブラリごとの数は同じ識別子を重複して含み、その和は一意の識別子の合計と一致しない。

| ライブラリ | 束縛済み | 全体 |
| --- | ---: | ---: |
| `(scheme base)` | 164 | 238 |
| `(scheme case-lambda)` | 1 | 1 |
| `(scheme char)` | 0 | 22 |
| `(scheme complex)` | 0 | 6 |
| `(scheme cxr)` | 24 | 24 |
| `(scheme eval)` | 0 | 2 |
| `(scheme file)` | 0 | 10 |
| `(scheme inexact)` | 0 | 12 |
| `(scheme lazy)` | 5 | 5 |
| `(scheme load)` | 0 | 1 |
| `(scheme process-context)` | 0 | 5 |
| `(scheme r5rs)` | 0 | 222 |
| `(scheme read)` | 0 | 1 |
| `(scheme repl)` | 0 | 1 |
| `(scheme time)` | 0 | 3 |
| `(scheme write)` | 0 | 4 |
| 一意の識別子の合計 | 194 | 339 |
