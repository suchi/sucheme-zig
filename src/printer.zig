//! Writes values in their external representation.
//!
//! スライス 1d が表示するのは、整数、真偽値、シンボル、リスト、手続きである。
//! 未指定値(unspecified value)は `#<unspecified>` と書く。最上位の未指定値を表示
//! しないのは、結果を表示する側の判断である。スライス 1h で文字、文字列、ベクタを
//! 足し、それとともに `write` と `display` の違いが入った(R7RS 6.13.3)。`write` は
//! `read` が読み戻せる形を出し、`display` は人が読むテキストを出す。
//!
//! どこまで深く進むかはデータの深さで決まるので、Zig の再帰でなく、明示的な
//! スタックで動く(docs/design/runtime.md)。
//!
//! スライス 5j で、`write` の3種(`write`、`write-shared`、`write-simple`)と `display` の
//! 4つの形にした。循環と共有は、データラベル(R7RS 2.4 の `#n=` と `#n#`)で書く。ラベルを
//! 付けるものは、書く前に1回辿って決める(`Labels.find`)。

const std = @import("std");
const value_mod = @import("value.zig");
const Value = value_mod.Value;
const symbol = @import("symbol.zig");
const Heap = @import("heap.zig").Heap;
const char_syntax = @import("char_syntax.zig");
const string_syntax = @import("string_syntax.zig");
const number = @import("num/number.zig");
const num_syntax = @import("num/syntax.zig");
const reader = @import("reader.zig");

pub const Error = std.Io.Writer.Error || error{ OutOfMemory, HeapLimit };

/// What is left to write.
const Item = union(enum) {
    /// A value to write whole.
    value: Value,
    /// The rest of a list after an element: a space and the next element, a
    /// closing parenthesis at the end, or ` . ` and a non-list tail.
    rest: Value,
    /// Text to write as it is.
    text: []const u8,
    /// The rest of a vector from element `next` on: a space and that element,
    /// or the closing parenthesis once there are none left.
    elements: Elements,
    /// The rest of the irritants of a condition: a space and the next one, or
    /// the closing `>` at the end of the list.
    irritants: Value,

    const Elements = struct { items: []const Value, next: usize };
};

/// Which of the external forms of data to write (R7RS 6.13.3).
/// - `write`: 循環にだけラベルを付ける。循環が無ければ付けない。
/// - `shared`: 2回以上現れるペアとベクタ(と条件オブジェクト)すべてにラベルを付ける(`write-shared`)。
/// - `simple`: ラベルを付けない。循環したデータでは止まらない(`write-simple`)。
/// - `display`: `write` と同じく循環にだけラベルを付け、文字列と文字をそのまま、シンボルを
///   縦棒なしで書く。
pub const Mode = enum {
    write,
    shared,
    simple,
    display,

    /// The form strings and characters take: `display`'s, or `write`'s for the
    /// three kinds of `write`.
    /// Why: `char_syntax` と `string_syntax` は、`write` と `display` の2つだけを見分ける。
    fn text(self: Mode) Mode {
        return if (self == .display) .display else .write;
    }
};

/// Writes `v` as the procedure of `mode` would (R7RS 6.13.3).
/// シンボル名は `symbols` から取る。まだ書いていないものを積むスタックと、ラベルの表は、
/// `heap` の上限に数える確保(`Heap.residentAllocator`)で持ち、戻る前に解放する。上限に
/// 収まらなければ `HeapLimit` を返す。データの大きさに比例して伸びる作業領域だからである
/// (docs/design/runtime.md の計上の対象)。
pub fn print(out: *std.Io.Writer, heap: *Heap, symbols: *const symbol.Table, v: Value, mode: Mode) Error!void {
    // 確保を断られたことは、`external_refused` で見分ける。呼び出し側の印は戻す
    // (`prim/equiv.zig` の `equal` と同じ形)。
    const was_refused = heap.external_refused;
    heap.external_refused = false;
    defer heap.external_refused = was_refused;
    const gpa = heap.residentAllocator();
    var labels: Labels = .{};
    defer labels.deinit(gpa);
    emit(out, gpa, symbols, v, mode, &labels) catch |e| switch (e) {
        error.OutOfMemory => return if (heap.external_refused) error.HeapLimit else error.OutOfMemory,
        // Why: 数の書式(src/num/number.zig)は、作業領域に置いた書き手に書いてから写すことがある。
        // その書き手が確保を断られると、`out` の失敗でなくても `WriteFailed` になる。断られたことは
        // `external_refused` で分かるので、上限の誤りに戻す。
        error.WriteFailed => return if (heap.external_refused) error.HeapLimit else error.WriteFailed,
    };
}

/// The pairs, vectors and conditions that are written with a datum label.
/// 鍵はオブジェクトの番地である。条件オブジェクトは irritant を書くので、irritant のリストを
/// 書き換えると、条件を通る循環ができる。レコードはフィールドを書かないので、辿らない。
const Labels = struct {
    marks: std.AutoHashMapUnmanaged(usize, Mark) = .empty,
    /// The number the next label written takes.
    next: u29 = 0,

    /// What the passes know of one object, in 32 bits.
    /// Why: 表は辿ったペアとベクタのすべてを持つので、書くデータの大きさに比例する。値を
    /// 詰めて、1つあたりの大きさを抑える。番号は、ヒープに置けるオブジェクトの数(上限の
    /// 1 GiB をペアの大きさで割った数)より大きい 2^29 まで持てる。
    const Mark = packed struct(u32) {
        /// Whether the first pass is still inside the object: it is on the path from
        /// the top to where the pass is.
        open: bool = true,
        /// Whether the object is written with a label.
        labeled: bool = false,
        /// Whether the object has been written, and so has its `number`.
        written: bool = false,
        /// The label's number, once the object has been written.
        number: u29 = 0,
    };

    /// What is left to do in the first pass.
    const Step = union(enum) {
        visit: Value,
        /// The pass has seen all that the object at this address holds.
        leave: usize,
    };

    fn deinit(self: *Labels, gpa: std.mem.Allocator) void {
        self.marks.deinit(gpa);
    }

    /// Marks the objects in `v` that `mode` writes with a label: those that are
    /// reached again from inside themselves (a cycle), and for `shared`, those
    /// that are reached a second time in any way.
    /// 深さ優先で辿り、まだ出ていない(`open`)オブジェクトにもう一度着いたら、循環である。
    /// どの循環も、深さ優先の辿りでは、まだ出ていないオブジェクトに戻る辺を1つ含むので、
    /// 戻り先にラベルを付ければ、書くときに同じオブジェクトを2回書き始めることはない。
    fn find(self: *Labels, gpa: std.mem.Allocator, v: Value, mode: Mode) error{OutOfMemory}!void {
        var stack: std.ArrayList(Step) = .empty;
        defer stack.deinit(gpa);
        try stack.append(gpa, .{ .visit = v });
        while (stack.pop()) |step| switch (step) {
            .leave => |key| self.marks.getPtr(key).?.open = false,
            .visit => |x| {
                const key = keyOf(x) orelse continue;
                const entry = try self.marks.getOrPut(gpa, key);
                if (entry.found_existing) {
                    if (mode == .shared or entry.value_ptr.open) entry.value_ptr.labeled = true;
                    continue;
                }
                entry.value_ptr.* = .{};
                try stack.append(gpa, .{ .leave = key });
                if (x.asPair()) |p| {
                    try stack.append(gpa, .{ .visit = p.cdr });
                    try stack.append(gpa, .{ .visit = p.car });
                } else if (x.asVector()) |vec| {
                    var i = vec.items.len;
                    while (i > 0) {
                        i -= 1;
                        try stack.append(gpa, .{ .visit = vec.items[i] });
                    }
                } else if (x.asCondition()) |c| {
                    try stack.append(gpa, .{ .visit = c.irritants });
                    try stack.append(gpa, .{ .visit = c.message });
                }
            },
        };
    }

    /// The mark of `v` if it is written with a label.
    fn labelOf(self: *const Labels, v: Value) ?*Mark {
        const key = keyOf(v) orelse return null;
        const mark = self.marks.getPtr(key) orelse return null;
        return if (mark.labeled) mark else null;
    }

    /// The address of `v` if a label may name it.
    fn keyOf(v: Value) ?usize {
        if (v.asPair()) |p| return @intFromPtr(p);
        if (v.asVector()) |vec| return @intFromPtr(vec);
        if (v.asCondition()) |c| return @intFromPtr(c);
        return null;
    }
};

