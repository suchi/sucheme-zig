//! The table of the primitives the global environment binds.
//!
//! プリミティブを足すスライスは、自分の族のファイル(`prim/*.zig`)の `primitives` を
//! 下の `families` に1行足す。名前は表の全体で一意でなければならない。

const std = @import("std");
const Primitive = @import("../value.zig").Primitive;
const arith = @import("arith.zig");
const char = @import("char.zig");

/// The primitives of each family, in the order they are bound.
const families = [_][]const Primitive{
    &arith.primitives,
    &char.primitives,
};

const total = blk: {
    var n: usize = 0;
    for (families) |family| n += family.len;
    break :blk n;
};

/// Every primitive, in one array.
/// `Context` が、名前をこの要素に束縛する。
pub const all: [total]Primitive = blk: {
    var out: [total]Primitive = undefined;
    var i: usize = 0;
    for (families) |family| {
        for (family) |p| {
            out[i] = p;
            i += 1;
        }
    }
    break :blk out;
};

test {
    std.testing.refAllDecls(@This());
}

test "the table names each primitive once" {
    for (all, 0..) |p, i| {
        try std.testing.expect(p.name.len > 0);
        for (all[i + 1 ..]) |q| try std.testing.expect(!std.mem.eql(u8, p.name, q.name));
    }
}

test "the table gives each primitive a range of argument counts that can be met" {
    for (all) |p| {
        if (p.max_args) |max| try std.testing.expect(p.min_args <= max);
    }
}

test "the table holds every primitive of every family" {
    var n: usize = 0;
    for (families) |family| n += family.len;
    try std.testing.expectEqual(n, all.len);
    for (families) |family| {
        for (family) |p| {
            var found = false;
            for (all) |q| {
                if (std.mem.eql(u8, p.name, q.name) and p.call == q.call) found = true;
            }
            try std.testing.expect(found);
        }
    }
}
