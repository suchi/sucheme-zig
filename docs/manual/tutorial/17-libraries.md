# 17 ライブラリ

ここまでの章でも、`(import (scheme write))` のように、ライブラリを `import` してきました。この章では、`import` の仕組みを詳しく見て、自分でライブラリを書く方法を学びます。

プログラムが大きくなると、定義を整理する必要が出ます。ライブラリ(library)は、関連する定義をひとまとめにして、外に見せる名前(公開する名前)と、中でだけ使う名前を分ける単位です。Python のモジュール、JavaScript の ES モジュール、Java のパッケージに当たります。

## 標準のライブラリを import する

標準のライブラリの名前は、`(scheme base)` のように、2つの語のリストです。主なものを表にします。

| ライブラリ | 主な内容 |
| --- | --- |
| `(scheme base)` | 基本の構文と手続き(リスト、文字列、ベクタ、数、レコード、例外など) |
| `(scheme write)` | `display`、`write` |
| `(scheme char)` | 大文字小文字の変換、文字の種類の判定 |
| `(scheme inexact)` | `sqrt`、`sin`、`exp` などと、`nan?` と `infinite?` |
| `(scheme complex)` | 複素数の部品(`real-part`、`magnitude` など) |
| `(scheme lazy)` | `delay`、`force` など |
| `(scheme case-lambda)` | `case-lambda` |
| `(scheme cxr)` | `caddr` のような3段、4段の `car` と `cdr` の組み合わせ |

どのライブラリが `import` できるかは、sucheme の版によって増えていきます。`import` の対象が読めないときは、誤りになります。

```scheme
(import (scheme nothing))
```

```output
error: unknown library: (scheme nothing)
```

`import` は、1つの式に複数のライブラリを並べて書けます。

```scheme
(import (scheme base) (scheme write) (scheme char))
(string-upcase "abc")
```

```output
"ABC"
```

REPL とファイルの実行は、最初から `(scheme base)` を `import` した状態で始まります。そのほかのライブラリは、必要なものを `import` します。

## import の形

`import` には、取り込む名前を加工する形があります。

- `(only ライブラリ 名前 ...)`: 指定した名前だけを取り込む。
- `(except ライブラリ 名前 ...)`: 指定した名前を除いて取り込む。
- `(prefix ライブラリ 接頭辞)`: すべての名前に接頭辞を付ける。
- `(rename ライブラリ (元の名前 新しい名前) ...)`: 名前を変える。

名前の衝突を避けたいときに使います。次は、自分でライブラリを書く例で見ます。

## define-library でライブラリを書く

`define-library` で、ライブラリを定義します。

```text
(define-library (ライブラリの名前)
  (export 公開する名前 ...)
  (import 取り込むライブラリ ...)
  (begin
    定義 ...))
```

`export` に書いた名前だけが、外から見えます。`begin` の中の、ほかの定義は、ライブラリの中でだけ使えます。`import` には、そのライブラリの中で使うライブラリを書きます。`(scheme base)` も、`import` しなければ使えません。

カウンタを作るライブラリを書きます。

```scheme
(define-library (mylib counter)
  (export make-counter counter-next! (rename internal-reset counter-reset!))
  (import (scheme base))
  (begin
    (define (make-counter) (list 0))
    (define (counter-next! c)
      (set-car! c (+ (car c) 1))
      (car c))
    (define (internal-reset c)
      (set-car! c 0))
    (define hidden 99)))
```

`export` の `(rename internal-reset counter-reset!)` は、ライブラリの中では `internal-reset` という名前で、外には `counter-reset!` という名前で公開します。`hidden` は公開していません。

定義したライブラリを `import` して、使います。

```scheme
(import (mylib counter))
(define c (make-counter))
(counter-next! c)
(counter-next! c)
(counter-reset! c)
(counter-next! c)
```

```output
1
2
1
```

`counter-reset!` の戻り値は、画面に出ません。

公開していない名前は、外から見えません。

```scheme
hidden
```

```output
error: unbound variable: hidden
```

ライブラリの中身を、あとから変えても、公開した名前の使い方が同じなら、使う側のコードには影響しません。

## import の形を使う

先に書いたライブラリを、加工した形で `import` します。

```scheme
(import (prefix (mylib counter) cnt:))
(cnt:make-counter)
(import (rename (mylib counter) (make-counter new-counter)))
(new-counter)
(import (only (scheme base) car))
(import (except (mylib counter) counter-next!))
```

```output
(0)
(0)
```

`(prefix (mylib counter) cnt:)` で、`make-counter` は `cnt:make-counter` という名前になります。名前が衝突するときや、どのライブラリの名前かを明示したいときに便利です。

## ライブラリが別のライブラリを使う

ライブラリは、ほかのライブラリを `import` できます。次は、小さなユーティリティのライブラリと、それを使うライブラリです。

```scheme
(define-library (mylib util)
  (export twice)
  (import (scheme base))
  (begin
    (define (twice f)
      (lambda (x) (f (f x))))))

(define-library (mylib steps)
  (export two-steps)
  (import (scheme base) (mylib util))
  (begin
    (define two-steps ((twice (lambda (x) (+ x 1))) 0))))

(import (mylib steps))
two-steps
```

