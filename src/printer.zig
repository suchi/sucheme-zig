//! Writes values in their external representation.
//!
//! Slice 1c prints integers, booleans, symbols and lists; the unspecified value
//! has no external form, so callers that print results skip it. `write` and
//! `display` differ first for strings and characters, which arrive in slice 1h.
//!
//! The depth of the data decides how deep printing goes, so it runs on an
//! explicit stack and not on Zig recursion (docs/design/runtime.md).

const std = @import("std");
const Value = @import("value.zig").Value;
const symbol = @import("symbol.zig");

pub const Error = std.Io.Writer.Error || error{OutOfMemory};

/// What is left to write.
const Item = union(enum) {
    /// A value to write whole.
    value: Value,
    /// The rest of a list after an element: a space and the next element, a
    /// closing parenthesis at the end, or ` . ` and a non-list tail.
    rest: Value,
    /// Text to write as it is.
    text: []const u8,
};

/// Writes `v` as `write` would (R7RS 6.13.3). Symbol names come from `symbols`.
/// `scratch` holds the stack of what is left to write, and is the caller's to
/// free.
///
/// A symbol is written by its name alone. The names the reader produces never
/// need the `|...|` form; the procedures that make other symbols come with the
/// slices that need it.
pub fn write(out: *std.Io.Writer, scratch: std.mem.Allocator, symbols: *const symbol.Table, v: Value) Error!void {
    var stack: std.ArrayList(Item) = .empty;
    defer stack.deinit(scratch);
    try stack.append(scratch, .{ .value = v });
    while (stack.pop()) |item| switch (item) {
        .text => |t| try out.writeAll(t),
        .value => |x| switch (x.kind()) {
            .fixnum => try out.print("{d}", .{x.asFixnum().?}),
            .boolean => try out.writeAll(if (x.isTrue()) "#t" else "#f"),
            .empty_list => try out.writeAll("()"),
            .symbol => try out.writeAll(symbols.nameOf(x.asSymbol().?)),
            .pair => {
                const p = x.asPair().?;
                try out.writeByte('(');
                try stack.append(scratch, .{ .rest = p.cdr });
                try stack.append(scratch, .{ .value = p.car });
            },
            // Nothing to write. The caller decides not to print the value at all.
            .unspecified => {},
        },
        .rest => |tail| switch (tail.kind()) {
            .empty_list => try out.writeByte(')'),
            .pair => {
                const p = tail.asPair().?;
                try out.writeByte(' ');
                try stack.append(scratch, .{ .rest = p.cdr });
                try stack.append(scratch, .{ .value = p.car });
            },
            else => {
                try out.writeAll(" . ");
                try stack.append(scratch, .{ .text = ")" });
                try stack.append(scratch, .{ .value = tail });
            },
        },
    };
}

test {
    std.testing.refAllDecls(@This());
}

/// A scratch space for the tests: symbols a, b, and pairs, all in one arena.
const Fixture = struct {
    arena: std.heap.ArenaAllocator,
    symbols: symbol.Table = .{},

    fn init() Fixture {
        return .{ .arena = .init(std.testing.allocator) };
    }

    fn deinit(self: *Fixture) void {
        self.arena.deinit();
    }

    fn sym(self: *Fixture, name: []const u8) !Value {
        return .fromSymbol(try self.symbols.intern(self.arena.allocator(), name));
    }

    fn cons(self: *Fixture, car: Value, cdr: Value) !Value {
        return Value.cons(self.arena.allocator(), car, cdr);
    }

    /// The list of `items`, ending in `tail`.
    fn list(self: *Fixture, items: []const Value, tail: Value) !Value {
        var result = tail;
        var i = items.len;
        while (i > 0) {
            i -= 1;
            result = try self.cons(items[i], result);
        }
        return result;
    }

    fn written(self: *Fixture, buf: []u8, v: Value) ![]const u8 {
        var w: std.Io.Writer = .fixed(buf);
        try write(&w, std.testing.allocator, &self.symbols, v);
        return w.buffered();
    }
};

