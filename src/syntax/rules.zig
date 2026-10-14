//! `syntax-rules`: checking a transformer where it is defined, and transcribing
//! a use of the macro with it (R7RS 4.3.2, docs/design/frontend.md).
//!
//! 照合は、パターン変数ごとの深さと値の木(`Match`)を作る。テンプレートの展開は、
//! その木を深さに沿ってたどり、パターン変数でない識別子を、適用ごとに新しい印を
//! 持つ別名にする(`Alias`)。別名は、マクロを定義した環境で解決されるので、テンプレート
//! が導入した識別子は利用側の束縛に捕まらず、定義側の意味を保つ。
//!
//! パターンの識別子のうち、`_` と省略記号 `...` は、綴りでなく束縛で見分ける
//! (`free-identifier=?` に相当する比較)。マクロを定義した環境でのその識別子の意味が、
//! 最上位でのその名前の意味と同じなら、それである。仮引数などが同じ綴りを束縛して
//! いれば、パターン変数になる。
//!
//! スライス 2k が扱うのは、パターン変数、`_`、リテラル、リストの末尾に置く深さ1の
//! 省略記号である。残りの形(入れ子の省略記号、省略記号の後の固定パターン、非真正
//! リスト、ベクタ、定数パターン、テンプレートの省略記号のエスケープ、利用者指定の
//! 省略記号)は 2l が入れる。それまでは、定義の時点で「まだ扱えない」と報告し、黙って
//! 別の意味に読まない。
//!
//! 照合と展開は入力とテンプレートの深さに比例して進むので、Zig の再帰で書かず、
//! 作業スタックを使う(docs/design/runtime.md)。展開の途中では GC が走らない
//! (ADR-0031)ので、作業スタックが持つ値はルートにしなくてよい。

const std = @import("std");
const value_mod = @import("../value.zig");
const Value = value_mod.Value;
const Macro = value_mod.Macro;
const context = @import("../context.zig");
const Context = context.Context;
const syntax_env = @import("env.zig");
const SyntacticEnv = syntax_env.SyntacticEnv;
const properLength = @import("../prim/pair.zig").properLength;
const isEqual = @import("../prim/equiv.zig").isEqual;

pub const Error = context.Error;

/// Checks `spec`, a `(syntax-rules (literal ...) rule ...)` form whose keyword
/// the caller has resolved, and makes the macro it describes, defined in `env`.
/// 誤りは定義の時点で報告する。マクロが使われるまで待つと、使われないマクロの誤りが
/// 見つからない。
///
/// `consulted` が null でなければ、読み方を決めるのに `env` での意味を引いた識別子
/// (パターンの `_` と、パターンとテンプレートの省略記号)を、重複なしに足す。照合器は
/// 適用のたびにこれらの意味を `env` で引き直すので、`env` が後から束縛を足す rib なら、
/// 呼び出し側は、これらの意味が変わらないことを確かめなければならない。変わると、
/// ここでの検査が見ていない読み方で適用される(src/syntax/expand.zig の `scanBody`)。
pub fn compile(ctx: *Context, scratch: std.mem.Allocator, spec: Value, env: ?*SyntacticEnv, consulted: ?*std.ArrayList(Value)) Error!*Macro {
    const shape = "bad syntax-rules: expected (syntax-rules (literal ...) rule ...)";
    var after_keyword = spec.asPair().?.cdr;
    // 最初の引数が識別子なら、それが省略記号である(R7RS 4.3.2)。
    var ellipsis: ?Value = null;
    if (after_keyword.asPair()) |p| {
        if (syntax_env.isIdentifier(p.car)) {
            ellipsis = p.car;
            after_keyword = p.cdr;
        }
    }
    const literals_pair = after_keyword.asPair() orelse return ctx.raise(shape, .{});
    const literals = literals_pair.car;
    var rest = literals;
    while (rest.asPair()) |p| : (rest = p.cdr) {
        if (!syntax_env.isIdentifier(p.car)) return ctx.raise("bad syntax-rules: a literal must be an identifier", .{});
    }
    if (rest.kind() != .empty_list) return ctx.raise(shape, .{});
    const rules = literals_pair.cdr;
    const s: Spec = .{ .ctx = ctx, .scratch = scratch, .literals = literals, .env = env, .consulted = consulted, .ellipsis = ellipsis };
    var r = rules;
    while (r.asPair()) |p| : (r = p.cdr) {
        const rule = try s.ruleOf(p.car);
        const vars = try s.patternVars(rule.pattern);
        _ = try s.transcribe(rule.template, vars, try s.dryMatches(vars), null, 0, true);
    }
    if (r.kind() != .empty_list) return ctx.raise(shape, .{});
    return ctx.create(Macro, .{ .literals = literals, .rules = rules, .env = env, .ellipsis = ellipsis });
}

