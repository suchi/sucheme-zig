# 用語集

文書で使う語のうち、英語との対応が自明でないものを示す。一般の技術文書で別の語が使われる概念には、本文でその一般の語を使う(下の「置き換えた語」)。ここにある語は、意味を保つために置き換えていない。

## 置き換えていない語

| 語 | 英語 | 意味 | 初出 |
| --- | --- | --- | --- |
| 機械 | machine | 評価を1歩ずつ進める CEK 機械。`machine.zig` のステップ関数が状態を進める | [architecture.md](design/architecture.md) |
| 節点 | node | コア IR の木の要素。変数参照、関数適用、`lambda` などの1つ1つ | [runtime.md](design/runtime.md) |
| 展開器 | expander | データを構文環境のもとで解析し、マクロを展開しながらコア IR に変換する段 | [frontend.md](design/frontend.md) |
| 計上 | accounting | ヒープの上限に対して、確保したメモリの量を数えること | [runtime.md](design/runtime.md) |
| 歩数 | step count | 機械のステップ関数を呼んだ回数。上限に達すると制御を戻す | [0024](plans/0024-step-limit-for-the-conformance-run.md) |
| 副表 | side table | 値そのものでなく、別の表に持つ付随情報(たとえばペアごとの読み取り位置) | [frontend.md](design/frontend.md) |
| 動的点 | dynamic point | `dynamic-wind` の入口と出口の組を並べた列の1要素 | [runtime.md](design/runtime.md) |
| 周回 | iteration of the apply loop | 機械の apply ループの1回分。カウンタが最大値から0に戻る意味の周回とは別 | [runtime.md](design/runtime.md) |
| 常駐 | resident | セッションが終わるまで回収されずに残るもの | [runtime.md](design/runtime.md) |
| 巡 | review round | 敵対的レビューの1回分 | [AGENTS.md](../AGENTS.md) |
| 勧める案 | recommended option | 判断を求めるとき、先に示す推奨の案 | [handoff.md](handoff.md) |
| 合意を求める点 | points for agreement | 計画書で、ユーザーの判断が要る点の一覧 | [0017](plans/0017-parallel-lanes.md) |
| 規模を試す | scale test | 深さ・個数・上限に比例して壊れる種類の誤りを見るテスト。`-Dslow=true` で走る | [0007](plans/0007-test-tiers.md) |
| 帰結 | consequence | レビューの指摘の重要度を決める基準。指摘が放置されたときに起きることで決める | [AGENTS.md](../AGENTS.md) |

## 置き換えた語

日本の技術文書で一般的な語に合わせた。新しく書くときも、右の語を使う。

| 概念 | 英語 | 使う語 | 以前の語 |
| --- | --- | --- | --- |
| マージで起きる食い違い | merge conflict | コンフリクト | 衝突 |
| トップレベルの式や定義 | top level | トップレベル | 最上位 |
| `#!fold-case` など | directive | ディレクティブ | 指令 |
| 準拠スイートを走らせるツール | runner | ランナー | 実行器 |
| CI の1回の実行 | (workflow) run | 実行 | ラン |
| GC の作業用の待ち行列 | work list | ワークリスト | 作業リスト |
| 所有する側 | owner | 所有者 | 持ち主 |
| 共用体の取りうる型 | variant | バリアント | 変種 |
| 容量を超えること | overflow | あふれ | 溢れ |
| 記録の台帳 | ledger | 台帳 | 帳簿 |
| 往復して元に戻る性質 | round trip | ラウンドトリップ | 往復 |
| 文章(コードや表でないもの) | prose | 文章 | 散文 |
| 別名(alias)を元の形に戻すこと | strip | 剥ぎ取り | 剥離 |
| 同名の束縛を覆うこと | shadowing | 隠蔽 | 遮蔽 |
| `dynamic-wind` などの範囲 | dynamic extent | 動的エクステント | 動的範囲 |
| 後で置き換える仮の値 | placeholder | プレースホルダ | 目印 |
| 字句を切り出す部品 | scanner | スキャナ | 走査器 |
| コードや表を作るツール | generator (tool) | 生成ツール | 生成器 |
| 呼び出しを繰り返し再開できる継続 | first-class continuation | 第一級継続 | 完全な継続 |
| 名前と実体の対応表 | registry | レジストリ | 登録表 |
| ルートを正確に把握する GC | precise (exact) GC | 正確な GC | 精密 GC |
| 順番に1つずつ進めること | sequential | 逐次 | 直列 |
| 人手でなく自動で行う検査 | automated check | 自動検査 | 機械検査 |
| 変更をレビューする人 | reviewer | レビュー担当者 | レビュア |
| 多倍長整数の桁の配列 | limbs | limbs | 限界値列 |

Scheme のジェネレータ(繰り返し値を返す手続き)は、生成ツールでなく「ジェネレータ」と書く。

## 表記

- 長音: 文書内で多数派の表記にそろえる(スカラ、トリガ)。
- `docs/adr/`、`docs/review/`、`docs/releases/`、`docs/spec/` は、記録としての性質があるので、以前の語のまま残している。
- コードのコメントが見出し名で参照しているため、次の2つの見出しは以前の語のまま残している。`docs/design/runtime.md` の「動的範囲の通常終了」(`src/machine.zig` と `src/value.zig` のコメントが参照する)と、`docs/plans/0020-conformance-harness-early.md` の「実行器の設計」(`tools/conformance-run/` のコメントが参照する)。本文中のこれらの見出しへの参照も合わせている。
- `docs/status/conformance.md` は、`tools/coverage-report` が出力する生成物なので、「最上位」が残っている。出力の文言を直す変更で、生成し直す。
