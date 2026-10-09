//! The CEK machine: the only place evaluation advances
//! (docs/design/architecture.md, ADR-0004).
//!
//! Four registers: the node to run (control), the frame of the procedure being
//! run (environment), the chain of frames that say what to do with a value
//! (continuation), and the value just produced. A step either takes the node in
//! control apart, or hands the value to the top frame of the continuation, so
//! nothing here recurses on Zig's stack and a program can be as deep as memory.
//!
//! Frames of the continuation are never changed once made. A call in tail
//! position needs no frame: a procedure's body runs under the continuation of
//! its caller, and the last node of a sequence, and either branch of an `if`,
//! run after their own frame is gone.

const std = @import("std");
const value_mod = @import("value.zig");
const Value = value_mod.Value;
const Node = value_mod.Node;
const Context = @import("context.zig").Context;
const arith = @import("prim/arith.zig");

pub const Error = arith.Error || error{
    OutOfMemory,
    /// An identifier naming nothing.
    UnboundVariable,
    /// A call with a number of arguments the procedure does not take.
    WrongArgumentCount,
    /// A local variable read before its definition has run.
    UninitializedVariable,
    /// The operator is not a procedure.
    NotAProcedure,
};

pub const Machine = struct {
    ctx: *Context,
    /// What a step needs only while it runs, such as the arguments of a call.
    scratch: std.mem.Allocator,
    /// The most frames the continuation has held since the machine was made or
    /// the figure was reset. A call in tail position adds none, so a loop that
    /// calls itself leaves this where it was.
    peak_depth: usize = 0,

    pub fn init(ctx: *Context, scratch: std.mem.Allocator) Machine {
        return .{ .ctx = ctx, .scratch = scratch };
    }

    /// Runs `node` to its value. On an error `ctx` holds the message.
    pub fn run(self: *Machine, node: *const Node) Error!Value {
        _ = node;
        return self.ctx.fail(error.NotAProcedure, "not implemented", .{});
    }
};

test {
    std.testing.refAllDecls(@This());
}

const expand = @import("syntax/expand.zig");
const reader_mod = @import("reader.zig");

/// What the tests share: a context, and a machine that runs source text.
const Fixture = struct {
    arena: std.heap.ArenaAllocator,
    ctx: Context,
    machine: Machine,

    fn init(self: *Fixture) !void {
        self.arena = .init(std.testing.allocator);
        errdefer self.arena.deinit();
        self.ctx = try .init(self.arena.allocator());
        self.machine = .init(&self.ctx, self.arena.allocator());
    }

    fn deinit(self: *Fixture) void {
        self.arena.deinit();
    }

    /// The value of the last form of `src`; the forms before it run first.
    fn eval(self: *Fixture, src: []const u8) !Value {
        var r: reader_mod.Reader = .init(src);
        const sink: reader_mod.Sink = .{ .alloc = self.ctx.persist, .symbols = &self.ctx.symbols };
        var last: Value = .unspecified_value;
        while (try r.next(self.arena.allocator(), sink)) |form| {
            const node = try expand.expand(&self.ctx, self.arena.allocator(), form);
            last = try self.machine.run(node);
        }
        return last;
    }

    fn expectInt(self: *Fixture, expected: i64, src: []const u8) !void {
        try std.testing.expectEqual(expected, (try self.eval(src)).asFixnum().?);
    }

    fn expectFails(self: *Fixture, err: anyerror, message: []const u8, src: []const u8) !void {
        try std.testing.expectError(err, self.eval(src));
        try std.testing.expectEqualStrings(message, self.ctx.diagnostic());
    }
};

test "a constant is its own value, and a primitive is applied to its operands" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.expectInt(42, "42");
    try f.expectInt(3, "(+ 1 2)");
    try f.expectInt(10, "(+ (+ 1 2) (+ 3 4))");
    try std.testing.expect((try f.eval("#t")).isTrue());
    try std.testing.expectEqual(value_mod.Kind.unspecified, (try f.eval("(define x 1)")).kind());
}

test "if takes the branch the condition chooses, and has no value without an alternative" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.expectInt(1, "(if #t 1 2)");
    try f.expectInt(2, "(if #f 1 2)");
    try f.expectInt(1, "(if 0 1 2)");
    try std.testing.expectEqual(value_mod.Kind.unspecified, (try f.eval("(if #f 1)")).kind());
}

test "a global is defined, read and assigned" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.expectInt(5, "(define x 5) x");
    try f.expectInt(6, "(set! x 6) x");
    try f.expectFails(error.UnboundVariable, "unbound variable: nope", "nope");
    try f.expectFails(error.UnboundVariable, "unbound variable: nope", "(set! nope 1)");
    // A failing definition leaves the name as it was.
    try f.expectFails(error.UnboundVariable, "unbound variable: nope", "(define x nope)");
    try f.expectInt(6, "x");
}

