//! The expander: data in, core IR out.
//!
//! 仕事は、特殊形式(`value.Special` の列挙が一覧である)と、マクロの適用と、呼び出しの
//! 変換である。マクロの変換子は
//! `syntax-rules` で、照合とテンプレートの展開は src/syntax/rules.zig にある。マクロの
//! 適用の結果は、同じ位置の形式として展開し直す。
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
const env_mod = @import("../env.zig");
const SyntacticEnv = syntax_env.SyntacticEnv;
const Denotation = syntax_env.Denotation;
const rules = @import("rules.zig");
const heap_mod = @import("../heap.zig");
const source = @import("source.zig");
const resolve = @import("../resolve.zig");
const positions = @import("../positions.zig");
const cond_expand = @import("cond_expand.zig");
const freeze = @import("../freeze.zig");

pub const Error = context.Error;

/// What the representation of a lexical address holds.
/// 既定は番地の幅いっぱいの値である。テストは上限に届かせるために、より小さい値を渡す。
pub const Limits = struct {
    address: u32 = std.math.maxInt(u32),
};

/// Expands `form`, which is at the top level of a program.
/// 節点は GC ヒープに確保し、上限に数える(ADR-0040)。展開の実行中だけ要るものは
/// `scratch` から取る。構文環境も GC ヒープに確保し、節点からは指さない。展開の途中では
/// GC が走らない(ADR-0031)ので、作りかけの節点はどこにも登録しない。返した根の節点は、
/// 呼び出し側が、GC の走る点に着く前に、機械の制御のレジスタに置く(`Machine.run`)。
/// エラーのときは `ctx` がメッセージを持つ。
pub fn expand(ctx: *Context, scratch: std.mem.Allocator, form: Value) Error!*const Node {
    return expandWith(ctx, scratch, form, .{});
}

pub fn expandWith(ctx: *Context, scratch: std.mem.Allocator, form: Value, limits: Limits) Error!*const Node {
    return expandIn(ctx, scratch, form, .{ .table = &ctx.globals }, limits);
}

/// What a form is expanded for: which top level it is part of, and whether the
/// rules for a program or those for the REPL apply (R7RS 5.2).
pub const Target = struct {
    /// The table of the bindings of the top level the form is in.
    table: *env_mod.Global,
    /// The environment of a library body, or null for the REPL.
    root: ?*SyntacticEnv = null,
    mode: Mode = .repl,
};

/// The rules for writing to the bindings a top level imported.
/// R7RS 5.2 は、プログラムとライブラリ宣言の中では、インポートした束縛の再定義と
/// 代入を誤りとし、REPL では許すべきとしている。
pub const Mode = enum {
    /// The REPL: a definition or an assignment shadows what was imported.
    repl,
    /// The body of a library: a definition or an assignment of an imported binding is a
    /// syntax error.
    library,
};

/// Expands `form`, which is at the top level of `target`.
pub fn expandIn(ctx: *Context, scratch: std.mem.Allocator, form: Value, target: Target, limits: Limits) Error!*const Node {
    // 展開は機械のステップの外で走り、その間は GC が走らない(ADR-0031)。展開が使う作業領域
    // はヒープの外にあるので、止まらないマクロの適用が、上限を大きく超えてメモリを使う。
    // それを避けるため、作業領域を、ヒープの上限に対して計上する(`heap.Charged`)。節点は
    // ヒープのオブジェクトなので、ほかのオブジェクトと同じく、作った時点から上限に入る。
    // 上限に収まらなければ、他の確保と同じ `heap limit exceeded` で終わる。上限の検査は、最初の
    // マクロの適用から効く(`Heap.external_enforced`)。
    // 展開は、`import` の評価の中(ライブラリのファイルの本体)でも走る。外側が数えた分は、
    // この展開の検査にも入る。終わったら、外側の計上と検査の状態に戻す。展開の作業は、
    // 外側の `import` の作業と違い、外側に残さない(今までどおり、展開ごとに数える)。
    ctx.heap.external_refused = false;
    const saved_external = ctx.heap.external;
    const saved_enforced = ctx.heap.external_enforced;
    ctx.heap.external_enforced = false;
    defer {
        ctx.heap.external = saved_external;
        ctx.heap.external_enforced = saved_enforced;
    }
    var scratch_charge: heap_mod.Charged = .{ .heap = &ctx.heap, .backing = scratch };
    var work_charge: heap_mod.Charged = .{ .heap = &ctx.heap, .backing = ctx.heap.backing };
    var e: Expander = .{
        .ctx = ctx,
        .scratch = scratch_charge.allocator(),
        .work = .init(work_charge.allocator()),
        .limits = limits,
        .top = target.table,
        .root = target.root,
        .mode = target.mode,
    };
    defer e.work.deinit();
    // 展開が失敗したら、この形式が遮蔽した特殊形式を戻す。失敗した形式は実行されない
    // ので、遮蔽だけが残ると、特殊形式を理由なく失う。
    errdefer target.table.undoShadows();
    // 失敗した形式の節点と、節点が持つ定数は、どこからも指されないごみになり、次の GC が
    // 回収する。ここで手放すものは無い。
    // 失敗した展開が、読んでいる最中のファイルとして載せたものも、手放す。
    const reading = ctx.sources.items.len;
    errdefer ctx.sources.shrinkRetainingCapacity(reading);
    const root = e.run(form) catch |err| {
        // 計上の上限で断られた確保は、呼び出し側には確保の失敗に見える。
        if (err == error.OutOfMemory and ctx.heap.external_refused) return ctx.raise(context.heap_limit_message, .{});
        return err;
    };
    target.table.commitShadows();
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
    op: Op = .expand,
    /// For `include_file`: whether the file is read with case folded (`include-ci`).
    fold_case: bool = false,
    /// Where the nearest form that holds this one was read, for the message of an error
    /// (docs/design/frontend.md の位置情報).
    /// マクロの出力と、ペアでない形式は、位置を持たないので、これを引き継ぐ。
    site: ?positions.Position = null,
    /// For `enter_file`: the file that the forms after this task were read from.
    origin: ?resolve.Origin = null,

    /// What a task does.
    const Op = enum {
        /// Expand `form`.
        expand,
        /// Read the file whose name `form` is, and expand the data in it in place of `dest`.
        include_file,
        /// The forms of a body that come next were read from the file `origin`, which an
        /// `include` at the start of the body read (`scanBody`).
        enter_file,
        /// The data of a file that an `include` read have all been expanded.
        leave_file,
    };
};

