//! The Scheme value.
//!
//! タグ付き共用体である(ADR-0002)。種別の全体は docs/design/runtime.md の表に
//! あり、各種別は、それを最初に作るスライスで加わる。スライス 1a は固定長の整数、
//! 1b は未規定値、1c は真偽値・空リスト・シンボル・ペア、1d は2種類の手続きを持ち、
//! 1e は未定義の変数の目印を加える。スライス 1f は条件オブジェクトと、コア IR と
//! 継続のレイアウトを加える。この2つは値ではないが、同じようにたどられる。
//! スライス 1g は、ペア・クロージャ・フレーム・継続フレーム・引数リストを GC ヒープ
//! (src/heap.zig)に置く。スライス 1h は文字・文字列・ベクタを加える。スライス 2b は
//! 条件オブジェクトを GC ヒープに移す。スライス 2i は、展開器の構文環境(値ではない
//! が GC ヒープにある)を加え、スライス 2j は大域変数の束縛セル(同じく GC ヒープに
//! ある)を加える。スライス 2h は、レコードとレコード型を加える。スライス 2k は、
//! マクロのテンプレートが導入した識別子である別名と、マクロを加える。別名は値の変種
//! だが、展開器の中だけにあり、機械には届かない。
//! GC がたどるものすべてのレイアウトをここで定義するので、それらをすべて知って
//! いなければならない場所は、このファイル1つである(docs/design/architecture.md)。
//!
//! このファイルの外のコードは、共用体のタグで switch しない。`kind` に問い合わせ、
//! アクセサ経由で読む。こうすると、表現を差し替え可能に保ったまま、`Kind` に対する
//! `switch` が、新しい種別を扱うべき箇所をすべて列挙してくれる。

const std = @import("std");
const SymbolId = @import("symbol.zig").SymbolId;
// ポインタ越しに名指すだけで、`Heap` のレイアウトには依存しない。
const Heap = @import("heap.zig").Heap;

pub const Value = union(enum) {
    fixnum: i64,
    boolean: bool,
    /// The empty list `()`.
    empty_list,
    symbol: SymbolId,
    /// A pair.
    /// GC ヒープにある。
    pair: *Pair,
    /// A procedure implemented in Zig.
    primitive: *const Primitive,
    /// A procedure made by `lambda`.
    closure: *Closure,
    /// What an expression with no useful value returns, such as `define`.
    /// 最上位の値としては REPL が出力しない(`Interpreter` の判定)。ペアやベクタの
    /// 要素になったときは、プリンタが `#<unspecified>` と書く。
    unspecified,
    /// What a local variable holds between the start of its body and its
    /// definition (R7RS 5.3.2 binds the names of a body as `letrec*` does).
    /// 変数がこれを保持している間に読むとエラーになるので、この目印が値として
    /// プログラムに届くことはない。
    uninitialized,
    /// What a Scheme error is: an object that says what went wrong (R7RS 6.11).
    /// GC ヒープにある。
    condition: *Condition,
    /// A character: a Unicode scalar value (R7RS 6.6), so never a surrogate.
    character: u21,
    /// A string.
    /// GC ヒープにある。
    string: *String,
    /// A vector.
    /// GC ヒープにある。
    vector: *Vector,
    /// An identifier that a macro's template put into its output (ADR-0019).
    /// GC ヒープにある。展開の途中だけに現れる。`quote` の中のものは定数にする時点で
    /// 元のシンボルに戻すので、機械には届かない。
    alias: *Alias,
    /// A record: an instance of a record type (R7RS 5.5).
    /// GC ヒープにある。
    record: *Record,
    /// A record type: what `%make-record-type` makes, and what the record
    /// primitives check a record against.
    /// GC ヒープにある。
    record_type: *RecordType,
    /// A continuation that `call/cc` captured (R7RS 6.10): a procedure that
    /// takes the computation back to where it was captured.
    /// GC ヒープにある。
    continuation: *Continuation,

    /// The empty list.
    /// 同名の定数はバリアントと衝突するので、バリアントとは別の名前にしてある。
    pub const empty_list_value: Value = .empty_list;

    /// The unspecified value.
    /// 同じ理由で、バリアントとは別の名前にしてある。
    pub const unspecified_value: Value = .unspecified;

    /// The marker of a variable that is not defined yet.
    /// 同じ理由で、バリアントとは別の名前にしてある。
    pub const uninitialized_value: Value = .uninitialized;

    pub fn fromFixnum(n: i64) Value {
        return .{ .fixnum = n };
    }

    pub fn fromBool(b: bool) Value {
        return .{ .boolean = b };
    }

    pub fn fromSymbol(id: SymbolId) Value {
        return .{ .symbol = id };
    }

    pub fn fromPrimitive(p: *const Primitive) Value {
        return .{ .primitive = p };
    }

    pub fn fromClosure(c: *Closure) Value {
        return .{ .closure = c };
    }

    pub fn fromCondition(c: *Condition) Value {
        return .{ .condition = c };
    }

    /// The character `c`, which must be a scalar value (`isScalarValue`).
    pub fn fromCharacter(c: u21) Value {
        std.debug.assert(isScalarValue(c));
        return .{ .character = c };
    }

    pub fn fromString(s: *String) Value {
        return .{ .string = s };
    }

    pub fn fromVector(v: *Vector) Value {
        return .{ .vector = v };
    }

    pub fn fromAlias(a: *Alias) Value {
        return .{ .alias = a };
    }

    pub fn fromRecord(r: *Record) Value {
        return .{ .record = r };
    }

    pub fn fromRecordType(t: *RecordType) Value {
        return .{ .record_type = t };
    }

    pub fn fromContinuation(c: *Continuation) Value {
        return .{ .continuation = c };
    }

    /// Whether the value refers to an object in the GC heap, which the collector
    /// has to be told about if the value is kept anywhere it cannot see.
    pub fn pointsIntoHeap(self: Value) bool {
        return switch (self) {
            .pair, .closure, .string, .vector, .condition, .alias, .record, .record_type, .continuation => true,
            .fixnum, .boolean, .empty_list, .symbol, .primitive, .unspecified, .uninitialized, .character => false,
        };
    }

    pub fn kind(self: Value) Kind {
        return switch (self) {
            .fixnum => .fixnum,
            .boolean => .boolean,
            .empty_list => .empty_list,
            .symbol => .symbol,
            .pair => .pair,
            .primitive => .primitive,
            .closure => .closure,
            .unspecified => .unspecified,
            .uninitialized => .uninitialized,
            .condition => .condition,
            .character => .character,
            .string => .string,
            .vector => .vector,
            .alias => .alias,
            .record => .record,
            .record_type => .record_type,
            .continuation => .continuation,
        };
    }

    /// The integer, or null when the value is not a fixnum.
    pub fn asFixnum(self: Value) ?i64 {
        return switch (self) {
            .fixnum => |n| n,
            else => null,
        };
    }

    /// The symbol, or null when the value is not one.
    pub fn asSymbol(self: Value) ?SymbolId {
        return switch (self) {
            .symbol => |id| id,
            else => null,
        };
    }

    /// The pair, or null when the value is not one.
    pub fn asPair(self: Value) ?*Pair {
        return switch (self) {
            .pair => |p| p,
            else => null,
        };
    }

    /// The primitive, or null when the value is not one.
    pub fn asPrimitive(self: Value) ?*const Primitive {
        return switch (self) {
            .primitive => |p| p,
            else => null,
        };
    }

    /// The closure, or null when the value is not one.
    pub fn asClosure(self: Value) ?*Closure {
        return switch (self) {
            .closure => |c| c,
            else => null,
        };
    }

    /// The condition, or null when the value is not one.
    pub fn asCondition(self: Value) ?*Condition {
        return switch (self) {
            .condition => |c| c,
            else => null,
        };
    }

    /// The character, or null when the value is not one.
    pub fn asCharacter(self: Value) ?u21 {
        return switch (self) {
            .character => |c| c,
            else => null,
        };
    }

    /// The string, or null when the value is not one.
    pub fn asString(self: Value) ?*String {
        return switch (self) {
            .string => |s| s,
            else => null,
        };
    }

    /// The vector, or null when the value is not one.
    pub fn asVector(self: Value) ?*Vector {
        return switch (self) {
            .vector => |v| v,
            else => null,
        };
    }

    /// The alias, or null when the value is not one.
    pub fn asAlias(self: Value) ?*Alias {
        return switch (self) {
            .alias => |a| a,
            else => null,
        };
    }

    /// The record, or null when the value is not one.
    pub fn asRecord(self: Value) ?*Record {
        return switch (self) {
            .record => |r| r,
            else => null,
        };
    }

    /// The record type, or null when the value is not one.
    pub fn asRecordType(self: Value) ?*RecordType {
        return switch (self) {
            .record_type => |t| t,
            else => null,
        };
    }

    /// The continuation, or null when the value is not one.
    pub fn asContinuation(self: Value) ?*Continuation {
        return switch (self) {
            .continuation => |c| c,
            else => null,
        };
    }

    /// Whether a conditional takes the consequent.
    /// `#f` 以外のすべての値は真で、空リストと 0 も含む(R7RS 6.3)。
    pub fn isTrue(self: Value) bool {
        return switch (self) {
            .boolean => |b| b,
            else => true,
        };
    }

    /// Whether `a` and `b` are the same value in the sense of `eqv?` (R7RS 6.1).
    /// 整数・真偽値・空リスト・シンボル・文字は値で比べ、ペア・文字列・ベクタ・手続き
    /// は同じオブジェクトかで比べる。種別が違えば偽である。内容が同じ別々のペアや
    /// 文字列は偽で、それを比べるのは `equal?` である。値の表現を隠すため、この
    /// ファイルの外は共用体のタグを見ずにこれを使う。
    ///
    /// 空の文字列と空のベクタは、R7RS が未規定とするので、同一性で比べる。
    pub fn isEqv(a: Value, b: Value) bool {
        return switch (a) {
            .fixnum => |x| b.asFixnum() == x,
            .boolean => |x| switch (b) {
                .boolean => |y| x == y,
                else => false,
            },
            .empty_list => b.kind() == .empty_list,
            .symbol => |x| b.asSymbol() == x,
            .character => |x| b.asCharacter() == x,
            .unspecified => b.kind() == .unspecified,
            .uninitialized => b.kind() == .uninitialized,
            .pair => |x| b.asPair() == x,
            .string => |x| b.asString() == x,
            .vector => |x| b.asVector() == x,
            .primitive => |x| b.asPrimitive() == x,
            .closure => |x| b.asClosure() == x,
            .condition => |x| b.asCondition() == x,
            .alias => |x| b.asAlias() == x,
            .record => |x| b.asRecord() == x,
            .record_type => |x| b.asRecordType() == x,
            .continuation => |x| b.asContinuation() == x,
        };
    }

    /// Whether `a` and `b` are the same value in the sense of `eq?` (R7RS 6.1).
    ///
    /// Why: R7RS 6.1 は、数と文字の `eq?` を実装依存とし、真を返してよいのは `eqv?` が
    /// 真のときだけとする。段階1の数は固定長整数だけなので、`eqv?` と同じ関数でよい。
    /// 段階4で数の種類が増えて `eqv?` が分かれたとき、`eq?` はここで別に決める。
    pub fn isEq(a: Value, b: Value) bool {
        return a.isEqv(b);
    }
};

