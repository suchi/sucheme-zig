# ADR-0016: 例外ハンドラの位置を独立したレジスタとして持つ

- ステータス: 採用
- 日付: 2026-10-04
- 補足対象: [ADR-0003](0003-precise-mark-sweep-gc.md) のルート集合の列挙と、[ADR-0004](0004-cek-machine-evaluator.md) のレジスタの列挙を本ADRが訂正する。両ADRの決定本体(非移動型の精密マーク・スイープGC、明示的な継続を持つCEK機械)は有効である。

## 背景

[ADR-0004](0004-cek-machine-evaluator.md) は機械の状態を「制御、環境、継続、直前の値の4レジスタと、動的状態のリスト」と列挙した。動的状態は `dynamic-wind`、`with-exception-handler`、`parameterize` の3つを1本の不変リスト(`DynPoint` の列)で統一して表す設計である。

PR #1 のレビューで、この表現では R7RS 6.11 の例外ハンドラの規定を満たせないことが判明した。誤記修正版 R7RS 6.11 の `raise` の規定は次のとおりである。

> The handler is called with the same dynamic environment as that of the call to raise, except that the current exception handler is the one that was in place when the handler being called was installed. If the handler returns, a secondary exception is raised in the same dynamic environment as the handler.

`raise-continuable` も同様で、加えて「if the handler being called returns, then it will again become the current exception handler」が規定されている。

つまりハンドラを呼ぶときに変わるのは現在の例外ハンドラだけであり、動的環境の残りは `raise` を呼んだ時点のままでなければならない。1本のリストでリストの先頭位置だけを動かす方式では、ハンドラのインストールより内側で有効になった `parameterize` の束縛や `dynamic-wind` の範囲までハンドラから見えなくなる。「ハンドラだけを切り替える」という操作が、1本のリスト上のポインタ移動では表現できない。

検討した選択肢は次の3つである。

- ハンドラ鎖を動的状態のリストから完全に分離し、別のリストとして持つ。規定どおりの操作が直接書ける。一方、`call/cc` との相互作用を2つの機構で別々に正しくする必要があり、ADR-0004 で「1箇所で正しくすれば全体が正しくなる」としていた利点を失う。
- 1本のリストのまま、ハンドラの位置を指すカーソルを独立したレジスタとして追加する。リストは `dynamic-wind` と `parameterize` のために統一されたまま、ハンドラの位置だけが独立に動く。
- ハンドラをリストに入れず、`with-exception-handler` を `parameterize` の上に Scheme で実装する。R7RS の規定を満たすには結局「現在のハンドラ」を他の動的束縛と独立に切り替える必要があり、問題が移動するだけである。

## 決定

1本の `DynPoint` のリストを維持したまま、「現在の例外ハンドラ」の位置を指す `handler_cursor` を機械の独立したレジスタとして追加する。機械のレジスタは、制御、環境、継続、直前の値、動的状態のリスト、ハンドラの位置となる。

- 種別によらず全ての `DynPoint` が `outer_handler_cursor` を持つ。その点を積む直前の `handler_cursor` の値であり、生成時に決まって以後変わらない。
- `handler` 種別の点では、この値が R7RS の「the one that was in place when the handler being called was installed」そのものである。`raise` と `raise-continuable` は `dynamic_point` を変えず、`handler_cursor` をこの値に差し替えてハンドラを呼ぶ。
- `raise-continuable` のハンドラが戻った場合はカーソルを元の点に戻す。
- `wind` 種別の点では、この値がその `dynamic-wind` に入った時点のカーソルであり、`after` を呼ぶときに復元すべき値である。`parameter` 種別の点では、`parameterize` がカーソルを変えないため外側の値と一致する。
- 退出するときは `outer_handler_cursor` を復元し、進入するときは `handler` 種別なら点自身、それ以外は `outer_handler_cursor` にする。この規則を通常実行と継続起動時の巻き戻しの両方で使う。
- カーソルを現在の `dynamic_point` から導出してはならない。導出すると、ハンドラ実行中にカーソルが最内ハンドラと一致しない状態が失われる。ハンドラの中の `dynamic-wind` から継続で脱出した場合、通常終了なら `after` は外側のカーソルのもとで走るのに、導出すると実行中のハンドラへ戻してしまい、`after` の中の例外が同じハンドラに再入する。
- 遷移の完了時は、継続に保存した `target_handler_cursor` を復元する。ハンドラ実行中に捕捉された継続では、点から導出できる値と一致しないためである。

`Continuation` は `kont` と `dynamic_point` に加えて `handler_cursor` を保存する。GC のルート集合に `handler_cursor` を加える。これが [ADR-0003](0003-precise-mark-sweep-gc.md) のルート集合の列挙に対する訂正である。

## 結果

- メリット: R7RS 6.11 の規定を正確に満たせる。`dynamic-wind` と `parameterize` については1本のリストによる統一が保たれ、共通祖先の計算も1箇所で済む。`outer_handler_cursor` が不変なので、通常実行と巻き戻しでカーソルの復元規則が同一になり、定数時間で行える。
- デメリット・受け入れたトレードオフ: レジスタが1つ増え、`call/cc`、巻き戻し、動的範囲の通常終了のすべてで保存と復元の対象が2つになる。ADR-0004 で挙げた「動的状態の機構が1つ」という利点が部分的に失われる。`DynPoint` が `outer_handler_cursor` のフィールド分だけ大きくなる。
- 将来の見直し条件: ハンドラ鎖を完全に分離したほうが実装が読みやすいと判明した場合に再検討する。その場合は本ADRを非推奨にして新ADRを書く。

## 補足対象の扱いについて

本ADRは新しい決定として記録し、[ADR-0003](0003-precise-mark-sweep-gc.md) と [ADR-0004](0004-cek-machine-evaluator.md) の本文は編集していない。[README.md](README.md) の運用ルールが採用済みADRの決定内容の書き換えを禁じているためである。

両ADRの決定本体は変わっておらず、変わったのは支持する詳細の列挙だけであるため、非推奨化ではなく訂正の明示という形を採った。レジスタ集合とルート集合について両ADRと本ADRの記述が異なる場合は、本ADRが優先する。一覧にもその関係を記した。

より厳密に、両ADRを非推奨にして決定本体ごと書き直す運用に改める場合は、その判断自体をADRとして記録する。
