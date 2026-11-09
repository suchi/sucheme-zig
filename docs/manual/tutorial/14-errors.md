# 14 エラーの扱い

プログラムが動いている間には、0での割り算、範囲外の添字、存在しない変数への参照など、続行できない状況が起きます。この章では、エラーを起こす方法と、エラーを捕まえて処理する方法を学びます。Python の `raise` と `try`/`except`、JavaScript の `throw` と `try`/`catch` に当たります。

## error でエラーを起こす

自分のプログラムの中でエラーを起こすには、`error` を使います。第1引数にメッセージ(文字列)を、残りの引数に、状況を示す値(irritants)を渡します。

```scheme
(error "something bad:" 1 2)
```

```output
error: something bad: 1 2
```

エラーが起きて、どこでも捕まえられなかったときは、プログラムの実行がここで止まります。REPL では、`error: ` に続けて内容が出て、次の入力を待ちます。ファイルの実行では、標準エラーに同じ内容を出して、終了コード1で終わります。

組み込みの手続きも、不正な使い方に対して、エラーを起こします。

```scheme
(car '())
```

```output
error: wrong type of argument to car ()
```

```scheme
(vector-ref #(1 2) 5)
```

```output
error: argument out of range in vector-ref #(1 2) 5
```

```scheme
(undefined-variable)
```

```output
error: unbound variable: undefined-variable
```

## raise でエラーでない値を投げる

`raise` は、任意の値を投げます。文字列でも、記号でも、数でも、リストでも、レコードでも構いません。

```scheme
(raise 'boom)
```

```output
error: boom
```

```scheme
(raise 42)
```

```output
error: 42
```

`error` は、「エラーオブジェクト」を作って、それを `raise` する手続きです。エラーオブジェクトは、メッセージと irritants を持つ、特別な値です。

## guard で捕まえる

`guard` は、`try`/`catch` に当たります。

```text
(guard (変数 (条件 式 ...) ...)
  本体 ...)
```

本体の実行中に、`raise` や `error` で投げられた値が、変数に束縛されます。その値を、節の条件で順に調べて、最初に真になった節の式を実行します。`cond` と同じ書き方です。どの節にも合わなければ、その値は、外側に投げ直されます。

```scheme
(guard (e (#t (list 'caught e)))
  (raise 42))
(guard (e ((string? e) (list 'string e))
          ((symbol? e) (list 'symbol e)))
  (raise 'oops))
(guard (e (else 'handled))
  (raise 1))
```

```output
(caught 42)
(symbol oops)
handled
```

本体が何も投げずに終わったときは、本体の最後の式の値が返ります。

```scheme
(guard (e (#t 'error))
  (+ 1 2))
```

```output
3
```

条件のどれにも合わなければ、値は外へ投げ直されます。

```scheme
(guard (e ((string? e) 'string))
  (raise 'unhandled))
```

```output
error: unhandled
```

`guard` を入れ子にすると、内側で合わなかったものを、外側が受け取れます。

```scheme
(guard (e ((string? e) (list 'outer e)))
  (guard (e2 ((number? e2) (list 'inner e2)))
    (raise "text")))
```

```output
(outer "text")
```

## エラーオブジェクトを調べる

`error` で作ったエラーオブジェクトや、組み込みの手続きが起こしたエラーは、`error-object?` で判定でき、`error-object-message` でメッセージ、`error-object-irritants` で irritants を取り出せます。

```scheme
(guard (e ((error-object? e)
           (list (error-object-message e)
                 (error-object-irritants e))))
  (error "boom" 1 2))
(guard (e ((error-object? e)
           (error-object-message e)))
  (car '()))
(guard (e ((error-object? e)
           (error-object-message e)))
  (/ 1 0))
```

```output
("boom" (1 2))
"wrong type of argument to car"
"division by zero in /"
```

エラーオブジェクトでない値(文字列、記号、数など)に `error-object-message` を使うと、誤りになるので、先に `error-object?` で調べます。

次は、安全な割り算の手続きです。

```scheme
(define (safe-div a b)
  (guard (e ((error-object? e) 'div-error))
    (/ a b)))
(safe-div 6 3)
(safe-div 1 0)
```

```output
2
div-error
```

ファイルを開けない、データを読み取れない、というエラーは、`file-error?` と `read-error?` で見分けます。この2つの述語は、投げられた値がそれぞれの種類のエラーのときだけ真になります。

```scheme
(guard (e ((file-error? e) 'file)
          ((read-error? e) 'read)
          (else 'other))
  (raise 'z))
```

```output
other
```

## 自分のエラーの種類を作る

投げる値は何でもよいので、レコードを投げれば、エラーの種類を区別できます。第12章のレコードを使います。

```scheme
(import (scheme char))
(define-record-type <parse-error>
  (make-parse-error position message)
  parse-error?
  (position parse-error-position)
  (message parse-error-message))

(define (parse-digit ch pos)
  (if (char-numeric? ch)
      (- (char->integer ch) (char->integer #\0))
      (raise (make-parse-error pos "not a digit"))))
```

