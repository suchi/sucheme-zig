//! Evaluates a form.
//!
//! A plain recursive evaluator, as docs/plans/0003-phase1-minimal-slice.md
//! decides for slices 1a to 1e. Slice 1f replaces it with the CEK machine in
//! machine.zig, which is the only place docs/design/architecture.md lets
//! evaluation advance. That document records this file as a provisional
//! exception until then.
//!
//! Slice 1e evaluates integers, booleans, variables, `define` (also the
//! `(define (name parameter ...) body ...)` form, and at the start of a body),
//! `quote`, `if`, `lambda`, `begin`, `set!` and procedure calls. A local variable is found by
//! name in the frames of the calls that are open around the `lambda`; slice 1f
//! replaces that with lexical addresses. A Scheme error is a Zig error with a
//! message in `Context`.

const std = @import("std");
const value_mod = @import("value.zig");
const Value = value_mod.Value;
const Closure = value_mod.Closure;
const Frame = value_mod.Frame;
const SymbolId = symbol.SymbolId;
const arith = @import("prim/arith.zig");
const symbol = @import("symbol.zig");
const env = @import("env.zig");
const context = @import("context.zig");

pub const Error = arith.Error || error{
    OutOfMemory,
    /// `()` is not an expression (R7RS 4.1.3 requires an operator).
    EmptyCombination,
    /// An identifier naming nothing.
    UnboundVariable,
    /// A call with a number of arguments the procedure does not take.
    WrongArgumentCount,
    /// A local variable read before its definition has run.
    UninitializedVariable,
    /// A form whose shape the evaluator rejects, such as `(define)`.
    BadSyntax,
    /// The operator is not a procedure.
    NotAProcedure,
    /// The expression nests deeper than `max_depth`.
    NestingTooDeep,
};

pub const Context = context.Context;

/// How deep `eval` recurses before giving up.
///
/// The recursion is on the Zig stack, and a nesting deep enough to overflow it
/// would kill the process instead of reporting an error. The reader handles any
/// depth, so this is where the limit has to be. It goes with the recursion,
/// when slice 1f moves evaluation into the machine.
///
/// Why: the stack a level costs depends on the build mode and on what `evalAt`
/// does in a level, and it grew when `define` was added. A figure written here
/// went stale once, so the test "the deepest legal evaluation of each form
/// fits" runs the deepest legal input of each form on a stack half the size of
/// 1 MiB, the smallest a host is assumed to give. Adding a form or a local to
/// `evalAt` that makes a level cost more fails that test, and the limit comes
/// down with it.
pub const max_depth = 150;

/// The special forms. A keyword cannot be shadowed, redefined, assigned or used
/// as a variable or a parameter; the expander of stage 2 replaces this enum with
/// syntactic bindings.
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

/// Where a form stands, which decides whether a definition is allowed there
/// (R7RS 5.3): at the top level, or at the start of a body.
const Position = enum { top, body, expression };

/// Where a form is evaluated: the frame whose variables it sees, and its
/// position.
const Scope = struct {
    env: ?*Frame,
    pos: Position,

    /// The same variables, inside an expression.
    fn inner(self: Scope) Scope {
        return .{ .env = self.env, .pos = .expression };
    }
};

/// Evaluates `form` at the top level. Temporary storage, such as the evaluated
/// arguments, comes from `arena`; the data a form returns is whatever the reader
/// allocated. On an error `ctx` holds the message.
pub fn eval(ctx: *Context, arena: std.mem.Allocator, form: Value) Error!Value {
    return evalAt(ctx, arena, form, 0, .{ .env = null, .pos = .top });
}

fn evalAt(ctx: *Context, arena: std.mem.Allocator, form: Value, depth: usize, scope: Scope) Error!Value {
    if (depth >= max_depth) return ctx.fail(error.NestingTooDeep, "nesting too deep", .{});
    switch (form.kind()) {
        // Self-evaluating (R7RS 4.1.2).
        .fixnum, .boolean, .unspecified, .uninitialized, .primitive, .closure => return form,
        // Why: R7RS 4.1.3 gives a procedure call a nonempty list.
        .empty_list => return ctx.fail(error.EmptyCombination, "empty combination", .{}),
        .symbol => return lookupVariable(ctx, form.asSymbol().?, scope),
        .pair => {
            const items = try itemsOf(ctx, arena, form);
            if (items[0].asSymbol()) |head| {
                if (Keyword.of(ctx.symbols.nameOf(head))) |keyword| return switch (keyword) {
                    .define => evalDefine(ctx, arena, items, depth, scope),
                    .quote => evalQuote(ctx, items),
                    .@"if" => evalIf(ctx, arena, items, depth, scope),
                    .lambda => evalLambda(ctx, arena, items, scope),
                    .begin => evalBegin(ctx, arena, items, depth, scope),
                    .@"set!" => evalSet(ctx, arena, items, depth, scope),
                };
            }
            return evalCall(ctx, arena, items, depth, scope);
        },
    }
}

