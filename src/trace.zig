//! What the collector follows: a walk over the fields of a heap object, made
//! from the declaration of its type (docs/design/runtime.md, ADR-0003).
//!
//! Nothing here is written per type. `walk` reads `@typeInfo` and sorts every
//! field into one of three classes, so a field added to `Frame` or `Kont` is
//! followed without anyone remembering to say so, and a field of a kind this
//! file does not know is a compile error and not a silent hole in the marking.
//!
//! - follow: a pointer to a heap object, or a value, slice or optional that
//!   holds one. The visitor is told of the object.
//! - symbol: a symbol id. The visitor is told of it; the symbol table is not
//!   weak yet, so the collector ignores it, and the class is here for the slice
//!   that makes it so.
//! - ignore: numbers, booleans, and pointers to code or static data, which the
//!   heap does not own.
//!
//! A pointer is sorted by what it points to. The types it knows are listed in
//! `Spec`; src/value.zig lists the real ones, beside the layouts.

const std = @import("std");
const value_mod = @import("value.zig");
const SymbolId = @import("symbol.zig").SymbolId;

pub const Class = enum {
    ignore,
    symbol,
    follow,

    /// The class of an aggregate is the strongest class among its parts.
    fn max(a: Class, b: Class) Class {
        return if (@backingInt(a) >= @backingInt(b)) a else b;
    }
};

/// What a walk has to know about the types of a program.
pub const Spec = struct {
    /// Types that live in the heap: a pointer to one is followed.
    heap: []const type,
    /// Types that are pointed to from the heap and are not in it: a pointer to
    /// one is not followed.
    code: []const type,
    /// The type of a symbol id.
    symbol: type,
};

/// The walk for the types of `spec`.
pub fn Tracer(comptime spec: Spec) type {
    return struct {
        /// The class of a field of type `T`, or null when the walk does not know
        /// how to sort it. `walk` turns null into a compile error.
        pub fn classify(comptime T: type) ?Class {
            return classifyAt(T, "", false);
        }

        fn classifyAt(comptime T: type, comptime path: []const u8, comptime fail: bool) ?Class {
            switch (@typeInfo(T)) {
                .int, .float, .bool, .void, .comptime_int, .comptime_float, .null => return .ignore,
                .@"enum" => return if (T == spec.symbol) .symbol else .ignore,
                .pointer => |p| {
                    if (p.size == .slice) return classifyAt(p.child, path ++ "[]", fail);
                    if (p.size == .one) {
                        if (isIn(spec.heap, p.child)) return .follow;
                        if (isIn(spec.code, p.child)) return .ignore;
                    }
                    return unknown(T, path, fail);
                },
                .optional => |o| return classifyAt(o.child, path, fail),
                .array => |a| return classifyAt(a.child, path ++ "[]", fail),
                .@"struct" => |s| {
                    comptime var class: Class = .ignore;
                    inline for (s.field_names, s.field_types) |name, FieldType| {
                        const c = classifyAt(FieldType, path ++ "." ++ name, fail) orelse return null;
                        class = class.max(c);
                    }
                    return class;
                },
                .@"union" => |u| {
                    comptime var class: Class = .ignore;
                    inline for (u.field_names, u.field_types) |name, FieldType| {
                        const c = classifyAt(FieldType, path ++ "." ++ name, fail) orelse return null;
                        class = class.max(c);
                    }
                    return class;
                },
                else => return unknown(T, path, fail),
            }
        }

        fn unknown(comptime T: type, comptime path: []const u8, comptime fail: bool) ?Class {
            if (fail) @compileError("trace: cannot sort the field `" ++ path ++ "` of type " ++ @typeName(T) ++
                ": a pointer must point to a heap type or a code type, and only plain data, enums, " ++
                "optionals, slices, arrays, structs and unions are walked");
            return null;
        }

        fn isIn(comptime types: []const type, comptime T: type) bool {
            inline for (types) |U| {
                if (U == T) return true;
            }
            return false;
        }

        /// Tells `visitor` of every heap object and every symbol id that `value`
        /// holds, one level down: it calls `visitor.object(T, pointer)` for a
        /// heap object and `visitor.symbol(id)` for a symbol id, and does not
        /// follow the objects itself.
        pub fn walk(visitor: anytype, comptime T: type, value: T) void {
            const class = comptime classifyAt(T, @typeName(T), true).?;
            if (class == .ignore) return;
            switch (@typeInfo(T)) {
                .@"enum" => visitor.symbol(value),
                .pointer => |p| switch (p.size) {
                    .one => visitor.object(p.child, @as(*const p.child, value)),
                    .slice => for (value) |element| walk(visitor, p.child, element),
                    else => unreachable,
                },
                .optional => |o| if (value) |v| walk(visitor, o.child, v),
                .array => |a| for (value) |element| walk(visitor, a.child, element),
                .@"struct" => |s| inline for (s.field_names, s.field_types) |name, FieldType| walk(visitor, FieldType, @field(value, name)),
                .@"union" => switch (value) {
                    inline else => |payload| walk(visitor, @TypeOf(payload), payload),
                },
                else => unreachable,
            }
        }

        /// Tells `visitor` of what the heap object `object` refers to.
        pub fn children(visitor: anytype, comptime T: type, object: *const T) void {
            walk(visitor, T, object.*);
        }
    };
}

