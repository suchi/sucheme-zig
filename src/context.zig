//! What the expander and the machine share between the lines of a session: the
//! GC heap (which holds the symbols and the code) and the arena beside it, the bindings
//! of the top level, and the value the most recent error raised.

const std = @import("std");
const symbol = @import("symbol.zig");
const value_mod = @import("value.zig");
const env = @import("env.zig");
const table = @import("prim/table.zig");
const heap_mod = @import("heap.zig");
const library = @import("syntax/library.zig");
const resolve = @import("resolve.zig");
const platform = @import("platform/native.zig");
const positions_mod = @import("positions.zig");
const Heap = heap_mod.Heap;
const Value = value_mod.Value;

/// What a step can fail with.
/// `Raised` は Zig レベルの失敗ではない。Scheme のエラーが送出されたことを表し、
/// 送出された値は `Context.raised` にある。ほかの2つは送出できない失敗である。
/// `OutOfMemory` はホストのメモリが尽きたこと、`ReserveExhausted` は上限に達した状態で
/// 送出のための予約領域も尽き、条件オブジェクトを作れなかったことを表す。どちらも
/// `raised` を空のまま返し、その行を終える(docs/design/runtime.md の上限超過と確保の失敗)。
/// `StepLimit` は、1つの最上位の形式が `step_limit` の歩数を使い切ったことを表す。ハンドラに
/// 渡さず、`dynamic-wind` の `after` も呼ばずに、その形式を終える(計画書 0024)。
/// ヒープの `HeapLimit` はこの集合に入れない。ヒープの確保を素の `try` で返すと
/// コンパイルエラーになり、`heapFailure` を通して送出することを型が強いる。
/// `Exited` は、プログラムが `exit` か `emergency-exit` を呼んだことを表す(R7RS 6.14)。
/// 終了コードは `Context.exit_code` にある。`exit` は、途中の `dynamic-wind` の `after` を
/// すべて呼んでから返す(src/machine.zig)。
/// `NeedsInput` は、機械の内側の経路で、読み取りが入力待ちになったことを `Machine.step` まで
/// 運ぶ。`step` が `Outcome.needs_input` に変えるので、機械の外には出ない。
pub const Error = error{ OutOfMemory, Raised, ReserveExhausted, StepLimit, WriteFailed, Exited, NeedsInput };

/// What the error is called when the heap cannot hold more.
/// 1か所にまとめてあるので、どの経路で到達してもメッセージは同じになる。
pub const heap_limit_message = "heap limit exceeded";

