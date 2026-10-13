//! What the collector follows: a walk over the fields of a heap object, made
//! from the declaration of its type (docs/design/runtime.md, ADR-0003).
//!
//! 型ごとに書くものは、ここには何もない。`walk` は `@typeInfo` を読んで、すべての
//! フィールドを3つの分類のどれかに振り分ける。そのため、`Frame` や `Kont` に足した
//! フィールドは、誰も覚えていなくてもたどられ、このファイルが知らない種類の
//! フィールドは、マークに黙って穴が開くのでなく、コンパイルエラーになる。
//!
//! - follow: ヒープオブジェクトへのポインタ、またはそれを持つ値・スライス・
//!   オプショナル。訪問者(visitor)にそのオブジェクトを知らせる。
//! - symbol: シンボル ID。訪問者に知らせるが、シンボル表はまだ弱参照ではないので、
//!   GC は無視する。この分類は、弱参照にするスライスのために置いてある。
//! - ignore: 数値、真偽値、コードや静的データへのポインタ。ヒープはこれらを所有
//!   しない。
//!
//! ポインタは、指す先の型で振り分ける。知っている型は `Spec` に挙げる。実際の型は、
//! レイアウトの隣の src/value.zig に挙げてある。

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
        /// how to sort it.
        /// `walk` は null をコンパイルエラーにする。
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

// 以下の集合は、それを導く規則とは別に、手で書き下してある。フィールドを落とした
// walk や、たどるべきでないものをたどった walk は、これらと食い違う。

