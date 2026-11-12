//! The GC heap: where the objects of a running program live
//! (docs/design/runtime.md, ADR-0003).
//!
//! すべてのオブジェクトは `Cell` である。ヘッダの後ろにオブジェクト本体が続く。
//! セルは、大きさの階級ごとに、64 KiB のチャンクから切り出される。スイープは、チャンクを
//! メモリの順に走査する(連結したリストをたどると、散らばったメモリの待ちが時間を決める。
//! docs/plans/0029-heap-limit-slow-exhaustion.md)。解放したセルは、階級ごとの空きリストに
//! つながれて、次の確保で再利用される。ヒープは、
//! セルと、セルが所有するペイロードのバイト数を計上し、計上量が上限を超える確保を
//! 拒否する。ただし送出のための確保(`Budget.raise_reserve`)は、上限を予約の分だけ
//! 超えてよい(ADR-0035)。シンボルの名前も、このヒープが持ち、計上する(`Heap.intern`)。
//! コードを置くインタプリタのアリーナは、計上の外にある。
//!
//! ヒープは確保の内部では GC を実行しない。GC は `shouldCollect` で要求され、
//! `collect` で実行される。どちらも、機械が2つのステップの間、つまり作りかけの値が
//! 存在しない場所から呼ぶ(ADR-0031)。

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
const Bytevector = value_mod.Bytevector;
const Record = value_mod.Record;
const RecordType = value_mod.RecordType;
const MultipleValues = value_mod.MultipleValues;
const Bignum = value_mod.Bignum;
const Ratnum = value_mod.Ratnum;
const Compnum = value_mod.Compnum;
const Limb = value_mod.Limb;
const Port = value_mod.Port;
const Node = value_mod.Node;
const Lambda = value_mod.Lambda;
const Parameterize = value_mod.Parameterize;
const ParameterBinding = value_mod.ParameterBinding;
const symbol = @import("symbol.zig");
const SymbolId = symbol.SymbolId;
const trace = @import("trace.zig");
const tier = @import("tier.zig");

/// The types that live in the heap; the index of a type here is the `kind` its
/// header records.
const object_types = value_mod.heap_types;

pub const Error = error{
    OutOfMemory,
    /// The allocation would take the account past what its budget allows: the
    /// limit, or for an allocation for raising, the limit and the reserve.
    HeapLimit,
};

pub const Options = struct {
    /// The most bytes the heap accounts for, except for the allocations for
    /// raising, which may pass it by `raise_reserve`.
    limit: usize = default_limit,
    /// The account at which the first collection is asked for, and the least
    /// that any later one is asked for at.
    min_threshold: usize = 1024 * 1024,
    /// How many objects the marking's list holds at first, and between collections.
    /// マークの途中で満杯になればリストを伸ばし、伸ばせなければヒープを走査し直して
    /// 拾う(`Marker` を参照)。0 はリストを使わない設定で、伸ばさない。テストは 0 に
    /// して、再走査の経路を走らせる。
    work_capacity: usize = 4096,
    /// Ask for a collection at every safe point of the start of a run, and less
    /// and less often as it goes on (see `stress_ramp`).
    /// セーフポイントが挙げ忘れたルートは、運よく残ることなく、すぐに解放される。
    /// そのためテストは機械をこのモードで動かす(ADR-0031)。
    stress: bool = false,
    /// How many bytes past the limit an allocation for raising may take (see
    /// `Budget.raise_reserve`).
    raise_reserve: usize = default_raise_reserve,
    /// The bytes of each chunk the cells are taken in. Less than one slot of the
    /// largest cell and the chunk's own fields is raised to that.
    /// ふつうは変えない。確保の失敗を仕掛けるテスト(ファジング)は、小さくして、セルの確保が
    /// 下の割り当て器に届く回数を増やす。
    chunk_bytes: usize = default_chunk_bytes,
};

/// The reserve for raising: 4 KiB.
/// 段階2のスライス 2b の初期値で、2e が測って 4 KiB のまま変えないと決めた。予約から
/// 確保する地点には、条件オブジェクトとそのメッセージ、ハンドラの呼び出し、継続の起動の
/// 巻き戻しがある。根拠は docs/design/runtime.md の送出のための予約領域の節と、
/// src/machine.zig の単体テスト(送出と、ハンドラの呼び出しと、wind 点を1つ通る脱出が
/// 予約に4回分収まること)にある。
pub const default_raise_reserve: usize = 4 * 1024;

/// What an allocation is held to.
/// 送出のための予約領域(docs/design/runtime.md)は、計上を別に持たない。予約から
/// 確保する地点に、上限を予約の分だけ超えることを許す形にしてある(ADR-0035)。
pub const Budget = enum {
    /// The limit. Every allocation but those for raising is held to it.
    limit,
    /// The limit and the reserve past it, for what raising an error must make
    /// even when the heap is at the limit: a condition and its message, the
    /// point that shifts the handler, and the call of the handler.
    /// 呼び出し側の確保地点で選ぶ。確保したものは、ほかと同じ計上に入り、同じ
    /// スイープで回収される。
    raise_reserve,
};

/// An allocator whose requests the heap counts against its limit.
///
/// 展開器の作業領域と節点を、この割り当て器を通して確保する。確保した大きさを `Heap.charge`
/// で計上し、返した大きさを `Heap.credit` で戻す。上限に収まらない要求は、`null` を返して
/// 断る。呼び出し側には `error.OutOfMemory` に見えるので、断られたことは
/// `Heap.external_refused` で見分ける。アリーナは個別の解放を受けつけないので、アリーナの
/// 下に置いた確保は、アリーナを捨てるまで計上され続ける。それが実際のメモリの使い方である。
pub const Charged = struct {
    heap: *Heap,
    backing: std.mem.Allocator,

    pub fn allocator(self: *Charged) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        } };
    }

    fn alloc(ptr: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *Charged = @ptrCast(@alignCast(ptr));
        self.heap.charge(len) catch return null;
        return self.backing.rawAlloc(len, alignment, ret_addr) orelse {
            self.heap.credit(len);
            return null;
        };
    }

    fn resize(ptr: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *Charged = @ptrCast(@alignCast(ptr));
        if (new_len > memory.len) self.heap.charge(new_len - memory.len) catch return false;
        if (!self.backing.rawResize(memory, alignment, new_len, ret_addr)) {
            if (new_len > memory.len) self.heap.credit(new_len - memory.len);
            return false;
        }
        if (new_len < memory.len) self.heap.credit(memory.len - new_len);
        return true;
    }

    fn remap(ptr: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *Charged = @ptrCast(@alignCast(ptr));
        if (new_len > memory.len) self.heap.charge(new_len - memory.len) catch return null;
        const moved = self.backing.rawRemap(memory, alignment, new_len, ret_addr) orelse {
            if (new_len > memory.len) self.heap.credit(new_len - memory.len);
            return null;
        };
        if (new_len < memory.len) self.heap.credit(memory.len - new_len);
        return moved;
    }

    fn free(ptr: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *Charged = @ptrCast(@alignCast(ptr));
        self.backing.rawFree(memory, alignment, ret_addr);
        self.heap.credit(memory.len);
    }
};

/// The most a host may ask the heap to account for: 1 GiB.
/// wasm32 の線形メモリは全体で 4 GiB であり、計上は実メモリの約半分なので、
/// ホストが 4 GiB に近い値を渡すと、上限に届く前に実メモリが尽きて trap する。
/// それを順序立ったエラー(`heap limit exceeded`)にするため、ホストの指定をここで丸める。
/// 展開の作業領域と節点も、`Charged` を通して上限に計上するので、この前提は展開の途中でも
/// 成り立つ(docs/adr/0031-gc-at-machine-step-boundaries.md の 2026-10-13 のスライス 2k
/// の追記。スライス 2l で入れた)。
pub const max_host_limit: usize = 1024 * 1024 * 1024;

/// Clamps a limit a host asked for to `max_host_limit`.
pub fn clampHostLimit(requested: usize) usize {
    return @min(requested, max_host_limit);
}

/// The options for a heap whose limit the host chose in bytes.
/// 0 は「指定なし」で、既定の上限になる。それ以外は `clampHostLimit` で丸める。
/// WebAssembly の `sucheme_init` が、ホストの `u32` をそのまま渡す。
pub fn hostOptions(requested: u32) Options {
    if (requested == 0) return .{};
    return .{ .limit = clampHostLimit(requested) };
}

test "work charged against the limit leaves less room for the heap, and gives it back" {
    var heap: Heap = .init(std.testing.allocator, .{ .limit = cellBytes(Pair) * 4 });
    defer heap.deinit();
    heap.external_enforced = true;
    var charged: Charged = .{ .heap = &heap, .backing = std.testing.allocator };
    const a = charged.allocator();
    const held = try a.alloc(u8, cellBytes(Pair) * 2);
    try std.testing.expectEqual(cellBytes(Pair) * 2, heap.external);
    _ = try heap.cons(.empty_list_value, .empty_list_value);
    _ = try heap.cons(.empty_list_value, .empty_list_value);
    try std.testing.expectError(error.HeapLimit, heap.cons(.empty_list_value, .empty_list_value));
    a.free(held);
    try std.testing.expectEqual(0, heap.external);
    _ = try heap.cons(.empty_list_value, .empty_list_value);
}

test "work is counted before a macro is applied, but is not held to the limit" {
    var heap: Heap = .init(std.testing.allocator, .{ .limit = cellBytes(Pair) * 2 });
    defer heap.deinit();
    var charged: Charged = .{ .heap = &heap, .backing = std.testing.allocator };
    const a = charged.allocator();
    const big = try a.alloc(u8, cellBytes(Pair) * 8);
    defer a.free(big);
    try std.testing.expectEqual(cellBytes(Pair) * 8, heap.external);
    try std.testing.expect(!heap.external_refused);
    // 数えるだけで、ヒープの確保は、いままでの上限で決まる。
    _ = try heap.cons(.empty_list_value, .empty_list_value);
    _ = try heap.cons(.empty_list_value, .empty_list_value);
    try std.testing.expectError(error.HeapLimit, heap.cons(.empty_list_value, .empty_list_value));
    // 検査を始めると、すでに数えた分が、上限に入る。
    heap.external_enforced = true;
    try std.testing.expectError(error.OutOfMemory, a.alloc(u8, 1));
    try std.testing.expect(heap.external_refused);
}

test "a request past the limit is refused and noted, and the account stays as it was" {
    var heap: Heap = .init(std.testing.allocator, .{ .limit = 1024 });
    defer heap.deinit();
    heap.external_enforced = true;
    var charged: Charged = .{ .heap = &heap, .backing = std.testing.allocator };
    const a = charged.allocator();
    const small = try a.alloc(u8, 1000);
    defer a.free(small);
    try std.testing.expect(!heap.external_refused);
    try std.testing.expectError(error.OutOfMemory, a.alloc(u8, 25));
    try std.testing.expect(heap.external_refused);
    try std.testing.expectEqual(1000, heap.external);
    // ちょうど収まる要求は通る。
    const rest = try a.alloc(u8, 24);
    a.free(rest);
    try std.testing.expectEqual(1000, heap.external);
}

test "growing and shrinking a charged block charge only the difference" {
    var heap: Heap = .init(std.testing.allocator, .{ .limit = 1024 });
    defer heap.deinit();
    heap.external_enforced = true;
    var charged: Charged = .{ .heap = &heap, .backing = std.testing.allocator };
    const a = charged.allocator();
    var block = try a.alloc(u8, 100);
    block = try a.realloc(block, 400);
    try std.testing.expectEqual(400, heap.external);
    block = try a.realloc(block, 50);
    try std.testing.expectEqual(50, heap.external);
    try std.testing.expectError(error.OutOfMemory, a.realloc(block, 2000));
    try std.testing.expectEqual(50, heap.external);
    try std.testing.expect(heap.external_refused);
    a.free(block);
    try std.testing.expectEqual(0, heap.external);
}

test "a request the backing refuses is not left charged" {
    var heap: Heap = .init(std.testing.allocator, .{ .limit = 1024 });
    defer heap.deinit();
    heap.external_enforced = true;
    var failing: std.testing.FailingAllocator = .init(std.testing.allocator, .{ .fail_index = 0 });
    var charged: Charged = .{ .heap = &heap, .backing = failing.allocator() };
    try std.testing.expectError(error.OutOfMemory, charged.allocator().alloc(u8, 100));
    try std.testing.expectEqual(0, heap.external);
    try std.testing.expect(!heap.external_refused);
}

test "the resident allocator counts against the limit at all times, and gives back what is freed" {
    var heap: Heap = .init(std.testing.allocator, .{ .limit = cellBytes(Pair) * 4 });
    defer heap.deinit();
    const a = heap.residentAllocator();
    // 展開の計上と違い、検査を始める印が無くても、上限に入る。
    try std.testing.expect(!heap.external_enforced);
    // 伸ばすと差分だけ、縮めると差分を戻す。
    var block = try a.alloc(u8, cellBytes(Pair) * 3);
    block = try a.realloc(block, cellBytes(Pair) * 2);
    try std.testing.expectEqual(cellBytes(Pair) * 2, heap.resident);
    try std.testing.expectEqual(cellBytes(Pair) * 2, heap.held());
    try std.testing.expectEqual(0, heap.external);
    _ = try heap.cons(.empty_list_value, .empty_list_value);
    _ = try heap.cons(.empty_list_value, .empty_list_value);
    try std.testing.expectError(error.HeapLimit, heap.cons(.empty_list_value, .empty_list_value));
    // 上限を超える要求は断り、断ったことを残す。計上は変わらない。
    try std.testing.expect(!heap.external_refused);
    try std.testing.expectError(error.OutOfMemory, a.alloc(u8, 1));
    try std.testing.expect(heap.external_refused);
    try std.testing.expectError(error.OutOfMemory, a.realloc(block, cellBytes(Pair) * 3));
    try std.testing.expectEqual(cellBytes(Pair) * 2, heap.resident);
    a.free(block);
    try std.testing.expectEqual(0, heap.resident);
    _ = try heap.cons(.empty_list_value, .empty_list_value);
}

test "a resident request the backing refuses is not left counted" {
    // 確保は1回目だけ通し、伸ばす要求はすべて断る下の割り当て器。
    var failing: std.testing.FailingAllocator = .init(std.testing.allocator, .{ .fail_index = 1, .resize_fail_index = 0 });
    var heap: Heap = .init(failing.allocator(), .{ .limit = 1 << 20 });
    defer heap.deinit();
    const a = heap.residentAllocator();
    const block = try a.alloc(u8, 100);
    defer a.free(block);
    try std.testing.expectEqual(100, heap.resident);
    // 伸ばす要求は、その場で伸ばせず(resize)、移して伸ばせず(remap)、新しく取れない。
    try std.testing.expect(!a.resize(block, 200));
    try std.testing.expectEqual(100, heap.resident);
    try std.testing.expectError(error.OutOfMemory, a.realloc(block, 300));
    try std.testing.expectEqual(100, heap.resident);
    try std.testing.expectError(error.OutOfMemory, a.alloc(u8, 10));
    try std.testing.expectEqual(100, heap.resident);
    // 下の割り当て器が断ったのであって、上限が断ったのではない。
    try std.testing.expect(!heap.external_refused);
}

test "resizing a resident block in place counts the difference, and a growth past the limit is refused" {
    // 最後の確保をその場で伸び縮みできる割り当て器を下に置き、`resize` の経路を通す
    // (`realloc` は先に `remap` を試すので、この経路を通らない)。
    var buffer: [1024]u8 = undefined;
    var fixed: std.heap.FixedBufferAllocator = .init(&buffer);
    var heap: Heap = .init(fixed.allocator(), .{ .limit = 256 });
    defer heap.deinit();
    const a = heap.residentAllocator();
    var block = try a.alloc(u8, 100);
    try std.testing.expect(a.resize(block, 200));
    block = block.ptr[0..200];
    try std.testing.expectEqual(200, heap.resident);
    try std.testing.expect(a.resize(block, 50));
    block = block.ptr[0..50];
    try std.testing.expectEqual(50, heap.resident);
    // 上限を超える伸び方は、下の割り当て器に頼む前に断る。計上は変わらない。
    try std.testing.expect(!heap.external_refused);
    try std.testing.expect(!a.resize(block, 300));
    try std.testing.expect(heap.external_refused);
    try std.testing.expectEqual(50, heap.resident);
    a.free(block);
    try std.testing.expectEqual(0, heap.resident);
}

/// An allocator that counts the bytes it holds, on top of `std.testing.allocator`,
/// which reports what is left at the end of the test.
const CountingAllocator = struct {
    live: usize = 0,
    allocations: usize = 0,

    fn allocator(self: *CountingAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }

    fn alloc(ptr: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ptr));
        const memory = std.testing.allocator.rawAlloc(len, alignment, ret_addr) orelse return null;
        self.live += len;
        self.allocations += 1;
        return memory;
    }

    fn resize(ptr: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(ptr));
        if (!std.testing.allocator.rawResize(memory, alignment, new_len, ret_addr)) return false;
        self.live = self.live - memory.len + new_len;
        return true;
    }

    fn remap(ptr: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ptr));
        const moved = std.testing.allocator.rawRemap(memory, alignment, new_len, ret_addr) orelse return null;
        self.live = self.live - memory.len + new_len;
        return moved;
    }

    fn free(ptr: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(ptr));
        std.testing.allocator.rawFree(memory, alignment, ret_addr);
        self.live -= memory.len;
    }
};

test "the size from which resident requests go to the large allocator is 4096" {
    // Why: 他の単体テストは、境目をシンボルで指す。数値を替えても通るので、ここで固定する。
    // 効き目は、境界 4096 バイトと 32768 バイトの実測に乗っている(`large_resident_bytes` の説明)。
    try std.testing.expectEqual(@as(usize, 4096), large_resident_bytes);
}

test "a resident request of the large size goes to the large allocator, and a smaller one stays on the backing" {
    // Why: `smp_allocator` は、解放した領域をスロットごとの空きリストに積み、別のスロットに
    // 積んだ領域を再利用しないことがある。大きな表を作っては捨てる繰り返しで、常駐のメモリが
    // 伸びた(docs/plans/0019-phase5-ports-and-io.md の「環境の表の GC の圧力の割り当て」)。
    var small: CountingAllocator = .{};
    var large: CountingAllocator = .{};
    var heap: Heap = .init(small.allocator(), .{ .limit = 1 << 20 });
    defer heap.deinit();
    heap.large = large.allocator();
    const a = heap.residentAllocator();
    const below = try a.alloc(u8, large_resident_bytes - 1);
    try std.testing.expectEqual(large_resident_bytes - 1, small.live);
    try std.testing.expectEqual(0, large.live);
    const at = try a.alloc(u8, large_resident_bytes);
    try std.testing.expectEqual(large_resident_bytes - 1, small.live);
    try std.testing.expectEqual(large_resident_bytes, large.live);
    // どちらの経路でも、計上は同じに数え、解放は取った経路に返す。
    try std.testing.expectEqual(large_resident_bytes * 2 - 1, heap.resident);
    a.free(at);
    a.free(below);
    try std.testing.expectEqual(0, small.live);
    try std.testing.expectEqual(0, large.live);
    try std.testing.expectEqual(0, heap.resident);
}

test "a resident block that grows past the large size moves to the large allocator, and back when it shrinks" {
    var small: CountingAllocator = .{};
    var large: CountingAllocator = .{};
    var heap: Heap = .init(small.allocator(), .{ .limit = 1 << 20 });
    defer heap.deinit();
    heap.large = large.allocator();
    const a = heap.residentAllocator();
    var block = try a.alloc(u8, 100);
    // 境目をまたぐ伸縮は、その場では断る。下の割り当て器に、取った経路でない側の領域を
    // 伸ばさせない。
    try std.testing.expect(!a.resize(block, large_resident_bytes * 2));
    try std.testing.expectEqual(100, heap.resident);
    block = try a.realloc(block, large_resident_bytes * 2);
    try std.testing.expectEqual(0, small.live);
    try std.testing.expectEqual(large_resident_bytes * 2, large.live);
    try std.testing.expectEqual(large_resident_bytes * 2, heap.resident);
    // 境目の内側の伸縮は、その場で通ってよい。
    block = try a.realloc(block, large_resident_bytes * 3);
    try std.testing.expectEqual(large_resident_bytes * 3, large.live);
    block = try a.realloc(block, 200);
    try std.testing.expectEqual(200, small.live);
    try std.testing.expectEqual(0, large.live);
    try std.testing.expectEqual(200, heap.resident);
    a.free(block);
    try std.testing.expectEqual(0, small.live);
    try std.testing.expectEqual(0, heap.resident);
}

