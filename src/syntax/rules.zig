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

pub const Error = context.Error;

/// Checks `spec`, a `(syntax-rules (literal ...) rule ...)` form whose keyword
/// the caller has resolved, and makes the macro it describes, defined in `env`.
/// 誤りは定義の時点で報告する。マクロが使われるまで待つと、使われないマクロの誤りが
/// 見つからない。
pub fn compile(ctx: *Context, scratch: std.mem.Allocator, spec: Value, env: ?*SyntacticEnv) Error!*Macro {
    const shape = "bad syntax-rules: expected (syntax-rules (literal ...) rule ...)";
    const after_keyword = spec.asPair().?.cdr;
    const literals_pair = after_keyword.asPair() orelse return ctx.raise(shape, .{});
    const literals = literals_pair.car;
    if (syntax_env.isIdentifier(literals))
        return ctx.raise("bad syntax-rules: a custom ellipsis is not supported yet", .{});
    var rest = literals;
    while (rest.asPair()) |p| : (rest = p.cdr) {
        if (!syntax_env.isIdentifier(p.car)) return ctx.raise("bad syntax-rules: a literal must be an identifier", .{});
    }
    if (rest.kind() != .empty_list) return ctx.raise(shape, .{});
    const rules = literals_pair.cdr;
    const s: Spec = .{ .ctx = ctx, .scratch = scratch, .literals = literals, .env = env };
    var r = rules;
    while (r.asPair()) |p| : (r = p.cdr) {
        const rule = try s.ruleOf(p.car);
        const vars = try s.patternVars(rule.pattern);
        try s.checkTemplate(rule.template, vars);
    }
    if (r.kind() != .empty_list) return ctx.raise(shape, .{});
    return ctx.create(Macro, .{ .literals = literals, .rules = rules, .env = env });
}

