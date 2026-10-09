//! The expander: data in, core IR out.
//!
//! Slice 1f has the six special forms and no macros, so this is a translation
//! of `quote`, `if`, `lambda`, `set!`, `define` and `begin`, and of calls. What
//! stage 2 adds (syntactic bindings, `syntax-rules`) replaces `Keyword` with a
//! syntactic environment; docs/design/frontend.md describes where it goes.
//!
//! The expander resolves every variable. A name that a `lambda` binds becomes a
//! lexical address (how many frames out, which slot), and any other name is a
//! global one, found by name when the machine runs it.
//!
//! The work is kept on a stack of its own and never recurses, so a program
//! nested as deep as the reader can read it does not overflow the Zig stack
//! (docs/design/frontend.md).

const std = @import("std");
const value_mod = @import("../value.zig");
const Value = value_mod.Value;
const Node = value_mod.Node;
const SymbolId = @import("../symbol.zig").SymbolId;
const symbol = @import("../symbol.zig");
const Context = @import("../context.zig").Context;
const core = @import("../core.zig");

pub const Error = error{
    OutOfMemory,
    /// `()` is not an expression (R7RS 4.1.3 requires an operator).
    EmptyCombination,
    /// A form whose shape the expander rejects, such as `(define)`.
    BadSyntax,
    /// A program the representation cannot hold, which R7RS 1.3.2 lets an
    /// implementation report.
    ImplementationRestriction,
};

/// What the representation of a lexical address holds. The default is the width
/// of the address; a test passes a smaller figure to reach the limit.
pub const Limits = struct {
    address: u32 = std.math.maxInt(u32),
};

/// Expands `form`, which is at the top level of a program. The node and what it
/// refers to are allocated in `ctx.persist`; what the expansion needs only while
/// it runs comes from `scratch`. On an error `ctx` holds the message.
pub fn expand(ctx: *Context, scratch: std.mem.Allocator, form: Value) Error!*const Node {
    return expandWith(ctx, scratch, form, .{});
}

pub fn expandWith(ctx: *Context, scratch: std.mem.Allocator, form: Value, limits: Limits) Error!*const Node {
    _ = scratch;
    _ = form;
    _ = limits;
    return ctx.fail(error.BadSyntax, "not implemented", .{});
}

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
        self.ctx = try .init(self.arena.allocator());
    }

    fn deinit(self: *Fixture) void {
        self.arena.deinit();
    }

    /// The first datum of `src`.
    fn read(self: *Fixture, src: []const u8) !Value {
        var r: @import("../reader.zig").Reader = .init(src);
        const sink: @import("../reader.zig").Sink = .{ .alloc = self.ctx.persist, .symbols = &self.ctx.symbols };
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

    fn expectFails(self: *Fixture, src: []const u8, err: Error, message: []const u8) !void {
        try std.testing.expectError(err, self.expandText(src, .{}));
        try std.testing.expectEqualStrings(message, self.ctx.diagnostic());
    }
};

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
    // A form inside a quote is data, so it is not read as a call.
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
    // The nearer binding hides the farther one, and a local hides a global.
    try f.expectExpands("(lambda (x) (lambda (x) x))", "(lambda 1 1 (lambda 1 1 (local x 0 0)))");
    try f.expectExpands("(lambda (+) +)", "(lambda 1 1 (local + 0 0))");
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
    // At the top level its forms are at the top level too (R7RS 5.3).
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
    // A name defined later is already visible to a procedure defined earlier.
    try f.expectExpands(
        "(lambda () (define (even? n) (odd? n)) (define (odd? n) n) 1)",
        "(lambda 0 2 (seq (define-local even? 0 0 (lambda 1 1 (call (local odd? 1 1) (local n 0 0)))) (define-local odd? 0 1 (lambda 1 1 (local n 0 0))) (const 1)))",
    );
    // A definition after an expression makes no variable: the name stays global.
    try f.expectFails(
        "(lambda () (+ a 1) (define a 1) a)",
        error.BadSyntax,
        "bad define: a definition is only allowed at the top level or at the start of a body",
    );
}

