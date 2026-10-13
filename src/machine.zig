//! The CEK machine: the only place evaluation advances
//! (docs/design/architecture.md, ADR-0004).
//!
//! レジスタは 4 つある。実行する節点(制御)、実行中の手続きのフレーム(環境)、
//! 値をどうするかを表すフレームの連なり(継続)、直前に作られた値である。ステップは、
//! 制御にある節点を分解するか、値を継続の先頭のフレームに渡すかのどちらかをする。
//! そのため、ここには Zig のスタックで再帰するものがなく、プログラムはメモリの
//! 許す限り深くなれる。
//!
//! 継続のフレームは、一度作ったら変えない。末尾位置の呼び出しにフレームは要らない。
//! 手続きの本体は呼び出し元の継続のもとで走り、列の最後の節点と `if` のどちらの枝も、
//! 自分のフレームが外れてから走る。
//!
//! ヒープは2つのステップの間で GC し、ステップの中では GC しない(ADR-0031)。その時点で
//! プログラムが持っているものは、コンテキストのルートの表(大域束縛、コードの定数、
//! 送出された値)を除けばレジスタがすべてである。だから GC にほかのルートは要らない
//! (ADR-0035)。

const std = @import("std");
const tier = @import("tier.zig");
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
const heap_mod = @import("heap.zig");
const pair = @import("prim/pair.zig");

pub const Error = context.Error;

