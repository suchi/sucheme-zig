//! The expander: data in, core IR out.
//!
//! マクロはまだない。仕事は、特殊形式(`quote`、`if`、`lambda`、`set!`、`define`、
//! `begin`)と、呼び出しの変換である。
//!
//! 展開器はすべての識別子を構文環境(src/syntax/env.zig)で解決する(ADR-0019)。
//! 特殊形式の名前は予約語ではなく、REPL の最上位の束縛なので、`lambda` の仮引数や
//! 本体の定義が同じ綴りを束縛すると、その内側では変数になる。局所変数は字句的番地
//! (lexical address。何個外側のフレームの、どのスロットか)になり、深さは参照する
//! 側の rib の深さから、束縛した rib の深さを引いて求める。それ以外の名前は大域変数で、
//! 展開器が REPL の束縛の表(src/env.zig)でセルに解決する。
//!
//! 作業は専用のスタックに積んで進め、再帰しない。したがって、リーダが読める深さまで
//! ネストしたプログラムでも、Zig のスタックはあふれない(docs/design/frontend.md)。

const std = @import("std");
const value_mod = @import("../value.zig");
const Value = value_mod.Value;
const Node = value_mod.Node;
const context = @import("../context.zig");
const Context = context.Context;
const core = @import("../core.zig");
const syntax_env = @import("env.zig");
const SyntacticEnv = syntax_env.SyntacticEnv;

pub const Error = context.Error;

/// What the representation of a lexical address holds.
/// 既定は番地の幅いっぱいの値である。テストは上限に届かせるために、より小さい値を渡す。
pub const Limits = struct {
    address: u32 = std.math.maxInt(u32),
};

/// Expands `form`, which is at the top level of a program.
/// 節点と、節点が指すものは `ctx.persist` に確保する。展開の実行中だけ要るものは
/// `scratch` から取る。構文環境は GC ヒープに確保し、節点からは指さない。
/// エラーのときは `ctx` がメッセージを持つ。
pub fn expand(ctx: *Context, scratch: std.mem.Allocator, form: Value) Error!*const Node {
    return expandWith(ctx, scratch, form, .{});
}

pub fn expandWith(ctx: *Context, scratch: std.mem.Allocator, form: Value, limits: Limits) Error!*const Node {
    var e: Expander = .{ .ctx = ctx, .scratch = scratch, .limits = limits };
    const root = try ctx.persist.create(Node);
    // 展開が失敗したら、この形式が遮蔽した特殊形式を戻す。失敗した形式は実行されない
    // ので、遮蔽だけが残ると、特殊形式を理由なく失う。
    errdefer ctx.globals.undoShadows();
    try e.stack.append(scratch, .{ .form = form, .env = null, .pos = .top, .dest = root });
    while (e.stack.pop()) |task| try e.step(task);
    ctx.globals.commitShadows();
    return root;
}

/// Where a form stands, which decides whether a definition is allowed there
/// (R7RS 5.3): at the top level, or at the start of a body.
const Position = enum { top, body, expression };

