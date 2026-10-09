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
const Frame = value_mod.Frame;
const Closure = value_mod.Closure;
const Kont = value_mod.Kont;
const Args = value_mod.Args;
const SymbolId = @import("symbol.zig").SymbolId;
const context = @import("context.zig");
const Context = context.Context;

pub const Error = context.Error;

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
    pub fn run(self: *Machine, root: *const Node) Error!Value {
        const ctx = self.ctx;
        var control: ?*const Node = root;
        var env: ?*Frame = null;
        var kont: ?*const Kont = null;
        var value: Value = .unspecified_value;
        while (true) {
            if (control) |node| {
                control = null;
                switch (node.*) {
                    .constant => |v| value = v,
                    .local_ref => |*r| {
                        const slot = slotAt(env, r.address);
                        if (slot.kind() == .uninitialized) return self.uninitialized(r.name);
                        value = slot.*;
                    },
                    .global_ref => |id| value = ctx.globals.lookup(id) orelse return self.unbound(id),
                    .lambda => |lambda| {
                        const closure = try ctx.persist.create(Closure);
                        closure.* = .{ .lambda = lambda, .env = env };
                        value = .fromClosure(closure);
                    },
                    .@"if" => |*i| {
                        kont = try self.push(kont, env, .{ .branch = i });
                        control = i.condition;
                    },
                    .sequence => |nodes| {
                        if (nodes.len > 1) kont = try self.push(kont, env, .{ .sequence = nodes[1..] });
                        control = nodes[0];
                    },
                    .local_set => |*a| {
                        kont = try self.push(kont, env, .{ .local_set = a });
                        control = a.value;
                    },
                    .local_define => |*a| {
                        kont = try self.push(kont, env, .{ .local_define = a });
                        control = a.value;
                    },
                    .global_set => |*a| {
                        kont = try self.push(kont, env, .{ .global_set = a });
                        control = a.value;
                    },
                    .global_define => |*a| {
                        kont = try self.push(kont, env, .{ .global_define = a });
                        control = a.value;
                    },
                    .call => |*c| {
                        kont = try self.push(kont, env, .{ .call = .{ .call = c, .args = null, .received = 0 } });
                        control = c.operator;
                    },
                }
            } else {
                // The value goes to the top frame of the continuation, which is
                // taken off first: whatever runs next runs without it.
                const k = kont orelse return value;
                kont = k.next;
                env = k.env;
                switch (k.step) {
                    .branch => |i| {
                        if (value.isTrue()) {
                            control = i.consequent;
                        } else if (i.alternative) |alternative| {
                            control = alternative;
                        } else {
                            value = .unspecified_value;
                        }
                    },
                    .sequence => |rest| {
                        // The last node runs with no frame of this sequence left.
                        if (rest.len > 1) kont = try self.push(kont, env, .{ .sequence = rest[1..] });
                        control = rest[0];
                    },
                    .local_set => |a| {
                        const slot = slotAt(env, a.address);
                        if (slot.kind() == .uninitialized) return self.uninitialized(a.name);
                        slot.* = value;
                        value = .unspecified_value;
                    },
                    .local_define => |a| {
                        slotAt(env, a.address).* = value;
                        value = .unspecified_value;
                    },
                    .global_set => |a| {
                        if (!ctx.globals.assign(a.name, value)) return self.unbound(a.name);
                        value = .unspecified_value;
                    },
                    .global_define => |a| {
                        try ctx.globals.define(ctx.persist, a.name, value);
                        value = .unspecified_value;
                    },
                    .call => |c| {
                        const args = try ctx.persist.create(Args);
                        args.* = .{ .value = value, .next = c.args };
                        const received = c.received + 1;
                        if (received <= c.call.operands.len) {
                            kont = try self.push(kont, env, .{ .call = .{ .call = c.call, .args = args, .received = received } });
                            control = c.call.operands[received - 1];
                        } else switch (try self.apply(args, received - 1)) {
                            .value => |v| value = v,
                            // A tail call: the body runs under the continuation of
                            // the call, which is what is left of `kont`.
                            .body => |entry| {
                                env = entry.env;
                                control = entry.body;
                            },
                        }
                    },
                }
            }
        }
    }

    const Applied = union(enum) {
        value: Value,
        body: struct { env: *Frame, body: *const Node },
    };

    /// Applies the operator at the end of `args` to the `count` operands before
    /// it. A primitive gives its value; a closure gives the frame of the call and
    /// the body to run in it.
    fn apply(self: *Machine, args: *const Args, count: usize) Error!Applied {
        const ctx = self.ctx;
        var operator_node = args;
        while (operator_node.next) |n| operator_node = n;
        const operator = operator_node.value;
        if (operator.asPrimitive()) |prim| {
            var small: [8]Value = undefined;
            const operands = if (count <= small.len) small[0..count] else try self.scratch.alloc(Value, count);
            fill(operands, args);
            const result = prim.call(operands) catch |e| return switch (e) {
                error.WrongType => ctx.raise("wrong type of argument to {s}", .{prim.name}),
                error.IntegerOverflow => ctx.raise("integer overflow in {s}", .{prim.name}),
                error.WrongArgumentCount => ctx.raise("wrong number of arguments to {s}", .{prim.name}),
            };
            return .{ .value = result };
        }
        const closure = operator.asClosure() orelse
            return ctx.raise("not a procedure", .{});
        const lambda = closure.lambda;
        if (count != lambda.arity) return ctx.raise(
            "wrong number of arguments: expected {d}, got {d}",
            .{ lambda.arity, count },
        );
        // The frame outlives the call when a closure made in it does, so it is
        // allocated where closures are. The names the body defines start out
        // uninitialized (R7RS 5.3.2: a body is a `letrec*`).
        const frame = try ctx.persist.create(Frame);
        const values = try ctx.persist.alloc(Value, lambda.frame_size);
        fill(values[0..count], args);
        @memset(values[count..], Value.uninitialized_value);
        frame.* = .{ .values = values, .parent = closure.env };
        return .{ .body = .{ .env = frame, .body = lambda.body } };
    }

    /// Copies the operands in `args`, which holds them last first and the
    /// operator at the end, into `out` in the order they were written.
    fn fill(out: []Value, args: *const Args) void {
        var i = out.len;
        var it: ?*const Args = args;
        while (i > 0) : (it = it.?.next) {
            i -= 1;
            out[i] = it.?.value;
        }
    }

    /// A new frame on top of `next`.
    fn push(self: *Machine, next: ?*const Kont, env: ?*Frame, step: Kont.Step) error{OutOfMemory}!*const Kont {
        const k = try self.ctx.persist.create(Kont);
        k.* = .{ .next = next, .env = env, .depth = (if (next) |n| n.depth else 0) + 1, .step = step };
        if (k.depth > self.peak_depth) self.peak_depth = k.depth;
        return k;
    }

    fn uninitialized(self: *Machine, name: SymbolId) Error {
        return self.ctx.raise("variable used before its definition: {s}", .{self.ctx.symbols.nameOf(name)});
    }

    fn unbound(self: *Machine, name: SymbolId) Error {
        return self.ctx.raise("unbound variable: {s}", .{self.ctx.symbols.nameOf(name)});
    }
};

