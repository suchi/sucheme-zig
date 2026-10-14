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
            // Why: 1つの関数の中のコンパイル時の評価は、分岐の上限を共有する。分類はヒープの
            // 型の数に比例して分岐するので、型を足すたびに、問い合わせを並べたテストが上限を
            // 超える。
            @setEvalBranchQuota(100_000);
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
            // Why: `classify` と同じ理由で、分岐の上限を上げる。継続フレームの種類を足すと、
            // 1つの型の分類が、既定の上限を超える。
            const class = comptime blk: {
                @setEvalBranchQuota(100_000);
                break :blk classifyAt(T, @typeName(T), true).?;
            };
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
    // 特殊形式の意味は、ヒープのものを指さない。大域変数の意味は、そのセルを指す。
    var q: Recorder = .{};
    interpreter.children(&q, value_mod.SyntacticBinding, &older);
    try q.expect(&.{});
    var cell: value_mod.Cell = .{ .name = @fromBackingInt(@intCast(5)), .value = .fromFixnum(1) };
    const global: value_mod.SyntacticBinding = .{ .id = .fromSymbol(@fromBackingInt(@intCast(1))), .denotation = .{ .global = &cell }, .next = null };
    var g: Recorder = .{};
    interpreter.children(&g, value_mod.SyntacticBinding, &global);
    try g.expect(&.{addr(&cell)});
}

test "a cell is followed through its value, and its name is a symbol" {
    var p: Pair = .{ .car = .empty_list_value, .cdr = .empty_list_value };
    const cell: value_mod.Cell = .{ .name = @fromBackingInt(@intCast(6)), .value = .{ .pair = &p } };
    var r: Recorder = .{};
    interpreter.children(&r, value_mod.Cell, &cell);
    try r.expect(&.{addr(&p)});
    try std.testing.expectEqual(1, r.symbol_count);
    try std.testing.expectEqual(@as(SymbolId, @fromBackingInt(@intCast(6))), r.symbols[0]);
    // 未束縛のセルは、ヒープのものを指さない。
    const unbound: value_mod.Cell = .{ .name = @fromBackingInt(@intCast(6)), .value = .uninitialized_value };
    var q: Recorder = .{};
    interpreter.children(&q, value_mod.Cell, &unbound);
    try q.expect(&.{});
}

test "a dynamic point is followed through its parent, its current handler and what its kind holds" {
    try std.testing.expectEqual(Class.follow, comptime interpreter.classify(value_mod.DynPoint).?);
    var c: Closure = .{ .lambda = undefined, .env = null };
    var outer: value_mod.DynPoint = .{ .parent = null, .depth = 1, .current_handler = null, .kind = .{ .handler = .{ .closure = &c } } };
    outer.current_handler = &outer;
    var r: Recorder = .{};
    interpreter.children(&r, value_mod.DynPoint, &outer);
    // 親は無く、現在のハンドラは自分自身で、ハンドラの手続き。
    try r.expect(&.{ addr(&outer), addr(&c) });
    var inner: value_mod.DynPoint = .{ .parent = &outer, .depth = 2, .current_handler = null, .kind = .{ .handler = .fromFixnum(1) } };
    inner.current_handler = &inner;
    const shift: value_mod.DynPoint = .{ .parent = &inner, .depth = 3, .current_handler = &outer, .kind = .{ .handler_shift = &outer } };
    var q: Recorder = .{};
    interpreter.children(&q, value_mod.DynPoint, &shift);
    try q.expect(&.{ addr(&inner), addr(&outer), addr(&outer) });
    // 切り替え先が無い切り替えの点は、親だけを持つ。
    const bare: value_mod.DynPoint = .{ .parent = &inner, .depth = 3, .current_handler = null, .kind = .{ .handler_shift = null } };
    var s: Recorder = .{};
    interpreter.children(&s, value_mod.DynPoint, &bare);
    try s.expect(&.{addr(&inner)});
}

test "the frames of the exceptions are followed through the dynamic points and the value they keep" {
    var point: value_mod.DynPoint = .{ .parent = null, .depth = 1, .current_handler = null, .kind = .{ .handler_shift = null } };
    var p: Pair = .{ .car = .empty_list_value, .cdr = .empty_list_value };
    var rest: Kont = .{ .next = null, .env = null, .depth = 1, .step = .{ .dynamic_exit = null } };
    const exit: Kont = .{ .next = &rest, .env = null, .depth = 2, .step = .{ .dynamic_exit = &point } };
    var r: Recorder = .{};
    interpreter.children(&r, Kont, &exit);
    try r.expect(&.{ addr(&rest), addr(&point) });
    const returning: Kont = .{ .next = null, .env = null, .depth = 1, .step = .{ .handler_return = .{ .dyn = &point, .raised = .{ .pair = &p }, .continuable = true } } };
    var q: Recorder = .{};
    interpreter.children(&q, Kont, &returning);
    try q.expect(&.{ addr(&point), addr(&p) });
    var s: Recorder = .{};
    interpreter.children(&s, Kont, &rest);
    try s.expect(&.{});
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
}

