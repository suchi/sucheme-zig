# 10 ベクタとバイトベクタ

リストは、先頭から順にたどるデータです。n 番目の要素を取るには n 回たどる必要があります。添字で直接、素早く要素を引きたいときは、ベクタ(vector)を使います。C や Java の配列、Python のリスト、JavaScript の配列に当たります。

この章では、ベクタの作り方と使い方、リストとの使い分け、バイトの並びを扱うバイトベクタを学びます。

## ベクタを作る

ベクタは `#(` で始まる形で書くか、`vector` や `make-vector` で作ります。

```scheme
#(1 2 3)
(vector 1 2 3)
(make-vector 3 0)
(vector 'a "s" #\c 1.5)
(vector? #(1 2))
(vector-length #(1 2 3))
```

```output
#(1 2 3)
#(1 2 3)
#(0 0 0)
#(a "s" #\c 1.5)
#t
3
```

要素の型は混ぜられます。`make-vector` は、長さと、全要素の初期値を取ります。

リストの `(1 2 3)` は、手続きの呼び出しとして読まれるので、データとして書くには `quote` が要りました(第6章)。ベクタの `#(1 2 3)` は、`quote` なしで書いた形がそのまま値になります。

## 添字で引く、更新する

`vector-ref` で要素を取り、`vector-set!` で書き換えます。添字は0から始まります。

```scheme
(vector-ref #(a b c) 1)
(define v (vector 1 2 3))
(vector-set! v 0 'x)
v
(vector-ref v 2)
```

```output
b
#(x 2 3)
3
```

範囲の外を指すと、誤りになります。

```scheme
(vector-ref #(1 2) 5)
```

```output
error: argument out of range in vector-ref #(1 2) 5
```

ベクタは、第6章の `set-car!` でペアを書き換えたのと同じで、中身を変えられます。同じベクタを複数の変数が指しているときは、どれから書き換えても全員に見えます。

```scheme
(define a (make-vector 2 0))
(define b a)
(vector-set! b 1 'changed)
a
```

```output
#(0 changed)
```

`vector-fill!` で全要素を同じ値にできます。

```scheme
(define w (make-vector 3 0))
(vector-fill! w 7)
w
```

```output
#(7 7 7)
```

## リストとの行き来

`vector->list` と `list->vector` で、リストと変換できます。

```scheme
(vector->list #(1 2 3))
(list->vector '(1 2))
(vector->list #(a b c d) 1 3)
```

```output
(1 2 3)
#(1 2)
(b c)
```

3つ目の例は、`vector->list` に始まりと終わりの添字を渡して、一部だけをリストにしています。

## 高階手続き

`vector-map` と `vector-for-each` は、第8章の `map` と `for-each` のベクタ版です。

```scheme
(import (scheme write))
(vector-map (lambda (x) (* x x)) #(1 2 3))
(vector-map + #(1 2) #(10 20))
(vector-for-each (lambda (x) (display (* x 10)) (newline)) #(1 2 3))
```

```output
#(1 4 9)
#(11 22)
10
20
30
```

## 部分と連結

`vector-copy` は部分のコピーを作り、`vector-append` は連結します。コピーを書き換えても、元のベクタは変わりません。

```scheme
(define orig (vector 1 2 3 4))
(define part (vector-copy orig 1 3))
part
(vector-set! part 0 'changed)
orig
(vector-copy orig 2)
(vector-append #(1) #(2 3))
```

```output
#(2 3)
#(1 2 3 4)
#(3 4)
#(1 2 3)
```

`vector-copy!` は、あるベクタの内容を、別のベクタの途中にコピーします。引数は、コピー先、コピー先の始まりの添字、コピー元の順です。

```scheme
(define dest (vector 1 2 3 4 5))
(vector-copy! dest 0 #(a b))
dest
```

```output
#(a b 3 4 5)
```

## ループでベクタをたどる

ベクタの全要素をたどるには、第7章の名前つき `let` か `do` を使います。

```scheme
(define (vector-sum v)
  (let loop ((i 0) (acc 0))
    (if (= i (vector-length v))
        acc
        (loop (+ i 1) (+ acc (vector-ref v i))))))
(vector-sum #(1 2 3 4))
```

```output
10
```

破壊的に更新するループは、`do` で書くと読みやすくなります。次は、ベクタの要素を前後で入れ替えて、逆順にします。

```scheme
(define (vector-reverse! v)
  (let ((n (vector-length v)))
    (do ((i 0 (+ i 1)))
        ((>= i (quotient n 2)) v)
      (let ((tmp (vector-ref v i))
            (j (- n i 1)))
        (vector-set! v i (vector-ref v j))
        (vector-set! v j tmp)))))
(vector-reverse! (vector 1 2 3 4 5))
```

```output
#(5 4 3 2 1)
```

## リストとベクタの使い分け

| 操作 | リスト | ベクタ |
| --- | --- | --- |
| n 番目の要素を取る | n に比例して遅くなる | 長さによらず一定 |
| 先頭に足す | 一定 (`cons`) | 新しいベクタを作る必要がある |
| 長さを変える | 簡単 | できない(作り直す) |
| 再帰的な処理 | `car` と `cdr` で書きやすい | 添字を持ち回る |

