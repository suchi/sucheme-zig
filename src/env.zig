//! The global environment of a top level: what each name means there, and the
//! cells of the global variables (docs/design/frontend.md, the REPL).
//!
//! 最上位の束縛は、名前から意味(特殊形式、マクロ、補助構文、大域変数のセル)への表
//! である。束縛は、インポートしたものと、その最上位自身が作ったものに分かれる。REPL の
//! 最上位は、`(sucheme core)` のエクスポート(`Core`)を最初からインポートしている。表に
//! 無い名前は `Core` から引き、インポートした束縛として表に写す。
//!
//! `define` と `set!` の扱いは frontend.md の REPL の表に従う。REPL 自身の束縛へは
//! 同じセルに代入し、インポートした束縛は REPL の新しいセルで遮蔽する。遮蔽されたセルは、
//! それを指すコードのために、エクスポート元が持ち続ける(`Core`、またはライブラリ)。
//!
//! 未束縛は、値として `Value.uninitialized` を持つセルで表す。表に無い名前を展開器が
//! 初めて解決したとき、その最上位自身の未束縛のセルを作る。後の `define` がそのセルに
//! 代入するので、先に定義した手続きからの前方参照が、後の定義を見る。
//!
//! プリミティブのセルは、名前が初めて解決されたときに `Core` が作り、以後は同じセルを
//! すべてのインポート元が共有する。初期化の時点で作ると、小さなヒープの上限のもとでは、
//! インタプリタを作ることすらできなくなるからである。

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

/// One binding of the top level: what the name means, and whether the top level
/// imported it or made it itself.
pub const Binding = struct {
    /// A special form, a macro, an auxiliary syntax, or a global variable.
    /// 最上位に局所変数の意味は無い。
    denotation: Denotation,
    imported: bool,
};

/// What `(sucheme core)` exports: the special forms, the auxiliary syntax and the
/// primitives, which Zig registers (docs/design/frontend.md, the order of
/// start-up).
/// 名前はシンボルで引く。名前はインタプリタの初期化のときにインターンされ、表は
/// インタプリタと同じ寿命である。
pub const Core = struct {
    entries: std.AutoHashMapUnmanaged(SymbolId, Entry) = .empty,

    pub const Entry = union(enum) {
        /// A primitive whose cell is made when the name is first looked up.
        primitive: *const value_mod.Primitive,
        /// A special form, an auxiliary syntax, or the cell of a primitive that
        /// has been looked up.
        bound: Denotation,
    };

    /// Exports the primitive `p` under the name `id`.
    pub fn addPrimitive(self: *Core, alloc: std.mem.Allocator, id: SymbolId, p: *const value_mod.Primitive) error{OutOfMemory}!void {
        try self.entries.put(alloc, id, .{ .primitive = p });
    }

    /// Exports `denotation`, a special form or an auxiliary syntax, under the name
    /// `id`.
    pub fn addSyntax(self: *Core, alloc: std.mem.Allocator, id: SymbolId, denotation: Denotation) error{OutOfMemory}!void {
        try self.entries.put(alloc, id, .{ .bound = denotation });
    }

    /// Whether `id` is exported.
    /// 何も作らない。
    pub fn contains(self: *const Core, id: SymbolId) bool {
        return self.entries.contains(id);
    }

    /// What `id` means as an export, or null when it is not exported.
    /// プリミティブのセルは、最初に引かれたときに作り、以後は同じセルを返す。作れなければ
    /// 名前は元のままである。
    pub fn get(self: *Core, heap: *Heap, id: SymbolId) Error!?Denotation {
        const entry = self.entries.getPtr(id) orelse return null;
        switch (entry.*) {
            .bound => |d| return d,
            .primitive => |p| {
                const cell = try heap.create(Cell, .{ .name = id, .value = .fromPrimitive(p) });
                entry.* = .{ .bound = .{ .global = cell } };
                return entry.bound;
            },
        }
    }

    /// Tells the collector of every cell the table has made.
    /// プリミティブのセルは、REPL やライブラリがその束縛を遮蔽しても、遮蔽の前に展開した
    /// コードが指し続けるので、ここが持ち続ける。
    pub fn mark(self: *const Core, marker: *Marker) void {
        var it = self.entries.valueIterator();
        while (it.next()) |entry| switch (entry.*) {
            .bound => |d| markDenotation(marker, d),
            .primitive => {},
        };
    }
};

