//! The syntactic environment: what an identifier means where the expander
//! meets it (ADR-0019, docs/design/frontend.md).
//!
//! 環境のレイアウトは src/value.zig にある(GC がたどるものはすべてそこで定義する)。
//! このファイルは、環境を作り、束縛を足し、識別子を解決する。
//!
//! 解決は、内側の環境から外へ、各 rib の束縛を新しいものから順に線形に探し、
//! 見つからなければ REPL の最上位の束縛の表(src/env.zig)を名前で引く。最上位の
//! 束縛は、特殊形式、マクロ、大域変数のセルである。特殊形式の名前は予約語ではないので、
//! 仮引数や本体の定義が同じ綴りを束縛すれば、その内側では特殊形式が隠れる。
//!
//! 識別子は、シンボルか、マクロのテンプレートが導入した別名(`Alias`)である。別名が
//! 環境に束縛されていなければ、内側の識別子を、マクロを定義した環境で解決し直す
//! (docs/design/frontend.md の解決規則)。

const std = @import("std");
const value_mod = @import("../value.zig");
const Value = value_mod.Value;
const context = @import("../context.zig");
const Context = context.Context;
const env_mod = @import("../env.zig");

pub const SyntacticEnv = value_mod.SyntacticEnv;
pub const SyntacticBinding = value_mod.SyntacticBinding;
pub const LocalBinding = value_mod.LocalBinding;
pub const Denotation = value_mod.Denotation;
pub const Special = value_mod.Special;
pub const Auxiliary = value_mod.Auxiliary;
pub const Alias = value_mod.Alias;
pub const Macro = value_mod.Macro;
const SymbolId = @import("../symbol.zig").SymbolId;

pub const Error = context.Error;

/// A new environment with an empty rib, inside `parent` (null at the top level).
/// rib の深さは外側より 1 大きい。幅を超える深さは実装制限(R7RS 1.3.2)として報告する。
pub fn extend(ctx: *Context, parent: ?*SyntacticEnv) Error!*SyntacticEnv {
    const depth = std.math.add(u32, ribDepth(parent), 1) catch
        return ctx.raise("implementation restriction: procedures are nested too deeply", .{});
    return ctx.create(SyntacticEnv, .{ .parent = parent, .rib_depth = depth, .bindings = null });
}

/// A new environment inside `parent` (null at the top level) that adds bindings
/// but no rib.
/// rib の深さは外側と同じである。局所変数の字句アドレスは rib の深さの差で求めるので、
/// ここで深さを増やすと、この環境の内側から外側の変数を参照したときの深さが1大きくなり、
/// 存在しない rib をたどる(docs/design/frontend.md)。`let-syntax` と `letrec-syntax` が、
/// マクロの束縛を置くために使う。
pub fn extendWithoutRib(ctx: *Context, parent: ?*SyntacticEnv) Error!*SyntacticEnv {
    return ctx.create(SyntacticEnv, .{ .parent = parent, .rib_depth = ribDepth(parent), .bindings = null });
}

/// The rib depth of `env`; the top level is 0.
pub fn ribDepth(env: ?*const SyntacticEnv) u32 {
    return if (env) |e| e.rib_depth else 0;
}

/// Binds `id` in the rib of `env` to a new local variable in slot `index`, and
/// returns that variable.
/// 新しい束縛は rib の先頭に置くので、同じ rib にある同じ識別子の前の束縛を隠す。
pub fn bindLocal(ctx: *Context, env: *SyntacticEnv, id: Value, index: u32) Error!*LocalBinding {
    const local = try ctx.create(LocalBinding, .{ .rib_depth = env.rib_depth, .index = index });
    env.bindings = try ctx.create(SyntacticBinding, .{ .id = id, .denotation = .{ .local = local }, .next = env.bindings });
    return local;
}