/// The value of the variable `id`: a local one if a frame binds it, otherwise a
/// global one.
fn lookupVariable(ctx: *Context, id: SymbolId, scope: Scope) Error!Value {
    const name = ctx.symbols.nameOf(id);
    if (Keyword.of(name) != null)
        return ctx.fail(error.BadSyntax, "{s} is a syntactic keyword and cannot be used as a variable", .{name});
    if (env.findLocal(scope.env, id)) |slot| {
        if (slot.kind() == .uninitialized)
            return ctx.fail(error.UninitializedVariable, "variable used before its definition: {s}", .{name});
        return slot.*;
    }
    if (ctx.globals.lookup(id)) |v| return v;
    return ctx.fail(error.UnboundVariable, "unbound variable: {s}", .{name});
}

/// The elements of the list `form`, in `arena`. A form is a proper list; the
/// reader cannot write any other, so this fails only for a datum built by hand.
fn itemsOf(ctx: *Context, arena: std.mem.Allocator, form: Value) Error![]const Value {
    var items: std.ArrayList(Value) = .empty;
    var rest = form;
    while (rest.asPair()) |p| : (rest = p.cdr) try items.append(arena, p.car);
    if (rest.kind() != .empty_list)
        return ctx.fail(error.BadSyntax, "bad syntax: a form must be a proper list", .{});
    return items.items;
}

/// A procedure call (R7RS 4.1.3): the operator, then the operands from left to
/// right, then the application. Why: R7RS leaves the order of evaluation
/// unspecified; left to right is the one a reader expects.
fn evalCall(ctx: *Context, arena: std.mem.Allocator, items: []const Value, depth: usize, scope: Scope) Error!Value {
    const operator = try evalAt(ctx, arena, items[0], depth + 1, scope.inner());
    const args = try arena.alloc(Value, items.len - 1);
    for (items[1..], args) |operand, *arg| arg.* = try evalAt(ctx, arena, operand, depth + 1, scope.inner());
    return apply(ctx, arena, operator, args, depth);
}

fn apply(ctx: *Context, arena: std.mem.Allocator, procedure: Value, args: []const Value, depth: usize) Error!Value {
    if (procedure.asPrimitive()) |prim| {
        return prim.call(args) catch |e| switch (e) {
            error.WrongType => ctx.fail(e, "wrong type of argument to {s}", .{prim.name}),
            error.IntegerOverflow => ctx.fail(e, "integer overflow in {s}", .{prim.name}),
            error.WrongArgumentCount => ctx.fail(e, "wrong number of arguments to {s}", .{prim.name}),
        };
    }
    const closure = procedure.asClosure() orelse
        return ctx.fail(error.NotAProcedure, "not a procedure", .{});
    if (args.len != closure.arity) return ctx.fail(
        error.WrongArgumentCount,
        "wrong number of arguments: expected {d}, got {d}",
        .{ closure.arity, args.len },
    );
    // The frame outlives the call when a closure made in it does, so it is
    // allocated where closures are, not in `arena`. The names the body defines
    // start out uninitialized (R7RS 5.3.2: a body is a `letrec*`).
    const frame = try ctx.persist.create(Frame);
    const values = try ctx.persist.alloc(Value, closure.names.len);
    @memcpy(values[0..args.len], args);
    @memset(values[args.len..], Value.uninitialized_value);
    frame.* = .{ .names = closure.names, .values = values, .parent = closure.env };
    const definitions: Scope = .{ .env = frame, .pos = .body };
    for (closure.body[0..closure.defines]) |form| _ = try evalAt(ctx, arena, form, depth + 1, definitions);
    const expressions = closure.body[closure.defines..];
    const scope: Scope = .{ .env = frame, .pos = .expression };
    for (expressions[0 .. expressions.len - 1]) |form| _ = try evalAt(ctx, arena, form, depth + 1, scope);
    return evalAt(ctx, arena, expressions[expressions.len - 1], depth + 1, scope);
}

