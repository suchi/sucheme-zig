//! The REPL's global environment: what each name means at the top level, and
//! the cells of the global variables (docs/design/frontend.md, the REPL).
//!
//! 最上位の束縛は、名前から意味(特殊形式か、大域変数のセル)への表である。束縛は、
//! インポートしたものと、REPL 自身が作ったものに分かれる。プリミティブと特殊形式は
//! インポートした束縛である(2m で `(sucheme core)` のエクスポートになる)。
//!
//! `define` と `set!` の扱いは frontend.md の REPL の表に従う。REPL 自身の束縛へは
//! 同じセルに代入し、インポートした束縛は REPL の新しいセルで遮蔽する。遮蔽された
//! セルは、それを指すコードのために `imported_cells` が持ち続ける。
//!
//! 未束縛は、値として `Value.uninitialized` を持つセルで表す。表に無い名前を展開器が
//! 初めて解決したとき、REPL 自身の未束縛のセルを作る。後の `define` がそのセルに
//! 代入するので、先に定義した手続きからの前方参照が、後の定義を見る。
//!
//! プリミティブのセルは、名前が初めて解決されたときに作る。初期化の時点で作ると、
//! 小さなヒープの上限のもとでは、インタプリタを作ることすらできなくなるからである。

const std = @import("std");
const SymbolId = @import("symbol.zig").SymbolId;
const value_mod = @import("value.zig");
const Value = value_mod.Value;
const Cell = value_mod.Cell;
const Denotation = value_mod.Denotation;
const heap_mod = @import("heap.zig");
const Heap = heap_mod.Heap;
const Marker = heap_mod.Marker;

/// What making a cell or a binding can fail with: the heap's limit, or the
/// host's memory.
pub const Error = heap_mod.Error;

/// One binding of the top level: what the name means, and whether the REPL
/// imported it or made it itself.
pub const Binding = struct {
    /// A special form, or a global variable.
    /// 最上位に局所変数の意味は無い。
    denotation: Denotation,
    imported: bool,
};

