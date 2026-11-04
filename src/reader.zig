//! Reads the external representation of data (R7RS 7.1.2).
//!
//! 読むのは、10 進整数、真偽値、識別子(縦棒で囲んだものと、ASCII でない文字を含むものを含む)、文字、文字列、丸括弧のリスト、ベクタ、`'` と
//! `` ` `` と `,` と `,@` の略記である。行コメント、入れ子のブロックコメント `#|` `|#`、
//! データコメント `#;` を読み飛ばす。畳み込みの状態(`fold_case`)を持ち、真のとき識別子と
//! 文字名を畳み込む(識別子は Unicode の単純な畳み込み、文字名は ASCII の小文字化)。
//! 指令 `#!fold-case` と `#!no-fold-case` が、この状態を切り替える。
//! 読めない記法は `InvalidToken` などの誤りにする。
//! `Value` を直接作る。ペアは渡された GC ヒープに確保し、識別子は渡されたシンボル表に
//! インターンする。読み取りの途中でヒープは GC しないので、`next` が返した時点で
//! データは完全な形をしている。何からも参照されなくなればすぐにゴミになるが、
//! `quote` が、参照を持つ定義にデータを渡すことはある。
//!
//! ベクタ `#(` ... `)` はリストと同じように集め、閉じたときにヒープに作る。
//! ベクタの中のドットはエラーである。バイトベクタ `#u8(` ... `)` も同じ形で集める。要素は
//! 0 から 255 までの 10 進整数でなければならず、読んだ時点で検査する(R7RS 7.1.2 の
//! <bytevector> は <byte> を並べる)。
//!
//! ネストは Zig の再帰でなく、明示的なスタックで処理する。どこまで深く進めるかは
//! 入力の深さで決まる(docs/design/runtime.md)。

const std = @import("std");
const value_mod = @import("value.zig");
const Value = value_mod.Value;
const Heap = @import("heap.zig").Heap;
const char_syntax = @import("char_syntax.zig");
const string_syntax = @import("string_syntax.zig");
const positions_mod = @import("positions.zig");
const num = @import("num/number.zig");
const unicode = @import("unicode/props.zig");

/// What the reader cannot read: the input is not a datum.
pub const SyntaxError = error{
    /// The input ended inside a list or after a `'`, `` ` ``, `,` or `,@`.
    /// REPL はこれを見て、続きの 1 行を求められる(ADR-0014)。そのため、ほかの構文
    /// エラーとは分けてある。
    Incomplete,
    UnexpectedCloseParen,
    /// A `'`, `` ` ``, `,` or `,@` followed by `)`: there is nothing to abbreviate.
    MissingDatum,
    /// A `#;` followed by `)`: there is no datum to comment out.
    /// R7RS 7.1.1 の <comment> は `#;` <intertoken space> <datum> で、データを欠けない。
    MissingCommentedDatum,
    /// A `.` that does not stand between the last element of a list and the
    /// one datum that ends it: at the top level, first in a list, after a `'`,
    /// before the `)`, or followed by more than one datum.
    UnexpectedDot,
    /// Text this reader cannot read as a datum.
    InvalidToken,
    /// A string with a backslash that begins no escape (src/string_syntax.zig).
    InvalidEscape,
    /// An identifier between vertical lines with a backslash that begins no
    /// escape (src/string_syntax.zig).
    InvalidSymbolEscape,
    /// A `#\` that does not begin a character (src/char_syntax.zig).
    InvalidCharacter,
    /// Input that is not valid UTF-8: the whole input, or, when the reader is used
    /// on its own, the bytes of a string literal (src/string_syntax.zig).
    /// 通常の入口(インタプリタ、WASM の境界)は、リーダに渡す前に入力全体を検査する。
    /// それでもリーダは、生のバイトから文字列を作る前に自分で確かめる。
    InvalidUtf8,
    /// A decimal integer outside the fixnum range.
    /// 数の綴りを `num.parse` で読むようになってから、リーダはこれを返さない。
    /// `src/sucheme.zig` の `switch` が参照しているので、誤りの集合には残している。
    IntegerOutOfRange,
    /// An element of a `#u8(` that is not an integer from 0 to 255 (R7RS 7.1.2, <byte>).
    InvalidByte,
    /// A `#<n>#` with no `#<n>=` before it in the same outermost datum (R7RS 2.4).
    UndefinedLabel,
    /// A second `#<n>=` for a number already labelled in the same outermost datum.
    DuplicateLabel,
    /// A `#<n>=` followed by `)`, or labelling only a reference to itself (`#0=#0#`,
    /// which R7RS 2.4 calls an error).
    MissingLabeledDatum,
    /// Code that is circular outside a literal (R7RS 2.4): what a reader of code
    /// rejects.
    CircularCode,
};

pub const Error = error{
    OutOfMemory,
    /// The pairs of the datum do not fit in the heap.
    HeapLimit,
} || SyntaxError;

/// The message for a failure to read.
/// REPL と、ライブラリのファイルの読み込みが、同じ文言を使う。
pub fn describe(e: SyntaxError) []const u8 {
    return switch (e) {
        error.Incomplete => "unexpected end of input",
        error.UnexpectedCloseParen => "unexpected )",
        error.MissingDatum => "quote needs a datum",
        error.MissingCommentedDatum => "datum comment needs a datum",
        error.UnexpectedDot => "unexpected .",
        error.InvalidEscape => "invalid escape in string",
        error.InvalidSymbolEscape => "invalid escape in identifier",
        error.InvalidCharacter => "invalid character",
        error.InvalidUtf8 => "invalid UTF-8 input",
        error.InvalidToken => "unreadable token",
        error.IntegerOutOfRange => "integer out of range",
        error.InvalidByte => "invalid byte in bytevector",
        error.UndefinedLabel => "reference to an undefined datum label",
        error.DuplicateLabel => "datum label defined twice",
        error.MissingLabeledDatum => "datum label needs a datum",
        error.CircularCode => "circular reference outside a literal",
    };
}

/// Where what the reader builds goes.
/// これらは呼び出しより長く生きる。
pub const Sink = struct {
    /// Where the pairs go, and where the names of new symbols are kept.
    /// 読み取りの途中でヒープは GC しないので、呼び出し側が受け取る時点でデータは
    /// 完全な形をしている。
    heap: *Heap,
    /// Where the positions of the lists read are kept, with the number of the
    /// file they are read from, or null when they are not kept.
    /// 記録するのは、括弧で書いたリストと略記(`'x` など)が作る先頭のペアの位置である。
    positions: ?Recording = null,

    pub const Recording = struct {
        table: *positions_mod.Table,
        file: u32,
    };
};

/// A prefix that abbreviates a form (R7RS 2.4).
const Abbreviation = enum {
    quote,
    quasiquote,
    unquote,
    unquote_splicing,

    /// The symbol that heads the form.
    fn symbolName(self: Abbreviation) []const u8 {
        return switch (self) {
            .quote => "quote",
            .quasiquote => "quasiquote",
            .unquote => "unquote",
            .unquote_splicing => "unquote-splicing",
        };
    }
};

/// What is open at this point of the input.
const Frame = union(enum) {
    list: List,
    /// A `#(` whose elements so far are these.
    /// ドットはベクタの中では意味を持たないので、持っておくのは要素だけでよい。
    vector: std.ArrayList(Value),
    /// A `#u8(` whose bytes so far are these.
    bytevector: std.ArrayList(u8),
    /// A `'`, `` ` ``, `,` or `,@` waiting for its datum, and where it was.
    abbreviation: struct { kind: Abbreviation, at: positions_mod.Location },
    /// A `#;` waiting for the datum it comments out, and how many labels there
    /// were when it began.
    /// データが完成したら、略記を閉じたあとで捨てる。`#;'a` は `'a` を捨てる。捨てたデータの
    /// 中で定義したラベルも、一緒に捨てる。
    datum_comment: usize,
    /// A `#<n>=` waiting for the datum it labels: the label's place in `Labels.entries`.
    label: usize,

    const List = struct {
        /// Where the `(` was.
        at: positions_mod.Location,
        /// The elements so far.
        items: std.ArrayList(Value) = .empty,
        /// Whether a `.` has been read, so that the next datum is the tail.
        dot: bool = false,
        /// The datum after the dot, once it has been read.
        tail: ?Value = null,

        /// Takes a finished datum as the next element, or as the tail if a dot
        /// came before it.
        /// ドットの後の 2 つ目のデータは、エラーである。
        fn add(self: *List, scratch: std.mem.Allocator, datum: Value) Error!void {
            if (!self.dot) return self.items.append(scratch, datum);
            if (self.tail != null) return error.UnexpectedDot;
            self.tail = datum;
        }
    };
};

/// The datum labels of one outermost datum (R7RS 2.4).
///
/// まだ読み終えていないラベルへの参照(循環)には、そのラベルの目印を置く。目印は
/// ヒープに作る新しいペアで、ほかのどのデータとも `eq?` で異なる。最も外側のデータを
/// 読み終えたら、`resolve` が1回辿って、目印をラベルのデータに置き換える。ラベルごとに
/// 辿ると、入れ子のラベルが多い入力で費用が大きさの2乗になるので、まとめて1回にする。
/// 読み取りの途中でヒープは GC しない(`Sink`)ので、目印はルートに入れなくてよい。
/// 表は `scratch` にあり、読み取りの作業スタック(`open`)と同じく、入力の大きさで抑えられる。
const Labels = struct {
    entries: std.ArrayList(Entry) = .empty,
    /// Where each number is in `entries`.
    by_number: std.AutoHashMapUnmanaged(u64, usize) = .empty,
    /// Whose placeholder each placeholder pair is: its place in `entries`.
    by_placeholder: std.AutoHashMapUnmanaged(usize, usize) = .empty,

    const Entry = struct {
        number: u64,
        /// The datum, once it has been read.
        value: ?Value = null,
        /// What references read before the datum was finished stand for.
        placeholder: ?Value = null,
    };

    /// Starts a label for `number`, and returns its place.
    fn define(self: *Labels, scratch: std.mem.Allocator, number: u64) Error!usize {
        const slot = try self.by_number.getOrPut(scratch, number);
        if (slot.found_existing) return error.DuplicateLabel;
        slot.value_ptr.* = self.entries.items.len;
        try self.entries.append(scratch, .{ .number = number });
        return self.entries.items.len - 1;
    }

    /// What a reference to `number` reads as: the labelled datum, or the label's
    /// placeholder while the datum is still being read.
    fn reference(self: *Labels, scratch: std.mem.Allocator, sink: Sink, number: u64) Error!Value {
        const i = self.by_number.get(number) orelse return error.UndefinedLabel;
        const entry = &self.entries.items[i];
        if (entry.value) |v| return v;
        if (entry.placeholder) |p| return p;
        const p = try sink.heap.cons(Value.empty_list_value, Value.empty_list_value);
        try self.by_placeholder.put(scratch, @intFromPtr(p.asPair().?), i);
        entry.placeholder = p;
        return p;
    }

    /// Finishes the label at `i` with `datum`.
    /// ラベルの付いたものが、そのラベル自身への参照だけなら、誤りである(R7RS 2.4 の
    /// `#<n>= #<n>#`)。間に別のラベルを挟んだ `#0=#1=#0#` も同じである。
    fn finish(self: *Labels, i: usize, datum: Value) Error!void {
        if (self.entries.items[i].placeholder) |p| {
            const r = self.resolved(datum) orelse return error.MissingLabeledDatum;
            if (r.isEq(p)) return error.MissingLabeledDatum;
        }
        self.entries.items[i].value = datum;
    }

    /// `v` with placeholders followed to the data their labels stand for, as far
    /// as those are finished, or null when that goes round in a circle.
    /// 目印が指すラベルのデータが、また目印であることがある(`#1=(#0=#1#)` の `#0#`)。
    /// 辿る回数はラベルの数で抑える。
    fn resolved(self: *const Labels, v: Value) ?Value {
        var current = v;
        var steps: usize = 0;
        while (self.labelOf(current)) |i| : (steps += 1) {
            if (steps > self.entries.items.len) return null;
            current = self.entries.items[i].value orelse return current;
        }
        return current;
    }

    /// The place of the label whose placeholder `v` is, if it is one.
    fn labelOf(self: *const Labels, v: Value) ?usize {
        const p = v.asPair() orelse return null;
        return self.by_placeholder.get(@intFromPtr(p));
    }

    /// Forgets the labels from `len` on: those of a datum that a `#;` discarded.
    fn truncate(self: *Labels, len: usize) void {
        for (self.entries.items[len..]) |entry| {
            _ = self.by_number.remove(entry.number);
            if (entry.placeholder) |p| _ = self.by_placeholder.remove(@intFromPtr(p.asPair().?));
        }
        self.entries.shrinkRetainingCapacity(len);
    }

    /// Replaces every placeholder in `datum` with the datum its label stands for.
    /// データは循環しうるので、訪問済みの集合を持ち、明示的なスタックで辿る。
    fn resolve(self: *const Labels, scratch: std.mem.Allocator, datum: Value) Error!void {
        if (self.by_placeholder.count() == 0) return;
        var visited: std.AutoHashMapUnmanaged(usize, void) = .empty;
        var stack: std.ArrayList(Value) = .empty;
        try stack.append(scratch, datum);
        while (stack.pop()) |v| {
            if (v.asPair()) |pair| {
                if ((try visited.getOrPut(scratch, @intFromPtr(pair))).found_existing) continue;
                try self.replaceIn(scratch, &stack, &pair.car);
                try self.replaceIn(scratch, &stack, &pair.cdr);
            } else if (v.asVector()) |vector| {
                if ((try visited.getOrPut(scratch, @intFromPtr(vector))).found_existing) continue;
                for (vector.items) |*slot| try self.replaceIn(scratch, &stack, slot);
            }
        }
    }

    /// Replaces the placeholder in `slot`, if it holds one, and leaves what it
    /// then holds for `resolve` to walk.
    fn replaceIn(self: *const Labels, scratch: std.mem.Allocator, stack: *std.ArrayList(Value), slot: *Value) Error!void {
        if (self.labelOf(slot.*) != null) slot.* = self.resolved(slot.*) orelse return error.MissingLabeledDatum;
        try stack.append(scratch, slot.*);
    }
};

/// Fails with `CircularCode` when `datum`, read as code, is circular outside a
/// literal (R7RS 2.4).
///
/// 辿るのはペアで、要素の位置(最も外側か、ペアの car)で出会う `(quote x)` の形(car が
/// シンボル `quote` で、cdr が1要素のリスト)の中には入らない。cdr として出会う同じ形は、
/// quote の式ではなくリストの尾部(`(lambda quote ...)` の仮引数の並びや本体)なので、中に
/// 入る。ベクタの中にも入らない。ベクタは自分自身に評価されるリテラルだからである
/// (R7RS 4.1.2)。
/// quasiquote の形の中では、quote の形とベクタの中にも入る。R7RS 2.4 は、quasiquote が
/// 循環を含むこと自体を誤りとしており、quasiquote はベクタの中まで辿るからである。
/// 深さ優先で、いま辿っている経路の上のものと、辿り終えたものを分けて持つ。経路の上の
/// ものに戻れば循環で、辿り終えたものに着くのは共有なので、もう辿らない。quasiquote の
/// 中と外では辿る範囲が違うので、状態は両者で別に持つ。費用はデータの大きさに比例する。
/// Why: `quote` は綴りで見る。展開の前に判定するので、束縛を引けないためである。そのため、
/// `quote` 以外の名前で受け取った循環データを、マクロが展開の中で quote する形は、
/// リテラルの外の循環として拒否する(docs/design/frontend.md の「現状(スライス 5c)」)。
/// `eval`(src/machine.zig)も、リーダを通らないデータに同じ検査を掛けるため呼ぶ。
pub fn checkNotCircularCode(scratch: std.mem.Allocator, heap: *Heap, datum: Value) Error!void {
    const State = enum { on_path, done };
    const Enter = struct { value: Value, tail: bool, quasi: bool };
    const Step = union(enum) { enter: Enter, leave: usize };
    var states: std.AutoHashMapUnmanaged(usize, State) = .empty;
    var stack: std.ArrayList(Step) = .empty;
    try stack.append(scratch, .{ .enter = .{ .value = datum, .tail = false, .quasi = false } });
    while (stack.pop()) |step| switch (step) {
        .leave => |key| try states.put(scratch, key, .done),
        .enter => |e| {
            const p = e.value.asPair();
            const vector = if (e.quasi) e.value.asVector() else null;
            if (p == null and vector == null) continue;
            if (p) |pair| if (!e.tail and !e.quasi and isFormOf(heap, pair, "quote")) continue;
            // ペアとベクタの番地は整列しているので、最下位のビットで quasiquote の中と外を分ける。
            const address = if (p) |pair| @intFromPtr(pair) else @intFromPtr(vector.?);
            const key = address | @intFromBool(e.quasi);
            const slot = try states.getOrPut(scratch, key);
            if (slot.found_existing) switch (slot.value_ptr.*) {
                .on_path => return error.CircularCode,
                .done => continue,
            };
            slot.value_ptr.* = .on_path;
            try stack.append(scratch, .{ .leave = key });
            if (p) |pair| {
                const quasi = e.quasi or (!e.tail and isFormOf(heap, pair, "quasiquote"));
                try stack.append(scratch, .{ .enter = .{ .value = pair.cdr, .tail = true, .quasi = quasi } });
                try stack.append(scratch, .{ .enter = .{ .value = pair.car, .tail = false, .quasi = quasi } });
            } else for (vector.?.items) |item| {
                try stack.append(scratch, .{ .enter = .{ .value = item, .tail = false, .quasi = true } });
            }
        },
    };
}