/// `(quote datum)` (R7RS 4.1.2). The datum, unevaluated.
fn evalQuote(ctx: *Context, items: []const Value) Error!Value {
    if (items.len != 2)
        return ctx.fail(error.BadSyntax, "bad quote: expected (quote datum)", .{});
    return items[1];
}

/// `(if test consequent [alternative])` (R7RS 4.1.5). Evaluates the test, then
/// the consequent when it is true and the alternative otherwise. Without an
/// alternative, a false test gives the unspecified value.
fn evalIf(ctx: *Context, arena: std.mem.Allocator, items: []const Value, depth: usize, scope: Scope) Error!Value {
    if (items.len != 3 and items.len != 4)
        return ctx.fail(error.BadSyntax, "bad if: expected (if test consequent) or (if test consequent alternative)", .{});
    const test_value = try evalAt(ctx, arena, items[1], depth + 1, scope.inner());
    if (test_value.isTrue()) return evalAt(ctx, arena, items[2], depth + 1, scope.inner());
    if (items.len == 4) return evalAt(ctx, arena, items[3], depth + 1, scope.inner());
    return .unspecified_value;
}

/// `(lambda (name ...) body ...)` (R7RS 4.1.4). A procedure that remembers the
/// frame it was made in. A variable number of arguments is not supported yet:
/// `(lambda args ...)` is refused until the evaluator takes it, and
/// `(lambda (a . rest) ...)` also waits for the reader to read a dotted list.
fn evalLambda(ctx: *Context, arena: std.mem.Allocator, items: []const Value, scope: Scope) Error!Value {
    if (items.len < 3)
        return ctx.fail(error.BadSyntax, "bad lambda: expected (lambda (name ...) body ...)", .{});
    return makeClosure(ctx, arena, items[1], items[2..], scope, "lambda");
}

/// The procedure with the parameters `params` and the forms `body`, made in
/// `scope`. `form_name` is the form it was written as, for the messages:
/// `(define (f x) ...)` is a `define` with a parameter list of its own.
fn makeClosure(
    ctx: *Context,
    arena: std.mem.Allocator,
    params_form: Value,
    body: []const Value,
    scope: Scope,
    comptime form_name: []const u8,
) Error!Value {
    var params: std.ArrayList(SymbolId) = .empty;
    var rest = params_form;
    if (rest.kind() == .symbol) return ctx.fail(
        error.BadSyntax,
        "bad " ++ form_name ++ ": parameters must be a list of identifiers; a variable number of arguments is not supported yet",
        .{},
    );
    while (rest.asPair()) |p| : (rest = p.cdr) {
        const id = p.car.asSymbol() orelse
            return ctx.fail(error.BadSyntax, "bad " ++ form_name ++ ": a parameter must be an identifier", .{});
        const name = ctx.symbols.nameOf(id);
        if (Keyword.of(name) != null)
            return ctx.fail(error.BadSyntax, "bad " ++ form_name ++ ": {s} is a syntactic keyword and cannot be a parameter", .{name});
        for (params.items) |seen| {
            if (seen == id) return ctx.fail(error.BadSyntax, "bad " ++ form_name ++ ": duplicate parameter: {s}", .{name});
        }
        try params.append(arena, id);
    }
    if (rest.kind() != .empty_list)
        return ctx.fail(error.BadSyntax, "bad " ++ form_name ++ ": the parameters must be a list of identifiers", .{});
    const arity = params.items.len;
    const defines = try collectDefinitions(ctx, arena, body, &params);
    // Why: R7RS 5.3.2 gives a body definitions followed by expressions, and at
    // least one expression: a body that only defines has no value to return.
    if (defines == body.len)
        return ctx.fail(error.BadSyntax, "bad " ++ form_name ++ ": a body needs an expression after its definitions", .{});
    const closure = try ctx.persist.create(Closure);
    closure.* = .{
        .names = try ctx.persist.dupe(SymbolId, params.items),
        .arity = arity,
        .body = try ctx.persist.dupe(Value, body),
        .defines = defines,
        .env = scope.env,
    };
    return .fromClosure(closure);
}

