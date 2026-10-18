//! String primitives (R7RS 6.7), and the two that carry strings to and from vectors
//! (`string->vector` and `vector->string`, R7RS 6.8).
//!
//! 文字列は UTF-8 のバイト列で、全部が ASCII かどうかのフラグを持つ(ADR-0008)。
//! 長さと位置は文字(Unicode スカラ値)で数える。バイトでは数えない。数え方は
//! `value.String` にあり、ここは型と範囲を検査して呼ぶだけである。
//!
//! 変更する手続き(`string-set!` `string-fill!` `string-copy!`)は、型を検査したあと、範囲を
//! 検査する前に、引数が定数でないことを検査する(`immutable.requireMutable`)。文字の幅が
//! 変わる書き込みは、新しいバイト列に作り直して差し替える(`replaceSpan`)。幅が変わらなければ、
//! その場で書く。
//!
//! 入力の大きさに比例して確保するもの(`make-string` `string-append` `list->string`
//! `string->vector` など)は、確保する領域を先に上限に照らして検査し、領域へ直接書く。
//! 一時の領域に作ってから写すと、その領域は上限の外にある。GC は機械のステップの境目でしか
//! 走らない(ADR-0031)ので、1回の呼び出しの確保は、その間に回収されない。確保する量が
//! 入力に比例するこの性質は、`list` や `vector` の個数に比例する確保と同じである。
//!
//! 大文字小文字を畳み込む手続き(`string-ci=?` `string-upcase` など)は、Unicode の表が入る
//! 段階4で足す。

const std = @import("std");
const value = @import("../value.zig");
const Value = value.Value;
const Primitive = value.Primitive;
const Services = value.Services;
const PrimitiveError = value.PrimitiveError;
const String = value.String;
const Heap = @import("../heap.zig").Heap;
const immutable = @import("immutable.zig");
const pair = @import("pair.zig");
const range_mod = @import("range.zig");
const RangeOperands = range_mod.RangeOperands;
const resolveRange = range_mod.resolveRange;

pub const Error = PrimitiveError;

pub const primitives = [_]Primitive{
    .{ .name = "string?", .min_args = 1, .max_args = 1, .body = .{ .pure = &isString } },
    .{ .name = "make-string", .min_args = 1, .max_args = 2, .body = .{ .pure = &makeString } },
    .{ .name = "string", .min_args = 0, .max_args = null, .body = .{ .pure = &stringOfChars } },
    .{ .name = "string-length", .min_args = 1, .max_args = 1, .body = .{ .pure = &stringLength } },
    .{ .name = "string-ref", .min_args = 2, .max_args = 2, .body = .{ .pure = &stringRef } },
    .{ .name = "string-set!", .min_args = 3, .max_args = 3, .body = .{ .pure = &stringSet } },
    .{ .name = "string=?", .min_args = 1, .max_args = null, .body = .{ .pure = comparison(.eq) } },
    .{ .name = "string<?", .min_args = 1, .max_args = null, .body = .{ .pure = comparison(.lt) } },
    .{ .name = "string>?", .min_args = 1, .max_args = null, .body = .{ .pure = comparison(.gt) } },
    .{ .name = "string<=?", .min_args = 1, .max_args = null, .body = .{ .pure = comparison(.lte) } },
    .{ .name = "string>=?", .min_args = 1, .max_args = null, .body = .{ .pure = comparison(.gte) } },
    .{ .name = "substring", .min_args = 3, .max_args = 3, .body = .{ .pure = &stringCopy } },
    .{ .name = "string-append", .min_args = 0, .max_args = null, .body = .{ .pure = &stringAppend } },
    .{ .name = "string->list", .min_args = 1, .max_args = 3, .body = .{ .pure = &stringToList } },
    .{ .name = "list->string", .min_args = 1, .max_args = 1, .body = .{ .pure = &listToString } },
    .{ .name = "string-copy", .min_args = 1, .max_args = 3, .body = .{ .pure = &stringCopy } },
    .{ .name = "string-copy!", .min_args = 3, .max_args = 5, .body = .{ .pure = &stringCopyInto } },
    .{ .name = "string-fill!", .min_args = 2, .max_args = 4, .body = .{ .pure = &stringFill } },
    .{ .name = "string->vector", .min_args = 1, .max_args = 3, .body = .{ .pure = &stringToVector } },
    .{ .name = "vector->string", .min_args = 1, .max_args = 3, .body = .{ .pure = &vectorToString } },
};

/// `(string? obj)`.
fn isString(_: *const Services, args: []const Value) Error!Value {
    return .fromBool(args[0].asString() != null);
}

/// `(string-length string)`: the number of characters (R7RS 6.7).
///
/// 長さは文字の数で、バイトの数ではない。`"あいう"` は 3 である。
fn stringLength(_: *const Services, args: []const Value) Error!Value {
    const s = args[0].asString() orelse return error.WrongType;
    // 文字の数は、バイトの数を超えず、バイトの数は確保できた大きさなので、i64 に収まる。
    return .fromFixnum(@intCast(s.length()));
}

/// `(string-ref string k)`: the `k`th character, counted from 0 (R7RS 6.7).
///
/// Why: R7RS 6.7 は、`k` が妥当な添字でなければ誤りとしている。`k` は文字の位置で
/// ある。添字の検査は、型の検査のあとに行う。引数は 64 ビットの整数なので、`usize` に
/// 変えられるかを先に調べる。`wasm32` で `@intCast` すると、大きな値の検査で
/// パニックするか、切り捨てて範囲内に戻ってしまう。
fn stringRef(_: *const Services, args: []const Value) Error!Value {
    const s = args[0].asString() orelse return error.WrongType;
    const k = args[1].asFixnum() orelse return error.WrongType;
    const index = std.math.cast(usize, k) orelse return error.OutOfRange;
    return .fromCharacter(s.charAt(index) orelse return error.OutOfRange);
}

/// The UTF-8 bytes of one character.
const Encoded = struct {
    buffer: [4]u8,
    len: usize,

    fn of(c: u21) Encoded {
        var e: Encoded = .{ .buffer = undefined, .len = 0 };
        // 文字はスカラ値なので、符号化は失敗しない。
        e.len = std.unicode.utf8Encode(c, &e.buffer) catch unreachable;
        return e;
    }

    fn slice(self: *const Encoded) []const u8 {
        return self.buffer[0..self.len];
    }
};

/// The width of the character `c` in UTF-8.
fn widthOf(c: u21) usize {
    return std.unicode.utf8CodepointSequenceLength(c) catch unreachable;
}

/// What a run of bytes in a string is replaced with, or a new string is filled with: given
/// bytes, or one character's bytes over and over.
/// 新しい文字列を作る確保(`Heap.createStringFilled`)の `filler` でもある。
const Splice = union(enum) {
    bytes: []const u8,
    repeat: struct { unit: []const u8, count: usize },

    /// The number of bytes. `repeat` の `count` と `unit` の積が桁あふれしないことは、
    /// 作る側が検査する。
    fn len(self: Splice) usize {
        return switch (self) {
            .bytes => |b| b.len,
            .repeat => |r| r.unit.len * r.count,
        };
    }

    /// Writes the bytes to `dest`, which is `len` long.
    /// `bytes` が書き込み先と重なっていてもよい(`@memmove`)。
    pub fn fill(self: Splice, dest: []u8) void {
        switch (self) {
            .bytes => |b| @memmove(dest, b),
            .repeat => |r| {
                if (r.unit.len == 1) {
                    @memset(dest, r.unit[0]);
                    return;
                }
                var i: usize = 0;
                while (i < dest.len) : (i += r.unit.len) @memcpy(dest[i..][0..r.unit.len], r.unit);
            },
        }
    }
};

/// Replaces the bytes `from` up to `to` of `s` with `with`.
///
/// 置き換えるバイトの数が同じなら、その場で書く。これは、重なる範囲の `string-copy!` の
/// 向きの扱いも含む(`@memmove` が、一時の領域に写したように振る舞う)。ASCII を ASCII へ置く
/// 書き込みと、同じ幅の非 ASCII を置く書き込みは、必ずこの場合である。数が違えば(幅の違う
/// 文字に変わる、または範囲の幅が変わる)、新しいバイト列を先に確保し、前の部分と置き換える
/// バイトと後ろの部分を書いてから、差し替える。確保の失敗は、書き始める前に起きるので、文字列は
/// 元のままである。`with` が `s` のバイト列を指していても、差し替えるまで古いバイト列は
/// 生きているので、書ける。
fn replaceSpan(heap: *Heap, s: *String, from: usize, to: usize, with: Splice) Error!void {
    const old_len = to - from;
    const new_len = with.len();
    if (new_len == old_len) {
        with.fill(s.bytes[from..to]);
        return;
    }
    const total = std.math.add(usize, s.bytes.len - old_len, new_len) catch return error.HeapLimit;
    const buffer = try heap.stringBytesFor(s, total);
    @memcpy(buffer[0..from], s.bytes[0..from]);
    with.fill(buffer[from..][0..new_len]);
    @memcpy(buffer[from + new_len ..], s.bytes[to..]);
    heap.replaceStringBytes(s, buffer);
}

/// `(make-string k)` and `(make-string k char)`: a new string of `k` characters, all `char`
/// (R7RS 6.7).
///
/// R7RS 6.7 は、`char` がなければ中身を未規定としている。ここでは空白で埋める。大きさは、
/// 一時の領域を経ずに直接確保し、上限に収まらなければ `HeapLimit` である。`usize` に収まらない
/// 大きさは、範囲の誤りでなく、上限超過として扱う(確保できないという意味で同じである)。
fn makeString(services: *const Services, args: []const Value) Error!Value {
    const k = args[0].asFixnum() orelse return error.WrongType;
    const fill: u21 = if (args.len > 1) args[1].asCharacter() orelse return error.WrongType else ' ';
    if (k < 0) return error.OutOfRange;
    const count = std.math.cast(usize, k) orelse return error.HeapLimit;
    const encoded: Encoded = .of(fill);
    const len = std.math.mul(usize, count, encoded.len) catch return error.HeapLimit;
    return .fromString(try services.heap.createStringFilled(len, Splice{ .repeat = .{ .unit = encoded.slice(), .count = count } }));
}