/// The slot of a local variable: `depth` frames out from `env`, then `index`.
fn slotAt(env: ?*Frame, address: value_mod.Address) *Value {
    var frame = env.?;
    var depth = address.depth;
    while (depth > 0) : (depth -= 1) frame = frame.parent.?;
    return &frame.values[address.index];
}

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

    /// `src` raises an error whose condition has `message`.
    fn expectFails(self: *Fixture, message: []const u8, src: []const u8) !void {
        try std.testing.expectError(error.Raised, self.eval(src));
        try std.testing.expectEqualStrings(message, self.ctx.raised.?.message);
    }
};

test "a constant is its own value, and a primitive is applied to its operands" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.expectInt(42, "42");
    try f.expectInt(3, "(+ 1 2)");
    try f.expectInt(10, "(+ (+ 1 2) (+ 3 4))");
    // More operands than the machine keeps on its own stack for a primitive.
    try f.expectInt(55, "(+ 1 2 3 4 5 6 7 8 9 10)");
    try f.expectInt(-53, "(- 1 2 3 4 5 6 7 8 9 10)");
    try std.testing.expect((try f.eval("#t")).isTrue());
    try std.testing.expectEqual(value_mod.Kind.unspecified, (try f.eval("(define x 1)")).kind());
}

test "a quoted datum is shared, not copied, each time it is read" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    _ = try f.eval("(define x '(1 2))");
    const first = try f.eval("x");
    const second = try f.eval("x");
    try std.testing.expectEqual(first.asPair().?, second.asPair().?);
    const sym = try f.eval("'foo");
    try std.testing.expectEqual(sym.asSymbol().?, (try f.eval("(quote foo)")).asSymbol().?);
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
    try f.expectFails("unbound variable: nope", "nope");
    try f.expectFails("unbound variable: nope", "(set! nope 1)");
    // A failing definition leaves the name as it was.
    try f.expectFails("unbound variable: nope", "(define x nope)");
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