test "resizing a resident block in place never crosses the large size, even where the allocator below could" {
    // 最後の確保をその場で伸び縮みできる割り当て器を下に置く。`std.testing.allocator` は
    // 大きさの違う領域を伸ばすことを自分で断るので、境目の検査を外しても挙動が変わらない。
    var small_buffer: [16 * 1024]u8 = undefined;
    var large_buffer: [16 * 1024]u8 = undefined;
    var small: std.heap.FixedBufferAllocator = .init(&small_buffer);
    var large: std.heap.FixedBufferAllocator = .init(&large_buffer);
    var heap: Heap = .init(small.allocator(), .{ .limit = 1 << 20 });
    defer heap.deinit();
    heap.large = large.allocator();
    const a = heap.residentAllocator();
    const below = try a.alloc(u8, 100);
    // 小さい領域を境目の上まで伸ばすのは、その場で伸ばせる領域でも断る(resize も remap も)。
    try std.testing.expect(!a.resize(below, large_resident_bytes * 2));
    try std.testing.expectEqual(null, a.remap(below, large_resident_bytes * 2));
    try std.testing.expectEqual(100, heap.resident);
    // 大きい領域を境目の下まで縮めるのも、断る。取った経路でない側が解放することになる。
    const above = try a.alloc(u8, large_resident_bytes * 2);
    try std.testing.expect(!a.resize(above, 100));
    try std.testing.expectEqual(null, a.remap(above, 100));
    try std.testing.expectEqual(100 + large_resident_bytes * 2, heap.resident);
    // 境目の内側は通る。
    try std.testing.expect(a.resize(above, large_resident_bytes * 2 - 1));
    try std.testing.expectEqual(100 + large_resident_bytes * 2 - 1, heap.resident);
    a.free(above.ptr[0 .. large_resident_bytes * 2 - 1]);
    a.free(below);
    try std.testing.expectEqual(0, heap.resident);
}

test "a large resident request the large allocator refuses is not left counted" {
    var failing: std.testing.FailingAllocator = .init(std.testing.allocator, .{ .fail_index = 0 });
    var heap: Heap = .init(std.testing.allocator, .{ .limit = 1 << 20 });
    defer heap.deinit();
    heap.large = failing.allocator();
    const a = heap.residentAllocator();
    try std.testing.expectError(error.OutOfMemory, a.alloc(u8, large_resident_bytes));
    try std.testing.expectEqual(0, heap.resident);
    // 下の割り当て器が断ったのであって、上限が断ったのではない。
    try std.testing.expect(!heap.external_refused);
}

test "a collection keeps the resident account, and counts it as live" {
    var heap: Heap = .init(std.testing.allocator, .{ .limit = 1 << 20, .min_threshold = 1 });
    defer heap.deinit();
    const a = heap.residentAllocator();
    const block = try a.alloc(u8, 4096);
    defer a.free(block);
    _ = try heap.cons(.empty_list_value, .empty_list_value);
    heap.collect(TestRoots{});
    // ペアは回収され、常駐の分は残る。次の GC の閾値は、残った分から決まる。
    try std.testing.expectEqual(0, heap.count);
    try std.testing.expectEqual(4096, heap.held());
    try std.testing.expectEqual(4096 * 2, heap.threshold);
}

test "max_host_limit is 1 GiB" {
    // 値そのものを固定する。大きくすると、wasm32 で 4 GiB に近い上限が通り、
    // 上限に届く前に実メモリが尽きて trap する(`max_host_limit` の説明を参照)。
    try std.testing.expectEqual(@as(usize, 1073741824), max_host_limit);
}

test "clampHostLimit leaves a small limit and caps a large one" {
    try std.testing.expectEqual(@as(usize, 65536), clampHostLimit(65536));
    try std.testing.expectEqual(max_host_limit, clampHostLimit(max_host_limit));
    try std.testing.expectEqual(max_host_limit, clampHostLimit(max_host_limit + 1));
    try std.testing.expectEqual(max_host_limit, clampHostLimit(std.math.maxInt(u32)));
}

test "hostOptions: 0 is the default, a small limit stays, a large one is capped" {
    try std.testing.expectEqual(default_limit, hostOptions(0).limit);
    try std.testing.expectEqual(@as(usize, 1), hostOptions(1).limit);
    try std.testing.expectEqual(@as(usize, 65536), hostOptions(65536).limit);
    try std.testing.expectEqual(@as(usize, 1073741824), hostOptions(1073741824).limit);
    try std.testing.expectEqual(@as(usize, 1073741824), hostOptions(1073741825).limit);
    // 3 GiB と、u32 の最大(4 GiB に1足りない)。
    try std.testing.expectEqual(@as(usize, 1073741824), hostOptions(3 * 1024 * 1024 * 1024).limit);
    try std.testing.expectEqual(@as(usize, 1073741824), hostOptions(std.math.maxInt(u32)).limit);
}

test "hostOptions leaves every other option at its default" {
    const d: Options = .{};
    const o = hostOptions(std.math.maxInt(u32));
    try std.testing.expectEqual(d.min_threshold, o.min_threshold);
    try std.testing.expectEqual(d.work_capacity, o.work_capacity);
    try std.testing.expectEqual(d.stress, o.stress);
    try std.testing.expectEqual(d.raise_reserve, o.raise_reserve);
}

/// 256 MiB.
/// 終了するプログラムが必要とする量をはるかに上回り、インタプリタが動く機械の
/// メモリをはるかに下回る。
pub const default_limit: usize = 256 * 1024 * 1024;

/// In stress mode a collection is asked for after a gap of safe points.
/// 間隔は、最初の `stress_ramp` 回のセーフポイントでは1である。小さなプログラム
/// なら、実行の全体がこの範囲に収まる。それ以降は、経過したセーフポイントの数に
/// 応じて広がるので、数百万ステップのループでも GC は数百万回でなく数千回で済む。
/// また、ヒープ内の `stress_objects_per_step` 個のオブジェクトにつき最低1回の
/// セーフポイントを置くので、生きているものがどれだけ多くても、1ステップに課す
/// 仕事が抑えられる。
const stress_ramp = 4096;
const stress_objects_per_step = 16;

