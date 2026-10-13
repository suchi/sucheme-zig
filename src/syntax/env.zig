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

pub const SyntacticEnv = value_mod.SyntacticEnv;
pub const SyntacticBinding = value_mod.SyntacticBinding;
pub const LocalBinding = value_mod.LocalBinding;
pub const Denotation = value_mod.Denotation;
pub const Special = value_mod.Special;
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
/// シンボルの名前で REPL の最上位の束縛を引く。最上位の表に無い名前には、REPL 自身の
/// 未束縛のセルを作る(src/env.zig)。確保しうるのはその場合だけである。
pub fn resolve(ctx: *Context, env: ?*const SyntacticEnv, id: Value) Error!Denotation {
    var e = env;
    var ident = id;
    while (true) {
        var scope = e;
        while (scope) |s| : (scope = s.parent) {
            if (lookupRib(s, ident)) |binding| return binding.denotation;
        }
        const alias = ident.asAlias() orelse break;
        ident = alias.inner;
        e = alias.env;
    }
    return ctx.globals.resolve(ctx.persist, &ctx.heap, ident.asSymbol().?) catch |err| ctx.heapFailure(err);
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
