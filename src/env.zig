//! The global environment: which symbols are bound, and to what.
//!
//! 存在しない名前は未束縛であり、そのための印の値は要らない。ローカル変数は
//! 呼び出しのフレームにあり、レキシカルアドレスで見つける。内部定義の「未初期化」
//! の状態は専用の `Value`(`Value.uninitialized`)であり、呼び出しの開始時に
//! 設定する。`import` で共有する docs/design/runtime.md のセルは、段階2の
//! ライブラリシステムとともに入る。

const std = @import("std");
const SymbolId = @import("symbol.zig").SymbolId;
const Value = @import("value.zig").Value;
const Marker = @import("heap.zig").Marker;

pub const Global = struct {
    bindings: std.AutoHashMapUnmanaged(SymbolId, Value) = .empty,

    /// Binds `id` to `value`, replacing any earlier binding.
    ///
    /// トップレベルでは再定義が許される(R7RS 5.3.1)。
    pub fn define(self: *Global, alloc: std.mem.Allocator, id: SymbolId, value: Value) error{OutOfMemory}!void {
        try self.bindings.put(alloc, id, value);
    }

    /// The value bound to `id`, or null when it is unbound.
    pub fn lookup(self: *const Global, id: SymbolId) ?Value {
        return self.bindings.get(id);
    }

    /// Tells the collector of every value a binding holds: they are roots.
    pub fn mark(self: *const Global, marker: *Marker) void {
        var it = self.bindings.valueIterator();
        while (it.next()) |value| marker.value(value.*);
    }

    /// Replaces the value of an existing binding.
    ///
    /// `id` が未束縛なら何も変えずに false を返す。`set!` は変数を作らない。
    pub fn assign(self: *Global, id: SymbolId, value: Value) bool {
        const slot = self.bindings.getPtr(id) orelse return false;
        slot.* = value;
        return true;
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