/// What the interpreter carries between lines: the heap and the arena, the
/// global bindings, and the value the most recent error raised.
pub const Context = struct {
    /// Where what the reader, the expander and the machine make is allocated, and
    /// collected: the pairs, the core IR, the closures, the frames of calls, the
    /// continuations, the argument lists, the strings, the vectors and the conditions.
    heap: Heap,
    /// Where what the heap does not hold, and does not count, is allocated: the
    /// table of `(sucheme core)`.
    /// 大域変数のセルとコアIRの節点は GC ヒープにある。最上位の束縛の表は、ここでなく
    /// `resident` にある。この中のものは、インタプリタが解放されるまで解放されない。
    persist: std.mem.Allocator,
    /// The bindings of the REPL's top level: what it imports from `core`, and the
    /// variables and macros it defines (src/env.zig).
    /// 特殊形式の名前は予約語ではなく、REPL の最上位の構文の束縛である。
    globals: env.Global = .{},
    /// What `(sucheme core)` exports: the special forms, the auxiliary syntax and
    /// the primitives (src/env.zig).
    /// アリーナにあるのは、`globals` がこれを指すので、コンテキストを動かしても
    /// アドレスが変わらないようにするためである。
    core: *env.Core,
    /// The libraries a program has defined, and the forms being processed
    /// (src/syntax/library.zig).
    libraries: library.Registry = .{},
    /// The tables of the top levels that `environment` made (R7RS 6.12), each
    /// freed when nothing reaches its root any more.
    environments: Environments = .{},
    /// The registers of the machines that are waiting on nested work, the
    /// innermost first (`Suspended`).
    suspended: ?*const Suspended = null,
    /// What the files of the libraries are opened with, when the host has a file
    /// system (src/resolve.zig).
    /// WASM は実ファイルシステムを持たないので、空のままである。このとき、ライブラリの
    /// ファイルを引く経路は、見つからないことになる。
    files: ?resolve.Files = null,
    /// The files the file ports have open, when the host has a file system
    /// (src/platform/native.zig). The heap reaches it through `Heap.files`.
    /// ヒープの `deinit` が開いたポートを閉じるときに使うので、ヒープより後に解放する。
    file_table: ?*platform.FileTable = null,
    /// The source files the executable carries (src/resolve.zig). They are searched
    /// before the files of `files`, and WASM searches only these.
    embedded: ?resolve.Embedded = null,
    /// The files being read, the innermost last: the file of a library being loaded,
    /// and each file an `include` reads (src/syntax/source.zig).
    /// 含むファイルのディレクトリが `include` の基準になり、含んでいる最中のファイルを
    /// もう一度含むことは、ここで見つけて拒否する。REPL の行は、ここに何も載せない。
    sources: std.ArrayList(resolve.Origin) = .empty,
    /// Whether any program may import `(sucheme core)`, and not only the libraries
    /// the executable carries (`coreImportable`).
    /// Why: ライブラリの仕組みを試す単体テストは、`lib/` の標準ライブラリを持たずに、`define`
    /// や `lambda` をインポートで得る必要がある。製品の経路は、これを立てない
    /// (docs/adr/0037-core-library-exposed-in-stage-2.md の段階3の取り消し)。
    core_open: bool = false,
    /// The value the most recent error raised, if the line was cut short by
    /// one.
    /// 段階2のスライス 2b からは、条件オブジェクトに限らない `Value` である(R7RS 6.11 は
    /// 何でも送出できるとする)。ヒープを指しうるので GC のルートであり(`mark`)、
    /// `clearDiagnostic` で空にするまで回収されない。
    raised: ?Value = null,
    /// The exit code of the last `exit` or `emergency-exit`, which `error.Exited`
    /// stands for (docs/design/platform-and-web.md, the table of `exit`).
    exit_code: i32 = 0,
    /// Where in a file the expander was when it raised a value, and the value.
    /// 位置は、`raised` がその値であるときだけ意味を持つ(`raisedPosition`)。値も GC の
    /// ルートにする。回収された値の番地が新しい条件に使い回されると、無関係な位置を指すため
    /// である。
    raised_at: ?RaisedAt = null,
    /// The positions of the pairs of the form being read and expanded
    /// (src/positions.zig), or null when none are kept.
    /// 表の鍵のペアは GC のルートである(`mark`)。
    positions: ?*positions_mod.Table = null,
    /// The parameters that are the current ports, and where the console writes
    /// (R7RS 6.13.1 `current-input-port` and the others).
    /// パラメータは、`%console-parameter` が最初に呼ばれたときに作り(src/prim/port.zig)、
    /// 作ったあとは GC のルートにする(`mark`)。プリミティブには `Services.console` として渡る
    /// (src/machine.zig)。書き先は、`Interpreter` が実行の間だけ置く。
    console: value_mod.Console = .{},
    /// The mark the next application of a macro takes.
    /// 対話の全体で1つの通し番号で、周回させない(`newMark`)。マクロの定義は行をまたいで
    /// 残り、その規則が別名を含みうるので、行ごとに数え直すことはできない。
    next_mark: u64 = 0,
    /// The most steps one run of the machine may take, or null for no limit.
    /// 機械は、`Machine.run` の1回ごとに残りをこの値に戻す(src/machine.zig)。既定は上限なしで、
    /// 準拠スイートの実行器だけが置く(計画書 0024)。
    step_limit: ?u64 = null,
    /// A request, set from outside, that the machine give control back at its next step
    /// (`Machine.step` reports `interrupted`, and takes the request down).
    /// Why: 割り込みはシグナルハンドラや別スレッドからも立てうるので、アトミックにする。
    /// 機械は歩の境目で見る。`Machine.run` は見ない。
    interrupt: std.atomic.Value(bool) = .init(false),
    /// The registers of a machine whose run `Machine.step` has given control back from,
    /// or null when no run is parked.
    /// 停止中は、機械のレジスタ以外にヒープの値を持つものが無いので、これを GC のルートにする
    /// (`mark`)。
    parked: ?Parked = null,

    /// A context whose top level imports everything `(sucheme core)` exports.
    /// `persist` は、コンテキストより長生きするアリーナである。`gpa` は、ヒープが
    /// オブジェクトを確保するアロケータである。`deinit` が解放するのはヒープで、
    /// アリーナではない。
    pub fn init(persist: std.mem.Allocator, gpa: std.mem.Allocator) error{OutOfMemory}!Context {
        return initWithOptions(persist, gpa, .{});
    }

    pub fn initWithOptions(persist: std.mem.Allocator, gpa: std.mem.Allocator, options: heap_mod.Options) error{OutOfMemory}!Context {
        const core = try persist.create(env.Core);
        core.* = .{};
        var ctx: Context = .{ .heap = .init(gpa, options), .persist = persist, .core = core };
        errdefer ctx.heap.deinit();
        for (&table.all) |*p| {
            const id = try ctx.heap.internFixed(p.name);
            try core.addPrimitive(persist, id, p);
        }
        for (std.enums.values(value_mod.Special)) |special| {
            const id = try ctx.heap.internFixed(@tagName(special));
            try core.addSyntax(persist, id, .{ .special = special });
        }
        for (std.enums.values(value_mod.Auxiliary)) |auxiliary| {
            const id = try ctx.heap.internFixed(auxiliary.spelling());
            try core.addSyntax(persist, id, .{ .auxiliary = auxiliary });
        }
        ctx.globals.base = core;
        return ctx;
    }

    /// Frees the heap, and the tables that count against its limit.
    /// アリーナにあるもの(`core`)は、アリーナの持ち主が捨てる。
    pub fn deinit(self: *Context) void {
        const tables = self.resident();
        self.globals.deinit(tables);
        self.libraries.deinit(tables);
        self.environments.deinit(tables);
        self.sources.deinit(tables);
        self.heap.deinit();
        if (self.file_table) |t| t.deinit();
    }

    /// Where the tables of the top levels, the registry of the libraries and the
    /// files being read are allocated: they count against the limit of the heap
    /// for as long as they are held (ADR-0040).
    /// Why: 表は、インポートした名前の数に比例して伸び、セッションの間ずっと残る。永続
    /// アリーナに置くと、上限の外で伸び続ける。断られた確保は `error.OutOfMemory` に見えるので、
    /// 最上位の入口が `limitFailure` で上限の超過に変える。
    pub fn resident(self: *Context) std.mem.Allocator {
        return self.heap.residentAllocator();
    }

    /// The error `e` is, once a refusal of the limit is told apart from the host's
    /// memory running out: "heap limit exceeded" when the heap refused a charged
    /// allocation, which its caller saw as `error.OutOfMemory`.
    /// 判定に使う印は、入口が処理を始める前に `heap.external_refused` を下ろしておくこと。
    pub fn limitFailure(self: *Context, e: Error) Error {
        if (e == error.OutOfMemory and self.heap.external_refused) return self.raise(heap_limit_message, .{});
        return e;
    }

    /// Whether the program being processed may import `(sucheme core)`.
    ///
    /// 実行ファイルに埋め込んだ標準ライブラリの本体だけが、取り込める。読んでいる最中の
    /// ファイルの一番内側が埋め込みのものなら、そのライブラリの宣言を処理している。REPL の
    /// 行と、実ファイルのライブラリは、`sources` の一番内側が埋め込みではないので、拒否される。
    pub fn coreImportable(self: *const Context) bool {
        if (self.core_open) return true;
        const innermost = self.sources.getLastOrNull() orelse return false;
        return resolve.isEmbeddedRoot(innermost.root);
    }

    /// Tells the collector of the roots the context holds: the cells of the
    /// global variables and of `core`, the libraries, and the value raised.
    /// 機械は自分のルート(制御のレジスタを含む)を加える。機械の実行をまたいでヒープの値を
    /// 持つものは、すべてここに挙げる(ADR-0035、ADR-0040)。コードの定数と名前は、節点から
    /// 辿られる。
    pub fn mark(self: *const Context, marker: *heap_mod.Marker) void {
        self.globals.mark(marker);
        self.core.mark(marker);
        self.libraries.mark(marker);
        self.environments.mark(marker);
        var waiting = self.suspended;
        while (waiting) |s| : (waiting = s.next) s.mark(marker);
        if (self.parked) |p| p.mark(marker);
        if (self.raised) |v| marker.value(v);
        if (self.raised_at) |at| marker.value(at.value);
        if (self.positions) |kept| kept.mark(marker);
        for ([_]?*value_mod.Parameter{ self.console.input, self.console.output, self.console.error_output }) |param| {
            if (param) |p| marker.object(value_mod.Parameter, p);
        }
    }

    /// What a parked machine holds (`parked`): the registers a step reads and writes.
    pub const Parked = struct {
        control: ?*const value_mod.Node,
        env: ?*value_mod.Frame,
        kont: ?*const value_mod.Kont,
        value: Value,
        dyn: ?*const value_mod.DynPoint,

        pub fn mark(self: Parked, marker: *heap_mod.Marker) void {
            if (self.control) |node| marker.object(value_mod.Node, node);
            marker.value(self.value);
            marker.frame(self.env);
            marker.kont(self.kont);
            marker.dynPoint(self.dyn);
        }
    };

    pub const RaisedAt = struct { value: Value, position: positions_mod.Position };

    /// The registers of a machine that waits, in the middle of a step, on work that
    /// may run another machine and collect: what it continues with, where in the
    /// dynamic state it is, and the arguments of the call it is applying.
    /// Why: GC のルートは、走っている機械のレジスタと `Context` だけである(`Machine.collect`)。
    /// `environment` の輸入集合はライブラリのファイルを読んで本体を走らせることがあり、
    /// その中の機械が GC すると、外側の機械のレジスタが辿られない。外側の機械は、入れ子の
    /// 作業の前にこれを積み、戻ったら外す(スライス 5o、計画書 0019 の合意を求める点の9)。
    pub const Suspended = struct {
        kont: ?*const value_mod.Kont,
        dyn: ?*const value_mod.DynPoint,
        args: ?*const value_mod.Args,
        next: ?*const Suspended,

        pub fn mark(self: *const Suspended, marker: *heap_mod.Marker) void {
            marker.kont(self.kont);
            marker.dynPoint(self.dyn);
            if (self.args) |a| marker.object(value_mod.Args, a);
        }
    };

    /// The tables of the top levels of the environment specifiers that
    /// `environment` made, in slots that a freed table leaves for the next.
    /// 表はヒープの外(`resident`)にあり、上限に数える。根の環境(`SyntacticEnv`)が
    /// 番号で指す。マークは、生きている表をすべて強くマークし、マークの後で、根に届かなかった
    /// 表を解放する(`prune`)。表のセルは、表が解放された次の GC で回収される。
    pub const Environments = struct {
        slots: std.ArrayList(?Slot) = .empty,
        weak: heap_mod.Weak = .{ .prune = prune },

        const Slot = struct { table: *env.Global, root: *const value_mod.SyntacticEnv };

        /// Puts `table` in a free slot, for the root `root` to name.
        pub fn add(self: *Environments, alloc: std.mem.Allocator, top: *env.Global, root: *const value_mod.SyntacticEnv) error{OutOfMemory}!value_mod.EnvironmentTable {
            for (self.slots.items, 0..) |slot, i| {
                if (slot != null) continue;
                self.slots.items[i] = .{ .table = top, .root = root };
                return @fromBackingInt(@intCast(i));
            }
            try self.slots.append(alloc, .{ .table = top, .root = root });
            return @fromBackingInt(@intCast(self.slots.items.len - 1));
        }

        /// The table in the slot `id`, which must be live.
        pub fn table(self: *const Environments, id: value_mod.EnvironmentTable) *env.Global {
            return self.slots.items[@backingInt(id)].?.table;
        }

        pub fn mark(self: *const Environments, marker: *heap_mod.Marker) void {
            // Why: 自分の刈り取りは、表それぞれの刈り取り(`Global` の弱い項目)より後に走らせる。
            // 刈り取りは登録の新しい順に走るので、表をマークする前に登録する。先に表を解放すると、
            // 表の刈り取りが解放済みの表を読む。
            if (self.slots.items.len != 0) marker.holdWeakly(@constCast(&self.weak));
            for (self.slots.items) |slot| if (slot) |s| s.table.mark(marker);
        }

        fn prune(w: *heap_mod.Weak, heap: *heap_mod.Heap) void {
            const self: *Environments = @fieldParentPtr("weak", w);
            const alloc = heap.residentAllocator();
            for (self.slots.items) |*slot| {
                const s = slot.* orelse continue;
                if (heap.isMarked(value_mod.SyntacticEnv, s.root)) continue;
                s.table.deinit(alloc);
                alloc.destroy(s.table);
                slot.* = null;
            }
        }

        pub fn deinit(self: *Environments, alloc: std.mem.Allocator) void {
            for (self.slots.items) |slot| if (slot) |s| {
                s.table.deinit(alloc);
                alloc.destroy(s.table);
            };
            self.slots.deinit(alloc);
        }
    };

    /// Keeps that the value just raised was raised at `position`, unless a
    /// place has been kept for it already: the innermost form keeps it first.
    pub fn noteRaisedAt(self: *Context, position: ?positions_mod.Position) void {
        const at = position orelse return;
        const v = self.raised orelse return;
        if (self.raisedPosition() != null) return;
        self.raised_at = .{ .value = v, .position = at };
    }

    /// Where the value raised was raised, when it is known.
    pub fn raisedPosition(self: *const Context) ?positions_mod.Position {
        const at = self.raised_at orelse return null;
        const v = self.raised orelse return null;
        return if (v.isEq(at.value)) at.position else null;
    }

    /// A mark that no application of a macro has had (docs/design/frontend.md).
    /// Why: 印が周回すると、周回の後の展開が導入した識別子が、前の展開の束縛と同じ
    /// 識別子になり、衛生性が黙って壊れる。最後の値に達したら、実装制限(R7RS 1.3.2)
    /// として報告する。
    pub fn newMark(self: *Context) Error!u64 {
        if (self.next_mark == std.math.maxInt(u64))
            return self.raise("implementation restriction: too many macro applications", .{});
        defer self.next_mark += 1;
        return self.next_mark;
    }

    /// The symbol named `name`, interned first if it is new; a name the limit
    /// has no room for is the error "heap limit exceeded".
    pub fn intern(self: *Context, name: []const u8) Error!symbol.SymbolId {
        return self.heap.intern(name) catch |e| return self.heapFailure(e);
    }

    /// Collects between two lines, where the only roots are the context's own.
    pub fn collectIdle(self: *Context) void {
        self.heap.collect(IdleRoots{ .ctx = self });
    }

    const IdleRoots = struct {
        ctx: *const Context,

        pub fn mark(self: IdleRoots, marker: *heap_mod.Marker) void {
            self.ctx.mark(marker);
        }
    };

    /// A new object holding `value`; an allocation the limit refuses is the
    /// error "heap limit exceeded".
    pub fn create(self: *Context, comptime T: type, value: T) Error!*T {
        return self.createIn(.limit, T, value);
    }

    /// A new object holding `value`, held to `budget`.
    /// `.limit` の確保が断られたら "heap limit exceeded" を送出し、送出のための予約からの
    /// 確保が断られたら `error.ReserveExhausted` を返す(`makeCondition` と同じ作法)。
    pub fn createIn(self: *Context, budget: heap_mod.Budget, comptime T: type, value: T) Error!*T {
        return self.heap.createIn(budget, T, value) catch |e| return self.budgetFailure(budget, e);
    }

    /// A new frame of `size` slots, all uninitialized, behind `parent`.
    pub fn createFrame(self: *Context, size: usize, parent: ?*value_mod.Frame) Error!*value_mod.Frame {
        return self.createFrameIn(.limit, size, parent);
    }

    /// A new frame of `size` slots, all uninitialized, behind `parent`, held
    /// to `budget`.
    pub fn createFrameIn(self: *Context, budget: heap_mod.Budget, size: usize, parent: ?*value_mod.Frame) Error!*value_mod.Frame {
        return self.heap.createFrameIn(budget, size, parent) catch |e| return self.budgetFailure(budget, e);
    }

    /// A new multiple-values object of a copy of `items`, held to `budget`.
    /// 個数は 0 か 2 以上でなければならない。
    pub fn createValuesIn(self: *Context, budget: heap_mod.Budget, items: []const Value) Error!*value_mod.MultipleValues {
        return self.heap.createMultipleValuesIn(budget, items) catch |e| return self.budgetFailure(budget, e);
    }

    /// The error an allocation held to `budget` fails with.
    fn budgetFailure(self: *Context, budget: heap_mod.Budget, e: heap_mod.Error) Error {
        return switch (budget) {
            .limit => self.heapFailure(e),
            .raise_reserve => reserveFailure(e),
        };
    }

    pub fn heapFailure(self: *Context, e: heap_mod.Error) Error {
        return switch (e) {
            error.OutOfMemory => error.OutOfMemory,
            error.HeapLimit => self.raise(heap_limit_message, .{}),
        };
    }

    /// The message of the condition raised by the most recent error, or empty
    /// when none was or what was raised is not a condition.
    /// 次の `raise` または `clearDiagnostic` まで有効である。送出された値の全体を
    /// 説明するのは `Interpreter.diagnostic` である。
    pub fn diagnostic(self: *const Context) []const u8 {
        const v = self.raised orelse return "";
        const c = v.asCondition() orelse return "";
        return c.messageText();
    }

    pub fn clearDiagnostic(self: *Context) void {
        self.raised = null;
        self.raised_at = null;
    }

    /// Raises an error: makes the condition with the message and keeps it in
    /// `raised`, and returns `error.Raised` for the caller to return, so a call
    /// site reads `return ctx.raise("...", .{})`.
    /// 機械のステップの中で返せば、`Machine.run` がレジスタを書き戻してから、送出された値を
    /// 現在の例外ハンドラに渡す。ハンドラが無いときと、展開器とリーダが返したときは、
    /// その行の読み取りまで戻る。これは最も外側の継続への脱出である(docs/design/runtime.md
    /// の未処理の例外)。条件を作れなければ、`makeCondition` の失敗をそのまま返し、`raised`
    /// は変えない。
    pub fn raise(self: *Context, comptime fmt: []const u8, args: anytype) Error {
        self.raised = try self.makeCondition(.@"error", fmt, args, .empty_list_value);
        return error.Raised;
    }

    /// A new condition of `kind`, with the message `fmt` formatted with `args`
    /// and the list `irritants`.
    /// 条件とメッセージは、送出のための予約領域を使ってよい確保地点である。上限に
    /// 達していても、予約が残っていれば作れる。予約も尽きたときは `error.ReserveExhausted`
    /// を返す。メッセージの確保とこの条件の確保の間に GC は走らない(ADR-0031)ので、
    /// `irritants` とメッセージはどこにも登録しなくてよい。
    pub fn makeCondition(self: *Context, kind: value_mod.ConditionKind, comptime fmt: []const u8, args: anytype, irritants: Value) Error!Value {
        const message = self.heap.printString(.raise_reserve, fmt, args) catch |e| return reserveFailure(e);
        const condition = self.heap.createIn(.raise_reserve, value_mod.Condition, .{
            .kind = kind,
            .message = .fromString(message),
            .irritants = irritants,
        }) catch |e| return reserveFailure(e);
        return .fromCondition(condition);
    }

    /// The error an allocation from the reserve for raising fails with.
    fn reserveFailure(e: heap_mod.Error) Error {
        return switch (e) {
            error.OutOfMemory => error.OutOfMemory,
            error.HeapLimit => error.ReserveExhausted,
        };
    }
};