/// Writes the characters of `chars`, which are all characters, as UTF-8.
const CharsFiller = struct {
    chars: []const Value,

    pub fn fill(self: CharsFiller, bytes: []u8) void {
        var i: usize = 0;
        for (self.chars) |c| i += std.unicode.utf8Encode(c.asCharacter().?, bytes[i..]) catch unreachable;
    }
};

/// The bytes the characters of `chars`, which must all be characters, take.
fn charsWidth(chars: []const Value) Error!usize {
    var total: usize = 0;
    for (chars) |c| {
        const scalar = c.asCharacter() orelse return error.WrongType;
        total = std.math.add(usize, total, widthOf(scalar)) catch return error.HeapLimit;
    }
    return total;
}

/// `(string char ...)`: a new string of the characters (R7RS 6.7).
fn stringOfChars(services: *const Services, args: []const Value) Error!Value {
    const len = try charsWidth(args);
    return .fromString(try services.heap.createStringFilled(len, CharsFiller{ .chars = args }));
}

/// `(string-set! string k char)`: replaces the `k`th character with `char` (R7RS 6.7).
///
/// 定数の文字列は書き換えない(R7RS 3.4。`(string-set! (symbol->string 'a) 0 #\?)` は誤りで
/// ある)。置き換える文字の幅が、置き換えられる文字と同じなら、その場で書く。違えば、バイト列を
/// 作り直し、ASCII の印を計算し直す(ADR-0008)。ASCII の文字列に ASCII の文字を書く、
/// ふつうの場合は、定数時間である。
fn stringSet(services: *const Services, args: []const Value) Error!Value {
    const s = args[0].asString() orelse return error.WrongType;
    const k = args[1].asFixnum() orelse return error.WrongType;
    const c = args[2].asCharacter() orelse return error.WrongType;
    try immutable.requireMutable(args[0]);
    const index = std.math.cast(usize, k) orelse return error.OutOfRange;
    if (index >= s.length()) return error.OutOfRange;
    const span = s.byteSpan(index, index + 1);
    const encoded: Encoded = .of(c);
    try replaceSpan(services.heap, s, span.from, span.to, .{ .bytes = encoded.slice() });
    return .unspecified_value;
}

/// `(string=? string1 string2 string3 ...)` and the other four comparisons (R7RS 6.7):
/// whether every neighboring pair of the arguments is in the order.
///
/// 順序は、文字の列の辞書式順序である(R7RS 6.7 が、`char<?` の誘導する辞書式順序を、例として
/// 挙げている)。短い文字列は、同じ接頭辞を持つ長い文字列より小さい。UTF-8 のバイト列の
/// バイトごとの順序は、コードポイントの順序と一致するので、バイト列を比べればよい。引数が1つなら
/// 真、なしならエラー(機械が表の下限で報告する)。最初に成り立たなかった組より後のものも含め、
/// すべての引数が文字列であることを検査する。エラーが値に左右されないようにするためで、
/// `char=?` と同じである。
fn comparison(comptime op: std.math.CompareOperator) Primitive.Fn {
    return &struct {
        fn call(_: *const Services, args: []const Value) Error!Value {
            for (args) |a| _ = a.asString() orelse return error.WrongType;
            var holds = true;
            for (args[0 .. args.len - 1], args[1..]) |a, b| {
                const order = std.mem.order(u8, a.asString().?.bytes, b.asString().?.bytes);
                if (!order.compare(op)) holds = false;
            }
            return .fromBool(holds);
        }
    }.call;
}

/// `(string-copy string)`, `(string-copy string start)` and `(string-copy string start end)`:
/// a new string of the characters from `start` up to `end` (R7RS 6.7). `substring` is the same
/// with all three arguments (the arity of the table makes them required).
///
/// 結果は新しい文字列で、定数ではない。元の文字列が定数でも、写しは書き換えられる
/// (R7RS 6.8 の `vector-copy` の例が、そう書いている)。
fn stringCopy(services: *const Services, args: []const Value) Error!Value {
    const s = args[0].asString() orelse return error.WrongType;
    const operands = try RangeOperands.of(args, 1);
    const range = try resolveRange(operands, s.length());
    const span = s.byteSpan(range.start, range.end);
    return .fromString(try services.heap.createString(s.bytes[span.from..span.to]));
}

/// Writes the bytes of the strings in `parts`.
const AppendFiller = struct {
    parts: []const Value,

    pub fn fill(self: AppendFiller, bytes: []u8) void {
        var i: usize = 0;
        for (self.parts) |part| {
            const b = part.asString().?.bytes;
            @memcpy(bytes[i..][0..b.len], b);
            i += b.len;
        }
    }
};

/// `(string-append string ...)`: a new string of the characters of the strings, in order
/// (R7RS 6.7). The result is a new string even for one argument.
fn stringAppend(services: *const Services, args: []const Value) Error!Value {
    var total: usize = 0;
    for (args) |a| {
        const s = a.asString() orelse return error.WrongType;
        total = std.math.add(usize, total, s.bytes.len) catch return error.HeapLimit;
    }
    return .fromString(try services.heap.createStringFilled(total, AppendFiller{ .parts = args }));
}

/// `(string->list string)`, `(string->list string start)` and
/// `(string->list string start end)`: a new list of the characters from `start` up to `end`
/// (R7RS 6.7).
///
/// 文字の数だけペアを作る。1回の呼び出しの中で個数に比例して確保し、その間に GC は走らない
/// (ADR-0031)。確保が失敗したときの途中のペアはゴミで、次の境目で回収される。
fn stringToList(services: *const Services, args: []const Value) Error!Value {
    const s = args[0].asString() orelse return error.WrongType;
    const operands = try RangeOperands.of(args, 1);
    const range = try resolveRange(operands, s.length());
    const span = s.byteSpan(range.start, range.end);
    var head: Value = .empty_list_value;
    var tail: ?*value.Pair = null;
    var it = std.unicode.Utf8View.initUnchecked(s.bytes[span.from..span.to]).iterator();
    while (it.nextCodepoint()) |c| {
        const cell = try services.heap.cons(.fromCharacter(c), .empty_list_value);
        if (tail) |t| t.cdr = cell else head = cell;
        tail = cell.asPair();
    }
    return head;
}

/// The characters of the list `list`, which is a list of characters, as UTF-8.
const ListFiller = struct {
    list: Value,

    pub fn fill(self: ListFiller, bytes: []u8) void {
        var i: usize = 0;
        var rest = self.list;
        while (rest.asPair()) |p| : (rest = p.cdr) i += std.unicode.utf8Encode(p.car.asCharacter().?, bytes[i..]) catch unreachable;
    }
};

/// `(list->string list)`: a new string of the characters in the list (R7RS 6.7).
///
/// 先にリストを検査する。リストでないもの(末尾が空リストでない鎖と、輪になった鎖)と、
/// 文字でない要素は、型の誤りである。輪は `properLength` が止める。
fn listToString(services: *const Services, args: []const Value) Error!Value {
    _ = pair.properLength(args[0]) orelse return error.WrongType;
    var total: usize = 0;
    var rest = args[0];
    while (rest.asPair()) |p| : (rest = p.cdr) {
        const c = p.car.asCharacter() orelse return error.WrongType;
        total = std.math.add(usize, total, widthOf(c)) catch return error.HeapLimit;
    }
    return .fromString(try services.heap.createStringFilled(total, ListFiller{ .list = args[0] }));
}

/// `(string-copy! to at from)`, `(string-copy! to at from start)` and
/// `(string-copy! to at from start end)`: copies the characters of `from` from `start` up
/// to `end` into `to`, from position `at` (R7RS 6.7).
///
/// R7RS 6.7 は、`at` が0未満か `to` の長さより大きいとき、`to` の残りが `end - start` に
/// 足りないときを誤りとし、重なる場合は、一時の文字列に写してから書いたように振る舞うことを
/// 求めている。`to` が定数なら断る。範囲が空でも断る(`immutable.requireMutable`)。
fn stringCopyInto(services: *const Services, args: []const Value) Error!Value {
    const to = args[0].asString() orelse return error.WrongType;
    const at_n = args[1].asFixnum() orelse return error.WrongType;
    const from = args[2].asString() orelse return error.WrongType;
    const operands = try RangeOperands.of(args, 3);
    try immutable.requireMutable(args[0]);
    const plan = try range_mod.resolveCopy(at_n, to.length(), operands, from.length());
    const at = plan.at;
    const range = plan.range;
    const count = range.end - range.start;
    const source = from.byteSpan(range.start, range.end);
    const target = to.byteSpan(at, at + count);
    try replaceSpan(services.heap, to, target.from, target.to, .{ .bytes = from.bytes[source.from..source.to] });
    return .unspecified_value;
}

/// `(string-fill! string fill)`, `(string-fill! string fill start)` and
/// `(string-fill! string fill start end)`: stores `fill` in the characters from `start` up
/// to `end` (R7RS 6.7).
fn stringFill(services: *const Services, args: []const Value) Error!Value {
    const s = args[0].asString() orelse return error.WrongType;
    const fill = args[1].asCharacter() orelse return error.WrongType;
    const operands = try RangeOperands.of(args, 2);
    try immutable.requireMutable(args[0]);
    const range = try resolveRange(operands, s.length());
    const span = s.byteSpan(range.start, range.end);
    const encoded: Encoded = .of(fill);
    _ = std.math.mul(usize, range.end - range.start, encoded.len) catch return error.HeapLimit;
    try replaceSpan(services.heap, s, span.from, span.to, .{ .repeat = .{ .unit = encoded.slice(), .count = range.end - range.start } });
    return .unspecified_value;
}

