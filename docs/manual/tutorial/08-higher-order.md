# 8 高階手続き

手続きは値なので、手続きを引数に取る手続きや、手続きを返す手続きを書けます。このような手続きを高階手続きと呼びます。この章では、`map`、`for-each`、`apply` と、繰り返しの形を取り出して再利用する書き方を学びます。

## map

`map` は、リストの全要素に手続きを適用して、結果のリストを返します。

```scheme
(map (lambda (x) (* x x)) '(1 2 3 4))
(map car '((a 1) (b 2) (c 3)))
(map even? '(1 2 3 4))
```

```output
(1 4 9 16)
(a b c)
(#f #t #f #t)
```

C や Python で、`for` ループを書いて、新しい配列に要素を足していく処理に当たります。JavaScript の `Array.prototype.map`、Python の `map` と同じ考え方です。

リストを複数渡すと、手続きは同じ位置の要素をまとめて受け取ります。リストの長さが違うときは、短いほうに合わせます。

```scheme
(map + '(1 2 3) '(10 20 30))
(map (lambda (x y) (list x y)) '(a b c) '(1 2 3))
(map + '(1 2 3) '(10 20))
```

```output
(11 22 33)
((a 1) (b 2) (c 3))
(11 22)
```

`map` の中身は、第7章の再帰で書けます。1つのリストだけを受ける簡単な版を書くと、次のようになります。

```scheme
(define (my-map f xs)
  (if (null? xs)
      '()
      (cons (f (car xs)) (my-map f (cdr xs)))))
(my-map (lambda (x) (+ x 1)) '(1 2 3))
```

```output
(2 3 4)
```

## for-each

`for-each` は、`map` と同じようにリストの全要素に手続きを適用しますが、結果を集めません。画面への出力など、副作用のために使います。

```scheme
(import (scheme write))
(for-each (lambda (x)
            (display x)
            (newline))
          '(1 2 3))
```

```output
1
2
3
```

`for-each` は、リストの先頭から順に手続きを呼びます。`map` が呼ぶ順序は、決まっていません。呼ぶ順序に意味がある(出力など)ときは、`for-each` を使ってください。

```scheme
(for-each (lambda (x y)
            (display (+ x y))
            (newline))
          '(1 2 3)
          '(10 20 30))
```

```output
11
22
33
```

## apply

`apply` は、リストの要素を引数として、手続きを呼びます。

```scheme
(apply + '(1 2 3 4))
(apply max '(3 9 2))
(apply + 1 2 '(3 4))
```

```output
10
9
10
```

`(apply + '(1 2 3 4))` は、`(+ 1 2 3 4)` と同じです。最後の引数がリストで、その前に引数を足すこともできます。

JavaScript のスプレッド構文 `f(...args)`、Python の `f(*args)` に当たります。可変長の引数(第4章)を受け取った手続きが、別の手続きに引数を渡すときに使います。

```scheme
(define (sum . numbers)
  (apply + numbers))
(sum 1 2 3)
(sum)
```

```output
6
0
```

## 手続きを返す手続き

第4章で、`make-adder` のように、手続きを返す手続きを見ました。これを使うと、似た手続きを簡単につくれます。

```scheme
(define (make-multiplier n)
  (lambda (x) (* x n)))
(define double (make-multiplier 2))
(define triple (make-multiplier 3))
(map double '(1 2 3))
(map triple '(1 2 3))
```

```output
(2 4 6)
(3 6 9)
```

手続きを組み合わせる手続きもつくれます。

```scheme
(define (compose f g)
  (lambda (x) (f (g x))))
(define add1 (lambda (x) (+ x 1)))
(map (compose double add1) '(1 2 3))
```

```output
(4 6 8)
```

最初の引数だけを渡して、残りを待つ手続きをつくることを、部分適用と呼びます。

```scheme
(define (partial f . fixed)
  (lambda args
    (apply f (append fixed args))))
(define add10 (partial + 10))
(add10 5)
((partial list 'a 'b) 'c 'd)
```

