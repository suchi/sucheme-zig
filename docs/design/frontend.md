# フロントエンド設計

リーダ、構文環境、衛生的マクロ展開器、`syntax-rules`、ライブラリシステム、標準ライブラリの起動順序についての決定。全体整合性に必要な範囲まで詳細を決め、それ以外は実装時に決める([ADR-0018](../adr/0018-incremental-vertical-slices.md))。実装時に決めるものは [open-questions.md](open-questions.md) に一覧がある。

対応する決定: [ADR-0005](../adr/0005-hygienic-expander-by-renaming.md)、[ADR-0006](../adr/0006-library-system-and-scheme-level-stdlib.md)。

## リーダ

外部表現を読んでデータを構築する。R7RS 7.1.2 の形式文法に対応させる。

| 分類 | 対応する記法 |
| --- | --- |
| コメント | `;` 行末まで、`#|` と `|#` の入れ子可能なブロック、`#;` によるデータ単位のコメント |
| 真偽値 | `#t` `#true` `#f` `#false` |
| 数値 | 基数接頭辞 `#b` `#o` `#d` `#x`、正確性接頭辞 `#e` `#i`、分数、小数、指数、`+inf.0` `-inf.0` `+nan.0` `-nan.0`、複素数 |
| 文字 | `#\a`、名前付き文字9種(`alarm` `backspace` `delete` `escape` `newline` `null` `return` `space` `tab`)、`#\x` に続く16進 |
| 文字列 | `\a \b \t \n \r \" \\ \|`、`\x` に続く16進とセミコロン、行継続 |
| 識別子 | 通常の識別子、特殊初期文字、`|` で囲んだ記法 |
| リスト | `(...)`、`[...]` は使わない、ドット対 |
| ベクタ | `#(...)` |
| バイトベクタ | `#u8(...)` |
| 略記 | `'` `` ` `` `,` `,@` |
| データラベル | `#0=` と `#0#` による循環構造 |
| 指令 | `#!fold-case` と `#!no-fold-case` |

識別子の大文字と小文字は区別する(R7RS 2.1)。

文字列のエスケープに `\|` を含めるのは R7RS 7.1.1 の `<string element>` の生成規則に従うためである。同規則は `<mnemonic escape>` と `\"` と `\\` と `\|` を列挙している。字面が縦棒識別子の記法と重なるが、文字列の要素としても規定されている。

名前付き文字は R7RS 7.1.1 の `<character name>` の生成規則どおり9種である。1つでも落とすと準拠しない。

### ケースフォールディング

リーダはポートごとに「識別子と文字名を畳み込むか」の状態を持つ。既定は畳み込まない。

`#!fold-case` と `#!no-fold-case` はこの状態を切り替える指令である。R7RS 2.1 の原文は次のとおり。

> The #!fold-case directive causes subsequent identifiers and character names to be case-folded as if by string-foldcase (see section 6.7). It has no effect on character literals. The #!no-fold-case directive causes a return to the default, non-folding behavior.

畳み込まれないのは文字リテラル(`#\A`)である。文字名(`#\NEWLINE`)は畳み込まれるので、`#!fold-case` のもとでは `#\NEWLINE` が `#\newline` と同じ改行文字になる。文字列と数値も影響を受けない。畳み込みには `string-foldcase` と同じケースフォールディングを使う([numerics-and-unicode.md](numerics-and-unicode.md))。

R7RS 7.1.1 は `<directive>` を `<atmosphere>` の構成要素として定義し、2.1 は「These directives can appear anywhere comments are permitted ... They are treated as comments, except that they affect the reading of subsequent data from the same port」と規定している。コメントが書ける場所すべてに現れうる。

指令の直後には区切りが必要である。R7RS 7.1.1 の注が「it is ungrammatical to follow a ⟨directive⟩ with anything but a ⟨delimiter⟩ or the end of file」としているため、`#!fold-casex` を指令と識別子 `x` の並びとして受理してはならない。読み取りエラーにする。

`include-ci` はこの機構の上に実装する。R7RS 4.1.7 が「include-ci reads each file as if it began with the #!fold-case directive」と規定しているため、対象ファイルを読むポートの初期状態を畳み込む側にするだけで実現できる。

### 段階ごとの実装範囲