fn emit(out: *std.Io.Writer, scratch: std.mem.Allocator, symbols: *const symbol.Table, v: Value, mode: Mode, labels: *Labels) error{ WriteFailed, OutOfMemory }!void {
    var stack: std.ArrayList(Item) = .empty;
    defer stack.deinit(scratch);
    // 中に値を持たない値は、表も作業スタックも要らない。ただし、数の書式は作業領域を使うことが
    // ある(多倍長整数と複素数)ので、上限の際では `HeapLimit` になりうる。
    if (!holdsValues(v)) return emitValue(out, scratch, symbols, v, mode, &stack);
    if (mode != .simple) try labels.find(scratch, v, mode);
    try stack.append(scratch, .{ .value = v });
    while (stack.pop()) |item| switch (item) {
        .text => |t| try out.writeAll(t),
        .elements => |e| if (e.next == e.items.len) {
            try out.writeByte(')');
        } else {
            if (e.next != 0) try out.writeByte(' ');
            try stack.append(scratch, .{ .elements = .{ .items = e.items, .next = e.next + 1 } });
            try stack.append(scratch, .{ .value = e.items[e.next] });
        },
        .value => |x| {
            if (labels.labelOf(x)) |mark| {
                // 2回目からは、ラベルだけを書く。
                if (mark.written) {
                    try out.print("#{d}#", .{mark.number});
                    continue;
                }
                mark.written = true;
                mark.number = labels.next;
                labels.next += 1;
                try out.print("#{d}=", .{mark.number});
            }
            try emitValue(out, scratch, symbols, x, mode, &stack);
        },
        // irritant のリストの続きも、ラベルの付くペアは `. #n=(...)` か `. #n#` と書く。続きとして
        // たどると、cdr が循環したリストで止まらない。
        .irritants => |rest| if (rest.asPair()) |p| {
            if (labels.labelOf(rest) != null) {
                try out.writeAll(" . ");
                try stack.append(scratch, .{ .text = ">" });
                try stack.append(scratch, .{ .value = rest });
                continue;
            }
            try out.writeByte(' ');
            try stack.append(scratch, .{ .irritants = p.cdr });
            try stack.append(scratch, .{ .value = p.car });
        } else {
            try out.writeByte('>');
        },
        .rest => |tail| switch (tail.kind()) {
            .empty_list => try out.writeByte(')'),
            // ラベルの付くペアは、リストの続きとして書かず、`. #n=(...)` か `. #n#` と書く。
            // ラベルはデータの頭にしか置けないからである(R7RS 2.4)。
            .pair => if (labels.labelOf(tail) == null) {
                const p = tail.asPair().?;
                try out.writeByte(' ');
                try stack.append(scratch, .{ .rest = p.cdr });
                try stack.append(scratch, .{ .value = p.car });
            } else {
                try out.writeAll(" . ");
                try stack.append(scratch, .{ .text = ")" });
                try stack.append(scratch, .{ .value = tail });
            },
            else => {
                try out.writeAll(" . ");
                try stack.append(scratch, .{ .text = ")" });
                try stack.append(scratch, .{ .value = tail });
            },
        },
    };
}

/// Whether writing `v` writes other values: those that `emitValue` puts on the stack.
fn holdsValues(v: Value) bool {
    return switch (v.kind()) {
        .pair, .vector, .condition, .alias => true,
        else => false,
    };
}

/// Writes the value `x` itself, or its opening and what is left of it on `stack`.
fn emitValue(out: *std.Io.Writer, scratch: std.mem.Allocator, symbols: *const symbol.Table, x: Value, mode: Mode, stack: *std.ArrayList(Item)) error{ WriteFailed, OutOfMemory }!void {
    switch (x.kind()) {
        .fixnum => try out.print("{d}", .{x.asFixnum().?}),
        // 数の書式は src/num/ が持つ(docs/plans/0018-phase4-numeric-tower-unicode.md)。
        // `write` と `display` で同じである。
        .flonum, .bignum, .ratnum, .compnum => try number.write(out, scratch, x, 10),
        .boolean => try out.writeAll(if (x.isTrue()) "#t" else "#f"),
        .empty_list => try out.writeAll("()"),
        .symbol => try writeSymbol(out, symbols.nameOf(x.asSymbol().?), mode),
        .character => try char_syntax.write(out, mode.text(), x.asCharacter().?),
        .string => try string_syntax.write(out, mode.text(), x.asString().?.bytes),
        .vector => {
            try out.writeAll("#(");
            try stack.append(scratch, .{ .elements = .{ .items = x.asVector().?.items, .next = 0 } });
        },
        // Why: R7RS 6.9 は `#u8(` バイト ... `)` と書く。バイトは 10 進の整数で、`read` が
        // 同じバイトベクタを読み返せる。中身がバイトだけなので、スタックに積まず、その場で書く。
        .bytevector => {
            try out.writeAll("#u8(");
            for (x.asBytevector().?.bytes, 0..) |byte, i| {
                if (i != 0) try out.writeByte(' ');
                try out.print("{d}", .{byte});
            }
            try out.writeByte(')');
        },
        // Why: R7RS は手続きの外部表現を決めていない。多くの処理系は `read` が
        // 受け付けない表記で書き、ここでもそうする。
        .closure => try out.writeAll("#<procedure>"),
        // 継続も手続きである(R7RS 6.10)。手続きと同じく読めない表記で、種類を書く。
        .continuation => try out.writeAll("#<continuation>"),
        // パラメータも手続きである(R7RS 4.2.6)。同じく読めない表記で、種類を書く。
        .parameter => try out.writeAll("#<parameter>"),
        // Why: R7RS 6.13.2 は EOF の値の外部表現を決めておらず、`read` が読める値でも
        // ないと定めている。手続きと同じく、読めない表記で書く。
        .eof => try out.writeAll("#<eof>"),
        // 約束も、R7RS 4.2.5 は外部表現を決めていない。強制済みかは書かない(書くと、`write` が
        // 約束の状態を読む表記を作ってしまう)。
        .promise => try out.writeAll("#<promise>"),
        // ポートも、R7RS 6.13 は外部表現を決めていない。向きや開閉の状態は書かない。
        .port => try out.writeAll("#<port>"),
        // 環境の指定子も、R7RS 6.12 は外部表現を決めていない。
        .environment => try out.writeAll("#<environment>"),
        // 複数値のオブジェクトは、1個を要求する継続に届くと誤りになるので、データの中には
        // 入らない。最上位の値は `Interpreter` が1つずつ書く。漏れたときに分かるよう、
        // それでも書く。
        .multiple_values => try out.writeAll("#<values>"),
        .primitive => try out.print("#<procedure {s}>", .{x.asPrimitive().?.name}),
        .pair => {
            const p = x.asPair().?;
            try out.writeByte('(');
            try stack.append(scratch, .{ .rest = p.cdr });
            try stack.append(scratch, .{ .value = p.car });
        },
        // Why: データの中の未規定値(`(list (if #f #f))` など)を何も書かないと、
        // `(1 . )` のように読めない出力になる。読めない表記で書く。最上位の値を
        // 表示しないことは、プリンタでなく呼び出し側(`Interpreter`)が決める。
        .unspecified => try out.writeAll("#<unspecified>"),
        // これを持つ変数を読むとエラーになるので、プログラムがこれを目にすることは
        // ない。漏れたときに分かるよう、それでも書く。
        .uninitialized => try out.writeAll("#<uninitialized>"),
        // 別名は展開器の中だけにあり、`quote` が元のシンボルに戻すので、機械にも
        // プログラムにも届かない。展開器のテストが展開の結果を読めるよう、内側の
        // 識別子を包む、読めない表記で書く。
        .alias => {
            try out.writeAll("#<alias ");
            try stack.append(scratch, .{ .text = ">" });
            try stack.append(scratch, .{ .value = x.asAlias().?.inner });
        },
        // Why: R7RS 5.5 はレコードとその型の外部表現を決めていない。手続きと同じく、
        // `read` が受け付けない表記で、型の名前を添えて書く。フィールドの値は書かない。
        .record => try out.print("#<record {s}>", .{symbols.nameOf(x.asRecord().?.record_type.name)}),
        .record_type => try out.print("#<record-type {s}>", .{symbols.nameOf(x.asRecordType().?.name)}),
        // Why: 条件オブジェクトはハンドラに渡る値で、書かれうる。R7RS は外部表現を決めて
        // いないので、手続きと同じく `read` が受け付けない表記で、メッセージと irritant を
        // 書く。
        .condition => {
            const c = x.asCondition().?;
            try out.writeAll("#<condition ");
            try stack.append(scratch, .{ .irritants = c.irritants });
            try stack.append(scratch, .{ .value = c.message });
        },
    }
}

