//! Evaluates a datum.
//!
//! A plain recursive evaluator, as docs/plans/0003-phase1-minimal-slice.md
//! decides for slices 1a to 1e. Slice 1f replaces it with the CEK machine in
//! machine.zig, which is the only place docs/design/architecture.md lets
//! evaluation advance. That document records this file as a provisional
//! exception until then.
//!
//! Slice 1a evaluates integers and calls to a primitive named in the operator
//! position. Variables, `define` and the reporting of errors as Scheme
//! conditions arrive in slice 1b; until then a Scheme error is a Zig error.

const std = @import("std");
const Value = @import("value.zig").Value;
const Datum = @import("reader.zig").Datum;
const arith = @import("prim/arith.zig");

pub const Error = arith.Error || error{
    OutOfMemory,
    /// `()` is not an expression (R7RS 4.1.3 requires an operator).
    EmptyCombination,
    /// An identifier naming nothing.
    UnboundVariable,
    /// An identifier outside the operator position. Slice 1a has no
    /// variables and no procedure values to give it.
    VariableReferenceUnsupported,
    /// The operator is not a procedure.
    NotAProcedure,
    /// The expression nests deeper than `max_depth`.
    NestingTooDeep,
};

/// How deep `eval` recurses before giving up.
///
/// The recursion is on the Zig stack, and a nesting deep enough to overflow it
/// would kill the process instead of reporting an error. The reader handles any
/// depth, so this is where the limit has to be. It goes with the recursion,
/// when slice 1f moves evaluation into the machine.
///
/// Why: a Debug build uses about a kilobyte of stack per level, measured by
/// running nested `(+ (+ ... 1))` against `ulimit -s`; at 8 MiB it overflowed
/// before 10_000 levels. 500 stays inside a 1 MiB stack, the smallest a host
/// might give, with room to spare.
pub const max_depth = 500;

/// Evaluates `d`. Temporary storage, such as the evaluated arguments, comes
/// from `arena`.
pub fn eval(arena: std.mem.Allocator, d: Datum) Error!Value {
    return evalAt(arena, d, 0);
}

fn evalAt(arena: std.mem.Allocator, d: Datum, depth: usize) Error!Value {
    if (depth >= max_depth) return error.NestingTooDeep;
    switch (d) {
        .integer => |n| return .fromFixnum(n),
        .identifier => |name| return if (arith.lookup(name) == null)
            error.UnboundVariable
        else
            error.VariableReferenceUnsupported,
        .list => |items| {
            if (items.len == 0) return error.EmptyCombination;
            const prim = switch (items[0]) {
                .identifier => |name| arith.lookup(name) orelse return error.UnboundVariable,
                else => {
                    // Evaluated for its errors; no value of slice 1a is a
                    // procedure.
                    _ = try evalAt(arena, items[0], depth + 1);
                    return error.NotAProcedure;
                },
            };
            const args = try arena.alloc(Value, items.len - 1);
            for (items[1..], args) |item, *arg| arg.* = try evalAt(arena, item, depth + 1);
            return prim.call(args);
        },
    }
}

test {
    std.testing.refAllDecls(@This());
}

fn evalSource(arena: std.mem.Allocator, src: []const u8) Error!i64 {
    var r: @import("reader.zig").Reader = .init(src);
    const d = (r.next(arena) catch unreachable).?;
    return (try eval(arena, d)).asFixnum().?;
}

test "eval returns an integer as itself and applies +" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqual(42, try evalSource(a, "42"));
    try std.testing.expectEqual(3, try evalSource(a, "(+ 1 2)"));
    try std.testing.expectEqual(10, try evalSource(a, "(+ (+ 1 2) (+ 3 4))"));
    try std.testing.expectEqual(0, try evalSource(a, "(+)"));
}

test "eval reports what it cannot evaluate" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectError(error.EmptyCombination, evalSource(a, "()"));
    try std.testing.expectError(error.UnboundVariable, evalSource(a, "(foo 1)"));
    try std.testing.expectError(error.UnboundVariable, evalSource(a, "foo"));
    try std.testing.expectError(error.VariableReferenceUnsupported, evalSource(a, "+"));
    try std.testing.expectError(error.NotAProcedure, evalSource(a, "(1 2)"));
    // The operator's own error comes first.
    try std.testing.expectError(error.EmptyCombination, evalSource(a, "(() 2)"));
    try std.testing.expectError(error.IntegerOverflow, evalSource(a, "(+ 9223372036854775807 1)"));
}

/// `(+ (+ ... (+ 1)))` with `calls` calls: the innermost `1` is evaluated at
/// depth `calls`.
fn nestedCalls(a: std.mem.Allocator, calls: usize) ![]const u8 {
    const src = try a.alloc(u8, calls * 3 + 1 + calls);
    for (0..calls) |k| @memcpy(src[k * 3 ..][0..3], "(+ ");
    src[calls * 3] = '1';
    @memset(src[calls * 3 + 1 ..], ')');
    return src;
}

test "eval reports a nesting it cannot recurse into instead of overflowing" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectError(error.NestingTooDeep, evalSource(a, try nestedCalls(a, max_depth)));
}

test "eval handles the deepest nesting the limit allows" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqual(1, try evalSource(a, try nestedCalls(a, max_depth - 1)));
}