```output
15
(a b c d)
```

## 繰り返しの形を取り出す

第7章で書いた `sum-list` と `my-length` は、似た形をしていました。違うのは、「空のときの値」と「要素と残りの結果をどう合わせるか」だけです。この違いを引数にすれば、共通の部分を1つの手続きにできます。

```scheme
(define (fold-right-list f init xs)
  (if (null? xs)
      init
      (f (car xs) (fold-right-list f init (cdr xs)))))
(fold-right-list + 0 '(1 2 3 4))
(fold-right-list (lambda (x acc) (+ acc 1)) 0 '(a b c))
(fold-right-list cons '() '(1 2 3))
```

```output
10
3
(1 2 3)
```

1行目は、合計です。2行目は、要素を無視して `acc` に 1 ずつ足していくので、長さになります。3行目は、`cons` で元のリストを組み立てなおしています。

このような手続きを、畳み込み(fold)と呼びます。右から畳み込む版を書きました。左から、途中の結果を持ち回る版も書けます。

```scheme
(define (fold-left-list f init xs)
  (if (null? xs)
      init
      (fold-left-list f (f init (car xs)) (cdr xs))))
(fold-left-list + 0 '(1 2 3 4))
(fold-left-list (lambda (acc x) (cons x acc)) '() '(1 2 3))
```

```output
10
(3 2 1)
```

左からの畳み込みは末尾呼び出しなので、第7章のとおり、リストが長くてもメモリを増やしません。2つめの例では、要素を先頭に積んでいくので、リストが逆順になります。

### filter も自分で書く

条件を満たす要素だけを残す `filter` は、R7RS-small の標準には入っていません。自分で書くのは簡単です。

```scheme
(define (my-filter pred xs)
  (cond ((null? xs) '())
        ((pred (car xs)) (cons (car xs) (my-filter pred (cdr xs))))
        (else (my-filter pred (cdr xs)))))
(my-filter odd? '(1 2 3 4 5))
(my-filter (lambda (x) (> x 2)) '(1 2 3 4 5))
```

```output
(1 3 5)
(3 4 5)
```

畳み込みと `map`、`filter` を組み合わせると、ループを書かずに、データの変換を書けます。

```scheme
(define (sum-of-odd-squares xs)
  (fold-left-list + 0
    (map (lambda (x) (* x x))
         (my-filter odd? xs))))
(sum-of-odd-squares '(1 2 3 4 5))
```

```output
35
```

奇数 1、3、5 の2乗の合計 1 + 9 + 25 です。

## 練習問題

1. リストの各要素を文字列の長さに置き換える式を、`map` と `string-length` で書いてください。`'("apple" "fig" "banana")` が対象です。
2. `my-filter` を使って、リストから、正の数だけを取り出してください。
3. `fold-left-list` を使って、リストの最大値を求める手続き `list-max` を書いてください。空でないリストを仮定します。
4. 手続き `f` を受け取り、`f` を2回適用する手続きを返す `twice` を書いてください。`(twice add1)` に 5 を渡すと、7 になります。

### 答え

1 の答えです。

```scheme
(map string-length '("apple" "fig" "banana"))
```

```output
(5 3 6)
```

2 の答えです。

```scheme
(my-filter positive? '(3 -1 4 -1 5 -9))
```

```output
(3 4 5)
```

3 の答えです。最初の要素を初期値にして、残りを畳み込みます。

```scheme
(define (list-max xs)
  (fold-left-list max (car xs) (cdr xs)))
(list-max '(3 9 2 7))
```

```output
9
```

4 の答えです。

```scheme
(define (twice f)
  (lambda (x) (f (f x))))
((twice add1) 5)
((twice double) 5)
```

```output
7
20
```

## 次の章

ここまでで、このチュートリアルの基本の部分(1 から 8 章)は終わりです。[第9章 文字列と文字](09-strings.md)から、文字列、ベクタ、数の詳しい扱い、レコード、制御、エラー処理、構文の定義、ライブラリを順に説明します。