test {
    std.testing.refAllDecls(@This());
}

test "coreImportable is true only inside an embedded library, or when the context is open" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var ctx = try Context.init(arena.allocator(), std.testing.allocator);
    defer ctx.deinit();
    // REPL の行は、`sources` に何も載せない。
    try std.testing.expect(!ctx.coreImportable());
    // 実ファイルのライブラリ。
    try ctx.sources.append(ctx.resident(), .{ .root = "libs", .path = &.{"a.sld"} });
    try std.testing.expect(!ctx.coreImportable());
    // 埋め込みのライブラリ。
    try ctx.sources.append(ctx.resident(), .{ .root = resolve.embedded_root, .path = &.{"base.sld"} });
    try std.testing.expect(ctx.coreImportable());
    // 一番内側が決める。埋め込みのライブラリが、実ファイルを含むことはないが、判定は内側だけを見る。
    try ctx.sources.append(ctx.resident(), .{ .root = "libs", .path = &.{"b.sld"} });
    try std.testing.expect(!ctx.coreImportable());
    ctx.sources.clearRetainingCapacity();
    ctx.core_open = true;
    try std.testing.expect(ctx.coreImportable());
}

test "raise keeps a condition with the message, and returns Raised" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var ctx = try Context.init(arena.allocator(), std.testing.allocator);
    defer ctx.deinit();
    try std.testing.expect(ctx.raised == null);
    try std.testing.expectEqualStrings("", ctx.diagnostic());
    try std.testing.expectEqual(error.Raised, ctx.raise("bad {s} {d}", .{ "thing", 3 }));
    const condition = ctx.raised.?.asCondition().?;
    try std.testing.expectEqualStrings("bad thing 3", condition.messageText());
    try std.testing.expectEqual(value_mod.ConditionKind.@"error", condition.kind);
    try std.testing.expectEqual(value_mod.Kind.empty_list, condition.irritants.kind());
    try std.testing.expectEqualStrings("bad thing 3", ctx.diagnostic());
    ctx.clearDiagnostic();
    try std.testing.expect(ctx.raised == null);
    try std.testing.expectEqualStrings("", ctx.diagnostic());
}

