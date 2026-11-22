//! Fuzzing of the whole interpreter: read, expand and run any input.
//!
//! リーダのファジング(src/reader.zig)と分けて、別のテストのバイナリに置く
//! (計画書 docs/plans/0025-fuzzing-the-evaluator.md の合意を求める点の2)。1つのバイナリに
//! `std.testing.fuzz` を呼ぶテストを2つ置くと、探索の実行でファザーが進まなくなる
//! (src/reader.zig のファジングのテストの `Why:` コメント)。`zig build test --fuzz=<N>` は、
//! ファジングのテストを持つバイナリごとにファザーを1つずつ並べて走らせ、それぞれに同じ
//! 上限 N を渡す(Zig 0.17.0 の lib/compiler/Maker/Fuzz.zig と Maker/Step/Run.zig)。

const std = @import("std");
const sucheme = @import("sucheme");

/// The longest input one fuzz run reads, in bytes.
/// リーダの対象と同じ値にする。長い入力は探索を遅くするだけで、深さや個数に比例する誤りは、
/// 規模を試すテストが受け持つ。
const max_input = 1024;

/// The most steps one top-level form of an input may take.
/// 止まらない入力(`(let loop () (loop))` など)を、形式ごとに `error.StepLimit` で打ち切る
/// (ADR-0044)。初期入力のどれよりも十分に大きく、1回の実行を短く保つ値にする。
const step_limit = 100_000;

/// The heap limit of the interpreter of one fuzz run.
/// 確保が際限なく増える入力を、`error.HeapLimit` か Scheme の条件で打ち切る。標準環境
/// (`(scheme base)`)の読み込みも上限に数えるので(ADR-0039)、それが収まる大きさにする。
const heap_limit = 8 * 1024 * 1024;

/// The bytes of a chunk of cells.
/// Why: 確保の失敗を仕掛ける対象は、下の割り当て器への確保である。セルは大きなチャンクから
/// 切り出すので、既定の大きさでは、1 回の実行で下に届く確保が少なく、仕掛けた番号に届かない。
/// 最小の大きさ(ヒープが引き上げる)にして、セルの確保を、以前に近い頻度で下に届かせる。
const heap_chunk_bytes = 1;

/// How many bytes of results one fuzz run may write.
/// 書き出し先が満ちると `error.WriteFailed` になる。循環するデータの印字は、ここで止まる
/// (計画書 0024 の「残っていること」)。
const output_capacity = 4096;

/// A corpus entry that holds `text` as its input.
/// `Smith.slice` が読む形は、4 バイトのリトルエンディアンの長さに、その長さのバイト列が
/// 続くものである。
///
/// Why: 配列はコンパイル時に作る。実行時に作った配列のアドレスを返すと、関数が戻った
/// あとの死んだスタックを指し、初期入力がテストに届かない(src/reader.zig の `fuzzSeed`)。
fn seed(comptime text: []const u8) []const u8 {
    comptime std.debug.assert(text.len <= max_input);
    const bytes = comptime std.mem.toBytes(std.mem.nativeToLittle(u32, text.len)) ++ text[0..text.len].*;
    return &bytes;
}

/// An input whose result shows that the input was evaluated.
/// `fact` は、入力が評価器に届いたことを固定する(入力を捨てても定数の評価だけは通る)。
const input_fact = "(define (fact n) (if (= n 0) 1 (* n (fact (- n 1))))) (fact 20)";
/// An input that needs the standard environment.
/// `assv` は `(scheme base)` が Scheme で定義する(lib/sucheme/procedures.scm)。標準環境を
/// 作らずにコアだけで作ると、未束縛になって結果が出ない。
const input_assv = "(cond ((assv 2 '((1 . a) (2 . b))) => cdr) (else 'none))";
/// An input that passes the heap limit in one step.
/// ヒープの上限が効いて、診断が `heap limit exceeded` になることを固定する。条件として
/// 送出されたか、ホストの誤りで返ったかは、診断の文では見分けない。
const input_heap = "(make-vector 100000000)";

/// What `zig build test` checks the runs of some inputs ended with.
const expected = [_]struct { src: []const u8, out: []const u8, diagnostic: []const u8 }{
    .{ .src = input_fact, .out = "2432902008176640000\n", .diagnostic = "" },
    .{ .src = input_assv, .out = "b\n", .diagnostic = "" },
    .{ .src = input_heap, .out = "", .diagnostic = "1:1: heap limit exceeded" },
};