pub const Machine = struct {
    ctx: *Context,
    /// What a step needs only while it runs, such as the arguments of a call.
    scratch: std.mem.Allocator,
    /// The most frames the continuation has held since the machine was made or
    /// the figure was reset.
    /// 末尾位置の呼び出しはフレームを足さないので、自分自身を呼ぶループがあっても
    /// この値は変わらない。
    peak_depth: usize = 0,

    pub fn init(ctx: *Context, scratch: std.mem.Allocator) Machine {
        return .{ .ctx = ctx, .scratch = scratch };
    }

    /// Runs `node` to its value.
    /// エラーのときは `ctx` がメッセージを持つ。
    pub fn run(self: *Machine, root: *const Node) Error!Value {
        const ctx = self.ctx;
        var control: ?*const Node = root;
        var env: ?*Frame = null;
        var kont: ?*const Kont = null;
        var value: Value = .unspecified_value;
        while (true) {
            if (ctx.heap.shouldCollect()) try self.collect(env, kont, value);
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
                        value = .fromClosure(try ctx.create(Closure, .{ .lambda = lambda, .env = env }));
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
                // 値は継続の先頭のフレームに渡す。そのフレームは先に外すので、
                // 次に走るものは、そのフレームなしで走る。
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
                        // 最後の節点は、この列のフレームが残っていない状態で走る。
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
                        const args = try ctx.create(Args, .{ .value = value, .next = c.args });
                        const received = c.received + 1;
                        if (received <= c.call.operands.len) {
                            kont = try self.push(kont, env, .{ .call = .{ .call = c.call, .args = args, .received = received } });
                            control = c.call.operands[received - 1];
                        } else switch (try self.apply(args, received - 1)) {
                            .value => |v| value = v,
                            // 末尾呼び出し: 本体は呼び出しの継続のもとで走る。その継続は
                            // `kont` に残っているものである。
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
    /// it.
    /// 純粋プリミティブは値を返す。クロージャは、呼び出しのフレームと、そのフレームで
    /// 走らせる本体を返す。機械操作プリミティブ `apply` は、引数を並べ直した呼び出しに
    /// 置き換わり、その呼び出しをここでもう一度適用する。
    fn apply(self: *Machine, initial_args: *const Args, initial_count: usize) Error!Applied {
        const ctx = self.ctx;
        var args = initial_args;
        var count = initial_count;
        // Why: `apply` の被呼び出し側を、Zig の再帰でなく周回で適用する。`apply` で `apply`
        // を呼ぶ入れ子は、データから好きなだけ深く作れるので、再帰にすると Zig のスタックを
        // 使い切りうる。ただし周回は1ステップの中で回るので、その間にできたごみは回収
        // されない。この制約と直す時期は、ADR-0031 の 2026-10-13 の追記にある。
        const operator = while (true) {
            var operator_node = args;
            while (operator_node.next) |n| operator_node = n;
            const operator = operator_node.value;
            const prim = operator.asPrimitive() orelse break operator;
            // 個数の検査はここにしかない。プリミティブの本体は、`args` が表の範囲に
            // 収まることを前提にしてよい。
            if (!prim.acceptsCount(count)) return primitiveFailure(ctx, prim, error.WrongArgumentCount);
            switch (prim.body) {
                .pure => |call| return .{ .value = try self.callPure(prim, call, args, count) },
                .machine => |op| switch (op) {
                    // Why: 並べ直した呼び出しは、継続のフレームを積まずに適用する。被呼び出し側は
                    // `apply` の呼び出しの継続のもとで走るので、`apply` の第1引数の呼び出しは
                    // 末尾呼び出しになる(R7RS 3.5、ADR-0029 の追記)。
                    .apply => {
                        const spread = try self.spreadApply(prim, args, count);
                        args = spread.args;
                        count = spread.count;
                    },
                },
            }
        };
        const closure = operator.asClosure() orelse
            return ctx.raise("not a procedure", .{});
        const lambda = closure.lambda;
        if (!lambda.acceptsCount(count)) {
            if (lambda.rest) return ctx.raise(
                "wrong number of arguments: expected at least {d}, got {d}",
                .{ lambda.arity, count },
            );
            return ctx.raise(
                "wrong number of arguments: expected {d}, got {d}",
                .{ lambda.arity, count },
            );
        }
        // フレームは、その中で作ったクロージャが生き延びるとき、呼び出しより長く生きる。
        // そのため、クロージャと同じ場所に確保する。本体が定義する名前は未初期化で
        // 始まる(R7RS 5.3.2: 本体は `letrec*` である)。ヒープがフレームを作ると、
        // そうなる。
        const frame = try ctx.createFrame(lambda.frame_size, closure.env);
        var required = args;
        if (lambda.rest) {
            // `args` は最後のオペランドから並ぶので、余りの引数はその先頭にある。
            // 先頭から順に前へ継ぎ足すと、書いた順のリストになる。リストは呼び出しの
            // たびに新しく作る(R7RS 4.1.4 の newly allocated list)。
            // Why: GC はステップの間でしか走らない(ADR-0031)。ここで作るリストは、
            // フレームのスロットに入るまでどのルートからも辿れないが、同じステップの
            // うちに入るので、回収されない。
            var list: Value = .empty_list_value;
            for (0..count - lambda.arity) |_| {
                list = ctx.heap.cons(required.value, list) catch |e| return ctx.heapFailure(e);
                required = required.next.?;
            }
            frame.values[lambda.arity] = list;
        }
        fill(frame.values[0..lambda.arity], required);
        return .{ .body = .{ .env = frame, .body = lambda.body } };
    }

    /// The operands a call lines up in a buffer on the Zig stack.
    /// これより多いときは、スクラッチ領域から取って、使い終えたら返す。
    const small_operands = 8;

    /// The value of the pure primitive `prim`, whose body is `call`, for the
    /// `count` operands in `args`.
    fn callPure(self: *Machine, prim: *const value_mod.Primitive, call: value_mod.Primitive.Fn, args: *const Args, count: usize) Error!Value {
        const ctx = self.ctx;
        var small: [small_operands]Value = undefined;
        const operands = if (count <= small.len) small[0..count] else try self.scratch.alloc(Value, count);
        // Why: スクラッチ領域は1行ぶんのアリーナで、`free` が効くのは最後の確保だけである。
        // オペランドを最初に取り、プリミティブは取ったものを確保と逆の順に返す約束なので、
        // 呼び出しの直後にオペランドを返せば、アリーナがそれを再利用できる。返さずに
        // 残すと、オペランドの多いプリミティブを呼ぶループは、1 周ごとに領域を広げてしまう。
        defer if (count > small.len) self.scratch.free(operands);
        fill(operands, args);
        const services: value_mod.Services = .{ .heap = &ctx.heap, .scratch = self.scratch };
        return call(&services, operands) catch |e| return primitiveFailure(ctx, prim, e);
    }

    /// A call and the number of its operands, as `apply` takes them.
    const Call = struct { args: *const Args, count: usize };

    /// The call that `(apply proc arg1 ... list)` stands for: `proc` applied to
    /// `arg1 ...` followed by the elements of `list` (R7RS 6.10).
    /// `args` は `apply` の呼び出しの値の鎖で、`list` から逆順に並び、末尾に `apply`
    /// 自身がある。鎖は捕捉された継続と共有されうる(`Args` の説明)ので書き換えず、
    /// `proc` を末尾に置く新しい鎖を作る。`prim` は `apply` 自身で、失敗の報告に使う。
    fn spreadApply(self: *Machine, prim: *const value_mod.Primitive, args: *const Args, count: usize) Error!Call {
        const ctx = self.ctx;
        const list = args.value;
        // 確保より前に検査する。長い非真正リストを、上限超過として報告しないためである。
        const length = pair.properLength(list) orelse return primitiveFailure(ctx, prim, error.WrongType);
        // `proc` と、リストの前の引数を、書いた順に並べる。
        const leading = count - 1;
        var small: [small_operands]Value = undefined;
        const before = if (leading <= small.len) small[0..leading] else try self.scratch.alloc(Value, leading);
        // Why: `callPure` と同じ理由で、並べ直した呼び出しを適用する前に返す。
        defer if (leading > small.len) self.scratch.free(before);
        fill(before, args.next.?);
        // Why: GC はステップの間でしか走らない(ADR-0031)。作りかけの鎖はどのルートからも
        // 辿れないが、同じステップのうちに適用されるので、回収されない。
        var chain: *const Args = try ctx.create(Args, .{ .value = before[0], .next = null });
        for (before[1..]) |v| chain = try ctx.create(Args, .{ .value = v, .next = chain });
        var it = list;
        while (it.asPair()) |p| : (it = p.cdr) chain = try ctx.create(Args, .{ .value = p.car, .next = chain });
        return .{ .args = chain, .count = leading - 1 + length };
    }

    /// The error a failure of `prim` is: a condition with the message the failure
    /// has, or the failure of the host as it is.
    fn primitiveFailure(ctx: *Context, prim: *const value_mod.Primitive, e: value_mod.PrimitiveError) Error {
        return switch (e) {
            error.WrongType => ctx.raise("wrong type of argument to {s}", .{prim.name}),
            error.IntegerOverflow => ctx.raise("integer overflow in {s}", .{prim.name}),
            error.WrongArgumentCount => ctx.raise("wrong number of arguments to {s}", .{prim.name}),
            error.DivisionByZero => ctx.raise("division by zero in {s}", .{prim.name}),
            error.OutOfRange => ctx.raise("argument out of range in {s}", .{prim.name}),
            // ヒープの失敗は、ほかの経路と同じ文言になるよう `Context` を通す。
            error.HeapLimit, error.OutOfMemory => |heap_error| ctx.heapFailure(heap_error),
        };
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
    fn push(self: *Machine, next: ?*const Kont, env: ?*Frame, step: Kont.Step) Error!*const Kont {
        const depth = (if (next) |n| n.depth else 0) + 1;
        const k = try self.ctx.create(Kont, .{ .next = next, .env = env, .depth = depth, .step = step });
        if (depth > self.peak_depth) self.peak_depth = depth;
        return k;
    }

    /// Collects, with the registers as the roots.
    /// 生きているものを除いてもなお余裕がないときは、ここで "heap limit exceeded" として
    /// 行を終える。どこかの確保で終えると、ヒープは同じ余裕を何度も求められることになる。
    fn collect(self: *Machine, env: ?*Frame, kont: ?*const Kont, value: Value) Error!void {
        const ctx = self.ctx;
        ctx.heap.collect(Roots{ .ctx = ctx, .env = env, .kont = kont, .value = value });
        if (ctx.heap.exhausted) return ctx.raise(context.heap_limit_message, .{});
    }

    /// What the program holds at a safe point.
    const Roots = struct {
        ctx: *const Context,
        env: ?*Frame,
        kont: ?*const Kont,
        value: Value,

        pub fn mark(self: Roots, marker: *heap_mod.Marker) void {
            marker.value(self.value);
            marker.frame(self.env);
            marker.kont(self.kont);
            self.ctx.mark(marker);
        }
    };

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
    /// 機械のスクラッチ領域。本番では永続のアリーナと別物なので、テストでも分ける。
    scratch_arena: std.heap.ArenaAllocator,
    ctx: Context,
    machine: Machine,

    fn init(self: *Fixture) !void {
        try self.initWith(.{});
    }

    fn initWith(self: *Fixture, options: heap_mod.Options) !void {
        try self.initIn(std.testing.allocator, options);
    }

    /// The heap takes its objects from `gpa`.
    /// 数百万個を作るテストは、速いアロケータを求める。テスト用のアロケータは、
    /// 1 つごとにスタックトレースを記録するからだ。
    fn initIn(self: *Fixture, gpa: std.mem.Allocator, options: heap_mod.Options) !void {
        self.arena = .init(std.testing.allocator);
        errdefer self.arena.deinit();
        self.scratch_arena = .init(std.testing.allocator);
        errdefer self.scratch_arena.deinit();
        self.ctx = try .initWithOptions(self.arena.allocator(), gpa, options);
        self.machine = .init(&self.ctx, self.scratch_arena.allocator());
    }

    fn deinit(self: *Fixture) void {
        self.ctx.deinit();
        self.scratch_arena.deinit();
        self.arena.deinit();
    }

    /// The value of the last form of `src`; the forms before it run first.
    fn eval(self: *Fixture, src: []const u8) !Value {
        var r: reader_mod.Reader = .init(src);
        const sink: reader_mod.Sink = .{ .alloc = self.ctx.persist, .heap = &self.ctx.heap, .symbols = &self.ctx.symbols };
        var last: Value = .unspecified_value;
        while (true) {
            // 2つの形式の間で持っているものは、コンテキストが持つものと、いま走り終えた
            // 形式の値だけである。その値は、呼び出し側がまだ受け取る。
            // (`Interpreter.run` は、この時点までにその値を表示し終えている。)
            if (self.ctx.heap.shouldCollect()) {
                self.ctx.heap.collect(Machine.Roots{ .ctx = &self.ctx, .env = null, .kont = null, .value = last });
            }
            const form = try r.next(self.arena.allocator(), sink) orelse break;
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
    // プリミティブ用に機械が自前のスタックに持つ数より、多いオペランド。
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
    // 失敗した定義は、名前をそのままにする。
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
    // オペランド `x` は、`(id 100)` が自分のフレームで走り終えたあとに読まれる。
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
    // 呼び出しごとに、自分のフレームがある。
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
    // 余りを受ける手続きは、必須の個数を下回るときだけ失敗する。
    try f.expectFails("wrong number of arguments: expected at least 2, got 1", "((lambda (x y . r) x) 1)");
    try f.expectFails("wrong number of arguments: expected at least 1, got 0", "((lambda (x . r) x))");
}

/// The length of the proper list `v`, and its elements as fixnums in `out`.
fn fixnums(v: Value, out: []i64) usize {
    var n: usize = 0;
    var it = v;
    while (it.asPair()) |p| : (it = p.cdr) {
        out[n] = p.car.asFixnum().?;
        n += 1;
    }
    std.debug.assert(it.kind() == .empty_list);
    return n;
}

test "a rest parameter gets the arguments left over, in the order they were written" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    var buf: [16]i64 = undefined;
    const cases = [_]struct { src: []const u8, expected: []const i64 }{
        .{ .src = "((lambda args args) 1 2)", .expected = &.{ 1, 2 } },
        .{ .src = "((lambda args args))", .expected = &.{} },
        .{ .src = "((lambda (a . r) r) 1 2 3)", .expected = &.{ 2, 3 } },
        .{ .src = "((lambda (a . r) r) 1)", .expected = &.{} },
        .{ .src = "((lambda (a b . r) r) 1 2 3 4 5 6 7 8 9 10)", .expected = &.{ 3, 4, 5, 6, 7, 8, 9, 10 } },
    };
    for (cases) |c| {
        const n = fixnums(try f.eval(c.src), &buf);
        try std.testing.expectEqualSlices(i64, c.expected, buf[0..n]);
    }
    // 必須の仮引数は、余りがあっても書いた位置の引数を受ける。
    try f.expectInt(2, "((lambda (a b . r) b) 1 2 3)");
    try f.expectInt(1, "((lambda (a . r) a) 1 2 3)");
    // 本体の先頭の定義は、余りのスロットの後ろに入り、余りを上書きしない。
    try f.expectInt(13, "((lambda (a . r) (define n 10) (+ n a (car r))) 1 2)");
}

test "the list of the arguments left over is new at each call" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    _ = try f.eval("(define (f . a) a)");
    const first = try f.eval("(f 1 2)");
    const second = try f.eval("(f 1 2)");
    try std.testing.expect(first.asPair().? != second.asPair().?);
    try std.testing.expect(first.pointsIntoHeap());
    try std.testing.expect(!(try f.eval("(eq? (f 1) (f 1))")).isTrue());
}

test "a variadic procedure called in tail position does not grow the continuation" {
    var f: Fixture = undefined;
    try f.initIn(std.heap.smp_allocator, .{});
    defer f.deinit();
    // 余りは数でない値にする。必須の仮引数に余りが入る誤りがあると、ループが終わらず
    // に回り続けるのでなく、`=` の型の誤りですぐに失敗する。
    _ = try f.eval("(define (loop n . more) (if (= n 0) 'done (loop (- n 1) 'a 'b 'c)))");
    f.machine.peak_depth = 0;
    _ = try f.eval("(loop 10)");
    const small = f.machine.peak_depth;
    f.machine.peak_depth = 0;
    _ = try f.eval("(loop 5000)");
    try std.testing.expectEqual(small, f.machine.peak_depth);
}

/// The deepest the continuation gets while a loop of `short` and then of
/// `long` calls through `apply` runs, for each of the two.
fn applyLoopDepths(f: *Fixture, short: usize, long: usize) ![2]usize {
    // `apply` で `apply` を呼ぶ形も、同じループで通す。
    _ = try f.eval("(define (loop n) (if (= n 0) 'done (apply loop (list (- n 1)))))");
    _ = try f.eval("(define (loop2 n) (if (= n 0) 'done (apply apply loop2 (list (list (- n 1))))))");
    var depths: [2]usize = undefined;
    for ([_]usize{ short, long }, 0..) |n, i| {
        var src: [64]u8 = undefined;
        f.machine.peak_depth = 0;
        const done = try f.eval(try std.fmt.bufPrint(&src, "(loop {d}) (loop2 {d})", .{ n, n }));
        try std.testing.expectEqualStrings("done", f.ctx.symbols.nameOf(done.asSymbol().?));
        depths[i] = f.machine.peak_depth;
    }
    return depths;
}

test "a procedure applied by apply runs in tail position, so a loop through apply does not grow the continuation" {
    var f: Fixture = undefined;
    try f.initIn(std.heap.smp_allocator, .{});
    defer f.deinit();
    const depths = try applyLoopDepths(&f, 10, 5000);
    try std.testing.expectEqual(depths[0], depths[1]);
    // 対照: 同じ形で `apply` の値を使う、末尾でないループは、回数に比例して深くなる。
    // 上の比較が、深さを測れていることを確かめる。
    _ = try f.eval("(define (count n) (if (= n 0) 0 (+ 1 (apply count (list (- n 1))))))");
    f.machine.peak_depth = 0;
    try f.expectInt(5000, "(count 5000)");
    try std.testing.expect(f.machine.peak_depth >= 5000);
}

test "slow: a million tail calls through apply keep the continuation at the same depth" {
    try tier.slow();
    var f: Fixture = undefined;
    try f.initIn(std.heap.smp_allocator, .{});
    defer f.deinit();
    const depths = try applyLoopDepths(&f, 10, 1_000_000);
    try std.testing.expectEqual(depths[0], depths[1]);
}

test "apply reports a last argument that is not a list before it allocates anything" {
    var f: Fixture = undefined;
    // 上限は、`n` 要素のリストの全部と、それを並べた引数の鎖の半分が入る大きさである。
    // リストは収まり、引数の鎖を作り終える前に上限に当たる。
    const n = 2000;
    const limit = n * heap_mod.cellBytes(value_mod.Pair) + n * heap_mod.cellBytes(Args) / 2;
    try f.initWith(.{ .limit = limit, .min_threshold = 16 * 1024 });
    defer f.deinit();
    _ = try f.eval("(define (build n acc) (if (= n 0) acc (build (- n 1) (cons n acc))))");
    // 対照: 正しいリストを並べると、引数の鎖を作る途中で上限に当たる。
    _ = try f.eval(std.fmt.comptimePrint("(define xs (build {d} '()))", .{n}));
    try f.expectFails("heap limit exceeded", "(apply list xs)");
    try f.expectInt(n, "(length xs)");
    // 同じ長さの正しくないリストは、上限に当たる前に、型の誤りとして報告される。
    // 2つのリストは同時には収まらないので、先のリストを手放してから作る。
    _ = try f.eval(std.fmt.comptimePrint("(set! xs 0) (define xs (build {d} 0))", .{n}));
    try f.expectFails("wrong type of argument to apply", "(apply list xs)");
}

test "the operands apply spreads do not pile up in the scratch space" {
    var f: Fixture = undefined;
    try f.initIn(std.heap.smp_allocator, .{});
    defer f.deinit();
    var scratch: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer scratch.deinit();
    f.machine.scratch = scratch.allocator();
    // リストの前の引数も、並べ直したあとの引数も、小さな配列に収まらない数である。
    _ = try f.eval("(define (loop n) (if (= n 0) 'done (begin (apply + 1 2 3 4 5 6 7 8 9 10 '(11 12)) (loop (- n 1)))))");
    _ = try f.eval("(loop 20000)");
    try std.testing.expect(scratch.queryCapacity() <= 16 * 1024);
}

test "an apply whose operands just fill the buffer on the stack takes no scratch space" {
    var f: Fixture = undefined;
    try f.initIn(std.heap.smp_allocator, .{});
    defer f.deinit();
    var scratch: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer scratch.deinit();
    f.machine.scratch = scratch.allocator();
    // 手続きとリストの前の引数を合わせた数も、並べ直したあとの引数の数も、
    // ちょうど `small_operands` になる呼び出し。境界の側を取り違えると、スクラッチ領域
    // から取ったものを返さず、ループのたびに領域が広がる。
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(std.testing.allocator);
    try src.appendSlice(std.testing.allocator, "(define (loop n) (if (= n 0) 'done (begin (apply +");
    for (1..Machine.small_operands) |i| try src.print(std.testing.allocator, " {d}", .{i});
    try src.print(std.testing.allocator, " '({d})) (loop (- n 1)))))", .{Machine.small_operands});
    _ = try f.eval(src.items);
    _ = try f.eval("(loop 20000)");
    try std.testing.expect(scratch.queryCapacity() <= 16 * 1024);
}

/// Primitives that record how the machine called them.
/// 引数の個数の検査が機械にあること、`Services` が機械のものであること、プリミティブの
/// 失敗が条件に写ることを確かめる。
const Probe = struct {
    var calls: usize = 0;
    var heap: ?*heap_mod.Heap = null;
    var scratch: ?std.mem.Allocator = null;
    var failure: ?value_mod.PrimitiveError = null;

    /// Takes one or two arguments.
    const primitive: value_mod.Primitive = .{ .name = "probe", .min_args = 1, .max_args = 2, .body = .{ .pure = &call } };
    /// Takes two arguments or more.
    const variadic: value_mod.Primitive = .{ .name = "probe*", .min_args = 2, .max_args = null, .body = .{ .pure = &call } };
    /// Takes no argument.
    const nullary: value_mod.Primitive = .{ .name = "probe0", .min_args = 0, .max_args = 0, .body = .{ .pure = &call } };

    fn call(services: *const value_mod.Services, args: []const Value) value_mod.PrimitiveError!Value {
        calls += 1;
        heap = services.heap;
        scratch = services.scratch;
        if (failure) |e| return e;
        return services.heap.cons(.fromFixnum(@intCast(args.len)), .empty_list_value);
    }

    /// Allocates until the limit refuses.
    /// GC はプリミティブの途中では走らない。
    const greedy: value_mod.Primitive = .{ .name = "greedy", .min_args = 0, .max_args = 0, .body = .{ .pure = &fill } };

    fn fill(services: *const value_mod.Services, _: []const Value) value_mod.PrimitiveError!Value {
        var list: Value = .empty_list_value;
        while (true) list = try services.heap.cons(.fromFixnum(1), list);
    }

    fn reset() void {
        calls = 0;
        heap = null;
        scratch = null;
        failure = null;
    }

    fn bind(f: *Fixture) !void {
        for ([_]*const value_mod.Primitive{ &primitive, &variadic, &nullary, &greedy }) |p| {
            const id = try f.ctx.symbols.intern(f.ctx.persist, p.name);
            try f.ctx.globals.define(f.ctx.persist, id, .fromPrimitive(p));
        }
    }

    /// The number of arguments the primitive got in `src`: the car of its value.
    fn count(f: *Fixture, src: []const u8) !i64 {
        return (try f.eval(src)).asPair().?.car.asFixnum().?;
    }
};

test "the machine checks the number of arguments, and the primitive is not called when it is wrong" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    Probe.reset();
    try Probe.bind(&f);
    // 下限を下回る。
    try f.expectFails("wrong number of arguments to probe", "(probe)");
    // 上限を上回る。
    try f.expectFails("wrong number of arguments to probe", "(probe 1 2 3)");
    // オペランドを小さな配列に収められない数でも、同じである。
    try f.expectFails("wrong number of arguments to probe", "(probe 1 2 3 4 5 6 7 8 9 10)");
    try f.expectFails("wrong number of arguments to probe*", "(probe* 1)");
    try f.expectFails("wrong number of arguments to probe0", "(probe0 1)");
    try std.testing.expectEqual(0, Probe.calls);
    // 範囲の両端は呼べる。
    try std.testing.expectEqual(1, try Probe.count(&f, "(probe 1)"));
    try std.testing.expectEqual(2, try Probe.count(&f, "(probe 1 2)"));
    try std.testing.expectEqual(2, try Probe.count(&f, "(probe* 1 2)"));
    try std.testing.expectEqual(10, try Probe.count(&f, "(probe* 1 2 3 4 5 6 7 8 9 10)"));
    try std.testing.expectEqual(0, try Probe.count(&f, "(probe0)"));
    try std.testing.expectEqual(5, Probe.calls);
    // 失敗のあとも、機械は次の呼び出しを受け付ける。
    try f.expectFails("wrong number of arguments to probe", "(probe)");
    try std.testing.expectEqual(5, Probe.calls);
}

test "the operands are evaluated before the count is checked" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    Probe.reset();
    try Probe.bind(&f);
    // オペランドは個数の検査より前に評価される。その中のエラーが先に報告される。
    try f.expectFails("unbound variable: nope", "(probe nope 1 2)");
    try std.testing.expectEqual(0, Probe.calls);
}

test "a primitive is given the heap and the scratch space of the machine" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    Probe.reset();
    try Probe.bind(&f);
    const before = f.ctx.heap.count;
    const result = try f.eval("(probe 7)");
    try std.testing.expectEqual(&f.ctx.heap, Probe.heap.?);
    try std.testing.expectEqual(f.machine.scratch.ptr, Probe.scratch.?.ptr);
    // 永続のアリーナ(`ctx.persist`)とは別物である。差し替えると、一時領域がセッションの
    // 終わりまで残ってしまう。
    try std.testing.expect(Probe.scratch.?.ptr != f.ctx.persist.ptr);
    // プリミティブが渡されたヒープに確保したペアは、機械が持つヒープのものである。
    try std.testing.expect(result.pointsIntoHeap());
    try std.testing.expect(f.ctx.heap.count > before);
    try std.testing.expectEqual(1, result.asPair().?.car.asFixnum().?);
}

test "the failures of a primitive become the conditions with their messages" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    Probe.reset();
    try Probe.bind(&f);
    const cases = [_]struct { failure: value_mod.PrimitiveError, message: []const u8 }{
        .{ .failure = error.WrongType, .message = "wrong type of argument to probe" },
        .{ .failure = error.WrongArgumentCount, .message = "wrong number of arguments to probe" },
        .{ .failure = error.IntegerOverflow, .message = "integer overflow in probe" },
        .{ .failure = error.DivisionByZero, .message = "division by zero in probe" },
        .{ .failure = error.OutOfRange, .message = "argument out of range in probe" },
        .{ .failure = error.HeapLimit, .message = "heap limit exceeded" },
    };
    for (cases) |c| {
        Probe.failure = c.failure;
        f.ctx.clearDiagnostic();
        try f.expectFails(c.message, "(probe 1)");
    }
    // ホストの失敗は条件にならず、そのまま返る。
    Probe.failure = error.OutOfMemory;
    f.ctx.clearDiagnostic();
    try std.testing.expectError(error.OutOfMemory, f.eval("(probe 1)"));
    try std.testing.expect(f.ctx.raised == null);
}