test "the code and the plain data around it are never followed" {
    // Why: 1つのテスト関数の中のコンパイル時の評価は、分岐の上限を共有する。`Value` の
    // 変種が増えて上のテストに収まらなくなったので、分けてある。
    try std.testing.expectEqual(Class.ignore, comptime interpreter.classify(*const value_mod.Node).?);
    try std.testing.expectEqual(Class.ignore, comptime interpreter.classify(*const value_mod.Primitive).?);
    try std.testing.expectEqual(Class.ignore, comptime interpreter.classify([]const *const value_mod.Node).?);
    try std.testing.expectEqual(Class.ignore, comptime interpreter.classify(value_mod.Call).?);
    try std.testing.expectEqual(Class.ignore, comptime interpreter.classify(usize).?);
    try std.testing.expectEqual(Class.symbol, comptime interpreter.classify(SymbolId).?);
    try std.testing.expectEqual(Class.follow, comptime interpreter.classify(?*const Kont).?);
}

test "the classes of the types of the syntactic environment" {
    // 分けたのは、上のテストがコンパイル時の分岐の上限を超えたためである。上限は
    // いま `classify` が上げている。
    try std.testing.expectEqual(Class.follow, comptime interpreter.classify(value_mod.SyntacticEnv).?);
    try std.testing.expectEqual(Class.follow, comptime interpreter.classify(value_mod.SyntacticBinding).?);
    try std.testing.expectEqual(Class.follow, comptime interpreter.classify(value_mod.Denotation).?);
    // 局所変数は、数を2つ持つだけである。
    try std.testing.expectEqual(Class.ignore, comptime interpreter.classify(value_mod.LocalBinding).?);
    try std.testing.expectEqual(Class.follow, comptime interpreter.classify(value_mod.Cell).?);
}

test "the classes of the types of macros" {
    // 上と同じ理由で分けてある。
    try std.testing.expectEqual(Class.follow, comptime interpreter.classify(value_mod.Alias).?);
    try std.testing.expectEqual(Class.follow, comptime interpreter.classify(value_mod.Macro).?);
}

test "an alias is followed through its inner identifier and its environment" {
    var env: value_mod.SyntacticEnv = .{ .parent = null, .rib_depth = 1, .bindings = null };
    var inner: value_mod.Alias = .{ .inner = .fromSymbol(@fromBackingInt(@intCast(2))), .env = null, .mark = 0 };
    const outer: value_mod.Alias = .{ .inner = .fromAlias(&inner), .env = &env, .mark = 1 };
    var r: Recorder = .{};
    interpreter.children(&r, value_mod.Alias, &outer);
    try r.expect(&.{ addr(&inner), addr(&env) });
    // 最上位で定義したマクロの別名は、シンボルだけを持つ。
    var q: Recorder = .{};
    interpreter.children(&q, value_mod.Alias, &inner);
    try q.expect(&.{});
    try std.testing.expectEqual(1, q.symbol_count);
}

test "a macro is followed through its literals, its rules and its environment" {
    var env: value_mod.SyntacticEnv = .{ .parent = null, .rib_depth = 1, .bindings = null };
    var literals: Pair = .{ .car = .fromSymbol(@fromBackingInt(@intCast(1))), .cdr = .empty_list_value };
    var rules: Pair = .{ .car = .empty_list_value, .cdr = .empty_list_value };
    const m: value_mod.Macro = .{ .literals = .{ .pair = &literals }, .rules = .{ .pair = &rules }, .env = &env };
    var r: Recorder = .{};
    interpreter.children(&r, value_mod.Macro, &m);
    try r.expect(&.{ addr(&literals), addr(&rules), addr(&env) });
    // 構文環境の束縛がマクロを指すときは、そのマクロをたどる。
    const binding: value_mod.SyntacticBinding = .{ .id = .fromSymbol(@fromBackingInt(@intCast(3))), .denotation = .{ .macro = @constCast(&m) }, .next = null };
    var b: Recorder = .{};
    interpreter.children(&b, value_mod.SyntacticBinding, &binding);
    try b.expect(&.{addr(&m)});
}

