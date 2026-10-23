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
    .{ .src = input_heap, .out = "", .diagnostic = "heap limit exceeded" },
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
    /// The start of what each run wrote, and of the diagnostic it ended with.
    outs: [capacity][64]u8 = undefined,
    out_lens: [capacity]usize = @splat(0),
    diagnostics: [capacity][64]u8 = undefined,
    diagnostic_lens: [capacity]usize = @splat(0),
    /// How many runs there were, also those past `capacity`.
    count: usize = 0,

    fn add(self: *Record, src: []const u8) void {
        if (self.count < capacity) {
            @memcpy(self.srcs[self.count][0..src.len], src);
            self.lens[self.count] = src.len;
        }
        self.count += 1;
    }

    /// Writes down how the run `add` wrote down last ended.
    fn end(self: *Record, out: []const u8, diagnostic: []const u8) void {
        const i = self.count - 1;
        if (i >= capacity) return;
        const o = @min(out.len, self.outs[i].len);
        @memcpy(self.outs[i][0..o], out[0..o]);
        self.out_lens[i] = o;
        const d = @min(diagnostic.len, self.diagnostics[i].len);
        @memcpy(self.diagnostics[i][0..d], diagnostic[0..d]);
        self.diagnostic_lens[i] = d;
    }
};

/// One fuzz run: a fresh interpreter evaluates the input, then a constant.
/// 見るのは次の3つである。パニックや安全検査の失敗が起きないこと(テストランナーが見る)。
/// 確保が漏れないこと(`std.testing.allocator` が見る)。`evalPrint` が返す誤りが
/// `OutOfMemory` でないこと。上限はヒープに置いてあり、この割り当て器は断らないので、
/// `OutOfMemory` が返るのは、上限の外の確保が際限なく増えたときである。最後に、誤りのあとも
/// インタプリタが使えることを、定数を評価して見る。定数にするのは、入力が `+` などの名前を
/// 定義し直せるからである。
///
/// インタプリタは、実行のたびに `(scheme base)` つきで作り直す(計画書 0025 の合意を求める
/// 点の1)。前の入力の定義が残らないので、ファザーが保存した入力1つで誤りを再現できる。
/// ファイルは読まない(`files` が null)。
fn run(record: ?*Record, smith: *std.testing.Smith) anyerror!void {
    var buf: [max_input]u8 = undefined;
    const src = buf[0..smith.slice(&buf)];
    if (record) |r| r.add(src);

    var interp: sucheme.Interpreter = undefined;
    try interp.initWithFiles(std.testing.allocator, .{ .limit = heap_limit }, null);
    defer interp.deinit();
    interp.setStepLimit(step_limit);

    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var out_buf: [output_capacity]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_buf);
    interp.evalPrint(arena.allocator(), src, &out) catch |e| switch (e) {
        error.OutOfMemory => return e,
        else => {},
    };
    if (record) |r| r.end(out.buffered(), interp.diagnostic());

    var after_buf: [16]u8 = undefined;
    var after: std.Io.Writer = .fixed(&after_buf);
    try interp.evalPrint(arena.allocator(), "#t", &after);
    try std.testing.expectEqualStrings("#t\n", after.buffered());
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
