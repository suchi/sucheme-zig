//! The WebAssembly boundary of the interpreter (docs/design/platform-and-web.md).
//!
//! `wasm32-freestanding` 向けのビルドのルート。ホスト(ブラウザの Worker や Node.js)が
//! 呼べる関数を `export` で公開し、設計文書の状態コードで結果を返す。
//! スライス 1i が実装するのは、設計のエクスポートの部分集合である
//! (docs/plans/0008-slice-1i-wasm-web-ui.md)。再開可能な機械と入力の待ちは後のスライスで足す。
//!
//! ホストから受け取る文字列は `sucheme_alloc` で確保した領域に置かれ、UTF-8 として
//! 妥当なものだけが処理系に入る。出力は固定の大きさのバッファに書き、ホストが読んで
//! `sucheme_output_clear` で空にする。

const std = @import("std");
const sucheme = @import("sucheme");

/// A write to the standard error the host provides.
/// 1i ではパニックのときだけ使う。
extern "env" fn host_write_stderr(ptr: [*]const u8, len: u32) void;

pub const panic = std.debug.FullPanic(wasmPanic);

fn wasmPanic(msg: []const u8, _: ?usize) noreturn {
    host_write_stderr(msg.ptr, @intCast(msg.len));
    @trap();
}

/// Status codes (the table of the design document).
/// エクスポートした関数が返す状態コードを置く(-2 は回復不能、-4 は呼び出しの順序の誤り)。
const Status = struct {
    const ok: i32 = 0;
    const scheme_error: i32 = -1;
    const unrecoverable: i32 = -2;
    const invalid_utf8: i32 = -3;
    const wrong_order: i32 = -4;
    const not_initialized: i32 = -5;
    const exited: i32 = -6;
    const out_of_memory: i32 = -7;
    const bad_region: i32 = -8;
};

/// The size of the output buffer.
/// 初期化のときに1回だけ確保し、伸ばさない。
const output_capacity = 256 * 1024;

// エントリ層である。ここで直接確保するもの(出力バッファと、`sucheme_alloc` が返す
// ホストの入力領域)は、docs/design/architecture.md の確保点の一元化の対象外にあり、
// ヒープの上限(`heap_limit_bytes`)に計上されない。docs/design/runtime.md の計上の対象は
// この2つを挙げているので設計との食い違いだが、エントリ層の例外として認めた
// (docs/adr/0038-wasm-entry-layer-allocations-outside-the-accounting.md)。
// 出力バッファは固定の大きさで伸びないが、入力領域は呼び出しごとに確保され、
// 起動と終了に限らない。入力領域ごとの記録(`regions`)と、評価ごとのアリーナも、
// 同じ確保元から直接確保し、計上されない。Scheme の値やそのペイロードは、ここでは確保しない。
const allocator = std.heap.wasm_allocator;

var interp: sucheme.Interpreter = undefined;
var initialized = false;
/// Whether an evaluation used up the reserve for raising, so that only
/// `sucheme_reset` may be called until it is cleared (status -2).
/// Why: 予約も尽きた状態は、条件を作れずに送出できなかった状態で、回復不能として扱う
/// (docs/design/runtime.md の上限超過と確保の失敗、docs/design/platform-and-web.md の
/// 状態コードの表)。上限超過(-1)と分けるのは、上限超過がハンドラで捕まえられる Scheme の
/// エラーだからである。
var unrecoverable = false;
/// Whether the program called `exit` or `emergency-exit`, so that only
/// `sucheme_reset` may be called until it is cleared (status -6).
/// Why: 終わったプログラムの続きを、同じインタプリタで評価しない(docs/design/platform-and-web.md
/// の状態コードの表)。
var exited = false;
/// The exit code of the last status -6, or 0 when there has been none
/// (`sucheme_exit_code`).
var exit_code: i32 = 0;

/// The command line `sucheme_set_command_line` set: the bytes it was given, and
/// the lines of them, or nothing for the name of the interpreter alone.
/// Why: ホストの領域はホストが返すので、写しを持つ。`Heap.command_line` に置くのは
/// `sucheme_eval_begin` で、評価の途中で `(command-line)` が変わらない。
var command_text: []u8 = &.{};
var command_line: std.ArrayList([]const u8) = .empty;

/// The output buffer and the writer into it.
/// `out.end` が出力の長さである。
var output: []u8 = &.{};
var out: std.Io.Writer = undefined;

/// A small static buffer for output written before initialization.
/// `sucheme_init` が失敗したときの説明もここに入る。
var early_buffer: [512]u8 = undefined;
var early: std.Io.Writer = std.Io.Writer.fixed(&early_buffer);

