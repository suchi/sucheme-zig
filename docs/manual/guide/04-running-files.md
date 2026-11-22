# 4 ファイルの実行

`sucheme <file>` は、ファイルのプログラムを先頭から1つずつ評価します。

```console
$ sucheme hello.scm
Hello, world
```

`hello.scm` の中身です。

```text
(import (scheme write))
(display "Hello, world")
(newline)
```

プログラムは、R7RS の形に沿って `import` で始められますが、始めなくてもかまいません。始めなかった場合の最初の環境は、REPL と同じ `(scheme base)` だけです。`display` を使うには `(scheme write)` が要ります。

## 出力

式の値は出力しません。プログラムが現在の出力ポートに書いたもの(`display`、`write-string` など)だけが標準出力に出ます。

```console
$ sucheme values.scm
only this is shown
```

`values.scm` は、`(+ 1 2)` や `"a string"` の式を置いたあとで `display` を呼びます。式の値は、REPL なら表示される式でも、ファイルでは出ません。

現在のエラーポートに書いたものは、標準エラーに出ます。標準出力と標準エラーを同じ端末で見ると、書いた順に並びます。

```console
$ sucheme warn.scm
to standard output
to standard error
```

## 実行時エラー

実行時エラーが起きると、`error: ` に続けて説明を標準エラーに出して、そこでプログラムは止まります。終了コードは 1 です。エラーより前の出力は残ります。説明の前には、誤りを起こした呼び出しの場所が、`ファイル名:行:桁:` の形で付きます。マクロが作った呼び出しや、標準ライブラリの手続きの中で起きた誤りには、付きません。

```console
$ sucheme boom.scm
before the error
error: boom.scm:4:1: wrong type of argument to car ()
[exit 1]
```

開けない、読めない、大きすぎる(1 MiB を超える)ファイルは、プログラムを走らせずに、終了コード 66 で断ります。UTF-8 でないファイルは、実行時エラーです。

## プログラムへの引数

ファイル名の後ろの引数は、プログラムに渡ります。`(scheme process-context)` の `command-line` で読めます。先頭はファイル名で、続くのが引数です。`-` で始まる引数も、プログラムの引数です。

```console
$ sucheme args.scm a -b c
("args.scm" "a" "-b" "c")
```

## `exit` で終わる

プログラムは、`(scheme process-context)` の `exit` で、終了コードを決めて終われます。

```console
$ sucheme exit3.scm
[exit 3]
```

`exit` は、`dynamic-wind` の `after` を呼んでから終わります。`exit` の引数と終了コードの対応は、[プラットフォームの設計](../../design/platform-and-web.md)にある表が正で、値の下位 8 ビットが終了コードになります。

## 標準入力

プログラムの `read` や `read-char` は標準入力から読みます。標準入力そのものをプログラムとして実行する形(`sucheme -`)は、まだありません。`-` だけの引数は、ファイル名ではなくオプションでもない名前として扱い、終了コード 69 で終わります([2 コマンドライン](02-command-line.md))。
