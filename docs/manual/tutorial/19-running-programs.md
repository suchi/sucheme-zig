# 19 プログラムとして動かす

前の章まで、式を REPL に打つ形で例を見てきました。この章では、ファイルに書いたプログラムを、コマンドから実行するときに使う機能を学びます。コマンドライン引数を受け取ること、終了コードを決めて終わること、処理にかかった時間を測ることです。

この章で使う手続きは、`(scheme process-context)` と `(scheme time)` に入っています。

```scheme
(import (scheme base) (scheme write) (scheme process-context) (scheme time))
```

## コマンドライン引数

`command-line` は、プログラムが起動されたときのコマンドラインを、文字列のリストで返します。先頭の要素は実行したファイルの名前で、続く要素が、ファイル名のあとに書いた引数です。Python の `sys.argv` に当たります。

ここからのコマンドの例は、どれも `zig build check-examples` が、`tutorial/examples/` の下で実行ファイルを走らせて確かめています。

次の `sum-args.scm` は、引数の数をすべて足して出します。

```text
(import (scheme base) (scheme write) (scheme process-context))

(define args (cdr (command-line)))

(if (null? args)
    (begin
      (display "usage: sum-args.scm NUMBER ...")
      (newline)
      (exit 2))
    (begin
      (display (apply + (map string->number args)))
      (newline)))
```

```console
$ sucheme sum-args.scm 1 2 3
6
$ sucheme sum-args.scm 10 2.5 1/2
13.0
```

引数はいつも文字列で届きます。数として使うには、`string->number` で変換します。`string->number` は、数として読めない文字列には `#f` を返します。

```scheme
(map string->number '("42" "2.5" "abc" "1/3"))
```

```output
(42 2.5 #f 1/3)
```

`command-line` の先頭の要素を除くために、`cdr` を使っています。引数が1つも無いときは、`(cdr (command-line))` が空のリストになるので、使い方を示して終わる、という作りにできます。

## exit で終わる

プログラムが終わるとき、終了コード(exit status)という整数を OS に返します。0 が成功で、0 以外が失敗です。シェルのスクリプトや、ほかのプログラムが、この値で成否を判断します。

`exit` は、プログラムをその場で終わらせます。引数で終了コードを決めます。

- 引数なし、または `#t`: 終了コード 0。
- `#f`: 終了コード 1。
- 整数: その値(下位 8 ビット)。

先の `sum-args.scm` は、引数が無いときに `(exit 2)` で終わります。

```console
$ sucheme sum-args.scm
usage: sum-args.scm NUMBER ...
[exit 2]
```

`[exit 2]` は、終了コードが 2 だったことを示す、この文書の書き方です。0 のときは書きません。

`exit` は、`dynamic-wind` の `after` の手続き(第13章)を呼んでから終わります。後片づけが必要な処理は、`dynamic-wind` で包んでおくと、`exit` で終わるときも後片づけが走ります。

`cleanup-exit.scm` の内容です。

```text
(import (scheme base) (scheme write) (scheme process-context))

(dynamic-wind
  (lambda () (display "start") (newline))
  (lambda () (exit 3))
  (lambda () (display "cleanup") (newline)))
```

```console
$ sucheme cleanup-exit.scm
start
cleanup
[exit 3]
```

後片づけを走らせずに、すぐ終わらせたいときは `emergency-exit` を使います。引数の意味は `exit` と同じです。

`emergency.scm` は、`cleanup-exit.scm` の `exit` を `emergency-exit` にしただけのものです。

```console
$ sucheme emergency.scm
start
[exit 4]
```

誤りを捕まえずにプログラムを終わらせたときの終了コードは 1 です。第18章の `missing.scm` がその例でした。ほかの終了コードの意味は、[ユーザーズガイド](../guide/02-command-line.md)にあります。

## 環境変数

`get-environment-variable` は、環境変数の値を文字列で返します。無い環境変数には `#f` を返します。

```scheme
(get-environment-variable "SUCHEME_SURELY_UNSET_VARIABLE")
```

```output
#f
```

`PATH` や `HOME` のような変数の値は、実行する環境によって変わります。値に依存するプログラムは、環境が変われば結果も変わることに注意してください。

## 時間を測る

`(scheme time)` は、時間を測る手続きを3つ持ちます。

