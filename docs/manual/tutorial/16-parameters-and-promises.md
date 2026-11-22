# 16 パラメータと遅延評価

この章では、2つの機能を学びます。1つ目は、ある範囲の中だけ値を差し替えられる設定の値、パラメータオブジェクトです。2つ目は、計算を先送りして、必要になったときに1度だけ行う遅延評価です。

## パラメータ

プログラムのあちこちで使う設定(出力の桁数、基数、デバッグの出力の有無など)を、グローバル変数に入れて `set!` で書き換えるのは、元に戻し忘れやすく、エラーが起きたときに戻らない、という問題があります。

パラメータ(parameter)は、この問題を解く仕組みです。`make-parameter` で作り、手続きのように、引数なしで呼ぶと値を返します。

```scheme
(define radix (make-parameter 10))
(radix)
```

```output
10
```

`parameterize` で、本体の実行中だけ値を差し替えます。本体を抜けると、元の値に戻ります。

```scheme
(parameterize ((radix 2))
  (radix))
(radix)
```

```output
2
10
```

パラメータを使う手続きを書いてみます。

```scheme
(define (show n)
  (number->string n (radix)))
(show 255)
(parameterize ((radix 16))
  (show 255))
(parameterize ((radix 2))
  (show 255))
(show 255)
```

```output
"255"
"ff"
"11111111"
"255"
```

`show` の引数に基数を渡さなくても、`parameterize` の範囲の中で呼べば、その範囲の基数で変換されます。呼び出しの途中に何段の手続きがあっても、パラメータなら、引数を持ち回る必要がありません。

### 入れ子と抜け方

`parameterize` は入れ子にできます。一番内側のものが有効です。

```scheme
(parameterize ((radix 2))
  (parameterize ((radix 8))
    (radix)))
```

```output
8
```

継続やエラーで本体から抜けても、元の値に戻ります。

```scheme
(call/cc
  (lambda (k)
    (parameterize ((radix 3))
      (k (radix)))))
(radix)
(guard (e (#t (radix)))
  (parameterize ((radix 5))
    (raise 'oops)))
```

```output
3
10
10
```

`(radix)` は、1つ目の呼び出しの中では3になりますが、抜けると10に戻ります。`guard` の節の中で呼んだ `(radix)` も、`parameterize` の外なので10です。

### 変換の手続き

`make-parameter` の第2引数に、値を変換する手続きを渡せます。初期値と、`parameterize` で設定した値は、この手続きを通ります。

```scheme
(define doubled (make-parameter 5 (lambda (x) (* x 2))))
(doubled)
(parameterize ((doubled 7))
  (doubled))
```

```output
10
14
```

不正な値を拒否する検査にも使えます。

```scheme
(define positive (make-parameter 1
  (lambda (x)
    (if (> x 0) x (error "must be positive:" x)))))
(parameterize ((positive 5)) (positive))
```

```output
5
```

```scheme
(parameterize ((positive -1)) (positive))
```

```output
error: 3:19: must be positive: -1
```

## 遅延評価

普通の Scheme は、引数を呼ぶ前にすべて評価します。計算を先送りして、本当に値が必要になったときに初めて行いたいことがあります。`delay` は、式の計算を先送りした、プロミス(promise)を作ります。`force` は、プロミスの値を取り出します。`delay` と `force` は、`(scheme lazy)` にあります。

```scheme
(import (scheme lazy))
(import (scheme write))
(define p (delay (begin (display "computing ") 42)))
(promise? p)
(force p)
```

```output
#t
computing 42
```

`delay` の式は、`force` するまで評価されません。そして、`force` は計算を1度しか行いません。2回目以降は、記録した値を返します。

```scheme
(force p)
(force p)
```

```output
42
42
```

2回目と3回目の呼び出しでは、`computing ` が出力されません。プロミスは、最初の `force` で計算した値を覚えています。

`delay` の式は、手続きの本体と違い、`force` されなければ評価されないので、エラーを含んでいても、使わなければ起きません。

```scheme
(define never (delay (car '())))
(promise? never)
```

```output
#t
```

プロミスでない値に `force` を使うと、その値がそのまま返ります。

```scheme
(force 5)
(force (make-promise 7))
```

```output
5
7
```

### 無限の列

遅延評価を使うと、無限に続く列を、必要な分だけ計算して使えます。次は、整数が無限に続くストリームです。ストリームは、ペアの `car` に値、`cdr` に残りを作るプロミスを入れたものです。

```scheme
(define (ints n)
  (cons n (delay (ints (+ n 1)))))
(define (stream-take s k)
  (if (= k 0)
      '()
      (cons (car s) (stream-take (force (cdr s)) (- k 1)))))
(stream-take (ints 1) 5)
(stream-take (ints 100) 3)
```

```output
(1 2 3 4 5)
(100 101 102)
```

