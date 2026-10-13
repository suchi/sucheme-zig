//! Fixtures the tests of the primitive files share.
//!
//! 機械を起こさずにプリミティブを呼ぶための道具である。製品のコードからは使わない。

const std = @import("std");
const value = @import("../value.zig");
const Value = value.Value;
const Primitive = value.Primitive;
const heap_mod = @import("../heap.zig");

/// A heap, and the `Services` over it.
/// `init` が自分のアドレスを `services` に書くので、置いた場所から動かさない。
pub const Fixture = struct {
    heap: heap_mod.Heap,
    services: value.Services,

    pub fn init(self: *Fixture) void {
        self.heap = .init(std.testing.allocator, .{});
        self.services = .{ .heap = &self.heap, .scratch = std.testing.allocator };
    }

    pub fn deinit(self: *Fixture) void {
        self.heap.deinit();
    }

    /// Calls the primitive called `name` in `table` as the machine would.
    /// 個数の検査は機械のものなので、ここではしない。範囲に収まらない個数で呼ぶのは
    /// テストの誤りで、本体が `args` の範囲外を読む前に失敗させる。
    pub fn call(self: *Fixture, table: []const Primitive, name: []const u8, args: []const Value) value.PrimitiveError!Value {
        for (table) |*p| {
            if (!std.mem.eql(u8, p.name, name)) continue;
            std.debug.assert(p.acceptsCount(args.len));
            return switch (p.body) {
                .pure => |f| f(&self.services, args),
            };
        }
        std.debug.panic("no primitive called {s}", .{name});
    }
};

test {
    std.testing.refAllDecls(@This());
}

test "a fixture calls a primitive with its heap" {
    const probe = struct {
        fn f(services: *const value.Services, args: []const Value) value.PrimitiveError!Value {
            return services.heap.cons(args[0], .empty_list_value);
        }
    }.f;
    const table = [_]Primitive{.{ .name = "list1", .min_args = 1, .max_args = 1, .body = .{ .pure = &probe } }};
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    const result = try f.call(&table, "list1", &.{.fromFixnum(5)});
    try std.testing.expectEqual(5, result.asPair().?.car.asFixnum().?);
    try std.testing.expectEqual(1, f.heap.count);
}