test "a call whose rest list passes the limit ends the line with heap limit exceeded, and the next line runs" {
    var f: Fixture = undefined;
    try f.initWith(.{ .limit = 128 * 1024, .min_threshold = 16 * 1024 });
    defer f.deinit();
    _ = try f.eval("(define (f . xs) xs)");
    var call: std.ArrayList(u8) = .empty;
    defer call.deinit(std.testing.allocator);
    try call.appendSlice(std.testing.allocator, "(f");
    for (0..1500) |_| try call.appendSlice(std.testing.allocator, " 1");
    try call.append(std.testing.allocator, ')');
    // 余りのリストを作る途中で上限に当たる。ホストの失敗(OutOfMemory)ではなく、
    // Scheme のエラーとして報告される。
    try f.expectFails("heap limit exceeded", call.items);
    try f.expectInt(3, "(+ 1 2)");
    // 対照: 同じ個数のオペランドをプリミティブに渡す呼び出しは、同じ上限に収まる。
    // 失敗の地点がリストの構築から別の所へ移っても、このテストが緑のまま
    // 固定する対象を失わないための確認である。
    call.items[1] = '+';
    try f.expectInt(1500, call.items);
}

test "a primitive that allocates past the limit ends the line with heap limit exceeded, and the next line runs" {
    var f: Fixture = undefined;
    try f.initWith(.{ .limit = 64 * 1024, .min_threshold = 16 * 1024 });
    defer f.deinit();
    Probe.reset();
    try Probe.bind(&f);
    try f.expectFails("heap limit exceeded", "(greedy)");
    try f.expectInt(3, "(+ 1 2)");
}

