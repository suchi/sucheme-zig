//! The expander: data in, core IR out.
//!
//! スライス 1f にあるのは 6 つの特殊形式だけで、マクロはない。したがって仕事は、
//! `quote`、`if`、`lambda`、`set!`、`define`、`begin` と、呼び出しの変換である。
//! 段階2で足すもの(構文束縛、`syntax-rules`)は、`Keyword` を構文環境に置き換える。
//! その置き場所は docs/design/frontend.md に書いてある。
//!
//! 展開器はすべての変数を解決する。`lambda` が束縛する名前は字句的番地(lexical
//! address。何個外側のフレームの、どのスロットか)になる。それ以外の名前は大域変数で、
//! 機械が実行するときに名前で探される。
//!
//! 作業は専用のスタックに積んで進め、再帰しない。したがって、リーダが読める深さまで
//! ネストしたプログラムでも、Zig のスタックはあふれない(docs/design/frontend.md)。

const std = @import("std");
const value_mod = @import("../value.zig");
const Value = value_mod.Value;
const Node = value_mod.Node;
const SymbolId = @import("../symbol.zig").SymbolId;
const symbol = @import("../symbol.zig");
const context = @import("../context.zig");
const Context = context.Context;
const core = @import("../core.zig");

pub const Error = context.Error;

/// What the representation of a lexical address holds.
/// 既定は番地の幅いっぱいの値である。テストは上限に届かせるために、より小さい値を渡す。
pub const Limits = struct {
    address: u32 = std.math.maxInt(u32),
};

/// Expands `form`, which is at the top level of a program.
/// 節点と、節点が指すものは `ctx.persist` に確保する。展開の実行中だけ要るものは
/// `scratch` から取る。エラーのときは `ctx` がメッセージを持つ。
pub fn expand(ctx: *Context, scratch: std.mem.Allocator, form: Value) Error!*const Node {
    return expandWith(ctx, scratch, form, .{});
}

pub fn expandWith(ctx: *Context, scratch: std.mem.Allocator, form: Value, limits: Limits) Error!*const Node {
    var e: Expander = .{ .ctx = ctx, .scratch = scratch, .limits = limits };
    const root = try ctx.persist.create(Node);
    try e.stack.append(scratch, .{ .form = form, .scope = null, .pos = .top, .dest = root });
    while (e.stack.pop()) |task| try e.step(task);
    return root;
}

/// The special forms.
/// キーワードは、隠す(シャドウ)・再定義・代入ができず、変数や仮引数としても使えない。
/// 段階2でこの列挙型は構文束縛に置き換わる。
const Keyword = enum {
    define,
    quote,
    @"if",
    lambda,
    begin,
    @"set!",

    fn of(name: []const u8) ?Keyword {
        return std.meta.stringToEnum(Keyword, name);
    }
};

/// Whether `name` is the name of a special form.
///
/// 準拠マトリクスが、特殊形式を束縛済みと数えるために使う。エラー文言から
/// 分類せず、展開器が使う判定と同じ関数で答える。
pub fn isKeyword(name: []const u8) bool {
    return Keyword.of(name) != null;
}

/// Where a form stands, which decides whether a definition is allowed there
/// (R7RS 5.3): at the top level, or at the start of a body.
const Position = enum { top, body, expression };

/// The variables of one `lambda` as the expander sees them: the parameters, then
/// the names its body defines at the start, in the order of the slots of a call's
/// frame.
const Scope = struct {
    names: []const SymbolId,
    parent: ?*const Scope,
};

/// A form still to expand, and the node to fill in with the result.
/// 節点は、子が決まる前に確保する。これによって、仕事を再帰でなくスタックに積める。
const Task = struct {
    form: Value,
    scope: ?*const Scope,
    pos: Position,
    dest: *Node,
};