/// Binds `id` in the rib of `env` to the macro `m`.
/// 局所変数と違ってスロットを取らない。`define-syntax` が本体の先頭で使う。
pub fn bindMacro(ctx: *Context, env: *SyntacticEnv, id: Value, m: *Macro) Error!void {
    env.bindings = try ctx.create(SyntacticBinding, .{ .id = id, .denotation = .{ .macro = m }, .next = env.bindings });
}

/// The newest binding of `id` in the rib of `env` itself, not in the
/// environments around it.
pub fn lookupRib(env: *const SyntacticEnv, id: Value) ?*SyntacticBinding {
    var b = env.bindings;
    while (b) |binding| : (b = binding.next) {
        if (boundIdentifierEq(binding.id, id)) return binding;
    }
    return null;
}

/// What `id` means in `env` (docs/design/frontend.md, the rules of
/// resolution).
/// `id` は識別子でなければならない。構文環境に束縛が無く、`id` が別名なら、別名を
/// 1段剥がした内側の識別子を、別名の環境(マクロを定義した環境)で解決し直す。別名
/// 自身でなく内側を渡すので、剥がすたびに別名の層が1つ減り、必ず止まる。最後は、
/// シンボルの名前で、その環境の最上位の束縛を引く(`topTable`)。最上位の表に無い名前には、
/// その最上位自身の未束縛のセルを作る(src/env.zig)。確保しうるのはその場合だけである。
pub fn resolve(ctx: *Context, env: ?*const SyntacticEnv, id: Value) Error!Denotation {
    return (try resolveAt(ctx, env, id)).denotation;
}

/// What an identifier means, and where a name that no environment binds was
/// looked up.
pub const Resolution = struct {
    denotation: Denotation,
    /// The table of the top level the name was looked up in, or null when an
    /// environment bound the identifier.
    table: ?*env_mod.Global,
    /// The name looked up in `table`: the innermost symbol of the identifier.
    symbol: SymbolId,
};

/// What `id` means in `env`, and the top level it was resolved in, if it was
/// resolved to the top level.
/// 別名の環境が別のライブラリのものなら、最上位の表もそのライブラリのものである。
/// `set!` が、REPL 自身の束縛と、マクロが持ち込んだ別のライブラリの束縛を分けるために
/// 使う。
pub fn resolveAt(ctx: *Context, env: ?*const SyntacticEnv, id: Value) Error!Resolution {
    var e = env;
    var ident = id;
    while (true) {
        var scope = e;
        var root = e;
        while (scope) |s| : (scope = s.parent) {
            if (lookupRib(s, ident)) |binding| return .{ .denotation = binding.denotation, .table = null, .symbol = baseSymbol(ident) };
            root = s;
        }
        const alias = ident.asAlias() orelse {
            const table = topTable(ctx, root);
            const symbol = ident.asSymbol().?;
            return .{
                .denotation = table.resolve(ctx.persist, &ctx.heap, symbol) catch |err| return ctx.heapFailure(err),
                .table = table,
                .symbol = symbol,
            };
        };
        ident = alias.inner;
        e = alias.env;
    }
}

/// The table of the top level that the environment with the root `root` is in:
/// the library's, or the REPL's when `root` is not the root of a library.
/// `root` は環境の鎖のいちばん外側である(鎖が空なら null)。
pub fn topTable(ctx: *Context, root: ?*const SyntacticEnv) *env_mod.Global {
    if (root) |r| if (r.library) |lib| return ctx.libraries.tableOf(lib);
    return &ctx.globals;
}

/// The outermost environment of the chain that starts at `env`, when it is the
/// root of a library body; null for the REPL's top level.
/// 識別子を最上位で引くときの環境として使う。REPL の環境の鎖は、根を持たない。
pub fn topOf(env: ?*const SyntacticEnv) ?*const SyntacticEnv {
    var scope = env;
    var root: ?*const SyntacticEnv = null;
    while (scope) |s| : (scope = s.parent) root = s;
    if (root) |r| if (r.library != null) return r;
    return null;
}

