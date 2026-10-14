//! The libraries a program defines, and how they are imported (R7RS 5.2, 5.6,
//! docs/design/frontend.md, the library system).
//!
//! `(sucheme core)` は Zig が登録する(`Context.core`)。ここが扱うのは、`define-library` で
//! 定義されるライブラリである。ライブラリはヒープのオブジェクト(`value.Library`)で、
//! 登録表(`Registry`)が指す。最上位の束縛の表は、ハッシュ表なのでヒープの外にあり、
//! 登録表が持つ。

const std = @import("std");
const value_mod = @import("../value.zig");
const Value = value_mod.Value;
const Library = value_mod.Library;
const TableId = value_mod.TableId;
const context = @import("../context.zig");
const Context = context.Context;
const env_mod = @import("../env.zig");
const heap_mod = @import("../heap.zig");
const syntax_env = @import("env.zig");
const expand = @import("expand.zig");
const printer = @import("../printer.zig");

pub const Error = context.Error;

/// The libraries that have been defined, or whose definition is in progress.
pub const Registry = struct {
    /// Every library whose definition began and has not failed, oldest first.
    list: std.ArrayList(*Library) = .empty,
    /// The tables of the libraries' top levels, indexed by `Library.table`.
    /// 表はアリーナにあり、定義に失敗したライブラリの表も残る(空にする)。表の番号を
    /// 再利用しないので、失敗したライブラリを指す古い識別子が、別のライブラリの表を引くことは
    /// ない。
    tables: std.ArrayList(*env_mod.Global) = .empty,
    /// The `define-library` forms being processed, innermost last.
    /// 本体の処理は機械を走らせるので、その間に GC が走る。処理中の宣言は、このリストが
    /// 指す形式の中にあるので、これがルートになる(ADR-0035 の読み込みの作業リスト)。
    loading: std.ArrayList(Value) = .empty,

    /// Tells the collector of the libraries, the tables of their top levels and
    /// the forms being processed.
    pub fn mark(self: *const Registry, marker: *heap_mod.Marker) void {
        for (self.list.items) |lib| marker.object(Library, lib);
        for (self.tables.items) |table| table.mark(marker);
        for (self.loading.items) |form| marker.value(form);
    }

    /// The table of the top level of `lib`.
    pub fn tableOf(self: *const Registry, lib: *const Library) *env_mod.Global {
        return self.tables.items[@backingInt(lib.table)];
    }

    /// The library named `name`, or null when none has been defined.
    pub fn find(self: *const Registry, name: Value) ?*Library {
        for (self.list.items) |lib| {
            if (sameName(lib.name, name)) return lib;
        }
        return null;
    }

    /// Starts the definition of a library named `name`: a library in the state
    /// loading, with an empty top level and the environment of its body.
    /// 展開の途中と同じく、この中では GC が走らないので、作ったオブジェクトを登録表に
    /// 載せるまでルートにしなくてよい。
    pub fn begin(self: *Registry, ctx: *Context, name: Value) Error!*Library {
        const table = try ctx.persist.create(env_mod.Global);
        table.* = .{};
        const id: TableId = @fromBackingInt(@intCast(self.tables.items.len));
        const lib = try ctx.create(Library, .{ .name = name, .state = .loading, .exports = null, .root = null, .table = id });
        lib.root = try ctx.create(value_mod.SyntacticEnv, .{ .parent = null, .rib_depth = 0, .bindings = null, .library = lib });
        try self.tables.append(ctx.persist, table);
        try self.list.append(ctx.persist, lib);
        return lib;
    }

    /// Takes a library whose definition failed out of the registry.
    /// 表の中身も手放す。ライブラリが作ったセルとマクロは、ほかから指されなければ
    /// 回収される。
    pub fn abandon(self: *Registry, lib: *Library) void {
        self.tableOf(lib).* = .{};
        for (self.list.items, 0..) |item, i| {
            if (item == lib) {
                _ = self.list.orderedRemove(i);
                break;
            }
        }
    }
};

/// What the import sets bring: names, each with what it means, in the order the
/// library exports them.
pub const Names = std.StringArrayHashMapUnmanaged(value_mod.Denotation);