/// Fills the heap of `f` with `n` pairs that the constants of the context keep.
fn fillKept(f: *Fixture, n: usize) !void {
    var list: Value = .empty_list_value;
    for (0..n) |_| list = try f.ctx.heap.cons(.fromFixnum(0), list);
    try f.ctx.keepConstant(list);
}

test "an error raised at the limit of the heap makes its condition from the reserve, and the condition outlives a collection" {
    const limit = 1024;
    for ([_]usize{ 4096, 0 }) |capacity| {
        // 上限の手前まで埋める量を探す。`(car 5)` を評価できるだけの余裕はあるが、条件と
        // そのメッセージを上限の内側には作れない量である。埋める量を固定しないのは、
        // オブジェクトの大きさが変わっても、この縁にとどまるためである。
        var found = false;
        var n: usize = 0;
        while (!found) : (n += 1) {
            var f: Fixture = undefined;
            try f.initWith(.{ .limit = limit, .min_threshold = limit, .work_capacity = capacity });
            defer f.deinit();
            fillKept(&f, n) catch break;
            if (f.eval("(car 5)")) |_| return error.TestUnexpectedResult else |e| switch (e) {
                error.Raised => {},
                // リーダが式を読めないほど埋まった。これより先の量は試せない。
                error.HeapLimit => break,
                else => return e,
            }
            // GC が余裕の無さを見つけた量では、別のエラーになる。
            if (!std.mem.eql(u8, "wrong type of argument to car", f.ctx.diagnostic())) continue;
            if (f.ctx.heap.accounted <= limit) continue;
            found = true;
            // 条件はヒープにあり、上限を超えた分は予約から取った。
            try std.testing.expectEqual(1, f.ctx.heap.countOf(value_mod.Condition));
            try std.testing.expect(f.ctx.heap.accounted <= limit + f.ctx.heap.options.raise_reserve);
            // 送出された値はルートなので、GC のあとも残り、読める。
            f.ctx.collectIdle();
            try std.testing.expectEqual(1, f.ctx.heap.countOf(value_mod.Condition));
            try std.testing.expectEqual(1, f.ctx.heap.countOf(value_mod.String));
            try std.testing.expectEqualStrings("wrong type of argument to car", f.ctx.diagnostic());
            // 手放せば回収される。
            f.ctx.clearDiagnostic();
            f.ctx.collectIdle();
            try std.testing.expectEqual(0, f.ctx.heap.countOf(value_mod.Condition));
            try std.testing.expectEqual(0, f.ctx.heap.countOf(value_mod.String));
            // 対照: 予約が無ければ、同じ量で条件を作れず、送出できないまま行が終わる。
            var g: Fixture = undefined;
            try g.initWith(.{ .limit = limit, .min_threshold = limit, .work_capacity = capacity, .raise_reserve = 0 });
            defer g.deinit();
            try fillKept(&g, n);
            try std.testing.expectError(error.ReserveExhausted, g.eval("(car 5)"));
            try std.testing.expect(g.ctx.raised == null);
        }
        try std.testing.expect(found);
    }
}

