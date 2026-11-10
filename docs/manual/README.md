# sucheme の利用者向け文書

sucheme を使う人のための文書の入口です。開発に参加する人の入口は [onboarding.md](../onboarding.md) です。

文書は次の4つに分けて、順に足していきます。どの章がいつ入るかは [計画書 0027](../plans/0027-user-documentation.md) の「章ごとの前提のスライス」にあります。

| 文書 | 内容 | 状態 |
| --- | --- | --- |
| チュートリアル | [Lisp 系の言語が初めての人が、式から順に Scheme を学ぶ](tutorial/README.md) | 1 から 17 章あり(18 章以降は前提のスライスのあと) |
| [ユーザーズガイド](guide/README.md) | 実行ファイル、REPL、ファイルの実行、ライブラリ、終了コード、Web UI | 1 から 7 章あり |
| [リファレンスマニュアル](reference/README.md) | R7RS の節への索引と、sucheme に固有のもの(上限、書式、誤りの文面、未実装の機能など) | 索引と、固有の項目(上限、REPL とコマンドライン、誤りの文面、表示の書式、まだ無い機能、R7RS と食い違う箇所)あり |
| [プログラム集](programs/README.md) | sucheme で動く、まとまった大きさのプログラム | 一部(アルゴリズムとベンチマークの分野の12本) |

## この文書の例について

文書に載せる Scheme のコードは、すべて `zig build check-examples` が実際に走らせて、載せた出力と比べています。比べるのは、全コミットの CI です。決定の経緯は [ADR-0048](../adr/0048-run-the-examples-of-the-user-documentation.md) にあります。

例は、コードのブロックと、その下の出力のブロックの組で書きます。出力は REPL と同じ形で、値が1行ずつ並びます。

```scheme
(define (square x) (* x x))
(square 12)
(map square '(1 2 3))
```

```output
144
(1 4 9)
```

定義は何も出力しません。同じページのコードは上から順に走るので、前のブロックの定義を後ろのブロックで使えます。

```scheme
(square 1/2)
```

```output
1/4
```

`display` などで書いたものは、書いた順に値と並びます。`display` を使うには、`(scheme write)` を `import` します。誤りは `error: ` に続けて説明が出ます。

```scheme
(import (scheme write))
(display "hello")
(newline)
(car '())
```

```output
hello
error: wrong type of argument to car ()
```

`(car '())` のように誤りを見せる例も、出力のブロックで、どの誤りが出るかまで確かめています。

## プログラム集の検査

[プログラム集](programs/README.md)の `.scm` は、ブロックと違い、実行ファイルにファイルとして渡して走らせます。標準出力が `.out` と一致し、終了コードが 0 であることを、同じ `zig build check-examples` が確かめます。
