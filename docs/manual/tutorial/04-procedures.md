# 4 手続き

この章では、自分で手続き(関数)をつくる方法を学びます。`lambda`、手続きを定義する `define`、可変長の引数、そしてクロージャです。

## lambda で手続きをつくる

`lambda` は、名前のない手続きをつくる式です。

```text
(lambda (引数...) 本体...)
```

```scheme
(lambda (x) (* x x))
```

```output
#<procedure>
```

値としては `#<procedure>` と表示されます。手続きは、数や文字列と同じ「値」の1つです。呼び出すには、手続きを括弧の先頭に置きます。先頭の位置には、手続きになる式なら何でも置けます。

```scheme
((lambda (x) (* x x)) 7)
((lambda (x y) (+ x y)) 3 4)
```

```output
49
7
```

JavaScript の無名関数 `(x) => x * x` や、Python の `lambda x: x * x` に当たるものです。Scheme の `lambda` は、本体に式をいくつでも書けます。最後の式の値が、手続きの値になります。

## define で手続きに名前をつける

手続きは値なので、第3章の `define` で名前をつけられます。

```scheme
(define square (lambda (x) (* x x)))
(square 12)
```

```output
144
```

この形はよく使うので、短い書き方があります。

```text
(define (名前 引数...) 本体...)
```

```scheme
(define (cube x) (* x x x))
(cube 3)
```

```output
27
```

`(define (cube x) ...)` は、`(define cube (lambda (x) ...))` と同じ意味です。以降は、この短い形を使います。

引数の数が合わないと、誤りになります。

```scheme
(cube 1 2)
```

```output
error: 1:1: wrong number of arguments: expected 1, got 2
```

### 本体に式が複数あるとき

本体の式は、上から順に評価され、最後の式の値が返ります。途中の式は、副作用(画面への出力など)のために書きます。

```scheme
(import (scheme write))
(define (greet name)
  (display "Hello, ")
  (display name)
  (newline)
  'done)
(greet "Scheme")
```

```output
Hello, Scheme
done
```

最後の式 `'done` は記号(シンボル)で、第6章で説明します。`greet` は、画面に書いたあと、その値を返しています。

## 可変長の引数

`+` が引数をいくつでも取れたように、自分の手続きも可変長にできます。引数の並びの代わりに名前を1つ書くと、その名前に引数全体がリストとして結びつきます。

```scheme
(define (all-args . args) args)
(all-args)
(all-args 1 2 3)
```

```output
()
(1 2 3)
```

`(1 2 3)` は、リストです。リストは第6章で詳しく説明します。

固定の引数のあとに、点を打って残りを受ける書き方もできます。

```scheme
(define (first-and-rest first . rest)
  (list first rest))
(first-and-rest 1)
(first-and-rest 1 2 3)
```

```output
(1 ())
(1 (2 3))
```

`first` は必ず要る引数で、`rest` は残りの引数のリストです。

## クロージャ

手続きは、つくられた場所の名前を覚えています。これをクロージャと呼びます。

```scheme
(define (make-adder n)
  (lambda (x) (+ x n)))
(define add3 (make-adder 3))
(define add10 (make-adder 10))
(add3 4)
(add10 4)
```

```output
7
14
```

`make-adder` が返す手続きは、`make-adder` の呼び出しが終わったあとも、引数 `n` を覚えています。`add3` の `n` は 3 で、`add10` の `n` は 10 です。それぞれが別の `n` を持っています。

クロージャと `set!`(第3章)を組み合わせると、状態を持つ手続きがつくれます。

```scheme
(define (make-counter)
  (let ((count 0))
    (lambda ()
      (set! count (+ count 1))
      count)))
(define counter-a (make-counter))
(define counter-b (make-counter))
(counter-a)
(counter-a)
(counter-b)
```

```output
1
2
1
```

`counter-a` と `counter-b` は、それぞれ独立した `count` を持っています。`counter-a` を2回呼んでも、`counter-b` の数には影響しません。オブジェクト指向言語のオブジェクトに近い性質を、手続きだけで実現しています。

## 手続きは値

手続きは、ほかの値と同じように、引数に渡したり、返したり、リストに入れたりできます。この性質を活かす書き方は、第8章で扱います。いまは、手続きを引数にとる手続きの小さな例を見ておきます。

```scheme
(define (twice f x)
  (f (f x)))
(twice cube 2)
(twice (lambda (x) (+ x 1)) 5)
```

```output
512
7
```

`(twice cube 2)` は、`(cube (cube 2))`、つまり `(cube 8)` で 512 です。

## 練習問題

1. 引数を2倍にする手続き `double` を定義して、`(double 21)` を求めてください。
2. 2つの数の平均を返す手続き `average` を定義してください。`(average 3 4)` は、分数 `7/2` になります。
3. 手続き `compose` を定義してください。`(compose f g)` は、引数 `x` を受けて `(f (g x))` を返す手続きを返します。`(compose double cube)` を 2 に適用すると、`double (cube 2)` で 16 になります。

### 答え

1 の答えです。

```scheme
(define (double x) (* 2 x))
(double 21)
```

```output
42
```

2 の答えです。

```scheme
(define (average a b) (/ (+ a b) 2))
(average 3 4)
(average 3 5)
```

```output
7/2
4
```

3 の答えです。`compose` が手続きを返すことに注意してください。

```scheme
(define (compose f g)
  (lambda (x) (f (g x))))
((compose double cube) 2)
```

```output
16
```

## 次の章

[第5章 条件分岐](05-conditionals.md)では、`if`、`cond`、`case` などで処理を分けます。