/// Tells the collector of the heap object a denotation holds.
fn markDenotation(marker: *Marker, d: Denotation) void {
    switch (d) {
        .global => |cell| marker.object(Cell, cell),
        .macro => |m| marker.object(value_mod.Macro, m),
        .special, .local, .auxiliary => {},
    }
}

pub const Global = struct {
    /// The bindings of the top level, by name.
    bindings: std.AutoHashMapUnmanaged(SymbolId, Binding) = .empty,
    /// What the top level imports to begin with, or null for an empty top level.
    /// 表の束縛が先に引かれるので、名前を `Core` から写した後は、そこが引かれることは
    /// ない。
    base: ?*Core = null,
    /// The cells of the top level's own variables that had no value when a
    /// `define-syntax` or an `import` replaced them.
    /// ライブラリの本体の終わりに、未束縛として報告するために持つ(`library.unboundNames`)。
    /// 値を持つセルは持たない。前に展開したコードがまだ指していれば(R7RS 5.4: 既存の参照は
    /// 変わらない)、そのコードから辿られる(ADR-0040)。
    displaced_unbound: std.ArrayList(*Cell) = .empty,
    /// The syntactic bindings that the expansion in progress has replaced, with
    /// what each name was bound to before, in order.
    /// 特殊形式やマクロの名前への `define` と、`define-syntax` と `import` が記録する。
    /// 展開が失敗したら `undoShadows` が元に戻し、成功したら `commitShadows` が捨てる。
    replaced: std.ArrayList(Replaced) = .empty,

    /// A name, and its binding before the expansion replaced it; null when the
    /// table had none.
    const Replaced = struct { id: SymbolId, previous: ?Binding };

    /// Gives back what the table took from `alloc`, which must be the allocator
    /// every call that grew it was given.
    /// セルとマクロはヒープにあり、ここでは返さない。
    pub fn deinit(self: *Global, alloc: std.mem.Allocator) void {
        self.bindings.deinit(alloc);
        self.displaced_unbound.deinit(alloc);
        self.replaced.deinit(alloc);
        self.* = .{ .base = self.base };
    }

    /// Gives back the bindings that the expansion that failed replaced.
    ///
    /// Why: 展開が失敗した形式は実行されないので、その形式が作った遮蔽は、残すと特殊形式を
    /// 理由なく失わせる(`(define if (quote))` の後で `if` が未束縛になる)。`define-syntax`
    /// も同じで、残すと、失敗した行が定義したマクロが後の行の意味を変える。遮蔽したセルと
    /// マクロは表から外れ、次の GC で回収される。新しい順に戻すので、同じ名前を2回
    /// 置き換えた展開も、最初の束縛に戻る。この中の確保はしない(表の項目は既にある)。
    /// 値の式が実行時に失敗した場合は、展開が成功しているので、ここでは戻さない。
    pub fn undoShadows(self: *Global) void {
        while (self.replaced.pop()) |r| {
            if (r.previous) |b| {
                if (self.bindings.getPtr(r.id)) |slot| slot.* = b;
            } else {
                _ = self.bindings.remove(r.id);
            }
        }
    }

    /// Keeps what the expansion that succeeded replaced.
    pub fn commitShadows(self: *Global) void {
        self.replaced.clearRetainingCapacity();
    }

    /// Binds `id` to the macro `m` (R7RS 5.4), in place of whatever `id` was
    /// bound to.
    /// docs/design/frontend.md の REPL の表のとおり、インポートした束縛は遮蔽し、REPL
    /// 自身の束縛は差し替える。どちらも、表の束縛を REPL 自身のマクロにすることである。
    /// 前に展開したコードが指すセルは変わらない(同節: 既存の参照は変わらない)。
    /// 表から外れたセルは、指すコードが持つ。値の無い REPL 自身のセルだけは、未束縛の
    /// 報告のために `displaced_unbound` が持つ。
    pub fn defineSyntax(self: *Global, alloc: std.mem.Allocator, id: SymbolId, m: *value_mod.Macro) error{OutOfMemory}!void {
        try self.replace(alloc, id, .{ .denotation = .{ .macro = m }, .imported = false });
    }

    /// Binds `id` to `denotation`, which the top level imports, in place of
    /// whatever `id` was bound to.
    /// 遮蔽の扱いは `defineSyntax` と同じである。
    pub fn importBinding(self: *Global, alloc: std.mem.Allocator, id: SymbolId, denotation: Denotation) error{OutOfMemory}!void {
        try self.replace(alloc, id, .{ .denotation = denotation, .imported = true });
    }

    /// Puts `new` in place of the binding of `id`, and records what was there so
    /// that `undoShadows` can give it back.
    fn replace(self: *Global, alloc: std.mem.Allocator, id: SymbolId, new: Binding) error{OutOfMemory}!void {
        const previous = self.bindings.get(id);
        if (previous) |b| switch (b.denotation) {
            .global => |cell| if (!b.imported and cell.value.kind() == .uninitialized) try self.displaced_unbound.append(alloc, cell),
            .special, .macro, .local, .auxiliary => {},
        };
        try self.replaced.append(alloc, .{ .id = id, .previous = previous });
        try self.bindings.put(alloc, id, new);
    }

    /// The binding of `id` in the table itself, which is null for a name that is
    /// only in `base` or not bound at all.
    pub fn lookup(self: *const Global, id: SymbolId) ?Binding {
        return self.bindings.get(id);
    }

    /// Whether `id` is bound at the top level: a special form, a macro, an
    /// auxiliary syntax, or a variable with a value.
    /// 何も作らない。未束縛のセルは、束縛が無いことと同じに扱う。
    pub fn isBound(self: *const Global, id: SymbolId) bool {
        if (self.bindings.get(id)) |b| return switch (b.denotation) {
            .special, .macro, .auxiliary => true,
            .global => |cell| cell.value.kind() != .uninitialized,
            .local => unreachable,
        };
        return if (self.base) |core| core.contains(id) else false;
    }

    /// What `id` means at the top level.
    /// 表に無い名前には、この最上位自身の未束縛のセルを作る。
    pub fn resolve(self: *Global, alloc: std.mem.Allocator, heap: *Heap, id: SymbolId) Error!Denotation {
        return (try self.binding(alloc, heap, id)).denotation;
    }

    /// The cell that a `define` of `id` at the top level gives its value to.
    ///
    /// REPL 自身の変数なら、そのセルである(R7RS 5.3.1: 束縛済みで構文でない変数への
    /// 定義は代入と同じ)。インポートした変数なら、REPL の新しいセルで遮蔽する。
    /// 特殊形式やマクロの名前なら、新しい未束縛のセルで遮蔽する(同節: 構文キーワードへの
    /// 定義は新しい場所を束縛する)。この遮蔽は記録し、展開が失敗したら `undoShadows` が
    /// 戻す。
    pub fn defineTarget(self: *Global, alloc: std.mem.Allocator, heap: *Heap, id: SymbolId) Error!*Cell {
        const b = try self.binding(alloc, heap, id);
        return switch (b.denotation) {
            .global => |cell| if (b.imported) self.shadow(alloc, heap, id, cell.value) else cell,
            .special, .macro, .auxiliary => {
                try self.replaced.append(alloc, .{ .id = id, .previous = b });
                return self.shadow(alloc, heap, id, .uninitialized_value);
            },
            .local => unreachable,
        };
    }

    /// The cell that a `set!` of `id` at the top level assigns, or null when
    /// `id` names a special form, a macro or an auxiliary syntax, which cannot be
    /// assigned.
    /// REPL 自身の変数なら、そのセルである。インポートした変数なら、REPL の新しい
    /// セルで遮蔽する(frontend.md の REPL の表)。
    pub fn assignTarget(self: *Global, alloc: std.mem.Allocator, heap: *Heap, id: SymbolId) Error!?*Cell {
        const b = try self.binding(alloc, heap, id);
        return switch (b.denotation) {
            .global => |cell| if (b.imported) try self.shadow(alloc, heap, id, cell.value) else cell,
            .special, .macro, .auxiliary => null,
            .local => unreachable,
        };
    }

    /// Tells the collector of every cell and macro: those the table binds, the
    /// cells of its own that had no value when they were replaced, and what the
    /// expansion in progress has replaced; and of every name the table is keyed by.
    /// Why: 名前は、束縛の表のキーとして持つ生のシンボル ID である。マクロの束縛の名前は
    /// マクロ自身が持たないので、キーを知らせなければ、名前が回収されて ID が別の名前に
    /// 再利用され、表が別のシンボルの束縛を持つ。`replaced` の名前は、展開が失敗したときに
    /// 表を戻すキーで、表にもう無いことがある。
    pub fn mark(self: *const Global, marker: *Marker) void {
        var it = self.bindings.iterator();
        while (it.next()) |entry| {
            marker.symbol(entry.key_ptr.*);
            markDenotation(marker, entry.value_ptr.denotation);
        }
        for (self.displaced_unbound.items) |cell| marker.object(Cell, cell);
        for (self.replaced.items) |r| {
            marker.symbol(r.id);
            if (r.previous) |b| markDenotation(marker, b.denotation);
        }
    }

    /// The binding of `id`, made when there is none yet: what `base` exports under
    /// the name if it does, or else an unbound cell of the table's own.
    fn binding(self: *Global, alloc: std.mem.Allocator, heap: *Heap, id: SymbolId) Error!Binding {
        if (self.bindings.get(id)) |b| return b;
        if (self.base) |core| {
            if (try core.get(heap, id)) |d| {
                const b: Binding = .{ .denotation = d, .imported = true };
                try self.bindings.put(alloc, id, b);
                return b;
            }
        }
        return .{ .denotation = .{ .global = try self.shadow(alloc, heap, id, .uninitialized_value) }, .imported = false };
    }

    /// Binds `id` to a new cell of the top level's own holding `value`, in place of
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
    /// What the top level imports to begin with.
    core: Core = .{},
    global: Global = .{},

    fn init(self: *Fixture) void {
        self.arena = .init(std.testing.allocator);
        self.heap = .init(std.testing.allocator, .{});
        self.core = .{};
        self.global = .{ .base = &self.core };
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
    try f.core.addPrimitive(f.arena.allocator(), x, &probe);
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
    try f.core.addPrimitive(a, x, &probe);
    try f.core.addPrimitive(a, y, &probe);
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
    try f.core.addSyntax(f.arena.allocator(), x, .{ .special = .@"if" });
    try std.testing.expect(f.global.isBound(x));
    try std.testing.expectEqual(value_mod.Special.@"if", (try f.resolve(x)).special);
    try std.testing.expect(try f.assign(x) == null);
    try std.testing.expectEqual(value_mod.Special.@"if", (try f.resolve(x)).special);
    const cell = try f.define(x);
    try std.testing.expectEqual(value_mod.Kind.uninitialized, cell.value.kind());
    try std.testing.expectEqual(cell, (try f.resolve(x)).global);
    try std.testing.expect(!f.global.isBound(x));
}

test "the shadow of a special form is undone when the expansion fails, and kept when it succeeds" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    try f.core.addSyntax(f.arena.allocator(), x, .{ .special = .@"if" });
    try f.core.addSyntax(f.arena.allocator(), y, .{ .special = .lambda });
    _ = try f.define(x);
    _ = try f.define(y);
    try std.testing.expect(!f.global.isBound(x));
    f.global.undoShadows();
    try std.testing.expectEqual(value_mod.Special.@"if", (try f.resolve(x)).special);
    try std.testing.expectEqual(value_mod.Special.lambda, (try f.resolve(y)).special);
    // 成功した展開の遮蔽は残る。確定のあとの失敗は、それを戻さない。
    const kept = try f.define(x);
    f.global.commitShadows();
    f.global.undoShadows();
    try std.testing.expectEqual(kept, (try f.resolve(x)).global);
    // 同じ展開の中の2回目の定義は、REPL 自身の変数への定義なので、記録しない。
    try std.testing.expectEqual(kept, try f.define(x));
    f.global.undoShadows();
    try std.testing.expectEqual(kept, (try f.resolve(x)).global);
}