/// The inputs `zig build test` runs, as text.
/// 構文ごとに短い入力を置く。探索はここから広がる。取り込んだ準拠スイートの文面は使わない
/// (計画書 0025 の合意を求める点の3)。
const inputs = [_][]const u8{
    input_fact,
    "(define x 1) (set! x (+ x 1)) x",
    "((lambda (a . rest) (list a rest)) 1 2 3)",
    "(let loop ((i 0) (acc '())) (if (< i 5) (loop (+ i 1) (cons i acc)) acc))",
    "(let* ((a 1) (b (+ a 1))) (letrec ((even? (lambda (n) (if (= n 0) #t (odd? (- n 1))))) (odd? (lambda (n) (if (= n 0) #f (even? (- n 1)))))) (even? b)))",
    input_assv,
    "(case (* 2 3) ((2 3 5 7) 'prime) ((1 4 6 8 9) 'composite))",
    "(and 1 2 #f 3) (or #f 2) (when #t 'w) (unless #f 'u)",
    "(do ((v (make-vector 5)) (i 0 (+ i 1))) ((= i 5) v) (vector-set! v i i))",
    "(define-syntax swap! (syntax-rules () ((_ a b) (let ((tmp a)) (set! a b) (set! b tmp))))) (define p 1) (define q 2) (swap! p q) (list p q)",
    "(define-syntax my-or (syntax-rules () ((_) #f) ((_ e) e) ((_ e r ...) (let ((t e)) (if t t (my-or r ...)))))) (my-or #f 3)",
    "(let-syntax ((foo (syntax-rules () ((_ x) (* x x))))) (foo 4))",
    "(guard (e ((symbol? e) (list 'caught e)) ((string? e) e)) (raise 'oops))",
    "(with-exception-handler (lambda (e) 42) (lambda () (+ (raise-continuable 'c) 1)))",
    "(guard (e (#t (condition/report-string e))) (car '()))",
    "(error \"msg\" 1 2)",
    "(dynamic-wind (lambda () 'before) (lambda () 'during) (lambda () 'after))",
    "(+ 1 (call/cc (lambda (k) (k 41))))",
    "(call-with-values (lambda () (values 1 2 3)) list) (values)",
    "(define-record-type point (make-point x y) point? (x point-x) (y point-y set-point-y!)) (point-x (make-point 1 2))",
    "(string-append \"ab\" (string #\\c) (number->string 42)) (string->symbol \"s\") (string-ref \"abc\" 5)",
    "(vector-ref #(1 2 3) 1) (list->vector '(1 2)) (vector->list #(a b) 1) (bytevector 1 2 255)",
    "(exact->inexact 1/3) (expt 2 100) (exact (floor 2.5)) (/ 1 0)",
    "(apply + 1 2 '(3 4)) (map (lambda (x) (* x x)) '(1 2 3)) (for-each car '())",
    "(define c (list 1 2)) (set-cdr! (cdr c) c) c",
    "(let loop () (loop))",
    "(define (f) (cons 1 (f))) (f)",
    "(import (scheme base)) (define-library (lib) (export g) (import (scheme base)) (begin (define (g) 'g))) (import (lib)) (g)",
    "(quasiquote (1 (unquote (+ 1 1)) (unquote-splicing (list 3 4))))",
    "(delay (+ 1 2)) (force (delay (+ 1 2))) (make-parameter 1)",
    "(undefined-variable) (car) (1 2) (lambda) (if) (define)",
    "#0=(a . #0#) '#1=(b . #1#)",
    input_heap,
};

/// `inputs` as corpus entries.
const corpus: []const []const u8 = blk: {
    var seeds: [inputs.len][]const u8 = undefined;
    for (inputs, 0..) |text, i| seeds[i] = seed(text);
    const done = seeds;
    break :blk &done;
};