/// Transcribes `form`, a use of `macro` in `use_env`, by the first rule whose
/// pattern it matches.
/// 展開器が変換子を呼ぶのは、ここ1か所である。手続き的マクロに広げるときは、ここで
/// 変換子の種類に応じて分ける(docs/design/frontend.md の変換子の実行)。
pub fn transform(ctx: *Context, scratch: std.mem.Allocator, macro: *const Macro, form: Value, use_env: ?*const SyntacticEnv) Error!Value {
    switch (macro.kind) {
        .syntax_rules => {},
    }
    const s: Spec = .{ .ctx = ctx, .scratch = scratch, .literals = macro.literals, .env = macro.env, .ellipsis = macro.ellipsis };
    var r = macro.rules;
    while (r.asPair()) |p| : (r = p.cdr) {
        const rule = try s.ruleOf(p.car);
        const vars = try s.patternVars(rule.pattern);
        const matches = try scratch.alloc(Match, vars.len);
        // 規則のパターンの先頭は照合に関与しない(R7RS 4.3.2)。利用側の先頭は、別の名前
        // で書かれていても、マクロのキーワードである。
        if (try s.match(rule.pattern, form.asPair().?.cdr, vars, matches, use_env)) {
            const mark = try ctx.newMark();
            return s.transcribe(rule.template, vars, matches, macro.env, mark, false);
        }
    }
    return ctx.raise("bad syntax: no rule of {s} matches the form", .{
        ctx.symbols.nameOf(syntax_env.baseSymbol(form.asPair().?.car)),
    });
}

/// A pattern variable, and how many ellipses follow the subpatterns it is in.
const Var = struct { id: Value, depth: u32 };

/// What a pattern variable matched: one form, or at a depth of one or more,
/// the matches of the forms an ellipsis repeated over, in order.
const Match = union(enum) {
    one: Value,
    many: []Match,
};

/// What an identifier in a pattern is (R7RS 4.3.2).
const Role = enum { literal, underscore, ellipsis, variable };

/// A rule: its pattern after the keyword, and its template.
const Rule = struct { pattern: Value, template: Value };

/// The elements of a list pattern or template, and what follows its last pair.
const Shape = struct {
    elems: []const Elem,
    /// The empty list for a proper list.
    tail: Value,

    /// An element, and how many ellipses follow it.
    const Elem = struct { form: Value, ellipses: u32 };

    /// The index of the element a pattern's ellipsis follows.
    fn repeated(self: Shape) ?usize {
        for (self.elems, 0..) |e, i| {
            if (e.ellipses > 0) return i;
        }
        return null;
    }
};

const escape_shape = "bad syntax-rules: an ellipsis escape must be (... template)";

/// How `Spec.shapeFrom` reads the ellipses among the elements.
const ShapeMode = enum {
    /// A pattern: an ellipsis follows one element, and a level has one.
    pattern,
    /// A template: any number of ellipses follow an element.
    template,
    /// A template inside `(... template)`, where an ellipsis is an identifier.
    literal,
};

/// One pass of an ellipsis in a template: the variables it repeats over, and
/// what each matched in this pass.
const Pass = struct {
    parent: ?*const Pass,
    vars: []const usize,
    matched: []const Match,
};