/// A macro for the tests: what it transcribes is never asked.
fn testMacro(heap: *Heap) !*value_mod.Macro {
    return heap.create(value_mod.Macro, .{ .literals = .empty_list_value, .rules = .empty_list_value, .env = null });
}

test "a define-syntax binds a macro, which is bound and cannot be assigned, and a define shadows it" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    const m = try testMacro(&f.heap);
    try f.global.defineSyntax(f.arena.allocator(), x, m);
    try std.testing.expect(f.global.isBound(x));
    try std.testing.expectEqual(m, (try f.resolve(x)).macro);
    try std.testing.expect(try f.assign(x) == null);
    // 構文キーワードへの定義は新しい場所を束縛する(R7RS 5.3.1)。
    const cell = try f.define(x);
    try std.testing.expectEqual(value_mod.Kind.uninitialized, cell.value.kind());
    try std.testing.expectEqual(cell, (try f.resolve(x)).global);
}

test "a define-syntax replaces a variable, whose cell then goes unless it has no value" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    const a = f.arena.allocator();
    const z: SymbolId = @fromBackingInt(@intCast(2));
    const own = try f.define(x);
    own.value = try f.heap.cons(.fromFixnum(1), .empty_list_value);
    try f.core.addPrimitive(a, y, &probe);
    const imported = (try f.resolve(y)).global;
    // 参照だけで作った、値の無い自分のセル。
    const unbound = (try f.resolve(z)).global;
    try f.global.defineSyntax(a, x, try testMacro(&f.heap));
    try f.global.defineSyntax(a, y, try testMacro(&f.heap));
    try f.global.defineSyntax(a, z, try testMacro(&f.heap));
    f.global.commitShadows();
    // 3つのセル、ペア、3つのマクロ。
    try std.testing.expectEqual(7, f.heap.count);
    f.heap.collect(Roots{ .global = &f.global, .core = &f.core });
    // 値を持つ自分のセルは、表から外れ、指すコードも無いので、ペアごと回収される。
    // インポートしたセルは `Core` が持つ。値の無いセルは、未束縛の報告のために残る。
    try std.testing.expectEqual(5, f.heap.count);
    try std.testing.expectEqual(&probe, imported.value.asPrimitive().?);
    try std.testing.expectEqual(1, f.global.displaced_unbound.items.len);
    try std.testing.expectEqual(unbound, f.global.displaced_unbound.items[0]);
}

