# REPL とコマンドライン

R7RS は、REPL を 5.7 節で、プログラムの形を 5.1 節で定めます。ここでは、その二つの経路について、sucheme の選択を書きます。引数と終了コードの使い方は [ユーザーズガイド 2 コマンドライン](../guide/02-command-line.md)、REPL の使い方は [ユーザーズガイド 3 REPL](../guide/03-repl.md) にあります。契約の正は [src/main.zig](../../../src/main.zig) の冒頭の doc コメントです。

## 経路は二つ

`sucheme` は、プログラムを 2 つの経路で読みます。

- 引数なし: REPL。標準入力から式を 1 つずつ読み、評価し、値を出します。
- `sucheme <file>`: ファイルの実行。ファイルのプログラム全体を実行し、式の値は出しません。

同じ式でも、経路で出力が違います。ファイルの実行は、`display` などで書いたものだけを出します。

```console
$ sucheme silent.scm
```

REPL に相当する評価(次のブロックの評価)は、各式の値を出します。

```scheme fresh
(+ 1 2)
"a string"
(define x 5)
```

```output
3
"a string"
```

定義は何も出力しません。値が複数のときは 1 行に 1 つずつ出し、0 個なら何も出しません。

## 初期環境

どちらの経路も、初期環境は `(scheme base)` です(R7RS 5.1 節は、プログラムの最初の環境が空で、`import` で束縛を得るとします。sucheme の REPL とファイルの実行は、`import` の前から `(scheme base)` が見える点で異なります)。`(scheme base)` にない名前は、`import` してから使います。

```scheme fresh
(display "hi")
```

```output
error: unbound variable: display
```

```scheme
(import (scheme write))
(display "hi")
```

```output
hi
```

どのライブラリに何があるかは、[索引](README.md#ライブラリの索引) にあります。

## 誤りでの振る舞い

- REPL: 誤りは `error: ` に続けて説明を出し、その式の評価だけが終わります。次の式から続けて読みます。
- ファイルの実行: 誤りで止まります。それまでに書いた出力は残り、終了コードは 1 です。

文面の例は [誤りの文面](error-messages.md)、終了コードの一覧は [src/main.zig](../../../src/main.zig) にあります。

## 入力の上限

REPL の溜める入力と、ファイルの大きさには上限があります([実装の上限](limits.md))。
