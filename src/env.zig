//! The global environment: which symbols are bound, and to what.
//!
//! A name that is absent is unbound, so slice 1b needs no marker value for it.
//! Local variables and the "uninitialized" state of an internal definition
//! arrive with `lambda` (slice 1d) and internal `define` (slice 1e), which are
//! what need them. The cells of docs/design/runtime.md, shared by `import`,
//! arrive with the library system in stage 2.

const std = @import("std");
const SymbolId = @import("symbol.zig").SymbolId;
const value_mod = @import("value.zig");
const Value = value_mod.Value;
const Frame = value_mod.Frame;

pub const Global = struct {
    bindings: std.AutoHashMapUnmanaged(SymbolId, Value) = .empty,

    /// Binds `id` to `value`, replacing any earlier binding. Redefinition is
    /// allowed at the top level (R7RS 5.3.1).
    pub fn define(self: *Global, alloc: std.mem.Allocator, id: SymbolId, value: Value) error{OutOfMemory}!void {
        try self.bindings.put(alloc, id, value);
    }

    /// The value bound to `id`, or null when it is unbound.
    pub fn lookup(self: *const Global, id: SymbolId) ?Value {
        return self.bindings.get(id);
    }

    /// Replaces the value of an existing binding. Returns false, and changes
    /// nothing, when `id` is unbound: `set!` does not create a variable.
    pub fn assign(self: *Global, id: SymbolId, value: Value) bool {
        const slot = self.bindings.getPtr(id) orelse return false;
        slot.* = value;
        return true;
    }
};

/// The slot of the local variable `id` in `frame` or the frames behind it,
/// innermost first, or null when no frame binds it. A local variable hides a
/// global one of the same name, and a nearer frame hides a farther one.
pub fn findLocal(frame: ?*Frame, id: SymbolId) ?*Value {
    var f = frame;
    while (f) |fr| : (f = fr.parent) {
        for (fr.names, 0..) |n, i| {
            if (n == id) return &fr.values[i];
        }
    }
    return null;
}

test {
    std.testing.refAllDecls(@This());
}

test "an unbound symbol has no value" {
    var g: Global = .{};
    try std.testing.expect(g.lookup(@fromBackingInt(@intCast(0))) == null);
}

test "define binds, and a second define replaces the first" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var g: Global = .{};
    const x: SymbolId = @fromBackingInt(@intCast(0));
    const y: SymbolId = @fromBackingInt(@intCast(1));
    try g.define(a, x, .fromFixnum(1));
    try g.define(a, y, .fromFixnum(2));
    try std.testing.expectEqual(1, g.lookup(x).?.asFixnum().?);
    try g.define(a, x, .fromFixnum(3));
    try std.testing.expectEqual(3, g.lookup(x).?.asFixnum().?);
    try std.testing.expectEqual(2, g.lookup(y).?.asFixnum().?);
    try std.testing.expect(g.lookup(@fromBackingInt(@intCast(2))) == null);
}

test "assign changes a binding that exists and refuses one that does not" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var g: Global = .{};
    const x: SymbolId = @fromBackingInt(@intCast(0));
    try std.testing.expect(!g.assign(x, .fromFixnum(1)));
    try std.testing.expect(g.lookup(x) == null);
    try g.define(arena.allocator(), x, .fromFixnum(1));
    try std.testing.expect(g.assign(x, .fromFixnum(2)));
    try std.testing.expectEqual(2, g.lookup(x).?.asFixnum().?);
}

test "findLocal finds the nearest binding, and nothing when no frame binds the name" {
    const a: SymbolId = @fromBackingInt(@intCast(0));
    const b: SymbolId = @fromBackingInt(@intCast(1));
    const c: SymbolId = @fromBackingInt(@intCast(2));
    var outer_values = [_]Value{ .fromFixnum(1), .fromFixnum(2) };
    var outer: Frame = .{ .names = &.{ a, b }, .values = &outer_values, .parent = null };
    var inner_values = [_]Value{.fromFixnum(10)};
    var inner: Frame = .{ .names = &.{a}, .values = &inner_values, .parent = &outer };
    // The inner `a` hides the outer one; `b` is found behind it.
    try std.testing.expectEqual(10, findLocal(&inner, a).?.asFixnum().?);
    try std.testing.expectEqual(2, findLocal(&inner, b).?.asFixnum().?);
    try std.testing.expectEqual(1, findLocal(&outer, a).?.asFixnum().?);
    try std.testing.expect(findLocal(&inner, c) == null);
    try std.testing.expect(findLocal(null, a) == null);
    // The slot is the variable itself, so writing through it changes it.
    findLocal(&inner, b).?.* = .fromFixnum(5);
    try std.testing.expectEqual(5, outer_values[1].asFixnum().?);
}