test "a define-syntax that a failed expansion made is undone, and one that succeeded is kept" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    const a = f.arena.allocator();
    const first = try testMacro(&f.heap);
    try f.global.defineSyntax(a, x, first);
    f.global.commitShadows();
    // 同じ展開の中で、マクロをマクロで、次に変数で置き換えても、最初のマクロに戻る。
    try f.global.defineSyntax(a, x, try testMacro(&f.heap));
    _ = try f.define(x);
    // 束縛の無かった名前とインポートしたプリミティブの名前は、束縛の無い状態に戻る。
    try f.core.addPrimitive(a, y, &probe);
    try f.global.defineSyntax(a, y, try testMacro(&f.heap));
    const z: SymbolId = @fromBackingInt(@intCast(2));
    try f.global.defineSyntax(a, z, try testMacro(&f.heap));
    f.global.undoShadows();
    try std.testing.expectEqual(first, (try f.resolve(x)).macro);
    try std.testing.expectEqual(&probe, (try f.resolve(y)).global.value.asPrimitive().?);
    try std.testing.expectEqual(value_mod.Kind.uninitialized, (try f.resolve(z)).global.value.kind());
}

test "the macros the table binds survive a collection, and those it no longer binds do not" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    const a = f.arena.allocator();
    try f.global.defineSyntax(a, x, try testMacro(&f.heap));
    try f.global.defineSyntax(a, y, try testMacro(&f.heap));
    // 展開の途中では、置き換えた束縛も戻すために残す。
    _ = try f.define(y);
    f.heap.collect(Roots{ .global = &f.global, .core = &f.core });
    try std.testing.expectEqual(2, f.heap.countOf(value_mod.Macro));
    f.global.commitShadows();
    f.heap.collect(Roots{ .global = &f.global, .core = &f.core });
    try std.testing.expectEqual(1, f.heap.countOf(value_mod.Macro));
    try std.testing.expect((try f.resolve(x)).macro.rules.kind() == .empty_list);
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
    try f.core.addPrimitive(f.arena.allocator(), x, &probe);
    const imported = (try f.resolve(x)).global;
    const own = try f.define(x);
    own.value = try f.heap.cons(.fromFixnum(1), .empty_list_value);
    _ = try f.heap.cons(.fromFixnum(2), .empty_list_value);
    // インポートしたセル、遮蔽したセル、2つのペア。
    try std.testing.expectEqual(4, f.heap.count);
    f.heap.collect(Roots{ .global = &f.global, .core = &f.core });
    // 到達できないペアだけが回収される。遮蔽されたセルは、コードがまだ指しうるので残る。
    try std.testing.expectEqual(3, f.heap.count);
    try std.testing.expectEqual(&probe, imported.value.asPrimitive().?);
    try std.testing.expectEqual(1, own.value.asPair().?.car.asFixnum().?);
}