/// The walk for the types of the interpreter.
pub const interpreter = Tracer(.{
    .heap = &value_mod.heap_types,
    .code = &value_mod.code_types,
    .symbol = SymbolId,
});

test {
    std.testing.refAllDecls(@This());
}

const Pair = value_mod.Pair;
const Closure = value_mod.Closure;
const Frame = value_mod.Frame;
const Kont = value_mod.Kont;
const Args = value_mod.Args;
const Value = value_mod.Value;

/// Remembers what a walk told it, in order.
const Recorder = struct {
    objects: [16]usize = undefined,
    n: usize = 0,
    symbols: [4]SymbolId = undefined,
    symbol_count: usize = 0,

    fn object(self: *Recorder, comptime T: type, pointer: *const T) void {
        self.objects[self.n] = @intFromPtr(pointer);
        self.n += 1;
    }

    fn symbol(self: *Recorder, id: SymbolId) void {
        self.symbols[self.symbol_count] = id;
        self.symbol_count += 1;
    }

    fn expect(self: *const Recorder, expected: []const usize) !void {
        try std.testing.expectEqualSlices(usize, expected, self.objects[0..self.n]);
    }
};

fn addr(pointer: anytype) usize {
    return @intFromPtr(pointer);
}

// The sets below are written out by hand, apart from the rule that produces them:
// a walk that dropped a field, or followed one it should not, differs from them.

test "a pair is followed through both of its halves, whatever they hold" {
    var a: Pair = .{ .car = .fromFixnum(0), .cdr = .empty_list_value };
    var b: Closure = .{ .lambda = undefined, .env = null };
    const pair: Pair = .{ .car = .{ .pair = &a }, .cdr = .{ .closure = &b } };
    var r: Recorder = .{};
    interpreter.children(&r, Pair, &pair);
    try r.expect(&.{ addr(&a), addr(&b) });
    // A half that is not a heap object is not reported.
    const flat: Pair = .{ .car = .fromFixnum(1), .cdr = .fromSymbol(@fromBackingInt(@intCast(7))) };
    var q: Recorder = .{};
    interpreter.children(&q, Pair, &flat);
    try q.expect(&.{});
    try std.testing.expectEqual(1, q.symbol_count);
    try std.testing.expectEqual(@as(SymbolId, @fromBackingInt(@intCast(7))), q.symbols[0]);
}

test "a closure is followed through its frame and not through its code" {
    var frame: Frame = .{ .values = &.{}, .parent = null };
    const lambda: value_mod.Lambda = .{ .arity = 0, .frame_size = 0, .body = &.{ .constant = .unspecified_value } };
    const closure: Closure = .{ .lambda = &lambda, .env = &frame };
    var r: Recorder = .{};
    interpreter.children(&r, Closure, &closure);
    try r.expect(&.{addr(&frame)});
    const bare: Closure = .{ .lambda = &lambda, .env = null };
    var q: Recorder = .{};
    interpreter.children(&q, Closure, &bare);
    try q.expect(&.{});
}

test "a frame is followed through its slots and its parent" {
    var outer: Frame = .{ .values = &.{}, .parent = null };
    var p: Pair = .{ .car = .empty_list_value, .cdr = .empty_list_value };
    var c: Closure = .{ .lambda = undefined, .env = null };
    var slots = [_]Value{ .{ .pair = &p }, .fromFixnum(3), .uninitialized_value, .{ .closure = &c } };
    const frame: Frame = .{ .values = &slots, .parent = &outer };
    var r: Recorder = .{};
    interpreter.children(&r, Frame, &frame);
    // The slots in order, then the parent.
    try r.expect(&.{ addr(&p), addr(&c), addr(&outer) });
}