pub const Global = struct {
    /// The bindings of the top level, by name.
    bindings: std.AutoHashMapUnmanaged(SymbolId, Binding) = .empty,
    /// The primitives the REPL imports whose cells are not made yet.
    /// 表の束縛が先に引かれるので、セルを作った後は、ここが引かれることはない。
    primitives: std.AutoHashMapUnmanaged(SymbolId, *const value_mod.Primitive) = .empty,
    /// The cells of the imported bindings.
    /// REPL がその束縛を遮蔽しても、遮蔽の前に展開したコードがセルを指し続ける。
    /// 2m では、インポート元のライブラリの表がこれを持つ。
    imported_cells: std.ArrayList(*Cell) = .empty,

    /// Imports the special form `special` under the name `id`.
    pub fn importSpecial(self: *Global, alloc: std.mem.Allocator, id: SymbolId, special: value_mod.Special) error{OutOfMemory}!void {
        try self.bindings.put(alloc, id, .{ .denotation = .{ .special = special }, .imported = true });
    }

    /// Imports the primitive `p` under the name `id`; its cell is made when the
    /// name is first resolved.
    pub fn importPrimitive(self: *Global, alloc: std.mem.Allocator, id: SymbolId, p: *const value_mod.Primitive) error{OutOfMemory}!void {
        try self.primitives.put(alloc, id, p);
    }

    /// Whether `id` is bound at the top level: a special form, or a variable
    /// with a value.
    /// 何も作らない。未束縛のセルは、束縛が無いことと同じに扱う。
    pub fn isBound(self: *const Global, id: SymbolId) bool {
        if (self.bindings.get(id)) |b| return switch (b.denotation) {
            .special => true,
            .global => |cell| cell.value.kind() != .uninitialized,
            .local => unreachable,
        };
        return self.primitives.contains(id);
    }

    /// What `id` means at the top level.
    /// 表に無い名前には、REPL 自身の未束縛のセルを作る。
    pub fn resolve(self: *Global, alloc: std.mem.Allocator, heap: *Heap, id: SymbolId) Error!Denotation {
        return (try self.binding(alloc, heap, id)).denotation;
    }

    /// The cell that a `define` of `id` at the top level gives its value to.
    ///
    /// REPL 自身の変数なら、そのセルである(R7RS 5.3.1: 束縛済みで構文でない変数への
    /// 定義は代入と同じ)。インポートした変数なら、REPL の新しいセルで遮蔽する。
    /// 特殊形式の名前なら、新しい未束縛のセルで遮蔽する(同節: 構文キーワードへの
    /// 定義は新しい場所を束縛する)。
    pub fn defineTarget(self: *Global, alloc: std.mem.Allocator, heap: *Heap, id: SymbolId) Error!*Cell {
        const b = try self.binding(alloc, heap, id);
        return switch (b.denotation) {
            .global => |cell| if (b.imported) self.shadow(alloc, heap, id, cell.value) else cell,
            .special => self.shadow(alloc, heap, id, .uninitialized_value),
            .local => unreachable,
        };
    }

    /// The cell that a `set!` of `id` at the top level assigns, or null when
    /// `id` names a special form, which cannot be assigned.
    /// REPL 自身の変数なら、そのセルである。インポートした変数なら、REPL の新しい
    /// セルで遮蔽する(frontend.md の REPL の表)。
    pub fn assignTarget(self: *Global, alloc: std.mem.Allocator, heap: *Heap, id: SymbolId) Error!?*Cell {
        const b = try self.binding(alloc, heap, id);
        return switch (b.denotation) {
            .global => |cell| if (b.imported) try self.shadow(alloc, heap, id, cell.value) else cell,
            .special => null,
            .local => unreachable,
        };
    }

    /// Tells the collector of every cell: those the table binds, and those it
    /// imported and has since shadowed.
    pub fn mark(self: *const Global, marker: *Marker) void {
        var it = self.bindings.valueIterator();
        while (it.next()) |b| switch (b.denotation) {
            .global => |cell| marker.object(Cell, cell),
            .special, .local => {},
        };
        for (self.imported_cells.items) |cell| marker.object(Cell, cell);
    }

    /// The binding of `id`, made when there is none yet: the primitive's cell
    /// if `id` names one, or else an unbound cell of the REPL's own.
    fn binding(self: *Global, alloc: std.mem.Allocator, heap: *Heap, id: SymbolId) Error!Binding {
        if (self.bindings.get(id)) |b| return b;
        if (self.primitives.get(id)) |p| {
            const cell = try heap.create(Cell, .{ .name = id, .value = .fromPrimitive(p) });
            try self.imported_cells.append(alloc, cell);
            const b: Binding = .{ .denotation = .{ .global = cell }, .imported = true };
            try self.bindings.put(alloc, id, b);
            return b;
        }
        return .{ .denotation = .{ .global = try self.shadow(alloc, heap, id, .uninitialized_value) }, .imported = false };
    }

    /// Binds `id` to a new cell of the REPL's own holding `value`, in place of
    /// whatever `id` was bound to.
    ///
    /// Why: 遮蔽するセルは、遮蔽される変数のその時点の値で始める。遮蔽は展開の時点で
    /// 決まり、値を与える `define` と `set!` が実行されるのはその後である。未束縛で
    /// 始めると、値の式が失敗したとき(`(define car (nope))`)や、同じ形式の後ろの
    /// 部分の展開が失敗したとき、名前が未束縛のまま残り、プリミティブを取り戻す手段が
    /// 無くなる。また `set!` は未束縛の変数を拒否するので、インポートした変数への
    /// `set!` が成り立たない。束縛済みで構文でない変数への定義は代入と同じ
    /// (R7RS 5.3.1)なので、その時点の値で始めて代入する形は、仕様の述べる結果と
    /// 一致する。違うのは、遮蔽の前に展開したコードが元のセルを見続けることだけで、
    /// それが frontend.md の REPL の表が求めることである。
    fn shadow(self: *Global, alloc: std.mem.Allocator, heap: *Heap, id: SymbolId, value: Value) Error!*Cell {
        const cell = try heap.create(Cell, .{ .name = id, .value = value });
        try self.bindings.put(alloc, id, .{ .denotation = .{ .global = cell }, .imported = false });
        return cell;
    }
};

test {
    std.testing.refAllDecls(@This());
}

const Fixture = struct {
    arena: std.heap.ArenaAllocator,
    heap: Heap,
    global: Global = .{},

    fn init(self: *Fixture) void {
        self.arena = .init(std.testing.allocator);
        self.heap = .init(std.testing.allocator, .{});
        self.global = .{};
    }

    fn deinit(self: *Fixture) void {
        self.heap.deinit();
        self.arena.deinit();
    }

    fn define(self: *Fixture, id: SymbolId) !*Cell {
        return self.global.defineTarget(self.arena.allocator(), &self.heap, id);
    }

    fn assign(self: *Fixture, id: SymbolId) !?*Cell {
        return self.global.assignTarget(self.arena.allocator(), &self.heap, id);
    }

    fn resolve(self: *Fixture, id: SymbolId) !Denotation {
        return self.global.resolve(self.arena.allocator(), &self.heap, id);
    }
};

const x: SymbolId = @fromBackingInt(@intCast(0));
const y: SymbolId = @fromBackingInt(@intCast(1));

test "a define of the REPL's own variable gives the same cell each time" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    const first = try f.define(x);
    first.value = .fromFixnum(1);
    const second = try f.define(x);
    try std.testing.expectEqual(first, second);
    // 先に参照だけされた名前も、REPL 自身の変数である。後の定義は、そのセルに値を与える。
    const referenced = (try f.resolve(y)).global;
    try std.testing.expectEqual(referenced, try f.define(y));
    try std.testing.expectEqual(referenced, (try f.assign(y)).?);
}