/// What the identifiers of a transformer are read against: its literals, and
/// the environment it was defined in.
const Spec = struct {
    ctx: *Context,
    scratch: std.mem.Allocator,
    literals: Value,
    env: ?*SyntacticEnv,
    /// Where to note the identifiers whose meaning in `env` was looked up, or
    /// null (`compile`).
    consulted: ?*std.ArrayList(Value) = null,
    /// The identifier the transformer names as the ellipsis, or null for `...`.
    ellipsis: ?Value = null,

    /// The parts of `rule`, after checking its shape.
    /// R7RS 4.3.2 は、規則のパターンを、識別子で始まるリストとしている。
    fn ruleOf(self: Spec, rule: Value) Error!Rule {
        const bad = "bad syntax-rules: a rule must be (pattern template)";
        const first = rule.asPair() orelse return self.ctx.raise(bad, .{});
        const second = first.cdr.asPair() orelse return self.ctx.raise(bad, .{});
        if (second.cdr.kind() != .empty_list) return self.ctx.raise(bad, .{});
        const pattern = first.car.asPair() orelse
            return self.ctx.raise("bad syntax-rules: a pattern must be a list that starts with an identifier", .{});
        if (!syntax_env.isIdentifier(pattern.car))
            return self.ctx.raise("bad syntax-rules: a pattern must be a list that starts with an identifier", .{});
        return .{ .pattern = first.car, .template = second.car };
    }

    /// What the identifier `id` of a pattern or a template is.
    /// リテラルの一覧にあることが先で、`_` と省略記号でも、一覧にあればリテラルになる
    /// (R7RS 4.3.2)。一覧との比較は、同じ定義の中の識別子どうしなので `bound-identifier=?`
    /// である。
    fn role(self: Spec, id: Value) Error!Role {
        var rest = self.literals;
        while (rest.asPair()) |p| : (rest = p.cdr) {
            if (syntax_env.boundIdentifierEq(p.car, id)) return .literal;
        }
        if (try self.means(id, "_")) return .underscore;
        if (try self.isEllipsis(id)) return .ellipsis;
        return .variable;
    }

    /// Whether the identifier `id` of a pattern or a template is the ellipsis.
    /// テンプレートで要るのは省略記号かどうかだけなので、`role` と違って `_` の意味を
    /// 引かない。テンプレートの `_` は、どちらにしても別名になる。
    fn isEllipsis(self: Spec, id: Value) Error!bool {
        var rest = self.literals;
        while (rest.asPair()) |p| : (rest = p.cdr) {
            if (syntax_env.boundIdentifierEq(p.car, id)) return false;
        }
        // 指定した省略記号は、同じ定義の中の識別子どうしなので `bound-identifier=?` で比べる。
        // そのとき `...` は、ふつうの識別子である。
        if (self.ellipsis) |custom| return syntax_env.boundIdentifierEq(custom, id);
        return self.means(id, "...");
    }

    /// Whether `id` means, where the transformer is defined, what `name` means
    /// at the top level.
    /// 綴りを先に比べる。比べずに解決すると、最上位で定義したマクロのパターン変数の
    /// それぞれに、REPL の未束縛のセルを作ることになる。綴りが同じなら、意味を引いた
    /// 識別子として `consulted` に足す。
    fn means(self: Spec, id: Value, comptime name: []const u8) Error!bool {
        const symbol = self.ctx.symbols.index.get(name) orelse return false;
        if (syntax_env.baseSymbol(id) != symbol) return false;
        if (self.consulted) |list| {
            for (list.items) |seen| {
                if (syntax_env.boundIdentifierEq(seen, id)) break;
            } else try list.append(self.scratch, id);
        }
        return syntax_env.sameDenotation(
            try syntax_env.resolve(self.ctx, self.env, id),
            try syntax_env.resolve(self.ctx, null, .fromSymbol(symbol)),
        );
    }

    /// Whether `form` is the ellipsis.
    fn isEllipsisForm(self: Spec, form: Value) Error!bool {
        return syntax_env.isIdentifier(form) and try self.isEllipsis(form);
    }

    /// The elements of the list `form`, each with the ellipses that follow it.
    fn shapeOf(self: Spec, form: Value, mode: ShapeMode) Error!Shape {
        var items: std.ArrayList(Value) = .empty;
        var rest = form;
        while (rest.asPair()) |p| : (rest = p.cdr) try items.append(self.scratch, p.car);
        return self.shapeFrom(items.items, rest, mode);
    }

    /// The elements of the vector `form`, each with the ellipses that follow it.
    fn shapeOfVector(self: Spec, form: Value, mode: ShapeMode) Error!Shape {
        return self.shapeFrom(form.asVector().?.items, .empty_list_value, mode);
    }

    /// `items`, the elements of a list or a vector, each with the ellipses that
    /// follow it, and `tail`, what follows the last pair of the list.
    /// 省略記号は、直前の要素に付く。パターンの1つの階層には、省略記号は1つしか置けず、
    /// 続けて並べることもできない(R7RS 4.3.2)。テンプレートは、続けて並べられる。
    fn shapeFrom(self: Spec, items: []const Value, tail: Value, mode: ShapeMode) Error!Shape {
        var elems: std.ArrayList(Shape.Elem) = .empty;
        var repeated = false;
        var i: usize = 0;
        while (i < items.len) {
            const form = items[i];
            i += 1;
            var count: u32 = 0;
            if (mode != .literal) {
                while (i < items.len and try self.isEllipsisForm(items[i])) : (i += 1) count += 1;
            }
            if (mode == .pattern and count > 0) {
                if (count > 1 or repeated)
                    return self.ctx.raise("bad syntax-rules: a list pattern can have only one ellipsis", .{});
                repeated = true;
            }
            try elems.append(self.scratch, .{ .form = form, .ellipses = count });
        }
        return .{ .elems = elems.items, .tail = tail };
    }

    /// The pattern variables of `pattern`, after checking that it uses only the
    /// forms this slice supports and binds no variable twice.
    /// `pattern` は規則のパターンの全体で、先頭のキーワードは見ない。
    fn patternVars(self: Spec, pattern: Value) Error![]Var {
        const Item = struct { form: Value, depth: u32 };
        var vars: std.ArrayList(Var) = .empty;
        var stack: std.ArrayList(Item) = .empty;
        defer stack.deinit(self.scratch);
        try stack.append(self.scratch, .{ .form = pattern.asPair().?.cdr, .depth = 0 });
        while (stack.pop()) |item| switch (item.form.kind()) {
            .symbol, .alias => switch (try self.role(item.form)) {
                .literal, .underscore => {},
                .ellipsis => return self.ctx.raise("bad syntax-rules: an ellipsis must follow a pattern", .{}),
                .variable => {
                    for (vars.items) |v| {
                        if (syntax_env.boundIdentifierEq(v.id, item.form)) return self.ctx.raise(
                            "bad syntax-rules: duplicate pattern variable: {s}",
                            .{self.ctx.symbols.nameOf(syntax_env.baseSymbol(item.form))},
                        );
                    }
                    try vars.append(self.scratch, .{ .id = item.form, .depth = item.depth });
                },
            },
            .empty_list => {},
            .pair => {
                const shape = try self.shapeOf(item.form, .pattern);
                try stack.append(self.scratch, .{ .form = shape.tail, .depth = item.depth });
                for (shape.elems) |e| try stack.append(self.scratch, .{ .form = e.form, .depth = item.depth + e.ellipses });
            },
            .vector => {
                const shape = try self.shapeOfVector(item.form, .pattern);
                for (shape.elems) |e| try stack.append(self.scratch, .{ .form = e.form, .depth = item.depth + e.ellipses });
            },
            // 定数は何も束縛しない。リーダが作るのは、この4種類だけである。
            .fixnum, .boolean, .character, .string => {},
            else => return self.ctx.raise("bad syntax-rules: this datum cannot be a pattern", .{}),
        };
        return vars.items;
    }

    /// The indexes of the variables in the pattern `form`.
    fn varsIn(self: Spec, form: Value, vars: []const Var) Error![]usize {
        var found: std.ArrayList(usize) = .empty;
        var stack: std.ArrayList(Value) = .empty;
        defer stack.deinit(self.scratch);
        try stack.append(self.scratch, form);
        while (stack.pop()) |v| switch (v.kind()) {
            .symbol, .alias => if (varIndex(vars, v)) |i| try found.append(self.scratch, i),
            .pair => {
                const p = v.asPair().?;
                try stack.append(self.scratch, p.cdr);
                try stack.append(self.scratch, p.car);
            },
            .vector => try stack.appendSlice(self.scratch, v.asVector().?.items),
            else => {},
        };
        return found.items;
    }

    /// A step of `match`.
    const MatchTask = union(enum) {
        /// Match `pattern` against `form`, noting what the variables matched in
        /// `out`.
        match: struct { pattern: Value, form: Value, out: []Match },
        /// After the passes of an ellipsis: the matches of its variables, one
        /// list of what each pass matched.
        gather: struct { repeated: []const usize, passes: []const []Match, out: []Match },
    };

    /// Whether `form`, from `use_env`, matches `pattern`, and if so what each
    /// variable of `vars` matched, in `out`.
    /// `pattern` は規則のパターンの全体で、`form` は利用の形式の先頭を除いた残りである。
    fn match(self: Spec, pattern: Value, form: Value, vars: []const Var, out: []Match, use_env: ?*const SyntacticEnv) Error!bool {
        var stack: std.ArrayList(MatchTask) = .empty;
        defer stack.deinit(self.scratch);
        try stack.append(self.scratch, .{ .match = .{ .pattern = pattern.asPair().?.cdr, .form = form, .out = out } });
        while (stack.pop()) |task| switch (task) {
            .gather => |g| for (g.repeated) |v| {
                const many = try self.scratch.alloc(Match, g.passes.len);
                for (many, g.passes) |*slot, pass| slot.* = pass[v];
                g.out[v] = .{ .many = many };
            },
            .match => |t| switch (t.pattern.kind()) {
                .symbol, .alias => switch (try self.role(t.pattern)) {
                    .underscore => {},
                    // R7RS 4.3.2: 入力が識別子で、利用側でのその意味と、定義側でのリテラルの
                    // 意味が同じときに限り照合する。綴りが同じでも、別の束縛なら照合しない。
                    .literal => {
                        if (!syntax_env.isIdentifier(t.form)) return false;
                        const used = try syntax_env.resolve(self.ctx, use_env, t.form);
                        const literal = try syntax_env.resolve(self.ctx, self.env, t.pattern);
                        if (!syntax_env.sameDenotation(used, literal)) return false;
                    },
                    .variable => t.out[varIndex(vars, t.pattern).?] = .{ .one = t.form },
                    .ellipsis => unreachable,
                },
                .empty_list => if (t.form.kind() != .empty_list) return false,
                .pair => {
                    const shape = try self.shapeOf(t.pattern, .pattern);
                    if (shape.repeated() == null) {
                        // 省略記号が無ければ、要素を1つずつ対応させ、残りを末尾のパターンに渡す。
                        var f = t.form;
                        for (shape.elems) |e| {
                            const p = f.asPair() orelse return false;
                            try stack.append(self.scratch, .{ .match = .{ .pattern = e.form, .form = p.car, .out = t.out } });
                            f = p.cdr;
                        }
                        try stack.append(self.scratch, .{ .match = .{ .pattern = shape.tail, .form = f, .out = t.out } });
                        continue;
                    }
                    var items: std.ArrayList(Value) = .empty;
                    var f = t.form;
                    while (f.asPair()) |p| : (f = p.cdr) try items.append(self.scratch, p.car);
                    if (!try self.matchRepeated(&stack, shape, items.items, f, vars, t.out)) return false;
                },
                .vector => {
                    const vector = t.form.asVector() orelse return false;
                    const shape = try self.shapeOfVector(t.pattern, .pattern);
                    if (shape.repeated() == null) {
                        if (vector.items.len != shape.elems.len) return false;
                        for (shape.elems, vector.items) |e, item|
                            try stack.append(self.scratch, .{ .match = .{ .pattern = e.form, .form = item, .out = t.out } });
                    } else if (!try self.matchRepeated(&stack, shape, vector.items, .empty_list_value, vars, t.out)) return false;
                },
                // 定数のパターンは、入力が equal? の意味で等しいときに照合する(R7RS 4.3.2)。
                else => if (!try isEqual(self.scratch, t.pattern, t.form)) return false,
            },
        };
        return true;
    }

    /// Queues the matching of the elements of `shape`, which has an ellipsis,
    /// against `items`; false when there are too few of them.
    /// 省略記号は、あとに続く要素のために残した分を除いて、できるだけ多くの形式に照合する。
    /// `tail` は、リストの入力の末尾が空リストでなかったときのそれで、末尾のパターンに渡る。
    fn matchRepeated(self: Spec, stack: *std.ArrayList(MatchTask), shape: Shape, items: []const Value, tail: Value, vars: []const Var, out: []Match) Error!bool {
        const repeated = shape.repeated().?;
        const after = shape.elems.len - repeated - 1;
        if (items.len < repeated + after) return false;
        const n = items.len - repeated - after;
        try stack.append(self.scratch, .{ .match = .{ .pattern = shape.tail, .form = tail, .out = out } });
        for (shape.elems[repeated + 1 ..], items[repeated + n ..]) |e, item|
            try stack.append(self.scratch, .{ .match = .{ .pattern = e.form, .form = item, .out = out } });
        const sub = shape.elems[repeated].form;
        const inside = try self.varsIn(sub, vars);
        // 繰り返しの1回ごとに、中の変数の照合結果を置く場所を作り、終わってから、
        // 変数ごとにその並びにまとめる。変数が無ければ、書く先は要らない。
        const passes = try self.scratch.alloc([]Match, if (inside.len == 0) 0 else n);
        for (passes) |*pass| {
            pass.* = try self.scratch.alloc(Match, vars.len);
            @memset(pass.*, .{ .one = .unspecified_value });
        }
        if (inside.len > 0) try stack.append(self.scratch, .{ .gather = .{ .repeated = inside, .passes = passes, .out = out } });
        var k = n;
        while (k > 0) {
            k -= 1;
            try stack.append(self.scratch, .{ .match = .{
                .pattern = sub,
                .form = items[repeated + k],
                .out = if (inside.len == 0) out else passes[k],
            } });
        }
        for (shape.elems[0..repeated], items[0..repeated]) |e, item|
            try stack.append(self.scratch, .{ .match = .{ .pattern = e.form, .form = item, .out = out } });
        return true;
    }

    /// What the variable `v` matched where the passes `pass` have got to, and how
    /// many ellipses a template still has to put after it.
    const Binding = struct { match: Match, remaining: u32 };

    fn lookup(vars: []const Var, matches: []const Match, pass: ?*const Pass, v: usize) Binding {
        var found: ?Match = null;
        var consumed: u32 = 0;
        var p = pass;
        while (p) |node| : (p = node.parent) {
            if (std.mem.indexOfScalar(usize, node.vars, v)) |i| {
                if (found == null) found = node.matched[i];
                consumed += 1;
            }
        }
        return .{ .match = found orelse matches[v], .remaining = vars[v].depth - consumed };
    }

    /// The variables of `form` that the ellipses after it repeat over, as the
    /// passes `pass` leave them.
    /// 変数が繰り返しを駆動するのは、まだ使っていない深さが、`form` の中でその出現を囲む
    /// 省略記号の数と、`form` の後ろにまだ残っている省略記号の数 `extra` の合計より大きいとき
    /// である。それ以外の出現は、内側の省略記号が使うか、複製される(R7RS 4.3.2)。
    fn drivers(self: Spec, form: Value, extra: u32, escaped: bool, vars: []const Var, matches: []const Match, pass: ?*const Pass) Error![]const usize {
        const Item = struct { form: Value, inner: u32, escaped: bool };
        var found: std.ArrayList(usize) = .empty;
        var stack: std.ArrayList(Item) = .empty;
        defer stack.deinit(self.scratch);
        try stack.append(self.scratch, .{ .form = form, .inner = 0, .escaped = escaped });
        while (stack.pop()) |item| switch (item.form.kind()) {
            .symbol, .alias => if (varIndex(vars, item.form)) |v| {
                if (lookup(vars, matches, pass, v).remaining > item.inner + extra and
                    std.mem.indexOfScalar(usize, found.items, v) == null) try found.append(self.scratch, v);
            },
            .pair => if (try self.escapedTemplate(item.form, item.escaped)) |inside| {
                try stack.append(self.scratch, .{ .form = inside, .inner = item.inner, .escaped = true });
            } else {
                const shape = try self.shapeOf(item.form, if (item.escaped) .literal else .template);
                // 書かれた順に見つかるように、後ろから積む。メッセージが先に書かれた変数を挙げる。
                try stack.append(self.scratch, .{ .form = shape.tail, .inner = item.inner, .escaped = item.escaped });
                var i = shape.elems.len;
                while (i > 0) {
                    i -= 1;
                    const e = shape.elems[i];
                    try stack.append(self.scratch, .{ .form = e.form, .inner = item.inner + e.ellipses, .escaped = item.escaped });
                }
            },
            .vector => {
                const shape = try self.shapeOfVector(item.form, if (item.escaped) .literal else .template);
                var i = shape.elems.len;
                while (i > 0) {
                    i -= 1;
                    const e = shape.elems[i];
                    try stack.append(self.scratch, .{ .form = e.form, .inner = item.inner + e.ellipses, .escaped = item.escaped });
                }
            },
            else => {},
        };
        return found.items;
    }

    /// The template of `(... template)`, when the list `form` is one that is
    /// not inside another escape; null for any other list.
    /// 先頭が省略記号の形式は、ちょうど1つのテンプレートを持たなければならない(R7RS 4.3.2)。
    fn escapedTemplate(self: Spec, form: Value, escaped: bool) Error!?Value {
        const first = form.asPair().?;
        if (escaped or !try self.isEllipsisForm(first.car)) return null;
        const second = first.cdr.asPair() orelse return self.ctx.raise(escape_shape, .{});
        if (second.cdr.kind() != .empty_list) return self.ctx.raise(escape_shape, .{});
        return second.car;
    }

    /// The output of `template`, with the pattern variables replaced by what
    /// they matched and every other identifier renamed to an alias with `mark`
    /// in `env`.
    /// `dry` なら、何も作らずに同じ道をたどる。そのとき `matches` は、各変数を深さの数だけ
    /// 長さ1の並びに包んだものである。マクロの定義の時点で、テンプレートの誤りを見つける
    /// ために使う。
    fn transcribe(self: Spec, template: Value, vars: []const Var, matches: []const Match, env: ?*SyntacticEnv, mark: u64, dry: bool) Error!Value {
        const Work = union(enum) {
            /// A template to transcribe, and the passes of the ellipses around it.
            template: struct { form: Value, pass: ?*const Pass, escaped: bool },
            /// A template that `left` ellipses follow.
            repeat: struct { form: Value, left: u32, pass: ?*const Pass, escaped: bool },
            /// The list of the outputs from `start` on; the last one is its
            /// tail when `dotted`.
            list: struct { start: usize, dotted: bool },
            /// The vector of the outputs from `start` on.
            vector: usize,
        };
        var work: std.ArrayList(Work) = .empty;
        defer work.deinit(self.scratch);
        var results: std.ArrayList(Value) = .empty;
        defer results.deinit(self.scratch);
        try work.append(self.scratch, .{ .template = .{ .form = template, .pass = null, .escaped = false } });
        while (work.pop()) |w| switch (w) {
            .list => |l| {
                var list: Value = .unspecified_value;
                if (!dry) {
                    list = if (l.dotted) results.pop().? else .empty_list_value;
                    var i = results.items.len;
                    while (i > l.start) {
                        i -= 1;
                        list = self.ctx.heap.cons(results.items[i], list) catch |e| return self.ctx.heapFailure(e);
                    }
                }
                results.shrinkRetainingCapacity(l.start);
                try results.append(self.scratch, list);
            },
            .vector => |start| {
                var vector: Value = .unspecified_value;
                if (!dry) vector = .fromVector(self.ctx.heap.createVector(results.items[start..]) catch |e| return self.ctx.heapFailure(e));
                results.shrinkRetainingCapacity(start);
                try results.append(self.scratch, vector);
            },
            .repeat => |r| {
                const driving = try self.drivers(r.form, r.left - 1, r.escaped, vars, matches, r.pass);
                if (driving.len == 0) return self.ctx.raise(
                    "bad syntax-rules: an ellipsis must follow a template with a pattern variable that an ellipsis followed",
                    .{},
                );
                const lists = try self.scratch.alloc([]Match, driving.len);
                for (lists, driving) |*slot, v| slot.* = lookup(vars, matches, r.pass, v).match.many;
                for (lists[1..], driving[1..]) |list, v| {
                    if (list.len != lists[0].len) return self.ctx.raise(
                        "bad syntax: {s} and {s} matched different numbers of forms but an ellipsis repeats them together",
                        .{
                            self.ctx.symbols.nameOf(syntax_env.baseSymbol(vars[driving[0]].id)),
                            self.ctx.symbols.nameOf(syntax_env.baseSymbol(vars[v].id)),
                        },
                    );
                }
                var k = lists[0].len;
                while (k > 0) {
                    k -= 1;
                    const matched = try self.scratch.alloc(Match, driving.len);
                    for (matched, lists) |*slot, list| slot.* = list[k];
                    const pass = try self.scratch.create(Pass);
                    pass.* = .{ .parent = r.pass, .vars = driving, .matched = matched };
                    try work.append(self.scratch, if (r.left == 1)
                        .{ .template = .{ .form = r.form, .pass = pass, .escaped = r.escaped } }
                    else
                        .{ .repeat = .{ .form = r.form, .left = r.left - 1, .pass = pass, .escaped = r.escaped } });
                }
            },
            .template => |t| switch (t.form.kind()) {
                .symbol, .alias => if (varIndex(vars, t.form)) |v| {
                    const b = lookup(vars, matches, t.pass, v);
                    if (b.remaining != 0) return self.ctx.raise(
                        "bad syntax-rules: {s} needs as many ellipses in the template as in its pattern",
                        .{self.ctx.symbols.nameOf(syntax_env.baseSymbol(t.form))},
                    );
                    try results.append(self.scratch, b.match.one);
                } else if (!t.escaped and try self.isEllipsis(t.form)) {
                    return self.ctx.raise("bad syntax-rules: an ellipsis must follow a template", .{});
                } else if (dry) {
                    try results.append(self.scratch, .unspecified_value);
                } else {
                    const alias = try self.ctx.create(value_mod.Alias, .{ .inner = t.form, .env = env, .mark = mark });
                    try results.append(self.scratch, .fromAlias(alias));
                },
                .pair => if (try self.escapedTemplate(t.form, t.escaped)) |inside| {
                    try work.append(self.scratch, .{ .template = .{ .form = inside, .pass = t.pass, .escaped = true } });
                } else {
                    const shape = try self.shapeOf(t.form, if (t.escaped) .literal else .template);
                    const dotted = shape.tail.kind() != .empty_list;
                    // 要素を先頭から集めて、後ろのものから積む。積んだ順と逆に取り出される。
                    try work.append(self.scratch, .{ .list = .{ .start = results.items.len, .dotted = dotted } });
                    if (dotted) try work.append(self.scratch, .{ .template = .{ .form = shape.tail, .pass = t.pass, .escaped = t.escaped } });
                    var i = shape.elems.len;
                    while (i > 0) {
                        i -= 1;
                        const e = shape.elems[i];
                        try work.append(self.scratch, if (e.ellipses == 0)
                            .{ .template = .{ .form = e.form, .pass = t.pass, .escaped = t.escaped } }
                        else
                            .{ .repeat = .{ .form = e.form, .left = e.ellipses, .pass = t.pass, .escaped = t.escaped } });
                    }
                },
                .vector => {
                    const shape = try self.shapeOfVector(t.form, if (t.escaped) .literal else .template);
                    try work.append(self.scratch, .{ .vector = results.items.len });
                    var i = shape.elems.len;
                    while (i > 0) {
                        i -= 1;
                        const e = shape.elems[i];
                        try work.append(self.scratch, if (e.ellipses == 0)
                            .{ .template = .{ .form = e.form, .pass = t.pass, .escaped = t.escaped } }
                        else
                            .{ .repeat = .{ .form = e.form, .left = e.ellipses, .pass = t.pass, .escaped = t.escaped } });
                    }
                },
                else => try results.append(self.scratch, t.form),
            },
        };
        return results.items[0];
    }

    /// `matches` for a dry run of `transcribe`: each variable matched once at
    /// every depth.
    fn dryMatches(self: Spec, vars: []const Var) Error![]Match {
        const matches = try self.scratch.alloc(Match, vars.len);
        for (matches, vars) |*slot, v| {
            slot.* = .{ .one = .unspecified_value };
            for (0..v.depth) |_| {
                const layer = try self.scratch.alloc(Match, 1);
                layer[0] = slot.*;
                slot.* = .{ .many = layer };
            }
        }
        return matches;
    }
};