/// Adds the names that the definitions at the start of `body` define to
/// `names`, and returns how many forms they are. A name that is already there,
/// as a parameter or an earlier definition, is an error. The definitions
/// themselves are checked when they run.
fn collectDefinitions(
    ctx: *Context,
    arena: std.mem.Allocator,
    body: []const Value,
    names: *std.ArrayList(SymbolId),
) Error!usize {
    var count: usize = 0;
    for (body) |form| {
        const head = form.asPair() orelse break;
        const keyword_id = head.car.asSymbol() orelse break;
        if (Keyword.of(ctx.symbols.nameOf(keyword_id)) != .define) break;
        const rest = head.cdr.asPair() orelse
            return ctx.fail(error.BadSyntax, "bad define: expected (define name expression)", .{});
        // `(define (name parameter ...) body ...)` names what its header starts with.
        const target = if (rest.car.asPair()) |header| header.car else rest.car;
        const id = target.asSymbol() orelse
            return ctx.fail(error.BadSyntax, "bad define: the name must be an identifier", .{});
        const name = ctx.symbols.nameOf(id);
        if (Keyword.of(name) != null)
            return ctx.fail(error.BadSyntax, "bad define: {s} is a syntactic keyword and cannot be redefined", .{name});
        for (names.items) |seen| {
            if (seen == id) return ctx.fail(
                error.BadSyntax,
                "bad define: {s} is already a parameter or defined earlier in this body",
                .{name},
            );
        }
        try names.append(arena, id);
        count += 1;
    }
    return count;
}

/// `(begin expression ...)` (R7RS 4.2.3). Evaluates its forms in order and
/// gives the value of the last. At the top level its forms are at the top level
/// too, so a definition in it is allowed (R7RS 5.3).
fn evalBegin(ctx: *Context, arena: std.mem.Allocator, items: []const Value, depth: usize, scope: Scope) Error!Value {
    if (items.len < 2)
        return ctx.fail(error.BadSyntax, "bad begin: expected (begin expression ...)", .{});
    for (items[1 .. items.len - 1]) |form| _ = try evalAt(ctx, arena, form, depth + 1, scope);
    return evalAt(ctx, arena, items[items.len - 1], depth + 1, scope);
}

/// `(set! name expression)` (R7RS 4.1.6). Changes the nearest binding of `name`,
/// local or global; it does not create one. Returns the unspecified value.
///
/// The expression is evaluated first, so a failing assignment changes nothing.
fn evalSet(ctx: *Context, arena: std.mem.Allocator, items: []const Value, depth: usize, scope: Scope) Error!Value {
    if (items.len != 3)
        return ctx.fail(error.BadSyntax, "bad set!: expected (set! name expression)", .{});
    const id = items[1].asSymbol() orelse
        return ctx.fail(error.BadSyntax, "bad set!: the name must be an identifier", .{});
    const name = ctx.symbols.nameOf(id);
    if (Keyword.of(name) != null)
        return ctx.fail(error.BadSyntax, "bad set!: {s} is a syntactic keyword and cannot be assigned", .{name});
    const value = try evalAt(ctx, arena, items[2], depth + 1, scope.inner());
    if (env.findLocal(scope.env, id)) |slot| {
        // Why: R7RS 5.3.2 binds a body's names as `letrec*` does, so assigning
        // one before its definition is as much an error as reading it.
        if (slot.kind() == .uninitialized)
            return ctx.fail(error.UninitializedVariable, "variable used before its definition: {s}", .{name});
        slot.* = value;
        return .unspecified_value;
    }
    if (!ctx.globals.assign(id, value))
        return ctx.fail(error.UnboundVariable, "unbound variable: {s}", .{name});
    return .unspecified_value;
}