/// Writes the characters of the UTF-8 bytes `bytes` as elements.
const VectorFiller = struct {
    bytes: []const u8,

    pub fn fill(self: VectorFiller, items: []Value) void {
        var it = std.unicode.Utf8View.initUnchecked(self.bytes).iterator();
        for (items) |*slot| slot.* = .fromCharacter(it.nextCodepoint().?);
    }
};

/// `(string->vector string)`, `(string->vector string start)` and
/// `(string->vector string start end)`: a new vector of the characters from `start` up to
/// `end` (R7RS 6.8).
fn stringToVector(services: *const Services, args: []const Value) Error!Value {
    const s = args[0].asString() orelse return error.WrongType;
    const operands = try RangeOperands.of(args, 1);
    const range = try resolveRange(operands, s.length());
    const span = s.byteSpan(range.start, range.end);
    return .fromVector(try services.heap.createVectorFilled(range.end - range.start, VectorFiller{ .bytes = s.bytes[span.from..span.to] }));
}

/// `(vector->string vector)`, `(vector->string vector start)` and
/// `(vector->string vector start end)`: a new string of the elements from `start` up to
/// `end`, which must be characters (R7RS 6.8).
fn vectorToString(services: *const Services, args: []const Value) Error!Value {
    const v = args[0].asVector() orelse return error.WrongType;
    const operands = try RangeOperands.of(args, 1);
    const range = try resolveRange(operands, v.items.len);
    const chars = v.items[range.start..range.end];
    const len = try charsWidth(chars);
    return .fromString(try services.heap.createStringFilled(len, CharsFiller{ .chars = chars }));
}

test {
    std.testing.refAllDecls(@This());
}

const test_support = @import("test_support.zig");
const string_syntax = @import("../string_syntax.zig");

/// A heap, and the `Services` over it, with the string `text` made in it.
const Probe = struct {
    fixture: test_support.Fixture,
    string: Value,

    fn init(self: *Probe, text: []const u8) !void {
        self.fixture.init();
        self.string = .fromString(try self.fixture.heap.createString(text));
    }

    fn deinit(self: *Probe) void {
        self.fixture.deinit();
    }

    fn call(self: *Probe, name: []const u8, args: []const Value) Error!Value {
        return self.fixture.call(&primitives, name, args);
    }

    /// `(string-length s)`.
    fn length(self: *Probe) !i64 {
        return (try self.call("string-length", &.{self.string})).asFixnum().?;
    }

    /// `(string-ref s k)`.
    fn ref(self: *Probe, k: i64) Error!Value {
        return self.call("string-ref", &.{ self.string, .fromFixnum(k) });
    }
};

test "the primitives take the numbers of arguments the language gives them" {
    const Arity = struct { name: []const u8, min: u8, max: ?u8 };
    const expected = [_]Arity{
        .{ .name = "string?", .min = 1, .max = 1 },
        .{ .name = "make-string", .min = 1, .max = 2 },
        .{ .name = "string", .min = 0, .max = null },
        .{ .name = "string-length", .min = 1, .max = 1 },
        .{ .name = "string-ref", .min = 2, .max = 2 },
        .{ .name = "string-set!", .min = 3, .max = 3 },
        .{ .name = "string=?", .min = 1, .max = null },
        .{ .name = "string<?", .min = 1, .max = null },
        .{ .name = "string>?", .min = 1, .max = null },
        .{ .name = "string<=?", .min = 1, .max = null },
        .{ .name = "string>=?", .min = 1, .max = null },
        .{ .name = "substring", .min = 3, .max = 3 },
        .{ .name = "string-append", .min = 0, .max = null },
        .{ .name = "string->list", .min = 1, .max = 3 },
        .{ .name = "list->string", .min = 1, .max = 1 },
        .{ .name = "string-copy", .min = 1, .max = 3 },
        .{ .name = "string-copy!", .min = 3, .max = 5 },
        .{ .name = "string-fill!", .min = 2, .max = 4 },
        .{ .name = "string->vector", .min = 1, .max = 3 },
        .{ .name = "vector->string", .min = 1, .max = 3 },
    };
    try std.testing.expectEqual(expected.len, primitives.len);
    for (expected, primitives) |e, p| {
        try std.testing.expectEqualStrings(e.name, p.name);
        try std.testing.expectEqual(e.min, p.min_args);
        try std.testing.expectEqual(e.max, p.max_args);
    }
}

test "string? is true of a string, the empty one included, and of nothing else" {
    var p: Probe = undefined;
    try p.init("");
    defer p.deinit();
    try std.testing.expect((try p.call("string?", &.{p.string})).isTrue());
    const other = [_]Value{ .fromCharacter('a'), .fromFixnum(1), .empty_list_value, .fromBool(true), .unspecified_value };
    for (other) |v| {
        const r = try p.call("string?", &.{v});
        try std.testing.expectEqual(value.Kind.boolean, r.kind());
        try std.testing.expect(!r.isTrue());
    }
    const vector: Value = .fromVector(try p.fixture.heap.createVector(&.{}));
    try std.testing.expect(!(try p.call("string?", &.{vector})).isTrue());
}

test "string-length counts characters, not bytes" {
    const Case = struct { text: []const u8, length: i64 };
    const cases = [_]Case{
        .{ .text = "", .length = 0 },
        .{ .text = "a", .length = 1 },
        .{ .text = "hello", .length = 5 },
        .{ .text = "あ", .length = 1 },
        .{ .text = "あいう", .length = 3 },
        .{ .text = "aあb", .length = 3 },
        .{ .text = "aλあ𐀀z", .length = 5 },
        .{ .text = "𐀀𐀀𐀀", .length = 3 },
        .{ .text = "\u{80}", .length = 1 },
        .{ .text = "\x00\x7f", .length = 2 },
    };
    for (cases) |c| {
        var p: Probe = undefined;
        try p.init(c.text);
        defer p.deinit();
        try std.testing.expectEqual(c.length, try p.length());
    }
}

test "string-length does not take a string for the flag it carries" {
    // フラグが立っていても立っていなくても、答えは同じ文字の数である。ASCII の文字列で
    // フラグを下ろして走査の経路を通し、立てた経路と一致することを確かめる。
    var p: Probe = undefined;
    try p.init("hello");
    defer p.deinit();
    try std.testing.expect(p.string.asString().?.is_ascii);
    try std.testing.expectEqual(5, try p.length());
    p.string.asString().?.is_ascii = false;
    try std.testing.expectEqual(5, try p.length());
}

test "string-ref gives the character at a position counted in characters" {
    var p: Probe = undefined;
    try p.init("aλあ𐀀z");
    defer p.deinit();
    const expected = [_]u21{ 'a', 0x3BB, 0x3042, 0x10000, 'z' };
    for (expected, 0..) |c, i| {
        const r = try p.ref(@intCast(i));
        try std.testing.expectEqual(value.Kind.character, r.kind());
        try std.testing.expectEqual(c, r.asCharacter().?);
    }
}

test "string-ref of an ASCII string is the byte at that position" {
    var p: Probe = undefined;
    try p.init("abc");
    defer p.deinit();
    try std.testing.expect(p.string.asString().?.is_ascii);
    try std.testing.expectEqual('a', (try p.ref(0)).asCharacter().?);
    try std.testing.expectEqual('c', (try p.ref(2)).asCharacter().?);
}

test "string-ref refuses a position outside the string" {
    const texts = [_][]const u8{ "", "abc", "あいう", "aあb", "𐀀" };
    for (texts) |text| {
        var p: Probe = undefined;
        try p.init(text);
        defer p.deinit();
        const n = try p.length();
        // 長さちょうどと、その先。バイトの数に届かない位置も範囲外である。
        try std.testing.expectError(error.OutOfRange, p.ref(n));
        try std.testing.expectError(error.OutOfRange, p.ref(n + 1));
        try std.testing.expectError(error.OutOfRange, p.ref(100));
        try std.testing.expectError(error.OutOfRange, p.ref(-1));
        try std.testing.expectError(error.OutOfRange, p.ref(std.math.minInt(i64)));
        try std.testing.expectError(error.OutOfRange, p.ref(std.math.maxInt(i64)));
        // `usize` が 32 ビットでも、切り捨てて範囲内に戻らない値。
        try std.testing.expectError(error.OutOfRange, p.ref(1 << 32));
        try std.testing.expectError(error.OutOfRange, p.ref((1 << 32) + 1));
        // 最後の文字までは読める。
        if (n > 0) _ = try p.ref(n - 1);
    }
}

test "string-ref and string-length report an argument of the wrong type, before the range" {
    var p: Probe = undefined;
    try p.init("abc");
    defer p.deinit();
    try std.testing.expectError(error.WrongType, p.call("string-length", &.{.fromFixnum(1)}));
    try std.testing.expectError(error.WrongType, p.call("string-length", &.{.fromCharacter('a')}));
    try std.testing.expectError(error.WrongType, p.call("string-length", &.{.empty_list_value}));
    // 文字列でない最初の引数は、添字が範囲外でも型のエラーになる。
    try std.testing.expectError(error.WrongType, p.call("string-ref", &.{ .fromFixnum(1), .fromFixnum(0) }));
    try std.testing.expectError(error.WrongType, p.call("string-ref", &.{ .fromFixnum(1), .fromFixnum(100) }));
    try std.testing.expectError(error.WrongType, p.call("string-ref", &.{ .fromFixnum(1), .fromFixnum(-1) }));
    // 整数でない添字。
    try std.testing.expectError(error.WrongType, p.call("string-ref", &.{ p.string, .fromCharacter('a') }));
    try std.testing.expectError(error.WrongType, p.call("string-ref", &.{ p.string, p.string }));
    try std.testing.expectError(error.WrongType, p.call("string-ref", &.{ p.string, .empty_list_value }));
}