const Expander = struct {
    ctx: *Context,
    scratch: std.mem.Allocator,
    limits: Limits,
    stack: std.ArrayList(Task) = .empty,

    fn step(self: *Expander, task: Task) Error!void {
        switch (task.form.kind()) {
            // 自己評価式(R7RS 4.1.2)。
            .fixnum, .boolean, .character, .string, .vector, .unspecified, .uninitialized, .condition, .primitive, .closure => try self.constant(task, task.form),
            // Why: R7RS 4.1.3 は、手続き呼び出しに空でないリストを与えている。
            .empty_list => return self.ctx.raise("empty combination", .{}),
            .symbol => try self.reference(task),
            .pair => {
                const items = try self.itemsOf(task.form);
                if (items[0].asSymbol()) |head| {
                    if (Keyword.of(self.ctx.symbols.nameOf(head))) |keyword| return switch (keyword) {
                        .define => self.define(task, items),
                        .quote => self.quote(task, items),
                        .@"if" => self.conditional(task, items),
                        .lambda => self.lambdaForm(task, items),
                        .begin => self.begin(task, items),
                        .@"set!" => self.set(task, items),
                    };
                }
                try self.call(task, items);
            },
        }
    }

    /// Makes the node of `task` the constant `v`.
    /// コードはまだ GC ヒープの中にない。そのため、ヒープを指す定数はコンテキストに
    /// 知らせ、コンテキストが生かしておく。定数を作る箇所は、この 2 つだけである。
    fn constant(self: *Expander, task: Task, v: Value) Error!void {
        try self.ctx.keepConstant(v);
        task.dest.* = .{ .constant = v };
    }

    /// Queues `form` to fill a new node, and returns the node.
    fn child(self: *Expander, form: Value, scope: ?*const Scope, pos: Position) Error!*Node {
        const node = try self.ctx.persist.create(Node);
        try self.stack.append(self.scratch, .{ .form = form, .scope = scope, .pos = pos, .dest = node });
        return node;
    }

    /// The elements of the list `form`.
    /// 形式はプロパーリスト(proper list)である。ドット付きのペアはデータとしては
    /// 読めるが形式ではないので、ここで失敗する。
    fn itemsOf(self: *Expander, form: Value) Error![]const Value {
        var items: std.ArrayList(Value) = .empty;
        var rest = form;
        while (rest.asPair()) |p| : (rest = p.cdr) try items.append(self.scratch, p.car);
        if (rest.kind() != .empty_list)
            return self.ctx.raise("bad syntax: a form must be a proper list", .{});
        return items.items;
    }

    /// The address of the variable `id` if a `lambda` around `scope` binds it.
    fn resolve(self: *Expander, scope: ?*const Scope, id: SymbolId) Error!?value_mod.Address {
        var depth: u32 = 0;
        var s = scope;
        while (s) |sc| : (s = sc.parent) {
            for (sc.names, 0..) |n, i| {
                if (n != id) continue;
                if (depth > self.limits.address) return self.ctx.raise(
                    "implementation restriction: procedures are nested too deeply",
                    .{},
                );
                return .{ .depth = depth, .index = @intCast(i) };
            }
            depth += 1;
        }
        return null;
    }

    fn reference(self: *Expander, task: Task) Error!void {
        const id = task.form.asSymbol().?;
        const name = self.ctx.symbols.nameOf(id);
        if (Keyword.of(name) != null)
            return self.ctx.raise("{s} is a syntactic keyword and cannot be used as a variable", .{name});
        task.dest.* = if (try self.resolve(task.scope, id)) |address|
            .{ .local_ref = .{ .address = address, .name = id } }
        else
            .{ .global_ref = id };
    }

    /// `(quote datum)` (R7RS 4.1.2).
    /// データは展開せず、そのまま使う。
    fn quote(self: *Expander, task: Task, items: []const Value) Error!void {
        if (items.len != 2)
            return self.ctx.raise("bad quote: expected (quote datum)", .{});
        try self.constant(task, items[1]);
    }

    /// `(if test consequent [alternative])` (R7RS 4.1.5).
    fn conditional(self: *Expander, task: Task, items: []const Value) Error!void {
        if (items.len != 3 and items.len != 4)
            return self.ctx.raise("bad if: expected (if test consequent) or (if test consequent alternative)", .{});
        // 後ろのものから先に積むので、判定が最初に展開される。
        const alternative = if (items.len == 4) try self.child(items[3], task.scope, .expression) else null;
        const consequent = try self.child(items[2], task.scope, .expression);
        const condition = try self.child(items[1], task.scope, .expression);
        task.dest.* = .{ .@"if" = .{ .condition = condition, .consequent = consequent, .alternative = alternative } };
    }

    /// `(begin expression ...)` (R7RS 4.2.3).
    /// トップレベルでは、中の形式もトップレベルにあるので、そこに定義を書ける(R7RS 5.3)。
    fn begin(self: *Expander, task: Task, items: []const Value) Error!void {
        if (items.len < 2)
            return self.ctx.raise("bad begin: expected (begin expression ...)", .{});
        const pos: Position = if (task.pos == .top) .top else .expression;
        try self.sequence(task.dest, items[1..], task.scope, pos, 0);
    }

    /// Fills `dest` with `forms` run in order: `defines` of them at the start
    /// are definitions of a body, the rest are in `pos`.
    /// 形式が 1 つなら、その形式そのものになる(本体が定義だけということはないので、
    /// その 1 つが定義になることはない)。
    fn sequence(self: *Expander, dest: *Node, forms: []const Value, scope: ?*const Scope, pos: Position, defines: usize) Error!void {
        if (forms.len == 1) {
            try self.stack.append(self.scratch, .{ .form = forms[0], .scope = scope, .pos = pos, .dest = dest });
            return;
        }
        const nodes = try self.ctx.persist.alloc(*const Node, forms.len);
        // 節点は順に作り、後ろのものから先にスタックに積む。
        for (nodes) |*n| n.* = try self.ctx.persist.create(Node);
        var i = forms.len;
        while (i > 0) {
            i -= 1;
            try self.stack.append(self.scratch, .{
                .form = forms[i],
                .scope = scope,
                .pos = if (i < defines) .body else pos,
                .dest = @constCast(nodes[i]),
            });
        }
        dest.* = .{ .sequence = nodes };
    }

    /// `(set! name expression)` (R7RS 4.1.6).
    /// 対象は `name` の最も近い束縛で、局所でも大域でもよい。
    fn set(self: *Expander, task: Task, items: []const Value) Error!void {
        if (items.len != 3)
            return self.ctx.raise("bad set!: expected (set! name expression)", .{});
        const id = items[1].asSymbol() orelse
            return self.ctx.raise("bad set!: the name must be an identifier", .{});
        const name = self.ctx.symbols.nameOf(id);
        if (Keyword.of(name) != null)
            return self.ctx.raise("bad set!: {s} is a syntactic keyword and cannot be assigned", .{name});
        const value = try self.child(items[2], task.scope, .expression);
        task.dest.* = if (try self.resolve(task.scope, id)) |address|
            .{ .local_set = .{ .address = address, .name = id, .value = value } }
        else
            .{ .global_set = .{ .name = id, .value = value } };
    }

    /// `(define name expression)` and `(define (name parameter ...) body ...)`
    /// (R7RS 5.3.1).
    /// トップレベルでは大域変数を束縛する。本体の先頭では、`lambdaNode` が作った
    /// 局所変数に値を与える。
    fn define(self: *Expander, task: Task, items: []const Value) Error!void {
        // Why: R7RS 5.3 が定義を許すのは、トップレベルと本体の先頭だけである。それ以外で
        // 許すと、あとで失敗するかもしれない式の中から名前を束縛することになる。
        if (task.pos == .expression)
            return self.ctx.raise("bad define: a definition is only allowed at the top level or at the start of a body", .{});
        // `(define (name parameter ...) body ...)` は
        // `(define name (lambda (parameter ...) body ...))` と同じである(R7RS 5.3.1)。
        const shorthand = items.len >= 2 and items[1].kind() == .pair;
        if (shorthand and items.len < 3)
            return self.ctx.raise("bad define: expected (define (name parameter ...) body ...)", .{});
        if (!shorthand and items.len != 3)
            return self.ctx.raise("bad define: expected (define name expression)", .{});
        const target = if (shorthand) items[1].asPair().?.car else items[1];
        const id = target.asSymbol() orelse
            return self.ctx.raise("bad define: the name must be an identifier", .{});
        const name = self.ctx.symbols.nameOf(id);
        if (Keyword.of(name) != null)
            return self.ctx.raise("bad define: {s} is a syntactic keyword and cannot be redefined", .{name});
        const value = try self.ctx.persist.create(Node);
        if (shorthand) {
            try self.lambdaNode(value, items[1].asPair().?.cdr, items[2..], task.scope, "define");
        } else {
            try self.stack.append(self.scratch, .{ .form = items[2], .scope = task.scope, .pos = .expression, .dest = value });
        }
        switch (task.pos) {
            .top => task.dest.* = .{ .global_define = .{ .name = id, .value = value } },
            // `collectDefinitions` が lambda を作るときに変数を作ってあり、
            // スコープはその lambda 自身のものである。
            .body => {
                const index = std.mem.indexOfScalar(SymbolId, task.scope.?.names, id).?;
                task.dest.* = .{ .local_define = .{ .address = .{ .depth = 0, .index = @intCast(index) }, .name = id, .value = value } };
            },
            .expression => unreachable,
        }
    }

    /// `(lambda (name ...) body ...)` (R7RS 4.1.4).
    fn lambdaForm(self: *Expander, task: Task, items: []const Value) Error!void {
        if (items.len < 3)
            return self.ctx.raise("bad lambda: expected (lambda (name ...) body ...)", .{});
        try self.lambdaNode(task.dest, items[1], items[2..], task.scope, "lambda");
    }

    /// Fills `dest` with the procedure whose parameters are `params_form` and
    /// whose body is `body`, made in `scope`.
    /// `form_name` は、メッセージのための、その手続きが書かれた形式の名前である。
    /// `(define (f x) ...)` は、自前の仮引数リストを持つ `define` である。
    ///
    /// 仮引数は R7RS 4.1.4 の3つの形を取る。`(a b)` は固定個、`args` は任意個、
    /// `(a b . r)` は2個以上である。余りを受ける変数は、必須の仮引数の直後の
    /// スロットに置く。
    fn lambdaNode(
        self: *Expander,
        dest: *Node,
        params_form: Value,
        body: []const Value,
        scope: ?*const Scope,
        comptime form_name: []const u8,
    ) Error!void {
        var names: std.ArrayList(SymbolId) = .empty;
        var rest = params_form;
        while (rest.asPair()) |p| : (rest = p.cdr) try self.parameter(&names, p.car, form_name);
        const arity = names.items.len;
        // リストの終わりが空リストでなければ、ドットの後ろ(または仮引数の全体)が
        // 余りを受ける変数である。識別子でないものは、仮引数の並びとして読めない。
        const has_rest = rest.kind() != .empty_list;
        if (has_rest) {
            if (rest.kind() != .symbol)
                return self.ctx.raise("bad " ++ form_name ++ ": the parameters must be an identifier or a list of identifiers", .{});
            try self.parameter(&names, rest, form_name);
        }
        const defines = try self.collectDefinitions(body, &names);
        // Why: R7RS 5.3.2 の本体は、定義のあとに式が続く形で、式は 1 つ以上要る。
        // 定義だけの本体には、返す値がない。
        if (defines == body.len)
            return self.ctx.raise("bad " ++ form_name ++ ": a body needs an expression after its definitions", .{});
        if (names.items.len > self.limits.address)
            return self.ctx.raise("implementation restriction: a procedure has too many variables", .{});
        const inner = try self.scratch.create(Scope);
        inner.* = .{ .names = names.items, .parent = scope };
        const body_node = try self.ctx.persist.create(Node);
        try self.sequence(body_node, body, inner, .expression, defines);
        const lambda = try self.ctx.persist.create(value_mod.Lambda);
        lambda.* = .{ .arity = @intCast(arity), .rest = has_rest, .frame_size = @intCast(names.items.len), .body = body_node };
        dest.* = .{ .lambda = lambda };
    }

    /// Adds the parameter `form` to `names`, after checking that it is an
    /// identifier that is neither a keyword nor one of `names` already.
    /// 必須の仮引数と余りを受ける変数の両方が、同じ検査を通る。
    fn parameter(self: *Expander, names: *std.ArrayList(SymbolId), form: Value, comptime form_name: []const u8) Error!void {
        const id = form.asSymbol() orelse
            return self.ctx.raise("bad " ++ form_name ++ ": a parameter must be an identifier", .{});
        const name = self.ctx.symbols.nameOf(id);
        if (Keyword.of(name) != null)
            return self.ctx.raise("bad " ++ form_name ++ ": {s} is a syntactic keyword and cannot be a parameter", .{name});
        for (names.items) |seen| {
            if (seen == id) return self.ctx.raise("bad " ++ form_name ++ ": duplicate parameter: {s}", .{name});
        }
        try names.append(self.scratch, id);
    }

    /// Adds the names that the definitions at the start of `body` define to
    /// `names`, and returns how many forms they are.
    /// すでにある名前(仮引数か、先の定義)と重なるとエラーになる。定義そのものの検査は、
    /// 展開するときに行う。
    fn collectDefinitions(self: *Expander, body: []const Value, names: *std.ArrayList(SymbolId)) Error!usize {
        var count: usize = 0;
        for (body) |form| {
            const head = form.asPair() orelse break;
            const keyword_id = head.car.asSymbol() orelse break;
            if (Keyword.of(self.ctx.symbols.nameOf(keyword_id)) != .define) break;
            const rest = head.cdr.asPair() orelse
                return self.ctx.raise("bad define: expected (define name expression)", .{});
            // `(define (name parameter ...) body ...)` は、ヘッダの先頭にあるものを名前とする。
            const target = if (rest.car.asPair()) |header| header.car else rest.car;
            const id = target.asSymbol() orelse
                return self.ctx.raise("bad define: the name must be an identifier", .{});
            const name = self.ctx.symbols.nameOf(id);
            if (Keyword.of(name) != null)
                return self.ctx.raise("bad define: {s} is a syntactic keyword and cannot be redefined", .{name});
            for (names.items) |seen| {
                if (seen == id) return self.ctx.raise(
                    "bad define: {s} is already a parameter or defined earlier in this body",
                    .{name},
                );
            }
            try names.append(self.scratch, id);
            count += 1;
        }
        return count;
    }

    /// A procedure call (R7RS 4.1.3): the operator, then the operands from left
    /// to right.
    /// Why: R7RS は評価順を規定していない。読み手が期待するのは左から右である。
    fn call(self: *Expander, task: Task, items: []const Value) Error!void {
        const operands = try self.ctx.persist.alloc(*const Node, items.len - 1);
        for (operands) |*n| n.* = try self.ctx.persist.create(Node);
        var i = items.len;
        while (i > 1) {
            i -= 1;
            try self.stack.append(self.scratch, .{ .form = items[i], .scope = task.scope, .pos = .expression, .dest = @constCast(operands[i - 1]) });
        }
        const operator = try self.child(items[0], task.scope, .expression);
        task.dest.* = .{ .call = .{ .operator = operator, .operands = operands } };
    }
};

