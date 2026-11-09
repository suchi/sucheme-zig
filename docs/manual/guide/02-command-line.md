# 2 コマンドライン

引数と終了コードの契約の正は、[src/main.zig](../../../src/main.zig) の冒頭の doc コメントです。この章は、その使い方を例で見せます。表を写すと食い違うので、写しません。

## 引数

| 書き方 | することの要点 |
| --- | --- |
| `sucheme` | 標準入力から式を読み、値を出す([3 REPL](03-repl.md)) |
| `sucheme <file>` | ファイルのプログラムを実行する([4 ファイルの実行](04-running-files.md)) |
| `sucheme <file> <args>...` | 同じ。`<args>` はプログラムへの引数になる |
| `sucheme -I <dir>` と `sucheme -I <dir> <file>` | ライブラリを探すディレクトリを足す(繰り返せる。[5 ライブラリ](05-libraries.md)) |
| `sucheme --version` | 名前と版を出す |
| `sucheme --help`、`sucheme -h` | 使い方を出す |

オプションは、ファイル名より前に書きます。ファイル名の後ろは、`-` で始まるものも含めて、プログラムへの引数です。

`--version` と `--help` の出力は、版が上がるたびに変わるので、この文書では例にしていません。

## 終了コード

終了コードは、プログラムの成否を、シェルのスクリプトなどに知らせる値です。ここでは代表を見ます。全部の値と、その条件は [src/main.zig](../../../src/main.zig) にあります。

0 は成功です。プログラムを最後まで実行しました。

```console
$ sucheme hello.scm
Hello, world
```

1 は、プログラムの実行時エラーです。それまでに書いた出力は残り、エラーは `error: ` に続けて標準エラーに出ます。そこでプログラムは止まり、あとの式は実行されません。

```console
$ sucheme boom.scm
before the error
error: wrong type of argument to car ()
[exit 1]
```

64 は、引数の誤りです。未知のオプションや、ディレクトリのない `-I` がこれに当たります。

```console
$ sucheme --bogus
sucheme: unknown option --bogus
Run with --help for the options available now.
[exit 64]
```

```console
$ sucheme -I
sucheme: option -I needs a directory
Run with --help for the options available now.
[exit 64]
```

66 は、ファイルを読めないことです。

```console
$ sucheme nothing.scm
error: cannot read nothing.scm: FileNotFound
[exit 66]
```

69 は、まだ実装していない要求です。標準入力のプログラム(`-` だけの引数)がこれに当たります。

```console
$ sucheme -
sucheme: reading a program from stdin is not implemented yet.
Run with --help for the options available now.
[exit 69]
```

プログラム自身が終了コードを決めることもあります。`exit` を呼ぶと、その引数から決まる値で終わります([4 ファイルの実行](04-running-files.md))。

出力を標準出力に書けないとき(パイプの先が閉じているなど)は 74 です。

プログラムが書いたものは標準出力に、エラーの説明は標準エラーに、別々に出ます。`sucheme prog.scm > out.txt` のようにすると、プログラムの出力だけがファイルに入り、エラーの説明は端末に出ます。このシェルの書き方は、`check-examples` が走らせられないので、例にしていません。