/// A form still to expand, the environment to expand it in (null at the top
/// level), and the node to fill in with the result.
/// 節点は、子が決まる前に確保する。これによって、仕事を再帰でなくスタックに積める。
const Task = struct {
    form: Value,
    env: ?*SyntacticEnv,
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
            .fixnum, .boolean, .character, .string, .vector, .unspecified, .uninitialized, .condition, .primitive, .closure, .record, .record_type => try self.constant(task, task.form),
            // Why: R7RS 4.1.3 は、手続き呼び出しに空でないリストを与えている。
            .empty_list => return self.ctx.raise("empty combination", .{}),
            .symbol => try self.reference(task),
            .pair => {
                const items = try self.itemsOf(task.form);
                if (try self.specialOf(task.env, items[0])) |special| return switch (special) {
                    .define => self.define(task, items),
                    .quote => self.quote(task, items),
                    .@"if" => self.conditional(task, items),
                    .lambda => self.lambdaForm(task, items),
                    .begin => self.begin(task, items),
                    .@"set!" => self.set(task, items),
                };
                try self.call(task, items);
            },
        }
    }

    /// The special form that `head` names in `env`, or null when it is not an
    /// identifier that means one.
    fn specialOf(self: *Expander, env: ?*const SyntacticEnv, head: Value) Error!?syntax_env.Special {
        if (head.kind() != .symbol) return null;
        return switch (try syntax_env.resolve(self.ctx, env, head)) {
            .special => |special| special,
            .local, .global => null,
        };
    }

    /// Makes the node of `task` the constant `v`.
    /// コードはまだ GC ヒープの中にない。そのため、ヒープを指す定数はコンテキストに
    /// 知らせ、コンテキストが生かしておく。定数を作る箇所は、この 2 つだけである。
    fn constant(self: *Expander, task: Task, v: Value) Error!void {
        try self.ctx.keepConstant(v);
        task.dest.* = .{ .constant = v };
    }

    /// Queues `form` to fill a new node, and returns the node.
    fn child(self: *Expander, form: Value, env: ?*SyntacticEnv, pos: Position) Error!*Node {
        const node = try self.ctx.persist.create(Node);
        try self.stack.append(self.scratch, .{ .form = form, .env = env, .pos = pos, .dest = node });
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

    /// The address of `local` from a use in `env`.
    /// 深さは、参照する側の rib の深さと、束縛した rib の深さの差である。
    fn address(self: *Expander, env: ?*const SyntacticEnv, local: *const syntax_env.LocalBinding) Error!value_mod.Address {
        const depth = syntax_env.ribDepth(env) - local.rib_depth;
        if (depth > self.limits.address) return self.ctx.raise(
            "implementation restriction: procedures are nested too deeply",
            .{},
        );
        return .{ .depth = depth, .index = local.index };
    }

    fn reference(self: *Expander, task: Task) Error!void {
        const id = task.form.asSymbol().?;
        task.dest.* = switch (try syntax_env.resolve(self.ctx, task.env, task.form)) {
            .special => return self.ctx.raise(
                "{s} is a syntactic keyword and cannot be used as a variable",
                .{self.ctx.symbols.nameOf(id)},
            ),
            .local => |local| .{ .local_ref = .{ .address = try self.address(task.env, local), .name = id } },
            .global => |cell| .{ .global_ref = cell },
        };
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
        const alternative = if (items.len == 4) try self.child(items[3], task.env, .expression) else null;
        const consequent = try self.child(items[2], task.env, .expression);
        const condition = try self.child(items[1], task.env, .expression);
        task.dest.* = .{ .@"if" = .{ .condition = condition, .consequent = consequent, .alternative = alternative } };
    }

    /// `(begin expression ...)` (R7RS 4.2.3).
    /// トップレベルでは、中の形式もトップレベルにあるので、そこに定義を書ける(R7RS 5.3)。
    /// トップレベルの `(begin)` は、定義が 0 個の `(begin <definition>*)` であり
    /// (R7RS 7.1.6)、何もしない。式の位置の `begin` は、式を 1 つ以上要る。
    /// 本体の先頭に置かれた、定義だけの `begin`(空を含む)は、R7RS 7.1.3 と 7.1.6 では
    /// 合法だが、まだ受け付けない。roadmap の「スライス未割り当て」の項目にある。
    fn begin(self: *Expander, task: Task, items: []const Value) Error!void {
        if (items.len < 2) {
            if (task.pos == .top) return self.constant(task, .unspecified_value);
            return self.ctx.raise("bad begin: expected (begin expression ...)", .{});
        }
        const pos: Position = if (task.pos == .top) .top else .expression;
        try self.sequence(task.dest, items[1..], task.env, pos, 0);
    }

    /// Fills `dest` with `forms` run in order: `defines` of them at the start
    /// are definitions of a body, the rest are in `pos`.
    /// 形式が 1 つなら、その形式そのものになる(本体が定義だけということはないので、
    /// その 1 つが定義になることはない)。
    fn sequence(self: *Expander, dest: *Node, forms: []const Value, env: ?*SyntacticEnv, pos: Position, defines: usize) Error!void {
        if (forms.len == 1) {
            try self.stack.append(self.scratch, .{ .form = forms[0], .env = env, .pos = pos, .dest = dest });
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
                .env = env,
                .pos = if (i < defines) .body else pos,
                .dest = @constCast(nodes[i]),
            });
        }
        dest.* = .{ .sequence = nodes };
    }

    /// `(set! name expression)` (R7RS 4.1.6).
    /// 対象は `name` の最も近い束縛で、局所でも大域でもよい。特殊形式は変数でない
    /// ので、対象にならない。大域変数がインポートしたものなら、REPL の新しいセルで
    /// 遮蔽して、そこへ代入する(docs/design/frontend.md の REPL の表)。
    fn set(self: *Expander, task: Task, items: []const Value) Error!void {
        if (items.len != 3)
            return self.ctx.raise("bad set!: expected (set! name expression)", .{});
        const id = items[1].asSymbol() orelse
            return self.ctx.raise("bad set!: the name must be an identifier", .{});
        switch (try syntax_env.resolve(self.ctx, task.env, items[1])) {
            .special => return self.ctx.raise(
                "bad set!: {s} is a syntactic keyword and cannot be assigned",
                .{self.ctx.symbols.nameOf(id)},
            ),
            .local => |local| {
                const where = try self.address(task.env, local);
                const value = try self.child(items[2], task.env, .expression);
                task.dest.* = .{ .local_set = .{ .address = where, .name = id, .value = value } };
            },
            .global => {
                // 解決が大域変数を返したので、名前は最上位で変数であり、対象のセルがある。
                const cell = (self.ctx.globals.assignTarget(self.ctx.persist, &self.ctx.heap, id) catch |e|
                    return self.ctx.heapFailure(e)).?;
                const value = try self.child(items[2], task.env, .expression);
                task.dest.* = .{ .global_set = .{ .cell = cell, .value = value } };
            },
        }
    }

    /// `(define name expression)` and `(define (name parameter ...) body ...)`
    /// (R7RS 5.3.1).
    /// トップレベルでは、REPL の束縛の表の規則で選んだ大域変数のセルに値を与える
    /// (src/env.zig)。本体の先頭では、`lambdaNode` が作った局所変数に値を与える。
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
        switch (task.pos) {
            .top => {
                // 対象のセルは、値の式を展開する前に選ぶ(R7RS 5.3.1: 新しい場所を束縛して
                // から代入する)。値の式そのものの展開は作業スタックで後に行われるので、
                // この順序が結果に効くのは、略記の本体の定義の走査(`definedValue` の中)
                // だけである。特殊形式の名前への定義も、新しい場所を束縛する(同節)。
                // R7RS 5.4 は `(define define 3)` を誤りとするが、最上位の形式は前から順に
                // 展開し、後ろの形式は前の定義の後の束縛で読むので、すでに判定した形式の意味が
                // 後から変わることは無い。本体の定義(`collectDefinitions`)と違って、受け付ける。
                const cell = self.ctx.globals.defineTarget(self.ctx.persist, &self.ctx.heap, id) catch |e|
                    return self.ctx.heapFailure(e);
                const value = try self.definedValue(task, items, shorthand);
                task.dest.* = .{ .global_define = .{ .cell = cell, .value = value } };
            },
            // `collectDefinitions` が lambda を作るときに、この名前をその lambda の rib に
            // 束縛してある。同じ rib の仮引数を隠すので、rib の中で最も新しい束縛である。
            .body => {
                const env = task.env.?;
                // `collectDefinitions` が、本体の定義の先頭の名前が定義を意味し続けることを
                // 確かめたので、ここに来る形式の名前は必ず rib にある。
                const local = syntax_env.lookupRib(env, target).?.denotation.local;
                const value = try self.definedValue(task, items, shorthand);
                task.dest.* = .{ .local_define = .{ .address = .{ .depth = 0, .index = local.index }, .name = id, .value = value } };
            },
            .expression => unreachable,
        }
    }

    /// The node of the value a `define` gives its name.
    fn definedValue(self: *Expander, task: Task, items: []const Value, shorthand: bool) Error!*Node {
        const value = try self.ctx.persist.create(Node);
        if (shorthand) {
            try self.lambdaNode(value, items[1].asPair().?.cdr, items[2..], task.env, "define");
        } else {
            try self.stack.append(self.scratch, .{ .form = items[2], .env = task.env, .pos = .expression, .dest = value });
        }
        return value;
    }

    /// `(lambda (name ...) body ...)` (R7RS 4.1.4).
    fn lambdaForm(self: *Expander, task: Task, items: []const Value) Error!void {
        if (items.len < 3)
            return self.ctx.raise("bad lambda: expected (lambda (name ...) body ...)", .{});
        try self.lambdaNode(task.dest, items[1], items[2..], task.env, "lambda");
    }

    /// Fills `dest` with the procedure whose parameters are `params_form` and
    /// whose body is `body`, made in `env`.
    /// `form_name` は、メッセージのための、その手続きが書かれた形式の名前である。
    /// `(define (f x) ...)` は、自前の仮引数リストを持つ `define` である。
    ///
    /// 仮引数は R7RS 4.1.4 の3つの形を取る。`(a b)` は固定個、`args` は任意個、
    /// `(a b . r)` は2個以上である。余りを受ける変数は、必須の仮引数の直後の
    /// スロットに置く。仮引数と本体の定義は、新しい rib に束縛する。
    fn lambdaNode(
        self: *Expander,
        dest: *Node,
        params_form: Value,
        body: []const Value,
        env: ?*SyntacticEnv,
        comptime form_name: []const u8,
    ) Error!void {
        const inner = try syntax_env.extend(self.ctx, env);
        var slots: u32 = 0;
        var rest = params_form;
        while (rest.asPair()) |p| : (rest = p.cdr) try self.parameter(inner, &slots, p.car, form_name);
        const arity = slots;
        // リストの終わりが空リストでなければ、ドットの後ろ(または仮引数の全体)が
        // 余りを受ける変数である。識別子でないものは、仮引数の並びとして読めない。
        const has_rest = rest.kind() != .empty_list;
        if (has_rest) {
            if (rest.kind() != .symbol)
                return self.ctx.raise("bad " ++ form_name ++ ": the parameters must be an identifier or a list of identifiers", .{});
            try self.parameter(inner, &slots, rest, form_name);
        }
        const defines = try self.collectDefinitions(body, inner, &slots);
        // Why: R7RS 5.3.2 の本体は、定義のあとに式が続く形で、式は 1 つ以上要る。
        // 定義だけの本体には、返す値がない。
        if (defines == body.len)
            return self.ctx.raise("bad " ++ form_name ++ ": a body needs an expression after its definitions", .{});
        const body_node = try self.ctx.persist.create(Node);
        try self.sequence(body_node, body, inner, .expression, defines);
        const lambda = try self.ctx.persist.create(value_mod.Lambda);
        lambda.* = .{ .arity = arity, .rest = has_rest, .frame_size = slots, .body = body_node };
        dest.* = .{ .lambda = lambda };
    }

    /// Binds the next slot of a call's frame in `rib`, after checking that the
    /// procedure has room for one more variable.
    fn nextSlot(self: *Expander, rib: *SyntacticEnv, slots: *u32, id: Value) Error!void {
        if (slots.* >= self.limits.address)
            return self.ctx.raise("implementation restriction: a procedure has too many variables", .{});
        _ = try syntax_env.bindLocal(self.ctx, rib, id, slots.*);
        slots.* += 1;
    }

    /// Binds the parameter `form` in `rib`, after checking that it is an
    /// identifier that is not a parameter already.
    /// 必須の仮引数と余りを受ける変数の両方が、同じ検査を通る。特殊形式と同じ綴りでも
    /// よく、本体ではその特殊形式を隠す。
    fn parameter(self: *Expander, rib: *SyntacticEnv, slots: *u32, form: Value, comptime form_name: []const u8) Error!void {
        const id = form.asSymbol() orelse
            return self.ctx.raise("bad " ++ form_name ++ ": a parameter must be an identifier", .{});
        if (syntax_env.lookupRib(rib, form) != null)
            return self.ctx.raise("bad " ++ form_name ++ ": duplicate parameter: {s}", .{self.ctx.symbols.nameOf(id)});
        try self.nextSlot(rib, slots, form);
    }

    /// Binds the names that the definitions at the start of `body` define in
    /// `rib`, and returns how many forms they are.
    ///
    /// 形式の先頭が定義を意味するかは、仮引数と、それより前の定義を束縛した `rib` で
    /// 判定する。本体の定義の領域は本体の全体である(R7RS 5.3.2)。そのため、仮引数と
    /// 同じ名前の定義は、仮引数を隠す新しい変数になる。同じ名前を2回定義することは
    /// 誤りである(同節)。定義そのものの検査は、展開するときに行う。
    fn collectDefinitions(self: *Expander, body: []const Value, rib: *SyntacticEnv, slots: *u32) Error!usize {
        var count: usize = 0;
        for (body) |form| {
            const head = form.asPair() orelse break;
            if (try self.specialOf(rib, head.car) != .define) break;
            const rest = head.cdr.asPair() orelse
                return self.ctx.raise("bad define: expected (define name expression)", .{});
            // `(define (name parameter ...) body ...)` は、ヘッダの先頭にあるものを名前とする。
            const target = if (rest.car.asPair()) |header| header.car else rest.car;
            const id = target.asSymbol() orelse
                return self.ctx.raise("bad define: the name must be an identifier", .{});
            // rib の先頭の `count` 個が、この本体のそれまでの定義である。
            var b = rib.bindings;
            for (0..count) |_| {
                const binding = b.?;
                if (syntax_env.boundIdentifierEq(binding.id, target)) return self.ctx.raise(
                    "bad define: {s} is already defined earlier in this body",
                    .{self.ctx.symbols.nameOf(id)},
                );
                b = binding.next;
            }
            try self.nextSlot(rib, slots, target);
            count += 1;
        }
        // Why: 定義が束縛する名前が、その定義や前の定義の先頭の `define` そのものだと、
        // 定義だと判定した形式が、本体の全体を領域とする束縛のもとでは定義でなくなる。
        // R7RS 5.4 はこれを誤りとしている。展開がこの判定に頼るので、ここで拒否する。
        for (body[0..count]) |form| {
            const head = form.asPair().?.car;
            if (try self.specialOf(rib, head) != .define) return self.ctx.raise(
                "bad define: {s} is defined in a body whose definitions it begins",
                .{self.ctx.symbols.nameOf(head.asSymbol().?)},
            );
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
            try self.stack.append(self.scratch, .{ .form = items[i], .env = task.env, .pos = .expression, .dest = @constCast(operands[i - 1]) });
        }
        const operator = try self.child(items[0], task.env, .expression);
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
        try std.testing.expectEqualStrings(message, self.ctx.diagnostic());
    }
};

