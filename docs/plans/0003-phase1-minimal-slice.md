# 0003: 段階1の実装計画 — 通しで動く最小の縦切り

- 対応する決定: [ADR-0018](../adr/0018-incremental-vertical-slices.md), [ADR-0027](../adr/0027-severity-by-consequence-and-a-cost-side-stop.md)
- 段階: 1
- 日付: 2026-10-09

## 用語

スライスは、段階を分けた、通しで動く縦切りの作業単位である。英語の vertical slice に当たり、読み取りから実行・表示までの全部の層を薄く貫いて動かす。コードのコメントとブランチ名は、英語の `slice` と書く。Zig の `slice`(`[]T`)とは別物である。

以前の文書は、これを「切片」と書いていた。[ADR-0029](../adr/0029-no-tail-marks-in-stage-1-machine.md) と [ADR-0030](../adr/0030-lexical-address-width-u32.md) の本文に「切片」が残っているのは、`main` にある ADR の本文を書き換えない規則([adr/README.md](../adr/README.md))による。読み替えは「切片」から「スライス」へである。

## この計画が解こうとしている問題

[roadmap.md](../roadmap.md) の段階1は14個の作業項目を持ち、完了条件が「階乗の定義と呼び出しがネイティブとブラウザの両方で動く。100万回の末尾再帰が一定のメモリで完了する。未処理例外の経路が動く」である。値表現・ヒープ・GC・リーダ・プリンタ・展開器・CEK機械・プリミティブ・REPL・WASM・Web UI が全部そろう。

これを1つの PR にすると、段階0で起きたことが繰り返される。レビューの対象が大きいほど指摘は増え、修正が次の指摘を生み、どこで止めるかの判断が効かなくなる。段階0の経緯は [review/stage0-findings.md](../review/stage0-findings.md) にある。

そこで段階1を、それぞれ単独でマージできる縦切りに割る。各スライスは「通しで動く」ことを保ち、完了条件を1行で書ける大きさにする。

## スライス

各スライスは1つの PR になる。前のスライスがマージされてから次を始める。ただし 1i のあとは、互いに独立な 1k、1l、1j-1 から 1j-3 を並行して進める(下の表の下の注記)。

| スライス | 完了条件 | 新しく入るもの |
| --- | --- | --- |
| 1a | `zig build run` で `(+ 1 2)` と打つと `3` が返る | 値表現(固定長整数のみ)、リーダ(整数・括弧・空白)、プリンタ(整数)、評価器(呼び出しのみ)、プリミティブ `+`、素朴な REPL |
| 1b | `(define x 1)` と `x` が動く。未定義の識別子がエラーになり REPL が止まらない | シンボルのインターン、環境、`define`、未処理エラーの報告経路 |
| 1c | `(if #f 1 2)` と `(quote (1 2))` が動く | 真偽値、空リスト、ペア、`quote`、`if`、リーダのリストと `'` |
| 1d | `((lambda (x) (+ x 1)) 2)` が動く | 手続き値、`lambda`、`begin`、`set!`、引数の束縛。局所変数は名前で引く環境フレームで表し、字句アドレスは使わない |
| 1e | `(define (fact n) (if (= n 0) 1 (* n (fact (- n 1)))))` と `(fact 10)` が動く | 再帰、プリミティブの拡充(比較と算術)、内部定義 |
| 1f | 末尾再帰で継続の深さが増えない。深い非末尾再帰が Zig のスタックで止まらない(メモリの定数性は GC が入る 1g の条件)。計画は [0004-slice-1f-cek-machine.md](0004-slice-1f-cek-machine.md) | CEK機械への移行(明示的な継続)、末尾呼び出し、展開器とコアIRの最小集合、字句アドレス |
| 1g | GC が動く。100万回の末尾再帰が一定のメモリで完了する | GCヒープ、マーク・スイープ、ルート登録 |
| 1h | 文字列・ベクタ・文字が読めて書ける | リーダとプリンタの残り(ドット対 `(1 . 2)` の読み取りを含む。1c のプリンタは書けるが、リーダは `.` を読めない)、`write` と `display` の区別 |
| 1i | ブラウザで `(fact 10)` が動く | WASM のエクスポート、Web UI の最小版、ローカルで開く手段 |
| 1j | リリース v0.1.0。計画は [0009-slice-1j-release-v0-1-0.md](0009-slice-1j-release-v0-1-0.md) | ファジングのワークフロー、aarch64 の判断と ADR、PR への成果物の添付 |
| 1k | リスト・述語・整数除算のプリミティブで、手で書いた `(define (len xs) (if (null? xs) 0 (+ 1 (len (cdr xs)))))` と `(len (list 1 2 3))` が `3` を返す。計画は [0010-slices-1k-1l-primitives-and-repl-continuation.md](0010-slices-1k-1l-primitives-and-repl-continuation.md) | プリミティブの呼び出し規約(ヒープを渡し、引数の個数を表で検査する)、ペアとリスト、等価と述語、整数除算、文字・文字列・ベクタの最小の操作 |
| 1l | `(+ 1` で改行すると継続行のプロンプトが出て、次の行 `2)` で `3` が返る。`;` の行コメントが読める(最初の単位 L1 として先に入れた)。計画は 0010 | 行コメント、リーダの完結判定、REPL の継続行 |
| 1m | `zig build report` が `docs/status/conformance.md` を生成し、`zig build check-report` が生成し直した結果との一致を検査する。計画は [0011-slice-1m-conformance-report-early.md](0011-slice-1m-conformance-report-early.md) | 準拠マトリクスの最小版(`tests/r7rs-required` の識別子が束縛済みかを数える)、`Interpreter.isBound` |

