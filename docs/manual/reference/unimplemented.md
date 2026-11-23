# まだ無い機能

R7RS-small の範囲で、sucheme がまだ持たないものと、持っていても利用者に見える形が足りないものをまとめます。状態は版ごとに変わります。進み具合の正は [docs/roadmap.md](../../roadmap.md) の「現在地」で、リリースごとの制限は、[v1.0.0](../../releases/v1.0.0.md)、[v1.1.0](../../releases/v1.1.0.md)、[v1.2.0](../../releases/v1.2.0.md) のリリースノートの「既知の制限」にあります。

## 識別子は、そろっている

R7RS 付録 A の標準ライブラリの、必須の識別子は、すべて束縛されています([ライブラリの索引](README.md#ライブラリの索引)。結果の正は [準拠マトリクス](../../status/conformance.md) です)。「まだ無い」のは、識別子ではなく、次の機能です。

## 標準入力のプログラム

`sucheme -` で、標準入力のプログラムを実行する機能は、まだありません。終了コード 69 で終わります。REPL に式を流し込む(`sucheme < prog.scm`)ことはできます([ユーザーズガイド 3 REPL](../guide/03-repl.md))。

```console
$ sucheme -
sucheme: reading a program from stdin is not implemented yet.
Run with --help for the options available now.
[exit 69]
```

## REPL の行編集

端末では、複数行にわたる式の編集、ファイルに保存する履歴、括弧の対応の表示があります([ユーザーズガイド 3 REPL](../guide/03-repl.md) の「行の編集」)。識別子の補完は、まだありません。[roadmap](../../roadmap.md) の「段階7の後続の作業」の項目です。

## エラーの位置

実行時のエラーの位置(`行:桁:`。ファイルのプログラムでは、先にファイル名が付く)は、手続きの呼び出しが送出した誤りにだけ付きます。未束縛の変数の参照のような呼び出しでない式の誤り、標準ライブラリの手続きの中の誤り、マクロの出力の呼び出しの誤りには、位置が付きません([誤りの文面](error-messages.md)、[設計](../../design/frontend.md) の「実行時の誤りの位置」)。位置が付く例を次に示します。

```scheme fresh
(define (f x)
  (car x))
(f 5)
```

```output
error: 2:3: wrong type of argument to car 5
```

## Web UI

Web UI では、ファイルを開けません(`file-error` になります)。標準入力は、画面の入力欄から1行ずつ渡します。「End of input」で終わりを渡すと、続く読み取りはファイルの終わりを返します([ユーザーズガイド 6 Web UI](../guide/06-web-ui.md))。

Web UI の評価は、「Stop」ボタンか `Esc` キーで止められ、止めても定義は残ります。ただし、`import` で読み込むライブラリの本体と、1歩の中で長く走る組み込みの手続きは、区切りの間に走るので、終わるまで止まりません。3秒たっても応えないときは、処理系を作り直し、定義は失われます。実行ファイルの REPL で、評価だけを止める Ctrl-C は、まだありません([roadmap](../../roadmap.md) の「段階7の後続の作業」)。