test "a parameter named like a special form is a variable in the body, and hides the special form there" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.expectExpands("(lambda (if) (if 1 2))", "(lambda 1 1 (call (local if 0 0) (const 1) (const 2)))");
    try f.expectExpands("(lambda (quote) 'x)", "(lambda 1 1 (call (local quote 0 0) (global x)))");
    try f.expectExpands("(lambda (set!) (set! set! 1))", "(lambda 1 1 (call (local set! 0 0) (local set! 0 0) (const 1)))");
    try f.expectExpands("(lambda define define)", "(lambda 0 rest 1 (local define 0 0))");
    try f.expectExpands("(lambda (a . lambda) (lambda a))", "(lambda 1 rest 2 (call (local lambda 0 1) (local a 0 0)))");
    // 内側の lambda からも、外側の仮引数として見える。
    try f.expectExpands("(lambda (begin) (lambda () (begin)))", "(lambda 1 1 (lambda 0 0 (call (local begin 1 0))))");
    // 仮引数の外では、同じ名前は特殊形式のままである。
    try f.expectExpands("((lambda (if) if) (if 1 2 3))", "(call (lambda 1 1 (local if 0 0)) (if (const 1) (const 2) (const 3)))");
    // 仮引数が `define` を隠すと、本体の `(define ...)` は定義でなく呼び出しになる。
    try f.expectExpands("(lambda (define) (define x 1))", "(lambda 1 1 (call (local define 0 0) (global x) (const 1)))");
}

