# ランタイム設計

値表現、ガベージコレクション、環境、CEK機械、継続、動的状態、例外を扱う。実装時に最も参照されるドキュメント。

対応する決定: [ADR-0002](../adr/0002-value-representation.md)、[ADR-0003](../adr/0003-precise-mark-sweep-gc.md)、[ADR-0004](../adr/0004-cek-machine-evaluator.md)、[ADR-0008](../adr/0008-string-representation.md)、[ADR-0016](../adr/0016-exception-handler-as-dynamic-point.md)。

## 値表現

`Value` は Zig のタグ付き union とする。即値はインラインに持ち、複合型は GC ヒープ上のオブジェクトへのポインタを持つ。サイズは16バイト(ペイロード8バイト+タグ)。

```zig
pub const Value = union(enum) {
    // 即値
    nil,                      // 空リスト
    unspecified,              // 未規定値
    eof,
    boolean: bool,
    fixnum: i64,
    flonum: f64,
    char: u21,                // Unicode スカラ値
    symbol: Symbol,           // インターン済みID

    // ヒープオブジェクト
    pair: *Pair,
    string: *Str,
    vector: *Vector,
    bytevector: *Bytevector,
    closure: *Closure,
    primitive: *Primitive,
    continuation: *Continuation,
    promise: *Promise,
    record: *Record,
    record_type: *RecordType,
    port: *Port,
    parameter: *Parameter,
    environment: *REnvironment,
    transformer: *Transformer,
    bignum: *Bignum,
    ratnum: *Ratnum,
    compnum: *Compnum,
    condition: *Condition,
    multiple_values: *MultipleValues,

    // 展開時にのみ現れる。CEK機械には到達しない
    alias: *Alias,
};
```

段階1で必要なのは `nil` から `primitive` までで、残りは段階が進むにつれて追加する。タグを増やすと `switch` の網羅性検査が既存コードの修正箇所を教えてくれる。これが表現の選択理由の一つである。

`alias` はマクロ展開の途中にデータの中に現れる識別子である([frontend.md](frontend.md) の構文環境と識別子)。マクロ展開の出力は通常のデータなので、別名もデータの一種でなければならない。別名はコアIRを作る時点で意味に解決されるか元のシンボルに剥離されるため、CEK機械には到達しない。これを不変条件とする。`Value` を受け取る実行時のプリミティブは `alias` の場合を考慮しなくてよいが、`switch` の網羅性検査を満たすために内部エラーとして扱う分岐を書く。

他モジュールはタグに直接依存せず、`value.zig` のアクセサを使う。

```zig
pub inline fn isPair(v: Value) bool {
    return v == .pair;
}

pub fn asFixnum(v: Value) ?i64 {
    return switch (v) {
        .fixnum => |n| n,
        else => null,
    };
}
```

`#f` 以外のすべての値は真である(R7RS 6.3)。真偽判定は `isTruthy` 一箇所に閉じる。

### ヒープオブジェクトのヘッダ

GC は `Value` のタグを知らない状態でオブジェクトを辿る必要があるため、全ヒープオブジェクトは先頭に共通ヘッダを持つ。

```zig
pub const Kind = enum(u8) { pair, string, vector, bytevector, closure, /* ... */ };

pub const Header = struct {
    kind: Kind,
    mark: bool,
    immutable: bool, // リテラル由来。破壊的操作を拒否する(後述)
    next: ?*Header,  // 確保済み全オブジェクトのリンクリスト。sweep で使う
};

pub const Pair = struct {
    header: Header,
    car: Value,
    cdr: Value,
};
```

`Value` のタグと `Header.kind` は冗長だが、GC が型を判別するために必要である。両者の対応表は `value.zig` に1箇所だけ置く。

`Header` のフィールドはいずれも GC のメタデータであり、マークの辺として辿ってはならない。特に `next` は確保済み全オブジェクトを繋ぐリンクであり、1つでも辿ると到達可能な1オブジェクトからヒープ全体が生存扱いになって何も回収されなくなる。走査関数を生成する仕組みは `Header` を必ず除外する。到達不能なオブジェクトが実際に回収されることを確かめるテストを置き、この誤りが入った時点で落ちるようにする。

### Header から具体型への復元

Zig の通常の `struct` はフィールドの配置順を保証しない。`Pair` の宣言で `header` を先頭に書いても、コンパイラが並べ替えてよい。実機で確認したところ、`header` を2番目に宣言しても `@offsetOf` は0になった。つまり宣言順は配置順の根拠にならない。