test {
    std.testing.refAllDecls(@This());
}

/// What the tests share: a context whose symbols the reader fills, and the text
/// of what `src` expands to.
const Fixture = struct {
    arena: std.heap.ArenaAllocator,
    ctx: Context,

    fn init(self: *Fixture) !void {
        self.arena = .init(std.testing.allocator);
        errdefer self.arena.deinit();
        self.ctx = try .init(self.arena.allocator(), std.heap.smp_allocator);
    }

    fn deinit(self: *Fixture) void {
        self.ctx.deinit();
        self.arena.deinit();
    }

    /// The first datum of `src`.
    fn read(self: *Fixture, src: []const u8) !Value {
        var r: @import("../reader.zig").Reader = .init(src);
        const sink: @import("../reader.zig").Sink = .{ .alloc = self.ctx.persist, .heap = &self.ctx.heap, .symbols = &self.ctx.symbols };
        return (try r.next(self.arena.allocator(), sink)).?;
    }

    fn expandText(self: *Fixture, src: []const u8, limits: Limits) ![]const u8 {
        const form = try self.read(src);
        const node = try expandWith(&self.ctx, self.arena.allocator(), form, limits);
        var out: std.Io.Writer.Allocating = .init(self.arena.allocator());
        try core.write(&out.writer, self.arena.allocator(), &self.ctx.symbols, node);
        return out.written();
    }

    fn expectExpands(self: *Fixture, src: []const u8, expected: []const u8) !void {
        try std.testing.expectEqualStrings(expected, try self.expandText(src, .{}));
    }

    /// `src` raises an error whose condition has `message`.
    fn expectFails(self: *Fixture, src: []const u8, message: []const u8) !void {
        try std.testing.expectError(error.Raised, self.expandText(src, .{}));
        try std.testing.expectEqualStrings(message, self.ctx.raised.?.message);
    }
};