const Expander = struct {
    ctx: *Context,
    /// Where the work of the expansion goes, counted against the limit of the heap.
    scratch: std.mem.Allocator,
    /// The work area of one application of a macro, emptied after each one.
    work: std.heap.ArenaAllocator,
    limits: Limits,
    /// The table of the top level the forms are part of.
    top: *env_mod.Global,
    /// The environment of the top level's forms: the root of a library body, or null at
    /// the REPL.
    root: ?*SyntacticEnv,
    mode: Mode,
    stack: std.ArrayList(Task) = .empty,

    /// A new node in the heap, for a task to fill.
    /// 子が決まる前に作るので、無害な値(未規定値の定数)で始める。展開が失敗して、作りかけの
    /// まま回収されても、`Heap.free` は変種を読めば足りる。
    fn newNode(self: *Expander) Error!*Node {
        return self.ctx.create(Node, .{ .constant = .unspecified_value });
    }

    /// A list of `len` nodes for `owner`, each a new node, held by `owner` before
    /// anything else is allocated (`Heap.allocAttached`).
    /// `attach` が、列を `owner` に持たせる。持たせてから要素の節点を作るので、要素を作る
    /// 途中で失敗しても、列は `owner` と一緒に回収される。
    fn newNodes(self: *Expander, len: usize, owner: *Node, comptime attach: fn (*Node, []*const Node) void) Error![]*const Node {
        const list = self.ctx.heap.allocAttached(*const Node, len) catch |e| return self.ctx.heapFailure(e);
        attach(owner, list);
        for (list) |*n| n.* = try self.newNode();
        return list;
    }

    fn attachSequence(owner: *Node, list: []*const Node) void {
        owner.* = .{ .sequence = list };
    }

    /// 演算子は、決まるまで持ち主自身を指しておく(未設定のポインタを持たない)。
    fn attachOperands(owner: *Node, list: []*const Node) void {
        owner.* = .{ .call = .{ .operator = owner, .operands = list } };
    }

    /// Where `form` was read, or null when it was not read from a file, or no
    /// positions are kept.
    fn siteOf(self: *const Expander, form: Value) ?positions.Position {
        const table = self.ctx.positions orelse return null;
        return table.of(form);
    }

    /// Keeps that `output`, the output of a macro, stands at `site`, when it is a
    /// pair without a place of its own.
    /// Why: 本体の先頭のマクロの出力は、仕事を通らずに本体の形式の並びに入るので、仕事の
    /// 位置の引き継ぎ(`run`)が届かない。表に置けば、仕事になったときに `run` が引く。
    fn inheritSite(self: *Expander, output: Value, site: ?positions.Position) Error!void {
        const table = self.ctx.positions orelse return;
        const at = site orelse return;
        const pair = output.asPair() orelse return;
        if (table.by_pair.contains(pair)) return;
        try table.record(pair, at);
    }

    /// Expands `form`, which is at the top level, and returns its node.
    fn run(self: *Expander, form: Value) Error!*const Node {
        const root = try self.newNode();
        try self.stack.append(self.scratch, .{ .form = form, .env = self.root, .pos = .top, .dest = root });
        while (self.stack.pop()) |popped| {
            var task = popped;
            if (self.ctx.positions) |table| task.site = table.of(task.form) orelse task.site;
            const pushed = self.stack.items.len;
            self.step(task) catch |e| {
                if (e == error.Raised) self.ctx.noteRaisedAt(task.site);
                return e;
            };
            // この形式が積んだ仕事は、この形式の中にある。位置を持たないものは、この位置を引き継ぐ。
            for (self.stack.items[pushed..]) |*queued| queued.site = queued.site orelse task.site;
        }
        return root;
    }

    fn step(self: *Expander, task: Task) Error!void {
        switch (task.op) {
            .expand => {},
            .include_file => return self.includeFile(task),
            .enter_file => return self.ctx.sources.append(self.ctx.resident(), task.origin.?),
            .leave_file => {
                _ = self.ctx.sources.pop();
                return;
            },
        }
        switch (task.form.kind()) {
            // 自己評価式(R7RS 4.1.2)。
            .fixnum, .boolean, .character, .string, .vector, .bytevector, .unspecified, .uninitialized, .condition, .primitive, .closure, .record, .record_type, .continuation, .multiple_values, .parameter, .eof, .promise, .flonum, .bignum, .ratnum, .compnum => try self.constant(task, task.form),
            // Why: R7RS 4.1.3 は、手続き呼び出しに空でないリストを与えている。
            .empty_list => return self.ctx.raise("empty combination", .{}),
            .symbol, .alias => try self.reference(task),
            .pair => {
                // Why: マクロの適用は、先頭が決まれば、形式がドット対でもよい(R7RS 4.3.2 は
                // 末尾のパターンを許す)。リストであることを求めるのは、特殊形式と呼び出しだけで
                // ある。
                const head = try self.headOf(task.env, task.form.asPair().?.car);
                if (head) |denotation| switch (denotation) {
                    // 適用の結果は、同じ位置の同じ節点を埋める形式として展開し直す。
                    .macro => |m| {
                        const output = try rules.transform(self.ctx, &self.work, m, task.form, task.env);
                        try self.stack.append(self.scratch, .{ .form = output, .env = task.env, .pos = task.pos, .dest = task.dest });
                        return;
                    },
                    else => {},
                };
                const items = try self.itemsOf(task.form);
                if (head) |denotation| switch (denotation) {
                    .special => |special| return switch (special) {
                        .define => self.define(task, items),
                        .quote => self.quote(task, items),
                        .@"if" => self.conditional(task, items),
                        .lambda => self.lambdaForm(task, items),
                        .begin => self.begin(task, items),
                        .@"set!" => self.set(task, items),
                        .@"define-syntax" => self.defineSyntax(task, items),
                        .@"syntax-rules" => self.ctx.raise("bad syntax-rules: it is only allowed as the transformer of a syntax definition", .{}),
                        .@"let-syntax" => self.letSyntax(task, items, false),
                        .@"letrec-syntax" => self.letSyntax(task, items, true),
                        .@"syntax-error" => self.syntaxError(items),
                        .parameterize => self.parameterizeForm(task, items),
                        .include => self.includeForm(task, items, false),
                        .@"include-ci" => self.includeForm(task, items, true),
                        .@"cond-expand" => self.condExpand(task, items),
                    },
                    .macro => unreachable,
                    // 補助構文は、演算子の位置でも変数として使えない。呼び出しの演算子の展開が報告する。
                    .local, .global, .auxiliary => {},
                };
                try self.call(task, items);
            },
        }
    }

    /// What `head` means in `env`, or null when it is not an identifier.
    fn headOf(self: *Expander, env: ?*const SyntacticEnv, head: Value) Error!?Denotation {
        if (!syntax_env.isIdentifier(head)) return null;
        return try syntax_env.resolve(self.ctx, env, head);
    }

    /// The special form that `head` names in `env`, or null when it is not an
    /// identifier that means one.
    fn specialOf(self: *Expander, env: ?*const SyntacticEnv, head: Value) Error!?syntax_env.Special {
        const d = try self.headOf(env, head) orelse return null;
        return switch (d) {
            .special => |special| special,
            .local, .global, .macro, .auxiliary => null,
        };
    }

    /// The name of the identifier `id`, for a message.
    fn nameOf(self: *Expander, id: Value) []const u8 {
        return self.ctx.heap.symbols.nameOf(syntax_env.baseSymbol(id));
    }

    /// Makes the node of `task` the constant `v`.
    /// 節点は GC ヒープにあり、定数は節点から辿られる。
    /// マクロのテンプレートが導入した別名は、ここで元のシンボルに戻す(`stripAliases`)。
    fn constant(self: *Expander, task: Task, v: Value) Error!void {
        const datum = try self.stripAliases(v);
        // R7RS 3.4 と 4.1.2: リテラルは定数である。到達できるデータのすべてに不変の印を立て、
        // 書き込む手続きが断る。`quote` と自己評価するリテラルは、どちらもここを通る。
        try freeze.freezeGraph(self.scratch, datum);
        task.dest.* = .{ .constant = datum };
    }

    /// `v` with each alias in it replaced by the symbol it was written as
    /// (docs/design/frontend.md, stripping in `quote`).
    ///
    /// 別名を含まなければ `v` そのものを返し、写さない。含めば、オブジェクトの同一性を
    /// キーにした対応表で全体を写す。ペアとベクタは、中身を埋める前に対応表に登録する
    /// ので、同じオブジェクトに2回着いたら同じ写しを返し、共有と循環がそのまま写る。
    /// 2つの走査は、どちらも訪問済みの表を持ち、再帰しない。展開の途中では GC が走らない
    /// (ADR-0031)ので、表はルートにしない。
    fn stripAliases(self: *Expander, v: Value) Error!Value {
        if (!try self.containsAlias(v)) return v;
        var copies: std.AutoHashMapUnmanaged(usize, Value) = .empty;
        var fills: std.ArrayList(Fill) = .empty;
        const root = try self.copyStripped(&copies, &fills, v);
        while (fills.pop()) |f| f.slot.* = try self.copyStripped(&copies, &fills, f.from);
        return root;
    }

    /// A place in a copy still to fill with the copy of `from`.
    const Fill = struct { slot: *Value, from: Value };

    /// Whether `v` holds an alias anywhere in the graph of pairs and vectors
    /// it reaches.
    fn containsAlias(self: *Expander, v: Value) Error!bool {
        var visited: std.AutoHashMapUnmanaged(usize, void) = .empty;
        var stack: std.ArrayList(Value) = .empty;
        try stack.append(self.scratch, v);
        while (stack.pop()) |x| switch (x.kind()) {
            .alias => return true,
            .pair => {
                const p = x.asPair().?;
                if ((try visited.getOrPut(self.scratch, @intFromPtr(p))).found_existing) continue;
                try stack.append(self.scratch, p.cdr);
                try stack.append(self.scratch, p.car);
            },
            .vector => {
                const vec = x.asVector().?;
                if ((try visited.getOrPut(self.scratch, @intFromPtr(vec))).found_existing) continue;
                try stack.appendSlice(self.scratch, vec.items);
            },
            else => {},
        };
        return false;
    }

    /// The copy of `v` without aliases: made now if `v` is a pair or a vector
    /// not met before, with its contents left in `fills` to copy.
    fn copyStripped(self: *Expander, copies: *std.AutoHashMapUnmanaged(usize, Value), fills: *std.ArrayList(Fill), v: Value) Error!Value {
        switch (v.kind()) {
            .alias => return .fromSymbol(syntax_env.baseSymbol(v)),
            .pair => {
                const p = v.asPair().?;
                if (copies.get(@intFromPtr(p))) |copy| return copy;
                const copy = self.ctx.heap.cons(.unspecified_value, .unspecified_value) catch |e| return self.ctx.heapFailure(e);
                try copies.put(self.scratch, @intFromPtr(p), copy);
                const c = copy.asPair().?;
                try fills.append(self.scratch, .{ .slot = &c.cdr, .from = p.cdr });
                try fills.append(self.scratch, .{ .slot = &c.car, .from = p.car });
                return copy;
            },
            .vector => {
                const vec = v.asVector().?;
                if (copies.get(@intFromPtr(vec))) |copy| return copy;
                // 写しの要素は、元の要素で始め、後で写しに置き換える。
                const c = self.ctx.heap.createVector(vec.items) catch |e| return self.ctx.heapFailure(e);
                const copy: Value = .fromVector(c);
                try copies.put(self.scratch, @intFromPtr(vec), copy);
                for (c.items, vec.items) |*slot, from| try fills.append(self.scratch, .{ .slot = slot, .from = from });
                return copy;
            },
            else => return v,
        }
    }

    /// Queues `form` to fill a new node, and returns the node.
    fn child(self: *Expander, form: Value, env: ?*SyntacticEnv, pos: Position) Error!*Node {
        const node = try self.newNode();
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
        const id = syntax_env.baseSymbol(task.form);
        task.dest.* = switch (try syntax_env.resolve(self.ctx, task.env, task.form)) {
            // R7RS 4.3 は、マクロのキーワードを式として使うことを定めていない。補助構文も
            // 式にならない。
            .special, .macro, .auxiliary => return self.ctx.raise(
                "{s} is a syntactic keyword and cannot be used as a variable",
                .{self.ctx.heap.symbols.nameOf(id)},
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

    /// `(cond-expand <clause> ...)` (R7RS 4.2.1): the body of the clause that applies,
    /// expanded as the forms of a `begin` in the same position.
    /// どの節も当てはまらず `else` も無いときの結果は、R7RS 4.2.1 が unspecified としている(原文で確認した)。
    /// 最上位では何もしない(`(begin)` と同じ)。式の位置では、値を作れないので、誤りにする。
    fn condExpand(self: *Expander, task: Task, items: []const Value) Error!void {
        const chosen = try cond_expand.select(self.ctx, self.scratch, items[1..]) orelse {
            if (task.pos == .top) return self.constant(task, .unspecified_value);
            return self.ctx.raise("bad cond-expand: no clause applies, and there is no else clause", .{});
        };
        const body = try self.itemsOf(chosen);
        if (body.len == 0) {
            if (task.pos == .top) return self.constant(task, .unspecified_value);
            return self.ctx.raise("bad cond-expand: the clause that applies has no expression", .{});
        }
        const pos: Position = if (task.pos == .top) .top else .expression;
        try self.sequence(task.dest, body, task.env, pos, 0);
    }

    /// `(include <string> ...)` and `(include-ci <string> ...)` (R7RS 4.1.7, 5.6.1): the
    /// data in the files, expanded as the forms of a `begin` in the same position.
    /// `include-ci` は、ファイルを `#!fold-case` で始まるものとして読む。リーダの畳み込みの
    /// 状態を真にして読むだけで、展開は `include` と同じである。
    /// Why: ファイルは、展開が進んでそこに着いたときに読む。ファイルのデータを展開し終えるまで、
    /// そのファイルは「読んでいる最中のファイル」として `ctx.sources` に載り、`include` の
    /// 基準のディレクトリになり、自分自身を含む鎖を見つける。展開は再帰しないので、終わりの
    /// 印を、データの下にスタックしておく(`leave_file`)。名前が複数あれば、1つずつ順に読む。
    fn includeForm(self: *Expander, task: Task, items: []const Value, fold_case: bool) Error!void {
        const names = try self.includeNames(items, fold_case);
        if (names.len == 1) {
            try self.stack.append(self.scratch, .{ .form = names[0], .env = task.env, .pos = task.pos, .dest = task.dest, .op = .include_file, .fold_case = fold_case });
            return;
        }
        const nodes = try self.newNodes(names.len, task.dest, attachSequence);
        var i = names.len;
        while (i > 0) {
            i -= 1;
            try self.stack.append(self.scratch, .{ .form = names[i], .env = task.env, .pos = task.pos, .dest = @constCast(nodes[i]), .op = .include_file, .fold_case = fold_case });
        }
    }

    /// The file names of `(include <string> ...)` or `(include-ci <string> ...)`,
    /// after checking that there is one at least and that each is a string.
    fn includeNames(self: *Expander, items: []const Value, fold_case: bool) Error![]const Value {
        const what = if (fold_case) "include-ci" else "include";
        const names = items[1..];
        if (names.len == 0) return self.ctx.raise("bad {s}: expected ({s} <file name> ...)", .{ what, what });
        for (names) |name| {
            if (name.asString() == null) return self.ctx.raise("bad {s}: a file name must be a string", .{what});
        }
        return names;
    }

    /// The file that the name `name` of an include means, opened, and the data in it.
    /// 名前は、読んでいる最中のファイルの一番内側(無ければ作業ディレクトリ)を基準にする。
    fn readIncluded(self: *Expander, name: []const u8, fold_case: bool) Error!struct { origin: resolve.Origin, data: []const Value } {
        const what = if (fold_case) "include-ci" else "include";
        const opened = try source.openIncluded(self.ctx, self.scratch, name, what);
        // Why: ファイルのデータは、大きさが REPL の1行の上限に縛られず、1 MiB のファイル1つが
        // 数十 MiB の節点になる。入れ子や名前の並びで掛け算になるので、マクロの適用を待たず、
        // ファイルを読む時点から、作業領域と節点をヒープの上限に数える(`Heap.external_enforced`)。
        self.ctx.heap.external_enforced = true;
        const subject = try std.fmt.allocPrint(self.scratch, "{s} {s}", .{ what, name });
        const data = try source.readDataFrom(self.ctx, self.scratch, self.ctx.files, opened.source, opened.origin, subject, fold_case);
        return .{ .origin = opened.origin, .data = data };
    }

    /// Reads the file that the name `task.form` means and queues its data to fill
    /// `task.dest`, in order. A file with no data does nothing.
    fn includeFile(self: *Expander, task: Task) Error!void {
        const read = try self.readIncluded(task.form.asString().?.bytes, task.fold_case);
        const data = read.data;
        if (data.len == 0) return self.constant(task, .unspecified_value);
        try self.ctx.sources.append(self.ctx.resident(), read.origin);
        // 終わりの印は、データの下に積む。データと、データが展開に使う仕事が先に済む。
        try self.stack.append(self.scratch, .{ .form = .unspecified_value, .env = null, .pos = .top, .dest = task.dest, .op = .leave_file });
        const pos: Position = if (task.pos == .top) .top else .expression;
        try self.sequence(task.dest, data, task.env, pos, 0);
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
        // 節点は順に作り、後ろのものから先にスタックに積む。
        const nodes = try self.newNodes(forms.len, dest, attachSequence);
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
    }

    /// `(parameterize ((param value) ...) body ...)` (R7RS 4.2.6).
    /// 束縛は空でもよい。本体は `<body>` なので、引数の無い `lambda` の本体と同じ形に展開し、
    /// 先頭に定義を置けるようにする。機械が、その本体のためのフレームを作って走らせる。
    fn parameterizeForm(self: *Expander, task: Task, items: []const Value) Error!void {
        if (items.len < 3)
            return self.ctx.raise("bad parameterize: expected (parameterize ((parameter value) ...) body ...)", .{});
        // 束縛の式は、パラメータと値を交互に並べる。
        var forms: std.ArrayList(Value) = .empty;
        var rest = items[1];
        while (rest.asPair()) |p| : (rest = p.cdr) {
            const bad = "bad parameterize: a binding must be (parameter value)";
            const first = p.car.asPair() orelse return self.ctx.raise(bad, .{});
            const second = first.cdr.asPair() orelse return self.ctx.raise(bad, .{});
            if (second.cdr.kind() != .empty_list) return self.ctx.raise(bad, .{});
            try forms.append(self.scratch, first.car);
            try forms.append(self.scratch, second.car);
        }
        if (rest.kind() != .empty_list)
            return self.ctx.raise("bad parameterize: the bindings must be a list", .{});
        // 束縛の列は、`Parameterize` を作る時点で持たせ、その後で埋める(`Heap.allocAttached`)。
        // 本体の `lambda` は最後に決まり、それまでは未設定である。途中で失敗したら、
        // `Parameterize` はごみになり、`Heap.free` は列の長さしか読まない。
        const body = try self.newNode();
        const bindings = self.ctx.heap.allocAttached(value_mod.ParameterBinding, forms.items.len / 2) catch |e| return self.ctx.heapFailure(e);
        const parameterize = self.ctx.create(value_mod.Parameterize, .{ .bindings = bindings, .body = undefined }) catch |e| {
            self.ctx.heap.freeDetached(value_mod.ParameterBinding, bindings);
            return e;
        };
        task.dest.* = .{ .parameterize = parameterize };
        for (bindings, 0..) |*b, i| b.* = .{
            .param = try self.child(forms.items[2 * i], task.env, .expression),
            .value = try self.child(forms.items[2 * i + 1], task.env, .expression),
        };
        try self.lambdaNode(body, .empty_list_value, items[2..], task.env, "parameterize");
        parameterize.body = body.lambda;
    }

    /// `(set! name expression)` (R7RS 4.1.6).
    /// 対象は `name` の最も近い束縛で、局所でも大域でもよい。特殊形式は変数でない
    /// ので、対象にならない。大域変数がインポートしたものなら、REPL の新しいセルで
    /// 遮蔽して、そこへ代入する(docs/design/frontend.md の REPL の表)。
    fn set(self: *Expander, task: Task, items: []const Value) Error!void {
        if (items.len != 3)
            return self.ctx.raise("bad set!: expected (set! name expression)", .{});
        if (!syntax_env.isIdentifier(items[1]))
            return self.ctx.raise("bad set!: the name must be an identifier", .{});
        const id = syntax_env.baseSymbol(items[1]);
        const resolution = try syntax_env.resolveAt(self.ctx, task.env, items[1]);
        switch (resolution.denotation) {
            .special, .macro, .auxiliary => return self.ctx.raise(
                "bad set!: {s} is a syntactic keyword and cannot be assigned",
                .{self.ctx.heap.symbols.nameOf(id)},
            ),
            .local => |local| {
                const where = try self.address(task.env, local);
                const value = try self.child(items[2], task.env, .expression);
                task.dest.* = .{ .local_set = .{ .address = where, .name = id, .value = value } };
            },
            .global => |resolved| {
                // 解決が大域変数を返したので、名前は最上位で変数であり、対象のセルがある。
                // 別名も、構文環境に束縛が無ければ、最上位の束縛を元のシンボルの名前で引く
                // (`syntax_env.resolve`)ので、同じセルになる。
                const table = resolution.table.?;
                const cell = if (self.mode == .repl and table == self.top)
                    // REPL 自身の変数ならそのセルに、インポートした変数なら遮蔽した新しいセルに代入する。
                    (table.assignTarget(self.ctx.resident(), &self.ctx.heap, resolution.symbol) catch |e|
                        return self.ctx.heapFailure(e)).?
                else blk: {
                    // ライブラリの本体と、マクロが持ち込んだ別のライブラリの変数は、遮蔽せずに、
                    // その変数のセルに代入する。インポートした束縛への代入は誤りである。
                    if (table.lookup(resolution.symbol).?.imported) return self.ctx.raise(
                        "bad set!: {s} is an imported binding and cannot be assigned",
                        .{self.ctx.heap.symbols.nameOf(id)},
                    );
                    break :blk resolved;
                };
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
        if (!syntax_env.isIdentifier(target))
            return self.ctx.raise("bad define: the name must be an identifier", .{});
        const id = syntax_env.baseSymbol(target);
        switch (task.pos) {
            .top => {
                // 対象のセルは、値の式を展開する前に選ぶ(R7RS 5.3.1: 新しい場所を束縛して
                // から代入する)。値の式そのものの展開は作業スタックで後に行われるので、
                // この順序が結果に効くのは、略記の本体の定義の走査(`definedValue` の中)
                // だけである。特殊形式の名前への定義も、新しい場所を束縛する(同節)。
                // R7RS 5.4 は `(define define 3)` を誤りとするが、最上位の形式は前から順に
                // 展開し、後ろの形式は前の定義の後の束縛で読むので、すでに判定した形式の意味が
                // 後から変わることは無い。本体の定義(`scanBody`)と違って、受け付ける。
                // 名前が別名(マクロのテンプレートが導入したもの)なら、元のシンボルの名前を
                // 束縛する。最上位の束縛の表は名前で引くので、同じ展開の中の同じ別名の参照
                // も、このセルに解決される。
                if (self.mode == .library) try self.checkNotImported(id, "define");
                const cell = self.top.defineTarget(self.ctx.resident(), &self.ctx.heap, id) catch |e|
                    return self.ctx.heapFailure(e);
                const value = try self.definedValue(task, items, shorthand);
                task.dest.* = .{ .global_define = .{ .cell = cell, .value = value } };
            },
            // `scanBody` が lambda を作るときに、この名前をその lambda の rib に
            // 束縛してある。同じ rib の仮引数を隠すので、rib の中で最も新しい束縛である。
            .body => {
                const env = task.env.?;
                // `scanBody` が、本体の定義の先頭の名前が定義を意味し続けることと、同じ名前を
                // 2回定義しないことを確かめたので、ここに来る形式の名前は必ず rib にあり、
                // 局所変数である。
                const local = syntax_env.lookupRib(env, target).?.denotation.local;
                const value = try self.definedValue(task, items, shorthand);
                task.dest.* = .{ .local_define = .{ .address = .{ .depth = 0, .index = local.index }, .name = id, .value = value } };
            },
            .expression => unreachable,
        }
    }

    /// The node of the value a `define` gives its name.
    fn definedValue(self: *Expander, task: Task, items: []const Value, shorthand: bool) Error!*Node {
        const value = try self.newNode();
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
            if (!syntax_env.isIdentifier(rest))
                return self.ctx.raise("bad " ++ form_name ++ ": the parameters must be an identifier or a list of identifiers", .{});
            try self.parameter(inner, &slots, rest, form_name);
        }
        const scanned = try self.scanBody(body, inner, &slots, form_name);
        const body_node = try self.newNode();
        try self.bodySequence(body_node, scanned, inner);
        const lambda = try self.ctx.create(value_mod.Lambda, .{ .arity = arity, .rest = has_rest, .frame_size = slots, .body = body_node });
        dest.* = .{ .lambda = lambda };
    }

    /// Fills `dest` with the forms of `body` run in order, in `rib`: the definitions
    /// at the start, and the expressions after them.
    /// 節点は形式だけに作る。ファイルの出入りの印は、その間の形式の仕事を挟む仕事にする
    /// (`enter_file` と `leave_file`)。形式が 1 つなら、その形式が `dest` を埋める。
    fn bodySequence(self: *Expander, dest: *Node, body: Body, rib: *SyntacticEnv) Error!void {
        const nodes: []const *const Node = if (body.forms == 1) &.{} else try self.newNodes(body.forms, dest, attachSequence);
        // 後ろのものから先に積むので、前の形式が先に展開される。
        var i = body.items.len;
        var n = body.forms;
        while (i > 0) {
            i -= 1;
            try self.stack.append(self.scratch, switch (body.items[i]) {
                .form => |form| blk: {
                    n -= 1;
                    break :blk .{
                        .form = form,
                        .env = rib,
                        .pos = if (n < body.defines) .body else .expression,
                        .dest = if (body.forms == 1) dest else @constCast(nodes[n]),
                    };
                },
                .enter => |origin| .{ .form = .unspecified_value, .env = null, .pos = .top, .dest = dest, .op = .enter_file, .origin = origin },
                .leave => .{ .form = .unspecified_value, .env = null, .pos = .top, .dest = dest, .op = .leave_file },
            });
        }
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
    /// 仮引数は、マクロのテンプレートが導入した別名でもよい。重複は `bound-identifier=?`
    /// で判定するので、同じ綴りでも、別の展開が導入した別名とシンボルは別の仮引数である。
    fn parameter(self: *Expander, rib: *SyntacticEnv, slots: *u32, form: Value, comptime form_name: []const u8) Error!void {
        if (!syntax_env.isIdentifier(form))
            return self.ctx.raise("bad " ++ form_name ++ ": a parameter must be an identifier", .{});
        if (syntax_env.lookupRib(rib, form) != null)
            return self.ctx.raise("bad " ++ form_name ++ ": duplicate parameter: {s}", .{self.nameOf(form)});
        try self.nextSlot(rib, slots, form);
    }

    /// The forms of a body, the macro uses at its start expanded, with where the
    /// files an `include` at its start read begin and end among them; how many
    /// forms there are; and how many of them, from the start, are definitions.
    const Body = struct { items: []const BodyItem, forms: usize, defines: usize };

    /// A form of a body, or the place where the forms of a file begin or end.
    const BodyItem = union(enum) {
        form: Value,
        /// The forms after this were read from the file.
        enter: resolve.Origin,
        /// The forms of the file that the nearest `enter` before this began end here.
        leave,
    };

    /// Forms of a body that the scan has not looked at yet, and the file they
    /// were read from, if an `include` at the start of the body read them.
    const Pending = struct {
        forms: []const Value,
        origin: ?resolve.Origin = null,
        /// Whether the scan has put the file on `ctx.sources` and an `enter` in the body.
        entered: bool = false,
    };

    /// A head identifier the scan of a body decided a form by, and what it
    /// meant then.
    const Decided = struct { id: Value, denotation: Denotation };

    /// Scans the definitions at the start of `body`: binds the names that they
    /// define in `rib`, and returns the forms of the body with the macro uses
    /// among them expanded.
    ///
    /// 本体の走査は展開と交互に進む(docs/design/frontend.md の展開器)。先頭の意味が
    /// マクロなら適用して、結果をもう一度判定する。`define-syntax` は、その場で変換子を
    /// 作って rib に束縛し、後の形式の判定から見える。`define` は名前にスロットを与える。
    /// 定義でも、定義に展開されるマクロの適用でもない最初の形式で、定義の並びが終わる。
    /// 適用の結果は返す形式の中に置くので、同じ形式を2回展開しない。
    ///
    /// 先頭の意味が `begin` なら、その中の形式を、残りの前に置いて、同じ並びとして走査する
    /// (R7RS 5.3.2 は、定義を置ける場所では、`begin` を、その中の定義の並びと同じとする)。
    /// 空の `(begin)` は、空の並びである。`cond-expand` は、当てはまる節の中身を、同じように
    /// 並びとして走査する。当てはまる節が無ければ、空の並びである(最上位と同じ。R7RS 4.2.1 は
    /// この場合を unspecified としている)。`include` と `include-ci` は、ここでファイルを読み、
    /// その中身を並びとして走査する。ファイルの中身を走査するあいだは、そのファイルを
    /// `ctx.sources` に載せ、中の `include` の基準にする。走査のあとで展開する形式のために、
    /// ファイルの中身の前後に出入りの印を置く(`BodyItem`)。走査を終えたら、載せたファイルを
    /// 下ろす。展開のときは、印の仕事が載せ直す(`bodySequence`)。
    /// Why: スライス 3i の `define-record-type` と `define-values` は、マクロの適用が複数の
    /// 定義を作るので、`(begin (define ...) ...)` に展開する。本体の中でも使えるように、
    /// `begin` をここで展開する。`include` と `cond-expand` の定義(R7RS 4.1.7、4.2.1、5.3.2)は、
    /// スライス 3p-1 が足した。
    ///
    /// 定義の後に式が無ければ、誤りにする(R7RS 5.3.2 の本体は、定義のあとに式が 1 つ以上続く
    /// 形で、定義だけの本体には返す値が無い)。`form_name` は、そのメッセージのための、本体を
    /// 持つ形式の名前である。
    ///
    /// 形式の先頭の意味は、仮引数と、それより前の定義を束縛した `rib` で判定する。本体の
    /// 定義の領域は本体の全体である(R7RS 5.3.2)。そのため、仮引数と同じ名前の定義は、
    /// 仮引数を隠す新しい変数になる。同じ名前を2回定義することは誤りである(同節)。
    /// `define` の検査は、展開するときに行う。`define-syntax` の検査は、ここで行う。
    ///
    /// `define-syntax` の変換子が読むのに使った識別子(`rules.compile` の `consulted` と、
    /// 変換子の先頭)は、後の定義が束縛するたびに、意味が変わらないことを確かめる
    /// (`checkDepended`)。本体の終わりまで待てない。走査の途中でマクロを適用するので、
    /// 待つと、定義の時点の検査が見ていない読み方で先に適用される。
    fn scanBody(self: *Expander, body: []const Value, rib: *SyntacticEnv, slots: *u32, comptime form_name: []const u8) Error!Body {
        var items: std.ArrayList(BodyItem) = .empty;
        var forms: usize = 0;
        // この本体が定義した名前と、判定に使った先頭の識別子。
        var defined: std.ArrayList(Value) = .empty;
        var decided: std.ArrayList(Decided) = .empty;
        // 変換子が読むのに使った識別子と、そのときの意味。
        var depended: std.ArrayList(Decided) = .empty;
        var consulted: std.ArrayList(Value) = .empty;
        // まだ見ていない形式の並びの積み。`begin` を展開すると、その中の形式を、残りの前に積む。
        var pending: std.ArrayList(Pending) = .empty;
        try pending.append(self.scratch, .{ .forms = body });
        // 走査が載せたファイルは、走査を終えたら下ろす。失敗のときは、展開の入口も下ろす。
        const reading = self.ctx.sources.items.len;
        defer self.ctx.sources.shrinkRetainingCapacity(reading);
        // 本体の先頭の形式は、仕事を積まずにここで調べるので、送出したら、調べていた形式の位置を
        // 記録する(`run` は、本体を持つ形式の位置しか知らない)。
        var site: ?positions.Position = null;
        // 送出でない失敗(確保の失敗)では、位置は読まれない(`Interpreter.located`)。
        errdefer self.ctx.noteRaisedAt(site);
        while (pending.items.len > 0) {
            const next = &pending.items[pending.items.len - 1];
            if (next.origin != null and !next.entered) {
                next.entered = true;
                try self.ctx.sources.append(self.ctx.resident(), next.origin.?);
                try items.append(self.scratch, .{ .enter = next.origin.? });
            }
            if (next.forms.len == 0) {
                if (pending.pop().?.entered) {
                    _ = self.ctx.sources.pop();
                    try items.append(self.scratch, .leave);
                }
                continue;
            }
            var form = next.forms[0];
            next.forms = next.forms[1..];
            site = self.siteOf(form);
            const definition = while (true) {
                const pair = form.asPair() orelse break false;
                const head = try self.headOf(rib, pair.car) orelse break false;
                switch (head) {
                    .special => |special| switch (special) {
                        .define => {
                            const target = try self.definedName(pair);
                            try self.defineOnce(&defined, target, "define");
                            try self.nextSlot(rib, slots, target);
                            try self.checkDepended(rib, depended.items, target, "define");
                            try items.append(self.scratch, .{ .form = form });
                            forms += 1;
                        },
                        .begin => {
                            const inside = (try self.itemsOf(form))[1..];
                            for (inside) |item| try self.inheritSite(item, site);
                            try pending.append(self.scratch, .{ .forms = inside });
                        },
                        .@"cond-expand" => {
                            const chosen = try cond_expand.select(self.ctx, self.scratch, (try self.itemsOf(form))[1..]);
                            const inside = if (chosen) |clause| try self.itemsOf(clause) else &.{};
                            for (inside) |item| try self.inheritSite(item, site);
                            try pending.append(self.scratch, .{ .forms = inside });
                        },
                        .include, .@"include-ci" => {
                            const fold_case = special == .@"include-ci";
                            const names = try self.includeNames(try self.itemsOf(form), fold_case);
                            // ファイルは、名前を書いた順に走査する。積みの上が先なので、後ろから積む。
                            const first = pending.items.len;
                            for (names) |name| {
                                const read = try self.readIncluded(name.asString().?.bytes, fold_case);
                                try pending.append(self.scratch, .{ .forms = read.data, .origin = read.origin });
                            }
                            std.mem.reverse(Pending, pending.items[first..]);
                        },
                        .@"define-syntax" => {
                            consulted.clearRetainingCapacity();
                            const syntax = try self.syntaxDefinition(rib, try self.itemsOf(form), &consulted);
                            try self.defineOnce(&defined, syntax.name, "define-syntax");
                            for (consulted.items) |id| try depended.append(self.scratch, .{
                                .id = id,
                                .denotation = try syntax_env.resolve(self.ctx, rib, id),
                            });
                            try syntax_env.bindMacro(self.ctx, rib, syntax.name, syntax.macro);
                            try self.checkDepended(rib, depended.items, syntax.name, "define-syntax");
                        },
                        else => break false,
                    },
                    .macro => |m| {
                        try decided.append(self.scratch, .{ .id = pair.car, .denotation = head });
                        form = try rules.transform(self.ctx, &self.work, m, form, rib);
                        // 出力は、本体の形式として、本体を持つ形式の位置でなく、マクロを使った
                        // 形式の位置を引き継ぐ。
                        try self.inheritSite(form, site);
                        continue;
                    },
                    .local, .global, .auxiliary => break false,
                }
                try decided.append(self.scratch, .{ .id = pair.car, .denotation = head });
                break true;
            };
            if (!definition) {
                const defines = forms;
                try items.append(self.scratch, .{ .form = form });
                forms += 1;
                // 残りの形式は、走査しないで、積みの上から順に並べる。まだ載せていないファイルの
                // 形式にも、出入りの印を置く。
                var i = pending.items.len;
                while (i > 0) : (i -= 1) {
                    const rest = pending.items[i - 1];
                    if (rest.origin != null and !rest.entered) try items.append(self.scratch, .{ .enter = rest.origin.? });
                    for (rest.forms) |f| try items.append(self.scratch, .{ .form = f });
                    forms += rest.forms.len;
                    if (rest.origin != null) try items.append(self.scratch, .leave);
                }
                return self.checkBody(.{ .items = items.items, .forms = forms, .defines = defines }, rib, decided.items, form_name);
            }
        }
        return self.checkBody(.{ .items = items.items, .forms = forms, .defines = forms }, rib, decided.items, form_name);
    }

    /// Checks `body`, the result of a scan, as `checkDecided` does, and that it
    /// has an expression after its definitions, and returns it.
    fn checkBody(self: *Expander, body: Body, rib: *SyntacticEnv, decided: []const Decided, comptime form_name: []const u8) Error!Body {
        _ = try self.checkDecided(body, rib, decided);
        if (body.defines == body.forms)
            return self.ctx.raise("bad " ++ form_name ++ ": a body needs an expression after its definitions", .{});
        return body;
    }

    /// Checks that each head the scan of a body decided a form by still means
    /// what it meant then, now that the rib binds all the definitions, and
    /// returns `body`.
    /// Why: 定義が束縛する名前が、その定義や前の定義の先頭の `define` そのものだと、
    /// 定義だと判定した形式が、本体の全体を領域とする束縛のもとでは定義でなくなる。
    /// マクロの適用の先頭も同じである。R7RS 5.4 はこれを誤りとしている。展開がこの判定に
    /// 頼るので、ここで拒否する。
    fn checkDecided(self: *Expander, body: Body, rib: *SyntacticEnv, decided: []const Decided) Error!Body {
        for (decided) |d| {
            if (!syntax_env.sameDenotation(try syntax_env.resolve(self.ctx, rib, d.id), d.denotation)) return self.ctx.raise(
                "bad define: {s} is defined in a body whose definitions it begins",
                .{self.nameOf(d.id)},
            );
        }
        return body;
    }

    /// Checks that `bound`, a name a definition of a body has just bound in
    /// `rib`, does not change what an identifier a transformer of the body was
    /// read by means.
    /// Why: R7RS 5.4 は、定義の意味を決めるのに束縛を知る必要がある識別子を、その定義や
    /// 同じ本体の前の定義が束縛することを誤りとしている。照合器はこれらの意味を適用の
    /// たびに引き直すので、変わったまま適用すると、定義の時点の検査(深さの検査など)が
    /// 見ていない読み方になり、処理系が落ちる。
    /// 束縛を足して意味が変わりうるのは、元のシンボルが同じ識別子だけである。別名は、
    /// 束縛が見つからなければ内側の識別子で引き直すからである。
    fn checkDepended(self: *Expander, rib: *SyntacticEnv, depended: []const Decided, bound: Value, comptime form_name: []const u8) Error!void {
        const symbol = syntax_env.baseSymbol(bound);
        for (depended) |d| {
            if (syntax_env.baseSymbol(d.id) != symbol) continue;
            if (!syntax_env.sameDenotation(try syntax_env.resolve(self.ctx, rib, d.id), d.denotation)) return self.ctx.raise(
                "bad " ++ form_name ++ ": {s} is defined after a syntax definition of this body that depends on its meaning",
                .{self.nameOf(d.id)},
            );
        }
    }

    /// The name a `(define ...)` form at the start of a body defines.
    /// `(define (name parameter ...) body ...)` は、ヘッダの先頭にあるものを名前とする。
    fn definedName(self: *Expander, form: *const value_mod.Pair) Error!Value {
        const rest = form.cdr.asPair() orelse
            return self.ctx.raise("bad define: expected (define name expression)", .{});
        const target = if (rest.car.asPair()) |header| header.car else rest.car;
        if (!syntax_env.isIdentifier(target))
            return self.ctx.raise("bad define: the name must be an identifier", .{});
        return target;
    }

    /// Adds `id` to the names a body has defined, after checking that it is
    /// not one of them already.
    fn defineOnce(self: *Expander, defined: *std.ArrayList(Value), id: Value, comptime form_name: []const u8) Error!void {
        for (defined.items) |earlier| {
            if (syntax_env.boundIdentifierEq(earlier, id)) return self.ctx.raise(
                "bad " ++ form_name ++ ": {s} is already defined earlier in this body",
                .{self.nameOf(id)},
            );
        }
        try defined.append(self.scratch, id);
    }

    /// A syntax definition: the keyword, and the macro it is bound to.
    const SyntaxDefinition = struct { name: Value, macro: *value_mod.Macro };

    /// Checks `(define-syntax keyword transformer)` (R7RS 5.4), and makes the
    /// macro of the transformer in `env`.
    /// `consulted` が null でなければ、変換子の先頭と、`rules.compile` が意味を引いた
    /// 識別子を足す。
    fn syntaxDefinition(self: *Expander, env: ?*SyntacticEnv, items: []const Value, consulted: ?*std.ArrayList(Value)) Error!SyntaxDefinition {
        if (items.len != 3)
            return self.ctx.raise("bad define-syntax: expected (define-syntax keyword transformer)", .{});
        if (!syntax_env.isIdentifier(items[1]))
            return self.ctx.raise("bad define-syntax: the keyword must be an identifier", .{});
        return .{ .name = items[1], .macro = try self.transformer(env, items[2], consulted, "define-syntax") };
    }

    /// The macro of the transformer `form`, made in `env`.
    /// 変換子は `syntax-rules` の形式で、その先頭は `env` で `syntax-rules` を意味しなければ
    /// ならない。同じ綴りを仮引数が束縛していれば、`syntax-rules` ではない。
    fn transformer(self: *Expander, env: ?*SyntacticEnv, form: Value, consulted: ?*std.ArrayList(Value), comptime form_name: []const u8) Error!*value_mod.Macro {
        const spec = form.asPair() orelse
            return self.ctx.raise("bad " ++ form_name ++ ": the transformer must be a syntax-rules form", .{});
        if (try self.specialOf(env, spec.car) != .@"syntax-rules")
            return self.ctx.raise("bad " ++ form_name ++ ": the transformer must be a syntax-rules form", .{});
        if (consulted) |list| try list.append(self.scratch, spec.car);
        return rules.compile(self.ctx, self.scratch, form, env, consulted);
    }

    /// `(let-syntax ((keyword transformer) ...) body ...)` and `letrec-syntax`
    /// (R7RS 4.3.1).
    /// 本体は、キーワードを束縛した新しい環境で展開する。その環境は rib を持たない
    /// (`extendWithoutRib`)。`let-syntax` の変換子は外側の環境で読み、`letrec-syntax` の
    /// 変換子は、束縛を足した環境で読む。後者は、同じ束縛の中のキーワード(自分自身を含む)を
    /// 見える。
    ///
    /// 本体は、`lambda` の本体と同じく、定義のあとに式が続く並びである(R7RS 4.3.1)。本体は
    /// 自分の有効範囲を持ち、定義は本体の局所変数になる。外側の並びに繋ぎ込まない(R6RS の
    /// `let-syntax` とは違う)。最上位の `let-syntax` の定義も、最上位の変数にならない。
    /// 本体は、その内側に rib を足して走査する(`scanBody`)。`define` が1つでもあれば、本体を
    /// 引数の無い手続きの呼び出しにして、そのフレームに局所変数を置く。`define` が無ければ
    /// (`define-syntax` だけなら)、フレームを作らない。足した rib を、外側と同じ深さに戻し、
    /// 本体の中の局所変数の番地を、外側と同じ深さから数える。
    /// Why: 2026-10-22 にユーザーが、本体を自分の有効範囲にする案を選んだ。R7RS 4.3.1 は、
    /// 本体を「0個以上の定義と1個以上の式」とし、キーワードの領域を本体とするだけで、外側への
    /// 繋ぎ込みを書いていない(docs/spec の原文で確かめた)。定義の無い本体にフレームを作ると、
    /// 今までの `let-syntax` の評価のたびに、手続きの確保と呼び出しが増える。
    /// Why: 深さを戻せるのは、走査が rib の深さを読むものを作らないからである。局所変数の束縛
    /// (`bindLocal`)は `define` だけが作り、子の環境は、走査のあとの展開の仕事が作る。
    ///
    /// Why: 変換子が `_` や省略記号の意味を `letrec-syntax` の環境で引くので、環境の束縛を
    /// 先に置いてから変換子を作る。後から束縛が増えると、定義の時点の検査が見ていない読み方で
    /// 適用される。束縛はいったん空のマクロに置き、変換子ができたら中身を入れ替える。
    fn letSyntax(self: *Expander, task: Task, items: []const Value, comptime recursive: bool) Error!void {
        const form_name = if (recursive) "letrec-syntax" else "let-syntax";
        if (items.len < 3)
            return self.ctx.raise("bad " ++ form_name ++ ": expected (" ++ form_name ++ " ((keyword transformer) ...) body ...)", .{});
        const bindings = try self.itemsOfBindings(items[1], form_name);
        const inner = try syntax_env.extendWithoutRib(self.ctx, task.env);
        const placeholders = try self.scratch.alloc(*value_mod.Macro, bindings.len);
        // 変換子を読む環境。`letrec-syntax` では、束縛を足した環境である。
        const read_in = if (recursive) inner else task.env;
        for (bindings, placeholders, 0..) |binding, *placeholder, i| {
            const pair = try self.itemsOfBinding(binding, form_name);
            for (bindings[0..i]) |earlier| {
                if (syntax_env.boundIdentifierEq(earlier.asPair().?.car, pair[0])) return self.ctx.raise(
                    "bad " ++ form_name ++ ": {s} is bound twice",
                    .{self.nameOf(pair[0])},
                );
            }
            if (recursive) {
                placeholder.* = try self.ctx.create(value_mod.Macro, .{ .literals = .empty_list_value, .rules = .empty_list_value, .env = inner });
                try syntax_env.bindMacro(self.ctx, inner, pair[0], placeholder.*);
            }
        }
        for (bindings, placeholders) |binding, placeholder| {
            const pair = try self.itemsOfBinding(binding, form_name);
            const macro = try self.transformer(read_in, pair[1], null, form_name);
            if (recursive) {
                placeholder.* = macro.*;
            } else {
                try syntax_env.bindMacro(self.ctx, inner, pair[0], macro);
            }
        }
        const rib = try syntax_env.extend(self.ctx, inner);
        var slots: u32 = 0;
        const scanned = try self.scanBody(items[2..], rib, &slots, form_name);
        if (slots == 0) {
            rib.rib_depth = inner.rib_depth;
            return self.bodySequence(task.dest, scanned, rib);
        }
        // 本体を、引数の無い手続きにして、すぐに呼ぶ。
        const body_node = try self.newNode();
        try self.bodySequence(body_node, scanned, rib);
        const operator = try self.newNode();
        operator.* = .{ .lambda = try self.ctx.create(value_mod.Lambda, .{ .arity = 0, .rest = false, .frame_size = slots, .body = body_node }) };
        _ = try self.newNodes(0, task.dest, attachOperands);
        task.dest.call.operator = operator;
    }

    /// The bindings of a `let-syntax`, a list of forms.
    fn itemsOfBindings(self: *Expander, form: Value, comptime form_name: []const u8) Error![]const Value {
        var items: std.ArrayList(Value) = .empty;
        var rest = form;
        while (rest.asPair()) |p| : (rest = p.cdr) try items.append(self.scratch, p.car);
        if (rest.kind() != .empty_list)
            return self.ctx.raise("bad " ++ form_name ++ ": the bindings must be a list", .{});
        return items.items;
    }

    /// The keyword and the transformer of one binding of a `let-syntax`.
    fn itemsOfBinding(self: *Expander, binding: Value, comptime form_name: []const u8) Error![2]Value {
        const bad = "bad " ++ form_name ++ ": a binding must be (keyword transformer)";
        const first = binding.asPair() orelse return self.ctx.raise(bad, .{});
        const second = first.cdr.asPair() orelse return self.ctx.raise(bad, .{});
        if (second.cdr.kind() != .empty_list) return self.ctx.raise(bad, .{});
        if (!syntax_env.isIdentifier(first.car))
            return self.ctx.raise("bad " ++ form_name ++ ": the keyword must be an identifier", .{});
        return .{ first.car, second.car };
    }

    /// `(syntax-error message datum ...)` (R7RS 4.3.3): an error found while
    /// expanding, which a handler cannot catch because nothing has run yet.
    /// 引数は評価せず、データとして報告する。マクロのテンプレートが導入した識別子は、
    /// 元のシンボルで書く。
    fn syntaxError(self: *Expander, items: []const Value) Error!void {
        const message = if (items.len >= 2) items[1].asString() else null;
        if (message == null)
            return self.ctx.raise("bad syntax-error: expected (syntax-error \"message\" datum ...)", .{});
        var irritants: Value = .empty_list_value;
        var i = items.len;
        while (i > 2) {
            i -= 1;
            irritants = self.ctx.heap.cons(try self.stripAliases(items[i]), irritants) catch |e| return self.ctx.heapFailure(e);
        }
        self.ctx.raised = try self.ctx.makeCondition(.@"error", "{s}", .{message.?.bytes}, irritants);
        return error.Raised;
    }

    /// Checks, in a library body, that the top level did not import `name`.
    /// Why: R7RS 5.2 は、プログラムとライブラリ宣言の中で、インポートした束縛を `define` や
    /// `define-syntax` で再定義することを誤りとしている。REPL は許す(`Mode`)。
    fn checkNotImported(self: *Expander, name: @import("../symbol.zig").SymbolId, comptime form_name: []const u8) Error!void {
        if (self.top.lookup(name)) |b| {
            if (b.imported) return self.ctx.raise(
                "bad " ++ form_name ++ ": {s} is an imported binding and cannot be redefined",
                .{self.ctx.heap.symbols.nameOf(name)},
            );
        }
    }

    /// `(define-syntax keyword transformer)` at the top level (R7RS 5.4).
    /// REPL の最上位の束縛の表で、名前をマクロに束縛する。それより前に展開したコードの
    /// 参照は変わらない(同節)。名前が別名なら、`define` と同じく元のシンボルの名前を
    /// 束縛する。本体の先頭のものは `scanBody` が扱い、ここには来ない。
    fn defineSyntax(self: *Expander, task: Task, items: []const Value) Error!void {
        switch (task.pos) {
            .expression => return self.ctx.raise("bad define-syntax: a definition is only allowed at the top level or at the start of a body", .{}),
            .body => unreachable,
            .top => {},
        }
        const syntax = try self.syntaxDefinition(task.env, items, null);
        const name = syntax_env.baseSymbol(syntax.name);
        if (self.mode == .library) try self.checkNotImported(name, "define-syntax");
        try self.top.defineSyntax(self.ctx.resident(), name, syntax.macro);
        try self.constant(task, .unspecified_value);
    }

    /// A procedure call (R7RS 4.1.3): the operator, then the operands from left
    /// to right.
    /// Why: R7RS は評価順を規定していない。読み手が期待するのは左から右である。
    fn call(self: *Expander, task: Task, items: []const Value) Error!void {
        const operands = try self.newNodes(items.len - 1, task.dest, attachOperands);
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
        const sink: @import("../reader.zig").Sink = .{ .heap = &self.ctx.heap };
        return (try r.next(self.arena.allocator(), sink)).?;
    }

    fn expandText(self: *Fixture, src: []const u8, limits: Limits) ![]const u8 {
        const form = try self.read(src);
        const node = try expandWith(&self.ctx, self.arena.allocator(), form, limits);
        var out: std.Io.Writer.Allocating = .init(self.arena.allocator());
        try core.write(&out.writer, self.arena.allocator(), &self.ctx.heap.symbols, node);
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
    // 本体の先頭の `(begin)` は、R7RS では合法な空の定義の並びである。本体の走査が
    // 展開するので、あとに式があれば本体は成り立つ。式が無ければ、本体が式を要る。
    try f.expectFails("(lambda () (begin))", "bad lambda: a body needs an expression after its definitions");
    try f.expectExpands("(lambda () (begin) 1)", "(lambda 0 0 (const 1))");
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
}

test "the scan of a body splices a begin at the start of the body into the definitions" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.expectExpands("(lambda () (begin (define x 1)) x)", "(lambda 0 1 (seq (define-local x 0 0 (const 1)) (local x 0 0)))");
    // 入れ子の `begin` も、定義のあとの `begin` も、定義の並びである。
    try f.expectExpands(
        "(lambda () (begin (define a 1) (begin (define b 2))) (define c 3) (begin (define d 4)) (list a b c d))",
        "(lambda 0 4 (seq (define-local a 0 0 (const 1)) (define-local b 0 1 (const 2)) (define-local c 0 2 (const 3)) (define-local d 0 3 (const 4)) (call (global list) (local a 0 0) (local b 0 1) (local c 0 2) (local d 0 3))))",
    );
    // `begin` の中の式は、そこで定義の並びを終える。それ以後の式も同じ並びの式である。
    try f.expectExpands("(lambda () (begin (define a 1) a) 2)", "(lambda 0 1 (seq (define-local a 0 0 (const 1)) (local a 0 0) (const 2)))");
    try f.expectExpands("(lambda () (begin 1 2) 3)", "(lambda 0 0 (seq (const 1) (const 2) (const 3)))");
    // 定義が1つも残らなければ、式を要る。
    try f.expectFails("(lambda () (begin (define x 1)))", "bad lambda: a body needs an expression after its definitions");
    // 式のあとの定義は、`begin` の中でも拒否される。
    try f.expectFails("(lambda () (begin (+ 1 2) (define a 1)) a)", "bad define: a definition is only allowed at the top level or at the start of a body");
    try f.expectFails("(lambda () (+ 1 2) (begin (define a 1)) a)", "bad define: a definition is only allowed at the top level or at the start of a body");
    // 同じ名前の定義は、`begin` の境を越えても重複である。
    try f.expectFails("(lambda () (define x 1) (begin (define x 2)) x)", "bad define: x is already defined earlier in this body");
    // `begin` が、本体の定義で別の意味になれば、定義の判定が変わるので拒否する(R7RS 5.4)。
    try f.expectFails("(lambda () (begin (define x 1)) (define begin 3) x)", "bad define: begin is defined in a body whose definitions it begins");
    // 内側の `begin` が仮引数なら、`begin` ではなく呼び出しである。
    try f.expectFails("(lambda (begin) (begin (define x 1)) x)", "bad define: a definition is only allowed at the top level or at the start of a body");
    // `begin` の中の `define-syntax` は、あとの形式の判定から見える。
    try f.expectExpands("(lambda () (begin (define-syntax m (syntax-rules () ((_) 1)))) (m))", "(lambda 0 0 (const 1))");
    // 形が悪い `begin` は、リストでないものを拒否する。
    try f.expectFails("(lambda () (begin . 1) 2)", "bad syntax: a form must be a proper list");
}

test "a macro that expands to a begin of definitions defines in a body" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.expectExpands("(define-syntax two (syntax-rules () ((_ a b) (begin (define a 1) (define b 2)))))", "(const #<unspecified>)");
    try f.expectExpands(
        "(lambda () (two p q) (list p q))",
        "(lambda 0 2 (seq (define-local p 0 0 (const 1)) (define-local q 0 1 (const 2)) (call (global list) (local p 0 0) (local q 0 1))))",
    );
    // 入れ子のマクロの適用も、定義の並びである。
    try f.expectExpands("(define-syntax three (syntax-rules () ((_ a b c) (begin (two a b) (define c 3)))))", "(const #<unspecified>)");
    try f.expectExpands(
        "(lambda () (three p q r) (list p q r))",
        "(lambda 0 3 (seq (define-local p 0 0 (const 1)) (define-local q 0 1 (const 2)) (define-local r 0 2 (const 3)) (call (global list) (local p 0 0) (local q 0 1) (local r 0 2))))",
    );
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
    const plus: Value = .fromSymbol(try f.ctx.intern("+"));
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

/// Roots for a test: what the context holds, and the nodes the test holds, as the
/// control register of a machine would.
const NodeRoots = struct {
    ctx: *const Context,
    nodes: []const *const Node = &.{},

    pub fn mark(self: NodeRoots, marker: *heap_mod.Marker) void {
        for (self.nodes) |n| marker.object(Node, n);
        self.ctx.mark(marker);
    }
};

test "the constants of the code live as long as the code, and go with it" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const a = f.arena.allocator();
    // 名前 `x` を解決すると、REPL の表に未束縛のセルができる。指すコードが無くなれば、
    // 表は弱く持つので、セルは外れて回収される(ADR-0040 の決定6)。
    _ = try expand(&f.ctx, a, try f.read("x"));
    f.ctx.collectIdle();
    try std.testing.expectEqual(0, f.ctx.heap.count);
    // クォートしたデータは、節点から辿られる。対象はデータそのもので、周りの `quote`
    // 形式のペアではない。
    const node = try expand(&f.ctx, a, try f.read("(quote (1 2))"));
    f.ctx.heap.collect(NodeRoots{ .ctx = &f.ctx, .nodes = &.{node} });
    // 節点と、データの2つのペア。
    try std.testing.expectEqual(3, f.ctx.heap.count);
    try std.testing.expectEqual(2, node.constant.asPair().?.cdr.asPair().?.car.asFixnum().?);
    // コードに誰も届かなくなれば、節点もデータも回収される(ADR-0031 の 2026-10-10 の追記の、
    // `quote` したデータがセッションの終わりまで残る帰結が外れる)。
    f.ctx.collectIdle();
    try std.testing.expectEqual(0, f.ctx.heap.count);
    // シンボルの定数も、節点から名前に印が付く。
    const named = try expand(&f.ctx, a, try f.read("(quote zzz-constant)"));
    f.ctx.heap.collect(NodeRoots{ .ctx = &f.ctx, .nodes = &.{named} });
    var buf: [24]u8 = undefined;
    for (0..32) |i| _ = try f.ctx.intern(std.fmt.bufPrint(&buf, "other-{d}", .{i}) catch unreachable);
    try std.testing.expectEqualStrings("zzz-constant", f.ctx.heap.symbols.nameOf(named.constant.asSymbol().?));
}

test "the name a local variable node holds stays the name after a collection that frees every other symbol" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const a = f.arena.allocator();
    // 仮引数の名前は、読んだデータ以外では、節点にしか無い。節点を持つのはテストである。
    const read_node = try expand(&f.ctx, a, try f.read("(lambda (zr) zr)"));
    const set_node = try expand(&f.ctx, a, try f.read("(lambda (zs) (set! zs 1))"));
    f.ctx.heap.collect(NodeRoots{ .ctx = &f.ctx, .nodes = &.{ read_node, set_node } });
    // 回収した ID を別の名前が使う。
    var buf: [16]u8 = undefined;
    for (0..32) |i| _ = try f.ctx.intern(std.fmt.bufPrint(&buf, "other-{d}", .{i}) catch unreachable);
    var out: std.Io.Writer.Allocating = .init(a);
    try core.write(&out.writer, a, &f.ctx.heap.symbols, read_node);
    try std.testing.expectEqualStrings("(lambda 1 1 (local zr 0 0))", out.written());
    out.clearRetainingCapacity();
    try core.write(&out.writer, a, &f.ctx.heap.symbols, set_node);
    try std.testing.expectEqualStrings("(lambda 1 1 (set-local zs 0 0 (const 1)))", out.written());
}

test "a form whose expansion fails keeps none of the nodes and constants it made" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const a = f.arena.allocator();
    _ = try expand(&f.ctx, a, try f.read("(define-syntax m (syntax-rules () ((_) (list '(tmp) (if)))))"));
    // 1回目の展開は、`list` のセルを作り、表が持ち続ける。数えるのはその後からである。
    try std.testing.expectError(error.Raised, expand(&f.ctx, a, try f.read("(m)")));
    f.ctx.clearDiagnostic();
    f.ctx.collectIdle();
    const before = f.ctx.heap.count;
    // 被演算子は左から展開するので、剥離した '(tmp) を定数にしてから (if) で失敗する。
    // 失敗した形式の節点と定数は、どこからも指されないので、次の GC で回収される
    // (roadmap の「マクロの展開の有界化の残り」の (2))。
    for (0..3) |_| {
        try std.testing.expectError(error.Raised, expand(&f.ctx, a, try f.read("(m)")));
        try std.testing.expect(f.ctx.heap.countOf(Node) > 0);
        f.ctx.clearDiagnostic();
        f.ctx.collectIdle();
        try std.testing.expectEqual(0, f.ctx.heap.countOf(Node));
        try std.testing.expectEqual(before, f.ctx.heap.count);
    }
}

test "a parameterize form whose expansion reaches the limit at any point keeps nothing it took" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const a = f.arena.allocator();
    const src = "(parameterize ((p 1) (q 2) (r 3)) 4)";
    // 1回目の展開が作り、表が持ち続けるもの(大域変数のセル)を、先に作らせておく。
    _ = try expand(&f.ctx, a, try f.read(src));
    f.ctx.collectIdle();
    const before = f.ctx.heap.accounted;
    const limit = f.ctx.heap.options.limit;
    defer f.ctx.heap.options.limit = limit;
    // 上限を、今の計上から8バイトずつ上げ、展開の途中のどの確保でも上限に当たるようにする。
    // 当たった展開が確保したものは、ごみとして回収されるか、その場で返される。返し忘れは、
    // テスト用アロケータがリークとして報告する。
    var extra: usize = 0;
    while (extra < 1024) : (extra += 8) {
        const form = try f.read(src);
        f.ctx.heap.options.limit = f.ctx.heap.held() + extra;
        _ = expand(&f.ctx, a, form) catch {};
        f.ctx.heap.options.limit = limit;
        f.ctx.clearDiagnostic();
        f.ctx.collectIdle();
        try std.testing.expectEqual(before, f.ctx.heap.accounted);
    }
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

test "a macro's template binds its own tmp, apart from the tmp of the use" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.expectExpands("(define-syntax swap! (syntax-rules () ((_ a b) ((lambda (tmp) (set! a b) (set! b tmp)) a))))", "(const #<unspecified>)");
    // テンプレートの tmp(内側の lambda の仮引数)と、利用側の tmp(外側の仮引数)は別の変数である。
    try f.expectExpands(
        "(lambda (tmp x) (swap! tmp x))",
        "(lambda 2 2 (call (lambda 1 1 (seq (set-local tmp 1 0 (local x 1 1)) (set-local x 1 1 (local tmp 0 0)))) (local tmp 0 0)))",
    );
}

test "the body of a let-syntax counts frames from the lambda around it, not from the syntactic scope" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    // let-syntax の環境は rib を持たないので、本体の中の外側の変数は、深さ0である。
    try f.expectExpands("(lambda (x) (let-syntax ((m (syntax-rules () ((_) x)))) (m)))", "(lambda 1 1 (local x 0 0))");
    try f.expectExpands("(lambda (x) (let-syntax ((m (syntax-rules () ((_) x)))) (lambda (y) (m))))", "(lambda 1 1 (lambda 1 1 (local x 1 0)))");
    try f.expectExpands("(lambda (x) (letrec-syntax ((m (syntax-rules () ((_) x)))) (m)))", "(lambda 1 1 (local x 0 0))");
    // 入れ子の let-syntax と letrec-syntax も、深さを足さない。
    try f.expectExpands(
        "(lambda (x) (let-syntax ((a (syntax-rules () ((_) x)))) (letrec-syntax ((b (syntax-rules () ((_) (a))))) (b))))",
        "(lambda 1 1 (local x 0 0))",
    );
    // 本体は式の並びで、最後の式が値になる。
    try f.expectExpands("(let-syntax () 1 2)", "(seq (const 1) (const 2))");
    // define-syntax だけの本体も、フレームを作らない。
    try f.expectExpands("(lambda (x) (let-syntax () (define-syntax m (syntax-rules () ((_) x))) (m)))", "(lambda 1 1 (local x 0 0))");
}