/// The object an error is: what kind of error, the message, and the objects
/// the message is about (R7RS 6.11).
/// GC ヒープにある(スライス 2b)。上限に達していても作れるよう、作る地点は送出の
/// ための予約領域から確保する(`Context.makeCondition`)。
pub const Condition = struct {
    kind: ConditionKind,
    /// A string.
    message: Value,
    /// A list, empty when the message is about nothing in particular.
    irritants: Value,

    /// The text of the message.
    pub fn messageText(self: *const Condition) []const u8 {
        return self.message.asString().?.bytes;
    }
};

/// Which of the predicates of R7RS 6.11 a condition answers to.
/// `error-object?` はすべてに真で、`read-error?` と `file-error?` はそれぞれ1つに真である。
pub const ConditionKind = enum { @"error", read, file };

pub const Pair = struct {
    car: Value,
    cdr: Value,
};

/// A string: its characters as UTF-8, which the creator guarantees is valid
/// (ADR-0008), and whether all of them are ASCII.
/// バイト列は、ヒープが所有し、計上するペイロードである。
pub const String = struct {
    bytes: []u8,
    /// Whether every character is ASCII, so that character `n` is byte `n`.
    /// 文字列を作る `Heap.createString` の1か所だけが計算する。ここで既定値を持たない
    /// のは、計算し忘れた作り方が、黙って誤った答えを返すのを避けるためである。
    /// GC の走査にも、ヒープの計上にも関わらない(計上するのはバイト列の長さである)。
    is_ascii: bool,

    /// The number of characters, which is the number of bytes when they are all
    /// ASCII.
    /// ASCII だけなら定数時間で、そうでなければ UTF-8 の先頭バイトを数える。
    pub fn length(self: *const String) usize {
        if (self.is_ascii) return self.bytes.len;
        var count: usize = 0;
        for (self.bytes) |b| {
            // 後続バイト(0b10xxxxxx)は文字の途中なので数えない。
            if (b & 0xC0 != 0x80) count += 1;
        }
        return count;
    }

    /// The character at `index`, counted in characters, or null when `index` is
    /// not less than `length`.
    /// ASCII だけなら添字がそのままバイトの位置で、そうでなければ先頭から走査する。
    pub fn charAt(self: *const String, index: usize) ?u21 {
        if (self.is_ascii) {
            if (index >= self.bytes.len) return null;
            return self.bytes[index];
        }
        var it = std.unicode.Utf8View.initUnchecked(self.bytes).iterator();
        var skipped: usize = 0;
        while (skipped < index) : (skipped += 1) _ = it.nextCodepointSlice() orelse return null;
        return it.nextCodepoint();
    }
};

/// Whether every byte of `bytes` is ASCII.
/// 妥当な UTF-8 では、最上位ビットが立つバイトがあれば、ASCII でない文字がある。
pub fn allAscii(bytes: []const u8) bool {
    for (bytes) |b| {
        if (b >= 0x80) return false;
    }
    return true;
}

/// A vector: its elements in order.
/// 要素は、ヒープが所有し、計上するペイロードで、GC はそれをたどる。
pub const Vector = struct {
    items: []Value,
};

/// A record type: its name, and how many fields its records have.
/// フィールドは添字で読み書きする。フィールドの名前から添字を求めるのは、段階3の
/// `define-record-type` の展開であり、型はフィールドの名前を持たない
/// (docs/plans/0014-phase2-core-language.md の 2h の節)。型の同一性はオブジェクトの
/// 同一性で、名前が同じでも別の型である。
pub const RecordType = struct {
    /// The name the type was made with, for the printer.
    name: SymbolId,
    field_count: u32,
};

/// A record: its type, and the values of its fields in order.
/// フィールドの値は、ヒープが所有し、計上するペイロードで、GC はそれをたどる。
/// 個数は型の `field_count` と等しい。
pub const Record = struct {
    record_type: *RecordType,
    fields: []Value,
};

/// Whether `cp` is a Unicode scalar value: from 0 to #xD7FF or from #xE000 to
/// #x10FFFF (R7RS 6.6), the code points a character can be.
/// 数から文字を作るものはすべて、まずこれを問い合わせる。そのため、サロゲートや範囲外
/// の数は Scheme のエラーになり、UTF-8 にならない文字列が作られることはない。
pub fn isScalarValue(cp: u32) bool {
    return cp <= 0xD7FF or (cp >= 0xE000 and cp <= 0x10FFFF);
}

/// The ways a primitive can fail.
/// プリミティブとともに増える。評価器が説明しなければならない失敗は、ここで名前を
/// 付ける。機械が条件に写す(`Machine.apply`)。メッセージの形は、ここにある名前ごとに
/// 1つである。
pub const PrimitiveError = error{
    /// An argument is not of the type the primitive takes.
    WrongType,
    /// The exact result does not fit a fixnum.
    /// R7RS 6.2.3 は、処理系がこれを実装制限の違反として報告してよいとしている。
    /// 多倍長整数(bignum)は段階4で入る。
    IntegerOverflow,
    /// A number of arguments the primitive does not take, such as `(-)`.
    /// 機械が、`Primitive` の個数の範囲から返す。プリミティブの本体は、その範囲を検査
    /// しない。例外は、受け取る個数がほかの引数で決まるプリミティブで、本体がそれを
    /// 検査して返す(`%make-record` は、型のフィールドの数だけ値を受け取る)。
    WrongArgumentCount,
    /// The divisor is zero.
    DivisionByZero,
    /// An argument is of the right type but outside what the primitive takes,
    /// such as an index past the end of a vector.
    OutOfRange,
    /// The allocation would take the heap past its limit.
    /// `Heap` のエラーと同じ名前である。そのまま返してよい。
    HeapLimit,
    /// The host has no memory left.
    /// 条件にならない。機械はそのまま返す。
    OutOfMemory,
};