test "the place of a raise belongs to the value raised, and the innermost place is kept" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var ctx = try Context.init(arena.allocator(), std.testing.allocator);
    defer ctx.deinit();
    const inner: positions_mod.Position = .{ .file = 0, .location = .{ .line = 2, .column = 3 } };
    const outer: positions_mod.Position = .{ .file = 0, .location = .{ .line = 1, .column = 1 } };
    // 何も送出していなければ、位置を持たない。
    ctx.noteRaisedAt(inner);
    try std.testing.expect(ctx.raisedPosition() == null);
    try std.testing.expectEqual(error.Raised, ctx.raise("first", .{}));
    ctx.noteRaisedAt(null);
    try std.testing.expect(ctx.raisedPosition() == null);
    ctx.noteRaisedAt(inner);
    ctx.noteRaisedAt(outer);
    try std.testing.expectEqual(inner, ctx.raisedPosition().?);
    // 別の値を送出したら、前の位置はその値のものではない。
    try std.testing.expectEqual(error.Raised, ctx.raise("second", .{}));
    try std.testing.expect(ctx.raisedPosition() == null);
    ctx.noteRaisedAt(outer);
    try std.testing.expectEqual(outer, ctx.raisedPosition().?);
    ctx.clearDiagnostic();
    try std.testing.expect(ctx.raised_at == null);
}