test "a condition is made in the heap, not in the arena that lasts the session" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    var r: reader_mod.Reader = .init("(car 5)");
    const sink: reader_mod.Sink = .{ .alloc = f.ctx.persist, .heap = &f.ctx.heap, .symbols = &f.ctx.symbols };
    const node = try expand.expand(&f.ctx, f.arena.allocator(), (try r.next(f.arena.allocator(), sink)).?);
    // 展開を済ませてから数え始める。数えるのは、機械が走って送出する間の確保だけである。
    var counting: std.testing.FailingAllocator = .init(f.arena.allocator(), .{});
    const persist = f.ctx.persist;
    f.ctx.persist = counting.allocator();
    defer f.ctx.persist = persist;
    for (0..3) |_| {
        try std.testing.expectError(error.Raised, f.machine.run(node));
        try std.testing.expectEqualStrings("wrong type of argument to car", f.ctx.diagnostic());
    }
    try std.testing.expectEqual(0, counting.allocations);
}

test "an error raised deep in the recursion leaves the machine, and the next run is not affected" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    _ = try f.eval("(define (boom n) (if (= n 0) (nope) (+ 1 (boom (- n 1)))))");
    try std.testing.expectError(error.Raised, f.eval("(boom 1000)"));
    const condition = f.ctx.raised.?;
    try std.testing.expectEqual(value_mod.Kind.condition, condition.kind());
    try std.testing.expectEqualStrings("unbound variable: nope", condition.asCondition().?.messageText());
    // 失敗した実行の継続は、実行とともに消える。実行は空の継続から始まる。
    f.machine.peak_depth = 0;
    try f.expectInt(3, "(+ 1 2)");
    try std.testing.expect(f.machine.peak_depth <= 4);
    // あとのエラーは、自前の条件オブジェクトを送出する。
    try f.expectFails("not a procedure", "(1)");
    try std.testing.expect(f.ctx.raised.?.asCondition().? != condition.asCondition().?);
}