/// The index of the pattern variable `id` in `vars`, or null when it is not one.
fn varIndex(vars: []const Var, id: Value) ?usize {
    for (vars, 0..) |v, i| {
        if (syntax_env.boundIdentifierEq(v.id, id)) return i;
    }
    return null;
}

test {
    std.testing.refAllDecls(@This());
}

const tier = @import("../tier.zig");

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

    fn read(self: *Fixture, src: []const u8) !Value {
        var r: @import("../reader.zig").Reader = .init(src);
        const sink: @import("../reader.zig").Sink = .{ .alloc = self.ctx.persist, .heap = &self.ctx.heap, .symbols = &self.ctx.symbols };
        return (try r.next(self.arena.allocator(), sink)).?;
    }

    /// The macro of the `syntax-rules` form `src`, defined at the top level.
    fn macro(self: *Fixture, src: []const u8) !*Macro {
        return compile(&self.ctx, self.arena.allocator(), try self.read(src), null, null);
    }

    /// What `use` transcribes to, written out.
    fn transcribed(self: *Fixture, m: *const Macro, use: []const u8) ![]const u8 {
        const out = try transform(&self.ctx, self.arena.allocator(), m, try self.read(use), null);
        var w: std.Io.Writer.Allocating = .init(self.arena.allocator());
        try @import("../printer.zig").write(&w.writer, self.arena.allocator(), &self.ctx.symbols, out);
        return w.written();
    }

    fn cons(self: *Fixture, car: Value, cdr: Value) !Value {
        return self.ctx.heap.cons(car, cdr);
    }

    fn sym(self: *Fixture, name: []const u8) !Value {
        return .fromSymbol(try self.ctx.symbols.intern(self.arena.allocator(), name));
    }
};