test "isKeyword names the six special forms and nothing near them" {
    for ([_][]const u8{ "define", "quote", "if", "lambda", "begin", "set!" }) |name| {
        try std.testing.expect(isKeyword(name));
    }
    for ([_][]const u8{ "set", "Define", "define ", "cond", "+", "" }) |name| {
        try std.testing.expect(!isKeyword(name));
    }
}

test "a literal is a constant, and a name is a global variable when nothing binds it" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.expectExpands("42", "(const 42)");
    try f.expectExpands("#t", "(const #t)");
    try f.expectExpands("x", "(global x)");
    try f.expectExpands("+", "(global +)");
}

test "quote gives its datum unexpanded" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.expectExpands("(quote x)", "(const x)");
    try f.expectExpands("'(a (b 2) ())", "(const (a (b 2) ()))");
    // quote の中の形式はデータなので、呼び出しとして読まれない。
    try f.expectExpands("'(if 1)", "(const (if 1))");
}

test "a call has the operator first and the operands in order" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.expectExpands("(f)", "(call (global f))");
    try f.expectExpands("(f 1 2)", "(call (global f) (const 1) (const 2))");
    try f.expectExpands("((g) (h 1))", "(call (call (global g)) (call (global h) (const 1)))");
}

test "if takes two or three parts" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.expectExpands("(if 1 2 3)", "(if (const 1) (const 2) (const 3))");
    try f.expectExpands("(if x 2)", "(if (global x) (const 2))");
}