| 段階 | 追加する記法 |
| --- | --- |
| 1 | 行コメント、真偽値、10進の整数、識別子、文字列の基本エスケープ、リスト、ベクタ、`'` の略記 |
| 2 | ポートごとのケースフォールディング状態と `include-ci`。指令そのものは段階5 |
| 3 | `` ` `` `,` `,@` の略記、文字リテラル(`#\a` と名前付き文字) |
| 4 | 基数接頭辞、正確性接頭辞、分数、小数、指数、`+inf.0` 系、複素数 |
| 5 | ブロックコメント、`#;`、データラベル、縦棒で囲んだ識別子、`#u8`、16進エスケープ、`#!fold-case` 指令 |

段階3に `` ` `` と `,` と `,@` を置くのは、段階3で `quasiquote` を `syntax-rules` で定義するためである。略記が読めないと `` `(1 ,x) `` を含むテストが書けない。

ケースフォールディングの状態を段階2に置くのは、ライブラリシステムが `include-ci` を提供する段階と合わせるためである。機構がないまま `include-ci` を提供すると `include` に退化し、畳み込みを期待したファイルが未束縛識別子のエラーになる。指令そのもの(入力の途中で切り替える機能)は段階5で足す。

未対応の記法は「段階Nで対応予定」と明示したエラーを返し、黙って誤読しないようにする。

### 位置情報

エラーメッセージのために、ポートから読んだ各ペアの行と桁を副表に記録する。

この副表は1つのトップレベルフォームを読んでから展開し終えるまでの作業表である。その間はルートとして登録し、展開が終わったら破棄する。実行時にも位置が必要なものは、展開器がコアIR節点に複製する([runtime.md](runtime.md))。

永続的な副表にすると、ルートとして扱えば REPL が読んだデータを恒久的に生存させ、扱わなければ回収後に鍵のアドレスが再利用されて無関係な位置を指す。どちらも避ける。

マクロ展開後は対応が失われるので、展開器は展開元のフォームの位置を引き継ぐ努力をするが、完全性は求めない。

### 逐次読み取り

REPL は「入力が完結したか」を知る必要がある。リーダは不足を表す専用の結果を返し、REPL はそれを見て継続行を促す。括弧の数を数える方式では、文字列やブロックコメントの中の括弧で誤判定するため採用しない。

## 構文環境と識別子

展開器の中心となるデータは構文環境である。構文環境は識別子から意味への写像である。衛生性の全体が依存するため、保持する状態は設計時に決める。

意味の種類は5つである。特殊形式、マクロ(変換子とその定義環境)、局所束縛、グローバルセル、パターン変数(`syntax-rules` の展開中のみ)。

| 保持するもの | 内容 |
| --- | --- |
| 構文環境 | 親へのリンク、この環境の rib の絶対深さ、束縛の配列 |
| 束縛 | 識別子、意味、インポートしたものかどうかの印 |
| 識別子 | 素のシンボルか別名のどちらか |
| 別名 | 内側の識別子、解決すべき環境(マクロの定義環境)、同一展開を区別する印 |
| 局所束縛 | この束縛を導入した rib の絶対深さ、rib 内の位置 |

局所束縛を深さと添字の組ではなく独立したオブジェクトにするのは、深さが利用側からの相対値なので別々の字句環境にある無関係な束縛が同じ組になりうるためである。意味の同一性をその組で判定すると、同名だが別束縛の識別子を同じ意味と誤判定し、`syntax-rules` のリテラル照合が壊れる。同一性はオブジェクトの同一性で判定する。

別名の内側の識別子がシンボルではなく識別子であることが重要である。入れ子になったマクロ展開では別名が別名を包むため、1段ずつ剥がせる構造でなければ解決規則が停止しない(後述)。元の名前は内側を最内まで辿って得る。

インポートしたものかどうかの印を意味の中ではなく束縛に置くのは、インポートできるのが変数だけではないためである。`(scheme base)` は `if` や `lambda` や `quote` のような特殊形式も、`when` や `cond` のようなマクロもエクスポートする。意味の種類に関わらず所有関係を表せる位置に置く。

rib を持たない構文環境(`let-syntax`、`letrec-syntax`、`define-syntax` が作る環境、パターン変数を束縛する環境)の絶対深さは親と同じ値にする。深さを増やすと、その環境の内側から外側の変数を参照したときの相対深さが1大きくなり、存在しない親の rib をたどる。

### 解決規則