test "a template's identifiers become aliases and the pattern variables become what they matched" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const m = try f.macro("(syntax-rules () ((_ a b) (f a tmp b)))");
    try std.testing.expectEqualStrings("(#<alias f> x #<alias tmp> (y z))", try f.transcribed(m, "(m x (y z))"));
    // 規則のパターンの先頭は照合に関与しない。利用側の先頭は、どの名前でもよい。
    try std.testing.expectEqualStrings("(#<alias f> 1 #<alias tmp> 2)", try f.transcribed(m, "(other 1 2)"));
}

test "the keyword at the start of a pattern is neither a pattern variable nor a literal" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    // パターン変数なら、テンプレートの kw が利用側の先頭 m に置き換わる。
    const m = try f.macro("(syntax-rules () ((kw a) (kw a)))");
    try std.testing.expectEqualStrings("(#<alias kw> 1)", try f.transcribed(m, "(m 1)"));
    // リテラルの一覧にあっても、先頭はリテラルとして照合しない。
    const lit = try f.macro("(syntax-rules (kw) ((kw a) a))");
    try std.testing.expectEqualStrings("1", try f.transcribed(lit, "(m 1)"));
}

test "one application gives all its aliases one mark, and the next application another" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const m = try f.macro("(syntax-rules () ((_) (tmp tmp)))");
    const first = try transform(&f.ctx, f.arena.allocator(), m, try f.read("(m)"), null);
    const second = try transform(&f.ctx, f.arena.allocator(), m, try f.read("(m)"), null);
    const a = first.asPair().?.car;
    const b = first.asPair().?.cdr.asPair().?.car;
    const c = second.asPair().?.car;
    // 同じ適用の同じ識別子は、同じ識別子である。別の適用のものは、綴りが同じでも違う。
    try std.testing.expect(syntax_env.boundIdentifierEq(a, b));
    try std.testing.expect(!syntax_env.boundIdentifierEq(a, c));
    try std.testing.expect(a.asAlias().?.mark != c.asAlias().?.mark);
    try std.testing.expect(a.asAlias().?.env == null);
}