/// What the machine gives a primitive besides its arguments: the means to
/// allocate.
/// プリミティブは `heap` の API(`cons` `createString` `createVector`)だけで確保し、
/// `std.mem.Allocator` を直接使わない。GC は機械のステップの境目で走り、プリミティブの
/// 途中では走らない(ADR-0031)。
pub const Services = struct {
    /// Where the objects a primitive makes are allocated, and counted.
    heap: *Heap,
    /// Memory a primitive needs only while it runs. It is the arena the machine puts
    /// the arguments in, and is outside the accounting of the heap. A primitive
    /// frees what it takes before it returns, in the reverse order of taking it.
    /// 1行ぶんのアリーナなので、`free` が効くのは最後の確保だけである。
    scratch: std.mem.Allocator,
};

/// A procedure implemented in Zig.
/// それらの表は prim/ にある(`prim/table.zig` が全体を1つの配列にする)。
///
/// 引数の個数の範囲は、省略できない。省略時の既定を可変長にすると、書き忘れた関数が
/// 範囲外の添字を読む。個数は機械が呼び出しの前に検査する(`Machine.apply`)ので、
/// 本体が受け取る `args` は、必ずこの範囲に収まる。
pub const Primitive = struct {
    /// The type of the function that is the primitive.
    pub const Fn = *const fn (services: *const Services, args: []const Value) PrimitiveError!Value;

    /// What the primitive does when it is applied.
    /// 純粋プリミティブと機械操作プリミティブは、呼び出しの規約が違う。前者は `Services`
    /// と引数から値を返し、後者は機械のレジスタを書き換える(docs/design/runtime.md の
    /// 機械操作プリミティブ)。後者の操作は `Machine.apply` にあり、ここには名前だけを置く。
    pub const Body = union(enum) {
        /// A function from the arguments to a value.
        pure: Fn,
        /// An operation the machine carries out on its registers.
        machine: MachineOp,
    };

    name: []const u8,
    /// The fewest arguments the primitive takes.
    min_args: u8,
    /// The most arguments the primitive takes, or null when there is no limit.
    max_args: ?u8,
    body: Body,

    /// Whether the primitive takes `count` arguments.
    pub fn acceptsCount(self: *const Primitive, count: usize) bool {
        if (count < self.min_args) return false;
        const max = self.max_args orelse return true;
        return count <= max;
    }
};

/// The operations of the machine that a primitive can name as its body.
/// 残りの変種は、docs/plans/0014-phase2-core-language.md の「スライス」の表が
/// 機械操作プリミティブを割り当てたスライスが、それぞれ足す。
pub const MachineOp = enum {
    /// `(apply proc arg1 ... args)` (R7RS 6.10).
    apply,
    /// `(with-exception-handler handler thunk)` (R7RS 6.11).
    with_exception_handler,
    /// `(raise obj)` (R7RS 6.11).
    raise,
    /// `(raise-continuable obj)` (R7RS 6.11).
    raise_continuable,
    /// `(error message obj ...)` (R7RS 6.11): makes a condition and raises it
    /// as `raise` does.
    @"error",
    /// `(call-with-current-continuation proc)` and `(call/cc proc)` (R7RS
    /// 6.10).
    call_cc,
    /// `(dynamic-wind before thunk after)` (R7RS 6.10).
    dynamic_wind,
};

/// A procedure made by `lambda`: what the expression means, and the frame it was
/// evaluated in.
/// 呼び出しは `env` を親とするフレームを作り、本体の変数は、そのフレームと、その
/// 親のフレームたちから、レキシカルアドレスで見つかる。
pub const Closure = struct {
    lambda: *const Lambda,
    env: ?*Frame,
};

/// The variables of one call, in the slots the expander assigned: the
/// parameters, then the names the body defines at its start.
/// 余りの引数を受ける仮引数があれば、そのスロットは必須の仮引数の直後にある。
/// `parent` は、クロージャが作られたフレームである。
pub const Frame = struct {
    values: []Value,
    parent: ?*Frame,
};

/// Where a local variable lives: how many frames out from the one being run, and
/// which slot in that frame.
/// 展開器がこれを解決する(docs/design/runtime.md の「環境」)。`u32` は、あふれたとき
/// 展開器が実装制限(R7RS 1.3.2)として報告する幅である。
pub const Address = struct {
    depth: u32,
    index: u32,
};

/// A node of the core IR: what the expander produces and the machine runs
/// (docs/design/runtime.md).
/// ノードは不変で、ノードは配下のノードをポインタで参照する。ノードは展開器が確保
/// した場所にあり、後のスライスがコードを GC ヒープに置くまでは、そこはインタプリタの
/// アリーナである。
pub const Node = union(enum) {
    /// A literal, or the datum of a `quote`.
    constant: Value,
    local_ref: LocalRef,
    /// A global variable: the cell the expander resolved its name to.
    global_ref: *Cell,
    /// `set!` of a local variable.
    /// 変数は値を持っていなければならない。
    local_set: LocalAssign,
    /// The definition of a local variable, at the start of a body.
    /// `uninitialized` を保持しているスロットに、最初の値を与える。
    local_define: LocalAssign,
    global_set: GlobalAssign,
    global_define: GlobalAssign,
    @"if": If,
    /// `begin` and the body of a `lambda`: one or more nodes, the last one's
    /// value is the value of the sequence.
    sequence: []const *const Node,
    lambda: *const Lambda,
    call: Call,
};

/// A local variable read.
/// 名前は、スロットがまだ未初期化のときのメッセージ用である。
pub const LocalRef = struct {
    address: Address,
    name: SymbolId,
};

pub const LocalAssign = struct {
    address: Address,
    name: SymbolId,
    value: *const Node,
};

/// `set!` or the definition of a global variable: the cell to give the value.
/// 展開器が、REPL の束縛の表の規則でセルを選んである(src/env.zig)。
pub const GlobalAssign = struct {
    cell: *Cell,
    value: *const Node,
};

pub const If = struct {
    condition: *const Node,
    consequent: *const Node,
    /// Null when the form had none; a false condition then gives the
    /// unspecified value.
    alternative: ?*const Node,
};

/// What a `lambda` expression means, apart from the frame it is evaluated in.
pub const Lambda = struct {
    /// The number of required parameters: those before the dot, or all of them
    /// when there is no dot.
    /// `rest` が偽なら、呼び出しの引数の個数はこれと等しくなければならない。
    arity: u32,
    /// Whether the procedure takes more arguments than `arity` (R7RS 4.1.4).
    /// 真なら、`arity` 個を超えた引数を呼び出しのたびに新しいリストにして、
    /// 必須の仮引数の直後のスロットに入れる。`(lambda args ...)` は `arity` が 0 で
    /// これが真である。
    rest: bool = false,
    /// The number of slots of a call's frame: the required parameters, the rest
    /// parameter if there is one, then the names the body defines at its start.
    frame_size: u32,
    body: *const Node,

    /// Whether a call with `count` arguments matches the parameters.
    pub fn acceptsCount(self: *const Lambda, count: usize) bool {
        if (self.rest) return count >= self.arity;
        return count == self.arity;
    }
};

/// A procedure call.
/// 演算子を最初に評価し、次にオペランドを左から右へ評価する。
pub const Call = struct {
    operator: *const Node,
    operands: []const *const Node,
};

/// Values already evaluated for a call, most recent first.
/// 不変なので、呼び出しがオペランドを評価している間に捕捉された継続は、何度でも
/// 再開でき、そのたびに同じオペランドから始まる(ADR-0004)。
pub const Args = struct {
    value: Value,
    next: ?*const Args,
};