`ints` は、再帰の呼び出しを `delay` で包んでいるので、`(ints 1)` を呼んでも、無限には計算されません。`stream-take` が `(force (cdr s))` したときに初めて、次の要素が作られます。

偶数だけを取り出す `stream-filter` と合わせてみます。

```scheme
(define (stream-filter pred s)
  (if (pred (car s))
      (cons (car s) (delay (stream-filter pred (force (cdr s)))))
      (stream-filter pred (force (cdr s)))))
(stream-take (stream-filter even? (ints 1)) 5)
```

```output
(2 4 6 8 10)
```

### たらい回し関数

遅延評価の効き目を、竹内正彦の「たらい回し関数」`tarai` で見ます。第7章の `tak` に似ていますが、戻り値が違います。第3引数 `z` は、`x` が `y` 以下のときは使われません。正格に評価する版では、使われないのに、毎回計算しています。

まず、普通に評価する版です。呼び出しの回数を数えます。

```scheme
(define strict-calls 0)
(define (tarai x y z)
  (set! strict-calls (+ strict-calls 1))
  (if (<= x y)
      y
      (tarai (tarai (- x 1) y z)
             (tarai (- y 1) z x)
             (tarai (- z 1) x y))))
(tarai 8 4 0)
strict-calls
```

```output
8
12605
```

次は、第3引数を `delay` で渡す版です。`z` は、必要になったときだけ `force` します。

```scheme
(define lazy-calls 0)
(define (tarai-lazy x y z)
  (set! lazy-calls (+ lazy-calls 1))
  (if (<= x y)
      y
      (tarai-lazy (tarai-lazy (- x 1) y z)
                  (tarai-lazy (- y 1) (force z) (delay x))
                  (delay (tarai-lazy (- (force z) 1) x (delay y))))))
(tarai-lazy 12 6 (delay 0))
lazy-calls
```

```output
12
109
```

引数 `(8 4 0)` の正格な版が12605回の呼び出しをするのに対し、さらに大きな `(12 6 0)` の遅延評価版は、109回で済んでいます。正格な版で `(12 6 0)` を計算すると、約1260万回の呼び出しになります。遅延評価は、不要な計算を省く効果が、桁で違います。

### 再帰が深いときの delay-force

`delay-force` は、プロミスを返す式を遅延させる `delay` の仲間です。`(delay-force 式)` の式は、プロミスを返すことが期待され、`force` はそのプロミスの値まで続けて取り出します。R7RS は、プロミスの連鎖が長くなっても、`force` が領域を使い切らないために、この形を用意しています。

```scheme
(force (delay-force (delay 1)))
```

```output
1
```

普通の使い方では、`delay` と `force` で足ります。

## 練習問題

1. パラメータ `indent`(初期値 0)を作ってください。`(print-line "text")` は、`indent` の数だけ空白を前に付けて出力します。`parameterize` で、字下げを深くして呼んでみてください。
2. 遅延評価で、フィボナッチ数の無限ストリームを作り、最初の10個を取り出してください。
3. `(delay (begin (display "x") 1))` を2回 `force` したとき、`x` が何回出力されるかを予想してから確かめてください。
4. `my-delay` を、マクロ(第15章)と `lambda` で作ってください。値の記録は不要で、`force` の代わりに `(my-force p)` で `p` の手続きを呼ぶだけで構いません。

### 答え

1 の答えです。

```scheme
(define indent (make-parameter 0))
(define (print-line text)
  (display (make-string (indent) #\space))
  (display text)
  (newline))
(print-line "top")
(parameterize ((indent 2))
  (print-line "inner")
  (parameterize ((indent 4))
    (print-line "innermost")))
(print-line "top again")
```

```output
top
  inner
    innermost
top again
```

2 の答えです。

```scheme
(define (fib-stream a b)
  (cons a (delay (fib-stream b (+ a b)))))
(stream-take (fib-stream 0 1) 10)
```

```output
(0 1 1 2 3 5 8 13 21 34)
```

3 の答えです。1回だけです。

```scheme
(define q (delay (begin (display "x") 1)))
(force q)
(force q)
```

```output
x1
1
```

最初の `force` で `x` が出力され、値の `1` が続いています。2回目の `force` は、記録した値を返すだけで、出力はありません。

4 の答えです。

```scheme
(define-syntax my-delay
  (syntax-rules ()
    ((_ e) (lambda () e))))
(define (my-force p) (p))
(define lazy-sum (my-delay (+ 1 2)))
(my-force lazy-sum)
```

```output
3
```

この版は、`force` するたびに計算し直します。本物の `delay` との違いです。

## 次の章

[第17章 ライブラリ](17-libraries.md)では、プログラムを複数のファイルに分けて、名前の見える範囲を決める、ライブラリの仕組みを学びます。
