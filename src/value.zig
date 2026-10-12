//! The Scheme value.
//!
//! タグ付き共用体である(ADR-0002)。種別の全体は docs/design/runtime.md の表に
//! あり、各種別は、それを最初に作るスライスで加わる。スライス 1a は固定長の整数、
//! 1b は未規定値、1c は真偽値・空リスト・シンボル・ペア、1d は2種類の手続きを持ち、
//! 1e は未定義の変数の目印を加える。スライス 1f は条件オブジェクトと、コア IR と
//! 継続のレイアウトを加える。この2つは値ではないが、同じようにたどられる。
//! スライス 1g は、ペア・クロージャ・フレーム・継続フレーム・引数リストを GC ヒープ
//! (src/heap.zig)に置く。スライス 1h は文字・文字列・ベクタを加える。
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
    condition: *Condition,
    /// A character: a Unicode scalar value (R7RS 6.6), so never a surrogate.
    character: u21,
    /// A string.
    /// GC ヒープにある。
    string: *String,
    /// A vector.
    /// GC ヒープにある。
    vector: *Vector,

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

    /// Whether the value refers to an object in the GC heap, which the collector
    /// has to be told about if the value is kept anywhere it cannot see.
    pub fn pointsIntoHeap(self: Value) bool {
        return switch (self) {
            .pair, .closure, .string, .vector => true,
            .fixnum, .boolean, .empty_list, .symbol, .primitive, .unspecified, .uninitialized, .condition, .character => false,
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

/// The object an error is.
/// スライス 1f はメッセージだけを持つ。段階2で、エラーの種類と、`error` が取る
/// irritant を加える(R7RS 6.11)。
pub const Condition = struct {
    message: []const u8,
};

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
    /// 機械が、`Primitive` の個数の範囲から返す。プリミティブの本体は、個数を検査
    /// しない。
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
/// `call` が受け取る `args` は、必ずこの範囲に収まる。
pub const Primitive = struct {
    /// The type of the function that is the primitive.
    pub const Fn = *const fn (services: *const Services, args: []const Value) PrimitiveError!Value;

    name: []const u8,
    /// The fewest arguments the primitive takes.
    min_args: u8,
    /// The most arguments the primitive takes, or null when there is no limit.
    max_args: ?u8,
    call: Fn,

    /// Whether the primitive takes `count` arguments.
    pub fn acceptsCount(self: *const Primitive, count: usize) bool {
        if (count < self.min_args) return false;
        const max = self.max_args orelse return true;
        return count <= max;
    }
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
    /// A global variable, found by name until stage 2 gives it a cell.
    global_ref: SymbolId,
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

pub const GlobalAssign = struct {
    name: SymbolId,
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
    };

    pub const CallStep = struct {
        call: *const Call,
        args: ?*const Args,
        /// How many values `args` holds.
        received: usize,
    };
};

/// The types of the objects that live in the GC heap.
/// それらへのポインタは、GC がたどる参照である(src/trace.zig)。順序は、ヒープが
/// 種別に番号を振る順序である。
pub const heap_types = [_]type{ Pair, Closure, Frame, Kont, Args, String, Vector };

/// The types that are not in the GC heap but are pointed to from it: the core
/// IR, which until a later slice stays where the expander allocated it, the
/// procedures implemented in Zig, and the conditions.
/// それらへのポインタはたどらない。
pub const code_types = [_]type{ Node, Lambda, If, LocalAssign, GlobalAssign, Call, Primitive, Condition };

/// What a value is, without how it is stored.
pub const Kind = enum { fixnum, boolean, empty_list, symbol, pair, primitive, closure, unspecified, uninitialized, condition, character, string, vector };

test {
    std.testing.refAllDecls(@This());
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

test "a condition is its own kind, and carries its message" {
    var c: Condition = .{ .message = "went wrong" };
    const v: Value = .fromCondition(&c);
    try std.testing.expectEqual(Kind.condition, v.kind());
    try std.testing.expectEqualStrings("went wrong", v.asCondition().?.message);
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
    const prim: Primitive = .{ .name = "p", .min_args = 0, .max_args = 0, .call = struct {
        fn f(_: *const Services, _: []const Value) PrimitiveError!Value {
            return .unspecified_value;
        }
    }.f };
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
    const one_or_two: Primitive = .{ .name = "a", .min_args = 1, .max_args = 2, .call = &nop };
    try std.testing.expect(!one_or_two.acceptsCount(0));
    try std.testing.expect(one_or_two.acceptsCount(1));
    try std.testing.expect(one_or_two.acceptsCount(2));
    try std.testing.expect(!one_or_two.acceptsCount(3));
    const none: Primitive = .{ .name = "b", .min_args = 0, .max_args = 0, .call = &nop };
    try std.testing.expect(none.acceptsCount(0));
    try std.testing.expect(!none.acceptsCount(1));
    // 上限がなければ、`u8` を超える個数でも受け付ける。
    const any: Primitive = .{ .name = "c", .min_args = 0, .max_args = null, .call = &nop };
    try std.testing.expect(any.acceptsCount(0));
    try std.testing.expect(any.acceptsCount(1000));
    const two_or_more: Primitive = .{ .name = "d", .min_args = 2, .max_args = null, .call = &nop };
    try std.testing.expect(!two_or_more.acceptsCount(1));
    try std.testing.expect(two_or_more.acceptsCount(2));
    try std.testing.expect(two_or_more.acceptsCount(1000));
    // `u8` の上限は、usize の個数と比べても回り込まない。
    const max: Primitive = .{ .name = "e", .min_args = 0, .max_args = 255, .call = &nop };
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
    prim_a: Primitive = .{ .name = "a", .min_args = 0, .max_args = 0, .call = &nop },
    prim_b: Primitive = .{ .name = "a", .min_args = 0, .max_args = 0, .call = &nop },
    body: Node = .{ .constant = .unspecified },
    lambda: Lambda = undefined,
    closure_a: Closure = undefined,
    closure_b: Closure = undefined,
    condition_a: Condition = .{ .message = "m" },
    condition_b: Condition = .{ .message = "m" },

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
    }

    /// Every sample, each different from all the others in the sense of `eqv?`.
    fn all(self: *Samples) [26]Value {
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