test "define at the top level binds a global, and the shorthand makes a lambda" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.expectExpands("(define x 1)", "(define-global x (const 1))");
    try f.expectExpands("(define (f a) a)", "(define-global f (lambda 1 1 (local a 0 0)))");
    try f.expectExpands("(define (f) 1 2)", "(define-global f (lambda 0 0 (seq (const 1) (const 2))))");
}

test "a lambda binds its parameters at depth 0, and the frame outside at depth 1" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.expectExpands("(lambda (x y) y)", "(lambda 2 2 (local y 0 1))");
    try f.expectExpands("(lambda () 1)", "(lambda 0 0 (const 1))");
    try f.expectExpands("(lambda (x) 1 x)", "(lambda 1 1 (seq (const 1) (local x 0 0)))");
    try f.expectExpands(
        "(lambda (x) (lambda (y) (+ x y)))",
        "(lambda 1 1 (lambda 1 1 (call (global +) (local x 1 0) (local y 0 0))))",
    );
    // 近いほうの束縛が遠いほうを隠し、局所変数が大域変数を隠す。
    try f.expectExpands("(lambda (x) (lambda (x) x))", "(lambda 1 1 (lambda 1 1 (local x 0 0)))");
    try f.expectExpands("(lambda (+) +)", "(lambda 1 1 (local + 0 0))");
}

