# チュートリアル

sucheme で Scheme を学ぶチュートリアルです。C、Python、JavaScript など、何かのプログラミング言語を使えるが、Lisp 系の言語は初めてという人を想定しています。知っている言語との対比から入ります。

## 読み方

- 章は順に読みます。前の章で定義したものを、後ろの章が使うことがあります。
- 各章は、説明と例、答えつきの練習問題でできています。練習問題は、答えを見る前に、自分で書いて試してください。
- 例は `sucheme` に打ち込めます。コードのブロックのすぐ下に、返ってくる値や画面への出力が書いてあります。これらは自動で実行して確かめています([README](../README.md) を参照)。
- 例で誤りを見せるところでは、`error: ` に続けて誤りの内容が出ます。

## 目次

章は、後の章で説明する機能を使わないように並べています。

| 章 | 内容 | 状態 |
| --- | --- | --- |
| [1 はじめに](01-introduction.md) | 起動と終了、式を打って値を見る、ファイルの実行 | あり |
| [2 式と前置記法](02-expressions.md) | 括弧と前置記法、数と算術、比較、真偽値 | あり |
| [3 定義と束縛](03-definitions.md) | `define`、`let` と `let*` と `letrec`、`set!` | あり |
| [4 手続き](04-procedures.md) | `lambda`、手続きの定義、可変長の引数、クロージャ | あり |
| [5 条件分岐](05-conditionals.md) | `if`、`cond`、`case`、`and` と `or`、`when` と `unless` | あり |
| [6 リスト](06-lists.md) | ペアとリスト、`car` と `cdr`、`quote`、リストの手続き、連想リスト | あり |
| [7 再帰と末尾呼び出し](07-recursion.md) | 再帰、末尾呼び出し、名前つき `let`、`do`、竹内関数 | あり |
| [8 高階手続き](08-higher-order.md) | `map`、`for-each`、`apply`、手続きを返す手続き、畳み込み | あり |
| [9 文字列と文字](09-strings.md) | リテラル、比較、部分、変換、文字列ポート | あり |
| [10 ベクタとバイトベクタ](10-vectors.md) | 添字で引く、更新、`vector-map`、バイトベクタと UTF-8 | あり |
| [11 数](11-numbers.md) | 正確な数と不正確な数、bignum と有理数、浮動小数点数、複素数 | あり |
| [12 レコード](12-records.md) | `define-record-type` | あり |
| [13 制御](13-control.md) | 多値、`call/cc`、`dynamic-wind` | あり |
| [14 エラーの扱い](14-errors.md) | `error`、`guard`、`raise`、`with-exception-handler`、エラーオブジェクト | あり |
| [15 構文の定義](15-macros.md) | `syntax-rules` と `define-syntax`、衛生性 | あり |
| [16 パラメータと遅延評価](16-parameters-and-promises.md) | `make-parameter` と `parameterize`、`delay` と `force`、遅延評価版の `tarai` | あり |
| [17 ライブラリ](17-libraries.md) | `import`、`define-library`、`-I` でファイルのライブラリを読む | あり |
| [18 入出力](18-io.md) | `write`、ポート、`read`、行や文字の読み取り、ファイルの読み書き | あり |
| [19 プログラムとして動かす](19-running-programs.md) | コマンドライン引数、`exit`、環境変数、時間の計測 | あり |

章立ての計画は [計画書 0027](../../plans/0027-user-documentation.md) の「構成案」にあります。まとまった大きさのプログラムは [プログラム集](../programs/README.md) にあります。
