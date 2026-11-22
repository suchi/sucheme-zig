//! The WebAssembly boundary of the interpreter (docs/design/platform-and-web.md).
//!
//! `wasm32-freestanding` 向けのビルドのルート。ホスト(ブラウザの Worker や Node.js)が
//! 呼べる関数を `export` で公開し、設計文書の状態コードで結果を返す。
//! スライス 1i が実装するのは、設計のエクスポートの部分集合である
//! (docs/plans/0008-slice-1i-wasm-web-ui.md)。歩数ごとに制御を戻す評価(`sucheme_step`、
//! `sucheme_abort`)はスライス 8e-2 で、入力の待ち(`sucheme_provide_input`、
//! `sucheme_provide_eof`)はスライス 8f-1 で足した。
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
    const more: i32 = 1;
    const waiting_input: i32 = 2;
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

/// Whether an evaluation `sucheme_eval_begin` started has not finished: `sucheme_step` goes
/// on with it, and `sucheme_abort` drops it (status 1).
/// Why: 評価は歩数ごとに制御を戻すので、評価の間、入力の写しとアリーナをここに持つ。
/// ホストの領域は `sucheme_eval_begin` が戻るとホストが返すので、読み手は写しを指す。
var evaluating = false;
/// Whether the evaluation stopped because a read waits for input (status 2), so that
/// `sucheme_provide_input` and `sucheme_provide_eof` may be called.
/// Why: 入力は、読み取りが待っているときだけ受け取る。待っていないときに渡された入力を受け取ると、
/// ホストの呼び出しの順序の誤りが、プログラムの読み取りの結果に紛れる。
var waiting = false;
var eval_arena: std.heap.ArenaAllocator = undefined;
var eval_source: []u8 = &.{};

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
    // コンソールの入力は、ホストが渡す。読み取りは、空で終端も無ければ待つ。
    interp.useHostInput();
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
    dropEvaluation();
    interp.deinit();
    unrecoverable = false;
    exited = false;
    interp.initWithOptions(allocator, .{ .limit = limit }) catch {
        initialized = false;
        allocator.free(output);
        output = &.{};
        return Status.out_of_memory;
    };
    interp.useHostInput();
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

/// Starts evaluating every expression of the input, and runs what needs no machine step.
/// 結果は出力バッファに書く。
///
/// 返す値は 1(評価が続いている。`sucheme_step` で進める)、0(完了)、-1(Scheme のエラー。`error: ...` の一行を出力に書く)、
/// -2(回復不能。送出のための予約も尽きた。`error: ...` の一行を出力に書き、以後は
/// `sucheme_reset` だけを受け付ける)、-3(不正な UTF-8。位置を出力に書き、状態は変えない)、
/// -4(-2 か -6 のあとで `sucheme_reset` の前に、または前の評価が続いている間に呼ばれた。状態は
/// 変えない)、-5、
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
    if (rejectInvalidUtf8(source)) return Status.invalid_utf8;
    if (evaluating) {
        appendTail(&out, output, "error: an evaluation is in progress; call sucheme_step or sucheme_abort\n");
        return Status.wrong_order;
    }
    eval_source = allocator.dupe(u8, source) catch {
        appendTail(&out, output, "error: out of memory\n");
        return Status.scheme_error;
    };
    eval_arena = .init(allocator);
    interp.ctx.heap.command_line = if (command_line.items.len == 0) &.{sucheme.name} else command_line.items;
    interp.beginEval(eval_arena.allocator(), eval_source, &out) catch |e| {
        freeEvaluation();
        return failed(e);
    };
    evaluating = true;
    // 歩数を使わずに済む入力(空、コメントだけ、ライブラリの宣言)は、ここで 0 になる。
    return advance(0);
}

/// Whether `bytes` is not valid UTF-8; if so, writes where to the output.
fn rejectInvalidUtf8(bytes: []const u8) bool {
    const at = firstInvalidUtf8(bytes) orelse return false;
    var buf: [96]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "error: invalid UTF-8 at byte {d}\n", .{at}) catch unreachable;
    appendTail(&out, output, text);
    return true;
}

/// Releases the copy of the input and the arena of the evaluation.
fn freeEvaluation() void {
    waiting = false;
    eval_arena.deinit();
    allocator.free(eval_source);
    eval_source = &.{};
    evaluating = false;
}

/// Drops the evaluation in progress, if there is one.
/// 定義と、ここまでの出力は残る(`Interpreter.abortEval`)。
fn dropEvaluation() void {
    if (!evaluating) return;
    interp.abortEval();
    freeEvaluation();
}

/// The status code of an evaluation that ended with the error `e`, after it wrote the
/// description to the output.
fn failed(e: sucheme.Error) i32 {
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
}

/// Runs the evaluation in progress for at most `budget` machine steps.
fn advance(budget: u64) i32 {
    // 待っていた読み取りは、ここでやり直される。まだ入力が無ければ、また待つ。
    waiting = false;
    const status = interp.stepEval(budget) catch |e| {
        freeEvaluation();
        return failed(e);
    };
    switch (status) {
        .done => {
            freeEvaluation();
            return Status.ok;
        },
        // 割り込みの要求は、ホストが立てる出口が無いので、ここには来ない。来ても、続きがある
        // ことには変わらない。
        .more, .interrupted => return Status.more,
        // 待っている読み取りは、何も消費していない。ホストが入力か終端を渡してから、`sucheme_step` が
        // 同じ読み取りをやり直す(docs/design/platform-and-web.md の再開可能性)。
        .needs_input => {
            waiting = true;
            return Status.waiting_input;
        },
    }
}

