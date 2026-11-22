# まだ無い機能

R7RS-small の範囲で、sucheme がまだ持たないものと、持っていても利用者に見える形が足りないものをまとめます。状態は版ごとに変わります。進み具合の正は [docs/roadmap.md](../../roadmap.md) の「現在地」で、リリースごとの制限は [v1.0.0 のリリースノート](../../releases/v1.0.0.md) の「既知の制限」にあります。

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

実行時のエラーには、ソースの位置(ファイルと行)が付きません。説明と、問題になった値だけが出ます([誤りの文面](error-messages.md))。[roadmap](../../roadmap.md) の段階 8 の項目です。

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