/// The modifiers of an import set (R7RS 5.2).
const Modifier = enum { only, except, prefix, rename };

/// Which top-level form of the REPL a datum is.
pub const TopLevelForm = enum { define_library, import };

/// Which form a datum read at the top level is, if it is one of those that
/// this file handles: `(define-library ...)` and `(import ...)`.
/// Why: R7RS の `(scheme base)` はこれらをエクスポートしない。束縛された名前ではなく、
/// 最上位の形式として、先頭の綴りで見分ける。
pub fn topLevelForm(ctx: *const Context, form: Value) ?TopLevelForm {
    const head = (form.asPair() orelse return null).car.asSymbol() orelse return null;
    const name = ctx.symbols.nameOf(head);
    if (std.mem.eql(u8, name, "import")) return .import;
    if (std.mem.eql(u8, name, "define-library")) return .define_library;
    return null;
}

/// The elements of the list `form`, or an error naming `what` when it is not a
/// proper list.
fn itemsOf(ctx: *Context, scratch: std.mem.Allocator, form: Value, comptime what: []const u8) Error![]const Value {
    var items: std.ArrayList(Value) = .empty;
    var rest = form;
    while (rest.asPair()) |p| : (rest = p.cdr) try items.append(scratch, p.car);
    if (rest.kind() != .empty_list) return ctx.raise("bad " ++ what ++ ": expected a proper list", .{});
    return items.items;
}

/// The text of the library name `name`, as `write` shows it.
fn nameText(ctx: *Context, scratch: std.mem.Allocator, name: Value) Error![]const u8 {
    var out: std.Io.Writer.Allocating = .init(scratch);
    printer.write(&out.writer, scratch, &ctx.symbols, name) catch return error.OutOfMemory;
    return out.written();
}

/// Checks that `name` is a library name: a list of at least one identifier or
/// non-negative integer (R7RS 5.6.1).
fn checkName(ctx: *Context, name: Value) Error!void {
    const bad = "bad library name: a name is a non-empty list of identifiers and non-negative integers";
    if (name.asPair() == null) return ctx.raise(bad, .{});
    var rest = name;
    while (rest.asPair()) |p| : (rest = p.cdr) {
        if (p.car.asSymbol() != null) continue;
        if (p.car.asFixnum()) |n| if (n >= 0) continue;
        return ctx.raise(bad, .{});
    }
    if (rest.kind() != .empty_list) return ctx.raise(bad, .{});
}

/// Whether `name` is `(sucheme core)`.
fn isCoreName(ctx: *const Context, name: Value) bool {
    var rest = name;
    for ([_][]const u8{ "sucheme", "core" }) |expected| {
        const p = rest.asPair() orelse return false;
        const sym = p.car.asSymbol() orelse return false;
        if (!std.mem.eql(u8, ctx.symbols.nameOf(sym), expected)) return false;
        rest = p.cdr;
    }
    return rest.kind() == .empty_list;
}

/// Evaluates the import set `spec` (R7RS 5.2): what it brings, by name.
/// 入れ子の修飾子の深さに比例して進むので、再帰せず、外側から内側へ修飾子を積み、
/// 内側から順に適用する。エクスポートの名前の文字列は、ヒープの文字列とシンボル表の
/// 名前を指す。GC が走るまで有効である。
pub fn evalImportSet(ctx: *Context, scratch: std.mem.Allocator, spec: Value) Error!Names {
    const Pending = struct { kind: Modifier, arguments: Value };
    var pending: std.ArrayList(Pending) = .empty;
    var current = spec;
    while (current.asPair()) |p| {
        const head = p.car.asSymbol() orelse break;
        const kind = std.meta.stringToEnum(Modifier, ctx.symbols.nameOf(head)) orelse break;
        const inner = p.cdr.asPair() orelse
            return ctx.raise("bad import: {s} needs an import set", .{@tagName(kind)});
        try pending.append(scratch, .{ .kind = kind, .arguments = inner.cdr });
        current = inner.car;
    }
    var names = try exportsOf(ctx, scratch, current);
    while (pending.pop()) |m| names = try modify(ctx, scratch, m.kind, m.arguments, names);
    return names;
}