test "a let-syntax whose body defines a variable runs the body as a call of a procedure without arguments" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    // 本体の定義は新しいフレームの局所変数で、外側の変数は1つ深くなる。
    try f.expectExpands(
        "(lambda (x) (let-syntax () (define y 1) (+ x y)))",
        "(lambda 1 1 (call (lambda 0 1 (seq (define-local y 0 0 (const 1)) (call (global +) (local x 1 0) (local y 0 0))))))",
    );
    try f.expectExpands("(letrec-syntax () (define y 2) y)", "(call (lambda 0 1 (seq (define-local y 0 0 (const 2)) (local y 0 0))))");
}

test "a let-syntax keyword hides the one around it only inside the body" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.expectExpands("(define-syntax m (syntax-rules () ((_) 1)))", "(const #<unspecified>)");
    try f.expectExpands("(let-syntax ((m (syntax-rules () ((_) 2)))) (m))", "(const 2)");
    try f.expectExpands("(m)", "(const 1)");
    // let-syntax の変換子は外側の環境で読み、letrec-syntax の変換子は自分たちの環境で読む。
    try f.expectExpands("(let-syntax ((m (syntax-rules () ((_) (m))))) (m))", "(const 1)");
    try f.expectExpands("(letrec-syntax ((m (syntax-rules () ((_ 0) 3) ((_ n) (m 0))))) (m 5))", "(const 3)");
}

