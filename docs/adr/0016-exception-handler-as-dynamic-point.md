# ADR-0016: 例外ハンドラの切り替えを動的状態の点として表す

- ステータス: 採用
- 日付: 2026-10-04

## 背景

[ADR-0004](0004-cek-machine-evaluator.md) では、`dynamic-wind`、`with-exception-handler`、`parameterize` の3つを1本の不変リスト(`DynPoint` の列)で統一して表すことにした。継続の起動時は現在の点と目標の点の共通祖先を求め、`after` と `before` を呼びながら遷移する。

PR #1 のレビューで、この表現のままでは R7RS 6.11 の例外ハンドラの規定を満たせないことが判明した。誤記修正版 R7RS 6.11 の `raise` の規定は次のとおりである。

> The handler is called with the same dynamic environment as that of the call to raise, except that the current exception handler is the one that was in place when the handler being called was installed. If the handler returns, a secondary exception is raised in the same dynamic environment as the handler.

`raise-continuable` も同様で、加えて「if the handler being called returns, then it will again become the current exception handler」が規定されている。

変わるのは現在の例外ハンドラだけであり、動的環境の残りは `raise` を呼んだ時点のままでなければならない。リストの位置を外側へ戻す方式では、ハンドラのインストールより内側で有効になった `parameterize` の束縛や `dynamic-wind` の範囲までハンドラから見えなくなる。

## 検討と棄却した案

この決定に至るまでに2つの案を採って、いずれもレビューで反例を示された。経緯を残す。

第1案は、現在のハンドラの位置を指すカーソルを機械の独立したレジスタとして持ち、巻き戻し中はそのカーソルを現在の `dynamic_point` の最内ハンドラから導出する方式である。反例は、ハンドラの中で `dynamic-wind` に入り、そこから継続で脱出する場合である。導出すると `after` を呼ぶ前に実行中のハンドラへ戻してしまい、`after` の中の例外が同じハンドラに再入する。通常終了の経路では外側のハンドラが見えるため、2つの経路で振る舞いが食い違う。

第2案は、各点が生成時のカーソル値を保持し、退出時にその値を復元する方式である。反例は、`raise` を囲む `dynamic-wind` からハンドラが継続で脱出する場合である。その点の生成時のカーソルは呼ばれるハンドラ自身を指すが、ハンドラ実行中の現在値は外側に切り替わっている。生成時の値へ戻すと、やはり `after` の中の例外が実行中のハンドラへ再入する。また継続で再入する場合、生成時の外側の文脈と再入時の外側の文脈でカーソルが異なるため、生成時の値は正しい復元値にならない。

2つの失敗の原因は同じである。現在のハンドラという状態について、レジスタと点の列という2つの真実の源を持ち、両者を同期させようとしたことである。同期の規則を精密にするほど反例が別の形で現れた。

## 決定

現在の例外ハンドラを独立したレジスタにしない。`dynamic_point` だけを真実の源とし、ハンドラの切り替えもこの列の中の点として表す。

`DynPoint` の種別に `handler_shift` を追加する。この点は「現在のハンドラを、指定した `handler` 点のものに切り替える」ことだけを表す。

```zig
kind: union(enum) {
    wind: struct { before: Value, after: Value },
    handler: Value,              // この点より内側で現在のハンドラになる
    handler_shift: ?*DynPoint,   // 現在のハンドラをこの handler 点に切り替える
    parameter: struct { param: *Parameter, value: Value },
},
```

各点は生成時に `current_handler` を決め、以後変えない。

| 点の種別 | `current_handler` |
| --- | --- |
| `handler` | その点自身 |
| `handler_shift` | 切り替え先の `handler` 点(`null` もありうる) |
| `wind` と `parameter` | 親の `current_handler` |

これにより、ある動的点における現在の例外ハンドラが定数時間に求まる。参照は `currentHandler(p)` という補助関数を通す。`dynamic_point` は起動直後は `null` であり、省略可能型を直接展開するとその状態での `raise` が panic する。`null` のときは `null` を返し、`raise` 側が未処理例外として扱う。

`raise` と `raise-continuable` は、外側へ戻るのではなく内側へ1点積む。`H = currentHandler(dynamic_point)` を求め、切り替え先を `H.parent` に対する `currentHandler`(すなわち `H` をインストールした時点で現在だったハンドラ)とする `handler_shift` 点を積んでから、`H` のハンドラ手続きを呼ぶ。`H` が `null` の場合は未処理例外として扱う。`dynamic_point` は `raise` 時点のものに1点足しただけなので、`parameterize` の束縛も `dynamic-wind` の範囲も失われない。

`raise-continuable` のハンドラが戻ったら、積んだ `handler_shift` 点を外す。これが規定の「it will again become the current exception handler」に対応する。

継続の起動時は、`handler_shift` 点も列の一部なので巻き戻しの経路に含まれ、正しい順序で退出する。現在のハンドラについて追加の同期は不要である。

## 結果

- メリット: 真実の源が1つなので、2つの状態が食い違う種類の誤りが起こりえない。棄却した2案の反例はいずれも成立しなくなる。機械のレジスタが増えないため [ADR-0004](0004-cek-machine-evaluator.md) の「制御・環境・継続・直前の値の4レジスタと動的状態のリスト」という状態の定義がそのまま維持され、[ADR-0003](0003-precise-mark-sweep-gc.md) のルート集合も変わらない。`Continuation` が保存するのも `kont` と `dynamic_point` だけで済む。動的状態の機構が1つという ADR-0004 の利点も保たれる。
- デメリット・受け入れたトレードオフ: `raise` のたびに `handler_shift` 点を1つ確保する。例外が多いプログラムでは確保回数が増える。`DynPoint` の種別が4つになり、`current_handler` のフィールド分だけ大きくなる。`handler_shift` という実装都合の点が動的環境の列に現れるため、列をそのまま人に見せるとやや分かりにくい。
- 将来の見直し条件: `raise` ごとの確保が性能上の問題になった場合、`handler_shift` 点の再利用または `handler` 点への情報の畳み込みを検討する。いずれも `dynamic_point` を唯一の真実の源とする性質を壊さない範囲で行う。性質そのものを変える場合は本ADRを非推奨にして新ADRを書く。

## 検証

検証項目は [runtime.md](../design/runtime.md) の例外の節に置く。件数も項目も本ADRには複製しない。同じ一覧を2箇所に持つと、項目を追加するたびにずれる。

棄却した2案は、その一覧のうち「ハンドラの中の `dynamic-wind` から継続で脱出したとき」と「`raise` を囲む `dynamic-wind` からハンドラが脱出したとき」のいずれかで落ちる。
