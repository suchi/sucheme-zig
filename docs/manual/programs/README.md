# プログラム集

sucheme で動く、まとまった大きさのプログラムを集めた。`名前.scm` がプログラムで、`名前.out` がその標準出力である。どれも `zig build check-examples` が、実行ファイルにファイルとして渡して走らせ、標準出力が `.out` と一致し、終了コードが 0 であることを確かめる([ADR-0048](../../adr/0048-run-the-examples-of-the-user-documentation.md))。

手元で動かすには、リポジトリの根から次のようにする。

```text
zig build
zig-out/bin/sucheme docs/manual/programs/tak.scm
```

プログラムは、時刻、パス、乱数に依らない出力だけを書く。呼び出しの回数を出すものは、回数が実装で変わらない決まった数になる。

## 一覧

チュートリアルの章は [計画書 0027](../../plans/0027-user-documentation.md) の章立てによる。章はまだ書かれていないものがある。

| プログラム | 内容 | 対応する章 |
| --- | --- | --- |
| [sort](sort.scm) | 挿入、マージ、クイックの3つの整列を同じ入力で比べる | 6 リスト、7 再帰、8 高階手続き |
| [binary-search](binary-search.scm) | 整列済みのベクタから二分探索で値を探す | 7 再帰、10 ベクタ |
| [sieve](sieve.scm) | エラトステネスのふるいで 100 以下の素数を求める | 7 再帰、10 ベクタ |
| [gcd-lcm](gcd-lcm.scm) | ユークリッドの互除法による最大公約数と最小公倍数 | 6 リスト、7 再帰 |
| [fibonacci](fibonacci.scm) | フィボナッチ数を、再帰、反復、メモ化で比べる | 7 再帰、8 高階手続き |
| [hanoi](hanoi.scm) | ハノイの塔の手順を出す | 7 再帰 |
| [queens](queens.scm) | 8 クイーンの全解を数え、最初の解を盤面に描く | 6 リスト、7 再帰、8 高階手続き |
| [permutations](permutations.scm) | リストの順列と組合せを作る | 6 リスト、8 高階手続き |
| [life](life.scm) | ライフゲームでグライダーを 4 世代進める | 7 再帰、10 ベクタ |
| [tak](tak.scm) | 竹内関数 `tak` | 7 再帰 |
| [tarai](tarai.scm) | たらい回し関数 `tarai` の、正格版と遅延評価版の呼び出し回数の比較 | 7 再帰、16 パラメータと遅延評価 |
| [fib](fib.scm) | `fib` のベンチマーク | 7 再帰 |
| [phone-book](phone-book.scm) | 連想リストの電話帳で追加、検索、更新、削除を行う | 6 リスト |
| [stack-queue](stack-queue.scm) | レコード型のスタックと、2つのリストで作るキュー | 6 リスト、12 レコード |
| [word-count](word-count.scm) | 文字列ポートで単語に分け、出現回数を数える | 6 リスト、9 文字列と文字 |
| [csv-split](csv-split.scm) | 引用符を含む CSV の1行を欄に分ける | 7 再帰、9 文字列と文字 |
| [palindrome](palindrome.scm) | 英字だけを見て回文かを判定する | 9 文字列と文字 |
| [caesar](caesar.scm) | シーザー暗号の暗号化、復号、総当たり | 9 文字列と文字 |
| [roman](roman.scm) | ローマ数字と整数の相互変換 | 5 条件分岐、9 文字列と文字 |
| [run-length](run-length.scm) | ランレングス符号化と復号 | 9 文字列と文字 |
| [factorial](factorial.scm) | bignum で大きな階乗と桁数を求める | 2 式と前置記法、11 数 |
| [factorize](factorize.scm) | 素因数分解 | 7 再帰、11 数 |
| [harmonic](harmonic.scm) | 有理数で調和数とベルヌーイ数を正確に求める | 11 数 |
| [newton-sqrt](newton-sqrt.scm) | ニュートン法の平方根を、正確な数と不正確な数で比べる | 2 式と前置記法、11 数 |
| [fizzbuzz](fizzbuzz.scm) | FizzBuzz | 5 条件分岐、7 再帰 |
| [collatz](collatz.scm) | コラッツの数列と、1000 以下で最も長い数 | 5 条件分岐、7 再帰 |
| [beer](beer.scm) | 99 本のビールの歌詞を、単複の場合分けで出す | 5 条件分岐、7 再帰 |
| [maze](maze.scm) | 文字の迷路を幅優先で探索し、最短の道を描く | 6 リスト、10 ベクタ |
| [compose-curry](compose-curry.scm) | 手続きの合成とカリー化 | 4 手続き、8 高階手続き |
| [memoize](memoize.scm) | 連想リストによるメモ化で、呼び出しの回数を比べる | 3 定義と束縛、8 高階手続き |
| [bank-account](bank-account.scm) | クロージャとメッセージによる銀行口座 | 3 定義と束縛、4 手続き、14 エラーの扱い |
| [deriv](deriv.scm) | 記号微分と簡約 | 6 リスト |
| [evaluator](evaluator.scm) | 数、if、let、lambda を持つ小さな式の評価器 | 6 リスト、8 高階手続き |
| [swap-macro](swap-macro.scm) | `swap!` マクロと、衛生性による名前の衝突の回避 | 15 構文の定義 |
| [while-macro](while-macro.scm) | `while` マクロ(入れ子と末尾呼び出し) | 15 構文の定義 |
| [control-macros](control-macros.scm) | `my-unless`、`my-or`、2つの形を持つ `for` | 15 構文の定義 |
| [generator](generator.scm) | `call/cc` による生成器 | 13 制御 |
| [early-exit](early-exit.scm) | `call/cc` と `dynamic-wind` による早期脱出 | 13 制御 |
| [validate](validate.scm) | `guard` と `raise` による入力の検査 | 14 エラーの扱い |
| [recover](recover.scm) | `with-exception-handler` と `raise-continuable` による回復 | 14 エラーの扱い |
| [parameters](parameters.scm) | `parameterize` による設定の切り替え | 16 パラメータと遅延評価 |

## 足すときの決まり

- `名前.scm` と `名前.out` を組で置く。組になっていないファイル、`.scm` と `.out` と `.md` 以外のファイルは、検査が失敗にする。
- 入力を読むもの(`.in`)と、ファイルを書くものは、前提のスライスがマージされてから、検査に足す。
- Debug ビルドの実行ファイルで、1 本あたり 1 秒前後に収める。