test "a string the reader makes has the flag set by what it holds" {
    // リテラルとエスケープ。ソースは ASCII でも、エスケープが ASCII でない文字を作る。
    const Case = struct { source: []const u8, ascii: bool, length: i64 };
    const cases = [_]Case{
        .{ .source = "\"\"", .ascii = true, .length = 0 },
        .{ .source = "\"abc\"", .ascii = true, .length = 3 },
        .{ .source = "\"a\\tb\"", .ascii = true, .length = 3 },
        .{ .source = "\"\\x41;\"", .ascii = true, .length = 1 },
        .{ .source = "\"\\x7f;\"", .ascii = true, .length = 1 },
        .{ .source = "\"\\x80;\"", .ascii = false, .length = 1 },
        .{ .source = "\"\\x3bb;\"", .ascii = false, .length = 1 },
        .{ .source = "\"a\\x3bb;b\"", .ascii = false, .length = 3 },
        .{ .source = "\"あいう\"", .ascii = false, .length = 3 },
        .{ .source = "\"abc\\x10ffff;\"", .ascii = false, .length = 4 },
    };
    for (cases) |c| {
        var f: test_support.Fixture = undefined;
        f.init();
        defer f.deinit();
        var pos: usize = 0;
        const v = try string_syntax.read(c.source, &pos, std.testing.allocator, &f.heap);
        try std.testing.expectEqual(c.ascii, v.asString().?.is_ascii);
        const n = try f.call(&primitives, "string-length", &.{v});
        try std.testing.expectEqual(c.length, n.asFixnum().?);
    }
}

test "a collection keeps the flag and the characters of a string the roots reach" {
    var p: Probe = undefined;
    try p.init("あいう");
    defer p.deinit();
    const garbage = try p.fixture.heap.createString("garbage あ");
    _ = garbage;
    const Roots = struct {
        v: Value,
        pub fn mark(self: @This(), marker: *@import("../heap.zig").Marker) void {
            marker.value(self.v);
        }
    };
    p.fixture.heap.collect(Roots{ .v = p.string });
    try std.testing.expectEqual(1, p.fixture.heap.count);
    try std.testing.expectEqual(3, try p.length());
    try std.testing.expectEqual(0x3046, (try p.ref(2)).asCharacter().?);
    try std.testing.expect(!p.string.asString().?.is_ascii);
}

// ---- スライス 3d: 文字列を作る、変更する、比べる、変換する手続き ----

const heap_mod = @import("../heap.zig");

/// Roots that keep nothing: a collection with them frees every object.
const NoRoots = struct {
    pub fn mark(_: NoRoots, _: *heap_mod.Marker) void {}
};

/// Roots that keep the values: a collection with them frees every other object.
const KeepRoots = struct {
    values: []const Value,

    pub fn mark(self: KeepRoots, marker: *heap_mod.Marker) void {
        for (self.values) |v| marker.value(v);
    }
};

fn call(f: *test_support.Fixture, name: []const u8, args: []const Value) Error!Value {
    return f.call(&primitives, name, args);
}

fn str(f: *test_support.Fixture, content: []const u8) !Value {
    return .fromString(try f.heap.createString(content));
}

fn fix(n: i64) Value {
    return .fromFixnum(n);
}

fn chr(c: u21) Value {
    return .fromCharacter(c);
}

/// The bytes of the string `v`.
fn bytesOf(v: Value) []const u8 {
    return v.asString().?.bytes;
}

/// Calls `name` on the arguments and checks that the result is the string `expected`, with
/// the flag that its characters call for.
fn expectString(expected: []const u8, result: Value) !void {
    try std.testing.expectEqual(value.Kind.string, result.kind());
    try std.testing.expectEqualStrings(expected, bytesOf(result));
    try std.testing.expectEqual(value.allAscii(expected), result.asString().?.is_ascii);
}

/// The account of a string alone in a heap that is its cell and its bytes.
fn expectAccount(f: *const test_support.Fixture, strings: usize, bytes: usize) !void {
    try std.testing.expectEqual(strings * heap_mod.cellBytes(String) + bytes, f.heap.accounted);
}

test "make-string gives a string of k copies of the character, or of spaces" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    try expectString("", try call(&f, "make-string", &.{fix(0)}));
    try expectString("   ", try call(&f, "make-string", &.{fix(3)}));
    try expectString("***", try call(&f, "make-string", &.{ fix(3), chr('*') }));
    try expectString("", try call(&f, "make-string", &.{ fix(0), chr('*') }));
    // 幅の違う文字。長さは文字の数で、バイトの数ではない。
    const lambda = try call(&f, "make-string", &.{ fix(3), chr(0x3bb) });
    try expectString("λλλ", lambda);
    try std.testing.expectEqual(3, lambda.asString().?.length());
    try expectString("𐀀𐀀", try call(&f, "make-string", &.{ fix(2), chr(0x10000) }));
    // 呼ぶたびに新しい文字列で、定数ではない。
    const a = try call(&f, "make-string", &.{ fix(1), chr('a') });
    const b = try call(&f, "make-string", &.{ fix(1), chr('a') });
    try std.testing.expect(a.asString().? != b.asString().?);
    try std.testing.expect(!heap_mod.isImmutable(a));
}

test "make-string reports a length that is not a count, and a fill that is not a character" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    try std.testing.expectError(error.WrongType, call(&f, "make-string", &.{chr('a')}));
    try std.testing.expectError(error.WrongType, call(&f, "make-string", &.{try str(&f, "3")}));
    try std.testing.expectError(error.WrongType, call(&f, "make-string", &.{ fix(3), fix(97) }));
    // 型の誤りは、範囲の誤りより先に報告される。
    try std.testing.expectError(error.WrongType, call(&f, "make-string", &.{ fix(-1), fix(97) }));
    try std.testing.expectError(error.OutOfRange, call(&f, "make-string", &.{fix(-1)}));
    try std.testing.expectError(error.OutOfRange, call(&f, "make-string", &.{ fix(std.math.minInt(i64)), chr('a') }));
}

test "make-string past the limit is a heap limit before any bytes are made, whatever the size" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    f.heap.options.limit = f.heap.accounted + heap_mod.cellBytes(String) + 8;
    // 収まる最大の大きさは作れる。1つ多いと断る。
    try expectString("aaaaaaaa", try call(&f, "make-string", &.{ fix(8), chr('a') }));
    f.heap.collect(NoRoots{});
    try std.testing.expectError(error.HeapLimit, call(&f, "make-string", &.{ fix(9), chr('a') }));
    // 幅のある文字は、バイトの数で数える。4文字は8バイトである。
    try expectString("λλλλ", try call(&f, "make-string", &.{ fix(4), chr(0x3bb) }));
    f.heap.collect(NoRoots{});
    try std.testing.expectError(error.HeapLimit, call(&f, "make-string", &.{ fix(5), chr(0x3bb) }));
    // 桁あふれする大きさも、回り込まずに上限超過である。
    try std.testing.expectError(error.HeapLimit, call(&f, "make-string", &.{ fix(std.math.maxInt(i64)), chr(0x10000) }));
    try std.testing.expectError(error.HeapLimit, call(&f, "make-string", &.{fix(std.math.maxInt(i64))}));
    try std.testing.expectError(error.HeapLimit, call(&f, "make-string", &.{ fix(1 << 40), chr('a') }));
}

test "string gives a string of its arguments, which are characters" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    try expectString("", try call(&f, "string", &.{}));
    try expectString("a", try call(&f, "string", &.{chr('a')}));
    try expectString("abc", try call(&f, "string", &.{ chr('a'), chr('b'), chr('c') }));
    const mixed = try call(&f, "string", &.{ chr('a'), chr(0x3bb), chr(0x3042), chr(0x10000), chr('z') });
    try expectString("aλあ𐀀z", mixed);
    try std.testing.expectEqual(5, mixed.asString().?.length());
    try std.testing.expect(!heap_mod.isImmutable(mixed));
    // 最後の引数だけが文字でなくても、型の誤りである。
    try std.testing.expectError(error.WrongType, call(&f, "string", &.{ chr('a'), fix(98) }));
    try std.testing.expectError(error.WrongType, call(&f, "string", &.{try str(&f, "a")}));
}

test "string-set! writes a character of the same width in place" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    const s = try str(&f, "abc");
    const bytes = s.asString().?.bytes;
    const before = f.heap.accounted;
    const r = try call(&f, "string-set!", &.{ s, fix(1), chr('X') });
    try std.testing.expectEqual(value.Kind.unspecified, r.kind());
    try std.testing.expectEqualStrings("aXc", bytesOf(s));
    // バイト列は同じ場所にあり、計上は変わらない。
    try std.testing.expectEqual(bytes.ptr, s.asString().?.bytes.ptr);
    try std.testing.expectEqual(before, f.heap.accounted);
    try std.testing.expect(s.asString().?.is_ascii);
    // 同じ幅の非 ASCII を、非 ASCII の文字列に書く。
    const w = try str(&f, "aλb");
    _ = try call(&f, "string-set!", &.{ w, fix(1), chr(0xe9) });
    try expectString("aéb", w);
    _ = try call(&f, "string-set!", &.{ w, fix(2), chr('c') });
    try expectString("aéc", w);
}

