//! Exception primitives (R7RS 6.11): `with-exception-handler`, `raise`,
//! `raise-continuable` and `error`, and the predicates and accessors of the
//! condition objects.
//!
//! 前の4つは機械操作プリミティブである。ここには名前と引数の個数の範囲だけを置き、操作は
//! `Machine.apply` が行う。ハンドラは動的状態の列の点として置き、現在のハンドラはその列から
//! 導く(ADR-0016)。`guard` は段階3で、Scheme の派生式として入る。

const std = @import("std");
const value = @import("../value.zig");
const Value = value.Value;
const Primitive = value.Primitive;
const Services = value.Services;
const PrimitiveError = value.PrimitiveError;

pub const Error = PrimitiveError;

pub const primitives = [_]Primitive{
    .{ .name = "with-exception-handler", .min_args = 2, .max_args = 2, .body = .{ .machine = .with_exception_handler } },
    .{ .name = "raise", .min_args = 1, .max_args = 1, .body = .{ .machine = .raise } },
    .{ .name = "raise-continuable", .min_args = 1, .max_args = 1, .body = .{ .machine = .raise_continuable } },
    // `(error message obj ...)`: メッセージは省けない。
    .{ .name = "error", .min_args = 1, .max_args = null, .body = .{ .machine = .@"error" } },
    .{ .name = "error-object?", .min_args = 1, .max_args = 1, .body = .{ .pure = &isErrorObject } },
    .{ .name = "error-object-message", .min_args = 1, .max_args = 1, .body = .{ .pure = &message } },
    .{ .name = "error-object-irritants", .min_args = 1, .max_args = 1, .body = .{ .pure = &irritants } },
    .{ .name = "read-error?", .min_args = 1, .max_args = 1, .body = .{ .pure = &isReadError } },
    .{ .name = "file-error?", .min_args = 1, .max_args = 1, .body = .{ .pure = &isFileError } },
};

/// `(error-object? obj)`: true of every condition object.
/// R7RS 6.11 は、`error` が作ったものと、処理系が決めるものに真とする。この処理系の
/// 条件オブジェクトは、種別によらずすべて真である。
fn isErrorObject(_: *const Services, args: []const Value) Error!Value {
    return .fromBool(args[0].asCondition() != null);
}

/// `(error-object-message error-object)`: the message of the condition.
fn message(_: *const Services, args: []const Value) Error!Value {
    const c = args[0].asCondition() orelse return error.WrongType;
    return c.message;
}

/// `(error-object-irritants error-object)`: the list of the irritants.
/// リストは条件が持つものそのもので、写さない。
fn irritants(_: *const Services, args: []const Value) Error!Value {
    const c = args[0].asCondition() orelse return error.WrongType;
    return c.irritants;
}

/// `(read-error? obj)`: true of a condition the reader raised.
fn isReadError(_: *const Services, args: []const Value) Error!Value {
    return .fromBool(isOfKind(args[0], .read));
}

/// `(file-error? obj)`: true of a condition that opening a file raised.
fn isFileError(_: *const Services, args: []const Value) Error!Value {
    return .fromBool(isOfKind(args[0], .file));
}

/// Whether `v` is a condition of `kind`.
fn isOfKind(v: Value, kind: value.ConditionKind) bool {
    const c = v.asCondition() orelse return false;
    return c.kind == kind;
}

test {
    std.testing.refAllDecls(@This());
}

const test_support = @import("test_support.zig");

test "the exception procedures that act on the machine are operations of the machine, with the counts R7RS gives them" {
    const expected = [_]struct { name: []const u8, min: u8, max: ?u8, op: value.MachineOp }{
        .{ .name = "with-exception-handler", .min = 2, .max = 2, .op = .with_exception_handler },
        .{ .name = "raise", .min = 1, .max = 1, .op = .raise },
        .{ .name = "raise-continuable", .min = 1, .max = 1, .op = .raise_continuable },
        .{ .name = "error", .min = 1, .max = null, .op = .@"error" },
    };
    for (expected, primitives[0..expected.len]) |e, p| {
        try std.testing.expectEqualStrings(e.name, p.name);
        try std.testing.expectEqual(e.min, p.min_args);
        try std.testing.expectEqual(e.max, p.max_args);
        try std.testing.expectEqual(e.op, p.body.machine);
    }
    // 残りは1引数の純粋プリミティブである。
    for (primitives[expected.len..]) |p| {
        try std.testing.expectEqual(1, p.min_args);
        try std.testing.expectEqual(1, p.max_args.?);
        try std.testing.expect(p.body == .pure);
    }
}

/// Conditions of each kind, and a value that is not one.
const Samples = struct {
    bytes: [3]u8 = "bad".*,
    text: value.String = undefined,
    pair: value.Pair = .{ .car = .fromFixnum(1), .cdr = .empty_list_value },
    general: value.Condition = undefined,
    read: value.Condition = undefined,
    file: value.Condition = undefined,

    fn link(self: *Samples) void {
        self.text = .{ .bytes = &self.bytes, .is_ascii = true };
        self.general = .{ .kind = .@"error", .message = .fromString(&self.text), .irritants = .{ .pair = &self.pair } };
        self.read = .{ .kind = .read, .message = .fromString(&self.text), .irritants = .empty_list_value };
        self.file = .{ .kind = .file, .message = .fromString(&self.text), .irritants = .empty_list_value };
    }
};

fn callWith(name: []const u8, arg: Value) !Value {
    var f: test_support.Fixture = undefined;
    f.init();
    defer f.deinit();
    return f.call(&primitives, name, &.{arg});
}

test "error-object? is true of every condition, and the other two predicates of their own kind" {
    var s: Samples = .{};
    s.link();
    const cases = [_]struct { v: Value, any: bool, read: bool, file: bool }{
        .{ .v = .fromCondition(&s.general), .any = true, .read = false, .file = false },
        .{ .v = .fromCondition(&s.read), .any = true, .read = true, .file = false },
        .{ .v = .fromCondition(&s.file), .any = true, .read = false, .file = true },
        .{ .v = .fromString(&s.text), .any = false, .read = false, .file = false },
        .{ .v = .fromFixnum(0), .any = false, .read = false, .file = false },
        .{ .v = .fromBool(false), .any = false, .read = false, .file = false },
    };
    for (cases) |c| {
        try std.testing.expectEqual(c.any, (try callWith("error-object?", c.v)).isTrue());
        try std.testing.expectEqual(c.read, (try callWith("read-error?", c.v)).isTrue());
        try std.testing.expectEqual(c.file, (try callWith("file-error?", c.v)).isTrue());
    }
}

test "the accessors give the message and the irritants the condition holds, and refuse anything else" {
    var s: Samples = .{};
    s.link();
    try std.testing.expectEqual(&s.text, (try callWith("error-object-message", .fromCondition(&s.general))).asString().?);
    try std.testing.expectEqual(&s.pair, (try callWith("error-object-irritants", .fromCondition(&s.general))).asPair().?);
    try std.testing.expectEqual(value.Kind.empty_list, (try callWith("error-object-irritants", .fromCondition(&s.read))).kind());
    try std.testing.expectError(error.WrongType, callWith("error-object-message", .fromString(&s.text)));
    try std.testing.expectError(error.WrongType, callWith("error-object-irritants", .fromFixnum(1)));
}
