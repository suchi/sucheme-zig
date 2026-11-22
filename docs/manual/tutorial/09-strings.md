# 9 文字列と文字

この章では、文字列(string)と文字(character)の扱いを学びます。リテラルの書き方、比較、部分文字列、変換、文字列の組み立てを順に見ます。

Scheme の文字列は、文字の並びです。文字は、文字列の要素とは別の型で、`#\a` のように書きます。JavaScript や Python と違って、1文字だけの文字列と文字は、別のものです。

## リテラルと基本の手続き

文字列は二重引用符で囲みます。`\n`(改行)、`\t`(タブ)、`\"`(二重引用符)、`\\`(バックスラッシュ)の書き方があります。文字は `#\` に続けて書き、空白や改行には名前があります。

```scheme
"hello"
#\a
#\space
#\newline
(string? "hello")
(char? #\a)
(string? #\a)
```

```output
"hello"
#\a
#\space
#\newline
#t
#t
#f
```

REPL は、値を書き出す形(`write` の形)で表示するので、文字列には二重引用符が、文字には `#\` が付きます。

長さと添字での取り出しは、次の手続きです。添字は0から数えます。範囲の外を指すと誤りになります。

```scheme
(string-length "hello")
(string-ref "hello" 1)
(string-length "日本語")
(string-ref "日本語" 1)
(string-ref "abc" 3)
```

```output
5
#\e
3
#\本
error: 5:1: argument out of range in string-ref "abc" 3
```

sucheme の文字列は Unicode の文字の並びで、`string-length` は文字の数を返します。バイトの数ではありません。バイトの数が必要なときは、第10章のバイトベクタを使います。

`char->integer` と `integer->char` で、文字とコードポイントを行き来できます。

```scheme
(char->integer #\A)
(integer->char 97)
(integer->char 955)
```

```output
65
#\a
#\λ
```

## 比較

文字列の比較には、`string=?`、`string<?`、`string>?`、`string<=?`、`string>=?` があります。文字には `char=?`、`char<?` などがあります。`<` は辞書順(文字のコードポイントの順)です。

```scheme
(string=? "abc" "abc")
(string<? "apple" "banana")
(string<? "Z" "a")
(char<? #\a #\b #\c)
```

```output
#t
#t
#t
#t
```

3行目は、大文字の `Z`(コードポイント90)が小文字の `a`(97)より前になるためです。

`=` が数にしか使えないのと同じで、`string=?` は文字列にしか使えません。`equal?` は文字列を中身で比べますが、`eq?` や `eqv?` は、同じ場所のオブジェクトかどうかを比べます。

```scheme
(equal? "abc" "abc")
(eqv? "abc" "abc")
```

```output
#t
#f
```

文字列を比べるときは、`string=?` を使ってください。

## 部分文字列と連結

`substring` は、始まりと終わりの添字を取ります。終わりは含みません。`string-append` は、文字列をつなぎます。

```scheme
(substring "hello world" 6 11)
(string-append "foo" "bar" "baz")
(string-append)
(substring "abc" 2 1)
```

```output
"world"
"foobarbaz"
""
error: 4:1: argument out of range in substring "abc" 2 1
```

型の違う引数を渡すと、別の誤りになります。

```scheme
(string-append "a" 1)
```

```output
error: 1:1: wrong type of argument to string-append "a" 1
```

数を文字列につなぐには、先に `number->string` で変換します。

```scheme
(string-append "n=" (number->string 42))
(number->string 255 16)
(string->number "42")
(string->number "abc")
```

```output
"n=42"
"ff"
42
#f
```

`string->number` は、数として読めない文字列に対して `#f` を返します。誤りにはなりません。

## 文字列を書き換える

文字列リテラルは、書き換えられません。書き換えたいときは、`string-copy` や `make-string` でコピーを作ります。

```scheme
(string-set! "abc" 0 #\x)
```

```output
error: 1:1: cannot modify a constant in string-set! "abc" 0 #\x
```

```scheme
(define s (string-copy "abc"))
(string-set! s 0 #\x)
s
(define t (make-string 3 #\a))
(string-fill! t #\z)
t
```

```output
"xbc"
"zzz"
```

`string-copy` は、範囲を指定して部分だけをコピーすることもできます。

```scheme
(string-copy "hello" 1 3)
```

```output
"el"
```

## 文字列とリスト

文字列は、リストにして、第6章と第8章の手続きで処理し、文字列に戻せます。

```scheme
(string->list "abc")
(list->string (list #\x #\y))
(list->string (reverse (string->list "stressed")))
(apply string-append (map symbol->string '(a b c)))
```

```output
(#\a #\b #\c)
"xy"
"desserts"
"abc"
```

`string-map` と `string-for-each` は、文字列の全文字に手続きを適用します。`string-map` は、手続きが返した文字から新しい文字列を作ります。

```scheme
(import (scheme char))
(import (scheme write))
(string-map char-upcase "abc")
(string-for-each (lambda (c) (display c) (display ",")) "abc")
(newline)
```

```output
"ABC"
a,b,c,
```

`char-upcase` や `string-upcase` など、大文字小文字や文字の種類にかかわる手続きは、`(scheme char)` を `import` すると使えます。`display` と `write` は `(scheme write)` に入っています。

## 大文字小文字と文字の種類

`(scheme char)` には、大文字小文字の変換、文字の種類の判定、大文字小文字を区別しない比較があります。

```scheme
(string-upcase "hello")
(string-downcase "HeLLo")
(char-upcase #\a)
(char-alphabetic? #\a)
(char-numeric? #\5)
(char-whitespace? #\space)
(digit-value #\7)
(string-ci=? "AbC" "aBc")
```

```output
"HELLO"
"hello"
#\A
#t
#t
#t
7
#t
```

Unicode の規則に従うので、英語以外の文字にも働きます。

```scheme
(string-upcase "straße")
(string-downcase "ÀB")
```

```output
"STRASSE"
"àb"
```

ドイツ語の `ß` は、大文字にすると `SS` の2文字になります。`string-upcase` の結果の長さは、元の文字列と同じとは限りません。

## 表示と書き出し

`display` と `write` は、どちらも値を出力しますが、`write` は文字列と文字を、プログラムに書ける形で出します。

```scheme
(display "a\"b")
(newline)
(write "a\"b")
(newline)
(display #\a)
(newline)
(write #\a)
(newline)
(display '(1 "two" #\3 four))
(newline)
(write '(1 "two" #\3 four))
(newline)
```

```output
a"b
"a\"b"
a
#\a
(1 two 3 four)
(1 "two" #\3 four)
```

人に見せる出力には `display`、データとして読み戻せる形が欲しいときは `write` を使います。

## 文字列ポートで文字列を組み立てる

文字列を小さな部品から組み立てるとき、`string-append` を何度も使うと、そのたびに新しい文字列ができます。文字列ポートは、書き込み先が文字列のポートで、`display` や `write` と組み合わせて使います。

```scheme
(define out (open-output-string))
(display "n=" out)
(display 42 out)
(write-char #\! out)
(write "q" out)
(get-output-string out)
```

```output
"n=42!\"q\""
```

`open-output-string` で作ったポートを、`display`、`write`、`write-char` の最後の引数に渡します。`get-output-string` は、ここまでに書いたものを文字列として返します。

反対に、文字列から読むポートが `open-input-string` です。1文字ずつ読む `read-char`、次の文字を見るだけの `peek-char`、行を読む `read-line` があります。終わりに達すると、特別な値 `eof-object` が返ります。

```scheme
(define in (open-input-string "ab\ncd"))
(read-char in)
(peek-char in)
(read-char in)
(read-line in)
(read-line in)
(eof-object? (read-char in))
```

```output
#\a
#\b
#\b
""
"cd"
#t
```

4行目の `read-line` が空の文字列を返したのは、`b` を読んだ直後の位置から、改行までの何もない部分を読んだからです。

文字列ポートを使うと、「文字を1つずつ読み、変換して、集める」処理を書けます。

```scheme
(define (shout str)
  (let ((in (open-input-string str))
        (out (open-output-string)))
    (let loop ((c (read-char in)))
      (if (eof-object? c)
          (get-output-string out)
          (begin
            (write-char (char-upcase c) out)
            (loop (read-char in)))))))
(shout "hello world")
```

```output
"HELLO WORLD"
```

## 練習問題

1. 文字列を逆順にする手続き `string-reverse` を書いてください。
2. 文字列に、指定した文字が何回出てくるかを数える手続き `count-char` を書いてください。引数は、文字列と文字の順です。
3. 文字列を受け取り、母音(`a e i o u`)を取り除いた文字列を返す手続き `remove-vowels` を、文字列ポートを使って書いてください。
4. 先頭の文字だけ大文字にして、残りを小文字にする手続き `capitalize` を書いてください。空の文字列は、そのまま返します。

### 答え

1 の答えです。

```scheme
(define (string-reverse str)
  (list->string (reverse (string->list str))))
(string-reverse "scheme")
```

```output
"emehcs"
```

2 の答えです。

```scheme
(define (count-char str ch)
  (let loop ((cs (string->list str)) (n 0))
    (cond ((null? cs) n)
          ((char=? (car cs) ch) (loop (cdr cs) (+ n 1)))
          (else (loop (cdr cs) n)))))
(count-char "banana" #\a)
(count-char "banana" #\z)
```

```output
3
0
```

3 の答えです。

```scheme
(define (remove-vowels str)
  (let ((out (open-output-string)))
    (string-for-each
      (lambda (c)
        (if (not (memv (char-downcase c) '(#\a #\e #\i #\o #\u)))
            (write-char c out)))
      str)
    (get-output-string out)))
(remove-vowels "Programming Language")
```

```output
"Prgrmmng Lngg"
```

4 の答えです。

```scheme
(define (capitalize str)
  (if (= (string-length str) 0)
      str
      (string-append
        (string (char-upcase (string-ref str 0)))
        (string-downcase (substring str 1 (string-length str))))))
(capitalize "sCHEME")
(capitalize "")
```

```output
"Scheme"
""
```

## 次の章

[第10章 ベクタとバイトベクタ](10-vectors.md)では、添字で素早く引ける配列に当たるデータと、バイトの並びを扱います。
