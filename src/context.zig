//! What the expander and the machine share between the lines of a session: where
//! what outlives a line is allocated, the symbols, the global bindings, and the
//! condition of the most recent error.

const std = @import("std");
const symbol = @import("symbol.zig");
const value_mod = @import("value.zig");
const env = @import("env.zig");
const arith = @import("prim/arith.zig");

/// What a step can fail with. `Raised` is not a Zig-level failure: it says that
/// a Scheme error was raised, and the condition that describes it is in
/// `Context.raised`. The failures of the host, such as memory, are the other one.
pub const Error = error{ OutOfMemory, Raised };

/// What the interpreter carries between lines: where what outlives a line is
/// allocated, the symbols and global bindings, and the condition of the most
/// recent error.
pub const Context = struct {
    /// Where the data the reader builds, the symbols, the global bindings, the
    /// closures, the frames of calls and the conditions are allocated. Nothing in
    /// it is freed until slice 1g replaces it with the GC heap, so a program that
    /// makes many calls grows it by a frame and its arguments each.
    persist: std.mem.Allocator,
    symbols: symbol.Table = .{},
    globals: env.Global = .{},
    /// The condition raised by the most recent error, if the line was cut short
    /// by one.
    raised: ?*value_mod.Condition = null,

    /// A context whose global environment binds each primitive to its name.
    pub fn init(persist: std.mem.Allocator) error{OutOfMemory}!Context {
        var ctx: Context = .{ .persist = persist };
        for (&arith.primitives) |*p| {
            const id = try ctx.symbols.intern(persist, p.name);
            try ctx.globals.define(persist, id, .fromPrimitive(p));
        }
        return ctx;
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
    var ctx = try Context.init(arena.allocator());
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
    var ctx = try Context.init(a);
    try std.testing.expectEqual(error.Raised, ctx.raise("unbound variable: {s}", .{name}));
    try std.testing.expectEqual("unbound variable: ".len + name.len, ctx.diagnostic().len);
}

test "a later raise replaces the condition of the earlier one" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var ctx = try Context.init(arena.allocator());
    _ = ctx.raise("first", .{}) catch {};
    _ = ctx.raise("second", .{}) catch {};
    try std.testing.expectEqualStrings("second", ctx.diagnostic());
}

test "a context binds each primitive to its name" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var ctx = try Context.init(arena.allocator());
    const id = try ctx.symbols.intern(arena.allocator(), "+");
    try std.testing.expectEqualStrings("+", ctx.globals.lookup(id).?.asPrimitive().?.name);
}