/// Where `run` writes down what it was given, for the test that checks the
/// corpus. The test passes null when it runs under `--fuzz`.
const Record = struct {
    /// テストランナーが、初期入力のあとに空の入力を 1 回走らせる。その分を含めて持つ。
    const capacity = inputs.len + 2;

    srcs: [capacity][max_input]u8 = undefined,
    lens: [capacity]usize = @splat(0),
    fail_ats: [capacity]u16 = @splat(0),
    /// Whether each run made an allocation fail.
    induced: [capacity]bool = @splat(false),
    /// The start of what each run wrote, and of the diagnostic it ended with.
    outs: [capacity][64]u8 = undefined,
    out_lens: [capacity]usize = @splat(0),
    diagnostics: [capacity][64]u8 = undefined,
    diagnostic_lens: [capacity]usize = @splat(0),
    /// How many runs there were, also those past `capacity`.
    count: usize = 0,

    fn add(self: *Record, src: []const u8, fail_at: u16) void {
        if (self.count < capacity) {
            @memcpy(self.srcs[self.count][0..src.len], src);
            self.lens[self.count] = src.len;
            self.fail_ats[self.count] = fail_at;
        }
        self.count += 1;
    }

    /// Writes down how the run `add` wrote down last ended.
    fn end(self: *Record, out: []const u8, diagnostic: []const u8, induced: bool) void {
        const i = self.count - 1;
        if (i >= capacity) return;
        self.induced[i] = induced;
        const o = @min(out.len, self.outs[i].len);
        @memcpy(self.outs[i][0..o], out[0..o]);
        self.out_lens[i] = o;
        const d = @min(diagnostic.len, self.diagnostics[i].len);
        @memcpy(self.diagnostics[i][0..d], diagnostic[0..d]);
        self.diagnostic_lens[i] = d;
    }
};

/// The latest allocation after the start a fuzz run may make fail.
/// ファザーが 0 から選び、0 なら失敗させない。初期入力は Smith の値を持たないので 0 で
/// 届き、出力の照合は失敗を混ぜずに走る。
const max_fail_at = 512;

/// What `evalOnce` saw.
const Outcome = struct {
    /// Whether an allocation was made to fail.
    induced: bool,
    /// How many allocations went through after the start before the one
    /// that failed, or null when none failed.
    failed_after: ?usize,
};

/// An allocator that makes one chosen allocation fail, and passes on the rest.
/// Why: std の `FailingAllocator` は、失敗させる番号に達すると、そのあとの確保をすべて失敗
/// させる(`alloc_index` を進めない)。ここで試したいのは1回だけの失敗で、失敗を捕まえて先に
/// 進む経路(`src/heap.zig` の作業スタックの確保など)が、そのあとの確保の成功を受けて一貫した
/// 状態を保つかも見る。数えるのは `alloc` だけで、`resize` と `remap` は失敗させない。
const OneShotFailure = struct {
    backing: std.mem.Allocator,
    /// How many more allocations succeed before the one that fails, or null
    /// when none is to fail.
    countdown: ?usize = null,
    /// How many allocations went through since `arm`.
    passed: usize = 0,
    /// Whether the chosen allocation has failed.
    induced: bool = false,
    /// How many allocations went through since `arm` before the one that
    /// failed.
    failed_after: ?usize = null,

    fn allocator(self: *OneShotFailure) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }

    /// Makes the `fail_at`-th allocation from now fail, or none when it is 0.
    fn arm(self: *OneShotFailure, fail_at: usize) void {
        self.countdown = if (fail_at == 0) null else fail_at - 1;
        self.passed = 0;
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *OneShotFailure = @ptrCast(@alignCast(ctx));
        if (self.countdown) |n| {
            if (n == 0) {
                self.countdown = null;
                self.induced = true;
                self.failed_after = self.passed;
                return null;
            }
            self.countdown = n - 1;
        }
        self.passed += 1;
        return self.backing.rawAlloc(len, alignment, ra);
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) bool {
        const self: *OneShotFailure = @ptrCast(@alignCast(ctx));
        return self.backing.rawResize(memory, alignment, new_len, ra);
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) ?[*]u8 {
        const self: *OneShotFailure = @ptrCast(@alignCast(ctx));
        return self.backing.rawRemap(memory, alignment, new_len, ra);
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *OneShotFailure = @ptrCast(@alignCast(ctx));
        self.backing.rawFree(memory, alignment, ra);
    }
};

/// One fuzz run: a fresh interpreter evaluates the input, then a constant.
/// 入力の後ろの Smith の値で、初期化のあとの確保を1回だけ失敗させる(`evalOnce`)。
fn run(record: ?*Record, smith: *std.testing.Smith) anyerror!void {
    var buf: [max_input]u8 = undefined;
    const src = buf[0..smith.slice(&buf)];
    const fail_at = smith.valueRangeAtMost(u16, 0, max_fail_at);
    if (record) |r| r.add(src, fail_at);
    _ = try evalOnce(record, src, fail_at, std.testing.allocator);
}

