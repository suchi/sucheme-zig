# R7RS と食い違う、または実装に委ねられた箇所

R7RS が実装に委ねている点での sucheme の選択と、R7RS の記述と食い違う箇所をまとめます。準拠スイートが通っても、ここに挙げたものは、スイートの外の振る舞いです。直すかどうかは、[roadmap](../../roadmap.md) と [open-questions](../../design/open-questions.md) が正です。リリースごとの一覧は [v1.0.0](../../releases/v1.0.0.md) の「既知の制限」にあります。

## マクロが導入したトップレベルの定義は、衛生的でない

`syntax-rules` のマクロが、トップレベルの `define` を導入すると、利用側の同じ綴りのトップレベルの変数を書き換えます。R7RS 4.3 は、トップレベルの変数の定義が束縛を導入するかを、実装に委ねています。局所の束縛は衛生的です。

```scheme fresh
(define-syntax def-x
  (syntax-rules ()
    ((_ v) (define x v))))
(define x 1)
(def-x 2)
x
```

```output
2
```

```scheme fresh
(define-syntax get-x
  (syntax-rules ()
    ((_) x)))
(let ((x 1))
  (let ((x 2))
    (get-x)))
```

```output
error: unbound variable: x
```

後者の例の `x` は、マクロを定義した場所(トップレベル)で解決されるので、`let` の `x` を見ません。トップレベルに `x` が無ければ、未束縛の変数です。

## 構文キーワードの名前への `define`

構文キーワードや特殊形式の名前を、トップレベルの変数として定義できます。R7RS 5.4 が誤りの例に挙げる `(define define 3)` も受け付けます。そのセッションの間、その名前は変数です。

```scheme fresh
(define define 3)
define
```

```output
3
```

```scheme fresh
(define if 5)
(if #t 1 2)
```

```output
error: 2:1: not a procedure
```

## 大文字小文字の畳み込み

`#!fold-case` が効いている間、ソースの識別子は小文字に畳み込まれます。

```scheme fresh
#!fold-case
'FooBar
```

```output
foobar
```

文字列の `string-foldcase` と `string-upcase` は、完全な変換(`ß` が `ss` と `SS` になる)をします。

```scheme fresh
(import (scheme char))
(string-foldcase "ß")
(string-upcase "ß")
```

```output
"ss"
"SS"
```

`string-downcase` は、語末のシグマを特別に扱いません。

```scheme fresh
(import (scheme char))
(string-downcase "ΑΣ")
```

```output
"ασ"
```

リーダの `#!fold-case` は単純な畳み込みで、`ß` のように、完全な畳み込みでだけ変わる文字は畳み込みません([v1.0.0](../../releases/v1.0.0.md)。この文書の例では確かめていません)。

## 初等関数の最後の桁

`exp` などの初等関数は、最後の桁が 1 だけずれることがあります。R7RS 6.2.6 は、不正確な結果の精度を定めていません。

```scheme fresh
(import (scheme inexact))
(exp 1)
```

```output
2.7182818284590455
```

## 複素数の、規定のない結果

複素数の演算で、R7RS が結果を規定していない場合は、`+nan.0` を含む結果になることがあります。

```scheme fresh
(* +i +inf.0+1.0i)
```

```output
+nan.0+inf.0i
```

```scheme fresh
(/ 1+2i 0.0+0.0i)
```

```output
+nan.0+nan.0i
```

## `error` の第一引数

`error` の第一引数(メッセージ)が文字列でないと、型の誤りになります。R7RS 6.11 節は、メッセージは文字列であるべきだとしています(`should`)。

```scheme fresh
(error 'my-proc "msg")
```

```output
error: 1:1: wrong type of argument to error my-proc "msg"
```

## 埋め込みのライブラリの名前

`(scheme base)` や `(sucheme derived)` など、埋め込みの標準ライブラリは、最初の `import` で読み込みます。その前に利用者が同じ名前の `define-library` を評価すると、利用者の定義がその名前を取ります。R7RS はライブラリ名の予約を定めていません(この文書では確かめていません。[v1.0.0](../../releases/v1.0.0.md) の「既知の制限」)。

## 性能とメモリ

ヒープの上限と入力の大きさ、数の綴りの上限は [実装の上限](limits.md) にあります。そのほかの、性能とメモリの制限(パラメータの読み出し、ヒープの上限に数えない確保など)は、リリースノートの「既知の制限」にあります。