/// Whether `v` is an identifier: a symbol or an alias.
pub fn isIdentifier(v: Value) bool {
    return v.kind() == .symbol or v.kind() == .alias;
}

/// The symbol an identifier was written as: an alias's innermost identifier.
/// メッセージと、局所変数の名前と、`quote` の剥離が使う。`id` は識別子でなければならない。
pub fn baseSymbol(id: Value) SymbolId {
    var v = id;
    while (v.asAlias()) |a| v = a.inner;
    return v.asSymbol().?;
}

/// Whether `a` and `b` are the same identifier in the sense of
/// `bound-identifier=?`: a binding of one would bind the other.
/// 一致するのは、両方がシンボルで同じシンボルのときと、両方が別名で、印と環境が
/// 同じで、内側の識別子どうしが一致するときに限る。種類の違う対は一致しない。
/// Why: 素のシンボルと別名を一致させると、マクロが導入した別名の束縛を、利用側の
/// 同じ綴りのシンボルが引き当て、衛生性が壊れる(docs/design/frontend.md の解決規則)。
pub fn boundIdentifierEq(a: Value, b: Value) bool {
    var x = a;
    var y = b;
    while (true) {
        if (x.asSymbol()) |sx| {
            const sy = y.asSymbol() orelse return false;
            return sx == sy;
        }
        const ax = x.asAlias() orelse return false;
        const ay = y.asAlias() orelse return false;
        if (ax == ay) return true;
        if (ax.mark != ay.mark or ax.env != ay.env) return false;
        x = ax.inner;
        y = ay.inner;
    }
}

/// Whether two denotations are the same binding, which is how
/// `free-identifier=?` compares identifiers (docs/design/frontend.md, comparing
/// identifiers).
/// 局所変数、セル、マクロはオブジェクトの同一性で比べる(ADR-0019)。最上位で
/// 束縛の無い名前は、名前ごとに1つの未束縛のセルに解決されるので、名前が同じなら
/// 同じセルになり、R7RS 4.3.2 の「どちらも束縛が無く、同じ識別子」の場合を含む。
pub fn sameDenotation(a: Denotation, b: Denotation) bool {
    return switch (a) {
        .special => |x| switch (b) {
            .special => |y| x == y,
            else => false,
        },
        .local => |x| switch (b) {
            .local => |y| x == y,
            else => false,
        },
        .global => |x| switch (b) {
            .global => |y| x == y,
            else => false,
        },
        .macro => |x| switch (b) {
            .macro => |y| x == y,
            else => false,
        },
        .auxiliary => |x| switch (b) {
            .auxiliary => |y| x == y,
            else => false,
        },
    };
}

test {
    std.testing.refAllDecls(@This());
}

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

    fn id(self: *Fixture, name: []const u8) !Value {
        return .fromSymbol(try self.ctx.symbols.intern(self.arena.allocator(), name));
    }
};

test "boundIdentifierEq matches the same symbol and nothing else" {
    const a: Value = .fromSymbol(@fromBackingInt(@intCast(1)));
    const b: Value = .fromSymbol(@fromBackingInt(@intCast(2)));
    try std.testing.expect(boundIdentifierEq(a, a));
    try std.testing.expect(!boundIdentifierEq(a, b));
    try std.testing.expect(!boundIdentifierEq(b, a));
    // 識別子でないものは、どれとも一致しない。同じ値どうしでもそうである。
    try std.testing.expect(!boundIdentifierEq(.fromFixnum(1), .fromFixnum(1)));
    try std.testing.expect(!boundIdentifierEq(a, .fromFixnum(1)));
    try std.testing.expect(!boundIdentifierEq(.fromFixnum(1), a));
}