test "a rest parameter takes the slot after the required ones, and the definitions follow it" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.expectExpands("(lambda args args)", "(lambda 0 rest 1 (local args 0 0))");
    try f.expectExpands("(lambda (a b . r) r)", "(lambda 2 rest 3 (local r 0 2))");
    try f.expectExpands("(lambda (a . r) a)", "(lambda 1 rest 2 (local a 0 0))");
    try f.expectExpands(
        "(lambda (a . r) (define n 1) n)",
        "(lambda 1 rest 3 (seq (define-local n 0 2 (const 1)) (local n 0 2)))",
    );
    // `define` の略記も同じ仮引数を取る(R7RS 5.3.1)。本体の先頭の略記も同じである。
    try f.expectExpands("(define (f . xs) xs)", "(define-global f (lambda 0 rest 1 (local xs 0 0)))");
    try f.expectExpands("(define (f a . xs) xs)", "(define-global f (lambda 1 rest 2 (local xs 0 1)))");
    try f.expectExpands(
        "(lambda () (define (g . r) r) g)",
        "(lambda 0 1 (seq (define-local g 0 0 (lambda 0 rest 1 (local r 0 0))) (local g 0 0)))",
    );
    // 固定個の手続きは、`rest` の印を持たない。
    try f.expectExpands("(lambda (a b) a)", "(lambda 2 2 (local a 0 0))");
}

test "a rest parameter is checked like the other parameters" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.expectFails("(lambda (a . a) a)", "bad lambda: duplicate parameter: a");
    try f.expectFails("(lambda (a . if) 1)", "bad lambda: if is a syntactic keyword and cannot be a parameter");
    try f.expectFails("(lambda if 1)", "bad lambda: if is a syntactic keyword and cannot be a parameter");
    try f.expectFails("(lambda (a . 1) a)", "bad lambda: the parameters must be an identifier or a list of identifiers");
    try f.expectFails("(lambda #t 1)", "bad lambda: the parameters must be an identifier or a list of identifiers");
    try f.expectFails("(lambda r (define r 1) r)", "bad define: r is already a parameter or defined earlier in this body");
    try f.expectFails("(define (f . if) 1)", "bad define: if is a syntactic keyword and cannot be a parameter");
    try f.expectFails("(define (f . 1) 1)", "bad define: the parameters must be an identifier or a list of identifiers");
    try f.expectFails("(define (f . r))", "bad define: expected (define (name parameter ...) body ...)");
}

test "a rest parameter counts toward the variables of a procedure" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const limits: Limits = .{ .address = 1 };
    try std.testing.expectEqualStrings("(lambda 0 rest 1 (local r 0 0))", try f.expandText("(lambda r r)", limits));
    try std.testing.expectError(error.Raised, f.expandText("(lambda (a . r) a)", limits));
    try std.testing.expectEqualStrings("implementation restriction: a procedure has too many variables", f.ctx.diagnostic());
}

test "set! assigns the nearest binding, local or global" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.expectExpands("(set! x 1)", "(set-global x (const 1))");
    try f.expectExpands("(lambda (x) (set! x 2))", "(lambda 1 1 (set-local x 0 0 (const 2)))");
    try f.expectExpands("(lambda (x) (lambda () (set! x 2)))", "(lambda 1 1 (lambda 0 0 (set-local x 1 0 (const 2))))");
    try f.expectExpands("(lambda (x) (set! y 2))", "(lambda 1 1 (set-global y (const 2)))");
}