/// A primitive for the tests: what it does is never asked.
const probe: value_mod.Primitive = .{ .name = "probe", .min_args = 0, .max_args = 0, .body = .{ .pure = undefined } };

test "a primitive's cell is made when its name is first resolved, and then kept" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    try f.global.importPrimitive(f.arena.allocator(), x, &probe);
    try std.testing.expect(f.global.isBound(x));
    try std.testing.expectEqual(0, f.heap.count);
    const cell = (try f.resolve(x)).global;
    try std.testing.expectEqual(&probe, cell.value.asPrimitive().?);
    try std.testing.expectEqual(x, cell.name);
    try std.testing.expectEqual(1, f.heap.count);
    try std.testing.expectEqual(cell, (try f.resolve(x)).global);
    try std.testing.expectEqual(1, f.heap.count);
}

test "a define or a set! of an imported variable shadows it with a new cell that starts with its value" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    const a = f.arena.allocator();
    try f.global.importPrimitive(a, x, &probe);
    try f.global.importPrimitive(a, y, &probe);
    const imported = (try f.resolve(x)).global;
    const defined = try f.define(x);
    try std.testing.expect(defined != imported);
    try std.testing.expectEqual(&probe, defined.value.asPrimitive().?);
    // 遮蔽した後の名前は REPL 自身の変数なので、もう一度の定義は同じセルに代入する。
    try std.testing.expectEqual(defined, (try f.resolve(x)).global);
    try std.testing.expectEqual(defined, try f.define(x));
    try std.testing.expectEqual(defined, (try f.assign(x)).?);
    // インポートしたセルは変わらない。
    try std.testing.expectEqual(&probe, imported.value.asPrimitive().?);
    // set! も同じく遮蔽する。
    const imported_y = (try f.resolve(y)).global;
    const assigned = (try f.assign(y)).?;
    try std.testing.expect(assigned != imported_y);
    try std.testing.expectEqual(&probe, assigned.value.asPrimitive().?);
    try std.testing.expectEqual(assigned, try f.define(y));
}

test "a special form's name is bound, cannot be assigned, and a define shadows it with an unbound cell" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    try f.global.importSpecial(f.arena.allocator(), x, .@"if");
    try std.testing.expect(f.global.isBound(x));
    try std.testing.expectEqual(value_mod.Special.@"if", (try f.resolve(x)).special);
    try std.testing.expect(try f.assign(x) == null);
    try std.testing.expectEqual(value_mod.Special.@"if", (try f.resolve(x)).special);
    const cell = try f.define(x);
    try std.testing.expectEqual(value_mod.Kind.uninitialized, cell.value.kind());
    try std.testing.expectEqual(cell, (try f.resolve(x)).global);
    try std.testing.expect(!f.global.isBound(x));
}

test "a name only referenced is unbound, and is bound once its cell has a value" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    try std.testing.expect(!f.global.isBound(x));
    const cell = (try f.resolve(x)).global;
    try std.testing.expectEqual(value_mod.Kind.uninitialized, cell.value.kind());
    try std.testing.expect(!f.global.isBound(x));
    cell.value = .fromFixnum(1);
    try std.testing.expect(f.global.isBound(x));
}

test "the cells the table binds and the imported cells it shadowed survive a collection" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    try f.global.importPrimitive(f.arena.allocator(), x, &probe);
    const imported = (try f.resolve(x)).global;
    const own = try f.define(x);
    own.value = try f.heap.cons(.fromFixnum(1), .empty_list_value);
    _ = try f.heap.cons(.fromFixnum(2), .empty_list_value);
    // インポートしたセル、遮蔽したセル、2つのペア。
    try std.testing.expectEqual(4, f.heap.count);
    f.heap.collect(Roots{ .global = &f.global });
    // 到達できないペアだけが回収される。遮蔽されたセルは、コードがまだ指しうるので残る。
    try std.testing.expectEqual(3, f.heap.count);
    try std.testing.expectEqual(&probe, imported.value.asPrimitive().?);
    try std.testing.expectEqual(1, own.value.asPair().?.car.asFixnum().?);
}

const Roots = struct {
    global: *const Global,

    pub fn mark(self: Roots, marker: *Marker) void {
        self.global.mark(marker);
    }
};

test "a cell that does not fit the heap is the heap's error, and leaves the name as it was" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var heap: Heap = .init(std.testing.allocator, .{ .limit = 1 });
    defer heap.deinit();
    var g: Global = .{};
    try g.importPrimitive(arena.allocator(), x, &probe);
    try std.testing.expectError(error.HeapLimit, g.resolve(arena.allocator(), &heap, x));
    try std.testing.expectError(error.HeapLimit, g.defineTarget(arena.allocator(), &heap, y));
    try std.testing.expect(g.isBound(x));
    try std.testing.expect(g.bindings.count() == 0);
}
