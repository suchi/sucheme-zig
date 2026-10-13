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

const std = @import("std");
const value_mod = @import("value.zig");
const Value = value_mod.Value;
const symbol = @import("symbol.zig");
const Heap = @import("heap.zig").Heap;
const char_syntax = @import("char_syntax.zig");
const string_syntax = @import("string_syntax.zig");

pub const Error = std.Io.Writer.Error || error{OutOfMemory};

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

/// Which of the two external forms of data to write (R7RS 6.13.3).
pub const Mode = enum { write, display };

/// Writes `v` as `write` would (R7RS 6.13.3).
/// シンボル名は `symbols` から取る。`scratch` は、まだ書いていないものを積むスタックを
/// 持ち、`write` は、戻る前にそこから取ったものを解放する。
///
/// シンボルは名前だけで書く。リーダが作る名前に `|...|` の形は要らない。ほかのシンボルを
/// 作る手続きは、それを必要とするスライスで入れる。
pub fn write(out: *std.Io.Writer, scratch: std.mem.Allocator, symbols: *const symbol.Table, v: Value) Error!void {
    return emit(out, scratch, symbols, v, .write);
}

/// Writes `v` as `display` would (R7RS 6.13.3): the same as `write`, except
/// that a string is its characters and a character is itself, also inside the
/// pairs and vectors that hold them.
pub fn display(out: *std.Io.Writer, scratch: std.mem.Allocator, symbols: *const symbol.Table, v: Value) Error!void {
    return emit(out, scratch, symbols, v, .display);
}

fn emit(out: *std.Io.Writer, scratch: std.mem.Allocator, symbols: *const symbol.Table, v: Value, mode: Mode) Error!void {
    var stack: std.ArrayList(Item) = .empty;
    defer stack.deinit(scratch);
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
        .value => |x| switch (x.kind()) {
            .fixnum => try out.print("{d}", .{x.asFixnum().?}),
            .boolean => try out.writeAll(if (x.isTrue()) "#t" else "#f"),
            .empty_list => try out.writeAll("()"),
            .symbol => try out.writeAll(symbols.nameOf(x.asSymbol().?)),
            .character => try char_syntax.write(out, mode, x.asCharacter().?),
            .string => try string_syntax.write(out, mode, x.asString().?.bytes),
            .vector => {
                try out.writeAll("#(");
                try stack.append(scratch, .{ .elements = .{ .items = x.asVector().?.items, .next = 0 } });
            },
            // Why: R7RS は手続きの外部表現を決めていない。多くの処理系は `read` が
            // 受け付けない表記で書き、ここでもそうする。
            .closure => try out.writeAll("#<procedure>"),
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
        },
        .irritants => |rest| if (rest.asPair()) |p| {
            try out.writeByte(' ');
            try stack.append(scratch, .{ .irritants = p.cdr });
            try stack.append(scratch, .{ .value = p.car });
        } else {
            try out.writeByte('>');
        },
        .rest => |tail| switch (tail.kind()) {
            .empty_list => try out.writeByte(')'),
            .pair => {
                const p = tail.asPair().?;
                try out.writeByte(' ');
                try stack.append(scratch, .{ .rest = p.cdr });
                try stack.append(scratch, .{ .value = p.car });
            },
            else => {
                try out.writeAll(" . ");
                try stack.append(scratch, .{ .text = ")" });
                try stack.append(scratch, .{ .value = tail });
            },
        },
    };
}

test {
    std.testing.refAllDecls(@This());
}

/// A scratch space for the tests: symbols a, b, and pairs, all in one arena.
const Fixture = struct {
    arena: std.heap.ArenaAllocator,
    heap: Heap,
    symbols: symbol.Table = .{},

    fn init() Fixture {
        return .{ .arena = .init(std.testing.allocator), .heap = .init(std.heap.smp_allocator, .{}) };
    }

    fn deinit(self: *Fixture) void {
        self.heap.deinit();
        self.arena.deinit();
    }

    fn sym(self: *Fixture, name: []const u8) !Value {
        return .fromSymbol(try self.symbols.intern(self.arena.allocator(), name));
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

    fn written(self: *Fixture, buf: []u8, v: Value) ![]const u8 {
        var w: std.Io.Writer = .fixed(buf);
        try write(&w, std.testing.allocator, &self.symbols, v);
        return w.buffered();
    }

    fn displayed(self: *Fixture, buf: []u8, v: Value) ![]const u8 {
        var w: std.Io.Writer = .fixed(buf);
        try display(&w, std.testing.allocator, &self.symbols, v);
        return w.buffered();
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
    try write(&out.writer, std.testing.allocator, &f.symbols, deep);
    try std.testing.expectEqual(depth * 2 + 2, out.written().len);
    out.clearRetainingCapacity();
    try write(&out.writer, std.testing.allocator, &f.symbols, long);
    try std.testing.expectEqual(depth * 2 + 1, out.written().len);
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
    try write(&out.writer, std.testing.allocator, &f.symbols, deep);
    // 各段は `#(` と `)` で、一番内側は `#()` である。
    try std.testing.expectEqual((depth + 1) * 3, out.written().len);
    out.clearRetainingCapacity();
    try write(&out.writer, std.testing.allocator, &f.symbols, long);
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