したがって `*Header` を先頭アドレスとみなして具体型のポインタにキャストしてはならない。配置が変われば無関係なフィールドを読み書きすることになる。`kind` で分岐して `@fieldParentPtr` を使う。

```zig
fn trace(h: *Header, gc: *Gc) void {
    switch (h.kind) {
        .pair => {
            const p: *Pair = @fieldParentPtr("header", h);
            gc.markValue(p.car);
            gc.markValue(p.cdr);
        },
        .string => {
            const s: *Str = @fieldParentPtr("header", h);
            _ = s;
        },
        // ...
    }
}
```

`@fieldParentPtr("header", h)` が結果型から親の型を推論して動作することは実機で確認した。

`extern struct` にして C のレイアウトを強制する方法は採らない。ヒープオブジェクトはスライスやタグ付き union を持ち、`extern struct` ではこれらを扱えないためである。

スイープで確保済みリストを辿るときも同じ規則に従う。アドレス計算による復元を書いた箇所は、レビューで指摘の対象とする。

### リテラルの不変性

R7RS 4.1.2 は次のように規定している。

> As noted in section 3.4, it is an error to attempt to alter a constant (i.e. the value of a literal expression) using a mutation procedure like set-car! or string-set!.

リテラルかどうかを区別する状態がないと、`set-car!` や `string-set!` が通常の可変オブジェクトと同じように通ってしまう。`Header.immutable` がこの区別を担う。

構築の規則は次のとおり。

- リーダが作るオブジェクトは可変である。`cons` や `make-string` が作るものも可変である。
- 展開器がデータをコアIRの定数にする時点で、そこから到達可能なオブジェクトグラフ全体に `immutable` を立てる。対象は `quote` されたデータと、自己評価するリテラル(文字列、ベクタ、バイトベクタ)の両方である。R7RS 4.1.2 はこれらを引用しなくても定数とすると規定している。
- グラフ走査は循環を含みうるので、訪問済み集合を使う。別名の剥離と同じ走査で行える([frontend.md](frontend.md) の quote による剥離)。
- 埋め込んだ Scheme の標準ライブラリに現れるリテラルも同じ経路を通るため、自動的に不変になる。

破壊的操作はすべて `immutable` を検査し、立っていれば Scheme のエラーにする。対象は `set-car!` `set-cdr!` `string-set!` `string-fill!` `string-copy!` `vector-set!` `vector-fill!` `vector-copy!` `bytevector-u8-set!` `bytevector-copy!` である。検査を1つの補助関数に集め、新しい破壊的操作を足したときに検査を忘れないようにする。

### 文字列

文字列は UTF-8 バイト列として保持し、全文字が ASCII かどうかのフラグを持つ。

```zig
pub const Str = struct {
    header: Header,
    bytes: []u8,       // GC ヒープ外のアロケータから確保し、sweep 時に解放
    len: u32,          // 文字数
    ascii_only: bool,
};
```

ASCII のみなら `string-ref` と `string-set!` は定数時間、そうでなければ先頭からの走査になる。R7RS は `string-ref` の計算量を規定していない(R7RS 6.7)ため準拠上の問題はない。UTF-8 を選ぶのはポートと WASM ホスト境界で変換が不要になるためである。幅の変わる `string-set!` はバイト列の再確保を伴う。詳細は [ADR-0008](../adr/0008-string-representation.md)。

### シンボルのインターン

シンボルはインターンして32ビットの ID で表す。`eq?` による比較が ID の一致になり、`Value` にポインタを持たせずに済む。

`string->symbol` は任意の文字列からシンボルを作れる(R7RS 6.5)。インターン表を解放しない永続表にすると、乱数で作った文字列をシンボル化し続けるだけでヒープ上限の外側でメモリを増やし続けられる。長時間稼働する REPL とブラウザでは、これは資源枯渇の経路になる。したがって次の2つを行う。

名前の格納領域をヒープ上限に計上する。インターン表自身の確保も `heap.zig` の計上に含める。上限を超えたら Scheme のエラーにする。

インターン表を弱い表にする。ID が `Value` の中に即値として入るため、GC はポインタを辿るだけでは生きているシンボルを判定できない。そこでマーク段階を利用する。

```zig
pub const SymbolTable = struct {
    names: ArrayListUnmanaged([]u8),   // ID -> 名前
    index: StringHashMapUnmanaged(Symbol), // 名前 -> ID
    pinned: DynamicBitSetUnmanaged,    // 回収してはならない ID
    live: DynamicBitSetUnmanaged,      // マーク中に参照された ID
    free: ArrayListUnmanaged(Symbol),  // 再利用できる ID
};
```

