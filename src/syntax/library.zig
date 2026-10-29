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
const machine = @import("../machine.zig");
const SymbolId = @import("../symbol.zig").SymbolId;
const printer = @import("../printer.zig");
const reader = @import("../reader.zig");
const resolve = @import("../resolve.zig");
const source_mod = @import("source.zig");
const cond_expand = @import("cond_expand.zig");

pub const Error = context.Error;

/// The most `define-library` forms and `import` lines being processed at once:
/// libraries that are files and import one another, to this depth.
/// Why: 読み込みは、import を見つけたところから入れ子に進む。入れ子の深さは、ファイルの鎖の
/// 長さで決まり、外部入力が決める。Zig のスタックを使い切らないよう、実装制限として報告する。
pub const max_load_depth = 64;

/// The deepest nesting of library declarations: `cond-expand` and
/// `include-library-declarations` inside one another.
/// Why: 宣言の入れ子は、入力が決める。処理は再帰するので、実装制限として報告する。
pub const max_declaration_depth = 64;

/// The most bytes of a source file (src/syntax/source.zig).
pub const max_file_bytes = source_mod.max_file_bytes;

/// The libraries that have been defined, or whose definition is in progress.
pub const Registry = struct {
    /// Every library whose definition began and has not failed, oldest first.
    list: std.ArrayList(*Library) = .empty,
    /// The tables of the libraries' top levels, indexed by `Library.table`.
    /// 定義に失敗したライブラリの表は、`abandon` が中身を返し、空のまま残る。表の番号を
    /// 再利用しないので、失敗したライブラリを指す古い識別子が、別のライブラリの表を引く
    /// ことはない。
    tables: std.ArrayList(*env_mod.Global) = .empty,
    /// The `define-library` forms being processed, innermost last.
    /// 本体の処理は機械を走らせるので、その間に GC が走る。処理中の宣言は、このリストが
    /// 指す形式の中にあるので、これがルートになる(ADR-0035 の読み込みの作業リスト)。
    loading: std.ArrayList(Value) = .empty,
    /// The names of the exports that the `define-library` forms being processed
    /// have declared and not yet resolved (`defineLibrary`).
    /// 保留の名前は、どの束縛にも、どの節点にも入っていないので、ここがルートになる。
    pending_names: std.ArrayList(SymbolId) = .empty,

    /// Gives back the tables and the lists, which were all taken from `alloc`.
    /// ライブラリ自身はヒープにあり、ここでは返さない。
    pub fn deinit(self: *Registry, alloc: std.mem.Allocator) void {
        for (self.tables.items) |table| {
            table.deinit(alloc);
            alloc.destroy(table);
        }
        self.tables.deinit(alloc);
        self.list.deinit(alloc);
        self.loading.deinit(alloc);
        self.pending_names.deinit(alloc);
    }

    /// Tells the collector of the libraries, the tables of their top levels,
    /// the forms being processed and the names of their pending exports.
    pub fn mark(self: *const Registry, marker: *heap_mod.Marker) void {
        for (self.list.items) |lib| marker.object(Library, lib);
        for (self.tables.items) |table| table.mark(marker);
        for (self.loading.items) |form| marker.value(form);
        for (self.pending_names.items) |id| marker.symbol(id);
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
        const tables = ctx.resident();
        const table = try tables.create(env_mod.Global);
        // 定義の途中は、未束縛のセルを強く持つ(`finish` の未束縛の検査が読む)。
        table.* = .{ .keep_unbound = true };
        // 表を `tables` に載せるまでは、`deinit` が返さないので、ここで返す。
        var listed = false;
        errdefer if (!listed) tables.destroy(table);
        const id: TableId = @fromBackingInt(@intCast(self.tables.items.len));
        const lib = try ctx.create(Library, .{ .name = name, .state = .loading, .exports = null, .root = null, .table = id });
        lib.root = try ctx.create(value_mod.SyntacticEnv, .{ .parent = null, .rib_depth = 0, .bindings = null, .library = lib });
        try self.tables.append(tables, table);
        listed = true;
        try self.list.append(tables, lib);
        return lib;
    }

    /// Takes a library whose definition failed out of the registry, and gives
    /// back what its table holds.
    /// 失敗した本体が、実行の途中で、ほかのライブラリの状態にクロージャを残すことがある。
    /// そのクロージャのコードは、このライブラリのセルを `global_ref` の節点で指すので、
    /// セルはコードから辿られる(ADR-0040)。表が持ち続ける必要は無い。表そのもの(空の
    /// `Global`)は `tables` に残し、番号を再利用しないので、失敗したライブラリを指す古い
    /// 識別子が、別のライブラリの表を引くことはない。同じ名前で、もう一度定義できる。
    pub fn abandon(self: *Registry, ctx: *Context, lib: *Library) void {
        for (self.list.items, 0..) |item, i| {
            if (item == lib) {
                _ = self.list.orderedRemove(i);
                break;
            }
        }
        self.tableOf(lib).deinit(ctx.resident());
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
    const name = ctx.heap.symbols.nameOf(head);
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
    // プリンタは、作業領域の確保を断られると `HeapLimit` を返し、`external_refused` を呼び出し側の
    // 値に戻す。上限の超過を `limitFailure` が見分けられるよう、印を立ててから `OutOfMemory` にする。
    printer.print(&out.writer, &ctx.heap, &ctx.heap.symbols, name, .write) catch |e| {
        if (e == error.HeapLimit) ctx.heap.external_refused = true;
        return error.OutOfMemory;
    };
    return out.written();
}

/// Checks that `name` is a library name: a list of at least one identifier or
/// non-negative integer (R7RS 5.6.1).
pub fn checkName(ctx: *Context, name: Value) Error!void {
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
pub fn isCoreName(ctx: *const Context, name: Value) bool {
    var rest = name;
    for ([_][]const u8{ "sucheme", "core" }) |expected| {
        const p = rest.asPair() orelse return false;
        const sym = p.car.asSymbol() orelse return false;
        if (!std.mem.eql(u8, ctx.heap.symbols.nameOf(sym), expected)) return false;
        rest = p.cdr;
    }
    return rest.kind() == .empty_list;
}

/// The work of one `import`, a form at the REPL or a declaration of a library:
/// the tables of names its sets bring, counted against the limit of the heap
/// until all the sets are bound (ADR-0040).
/// Why: 修飾子を入れ子に重ねると、段ごとに名前の全部を写すので、作業が上限を大きく超えうる。
/// 集合を並べても同じで、どの集合の作業も束縛し終えるまで残るので、`import` の全体の間
/// 数える。数えたものが上限に収まらなければ、確保は `error.OutOfMemory` で断られ、
/// `heap.external_refused` が立つ。作業は `scratch` に残り、呼び出し側が丸ごと捨てる。
/// 使い方: `begin` で始め、`allocator` を集合の評価に渡し、`end` を `defer` で呼ぶ。始めた後は
/// 動かさない(割り当て器が自分を指す)。
const ImportWork = struct {
    charge: heap_mod.Charged,
    counting: heap_mod.Heap.Counting,

    fn begin(ctx: *Context, scratch: std.mem.Allocator) ImportWork {
        return .{
            .charge = .{ .heap = &ctx.heap, .backing = scratch },
            .counting = ctx.heap.beginCounting(true),
        };
    }

    fn allocator(self: *ImportWork) std.mem.Allocator {
        return self.charge.allocator();
    }

    fn end(self: *ImportWork) void {
        self.charge.heap.endCounting(self.counting);
    }
};

/// Evaluates the import set `spec` (R7RS 5.2): what it brings, by name.
/// 入れ子の修飾子の深さに比例して進むので、再帰せず、外側から内側へ修飾子を積み、
/// 内側から順に適用する。エクスポートの名前の文字列は、ヒープの文字列とシンボル表の
/// 名前を指す。GC が走るまで有効である。
///
/// 修飾子の作業(名前の表と、`prefix` が作る名前)は `work` から取る。`work` は、1つの `import`
/// の間ずっと上限に数える割り当て器である(`ImportWork`)。ライブラリのファイルを読む処理は、
/// 数えない `scratch` で行う(その中の展開と本体の実行は、それぞれの計上に従う)。
pub fn evalImportSet(ctx: *Context, scratch: std.mem.Allocator, work: std.mem.Allocator, spec: Value) Error!Names {
    const Pending = struct { kind: Modifier, arguments: Value };
    // Why: 修飾子の列も `work` に置くが、大きさは修飾子の数に比例し、修飾子はどれも読んだ形式の
    // 対を2つ以上使う。形式はヒープにあり、上限に数えてあるので、列は上限を大きく超えない。
    // 列を数えることを固定するテストは置いていない(列だけで上限を超える入力は、形式が先に
    // 上限を超える)。
    var pending: std.ArrayList(Pending) = .empty;
    var current = spec;
    while (current.asPair()) |p| {
        const head = p.car.asSymbol() orelse break;
        const kind = std.meta.stringToEnum(Modifier, ctx.heap.symbols.nameOf(head)) orelse break;
        const inner = p.cdr.asPair() orelse
            return ctx.raise("bad import: {s} needs an import set", .{@tagName(kind)});
        try pending.append(work, .{ .kind = kind, .arguments = inner.cdr });
        current = inner.car;
    }
    var names = try exportsOf(ctx, scratch, work, current);
    while (pending.pop()) |m| names = try modify(ctx, work, m.kind, m.arguments, names);
    return names;
}

/// What the library named `name` exports, in a table taken from `work`.
/// 見つからないライブラリのファイルは、`scratch` で読む。
fn exportsOf(ctx: *Context, scratch: std.mem.Allocator, work: std.mem.Allocator, name: Value) Error!Names {
    try checkName(ctx, name);
    var names: Names = .empty;
    if (isCoreName(ctx, name)) {
        // Why: `(sucheme core)` は標準ライブラリの土台で、`%` で始まる内部の名前を含む。利用者の
        // プログラムには見せない(docs/adr/0037-core-library-exposed-in-stage-2.md)。
        if (!ctx.coreImportable())
            return ctx.raise("bad import: the library (sucheme core) is only for the standard libraries the executable carries", .{});
        var it = ctx.core.entries.keyIterator();
        while (it.next()) |id| {
            const d = (ctx.core.get(&ctx.heap, id.*) catch |e| return ctx.heapFailure(e)).?;
            try names.put(work, ctx.heap.symbols.nameOf(id.*), d);
        }
        return names;
    }
    const lib = ctx.libraries.find(name) orelse try loadFile(ctx, scratch, name);
    if (lib.state == .loading)
        return ctx.raise("bad import: circular import of the library {s}", .{try nameText(ctx, scratch, name)});
    var export_it = lib.exports;
    while (export_it) |e| : (export_it = e.next) try names.put(work, e.name.bytes, e.denotation);
    return names;
}

/// Defines the library named `name` from its file, which an import found no
/// definition of, and returns it.
/// ファイルは、探索ルートの配下にある `foo/bar.sld`(`(foo bar)` の場合)で、1つの
/// `define-library` を持つ。読む、名前を照合する、展開して本体を機械で走らせる、の順に進める。
/// ファイルのデータを読む前は、GC の境目である(ADR-0035)。呼び出し側の保持するものは、すべて
/// 登録表の `loading` がルートとして持つ形式の中か、登録表の中にある。ファイルの名前は、
/// ファイルシステムが無いときも検査する。
fn loadFile(ctx: *Context, scratch: std.mem.Allocator, name: Value) Error!*Library {
    const text = try nameText(ctx, scratch, name);
    _ = resolve.libraryParts(scratch, &ctx.heap.symbols, name) catch |e| return nameFailure(ctx, text, e);
    if (ctx.files == null and ctx.embedded == null) return ctx.raise("unknown library: {s}", .{text});
    if (ctx.libraries.loading.items.len >= max_load_depth)
        return ctx.raise("implementation restriction: libraries import one another more than {d} deep, at {s}", .{ max_load_depth, text });
    const opened = resolve.openLibrary(ctx.files, ctx.embedded, scratch, &ctx.heap.symbols, name) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.NotFound => return ctx.raise("unknown library: {s}", .{text}),
        error.LinkRefused => return ctx.raise("cannot load the library {s}: its file, or a directory on the way to it, is a link", .{text}),
        error.NotRegularFile => return ctx.raise("cannot load the library {s}: its file is not a regular file", .{text}),
        error.Unreadable => return ctx.raise("cannot load the library {s}: the system refused to open its file", .{text}),
        else => |n| return nameFailure(ctx, text, n),
    };
    const form = try readLibraryForm(ctx, scratch, opened, text);
    // ファイルシステムは大文字と小文字を区別しないことがある。名前の照合は、定義より前に行う。
    if (form.asPair().?.cdr.asPair()) |rest| {
        if (!sameName(rest.car, name)) return ctx.raise(
            "bad import: the file of the library {s} defines the library {s}",
            .{ text, try nameText(ctx, scratch, rest.car) },
        );
    }
    // 本体の `include` は、このファイルのディレクトリを基準にする。同じファイルを含む
    // ことは、含んでいる最中のファイルとして見つけて拒否する。
    try ctx.sources.append(ctx.resident(), opened.origin);
    defer _ = ctx.sources.pop();
    try defineLibrary(ctx, scratch, form);
    return ctx.libraries.find(name).?;
}

/// The one `define-library` form that `source` holds, closing its file and letting go
/// of its text before it returns.
/// Why: 本体の評価は、`import` を通して次のファイルを読む。ファイルの内容(最大
/// `max_file_bytes`)をその間も持ち続けると、入れ子の深さ分が同時にメモリに載る。リーダが
/// 作る値は、内容を指さない(シンボルは永続領域へ、文字列はヒープへ複製する)ので、読み終えた
/// 時点で手放す。
/// 読んだリストの位置は、ファイルの名前とともに `ctx.positions` に記録する。
fn readLibraryForm(ctx: *Context, scratch: std.mem.Allocator, opened: resolve.Opened, text: []const u8) Error!Value {
    defer source_mod.closeSource(ctx.files, opened.source);
    const subject = try std.fmt.allocPrint(scratch, "load the library {s}", .{text});
    const contents = try source_mod.readText(ctx, ctx.files, opened.source, subject);
    defer ctx.heap.backing.free(contents);
    if (ctx.heap.shouldCollect()) ctx.collectIdle();
    var r: reader.Reader = .init(contents);
    const to = try source_mod.sinkFrom(ctx, scratch, opened.origin);
    const form = (try source_mod.readDatumTo(ctx, &r, scratch, to, subject)) orelse
        return ctx.raise("cannot {s}: its file is empty", .{subject});
    if (topLevelForm(ctx, form) != .define_library)
        return ctx.raise("cannot {s}: its file must hold one (define-library ...) form", .{subject});
    if ((try source_mod.readDatum(ctx, &r, scratch, subject)) != null)
        return ctx.raise("cannot {s}: its file holds more than one form", .{subject});
    return form;
}

/// What can go wrong in checking that a library name can name a file.
const NameFailure = resolve.NameError || error{OutOfMemory};

/// The error for a library name that cannot name a file.
fn nameFailure(ctx: *Context, text: []const u8, e: NameFailure) Error {
    return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        else => |refused| ctx.raise(
            "unknown library: {s}: a library with that name cannot be a file, because {s}",
            .{ text, resolve.describeNameError(refused) },
        ),
    };
}

