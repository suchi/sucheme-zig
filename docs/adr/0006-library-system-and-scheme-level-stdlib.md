# ADR-0006: 標準ライブラリは可能な限り Scheme で書く

- ステータス: 採用
- 日付: 2026-10-04

## 背景

要件として「コア言語で表現できるものはコア Scheme スクリプトで実現する」という方針が与えられている。一方、R7RS のライブラリシステム(`define-library` `import` `export` `cond-expand` `include`)は言語の読み込み機構そのものであり、Zig 側に置かざるをえない部分がある。

どこに境界を引くかを決める必要があった。

## 決定

Zig で書くのは次に限る。

- コアの特殊形式(`quote` `if` `lambda` `set!` `define` `begin`)と、それらのコアIRへの変換
- 構文定義(`define-syntax` `let-syntax` `letrec-syntax`)。構文環境にマクロ束縛を追加する操作はテンプレートで表せない
- `syntax-rules` の照合器とテンプレート展開器
- ライブラリシステム(`define-library` `import` `export` `cond-expand` `include` `include-ci` `include-library-declarations`)
- リーダとプリンタ。`#!fold-case` 指令とポートごとのケースフォールディング状態を含む
- 基本操作のプリミティブ(`cons` `car` `cdr` `set-car!` など、算術の核、文字列とベクタの基本操作、ポートの入出力)
- 機械操作プリミティブ(`apply` `call/cc` `call-with-values` `values` `dynamic-wind` `with-exception-handler` `raise` `raise-continuable` `make-parameter` `eval`)
- `parameterize`。`Parameter` を `Value` の独立した変種として動的点に直接結びつける表現を採ったため。R7RS 7.3 の参考実装は `syntax-rules` で書けているが、パラメータオブジェクトを Scheme のクロージャとして作り私的なマーカーを引数に渡す形を前提としており、本処理系の表現では使えない
- Unicode のテーブルと数値の表示・解析

これ以外は Scheme で書く。`map` と `for-each` も Scheme で書く。Scheme で書けば末尾呼び出しと継続の相互作用が自動的に正しくなるためである。

起動順序は次のとおり。Zig が内部用の `(sucheme core)` を登録し、埋め込んだ `lib/sucheme/derived.scm` が派生構文を定義し、その上に `lib/scheme/base.sld` が `(scheme base)` を構成する。`(sucheme core)` は利用者に公開しない。

`import` はグローバル束縛セルを共有する。値をコピーしないため、エクスポート元での再定義がインポート側に反映される。

Scheme のソースはビルド時に実行ファイルへ埋め込む。`build.zig` が `lib/` 以下をパス名順に走査して `@embedFile` の索引を生成する。ネイティブと WASM で同じ仕組みを使う。

## 結果

- メリット: Zig 側のコード量が小さく保たれ、検証すべき範囲が狭まる。Scheme で書いた部分は仕様の記述に近く、読んで正しさを判断しやすい。WASM でもファイルシステムなしに標準ライブラリが使える。
- デメリット・受け入れたトレードオフ: Scheme で書いた手続きは Zig 実装より遅い。起動時に埋め込んだ Scheme を展開する時間がかかる。成果物のサイズが増える。
- 将来の見直し条件: 起動時間または特定手続きの性能が問題になった場合、個別に Zig 側へ移す。その場合も、プリミティブの中で機械を起動しないという不変条件([ADR-0004](0004-cek-machine-evaluator.md))を守る形で実装する。移行は性能測定の結果を根拠として行う。