- マーク段階では、オブジェクトを辿る過程でシンボル ID に出会うたびに `live` に印を付ける。GC は既に生きている全オブジェクトを訪れるので、追加の走査は発生しない。
- 記録の対象は `Value` の `.symbol` だけではない。`Symbol` 型の生のフィールドもすべて対象にする。`GlobalCell.name`、`Binding.id`、`Primitive.name`、`RecordType` のフィールド名、`LambdaInfo` の引数名などが該当する。これらを漏らすと、所有オブジェクトが生存中でも ID が回収・再利用され、既存のセルや構文束縛が別のシンボルを指すという最悪の形の破壊が起きる。
- ヒープ上のオブジェクトだけでは足りない。Zig のローカル変数や、展開器がヒープ外に持つ作業表が保持している生の ID も対象にする。これらは次の確保で GC が走ると回収されうる。一時ルート枠は `Value` と `Symbol` の両方を登録できるものとし(`frame.add` と `frame.addSymbol`)、ヒープ外のルート走査も自分が持つ `Symbol` をマークする責任を持つ。
- マーク段階の開始前に `live` を全消去する。消去を忘れると、一度でも参照された ID が以後ずっと生存扱いになり、弱い表として機能しない。
- スイープ段階で、`live` にも `pinned` にもない ID の名前を解放し、ID を `free` に戻す。
- `pinned` には、起動時に Zig 側が登録する既知のシンボル(`quote` `if` `lambda` など)を入れる。これらは Zig のコードが ID を定数として保持するため回収してはならない。
- ID の再利用は、その ID への生きた参照が存在しないことを `live` が保証した後にのみ行う。

この方式により `string->symbol` で作って捨てたシンボルは回収され、ID 表現の利点も保たれる。

生のフィールドの漏れは静かな破壊につながるため、走査関数を手書きしない。`heap.zig` が各オブジェクト型の宣言を `@typeInfo` で走査し、`Value`、`Symbol`、GC オブジェクトへのポインタ、それらのスライスを見分ける走査関数をコンパイル時に生成する。構造体にフィールドを足したときに走査も自動で追随するため、この種の漏れが構造的に起きない。

反映で扱えない型(外部の資源を持つ `Bignum` や `Str` のバイト列など)は個別の走査関数を書く。`Kind` の全要素に走査関数が対応していることを確認するテストを置き、新しい `Kind` を足して走査を忘れた場合にコンパイル時または単体テストで落ちるようにする。

## ガベージコレクション

非移動型のマーク・スイープGCとする。停止型で、確保量が閾値を超えたときに動作する。

非移動型を選ぶ理由は2つある。第一に、`*Pair` などの生ポインタが収集後も有効なままなので、ルート登録は到達可能性の保証だけを意味し、Zig のローカル変数を書き換える必要がない。第二に、ハンドル経由の間接参照が不要なのでコードが読みやすい。代償は断片化とスイープのコストである。

保守的スタック走査は採用しない。wasm の関数ローカル変数は線形メモリ上に存在せず走査できないため、ネイティブと WASM で GC の正しさが変わってしまう。

マーク段階は、生きている `Value` に出会うたびに参照されたシンボル ID を記録する。スイープ段階でインターン表の未参照の項目を解放する(前述のシンボルのインターン)。これによりシンボルもヒープ上限の中で管理される。

### ルート集合

```mermaid
flowchart LR
    subgraph roots[ルート]
        reg["機械レジスタ<br/>control / env / kont / value"]
        dyn["dynamic_point<br/>wind・handler・handler_shift・parameter"]
        glob["グローバル環境<br/>ライブラリごとのエクスポート表"]
        tmp["一時ルートスタック"]
        exp["展開器の作業状態"]
    end
    roots --> heap[(ヒープ)]
```

機械の状態が4レジスタと `dynamic_point` に集約されているため、ルートは少数で済む。これが CEK 機械を選んだ理由の一つである。現在の例外ハンドラを独立したレジスタにせず `dynamic_point` から導出するのも、ルートと真実の源を増やさないためである。

### 一時ルートの書き方

ヒープ確保をまたいで `Value` を保持する場合は、スコープ単位でルート枠を使う。

```zig
pub fn makeList2(h: *Heap, a: Value, b: Value) !Value {
    var frame = h.rootFrame();
    defer frame.pop();
    frame.add(a);
    frame.add(b);

    const tail = try h.cons(b, .nil); // ここで GC が走りうる
    frame.add(tail);
    return try h.cons(a, tail);
}
```