/// Whether `p` is `(<name> x)`: a pair whose car is the symbol spelled `name`
/// and whose cdr is a list of one element.
fn isFormOf(heap: *Heap, p: *const value_mod.Pair, comptime name: []const u8) bool {
    const head = p.car.asSymbol() orelse return false;
    if (!std.mem.eql(u8, heap.symbols.nameOf(head), name)) return false;
    const rest = p.cdr.asPair() orelse return false;
    return rest.cdr.kind() == .empty_list;
}

/// A datum label or a reference to one, as `Reader.label` reads it.
const LabelToken = struct {
    number: u64,
    kind: Kind,

    const Kind = enum { define, reference };
};

pub const Reader = struct {
    src: []const u8,
    pos: usize = 0,
    /// Whether identifiers and character names are folded to lower case.
    /// `include-ci` が読むファイルは、この状態で始まる(R7RS 4.1.7)。指令 `#!fold-case` と
    /// `#!no-fold-case` が、入力の途中で切り替える(R7RS 2.1)。切り替えた状態は、この読み手の
    /// 残りの入力に効く。読み手をまたいで残すのは、呼び出し側の役目である。
    fold_case: bool = false,
    /// Whether the reader reads code, so that a datum circular outside a literal
    /// is an error (R7RS 2.4).
    /// 既定は真である。読んだものを展開器がコードとして辿るので、リテラルの外の循環が
    /// 届くと、展開器が止まらない。データとして読む手続き(`read`)は偽にする。
    code: bool = true,
    /// How far into `src` the lines and columns have been counted.
    /// 位置を記録しない読み手は、数えない。
    cursor: positions_mod.Cursor = .{},

    pub fn init(src: []const u8) Reader {
        return .{ .src = src };
    }

    /// Reads the next datum, or returns null at the end of the input.
    ///
    /// データは `sink` に確保する。`scratch` は、データを読んでいる間に開いているものを
    /// 持ち、呼び出し側がまとめて解放する。
    pub fn next(self: *Reader, scratch: std.mem.Allocator, sink: Sink) Error!?Value {
        var open: std.ArrayList(Frame) = .empty;
        // ラベルの範囲は最も外側のデータなので、データごとに表を作る(R7RS 2.4)。
        var labels: Labels = .{};
        while (true) {
            try self.skipAtmosphere();
            if (self.pos == self.src.len) {
                if (open.items.len == 0) return null;
                return error.Incomplete;
            }
            var datum: Value = switch (self.src[self.pos]) {
                '(' => {
                    const at = self.here(sink);
                    self.pos += 1;
                    try open.append(scratch, .{ .list = .{ .at = at } });
                    continue;
                },
                '.' => if (self.atDot()) {
                    self.pos += 1;
                    // Why: R7RS 7.1.2 の <list> が `.` を許すのは、1 つ以上の要素と、
                    // リストを終える 1 つだけのデータとの間である。
                    if (open.items.len == 0) return error.UnexpectedDot;
                    switch (open.items[open.items.len - 1]) {
                        // Why: R7RS 7.1.2 の <vector> は `#(` <datum>* `)` で、
                        // ドットを置く場所がない。`#;` が捨てるのも、ラベルを付けるのも
                        // <datum> で、ドットではない。
                        .abbreviation, .vector, .bytevector, .datum_comment, .label => return error.UnexpectedDot,
                        .list => |*l| {
                            if (l.dot or l.items.items.len == 0) return error.UnexpectedDot;
                            l.dot = true;
                        },
                    }
                    continue;
                } else try self.atom(scratch, sink),
                '"' => try string_syntax.read(self.src, &self.pos, scratch, sink.heap),
                // Why: 縦棒の識別子は、書かれたとおりの名前である。畳み込む読み手でも
                // `folded` を通さない(下の `folded` の doc コメント)。
                '|' => blk: {
                    const name = string_syntax.readIdentifier(self.src, &self.pos, scratch) catch |e| switch (e) {
                        error.InvalidEscape => return error.InvalidSymbolEscape,
                        else => |other| return other,
                    };
                    break :blk .fromSymbol(try sink.heap.intern(name));
                },
                '#' => if (self.atCharacter()) .fromCharacter(try char_syntax.read(self.src, &self.pos, self.fold_case)) else if (self.atVectorOpen()) {
                    self.pos += 2;
                    try open.append(scratch, .{ .vector = .empty });
                    continue;
                } else if (self.atBytevectorOpen()) {
                    self.pos += 4;
                    try open.append(scratch, .{ .bytevector = .empty });
                    continue;
                } else if (self.atDatumComment()) {
                    self.pos += 2;
                    try open.append(scratch, .{ .datum_comment = labels.entries.items.len });
                    continue;
                } else if (try self.label()) |l| blk: {
                    // Why: R7RS 7.1.2 の <bytevector> の要素は <byte> で、<datum> ではないので、
                    // ラベルもその参照も置けない。
                    if (open.items.len != 0 and open.items[open.items.len - 1] == .bytevector) return error.InvalidByte;
                    switch (l.kind) {
                        .define => {
                            try open.append(scratch, .{ .label = try labels.define(scratch, l.number) });
                            continue;
                        },
                        .reference => break :blk try labels.reference(scratch, sink, l.number),
                    }
                } else try self.atom(scratch, sink),
                '\'', '`', ',' => |c| {
                    const abbreviation: Abbreviation = switch (c) {
                        '\'' => .quote,
                        '`' => .quasiquote,
                        else => if (self.pos + 1 < self.src.len and self.src[self.pos + 1] == '@') .unquote_splicing else .unquote,
                    };
                    const at = self.here(sink);
                    // Why: `,@` は 2 文字で 1 つの記号である(R7RS 2.4)。
                    self.pos += if (abbreviation == .unquote_splicing) 2 else 1;
                    try open.append(scratch, .{ .abbreviation = .{ .kind = abbreviation, .at = at } });
                    continue;
                },
                ')' => blk: {
                    self.pos += 1;
                    if (open.items.len == 0) return error.UnexpectedCloseParen;
                    switch (open.pop().?) {
                        .abbreviation => return error.MissingDatum,
                        .datum_comment => return error.MissingCommentedDatum,
                        .label => return error.MissingLabeledDatum,
                        .list => |l| {
                            if (l.dot and l.tail == null) return error.UnexpectedDot;
                            const list = try listOf(sink, l.items.items, l.tail orelse Value.empty_list_value);
                            try recordPosition(sink, list, l.at);
                            break :blk list;
                        },
                        .vector => |items| break :blk .fromVector(try sink.heap.createVector(items.items)),
                        .bytevector => |bytes| break :blk .fromBytevector(try sink.heap.createBytevector(bytes.items)),
                    }
                },
                else => try self.atom(scratch, sink),
            };
            // 完成したデータは、それを待っているすべての略記とラベルを、内側から順に閉じる。
            while (open.items.len != 0) {
                switch (open.items[open.items.len - 1]) {
                    .abbreviation => |a| {
                        datum = try abbreviated(sink, a.kind, datum);
                        try recordPosition(sink, datum, a.at);
                    },
                    .label => |i| try labels.finish(i, datum),
                    else => break,
                }
                _ = open.pop();
            }
            // `#;` が待っていたデータなら、捨てて次を読む。捨てたデータはどこからも
            // 参照されず、ヒープのゴミになる。その中で定義したラベルも捨てる。
            if (open.items.len != 0 and open.items[open.items.len - 1] == .datum_comment) {
                labels.truncate(open.pop().?.datum_comment);
                continue;
            }
            if (open.items.len == 0) {
                try labels.resolve(scratch, datum);
                // 循環は、読み終える前のラベルへの参照(目印)からしか生まれないので、目印を
                // 置いたデータだけを検査する。
                if (self.code and labels.by_placeholder.count() != 0) try checkNotCircularCode(scratch, sink.heap, datum);
                return datum;
            }
            switch (open.items[open.items.len - 1]) {
                .list => |*l| try l.add(scratch, datum),
                .vector => |*items| try items.append(scratch, datum),
                .bytevector => |*bytes| {
                    const byte = std.math.cast(u8, datum.asFixnum() orelse return error.InvalidByte) orelse return error.InvalidByte;
                    try bytes.append(scratch, byte);
                },
                .abbreviation, .datum_comment, .label => unreachable,
            }
        }
    }

    /// The place of the input's next character, when `sink` keeps positions.
    /// 記録しない読み手は数えずに、使われない値を返す。
    fn here(self: *Reader, sink: Sink) positions_mod.Location {
        if (sink.positions == null) return .{};
        return self.cursor.locate(self.src, self.pos);
    }

    /// A `#<n>=` or `#<n>#` at the input: a datum label or a reference to one
    /// (R7RS 2.4, 7.1.2), with the input moved past it.
    /// `#` に数字が続かなければ null で、入力を動かさない。数字の後ろに `=` も `#` も
    /// 無いもの(`#12 a`)と、64 ビットに収まらない数は、読めないトークンである。
    fn label(self: *Reader) Error!?LabelToken {
        var end = self.pos + 1;
        while (end < self.src.len and std.ascii.isDigit(self.src[end])) end += 1;
        if (end == self.pos + 1) return null;
        if (end == self.src.len or (self.src[end] != '=' and self.src[end] != '#')) return null;
        const number = std.fmt.parseInt(u64, self.src[self.pos + 1 .. end], 10) catch {
            self.pos = end + 1;
            return error.InvalidToken;
        };
        const kind: LabelToken.Kind = if (self.src[end] == '=') .define else .reference;
        self.pos = end + 1;
        return .{ .number = number, .kind = kind };
    }

    /// Whether the input is at the `#(` that begins a vector.
    fn atVectorOpen(self: *const Reader) bool {
        return self.pos + 1 < self.src.len and self.src[self.pos + 1] == '(';
    }

    /// Whether the input is at the `#u8(` that begins a bytevector.
    fn atBytevectorOpen(self: *const Reader) bool {
        return std.mem.startsWith(u8, self.src[self.pos..], "#u8(");
    }

    /// Whether the input is at a `.` that stands alone: the next character is a
    /// delimiter or the end.
    /// `...` と `.a` は識別子であり、ドットではない。
    fn atDot(self: *const Reader) bool {
        const after = self.pos + 1;
        return after == self.src.len or isDelimiter(self.src[after]);
    }

    /// Whether the input is at the `#\` that begins a character.
    fn atCharacter(self: *const Reader) bool {
        return self.pos + 1 < self.src.len and self.src[self.pos + 1] == '\\';
    }

    /// Whether the input is at the `#;` that begins a datum comment.
    fn atDatumComment(self: *const Reader) bool {
        return self.pos + 1 < self.src.len and self.src[self.pos + 1] == ';';
    }

    /// Skips whitespace, line comments, block comments and directives: the
    /// <atmosphere> of R7RS 7.1.1, except for datum comments.
    /// 行コメントは `;` から行の終わり(改行か CR)の手前までである。行の終わりは空白として
    /// 次の周で読み飛ばす。文字列の中の `;` と `#\;` は、それぞれの読み取りが先に処理する
    /// ので、ここには届かない。データコメント `#;` はデータを読む必要があるので、`next` が
    /// 開いているものの1つとして扱う。指令は、読み手の畳み込みの状態を切り替える。
    fn skipAtmosphere(self: *Reader) Error!void {
        while (self.pos < self.src.len) {
            const c = self.src[self.pos];
            if (c == ';') {
                while (self.pos < self.src.len and self.src[self.pos] != '\n' and self.src[self.pos] != '\r') self.pos += 1;
            } else if (isWhitespace(c)) {
                self.pos += 1;
            } else if (std.mem.startsWith(u8, self.src[self.pos..], "#|")) {
                try self.skipBlockComment();
            } else if (std.mem.startsWith(u8, self.src[self.pos..], "#!")) {
                try self.directive();
            } else {
                return;
            }
        }
    }

    /// Skips the block comment that starts at `#|`, with the comments nested in it.
    /// R7RS 7.1.1 の <nested comment> である。中の文字列や文字は特別に扱わない。
    fn skipBlockComment(self: *Reader) Error!void {
        var depth: usize = 0;
        while (self.pos + 1 < self.src.len) {
            const pair = self.src[self.pos..][0..2];
            if (std.mem.eql(u8, pair, "#|")) {
                depth += 1;
                self.pos += 2;
            } else if (std.mem.eql(u8, pair, "|#")) {
                depth -= 1;
                self.pos += 2;
                if (depth == 0) return;
            } else {
                self.pos += 1;
            }
        }
        // 閉じる前に入力が尽きた。REPL は続きの行を求める。
        return error.Incomplete;
    }

    /// Reads the directive that starts at `#!`, and switches the folding of
    /// case as it says (R7RS 2.1).
    /// 指令の綴りは `#!fold-case` と `#!no-fold-case` だけで、区切り文字か入力の終わりが
    /// 続かなければならない(R7RS 7.1.1 の注)。それ以外は、読めないトークンである。
    fn directive(self: *Reader) Error!void {
        const start = self.pos + 2;
        var end = start;
        while (end < self.src.len and !isDelimiter(self.src[end])) end += 1;
        self.pos = end;
        const name = self.src[start..end];
        if (std.mem.eql(u8, name, "fold-case")) {
            self.fold_case = true;
        } else if (std.mem.eql(u8, name, "no-fold-case")) {
            self.fold_case = false;
        } else return error.InvalidToken;
    }

    /// Reads one token up to the next delimiter and classifies it.
    fn atom(self: *Reader, scratch: std.mem.Allocator, sink: Sink) Error!Value {
        const start = self.pos;
        while (self.pos < self.src.len and !isDelimiter(self.src[self.pos])) self.pos += 1;
        if (self.pos == start) {
            // 区切り文字は、どれも `next` と `skipAtmosphere` が先に扱うので、ここには来ない
            // はずである。来たら、同じ位置で止まり続けないよう、1文字進めて誤りにする。
            self.pos += 1;
            return error.InvalidToken;
        }
        const token = self.src[start..self.pos];
        if (booleanOf(token)) |b| return .fromBool(b);
        // Why: fixnum に収まる十進整数は、確保も計上も要らないので、`num.parse` を通さない。
        // 先頭の 0 を含めて 20 字までに限る(i64 の最小値 `-9223372036854775808` が 20 字)。
        // 長い綴りは、桁数の上限を課す `num.parse` に任せる。
        if (token.len <= max_fast_integer_len and isDecimalInteger(token)) {
            if (std.fmt.parseInt(i64, token, 10)) |n| return .fromFixnum(n) else |_| {}
        }
        // 数の綴りは R7RS 7.1.1 の <number> で、<peculiar identifier> の形をしたもの
        // (`+inf.0`、`+i`)も数である。識別子より先に尋ねる。null は、数でないか、
        // 読み取りの大きさの上限を超えるか、ヒープの上限に収まらないか、`1/0` のような
        // 値を持たない綴りである。
        if (try num.parse(sink.heap, token, 10)) |n| return n;
        if (readsAsIdentifier(token)) return .fromSymbol(try sink.heap.intern(try self.folded(scratch, token)));
        return error.InvalidToken;
    }

    /// The identifier `token` as this reader reads it: folded when the reader folds
    /// case.
    /// 文字ごとに Unicode の単純な畳み込み(`props.simpleFoldcase`)をかける。畳み込みで変わる
    /// 文字が無ければ、そのまま返す。確保するのは、変わるときだけである。`token` は
    /// `readsAsIdentifier` が真にした綴りで、妥当な UTF-8 である。
    /// Why: 全体の畳み込み(`string-foldcase`)でなく単純な畳み込みを使うのは、識別子の名前を
    /// 文字ごとの写像で決めるためである。全体の畳み込みは文字の数を変えうる(エスツェット
    /// が `ss` になる)。縦棒の識別子は畳み込まないので、ここを通らない。
    fn folded(self: *const Reader, scratch: std.mem.Allocator, token: []const u8) Error![]const u8 {
        if (!self.fold_case) return token;
        const view = std.unicode.Utf8View.init(token) catch return error.InvalidToken;
        var changes = false;
        var scan = view.iterator();
        while (scan.nextCodepoint()) |c| {
            if (unicode.simpleFoldcase(c) != c) {
                changes = true;
                break;
            }
        }
        if (!changes) return token;
        var out: std.ArrayList(u8) = .empty;
        // 畳み込みの結果の符号化は元より長くなりうる(4 バイトまで)が、短くなることが多い。
        try out.ensureTotalCapacity(scratch, token.len);
        var it = view.iterator();
        while (it.nextCodepoint()) |c| {
            var encoded: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(unicode.simpleFoldcase(c), &encoded) catch return error.InvalidToken;
            try out.appendSlice(scratch, encoded[0..n]);
        }
        return out.items;
    }
};