test "a call in tail position does not grow the continuation" {
    var f: Fixture = undefined;
    try f.initIn(std.heap.smp_allocator, .{});
    defer f.deinit();
    _ = try f.eval("(define (loop n) (if (= n 0) 'done (loop (- n 1))))");
    f.machine.peak_depth = 0;
    _ = try f.eval("(loop 10)");
    const small = f.machine.peak_depth;
    f.machine.peak_depth = 0;
    _ = try f.eval("(loop 10000)");
    try std.testing.expectEqual(small, f.machine.peak_depth);
    // `begin` を通しても、定義のある本体でも、渡された手続きでも、同じである。
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
    try f.initIn(std.heap.smp_allocator, .{});
    defer f.deinit();
    // 機械のスクラッチ領域は専用で、展開器が使ったものとは別である。
    var scratch: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer scratch.deinit();
    f.machine.scratch = scratch.allocator();
    _ = try f.eval("(define (loop n) (if (= n 0) 'done (begin (+ 1 2 3 4 5 6 7 8 9 10) (loop (- n 1)))))");
    _ = try f.eval("(loop 20000)");
    // 呼び出しは、実行している間だけスクラッチ領域からオペランドを取ってよく、
    // 終われば返す。領域はループとともには広がらない。
    try std.testing.expect(scratch.queryCapacity() <= 16 * 1024);
}