非移動型なので `frame.add(a)` の後も `a` をそのまま使える。`frame.add` は到達可能性のみを保証する。

生のシンボル ID も同じ扱いが必要である。シンボルは弱い表で管理されるため(後述)、確保をまたいで保持する `Symbol` はルート枠に登録する。

```zig
pub fn defineGlobal(h: *Heap, name_text: []const u8, v: Value) !void {
    var frame = h.rootFrame();
    defer frame.pop();
    frame.add(v);

    const sym = try h.intern(name_text); // ここで GC が走りうる
    frame.addSymbol(sym);                // 登録しないと次の確保で回収されうる

    const cell = try h.allocGlobalCell(sym); // ここでも GC が走りうる
    cell.value = v;
}
```

次の書き方は誤りである。

```zig
// 誤り: 2回目の cons で GC が走ると first が回収されうる
const first = try h.cons(.nil, .nil);
const second = try h.cons(.nil, .nil);
return try h.cons(first, second);
```

判断に迷ったら登録する。過剰な登録は性能を落とすだけだが、不足はメモリ破壊を招く。

### 収集の起動点

GC は `heap.allocate` の内部でのみ走る。したがって確保を行う可能性のある呼び出しを見分けることが実装上の要点になる。`heap.zig` の公開APIのうち確保を行うものは、ドキュメンテーションコメントの先頭に `GCを起動しうる` と書く規約とする。

機械のステップ関数の境界では、レジスタだけがルートであることが保証される。したがってステップの先頭で GC を走らせる安全点方式も将来の選択肢として残す。

## 環境

### 局所環境

展開器が字句アドレスを解決するため、局所変数の参照は深さと添字によるポインタ辿りだけになる。

```zig
pub const Rib = struct {
    header: Header,
    parent: ?*Rib,
    slots: []Value, // 固定長。可変長引数は最後のスロットにリストで入る
};
```

内部 `define` は `letrec*` 意味論に従う(R7RS 5.3.2)。展開器は本体をすべて走査して内部定義を集め、`Rib` のスロットを事前に確保し、未初期化を表す内部値で埋める。未初期化スロットの参照はエラーとする。

### グローバル環境

グローバル変数は束縛セルを経由する。

```zig
pub const GlobalCell = struct {
    header: Header,
    name: Symbol,
    value: Value, // 未束縛を表す内部値で初期化
};
```

セルを介することで、前方参照、相互再帰、`set!`、REPL での再定義がすべて自然に扱える。ライブラリごとにシンボルからセルへの表を持ち、`import` はセルを共有する(値をコピーしない)。これによりエクスポート元での再定義がインポート側にも反映される。

セルの共有だけでは、インポートした束縛への `define` と `set!` を拒否できない。R7RS 5.2 がこれをエラーと規定しているため、所有とインポートの区別は構文環境側の意味に持たせる([frontend.md](frontend.md) のインポートした束縛への書き込みの禁止)。実行時のセルには可否の情報を持たせず、展開時に拒否する。

## コアIR

展開器の出力。R7RS 7.1.3 の基本式に対応する。

```zig
pub const Node = struct {
    header: Header, // GC が割り当てリストへの登録と種別判定とマークに使う
    body: union(enum) {
        constant: Value,
        local_ref: struct { depth: u16, index: u16 },
        global_ref: *GlobalCell,
        local_set: struct { depth: u16, index: u16, value: *Node },
        global_set: struct { cell: *GlobalCell, value: *Node },
        branch: struct { test_: *Node, consequent: *Node, alternative: ?*Node },
        lambda: *LambdaInfo,
        seq: []*Node,
        call: struct { operator: *Node, operands: []*Node, tail: bool },
    },
};
```

`Node` も GC ヒープに置くため、他のヒープオブジェクトと同じく先頭に `Header` を持つ。ヘッダのない union にすると、割り当てリストへの登録、`Header.kind` による種別判定、マークのいずれもできない。`Header.kind` は `.core_node` の1種類とし、子の走査は `body` のタグで分岐する。

`call` の `tail` は展開器が付ける。機械はこの印を信用して、真なら継続フレームを積まない。末尾位置の判定を機械側に持たせないのは、判定の責任を1箇所にまとめるためである。