/// Transcribes `form`, a use of `macro` in `use_env`, by the first rule whose
/// pattern it matches.
/// 展開器が変換子を呼ぶのは、ここ1か所である。手続き的マクロに広げるときは、ここで
/// 変換子の種類に応じて分ける(docs/design/frontend.md の変換子の実行)。
pub fn transform(ctx: *Context, scratch: std.mem.Allocator, macro: *const Macro, form: Value, use_env: ?*const SyntacticEnv) Error!Value {
    const s: Spec = .{ .ctx = ctx, .scratch = scratch, .literals = macro.literals, .env = macro.env };
    var r = macro.rules;
    while (r.asPair()) |p| : (r = p.cdr) {
        const rule = try s.ruleOf(p.car);
        const vars = try s.patternVars(rule.pattern);
        const matches = try scratch.alloc(Match, vars.len);
        // 規則のパターンの先頭は照合に関与しない(R7RS 4.3.2)。利用側の先頭は、別の名前
        // で書かれていても、マクロのキーワードである。
        if (try s.match(rule.pattern, form.asPair().?.cdr, vars, matches, use_env)) {
            const mark = try ctx.newMark();
            return s.transcribe(rule.template, vars, matches, macro.env, mark);
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

/// What the identifiers of a transformer are read against: its literals, and
/// the environment it was defined in.
const Spec = struct {
    ctx: *Context,
    scratch: std.mem.Allocator,
    literals: Value,
    env: ?*SyntacticEnv,

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
        if (try self.means(id, "...")) return .ellipsis;
        return .variable;
    }

    /// Whether `id` means, where the transformer is defined, what `name` means
    /// at the top level.
    /// 綴りを先に比べる。比べずに解決すると、最上位で定義したマクロのパターン変数の
    /// それぞれに、REPL の未束縛のセルを作ることになる。
    fn means(self: Spec, id: Value, comptime name: []const u8) Error!bool {
        const symbol = self.ctx.symbols.index.get(name) orelse return false;
        if (syntax_env.baseSymbol(id) != symbol) return false;
        return syntax_env.sameDenotation(
            try syntax_env.resolve(self.ctx, self.env, id),
            try syntax_env.resolve(self.ctx, null, .fromSymbol(symbol)),
        );
    }

    /// Whether the element after `p` in a list is the ellipsis.
    fn ellipsisFollows(self: Spec, p: *const value_mod.Pair) Error!bool {
        const next = p.cdr.asPair() orelse return false;
        return syntax_env.isIdentifier(next.car) and try self.role(next.car) == .ellipsis;
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
                var rest = item.form;
                while (rest.asPair()) |p| : (rest = p.cdr) {
                    if (try self.ellipsisFollows(p)) {
                        const after = p.cdr.asPair().?.cdr;
                        if (after.kind() != .empty_list)
                            return self.ctx.raise("bad syntax-rules: patterns after an ellipsis are not supported yet", .{});
                        if (item.depth > 0)
                            return self.ctx.raise("bad syntax-rules: nested ellipses are not supported yet", .{});
                        try stack.append(self.scratch, .{ .form = p.car, .depth = item.depth + 1 });
                        rest = after;
                        break;
                    }
                    try stack.append(self.scratch, .{ .form = p.car, .depth = item.depth });
                }
                if (rest.kind() != .empty_list)
                    return self.ctx.raise("bad syntax-rules: improper list patterns are not supported yet", .{});
            },
            .vector => return self.ctx.raise("bad syntax-rules: vector patterns are not supported yet", .{}),
            else => return self.ctx.raise("bad syntax-rules: constant patterns are not supported yet", .{}),
        };
        return vars.items;
    }

    /// Checks that each pattern variable in `template` is followed by at least
    /// as many ellipses as in its pattern, and that each ellipsis repeats one.
    /// Why: R7RS 4.3.2 が制約するのは、省略記号つきの部分パターンに現れる変数だけで
    /// ある。深さ0の変数は、省略記号の内側に置いてよく、繰り返しの回数だけ複製される
    /// (docs/design/frontend.md の深さの規則)。一律に深さの一致を求めると、R7RS 7.3 の
    /// `define-values` の定義が拒否される。
    fn checkTemplate(self: Spec, template: Value, vars: []const Var) Error!void {
        const Item = struct { form: Value, depth: u32 };
        var stack: std.ArrayList(Item) = .empty;
        defer stack.deinit(self.scratch);
        try stack.append(self.scratch, .{ .form = template, .depth = 0 });
        while (stack.pop()) |item| switch (item.form.kind()) {
            .symbol, .alias => if (varIndex(vars, item.form)) |v| {
                if (vars[v].depth > item.depth) return self.ctx.raise(
                    "bad syntax-rules: {s} needs as many ellipses in the template as in its pattern",
                    .{self.ctx.symbols.nameOf(syntax_env.baseSymbol(item.form))},
                );
            } else if (try self.role(item.form) == .ellipsis) {
                return self.ctx.raise("bad syntax-rules: an ellipsis must follow a template", .{});
            },
            .pair => {
                const first = item.form.asPair().?;
                if (syntax_env.isIdentifier(first.car) and try self.role(first.car) == .ellipsis)
                    return self.ctx.raise("bad syntax-rules: ellipsis escapes are not supported yet", .{});
                var rest = item.form;
                while (rest.asPair()) |p| {
                    if (try self.ellipsisFollows(p)) {
                        // `ellipsis` は省略記号のペアで、その後ろから続ける。
                        const ellipsis = p.cdr.asPair().?;
                        if (item.depth > 0 or try self.ellipsisFollows(ellipsis))
                            return self.ctx.raise("bad syntax-rules: nested ellipses are not supported yet", .{});
                        if ((try self.repeatedVars(p.car, vars)).len == 0)
                            return self.ctx.raise("bad syntax-rules: an ellipsis must follow a template with a pattern variable that an ellipsis followed", .{});
                        try stack.append(self.scratch, .{ .form = p.car, .depth = item.depth + 1 });
                        rest = ellipsis.cdr;
                    } else {
                        try stack.append(self.scratch, .{ .form = p.car, .depth = item.depth });
                        rest = p.cdr;
                    }
                }
                if (rest.kind() != .empty_list)
                    return self.ctx.raise("bad syntax-rules: improper list templates are not supported yet", .{});
            },
            .vector => return self.ctx.raise("bad syntax-rules: vector templates are not supported yet", .{}),
            else => {},
        };
    }

    /// The indexes of the variables in `form` that an ellipsis followed in
    /// their pattern.
    fn repeatedVars(self: Spec, form: Value, vars: []const Var) Error![]usize {
        var found: std.ArrayList(usize) = .empty;
        var stack: std.ArrayList(Value) = .empty;
        defer stack.deinit(self.scratch);
        try stack.append(self.scratch, form);
        while (stack.pop()) |v| switch (v.kind()) {
            .symbol, .alias => if (varIndex(vars, v)) |i| {
                if (vars[i].depth > 0 and std.mem.indexOfScalar(usize, found.items, i) == null) try found.append(self.scratch, i);
            },
            .pair => {
                const p = v.asPair().?;
                try stack.append(self.scratch, p.cdr);
                try stack.append(self.scratch, p.car);
            },
            else => {},
        };
        return found.items;
    }

    /// Whether `form`, from `use_env`, matches `pattern`, and if so what each
    /// variable of `vars` matched, in `out`.
    /// `pattern` は規則のパターンの全体で、`form` は利用の形式の先頭を除いた残りである。
    fn match(self: Spec, pattern: Value, form: Value, vars: []const Var, out: []Match, use_env: ?*const SyntacticEnv) Error!bool {
        // `index` は、省略記号が繰り返した何番目の形式の中にいるかである。
        const Task = struct { pattern: Value, form: Value, index: ?usize };
        var stack: std.ArrayList(Task) = .empty;
        defer stack.deinit(self.scratch);
        try stack.append(self.scratch, .{ .pattern = pattern.asPair().?.cdr, .form = form, .index = null });
        while (stack.pop()) |t| switch (t.pattern.kind()) {
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
                .variable => {
                    const v = varIndex(vars, t.pattern).?;
                    if (t.index) |k| out[v].many[k] = .{ .one = t.form } else out[v] = .{ .one = t.form };
                },
                .ellipsis => unreachable,
            },
            .empty_list => if (t.form.kind() != .empty_list) return false,
            .pair => {
                var fixed: usize = 0;
                var repeated: ?Value = null;
                var rest = t.pattern;
                while (rest.asPair()) |p| : (rest = p.cdr) {
                    if (try self.ellipsisFollows(p)) {
                        repeated = p.car;
                        break;
                    }
                    fixed += 1;
                }
                const length = properLength(t.form) orelse return false;
                if (length < fixed or (repeated == null and length != fixed)) return false;
                var ps = t.pattern;
                var fs = t.form;
                for (0..fixed) |_| {
                    const p = ps.asPair().?;
                    const f = fs.asPair().?;
                    try stack.append(self.scratch, .{ .pattern = p.car, .form = f.car, .index = t.index });
                    ps = p.cdr;
                    fs = f.cdr;
                }
                if (repeated) |sub| {
                    // 深さ1の省略記号だけなので、ここに来るのは省略記号の外である。
                    std.debug.assert(t.index == null);
                    const n = length - fixed;
                    for (try self.repeatedVars(sub, vars)) |v| out[v] = .{ .many = try self.scratch.alloc(Match, n) };
                    for (0..n) |k| {
                        const f = fs.asPair().?;
                        try stack.append(self.scratch, .{ .pattern = sub, .form = f.car, .index = k });
                        fs = f.cdr;
                    }
                }
            },
            else => unreachable,
        };
        return true;
    }

    /// The output of `template`, with the pattern variables replaced by what
    /// they matched and every other identifier renamed to an alias with `mark`
    /// in `env`.
    fn transcribe(self: Spec, template: Value, vars: []const Var, matches: []const Match, env: ?*SyntacticEnv, mark: u64) Error!Value {
        const Work = union(enum) {
            /// A template to transcribe, and the place in the repetition of
            /// the ellipsis it is under.
            template: struct { form: Value, index: ?usize },
            /// The list of the outputs from `start` on.
            list: usize,
        };
        var work: std.ArrayList(Work) = .empty;
        defer work.deinit(self.scratch);
        var results: std.ArrayList(Value) = .empty;
        defer results.deinit(self.scratch);
        try work.append(self.scratch, .{ .template = .{ .form = template, .index = null } });
        while (work.pop()) |w| switch (w) {
            .list => |start| {
                var list: Value = .empty_list_value;
                var i = results.items.len;
                while (i > start) {
                    i -= 1;
                    list = self.ctx.heap.cons(results.items[i], list) catch |e| return self.ctx.heapFailure(e);
                }
                results.shrinkRetainingCapacity(start);
                try results.append(self.scratch, list);
            },
            .template => |t| switch (t.form.kind()) {
                .symbol, .alias => if (varIndex(vars, t.form)) |v| {
                    const m = matches[v];
                    try results.append(self.scratch, if (vars[v].depth == 0) m.one else m.many[t.index.?].one);
                } else {
                    const alias = try self.ctx.create(value_mod.Alias, .{ .inner = t.form, .env = env, .mark = mark });
                    try results.append(self.scratch, .fromAlias(alias));
                },
                .pair => {
                    try work.append(self.scratch, .{ .list = results.items.len });
                    // 要素を先頭から集め、後ろのものから積む。積んだ順と逆に取り出される。
                    const Element = struct { form: Value, repeated: bool };
                    var elements: std.ArrayList(Element) = .empty;
                    var rest = t.form;
                    while (rest.asPair()) |p| {
                        const repeated = try self.ellipsisFollows(p);
                        try elements.append(self.scratch, .{ .form = p.car, .repeated = repeated });
                        // 繰り返す要素なら、後ろの省略記号を飛ばす。
                        rest = if (repeated) p.cdr.asPair().?.cdr else p.cdr;
                    }
                    var i = elements.items.len;
                    while (i > 0) {
                        i -= 1;
                        const e = elements.items[i];
                        if (!e.repeated) {
                            try work.append(self.scratch, .{ .template = .{ .form = e.form, .index = t.index } });
                            continue;
                        }
                        const n = try self.repetitions(e.form, vars, matches);
                        var k = n;
                        while (k > 0) {
                            k -= 1;
                            try work.append(self.scratch, .{ .template = .{ .form = e.form, .index = k } });
                        }
                    }
                },
                else => try results.append(self.scratch, t.form),
            },
        };
        return results.items[0];
    }

    /// How many times the ellipsis after `form` repeats it: how many forms its
    /// repeated variables matched, which must be the same for all of them.
    fn repetitions(self: Spec, form: Value, vars: []const Var, matches: []const Match) Error!usize {
        const repeated = try self.repeatedVars(form, vars);
        const n = matches[repeated[0]].many.len;
        for (repeated[1..]) |v| {
            if (matches[v].many.len != n) return self.ctx.raise(
                "bad syntax: {s} and {s} matched different numbers of forms but an ellipsis repeats them together",
                .{
                    self.ctx.symbols.nameOf(syntax_env.baseSymbol(vars[repeated[0]].id)),
                    self.ctx.symbols.nameOf(syntax_env.baseSymbol(vars[v].id)),
                },
            );
        }
        return n;
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
        return compile(&self.ctx, self.arena.allocator(), try self.read(src), null);
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
    const m = try compile(&f.ctx, f.arena.allocator(), spec, null);
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
