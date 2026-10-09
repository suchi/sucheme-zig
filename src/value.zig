//! The Scheme value.
//!
//! A tagged union (ADR-0002). The full set of kinds is the table in
//! docs/design/runtime.md; each arrives with the slice that first creates it.
//! Slice 1a had fixed-length integers, 1b the unspecified value, and 1c adds
//! booleans, the empty list, symbols and pairs.
//!
//! Code outside this file does not switch on the union's tag. It asks `kind`
//! and reads through the accessors, which keeps the representation replaceable
//! while still letting a `switch` on `Kind` list every place a new kind has to
//! be handled.

const std = @import("std");
const SymbolId = @import("symbol.zig").SymbolId;

pub const Value = union(enum) {
    fixnum: i64,
    boolean: bool,
    /// The empty list `()`.
    empty_list,
    symbol: SymbolId,
    /// A pair. It lives where its allocator put it; until the GC heap arrives
    /// (slice 1g) that is the interpreter's arena, and nothing frees it.
    pair: *Pair,
    /// What an expression with no useful value returns, such as `define`. It
    /// has no external representation.
    unspecified,

    /// The empty list. Named apart from the variant, which a constant of the
    /// same name would clash with.
    pub const empty_list_value: Value = .empty_list;

    /// The unspecified value. Named apart from the variant for the same reason.
    pub const unspecified_value: Value = .unspecified;

    pub fn fromFixnum(n: i64) Value {
        return .{ .fixnum = n };
    }

    pub fn fromBool(b: bool) Value {
        return .{ .boolean = b };
    }

    pub fn fromSymbol(id: SymbolId) Value {
        return .{ .symbol = id };
    }

    /// A new pair of `car` and `cdr`, allocated with `alloc`.
    pub fn cons(alloc: std.mem.Allocator, car: Value, cdr: Value) error{OutOfMemory}!Value {
        const p = try alloc.create(Pair);
        p.* = .{ .car = car, .cdr = cdr };
        return .{ .pair = p };
    }

    pub fn kind(self: Value) Kind {
        return switch (self) {
            .fixnum => .fixnum,
            .boolean => .boolean,
            .empty_list => .empty_list,
            .symbol => .symbol,
            .pair => .pair,
            .unspecified => .unspecified,
        };
    }

    /// The integer, or null when the value is not a fixnum.
    pub fn asFixnum(self: Value) ?i64 {
        return switch (self) {
            .fixnum => |n| n,
            else => null,
        };
    }

    /// The symbol, or null when the value is not one.
    pub fn asSymbol(self: Value) ?SymbolId {
        return switch (self) {
            .symbol => |id| id,
            else => null,
        };
    }

    /// The pair, or null when the value is not one.
    pub fn asPair(self: Value) ?*Pair {
        return switch (self) {
            .pair => |p| p,
            else => null,
        };
    }

    /// Whether a conditional takes the consequent. Every value but `#f` is
    /// true, the empty list and zero included (R7RS 6.3).
    pub fn isTrue(self: Value) bool {
        return switch (self) {
            .boolean => |b| b,
            else => true,
        };
    }
};

pub const Pair = struct {
    car: Value,
    cdr: Value,
};

/// What a value is, without how it is stored.
pub const Kind = enum { fixnum, boolean, empty_list, symbol, pair, unspecified };

test {
    std.testing.refAllDecls(@This());
}

test "a fixnum reads back as itself" {
    const v: Value = .fromFixnum(-7);
    try std.testing.expectEqual(Kind.fixnum, v.kind());
    try std.testing.expectEqual(-7, v.asFixnum().?);
}

test "a fixnum holds the full i64 range" {
    try std.testing.expectEqual(std.math.maxInt(i64), Value.fromFixnum(std.math.maxInt(i64)).asFixnum().?);
    try std.testing.expectEqual(std.math.minInt(i64), Value.fromFixnum(std.math.minInt(i64)).asFixnum().?);
}

test "the unspecified value is not a fixnum" {
    const v = Value.unspecified_value;
    try std.testing.expectEqual(Kind.unspecified, v.kind());
    try std.testing.expect(v.asFixnum() == null);
}

test "only #f is false" {
    try std.testing.expect(!Value.fromBool(false).isTrue());
    try std.testing.expect(Value.fromBool(true).isTrue());
    try std.testing.expect(Value.fromFixnum(0).isTrue());
    try std.testing.expect(Value.empty_list_value.isTrue());
    try std.testing.expect(Value.unspecified_value.isTrue());
    try std.testing.expect(Value.fromSymbol(@fromBackingInt(@intCast(0))).isTrue());
}

test "each kind answers only to its own accessor" {
    const sym: Value = .fromSymbol(@fromBackingInt(@intCast(3)));
    try std.testing.expectEqual(Kind.symbol, sym.kind());
    try std.testing.expectEqual(@as(SymbolId, @fromBackingInt(@intCast(3))), sym.asSymbol().?);
    try std.testing.expect(sym.asFixnum() == null);
    try std.testing.expect(sym.asPair() == null);
    try std.testing.expect(Value.fromFixnum(1).asSymbol() == null);
    try std.testing.expectEqual(Kind.boolean, Value.fromBool(true).kind());
    try std.testing.expectEqual(Kind.empty_list, Value.empty_list_value.kind());
}

test "cons makes a pair that holds both halves" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const v = try Value.cons(arena.allocator(), .fromFixnum(1), Value.empty_list_value);
    try std.testing.expectEqual(Kind.pair, v.kind());
    const p = v.asPair().?;
    try std.testing.expectEqual(1, p.car.asFixnum().?);
    try std.testing.expectEqual(Kind.empty_list, p.cdr.kind());
    try std.testing.expect(Value.fromFixnum(1).asPair() == null);
}
