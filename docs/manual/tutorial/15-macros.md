# 15 構文の定義

手続きは、引数をすべて評価してから呼ばれます。そのため、`if` のように、条件に応じて一部の式だけを評価する構文は、手続きでは書けません。Scheme では、新しい構文を自分で定義できます。この仕組みをマクロ(macro)と呼びます。

マクロは、コードを、別のコードに書き換える規則です。プログラムが実行される前に、書き換えが行われます。C のプリプロセッサの `#define` に似ていますが、文字列の置き換えではなく、式の構造に基づいた書き換えで、変数の取り違えが起きないように守られています。

## define-syntax と syntax-rules

マクロは、`define-syntax` で名前をつけ、`syntax-rules` で書き換えの規則を書きます。

```text
(define-syntax 名前
  (syntax-rules (リテラル ...)
    (パターン テンプレート)
    ...))
```

規則は、パターンとテンプレートの組です。マクロの呼び出しが、パターンに合ったら、テンプレートに書き換えられます。パターンの先頭の要素(マクロの名前の位置)は、`_` と書きます。

最初の例は、2つの変数の値を入れ替える `swap!` です。

```scheme
(define-syntax swap!
  (syntax-rules ()
    ((_ a b)
     (let ((tmp a))
       (set! a b)
       (set! b tmp)))))
(define x 1)
(define y 2)
(swap! x y)
(list x y)
```

```output
(2 1)
```

`(swap! x y)` は、パターン `(_ a b)` に合います。`a` が `x` に、`b` が `y` に対応して、テンプレートの `a` と `b` に代入され、次のコードに書き換わります。

```text
(let ((tmp x))
  (set! x y)
  (set! y tmp))
```

`swap!` は、手続きでは書けません。手続きに `x` と `y` を渡しても、渡されるのは値で、変数ではないので、変数に代入できないからです。

## 引数の評価を制御する

`unless` のような構文は、条件に応じて、本体を評価するかしないかを決めます。

```scheme
(define-syntax my-unless
  (syntax-rules ()
    ((_ condition body ...)
     (if condition #f (begin body ...)))))
(my-unless #f 1 2 3)
(my-unless #t (car '()))
```

```output
3
#f
```

パターンの `body ...` は、0個以上の式にそれぞれ対応します。テンプレートの `body ...` で、それらが並べて展開されます。

2つ目の例では、`condition` が真なので、本体の `(car '())` は評価されません。手続きでは、引数は呼ぶ前にすべて評価されるので、この例は誤りになります。

もっと長く使う例として、`while` を定義します。

```scheme
(import (scheme write))
(define-syntax while
  (syntax-rules ()
    ((_ condition body ...)
     (let loop ()
       (when condition
         body ...
         (loop))))))
(define i 0)
(while (< i 3)
  (display i)
  (newline)
  (set! i (+ i 1)))
```

```output
0
1
2
```

`while` は、C や Python にある構文ですが、Scheme には標準でありません。マクロで足せます。

## 再帰するマクロ

マクロの規則は、テンプレートの中で、そのマクロ自身を使えます。これで、引数の数に応じた展開を書けます。複数の規則があるときは、上から順に試して、最初に合ったものを使います。

```scheme
(define-syntax my-or
  (syntax-rules ()
    ((_) #f)
    ((_ e) e)
    ((_ e rest ...)
     (let ((t e))
       (if t t (my-or rest ...))))))
(my-or)
(my-or 5)
(my-or #f #f 3)
(my-or #f (+ 1 2) (car '()))
```

```output
#f
5
3
3
```

`my-or` は、`or` と同じ動きをします。最初に真になる式の値を返し、それ以降の式は評価しません。4つ目の例で、`(car '())` が評価されず、エラーにならないのは、そのためです。

## リテラルを使う

`syntax-rules` の最初の括弧には、パターンの中で、変数としてでなく、そのままの名前として扱う語(リテラル)を並べます。構文の中の「区切りの語」を作るときに使います。

```scheme
(define-syntax for
  (syntax-rules (in)
    ((_ x in lst body ...)
     (for-each (lambda (x) body ...) lst))))
(for v in '(1 2 3)
  (display (* v v))
  (newline))
```

```output
1
4
9
```

`in` がリテラルなので、`(for v in ...)` の `in` の位置に別の語を書くと、パターンに合いません。

## 衛生性

