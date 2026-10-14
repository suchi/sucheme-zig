//! What the expander and the machine share between the lines of a session: the
//! GC heap and the arena beside it, the symbols, the bindings of the top level,
//! the constants of the code, and the value the most recent error raised.

const std = @import("std");
const symbol = @import("symbol.zig");
const value_mod = @import("value.zig");
const env = @import("env.zig");
const table = @import("prim/table.zig");
const heap_mod = @import("heap.zig");
const library = @import("syntax/library.zig");
const Heap = heap_mod.Heap;
const Value = value_mod.Value;

/// What a step can fail with.
/// `Raised` は Zig レベルの失敗ではない。Scheme のエラーが送出されたことを表し、
/// 送出された値は `Context.raised` にある。ほかの2つは送出できない失敗である。
/// `OutOfMemory` はホストのメモリが尽きたこと、`ReserveExhausted` は上限に達した状態で
/// 送出のための予約領域も尽き、条件オブジェクトを作れなかったことを表す。どちらも
/// `raised` を空のまま返し、その行を終える(docs/design/runtime.md の上限超過と確保の失敗)。
/// ヒープの `HeapLimit` はこの集合に入れない。ヒープの確保を素の `try` で返すと
/// コンパイルエラーになり、`heapFailure` を通して送出することを型が強いる。
pub const Error = error{ OutOfMemory, Raised, ReserveExhausted };

/// What the error is called when the heap cannot hold more.
/// 1か所にまとめてあるので、どの経路で到達してもメッセージは同じになる。
pub const heap_limit_message = "heap limit exceeded";

/// What the interpreter carries between lines: the heap and the arena, the
/// symbols and global bindings, the constants of the code, and the value the
/// most recent error raised.
pub const Context = struct {
    /// Where what the reader and the machine make is allocated, and collected:
    /// the pairs, the closures, the frames of calls, the continuations, the
    /// argument lists, the strings, the vectors and the conditions.
    heap: Heap,
    /// Where what the heap does not hold is allocated: the symbols, the table of
    /// the bindings of the top level and the core IR the expander builds.
    /// 大域変数のセルそのものは GC ヒープにある。
    /// この中のものは、インタプリタが解放されるまで解放されない。
    persist: std.mem.Allocator,
    symbols: symbol.Table = .{},
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
    /// The constants of the code that refer to the heap: a quoted list, say.
    /// コードはまだヒープにないので、GC はコードを通してそれらを見つけられない。
    /// そのため展開器がここに挙げる。コードをヒープに移すスライスでは、このリストは
    /// 要らなくなる。
    code_roots: std.ArrayList(Value) = .empty,
    /// The value the most recent error raised, if the line was cut short by
    /// one.
    /// 段階2のスライス 2b からは、条件オブジェクトに限らない `Value` である(R7RS 6.11 は
    /// 何でも送出できるとする)。ヒープを指しうるので GC のルートであり(`mark`)、
    /// `clearDiagnostic` で空にするまで回収されない。
    raised: ?Value = null,
    /// The mark the next application of a macro takes.
    /// 対話の全体で1つの通し番号で、周回させない(`newMark`)。マクロの定義は行をまたいで
    /// 残り、その規則が別名を含みうるので、行ごとに数え直すことはできない。
    next_mark: u64 = 0,

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
            const id = try ctx.symbols.intern(persist, p.name);
            try core.addPrimitive(persist, id, p);
        }
        for (std.enums.values(value_mod.Special)) |special| {
            const id = try ctx.symbols.intern(persist, @tagName(special));
            try core.addSyntax(persist, id, .{ .special = special });
        }
        for (std.enums.values(value_mod.Auxiliary)) |auxiliary| {
            const id = try ctx.symbols.intern(persist, auxiliary.spelling());
            try core.addSyntax(persist, id, .{ .auxiliary = auxiliary });
        }
        ctx.globals.base = core;
        return ctx;
    }

    pub fn deinit(self: *Context) void {
        self.heap.deinit();
    }

    /// Tells the collector of the roots the context holds: the cells of the
    /// global variables and of `core`, the libraries, the constants of the code and
    /// the value raised.
    /// 機械は自分のルートを加える。機械の実行をまたいでヒープの値を持つものは、
    /// すべてここに挙げる(ADR-0035)。
    pub fn mark(self: *const Context, marker: *heap_mod.Marker) void {
        self.globals.mark(marker);
        self.core.mark(marker);
        self.libraries.mark(marker);
        for (self.code_roots.items) |v| marker.value(v);
        if (self.raised) |v| marker.value(v);
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

    /// Keeps `v`, a constant of some code, alive for as long as the context is.
    pub fn keepConstant(self: *Context, v: Value) error{OutOfMemory}!void {
        if (v.pointsIntoHeap()) try self.code_roots.append(self.persist, v);
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
    const id = try ctx.symbols.intern(arena.allocator(), "+");
    try std.testing.expect(ctx.globals.isBound(id));
    // 初期化はヒープに何も作らない。プリミティブのセルは、名前を解決したときに作る。
    try std.testing.expectEqual(0, ctx.heap.count);
    const cell = (try ctx.globals.resolve(ctx.persist, &ctx.heap, id)).global;
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
