# 7 再帰と末尾呼び出し

この章では、Scheme での繰り返しの書き方を学びます。C や Python の `for` や `while` に当たる構文はありますが、Scheme では手続きが自分自身を呼ぶ「再帰」で書くのが基本です。末尾呼び出しを使うと、再帰が通常のループと同じ使い方で動きます。

## 再帰で考える

再帰は、問題を「小さな同じ問題」に分けて解く方法です。階乗 n! を例にします。

- 0 の階乗は 1 です。(終わりの条件)
- n の階乗は、n に「n - 1 の階乗」を掛けたものです。

これをそのまま手続きにします。

```scheme
(define (factorial n)
  (if (= n 0)
      1
      (* n (factorial (- n 1)))))
(factorial 5)
(factorial 20)
(factorial 30)
```

```output
120
2432902008176640000
265252859812191058636308480000000
```

`(factorial 30)` は 64 ビット整数に入りきらない大きさですが、Scheme の整数は桁数に制限がないので、そのまま計算できます(第2章)。

再帰を書くときは、次の2つを確かめます。

- 終わりの条件があるか: これがないと、再帰が止まりません。
- 呼び出しのたびに、終わりの条件に近づくか: `factorial` では、`n` が1ずつ減っていきます。

### リストの再帰

リストも再帰で処理できます。リストは「空」か、「先頭の要素と残りのリスト」のどちらかです(第6章)。この形に沿って手続きを書きます。

```scheme
(define (sum-list xs)
  (if (null? xs)
      0
      (+ (car xs) (sum-list (cdr xs)))))
(sum-list '(1 2 3 4 5))
(sum-list '())
```

```output
15
0
```

```scheme
(define (my-length xs)
  (if (null? xs)
      0
      (+ 1 (my-length (cdr xs)))))
(my-length '(a b c))
```

```output
3
```

```scheme
(define (my-append xs ys)
  (if (null? xs)
      ys
      (cons (car xs) (my-append (cdr xs) ys))))
(my-append '(1 2) '(3 4))
```

```output
(1 2 3 4)
```

どれも、「空のとき」と「そうでないとき」の2つの場合を書いています。

### 二重の再帰

フィボナッチ数は、前の2つの数の和です。再帰が2か所に出てきます。

```scheme
(define (fib n)
  (if (< n 2)
      n
      (+ (fib (- n 1)) (fib (- n 2)))))
(fib 10)
(fib 20)
```

```output
55
6765
```

この書き方は分かりやすいですが、同じ計算を何度も繰り返すので、`n` が大きくなると急に遅くなります。次の節の方法で速くできます。

## 再帰の深さ

`factorial` や `sum-list` は、再帰呼び出しの結果を受け取ってから、さらに計算(`*` や `+`)をします。呼び出しが終わるまで、「あとで掛ける」という仕事を覚えておく必要があり、再帰が深いほど、覚えておくことが増えます。

```scheme
(define (count-down n)
  (if (= n 0)
      0
      (+ 1 (count-down (- n 1)))))
(count-down 100000)
```

```output
100000
```

この処理系では、10 万段の再帰は動きます。しかし、無限に深くはできません。メモリの上限があり、超えると誤りになります。手元で、1000 万段の再帰を試すと、`error: heap limit exceeded` になりました。

## 末尾呼び出し

手続きの最後の仕事が、別の手続きの呼び出しである場合、その呼び出しを「末尾呼び出し」と呼びます。末尾呼び出しでは、呼び出し元に戻ってやる仕事がないので、覚えておくことがありません。Scheme の規格(R7RS)は、末尾呼び出しが、いくら繰り返してもメモリを増やさないことを、処理系に求めています。そのため、末尾呼び出しで書いた再帰は、ループと同じように使えます。

階乗を、途中の結果を引数で持ち回る形に書き換えます。

```scheme
(define (factorial-iter n acc)
  (if (= n 0)
      acc
      (factorial-iter (- n 1) (* n acc))))
(factorial-iter 5 1)
(factorial-iter 20 1)
```

```output
120
2432902008176640000
```

`factorial-iter` の再帰呼び出しは、`if` の枝の最後にあり、結果をそのまま返しています。これが末尾呼び出しです。`acc` は「ここまでの結果(accumulator, 累積値)」を持ち回る引数です。

末尾呼び出しなら、100 万回繰り返しても大丈夫です。

```scheme
(define (loop n)
  (if (= n 0)
      'done
      (loop (- n 1))))
(loop 1000000)
```

```output
done
```

`(loop 1000000)` は、メモリを使い続けません。JavaScript などの多くの言語では、これほど深い再帰はスタックがあふれます。Scheme では、この形が `while` ループの代わりです。