test "write prints an integer in decimal with its sign" {
    var f: Fixture = .init();
    defer f.deinit();
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("42", try f.written(&buf, .fromFixnum(42)));
    try std.testing.expectEqualStrings("-7", try f.written(&buf, .fromFixnum(-7)));
    try std.testing.expectEqualStrings("0", try f.written(&buf, .fromFixnum(0)));
}

test "write prints the extremes of a fixnum" {
    var f: Fixture = .init();
    defer f.deinit();
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("-9223372036854775808", try f.written(&buf, .fromFixnum(std.math.minInt(i64))));
    try std.testing.expectEqualStrings("9223372036854775807", try f.written(&buf, .fromFixnum(std.math.maxInt(i64))));
}

test "write writes nothing for the unspecified value" {
    var f: Fixture = .init();
    defer f.deinit();
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("", try f.written(&buf, .unspecified_value));
}

test "write prints booleans, the empty list and symbols" {
    var f: Fixture = .init();
    defer f.deinit();
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("#t", try f.written(&buf, .fromBool(true)));
    try std.testing.expectEqualStrings("#f", try f.written(&buf, .fromBool(false)));
    try std.testing.expectEqualStrings("()", try f.written(&buf, Value.empty_list_value));
    try std.testing.expectEqualStrings("list->vector", try f.written(&buf, try f.sym("list->vector")));
}

test "write prints a list with one space between elements" {
    var f: Fixture = .init();
    defer f.deinit();
    var buf: [64]u8 = undefined;
    const l = try f.list(&.{ .fromFixnum(1), try f.sym("a"), .fromBool(false) }, Value.empty_list_value);
    try std.testing.expectEqualStrings("(1 a #f)", try f.written(&buf, l));
    const one = try f.list(&.{.fromFixnum(1)}, Value.empty_list_value);
    try std.testing.expectEqualStrings("(1)", try f.written(&buf, one));
}

test "write prints nested lists and the empty list inside one" {
    var f: Fixture = .init();
    defer f.deinit();
    var buf: [64]u8 = undefined;
    const inner = try f.list(&.{ try f.sym("b"), try f.sym("c") }, Value.empty_list_value);
    const l = try f.list(&.{ try f.sym("a"), inner, Value.empty_list_value }, Value.empty_list_value);
    try std.testing.expectEqualStrings("(a (b c) ())", try f.written(&buf, l));
}

test "write prints a list that does not end in the empty list with a dot" {
    var f: Fixture = .init();
    defer f.deinit();
    var buf: [64]u8 = undefined;
    const improper = try f.list(&.{ .fromFixnum(1), .fromFixnum(2) }, .fromFixnum(3));
    try std.testing.expectEqualStrings("(1 2 . 3)", try f.written(&buf, improper));
    const pair = try f.cons(.fromFixnum(1), .fromFixnum(2));
    try std.testing.expectEqualStrings("(1 . 2)", try f.written(&buf, pair));
    // The tail can itself be a list that needs the closing parenthesis.
    const nested_tail = try f.cons(.fromFixnum(1), try f.cons(.fromFixnum(2), try f.sym("t")));
    try std.testing.expectEqualStrings("(1 2 . t)", try f.written(&buf, nested_tail));
}

test "write does not recurse on the depth of the data" {
    var f: Fixture = .init();
    defer f.deinit();
    // A list nested 200000 deep in its first element, and one 200000 long.
    const depth = 200_000;
    var deep: Value = Value.empty_list_value;
    for (0..depth) |_| deep = try f.cons(deep, Value.empty_list_value);
    var long: Value = Value.empty_list_value;
    for (0..depth) |_| long = try f.cons(.fromFixnum(1), long);
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try write(&out.writer, std.testing.allocator, &f.symbols, deep);
    try std.testing.expectEqual(depth * 2 + 2, out.written().len);
    out.clearRetainingCapacity();
    try write(&out.writer, std.testing.allocator, &f.symbols, long);
    try std.testing.expectEqual(depth * 2 + 1, out.written().len);
}