test "the scan of a body expands a macro use once, and uses what it expanded to" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.expectExpands("(define-syntax def (syntax-rules () ((_ n v) (define n v))))", "(const #<unspecified>)");
    const before = f.ctx.next_mark;
    try f.expectExpands("(lambda () (def a 1) (def b a) b)", "(lambda 0 2 (seq (define-local a 0 0 (const 1)) (define-local b 0 1 (local a 0 0)) (local b 0 1)))");
    try std.testing.expectEqual(before + 2, f.ctx.next_mark);
    // 定義の並びを終える最初の式も、適用を1回だけ展開する。
    try f.expectExpands("(define-syntax one (syntax-rules () ((_) 1)))", "(const #<unspecified>)");
    const again = f.ctx.next_mark;
    try f.expectExpands("(lambda () (one))", "(lambda 0 0 (const 1))");
    try std.testing.expectEqual(again + 1, f.ctx.next_mark);
}

test "a define-syntax that a failed expansion made is undone" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.expectFails("(begin (define-syntax m (syntax-rules () ((_) 1))) (if))", "bad if: expected (if test consequent) or (if test consequent alternative)");
    try f.expectExpands("(m)", "(call (global m))");
    // 成功した展開のものは残る。
    try f.expectExpands("(define-syntax m (syntax-rules () ((_) 1)))", "(const #<unspecified>)");
    try f.expectFails("(begin (define m 2) (if))", "bad if: expected (if test consequent) or (if test consequent alternative)");
    try f.expectExpands("(m)", "(const 1)");
}