const Roots = struct {
    global: *const Global,
    core: *const Core,

    pub fn mark(self: Roots, marker: *Marker) void {
        self.global.mark(marker);
        self.core.mark(marker);
    }
};

test "a cell that does not fit the heap is the heap's error, and leaves the name as it was" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var heap: Heap = .init(std.testing.allocator, .{ .limit = 1 });
    defer heap.deinit();
    var core: Core = .{};
    try core.addPrimitive(arena.allocator(), x, &probe);
    var g: Global = .{ .base = &core };
    try std.testing.expectError(error.HeapLimit, g.resolve(arena.allocator(), &heap, x));
    try std.testing.expectError(error.HeapLimit, g.defineTarget(arena.allocator(), &heap, y));
    try std.testing.expect(g.isBound(x));
    try std.testing.expect(g.bindings.count() == 0);
}

test "an auxiliary syntax is bound and cannot be assigned, and a define shadows it with an unbound cell" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    try f.core.addSyntax(f.arena.allocator(), x, .{ .auxiliary = .@"else" });
    try std.testing.expect(f.global.isBound(x));
    try std.testing.expectEqual(value_mod.Auxiliary.@"else", (try f.resolve(x)).auxiliary);
    try std.testing.expect(try f.assign(x) == null);
    // 補助構文の名前への定義は、特殊形式と同じく、新しい場所を束縛する(R7RS 5.3.1)。
    const cell = try f.define(x);
    try std.testing.expectEqual(value_mod.Kind.uninitialized, cell.value.kind());
    try std.testing.expectEqual(cell, (try f.resolve(x)).global);
    // 展開が失敗したときは、補助構文に戻る。
    f.global.undoShadows();
    try std.testing.expectEqual(value_mod.Auxiliary.@"else", (try f.resolve(x)).auxiliary);
}

