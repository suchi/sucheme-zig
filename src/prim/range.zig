//! The `start` and `end` arguments that the sequence procedures share (R7RS 6.7 to 6.9).
//!
//! 文字列、ベクタ、バイトベクタの手続きは、どれも省略できる `start` と `end` を取る。型の
//! 検査と範囲の検査を分け、手続きが、すべての型を検査してから、ほかのことを見られるようにする。
//! 検査の順序は、型、不変(`immutable.requireMutable`)、範囲の順である。

const std = @import("std");
const value = @import("../value.zig");
const Value = value.Value;
const PrimitiveError = value.PrimitiveError;

const Error = PrimitiveError;

/// The `start` and `end` arguments of a procedure, which are optional, as the numbers
/// they are given as. The types are checked here and the range later (`resolveRange`), so
/// that a procedure can check all the types before it looks at anything else.
pub const RangeOperands = struct {
    start: ?i64,
    end: ?i64,

    /// The operands from `args[first]` and `args[first + 1]`, where they are given.
    pub fn of(args: []const Value, first: usize) Error!RangeOperands {
        var result: RangeOperands = .{ .start = null, .end = null };
        if (args.len > first) result.start = args[first].asFixnum() orelse return error.WrongType;
        if (args.len > first + 1) result.end = args[first + 1].asFixnum() orelse return error.WrongType;
        return result;
    }
};

/// A range of positions: from `start` up to, and not including, `end`.
pub const Range = struct { start: usize, end: usize };

/// `start` and `end` as positions in a sequence of `len` elements: `start` defaults to 0
/// and `end` to `len`, and `0 <= start <= end <= len` must hold (R7RS 6.7, 6.8, 6.9).
///
/// Why: 引数は 64 ビットの整数なので、`usize` に変えられるかを先に調べる(`vector-ref` と同じ)。
/// `wasm32` で `@intCast` すると、大きな値の検査でパニックするか、切り捨てて範囲内に戻ってしまう。
pub fn resolveRange(operands: RangeOperands, len: usize) Error!Range {
    const start: usize = if (operands.start) |n| std.math.cast(usize, n) orelse return error.OutOfRange else 0;
    const end: usize = if (operands.end) |n| std.math.cast(usize, n) orelse return error.OutOfRange else len;
    if (end > len or start > end) return error.OutOfRange;
    return .{ .start = start, .end = end };
}

/// Where a `copy!` procedure reads and where it writes.
pub const CopyPlan = struct {
    /// The position in the destination at which the copy starts.
    at: usize,
    /// The positions in the source that are copied.
    range: Range,
};

/// The positions of `(copy! to at from start end)`, given the lengths of `to` and `from`
/// (R7RS 6.8, 6.9): `at` must be from 0 up to the length of `to`, `start` and `end` a range of
/// `from`, and the rest of `to` from `at` must hold the `end - start` elements.
///
/// 検査の順序は、`at`、`from` の範囲、`to` の残りの順である。
pub fn resolveCopy(at: i64, to_len: usize, operands: RangeOperands, from_len: usize) Error!CopyPlan {
    const at_index = std.math.cast(usize, at) orelse return error.OutOfRange;
    if (at_index > to_len) return error.OutOfRange;
    const range = try resolveRange(operands, from_len);
    if (to_len - at_index < range.end - range.start) return error.OutOfRange;
    return .{ .at = at_index, .range = range };
}

test {
    std.testing.refAllDecls(@This());
}

fn fix(n: i64) Value {
    return .fromFixnum(n);
}

test "the operands are read from where the arguments put them, and an absent one is null" {
    const args = [_]Value{ fix(9), fix(1), fix(2) };
    const none = try RangeOperands.of(args[0..1], 1);
    try std.testing.expectEqual(null, none.start);
    try std.testing.expectEqual(null, none.end);
    const one = try RangeOperands.of(args[0..2], 1);
    try std.testing.expectEqual(1, one.start.?);
    try std.testing.expectEqual(null, one.end);
    const both = try RangeOperands.of(&args, 1);
    try std.testing.expectEqual(1, both.start.?);
    try std.testing.expectEqual(2, both.end.?);
    // 先頭の引数は、範囲の引数ではないので読まない。
    const late = try RangeOperands.of(&args, 2);
    try std.testing.expectEqual(2, late.start.?);
    try std.testing.expectEqual(null, late.end);
}