test "a pair is followed through both of its halves, whatever they hold" {
    var a: Pair = .{ .car = .fromFixnum(0), .cdr = .empty_list_value };
    var b: Closure = .{ .lambda = undefined, .env = null };
    const pair: Pair = .{ .car = .{ .pair = &a }, .cdr = .{ .closure = &b } };
    var r: Recorder = .{};
    interpreter.children(&r, Pair, &pair);
    try r.expect(&.{ addr(&a), addr(&b) });
    // ヒープオブジェクトでない半分は報告されない。
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
    // スロットを順に、その後に親。
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

    // 他のステップはコードしか持たないので、リンクと環境だけが数えられる。
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

test "a condition is followed through its message and its irritants" {
    var bytes = "m".*;
    var message: value_mod.String = .{ .bytes = &bytes, .is_ascii = true };
    var irritant: Pair = .{ .car = .fromFixnum(1), .cdr = .empty_list_value };
    const condition: value_mod.Condition = .{ .kind = .@"error", .message = .fromString(&message), .irritants = .{ .pair = &irritant } };
    var r: Recorder = .{};
    interpreter.children(&r, value_mod.Condition, &condition);
    try r.expect(&.{ addr(&message), addr(&irritant) });
    // irritant が空なら、メッセージだけが報告される。種別は報告されない。
    const bare: value_mod.Condition = .{ .kind = .file, .message = .fromString(&message), .irritants = .empty_list_value };
    var q: Recorder = .{};
    interpreter.children(&q, value_mod.Condition, &bare);
    try q.expect(&.{addr(&message)});
    try std.testing.expectEqual(0, q.symbol_count);
}

test "a syntactic environment is followed through its parent and its first binding" {
    var outer: value_mod.SyntacticEnv = .{ .parent = null, .rib_depth = 1, .bindings = null };
    var local: value_mod.LocalBinding = .{ .rib_depth = 2, .index = 0 };
    var binding: value_mod.SyntacticBinding = .{ .id = .fromSymbol(@fromBackingInt(@intCast(3))), .denotation = .{ .local = &local }, .next = null };
    const env: value_mod.SyntacticEnv = .{ .parent = &outer, .rib_depth = 2, .bindings = &binding };
    var r: Recorder = .{};
    interpreter.children(&r, value_mod.SyntacticEnv, &env);
    try r.expect(&.{ addr(&outer), addr(&binding) });
    var q: Recorder = .{};
    interpreter.children(&q, value_mod.SyntacticEnv, &outer);
    try q.expect(&.{});
}

test "a syntactic binding is followed through its identifier, its local variable and the next binding" {
    var local: value_mod.LocalBinding = .{ .rib_depth = 1, .index = 4 };
    var older: value_mod.SyntacticBinding = .{ .id = .fromSymbol(@fromBackingInt(@intCast(1))), .denotation = .{ .special = .@"if" }, .next = null };
    const binding: value_mod.SyntacticBinding = .{ .id = .fromSymbol(@fromBackingInt(@intCast(2))), .denotation = .{ .local = &local }, .next = &older };
    var r: Recorder = .{};
    interpreter.children(&r, value_mod.SyntacticBinding, &binding);
    try r.expect(&.{ addr(&local), addr(&older) });
    try std.testing.expectEqual(1, r.symbol_count);
    try std.testing.expectEqual(@as(SymbolId, @fromBackingInt(@intCast(2))), r.symbols[0]);
    // 特殊形式と大域変数の意味は、ヒープのものを指さない。大域変数の名前はシンボルである。
    var q: Recorder = .{};
    interpreter.children(&q, value_mod.SyntacticBinding, &older);
    try q.expect(&.{});
    const global: value_mod.SyntacticBinding = .{ .id = .fromSymbol(@fromBackingInt(@intCast(1))), .denotation = .{ .global = @fromBackingInt(@intCast(5)) }, .next = null };
    var g: Recorder = .{};
    interpreter.children(&g, value_mod.SyntacticBinding, &global);
    try g.expect(&.{});
    try std.testing.expectEqual(2, g.symbol_count);
    try std.testing.expectEqual(@as(SymbolId, @fromBackingInt(@intCast(5))), g.symbols[1]);
}

test "the classes of the real types" {
    try std.testing.expectEqual(Class.follow, comptime interpreter.classify(Pair).?);
    try std.testing.expectEqual(Class.follow, comptime interpreter.classify(Closure).?);
    try std.testing.expectEqual(Class.follow, comptime interpreter.classify(Frame).?);
    try std.testing.expectEqual(Class.follow, comptime interpreter.classify(Kont).?);
    try std.testing.expectEqual(Class.follow, comptime interpreter.classify(Args).?);
    try std.testing.expectEqual(Class.follow, comptime interpreter.classify(Value).?);
    try std.testing.expectEqual(Class.follow, comptime interpreter.classify(value_mod.Condition).?);
    try std.testing.expectEqual(Class.follow, comptime interpreter.classify(*value_mod.Condition).?);
    // コードと、その周りの単純なデータは、決してたどられない。
    try std.testing.expectEqual(Class.ignore, comptime interpreter.classify(*const value_mod.Node).?);
    try std.testing.expectEqual(Class.ignore, comptime interpreter.classify(*const value_mod.Primitive).?);
    try std.testing.expectEqual(Class.ignore, comptime interpreter.classify([]const *const value_mod.Node).?);
    try std.testing.expectEqual(Class.ignore, comptime interpreter.classify(value_mod.Call).?);
    try std.testing.expectEqual(Class.ignore, comptime interpreter.classify(usize).?);
    try std.testing.expectEqual(Class.symbol, comptime interpreter.classify(SymbolId).?);
    try std.testing.expectEqual(Class.follow, comptime interpreter.classify(?*const Kont).?);
}

test "the classes of the types of the syntactic environment" {
    // Why: 1つのテスト関数の中のコンパイル時の評価は、分岐の上限を共有する。上の
    // テストに足すと上限を超えるので、分けてある。
    try std.testing.expectEqual(Class.follow, comptime interpreter.classify(value_mod.SyntacticEnv).?);
    try std.testing.expectEqual(Class.follow, comptime interpreter.classify(value_mod.SyntacticBinding).?);
    try std.testing.expectEqual(Class.follow, comptime interpreter.classify(value_mod.Denotation).?);
    // 局所変数は、数を2つ持つだけである。
    try std.testing.expectEqual(Class.ignore, comptime interpreter.classify(value_mod.LocalBinding).?);
}

test "a type the walk cannot sort has no class" {
    // `walk` はこれを、フィールド名を示すコンパイルエラーにする。ここでは同じ問いを、
    // テストが答えられる形で行う。
    const unsorted = [_]type{
        *u8, // ヒープのものでもコードのものでもない何かへのポインタ
        [*]Pair, // 長さを持たないポインタ
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
    // ヒープ型を挙げない spec のもとでは、同じ型が、分類できないポインタを持つ。
    const Other = Tracer(.{ .heap = &.{}, .code = &.{u8}, .symbol = SymbolId });
    try std.testing.expect(comptime Other.classify(Branch) == null);
}

test "of the code types only the node holds values, which the context's constants stand in for" {
    // GC はコードへのポインタをたどらない。これが安全なのは、コードの型がヒープ
    // オブジェクトを持たない間だけである。持つのは `Node`(定数)で、そのためコンテキスト
    // がそれらの定数を自分で保持する。他のコード型に値を足すと、何も言わずに見落とされる。
    // そのことがここで表に出る。
    inline for (value_mod.code_types) |T| {
        const class = comptime interpreter.classify(T);
        if (T == value_mod.Node) {
            try std.testing.expectEqual(Class.follow, class.?);
        } else if (T == value_mod.Primitive) {
            // Zig の関数ポインタ。walk にはその分類がなく、たどることもない。
            try std.testing.expect(class == null);
        } else {
            // シンボル ID は許す。名前はまだ回収されない。ヒープオブジェクトは許さない。
            try std.testing.expect(class.? != .follow);
        }
    }
}