/// The record of the regions `sucheme_alloc` handed out.
/// (ptr, len) の検査と、`sucheme_free` の突き合わせに使う。
const Region = struct { ptr: u32, len: u32, size: u32 };
var regions: std.ArrayList(Region) = .empty;

fn currentOutput() *std.Io.Writer {
    return if (initialized) &out else &early;
}

/// Writes `bytes` to the output, as much as fits.
/// 溢れるときは、手前の出力の末尾を削って `bytes` を残す。エラーの一行(短い)を
/// 確実に残すために使う。
fn appendTail(w: *std.Io.Writer, buffer: []u8, bytes: []const u8) void {
    const len = @min(bytes.len, buffer.len);
    if (w.end + len > buffer.len) w.end = buffer.len - len;
    @memcpy(buffer[w.end..][0..len], bytes[bytes.len - len ..]);
    w.end += len;
}

fn outputBuffer() []u8 {
    return if (initialized) output else &early_buffer;
}

fn addressOf(bytes: []const u8) u32 {
    return @intCast(@intFromPtr(bytes.ptr));
}

/// Initializes the interpreter.
/// `heap_limit_bytes` は GC ヒープの計上の上限である(0 なら既定)。
///
/// 1 GiB を超える値は 1 GiB に丸める(`heap.hostOptions`、`heap.max_host_limit`)。
export fn sucheme_init(heap_limit_bytes: u32) i32 {
    if (initialized) {
        appendTail(&out, output, "error: sucheme_init was called twice\n");
        return Status.wrong_order;
    }
    interp.initWithOptions(allocator, sucheme.heap.hostOptions(heap_limit_bytes)) catch {
        appendTail(&early, &early_buffer, "error: out of memory while initializing\n");
        return Status.out_of_memory;
    };
    output = allocator.alloc(u8, output_capacity) catch {
        interp.deinit();
        appendTail(&early, &early_buffer, "error: out of memory for the output buffer\n");
        return Status.out_of_memory;
    };
    out = std.Io.Writer.fixed(output);
    initialized = true;
    return Status.ok;
}

/// Resets the interpreter to its state just after initialization.
///
/// `sucheme_alloc` で確保した領域はホストのものなので、触らない。リセットのあとも
/// `sucheme_free` で返せる。記録を捨てると、返せなくなって漏れるうえ、返したときに
/// panic する。
export fn sucheme_reset() i32 {
    if (!initialized) {
        appendTail(&early, &early_buffer, "error: the interpreter is not initialized\n");
        return Status.not_initialized;
    }
    const limit = interp.ctx.heap.options.limit;
    interp.deinit();
    unrecoverable = false;
    exited = false;
    interp.initWithOptions(allocator, .{ .limit = limit }) catch {
        initialized = false;
        allocator.free(output);
        output = &.{};
        return Status.out_of_memory;
    };
    out.end = 0;
    return Status.ok;
}

/// Allocates a region for an input string.
/// 失敗と初期化前は 0 を返す。
export fn sucheme_alloc(len: u32) u32 {
    if (!initialized) return 0;
    const size = @max(len, 1);
    const bytes = allocator.alloc(u8, size) catch return 0;
    regions.append(allocator, .{ .ptr = addressOf(bytes), .len = len, .size = size }) catch {
        allocator.free(bytes);
        return 0;
    };
    return addressOf(bytes);
}

/// Returns a region that `sucheme_alloc` allocated.
/// `len` が確保時の値と違えば panic する。
export fn sucheme_free(ptr: u32, len: u32) void {
    if (!initialized) return;
    for (regions.items, 0..) |r, i| {
        if (r.ptr != ptr) continue;
        if (r.len != len) @panic("sucheme_free: len does not match the allocation");
        const p: [*]u8 = @ptrFromInt(ptr);
        allocator.free(p[0..r.size]);
        _ = regions.swapRemove(i);
        return;
    }
    @panic("sucheme_free: ptr was not returned by sucheme_alloc");
}

/// Whether (ptr, len) lies inside an allocated region.
/// 長さ 0 は常に収まる。
fn insideRegion(ptr: u32, len: u32) bool {
    if (len == 0) return true;
    for (regions.items) |r| {
        if (ptr >= r.ptr and @as(u64, ptr) + len <= @as(u64, r.ptr) + r.len) return true;
    }
    return false;
}

/// The position of the first byte that is not valid UTF-8.
/// 妥当なら null。
fn firstInvalidUtf8(bytes: []const u8) ?usize {
    var i: usize = 0;
    while (i < bytes.len) {
        const n = std.unicode.utf8ByteSequenceLength(bytes[i]) catch return i;
        if (i + n > bytes.len) return i;
        _ = std.unicode.utf8Decode(bytes[i..][0..n]) catch return i;
        i += n;
    }
    return null;
}