test "after a call returns, the caller's own variables are the ones in sight" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    _ = try f.eval("(define (id x) x)");
    // The operand `x` is read after `(id 100)` has run in a frame of its own.
    try f.expectInt(101, "((lambda (x) (+ (id 100) x)) 1)");
    try f.expectInt(7, "((lambda (x) (if (id #t) (+ x 6) 0)) 1)");
    try f.expectInt(12, "((lambda (x) (id 0) (id 0) (+ x 11)) 1)");
    try f.expectInt(9, "((lambda (x) (define y (id 8)) (+ x y)) 1)");
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
    try f.expectFails("unbound variable: y", "y");
    try f.expectFails("variable used before its definition: b", "((lambda () (define a b) (define b 1) a))");
    try f.expectFails("variable used before its definition: b", "((lambda () (define a (set! b 1)) (define b 2) b))");
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
    try f.expectFails("not a procedure", "(1 2)");
    try f.expectFails("wrong type of argument to +", "(+ 1 #t)");
    try f.expectFails("integer overflow in +", "(+ 9223372036854775807 1)");
    try f.expectFails("wrong number of arguments to -", "(-)");
    try f.expectFails("wrong number of arguments: expected 1, got 2", "((lambda (x) x) 1 2)");
    try f.expectFails("wrong number of arguments: expected 2, got 1", "((lambda (x y) x) 1)");
}

test "an error raised deep in the recursion leaves the machine, and the next run is not affected" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    _ = try f.eval("(define (boom n) (if (= n 0) (nope) (+ 1 (boom (- n 1)))))");
    try std.testing.expectError(error.Raised, f.eval("(boom 1000)"));
    const condition = Value.fromCondition(f.ctx.raised.?);
    try std.testing.expectEqual(value_mod.Kind.condition, condition.kind());
    try std.testing.expectEqualStrings("unbound variable: nope", condition.asCondition().?.message);
    // The continuation of the failed run is gone with it: a run starts empty.
    f.machine.peak_depth = 0;
    try f.expectInt(3, "(+ 1 2)");
    try std.testing.expect(f.machine.peak_depth <= 4);
    // A later error raises a condition of its own.
    try f.expectFails("not a procedure", "(1)");
    try std.testing.expect(f.ctx.raised.? != condition.asCondition().?);
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

test "the operands of a primitive call with many operands do not pile up in the scratch space" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    // The machine's scratch space is its own, apart from the one the expander used.
    var scratch: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer scratch.deinit();
    f.machine.scratch = scratch.allocator();
    _ = try f.eval("(define (loop n) (if (= n 0) 'done (begin (+ 1 2 3 4 5 6 7 8 9 10) (loop (- n 1)))))");
    _ = try f.eval("(loop 20000)");
    // Each call may take its operands from the scratch space for as long as the
    // call runs, and gives them back; the space does not grow with the loop.
    try std.testing.expect(scratch.queryCapacity() <= 16 * 1024);
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