test "a lambda is applied, and sees the frame it was made in" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.expectInt(3, "((lambda (x) (+ x 1)) 2)");
    try f.expectInt(7, "((lambda (x y) (+ x y)) 3 4)");
    try f.expectInt(5, "(((lambda (x) (lambda (y) (+ x y))) 2) 3)");
    try f.expectInt(4, "((lambda () 1 2 4))");
    try std.testing.expectEqual(value_mod.Kind.closure, (try f.eval("(lambda (x) x)")).kind());
}

test "a closure keeps its frame, and set! changes the variable it shares" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    _ = try f.eval("(define make (lambda (n) (lambda () (set! n (+ n 1)) n)))");
    _ = try f.eval("(define a (make 10)) (define b (make 20))");
    try f.expectInt(11, "(a)");
    try f.expectInt(12, "(a)");
    try f.expectInt(21, "(b)");
}

test "the operator is evaluated first, then the operands from left to right" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    _ = try f.eval("(define n 0)");
    try f.expectInt(-1, "(- (begin (set! n 1) n) (begin (set! n 2) n))");
    _ = try f.eval("(set! n 0)");
    try f.expectInt(4, "((begin (set! n 5) -) n 1)");
}

test "definitions at the start of a body are local, and uninitialized until they run" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.expectInt(8, "((lambda (x) (define y (+ x 1)) (define (g) (* y 2)) (g)) 3)");
    try f.expectFails(error.UnboundVariable, "unbound variable: y", "y");
    try f.expectFails(error.UninitializedVariable, "variable used before its definition: b", "((lambda () (define a b) (define b 1) a))");
    try f.expectFails(error.UninitializedVariable, "variable used before its definition: b", "((lambda () (define a (set! b 1)) (define b 2) b))");
    // Each call has frame of its own.
    _ = try f.eval("(define (f n) (define cell n) (set! cell (+ cell 1)) cell)");
    try f.expectInt(2, "(f 1)");
    try f.expectInt(11, "(f 10)");
}

test "procedures can call each other before both are defined" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    _ = try f.eval("(define (ev? n) (if (= n 0) #t (od? (- n 1))))");
    _ = try f.eval("(define (od? n) (if (= n 0) #f (ev? (- n 1))))");
    try std.testing.expect((try f.eval("(ev? 10)")).isTrue());
    try std.testing.expect(!(try f.eval("(ev? 7)")).isTrue());
    try f.expectInt(3628800, "(define (fact n) (if (= n 0) 1 (* n (fact (- n 1))))) (fact 10)");
}

test "the errors of a call keep the messages the evaluator gave" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.expectFails(error.NotAProcedure, "not a procedure", "(1 2)");
    try f.expectFails(error.WrongType, "wrong type of argument to +", "(+ 1 #t)");
    try f.expectFails(error.IntegerOverflow, "integer overflow in +", "(+ 9223372036854775807 1)");
    try f.expectFails(error.WrongArgumentCount, "wrong number of arguments to -", "(-)");
    try f.expectFails(error.WrongArgumentCount, "wrong number of arguments: expected 1, got 2", "((lambda (x) x) 1 2)");
    try f.expectFails(error.WrongArgumentCount, "wrong number of arguments: expected 2, got 1", "((lambda (x y) x) 1)");
}

test "a call in tail position does not grow the continuation" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    _ = try f.eval("(define (loop n) (if (= n 0) 'done (loop (- n 1))))");
    f.machine.peak_depth = 0;
    _ = try f.eval("(loop 10)");
    const small = f.machine.peak_depth;
    f.machine.peak_depth = 0;
    _ = try f.eval("(loop 10000)");
    try std.testing.expectEqual(small, f.machine.peak_depth);
    // The same through `begin`, a body with definitions, and a procedure passed in.
    _ = try f.eval("(define (b n) (begin 1 (if (= n 0) 'ok (b (- n 1)))))");
    _ = try f.eval("(define (g n) (define k 1) (if (= n 0) 'ok (g (- n k))))");
    _ = try f.eval("(define (run h n) (if (= n 0) 'ok (h h (- n 1))))");
    f.machine.peak_depth = 0;
    _ = try f.eval("(b 10)  (g 10) (run run 10)");
    const small_all = f.machine.peak_depth;
    f.machine.peak_depth = 0;
    _ = try f.eval("(b 5000) (g 5000) (run run 5000)");
    try std.testing.expectEqual(small_all, f.machine.peak_depth);
}

test "a call that is not in tail position holds a frame for each pending call" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    _ = try f.eval("(define (count n) (if (= n 0) 0 (+ 1 (count (- n 1)))))");
    f.machine.peak_depth = 0;
    try f.expectInt(1000, "(count 1000)");
    try std.testing.expect(f.machine.peak_depth >= 1000);
    // As deep as memory allows, and not as deep as the Zig stack does.
    try f.expectInt(100_000, "(count 100000)");
}
