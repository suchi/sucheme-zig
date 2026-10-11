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
const String = value_mod.String;
const Vector = value_mod.Vector;
const SymbolId = @import("symbol.zig").SymbolId;
const trace = @import("trace.zig");

/// The types that live in the heap; the index of a type here is the `kind` its
/// header records.
const object_types = value_mod.heap_types;

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
    /// How many objects the marking keeps to scan. When more are waiting the
    /// marking does not stop: it rescans the heap for them (see `Marker`). The
    /// tests set 0, so that the rescan is what runs.
    work_capacity: usize = 4096,
    /// Ask for a collection at every safe point of the start of a run, and less
    /// and less often as it goes on (see `stress_ramp`). A root a safe point
    /// forgot to name is freed at once and not by luck, so the tests run the
    /// machine this way (ADR-0031).
    stress: bool = false,
};

/// 256 MiB: far above what a program that returns needs, and far below the
/// memory of the machines the interpreter runs on.
pub const default_limit: usize = 256 * 1024 * 1024;

/// In stress mode a collection is asked for after a gap of safe points. The gap
/// is one for the first `stress_ramp` safe points, which is all of a small
/// program. After that it grows with the number that have passed, so a loop of
/// millions of steps costs thousands of collections and not millions, and it is
/// at least one safe point for each `stress_objects_per_step` objects in the
/// heap, which bounds the work a step is charged however much is live.
const stress_ramp = 4096;
const stress_objects_per_step = 16;