/// `(define name expression)` (R7RS 5.3.1). At the top level it binds `name` in
/// the global environment, replacing an earlier binding. At the start of a body
/// it gives a value to the local variable that the body's definitions made when
/// the call began (R7RS 5.3.2). Either way it returns the unspecified value.
///
/// The expression is evaluated before the name is bound, so a failing
/// definition leaves the name as it was.
fn evalDefine(ctx: *Context, arena: std.mem.Allocator, items: []const Value, depth: usize, scope: Scope) Error!Value {
    // Why: R7RS 5.3 allows a definition at the top level and at the start of a
    // body. Anything else would bind a name from inside an expression that may
    // go on to fail.
    if (scope.pos == .expression)
        return ctx.fail(error.BadSyntax, "bad define: a definition is only allowed at the top level or at the start of a body", .{});
    // `(define (name parameter ...) body ...)` is `(define name (lambda
    // (parameter ...) body ...))` (R7RS 5.3.1).
    const shorthand = items.len >= 2 and items[1].kind() == .pair;
    if (shorthand and items.len < 3)
        return ctx.fail(error.BadSyntax, "bad define: expected (define (name parameter ...) body ...)", .{});
    if (!shorthand and items.len != 3)
        return ctx.fail(error.BadSyntax, "bad define: expected (define name expression)", .{});
    const target = if (shorthand) items[1].asPair().?.car else items[1];
    const id = target.asSymbol() orelse
        return ctx.fail(error.BadSyntax, "bad define: the name must be an identifier", .{});
    const name = ctx.symbols.nameOf(id);
    if (Keyword.of(name) != null)
        return ctx.fail(error.BadSyntax, "bad define: {s} is a syntactic keyword and cannot be redefined", .{name});
    const value = if (shorthand)
        try makeClosure(ctx, arena, items[1].asPair().?.cdr, items[2..], scope, "define")
    else
        try evalAt(ctx, arena, items[2], depth + 1, scope.inner());
    switch (scope.pos) {
        .top => try ctx.globals.define(ctx.persist, id, value),
        // `collectDefinitions` made the variable when the closure was made, and
        // the frame being evaluated in is the call's own, so it is the nearest.
        .body => env.findLocal(scope.env, id).?.* = value,
        .expression => unreachable,
    }
    return .unspecified_value;
}

test {
    std.testing.refAllDecls(@This());
}

fn evalSource(arena: std.mem.Allocator, src: []const u8) Error!i64 {
    var ctx = try Context.init(arena);
    return (try evalWith(&ctx, arena, src)).asFixnum().?;
}

/// Reads the first datum of `src` into `ctx`'s symbols and allocator, and
/// evaluates it.
fn evalWith(ctx: *Context, arena: std.mem.Allocator, src: []const u8) Error!Value {
    var r: @import("reader.zig").Reader = .init(src);
    const form = (r.next(arena, .{ .alloc = ctx.persist, .symbols = &ctx.symbols }) catch unreachable).?;
    return eval(ctx, arena, form);
}

test "eval returns an integer as itself and applies +" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqual(42, try evalSource(a, "42"));
    try std.testing.expectEqual(3, try evalSource(a, "(+ 1 2)"));
    try std.testing.expectEqual(10, try evalSource(a, "(+ (+ 1 2) (+ 3 4))"));
    try std.testing.expectEqual(0, try evalSource(a, "(+)"));
}

test "a primitive is a value that a variable can name" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = try Context.init(a);
    const plus = try evalWith(&ctx, a, "+");
    try std.testing.expectEqualStrings("+", plus.asPrimitive().?.name);
    _ = try evalWith(&ctx, a, "(define plus +)");
    try std.testing.expectEqual(plus.asPrimitive().?, (try evalWith(&ctx, a, "plus")).asPrimitive().?);
    // Rebinding the name hides the primitive; the primitive itself is untouched.
    _ = try evalWith(&ctx, a, "(define + 5)");
    try std.testing.expectError(error.NotAProcedure, evalWith(&ctx, a, "(+ 1 2)"));
    try std.testing.expectEqual(3, (try evalWith(&ctx, a, "(plus 1 2)")).asFixnum().?);
}

test "eval reports what it cannot evaluate" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectError(error.EmptyCombination, evalSource(a, "()"));
    try std.testing.expectError(error.UnboundVariable, evalSource(a, "(foo 1)"));
    try std.testing.expectError(error.UnboundVariable, evalSource(a, "foo"));
    try std.testing.expectError(error.NotAProcedure, evalSource(a, "(1 2)"));
    // The operator's own error comes first.
    try std.testing.expectError(error.EmptyCombination, evalSource(a, "(() 2)"));
    try std.testing.expectError(error.IntegerOverflow, evalSource(a, "(+ 9223372036854775807 1)"));
}

/// `(+ (+ ... (+ 1)))` with `calls` calls: the innermost `1` is evaluated at
/// depth `calls`.
fn nestedCalls(a: std.mem.Allocator, calls: usize) ![]const u8 {
    const src = try a.alloc(u8, calls * 3 + 1 + calls);
    for (0..calls) |k| @memcpy(src[k * 3 ..][0..3], "(+ ");
    src[calls * 3] = '1';
    @memset(src[calls * 3 + 1 ..], ')');
    return src;
}

