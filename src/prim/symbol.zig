//! Symbol primitives (R7RS 6.5): `symbol?`, `symbol=?`, `symbol->string` and
//! `string->symbol`.
//!
//! シンボル表は弱い表である(docs/design/runtime.md の「インターン表を弱い表にする」)。
//! `string->symbol` が作った ID は、返した値がレジスタにある間と、値を保持するものが
//! GC に伝える間、生きる。プリミティブの本体は機械のステップの中で走り、GC は走らない
//! ので、プリミティブの中で ID を一時ルートに載せる必要はない。

const std = @import("std");
const value = @import("../value.zig");
const Value = value.Value;
const Primitive = value.Primitive;
const Services = value.Services;
const PrimitiveError = value.PrimitiveError;

pub const Error = PrimitiveError;

pub const primitives = [_]Primitive{
    .{ .name = "symbol?", .min_args = 1, .max_args = 1, .body = .{ .pure = &isSymbol } },
    .{ .name = "symbol=?", .min_args = 1, .max_args = null, .body = .{ .pure = &symbolEquals } },
    .{ .name = "symbol->string", .min_args = 1, .max_args = 1, .body = .{ .pure = &symbolToString } },
    .{ .name = "string->symbol", .min_args = 1, .max_args = 1, .body = .{ .pure = &stringToSymbol } },
};

/// `(symbol? obj)`: true of symbols only (R7RS 6.5).
fn isSymbol(_: *const Services, args: []const Value) Error!Value {
    return .fromBool(args[0].kind() == .symbol);
}

/// `(symbol=? symbol1 symbol2 symbol3 ...)`: whether all the arguments are the same
/// symbol (R7RS 6.5).
///
/// 引数が1つなら真、なしならエラー(機械が表の下限で報告する)。すべての引数がシンボルである
/// ことを、最初に違いが見つかったあとも検査する。エラーが値に左右されないようにするためで、
/// 整数の比較と同じである。
fn symbolEquals(_: *const Services, args: []const Value) Error!Value {
    for (args) |a| _ = a.asSymbol() orelse return error.WrongType;
    var holds = true;
    for (args[0 .. args.len - 1], args[1..]) |a, b| {
        if (a.asSymbol().? != b.asSymbol().?) holds = false;
    }
    return .fromBool(holds);
}

/// `(symbol->string symbol)`: the name of the symbol, as a new string (R7RS 6.5).
///
/// Why: 名前は表のものを共有せず、複製を返す。共有すると、文字列を変更する手続きが、表の
/// 名前を壊して、`(eq? 'abc (string->symbol "abc"))` が成り立たなくなる(docs/design/runtime.md)。
/// R7RS 3.4 は、この文字列を不変としている。不変の印は、それを検査する文字列の変更の手続き
/// と同じスライスで足す(段階3の 3d)。複製の確保は、ヒープの上限に計上される。
fn symbolToString(services: *const Services, args: []const Value) Error!Value {
    const id = args[0].asSymbol() orelse return error.WrongType;
    return .fromString(try services.heap.createString(services.heap.symbols.nameOf(id)));
}

/// `(string->symbol string)`: the symbol whose name is the string (R7RS 6.5).
///
/// 名前が表にあれば、その ID である。なければ新しい ID を作り、名前の複製とともに表に載せる。
/// 載せる量は名前の長さに比例し、ヒープの上限に計上される。収まらなければ上限超過になる。
/// 文字列は妥当な UTF-8 なので(ADR-0008)、シンボルの名前もそうである。
fn stringToSymbol(services: *const Services, args: []const Value) Error!Value {
    const s = args[0].asString() orelse return error.WrongType;
    return .fromSymbol(try services.heap.intern(s.bytes));
}

test {
    std.testing.refAllDecls(@This());
}

const test_support = @import("test_support.zig");
const heap_mod = @import("../heap.zig");

fn callWith(arg: Value) !bool {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    const v = try f.call(&primitives, "symbol?", &.{arg});
    try std.testing.expectEqual(.boolean, v.kind());
    return v.isTrue();
}

test "the primitives take the numbers of arguments the language gives them" {
    const Arity = struct { name: []const u8, min: u8, max: ?u8 };
    const expected = [_]Arity{
        .{ .name = "symbol?", .min = 1, .max = 1 },
        .{ .name = "symbol=?", .min = 1, .max = null },
        .{ .name = "symbol->string", .min = 1, .max = 1 },
        .{ .name = "string->symbol", .min = 1, .max = 1 },
    };
    try std.testing.expectEqual(expected.len, primitives.len);
    for (expected, primitives) |e, p| {
        try std.testing.expectEqualStrings(e.name, p.name);
        try std.testing.expectEqual(e.min, p.min_args);
        try std.testing.expectEqual(e.max, p.max_args);
    }
}