/// One frame of the continuation: what to do with the value that arrives, and
/// the frame to do it in.
/// フレームは鎖をなし、一度作られたら変更されない。そのため、継続を定数時間で
/// 捕捉できる。
pub const Kont = struct {
    next: ?*const Kont,
    /// The local frame to resume in.
    env: ?*Frame,
    /// The number of frames in the chain from this one, itself included.
    depth: usize,
    step: Step,

    pub const Step = union(enum) {
        /// The value is the condition of this `if`.
        branch: *const If,
        /// The value is dropped, and these nodes run next.
        /// 空にならない。シーケンスの最後のノードは、この継続フレームがすでに無い状態で
        /// 実行される。これにより、末尾位置の呼び出しはフレームを消費しない。
        sequence: []const *const Node,
        local_set: *const LocalAssign,
        local_define: *const LocalAssign,
        global_set: *const GlobalAssign,
        global_define: *const GlobalAssign,
        /// The value is the next one of the call: the operator first, then each
        /// operand.
        /// `args` には、それより前に届いた値が入る。
        call: CallStep,
        /// The value is what the body of a dynamic extent returned; the dynamic
        /// point goes back to this one, and the value passes on as it is.
        /// `with-exception-handler` が、点を積む前の点を持たせて置く(docs/design/runtime.md の
        /// 動的範囲の通常終了)。
        dynamic_exit: ?*const DynPoint,
        /// The value is what a handler called by `raise` or `raise-continuable`
        /// returned.
        handler_return: HandlerReturn,
        /// The value is what the `before` of a `dynamic-wind` returned: the wind
        /// point goes on, and the thunk is called.
        /// 値は捨てる(docs/design/runtime.md の複数値の表の「捨てる」群)。
        wind_before: WindBefore,
        /// The value is what the thunk of a `dynamic-wind` returned: the wind
        /// point comes off, and its `after` is called.
        /// R7RS 6.10 は `after` を `thunk` の動的範囲の外で呼ぶとするので、点を外してから呼ぶ。
        wind_body: *const DynPoint,
        /// The value is what the `after` of a `dynamic-wind` returned; it is
        /// dropped, and this value, which the thunk returned, passes on.
        wind_after: Value,
        /// The value is what an `after` or a `before` called while a
        /// continuation is invoked returned; it is dropped, and the rewind goes
        /// on by one point (docs/design/runtime.md, the progress of a rewind).
        rewind: RewindStep,
    };

    pub const WindBefore = struct {
        /// The point the `dynamic-wind` puts on once `before` returns.
        point: *const DynPoint,
        /// What runs in the extent of `point`.
        thunk: Value,
    };

    pub const RewindStep = struct {
        /// What every frame of one invocation shares.
        state: *const Rewind,
        /// The link of the path whose `before` returned, so that its point goes
        /// on next; null when the rewind is still leaving the points between
        /// the invocation and the common ancestor.
        entered: ?*const WindPath,
        /// The dynamic point this frame was put on at, and where the dynamic
        /// state is when its value arrives.
        /// 巻き戻しの位置は列のレジスタそのものである(docs/design/runtime.md)。これは、
        /// フレームが値を受け取るときの列が、フレームを積んだときの列と同じであるという
        /// 機械の不変条件を、安全ビルドで確かめるためだけに持つ。
        at: ?*const DynPoint,
    };

    pub const HandlerReturn = struct {
        /// The dynamic point of the raise, before the shift was put on it.
        /// `raise-continuable` なら、ここに戻してから値を渡す。
        dyn: ?*const DynPoint,
        /// What was raised.
        /// `raise` のハンドラが戻ったときの二次例外の irritant にする。
        raised: Value,
        /// Whether the raise was `raise-continuable`.
        /// 偽なら、ハンドラが戻ることは二次例外である(R7RS 6.11)。
        continuable: bool,
    };

    pub const CallStep = struct {
        call: *const Call,
        args: ?*const Args,
        /// How many values `args` holds.
        received: usize,
    };
};

/// One point of the dynamic state: the list of what the dynamic extents around
/// the running code have put in place, innermost first (ADR-0016).
/// 点は不変で、親へのリンクで連なる。機械のレジスタが最も内側の点を指し、`null` は
/// 何も置かれていない状態である。現在の例外ハンドラは独立したレジスタでなく、この列から
/// `currentHandler` で導く。点の種別のうち、パラメータの点は、それを使うスライス 2g が
/// 足す。
pub const DynPoint = struct {
    parent: ?*const DynPoint,
    /// The number of points from this one out, itself included.
    /// 継続の起動で共通祖先を求めるために持つ(2e)。`u32` で足りるのは、点が1つ数十
    /// バイトで、ヒープの上限(`heap.max_host_limit` の 1 GiB)に 2^32 個は入らないから
    /// である。
    depth: u32,
    /// The handler point that is the current exception handler at this point,
    /// or null when there is none.
    /// 点を作るときに決め、以後変えない。ハンドラの点では自分自身、ハンドラ切り替えの
    /// 点では切り替え先、それ以外の点では親のものである(ADR-0016 の表)。
    current_handler: ?*const DynPoint,
    kind: Variant,

    pub const Variant = union(enum) {
        /// Installed by `with-exception-handler`: inside this point, the
        /// procedure is the current exception handler.
        handler: Value,
        /// Put on by `raise` and `raise-continuable` while a handler runs: the
        /// current handler becomes this handler point, the one that was current
        /// when the handler being called was installed (R7RS 6.11).
        handler_shift: ?*const DynPoint,
        /// Put on by `dynamic-wind` once `before` returns, and taken off
        /// before `after` is called (R7RS 6.10).
        /// 継続の起動で、この点を出るときに `after` を、入るときに `before` を呼ぶ。どちらも
        /// この点の親の列で呼ぶ(docs/design/runtime.md の巻き戻しの進行)。
        wind: Wind,
    };

    pub const Wind = struct {
        before: Value,
        after: Value,
    };
};

/// The innermost point that `a` and `b` both have, themselves included, or
/// null when they have none in common.
/// 深い側を浅い側の深さまで上り、それから両方を1つずつ上る(docs/design/runtime.md の
/// 動的状態)。点は親へのリンクしか持たないので、深さが要る。
pub fn commonAncestor(a: ?*const DynPoint, b: ?*const DynPoint) ?*const DynPoint {
    var x = a;
    var y = b;
    while (depthOf(x) > depthOf(y)) x = x.?.parent;
    while (depthOf(y) > depthOf(x)) y = y.?.parent;
    while (x != y) {
        x = x.?.parent;
        y = y.?.parent;
    }
    return x;
}

/// The depth of `point`: 0 for no point.
fn depthOf(point: ?*const DynPoint) u32 {
    const p = point orelse return 0;
    return p.depth;
}

/// Whether a wind point lies from `from` out to `ancestor`, `from` included
/// and `ancestor` not.
/// `ancestor` は `from` 自身か、その外側の点か、null でなければならない。
pub fn windBetween(from: ?*const DynPoint, ancestor: ?*const DynPoint) bool {
    var it = from;
    while (it != ancestor) {
        const p = it.?;
        if (p.kind == .wind) return true;
        it = p.parent;
    }
    return false;
}

/// What `call/cc` captures: the continuation and the dynamic state of the
/// call (docs/design/runtime.md, the full continuation).
/// 継続のフレームと動的点はどちらも不変なので、捕捉は2つのポインタを写すだけで、何度でも
/// 起動できる。現在の例外ハンドラは列から導くので、ほかに保存するものは無い(ADR-0016)。
pub const Continuation = struct {
    kont: ?*const Kont,
    dyn: ?*const DynPoint,
};

/// What every frame of one invocation of a continuation shares: where it
/// goes, the value it takes there, and the point where leaving ends and
/// entering starts.
/// 起動ごとに1つ作り、変えない。巻き戻しの途中の `after` と `before` の中で捕捉した継続を
/// 後で起動しても、フレームが指すこれは変わっていないので、その時点から正しく再開する。
pub const Rewind = struct {
    /// Where the value goes, or null for the outermost continuation of the
    /// run, to which the value is delivered as raised (an unhandled raise,
    /// docs/design/runtime.md).
    target: ?*const Continuation,
    value: Value,
    /// The innermost point that the dynamic state of the invocation and of
    /// the target have in common.
    ancestor: ?*const DynPoint,
};

/// One link of the path a rewind enters: the wind points from the common
/// ancestor in to the target, outermost first.
/// 列は親へのリンクしか持たないので、退出を終えたときに目標から上って作る。作った後は
/// 変えず、進入の各段のフレームが共有する。`before` を呼ぶ必要のない点(ハンドラの点など)
/// は入れない。それらは、次の wind 点の親を列に入れるときと、目標の列を入れるときに入る。
pub const WindPath = struct {
    point: *const DynPoint,
    next: ?*const WindPath,
};