/// Advances the evaluation `sucheme_eval_begin` started by at most `budget` machine steps.
///
/// 返す値は 1(続きがある。また呼ぶ)、2(読み取りが入力を待っている。`sucheme_provide_input` か
/// `sucheme_provide_eof` で渡して、また呼ぶ)、0(完了)、-1(Scheme のエラー)、-2(回復不能)、
/// -6(`exit`)、-4(評価が無いときに呼んだ。状態は変えない)、-5。予算 0 は、何も進めずに
/// 1 を返す。待っているときに、入力を渡さずに呼んでも、待っている読み取りをやり直すだけで、
/// 入力が無ければまた 2 を返す。出力は、1歩ごとに取り出してよい(`sucheme_output_len`)。
export fn sucheme_step(budget: u32) i32 {
    if (!initialized) {
        appendTail(&early, &early_buffer, "error: the interpreter is not initialized\n");
        return Status.not_initialized;
    }
    if (!evaluating) {
        appendTail(&out, output, "error: no evaluation is in progress; call sucheme_eval_begin\n");
        return Status.wrong_order;
    }
    return advance(budget);
}

/// Gives the read that waits for input (status 2) the bytes of (ptr, len), which are copied.
///
/// 返す値は 1(受け取った。`sucheme_step` で続ける)、-1(入力を保持できなかった。評価は捨て、
/// 定義は残る。説明を出力に書く)、-3(不正な UTF-8。位置を出力に書き、状態は変えない)、
/// -4(読み取りが待っていないときに呼んだ。状態は変えない)、-5、-8。長さ 0 は、何も渡さず、
/// 読み取りは待ったままである(空行は、改行1つを渡す)。1回の読み取りより長い分は、WASM 側が
/// 保持し、次の読み取りが先に読む。保持する領域はヒープの上限に数える。
export fn sucheme_provide_input(ptr: u32, len: u32) i32 {
    if (!initialized) {
        appendTail(&early, &early_buffer, "error: the interpreter is not initialized\n");
        return Status.not_initialized;
    }
    if (!insideRegion(ptr, len)) {
        appendTail(&out, output, "error: the region was not returned by sucheme_alloc\n");
        return Status.bad_region;
    }
    const bytes: []const u8 = if (len == 0) &.{} else blk: {
        const p: [*]const u8 = @ptrFromInt(ptr);
        break :blk p[0..len];
    };
    if (rejectInvalidUtf8(bytes)) return Status.invalid_utf8;
    if (!waiting) {
        appendTail(&out, output, "error: no read is waiting for input; call sucheme_step\n");
        return Status.wrong_order;
    }
    interp.provideInput(bytes) catch |e| {
        // Why: 入力を保持できなかった読み取りは、続けられない。評価を捨てる(定義は残る)。
        dropEvaluation();
        var buf: [64]u8 = undefined;
        appendTail(&out, output, sucheme.errorLine(&buf, if (e == error.HeapLimit) "heap limit exceeded" else "out of memory"));
        return Status.scheme_error;
    };
    return Status.more;
}

/// Says that the console has no more input: the read that waits, and every read after it, gets
/// the end of file.
///
/// 返す値は 1(受け取った。`sucheme_step` で続ける)、-4(読み取りが待っていないときに呼んだ。状態は
/// 変えない)、-5。終端のあとに渡した入力は捨てる。終端は、`sucheme_reset` まで残り、あとの評価の
/// 読み取りも、終端を受け取る。
export fn sucheme_provide_eof() i32 {
    if (!initialized) {
        appendTail(&early, &early_buffer, "error: the interpreter is not initialized\n");
        return Status.not_initialized;
    }
    if (!waiting) {
        appendTail(&out, output, "error: no read is waiting for input; call sucheme_step\n");
        return Status.wrong_order;
    }
    interp.provideEof();
    return Status.more;
}

/// Drops the evaluation `sucheme_eval_begin` started and `sucheme_step` has not finished.
///
/// 返す値は 0(捨てた)、-4(評価が無い。状態は変えない)、-5。それまでの定義と出力は残り、
/// 次に `sucheme_eval_begin` を呼べる。実行中の1歩の途中では呼べないので、ホストは
/// `sucheme_step` が戻ったあとに呼ぶ。
export fn sucheme_abort() i32 {
    if (!initialized) {
        appendTail(&early, &early_buffer, "error: the interpreter is not initialized\n");
        return Status.not_initialized;
    }
    if (!evaluating) {
        appendTail(&out, output, "error: no evaluation is in progress; call sucheme_eval_begin\n");
        return Status.wrong_order;
    }
    dropEvaluation();
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
    // 評価の間は、機械が `(command-line)` の行を指すので、置き換えない。
    if (evaluating) return 0;
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