test "symbol? is true of symbols and of nothing else" {
    try std.testing.expect(try callWith(.fromSymbol(@fromBackingInt(@intCast(0)))));
    try std.testing.expect(try callWith(.fromSymbol(@fromBackingInt(@intCast(7)))));
    try std.testing.expect(!try callWith(.fromFixnum(0)));
    try std.testing.expect(!try callWith(.fromBool(false)));
    try std.testing.expect(!try callWith(.fromBool(true)));
    try std.testing.expect(!try callWith(.empty_list_value));
    try std.testing.expect(!try callWith(.fromCharacter('a')));
    try std.testing.expect(!try callWith(.unspecified_value));
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    // 名前が同じでも、文字列はシンボルではない。
    try std.testing.expect(!try callWith(.fromString(try f.heap.createString("a"))));
    try std.testing.expect(!try callWith(.fromVector(try f.heap.createVector(&.{.fromSymbol(@fromBackingInt(@intCast(0)))}))));
    try std.testing.expect(!try callWith(try f.heap.cons(.fromSymbol(@fromBackingInt(@intCast(0))), .empty_list_value)));
}

/// A heap and the `Services` over it, and the symbols and strings the tests use.
fn symbolOf(f: *test_support.Fixture, name: []const u8) !Value {
    return .fromSymbol(try f.heap.intern(name));
}

fn stringOf(f: *test_support.Fixture, text: []const u8) !Value {
    return .fromString(try f.heap.createString(text));
}

test "string->symbol gives the one symbol of a name, and a different symbol to a different name" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    const first = try f.call(&primitives, "string->symbol", &.{try stringOf(&f, "abc")});
    const second = try f.call(&primitives, "string->symbol", &.{try stringOf(&f, "abc")});
    try std.testing.expectEqual(value.Kind.symbol, first.kind());
    try std.testing.expectEqual(first.asSymbol().?, second.asSymbol().?);
    // リーダが読んだシンボルとも同じである。
    try std.testing.expectEqual(first.asSymbol().?, (try symbolOf(&f, "abc")).asSymbol().?);
    for ([_][]const u8{ "abd", "ab", "ABC", "abc ", "" }) |other| {
        const v = try f.call(&primitives, "string->symbol", &.{try stringOf(&f, other)});
        try std.testing.expect(v.asSymbol().? != first.asSymbol().?);
        try std.testing.expectEqualStrings(other, f.heap.symbols.nameOf(v.asSymbol().?));
    }
    // 空の名前も、ASCII の外の名前も、シンボルになる。
    const wide = try f.call(&primitives, "string->symbol", &.{try stringOf(&f, "あいう")});
    try std.testing.expectEqualStrings("あいう", f.heap.symbols.nameOf(wide.asSymbol().?));
}

test "string->symbol reports an argument that is not a string" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    try std.testing.expectError(error.WrongType, f.call(&primitives, "string->symbol", &.{try symbolOf(&f, "abc")}));
    try std.testing.expectError(error.WrongType, f.call(&primitives, "string->symbol", &.{.fromCharacter('a')}));
    try std.testing.expectError(error.WrongType, f.call(&primitives, "string->symbol", &.{.empty_list_value}));
}

test "symbol->string gives a new string of the name, and changing it does not change the symbol" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    const sym = try symbolOf(&f, "abc");
    const first = try f.call(&primitives, "symbol->string", &.{sym});
    const second = try f.call(&primitives, "symbol->string", &.{sym});
    try std.testing.expectEqual(value.Kind.string, first.kind());
    try std.testing.expectEqualStrings("abc", first.asString().?.bytes);
    try std.testing.expect(first.asString().? != second.asString().?);
    try std.testing.expect(first.asString().?.bytes.ptr != f.heap.symbols.nameOf(sym.asSymbol().?).ptr);
    // 名前を共有していれば、ここで表の名前が壊れる。
    first.asString().?.bytes[0] = 'z';
    try std.testing.expectEqualStrings("abc", f.heap.symbols.nameOf(sym.asSymbol().?));
    try std.testing.expectEqualStrings("abc", second.asString().?.bytes);
    try std.testing.expectEqual(sym.asSymbol().?, (try f.call(&primitives, "string->symbol", &.{try stringOf(&f, "abc")})).asSymbol().?);
    const empty = try f.call(&primitives, "symbol->string", &.{try symbolOf(&f, "")});
    try std.testing.expectEqual(0, empty.asString().?.bytes.len);
}