test "a call that is not in tail position holds a frame for each pending call" {
    var f: Fixture = undefined;
    try f.initIn(std.heap.smp_allocator, .{});
    defer f.deinit();
    _ = try f.eval("(define (count n) (if (= n 0) 0 (+ 1 (count (- n 1)))))");
    f.machine.peak_depth = 0;
    try f.expectInt(1000, "(count 1000)");
    try std.testing.expect(f.machine.peak_depth >= 1000);
    f.machine.peak_depth = 0;
    try f.expectInt(5000, "(count 5000)");
    try std.testing.expect(f.machine.peak_depth >= 5000);
}

test "slow: a recursion as deep as memory allows, and not as deep as the Zig stack does" {
    try tier.slow();
    var f: Fixture = undefined;
    try f.initIn(std.heap.smp_allocator, .{});
    defer f.deinit();
    _ = try f.eval("(define (count n) (if (= n 0) 0 (+ 1 (count (- n 1)))))");
    try f.expectInt(100_000, "(count 100000)");
}

// 以下のテストはヒープに関するものである。上のテストのプログラムを、毎ステップで
// GC する同じフィクスチャで走らせる。そのため、機械が GC の見ない場所に持っている値は、
// 運よく残るのでなく、すぐに解放される。

/// Programs and what they give, covering closures, shared variables, quoted data,
/// definitions at the start of a body and non-tail calls.
const stress_programs = [_]struct { src: []const u8, expected: i64 }{
    .{ .src = "((lambda (x y) (+ x y)) 3 4)", .expected = 7 },
    .{ .src = "(((lambda (x) (lambda (y) (+ x y))) 2) 3)", .expected = 5 },
    .{ .src = "(define make (lambda (n) (lambda () (set! n (+ n 1)) n))) (define a (make 10)) (define b (make 20)) (a) (a) (b)", .expected = 21 },
    .{ .src = "(a)", .expected = 13 },
    .{ .src = "((lambda (x) (define y (+ x 1)) (define (g) (* y 2)) (g)) 3)", .expected = 8 },
    .{ .src = "(define (fact n) (if (= n 0) 1 (* n (fact (- n 1))))) (fact 10)", .expected = 3628800 },
    .{ .src = "(define (ev? n) (if (= n 0) #t (od? (- n 1)))) (define (od? n) (if (= n 0) #f (ev? (- n 1)))) (if (ev? 100) 1 0)", .expected = 1 },
    .{ .src = "(define (id x) x) ((lambda (x) (+ (id 100) x)) 1)", .expected = 101 },
    .{ .src = "(define (loop n) (if (= n 0) 7 (loop (- n 1)))) (loop 3000)", .expected = 7 },
    .{ .src = "(define xs '(1 2 3)) (define (second l) ((lambda (rest) rest) l)) (+ 1 2 3 4 5 6 7 8 9 10)", .expected = 55 },
    .{ .src = "(define (count n) (if (= n 0) 0 (+ 1 (count (- n 1))))) (count 300)", .expected = 300 },
    // 余りの引数のリストが、フレームとクロージャを通じて、毎ステップの GC を生き延びる。
    .{ .src = "(define (sum . xs) (if (null? xs) 0 (+ (car xs) (apply-sum (cdr xs))))) (define (apply-sum l) (if (null? l) 0 (+ (car l) (apply-sum (cdr l))))) (sum 1 2 3 4 5 6 7 8 9 10)", .expected = 55 },
    .{ .src = "(define (keep . xs) (lambda () xs)) (define k (keep 4 5 6)) (car (cdr (cdr (k))))", .expected = 6 },
    // `apply` が並べ直した引数の鎖が、毎ステップの GC を生き延びる。
    .{ .src = "(define (f a b . r) (+ a b (apply + r))) (apply f 1 2 3 '(4 5))", .expected = 15 },
    .{ .src = "(apply + 1 2 3 4 5 6 7 8 9 10 (list 11))", .expected = 66 },
    .{ .src = "(define (aloop n) (if (= n 0) 9 (apply aloop (list (- n 1))))) (aloop 300)", .expected = 9 },
};

test "the programs give the same results with a collection at every step, whatever the marking list holds" {
    for ([_]usize{ 4096, 0 }) |capacity| {
        var f: Fixture = undefined;
        try f.initWith(.{ .stress = true, .work_capacity = capacity });
        defer f.deinit();
        for (stress_programs) |p| try f.expectInt(p.expected, p.src);
        // 実際に GC しており、小さなプログラムでは毎ステップで GC している。
        try std.testing.expect(f.ctx.heap.collections > 1000);
    }
}

test "the value a run gives back is still there after the collection that follows it" {
    var f: Fixture = undefined;
    try f.initWith(.{ .stress = true });
    defer f.deinit();
    // 最後の形式が作ったクロージャで、結果以外の何からも持たれていない。
    const closure = try f.eval("(lambda (x y) x)");
    try std.testing.expectEqual(2, closure.asClosure().?.lambda.arity);
    const made = try f.eval("((lambda (n) (lambda () n)) 7)");
    try std.testing.expectEqual(0, made.asClosure().?.lambda.arity);
    try std.testing.expectEqual(7, made.asClosure().?.env.?.values[0].asFixnum().?);
}