/// Writes the symbol named `name`, between vertical lines when `read` would not
/// read the name back as the same symbol (R7RS 6.13.3, 7.1.1).
/// `display` は縦棒を付けない(R7RS 6.13.3 の「Symbols are not escaped」)。縦棒を付けるのは、
/// リーダが縦棒なしで識別子として読まない名前(空白や区切り文字を含むもの、`.`、
/// 空の名前など。ASCII でない文字は、リーダが識別子に読めるものなら囲まない。判定は
/// `reader.readsAsIdentifier` と同じ関数である)と、数として読める名前(`1`、`+i`、`-inf.0`)である。縦棒の中では、`|` と `\`
/// の前に `\` を置き、制御文字を `\x` の16進のエスケープにする。リーダが読むエスケープ
/// (src/string_syntax.zig の `readIdentifier`)の中から選んでいる。
fn writeSymbol(out: *std.Io.Writer, name: []const u8, mode: Mode) std.Io.Writer.Error!void {
    if (mode == .display or !needsVerticalLines(name)) return out.writeAll(name);
    try out.writeByte('|');
    for (name) |byte| switch (byte) {
        '|', '\\' => {
            try out.writeByte('\\');
            try out.writeByte(byte);
        },
        0...0x1f, 0x7f => try out.print("\\x{x};", .{byte}),
        else => try out.writeByte(byte),
    };
    try out.writeByte('|');
}

/// Whether the symbol named `name` is written between vertical lines.
fn needsVerticalLines(name: []const u8) bool {
    if (name.len == 0) return true;
    if (!reader.readsAsIdentifier(name)) return true;
    if (num_syntax.scan(name, 10) != null) return true;
    // Why: `+nan.0abc` は R7RS 7.1.1 の <peculiar identifier> で、このリーダは縦棒なしでも同じ
    // シンボルとして読む(数として読む例外は `+i` `-i` と <infnan> そのものだけである)。それでも
    // 準拠スイート(tests/vendor/r7rs-tests.scm の Read syntax)は縦棒を求める。<infnan> の綴りで
    // 始まる名前を囲んでも、読み戻せば同じシンボルなので、スイートに合わせる。
    return startsWithInfnan(name);
}

/// Whether `name` begins with `+inf.0`, `-inf.0`, `+nan.0` or `-nan.0`, in any case.
fn startsWithInfnan(name: []const u8) bool {
    if (name.len < 6 or (name[0] != '+' and name[0] != '-')) return false;
    const rest = name[1..6];
    return std.ascii.eqlIgnoreCase(rest, "inf.0") or std.ascii.eqlIgnoreCase(rest, "nan.0");
}

test {
    std.testing.refAllDecls(@This());
}

/// A scratch space for the tests: symbols a, b, and pairs, all in one arena.
const Fixture = struct {
    arena: std.heap.ArenaAllocator,
    heap: Heap,

    fn init() Fixture {
        return .{ .arena = .init(std.testing.allocator), .heap = .init(std.heap.smp_allocator, .{}) };
    }

    fn deinit(self: *Fixture) void {
        self.heap.deinit();
        self.arena.deinit();
    }

    fn sym(self: *Fixture, name: []const u8) !Value {
        return .fromSymbol(try self.heap.intern(name));
    }

    fn cons(self: *Fixture, car: Value, cdr: Value) !Value {
        return self.heap.cons(car, cdr);
    }

    /// The list of `items`, ending in `tail`.
    fn list(self: *Fixture, items: []const Value, tail: Value) !Value {
        var result = tail;
        var i = items.len;
        while (i > 0) {
            i -= 1;
            result = try self.cons(items[i], result);
        }
        return result;
    }

    fn vector(self: *Fixture, items: []const Value) !Value {
        return .fromVector(try self.heap.createVector(items));
    }

    fn string(self: *Fixture, bytes: []const u8) !Value {
        return .fromString(try self.heap.createString(bytes));
    }

    fn printed(self: *Fixture, buf: []u8, v: Value, mode: Mode) ![]const u8 {
        var w: std.Io.Writer = .fixed(buf);
        try print(&w, &self.heap, &self.heap.symbols, v, mode);
        // 作業領域は、戻る前にすべて返している。
        try std.testing.expectEqual(0, self.heap.resident);
        return w.buffered();
    }

    fn written(self: *Fixture, buf: []u8, v: Value) ![]const u8 {
        return self.printed(buf, v, .write);
    }

    fn displayed(self: *Fixture, buf: []u8, v: Value) ![]const u8 {
        return self.printed(buf, v, .display);
    }
};

test "write prints an integer in decimal with its sign" {
    var f: Fixture = .init();
    defer f.deinit();
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("42", try f.written(&buf, .fromFixnum(42)));
    try std.testing.expectEqualStrings("-7", try f.written(&buf, .fromFixnum(-7)));
    try std.testing.expectEqualStrings("0", try f.written(&buf, .fromFixnum(0)));
}

test "write prints the extremes of a fixnum" {
    var f: Fixture = .init();
    defer f.deinit();
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("-9223372036854775808", try f.written(&buf, .fromFixnum(std.math.minInt(i64))));
    try std.testing.expectEqualStrings("9223372036854775807", try f.written(&buf, .fromFixnum(std.math.maxInt(i64))));
}