```output
2
```

`(mylib steps)` が使っている `twice` は、`(mylib steps)` の `export` に入っていないので、`two-steps` を `import` しても、`twice` は見えません。

## ファイルに分ける

ライブラリを、別のファイルに書いて、プログラムから読み込めます。ライブラリの名前を、ファイルの場所に対応させます。`(mylib greet)` は `mylib/greet.sld` というファイルです。名前の語ごとにディレクトリを掘り、最後の語に拡張子 `.sld` を付けます。

次のファイル2つを用意します。

`mylib/greet.sld` の内容です。

```text
(define-library (mylib greet)
  (export greet)
  (import (scheme base))
  (begin
    (define (prefix) "Hello, ")
    (define (greet name)
      (string-append (prefix) name "!"))))
```

`main.scm` の内容です。

```text
(import (scheme base) (scheme write) (mylib greet))
(display (greet "world"))
(newline)
```

2つのファイルがあるディレクトリで、`main.scm` を実行します。

```text
$ sucheme main.scm
Hello, world!
```

この例は、このチュートリアルの検査の対象ではありません。ここに書いた実行の結果は、`sucheme` の実行ファイルで確かめたものです。

実行するディレクトリと、ライブラリのディレクトリが違うときは、`-I` でライブラリを探すディレクトリを教えます。何度でも書けます。

```text
$ sucheme -I /path/to/libs main.scm
Hello, world!
```

作業ディレクトリは、`-I` を書かなくても、先に探されます。`-I` を書かずに、ライブラリが見つからないと、次の誤りになります。

```text
$ sucheme main.scm
error: main.scm:1:1: unknown library: (mylib greet)
```

(ライブラリのファイルがないディレクトリで実行した場合です。)

## import は先に書く

ライブラリの `import` は、そのライブラリの名前を使う定義より前に書いてください。`import` より前に定義した手続きの中から、あとで `import` した名前を呼ぶと、その名前は見つかりません(sucheme で確かめた動作です)。次の例は、`scheme fresh` のブロックなので、これまでの `import` の影響を受けません。

```scheme fresh
(define (f c) (char-numeric? c))
(import (scheme char))
(f #\5)
```

```output
error: unbound variable: char-numeric?
```

`(scheme char)` を `import` したあとに、トップレベルで `(char-numeric? #\5)` を直接呼べば動きます。手続きの定義と `import` の順序で結果が変わるので、プログラムの先頭にまとめて `import` を書いてください。

## 練習問題

1. 文字列に関する小さなライブラリ `(mylib strings)` を書いてください。公開するのは `string-repeat`(文字列を n 回つなぐ)だけにして、内部の補助の手続きは公開しないでください。
2. 練習問題1のライブラリを `(prefix (mylib strings) s:)` で `import` して、`s:string-repeat` を呼んでください。
3. `(import (only (scheme base) car cdr))` のあとに、`cons` が使えるかを予想してください。REPL では最初から `(scheme base)` が見えているので、結果は予想と異なるかもしれません。その理由を考えてください。
4. 外から見える名前を `counter-next!` だけにしたカウンタのライブラリを、1つの変数を持つクロージャ(第4章)で書き直してください。`make-counter` を公開せずに、1つのカウンタだけを提供します。

### 答え

1 の答えです。

```scheme
(define-library (mylib strings)
  (export string-repeat)
  (import (scheme base))
  (begin
    (define (string-repeat-helper s n acc)
      (if (= n 0)
          acc
          (string-repeat-helper s (- n 1) (string-append acc s))))
    (define (string-repeat s n)
      (string-repeat-helper s n ""))))
(import (mylib strings))
(string-repeat "ab" 3)
(string-repeat "x" 0)
```

```output
"ababab"
""
```

2 の答えです。

```scheme
(import (prefix (mylib strings) s:))
(s:string-repeat "-" 5)
```

```output
"-----"
```

3 の答えです。`(import (only (scheme base) car cdr))` は、既に見えている `cons` を隠しません。`import` は、名前を足すだけで、すでに見えている名前を消さないからです。

```scheme
(import (only (scheme base) car cdr))
(cons 1 2)
```

```output
(1 . 2)
```

4 の答えです。

```scheme
(define-library (mylib single-counter)
  (export counter-next!)
  (import (scheme base))
  (begin
    (define count 0)
    (define (counter-next!)
      (set! count (+ count 1))
      count)))
(import (mylib single-counter))
(counter-next!)
(counter-next!)
```

```output
1
2
```

`count` は、ライブラリの中の変数なので、外からは見えません。この変数を、`counter-next!` だけが書き換えます。

## 次の章

ここまでで、このチュートリアルの 1 から 17 章が終わりです。入出力(`write`、ファイルの読み書き、`read`)と、プログラムとして動かすこと(コマンドラインの引数、`exit`、時間の計測)は、続きの章で説明します。
