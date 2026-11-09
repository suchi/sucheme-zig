# 3 REPL

引数なしで `sucheme` を起動すると、REPL(read-eval-print loop)になります。式を1つ読み、評価し、値を出す、という繰り返しです。

## 式を打つ

プロンプトは `> ` です。式を打って Enter を押すと、次の行に値が出ます。次の図は、端末での見え方です。この対話は `check-examples` の検査の外にあります(検査は標準入力を渡して実行ファイルを走らせません)。入力の行は、実行ファイルに式を流し込んだ出力から、端末が表示する形に組み立てたものです。

```text
$ sucheme
> (+ 1 2)
3
> (define (twice x)
... (* x 2))
> (twice 21)
42
> (car 5)
error: wrong type of argument to car 5
> (twice 1)
2
```

次のことが、上の対話から分かります。

- 定義は何も出力しません。
- 式が閉じていない行(括弧が足りない行)で Enter を押すと、プロンプトが `... ` に変わり、続きを待ちます。閉じたところで、溜めた入力の全体を評価します。継続行をやめる方法はありません。
- 誤りは `error: ` に続けて説明が出て、その式の評価だけが終わります。REPL は止まらず、次の式を読みます。

`check-examples` は、REPL と同じ評価の入口で、コードブロックの出力を確かめています。次のコードブロックは、REPL に1行ずつ打ったときと同じ値を出します。

```scheme
(define x 5)
(* x x)
"a string"
(values 1 2)
(values)
```

```output
25
"a string"
1
2
```

値が複数のときは1行に1つずつ、0 個なら何も出ません。

## 使えるものは `(scheme base)` だけ

REPL の最初の環境は `(scheme base)` です。`display` や `exit` のように、ほかのライブラリにあるものは、`import` してから使います。

```scheme fresh
(display "hi")
```

```output
error: unbound variable: display
```

```scheme
(import (scheme write))
(display "hi")
(newline)
```

```output
hi
```

`display` を `import` する前の呼び出しは `unbound variable` の誤りです。どのライブラリに何があるかは [5 ライブラリ](05-libraries.md) を見てください。

## 終わり方

標準入力を閉じると終わります。Unix 系の端末では Ctrl-D です(Windows での操作は、この文書では確かめていません)。`(import (scheme process-context))` のあとで `(exit)` を呼んでも終わります。

```text
> (import (scheme process-context))
> (exit 7)
```

`exit` の引数が、`sucheme` の終了コードになります。式の途中で標準入力が尽きたときは、`error: unexpected end of input` を出して終わります。

## 入力の長さの上限

溜めている入力(継続行を含む)の合計は、改行を入れて 65536 バイトまでです。超えると `error: the input does not fit in 65536 bytes, newline included` を出して、溜めた入力を捨てます。大きなプログラムは、REPL に貼らずにファイルに書いて実行します([4 ファイルの実行](04-running-files.md))。

## まだ無い機能

カーソルの移動、履歴、補完などの行編集は、まだありません([7 準拠の状況と既知の制限](07-limitations.md))。