test "an application past the last mark is an implementation restriction" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const m = try f.macro("(syntax-rules () ((_) tmp))");
    f.ctx.next_mark = std.math.maxInt(u64) - 1;
    const last = try transform(&f.ctx, f.arena.allocator(), m, try f.read("(m)"), null);
    try std.testing.expectEqual(std.math.maxInt(u64) - 1, last.asAlias().?.mark);
    try std.testing.expectError(error.Raised, transform(&f.ctx, f.arena.allocator(), m, try f.read("(m)"), null));
    try std.testing.expectEqualStrings("implementation restriction: too many macro applications", f.ctx.diagnostic());
}

test "an ellipsis repeats over zero or more forms, and a variable of depth 0 is copied into each" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const m = try f.macro("(syntax-rules () ((_ p (x y) ...) ((p x y) ... end)))");
    try std.testing.expectEqualStrings("((a 1 2) (a 3 4) #<alias end>)", try f.transcribed(m, "(m a (1 2) (3 4))"));
    try std.testing.expectEqualStrings("(#<alias end>)", try f.transcribed(m, "(m a)"));
    // 繰り返しの中の形が合わなければ、照合しない。
    try std.testing.expectError(error.Raised, f.transcribed(m, "(m a (1 2) 3)"));
    try std.testing.expectEqualStrings("bad syntax: no rule of m matches the form", f.ctx.diagnostic());
}