test "a definition in a body named like a special form is a variable of the body" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.expectExpands("(lambda () (define if list) (if 1 2))", "(lambda 0 1 (seq (define-local if 0 0 (global list)) (call (local if 0 0) (const 1) (const 2))))");
    try f.expectExpands("(lambda () (define (begin) 1) (begin))", "(lambda 0 1 (seq (define-local begin 0 0 (lambda 0 0 (const 1))) (call (local begin 0 0))))");
    // 定義する名前が、その定義や前の定義を始めている `define` なら、定義の判定が
    // 変わるので拒否する(R7RS 5.4)。
    try f.expectFails("(lambda () (define define 3) 1)", "bad define: define is defined in a body whose definitions it begins");
    try f.expectFails("(lambda () (define (f) 1) (define (define) 2) (f))", "bad define: define is defined in a body whose definitions it begins");
}

test "begin with nothing in it is allowed at the top level only" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    // 最上位の `(begin)` は、何もしない定義の並びである(R7RS 7.1.6)。
    try f.expectExpands("(begin)", "(const #<unspecified>)");
    try f.expectExpands("(begin (begin) 1)", "(seq (const #<unspecified>) (const 1))");
    // 式の位置の `begin` は、式を 1 つ以上要る。
    try f.expectFails("(f (begin))", "bad begin: expected (begin expression ...)");
    try f.expectFails("(lambda () (begin))", "bad begin: expected (begin expression ...)");
    // 本体の先頭の `(begin)` は、R7RS では合法な空の定義の並びである。本体の中の
    // `begin` の展開(スプライス)が無いため、今は拒否される。その挙動は固定しない。
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
    try f.expectFails("(lambda (a . 1) a)", "bad lambda: the parameters must be an identifier or a list of identifiers");
    try f.expectFails("(lambda #t 1)", "bad lambda: the parameters must be an identifier or a list of identifiers");
    try f.expectFails("(lambda (a b . a) a)", "bad lambda: duplicate parameter: a");
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