test "the pairs of the table of positions are roots while the context holds it" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var ctx = try Context.init(arena.allocator(), std.testing.allocator);
    defer ctx.deinit();
    var kept: positions_mod.Table = .init(std.testing.allocator);
    defer kept.deinit();
    const file = try kept.addFile("a.scm");
    // 表だけが持つペアは、表をコンテキストに置いている間は回収されず、外せば回収される。
    const pair = try ctx.heap.cons(.fromFixnum(1), .empty_list_value);
    try kept.record(pair.asPair().?, .{ .file = file, .location = .{} });
    ctx.positions = &kept;
    ctx.collectIdle();
    const held = ctx.heap.count;
    ctx.positions = null;
    ctx.collectIdle();
    try std.testing.expectEqual(held - 1, ctx.heap.count);
}

test "a message as long as the REPL's line is kept whole" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const name = try a.alloc(u8, 5000);
    @memset(name, 'x');
    var ctx = try Context.init(a, std.testing.allocator);
    defer ctx.deinit();
    try std.testing.expectEqual(error.Raised, ctx.raise("unbound variable: {s}", .{name}));
    try std.testing.expectEqual("unbound variable: ".len + name.len, ctx.diagnostic().len);
}

test "a later raise replaces the condition of the earlier one" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var ctx = try Context.init(arena.allocator(), std.testing.allocator);
    defer ctx.deinit();
    _ = ctx.raise("first", .{}) catch {};
    _ = ctx.raise("second", .{}) catch {};
    try std.testing.expectEqualStrings("second", ctx.diagnostic());
}