```
resolve(id, env):
    e = env
    while e != null:
        if e に id と同一性が一致する束縛がある: return その意味
        e = e.parent
    if id が別名である: return resolve(id.inner, id.env)   // 1段剥がして委譲する
    return グローバル環境で id の名前を引く
```

委譲するのは別名自身ではなく内側の識別子である。マクロが導入した別名は定義環境に束縛を持たないのが通常であり、別名のまま委譲すると同じ分岐に戻って停止しない。内側を渡せば1回の委譲で別名の層が1つ減るため、有限回で素のシンボルに到達して必ず停止する。マクロが導入した `if` のような自由な参照は、この経路で定義環境の意味に解決される。

同一性の一致は、素のシンボルなら名前の一致、別名なら内側の同一性と印と環境の一致とする。これが衛生性の要になる。

- マクロが導入した識別子は印が利用側のものと異なるため、利用側の同名の束縛に捕捉されない。
- マクロが導入した識別子が利用側で束縛されなかった場合、定義環境で解決されるため定義時の意味を保つ(参照透明性)。
- マクロが導入した束縛構文が束縛するのは別名そのものなので、本体中の同じ別名だけがその束縛を見る。

### 識別子の比較

- `free-identifier=?` に相当する比較: それぞれの環境での意味が同一なら等しい。どちらも未束縛なら元のシンボル名が等しければ等しい。`syntax-rules` のリテラル照合はこの比較を使う(R7RS 4.3.2)。利用側が `else` を再束縛している場合にリテラル `else` が照合しなくなるという規定が満たされる。
- `bound-identifier=?` に相当する比較: 名前と印と環境が一致する場合のみ等しい。`lambda` の引数リストの重複検査などに使う。

### quote による剥離

`quote` の中に現れた別名は、コアIRの定数にする時点で元のシンボルに戻す。マクロが導入した識別子を `quote` した結果は元の名前のシンボルでなければならない。

剥離は単純な再帰走査にしてはならない。データラベル(R7RS 2.4)で作った循環データを `quote` できるため、再帰では停止しない。また共有構造を複製すると `eq?` で観測できる同一性が変わる。

訪問済みオブジェクトの対応表を使うグラフ走査とする。

1. 第1走査で別名を含む部分グラフがあるかを調べる。含まなければ元のオブジェクトをそのまま定数にする。複製しないので同一性が保たれ、よくある場合の費用もかからない。
2. 含む場合は、オブジェクトの同一性をキーにした対応表で写しを作る。ペアやベクタは先に中身を未確定で確保して対応表に登録し、そのうえで要素を埋める。これにより循環を同じ形で再現できる。
3. 同じオブジェクトに2回到達したら対応表の値を返す。共有が共有として保たれる。
4. 対応表は走査中の作業領域である。GC のルートとして登録し、計上の対象に含める。

## 展開器

```mermaid
flowchart TB
    form[フォーム] --> head{先頭の意味}
    head -->|特殊形式| core[コアIRに変換]
    head -->|マクロ| expand[変換子を適用して再展開]
    head -->|局所 / グローバル / 非識別子| call[呼び出しに変換]
    expand --> form
    core --> out[コアIR]
    call --> out
```

展開器はフォームと構文環境を受け取り、コアIRを返す。マクロ適用のたびに新しい印を割り当てる。

| 構文 | 扱い |
| --- | --- |
| `quote` `if` `lambda` `set!` `define` `begin` `parameterize` | コアIRに直接変換する。`parameterize` が節点である理由は [runtime.md](runtime.md) のコアIRにある |
| `define-syntax` `let-syntax` `letrec-syntax` | 構文環境にマクロ束縛を追加し、コアIRには何も出さない |
| `syntax-rules` | 変換子オブジェクトを作る |
| `include` `include-ci` `cond-expand` | 展開時に解決する。式の位置とライブラリ宣言の位置の両方に現れる(後述) |
| `define-library` `import` `export` | ライブラリ処理に委譲する |
| `define-values` `define-record-type` `case-lambda` などの派生構文 | Scheme 側の `syntax-rules` で定義する |

`include`、`include-ci`、`cond-expand` は式の位置にも現れる。R7RS の導入部が「The expression types include, include-ci, and cond-expand have been added to the base library; they have the same semantics as the corresponding library declarations」と述べ、付録A が3つとも `(scheme base)` のエクスポートに含めている。ライブラリ宣言としての経路と式としての経路の両方を持つ。前者はライブラリ宣言の列という文脈で処理順の規則に従い、後者は普通の式として展開する。

