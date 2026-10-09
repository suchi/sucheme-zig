//! Evaluates a datum.
//!
//! A plain recursive evaluator, as docs/plans/0003-phase1-minimal-slice.md
//! decides for slices 1a to 1e. Slice 1f replaces it with the CEK machine in
//! machine.zig, which is the only place docs/design/architecture.md lets
//! evaluation advance. That document records this file as a provisional
//! exception until then.
//!
//! Slice 1b evaluates integers, global variables, `define`, and calls to a
//! primitive or a variable in the operator position. Procedure values and
//! `lambda` arrive in slice 1d; until then no variable holds a procedure, and a
//! Scheme error is a Zig error with a message in `Context`.

const std = @import("std");
const Value = @import("value.zig").Value;
const Datum = @import("reader.zig").Datum;
const arith = @import("prim/arith.zig");
const symbol = @import("symbol.zig");
const env = @import("env.zig");

pub const Error = arith.Error || error{
    OutOfMemory,
    /// `()` is not an expression (R7RS 4.1.3 requires an operator).
    EmptyCombination,
    /// An identifier naming nothing.
    UnboundVariable,
    /// A primitive named outside the operator position. There are no procedure
    /// values to give it until slice 1d.
    VariableReferenceUnsupported,
    /// A form whose shape the evaluator rejects, such as `(define)`.
    BadSyntax,
    /// The operator is not a procedure.
    NotAProcedure,
    /// The expression nests deeper than `max_depth`.
    NestingTooDeep,
};

/// What `eval` carries between calls: the symbols and global bindings that
/// outlive a line, and the message for the most recent error.
///
/// A Zig error carries no payload, so the message that names the offending
/// identifier lives here, and the caller reads it with `diagnostic` after an
/// error. Slice 1f replaces the message with condition objects.
pub const Context = struct {
    /// Where symbols and global bindings are allocated. Slice 1g replaces it
    /// with the GC heap.
    persist: std.mem.Allocator,
    symbols: symbol.Table = .{},
    globals: env.Global = .{},
    message_buf: [256]u8 = undefined,
    message_len: usize = 0,

    pub fn init(persist: std.mem.Allocator) Context {
        return .{ .persist = persist };
    }

    /// The message for the most recent error, or empty when none was set.
    /// Valid until the next call that fails or `clearDiagnostic`.
    pub fn diagnostic(self: *const Context) []const u8 {
        return self.message_buf[0..self.message_len];
    }

    pub fn clearDiagnostic(self: *Context) void {
        self.message_len = 0;
    }

    pub fn setDiagnostic(self: *Context, message: []const u8) void {
        const n = @min(message.len, self.message_buf.len);
        @memcpy(self.message_buf[0..n], message[0..n]);
        self.message_len = n;
    }

    /// Records the message and returns `err`, so a call site reads
    /// `return ctx.fail(error.X, "...", .{})`. A message longer than the buffer
    /// is cut, not dropped: an identifier can be as long as the REPL's line.
    fn fail(self: *Context, err: Error, comptime fmt: []const u8, args: anytype) Error {
        var w: std.Io.Writer = .fixed(&self.message_buf);
        w.print(fmt, args) catch {};
        self.message_len = w.buffered().len;
        return err;
    }
};

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
pub const max_depth = 200;

/// Evaluates `d`. Temporary storage, such as the evaluated arguments, comes
/// from `arena`. On an error `ctx` holds the message.
pub fn eval(ctx: *Context, arena: std.mem.Allocator, d: Datum) Error!Value {
    return evalAt(ctx, arena, d, 0);
}

/// The one special form of slice 1b. A keyword cannot be shadowed or used as a
/// variable; the expander of stage 2 replaces this check with syntactic
/// bindings.
const define_keyword = "define";

fn evalAt(ctx: *Context, arena: std.mem.Allocator, d: Datum, depth: usize) Error!Value {
    if (depth >= max_depth) return ctx.fail(error.NestingTooDeep, "nesting too deep", .{});
    switch (d) {
        .integer => |n| return .fromFixnum(n),
        .identifier => |name| {
            if (std.mem.eql(u8, name, define_keyword))
                return ctx.fail(error.BadSyntax, "{s} is a syntactic keyword and cannot be used as a variable", .{name});
            if (lookupGlobal(ctx, name)) |v| return v;
            if (arith.lookup(name) != null)
                return ctx.fail(error.VariableReferenceUnsupported, "procedure values are not supported yet: {s}", .{name});
            return ctx.fail(error.UnboundVariable, "unbound variable: {s}", .{name});
        },
        .list => |items| {
            if (items.len == 0) return ctx.fail(error.EmptyCombination, "empty combination", .{});
            switch (items[0]) {
                .identifier => |name| {
                    if (std.mem.eql(u8, name, define_keyword)) return evalDefine(ctx, arena, items, depth);
                    // A definition shadows a primitive of the same name. Nothing
                    // a variable can hold is a procedure yet, so a bound
                    // operator is an error.
                    if (lookupGlobal(ctx, name) != null)
                        return ctx.fail(error.NotAProcedure, "not a procedure", .{});
                    const prim = arith.lookup(name) orelse
                        return ctx.fail(error.UnboundVariable, "unbound variable: {s}", .{name});
                    return applyPrimitive(ctx, arena, prim, items[1..], depth);
                },
                else => {
                    // Evaluated for its errors; no value is a procedure yet.
                    _ = try evalAt(ctx, arena, items[0], depth + 1);
                    return ctx.fail(error.NotAProcedure, "not a procedure", .{});
                },
            }
        },
    }
}