test "begin is a sequence, and one form is that form" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.expectExpands("(begin 1 2)", "(seq (const 1) (const 2))");
    try f.expectExpands("(begin 1)", "(const 1)");
    // トップレベルでは、中の形式もトップレベルにある(R7RS 5.3)。
    try f.expectExpands("(begin (define x 1) x)", "(seq (define-global x (const 1)) (global x))");
}

test "definitions at the start of a body make slots after the parameters" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.expectExpands(
        "(lambda (n) (define a 1) (define (g) a) (g))",
        "(lambda 1 3 (seq (define-local a 0 1 (const 1)) (define-local g 0 2 (lambda 0 0 (local a 1 1))) (call (local g 0 2))))",
    );
    // 後で定義する名前は、先に定義した手続きからすでに見える。
    try f.expectExpands(
        "(lambda () (define (even? n) (odd? n)) (define (odd? n) n) 1)",
        "(lambda 0 2 (seq (define-local even? 0 0 (lambda 1 1 (call (local odd? 1 1) (local n 0 0)))) (define-local odd? 0 1 (lambda 1 1 (local n 0 0))) (const 1)))",
    );
    // 式のあとの定義は、本体が少しも実行されないうちに拒否される。
    try f.expectFails(
        "(lambda () (+ a 1) (define a 1) a)",
        "bad define: a definition is only allowed at the top level or at the start of a body",
    );
}

test "the shapes the expander refuses, with the messages the evaluator gave" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.expectFails("()", "empty combination");
    try f.expectFails("(quote)", "bad quote: expected (quote datum)");
    try f.expectFails("(quote 1 2)", "bad quote: expected (quote datum)");
    try f.expectFails("(if 1)", "bad if: expected (if test consequent) or (if test consequent alternative)");
    try f.expectFails("(lambda)", "bad lambda: expected (lambda (name ...) body ...)");
    try f.expectFails("(lambda (x))", "bad lambda: expected (lambda (name ...) body ...)");
    try f.expectFails("(lambda (x x) x)", "bad lambda: duplicate parameter: x");
    try f.expectFails("(lambda (if) 1)", "bad lambda: if is a syntactic keyword and cannot be a parameter");
    try f.expectFails("(lambda (1) 1)", "bad lambda: a parameter must be an identifier");
    try f.expectFails("(lambda 1 1)", "bad lambda: the parameters must be an identifier or a list of identifiers");
    try f.expectFails("(set! x)", "bad set!: expected (set! name expression)");
    try f.expectFails("(set! 1 2)", "bad set!: the name must be an identifier");
    try f.expectFails("(set! if 1)", "bad set!: if is a syntactic keyword and cannot be assigned");
    try f.expectFails("(begin)", "bad begin: expected (begin expression ...)");
    try f.expectFails("if", "if is a syntactic keyword and cannot be used as a variable");
    try f.expectFails("(define)", "bad define: expected (define name expression)");
    try f.expectFails("(define x)", "bad define: expected (define name expression)");
    try f.expectFails("(define 1 2)", "bad define: the name must be an identifier");
    try f.expectFails("(define if 1)", "bad define: if is a syntactic keyword and cannot be redefined");
    try f.expectFails("(define (f))", "bad define: expected (define (name parameter ...) body ...)");
    try f.expectFails("(+ 1 (define x 1))", "bad define: a definition is only allowed at the top level or at the start of a body");
    try f.expectFails("(if (define x 1) 2)", "bad define: a definition is only allowed at the top level or at the start of a body");
}

test "the shapes a body refuses" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.expectFails("(lambda () (define x 1))", "bad lambda: a body needs an expression after its definitions");
    try f.expectFails("(define (f) (define x 1))", "bad define: a body needs an expression after its definitions");
    try f.expectFails("(lambda (x) (define x 1) x)", "bad define: x is already a parameter or defined earlier in this body");
    try f.expectFails("(lambda () (define x 1) (define x 2) x)", "bad define: x is already a parameter or defined earlier in this body");
    try f.expectFails("(lambda () (define if 1) 1)", "bad define: if is a syntactic keyword and cannot be redefined");
    try f.expectFails("(lambda () (begin (define x 1)) x)", "bad define: a definition is only allowed at the top level or at the start of a body");
}