test "write and display hand the other numbers to src/num, also inside a list" {
    var f: Fixture = .init();
    defer f.deinit();
    var buf: [64]u8 = undefined;
    // 書式の本体は src/num/number.zig が持つ。ここでは、分岐が src/num の `write` に届くことだけを
    // 固定する。複素数も同じ分岐を通る。
    const l = try f.list(&.{ .fromFixnum(1), .fromFlonum(0.5) }, .empty_list_value);
    try std.testing.expectEqualStrings("(1 0.5)", try f.written(&buf, l));
    try std.testing.expectEqualStrings("(1 0.5)", try f.displayed(&buf, l));
    // ヒープの3種も同じ分岐を通る。
    var limbs = [_]value_mod.Limb{ 0, 1 };
    var b: value_mod.Bignum = .{ .limbs = &limbs, .positive = true };
    var r: value_mod.Ratnum = .{ .numerator = .fromFixnum(1), .denominator = .fromFixnum(3) };
    var c: value_mod.Compnum = .{ .real = .fromFixnum(1), .imag = .fromFixnum(2) };
    const heap_numbers = try f.list(&.{ .fromBignum(&b), .fromRatnum(&r), .fromCompnum(&c) }, .empty_list_value);
    try std.testing.expectEqualStrings("(18446744073709551616 1/3 1+2i)", try f.written(&buf, heap_numbers));
}

test "write shows an uninitialized marker that leaked" {
    var f: Fixture = .init();
    defer f.deinit();
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("#<uninitialized>", try f.written(&buf, .uninitialized_value));
}

test "write shows a condition by its message" {
    var f: Fixture = .init();
    defer f.deinit();
    var buf: [64]u8 = undefined;
    var bytes = "boom".*;
    var message: value_mod.String = .{ .bytes = &bytes, .is_ascii = true };
    var c: value_mod.Condition = .{ .kind = .@"error", .message = .fromString(&message), .irritants = .empty_list_value };
    try std.testing.expectEqualStrings("#<condition \"boom\">", try f.written(&buf, .fromCondition(&c)));
    try std.testing.expectEqualStrings("#<condition boom>", try f.displayed(&buf, .fromCondition(&c)));
}

test "write shows a condition with its message and its irritants" {
    var f: Fixture = .init();
    defer f.deinit();
    var buf: [64]u8 = undefined;
    var bytes = "bad".*;
    var message: value_mod.String = .{ .bytes = &bytes, .is_ascii = true };
    const irritants = try f.list(&.{ .fromFixnum(1), try f.string("two"), try f.list(&.{try f.sym("a")}, .empty_list_value) }, .empty_list_value);
    var c: value_mod.Condition = .{ .kind = .@"error", .message = .fromString(&message), .irritants = irritants };
    try std.testing.expectEqualStrings("#<condition \"bad\" 1 \"two\" (a)>", try f.written(&buf, .fromCondition(&c)));
    try std.testing.expectEqualStrings("#<condition bad 1 two (a)>", try f.displayed(&buf, .fromCondition(&c)));
    // 条件の中の条件も、同じ形で書く。
    var outer: value_mod.Condition = .{ .kind = .@"error", .message = .fromString(&message), .irritants = try f.list(&.{.fromCondition(&c)}, .empty_list_value) };
    try std.testing.expectEqualStrings("#<condition \"bad\" #<condition \"bad\" 1 \"two\" (a)>>", try f.written(&buf, .fromCondition(&outer)));
}

test "write shows an alias around the identifier inside it" {
    var f: Fixture = .init();
    defer f.deinit();
    var buf: [64]u8 = undefined;
    var inner: value_mod.Alias = .{ .inner = try f.sym("tmp"), .env = null, .mark = 0 };
    var outer: value_mod.Alias = .{ .inner = .fromAlias(&inner), .env = null, .mark = 1 };
    try std.testing.expectEqualStrings("#<alias tmp>", try f.written(&buf, .fromAlias(&inner)));
    try std.testing.expectEqualStrings("#<alias #<alias tmp>>", try f.written(&buf, .fromAlias(&outer)));
    const l = try f.list(&.{ .fromAlias(&inner), .fromFixnum(1) }, Value.empty_list_value);
    try std.testing.expectEqualStrings("(#<alias tmp> 1)", try f.written(&buf, l));
}

test "write and display show a record and its type by the name of the type, not the fields" {
    var f: Fixture = .init();
    defer f.deinit();
    var buf: [64]u8 = undefined;
    const name = (try f.sym("<point>")).asSymbol().?;
    var t: value_mod.RecordType = .{ .name = name, .field_count = 1 };
    var fields = [_]Value{try f.string("x")};
    var r: value_mod.Record = .{ .record_type = &t, .fields = &fields };
    try std.testing.expectEqualStrings("#<record-type <point>>", try f.written(&buf, .fromRecordType(&t)));
    try std.testing.expectEqualStrings("#<record <point>>", try f.written(&buf, .fromRecord(&r)));
    try std.testing.expectEqualStrings("#<record <point>>", try f.displayed(&buf, .fromRecord(&r)));
    // データの中でも同じである。
    const both = try f.list(&.{ .fromRecord(&r), .fromRecordType(&t) }, .empty_list_value);
    try std.testing.expectEqualStrings("(#<record <point>> #<record-type <point>>)", try f.written(&buf, both));
}

test "write and display show a continuation as #<continuation>" {
    var f: Fixture = .init();
    defer f.deinit();
    var buf: [64]u8 = undefined;
    var k: value_mod.Continuation = .{ .kont = null, .dyn = null };
    try std.testing.expectEqualStrings("#<continuation>", try f.written(&buf, .fromContinuation(&k)));
    try std.testing.expectEqualStrings("#<continuation>", try f.displayed(&buf, .fromContinuation(&k)));
    const l = try f.list(&.{ .fromContinuation(&k), .fromFixnum(1) }, .empty_list_value);
    try std.testing.expectEqualStrings("(#<continuation> 1)", try f.written(&buf, l));
}

test "write and display show a port as #<port>, whatever it holds" {
    var f: Fixture = .init();
    defer f.deinit();
    var buf: [64]u8 = undefined;
    var bytes = [_]u8{ 'h', 'i' };
    var p: value_mod.Port = .{ .direction = .input, .element = .textual, .backing = .{ .memory = .{ .bytes = &bytes, .len = 2 } } };
    try std.testing.expectEqualStrings("#<port>", try f.written(&buf, .fromPort(&p)));
    try std.testing.expectEqualStrings("#<port>", try f.displayed(&buf, .fromPort(&p)));
    const l = try f.list(&.{ .fromPort(&p), .fromFixnum(1) }, .empty_list_value);
    try std.testing.expectEqualStrings("(#<port> 1)", try f.written(&buf, l));
    // 向きも、種類も、開閉の状態も書かない。
    var q: value_mod.Port = .{ .direction = .output, .element = .binary, .open = false, .backing = .{ .memory = .{ .bytes = &bytes, .len = 0 } } };
    try std.testing.expectEqualStrings("#<port>", try f.written(&buf, .fromPort(&q)));
    try std.testing.expectEqualStrings("#<port>", try f.displayed(&buf, .fromPort(&q)));
}

test "write prints the unspecified value as #<unspecified>" {
    var f: Fixture = .init();
    defer f.deinit();
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("#<unspecified>", try f.written(&buf, .unspecified_value));
    try std.testing.expectEqualStrings("#<unspecified>", try f.displayed(&buf, .unspecified_value));
}