内部定義の扱いは `letrec*` 意味論に従う(R7RS 5.3.2)。本体の先頭から `define` と `define-syntax` を集め、`define-syntax` を先に構文環境へ入れてから、`define` のスロットを確保する。マクロ展開によって新たな `define` が現れる可能性があるため、本体の走査は展開と交互に行う。

展開器は入力の深さに比例して進むため、Zig の再帰で書かない。明示的な作業スタックを使う([runtime.md](runtime.md))。

### 変換子の実行

`syntax-rules` の変換子は Zig で実行する。将来 `er-macro-transformer` のような Scheme の手続きを変換子にできるようにする場合、変換子の実行は Scheme 手続きの呼び出しになるため、展開器を機械の継続フレームとして表現する必要がある。段階2ではその拡張を想定した関数境界を作るが、実装は `syntax-rules` のみとする。

## syntax-rules

```text
(syntax-rules (<literal>...) <rule>...)
(syntax-rules <ellipsis> (<literal>...) <rule>...)
<rule> = (<pattern> <template>)
```

R7RS 4.3.2 の全機能を実装する。実装しなければならない要件を列挙する。これらは個別のテストケースに対応させる。

- パターン変数、`_`(何にでも照合し束縛しない)、リテラル(意味の一致で照合)
- 省略記号による0回以上の繰り返し
- 省略記号の入れ子(深さ2以上)
- 省略記号の後に固定パターンを置く形。R5RS から R7RS で拡張された部分
- 非真正リストのパターンとテンプレート
- ベクタのパターンとテンプレート
- テンプレート中の省略記号のエスケープ
- 利用者指定の省略記号識別子
- テンプレートに現れるパターン変数以外の識別子の自動別名化
- マクロを定義するマクロ、`letrec-syntax` による再帰的マクロ
- 定数パターン。パターンが定数のとき、入力が `equal?` の意味で等しければ照合する(R7RS 4.3.2「P is a constant and E is equal to P in the sense of the equal? procedure」)
- `_` をリテラル一覧に置いた場合は、ワイルドカードではなくリテラルとして照合する(R7RS 4.3.2「If an underscore appears in the ⟨pattern literal⟩s list, then that takes precedence and underscores in the ⟨pattern⟩ match as literals」)
- 省略記号の識別子をリテラル一覧に置いた場合は、繰り返しではなくリテラルとして照合する(R7RS 4.3.2「unless ⟨ellipsis⟩ appears in the ⟨pattern literal⟩s, in which case it is matched as a literal」)

照合はパターン変数名から、深さと値の木への写像を作る。テンプレート展開はその写像を深さに沿って展開する。パターン変数の出現深さとテンプレート中の省略記号の深さが一致しない場合は構文エラーとする。

照合結果の表現は実装時に決める([open-questions.md](open-questions.md))。

### 衛生性の検証項目

次の事例をテストとして持つ。実装の正しさはこれらで判定する。件数は他の文書に書かず、この一覧を参照させる。

1. `swap!` マクロが、利用側の `tmp` という変数を壊さない
2. `my-or` マクロが、利用側の `t` という変数を壊さない
3. 利用側が `if` を再束縛していても、マクロ内の `if` は本来の意味を保つ
4. `let-syntax` の本体で、マクロ定義側だけが見える手続きをテンプレートが参照できる
5. 利用側が `else` を束縛している場合、`cond` のリテラル `else` が照合しない
6. マクロを定義するマクロで、内側のマクロの衛生性が保たれる
7. 省略記号のエスケープが、入れ子マクロのテンプレート生成で正しく働く
8. 入れ子の同名束縛がリテラルに一致しない。別々の字句環境にある同名の局所束縛を、意味の同一性で誤って同じと判定しないことを確かめる
9. 循環データと共有構造を `quote` したとき、剥離が停止し、循環と `eq?` による同一性が保たれる
10. `let-syntax` の本体から外側の `lambda` の変数を参照したとき、相対深さが正しい

## ライブラリシステム

ライブラリシステムと展開器が依存するため、エクスポート表の表現は設計時に決める。

| 保持するもの | 内容 |
| --- | --- |
| ライブラリ | 名前、エクスポート表、本体の構文環境、読み込みの状態(未読み込み・読み込み中・読み込み済み) |
| エクスポート表 | 外部名から、意味とインポートしたものかどうかの印の組への写像 |