末尾にあたる位置は、次のとおりです。

- 手続きの本体の最後の式
- `if` の、真と偽の枝の式
- `cond`、`case`、`and`、`or`、`when`、`unless` の最後の式

`(+ 1 (loop ...))` のように、呼び出しの結果にさらに計算をする場合は、末尾ではありません。

## 名前つき let

末尾呼び出しの再帰を書くたびに、補助の手続きを `define` するのは面倒です。`let` に名前をつけると、その場で繰り返しを書けます。

```text
(let 名前 ((変数 初期値) ...) 本体...)
```

本体の中で `(名前 新しい値 ...)` と呼ぶと、変数を更新して先頭から繰り返します。

```scheme
(define (factorial2 n)
  (let loop ((i n) (acc 1))
    (if (= i 0)
        acc
        (loop (- i 1) (* i acc)))))
(factorial2 10)
```

```output
3628800
```

`loop` は、`let` の本体の中だけで使える手続きです。`i` と `acc` が更新される変数です。

名前つき `let` を使うと、`fib` も速くなります。

```scheme
(define (fib2 n)
  (let loop ((a 0) (b 1) (i 0))
    (if (= i n)
        a
        (loop b (+ a b) (+ i 1)))))
(fib2 10)
(fib2 90)
```

```output
55
2880067194370816120
```

`(fib2 90)` は、すぐに答えが出ます。2つの数 `a` と `b` を持ち回ることで、同じ計算の繰り返しがなくなります。

## do

`do` は、C の `for` に似た構文です。

```text
(do ((変数 初期値 更新式) ...) (終わりの条件 結果の式...) 本体...)
```

終わりの条件が真になるまで、本体を繰り返し、そのあと結果の式を評価します。

```scheme
(import (scheme write))
(do ((i 0 (+ i 1)))
    ((= i 3))
  (display i)
  (newline))
```

```output
0
1
2
```

結果の式を書くと、それが `do` の値になります。

```scheme
(do ((i 1 (+ i 1))
     (sum 0 (+ sum i)))
    ((> i 10) sum))
```

```output
55
```

1 から 10 までを足した結果です。`do` は、名前つき `let` と同じく、末尾呼び出しの再帰の書き換えに当たります。どちらを使っても、書ける範囲は変わりません。

## 竹内関数

再帰の重さを見るための例として、竹内関数 `tak` が知られています。単純な定義ですが、再帰が非常に多く繰り返されるので、処理系の性能の目安に使われてきました。

```scheme
(define (tak x y z)
  (if (<= x y)
      z
      (tak (tak (- x 1) y z)
           (tak (- y 1) z x)
           (tak (- z 1) x y))))
(tak 18 12 6)
```

```output
7
```

`(tak 18 12 6)` は、6 万回余りの呼び出しで、7 を返します。引数を少し大きくすると、呼び出しの数が急に増えます。

## 練習問題

1. 整数 `n` を受け取り、1 から `n` までの合計を返す手続き `sum-to` を、末尾呼び出しで定義してください。
2. 底 `base` の `exp` 乗を、掛け算の繰り返しで計算する手続き `power` を定義してください。`exp` は 0 以上の整数とします。
3. リストの要素のうち、偶数の個数を数える手続き `count-evens` を、名前つき `let` で書いてください。
4. 1 から 5 までの数の2乗を、`do` を使って画面に1行ずつ書いてください。

### 答え

1 の答えです。

```scheme
(define (sum-to n)
  (let loop ((i 1) (acc 0))
    (if (> i n)
        acc
        (loop (+ i 1) (+ acc i)))))
(sum-to 10)
(sum-to 100000)
```

```output
55
5000050000
```

2 の答えです。

```scheme
(define (power base exp)
  (if (= exp 0)
      1
      (* base (power base (- exp 1)))))
(power 2 10)
(power 3 0)
```

```output
1024
1
```

3 の答えです。

```scheme
(define (count-evens xs)
  (let loop ((rest xs) (n 0))
    (cond ((null? rest) n)
          ((even? (car rest)) (loop (cdr rest) (+ n 1)))
          (else (loop (cdr rest) n)))))
(count-evens '(1 2 3 4 5 6))
```

```output
3
```

4 の答えです。

```scheme
(import (scheme write))
(do ((i 1 (+ i 1)))
    ((> i 5))
  (display (* i i))
  (newline))
```

```output
1
4
9
16
25
```

## 次の章

[第8章 高階手続き](08-higher-order.md)では、手続きを引数にとる手続きを使い、繰り返しの形を取り出して再利用します。
