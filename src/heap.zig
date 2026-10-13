//! The GC heap: where the objects of a running program live
//! (docs/design/runtime.md, ADR-0003).
//!
//! すべてのオブジェクトは `Cell` である。ヘッダの後ろにオブジェクト本体が続く。
//! ヘッダは1本のリストにつながれていて、スイープはこのリストをたどる。ヒープは、
//! セルと、セルが所有するペイロードのバイト数を計上し、計上量が上限を超える確保を
//! 拒否する。ただし送出のための確保(`Budget.raise_reserve`)は、上限を予約の分だけ
//! 超えてよい(ADR-0035)。コードとシンボルを置くインタプリタのアリーナは、計上の外にある。
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
const SymbolId = @import("symbol.zig").SymbolId;
const trace = @import("trace.zig");

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
/// 段階2のスライス 2b の初期値である。いま予約から確保するのは、条件オブジェクトと
/// そのメッセージだけで、メッセージが約 4000 バイトまでなら収まる。ハンドラと巻き戻しの
/// 確保地点が加わる 2d と 2e で測り直し、2e で決める(docs/design/open-questions.md)。
pub const default_raise_reserve: usize = 4 * 1024;

/// What an allocation is held to.
/// 送出のための予約領域(docs/design/runtime.md)は、計上を別に持たない。予約から
/// 確保する地点に、上限を予約の分だけ超えることを許す形にしてある(ADR-0035)。
pub const Budget = enum {
    /// The limit. Every allocation but those for raising is held to it.
    limit,
    /// The limit and the reserve past it, for what raising an error must make
    /// even when the heap is at the limit: a condition and its message.
    /// 呼び出し側の確保地点で選ぶ。確保したものは、ほかと同じ計上に入り、同じ
    /// スイープで回収される。
    raise_reserve,
};

/// The most a host may ask the heap to account for: 1 GiB.
/// wasm32 の線形メモリは全体で 4 GiB であり、計上は実メモリの約半分なので、
/// ホストが 4 GiB に近い値を渡すと、上限に届く前に実メモリが尽きて trap する。
/// それを順序立ったエラー(`heap limit exceeded`)にするため、ホストの指定をここで丸める。
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
pub fn cellBytes(comptime T: type) usize {
    return @sizeOf(Cell(T));
}

/// The bytes the object owns beyond its cell: the slots of a frame, the bytes
/// of a string, the elements of a vector.
/// ペイロードはセルとは別に確保され、セルと一緒に返される。
fn payloadBytes(comptime T: type, object: *const T) usize {
    return switch (T) {
        Frame => object.values.len * @sizeOf(Value),
        String => object.bytes.len,
        Vector => object.items.len * @sizeOf(Value),
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
/// 例外が1つある。`apply` は、最後の引数のリストの長さに比例する量を1ステップの中で
/// 確保し、この余裕を超えうる(ADR-0031 の 2026-10-13 の追記)。
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
    /// ペイロードを持つオブジェクトは、専用の関数 `createFrame`、`createString`、
    /// `createVector` で作る。
    pub fn create(self: *Heap, comptime T: type, value: T) Error!*T {
        return self.createIn(.limit, T, value);
    }

    /// A new object holding `value`, held to `budget`.
    pub fn createIn(self: *Heap, budget: Budget, comptime T: type, value: T) Error!*T {
        comptime std.debug.assert(T != Frame and T != String and T != Vector);
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
        const bytes = try self.reserveWithPayload(.limit, Frame, size, @sizeOf(Value));
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

    /// Puts `bytes`, which the string will own, in a new cell.
    /// セルを確保できなければ、呼び出し側の `errdefer` がペイロードを返す。
    fn linkString(self: *Heap, bytes: []u8, total: usize) Error!*String {
        const cell = try self.backing.create(Cell(String));
        // 文字列を作る経路はすべてここを通るので、フラグの計算はここだけにある。
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
        return self.accounted >= self.threshold;
    }

    /// Frees every object that cannot be reached from `roots`.
    ///
    /// `roots.mark(marker)` が、プログラムの出発点をマーカに伝える。ほかにルートは
    /// ないので、`roots` が挙げるもの以外のどこにも値が保持されていない場所、つまり
    /// 機械の2つのステップの間でだけ呼ぶこと(ADR-0031)。
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

    /// Fails with `HeapLimit` when `bytes` more would pass what `budget` allows.
    fn reserve(self: *const Heap, budget: Budget, bytes: usize) error{HeapLimit}!void {
        const total = std.math.add(usize, self.accounted, bytes) catch return error.HeapLimit;
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
        cell.header = .{ .next = self.objects, .kind = kindOf(T), .marked = false };
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
    /// シンボル表はまだ弱参照ではないので、記録するものはない。
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