/// What the library named `name` exports.
fn exportsOf(ctx: *Context, scratch: std.mem.Allocator, name: Value) Error!Names {
    try checkName(ctx, name);
    var names: Names = .empty;
    if (isCoreName(ctx, name)) {
        var it = ctx.core.entries.keyIterator();
        while (it.next()) |id| {
            const d = (ctx.core.get(&ctx.heap, id.*) catch |e| return ctx.heapFailure(e)).?;
            try names.put(scratch, ctx.symbols.nameOf(id.*), d);
        }
        return names;
    }
    const lib = ctx.libraries.find(name) orelse
        return ctx.raise("unknown library: {s}", .{try nameText(ctx, scratch, name)});
    if (lib.state == .loading)
        return ctx.raise("bad import: circular import of the library {s}", .{try nameText(ctx, scratch, name)});
    var export_it = lib.exports;
    while (export_it) |e| : (export_it = e.next) try names.put(scratch, e.name.bytes, e.denotation);
    return names;
}

/// The name an identifier of an import set is written as.
fn identifierName(ctx: *Context, id: Value, comptime what: []const u8) Error![]const u8 {
    const symbol = id.asSymbol() orelse
        return ctx.raise("bad import: " ++ what ++ " expects identifiers", .{});
    return ctx.symbols.nameOf(symbol);
}

/// Applies one modifier of an import set to what it modifies.
fn modify(ctx: *Context, scratch: std.mem.Allocator, kind: Modifier, arguments: Value, names: Names) Error!Names {
    const items = try itemsOf(ctx, scratch, arguments, "import");
    var result: Names = .empty;
    switch (kind) {
        .only => for (items) |item| {
            const name = try identifierName(ctx, item, "only");
            const d = names.get(name) orelse
                return ctx.raise("bad import: {s} is not exported by the import set", .{name});
            try result.put(scratch, name, d);
        },
        .except => {
            result = try names.clone(scratch);
            for (items) |item| {
                const name = try identifierName(ctx, item, "except");
                if (!result.orderedRemove(name))
                    return ctx.raise("bad import: {s} is not exported by the import set", .{name});
            }
        },
        .prefix => {
            if (items.len != 1) return ctx.raise("bad import: prefix expects one identifier", .{});
            const prefix = try identifierName(ctx, items[0], "prefix");
            var it = names.iterator();
            while (it.next()) |entry| {
                const name = try std.mem.concat(scratch, u8, &.{ prefix, entry.key_ptr.* });
                try result.put(scratch, name, entry.value_ptr.*);
            }
        },
        .rename => {
            // 改名は同時に行う。`(rename s (a b) (b a))` は a と b を入れ替える。
            var renames: std.StringHashMapUnmanaged([]const u8) = .empty;
            for (items) |item| {
                const pair = try itemsOf(ctx, scratch, item, "import");
                if (pair.len != 2) return ctx.raise("bad import: rename expects (from to) pairs", .{});
                const from = try identifierName(ctx, pair[0], "rename");
                const to = try identifierName(ctx, pair[1], "rename");
                if (!names.contains(from))
                    return ctx.raise("bad import: {s} is not exported by the import set", .{from});
                try renames.put(scratch, from, to);
            }
            var it = names.iterator();
            while (it.next()) |entry| {
                const name = renames.get(entry.key_ptr.*) orelse entry.key_ptr.*;
                const added = try result.getOrPut(scratch, name);
                if (added.found_existing)
                    return ctx.raise("bad import: {s} is the name of more than one identifier", .{name});
                added.value_ptr.* = entry.value_ptr.*;
            }
        },
    }
    return result;
}