test "tables that import from the same core share the cell of a primitive" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    try f.core.addPrimitive(f.arena.allocator(), x, &probe);
    var other: Global = .{ .base = &f.core };
    defer other.bindings.deinit(f.arena.allocator());
    const first = (try f.resolve(x)).global;
    const second = (try other.resolve(f.arena.allocator(), &f.heap, x)).global;
    // 同じセルである。別々のセルだと、同じ束縛を `free-identifier=?` が別と判定する。
    try std.testing.expectEqual(first, second);
    try std.testing.expectEqual(1, f.heap.count);
    // 一方の遮蔽は、他方に見えない。
    const shadow = try f.define(x);
    try std.testing.expect(shadow != first);
    try std.testing.expectEqual(first, (try other.resolve(f.arena.allocator(), &f.heap, x)).global);
}

test "a name that only core exports is bound without a cell being made, and an empty table binds nothing" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    try f.core.addPrimitive(f.arena.allocator(), x, &probe);
    try std.testing.expect(f.global.isBound(x));
    try std.testing.expect(!f.global.isBound(y));
    try std.testing.expectEqual(0, f.heap.count);
    try std.testing.expectEqual(null, f.global.lookup(x));
    var empty: Global = .{};
    try std.testing.expect(!empty.isBound(x));
}

