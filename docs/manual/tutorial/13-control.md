# 13 制御

この章では、普通の手続きの呼び出しと値の返し方では書きにくい制御の流れを学びます。複数の値を一度に返す多値、プログラムの「この先の実行」を値として取り出す継続、後始末を確実に行う `dynamic-wind` の3つです。

## 多値

手続きは、普通は値を1つ返します。2つ以上の値を返したいとき、リストやベクタにまとめることもできますが、Scheme には、複数の値をそのまま返す `values` があります。

```scheme
(define (min-max lst)
  (values (apply min lst) (apply max lst)))
(call-with-values
  (lambda () (min-max '(3 1 4 1 5)))
  list)
```

```output
(1 5)
```

`call-with-values` は、最初の引数の手続き(引数なし)を呼び、返った値のすべてを、2番目の引数の手続きに渡します。ここでは `list` に渡したので、`(1 5)` というリストになります。

この書き方は読みづらいので、`let-values` と `define-values` があります。

```scheme
(let-values (((lo hi) (min-max '(3 1 4))))
  (- hi lo))
(define-values (q r) (floor/ 17 5))
q
r
```

```output
3
3
2
```

`let-values` は、`let` と同じ形で、束縛の左側に、受け取る名前の並びを書きます。`define-values` は、`define` の多値版です。第11章の `floor/` は、商と余りの2つの値を返します。

可変長の受け取りも書けます。

```scheme
(let-values (((a . rest) (values 1 2 3))
             (all (values 4 5)))
  (list a rest all))
```

```output
(1 (2 3) (4 5))
```

値が1つなら、`(values 1)` は `1` と同じです。

```scheme
(values 1)
(+ 1 (values 2))
```

```output
1
3
```

## 継続

プログラムのある時点で、「これから実行される残りの計算」を継続(continuation)と呼びます。たとえば、次の式の `(* 2 3)` を評価する時点での継続は、「その結果に 1 を足して、結果として返す」です。

```text
(+ 1 (* 2 3))
```

`call-with-current-continuation`(短くは `call/cc`)は、その時点の継続を、手続きとして取り出します。取り出した継続を呼ぶと、そのとき実行中だった計算を捨てて、継続が表す時点に、渡した値で戻ります。

```scheme
(call/cc (lambda (k) (+ 1 (k 42))))
(+ 1 (call/cc (lambda (k) (k 10))))
(+ 1 (call/cc (lambda (k) 10)))
```

```output
42
11
11
```

1つ目では、`(k 42)` を呼んだ時点で、`(+ 1 ...)` の計算は捨てられ、`call/cc` の式全体が `42` を返します。2つ目では、`k` に渡した `10` が、`call/cc` の返す値になり、その外の `(+ 1 ...)` の計算は続きます。3つ目は、`k` を呼ばずに、手続きが 10 を返しただけで、2つ目と結果は同じです。

### 早期脱出

継続の最も単純な使い方は、深い呼び出しから抜けて、すぐに値を返す早期脱出です。C の `return` や、ループの `break` に当たります。

```scheme
(define (find-first pred lst)
  (call/cc
    (lambda (return)
      (for-each (lambda (x)
                  (if (pred x) (return x)))
                lst)
      #f)))
(find-first even? '(1 3 4 5))
(find-first even? '(1 3))
```

```output
4
#f
```

`for-each` の途中で `(return x)` を呼ぶと、残りの要素を見ずに、`find-first` が `x` を返します。

`map` の途中から抜けることもできます。

```scheme
(call/cc
  (lambda (k)
    (map (lambda (x)
           (if (negative? x) (k x) (* x 2)))
         '(1 2 -3 4))))
```

```output
-3
```

### 継続を取っておく

継続は値なので、変数に保存して、後で呼べます。呼ぶたびに、保存した時点の続きがもう一度実行されます。次のジェネレータは、リストの要素を、呼ぶたびに1つずつ返します。

```scheme
(define (make-generator lst)
  (define return #f)
  (define resume #f)
  (define (start)
    (for-each
      (lambda (x)
        (call/cc
          (lambda (next)
            (set! resume next)
            (return x))))
      lst)
    (return 'done))
  (lambda ()
    (call/cc
      (lambda (r)
        (set! return r)
        (if resume
            (resume #f)
            (start))))))
(define g (make-generator '(a b c)))
(g)
(g)
(g)
(g)
```

```output
a
b
c
done
```