test "a context binds each primitive to its name" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var ctx = try Context.init(arena.allocator(), std.testing.allocator);
    defer ctx.deinit();
    const id = try ctx.heap.intern("+");
    try std.testing.expect(ctx.globals.isBound(id));
    // 初期化はヒープに何も作らない。プリミティブのセルは、名前を解決したときに作る。
    try std.testing.expectEqual(0, ctx.heap.count);
    const cell = (try ctx.globals.resolve(ctx.resident(), &ctx.heap, id)).global;
    try std.testing.expectEqualStrings("+", cell.value.asPrimitive().?.name);
}

test "an allocation the limit refuses is the error heap limit exceeded, for an object and for a frame" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    // どのオブジェクトも入らない上限。
    var ctx = try Context.initWithOptions(arena.allocator(), std.testing.allocator, .{ .limit = 1 });
    defer ctx.deinit();
    try std.testing.expectEqual(error.Raised, ctx.create(value_mod.Pair, .{ .car = .empty_list_value, .cdr = .empty_list_value }));
    try std.testing.expectEqualStrings("heap limit exceeded", ctx.diagnostic());
    ctx.clearDiagnostic();
    try std.testing.expectEqual(error.Raised, ctx.createFrame(2, null));
    try std.testing.expectEqualStrings("heap limit exceeded", ctx.diagnostic());
    // 断られたものは確保されていない。ヒープにあるのは、予約から作った2つの条件と
    // そのメッセージだけである。ホストの失敗は、このエラーではない。
    try std.testing.expectEqual(0, ctx.heap.countOf(value_mod.Pair));
    try std.testing.expectEqual(0, ctx.heap.countOf(value_mod.Frame));
    try std.testing.expectEqual(2, ctx.heap.countOf(value_mod.Condition));
    try std.testing.expectEqual(4, ctx.heap.count);
    try std.testing.expectEqual(error.OutOfMemory, ctx.heapFailure(error.OutOfMemory));
}