const Header = struct {
    next: ?*Header,
    /// An index into `object_types`.
    kind: u8,
    /// Set by the marking, cleared by the sweep.
    marked: bool,
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

/// The bytes the object owns beyond its cell: the slots of a frame, the bytes
/// of a string, the elements of a vector. The payload is allocated apart from
/// the cell and given back with it.
fn payloadBytes(comptime T: type, object: *const T) usize {
    return switch (T) {
        Frame => object.values.len * @sizeOf(Value),
        String => object.bytes.len,
        Vector => object.items.len * @sizeOf(Value),
        else => 0,
    };
}

/// What `Heap.work` is while no list has been allocated, or the allocation
/// failed: a list that holds nothing, which makes every marking a rescan.
var no_work: [0]*Header = .{};

/// The share of the limit kept free of live data: a collection that leaves more
/// than the rest live has gained too little to be worth asking for again.
const reserve_divisor = 16;

/// The account a collection is asked for at the latest. The margin to the limit
/// is what one step of the machine may allocate between two safe points.
fn softLimit(limit: usize) usize {
    return limit - limit / reserve_divisor;
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
    /// The account at which `shouldCollect` says yes.
    threshold: usize,
    /// Whether the collection that last ran left the heap too full to go on:
    /// what is live is within a margin of the limit, so the next allocation
    /// would fail whatever a collection did.
    exhausted: bool = false,
    /// How many collections have run.
    collections: usize = 0,
    /// How many times `shouldCollect` was asked since the last collection, and
    /// in all. Only stress mode counts.
    steps: usize = 0,
    total_steps: usize = 0,
    /// The marking's list of objects still to scan, kept between collections.
    work: []*Header = &no_work,

    pub fn init(backing: std.mem.Allocator, options: Options) Heap {
        return .{
            .backing = backing,
            .options = options,
            .threshold = @min(softLimit(options.limit), options.min_threshold),
        };
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
        if (self.work.len != 0) self.backing.free(self.work);
        self.work = &no_work;
    }

    /// A new object holding `value`.
    ///
    /// An object with a payload is made by the function for it: `createFrame`,
    /// `createString`, `createVector`.
    pub fn create(self: *Heap, comptime T: type, value: T) Error!*T {
        comptime std.debug.assert(T != Frame and T != String and T != Vector);
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
        const bytes = try self.reserveWithPayload(Frame, size, @sizeOf(Value));
        const values = try self.backing.alloc(Value, size);
        errdefer self.backing.free(values);
        const cell = try self.backing.create(Cell(Frame));
        @memset(values, Value.uninitialized_value);
        cell.value = .{ .values = values, .parent = parent };
        self.link(Frame, cell, bytes);
        return &cell.value;
    }

    /// A new string of a copy of `bytes`, which must be valid UTF-8 (ADR-0008).
    /// The copy is the payload: allocated first and given back if the cell
    /// cannot be allocated, as `createFrame` does.
    pub fn createString(self: *Heap, bytes: []const u8) Error!*String {
        const total = try self.reserveWithPayload(String, bytes.len, 1);
        const copy = try self.backing.dupe(u8, bytes);
        errdefer self.backing.free(copy);
        const cell = try self.backing.create(Cell(String));
        cell.value = .{ .bytes = copy };
        self.link(String, cell, total);
        return &cell.value;
    }

    /// A new vector of a copy of `items`. The copy is the payload, as the bytes
    /// of a string are.
    pub fn createVector(self: *Heap, items: []const Value) Error!*Vector {
        const total = try self.reserveWithPayload(Vector, items.len, @sizeOf(Value));
        const copy = try self.backing.dupe(Value, items);
        errdefer self.backing.free(copy);
        const cell = try self.backing.create(Cell(Vector));
        cell.value = .{ .items = copy };
        self.link(Vector, cell, total);
        return &cell.value;
    }

    /// Checks that a cell of `T` and `count` payload elements of `size` bytes
    /// fit under the limit, and returns the bytes they account for. A size that
    /// overflows is over the limit, not wrapped around.
    fn reserveWithPayload(self: *Heap, comptime T: type, count: usize, size: usize) Error!usize {
        const payload = std.math.mul(usize, count, size) catch return error.HeapLimit;
        const bytes = std.math.add(usize, cellBytes(T), payload) catch return error.HeapLimit;
        try self.reserve(bytes);
        return bytes;
    }

    /// A new pair of `car` and `cdr`.
    pub fn cons(self: *Heap, car: Value, cdr: Value) Error!Value {
        const pair = try self.create(Pair, .{ .car = car, .cdr = cdr });
        return .{ .pair = pair };
    }

    /// Whether a collection is due. The machine asks between two steps.
    pub fn shouldCollect(self: *Heap) bool {
        if (self.options.stress) {
            self.steps +|= 1;
            self.total_steps +|= 1;
            const gap = if (self.total_steps <= stress_ramp) 1 else @max(
                self.total_steps / stress_ramp,
                self.count / stress_objects_per_step,
            );
            if (self.steps >= gap) return true;
        }
        return self.accounted >= self.threshold;
    }

    /// Frees every object that cannot be reached from `roots`.
    ///
    /// `roots.mark(marker)` tells the marker where the program can start from.
    /// Nothing else is a root, so this must be called only where no value is
    /// held anywhere but in what `roots` names: between two steps of the machine
    /// (ADR-0031).
    pub fn collect(self: *Heap, roots: anytype) void {
        self.ensureWork();
        var marker: Marker = .{ .heap = self, .work = self.work };
        roots.mark(&marker);
        marker.finish();
        self.sweep();
        self.collections += 1;
        self.steps = 0;
        const live = self.accounted;
        const soft = softLimit(self.options.limit);
        self.threshold = @min(soft, @max(self.options.min_threshold, live *| 2));
        self.exhausted = live +| (self.options.limit / reserve_divisor) > soft;
    }

    /// Makes the marking's list the size the options ask for. If memory for it
    /// cannot be had the list stays empty, and the marking rescans instead of
    /// stopping.
    fn ensureWork(self: *Heap) void {
        if (self.work.len == self.options.work_capacity) return;
        if (self.work.len != 0) self.backing.free(self.work);
        self.work = &no_work;
        if (self.options.work_capacity == 0) return;
        self.work = self.backing.alloc(*Header, self.options.work_capacity) catch &no_work;
    }

    /// Frees the objects the marking did not reach, and clears the mark of the
    /// rest.
    fn sweep(self: *Heap) void {
        var slot: *?*Header = &self.objects;
        while (slot.*) |header| {
            if (header.marked) {
                header.marked = false;
                slot = &header.next;
            } else {
                slot.* = header.next;
                self.free(header);
            }
        }
    }

    /// Fails with `HeapLimit` when `bytes` more would pass the limit.
    fn reserve(self: *const Heap, bytes: usize) error{HeapLimit}!void {
        const total = std.math.add(usize, self.accounted, bytes) catch return error.HeapLimit;
        if (total > self.options.limit) return error.HeapLimit;
    }

    fn link(self: *Heap, comptime T: type, cell: *Cell(T), bytes: usize) void {
        cell.header = .{ .next = self.objects, .kind = kindOf(T), .marked = false };
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
                const cell: *Cell(T) = @alignCast(@fieldParentPtr("header", header));
                self.accounted -= cellBytes(T) + payloadBytes(T, &cell.value);
                self.count -= 1;
                switch (T) {
                    Frame => self.backing.free(cell.value.values),
                    String => self.backing.free(cell.value.bytes),
                    Vector => self.backing.free(cell.value.items),
                    else => {},
                }
                self.backing.destroy(cell);
                return;
            }
        }
        unreachable;
    }
};