仕組みは次のとおりです。

- 呼ぶたびに、呼び出し元の継続を `return` に保存します。
- `for-each` が1つの要素を渡すとき、「この要素の次から続ける」継続 `next` を `resume` に保存して、`return` で呼び出し元に値を返します。
- 次に `g` を呼ぶと、`resume` で、`for-each` の続きに戻ります。

ここでは、継続を使って、手続きの実行を途中で止めて、あとで再開しています。ほかの言語の `yield` や、コルーチンに当たります。

継続は強力ですが、読みにくいコードになりがちです。早期脱出と、エラーの扱い(第14章)のように、使う目的が決まった形で使うのが勧めです。

## dynamic-wind

ファイルを開いたら必ず閉じる、というような後始末は、途中で継続によって抜けたり、エラーが起きたりしても、確実に行いたいものです。`dynamic-wind` は、3つの手続きを取ります。

```text
(dynamic-wind 前処理 本体 後処理)
```

前処理を呼び、本体を呼び、後処理を呼びます。本体が通常に終わっても、継続やエラーで抜けても、後処理が必ず呼ばれます。値は、本体のものが返ります。

```scheme
(import (scheme write))
(dynamic-wind
  (lambda () (display "[in]"))
  (lambda () (display "body") 'result)
  (lambda () (display "[out]") (newline)))
```

```output
[in]body[out]
result
```

本体が継続で抜けるときも、後処理が呼ばれます。

```scheme
(call/cc
  (lambda (k)
    (dynamic-wind
      (lambda () (display "a"))
      (lambda () (k 'escaped))
      (lambda () (display "z") (newline)))))
```

```output
az
escaped
```

入れ子になっているときは、内側から順に、後処理が呼ばれます。

```scheme
(call/cc
  (lambda (k)
    (dynamic-wind
      (lambda () (display "a"))
      (lambda ()
        (dynamic-wind
          (lambda () (display "b"))
          (lambda () (k 1))
          (lambda () (display "c"))))
      (lambda () (display "d")))))
```

```output
abcd1
```

`a` `b` と入って、`c` `d` の順に出ていきます。

## 練習問題

1. 整数のリストを受け取り、偶数の個数と奇数の個数を、2つの値として返す手続き `count-parity` を書いてください。
2. リストの要素の積を求める手続き `product` を、`call/cc` を使って、0が見つかったら残りを見ずに0を返すように書いてください。
3. `dynamic-wind` を使って、本体の中で `call/cc` で抜けたときにも、カウンタ `depth` が元の値に戻ることを確かめてください。
4. 次の式の値を、実行する前に予想してから、確かめてください。

```text
(+ 1 (call/cc (lambda (k) (+ 10 (k 2)))))
```

### 答え

1 の答えです。

```scheme
(define (count-parity lst)
  (let loop ((rest lst) (evens 0) (odds 0))
    (cond ((null? rest) (values evens odds))
          ((even? (car rest)) (loop (cdr rest) (+ evens 1) odds))
          (else (loop (cdr rest) evens (+ odds 1))))))
(call-with-values (lambda () (count-parity '(1 2 3 4 5))) list)
```

```output
(2 3)
```

2 の答えです。

```scheme
(define (product lst)
  (call/cc
    (lambda (return)
      (let loop ((rest lst) (acc 1))
        (cond ((null? rest) acc)
              ((= (car rest) 0) (return 0))
              (else (loop (cdr rest) (* acc (car rest)))))))))
(product '(2 3 4))
(product '(2 0 4))
```

```output
24
0
```

3 の答えです。

```scheme
(define depth 0)
(call/cc
  (lambda (k)
    (dynamic-wind
      (lambda () (set! depth (+ depth 1)))
      (lambda () (k depth))
      (lambda () (set! depth (- depth 1))))))
depth
```

```output
1
0
```

本体の中では `depth` が1で、抜けたあとには0に戻っています。

4 の答えです。`(k 2)` で、`(+ 10 ...)` の計算を捨てて、`call/cc` の式が `2` になります。外の `(+ 1 ...)` は続くので、3になります。

```scheme
(+ 1 (call/cc (lambda (k) (+ 10 (k 2)))))
```

```output
3
```

## 次の章

[第14章 エラーの扱い](14-errors.md)では、エラーを起こす方法と、捕まえて処理する方法を学びます。この章の継続と `dynamic-wind` が、エラーの処理の土台になっています。