1k と 1l の番号は、作った順である。実施順は 1i、1k・1l・1j-1 から 1j-3(並行)、1j-4、1j-5 とする。1m は他のスライスと独立で、どの時点でも入れてよい。リリース(1j-4、1j-5)は、段階1の全項目がそろってから出す。1k と 1l は、roadmap の段階1の作業項目のうち、1j までのどのスライスにも割り当てられていなかったもの(「プリミティブ約30個」「REPL の継続行」)を引き受ける。行コメント `;` も同じで、1l が入れる。ただし行コメントは、1l の最初の単位 L1 として切り出し、独立した小さな PR で最初にマージした。理由と選択肢は [0010](0010-slices-1k-1l-primitives-and-repl-continuation.md) にある。

1a から 1e までは素朴な再帰下降の評価器で進め、1f で CEK 機械に置き換えた。先に CEK を入れなかったのは、評価器の形を決める前に継続の形を決めると、どちらも推測で書くことになるためである。置き換えのとき、1a から 1e のテストがそのまま通ることを移行の根拠にした。例外は3つある。`tests/scheme/0009-define-forms.txt` の `(loop 1)` は止まらなくなるので外し、`(fact 100)` は深さの上限でなく `integer overflow in *` を期待する。`tests/scheme/0010-internal-define.txt` の2ケースは、本体の途中の `define` を呼び出し時でなく `lambda` の展開時に報告するので、期待する時点が変わった。

## 進捗

スライスごとの状態。スライスの PR を出すときに、この表と下の「次にやること」を同じ PR で更新し、そのスライスが完了させる [roadmap.md](../roadmap.md) の段階1の項目にチェックを入れる。会話が途切れても、リポジトリの文書だけから現状に戻れるようにするためである。