/// The marking of one collection. `roots` hands it the values the program can
/// start from, and `finish` follows them to everything they reach.
///
/// Reaching an object marks it and, if there is room, puts it on a list to scan
/// later; scanning it reaches what it refers to. The list has the capacity the
/// options give. When an object is reached and the list is full it is marked and
/// the marking only notes that it was lost, and `finish` goes over every marked
/// object in the heap again until a pass loses nothing. A marked object is
/// scanned once the list has room, or by the pass, so none is missed, and the
/// size of the list changes how long marking takes and not what it marks.
pub const Marker = struct {
    heap: *Heap,
    work: []*Header,
    len: usize = 0,
    /// An object was marked and not put on the list.
    lost: bool = false,

    /// Marks what `v` refers to.
    pub fn value(self: *Marker, v: Value) void {
        trace.interpreter.walk(self, Value, v);
    }

    /// Marks `f` and, through it, what it refers to.
    pub fn frame(self: *Marker, f: ?*Frame) void {
        trace.interpreter.walk(self, ?*Frame, f);
    }

    /// Marks `k` and, through it, what it refers to.
    pub fn kont(self: *Marker, k: ?*const Kont) void {
        trace.interpreter.walk(self, ?*const Kont, k);
    }

    /// What `trace.walk` calls for a heap object.
    pub fn object(self: *Marker, comptime T: type, pointer: *const T) void {
        const cell: *Cell(T) = @constCast(@fieldParentPtr("value", pointer));
        const header = &cell.header;
        if (header.marked) return;
        header.marked = true;
        if (self.len < self.work.len) {
            self.work[self.len] = header;
            self.len += 1;
        } else {
            self.lost = true;
        }
    }

    /// What `trace.walk` calls for a symbol id. The symbol table is not weak
    /// yet, so there is nothing to record.
    pub fn symbol(_: *Marker, _: SymbolId) void {}

    fn finish(self: *Marker) void {
        self.drain();
        while (self.lost) {
            self.lost = false;
            var it = self.heap.objects;
            while (it) |header| : (it = header.next) {
                if (header.marked) self.scan(header);
            }
            self.drain();
        }
    }

    fn drain(self: *Marker) void {
        while (self.len > 0) {
            self.len -= 1;
            self.scan(self.work[self.len]);
        }
    }

    fn scan(self: *Marker, header: *Header) void {
        inline for (object_types, 0..) |T, i| {
            if (header.kind == i) {
                const cell: *Cell(T) = @alignCast(@fieldParentPtr("header", header));
                trace.interpreter.children(self, T, &cell.value);
                return;
            }
        }
        unreachable;
    }
};