長さが決まっていて添字で引く(表、行列、バッファ)ならベクタ、順に処理するだけで長さが変わる(積み上げ、一覧)ならリストが向いています。

### 入れ子のベクタ

行列のように、ベクタの中にベクタを入れて2次元の表を作れます。1つ気をつけることがあります。`make-vector` の第2引数は1回だけ評価されるので、全要素が同じオブジェクトを指します。

```scheme
(define bad-grid (make-vector 2 (make-vector 2 0)))
(vector-set! (vector-ref bad-grid 0) 0 'x)
bad-grid
```

```output
#(#(x 0) #(x 0))
```

行ごとに別のベクタが要るときは、行を1つずつ作ります。

```scheme
(define (make-grid rows cols init)
  (let ((g (make-vector rows)))
    (do ((i 0 (+ i 1)))
        ((= i rows) g)
      (vector-set! g i (make-vector cols init)))))
(define grid (make-grid 2 3 0))
(vector-set! (vector-ref grid 0) 1 'x)
grid
```

```output
#(#(0 x 0) #(0 0 0))
```

## バイトベクタ

バイトベクタ(bytevector)は、0から255の整数(バイト)だけを入れるベクタです。ファイルやネットワークから来る生のデータ、文字をエンコードした結果などを表します。`#u8(` で始まる形で書きます。

```scheme
#u8(1 2 3)
(bytevector 10 20 30)
(make-bytevector 2 255)
(bytevector-length #u8(1 2 3))
(bytevector-u8-ref #u8(10 20) 1)
(define b (make-bytevector 3 0))
(bytevector-u8-set! b 0 65)
b
```

```output
#u8(1 2 3)
#u8(10 20 30)
#u8(255 255)
3
20
#u8(65 0 0)
```

0から255の範囲の外の値や、整数でないものは入れられません。

```scheme
(bytevector-u8-set! (make-bytevector 1 0) 0 256)
```

```output
error: wrong type of argument to bytevector-u8-set! #u8(0) 0 256
```

`bytevector-copy`、`bytevector-append`、`bytevector-copy!` は、ベクタの対応する手続きと同じ形で使えます。

```scheme
(bytevector-copy #u8(1 2 3 4) 1 3)
(bytevector-append #u8(1) #u8(2 3))
(define buf (bytevector 1 2 3 4 5))
(bytevector-copy! buf 0 #u8(9 9))
buf
```

```output
#u8(2 3)
#u8(1 2 3)
#u8(9 9 3 4 5)
```

### 文字列と UTF-8

文字列を UTF-8 のバイトの並びに直すのが `string->utf8`、戻すのが `utf8->string` です。第9章のとおり、文字列の長さは文字の数ですが、バイトの数は文字によって違います。

```scheme
(string->utf8 "abc")
(string->utf8 "日本")
(utf8->string #u8(104 105))
(utf8->string (string->utf8 "日本"))
(string-length "日本")
(bytevector-length (string->utf8 "日本"))
```

```output
#u8(97 98 99)
#u8(230 151 165 230 156 172)
"hi"
"日本"
2
6
```

英数字は1バイトですが、日本語の文字は、この UTF-8 では3バイトを使います。

## 練習問題

1. 数のベクタを受け取り、最大の要素を返す手続き `vector-max` を書いてください。空でないベクタを仮定します。
2. `(iota-vector n)` が `#(0 1 ... n-1)` を返すように書いてください。
3. 数のベクタを受け取り、各要素を2倍にした新しいベクタを、`vector-map` を使わずに `make-vector` と `do` で作る手続き `double-all` を書いてください。
4. 文字列を受け取り、その UTF-8 のバイト列の合計(全バイトの和)を返す手続き `byte-sum` を書いてください。

### 答え

1 の答えです。

```scheme
(define (vector-max v)
  (let loop ((i 1) (best (vector-ref v 0)))
    (cond ((= i (vector-length v)) best)
          ((> (vector-ref v i) best) (loop (+ i 1) (vector-ref v i)))
          (else (loop (+ i 1) best)))))
(vector-max #(3 9 2 7))
```

```output
9
```

2 の答えです。

```scheme
(define (iota-vector n)
  (let ((v (make-vector n 0)))
    (do ((i 0 (+ i 1)))
        ((= i n) v)
      (vector-set! v i i))))
(iota-vector 5)
(iota-vector 0)
```

```output
#(0 1 2 3 4)
#()
```

3 の答えです。

```scheme
(define (double-all v)
  (let ((result (make-vector (vector-length v) 0)))
    (do ((i 0 (+ i 1)))
        ((= i (vector-length v)) result)
      (vector-set! result i (* 2 (vector-ref v i))))))
(double-all #(1 2 3))
```

```output
#(2 4 6)
```

4 の答えです。

```scheme
(define (byte-sum str)
  (let ((bv (string->utf8 str)))
    (let loop ((i 0) (acc 0))
      (if (= i (bytevector-length bv))
          acc
          (loop (+ i 1) (+ acc (bytevector-u8-ref bv i)))))))
(byte-sum "ab")
(byte-sum "日")
```

```output
195
546
```

`"ab"` は 97 + 98、`"日"` は 230 + 151 + 165 です。

## 次の章

[第11章 数](11-numbers.md)では、整数、有理数、浮動小数点数、複素数の扱いを、正確な数と不正確な数の違いから説明します。
