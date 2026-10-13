//! The CEK machine: the only place evaluation advances
//! (docs/design/architecture.md, ADR-0004).
//!
//! レジスタは 5 つある。実行する節点(制御)、実行中の手続きのフレーム(環境)、
//! 値をどうするかを表すフレームの連なり(継続)、直前に作られた値、動的状態の最も内側の
//! 点(スライス 2d。現在の例外ハンドラはここから導く、ADR-0016)である。ステップは、
//! 制御にある節点を分解するか、値を継続の先頭のフレームに渡すかのどちらかをする。
//! そのため、ここには Zig のスタックで再帰するものがなく、プログラムはメモリの
//! 許す限り深くなれる。
//!
//! 継続のフレームは、一度作ったら変えない。末尾位置の呼び出しにフレームは要らない。
//! 手続きの本体は呼び出し元の継続のもとで走り、列の最後の節点と `if` のどちらの枝も、
//! 自分のフレームが外れてから走る。
//!
//! ヒープは2つのステップの間で GC し、ステップの中では GC しない(ADR-0031)。その時点で
//! プログラムが持っているものは、コンテキストのルートの表(大域変数のセル、コードの
//! 定数、送出された値)を除けばレジスタがすべてである。だから GC にほかのルートは
//! 要らない(ADR-0035)。

