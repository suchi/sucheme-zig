//! The CEK machine: the only place evaluation advances
//! (docs/design/architecture.md, ADR-0004).
//!
//! 状態は 4 つのレジスタと動的状態のリストである(ADR-0004)。レジスタは、実行する節点
//! (制御)、実行中の手続きのフレーム(環境)、値をどうするかを表すフレームの連なり(継続)、
//! 直前に作られた値である。動的状態のリストは、その最も内側の点で持つ(スライス 2d)。
//! 現在の例外ハンドラはこの点から導き、そのためのレジスタは持たない(ADR-0016)。この
//! ファイルでは、4 つのレジスタと最も内側の点をまとめて `Registers` に置き、まとめて
//! レジスタと呼ぶ。ステップは、
//! 制御にある節点を分解するか、値を継続の先頭のフレームに渡すかのどちらかをする。
//! そのため、ここには Zig のスタックで再帰するものがなく、プログラムはメモリの
//! 許す限り深くなれる。
//!
//! 継続のフレームは、一度作ったら変えない。末尾位置の呼び出しにフレームは要らない。
//! 手続きの本体は呼び出し元の継続のもとで走り、列の最後の節点と `if` のどちらの枝も、
//! 自分のフレームが外れてから走る。
//!
//! ヒープは2つのステップの間で GC し、ステップの中では GC しない(ADR-0031)。その時点で
//! プログラムが持っているものは、コンテキストのルートの表(大域変数のセル、
//! `(sucheme core)` の表、ライブラリの登録表と読み込みの作業リスト、コードの定数、
//! 送出された値。`Context.mark` が挙げる)を除けばレジスタがすべてである。だから GC に
//! ほかのルートは要らない(ADR-0035)。

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
const features = @import("features.zig");

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
        /// まで続く。ハンドラが継続で外へ脱出すれば(2e)、深い継続は辿れなくなり、その後の
        /// GC が余裕を見つけて印を戻す。
        limit_reported: bool = false,
    };

    /// Runs `node` to its value.
    /// 送出された値は、現在の例外ハンドラに渡す。ハンドラが無ければ、実行の最も外側の継続
    /// (空の継続と空の列)へ脱出する。脱出は継続の起動と同じく巻き戻しの経路を通り、
    /// 途中の `dynamic-wind` の `after` をすべて呼ぶ。着いたら、送出された値を `ctx.raised`
    /// に置いて `error.Raised` を返す(docs/design/runtime.md の未処理例外)。
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
    /// handler, as `raise` does, or, when there is none, escapes with it to the
    /// outermost continuation of the run.
    /// ハンドラを呼ぶこと自体が送出すれば(ハンドラが手続きでない、引数の個数が合わない
    /// など)、その値を同じように渡す。そのときの列はハンドラ切り替えの点を積んだあとなので、
    /// 外側のハンドラに届き、周回は止まる。脱出の途中に `after` があれば、それを呼ぶ巻き戻しの
    /// フレームを継続に置いて戻り、`run` が実行を続ける。無ければ、その場で着き、値を
    /// `ctx.raised` に戻して `error.Raised` を返す。
    /// Why: 未処理例外に専用の機構を作らず、最外の継続への脱出として扱う
    /// (docs/design/runtime.md の未処理例外)。`after` の中の未処理例外は、その時点の列
    /// (`after` の点の親)から改めて脱出するので、巻き戻しは1つ外側の点から再開する。
    /// 着いたあとの列と継続は空なので、`run` がもう一度ここに来ても、ハンドラも `after` も
    /// 無く、すぐに `error.Raised` を返す。
    fn handOver(self: *Machine, regs: *Registers) Error!void {
        const ctx = self.ctx;
        while (true) {
            const raised = ctx.raised.?;
            ctx.raised = null;
            const handled = self.callHandler(regs, raised) catch |e| {
                if (e != error.Raised) return e;
                continue;
            };
            if (handled) return;
            regs.control = null;
            regs.env = null;
            regs.value = try self.invoke(&regs.kont, &regs.dyn, null, raised);
            return;
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
            if (ctx.heap.shouldCollect()) try self.collect(.{ .ctx = ctx, .control = control, .env = env, .kont = kont, .value = value, .dyn = dyn }, &regs.limit_reported);
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
                        kont = try self.push(kont, env, .{ .branch = node });
                        control = i.condition;
                    },
                    .sequence => |nodes| {
                        if (nodes.len > 1) kont = try self.push(kont, env, .{ .sequence = .{ .node = node, .next = 1 } });
                        control = nodes[0];
                    },
                    .local_set => |*a| {
                        kont = try self.push(kont, env, .{ .local_set = node });
                        control = a.value;
                    },
                    .local_define => |*a| {
                        kont = try self.push(kont, env, .{ .local_define = node });
                        control = a.value;
                    },
                    .global_set => |*a| {
                        kont = try self.push(kont, env, .{ .global_set = node });
                        control = a.value;
                    },
                    .global_define => |*a| {
                        kont = try self.push(kont, env, .{ .global_define = node });
                        control = a.value;
                    },
                    .call => |*c| {
                        kont = try self.push(kont, env, .{ .call = .{ .call = node, .args = null, .received = 0 } });
                        control = c.operator;
                    },
                    .parameterize => |pz| {
                        if (pz.bindings.len == 0) {
                            const next = try self.enterParameterize(&kont, &dyn, env, pz, null);
                            env = next.env;
                            control = next.control;
                        } else {
                            kont = try self.push(kont, env, .{ .parameterize_param = .{ .node = pz, .index = 0, .pending = null } });
                            control = pz.bindings[0].param;
                        }
                    },
                }
            } else {
                // 値は継続の先頭のフレームに渡す。そのフレームは先に外すので、
                // 次に走るものは、そのフレームなしで走る。
                const k = kont orelse return value;
                kont = k.next;
                env = k.env;
                // 複数値の表の「1個を要求する」群のフレームに複数値が届いたら誤りにする。
                // ほかの群は個数を検査しない(`Kont.Step.requiresOneValue`)。
                if (value.asMultipleValues()) |m| {
                    if (k.step.requiresOneValue()) return self.wrongValueCount(m);
                }
                switch (k.step) {
                    .branch => |n| {
                        const i = &n.@"if";
                        if (value.isTrue()) {
                            control = i.consequent;
                        } else if (i.alternative) |alternative| {
                            control = alternative;
                        } else {
                            value = .unspecified_value;
                        }
                    },
                    .sequence => |s| {
                        const nodes = s.node.sequence;
                        // 最後の節点は、この列のフレームが残っていない状態で走る。
                        if (s.next + 1 < nodes.len) kont = try self.push(kont, env, .{ .sequence = .{ .node = s.node, .next = s.next + 1 } });
                        control = nodes[s.next];
                    },
                    .local_set => |n| {
                        const a = &n.local_set;
                        const slot = slotAt(env, a.address);
                        if (slot.kind() == .uninitialized) return self.uninitialized(a.name);
                        slot.* = value;
                        value = .unspecified_value;
                    },
                    .local_define => |n| {
                        slotAt(env, n.local_define.address).* = value;
                        value = .unspecified_value;
                    },
                    .global_set => |n| {
                        const a = &n.global_set;
                        // `set!` は変数を作らない。未束縛の変数への代入はエラーである。
                        if (a.cell.value.kind() == .uninitialized) return self.unbound(a.cell.name);
                        a.cell.value = value;
                        value = .unspecified_value;
                    },
                    .global_define => |n| {
                        n.global_define.cell.value = value;
                        value = .unspecified_value;
                    },
                    .call => |c| {
                        const call = &c.call.call;
                        const args = try ctx.create(Args, .{ .value = value, .next = c.args });
                        const received = c.received + 1;
                        if (received <= call.operands.len) {
                            kont = try self.push(kont, env, .{ .call = .{ .call = c.call, .args = args, .received = received } });
                            control = call.operands[received - 1];
                        } else {
                            // 末尾呼び出し: 本体は呼び出しの継続のもとで走る。その継続は
                            // `kont` に残っているものである。
                            take(try self.apply(&kont, &dyn, args, received - 1, .limit), &env, &control, &value);
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
                    // `before` が戻った。点を積み、その範囲で `thunk` を呼ぶ。`before` の値は捨てる。
                    .wind_before => |w| {
                        std.debug.assert(dyn == w.point.parent);
                        const call = try ctx.create(Args, .{ .value = w.thunk, .next = null });
                        kont = try self.push(kont, null, .{ .wind_body = w.point });
                        dyn = w.point;
                        take(try self.apply(&kont, &dyn, call, 0, .limit), &env, &control, &value);
                    },
                    // `thunk` が戻った。点を外してから `after` を呼び、`thunk` の値を残す
                    // (R7RS 6.10)。確保を済ませてから列を書き換えるので、確保が失敗して送出した
                    // ときは点の中にいて、その脱出が `after` を呼ぶ。
                    .wind_body => |point| {
                        std.debug.assert(dyn == point);
                        const call = try ctx.create(Args, .{ .value = point.kind.wind.after, .next = null });
                        kont = try self.push(kont, null, .{ .wind_after = value });
                        dyn = point.parent;
                        take(try self.apply(&kont, &dyn, call, 0, .limit), &env, &control, &value);
                    },
                    // `after` が戻った。その値は捨て、`thunk` の値を渡す。
                    .wind_after => |v| value = v,
                    .rewind => |r| take(try self.rewind(&kont, &dyn, r), &env, &control, &value),
                    // 変換手続きが戻った。その戻り値が、新しいパラメータの初期値である。
                    .make_parameter => |converter| {
                        value = .fromParameter(try ctx.create(value_mod.Parameter, .{ .value = value, .converter = converter }));
                    },
                    // 束縛のパラメータが届いた。値の式を、同じ動的環境で評価する。
                    .parameterize_param => |s| {
                        const param = value.asParameter() orelse return notParameter(ctx, value);
                        kont = try self.push(kont, env, .{ .parameterize_value = .{ .node = s.node, .index = s.index, .pending = s.pending, .param = param } });
                        control = s.node.bindings[s.index].value;
                    },
                    // 束縛の値が届いた。変換手続きがあれば、束縛を積む前の動的環境で呼び、その戻りで
                    // 束縛する。無ければ、そのまま束縛する。
                    .parameterize_value => |b| if (b.param.converter) |converter| {
                        const procedure = try ctx.create(Args, .{ .value = converter, .next = null });
                        const call = try ctx.create(Args, .{ .value = value, .next = procedure });
                        kont = try self.push(kont, env, .{ .parameterize_convert = b });
                        take(try self.apply(&kont, &dyn, call, 1, .limit), &env, &control, &value);
                    } else {
                        const next = try self.bindParameter(&kont, &dyn, env, b, value);
                        env = next.env;
                        control = next.control;
                    },
                    // 変換手続きが戻った。戻り値で束縛する。もう一度は変換しない。
                    .parameterize_convert => |b| {
                        const next = try self.bindParameter(&kont, &dyn, env, b, value);
                        env = next.env;
                        control = next.control;
                    },
                    // 生産者が戻った。値を受け手の引数にして、`call-with-values` の継続のもとで
                    // 受け手を呼ぶ。このフレームはすでに外れているので、受け手は末尾呼び出し
                    // である(R7RS 3.5)。
                    .values_receiver => |consumer| {
                        take(try self.receive(&kont, &dyn, consumer, value), &env, &control, &value);
                    },
                    // 約束の手続きが戻った。戻した約束の状態を、強制している約束に移し、強制を続ける。
                    // このフレームはすでに外れているので、続きの手続きの呼び出しは、継続を伸ばさない。
                    .force_thunk => |promise| {
                        const returned = value.asPromise() orelse
                            return ctx.raise("delay-force: the expression did not return a promise", .{});
                        mergePromise(promise, returned);
                        switch (try self.forceNext(&kont, promise)) {
                            .value => |v| value = v,
                            .call => |call| take(try self.apply(&kont, &dyn, call, 0, .limit), &env, &control, &value),
                        }
                    },
                    // 引数の並べ直しの続きである。1ステップで並べるのは、一定の個数までにする。
                    // 残りが無くなったら、このフレームは外れているので、末尾呼び出しとして適用する。
                    .spread => |s| {
                        const lined = try self.lineUp(s);
                        if (lined.isDone()) {
                            take(try self.apply(&kont, &dyn, lined.chain, lined.count, .limit), &env, &control, &value);
                        } else {
                            kont = try self.push(kont, null, .{ .spread = lined });
                            value = .unspecified_value;
                        }
                    },
                }
            }
        }
    }

    /// Raises the error of a multiple-values object reaching a continuation that
    /// takes one value.
    /// 複数値のオブジェクトを irritant にしない。条件を通して、利用者のプログラムが
    /// それを値として手にしないようにするためである。
    fn wrongValueCount(self: *Machine, got: *const value_mod.MultipleValues) Error {
        return self.ctx.raise("wrong number of values: expected 1, got {d}", .{got.items.len});
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

    /// What a step goes on with: the node to run, and the frame to run it in.
    const Next = struct { env: ?*Frame, control: *const Node };

    /// Makes the binding `b` of a `parameterize` with the value `converted`, which
    /// is the value after the conversion, and goes on with the next binding, or
    /// with the body once there is none.
    /// 点は、`pending` の鎖の先頭に継ぎ足す。列のレジスタは、すべての束縛を作り終えるまで
    /// 書き換えない。変換手続きと式が、束縛を積む前の動的環境で走るようにするためである。
    /// 確保を済ませてから継続を書き換える。
    fn bindParameter(self: *Machine, kont: *?*const Kont, dyn: *?*const DynPoint, env: ?*Frame, b: Kont.ParameterizeBound, converted: Value) Error!Next {
        const ctx = self.ctx;
        const parent = b.pending orelse dyn.*;
        const point = try ctx.create(DynPoint, .{
            .parent = parent,
            .depth = value_mod.depthAbove(parent),
            .current_handler = value_mod.currentHandler(parent),
            .kind = .{ .parameter = .{ .param = b.param, .value = converted } },
        });
        const next = b.index + 1;
        if (next == b.node.bindings.len) return self.enterParameterize(kont, dyn, env, b.node, point);
        kont.* = try self.push(kont.*, env, .{ .parameterize_param = .{ .node = b.node, .index = next, .pending = point } });
        return .{ .env = env, .control = b.node.bindings[next].param };
    }

    /// Puts the points of a `parameterize`, `innermost` being the last of them or
    /// null when it has no binding, on the dynamic state, and returns its body with
    /// the frame it runs in.
    /// 本体の終わりで列を戻すフレームを、点を積む前の列を持たせて置く(docs/design/runtime.md
    /// の動的範囲の通常終了)。本体は末尾位置ではない。フレームが残るからである。
    fn enterParameterize(self: *Machine, kont: *?*const Kont, dyn: *?*const DynPoint, env: ?*Frame, node: *const value_mod.Parameterize, innermost: ?*const DynPoint) Error!Next {
        const frame = try self.ctx.createFrame(node.body.frame_size, env);
        kont.* = try self.push(kont.*, null, .{ .dynamic_exit = dyn.* });
        dyn.* = innermost orelse dyn.*;
        return .{ .env = frame, .control = node.body.body };
    }

    const Applied = union(enum) {
        value: Value,
        body: struct { env: *Frame, body: *const Node },
    };

    /// Puts what `apply` gave into the registers of a step: the value, or
    /// the body to run and the frame to run it in.
    fn take(applied: Applied, env: *?*Frame, control: *?*const Node, value: *Value) void {
        switch (applied) {
            .value => |v| value.* = v,
            .body => |entry| {
                env.* = entry.env;
                control.* = entry.body;
            },
        }
    }

    /// Invokes `target` with `v`: takes the continuation and the dynamic
    /// state to it, and gives `v` as the value to deliver. A null `target` is
    /// the outermost continuation of the run, to which `v` goes as what was
    /// raised (`error.Raised`).
    /// 現在の列から目標の列へ移る途中に wind 点が無ければ、その場で着く。あれば、巻き戻しの
    /// フレームを1つ継続に置くだけで戻り、`after` と `before` は次のステップから呼ぶ。
    /// Why: 次のステップの先頭で GC が走るので、捨てた継続(上限超過を起こした深い再帰など)は、
    /// `after` を呼ぶ前に回収できる。その場で呼ぶと、上限に達したままのヒープで `after` を
    /// 呼ぶことになる。巻き戻しの状態とフレームは、送出のための予約から確保する
    /// (docs/design/runtime.md の送出のための予約領域)。
    fn invoke(self: *Machine, kont: *?*const Kont, dyn: *?*const DynPoint, target: ?*const value_mod.Continuation, v: Value) Error!Value {
        const ctx = self.ctx;
        const to = if (target) |t| t.dyn else null;
        const ancestor = value_mod.commonAncestor(dyn.*, to);
        if (!value_mod.windBetween(dyn.*, ancestor) and !value_mod.windBetween(to, ancestor)) return self.arrive(kont, dyn, target, v);
        const state = try ctx.createIn(.raise_reserve, value_mod.Rewind, .{ .target = target, .value = v, .ancestor = ancestor });
        kont.* = try self.pushIn(.raise_reserve, null, null, .{ .rewind = .{ .state = state, .entered = null, .at = dyn.* } });
        return .unspecified_value;
    }

    /// Takes the registers to `target` and returns `v`; for the outermost
    /// continuation, empties them and raises `v`.
    fn arrive(self: *Machine, kont: *?*const Kont, dyn: *?*const DynPoint, target: ?*const value_mod.Continuation, v: Value) Error!Value {
        if (target) |t| {
            kont.* = t.kont;
            dyn.* = t.dyn;
            return v;
        }
        kont.* = null;
        dyn.* = null;
        self.ctx.raised = v;
        return error.Raised;
    }

    /// Takes the rewind of an invocation one wind point further: calls the
    /// next `after` while it leaves the points out to the common ancestor,
    /// then the next `before` while it enters the points in to the target, and
    /// arrives when there is none left (docs/design/runtime.md, the progress of
    /// a rewind).
    /// 各 `after` と各 `before` は、その wind 点の親の列で呼ぶ(R7RS 6.10 の「same dynamic
    /// environment as the call to dynamic-wind」)。退出では点を外してから `after` を呼び、
    /// 進入では親の列で `before` を呼んで、戻ってから点を積む。呼ぶたびに、位置を1つ進めた
    /// 巻き戻しのフレームを継続に置く。フレームと進入の経路は不変なので、`after` や
    /// `before` の中で捕捉した継続を後で起動しても、その位置から再開する。
    fn rewind(self: *Machine, kont: *?*const Kont, dyn: *?*const DynPoint, r: Kont.RewindStep) Error!Applied {
        std.debug.assert(dyn.* == r.at);
        const state = r.state;
        const path = if (r.entered) |link| next: {
            dyn.* = link.point;
            break :next link.next;
        } else path: {
            while (dyn.* != state.ancestor) {
                const point = dyn.*.?;
                dyn.* = point.parent;
                switch (point.kind) {
                    .wind => |w| return self.callWinder(kont, dyn, state, null, w.after),
                    .handler, .handler_shift, .parameter => {},
                }
            }
            break :path try self.windPath(state.ancestor, if (state.target) |t| t.dyn else null);
        };
        if (path) |link| {
            dyn.* = link.point.parent;
            return self.callWinder(kont, dyn, state, link, link.point.kind.wind.before);
        }
        return .{ .value = try self.arrive(kont, dyn, state.target, state.value) };
    }

    /// Calls `winder`, an `after` or a `before` of a rewind, with no
    /// arguments, under a rewind frame that goes on from `entered`.
    /// 呼び出しの確保は、ハンドラの呼び出しと同じく送出のための予約から行う(2d の前例)。
    /// `winder` の本体の評価は予約から行わない。
    fn callWinder(self: *Machine, kont: *?*const Kont, dyn: *?*const DynPoint, state: *const value_mod.Rewind, entered: ?*const value_mod.WindPath, winder: Value) Error!Applied {
        const call = try self.ctx.createIn(.raise_reserve, Args, .{ .value = winder, .next = null });
        kont.* = try self.pushIn(.raise_reserve, kont.*, null, .{ .rewind = .{ .state = state, .entered = entered, .at = dyn.* } });
        return self.apply(kont, dyn, call, 0, .raise_reserve);
    }

    /// The wind points from `ancestor` in to `to`, outermost first.
    /// `ancestor` は `to` 自身か、その外側の点か、null でなければならない。目標から
    /// 上りながら先頭に継ぎ足すと、外側から内側の順になる。
    fn windPath(self: *Machine, ancestor: ?*const DynPoint, to: ?*const DynPoint) Error!?*const value_mod.WindPath {
        var path: ?*const value_mod.WindPath = null;
        var it = to;
        while (it != ancestor) {
            const point = it.?;
            if (point.kind == .wind) path = try self.ctx.createIn(.raise_reserve, value_mod.WindPath, .{ .point = point, .next = path });
            it = point.parent;
        }
        return path;
    }

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
        // Why: 機械操作プリミティブが置き換えた呼び出しを、Zig の再帰でなく周回で適用する。
        // 他の機械操作プリミティブは、手続きの引数の個数が決まっているので、データから好きなだけ
        // 深い入れ子は作れない。作れるのは `apply` で、`apply` は並べ直しを継続のフレームに
        // 持たせて戻るので、周回に入らない(ADR-0031 の 2026-10-15 の追記(3))。
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
                    // Why: 並べ直しは、ここでは始めるだけで、継続のフレームに持たせて次の
                    // ステップへ送る。周回のたびに境目を通るので、`apply` で `apply` を呼ぶ入れ子や、
                    // 自分を指す引数のリストの周回でも、その間のごみを回収できる。フレームは
                    // 次のステップが外してから適用するので、末尾呼び出しは保たれる。
                    .apply => {
                        const start = try self.startApply(prim, args, count);
                        kont.* = try self.push(kont.*, null, .{ .spread = start });
                        return .{ .value = .unspecified_value };
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
                    // Why: `proc` を、継続のフレームを積まずに捕捉した継続で呼ぶ。`call/cc` の
                    // 第1引数の呼び出しは末尾呼び出しである(R7RS 3.5)。捕捉した継続は、この
                    // 呼び出しの継続そのものである。
                    .call_cc => {
                        args = try self.captureFor(prim, kont.*, dyn.*, args);
                        count = 1;
                        budget = .limit;
                    },
                    .dynamic_wind => {
                        args = try self.enterWind(prim, kont, dyn.*, args);
                        count = 0;
                        budget = .limit;
                    },
                    .make_parameter => {
                        // 変換手続きが無ければ、パラメータをそのまま返す。あれば、初期値に適用して、
                        // 戻りでパラメータを作る。
                        if (count == 1) {
                            const param = try ctx.create(value_mod.Parameter, .{ .value = args.value, .converter = null });
                            return .{ .value = .fromParameter(param) };
                        }
                        args = try self.convertInitial(prim, kont, args, count);
                        count = 1;
                        budget = .limit;
                    },
                    // 約束でない値は、そのまま返す(R7RS 4.2.5 が許している)。
                    .force => {
                        const promise = args.value.asPromise() orelse return .{ .value = args.value };
                        switch (try self.forceNext(kont, promise)) {
                            .value => |v| return .{ .value = v },
                            .call => |call| {
                                args = call;
                                count = 0;
                                budget = .limit;
                            },
                        }
                    },
                    .values => return .{ .value = try self.valuesOf(args, count, budget) },
                    .features => return .{ .value = try self.featureList() },
                    .call_with_values => {
                        args = try self.enterReceiver(prim, kont, args);
                        count = 0;
                        budget = .limit;
                    },
                },
            }
        };
        if (operator.asContinuation()) |k| {
            // 継続は任意個の値を受け取る。1個以外なら、複数値のオブジェクトにして渡す。
            return .{ .value = try self.invoke(kont, dyn, k, try self.valuesOf(args, count, budget)) };
        }
        if (operator.asParameter()) |param| {
            if (count != 0) return ctx.raise("wrong number of arguments: expected 0, got {d}", .{count});
            return .{ .value = value_mod.parameterValue(dyn.*, param) };
        }
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

    /// How many operands one step lines up (`Kont.Step.spread`).
    /// Why: 1ステップで確保する量を、リストの長さによらず一定にするためである。大きすぎると、
    /// 境目の GC が走る前に上限までの余りを使い切る(ADR-0031)。小さすぎると、ステップと
    /// 継続のフレームが増える。
    const spread_chunk = 64;

    /// Starts the call that `(apply proc arg1 ... list)` stands for: `proc` applied
    /// to `arg1 ...` followed by the elements of `list` (R7RS 6.10). It lines up
    /// `proc` and `arg1 ...`, and leaves the elements of `list` for `lineUp`.
    /// `args` は `apply` の呼び出しの値の鎖で、`list` から逆順に並び、末尾に `apply`
    /// 自身がある。鎖は捕捉された継続と共有されうる(`Args` の説明)ので書き換えず、
    /// `proc` を末尾に置く新しい鎖を作る。`prim` は `apply` 自身で、失敗の報告に使う。
    /// リストの前の引数は、ソースに書いた数のほかに、入れ子の `apply` が並べた分も
    /// ありうるので、データの大きさに比例しうる。その分は、ここで1ステップに並べる。
    fn startApply(self: *Machine, prim: *const value_mod.Primitive, args: *const Args, count: usize) Error!Kont.Spread {
        const ctx = self.ctx;
        const list = args.value;
        // 確保より前に検査する。長い非真正リストを、上限超過として報告しないためである。
        // 並べる個数は、`lineUp` が並べた分を数える。リストは、並べ終えるまでに書き換わらない。
        // 間に走る Scheme のコードが無いからである。
        _ = pair.properLength(list) orelse return primitiveFailure(ctx, prim, error.WrongType, args, count);
        // `proc` と、リストの前の引数を、書いた順に並べる。
        const leading = count - 1;
        var small: [small_operands]Value = undefined;
        const before = if (leading <= small.len) small[0..leading] else try self.scratch.alloc(Value, leading);
        // Why: `callPure` と同じ理由で、並べ直した呼び出しを適用する前に返す。
        defer if (leading > small.len) self.scratch.free(before);
        fill(before, args.next.?);
        // Why: GC はステップの間でしか走らない(ADR-0031)。作りかけの鎖はどのルートからも
        // 辿れないが、同じステップのうちにフレームに載るので、回収されない。
        var chain: *const Args = try ctx.create(Args, .{ .value = before[0], .next = null });
        for (before[1..]) |v| chain = try ctx.create(Args, .{ .value = v, .next = chain });
        return .{ .chain = chain, .count = leading - 1, .rest = list, .index = 0 };
    }

    /// Lines up the next chunk of the operands of `s`, at most `spread_chunk` of them,
    /// and returns what is left to do.
    /// 最後のオペランドから順に前へ継ぎ足すので、鎖は最後のオペランドから並ぶ。
    /// Why: GC はステップの間でしか走らない(ADR-0031)。作りかけの鎖は、このステップの
    /// うちに継続のフレームか呼び出しに載るので、回収されない。
    fn lineUp(self: *Machine, s: Kont.Spread) Error!Kont.Spread {
        var lined = s;
        for (0..spread_chunk) |_| {
            const operand = lined.takeNext() orelse break;
            lined.chain = try self.ctx.create(Args, .{ .value = operand, .next = lined.chain });
            lined.count += 1;
        }
        return lined;
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

    /// The call `(call/cc proc)` stands for: `proc` applied to the
    /// continuation of the call of `call/cc`, which it captures with the
    /// dynamic state `dyn`.
    /// `args` は `proc`、`prim` の順に並ぶ。継続は捕捉の時点のフレームと点を指すだけで、
    /// 写さない(フレームも点も不変である)。
    fn captureFor(self: *Machine, prim: *const value_mod.Primitive, kont: ?*const Kont, dyn: ?*const DynPoint, args: *const Args) Error!*const Args {
        const ctx = self.ctx;
        const proc = args.value;
        if (!isProcedure(proc)) return primitiveFailure(ctx, prim, error.WrongType, args, 1);
        const k = try ctx.create(value_mod.Continuation, .{ .kont = kont, .dyn = dyn });
        const procedure = try ctx.create(Args, .{ .value = proc, .next = null });
        return ctx.create(Args, .{ .value = .fromContinuation(k), .next = procedure });
    }

    /// What `(dynamic-wind before thunk after)` does first (R7RS 6.10): makes
    /// the wind point, puts the frame that puts it on once `before` returns,
    /// and returns the call of `before`.
    /// `args` は `after`、`thunk`、`before`、`prim` の順に並ぶ。`before` は点を積む前の
    /// 列で呼ぶ。点の現在のハンドラは親のものである(ADR-0016)。確保を済ませてから継続を
    /// 書き換える。
    fn enterWind(self: *Machine, prim: *const value_mod.Primitive, kont: *?*const Kont, dyn: ?*const DynPoint, args: *const Args) Error!*const Args {
        const ctx = self.ctx;
        const after = args.value;
        const thunk = args.next.?.value;
        const before = args.next.?.next.?.value;
        if (!isProcedure(before) or !isProcedure(thunk) or !isProcedure(after)) return primitiveFailure(ctx, prim, error.WrongType, args, 3);
        const point = try ctx.create(DynPoint, .{
            .parent = dyn,
            .depth = value_mod.depthAbove(dyn),
            .current_handler = value_mod.currentHandler(dyn),
            .kind = .{ .wind = .{ .before = before, .after = after } },
        });
        const call = try ctx.create(Args, .{ .value = before, .next = null });
        kont.* = try self.push(kont.*, null, .{ .wind_before = .{ .point = point, .thunk = thunk } });
        return call;
    }

    /// The call `(converter init)` that `(make-parameter init converter)` makes
    /// first, with the frame that makes the parameter from what it returns.
    /// `args` は `converter`、`init`、`prim` の順に並ぶ。変換手続きは末尾位置で呼ばない。
    /// 戻りを受けるフレームが残るからである。確保を済ませてから継続を書き換える。
    fn convertInitial(self: *Machine, prim: *const value_mod.Primitive, kont: *?*const Kont, args: *const Args, count: usize) Error!*const Args {
        const ctx = self.ctx;
        const converter = args.value;
        if (!isProcedure(converter)) return primitiveFailure(ctx, prim, error.WrongType, args, count);
        const procedure = try ctx.create(Args, .{ .value = converter, .next = null });
        const call = try ctx.create(Args, .{ .value = args.next.?.value, .next = procedure });
        kont.* = try self.push(kont.*, null, .{ .make_parameter = converter });
        return call;
    }

    /// What `force` goes on with: the value of a promise that is done, or the call of
    /// the procedure of one that is not.
    const Forced = union(enum) { value: Value, call: *const Args };

    /// Starts, or goes on with, forcing `promise` (R7RS 4.2.5): the value of the
    /// promise when its state holds one, and otherwise the call of its procedure,
    /// with the frame that takes what the procedure returns.
    /// 状態は、別名をたどった先の約束にある。強制の途中で、同じ状態が別の約束に併合されること
    /// があるので、フレームには強制を始めた約束を持たせ、そのたびに根をたどり直す。手続きは
    /// 末尾位置で呼ばない。戻りを受けるフレームが残るからである。確保を済ませてから継続を
    /// 書き換える。
    fn forceNext(self: *Machine, kont: *?*const Kont, promise: *value_mod.Promise) Error!Forced {
        const root = promise.root();
        if (root.done) return .{ .value = root.value };
        const call = try self.ctx.create(Args, .{ .value = root.value, .next = null });
        kont.* = try self.push(kont.*, null, .{ .force_thunk = promise });
        return .{ .call = call };
    }

    /// Puts the state of `returned`, the promise that the procedure of `promise` gave
    /// back, into `promise`, and makes the two share it (R7RS 7.3, `promise-update!`).
    /// 手続きが戻るまでの間に、`promise` がすでに値を持っていたなら、何もしない。最初に終えた
    /// 計算の値が残る(R7RS 4.2.5 の「一度だけ計算される」)。戻した約束が値を持つときは、状態を
    /// 写すだけでよい。値は変わらないので、共有は見分けられない。共有するのは、まだ手続きを
    /// 持つ約束だけで、そうすると、あとからその約束を強制しても、手続きが走り直さない。
    fn mergePromise(promise: *value_mod.Promise, returned: *value_mod.Promise) void {
        const target = promise.root();
        if (target.done) return;
        const source = returned.root();
        if (source == target) return;
        target.done = source.done;
        target.value = source.value;
        if (!source.done) {
            source.value = .unspecified_value;
            source.forward = target;
        }
    }

    /// A new list of the feature identifiers of the build, as symbols.
    /// Why: 呼ぶたびに新しいリストを作る。返したリストを書き換えても、次の呼び出しに響かない。
    fn featureList(self: *Machine) Error!Value {
        const ctx = self.ctx;
        var list: Value = .empty_list_value;
        var i = features.names.len;
        while (i > 0) {
            i -= 1;
            const id = try ctx.intern(features.names[i]);
            list = ctx.heap.cons(.fromSymbol(id), list) catch |e| return ctx.heapFailure(e);
        }
        return list;
    }

    /// What `(values obj ...)` returns for the `count` operands in `args`: the
    /// operand itself when there is one, and otherwise a multiple-values object
    /// of them (R7RS 6.10).
    /// `args` は最後のオペランドから並ぶ(末尾に演算子があってもよい)。1個の値を複数値の
    /// オブジェクトにしないのは、`(+ 1 (values 2))` のように、値を1個要求する継続が
    /// 受け取れるようにするためである。オブジェクトは、呼び出しの `budget` から確保する。
    fn valuesOf(self: *Machine, args: *const Args, count: usize, budget: heap_mod.Budget) Error!Value {
        if (count == 1) return args.value;
        var small: [small_operands]Value = undefined;
        const items = if (count <= small.len) small[0..count] else try self.scratch.alloc(Value, count);
        // Why: `callPure` と同じ理由で、使い終えたら返す。
        defer if (count > small.len) self.scratch.free(items);
        fill(items, args);
        return .fromMultipleValues(try self.ctx.createValuesIn(budget, items));
    }

    /// What `(call-with-values producer consumer)` does first (R7RS 6.10): puts
    /// the frame that takes what `producer` returns to `consumer`, and returns
    /// the call of `producer`.
    /// `args` は `consumer`、`producer`、`prim` の順に並ぶ。`producer` は末尾位置で呼ばない。
    /// 戻った値を受け取るフレームが残るからである。`consumer` は、そのフレームが外れたあとに
    /// 呼ぶので、末尾位置で呼ぶ。確保を済ませてから継続を書き換える。
    fn enterReceiver(self: *Machine, prim: *const value_mod.Primitive, kont: *?*const Kont, args: *const Args) Error!*const Args {
        const ctx = self.ctx;
        const consumer = args.value;
        const producer = args.next.?.value;
        if (!isProcedure(producer) or !isProcedure(consumer)) return primitiveFailure(ctx, prim, error.WrongType, args, 2);
        const call = try ctx.create(Args, .{ .value = producer, .next = null });
        kont.* = try self.push(kont.*, null, .{ .values_receiver = consumer });
        return call;
    }

    /// Calls `consumer` with `received`, what a producer returned: with its values
    /// when it returned a multiple-values object, and otherwise with the one value.
    /// 複数値のオブジェクトの値は、`apply` のリストと同じく、境目を挟む複数のステップに
    /// 分けて並べる。1個の値は、並べるのが一定の量なので、その場で呼ぶ。
    /// 引数の鎖は最後のオペランドから並べ、末尾に `consumer` を置く。
    fn receive(self: *Machine, kont: *?*const Kont, dyn: *?*const DynPoint, consumer: Value, received: Value) Error!Applied {
        const ctx = self.ctx;
        // Why: GC はステップの間でしか走らない(ADR-0031)。作りかけの鎖はどのルートからも
        // 辿れないが、同じステップのうちに適用されるか、フレームに載るので、回収されない。
        const chain: *const Args = try ctx.create(Args, .{ .value = consumer, .next = null });
        if (received.asMultipleValues() == null) {
            const args = try ctx.create(Args, .{ .value = received, .next = chain });
            return self.apply(kont, dyn, args, 1, .limit);
        }
        kont.* = try self.push(kont.*, null, .{ .spread = .{ .chain = chain, .count = 0, .rest = received, .index = 0 } });
        return .{ .value = .unspecified_value };
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
            error.Immutable => raiseWith(ctx, irritants, "cannot modify a constant in {s}", .{prim.name}),
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

    /// The error that a `parameterize` of `v`, which is not a parameter object, is.
    /// 条件の irritant は `v` である。確保は上限に従い、当たったときは irritant を諦める
    /// (`operandList` と同じ理由である)。
    fn notParameter(ctx: *Context, v: Value) Error {
        const irritants: Value = if (ctx.heap.create(value_mod.Pair, .{ .car = v, .cdr = .empty_list_value })) |cell|
            .{ .pair = cell }
        else |e| switch (e) {
            error.HeapLimit => .empty_list_value,
            error.OutOfMemory => return error.OutOfMemory,
        };
        return raiseWith(ctx, irritants, "wrong type of argument to parameterize", .{});
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
    /// 制御は、次に走らせる節点である。節点は GC ヒープにあり、まだ継続にもクロージャにも
    /// 載っていない節点(走り始めたばかりの根の節点など)は、ここからしか辿れない(ADR-0040)。
    const Roots = struct {
        ctx: *const Context,
        control: ?*const Node = null,
        env: ?*Frame,
        kont: ?*const Kont,
        value: Value,
        dyn: ?*const DynPoint,

        pub fn mark(self: Roots, marker: *heap_mod.Marker) void {
            if (self.control) |node| marker.object(Node, node);
            marker.value(self.value);
            marker.frame(self.env);
            marker.kont(self.kont);
            marker.dynPoint(self.dyn);
            self.ctx.mark(marker);
        }
    };

    fn uninitialized(self: *Machine, name: SymbolId) Error {
        return self.ctx.raise("variable used before its definition: {s}", .{self.ctx.heap.symbols.nameOf(name)});
    }

    fn unbound(self: *Machine, name: SymbolId) Error {
        return self.ctx.raise("unbound variable: {s}", .{self.ctx.heap.symbols.nameOf(name)});
    }
};

/// Whether `v` can be applied.
fn isProcedure(v: Value) bool {
    return v.asClosure() != null or v.asPrimitive() != null or v.asContinuation() != null or v.asParameter() != null;
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
        const sink: reader_mod.Sink = .{ .heap = &self.ctx.heap };
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
    try std.testing.expectEqualStrings("fixed", f.ctx.heap.symbols.nameOf(fixed.asSymbol().?));
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
        try std.testing.expectEqualStrings("done", f.ctx.heap.symbols.nameOf(done.asSymbol().?));
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

/// 生きているデータは収まり、1周ごとのごみを周回の回数ぶんためると収まらない上限。
/// `(nest n l)` のリストは、1段ごとにペア2個を持つ。`(apply apply l)` は1周ごとに引数の
/// 鎖のノードを3個(`apply` と、リストの2要素)確保する。
fn applyNestLimit(n: usize) usize {
    const live = 2 * n * heap_mod.cellBytes(value_mod.Pair);
    return live + live / 4;
}

test "a collection runs between the rounds of an apply nested as deep as the data, so the rounds fit in the live data" {
    const n = 4000;
    const nest = "(define (nest n l) (if (= n 0) l (nest (- n 1) (list apply l))))";
    // 上限は、生きている量が収まる大きさにして、周回のごみ(3n 個の引数のノード)は
    // 収まらない大きさにしてある。
    try std.testing.expect(3 * n * heap_mod.cellBytes(Args) > applyNestLimit(n) - 2 * n * heap_mod.cellBytes(value_mod.Pair));
    // 対照: 同じデータは、ゆとりのある上限なら通る。周回が境目を通っても、同じ値になる。
    {
        var f: Fixture = undefined;
        try f.init();
        defer f.deinit();
        _ = try f.eval(nest);
        _ = try f.eval(std.fmt.comptimePrint("(define l (nest {d} (list + '(1 2))))", .{n}));
        try f.expectInt(3, "(apply apply l)");
    }
    for ([_]bool{ false, true }) |stress| {
        var f: Fixture = undefined;
        try f.initWith(.{ .limit = applyNestLimit(n), .min_threshold = 16 * 1024, .stress = stress });
        defer f.deinit();
        _ = try f.eval(nest);
        _ = try f.eval(std.fmt.comptimePrint("(define l (nest {d} (list + '(1 2))))", .{n}));
        const before = f.ctx.heap.collections;
        // 周回のごみは、周回の間の境目で回収される。
        try f.expectInt(3, "(apply apply l)");
        try std.testing.expect(f.ctx.heap.collections > before);
    }
}

test "a collection runs while a call-with-values lines up the values it received" {
    const n = 4000;
    const cell = heap_mod.cellBytes;
    // 受け手を呼ぶ時点で、ヒープには、リスト `xs` と、`(apply values xs)` が並べた引数の鎖
    // (もうごみである)と、複数値のオブジェクトがある。受け手に渡す引数の鎖は、その上に
    // さらに `n` 個のノードを足す。上限は、鎖を1ステップで並べ切ると収まらず、塊ごとに
    // 境目で GC が走れば収まる大きさにする。生きているのは、鎖の分を除いて、`xs` と
    // オブジェクトだけである。
    const before = n * (cell(value_mod.Pair) + cell(Args) + @sizeOf(Value));
    const limit = before + n * cell(Args) - 1;
    try std.testing.expect(limit - limit / 16 > before);
    var f: Fixture = undefined;
    // 最初の GC を、上限の手前まで遅らせる。
    try f.initWith(.{ .limit = limit, .min_threshold = limit });
    defer f.deinit();
    _ = try f.eval("(define (build n acc) (if (= n 0) acc (build (- n 1) (cons n acc))))");
    _ = try f.eval(std.fmt.comptimePrint("(define xs (build {d} '()))", .{n}));
    const sum: i64 = n * (n + 1) / 2;
    try f.expectInt(sum, "(call-with-values (lambda () (apply values xs)) +)");
}

test "apply lines up a list in chunks and keeps the order around the size of a chunk" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    _ = try f.eval("(define (build n acc) (if (= n 0) acc (build (- n 1) (cons n acc))))");
    const c = Machine.spread_chunk;
    // 一つの塊に収まる長さ、ちょうど収まる長さ、はみ出す長さ、複数の塊になる長さ。
    for ([_]usize{ 0, 1, c - 1, c, c + 1, 2 * c, 2 * c + 1, 5 * c + 3 }) |n| {
        var src: [160]u8 = undefined;
        _ = try f.eval(try std.fmt.bufPrint(&src, "(define xs (build {d} '()))", .{n}));
        // リストの前の引数も、書いた順に並ぶ。
        const same = try f.eval("(equal? (apply list xs) xs)");
        try std.testing.expect(same.isTrue());
        const lead = try f.eval("(equal? (apply list 'a 'b xs) (cons 'a (cons 'b xs)))");
        try std.testing.expect(lead.isTrue());
        const sum = try f.eval("(apply + xs)");
        try std.testing.expectEqual(@as(i64, @intCast(n * (n + 1) / 2)), sum.asFixnum().?);
    }
}

test "apply lines up a long list in few steps, not one step for each element" {
    var f: Fixture = undefined;
    try f.initWith(.{ .stress = true });
    defer f.deinit();
    _ = try f.eval("(define (build n acc) (if (= n 0) acc (build (- n 1) (cons n acc))))");
    const n = 1280;
    _ = try f.eval(std.fmt.comptimePrint("(define xs (build {d} '()))", .{n}));
    // 強制 GC のモードでは、ステップごとに `total_steps` が増える。塊で並べるなら、
    // ステップ数は要素数の数分の1に収まる。1要素ごとに1ステップなら、n を超える。
    const before = f.ctx.heap.total_steps;
    const sum = try f.eval("(apply + xs)");
    try std.testing.expectEqual(@as(i64, n * (n + 1) / 2), sum.asFixnum().?);
    try std.testing.expect(f.ctx.heap.total_steps - before <= n / 8);
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
            const id = try f.ctx.heap.internFixed(p.name);
            try f.ctx.core.addPrimitive(f.ctx.persist, id, p);
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
        .{ .failure = error.Immutable, .message = "cannot modify a constant in probe" },
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
    // 上限は、1500 個のオペランドの節点(ヒープにある。ADR-0040)と読んだペアを収め、
    // 余りのリストを収めない大きさである。
    try f.initWith(.{ .limit = 192 * 1024, .min_threshold = 16 * 1024 });
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

/// Fills the heap of `f` with `n` pairs that a global variable of the context keeps.
/// 変数の名前とセルは、ペアより先に作る。ペアを作れなくなった時点で、上限の縁にいる。
fn fillKept(f: *Fixture, n: usize) !void {
    const id = try f.ctx.heap.intern("kept");
    const cell = try f.ctx.globals.defineTarget(f.ctx.resident(), &f.ctx.heap, id);
    var list: Value = .empty_list_value;
    for (0..n) |_| list = try f.ctx.heap.cons(.fromFixnum(0), list);
    cell.value = list;
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
            // 上限と比べるのは、ヒープのオブジェクトの量だけでなく、上限に数える全部
            // (`held`。最上位の表の常駐の計上を含む)である。
            if (f.ctx.heap.held() <= limit) continue;
            found = true;
            // 条件はヒープにあり、上限を超えた分は予約から取った。
            try std.testing.expectEqual(1, f.ctx.heap.countOf(value_mod.Condition));
            try std.testing.expect(f.ctx.heap.held() <= limit + f.ctx.heap.options.raise_reserve);
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
    const sink: reader_mod.Sink = .{ .heap = &f.ctx.heap };
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
    // 継続と wind 点は、捕捉した継続の値からしか辿れない。脱出と再入、巻き戻しの途中の
    // `after` と `before` が、毎ステップの GC を生き延びる。
    .{ .src = "(define kk #f) (define log 0) (define (bump) (set! log (+ log 1))) (+ 100 (dynamic-wind bump (lambda () (call/cc (lambda (c) (set! kk c) 1))) bump))", .expected = 101 },
    .{ .src = "(if (= log 2) (kk 2) log)", .expected = 102 },
    .{ .src = "(if (= log 4) (kk 3) log)", .expected = 103 },
    .{ .src = "log", .expected = 6 },
    .{ .src = "(call/cc (lambda (out) (dynamic-wind bump (lambda () (with-exception-handler (lambda (c) (out (+ c log))) (lambda () (raise 10)))) bump)))", .expected = 17 },
    .{ .src = "log", .expected = 8 },
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
    // リーダのペアと、定義の節点と、数個のフレームぶんだけの余裕。節点はヒープにあるので、
    // 上限は節点の分を含む(ADR-0040)。
    try f.initWith(.{ .limit = 4096, .min_threshold = 2048 });
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
    try std.testing.expectEqualStrings("oops", f.ctx.heap.symbols.nameOf(f.ctx.raised.?.asSymbol().?));
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
    try std.testing.expectEqualStrings("oops", f.ctx.heap.symbols.nameOf(irritants.car.asSymbol().?));
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
    try std.testing.expectEqualStrings("again", f.ctx.heap.symbols.nameOf(again.asSymbol().?));
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
    try std.testing.expectEqualStrings("two", f.ctx.heap.symbols.nameOf(second.car.asSymbol().?));
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
            // リーダが式を読めないほど埋まった。これより先の量も試せない。
            error.HeapLimit => break,
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
        // `peak` はオブジェクトの量の最大値である。最上位の表の常駐の計上は、展開で伸び、
        // 実行の間は変わらないので、足すと、実行の間に上限に数えた量の最大値になる。
        const peak_held = f.ctx.heap.peak + f.ctx.heap.resident;
        if (peak_held <= limit + heap_mod.cellBytes(value_mod.Condition) + heap_mod.cellBytes(value_mod.String) + 64) continue;
        found = true;
        try std.testing.expect(peak_held <= limit + f.ctx.heap.options.raise_reserve);
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
        try @import("printer.zig").write(&w, std.testing.allocator, &f.ctx.heap.symbols, p.car);
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
    try std.testing.expect(f.ctx.heap.held() > f.ctx.heap.options.limit);
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
    try std.testing.expect(f.ctx.heap.held() > f.ctx.heap.options.limit);
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
    try std.testing.expect(f.ctx.heap.held() > f.ctx.heap.options.limit);
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
    try std.testing.expect(f.ctx.heap.held() > f.ctx.heap.options.limit);
}

// 以下は継続と `dynamic-wind` のテストである(スライス 2e)。

test "a continuation escapes, and each invocation starts again from the operands evaluated before the capture" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.expectInt(42, "(call/cc (lambda (k) (+ 1 (k 42))))");
    try f.expectInt(42, "(call-with-current-continuation (lambda (k) (+ 1 (k 42))))");
    // 継続を呼ばずに戻れば、その値が `call/cc` の値である。
    try f.expectInt(3, "(+ 1 (call/cc (lambda (k) 2)))");
    // 引数の評価の途中で捕捉した継続を何度も起動する。捕捉の前に評価した引数は、起動の
    // たびに捕捉の時点の値で、後ろの引数は起動のたびに評価し直す(フレームと引数の鎖は不変)。
    _ = try f.eval("(define k #f) (define n 0) (define (next) (set! n (+ n 1)) n)");
    var buf: [8]i64 = undefined;
    const cases = [_]struct { src: []const u8, expected: []const i64 }{
        .{ .src = "(list (next) (call/cc (lambda (c) (set! k c) 0)) (next))", .expected = &.{ 1, 0, 2 } },
        .{ .src = "(k 10)", .expected = &.{ 1, 10, 3 } },
        .{ .src = "(k 20)", .expected = &.{ 1, 20, 4 } },
    };
    for (cases) |c| {
        const len = fixnums(try f.eval(c.src), &buf);
        try std.testing.expectEqualSlices(i64, c.expected, buf[0..len]);
    }
    // `apply` で呼んでも、ハンドラとして呼ばれても、継続である。
    try f.expectInt(7, "(+ 1 (call/cc (lambda (k) (apply k '(6)))))");
    try f.expectInt(9, "(call/cc (lambda (k) (with-exception-handler k (lambda () (raise 9)))))");
}

test "the arguments of call/cc and of a continuation are checked" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.expectFails("wrong type of argument to call/cc", "(call/cc 5)");
    try f.expectFails("wrong number of arguments to call/cc", "(call/cc)");
    try f.expectFails("wrong number of arguments: expected 0, got 1", "(call/cc (lambda () 1))");
    try f.expectFails("wrong type of argument to dynamic-wind", "(dynamic-wind 1 (lambda () 2) (lambda () 3))");
    try f.expectFails("wrong type of argument to dynamic-wind", "(dynamic-wind (lambda () 1) 2 (lambda () 3))");
    try f.expectFails("wrong type of argument to dynamic-wind", "(dynamic-wind (lambda () 1) (lambda () 2) 3)");
    // 継続は手続きなので、`dynamic-wind` の型の検査を通る。継続は任意個の値を取るので、
    // 引数なしで呼ぶ `after` としては、0個の値を渡して脱出する。
    try std.testing.expectEqual(0, (try f.eval("(call/cc (lambda (k) (dynamic-wind (lambda () 1) (lambda () 5) k)))")).asMultipleValues().?.items.len);
}

test "the procedure call/cc calls runs in tail position, so a loop through call/cc does not grow the continuation" {
    var f: Fixture = undefined;
    try f.initIn(std.heap.smp_allocator, .{});
    defer f.deinit();
    _ = try f.eval("(define (loop n) (if (= n 0) 'done (call/cc (lambda (k) (loop (- n 1))))))");
    f.machine.peak_depth = 0;
    _ = try f.eval("(loop 10)");
    const small = f.machine.peak_depth;
    f.machine.peak_depth = 0;
    _ = try f.eval("(loop 5000)");
    try std.testing.expectEqual(small, f.machine.peak_depth);
    // 対照: 値を使う、末尾でないループは、回数に比例して深くなる。
    _ = try f.eval("(define (count n) (if (= n 0) 0 (+ 1 (call/cc (lambda (k) (count (- n 1)))))))");
    f.machine.peak_depth = 0;
    try f.expectInt(5000, "(count 5000)");
    try std.testing.expect(f.machine.peak_depth >= 5000);
}

test "dynamic-wind calls before, the thunk and after in order, and gives the value of the thunk" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    _ = try f.eval("(define log '()) (define (note x) (set! log (cons x log)) x)");
    try f.expectInt(2, "(dynamic-wind (lambda () (note 1)) (lambda () (note 2)) (lambda () (note 3)))");
    var buf: [8]i64 = undefined;
    var len = fixnums(try f.eval("log"), &buf);
    try std.testing.expectEqualSlices(i64, &.{ 3, 2, 1 }, buf[0..len]);
    // 継続で脱出すると、`after` が呼ばれる。再入すると、`before` がまた呼ばれる。
    _ = try f.eval("(set! log '()) (define k #f)");
    try f.expectInt(10, "(+ 10 (dynamic-wind (lambda () (note 1)) (lambda () (call/cc (lambda (c) (set! k c) 0))) (lambda () (note 3))))");
    try f.expectInt(15, "(k 5)");
    len = fixnums(try f.eval("log"), &buf);
    try std.testing.expectEqualSlices(i64, &.{ 3, 1, 3, 1 }, buf[0..len]);
    // 脱出の外へ出るときの `after` は、内側から順に呼ばれる。
    _ = try f.eval("(set! log '())");
    try f.expectInt(0, "(call/cc (lambda (out) (dynamic-wind (lambda () (note 1)) (lambda () (dynamic-wind (lambda () (note 2)) (lambda () (out 0)) (lambda () (note 3)))) (lambda () (note 4)))))");
    len = fixnums(try f.eval("log"), &buf);
    try std.testing.expectEqualSlices(i64, &.{ 4, 3, 2, 1 }, buf[0..len]);
}