コアIRの節点は GC ヒープに置く。`constant` が `Value` を持ち、`lambda` が実行時にクロージャとして参照されるため、プログラム本体も収集対象にする必要がある(REPL で再定義を繰り返すとコードも捨てられる)。

## CEK機械

### 状態

```zig
pub const Machine = struct {
    heap: *Heap,
    control: ?*Node,    // 次に評価する式。null なら value を継続に渡す
    env: ?*Rib,
    kont: ?*Frame,      // 継続。null なら実行完了
    value: Value,       // 直前の結果
    dynamic_point: ?*DynPoint, // wind と parameter と handler の束縛列
    step_budget: u64,   // WASM で制御を戻すための歩数制限
};
```

「現在の例外ハンドラ」は独立したレジスタにしない。`dynamic_point` から定数時間で導出する。理由と仕組みは例外の節で述べる。

ステップ関数は `control` が非 null なら式を1段分解して進み、null なら `value` を `kont` に渡して1フレーム取り崩す。実行ループはこれを繰り返すだけである。

```mermaid
stateDiagram-v2
    [*] --> Eval
    Eval --> Eval: 部分式を取り出しフレームを積む
    Eval --> Eval: 末尾呼び出しはフレームを積まない
    Eval --> Apply: 定数・変数参照・呼び出しが完了した
    Apply --> Eval: フレームを取り崩し次の式へ
    Apply --> [*]: kont が null
```

### 継続フレーム

継続フレームは不変とする。一度作ったフレームの内容を書き換えてはならない。

```zig
pub const Frame = struct {
    header: Header,
    parent: ?*Frame,
    env: ?*Rib,
    kind: union(enum) {
        if_branch: struct { consequent: *Node, alternative: ?*Node },
        seq_rest: struct { nodes: []*Node, index: u32 },
        set_local: struct { depth: u16, index: u16 },
        set_global: *GlobalCell,
        eval_operator: struct { operands: []*Node, tail: bool },
        eval_operand: struct {
            operands: []*Node,
            index: u32,
            operator: Value,
            done: Value, // 評価済み引数の逆順リスト
            tail: bool,
        },
        // 段階2以降で追加
        receive_values: struct { consumer: Value },
        handler_result: struct {
            continuable: bool,
            shift_point: *DynPoint, // raise が積んだ handler_shift 点
        },

        // dynamic-wind の通常実行経路。後述
        wind_enter: struct { thunk: Value, after: Value },
        wind_body: struct { after: Value, point: *DynPoint },
        wind_leave: struct { result: Value },

        // with-exception-handler と parameterize の本体が通常終了した
        leave_dynamic: struct { point: ?*DynPoint }, // 復元する dynamic_point

        rewind: Rewind, // 継続起動時の動的状態の遷移。後述
    },
};
```

引数の蓄積を可変配列ではなく不変の逆順リストで行うのは、継続の多重起動に対する正しさのためである。引数を評価している途中で `call/cc` で継続を捕捉し、その継続を2回起動した場合、可変配列を共有していると2回目が1回目の書き込みを観測してしまう。不変リストなら各起動が独立した状態から再開する。

この選択は確保回数を増やす。段階6以降の最適化候補として、捕捉時にコピーするスタックセグメント方式を検討する。最適化は準拠テストが通った後に行う。

### 完全な継続

```zig
pub const Continuation = struct {
    header: Header,
    kont: ?*Frame,
    dynamic_point: ?*DynPoint,
};
```

`call/cc` は現在の `kont` と `dynamic_point` を保存した `Continuation` を作り、引数の手続きに渡す。起動時は `kont` を復元し、`dynamic_point` を現在のものから目標のものへ巻き戻す。現在の例外ハンドラは `dynamic_point` から導出されるので、別に保存するものはない。フレームが不変なので捕捉は定数時間であり、多重起動も再入も成立する。

### 動的状態

`dynamic-wind`、`with-exception-handler`、`parameterize` の3つは、いずれも動的範囲に対する束縛である。1つの不変リストで統一して表す。

```zig
pub const DynPoint = struct {
    header: Header,
    parent: ?*DynPoint,
    depth: u32,                      // 共通祖先の計算用
    current_handler: ?*DynPoint,     // この点で有効な handler 点。生成時に決まる
    kind: union(enum) {
        wind: struct { before: Value, after: Value },
        handler: Value,              // この点より内側で現在のハンドラになる
        handler_shift: ?*DynPoint,   // 現在のハンドラをこの handler 点に切り替える
        parameter: struct { param: *Parameter, value: Value },
    },
};
```

`current_handler` は生成時に決まり、以後変わらない。