test "a name a macro defines at the top level is the name it was written as" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.expectExpands("(define-syntax def-counter (syntax-rules () ((_) (begin (define counter 0) (set! counter 1)))))", "(const #<unspecified>)");
    // テンプレートの counter は別名だが、最上位の定義は元の名前を束縛し、同じ展開の中の参照も
    // 同じセルに解決される。
    const node = try expand(&f.ctx, f.arena.allocator(), try f.read("(def-counter)"));
    const defined = node.sequence[0].global_define.cell;
    try std.testing.expectEqual(defined, node.sequence[1].global_set.cell);
    try std.testing.expectEqual(defined, (try expand(&f.ctx, f.arena.allocator(), try f.read("counter"))).global_ref);
}

/// The alias of `name` that a macro defined at the top level would make.
fn testAlias(f: *Fixture, name: []const u8) !Value {
    const inner: Value = .fromSymbol(try f.ctx.intern(name));
    return .fromAlias(try f.ctx.heap.create(value_mod.Alias, .{ .inner = inner, .env = null, .mark = 0 }));
}

/// The node of `(quote datum)`, the form built by hand.
fn quoted(f: *Fixture, datum: Value) !*const Node {
    const quote: Value = .fromSymbol(try f.ctx.intern("quote"));
    const form = try f.ctx.heap.cons(quote, try f.ctx.heap.cons(datum, .empty_list_value));
    return expand(&f.ctx, f.arena.allocator(), form);
}