test "with no handler, a heap limit in the body of a dynamic-wind runs after once, and the line ends" {
    var f: Fixture = undefined;
    try f.initWith(small_heap);
    defer f.deinit();
    _ = try f.eval("(define n 0) (define (forever x) (+ 1 (forever x)))");
    try f.expectFails("heap limit exceeded", "(dynamic-wind (lambda () #f) (lambda () (forever 0)) (lambda () (set! n (+ n 1))))");
    try f.expectInt(1, "n");
    // 型の誤りでも同じである。脱出は列を空にするので、次の行には何も残らない。
    try f.expectFails("wrong type of argument to car", "(dynamic-wind (lambda () #f) (lambda () (car 5)) (lambda () (set! n (+ n 1))))");
    try f.expectInt(2, "n");
    // `after` の中の未処理の送出は、その点の外から脱出を続け、報告されるのはその値である。
    try f.expectFails("unbound variable: nope", "(dynamic-wind (lambda () #f) (lambda () (dynamic-wind (lambda () #f) (lambda () (car 5)) (lambda () nope))) (lambda () (set! n (+ n 1))))");
    try f.expectInt(3, "n");
}

test "a handler that escapes with call/cc from a heap limit in the body of a dynamic-wind runs after once, and the run can report the limit again" {
    var f: Fixture = undefined;
    try f.initWith(small_heap);
    defer f.deinit();
    _ = try f.eval(
        \\(define n 0) (define (forever x) (+ 1 (forever x)))
        \\(define (catch) (call/cc (lambda (k) (with-exception-handler (lambda (c) (k c))
        \\  (lambda () (dynamic-wind (lambda () #f) (lambda () (forever 0)) (lambda () (set! n (+ n 1)))))))))
    );
    const before = f.ctx.heap.collections;
    try std.testing.expectEqualStrings("heap limit exceeded", try conditionMessage(&f, "(catch)"));
    try f.expectInt(1, "n");
    const one = f.ctx.heap.collections - before;
    // 同じ実行の中で、もう一度上限に達する。脱出のあとの GC が余裕を見つけて報告済みの印を
    // 戻すので、2度目も GC が報告する。印が戻らなければ、2度目の再帰は上限の近くで毎ステップ
    // GC しながら、確保が断られるまで進む。
    try std.testing.expectEqualStrings("heap limit exceeded", try conditionMessage(&f, "(begin (catch) (catch))"));
    try f.expectInt(3, "n");
    try std.testing.expect(f.ctx.heap.collections - before <= 3 * one + 8);
}

test "every allocation of a rewind is made from the reserve" {
    var f: Fixture = undefined;
    try f.initWith(no_collection);
    defer f.deinit();
    // 列: 外側から、`after` と `before` が `(lambda () 7)` の wind 点 `w`、その内側にハンドラの
    // 点 `h`。継続 `inside` は `h` に、継続 `outside` は空の列にいる。
    const winder = try f.eval("(lambda () 7)");
    const w = try f.ctx.heap.create(DynPoint, .{ .parent = null, .depth = 1, .current_handler = null, .kind = .{ .wind = .{ .before = winder, .after = winder } } });
    const h = try handlerPoint(&f, winder);
    h.parent = w;
    h.depth = 2;
    const inside = try f.ctx.heap.create(value_mod.Continuation, .{ .kont = null, .dyn = h });
    const outside = try f.ctx.heap.create(value_mod.Continuation, .{ .kont = null, .dyn = null });
    try fillToLimit(&f);
    // 外へ出る: `h` を外し、`w` を外してから、その親の列で `after` を呼ぶ。
    var kont: ?*const Kont = null;
    var dyn: ?*const DynPoint = h;
    try std.testing.expectEqual(value_mod.Kind.unspecified, (try f.machine.invoke(&kont, &dyn, outside, .fromFixnum(5))).kind());
    var frame = kont.?;
    kont = frame.next;
    switch (try f.machine.rewind(&kont, &dyn, frame.step.rewind)) {
        .body => |entry| try std.testing.expectEqual(0, entry.env.values.len),
        .value => return error.TestUnexpectedResult,
    }
    try std.testing.expectEqual(null, dyn);
    try std.testing.expectEqual(null, kont.?.step.rewind.entered);
    // `after` が戻ると、着く。
    frame = kont.?;
    kont = frame.next;
    try std.testing.expectEqual(5, (try f.machine.rewind(&kont, &dyn, frame.step.rewind)).value.asFixnum().?);
    try std.testing.expectEqual(null, dyn);
    // 中へ入る: 経路を作り、`w` の親の列で `before` を呼ぶ。戻ったら `w` を積み、目標の列で着く。
    try std.testing.expectEqual(value_mod.Kind.unspecified, (try f.machine.invoke(&kont, &dyn, inside, .fromFixnum(6))).kind());
    frame = kont.?;
    kont = frame.next;
    try std.testing.expect(try f.machine.rewind(&kont, &dyn, frame.step.rewind) == .body);
    try std.testing.expectEqual(null, dyn);
    try std.testing.expectEqual(w, kont.?.step.rewind.entered.?.point);
    frame = kont.?;
    kont = frame.next;
    try std.testing.expectEqual(6, (try f.machine.rewind(&kont, &dyn, frame.step.rewind)).value.asFixnum().?);
    try std.testing.expectEqual(h, dyn.?);
    try std.testing.expect(f.ctx.heap.held() > f.ctx.heap.options.limit);
}

test "a continuation invoked with no wind point on the way arrives at once, without allocating" {
    var f: Fixture = undefined;
    try f.initWith(no_collection);
    defer f.deinit();
    const winder = try f.eval("(lambda () 7)");
    const h = try handlerPoint(&f, winder);
    const target = try f.ctx.heap.create(value_mod.Continuation, .{ .kont = null, .dyn = null });
    try fillToLimit(&f);
    const accounted = f.ctx.heap.accounted;
    var kont: ?*const Kont = null;
    var dyn: ?*const DynPoint = h;
    try std.testing.expectEqual(5, (try f.machine.invoke(&kont, &dyn, target, .fromFixnum(5))).asFixnum().?);
    try std.testing.expectEqual(null, dyn);
    // 最外の継続(目標が null)へは、送出された値として着く。
    dyn = h;
    try std.testing.expectError(error.Raised, f.machine.invoke(&kont, &dyn, null, .fromFixnum(6)));
    try std.testing.expectEqual(6, f.ctx.raised.?.asFixnum().?);
    try std.testing.expectEqual(null, dyn);
    try std.testing.expectEqual(accounted, f.ctx.heap.accounted);
}

test "a raise at the limit, the call of its handler and an escape through a wind point fit four times in the reserve" {
    // Why: 予約の大きさを決める測定である(docs/design/runtime.md の送出のための予約領域)。
    // 上限に達した状態で、送出と、ハンドラの呼び出しと、捕捉した継続への wind 点を通る脱出の
    // 予約の地点を1回ずつ通す。その確保の合計の4倍が、既定の予約に収まることを確かめる。
    // ハンドラの中の送出は、ほかの確保が上限に断られても、予約から数段重ねられる。
    var f: Fixture = undefined;
    try f.initWith(no_collection);
    defer f.deinit();
    const winder = try f.eval("(lambda () 7)");
    const handler = try f.eval("(lambda (c) c)");
    const w = try f.ctx.heap.create(DynPoint, .{ .parent = null, .depth = 1, .current_handler = null, .kind = .{ .wind = .{ .before = winder, .after = winder } } });
    const h = try handlerPoint(&f, handler);
    h.parent = w;
    h.depth = 2;
    const outside = try f.ctx.heap.create(value_mod.Continuation, .{ .kont = null, .dyn = null });
    try fillToLimit(&f);
    const start = f.ctx.heap.accounted;
    var kont: ?*const Kont = null;
    var dyn: ?*const DynPoint = h;
    try std.testing.expectEqual(error.Raised, f.ctx.raise("wrong type of argument to car", .{}));
    const call = (try f.machine.enterHandler(&kont, &dyn, f.ctx.raised.?, false)).?;
    try std.testing.expect(try f.machine.apply(&kont, &dyn, call, 1, .raise_reserve) == .body);
    _ = try f.machine.invoke(&kont, &dyn, outside, call.value);
    const frame = kont.?;
    kont = frame.next;
    try std.testing.expect(try f.machine.rewind(&kont, &dyn, frame.step.rewind) == .body);
    const used = f.ctx.heap.accounted - start;
    try std.testing.expect(used > 0);
    try std.testing.expect(4 * used <= heap_mod.default_raise_reserve);
}

test "values returns one value as it is, and anything else as a multiple-values object" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.expectInt(5, "(values 5)");
    const none = (try f.eval("(values)")).asMultipleValues().?;
    try std.testing.expectEqual(0, none.items.len);
    const some = (try f.eval("(values 1 2 3)")).asMultipleValues().?;
    try std.testing.expectEqual(3, some.items.len);
    // 書いた順に並ぶ。
    for (some.items, 1..) |item, i| try std.testing.expectEqual(@as(i64, @intCast(i)), item.asFixnum().?);
    // オペランドが、機械が自前のスタックに持つ数より多いとき。
    const many = (try f.eval("(values 1 2 3 4 5 6 7 8 9 10)")).asMultipleValues().?;
    try std.testing.expectEqual(10, many.items.len);
    try std.testing.expectEqual(10, many.items[9].asFixnum().?);
    // 0個の値の呼び出しのたびに、新しいオブジェクトができる。
    try std.testing.expect((try f.eval("(values)")).asMultipleValues().? != none);
}

test "call-with-values gives the consumer the values the producer returns" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.expectInt(3, "(call-with-values (lambda () (values 1 2)) +)");
    try f.expectInt(7, "(call-with-values (lambda () 7) (lambda (x) x))");
    try f.expectInt(0, "(call-with-values (lambda () (values)) +)");
    try f.expectInt(6, "(call-with-values (lambda () (values 1 2 3)) (lambda args (apply + args)))");
    // 引数の個数の誤りは、手続き呼び出しの誤りと同じである。
    try f.expectFails("wrong number of arguments: expected 1, got 2", "(call-with-values (lambda () (values 1 2)) (lambda (a) a))");
    try f.expectFails("wrong type of argument to call-with-values", "(call-with-values 1 +)");
    try f.expectFails("wrong type of argument to call-with-values", "(call-with-values (lambda () 1) 2)");
}

test "a frame that takes one value rejects multiple values, and the others do not" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const rejected = "wrong number of values: expected 1, got 2";
    try f.expectFails(rejected, "(+ 1 (values 1 2))");
    try f.expectFails(rejected, "(if (values 1 2) 1 2)");
    try f.expectFails(rejected, "(define x (values 1 2))");
    try f.expectFails("wrong number of values: expected 1, got 0", "(list (values))");
    // 捨てる群と、そのまま渡す群。
    try f.expectInt(3, "(begin (values 1 2) 3)");
    try f.expectInt(3, "((lambda () (values) 3))");
    try f.expectInt(4, "(call-with-values (lambda () (dynamic-wind (lambda () (values 1 2)) (lambda () (values 1 2)) (lambda () (values)))) (lambda (a b) (+ a b 1)))");
    try f.expectInt(3, "(call-with-values (lambda () (with-exception-handler (lambda (c) (values 1 2)) (lambda () (raise-continuable 'x)))) +)");
}

test "a continuation takes any number of values, through a rewind too" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.expectInt(3, "(call-with-values (lambda () (call/cc (lambda (k) (k 1 2)))) +)");
    try f.expectInt(0, "(call-with-values (lambda () (call/cc (lambda (k) (k)))) +)");
    try f.expectInt(3, "(call-with-values (lambda () (call/cc (lambda (k) (dynamic-wind (lambda () 0) (lambda () (k 1 2)) (lambda () 0))))) +)");
    // 巻き戻しの途中で呼ばれる `after` が、継続を0個の値で呼ぶ(予約領域から確保する)。
    try f.expectInt(0, "(call-with-values (lambda () (call/cc (lambda (k2) (call/cc (lambda (k) (dynamic-wind (lambda () 0) (lambda () (k 1)) k2)))))) +)");
    // 複数値を受けた継続の再起動は、受け手をもう一度呼ぶ。
    _ = try f.eval("(define k #f) (define total 0)");
    try f.expectInt(3, "(call-with-values (lambda () (call/cc (lambda (c) (set! k c) (values 1 2)))) (lambda (a b) (set! total (+ total a b)) total))");
    try f.expectInt(10, "(k 3 4)");
}

test "a continuation invoked with no values from the reserve makes its multiple values there" {
    var f: Fixture = undefined;
    try f.initWith(no_collection);
    defer f.deinit();
    // 継続を先に作り、呼び出しの引数の鎖もヒープを埋める前に作る。
    const k = try f.eval("(call/cc (lambda (k) k))");
    const call = try f.ctx.heap.create(Args, .{ .value = k, .next = null });
    try fillToLimit(&f);
    var kont: ?*const Kont = null;
    var dyn: ?*const DynPoint = null;
    // 巻き戻しの途中で呼ばれる `after` が継続のときと同じく、予約の budget で適用する。上限の
    // budget なら、0個の値の複数値のオブジェクトが作れず、HeapLimit になる。
    switch (try f.machine.apply(&kont, &dyn, call, 0, .raise_reserve)) {
        .value => |v| try std.testing.expect(v.kind() == .multiple_values),
        .body => return error.TestUnexpectedResult,
    }
    try std.testing.expect(f.ctx.heap.held() > f.ctx.heap.options.limit);
}

test "the consumer of call-with-values runs in tail position, and the producer does not" {
    var f: Fixture = undefined;
    try f.initIn(std.heap.smp_allocator, .{});
    defer f.deinit();
    _ = try f.eval("(define (loop n) (if (= n 0) 'done (call-with-values (lambda () (values (- n 1) 0)) (lambda (m z) (loop m)))))");
    f.machine.peak_depth = 0;
    _ = try f.eval("(loop 10)");
    const small = f.machine.peak_depth;
    f.machine.peak_depth = 0;
    _ = try f.eval("(loop 5000)");
    try std.testing.expectEqual(small, f.machine.peak_depth);
    // 対照: 生産者の中の呼び出しは、末尾位置でないので、回数に比例して深くなる。
    _ = try f.eval("(define (count n) (if (= n 0) 0 (call-with-values (lambda () (+ 1 (count (- n 1)))) (lambda (m) m))))");
    f.machine.peak_depth = 0;
    try f.expectInt(5000, "(count 5000)");
    try std.testing.expect(f.machine.peak_depth >= 5000);
}

test "multiple values survive a collection at every step, and are collected once nothing reaches them" {
    var f: Fixture = undefined;
    try f.initWith(.{ .stress = true });
    defer f.deinit();
    try f.expectInt(10, "(call-with-values (lambda () (values (list 1 2) (list 3 4) (list 5 6))) (lambda (a b c) (+ (car a) (car (cdr b)) (car c))))");
    // 再起動した継続が運ぶ複数値も、ステップごとの GC を越えて読める。
    _ = try f.eval("(define k #f) (define total 0)");
    try f.expectInt(3, "(call-with-values (lambda () (call/cc (lambda (c) (set! k c) (values (list 1) (list 2))))) (lambda (a b) (set! total (+ total (car a) (car b))) total))");
    try f.expectInt(10, "(k (list 3) (list 4))");
    f.ctx.heap.collect(Machine.Roots{ .ctx = &f.ctx, .env = null, .kont = null, .value = .unspecified_value, .dyn = null });
    try std.testing.expectEqual(0, f.ctx.heap.countOf(value_mod.MultipleValues));
}

/// The promise a test makes in a heap, not yet done, with `thunk` as its procedure.
fn lazyPromise(f: *Fixture, thunk: Value) !*value_mod.Promise {
    return f.ctx.heap.create(value_mod.Promise, .{ .done = false, .value = thunk, .forward = null });
}

test "forcing a promise that is done gives its value, and puts nothing on the continuation" {
    var f: Fixture = undefined;
    try f.initWith(no_collection);
    defer f.deinit();
    const p = try f.ctx.heap.create(value_mod.Promise, .{ .done = true, .value = .fromFixnum(7), .forward = null });
    var kont: ?*const Kont = null;
    const accounted = f.ctx.heap.accounted;
    switch (try f.machine.forceNext(&kont, p)) {
        .value => |v| try std.testing.expectEqual(7, v.asFixnum().?),
        .call => return error.TestUnexpectedResult,
    }
    try std.testing.expect(kont == null);
    try std.testing.expectEqual(accounted, f.ctx.heap.accounted);
}

test "forcing a promise that is not done calls its procedure, with a frame for the promise below" {
    var f: Fixture = undefined;
    try f.initWith(no_collection);
    defer f.deinit();
    const thunk = try f.eval("(lambda () 1)");
    const p = try lazyPromise(&f, thunk);
    var kont: ?*const Kont = null;
    switch (try f.machine.forceNext(&kont, p)) {
        .value => return error.TestUnexpectedResult,
        .call => |call| {
            // 呼び出しは、引数なしの手続き1つである。
            try std.testing.expect(call.value.isEqv(thunk));
            try std.testing.expect(call.next == null);
        },
    }
    try std.testing.expectEqual(1, kont.?.depth);
    try std.testing.expectEqual(p, kont.?.step.force_thunk);
}

test "forcing a promise that shares the state of another reads the state where it is" {
    var f: Fixture = undefined;
    try f.initWith(no_collection);
    defer f.deinit();
    const thunk = try f.eval("(lambda () 1)");
    const root = try lazyPromise(&f, thunk);
    const alias = try f.ctx.heap.create(value_mod.Promise, .{ .done = false, .value = .unspecified_value, .forward = root });
    var kont: ?*const Kont = null;
    // 別名の値は使わない。強制するのは、根の手続きである。
    switch (try f.machine.forceNext(&kont, alias)) {
        .value => return error.TestUnexpectedResult,
        .call => |call| try std.testing.expect(call.value.isEqv(thunk)),
    }
    // フレームは、強制を始めた約束を持つ。戻ったあとに、根を引き直すためである。
    try std.testing.expectEqual(alias, kont.?.step.force_thunk);
    // 根が値を持っていれば、別名からその値が返る。
    root.done = true;
    root.value = .fromFixnum(9);
    switch (try f.machine.forceNext(&kont, alias)) {
        .value => |v| try std.testing.expectEqual(9, v.asFixnum().?),
        .call => return error.TestUnexpectedResult,
    }
}

test "the state of the promise a procedure returned goes into the promise being forced" {
    const Promise = value_mod.Promise;
    // 返した約束が手続きを持つとき、手続きが移り、2つはその状態を共有する。
    var target: Promise = .{ .done = false, .value = .fromFixnum(1), .forward = null };
    var source: Promise = .{ .done = false, .value = .fromFixnum(2), .forward = null };
    Machine.mergePromise(&target, &source);
    try std.testing.expect(!target.done);
    try std.testing.expectEqual(2, target.value.asFixnum().?);
    try std.testing.expect(target.forward == null);
    try std.testing.expectEqual(&target, source.forward.?);
    try std.testing.expectEqual(&target, source.root());
    // 手放した約束は、手続きを持ち続けない。
    try std.testing.expectEqual(Value.unspecified, source.value);
    // 返した約束が値を持つとき、値が移る。持つものは変えないので、共有しない。
    var other: Promise = .{ .done = false, .value = .fromFixnum(1), .forward = null };
    var finished: Promise = .{ .done = true, .value = .fromFixnum(3), .forward = null };
    Machine.mergePromise(&other, &finished);
    try std.testing.expect(other.done);
    try std.testing.expectEqual(3, other.value.asFixnum().?);
    try std.testing.expect(finished.forward == null);
    try std.testing.expect(finished.done);
    try std.testing.expectEqual(3, finished.value.asFixnum().?);
}

test "a promise that already has its value keeps it when a procedure returns another" {
    const Promise = value_mod.Promise;
    var done: Promise = .{ .done = true, .value = .fromFixnum(1), .forward = null };
    var returned: Promise = .{ .done = true, .value = .fromFixnum(2), .forward = null };
    Machine.mergePromise(&done, &returned);
    try std.testing.expectEqual(1, done.value.asFixnum().?);
    var pending: Promise = .{ .done = false, .value = .fromFixnum(3), .forward = null };
    Machine.mergePromise(&done, &pending);
    try std.testing.expect(done.done);
    try std.testing.expectEqual(1, done.value.asFixnum().?);
    // 返された約束は、そのままである。
    try std.testing.expect(returned.forward == null);
    try std.testing.expect(pending.forward == null);
    try std.testing.expectEqual(3, pending.value.asFixnum().?);
}

test "a procedure that returns the promise being forced, or one that shares its state, changes nothing" {
    const Promise = value_mod.Promise;
    var target: Promise = .{ .done = false, .value = .fromFixnum(1), .forward = null };
    Machine.mergePromise(&target, &target);
    try std.testing.expect(!target.done);
    try std.testing.expectEqual(1, target.value.asFixnum().?);
    try std.testing.expect(target.forward == null);
    var alias: Promise = .{ .done = false, .value = .unspecified_value, .forward = &target };
    Machine.mergePromise(&target, &alias);
    try std.testing.expectEqual(1, target.value.asFixnum().?);
    try std.testing.expectEqual(&target, alias.forward.?);
    try std.testing.expectEqual(Value.unspecified, alias.value);
}

test "the state goes into the root when the promise being forced has come to share another's" {
    const Promise = value_mod.Promise;
    // 強制の途中で、強制している約束が別の約束の別名になっていたら、根が受け取る。
    var root: Promise = .{ .done = false, .value = .fromFixnum(1), .forward = null };
    var alias: Promise = .{ .done = false, .value = .unspecified_value, .forward = &root };
    var source: Promise = .{ .done = false, .value = .fromFixnum(2), .forward = null };
    Machine.mergePromise(&alias, &source);
    try std.testing.expectEqual(2, root.value.asFixnum().?);
    try std.testing.expectEqual(&root, source.forward.?);
    try std.testing.expectEqual(Value.unspecified, alias.value);
    // 返した約束が、根の別名の別名でも、同じ状態なので変わらない。
    var far: Promise = .{ .done = false, .value = .unspecified_value, .forward = &alias };
    Machine.mergePromise(&alias, &far);
    try std.testing.expectEqual(2, root.value.asFixnum().?);
}

test "a chain of forced promises does not grow the continuation" {
    var f: Fixture = undefined;
    try f.initIn(std.heap.smp_allocator, .{});
    defer f.deinit();
    _ = try f.eval("(define (chain n) (if (= n 0) (%make-promise #t 'done) (%make-promise #f (lambda () (chain (- n 1))))))");
    f.machine.peak_depth = 0;
    _ = try f.eval("(force (chain 10))");
    const small = f.machine.peak_depth;
    f.machine.peak_depth = 0;
    _ = try f.eval("(force (chain 5000))");
    try std.testing.expectEqual(small, f.machine.peak_depth);
    // 対照: 手続きの中で強制する(`delay` の中の `force`)連鎖は、末尾位置でないので、深くなる。
    // 上の比較が、深さを測れていることを確かめる。
    _ = try f.eval("(define (nest n) (if (= n 0) (%make-promise #t 0) (%make-promise #f (lambda () (%make-promise #t (+ 1 (force (nest (- n 1)))))))))");
    f.machine.peak_depth = 0;
    try f.expectInt(1000, "(force (nest 1000))");
    try std.testing.expect(f.machine.peak_depth >= 1000);
}

test "slow: a million promises in a chain are forced at the same depth" {
    try tier.slow();
    var f: Fixture = undefined;
    try f.initIn(std.heap.smp_allocator, .{});
    defer f.deinit();
    _ = try f.eval("(define (chain n) (if (= n 0) (%make-promise #t 'done) (%make-promise #f (lambda () (chain (- n 1))))))");
    f.machine.peak_depth = 0;
    _ = try f.eval("(force (chain 10))");
    const small = f.machine.peak_depth;
    f.machine.peak_depth = 0;
    _ = try f.eval("(force (chain 1000000))");
    try std.testing.expectEqual(small, f.machine.peak_depth);
}

test "a collection runs between the steps of a chain of promises, so the chain fits in the live data" {
    const n = 20000;
    const limit = 512 * 1024;
    // 連鎖が1つ進むごとに、約束が1つできる。全部を合わせると上限を超えるので、途中で回収
    // されなければ、上限を超える。
    try std.testing.expect(n * heap_mod.cellBytes(value_mod.Promise) > limit);
    for ([_]bool{ false, true }) |stress| {
        var f: Fixture = undefined;
        try f.initWith(.{ .limit = limit, .min_threshold = 16 * 1024, .stress = stress });
        defer f.deinit();
        _ = try f.eval("(define (chain n) (if (= n 0) (%make-promise #t 'done) (%make-promise #f (lambda () (chain (- n 1))))))");
        const before = f.ctx.heap.collections;
        const done = try f.eval(std.fmt.comptimePrint("(force (chain {d}))", .{n}));
        try std.testing.expectEqualStrings("done", f.ctx.heap.symbols.nameOf(done.asSymbol().?));
        try std.testing.expect(f.ctx.heap.collections > before);
    }
}

test "promises survive a collection at every step, and are collected once nothing reaches them" {
    var f: Fixture = undefined;
    try f.initWith(.{ .stress = true });
    defer f.deinit();
    // 約束が持つ値と、強制していない約束が持つ手続きの環境が、ステップごとの GC を越えて読める。
    try f.expectInt(6, "(+ (car (force (make-promise (list 1 2)))) (car (force (%make-promise #f (lambda () (%make-promise #t (list 5 6)))))))");
    // 連鎖で併合された約束(別名)も、強制のあとに回収を越えて同じ値を返す。
    _ = try f.eval("(define q (%make-promise #f (lambda () (%make-promise #t (list 8)))))");
    _ = try f.eval("(define p (%make-promise #f (lambda () q)))");
    try std.testing.expectEqual(8, (try f.eval("(car (force p))")).asFixnum().?);
    try std.testing.expectEqual(8, (try f.eval("(car (force q))")).asFixnum().?);
    _ = try f.eval("(define q 0) (define p 0)");
    f.ctx.heap.collect(Machine.Roots{ .ctx = &f.ctx, .env = null, .kont = null, .value = .unspecified_value, .dyn = null });
    try std.testing.expectEqual(0, f.ctx.heap.countOf(value_mod.Promise));
}