test "a literal matches an identifier with the same binding, and _ matches anything without binding it" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const m = try f.macro("(syntax-rules (=>) ((_ => _) arrow) ((_ x _) other))");
    try std.testing.expectEqualStrings("#<alias arrow>", try f.transcribed(m, "(m => 1)"));
    try std.testing.expectEqualStrings("#<alias other>", try f.transcribed(m, "(m 1 2)"));
    // 識別子でない入力は、リテラルに照合しない。
    try std.testing.expectEqualStrings("#<alias other>", try f.transcribed(m, "(m (=>) 2)"));
}

test "_ and the ellipsis in the list of literals are literals" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    // リテラルの一覧にあることが、`_` と省略記号であることより先である(R7RS 4.3.2)。
    const under = try f.macro("(syntax-rules (_) ((k _) lit) ((k x) other))");
    try std.testing.expectEqualStrings("#<alias lit>", try f.transcribed(under, "(m _)"));
    try std.testing.expectEqualStrings("#<alias other>", try f.transcribed(under, "(m 1)"));
    const dots = try f.macro("(syntax-rules (...) ((k a ...) a))");
    try std.testing.expectEqualStrings("1", try f.transcribed(dots, "(m 1 ...)"));
    try std.testing.expectError(error.Raised, f.transcribed(dots, "(m 1 2)"));
}