test "the shapes the expander refuses, with the messages the evaluator gave" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.expectFails("()", error.EmptyCombination, "empty combination");
    try f.expectFails("(quote)", error.BadSyntax, "bad quote: expected (quote datum)");
    try f.expectFails("(quote 1 2)", error.BadSyntax, "bad quote: expected (quote datum)");
    try f.expectFails("(if 1)", error.BadSyntax, "bad if: expected (if test consequent) or (if test consequent alternative)");
    try f.expectFails("(lambda)", error.BadSyntax, "bad lambda: expected (lambda (name ...) body ...)");
    try f.expectFails("(lambda (x))", error.BadSyntax, "bad lambda: expected (lambda (name ...) body ...)");
    try f.expectFails("(lambda (x x) x)", error.BadSyntax, "bad lambda: duplicate parameter: x");
    try f.expectFails("(lambda (if) 1)", error.BadSyntax, "bad lambda: if is a syntactic keyword and cannot be a parameter");
    try f.expectFails("(lambda (1) 1)", error.BadSyntax, "bad lambda: a parameter must be an identifier");
    try f.expectFails("(lambda x 1)", error.BadSyntax, "bad lambda: parameters must be a list of identifiers; a variable number of arguments is not supported yet");
    try f.expectFails("(set! x)", error.BadSyntax, "bad set!: expected (set! name expression)");
    try f.expectFails("(set! 1 2)", error.BadSyntax, "bad set!: the name must be an identifier");
    try f.expectFails("(set! if 1)", error.BadSyntax, "bad set!: if is a syntactic keyword and cannot be assigned");
    try f.expectFails("(begin)", error.BadSyntax, "bad begin: expected (begin expression ...)");
    try f.expectFails("if", error.BadSyntax, "if is a syntactic keyword and cannot be used as a variable");
    try f.expectFails("(define)", error.BadSyntax, "bad define: expected (define name expression)");
    try f.expectFails("(define x)", error.BadSyntax, "bad define: expected (define name expression)");
    try f.expectFails("(define 1 2)", error.BadSyntax, "bad define: the name must be an identifier");
    try f.expectFails("(define if 1)", error.BadSyntax, "bad define: if is a syntactic keyword and cannot be redefined");
    try f.expectFails("(define (f))", error.BadSyntax, "bad define: expected (define (name parameter ...) body ...)");
    try f.expectFails("(+ 1 (define x 1))", error.BadSyntax, "bad define: a definition is only allowed at the top level or at the start of a body");
    try f.expectFails("(if (define x 1) 2)", error.BadSyntax, "bad define: a definition is only allowed at the top level or at the start of a body");
}

test "the shapes a body refuses" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.expectFails("(lambda () (define x 1))", error.BadSyntax, "bad lambda: a body needs an expression after its definitions");
    try f.expectFails("(define (f) (define x 1))", error.BadSyntax, "bad define: a body needs an expression after its definitions");
    try f.expectFails("(lambda (x) (define x 1) x)", error.BadSyntax, "bad define: x is already a parameter or defined earlier in this body");
    try f.expectFails("(lambda () (define x 1) (define x 2) x)", error.BadSyntax, "bad define: x is already a parameter or defined earlier in this body");
    try f.expectFails("(lambda () (define if 1) 1)", error.BadSyntax, "bad define: if is a syntactic keyword and cannot be redefined");
    try f.expectFails("(lambda () (begin (define x 1)) x)", error.BadSyntax, "bad define: a definition is only allowed at the top level or at the start of a body");
}

test "an address that does not fit the width is reported, and one that just fits is not" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const limits: Limits = .{ .address = 1 };
    // Depth 1 is the last that fits.
    try std.testing.expectEqualStrings(
        "(lambda 1 1 (lambda 1 1 (local a 1 0)))",
        try f.expandText("(lambda (a) (lambda (b) a))", limits),
    );
    try std.testing.expectError(error.ImplementationRestriction, f.expandText("(lambda (a) (lambda (b) (lambda (c) a)))", limits));
    try std.testing.expectEqualStrings("implementation restriction: procedures are nested too deeply", f.ctx.diagnostic());
    // A frame of one slot is the last that fits, and two do not.
    try std.testing.expectEqualStrings("(lambda 1 1 (local a 0 0))", try f.expandText("(lambda (a) a)", limits));
    try std.testing.expectError(error.ImplementationRestriction, f.expandText("(lambda (a b) a)", limits));
    try std.testing.expectEqualStrings("implementation restriction: a procedure has too many variables", f.ctx.diagnostic());
    try std.testing.expectError(error.ImplementationRestriction, f.expandText("(lambda (a) (define b 1) a)", limits));
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