/// Evaluates every expression of the input and writes the results to the output buffer.
///
/// 返す値は 0(完了)、-1(Scheme のエラー。`error: ...` の一行を出力に書く)、
/// -2(回復不能。送出のための予約も尽きた。`error: ...` の一行を出力に書き、以後は
/// `sucheme_reset` だけを受け付ける)、-3(不正な UTF-8。位置を出力に書き、状態は変えない)、
/// -4(-2 か -6 のあとで `sucheme_reset` の前に呼ばれた。状態は変えない)、-5、
/// -6(プログラムが `exit` か `emergency-exit` を呼んだ。終了コードは `sucheme_exit_code` で取り、
/// 以後は `sucheme_reset` だけを受け付ける)、-8。
export fn sucheme_eval_begin(ptr: u32, len: u32) i32 {
    if (!initialized) {
        appendTail(&early, &early_buffer, "error: the interpreter is not initialized\n");
        return Status.not_initialized;
    }
    if (unrecoverable or exited) {
        appendTail(&out, output, "error: the interpreter cannot go on; call sucheme_reset\n");
        return Status.wrong_order;
    }
    if (!insideRegion(ptr, len)) {
        appendTail(&out, output, "error: the region was not returned by sucheme_alloc\n");
        return Status.bad_region;
    }
    const source: []const u8 = if (len == 0) &.{} else blk: {
        const p: [*]const u8 = @ptrFromInt(ptr);
        break :blk p[0..len];
    };
    if (firstInvalidUtf8(source)) |at| {
        var buf: [96]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, "error: invalid UTF-8 at byte {d}\n", .{at}) catch unreachable;
        appendTail(&out, output, text);
        return Status.invalid_utf8;
    }
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    interp.ctx.heap.command_line = if (command_line.items.len == 0) &.{sucheme.name} else command_line.items;
    interp.evalPrint(arena.allocator(), source, &out) catch |e| {
        // 終了コードは出力に書かない。`exit` が呼ぶ `after` の出力と混ざるからである
        // (docs/design/platform-and-web.md)。
        if (e == error.Exited) {
            exited = true;
            exit_code = interp.ctx.exit_code;
            return Status.exited;
        }
        var buf: [320]u8 = undefined;
        const message = switch (e) {
            error.WriteFailed => "output buffer full",
            else => interp.diagnostic(),
        };
        appendTail(&out, output, sucheme.errorLine(&buf, message));
        if (e == error.ReserveExhausted) {
            unrecoverable = true;
            return Status.unrecoverable;
        }
        return Status.scheme_error;
    };
    return Status.ok;
}

/// Sets the command line that `(command-line)` gives from the next
/// `sucheme_eval_begin`: the UTF-8 lines of (ptr, len), the name of the program
/// first, or, for an empty one, the name of the interpreter alone.
/// 返す値は 1(設定した)か 0(妥当な UTF-8 でない、`sucheme_alloc` の領域でない、確保できない。
/// 設定は変えず、出力バッファにも書かない。docs/design/platform-and-web.md の検証の表)。状態は
/// 変えないので、いつ呼んでもよい。
/// 行は改行で区切り、末尾の改行は区切りとして扱わない(`"a\nb\n"` は2行)。
export fn sucheme_set_command_line(ptr: u32, len: u32) u32 {
    if (!initialized) return 0;
    if (!insideRegion(ptr, len)) return 0;
    const bytes: []const u8 = if (len == 0) &.{} else blk: {
        const p: [*]const u8 = @ptrFromInt(ptr);
        break :blk p[0..len];
    };
    if (!std.unicode.utf8ValidateSlice(bytes)) return 0;
    const text = allocator.dupe(u8, bytes) catch return 0;
    var lines: std.ArrayList([]const u8) = .empty;
    if (text.len != 0) {
        var it = std.mem.splitScalar(u8, if (text[text.len - 1] == '\n') text[0 .. text.len - 1] else text, '\n');
        while (it.next()) |line| lines.append(allocator, line) catch {
            lines.deinit(allocator);
            allocator.free(text);
            return 0;
        };
    }
    command_line.deinit(allocator);
    allocator.free(command_text);
    command_text = text;
    command_line = lines;
    return 1;
}

/// The exit code of the last status -6, or 0 when there has been none
/// (docs/design/platform-and-web.md, the table of `exit`).
export fn sucheme_exit_code() i32 {
    return exit_code;
}

export fn sucheme_output_ptr() u32 {
    return addressOf(outputBuffer());
}

export fn sucheme_output_len() u32 {
    return @intCast(currentOutput().end);
}

export fn sucheme_output_clear() void {
    currentOutput().end = 0;
}

export fn sucheme_version_ptr() u32 {
    return addressOf(sucheme.version);
}

export fn sucheme_version_len() u32 {
    return @intCast(sucheme.version.len);
}
