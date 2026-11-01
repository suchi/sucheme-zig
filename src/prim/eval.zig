//! Evaluation primitives (R7RS 6.12): `eval`, `environment` and
//! `interaction-environment`.
//!
//! `eval` と `environment` は機械操作プリミティブで、展開と輸入集合の評価は `Machine.apply` が
//! 行う(スライス 5o、docs/plans/0019-phase5-ports-and-io.md の合意を求める点の9)。
//! `interaction-environment` は純粋プリミティブで、REPL の最上位を指す指定子を作る。

const std = @import("std");
const value = @import("../value.zig");
const Value = value.Value;
const Primitive = value.Primitive;
const Services = value.Services;
const PrimitiveError = value.PrimitiveError;

pub const Error = PrimitiveError;

pub const primitives = [_]Primitive{
    .{ .name = "eval", .min_args = 2, .max_args = 2, .body = .{ .machine = .eval } },
    .{ .name = "environment", .min_args = 0, .max_args = null, .body = .{ .machine = .environment } },
    .{ .name = "interaction-environment", .min_args = 0, .max_args = 0, .body = .{ .pure = &interactionEnvironment } },
};

/// `(interaction-environment)`: an environment specifier for the REPL's top
/// level, where `eval` may define names (R7RS 6.12).
/// Why: 呼ぶたびに新しい値を作る。指す表は同じなので、どの値で `eval` しても同じ最上位に
/// 定義が残る。R7RS 6.12 は、同じ値を返すことを求めていない。
fn interactionEnvironment(services: *const Services, _: []const Value) Error!Value {
    const made = try services.heap.create(value.Environment, .{ .root = null, .mutable = true });
    return .fromEnvironment(made);
}

test {
    std.testing.refAllDecls(@This());
}
