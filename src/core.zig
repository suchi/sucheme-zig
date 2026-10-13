//! The core IR: helpers over the nodes of value.zig.
//!
//! 配置(レイアウト)は value.zig にある。GC が辿るものはすべてそこで定義する
//! (docs/design/architecture.md)。このファイルはノードを作り、テキストとして
//! 書き出す。展開器のテストは、展開器が作ったものをこれで読む。

const std = @import("std");
const value_mod = @import("value.zig");
const Value = value_mod.Value;
const Node = value_mod.Node;
const symbol = @import("symbol.zig");
const printer = @import("printer.zig");
const Heap = @import("heap.zig").Heap;

pub const Error = std.Io.Writer.Error || error{OutOfMemory};

/// A new node holding `n`, allocated with `alloc`.
pub fn make(alloc: std.mem.Allocator, n: Node) error{OutOfMemory}!*const Node {
    const p = try alloc.create(Node);
    p.* = n;
    return p;
}

/// Writes `node` as a list that names the kind of node first, for the tests of
/// the expander.
///
/// `read` が読み戻せる形ではない。IR はソースではない。
///
/// ノードは再帰で書き、その深さはノードの木の深さに等しい。呼び出し側はテスト
/// だけなので、深い入力はここでは問題にならない。プログラムの入力を受け取る
/// 呼び出し側は、これを使ってはならない。
pub fn write(out: *std.Io.Writer, scratch: std.mem.Allocator, symbols: *const symbol.Table, node: *const Node) Error!void {
    switch (node.*) {
        .constant => |v| {
            try out.writeAll("(const ");
            try printer.write(out, scratch, symbols, v);
            try out.writeByte(')');
        },
        .local_ref => |r| try out.print("(local {s} {d} {d})", .{ symbols.nameOf(r.name), r.address.depth, r.address.index }),
        .global_ref => |cell| try out.print("(global {s})", .{symbols.nameOf(cell.name)}),
        .local_set => |a| {
            try out.print("(set-local {s} {d} {d} ", .{ symbols.nameOf(a.name), a.address.depth, a.address.index });
            try write(out, scratch, symbols, a.value);
            try out.writeByte(')');
        },
        .local_define => |a| {
            try out.print("(define-local {s} {d} {d} ", .{ symbols.nameOf(a.name), a.address.depth, a.address.index });
            try write(out, scratch, symbols, a.value);
            try out.writeByte(')');
        },
        .global_set => |a| {
            try out.print("(set-global {s} ", .{symbols.nameOf(a.cell.name)});
            try write(out, scratch, symbols, a.value);
            try out.writeByte(')');
        },
        .global_define => |a| {
            try out.print("(define-global {s} ", .{symbols.nameOf(a.cell.name)});
            try write(out, scratch, symbols, a.value);
            try out.writeByte(')');
        },
        .@"if" => |i| {
            try out.writeAll("(if ");
            try write(out, scratch, symbols, i.condition);
            try out.writeByte(' ');
            try write(out, scratch, symbols, i.consequent);
            if (i.alternative) |alt| {
                try out.writeByte(' ');
                try write(out, scratch, symbols, alt);
            }
            try out.writeByte(')');
        },
        .sequence => |nodes| {
            try out.writeAll("(seq");
            for (nodes) |n| {
                try out.writeByte(' ');
                try write(out, scratch, symbols, n);
            }
            try out.writeByte(')');
        },
        // 余りの引数を受ける手続きは、必須の個数のあとに `rest` と書く。固定個の手続きの
        // 書き方は変えない。
        .lambda => |l| {
            if (l.rest) {
                try out.print("(lambda {d} rest {d} ", .{ l.arity, l.frame_size });
            } else {
                try out.print("(lambda {d} {d} ", .{ l.arity, l.frame_size });
            }
            try write(out, scratch, symbols, l.body);
            try out.writeByte(')');
        },
        .call => |c| {
            try out.writeAll("(call ");
            try write(out, scratch, symbols, c.operator);
            for (c.operands) |n| {
                try out.writeByte(' ');
                try write(out, scratch, symbols, n);
            }
            try out.writeByte(')');
        },
    }
}

