# 6 リスト

この章では、Scheme のデータ構造の中心であるリストを学びます。ペア、`car` と `cdr`、`quote`、リストを扱う手続き、連想リストを扱います。

## ペアとリスト

Scheme の基本的なデータ構造は、2つの値をまとめた「ペア」です。`cons` でつくります。

```scheme
(cons 1 2)
```

```output
(1 . 2)
```

ペアの左を `car`、右を `cdr` で取り出します。名前は古い計算機の命令に由来します。

```scheme
(define p (cons 1 2))
(car p)
(cdr p)
```

```output
1
2
```

ペアの右に、またペアをつなげていくと、リストになります。リストの終わりは、空のリスト `()` です。

```scheme
(cons 1 (cons 2 (cons 3 '())))
```

```output
(1 2 3)
```

`(1 2 3)` は、`(1 . (2 . (3 . ())))` を短く書いたものです。リストは、「先頭の要素」と「残りのリスト」のペアです。`car` が先頭の要素、`cdr` が残りのリストになります。

```scheme
(define xs (list 1 2 3))
(car xs)
(cdr xs)
(car (cdr xs))
(cadr xs)
(cddr xs)
```

```output
1
(2 3)
2
2
(3)
```

`list` は、引数を並べたリストをつくります。`cadr` は `(car (cdr ...))` の略記で、このように `a` と `d` を並べた名前が定義されています。

C や Python の配列やリストと違って、Scheme のリストは「ペアのつながり」です。先頭から順にたどるのは速いですが、n 番目の要素を取り出すには、n 回たどる必要があります。

## quote

リストを書くとき、`(1 2 3)` と書くと、`1` を手続きとして呼ぶ式になってしまいます(第2章で見たとおり、誤りです)。式でなくデータとして書くには、`quote` を使います。

```scheme
(quote (1 2 3))
'(1 2 3)
```

```output
(1 2 3)
(1 2 3)
```

`'` は `quote` の略記です。`'x` は `(quote x)` の意味で、「x を評価せず、そのまま渡す」という指示です。

名前を `quote` すると、記号(シンボル)になります。記号は、名前そのものを表す値です。

```scheme
(define x 10)
x
'x
(list 'a 'b 'c)
(list x x)
(list 'x 'x)
```

```output
10
x
(a b c)
(10 10)
(x x)
```

`x` は変数 `x` の値 10 で、`'x` は記号 `x` です。記号は、`eq?` で同じかどうかを比べるのが基本です。

```scheme
(eq? 'abc 'abc)
(eq? 'abc 'abd)
(symbol? 'abc)
(symbol? "abc")
```

```output
#t
#f
#t
#f
```

リストの中の一部だけを評価したいときは、`` ` ``(準引用)と `,`(カンマ)を使います。

```scheme
(define n 5)
`(n is ,n)
`(1 ,(+ 1 1) ,@(list 3 4))
```

```output
(n is 5)
(1 2 3 4)
```

`` ` `` のリストの中では、`,式` の部分だけが評価されて値に置き換わります。`,@式` は、リストの中身をその場に展開します。

## リストを調べる

```scheme
(null? '())
(null? '(1))
(pair? '(1 2))
(pair? '())
(list? '(1 2))
(list? 5)
(length '(a b c))
(length '())
```

```output
#t
#f
#t
#f
#t
#f
3
0
```

`null?` は、空のリストかどうかを調べます。リストを処理する再帰(第7章)で必ず使います。

## リストを組み立てる

```scheme
(append '(1 2) '(3 4))
(append '(1) '(2) '(3))
(reverse '(1 2 3))
(list-tail '(a b c d) 2)
(list-ref '(a b c d) 2)
```

```output
(1 2 3 4)
(1 2 3)
(3 2 1)
(c d)
c
```

`append` は、リストをつないだ新しいリストを返します。`list-tail` は先頭から指定の個数を取り除いた残りを、`list-ref` は指定の位置の要素を返します。位置は 0 から数えます。

リストの範囲を超えた位置を指定すると、誤りになります。

```scheme
(list-ref '(a b c) 10)
```

```output
error: argument out of range in list-ref (a b c) 10
```

`car` や `cdr` を、空のリストに使っても、誤りです。

```scheme
(car '())
```

```output
error: 1:1: wrong type of argument to car ()
```

### 元のリストは変わらない

`append` や `reverse` は、新しいリストを返します。元のリストは変わりません。

```scheme
(define lst '(1 2 3))
(reverse lst)
lst
```

```output
(3 2 1)
(1 2 3)
```

先頭に要素を足すときは、`cons` を使います。これは速く、元のリストを変えません。

```scheme
(cons 0 lst)
lst
```

```output
(0 1 2 3)
(1 2 3)
```

## 探す

`memq`、`memv`、`member` は、リストの中から要素を探します。見つかれば、そこから先のリストを、見つからなければ `#f` を返します。3つの違いは、要素を比べる手続きです。`memq` は `eq?`、`memv` は `eqv?`、`member` は `equal?` を使います。

```scheme
(memq 'c '(a b c d))
(memq 'z '(a b c d))
(member "b" '("a" "b" "c"))
(member '(1) '((0) (1) (2)))
```

```output
(c d)
#f
("b" "c")
((1) (2))
```

文字列やリストのように、中身で比べたいものは、`equal?` を使う `member` で探します。

## 連想リスト

「名前から値を引く」表は、ペアのリストで書けます。これを連想リストと呼びます。

```scheme
(define phone-book
  '(("alice" . 1111)
    ("bob" . 2222)
    ("carol" . 3333)))
(assoc "bob" phone-book)
(cdr (assoc "bob" phone-book))
(assoc "dave" phone-book)
```

```output
("bob" . 2222)
2222
#f
```

`assoc` は、`car` が引数と等しい最初のペアを返します。見つからなければ `#f` です。`assq` と `assv` も、`memq` と `memv` と同様に、比べる手続きが違います。記号のキーなら `assq` を使います。

```scheme
(define colors '((red . 1) (green . 2) (blue . 3)))
(assq 'green colors)
(cdr (assq 'blue colors))
```

```output
(green . 2)
3
```

連想リストに項目を足すには、`cons` で先頭に足します。同じキーがあっても、先頭が先に見つかるので、新しい値が優先されます。

```scheme
(define colors2 (cons '(red . 10) colors))
(cdr (assq 'red colors2))
(cdr (assq 'red colors))
```

```output
10
1
```

連想リストは、項目が少ないときに便利です。たくさんあるときは、探すのに時間がかかります。

## 練習問題

1. リストの 2 番目の要素を返す式を、`car` と `cdr` だけで書いてください。リスト `'(a b c d)` から `b` を取り出します。
2. `(1 2 3)` と `(4 5 6)` をつないで、さらに逆順にしたリストを、`append` と `reverse` を使って求めてください。
3. 次の電話帳から、`carol` の番号を探してください。見つからない人を探すと `#f` になることも確かめてください。

```text
(define book '((alice . 1111) (bob . 2222) (carol . 3333)))
```

### 答え

1 の答えです。

```scheme
(car (cdr '(a b c d)))
```

```output
b
```

2 の答えです。

```scheme
(reverse (append '(1 2 3) '(4 5 6)))
```

```output
(6 5 4 3 2 1)
```

3 の答えです。

```scheme
(define book '((alice . 1111) (bob . 2222) (carol . 3333)))
(cdr (assq 'carol book))
(assq 'dave book)
```

```output
3333
#f
```

## 次の章

[第7章 再帰と末尾呼び出し](07-recursion.md)では、リストを再帰で処理する方法と、繰り返しの書き方を学びます。