test "at the top level a special form's name means the special form, and any other name a global" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    inline for (@typeInfo(Special).@"enum".field_names) |name| {
        const d = try resolve(&f.ctx, null, try f.id(name));
        try std.testing.expectEqual(@field(Special, name), d.special);
    }
    const x = try f.id("x");
    const cell = (try resolve(&f.ctx, null, x)).global;
    try std.testing.expectEqual(x.asSymbol().?, cell.name);
    try std.testing.expectEqual(cell, (try resolve(&f.ctx, null, x)).global);
    // プリミティブの名前も大域変数である。
    const plus = try f.id("+");
    try std.testing.expectEqualStrings("+", (try resolve(&f.ctx, null, plus)).global.value.asPrimitive().?.name);
}

test "a rib's binding hides the special form, the global and an outer rib's binding of the same name" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const @"if" = try f.id("if");
    const x = try f.id("x");
    const outer = try extend(&f.ctx, null);
    try std.testing.expectEqual(1, outer.rib_depth);
    const outer_if = try bindLocal(&f.ctx, outer, @"if", 0);
    const outer_x = try bindLocal(&f.ctx, outer, x, 1);
    const inner = try extend(&f.ctx, outer);
    try std.testing.expectEqual(2, inner.rib_depth);
    const inner_x = try bindLocal(&f.ctx, inner, x, 0);
    try std.testing.expectEqual(outer_if, (try resolve(&f.ctx, inner, @"if")).local);
    try std.testing.expectEqual(inner_x, (try resolve(&f.ctx, inner, x)).local);
    try std.testing.expectEqual(outer_x, (try resolve(&f.ctx, outer, x)).local);
    try std.testing.expectEqual(Special.@"if", (try resolve(&f.ctx, null, @"if")).special);
    // 局所束縛は、それを導入した rib の絶対深さと、スロットを持つ。
    try std.testing.expectEqual(1, outer_x.rib_depth);
    try std.testing.expectEqual(1, outer_x.index);
    try std.testing.expectEqual(2, inner_x.rib_depth);
}

test "an environment without a rib has the depth of the one around it, and hides what it binds" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const x = try f.id("x");
    const outer = try extend(&f.ctx, null);
    const local = try bindLocal(&f.ctx, outer, x, 0);
    const scope = try extendWithoutRib(&f.ctx, outer);
    try std.testing.expectEqual(outer.rib_depth, scope.rib_depth);
    try std.testing.expectEqual(0, ribDepth(try extendWithoutRib(&f.ctx, null)));
    // 外側の rib の束縛は、そのまま見える。ここでの束縛は外側を隠し、外側には見えない。
    try std.testing.expectEqual(local, (try resolve(&f.ctx, scope, x)).local);
    var m: value_mod.Macro = .{ .literals = .empty_list_value, .rules = .empty_list_value, .env = scope };
    try bindMacro(&f.ctx, scope, x, &m);
    try std.testing.expectEqual(&m, (try resolve(&f.ctx, scope, x)).macro);
    try std.testing.expectEqual(local, (try resolve(&f.ctx, outer, x)).local);
    // rib を足すと、深さはその分だけ増える。
    try std.testing.expectEqual(outer.rib_depth + 1, (try extend(&f.ctx, scope)).rib_depth);
}

test "a later binding in the same rib hides an earlier one, and each binding is its own object" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const x = try f.id("x");
    const env = try extend(&f.ctx, null);
    const first = try bindLocal(&f.ctx, env, x, 0);
    const second = try bindLocal(&f.ctx, env, x, 1);
    try std.testing.expect(first != second);
    try std.testing.expectEqual(second, (try resolve(&f.ctx, env, x)).local);
    try std.testing.expectEqual(second, lookupRib(env, x).?.denotation.local);
    try std.testing.expect(lookupRib(env, try f.id("y")) == null);
    // 外側の rib は lookupRib の対象ではない。
    const inner = try extend(&f.ctx, env);
    try std.testing.expect(lookupRib(inner, x) == null);
}