const std = @import("std");
const tier = @import("tier.zig");
const value_mod = @import("value.zig");
const Value = value_mod.Value;
const Node = value_mod.Node;
const Frame = value_mod.Frame;
const Closure = value_mod.Closure;
const Kont = value_mod.Kont;
const Args = value_mod.Args;
const DynPoint = value_mod.DynPoint;
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

    /// What the machine holds between two steps: the registers, and whether
    /// it has reported a heap left without room.
    const Registers = struct {
        /// The node to run next, or null when the value goes to the
        /// continuation.
        control: ?*const Node,
        env: ?*Frame = null,
        kont: ?*const Kont = null,
        value: Value = .unspecified_value,
        /// The innermost point of the dynamic state (ADR-0016).
        dyn: ?*const DynPoint = null,
        /// Whether a collection has found the heap without room, the machine
        /// raised "heap limit exceeded" for it, and no collection since has
        /// found room.
        /// Why: 上限超過をハンドラで捕まえられるようにするためである。余裕の無さを見つけた
        /// GC のあとも、深い継続はハンドラの戻りのフレームから辿れるので、ハンドラの次の
        /// ステップの GC がまた余裕の無さを見つける。そのたびに送出すると、ハンドラは1歩も
        /// 進めずに外側へ送出し直す。報告は余裕ができるまで1度にし、その間も確保は上限
        /// (`Budget.limit`)で断られる。生きている量がソフトな上限以上なら、その間は
        /// ステップごとに GC が走り、毎回ほぼヒープの全体をマークする。ハンドラの作るごみは
        /// 回収されるので、この状態はハンドラが戻るか送出し直すか、GC が余裕を見つける
        /// まで続く。2d には継続での脱出が無いので、深い継続はその間ずっと残る。
        limit_reported: bool = false,
    };

    /// Runs `node` to its value.
    /// 送出された値は、現在の例外ハンドラに渡す。ハンドラが無ければ、送出された値を
    /// `ctx.raised` に置いて `error.Raised` を返す。
    pub fn run(self: *Machine, root: *const Node) Error!Value {
        var regs: Registers = .{ .control = root };
        while (true) {
            if (self.steps(&regs)) |v| return v else |e| if (e != error.Raised) return e;
            // Why: 送出の地点は、ステップの中のどこでも `ctx.raise` を返せばよい。値をハンドラ
            // に渡すのは、レジスタを書き戻したここ1か所である。機械が検出する失敗(型の誤り、
            // 未束縛の変数、上限超過など)も、こうして機械の中の `raise` になる(計画 0014 の
            // 合意を求める点の2)。
            try self.handOver(&regs);
        }
    }

    /// Hands what was raised, which is in `ctx.raised`, to the current
    /// handler, as `raise` does.
    /// ハンドラを呼ぶこと自体が送出すれば(ハンドラが手続きでない、引数の個数が合わない
    /// など)、その値を同じように渡す。そのときの列はハンドラ切り替えの点を積んだあとなので、
    /// 外側のハンドラに届き、周回は止まる。ハンドラが無ければ、値を `ctx.raised` に戻して
    /// `error.Raised` を返す。
    fn handOver(self: *Machine, regs: *Registers) Error!void {
        const ctx = self.ctx;
        while (true) {
            const raised = ctx.raised.?;
            ctx.raised = null;
            if (self.callHandler(regs, raised)) |handled| {
                if (handled) return;
                ctx.raised = raised;
                return error.Raised;
            } else |e| if (e != error.Raised) return e;
        }
    }

    /// Calls the current handler with `raised`, for a `raise`; false when
    /// there is no handler.
    fn callHandler(self: *Machine, regs: *Registers, raised: Value) Error!bool {
        const call = try self.enterHandler(&regs.kont, &regs.dyn, raised, false) orelse return false;
        // 送出した時点の制御と値は捨てる。GC が余裕の無さを見つけた時点では、制御に節点が
        // 残っている。
        regs.control = null;
        regs.env = null;
        regs.value = .unspecified_value;
        switch (try self.apply(&regs.kont, &regs.dyn, call, 1, .raise_reserve)) {
            .value => |v| regs.value = v,
            .body => |entry| {
                regs.env = entry.env;
                regs.control = entry.body;
            },
        }
        return true;
    }

    /// Puts on what calling the current handler with `raised` needs, and
    /// returns the call: `raised`, then the handler. Null when there is no
    /// handler; nothing is put on then.
    /// 継続にハンドラの戻りのフレームを積み、列にハンドラ切り替えの点を積む。切り替え先は、
    /// 呼ぶハンドラを置いた時点で現在だったハンドラで、ハンドラの中の送出はそこに届く
    /// (ADR-0016)。確保はすべて送出のための予約から行い、2つのレジスタを書き換える前に
    /// 済ませる。
    fn enterHandler(self: *Machine, kont: *?*const Kont, dyn: *?*const DynPoint, raised: Value, continuable: bool) Error!?*const Args {
        const ctx = self.ctx;
        const handler = value_mod.currentHandler(dyn.*) orelse return null;
        const outer = value_mod.currentHandler(handler.parent);
        const shift = try ctx.createIn(.raise_reserve, DynPoint, .{
            .parent = dyn.*,
            .depth = value_mod.depthAbove(dyn.*),
            .current_handler = outer,
            .kind = .{ .handler_shift = outer },
        });
        const procedure = try ctx.createIn(.raise_reserve, Args, .{ .value = handler.kind.handler, .next = null });
        const call = try ctx.createIn(.raise_reserve, Args, .{ .value = raised, .next = procedure });
        kont.* = try self.pushIn(.raise_reserve, kont.*, null, .{ .handler_return = .{
            .dyn = dyn.*,
            .raised = raised,
            .continuable = continuable,
        } });
        dyn.* = shift;
        return call;
    }

    /// Runs steps from the registers in `regs` until the program ends or an
    /// error is raised, and leaves the registers in `regs` either way.
    /// Why: レジスタを局所変数に置くのは、ステップの本体が `ctx.raise` を `return` する形の
    /// まま、送出の時点のレジスタを `run` に渡すためである。`defer` はエラーで抜けるときも
    /// 走る。
    fn steps(self: *Machine, regs: *Registers) Error!Value {
        const ctx = self.ctx;
        var control = regs.control;
        var env = regs.env;
        var kont = regs.kont;
        var value = regs.value;
        var dyn = regs.dyn;
        defer {
            regs.control = control;
            regs.env = env;
            regs.kont = kont;
            regs.value = value;
            regs.dyn = dyn;
        }
        while (true) {
            if (ctx.heap.shouldCollect()) try self.collect(.{ .ctx = ctx, .env = env, .kont = kont, .value = value, .dyn = dyn }, &regs.limit_reported);
            if (control) |node| {
                control = null;
                switch (node.*) {
                    .constant => |v| value = v,
                    .local_ref => |*r| {
                        const slot = slotAt(env, r.address);
                        if (slot.kind() == .uninitialized) return self.uninitialized(r.name);
                        value = slot.*;
                    },
                    .global_ref => |cell| {
                        if (cell.value.kind() == .uninitialized) return self.unbound(cell.name);
                        value = cell.value;
                    },
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
                        // `set!` は変数を作らない。未束縛の変数への代入はエラーである。
                        if (a.cell.value.kind() == .uninitialized) return self.unbound(a.cell.name);
                        a.cell.value = value;
                        value = .unspecified_value;
                    },
                    .global_define => |a| {
                        a.cell.value = value;
                        value = .unspecified_value;
                    },
                    .call => |c| {
                        const args = try ctx.create(Args, .{ .value = value, .next = c.args });
                        const received = c.received + 1;
                        if (received <= c.call.operands.len) {
                            kont = try self.push(kont, env, .{ .call = .{ .call = c.call, .args = args, .received = received } });
                            control = c.call.operands[received - 1];
                        } else switch (try self.apply(&kont, &dyn, args, received - 1, .limit)) {
                            .value => |v| value = v,
                            // 末尾呼び出し: 本体は呼び出しの継続のもとで走る。その継続は
                            // `kont` に残っているものである。
                            .body => |entry| {
                                env = entry.env;
                                control = entry.body;
                            },
                        }
                    },
                    // 値は、そのまま次のフレームに渡る。
                    .dynamic_exit => |saved| dyn = saved,
                    .handler_return => |h| {
                        if (!h.continuable) return self.handlerReturned(h.raised);
                        // `raise-continuable` のハンドラが戻った。積んだ切り替えの点を外し、
                        // そのハンドラを再び現在のハンドラにする(R7RS 6.11)。
                        dyn = h.dyn;
                    },
                }
            }
        }
    }

    /// Raises the secondary exception of a handler that returned from a
    /// `raise` (R7RS 6.11), with what was raised as its irritant.
    /// 列はハンドラを呼んだときのままなので、二次例外はハンドラと同じ動的環境で送出され、
    /// 外側のハンドラに届く。条件と irritant は、送出のための予約から作る。
    fn handlerReturned(self: *Machine, raised: Value) Error {
        const ctx = self.ctx;
        const irritant = try ctx.createIn(.raise_reserve, value_mod.Pair, .{ .car = raised, .cdr = .empty_list_value });
        ctx.raised = try ctx.makeCondition(.@"error", "handler returned from non-continuable raise", .{}, .{ .pair = irritant });
        return error.Raised;
    }

    const Applied = union(enum) {
        value: Value,
        body: struct { env: *Frame, body: *const Node },
    };

    /// Applies the operator at the end of `args` to the `count` operands before
    /// it, in the continuation `kont` and at the dynamic point `dyn`.
    /// 純粋プリミティブは値を返す。クロージャは、呼び出しのフレームと、そのフレームで
    /// 走らせる本体を返す。機械操作プリミティブは、継続と動的点を書き換えてよく、別の
    /// 呼び出しに置き換わる。置き換わった呼び出しは、ここでもう一度適用する。クロージャの
    /// フレームと余りの引数のリストは `budget` から確保する。ハンドラの呼び出しは送出の
    /// ための予約から確保する(docs/design/runtime.md の送出のための予約領域)。
    fn apply(self: *Machine, kont: *?*const Kont, dyn: *?*const DynPoint, initial_args: *const Args, initial_count: usize, initial_budget: heap_mod.Budget) Error!Applied {
        const ctx = self.ctx;
        var args = initial_args;
        var count = initial_count;
        var budget = initial_budget;
        // Why: `apply` の被呼び出し側を、Zig の再帰でなく周回で適用する。`apply` で `apply`
        // を呼ぶ入れ子は、データから好きなだけ深く作れるので、再帰にすると Zig のスタックを
        // 使い切りうる。ただし周回は1ステップの中で回るので、その間にできたごみは回収
        // されない。この制約と直す時期は、ADR-0031 の 2026-10-13 の追記にある。
        const operator = while (true) {
            var operator_node = args;
            while (operator_node.next) |n| operator_node = n;
            const operator = operator_node.value;
            const prim = operator.asPrimitive() orelse break operator;
            // 表の範囲の検査はここにしかない。プリミティブの本体は、`args` が表の範囲に
            // 収まることを前提にしてよい。個数がほかの引数で決まるもの(`%make-record`)は、
            // 本体が検査する(`PrimitiveError.WrongArgumentCount` を参照)。
            if (!prim.acceptsCount(count)) return primitiveFailure(ctx, prim, error.WrongArgumentCount, args, count);
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
                        budget = .limit;
                    },
                    .with_exception_handler => {
                        args = try self.installHandler(prim, kont, dyn, args);
                        count = 0;
                        budget = .limit;
                    },
                    // 送出された値は `run` がハンドラに渡す。機械が検出する失敗と同じ経路である。
                    .raise => {
                        ctx.raised = args.value;
                        return error.Raised;
                    },
                    .@"error" => {
                        ctx.raised = try self.makeError(prim, args, count);
                        return error.Raised;
                    },
                    .raise_continuable => {
                        args = try self.enterHandler(kont, dyn, args.value, true) orelse {
                            ctx.raised = args.value;
                            return error.Raised;
                        };
                        count = 1;
                        budget = .raise_reserve;
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
        const frame = try ctx.createFrameIn(budget, lambda.frame_size, closure.env);
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
                // Why: 新しいペアを一時変数に受けてから `list` に入れる。`list = .{ .pair = ... }`
                // と書くと、結果の置き場所が `list` そのものになり、`.cdr = list` を読む前に
                // `list` が書き換わりうる。
                const cell = try ctx.createIn(budget, value_mod.Pair, .{ .car = required.value, .cdr = list });
                list = .{ .pair = cell };
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
        return call(&services, operands) catch |e| return primitiveFailure(ctx, prim, e, args, count);
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
        const length = pair.properLength(list) orelse return primitiveFailure(ctx, prim, error.WrongType, args, count);
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

    /// What `(with-exception-handler handler thunk)` does (R7RS 6.11): puts a
    /// handler point on the dynamic state, and a frame that takes it off when
    /// `thunk` returns, and returns the call of `thunk`.
    /// `args` は `thunk`、`handler`、`prim` の順に並ぶ。`thunk` は末尾位置で呼ばない。
    /// 戻ったら点を外すフレームが残るからである。確保を済ませてから2つのレジスタを書き換える。
    fn installHandler(self: *Machine, prim: *const value_mod.Primitive, kont: *?*const Kont, dyn: *?*const DynPoint, args: *const Args) Error!*const Args {
        const ctx = self.ctx;
        const thunk = args.value;
        const handler = args.next.?.value;
        // 手続きでないハンドラは、送出のときでなく、ここで型の誤りにする。送出のときに
        // 見つけると、どの送出が誤りを生んだかが分からない。
        if (!isProcedure(handler) or !isProcedure(thunk)) return primitiveFailure(ctx, prim, error.WrongType, args, 2);
        const point = try ctx.create(DynPoint, .{
            .parent = dyn.*,
            .depth = value_mod.depthAbove(dyn.*),
            .current_handler = null,
            .kind = .{ .handler = handler },
        });
        // ハンドラの点では、現在のハンドラはその点自身である(ADR-0016)。
        point.current_handler = point;
        const call = try ctx.create(Args, .{ .value = thunk, .next = null });
        kont.* = try self.push(kont.*, null, .{ .dynamic_exit = dyn.* });
        dyn.* = point;
        return call;
    }

    /// The condition `(error message obj ...)` makes: the message, and the
    /// objects after it as a new list (R7RS 6.11).
    /// `args` は最後のオペランドから並び、末尾に `prim` がある。メッセージの文字列は
    /// 写さずに共有する。確保は利用者の確保と同じく上限に従う。予約から取らないのは、
    /// irritant の数が呼び出しで決まり、予約で賄える量に収まらないからである。
    fn makeError(self: *Machine, prim: *const value_mod.Primitive, args: *const Args, count: usize) Error!Value {
        const ctx = self.ctx;
        var message_node = args;
        for (0..count - 1) |_| message_node = message_node.next.?;
        const message = message_node.value;
        // 確保より前に検査する。
        if (message.asString() == null) return primitiveFailure(ctx, prim, error.WrongType, args, count);
        // 最後のオペランドから順に前へ継ぎ足すと、書いた順のリストになる。
        var irritants: Value = .empty_list_value;
        var it = args;
        while (it != message_node) : (it = it.next.?) {
            const cell = try ctx.create(value_mod.Pair, .{ .car = it.value, .cdr = irritants });
            irritants = .{ .pair = cell };
        }
        const condition = try ctx.create(value_mod.Condition, .{ .kind = .@"error", .message = message, .irritants = irritants });
        return .fromCondition(condition);
    }

    /// The error a failure of `prim` called with the `count` operands in
    /// `args` is: a condition with the message the failure has and the
    /// operands as its irritants, or the failure of the host as it is.
    /// `args` は最後のオペランドから並ぶ(末尾に演算子があってもよい)。
    fn primitiveFailure(ctx: *Context, prim: *const value_mod.Primitive, e: value_mod.PrimitiveError, args: *const Args, count: usize) Error {
        const irritants = switch (e) {
            // ヒープの失敗は、ほかの経路と同じ文言になるよう `Context` を通す。
            error.HeapLimit, error.OutOfMemory => |heap_error| return ctx.heapFailure(heap_error),
            else => try operandList(ctx, args, count),
        };
        return switch (e) {
            error.WrongType => raiseWith(ctx, irritants, "wrong type of argument to {s}", .{prim.name}),
            error.IntegerOverflow => raiseWith(ctx, irritants, "integer overflow in {s}", .{prim.name}),
            error.WrongArgumentCount => raiseWith(ctx, irritants, "wrong number of arguments to {s}", .{prim.name}),
            error.DivisionByZero => raiseWith(ctx, irritants, "division by zero in {s}", .{prim.name}),
            error.OutOfRange => raiseWith(ctx, irritants, "argument out of range in {s}", .{prim.name}),
            error.HeapLimit, error.OutOfMemory => unreachable,
        };
    }

    /// The `count` operands in `args` as a new list, in the order they were
    /// written; the empty list when the heap has no room for it.
    /// Why: リストは上限に従って確保し、予約から取らない。長さが呼び出しの引数の数で決まり、
    /// 予約で賄える量に収まらないからである(ADR-0035 の見直し条件)。上限に当たったときは
    /// irritant を諦め、条件とメッセージだけを予約から作る。失敗の報告を、上限超過に
    /// すり替えないためである。
    fn operandList(ctx: *Context, args: *const Args, count: usize) error{OutOfMemory}!Value {
        var list: Value = .empty_list_value;
        var it = args;
        for (0..count) |_| {
            const cell = ctx.heap.create(value_mod.Pair, .{ .car = it.value, .cdr = list }) catch |e| switch (e) {
                error.HeapLimit => return .empty_list_value,
                error.OutOfMemory => return error.OutOfMemory,
            };
            list = .{ .pair = cell };
            it = it.next orelse break;
        }
        return list;
    }

    /// Raises a condition with the message `fmt` formatted with `args` and
    /// the list `irritants`.
    fn raiseWith(ctx: *Context, irritants: Value, comptime fmt: []const u8, args: anytype) Error {
        ctx.raised = try ctx.makeCondition(.@"error", fmt, args, irritants);
        return error.Raised;
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
        return self.pushIn(.limit, next, env, step);
    }

    /// A new frame on top of `next`, held to `budget`.
    fn pushIn(self: *Machine, budget: heap_mod.Budget, next: ?*const Kont, env: ?*Frame, step: Kont.Step) Error!*const Kont {
        const depth = (if (next) |n| n.depth else 0) + 1;
        const k = try self.ctx.createIn(budget, Kont, .{ .next = next, .env = env, .depth = depth, .step = step });
        if (depth > self.peak_depth) self.peak_depth = depth;
        return k;
    }

    /// Collects, with the registers as the roots.
    /// 生きているものを除いてもなお余裕がないときは、ここで "heap limit exceeded" を送出する。
    /// どこかの確保で送出すると、ヒープは同じ余裕を何度も求められることになる。送出は、
    /// 余裕ができるまで1度だけにする(`Registers.limit_reported`)。
    fn collect(self: *Machine, roots: Roots, reported: *bool) Error!void {
        const ctx = self.ctx;
        ctx.heap.collect(roots);
        if (!ctx.heap.exhausted) {
            reported.* = false;
            return;
        }
        if (reported.*) return;
        reported.* = true;
        return ctx.raise(context.heap_limit_message, .{});
    }

    /// What the program holds at a safe point.
    const Roots = struct {
        ctx: *const Context,
        env: ?*Frame,
        kont: ?*const Kont,
        value: Value,
        dyn: ?*const DynPoint,

        pub fn mark(self: Roots, marker: *heap_mod.Marker) void {
            marker.value(self.value);
            marker.frame(self.env);
            marker.kont(self.kont);
            marker.dynPoint(self.dyn);
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

/// Whether `v` can be applied.
fn isProcedure(v: Value) bool {
    return v.asClosure() != null or v.asPrimitive() != null;
}

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
                self.ctx.heap.collect(Machine.Roots{ .ctx = &self.ctx, .env = null, .kont = null, .value = last, .dyn = null });
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

test "a define or a set! of a primitive that fails leaves the name with the primitive" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    // 遮蔽するセルは、展開の時点で、元の値で始まる(src/env.zig)。値の式が失敗しても、
    // 名前はプリミティブを指したままである。
    try f.expectFails("unbound variable: nope", "(define car (nope))");
    try f.expectInt(1, "(car '(1 2))");
    try f.expectFails("unbound variable: nope", "(set! cdr (nope))");
    try f.expectInt(2, "(car (cdr '(1 2)))");
    // 特殊形式の名前には元の値が無いので、値の式が実行時に失敗した定義の後は、
    // 未束縛の変数である(展開は成功しているので、遮蔽は戻らない)。
    try f.expectFails("unbound variable: nope", "(define if (nope))");
    try f.expectFails("unbound variable: if", "if");
}

test "a define of a special form's name whose expansion fails leaves the special form" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.expectFails("bad quote: expected (quote datum)", "(define if (quote))");
    try f.expectInt(1, "(if #t 1 2)");
    // 略記の定義の本体の展開が失敗しても同じである。
    try f.expectFails("bad quote: expected (quote datum)", "(define (lambda x) (quote))");
    try f.expectInt(7, "((lambda (y) y) 7)");
    // 同じ形式の中の後ろの部分の展開が失敗したときも、その形式の遮蔽は戻る。
    try f.expectFails("bad quote: expected (quote datum)", "(begin (define begin 1) (quote))");
    try f.expectInt(3, "(begin 1 3)");
    // 展開が成功した定義の遮蔽は残る。
    try f.expectInt(5, "(define if 5) if");
    try f.expectFails("not a procedure", "(if 1 2)");
}

test "a global's cell holds what the definition gives it, across forms" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    // docs/design/frontend.md の REPL の表の例。3つ目の定義は、`pong` が指すセルに代入する。
    _ = try f.eval("(define (ping n) (if (= n 0) 'done (pong (- n 1))))");
    _ = try f.eval("(define (pong n) (ping n))");
    _ = try f.eval("(define (ping n) 'fixed)");
    const fixed = try f.eval("(pong 2)");
    try std.testing.expectEqualStrings("fixed", f.ctx.symbols.nameOf(fixed.asSymbol().?));
    // プリミティブの再定義は、先に定義した手続きに見えない。
    _ = try f.eval("(define (first xs) (car xs))");
    _ = try f.eval("(define (car xs) 99)");
    try f.expectInt(1, "(first '(1 2))");
    try f.expectInt(99, "(car '(1 2))");
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

test "an apply whose operands just fill the buffer on the stack does not grow the scratch space" {
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
    const greedy: value_mod.Primitive = .{ .name = "greedy", .min_args = 0, .max_args = null, .body = .{ .pure = &fill } };

    fn fill(services: *const value_mod.Services, _: []const Value) value_mod.PrimitiveError!Value {
        var list: Value = .empty_list_value;
        while (true) list = services.heap.cons(.fromFixnum(1), list) catch |e| return fill_failure orelse e;
    }

    /// What `greedy` fails with once the limit refuses, instead of the
    /// refusal itself.
    /// ヒープが満杯の状態で、ヒープの失敗でない失敗を報告させるためにある。
    var fill_failure: ?value_mod.PrimitiveError = null;

    fn reset() void {
        calls = 0;
        heap = null;
        scratch = null;
        failure = null;
        fill_failure = null;
    }

    fn bind(f: *Fixture) !void {
        for ([_]*const value_mod.Primitive{ &primitive, &variadic, &nullary, &greedy }) |p| {
            const id = try f.ctx.symbols.intern(f.ctx.persist, p.name);
            try f.ctx.globals.importPrimitive(f.ctx.persist, id, p);
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
    // ハンドラの点は、動的点のレジスタからしか辿れない。毎ステップの GC を、本体の深い
    // 再帰の間も生き延びる。
    .{ .src = "(define (down n) (if (= n 0) (raise-continuable 0) (+ 1 (down (- n 1))))) (with-exception-handler (lambda (c) 100) (lambda () (down 300)))", .expected = 400 },
    .{ .src = "(with-exception-handler (lambda (c) (* c 2)) (lambda () (+ (raise-continuable 1) (raise-continuable 10))))", .expected = 22 },
    .{ .src = "(with-exception-handler (lambda (c) (+ c 100)) (lambda () (with-exception-handler (lambda (c) (raise-continuable (+ c 10))) (lambda () (raise-continuable 1)))))", .expected = 111 },
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

// 以下は例外のテストである。番号は docs/design/runtime.md の例外の節の「テストに含める
// 事例」のものである。ハンドラが周回しうるテストは小さな上限で走らせる。切り替え先を
// 取り違える誤りが、止まらないのでなく、上限か予約の枯渇で失敗するようにするためである。

/// The options of the tests whose handlers could go round for ever if the
/// machine had them wrong.
const small_heap: heap_mod.Options = .{ .limit = 256 * 1024, .min_threshold = 16 * 1024 };

/// The message of the condition that `src` evaluates to.
fn conditionMessage(f: *Fixture, src: []const u8) ![]const u8 {
    const v = try f.eval(src);
    const c = v.asCondition() orelse return error.TestUnexpectedResult;
    return c.messageText();
}

test "a handler that returns gives the value of raise-continuable" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.expectInt(42, "(with-exception-handler (lambda (c) 42) (lambda () (raise-continuable 'oops)))");
    // 事例5: ハンドラが戻ると、そのハンドラが再び現在のハンドラである。2回目の送出も同じ
    // ハンドラに届く。
    try f.expectInt(22, "(with-exception-handler (lambda (c) (* c 2)) (lambda () (+ (raise-continuable 1) (raise-continuable 10))))");
    // 本体が戻ると、ハンドラは外れる。そのあとの送出には、ハンドラが無い。
    try std.testing.expectError(error.Raised, f.eval("(+ (with-exception-handler (lambda (c) 1) (lambda () 2)) (raise-continuable 5))"));
    try std.testing.expectEqual(5, f.ctx.raised.?.asFixnum().?);
    // 本体の値は、そのまま `with-exception-handler` の値になる。
    try f.expectInt(7, "(with-exception-handler (lambda (c) 0) (lambda () 7))");
}

test "a handler that raises reaches the handler outside it, and does not go round" {
    var f: Fixture = undefined;
    try f.initWith(small_heap);
    defer f.deinit();
    // 事例6: 内側のハンドラの中の送出は、外側のハンドラに届く。外側のハンドラの値が、
    // 内側のハンドラの送出の値になり、それが元の送出の値になる。
    try f.expectInt(111,
        \\(with-exception-handler (lambda (c) (+ c 100))
        \\  (lambda () (with-exception-handler (lambda (c) (raise-continuable (+ c 10)))
        \\    (lambda () (raise-continuable 1)))))
    );
    // ハンドラが機械操作プリミティブでも同じである。
    try f.expectInt(16,
        \\(with-exception-handler (lambda (c) (+ c 1))
        \\  (lambda () (with-exception-handler raise-continuable
        \\    (lambda () (+ 10 (raise-continuable 5))))))
    );
    // 外側にハンドラが無ければ、内側のハンドラの中の送出は未処理になる。
    try std.testing.expectError(error.Raised, f.eval("(with-exception-handler raise (lambda () (raise-continuable 5)))"));
    try std.testing.expectEqual(5, f.ctx.raised.?.asFixnum().?);
    try f.expectInt(3, "(+ 1 2)");
}

test "a raise with no handler leaves the machine with what was raised, and the next line runs" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    // 事例7と事例11: 列が空の状態の送出は、条件オブジェクトでない値でも未処理として返る。
    try std.testing.expectError(error.Raised, f.eval("(raise 'oops)"));
    try std.testing.expectEqualStrings("oops", f.ctx.symbols.nameOf(f.ctx.raised.?.asSymbol().?));
    try std.testing.expectError(error.Raised, f.eval("(raise 42)"));
    try std.testing.expectEqual(42, f.ctx.raised.?.asFixnum().?);
    try std.testing.expectError(error.Raised, f.eval("(raise-continuable 43)"));
    try std.testing.expectEqual(43, f.ctx.raised.?.asFixnum().?);
    try f.expectInt(3, "(+ 1 2)");
}

test "a handler that returns from a raise raises a secondary exception, in the dynamic environment of the handler" {
    var f: Fixture = undefined;
    try f.initWith(small_heap);
    defer f.deinit();
    try f.expectFails("handler returned from non-continuable raise", "(with-exception-handler (lambda (c) 42) (lambda () (raise 'oops)))");
    // 二次例外の irritant は、送出された値である。
    const irritants = f.ctx.raised.?.asCondition().?.irritants.asPair().?;
    try std.testing.expectEqualStrings("oops", f.ctx.symbols.nameOf(irritants.car.asSymbol().?));
    try std.testing.expectEqual(value_mod.Kind.empty_list, irritants.cdr.kind());
    // 二次例外は外側のハンドラに届き、戻ったハンドラ自身には届かない。
    _ = try f.eval("(define got #f)");
    try f.expectFails("handler returned from non-continuable raise",
        \\(with-exception-handler (lambda (c) (set! got c) 7)
        \\  (lambda () (with-exception-handler (lambda (c) 42) (lambda () (raise 'oops)))))
    );
    try std.testing.expectEqualStrings("handler returned from non-continuable raise", try conditionMessage(&f, "got"));
    // 内側のハンドラが `raise` で外側に送り、外側のハンドラが戻ると、二次例外になる。
    try f.expectFails("handler returned from non-continuable raise",
        \\(with-exception-handler (lambda (c) 'outer)
        \\  (lambda () (with-exception-handler (lambda (c) (raise 'again)) (lambda () (raise 'first)))))
    );
    const again = f.ctx.raised.?.asCondition().?.irritants.asPair().?.car;
    try std.testing.expectEqualStrings("again", f.ctx.symbols.nameOf(again.asSymbol().?));
}

test "the errors the machine finds reach the handler as conditions" {
    var f: Fixture = undefined;
    try f.initWith(small_heap);
    defer f.deinit();
    _ = try f.eval("(define got #f)");
    const cases = [_]struct { body: []const u8, message: []const u8 }{
        // 事例8: 純粋プリミティブの型の誤り。
        .{ .body = "(car 5)", .message = "wrong type of argument to car" },
        .{ .body = "(+ 1 nope)", .message = "unbound variable: nope" },
        .{ .body = "(5 1)", .message = "not a procedure" },
        .{ .body = "((lambda (x) x))", .message = "wrong number of arguments: expected 1, got 0" },
        .{ .body = "(car)", .message = "wrong number of arguments to car" },
        .{ .body = "((lambda () (define a b) (define b 1) a))", .message = "variable used before its definition: b" },
        .{ .body = "(apply + 1 2)", .message = "wrong type of argument to apply" },
    };
    for (cases) |c| {
        var src: [256]u8 = undefined;
        const line = try std.fmt.bufPrint(&src, "(with-exception-handler (lambda (c) (set! got c) 0) (lambda () {s}))", .{c.body});
        // `raise` と同じく、ハンドラが戻ると二次例外になる。
        try f.expectFails("handler returned from non-continuable raise", line);
        try std.testing.expectEqualStrings(c.message, try conditionMessage(&f, "got"));
        _ = try f.eval("(set! got #f)");
    }
}

test "heap limit exceeded reaches the handler as a condition, and the handler can run and return" {
    var f: Fixture = undefined;
    try f.initWith(small_heap);
    defer f.deinit();
    _ = try f.eval("(define got #f) (define (forever n) (+ 1 (forever n)))");
    // ハンドラは、上限に達したヒープのまま走り、値を返す。`raise` の規定どおり、戻ることは
    // 二次例外である。
    try f.expectFails("handler returned from non-continuable raise", "(with-exception-handler (lambda (c) (set! got c) 42) (lambda () (forever 0)))");
    try std.testing.expectEqualStrings("heap limit exceeded", try conditionMessage(&f, "got"));
    // 次の行の実行も、上限超過をまた報告できる。
    try f.expectFails("heap limit exceeded", "(forever 0)");
    try f.expectInt(3, "(+ 1 2)");
}

test "with-exception-handler takes procedures, and a handler that cannot take the value does not go round" {
    var f: Fixture = undefined;
    try f.initWith(small_heap);
    defer f.deinit();
    try f.expectFails("wrong type of argument to with-exception-handler", "(with-exception-handler 5 (lambda () 1))");
    try f.expectFails("wrong type of argument to with-exception-handler", "(with-exception-handler car 5)");
    // ハンドラを呼ぶこと自体の失敗は、ハンドラの動的環境で送出されるので、そのハンドラ
    // には戻らない。
    try f.expectFails("wrong number of arguments: expected 0, got 1", "(with-exception-handler (lambda () 1) (lambda () (raise 'x)))");
    try f.expectFails("wrong number of arguments: expected 0, got 1", "(with-exception-handler (lambda () 1) (lambda () (car 5)))");
    try f.expectInt(3, "(+ 1 2)");
}

test "error raises a condition with the message and the irritants it is given" {
    var f: Fixture = undefined;
    try f.initWith(small_heap);
    defer f.deinit();
    try f.expectFails("bad thing", "(error \"bad thing\" 1 'two)");
    const c = f.ctx.raised.?.asCondition().?;
    try std.testing.expectEqual(value_mod.ConditionKind.@"error", c.kind);
    // irritant は書いた順のリストである。
    const first = c.irritants.asPair().?;
    try std.testing.expectEqual(1, first.car.asFixnum().?);
    const second = first.cdr.asPair().?;
    try std.testing.expectEqualStrings("two", f.ctx.symbols.nameOf(second.car.asSymbol().?));
    try std.testing.expectEqual(value_mod.Kind.empty_list, second.cdr.kind());
    // irritant が無ければ空リストである。ハンドラにも同じ条件が届き、`raise` と同じく、
    // ハンドラが戻ると二次例外になる。
    _ = try f.eval("(define got #f)");
    try f.expectFails("handler returned from non-continuable raise", "(with-exception-handler (lambda (c) (set! got c) 0) (lambda () (error \"plain\")))");
    const plain = (try f.eval("got")).asCondition().?;
    try std.testing.expectEqualStrings("plain", plain.messageText());
    try std.testing.expectEqual(value_mod.Kind.empty_list, plain.irritants.kind());
    // メッセージは文字列でなければならない。
    try f.expectFails("wrong type of argument to error", "(error 'oops 1)");
}

test "at the limit of the heap, the call of the handler is made from the reserve" {
    const limit = 2048;
    const src = "(with-exception-handler (lambda (c) c) (lambda () (car 5)))";
    var found = false;
    var n: usize = 0;
    while (!found) : (n += 1) {
        var f: Fixture = undefined;
        try f.initWith(.{ .limit = limit, .min_threshold = limit });
        defer f.deinit();
        fillKept(&f, n) catch break;
        if (f.eval(src)) |_| return error.TestUnexpectedResult else |e| switch (e) {
            error.Raised => {},
            // ハンドラを置く前に上限に当たるほど埋まった。これより先の量は試せない。
            error.ReserveExhausted => break,
            else => return e,
        }
        // ハンドラは送出された条件を返し、`raise` の規定どおり二次例外になる。ハンドラを
        // 置く確保が上限に当たった量では、ハンドラが置かれずに別のエラーになる。
        if (!std.mem.eql(u8, "handler returned from non-continuable raise", f.ctx.diagnostic())) continue;
        // ハンドラに渡ったのは、上限に達したことか型の誤りを表す条件である。
        const original = f.ctx.raised.?.asCondition().?.irritants.asPair().?.car.asCondition().?;
        try std.testing.expect(original.message.asString() != null);
        // 上限を超えて確保した量で、ハンドラの呼び出しまで予約から取ったことを確かめる。
        // 条件とメッセージだけなら超えない量を、ハンドラの切り替えの点が超える。
        if (f.ctx.heap.peak <= limit + heap_mod.cellBytes(value_mod.Condition) + heap_mod.cellBytes(value_mod.String) + 64) continue;
        found = true;
        try std.testing.expect(f.ctx.heap.peak <= limit + f.ctx.heap.options.raise_reserve);
        // 対照: 予約が無ければ、同じ量でハンドラを呼べない。
        var g: Fixture = undefined;
        try g.initWith(.{ .limit = limit, .min_threshold = limit, .raise_reserve = 0 });
        defer g.deinit();
        try fillKept(&g, n);
        try std.testing.expectError(error.ReserveExhausted, g.eval(src));
    }
    try std.testing.expect(found);
}

/// Writes the irritants of the condition raised, separated by spaces.
fn irritantsText(f: *Fixture, buf: []u8) ![]const u8 {
    var w: std.Io.Writer = .fixed(buf);
    var it = f.ctx.raised.?.asCondition().?.irritants;
    while (it.asPair()) |p| : (it = p.cdr) {
        if (w.end != 0) try w.writeByte(' ');
        try @import("printer.zig").write(&w, std.testing.allocator, &f.ctx.symbols, p.car);
    }
    return w.buffered();
}

test "the condition of a primitive's failure has the arguments of the call as its irritants" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    var buf: [128]u8 = undefined;
    const cases = [_]struct { src: []const u8, message: []const u8, irritants: []const u8 }{
        .{ .src = "(car 5)", .message = "wrong type of argument to car", .irritants = "5" },
        .{ .src = "(+ 1 #t \"x\")", .message = "wrong type of argument to +", .irritants = "1 #t \"x\"" },
        .{ .src = "(car 1 2)", .message = "wrong number of arguments to car", .irritants = "1 2" },
        .{ .src = "(car)", .message = "wrong number of arguments to car", .irritants = "" },
        .{ .src = "(vector-ref (vector 'a) 1)", .message = "argument out of range in vector-ref", .irritants = "#(a) 1" },
        // `apply` が並べ直した引数が、失敗したプリミティブの引数である。
        .{ .src = "(apply + 1 '(2 a))", .message = "wrong type of argument to +", .irritants = "1 2 a" },
        // `apply` 自身の失敗の irritant は、`apply` に渡された引数である。
        .{ .src = "(apply + 1 2)", .message = "wrong type of argument to apply", .irritants = "#<procedure +> 1 2" },
        .{ .src = "(with-exception-handler 5 car)", .message = "wrong type of argument to with-exception-handler", .irritants = "5 #<procedure car>" },
        .{ .src = "(error 'oops 1)", .message = "wrong type of argument to error", .irritants = "oops 1" },
    };
    for (cases) |c| {
        try f.expectFails(c.message, c.src);
        try std.testing.expectEqualStrings(c.irritants, try irritantsText(&f, &buf));
    }
}

test "a primitive that fails at the limit of the heap still reports its failure, without irritants" {
    var f: Fixture = undefined;
    try f.initWith(.{ .limit = 64 * 1024, .min_threshold = 16 * 1024 });
    defer f.deinit();
    Probe.reset();
    defer Probe.reset();
    try Probe.bind(&f);
    Probe.fill_failure = error.WrongType;
    // ヒープは満杯で、引数のリストは作れない。失敗は上限超過にすり替わらず、irritant を
    // 諦めて報告される。
    try f.expectFails("wrong type of argument to greedy", "(greedy 7)");
    try std.testing.expectEqual(value_mod.Kind.empty_list, f.ctx.raised.?.asCondition().?.irritants.kind());
    try f.expectInt(3, "(+ 1 2)");
    // 対照: 余裕があれば、引数がリストになる。
    Probe.failure = error.WrongType;
    try f.expectFails("wrong type of argument to probe", "(probe 7)");
    try std.testing.expectEqual(7, f.ctx.raised.?.asCondition().?.irritants.asPair().?.car.asFixnum().?);
}

test "a handler that keeps allocating on a heap without room is not interrupted by the same report" {
    var f: Fixture = undefined;
    try f.initWith(small_heap);
    defer f.deinit();
    _ = try f.eval("(define got #f) (define (forever n) (+ 1 (forever n))) (define (spin n) (if (= n 0) 'done (spin (- n 1))))");
    // ハンドラの中のループは、ごみを作り続けて何度も GC を起こす。GC はそのたびに余裕の
    // 無さを見つけるが、上限超過は1度しか報告しないので、ハンドラは終わりまで走る。
    const before = f.ctx.heap.collections;
    try f.expectFails("handler returned from non-continuable raise", "(with-exception-handler (lambda (c) (set! got c) (spin 3000) 42) (lambda () (forever 0)))");
    try std.testing.expectEqualStrings("heap limit exceeded", try conditionMessage(&f, "got"));
    try std.testing.expect(f.ctx.heap.collections > before + 2);
    try std.testing.expect(f.ctx.heap.exhausted);
}

test "a handler that is a primitive gives its value to the frame of the handler's return" {
    var f: Fixture = undefined;
    try f.initWith(small_heap);
    defer f.deinit();
    _ = try f.eval("(define (forever n) (+ 1 (forever n)))");
    // 上限超過は、ステップの先頭の GC で、制御に節点が残ったまま送出されうる。ハンドラが
    // 値を返すプリミティブなら、その節点を捨てて、値をハンドラの戻りのフレームに渡す。
    for ([_][]const u8{ "(forever 0)", "(+ 1 (forever 0))", "(forever (+ 1 2))" }) |body| {
        var src: [128]u8 = undefined;
        try f.expectFails("handler returned from non-continuable raise", try std.fmt.bufPrint(&src, "(with-exception-handler error-object? (lambda () {s}))", .{body}));
        try std.testing.expect(f.ctx.raised.?.asCondition().?.irritants.asPair().?.car.asCondition() != null);
    }
    try f.expectInt(3, "(+ 1 2)");
}

/// The options of the tests that fill the heap to its limit and run no
/// collection.
const no_collection: heap_mod.Options = .{ .limit = 64 * 1024, .min_threshold = 64 * 1024 };

/// A point of the dynamic state that installs `handler`, with no point
/// outside it.
fn handlerPoint(f: *Fixture, handler: Value) !*DynPoint {
    const point = try f.ctx.heap.create(DynPoint, .{ .parent = null, .depth = 1, .current_handler = null, .kind = .{ .handler = handler } });
    point.current_handler = point;
    return point;
}

/// Fills the heap up to its limit, so that every ordinary allocation is
/// refused.
/// GC は走らせないので、それまでに作ったものも、埋めたものも残る。
fn fillToLimit(f: *Fixture) !void {
    var list: Value = .empty_list_value;
    while (f.ctx.heap.cons(.empty_list_value, list)) |p| list = p else |_| {}
    // ペアより小さいセルで、残りを埋める。
    while (f.ctx.heap.create(Args, .{ .value = list, .next = null })) |_| {} else |_| {}
    try std.testing.expectError(error.HeapLimit, f.ctx.heap.create(Args, .{ .value = .empty_list_value, .next = null }));
}

test "every allocation to call a handler is made from the reserve" {
    // ハンドラを置いてから、ヒープを上限ちょうどまで埋め、送出の準備だけをする。
    var f: Fixture = undefined;
    try f.initWith(no_collection);
    defer f.deinit();
    const point = try handlerPoint(&f, try f.eval("(lambda (c) c)"));
    try fillToLimit(&f);
    var kont: ?*const Kont = null;
    var dyn: ?*const DynPoint = point;
    const call = (try f.machine.enterHandler(&kont, &dyn, .fromFixnum(5), false)).?;
    try std.testing.expectEqual(5, call.value.asFixnum().?);
    try std.testing.expect(dyn.?.kind == .handler_shift);
    try std.testing.expect(kont.?.step == .handler_return);
    try std.testing.expect(f.ctx.heap.accounted > f.ctx.heap.options.limit);
    // ハンドラのフレームも予約から作る。
    switch (try f.machine.apply(&kont, &dyn, call, 1, .raise_reserve)) {
        .body => |entry| try std.testing.expectEqual(5, entry.env.values[0].asFixnum().?),
        .value => return error.TestUnexpectedResult,
    }
}

test "a handler that takes its arguments as a list gets the list from the reserve" {
    var f: Fixture = undefined;
    try f.initWith(no_collection);
    defer f.deinit();
    const point = try handlerPoint(&f, try f.eval("(lambda args args)"));
    try fillToLimit(&f);
    var kont: ?*const Kont = null;
    var dyn: ?*const DynPoint = point;
    const call = (try f.machine.enterHandler(&kont, &dyn, .fromFixnum(5), false)).?;
    // 余りの引数のリストも、フレームと同じく予約から作る。
    switch (try f.machine.apply(&kont, &dyn, call, 1, .raise_reserve)) {
        .body => |entry| {
            const rest = entry.env.values[0].asPair().?;
            try std.testing.expectEqual(5, rest.car.asFixnum().?);
            try std.testing.expectEqual(value_mod.Kind.empty_list, rest.cdr.kind());
        },
        .value => return error.TestUnexpectedResult,
    }
    try std.testing.expect(f.ctx.heap.accounted > f.ctx.heap.options.limit);
}

test "raise-continuable calls the handler from the reserve, though it is applied as an ordinary call" {
    var f: Fixture = undefined;
    try f.initWith(no_collection);
    defer f.deinit();
    // プリミティブを先に読む。ハンドラのクロージャは、作ってから GC を走らせない。
    const operator = try f.eval("raise-continuable");
    const point = try handlerPoint(&f, try f.eval("(lambda (c) c)"));
    const procedure = try f.ctx.heap.create(Args, .{ .value = operator, .next = null });
    const call = try f.ctx.heap.create(Args, .{ .value = .fromFixnum(5), .next = procedure });
    try fillToLimit(&f);
    var kont: ?*const Kont = null;
    var dyn: ?*const DynPoint = point;
    // ふつうの呼び出しと同じく上限の budget で適用し、ハンドラの呼び出しに切り替わったところで
    // 予約に移る。
    switch (try f.machine.apply(&kont, &dyn, call, 1, .limit)) {
        .body => |entry| try std.testing.expectEqual(5, entry.env.values[0].asFixnum().?),
        .value => return error.TestUnexpectedResult,
    }
    try std.testing.expect(kont.?.step.handler_return.continuable);
    try std.testing.expect(dyn.?.kind == .handler_shift);
    try std.testing.expect(f.ctx.heap.accounted > f.ctx.heap.options.limit);
}

test "the secondary exception of a handler that returned is made from the reserve" {
    var f: Fixture = undefined;
    try f.initWith(no_collection);
    defer f.deinit();
    try fillToLimit(&f);
    // 条件とメッセージに加えて、irritant のペアも予約から作る。
    try std.testing.expectEqual(error.Raised, f.machine.handlerReturned(.fromFixnum(5)));
    const c = f.ctx.raised.?.asCondition().?;
    try std.testing.expectEqualStrings("handler returned from non-continuable raise", c.messageText());
    const irritants = c.irritants.asPair().?;
    try std.testing.expectEqual(5, irritants.car.asFixnum().?);
    try std.testing.expectEqual(value_mod.Kind.empty_list, irritants.cdr.kind());
    try std.testing.expect(f.ctx.heap.accounted > f.ctx.heap.options.limit);
}