エクスポート表が保持するのは意味そのものであり、変数のセルやマクロに限らない。`(scheme base)` は `if` `lambda` `quote` `define` `set!` `begin` `define-syntax` のような特殊形式もエクスポートするため、これらを `import` し `rename` し再エクスポートできなければ準拠しない。

外部名は独立に所有した文字列のコピーとする。シンボル表と鍵を共有してはならない。シンボル表は弱い表なので、`(export (rename internal external))` の `external` はどの生のシンボル型フィールドにも入らず、最初の GC で名前バッファが解放される。共有していると次の `import` のハッシュ探索が解放済みメモリを読む。コピーはエクスポート表が所有し、その sweep で解放し、計上の対象に含める。

`import` は変数についてはセルを共有する。値をコピーしないため、エクスポート元での再定義がインポート側に反映される。読み込み中のライブラリを再び読み込もうとした場合は循環インポートのエラーとする。

### ライブラリ宣言

R7RS 5.6.1 の `<library declaration>` は7形式である。`(export ...)` `(import ...)` `(begin ...)` `(include ...)` `(include-ci ...)` `(include-library-declarations ...)` `(cond-expand ...)`。`begin` を落とすと `(define-library (sucheme core) (export x) (begin (define x 1)))` という最も一般的な本体記述が未知の宣言になる。

`<import set>` は R7RS 5.2 で5形式が定義されている。

| 形式 | 意味 |
| --- | --- |
| `<library name>` | そのライブラリの全エクスポートを同じ名前で取り込む。入れ子の基底ケースである |
| `(only <import set> <identifier>...)` | 列挙した識別子だけに絞る |
| `(except <import set> <identifier>...)` | 列挙した識別子を除く |
| `(prefix <import set> <identifier>)` | すべてに接頭辞を付ける |
| `(rename <import set> (<from> <to>)...)` | 個別に改名する |

第1の形式を落とすと入れ子の再帰に基底ケースがなくなる。`(import (prefix (scheme base) s-))` の内側の `(scheme base)` に到達した時点で未知の形式になる。4つの修飾子だけを数えないこと。

### 宣言の処理順

R7RS 5.6.1 は2つの実装を許している。1つは `cond-expand` を展開した後に `import` をすべて処理して環境を作り、そのうえで `begin` と `include` を展開する方式である。もう1つは `cond-expand` と `import` を他の宣言と混ぜて左から右へ処理する方式である。

本処理系は後者を採る。R7RS 5.2 が「インポートされる前の識別子を参照すること」をエラーと定めており、検出できる実装を選ぶほうが利用者の誤りを早く知らせられる。

ただし `export` の解決は遅延させる。R7RS 5.6.2 の規範例が `export` を先頭に置いており、左から右へ処理する方式でも `export` だけは本体の処理が終わってから解決しなければならない。

```scheme
(define-library (example grid)
  (export make rows cols ref each (rename put! set!))
  (import (scheme base))
  (begin (define (make n m) ...) ...))
```

`export` 宣言は識別子の名前だけを記録し、ライブラリ本体の処理が終わった時点でまとめて解決する。R7RS 5.6.1 が左から右へ処理すると述べているのは `cond-expand` と `import` についてであり、`export` の解決時点には触れていない。

### インポートした束縛への書き込みの禁止

R7RS 5.2 は次を規定している。

> In a program or library declaration, it is an error to import the same identifier more than once with different bindings, or to redefine or mutate an imported binding with a definition or with set!, or to refer to an identifier before it is imported. However, a REPL should permit these actions.

禁止はプログラムとライブラリ宣言の中に限られ、REPL では許すべきとされている。

展開器は、プログラムまたはライブラリ宣言を展開しているときに次を構文エラーとして拒否する。

- インポートした束縛に対する `define` `define-syntax` `set!`
- 意味が特殊形式またはマクロである識別子に対する `set!`(R7RS 4.1.6 は `set!` の対象を変数に限る)
- 同じ識別子を異なる束縛で2回インポートすること。`import` の処理時に検出する
- インポートされる前の識別子を参照すること

### REPL での扱い

REPL では上記を許す。REPL の環境は少なくとも `(scheme base)` の束縛を持つ(R7RS 5.7)ので、`car` や `list` はインポートされた束縛である。これらを拒否すると `(define (list . xs) xs)` や `(set! car my-car)` が入力できない。