/// The value of the global variable `name`, or null when it is unbound. Looking
/// up a name nobody defined does not intern it.
fn lookupGlobal(ctx: *Context, name: []const u8) ?Value {
    const id = ctx.symbols.find(name) orelse return null;
    return ctx.globals.lookup(id);
}

fn applyPrimitive(
    ctx: *Context,
    arena: std.mem.Allocator,
    prim: *const arith.Primitive,
    operands: []const Datum,
    depth: usize,
) Error!Value {
    const args = try arena.alloc(Value, operands.len);
    for (operands, args) |operand, *arg| arg.* = try evalAt(ctx, arena, operand, depth + 1);
    return prim.call(args) catch |e| switch (e) {
        error.WrongType => ctx.fail(e, "wrong type of argument to {s}", .{prim.name}),
        error.IntegerOverflow => ctx.fail(e, "integer overflow in {s}", .{prim.name}),
    };
}

/// `(define name expression)` (R7RS 5.3.2). Binds `name` in the global
/// environment, replacing an earlier binding, and returns the unspecified value.
///
/// The expression is evaluated before the name is bound, so a failing
/// definition leaves the name as it was.
fn evalDefine(ctx: *Context, arena: std.mem.Allocator, items: []const Datum, depth: usize) Error!Value {
    if (items.len != 3)
        return ctx.fail(error.BadSyntax, "bad define: expected (define name expression)", .{});
    const name = switch (items[1]) {
        .identifier => |n| n,
        .list => return ctx.fail(error.BadSyntax, "bad define: procedure definitions are not supported yet", .{}),
        .integer => return ctx.fail(error.BadSyntax, "bad define: the name must be an identifier", .{}),
    };
    if (std.mem.eql(u8, name, define_keyword))
        return ctx.fail(error.BadSyntax, "bad define: {s} is a syntactic keyword and cannot be redefined", .{name});
    const value = try evalAt(ctx, arena, items[2], depth + 1);
    const id = try ctx.symbols.intern(ctx.persist, name);
    try ctx.globals.define(ctx.persist, id, value);
    return .unspecified_value;
}

test {
    std.testing.refAllDecls(@This());
}

fn evalSource(arena: std.mem.Allocator, src: []const u8) Error!i64 {
    var ctx: Context = .init(arena);
    return (try evalWith(&ctx, arena, src)).asFixnum().?;
}

fn evalWith(ctx: *Context, arena: std.mem.Allocator, src: []const u8) Error!Value {
    var r: @import("reader.zig").Reader = .init(src);
    const d = (r.next(arena) catch unreachable).?;
    return eval(ctx, arena, d);
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

test "eval reports what it cannot evaluate" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectError(error.EmptyCombination, evalSource(a, "()"));
    try std.testing.expectError(error.UnboundVariable, evalSource(a, "(foo 1)"));
    try std.testing.expectError(error.UnboundVariable, evalSource(a, "foo"));
    try std.testing.expectError(error.VariableReferenceUnsupported, evalSource(a, "+"));
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

test "eval leaves the message of an error in the context" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx: Context = .init(a);
    try std.testing.expectError(error.UnboundVariable, evalWith(&ctx, a, "(+ 1 foo)"));
    try std.testing.expectEqualStrings("unbound variable: foo", ctx.diagnostic());
    try std.testing.expectError(error.IntegerOverflow, evalWith(&ctx, a, "(+ 9223372036854775807 1)"));
    try std.testing.expectEqualStrings("integer overflow in +", ctx.diagnostic());
    ctx.clearDiagnostic();
    try std.testing.expectEqualStrings("", ctx.diagnostic());
}

test "a reference to an unbound name does not intern it, and a definition does" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx: Context = .init(a);
    try std.testing.expectError(error.UnboundVariable, evalWith(&ctx, a, "nope"));
    try std.testing.expectError(error.UnboundVariable, evalWith(&ctx, a, "(nope 1)"));
    try std.testing.expectEqual(0, ctx.symbols.names.items.len);
    _ = try evalWith(&ctx, a, "(define yes 1)");
    try std.testing.expectEqual(1, ctx.symbols.names.items.len);
    try std.testing.expectEqualStrings("yes", ctx.symbols.nameOf(ctx.symbols.find("yes").?));
}

test "eval cuts a message longer than its buffer instead of dropping it" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const name = try a.alloc(u8, 1000);
    @memset(name, 'x');
    var ctx: Context = .init(a);
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

test "eval stops a definition's expression at the limit, and not one level later" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx: Context = .init(a);
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
            var ctx: Context = .init(arena.allocator());
            var reader: @import("reader.zig").Reader = .init(self.src);
            const d = (reader.next(arena.allocator()) catch unreachable).?;
            if (eval(&ctx, arena.allocator(), d)) |_| {} else |e| self.outcome = e;
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
    // Past the limit it is reported, on the same small stack.
    try std.testing.expectEqual(error.NestingTooDeep, (try evalOnSmallStack(try nestedCalls(a, max_depth + 50))).?);
}

test "eval handles the deepest nesting the limit allows" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqual(1, try evalSource(a, try nestedCalls(a, max_depth - 1)));
}