test "symbol->string reports an argument that is not a symbol" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    try std.testing.expectError(error.WrongType, f.call(&primitives, "symbol->string", &.{try stringOf(&f, "abc")}));
    try std.testing.expectError(error.WrongType, f.call(&primitives, "symbol->string", &.{.fromFixnum(1)}));
}

test "symbol=? holds when every argument is the same symbol" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    const a = try symbolOf(&f, "a");
    const b = try symbolOf(&f, "b");
    const a_again = try f.call(&primitives, "string->symbol", &.{try stringOf(&f, "a")});
    try std.testing.expect((try f.call(&primitives, "symbol=?", &.{ a, a_again })).isTrue());
    try std.testing.expect((try f.call(&primitives, "symbol=?", &.{ a, a_again, a })).isTrue());
    try std.testing.expect(!(try f.call(&primitives, "symbol=?", &.{ a, b })).isTrue());
    try std.testing.expect(!(try f.call(&primitives, "symbol=?", &.{ a, a, b })).isTrue());
    try std.testing.expect(!(try f.call(&primitives, "symbol=?", &.{ b, a, a })).isTrue());
    try std.testing.expect(!(try f.call(&primitives, "symbol=?", &.{ a, b, a })).isTrue());
    // 1つの引数は、比べる相手が無いので真である。
    try std.testing.expect((try f.call(&primitives, "symbol=?", &.{a})).isTrue());
    // 結果は真偽値である。
    try std.testing.expectEqual(value.Kind.boolean, (try f.call(&primitives, "symbol=?", &.{ a, b })).kind());
}

test "symbol=? checks every argument for being a symbol, after the first pair that differs too" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    const a = try symbolOf(&f, "a");
    const b = try symbolOf(&f, "b");
    try std.testing.expectError(error.WrongType, f.call(&primitives, "symbol=?", &.{.fromFixnum(1)}));
    try std.testing.expectError(error.WrongType, f.call(&primitives, "symbol=?", &.{ a, try stringOf(&f, "a") }));
    try std.testing.expectError(error.WrongType, f.call(&primitives, "symbol=?", &.{ try stringOf(&f, "a"), a }));
    try std.testing.expectError(error.WrongType, f.call(&primitives, "symbol=?", &.{ a, b, .fromFixnum(1) }));
    try std.testing.expectError(error.WrongType, f.call(&primitives, "symbol=?", &.{ a, a, .fromFixnum(1) }));
}

test "a name too large for the limit is refused as the limit, and the table and the heap stay as they were" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    f.heap.deinit();
    f.heap = .init(std.testing.allocator, .{ .limit = 5000 });
    const long_text: [1500]u8 = @splat('n');
    const other_text: [900]u8 = @splat('m');
    const long = try stringOf(&f, &long_text);
    const other = try stringOf(&f, &other_text);
    const small = try stringOf(&f, "ok");
    // 1つ目の名前は、複製を足しても収まる。
    const symbol_long = try f.call(&primitives, "string->symbol", &.{long});
    const held = f.heap.held();
    // 2つ目は、文字列は収まったが、名前の複製を足すと収まらない。
    try std.testing.expectError(error.HeapLimit, f.call(&primitives, "string->symbol", &.{other}));
    try std.testing.expect(f.heap.symbols.lookup(&other_text) == null);
    try std.testing.expectEqual(held, f.heap.held());
    // 断られたあとも、小さな名前は通る。
    _ = try f.call(&primitives, "string->symbol", &.{small});
    try std.testing.expect(f.heap.symbols.lookup("ok") != null);
    // 同じ名前をもう一度頼むのは、確保が要らないので、上限の近くでも通る。
    try std.testing.expectEqual(symbol_long.asSymbol().?, (try f.call(&primitives, "string->symbol", &.{long})).asSymbol().?);
}

test "the copy that symbol->string makes is held to the limit" {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    f.heap.deinit();
    f.heap = .init(std.testing.allocator, .{ .limit = 4096 });
    const text: [900]u8 = @splat('n');
    const sym = try f.call(&primitives, "string->symbol", &.{try stringOf(&f, &text)});
    // 文字列と名前の複製が使った残りに、複製が何個入るか。
    const room = (f.heap.options.limit - f.heap.held()) / (heap_mod.cellBytes(value.String) + text.len);
    try std.testing.expect(room >= 1);
    for (0..room) |_| _ = try f.call(&primitives, "symbol->string", &.{sym});
    try std.testing.expectError(error.HeapLimit, f.call(&primitives, "symbol->string", &.{sym}));
}