test "the environments live in the heap and are collected when nothing refers to them" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const before = f.ctx.heap.count;
    const env = try extend(&f.ctx, null);
    _ = try bindLocal(&f.ctx, env, try f.id("x"), 0);
    // 環境、束縛、局所束縛の3つである。
    try std.testing.expectEqual(before + 3, f.ctx.heap.count);
    f.ctx.collectIdle();
    try std.testing.expectEqual(before, f.ctx.heap.count);
}

test "an environment that does not fit the heap is the error heap limit exceeded" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var ctx = try Context.initWithOptions(arena.allocator(), std.testing.allocator, .{ .limit = 1 });
    defer ctx.deinit();
    try std.testing.expectError(error.Raised, extend(&ctx, null));
    try std.testing.expectEqualStrings("heap limit exceeded", ctx.diagnostic());
}

test "an alias is the same identifier only as an alias with the same inner identifier, mark and environment" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const tmp = try f.id("tmp");
    const other = try f.id("other");
    const env = try extend(&f.ctx, null);
    var a: Alias = .{ .inner = tmp, .env = env, .mark = 1 };
    // 別のオブジェクトでも、3つが同じなら同じ識別子である。
    var same: Alias = .{ .inner = tmp, .env = env, .mark = 1 };
    var other_mark: Alias = .{ .inner = tmp, .env = env, .mark = 2 };
    var other_env: Alias = .{ .inner = tmp, .env = null, .mark = 1 };
    var other_inner: Alias = .{ .inner = other, .env = env, .mark = 1 };
    const av: Value = .fromAlias(&a);
    try std.testing.expect(boundIdentifierEq(av, av));
    try std.testing.expect(boundIdentifierEq(av, .fromAlias(&same)));
    try std.testing.expect(boundIdentifierEq(.fromAlias(&same), av));
    try std.testing.expect(!boundIdentifierEq(av, .fromAlias(&other_mark)));
    try std.testing.expect(!boundIdentifierEq(av, .fromAlias(&other_env)));
    try std.testing.expect(!boundIdentifierEq(av, .fromAlias(&other_inner)));
    // 素のシンボルとは、綴りが同じでも、どちら向きにも一致しない(衛生性の要)。
    try std.testing.expect(!boundIdentifierEq(av, tmp));
    try std.testing.expect(!boundIdentifierEq(tmp, av));
    // 入れ子の別名は、外側から順に比べ、内側まで一致しなければならない。
    var outer: Alias = .{ .inner = av, .env = null, .mark = 3 };
    var outer_same: Alias = .{ .inner = .fromAlias(&same), .env = null, .mark = 3 };
    var outer_of_other: Alias = .{ .inner = .fromAlias(&other_mark), .env = null, .mark = 3 };
    try std.testing.expect(boundIdentifierEq(.fromAlias(&outer), .fromAlias(&outer_same)));
    try std.testing.expect(!boundIdentifierEq(.fromAlias(&outer), .fromAlias(&outer_of_other)));
    try std.testing.expect(!boundIdentifierEq(.fromAlias(&outer), av));
    try std.testing.expect(!boundIdentifierEq(.fromAlias(&outer), tmp));
}

test "an identifier is a symbol or an alias, and its base symbol is the innermost one" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const tmp = try f.id("tmp");
    var a: Alias = .{ .inner = tmp, .env = null, .mark = 0 };
    var b: Alias = .{ .inner = .fromAlias(&a), .env = null, .mark = 1 };
    try std.testing.expect(isIdentifier(tmp));
    try std.testing.expect(isIdentifier(.fromAlias(&b)));
    try std.testing.expect(!isIdentifier(.fromFixnum(1)));
    try std.testing.expect(!isIdentifier(.empty_list_value));
    try std.testing.expectEqual(tmp.asSymbol().?, baseSymbol(tmp));
    try std.testing.expectEqual(tmp.asSymbol().?, baseSymbol(.fromAlias(&b)));
}