/// `inner` wrapped in `depth` lists: `((((inner))))`.
fn nested(f: *Fixture, inner: Value, depth: usize) !Value {
    var v = inner;
    for (0..depth) |_| v = try f.cons(v, .empty_list_value);
    return v;
}

/// Checks that the matcher and the transcriber walk a pattern, an input and a
/// template `depth` lists deep, which a Zig recursion could not.
fn expectDeep(depth: usize) !void {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const x = try f.sym("x");
    // (syntax-rules () ((_ ((x))) ((x))))
    const pattern = try f.cons(try f.sym("_"), try f.cons(try nested(&f, x, depth), .empty_list_value));
    const template = try nested(&f, x, depth);
    const rule = try f.cons(pattern, try f.cons(template, .empty_list_value));
    const spec = try f.cons(try f.sym("syntax-rules"), try f.cons(.empty_list_value, try f.cons(rule, .empty_list_value)));
    const m = try compile(&f.ctx, f.arena.allocator(), spec, null, null);
    const use = try f.cons(try f.sym("m"), try f.cons(try nested(&f, .fromFixnum(5), depth), .empty_list_value));
    var out = try transform(&f.ctx, f.arena.allocator(), m, use, null);
    for (0..depth) |_| {
        const p = out.asPair().?;
        try std.testing.expectEqual(Value.empty_list_value.kind(), p.cdr.kind());
        out = p.car;
    }
    try std.testing.expectEqual(5, out.asFixnum().?);
    // 1段浅い入力は照合しない。
    const shallow = try f.cons(try f.sym("m"), try f.cons(try nested(&f, .fromFixnum(5), depth - 1), .empty_list_value));
    try std.testing.expectError(error.Raised, transform(&f.ctx, f.arena.allocator(), m, shallow, null));
}

test "a pattern and a template nested deep are matched and transcribed" {
    try expectDeep(1000);
}

test "slow: a pattern and a template nested deeper than the Zig stack allows are matched and transcribed" {
    try tier.slow();
    try expectDeep(200_000);
}