test "a record is followed through its type and its fields" {
    var t: value_mod.RecordType = .{ .name = @fromBackingInt(@intCast(6)), .field_count = 3 };
    var p: Pair = .{ .car = .empty_list_value, .cdr = .empty_list_value };
    var other: value_mod.RecordType = .{ .name = @fromBackingInt(@intCast(7)), .field_count = 0 };
    var fields = [_]Value{ .{ .pair = &p }, .fromFixnum(2), .fromRecordType(&other) };
    const record: value_mod.Record = .{ .record_type = &t, .fields = &fields };
    var r: Recorder = .{};
    interpreter.children(&r, value_mod.Record, &record);
    // 型を先に、その後にフィールドを順に。ヒープのものでないフィールドは報告されない。
    try r.expect(&.{ addr(&t), addr(&p), addr(&other) });
    const bare: value_mod.Record = .{ .record_type = &other, .fields = &.{} };
    var q: Recorder = .{};
    interpreter.children(&q, value_mod.Record, &bare);
    try q.expect(&.{addr(&other)});
}

test "a record type is followed through nothing, and tells its name as a symbol" {
    const t: value_mod.RecordType = .{ .name = @fromBackingInt(@intCast(6)), .field_count = 3 };
    var r: Recorder = .{};
    interpreter.children(&r, value_mod.RecordType, &t);
    try r.expect(&.{});
    try std.testing.expectEqual(1, r.symbol_count);
    try std.testing.expectEqual(@as(SymbolId, @fromBackingInt(@intCast(6))), r.symbols[0]);
}

test "the classes of the types of records" {
    try std.testing.expectEqual(Class.follow, comptime interpreter.classify(value_mod.Record).?);
    try std.testing.expectEqual(Class.follow, comptime interpreter.classify(*value_mod.Record).?);
    try std.testing.expectEqual(Class.follow, comptime interpreter.classify(*value_mod.RecordType).?);
    // 型は、名前のシンボルと数を持つだけである。
    try std.testing.expectEqual(Class.symbol, comptime interpreter.classify(value_mod.RecordType).?);
}

test "a wind point is followed through its parent, its current handler, its before and its after" {
    var c: Closure = .{ .lambda = undefined, .env = null };
    var d: Closure = .{ .lambda = undefined, .env = null };
    var outer: value_mod.DynPoint = .{ .parent = null, .depth = 1, .current_handler = null, .kind = .{ .handler = .fromFixnum(0) } };
    outer.current_handler = &outer;
    const wind: value_mod.DynPoint = .{ .parent = &outer, .depth = 2, .current_handler = &outer, .kind = .{ .wind = .{ .before = .{ .closure = &c }, .after = .{ .closure = &d } } } };
    var r: Recorder = .{};
    interpreter.children(&r, value_mod.DynPoint, &wind);
    try r.expect(&.{ addr(&outer), addr(&outer), addr(&c), addr(&d) });
    // 手続きがヒープのものでなければ(プリミティブ)、親と現在のハンドラだけである。
    const bare: value_mod.DynPoint = .{ .parent = null, .depth = 1, .current_handler = null, .kind = .{ .wind = .{ .before = .fromFixnum(1), .after = .fromFixnum(2) } } };
    var q: Recorder = .{};
    interpreter.children(&q, value_mod.DynPoint, &bare);
    try q.expect(&.{});
}

test "a continuation is followed through its frames and its dynamic point" {
    var rest: Kont = .{ .next = null, .env = null, .depth = 1, .step = .{ .dynamic_exit = null } };
    var point: value_mod.DynPoint = .{ .parent = null, .depth = 1, .current_handler = null, .kind = .{ .handler_shift = null } };
    const k: value_mod.Continuation = .{ .kont = &rest, .dyn = &point };
    var r: Recorder = .{};
    interpreter.children(&r, value_mod.Continuation, &k);
    try r.expect(&.{ addr(&rest), addr(&point) });
    // 実行の最も外側で捕捉した継続は、何も指さない。
    const empty: value_mod.Continuation = .{ .kont = null, .dyn = null };
    var q: Recorder = .{};
    interpreter.children(&q, value_mod.Continuation, &empty);
    try q.expect(&.{});
}