test "a continuation frame is followed through its link, its environment and its pending arguments" {
    var env: Frame = .{ .values = &.{}, .parent = null };
    var rest: Kont = .{ .next = null, .env = null, .depth = 1, .step = .{ .sequence = &.{} } };
    var arg: Args = .{ .value = .empty_list_value, .next = null };
    const node: value_mod.Node = .{ .constant = .unspecified_value };
    const nodes = [_]*const value_mod.Node{&node};
    const call: value_mod.Call = .{ .operator = &node, .operands = &nodes };
    const condition: value_mod.If = .{ .condition = &node, .consequent = &node, .alternative = null };

    const waiting: Kont = .{ .next = &rest, .env = &env, .depth = 2, .step = .{ .call = .{ .call = &call, .args = &arg, .received = 1 } } };
    var r: Recorder = .{};
    interpreter.children(&r, Kont, &waiting);
    try r.expect(&.{ addr(&rest), addr(&env), addr(&arg) });

    // The other steps hold code only, so only the link and the environment count.
    const branching: Kont = .{ .next = &rest, .env = &env, .depth = 2, .step = .{ .branch = &condition } };
    var q: Recorder = .{};
    interpreter.children(&q, Kont, &branching);
    try q.expect(&.{ addr(&rest), addr(&env) });
    const sequencing: Kont = .{ .next = null, .env = null, .depth = 1, .step = .{ .sequence = &nodes } };
    var s: Recorder = .{};
    interpreter.children(&s, Kont, &sequencing);
    try s.expect(&.{});
}

test "the arguments gathered so far are followed through their value and their link" {
    var p: Pair = .{ .car = .empty_list_value, .cdr = .empty_list_value };
    var older: Args = .{ .value = .fromFixnum(1), .next = null };
    const args: Args = .{ .value = .{ .pair = &p }, .next = &older };
    var r: Recorder = .{};
    interpreter.children(&r, Args, &args);
    try r.expect(&.{ addr(&p), addr(&older) });
}

test "the classes of the real types" {
    try std.testing.expectEqual(Class.follow, comptime interpreter.classify(Pair).?);
    try std.testing.expectEqual(Class.follow, comptime interpreter.classify(Closure).?);
    try std.testing.expectEqual(Class.follow, comptime interpreter.classify(Frame).?);
    try std.testing.expectEqual(Class.follow, comptime interpreter.classify(Kont).?);
    try std.testing.expectEqual(Class.follow, comptime interpreter.classify(Args).?);
    try std.testing.expectEqual(Class.follow, comptime interpreter.classify(Value).?);
    // Code and the plain data around it are never followed.
    try std.testing.expectEqual(Class.ignore, comptime interpreter.classify(*const value_mod.Node).?);
    try std.testing.expectEqual(Class.ignore, comptime interpreter.classify(*const value_mod.Primitive).?);
    try std.testing.expectEqual(Class.ignore, comptime interpreter.classify(*value_mod.Condition).?);
    try std.testing.expectEqual(Class.ignore, comptime interpreter.classify([]const *const value_mod.Node).?);
    try std.testing.expectEqual(Class.ignore, comptime interpreter.classify(value_mod.Call).?);
    try std.testing.expectEqual(Class.ignore, comptime interpreter.classify(usize).?);
    try std.testing.expectEqual(Class.symbol, comptime interpreter.classify(SymbolId).?);
    try std.testing.expectEqual(Class.follow, comptime interpreter.classify(?*const Kont).?);
}

test "a type the walk cannot sort has no class" {
    // `walk` turns this into a compile error naming the field; here the same
    // question is asked in a way a test can answer.
    const unsorted = [_]type{
        *u8, // a pointer to something that is neither heap nor code
        [*]Pair, // a pointer with no length
        struct { fine: u32, odd: *u8 },
        union(enum) { fine: bool, odd: error{Boom}!u8 },
        fn () void,
        ?*opaque {},
    };
    inline for (unsorted) |T| try std.testing.expect(comptime interpreter.classify(T) == null);
}

test "a spec of its own sorts pointers by the types it lists" {
    const Leaf = struct { n: u8 };
    const Branch = struct { left: ?*Leaf, label: *const u8 };
    const Mine = Tracer(.{ .heap = &.{Leaf}, .code = &.{u8}, .symbol = SymbolId });
    try std.testing.expectEqual(Class.follow, comptime Mine.classify(Branch).?);
    // The same type under a spec that lists no heap types has a pointer it cannot sort.
    const Other = Tracer(.{ .heap = &.{}, .code = &.{u8}, .symbol = SymbolId });
    try std.testing.expect(comptime Other.classify(Branch) == null);
}