/// The current exception handler at `point`: a handler point, or null when no
/// handler is installed.
/// 列は起動直後に空(`null`)である。省略可能型を直接展開せず、必ずこれを通す。空のときに
/// 展開すると、ハンドラの無い状態での送出が安全ビルドで panic する(docs/design/runtime.md
/// の動的状態)。
pub fn currentHandler(point: ?*const DynPoint) ?*const DynPoint {
    const p = point orelse return null;
    return p.current_handler;
}

/// The depth a point put on `parent` has.
pub fn depthAbove(parent: ?*const DynPoint) u32 {
    const p = parent orelse return 1;
    return p.depth + 1;
}

/// The types of the objects that live in the GC heap.
/// それらへのポインタは、GC がたどる参照である(src/trace.zig)。順序は、ヒープが
/// 種別に番号を振る順序である。
pub const heap_types = [_]type{ Pair, Closure, Frame, Kont, Args, String, Vector, Condition, SyntacticEnv, SyntacticBinding, LocalBinding, Cell, DynPoint, Alias, Macro, RecordType, Record, Continuation, Rewind, WindPath };

/// The types that are not in the GC heap but are pointed to from it: the core
/// IR, which until a later slice stays where the expander allocated it, and the
/// procedures implemented in Zig.
/// それらへのポインタはたどらない。
pub const code_types = [_]type{ Node, Lambda, If, LocalAssign, GlobalAssign, Call, Primitive };

/// What a value is, without how it is stored.
pub const Kind = enum { fixnum, boolean, empty_list, symbol, pair, primitive, closure, unspecified, uninitialized, condition, character, string, vector, alias, record, record_type, continuation };

/// The special forms: the syntax the expander turns into core IR itself
/// (ADR-0019).
/// 名前は予約語ではなく、REPL の最上位の束縛である(src/syntax/env.zig)。
pub const Special = enum { define, quote, @"if", lambda, begin, @"set!", @"define-syntax", @"syntax-rules", @"let-syntax", @"letrec-syntax", @"syntax-error" };

/// What an identifier means where it is used (ADR-0019,
/// docs/design/frontend.md).
/// ADR-0019 の6種のうち、補助構文は、それを使うスライスが足す。パターン変数は変種に
/// しない。照合器とテンプレート展開器(src/syntax/rules.zig)が規則ごとの表で引き、構文
/// 環境に束縛しないからである(ADR-0019 の 2026-10-13 の追記)。
pub const Denotation = union(enum) {
    special: Special,
    local: *LocalBinding,
    /// A global variable: the cell that holds its value.
    global: *Cell,
    /// A macro: its transformer and the environment it was defined in.
    macro: *Macro,
};

/// A syntactic environment: the bindings of one rib, and the environment
/// around it.
/// GC ヒープにある。展開の途中では GC が走らない(ADR-0031)ので、展開器が作った
/// 環境はルートにしない。コア IR の節点は環境を指さないので、展開が終われば到達
/// できなくなり、回収される。
pub const SyntacticEnv = struct {
    parent: ?*SyntacticEnv,
    /// How many ribs there are from the top level to this environment, this
    /// one included.
    /// 最上位は 0 で、`lambda` の rib は外側より 1 大きい。局所変数の字句アドレスの
    /// 深さは、参照する側の環境のこの値から、束縛した rib のこの値を引いたものである。
    rib_depth: u32,
    /// The bindings, the newest first.
    /// 探索は先頭から線形に進む。同じ識別子を束縛し直すと、後のものが前のものを隠す。
    bindings: ?*SyntacticBinding,
};

/// One binding of a syntactic environment: an identifier and what it means.
pub const SyntacticBinding = struct {
    /// The identifier: a symbol or an alias.
    id: Value,
    denotation: Denotation,
    next: ?*SyntacticBinding,
};

/// A local variable as the expander sees it: the rib that binds it, and its
/// slot in the frame of a call.
/// 束縛ごとに1つ作り、意味が同じかはこのオブジェクトが同じかで判定する
/// (ADR-0019)。深さは最上位から数えた絶対値であり、利用側からの相対値ではない。
pub const LocalBinding = struct {
    rib_depth: u32,
    index: u32,
};

/// The location of a global variable (docs/design/runtime.md, the cells of the
/// global bindings).
/// GC ヒープにある。コア IR の節点(アリーナにある)はセルを指すが、GC は節点を
/// たどらない。それでも回収されないのは、作られたセルがすべて、REPL の束縛の表か、
/// 遮蔽されたインポートの束縛を持ち続ける表か、`define-syntax` が表から外したセルを
/// 持ち続ける表から到達できるからである(src/env.zig)。
pub const Cell = struct {
    /// The name, for the message of an error.
    name: SymbolId,
    /// The value, or `uninitialized` while the variable is unbound.
    /// 大域変数には「未初期化」の段階が無いので、局所変数の未初期化の目印を、未束縛の
    /// 目印として使う。参照と `set!` は、どちらもこの値を1か所で調べる。
    value: Value,
};

/// An identifier that a macro's template introduced (docs/design/frontend.md,
/// the syntactic environment and identifiers).
/// 別名が束縛されていない環境で解決すると、内側の識別子を `env` で解決する。同じ識別子
/// かどうかは、内側、印、環境の3つで決める(src/syntax/env.zig の `boundIdentifierEq`)。
pub const Alias = struct {
    /// The identifier the template had: a symbol, or an alias of an outer
    /// expansion.
    inner: Value,
    /// The environment the macro was defined in; null is the top level.
    env: ?*SyntacticEnv,
    /// Which application of a macro made the alias.
    /// 適用ごとに新しい値を割り当て、同じ値を2回割り当てない(`Context.newMark`)。
    mark: u64,
};

/// A macro: the rules of its `syntax-rules` and the environment it was
/// defined in.
/// 段階2の変換子は `syntax-rules` だけである。変換子を呼ぶ箇所は
/// src/syntax/rules.zig の `transform` の1か所で、手続き的マクロに広げるときの境界になる。
pub const Macro = struct {
    /// The kind of transformer.
    kind: TransformerKind = .syntax_rules,
    /// The literals: a list of identifiers.
    literals: Value,
    /// The rules: a list of `(pattern template)`.
    /// 形は定義の時点で `rules.compile` が検査してある。
    rules: Value,
    /// Where the identifiers of the patterns and templates are resolved; null is
    /// the top level.
    env: ?*SyntacticEnv,
    /// The identifier that `(syntax-rules ellipsis (literal ...) rule ...)` names
    /// as the ellipsis, or null for `...`.
    /// 指定したとき、`...` はふつうの識別子である。
    ellipsis: ?Value = null,

    /// The kinds of transformer a macro can have.
    /// 段階2は `syntax-rules` だけである。Scheme の手続きを変換子にする種類は、要求が
    /// 出るまで足さない(docs/plans/0014-phase2-core-language.md の 2k の節)。
    pub const TransformerKind = enum { syntax_rules };
};

test {
    std.testing.refAllDecls(@This());
}

test "the current handler of no point is none, and of a point is the one the point holds" {
    try std.testing.expectEqual(null, currentHandler(null));
    var handler: DynPoint = .{ .parent = null, .depth = 1, .current_handler = null, .kind = .{ .handler = .fromFixnum(0) } };
    handler.current_handler = &handler;
    try std.testing.expectEqual(&handler, currentHandler(&handler).?);
    const shift: DynPoint = .{ .parent = &handler, .depth = 2, .current_handler = null, .kind = .{ .handler_shift = null } };
    try std.testing.expectEqual(null, currentHandler(&shift));
}

test "a point is one deeper than its parent, and the first is at depth 1" {
    try std.testing.expectEqual(1, depthAbove(null));
    const p: DynPoint = .{ .parent = null, .depth = 3, .current_handler = null, .kind = .{ .handler_shift = null } };
    try std.testing.expectEqual(4, depthAbove(&p));
}

