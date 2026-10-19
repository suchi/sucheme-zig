//! The GC heap: where the objects of a running program live
//! (docs/design/runtime.md, ADR-0003).
//!
//! すべてのオブジェクトは `Cell` である。ヘッダの後ろにオブジェクト本体が続く。
//! ヘッダは1本のリストにつながれていて、スイープはこのリストをたどる。ヒープは、
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
    /// How many objects the marking keeps to scan.
    /// これを超えて待つオブジェクトがあっても、マークは止まらず、ヒープを走査し直して
    /// 拾う(`Marker` を参照)。テストは 0 にして、再走査の経路を走らせる。
    work_capacity: usize = 4096,
    /// Ask for a collection at every safe point of the start of a run, and less
    /// and less often as it goes on (see `stress_ramp`).
    /// セーフポイントが挙げ忘れたルートは、運よく残ることなく、すぐに解放される。
    /// そのためテストは機械をこのモードで動かす(ADR-0031)。
    stress: bool = false,
    /// How many bytes past the limit an allocation for raising may take (see
    /// `Budget.raise_reserve`).
    raise_reserve: usize = default_raise_reserve,
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
    next: ?*Header,
    /// An index into `object_types`.
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
/// a multiple-values object, the limbs of a bignum.
/// ペイロードはセルとは別に確保され、セルと一緒に返される。
fn payloadBytes(comptime T: type, object: *const T) usize {
    return switch (T) {
        Frame => object.values.len * @sizeOf(Value),
        String => object.bytes.len,
        Vector => object.items.len * @sizeOf(Value),
        Bytevector => object.bytes.len,
        Record => object.fields.len * @sizeOf(Value),
        MultipleValues => object.items.len * @sizeOf(Value),
        Bignum => object.limbs.len * @sizeOf(Limb),
        else => 0,
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
    /// Whether the collection that last ran left the heap too full to go on.
    /// 生きているものが上限との余裕の内側まで来ているので、GC で何をしても、次の確保は
    /// 失敗する。
    exhausted: bool = false,
    /// How many collections have run.
    collections: usize = 0,
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
    external_refused: bool = false,
    /// The symbols: each name is interned once, and named by a `SymbolId`.
    symbols: symbol.Table = .{},

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
    /// ペイロードを持つオブジェクトは、専用の関数 `createFrame`、`createString`、
    /// `createVector`、`createRecord`、`createMultipleValuesIn` で作る。
    pub fn create(self: *Heap, comptime T: type, value: T) Error!*T {
        return self.createIn(.limit, T, value);
    }

    /// A new object holding `value`, held to `budget`.
    pub fn createIn(self: *Heap, budget: Budget, comptime T: type, value: T) Error!*T {
        comptime std.debug.assert(T != Frame and T != String and T != Vector and T != Bytevector and T != Record and T != MultipleValues);
        try self.reserve(budget, cellBytes(T));
        const cell = try self.backing.create(Cell(T));
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
        const cell = try self.backing.create(Cell(Frame));
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
        const cell = try self.backing.create(Cell(String));
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
        const cell = try self.backing.create(Cell(Vector));
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
        const cell = try self.backing.create(Cell(Vector));
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
        const cell = try self.backing.create(Cell(Bignum));
        cell.value = .{ .limbs = copy, .positive = n.positive };
        self.link(Bignum, cell, total);
        return &cell.value;
    }

    /// Puts `bytes`, which the bytevector will own, in a new cell.
    /// セルを確保できなければ、呼び出し側の `errdefer` がペイロードを返す。
    fn linkBytevector(self: *Heap, bytes: []u8, total: usize) Error!*Bytevector {
        const cell = try self.backing.create(Cell(Bytevector));
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
        const cell = try self.backing.create(Cell(Record));
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
        const cell = try self.backing.create(Cell(MultipleValues));
        cell.value = .{ .items = copy };
        self.link(MultipleValues, cell, total);
        return &cell.value;
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
        return self.accounted +| self.symbols.charged;
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
        self.sweep();
        self.symbols.sweep(self.backing);
        self.collections += 1;
        self.steps = 0;
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

    /// The number of objects of type `T` in the heap.
    /// テストが、ある種類のオブジェクトが回収されたか残っているかを、そのオブジェクトの
    /// 中身を読まずに確かめるためにある。
    pub fn countOf(self: *const Heap, comptime T: type) usize {
        var n: usize = 0;
        var it = self.objects;
        while (it) |header| : (it = header.next) {
            if (header.kind == kindOf(T)) n += 1;
        }
        return n;
    }

    fn link(self: *Heap, comptime T: type, cell: *Cell(T), bytes: usize) void {
        cell.header = .{ .next = self.objects, .kind = kindOf(T), .marked = false, .immutable = false };
        self.objects = &cell.header;
        self.accounted += bytes;
        self.count += 1;
        if (self.accounted > self.peak) self.peak = self.accounted;
    }

    /// Gives an object and its payload back to the allocator, and takes them
    /// off the account.
    /// ヘッダは、呼ぶ前にリストから外しておくこと。
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
                    else => {},
                }
                self.backing.destroy(cell);
                return;
            }
        }
        unreachable;
    }
};

/// The marking of one collection.
/// `roots` がプログラムの出発点となる値を渡し、`finish` がそこからたどれるすべてに
/// 到達する。
///
/// オブジェクトに到達するとマークを付け、余地があれば、後で走査するためのリストに
/// 載せる。走査すると、そのオブジェクトの参照先に到達する。リストの容量は、
/// オプションで決まる。到達したときリストが満杯なら、マークだけ付けて、取りこぼした
/// ことを記録する。`finish` は、取りこぼしがなくなるまで、ヒープ内のマーク済みの
/// 全オブジェクトを走査し直す。マーク済みのオブジェクトは、リストに載れば順に、
/// 載らなければ再走査で走査されるので、漏れるものはない。リストの大きさが変えるのは、
/// マークにかかる時間であって、マークする対象ではない。
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
    try std.testing.expect(heap.objects == null);
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
    // ルートは継続だけで、残りはそこからたどって到達する。
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
