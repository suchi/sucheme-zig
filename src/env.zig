//! The global environment: which symbols are bound, and to what.
//!
//! A name that is absent is unbound, so slice 1b needs no marker value for it.
//! Local variables and the "uninitialized" state of an internal definition
//! arrive with `lambda` (slice 1d) and internal `define` (slice 1e), which are
//! what need them. The cells of docs/design/runtime.md, shared by `import`,
//! arrive with the library system in stage 2.

const std = @import("std");
const SymbolId = @import("symbol.zig").SymbolId;
const Value = @import("value.zig").Value;

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
};

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