test "eval returns a boolean as itself, and quote returns its datum unevaluated" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = try Context.init(a);
    try std.testing.expectEqual(.boolean, (try evalWith(&ctx, a, "#f")).kind());
    try std.testing.expect(!(try evalWith(&ctx, a, "#f")).isTrue());
    try std.testing.expect((try evalWith(&ctx, a, "#t")).isTrue());
    const sym = try evalWith(&ctx, a, "'foo");
    try std.testing.expectEqualStrings("foo", ctx.symbols.nameOf(sym.asSymbol().?));
    // The datum is not evaluated: neither a call nor an unbound name fails.
    const call = try evalWith(&ctx, a, "(quote (+ 1 2))");
    try std.testing.expectEqual(.pair, call.kind());
    try std.testing.expectEqual(.empty_list, (try evalWith(&ctx, a, "'()")).kind());
    // Quoting twice reads the same symbol: eq?-ness of symbols is id equality.
    try std.testing.expectEqual(sym.asSymbol().?, (try evalWith(&ctx, a, "(quote foo)")).asSymbol().?);
}

test "quote returns the very datum it was read with, not a copy" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = try Context.init(a);
    _ = try evalWith(&ctx, a, "(define x '(1 2))");
    const first = try evalWith(&ctx, a, "x");
    const second = try evalWith(&ctx, a, "x");
    try std.testing.expectEqual(first.asPair().?, second.asPair().?);
}

test "eval rejects a quote or define of the wrong shape, and keywords as variables" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = try Context.init(a);
    try std.testing.expectError(error.BadSyntax, evalWith(&ctx, a, "(quote)"));
    try std.testing.expectEqualStrings("bad quote: expected (quote datum)", ctx.diagnostic());
    try std.testing.expectError(error.BadSyntax, evalWith(&ctx, a, "(quote 1 2)"));
    try std.testing.expectError(error.BadSyntax, evalWith(&ctx, a, "quote"));
    try std.testing.expectError(error.BadSyntax, evalWith(&ctx, a, "(define quote 1)"));
    try std.testing.expectEqualStrings("bad define: quote is a syntactic keyword and cannot be redefined", ctx.diagnostic());
    try std.testing.expectError(error.BadSyntax, evalWith(&ctx, a, "(define #t 1)"));
    try std.testing.expectEqualStrings("bad define: the name must be an identifier", ctx.diagnostic());
}

test "eval refuses a form that is not a proper list" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = try Context.init(a);
    // The reader cannot write a dotted list, so build (+ 1 . 2) by hand.
    const tail = try Value.cons(a, .fromFixnum(1), .fromFixnum(2));
    const plus: Value = .fromSymbol(try ctx.symbols.intern(a, "+"));
    const form = try Value.cons(a, plus, tail);
    try std.testing.expectError(error.BadSyntax, eval(&ctx, a, form));
    try std.testing.expectEqualStrings("bad syntax: a form must be a proper list", ctx.diagnostic());
}

test "eval leaves the message of an error in the context" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = try Context.init(a);
    try std.testing.expectError(error.UnboundVariable, evalWith(&ctx, a, "(+ 1 foo)"));
    try std.testing.expectEqualStrings("unbound variable: foo", ctx.diagnostic());
    try std.testing.expectError(error.IntegerOverflow, evalWith(&ctx, a, "(+ 9223372036854775807 1)"));
    try std.testing.expectEqualStrings("integer overflow in +", ctx.diagnostic());
    ctx.clearDiagnostic();
    try std.testing.expectEqualStrings("", ctx.diagnostic());
}

test "eval cuts a message longer than its buffer instead of dropping it" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const name = try a.alloc(u8, 1000);
    @memset(name, 'x');
    var ctx = try Context.init(a);
    try std.testing.expectError(error.UnboundVariable, evalWith(&ctx, a, name));
    try std.testing.expect(std.mem.startsWith(u8, ctx.diagnostic(), "unbound variable: xxx"));
    try std.testing.expectEqual(ctx.message_buf.len, ctx.diagnostic().len);
}

test "eval reports a nesting it cannot recurse into instead of overflowing" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectError(error.NestingTooDeep, evalSource(a, try nestedCalls(a, max_depth)));
}

/// `(define x (+ (+ ... 1)))`: the expression is evaluated one level below the
/// definition, so its innermost `1` is at depth `calls + 1`.
fn definitionOfNestedCalls(a: std.mem.Allocator, calls: usize) ![]const u8 {
    return std.mem.concat(a, u8, &.{ "(define x ", try nestedCalls(a, calls), ")" });
}