/// Binds `names` in `table`, as imported bindings.
/// REPL では、インポートは同じ名前の今の束縛を置き換える(R7RS 5.2)。ライブラリの本体では、
/// 同じ識別子を別の束縛で2回インポートすることと、本体が先に定義した名前をインポートすること
/// は誤りである。インポートより前に参照だけされた名前は、そのセルが `displaced_cells` に残り、
/// 本体の終わりに未束縛として報告される(`finish`)。
pub fn bindImports(ctx: *Context, table: *env_mod.Global, names: Names, mode: expand.Mode) Error!void {
    var it = names.iterator();
    while (it.next()) |entry| {
        const name = entry.key_ptr.*;
        const id = try ctx.symbols.intern(ctx.persist, name);
        if (mode == .library) if (table.lookup(id)) |existing| {
            if (existing.imported) {
                if (syntax_env.sameDenotation(existing.denotation, entry.value_ptr.*)) continue;
                return ctx.raise("bad import: {s} is imported twice with different bindings", .{name});
            }
            switch (existing.denotation) {
                .global => |cell| if (cell.value.kind() == .uninitialized) {} else return ctx.raise(
                    "bad import: {s} is defined in this library, and cannot be imported",
                    .{name},
                ),
                else => return ctx.raise("bad import: {s} is defined in this library, and cannot be imported", .{name}),
            }
        };
        try table.importBinding(ctx.persist, id, entry.value_ptr.*);
    }
}

/// `(import <import set> ...)` at the REPL (R7RS 5.2): imports what the sets bring
/// into the REPL's top level.
/// 先にすべての集合を評価し、それから束縛する。集合の誤りで、一部だけがインポート
/// されることはない。
pub fn importIntoRepl(ctx: *Context, scratch: std.mem.Allocator, form: Value) Error!void {
    const items = try itemsOf(ctx, scratch, form, "import");
    if (items.len < 2) return ctx.raise("bad import: expected (import <import set> ...)", .{});
    const sets = try scratch.alloc(Names, items.len - 1);
    for (sets, items[1..]) |*set, spec| set.* = try evalImportSet(ctx, scratch, spec);
    for (sets) |set| try bindImports(ctx, &ctx.globals, set, .repl);
    ctx.globals.commitShadows();
}

/// Whether two library names are the same: lists of the same length whose
/// elements are the same symbols and the same integers.
pub fn sameName(a: Value, b: Value) bool {
    var x = a;
    var y = b;
    while (true) {
        const px = x.asPair() orelse return x.kind() == .empty_list and y.kind() == .empty_list;
        const py = y.asPair() orelse return false;
        if (!sameComponent(px.car, py.car)) return false;
        x = px.cdr;
        y = py.cdr;
    }
}

/// Whether two elements of library names are the same.
fn sameComponent(a: Value, b: Value) bool {
    if (a.asSymbol()) |s| return if (b.asSymbol()) |t| s == t else false;
    if (a.asFixnum()) |n| return if (b.asFixnum()) |m| n == m else false;
    return false;
}

test {
    std.testing.refAllDecls(@This());
}

const reader = @import("../reader.zig");
const core = @import("../core.zig");