test "an alias that the environments do not bind is resolved as its inner identifier in its own environment" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const x = try f.id("x");
    // マクロを定義した環境が x を束縛し、利用側の内側の環境も x を束縛する。
    const definition = try extend(&f.ctx, null);
    const defined_x = try bindLocal(&f.ctx, definition, x, 0);
    const use = try extend(&f.ctx, definition);
    const used_x = try bindLocal(&f.ctx, use, x, 0);
    var alias: Alias = .{ .inner = x, .env = definition, .mark = 7 };
    const av: Value = .fromAlias(&alias);
    // 利用側の x は、別名の x を捕まえない。別名は定義側の x を指す。
    try std.testing.expectEqual(used_x, (try resolve(&f.ctx, use, x)).local);
    try std.testing.expectEqual(defined_x, (try resolve(&f.ctx, use, av)).local);
    // 別名そのものを束縛した rib があれば、それが先である。
    const inner = try extend(&f.ctx, use);
    const bound_alias = try bindLocal(&f.ctx, inner, av, 0);
    try std.testing.expectEqual(bound_alias, (try resolve(&f.ctx, inner, av)).local);
    try std.testing.expectEqual(used_x, (try resolve(&f.ctx, inner, x)).local);
    // 最上位で定義したマクロの別名は、最上位の束縛を名前で引く。特殊形式も同じである。
    var top_if: Alias = .{ .inner = try f.id("if"), .env = null, .mark = 8 };
    _ = try bindLocal(&f.ctx, inner, try f.id("if"), 1);
    try std.testing.expectEqual(Special.@"if", (try resolve(&f.ctx, inner, .fromAlias(&top_if))).special);
    // 2段の別名は、1段ずつ剥がす。
    var twice: Alias = .{ .inner = av, .env = null, .mark = 9 };
    try std.testing.expectEqual(defined_x, (try resolve(&f.ctx, use, .fromAlias(&twice))).local);
}

test "sameDenotation is the identity of the binding, and different kinds are never the same" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const env = try extend(&f.ctx, null);
    const a = try bindLocal(&f.ctx, env, try f.id("a"), 0);
    // 同じ位置の別の束縛は、別の意味である(ADR-0019)。
    const twin = try f.ctx.create(LocalBinding, .{ .rib_depth = a.rib_depth, .index = a.index });
    const cell_x = (try resolve(&f.ctx, null, try f.id("x"))).global;
    const cell_y = (try resolve(&f.ctx, null, try f.id("y"))).global;
    const m = try f.ctx.create(Macro, .{ .literals = .empty_list_value, .rules = .empty_list_value, .env = null });
    const n = try f.ctx.create(Macro, .{ .literals = .empty_list_value, .rules = .empty_list_value, .env = null });
    const all = [_]Denotation{
        .{ .special = .@"if" }, .{ .special = .lambda },
        .{ .local = a },        .{ .local = twin },
        .{ .global = cell_x },  .{ .global = cell_y },
        .{ .macro = m },        .{ .macro = n },
    };
    for (all, 0..) |p, i| {
        for (all, 0..) |q, j| try std.testing.expectEqual(i == j, sameDenotation(p, q));
    }
    // 束縛の無い同じ名前は、同じ未束縛のセルに解決されるので、同じ意味である。
    try std.testing.expect(sameDenotation(.{ .global = cell_x }, try resolve(&f.ctx, env, try f.id("x"))));
}

test "a macro bound in a rib takes no slot and hides what is outside" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const m = try f.ctx.create(Macro, .{ .literals = .empty_list_value, .rules = .empty_list_value, .env = null });
    const env = try extend(&f.ctx, null);
    const @"if" = try f.id("if");
    try bindMacro(&f.ctx, env, @"if", m);
    try std.testing.expectEqual(m, (try resolve(&f.ctx, env, @"if")).macro);
    try std.testing.expectEqual(m, lookupRib(env, @"if").?.denotation.macro);
    try std.testing.expectEqual(Special.@"if", (try resolve(&f.ctx, null, @"if")).special);
}