/// Whether `source` ends inside a datum that more input could finish.
///
/// REPL の継続行の判定である(ADR-0014)。別の字句解析器を持たず、`source` を
/// 使い捨てのヒープ・シンボル表・アリーナで `Reader` に最後まで読ませる。字句の規則が
/// 1つなので、文字列・文字・行コメントの中の括弧で誤らず、リーダが育てば判定も追従する。
///
/// 真になるのは、`Reader` が `Incomplete` で止まるときだけである。データが尽きて終わる
/// 入力(空やコメントだけを含む)も、`Incomplete` 以外の構文エラーで止まる入力も、
/// 続きを足しても直らないので偽にする。そのエラーの報告は `evalPrint` に任せる。
/// 不正な UTF-8 も偽である。リーダは入力が妥当な UTF-8 であることを前提にしている。
///
/// 読み直しの費用は `source` の長さに比例する。呼び出し側は、行を足すたびに全体を
/// 渡し直すので、`source` の上限で費用を抑える。
pub fn isIncomplete(gpa: std.mem.Allocator, source: []const u8) error{OutOfMemory}!bool {
    if (!std.unicode.utf8ValidateSlice(source)) return false;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var heap: Heap = .init(gpa, .{});
    defer heap.deinit();
    const sink: Sink = .{ .heap = &heap };
    var r: Reader = .init(source);
    while (true) {
        const datum = r.next(arena.allocator(), sink) catch |e| switch (e) {
            error.Incomplete => return true,
            error.OutOfMemory => return error.OutOfMemory,
            else => return false,
        };
        if (datum == null) return false;
    }
}

/// One row of the judgement table: an input, and whether it asks for more.
///
/// 判定表のテストが使う。
const Judgement = struct { []const u8, bool };

test "isIncomplete asks for more input only for an unfinished datum" {
    const table = [_]Judgement{
        // リストかベクタが閉じていない。
        .{ "(+ 1", true },
        .{ "(a (b)", true },
        .{ "#(1 2", true },
        .{ "(", true },
        .{ "#(", true },
        .{ "((a) (b", true },
        // `'` のあとにデータが無い。
        .{ "'", true },
        .{ "(a '", true },
        .{ "''", true },
        // `` ` `` と `,` と `,@` も同じである。
        .{ "`", true },
        .{ ",", true },
        .{ ",@", true },
        .{ "(a ,@", true },
        .{ "`,", true },
        .{ "(a) `b ,", true },
        // 文字列が閉じていない。エスケープの途中も含む。
        .{ "\"abc", true },
        // 単独の `isIncomplete` の判定である。REPL は保留に `\n` を足す。`\` + 改行は行継続で、
        // 文字列はまだ閉じていないので、REPL でも継続行になる。`\x41` + 改行は不正なエスケープ
        // なので、REPL では継続行にならない。
        .{ "\"a\\", true },
        .{ "\"a\\\n", true },
        .{ "\"a\\  \n  b", true },
        .{ "\"a\\x41", true },
        .{ "\"a\\\"", true },
        .{ "\"a\nb", true },
        // 文字の本体が無い。次の2行も単独の判定で、REPL では `\n` が文字の本体になる。
        // 最上位の `#\` は `#\newline` として完結する。`(a #\` は文字が完結したうえで、
        // リストが閉じていないので、REPL でも継続行になる。
        .{ "#\\", true },
        .{ "(a #\\", true },
        // ドットのあとのデータが無い。
        .{ "(a . ", true },
        .{ "(a . b", true },
        // 閉じた式のあとに、閉じていない式が続く。
        .{ "1 (a", true },
        .{ "(a) 'b '", true },
        // コメントの中の `)` は数えないので、閉じていない。
        .{ "(a ; )\n", true },
        .{ "(a ; )", true },
        .{ "(+ 1 2 ;)\n", true },
        .{ "'; a", true },
        .{ "(1 . ; c", true },
        .{ "#(1 ; )\n", true },
        // 区切り文字の `;` がトークンを終わらせても、リストは閉じていない。
        .{ "(a;b\n", true },

        // 閉じた式は完結している。
        .{ "(+ 1 2)", false },
        .{ "1", false },
        .{ "1 2", false },
        .{ "(a (b) c)", false },
        .{ "#(1 2)", false },
        .{ "'a", false },
        .{ "'(a b)", false },
        .{ "(a . b)", false },
        .{ "abc", false },
        .{ "\"abc\"", false },
        .{ "\"a\\\"\"", false },
        .{ "\"a\nb\"", false },
        .{ "#\\a", false },
        .{ "#\\space", false },
        // 文字列、文字、コメントの中の括弧は、何も開かず閉じない。
        .{ "\"(\"", false },
        .{ "\")\"", false },
        .{ "#\\(", false },
        .{ "#\\)", false },
        .{ "(a #\\()", false },
        .{ "(a \"(\")", false },
        .{ "(a #\\( 1", true },
        .{ "(a) ; (", false },
        .{ "(a ; (\n)", false },
        .{ "\"a;b\"", false },
        // 構文エラーは、続けても直らないので完結とする。
        .{ ")", false },
        .{ "(a))", false },
        .{ "(a . )", false },
        .{ "(a . b c)", false },
        .{ "#z", false },
        .{ "')", false },
        .{ "(a ')", false },
        .{ "`)", false },
        .{ "(a ,@)", false },
        .{ ",.", false },
        .{ ", @x", false },
        .{ "#(1 . 2)", false },
        .{ "#\\spa", false },
        .{ "\"\\q\"", false },
        .{ "9223372036854775808", false },
        // 構文エラーのあとに閉じていない式があっても、先のエラーで完結とする。
        .{ ") (a", false },
        .{ "(a . ) (b", false },
        // ブロックコメントが閉じていないか、データコメントのデータが無い。
        .{ "#| x", true },
        .{ "#|", true },
        .{ "#| #| x |#", true },
        .{ "(a #;1", true },
        .{ "#;", true },
        .{ "(a #;", true },
        // 閉じたブロックコメントと、データを捨て終えたデータコメントは、完結している。
        .{ "#| ( |#", false },
        .{ "#;1", false },
        .{ "#;(a) b", false },
        .{ "(a #;)", false },
        // ラベルの付くデータが無いか、閉じていない。未定義のラベルの参照は誤りで、完結している。
        .{ "#0=", true },
        .{ "#0=(a", true },
        .{ "(#0=a #0#)", false },
        .{ "#0#", false },
        // 縦棒の識別子が閉じていない。閉じたものと、エスケープの誤りは完結している。
        .{ "|abc", true },
        .{ "(a |b c", true },
        .{ "|a b|", false },
        .{ "(a |b) c|", true },
        .{ "|\\q|", false },
        // 指令はコメントと同じく、それだけでは何も開かない。
        .{ "#!fold-case", false },
        .{ "#!fold-case (a", true },
        .{ "#!fold-casex", false },
        // 何も無い入力。
        .{ "", false },
        .{ "  ", false },
        .{ "\n", false },
        .{ "\n\n", false },
        .{ "; コメント", false },
        .{ "; コメント\n", false },
        .{ ";\n;\n", false },
        .{ "  ;a\n\n;b", false },
        // 不正な UTF-8 は、続けても直らない。報告は evalPrint に任せる。
        .{ "\xff", false },
        .{ "(a \xff", false },
        .{ "\"\xc3", false },
    };
    for (table) |row| {
        const source, const expected = row;
        std.testing.expectEqual(expected, try isIncomplete(std.testing.allocator, source)) catch |e| {
            std.debug.print("isIncomplete({f}) should be {}\n", .{ std.zig.fmtString(source), expected });
            return e;
        };
    }
}

test "isIncomplete gives back what it takes, and reports running out of memory" {
    const check = struct {
        fn run(gpa: std.mem.Allocator, source: []const u8) !void {
            _ = try isIncomplete(gpa, source);
        }
    }.run;
    for ([_][]const u8{ "(a (b \"c\" #(1 'd)", "(a (b \"c\" #(1 'd)))", "1" }) |source| {
        try std.testing.checkAllAllocationFailures(std.testing.allocator, check, .{source});
    }
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, isIncomplete(failing.allocator(), "(a (b"));
}

test "isIncomplete tells a line that a later line can finish from one it cannot" {
    // REPL が行を足していく経路。足すたびに全体を読み直す。
    const lines = [_][]const u8{ "(define (f x)\n", "  (+ x\n", "     1))\n" };
    var buf: [64]u8 = undefined;
    var len: usize = 0;
    for (lines, 0..) |line, i| {
        @memcpy(buf[len..][0..line.len], line);
        len += line.len;
        const expected = i + 1 < lines.len;
        try std.testing.expectEqual(expected, try isIncomplete(std.testing.allocator, buf[0..len]));
    }
}

/// The pairs of `items` ending in `tail`, allocated in `sink`.
/// `tail` が `()` ならリストになる。
fn listOf(sink: Sink, items: []const Value, tail: Value) Error!Value {
    var result = tail;
    var i = items.len;
    while (i > 0) {
        i -= 1;
        result = try sink.heap.cons(items[i], result);
    }
    return result;
}

/// Keeps that `datum` was read at `at`, when `sink` keeps positions and
/// `datum` is a pair: `()` is not one.
fn recordPosition(sink: Sink, datum: Value, at: positions_mod.Location) Error!void {
    const recording = sink.positions orelse return;
    const pair = datum.asPair() orelse return;
    try recording.table.record(pair, .{ .file = recording.file, .location = at });
}

/// `(quote datum)` for `'datum`, and likewise `quasiquote`, `unquote` and
/// `unquote-splicing` for `` `datum ``, `,datum` and `,@datum` (R7RS 2.4).
fn abbreviated(sink: Sink, abbreviation: Abbreviation, datum: Value) Error!Value {
    const head: Value = .fromSymbol(try sink.heap.intern(abbreviation.symbolName()));
    const tail = try sink.heap.cons(datum, Value.empty_list_value);
    return sink.heap.cons(head, tail);
}

// Why: R7RS 7.1.1 の <boolean> は `#t`、`#f`、`#true`、`#false` である。
fn booleanOf(token: []const u8) ?bool {
    if (std.mem.eql(u8, token, "#t") or std.mem.eql(u8, token, "#true")) return true;
    if (std.mem.eql(u8, token, "#f") or std.mem.eql(u8, token, "#false")) return false;
    return null;
}

// Why: R7RS 7.1.1 は、空白を、行内の空白(スペース、タブ)と改行とに定めている。
// CR は CRLF による改行の一部である。
fn isWhitespace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}

// Why: R7RS 7.1.1 の <delimiter> は、空白、縦線、丸括弧、二重引用符、セミコロンである。
fn isDelimiter(c: u8) bool {
    return isWhitespace(c) or c == '|' or c == '(' or c == ')' or c == '"' or c == ';';
}

/// The longest spelling the fast path of `atom` reads as a fixnum.
const max_fast_integer_len = 20;

