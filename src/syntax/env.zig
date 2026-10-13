//! The syntactic environment: what an identifier means where the expander
//! meets it (ADR-0019, docs/design/frontend.md).
//!
//! 環境のレイアウトは src/value.zig にある(GC がたどるものはすべてそこで定義する)。
//! このファイルは、環境を作り、束縛を足し、識別子を解決する。
//!
//! 解決は、内側の環境から外へ、各 rib の束縛を新しいものから順に線形に探し、
//! 見つからなければ REPL の最上位の束縛を引く。最上位の束縛は、特殊形式の名前の表
//! (`Context.specials`)と、名前で探す大域変数である。特殊形式の名前は予約語ではない
//! ので、仮引数や本体の定義が同じ綴りを束縛すれば、その内側では特殊形式が隠れる。

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
/// 構文環境に束縛が無ければ、REPL の最上位の束縛になる。特殊形式の名前の表に無い
/// 名前は大域変数で、機械が実行するときに名前で探す。
pub fn resolve(ctx: *const Context, env: ?*const SyntacticEnv, id: Value) Denotation {
    var e = env;
    while (e) |scope| : (e = scope.parent) {
        if (lookupRib(scope, id)) |binding| return binding.denotation;
    }
    const name = id.asSymbol().?;
    if (ctx.specials.get(name)) |special| return .{ .special = special };
    return .{ .global = name };
}

/// Whether `a` and `b` are the same identifier in the sense of
/// `bound-identifier=?`: a binding of one would bind the other.
/// 段階2の識別子はシンボルだけなので、両方がシンボルで、同じシンボルのときに限る。
/// 別名(2k)が入ったら、種類の違う対を一致させない規則(frontend.md)をここに足す。
pub fn boundIdentifierEq(a: Value, b: Value) bool {
    const x = a.asSymbol() orelse return false;
    const y = b.asSymbol() orelse return false;
    return x == y;
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
        const d = resolve(&f.ctx, null, try f.id(name));
        try std.testing.expectEqual(@field(Special, name), d.special);
    }
    const x = try f.id("x");
    try std.testing.expectEqual(x.asSymbol().?, resolve(&f.ctx, null, x).global);
    // プリミティブの名前も大域変数である。
    const plus = try f.id("+");
    try std.testing.expectEqual(plus.asSymbol().?, resolve(&f.ctx, null, plus).global);
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
    try std.testing.expectEqual(outer_if, resolve(&f.ctx, inner, @"if").local);
    try std.testing.expectEqual(inner_x, resolve(&f.ctx, inner, x).local);
    try std.testing.expectEqual(outer_x, resolve(&f.ctx, outer, x).local);
    try std.testing.expectEqual(Special.@"if", resolve(&f.ctx, null, @"if").special);
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
    try std.testing.expectEqual(second, resolve(&f.ctx, env, x).local);
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