`char-numeric?` は `(scheme char)` の手続きなので、先に `import` しています。

```scheme
(guard (e ((parse-error? e)
           (list 'parse-error (parse-error-position e) (parse-error-message e))))
  (parse-digit #\x 3))
(guard (e ((parse-error? e) 'bad))
  (parse-digit #\7 0))
```

```output
(parse-error 3 "not a digit")
7
```

## 後始末と guard

`guard` が本体から抜けるとき、第13章の `dynamic-wind` の後処理が実行されます。

```scheme
(import (scheme write))
(guard (e (#t (display "caught ") 'recovered))
  (dynamic-wind
    (lambda () (display "in "))
    (lambda () (raise 'x))
    (lambda () (display "out "))))
```

```output
in out caught recovered
```

`out` は `caught` より前に出ています。`guard` は、本体を抜けてから節を実行するためです。

## with-exception-handler と raise-continuable

`guard` は、本体から抜けて、節の結果を返します。エラーが起きた場所に戻って、処理を続けたいときは、`with-exception-handler` と `raise-continuable` を使います。

```text
(with-exception-handler ハンドラ 本体の手続き)
```

`raise-continuable` で投げた値は、ハンドラに渡されます。ハンドラが返した値は、`raise-continuable` を呼んだ場所の値になり、処理が続きます。

```scheme
(with-exception-handler
  (lambda (e) 10)
  (lambda () (+ 1 (raise-continuable 'oops))))
```

```output
11
```

`(raise-continuable 'oops)` が `10` を返し、それに 1 を足して、`11` になります。

`raise` で投げた値に対しては、ハンドラが普通に返ることは許されません。続行できないからです。

```scheme
(with-exception-handler
  (lambda (e) 10)
  (lambda () (+ 1 (raise 'oops))))
```

```output
error: handler returned from non-continuable raise oops
```

`raise` に対してハンドラを使うときは、返らずに、継続で抜けます。

```scheme
(call/cc
  (lambda (k)
    (with-exception-handler
      (lambda (e) (k (list 'handled e)))
      (lambda () (raise 'x)))))
```

```output
(handled x)
```

実は、`guard` は、この組み合わせを書きやすくしたものです。普通は `guard` を使い、`raise-continuable` が要る特別な場合にだけ、`with-exception-handler` を使います。

回復の例を1つ見ます。数のリストの合計で、数でない要素は0とみなします。

```scheme
(define (sum-lenient lst)
  (with-exception-handler
    (lambda (e) 0)
    (lambda ()
      (let loop ((rest lst) (acc 0))
        (if (null? rest)
            acc
            (loop (cdr rest)
                  (+ acc (if (number? (car rest))
                             (car rest)
                             (raise-continuable (car rest))))))))))
(sum-lenient '(1 2 x 4))
```

```output
7
```

## 練習問題

1. 文字列を `string->number` で数に変換し、変換できなかったときは `error` で、メッセージ `"not a number:"` と元の文字列を irritant にしたエラーを起こす手続き `parse-number` を書いてください。
2. 練習問題1の `parse-number` を呼んで、エラーのときは 0 を返す手続き `parse-number-or-zero` を `guard` で書いてください。
3. リストの各要素に手続き `f` を適用し、エラーになった要素は結果に入れず、成功した結果だけを集める手続き `try-map` を書いてください。
4. `(guard (e ((string? e) e)) (raise 'a))` の値が何になるか、予想してから確かめてください。

### 答え

1 の答えです。

```scheme
(define (parse-number str)
  (let ((n (string->number str)))
    (if n
        n
        (error "not a number:" str))))
(parse-number "42")
```

```output
42
```

```scheme
(parse-number "abc")
```

```output
error: not a number: "abc"
```

2 の答えです。

```scheme
(define (parse-number-or-zero str)
  (guard (e ((error-object? e) 0))
    (parse-number str)))
(parse-number-or-zero "42")
(parse-number-or-zero "abc")
```

```output
42
0
```

3 の答えです。

```scheme
(define (try-map f lst)
  (cond ((null? lst) '())
        (else
         (let ((result (guard (e (#t 'failed))
                         (list (f (car lst))))))
           (if (eq? result 'failed)
               (try-map f (cdr lst))
               (cons (car result) (try-map f (cdr lst))))))))
(try-map (lambda (x) (/ 10 x)) '(1 0 2 0 5))
```

```output
(10 5 2)
```

成功した結果を `list` で包んでいるのは、結果が記号 `failed` と区別できなくなるのを避けるためです。

4 の答えです。条件 `(string? e)` に合わないので、値は外へ投げ直されて、どこでも捕まえられず、エラーになります。

```scheme
(guard (e ((string? e) e))
  (raise 'a))
```

```output
error: a
```

## 次の章

[第15章 構文の定義](15-macros.md)では、`syntax-rules` で、自分の構文(マクロ)を定義する方法を学びます。