/// What the tests share: a context, a library and the means to read and expand
/// forms in it.
const Fixture = struct {
    arena: std.heap.ArenaAllocator,
    ctx: Context,

    fn init(self: *Fixture) !void {
        self.arena = .init(std.testing.allocator);
        errdefer self.arena.deinit();
        self.ctx = try .init(self.arena.allocator(), std.testing.allocator);
    }

    fn deinit(self: *Fixture) void {
        self.ctx.deinit();
        self.arena.deinit();
    }

    fn read(self: *Fixture, src: []const u8) !Value {
        var r: reader.Reader = .init(src);
        const sink: reader.Sink = .{ .alloc = self.ctx.persist, .heap = &self.ctx.heap, .symbols = &self.ctx.symbols };
        return (try r.next(self.arena.allocator(), sink)).?;
    }

    /// A new library named by the datum `name`, which imports `names` from core.
    fn library(self: *Fixture, name: []const u8, names: []const []const u8) !*Library {
        const lib = try self.ctx.libraries.begin(&self.ctx, try self.read(name));
        const table = self.ctx.libraries.tableOf(lib);
        for (names) |n| {
            const id = try self.ctx.symbols.intern(self.ctx.persist, n);
            const d = (try self.ctx.core.get(&self.ctx.heap, id)).?;
            try table.importBinding(self.ctx.persist, id, d);
        }
        table.commitShadows();
        return lib;
    }

    fn expandIn(self: *Fixture, lib: *Library, src: []const u8) ![]const u8 {
        const target: expand.Target = .{ .table = self.ctx.libraries.tableOf(lib), .root = lib.root, .mode = .library };
        const node = try expand.expandIn(&self.ctx, self.arena.allocator(), try self.read(src), target, .{});
        return self.text(node);
    }

    fn expandRepl(self: *Fixture, src: []const u8) ![]const u8 {
        return self.text(try expand.expand(&self.ctx, self.arena.allocator(), try self.read(src)));
    }

    fn text(self: *Fixture, node: *const value_mod.Node) ![]const u8 {
        var out: std.Io.Writer.Allocating = .init(self.arena.allocator());
        try core.write(&out.writer, self.arena.allocator(), &self.ctx.symbols, node);
        return out.written();
    }

    fn expectFailsIn(self: *Fixture, lib: *Library, src: []const u8, message: []const u8) !void {
        try std.testing.expectError(error.Raised, self.expandIn(lib, src));
        try std.testing.expectEqualStrings(message, self.ctx.diagnostic());
    }
};

test "the name of a library is the same as another's when the elements are the same symbols and integers" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const a = try f.read("(foo bar 1)");
    try std.testing.expect(sameName(a, a));
    try std.testing.expect(sameName(a, try f.read("(foo bar 1)")));
    try std.testing.expect(!sameName(a, try f.read("(foo bar 2)")));
    try std.testing.expect(!sameName(a, try f.read("(foo bar)")));
    try std.testing.expect(!sameName(try f.read("(foo bar)"), a));
    try std.testing.expect(!sameName(a, try f.read("(foo bar baz)")));
    // 整数と、同じ綴りのシンボルは別である。
    try std.testing.expect(!sameName(try f.read("(foo 1)"), try f.read("(foo one)")));
    try std.testing.expect(!sameName(try f.read("(foo)"), try f.read("(Foo)")));
}

test "a library that begins is registered in the state loading, with the environment of its body" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const lib = try f.library("(t a)", &.{});
    try std.testing.expectEqual(Library.State.loading, lib.state);
    try std.testing.expectEqual(lib, f.ctx.libraries.find(try f.read("(t a)")).?);
    try std.testing.expectEqual(null, f.ctx.libraries.find(try f.read("(t b)")));
    // 本体の環境は、このライブラリを指す根である。
    try std.testing.expectEqual(lib, lib.root.?.library.?);
    try std.testing.expectEqual(null, lib.root.?.parent);
    try std.testing.expectEqual(0, lib.root.?.rib_depth);
    // ライブラリごとに、最上位の表は別である。
    const other = try f.library("(t b)", &.{});
    try std.testing.expect(f.ctx.libraries.tableOf(lib) != f.ctx.libraries.tableOf(other));
    try std.testing.expect(f.ctx.libraries.tableOf(lib) != &f.ctx.globals);
}

test "a library whose definition failed leaves the registry, and is collected" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const keep = try f.library("(t keep)", &.{});
    const lost = try f.library("(t lost)", &.{});
    f.ctx.collectIdle();
    // ライブラリと本体の環境が、2つずつ残る。
    try std.testing.expectEqual(2, f.ctx.heap.countOf(Library));
    try std.testing.expectEqual(2, f.ctx.heap.countOf(value_mod.SyntacticEnv));
    const lost_table = f.ctx.libraries.tableOf(lost);
    f.ctx.libraries.abandon(lost);
    try std.testing.expectEqual(null, f.ctx.libraries.find(try f.read("(t lost)")));
    try std.testing.expectEqual(keep, f.ctx.libraries.find(try f.read("(t keep)")).?);
    f.ctx.collectIdle();
    try std.testing.expectEqual(1, f.ctx.heap.countOf(Library));
    try std.testing.expectEqual(1, f.ctx.heap.countOf(value_mod.SyntacticEnv));
    // 同じ名前で、もう一度始められる。
    const again = try f.library("(t lost)", &.{});
    try std.testing.expect(f.ctx.libraries.tableOf(again) != lost_table);
}