| 点の種別 | `current_handler` |
| --- | --- |
| `handler` | その点自身 |
| `handler_shift` | 切り替え先の `handler` 点(`null` もありうる) |
| `wind` と `parameter` | 親の `current_handler` |

この1つのフィールドにより、ある動的点における現在の例外ハンドラが `dynamic_point.?.current_handler` で定数時間に求まる。独立したレジスタを持たず、`dynamic_point` だけが真実の源になる。

`handler_shift` は `raise` がハンドラを呼ぶ間だけ積む点である。R7RS 6.11 の「現在のハンドラだけを切り替え、残りの動的環境は `raise` 時のまま保つ」を、外側へ戻るのではなく内側へ1点積むことで表す。詳細は例外の節で述べる。

この表現を選ぶまでに、独立したカーソルレジスタを持つ案を検討して捨てた。カーソルを点の生成時の値から復元する方式も、現在の `dynamic_point` から導出する方式も、継続による再入や `raise` を囲む `dynamic-wind` からの脱出で誤った値になる。レジスタと点の列という2つの真実の源を同期させようとすることが問題の根であり、源を1つにすれば同期の誤りが起こりえない。経緯は [ADR-0016](../adr/0016-exception-handler-as-dynamic-point.md) に記録した。

継続の起動時は、現在の点と目標の点の共通祖先を `depth` を使って求め、現在側を祖先まで `after` を呼びながら降り、目標側を `before` を呼びながら登る(R7RS 6.10)。ハンドラとパラメータの束縛は呼び出しを伴わないので、復元は参照の差し替えだけで済む。

3つを1つの機構で表すことで、`call/cc` との相互作用を1箇所で正しくすれば全体が正しくなる。

「現在の例外ハンドラ」もこの列の中で表す。`raise` がハンドラを呼ぶ間だけ `handler_shift` 種別の点を積むことで、独立したレジスタを持たずに R7RS 6.11 の規定を満たす。理由は例外の節で述べる([ADR-0016](../adr/0016-exception-handler-as-dynamic-point.md))。

### dynamic-wind の通常実行

`before`、`thunk`、`after` はいずれも Scheme 手続きである。プリミティブの中で機械を起動しないという不変条件により、3つの呼び出しはそれぞれ継続フレームを積んで機械に戻す形で実装する。

```mermaid
sequenceDiagram
    participant M as 機械
    participant B as before
    participant T as thunk
    participant A as after

    M->>B: 呼び出し。継続は wind_enter{thunk, after}
    B-->>M: 戻る
    Note over M: wind の DynPoint を積む
    M->>T: 呼び出し。継続は wind_body{after, point}
    T-->>M: 戻る(値は value)
    Note over M: DynPoint を外す
    M->>A: 呼び出し。継続は wind_leave{result = value}
    A-->>M: 戻る
    Note over M: value = result として親の継続へ
```

- `wind_enter`: `before` が完了した。`wind` 種別の `DynPoint` を積み、`thunk` を呼ぶ。継続は `wind_body`。
- `wind_body`: `thunk` が完了した。`dynamic_point` を `point` の親に戻し、`after` を呼ぶ。継続は `wind_leave { result = value }`。フレームは不変なので、`thunk` の結果はこの新しいフレームに格納する。
- `wind_leave`: `after` が完了した。`after` の戻り値を捨て、`result` を親の継続に渡す。

`after` は `DynPoint` を外した後に呼ぶ。R7RS 6.10 が `after` を `thunk` の動的範囲の外で実行すると規定しているためである。`thunk` が複数値を返した場合は `result` に `MultipleValues` が入り、そのまま親に渡る。

`thunk` が例外を送出した場合や継続で脱出した場合は、この通常経路ではなく後述の巻き戻しが働く。

### 動的範囲の通常終了

`with-exception-handler` と `parameterize` も `DynPoint` を積むため、本体が通常終了したときに外す継続状態が必要である。非局所脱出だけを考えて専用のフレームを置かないと、ハンドラやパラメータの束縛が後続の処理へ漏れる。

`leave_dynamic` フレームがこれを担う。本体を呼ぶ際に、積む前の `dynamic_point` を保存したフレームを継続として置く。本体が値を返したら `dynamic_point` を復元し、`value` をそのまま親の継続に渡す。本体が複数値を返した場合もそのまま渡る。現在の例外ハンドラは `dynamic_point` から導出されるため、別に復元するものはない。

