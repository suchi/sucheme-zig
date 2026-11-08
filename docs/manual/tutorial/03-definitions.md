# 3 定義と束縛

この章では、名前に値を結びつける方法を学びます。トップレベルの `define`、局所的な名前をつくる `let` の仲間、変数を更新する `set!` を扱います。

## define で名前をつける

`define` は、名前に値を結びつけます。

```text
(define 名前 式)
```

```scheme
(define width 6)
(define height 7)
(* width height)
```

```output
42
```

`define` を打っても、値は表示されません。名前が結びついただけで、表示する値がないからです。結びついた名前は、あとの式で使えます。

結びついていない名前を使うと、誤りになります。

```scheme
(* width depth)
```

```output
error: unbound variable: depth
```

`define` の第2引数は式です。式の値が名前に結びつきます。

```scheme
(define area (* width height))
area
```

```output
42
```

`area` に結びついたのは、計算した結果の 42 です。あとで `width` を変えても、`area` は変わりません。

### 名前に使える文字

Scheme の名前(識別子)には、英数字のほかに、`-`、`?`、`!`、`*`、`<`、`>`、`=`、`/` などの記号を使えます。`list->string`、`zero?`、`set-cdr!` のような名前が普通に使われます。単語の区切りには `-` を使うのが習慣です。`my-value` は、1つの名前です。`my - value` は、`my`、`-`、`value` の3つです。

名前の大文字と小文字は区別されます。

## let で局所的な名前をつくる

関数の中で一時的な変数を使いたいことがあります。`let` は、式の中だけで使える名前をつくります。

```text
(let ((名前1 式1) (名前2 式2) ...) 本体...)
```

```scheme
(let ((a 3) (b 4))
  (+ (* a a) (* b b)))
```

```output
25
```

`a` と `b` は、`let` の中だけで有効です。外に出ると、使えません。

```scheme
(* a a)
```

```output
error: unbound variable: a
```

`let` 全体も式で、最後の式の値を返します。そのため、`let` を式の一部として使えます。

```scheme
(+ 1 (let ((x 10)) (* x x)))
```

```output
101
```

### 隠蔽

内側の `let` が、外側と同じ名前を使うことができます。内側の範囲では、内側の名前が外側の名前を隠します。

```scheme
(define x 1)
(let ((x 2))
  x)
x
```

```output
2
1
```

`let` の中の `x` は 2 でしたが、外の `x` は変わっていません。これは、`let` が新しい名前をつくっているだけで、外の `x` を書き換えていないからです。

## let* で前の名前を使う

`let` では、名前に結びつける式を、`let` の外の名前で評価します。同じ `let` の中の、前の名前は使えません。

```scheme
(define n 10)
(let ((n 1)
      (m (+ n 1)))
  m)
```

```output
11
```

`m` を計算するときの `n` は、外側の 10 です。1 ではありません。

前の名前を使いたいときは、`let*` を使います。`let*` は、名前を上から順に結びつけます。

```scheme
(let* ((n 1)
       (m (+ n 1)))
  m)
```

```output
2
```

## letrec で自分自身を使う

自分自身を呼ぶ手続きを局所的につくりたいときは、`letrec` を使います。`letrec` の名前は、結びつける式の中から見えます。手続きの書き方(`lambda`)は第4章で説明するので、ここでは雰囲気だけを見てください。

```scheme
(letrec ((even2? (lambda (n)
                   (if (= n 0) #t (odd2? (- n 1)))))
         (odd2? (lambda (n)
                  (if (= n 0) #f (even2? (- n 1))))))
  (even2? 10))
```

```output
#t
```

`even2?` と `odd2?` が、お互いを呼んでいます。`let` や `let*` では、こうは書けません。

## 本体の中の define

`let` や手続きの本体の先頭では、`define` で局所的な名前をつくれます。

```scheme
(define (hypotenuse-squared a b)
  (define a2 (* a a))
  (define b2 (* b b))
  (+ a2 b2))
(hypotenuse-squared 3 4)
```

```output
25
```

`(define (名前 引数...) 本体...)` は手続きを定義する書き方で、第4章で説明します。ここで見てほしいのは、本体の中の `define` が、手続きの中だけで有効な名前をつくることです。本体の中の `define` は、本体の先頭にまとめて書きます。

## set! で値を更新する

名前に結びついた値を、あとから更新するには `set!` を使います。

```scheme
(define counter 0)
(set! counter (+ counter 1))
(set! counter (+ counter 1))
counter
```

```output
2
```

名前の最後の `!` は、「値を書き換える」手続きや構文に付ける習慣です。

`set!` は、すでに結びついている名前(`define` や `let` でつくったもの)にしか使えません。Scheme のプログラムは、`set!` をあまり使わず、`let` や再帰(第7章)で書くのが普通です。使うとしたら、第4章で学ぶクロージャに状態を持たせるときなどです。

## 練習問題

1. 半径 5 の円の面積を、`pi` を 3.14159 として求めてください。`define` で `pi` と `radius` を決めてから計算します。
2. 直角をはさむ2辺が 3 と 4 の直角三角形の、斜辺の長さの2乗を、`let*` を使って求めてください。それぞれの辺の2乗を、名前をつけて足します。
3. 次の式の値を予想してから、試してください。

```text
(define x 5)
(let ((x 10) (y x))
  (+ x y))
```

### 答え

1 の答えです。

```scheme
(define pi 3.14159)
(define radius 5)
(* pi radius radius)
```

```output
78.53975
```

2 の答えです。

```scheme
(let* ((a 3)
       (b 4)
       (a2 (* a a))
       (b2 (* b b)))
  (+ a2 b2))
```

```output
25
```

3 の答えです。`let` の中の `y` を結びつける式は、`let` の外の `x` を見ます。そのため、`y` は 5 で、`x` は 10 になります。

```scheme
(define x 5)
(let ((x 10) (y x))
  (+ x y))
```

```output
15
```

## 次の章

[第4章 手続き](04-procedures.md)では、自分で手続きをつくる `lambda` と、手続きを定義する `define` を学びます。
