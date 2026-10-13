//! What the expander and the machine share between the lines of a session: the
//! GC heap and the arena beside it, the symbols, the global bindings, the
//! constants of the code, and the condition of the most recent error.

const std = @import("std");
const symbol = @import("symbol.zig");
const value_mod = @import("value.zig");
const env = @import("env.zig");
const table = @import("prim/table.zig");
const heap_mod = @import("heap.zig");
const Heap = heap_mod.Heap;
const Value = value_mod.Value;

/// What a step can fail with.
/// `Raised` は Zig レベルの失敗ではない。Scheme のエラーが送出されたことを表し、
/// それを説明する条件オブジェクトは `Context.raised` にある。メモリのような
/// ホストの失敗は、もう一方である。
pub const Error = error{ OutOfMemory, Raised };

/// What the error is called when the heap cannot hold more.
/// 1か所にまとめてあるので、どの経路で到達してもメッセージは同じになる。
pub const heap_limit_message = "heap limit exceeded";

/// What the interpreter carries between lines: the heap and the arena, the
/// symbols and global bindings, the constants of the code, and the condition of
/// the most recent error.
pub const Context = struct {
    /// Where what the reader and the machine make is allocated, and collected:
    /// the pairs, the closures, the frames of calls, the continuations, the
    /// argument lists, the strings and the vectors.
    heap: Heap,
    /// Where what the heap does not hold is allocated: the symbols, the global
    /// bindings, the core IR the expander builds, and the conditions.
    /// この中のものは、インタプリタが解放されるまで解放されない。またヒープの上限の外に
    /// あるので、ヒープが満杯でもエラーを報告できる。
    persist: std.mem.Allocator,
    symbols: symbol.Table = .{},
    globals: env.Global = .{},
    /// The special forms the top level of the REPL binds, by name.
    /// 特殊形式の名前は予約語ではなく、REPL の最上位の構文の束縛である
    /// (src/syntax/env.zig の解決)。値は GC ヒープを指さないので、GC のルートではない。
    /// スライス 2j で、REPL の束縛の表(大域変数のセルと同じ表)に移る。
    specials: std.AutoHashMapUnmanaged(symbol.SymbolId, value_mod.Special) = .empty,
    /// The constants of the code that refer to the heap: a quoted list, say.
    /// コードはまだヒープにないので、GC はコードを通してそれらを見つけられない。
    /// そのため展開器がここに挙げる。コードをヒープに移すスライスでは、このリストは
    /// 要らなくなる。
    code_roots: std.ArrayList(Value) = .empty,
    /// The condition raised by the most recent error, if the line was cut short
    /// by one.
    raised: ?*value_mod.Condition = null,

    /// A context whose global environment binds each primitive to its name, and
    /// whose top level binds each special form to its name.
    /// `persist` は、コンテキストより長生きするアリーナである。`gpa` は、ヒープが
    /// オブジェクトを確保するアロケータである。`deinit` が解放するのはヒープで、
    /// アリーナではない。
    pub fn init(persist: std.mem.Allocator, gpa: std.mem.Allocator) error{OutOfMemory}!Context {
        return initWithOptions(persist, gpa, .{});
    }

    pub fn initWithOptions(persist: std.mem.Allocator, gpa: std.mem.Allocator, options: heap_mod.Options) error{OutOfMemory}!Context {
        var ctx: Context = .{ .heap = .init(gpa, options), .persist = persist };
        errdefer ctx.heap.deinit();
        for (&table.all) |*p| {
            const id = try ctx.symbols.intern(persist, p.name);
            try ctx.globals.define(persist, id, .fromPrimitive(p));
        }
        for (std.enums.values(value_mod.Special)) |special| {
            const id = try ctx.symbols.intern(persist, @tagName(special));
            try ctx.specials.put(persist, id, special);
        }
        return ctx;
    }

    pub fn deinit(self: *Context) void {
        self.heap.deinit();
    }

    /// Tells the collector of the roots the context holds: the values of the
    /// global bindings and the constants of the code.
    /// 機械は自分のルートを加える。
    pub fn mark(self: *const Context, marker: *heap_mod.Marker) void {
        self.globals.mark(marker);
        for (self.code_roots.items) |v| marker.value(v);
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
        return self.heap.create(T, value) catch |e| return self.heapFailure(e);
    }

    /// A new frame of `size` slots, all uninitialized, behind `parent`.
    pub fn createFrame(self: *Context, size: usize, parent: ?*value_mod.Frame) Error!*value_mod.Frame {
        return self.heap.createFrame(size, parent) catch |e| return self.heapFailure(e);
    }

    pub fn heapFailure(self: *Context, e: heap_mod.Error) Error {
        return switch (e) {
            error.OutOfMemory => error.OutOfMemory,
            error.HeapLimit => self.raise(heap_limit_message, .{}),
        };
    }

    /// The message of the condition raised by the most recent error, or empty
    /// when none was.
    /// 次の `raise` または `clearDiagnostic` まで有効である。
    pub fn diagnostic(self: *const Context) []const u8 {
        return if (self.raised) |c| c.message else "";
    }

    pub fn clearDiagnostic(self: *Context) void {
        self.raised = null;
    }

    /// Raises an error: makes the condition with the message and keeps it in
    /// `raised`, and returns `error.Raised` for the caller to return, so a call
    /// site reads `return ctx.raise("...", .{})`.
    /// 送出を処理するものはまだないので、送出は機械を抜けて、その行の読み取りまで戻る。
    /// これは最も外側の継続への脱出である(docs/design/runtime.md の未処理の例外)。
    pub fn raise(self: *Context, comptime fmt: []const u8, args: anytype) Error {
        const message = std.fmt.allocPrint(self.persist, fmt, args) catch return error.OutOfMemory;
        const condition = self.persist.create(value_mod.Condition) catch return error.OutOfMemory;
        condition.* = .{ .message = message };
        self.raised = condition;
        return error.Raised;
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
    try std.testing.expectEqualStrings("bad thing 3", ctx.raised.?.message);
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
    try std.testing.expectEqualStrings("+", ctx.globals.lookup(id).?.asPrimitive().?.name);
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
    // 何も確保されておらず、ホストの失敗はこのエラーではない。
    try std.testing.expectEqual(0, ctx.heap.count);
    try std.testing.expectEqual(error.OutOfMemory, ctx.heapFailure(error.OutOfMemory));
}
