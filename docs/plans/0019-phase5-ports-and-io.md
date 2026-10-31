# 0019: 段階5の実装計画 — ポートと入出力

- 対応する決定: [ADR-0003](../adr/0003-precise-mark-sweep-gc.md)、[ADR-0018](../adr/0018-incremental-vertical-slices.md)、[ADR-0027](../adr/0027-severity-by-consequence-and-a-cost-side-stop.md)、[ADR-0031](../adr/0031-gc-at-machine-step-boundaries.md)、[ADR-0038](../adr/0038-wasm-entry-layer-allocations-outside-the-accounting.md)、[ADR-0039](../adr/0039-standard-environment-installed-at-init.md)。並行の進め方は [0017](0017-parallel-lanes.md)
- 段階: 5(ポートと入出力)。段階の作業項目と完了条件は [roadmap.md](../roadmap.md) の段階5の節が正
- 対象のレーン: [0017](0017-parallel-lanes.md) の L3(ポートと入出力)の全部と、L2(リーダ)のうち、リーダの完全化と位置情報の副表。L2 の数の構文は、段階4の計画(0018)の担当で、ここでは順序だけを書く
- 日付: 2026-10-20
- 状態: 合意済み(2026-10-20)。6項目すべてを勧める案どおりに承認。7は報告である。スライスの実装は未着手

## 解こうとしている問題

段階3までの処理系には、ポートが無い。結果の出力は、`Interpreter.evalPrint` に渡す `std.Io.Writer` だけを通り、Scheme のプログラムは `display` も `read-char` も呼べない。`eval` と `exit` は、機械操作プリミティブとして設計だけがある([runtime.md](../design/runtime.md) の機械操作プリミティブ)。リーダは、データラベル、ブロックコメント、`#;`、縦棒の識別子、`#!fold-case` のディレクティブ、文字列の行継続を読めない([frontend.md](../design/frontend.md) の段階ごとの実装範囲)。プリンタは循環を検出しないので、`set-cdr!` で作った循環リストを REPL が書くと止まらない。

R7RS 付録Aのライブラリのうち、段階5が入れるのは、`(scheme file)` `(scheme read)` `(scheme write)` `(scheme load)` `(scheme eval)` `(scheme repl)` `(scheme process-context)` `(scheme time)` `(scheme r5rs)` の9つと、`(scheme base)` のポートの識別子である。必須の識別子の一覧は `tests/r7rs-required/` の各ファイルが正で、ここに複製しない。

## 完了条件

[roadmap.md](../roadmap.md) の段階5の完了条件が正である。この計画は次のように読む。

- 循環リストの `write` がデータラベル付きで出る(5j)。
- `#!fold-case` が入力の途中で有効になる(5a)。
- 衛生性の検証項目([frontend.md](../design/frontend.md))のうち、循環データの `quote`(9番)が Scheme から通る(5c)。
- [runtime.md](../design/runtime.md) の「テストに含める事例」の12(`exit` と `dynamic-wind`)が通る(5m)。
- R7RS 付録Aのライブラリすべてが `import` できる(5q。段階4のライブラリは 0018 が入れる)。
- リリース v0.5.0 を出す(5r)。

## 範囲

含めるもの:

- roadmap の段階5の作業項目のすべて(割り当ては下の表)。
- ポートの型、文字列ポート、バイトベクタポート、ファイルポート、コンソールのポート(標準入出力と標準エラー)。
- `write` の3種と `display` の循環への対応、非 ASCII を含むシンボルの縦棒での書き出し。
- `eval` `environment` `interaction-environment` `load`、`exit` `emergency-exit` `command-line` `get-environment-variable` `get-environment-variables`、`current-second` `current-jiffy` `jiffies-per-second`。
- WASM の境界の追加(`sucheme_set_command_line`、`sucheme_exit_code`、状態コード -6、時刻の import)と、`web/sucheme.js` と `tools/test-wasm/` のホスト側の対応。

含めないもの(送り先は括弧の中):

- 数の構文と数の書式の実体(段階4、0018)。この計画は、呼ぶ側の署名だけを書く。
- 再開可能な機械と、ブラウザでの入力待ち(状態コード 2)と `sucheme_provide_input`(段階8)。段階5の WASM の標準入力は、合意を求める点の6で決める。
- 準拠スイートの取り込み(段階6、0020)。

## roadmap の項目の割り当て

| roadmap の段階5の項目 | スライス |
| --- | --- |
| テキストポートとバイナリポート、文字列ポート、バイトベクタポート、ファイルポート | 5g(型の骨格)、5h(文字列とバイトベクタ)、5i(コンソール)、5k(ファイル) |
| 第2類の経路を同じリゾルバに通す。失敗は `file-error` | 5k |
| リーダの完全化 | 5a、5b、5c |
| リーダの位置情報の副表(スライス未割り当て) | 5d |
| `write` と `write-shared` と `write-simple` | 5j |
| `eval` `exit` と `eval` 用の環境の値。`Expander.constant` の EOF と約束の分岐を Scheme から通すテスト | 5m(`exit`)、5o(`eval` と環境の値とテスト) |
| 9つのライブラリ | 5i と 5j(`(scheme write)`)、5k(`(scheme file)`)、5l(`(scheme read)`)、5m(`(scheme process-context)`)、5n(`(scheme time)`)、5o(`(scheme eval)` `(scheme repl)`)、5p(`(scheme load)`)、5q(`(scheme r5rs)`) |

リーダの項目のうち、`#u8` と、文字列と文字の16進のエスケープは、すでに入っている(`src/reader.zig` の `atBytevectorOpen`、`src/string_syntax.zig` と `src/char_syntax.zig` の `x` の分岐)。5a から 5c は、残りを足す。roadmap の項目は、この計画の合意のあとで、入っているものが分かる形に直す(下の「合意のあとにやること」)。

## スライス

規模は、0016 と同じ「小・中・大」の3段で書く。見積りの時間は付けない(別の方法で付ける)。担当の階層は [0017](0017-parallel-lanes.md) の「階層と引き継ぎ」の T1・T2・T3 である。