test "the forms being processed and the bindings of a library survive a collection" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const lib = try f.library("(t a)", &.{ "define", "quote" });
    _ = try f.expandIn(lib, "(define x '(1 2))");
    const table = f.ctx.libraries.tableOf(lib);
    const x = f.ctx.symbols.index.get("x").?;
    table.lookup(x).?.denotation.global.value = try f.ctx.heap.cons(.fromFixnum(1), .empty_list_value);
    const form = try f.read("(define-library (t a) (export))");
    try f.ctx.libraries.loading.append(f.ctx.persist, form);
    _ = try f.ctx.heap.cons(.fromFixnum(9), .empty_list_value);
    f.ctx.collectIdle();
    // 作業中の形式は、読んだペアのまま残る。セルの値も残る。
    var out: std.Io.Writer.Allocating = .init(f.arena.allocator());
    try @import("../printer.zig").write(&out.writer, f.arena.allocator(), &f.ctx.symbols, form);
    try std.testing.expectEqualStrings("(define-library (t a) (export))", out.written());
    try std.testing.expectEqual(1, table.lookup(x).?.denotation.global.value.asPair().?.car.asFixnum().?);
    // 作業中の形式を手放すと、それは回収される。
    f.ctx.libraries.loading.clearRetainingCapacity();
    const before = f.ctx.heap.countOf(value_mod.Pair);
    f.ctx.collectIdle();
    try std.testing.expect(f.ctx.heap.countOf(value_mod.Pair) < before);
}

test "a form of a library body is expanded for the library's own top level, not the REPL's" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const lib = try f.library("(t a)", &.{ "define", "lambda", "quote" });
    try std.testing.expectEqualStrings("(define-global x (const 1))", try f.expandIn(lib, "(define x 1)"));
    // REPL の最上位は、その名前を束縛していない。
    try std.testing.expect(!f.ctx.globals.isBound(f.ctx.symbols.index.get("x").?));
    try std.testing.expectEqualStrings("(global x)", try f.expandRepl("x"));
    try std.testing.expect(f.ctx.globals.lookup(f.ctx.symbols.index.get("x").?).?.denotation.global !=
        f.ctx.libraries.tableOf(lib).lookup(f.ctx.symbols.index.get("x").?).?.denotation.global);
    // ライブラリの本体は、インポートしたものだけを見る。`if` はインポートしていない。
    try std.testing.expectEqualStrings("(call (global if) (const 1) (const 2))", try f.expandIn(lib, "(if 1 2)"));
    // 局所の束縛は、最上位の下で、ふつうに働く。
    try std.testing.expectEqualStrings("(lambda 1 1 (local a 0 0))", try f.expandIn(lib, "(lambda (a) a)"));
}

test "a definition or an assignment of an imported binding is a syntax error in a library body, and shadows at the REPL" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const lib = try f.library("(t a)", &.{ "define", "define-syntax", "syntax-rules", "set!", "car", "if" });
    try f.expectFailsIn(lib, "(define car 1)", "bad define: car is an imported binding and cannot be redefined");
    try f.expectFailsIn(lib, "(define (car x) x)", "bad define: car is an imported binding and cannot be redefined");
    try f.expectFailsIn(lib, "(set! car 1)", "bad set!: car is an imported binding and cannot be assigned");
    try f.expectFailsIn(lib, "(define-syntax car (syntax-rules () ((_) 1)))", "bad define-syntax: car is an imported binding and cannot be redefined");
    try f.expectFailsIn(lib, "(define if 1)", "bad define: if is an imported binding and cannot be redefined");
    try f.expectFailsIn(lib, "(set! if 1)", "bad set!: if is a syntactic keyword and cannot be assigned");
    // 失敗した展開は、何も束縛しない。
    try std.testing.expect(f.ctx.libraries.tableOf(lib).lookup(f.ctx.symbols.index.get("car").?).?.imported);
    // ライブラリ自身の変数は、定義し直しても代入してもよい。
    try std.testing.expectEqualStrings("(define-global x (if (const #t) (const #t)))", try f.expandIn(lib, "(define x (if #t #t))"));
    try std.testing.expectEqualStrings("(set-global x (const 2))", try f.expandIn(lib, "(set! x 2)"));
}