test "makeCondition keeps the kind, the message and the irritants it is given" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var ctx = try Context.init(arena.allocator(), std.testing.allocator);
    defer ctx.deinit();
    const irritants = try ctx.heap.cons(.fromFixnum(5), .empty_list_value);
    const v = try ctx.makeCondition(.file, "cannot open {s}", .{"x.scm"}, irritants);
    const c = v.asCondition().?;
    try std.testing.expectEqual(value_mod.ConditionKind.file, c.kind);
    try std.testing.expectEqualStrings("cannot open x.scm", c.messageText());
    try std.testing.expectEqual(irritants.asPair().?, c.irritants.asPair().?);
    // 作るだけで、送出はしない。
    try std.testing.expect(ctx.raised == null);
}

test "when the reserve is used up too, raise returns ReserveExhausted and leaves raised empty" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var ctx = try Context.initWithOptions(arena.allocator(), std.testing.allocator, .{ .limit = 1, .raise_reserve = 0 });
    defer ctx.deinit();
    try std.testing.expectEqual(error.ReserveExhausted, ctx.raise("first", .{}));
    try std.testing.expect(ctx.raised == null);
    try std.testing.expectEqualStrings("", ctx.diagnostic());
    // 上限の超過から送出に移るときも同じである。
    try std.testing.expectEqual(error.ReserveExhausted, ctx.create(value_mod.Pair, .{ .car = .empty_list_value, .cdr = .empty_list_value }));
    try std.testing.expect(ctx.raised == null);
    try std.testing.expectEqual(0, ctx.heap.count);
}

