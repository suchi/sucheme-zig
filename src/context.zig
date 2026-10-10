//! What the expander and the machine share between the lines of a session: the
//! GC heap and the arena beside it, the symbols, the global bindings, the
//! constants of the code, and the condition of the most recent error.

const std = @import("std");
const symbol = @import("symbol.zig");
const value_mod = @import("value.zig");
const env = @import("env.zig");
const arith = @import("prim/arith.zig");
const heap_mod = @import("heap.zig");
const Heap = heap_mod.Heap;
const Value = value_mod.Value;

/// What a step can fail with. `Raised` is not a Zig-level failure: it says that
/// a Scheme error was raised, and the condition that describes it is in
/// `Context.raised`. The failures of the host, such as memory, are the other one.
pub const Error = error{ OutOfMemory, Raised };

/// What the interpreter carries between lines: the heap and the arena, the
/// symbols and global bindings, the constants of the code, and the condition of
/// the most recent error.
pub const Context = struct {
    /// Where what the reader and the machine make is allocated, and collected:
    /// the pairs, the closures, the frames of calls and the continuation.
    heap: Heap,
    /// Where what the heap does not hold is allocated: the symbols, the global
    /// bindings, the core IR the expander builds, and the conditions. Nothing in
    /// it is freed before the interpreter is, and it is outside the limit of the
    /// heap, so an error can be reported when the heap is full.
    persist: std.mem.Allocator,
    symbols: symbol.Table = .{},
    globals: env.Global = .{},
    /// The constants of the code that refer to the heap: a quoted list, say. The
    /// code is not in the heap yet, so the collector cannot find them through it,
    /// and the expander lists them here. The slice that moves the code into the
    /// heap needs no list.
    code_roots: std.ArrayList(Value) = .empty,
    /// The condition raised by the most recent error, if the line was cut short
    /// by one.
    raised: ?*value_mod.Condition = null,

    /// A context whose global environment binds each primitive to its name.
    /// `persist` is the arena that outlives it and `gpa` the allocator the heap
    /// takes its objects from; `deinit` frees the heap and not the arena.
    pub fn init(persist: std.mem.Allocator, gpa: std.mem.Allocator) error{OutOfMemory}!Context {
        return initWithOptions(persist, gpa, .{});
    }

    pub fn initWithOptions(persist: std.mem.Allocator, gpa: std.mem.Allocator, options: heap_mod.Options) error{OutOfMemory}!Context {
        var ctx: Context = .{ .heap = .init(gpa, options), .persist = persist };
        errdefer ctx.heap.deinit();
        for (&arith.primitives) |*p| {
            const id = try ctx.symbols.intern(persist, p.name);
            try ctx.globals.define(persist, id, .fromPrimitive(p));
        }
        return ctx;
    }

    pub fn deinit(self: *Context) void {
        self.heap.deinit();
    }

    /// Tells the collector of the roots the context holds: the values of the
    /// global bindings and the constants of the code. The machine adds its own.
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
            error.HeapLimit => self.raise("heap limit exceeded", .{}),
        };
    }

    /// The message of the condition raised by the most recent error, or empty
    /// when none was. Valid until the next `raise` or `clearDiagnostic`.
    pub fn diagnostic(self: *const Context) []const u8 {
        return if (self.raised) |c| c.message else "";
    }

    pub fn clearDiagnostic(self: *Context) void {
        self.raised = null;
    }

    /// Raises an error: makes the condition with the message and keeps it in
    /// `raised`, and returns `error.Raised` for the caller to return, so a call
    /// site reads `return ctx.raise("...", .{})`. Nothing handles a raise yet, so
    /// it leaves the machine for the line it came from, which is the escape to
    /// the outermost continuation (docs/design/runtime.md, unhandled
    /// exceptions).
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