/// Evaluates `src` in a fresh interpreter on `backing`, making the
/// `fail_at`-th allocation after the start fail when it is not 0, then
/// evaluates a constant.
/// 見るのは次の4つである。パニックや安全検査の失敗が起きないこと(テストランナーが見る)。
/// 確保が漏れないこと(`std.testing.allocator` が見る)。失敗を混ぜなかったのに `evalPrint` が
/// `OutOfMemory` を返さないこと。上限はヒープに置いてあり、この割り当て器は断らないので、
/// `OutOfMemory` が返るのは、上限の外の確保が際限なく増えたときである。最後に、確保の失敗を
/// 含む誤りのあとも、インタプリタが使えることを、定数を評価して見る。定数にするのは、入力が
/// `+` などの名前を定義し直せるからである。
///
/// インタプリタは、実行のたびに `(scheme base)` つきで作り直す(計画書 0025 の合意を求める
/// 点の1)。前の入力の定義が残らないので、ファザーが保存した入力1つで誤りを再現できる。
/// ファイルは読まない(`files` が null)。初期化の途中と、`evalPrint` の作業用のアリーナの確保は
/// 失敗させない(計画書 0025 の「残っていること」)。`backing` は、ふつうは
/// `std.testing.allocator` である。テストは、仕掛けていない失敗を作るために、自分で失敗する
/// 割り当て器を渡す。
fn evalOnce(record: ?*Record, src: []const u8, fail_at: u16, backing: std.mem.Allocator) anyerror!Outcome {
    var failing: OneShotFailure = .{ .backing = backing };
    var interp: sucheme.Interpreter = undefined;
    try interp.initWithFiles(failing.allocator(), .{ .limit = heap_limit, .chunk_bytes = heap_chunk_bytes }, null);
    defer interp.deinit();
    interp.setStepLimit(step_limit);

    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var out_buf: [output_capacity]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_buf);
    failing.arm(fail_at);
    interp.evalPrint(arena.allocator(), src, &out) catch |e| switch (e) {
        error.OutOfMemory => if (!failing.induced) return e,
        else => {},
    };
    // 失敗する前に `evalPrint` が戻ったときは、仕掛けを外す。
    failing.countdown = null;
    if (record) |r| r.end(out.buffered(), interp.diagnostic(), failing.induced);

    var after_buf: [16]u8 = undefined;
    var after: std.Io.Writer = .fixed(&after_buf);
    try interp.evalPrint(arena.allocator(), "#t", &after);
    try std.testing.expectEqualStrings("#t\n", after.buffered());
    return .{ .induced = failing.induced, .failed_after = failing.failed_after };
}

/// Runs the fuzz test on `corpus`.
/// 通常の `zig build test` では初期入力だけを通る。`--fuzz=<N>` のときは、そこから
/// 探索を広げる。
fn runFuzz(record: ?*Record) anyerror!void {
    try std.testing.fuzz(record, run, .{ .corpus = corpus });
}

test "fuzz: the interpreter ends any input with a value or a specified error, and stays usable" {
    // Why: 届いた入力を確かめるテストを別にすると、`std.testing.fuzz` を呼ぶテストが 2 つに
    // なり、探索の実行でファザーが進まなくなる(src/reader.zig の同じ形のテストを参照)。
    if (@import("builtin").fuzz) return runFuzz(null);
    // 初期入力が意図どおりに届かなければ、このテストは何も固定しないまま緑になる。
    // `run` が受け取った入力を書き留めて、`inputs` と比べる。
    var record: Record = .{};
    try runFuzz(&record);
    // `inputs` の全件が順に届き、最後にテストランナーの空の入力が 1 回付く。
    try std.testing.expectEqual(inputs.len + 1, record.count);
    for (inputs, 0..) |text, i| {
        try std.testing.expectEqualSlices(u8, text, record.srcs[i][0..record.lens[i]]);
        // 初期入力の実行では、確保を失敗させない。
        try std.testing.expectEqual(0, record.fail_ats[i]);
        try std.testing.expect(!record.induced[i]);
    }
    try std.testing.expectEqual(0, record.lens[inputs.len]);
    // 入力が届いても、評価されなければ、上の照合は緑のままである。標準環境とヒープの上限が
    // 効いていることも含めて、いくつかの入力の結果を見る。
    for (expected) |e| {
        const i = for (inputs, 0..) |text, j| {
            if (std.mem.eql(u8, text, e.src)) break j;
        } else return error.TestUnexpectedResult;
        try std.testing.expectEqualStrings(e.out, record.outs[i][0..record.out_lens[i]]);
        try std.testing.expectEqualStrings(e.diagnostic, record.diagnostics[i][0..record.diagnostic_lens[i]]);
    }
}