/// `((( ... 1)))` with `parens` opening parentheses: each operator is evaluated
/// one level below its call, so the `1` is at depth `parens`, and the innermost
/// call is the one that fails, as `NotAProcedure`.
fn nestedOperators(a: std.mem.Allocator, parens: usize) ![]const u8 {
    const src = try a.alloc(u8, parens * 2 + 1);
    @memset(src[0..parens], '(');
    src[parens] = '1';
    @memset(src[parens + 1 ..], ')');
    return src;
}

/// `prefix` repeated `n` times, `core`, then `suffix` repeated `n` times.
fn wrapped(a: std.mem.Allocator, n: usize, prefix: []const u8, core: []const u8, suffix: []const u8) ![]const u8 {
    const src = try a.alloc(u8, n * (prefix.len + suffix.len) + core.len);
    for (0..n) |k| @memcpy(src[k * prefix.len ..][0..prefix.len], prefix);
    @memcpy(src[n * prefix.len ..][0..core.len], core);
    for (0..n) |k| @memcpy(src[n * prefix.len + core.len + k * suffix.len ..][0..suffix.len], suffix);
    return src;
}

/// Places where a form evaluates a subform, each nested `n` deep. The innermost
/// `1`, `#t`, `2` or `x` is evaluated at depth `n`, and evaluating the whole
/// succeeds. One shape per call site of `evalAt`, because a call site that
/// forgets to count a level is not caught by the tests of another.
const shapes = [_]struct { name: []const u8, prefix: []const u8, core: []const u8, suffix: []const u8 }{
    .{ .name = "if test", .prefix = "(if ", .core = "#t", .suffix = " 1 2)" },
    .{ .name = "if consequent", .prefix = "(if #t ", .core = "1", .suffix = ")" },
    .{ .name = "if alternative", .prefix = "(if #f 1 ", .core = "2", .suffix = ")" },
    .{ .name = "lambda body", .prefix = "((lambda (x) ", .core = "x", .suffix = ") 1)" },
    .{ .name = "begin last form", .prefix = "(begin 1 ", .core = "1", .suffix = ")" },
    .{ .name = "begin first form", .prefix = "(begin ", .core = "1", .suffix = " 1)" },
    .{ .name = "lambda body before the last form", .prefix = "((lambda (x) ", .core = "1", .suffix = " x) 1)" },
};

test "eval stops each subform at the limit, and not one level later" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for (shapes) |sh| {
        var ctx = try Context.init(a);
        evalAtDepth(&ctx, a, try wrapped(a, max_depth - 1, sh.prefix, sh.core, sh.suffix)) catch |e| {
            std.debug.print("{s}: the deepest legal input failed with {t}\n", .{ sh.name, e });
            return error.TestUnexpectedResult;
        };
        evalAtDepth(&ctx, a, try wrapped(a, max_depth, sh.prefix, sh.core, sh.suffix)) catch |e| {
            try std.testing.expectEqual(error.NestingTooDeep, e);
            continue;
        };
        std.debug.print("{s}: one level past the limit was accepted\n", .{sh.name});
        return error.TestUnexpectedResult;
    }
}

fn evalAtDepth(ctx: *Context, a: std.mem.Allocator, src: []const u8) Error!void {
    _ = try evalWith(ctx, a, src);
}

test "eval stops the value of a set! at the limit, and not one level later" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = try Context.init(a);
    _ = try evalWith(&ctx, a, "(define x 0)");
    _ = try evalWith(&ctx, a, try wrapped(a, max_depth - 1, "(set! x ", "1", ")"));
    try std.testing.expectError(error.NestingTooDeep, evalWith(&ctx, a, try wrapped(a, max_depth, "(set! x ", "1", ")")));
}

test "eval stops a definition's expression at the limit, and not one level later" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = try Context.init(a);
    _ = try evalWith(&ctx, a, try definitionOfNestedCalls(a, max_depth - 2));
    try std.testing.expectError(error.NestingTooDeep, evalWith(&ctx, a, try definitionOfNestedCalls(a, max_depth - 1)));
}

test "eval stops an operator that nests at the limit, and not one level later" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectError(error.NotAProcedure, evalSource(a, try nestedOperators(a, max_depth - 1)));
    try std.testing.expectError(error.NestingTooDeep, evalSource(a, try nestedOperators(a, max_depth)));
}

/// The stack the deepest legal evaluation must fit in. Half of the smallest
/// stack a host is assumed to give (1 MiB), so a Debug build that grows a level
/// by a few percent still fits and one that doubles it does not.
const probe_stack_size = 512 * 1024;