test "quote gives an alias back as its symbol, and keeps the shared structure shared" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const h = &f.ctx.heap;
    // (shared shared tmp) で、shared は同じペア (1 tmp) を2回指す。
    const shared = try h.cons(.fromFixnum(1), try h.cons(try testAlias(&f, "tmp"), .empty_list_value));
    const datum = try h.cons(shared, try h.cons(shared, try h.cons(try testAlias(&f, "tmp"), .empty_list_value)));
    const c = (try quoted(&f, datum)).constant;
    var out: std.Io.Writer.Allocating = .init(f.arena.allocator());
    try @import("../printer.zig").write(&out.writer, f.arena.allocator(), &f.ctx.heap.symbols, c);
    try std.testing.expectEqualStrings("((1 tmp) (1 tmp) tmp)", out.written());
    const first = c.asPair().?.car.asPair().?;
    const second = c.asPair().?.cdr.asPair().?.car.asPair().?;
    try std.testing.expectEqual(first, second);
    // 写しであり、元のデータは変わらない。
    try std.testing.expect(first != shared.asPair().?);
    try std.testing.expectEqual(value_mod.Kind.alias, shared.asPair().?.cdr.asPair().?.car.kind());
    try std.testing.expectEqual(tmpSymbol(&f), first.cdr.asPair().?.car.asSymbol().?);
}