test "an operand that is not an integer is a wrong type, whichever it is" {
    const string: Value = .empty_list_value;
    try std.testing.expectError(error.WrongType, RangeOperands.of(&.{ fix(0), string }, 1));
    try std.testing.expectError(error.WrongType, RangeOperands.of(&.{ fix(0), fix(0), string }, 1));
    try std.testing.expectError(error.WrongType, RangeOperands.of(&.{ fix(0), string, fix(0) }, 1));
}

test "a range defaults to the whole sequence, and must lie inside it" {
    const whole = try resolveRange(.{ .start = null, .end = null }, 4);
    try std.testing.expectEqual(0, whole.start);
    try std.testing.expectEqual(4, whole.end);
    const tail = try resolveRange(.{ .start = 3, .end = null }, 4);
    try std.testing.expectEqual(3, tail.start);
    try std.testing.expectEqual(4, tail.end);
    const empty = try resolveRange(.{ .start = 4, .end = 4 }, 4);
    try std.testing.expectEqual(4, empty.start);
    try std.testing.expectEqual(4, empty.end);
    try std.testing.expectError(error.OutOfRange, resolveRange(.{ .start = 5, .end = null }, 4));
    try std.testing.expectError(error.OutOfRange, resolveRange(.{ .start = null, .end = 5 }, 4));
    try std.testing.expectError(error.OutOfRange, resolveRange(.{ .start = 3, .end = 2 }, 4));
    try std.testing.expectError(error.OutOfRange, resolveRange(.{ .start = -1, .end = null }, 4));
    try std.testing.expectError(error.OutOfRange, resolveRange(.{ .start = null, .end = -1 }, 4));
    try std.testing.expectError(error.OutOfRange, resolveRange(.{ .start = null, .end = 1 << 32 }, 4));
    try std.testing.expectError(error.OutOfRange, resolveRange(.{ .start = null, .end = std.math.maxInt(i64) }, 4));
    try std.testing.expectError(error.OutOfRange, resolveRange(.{ .start = std.math.minInt(i64), .end = null }, 4));
}

test "a copy starts inside the destination and fits in what is left of it" {
    const plan = try resolveCopy(1, 5, .{ .start = 0, .end = 2 }, 5);
    try std.testing.expectEqual(1, plan.at);
    try std.testing.expectEqual(0, plan.range.start);
    try std.testing.expectEqual(2, plan.range.end);
    // 残りにちょうど収まる。何も写さないときは、末尾の位置から始めてよい。
    _ = try resolveCopy(3, 5, .{ .start = 0, .end = 2 }, 5);
    _ = try resolveCopy(5, 5, .{ .start = 2, .end = 2 }, 5);
    try std.testing.expectError(error.OutOfRange, resolveCopy(4, 5, .{ .start = 0, .end = 2 }, 5));
    try std.testing.expectError(error.OutOfRange, resolveCopy(6, 5, .{ .start = 0, .end = 0 }, 5));
    try std.testing.expectError(error.OutOfRange, resolveCopy(-1, 5, .{ .start = 0, .end = 0 }, 5));
    try std.testing.expectError(error.OutOfRange, resolveCopy(std.math.maxInt(i64), 5, .{ .start = null, .end = null }, 5));
    // 元の範囲が長さを超えるときは、残りが足りても断る。
    try std.testing.expectError(error.OutOfRange, resolveCopy(0, 9, .{ .start = 0, .end = 6 }, 5));
    try std.testing.expectError(error.OutOfRange, resolveCopy(0, 9, .{ .start = 3, .end = 2 }, 5));
}