/// Evaluates `src` on a thread whose stack is `probe_stack_size`, and reports
/// what it returned. A stack overflow ends the process, so a limit that is too
/// high shows as a crashed test run and not as an error.
fn evalOnSmallStack(src: []const u8) !?Error {
    const Probe = struct {
        src: []const u8,
        outcome: ?Error = null,

        fn run(self: *@This()) void {
            var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
            defer arena.deinit();
            var ctx = Context.init(arena.allocator()) catch {
                self.outcome = error.OutOfMemory;
                return;
            };
            if (evalWith(&ctx, arena.allocator(), self.src)) |_| {} else |e| self.outcome = e;
        }
    };
    var probe: Probe = .{ .src = src };
    const t = try std.Thread.spawn(.{ .stack_size = probe_stack_size }, Probe.run, .{&probe});
    t.join();
    return probe.outcome;
}

test "the deepest legal evaluation of each form fits a stack half the size of 1 MiB" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqual(null, try evalOnSmallStack(try nestedCalls(a, max_depth - 1)));
    try std.testing.expectEqual(null, try evalOnSmallStack(try definitionOfNestedCalls(a, max_depth - 2)));
    try std.testing.expectEqual(error.NotAProcedure, (try evalOnSmallStack(try nestedOperators(a, max_depth - 1))).?);
    for (shapes) |sh|
        try std.testing.expectEqual(null, try evalOnSmallStack(try wrapped(a, max_depth - 1, sh.prefix, sh.core, sh.suffix)));
    // A set! chain needs a bound variable, so it runs in a lambda body. Its
    // innermost `1` is one level below the call, plus the depth of the chain.
    const set_chain = try std.mem.concat(a, u8, &.{
        "((lambda (x) ", try wrapped(a, max_depth - 2, "(set! x ", "1", ")"), ") 0)",
    });
    try std.testing.expectEqual(null, try evalOnSmallStack(set_chain));
    // Past the limit it is reported, on the same small stack.
    try std.testing.expectEqual(error.NestingTooDeep, (try evalOnSmallStack(try nestedCalls(a, max_depth + 50))).?);
}

test "eval handles the deepest nesting the limit allows" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqual(1, try evalSource(a, try nestedCalls(a, max_depth - 1)));
}

test "a body's definitions are local to the call and do not reach the globals" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = try Context.init(a);
    _ = try evalWith(&ctx, a, "(define (f x) (define y (+ x 1)) (define (g) (* y 2)) (g))");
    try std.testing.expectEqual(8, (try evalWith(&ctx, a, "(f 3)")).asFixnum().?);
    try std.testing.expectError(error.UnboundVariable, evalWith(&ctx, a, "y"));
    try std.testing.expectError(error.UnboundVariable, evalWith(&ctx, a, "g"));
}

test "a call gets a frame of its own for the names its body defines" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = try Context.init(a);
    _ = try evalWith(&ctx, a, "(define (f n) (define cell n) (set! cell (+ cell 1)) cell)");
    try std.testing.expectEqual(2, (try evalWith(&ctx, a, "(f 1)")).asFixnum().?);
    try std.testing.expectEqual(11, (try evalWith(&ctx, a, "(f 10)")).asFixnum().?);
}

test "a variable read before its definition is an error that names it" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = try Context.init(a);
    try std.testing.expectError(error.UninitializedVariable, evalWith(&ctx, a, "((lambda () (define a b) (define b 1) a))"));
    try std.testing.expectEqualStrings("variable used before its definition: b", ctx.diagnostic());
    // A definition that fails leaves the name uninitialized, not defined.
    try std.testing.expectError(error.UninitializedVariable, evalWith(&ctx, a, "((lambda () (define a a) a))"));
}

test "a body that only defines is refused, and a definition after an expression is too" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = try Context.init(a);
    try std.testing.expectError(error.BadSyntax, evalWith(&ctx, a, "(lambda () (define a 1))"));
    try std.testing.expectEqualStrings("bad lambda: a body needs an expression after its definitions", ctx.diagnostic());
    try std.testing.expectError(error.BadSyntax, evalWith(&ctx, a, "((lambda () 0 (define a 1) a))"));
    try std.testing.expectError(error.BadSyntax, evalWith(&ctx, a, "(lambda (x) (define x 1) x)"));
    try std.testing.expectEqualStrings("bad define: x is already a parameter or defined earlier in this body", ctx.diagnostic());
}