fn tmpSymbol(f: *Fixture) @import("../symbol.zig").SymbolId {
    return f.ctx.heap.symbols.lookup("tmp").?;
}

test "quote strips the aliases of a cycle, and the copy is the same cycle" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const h = &f.ctx.heap;
    // #0=(tmp . #0#) と、それを要素に持つベクタ #(#0# #0#)。
    const cycle = try h.cons(try testAlias(&f, "tmp"), .empty_list_value);
    cycle.asPair().?.cdr = cycle;
    const vector: Value = .fromVector(try h.createVector(&.{ cycle, cycle }));
    const c = (try quoted(&f, vector)).constant;
    const items = c.asVector().?.items;
    try std.testing.expectEqual(items[0].asPair().?, items[1].asPair().?);
    const p = items[0].asPair().?;
    try std.testing.expectEqual(p, p.cdr.asPair().?);
    try std.testing.expectEqual(tmpSymbol(&f), p.car.asSymbol().?);
    try std.testing.expect(p != cycle.asPair().?);
}

test "quote of a cycle without an alias gives the cycle itself" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const cycle = try f.ctx.heap.cons(.fromFixnum(1), .empty_list_value);
    cycle.asPair().?.cdr = cycle;
    try std.testing.expectEqual(cycle.asPair().?, (try quoted(&f, cycle)).constant.asPair().?);
}

test "a self-evaluating vector that holds an alias is stripped too" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const vector: Value = .fromVector(try f.ctx.heap.createVector(&.{ try testAlias(&f, "tmp"), .fromFixnum(2) }));
    const node = try expand(&f.ctx, f.arena.allocator(), vector);
    try std.testing.expectEqual(tmpSymbol(&f), node.constant.asVector().?.items[0].asSymbol().?);
}