test "write prints the unspecified value inside data" {
    var f: Fixture = .init();
    defer f.deinit();
    var buf: [64]u8 = undefined;
    const u: Value = .unspecified_value;
    // 読み戻せない表記(`#<procedure>` と同じ種類)で、リストの要素・ペアの末尾・ベクタの要素になる。
    const l = try f.list(&.{ .fromFixnum(1), u, .fromFixnum(3) }, Value.empty_list_value);
    try std.testing.expectEqualStrings("(1 #<unspecified> 3)", try f.written(&buf, l));
    try std.testing.expectEqualStrings("(1 . #<unspecified>)", try f.written(&buf, try f.cons(.fromFixnum(1), u)));
    try std.testing.expectEqualStrings("(#<unspecified> . 2)", try f.written(&buf, try f.cons(u, .fromFixnum(2))));
    try std.testing.expectEqualStrings("#(#<unspecified> 1)", try f.written(&buf, try f.vector(&.{ u, .fromFixnum(1) })));
}

test "write prints booleans, the empty list and symbols" {
    var f: Fixture = .init();
    defer f.deinit();
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("#t", try f.written(&buf, .fromBool(true)));
    try std.testing.expectEqualStrings("#f", try f.written(&buf, .fromBool(false)));
    try std.testing.expectEqualStrings("()", try f.written(&buf, Value.empty_list_value));
    try std.testing.expectEqualStrings("list->vector", try f.written(&buf, try f.sym("list->vector")));
}

test "write prints a procedure in a form read rejects" {
    var f: Fixture = .init();
    defer f.deinit();
    var buf: [64]u8 = undefined;
    const body: value_mod.Node = .{ .constant = .unspecified_value };
    const lambda: value_mod.Lambda = .{ .arity = 0, .frame_size = 0, .body = &body };
    var closure: value_mod.Closure = .{ .lambda = &lambda, .env = null };
    try std.testing.expectEqualStrings("#<procedure>", try f.written(&buf, .fromClosure(&closure)));
    const prim: value_mod.Primitive = .{ .name = "plus", .min_args = 0, .max_args = null, .body = .{ .pure = struct {
        fn call(_: *const value_mod.Services, _: []const Value) value_mod.PrimitiveError!Value {
            return .unspecified_value;
        }
    }.call } };
    try std.testing.expectEqualStrings("#<procedure plus>", try f.written(&buf, .fromPrimitive(&prim)));
    // リストの中では、ほかと同じ 1 つの要素である。
    const l = try f.list(&.{ .fromPrimitive(&prim), .fromFixnum(1) }, Value.empty_list_value);
    try std.testing.expectEqualStrings("(#<procedure plus> 1)", try f.written(&buf, l));
}

test "write prints a list with one space between elements" {
    var f: Fixture = .init();
    defer f.deinit();
    var buf: [64]u8 = undefined;
    const l = try f.list(&.{ .fromFixnum(1), try f.sym("a"), .fromBool(false) }, Value.empty_list_value);
    try std.testing.expectEqualStrings("(1 a #f)", try f.written(&buf, l));
    const one = try f.list(&.{.fromFixnum(1)}, Value.empty_list_value);
    try std.testing.expectEqualStrings("(1)", try f.written(&buf, one));
}

test "write prints nested lists and the empty list inside one" {
    var f: Fixture = .init();
    defer f.deinit();
    var buf: [64]u8 = undefined;
    const inner = try f.list(&.{ try f.sym("b"), try f.sym("c") }, Value.empty_list_value);
    const l = try f.list(&.{ try f.sym("a"), inner, Value.empty_list_value }, Value.empty_list_value);
    try std.testing.expectEqualStrings("(a (b c) ())", try f.written(&buf, l));
}

test "write prints a list that does not end in the empty list with a dot" {
    var f: Fixture = .init();
    defer f.deinit();
    var buf: [64]u8 = undefined;
    const improper = try f.list(&.{ .fromFixnum(1), .fromFixnum(2) }, .fromFixnum(3));
    try std.testing.expectEqualStrings("(1 2 . 3)", try f.written(&buf, improper));
    const pair = try f.cons(.fromFixnum(1), .fromFixnum(2));
    try std.testing.expectEqualStrings("(1 . 2)", try f.written(&buf, pair));
    // 末尾は、閉じ括弧を必要とするリストであってもよい。
    const nested_tail = try f.cons(.fromFixnum(1), try f.cons(.fromFixnum(2), try f.sym("t")));
    try std.testing.expectEqualStrings("(1 2 . t)", try f.written(&buf, nested_tail));
}

test "write does not recurse on the depth of the data" {
    var f: Fixture = .init();
    defer f.deinit();
    // 先頭の要素に 200000 段ネストしたリストと、長さ 200000 のリスト。
    const depth = 200_000;
    var deep: Value = Value.empty_list_value;
    for (0..depth) |_| deep = try f.cons(deep, Value.empty_list_value);
    var long: Value = Value.empty_list_value;
    for (0..depth) |_| long = try f.cons(.fromFixnum(1), long);
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try print(&out.writer, &f.heap, &f.heap.symbols, deep, .write);
    try std.testing.expectEqual(depth * 2 + 2, out.written().len);
    out.clearRetainingCapacity();
    try print(&out.writer, &f.heap, &f.heap.symbols, long, .write);
    try std.testing.expectEqual(depth * 2 + 1, out.written().len);
}

test "write prints a bytevector as #u8 and the bytes in decimal" {
    var f: Fixture = .init();
    defer f.deinit();
    var buf: [128]u8 = undefined;
    const empty: Value = .fromBytevector(try f.heap.createBytevector(&.{}));
    try std.testing.expectEqualStrings("#u8()", try f.written(&buf, empty));
    try std.testing.expectEqualStrings("#u8(0)", try f.written(&buf, .fromBytevector(try f.heap.createBytevector(&.{0}))));
    const some: Value = .fromBytevector(try f.heap.createBytevector(&.{ 0, 10, 5, 255 }));
    try std.testing.expectEqualStrings("#u8(0 10 5 255)", try f.written(&buf, some));
    try std.testing.expectEqualStrings("#u8(0 10 5 255)", try f.displayed(&buf, some));
    // リストやベクタの中でも、前後の区切りは保たれる。
    const v = try f.vector(&.{ some, empty, .fromFixnum(1) });
    try std.testing.expectEqualStrings("#(#u8(0 10 5 255) #u8() 1)", try f.written(&buf, v));
    try std.testing.expectEqualStrings("(#u8() . #u8(0))", try f.written(&buf, try f.cons(empty, .fromBytevector(try f.heap.createBytevector(&.{0})))));
}

test "write prints a vector as # and a parenthesised list of its elements" {
    var f: Fixture = .init();
    defer f.deinit();
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("#()", try f.written(&buf, try f.vector(&.{})));
    try std.testing.expectEqualStrings("#(1)", try f.written(&buf, try f.vector(&.{.fromFixnum(1)})));
    const v = try f.vector(&.{ .fromFixnum(1), try f.sym("a"), .fromBool(true), Value.empty_list_value });
    try std.testing.expectEqualStrings("#(1 a #t ())", try f.written(&buf, v));
}