/// The name an identifier of an import set is written as.
fn identifierName(ctx: *Context, id: Value, comptime what: []const u8) Error![]const u8 {
    const symbol = id.asSymbol() orelse
        return ctx.raise("bad import: " ++ what ++ " expects identifiers", .{});
    return ctx.heap.symbols.nameOf(symbol);
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
/// は誤りである。インポートより前に参照だけされた名前は、そのセルが `displaced_unbound` に残り、
/// 本体の終わりに未束縛として報告される(`finish`)。
pub fn bindImports(ctx: *Context, table: *env_mod.Global, names: Names, mode: expand.Mode) Error!void {
    var it = names.iterator();
    while (it.next()) |entry| {
        const name = entry.key_ptr.*;
        const id = try ctx.intern(name);
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
        try table.importBinding(ctx.resident(), id, entry.value_ptr.*);
    }
}

/// `(import <import set> ...)` at the REPL (R7RS 5.2): imports what the sets bring
/// into the REPL's top level.
/// 先にすべての集合を評価し、それから束縛する。集合の誤りで、一部だけがインポート
/// されることはない。束縛の途中で上限に断られたときも、それまでの束縛を戻す。
pub fn importIntoRepl(ctx: *Context, scratch: std.mem.Allocator, form: Value) Error!void {
    const items = try itemsOf(ctx, scratch, form, "import");
    if (items.len < 2) return ctx.raise("bad import: expected (import <import set> ...)", .{});
    // 集合を評価する間に、ファイルのライブラリを読んで本体を走らせると、GC が走る。
    // この形式は、そのあいだ読み手の外にあるので、作業中の形式としてルートに載せる。
    try ctx.libraries.loading.append(ctx.resident(), form);
    defer _ = ctx.libraries.loading.pop();
    var import_work: ImportWork = .begin(ctx, scratch);
    defer import_work.end();
    const work = import_work.allocator();
    const sets = try work.alloc(Names, items.len - 1);
    for (sets, items[1..]) |*set, spec| set.* = try evalImportSet(ctx, scratch, work, spec);
    errdefer ctx.globals.undoShadows();
    for (sets) |set| try bindImports(ctx, &ctx.globals, set, .repl);
    ctx.globals.commitShadows();
}

/// One `export` the library declares: the identifier of its body and the name
/// it is exported under.
const PendingExport = struct { internal: SymbolId, external: SymbolId };

/// `(define-library <name> <declaration> ...)` (R7RS 5.6.1): defines the library,
/// processing its declarations from left to right.
/// 本体の `begin` は、フォームごとに展開して機械で走らせる。展開器は機械の実行をまたいで
/// 状態を持たない(ADR-0035)。処理中の形式は登録表の `loading` がルートとして持ち、フォームの
/// 間でだけ GC が走る。どこかで失敗したら、ライブラリは登録表から外れ、REPL の最上位は何も
/// 変わらない。`export` の解決は本体の処理が終わってからで、本体の終わりに、未束縛の
/// 識別子を名前を挙げて報告する(docs/design/frontend.md)。
pub fn defineLibrary(ctx: *Context, scratch: std.mem.Allocator, form: Value) Error!void {
    const items = try itemsOf(ctx, scratch, form, "define-library");
    if (items.len < 2) return ctx.raise("bad define-library: expected (define-library <name> <declaration> ...)", .{});
    const name = items[1];
    try checkName(ctx, name);
    if (isCoreName(ctx, name) or ctx.libraries.find(name) != null)
        return ctx.raise("bad define-library: the library {s} is already defined", .{try nameText(ctx, scratch, name)});
    const lib = try ctx.libraries.begin(ctx, name);
    errdefer ctx.libraries.abandon(ctx, lib);
    try ctx.libraries.loading.append(ctx.resident(), form);
    defer _ = ctx.libraries.loading.pop();
    const names_before = ctx.libraries.pending_names.items.len;
    defer ctx.libraries.pending_names.shrinkRetainingCapacity(names_before);
    var pending: std.ArrayList(PendingExport) = .empty;
    for (items[2..]) |declaration| try declare(ctx, scratch, lib, declaration, &pending, 0);
    try finish(ctx, scratch, lib, pending.items);
}

/// Processes one declaration of a library.
fn declare(ctx: *Context, scratch: std.mem.Allocator, lib: *Library, declaration: Value, pending: *std.ArrayList(PendingExport), depth: usize) Error!void {
    if (depth >= max_declaration_depth)
        return ctx.raise("implementation restriction: library declarations are nested more than {d} deep", .{max_declaration_depth});
    const bad = "bad define-library: a declaration must be a list that starts with an identifier";
    if (declaration.asPair() == null) return ctx.raise(bad, .{});
    const parts = try itemsOf(ctx, scratch, declaration, "define-library");
    const head = parts[0].asSymbol() orelse return ctx.raise(bad, .{});
    const keyword = ctx.heap.symbols.nameOf(head);
    const table = ctx.libraries.tableOf(lib);
    if (std.mem.eql(u8, keyword, "export")) {
        for (parts[1..]) |spec| {
            const export_spec = try exportSpec(ctx, scratch, spec);
            // Why: 保留の名前は、本体の各形式の間を Zig の一覧で持ち越す。その間に GC が走る。
            // `include-library-declarations` が読んだ宣言は、読み終えると登録表の `loading` から
            // 外れ、名前を指すものが無くなる。名前を挙げておかないと、ID が回収され、別の名前に
            // 再利用される。登録表の `pending_names` が、定義を終えるまで持つ。
            try ctx.libraries.pending_names.appendSlice(ctx.resident(), &.{ export_spec.internal, export_spec.external });
            try pending.append(scratch, export_spec);
        }
    } else if (std.mem.eql(u8, keyword, "import")) {
        // 集合を先にすべて評価してから束縛する。失敗したら、ライブラリごと登録表から外れる。
        var import_work: ImportWork = .begin(ctx, scratch);
        defer import_work.end();
        const work = import_work.allocator();
        const sets = try work.alloc(Names, parts.len - 1);
        for (sets, parts[1..]) |*set, spec| set.* = try evalImportSet(ctx, scratch, work, spec);
        for (sets) |set| try bindImports(ctx, table, set, .library);
        table.commitShadows();
    } else if (std.mem.eql(u8, keyword, "begin")) {
        const target: expand.Target = .{ .table = table, .root = lib.root, .mode = .library };
        for (parts[1..]) |body| {
            // フォームの間は、機械もリーダも何も保持していない境目である(ADR-0035)。
            if (ctx.heap.shouldCollect()) ctx.collectIdle();
            const node = try expand.expandIn(ctx, scratch, body, target, .{});
            var m: machine.Machine = .init(ctx, scratch);
            _ = try m.run(node);
        }
    } else if (std.mem.eql(u8, keyword, "include") or std.mem.eql(u8, keyword, "include-ci")) {
        const fold_case = std.mem.eql(u8, keyword, "include-ci");
        for (parts[1..]) |name| {
            var rest = try enterIncluded(ctx, scratch, name, keyword, fold_case);
            defer leaveIncluded(ctx);
            const target: expand.Target = .{ .table = table, .root = lib.root, .mode = .library };
            while (rest.asPair()) |p| : (rest = p.cdr) {
                if (ctx.heap.shouldCollect()) ctx.collectIdle();
                const node = try expand.expandIn(ctx, scratch, p.car, target, .{});
                var m: machine.Machine = .init(ctx, scratch);
                _ = try m.run(node);
            }
        }
    } else if (std.mem.eql(u8, keyword, "include-library-declarations")) {
        for (parts[1..]) |name| {
            var rest = try enterIncluded(ctx, scratch, name, "include-library-declarations", false);
            defer leaveIncluded(ctx);
            while (rest.asPair()) |p| : (rest = p.cdr) try declare(ctx, scratch, lib, p.car, pending, depth + 1);
        }
    } else if (std.mem.eql(u8, keyword, "cond-expand")) {
        // どの節も当てはまらず `else` も無ければ、宣言は何も足さない。
        const chosen = try cond_expand.select(ctx, scratch, parts[1..]) orelse return;
        for (try itemsOf(ctx, scratch, chosen, "cond-expand")) |chosen_declaration|
            try declare(ctx, scratch, lib, chosen_declaration, pending, depth + 1);
    } else {
        return ctx.raise("bad define-library: {s} is not a library declaration", .{keyword});
    }
}

/// Reads the file that `name`, the file name of an `include` declaration, means, and
/// returns its data as a list. The data are roots, and the file is the one that
/// `include`s in it are relative to, until `leaveIncluded`.
/// Why: 宣言の処理は、データの間に機械を走らせるので、GC が走りうる。読み終えたデータは
/// どこからも指されていないので、リストにして、登録表の `loading` にルートとして載せる。
fn enterIncluded(ctx: *Context, scratch: std.mem.Allocator, name: Value, what: []const u8, fold_case: bool) Error!Value {
    const text = (name.asString() orelse return ctx.raise("bad {s}: a file name must be a string", .{what})).bytes;
    const opened = try source_mod.openIncluded(ctx, scratch, text, what);
    const subject = try std.fmt.allocPrint(scratch, "{s} {s}", .{ what, text });
    const data = try source_mod.readDataFrom(ctx, scratch, ctx.files, opened.source, opened.origin, subject, fold_case);
    var list: Value = .empty_list_value;
    var i = data.len;
    while (i > 0) {
        i -= 1;
        list = ctx.heap.cons(data[i], list) catch |e| return ctx.heapFailure(e);
    }
    try ctx.libraries.loading.append(ctx.resident(), list);
    errdefer _ = ctx.libraries.loading.pop();
    try ctx.sources.append(ctx.resident(), opened.origin);
    return list;
}

/// Ends what `enterIncluded` began.
fn leaveIncluded(ctx: *Context) void {
    _ = ctx.sources.pop();
    _ = ctx.libraries.loading.pop();
}

/// The export `spec` of an `export` declaration: an identifier, or
/// `(rename <internal> <external>)` (R7RS 5.6.1).
fn exportSpec(ctx: *Context, scratch: std.mem.Allocator, spec: Value) Error!PendingExport {
    if (spec.asSymbol()) |id| return .{ .internal = id, .external = id };
    const bad = "bad export: expected an identifier or (rename <internal> <external>)";
    const parts = itemsOf(ctx, scratch, spec, "export") catch return ctx.raise(bad, .{});
    if (parts.len != 3) return ctx.raise(bad, .{});
    const keyword = parts[0].asSymbol() orelse return ctx.raise(bad, .{});
    if (!std.mem.eql(u8, ctx.heap.symbols.nameOf(keyword), "rename")) return ctx.raise(bad, .{});
    return .{
        .internal = parts[1].asSymbol() orelse return ctx.raise(bad, .{}),
        .external = parts[2].asSymbol() orelse return ctx.raise(bad, .{}),
    };
}

/// Ends the definition of a library whose body is processed: resolves the
/// exports, checks that nothing the body refers to is unbound, and makes the
/// library loaded.
fn finish(ctx: *Context, scratch: std.mem.Allocator, lib: *Library, pending: []const PendingExport) Error!void {
    const table = ctx.libraries.tableOf(lib);
    for (pending) |p| {
        const denotation = try syntax_env.resolve(ctx, lib.root, .fromSymbol(p.internal));
        const external = ctx.heap.symbols.nameOf(p.external);
        var existing = lib.exports;
        while (existing) |e| : (existing = e.next) {
            if (!std.mem.eql(u8, e.name.bytes, external)) continue;
            if (syntax_env.sameDenotation(e.denotation, denotation)) break;
            return ctx.raise("bad export: {s} is exported twice with different bindings", .{external});
        } else {
            const name = ctx.heap.createString(external) catch |e| return ctx.heapFailure(e);
            lib.exports = try ctx.create(value_mod.Export, .{
                .name = name,
                .denotation = denotation,
                .imported = table.lookup(p.internal).?.imported,
                .next = lib.exports,
            });
        }
    }
    const unbound = try unboundNames(ctx, scratch, table);
    if (unbound.len > 0) {
        var list: std.Io.Writer.Allocating = .init(scratch);
        for (unbound, 0..) |n, i| list.writer.print("{s}{s}", .{ if (i == 0) "" else ", ", n }) catch return error.OutOfMemory;
        return ctx.raise("{s} in library {s}: {s}", .{
            if (unbound.len == 1) "unbound identifier" else "unbound identifiers",
            try nameText(ctx, scratch, lib.name),
            list.written(),
        });
    }
    // 検査が済めば、ほかの最上位の表と同じく弱く持つ。エクスポートしたマクロの展開が、
    // この表に未束縛のセルを作ることがある。
    table.keep_unbound = false;
    lib.state = .loaded;
}

/// The names that the top level of a library refers to and never binds, in
/// order, each once: variables that have no value, including those that a later
/// `import` or `define-syntax` replaced.
/// Why: 本体の処理中は、見つからない識別子を、その最上位自身の未束縛のセルに解決する。
/// 同じ本体の後の `define` への前方参照が通るためである。本体の終わりまで値を持たない
/// セルが、定義もインポートもされなかった名前である。
fn unboundNames(ctx: *Context, scratch: std.mem.Allocator, table: *const env_mod.Global) Error![]const []const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    var it = table.bindings.valueIterator();
    while (it.next()) |b| {
        if (b.imported) continue;
        switch (b.denotation) {
            .global => |cell| if (cell.value.kind() == .uninitialized) try names.append(scratch, ctx.heap.symbols.nameOf(cell.name)),
            else => {},
        }
    }
    for (table.displaced_unbound.items) |cell| {
        if (cell.value.kind() == .uninitialized) try names.append(scratch, ctx.heap.symbols.nameOf(cell.name));
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);
    var unique: usize = 0;
    for (names.items) |n| {
        if (unique > 0 and std.mem.eql(u8, names.items[unique - 1], n)) continue;
        names.items[unique] = n;
        unique += 1;
    }
    return names.items[0..unique];
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
        // 標準ライブラリを持たないので、`(sucheme core)` を直接取り込めるようにする。
        self.ctx.core_open = true;
    }

    fn deinit(self: *Fixture) void {
        self.ctx.deinit();
        self.arena.deinit();
    }

    fn read(self: *Fixture, src: []const u8) !Value {
        var r: reader.Reader = .init(src);
        const sink: reader.Sink = .{ .heap = &self.ctx.heap };
        return (try r.next(self.arena.allocator(), sink)).?;
    }

    /// A new library named by the datum `name`, which imports `names` from core.
    fn library(self: *Fixture, name: []const u8, names: []const []const u8) !*Library {
        const lib = try self.ctx.libraries.begin(&self.ctx, try self.read(name));
        const table = self.ctx.libraries.tableOf(lib);
        for (names) |n| {
            const id = try self.ctx.intern(n);
            const d = (try self.ctx.core.get(&self.ctx.heap, id)).?;
            try table.importBinding(self.ctx.resident(), id, d);
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
        try core.write(&out.writer, &self.ctx.heap, &self.ctx.heap.symbols, node);
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

test "the text of a library name that does not fit in the heap is told as the limit" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const name = try f.read("(foo bar 1)");
    f.ctx.heap.options.limit = f.ctx.heap.held() + 16;
    f.ctx.heap.external_refused = false;
    try std.testing.expectError(error.OutOfMemory, nameText(&f.ctx, f.arena.allocator(), name));
    // 上限で断られたことが残るので、入口の `limitFailure` が上限の誤りにする。
    try std.testing.expect(f.ctx.heap.external_refused);
    try std.testing.expectEqual(error.Raised, f.ctx.limitFailure(error.OutOfMemory));
    try std.testing.expectEqualStrings(context.heap_limit_message, f.ctx.diagnostic());
    // 上限でない失敗(書き出す先の確保をホストが断る)では、印を立てない。
    var failing: std.testing.FailingAllocator = .init(std.testing.allocator, .{ .fail_index = 0 });
    f.ctx.heap.options.limit = std.math.maxInt(usize);
    f.ctx.heap.external_refused = false;
    try std.testing.expectError(error.OutOfMemory, nameText(&f.ctx, failing.allocator(), name));
    try std.testing.expect(!f.ctx.heap.external_refused);
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
    f.ctx.libraries.abandon(&f.ctx, lost);
    try std.testing.expectEqual(null, f.ctx.libraries.find(try f.read("(t lost)")));
    try std.testing.expectEqual(keep, f.ctx.libraries.find(try f.read("(t keep)")).?);
    f.ctx.collectIdle();
    try std.testing.expectEqual(1, f.ctx.heap.countOf(Library));
    try std.testing.expectEqual(1, f.ctx.heap.countOf(value_mod.SyntacticEnv));
    // 同じ名前で、もう一度始められる。
    const again = try f.library("(t lost)", &.{});
    try std.testing.expect(f.ctx.libraries.tableOf(again) != lost_table);
}

test "the table of a library whose definition failed is given back, and its cells go with the code" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const lost = try f.library("(t lost)", &.{ "define", "quote" });
    _ = try f.expandIn(lost, "(define x '(1 2))");
    f.ctx.collectIdle();
    const cells = f.ctx.heap.countOf(value_mod.Cell);
    const resident = f.ctx.heap.resident;
    f.ctx.libraries.abandon(&f.ctx, lost);
    // 表の束縛の分が、常駐の計上から戻る。
    try std.testing.expect(f.ctx.heap.resident < resident);
    f.ctx.collectIdle();
    // `x` のセルは、表のほかに持つものが無いので、回収される。
    try std.testing.expect(f.ctx.heap.countOf(value_mod.Cell) < cells);
}