| スライス | レーン | 完了条件 | 所有するファイル | 階層 | 前提 | 並行 | 規模 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 5a コメントとディレクティブと行継続 | L2 | `#\| a #\| b \|# \|# 1` が `1`、`(list 1 #;2 3)` が `(1 3)`、同じ入力の中で、`#!fold-case` のあとの `ABC` が `abc` で、`#!no-fold-case` で戻る(REPL の次の入力まで残すのは 5i と 5l)。文字列の行継続が読める | `src/reader.zig`、`src/string_syntax.zig` | T2 | なし | 5b と 5c とは逐次(同じファイル)。L3 とは並行 | 小 |
| 5b 縦棒の識別子 | L2 | `(eq? '\|a b\| (string->symbol "a b"))` が `#t`。`\|\x41;\|` が `A` という名前のシンボル | `src/reader.zig`、`src/string_syntax.zig`(文字列とエスケープを共有するので、新しいファイルは作らなかった)。`src/sucheme.zig` の誤りの説明の振り分けに1行(5a も同じ) | T2 | 5a | L3 と並行 | 小 |
| 5c データラベル | L2 | `(let ((x '#0=(a . #0#))) (eq? x (cdr x)))` が `#t`。衛生性の検証項目の9。リテラルの外の循環と、`syntax-rules` のパターンとテンプレートの循環が、止まらずに誤りになる | `src/reader.zig`。`src/syntax/rules.zig`(循環の検査の関数1つと呼び出し、2026-10-20 に承認)。`src/sucheme.zig` の誤りの説明の振り分けに1行 | T2(T3 がレビュー) | 5b | L3 と並行 | 中 |
| 5d 位置情報の副表 | L2 | 展開時のエラーが、ファイルと行と桁を添えて報告される | `src/reader.zig`、`src/positions.zig`(新規)、`src/syntax/source.zig` の受け渡しの部分。2026-10-21 に承認された所有の外のもの: `src/syntax/expand.zig`(仕事に位置を持たせる分)、`src/context.zig`(表と送出の位置)、`src/sucheme.zig`(表の配線と説明の前置)、`src/main.zig`(パスを渡す1か所) | T3 | 5c、3o のマージ | L3 と並行。3o とは逐次 | 中 |
| 5g ポートの型の骨格 | L3 | `Value` に `port` のバリアントがあり、GC が辿り、計上し、回収する。プリンタが `#<port>` と書く。手続きは足さない | `src/value.zig`、`src/trace.zig`、`src/heap.zig`、`src/printer.zig` の1行 | T3 | 0018 の数の型の骨格との順序(下の「型の骨格のコンフリクト」) | L2 と並行 | 小 |
| 5h 文字列ポートとバイトベクタポート | L3 | `(let ((p (open-input-string "ab"))) (list (read-char p) (peek-char p) (read-char p) (eof-object? (read-char p))))` が `(#\a #\b #\b #t)`。`get-output-string` と `get-output-bytevector` がラウンドトリップする | `src/port.zig`(新規)、`src/prim/port.zig`(新規)、`src/prim/table.zig` の1行、`lib/scheme/base.sld` のポートの輸出 | T2 | 5g | L2 と並行 | 中 |
| 5i コンソールのポートと現在のポート | L3 | `(display "hi")` と `(newline)` と `(write-string "x" (current-error-port))` が、ネイティブでも WASM でも、評価の結果の出力と同じ順で出る。`current-output-port` が `parameterize` で差し替わる。既知の制限: 標準エラーは標準出力と同じ書き先に出る。標準入力は読めない(最初から終わりにある。5l が読む) | `src/port.zig`、`src/prim/port.zig`、`src/sucheme.zig` の配線、`lib/scheme/write.sld`(新規、`display` だけ先に)。`src/platform/` は 5i では作らない(下の 5i の中身) | T2 | 5h | L2 と並行 | 中 |
| 5j `write` の3種 | L3 | `(let ((x (list 1 2))) (set-cdr! (cdr x) x) (write x))` が `#0=(1 2 . #0#)`。`write-shared` が共有を、`write-simple` がラベルなしを書く。`display` が循環で止まる。非 ASCII を含むシンボルを縦棒で書く | `src/printer.zig`、`src/prim/port.zig` の書き出しの手続き、`lib/scheme/write.sld` | T2(T3 がレビュー) | 5i | L2 と並行 | 中 |
| 5k ファイルポートと `(scheme file)` | L3 | `with-output-to-file` で書いたファイルを `call-with-input-file` で読み返せる。開けないファイルで `file-error?` が真になる条件が送出される。WASM で `file-exists?` が `#f` を返す | `src/port.zig`、`src/prim/port.zig`、`src/resolve.zig` の第2類の入口、`src/platform/`、`lib/scheme/file.sld`(新規) | T3(GC との関係)、T2(手続き) | 5i | L2 と並行 | 大 |
| 5l `read` と `(scheme read)` | L3 | `(read (open-input-string "(a . b) c"))` が `(a . b)` で、続く `read` が `c`、その次が EOF。読めない入力で `read-error?` が真になる。`#!fold-case` がポートごとに効く | `src/prim/port.zig`、`lib/scheme/read.sld`(新規) | T2 | 5h、5a(ディレクティブの状態) | L2 と並行。5a のマージ後 | 小 |
| 5m `exit` と `(scheme process-context)` | L3 | 事例12が通る。`sucheme prog.scm a b` で `(command-line)` が `("prog.scm" "a" "b")` の形の文字列のリスト。終了コードが [platform-and-web.md](../design/platform-and-web.md) の表どおり。WASM が -6 と `sucheme_exit_code` を返す | `src/machine.zig` の `MachineOp.exit` と巻き戻しの目標、`src/value.zig` の `MachineOp` の1行、`src/prim/process.zig`(新規)、`src/main.zig` のファイルの実行の部分、`src/wasm.zig`、`web/sucheme.js`、`tools/test-wasm/`、`lib/scheme/process-context.sld`(新規) | T3(機械)、T2(残り) | 5i | 3o と重なる(下の「機械の重なり」) | 中 |
| 5n `(scheme time)` | L3 | `(< 0 (current-jiffy))` と `(exact-integer? (jiffies-per-second))` が `#t`。`current-second` が不正確な数を返す。WASM でも同じ | `src/prim/time.zig`(新規)、`src/platform/`、`src/wasm.zig`、`web/sucheme.js`、`tools/test-wasm/`、`lib/scheme/time.sld`(新規) | T2 | 5i、0018 の浮動小数点数 | L2 と並行 | 小 |
| 5o `eval` と環境の値 | L3 | `(eval '(* 7 3) (environment '(scheme base)))` が `21`。`(eval '(define foo 32) (environment '(scheme base)))` が誤りを送出する。`interaction-environment` で定義した名前が REPL から見える。EOF の値と約束を `eval` で定数にするテストが通る | `src/machine.zig` の `MachineOp.eval`、`src/value.zig` の環境の値の型、`src/prim/eval.zig`(新規)、`lib/scheme/eval.sld` `repl.sld`(新規) | T3 | 3o のマージ、5m | 3o とは逐次 | 大 |
| 5p `load` と `(scheme load)` | L3 | `(load "x.scm")` が探索ルートの中の `x.scm` を、指定の環境で評価する。ルートの外の名前を拒否する | `src/prim/eval.zig`、`src/resolve.zig` の第1類の入口、`lib/scheme/load.sld`(新規) | T2 | 5o | L2 と並行 | 小 |
| 5q `(scheme r5rs)` | L3 | `(import (scheme r5rs))` が通り、`(eval '(+ 1 2) (scheme-report-environment 5))` が `3`。付録Aの全ライブラリが `import` できる | `lib/scheme/r5rs.sld`(新規)、`src/prim/eval.zig` の `null-environment` と `scheme-report-environment` | T2(輸出の転記は T1) | 5k、5l、5n、5p、0018 の `(scheme inexact)` `(scheme complex)` `(scheme char)` | 最後 | 小 |
| 5r v0.5.0 と段階の完了 | L3 | v0.5.0 が公開され、段階5の完了の手続きが済む | `docs/releases/`、`build.zig` の `current_stage` と版、roadmap | T2 | 5a から 5q と 5s、v0.4.0 の公開 | 最後 | 小 |

5e は、L2 が数の構文を足すスライスの名前として 0018 に渡す(下の「数の構文との順序」)。5f は欠番である。

### 5a から 5d の中身(L2)

- 5a: `skipWhitespace` を、行コメント、入れ子のブロックコメント、データコメント、ディレクティブを読み飛ばす形に広げる。`#;` は、続く1つのデータを読んで捨てる。捨てるデータの中のデータラベルの扱いは 5c で決める。ディレクティブの直後に区切りが要る([frontend.md](../design/frontend.md) のケースフォールディングの節。`#!fold-casex` は読み取りの誤り)。閉じていない `#|` と、データの来ない `#;` は `Incomplete` にする。`isIncomplete` の判定表の `"#| x"` と `"(a #;1"` の行は、偽から真に変わる。行継続は `\` に続く行内の空白、改行、次の行の先頭の空白を読み飛ばす(R7RS 6.7 と 7.1.1 の `<line ending>` と `<intraline whitespace>`。原文で確かめてから書く)。
- 5b: `|` で始まるトークンを、R7RS 7.1.1 の `<symbol element>` の規則で読む。`\x` の16進と、文字列と同じ記憶術のエスケープを許す(原文の生成規則で確かめる)。名前に ASCII でない文字を含むシンボルは、`#!fold-case` のもとでも畳み込まない縦棒の記法でだけ作れる。畳み込みの扱いは R7RS 2.1 の規定で確かめる。`folded` の ASCII の assert は、縦棒の識別子を通さない形に保つ。
- 5c: `#n=` を読んだら、ラベルの表にプレースホルダ(placeholder)を置き、データを読み終えたら、プレースホルダを本体で置き換える。置き換えは、作ったペアとベクタを訪問済みの集合つきで辿る(循環を作るので、Zig の再帰を使わない。[runtime.md](../design/runtime.md) の入力の深さに比例する処理)。ラベルの表と訪問済みの集合は、計上の対象である(runtime.md の計上の対象の「データラベルの表」)。読み取りの途中で GC は走らない(`Sink` の doc コメント)ので、プレースホルダはルートに入れなくてよい。未定義のラベルの参照と、同じラベルの二重定義は、読み取りの誤り(新しい `SyntaxError` のバリアント)にする。`#;` の中のラベルは、捨てるデータの中だけで有効にする。プレースホルダの表現(専用の `Value` のバリアントを作らず、ラベルの表の中の未完成のペアを指すなど)は、5c の中で決め、PR に書く。
- 5d: [frontend.md](../design/frontend.md) の位置情報の節を実装する。副表は、1つのトップレベルフォームを読んでから展開し終えるまでの作業表で、ルートに登録し、展開が終われば捨てる。展開時の誤りに、ファイルと行と桁を前置する。L7 の「エラー位置の表示」が、この結果を使う。展開器がコアIRの節点に位置を写す部分は、5d に入れない(2026-10-21 にユーザーが判断した)。位置を読むのは実行時の誤りの報告で、5d の完了条件の外だからである。実行時の誤りに位置を出すスライスで、読む側と一緒に入れる。そのスライスは、まだ割り当てていない(L7 の「エラー位置の表示」の計画で決める)。

### 5g から 5r の中身(L3)