test "write prints vectors and pairs nested in one another" {
    var f: Fixture = .init();
    defer f.deinit();
    var buf: [64]u8 = undefined;
    const inner = try f.vector(&.{ .fromFixnum(2), .fromFixnum(3) });
    try std.testing.expectEqualStrings("#(1 #(2 3) #())", try f.written(&buf, try f.vector(&.{ .fromFixnum(1), inner, try f.vector(&.{}) })));
    // リストの中のベクタ、ペアの末尾のベクタ、ベクタの中のリストとペア。
    const in_list = try f.list(&.{ .fromFixnum(1), inner, .fromFixnum(4) }, Value.empty_list_value);
    try std.testing.expectEqualStrings("(1 #(2 3) 4)", try f.written(&buf, in_list));
    try std.testing.expectEqualStrings("(a . #(2 3))", try f.written(&buf, try f.cons(try f.sym("a"), inner)));
    const dotted = try f.cons(.fromFixnum(1), .fromFixnum(2));
    const lst = try f.list(&.{ .fromFixnum(3), .fromFixnum(4) }, .fromFixnum(5));
    try std.testing.expectEqualStrings("#((1 . 2) (3 4 . 5) (a))", try f.written(&buf, try f.vector(&.{ dotted, lst, try f.list(&.{try f.sym("a")}, Value.empty_list_value) })));
}

test "display prints what write prints for data without strings and characters" {
    var f: Fixture = .init();
    defer f.deinit();
    var wbuf: [64]u8 = undefined;
    var dbuf: [64]u8 = undefined;
    const inner = try f.vector(&.{ .fromFixnum(2), try f.sym("b") });
    const l = try f.list(&.{ .fromFixnum(1), inner, .fromBool(false) }, .fromFixnum(9));
    const v = try f.vector(&.{ l, inner, Value.empty_list_value });
    try std.testing.expectEqualStrings(try f.written(&wbuf, v), try f.displayed(&dbuf, v));
    try std.testing.expectEqualStrings("#((1 #(2 b) #f . 9) #(2 b) ())", try f.displayed(&dbuf, v));
}

test "write does not recurse on the depth of a vector" {
    var f: Fixture = .init();
    defer f.deinit();
    // 唯一の要素に 200000 段ネストしたベクタと、長さ 200000 のベクタ。
    const depth = 200_000;
    var deep: Value = try f.vector(&.{});
    for (0..depth) |_| deep = try f.vector(&.{deep});
    const items = try f.arena.allocator().alloc(Value, depth);
    @memset(items, .fromFixnum(1));
    const long = try f.vector(items);
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try print(&out.writer, &f.heap, &f.heap.symbols, deep, .write);
    // 各段は `#(` と `)` で、一番内側は `#()` である。
    try std.testing.expectEqual((depth + 1) * 3, out.written().len);
    out.clearRetainingCapacity();
    try print(&out.writer, &f.heap, &f.heap.symbols, long, .write);
    try std.testing.expectEqual(depth * 2 + 2, out.written().len);
}

test "write and display differ on a string and a character at the top" {
    var f: Fixture = .init();
    defer f.deinit();
    var buf: [64]u8 = undefined;
    const s = try f.string("a\"b");
    try std.testing.expectEqualStrings("\"a\\\"b\"", try f.written(&buf, s));
    try std.testing.expectEqualStrings("a\"b", try f.displayed(&buf, s));
    const c: Value = .fromCharacter('b');
    try std.testing.expectEqualStrings("#\\b", try f.written(&buf, c));
    try std.testing.expectEqualStrings("b", try f.displayed(&buf, c));
    const space: Value = .fromCharacter(' ');
    try std.testing.expectEqualStrings("#\\space", try f.written(&buf, space));
    try std.testing.expectEqualStrings(" ", try f.displayed(&buf, space));
}

test "write and display differ inside a list and a dotted pair" {
    var f: Fixture = .init();
    defer f.deinit();
    var buf: [64]u8 = undefined;
    const l = try f.list(&.{ try f.string("a"), .fromCharacter('b'), try f.sym("c") }, Value.empty_list_value);
    try std.testing.expectEqualStrings("(\"a\" #\\b c)", try f.written(&buf, l));
    try std.testing.expectEqualStrings("(a b c)", try f.displayed(&buf, l));
    // ドットの後の要素も、同じモードで書く。
    const pair = try f.cons(try f.string("a"), .fromCharacter('b'));
    try std.testing.expectEqualStrings("(\"a\" . #\\b)", try f.written(&buf, pair));
    try std.testing.expectEqualStrings("(a . b)", try f.displayed(&buf, pair));
    const improper = try f.list(&.{ try f.string("x"), .fromCharacter('y') }, try f.string("z"));
    try std.testing.expectEqualStrings("(\"x\" #\\y . \"z\")", try f.written(&buf, improper));
    try std.testing.expectEqualStrings("(x y . z)", try f.displayed(&buf, improper));
}

test "write and display differ inside a vector" {
    var f: Fixture = .init();
    defer f.deinit();
    var buf: [64]u8 = undefined;
    const v = try f.vector(&.{ try f.string("a"), .fromCharacter('b'), .fromFixnum(1) });
    try std.testing.expectEqualStrings("#(\"a\" #\\b 1)", try f.written(&buf, v));
    try std.testing.expectEqualStrings("#(a b 1)", try f.displayed(&buf, v));
    // 空文字列は、何も書かない要素である。
    const empties = try f.vector(&.{ try f.string(""), try f.string("") });
    try std.testing.expectEqualStrings("#(\"\" \"\")", try f.written(&buf, empties));
    try std.testing.expectEqualStrings("#( )", try f.displayed(&buf, empties));
    try std.testing.expectEqualStrings("#(\"\")", try f.written(&buf, try f.vector(&.{try f.string("")})));
    try std.testing.expectEqualStrings("#()", try f.displayed(&buf, try f.vector(&.{try f.string("")})));
}

test "write and display differ at every level of nested data" {
    var f: Fixture = .init();
    defer f.deinit();
    var buf: [64]u8 = undefined;
    // (#("a" (#\b . "c")) "d")
    const inner_pair = try f.cons(.fromCharacter('b'), try f.string("c"));
    const inner_list = try f.list(&.{inner_pair}, Value.empty_list_value);
    const vec = try f.vector(&.{ try f.string("a"), inner_list });
    const outer = try f.list(&.{ vec, try f.string("d") }, Value.empty_list_value);
    try std.testing.expectEqualStrings("(#(\"a\" ((#\\b . \"c\"))) \"d\")", try f.written(&buf, outer));
    try std.testing.expectEqualStrings("(#(a ((b . c))) d)", try f.displayed(&buf, outer));
    // 文字列のベクタのベクタと、文字のリストのリスト。
    const vv = try f.vector(&.{ try f.vector(&.{try f.string("p")}), try f.vector(&.{ .fromCharacter('q'), try f.string("r") }) });
    try std.testing.expectEqualStrings("#(#(\"p\") #(#\\q \"r\"))", try f.written(&buf, vv));
    try std.testing.expectEqualStrings("#(#(p) #(q r))", try f.displayed(&buf, vv));
}

test "write escapes a string and a character in data as read would need" {
    var f: Fixture = .init();
    defer f.deinit();
    var buf: [64]u8 = undefined;
    const v = try f.vector(&.{ try f.string("a\nb\\"), .fromCharacter('\n'), .fromCharacter(0x3bb), try f.string("\u{3bb}") });
    try std.testing.expectEqualStrings("#(\"a\\nb\\\\\" #\\newline #\\\u{3bb} \"\u{3bb}\")", try f.written(&buf, v));
    try std.testing.expectEqualStrings("#(a\nb\\ \n \u{3bb} \u{3bb})", try f.displayed(&buf, v));
}