test "a macro defined in a library reads its ellipsis and underscore by the library's top level, whatever the REPL does to those names" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const lib = try f.library("(t a)", &.{ "define-syntax", "syntax-rules", "quote", "...", "_" });
    try std.testing.expectEqualStrings("(const #<unspecified>)", try f.expandIn(lib, "(define-syntax m (syntax-rules () ((_ _ x ...) '(x ...))))"));
    // REPL が同じ綴りを変数にしても、ライブラリのマクロの読み方は変わらない。
    _ = try f.expandRepl("(define ... 1)");
    _ = try f.expandRepl("(define _ 2)");
    const m = f.ctx.libraries.tableOf(lib).lookup(f.ctx.symbols.index.get("m").?).?.denotation;
    const use = try f.read("(m 0 1 2)");
    var work: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer work.deinit();
    const output = try @import("rules.zig").transform(&f.ctx, &work, m.macro, use, null);
    var out: std.Io.Writer.Allocating = .init(f.arena.allocator());
    try @import("../printer.zig").write(&out.writer, f.arena.allocator(), &f.ctx.symbols, output);
    // テンプレートの `quote` は別名なので、`(quote (1 2))` の形で出る。
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "(1 2)") != null);
}

test "a macro of a library refers to the library's own variable, where the REPL has a variable of the same name" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const lib = try f.library("(t a)", &.{ "define", "define-syntax", "syntax-rules", "lambda" });
    _ = try f.expandIn(lib, "(define helper 1)");
    _ = try f.expandIn(lib, "(define-syntax use-helper (syntax-rules () ((_) helper)))");
    _ = try f.expandRepl("(define helper 2)");
    // REPL へ持ち出したマクロの適用は、ライブラリのセルを指す(参照透明性)。
    const macro = f.ctx.libraries.tableOf(lib).lookup(f.ctx.symbols.index.get("use-helper").?).?.denotation.macro;
    const helper = f.ctx.symbols.index.get("helper").?;
    const own = f.ctx.libraries.tableOf(lib).lookup(helper).?.denotation.global;
    const repl = f.ctx.globals.lookup(helper).?.denotation.global;
    try std.testing.expect(own != repl);
    // マクロを REPL の最上位に束縛して、使う。
    try f.ctx.globals.defineSyntax(f.ctx.persist, f.ctx.symbols.index.get("use-helper").?, macro);
    f.ctx.globals.commitShadows();
    const node = try expand.expand(&f.ctx, f.arena.allocator(), try f.read("(use-helper)"));
    try std.testing.expectEqual(own, node.global_ref);
    // REPL の同じ名前は、REPL 自身のセルである。
    const direct = try expand.expand(&f.ctx, f.arena.allocator(), try f.read("helper"));
    try std.testing.expectEqual(repl, direct.global_ref);
}