- 5g: ヒープの型 `Port` を足す。中身は、方向(入力、出力)、種類(テキスト、バイナリ)、開いているか、畳み込みの状態(`#!fold-case` の状態はポートごと。[frontend.md](../design/frontend.md))、裏付け(下の表)の直和である。`Value` と `Kind` と `heap_types` に1行ずつ、`payloadBytes` と `free` に1行ずつ足す。`isEqv` は同一性で比べる。裏付けの各バリアントの中身は、合意を求める点の1と3と4の回答で決まる。骨格の PR では、文字列ポートのバリアント1つだけを置き、ほかは各スライスが足す。
- 5h: `src/port.zig` に、ポートの読み書きの関数を置く(下の「署名」)。`src/prim/port.zig` に、`(scheme base)` のポートの手続きのうち、明示したポートを取るものと、文字列ポートとバイトベクタポートを作るものを置く。`call-with-port` は Scheme で書けるので、`lib/sucheme/procedures.scm` に置く(R7RS 6.13.1 の定義を原文で確かめる)。`read-bytevector!` は `requireMutable` を呼ぶ([runtime.md](../design/runtime.md) のリテラルの不変性)。
- 5i: 標準入力、標準出力、標準エラーのポートを、`Interpreter` が作る。`current-input-port` `current-output-port` `current-error-port` は、パラメータオブジェクトである(R7RS 6.13.1)。既存の `make-parameter` の機構に載せる。ネイティブの出力は `evalPrint` が受け取る `std.Io.Writer` に、WASM の出力は既存の出力バッファに書く。WASM の出力バッファを計上の外に置く例外([ADR-0038](../adr/0038-wasm-entry-layer-allocations-outside-the-accounting.md))は変えない。プラットフォームの差は、[platform-and-web.md](../design/platform-and-web.md) のプラットフォーム抽象の形(`src/platform/native.zig` と `src/platform/wasm.zig` をコンパイル時に選ぶ)で置く。
  - 実施の結果(2026-10-28、親のセッションに諮って決めた): ネイティブも WASM も、コンソールの出力は `evalPrint` の書き手(ファイルの実行では `Interpreter.console_out` の標準出力)に直接書き、入力は最初から終わりにあるので、5i ではプラットフォームの差が無い。`src/platform/` は 5i では作らず、差が初めて出る 5k か 5n で作る。現在のポートのパラメータとコンソールのポートは `Context.console` が持ち、`%console-parameter` が最初に求められたときに作る。純粋プリミティブは `Services.console` と `Services.dyn` から現在のポートを引く。
  - 既知の制限(5i): `current-error-port` への書き込みは、標準出力と同じ書き先に出る(ネイティブでも標準エラーに分けない)。分けるのは、`evalPrint` にエラーの書き手を足す変更で、まだどのスライスにも割り当てていない(スライス未割り当て)。`current-input-port` は最初から終わりにあり、ネイティブでも標準入力を読まない。読むのは、入力を足す `fill` を入れる 5l で、REPL が標準入力を行で読むこととの調停も 5l で決める。ポートを省略した呼び出しは、動的点の鎖を根まで辿って現在のポートを引くので、関係の無い `parameterize` や `dynamic-wind` が深く重なるほど遅くなる(5i のレビューで見つかった)。速くするのは、まだどのスライスにも割り当てていない。
- 5j: プリンタを、`write`(循環にだけラベル)、`write-shared`(2回以上現れるペアとベクタすべてにラベル)、`write-simple`(ラベルなし)、`display`(循環にだけラベル)の4つの形にする。原文は R7RS 6.13.3 で、`display` は「must not loop forever on self-referencing pairs, vectors, or records」である。ラベルは、先に1回辿って、共有または循環しているオブジェクトを数え、2回目に書く。辿る表は計上の対象である。プリンタは今、作業スタックを `scratch`(計上の外)に置いているので、5j で計上つきの確保に移す。名前に ASCII でない文字を含むシンボルと、そのまま書くと別のデータとして読まれる名前(空白や括弧を含むもの、数として読めるもの)は、縦棒で囲んで書く(R7RS 6.13.3 の「Symbols that contain non-ASCII characters are escaped with vertical lines」)。数として読めるかの判定は、0018 の `scan` を呼ぶ(下の「署名」)。REPL が結果を書くのも `write` なので、循環した結果が止まらない問題も、ここで直る。名前が空のシンボルは `||` と書く。そのとき、リーダのファズの不変条件(書き出した長さが0でない)に 5b が置いた、名前が空のシンボルの例外を外す(`src/reader.zig` の `fuzzReadAll`)。
  - 実施の結果(2026-10-29、親のセッションに諮って決めた): 入口は `printer.print(out, heap, symbols, v, mode)` の1つで、`printer.write` と `printer.display` は無くした。表と作業スタックは `Heap.residentAllocator` で持ち、断られたら `HeapLimit` にする。中に値を持たない値は、表も作業スタックも使わない。ラベルを付けるのは、ペア、ベクタ、条件オブジェクト(irritant を書くので、条件を通る循環がありうる)で、番号は書く順に 0 から振り、一度書いたものは後の出現をすべて `#n#` と書く。縦棒で囲む名前は、リーダの `isIdentifier`(5j で `pub` にした)が受け付けない名前、`num.syntax.scan` が数とみなす名前、空の名前である。REPL の結果の書き出しで表の確保が断られたら、ヒープの上限の誤りになる。誤りの説明の値は、断られたらそこまでで切る。入口を1つにしたので、所有の外のテストの呼び出し(`src/core.zig` の `core.write` の引数と、`src/syntax/expand.zig`、`src/syntax/library.zig`、`src/syntax/rules.zig`、`src/machine.zig`、`src/reader.zig` のテスト)を新しい入口に替えた。`<infnan>` の綴りで始まる名前(`+NaN.0abc`)も縦棒で囲む。R7RS では識別子だが、準拠スイートが囲むことを求めるためである。
  - 査読の結果(2026-10-29): 挙動の担当が、cdr が循環した irritant のリストで書き出しが止まらないこと(ラベルの付くペアを `. #n=(...)` と書いて直した)と、上限の際で複素数を書くとプロセスが落ちること(数の書式の作業領域の断りを、`WriteFailed` でなく `HeapLimit` に戻して直した。5j で作業領域を上限に数えたことで入った退行だった)を見つけた。ライブラリの名前を書く `nameText` が上限の超過を「out of memory」にしていたのも直した。ラベルの表の値は 32 ビットに詰めた。ミューテーションの担当が見つけた、テストが固定していなかった判定は、単体テストを足して固定した。
- 5k: ファイルポートを、[frontend.md](../design/frontend.md) のファイルを開く経路の第2類として、リゾルバを通して開く。探索ルートの制約はかけない。失敗は、`ConditionKind.file` の条件で送出する。WASM の扱いは frontend.md の表どおり(開く手続きと `delete-file` は `file-error`、`file-exists?` は `#f`)。閉じ忘れたファイルの扱いは、合意を求める点の4で決める。
- 5l: `read` は、ポートの残りの入力を `Reader` に渡し、読めたデータの長さだけポートを進める。`Reader` の今の形(入力のスライス、`pos`、`fold_case`)で足り、`src/reader.zig` を変えない見込みである。ディレクティブで変わった `fold_case` は、読み終えたあとポートに書き戻す。ファイルとコンソールのポートでは、データの途中で入力のバッファが尽きたとき(`Incomplete`)、バッファに続きを足して、データの頭から読み直す。読み直しの費用はデータの長さの2乗に比例する。REPL の継続行の判定と同じ制約で、段階7の差分読み取りの項目([roadmap.md](../roadmap.md))が解く。`reader.zig` の変更が要ると分かったら、L3 の担当は止めて、L2 に頼む([0017](0017-parallel-lanes.md) の引き継ぎの条件の2)。
- 5m: `MachineOp` に `exit` を足す。未処理例外と同じ巻き戻しの経路で最外まで戻り、途中の `after` を呼ぶ([runtime.md](../design/runtime.md) の未処理例外と、必要なフレームの種類の「`exit` の巻き戻し」)。最外に着いたら、終了の値を持って、`error.Raised` と別の Zig の誤り(名前は 5m で決める)で機械の外へ出る。`emergency-exit` は、純粋プリミティブとして、巻き戻さずに同じ誤りを返す。`exit` の値から終了コードへの変換は [platform-and-web.md](../design/platform-and-web.md) の表どおり。`sucheme prog.scm` の後ろの引数を、今の 64 での拒否から、`command-line` に渡す形に変える(`src/main.zig` の doc コメントの表を直す)。引数と環境変数を UTF-8 として検査する位置は、platform-and-web.md の未決の記述どおり、このスライスで決める。WASM は `sucheme_set_command_line` と `sucheme_exit_code` を足し、`exit` で -6 を返す。環境変数は空として扱う。
- 5n: `current-jiffy` と `jiffies-per-second` は正確な整数(固定長整数で足りる)、`current-second` は不正確な数である(R7RS 6.14)。`current-second` は 0018 の浮動小数点数が入ってから足す。それまでに 5n を始めるなら、`current-jiffy` と `jiffies-per-second` だけを先に入れ、`(scheme time)` の `.sld` は `current-second` が入ってから置く。TAI は、R7RS が許す「UTC に定数を足したもの」で返す。足す定数の値と出典(IERS の公表値)は、5n の着手時に一次情報で確かめる(未確認)。WASM の import の形は、合意を求める点の2で決める。ネイティブの時計の API(Zig 0.17.0 の `std.Io.Clock` の種類)は、5n の着手時に標準ライブラリのソースで確かめ、[zig-api-notes.md](../design/zig-api-notes.md) に足す(未確認)。
- 5o: 環境の値(`environment` が返す指定子)のヒープの型を足し、`MachineOp` に `eval` を足す。`eval` は、データを指定の環境で展開し、できた節点を `eval` の継続のもとで、末尾の位置として評価する(R7RS 3.5)。`environment` は、空の環境に輸入集合を `import` した、変更できない環境を作る(R7RS 6.12)。環境の表の形と、展開した節点の置き場所は、3o の結果に従う。3o の前に `eval` を入れると、`eval` を繰り返すループが、計上の外の節点を際限なく積む。roadmap の、`Expander.constant` の EOF の値と約束の分岐を Scheme から通すテストは、`(eval (list 'quote (eof-object)) ...)` の形で書く。
- 5p: `load` は第1類の経路で、探索ルートの制約をかける([frontend.md](../design/frontend.md))。読み込んだ式は、5o の機構で、指定の環境(省略時は `interaction-environment`)で順に評価する。
- 5q: `(scheme r5rs)` は、ほかのライブラリからの再輸出と、`null-environment` と `scheme-report-environment` である。数の手続き(`exact->inexact` など)は 0018 のライブラリを待つ。準拠マトリクスの、再輸出による識別子の重複は、roadmap の段階6の項目が解く。
- 5r: 0016 の 3r と同じ手続き。v0.4.0 の公開より前には出さない(リリースは段階の完了条件で切る。[0017](0017-parallel-lanes.md) の合意を求める点の4)。