展開器は、プログラムまたはライブラリ宣言を展開しているのか REPL の入力を展開しているのかを引数で受け取る。REPL の場合は3つの操作すべてを遮蔽として扱う。

| 操作 | REPL での扱い |
| --- | --- |
| `define` | REPL 自身の環境に新しいセルを作り、以後その識別子を遮蔽する |
| `define-syntax` | REPL 自身の環境に新しいマクロ束縛を作って遮蔽する |
| `set!` | 意味が変数なら REPL 自身の環境に新しいセルを作って遮蔽し、そこへ代入する。特殊形式とマクロに対してはエラー |

3つすべてを遮蔽にする理由は影響範囲である。セルを共有しているため、エクスポート元のセルへの代入として扱うと、Scheme で書かれた `map` `assoc` `append` の中の `car` も同時に差し替わり、以後の標準手続きが壊れる。REPL で手続きを試す利用者がこの結果を期待することはない。`define-syntax` も同じで、`lib/` が使っている `when` や `cond` を REPL で再定義した時点で標準ライブラリの内部の振る舞いが変わる。

R7RS 5.7 の「Top level REPL definitions ... are truly equivalent to assignments」は、同節が「Implementations may provide an initial REPL environment which behaves as if all possible variables are bound to locations」とした初期環境を提供する処理系に限った話である。本処理系は未束縛の番兵を持つセル方式なのでこの前提を満たさない。同節は構文キーワードの場合を例外としている。

### 探索とパス名への対応付け

R7RS 5.6.1 はライブラリ名を「識別子と正確な非負整数のリスト」と定めている。ファイルに格納する処理系が名前から位置への対応付けを文書化すべきとしているのは R7RS 5.1 の末尾である。本処理系の対応付けを次のとおり定める。

ライブラリ名 `(foo bar)` はファイル `foo/bar.sld` に対応させる。探索パスは、ネイティブでは埋め込みの仮想ファイルシステムを先に見てから実ファイルシステム、WASM では埋め込みのみとする。

識別子は縦棒で囲む記法によって任意の文字を含みうるため、名前の成分をそのままパス成分にしてはならない。`(|../../etc| passwd)` のような名前が探索ルートの外を指す経路になる。次の規則で防ぐ。

1. 成分の検証: 成分が1個以上であり、各成分が1文字以上であり、`A` から `Z`、`a` から `z`、`0` から `9`、`-`、`_`、`.` のみからなり、`.` で始まらず、`.` で終わらず、`.` または `..` に一致しないことを確認する。正確な非負整数の成分は10進表記に変換する。

   許可集合から `+` を外したのは、R7RS 5.6.1 が「It is inadvisable, but not an error, for identifiers in library names to contain any of the characters `|` `\` `?` `*` `<` `"` `:` `>` `+` `[` `]` `/` or control characters after escapes are expanded」としているためである。仕様自身がパスに問題を起こす文字を列挙しており、`/` と `+` が含まれる。エラーではないので、これらを含む名前はファイルに対応付けないだけとし、埋め込みの仮想ファイルシステムと実行時登録からは解決できるようにする。

   空の成分を拒否するのは、`||` が R7RS 2.1 が認める正当な識別子であり、空文字列の成分が文字集合の検証を空虚に満たすためである。パスの結合は空成分を取り除くので、`(|| base)` が `(base)` と同じファイルを開いてしまう。成分数0も同じ理由で拒否する。空リストは各成分への条件を空虚に満たし、組み立てたパスが空になって探索ルート自身を指す。

   `.` で終わる成分を拒否するのは、Windows が末尾の `.` を取り除いて解決し別の名前のファイルに当たるためである。空白と `$` を含む成分は文字集合で既に排除される。