test "an address that does not fit the width is reported, and one that just fits is not" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const limits: Limits = .{ .address = 1 };
    // 深さ 1 が収まる最後の値である。
    try std.testing.expectEqualStrings(
        "(lambda 1 1 (lambda 1 1 (local a 1 0)))",
        try f.expandText("(lambda (a) (lambda (b) a))", limits),
    );
    try std.testing.expectError(error.Raised, f.expandText("(lambda (a) (lambda (b) (lambda (c) a)))", limits));
    try std.testing.expectEqualStrings("implementation restriction: procedures are nested too deeply", f.ctx.diagnostic());
    // 1 スロットのフレームが収まる最後で、2 スロットは収まらない。
    try std.testing.expectEqualStrings("(lambda 1 1 (local a 0 0))", try f.expandText("(lambda (a) a)", limits));
    try std.testing.expectError(error.Raised, f.expandText("(lambda (a b) a)", limits));
    try std.testing.expectEqualStrings("implementation restriction: a procedure has too many variables", f.ctx.diagnostic());
    try std.testing.expectError(error.Raised, f.expandText("(lambda (a) (define b 1) a)", limits));
}

test "a keyword is not a variable, a parameter or a name to define" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.expectFails("quote", "quote is a syntactic keyword and cannot be used as a variable");
    try f.expectFails("(define quote 1)", "bad define: quote is a syntactic keyword and cannot be redefined");
    try f.expectFails("(define #t 1)", "bad define: the name must be an identifier");
    try f.expectFails("(f if)", "if is a syntactic keyword and cannot be used as a variable");
}

test "a form that is not a proper list is refused" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const a = f.arena.allocator();
    // リーダはドット付きリストを書けないので、(+ 1 . 2) は手で組み立てる。
    const tail = try f.ctx.heap.cons(.fromFixnum(1), .fromFixnum(2));
    const plus: Value = .fromSymbol(try f.ctx.symbols.intern(a, "+"));
    const form = try f.ctx.heap.cons(plus, tail);
    try std.testing.expectError(error.Raised, expand(&f.ctx, a, form));
    try std.testing.expectEqualStrings("bad syntax: a form must be a proper list", f.ctx.diagnostic());
}

test "quote gives the very datum it was read with, not a copy" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const a = f.arena.allocator();
    const form = try f.read("(quote (1 2))");
    const node = try expand(&f.ctx, a, form);
    try std.testing.expectEqual(form.asPair().?.cdr.asPair().?.car.asPair().?, node.constant.asPair().?);
}

test "a constant that refers to the heap is kept for the collector, and nothing else is" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const a = f.arena.allocator();
    // ヒープオブジェクトを持たない定数には、ルートは要らない。
    for ([_][]const u8{ "5", "#t", "(quote foo)", "(quote ())", "x" }) |src| _ = try expand(&f.ctx, a, try f.read(src));
    try std.testing.expectEqual(0, f.ctx.code_roots.items.len);
    f.ctx.collectIdle();
    try std.testing.expectEqual(0, f.ctx.heap.count);
    // クォートしたリストがその例である。対象はデータそのもので、周りの `quote` 形式のペアではない。
    const node = try expand(&f.ctx, a, try f.read("(quote (1 2))"));
    try std.testing.expectEqual(1, f.ctx.code_roots.items.len);
    try std.testing.expectEqual(4, f.ctx.heap.count);
    f.ctx.collectIdle();
    try std.testing.expectEqual(2, f.ctx.heap.count);
    try std.testing.expectEqual(2, node.constant.asPair().?.cdr.asPair().?.car.asFixnum().?);
    // 定数を作るもう一方の箇所: すでに値である形式。
    const closure = try f.ctx.heap.create(value_mod.Closure, .{ .lambda = undefined, .env = null });
    const itself = try expand(&f.ctx, a, .fromClosure(closure));
    try std.testing.expectEqual(closure, itself.constant.asClosure().?);
    try std.testing.expectEqual(2, f.ctx.code_roots.items.len);
    f.ctx.collectIdle();
    try std.testing.expectEqual(3, f.ctx.heap.count);
}

test "a program nested deeper than the Zig stack allows still expands" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const depth = 100_000;
    var src: std.ArrayList(u8) = .empty;
    for (0..depth) |_| try src.appendSlice(f.arena.allocator(), "(+ 1 ");
    try src.append(f.arena.allocator(), '2');
    for (0..depth) |_| try src.append(f.arena.allocator(), ')');
    const form = try f.read(src.items);
    const node = try expand(&f.ctx, f.arena.allocator(), form);
    try std.testing.expect(node.* == .call);
}