`swap!` のテンプレートは、一時変数 `tmp` を使っています。利用者が、`tmp` という名前の変数を使っていたら、どうなるでしょうか。

```scheme
(define tmp 10)
(define other 20)
(swap! tmp other)
(list tmp other)
```

```output
(20 10)
```

正しく入れ替わっています。`syntax-rules` のマクロは、衛生的(hygienic)です。テンプレートの中の `tmp` と、利用者のコードの `tmp` は、同じ名前でも、別の変数として扱われます。C のプリプロセッサ・マクロのように、`tmp` が衝突して、結果がおかしくなることはありません。

衛生性は、逆の向きにも働きます。マクロが使う `if` が、利用者の定義で隠されることもありません。

```scheme
(let ((if list))
  (my-unless #f 'ok))
```

```output
ok
```

利用者が、局所的に `if` という名前の変数を定義しても、`my-unless` の中の `if` は、本来の `if` のままです。

## 規則に合わないとき

どの規則にも合わない呼び出しは、誤りになります。

```scheme
(define-syntax ten
  (syntax-rules ()
    ((_) 10)))
(ten)
(ten 1)
```

```output
10
error: bad syntax: no rule of ten matches the form
```

## 繰り返しのパターン

パターンの `...` は、直前の要素の0回以上の繰り返しです。要素がリストの組などの構造のときも使えます。

```scheme
(define-syntax pairs
  (syntax-rules ()
    ((_ (a b) ...)
     (list (cons a b) ...))))
(pairs (1 2) (3 4))
(pairs)
```

```output
((1 . 2) (3 . 4))
()
```

`let*` のように、再帰して束縛を1つずつ展開する規則も書けます。

```scheme
(define-syntax my-let*
  (syntax-rules ()
    ((_ () body ...)
     (let () body ...))
    ((_ ((name value) rest ...) body ...)
     (let ((name value))
       (my-let* (rest ...) body ...)))))
(my-let* ((a 1) (b (+ a 1)) (c (* b 2)))
  (list a b c))
```

```output
(1 2 4)
```

## 局所的なマクロ

`let-syntax` と `letrec-syntax` は、`let` と `letrec` に当たる、局所的なマクロの定義です。

```scheme
(let-syntax ((double (syntax-rules ()
                       ((_ e) (* e 2)))))
  (double 21))
```

```output
42
```

## 注意

`syntax-rules` は、書き換えの規則だけを書けます。パターンと、テンプレートで、計算(足し算など)をすることはできません。計算が必要なら、展開された結果のコードが実行時に行います。

## 練習問題

1. 変数に1を足す `inc!` を定義してください。`(inc! n)` で1を足し、`(inc! n 10)` で10を足せるようにします。
2. 条件が偽のあいだ本体を繰り返す `until` を定義してください。`(until (> i 3) ...)` のように使います。
3. `my-or` と同じ要領で、`my-and` を定義してください。
4. `(unless-zero n body ...)` を定義してください。`n` が0でないときだけ本体を実行します。

### 答え

1 の答えです。規則を2つ並べます。

```scheme
(define-syntax inc!
  (syntax-rules ()
    ((_ v) (set! v (+ v 1)))
    ((_ v n) (set! v (+ v n)))))
(define n 5)
(inc! n)
(inc! n 10)
n
```

```output
16
```

2 の答えです。

```scheme
(define-syntax until
  (syntax-rules ()
    ((_ condition body ...)
     (let loop ()
       (if (not condition)
           (begin body ... (loop)))))))
(define j 0)
(until (> j 3)
  (display j)
  (set! j (+ j 1)))
(newline)
```

```output
0123
```

3 の答えです。

```scheme
(define-syntax my-and
  (syntax-rules ()
    ((_) #t)
    ((_ e) e)
    ((_ e rest ...)
     (if e (my-and rest ...) #f))))
(my-and)
(my-and 1 2 3)
(my-and 1 #f (car '()))
```

```output
#t
3
#f
```

4 の答えです。

```scheme
(define-syntax unless-zero
  (syntax-rules ()
    ((_ n body ...)
     (if (= n 0) #f (begin body ...)))))
(unless-zero 5 'nonzero)
(unless-zero 0 'nonzero)
```

```output
nonzero
#f
```

## 次の章

[第16章 パラメータと遅延評価](16-parameters-and-promises.md)では、動的な範囲を持つ設定の値と、計算を先送りして必要になったときに行う仕組みを学びます。