/// A chain of points for the tests of the dynamic state: `a` at depth 1,
/// `b` a wind point on it, `c` a handler point on `b`, and `d` a wind point
/// on `a` beside `b`.
const TestPoints = struct {
    a: DynPoint = .{ .parent = null, .depth = 1, .current_handler = null, .kind = .{ .handler_shift = null } },
    b: DynPoint = undefined,
    c: DynPoint = undefined,
    d: DynPoint = undefined,

    fn link(self: *TestPoints) void {
        const wind: DynPoint.Variant = .{ .wind = .{ .before = .fromFixnum(0), .after = .fromFixnum(0) } };
        self.b = .{ .parent = &self.a, .depth = 2, .current_handler = null, .kind = wind };
        self.c = .{ .parent = &self.b, .depth = 3, .current_handler = null, .kind = .{ .handler = .fromFixnum(0) } };
        self.d = .{ .parent = &self.a, .depth = 2, .current_handler = null, .kind = wind };
    }
};

test "the common ancestor of two points is the innermost point they share" {
    var t: TestPoints = .{};
    t.link();
    try std.testing.expectEqual(null, commonAncestor(null, null));
    try std.testing.expectEqual(null, commonAncestor(&t.c, null));
    try std.testing.expectEqual(null, commonAncestor(null, &t.d));
    try std.testing.expectEqual(&t.c, commonAncestor(&t.c, &t.c).?);
    // 一方が他方の外側なら、外側の点である。深さが違うので、深い側を先に上る。
    try std.testing.expectEqual(&t.b, commonAncestor(&t.c, &t.b).?);
    try std.testing.expectEqual(&t.b, commonAncestor(&t.b, &t.c).?);
    // 枝が分かれていれば、分かれる前の点である。深さが違っても同じである。
    try std.testing.expectEqual(&t.a, commonAncestor(&t.c, &t.d).?);
    try std.testing.expectEqual(&t.a, commonAncestor(&t.d, &t.c).?);
    try std.testing.expectEqual(&t.a, commonAncestor(&t.b, &t.d).?);
    // 根の違う2つの点は、共通の点を持たない。
    var other: DynPoint = .{ .parent = null, .depth = 1, .current_handler = null, .kind = .{ .handler_shift = null } };
    try std.testing.expectEqual(null, commonAncestor(&t.c, &other));
}

test "a wind point between a point and an ancestor is found, the point included and the ancestor not" {
    var t: TestPoints = .{};
    t.link();
    try std.testing.expect(!windBetween(null, null));
    try std.testing.expect(!windBetween(&t.c, &t.c));
    // `c` 自身はハンドラの点で、その外の `b` が wind 点である。
    try std.testing.expect(windBetween(&t.c, &t.a));
    try std.testing.expect(windBetween(&t.c, null));
    // 始めの点は数え、終わりの点は数えない。
    try std.testing.expect(windBetween(&t.b, &t.a));
    try std.testing.expect(!windBetween(&t.c, &t.b));
    try std.testing.expect(!windBetween(&t.a, null));
}

test "a fixnum reads back as itself" {
    const v: Value = .fromFixnum(-7);
    try std.testing.expectEqual(Kind.fixnum, v.kind());
    try std.testing.expectEqual(-7, v.asFixnum().?);
}

test "a fixnum holds the full i64 range" {
    try std.testing.expectEqual(std.math.maxInt(i64), Value.fromFixnum(std.math.maxInt(i64)).asFixnum().?);
    try std.testing.expectEqual(std.math.minInt(i64), Value.fromFixnum(std.math.minInt(i64)).asFixnum().?);
}

test "the unspecified value is not a fixnum" {
    const v = Value.unspecified_value;
    try std.testing.expectEqual(Kind.unspecified, v.kind());
    try std.testing.expect(v.asFixnum() == null);
}

test "only #f is false" {
    try std.testing.expect(!Value.fromBool(false).isTrue());
    try std.testing.expect(Value.fromBool(true).isTrue());
    try std.testing.expect(Value.fromFixnum(0).isTrue());
    try std.testing.expect(Value.empty_list_value.isTrue());
    try std.testing.expect(Value.unspecified_value.isTrue());
    try std.testing.expect(Value.fromSymbol(@fromBackingInt(@intCast(0))).isTrue());
}

test "the uninitialized marker is its own kind, and is true like any value but #f" {
    const v = Value.uninitialized_value;
    try std.testing.expectEqual(Kind.uninitialized, v.kind());
    try std.testing.expect(v.asFixnum() == null);
    try std.testing.expect(v.asClosure() == null);
    try std.testing.expect(v.isTrue());
    try std.testing.expect(Value.unspecified_value.kind() != v.kind());
}

test "a condition is its own kind, a heap object, and carries its message" {
    var bytes = "went wrong".*;
    var message: String = .{ .bytes = &bytes, .is_ascii = true };
    var c: Condition = .{ .kind = .@"error", .message = .fromString(&message), .irritants = .empty_list_value };
    const v: Value = .fromCondition(&c);
    try std.testing.expectEqual(Kind.condition, v.kind());
    try std.testing.expectEqualStrings("went wrong", v.asCondition().?.messageText());
    try std.testing.expect(v.pointsIntoHeap());
    try std.testing.expect(v.asFixnum() == null);
    try std.testing.expect(v.asClosure() == null);
    try std.testing.expect(Value.fromFixnum(1).asCondition() == null);
    try std.testing.expect(v.isTrue());
}

test "a character holds a scalar value and answers only to its own accessor" {
    const c: Value = .fromCharacter(0x3BB);
    try std.testing.expectEqual(Kind.character, c.kind());
    try std.testing.expectEqual(0x3BB, c.asCharacter().?);
    try std.testing.expect(c.asFixnum() == null);
    try std.testing.expect(c.asString() == null);
    try std.testing.expect(Value.fromFixnum(0x3BB).asCharacter() == null);
    try std.testing.expect(c.isTrue());
    try std.testing.expect(!c.pointsIntoHeap());
    try std.testing.expectEqual(0x10FFFF, Value.fromCharacter(0x10FFFF).asCharacter().?);
}

test "isScalarValue refuses the surrogates and what is past the range" {
    try std.testing.expect(isScalarValue(0));
    try std.testing.expect(isScalarValue(0xD7FF));
    try std.testing.expect(!isScalarValue(0xD800));
    try std.testing.expect(!isScalarValue(0xDFFF));
    try std.testing.expect(isScalarValue(0xE000));
    try std.testing.expect(isScalarValue(0x10FFFF));
    try std.testing.expect(!isScalarValue(0x110000));
}

test "a string and a vector are heap objects, each answering to its own accessor" {
    var bytes = [_]u8{ 'h', 'i' };
    var s: String = .{ .bytes = &bytes, .is_ascii = true };
    const sv: Value = .fromString(&s);
    try std.testing.expectEqual(Kind.string, sv.kind());
    try std.testing.expectEqualStrings("hi", sv.asString().?.bytes);
    try std.testing.expect(sv.pointsIntoHeap());
    try std.testing.expect(sv.asVector() == null);
    var items = [_]Value{.fromFixnum(1)};
    var v: Vector = .{ .items = &items };
    const vv: Value = .fromVector(&v);
    try std.testing.expectEqual(Kind.vector, vv.kind());
    try std.testing.expectEqual(1, vv.asVector().?.items[0].asFixnum().?);
    try std.testing.expect(vv.pointsIntoHeap());
    try std.testing.expect(vv.asString() == null);
    try std.testing.expect(vv.isTrue() and sv.isTrue());
}

test "a record and a record type are heap objects, each answering to its own accessor" {
    var t: RecordType = .{ .name = @fromBackingInt(@intCast(2)), .field_count = 1 };
    const tv: Value = .fromRecordType(&t);
    try std.testing.expectEqual(Kind.record_type, tv.kind());
    try std.testing.expectEqual(&t, tv.asRecordType().?);
    try std.testing.expect(tv.pointsIntoHeap());
    try std.testing.expect(tv.asRecord() == null);
    var fields = [_]Value{.fromFixnum(4)};
    var r: Record = .{ .record_type = &t, .fields = &fields };
    const rv: Value = .fromRecord(&r);
    try std.testing.expectEqual(Kind.record, rv.kind());
    try std.testing.expectEqual(&r, rv.asRecord().?);
    try std.testing.expect(rv.pointsIntoHeap());
    try std.testing.expect(rv.asRecordType() == null);
    try std.testing.expect(rv.asVector() == null);
    try std.testing.expect(Value.fromFixnum(1).asRecord() == null);
    try std.testing.expect(Value.fromFixnum(1).asRecordType() == null);
    try std.testing.expect(rv.isTrue() and tv.isTrue());
}