test "write, display and write-shared put a label on a list whose tail comes back to it" {
    var f: Fixture = .init();
    defer f.deinit();
    var buf: [64]u8 = undefined;
    // (1 2 . #0#)
    const x = try f.list(&.{ .fromFixnum(1), .fromFixnum(2) }, .empty_list_value);
    x.asPair().?.cdr.asPair().?.cdr = x;
    try std.testing.expectEqualStrings("#0=(1 2 . #0#)", try f.written(&buf, x));
    try std.testing.expectEqualStrings("#0=(1 2 . #0#)", try f.displayed(&buf, x));
    try std.testing.expectEqualStrings("#0=(1 2 . #0#)", try f.printed(&buf, x, .shared));
    // 循環が car を通っても同じである。
    const y = try f.list(&.{try f.sym("a")}, .empty_list_value);
    y.asPair().?.car = y;
    try std.testing.expectEqualStrings("#0=(#0#)", try f.written(&buf, y));
}

test "write puts a label on a pair in the middle of a list that the list comes back to" {
    var f: Fixture = .init();
    defer f.deinit();
    var buf: [64]u8 = undefined;
    // (a b c) の c のペアの cdr を、b のペアに向ける。ラベルは頭にしか置けないので、
    // b のペアからは `.` のあとに書く。
    const x = try f.list(&.{ try f.sym("a"), try f.sym("b"), try f.sym("c") }, .empty_list_value);
    const b = x.asPair().?.cdr;
    b.asPair().?.cdr.asPair().?.cdr = b;
    try std.testing.expectEqualStrings("(a . #0=(b c . #0#))", try f.written(&buf, x));
}

test "write puts a label on a vector that holds itself" {
    var f: Fixture = .init();
    defer f.deinit();
    var buf: [64]u8 = undefined;
    const v = try f.vector(&.{ .fromFixnum(1), .fromBool(false) });
    v.asVector().?.items[1] = v;
    try std.testing.expectEqualStrings("#0=#(1 #0#)", try f.written(&buf, v));
    try std.testing.expectEqualStrings("#0=#(1 #0#)", try f.displayed(&buf, v));
}

test "write numbers the labels in the order it writes them, and writes a labeled object once" {
    var f: Fixture = .init();
    defer f.deinit();
    var buf: [64]u8 = undefined;
    const c1 = try f.cons(.fromFixnum(1), .empty_list_value);
    c1.asPair().?.cdr = c1;
    const c2 = try f.cons(.fromFixnum(2), .empty_list_value);
    c2.asPair().?.cdr = c2;
    try std.testing.expectEqualStrings("(#0=(1 . #0#) #1=(2 . #1#))", try f.written(&buf, try f.list(&.{ c1, c2 }, .empty_list_value)));
    // 同じ循環が2回現れたら、2回目はラベルだけを書く。
    try std.testing.expectEqualStrings("(#0=(1 . #0#) #0#)", try f.written(&buf, try f.list(&.{ c1, c1 }, .empty_list_value)));
}

test "only write-shared puts labels on what appears twice without a cycle" {
    var f: Fixture = .init();
    defer f.deinit();
    var buf: [64]u8 = undefined;
    const s = try f.list(&.{.fromFixnum(1)}, .empty_list_value);
    const v = try f.vector(&.{ try f.sym("v"), s });
    const both = try f.list(&.{ s, v, v }, .empty_list_value);
    try std.testing.expectEqualStrings("((1) #(v (1)) #(v (1)))", try f.written(&buf, both));
    try std.testing.expectEqualStrings("((1) #(v (1)) #(v (1)))", try f.displayed(&buf, both));
    try std.testing.expectEqualStrings("((1) #(v (1)) #(v (1)))", try f.printed(&buf, both, .simple));
    try std.testing.expectEqualStrings("(#0=(1) #1=#(v #0#) #1#)", try f.printed(&buf, both, .shared));
}

test "write-shared numbers more labels than fit in a byte" {
    var f: Fixture = .init();
    defer f.deinit();
    // (#0=(0) #0# #1=(1) #1# ... #299=(299) #299#)
    const n = 300;
    var items: [2 * n]Value = undefined;
    for (0..n) |i| {
        const s = try f.cons(.fromFixnum(@intCast(i)), .empty_list_value);
        items[2 * i] = s;
        items[2 * i + 1] = s;
    }
    const l = try f.list(&items, .empty_list_value);
    var expected: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer expected.deinit();
    try expected.writer.writeByte('(');
    for (0..n) |i| {
        if (i != 0) try expected.writer.writeByte(' ');
        try expected.writer.print("#{d}=({d}) #{d}#", .{ i, i, i });
    }
    try expected.writer.writeByte(')');
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try print(&out.writer, &f.heap, &f.heap.symbols, l, .shared);
    try std.testing.expectEqualStrings(expected.written(), out.written());
}

test "write-simple writes no label, even for a list that comes back to itself" {
    var f: Fixture = .init();
    defer f.deinit();
    var buf: [16]u8 = undefined;
    const x = try f.cons(.fromFixnum(1), .empty_list_value);
    x.asPair().?.cdr = x;
    // 止まらないので、書き出す先が満杯になったところで切れる。
    var w: std.Io.Writer = .fixed(&buf);
    try std.testing.expectError(error.WriteFailed, print(&w, &f.heap, &f.heap.symbols, x, .simple));
    try std.testing.expectEqualStrings("(1 1 1 1 1 1 1 1", w.buffered());
}

test "write stops on a condition whose irritants hold the condition" {
    var f: Fixture = .init();
    defer f.deinit();
    var buf: [64]u8 = undefined;
    var bytes = "boom".*;
    var message: value_mod.String = .{ .bytes = &bytes, .is_ascii = true };
    const irritants = try f.list(&.{.fromFixnum(1)}, .empty_list_value);
    var c: value_mod.Condition = .{ .kind = .@"error", .message = .fromString(&message), .irritants = irritants };
    irritants.asPair().?.car = .fromCondition(&c);
    try std.testing.expectEqualStrings("#0=#<condition \"boom\" #0#>", try f.written(&buf, .fromCondition(&c)));
}

test "write stops on a condition whose list of irritants comes back to itself" {
    var f: Fixture = .init();
    defer f.deinit();
    var buf: [64]u8 = undefined;
    var bytes = "boom".*;
    var message: value_mod.String = .{ .bytes = &bytes, .is_ascii = true };
    // irritant のリストの cdr を、リストの頭に戻す。
    const irritants = try f.list(&.{ .fromFixnum(1), .fromFixnum(2) }, .empty_list_value);
    irritants.asPair().?.cdr.asPair().?.cdr = irritants;
    var c: value_mod.Condition = .{ .kind = .@"error", .message = .fromString(&message), .irritants = irritants };
    try std.testing.expectEqualStrings("#<condition \"boom\" . #0=(1 2 . #0#)>", try f.written(&buf, .fromCondition(&c)));
    try std.testing.expectEqualStrings("#<condition boom . #0=(1 2 . #0#)>", try f.displayed(&buf, .fromCondition(&c)));
    // 途中のペアに戻るときは、そこまでの irritant を書いてから `.` を置く。
    const more = try f.list(&.{ .fromFixnum(1), .fromFixnum(2), .fromFixnum(3) }, .empty_list_value);
    const second = more.asPair().?.cdr;
    second.asPair().?.cdr.asPair().?.cdr = second;
    var d: value_mod.Condition = .{ .kind = .@"error", .message = .fromString(&message), .irritants = more };
    try std.testing.expectEqualStrings("#<condition \"boom\" 1 . #0=(2 3 . #0#)>", try f.written(&buf, .fromCondition(&d)));
}