- `(current-jiffy)`: ジフィー(jiffy)という単位の、現在の時刻を、正確な整数で返す。起点は決まっていないので、2つの値の差だけに意味がある。
- `(jiffies-per-second)`: 1秒が何ジフィーかを返す。
- `(current-second)`: 現在の時刻を、秒を単位にした不正確な数(浮動小数点数)で返す。

ジフィーの長さは実装によって違うので、時間は `(jiffies-per-second)` で割って秒にします。処理の前後で `current-jiffy` を呼び、差を取ります。

```scheme
(define (count-up n)
  (let loop ((i 0))
    (if (< i n) (loop (+ i 1)) i)))

(define start (current-jiffy))
(define result (count-up 100000))
(define seconds (/ (- (current-jiffy) start) (jiffies-per-second)))
result
(exact? start)
(>= seconds 0)
```

```output
100000
#t
#t
```

時間の値そのものは、実行のたびに変わるので、この文書は値を載せていません。確かめられるのは、差が 0 以上の正確な数になることです。

測る処理を包む手続きを作っておくと便利です。結果と、かかった秒数の2つを、多値(第13章)で返します。

```scheme
(define (timed thunk)
  (let* ((start (current-jiffy))
         (result (thunk))
         (end (current-jiffy)))
    (values result (/ (- end start) (jiffies-per-second)))))

(call-with-values
  (lambda () (timed (lambda () (count-up 1000))))
  (lambda (result seconds)
    (list result (>= seconds 0))))
```

```output
(1000 #t)
```

`current-second` は、現在の時刻を、秒を単位にした不正確な数で返します。値は実行のたびに変わるので、ここでは、実数であることだけを確かめます。

```scheme
(real? (current-second))
(inexact? (current-second))
```

```output
#t
#t
```

プログラム全体の時間を測りたいときは、`clock.scm` のように、最初と最後で `current-jiffy` を呼びます。

```text
(import (scheme base) (scheme write) (scheme time))

(define (count-up n)
  (let loop ((i 0))
    (if (< i n) (loop (+ i 1)) i)))

(define start (current-jiffy))
(define result (count-up 100000))
(define seconds (/ (- (current-jiffy) start) (jiffies-per-second)))

(display result)
(newline)
(display (>= seconds 0))
(newline)
```

```console
$ sucheme clock.scm
100000
#t
```

## 練習問題

1. 引数のリスト(文字列のリスト)を受け取り、数として読めるものだけを足す手続き `sum-numbers` を書いてください。`("1" "x" "2.5")` から `3.5` が得られます。
2. 引数のリストが空なら終了コード 2、そうでなければ 0 で終わる、という判断を、`exit` を呼ばずに「終了コードを返す手続き」として書いてください。`exit` を呼ぶのは、その結果を受けた最後の1か所だけにします。
3. 手続き `(timed thunk)` を使って、`(count-up 1000)` の結果だけを取り出してください。かかった時間は捨てます。
4. `exit` に渡す値と、終了コードの対応を、`(exit #t)`、`(exit #f)`、`(exit 5)` のそれぞれについて答えてください。

### 答え

1 の答えです。

```scheme
(define (sum-numbers args)
  (let loop ((rest args) (total 0))
    (cond ((null? rest) total)
          ((string->number (car rest))
           => (lambda (n) (loop (cdr rest) (+ total n))))
          (else (loop (cdr rest) total)))))

(sum-numbers '("1" "x" "2.5"))
(sum-numbers '())
```

```output
3.5
0
```

2 の答えです。

```scheme
(define (status-for args)
  (if (null? args) 2 0))

(status-for '())
(status-for '("a"))
```

```output
2
0
```

実際のプログラムでは、最後に `(exit (status-for (cdr (command-line))))` と書きます。

3 の答えです。

```scheme
(call-with-values
  (lambda () (timed (lambda () (count-up 1000))))
  (lambda (result seconds) result))
```

```output
1000
```

4 の答えです。`(exit #t)` は 0、`(exit #f)` は 1、`(exit 5)` は 5 です。

## 次の章

ここまでで、このチュートリアルの 1 から 19 章が終わりです。次は、[プログラム集](../programs/README.md)で、まとまった大きさのプログラムを読んでみてください。コマンドの使い方の全体は[ユーザーズガイド](../guide/README.md)に、手続きの一覧は[リファレンス](../reference/README.md)にあります。
