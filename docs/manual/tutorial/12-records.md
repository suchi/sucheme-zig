# 12 レコード

名前、年齢、住所のように、複数の値を1つにまとめて扱いたいことがあります。リストやベクタで「1番目が名前、2番目が年齢」と約束して扱うこともできますが、番号の意味を覚えておく必要があり、間違えても気づけません。

レコード(record)は、名前のついた欄(フィールド)を持つ、自分で定義する型です。C の構造体、Python の dataclass、JavaScript のクラスに当たります。

## レコード型を定義する

レコード型は、`define-record-type` で定義します。

```text
(define-record-type 型の名前
  (コンストラクタ 欄の名前 ...)
  述語
  (欄の名前 アクセサ [モディファイア])
  ...)
```

次は、2次元の点の型です。

```scheme
(define-record-type point
  (make-point x y)
  point?
  (x point-x)
  (y point-y))
(define p (make-point 3 4))
(point? p)
(point? 5)
(point-x p)
(point-y p)
```

```output
#t
#f
3
4
```

この定義は、次の4つを作ります。

- `point`: 型の名前。
- `make-point`: 値を作る手続き(コンストラクタ)。引数は `(make-point x y)` の欄の名前の順。
- `point?`: 値がこの型かどうかを調べる述語。
- `point-x` と `point-y`: 欄を読み出す手続き(アクセサ)。

型の名前は、慣習として `<point>` のように山括弧で囲んで書くこともあります。山括弧に特別な意味はなく、名前の一部です。以降は、山括弧つきで書きます。

## 欄を書き換える

欄ごとに、アクセサに続けて書き換える手続き(モディファイア)の名前を書くと、書き換えられるようになります。書かなかった欄は、書き換えられません。

```scheme
(define-record-type <account>
  (make-account owner balance)
  account?
  (owner account-owner)
  (balance account-balance set-account-balance!))
(define acct (make-account "ann" 100))
(account-balance acct)
(set-account-balance! acct 150)
(account-balance acct)
(account-owner acct)
```

```output
100
150
"ann"
```

`owner` は書き換えられない欄で、`balance` だけが書き換えられます。レコードは、ベクタと同じで中身を変えられるので、同じレコードを指す全員に変更が見えます。

```scheme
(define (deposit! account amount)
  (set-account-balance! account (+ (account-balance account) amount)))
(deposit! acct 25)
(account-balance acct)
```

```output
175
```

## 型の検査

アクセサは、その型のレコードだけを受け取ります。ほかの型の値を渡すと、誤りになります。

```scheme
(point-x acct)
```

```output
error: wrong type of argument to a record accessor point-x #<record <account>>
```

リストやベクタで約束事として扱った場合と違い、取り違えがすぐに分かります。

レコードは、リストでもベクタでもありません。ほかの型の述語は、偽を返します。

```scheme
(pair? p)
(vector? p)
(account? p)
(account? acct)
```

```output
#f
#f
#f
#t
```

## 表示

レコードを `display` や `write` で表示すると、型の名前だけが出ます。欄の値は出ません。

```scheme
(import (scheme write))
(display p)
(newline)
(display (list p p))
(newline)
```

```output
#<record point>
(#<record point> #<record point>)
```

中身を見たいときは、アクセサで取り出して表示する手続きを、自分で書きます。

```scheme
(define (show-point p)
  (display "(")
  (display (point-x p))
  (display ", ")
  (display (point-y p))
  (display ")")
  (newline))
(show-point p)
```

```output
(3, 4)
```

## 欄を一部だけ初期化する

コンストラクタの引数には、すべての欄を並べなくてもかまいません。コンストラクタに並べなかった欄は、モディファイアで後から設定するまで、値が決まっていません。

```scheme
(define-record-type <person>
  (make-person name)
  person?
  (name person-name)
  (age person-age set-person-age!))
(define bob (make-person "bob"))
(set-person-age! bob 30)
(person-name bob)
(person-age bob)
```

```output
"bob"
30
```

設定する前の値を読むのは、避けてください。

## レコードを使って、データ構造を作る

レコードと手続きで、データ構造を包んで隠せます。次は、積み上げ式のスタックです。中身のリストは、利用者が直接さわらず、`push!` と `pop!` だけで操作します。

```scheme
(define-record-type <stack>
  (make-stack-raw items)
  stack?
  (items stack-items set-stack-items!))

(define (make-stack) (make-stack-raw '()))
(define (stack-empty? s) (null? (stack-items s)))
(define (push! s x)
  (set-stack-items! s (cons x (stack-items s))))
(define (pop! s)
  (let ((x (car (stack-items s))))
    (set-stack-items! s (cdr (stack-items s)))
    x))

(define st (make-stack))
(push! st 1)
(push! st 2)
(push! st 3)
(pop! st)
(pop! st)
(stack-empty? st)
(pop! st)
(stack-empty? st)
```

```output
3
2
#f
1
#t
```

`make-stack-raw` と `make-stack` に分けたのは、利用者に、中身の初期値を意識させない公開の窓口を見せるためです。

## 同じかどうかの比較

`eqv?` は、同じレコードかどうかを調べます。`equal?` は、レコードの中身を比べるのではなく、同じものかどうかを調べます。中身が同じ2つのレコードは、別のものです。

```scheme
(define p1 (make-point 1 2))
(define p2 (make-point 1 2))
(eqv? p1 p1)
(eqv? p1 p2)
(equal? p1 p2)
```

```output
#t
#f
#f
```

中身が同じかどうかを調べたいときは、アクセサで取り出して、自分で比較します。

```scheme
(define (point=? a b)
  (and (= (point-x a) (point-x b))
       (= (point-y a) (point-y b))))
(point=? p1 p2)
```

```output
#t
```

## 練習問題

1. 長方形を表すレコード型 `<rect>` を定義してください。欄は `width` と `height` で、どちらも書き換えられないものとします。
2. 練習問題1の `<rect>` の面積を返す `rect-area` を書いてください。
3. 2つの点の距離を返す手続き `distance` を書いてください。平方根が要るので、整数で割り切れない場合は不正確な数になります。
4. 生徒を表す `<student>` を、名前と点数の欄で定義し、`<student>` のリストを受け取って、点数の合計を返す手続き `total-score` を書いてください。

### 答え

1 と 2 の答えです。

```scheme
(define-record-type <rect>
  (make-rect width height)
  rect?
  (width rect-width)
  (height rect-height))
(define (rect-area r)
  (* (rect-width r) (rect-height r)))
(rect-area (make-rect 3 4))
```

```output
12
```

3 の答えです。

```scheme
(import (scheme inexact))
(define (distance a b)
  (let ((dx (- (point-x a) (point-x b)))
        (dy (- (point-y a) (point-y b))))
    (sqrt (+ (* dx dx) (* dy dy)))))
(distance (make-point 0 0) (make-point 3 4))
(distance (make-point 0 0) (make-point 1 1))
```

```output
5
1.4142135623730951
```

4 の答えです。

```scheme
(define-record-type <student>
  (make-student name score)
  student?
  (name student-name)
  (score student-score))
(define (total-score students)
  (apply + (map student-score students)))
(total-score
  (list (make-student "ann" 80)
        (make-student "bob" 65)
        (make-student "cat" 90)))
```

```output
235
```

## 次の章

[第13章 制御](13-control.md)では、複数の値を返す方法と、プログラムの実行の続きを値として扱う継続を学びます。
