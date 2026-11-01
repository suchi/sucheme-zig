//! Process context primitives (R7RS 6.14): `command-line`, `exit`,
//! `emergency-exit`, `get-environment-variable` and `get-environment-variables`.
//!
//! `exit` と `emergency-exit` は機械操作プリミティブである。終了コードへの変換と、`exit` が
//! `dynamic-wind` の `after` を呼ぶ巻き戻しは `Machine.apply` が行う。ほかは純粋プリミティブで、
//! コマンドラインと環境変数は、`Interpreter` がヒープに置いたもの(`Heap.command_line`、
//! `Heap.process_environ`)を読む。

const std = @import("std");
const value = @import("../value.zig");
const Value = value.Value;
const Primitive = value.Primitive;
const Services = value.Services;
const PrimitiveError = value.PrimitiveError;

pub const Error = PrimitiveError;

pub const primitives = [_]Primitive{
    .{ .name = "command-line", .min_args = 0, .max_args = 0, .body = .{ .pure = &commandLine } },
    .{ .name = "exit", .min_args = 0, .max_args = 1, .body = .{ .machine = .exit } },
    .{ .name = "emergency-exit", .min_args = 0, .max_args = 1, .body = .{ .machine = .emergency_exit } },
    .{ .name = "get-environment-variable", .min_args = 1, .max_args = 1, .body = .{ .pure = &getVariable } },
    .{ .name = "get-environment-variables", .min_args = 0, .max_args = 0, .body = .{ .pure = &getVariables } },
};

/// `(command-line)`: the command line of the program, as a new list of strings,
/// the name of the program first.
/// Why: 呼ぶたびに新しいリストと文字列を作る。返したものを書き換えても、次の呼び出しに
/// 響かない(R7RS 6.14 は、変えてよいかを定めていない)。
fn commandLine(services: *const Services, _: []const Value) Error!Value {
    const heap = services.heap;
    var list: Value = .empty_list_value;
    var i = heap.command_line.len;
    while (i > 0) {
        i -= 1;
        const s = try heap.createString(heap.command_line[i]);
        list = try heap.cons(.fromString(s), list);
    }
    return list;
}

/// `(get-environment-variable name)`: the value of the environment variable
/// `name` as a new string, or `#f` when there is none.
/// 値が UTF-8 でなければ、文字列にできないので `InvalidUtf8` である(docs/design/platform-and-web.md
/// の検証の表)。
fn getVariable(services: *const Services, args: []const Value) Error!Value {
    const name = args[0].asString() orelse return error.WrongType;
    const map = services.heap.process_environ orelse return .fromBool(false);
    const found = map.get(name.bytes) orelse return .fromBool(false);
    if (!std.unicode.utf8ValidateSlice(found)) return error.InvalidUtf8;
    return .fromString(try services.heap.createString(found));
}

/// `(get-environment-variables)`: every environment variable, as a new
/// association list of name and value strings.
/// 名前か値が UTF-8 でない項目は、文字列にできないので除く(docs/design/platform-and-web.md の
/// 検証の表)。
fn getVariables(services: *const Services, _: []const Value) Error!Value {
    const heap = services.heap;
    const map = heap.process_environ orelse return .empty_list_value;
    var list: Value = .empty_list_value;
    var it = map.iterator();
    while (it.next()) |entry| {
        const name = entry.key_ptr.*;
        const v = entry.value_ptr.*;
        if (!std.unicode.utf8ValidateSlice(name) or !std.unicode.utf8ValidateSlice(v)) continue;
        const pair = try heap.cons(.fromString(try heap.createString(name)), .fromString(try heap.createString(v)));
        list = try heap.cons(pair, list);
    }
    return list;
}

test {
    std.testing.refAllDecls(@This());
}