2. 予約デバイス名の検証: 最初の `.` より前の部分が Windows の予約デバイス名に一致する成分を、大文字小文字を区別せずに拒否する。対象は `CON` `PRN` `AUX` `NUL` `COM1` から `COM9` と `LPT1` から `LPT9` である。拡張子を付けてもデバイスまたはその別名に解決されうるため `CON.scm` のような形も拒否する。判定はビルド対象の OS によらず常に行う。対象 OS ごとに通る名前が変わると再現性を失う。
3. 条件を満たさない成分: その名前をファイルに対応付けない。埋め込みの仮想ファイルシステムと実行時に登録されたライブラリのみを探索対象とする。エラーメッセージには元の名前を表示する。
4. 字句的な正規化: 組み立てたパスを正規化し、設定済みの探索ルート配下にあることを確認する。
5. 実体の確認: 字句的な正規化だけでは足りない。探索ルート内にあるシンボリックリンクや Windows の junction や reparse point がルート外を指していれば、正規化後のパスはルート配下に見えたまま外部のファイルを開ける。探索ルートのディレクトリハンドルから成分を1つずつ辿り、リンクと reparse point の追跡を禁止する。この方法が採れない場合は、開いたファイルハンドルから実体のパスを取得してルートの実体のパス配下にあることを確認する。開く前のパス文字列で確認すると、確認と開く操作の間に経路が差し替えられる余地が残る。
6. 大文字と小文字: 識別子は大文字と小文字を区別するが、ファイルシステムは区別しない場合がある。読み込んだファイルの `define-library` の名前が要求した名前と一致することを確認する。

この検証は外部入力の取り扱いに相当する。`AGENTS.md` のセキュリティの節に従い、パスを組み立てる箇所を1つの関数に閉じ、そこで検証する。リンクの追跡を禁止して開く具体的な手段は実装時に Zig 0.17.0 で確認し、結果を [zig-api-notes.md](zig-api-notes.md) に記録する([open-questions.md](open-questions.md))。

### ファイルを開く経路

ファイルを開く経路を全部数え上げ、2つの類に分ける。類によって制約が違うため、1つの制約をすべてにかけることはできない。

第1類は処理系がソースとして読む経路である。探索ルートの制約をかける。

| 経路 | 入力 | 段階 |
| --- | --- | --- |
| `import` と `define-library` のライブラリ名 | シンボルと正確な非負整数のリスト | 2 |
| `include` `include-ci` `include-library-declarations` | 文字列のファイル名(R7RS 4.1.7、5.6.1) | 2 |
| `load` | 文字列のファイル名(`(scheme load)`) | 5 |

第2類は利用者プログラムのファイル入出力である。探索ルートの制約をかけない。制約をかけると R7RS 6.13.1 と 6.14 に反する。

| 経路 | 手続き | 段階 |
| --- | --- | --- |
| 入力ポートを開く | `open-input-file` `open-binary-input-file` `call-with-input-file` `with-input-from-file` | 5 |
| 出力ポートを開く | `open-output-file` `open-binary-output-file` `call-with-output-file` `with-output-to-file` | 5 |
| ファイルの存在と削除 | `file-exists?` `delete-file` | 5 |
| コマンドライン引数で与えたソース | 実行ファイルの引数 | 1 |

`load` を第1類に入れるのは、読み込んだ内容を処理系がソースコードとして展開するためである。R7RS 6.14 は `load` のファイル名の変換を「An implementation-dependent operation is used to transform filename into the name of an existing file」として処理系に委ねているので、探索ルートの制約をかけても非準拠ではない。利用者が任意のパスからソースを読みたい場合は、探索ディレクトリを追加指定する手段を使う([open-questions.md](open-questions.md))。

第2類の失敗は R7RS 6.11 の `file-error?` が真になる条件オブジェクトで報告する。WASM では実ファイルシステムを持たないため、第2類はすべて `file-error` を送出する。

文字列のファイル名を受け取る経路には、第1類なら成分の検証(文字集合、予約デバイス名)を成分ではなくパス要素に対して適用し、加えて次を定める。

- 相対の基準: 相対パスは、その構文を含むファイルのあるディレクトリを基準に解決する。R7RS 4.1.7 はファイルの探索を「apply an implementation-specific algorithm to find corresponding files」と処理系に委ね、同節の Note が「Implementations are encouraged to search for files in the directory which contains the including file, and to provide a way for users to specify other directories to search」と推奨している。これに従う。
- 絶対パスと `..`: 第1類では絶対パスを拒否し、正規化後に探索ルートの外へ出る `..` を拒否する。
- 仮想ファイルシステムとの優先順: 埋め込みを先に見る。

リゾルバは1つの関数に閉じる。引数は基準ディレクトリ、利用者由来の名前、名前の種別(ライブラリ名か文字列か)、開くモード(読み・書き・追記)、バイナリかどうか、探索ルートの制約をかけるかどうかである。戻り値はパス文字列ではなく開いたファイルハンドルとする。検証と使用の間に対象が差し替わる余地を残さない。`file-exists?` と `delete-file` はハンドルを返さないが、同じ検証と同じ基準解決を通した後に操作する。

