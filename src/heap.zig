//! The GC heap: where the objects of a running program live
//! (docs/design/runtime.md, ADR-0003).
//!
//! Every object is a `Cell`: a header, then the object. The headers are linked
//! in one list, which is what the sweep walks. The heap accounts for the bytes
//! of its cells and of the payloads they own, and refuses an allocation that
//! would take the account past its limit; the interpreter's arena, where the
//! code and the symbols are, is outside the account.
//!
//! The heap never collects inside an allocation. A collection is asked for by
//! `shouldCollect` and run by `collect`, both of which the machine calls between
//! two steps, where no value is half-made (ADR-0031).

const std = @import("std");
const value_mod = @import("value.zig");
const Value = value_mod.Value;
const Pair = value_mod.Pair;
const Closure = value_mod.Closure;
const Frame = value_mod.Frame;
const Kont = value_mod.Kont;
const Args = value_mod.Args;

/// The types that live in the heap. A pointer to one of them is followed by the
/// collector; the index of a type here is the `kind` its header records.
pub const object_types = [_]type{ Pair, Closure, Frame, Kont, Args };

pub const Error = error{
    OutOfMemory,
    /// The allocation would take the account past the limit.
    HeapLimit,
};

pub const Options = struct {
    /// The most bytes the heap accounts for.
    limit: usize = default_limit,
    /// The account at which the first collection is asked for, and the least
    /// that any later one is asked for at.
    min_threshold: usize = 1024 * 1024,
};

/// 256 MiB: far above what a program that returns needs, and far below the
/// memory of the machines the interpreter runs on.
pub const default_limit: usize = 256 * 1024 * 1024;

const Header = struct {
    next: ?*Header,
    /// An index into `object_types`.
    kind: u8,
};

fn Cell(comptime T: type) type {
    return struct {
        header: Header,
        value: T,
    };
}

fn kindOf(comptime T: type) u8 {
    inline for (object_types, 0..) |U, i| {
        if (U == T) return i;
    }
    @compileError("not a heap object type: " ++ @typeName(T));
}

/// The bytes a cell of `T` accounts for, without its payload.
fn cellBytes(comptime T: type) usize {
    return @sizeOf(Cell(T));
}

/// The bytes the object owns beyond its cell. Only a frame owns any: the slots
/// of its variables.
fn payloadBytes(comptime T: type, object: *const T) usize {
    return if (T == Frame) object.values.len * @sizeOf(Value) else 0;
}

pub const Heap = struct {
    backing: std.mem.Allocator,
    options: Options,
    /// Every object, newest first.
    objects: ?*Header = null,
    /// The bytes of the cells and payloads that are in `objects`.
    accounted: usize = 0,
    /// The most `accounted` has been.
    peak: usize = 0,
    /// The number of objects in `objects`.
    count: usize = 0,

    pub fn init(backing: std.mem.Allocator, options: Options) Heap {
        return .{ .backing = backing, .options = options };
    }

    /// Frees every object, reachable or not.
    pub fn deinit(self: *Heap) void {
        var it = self.objects;
        while (it) |header| {
            it = header.next;
            self.free(header);
        }
        self.objects = null;
        self.accounted = 0;
        self.count = 0;
    }

    /// A new object holding `value`.
    ///
    /// A frame has a payload, so it is made by `createFrame`.
    pub fn create(self: *Heap, comptime T: type, value: T) Error!*T {
        comptime std.debug.assert(T != Frame);
        try self.reserve(cellBytes(T));
        const cell = try self.backing.create(Cell(T));
        cell.value = value;
        self.link(T, cell, cellBytes(T));
        return &cell.value;
    }

    /// A new frame of `size` slots, all `uninitialized`, behind `parent`.
    ///
    /// The slots are allocated first and the cell second. If the cell cannot be
    /// allocated the slots are given back, so a failed call leaves the heap as
    /// it was. That is the unit of the rollback: one call.
    pub fn createFrame(self: *Heap, size: usize, parent: ?*Frame) Error!*Frame {
        const payload = std.math.mul(usize, size, @sizeOf(Value)) catch return error.HeapLimit;
        const bytes = std.math.add(usize, cellBytes(Frame), payload) catch return error.HeapLimit;
        try self.reserve(bytes);
        const values = try self.backing.alloc(Value, size);
        errdefer self.backing.free(values);
        const cell = try self.backing.create(Cell(Frame));
        @memset(values, Value.uninitialized_value);
        cell.value = .{ .values = values, .parent = parent };
        self.link(Frame, cell, bytes);
        return &cell.value;
    }

    /// A new pair of `car` and `cdr`.
    pub fn cons(self: *Heap, car: Value, cdr: Value) Error!Value {
        const pair = try self.create(Pair, .{ .car = car, .cdr = cdr });
        return .{ .pair = pair };
    }

    /// Fails with `HeapLimit` when `bytes` more would pass the limit.
    fn reserve(self: *const Heap, bytes: usize) error{HeapLimit}!void {
        const total = std.math.add(usize, self.accounted, bytes) catch return error.HeapLimit;
        if (total > self.options.limit) return error.HeapLimit;
    }

    fn link(self: *Heap, comptime T: type, cell: *Cell(T), bytes: usize) void {
        cell.header = .{ .next = self.objects, .kind = kindOf(T) };
        self.objects = &cell.header;
        self.accounted += bytes;
        self.count += 1;
        if (self.accounted > self.peak) self.peak = self.accounted;
    }

    /// Gives an object and its payload back to the allocator, and takes them
    /// off the account. The header must already be off the list.
    fn free(self: *Heap, header: *Header) void {
        inline for (object_types, 0..) |T, i| {
            if (header.kind == i) {
                const cell: *Cell(T) = @fieldParentPtr("header", header);
                self.accounted -= cellBytes(T) + payloadBytes(T, &cell.value);
                self.count -= 1;
                if (T == Frame) self.backing.free(cell.value.values);
                self.backing.destroy(cell);
                return;
            }
        }
        unreachable;
    }
};