test "a definition in a body hides a parameter of the same name in the whole body" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    // 本体の定義の領域は本体の全体である(R7RS 5.3.2)。仮引数 x のスロット 0 は、本体の
    // どこからも見えない。先の定義の式の中の x も、後で定義される x を指す。
    try f.expectExpands("(lambda (x) (define x 1) x)", "(lambda 1 2 (seq (define-local x 0 1 (const 1)) (local x 0 1)))");
    try f.expectExpands(
        "(lambda (x) (define y x) (define x 1) y)",
        "(lambda 1 3 (seq (define-local y 0 1 (local x 0 2)) (define-local x 0 2 (const 1)) (local y 0 1)))",
    );
    try f.expectExpands("(lambda r (define r 1) r)", "(lambda 0 rest 2 (seq (define-local r 0 1 (const 1)) (local r 0 1)))");
    // 内側の lambda から見ても同じである。
    try f.expectExpands(
        "(lambda (x) (define x 1) (lambda () x))",
        "(lambda 1 2 (seq (define-local x 0 1 (const 1)) (lambda 0 0 (local x 1 1))))",
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
    try f.expectFails("(lambda (1) 1)", "bad lambda: a parameter must be an identifier");
    try f.expectFails("(lambda 1 1)", "bad lambda: the parameters must be an identifier or a list of identifiers");
    try f.expectFails("(set! x)", "bad set!: expected (set! name expression)");
    try f.expectFails("(set! 1 2)", "bad set!: the name must be an identifier");
    try f.expectFails("(set! if 1)", "bad set!: if is a syntactic keyword and cannot be assigned");
    try f.expectFails("if", "if is a syntactic keyword and cannot be used as a variable");
    try f.expectFails("(define)", "bad define: expected (define name expression)");
    try f.expectFails("(define x)", "bad define: expected (define name expression)");
    try f.expectFails("(define 1 2)", "bad define: the name must be an identifier");
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
    // 同じ名前を本体で2回定義することは誤りである(R7RS 5.3.2)。間に別の定義があっても同じである。
    try f.expectFails("(lambda () (define x 1) (define x 2) x)", "bad define: x is already defined earlier in this body");
    try f.expectFails("(lambda (x) (define x 1) (define y 2) (define x 3) x)", "bad define: x is already defined earlier in this body");
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

test "a special form at the top level is not a variable or a value to assign" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.expectFails("quote", "quote is a syntactic keyword and cannot be used as a variable");
    try f.expectFails("(define #t 1)", "bad define: the name must be an identifier");
    try f.expectFails("(f if)", "if is a syntactic keyword and cannot be used as a variable");
    // 局所の束縛が隠していないところでは、本体の中でも同じである。
    try f.expectFails("(lambda (x) (set! define x))", "bad set!: define is a syntactic keyword and cannot be assigned");
    try f.expectFails("(lambda (x) (lambda (y) lambda))", "lambda is a syntactic keyword and cannot be used as a variable");
}