test "the forms being processed and the bindings of a library survive a collection" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const lib = try f.library("(t a)", &.{ "define", "quote" });
    _ = try f.expandIn(lib, "(define x '(1 2))");
    const table = f.ctx.libraries.tableOf(lib);
    const x = f.ctx.heap.symbols.lookup("x").?;
    table.lookup(x).?.denotation.global.value = try f.ctx.heap.cons(.fromFixnum(1), .empty_list_value);
    const form = try f.read("(define-library (t a) (export))");
    try f.ctx.libraries.loading.append(f.ctx.resident(), form);
    _ = try f.ctx.heap.cons(.fromFixnum(9), .empty_list_value);
    f.ctx.collectIdle();
    // 作業中の形式は、読んだペアのまま残る。セルの値も残る。
    var out: std.Io.Writer.Allocating = .init(f.arena.allocator());
    try @import("../printer.zig").print(&out.writer, &f.ctx.heap, &f.ctx.heap.symbols, form, .write);
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
    try std.testing.expect(!f.ctx.globals.isBound(f.ctx.heap.symbols.lookup("x").?));
    try std.testing.expectEqualStrings("(global x)", try f.expandRepl("x"));
    try std.testing.expect(f.ctx.globals.lookup(f.ctx.heap.symbols.lookup("x").?).?.denotation.global !=
        f.ctx.libraries.tableOf(lib).lookup(f.ctx.heap.symbols.lookup("x").?).?.denotation.global);
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
    try std.testing.expect(f.ctx.libraries.tableOf(lib).lookup(f.ctx.heap.symbols.lookup("car").?).?.imported);
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
    const m = f.ctx.libraries.tableOf(lib).lookup(f.ctx.heap.symbols.lookup("m").?).?.denotation;
    const use = try f.read("(m 0 1 2)");
    var work: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer work.deinit();
    const output = try @import("rules.zig").transform(&f.ctx, &work, m.macro, use, null);
    var out: std.Io.Writer.Allocating = .init(f.arena.allocator());
    try @import("../printer.zig").print(&out.writer, &f.ctx.heap, &f.ctx.heap.symbols, output, .write);
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
    const macro = f.ctx.libraries.tableOf(lib).lookup(f.ctx.heap.symbols.lookup("use-helper").?).?.denotation.macro;
    const helper = f.ctx.heap.symbols.lookup("helper").?;
    const own = f.ctx.libraries.tableOf(lib).lookup(helper).?.denotation.global;
    const repl = f.ctx.globals.lookup(helper).?.denotation.global;
    try std.testing.expect(own != repl);
    // マクロを REPL の最上位に束縛して、使う。
    try f.ctx.globals.defineSyntax(f.ctx.resident(), f.ctx.heap.symbols.lookup("use-helper").?, macro);
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
            return fx.ctx.heap.symbols.lookup(name).?;
        }
    }.of;
    try f.ctx.globals.defineSyntax(f.ctx.resident(), id(&f, "bump!"), table.lookup(id(&f, "bump!")).?.denotation.macro);
    try f.ctx.globals.defineSyntax(f.ctx.resident(), id(&f, "clobber!"), table.lookup(id(&f, "clobber!")).?.denotation.macro);
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
    const names = try evalImportSet(&f.ctx, f.arena.allocator(), f.arena.allocator(), try f.read(spec));
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
    const all = try evalImportSet(&f.ctx, f.arena.allocator(), f.arena.allocator(), try f.read("(sucheme core)"));
    const less = try evalImportSet(&f.ctx, f.arena.allocator(), f.arena.allocator(), try f.read("(except (sucheme core) car cdr)"));
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