| スライス | 状態 | PR |
| --- | --- | --- |
| 1a | マージ済み | 1a 本体が #4、あわせて直した `harness.py` が #5 |
| 1b | マージ済み | 本体が #6、レビュー対応が #7 |
| 1c | マージ済み | #8 |
| 1d | マージ済み | #10 |
| 1e | マージ済み | #11 |
| 1f | マージ済み | #13(計画書 0004 は #12) |
| 1g | マージ済み。計画は [0005-slice-1g-gc-heap.md](0005-slice-1g-gc-heap.md) | 実装が #21、後半のレビュー対応が #22(計画書 0005 は #18) |
| 1h | マージ済み。計画は [0006-slice-1h-strings-chars-vectors.md](0006-slice-1h-strings-chars-vectors.md) | 計画書が [#23](https://github.com/suchi/sucheme-zig/pull/23)、実装が [#24](https://github.com/suchi/sucheme-zig/pull/24) |
| 1i | マージ済み。計画は [0008-slice-1i-wasm-web-ui.md](0008-slice-1i-wasm-web-ui.md) | 計画書が [#29](https://github.com/suchi/sucheme-zig/pull/29)、実装が [#36](https://github.com/suchi/sucheme-zig/pull/36) |
| L1 | マージ済み。1l の最初の単位(行コメント) | 実装が [#43](https://github.com/suchi/sucheme-zig/pull/43) |
| 1j | 計画は合意済み。1j-1 から 1j-3 を 1k・1l と並行して実装し、1j-4 と 1j-5 は段階1の全項目がそろってから実装する。計画は [0009-slice-1j-release-v0-1-0.md](0009-slice-1j-release-v0-1-0.md) | 計画書が [#33](https://github.com/suchi/sucheme-zig/pull/33)、実装は 1j-1 から 1j-5 の PR |
| 1k | 計画は合意済み(2026-10-11)。実装中。K0(呼び出し規約)は PR で出した。マージされたら K1 から K5 を並行して進め、K6 で統合する。計画は [0010-slices-1k-1l-primitives-and-repl-continuation.md](0010-slices-1k-1l-primitives-and-repl-continuation.md) | 計画書が [#39](https://github.com/suchi/sucheme-zig/pull/39)、K0 は [#47](https://github.com/suchi/sucheme-zig/pull/47)、K1 から K6 は各単位の PR |
| 1l | 計画は合意済み(2026-10-11)。最初の単位 L1(行コメント)は [#43](https://github.com/suchi/sucheme-zig/pull/43) でマージ済み。L2(完結判定)と L3(REPL の継続行)はこれから | 計画書が [#39](https://github.com/suchi/sucheme-zig/pull/39)、実装は L1 の PR と 1l の PR |
| 1m | マージ済み。1k・1l・1j とは独立だった。計画は [0011-slice-1m-conformance-report-early.md](0011-slice-1m-conformance-report-early.md) | 実装が [#44](https://github.com/suchi/sucheme-zig/pull/44) |

## 再開の手がかり

コードが正であり、ここには ADR にも設計文書にも無い、実装中の決定と環境の事実だけを書く。

- 実装中の決定: 読み取り、展開、実行の順に進む。展開器(`src/syntax/expand.zig`)はデータをコアIR(`value.zig` の `Node`)に変換し、変数を字句アドレス(深さと添字、u32)に解決する。作業は自前のスタックで進め、Zig の再帰は使わない。機械(`src/machine.zig`)は制御・環境・継続・値の4レジスタで、継続フレームは不変、末尾位置の印は持たない([ADR-0029](../adr/0029-no-tail-marks-in-stage-1-machine.md))。特別な形は `expand.zig` のキーワードの列挙で扱い、変数にも再定義にも代入にも仮引数にも使えない。`define` は最上位(最上位の `begin` の中を含む)と、`lambda` の本体の先頭だけ。本体の先頭の `define` の名前は展開器が集め、呼び出しのたびに仮引数と同じフレームに `.uninitialized` で作る(`letrec*`)。式のあとの `define` は、展開時に `bad define` になる。プリミティブは大域環境の束縛で、`define` で隠せる。リーダは `Value` を `Interpreter` の永続アリーナに直接作る(`quote` が定義に渡すため)。このアリーナと、シンボル表、大域環境、コアIR、フレーム、継続フレーム、条件は 1g の `heap.zig` まで回収されない。Scheme のエラーは条件オブジェクト(`Value.condition`)で、`Context.raise` が作って `error.Raised` で機械の外へ返す。ハンドラは段階2。
- 深さ: 継続の深さに上限は無い。機械が `peak_depth` で数え、テストが末尾呼び出しで増えないことを確かめる。非末尾の無限再帰はメモリを使い切るまで走るので、テストにこの形を入れない。
- テストの書式: `tests/scheme/*.txt` は、入力の行、期待する出力の行、空行の順。出力が空のケースは期待する行に `<no output>` と書く。書式は `tools/test-scheme/main.zig` の doc コメントが正。
- レビュー: スライスの PR ごとに、設計の意図を渡さないサブエージェントに `adversarial-review` を1巡させる。機械の検査を壊して確かめるときは `tools/review-harness/harness.py` を使う。
- 環境の事実: 実行環境から ziglang.org に届かないことがある。その場合は `python3 -m venv <dir> && <dir>/bin/pip install ziglang==0.17.0` で入れ、`zig` を PATH に置く(`.zigversion` と一致することを `zig version` で確かめる)。
- ブランチ: スライスごとに、作業内容が分かる名前のブランチを最新の `origin/main` から作る(1f は `feature/phase1-slice-1f-cek-machine`)。PR がマージされたら、次のスライスのブランチを新しく作る。マージ済みのブランチは、ユーザーの承認を得てから消す。

GC を 1g まで遅らせるのは、1f までのヒープ使用量が小さく、アリーナで足りるためである。ただし 1d から呼び出しごとのフレームが永続側に残り、1f で継続フレームと引数の蓄積も加わって、メモリは入力の大きさでなく呼び出しの回数に比例して増える。1f で末尾呼び出しが継続を積まなくなったが、メモリの定数性は回収が入る 1g の完了条件である。GC の正しさは、回収が必要な状況で初めて検査できる。

## この計画が決めていないこと

[design/open-questions.md](../design/open-questions.md) の「段階1までに決める」の行は、この計画では決めない。各スライスで、そのスライスが必要にした時点で決める。どのスライスでどれを決めるかは次のとおりである。

| スライス | 決める事項 |
| --- | --- |
| 1b | 内部値のうち未束縛の表現。大域環境に名前が無いことで表したので、専用の値は要らなかった。1a で決める予定だったが、1a には束縛が無く使う箇所が無いので 1b に移した |
| 1e | 内部値のうち未初期化の表現。`Value` の即値の変種 `.uninitialized` にした(ヒープオブジェクトにすると、読み取りのたびに種類の判定が要るうえ、1g で回収の対象が増える)。大域の束縛セルが入る段階2で、未束縛と合わせて再び決める |
| 1f | 字句アドレスの深さと添字のビット幅: u32 にして、超える入れ子を実装制限として報告する([ADR-0030](../adr/0030-lexical-address-width-u32.md))。フレーム数の上限: 設けない。1g の計上の上限が入るときに決め直す |
| 1g | 決めた: GC は機械のステップの境目で実行する([ADR-0031](../adr/0031-gc-at-machine-step-boundaries.md))。起動の閾値は、直前の GC のあとの計上量の倍率と最小値の大きいほうで、上限の手前で頭打ちにする。GC のあとの計上量が上限に近いときは `heap limit exceeded`。値は `src/heap.zig` の定数が正で、ベンチマークは未実施の暫定値。巻き戻しの単位は `Heap.createFrame` の1回の呼び出し(ペイロードを先に確保し、セルの確保が失敗したら返す)。作業リストの容量は `Options.work_capacity`(テストでは0)で、溢れたら全走査でマークし直す。フレーム数の上限は設けない(計上の上限が止める)。上限の既定は `Options.limit`。予約領域の具体的なバイト数は段階2に移した(1g は条件オブジェクトを上限の外のアリーナに作る) |
| 1h | 決めた: Windows の引数と環境変数は Zig 0.17.0 が WTF-8 に変換し、不対サロゲートは `utf8ValidateSlice` が拒否する([zig-api-notes.md](../design/zig-api-notes.md))。引数が Scheme の文字列になる経路は段階5の `command-line` まで無いので、検査の位置はそこで決める。Windows 実機での実行は未確認。1h で入る入力は `Interpreter.evalPrint` の先頭で検査する |
| 1i | 決めた([0008](0008-slice-1i-wasm-web-ui.md)): 出力バッファは初期化のときに 256 KiB を1回だけ確保し、伸ばさない(溢れたら `output buffer full` のエラー)。ローカルで開く手段は、依存パッケージの無い Node.js のスクリプト `web/serve.mjs`。PR の zip を開くレビュアは Node.js だけでよい(Zig もリポジトリも要らない) |
| 1j | aarch64 を自動テストの対象に加えるか |
| 1k | 決めた([0010](0010-slices-1k-1l-primitives-and-repl-continuation.md)): 呼び出し規約は、個数の範囲を `Primitive` に持たせて機械が検査し、`call` に `Services` を渡す。エラーは Zig の `error` の集合を広げ、`apply` が条件に写す。K0 の実装で足したこと: 関数の型の別名 `Primitive.Fn`(`Call` は IR の節点の名前と衝突するため)、単体テストが機械を起こさずにプリミティブを呼ぶ `src/prim/test_support.zig` |

検査ツールについての未決事項(`refAllDecls` の到達性、`test_excluded` の理由、CI が表の行を走らせる検査の範囲、フックの判定の機械検査)は、この段階では決めない。段階0の経緯から、検査ツールを育てることが製品を作ることに先立ってはならない([ADR-0026](../adr/0026-verify-facts-about-code-not-prose.md))。製品コードが育って同じ誤りが2回起きたときに決める。

## 各スライスの進め方

1. そのスライスの完了条件を満たす失敗するテストを書く(Red)。
2. 最小の実装で通す(Green)。
3. テストを通したまま整理する(Refactor)。
4. `AGENTS.md` の検証コマンドを全部通す。
5. PR を作り、敵対的レビューを1巡かける。重要度は [ADR-0027](../adr/0027-severity-by-consequence-and-a-cost-side-stop.md) の帯で採点する。
6. 必須が帰結(1)(2)(3)に当たらなくなったらマージを依頼する。
7. 同じ PR で、この計画書の進捗の表と「次にやること」、スライスで決めたことの表を更新する。

レビューの対象はそのスライスの差分に限る。既存の文書の全面再走査はしない。段階の終わりに1回、計画書と帳簿を見る([ADR-0027](../adr/0027-severity-by-consequence-and-a-cost-side-stop.md))。

## 検証コマンドの追加

段階1で `AGENTS.md` の検証コマンド表に次の行が必要になる。追加は、その行が指すものが実在するスライスで行う。

| コマンド | スライス |
| --- | --- |
| `zig build test-scheme` | 1a(Scheme の振る舞いのテストが最初に要るところ) |
| `zig build wasm` | 1i(戻した) |
| `zig build test-wasm` | 1i(戻した) |
| `zig build report` | 1m(準拠マトリクスの最小版が入るところ。突き合わせる `lib/` を待たず、`tests/r7rs-required` の識別子が束縛済みかをインタプリタに尋ねる。1e で計画していたが、`lib/` が無く全部未実装になるため段階3へ延期し、1m で最小の形に絞って前倒しした) |
| `zig build check-report` | 1m |

1a で `build.zig` の `current_stage` を1に上げたので、段階1の全コミットの行は `zig build check-docs` が CI に要求する。そのため 1a の時点で表にあった `wasm`・`test-wasm`・`report`・`check-report` の4行をいったん外した。上の表のスライスで戻す。`report` と `check-report` は 1m で戻す。

戻す行の意味は次のとおり。`zig build test-wasm` は Node.js 上でエクスポートを呼び出す往復テストである([ADR-0010](../adr/0010-ci-cd-and-release-strategy.md))。`zig build check-report` は準拠マトリクスを生成し直して現在のファイルと一致するかを検査する([design/r7rs-coverage.md](../design/r7rs-coverage.md))。`zig build report` は生成するだけで一致を検査しない。

`.github/workflows/ci.yml` の変更を伴うので、各スライスでユーザーの承認を得てから行う([AGENTS.md](../../AGENTS.md) のセキュリティの節)。

## 次にやること

スライス 1h(文字・文字列・ベクタ、ドット対)は PR #24 で `main` に入っている。テストの層([0007](0007-test-tiers.md))は PR #25 から #28 で入っている(`full.yml` は #28)。

1. スライス 1k(プリミティブ)の K0(呼び出し規約の変更)は、PR で出した。マージされたら、K1 から K5 を別々のワークツリーで並行に進める([0010](0010-slices-1k-1l-primitives-and-repl-continuation.md) の「並行できる単位」)。K1 から K5 は K0 の API(`Primitive` の `min_args` と `max_args`、`call` が受け取る `Services`、`src/prim/table.zig` の `families` に足す1行)を使う。
2. 1l の残り(L2、L3)と、1j-1(ファジング)から 1j-3 は、K0 と並行して進めてよい。1j-4 と 1j-5 は、段階1の全項目(1k と 1l を含む)がそろってから出す。計画は [0009](0009-slice-1j-release-v0-1-0.md) と 0010。
3. `build.zig` などのコメントの日本語化の残りは [Issue #30](https://github.com/suchi/sucheme-zig/issues/30) の PR で進めている。スライス 1i は [#36](https://github.com/suchi/sucheme-zig/pull/36) で `main` に入っている。
4. 1g で残したこと: シンボル表は弱い表にしていない(回収されない)。コードの節点と `Lambda` はヒープの外にある(コードをヒープに移すスライスで、コードの定数の登録表 `Context.code_roots` も要らなくなる)。条件オブジェクトはヒープの外にある(段階2)。1ステップで大きく確保するプリミティブが入るとき、境目だけの GC の方針を見直す([ADR-0031](../adr/0031-gc-at-machine-step-boundaries.md))。1k は、大きさを数で決める生成(`make-vector` など)を入れないので、見直さない。見直しは、それらが入る段階3の最初のスライスで行う([0010](0010-slices-1k-1l-primitives-and-repl-continuation.md))。
5. スライス 1m(準拠マトリクスの最小版、[#44](https://github.com/suchi/sucheme-zig/pull/44))は `main` に入っている。計画は [0011](0011-slice-1m-conformance-report-early.md)。束縛を増やす PR(1k の K1 以降を含む)は、`zig build report` を実行して `docs/status/conformance.md` を更新する。

1f で意図して残したこと: 本体の途中の `define` の構文エラーは展開時、継続の深さの上限は無い、条件は `error.Raised` の脱出でハンドラは無い。