`dynamic-wind` は `after` の呼び出しを伴うため `wind_body` と `wind_leave` を使うが、`with-exception-handler` と `parameterize` は呼び出しを伴わないので `leave_dynamic` だけで足りる。

### 巻き戻しの進行

`after` と `before` は Scheme 手続きであり、その中でさらに継続を捕捉したり起動したりできる。したがって巻き戻しを Zig の同期ループで回すことはできない。巻き戻しの途中の状態自体が継続に含まれていなければならない。

専用の不変フレームを置く。

```zig
pub const Rewind = struct {
    phase: enum { exiting, entering },

    // exiting: 現在側を共通祖先まで降りる
    cursor: ?*DynPoint,       // 次に after を呼ぶ点
    ancestor: ?*DynPoint,     // 共通祖先。exiting の終点

    // entering: 目標側を共通祖先から降りる
    enter_path: ?*DynPath,    // 外側から内側の順に並べた経路
    enter_index: u32,         // 次に before を呼ぶ位置

    target_point: ?*DynPoint, // 目標の動的点。entering の終点
    target_kont: ?*Frame,     // 遷移完了後に復元する継続
    target_value: Value,      // 復元した継続に渡す値。複数値も入る
};

pub const DynPath = struct {
    header: Header,
    points: []*DynPoint, // ancestor の直下から target_point までを外側から内側の順に並べる
};
```

`DynPoint` は親へのポインタしか持たないため、目標側を外側から内側へ辿ることができない。`exiting` の完了時に `target_point` から `ancestor` まで親をたどり、順序を反転した `DynPath` を作る。この構築は Scheme 手続きの呼び出しを伴わないので同期に行える。

`DynPath` は作成後に変更しない。`entering` の各段は `enter_index` を1つ進めた新しい `Rewind` フレームを作り、同じ `DynPath` を共有する。不変なので共有しても継続の多重起動で壊れない。

機械の動作は次のとおり。

```mermaid
stateDiagram-v2
    [*] --> Exiting: 継続を起動。共通祖先を求める
    Exiting --> Exiting: cursor の after を呼ぶ。戻ったら cursor を親へ
    Exiting --> Entering: cursor が ancestor に到達
    Entering --> Entering: 目標側の経路を1つ進み before を呼ぶ
    Entering --> Done: target_point に到達
    Done --> [*]: kont と dynamic_point と value を復元
```

各 `after` と `before` の呼び出しは通常の手続き呼び出しとして機械に積む。その継続として、`exiting` なら `cursor` を親へ進め、`entering` なら `enter_index` を1つ進めた新しい `Rewind` フレームを置く。フレームは不変なので、`after` の中で捕捉した継続を後で起動しても、その時点の巻き戻し状態から正しく再開する。

`dynamic_point` レジスタは各 `after` の呼び出しの前に親へ、各 `before` の呼び出しの後に子へ更新する。これにより `after` と `before` の中で例外が起きた場合のハンドラ探索が、R7RS の規定どおりその時点の動的環境を見る。

現在の例外ハンドラについて追加の同期は不要である。`dynamic_point.?.current_handler` で導出されるため、`dynamic_point` を正しく動かせば自動的に追随する。`raise` がハンドラを呼ぶ間に積んだ `handler_shift` 点も列の一部なので、巻き戻しの経路に含まれて正しい順序で退出する。

- 点 N を退出するとき: `dynamic_point = N.parent` にしてから、N が `wind` なら `after` を呼ぶ。
- 点 N へ進入するとき: まず `dynamic_point = N.parent` にして、N が `wind` なら `before` を呼ぶ。戻ったら `dynamic_point = N` にする。
- 遷移の完了時は `target_point` と `target_kont` と `target_value` を復元する。

真実の源が `dynamic_point` だけなので、通常経路と巻き戻し経路で `after` が見るハンドラが食い違う余地がない。独立したレジスタを同期させる方式では、この食い違いが設計上の繰り返しの誤りになっていた。

### 例外

R7RS 6.11 は `raise` について次のように規定している。

> The handler is called with the same dynamic environment as that of the call to raise, except that the current exception handler is the one that was in place when the handler being called was installed. If the handler returns, a secondary exception is raised in the same dynamic environment as the handler.

変わるのは現在の例外ハンドラだけであり、動的環境の残りは `raise` を呼んだ時点のままである。したがって `dynamic_point` 全体を外側へ戻してはならない。戻してしまうと、ハンドラのインストールより内側で有効になった `parameterize` の束縛や `dynamic-wind` の範囲までハンドラから見えなくなる。

