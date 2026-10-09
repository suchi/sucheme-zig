//! The Scheme value.
//!
//! A tagged union (ADR-0002). The full set of kinds is the table in
//! docs/design/runtime.md; each arrives with the slice that first creates it.
//! Slice 1a had fixed-length integers, 1b the unspecified value, 1c booleans,
//! the empty list, symbols and pairs, 1d the two kinds of procedure, and 1e adds
//! the marker of a variable that is not defined yet. Slice 1f adds the layouts of
//! the core IR and of the continuation, which are not values but are walked all
//! the same.
//! The layouts of everything the GC will walk are defined here, so the one
//! place that has to know them all is this file (docs/design/architecture.md).
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
    /// A procedure implemented in Zig.
    primitive: *const Primitive,
    /// A procedure made by `lambda`.
    closure: *Closure,
    /// What an expression with no useful value returns, such as `define`. It
    /// has no external representation.
    unspecified,
    /// What a local variable holds between the start of its body and its
    /// definition (R7RS 5.3.2 binds the names of a body as `letrec*` does).
    /// Reading the variable while it holds this is an error, so the marker never
    /// reaches a program as a value.
    uninitialized,

    /// The empty list. Named apart from the variant, which a constant of the
    /// same name would clash with.
    pub const empty_list_value: Value = .empty_list;

    /// The unspecified value. Named apart from the variant for the same reason.
    pub const unspecified_value: Value = .unspecified;

    /// The marker of a variable that is not defined yet. Named apart from the
    /// variant for the same reason.
    pub const uninitialized_value: Value = .uninitialized;

    pub fn fromFixnum(n: i64) Value {
        return .{ .fixnum = n };
    }

    pub fn fromBool(b: bool) Value {
        return .{ .boolean = b };
    }

    pub fn fromSymbol(id: SymbolId) Value {
        return .{ .symbol = id };
    }

    pub fn fromPrimitive(p: *const Primitive) Value {
        return .{ .primitive = p };
    }

    pub fn fromClosure(c: *Closure) Value {
        return .{ .closure = c };
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
            .primitive => .primitive,
            .closure => .closure,
            .unspecified => .unspecified,
            .uninitialized => .uninitialized,
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

    /// The primitive, or null when the value is not one.
    pub fn asPrimitive(self: Value) ?*const Primitive {
        return switch (self) {
            .primitive => |p| p,
            else => null,
        };
    }

    /// The closure, or null when the value is not one.
    pub fn asClosure(self: Value) ?*Closure {
        return switch (self) {
            .closure => |c| c,
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

/// The ways a primitive can fail. It grows with the primitives: a failure the
/// evaluator has to describe is named here.
pub const PrimitiveError = error{
    /// An argument is not of the type the primitive takes.
    WrongType,
    /// The exact result does not fit a fixnum. R7RS 6.2.3 lets an
    /// implementation report this as a violation of an implementation
    /// restriction; bignums arrive in stage 4.
    IntegerOverflow,
    /// A number of arguments the primitive does not take, such as `(-)`.
    WrongArgumentCount,
};

/// A procedure implemented in Zig. The table of them is in prim/.
pub const Primitive = struct {
    name: []const u8,
    call: *const fn (args: []const Value) PrimitiveError!Value,
};

/// A procedure made by `lambda`: its variables, its body, and the frame it was
/// made in. Local variables are found by name through `env` and the frames
/// behind it; the expander of slice 1f replaces that with lexical addresses.
pub const Closure = struct {
    /// The names of the variables of a call: the parameters, then the names the
    /// body defines at its start.
    names: []const SymbolId,
    /// How many of `names` are parameters, so how many arguments a call takes.
    arity: usize,
    /// The forms of the body, evaluated in order; the last one is the value.
    body: []const Value,
    /// How many forms at the start of `body` are definitions. Never all of
    /// them: a body ends in an expression.
    defines: usize,
    env: ?*Frame,
};

/// The variables of one call: their names and what they are bound to, and the
/// frame the closure was made in.
pub const Frame = struct {
    names: []const SymbolId,
    values: []Value,
    parent: ?*Frame,
};

/// Where a local variable lives: how many frames out from the one being run, and
/// which slot in that frame. The expander resolves it (docs/design/runtime.md,
/// the environment); `u32` is the width the expander reports an overflow of as
/// an implementation restriction (R7RS 1.3.2).
pub const Address = struct {
    depth: u32,
    index: u32,
};

/// A node of the core IR: what the expander produces and the machine runs
/// (docs/design/runtime.md). Nodes are immutable, and a node refers to the nodes
/// under it by pointer. They live where the expander allocated them, which until
/// slice 1g is the interpreter's arena.
pub const Node = union(enum) {
    /// A literal, or the datum of a `quote`.
    constant: Value,
    local_ref: LocalRef,
    /// A global variable, found by name until stage 2 gives it a cell.
    global_ref: SymbolId,
    /// `set!` of a local variable. The variable must have a value.
    local_set: LocalAssign,
    /// The definition of a local variable, at the start of a body. It gives the
    /// first value to a slot that holds `uninitialized`.
    local_define: LocalAssign,
    global_set: GlobalAssign,
    global_define: GlobalAssign,
    @"if": If,
    /// `begin` and the body of a `lambda`: one or more nodes, the last one's
    /// value is the value of the sequence.
    sequence: []const *const Node,
    lambda: *const Lambda,
    call: Call,
};

/// A local variable read. The name is for the message when the slot is still
/// uninitialized.
pub const LocalRef = struct {
    address: Address,
    name: SymbolId,
};

pub const LocalAssign = struct {
    address: Address,
    name: SymbolId,
    value: *const Node,
};

pub const GlobalAssign = struct {
    name: SymbolId,
    value: *const Node,
};

pub const If = struct {
    condition: *const Node,
    consequent: *const Node,
    /// Null when the form had none; a false condition then gives the
    /// unspecified value.
    alternative: ?*const Node,
};

/// What a `lambda` expression means, apart from the frame it is evaluated in.
pub const Lambda = struct {
    /// The number of parameters, which a call has to match.
    arity: u32,
    /// The number of slots of a call's frame: the parameters, then the names the
    /// body defines at its start.
    frame_size: u32,
    body: *const Node,
};

/// A procedure call. The operator is evaluated first, then the operands from
/// left to right.
pub const Call = struct {
    operator: *const Node,
    operands: []const *const Node,
};

/// Values already evaluated for a call, most recent first. Immutable, so a
/// continuation captured while a call evaluates its operands can be resumed more
/// than once, each time from the same operands (ADR-0004).
pub const Args = struct {
    value: Value,
    next: ?*const Args,
};

/// One frame of the continuation: what to do with the value that arrives, and
/// the frame to do it in. The frames form a chain, and are never changed once
/// made, which is what lets a continuation be captured in constant time.
pub const Kont = struct {
    next: ?*const Kont,
    /// The local frame to resume in.
    env: ?*Frame,
    /// The number of frames in the chain from this one, itself included.
    depth: usize,
    step: Step,

    pub const Step = union(enum) {
        /// The value is the condition of this `if`.
        branch: *const If,
        /// The value is dropped, and these nodes run next. Never empty: the
        /// last node of a sequence runs with this frame already gone, which is
        /// what makes a call in tail position cost no frame.
        sequence: []const *const Node,
        local_set: *const LocalAssign,
        local_define: *const LocalAssign,
        global_set: *const GlobalAssign,
        global_define: *const GlobalAssign,
        /// The value is the next one of the call: the operator first, then each
        /// operand. `args` holds those that came before it.
        call: CallStep,
    };

    pub const CallStep = struct {
        call: *const Call,
        args: ?*const Args,
        /// How many values `args` holds.
        received: usize,
    };
};

/// What a value is, without how it is stored.
pub const Kind = enum { fixnum, boolean, empty_list, symbol, pair, primitive, closure, unspecified, uninitialized };

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

test "the uninitialized marker is its own kind, and is true like any value but #f" {
    const v = Value.uninitialized_value;
    try std.testing.expectEqual(Kind.uninitialized, v.kind());
    try std.testing.expect(v.asFixnum() == null);
    try std.testing.expect(v.asClosure() == null);
    try std.testing.expect(v.isTrue());
    try std.testing.expect(Value.unspecified_value.kind() != v.kind());
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

test "procedures answer only to their own accessor" {
    const prim: Primitive = .{ .name = "p", .call = struct {
        fn f(_: []const Value) PrimitiveError!Value {
            return .unspecified_value;
        }
    }.f };
    const pv: Value = .fromPrimitive(&prim);
    try std.testing.expectEqual(Kind.primitive, pv.kind());
    try std.testing.expectEqualStrings("p", pv.asPrimitive().?.name);
    try std.testing.expect(pv.asClosure() == null);
    try std.testing.expect(pv.isTrue());
    var closure: Closure = .{ .names = &.{}, .arity = 0, .body = &.{}, .defines = 0, .env = null };
    const cv: Value = .fromClosure(&closure);
    try std.testing.expectEqual(Kind.closure, cv.kind());
    try std.testing.expectEqual(&closure, cv.asClosure().?);
    try std.testing.expect(cv.asPrimitive() == null);
    try std.testing.expect(Value.fromFixnum(1).asClosure() == null);
}

test "a node tree and a continuation chain can be built from the layouts" {
    const x: SymbolId = @fromBackingInt(@intCast(0));
    const one: Node = .{ .constant = .fromFixnum(1) };
    const reference: Node = .{ .local_ref = .{ .address = .{ .depth = 1, .index = 2 }, .name = x } };
    const operands = [_]*const Node{&one};
    const call: Node = .{ .call = .{ .operator = &reference, .operands = &operands } };
    try std.testing.expectEqual(1, call.call.operands[0].constant.asFixnum().?);
    try std.testing.expectEqual(2, call.call.operator.local_ref.address.index);
    const base: Kont = .{ .next = null, .env = null, .depth = 1, .step = .{ .branch = &.{ .condition = &one, .consequent = &one, .alternative = null } } };
    const top: Kont = .{ .next = &base, .env = null, .depth = base.depth + 1, .step = .{ .call = .{ .call = &call.call, .args = null, .received = 0 } } };
    try std.testing.expectEqual(2, top.depth);
    try std.testing.expectEqual(&base, top.next.?);
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
