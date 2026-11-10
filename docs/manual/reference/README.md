# リファレンス

sucheme を使うときに、R7RS の原文([docs/spec/](../../spec/README.md))だけでは分からないことを置く場所です。二つの部分からなります。

- ライブラリの索引: `import` できる R7RS のライブラリごとに、識別子の一覧と、R7RS の節番号を置きます。説明は R7RS の原文にあるので、写しません。
- sucheme に固有の項目: R7RS が実装に委ねている点での sucheme の選択と上限です。例は `check-examples` が走らせます。

## sucheme に固有の項目

- [実装の上限](limits.md): ヒープ、再帰の深さ、入力の大きさ
- [REPL とコマンドライン](repl-and-command-line.md): 二つの経路の違い、初期環境
- [誤りの文面](error-messages.md): `error:` の文面の例
- [表示の書式](printing.md): 値が文字になる書式(`write` と `display`)
- [まだ無い機能](unimplemented.md): 標準入力のプログラム、行編集、エラーの位置など
- [R7RS と食い違う、または実装に委ねられた箇所](deviations.md): 既知の制限のうち、結果が決まっているもの

## ライブラリの索引

各ページは、識別子の表を持ちます。表の「R7RS の節」は、識別子を定める原文の節番号です。表と、ライブラリが輸出する識別子の一致は、`check-examples` が確かめます。輸出が増減すると、その変更が表を直すまで赤くなります。

- [`(scheme base)`](scheme-base.md)
- [`(scheme case-lambda)`](scheme-case-lambda.md)
- [`(scheme char)`](scheme-char.md)
- [`(scheme complex)`](scheme-complex.md)
- [`(scheme cxr)`](scheme-cxr.md)
- [`(scheme eval)`](scheme-eval.md)
- [`(scheme file)`](scheme-file.md)
- [`(scheme inexact)`](scheme-inexact.md)
- [`(scheme lazy)`](scheme-lazy.md)
- [`(scheme load)`](scheme-load.md)
- [`(scheme process-context)`](scheme-process-context.md)
- [`(scheme r5rs)`](scheme-r5rs.md)
- [`(scheme read)`](scheme-read.md)
- [`(scheme repl)`](scheme-repl.md)
- [`(scheme time)`](scheme-time.md)
- [`(scheme write)`](scheme-write.md)

`(sucheme core)` などの内部のライブラリは、標準ライブラリと準拠スイートの部品で、名前と中身が予告なく変わります。索引には載せません([ユーザーズガイド 5 ライブラリ](../guide/05-libraries.md))。