test "string-set! of a character of another width remakes the bytes, and the flag follows" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    const s = try str(&f, "abc");
    try expectAccount(&f, 1, 3);
    // ASCII の文字列に、幅の広い文字を書く。長さは文字の数のまま、印は下りる。
    _ = try call(&f, "string-set!", &.{ s, fix(1), chr(0x3bb) });
    try expectString("aλc", s);
    try std.testing.expectEqual(3, s.asString().?.length());
    try std.testing.expect(!s.asString().?.is_ascii);
    try expectAccount(&f, 1, 4);
    try std.testing.expectEqual(0x3bb, (try call(&f, "string-ref", &.{ s, fix(1) })).asCharacter().?);
    try std.testing.expectEqual('c', (try call(&f, "string-ref", &.{ s, fix(2) })).asCharacter().?);
    // さらに広い文字へ。
    _ = try call(&f, "string-set!", &.{ s, fix(0), chr(0x10000) });
    try expectString("𐀀λc", s);
    try expectAccount(&f, 1, 7);
    // 狭い文字へ戻す。最後の非 ASCII を ASCII にすると、印が上がる。
    _ = try call(&f, "string-set!", &.{ s, fix(0), chr('a') });
    try expectString("aλc", s);
    try std.testing.expect(!s.asString().?.is_ascii);
    _ = try call(&f, "string-set!", &.{ s, fix(1), chr('b') });
    try expectString("abc", s);
    try std.testing.expect(s.asString().?.is_ascii);
    try expectAccount(&f, 1, 3);
    // 先頭と末尾の文字にも書ける。
    _ = try call(&f, "string-set!", &.{ s, fix(2), chr(0x3042) });
    _ = try call(&f, "string-set!", &.{ s, fix(0), chr(0x3042) });
    try expectString("あbあ", s);
    // 回収のあとも、計上は新しい長さで合っている。
    f.heap.collect(NoRoots{});
    try expectAccount(&f, 0, 0);
}

test "string-set! refuses what it cannot write, and leaves the string as it was" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    const s = try str(&f, "aλb");
    const n = 3;
    for ([_]i64{ n, n + 1, -1, 100, std.math.minInt(i64), std.math.maxInt(i64), 1 << 32 }) |k| {
        try std.testing.expectError(error.OutOfRange, call(&f, "string-set!", &.{ s, fix(k), chr('x') }));
    }
    try std.testing.expectError(error.WrongType, call(&f, "string-set!", &.{ fix(1), fix(0), chr('x') }));
    try std.testing.expectError(error.WrongType, call(&f, "string-set!", &.{ s, chr('a'), chr('x') }));
    try std.testing.expectError(error.WrongType, call(&f, "string-set!", &.{ s, fix(0), fix(120) }));
    try std.testing.expectError(error.WrongType, call(&f, "string-set!", &.{ s, fix(0), try str(&f, "x") }));
    // 型の誤りは、範囲の誤りより先である。
    try std.testing.expectError(error.WrongType, call(&f, "string-set!", &.{ s, fix(100), fix(120) }));
    try expectString("aλb", s);
    // 空の文字列には、書ける位置がない。
    const empty = try str(&f, "");
    try std.testing.expectError(error.OutOfRange, call(&f, "string-set!", &.{ empty, fix(0), chr('x') }));
}

test "string-set! refuses a string that is a constant, after the types and before the range" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    const s = try str(&f, "abc");
    heap_mod.makeImmutable(s);
    try std.testing.expectError(error.Immutable, call(&f, "string-set!", &.{ s, fix(0), chr('x') }));
    // 範囲の誤りより、定数の誤りが先である。型の誤りは、その前である。
    try std.testing.expectError(error.Immutable, call(&f, "string-set!", &.{ s, fix(100), chr('x') }));
    try std.testing.expectError(error.WrongType, call(&f, "string-set!", &.{ s, fix(0), fix(120) }));
    try std.testing.expectEqualStrings("abc", bytesOf(s));
    // 同じ文字を書き込む場合も断る。書き込もうとしたことが誤りである。
    try std.testing.expectError(error.Immutable, call(&f, "string-set!", &.{ s, fix(0), chr('a') }));
    // 対照: 同じ内容の別の文字列には書ける。
    const copy = try str(&f, "abc");
    _ = try call(&f, "string-set!", &.{ copy, fix(0), chr('x') });
    try std.testing.expectEqualStrings("xbc", bytesOf(copy));
}

test "string-set! that cannot make the new bytes leaves the string as it was" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    const s = try str(&f, "abc");
    // 幅が増える書き込みの分だけ余裕が無い。
    f.heap.options.limit = f.heap.accounted;
    try std.testing.expectError(error.HeapLimit, call(&f, "string-set!", &.{ s, fix(1), chr(0x3bb) }));
    try expectString("abc", s);
    try expectAccount(&f, 1, 3);
    // 同じ幅の書き込みは、確保しないので、上限にいても通る。
    _ = try call(&f, "string-set!", &.{ s, fix(1), chr('x') });
    try expectString("axc", s);
    // 余裕があれば通る。
    f.heap.options.limit = f.heap.accounted + 1;
    _ = try call(&f, "string-set!", &.{ s, fix(1), chr(0x3bb) });
    try expectString("aλc", s);
    // 確保そのものが失敗しても、同じである。
    var failing: std.testing.FailingAllocator = .init(std.testing.allocator, .{ .fail_index = 0 });
    const real = f.heap.backing;
    f.heap.backing = failing.allocator();
    f.heap.options.limit = 1 << 20;
    try std.testing.expectError(error.OutOfMemory, call(&f, "string-set!", &.{ s, fix(0), chr(0x10000) }));
    f.heap.backing = real;
    try expectString("aλc", s);
}

/// The result of the comparison `name` of the strings with the contents `contents`.
fn compareStrings(f: *test_support.Fixture, name: []const u8, contents: []const []const u8) !bool {
    var args: [8]Value = undefined;
    for (contents, 0..) |c, i| args[i] = try str(f, c);
    const r = try call(f, name, args[0..contents.len]);
    try std.testing.expectEqual(value.Kind.boolean, r.kind());
    return r.isTrue();
}

test "the comparisons of two strings follow the order of their characters" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    const Row = struct { name: []const u8, less: bool, equal: bool, greater: bool };
    const rows = [_]Row{
        .{ .name = "string=?", .less = false, .equal = true, .greater = false },
        .{ .name = "string<?", .less = true, .equal = false, .greater = false },
        .{ .name = "string>?", .less = false, .equal = false, .greater = true },
        .{ .name = "string<=?", .less = true, .equal = true, .greater = false },
        .{ .name = "string>=?", .less = false, .equal = true, .greater = true },
    };
    // 小さい、等しい、大きい。最初の文字、あとの文字、長さの違い(短いほうが小さい)。
    const Pair = struct { small: []const u8, big: []const u8 };
    const pairs = [_]Pair{
        .{ .small = "a", .big = "b" },
        .{ .small = "abc", .big = "abd" },
        .{ .small = "abc", .big = "abcd" },
        .{ .small = "", .big = "a" },
        .{ .small = "Z", .big = "a" },
        .{ .small = "ab", .big = "b" },
        // ASCII の外は、コードポイントの順である。UTF-8 のバイト列の順と一致する。
        .{ .small = "z", .big = "λ" },
        .{ .small = "λ", .big = "あ" },
        .{ .small = "\u{ffff}", .big = "\u{10000}" },
        .{ .small = "\u{d7ff}", .big = "\u{e000}" },
        .{ .small = "aλ", .big = "aあ" },
        .{ .small = "あ", .big = "あa" },
    };
    for (rows) |r| {
        for (pairs) |p| {
            try std.testing.expectEqual(r.less, try compareStrings(&f, r.name, &.{ p.small, p.big }));
            try std.testing.expectEqual(r.greater, try compareStrings(&f, r.name, &.{ p.big, p.small }));
            try std.testing.expectEqual(r.equal, try compareStrings(&f, r.name, &.{ p.small, p.small }));
        }
        try std.testing.expectEqual(r.equal, try compareStrings(&f, r.name, &.{ "", "" }));
    }
}

test "the comparisons take any number of strings, and hold when every neighboring pair does" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    try std.testing.expect(try compareStrings(&f, "string=?", &.{ "a", "a", "a", "a" }));
    try std.testing.expect(!try compareStrings(&f, "string=?", &.{ "a", "a", "b" }));
    try std.testing.expect(!try compareStrings(&f, "string=?", &.{ "b", "a", "a" }));
    try std.testing.expect(try compareStrings(&f, "string<?", &.{ "a", "b", "c", "d" }));
    try std.testing.expect(!try compareStrings(&f, "string<?", &.{ "a", "b", "b" }));
    try std.testing.expect(!try compareStrings(&f, "string<?", &.{ "a", "c", "b" }));
    try std.testing.expect(try compareStrings(&f, "string>?", &.{ "d", "c", "b" }));
    try std.testing.expect(!try compareStrings(&f, "string>?", &.{ "d", "b", "c" }));
    try std.testing.expect(try compareStrings(&f, "string<=?", &.{ "a", "a", "b", "b" }));
    try std.testing.expect(!try compareStrings(&f, "string<=?", &.{ "a", "b", "a" }));
    try std.testing.expect(try compareStrings(&f, "string>=?", &.{ "c", "c", "b", "a" }));
    try std.testing.expect(!try compareStrings(&f, "string>=?", &.{ "c", "b", "c" }));
    for ([_][]const u8{ "string=?", "string<?", "string>?", "string<=?", "string>=?" }) |name| {
        // 1つの引数は、比べる相手が無いので真である。
        try std.testing.expect(try compareStrings(&f, name, &.{"a"}));
        // 文字列でない引数は、最初に成り立たない組があっても、どの位置でも型の誤りである。
        try std.testing.expectError(error.WrongType, call(&f, name, &.{ try str(&f, "a"), chr('a') }));
        try std.testing.expectError(error.WrongType, call(&f, name, &.{ chr('a'), try str(&f, "a") }));
        try std.testing.expectError(error.WrongType, call(&f, name, &.{fix(1)}));
        try std.testing.expectError(error.WrongType, call(&f, name, &.{ try str(&f, "b"), try str(&f, "a"), try str(&f, "a"), fix(1) }));
        try std.testing.expectError(error.WrongType, call(&f, name, &.{ try str(&f, "a"), try str(&f, "b"), .empty_list_value }));
    }
}