test "the shared state of a rewind is followed through its target, its value and the common ancestor" {
    const k: value_mod.Continuation = .{ .kont = null, .dyn = null };
    var p: Pair = .{ .car = .empty_list_value, .cdr = .empty_list_value };
    var point: value_mod.DynPoint = .{ .parent = null, .depth = 1, .current_handler = null, .kind = .{ .handler_shift = null } };
    const state: value_mod.Rewind = .{ .target = &k, .value = .{ .pair = &p }, .ancestor = &point };
    var r: Recorder = .{};
    interpreter.children(&r, value_mod.Rewind, &state);
    try r.expect(&.{ addr(&k), addr(&p), addr(&point) });
    // 最外の継続への脱出(目標が null)で、共通の点が無いとき。
    const unhandled: value_mod.Rewind = .{ .target = null, .value = .fromFixnum(1), .ancestor = null };
    var q: Recorder = .{};
    interpreter.children(&q, value_mod.Rewind, &unhandled);
    try q.expect(&.{});
}

test "a link of the path a rewind enters is followed through its point and the next link" {
    var point: value_mod.DynPoint = .{ .parent = null, .depth = 1, .current_handler = null, .kind = .{ .handler_shift = null } };
    var last: value_mod.WindPath = .{ .point = &point, .next = null };
    const first: value_mod.WindPath = .{ .point = &point, .next = &last };
    var r: Recorder = .{};
    interpreter.children(&r, value_mod.WindPath, &first);
    try r.expect(&.{ addr(&point), addr(&last) });
    var q: Recorder = .{};
    interpreter.children(&q, value_mod.WindPath, &last);
    try q.expect(&.{addr(&point)});
}

test "the frames of dynamic-wind are followed through the point, the thunk and the value they keep" {
    var point: value_mod.DynPoint = .{ .parent = null, .depth = 1, .current_handler = null, .kind = .{ .handler_shift = null } };
    var c: Closure = .{ .lambda = undefined, .env = null };
    var p: Pair = .{ .car = .empty_list_value, .cdr = .empty_list_value };
    const before: Kont = .{ .next = null, .env = null, .depth = 1, .step = .{ .wind_before = .{ .point = &point, .thunk = .{ .closure = &c } } } };
    var r: Recorder = .{};
    interpreter.children(&r, Kont, &before);
    try r.expect(&.{ addr(&point), addr(&c) });
    const body: Kont = .{ .next = null, .env = null, .depth = 1, .step = .{ .wind_body = &point } };
    var q: Recorder = .{};
    interpreter.children(&q, Kont, &body);
    try q.expect(&.{addr(&point)});
    const after: Kont = .{ .next = null, .env = null, .depth = 1, .step = .{ .wind_after = .{ .pair = &p } } };
    var s: Recorder = .{};
    interpreter.children(&s, Kont, &after);
    try s.expect(&.{addr(&p)});
}

test "a rewind frame is followed through its shared state, the link it entered and the point it was put on at" {
    const state: value_mod.Rewind = .{ .target = null, .value = .fromFixnum(1), .ancestor = null };
    var point: value_mod.DynPoint = .{ .parent = null, .depth = 1, .current_handler = null, .kind = .{ .handler_shift = null } };
    var link: value_mod.WindPath = .{ .point = &point, .next = null };
    const entering: Kont = .{ .next = null, .env = null, .depth = 1, .step = .{ .rewind = .{ .state = &state, .entered = &link, .at = &point } } };
    var r: Recorder = .{};
    interpreter.children(&r, Kont, &entering);
    try r.expect(&.{ addr(&state), addr(&link), addr(&point) });
    const leaving: Kont = .{ .next = null, .env = null, .depth = 1, .step = .{ .rewind = .{ .state = &state, .entered = null, .at = null } } };
    var q: Recorder = .{};
    interpreter.children(&q, Kont, &leaving);
    try q.expect(&.{addr(&state)});
}

test "the classes of the types of continuations" {
    try std.testing.expectEqual(Class.follow, comptime interpreter.classify(value_mod.Continuation).?);
    try std.testing.expectEqual(Class.follow, comptime interpreter.classify(*value_mod.Continuation).?);
    try std.testing.expectEqual(Class.follow, comptime interpreter.classify(value_mod.Rewind).?);
    try std.testing.expectEqual(Class.follow, comptime interpreter.classify(value_mod.WindPath).?);
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
        if (T == value_mod.Node or T == value_mod.GlobalAssign) {
            // Why: 節点と大域変数への代入は、大域変数のセルを指す(スライス 2j)。セルは
            // GC ヒープにあるが、GC が節点をたどらなくても回収されない。作られたセルは
            // すべて、REPL の束縛の表か、遮蔽されたインポートのセルの表か、`define-syntax`
            // が表から外したセルの表から到達できる(src/env.zig の `Global.mark`)。この
            // 不変条件は、tests/scheme/ のステップごとに GC する方式で、遮蔽された
            // プリミティブのセルや、マクロに置き換えられた変数のセルを、先に定義した
            // 手続きから読むケースが確かめる。
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