test "an allocation that fails in the middle of an input leaves the interpreter usable" {
    // 初期入力は確保を失敗させずに走るので、失敗を混ぜる経路は、ここで通る。`evalOnce` は、
    // 失敗のあとに定数を評価できることと、漏れが無いことを見る。失敗したのが何回目かも見る。
    for ([_]u16{ 1, 50, 200 }) |fail_at| {
        const outcome = try evalOnce(null, input_fact, fail_at, std.testing.allocator);
        try std.testing.expect(outcome.induced);
        // 失敗の前に通った確保は `fail_at - 1` 回である。
        try std.testing.expectEqual(fail_at - 1, outcome.failed_after.?);
    }
    // 0 なら失敗させない。
    try std.testing.expect(!(try evalOnce(null, input_fact, 0, std.testing.allocator)).induced);
    // 失敗させる番号に届く前に `evalPrint` が戻っても、仕掛けは定数の評価に持ち越さない。
    try std.testing.expect(!(try evalOnce(null, "", 1, std.testing.allocator)).induced);
}

test "a fuzz run makes the allocation the fuzzer chose fail" {
    // 初期入力は `fail_at` が 0 で届くので、`run` が Smith の値を `evalOnce` に渡すことは、
    // 初期入力の照合では固定されない。入力の後ろに値を載せて、`run` を直接呼ぶ。Smith は、
    // 整数を 8 バイトのリトルエンディアンで読む(Zig 0.17.0 の lib/std/testing/Smith.zig)。
    const bytes = comptime seed(input_fact) ++ std.mem.toBytes(std.mem.nativeToLittle(u64, 50));
    var smith: std.testing.Smith = .{ .in = bytes };
    var record: Record = .{};
    try run(&record, &smith);
    try std.testing.expectEqual(1, record.count);
    try std.testing.expectEqual(50, record.fail_ats[0]);
    try std.testing.expect(record.induced[0]);
}

test "the chosen allocation fails only once, and the ones before it go through" {
    var failing: OneShotFailure = .{ .backing = std.testing.allocator };
    const a = failing.allocator();
    failing.arm(3);
    const first = try a.create(u8);
    defer a.destroy(first);
    const second = try a.create(u8);
    defer a.destroy(second);
    try std.testing.expectError(error.OutOfMemory, a.create(u8));
    try std.testing.expect(failing.induced);
    try std.testing.expectEqual(2, failing.failed_after.?);
    // 失敗のあとの確保は通る。
    const after = try a.create(u8);
    defer a.destroy(after);
    try std.testing.expectEqual(3, failing.passed);
}

test "an allocation failure that was not chosen is reported as an error" {
    // 仕掛けていない失敗(上限の外の確保が際限なく増えたときに起きるもの)を、内側の割り当て器
    // で作る。初期化に要る確保の数を先に数え、評価の途中の確保を1回だけ失敗させる。
    // Why: 内側を失敗し続ける割り当て器にすると、`evalOnce` が `OutOfMemory` を握りつぶしても、
    // 続く定数の評価が同じ誤りで落ちるので、握りつぶしを見分けられない。
    var counting: OneShotFailure = .{ .backing = std.testing.allocator };
    {
        var interp: sucheme.Interpreter = undefined;
        try interp.initWithFiles(counting.allocator(), .{ .limit = heap_limit }, null);
        interp.deinit();
    }
    var failing: OneShotFailure = .{ .backing = std.testing.allocator };
    failing.arm(counting.passed + 3);
    try std.testing.expectError(error.OutOfMemory, evalOnce(null, input_fact, 0, failing.allocator()));
    try std.testing.expect(failing.induced);
}