test "the comparisons see the characters of a string that string-set! changed" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    const s = try str(&f, "abc");
    const t = try str(&f, "abc");
    try std.testing.expect((try call(&f, "string=?", &.{ s, t })).isTrue());
    _ = try call(&f, "string-set!", &.{ s, fix(2), chr(0x3bb) });
    try std.testing.expect(!(try call(&f, "string=?", &.{ s, t })).isTrue());
    try std.testing.expect((try call(&f, "string>?", &.{ s, t })).isTrue());
}

test "string-copy and substring give a new string of the characters in the range" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    const s = try str(&f, "abcde");
    try expectString("abcde", try call(&f, "string-copy", &.{s}));
    try expectString("cde", try call(&f, "string-copy", &.{ s, fix(2) }));
    try expectString("bc", try call(&f, "string-copy", &.{ s, fix(1), fix(3) }));
    try expectString("bc", try call(&f, "substring", &.{ s, fix(1), fix(3) }));
    try expectString("", try call(&f, "string-copy", &.{ s, fix(5) }));
    try expectString("", try call(&f, "string-copy", &.{ s, fix(2), fix(2) }));
    try expectString("", try call(&f, "substring", &.{ s, fix(0), fix(0) }));
    try expectString("", try call(&f, "string-copy", &.{try str(&f, "")}));
    // 位置は文字で数える。
    const w = try str(&f, "aλあ𐀀z");
    try expectString("λあ", try call(&f, "string-copy", &.{ w, fix(1), fix(3) }));
    try expectString("𐀀z", try call(&f, "substring", &.{ w, fix(3), fix(5) }));
    try expectString("aλあ𐀀z", try call(&f, "string-copy", &.{w}));
    try expectString("a", try call(&f, "string-copy", &.{ w, fix(0), fix(1) }));
    // ASCII だけの範囲を取り出すと、印は上がる。
    try std.testing.expect((try call(&f, "string-copy", &.{ w, fix(0), fix(1) })).asString().?.is_ascii);
    try std.testing.expect(!(try call(&f, "string-copy", &.{ w, fix(0), fix(2) })).asString().?.is_ascii);
}

test "string-copy is a new string that is not a constant, whatever it is a copy of" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    const s = try str(&f, "abc");
    heap_mod.makeImmutable(s);
    const full = try call(&f, "string-copy", &.{s});
    const part = try call(&f, "substring", &.{ s, fix(0), fix(2) });
    try std.testing.expect(full.asString().? != s.asString().?);
    try std.testing.expect(!heap_mod.isImmutable(full));
    try std.testing.expect(!heap_mod.isImmutable(part));
    _ = try call(&f, "string-set!", &.{ full, fix(0), chr('x') });
    try std.testing.expectEqualStrings("abc", bytesOf(s));
    try std.testing.expectEqualStrings("xbc", bytesOf(full));
    // 空の写しも新しい。
    const empty = try call(&f, "string-copy", &.{ s, fix(3) });
    try std.testing.expect(!heap_mod.isImmutable(empty));
}

test "the range of string-copy, substring, string->list, string->vector and vector->string is checked" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    const s = try str(&f, "aλbc");
    const v: Value = .fromVector(try f.heap.createVector(&.{ chr('a'), chr('b'), chr('c'), chr('d') }));
    const Case = struct { name: []const u8, subject: Value, length: i64 };
    const cases = [_]Case{
        .{ .name = "string-copy", .subject = s, .length = 4 },
        .{ .name = "string->list", .subject = s, .length = 4 },
        .{ .name = "string->vector", .subject = s, .length = 4 },
        .{ .name = "vector->string", .subject = v, .length = 4 },
    };
    for (cases) |c| {
        // start が長さまでは、空の範囲として通る。長さを超えると誤りである。
        _ = try call(&f, c.name, &.{ c.subject, fix(c.length) });
        _ = try call(&f, c.name, &.{ c.subject, fix(c.length), fix(c.length) });
        try std.testing.expectError(error.OutOfRange, call(&f, c.name, &.{ c.subject, fix(c.length + 1) }));
        try std.testing.expectError(error.OutOfRange, call(&f, c.name, &.{ c.subject, fix(0), fix(c.length + 1) }));
        try std.testing.expectError(error.OutOfRange, call(&f, c.name, &.{ c.subject, fix(c.length + 1), fix(c.length + 1) }));
        // start が end を超えると誤りである。
        try std.testing.expectError(error.OutOfRange, call(&f, c.name, &.{ c.subject, fix(2), fix(1) }));
        try std.testing.expectError(error.OutOfRange, call(&f, c.name, &.{ c.subject, fix(c.length), fix(0) }));
        // 負の数と、usize に収まらない数。
        try std.testing.expectError(error.OutOfRange, call(&f, c.name, &.{ c.subject, fix(-1) }));
        try std.testing.expectError(error.OutOfRange, call(&f, c.name, &.{ c.subject, fix(0), fix(-1) }));
        try std.testing.expectError(error.OutOfRange, call(&f, c.name, &.{ c.subject, fix(std.math.minInt(i64)) }));
        try std.testing.expectError(error.OutOfRange, call(&f, c.name, &.{ c.subject, fix(0), fix(std.math.maxInt(i64)) }));
        try std.testing.expectError(error.OutOfRange, call(&f, c.name, &.{ c.subject, fix(1 << 32), fix(1 << 32) }));
        // 型の誤りは範囲の誤りより先に報告される。
        try std.testing.expectError(error.WrongType, call(&f, c.name, &.{ c.subject, chr('a') }));
        try std.testing.expectError(error.WrongType, call(&f, c.name, &.{ c.subject, fix(100), chr('a') }));
        try std.testing.expectError(error.WrongType, call(&f, c.name, &.{ fix(1), fix(0) }));
    }
    try std.testing.expectError(error.OutOfRange, call(&f, "substring", &.{ s, fix(2), fix(5) }));
    try std.testing.expectError(error.OutOfRange, call(&f, "substring", &.{ s, fix(3), fix(2) }));
    try std.testing.expectError(error.WrongType, call(&f, "substring", &.{ s, fix(0), chr('a') }));
    try std.testing.expectError(error.WrongType, call(&f, "substring", &.{ chr('a'), fix(0), fix(1) }));
}

test "string-append gives a new string of the strings in order, and of one string a copy of it" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    try expectString("", try call(&f, "string-append", &.{}));
    try expectString("abcd", try call(&f, "string-append", &.{ try str(&f, "ab"), try str(&f, "cd") }));
    try expectString("abc", try call(&f, "string-append", &.{ try str(&f, ""), try str(&f, "abc"), try str(&f, "") }));
    try expectString("aλあ", try call(&f, "string-append", &.{ try str(&f, "a"), try str(&f, "λ"), try str(&f, "あ") }));
    const s = try str(&f, "abc");
    const same = try call(&f, "string-append", &.{s});
    try std.testing.expect(same.asString().? != s.asString().?);
    try expectString("abc", same);
    // 結果は定数ではない。引数が定数でも、そうである。
    heap_mod.makeImmutable(s);
    const joined = try call(&f, "string-append", &.{ s, s });
    try std.testing.expect(!heap_mod.isImmutable(joined));
    _ = try call(&f, "string-set!", &.{ joined, fix(0), chr('x') });
    try expectString("xbcabc", joined);
    try expectString("abc", s);
    // 長さは文字の数の和である。
    const mixed = try call(&f, "string-append", &.{ try str(&f, "aλ"), try str(&f, "あ𐀀") });
    try std.testing.expectEqual(4, mixed.asString().?.length());
    try std.testing.expectError(error.WrongType, call(&f, "string-append", &.{ s, chr('a') }));
    try std.testing.expectError(error.WrongType, call(&f, "string-append", &.{ s, s, .empty_list_value }));
    try std.testing.expectError(error.WrongType, call(&f, "string-append", &.{.fromSymbol(try f.heap.intern("a"))}));
}

test "string-append is held to the limit by the bytes of the whole result" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    const a = try str(&f, "abcd");
    const b = try str(&f, "efgh");
    // 結果の8バイトに足りない余裕では、書く前に断る。引数の長さは、1つずつは収まる。
    f.heap.options.limit = f.heap.accounted + heap_mod.cellBytes(String) + 7;
    try std.testing.expectError(error.HeapLimit, call(&f, "string-append", &.{ a, b }));
    try expectAccount(&f, 2, 8);
    f.heap.options.limit = f.heap.accounted + heap_mod.cellBytes(String) + 8;
    try expectString("abcdefgh", try call(&f, "string-append", &.{ a, b }));
}