test "a continuation is a heap object of its own kind" {
    var k: Continuation = .{ .kont = null, .dyn = null };
    const v: Value = .fromContinuation(&k);
    try std.testing.expectEqual(Kind.continuation, v.kind());
    try std.testing.expectEqual(&k, v.asContinuation().?);
    try std.testing.expect(v.pointsIntoHeap());
    try std.testing.expect(v.asClosure() == null);
    try std.testing.expect(Value.fromFixnum(1).asContinuation() == null);
    try std.testing.expect(v.isTrue());
}

test "allAscii looks at every byte" {
    try std.testing.expect(allAscii(""));
    try std.testing.expect(allAscii("abc\x00\x7f"));
    try std.testing.expect(!allAscii("\x80"));
    try std.testing.expect(!allAscii("abc\xff"));
    try std.testing.expect(!allAscii("あ"));
    try std.testing.expect(!allAscii("abcdefghijklあ"));
}

test "a string counts and indexes its characters, not its bytes" {
    const Case = struct { text: []const u8, characters: []const u21 };
    const cases = [_]Case{
        .{ .text = "", .characters = &.{} },
        .{ .text = "a", .characters = &.{'a'} },
        .{ .text = "abc", .characters = &.{ 'a', 'b', 'c' } },
        .{ .text = "あいう", .characters = &.{ 0x3042, 0x3044, 0x3046 } },
        .{ .text = "aあb", .characters = &.{ 'a', 0x3042, 'b' } },
        // 1バイトから4バイトまでの文字が混ざる。
        .{ .text = "aλあ𐀀z", .characters = &.{ 'a', 0x3BB, 0x3042, 0x10000, 'z' } },
        .{ .text = "𐀀𐀀", .characters = &.{ 0x10000, 0x10000 } },
        .{ .text = "\u{80}\u{7ff}\u{800}\u{ffff}\u{10ffff}", .characters = &.{ 0x80, 0x7FF, 0x800, 0xFFFF, 0x10FFFF } },
    };
    for (cases) |c| {
        var bytes: [64]u8 = undefined;
        @memcpy(bytes[0..c.text.len], c.text);
        // 本来のフラグ(ASCII だけなら立つ)と、立てない場合の両方の経路が同じ答えを返す。
        // ASCII の文字列で立てないのは、走査の経路を試すためである。
        for ([_]bool{ allAscii(c.text), false }) |flag| {
            const s: String = .{ .bytes = bytes[0..c.text.len], .is_ascii = flag };
            try std.testing.expectEqual(c.characters.len, s.length());
            for (c.characters, 0..) |ch, i| try std.testing.expectEqual(ch, s.charAt(i).?);
            try std.testing.expectEqual(null, s.charAt(c.characters.len));
            try std.testing.expectEqual(null, s.charAt(c.characters.len + 1));
            try std.testing.expectEqual(null, s.charAt(std.math.maxInt(usize)));
        }
    }
}

test "each kind answers only to its own accessor" {
    const sym: Value = .fromSymbol(@fromBackingInt(@intCast(3)));
    try std.testing.expectEqual(Kind.symbol, sym.kind());
    try std.testing.expectEqual(@as(SymbolId, @fromBackingInt(@intCast(3))), sym.asSymbol().?);
    try std.testing.expect(sym.asFixnum() == null);
    try std.testing.expect(sym.asPair() == null);
    try std.testing.expect(Value.fromFixnum(1).asSymbol() == null);
    try std.testing.expectEqual(Kind.boolean, Value.fromBool(true).kind());
    try std.testing.expectEqual(Kind.empty_list, Value.empty_list_value.kind());
}

test "procedures answer only to their own accessor" {
    const prim: Primitive = .{ .name = "p", .min_args = 0, .max_args = 0, .body = .{ .pure = struct {
        fn f(_: *const Services, _: []const Value) PrimitiveError!Value {
            return .unspecified_value;
        }
    }.f } };
    const pv: Value = .fromPrimitive(&prim);
    try std.testing.expectEqual(Kind.primitive, pv.kind());
    try std.testing.expectEqualStrings("p", pv.asPrimitive().?.name);
    try std.testing.expect(pv.asClosure() == null);
    try std.testing.expect(pv.isTrue());
    const body: Node = .{ .constant = .unspecified_value };
    const lambda: Lambda = .{ .arity = 0, .frame_size = 0, .body = &body };
    var closure: Closure = .{ .lambda = &lambda, .env = null };
    const cv: Value = .fromClosure(&closure);
    try std.testing.expectEqual(Kind.closure, cv.kind());
    try std.testing.expectEqual(&closure, cv.asClosure().?);
    try std.testing.expect(cv.asPrimitive() == null);
    try std.testing.expect(Value.fromFixnum(1).asClosure() == null);
}

test "a node tree and a continuation chain can be built from the layouts" {
    const x: SymbolId = @fromBackingInt(@intCast(0));
    const one: Node = .{ .constant = .fromFixnum(1) };
    const reference: Node = .{ .local_ref = .{ .address = .{ .depth = 1, .index = 2 }, .name = x } };
    const operands = [_]*const Node{&one};
    const call: Node = .{ .call = .{ .operator = &reference, .operands = &operands } };
    try std.testing.expectEqual(1, call.call.operands[0].constant.asFixnum().?);
    try std.testing.expectEqual(2, call.call.operator.local_ref.address.index);
    const base: Kont = .{ .next = null, .env = null, .depth = 1, .step = .{ .branch = &.{ .condition = &one, .consequent = &one, .alternative = null } } };
    const top: Kont = .{ .next = &base, .env = null, .depth = base.depth + 1, .step = .{ .call = .{ .call = &call.call, .args = null, .received = 0 } } };
    try std.testing.expectEqual(2, top.depth);
    try std.testing.expectEqual(&base, top.next.?);
}

test "a primitive takes the numbers of arguments from its minimum to its maximum" {
    const nop = struct {
        fn f(_: *const Services, _: []const Value) PrimitiveError!Value {
            return .unspecified_value;
        }
    }.f;
    const one_or_two: Primitive = .{ .name = "a", .min_args = 1, .max_args = 2, .body = .{ .pure = &nop } };
    try std.testing.expect(!one_or_two.acceptsCount(0));
    try std.testing.expect(one_or_two.acceptsCount(1));
    try std.testing.expect(one_or_two.acceptsCount(2));
    try std.testing.expect(!one_or_two.acceptsCount(3));
    const none: Primitive = .{ .name = "b", .min_args = 0, .max_args = 0, .body = .{ .pure = &nop } };
    try std.testing.expect(none.acceptsCount(0));
    try std.testing.expect(!none.acceptsCount(1));
    // 上限がなければ、`u8` を超える個数でも受け付ける。
    const any: Primitive = .{ .name = "c", .min_args = 0, .max_args = null, .body = .{ .pure = &nop } };
    try std.testing.expect(any.acceptsCount(0));
    try std.testing.expect(any.acceptsCount(1000));
    const two_or_more: Primitive = .{ .name = "d", .min_args = 2, .max_args = null, .body = .{ .pure = &nop } };
    try std.testing.expect(!two_or_more.acceptsCount(1));
    try std.testing.expect(two_or_more.acceptsCount(2));
    try std.testing.expect(two_or_more.acceptsCount(1000));
    // `u8` の上限は、usize の個数と比べても回り込まない。
    const max: Primitive = .{ .name = "e", .min_args = 0, .max_args = 255, .body = .{ .pure = &nop } };
    try std.testing.expect(max.acceptsCount(255));
    try std.testing.expect(!max.acceptsCount(256));
}