test "set! through a macro of another library assigns that library's variable and never shadows" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const lib = try f.library("(t a)", &.{ "define", "define-syntax", "syntax-rules", "set!", "car" });
    _ = try f.expandIn(lib, "(define counter 0)");
    _ = try f.expandIn(lib, "(define-syntax bump! (syntax-rules () ((_) (set! counter 1))))");
    _ = try f.expandIn(lib, "(define-syntax clobber! (syntax-rules () ((_) (set! car 1))))");
    const table = f.ctx.libraries.tableOf(lib);
    const id = struct {
        fn of(fx: *Fixture, name: []const u8) @import("../symbol.zig").SymbolId {
            return fx.ctx.symbols.index.get(name).?;
        }
    }.of;
    try f.ctx.globals.defineSyntax(f.ctx.persist, id(&f, "bump!"), table.lookup(id(&f, "bump!")).?.denotation.macro);
    try f.ctx.globals.defineSyntax(f.ctx.persist, id(&f, "clobber!"), table.lookup(id(&f, "clobber!")).?.denotation.macro);
    f.ctx.globals.commitShadows();
    const node = try expand.expand(&f.ctx, f.arena.allocator(), try f.read("(bump!)"));
    try std.testing.expectEqual(table.lookup(id(&f, "counter")).?.denotation.global, node.global_set.cell);
    // REPL の最上位には、`counter` の新しい束縛ができていない。
    try std.testing.expectEqual(null, f.ctx.globals.lookup(id(&f, "counter")));
    // ライブラリがインポートした束縛への代入は、マクロを通しても誤りである。
    try std.testing.expectError(error.Raised, expand.expand(&f.ctx, f.arena.allocator(), try f.read("(clobber!)")));
    try std.testing.expectEqualStrings("bad set!: car is an imported binding and cannot be assigned", f.ctx.diagnostic());
}

fn expectNames(f: *Fixture, spec: []const u8, expected: []const []const u8) !void {
    const names = try evalImportSet(&f.ctx, f.arena.allocator(), try f.read(spec));
    try std.testing.expectEqual(expected.len, names.count());
    for (expected) |name| try std.testing.expect(names.contains(name));
}

test "the forms of an import set bring the names they say" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try expectNames(&f, "(only (sucheme core) car cdr)", &.{ "car", "cdr" });
    try expectNames(&f, "(only (sucheme core))", &.{});
    try expectNames(&f, "(prefix (only (sucheme core) car) a-)", &.{"a-car"});
    try expectNames(&f, "(rename (only (sucheme core) car cdr) (car kar))", &.{ "kar", "cdr" });
    try expectNames(&f, "(rename (only (sucheme core) car cdr) (car cdr) (cdr car))", &.{ "car", "cdr" });
    // 入れ子は内側から適用する。
    try expectNames(&f, "(only (rename (only (sucheme core) car cdr) (car kar)) kar)", &.{"kar"});
    // `except` は、除いた名前以外のすべてを残す。
    const all = try evalImportSet(&f.ctx, f.arena.allocator(), try f.read("(sucheme core)"));
    const less = try evalImportSet(&f.ctx, f.arena.allocator(), try f.read("(except (sucheme core) car cdr)"));
    try std.testing.expectEqual(all.count() - 2, less.count());
    try std.testing.expect(all.contains("car") and !less.contains("car"));
    // 特殊形式と補助構文も、名前を持つ。
    for ([_][]const u8{ "if", "define-syntax", "else", "...", "_" }) |name| try std.testing.expect(all.contains(name));
    // `define-library` と `import` は束縛された名前ではない。
    try std.testing.expect(!all.contains("define-library") and !all.contains("import"));
}

test "an import set nested far deeper than the Zig stack allows is evaluated" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const depth = 100_000;
    var src: std.ArrayList(u8) = .empty;
    for (0..depth) |_| try src.appendSlice(f.arena.allocator(), "(only ");
    try src.appendSlice(f.arena.allocator(), "(sucheme core)");
    for (0..depth) |_| try src.appendSlice(f.arena.allocator(), " car)");
    try expectNames(&f, src.items, &.{"car"});
}

test "which top-level form a datum is is told by the spelling of its head" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try std.testing.expectEqual(TopLevelForm.import, topLevelForm(&f.ctx, try f.read("(import (a))")).?);
    try std.testing.expectEqual(TopLevelForm.define_library, topLevelForm(&f.ctx, try f.read("(define-library (a))")).?);
    try std.testing.expectEqual(null, topLevelForm(&f.ctx, try f.read("(imports (a))")));
    try std.testing.expectEqual(null, topLevelForm(&f.ctx, try f.read("(define (a))")));
    try std.testing.expectEqual(null, topLevelForm(&f.ctx, try f.read("import")));
    try std.testing.expectEqual(null, topLevelForm(&f.ctx, try f.read("((import))")));
    try std.testing.expectEqual(null, topLevelForm(&f.ctx, .fromFixnum(1)));
}