規定を満たす方法は、外側へ戻るのではなく内側へ1点積むことである。`raise` はハンドラを呼ぶ間だけ `handler_shift` 種別の点を積む。この点は「現在のハンドラを、呼ばれるハンドラがインストールされた時点のものに切り替える」ことだけを表す。`parameterize` の束縛も `dynamic-wind` の範囲も列の中にそのまま残るため、ハンドラは `raise` 時点の動的環境を見る。

```mermaid
flowchart RL
    P["handler_shift<br/>切り替え先 = C0"] --> W["wind W"] --> H["handler H"] --> C0["handler C0"] --> nil["null"]
```

上の列は、ハンドラ `C0` の内側で `H` をインストールし、その本体で `dynamic-wind` に入り、その thunk で `raise` した状態である。`handler_shift` を積んだので `current_handler` は `C0` になり、`H` の実行中に再び `H` が呼ばれることはない。`dynamic_point` は `raise` 時点のものに1点足しただけなので、`W` の範囲も失われていない。

各手続きの動作は次のとおり。

- `with-exception-handler`: `handler` 種別の点を積み、`thunk` を `leave_dynamic` 継続のもとで呼ぶ。積んだ点の `current_handler` はその点自身になる。
- `raise` と `raise-continuable`: `H = dynamic_point.?.current_handler` を求める。`null` なら未処理例外として扱う。`handler_shift` 種別の点を積む。切り替え先は `H.parent` の `current_handler`、すなわち `H` をインストールした時点で現在だったハンドラである。この点を積んだ状態で `H` のハンドラ手続きを呼ぶ。継続は `handler_result`。
- `handler_result`: `raise-continuable` の場合は積んだ `handler_shift` 点を外し(規定の「it will again become the current exception handler」)、ハンドラの戻り値を `raise-continuable` の値として親の継続に渡す。`raise` の場合は二次例外を起こす。このとき `dynamic_point` はハンドラ実行時のままなので、規定の「in the same dynamic environment as the handler」が満たされる。
- `guard`: Scheme 側で `call/cc` と `with-exception-handler` を用いて実装する(R7RS 7.3 の派生式に対応)。
- `error`: 条件オブジェクトを作って `raise` する。

ハンドラの中でさらに例外が起きた場合、`current_handler` は `handler_shift` によって既に外側を指しているため外側のハンドラが呼ばれ、無限ループにならない。

ハンドラが継続で脱出した場合も、`handler_shift` 点が列の一部なので巻き戻しの経路に含まれ、正しい順序で退出する。独立したレジスタを `dynamic_point` と同期させる必要がないため、両者が食い違う種類の誤りが起こりえない。

テストに含める事例を挙げる。

1. ハンドラの中で `dynamic-wind` に入り、そこから継続で脱出したとき、`after` の中の例外が実行中のハンドラではなく外側のハンドラに届く。
2. `raise` を囲む `dynamic-wind` からハンドラが継続で脱出したとき、`after` が見るハンドラが、その `dynamic-wind` を呼んだ時点のハンドラと一致する。
3. 上の2つについて、通常終了の経路と脱出の経路で `after` が見るハンドラが一致する。
4. ハンドラの内側で `parameterize` した束縛が、`raise` 時点の束縛としてハンドラから見える。
5. `raise-continuable` のハンドラが戻った後、現在のハンドラがそのハンドラに戻っている。

条件オブジェクトは R7RS が要求する述語を区別できる構造を持つ。

```zig
pub const Condition = struct {
    header: Header,
    tag: enum { error_object, read_error, file_error },
    message: Value,  // 文字列
    irritants: Value, // リスト
};
```

### 複数値

`values` は引数が1個なら値をそのまま返し、それ以外なら `MultipleValues` を返す。これを受け取れるのは `receive_values` フレームと最外の REPL だけである。1個を期待するフレームが複数値を受け取った場合はエラーとする。R7RS はこの場合を未規定としている(R7RS 6.10)ため、検出してエラーにする方が実装の誤りを見つけやすい。

### 歩数制限とWASM

ブラウザではメインスレッドを長時間占有できない。機械のループは `step_budget` 歩で制御を呼び出し元に返す。WASM のエクスポート関数は続きがあるかどうかを返し、JS 側が再開する。この構造はネイティブ側でも割り込み処理に使える。

深い再帰はヒープフレームを消費するだけなので Zig のスタックは溢れない。ただし無限再帰でヒープを食い潰す前に Scheme のエラーにするため、フレーム数の上限を設定可能にする。