test "the value raised is a root until it is cleared" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    for ([_]usize{ 4096, 0 }) |capacity| {
        var ctx = try Context.initWithOptions(arena.allocator(), std.testing.allocator, .{ .work_capacity = capacity });
        defer ctx.deinit();
        _ = ctx.raise("kept {d}", .{1}) catch {};
        _ = try ctx.heap.cons(.fromFixnum(1), .empty_list_value);
        ctx.collectIdle();
        // 条件とメッセージが残り、ゴミのペアは回収された。
        try std.testing.expectEqual(1, ctx.heap.countOf(value_mod.Condition));
        try std.testing.expectEqual(1, ctx.heap.countOf(value_mod.String));
        try std.testing.expectEqual(2, ctx.heap.count);
        try std.testing.expectEqualStrings("kept 1", ctx.diagnostic());
        // 条件でない値も、送出された値ならルートである。
        ctx.raised = try ctx.heap.cons(.fromFixnum(2), .empty_list_value);
        ctx.collectIdle();
        try std.testing.expectEqual(1, ctx.heap.countOf(value_mod.Pair));
        try std.testing.expectEqual(0, ctx.heap.countOf(value_mod.Condition));
        ctx.clearDiagnostic();
        ctx.collectIdle();
        try std.testing.expectEqual(0, ctx.heap.count);
    }
}
