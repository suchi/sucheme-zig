//! Which clause of a `cond-expand` applies (R7RS 4.2.1 and 5.6.1,
//! docs/design/frontend.md, the feature requirements).
//!
//! 式の位置と、ライブラリ宣言の位置の両方が、ここで節を選ぶ。選んだ節の本体を、前者は式と
//! して、後者は宣言として処理するのは、呼び出し側である。

const std = @import("std");
const value_mod = @import("../value.zig");
const Value = value_mod.Value;
const context = @import("../context.zig");
const Context = context.Context;
const features = @import("../features.zig");
const resolve = @import("../resolve.zig");
const library = @import("library.zig");
const source = @import("source.zig");
const syntax_env = @import("env.zig");

pub const Error = context.Error;

/// The deepest nesting of `and`, `or` and `not` in a feature requirement.
/// Why: 要求の入れ子は、リーダが読める深さまで、入力が決める。評価は再帰するので、Zig の
/// スタックを使い切らないよう、実装制限として報告する。
pub const max_depth = 64;

/// The body of the first clause of `clauses` that applies, which is the clause
/// without its requirement, or null when none applies.
/// 節は `(<feature requirement> <body>...)` と、最後の `(else <body>...)` である。どの節も
/// 当てはまらず `else` も無いときの結果は、R7RS が定めていない(原文は未確認)。ここでは
/// 呼び出し側が決められるよう、null を返す。
pub fn select(ctx: *Context, scratch: std.mem.Allocator, clauses: []const Value) Error!?Value {
    for (clauses, 0..) |clause, i| {
        const pair = clause.asPair() orelse
            return ctx.raise("bad cond-expand: a clause is (<feature requirement> <body> ...) or (else <body> ...)", .{});
        if (isKeyword(ctx, pair.car, "else")) {
            if (i + 1 != clauses.len) return ctx.raise("bad cond-expand: the else clause must be the last", .{});
            return pair.cdr;
        }
        if (try evaluate(ctx, scratch, pair.car, 0)) return pair.cdr;
    }
    return null;
}

/// Whether the feature requirement `requirement` is true.
/// 識別子はビルドの一覧にあれば真、`(library <name>)` はインポートできれば真、`and` `or`
/// `not` は結合子である。部分の要求は、短絡せずにすべて調べる。後ろの部分の誤りを、前の部分
/// が真偽を決めたからといって見逃さないためである。
fn evaluate(ctx: *Context, scratch: std.mem.Allocator, requirement: Value, depth: usize) Error!bool {
    if (syntax_env.isIdentifier(requirement)) return features.has(ctx.symbols.nameOf(syntax_env.baseSymbol(requirement)));
    const pair = requirement.asPair() orelse
        return ctx.raise("bad cond-expand: a feature requirement is an identifier or a list that starts with library, and, or or not", .{});
    if (depth >= max_depth)
        return ctx.raise("implementation restriction: feature requirements are nested more than {d} deep", .{max_depth});
    const head = pair.car;
    var arguments: std.ArrayList(Value) = .empty;
    var rest = pair.cdr;
    while (rest.asPair()) |p| : (rest = p.cdr) try arguments.append(scratch, p.car);
    if (rest.kind() != .empty_list) return ctx.raise("bad cond-expand: a feature requirement must be a proper list", .{});
    if (isKeyword(ctx, head, "library")) {
        if (arguments.items.len != 1) return ctx.raise("bad cond-expand: expected (library <library name>)", .{});
        return try libraryAvailable(ctx, scratch, arguments.items[0]);
    }
    if (isKeyword(ctx, head, "not")) {
        if (arguments.items.len != 1) return ctx.raise("bad cond-expand: expected (not <feature requirement>)", .{});
        return !try evaluate(ctx, scratch, arguments.items[0], depth + 1);
    }
    const is_and = isKeyword(ctx, head, "and");
    if (!is_and and !isKeyword(ctx, head, "or"))
        return ctx.raise("bad cond-expand: a feature requirement is an identifier or a list that starts with library, and, or or not", .{});
    var result = is_and;
    for (arguments.items) |argument| {
        const value = try evaluate(ctx, scratch, argument, depth + 1);
        result = if (is_and) result and value else result or value;
    }
    return result;
}

/// Whether `id` is the identifier `spelling`.
/// Why: `else` `library` `and` `or` `not` は、`cond-expand` の構文の中の目印で、変数の
/// 束縛ではない。綴りで見分ける。マクロのテンプレートが導入した別名は、元の綴りで見る。
fn isKeyword(ctx: *const Context, id: Value, spelling: []const u8) bool {
    if (!syntax_env.isIdentifier(id)) return false;
    return std.mem.eql(u8, ctx.symbols.nameOf(syntax_env.baseSymbol(id)), spelling);
}

/// Whether the library `name` can be imported: `(sucheme core)`, a library that is
/// defined, or one whose file is beneath a root.
/// Why: ファイルは、開けることだけを調べ、読まない。読むと本体を走らせてしまい、要求を
/// 評価しただけで副作用が起きる。
fn libraryAvailable(ctx: *Context, scratch: std.mem.Allocator, name: Value) Error!bool {
    try library.checkName(ctx, name);
    if (library.isCoreName(ctx, name) or ctx.libraries.find(name) != null) return true;
    const opened = resolve.openLibrary(ctx.files, ctx.embedded, scratch, &ctx.symbols, name) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return false,
    };
    source.closeSource(ctx.files, opened.source);
    return true;
}

test {
    std.testing.refAllDecls(@This());
}