const Header = struct {
    /// The next free slot of the pool, while the slot is free; null otherwise.
    /// 生きているセルでは使わない。
    next: ?*Header,
    /// An index into `object_types`, or `free_kind` for a slot that holds no object.
    kind: u8,
    /// Set by the marking, cleared by the sweep.
    marked: bool,
    /// Whether the object is a constant: the data of a literal, or the string
    /// `symbol->string` returned (R7RS 3.4). The procedures that write to an object
    /// refuse it (`isImmutable`). Set by `makeImmutable`, never cleared; the sweep
    /// clears `marked` and leaves this.
    ///
    /// Why: ヘッダに置くのは、設計(docs/design/runtime.md)の指定であり、オブジェクト
    /// 本体に足すより小さい。`next` の後ろの `kind` と `marked` の余白に収まるので、
    /// セルの大きさは変わらない(単体テストが固定している)。
    immutable: bool,
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

/// The `kind` of a slot that holds no object: never handed out yet, or given back.
const free_kind: u8 = std.math.maxInt(u8);

/// The bytes of one chunk, the unit the heap takes cells in, unless the options say
/// otherwise (`Options.chunk_bytes`).
/// Why: 64 KiB 以上にする。実行ファイルの割り当て器を替える案は、確保の数が
/// `vm.max_map_count` を超えて異常終了した(`large_resident_bytes` の Why)。256 MiB の上限でも、
/// チャンクは数千個で、その数の `mmap` に収まる。
pub const default_chunk_bytes: usize = 64 * 1024;

/// What a slot's start and size are multiples of.
const slot_align: usize = 16;

/// Where the first slot of a chunk starts: after the chunk's own fields.
const slots_offset: usize = 32;

/// The least a chunk may be: its fields, and one slot of the largest shape.
const min_chunk_bytes: usize = blk: {
    var largest: usize = 0;
    for (shapes) |s| largest = @max(largest, s.bytes);
    break :blk slots_offset + largest;
};

comptime {
    std.debug.assert(object_types.len < free_kind);
    std.debug.assert(@sizeOf(Chunk) <= slots_offset);
    std.debug.assert(min_chunk_bytes <= default_chunk_bytes);
    for (object_types) |T| {
        std.debug.assert(@alignOf(Cell(T)) <= slot_align);
    }
}

/// What a pool's slots look like: their size, and where in a slot the header is.
/// Why: `Cell` は自動の並びの構造体なので、ヘッダがセルの先頭に来るとは限らない(wasm32 では、
/// 型によって先頭に来ない)。スイープは、型を知らずにスロットからヘッダを取るので、ヘッダの
/// オフセットが同じセルだけを、1つのプールに入れる。
const Shape = struct {
    bytes: usize,
    header_offset: usize,
};

fn shapeOf(comptime T: type) Shape {
    return .{
        .bytes = std.mem.alignForward(usize, @sizeOf(Cell(T)), slot_align),
        .header_offset = @offsetOf(Cell(T), "header"),
    };
}

/// The distinct shapes: the heap keeps one pool of chunks for each.
const shapes = blk: {
    var found: [object_types.len]Shape = undefined;
    var n: usize = 0;
    for (object_types) |T| {
        const shape = shapeOf(T);
        var seen = false;
        for (found[0..n]) |s| {
            if (s.bytes == shape.bytes and s.header_offset == shape.header_offset) seen = true;
        }
        if (!seen) {
            found[n] = shape;
            n += 1;
        }
    }
    const result: [n]Shape = found[0..n].*;
    break :blk result;
};

const class_count = shapes.len;

/// The pool that holds cells of `T`.
fn classOf(comptime T: type) usize {
    const shape = shapeOf(T);
    for (shapes, 0..) |s, i| {
        if (s.bytes == shape.bytes and s.header_offset == shape.header_offset) return i;
    }
    unreachable;
}

/// A run of slots of one shape, taken from the allocator whole.
const Chunk = struct {
    /// The next older chunk of the pool.
    older: ?*Chunk,
    /// How many slots have been handed out; the ones after are untouched.
    used: usize,
    /// How many slots the chunk holds.
    capacity: usize,
    /// The bytes the chunk was taken with, which it is given back with.
    bytes: usize,

    /// The start of slot `index`.
    fn slotStart(self: *Chunk, comptime class: usize, index: usize) [*]u8 {
        const base: [*]u8 = @ptrCast(self);
        return base + slots_offset + index * shapes[class].bytes;
    }

    /// The header of the cell in slot `index`.
    fn slot(self: *Chunk, comptime class: usize, index: usize) *Header {
        return @ptrCast(@alignCast(self.slotStart(class, index) + shapes[class].header_offset));
    }
};

/// The chunks that hold cells of one slot size, and the slots given back.
const Pool = struct {
    /// Newest first.
    chunks: ?*Chunk = null,
    /// A slot to hand out again, with the rest on its `next`.
    free: ?*Header = null,
};

/// The header of the cell that holds `object`.
/// 指す先は必ずセルの中なので、整列を表明してよい(`Marker.object` と同じ)。
fn headerOf(comptime T: type, object: *const T) *Header {
    const cell: *Cell(T) = @alignCast(@constCast(@fieldParentPtr("value", object)));
    return &cell.header;
}

/// Whether `v` is a constant: a pair, string, vector or bytevector that `makeImmutable` marked.
/// 場所を持たない値(数、シンボル、手続きなど)は、変更できないが、「不変の印」を持つ対象では
/// ないので、偽である。変更の手続きは、型の検査が済んだ引数にこれを問い合わせる
/// (`prim/immutable.zig`)。
pub fn isImmutable(v: Value) bool {
    return switch (v.kind()) {
        .pair => headerOf(Pair, v.asPair().?).immutable,
        .string => headerOf(String, v.asString().?).immutable,
        .vector => headerOf(Vector, v.asVector().?).immutable,
        .bytevector => headerOf(Bytevector, v.asBytevector().?).immutable,
        else => false,
    };
}

/// Marks the pair, string, vector or bytevector `v` as a constant. Another kind of value has no
/// locations to mark, and is left as it is.
/// この関数は `v` そのものだけを印づける。到達できるオブジェクトの全体に印を立てるのは
/// `freeze.zig` である。
pub fn makeImmutable(v: Value) void {
    switch (v.kind()) {
        .pair => headerOf(Pair, v.asPair().?).immutable = true,
        .string => headerOf(String, v.asString().?).immutable = true,
        .vector => headerOf(Vector, v.asVector().?).immutable = true,
        .bytevector => headerOf(Bytevector, v.asBytevector().?).immutable = true,
        else => {},
    }
}

/// The bytes a cell of `T` accounts for, without its payload.
pub fn cellBytes(comptime T: type) usize {
    return @sizeOf(Cell(T));
}

/// The bytes the object owns beyond its cell: the slots of a frame, the bytes
/// of a string, the elements of a vector, the fields of a record, the values of
/// a multiple-values object, the limbs of a bignum, the bytes of a port.
/// ペイロードはセルとは別に確保され、セルと一緒に返される。
/// ペイロードを持つ型は `ownsPayload` が答える。この switch の分岐と同じ集合である。
fn payloadBytes(comptime T: type, object: *const T) usize {
    return switch (T) {
        Frame => object.values.len * @sizeOf(Value),
        String => object.bytes.len,
        Vector => object.items.len * @sizeOf(Value),
        Bytevector => object.bytes.len,
        Record => object.fields.len * @sizeOf(Value),
        MultipleValues => object.items.len * @sizeOf(Value),
        Bignum => object.limbs.len * @sizeOf(Limb),
        Port => switch (object.backing) {
            .memory => |m| m.bytes.len,
            .console => 0,
            .file => |f| f.buffer.len,
        },
        Node => switch (object.*) {
            .sequence => |nodes| nodes.len * @sizeOf(*const Node),
            .call => |c| c.operands.len * @sizeOf(*const Node),
            else => 0,
        },
        Parameterize => object.bindings.len * @sizeOf(ParameterBinding),
        else => 0,
    };
}

/// Whether objects of type `T` own a payload beyond their cell, so that only
/// their own `create` function may make them.
/// 節点(`Node` と `Parameterize`)は、ここに入らない。節点は `create` で作り、列を持つ節点は、
/// 作った後に `allocAttached` の列を持たせる(展開器が、子を決める前に節点を作るため)。
fn ownsPayload(comptime T: type) bool {
    return switch (T) {
        Frame, String, Vector, Bytevector, Record, MultipleValues, Bignum, Port => true,
        else => false,
    };
}

/// What `Heap.work` is while no list has been allocated, or the allocation
/// failed.
/// 何も入らないリストなので、すべてのマークが再走査になる。
var no_work: [0]*Header = .{};

/// The share of the limit kept free of live data.
/// GC のあと、これを除いた残りより多くが生きているなら、その GC で得たものが
/// 少なすぎて、再び要求する価値がない。
const reserve_divisor = 16;

/// The size from which a request to the resident allocator goes to `Heap.large`
/// rather than to `Heap.backing`.
/// Why: 実行ファイルの下の割り当て器 `smp_allocator` は、解放した領域をスロットごとの空きリストに
/// 積み、別のスロットに積んだ領域を再利用しないことがある(`std/heap/SmpAllocator.zig`。機序は
/// 実測しておらず、CPU を 1 個か 2 個に絞ると伸びなかった観察と矛盾しない推測である)。
/// `environment` は、大きな表を作っては捨てるので、`heap limit exceeded` にならないまま常駐の
/// メモリが伸びた。4 KiB 以上の確保をページ単位の割り当て器に回すと、一定に収まった
/// (境界 4096 バイトで効き、32768 バイトでは効かなかった。実測は計画書 0019 の同じ節にある)。
/// 実行ファイルの割り当て器そのものを替える案は、`vm.max_map_count` を超えて異常終了した
/// (`tests/cli-slow/multi-list-map.scm`)。回すのは常駐の確保だけで、ヒープのセルは動かさない。
/// この数値は、実測(境界 4096 バイトと 32768 バイトの2点)に乗っている。変えるときは、
/// `environment` を 20000 回以上繰り返す実行ファイルで、最大 RSS を測り直す。単体テストは境目の
/// 振る舞いをシンボルで固定するので、数値そのものは「境目の数値」のテストが固定する。
pub const large_resident_bytes: usize = 4096;

/// The account a collection is asked for at the latest.
/// 上限までの余裕は、機械の1ステップが2つのセーフポイントの間に確保してよい量である。
/// 例外が2つある。`apply` は、最後の引数のリストの長さに比例する量を1ステップの中で
/// 確保し(ADR-0031 の 2026-10-13 の追記)、`values` と `receiverCall` は、複数値の
/// 個数に比例する量を確保する(同じ ADR の 2026-10-14 の追記)。どちらもこの余裕を
/// 超えうる。
fn softLimit(limit: usize) usize {
    return limit - limit / reserve_divisor;
}

pub const Heap = struct {
    backing: std.mem.Allocator,
    /// Where the resident requests of `large_resident_bytes` and more go.
    /// ページ単位の割り当て器が既定である。WebAssembly では、`wasm_allocator` と同じものになる。
    /// 単体テストは、回した確保を数えるために置き換える。
    large: std.mem.Allocator = std.heap.page_allocator,
    options: Options,
    /// The chunks that hold the objects, one pool for each slot size.
    pools: [class_count]Pool = @splat(.{}),
    /// The bytes of the cells and payloads of the objects.
    accounted: usize = 0,
    /// The most `accounted` has been.
    peak: usize = 0,
    /// The number of objects.
    count: usize = 0,
    /// The account at which `shouldCollect` says yes.
    threshold: usize,
    /// Whether the collection that last ran left the heap too full to go on.
    /// 生きているものが上限との余裕の内側まで来ているので、GC で何をしても、次の確保は
    /// 失敗する。
    exhausted: bool = false,
    /// How many collections have run.
    collections: usize = 0,
    /// How many times the markings have rescanned the heap, over all collections.
    rescans: usize = 0,
    /// How many times `shouldCollect` was asked since the last collection, and
    /// in all.
    /// ストレスモードだけが数える。
    steps: usize = 0,
    total_steps: usize = 0,
    /// The marking's list of objects still to scan, kept between collections.
    work: []*Header = &no_work,
    /// The bytes of work outside the heap that count against the limit, while
    /// an expansion runs (`Charged`).
    /// 展開は機械のステップの外で走り、その間は GC が走らない(ADR-0031)。展開が使う作業領域
    /// は、ヒープの外にあるので、計上に入らないと、止まらないマクロの適用が、上限を大きく
    /// 超えてメモリを使う。展開が終われば 0 に戻す。
    external: usize = 0,
    /// Whether `external` counts against the limit. An expansion turns it on
    /// when it first applies a macro.
    /// Why: 展開の作業領域は、ふつうはソースの大きさに比例し、ソースはすでにヒープに計上されて
    /// いる。上限を超えて増えうるのは、マクロの適用が作る出力だけである。そこで数えるのは
    /// 常に数え、上限の検査にそれを入れるのは、最初のマクロの適用からにする。マクロを使わない
    /// 式の展開の振る舞いは、変わらない。
    external_enforced: bool = false,
    /// Whether a charge was refused for want of room under the limit, since
    /// whoever started the expansion last cleared it.
    /// 常駐の割り当て器(`residentAllocator`)が断ったときも立てる。どちらの断りも、呼び出し側
    /// には `error.OutOfMemory` に見えるので、これで上限の超過と見分ける。
    external_refused: bool = false,
    /// The bytes outside the heap that count against the limit at all times:
    /// the tables of the bindings of the top levels and the registry of the
    /// libraries (`residentAllocator`).
    /// Why: 表は、セッションの間ずっと残り、インポートした名前の数に比例して伸びる。展開の
    /// 計上(`external`)と違い、1行ごとに戻すと、上限の外で伸び続ける(ADR-0040)。GC が
    /// 回収しないので、生きている量として `held` に入れる。
    resident: usize = 0,
    /// The symbols: each name is interned once, and named by a `SymbolId`.
    symbols: symbol.Table = .{},
    /// The host's open files, which the file ports read from and write to, or null
    /// when no file port can be made.
    /// Why: ファイルを持つのはホストの表(src/platform/)で、ヒープはその型を知らない。
    /// ポートの読み書き(src/port.zig)は、ヒープを受け取るので、ここから表に届く。閉じ忘れた
    /// ファイルポートは、回収のときに書き出してから閉じる(docs/plans/0019-phase5-ports-and-io.md
    /// の合意を求める点の4)。`deinit` も同じ経路を通るので、終了のときに開いたままの
    /// ファイルも閉じる。
    files: ?FileHost = null,
    /// Where the console's input port reads from, while a program runs, or null when
    /// the console has no input: standard input (src/main.zig), or nothing (WASM).
    /// Why: コンソールの入力ポートは、REPL が行を読むのと同じ読み手から読む
    /// (suchi/sucheme-zig#230 の決定)。ポートの読み書き(src/port.zig)はヒープを受け取るので、
    /// ここから届く。`Interpreter` が実行の間だけ置く。
    console_input: ?*std.Io.Reader = null,
    /// The command line of the program, which `command-line` gives (R7RS 6.14): the
    /// name of the program and then its arguments, each valid UTF-8.
    /// `Interpreter` が実行の間だけ置く。UTF-8 の検査は、置く側が済ませる(ネイティブは
    /// 起動時に src/main.zig が、WASM は `sucheme_set_command_line` が行う)。
    command_line: []const []const u8 = &.{"sucheme"},
    /// The variables of the process's environment that `get-environment-variable`
    /// reads, or null when the program has none (WASM).
    /// 値が UTF-8 かは、読むときに検査する(docs/design/platform-and-web.md の検証の表)。
    /// `Interpreter` が実行の間だけ置く。
    process_environ: ?*const std.process.Environ.Map = null,
    /// Whether the next boundary between steps collects, whatever the threshold.
    /// Why: ファイルを開くときに記述子が尽きたら、回収で閉じられるポートがあれば開き直せる
    /// (docs/plans/0019-phase5-ports-and-io.md の合意を求める点の4)。プリミティブの途中では
    /// 回収できない(ADR-0031)ので、機械がこれを立てて、次の境目で回収してから呼び直す
    /// (`Machine.apply`)。回収が下ろす。
    collect_requested: bool = false,

    /// The means of opening, reading, writing and closing the host's files, each
    /// open one named by the slot of the host's table that holds it (`Port.File.id`).
    /// 開く、消す、有無を調べる口は、ヒープは使わない。ファイルの手続き(src/prim/port.zig)が、
    /// ヒープを通してここに届く。
    pub const FileHost = struct {
        context: *anyopaque,
        /// Opens the file `path` and gives the slot that holds it (src/resolve.zig
        /// `openUserFile`).
        open: *const fn (context: *anyopaque, path: []const u8, direction: Port.Direction) error{ Exhausted, Refused, OutOfMemory }!u32,
        /// Deletes the file `path`.
        delete: *const fn (context: *anyopaque, path: []const u8) error{Refused}!void,
        /// Whether the file `path` is there.
        exists: *const fn (context: *anyopaque, path: []const u8) bool,
        /// Reads into `buffer`, and gives how many bytes it read; 0 at the end of
        /// the file.
        read: *const fn (context: *anyopaque, id: u32, buffer: []u8) error{Io}!usize,
        /// Writes all of `bytes`.
        write: *const fn (context: *anyopaque, id: u32, bytes: []const u8) error{Io}!void,
        /// Closes the file and frees its slot.
        /// 誤りは返さない。閉じる操作の誤りは、知らせても取り返せない(R7RS 6.13.1 の
        /// `close-port` は値を返さない)。
        close: *const fn (context: *anyopaque, id: u32) void,
    };

    pub fn init(backing: std.mem.Allocator, options: Options) Heap {
        var adjusted = options;
        adjusted.chunk_bytes = @max(options.chunk_bytes, min_chunk_bytes);
        return .{
            .backing = backing,
            .options = adjusted,
            .threshold = @min(softLimit(options.limit), options.min_threshold),
        };
    }

    /// Frees every object, reachable or not, and the chunks.
    pub fn deinit(self: *Heap) void {
        inline for (0..class_count) |class| {
            var chunk = self.pools[class].chunks;
            while (chunk) |c| {
                var i = c.used;
                while (i > 0) {
                    i -= 1;
                    const header = c.slot(class, i);
                    if (header.kind != free_kind) self.free(header);
                }
                chunk = c.older;
                const memory: [*]align(slot_align) u8 = @ptrCast(@alignCast(c));
                self.backing.free(memory[0..c.bytes]);
            }
            self.pools[class] = .{};
        }
        self.accounted = 0;
        self.count = 0;
        if (self.work.len != 0) self.backing.free(self.work);
        self.work = &no_work;
        self.symbols.deinit(self.backing);
    }

    /// The symbol named `name`, interned first if it is new.
    ///
    /// 新しい名前は、名前の長さに比例する量を上限に計上する。上限に収まらなければ
    /// `HeapLimit` を返し、表は変わらない。すでにある名前は、何も確保しないので、上限に
    /// 達していても返せる。ID を保持するものは、GC の間、`Marker.symbol` で知らせなければ
    /// ならない。
    pub fn intern(self: *Heap, name: []const u8) Error!SymbolId {
        if (self.symbols.lookup(name)) |id| return id;
        try self.reserve(.limit, symbol.charge(name.len) catch return error.HeapLimit);
        return self.symbols.intern(self.backing, name);
    }

    /// The symbol named `name` that no collection reclaims, interned first if it is new.
    /// Zig のコードが ID を定数として持つ名前のためにある。上限に数えない。
    pub fn internFixed(self: *Heap, name: []const u8) error{OutOfMemory}!SymbolId {
        return self.symbols.internFixed(self.backing, name);
    }

    /// A new object holding `value`.
    ///
    /// ペイロードを持つオブジェクト(`ownsPayload`)は、専用の関数 `createFrame`、
    /// `createString`、`createVector`、`createBytevector`、`createRecord`、
    /// `createMultipleValuesIn`、`createBignum`、`createMemoryPort` で作る。
    pub fn create(self: *Heap, comptime T: type, value: T) Error!*T {
        return self.createIn(.limit, T, value);
    }

    /// A new object holding `value`, held to `budget`.
    pub fn createIn(self: *Heap, budget: Budget, comptime T: type, value: T) Error!*T {
        // Why: ペイロードを持つ型をここで作ると、ペイロードを計上せず、呼び出し側の切片を
        // そのまま持つ。スイープがそれを `backing` に返すので、実行時に壊れる。
        // コンパイル時に断る。
        comptime std.debug.assert(!ownsPayload(T));
        try self.reserve(budget, cellBytes(T));
        const cell = try self.allocCell(T);
        cell.value = value;
        self.link(T, cell, cellBytes(T));
        return &cell.value;
    }

    /// A new frame of `size` slots, all `uninitialized`, behind `parent`.
    ///
    /// スロットを先に確保し、セルを後に確保する。セルを確保できなければスロットを
    /// 返すので、失敗した呼び出しはヒープを元のままにする。巻き戻しの単位は、この
    /// 1回の呼び出しである。
    pub fn createFrame(self: *Heap, size: usize, parent: ?*Frame) Error!*Frame {
        return self.createFrameIn(.limit, size, parent);
    }

    /// A new frame of `size` slots, all `uninitialized`, behind `parent`, held
    /// to `budget`.
    pub fn createFrameIn(self: *Heap, budget: Budget, size: usize, parent: ?*Frame) Error!*Frame {
        const bytes = try self.reserveWithPayload(budget, Frame, size, @sizeOf(Value));
        const values = try self.backing.alloc(Value, size);
        errdefer self.backing.free(values);
        const cell = try self.allocCell(Frame);
        @memset(values, Value.uninitialized_value);
        cell.value = .{ .values = values, .parent = parent };
        self.link(Frame, cell, bytes);
        return &cell.value;
    }

    /// A new string of a copy of `bytes`, which must be valid UTF-8 (ADR-0008).
    /// コピーがペイロードで、先に確保し、セルを確保できなければ返す。
    /// `createFrame` と同じである。ASCII 判定のフラグを計算するのも、ここである。
    pub fn createString(self: *Heap, bytes: []const u8) Error!*String {
        // Why: `string-length` と `string-ref` は、バイト列が妥当な UTF-8 であることを前提に
        // 文字を数える。リーダは文字列リテラルのバイトを自分で検査し、その他の入口は
        // `Interpreter` と WASM の境界が検査するので、ここで保証される。将来の
        // `string-append` などがこの前提を破ったとき、Debug と ReleaseSafe のビルドで、
        // 作った場所で見つける(ReleaseFast では検査が消える)。
        std.debug.assert(std.unicode.utf8ValidateSlice(bytes));
        const total = try self.reserveWithPayload(.limit, String, bytes.len, 1);
        const copy = try self.backing.dupe(u8, bytes);
        errdefer self.backing.free(copy);
        return self.linkString(copy, total);
    }

    /// A new string of `fmt` formatted with `args`, held to `budget`.
    /// 書式の結果を、文字列のペイロードに直接書く。一時の領域を使わないので、ヒープの
    /// 外の確保は、ペイロードとセルの2つだけである。引数は妥当な UTF-8 でなければ
    /// ならない(`createString` と同じ前提)。
    pub fn printString(self: *Heap, budget: Budget, comptime fmt: []const u8, args: anytype) Error!*String {
        const len = std.fmt.count(fmt, args);
        const total = try self.reserveWithPayload(budget, String, len, 1);
        const bytes = try self.backing.alloc(u8, len);
        errdefer self.backing.free(bytes);
        _ = std.fmt.bufPrint(bytes, fmt, args) catch unreachable;
        std.debug.assert(std.unicode.utf8ValidateSlice(bytes));
        return self.linkString(bytes, total);
    }

    /// A new string of `len` bytes that `filler` writes, which must be valid UTF-8 (ADR-0008).
    /// `filler.fill(bytes)` が、確保したペイロードに内容を書く。ペイロードの大きさは、先に
    /// 上限に照らして検査するので、入力の大きさに比例する文字列(`make-string` や
    /// `string-append`)は、一時の領域に作ってから写すことなく、直接作れる。書いている間は
    /// 何も確保しない。コピーがペイロードで、先に確保し、セルを確保できなければ返す
    /// (`createString` と同じ)。
    pub fn createStringFilled(self: *Heap, len: usize, filler: anytype) Error!*String {
        const total = try self.reserveWithPayload(.limit, String, len, 1);
        const bytes = try self.backing.alloc(u8, len);
        errdefer self.backing.free(bytes);
        filler.fill(bytes);
        return self.linkString(bytes, total);
    }

    /// New bytes of `len` bytes for `s` to take in place of its own, which the caller
    /// fills from the old ones and gives to `replaceStringBytes`.
    ///
    /// Why: 文字を置き換えて UTF-8 の幅が変わる手続き(`string-set!` など)は、バイト列の
    /// 長さが変わる。古いバイト列を書き換えながら伸び縮みさせると、確保の失敗が文字列を
    /// 壊す。新しいバイト列を先に確保し、すべてを書いてから差し替えれば、失敗はここだけで、
    /// 文字列は元のままである。確保の検査は、差し替えのあとの計上が上限に収まるかで行う
    /// (増える分だけを見る)。
    pub fn stringBytesFor(self: *Heap, s: *const String, len: usize) Error![]u8 {
        if (len > s.bytes.len) try self.reserve(.limit, len - s.bytes.len);
        return self.backing.alloc(u8, len);
    }

    /// Makes `new`, from `stringBytesFor`, the bytes of `s`, and gives the old ones back.
    /// 計上は新しい長さに合わせ、`is_ascii` は新しいバイト列から計算し直す。
    pub fn replaceStringBytes(self: *Heap, s: *String, new: []u8) void {
        std.debug.assert(std.unicode.utf8ValidateSlice(new));
        self.accounted = self.accounted - s.bytes.len + new.len;
        if (self.accounted > self.peak) self.peak = self.accounted;
        self.backing.free(s.bytes);
        s.bytes = new;
        s.is_ascii = value_mod.allAscii(new);
    }

    /// Puts `bytes`, which the string will own, in a new cell.
    /// セルを確保できなければ、呼び出し側の `errdefer` がペイロードを返す。
    fn linkString(self: *Heap, bytes: []u8, total: usize) Error!*String {
        std.debug.assert(std.unicode.utf8ValidateSlice(bytes));
        const cell = try self.allocCell(String);
        // 文字列を作る経路はすべてここを通るので、フラグの計算はここだけにある。
        // 作ったあとに内容が変わる経路は `replaceStringBytes` で、そこでも計算し直す。
        cell.value = .{ .bytes = bytes, .is_ascii = value_mod.allAscii(bytes) };
        self.link(String, cell, total);
        return &cell.value;
    }

    /// A new vector of a copy of `items`.
    /// コピーがペイロードで、文字列のバイト列と同じ扱いである。
    pub fn createVector(self: *Heap, items: []const Value) Error!*Vector {
        const total = try self.reserveWithPayload(.limit, Vector, items.len, @sizeOf(Value));
        const copy = try self.backing.dupe(Value, items);
        errdefer self.backing.free(copy);
        const cell = try self.allocCell(Vector);
        cell.value = .{ .items = copy };
        self.link(Vector, cell, total);
        return &cell.value;
    }

    /// A new vector of `len` elements that `filler` writes.
    /// `filler.fill(items)` が、確保した要素の領域に値を書く。`createStringFilled` と同じ
    /// 形で、入力の大きさに比例するベクタ(`string->vector` など)を、一時の領域を経ずに作る。
    /// 領域は、書き終えるまでヒープにつながれていないので、GC が未初期化の要素を見ることはない
    /// (GC は機械のステップの境目でしか走らない)。
    pub fn createVectorFilled(self: *Heap, len: usize, filler: anytype) Error!*Vector {
        const total = try self.reserveWithPayload(.limit, Vector, len, @sizeOf(Value));
        const items = try self.backing.alloc(Value, len);
        errdefer self.backing.free(items);
        filler.fill(items);
        const cell = try self.allocCell(Vector);
        cell.value = .{ .items = items };
        self.link(Vector, cell, total);
        return &cell.value;
    }

    /// A new bytevector of a copy of `bytes`.
    /// コピーがペイロードで、文字列のバイト列と同じ扱いである。
    pub fn createBytevector(self: *Heap, bytes: []const u8) Error!*Bytevector {
        const total = try self.reserveWithPayload(.limit, Bytevector, bytes.len, 1);
        const copy = try self.backing.dupe(u8, bytes);
        errdefer self.backing.free(copy);
        return self.linkBytevector(copy, total);
    }

    /// A new bytevector of `len` bytes that `filler` writes.
    /// `filler.fill(bytes)` が、確保したペイロードに内容を書く。`createStringFilled` と同じ形で、
    /// 入力の大きさに比例するバイトベクタ(`make-bytevector` や `bytevector-append`)を、一時の領域を
    /// 経ずに作る。領域の大きさは、確保する前に上限に照らして検査する。
    pub fn createBytevectorFilled(self: *Heap, len: usize, filler: anytype) Error!*Bytevector {
        const total = try self.reserveWithPayload(.limit, Bytevector, len, 1);
        const bytes = try self.backing.alloc(u8, len);
        errdefer self.backing.free(bytes);
        filler.fill(bytes);
        return self.linkBytevector(bytes, total);
    }

    /// A new bignum of a copy of the limbs and the sign of `n`.
    /// 限界値列のコピーがペイロードで、先に確保し、セルを確保できなければ返す。
    /// `createBytevector` と同じ単位である。`n` が正規化されていること(上位の限界値が
    /// 0 でないこと、`i64` に収まらないこと)は、呼び出し側の src/num/ が保証する。
    pub fn createBignum(self: *Heap, n: std.math.big.int.Const) Error!*Bignum {
        const total = try self.reserveWithPayload(.limit, Bignum, n.limbs.len, @sizeOf(Limb));
        const copy = try self.backing.dupe(Limb, n.limbs);
        errdefer self.backing.free(copy);
        const cell = try self.allocCell(Bignum);
        cell.value = .{ .limbs = copy, .positive = n.positive };
        self.link(Bignum, cell, total);
        return &cell.value;
    }

    /// A new open port reading from or writing to memory, holding a copy of
    /// `contents`, which for a textual port must be valid UTF-8 (ADR-0008).
    /// コピーがペイロードで、先に確保し、セルを確保できなければ返す(`createBytevector` と
    /// 同じ単位である)。入力のポートは、文字列の UTF-8 のバイト列かバイトベクタの中身を
    /// 渡す。出力のポートは空で作り、書くときに `growPortBytes` で伸ばす。
    pub fn createMemoryPort(self: *Heap, direction: Port.Direction, element: Port.Element, contents: []const u8) Error!*Port {
        if (element == .textual) std.debug.assert(std.unicode.utf8ValidateSlice(contents));
        const total = try self.reserveWithPayload(.limit, Port, contents.len, 1);
        const copy = try self.backing.dupe(u8, contents);
        errdefer self.backing.free(copy);
        const cell = try self.allocCell(Port);
        cell.value = .{ .direction = direction, .element = element, .backing = .{ .memory = .{ .bytes = copy, .len = copy.len } } };
        self.link(Port, cell, total);
        return &cell.value;
    }

    /// A new file port with a buffer of `size` bytes, closed until the caller has
    /// opened its file and set `id` and `open`.
    /// Why: ポートを先に作り、ファイルを後で開く。逆の順では、ファイルを開いたあとでポートの
    /// 確保が上限で断られたとき、開いたファイルを閉じる責任が呼び出し側に残る。この順なら、
    /// 開けなかったポートは閉じたまま回収されるだけで、ホストの表(`files`)には触れない。
    pub fn createFilePort(self: *Heap, direction: Port.Direction, element: Port.Element, size: usize) Error!*Port {
        const total = try self.reserveWithPayload(.limit, Port, size, 1);
        const buffer = try self.backing.alloc(u8, size);
        errdefer self.backing.free(buffer);
        const cell = try self.allocCell(Port);
        cell.value = .{ .direction = direction, .element = element, .open = false, .backing = .{ .file = .{ .id = 0, .buffer = buffer } } };
        self.link(Port, cell, total);
        return &cell.value;
    }

    /// Gives the file input port `port` a buffer of `capacity` bytes, keeping the bytes
    /// it has not read, which move to the start.
    /// Why: `read` は、1つのデータがバッファより長いときだけ、バッファを伸ばし、戻るときに
    /// 元の大きさに戻す(suchi/sucheme-zig#230 の決定)。伸ばす分は上限に数え、新しい領域を先に
    /// 確保するので、失敗したときは、ポートも計上も元のままである。`capacity` は、読んでいない
    /// 分より小さくてはならない。
    pub fn resizeFileBuffer(self: *Heap, port: *Port, capacity: usize) Error!void {
        std.debug.assert(port.direction == .input);
        const file = &port.backing.file;
        const unread = file.len - file.pos;
        std.debug.assert(capacity >= unread);
        if (capacity > file.buffer.len) try self.reserve(.limit, capacity - file.buffer.len);
        const new = try self.backing.alloc(u8, capacity);
        @memcpy(new[0..unread], file.buffer[file.pos..file.len]);
        self.accounted = self.accounted - file.buffer.len + capacity;
        if (self.accounted > self.peak) self.peak = self.accounted;
        self.backing.free(file.buffer);
        file.buffer = new;
        file.pos = 0;
        file.len = unread;
    }

    /// A new open textual port on the console's stream `stream`: an input port for
    /// standard input, an output port for the others.
    /// ペイロードを持たないので、計上はセルだけである。
    pub fn createConsolePort(self: *Heap, stream: Port.Stream) Error!*Port {
        const total = try self.reserveWithPayload(.limit, Port, 0, 1);
        const cell = try self.allocCell(Port);
        const direction: Port.Direction = if (stream == .input) .input else .output;
        cell.value = .{ .direction = direction, .element = .textual, .backing = .{ .console = stream } };
        self.link(Port, cell, total);
        return &cell.value;
    }

    /// Gives the memory port `port` room for at least `capacity` bytes,
    /// keeping the bytes it holds.
    ///
    /// Why: 出力の文字列ポートとバイトベクタポートは、書くたびに伸びる領域を持つ
    /// (docs/plans/0019-phase5-ports-and-io.md の合意を求める点の3)。`replaceStringBytes`
    /// と同じく、新しい領域を先に確保して写してから差し替えるので、失敗したときは
    /// ポートも計上も元のままである。上限の検査は増える分だけを見る。伸ばし方(倍にするか)は
    /// 呼び出し側が `capacity` で決める。今の大きさ以下を求められたら、何もしない。
    /// 入力のポートは、領域のすべてにデータを持つので、伸ばさない。
    pub fn growPortBytes(self: *Heap, port: *Port, capacity: usize) Error!void {
        std.debug.assert(port.direction == .output);
        const memory = &port.backing.memory;
        if (capacity <= memory.bytes.len) return;
        try self.reserve(.limit, capacity - memory.bytes.len);
        const new = try self.backing.alloc(u8, capacity);
        @memcpy(new[0..memory.len], memory.bytes[0..memory.len]);
        self.accounted = self.accounted - memory.bytes.len + capacity;
        if (self.accounted > self.peak) self.peak = self.accounted;
        self.backing.free(memory.bytes);
        memory.bytes = new;
    }

    /// Puts `bytes`, which the bytevector will own, in a new cell.
    /// セルを確保できなければ、呼び出し側の `errdefer` がペイロードを返す。
    fn linkBytevector(self: *Heap, bytes: []u8, total: usize) Error!*Bytevector {
        const cell = try self.allocCell(Bytevector);
        cell.value = .{ .bytes = bytes };
        self.link(Bytevector, cell, total);
        return &cell.value;
    }

    /// A new record of `record_type` whose fields are a copy of `fields`, which
    /// must be as many as the type has.
    /// コピーがペイロードで、ベクタの要素と同じ扱いである。
    pub fn createRecord(self: *Heap, record_type: *RecordType, fields: []const Value) Error!*Record {
        std.debug.assert(fields.len == record_type.field_count);
        const total = try self.reserveWithPayload(.limit, Record, fields.len, @sizeOf(Value));
        const copy = try self.backing.dupe(Value, fields);
        errdefer self.backing.free(copy);
        const cell = try self.allocCell(Record);
        cell.value = .{ .record_type = record_type, .fields = copy };
        self.link(Record, cell, total);
        return &cell.value;
    }

    /// A new multiple-values object of a copy of `items`, held to `budget`.
    /// コピーがペイロードで、ベクタの要素と同じ扱いである。個数は 0 か 2 以上でなければ
    /// ならない。1個の値は、複数値のオブジェクトにせず、その値自身で運ぶ。
    pub fn createMultipleValuesIn(self: *Heap, budget: Budget, items: []const Value) Error!*MultipleValues {
        std.debug.assert(items.len != 1);
        const total = try self.reserveWithPayload(budget, MultipleValues, items.len, @sizeOf(Value));
        const copy = try self.backing.dupe(Value, items);
        errdefer self.backing.free(copy);
        const cell = try self.allocCell(MultipleValues);
        cell.value = .{ .items = copy };
        self.link(MultipleValues, cell, total);
        return &cell.value;
    }

    /// Whether a multiple-values object of `count` values would fit under what
    /// `budget` allows now, without allocating it.
    /// 本体は1回の確保で作るので、ステップに分けられない。機械は、収まらないときに、
    /// 確保の前に境目で回収させてから呼び直す(`Machine.valuesOf`)。
    pub fn multipleValuesFit(self: *const Heap, budget: Budget, count: usize) bool {
        const payload = std.math.mul(usize, count, @sizeOf(Value)) catch return false;
        const bytes = std.math.add(usize, cellBytes(MultipleValues), payload) catch return false;
        self.reserve(budget, bytes) catch return false;
        return true;
    }

    /// A list of `len` elements for a node to hold: the nodes of a sequence or the
    /// operands of a call (`*const Node`), or the bindings of a `parameterize`
    /// (`ParameterBinding`), with every element unset.
    /// Why: 展開器は、子を決める前に節点を作り、列もその時点で作る。列は持ち主の節点の
    /// ペイロードとして数え、持ち主と一緒に返す(`free`)。呼び出し側は、列を受け取ったら、
    /// ほかの確保をする前に、ちょうど1つの節点に持たせる。持たせる前に展開が失敗すると、
    /// 列が返らずに残る。持たせた後に失敗すると、節点ごとごみになり、次の GC が返す。
    /// 要素は未設定のままで、ごみになった節点の要素は読まれない(`free` が読むのは長さだけ
    /// である)。展開の途中で GC は走らないので(ADR-0031)、生きている節点が未設定の要素を
    /// 持つことは無い。
    pub fn allocAttached(self: *Heap, comptime E: type, len: usize) Error![]E {
        comptime std.debug.assert(E == *const Node or E == ParameterBinding);
        const bytes = std.math.mul(usize, len, @sizeOf(E)) catch return error.HeapLimit;
        try self.reserve(.limit, bytes);
        const list = try self.backing.alloc(E, len);
        self.accounted += bytes;
        if (self.accounted > self.peak) self.peak = self.accounted;
        return list;
    }

    /// Gives back a list `allocAttached` returned that no node came to hold.
    /// 持ち主の節点を作れなかったときだけ使う。
    pub fn freeDetached(self: *Heap, comptime E: type, list: []E) void {
        self.accounted -= list.len * @sizeOf(E);
        self.backing.free(list);
    }

    /// Checks that a cell of `T` and `count` payload elements of `size` bytes
    /// fit under the limit, and returns the bytes they account for.
    /// 桁あふれする大きさは、回り込ませず、上限超過として扱う。
    fn reserveWithPayload(self: *Heap, budget: Budget, comptime T: type, count: usize, size: usize) Error!usize {
        const payload = std.math.mul(usize, count, size) catch return error.HeapLimit;
        const bytes = std.math.add(usize, cellBytes(T), payload) catch return error.HeapLimit;
        try self.reserve(budget, bytes);
        return bytes;
    }

    /// A new pair of `car` and `cdr`.
    pub fn cons(self: *Heap, car: Value, cdr: Value) Error!Value {
        const pair = try self.create(Pair, .{ .car = car, .cdr = cdr });
        return .{ .pair = pair };
    }

    /// Whether a collection is due.
    /// 機械は2つのステップの間に問い合わせる。
    pub fn shouldCollect(self: *Heap) bool {
        if (self.collect_requested) return true;
        if (self.options.stress) {
            self.steps +|= 1;
            self.total_steps +|= 1;
            const gap = if (self.total_steps <= stress_ramp) 1 else @max(
                self.total_steps / stress_ramp,
                self.count / stress_objects_per_step,
            );
            if (self.steps >= gap) return true;
        }
        return self.held() >= self.threshold;
    }

    /// The bytes the heap accounts for: the objects, and the symbols a collection
    /// may reclaim. The limit and the threshold are held to this.
    pub fn held(self: *const Heap) usize {
        return self.accounted +| self.symbols.charged +| self.resident;
    }

    /// An allocator whose requests count against the limit for as long as they
    /// are held, on `backing`.
    /// 上限に収まらない要求は `null` を返して断り、`external_refused` を立てる。下の割り当て器は
    /// 個別に解放できるものでなければならない(アリーナでは、伸ばした表の古い領域が残り、
    /// 戻した計上が実際より少なくなる)。ヒープを動かすと、作った割り当て器は使えなくなる。
    pub fn residentAllocator(self: *Heap) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{
            .alloc = residentAlloc,
            .resize = residentResize,
            .remap = residentRemap,
            .free = residentFree,
        } };
    }

    /// Counts `bytes` more as resident, or refuses them and notes that it did.
    fn chargeResident(self: *Heap, bytes: usize) error{HeapLimit}!void {
        self.reserve(.limit, bytes) catch |e| {
            self.external_refused = true;
            return e;
        };
        self.resident += bytes;
    }

    /// The allocator that holds a resident block of `len` bytes.
    /// 解放と伸縮は、ブロックの大きさで経路を選び直す。取ったときと同じ経路になるのは、
    /// 境目をまたぐ伸縮を下で断るからである。
    fn residentBacking(self: *Heap, len: usize) std.mem.Allocator {
        return if (len >= large_resident_bytes) self.large else self.backing;
    }

    /// Whether two sizes of one resident block go to the same allocator.
    fn sameResidentRoute(a: usize, b: usize) bool {
        return (a >= large_resident_bytes) == (b >= large_resident_bytes);
    }

    fn residentAlloc(ptr: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *Heap = @ptrCast(@alignCast(ptr));
        self.chargeResident(len) catch return null;
        return self.residentBacking(len).rawAlloc(len, alignment, ret_addr) orelse {
            self.resident -= len;
            return null;
        };
    }

    fn residentResize(ptr: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *Heap = @ptrCast(@alignCast(ptr));
        if (!sameResidentRoute(memory.len, new_len)) return false;
        if (new_len > memory.len) self.chargeResident(new_len - memory.len) catch return false;
        if (!self.residentBacking(memory.len).rawResize(memory, alignment, new_len, ret_addr)) {
            if (new_len > memory.len) self.resident -= new_len - memory.len;
            return false;
        }
        if (new_len < memory.len) self.resident -= memory.len - new_len;
        return true;
    }

    fn residentRemap(ptr: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *Heap = @ptrCast(@alignCast(ptr));
        if (!sameResidentRoute(memory.len, new_len)) return null;
        if (new_len > memory.len) self.chargeResident(new_len - memory.len) catch return null;
        const moved = self.residentBacking(memory.len).rawRemap(memory, alignment, new_len, ret_addr) orelse {
            if (new_len > memory.len) self.resident -= new_len - memory.len;
            return null;
        };
        if (new_len < memory.len) self.resident -= memory.len - new_len;
        return moved;
    }

    fn residentFree(ptr: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *Heap = @ptrCast(@alignCast(ptr));
        self.residentBacking(memory.len).rawFree(memory, alignment, ret_addr);
        self.resident -= memory.len;
    }

    /// Frees every object that cannot be reached from `roots`.
    ///
    /// `roots.mark(marker)` が、プログラムの出発点をマーカに伝える。ほかにルートは
    /// ないので、`roots` が挙げるもの以外のどこにも値が保持されていない場所、つまり
    /// 機械の2つのステップの間でだけ呼ぶこと(ADR-0031)。
    pub fn collect(self: *Heap, roots: anytype) void {
        self.ensureWork();
        self.symbols.clearMarks();
        var marker: Marker = .{ .heap = self, .work = self.work };
        roots.mark(&marker);
        marker.finish();
        // 弱く持つ表は、マークが済んでから、掃除の前に、マークされなかったものを外す。
        var weak = marker.weak;
        while (weak) |w| {
            weak = w.next;
            w.next = null;
            w.listed = false;
            w.prune(w, self);
        }
        // マークの途中でリストを伸ばしていたら、オプションの大きさに戻す。伸ばした分は
        // 上限の外のメモリなので、次の GC まで持ち越さない。
        self.ensureWork();
        self.sweep();
        self.symbols.sweep(self.backing);
        self.collections += 1;
        self.steps = 0;
        self.collect_requested = false;
        const live = self.held();
        const soft = softLimit(self.options.limit);
        self.threshold = @min(soft, @max(self.options.min_threshold, live *| 2));
        self.exhausted = live +| (self.options.limit / reserve_divisor) > soft;
    }

    /// Makes the marking's list the size the options ask for.
    /// リスト用のメモリを確保できなければ、リストは空のままになり、マークは止まらずに
    /// 再走査する。
    fn ensureWork(self: *Heap) void {
        if (self.work.len == self.options.work_capacity) return;
        if (self.work.len != 0) self.backing.free(self.work);
        self.work = &no_work;
        if (self.options.work_capacity == 0) return;
        self.work = self.backing.alloc(*Header, self.options.work_capacity) catch &no_work;
    }

    /// Frees the objects the marking did not reach, and clears the mark of the
    /// rest.
    /// チャンクを、新しいほうから、チャンクの中では高いアドレスから走査する。解放した
    /// セルは空きリストの先頭に積まれるので、次の確保は、低いアドレスのセルから使う。
    fn sweep(self: *Heap) void {
        inline for (0..class_count) |class| {
            var chunk = self.pools[class].chunks;
            while (chunk) |c| : (chunk = c.older) {
                var i = c.used;
                while (i > 0) {
                    i -= 1;
                    const header = c.slot(class, i);
                    if (header.kind == free_kind) continue;
                    if (header.marked) {
                        header.marked = false;
                    } else {
                        self.free(header);
                    }
                }
            }
        }
    }

    /// Counts `bytes` of work outside the heap against the limit, or fails with
    /// `HeapLimit` and notes that it did.
    pub fn charge(self: *Heap, bytes: usize) error{HeapLimit}!void {
        if (self.external_enforced) self.reserve(.limit, bytes) catch |e| {
            self.external_refused = true;
            return e;
        };
        self.external +|= bytes;
    }

    /// Gives back `bytes` that `charge` counted.
    pub fn credit(self: *Heap, bytes: usize) void {
        self.external -|= bytes;
    }

    /// What the counting of work outside the heap was before a piece of work began
    /// its own (`beginCounting`).
    pub const Counting = struct { external: usize, enforced: bool };

    /// Starts a piece of work whose allocations through `Charged` count against the
    /// limit, held to it from now on when `enforced`; returns what to give back to
    /// `endCounting`.
    /// Why: 計上の範囲は入れ子になる。`import` の評価はライブラリのファイルを読み込み、その
    /// 宣言の `import` の評価を走らせる。内側の `import` の作業は、外側と同じ1行の作業領域に
    /// 残るので、外側が数えている間は、内側が終わっても数え続ける(`endCounting`)。展開は
    /// これを使わず、終わったら外側の計上に戻す(`expand.expandIn`)。
    pub fn beginCounting(self: *Heap, enforced: bool) Counting {
        const before: Counting = .{ .external = self.external, .enforced = self.external_enforced };
        self.external_enforced = enforced;
        return before;
    }

    /// Ends the piece of work `beginCounting` started.
    /// 外側に数えている範囲が無ければ、数えた分を戻す(作業領域は、呼び出し側が捨てる)。
    /// 外側が検査しているなら、数えた分を外側に残す。
    pub fn endCounting(self: *Heap, before: Counting) void {
        if (!before.enforced) self.external = before.external;
        self.external_enforced = before.enforced;
    }

    /// Fails with `HeapLimit` when `bytes` more would pass what `budget` allows.
    fn reserve(self: *const Heap, budget: Budget, bytes: usize) error{HeapLimit}!void {
        const total_held = std.math.add(usize, self.held(), if (self.external_enforced) self.external else 0) catch return error.HeapLimit;
        const total = std.math.add(usize, total_held, bytes) catch return error.HeapLimit;
        const ceiling = switch (budget) {
            .limit => self.options.limit,
            .raise_reserve => self.options.limit +| self.options.raise_reserve,
        };
        if (total > ceiling) return error.HeapLimit;
    }

    /// Whether the marking in progress has reached `pointer`.
    /// マークの後、掃除の前(`Weak.prune` の中)でだけ意味がある。
    pub fn isMarked(self: *const Heap, comptime T: type, pointer: *const T) bool {
        _ = self;
        const cell: *const Cell(T) = @alignCast(@fieldParentPtr("value", pointer));
        return cell.header.marked;
    }

    /// The number of objects of type `T` in the heap.
    /// テストが、ある種類のオブジェクトが回収されたか残っているかを、そのオブジェクトの
    /// 中身を読まずに確かめるためにある。
    pub fn countOf(self: *const Heap, comptime T: type) usize {
        const class = comptime classOf(T);
        var n: usize = 0;
        var chunk = self.pools[class].chunks;
        while (chunk) |c| : (chunk = c.older) {
            for (0..c.used) |i| {
                if (c.slot(class, i).kind == kindOf(T)) n += 1;
            }
        }
        return n;
    }

    /// A slot for a cell of `T`: one given back, or else the next of the newest chunk
    /// of its pool, taking a new chunk when that one is full.
    /// 返すセルのヘッダは「空き」のままで、`link` が実際の種類を書く。作ったあとで `link` までに
    /// 失敗する経路があっても、スイープは、その場所を空きとして読み飛ばす。
    fn allocCell(self: *Heap, comptime T: type) error{OutOfMemory}!*Cell(T) {
        const class = comptime classOf(T);
        const pool = &self.pools[class];
        if (pool.free) |header| {
            pool.free = header.next;
            header.next = null;
            return @alignCast(@fieldParentPtr("header", header));
        }
        var chunk = pool.chunks;
        if (chunk == null or chunk.?.used == chunk.?.capacity) {
            const bytes = self.options.chunk_bytes;
            const memory = try self.backing.alignedAlloc(u8, .@"16", bytes);
            const fresh: *Chunk = @ptrCast(@alignCast(memory.ptr));
            fresh.* = .{
                .older = pool.chunks,
                .used = 0,
                .capacity = (bytes - slots_offset) / shapes[class].bytes,
                .bytes = bytes,
            };
            pool.chunks = fresh;
            chunk = fresh;
        }
        const c = chunk.?;
        const cell: *Cell(T) = @ptrCast(@alignCast(c.slotStart(class, c.used)));
        c.used += 1;
        cell.header = .{ .next = null, .kind = free_kind, .marked = false, .immutable = false };
        return cell;
    }

    fn link(self: *Heap, comptime T: type, cell: *Cell(T), bytes: usize) void {
        cell.header = .{ .next = null, .kind = kindOf(T), .marked = false, .immutable = false };
        self.accounted += bytes;
        self.count += 1;
        if (self.accounted > self.peak) self.peak = self.accounted;
    }

    /// Writes out what the open file port `port` holds, if it is an output port,
    /// closes its file and marks it closed.
    /// 書き出しの誤りは捨てる。回収の途中では知らせる先が無い。`close-port` が誤りを知らせる
    /// ときは、先に書き出してから、これを呼ぶ(src/port.zig)。
    pub fn closeFile(self: *Heap, port: *Port) void {
        std.debug.assert(port.open);
        const host = self.files.?;
        const file = &port.backing.file;
        if (port.direction == .output and file.len != 0) host.write(host.context, file.id, file.buffer[0..file.len]) catch {};
        file.len = 0;
        host.close(host.context, file.id);
        port.open = false;
    }

    /// Gives an object's payload back to the allocator and its cell to the pool, and
    /// takes them off the account.
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
                    Bytevector => self.backing.free(cell.value.bytes),
                    Record => self.backing.free(cell.value.fields),
                    MultipleValues => self.backing.free(cell.value.items),
                    Bignum => self.backing.free(cell.value.limbs),
                    Port => switch (cell.value.backing) {
                        .memory => |m| self.backing.free(m.bytes),
                        .console => {},
                        .file => |f| {
                            if (cell.value.open) self.closeFile(&cell.value);
                            self.backing.free(f.buffer);
                        },
                    },
                    Node => switch (cell.value) {
                        .sequence => |nodes| self.backing.free(nodes),
                        .call => |c| self.backing.free(c.operands),
                        else => {},
                    },
                    Parameterize => self.backing.free(cell.value.bindings),
                    else => {},
                }
                const pool = &self.pools[comptime classOf(T)];
                cell.header = .{ .next = pool.free, .kind = free_kind, .marked = false, .immutable = false };
                pool.free = &cell.header;
                return;
            }
        }
        unreachable;
    }
};