test {
    std.testing.refAllDecls(@This());
}

test "an allocation adds its bytes to the account, and the peak follows it" {
    var heap: Heap = .init(std.testing.allocator, .{});
    defer heap.deinit();
    try std.testing.expectEqual(0, heap.accounted);
    const a = try heap.create(Args, .{ .value = .fromFixnum(1), .next = null });
    try std.testing.expectEqual(cellBytes(Args), heap.accounted);
    try std.testing.expectEqual(1, a.value.asFixnum().?);
    _ = try heap.cons(.fromFixnum(1), .empty_list_value);
    try std.testing.expectEqual(cellBytes(Args) + cellBytes(Pair), heap.accounted);
    try std.testing.expectEqual(heap.accounted, heap.peak);
    try std.testing.expectEqual(2, heap.count);
}

test "a frame accounts for its slots as well as its cell, and starts with them uninitialized" {
    var heap: Heap = .init(std.testing.allocator, .{});
    defer heap.deinit();
    const frame = try heap.createFrame(3, null);
    try std.testing.expectEqual(cellBytes(Frame) + 3 * @sizeOf(Value), heap.accounted);
    try std.testing.expectEqual(3, frame.values.len);
    for (frame.values) |v| try std.testing.expectEqual(value_mod.Kind.uninitialized, v.kind());
    const inner = try heap.createFrame(0, frame);
    try std.testing.expectEqual(frame, inner.parent.?);
    try std.testing.expectEqual(0, inner.values.len);
}

test "an allocation past the limit fails and leaves the account as it was" {
    var heap: Heap = .init(std.testing.allocator, .{ .limit = cellBytes(Pair) * 2 });
    defer heap.deinit();
    _ = try heap.cons(.fromFixnum(1), .fromFixnum(2));
    // The limit is on the sum, and reaching it exactly is allowed.
    _ = try heap.cons(.fromFixnum(3), .fromFixnum(4));
    try std.testing.expectEqual(cellBytes(Pair) * 2, heap.accounted);
    try std.testing.expectError(error.HeapLimit, heap.cons(.fromFixnum(5), .fromFixnum(6)));
    try std.testing.expectEqual(cellBytes(Pair) * 2, heap.accounted);
    try std.testing.expectEqual(2, heap.count);
}

test "a frame is held to the limit by the size of its slots too" {
    var heap: Heap = .init(std.testing.allocator, .{ .limit = cellBytes(Frame) + 2 * @sizeOf(Value) });
    defer heap.deinit();
    try std.testing.expectError(error.HeapLimit, heap.createFrame(3, null));
    try std.testing.expectEqual(0, heap.accounted);
    _ = try heap.createFrame(2, null);
    try std.testing.expectError(error.HeapLimit, heap.createFrame(0, null));
}

test "a frame too large to account for is refused, not wrapped around" {
    var heap: Heap = .init(std.testing.allocator, .{});
    defer heap.deinit();
    try std.testing.expectError(error.HeapLimit, heap.createFrame(std.math.maxInt(usize), null));
    try std.testing.expectError(error.HeapLimit, heap.createFrame(std.math.maxInt(usize) / @sizeOf(Value), null));
    try std.testing.expectEqual(0, heap.accounted);
}

test "when the cell cannot be allocated the slots are given back" {
    // The first allocation (the slots) succeeds and the second (the cell) fails.
    var failing: std.testing.FailingAllocator = .init(std.testing.allocator, .{ .fail_index = 1 });
    var heap: Heap = .init(failing.allocator(), .{});
    defer heap.deinit();
    try std.testing.expectError(error.OutOfMemory, heap.createFrame(4, null));
    try std.testing.expectEqual(0, heap.accounted);
    try std.testing.expectEqual(0, heap.count);
    try std.testing.expect(heap.objects == null);
    // The slots were allocated and given back: nothing is left for the leak check.
    try std.testing.expectEqual(1, failing.allocations);
    try std.testing.expectEqual(1, failing.deallocations);
    try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
}

test "deinit frees every object, frames and their slots included" {
    var heap: Heap = .init(std.testing.allocator, .{});
    const frame = try heap.createFrame(5, null);
    _ = try heap.create(Closure, .{ .lambda = undefined, .env = frame });
    _ = try heap.create(Kont, .{ .next = null, .env = frame, .depth = 1, .step = .{ .sequence = &.{} } });
    _ = try heap.cons(.empty_list_value, .empty_list_value);
    heap.deinit();
    try std.testing.expectEqual(0, heap.accounted);
    try std.testing.expectEqual(0, heap.count);
}