test {
    std.testing.refAllDecls(@This());
}

/// The text of `node`, in memory owned by the caller.
fn written(gpa: std.mem.Allocator, symbols: *const symbol.Table, node: *const Node) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    try write(&out.writer, gpa, symbols, node);
    return out.toOwnedSlice();
}

test "make allocates a node that holds what it was given" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const n = try make(arena.allocator(), .{ .constant = .fromFixnum(7) });
    try std.testing.expectEqual(7, n.constant.asFixnum().?);
}

test "write names each kind of node and its parts" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var symbols: symbol.Table = .{};
    const x = try symbols.intern(a, "x");
    const f = try symbols.intern(a, "f");

    const one = try make(a, .{ .constant = .fromFixnum(1) });
    const local = try make(a, .{ .local_ref = .{ .address = .{ .depth = 1, .index = 2 }, .name = x } });
    // 大域変数の節点はセルを指し、書き出すのはセルの名前である。
    var cell: value_mod.Cell = .{ .name = f, .value = .uninitialized_value };
    const global = try make(a, .{ .global_ref = &cell });
    const set_local = try make(a, .{ .local_set = .{ .address = .{ .depth = 0, .index = 0 }, .name = x, .value = one } });
    const define_local = try make(a, .{ .local_define = .{ .address = .{ .depth = 0, .index = 1 }, .name = x, .value = one } });
    const set_global = try make(a, .{ .global_set = .{ .cell = &cell, .value = one } });
    const define_global = try make(a, .{ .global_define = .{ .cell = &cell, .value = one } });
    const no_alt = try make(a, .{ .@"if" = .{ .condition = one, .consequent = local, .alternative = null } });
    const with_alt = try make(a, .{ .@"if" = .{ .condition = one, .consequent = local, .alternative = global } });
    const seq = try make(a, .{ .sequence = &.{ one, local } });
    const lambda = value_mod.Lambda{ .arity = 1, .frame_size = 2, .body = seq };
    const lam = try make(a, .{ .lambda = &lambda });
    const variadic = value_mod.Lambda{ .arity = 1, .rest = true, .frame_size = 2, .body = local };
    const lam_rest = try make(a, .{ .lambda = &variadic });
    const call = try make(a, .{ .call = .{ .operator = global, .operands = &.{ one, local } } });

    const cases = [_]struct { node: *const Node, text: []const u8 }{
        .{ .node = one, .text = "(const 1)" },
        .{ .node = local, .text = "(local x 1 2)" },
        .{ .node = global, .text = "(global f)" },
        .{ .node = set_local, .text = "(set-local x 0 0 (const 1))" },
        .{ .node = define_local, .text = "(define-local x 0 1 (const 1))" },
        .{ .node = set_global, .text = "(set-global f (const 1))" },
        .{ .node = define_global, .text = "(define-global f (const 1))" },
        .{ .node = no_alt, .text = "(if (const 1) (local x 1 2))" },
        .{ .node = with_alt, .text = "(if (const 1) (local x 1 2) (global f))" },
        .{ .node = seq, .text = "(seq (const 1) (local x 1 2))" },
        .{ .node = lam, .text = "(lambda 1 2 (seq (const 1) (local x 1 2)))" },
        .{ .node = lam_rest, .text = "(lambda 1 rest 2 (local x 1 2))" },
        .{ .node = call, .text = "(call (global f) (const 1) (local x 1 2))" },
    };
    for (cases) |c| {
        const text = try written(std.testing.allocator, &symbols, c.node);
        defer std.testing.allocator.free(text);
        try std.testing.expectEqualStrings(c.text, text);
    }
}

test "write prints a quoted datum with the printer" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var symbols: symbol.Table = .{};
    var heap: Heap = .init(std.testing.allocator, .{});
    defer heap.deinit();
    const s = Value.fromSymbol(try symbols.intern(a, "a"));
    const datum = try heap.cons(s, try heap.cons(.fromFixnum(2), Value.empty_list_value));
    const n = try make(a, .{ .constant = datum });
    const text = try written(std.testing.allocator, &symbols, n);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("(const (a 2))", text);
}