test "print fails with HeapLimit, and not WriteFailed, when writing a number takes work that does not fit" {
    var f: Fixture = .init();
    defer f.deinit();
    var buf: [64]u8 = undefined;
    // 複素数の書式は、作業領域に書いてから写す(src/num/number.zig)。
    var c: value_mod.Compnum = .{ .real = .fromFixnum(1), .imag = .fromFixnum(2) };
    f.heap.options.limit = f.heap.held() + 8;
    var w: std.Io.Writer = .fixed(&buf);
    try std.testing.expectError(error.HeapLimit, print(&w, &f.heap, &f.heap.symbols, .fromCompnum(&c), .write));
    try std.testing.expectEqual(0, f.heap.resident);
}

test "write puts a symbol between vertical lines when read would not read its name back" {
    var f: Fixture = .init();
    defer f.deinit();
    var buf: [64]u8 = undefined;
    const cases = [_]struct { name: []const u8, written: []const u8 }{
        .{ .name = "", .written = "||" },
        .{ .name = "a b", .written = "|a b|" },
        // ASCII でない文字は、リーダが識別子に読めるなら縦棒なしで書く。読めない綴りは囲む。
        .{ .name = "\u{3bb}", .written = "\u{3bb}" },
        .{ .name = "\u{4e8c}\u{500d}", .written = "\u{4e8c}\u{500d}" },
        .{ .name = "+\u{3bb}", .written = "+\u{3bb}" },
        .{ .name = "a\u{3bb}1", .written = "a\u{3bb}1" },
        .{ .name = "\u{3bb} x", .written = "|\u{3bb} x|" },
        .{ .name = "\u{3bb}\u{3000}", .written = "|\u{3bb}\u{3000}|" },
        .{ .name = "\u{3bb}(", .written = "|\u{3bb}(|" },
        .{ .name = "\u{661}", .written = "|\u{661}|" },
        .{ .name = "\xff\xfe", .written = "|\xff\xfe|" },
        .{ .name = ".", .written = "|.|" },
        .{ .name = "1+", .written = "|1+|" },
        .{ .name = "(", .written = "|(|" },
        .{ .name = "a|b\\c", .written = "|a\\|b\\\\c|" },
        .{ .name = "a\x07\nb\x7f", .written = "|a\\x7;\\xa;b\\x7f;|" },
        // 数として読める名前。
        .{ .name = "1", .written = "|1|" },
        .{ .name = "-2.5", .written = "|-2.5|" },
        .{ .name = "+i", .written = "|+i|" },
        .{ .name = "-i", .written = "|-i|" },
        .{ .name = "-inf.0", .written = "|-inf.0|" },
        .{ .name = "#x10", .written = "|#x10|" },
        // <infnan> の綴りで始まる名前(準拠スイートに合わせる)。
        .{ .name = "+NaN.0abc", .written = "|+NaN.0abc|" },
        .{ .name = "-inf.0x", .written = "|-inf.0x|" },
        .{ .name = "+INF.0x", .written = "|+INF.0x|" },
        .{ .name = "+inf", .written = "+inf" },
        .{ .name = "+nan.", .written = "+nan." },
        // 縦棒の要らない名前。<peculiar identifier> も含む。
        .{ .name = "list->vector", .written = "list->vector" },
        .{ .name = "+", .written = "+" },
        .{ .name = "-", .written = "-" },
        .{ .name = "...", .written = "..." },
        .{ .name = "->x", .written = "->x" },
        .{ .name = "+a", .written = "+a" },
        .{ .name = ".a", .written = ".a" },
    };
    for (cases) |case| {
        const s = try f.sym(case.name);
        try std.testing.expectEqualStrings(case.written, try f.written(&buf, s));
        try std.testing.expectEqualStrings(case.written, try f.printed(&buf, s, .shared));
        try std.testing.expectEqualStrings(case.written, try f.printed(&buf, s, .simple));
        // display は縦棒を付けない。
        try std.testing.expectEqualStrings(case.name, try f.displayed(&buf, s));
    }
    // データの中でも同じである。
    const l = try f.list(&.{ try f.sym("a b"), try f.sym("c") }, .empty_list_value);
    try std.testing.expectEqualStrings("(|a b| c)", try f.written(&buf, l));
    try std.testing.expectEqualStrings("(a b c)", try f.displayed(&buf, l));
}

test "write-shared and write-simple write strings and characters as write does" {
    var f: Fixture = .init();
    defer f.deinit();
    var buf: [64]u8 = undefined;
    const l = try f.list(&.{ try f.string("a"), .fromCharacter('b') }, .empty_list_value);
    try std.testing.expectEqualStrings("(\"a\" #\\b)", try f.printed(&buf, l, .shared));
    try std.testing.expectEqualStrings("(\"a\" #\\b)", try f.printed(&buf, l, .simple));
}

test "print fails with HeapLimit when its table does not fit in the heap, and gives back what it took" {
    var f: Fixture = .init();
    defer f.deinit();
    var buf: [256]u8 = undefined;
    var items: [32]Value = undefined;
    for (&items, 0..) |*item, i| item.* = .fromFixnum(@intCast(i));
    const l = try f.list(&items, .empty_list_value);
    const s = try f.string("s");
    const a = try f.sym("a");
    f.heap.options.limit = f.heap.held() + 16;
    f.heap.external_refused = true;
    var w: std.Io.Writer = .fixed(&buf);
    try std.testing.expectError(error.HeapLimit, print(&w, &f.heap, &f.heap.symbols, l, .write));
    try std.testing.expectEqual(0, f.heap.resident);
    // 呼び出し側の印は戻す。
    try std.testing.expect(f.heap.external_refused);
    // ラベルを付けない形も、作業スタックを上限に数える。
    try std.testing.expectError(error.HeapLimit, print(&w, &f.heap, &f.heap.symbols, l, .simple));
    // アトムは表も作業スタックも使わない。上限の際でも書け、呼び出し側の印も戻す。
    f.heap.options.limit = f.heap.held();
    w = .fixed(&buf);
    try print(&w, &f.heap, &f.heap.symbols, .fromFixnum(7), .write);
    try print(&w, &f.heap, &f.heap.symbols, s, .write);
    try print(&w, &f.heap, &f.heap.symbols, .fromCharacter('c'), .write);
    try print(&w, &f.heap, &f.heap.symbols, a, .write);
    try std.testing.expectEqualStrings("7\"s\"#\\ca", w.buffered());
    try std.testing.expect(f.heap.external_refused);
}

test "print tells the host's memory running out from the limit, whatever its caller had marked" {
    var failing: std.testing.FailingAllocator = .init(std.testing.allocator, .{});
    var heap: Heap = .init(failing.allocator(), .{});
    defer heap.deinit();
    const l = try heap.cons(.fromFixnum(1), .empty_list_value);
    // 次の確保から、ホストが断る。上限は断っていない。
    failing.fail_index = failing.alloc_index;
    heap.external_refused = true;
    var buf: [16]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try std.testing.expectError(error.OutOfMemory, print(&w, &heap, &heap.symbols, l, .write));
    try std.testing.expect(heap.external_refused);
}

test "write labels the pair it reaches first by the car before the cdr, and a vector's items in order" {
    var f: Fixture = .init();
    defer f.deinit();
    var buf: [64]u8 = undefined;
    // a = ((a)) のように、a の car が b で、b の car が a である。
    const a = try f.list(&.{.fromBool(false)}, .empty_list_value);
    const b = try f.list(&.{a}, .empty_list_value);
    a.asPair().?.car = b;
    try std.testing.expectEqualStrings("(#0=((#0#)) #0#)", try f.written(&buf, try f.cons(a, b)));
    try std.testing.expectEqualStrings("#(#0=((#0#)) (#0#))", try f.written(&buf, try f.vector(&.{ a, b })));
}