/// A table that holds some of its objects weakly (ADR-0040, decision 6).
/// 表に埋め込み、マークのときに `Marker.holdWeakly` で登録する。`prune` は、`Heap.isMarked`
/// で生死を見て、マークされなかったものを表から外す。何も確保せず、何も解放しない(解放は
/// 掃除がする)。
pub const Weak = struct {
    next: ?*Weak = null,
    /// Whether the marking in progress has the table on its list.
    /// 1回の GC で同じ表を2回登録すると、列が輪になって、途中の表が刈られずに解放済みの
    /// セルを指したまま残る。`holdWeakly` が表明して防ぐ。
    listed: bool = false,
    prune: *const fn (*Weak, *Heap) void,
};

/// The marking of one collection.
/// `roots` がプログラムの出発点となる値を渡し、`finish` がそこからたどれるすべてに
/// 到達する。
///
/// オブジェクトに到達するとマークを付け、余地があれば、後で走査するためのリストに
/// 載せる。走査すると、そのオブジェクトの参照先に到達する。リストの初めの容量は、
/// オプションで決まる。到達したときリストが満杯なら、ヒープの外で倍の大きさに
/// 確保し直す。確保できないとき(容量0の設定を含む)は、マークだけ付けて、取りこぼした
/// ことを記録する。`finish` は、取りこぼしがなくなるまで、ヒープ内のマーク済みの
/// 全オブジェクトを走査し直す。マーク済みのオブジェクトは、リストに載れば順に、
/// 載らなければ再走査で走査されるので、漏れるものはない。リストの大きさが変えるのは、
/// マークにかかる時間であって、マークする対象ではない。
/// Why: 再走査の1回は、チャンクを新しいほうから、チャンクの中を高いアドレスから、1回なめる
/// だけである。新しいチャンクのセルは、確保の順にアドレスが上がるので、これは確保が新しい順
/// に近い(掃除の空きリストは低いアドレスから再利用するので、再利用したセルでは、順は
/// 近似にとどまる)。参照が
/// 新しいオブジェクトの方向へ伸びる鎖では、1回で進む深さがリストの大きさ程度になり、
/// 再走査の回数が鎖の長さに比例する。展開器は親の節点を子より先に作るので、深く
/// 入れ子になったコードがこの形になる(3o-3)。伸ばせば、確保が成功する限り再走査は
/// 起きない。各オブジェクトは1回しか載らないので、積まれている数はマークされる数を
/// 超えない。確保の大きさは倍々なのでその2倍まで、`realloc` が写す間は新旧の両方を
/// 持つので3倍までになる。
pub const Marker = struct {
    heap: *Heap,
    work: []*Header,
    len: usize = 0,
    /// An object was marked and not put on the list.
    lost: bool = false,
    /// The tables that hold some of their objects weakly, as `holdWeakly` met them.
    weak: ?*Weak = null,

    /// Asks that `w` drop what the marking did not reach, once the marking is done
    /// and before the sweep (`Heap.collect`).
    /// 表は、弱く持つものをマークせずに、ここで自分を登録する。登録とマークが同じ
    /// 呼び出しで起きるので、マークを省いた表が刈られずに残ることはない。
    pub fn holdWeakly(self: *Marker, w: *Weak) void {
        std.debug.assert(!w.listed);
        w.listed = true;
        w.next = self.weak;
        self.weak = w;
    }

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

    /// Marks the dynamic point `p` and, through it, what it refers to.
    pub fn dynPoint(self: *Marker, p: ?*const value_mod.DynPoint) void {
        trace.interpreter.walk(self, ?*const value_mod.DynPoint, p);
    }

    /// What `trace.walk` calls for a heap object.
    pub fn object(self: *Marker, comptime T: type, pointer: *const T) void {
        // オブジェクトの型の整列がヘッダより小さいとき(`LocalBinding` など)、セルの
        // 整列は型からは導けない。指す先は必ずセルの中なので、整列を表明してよい。
        const cell: *Cell(T) = @alignCast(@constCast(@fieldParentPtr("value", pointer)));
        const header = &cell.header;
        if (header.marked) return;
        header.marked = true;
        if (self.len == self.work.len) self.grow();
        if (self.len < self.work.len) {
            self.work[self.len] = header;
            self.len += 1;
        } else {
            self.lost = true;
        }
    }

    /// What `trace.walk` calls for a symbol id.
    /// 作業リストを通る経路と、再走査の経路の両方が、オブジェクトの走査を通るので、
    /// どちらでマークしたオブジェクトのシンボルも、ここで記録される。
    pub fn symbol(self: *Marker, id: SymbolId) void {
        self.heap.symbols.mark(id);
    }

    /// Doubles the list, outside the account of the heap, if the memory is there.
    /// 空のリスト(容量0の設定か、初めの確保の失敗)は伸ばさない。どちらも静的な
    /// `no_work` を指すので、アロケータが確保したものとして扱わない。確保に失敗したら、
    /// 元のリストのまま続ける(`realloc` は失敗のとき元を残す)。
    fn grow(self: *Marker) void {
        if (self.work.len == 0) return;
        const len = std.math.mul(usize, self.work.len, 2) catch return;
        const bigger = self.heap.backing.realloc(self.work, len) catch return;
        self.work = bigger;
        self.heap.work = bigger;
    }

    fn finish(self: *Marker) void {
        self.drain();
        while (self.lost) {
            self.lost = false;
            self.heap.rescans += 1;
            // 掃除と同じ順で、マーク済みの生きたセルを走査する。
            inline for (0..class_count) |class| {
                var chunk = self.heap.pools[class].chunks;
                while (chunk) |c| : (chunk = c.older) {
                    var i = c.used;
                    while (i > 0) {
                        i -= 1;
                        const header = c.slot(class, i);
                        if (header.kind != free_kind and header.marked) self.scan(header);
                    }
                }
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
    // 上限は合計に対するもので、ちょうど達するのは許される。
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
    // 大きさが回り込んで小さくなる個数を、小さい個数として通してはならない。
    try std.testing.expectError(error.HeapLimit, heap.createFrame(std.math.maxInt(usize) / @sizeOf(Value) + 2, null));
    try std.testing.expectEqual(0, heap.accounted);
}

test "when the cell cannot be allocated the slots are given back" {
    // 1回目の確保(スロット)は成功し、2回目(セル)は失敗する。
    var failing: std.testing.FailingAllocator = .init(std.testing.allocator, .{ .fail_index = 1 });
    var heap: Heap = .init(failing.allocator(), .{});
    defer heap.deinit();
    try std.testing.expectError(error.OutOfMemory, heap.createFrame(4, null));
    try std.testing.expectEqual(0, heap.accounted);
    try std.testing.expectEqual(0, heap.count);
    try std.testing.expectEqual(0, heap.countOf(Frame));
    // スロットは確保されて返された。リーク検査に残るものはない。
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

test "createString records whether every character of the string is ASCII" {
    var heap: Heap = .init(std.testing.allocator, .{});
    defer heap.deinit();
    const cases = [_]struct { text: []const u8, ascii: bool }{
        .{ .text = "", .ascii = true },
        .{ .text = "a", .ascii = true },
        .{ .text = "hello, world", .ascii = true },
        // 0 と DEL は ASCII である。
        .{ .text = "\x00\x7f", .ascii = true },
        .{ .text = "あ", .ascii = false },
        // 最小の非 ASCII 文字(U+0080、2バイト)。
        .{ .text = "\u{80}", .ascii = false },
        .{ .text = "𐀀", .ascii = false },
        // 非 ASCII の文字が、先頭、途中、末尾のどこにあっても見つける。
        .{ .text = "あabcdefghijklmnop", .ascii = false },
        .{ .text = "abcdefgあhijklmnop", .ascii = false },
        .{ .text = "abcdefghijklmnopあ", .ascii = false },
    };
    for (cases) |c| {
        const s = try heap.createString(c.text);
        try std.testing.expectEqualStrings(c.text, s.bytes);
        try std.testing.expectEqual(c.ascii, s.is_ascii);
    }
}

test "the ASCII flag changes neither the account nor what a collection keeps" {
    var heap: Heap = .init(std.testing.allocator, .{});
    defer heap.deinit();
    // 計上するのはバイト列の長さで、文字の数ではない。
    const wide = try heap.createString("あいう");
    try std.testing.expectEqual(cellBytes(String) + 9, heap.accounted);
    const narrow = try heap.createString("abc");
    try std.testing.expectEqual(cellBytes(String) * 2 + 9 + 3, heap.accounted);
    _ = try heap.createString("dropped あ");
    heap.collect(TestRoots{ .values = &.{ .fromString(wide), .fromString(narrow) } });
    try std.testing.expectEqual(2, heap.count);
    try std.testing.expectEqual(cellBytes(String) * 2 + 9 + 3, heap.accounted);
    try std.testing.expectEqualStrings("あいう", wide.bytes);
    try std.testing.expect(!wide.is_ascii);
    try std.testing.expectEqualStrings("abc", narrow.bytes);
    try std.testing.expect(narrow.is_ascii);
    try std.testing.expectEqual(3, wide.length());
    try std.testing.expectEqual(3, narrow.length());
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

test "an allocation for raising may pass the limit by the reserve, and no further" {
    const limit = cellBytes(Pair) * 2;
    var heap: Heap = .init(std.testing.allocator, .{ .limit = limit, .raise_reserve = cellBytes(Pair) + 3 });
    defer heap.deinit();
    _ = try heap.cons(.fromFixnum(1), .fromFixnum(2));
    _ = try heap.cons(.fromFixnum(3), .fromFixnum(4));
    // 上限に達した。通常の確保は断られる。
    try std.testing.expectError(error.HeapLimit, heap.cons(.fromFixnum(5), .fromFixnum(6)));
    // 送出のための確保は、上限を予約の分だけ超えてよい。
    const pair = try heap.createIn(.raise_reserve, Pair, .{ .car = .fromFixnum(7), .cdr = .empty_list_value });
    try std.testing.expectEqual(7, pair.car.asFixnum().?);
    try std.testing.expectEqual(limit + cellBytes(Pair), heap.accounted);
    try std.testing.expectEqual(heap.accounted, heap.peak);
    // 予約の残りは 3 バイトで、セル1つは入らない。文字列も同じ予約から確保する。
    try std.testing.expectError(error.HeapLimit, heap.createIn(.raise_reserve, Pair, .{ .car = .empty_list_value, .cdr = .empty_list_value }));
    try std.testing.expectError(error.HeapLimit, heap.printString(.raise_reserve, "{s}", .{""}));
    try std.testing.expectEqual(limit + cellBytes(Pair), heap.accounted);
    // 上限を超えている間、通常の確保は断られ続ける。
    try std.testing.expectError(error.HeapLimit, heap.cons(.fromFixnum(5), .fromFixnum(6)));
    // 回収されたら、上限と予約の両方に再び余裕ができる。
    heap.collect(TestRoots{});
    try std.testing.expectEqual(0, heap.accounted);
    _ = try heap.createIn(.raise_reserve, Pair, .{ .car = .empty_list_value, .cdr = .empty_list_value });
}

test "a frame for raising may pass the limit by the reserve, with its slots" {
    const limit = cellBytes(Pair);
    const frame = cellBytes(Frame) + 2 * @sizeOf(Value);
    var heap: Heap = .init(std.testing.allocator, .{ .limit = limit, .raise_reserve = frame });
    defer heap.deinit();
    _ = try heap.cons(.fromFixnum(1), .fromFixnum(2));
    try std.testing.expectError(error.HeapLimit, heap.createFrame(2, null));
    const f = try heap.createFrameIn(.raise_reserve, 2, null);
    try std.testing.expectEqual(2, f.values.len);
    try std.testing.expectEqual(limit + frame, heap.accounted);
    // 予約はスロットの分も数えるので、もう1つは入らない。
    try std.testing.expectError(error.HeapLimit, heap.createFrameIn(.raise_reserve, 0, null));
}

test "an allocation for raising may take the account exactly to the limit and the reserve, and not a byte more" {
    const limit = cellBytes(Pair) * 2;
    for ([_]usize{ 0, 1 }) |over| {
        // 予約の最後の確保が、ちょうど上限と予約の和に届く大きさ。`over` が 1 なら 1 バイト足りない。
        var heap: Heap = .init(std.testing.allocator, .{ .limit = limit, .raise_reserve = cellBytes(String) + 5 - over });
        defer heap.deinit();
        _ = try heap.cons(.fromFixnum(1), .fromFixnum(2));
        _ = try heap.cons(.fromFixnum(3), .fromFixnum(4));
        if (over == 0) {
            _ = try heap.printString(.raise_reserve, "{s}", .{"fives"});
            try std.testing.expectEqual(limit + heap.options.raise_reserve, heap.accounted);
        } else {
            try std.testing.expectError(error.HeapLimit, heap.printString(.raise_reserve, "{s}", .{"fives"}));
            try std.testing.expectEqual(limit, heap.accounted);
        }
    }
}

test "the reserve for raising is outside the limit, so an ordinary allocation never uses it" {
    const limit = cellBytes(String) + 4;
    var heap: Heap = .init(std.testing.allocator, .{ .limit = limit, .raise_reserve = 1024 });
    defer heap.deinit();
    // 上限ちょうどまでは、どちらの確保も通る。
    _ = try heap.printString(.limit, "{s}", .{"four"});
    try std.testing.expectError(error.HeapLimit, heap.printString(.limit, "{s}", .{""}));
    try std.testing.expectError(error.HeapLimit, heap.createString(""));
    try std.testing.expectError(error.HeapLimit, heap.createFrame(0, null));
    try std.testing.expectError(error.HeapLimit, heap.createVector(&.{}));
    try std.testing.expectError(error.HeapLimit, heap.create(Args, .{ .value = .empty_list_value, .next = null }));
    try std.testing.expectEqual(limit, heap.accounted);
    // 予約が 0 なら、送出のための確保も上限で断られる。
    var none: Heap = .init(std.testing.allocator, .{ .limit = limit, .raise_reserve = 0 });
    defer none.deinit();
    _ = try none.printString(.raise_reserve, "{s}", .{"four"});
    try std.testing.expectError(error.HeapLimit, none.printString(.raise_reserve, "{s}", .{""}));
}

test "printString formats straight into a string of the heap, and keeps what createString keeps" {
    var heap: Heap = .init(std.testing.allocator, .{});
    defer heap.deinit();
    const s = try heap.printString(.limit, "bad {s} {d}", .{ "thing", 3 });
    try std.testing.expectEqualStrings("bad thing 3", s.bytes);
    try std.testing.expect(s.is_ascii);
    try std.testing.expectEqual(cellBytes(String) + "bad thing 3".len, heap.accounted);
    const wide = try heap.printString(.raise_reserve, "unbound variable: {s}", .{"λ"});
    try std.testing.expectEqualStrings("unbound variable: λ", wide.bytes);
    try std.testing.expect(!wide.is_ascii);
    const empty = try heap.printString(.limit, "", .{});
    try std.testing.expectEqual(0, empty.bytes.len);
    // 回収すると、ペイロードの分も計上から外れる。
    heap.collect(TestRoots{ .values = &.{.fromString(s)} });
    try std.testing.expectEqual(cellBytes(String) + "bad thing 3".len, heap.accounted);
}

test "when the cell cannot be allocated the bytes of a printed string are given back" {
    var failing: std.testing.FailingAllocator = .init(std.testing.allocator, .{ .fail_index = 1 });
    var heap: Heap = .init(failing.allocator(), .{});
    defer heap.deinit();
    try std.testing.expectError(error.OutOfMemory, heap.printString(.raise_reserve, "{d}", .{42}));
    try std.testing.expectEqual(0, heap.accounted);
    try std.testing.expectEqual(1, failing.deallocations);
    try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
}

test "countOf counts the objects of one type" {
    var heap: Heap = .init(std.testing.allocator, .{});
    defer heap.deinit();
    try std.testing.expectEqual(0, heap.countOf(Pair));
    _ = try heap.cons(.empty_list_value, .empty_list_value);
    _ = try heap.createString("a");
    _ = try heap.cons(.empty_list_value, .empty_list_value);
    try std.testing.expectEqual(2, heap.countOf(Pair));
    try std.testing.expectEqual(1, heap.countOf(String));
    try std.testing.expectEqual(0, heap.countOf(Vector));
}

test "cells fill a chunk and then take another, and every one of them is counted and freed" {
    // 1 つのチャンクに収まる数より多くのペアを作る。最小のチャンクを使うので、数は少なくて済む。
    var heap: Heap = .init(std.testing.allocator, .{ .chunk_bytes = 1 });
    defer heap.deinit();
    const capacity = heap.options.chunk_bytes - slots_offset;
    const per_chunk = capacity / shapeOf(Pair).bytes;
    const n = per_chunk * 3 + 1;
    var head: Value = .empty_list_value;
    for (0..n) |i| head = try heap.cons(.fromFixnum(@intCast(i)), head);
    try std.testing.expectEqual(n, heap.countOf(Pair));
    try std.testing.expectEqual(n, heap.count);
    var chunks: usize = 0;
    var chunk = heap.pools[comptime classOf(Pair)].chunks;
    while (chunk) |c| : (chunk = c.older) chunks += 1;
    try std.testing.expectEqual(4, chunks);
    heap.collect(TestRoots{ .values = &.{head} });
    try std.testing.expectEqual(n, heap.countOf(Pair));
}

test "a collection gives a cell back to its pool, and the next one of that shape takes it, with no new chunk" {
    var failing: std.testing.FailingAllocator = .init(std.testing.allocator, .{});
    // 最小のチャンクを使い、チャンクをいくつか使う数のペアを作る。
    var heap: Heap = .init(failing.allocator(), .{ .chunk_bytes = 1 });
    defer heap.deinit();
    const n = 3 * ((heap.options.chunk_bytes - slots_offset) / shapeOf(Pair).bytes);
    for (0..n) |_| _ = try heap.cons(.empty_list_value, .empty_list_value);
    heap.collect(TestRoots{});
    try std.testing.expectEqual(0, heap.countOf(Pair));
    try std.testing.expectEqual(0, heap.count);
    // 回収は、マークの作業リストを確保する。数えるのは、その後からにする。
    const taken = failing.allocations;
    // 回収で空いた分を、同じ数だけ作り直す。チャンクは増えない。
    for (0..n) |_| _ = try heap.cons(.empty_list_value, .empty_list_value);
    try std.testing.expectEqual(taken, failing.allocations);
    try std.testing.expectEqual(n, heap.countOf(Pair));
}

test "a given-back slot is skipped by the sweep and the count, and what is made in it is a whole new object" {
    var heap: Heap = .init(std.testing.allocator, .{});
    defer heap.deinit();
    const dropped = try heap.cons(.fromFixnum(1), .empty_list_value);
    makeImmutable(dropped);
    const kept = try heap.cons(.fromFixnum(2), .empty_list_value);
    heap.collect(TestRoots{ .values = &.{kept} });
    try std.testing.expectEqual(1, heap.countOf(Pair));
    // 空いたスロットを使って作ったペアは、前のオブジェクトの「不変の印」を引き継がない。
    const again = try heap.cons(.fromFixnum(3), .empty_list_value);
    try std.testing.expectEqual(2, heap.countOf(Pair));
    try std.testing.expect(!isImmutable(again));
    heap.collect(TestRoots{ .values = &.{ kept, again } });
    try std.testing.expectEqual(2, heap.countOf(Pair));
    try std.testing.expectEqual(2, kept.asPair().?.car.asFixnum().?);
    try std.testing.expectEqual(3, again.asPair().?.car.asFixnum().?);
}

test "a chunk smaller than one slot is raised to hold one" {
    const heap: Heap = .init(std.testing.allocator, .{ .chunk_bytes = 1 });
    try std.testing.expectEqual(min_chunk_bytes, heap.options.chunk_bytes);
    const big: Heap = .init(std.testing.allocator, .{ .chunk_bytes = 1 << 20 });
    try std.testing.expectEqual(1 << 20, big.options.chunk_bytes);
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

test "a record accounts for its fields as well as its cell, and keeps a copy of them" {
    var heap: Heap = .init(std.testing.allocator, .{});
    defer heap.deinit();
    const t = try heap.create(RecordType, .{ .name = @fromBackingInt(@intCast(0)), .field_count = 2 });
    const before = heap.accounted;
    try std.testing.expectEqual(cellBytes(RecordType), before);
    var source = [_]Value{ .fromFixnum(1), .fromFixnum(2) };
    const r = try heap.createRecord(t, &source);
    source[0] = .fromFixnum(9);
    try std.testing.expectEqual(1, r.fields[0].asFixnum().?);
    try std.testing.expectEqual(2, r.fields.len);
    try std.testing.expectEqual(t, r.record_type);
    try std.testing.expectEqual(before + cellBytes(Record) + 2 * @sizeOf(Value), heap.accounted);
    const none = try heap.create(RecordType, .{ .name = @fromBackingInt(@intCast(0)), .field_count = 0 });
    const empty = try heap.createRecord(none, &.{});
    try std.testing.expectEqual(0, empty.fields.len);
}

test "a record is held to the limit by its fields" {
    for ([_]usize{ 0, 1 }) |short| {
        // 型と、フィールド2つのレコードがちょうど収まる上限。`short` が 1 なら 1 バイト足りない。
        const fit = cellBytes(RecordType) + cellBytes(Record) + 2 * @sizeOf(Value);
        var heap: Heap = .init(std.testing.allocator, .{ .limit = fit - short });
        defer heap.deinit();
        const t = try heap.create(RecordType, .{ .name = @fromBackingInt(@intCast(0)), .field_count = 2 });
        const fields = [_]Value{ .fromFixnum(1), .fromFixnum(2) };
        if (short == 0) {
            _ = try heap.createRecord(t, &fields);
            try std.testing.expectEqual(fit, heap.accounted);
        } else {
            try std.testing.expectError(error.HeapLimit, heap.createRecord(t, &fields));
            try std.testing.expectEqual(cellBytes(RecordType), heap.accounted);
            try std.testing.expectEqual(1, heap.count);
        }
    }
}

test "when the cell cannot be allocated the fields of a record are given back" {
    var failing: std.testing.FailingAllocator = .init(std.testing.allocator, .{ .fail_index = 2 });
    var heap: Heap = .init(failing.allocator(), .{});
    defer heap.deinit();
    // 1回目の確保は型のセル、2回目はフィールド、3回目はレコードのセルで、これが失敗する。
    const t = try heap.create(RecordType, .{ .name = @fromBackingInt(@intCast(0)), .field_count = 1 });
    const accounted = heap.accounted;
    try std.testing.expectError(error.OutOfMemory, heap.createRecord(t, &.{.fromFixnum(1)}));
    try std.testing.expectEqual(accounted, heap.accounted);
    try std.testing.expectEqual(1, heap.count);
    try std.testing.expectEqual(1, failing.deallocations);
}

test "a collection keeps a record, its type and its fields, and frees them all once nothing reaches them" {
    for ([_]usize{ 0, 4096 }) |capacity| {
        var heap: Heap = .init(std.testing.allocator, .{ .work_capacity = capacity });
        defer heap.deinit();
        const t = try heap.create(RecordType, .{ .name = @fromBackingInt(@intCast(0)), .field_count = 2 });
        const field = try heap.createString("kept");
        const r = try heap.createRecord(t, &.{ .fromString(field), .fromFixnum(1) });
        // 到達できない型とレコード。
        const other = try heap.create(RecordType, .{ .name = @fromBackingInt(@intCast(1)), .field_count = 1 });
        _ = try heap.createRecord(other, &.{.fromFixnum(2)});
        heap.collect(TestRoots{ .values = &.{.fromRecord(r)} });
        // ルートはレコードだけで、型とフィールドの文字列はそこからたどって残る。
        try std.testing.expectEqual(1, heap.countOf(Record));
        try std.testing.expectEqual(1, heap.countOf(RecordType));
        try std.testing.expectEqual(1, heap.countOf(String));
        try std.testing.expectEqual(cellBytes(RecordType) + cellBytes(Record) + 2 * @sizeOf(Value) + cellBytes(String) + 4, heap.accounted);
        try std.testing.expectEqualStrings("kept", r.fields[0].asString().?.bytes);
        // 型だけをルートにすると、レコードは回収され、型は残る。
        heap.collect(TestRoots{ .values = &.{.fromRecordType(t)} });
        try std.testing.expectEqual(0, heap.countOf(Record));
        try std.testing.expectEqual(1, heap.countOf(RecordType));
        heap.collect(TestRoots{});
        try std.testing.expectEqual(0, heap.count);
        try std.testing.expectEqual(0, heap.accounted);
    }
}

/// The code of a procedure that returns `datum`, made in `heap`: a lambda whose
/// body is a sequence of two nodes, `datum` twice.
/// 節点はヒープにあり(ADR-0040)、クロージャと継続のフレームが指す先として、テストが使う。
fn testLambda(heap: *Heap, datum: Value) !*Lambda {
    const body = try heap.create(Node, .{ .constant = .unspecified_value });
    const list = try heap.allocAttached(*const Node, 2);
    body.* = .{ .sequence = list };
    for (list) |*n| n.* = try heap.create(Node, .{ .constant = datum });
    return heap.create(Lambda, .{ .arity = 0, .frame_size = 0, .body = body });
}

test "deinit frees every object, frames and their slots and the lists of nodes included" {
    var heap: Heap = .init(std.testing.allocator, .{});
    const frame = try heap.createFrame(5, null);
    const lambda = try testLambda(&heap, .fromFixnum(1));
    _ = try heap.create(Closure, .{ .lambda = lambda, .env = frame });
    _ = try heap.create(Kont, .{ .next = null, .env = frame, .depth = 1, .step = .{ .sequence = .{ .node = lambda.body, .next = 1 } } });
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
    // クロージャのコードは、ヒープの節点を通して、データ(`code_datum`)を指す。
    const code_datum = try heap.cons(.fromFixnum(8), .empty_list_value);
    const lambda = try testLambda(&heap, code_datum);
    const closure = try heap.create(Closure, .{ .lambda = lambda, .env = frame });
    const arg = try heap.create(Args, .{ .value = .{ .closure = closure }, .next = null });
    const outer = try heap.create(Kont, .{ .next = null, .env = null, .depth = 1, .step = .{ .sequence = .{ .node = lambda.body, .next = 1 } } });
    // 呼び出しの節点は、オペランドの列を持つ。演算子とオペランドは、本体の2つの節点である。
    const call = try heap.create(Node, .{ .constant = .unspecified_value });
    const operands = try heap.allocAttached(*const Node, 1);
    call.* = .{ .call = .{ .operator = lambda.body.sequence[0], .operands = operands } };
    operands[0] = lambda.body.sequence[1];
    const top = try heap.create(Kont, .{ .next = outer, .env = frame, .depth = 2, .step = .{ .call = .{ .call = call, .args = arg, .received = 1 } } });
    _ = try heap.cons(.fromFixnum(0), .empty_list_value);
    const garbage_frame = try heap.createFrame(100, null);
    _ = garbage_frame;
    _ = try testLambda(&heap, .fromFixnum(9));
    const before = heap.count;
    // ルートは継続だけで、残りはそこからたどって到達する。ごみは、ペア、フレーム、使われない
    // コード(lambda、本体、2つの節点)の6つである。
    heap.collect(TestRoots{ .kont = top });
    try std.testing.expectEqual(before - 6, heap.count);
    try std.testing.expectEqual(7, frame.values[0].asPair().?.car.asFixnum().?);
    try std.testing.expectEqual(frame, closure.env.?);
    try std.testing.expectEqual(arg, top.step.call.args.?);
    try std.testing.expectEqual(8, closure.lambda.body.sequence[0].constant.asPair().?.car.asFixnum().?);
    try std.testing.expectEqual(2 * cellBytes(Pair) + cellBytes(Frame) + 2 * @sizeOf(Value) + cellBytes(Closure) +
        cellBytes(Args) + 2 * cellBytes(Kont) + cellBytes(Lambda) + 4 * cellBytes(Node) + 3 * @sizeOf(*const Node), heap.accounted);
}

test "a node gives back the list it holds when it is collected, and a list no node came to hold can be given back" {
    var heap: Heap = .init(std.testing.allocator, .{});
    defer heap.deinit();
    const lambda = try testLambda(&heap, .fromFixnum(1));
    _ = lambda;
    try std.testing.expectEqual(cellBytes(Lambda) + 3 * cellBytes(Node) + 2 * @sizeOf(*const Node), heap.accounted);
    const bindings = try heap.allocAttached(ParameterBinding, 3);
    try std.testing.expectEqual(cellBytes(Lambda) + 3 * cellBytes(Node) + 2 * @sizeOf(*const Node) + 3 * @sizeOf(ParameterBinding), heap.accounted);
    heap.freeDetached(ParameterBinding, bindings);
    heap.collect(TestRoots{});
    try std.testing.expectEqual(0, heap.count);
    try std.testing.expectEqual(0, heap.accounted);
    // `parameterize` の節点は、束縛の列を持ち、回収されるときに列ごと計上から外れる。
    const body = try testLambda(&heap, .fromFixnum(2));
    const held_bindings = try heap.allocAttached(ParameterBinding, 2);
    _ = try heap.create(Parameterize, .{ .bindings = held_bindings, .body = body });
    for (held_bindings) |*b| b.* = .{ .param = body.body, .value = body.body };
    try std.testing.expectEqual(cellBytes(Lambda) + 3 * cellBytes(Node) + 2 * @sizeOf(*const Node) +
        cellBytes(Parameterize) + 2 * @sizeOf(ParameterBinding), heap.accounted);
    heap.collect(TestRoots{});
    try std.testing.expectEqual(0, heap.count);
    try std.testing.expectEqual(0, heap.accounted);
    // 呼び出しの節点も、オペランドの列ごと計上から外れる。
    const operator = try heap.create(Node, .{ .constant = .fromFixnum(3) });
    const call = try heap.create(Node, .{ .constant = .unspecified_value });
    const operands = try heap.allocAttached(*const Node, 4);
    call.* = .{ .call = .{ .operator = operator, .operands = operands } };
    for (operands) |*o| o.* = operator;
    try std.testing.expectEqual(2 * cellBytes(Node) + 4 * @sizeOf(*const Node), heap.accounted);
    heap.collect(TestRoots{});
    try std.testing.expectEqual(0, heap.count);
    try std.testing.expectEqual(0, heap.accounted);
}

test "a list for a node is counted against the limit, and the peak follows it" {
    var heap: Heap = .init(std.testing.allocator, .{ .limit = 1024 });
    defer heap.deinit();
    // 上限を超える長さは、確保せずに `HeapLimit` で断り、計上を変えない。
    try std.testing.expectError(error.HeapLimit, heap.allocAttached(*const Node, 1024));
    try std.testing.expectEqual(0, heap.accounted);
    // バイト数の計算が桁あふれする長さも、同じく断る。この長さは、あふれを回り込ませると
    // 8バイトになり、上限の内に収まって見える。
    try std.testing.expectError(error.HeapLimit, heap.allocAttached(*const Node, std.math.maxInt(usize) / @sizeOf(*const Node) + 2));
    try std.testing.expectEqual(0, heap.accounted);
    const list = try heap.allocAttached(ParameterBinding, 2);
    try std.testing.expectEqual(2 * @sizeOf(ParameterBinding), heap.accounted);
    try std.testing.expectEqual(heap.accounted, heap.peak);
    heap.freeDetached(ParameterBinding, list);
    try std.testing.expectEqual(0, heap.accounted);
    try std.testing.expectEqual(2 * @sizeOf(ParameterBinding), heap.peak);
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
        // 古いオブジェクトへのリンク。各ペアは、その前に作ったペアを指すように作る。
        var older: Value = .empty_list_value;
        for (0..200) |i| older = try heap.cons(.fromFixnum(@intCast(i)), older);
        // 新しいオブジェクトへのリンク。ペアを先に作ってから後で連結するので、先頭が
        // 最も古く、すべてのリンクは新しいペアへ向かう。
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
        // 2回目の GC も、最初からやり直して同じ結果になる。
        heap.collect(TestRoots{ .values = &.{ older, cells[0] } });
        try std.testing.expectEqual(400, heap.count);
    }
}

test "the threshold follows what is live, within the limit" {
    var heap: Heap = .init(std.testing.allocator, .{ .limit = 1600, .min_threshold = 160 });
    defer heap.deinit();
    // ソフトリミット(soft limit)は、上限からその16分の1を引いたもの。
    try std.testing.expectEqual(1500, softLimit(1600));
    try std.testing.expectEqual(160, heap.threshold);
    try std.testing.expect(!heap.shouldCollect());
    // 計上量を閾値に到達させる。
    var keep: Value = .empty_list_value;
    while (!heap.shouldCollect()) keep = try heap.cons(.fromFixnum(1), keep);
    heap.collect(TestRoots{ .values = &.{keep} });
    // すべてが生きていた。最小値より大きいので、その2倍になる。
    try std.testing.expectEqual(@min(1500, heap.accounted * 2), heap.threshold);
    try std.testing.expect(!heap.shouldCollect());
    try std.testing.expect(!heap.exhausted);
    // 生きているものがなければ、閾値は最小値に戻る。
    heap.collect(TestRoots{});
    try std.testing.expectEqual(160, heap.threshold);
    try std.testing.expectEqual(0, heap.accounted);
}

test "a collection that leaves the heap nearly full says it is exhausted" {
    var heap: Heap = .init(std.testing.allocator, .{ .limit = 1600, .min_threshold = 160 });
    defer heap.deinit();
    var keep: Value = .empty_list_value;
    while (true) keep = heap.cons(.fromFixnum(1), keep) catch break;
    // ソフトリミットを超え、すべてが生きている。
    try std.testing.expect(heap.shouldCollect());
    heap.collect(TestRoots{ .values = &.{keep} });
    try std.testing.expect(heap.exhausted);
    // 生きていたものを手放せば、ヒープに再び余裕ができる。
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
    // オブジェクトはテスト用アロケータから直接確保する。リストだけが、最初の確保で
    // 失敗するアロケータから来る。
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

/// Makes a spine of `n` pairs, each holding a leaf pair, whose links all run to
/// newer pairs, and returns its head.
/// 背骨のペアを先に作ってから葉と次の背骨をつなぐので、すべての参照が新しいペアへ
/// 向く。再走査の1回は新しい順にしか進まないので、リストがあふれると、再走査の回数が
/// 背骨の長さに比例する。
fn spineToNewer(heap: *Heap, comptime n: usize) !Value {
    var spine: [n]Value = undefined;
    for (&spine) |*s| s.* = try heap.cons(.empty_list_value, .empty_list_value);
    for (spine, 0..) |s, i| {
        s.asPair().?.car = try heap.cons(.fromFixnum(@intCast(i)), .empty_list_value);
        if (i + 1 < n) s.asPair().?.cdr = spine[i + 1];
    }
    return spine[0];
}

/// Makes a frame of 16 slots: the first holds `head`, and each other a pair of its own.
/// 走査すると16個を一度に積むので、容量1のリストは何度か伸びなければ収まらない。
fn wideFrame(heap: *Heap, head: Value) !*Frame {
    const frame = try heap.createFrame(16, null);
    frame.values[0] = head;
    for (frame.values[1..], 1..) |*v, i| v.* = try heap.cons(.fromFixnum(@intCast(i)), .empty_list_value);
    return frame;
}

test "the marking list grows when it fills, so a spine to newer objects needs no rescan, and goes back to its size" {
    var heap: Heap = .init(std.testing.allocator, .{ .work_capacity = 1 });
    defer heap.deinit();
    const frame = try wideFrame(&heap, try spineToNewer(&heap, 50));
    heap.collect(TestRoots{ .frame = frame });
    try std.testing.expectEqual(1 + 15 + 100, heap.count);
    try std.testing.expectEqual(0, heap.rescans);
    try std.testing.expectEqual(1, heap.work.len);
}

test "when the marking list cannot grow the marking rescans, as many times as the spine is long, and still finishes" {
    // 最初のリストの確保は通し、伸ばすための確保(その場の伸長と、新しい確保)を失敗させる。
    var failing: std.testing.FailingAllocator = .init(std.testing.allocator, .{ .fail_index = 1, .resize_fail_index = 0 });
    var heap: Heap = .init(std.testing.allocator, .{ .work_capacity = 1 });
    defer heap.deinit();
    const frame = try wideFrame(&heap, try spineToNewer(&heap, 50));
    heap.backing = failing.allocator();
    heap.collect(TestRoots{ .frame = frame });
    heap.backing = std.testing.allocator;
    try std.testing.expectEqual(1 + 15 + 100, heap.count);
    try std.testing.expect(heap.rescans >= 40);
    try std.testing.expectEqual(1, heap.work.len);
}

test "an object a rescan puts on the list is scanned before the rescan ends" {
    var failing: std.testing.FailingAllocator = .init(std.testing.allocator, .{ .fail_index = 1, .resize_fail_index = 0 });
    var heap: Heap = .init(std.testing.allocator, .{ .work_capacity = 1 });
    defer heap.deinit();
    // `y` が最も古く、`z`、`w` の順に新しい。`r` の走査で `y` があふれ、再走査が `y` から
    // `z` をリストに積む。`w` は `z` の走査でしか届かず、`y` より新しいので、再走査は
    // 新しい順に進むから、もう過ぎている。再走査の後でリストを空にしなければ、`w` は
    // マークされない。
    const y = try heap.cons(.empty_list_value, .empty_list_value);
    const z = try heap.cons(.empty_list_value, .empty_list_value);
    const w = try heap.cons(.fromFixnum(4), .empty_list_value);
    y.asPair().?.car = z;
    z.asPair().?.car = w;
    const x = try heap.cons(.fromFixnum(1), .empty_list_value);
    const r = try heap.cons(x, y);
    heap.backing = failing.allocator();
    heap.collect(TestRoots{ .values = &.{r} });
    heap.backing = std.testing.allocator;
    try std.testing.expectEqual(5, heap.count);
    try std.testing.expectEqual(4, w.asPair().?.car.asFixnum().?);
}

test "in stress mode every safe point of a short run collects, and the gap grows as the run goes on" {
    var heap: Heap = .init(std.testing.allocator, .{ .stress = true, .min_threshold = 1 << 30 });
    defer heap.deinit();
    // 短い実行。最初の `stress_ramp` 回のセーフポイントはすべて GC を要求する。
    for (0..stress_ramp) |_| {
        try std.testing.expect(heap.shouldCollect());
        heap.collect(TestRoots{});
    }
    try std.testing.expectEqual(stress_ramp, heap.collections);
    // 長い実行。GC のたびにセーフポイントの数え直しが始まるので、GC の回数はセーフ
    // ポイントの数よりはるかに少ない。数えをクリアしなければ、数はどの間隔も超えた
    // ままになり、毎回 GC が走ってしまう。
    const calls = 20_000;
    for (0..calls) |_| {
        if (heap.shouldCollect()) heap.collect(TestRoots{});
    }
    const after_ramp = heap.collections - stress_ramp;
    try std.testing.expect(after_ramp < calls * 3 / 4);
    try std.testing.expect(after_ramp > calls / 4);
}

test "multiple values account for their items as well as their cell, and keep a copy of them" {
    var heap: Heap = .init(std.testing.allocator, .{});
    defer heap.deinit();
    var source = [_]Value{ .fromFixnum(1), .fromFixnum(2) };
    const m = try heap.createMultipleValuesIn(.limit, &source);
    source[0] = .fromFixnum(9);
    try std.testing.expectEqual(1, m.items[0].asFixnum().?);
    try std.testing.expectEqual(2, m.items.len);
    try std.testing.expectEqual(cellBytes(MultipleValues) + 2 * @sizeOf(Value), heap.accounted);
    // 0個の値も、ヒープのオブジェクトである(共有の定数ではない)。
    const none = try heap.createMultipleValuesIn(.limit, &.{});
    try std.testing.expectEqual(0, none.items.len);
    try std.testing.expect(m != none);
    try std.testing.expectEqual(2, heap.countOf(MultipleValues));
}

test "multiple values are held to the limit by their items, and to the reserve by the budget" {
    for ([_]usize{ 0, 1 }) |short| {
        const fit = cellBytes(MultipleValues) + 2 * @sizeOf(Value);
        var heap: Heap = .init(std.testing.allocator, .{ .limit = fit - short, .raise_reserve = 2 * @sizeOf(Value) });
        defer heap.deinit();
        const items = [_]Value{ .fromFixnum(1), .fromFixnum(2) };
        if (short == 0) {
            _ = try heap.createMultipleValuesIn(.limit, &items);
        } else {
            try std.testing.expectError(error.HeapLimit, heap.createMultipleValuesIn(.limit, &items));
            try std.testing.expectEqual(0, heap.accounted);
            // 送出のための予約からなら、同じ大きさが収まる。
            _ = try heap.createMultipleValuesIn(.raise_reserve, &items);
            try std.testing.expectEqual(fit, heap.accounted);
        }
    }
}

test "when the cell cannot be allocated the items of multiple values are given back" {
    var failing: std.testing.FailingAllocator = .init(std.testing.allocator, .{ .fail_index = 1 });
    var heap: Heap = .init(failing.allocator(), .{});
    defer heap.deinit();
    try std.testing.expectError(error.OutOfMemory, heap.createMultipleValuesIn(.limit, &.{ .fromFixnum(1), .fromFixnum(2) }));
    try std.testing.expectEqual(0, heap.accounted);
    try std.testing.expectEqual(1, failing.deallocations);
    try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
}

test "a collection keeps multiple values and what they hold, and frees them once nothing reaches them" {
    for ([_]usize{ 0, 4096 }) |capacity| {
        var heap: Heap = .init(std.testing.allocator, .{ .work_capacity = capacity });
        defer heap.deinit();
        const text = try heap.createString("kept");
        const m = try heap.createMultipleValuesIn(.limit, &.{ .fromString(text), .fromFixnum(1) });
        _ = try heap.createMultipleValuesIn(.limit, &.{ .fromFixnum(2), .fromFixnum(3) });
        heap.collect(TestRoots{ .values = &.{.fromMultipleValues(m)} });
        try std.testing.expectEqual(1, heap.countOf(MultipleValues));
        try std.testing.expectEqual(1, heap.countOf(String));
        try std.testing.expectEqual(cellBytes(MultipleValues) + 2 * @sizeOf(Value) + cellBytes(String) + 4, heap.accounted);
        try std.testing.expectEqualStrings("kept", m.items[0].asString().?.bytes);
        heap.collect(TestRoots{ .values = &.{} });
        try std.testing.expectEqual(0, heap.countOf(MultipleValues));
        try std.testing.expectEqual(0, heap.accounted);
    }
}

/// Roots for a symbol test: values, and the cells and record types whose names are
/// raw symbol ids.
const SymbolRoots = struct {
    values: []const Value = &.{},
    cells: []const *value_mod.Cell = &.{},

    pub fn mark(self: SymbolRoots, marker: *Marker) void {
        for (self.values) |v| marker.value(v);
        for (self.cells) |c| marker.object(value_mod.Cell, c);
    }
};

/// Interns `count` names that nothing refers to, so that the ids a collection freed
/// are used by other names.
/// Why: 回収した ID は、次に作る名前が使う。印の漏れで ID を誤って回収しても、別の名前が
/// 作られなければ、元の名前が残って見えるので、漏れが検出されない。
fn churn(heap: *Heap, count: usize) !void {
    var buf: [24]u8 = undefined;
    for (0..count) |i| _ = try heap.intern(std.fmt.bufPrint(&buf, "churn-{d}", .{i}) catch unreachable);
}

test "a collection reclaims the symbols no root reaches and keeps every kind of holder" {
    for ([_]usize{ 4096, 1, 0 }) |capacity| {
        var heap: Heap = .init(std.testing.allocator, .{ .work_capacity = capacity });
        defer heap.deinit();
        const by_value = try heap.intern("by-value");
        const in_pair = try heap.intern("in-pair");
        const in_record_type = try heap.intern("in-record-type");
        const in_cell = try heap.intern("in-cell");
        const dropped = try heap.intern("dropped");
        const pair = try heap.cons(.fromSymbol(in_pair), .empty_list_value);
        const record_type = try heap.create(RecordType, .{ .name = in_record_type, .field_count = 0 });
        const cell = try heap.create(value_mod.Cell, .{ .name = in_cell, .value = .fromFixnum(1) });
        heap.collect(SymbolRoots{ .values = &.{ .fromSymbol(by_value), pair, .fromRecordType(record_type) }, .cells = &.{cell} });
        try churn(&heap, 16);
        // 残るものは、元の ID で、元の名前のままである。
        try std.testing.expectEqualStrings("by-value", heap.symbols.nameOf(by_value));
        try std.testing.expectEqualStrings("in-pair", heap.symbols.nameOf(pair.asPair().?.car.asSymbol().?));
        try std.testing.expectEqualStrings("in-record-type", heap.symbols.nameOf(record_type.name));
        try std.testing.expectEqualStrings("in-cell", heap.symbols.nameOf(cell.name));
        try std.testing.expectEqual(in_cell, heap.symbols.lookup("in-cell").?);
        // 参照されないものは回収され、ID は別の名前になった。
        try std.testing.expect(heap.symbols.lookup("dropped") == null);
        try std.testing.expect(!std.mem.eql(u8, "dropped", heap.symbols.nameOf(dropped)));
    }
}

test "a bare symbol that identifies a syntactic binding is kept, and the alias that identifies another is followed" {
    for ([_]usize{ 4096, 0 }) |capacity| {
        var heap: Heap = .init(std.testing.allocator, .{ .work_capacity = capacity });
        defer heap.deinit();
        const bare = try heap.intern("bare-identifier");
        const inner = try heap.intern("inner-of-alias");
        const dropped = try heap.intern("dropped-identifier");
        const alias = try heap.create(value_mod.Alias, .{ .inner = .fromSymbol(inner), .env = null, .mark = 1 });
        const local = try heap.create(value_mod.LocalBinding, .{ .rib_depth = 0, .index = 0 });
        const second = try heap.create(value_mod.SyntacticBinding, .{ .id = .{ .alias = alias }, .denotation = .{ .local = local }, .next = null });
        const first = try heap.create(value_mod.SyntacticBinding, .{ .id = .fromSymbol(bare), .denotation = .{ .local = local }, .next = second });
        const env = try heap.create(value_mod.SyntacticEnv, .{ .parent = null, .rib_depth = 0, .bindings = first, .library = null });
        const Roots = struct {
            env: *value_mod.SyntacticEnv,
            pub fn mark(self: @This(), marker: *Marker) void {
                marker.object(value_mod.SyntacticEnv, self.env);
            }
        };
        heap.collect(Roots{ .env = env });
        try churn(&heap, 16);
        try std.testing.expectEqualStrings("bare-identifier", heap.symbols.nameOf(first.id.asSymbol().?));
        try std.testing.expectEqualStrings("inner-of-alias", heap.symbols.nameOf(second.id.asAlias().?.inner.asSymbol().?));
        try std.testing.expect(!std.mem.eql(u8, "dropped-identifier", heap.symbols.nameOf(dropped)));
    }
}

test "the symbols of an object marked by a rescan are recorded too" {
    // 作業リストが空だと、すべてのオブジェクトが再走査でマークされる。深い鎖の最後のペアの
    // シンボルも、印を立てる。
    var heap: Heap = .init(std.testing.allocator, .{ .work_capacity = 0 });
    defer heap.deinit();
    var list: Value = .empty_list_value;
    var buf: [16]u8 = undefined;
    for (0..50) |i| {
        const id = try heap.intern(std.fmt.bufPrint(&buf, "s{d}", .{i}) catch unreachable);
        list = try heap.cons(.fromSymbol(id), list);
    }
    heap.collect(TestRoots{ .values = &.{list} });
    try churn(&heap, 64);
    var it = list;
    var i: usize = 50;
    while (it.asPair()) |p| : (it = p.cdr) {
        i -= 1;
        try std.testing.expectEqualStrings(std.fmt.bufPrint(&buf, "s{d}", .{i}) catch unreachable, heap.symbols.nameOf(p.car.asSymbol().?));
    }
    try std.testing.expectEqual(0, i);
}

test "a symbol that the last collection kept is reclaimed by the next one that does not reach it" {
    var heap: Heap = .init(std.testing.allocator, .{});
    defer heap.deinit();
    const id = try heap.intern("sticky");
    heap.collect(TestRoots{ .values = &.{.fromSymbol(id)} });
    try std.testing.expect(heap.symbols.lookup("sticky") != null);
    heap.collect(TestRoots{});
    try std.testing.expect(heap.symbols.lookup("sticky") == null);
    try std.testing.expectEqual(0, heap.held());
}

test "the names of symbols are held to the limit, and a collection gives them back" {
    var heap: Heap = .init(std.testing.allocator, .{ .limit = 1024 });
    defer heap.deinit();
    const name: [100]u8 = @splat('n');
    const id = try heap.intern(&name);
    try std.testing.expectEqual(symbol.charge(100) catch unreachable, heap.held());
    try std.testing.expectEqual(0, heap.accounted);
    // 上限を超える名前は、断られ、表も計上も変わらない。
    const huge: [1000]u8 = @splat('h');
    try std.testing.expectError(error.HeapLimit, heap.intern(&huge));
    try std.testing.expect(heap.symbols.lookup(&huge) == null);
    try std.testing.expectEqual(symbol.charge(100) catch unreachable, heap.held());
    // 名前が占める分だけ、オブジェクトに使える量が減る。
    var pairs: usize = 0;
    while (heap.cons(.empty_list_value, .empty_list_value)) |_| pairs += 1 else |_| {}
    try std.testing.expectEqual((1024 - (symbol.charge(100) catch unreachable)) / cellBytes(Pair), pairs);
    // すでにある名前は、何も確保しないので、満杯でも引ける。
    try std.testing.expectEqual(id, try heap.intern(&name));
    heap.collect(TestRoots{});
    try std.testing.expectEqual(0, heap.held());
    _ = try heap.intern(&huge[0..800].*);
}

test "a name for Zig's own constants is not held to the limit, and no collection reclaims it" {
    var heap: Heap = .init(std.testing.allocator, .{ .limit = 1 });
    defer heap.deinit();
    const id = try heap.internFixed("quote");
    try std.testing.expectEqual(0, heap.held());
    heap.collect(TestRoots{});
    try std.testing.expectEqual(id, heap.symbols.lookup("quote").?);
    try std.testing.expectEqualStrings("quote", heap.symbols.nameOf(id));
    // 同じ名前を、通常の intern で引いても、固定のまま同じ ID である。
    try std.testing.expectEqual(id, try heap.intern("quote"));
}

test "the names of symbols alone make a collection due" {
    var heap: Heap = .init(std.testing.allocator, .{ .min_threshold = 2048 });
    defer heap.deinit();
    var buf: [24]u8 = undefined;
    var i: usize = 0;
    while (!heap.shouldCollect()) : (i += 1) {
        _ = try heap.intern(std.fmt.bufPrint(&buf, "name-{d}", .{i}) catch unreachable);
        try std.testing.expect(i < 1000);
    }
    try std.testing.expectEqual(0, heap.accounted);
    heap.collect(TestRoots{});
    try std.testing.expect(!heap.shouldCollect());
}

test "slow: a flood of distinct names ends at the limit, and a collection gives the room back" {
    try tier.slow();
    // 1 MiB の名前を、GC を挟まずに作り続ける。名前の計上が無ければ、上限の外でメモリが
    // 増え続ける(docs/design/runtime.md の「インターン表を弱い表にする」)。
    var heap: Heap = .init(std.heap.smp_allocator, .{ .limit = 64 * 1024 * 1024 });
    defer heap.deinit();
    const name = try std.heap.smp_allocator.alloc(u8, 1024 * 1024);
    defer std.heap.smp_allocator.free(name);
    @memset(name, 'a');
    var made: usize = 0;
    while (true) : (made += 1) {
        std.mem.writeInt(u32, name[0..4], @intCast(made), .little);
        _ = heap.intern(name) catch |e| {
            try std.testing.expectEqual(error.HeapLimit, e);
            break;
        };
        try std.testing.expect(made < 1000);
    }
    try std.testing.expectEqual(heap.options.limit / (try symbol.charge(name.len)), made);
    try std.testing.expect(heap.held() <= heap.options.limit);
    // 参照されない名前は、GC がすべて回収し、上限の余裕が戻る。
    heap.collect(TestRoots{});
    try std.testing.expectEqual(0, heap.held());
    // GC を挟みながら作り続けると、回収した ID が再利用され、表は伸びない。
    const length = heap.symbols.entries.items.len;
    for (0..300) |i| {
        std.mem.writeInt(u32, name[0..4], @intCast(i), .little);
        _ = try heap.intern(name);
        if (heap.shouldCollect()) heap.collect(TestRoots{});
    }
    try std.testing.expectEqual(length, heap.symbols.entries.items.len);
}

test "the header with the mark for a constant is no larger than the one without" {
    // `kind` と `marked` と `immutable` は `next` の後ろの余白に収まる。大きさが増えると、
    // すべてのセルが増える。
    try std.testing.expectEqual(2 * @sizeOf(usize), @sizeOf(Header));
}

test "an object is not a constant until it is marked, and then stays one through collections" {
    var heap: Heap = .init(std.testing.allocator, .{});
    defer heap.deinit();
    const pair = try heap.cons(.fromFixnum(1), .empty_list_value);
    const string: Value = .fromString(try heap.createString("abc"));
    const vector: Value = .fromVector(try heap.createVector(&.{.fromFixnum(1)}));
    const bytes: Value = .fromBytevector(try heap.createBytevector(&.{1}));
    const other = try heap.cons(.fromFixnum(2), .empty_list_value);
    const other_bytes: Value = .fromBytevector(try heap.createBytevector(&.{2}));
    for ([_]Value{ pair, string, vector, bytes, other, other_bytes }) |v| try std.testing.expect(!isImmutable(v));
    makeImmutable(pair);
    makeImmutable(string);
    makeImmutable(vector);
    makeImmutable(bytes);
    try std.testing.expect(isImmutable(pair));
    try std.testing.expect(isImmutable(string));
    try std.testing.expect(isImmutable(vector));
    try std.testing.expect(isImmutable(bytes));
    // 印は1つのオブジェクトだけにある。
    try std.testing.expect(!isImmutable(other));
    try std.testing.expect(!isImmutable(other_bytes));
    // マークとスイープは `marked` だけを動かす。生き残ったものの印は残り、印のないものは
    // 印のないままである。
    const roots = TestRoots{ .values = &.{ pair, string, vector, bytes, other, other_bytes } };
    heap.collect(roots);
    heap.collect(roots);
    try std.testing.expect(isImmutable(pair));
    try std.testing.expect(isImmutable(string));
    try std.testing.expect(isImmutable(vector));
    try std.testing.expect(isImmutable(bytes));
    try std.testing.expect(!isImmutable(other));
    try std.testing.expect(!isImmutable(other_bytes));
}

test "a value that is not a pair, a string, a vector or a bytevector is not a constant, and marking it changes nothing" {
    var heap: Heap = .init(std.testing.allocator, .{});
    defer heap.deinit();
    const record_type = try heap.create(RecordType, .{ .name = try heap.internFixed("t"), .field_count = 0 });
    const others = [_]Value{ .fromFixnum(1), .fromBool(true), .empty_list_value, .fromCharacter('a'), .unspecified_value, .fromRecordType(record_type) };
    for (others) |v| {
        makeImmutable(v);
        try std.testing.expect(!isImmutable(v));
    }
}

test "replacing the bytes of a string keeps the account exact, and works out the flag again" {
    var heap: Heap = .init(std.testing.allocator, .{});
    defer heap.deinit();
    const s = try heap.createString("abc");
    try std.testing.expect(s.is_ascii);
    // 伸ばす。
    const longer = try heap.stringBytesFor(s, 4);
    @memcpy(longer, "ab\u{3bb}");
    heap.replaceStringBytes(s, longer);
    try std.testing.expectEqualStrings("abλ", s.bytes);
    try std.testing.expect(!s.is_ascii);
    try std.testing.expectEqual(cellBytes(String) + 4, heap.accounted);
    // 縮める。
    const shorter = try heap.stringBytesFor(s, 1);
    shorter[0] = 'z';
    heap.replaceStringBytes(s, shorter);
    try std.testing.expect(s.is_ascii);
    try std.testing.expectEqual(cellBytes(String) + 1, heap.accounted);
    try std.testing.expectEqual(cellBytes(String) + 4, heap.peak);
    // 回収は、いまの長さを外す。
    heap.collect(TestRoots{});
    try std.testing.expectEqual(0, heap.accounted);
}

test "the bytes for a longer string are held to the limit by what they add" {
    var heap: Heap = .init(std.testing.allocator, .{ .limit = cellBytes(String) + 4 });
    defer heap.deinit();
    const s = try heap.createString("abcd");
    // 同じ長さと短い長さは、上限に収まる。長くなる分は収まらない。
    const same = try heap.stringBytesFor(s, 4);
    @memcpy(same, "wxyz");
    heap.replaceStringBytes(s, same);
    try std.testing.expectEqualStrings("wxyz", s.bytes);
    try std.testing.expectError(error.HeapLimit, heap.stringBytesFor(s, 5));
    try std.testing.expectEqual(4, s.bytes.len);
    try std.testing.expectEqual(cellBytes(String) + 4, heap.accounted);
}

test "createStringFilled reserves the bytes before it fills them, and flags what it was filled with" {
    const Filler = struct {
        text: []const u8,
        calls: *usize,
        fn fill(self: @This(), bytes: []u8) void {
            self.calls.* += 1;
            @memcpy(bytes, self.text);
        }
    };
    var calls: usize = 0;
    var heap: Heap = .init(std.testing.allocator, .{ .limit = cellBytes(String) + 4 });
    defer heap.deinit();
    // 上限に収まらなければ、書く前に断る。
    try std.testing.expectError(error.HeapLimit, heap.createStringFilled(5, Filler{ .text = "abcde", .calls = &calls }));
    try std.testing.expectEqual(0, calls);
    try std.testing.expectEqual(0, heap.accounted);
    const s = try heap.createStringFilled(4, Filler{ .text = "ab\u{e9}", .calls = &calls });
    try std.testing.expectEqual(1, calls);
    try std.testing.expectEqualStrings("abé", s.bytes);
    try std.testing.expect(!s.is_ascii);
    try std.testing.expectEqual(cellBytes(String) + 4, heap.accounted);
}

test "createVectorFilled reserves the elements before it fills them, and accounts for them" {
    const Filler = struct {
        calls: *usize,
        fn fill(self: @This(), items: []Value) void {
            self.calls.* += 1;
            for (items, 0..) |*slot, i| slot.* = .fromFixnum(@intCast(i));
        }
    };
    var calls: usize = 0;
    var heap: Heap = .init(std.testing.allocator, .{ .limit = cellBytes(Vector) + 2 * @sizeOf(Value) });
    defer heap.deinit();
    try std.testing.expectError(error.HeapLimit, heap.createVectorFilled(3, Filler{ .calls = &calls }));
    try std.testing.expectError(error.HeapLimit, heap.createVectorFilled(std.math.maxInt(usize), Filler{ .calls = &calls }));
    try std.testing.expectEqual(0, calls);
    try std.testing.expectEqual(0, heap.accounted);
    const v = try heap.createVectorFilled(2, Filler{ .calls = &calls });
    try std.testing.expectEqual(1, calls);
    try std.testing.expectEqual(1, v.items[1].asFixnum().?);
    try std.testing.expectEqual(cellBytes(Vector) + 2 * @sizeOf(Value), heap.accounted);
    heap.collect(TestRoots{});
    try std.testing.expectEqual(0, heap.accounted);
}

test "a bytevector accounts for its bytes as well as its cell, and keeps a copy of them" {
    var heap: Heap = .init(std.testing.allocator, .{});
    defer heap.deinit();
    var source = [_]u8{ 1, 2, 255 };
    const b = try heap.createBytevector(&source);
    source[0] = 9;
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 255 }, b.bytes);
    try std.testing.expectEqual(cellBytes(Bytevector) + 3, heap.accounted);
    const empty = try heap.createBytevector(&.{});
    try std.testing.expectEqual(0, empty.bytes.len);
    try std.testing.expectEqual(cellBytes(Bytevector) * 2 + 3, heap.accounted);
    // 回収は、ペイロードごと計上から外す。残したものは中身を保つ。
    heap.collect(TestRoots{ .values = &.{.fromBytevector(b)} });
    try std.testing.expectEqual(1, heap.count);
    try std.testing.expectEqual(cellBytes(Bytevector) + 3, heap.accounted);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 255 }, b.bytes);
    heap.collect(TestRoots{});
    try std.testing.expectEqual(0, heap.accounted);
}

test "a bytevector is held to the limit by its payload, and a failure leaves the account as it was" {
    var heap: Heap = .init(std.testing.allocator, .{ .limit = cellBytes(Bytevector) + 4 });
    defer heap.deinit();
    try std.testing.expectError(error.HeapLimit, heap.createBytevector("hello"));
    try std.testing.expectEqual(0, heap.accounted);
    _ = try heap.createBytevector("four");
    try std.testing.expectError(error.HeapLimit, heap.createBytevector(&.{}));
    try std.testing.expectEqual(cellBytes(Bytevector) + 4, heap.accounted);
}

test "createBytevectorFilled reserves the bytes before it fills them, and accounts for them" {
    const Filler = struct {
        calls: *usize,
        fn fill(self: @This(), bytes: []u8) void {
            self.calls.* += 1;
            for (bytes, 0..) |*slot, i| slot.* = @intCast(i + 10);
        }
    };
    var calls: usize = 0;
    var heap: Heap = .init(std.testing.allocator, .{ .limit = cellBytes(Bytevector) + 2 });
    defer heap.deinit();
    try std.testing.expectError(error.HeapLimit, heap.createBytevectorFilled(3, Filler{ .calls = &calls }));
    try std.testing.expectError(error.HeapLimit, heap.createBytevectorFilled(std.math.maxInt(usize), Filler{ .calls = &calls }));
    try std.testing.expectEqual(0, calls);
    try std.testing.expectEqual(0, heap.accounted);
    const b = try heap.createBytevectorFilled(2, Filler{ .calls = &calls });
    try std.testing.expectEqual(1, calls);
    try std.testing.expectEqualSlices(u8, &.{ 10, 11 }, b.bytes);
    try std.testing.expectEqual(cellBytes(Bytevector) + 2, heap.accounted);
    heap.collect(TestRoots{});
    try std.testing.expectEqual(0, heap.accounted);
}

test "a bignum accounts for its limbs as well as its cell, and keeps a copy of them" {
    var heap: Heap = .init(std.testing.allocator, .{});
    defer heap.deinit();
    var source = [_]Limb{ 7, 1 };
    const b = try heap.createBignum(.{ .limbs = &source, .positive = false });
    source[0] = 9;
    try std.testing.expectEqualSlices(Limb, &.{ 7, 1 }, b.limbs);
    try std.testing.expect(!b.positive);
    try std.testing.expectEqual(cellBytes(Bignum) + 2 * @sizeOf(Limb), heap.accounted);
}

test "a collection keeps a bignum a ratnum or a compnum reaches, and frees it with its limbs once nothing does" {
    for ([_]usize{ 0, 4096 }) |capacity| {
        var heap: Heap = .init(std.testing.allocator, .{ .work_capacity = capacity });
        defer heap.deinit();
        const limbs = [_]Limb{ 7, 1 };
        const b = try heap.createBignum(.{ .limbs = &limbs, .positive = true });
        const big = cellBytes(Bignum) + 2 * @sizeOf(Limb);
        const r = try heap.create(Ratnum, .{ .numerator = .fromBignum(b), .denominator = .fromFixnum(3) });
        heap.collect(TestRoots{ .values = &.{.fromRatnum(r)} });
        try std.testing.expectEqual(2, heap.count);
        try std.testing.expectEqual(cellBytes(Ratnum) + big, heap.accounted);
        try std.testing.expectEqualSlices(Limb, &limbs, b.limbs);
        // 実部でも虚部でも、たどる。
        for ([_]bool{ false, true }) |in_imag| {
            const part: Value = .fromBignum(b);
            const c = try heap.create(Compnum, if (in_imag)
                .{ .real = .fromFixnum(0), .imag = part }
            else
                .{ .real = part, .imag = .fromFlonum(1.0) });
            heap.collect(TestRoots{ .values = &.{.fromCompnum(c)} });
            try std.testing.expectEqual(2, heap.count);
            try std.testing.expectEqual(cellBytes(Compnum) + big, heap.accounted);
        }
        // 何からも届かなければ、限界値列ごと計上から外れる。
        heap.collect(TestRoots{});
        try std.testing.expectEqual(0, heap.count);
        try std.testing.expectEqual(0, heap.accounted);
    }
}

test "a bignum is held to the limit by its limbs, and a failure leaves the account as it was" {
    var heap: Heap = .init(std.testing.allocator, .{ .limit = cellBytes(Bignum) + 2 * @sizeOf(Limb) });
    defer heap.deinit();
    const three = [_]Limb{ 1, 2, 3 };
    try std.testing.expectError(error.HeapLimit, heap.createBignum(.{ .limbs = &three, .positive = true }));
    try std.testing.expectEqual(0, heap.accounted);
    _ = try heap.createBignum(.{ .limbs = three[0..2], .positive = true });
    try std.testing.expectEqual(cellBytes(Bignum) + 2 * @sizeOf(Limb), heap.accounted);
}

test "create refuses exactly the heap types that own a payload" {
    // 期待する集合は `ownsPayload` から導かず、手で挙げる。導くと、一覧の漏れを検出できない。
    const with_payload = [_]type{ Frame, String, Vector, Bytevector, Record, MultipleValues, Bignum, Port };
    inline for (object_types) |T| {
        const expected = comptime for (with_payload) |U| {
            if (U == T) break true;
        } else false;
        try std.testing.expectEqual(expected, comptime ownsPayload(T));
    }
}

test "when the cell cannot be allocated the limbs of a bignum are given back" {
    var failing: std.testing.FailingAllocator = .init(std.testing.allocator, .{ .fail_index = 1 });
    var heap: Heap = .init(failing.allocator(), .{});
    defer heap.deinit();
    // 1回目の確保は限界値列、2回目はセルで、これが失敗する。
    const limbs = [_]Limb{ 1, 2 };
    try std.testing.expectError(error.OutOfMemory, heap.createBignum(.{ .limbs = &limbs, .positive = true }));
    try std.testing.expectEqual(0, heap.accounted);
    try std.testing.expectEqual(0, heap.count);
    try std.testing.expectEqual(1, failing.deallocations);
}

test "a memory port accounts for its bytes as well as its cell, and keeps a copy of them" {
    var heap: Heap = .init(std.testing.allocator, .{});
    defer heap.deinit();
    var source = [_]u8{ 'h', 'i' };
    const p = try heap.createMemoryPort(.input, .textual, &source);
    source[0] = 'x';
    try std.testing.expectEqualStrings("hi", p.backing.memory.bytes);
    try std.testing.expectEqual(2, p.backing.memory.len);
    try std.testing.expectEqual(0, p.backing.memory.pos);
    try std.testing.expectEqual(.input, p.direction);
    try std.testing.expectEqual(.textual, p.element);
    try std.testing.expect(p.open);
    try std.testing.expect(!p.fold_case);
    try std.testing.expectEqual(cellBytes(Port) + 2, heap.accounted);
    // 出力のポートは空で始まり、領域もまだ持たない。
    const q = try heap.createMemoryPort(.output, .binary, "");
    try std.testing.expectEqual(0, q.backing.memory.len);
    try std.testing.expectEqual(.output, q.direction);
    try std.testing.expectEqual(.binary, q.element);
    try std.testing.expectEqual(2 * cellBytes(Port) + 2, heap.accounted);
}

test "a collection keeps a port a value reaches, and frees it with its bytes once nothing does" {
    for ([_]usize{ 0, 4096 }) |capacity| {
        var heap: Heap = .init(std.testing.allocator, .{ .work_capacity = capacity });
        defer heap.deinit();
        const p = try heap.createMemoryPort(.output, .textual, "abc");
        // ペアの中からでも、たどる。
        const held = try heap.cons(.fromPort(p), .empty_list_value);
        heap.collect(TestRoots{ .values = &.{held} });
        try std.testing.expectEqual(2, heap.count);
        try std.testing.expectEqual(cellBytes(Pair) + cellBytes(Port) + 3, heap.accounted);
        try std.testing.expectEqualStrings("abc", p.backing.memory.bytes);
        // 伸ばした領域も、回収のときに計上ごと返る。
        try heap.growPortBytes(p, 16);
        heap.collect(TestRoots{ .values = &.{.fromPort(p)} });
        try std.testing.expectEqual(1, heap.count);
        try std.testing.expectEqual(cellBytes(Port) + 16, heap.accounted);
        // 何からも届かなければ、領域ごと計上から外れる。
        heap.collect(TestRoots{});
        try std.testing.expectEqual(0, heap.count);
        try std.testing.expectEqual(0, heap.accounted);
    }
}

test "a memory port is held to the limit by its bytes, and a failure leaves the account as it was" {
    var heap: Heap = .init(std.testing.allocator, .{ .limit = cellBytes(Port) + 2 });
    defer heap.deinit();
    try std.testing.expectError(error.HeapLimit, heap.createMemoryPort(.input, .binary, "abc"));
    try std.testing.expectEqual(0, heap.accounted);
    try std.testing.expectEqual(0, heap.count);
    _ = try heap.createMemoryPort(.input, .binary, "ab");
    try std.testing.expectEqual(cellBytes(Port) + 2, heap.accounted);
}

test "when the cell cannot be allocated the bytes of a memory port are given back" {
    var failing: std.testing.FailingAllocator = .init(std.testing.allocator, .{ .fail_index = 1 });
    var heap: Heap = .init(failing.allocator(), .{});
    defer heap.deinit();
    // 1回目の確保はバイト列、2回目はセルで、これが失敗する。
    try std.testing.expectError(error.OutOfMemory, heap.createMemoryPort(.input, .textual, "ab"));
    try std.testing.expectEqual(0, heap.accounted);
    try std.testing.expectEqual(0, heap.count);
    try std.testing.expectEqual(1, failing.deallocations);
}

test "growing the bytes of a memory port keeps what it holds, and accounts for the new room" {
    var heap: Heap = .init(std.testing.allocator, .{});
    defer heap.deinit();
    const p = try heap.createMemoryPort(.output, .textual, "");
    try heap.growPortBytes(p, 4);
    try std.testing.expectEqual(4, p.backing.memory.bytes.len);
    try std.testing.expectEqual(0, p.backing.memory.len);
    @memcpy(p.backing.memory.bytes[0..3], "abc");
    p.backing.memory.len = 3;
    try heap.growPortBytes(p, 10);
    try std.testing.expectEqual(10, p.backing.memory.bytes.len);
    try std.testing.expectEqual(3, p.backing.memory.len);
    try std.testing.expectEqualStrings("abc", p.backing.memory.bytes[0..3]);
    try std.testing.expectEqual(cellBytes(Port) + 10, heap.accounted);
    // 伸ばした分は、最大の計上量にも入る。
    try std.testing.expectEqual(heap.accounted, heap.peak);
    // 今の大きさ以下を求めても、縮めない。
    try heap.growPortBytes(p, 5);
    try std.testing.expectEqual(10, p.backing.memory.bytes.len);
    try std.testing.expectEqual(cellBytes(Port) + 10, heap.accounted);
}

test "growing the bytes of a memory port past the limit leaves the port and the account as they were" {
    var heap: Heap = .init(std.testing.allocator, .{ .limit = cellBytes(Port) + 8 });
    defer heap.deinit();
    const p = try heap.createMemoryPort(.output, .binary, "");
    try heap.growPortBytes(p, 8);
    @memcpy(p.backing.memory.bytes[0..2], "ab");
    p.backing.memory.len = 2;
    const before = p.backing.memory.bytes;
    try std.testing.expectError(error.HeapLimit, heap.growPortBytes(p, 9));
    try std.testing.expectEqual(before.ptr, p.backing.memory.bytes.ptr);
    try std.testing.expectEqual(8, p.backing.memory.bytes.len);
    try std.testing.expectEqualStrings("ab", p.backing.memory.bytes[0..2]);
    try std.testing.expectEqual(cellBytes(Port) + 8, heap.accounted);
}

test "growing the bytes of a memory port is held to the limit by the bytes it adds, not by the new size" {
    // 上限はちょうど 16 バイトの領域の分である。8 から 16 に伸ばすとき、照らすのは
    // 増える 8 バイトで、新しい大きさの 16 バイトを足すと上限を超える。
    var heap: Heap = .init(std.testing.allocator, .{ .limit = cellBytes(Port) + 16 });
    defer heap.deinit();
    const p = try heap.createMemoryPort(.output, .binary, "");
    try heap.growPortBytes(p, 8);
    try heap.growPortBytes(p, 16);
    try std.testing.expectEqual(16, p.backing.memory.bytes.len);
    try std.testing.expectEqual(cellBytes(Port) + 16, heap.accounted);
}

test "when the new bytes cannot be allocated a memory port keeps its old ones" {
    var failing: std.testing.FailingAllocator = .init(std.testing.allocator, .{ .fail_index = 2 });
    var heap: Heap = .init(failing.allocator(), .{});
    defer heap.deinit();
    // 1回目はバイト列、2回目はセル、3回目は伸ばした領域で、これが失敗する。
    const p = try heap.createMemoryPort(.output, .binary, "ab");
    try std.testing.expectError(error.OutOfMemory, heap.growPortBytes(p, 8));
    try std.testing.expectEqualStrings("ab", p.backing.memory.bytes);
    try std.testing.expectEqual(cellBytes(Port) + 2, heap.accounted);
}

test "a console port accounts for its cell only, and a collection keeps it while a value reaches it" {
    for ([_]usize{ 0, 4096 }) |capacity| {
        var heap: Heap = .init(std.testing.allocator, .{ .work_capacity = capacity });
        defer heap.deinit();
        const in = try heap.createConsolePort(.input);
        const out = try heap.createConsolePort(.output);
        const err = try heap.createConsolePort(.error_output);
        try std.testing.expectEqual(.input, in.direction);
        try std.testing.expectEqual(.output, out.direction);
        try std.testing.expectEqual(.output, err.direction);
        for ([_]*Port{ in, out, err }) |p| {
            try std.testing.expectEqual(.textual, p.element);
            try std.testing.expect(p.open);
        }
        try std.testing.expectEqual(Port.Stream.error_output, err.backing.console);
        try std.testing.expectEqual(3 * cellBytes(Port), heap.accounted);
        // 領域を持つポートと並んでいても、コンソールのポートの分はセルだけである。
        _ = try heap.createMemoryPort(.input, .binary, "abcd");
        heap.collect(TestRoots{ .values = &.{ .fromPort(in), .fromPort(err) } });
        try std.testing.expectEqual(2, heap.count);
        try std.testing.expectEqual(2 * cellBytes(Port), heap.accounted);
        heap.collect(TestRoots{});
        try std.testing.expectEqual(0, heap.count);
        try std.testing.expectEqual(0, heap.accounted);
    }
}

/// A host that records what is written to its files and which it closes, for the
/// tests of file ports.
const RecordingHost = struct {
    written: std.ArrayList(u8) = .empty,
    closed: std.ArrayList(u32) = .empty,
    fail_writes: bool = false,

    fn deinit(self: *RecordingHost) void {
        self.written.deinit(std.testing.allocator);
        self.closed.deinit(std.testing.allocator);
    }

    fn host(self: *RecordingHost) Heap.FileHost {
        return .{ .context = self, .open = open, .delete = delete, .exists = exists, .read = read, .write = write, .close = close };
    }

    fn open(_: *anyopaque, _: []const u8, _: Port.Direction) error{ Exhausted, Refused, OutOfMemory }!u32 {
        return error.Refused;
    }

    fn delete(_: *anyopaque, _: []const u8) error{Refused}!void {
        return error.Refused;
    }

    fn exists(_: *anyopaque, _: []const u8) bool {
        return false;
    }

    fn read(context: *anyopaque, id: u32, buffer: []u8) error{Io}!usize {
        _ = context;
        _ = id;
        _ = buffer;
        return 0;
    }

    fn write(context: *anyopaque, id: u32, bytes: []const u8) error{Io}!void {
        const self: *RecordingHost = @ptrCast(@alignCast(context));
        _ = id;
        if (self.fail_writes) return error.Io;
        self.written.appendSlice(std.testing.allocator, bytes) catch unreachable;
    }

    fn close(context: *anyopaque, id: u32) void {
        const self: *RecordingHost = @ptrCast(@alignCast(context));
        self.closed.append(std.testing.allocator, id) catch unreachable;
    }
};

test "a file port is made closed, and accounts for its buffer as well as its cell" {
    var heap: Heap = .init(std.testing.allocator, .{});
    defer heap.deinit();
    const p = try heap.createFilePort(.output, .binary, 64);
    try std.testing.expect(!p.open);
    try std.testing.expectEqual(.output, p.direction);
    try std.testing.expectEqual(.binary, p.element);
    try std.testing.expectEqual(64, p.backing.file.buffer.len);
    try std.testing.expectEqual(0, p.backing.file.len);
    try std.testing.expectEqual(0, p.backing.file.pos);
    try std.testing.expect(!p.backing.file.at_end);
    try std.testing.expectEqual(cellBytes(Port) + 64, heap.accounted);
}

test "a collection writes out and closes a file port it frees while the port is open, and only then" {
    var recording: RecordingHost = .{};
    defer recording.deinit();
    var heap: Heap = .init(std.testing.allocator, .{ .work_capacity = 4096 });
    heap.files = recording.host();
    const kept = try heap.createFilePort(.output, .textual, 16);
    kept.backing.file.id = 1;
    kept.open = true;
    @memcpy(kept.backing.file.buffer[0..2], "ok");
    kept.backing.file.len = 2;
    const lost = try heap.createFilePort(.output, .textual, 16);
    lost.backing.file.id = 2;
    lost.open = true;
    @memcpy(lost.backing.file.buffer[0..3], "abc");
    lost.backing.file.len = 3;
    // 開けなかったポートは閉じたまま回収され、表に触れない。
    _ = try heap.createFilePort(.input, .binary, 16);
    heap.collect(TestRoots{ .values = &.{.fromPort(kept)} });
    try std.testing.expectEqualSlices(u32, &.{2}, recording.closed.items);
    try std.testing.expectEqualStrings("abc", recording.written.items);
    try std.testing.expectEqual(cellBytes(Port) + 16, heap.accounted);
    // 終了のときに開いたままのポートも、同じ経路で書き出して閉じる。
    heap.deinit();
    try std.testing.expectEqualSlices(u32, &.{ 2, 1 }, recording.closed.items);
    try std.testing.expectEqualStrings("abcok", recording.written.items);
}

test "closing a file port drops what cannot be written, and closes the file all the same" {
    var recording: RecordingHost = .{ .fail_writes = true };
    defer recording.deinit();
    var heap: Heap = .init(std.testing.allocator, .{});
    defer heap.deinit();
    heap.files = recording.host();
    const p = try heap.createFilePort(.output, .binary, 4);
    p.backing.file.id = 7;
    p.open = true;
    p.backing.file.len = 1;
    heap.closeFile(p);
    try std.testing.expect(!p.open);
    try std.testing.expectEqual(0, p.backing.file.len);
    try std.testing.expectEqualSlices(u32, &.{7}, recording.closed.items);
}

test "closing a file input port writes nothing" {
    var recording: RecordingHost = .{};
    defer recording.deinit();
    var heap: Heap = .init(std.testing.allocator, .{});
    defer heap.deinit();
    heap.files = recording.host();
    const p = try heap.createFilePort(.input, .binary, 4);
    p.backing.file.id = 3;
    p.open = true;
    p.backing.file.len = 4;
    heap.closeFile(p);
    try std.testing.expectEqual(0, recording.written.items.len);
    try std.testing.expectEqualSlices(u32, &.{3}, recording.closed.items);
}

test "resizing the buffer of a file input port keeps what it has not read, and accounts for the new size" {
    var heap: Heap = .init(std.testing.allocator, .{ .limit = cellBytes(Port) + 16 });
    defer heap.deinit();
    const p = try heap.createFilePort(.input, .textual, 8);
    const file = &p.backing.file;
    @memcpy(file.buffer, "abcdefgh");
    file.len = 8;
    file.pos = 3;
    try heap.resizeFileBuffer(p, 16);
    try std.testing.expectEqual(16, file.buffer.len);
    try std.testing.expectEqualStrings("defgh", file.buffer[file.pos..file.len]);
    try std.testing.expectEqual(0, file.pos);
    try std.testing.expectEqual(cellBytes(Port) + 16, heap.accounted);
    // 上限を超える伸長は断られ、ポートも計上も元のままである。
    try std.testing.expectError(error.HeapLimit, heap.resizeFileBuffer(p, 17));
    try std.testing.expectEqual(16, file.buffer.len);
    try std.testing.expectEqual(cellBytes(Port) + 16, heap.accounted);
    // 縮めると、計上も戻る。
    try heap.resizeFileBuffer(p, 5);
    try std.testing.expectEqual(5, file.buffer.len);
    try std.testing.expectEqualStrings("defgh", file.buffer[0..file.len]);
    try std.testing.expectEqual(cellBytes(Port) + 5, heap.accounted);
}

test "a file port is held to the limit by its buffer, and a failure leaves the account as it was" {
    var heap: Heap = .init(std.testing.allocator, .{ .limit = cellBytes(Port) + 16 });
    defer heap.deinit();
    try std.testing.expectError(error.HeapLimit, heap.createFilePort(.input, .binary, 17));
    try std.testing.expectEqual(0, heap.accounted);
    _ = try heap.createFilePort(.input, .binary, 16);
    try std.testing.expectEqual(cellBytes(Port) + 16, heap.accounted);
}

test "when the cell cannot be allocated the buffer of a file port is given back" {
    var failing: std.testing.FailingAllocator = .init(std.testing.allocator, .{ .fail_index = 1 });
    var heap: Heap = .init(failing.allocator(), .{});
    defer heap.deinit();
    // 1回目の確保はバッファ、2回目はセルで、これが失敗する。
    try std.testing.expectError(error.OutOfMemory, heap.createFilePort(.output, .textual, 8));
    try std.testing.expectEqual(0, heap.accounted);
    try std.testing.expectEqual(0, heap.count);
    try std.testing.expectEqual(1, failing.deallocations);
}

test "a requested collection is due at once, and the collection takes the request back" {
    var heap: Heap = .init(std.testing.allocator, .{ .min_threshold = 1 << 20 });
    defer heap.deinit();
    try std.testing.expect(!heap.shouldCollect());
    heap.collect_requested = true;
    try std.testing.expect(heap.shouldCollect());
    heap.collect(TestRoots{});
    // 下ろさないと、以後の境目のたびに回収が走り、プログラムが遅くなり続ける。
    try std.testing.expect(!heap.collect_requested);
    try std.testing.expect(!heap.shouldCollect());
}

test "a console port is held to the limit by its cell" {
    var heap: Heap = .init(std.testing.allocator, .{ .limit = cellBytes(Port) });
    defer heap.deinit();
    _ = try heap.createConsolePort(.output);
    try std.testing.expectError(error.HeapLimit, heap.createConsolePort(.output));
    try std.testing.expectEqual(cellBytes(Port), heap.accounted);
}

test "multipleValuesFit holds exactly when the cell and the values fit under the limit" {
    const count = 5;
    const exact = cellBytes(MultipleValues) + count * @sizeOf(Value);
    var heap: Heap = .init(std.testing.allocator, .{ .limit = exact, .min_threshold = 1 << 20 });
    defer heap.deinit();
    try std.testing.expect(heap.multipleValuesFit(.limit, count));
    try std.testing.expect(!heap.multipleValuesFit(.limit, count + 1));
    // 1バイト足りない上限では収まらない。
    var short: Heap = .init(std.testing.allocator, .{ .limit = exact - 1, .min_threshold = 1 << 20 });
    defer short.deinit();
    try std.testing.expect(!short.multipleValuesFit(.limit, count));
    // 検査と確保は同じ境目である。
    var items: [count]Value = @splat(.unspecified_value);
    _ = try heap.createMultipleValuesIn(.limit, &items);
    try std.testing.expect(!heap.multipleValuesFit(.limit, 0));
    // 桁あふれする個数は収まらない。
    try std.testing.expect(!heap.multipleValuesFit(.raise_reserve, std.math.maxInt(usize)));
}
