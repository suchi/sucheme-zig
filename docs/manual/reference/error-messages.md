# 誤りの文面

実行時の誤りは、`error: ` に続けて説明が出ます。誤りを起こした呼び出しの場所が分かるときは、説明の前に `行:桁:`(ファイルの実行では `ファイル名:行:桁:`)が付きます。マクロが作った呼び出しや、標準ライブラリの手続きの中で起きた誤りには、付きません。以下の例では、文面の部分を見ます。REPL は標準出力に、ファイルの実行は標準エラーに出します。ファイルの実行では、その誤りでプログラムが止まり、終了コードは 1 です([ユーザーズガイド 2 コマンドライン](../guide/02-command-line.md))。

R7RS は、誤りの文面を定めていません(1.3.2 節。誤りの状況の多くは「誤りである」とだけ書かれています)。ここに書くのは sucheme の文面で、版によって変わりえます。文面が変わったら、変えた変更が、この文書の例を直します([ADR-0048](../../adr/0048-run-the-examples-of-the-user-documentation.md))。プログラムが文面に頼るのは勧めません。`guard` で受けて、`error-object-message` と `error-object-irritants` を使ってください(R7RS 6.11 節)。

文面は、おおよそ「説明」のあとに、問題になった値が続く形です。

## 引数の型と範囲

手続きに渡した引数の型が合わないと、`wrong type of argument to` に、手続きの名前と引数が続きます。

```scheme fresh
(car 5)
```

```output
error: 1:1: wrong type of argument to car 5
```

```scheme fresh
(+ 'a 1)
```

```output
error: 1:1: wrong type of argument to + a 1
```

```scheme fresh
(string->symbol 5)
```

```output
error: 1:1: wrong type of argument to string->symbol 5
```

```scheme fresh
(length '(1 . 2))
```

```output
error: 1:1: wrong type of argument to length (1 . 2)
```

型は合うが範囲の外のときは、`argument out of range in` です。

```scheme fresh
(vector-ref (vector 1 2) 5)
```

```output
error: 1:1: argument out of range in vector-ref #(1 2) 5
```

```scheme fresh
(string-ref "abc" 10)
```

```output
error: 1:1: argument out of range in string-ref "abc" 10
```

ゼロでの除算は、`division by zero in` です。

```scheme fresh
(/ 1 0)
```

```output
error: 1:1: division by zero in / 1 0
```

## 変数と呼び出し

束縛の無い変数は `unbound variable:` です。

```scheme fresh
undefined-name
```

```output
error: unbound variable: undefined-name
```

引数の個数が合わないときは、期待する個数と実際の個数が出ます。手続きでないものを呼ぶと `not a procedure` です。

```scheme fresh
((lambda (x) x))
```

```output
error: 1:1: wrong number of arguments: expected 1, got 0
```

```scheme fresh
(5 5)
```

```output
error: 1:1: not a procedure
```

## 構文の誤り

特殊形式の形が合わないと、`bad` に形式の名前と、期待する形が続きます。

```scheme fresh
(if)
```

```output
error: 1:1: bad if: expected (if test consequent) or (if test consequent alternative)
```

```scheme fresh
(lambda)
```

```output
error: 1:1: bad lambda: expected (lambda (name ...) body ...)
```

```scheme fresh
(define)
```

```output
error: 1:1: bad define: expected (define name expression)
```

```scheme fresh
(let ((x 1) (x 2)) x)
```

```output
error: 1:1: bad lambda: duplicate parameter: x
```

最後の例は `let` の誤りですが、文面は `bad lambda` です。`let` は内部で `lambda` に展開されるためです。

## `error` と `raise`

`error` は、メッセージと、続く値(irritants)を並べて出します。

```scheme fresh
(error "boom" 1 2)
```

```output
error: 1:1: boom 1 2
```

`raise` に条件オブジェクトでない値を渡して、誰も受けなければ、その値がそのまま出ます。

```scheme fresh
(raise 'oops)
```

```output
error: 1:1: oops
```

```scheme fresh
(raise 42)
```

```output
error: 1:1: 42
```

`with-exception-handler` のハンドラが、`raise` から戻ると、それも誤りになります(R7RS 6.11 節は、`raise` の場合に二次的な例外を送出するとします)。

```scheme fresh
(with-exception-handler (lambda (e) 0) (lambda () (raise 'x)))
```

```output
error: handler returned from non-continuable raise x
```

## 上限と標準にないもの

`heap limit exceeded` は [実装の上限](limits.md) にあります。

`(scheme base)` にない名前は、`unbound variable` になります。たとえば `assert` は R7RS の識別子ではなく、`exact->inexact` は `(scheme r5rs)` にあります([索引](scheme-r5rs.md))。

```scheme fresh
(assert (= 1 2))
```

```output
error: unbound variable: assert
```

```scheme fresh
(exact->inexact 1)
```

```output
error: unbound variable: exact->inexact
```