test "an import replaces a binding, lets the variable it replaced go with the code, and is undone with the expansion" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    const a = f.arena.allocator();
    try f.core.addPrimitive(a, y, &probe);
    const own = try f.define(x);
    own.value = try f.heap.cons(.fromFixnum(1), .empty_list_value);
    f.global.commitShadows();
    const imported = (try f.resolve(y)).global;
    try f.global.importBinding(a, x, .{ .global = imported });
    // 名前は、インポートした束縛になる。
    const b = f.global.lookup(x).?;
    try std.testing.expect(b.imported);
    try std.testing.expectEqual(imported, b.denotation.global);
    f.global.commitShadows();
    // 置き換えられた REPL 自身の変数は、指すコードが無ければ、ペアごと回収される。
    const before = f.heap.count;
    f.heap.collect(Roots{ .global = &f.global, .core = &f.core });
    try std.testing.expectEqual(before - 2, f.heap.count);
    try std.testing.expectEqual(0, f.global.displaced_unbound.items.len);
    // 失敗した展開のインポートは、元の束縛に戻る。束縛の無かった名前は、束縛の無い状態に戻る。
    const z: SymbolId = @fromBackingInt(@intCast(2));
    try f.global.importBinding(a, x, .{ .special = .@"if" });
    try f.global.importBinding(a, z, .{ .special = .lambda });
    f.global.undoShadows();
    try std.testing.expectEqual(imported, (try f.resolve(x)).global);
    try std.testing.expectEqual(null, f.global.lookup(z));
}

test "the names a table is keyed by survive a collection, though nothing else holds them" {
    for ([_]usize{ 4096, 0 }) |capacity| {
        var f: Fixture = undefined;
        f.init();
        f.heap.options.work_capacity = capacity;
        defer f.deinit();
        const arena = f.arena.allocator();
        // 束縛が生きたオブジェクトを持たない名前は、キーだけが ID の持ち主である。
        const imported = try f.heap.intern("imported-key");
        try f.global.importBinding(arena, imported, .{ .special = .@"if" });
        // 展開が置き換えた名前は、表を戻すためのキーで、表にもう無いことがある。
        const replaced = try f.heap.intern("replaced-key");
        try f.global.replaced.append(arena, .{ .id = replaced, .previous = null });
        const unrelated = try f.heap.intern("unrelated");
        f.heap.collect(Roots{ .global = &f.global, .core = &f.core });
        for (0..16) |i| _ = try f.heap.intern(&[_]u8{ 'a' + @as(u8, @intCast(i)), 'z' });
        try std.testing.expectEqualStrings("imported-key", f.heap.symbols.nameOf(imported));
        try std.testing.expectEqualStrings("replaced-key", f.heap.symbols.nameOf(replaced));
        try std.testing.expect(f.heap.symbols.lookup("unrelated") == null);
        _ = unrelated;
    }
}