test "a lambda takes exactly its arity, or with a rest parameter its arity or more" {
    const body: Node = .{ .constant = .unspecified_value };
    const two: Lambda = .{ .arity = 2, .frame_size = 2, .body = &body };
    try std.testing.expect(!two.acceptsCount(1));
    try std.testing.expect(two.acceptsCount(2));
    try std.testing.expect(!two.acceptsCount(3));
    const none: Lambda = .{ .arity = 0, .frame_size = 0, .body = &body };
    try std.testing.expect(none.acceptsCount(0));
    try std.testing.expect(!none.acceptsCount(1));
    // `(lambda (a b . r) ...)`: 2 個ちょうどから受け付け、上限はない。
    const two_or_more: Lambda = .{ .arity = 2, .rest = true, .frame_size = 3, .body = &body };
    try std.testing.expect(!two_or_more.acceptsCount(0));
    try std.testing.expect(!two_or_more.acceptsCount(1));
    try std.testing.expect(two_or_more.acceptsCount(2));
    try std.testing.expect(two_or_more.acceptsCount(3));
    try std.testing.expect(two_or_more.acceptsCount(1000));
    // `(lambda args ...)`: 0 個から受け付ける。
    const any: Lambda = .{ .arity = 0, .rest = true, .frame_size = 1, .body = &body };
    try std.testing.expect(any.acceptsCount(0));
    try std.testing.expect(any.acceptsCount(1000));
    // `u32` の個数は、usize の個数と比べても回り込まない。
    const wide: Lambda = .{ .arity = std.math.maxInt(u32), .frame_size = std.math.maxInt(u32), .body = &body };
    try std.testing.expect(wide.acceptsCount(std.math.maxInt(u32)));
    try std.testing.expect(!wide.acceptsCount(@as(usize, std.math.maxInt(u32)) + 1));
}

/// One of each kind of value, and a second distinct object for each kind that
/// lives in a place. The tests of `isEqv` compare every pair of them.
const Samples = struct {
    pair_a: Pair = .{ .car = .{ .fixnum = 1 }, .cdr = .empty_list },
    // 中身が pair_a と同じで、別の場所にある。
    pair_b: Pair = .{ .car = .{ .fixnum = 1 }, .cdr = .empty_list },
    bytes_a: [2]u8 = .{ 'h', 'i' },
    bytes_b: [2]u8 = .{ 'h', 'i' },
    string_a: String = undefined,
    string_b: String = undefined,
    items_a: [1]Value = .{.{ .fixnum = 1 }},
    items_b: [1]Value = .{.{ .fixnum = 1 }},
    vector_a: Vector = undefined,
    vector_b: Vector = undefined,
    prim_a: Primitive = .{ .name = "a", .min_args = 0, .max_args = 0, .body = .{ .pure = &nop } },
    prim_b: Primitive = .{ .name = "a", .min_args = 0, .max_args = 0, .body = .{ .pure = &nop } },
    body: Node = .{ .constant = .unspecified },
    lambda: Lambda = undefined,
    closure_a: Closure = undefined,
    closure_b: Closure = undefined,
    message: String = undefined,
    condition_a: Condition = undefined,
    condition_b: Condition = undefined,
    // 名前とフィールドの数が同じ2つの型。
    record_type_a: RecordType = .{ .name = @fromBackingInt(@intCast(0)), .field_count = 1 },
    record_type_b: RecordType = .{ .name = @fromBackingInt(@intCast(0)), .field_count = 1 },
    fields_a: [1]Value = .{.{ .fixnum = 1 }},
    fields_b: [1]Value = .{.{ .fixnum = 1 }},
    record_a: Record = undefined,
    record_b: Record = undefined,
    // 同じ継続と列を捕捉した2つの継続。
    continuation_a: Continuation = .{ .kont = null, .dyn = null },
    continuation_b: Continuation = .{ .kont = null, .dyn = null },

    fn nop(_: *const Services, _: []const Value) PrimitiveError!Value {
        return .unspecified_value;
    }

    /// Fills in what points into the struct itself. The struct must not move
    /// after this.
    fn link(self: *Samples) void {
        self.string_a = .{ .bytes = &self.bytes_a, .is_ascii = true };
        self.string_b = .{ .bytes = &self.bytes_b, .is_ascii = true };
        self.vector_a = .{ .items = &self.items_a };
        self.vector_b = .{ .items = &self.items_b };
        self.lambda = .{ .arity = 0, .frame_size = 0, .body = &self.body };
        self.closure_a = .{ .lambda = &self.lambda, .env = null };
        self.closure_b = .{ .lambda = &self.lambda, .env = null };
        self.message = .{ .bytes = &self.bytes_a, .is_ascii = true };
        // 中身が同じ2つの条件。
        self.condition_a = .{ .kind = .@"error", .message = .fromString(&self.message), .irritants = .empty_list_value };
        self.condition_b = .{ .kind = .@"error", .message = .fromString(&self.message), .irritants = .empty_list_value };
        // 型もフィールドの値も同じ2つのレコード。
        self.record_a = .{ .record_type = &self.record_type_a, .fields = &self.fields_a };
        self.record_b = .{ .record_type = &self.record_type_a, .fields = &self.fields_b };
    }

    /// Every sample, each different from all the others in the sense of `eqv?`.
    fn all(self: *Samples) [32]Value {
        return .{
            .fromFixnum(0),
            .fromFixnum(1),
            .fromFixnum(97),
            .fromFixnum(std.math.maxInt(i64)),
            .fromFixnum(std.math.minInt(i64)),
            .fromBool(true),
            .fromBool(false),
            .empty_list_value,
            .fromSymbol(@fromBackingInt(@intCast(0))),
            .fromSymbol(@fromBackingInt(@intCast(1))),
            .unspecified_value,
            .uninitialized_value,
            .fromCharacter('a'),
            .fromCharacter('b'),
            .{ .pair = &self.pair_a },
            .{ .pair = &self.pair_b },
            .fromString(&self.string_a),
            .fromString(&self.string_b),
            .fromVector(&self.vector_a),
            .fromVector(&self.vector_b),
            .fromPrimitive(&self.prim_a),
            .fromPrimitive(&self.prim_b),
            .fromClosure(&self.closure_a),
            .fromClosure(&self.closure_b),
            .fromCondition(&self.condition_a),
            .fromCondition(&self.condition_b),
            .fromRecordType(&self.record_type_a),
            .fromRecordType(&self.record_type_b),
            .fromRecord(&self.record_a),
            .fromRecord(&self.record_b),
            .fromContinuation(&self.continuation_a),
            .fromContinuation(&self.continuation_b),
        };
    }
};

test "a value is eqv? to itself and to nothing else among the samples" {
    var s: Samples = .{};
    s.link();
    const all = s.all();
    for (all, 0..) |a, i| {
        for (all, 0..) |b, j| {
            try std.testing.expectEqual(i == j, a.isEqv(b));
        }
    }
}

test "values of the kinds that are compared by what they are are eqv? when built apart" {
    try std.testing.expect(Value.fromFixnum(-7).isEqv(.fromFixnum(-7)));
    try std.testing.expect(Value.fromBool(true).isEqv(.fromBool(true)));
    try std.testing.expect(Value.fromBool(false).isEqv(.fromBool(false)));
    try std.testing.expect(Value.fromCharacter(0x3BB).isEqv(.fromCharacter(0x3BB)));
    const id: SymbolId = @fromBackingInt(@intCast(5));
    try std.testing.expect(Value.fromSymbol(id).isEqv(.fromSymbol(id)));
    try std.testing.expect(Value.empty_list_value.isEqv(.empty_list_value));
    try std.testing.expect(Value.unspecified_value.isEqv(.unspecified_value));
}

test "the same object is eqv? to itself, but an object with the same contents is not" {
    var s: Samples = .{};
    s.link();
    const pair: Value = .{ .pair = &s.pair_a };
    try std.testing.expect(pair.isEqv(.{ .pair = &s.pair_a }));
    try std.testing.expect(!pair.isEqv(.{ .pair = &s.pair_b }));
    const string: Value = .fromString(&s.string_a);
    try std.testing.expect(string.isEqv(.fromString(&s.string_a)));
    try std.testing.expect(!string.isEqv(.fromString(&s.string_b)));
    const vector: Value = .fromVector(&s.vector_a);
    try std.testing.expect(vector.isEqv(.fromVector(&s.vector_a)));
    try std.testing.expect(!vector.isEqv(.fromVector(&s.vector_b)));
}

test "eq? agrees with eqv? on every pair of the samples" {
    // Why: R7RS 6.1 は、`eq?` が真を返してよいのは `eqv?` が真のときだけとする。段階1の
    // 値では2つは一致する。段階4で数の種類が増えて `eqv?` が分かれたとき、この対応を
    // どちらに寄せるかを決め直す。
    var s: Samples = .{};
    s.link();
    const all = s.all();
    for (all) |a| {
        for (all) |b| try std.testing.expectEqual(a.isEqv(b), a.isEq(b));
    }
}