test "list->string and string->list are inverses, and the range of string->list is the range of characters" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    const w = try str(&f, "aλあ𐀀z");
    const list = try call(&f, "string->list", &.{w});
    const expected = [_]u21{ 'a', 0x3bb, 0x3042, 0x10000, 'z' };
    var rest = list;
    for (expected) |c| {
        try std.testing.expectEqual(c, rest.asPair().?.car.asCharacter().?);
        rest = rest.asPair().?.cdr;
    }
    try std.testing.expectEqual(value.Kind.empty_list, rest.kind());
    try expectString("aλあ𐀀z", try call(&f, "list->string", &.{list}));
    // 範囲。
    const part = try call(&f, "string->list", &.{ w, fix(1), fix(3) });
    try expectString("λあ", try call(&f, "list->string", &.{part}));
    try std.testing.expectEqual(value.Kind.empty_list, (try call(&f, "string->list", &.{ w, fix(5) })).kind());
    try std.testing.expectEqual(value.Kind.empty_list, (try call(&f, "string->list", &.{try str(&f, "")})).kind());
    try expectString("", try call(&f, "list->string", &.{.empty_list_value}));
    // 結果のリストは新しいペアで、定数ではない。文字列が定数でも、そうである。
    heap_mod.makeImmutable(w);
    const fresh = try call(&f, "string->list", &.{w});
    try std.testing.expect(!heap_mod.isImmutable(fresh));
    try std.testing.expect(!heap_mod.isImmutable(fresh.asPair().?.cdr));
    // 結果の文字列も定数ではない。
    const made = try call(&f, "list->string", &.{fresh});
    try std.testing.expect(!heap_mod.isImmutable(made));
}

test "list->string reports what is not a list of characters, and a list that never ends" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    const ok = try f.heap.cons(chr('a'), try f.heap.cons(chr('b'), .empty_list_value));
    try expectString("ab", try call(&f, "list->string", &.{ok}));
    const bad_last = try f.heap.cons(chr('a'), try f.heap.cons(fix(98), .empty_list_value));
    try std.testing.expectError(error.WrongType, call(&f, "list->string", &.{bad_last}));
    const bad_first = try f.heap.cons(fix(97), try f.heap.cons(chr('b'), .empty_list_value));
    try std.testing.expectError(error.WrongType, call(&f, "list->string", &.{bad_first}));
    // リストでないもの。末尾が空リストでない鎖と、リストでない値。
    const dotted = try f.heap.cons(chr('a'), chr('b'));
    try std.testing.expectError(error.WrongType, call(&f, "list->string", &.{dotted}));
    try std.testing.expectError(error.WrongType, call(&f, "list->string", &.{chr('a')}));
    try std.testing.expectError(error.WrongType, call(&f, "list->string", &.{try str(&f, "ab")}));
    // 輪になった鎖は、止まって、型の誤りになる。
    const ring = try f.heap.cons(chr('a'), .empty_list_value);
    ring.asPair().?.cdr = ring;
    try std.testing.expectError(error.WrongType, call(&f, "list->string", &.{ring}));
    const long = try f.heap.cons(chr('a'), try f.heap.cons(chr('b'), try f.heap.cons(chr('c'), .empty_list_value)));
    long.asPair().?.cdr.asPair().?.cdr.asPair().?.cdr = long;
    try std.testing.expectError(error.WrongType, call(&f, "list->string", &.{long}));
}

test "string->vector and vector->string carry characters between the two" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    const w = try str(&f, "aλあ𐀀z");
    const v = try call(&f, "string->vector", &.{w});
    try std.testing.expectEqual(5, v.asVector().?.items.len);
    const expected = [_]u21{ 'a', 0x3bb, 0x3042, 0x10000, 'z' };
    for (expected, v.asVector().?.items) |c, item| try std.testing.expectEqual(c, item.asCharacter().?);
    try expectString("aλあ𐀀z", try call(&f, "vector->string", &.{v}));
    const part = try call(&f, "string->vector", &.{ w, fix(1), fix(3) });
    try std.testing.expectEqual(2, part.asVector().?.items.len);
    try expectString("λあ", try call(&f, "vector->string", &.{part}));
    try expectString("あ𐀀", try call(&f, "vector->string", &.{ v, fix(2), fix(4) }));
    try std.testing.expectEqual(0, (try call(&f, "string->vector", &.{ w, fix(5) })).asVector().?.items.len);
    try expectString("", try call(&f, "vector->string", &.{ v, fix(5) }));
    // 範囲の外の要素は、文字でなくてもよい。範囲の中に文字でないものがあると、型の誤りである。
    const mixed: Value = .fromVector(try f.heap.createVector(&.{ chr('a'), fix(1), chr('c') }));
    try expectString("a", try call(&f, "vector->string", &.{ mixed, fix(0), fix(1) }));
    try expectString("c", try call(&f, "vector->string", &.{ mixed, fix(2) }));
    try std.testing.expectError(error.WrongType, call(&f, "vector->string", &.{mixed}));
    try std.testing.expectError(error.WrongType, call(&f, "vector->string", &.{ mixed, fix(1), fix(2) }));
    // 結果は新しいオブジェクトで、定数ではない。
    heap_mod.makeImmutable(w);
    heap_mod.makeImmutable(v);
    try std.testing.expect(!heap_mod.isImmutable(try call(&f, "string->vector", &.{w})));
    try std.testing.expect(!heap_mod.isImmutable(try call(&f, "vector->string", &.{v})));
    try std.testing.expectError(error.WrongType, call(&f, "string->vector", &.{v}));
    try std.testing.expectError(error.WrongType, call(&f, "vector->string", &.{w}));
}

test "string->list, string->vector and vector->string are held to the limit" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    const w = try str(&f, "abcdef");
    const v = try call(&f, "string->vector", &.{w});
    // 6個のペアには足りない。
    f.heap.options.limit = f.heap.accounted + 5 * heap_mod.cellBytes(value.Pair);
    try std.testing.expectError(error.HeapLimit, call(&f, "string->list", &.{w}));
    f.heap.options.limit = f.heap.accounted + 6 * heap_mod.cellBytes(value.Pair);
    _ = try call(&f, "string->list", &.{w});
    // 6要素のベクタ。ペイロードを書く前に断る。
    f.heap.collect(KeepRoots{ .values = &.{ w, v } });
    f.heap.options.limit = 0;
    try std.testing.expectError(error.HeapLimit, call(&f, "string->vector", &.{w}));
    try std.testing.expectError(error.HeapLimit, call(&f, "vector->string", &.{v}));
}

test "string-copy! copies the characters of the range to the position, as the report's example does" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    // R7RS 6.7 の例。
    const a = try str(&f, "12345");
    const b = try str(&f, "abcde");
    const r = try call(&f, "string-copy!", &.{ b, fix(1), a, fix(0), fix(2) });
    try std.testing.expectEqual(value.Kind.unspecified, r.kind());
    try expectString("a12de", b);
    // start と end は省ける。
    const c = try str(&f, "abcde");
    _ = try call(&f, "string-copy!", &.{ c, fix(2), try str(&f, "XYZ") });
    try expectString("abXYZ", c);
    const d = try str(&f, "abcde");
    _ = try call(&f, "string-copy!", &.{ d, fix(0), try str(&f, "XYZ"), fix(1) });
    try expectString("YZcde", d);
    // 書く文字の数が0なら、何も変わらない。位置は長さまで置ける。
    const e = try str(&f, "abc");
    _ = try call(&f, "string-copy!", &.{ e, fix(3), try str(&f, "") });
    _ = try call(&f, "string-copy!", &.{ e, fix(3), try str(&f, "xyz"), fix(3) });
    _ = try call(&f, "string-copy!", &.{ e, fix(1), try str(&f, "xyz"), fix(1), fix(1) });
    try expectString("abc", e);
    // 全部を置き換える。
    _ = try call(&f, "string-copy!", &.{ e, fix(0), try str(&f, "xyz") });
    try expectString("xyz", e);
}

test "string-copy! of ranges that overlap acts as if the source were copied first" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    // 先へ重ねる(後ろから写す向き)。
    const forward = try str(&f, "abcde");
    _ = try call(&f, "string-copy!", &.{ forward, fix(1), forward, fix(0), fix(3) });
    try expectString("aabce", forward);
    // 手前へ重ねる(前から写す向き)。
    const backward = try str(&f, "abcde");
    _ = try call(&f, "string-copy!", &.{ backward, fix(0), backward, fix(1), fix(4) });
    try expectString("bcdde", backward);
    // 同じ位置。
    const same = try str(&f, "abcde");
    _ = try call(&f, "string-copy!", &.{ same, fix(1), same, fix(1), fix(4) });
    try expectString("abcde", same);
    // 幅の違う文字の重なりでも、元の内容が先に写されたように振る舞う。
    const wide = try str(&f, "aλbあc");
    _ = try call(&f, "string-copy!", &.{ wide, fix(1), wide, fix(0), fix(4) });
    try expectString("aaλbあ", wide);
    const wide_back = try str(&f, "aλbあc");
    _ = try call(&f, "string-copy!", &.{ wide_back, fix(0), wide_back, fix(1), fix(5) });
    try expectString("λbあcc", wide_back);
}

test "string-copy! across widths remakes the bytes, and keeps the length in characters and the account" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    // ASCII に、幅の広い文字を写す。
    const s = try str(&f, "abcde");
    _ = try call(&f, "string-copy!", &.{ s, fix(1), try str(&f, "λあ") });
    try expectString("aλあde", s);
    try std.testing.expectEqual(5, s.asString().?.length());
    try std.testing.expect(!s.asString().?.is_ascii);
    // 幅の広い文字を、ASCII で置き換える。印は、非 ASCII が無くなったとき上がる。
    _ = try call(&f, "string-copy!", &.{ s, fix(1), try str(&f, "xy") });
    try expectString("axyde", s);
    try std.testing.expect(s.asString().?.is_ascii);
    // 置き換える範囲と同じバイト数の文字は、その場で書く。
    const t = try str(&f, "a\u{e9}c");
    const before = t.asString().?.bytes.ptr;
    _ = try call(&f, "string-copy!", &.{ t, fix(1), try str(&f, "\u{fc}") });
    try expectString("a\u{fc}c", t);
    try std.testing.expectEqual(before, t.asString().?.bytes.ptr);
    f.heap.collect(KeepRoots{ .values = &.{ s, t } });
    try expectAccount(&f, 2, 5 + 4);
}