### cond-expand のフィーチャ

`<feature requirement>` は R7RS 4.2.1 が5形式を定めている。フィーチャ識別子だけでなく論理結合子も実装する。

| 形式 | 意味 |
| --- | --- |
| `<feature identifier>` | 処理系のフィーチャ一覧にあれば真 |
| `(library <library name>)` | そのライブラリがインポート可能なら真 |
| `(and <feature requirement>...)` | すべてが真なら真 |
| `(or <feature requirement>...)` | いずれかが真なら真 |
| `(not <feature requirement>)` | 否定 |

評価の規則は原文のとおり、処理系の一覧にあるフィーチャ識別子と `(library ...)` を `#t` に、それ以外のフィーチャ識別子とライブラリ名を `#f` に置き換えてから、Scheme の真偽式として評価する。

結合子を実装しないと、誤りが検出されない形で非準拠になる。`(cond-expand ((and r7rs (not wasm)) (include "native.scm")) (else (error "unsupported")))` で `(and ...)` を未知のフィーチャ識別子として `#f` に落とすと、エラーにならず黙って `else` 節が選ばれる。

提供するフィーチャ識別子。

| フィーチャ | 条件 |
| --- | --- |
| `r7rs` `sucheme` | 常に真 |
| `exact-closed` `ratios` `exact-complex` `ieee-float` | 段階4の完了により真になる |
| `full-unicode` | 段階4で Unicode テーブルを入れた時点で真になる。サイズの退避案を採る場合は偽のままになる([open-questions.md](open-questions.md)) |
| `unix` `posix` `windows` `gnu-linux` `darwin` | ビルドターゲットに応じる。R7RS 付録B の標準名 |
| `linux` `macos` | 上記の別名として併せて提供する。付録Bにはない独自の名前 |
| `wasm` | WASM ビルドで真 |
| `little-endian` `big-endian` | ターゲットのエンディアンに応じる |
| `sucheme-0.1` のようなバージョン | ビルド時のバージョンに応じる |

OS のフィーチャ名は R7RS 付録B の標準名を提供する。付録Bは「may provide」なので提供しなくても非準拠ではないが、R7RS 4.2.1 が「for portability a core set of features is given in appendix B」とするため、`(cond-expand (gnu-linux ...) (darwin ...) (windows ...) (else (error ...)))` と書いた移植可能なプログラムが else に落ちないようにする。

`features` 手続き(付録A が `(scheme base)` のエクスポートに含める)は、このフィーチャ一覧をリストとして返す。

## 標準ライブラリの起動順序

「コア言語で表現できるものはコア言語で書く」方針([ADR-0006](../adr/0006-library-system-and-scheme-level-stdlib.md))に従い、Zig で書くのは最小限にとどめる。

```mermaid
flowchart TB
    zig["Zig: コア特殊形式とプリミティブ手続き"] --> core["(sucheme core)"]
    core --> derived["lib/sucheme/derived.scm<br/>派生構文を syntax-rules で定義"]
    derived --> baselib["lib/scheme/base.sld<br/>(scheme base)"]
    baselib --> others["(scheme char) (scheme file) (scheme read) ..."]
    baselib --> user["利用者のプログラム"]
```

`(sucheme core)` は内部用のライブラリで、コアの特殊形式と Zig で書いたプリミティブのみを公開する。利用者には公開しない。

Zig で書く範囲は [ADR-0006](../adr/0006-library-system-and-scheme-level-stdlib.md) が族の一覧として定める。Scheme で書くのは派生構文、合成アクセサ、リストと文字列とベクタの高階手続き、`guard`、`assert`、数値手続きのうち基本演算で書けるものである。

`map` と `for-each` を Scheme で書くと末尾呼び出しと継続の相互作用が自動的に正しくなる。性能が問題になった段階で Zig 側へ移すが、その場合も継続フレームを積む形で実装し、プリミティブの中で機械を起動しないという不変条件を守る([open-questions.md](open-questions.md))。

### 埋め込み

`build.zig` が `lib/` 以下を走査して、埋め込んだファイルの一覧とパスの索引を持つ Zig ソースを生成する。走査結果はパス名でソートして再現可能なビルドにする。ネイティブと WASM で同じ仕組みを使う。