test {
    std.testing.refAllDecls(@This());
    _ = @import("trace.zig");
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
    // A count whose size wraps around to a small one must not pass for it.
    try std.testing.expectError(error.HeapLimit, heap.createFrame(std.math.maxInt(usize) / @sizeOf(Value) + 2, null));
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

test "a string accounts for its bytes as well as its cell, and keeps a copy of them" {
    var heap: Heap = .init(std.testing.allocator, .{});
    defer heap.deinit();
    var source = [_]u8{ 'a', 'b', 'c' };
    const s = try heap.createString(&source);
    source[0] = 'x';
    try std.testing.expectEqualStrings("abc", s.bytes);
    try std.testing.expectEqual(cellBytes(String) + 3, heap.accounted);
    const empty = try heap.createString("");
    try std.testing.expectEqual(0, empty.bytes.len);
    try std.testing.expectEqual(cellBytes(String) * 2 + 3, heap.accounted);
}

test "a vector accounts for its elements as well as its cell, and keeps a copy of them" {
    var heap: Heap = .init(std.testing.allocator, .{});
    defer heap.deinit();
    var source = [_]Value{ .fromFixnum(1), .fromFixnum(2) };
    const v = try heap.createVector(&source);
    source[0] = .fromFixnum(9);
    try std.testing.expectEqual(1, v.items[0].asFixnum().?);
    try std.testing.expectEqual(2, v.items.len);
    try std.testing.expectEqual(cellBytes(Vector) + 2 * @sizeOf(Value), heap.accounted);
    const empty = try heap.createVector(&.{});
    try std.testing.expectEqual(0, empty.items.len);
}

test "a string and a vector are held to the limit by their payload" {
    var heap: Heap = .init(std.testing.allocator, .{ .limit = cellBytes(String) + 4 });
    defer heap.deinit();
    try std.testing.expectError(error.HeapLimit, heap.createString("hello"));
    try std.testing.expectEqual(0, heap.accounted);
    _ = try heap.createString("four");
    try std.testing.expectError(error.HeapLimit, heap.createVector(&.{}));
    try std.testing.expectError(error.HeapLimit, heap.createString(""));
    var small: Heap = .init(std.testing.allocator, .{ .limit = cellBytes(Vector) + @sizeOf(Value) });
    defer small.deinit();
    try std.testing.expectError(error.HeapLimit, small.createVector(&.{ .fromFixnum(1), .fromFixnum(2) }));
    _ = try small.createVector(&.{.fromFixnum(1)});
}

test "when the cell cannot be allocated the copy of a string or a vector is given back" {
    var failing: std.testing.FailingAllocator = .init(std.testing.allocator, .{ .fail_index = 1 });
    var heap: Heap = .init(failing.allocator(), .{});
    defer heap.deinit();
    try std.testing.expectError(error.OutOfMemory, heap.createString("abc"));
    try std.testing.expectEqual(0, heap.accounted);
    try std.testing.expectEqual(1, failing.deallocations);
    var failing2: std.testing.FailingAllocator = .init(std.testing.allocator, .{ .fail_index = 1 });
    var heap2: Heap = .init(failing2.allocator(), .{});
    defer heap2.deinit();
    try std.testing.expectError(error.OutOfMemory, heap2.createVector(&.{.fromFixnum(1)}));
    try std.testing.expectEqual(0, heap2.accounted);
    try std.testing.expectEqual(1, failing2.deallocations);
    try std.testing.expectEqual(failing2.allocated_bytes, failing2.freed_bytes);
}

test "a collection frees a string and a vector the roots do not reach, payload included" {
    var heap: Heap = .init(std.testing.allocator, .{});
    defer heap.deinit();
    const kept = try heap.createVector(&.{ .fromString(try heap.createString("kept")), .fromFixnum(1) });
    _ = try heap.createString("dropped");
    _ = try heap.createVector(&.{.fromFixnum(2)});
    const before = heap.accounted;
    heap.collect(TestRoots{ .values = &.{.fromVector(kept)} });
    try std.testing.expect(heap.accounted < before);
    try std.testing.expectEqual(2, heap.count);
    try std.testing.expectEqual(cellBytes(Vector) + 2 * @sizeOf(Value) + cellBytes(String) + 4, heap.accounted);
    try std.testing.expectEqualStrings("kept", kept.items[0].asString().?.bytes);
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

/// Roots for a test: values, a frame and a continuation held by the test.
const TestRoots = struct {
    values: []const Value = &.{},
    frame: ?*Frame = null,
    kont: ?*const Kont = null,

    pub fn mark(self: TestRoots, marker: *Marker) void {
        for (self.values) |v| marker.value(v);
        marker.frame(self.frame);
        marker.kont(self.kont);
    }
};

test "a collection frees what the roots do not reach and keeps what they do" {
    var heap: Heap = .init(std.testing.allocator, .{});
    defer heap.deinit();
    const kept = try heap.cons(.fromFixnum(1), .empty_list_value);
    _ = try heap.cons(.fromFixnum(2), .empty_list_value);
    _ = try heap.cons(.fromFixnum(3), .empty_list_value);
    try std.testing.expectEqual(3, heap.count);
    heap.collect(TestRoots{ .values = &.{kept} });
    try std.testing.expectEqual(1, heap.count);
    try std.testing.expectEqual(cellBytes(Pair), heap.accounted);
    try std.testing.expectEqual(1, kept.asPair().?.car.asFixnum().?);
    try std.testing.expectEqual(1, heap.collections);
}

test "what a root reaches through pairs, closures, frames and continuations survives" {
    var heap: Heap = .init(std.testing.allocator, .{});
    defer heap.deinit();
    const deep = try heap.cons(.fromFixnum(7), .empty_list_value);
    const frame = try heap.createFrame(2, null);
    frame.values[0] = deep;
    const closure = try heap.create(Closure, .{ .lambda = undefined, .env = frame });
    const arg = try heap.create(Args, .{ .value = .{ .closure = closure }, .next = null });
    const outer = try heap.create(Kont, .{ .next = null, .env = null, .depth = 1, .step = .{ .sequence = &.{} } });
    const top = try heap.create(Kont, .{ .next = outer, .env = frame, .depth = 2, .step = .{ .call = .{ .call = undefined, .args = arg, .received = 1 } } });
    _ = try heap.cons(.fromFixnum(0), .empty_list_value);
    const garbage_frame = try heap.createFrame(100, null);
    _ = garbage_frame;
    const before = heap.count;
    // Only the continuation is a root: the rest is reached through it.
    heap.collect(TestRoots{ .kont = top });
    try std.testing.expectEqual(before - 2, heap.count);
    try std.testing.expectEqual(7, frame.values[0].asPair().?.car.asFixnum().?);
    try std.testing.expectEqual(frame, closure.env.?);
    try std.testing.expectEqual(arg, top.step.call.args.?);
    try std.testing.expectEqual(cellBytes(Pair) + cellBytes(Frame) + 2 * @sizeOf(Value) + cellBytes(Closure) +
        cellBytes(Args) + 2 * cellBytes(Kont), heap.accounted);
}

test "an unreachable frame takes its slots off the account with it" {
    var heap: Heap = .init(std.testing.allocator, .{});
    defer heap.deinit();
    const kept = try heap.cons(.fromFixnum(1), .fromFixnum(2));
    _ = try heap.createFrame(100, null);
    try std.testing.expectEqual(cellBytes(Pair) + cellBytes(Frame) + 100 * @sizeOf(Value), heap.accounted);
    heap.collect(TestRoots{ .values = &.{kept} });
    try std.testing.expectEqual(cellBytes(Pair), heap.accounted);
}

test "a cycle is marked once, and freed when nothing reaches it" {
    var heap: Heap = .init(std.testing.allocator, .{});
    defer heap.deinit();
    const a = try heap.cons(.fromFixnum(1), .empty_list_value);
    const b = try heap.cons(.fromFixnum(2), a);
    a.asPair().?.cdr = b;
    heap.collect(TestRoots{ .values = &.{a} });
    try std.testing.expectEqual(2, heap.count);
    heap.collect(TestRoots{});
    try std.testing.expectEqual(0, heap.count);
    try std.testing.expectEqual(0, heap.accounted);
}

test "the mark is cleared, so a second collection can free what the first kept" {
    var heap: Heap = .init(std.testing.allocator, .{});
    defer heap.deinit();
    const a = try heap.cons(.fromFixnum(1), .empty_list_value);
    heap.collect(TestRoots{ .values = &.{a} });
    try std.testing.expectEqual(1, heap.count);
    heap.collect(TestRoots{ .values = &.{a} });
    try std.testing.expectEqual(1, heap.count);
    heap.collect(TestRoots{});
    try std.testing.expectEqual(0, heap.count);
}

test "a list is marked whole whatever the capacity of the marking list, and whichever way its links run" {
    for ([_]usize{ 0, 1, 3, 4096 }) |capacity| {
        var heap: Heap = .init(std.testing.allocator, .{ .work_capacity = capacity });
        defer heap.deinit();
        // Links to older objects: each pair is made pointing at the one before.
        var older: Value = .empty_list_value;
        for (0..200) |i| older = try heap.cons(.fromFixnum(@intCast(i)), older);
        // Links to newer objects: the pairs are made first and joined after, so the
        // head is the oldest and every link runs to a newer pair.
        var cells: [200]Value = undefined;
        for (&cells, 0..) |*cell, i| cell.* = try heap.cons(.fromFixnum(@intCast(1000 + i)), .empty_list_value);
        for (cells[0..199], cells[1..]) |from, to| from.asPair().?.cdr = to;
        for (0..50) |_| _ = try heap.cons(.fromFixnum(-1), .empty_list_value);
        heap.collect(TestRoots{ .values = &.{ older, cells[0] } });
        try std.testing.expectEqual(400, heap.count);
        var n: usize = 0;
        var it = cells[0];
        while (it.asPair()) |p| : (it = p.cdr) n += 1;
        try std.testing.expectEqual(200, n);
        // And the second collection, with a fresh start, does the same.
        heap.collect(TestRoots{ .values = &.{ older, cells[0] } });
        try std.testing.expectEqual(400, heap.count);
    }
}

test "the threshold follows what is live, within the limit" {
    var heap: Heap = .init(std.testing.allocator, .{ .limit = 1600, .min_threshold = 160 });
    defer heap.deinit();
    // The soft limit is the limit less a sixteenth of it.
    try std.testing.expectEqual(1500, softLimit(1600));
    try std.testing.expectEqual(160, heap.threshold);
    try std.testing.expect(!heap.shouldCollect());
    // Make the account reach the threshold.
    var keep: Value = .empty_list_value;
    while (!heap.shouldCollect()) keep = try heap.cons(.fromFixnum(1), keep);
    heap.collect(TestRoots{ .values = &.{keep} });
    // Everything was live: twice that, since it is more than the least.
    try std.testing.expectEqual(@min(1500, heap.accounted * 2), heap.threshold);
    try std.testing.expect(!heap.shouldCollect());
    try std.testing.expect(!heap.exhausted);
    // With nothing live, the threshold falls back to the least.
    heap.collect(TestRoots{});
    try std.testing.expectEqual(160, heap.threshold);
    try std.testing.expectEqual(0, heap.accounted);
}

test "a collection that leaves the heap nearly full says it is exhausted" {
    var heap: Heap = .init(std.testing.allocator, .{ .limit = 1600, .min_threshold = 160 });
    defer heap.deinit();
    var keep: Value = .empty_list_value;
    while (true) keep = heap.cons(.fromFixnum(1), keep) catch break;
    // Past the soft limit, with everything live.
    try std.testing.expect(heap.shouldCollect());
    heap.collect(TestRoots{ .values = &.{keep} });
    try std.testing.expect(heap.exhausted);
    // Once what was live is dropped the heap has room again.
    heap.collect(TestRoots{});
    try std.testing.expect(!heap.exhausted);
}

test "the list the marking keeps is made to the size the options ask for" {
    var heap: Heap = .init(std.testing.allocator, .{ .work_capacity = 8 });
    defer heap.deinit();
    heap.collect(TestRoots{});
    try std.testing.expectEqual(8, heap.work.len);
    heap.options.work_capacity = 0;
    heap.collect(TestRoots{});
    try std.testing.expectEqual(0, heap.work.len);
}

test "when the marking list cannot be allocated the marking rescans and still finishes" {
    var failing: std.testing.FailingAllocator = .init(std.testing.allocator, .{ .fail_index = 0 });
    // Objects come from the testing allocator directly; only the list comes from
    // the failing one, which fails its first allocation.
    var heap: Heap = .init(std.testing.allocator, .{ .work_capacity = 64 });
    defer heap.deinit();
    const a = try heap.cons(.fromFixnum(1), .empty_list_value);
    const b = try heap.cons(.fromFixnum(2), a);
    _ = try heap.cons(.fromFixnum(3), .empty_list_value);
    heap.backing = failing.allocator();
    heap.collect(TestRoots{ .values = &.{b} });
    heap.backing = std.testing.allocator;
    try std.testing.expectEqual(0, heap.work.len);
    try std.testing.expectEqual(2, heap.count);
}

test "in stress mode every safe point of a short run collects, and the gap grows as the run goes on" {
    var heap: Heap = .init(std.testing.allocator, .{ .stress = true, .min_threshold = 1 << 30 });
    defer heap.deinit();
    // A short run: every one of the first `stress_ramp` safe points asks.
    for (0..stress_ramp) |_| {
        try std.testing.expect(heap.shouldCollect());
        heap.collect(TestRoots{});
    }
    try std.testing.expectEqual(stress_ramp, heap.collections);
    // A long run: each collection starts the count of safe points again, so the
    // number of collections is far below the number of safe points. Left
    // uncleared, the count would stay past every gap and each would collect.
    const calls = 20_000;
    for (0..calls) |_| {
        if (heap.shouldCollect()) heap.collect(TestRoots{});
    }
    const after_ramp = heap.collections - stress_ramp;
    try std.testing.expect(after_ramp < calls * 3 / 4);
    try std.testing.expect(after_ramp > calls / 4);
}