test "a definition at the top level of a special form's name binds a new variable" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    // 定義の後、その名前は最上位で変数である(R7RS 5.3.1)。
    try f.expectExpands("(define if 5)", "(define-global if (const 5))");
    try f.expectExpands("(if 1 2)", "(call (global if) (const 1) (const 2))");
    try f.expectExpands("(define (lambda x) x)", "(define-global lambda (lambda 1 1 (local x 0 0)))");
    try f.expectExpands("(lambda 1)", "(call (global lambda) (const 1))");
    // R7RS 5.4 が誤りの例に挙げる形も、最上位では受け付ける。前の形式の意味は変わらない。
    try f.expectExpands(
        "(begin (define begin list) (begin 1 2))",
        "(seq (define-global begin (global list)) (call (global begin) (const 1) (const 2)))",
    );
    try f.expectExpands("(define define 3)", "(define-global define (const 3))");
    try f.expectExpands("(define x 1)", "(call (global define) (global x) (const 1))");
    // `set!` の対象にはならないままである。定義した後は変数なので、代入できる。
    try f.expectFails("(set! quote 1)", "bad set!: quote is a syntactic keyword and cannot be assigned");
    try f.expectExpands("(set! if 6)", "(set-global if (const 6))");
}

test "the cell a global names is chosen when the form is expanded" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const a = f.arena.allocator();
    // 先に参照された名前の定義と、REPL 自身の変数の再定義と `set!` は、同じセルを使う。
    const use = try expand(&f.ctx, a, try f.read("(lambda () (g))"));
    const cell = use.lambda.body.call.operator.global_ref;
    try std.testing.expectEqual(cell, (try expand(&f.ctx, a, try f.read("(define g 1)"))).global_define.cell);
    try std.testing.expectEqual(cell, (try expand(&f.ctx, a, try f.read("(define (g) 2)"))).global_define.cell);
    try std.testing.expectEqual(cell, (try expand(&f.ctx, a, try f.read("(set! g 3)"))).global_set.cell);
    // インポートした変数への定義と `set!` は、新しいセルで遮蔽する。前に展開した
    // コードは元のセルを指したままである。
    const car_use = try expand(&f.ctx, a, try f.read("(lambda () car)"));
    const imported = car_use.lambda.body.global_ref;
    const shadow = (try expand(&f.ctx, a, try f.read("(define car 5)"))).global_define.cell;
    try std.testing.expect(shadow != imported);
    try std.testing.expectEqual(shadow, (try expand(&f.ctx, a, try f.read("car"))).global_ref);
    const cdr_use = try expand(&f.ctx, a, try f.read("(lambda () cdr)"));
    const assigned = (try expand(&f.ctx, a, try f.read("(set! cdr 5)"))).global_set.cell;
    try std.testing.expect(assigned != cdr_use.lambda.body.global_ref);
    try std.testing.expectEqual(assigned, (try expand(&f.ctx, a, try f.read("cdr"))).global_ref);
    // 値の式の中の同じ名前は、定義される変数を指す。
    const recursive = try expand(&f.ctx, a, try f.read("(define (cons x) (cons x))"));
    try std.testing.expectEqual(recursive.global_define.cell, recursive.global_define.value.lambda.body.call.operator.global_ref);
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
    // 残るのは、名前 `x` を解決したときに REPL の表に作った、未束縛のセル1つだけである。
    // セルは定数ではなく、表がルートとして持つ。
    try std.testing.expectEqual(1, f.ctx.heap.count);
    // クォートしたリストがその例である。対象はデータそのもので、周りの `quote` 形式のペアではない。
    const node = try expand(&f.ctx, a, try f.read("(quote (1 2))"));
    try std.testing.expectEqual(1, f.ctx.code_roots.items.len);
    // セルと、読んだ4つのペア。
    try std.testing.expectEqual(5, f.ctx.heap.count);
    f.ctx.collectIdle();
    // セルと、データの2つのペア。
    try std.testing.expectEqual(3, f.ctx.heap.count);
    try std.testing.expectEqual(2, node.constant.asPair().?.cdr.asPair().?.car.asFixnum().?);
    // 定数を作るもう一方の箇所: すでに値である形式。
    const closure = try f.ctx.heap.create(value_mod.Closure, .{ .lambda = undefined, .env = null });
    const itself = try expand(&f.ctx, a, .fromClosure(closure));
    try std.testing.expectEqual(closure, itself.constant.asClosure().?);
    try std.testing.expectEqual(2, f.ctx.code_roots.items.len);
    f.ctx.collectIdle();
    // セル、データの2つのペア、クロージャ。
    try std.testing.expectEqual(4, f.ctx.heap.count);
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