/// `[+-]?[0-9]+`.
/// fixnum の速い経路の判定である。ほかの数の構文は `num.parse` が読む。
fn isDecimalInteger(token: []const u8) bool {
    const digits = if (token[0] == '+' or token[0] == '-') token[1..] else token;
    if (digits.len == 0) return false;
    for (digits) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

// Why: R7RS 7.1.1 の <identifier> を、`|...|` の形を除いて実装している。
// `|...|` の形は `next` が `string_syntax.readIdentifier` で読む。
// <initial> に <subsequent> が続くものか、<peculiar identifier> である。整数は、
// これを尋ねる前に判別してあり、識別子の形をした数(`+inf.0`、`+i`)は、
// `atom` が先に `num.parse` で数として読む。
// ASCII でない文字は、<initial> と <subsequent> の `<Unicode non-ASCII ...>` の部分で、
// 符号位置ごとに `props` の表が決める。<sign subsequent> と <dot subsequent> は
// <initial> を含むので、`+λ` や `.λ` も識別子である。
/// Whether `read` reads `token`, written without vertical lines, as an identifier
/// (unless it is a number). `token` is not empty.
/// 不正な UTF-8 は識別子ではない。
/// プリンタ(src/printer.zig)が、シンボルを縦棒で囲むかを決めるのに使う(スライス 6q)。
/// 印字の判定をリーダと同じ関数にそろえ、規則を2か所に持たない。
pub fn readsAsIdentifier(token: []const u8) bool {
    const view = std.unicode.Utf8View.init(token) catch return false;
    var it = view.iterator();
    var c = it.nextCodepoint() orelse return false;
    if (isInitial(c)) return allSubsequent(&it);
    // <peculiar identifier>
    if (c == '+' or c == '-') {
        c = it.nextCodepoint() orelse return true; // <explicit sign>
        if (isSignSubsequent(c)) return allSubsequent(&it);
    }
    // `.` <dot subsequent> <subsequent>*。手前の符号はあってもなくてもよい。
    if (c != '.') return false;
    const dot_subsequent = it.nextCodepoint() orelse return false;
    if (!isSignSubsequent(dot_subsequent) and dot_subsequent != '.') return false;
    return allSubsequent(&it);
}

fn isInitial(c: u21) bool {
    if (c >= 0x80) return unicode.isIdentifierInitial(c);
    const byte: u8 = @intCast(c);
    return std.ascii.isAlphabetic(byte) or std.mem.indexOfScalar(u8, "!$%&*/:<=>?^_~", byte) != null;
}

fn isSignSubsequent(c: u21) bool {
    return isInitial(c) or c == '+' or c == '-' or c == '@';
}

/// Whether every character that `it` has left is a <subsequent>.
fn allSubsequent(it: *std.unicode.Utf8Iterator) bool {
    while (it.nextCodepoint()) |c| {
        if (c >= 0x80) {
            if (!unicode.isIdentifierSubsequent(c)) return false;
        } else if (!(isInitial(c) or std.ascii.isDigit(@intCast(c)) or c == '+' or c == '-' or c == '.' or c == '@')) return false;
    }
    return true;
}

test {
    std.testing.refAllDecls(@This());
}

const printer = @import("printer.zig");

/// A reader test's fixture: where data goes, and how it is printed back.
const Fixture = struct {
    arena: std.heap.ArenaAllocator,
    heap: Heap,
    fold_case: bool = false,
    /// Whether the readers read code, which may not be circular outside a literal.
    code: bool = true,

    fn init() Fixture {
        return .{ .arena = .init(std.testing.allocator), .heap = .init(std.heap.smp_allocator, .{}) };
    }

    fn deinit(self: *Fixture) void {
        self.heap.deinit();
        self.arena.deinit();
    }

    fn sink(self: *Fixture) Sink {
        return .{ .heap = &self.heap };
    }

    /// Reads the only datum of `src`; any other count is an error.
    fn readOne(self: *Fixture, src: []const u8) Error!Value {
        var r: Reader = .init(src);
        r.fold_case = self.fold_case;
        r.code = self.code;
        const d = (try r.next(self.arena.allocator(), self.sink())) orelse return error.Incomplete;
        if (try r.next(self.arena.allocator(), self.sink()) != null) return error.InvalidToken;
        return d;
    }

    /// What `src` reads as, written back.
    fn roundTrip(self: *Fixture, src: []const u8, buf: []u8) ![]const u8 {
        const d = try self.readOne(src);
        var w: std.Io.Writer = .fixed(buf);
        try printer.print(&w, &self.heap, &self.heap.symbols, d, .write);
        return w.buffered();
    }
};

test "next reads integers with and without a sign" {
    var f: Fixture = .init();
    defer f.deinit();
    try std.testing.expectEqual(42, (try f.readOne("42")).asFixnum().?);
    try std.testing.expectEqual(-7, (try f.readOne("-7")).asFixnum().?);
    try std.testing.expectEqual(5, (try f.readOne("+5")).asFixnum().?);
    try std.testing.expectEqual(std.math.minInt(i64), (try f.readOne("-9223372036854775808")).asFixnum().?);
}

test "next reads an integer outside the fixnum range as a bignum" {
    var f: Fixture = .init();
    defer f.deinit();
    var buf: [64]u8 = undefined;
    try std.testing.expect((try f.readOne("9223372036854775808")).asBignum() != null);
    try std.testing.expectEqualStrings("9223372036854775808", try f.roundTrip("9223372036854775808", &buf));
    try std.testing.expectEqualStrings("-9223372036854775809", try f.roundTrip("-9223372036854775809", &buf));
    // 範囲の端は、fixnum のままである。
    try std.testing.expectEqual(std.math.maxInt(i64), (try f.readOne("9223372036854775807")).asFixnum().?);
}

test "next reads the numbers of R7RS 7.1.1 that are not plain decimal integers" {
    var f: Fixture = .init();
    defer f.deinit();
    var buf: [128]u8 = undefined;
    // 入力と、書き戻した結果(`num.write` の正規形)。
    const rows = [_][2][]const u8{
        // 基数の接頭辞(大文字小文字を区別しない)。
        .{ "#x1F", "31" },       .{ "#X-1f", "-31" },     .{ "#b101", "5" },
        .{ "#o17", "15" },       .{ "#d10", "10" },
        // 正確性の接頭辞と、基数との組(順序は両方)。
              .{ "#e1.5", "3/2" },
        .{ "#i3", "3.0" },       .{ "#x#e10", "16" },     .{ "#e#x10", "16" },
        .{ "#I#B11", "3.0" },
        // 分数。
           .{ "1/2", "1/2" },       .{ "-6/4", "-3/2" },
        .{ "4/2", "2" },
        // 小数と指数。
                .{ "1.5", "1.5" },       .{ ".5", "0.5" },
        .{ "-1.", "-1.0" },      .{ "1e3", "1000.0" },    .{ "1E-2", "0.01" },
        .{ "#e1e3", "1000" },
        // <infnan>(大文字小文字を区別しない)。
           .{ "+inf.0", "+inf.0" }, .{ "-INF.0", "-inf.0" },
        .{ "+nan.0", "+nan.0" }, .{ "-NaN.0", "+nan.0" },
        // 複素数。
        .{ "+i", "+i" },
        .{ "-i", "-i" },         .{ "1+2i", "1+2i" },     .{ "1.5-2.5i", "1.5-2.5i" },
        .{ "+2i", "+2i" },       .{ "1+0i", "1" },        .{ "1@0", "1" },
    };
    for (rows) |row| {
        const got = f.roundTrip(row[0], &buf) catch |e| {
            std.debug.print("{s}: {s}\n", .{ row[0], @errorName(e) });
            return e;
        };
        try std.testing.expectEqualStrings(row[1], got);
    }
    // 数は区切り文字までのトークンなので、後ろに続く括弧は別の文字である。
    try std.testing.expectEqualStrings("(1/2 31 -1.5)", try f.roundTrip("(1/2 #x1F -1.5)", &buf));
}

test "next keeps the spellings that are not numbers as identifiers" {
    var f: Fixture = .init();
    defer f.deinit();
    var buf: [64]u8 = undefined;
    // 識別子の形で、数でないもの(`+` `-` `...` `1+` は <peculiar identifier> か <initial> で始まる)。
    for ([_][]const u8{ "+", "-", "...", "-x", "+inf", "inf", "nan.0", "e1", "x1F", "+ia" }) |src| {
        try std.testing.expectEqualStrings(src, try f.roundTrip(src, &buf));
    }
    // 数にも識別子にもならない綴り。
    for ([_][]const u8{ "1/0", "#e+inf.0", "#e+nan.0", "#xg", "#b2", "1..2", "1e", "#e1@2", "1+i+i", "#z", "1x", "1+" }) |src| {
        try std.testing.expectError(error.InvalidToken, f.readOne(src));
    }
}

test "next refuses a number whose spelling is longer than the limit of reading" {
    var f: Fixture = .init();
    defer f.deinit();
    // 桁数の上限は 100,000、指数の絶対値の上限は 1,000,000(src/num/number.zig の
    // `max_spelling_digits` と `max_spelling_exponent`。非公開なので、値を写している)。
    const max_spelling_digits = 100_000;
    const long = try std.testing.allocator.alloc(u8, max_spelling_digits + 1);
    defer std.testing.allocator.free(long);
    @memset(long, '9');
    try std.testing.expectError(error.InvalidToken, f.readOne(long));
    try std.testing.expectError(error.InvalidToken, f.readOne("#e1e1000001"));
    // 上限ちょうどは読める。
    const edge = try std.testing.allocator.alloc(u8, max_spelling_digits);
    defer std.testing.allocator.free(edge);
    @memset(edge, '9');
    try std.testing.expect((try f.readOne(edge)).asBignum() != null);
}

test "next gives a spelling padded with zeros past the limit of reading the same answer as num.parse" {
    var f: Fixture = .init();
    defer f.deinit();
    var buf: [64]u8 = undefined;
    // 先頭の 0 は、20 字を超えても値を変えない。
    try std.testing.expectEqualStrings("1", try f.roundTrip("0000000000000000000000000000001", &buf));
    try std.testing.expectEqualStrings("-12", try f.roundTrip("-000000000000000000000000012", &buf));
    // 桁数の上限(100,000)には、先頭の 0 も数える。速い経路で 1 と読まず、`num.parse` と
    // 同じく読めない綴りにする。
    const padded = try std.testing.allocator.alloc(u8, 100_001);
    defer std.testing.allocator.free(padded);
    @memset(padded, '0');
    padded[padded.len - 1] = '1';
    try std.testing.expectError(error.InvalidToken, f.readOne(padded));
}

test "next reports the heap limit when the work of reading a number is refused" {
    var f: Fixture = .init();
    defer f.deinit();
    // 外側の作業が上限のすぐ手前まで数えているところへ、読む。
    f.heap.external = f.heap.options.limit - 8;
    try std.testing.expectError(error.HeapLimit, f.readOne("123456789012345678901234567890"));
    f.heap.external = 0;
    // 上限より大きくなる数は、確保せずに断られる(`num.parse` の null)。
    f.heap.options.limit = 1024;
    var big: [5001]u8 = undefined;
    @memset(&big, '0');
    big[0] = '1';
    try std.testing.expectError(error.InvalidToken, f.readOne(&big));
}

test "next reads the four spellings of a boolean" {
    var f: Fixture = .init();
    defer f.deinit();
    try std.testing.expect((try f.readOne("#t")).isTrue());
    try std.testing.expect((try f.readOne("#true")).isTrue());
    try std.testing.expect(!(try f.readOne("#f")).isTrue());
    try std.testing.expect(!(try f.readOne("#false")).isTrue());
    try std.testing.expectEqual(.boolean, (try f.readOne("#f")).kind());
}

test "next reads an identifier as the one symbol of its name" {
    var f: Fixture = .init();
    defer f.deinit();
    const a = (try f.readOne("abc")).asSymbol().?;
    try std.testing.expectEqual(a, (try f.readOne("abc")).asSymbol().?);
    try std.testing.expect(a != (try f.readOne("abd")).asSymbol().?);
    // 識別子は大文字と小文字を区別する(R7RS 2.1)。
    try std.testing.expect(a != (try f.readOne("ABC")).asSymbol().?);
    try std.testing.expectEqualStrings("abc", f.heap.symbols.nameOf(a));
}

test "a reader that folds case reads identifiers and character names in lower case, and not strings or one-character literals" {
    var f: Fixture = .init();
    defer f.deinit();
    f.fold_case = true;
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings(
        "(define foo-bar #\\newline #\\A \"MiXed\" x1 +soon ...)",
        try f.roundTrip("(DEFINE Foo-Bar #\\NEWLINE #\\A \"MiXed\" X1 +SOON ...)", &buf),
    );
    // 大文字は、端の A も Z も畳み込む。
    try std.testing.expectEqualStrings("abcdefghijklmnopqrstuvwxyz", f.heap.symbols.nameOf((try f.readOne("ABCDEFGHIJKLMNOPQRSTUVWXYZ")).asSymbol().?));
    try std.testing.expectEqualStrings("z", f.heap.symbols.nameOf((try f.readOne("Z")).asSymbol().?));
    // 読み手が畳み込まないときは、どれも変わらない。
    f.fold_case = false;
    try std.testing.expectEqualStrings("(DEFINE Foo-Bar #\\A)", try f.roundTrip("(DEFINE Foo-Bar #\\A)", &buf));
    try std.testing.expectError(error.InvalidCharacter, f.readOne("#\\NEWLINE"));
}

test "next reads an identifier with characters that are not ASCII as the symbol of its characters" {
    var f: Fixture = .init();
    defer f.deinit();
    // <initial> に入る一般カテゴリ(Ll、Lu、Lo、Sm、So、Pc、Mn、Co)と、4 バイトの文字。
    // どれも大文字を含まないので、畳み込む読み手でも名前は変わらない。
    // U+0080 から U+00FF の文字(é、ß、ª)は、ASCII との境界のすぐ上にある。
    for ([_][]const u8{ "λ", "二倍", "→", "😀", "\u{203F}", "\u{0301}", "\u{E000}", "a\u{3BB}", "\u{3BB}1", "x\u{663}", "\u{E9}", "\u{DF}x", "\u{AA}" }) |name| {
        for ([_]bool{ false, true }) |fold| {
            f.fold_case = fold;
            const sym = (try f.readOne(name)).asSymbol() orelse return error.TestUnexpectedResult;
            try std.testing.expectEqualStrings(name, f.heap.symbols.nameOf(sym));
        }
    }
    f.fold_case = false;
    try std.testing.expectEqualStrings("Αβ", f.heap.symbols.nameOf((try f.readOne("Αβ")).asSymbol().?));
    // 識別子の中の位置を問わず、ほかのデータと並べて読める。
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("(λ 1 二倍)", try f.roundTrip("(λ 1 二倍)", &buf));
    // 同じ名前は同じシンボルで、大文字と小文字は別である。
    try std.testing.expectEqual((try f.readOne("λ")).asSymbol().?, (try f.readOne("|\\x3BB;|")).asSymbol().?);
    try std.testing.expect((try f.readOne("Λ")).asSymbol().? != (try f.readOne("λ")).asSymbol().?);
    // 文字列の中と、1文字のリテラルは、識別子ではない。
    _ = try f.readOne("\"λ\"");
    _ = try f.readOne("#\\λ");
}

test "next reads a peculiar identifier with a character that is not ASCII" {
    var f: Fixture = .init();
    defer f.deinit();
    // <sign subsequent> と <dot subsequent> は <initial> を含む。
    for ([_][]const u8{ "+λ", "-λ1", "+\u{3BB}.x", ".λ", "+.λ", "-..λ" }) |name| {
        const sym = (try f.readOne(name)).asSymbol() orelse return error.TestUnexpectedResult;
        try std.testing.expectEqualStrings(name, f.heap.symbols.nameOf(sym));
    }
    // 記号の後ろの数字や、<initial> でない文字は、そのままでは識別子にならない。
    try std.testing.expectError(error.InvalidToken, f.readOne("+\u{664}"));
    try std.testing.expectError(error.InvalidToken, f.readOne(".\u{664}"));
}

test "next rejects a token with a character that may not be in an identifier" {
    var f: Fixture = .init();
    defer f.deinit();
    for ([_][]const u8{
        // <initial> に使えない Nd、Mc、Me(<subsequent> には使える)。
        "\u{664}",
        "\u{664}x",
        "\u{903}",
        "\u{20DD}",
        // 空白(Zs、Zl、Zp)と、制御文字(Cc、Cf のうち U+200C、U+200D 以外)。
        "a\u{A0}b",
        "a\u{2028}b",
        "a\u{85}b",
        "a\u{200B}b",
        // 割り当てのない符号位置と、非文字。
        "\u{378}",
        "a\u{378}",
        "a\u{FFFF}",
        "a\u{10FFFF}",
        // ASCII の規則が決めるもの(<subsequent> にない `#` と、数字で始まる綴り)。
        "\u{3BB}#",
        "1\u{3BB}",
        "\u{3BB}\u{7F}",
        // 不正な UTF-8 は、識別子にならない。
        "a\xff",
        "\xc3",
        "a\xe3\x81",
    }) |src| {
        f.fold_case = src.len % 2 == 1;
        std.testing.expectError(error.InvalidToken, f.readOne(src)) catch |e| {
            std.debug.print("accepted {any}\n", .{src});
            return e;
        };
    }
}

test "next reads U+200C and U+200D as parts of an identifier, at the start too" {
    var f: Fixture = .init();
    defer f.deinit();
    for ([_][]const u8{ "a\u{200C}b", "a\u{200D}", "\u{200C}a", "\u{200D}", "+\u{200D}" }) |name| {
        const sym = (try f.readOne(name)).asSymbol() orelse return error.TestUnexpectedResult;
        try std.testing.expectEqualStrings(name, f.heap.symbols.nameOf(sym));
    }
}

test "a reader that folds case folds the characters of an identifier that are not ASCII" {
    var f: Fixture = .init();
    defer f.deinit();
    f.fold_case = true;
    const cases = [_][2][]const u8{
        .{ "ΛΑΜΒΔΑ", "λαμβδα" },
        .{ "Αβ", "αβ" },
        // 末尾のシグマは小文字の字形が別でも、単純な畳み込みは 1 つの文字に寄せる。
        .{ "ΟΔΟΣ", "οδοσ" },
        .{ "οδος", "οδοσ" },
        // ASCII の大文字と混ざる。
        .{ "AλB", "aλb" },
        .{ "Foo-BAR", "foo-bar" },
        // 畳み込んだ結果の符号化の長さが元と違う(3 バイトが 1 バイト、3 バイトが 2 バイト)。
        .{ "\u{212A}x", "kx" },
        .{ "\u{1E9E}", "\u{DF}" },
        // 4 バイトの文字(Deseret)。
        .{ "\u{10400}", "\u{10428}" },
        // 単純な畳み込みを持たない文字は、そのまま残る(完全な畳み込みなら `ss` になる `ß` も)。
        .{ "\u{130}", "\u{130}" },
        .{ "Stra\u{DF}e", "stra\u{DF}e" },
        // 記号の後ろ。
        .{ "+Λ", "+λ" },
    };
    for (cases) |c| {
        const sym = (try f.readOne(c[0])).asSymbol() orelse return error.TestUnexpectedResult;
        try std.testing.expectEqualStrings(c[1], f.heap.symbols.nameOf(sym));
    }
    // 畳み込んだ名前は、小文字で書いた同じ名前と同じシンボルである。
    try std.testing.expectEqual((try f.readOne("ΛΑΜΒΔΑ")).asSymbol().?, (try f.readOne("λαμβδα")).asSymbol().?);
    // 畳み込む読み手でも、縦棒の識別子、文字列、1 文字のリテラルは畳み込まない。
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("(Λ \"Λ\" #\\Λ)", try f.roundTrip("(|Λ| \"Λ\" #\\Λ)", &buf));
    // 畳み込まない読み手は、どれも変えない。
    f.fold_case = false;
    const kept = (try f.readOne("ΛΑΜΒΔΑ")).asSymbol().?;
    try std.testing.expectEqualStrings("ΛΑΜΒΔΑ", f.heap.symbols.nameOf(kept));
}

test "a directive switches the folding of an identifier that is not ASCII" {
    var f: Fixture = .init();
    defer f.deinit();
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("(Λ λ Λ)", try f.roundTrip("(Λ #!fold-case Λ #!no-fold-case Λ)", &buf));
}

test "readsAsIdentifier accepts a name with a character that is not ASCII, by the same rule as the reader" {
    try std.testing.expect(readsAsIdentifier("abc"));
    try std.testing.expect(readsAsIdentifier("λ"));
    try std.testing.expect(readsAsIdentifier("a\u{3BB}"));
    try std.testing.expect(readsAsIdentifier("+\u{3BB}"));
    try std.testing.expect(!readsAsIdentifier("a b"));
    try std.testing.expect(!readsAsIdentifier("\u{3BB}\u{3000}"));
}

test "next reads lists, the empty list and nesting" {
    var f: Fixture = .init();
    defer f.deinit();
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("(+ 1 (+ 2 3))", try f.roundTrip(" (+ 1\t(+ 2 3)\r\n) ", &buf));
    try std.testing.expectEqualStrings("()", try f.roundTrip("()", &buf));
    try std.testing.expectEqualStrings("(())", try f.roundTrip("(())", &buf));
    try std.testing.expectEqualStrings("(a (b c) ())", try f.roundTrip("(a (b c) ())", &buf));
    try std.testing.expectEqual(.empty_list, (try f.readOne("()")).kind());
    try std.testing.expectEqual(.pair, (try f.readOne("(1)")).kind());
}

test "next reads ' as a quote form, and nests it" {
    var f: Fixture = .init();
    defer f.deinit();
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("(quote a)", try f.roundTrip("'a", &buf));
    try std.testing.expectEqualStrings("(quote (1 2))", try f.roundTrip("'(1 2)", &buf));
    try std.testing.expectEqualStrings("(quote (quote a))", try f.roundTrip("''a", &buf));
    try std.testing.expectEqualStrings("(a (quote b) c)", try f.roundTrip("(a 'b c)", &buf));
    try std.testing.expectEqualStrings("(quote ())", try f.roundTrip("'()", &buf));
    // `'a` と `(quote a)` は同じデータである。
    try std.testing.expectEqualStrings(try f.roundTrip("(quote a)", &buf), "(quote a)");
}

test "next reads ` , and ,@ as the forms they abbreviate, and nests them" {
    var f: Fixture = .init();
    defer f.deinit();
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings("(quasiquote a)", try f.roundTrip("`a", &buf));
    try std.testing.expectEqualStrings("(unquote a)", try f.roundTrip(",a", &buf));
    try std.testing.expectEqualStrings("(unquote-splicing a)", try f.roundTrip(",@a", &buf));
    try std.testing.expectEqualStrings("(quasiquote (1 (unquote x) (unquote-splicing y)))", try f.roundTrip("`(1 ,x ,@y)", &buf));
    try std.testing.expectEqualStrings("(quasiquote (quasiquote (unquote (unquote a))))", try f.roundTrip("``,,a", &buf));
    try std.testing.expectEqualStrings("(quote (unquote (quasiquote (unquote-splicing a))))", try f.roundTrip("',`,@a", &buf));
    try std.testing.expectEqualStrings("(a (unquote b) (unquote-splicing c) d)", try f.roundTrip("(a ,b ,@c d)", &buf));
    // `,@` は 2 文字で 1 つの記号である。間に空白があれば、`,` に識別子 `@x` が続く形になるが、
    // `@x` は識別子の綴りではないので読めない。
    try std.testing.expectError(error.InvalidToken, f.readOne(", @x"));
    // `,` の直後が `@` 以外なら `,@` ではない。
    try std.testing.expectEqualStrings("(unquote a@)", try f.roundTrip(",a@", &buf));
    // 略記は、`'` と同じように、直前のデータと区切らずに並べられるわけではない。
    try std.testing.expectError(error.InvalidToken, f.readOne("a,b"));
    try std.testing.expectError(error.InvalidToken, f.readOne("a`b"));
    // `'` が `quote` を作るのと同じ形で、`quasiquote` などの記号は、
    // `(quasiquote a)` と書いた入力と同じデータになる。
    try std.testing.expectEqualStrings(try f.roundTrip("(quasiquote a)", &buf), "(quasiquote a)");
    const q = (try f.readOne("`a")).asPair().?;
    try std.testing.expectEqualStrings("quasiquote", f.heap.symbols.nameOf(q.car.asSymbol().?));
    try std.testing.expectEqual(.empty_list, q.cdr.asPair().?.cdr.kind());
}

test "next reads ` , and ,@ before and inside a vector and after a dot" {
    var f: Fixture = .init();
    defer f.deinit();
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings("(quasiquote #(1 (unquote x) (unquote-splicing y)))", try f.roundTrip("`#(1 ,x ,@y)", &buf));
    try std.testing.expectEqualStrings("#((quasiquote a) (unquote b) (unquote-splicing #(c)))", try f.roundTrip("#(`a ,b ,@#(c))", &buf));
    try std.testing.expectEqualStrings("(a unquote b)", try f.roundTrip("(a . ,b)", &buf));
    try std.testing.expectEqualStrings("(a unquote-splicing b)", try f.roundTrip("(a . ,@b)", &buf));
    try std.testing.expectEqualStrings("(a quasiquote b)", try f.roundTrip("(a . `b)", &buf));
    // 略記の直後のコメントは読み飛ばされる。
    try std.testing.expectEqualStrings("(unquote a)", try f.roundTrip(",; c\na", &buf));
    try std.testing.expectEqualStrings("(unquote-splicing a)", try f.roundTrip(",@; c\na", &buf));
}

test "next reports ` , and ,@ with nothing after them, as it does for '" {
    var f: Fixture = .init();
    defer f.deinit();
    for ([_][]const u8{ "`)", "(a `)", "(a ,)", "(a ,@)", "(a `, )", "#(,@)", "(a ,@ ,)" }) |src| {
        try std.testing.expectError(error.MissingDatum, f.readOne(src));
    }
    const a = f.arena.allocator();
    for ([_][]const u8{ "`", ",", ",@", "(a `", "(a ,@", "#(,", "`,@" }) |src| {
        var r: Reader = .init(src);
        try std.testing.expectError(error.Incomplete, r.next(a, f.sink()));
    }
}

test "next rejects a dot right after ` , and ,@, and a dot cannot hide inside them" {
    var f: Fixture = .init();
    defer f.deinit();
    for ([_][]const u8{ "`.", ",.", ",@.", "(a ,@ . b)", "(a . ,@ . b)", "(a . ,)", "#(, . a)" }) |src| {
        if (f.readOne(src)) |_| {
            std.debug.print("accepted {s}\n", .{src});
            return error.TestUnexpectedResult;
        } else |_| {}
    }
    try std.testing.expectError(error.UnexpectedDot, f.readOne("`."));
    try std.testing.expectError(error.UnexpectedDot, f.readOne(",@."));
    try std.testing.expectError(error.UnexpectedDot, f.readOne("(a . ,b c)"));
}

test "next reads a dotted pair and a dotted tail" {
    var f: Fixture = .init();
    defer f.deinit();
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("(1 . 2)", try f.roundTrip("(1 . 2)", &buf));
    try std.testing.expectEqualStrings("(1 2 . 3)", try f.roundTrip("(1 2 . 3)", &buf));
    try std.testing.expectEqualStrings("(a b c)", try f.roundTrip("(a . (b c))", &buf));
    try std.testing.expectEqualStrings("(a)", try f.roundTrip("(a . ())", &buf));
    try std.testing.expectEqualStrings("(1 2)", try f.roundTrip("(1 .(2))", &buf));
    try std.testing.expectEqualStrings("(a quote b)", try f.roundTrip("(a . 'b)", &buf));
    // ドットは単独のトークンである。これらは識別子だ。
    try std.testing.expectEqualStrings("(a ... .b)", try f.roundTrip("(a ... .b)", &buf));
    const pair = (try f.readOne("(1 . 2)")).asPair().?;
    try std.testing.expectEqual(1, pair.car.asFixnum().?);
    try std.testing.expectEqual(2, pair.cdr.asFixnum().?);
}

test "next rejects a dot that is not between an element and one datum" {
    var f: Fixture = .init();
    defer f.deinit();
    for ([_][]const u8{ ".", "'.", "( . 1)", "(1 . )", "(1 . 2 3)", "(1 . . 2)", "(1 . 2 .)", "(. )", "(1 . ' )" }) |src| {
        if (f.readOne(src)) |_| {
            std.debug.print("accepted {s}\n", .{src});
            return error.TestUnexpectedResult;
        } else |e| {
            if (e != error.UnexpectedDot and e != error.MissingDatum) {
                std.debug.print("{s}: {s}\n", .{ src, @errorName(e) });
                return error.TestUnexpectedResult;
            }
        }
    }
    // 未完了は誤りではない。
    var r: Reader = .init("(1 . 2");
    try std.testing.expectError(error.Incomplete, r.next(f.arena.allocator(), f.sink()));
    var r2: Reader = .init("(1 .");
    try std.testing.expectError(error.Incomplete, r2.next(f.arena.allocator(), f.sink()));
}

test "next reads the data of one source in turn, then null" {
    var f: Fixture = .init();
    defer f.deinit();
    var r: Reader = .init("1 (2)3 'x");
    const a = f.arena.allocator();
    try std.testing.expectEqual(1, (try r.next(a, f.sink())).?.asFixnum().?);
    try std.testing.expectEqual(.pair, (try r.next(a, f.sink())).?.kind());
    try std.testing.expectEqual(3, (try r.next(a, f.sink())).?.asFixnum().?);
    try std.testing.expectEqual(.pair, (try r.next(a, f.sink())).?.kind());
    try std.testing.expect(try r.next(a, f.sink()) == null);
    var empty: Reader = .init("  \n");
    try std.testing.expect(try empty.next(a, f.sink()) == null);
}

test "next tells an unfinished input from a stray close paren" {
    var f: Fixture = .init();
    defer f.deinit();
    const a = f.arena.allocator();
    // readOne ではなく `next` そのものを使う。readOne は、データがないことを Incomplete にしてしまう。
    var r: Reader = .init("(+ 1 (2)");
    try std.testing.expectError(error.Incomplete, r.next(a, f.sink()));
    var q: Reader = .init("'");
    try std.testing.expectError(error.Incomplete, q.next(a, f.sink()));
    var q2: Reader = .init("(a '");
    try std.testing.expectError(error.Incomplete, q2.next(a, f.sink()));
    try std.testing.expectError(error.UnexpectedCloseParen, f.readOne(")"));
    try std.testing.expectError(error.UnexpectedCloseParen, f.readOne("(1))"));
}

test "next reports a quote with nothing to quote" {
    var f: Fixture = .init();
    defer f.deinit();
    try std.testing.expectError(error.MissingDatum, f.readOne("')"));
    try std.testing.expectError(error.MissingDatum, f.readOne("(a ')"));
    try std.testing.expectError(error.MissingDatum, f.readOne("(a '' )"));
}

test "next rejects text that is neither an integer, a boolean nor an identifier" {
    var f: Fixture = .init();
    defer f.deinit();
    for ([_][]const u8{ "1+", "12a", "#tru", "#T", "#", "#)", "a'b" }) |src| {
        try std.testing.expectError(error.InvalidToken, f.readOne(src));
    }
}

test "next skips a line comment up to the end of the line" {
    var f: Fixture = .init();
    defer f.deinit();
    var buf: [64]u8 = undefined;
    try std.testing.expectEqual(1, (try f.readOne("1 ; コメント")).asFixnum().?);
    try std.testing.expectEqual(1, (try f.readOne("; 前\n1")).asFixnum().?);
    // コメントを終わらせるのは改行だけで、そこで読み取りは続きから再開する。
    try std.testing.expectEqualStrings("(+ 1 2)", try f.roundTrip("(+ 1 ; ここ\n 2)", &buf));
    try std.testing.expectEqualStrings("(+ 1 2)", try f.roundTrip("(+ 1 ; ここ\r\n 2)", &buf));
    // コメントの中の括弧・引用符・`;` は何も開閉しない。
    try std.testing.expectEqualStrings("(a b)", try f.roundTrip("(a ; ( ) \" ' ; #|\nb)", &buf));
    // コメントは、データのあいだのどこにでも置ける。
    try std.testing.expectEqualStrings("(quote a)", try f.roundTrip("'; c\na", &buf));
    try std.testing.expectEqualStrings("(1 . 2)", try f.roundTrip("(1 ;a\n. ;b\n2 ;c\n)", &buf));
    // `.` の直後が `;` でも、`.` はそこで終わる(`atDot` の区切りの判定)。
    try std.testing.expectEqualStrings("(1 . 2)", try f.roundTrip("(1 .;c\n2)", &buf));
    try std.testing.expectEqualStrings("#(1 2)", try f.roundTrip("#(1 ;a\n2)", &buf));
    // 空白だけの行とコメントだけの行が続いても、次のデータに届く。
    try std.testing.expectEqualStrings("x", try f.roundTrip(";a\n\n  ;b\n\t;c\nx", &buf));
}

test "next ends an identifier, a number and a boolean at a semicolon" {
    var f: Fixture = .init();
    defer f.deinit();
    const a = f.arena.allocator();
    // `;` は区切り文字なので、トークンはそこで終わり、残りはコメントである。
    try std.testing.expectEqualStrings("abc", f.heap.symbols.nameOf((try f.readOne("abc;コメント")).asSymbol().?));
    try std.testing.expectEqual(12, (try f.readOne("12;コメント")).asFixnum().?);
    try std.testing.expect((try f.readOne("#t;コメント")).isTrue());
    var r: Reader = .init("a;b\nc");
    try std.testing.expectEqualStrings("a", f.heap.symbols.nameOf((try r.next(a, f.sink())).?.asSymbol().?));
    try std.testing.expectEqualStrings("c", f.heap.symbols.nameOf((try r.next(a, f.sink())).?.asSymbol().?));
    try std.testing.expect(try r.next(a, f.sink()) == null);
}

test "next reads an input of nothing but comments as no data" {
    var f: Fixture = .init();
    defer f.deinit();
    const a = f.arena.allocator();
    for ([_][]const u8{ ";", "; コメント", ";\n", "; a\n; b\n", "  ;a\n\n;b", ";\r\n;" }) |src| {
        var r: Reader = .init(src);
        try std.testing.expect(try r.next(a, f.sink()) == null);
    }
}

test "next reports an unfinished datum when a comment hides the rest" {
    var f: Fixture = .init();
    defer f.deinit();
    const a = f.arena.allocator();
    // `)` がコメントの中にあれば、閉じていない。
    for ([_][]const u8{ "(+ 1 ; )", "(+ 1 2 ;)\n", "'; a", "(1 . ; c", "#(1 ; )" }) |src| {
        var r: Reader = .init(src);
        try std.testing.expectError(error.Incomplete, r.next(a, f.sink()));
    }
    // コメントは行の終わりまでなので、次の行の `)` は閉じる。
    try std.testing.expectEqual(.pair, (try f.readOne("(+ 1 ; (\n)")).kind());
}

test "next does not read a semicolon in a string or a character as a comment" {
    var f: Fixture = .init();
    defer f.deinit();
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("\"a;b\"", try f.roundTrip("\"a;b\"", &buf));
    try std.testing.expectEqualStrings("\";\"", try f.roundTrip("\";\" ; 後", &buf));
    // 文字列は複数行にまたがってよく、その中の `;` は行末まででも文字列の一部である。
    try std.testing.expectEqualStrings("\"a ; b\\nc\"", try f.roundTrip("\"a ; b\nc\"", &buf));
    try std.testing.expectEqual(';', (try f.readOne("#\\;")).asCharacter().?);
    try std.testing.expectEqual(';', (try f.readOne("#\\; ; 後")).asCharacter().?);
    try std.testing.expectEqualStrings("(#\\; 1)", try f.roundTrip("(#\\; 1)", &buf));
    try std.testing.expectEqualStrings("(\"x\" 1)", try f.roundTrip("(\"x\" ; ( \n 1)", &buf));
    // 文字や文字列のすぐ後の `;` は、やはりコメントを始める。
    try std.testing.expectEqual(';', (try f.readOne("#\\;;後")).asCharacter().?);
    try std.testing.expectEqual('a', (try f.readOne("#\\a;後")).asCharacter().?);
    try std.testing.expectEqualStrings("\"x\"", try f.roundTrip("\"x\";後", &buf));
    try std.testing.expectEqualStrings("(\"x\" #\\;)", try f.roundTrip("(\"x\";(\n#\\;)", &buf));
}

test "next skips block comments, which nest, wherever whitespace may stand" {
    var f: Fixture = .init();
    defer f.deinit();
    var buf: [64]u8 = undefined;
    try std.testing.expectEqual(1, (try f.readOne("#| a |# 1")).asFixnum().?);
    try std.testing.expectEqual(1, (try f.readOne("1 #| a |#")).asFixnum().?);
    // 入れ子の内側の `|#` は、内側だけを閉じる(R7RS 7.1.1 の <nested comment>)。
    try std.testing.expectEqual(1, (try f.readOne("#| a #| b |# c |# 1")).asFixnum().?);
    try std.testing.expectEqualStrings("(1 2)", try f.roundTrip("(1 #| x |# 2)", &buf));
    try std.testing.expectEqualStrings("(1 2)", try f.roundTrip("(1 #|x|#2)", &buf));
    // `#` は区切り文字ではないので、トークンの途中の `#|` はコメントを始めない。
    try std.testing.expectError(error.InvalidToken, f.readOne("(1#|x|# 2)"));
    try std.testing.expectEqualStrings("#(1 2)", try f.roundTrip("#(1 #|x|# 2)", &buf));
    try std.testing.expectEqualStrings("(quote a)", try f.roundTrip("' #| x |# a", &buf));
    // コメントの中の文字列、文字、行コメント、括弧は、何も始めない。
    try std.testing.expectEqual(1, (try f.readOne("#| \" ; ( #\\ |# 1")).asFixnum().?);
    try std.testing.expectEqual(1, (try f.readOne("#|\n( \n|#\n1")).asFixnum().?);
    // `|#` の `|` を `#|` と重ねて読まない。`#|#` は閉じていない。
    try std.testing.expectError(error.Incomplete, f.readOne("#|# 1"));
    try std.testing.expectEqual(1, (try f.readOne("#||# 1")).asFixnum().?);
    try std.testing.expectEqual(1, (try f.readOne("#|||# 1")).asFixnum().?);
}

test "next asks for more input inside a block comment" {
    var f: Fixture = .init();
    defer f.deinit();
    for ([_][]const u8{ "#|", "#| x", "#| #| x |#", "(1 #| x", "#| x |" }) |src| {
        try std.testing.expectError(error.Incomplete, f.readOne(src));
    }
    // 閉じる記号だけでは、コメントを始めない。`|` は縦棒の識別子を始め、閉じていない。
    try std.testing.expectError(error.Incomplete, f.readOne("|# 1"));
}

test "next reads an identifier between vertical lines as the symbol of the characters between them" {
    var f: Fixture = .init();
    defer f.deinit();
    const Case = struct { []const u8, []const u8 };
    // R7RS 2.1 の例と、7.1.1 の <symbol element> のエスケープ。
    for ([_]Case{
        .{ "|a b|", "a b" },
        .{ "||", "" },
        .{ "|H\\x65;llo|", "Hello" },
        .{ "|\\x3BB;|", "\u{3bb}" },
        .{ "|\\t\\t|", "\t\t" },
        .{ "|\\x9;\\x9;|", "\t\t" },
        .{ "|a\\|b|", "a|b" },
        .{ "|\\a\\b\\n\\r|", "\x07\x08\n\r" },
        // R7RS 2.1 の本文は、文字列と同じエスケープを許すとしている。
        .{ "|\\\"\\\\|", "\"\\" },
        // 空白、括弧、引用符、`;`、`#`、数の形も、名前の一部である。
        .{ "|(a) ; \"#t\" 1|", "(a) ; \"#t\" 1" },
        .{ "|1|", "1" },
        .{ "|.|", "." },
        // 生の文字は、そのまま名前に入る。行の終わりも、綴りのまま入る。
        .{ "|\u{3bb}|", "\u{3bb}" },
        .{ "|a\nb|", "a\nb" },
        .{ "|a\r\nb|", "a\r\nb" },
    }) |case| {
        const src, const name = case;
        const d = try f.readOne(src);
        std.testing.expectEqualStrings(name, f.heap.symbols.nameOf(d.asSymbol() orelse return error.TestUnexpectedResult)) catch |e| {
            std.debug.print("reading {f}\n", .{std.zig.fmtString(src)});
            return e;
        };
    }
    // 同じ名前の識別子は、どちらの書き方でも同じシンボルである。
    try std.testing.expectEqual((try f.readOne("abc")).asSymbol().?, (try f.readOne("|abc|")).asSymbol().?);
    try std.testing.expectEqual((try f.readOne("|\\t|")).asSymbol().?, (try f.readOne("|\\x9;|")).asSymbol().?);
}

test "an identifier between vertical lines ends at the closing vertical line" {
    var f: Fixture = .init();
    defer f.deinit();
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("(a b c)", try f.roundTrip("(|a| b |c|)", &buf));
    try std.testing.expectEqualStrings("(quote a)", try f.roundTrip("'|a|", &buf));
    // 縦線は区切り文字なので、前後のトークンとも別のデータになる。
    var r: Reader = .init("abc|def|ghi");
    for ([_][]const u8{ "abc", "def", "ghi" }) |name| {
        const d = (try r.next(f.arena.allocator(), f.sink())).?;
        try std.testing.expectEqualStrings(name, f.heap.symbols.nameOf(d.asSymbol().?));
    }
    try std.testing.expectEqual(null, try r.next(f.arena.allocator(), f.sink()));
}

test "a reader that folds case keeps an identifier between vertical lines as it is written" {
    var f: Fixture = .init();
    defer f.deinit();
    var buf: [64]u8 = undefined;
    f.fold_case = true;
    try std.testing.expectEqualStrings("(abc ABC)", try f.roundTrip("(ABC |ABC|)", &buf));
    // ASCII でない文字の名前も、畳み込みに渡らない。
    try std.testing.expectEqualStrings("\u{39b}", f.heap.symbols.nameOf((try f.readOne("|\u{39b}|")).asSymbol().?));
    try std.testing.expectEqualStrings("(a B)", try f.roundTrip("#!no-fold-case (#!fold-case A |B|)", &buf));
}

test "next asks for more input inside an identifier between vertical lines" {
    var f: Fixture = .init();
    defer f.deinit();
    for ([_][]const u8{ "|", "|abc", "(a |b", "|a\\", "|a\\x41", "|a\\x", "|a\nb" }) |src| {
        try std.testing.expectError(error.Incomplete, f.readOne(src));
    }
}

test "next rejects a backslash in an identifier between vertical lines that begins no escape" {
    var f: Fixture = .init();
    defer f.deinit();
    // 行継続は文字列だけのもので、<symbol element> には無い。
    // `\` の直後の空白と行の終わりは、どの綴り(スペース、タブ、LF、CR、CR LF)でも誤りである。
    for ([_][]const u8{ "|\\q|", "|\\x;|", "|\\xD800;|", "|\\x110000;|", "|\\xg;|", "|a\\\nb|", "|a\\ b|", "|a\\\tb|", "|a\\\rb|", "|a\\\r\nb|", "|a\\\t\nb|", "|\\X41;|" }) |src| {
        try std.testing.expectError(error.InvalidSymbolEscape, f.readOne(src));
    }
}

test "next makes no symbol whose name is not UTF-8, when it is given bytes that are not" {
    var f: Fixture = .init();
    defer f.deinit();
    // 通常の入口は入力全体を先に検査するが、リーダを直接使うとき(ファズ)は、不正なバイトが
    // 縦棒の間に来うる。文字列と同じく、名前にする前に確かめる。
    for ([_][]const u8{ "|\xff|", "|a\xc3|", "(|\xed\xa0\x80|)" }) |src| {
        try std.testing.expectError(error.InvalidUtf8, f.readOne(src));
    }
}

test "next reads past the datum after a datum comment" {
    var f: Fixture = .init();
    defer f.deinit();
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("(1 3)", try f.roundTrip("(1 #;2 3)", &buf));
    try std.testing.expectEqualStrings("(1 3)", try f.roundTrip("(1 #; 2 3)", &buf));
    try std.testing.expectEqualStrings("(c)", try f.roundTrip("(#;(a (b)) c)", &buf));
    try std.testing.expectEqual(2, (try f.readOne("#;1 2")).asFixnum().?);
    // `#;` に続く <intertoken space> の中の `#;` は、後ろの1つのデータを先に捨てる。
    try std.testing.expectEqual(3, (try f.readOne("#; #;1 2 3")).asFixnum().?);
    // 捨てるデータの略記は、そのデータの一部である。略記のあとのコメントは、略記の
    // データの前の空白である。
    try std.testing.expectEqual(2, (try f.readOne("#;'1 2")).asFixnum().?);
    try std.testing.expectEqualStrings("(quote b)", try f.roundTrip("'#;a b", &buf));
    try std.testing.expectEqualStrings("(a . c)", try f.roundTrip("(a . #;b c)", &buf));
    try std.testing.expectEqualStrings("#(1 3)", try f.roundTrip("#(1 #;2 3)", &buf));
    try std.testing.expectEqualStrings("#u8(1 3)", try f.roundTrip("#u8(1 #;2 3)", &buf));
    try std.testing.expectEqualStrings("(1)", try f.roundTrip("(1 #;\"x)\")", &buf));
    // 捨てるデータは、読めるデータでなければならない。
    try std.testing.expectError(error.InvalidToken, f.readOne("#;#z 1"));
    // 捨てるデータしかない入力には、データが無い。
    var r: Reader = .init("#;1 #;(2)");
    try std.testing.expectEqual(null, try r.next(f.arena.allocator(), f.sink()));
    try std.testing.expectEqual(r.src.len, r.pos);
}

test "next reports a datum comment with no datum to comment out" {
    var f: Fixture = .init();
    defer f.deinit();
    for ([_][]const u8{ "(a #;)", "(a #; )", "#(#;)", "(#; #;1)" }) |src| {
        try std.testing.expectError(error.MissingCommentedDatum, f.readOne(src));
    }
    for ([_][]const u8{ "#;", "(a #;", "#; #;1" }) |src| {
        try std.testing.expectError(error.Incomplete, f.readOne(src));
    }
    // ドットは、捨てるデータにならない。
    try std.testing.expectError(error.UnexpectedDot, f.readOne("(a #; . b)"));
}

test "a directive switches the folding of what the reader reads after it" {
    var f: Fixture = .init();
    defer f.deinit();
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings("abc", f.heap.symbols.nameOf((try f.readOne("#!fold-case ABC")).asSymbol().?));
    // 入力の途中で効く。指令より前に読んだものは、そのままである。
    try std.testing.expectEqualStrings("(A b #\\newline #\\A \"S\")", try f.roundTrip("(A #!fold-case B #\\NEWLINE #\\A \"S\")", &buf));
    try std.testing.expectEqualStrings("(a B)", try f.roundTrip("#!fold-case (A #!no-fold-case B)", &buf));
    // 指令の状態は、読み手に残り、次のデータにも効く。
    var r: Reader = .init("#!fold-case A B #!no-fold-case C");
    const names = [_][]const u8{ "a", "b", "C" };
    for (names) |name| {
        const d = (try r.next(f.arena.allocator(), f.sink())).?;
        try std.testing.expectEqualStrings(name, f.heap.symbols.nameOf(d.asSymbol().?));
    }
    try std.testing.expect(!r.fold_case);
    // 区切り文字か入力の終わりが続けば、指令である(R7RS 7.1.1 の注)。
    try std.testing.expectEqualStrings("(a)", try f.roundTrip("#!fold-case(A)", &buf));
    try std.testing.expectEqualStrings("\"S\"", try f.roundTrip("#!fold-case\"S\"", &buf));
    try std.testing.expectEqualStrings("x", f.heap.symbols.nameOf((try f.readOne("#!fold-case;c\nX")).asSymbol().?));
    // 指令だけの入力には、データが無い。
    var only: Reader = .init("#!fold-case");
    try std.testing.expectEqual(null, try only.next(f.arena.allocator(), f.sink()));
    try std.testing.expect(only.fold_case);
}

test "next rejects a directive that is spelled otherwise or not followed by a delimiter" {
    var f: Fixture = .init();
    defer f.deinit();
    for ([_][]const u8{ "#!fold-casex A", "#!no-fold-case1", "#!FOLD-CASE A", "#!fold A", "#!", "#! fold-case", "#!eof", "#!fold-case#|c|# A" }) |src| {
        try std.testing.expectError(error.InvalidToken, f.readOne(src));
    }
    // `#!` が `#` に続くトークンの中に現れても、指令ではない。
    try std.testing.expectError(error.InvalidToken, f.readOne("a#!fold-case"));
}

test "a line comment ends at a carriage return as well as at a newline" {
    var f: Fixture = .init();
    defer f.deinit();
    var buf: [64]u8 = undefined;
    // R7RS 7.1.1 の <line ending> は、改行、CR と改行、CR のどれかである。
    try std.testing.expectEqualStrings("(a b)", try f.roundTrip("(a ; x\rb)", &buf));
    try std.testing.expectEqualStrings("(a b)", try f.roundTrip("(a ; x\r\nb)", &buf));
}

test "next reads the numbers that are spelled like peculiar identifiers as numbers" {
    var f: Fixture = .init();
    defer f.deinit();
    for ([_][]const u8{ "+inf.0", "-inf.0", "+nan.0", "-nan.0", "+i", "-i", "+INF.0", "+.1" }) |src| {
        try std.testing.expect((try f.readOne(src)).kind() != .symbol);
    }
    // 綴りの近いものは、識別子のままである。
    for ([_][]const u8{ "+in", "-inf", "+inf.01", "+ia", "i" }) |src| {
        _ = try f.readOne(src);
    }
}

test "readsAsIdentifier follows the R7RS grammar, peculiar identifiers included" {
    for ([_][]const u8{ "+", "-", "...", "x", "list->vector", "<=?", "a.b", "+a", "-@", "+.a", "..", ".a", "->x", ".+", ".-x", ".@x" }) |s| {
        if (!readsAsIdentifier(s)) {
            std.debug.print("rejected {s}\n", .{s});
            return error.TestUnexpectedResult;
        }
    }
    for ([_][]const u8{ ".", "+.", "+.1", ".1", "1a", "a#", "@a" }) |s| {
        if (readsAsIdentifier(s)) {
            std.debug.print("accepted {s}\n", .{s});
            return error.TestUnexpectedResult;
        }
    }
}

test "a datum label and a reference to it read as one object, which can hold itself" {
    var f: Fixture = .init();
    defer f.deinit();
    // データとして読む。コードとしての循環は、下の別のテストが見る。
    f.code = false;
    // 循環するリスト(R7RS 2.4 の例 `#0=(a b c . #0#)` と同じ形)。
    const cycle = (try f.readOne("#0=(a b c . #0#)")).asPair().?;
    const third = cycle.cdr.asPair().?.cdr.asPair().?;
    try std.testing.expect(third.cdr.asPair().? == cycle);
    // 循環するベクタ。
    const v = (try f.readOne("#0=#(1 #0#)")).asVector().?;
    try std.testing.expect(v.items[1].asVector().? == v);
    // 共有。ラベルを読み終えたあとの参照は、同じオブジェクトである。
    const shared = (try f.readOne("(#0=(x) #0# #0#)")).asPair().?;
    const second = shared.cdr.asPair().?;
    try std.testing.expect(shared.car.asPair().? == second.car.asPair().?);
    try std.testing.expect(shared.car.asPair().? == second.cdr.asPair().?.car.asPair().?);
    // 入れ子のラベル。内側の循環と外側の循環が、どちらも閉じる。
    const outer = (try f.readOne("#0=(#1=(b . #1#) . #0#)")).asPair().?;
    try std.testing.expect(outer.cdr.asPair().? == outer);
    const inner = outer.car.asPair().?;
    try std.testing.expect(inner.cdr.asPair().? == inner);
    // 略記の中のラベルと、略記をラベルにしたもの。
    const quoted = (try f.readOne("'#0=(a #0#)")).asPair().?;
    const body = quoted.cdr.asPair().?.car.asPair().?;
    try std.testing.expect(body.cdr.asPair().?.car.asPair().? == body);
    const labelled_quote = (try f.readOne("(#0='a #0#)")).asPair().?;
    try std.testing.expect(labelled_quote.car.asPair().? == labelled_quote.cdr.asPair().?.car.asPair().?);
    // 1つのデータに2つのラベル。数は10進の値で比べる。
    const both = (try f.readOne("(#0=#1=(a) #0# #01#)")).asPair().?;
    const tail = both.cdr.asPair().?;
    try std.testing.expect(both.car.asPair().? == tail.car.asPair().?);
    try std.testing.expect(both.car.asPair().? == tail.cdr.asPair().?.car.asPair().?);
    // ペアでもベクタでもないデータにも、ラベルを付けられる。
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("(a a 12345 12345)", try f.roundTrip("(#7=a #7# #123456789=12345 #123456789#)", &buf));
}

test "a reader of code rejects a circular reference outside a literal" {
    var f: Fixture = .init();
    defer f.deinit();
    // R7RS 2.4 の例と、関数の呼び出しの中の循環、quasiquote の中の循環(同節が誤りとする)。
    for ([_][]const u8{
        "#1=(begin (display #\\x) #1#)",
        "#0=(a . #0#)",
        "(f #0=(g #0#))",
        "`#0=(a . #0#)",
        "(quasiquote #0=(a ,@#0#))",
        // `quote` の形でなければ、中に入る。
        "(quote . #0=(a . #0#))",
        "(list 'a #0=(b #0#))",
        // cdr として出会う `(quote x)` は、quote の式ではなく、リストの尾部である。
        "#0=(lambda quote #0#)",
        "(define (h . quote) #0=(if #f quote #0#))",
        "(f . '#0=(a . #0#))",
        // quasiquote の中では、quote の形とベクタの中にも入る。
        "`#(1 ,#0=(a . #0#))",
        "`(1 '#0=(a . #0#))",
        "`#0=#(1 #0#)",
        // quasiquote の外で辿り終えたペアにも、quasiquote の中から着けば、quote の中まで辿る。
        "(#0=(a '#1=(b . #1#)) `#0#)",
    }) |src| {
        _ = f.readOne(src) catch |e| {
            if (e == error.CircularCode) continue;
            std.debug.print("reading {s}: {}\n", .{ src, e });
            return e;
        };
        std.debug.print("reading {s}: accepted\n", .{src});
        return error.TestUnexpectedResult;
    }
}

test "a reader that keeps positions records where each list and abbreviation began" {
    var f: Fixture = .init();
    defer f.deinit();
    var table: positions_mod.Table = .init(std.testing.allocator);
    defer table.deinit();
    const file = try table.addFile("a.scm");
    var sink = f.sink();
    sink.positions = .{ .table = &table, .file = file };
    // 2行目の `(b` は4桁目、`'c` は3行目の3桁目、`(d)` は CR LF のあとの4行目、`#(` の中の
    // `(e)` は `あ` を1文字と数えて7桁目に始まる。
    var r: Reader = .init("(a\n   (b\n  'c) . ())\r\n#;(x) (d)\n#(\"\u{3042}\" (e))");
    const first = (try r.next(f.arena.allocator(), sink)).?;
    const Expected = struct { datum: Value, line: u32, column: u32 };
    const p = first.asPair().?;
    const b = p.cdr.asPair().?.car;
    const quoted = b.asPair().?.cdr.asPair().?.car;
    for ([_]Expected{
        .{ .datum = first, .line = 1, .column = 1 },
        .{ .datum = b, .line = 2, .column = 4 },
        .{ .datum = quoted, .line = 3, .column = 3 },
    }) |e| {
        const at = table.of(e.datum) orelse return error.TestExpectedPosition;
        try std.testing.expectEqual(file, at.file);
        try std.testing.expectEqual(positions_mod.Location{ .line = e.line, .column = e.column }, at.location);
    }
    // 先頭のペアだけを記録する。リストの2番目のペアと、`()` は記録しない。
    try std.testing.expect(table.of(p.cdr) == null);
    const d = (try r.next(f.arena.allocator(), sink)).?;
    try std.testing.expectEqual(positions_mod.Location{ .line = 4, .column = 7 }, table.of(d).?.location);
    const v = (try r.next(f.arena.allocator(), sink)).?;
    try std.testing.expectEqual(positions_mod.Location{ .line = 5, .column = 7 }, table.of(v.asVector().?.items[1]).?.location);
    // 記録しない読み手は、表に何も足さない。
    const before = table.by_pair.count();
    var plain: Reader = .init("(a (b))");
    _ = (try plain.next(f.arena.allocator(), f.sink())).?;
    try std.testing.expectEqual(before, table.by_pair.count());
}

test "a reader of code accepts circular data in a literal, and shared code" {
    var f: Fixture = .init();
    defer f.deinit();
    // quote の中と、自分自身に評価されるベクタの中の循環は、リテラルの中にある。
    for ([_][]const u8{
        "'#0=(a . #0#)",
        "(quote #0=(a . #0#))",
        "(f '#0=(a . #0#) #(#1=(b . #1#)))",
        "#0=(quote #0#)",
        "#0=#(1 #0#)",
        // 共有は循環ではない。読み終えたラベルへの参照は、同じものを指すだけである。
        "(#0=(f x) #0# #0#)",
        "(+ #0=(* 2 3) #0#)",
        "`(#0=(a #(b)) ,#0# #0#)",
        // cdr として出会う `(quasiquote x)` は、quasiquote の式ではない。
        "(f quasiquote #(#0=(a . #0#)))",
        // 共有したコードと、リテラルの中の循環が、同じデータにある。辿り終えたペアに再び
        // 着くのは共有で、循環ではない。
        "(let ((y 1)) (list #0=(+ y 1) #0# (eq? '#1=(a . #1#) 'b)))",
        "(f #0=(g) #0# '#1=(a . #1#))",
    }) |src| {
        _ = f.readOne(src) catch |e| {
            std.debug.print("reading {s}: {}\n", .{ src, e });
            return e;
        };
    }
    // データとして読む読み手(5l の `read`)は、どこの循環も受け入れる。
    f.code = false;
    _ = try f.readOne("#1=(begin (display #\\x) #1#)");
}

test "a datum label is in scope only in the rest of the outermost datum it is in" {
    var f: Fixture = .init();
    defer f.deinit();
    // 最上位のデータが変われば、ラベルは見えない。
    var r: Reader = .init("#0=a #0#");
    _ = try r.next(f.arena.allocator(), f.sink());
    try std.testing.expectError(error.UndefinedLabel, r.next(f.arena.allocator(), f.sink()));
    // 前方参照は誤りである(R7RS 2.4)。
    try std.testing.expectError(error.UndefinedLabel, f.readOne("(#0# #0=a)"));
    try std.testing.expectError(error.UndefinedLabel, f.readOne("#0#"));
    // データコメントで捨てたデータの中のラベルは、捨てたデータの外から見えない。
    try std.testing.expectError(error.UndefinedLabel, f.readOne("(#;#0=a #0#)"));
    // 捨てたデータの中から外のラベルを参照してもよい。
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("(a b)", try f.roundTrip("(#0=a #;#0# b)", &buf));
    try std.testing.expectEqualStrings("(a)", try f.roundTrip("#0=(a #;#0#)", &buf));
}

test "next reports a datum label that is defined twice or labels no datum" {
    var f: Fixture = .init();
    defer f.deinit();
    try std.testing.expectError(error.DuplicateLabel, f.readOne("(#0=a #0=b)"));
    try std.testing.expectError(error.DuplicateLabel, f.readOne("#0=(#0=a)"));
    // ラベルの付いたものが、ラベルそのものへの参照だけである(R7RS 2.4 の `#<n>= #<n>#`)。
    try std.testing.expectError(error.MissingLabeledDatum, f.readOne("#0=#0#"));
    try std.testing.expectError(error.MissingLabeledDatum, f.readOne("#0=#1=#0#"));
    try std.testing.expectError(error.MissingLabeledDatum, f.readOne("(#0=)"));
    try std.testing.expectError(error.Incomplete, f.readOne("#0="));
    try std.testing.expectError(error.Incomplete, f.readOne("#0=(a"));
    // ドットは、ラベルを付けるデータにならない。
    try std.testing.expectError(error.UnexpectedDot, f.readOne("(a #0= . b)"));
    // バイトベクタの要素は <byte> で、ラベルを付けられない(R7RS 7.1.2)。
    try std.testing.expectError(error.InvalidByte, f.readOne("#u8(#0=1)"));
    try std.testing.expectError(error.InvalidByte, f.readOne("(#0=1 #u8(#0#))"));
    // 数字の後ろに `=` も `#` も無ければ、ラベルではない。
    for ([_][]const u8{ "#0", "#0x", "#12 a", "#=a", "##", "#99999999999999999999999=a" }) |src| {
        try std.testing.expectError(error.InvalidToken, f.readOne(src));
    }
}

test "next reads nesting far deeper than a recursive reader could" {
    var f: Fixture = .init();
    defer f.deinit();
    const depth = 100_000;
    const src = try f.arena.allocator().alloc(u8, depth * 2);
    @memset(src[0..depth], '(');
    @memset(src[depth..], ')');
    var d = try f.readOne(src);
    // 一番内側の `()` は空リストなので、ペアの数は括弧の対の数より 1 つ少ない。
    var pairs: usize = 0;
    while (d.asPair()) |p| : (pairs += 1) d = p.car;
    try std.testing.expectEqual(depth - 1, pairs);
    try std.testing.expectEqual(.empty_list, d.kind());
}

test "next reads a long chain of quotes and a long list" {
    var f: Fixture = .init();
    defer f.deinit();
    const n = 100_000;
    const quotes = try f.arena.allocator().alloc(u8, n + 1);
    @memset(quotes[0..n], '\'');
    quotes[n] = '1';
    var d = try f.readOne(quotes);
    var depth: usize = 0;
    while (d.asPair()) |p| : (depth += 1) d = p.cdr.asPair().?.car;
    try std.testing.expectEqual(n, depth);

    const list = try f.arena.allocator().alloc(u8, 2 * n + 2);
    list[0] = '(';
    for (0..n) |k| {
        list[1 + 2 * k] = '1';
        list[2 + 2 * k] = ' ';
    }
    list[2 * n + 1] = ')';
    var l = try f.readOne(list);
    var count: usize = 0;
    while (l.asPair()) |p| : (count += 1) l = p.cdr;
    try std.testing.expectEqual(n, count);
}

test "next reads a long chain of ` , and ,@" {
    var f: Fixture = .init();
    defer f.deinit();
    const n = 100_000;
    const chain = try f.arena.allocator().alloc(u8, 2 * n + 1);
    for (0..n) |k| {
        chain[2 * k] = ',';
        chain[2 * k + 1] = '@';
    }
    chain[2 * n] = '1';
    var d = try f.readOne(chain);
    var depth: usize = 0;
    while (d.asPair()) |p| : (depth += 1) {
        try std.testing.expectEqualStrings("unquote-splicing", f.heap.symbols.nameOf(p.car.asSymbol().?));
        d = p.cdr.asPair().?.car;
    }
    try std.testing.expectEqual(n, depth);
}

test "next reads a vector of data, the empty vector and nesting" {
    var f: Fixture = .init();
    defer f.deinit();
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("#(1 2 3)", try f.roundTrip(" #(1\t2\r\n3) ", &buf));
    try std.testing.expectEqualStrings("#()", try f.roundTrip("#()", &buf));
    try std.testing.expectEqualStrings("#()", try f.roundTrip("#( )", &buf));
    try std.testing.expectEqualStrings("#(a #t -1)", try f.roundTrip("#(a #t -1)", &buf));
    try std.testing.expectEqualStrings("#(1 #(2 3) ())", try f.roundTrip("#(1 #(2 3) ())", &buf));
    try std.testing.expectEqualStrings("#(#(#()))", try f.roundTrip("#(#(#()))", &buf));
    try std.testing.expectEqualStrings("(1 #(2) (3 #()))", try f.roundTrip("(1 #(2) (3 #()))", &buf));
    try std.testing.expectEqualStrings("#((1 . 2) (3 4 . 5))", try f.roundTrip("#((1 . 2) (3 4 . 5))", &buf));
    try std.testing.expectEqualStrings("(a . #(1))", try f.roundTrip("(a . #(1))", &buf));
    // `(` は区切り文字なので、ベクタは別のデータのすぐ後に続けてよい。
    try std.testing.expectEqualStrings("(#(1) #(2))", try f.roundTrip("(#(1)#(2))", &buf));
    const v = try f.readOne("#(1 2)");
    try std.testing.expectEqual(.vector, v.kind());
    try std.testing.expectEqual(2, v.asVector().?.items.len);
    try std.testing.expectEqual(2, v.asVector().?.items[1].asFixnum().?);
}

test "next reads a quote before and inside a vector" {
    var f: Fixture = .init();
    defer f.deinit();
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("(quote #(1 2))", try f.roundTrip("'#(1 2)", &buf));
    try std.testing.expectEqualStrings("#((quote a) b)", try f.roundTrip("#('a b)", &buf));
    try std.testing.expectEqualStrings("#((quote #(1)))", try f.roundTrip("#('#(1))", &buf));
    try std.testing.expectEqualStrings("(quote (quote #()))", try f.roundTrip("''#()", &buf));
}

test "next reports a dot in a vector" {
    var f: Fixture = .init();
    defer f.deinit();
    for ([_][]const u8{ "#(1 . 2)", "#(. 1)", "#(1 .)", "#(.)", "'#(a . b)", "#(1 (2) . 3)", "(#(1 . 2))" }) |src| {
        try std.testing.expectError(error.UnexpectedDot, f.readOne(src));
    }
    // ベクタの中のリストにあるドットは、やはりそのリスト自身のものである。
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("#((1 . 2))", try f.roundTrip("#((1 . 2))", &buf));
    // `...` と `.a` は、ベクタの中でも識別子である。
    try std.testing.expectEqualStrings("#(... .a)", try f.roundTrip("#(... .a)", &buf));
}

test "next tells an unclosed vector from a stray close paren" {
    var f: Fixture = .init();
    defer f.deinit();
    const a = f.arena.allocator();
    for ([_][]const u8{ "#(", "#(1 2", "#(1 (2)", "(#(1)", "#(#(1)", "#('", "#(1 'a" }) |src| {
        var r: Reader = .init(src);
        try std.testing.expectError(error.Incomplete, r.next(a, f.sink()));
    }
    try std.testing.expectError(error.UnexpectedCloseParen, f.readOne("#(1 2))"));
    try std.testing.expectError(error.MissingDatum, f.readOne("#(')"));
    // `#(` でも `#\` でもない `#` は、やはりデータではない。
    try std.testing.expectError(error.InvalidToken, f.readOne("#"));
    try std.testing.expectError(error.InvalidToken, f.readOne("#)"));
    // `#u8` は、`(` が続かなければバイトベクタの開きではない。
    try std.testing.expectError(error.InvalidToken, f.readOne("#u8"));
    try std.testing.expectError(error.InvalidToken, f.readOne("#u8 (1)"));
    try std.testing.expectError(error.InvalidToken, f.readOne("#u8[1]"));
}

test "next reads a bytevector of bytes, the empty one and nesting" {
    var f: Fixture = .init();
    defer f.deinit();
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("#u8(0 10 5)", try f.roundTrip(" #u8(0\t10\r\n5) ", &buf));
    try std.testing.expectEqualStrings("#u8()", try f.roundTrip("#u8()", &buf));
    try std.testing.expectEqualStrings("#u8()", try f.roundTrip("#u8( )", &buf));
    try std.testing.expectEqualStrings("#u8(0 255)", try f.roundTrip("#u8(0 255)", &buf));
    try std.testing.expectEqualStrings("#u8(1 2)", try f.roundTrip("#u8(+1 002)", &buf));
    try std.testing.expectEqualStrings("(#u8(1) #(#u8(2) #u8()))", try f.roundTrip("(#u8(1) #(#u8(2) #u8()))", &buf));
    try std.testing.expectEqualStrings("(a . #u8(1))", try f.roundTrip("(a . #u8(1))", &buf));
    // `(` は区切り文字なので、別のデータのすぐ後に続けてよい。
    try std.testing.expectEqualStrings("(#u8(1) #u8(2))", try f.roundTrip("(#u8(1)#u8(2))", &buf));
    try std.testing.expectEqualStrings("(quote #u8(1 2))", try f.roundTrip("'#u8(1 2)", &buf));
    const v = try f.readOne("#u8(7 8)");
    try std.testing.expectEqual(.bytevector, v.kind());
    try std.testing.expectEqualSlices(u8, &.{ 7, 8 }, v.asBytevector().?.bytes);
}

test "next refuses what is not a byte in a bytevector, and reports a dot or an unclosed one" {
    var f: Fixture = .init();
    defer f.deinit();
    for ([_][]const u8{ "#u8(256)", "#u8(-1)", "#u8(1000)", "#u8(a)", "#u8(\"a\")", "#u8(#\\a)", "#u8(#t)", "#u8(())", "#u8((1))", "#u8(#(1))", "#u8(1 'a)", "#u8(#u8())", "#u8(1 256)", "(#u8(256))" }) |src| {
        try std.testing.expectError(error.InvalidByte, f.readOne(src));
    }
    try std.testing.expectEqualStrings("invalid byte in bytevector", describe(error.InvalidByte));
    for ([_][]const u8{ "#u8(1 . 2)", "#u8(. 1)", "#u8(1 .)", "#u8(.)", "'#u8(1 . 2)" }) |src| {
        try std.testing.expectError(error.UnexpectedDot, f.readOne(src));
    }
    const a = f.arena.allocator();
    for ([_][]const u8{ "#u8(", "#u8(1 2", "(#u8(1)", "#u8(1 '" }) |src| {
        var r: Reader = .init(src);
        try std.testing.expectError(error.Incomplete, r.next(a, f.sink()));
    }
    try std.testing.expectError(error.UnexpectedCloseParen, f.readOne("#u8(1 2))"));
    try std.testing.expectError(error.MissingDatum, f.readOne("#u8(')"));
}

test "next makes a long bytevector in one allocation of its own" {
    var f: Fixture = .init();
    defer f.deinit();
    const n = 5000;
    const src = try f.arena.allocator().alloc(u8, 4 + n * 4 + 1);
    @memcpy(src[0..4], "#u8(");
    for (0..n) |k| @memcpy(src[4 + 4 * k ..][0..4], "255 ");
    src[src.len - 1] = ')';
    const v = try f.readOne(src);
    try std.testing.expectEqual(n, v.asBytevector().?.bytes.len);
    for (v.asBytevector().?.bytes) |b| try std.testing.expectEqual(255, b);
}

test "next reads vectors nested far deeper than a recursive reader could" {
    var f: Fixture = .init();
    defer f.deinit();
    const depth = 100_000;
    const src = try f.arena.allocator().alloc(u8, depth * 3);
    for (0..depth) |k| @memcpy(src[2 * k ..][0..2], "#(");
    @memset(src[depth * 2 ..], ')');
    var d = try f.readOne(src);
    // 一番内側の `#()` には要素がないので、連なるベクタは `depth` 個で、その間の
    // つながりは 1 つ少ない。
    var vectors: usize = 0;
    while (d.asVector()) |v| : (vectors += 1) {
        if (v.items.len == 0) break;
        d = v.items[0];
    }
    try std.testing.expectEqual(depth - 1, vectors);
    try std.testing.expectEqual(.vector, d.kind());
}

test "next reads a long vector" {
    var f: Fixture = .init();
    defer f.deinit();
    const n = 100_000;
    const src = try f.arena.allocator().alloc(u8, 2 * n + 3);
    @memcpy(src[0..2], "#(");
    for (0..n) |k| {
        src[2 + 2 * k] = '1';
        src[3 + 2 * k] = ' ';
    }
    src[2 * n + 2] = ')';
    const v = try f.readOne(src);
    try std.testing.expectEqual(n, v.asVector().?.items.len);
}

/// The longest input one fuzz run reads, in bytes.
/// 長い入力はファザーの探索を遅くするだけで、深いネストなどの大きさに比例する誤りは、
/// 規模を試すテストが受け持つ。
const fuzz_max_input = 1024;

/// A corpus entry for `fuzzReader` that holds `text` as its input.
/// `Smith.slice` が読む形は、4 バイトのリトルエンディアンの長さに、その長さのバイト列が
/// 続くものである。
///
/// Why: 配列はコンパイル時に作る。実行時に作った配列のアドレスを返すと、関数が戻った
/// あとの死んだスタックを指し、初期入力がテストに届かない(PR #57 のレビューで見つかった)。
fn fuzzSeed(comptime text: []const u8) []const u8 {
    comptime std.debug.assert(text.len <= fuzz_max_input);
    const bytes = comptime std.mem.toBytes(std.mem.nativeToLittle(u32, text.len)) ++ text[0..text.len].*;
    return &bytes;
}

/// The inputs `zig build test` reads, as text.
/// `zig build test` は、ここにある入力を順に 1 回ずつ通り、最後にテストランナーが付ける
/// 空の入力を 1 回通る。入力の終わりで止まるトークン(`.` `#`)と、不正な UTF-8 を含む。
const fuzz_inputs = [_][]const u8{
    "(define (fact n) (if (= n 0) 1 (* n (fact (- n 1)))))",
    "'(1 . (2 3)) #(1 #(2)) ''() #t #false",
    "\"a\\tb\\x41;\" #\\a #\\space #\\x41 #\\(",
    "1 ; comment\n  foo ; (\n",
    "(a . b c)",
    "(1 . ",
    ")",
    "'",
    "\"unterminated",
    "99999999999999999999 -1 +1 ... +.5 1/2",
    "#( . ) ( . 1) '. # #\\",
    // 入力の終わりで止まるトークン。終わりの 1 つ先を読む誤りは、ここで見つかる。
    ".",
    "(a .",
    "#",
    "'#",
    // 文字列の `\x...;` と、文字の名前と 16 進(tests/scheme/0014、0015 から)。
    "\"\\x41;bc\" \"a\\x41;b\" \"\\x3bb;\" \"\\x0;\" \"\\x10;\"",
    "#\\alarm #\\delete #\\newline #\\null #\\x3bb #\\x",
    // 1 バイトに収まる値の 16 進エスケープ。UTF-8 では 2 バイトになる。
    "\"\\x80;\" \"\\xe9;\" \"\\xff;\"",
    // 縦棒の識別子(スライス 5b): エスケープ、空の名前、閉じないもの、誤ったエスケープ。
    "|a b| |\\x3bb;| || |a\\|b| |\\q| |abc",
    // データラベル(スライス 5c): 循環、共有、入れ子、未定義、二重の定義、データの無いもの。
    "#0=(a . #0#) #1=#(1 #1#) (#2=(x) #2# #2#) '#3=(#4=(b . #4#) . #3#)",
    "(#0=a #0=b) #0# #0=#0# #0=",
    // スカラ値でない 16 進エスケープ。
    "\"\\xD800;\" \"\\x110000;\" \"\\xDFFF;\" #\\xD800 #\\x110000",
    "\"λ\" #\\λ あ #\\x3bb",
    // 不正な UTF-8。`#\` の後ろの不正な先頭バイト、途中で切れた先頭バイト。
    "\"\xff\" #\\\xff #\\\xc3 \xe3\x81",
    "#\\\xe3\x81",
    "#\\\xe3",
    // 畳み込む読み手の経路(`fuzzReadAll` は、入力の長さが奇数のときに畳み込む)。大文字の
    // 識別子、文字名、16 進の `X`、ASCII でない識別子と、畳み込みで名前にならないもの。
    "(DEFINE Foo #\\NEWLINE #\\X41 x) ",
    "(DEFINE Foo λ) #\\X41g #\\Newlin ",
    // ASCII でない識別子(スライス 4u4): 畳み込まれるもの(ギリシャ文字、ケルビン記号、4 バイトの
    // Deseret)、符号の後ろ、U+200D、最初の文字に使えない Nd と Mc、空白、不正な UTF-8、途中で切れた文字。
    // 同じ綴りを、末尾の空白の有無で長さの偶奇を変えて 2 つ置く(畳み込む読み手と畳み込まない読み手)。
    "(ΛΑΜΒΔΑ ΟΔΟΣ \u{212A}x \u{10400} +Λ .Λ a\u{200D} → 😀) ",
    "(ΛΑΜΒΔΑ ΟΔΟΣ \u{212A}x \u{10400} +Λ .Λ a\u{200D} → 😀)",
    "\u{664} \u{664}x \u{903} a\u{A0}b \u{378} a\u{FFFF} Λ# 1Λ",
    "(a\xce) λ\xcf (\xce",
    // 評価器の入力に出る綴り(計画書 0025 のスライス 6i-3)。データの注釈と、それを重ねた形、
    // 入れ子のブロック注釈と閉じないもの、読み手の畳み込みの指令、文字の名前の残り。
    "(1 #;(ignored) 2 #;#;a b 3) #; ",
    "#| outer #| inner |# still |# x #| open #| only |#",
    "#!fold-case ABC #!no-fold-case Abc #!unknown",
    "#\\tab #\\return #\\escape #\\backspace #\\TAB",
    // バイトベクタと、基数や正確さの接頭辞、指数、無限大と NaN の数の綴り。
    "#u8(1 2 255) #u8(256) #u8( #x1F #b101 #o17 #e1.5 #i1/2 1e3 -2.5e-2 +inf.0 -nan.0",
    // 行の続きのエスケープと、文字列のエスケープの残り。
    "\"line1 \\\n   continued\" \"\\a\\b\\t\\n\\r\\\"\\\\\"",
};

/// `fuzz_inputs` as corpus entries.
const fuzz_corpus: []const []const u8 = blk: {
    var seeds: [fuzz_inputs.len][]const u8 = undefined;
    for (fuzz_inputs, 0..) |text, i| seeds[i] = fuzzSeed(text);
    const done = seeds;
    break :blk &done;
};

/// Whether every string in `v` holds valid UTF-8 (ADR-0008).
/// データラベルで循環と共有ができるので、訪問済みの集合を持って辿る。
fn stringsAreUtf8(gpa: std.mem.Allocator, v: Value) error{OutOfMemory}!bool {
    var visited: std.AutoHashMapUnmanaged(usize, void) = .empty;
    defer visited.deinit(gpa);
    var stack: std.ArrayList(Value) = .empty;
    defer stack.deinit(gpa);
    try stack.append(gpa, v);
    while (stack.pop()) |cur| {
        if (cur.asString()) |s| {
            if (!std.unicode.utf8ValidateSlice(s.bytes)) return false;
        } else if (cur.asVector()) |vec| {
            if ((try visited.getOrPut(gpa, @intFromPtr(vec))).found_existing) continue;
            try stack.appendSlice(gpa, vec.items);
        } else if (cur.asPair()) |p| {
            if ((try visited.getOrPut(gpa, @intFromPtr(p))).found_existing) continue;
            try stack.append(gpa, p.car);
            try stack.append(gpa, p.cdr);
        }
    }
    return true;
}

/// Reads `src` the way the interpreter does: datum after datum, up to the end or
/// the first error, with `gpa` behind everything the reader allocates.
///
/// 読めたデータは `printer` に通す。`next` が返してよいエラーは `Error` の中だけで、
/// 型が保証する。下の `switch` は `else` を持たないので、`Error` に足したエラーは、
/// ここで扱いを決めるまでコンパイルが通らない。
///
/// 検出力のある性質は、パニックと確保の漏れが無いこと、データを返した `next` が入力を
/// 進めること(進まなければ、読み取りの繰り返しが終わらない)、入力に関わらず
/// 読めた文字列が妥当な UTF-8 であることである。終端を返したときに入力を読み切って
/// いることは、`next` の構造から自明で、検出力はほとんどない。エラーのときの `pos` は、
/// 文字や文字列のリテラルが元の位置に戻すので、何も言わない。
fn fuzzReadAll(gpa: std.mem.Allocator, src: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var heap: Heap = .init(gpa, .{});
    defer heap.deinit();
    const sink: Sink = .{ .heap = &heap };
    var r: Reader = .init(src);
    // 畳み込む読み手の経路も通すため、入力の長さの偶奇で切り替える。
    r.fold_case = src.len % 2 == 1;
    while (true) {
        const before = r.pos;
        const datum = r.next(arena.allocator(), sink) catch |err| switch (err) {
            // どのエラーでも読み取りはそこで終わる。`OutOfMemory` はこちらが起こした
            // 確保の失敗で、`HeapLimit` は上限に届いたときである(この入力の大きさでは届かない)。
            error.OutOfMemory,
            error.HeapLimit,
            error.Incomplete,
            error.UnexpectedCloseParen,
            error.MissingDatum,
            error.MissingCommentedDatum,
            error.UnexpectedDot,
            error.InvalidToken,
            error.InvalidEscape,
            error.InvalidSymbolEscape,
            error.InvalidCharacter,
            error.InvalidUtf8,
            error.IntegerOutOfRange,
            error.InvalidByte,
            error.UndefinedLabel,
            error.DuplicateLabel,
            error.MissingLabeledDatum,
            error.CircularCode,
            => return,
        } orelse {
            try std.testing.expectEqual(src.len, r.pos);
            return;
        };
        try std.testing.expect(r.pos > before);
        // リーダは、入力に関わらず不正な文字列を作らない(不正なバイトを含む文字列リテラルは
        // `InvalidUtf8` になる。src/string_syntax.zig)。`createString` の assert は
        // ReleaseFast では消えるので、その最適化でもこの性質を見る。
        try std.testing.expect(stringsAreUtf8(gpa, datum) catch return);
        // Why: `write` は循環にだけラベルを付け(スライス 5j)、循環でない共有はたどるたびに
        // 書くので、データラベルのあるデータの書き出しは、入力より桁違いに長くなりうる。
        // 書き出す先を入力の大きさに比例する長さで切り、ラベルが無ければ収まることを見る。
        // ラベルの無いデータでは、1バイトの入力が最も長く書かれるのは `'` の `(quote ` と `)` で、
        // 16 倍に収まる。
        var printed: [16 * fuzz_max_input + 64]u8 = undefined;
        var sunk: std.Io.Writer = .fixed(&printed);
        printer.print(&sunk, &heap, &heap.symbols, datum, .write) catch |err| switch (err) {
            error.OutOfMemory, error.HeapLimit => return,
            error.WriteFailed => if (std.mem.indexOfScalar(u8, src, '=') != null) return else return error.TestUnexpectedResult,
        };
        // 名前が空のシンボルも `||` と書くので、書き出しは空でない。
        try std.testing.expect(sunk.end > 0);
    }
}

/// What one fuzz run reads from the `Smith`.
const FuzzInput = struct {
    src: []const u8,
    /// The allocation that fails in the second reading (see `fuzzReader`).
    fail_index: u16,
};

/// Reads the input of one fuzz run from `smith`, into `buf`.
/// `Smith` の読み方はここ 1 か所にある。`fuzzReader` と、初期入力が届くことを確かめる
/// テストの両方が、この関数を通る。
fn fuzzInput(smith: *std.testing.Smith, buf: *[fuzz_max_input]u8) FuzzInput {
    const src = buf[0..smith.slice(buf)];
    return .{ .src = src, .fail_index = smith.valueRangeAtMost(u16, 0, 512) };
}

/// Where `fuzzReader` writes down what it was given, for the test that checks
/// the corpus. The test passes null when it runs under `--fuzz`.
const FuzzRecord = struct {
    /// テストランナーが、初期入力のあとに空の入力を 1 回走らせる。その分を含めて持つ。
    const capacity = fuzz_inputs.len + 2;

    srcs: [capacity][fuzz_max_input]u8 = undefined,
    lens: [capacity]usize = @splat(0),
    fail_indexes: [capacity]u16 = @splat(0),
    /// How many runs there were, also those past `capacity`.
    count: usize = 0,

    fn add(self: *FuzzRecord, input: FuzzInput) void {
        if (self.count < capacity) {
            @memcpy(self.srcs[self.count][0..input.src.len], input.src);
            self.lens[self.count] = input.src.len;
            self.fail_indexes[self.count] = input.fail_index;
        }
        self.count += 1;
    }
};

/// One fuzz run: the reader on one input, then on the same input with an
/// allocation that fails.
fn fuzzReader(record: ?*FuzzRecord, smith: *std.testing.Smith) anyerror!void {
    var buf: [fuzz_max_input]u8 = undefined;
    const input = fuzzInput(smith, &buf);
    if (record) |r| r.add(input);
    const src = input.src;
    // Why: 入力全体の UTF-8 の検査は、リーダの呼び出し側が行う
    // (src/sucheme.zig の `run` と src/wasm.zig の `sucheme_eval_begin`)。ここでは
    // その検査を通さず、任意のバイト列を渡す。検査が外れても、リーダがパニックや
    // 不正なメモリアクセスを起こさないことを見る(多層防御)。文字列リテラルの
    // バイトは、リーダ自身も `InvalidUtf8` で拒否する(src/string_syntax.zig)。それ以外の
    // 不正なバイトを読んだ結果が正しいかは、確かめない。
    try fuzzReadAll(std.testing.allocator, src);
    // 確保が n 回目に失敗する場合。リークは `std.testing.allocator` が見る。
    var failing: std.testing.FailingAllocator = .init(std.testing.allocator, .{
        .fail_index = input.fail_index,
    });
    try fuzzReadAll(failing.allocator(), src);
}

/// Runs the fuzz test on `fuzz_corpus`.
/// 通常の `zig build test` では初期入力だけを通る。`--fuzz=<N>` のときは、そこから
/// 探索を広げる。
fn runFuzz(record: ?*FuzzRecord) anyerror!void {
    try std.testing.fuzz(record, fuzzReader, .{ .corpus = fuzz_corpus });
}

test "fuzz: the reader returns a datum, the end or a specified error for any input" {
    // 探索の実行では、ファザーが入力を決めるので、届いた入力は確かめられない。
    // Why: 確かめるテストを別にすると、`std.testing.fuzz` を呼ぶテストが 2 つになり、
    // 探索の実行で片方が飛ばされて、ファザーがそのテストを回し続けて進まなくなる
    // (飛ばしたテストも、通常の実行では `std.testing.fuzz` を呼ぶので、ファジングの
    // テストに数えられる)。そのため 1 つのテストにまとめた。
    if (@import("builtin").fuzz) return runFuzz(null);
    // 初期入力が意図どおりに届かなければ、このテストは何も固定しないまま緑になる。
    // 実際に `std.testing.fuzz` を `fuzz_corpus` で呼び、`fuzzReader` が受け取った入力を
    // 書き留めて、`fuzz_inputs` と比べる。
    var record: FuzzRecord = .{};
    try runFuzz(&record);
    // `fuzz_inputs` の全件が順に届き、最後にテストランナーの空の入力が 1 回付く。
    try std.testing.expectEqual(fuzz_inputs.len + 1, record.count);
    for (fuzz_inputs, 0..) |text, i| {
        try std.testing.expectEqualSlices(u8, text, record.srcs[i][0..record.lens[i]]);
        // 初期入力の実行では、確保の失敗の番号は 0 である。
        try std.testing.expectEqual(0, record.fail_indexes[i]);
    }
    try std.testing.expectEqual(0, record.lens[fuzz_inputs.len]);
}

test "fuzz: the reader leaks nothing wherever an allocation fails" {
    // 初期入力を使う実行では、確保の失敗の番号が 0 になる。当たるのはアリーナの最初の
    // 確保だけで、ヒープのセル、文字列、ベクタ、プリンタのスタックの確保の失敗は
    // 当たらない。それを担うのはこのテストで、固定の入力に対し、n 回目の確保の失敗を、
    // 失敗が起きなくなるまで 1 つずつ試す。ヒープの上限は既定で 256 MiB で、この入力では
    // 届かないので、`HeapLimit` は試さない。
    const src = "(a #(1 \"s\") 'b . c) foo \"str\" (1 2 3) #\\x";
    var n: usize = 0;
    while (true) : (n += 1) {
        var failing: std.testing.FailingAllocator = .init(std.testing.allocator, .{ .fail_index = n });
        try fuzzReadAll(failing.allocator(), src);
        if (!failing.has_induced_failure) break;
    }
    // 入力が確保をしなければ、何も試していない。
    try std.testing.expect(n > 0);
}

test "the corpus has inputs that the reader reads with case folded, and that fold something" {
    var folded: usize = 0;
    for (fuzz_inputs) |text| {
        if (text.len % 2 == 0) continue;
        for (text) |byte| {
            if (std.ascii.isUpper(byte)) {
                folded += 1;
                break;
            }
        }
    }
    try std.testing.expect(folded >= 2);
}