test "string-copy! reports the arguments it cannot use, before it changes anything" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    const to = try str(&f, "abcde");
    const from = try str(&f, "XYZ");
    const OutOfRangeCall = struct { at: i64, start: ?i64, end: ?i64 };
    const bad = [_]OutOfRangeCall{
        .{ .at = -1, .start = null, .end = null },
        .{ .at = 6, .start = null, .end = null },
        .{ .at = std.math.maxInt(i64), .start = null, .end = null },
        .{ .at = 1 << 32, .start = null, .end = null },
        // to の残りが end - start に足りない。
        .{ .at = 3, .start = null, .end = null },
        .{ .at = 5, .start = 0, .end = 1 },
        .{ .at = 0, .start = 0, .end = 6 },
        // start と end の範囲。
        .{ .at = 0, .start = 4, .end = null },
        .{ .at = 0, .start = 2, .end = 1 },
        .{ .at = 0, .start = -1, .end = null },
        .{ .at = 0, .start = 0, .end = -1 },
        .{ .at = 0, .start = 0, .end = 4 },
    };
    for (bad) |c| {
        var args: [5]Value = .{ to, fix(c.at), from, undefined, undefined };
        var n: usize = 3;
        if (c.start) |x| {
            args[3] = fix(x);
            n = 4;
        }
        if (c.end) |x| {
            args[4] = fix(x);
            n = 5;
        }
        if (c.end != null and c.start == null) unreachable;
        try std.testing.expectError(error.OutOfRange, call(&f, "string-copy!", args[0..n]));
    }
    try expectString("abcde", to);
    try std.testing.expectError(error.WrongType, call(&f, "string-copy!", &.{ fix(1), fix(0), from }));
    try std.testing.expectError(error.WrongType, call(&f, "string-copy!", &.{ to, chr('a'), from }));
    try std.testing.expectError(error.WrongType, call(&f, "string-copy!", &.{ to, fix(0), fix(1) }));
    try std.testing.expectError(error.WrongType, call(&f, "string-copy!", &.{ to, fix(0), from, chr('a') }));
    try std.testing.expectError(error.WrongType, call(&f, "string-copy!", &.{ to, fix(0), from, fix(0), chr('a') }));
    // 型の誤りは、範囲の誤りより先である。
    try std.testing.expectError(error.WrongType, call(&f, "string-copy!", &.{ to, fix(100), fix(1) }));
    try expectString("abcde", to);
}

test "string-copy! refuses a destination that is a constant, even to copy nothing, and takes a constant source" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    const to = try str(&f, "abc");
    heap_mod.makeImmutable(to);
    const from = try str(&f, "xyz");
    try std.testing.expectError(error.Immutable, call(&f, "string-copy!", &.{ to, fix(0), from }));
    try std.testing.expectError(error.Immutable, call(&f, "string-copy!", &.{ to, fix(3), try str(&f, "") }));
    // 範囲の誤りより、定数の誤りが先である。
    try std.testing.expectError(error.Immutable, call(&f, "string-copy!", &.{ to, fix(100), from }));
    // 型の誤りは、その前である。
    try std.testing.expectError(error.WrongType, call(&f, "string-copy!", &.{ to, fix(0), fix(1) }));
    try expectString("abc", to);
    // 対照: 定数の文字列を、写す元にはできる。
    heap_mod.makeImmutable(from);
    const target = try str(&f, "abc");
    _ = try call(&f, "string-copy!", &.{ target, fix(0), from });
    try expectString("xyz", target);
    // 自分自身へ写すとき、自分が定数なら断る。
    try std.testing.expectError(error.Immutable, call(&f, "string-copy!", &.{ to, fix(0), to }));
}

test "string-copy! that cannot make the new bytes leaves the destination as it was" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    const to = try str(&f, "abc");
    const from = try str(&f, "λ");
    f.heap.options.limit = f.heap.accounted;
    try std.testing.expectError(error.HeapLimit, call(&f, "string-copy!", &.{ to, fix(0), from }));
    try expectString("abc", to);
    f.heap.options.limit = f.heap.accounted + 1;
    _ = try call(&f, "string-copy!", &.{ to, fix(0), from });
    try expectString("λbc", to);
}

test "string-fill! stores the character in the range, and in the whole string by default" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    const s = try str(&f, "abcde");
    const r = try call(&f, "string-fill!", &.{ s, chr('x') });
    try std.testing.expectEqual(value.Kind.unspecified, r.kind());
    try expectString("xxxxx", s);
    const t = try str(&f, "abcde");
    _ = try call(&f, "string-fill!", &.{ t, chr('x'), fix(2) });
    try expectString("abxxx", t);
    const u = try str(&f, "abcde");
    _ = try call(&f, "string-fill!", &.{ u, chr('x'), fix(1), fix(3) });
    try expectString("axxde", u);
    // 空の範囲は、何も変えない。
    _ = try call(&f, "string-fill!", &.{ u, chr('z'), fix(2), fix(2) });
    _ = try call(&f, "string-fill!", &.{ u, chr('z'), fix(5) });
    _ = try call(&f, "string-fill!", &.{ try str(&f, ""), chr('z') });
    try expectString("axxde", u);
}

test "string-fill! across widths remakes the bytes, and the flag follows" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    const s = try str(&f, "abcde");
    _ = try call(&f, "string-fill!", &.{ s, chr(0x3bb), fix(1), fix(3) });
    try expectString("aλλde", s);
    try std.testing.expectEqual(5, s.asString().?.length());
    try std.testing.expect(!s.asString().?.is_ascii);
    _ = try call(&f, "string-fill!", &.{ s, chr(0x10000) });
    try expectString("𐀀𐀀𐀀𐀀𐀀", s);
    try expectAccount(&f, 1, 20);
    _ = try call(&f, "string-fill!", &.{ s, chr('z') });
    try expectString("zzzzz", s);
    try std.testing.expect(s.asString().?.is_ascii);
    try expectAccount(&f, 1, 5);
    // 同じ幅のなかで、非 ASCII を置き換える。
    const w = try str(&f, "aλλb");
    _ = try call(&f, "string-fill!", &.{ w, chr(0xe9), fix(1), fix(3) });
    try expectString("aééb", w);
    try expectAccount(&f, 2, 5 + 6);
}

test "string-fill! refuses what it cannot use, and a constant before the range" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    const s = try str(&f, "abc");
    try std.testing.expectError(error.WrongType, call(&f, "string-fill!", &.{ fix(1), chr('x') }));
    try std.testing.expectError(error.WrongType, call(&f, "string-fill!", &.{ s, fix(120) }));
    try std.testing.expectError(error.WrongType, call(&f, "string-fill!", &.{ s, try str(&f, "x") }));
    try std.testing.expectError(error.WrongType, call(&f, "string-fill!", &.{ s, chr('x'), chr('a') }));
    try std.testing.expectError(error.OutOfRange, call(&f, "string-fill!", &.{ s, chr('x'), fix(4) }));
    try std.testing.expectError(error.OutOfRange, call(&f, "string-fill!", &.{ s, chr('x'), fix(2), fix(1) }));
    try std.testing.expectError(error.OutOfRange, call(&f, "string-fill!", &.{ s, chr('x'), fix(0), fix(4) }));
    try std.testing.expectError(error.OutOfRange, call(&f, "string-fill!", &.{ s, chr('x'), fix(-1) }));
    try expectString("abc", s);
    heap_mod.makeImmutable(s);
    try std.testing.expectError(error.Immutable, call(&f, "string-fill!", &.{ s, chr('x') }));
    try std.testing.expectError(error.Immutable, call(&f, "string-fill!", &.{ s, chr('x'), fix(1), fix(1) }));
    try std.testing.expectError(error.Immutable, call(&f, "string-fill!", &.{ s, chr('x'), fix(100) }));
    try std.testing.expectError(error.Immutable, call(&f, "string-fill!", &.{ try emptyConstant(&f), chr('x') }));
    try std.testing.expectError(error.WrongType, call(&f, "string-fill!", &.{ s, fix(120), fix(100) }));
    try expectString("abc", s);
}

/// The empty string, as a constant.
fn emptyConstant(f: *test_support.Fixture) !Value {
    const s = try str(f, "");
    heap_mod.makeImmutable(s);
    return s;
}

test "string-fill! that cannot make the new bytes leaves the string as it was" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    const s = try str(&f, "abcd");
    f.heap.options.limit = f.heap.accounted + 3;
    try std.testing.expectError(error.HeapLimit, call(&f, "string-fill!", &.{ s, chr(0x3bb) }));
    try expectString("abcd", s);
    // 桁あふれする書き込みも、回り込まない。
    f.heap.options.limit = f.heap.accounted + 4;
    _ = try call(&f, "string-fill!", &.{ s, chr(0x3bb) });
    try expectString("λλλλ", s);
}

test "the strings that the primitives write keep their characters through a collection" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    const s = try str(&f, "abc");
    _ = try call(&f, "string-set!", &.{ s, fix(1), chr(0x3bb) });
    const t = try call(&f, "string-append", &.{ s, s });
    garbage: {
        _ = try call(&f, "make-string", &.{ fix(100), chr('g') });
        break :garbage;
    }
    f.heap.collect(KeepRoots{ .values = &.{ s, t } });
    try expectString("aλc", s);
    try expectString("aλcaλc", t);
    try expectAccount(&f, 2, 4 + 8);
    try std.testing.expectEqual(2, f.heap.count);
}