### 5g のレビューの記録と、後のスライスへの申し送り

5g のレビュー(suchi/sucheme-zig#205)で、ミューテーションが生き残ったが、テストを足さなかったもの:

- `growPortBytes` の早期の戻りの条件 `capacity <= bytes.len` を `<` にしても、同じ大きさの確保と写しが1回増えるだけで、結果も計上も変わらない(同値)。
- `growPortBytes` が古い領域から写す量を `len` から `bytes.len` に変えても、写す先の `len` より後ろは中身を約束しない部分なので、観測できる違いが無い(同値)。
- `growPortBytes` の `assert(direction == .output)` と、`createMemoryPort` のテキストのポートの UTF-8 の `assert`。外しても緑だが、Zig のテストは panic を期待して書けないので、固定しない。

5h と 5k が守る約束(型や表明では保証していないもの):

- `Port.Memory` の `pos <= len <= bytes.len` は、型では保証されない。読み書きの関数(5h の `src/port.zig`)が保つ。
- `growPortBytes` で伸ばした領域のうち、`bytes[len..]` は初期化されていない。`get-output-string` と `get-output-bytevector` は `len` までだけを読む。
- 入力のポートに `growPortBytes` を呼ぶと、安全なビルドでは表明で止まる。入力のポートは、開いたときの写しを最後まで使い、伸ばさない。
- `Port.Direction` は `input` か `output` の片方だけで、入出力の両方を持つポートは表せない。両方が要るポートを足すなら、型を変える。
- テキストのポートのバイト列が妥当な UTF-8 であることは、`createMemoryPort` の表明(安全なビルドだけ)でしか確かめない。呼び出し側(5h の `open-input-string` など)は、検査済みの文字列のバイト列だけを渡す。

## 依存と実施順

```mermaid
flowchart TD
    o3["3o IR を GC ヒープへ(L0)"]
    n0["0018 数の型の骨格(L1)"]
    nf["0018 浮動小数点数と書式(L1)"]
    np["0018 数の解析関数(L1)"]
    nl["0018 段階4のライブラリ(L1)"]
    s5a["5a コメントとディレクティブ"]
    s5b["5b 縦棒の識別子"]
    s5c["5c データラベル"]
    s5d["5d 位置情報"]
    s5e["5e 数の構文(0018)"]
    s5g["5g ポートの骨格"]
    s5h["5h 文字列とバイトベクタのポート"]
    s5i["5i コンソールと現在のポート"]
    s5j["5j write の3種"]
    s5k["5k ファイル"]
    s5l["5l read"]
    s5m["5m exit と process-context"]
    s5n["5n time"]
    s5o["5o eval と環境"]
    s5p["5p load"]
    s5q["5q r5rs"]
    s5r["5r v0.5.0"]
    s5a --> s5b --> s5c --> s5d
    o3 --> s5d
    s5c --> s5e
    np --> s5e
    n0 -.->|"先にマージ"| s5g
    s5g --> s5h --> s5i
    s5i --> s5j
    s5i --> s5k
    s5h --> s5l
    s5a --> s5l
    s5i --> s5m
    s5i --> s5n
    nf --> s5n
    np -.->|"数として読める名前の判定"| s5j
    nf -.->|"数の書式"| s5j
    o3 --> s5o
    s5m --> s5o
    s5o --> s5p
    s5k --> s5q
    s5l --> s5q
    s5n --> s5q
    s5p --> s5q
    nl --> s5q
    s5q --> s5r
    s5d --> s5r
    s5j --> s5r
```

実線は、後ろのスライスが前のスライスのマージを待つ依存である。点線は、マージの順序の取り決めか、後から呼び先を差し替える依存で、着手を縛らない。数の書式は、0018 の 4d がプリンタに入れる `num.write` の呼び出しを、5j がそのまま使う(5g は 4d のあとなので、5j の時点で必ずある)。5j は、0018 の `scan`(4a)がまだ無ければ、数として読める名前の判定を、今の `isDecimalInteger` 相当で入れ、4a のマージのあとに `scan` に差し替える(差し替えは L3 の小さな PR にする)。

### 並行できるものと、できないもの

- L2(5a から 5d)と L3(5g から 5q)は、所有するファイルが重ならないので、並行できる。重なるのは、5l が 5a のディレクティブの状態に依存する点だけで、5l は 5a のマージを待つ。
- L2 の中は逐次である(どれも `src/reader.zig` を触る)。0018 の数の構文(5e)も、L2 の中で 5c のあとに置く。
- L3 の中では、5i のあとに、5j、5k、5m、5n を並行できる。どれも `src/prim/port.zig` か `src/platform/` に足すが、足す関数が別で、隣り合う行のコンフリクトだけである。同時に開く PR の数は、[0017](0017-parallel-lanes.md) の上限 W に従う。
- 5o は 3o のマージを待つ。5p と 5q は 5o のあとである。

### 型の骨格のコンフリクト

`src/value.zig`、`src/trace.zig`、`src/heap.zig` には、0018(L1)が数の型を、この計画(5g)がポートの型を足す。どちらも `Value` のバリアント、`Kind`、`heap_types`、`payloadBytes`、`free` の末尾に1行ずつ足すので、コンフリクトは隣り合う行だけである。

- 順序: 0018 の骨格(スライス 4d)を先にマージし、5g は 4d のマージのあとに着手する(2026-10-20 に親のセッションが決めた。合意を求める点の7の「同時なら 0018 が先」を、着手の順序まで固定したもの)。段階4のリリースが段階5より前で、5j が数の書式を呼ぶためである。4d の PR ができたときと、マージされたときは、親が知らせる。
- 5g は、main を取り込んでから、4d の行の後ろに自分の行を足す。
- どちらの骨格の PR も、型のバリアントと、GC と計上の最小の行だけにして、手続きを含めない。

### 機械の重なり

`src/machine.zig` は、L0 の 3o と、この計画の 5m と 5o が触る。`origin/main`(`83e173d`)で確かめたこと:

- 0016 は 3o の変更ファイルを `src/syntax/expand.zig`、`src/syntax/env.zig`、`src/context.zig`、`src/core.zig` としており、`src/machine.zig` にどこまで及ぶかは見積れないと書いている(0016 の「確かめられなかったこと」)。`Machine` は、`Context` を持ち、`apply` の中で `MachineOp` を振り分け、`invoke` で巻き戻す。`Context.code_roots`(3o が無くす)は `src/context.zig` にある。
- 5m が触るのは、`MachineOp` のバリアントの追加、`apply` の振り分けの1行、`invoke` の巻き戻しの目標に「終了」を加える部分である。展開器と節点には触れない。
- 5o は、`apply` から展開器を呼び、できた節点を評価する。節点の置き場所と環境の表の形は、3o が決める。

取り決め:

- 5m は、3o の着手前にマージできれば先に入れる。3o が進行中なら、5m の PR は 3o のマージを待ってから main を取り込む。どちらの場合も、マージの順序を報告する前に、変更ファイルの一覧を突き合わせる(AGENTS.md)。
- 5o は、3o のマージのあとに着手する。
- 5h は、閉じたポートの誤りを報告するため、`primitiveFailure` の振り分けに `PortClosed` の1行を足した(`src/value.zig` の `PrimitiveError` にも1つ足した)。5m が `src/machine.zig` を触るときは、この行と隣り合いうるので、main を取り込んでから変更ファイルを突き合わせる。
- 5i は、`callPure` に動的点を渡し、`Services` に `console` と `dyn` を入れる3行と、`primitiveFailure` で `WriteFailed` を条件にせず返す行を足した(`src/value.zig` の `PrimitiveError` と `src/context.zig` の `Error` にも `WriteFailed` を足した)。5m の `MachineOp.exit` は `apply` の振り分けと巻き戻しを触るので、`callPure` の呼び出しの行と隣り合いうる。5m は main を取り込んでから突き合わせる。
- 5i は、`src/main.zig` の `runFile` に標準出力の書き手を渡す引数を足し、`Interpreter.console_out` に置いた。5m もファイルの実行の部分(終了コードと `command-line`)を触るので、同じ関数の隣り合う行になる。5m は main を取り込んでから突き合わせる。

### そのほかのファイルの重なり

- `src/sucheme.zig`: [0017](0017-parallel-lanes.md) では L0 の所有である。5i(コンソールのポートの配線)と 5m(終了の結果)が、`Interpreter` に小さく足す。3o と同時に開いたときは、後からマージするほうが取り込む。
- `src/main.zig`: L6 が REPL の入口を、5m がファイルの実行の引数と終了コードを触る。触る関数が別で、隣り合う行のコンフリクトだけの見込みである。
- `lib/scheme/base.sld`: 0018 が数の識別子を、5h がポートの識別子を輸出に足す。輸出の並びの中で、L3 の分を1つの塊にまとめて置き、隣り合う行のコンフリクトにとどめる。
- `web/sucheme.js` と `tools/test-wasm/`: ホスト側の import と、新しいエクスポートの呼び出しは L3(5m、5n)が足す。`web/` のそれ以外は L7 の所有である。
- `src/prim/table.zig`: 5h、5m、5n、5o が1行ずつ足す。

### 数の構文との順序

roadmap の段階4の「リーダに基数接頭辞、正確性接頭辞、分数、小数、指数、`+inf.0` 系、複素数を追加」は、0018 の担当である。[0017](0017-parallel-lanes.md) の取り決めで `src/reader.zig` は L2 の所有なので、実装は L2 のスライス 5e として行い、0018 が解析関数を `src/num/` に置く。

- 5e は、0018 の解析関数のマージと、5c のマージのあとに置く。5a から 5c は `atom` の外(空白の読み飛ばし、`#` の分岐、`|`)を主に触り、5e は `atom` の中の数の判定を差し替えるので、順序を逆にしてもコンフリクトは小さい。0018 の解析関数が 5a より先に揃ったときは、5e を 5a の前に入れてよい。
- 5e の完了条件と検証項目は 0018 が書く。この計画は、5e を L2 の逐次の中に置くことだけを決める。

## 署名

レーンをまたいで呼ぶ関数の署名を書く([0017](0017-parallel-lanes.md) のリスクと対策の「レーン間の見えない結合」)。名前は実装の中で変えてよいが、変えたら、相手のレーンの計画書の担当に、親を通して知らせる。

0018(L1)から受け取るもの。[0018](0018-phase4-numeric-tower-unicode.md) の「レーンの間の関数の署名」が正で、ここには使う関数だけを写す(0018 が main に入った 2026-10-20 に、この計画の初めの案を 0018 に合わせて直した):

```zig
// src/num/number.zig(4e。4d では仮の write だけ)
pub fn write(out: *std.Io.Writer, scratch: std.mem.Allocator, v: Value, radix: u8) (std.Io.Writer.Error || error{OutOfMemory})!void
pub fn isNumber(v: Value) bool

// src/num/syntax.zig(4a): 確保しない。
pub fn scan(text: []const u8, default_radix: u8) ?Literal
```

- プリンタの数の分岐から `num.write` を呼ぶ行は、0018 の 4d が `src/printer.zig` に1回だけ足す(0018 の 4d の中身)。5j は、その行を残したまま、ラベルと縦棒の部分を足す。5j が `scratch` を計上つきの確保に移すとき、`num.write` に渡す `scratch` も同じ確保になる。
- シンボルを縦棒で囲むかの判定は、`scan(name, 10)` が null 以外を返す名前を「数として読める」とみなす。`scan` は確保しないので、プリンタから呼べる。初めの案で 0018 に頼むとしていた確保しない判定の入口は、`scan` で足りるので要らない。
- リーダの数の構文(5e)は、0018 の「リーダ(L2)の呼び方」のとおり `num.parse(heap, token, 10)` を呼ぶ。

L3 が置くもの(`src/port.zig`。5h で入れる):

```zig
pub const Error = heap_mod.Error || error{ PortClosed, WrongDirection, WrongKind, Io };

// テキストの入力ポートから1文字を読む。終端なら null。
pub fn readChar(heap: *Heap, port: *Port) Error!?u21;
pub fn peekChar(heap: *Heap, port: *Port) Error!?u21;
// バイナリの入力ポートから1バイトを読む。終端なら null。
pub fn readByte(heap: *Heap, port: *Port) Error!?u8;
pub fn peekByte(heap: *Heap, port: *Port) Error!?u8;
// 出力ポートにバイト列を書く。テキストのポートには妥当な UTF-8 だけを渡す。
pub fn writeBytes(heap: *Heap, port: *Port, bytes: []const u8) Error!void;
pub fn flush(port: *Port) Error!void;
pub fn close(port: *Port) void;

// read(5l)のための入口: まだ読んでいない入力の、手元にある分と、そこから n バイトを
// 読んだことにする操作。足りなければ fill で足す(終端なら false)。
pub fn pending(port: *const Port) []const u8;
pub fn consume(port: *Port, n: usize) void;
pub fn fill(heap: *Heap, port: *Port) Error!bool;

// プリンタ(5j)のための入口: ポートに書く std.Io.Writer。
pub fn writer(port: *Port, heap: *Heap) PortWriter;
```

プリンタ(5j、`src/printer.zig`)の入口は、次の形にする。今の `write` と `display` は、この1つにまとめる。

```zig
pub const Mode = enum { write, shared, simple, display };

// ラベルの表と作業スタックは、heap の計上つきの確保で持つ。
pub fn print(out: *std.Io.Writer, heap: *Heap, symbols: *const symbol.Table, v: Value, mode: Mode) Error!void;
```

## ホスト側のインポートの設計

[platform-and-web.md](../design/platform-and-web.md) のインポートの節は、`host_write_stdout`、`host_write_stderr`、`host_now_ms` の3つに限る、と書いている。今の `src/wasm.zig` が宣言するのは `host_write_stderr` だけで、パニックのときに使う。

- 標準出力と標準エラー(5i): 今のまま、出力バッファに書く。`host_write_stdout` は足さない(足す段階は決まっていない。platform-and-web.md)。`current-error-port` への書き込みも、5i では出力バッファに書く。標準出力と分けてホストに渡すかは、L7 の Web UI の表示と合わせて決めるので、段階5では分けない。分けないことを 5i の PR に書く。
- 標準入力(5i): 合意を求める点の6で決める。
- ファイル(5k): import を足さない。WASM は実ファイルを持たない(platform-and-web.md のプラットフォーム抽象)。
- コマンドラインと終了(5m): import でなく、エクスポート(`sucheme_set_command_line`、`sucheme_exit_code`)と状態コード -6 で扱う(platform-and-web.md の設計どおり)。
- 時刻(5n): 合意を求める点の2で決める。

import を足すと、ホストのすべて(`web/sucheme.js` と `tools/test-wasm/main.mjs`)が、その関数を渡さなければ、`WebAssembly.instantiate` が失敗する。5n は、`src/wasm.zig` の宣言と、2つのホストの `env` を、同じ PR で足す。`zig build test-wasm` が、渡し忘れを落とす。

## 各ライブラリの作り方

| ライブラリ | 作り方 | スライス |
| --- | --- | --- |
| `(scheme base)` のポートの識別子 | Zig のプリミティブ(`src/prim/port.zig`)と、Scheme の `call-with-port`。`base.sld` の輸出に足す | 5h、5i |
| `(scheme write)` | `display` を 5i で、`write` `write-shared` `write-simple` を 5j で。プリミティブはプリンタを呼ぶ | 5i、5j |
| `(scheme file)` | 開く手続きと `file-exists?` `delete-file` は Zig。`call-with-input-file` `call-with-output-file` は Scheme(`call-with-port` の上)。`with-input-from-file` `with-output-to-file` は、`parameterize` で現在のポートを差し替える Scheme の手続き(R7RS 6.13.1 の記述を原文で確かめる) | 5k |
| `(scheme read)` | `read` だけ。Zig のプリミティブで、`Reader` を呼ぶ | 5l |
| `(scheme process-context)` | `exit` は機械操作プリミティブ。残りは純粋プリミティブ | 5m |
| `(scheme time)` | 純粋プリミティブ3つ | 5n |
| `(scheme eval)` | `eval` は機械操作プリミティブ、`environment` は純粋プリミティブ(展開器のライブラリの表を引く) | 5o |
| `(scheme repl)` | `interaction-environment` だけ。REPL のトップレベルの環境を指す環境の値を返す | 5o |
| `(scheme load)` | `load` だけ。読み込みはリゾルバ、評価は 5o の機構 | 5p |
| `(scheme r5rs)` | 再輸出の `.sld` と、`null-environment` `scheme-report-environment` | 5q |

## 検証項目の割り当て

- 衛生性の検証項目の9(循環データと共有構造の `quote`): 5c。データラベルで循環と共有を作り、`eq?` で同一性を確かめる。剥ぎ取りが循環で止まることは、`src/syntax/expand.zig` の単体テスト(`quote strips the aliases of a cycle`)がすでに見ている。Scheme から通すのが 5c の追加である。結果を `write` で見るケースは 5j に足す。
- [runtime.md](../design/runtime.md) の例外の事例12: 5m。`(dynamic-wind (lambda () #f) (lambda () (display "in") (exit 3)) (lambda () (display "cleanup")))` の出力と終了コードを、ネイティブ(ファイルの実行)と WASM(-6 と `sucheme_exit_code`)の両方で見る。
- roadmap の完了条件の `#!fold-case`: 5a(リーダ)と 5l(ポートごとの状態)。
- roadmap の完了条件の循環の `write`: 5j。
- roadmap の完了条件の付録Aのライブラリ: 5q。`zig build report` と `zig build check-report` が、`lib/` の輸出から表を作る。
- `Expander.constant` の EOF の値と約束の分岐: 5o。
- R7RS 6.13、6.14、6.12、2.2 と 7.1.1(リーダ)の各識別子と構文: 各スライスが、R7RS の原文([docs/spec/](../spec/README.md))の例から `tests/scheme/` のケースを起こす。原文で確かめていない例は、PR 本文に「未確認」と書く。
- 規模を試すテスト: 入れ子の深いブロックコメント、長いデータラベルの鎖(5c)、深い循環の `write`(5j)、大きな文字列ポートの読み書き(5h)、`read` の読み直し(5l)。縮小版を層1 に、規模を試す版を `tests/scheme-slow/` に置く。

`tests/scheme/` と `tests/scheme-slow/` の番号は、[0017](0017-parallel-lanes.md) の取り決めで、L2 が 0500 台、L3 が 0600 台である。スライスごとに次のように振る。

| スライス | 番号 |
| --- | --- |
| 5a | 0500 から 0509 |
| 5b | 0510 から 0519 |
| 5c | 0520 から 0529 |
| 5d | 0530 から 0539 |
| 5e(0018) | 0540 から 0559 |
| 5g | 0600 から 0604 |
| 5h | 0605 から 0619 |
| 5i | 0620 から 0629 |
| 5j | 0630 から 0639 |
| 5k | 0640 から 0654 |
| 5l | 0655 から 0664 |
| 5m | 0665 から 0674 |
| 5n | 0675 から 0679 |
| 5o | 0680 から 0689 |
| 5p | 0690 から 0694 |
| 5q | 0695 から 0699 |

## 合意を求める点

勧める案を先に書く。勧める案でよいときは、そう返信する。小さく戻せる選択(ファイルの構成、名前、テストの足し方)は、[AGENTS.md](../../AGENTS.md) の規則どおり、ここでは諮らず、PR に書く。1 から 3 は [open-questions.md](../design/open-questions.md) の「段階5までに決める」の3行で、4 から 6 は、この計画を書くなかで、データ形式または設計の判断と分かったものである。

1. ポートのバッファの大きさと、バッファリングの方針(open-questions.md の1行目)。
   - 勧める案: ファイルとコンソールのポートは、開くときに固定の大きさのバッファを1つ持つ。バッファはヒープの計上つきの確保で取り、ポートと一緒に回収する。ファイルへの出力は、バッファが満ちたとき、`flush-output-port`、閉じるとき、終了するときに書き出す。コンソールの出力は、それに加えて、トップレベルの式の評価のたびと、コンソールから入力を読む前に書き出す(プロンプトと出力の順を保つため)。大きさは、5k で、候補の値を `ReleaseSafe` で測って決め、決めた値と測定の方法をコードの `Why:` コメントに書く。文字列ポートとバイトベクタポートは、このバッファを持たない(3の表現そのものがバッファである)。
     - メリット: 確保がポートごとに1回で、上限への計上が開くときに決まる。書き出しの時点が決まっているので、出力の順序をテストできる。
     - デメリット: 大きな値を1つ選ぶと、多数のファイルを開いたときに計上が膨らむ。小さく選ぶと、システムコールが増える。
   - 別案A: バッファを持たず、書き込みのたびにシステムコールを呼ぶ。実装が最も小さいが、`write-char` を繰り返すプログラムが遅い。
   - 別案B: 伸びるバッファ。大きな書き込みでシステムコールが減るが、計上が書き込みの量に比例して動き、上限の超過が書き出しの途中で起きうる。

2. ブラウザで単調時間と絶対時刻の両方を得る import の形(open-questions.md の2行目)。
   - 勧める案: import を2つにする。`env.host_now_ms() -> f64` は絶対時刻(UNIX 時刻のミリ秒。ブラウザでは `Date.now()`)、`env.host_monotonic_ms() -> f64` は単調時間(ブラウザでは `performance.now()`)を返す。`jiffies-per-second` は、ネイティブと WASM で同じ値(マイクロ秒、`1000000`)にする。`current-second` は、絶対時刻に TAI と UTC の差の定数を足す(5n の中身)。platform-and-web.md の import の一覧と「3つに限る」の文は、5n で4つに直す。
     - メリット: 1つの import が1つの JavaScript の API に対応し、ホストの実装が読んで分かる。用途の取り違えを型でなく名前で防げる。
     - デメリット: ホストが用意する関数が1つ増える。
   - 別案A: import を1つにし、用途の引数を持たせる(`env.host_now(kind: u32) -> f64`)。import の数は増えないが、引数の値の約束がホストとの契約に増え、知らない値を渡したときの扱いを決める必要がある。
   - 別案B: 単調時間の import を持たず、`current-jiffy` を `host_now_ms` から作る。時計が戻ると `current-jiffy` が減り、R7RS 6.14 の「The starting epoch is guaranteed to be constant during a run of the program」に反する経過時間を返しうる。

3. 文字列ポートとバイトベクタポートの内部表現(open-questions.md の3行目)。
   - 勧める案: 入力のポートは、開くときに、文字列の UTF-8 のバイト列(またはバイトベクタの中身)をポートのペイロードに写し、読んだ位置をバイトの添字で持つ。出力のポートは、伸びるバイト列をペイロードに持ち、`get-output-string` と `get-output-bytevector` が新しいオブジェクトに写して返す。ペイロードは、文字列やバイトベクタと同じく、計上して回収する。
     - メリット: 開いたあとで元の文字列が `string-set!` で変わっても(R7RS 6.13.1 はこの場合を unspecified としている)、ポートの添字が文字の途中を指すことがない。文字の境目の検査が要らない。GC が辿るポインタが増えない。
     - デメリット: 入力の文字列の長さに比例する写しと計上が、開くたびにかかる。
   - 別案A: 入力のポートが元の `String` を指し、バイトの添字を持つ。写しは要らないが、`string-set!` が UTF-8 の長さの違う文字を書くとバイト列が作り直されるので、読むたびに添字が範囲と文字の境目に収まるかを確かめる必要がある。確かめ忘れると、安全ビルドで panic する。
   - 別案B: 入力のポートを、文字の配列(`u21` の列)で持つ。`read-char` が定数時間だが、文字列の4倍の大きさを計上し、`read` の `Reader` に渡すには UTF-8 に戻す必要がある。

4. 閉じ忘れたファイルポートの扱い(データ形式と GC の設計に関わる)。
   - 勧める案: ヒープが、開いているファイルポートの弱い一覧を持つ。到達できなくなった開いたポートは、回収のときに、出力なら書き出してから、閉じる。書き出しと閉じる操作の誤りは捨てる。`Interpreter.deinit` と `exit` は、一覧に残るポートをすべて書き出して閉じる。ファイルを開くとき、記述子が尽きた誤りが返ったら、GC を1回走らせて、1回だけ開き直す。回収のときに閉じるには、ヒープの回収が、ホストの閉じる関数を呼べる必要がある。`Heap` に、閉じる関数を差し込む口を1つ足す(5k で、その形を PR に書く)。
     - メリット: 閉じ忘れるプログラムでも、記述子とバッファが際限なく残らない。終了時に出力が失われない。
     - デメリット: 回収の中で入出力が起きる。書き出しの誤りを利用者に報告できない。`Heap` がホストに依存する口を持つ。
   - 別案A: 回収のときに閉じない。開いたポートは、一覧がルートとして生かし続け、`Interpreter.deinit` と `exit` で閉じる。動きが決定的だが、閉じ忘れたポートのメモリと記述子が、セッションの終わりまで残る。REPL で開き続けると、記述子が尽きる。
   - 別案B: 別案Aに、開いているファイルポートの数の上限を足し、超えたら `file-error` を送出する。資源は有界になるが、上限の値を決める根拠が要る。

5. `eval` を 3o のあとに置くこと(実施の順序)。
   - 勧める案: 5o(`eval` と環境の値)と、それに依存する 5p と 5q を、3o のマージのあとに着手する。理由は「5g から 5r の中身」の 5o にある(3o の前に入れると、`eval` を繰り返すループが、計上の外の節点を際限なく積む)。環境の値の型の形(ライブラリの表を指すか、写しを持つか)は、3o の結果に合わせて 5o で決め、データ形式の判断として、5o の着手前に改めて諮る。
     - メリット: 3o が解く問題を、`eval` で作り直さない。
     - デメリット: 段階5の最後の鎖が、3o の長さだけ延びる。3o が段階4の最初に送られた場合(0016 の範囲を狭める線)、5o も一緒に遅れる。
   - 別案: 5o を 3o より先に入れ、`eval` が作る節点を、評価が終わるまでの一時の領域に置いて捨てる。3o を待たないが、`eval` の中で定義した手続き(クロージャが節点を指す)が評価のあとも生きるので、捨てられない。この案は、確かめた範囲では成り立たない見込みである(推測。`Closure` が節点を指すことは `src/value.zig` で確かめたが、捨て方の全体は試していない)。

6. 段階5の WASM の標準入力(データの流れに関わる)。
   - 勧める案: 段階5の WASM では、`current-input-port` を、最初から終端にある入力ポートにする。`(read-char)` は EOF を返し、`char-ready?` は `#t` を返す(R7RS 6.13.2 は終端で `#t` を求める)。ホストからの入力は、段階8の再開可能な機械と `sucheme_provide_input` で入れる。この扱いを、v0.5.0 のリリースノートの既知の制限に書く。
     - メリット: 段階8の設計(状態コード 2 と入力待ち)を前倒しせずに、入力を読むプログラムが WASM でも止まらずに終わる。
     - デメリット: ブラウザで `read` を使うサンプルが、段階8まで動かない。
   - 別案: 段階5で、評価の前にホストが入力の全体を渡すエクスポート(仮の名前 `sucheme_set_stdin`)を足す。対話はできないが、入力を読むサンプルが動く。段階8で入れる `sucheme_provide_input` と別の経路になり、境界の契約が増える。

7. 型の骨格のマージの順序(報告)。「型の骨格のコンフリクト」の節のとおり、先に ready になったほうを先に、同時なら 0018 を先にする。[0017](0017-parallel-lanes.md) の取り決めの具体化で、確認の対象ではない。異論があれば返信する。合意のあと、4d を先にマージし、5g はそのあとに着手する形に固定した(「型の骨格のコンフリクト」の節)。

回答(2026-10-20): ユーザーが、1 から 6 のすべてを勧める案どおりに承認した。

## 検証

各スライスの PR を ready にする前に、[AGENTS.md](../../AGENTS.md) の検証コマンド表の「全コミット」の行をすべて通す。段階5で足す検証は次のとおりである。

- 5a から 5q: `zig build test-scheme` の `tests/scheme/` に、上の番号の範囲でケースを足す。
- 5i、5m、5n: `zig build test-wasm` に、出力の順序、-6 と終了コード、時刻の import のラウンドトリップを足す。
- 5k: ファイルを書いて読み返すケース。書き込み先は、テストのランナーが作る一時のディレクトリにする(ランナーの変更が要るかは 5k で確かめる)。
- 5m: ファイルの実行の終了コードは、今は単体テストの外で手で確かめている(0016 の 3m の進捗)。事例12の終了コードを自動で見る方法(`tests/cli-slow/` の形を使えるか)を、5m で確かめる。
- 5q: `zig build report` と `zig build check-report`。

敵対的レビューは、[AGENTS.md](../../AGENTS.md) の規則に従う。ミューテーションの担当1本を基本にし、5c、5j、5k、5o のように、入力に比例する確保か、GC と計上に関わるものには、挙動を広く試す担当を足す。メモリと衛生性に関わる変更(5c、5g、5k、5o)は、T3 の担当のレビューを通す([0017](0017-parallel-lanes.md) のリスクと対策)。文書だけの変更(この計画書を含む)には、サブエージェントのレビューを走らせない。

## ファイル

追加または変更する主なファイル。所有は [0017](0017-parallel-lanes.md) のレーンの表に従う。

| ファイル | 変更 | スライス |
| --- | --- | --- |
| `src/reader.zig` | コメント、ディレクティブ、縦棒の識別子、データラベル、位置情報 | 5a から 5d(L2) |
| `src/string_syntax.zig` | 文字列の行継続、縦棒の識別子の名前 | 5a、5b(L2) |
| `src/value.zig`、`src/trace.zig`、`src/heap.zig` | ポートの型、環境の値の型、`MachineOp` の `exit` と `eval` | 5g、5m、5o |
| `src/port.zig`(新規) | ポートの読み書き | 5h、5i、5k |
| `src/prim/port.zig`(新規) | ポートの手続き | 5h から 5l |
| `src/prim/process.zig`、`time.zig`、`eval.zig`(新規) | プロセス、時刻、`eval` の手続き | 5m、5n、5o、5p、5q |
| `src/platform/native.zig`、`src/platform/wasm.zig`(新規) | ホストの機能の差。5i では差が無いので作らず、差が初めて出るスライスが作る | 5k、5m、5n |
| `src/printer.zig` | `write` の3種と `display`、シンボルの縦棒 | 5j |
| `src/machine.zig` | `exit` の巻き戻し、`eval`。閉じたポートと書き込みの失敗の振り分け、`Services` の現在のポート(5h、5i が数行) | 5m、5o |
| `src/resolve.zig` | 第2類の入口、`load` | 5k、5p |
| `src/sucheme.zig` | 新しい読み取りの誤りの説明の振り分け(1行ずつ)、コンソールのポート、終了の結果 | 5a、5b、5i、5m |
| `src/main.zig` | プログラムへの引数、終了コード。ファイルの実行のコンソールの書き先(5i が数行) | 5m |
| `src/wasm.zig`、`web/sucheme.js`、`tools/test-wasm/main.mjs` | エクスポートと import | 5i、5m、5n |
| `lib/scheme/base.sld` | ポートの識別子 | 5h、5i |
| `lib/scheme/write.sld` `file.sld` `read.sld` `process-context.sld` `time.sld` `eval.sld` `repl.sld` `load.sld` `r5rs.sld`(新規) | ライブラリ | 5i から 5q |
| `lib/sucheme/procedures.scm` | `call-with-port`、ファイルの `call-with-*` と `with-*` | 5h、5k |
| `docs/design/platform-and-web.md`、`runtime.md`、`frontend.md`、`open-questions.md` | 決めたことの反映、段階5の行の削除 | 各スライス、5r |

## 確かめた事実と、確かめられなかったこと

確かめた事実(`origin/main` の `83e173d` で、ソースと文書を読んだ):

- `src/reader.zig` の `Reader` は、入力全体のスライス(`src`)と位置(`pos`)と畳み込みの状態(`fold_case`)を持ち、`next` が1つのデータを読む。`#u8(` のバイトベクタは読める。ブロックコメントと `#;` は読めず、`isIncomplete` の判定表は `"#| x"` と `"(a #;1"` を偽としている。`|` は `unreadable token` になる。
- `src/string_syntax.zig` は `\x` の16進のエスケープを読み、行継続を読まない(「行継続はまだ読まない」のコメント)。
- `src/printer.zig` は、作業スタックを `scratch` に置き、循環を検出しない。シンボルは名前だけで書く。
- `src/value.zig` の `MachineOp` に `eval` と `exit` は無い。`ConditionKind` には `read` と `file` がすでにある。
- `src/wasm.zig` が宣言する import は `host_write_stderr` だけである。`host_write_stderr` を渡すホストは、`web/sucheme.js` と `tools/test-wasm/main.mjs` の2つである。
- R7RS の原文(`docs/spec/` の errata 訂正版)で、次を確かめた。`write` は循環にだけラベルを使い、循環が無ければ使ってはならない。`write-shared` は2回以上現れるペアとベクタすべてにラベルを付ける。`write-simple` はラベルを使わない。`display` は自己参照で止まらなければならない。非 ASCII を含むシンボルは `write` で縦棒で囲む。`open-input-string` のあとで文字列を変えたときの効果は unspecified である。`current-second` は TAI の不正確な数で、UTC に定数を足したものでよい。`current-jiffy` は正確な整数で、起点は1回の実行の間は変わらない。`exit` は例外を送出せず、継続に戻らない。`environment` が返す環境と束縛は変更できず、そこでの `define` の `eval` は誤りを送出する。
- `tests/r7rs-required/r5rs.txt` は、`exact->inexact` `make-polar` などの数の手続きと、`null-environment` `scheme-report-environment` を含む。

確かめられなかったこと:

- 0018(段階4)の計画書は、この計画書を書いた時点で push されていなかった。「署名」の節は、0018 が main に入ったあとで、0018 に合わせて直した。
- 3o が `src/machine.zig` と `src/sucheme.zig` のどこまでを変えるかは、0016 が見積れないとしており、ここでも分からない。
- Zig 0.17.0 の `std.Io.Clock` の時計の種類、`std.Io.File` の閉じる関数が `Io` を要るか、記述子が尽きたときの誤りの名前。5k と 5n の着手時に標準ライブラリのソースで確かめる。
- TAI と UTC の差の現在の値。5n で一次情報で確かめる。
- 5l の読み直しの費用が、実際のプログラム(大きなファイルの `read`)でどれだけになるか。5l で測る。

## 範囲を狭める線

次の兆候が出たら、巡を足す前に、範囲を狭めるかをユーザーに諮る(AGENTS.md の「終わらなさそうなら」の規則)。

- 5k の GC とファイルの閉じ方が、レビューの巡ごとに必須の指摘を減らさない。このとき、合意を求める点の4の別案A(回収のときに閉じない)に落とし、閉じ忘れの資源を既知の制限として v0.5.0 に入れる。
- 3o が段階4以降に送られる。このとき、5o、5p、5q を段階6の前に送り、v0.5.0 の完了条件の「付録Aのライブラリすべて」を、`(scheme eval)` `(scheme repl)` `(scheme load)` `(scheme r5rs)` を除いた形に狭めることを諮る(roadmap の完了条件の変更になる)。
- 5c のプレースホルダの置き換えが、GC と計上の不変条件を変える必要に行き当たる。このとき、T3 へ引き継ぐ([0017](0017-parallel-lanes.md) の引き継ぎの条件の4)。

## 位置情報の残りの割り当て

5d は、展開時の誤りに位置を前置したが、2つを残した(docs/design/frontend.md の「現状(スライス 5d)」、roadmap の「位置情報の残り」)。

- ライブラリのファイルそのものと、ライブラリの宣言(`include`、`include-ci`、`include-library-declarations`)が読むファイルの位置の記録。読む経路が `src/syntax/library.zig` にあり、5d では触れなかった。いまは、その中の誤りが、トップレベルの `import` の形式の位置になるか、位置が付かない。
- コアIRの節点への位置の複写と、実行時の誤りへの位置の表示。

前者を、次のスライス 5s として段階5に置いた(2026-10-22 にユーザーが着手を指示した)。後者は、読む側(機械が今の節点の位置を引く変更)と一緒に入れると決めた(2026-10-21)ので、0017 の L7 の「エラー位置の表示」の計画書で、段階とスライスを決める。ここでは割り当てない。

| スライス | レーン | 完了条件 | 所有するファイル | 階層 | 前提 | 並行 | 規模 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 5s ライブラリのファイルの位置 | L2 | ライブラリのファイルの本体の誤りと、ライブラリの宣言が読むファイルの中の誤りが、そのファイルの名前と行と桁を添えて報告される。REPL から `import` したライブラリでも付く | `src/syntax/library.zig`(L0 の所有。`readLibraryForm` と `enterIncluded` が、読むファイルの名前を `src/syntax/source.zig` に渡す部分だけ)、`src/syntax/source.zig`(1つのデータを位置つきで読む入口)、`docs/design/frontend.md` の「現状」、`src/sucheme.zig` のテスト(L0 の所有) | T2 | 5d のマージ。L0 が `src/syntax/library.zig` を触るスライスを進めていないこと(着手の前に親が確かめる) | L3 と並行 | 小 |

- 段階: 段階5に置く。リーダの完全化と位置情報の副表を段階5に置いた理由(0014)と同じで、5d の続きだからである。段階5の完了(5r)の前提に 5s を加えた。
- 名前: 5e は 0018 に渡した名前、5f は欠番で、5g から 5r は L3 が使うので、次の 5s にする。
- 所有の外のファイル: `src/syntax/library.zig` は L0 の所有なので、5d と同じく、触れる範囲をユーザーの承認で決める。2026-10-22 に、名前を渡す2か所だけと決まった。宣言の誤りの位置と、本体の実行時の誤りの位置は、frontend.md の「現状(スライス 5d)」の既知の制限に書き、3q 以降で直す候補にした。
- 規模の根拠: 5d で、読む経路に位置を渡す形(`source.readDataFrom`)ができている。`library.zig` の2つの読み手が、同じ形でファイルの名前を渡せば足りる見込みである。見込みで、`library.zig` の読み手を確かめて決めたものではない。
- `tests/scheme` の番号は、5d の範囲(0530 から 0539)の残りを使う。ハーネスはファイルの名前を渡さないので、位置の確かめは単体テストで行う見込みである。

## 合意のあとにやること

- roadmap の段階5の項目を、入っているもの(`#u8`、16進のエスケープ)が分かる形に直し、位置情報の副表の「スライス未割り当て」を 5d に替える。
- open-questions.md の段階5の3行を、決めたスライス(5k、5n、5h)で消す。
- 0018 の計画書と、署名と骨格の順序を突き合わせる。食い違いは、親を通して両方の担当に知らせる。

## 進捗

| スライス | 状態 | PR |
| --- | --- | --- |
| この計画書 | 合意済み(2026-10-20) | suchi/sucheme-zig#132 |
| 5a | マージ済み。ブロックコメント、データコメント、`#!fold-case` と `#!no-fold-case`、文字列の行継続と行の終わり、CR で終わる行コメント。ディレクティブの状態は同じ `Reader` の中だけで、REPL の入力をまたいで残すのは 5i と 5l | suchi/sucheme-zig#141 |
| 5b | マージ済み。縦棒の識別子。エスケープは <symbol element> のものに `\"` と `\\` を足したもので、行継続は無い。畳み込む読み手でも畳み込まない。縦棒を付けて書き出すのは 5j | suchi/sucheme-zig#146 |
| 5c | マージ済み。データラベル。実装の途中で、リテラルの外の循環(R7RS 2.4 が誤りとする `#1=(begin (display #\x) #1#)`)と、`syntax-rules` のテンプレートの循環で展開器が止まらないと分かった。0017 の引き継ぎの条件の2と3に当たるので止めて諮り、2026-10-20 に、リーダがコードとしての循環を断る形と、`rules.compile` がパターンとテンプレートの循環を断る形(L0 の `src/syntax/rules.zig` への小さな追加)が承認された。既知の制限は docs/design/frontend.md の「現状(スライス 5c)」にある | suchi/sucheme-zig#147 |
| 5d | マージ済み。位置情報の副表と、展開時の誤りの位置(`path:line:column: message`)。節点への複写は入れない。ライブラリのファイルと、ライブラリの宣言が読むファイルは、まだ位置を記録しない(docs/design/frontend.md の「現状(スライス 5d)」) | suchi/sucheme-zig#160 |
| 5s | PR 作成済み。ライブラリのファイルと、ライブラリの宣言が読むファイルの位置の記録。`library.zig` は名前を渡す2か所だけ。残した制限は docs/design/frontend.md の「現状(スライス 5d)」の既知の制限にある | suchi/sucheme-zig#168 |
| 5g | マージ済み。`Value` の `port` と、ヒープの型 `Port`(`src/value.zig`)。裏付けは、文字列ポートとバイトベクタポートが共有する `memory` の1つだけで、どちらかは `element`(`textual` か `binary`)で分ける。確保は `Heap.createMemoryPort`、出力の領域を伸ばすのは `Heap.growPortBytes` で、5h が `src/heap.zig` を触らずに書けるよう、ここで置いた。`Kind` の網羅的な switch に `.port` を足すため、`src/prim/equiv.zig`、`src/prim/procedure.zig`、`src/prim/promise.zig`、`src/syntax/expand.zig` にも1行ずつ触れた(4d と同じ4か所)。レビューで足さなかったテストと、後のスライスへの申し送りは「5g のレビューの記録と、後のスライスへの申し送り」の節にある | suchi/sucheme-zig#205 |
| 5h | マージ済み。`src/port.zig` の読み書きの関数と、`(scheme base)` のポートの手続き(`src/prim/port.zig`、`call-with-port` は `lib/sucheme/procedures.scm`)。ポートの引数は、5i が現在のポートを入れるまで省略できない。署名の節のうち、`fill`(5k)、`flush`(書き出す先を持つポートを入れる 5i)、`writer`(5j)は、使うスライスが足す。閉じたポートへの読み書きは、新しい誤り `PortClosed`(文言は `port is closed in 手続きの名前`)、向きと種類の違いは型の誤りである。所有の外に、`src/value.zig` の `PrimitiveError` と `src/machine.zig` の `primitiveFailure`(「機械の重なり」の節)、`lib/sucheme/procedures.sld` の輸出、`tools/test-scheme/main.zig` の `mutators` の表に1つずつ足し、未実装の例にポートの名前を使っていた `tests/scheme/0292-scheme-libraries.txt`、`tools/conformance-run/run.zig`、`tools/test-wasm/main.mjs` のテストを、まだ無い現在のポートの名前に替えた(5i で替え直す) | suchi/sucheme-zig#207 |
| 5i | マージ済み(2026-10-29)。実績は、PR を開いてから ready まで約3時間20分、ready からマージまで約17時間(ユーザーの判断の待ちを含む)。コンソールのポート(`Port.Backing` の `console`)と、`current-input-port` `current-output-port` `current-error-port` のパラメータ(`Context.console`、`%console-parameter`)。ポートを省略した手続きは、呼び出しの動的点での現在のポートを使う。`display` を `(scheme write)` に置き、署名の節の `writer` にあたる `port.Writer`(プリンタがポートに直接書く書き手)を、5j より先にここで入れた(作業領域に全体を写すと、計上の外に大きく確保するため)。コンソールへの書き込みの失敗は、条件にせず `WriteFailed` で機械の外へ返す。ファイルの実行は、式の値を捨て、プログラムの出力を標準出力に書く(`Interpreter.console_out`)。標準出力に書けなければ、`error: cannot write to standard output` を出して終了コード 74 で止める(`src/main.zig` の契約の表)。既知の制限: 標準エラーは標準出力と同じ書き先、標準入力は読めない(上の 5i の中身)。所有の外のファイルと理由は PR 本文にある | suchi/sucheme-zig#208 |
| 5j | PR 作成済み。`write` `write-shared` `write-simple` と `display` を、プリンタの1つの入口(`printer.print`)の4つの形にした。循環と共有のデータラベル、縦棒で囲むシンボル、表と作業スタックのヒープの上限への計上。決めたことは上の 5j の中身の「実施の結果」にある。受け入れた制約: `write` と `display` と `write-shared` の作業領域は、書くペアとベクタの数に比例し、上限に数える。1ペアあたりの大きさは、ペアそのものと同じ桁である(測った値は PR 本文にある)。そのため、データとその書き出しの作業領域の合計が上限を超えると、データは作れても、REPL で結果を表示すると `heap limit exceeded` になる。`write-simple` は、長いリストで定数、深い入れ子で比例する | suchi/sucheme-zig#212 |
| 5k から 5r | 未着手 | - |

## 次にやること

- 「合意のあとにやること」の1つ目(roadmap の段階5の項目)は、この計画書の PR で済ませた。3つ目(0018 との突き合わせ)は、5a の PR で「署名」の節を直して済ませた。open-questions.md の3行は、決めた内容を実装するスライス(5h、5k、5n)の PR で消す。5h の行(文字列ポートとバイトベクタポートの内部表現)は、5h の PR で消した。
- L2 の 5a から 5d は、すべてマージした。L2 は 5s のレビューを収束させる。5s のあとの L2 のスライスは、この計画書には無い。
- L3 は 5j の PR のレビューを収束させる。5k、5m、5n は 5i のマージのあとに着手できる。5l は 5h と 5a のあとに着手できる。
- 標準エラーを標準出力と分ける変更(5i の既知の制限)は、割り当て先の案を 5m にした(roadmap の項目)。`evalPrint` にエラーの書き手を足す変更が、5m がファイルの実行の終了の経路で触る場所と同じだからである。決めるのは親のセッションである。
- 5j のマージのあと、0024 の「残っていること」の循環するデータの印字が、準拠スイートのランナーでも止まることを確かめる(0024 の次にやること)。
- 次のスライスの着手は、親のセッションの指示を待つ。
