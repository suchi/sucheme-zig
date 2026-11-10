# 表示の書式

値が文字になる書式をまとめます。R7RS は、`write` と `display` の書式の大枠だけを定め(6.13.3 節)、数の書き方などの細部は実装に委ねています。ここに書くのは sucheme の書式で、実機で確かめた例です。変わったら、変えた変更が、この文書の例を直します([ADR-0048](../../adr/0048-run-the-examples-of-the-user-documentation.md))。

## どこで使われるか

- REPL が値を出すとき(と、この文書のコードブロックの出力)は、`write` と同じ書式です。複数の値は 1 行に 1 つずつ出し、値が 0 個のものと、未規定の値(`(if #f #f)` など)は何も出しません。
- `write` は、読み戻すと同じ値になる書式で書きます。文字列は引用符で囲み、文字は `#\` で書きます。
- `display` は、人が読む書式です。文字列の引用符と文字の `#\` を付けません。リストや配列の中の文字列と文字も、同じです。
- `write-shared` と `write-simple` は、共有と循環の書き方が違います(下の「共有と循環」)。

`display` と `write` は `(scheme write)` にあります([索引](scheme-write.md))。

```scheme fresh
(import (scheme write))
(display '(1 "two" #\3 four 5.0))
(newline)
(write '(1 "two" #\3 four 5.0))
(newline)
```

```output
(1 two 3 four 5.0)
(1 "two" #\3 four 5.0)
```

## 数

整数は十進で、有理数は約分した `分子/分母` で書きます。

```scheme fresh
42
-6/4
123456789012345678901234567890
```

```output
42
-3/2
123456789012345678901234567890
```

浮動小数点数は、読み戻すと同じ値になる十進の桁で書き、整数に見える値には `.0` を付けます。指数の形になるのは、絶対値が大きい値(1e21)と小さい値(1e-7)で、仮数は小数点を持ち、指数に符号が付きます。

```scheme fresh
1.5
100.0
(/ 1.0 3)
1e21
1e-7
```

```output
1.5
100.0
0.3333333333333333
1.0e+21
1.0e-7
```

無限大と NaN と負のゼロは、次の綴りです。

```scheme fresh
+inf.0
-inf.0
+nan.0
-0.0
```

```output
+inf.0
-inf.0
+nan.0
-0.0
```

複素数は、実部と虚部を符号付きでつなぎ、虚部のあとに `i` を付けます。実部が正確な 0 のときは、実部を書きません。虚部が正確な 0 の数は、実数です。

```scheme fresh
(import (scheme complex) (scheme inexact))
(sqrt -4)
(make-rectangular 1 2)
(make-rectangular 1.5 -2.5)
(make-polar 1 0)
```

```output
+2i
1+2i
1.5-2.5i
1
```

## 真偽値、空リスト、文字列、文字

```scheme fresh
#t
#f
'()
"a\nb\t\"q\"\\"
```

```output
#t
#f
()
"a\nb\t\"q\"\\"
```

`write` は、文字列の中の `"` と `\` と、制御文字をバックスラッシュで書きます。ASCII でない文字は、そのまま書きます。

```scheme fresh
(import (scheme write))
(write (string #\x7))
(newline)
(write (string #\x7f))
(newline)
(write (string #\x3bb))
(newline)
```

```output
"\a"
"\x7f;"
"λ"
```

文字は、名前のあるものは名前で、ほかは文字そのもので書きます。

```scheme fresh
#\a
#\space
#\newline
#\tab
#\x0
#\x3bb
#\x7f
```

```output
#\a
#\space
#\newline
#\tab
#\null
#\λ
#\delete
```

## シンボル

シンボルは、読み戻すと同じになる形で書きます。大文字小文字は区別します。空白などを含む綴りは、縦棒で囲みます。

```scheme fresh
'sym
'Abc
'|hello world|
(string->symbol "A b")
(string->symbol "")
```

```output
sym
Abc
|hello world|
|A b|
||
```

## ペア、リスト、ベクタ、バイトベクタ

```scheme fresh
'(1 2 . 3)
'(1 (2 3) #(4 5))
(vector 1 "s" #\c 'x)
(bytevector 1 2 255)
```

```output
(1 2 . 3)
(1 (2 3) #(4 5))
#(1 "s" #\c x)
#u8(1 2 255)
```

`quote` などの略記(`'x`、`` ` ``、`,`、`,@`)は、略記に戻さず、長い形で書きます。

```scheme fresh
''x
'`(a ,b ,@c)
```

```output
(quote x)
(quasiquote (a (unquote b) (unquote-splicing c)))
```

## 共有と循環

`write` は、循環する構造だけにデータラベル(`#0=` と `#0#`)を使います。循環しない共有は、ラベルを付けずに、そのまま書きます(R7RS 6.13.3 節)。`write-shared` は、共有のすべてにラベルを付け、`write-simple` は、ラベルを使いません(循環した構造に使うと終わりません)。

```scheme fresh
(import (scheme write))
(let ((x (list 1 2)))
  (set-cdr! (cdr x) x)
  (write x)
  (newline))
```

```output
#0=(1 2 . #0#)
```

```scheme fresh
(import (scheme write))
(let ((s (list 1 2)))
  (write (list s s))
  (newline)
  (write-shared (list s s))
  (newline)
  (write-simple (list s s))
  (newline))
```

```output
((1 2) (1 2))
(#0=(1 2) #0#)
((1 2) (1 2))
```

## 手続き、レコード、ポート、そのほか

手続きは `#<procedure>` と書きます。組み込みの手続きは、名前が付きます。利用者が定義した手続きに名前は付きません。

```scheme fresh
car
(lambda (x) x)
(define (named x) x)
named
```

```output
#<procedure car>
#<procedure>
#<procedure>
```

レコードの値は `#<record 型の名前>`、レコード型は `#<record-type 型の名前>` と書きます。

```scheme fresh
(import (scheme write))
(define-record-type point (make-point x y) point? (x px) (y py))
(display (make-point 1 2))
(newline)
(write point)
(newline)
```

```output
#<record point>
#<record-type point>
```

ポート、ファイルの終わり、パラメータ、約束、未規定の値は、次の書き方です。

```scheme fresh
(import (scheme write) (scheme lazy))
(write (current-output-port))
(newline)
(write (eof-object))
(newline)
(write (make-parameter 1))
(newline)
(write (delay 1))
(newline)
(write (if #f #f))
(newline)
```

```output
#<port>
#<eof>
#<parameter>
#<promise>
#<unspecified>
```