test "what a global and what the code quote hold survives the collections of a long loop" {
    var f: Fixture = undefined;
    try f.initWith(.{ .stress = true });
    defer f.deinit();
    _ = try f.eval("(define xs '(1 2 3)) (define (get) '(4 5 6)) (define k ((lambda (n) (lambda () n)) 42))");
    _ = try f.eval("(define (spin n) (if (= n 0) 0 (spin (- n 1)))) (spin 500)");
    try f.expectInt(42, "(k)");
    const xs = try f.eval("xs");
    try std.testing.expectEqual(3, xs.asPair().?.cdr.asPair().?.cdr.asPair().?.car.asFixnum().?);
    const got = try f.eval("(get)");
    try std.testing.expectEqual(4, got.asPair().?.car.asFixnum().?);
    // 毎回同じデータである。コピーでなく、コードの定数だからだ。
    try std.testing.expectEqual(got.asPair().?, (try f.eval("(get)")).asPair().?);
}

/// A loop of `long` tail calls holds the heap to a size that does not depend on
/// how long it runs, after a short one of 2000.
/// `collections` は、長いほうが起こさなければならない GC の回数である。1 回も GC
/// しないまま合格することがないようにするためだ。
fn expectBoundedHeapLoop(long: usize, collections: usize) !void {
    var f: Fixture = undefined;
    try f.initIn(std.heap.smp_allocator, .{});
    defer f.deinit();
    _ = try f.eval("(define (loop n) (if (= n 0) 'done (loop (- n 1))))");
    _ = try f.eval("(loop 2000)");
    const short = f.ctx.heap.peak;
    var src: [32]u8 = undefined;
    _ = try f.eval(try std.fmt.bufPrint(&src, "(loop {d})", .{long}));
    // ヒープに収まりきらないほど多くの呼び出しをしても、ヒープの中身は、前の量に
    // GC の1区間が許す分を足した以上にはならない。
    try std.testing.expect(f.ctx.heap.collections > collections);
    try std.testing.expect(f.ctx.heap.peak <= 2 * f.ctx.heap.options.min_threshold);
    try std.testing.expect(f.ctx.heap.peak <= short + f.ctx.heap.options.min_threshold);
    // 終わったあとに残るものは、ほとんどない。
    f.ctx.collectIdle();
    try std.testing.expect(f.ctx.heap.accounted < 4096);
}

test "a loop of tail calls holds the heap to a size that does not depend on how long it runs" {
    try expectBoundedHeapLoop(30_000, 2);
}

test "slow: a loop of two hundred thousand tail calls holds the heap to the same size" {
    try tier.slow();
    try expectBoundedHeapLoop(200_000, 10);
}

test "garbage is collected: the unreachable closures and frames of finished calls are freed" {
    var f: Fixture = undefined;
    try f.initWith(.{ .min_threshold = 64 * 1024 });
    defer f.deinit();
    _ = try f.eval("(define (make n) (lambda () n)) (define keep (make 1))");
    const before = f.ctx.heap.count;
    _ = try f.eval("(define (many n) (if (= n 0) 0 (begin (make n) (many (- n 1))))) (many 5000)");
    try std.testing.expect(f.ctx.heap.collections > 0);
    f.ctx.collectIdle();
    try std.testing.expect(f.ctx.heap.count <= before + 8);
    // まだ参照されているものは残っていて、動く。
    try f.expectInt(1, "(keep)");
}

test "a recursion that never returns ends in an error at the limit of the heap, and the next line runs" {
    var f: Fixture = undefined;
    try f.initWith(.{ .limit = 256 * 1024, .min_threshold = 16 * 1024 });
    defer f.deinit();
    _ = try f.eval("(define (forever n) (+ 1 (forever n)))");
    try f.expectFails("heap limit exceeded", "(forever 0)");
    // Why: 上限に当たった確保のあとで作る条件は、送出のための予約から取るので、上限を
    // 予約の分だけ超えうる(ADR-0035)。予約を除いた部分は上限に収まる。
    try std.testing.expect(f.ctx.heap.peak <= 256 * 1024 + f.ctx.heap.options.raise_reserve);
    try f.expectInt(3, "(+ 1 2)");
    // その前に作った大域変数はまだあり、エラーはまた起こりうる。
    _ = try f.eval("(define (id x) x)");
    try f.expectFails("heap limit exceeded", "(forever 0)");
    try f.expectInt(5, "(id 5)");
    // 戻ってくる深い再帰は、上限が許すなら、やはり戻ってくる。
    _ = try f.eval("(define (count n) (if (= n 0) 0 (+ 1 (count (- n 1)))))");
    try f.expectInt(500, "(count 500)");
}

test "a recursion that never returns reaches the limit with few collections, because the collection that leaves no room ends the line" {
    var f: Fixture = undefined;
    try f.initWith(.{ .limit = 256 * 1024, .min_threshold = 16 * 1024 });
    defer f.deinit();
    _ = try f.eval("(define (forever n) (+ 1 (forever n)))");
    try f.expectFails("heap limit exceeded", "(forever 0)");
    // しきい値は、ソフトな上限まで倍々に増える。そのために数回の GC がかかる。
    // GC のあとの検査がなければ、上限の近くでは毎ステップでまた GC し、確保が
    // 失敗するまで続く。
    try std.testing.expect(f.ctx.heap.collections <= 40);
    try std.testing.expect(f.ctx.heap.exhausted);
}

test "a single allocation the limit refuses is the same error" {
    var f: Fixture = undefined;
    // リーダのペアと、数個のフレームぶんだけの余裕。
    try f.initWith(.{ .limit = 2048, .min_threshold = 1024 });
    defer f.deinit();
    _ = try f.eval("(define (wide a b c d e f g h) h)");
    try f.expectFails("heap limit exceeded", "(define (forever n) (+ 1 (forever n))) (forever 0)");
}
