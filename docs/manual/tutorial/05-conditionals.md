# 5 条件分岐

この章では、処理を場合分けする構文を学びます。`if`、`cond`、`case`、`and` と `or`、`when` と `unless` です。

## if

`if` は、条件が真ならひとつめの式を、偽ならふたつめの式を評価します。

```text
(if 条件 真のときの式 偽のときの式)
```

```scheme
(if (> 3 2) "yes" "no")
(if (> 2 3) "yes" "no")
```

```output
"yes"
"no"
```

C や JavaScript の `if` は文ですが、Scheme の `if` は式で、値を持ちます。C の三項演算子 `条件 ? a : b` に近いものです。そのため、式の中にそのまま書けます。

```scheme
(define (absolute x)
  (if (< x 0) (- x) x))
(absolute -5)
(absolute 5)
(+ 10 (if (even? 4) 1 2))
```

```output
5
5
11
```

選ばれなかった側の式は、評価されません。そのため、次のように、起きると困る計算を条件の裏に隠せます。

```scheme
(define (safe-div a b)
  (if (= b 0) 'undefined (/ a b)))
(safe-div 10 2)
(safe-div 10 0)
```

```output
5
undefined
```

`'undefined` は記号です。第6章で扱います。

第2章で見たとおり、`#f` 以外はすべて真です。

```scheme
(if 0 'true 'false)
(if '() 'true 'false)
(if "" 'true 'false)
(if #f 'true 'false)
```

```output
true
true
true
false
```

## cond

条件が3つ以上に分かれるときは、`if` を入れ子にするより、`cond` が読みやすくなります。

```text
(cond (条件1 式...) (条件2 式...) ... (else 式...))
```

上から順に条件を評価し、最初に真になった節の式を評価します。どれも真でなければ、`else` の節を評価します。

```scheme
(define (grade score)
  (cond ((>= score 90) 'a)
        ((>= score 80) 'b)
        ((>= score 70) 'c)
        (else 'f)))
(grade 95)
(grade 85)
(grade 42)
```

```output
a
b
f
```

C の `if ... else if ... else` の並びに当たります。

節の式の前に `=>` を書くと、条件の値を、右の手続きに渡せます。値を使いたいときに便利です(連想リストは第6章で扱います)。

```scheme
(define table '((1 . one) (2 . two)))
(cond ((assv 2 table) => cdr)
      (else 'none))
(cond ((assv 9 table) => cdr)
      (else 'none))
```

```output
two
none
```

## case

ひとつの値を、いくつかの定数と比べて分岐するときは、`case` を使います。

```text
(case 式 ((定数...) 式...) ... (else 式...))
```

```scheme
(define (day-type day)
  (case day
    ((sat sun) 'weekend)
    ((mon tue wed thu fri) 'weekday)
    (else 'unknown)))
(day-type 'sun)
(day-type 'wed)
(day-type 'foo)
```

```output
weekend
weekday
unknown
```

C の `switch` に似ていますが、`break` は要りません。1つの節に定数を複数並べられます。定数は評価されず、そのまま比較されます(`eqv?` で比べます)。

数でも使えます。

```scheme
(define (small-number-name n)
  (case n
    ((0) "zero")
    ((1 2 3) "few")
    (else "many")))
(small-number-name 0)
(small-number-name 2)
(small-number-name 10)
```

```output
"zero"
"few"
"many"
```

## and と or

`and` は、引数を左から順に評価して、偽が出たらそこで止め、その値を返します。すべて真なら、最後の値を返します。

```scheme
(and 1 2 3)
(and 1 #f 3)
(and)
```

```output
3
#f
#t
```

`or` は、引数を左から順に評価して、真が出たらそこで止め、その値を返します。すべて偽なら `#f` です。

```scheme
(or #f 2 3)
(or #f #f)
(or)
```

```output
2
#f
#f
```

どちらも、結果が決まった時点で止まるので、後ろの式は評価されないことがあります。C の `&&` と `||` と同じ性質です。

```scheme
(define (positive-and-small? n)
  (and (> n 0) (< n 10)))
(positive-and-small? 5)
(positive-and-small? 50)
(positive-and-small? -1)
```

```output
#t
#f
#f
```

返す値が真偽値とは限らない点が、他の言語と違います。この性質を使い、「値がなければ別の値」を書けます。

```scheme
(or (assv 9 '((1 . one))) 'not-found)
```

```output
not-found
```

## when と unless

条件が真(`when`)または偽(`unless`)のときだけ、いくつかの式を評価したいことがあります。`if` では、式を複数並べるのに別の構文が要ります。`when` と `unless` は、本体に式をいくつでも書けます。

```scheme
(import (scheme write))
(define (report n)
  (when (> n 0)
    (display "positive")
    (newline))
  (unless (> n 0)
    (display "not positive")
    (newline)))
(report 3)
(report -3)
```

```output
positive
not positive
```

条件が成り立たなかったとき、`when` と `unless` が返す値は、決まっていません。値を使わず、画面に書くなど、副作用のためだけに使ってください。

## 練習問題

1. 数 `n` を受けて、負なら `negative`、0 なら `zero`、正なら `positive` の記号を返す手続き `sign-name` を、`cond` で定義してください。
2. うるう年を判定する手続き `leap-year?` を定義してください。4 で割り切れ、かつ 100 で割り切れない年、または 400 で割り切れる年がうるう年です。`and` と `or` を使います。
3. `case` を使って、月の数 (1 から 12) を受け取り、その月の日数を返す手続き `days-in-month` を書いてください。うるう年は考えず、2月は 28 日とします。

### 答え

1 の答えです。

```scheme
(define (sign-name n)
  (cond ((< n 0) 'negative)
        ((= n 0) 'zero)
        (else 'positive)))
(sign-name -5)
(sign-name 0)
(sign-name 7)
```

```output
negative
zero
positive
```

2 の答えです。

```scheme
(define (leap-year? y)
  (or (and (= (remainder y 4) 0)
           (not (= (remainder y 100) 0)))
      (= (remainder y 400) 0)))
(leap-year? 2024)
(leap-year? 1900)
(leap-year? 2000)
(leap-year? 2023)
```

```output
#t
#f
#t
#f
```

3 の答えです。

```scheme
(define (days-in-month m)
  (case m
    ((1 3 5 7 8 10 12) 31)
    ((4 6 9 11) 30)
    ((2) 28)
    (else 'invalid)))
(days-in-month 1)
(days-in-month 4)
(days-in-month 2)
(days-in-month 13)
```

```output
31
30
28
invalid
```

## 次の章

[第6章 リスト](06-lists.md)では、Scheme のデータ構造の中心であるリストを学びます。
