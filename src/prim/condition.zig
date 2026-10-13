//! Exception primitives (R7RS 6.11): `with-exception-handler`, `raise` and
//! `raise-continuable`.
//!
//! 3つとも機械操作プリミティブである。ここには名前と引数の個数の範囲だけを置き、操作は
//! `Machine.apply` が行う。ハンドラは動的状態の列の点として置き、現在のハンドラはその列から
//! 導く(ADR-0016)。`guard` は段階3で、Scheme の派生式として入る。

const std = @import("std");
const value = @import("../value.zig");
const Primitive = value.Primitive;

pub const primitives = [_]Primitive{
    .{ .name = "with-exception-handler", .min_args = 2, .max_args = 2, .body = .{ .machine = .with_exception_handler } },
    .{ .name = "raise", .min_args = 1, .max_args = 1, .body = .{ .machine = .raise } },
    .{ .name = "raise-continuable", .min_args = 1, .max_args = 1, .body = .{ .machine = .raise_continuable } },
};

test {
    std.testing.refAllDecls(@This());
}

test "the exception primitives are operations of the machine, with the counts R7RS gives them" {
    const expected = [_]struct { name: []const u8, count: u8, op: value.MachineOp }{
        .{ .name = "with-exception-handler", .count = 2, .op = .with_exception_handler },
        .{ .name = "raise", .count = 1, .op = .raise },
        .{ .name = "raise-continuable", .count = 1, .op = .raise_continuable },
    };
    try std.testing.expectEqual(expected.len, primitives.len);
    for (expected, primitives) |e, p| {
        try std.testing.expectEqualStrings(e.name, p.name);
        try std.testing.expectEqual(e.count, p.min_args);
        try std.testing.expectEqual(e.count, p.max_args.?);
        try std.testing.expectEqual(e.op, p.body.machine);
    }
}
