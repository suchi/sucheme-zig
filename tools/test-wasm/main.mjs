// Round-trip tests for sucheme.wasm, run from Node.js: `node main.mjs <path to sucheme.wasm>`.
//
// sucheme.wasm の往復テスト。エクスポートを Node.js から呼び、状態コードと出力バッファの
// 内容を確かめる(docs/design/platform-and-web.md の「WebAssembly の境界」、
// docs/plans/0008-slice-1i-wasm-web-ui.md)。依存パッケージは使わない。
//
// 1つの panic のあとは同じインスタンスを使えない(trap する)ので、panic を起こす
// テストは新しいインスタンスで行う。テストごとに新しいインスタンスを作るので、
// テスト同士が状態を共有しない。

import { readFileSync, readdirSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import assert from "node:assert/strict";
import { samples } from "../../web/samples.mjs";
import { encodeFragment, decodeFragment, MAX_FRAGMENT_LENGTH } from "../../web/share.mjs";
import { describeResult, splitError } from "../../web/errors.mjs";
import { Status } from "../../web/sucheme.js";
import { matching, highlightPair, changeIndent, nextTabMovesFocus } from "../../web/parens.mjs";
import { createHistory, onFirstLine, onLastLine } from "../../web/history.mjs";
import {
  formatElapsed,
  restartedMessage,
  describeStopped,
  stopWarning,
  stopTimeoutMs,
  isStopKey,
} from "../../web/stop.mjs";
import { runEvaluation } from "../../web/runner.mjs";
import { Sucheme } from "../../web/sucheme.js";

const wasmPath = process.argv[2];
if (wasmPath === undefined) {
  console.error("usage: node main.mjs <path to sucheme.wasm>");
  process.exit(2);
}

// 状態コード(設計文書の表)。
const OK = 0;
const SCHEME_ERROR = -1;
const UNRECOVERABLE = -2;
const INVALID_UTF8 = -3;
const WRONG_ORDER = -4;
const NOT_INITIALIZED = -5;
const EXITED = -6;
const NO_MEMORY = -7;
const BAD_REGION = -8;
const CONTINUE = 1;

const OUTPUT_CAPACITY = 256 * 1024;

const compiled = new WebAssembly.Module(readFileSync(wasmPath));

console.log(`node ${process.version}`);

/**
 * Makes a new instance. `stderr` collects the strings passed to host_write_stderr.
 * `clock` は時刻の2つの import を差し替える(既定は `Date.now()` と `performance.now()`)。
 */
function instantiate(clock = {}) {
  const stderr = [];
  let memory;
  const decoder = new TextDecoder();
  const nowMs = clock.nowMs ?? (() => Date.now());
  const monotonicMs = clock.monotonicMs ?? (() => performance.now());
  const instance = new WebAssembly.Instance(compiled, {
    env: {
      host_write_stderr(ptr, len) {
        stderr.push(decoder.decode(new Uint8Array(memory.buffer, ptr >>> 0, len >>> 0)));
      },
      host_now_ms: () => nowMs(),
      host_monotonic_ms: () => monotonicMs(),
    },
  });
  memory = instance.exports.memory;
  const x = instance.exports;
  const encoder = new TextEncoder();

  const host = {
    x,
    stderr,
    /** Views the instance memory. メモリは grow で付け替わるので、使うたびに buffer を取り直す。 */
    bytes(ptr, len) {
      // Why: wasm32 の i32 は JS に符号つきで届く。2 GiB 以上のアドレスは符号なしに直す。
      return new Uint8Array(memory.buffer, ptr >>> 0, len >>> 0);
    },
    /** Reads the output buffer as a string without clearing it. */
    output() {
      const len = x.sucheme_output_len();
      return decoder.decode(host.bytes(x.sucheme_output_ptr(), len));
    },
    /** Starts an evaluation through alloc, eval_begin and free, and returns the status (1 when it goes on). */
    beginBytes(bytes) {
      const ptr = x.sucheme_alloc(bytes.length);
      assert.notEqual(ptr, 0, "sucheme_alloc failed");
      host.bytes(ptr, bytes.length).set(bytes);
      const status = x.sucheme_eval_begin(ptr, bytes.length);
      x.sucheme_free(ptr, bytes.length);
      return status;
    },
    /** Evaluates bytes to the end: eval_begin, then sucheme_step with the largest budget while it goes on. */
    evalBytes(bytes) {
      let status = host.beginBytes(bytes);
      while (status === CONTINUE) status = x.sucheme_step(0xffffffff);
      return status;
    },
    begin(source) {
      return host.beginBytes(encoder.encode(source));
    },
    eval(source) {
      return host.evalBytes(encoder.encode(source));
    },
    /** Evaluates a source string, then takes and clears the output. Returns `[status, output]`. */
    run(source) {
      const status = host.eval(source);
      const text = host.output();
      x.sucheme_output_clear();
      return [status, text];
    },
    init() {
      assert.equal(x.sucheme_init(0), OK);
      return host;
    },
  };
  return host;
}

const tests = [];
function test(name, body) {
  tests.push({ name, body });
}

// 規模を確かめるテストは、`zig build test-wasm -Dslow=true` のときだけ走る
// (build.zig が環境変数 SUCHEME_SLOW を渡す。docs/plans/0007-test-tiers.md)。
const slowTier = process.env.SUCHEME_SLOW === "1";
function slowTest(name, body) {
  tests.push({ name, body, slow: true });
}

test("version string is not empty", () => {
  const h = instantiate();
  const len = h.x.sucheme_version_len();
  assert.ok(len > 0);
  const text = new TextDecoder().decode(h.bytes(h.x.sucheme_version_ptr(), len));
  assert.match(text, /\S/);
});

test("before init: eval_begin and reset return not_initialized and say why", () => {
  const h = instantiate();
  assert.equal(h.x.sucheme_eval_begin(0, 0), NOT_INITIALIZED);
  assert.match(h.output(), /not initialized/);
  h.x.sucheme_output_clear();
  assert.equal(h.x.sucheme_reset(), NOT_INITIALIZED);
  assert.match(h.output(), /not initialized/);
});

test("before init: alloc returns 0 and the output is empty", () => {
  const h = instantiate();
  assert.equal(h.x.sucheme_alloc(16), 0);
  assert.equal(h.x.sucheme_output_len(), 0);
});

test("init returns ok once and wrong_order, with the reason, the second time", () => {
  const h = instantiate();
  assert.equal(h.x.sucheme_init(0), OK);
  assert.equal(h.x.sucheme_init(0), WRONG_ORDER);
  assert.match(h.output(), /sucheme_init was called twice/);
});

test("factorial of 10 prints 3628800", () => {
  const h = instantiate().init();
  const status = h.eval("(define (fact n) (if (= n 0) 1 (* n (fact (- n 1))))) (fact 10)");
  assert.equal(status, OK);
  assert.equal(h.output(), "3628800\n");
});

test("output_clear empties the output", () => {
  const h = instantiate().init();
  assert.equal(h.eval("(+ 1 2)"), OK);
  assert.equal(h.output(), "3\n");
  h.x.sucheme_output_clear();
  assert.equal(h.x.sucheme_output_len(), 0);
  assert.equal(h.output(), "");
});

test("a Scheme error returns -1 with one error line, and evaluation continues", () => {
  const h = instantiate().init();
  const [status, text] = h.run("(foo)");
  assert.equal(status, SCHEME_ERROR);
  assert.equal(text, "error: unbound variable: foo\n");
  assert.deepEqual(h.run("(+ 1 2)"), [OK, "3\n"]);
});

// スライス 2b: 条件オブジェクトは GC ヒープにある。プリミティブの失敗が、ヒープの条件を
// 通って、今までと同じ一行として届く。条件が回収されたあとも評価が続く。
test("a primitive's error reaches the output through the condition in the heap", () => {
  const h = instantiate().init();
  assert.deepEqual(h.run("(car 5)"), [SCHEME_ERROR, "error: wrong type of argument to car 5\n"]);
  // 多くの GC を経たあとで送出しても、同じである。
  const [status, text] = h.run("(define (spin n) (if (= n 0) (car 5) (spin (- n 1)))) (spin 30000)");
  assert.equal(status, SCHEME_ERROR);
  assert.equal(text, "error: wrong type of argument to car 5\n");
  assert.deepEqual(h.run("(+ 1 2)"), [OK, "3\n"]);
});

// スライス 2d: 条件オブジェクトでない値も送出できる。ハンドラが無ければ、送出された値を
// write の形で一行に書き、評価は続く(docs/design/runtime.md の例外の事例11)。ハンドラが
// あれば、機械が検出する失敗もハンドラに届く。
test("a raised value that is not a condition is reported as write shows it, and a handler catches what the machine finds", () => {
  const h = instantiate().init();
  assert.deepEqual(h.run("(raise 42)"), [SCHEME_ERROR, "error: 42\n"]);
  assert.deepEqual(h.run("(raise 'oops)"), [SCHEME_ERROR, "error: oops\n"]);
  assert.deepEqual(h.run('(error "bad thing" 1 "two")'), [SCHEME_ERROR, 'error: bad thing 1 "two"\n']);
  assert.deepEqual(h.run("(with-exception-handler (lambda (c) 42) (lambda () (raise-continuable 'oops)))"), [OK, "42\n"]);
  assert.deepEqual(
    h.run("(define got #f) (with-exception-handler (lambda (c) (set! got c) 0) (lambda () (car 5)))"),
    [SCHEME_ERROR, 'error: handler returned from non-continuable raise #<condition "wrong type of argument to car" 5>\n'],
  );
  assert.deepEqual(h.run("(error-object-message got)"), [OK, '"wrong type of argument to car"\n']);
  assert.deepEqual(h.run("(+ 1 2)"), [OK, "3\n"]);
});

// 継続は第一級の値で、未処理例外は最外の継続への脱出として、途中の dynamic-wind の after を
// 呼んでから報告される(スライス 2e)。
test("a continuation escapes, and an unhandled raise runs the after of a dynamic-wind before it is reported", () => {
  const h = instantiate().init();
  assert.deepEqual(h.run("(call/cc (lambda (k) (+ 1 (k 42))))"), [OK, "42\n"]);
  assert.deepEqual(
    h.run("(define k #f) (define n 0) (list (call/cc (lambda (c) (set! k c) 0)) (begin (set! n (+ n 1)) n))"),
    [OK, "(0 1)\n"],
  );
  // 前の行で捕捉した継続を起動すると、捕捉した式の残りだけが走る。
  assert.deepEqual(h.run("(k 5)"), [OK, "(5 2)\n"]);
  // after の送出が報告されることで、after が呼ばれたことを見る。
  assert.deepEqual(
    h.run("(dynamic-wind (lambda () #f) (lambda () (car 5)) (lambda () (raise 'after-ran)))"),
    [SCHEME_ERROR, "error: after-ran\n"],
  );
  assert.deepEqual(h.run("(+ 1 2)"), [OK, "3\n"]);
});

// ライブラリを定義して、`import` した手続きを呼ぶ(スライス 2m)。定義とインポートは何も
// 出力せず、失敗した定義は登録を残さない。リセットは登録したライブラリも忘れる。
test("a library is defined, imported and called, and a failed definition leaves nothing", () => {
  const h = instantiate().init();
  const definition = "(define-library (t a) (export f) (import (scheme base)) (begin (define (f) 1)))";
  assert.deepEqual(h.run(definition), [OK, ""]);
  assert.deepEqual(h.run("(import (t a)) (f)"), [OK, "1\n"]);
  assert.deepEqual(
    h.run("(define-library (t b) (export) (import (scheme base)) (begin (define x (car 5))))"),
    [SCHEME_ERROR, "error: wrong type of argument to car 5\n"],
  );
  assert.deepEqual(h.run("(import (t b))"), [SCHEME_ERROR, "error: unknown library: (t b)\n"]);
  assert.deepEqual(h.run("(f)"), [OK, "1\n"]);
  assert.equal(h.x.sucheme_reset(), OK);
  assert.deepEqual(h.run("(import (t a))"), [SCHEME_ERROR, "error: unknown library: (t a)\n"]);
});

// WASM にはファイルを開く手段が無いので、定義されていないライブラリは、ファイルを探さずに
// 「見つからない」になる(スライス 2n)。ファイルの名前にならない名前は、その理由つきで断る。
test("a library that is not defined is not found, since there is no file system", () => {
  const h = instantiate().init();
  assert.deepEqual(h.run("(import (foo bar))"), [SCHEME_ERROR, "error: unknown library: (foo bar)\n"]);
  assert.deepEqual(
    h.run("(import (CON))"),
    [SCHEME_ERROR, "error: unknown library: (CON): a library with that name cannot be a file, because a component is the name of a device\n"],
  );
  assert.deepEqual(h.run("(+ 1 2)"), [OK, "3\n"]);
});

// `lib/` のファイルは実行ファイルに埋め込まれているので、ファイルを開く手段の無い WASM でも
// `import` できる(スライス 3a)。埋め込みのファイルの `include` も、埋め込みの中から引く。
test("an embedded library is imported without a file system", () => {
  const h = instantiate().init();
  assert.deepEqual(h.run("(import (sucheme derived)) (list (when #t 1 2) (unless #f 3 4))"), [OK, "(2 4)\n"]);
  assert.deepEqual(h.run("(when #t 5)"), [OK, "5\n"]);
  // 埋め込みに無いライブラリは、これまでどおり見つからない。
  assert.deepEqual(h.run("(import (sucheme nope))"), [SCHEME_ERROR, "error: unknown library: (sucheme nope)\n"]);
  // `cond-expand` の `(library ...)` も、埋め込みのライブラリを見つける。
  assert.deepEqual(h.run("(cond-expand ((library (sucheme derived)) 1) (else 2))"), [OK, "1\n"]);
  assert.deepEqual(h.run("(cond-expand ((library (sucheme nope)) 1) (else 2))"), [OK, "2\n"]);
  assert.deepEqual(h.run("(+ 1 2)"), [OK, "3\n"]);
});

// Scheme で書いたリストの手続きも、WASM で `import` できて、`map` が `apply` を通る(スライス 3g)。
test("the list procedures in (sucheme procedures) run in wasm", () => {
  const h = instantiate().init();
  assert.deepEqual(
    h.run("(import (sucheme procedures)) (list (append '(1 2) '(3)) (map + '(1 2) '(10 20)) (reverse '(1 2 3)) (list-tail '(a b c) 1))"),
    [OK, "((1 2 3) (11 22) (3 2 1) (b c))\n"],
  );
  assert.deepEqual(h.run("(list-ref '(a b) 2)"), [SCHEME_ERROR, "error: argument out of range in list-ref (a b) 2\n"]);
});

// EOF の値と約束が WASM でも動く(スライス 3f)。`force` は継続のフレームを経由する機械操作で、
// 強制していない約束の連鎖を反復で解き、約束の値は一度だけ計算される。
test("the end-of-file object and promises work in wasm", () => {
  const h = instantiate().init();
  assert.deepEqual(h.run("(list (eof-object? (eof-object)) (eof-object? 1) (eof-object))"), [OK, "(#t #f #<eof>)\n"]);
  assert.deepEqual(
    h.run("(import (scheme lazy)) (list (promise? (make-promise 1)) (promise? 1) (force (make-promise 5)) (force 6))"),
    [OK, "(#t #f 5 6)\n"],
  );
  assert.deepEqual(
    h.run(
      "(define n 0) (define (chain k) (if (= k 0) (delay 'done) (delay-force (begin (set! n (+ n 1)) (chain (- k 1)))))) " +
        "(define p (chain 3000)) (list (force p) (force p) n)",
    ),
    [OK, "(done done 3000)\n"],
  );
  assert.deepEqual(
    h.run("(force (delay-force 5))"),
    [SCHEME_ERROR, "error: delay-force: the expression did not return a promise\n"],
  );
});

// 派生構文(`cond` と `quasiquote` など)も、WASM で `import` できて動く(スライス 3h)。
// リーダの略記(`` ` `` `,` `,@`)は、WASM の入口から渡した文字列でも読める。
test("the derived syntax in (sucheme derived) runs in wasm", () => {
  const h = instantiate().init();
  assert.deepEqual(
    h.run("(import (sucheme derived)) (list (cond (#f 1) (else 2)) (cond ((list 1 2) => car)) (case 3 ((1 2) 'low) (else 'high)) (let loop ((i 0)) (if (< i 3) (loop (+ i 1)) i)))"),
    [OK, "(2 1 high 3)\n"],
  );
  assert.deepEqual(h.run("`(1 ,(+ 1 1) ,@(list 3 4) #(5 ,(+ 3 3)))"), [OK, "(1 2 3 4 #(5 6))\n"]);
  assert.deepEqual(h.run("(do ((i 0 (+ i 1)) (s 0 (+ s i))) ((= i 1000) s))"), [OK, "499500\n"]);
  assert.deepEqual(h.run("'`(a ,b ,@c)"), [OK, "(quasiquote (a (unquote b) (unquote-splicing c)))\n"]);
  assert.deepEqual(h.run("`"), [SCHEME_ERROR, "error: unexpected end of input\n"]);
  assert.deepEqual(h.run("(+ 1 2)"), [OK, "3\n"]);
});

// スライス 3i の派生構文(`define-record-type` `let-values` `define-values` `guard` `case-lambda`)も、
// WASM で動く。`guard` は継続と `dynamic-wind` を使い、再送出は `raise-continuable` である。
test("the derived syntax of slice 3i runs in wasm", () => {
  const h = instantiate().init();
  assert.deepEqual(
    h.run("(import (sucheme derived)) (define-record-type pare (kons x y) pare? (x kar set-kar!) (y kdr)) (let ((k (kons 1 2))) (set-kar! k 3) (list (pare? k) (pare? 1) (kar k) (kdr k)))"),
    [OK, "(#t #f 3 2)\n"],
  );
  assert.deepEqual(h.run("(let-values (((a b) (values 1 2)) ((c . d) (values 3 4 5))) (list a b c d))"), [OK, "(1 2 3 (4 5))\n"]);
  assert.deepEqual(h.run("(define-values (p q) (values 10 20)) (list p q)"), [OK, "(10 20)\n"]);
  assert.deepEqual(
    h.run("(define f (case-lambda ((a) (list 'one a)) ((a . r) (list 'many a r)))) (list (f 1) (f 1 2 3))"),
    [OK, "((one 1) (many 1 (2 3)))\n"],
  );
  assert.deepEqual(
    h.run("(let ((log '())) (guard (o (#t (set! log (cons 'outer log)))) (guard (i ((string? i) 'inner)) (dynamic-wind (lambda () (set! log (cons 'in log))) (lambda () (raise 'x)) (lambda () (set! log (cons 'out log)))))) log)"),
    [OK, "(outer out in out in)\n"],
  );
  assert.deepEqual(h.run("(guard (e ((string? e) 1)) (raise 'sym))"), [SCHEME_ERROR, "error: sym\n"]);
});

// スライス 3j のベクタと文字列の高階手続きと、約束の構文も、WASM で動く。`delay-force` の連鎖は、
// 継続を伸ばさずに解かれる。ベクタの長さは 64 ビットの整数なので、32 ビットの usize で切り捨てない。
test("the higher-order procedures and the promise syntax of slice 3j run in wasm", () => {
  const h = instantiate().init();
  assert.deepEqual(
    h.run("(import (sucheme derived) (sucheme procedures) (scheme lazy)) (list (vector-map + #(1 2 3) #(10 20)) (string-map (lambda (c) c) \"aλあ\") (force (delay (+ 1 2))))"),
    [OK, '(#(11 22) "aλあ" 3)\n'],
  );
  assert.deepEqual(
    h.run("(define n 0) (vector-for-each (lambda (x) (set! n (+ n x))) #(1 2 3)) (string-for-each (lambda (c) (set! n (+ n 1))) \"ab\") n"),
    [OK, "8\n"],
  );
  assert.deepEqual(
    h.run("(define (loop n) (if (= n 0) (delay 'done) (delay-force (loop (- n 1))))) (force (loop 20000))"),
    [OK, "done\n"],
  );
  assert.deepEqual(h.run("(vector-map car #(1 2))"), [SCHEME_ERROR, "error: wrong type of argument to car 1\n"]);
});

// スライス 3k の標準ライブラリ(`lib/scheme/`)も、WASM に埋め込まれて引ける。`(scheme base)` は、
// 実装の無い識別子をエクスポートしない。
test("the standard libraries of slice 3k can be imported in wasm", () => {
  const h = instantiate().init();
  assert.deepEqual(
    h.run("(import (scheme base) (scheme cxr) (scheme lazy) (scheme case-lambda)) (list (cadr '(1 2 3)) (caddr '(1 2 3)) (force (delay 4)) ((case-lambda ((a) a) ((a b) (+ a b))) 1 2))"),
    [OK, "(2 3 4 3)\n"],
  );
  assert.deepEqual(h.run("(import (only (scheme base) display))"), [SCHEME_ERROR, "error: bad import: display is not exported by the import set\n"]);
});

// スライス 5i: コンソールのポートは、評価の結果と同じ出力バッファに、書いた順に書く。標準エラーも
// 同じバッファに書く。標準入力は、ホストが渡す(スライス 8f-1)。渡されるまで、読み取りは待つ。
test("the console ports write to the output buffer in order with the results", () => {
  const h = instantiate().init();
  assert.deepEqual(
    h.run("(import (scheme write)) (display \"hi\") (newline) (write-string \"x\" (current-error-port)) 1"),
    [OK, "hi\nx1\n"],
  );
  // 入力は、ホストが渡すまで空で、読み取りは待つ。終端を渡すと、終端のオブジェクトが返る。
  assert.equal(h.begin("(eof-object? (read-char))"), CONTINUE);
  assert.equal(h.x.sucheme_step(1000), WAITING);
  assert.equal(h.x.sucheme_provide_eof(), CONTINUE);
  assert.equal(h.x.sucheme_step(1000), OK);
  assert.equal(h.output(), "#t\n");
  h.x.sucheme_output_clear();
  // 出力バッファの書き手は、書き出しで失敗しない(固定の書き手の flush は何もしない)。
  assert.deepEqual(h.run("(write-string \"y\") (flush-output-port) 2"), [OK, "y2\n"]);
  // 出力が残っていても、エラーの行はそのあとに書かれる。
  assert.deepEqual(h.run("(write-string \"a\") (car 1)"), [SCHEME_ERROR, "aerror: wrong type of argument to car 1\n"]);
});

// スライス 5k: WASM はファイルの表を持たないので、`file-exists?` は誤りを送出せずに `#f` を返し、
// ファイルを開く手続きは `file-error?` が真になる条件を送出する(docs/design/frontend.md の第2類)。
test("file-exists? is false in wasm, and opening a file is a file error", () => {
  const h = instantiate().init();
  assert.deepEqual(h.run('(import (scheme file)) (file-exists? "x")'), [OK, "#f\n"]);
  assert.deepEqual(h.run("(guard (c ((file-error? c) 'file)) (open-input-file \"x\"))"), [OK, "file\n"]);
});

// WASM にはファイルを開く手段が無いので、`include` は、ファイルを探さずに、ファイルが無いと
// 報告する(スライス 2o)。ファイル名の形が悪いものは、開く前に、形の誤りとして断る。
test("an include reports that there is no file to read, and refuses a form that is not well formed", () => {
  const h = instantiate().init();
  assert.deepEqual(
    h.run('(include "a.scm")'),
    [SCHEME_ERROR, "error: bad include: this interpreter has no files to read: a.scm\n"],
  );
  assert.deepEqual(h.run("(include 1)"), [SCHEME_ERROR, "error: bad include: a file name must be a string\n"]);
  assert.deepEqual(
    h.run('(include-ci "a.scm")'),
    [SCHEME_ERROR, "error: bad include-ci: this interpreter has no files to read: a.scm\n"],
  );
  assert.deepEqual(h.run("(+ 1 2)"), [OK, "3\n"]);
});

// `wasm` は、WASM のビルドでだけ真で、WASM のビルドは OS の名前を持たない(スライス 2p)。
test("the wasm feature is true in this build, and the names of an operating system are not", () => {
  const h = instantiate().init();
  assert.deepEqual(h.run("(cond-expand (wasm 'wasm) (else 'other))"), [OK, "wasm\n"]);
  assert.deepEqual(h.run("(cond-expand ((or unix windows linux macos) 'os) (else 'none))"), [OK, "none\n"]);
  assert.deepEqual(h.run("(cond-expand ((and r7rs sucheme) 'both) (else 'no))"), [OK, "both\n"]);
});

// 送出のための予約も尽きて条件を作れなかったら、回復不能(-2)を返し、リセットまで評価を
// 受け付けない(docs/design/platform-and-web.md の状態コードの表)。予約を使い切らせるため、
// 名前が上限の2分の1の未束縛の名前を使う。名前のシンボルが上限に計上されるので、名前は上限
// を超えられない。初期化で読み込む標準ライブラリが上限の4分の1ほどを占めるので、名前を足した
// 計上は上限の4分の3ほどで、同じ長さのメッセージは、予約を足しても収まらない。一方で、
// ヒープが満杯の報告(上限と余裕の差の内側まで生きているもの)には当たらない長さである。
// 名前が上限を超えるなら、シンボルを作れず、回復できるエラーになる。
// `(scheme time)` は、ホストの2つの import から時刻を読む(スライス 5n)。絶対時刻には TAI と UTC の
// 差の 37 秒を足し、単調な時間はマイクロ秒の jiffy にする。
test("the time procedures read the two clock imports of the host", () => {
  const h = instantiate({ nowMs: () => 1_500_000_000_250, monotonicMs: () => 2.5 }).init();
  assert.deepEqual(
    h.run("(import (scheme time)) (list (current-second) (current-jiffy) (jiffies-per-second))"),
    [OK, "(1500000037.25 2500 1000000)\n"],
  );
  // 本物の時計でも、性質は同じである。
  const r = instantiate().init();
  assert.deepEqual(
    r.run("(import (scheme time)) (let ((a (current-jiffy)) (b (current-jiffy))) (list (< 0 a) (<= a b) (exact-integer? a) (inexact? (current-second)) (< 1483228800 (current-second))))"),
    [OK, "(#t #t #t #t #t)\n"],
  );
});

test("a monotonic time the host gives out of range becomes 0, not a trap", () => {
  for (const bad of [-1, Number.NaN, Number.NEGATIVE_INFINITY]) {
    const h = instantiate({ monotonicMs: () => bad }).init();
    assert.deepEqual(h.run("(import (scheme time)) (current-jiffy)"), [OK, "0\n"]);
  }
  const big = instantiate({ monotonicMs: () => Number.POSITIVE_INFINITY }).init();
  assert.deepEqual(big.run("(import (scheme time)) (current-jiffy)"), [OK, "9223372036854775807\n"]);
});

// `exit` は、`after` を呼んでから -6 を返す。終了コードは出力に書かず、`sucheme_exit_code` で
// 取る。以後はリセットまで評価を受け付けない(スライス 5m、docs/design/platform-and-web.md)。
test("a fold-case directive applies to the later evaluations until a reset", () => {
  const h = instantiate().init();
  assert.deepEqual(h.run("'ABC"), [OK, "ABC\n"]);
  assert.deepEqual(h.run("#!fold-case"), [OK, ""]);
  assert.deepEqual(h.run("'ABC"), [OK, "abc\n"]);
  assert.equal(h.x.sucheme_reset(), OK);
  assert.deepEqual(h.run("'ABC"), [OK, "ABC\n"]);
});

test("exit runs the after of a dynamic-wind, returns -6 with the code apart from the output, and waits for a reset", () => {
  const h = instantiate().init();
  assert.equal(h.x.sucheme_exit_code(), 0);
  assert.deepEqual(
    h.run("(import (scheme process-context) (scheme write)) (dynamic-wind (lambda () #f) (lambda () (display \"in \") (exit 3)) (lambda () (display \"cleanup\")))"),
    [EXITED, "in cleanup"],
  );
  assert.equal(h.x.sucheme_exit_code(), 3);
  assert.deepEqual(h.run("(+ 1 2)"), [WRONG_ORDER, "error: the interpreter cannot go on; call sucheme_reset\n"]);
  assert.equal(h.x.sucheme_reset(), OK);
  assert.deepEqual(h.run("(+ 1 2)"), [OK, "3\n"]);
  // 終了コードは、次の -6 まで残る。`emergency-exit` は `after` を呼ばない。
  assert.equal(h.x.sucheme_exit_code(), 3);
  assert.deepEqual(
    h.run("(import (scheme process-context) (scheme write)) (dynamic-wind (lambda () #f) (lambda () (emergency-exit #f)) (lambda () (display \"cleanup\")))"),
    [EXITED, ""],
  );
  assert.equal(h.x.sucheme_exit_code(), 1);
});

test("set_command_line sets what command-line gives from the next evaluation, and refuses what is not UTF-8", () => {
  const h = instantiate().init();
  const encoder = new TextEncoder();
  const setLine = (bytes) => {
    const ptr = h.x.sucheme_alloc(bytes.length);
    h.bytes(ptr, bytes.length).set(bytes);
    const result = h.x.sucheme_set_command_line(ptr, bytes.length);
    h.x.sucheme_free(ptr, bytes.length);
    return result;
  };
  // 設定していなければ、処理系の名前だけである。環境変数は無い。
  assert.deepEqual(
    h.run("(import (scheme process-context)) (list (command-line) (get-environment-variable \"PATH\") (get-environment-variables))"),
    [OK, "((\"sucheme\") #f ())\n"],
  );
  assert.equal(setLine(encoder.encode("prog.scm\nα\n\n")), 1);
  assert.deepEqual(h.run("(command-line)"), [OK, "(\"prog.scm\" \"α\" \"\")\n"]);
  // 妥当でない UTF-8 は断り、前の設定を残す。出力バッファには書かない。
  assert.equal(setLine(new Uint8Array([0x61, 0xff])), 0);
  assert.equal(h.output(), "");
  assert.deepEqual(h.run("(command-line)"), [OK, "(\"prog.scm\" \"α\" \"\")\n"]);
  // リセットのあとも残る。空の設定は、処理系の名前だけに戻す。
  assert.equal(h.x.sucheme_reset(), OK);
  assert.deepEqual(h.run("(import (scheme process-context)) (command-line)"), [OK, "(\"prog.scm\" \"α\" \"\")\n"]);
  assert.equal(setLine(new Uint8Array([])), 1);
  assert.deepEqual(h.run("(command-line)"), [OK, "(\"sucheme\")\n"]);
});

test("a raise that uses up the reserve is unrecoverable until a reset", () => {
  const h = instantiate();
  assert.equal(h.x.sucheme_init(small_limit), OK);
  assert.deepEqual(h.run("x".repeat(small_limit + 8192)), [SCHEME_ERROR, "error: heap limit exceeded\n"]);
  const [status, text] = h.run("x".repeat(small_limit / 2));
  assert.equal(status, UNRECOVERABLE);
  assert.equal(text, "error: heap limit exceeded\n");
  // リセットの前の評価は、何も変えずに呼び出し順序の誤りを返す。
  assert.deepEqual(h.run("(+ 1 2)"), [WRONG_ORDER, "error: the interpreter cannot go on; call sucheme_reset\n"]);
  assert.equal(h.x.sucheme_reset(), OK);
  assert.deepEqual(h.run("(+ 1 2)"), [OK, "3\n"]);
  // 対照: 同じ上限で、メッセージが予約に収まる名前なら、ふつうの Scheme のエラーである。
  assert.deepEqual(h.run("nope"), [SCHEME_ERROR, "error: unbound variable: nope\n"]);
});

// 診断の一行が境界のバッファ(320 バイト)に収まらなければ、メッセージを文字の境目で切って
// `...` を付ける。メッセージごと失わない。
test("a diagnostic too long for the line is cut short with ..., not lost", () => {
  const h = instantiate().init();
  const long = "x".repeat(330);
  assert.deepEqual(h.run(`(error "${long}")`), [SCHEME_ERROR, `error: ${"x".repeat(309)}...\n`]);
  // irritant を切ったあとでも、メッセージが長ければ一行に収まらない。
  const [status, text] = h.run(`(error "${"m".repeat(200)}" "${"y".repeat(300)}")`);
  assert.equal(status, SCHEME_ERROR);
  assert.equal(text.length, 320);
  assert.ok(text.startsWith(`error: ${"m".repeat(200)} "yyy`), text);
  assert.ok(text.endsWith("...\n"), text);
  assert.deepEqual(h.run("(+ 1 2)"), [OK, "3\n"]);
});

test("invalid UTF-8 returns -3 with the position, and leaves the state unchanged", () => {
  const h = instantiate().init();
  assert.equal(h.run("(define kept 42)")[0], OK);
  const status = h.evalBytes(new Uint8Array([0x31, 0x20, 0x80])); // "1 " then a lone continuation byte
  assert.equal(status, INVALID_UTF8);
  assert.ok(h.output().includes("invalid UTF-8 at byte 2"), h.output());
  h.x.sucheme_output_clear();
  // 不正な入力の「1」は評価されず、前の定義が残っている。
  assert.deepEqual(h.run("kept"), [OK, "42\n"]);
});

test("a region that was not allocated returns -8 and says so in the output", () => {
  const h = instantiate().init();
  assert.equal(h.x.sucheme_eval_begin(1, 4), BAD_REGION);
  assert.match(h.output(), /region was not returned by sucheme_alloc/);
  h.x.sucheme_output_clear();
  const ptr = h.x.sucheme_alloc(4);
  assert.notEqual(ptr, 0);
  assert.equal(h.x.sucheme_eval_begin(ptr, 5), BAD_REGION); // 確保した長さを超える
  h.x.sucheme_free(ptr, 4);
  assert.equal(h.x.sucheme_eval_begin(ptr, 4), BAD_REGION); // 解放済み
});

test("an empty input returns ok with no output", () => {
  const h = instantiate().init();
  assert.equal(h.x.sucheme_eval_begin(0, 0), OK);
  assert.equal(h.x.sucheme_output_len(), 0);
  const ptr = h.x.sucheme_alloc(0);
  assert.notEqual(ptr, 0);
  assert.equal(h.x.sucheme_eval_begin(ptr, 0), OK);
  h.x.sucheme_free(ptr, 0);
});

test("free with a different length panics and reports it on stderr", () => {
  const h = instantiate().init();
  const ptr = h.x.sucheme_alloc(8);
  assert.notEqual(ptr, 0);
  assert.throws(() => h.x.sucheme_free(ptr, 4), WebAssembly.RuntimeError);
  assert.ok(
    h.stderr.some((s) => s.includes("sucheme_free")),
    `stderr was ${JSON.stringify(h.stderr)}`,
  );
});

test("free of a pointer that was not allocated panics", () => {
  const h = instantiate().init();
  assert.throws(() => h.x.sucheme_free(12345, 4), WebAssembly.RuntimeError);
  assert.ok(h.stderr.some((s) => s.includes("sucheme_free")));
});

test("output overflow returns -1 and ends with the buffer-full line", () => {
  const h = instantiate().init();
  // 100 KB の文字列リテラルを 4 回評価すると、256 KiB の出力バッファに入らない。
  const literal = `"${"a".repeat(100_000)}"`;
  const status = h.eval(`${literal} ${literal} ${literal} ${literal}`);
  assert.equal(status, SCHEME_ERROR);
  const len = h.x.sucheme_output_len();
  assert.ok(len <= OUTPUT_CAPACITY, `output length ${len}`);
  assert.ok(h.output().endsWith("error: output buffer full\n"), h.output().slice(-60));
  // 出力を取り出して消せば、続けて評価できる。
  h.x.sucheme_output_clear();
  assert.deepEqual(h.run("(+ 1 2)"), [OK, "3\n"]);
});

// スライス 5i: プログラムがコンソールに書き続けて出力バッファが満杯になっても、同じ行で終わる。
// 書き込みの失敗は Scheme の条件にならず、ハンドラでも捕まえられない。
test("console output that overflows the buffer returns -1 with the buffer-full line, even under a handler", () => {
  const h = instantiate().init();
  const status = h.eval("(with-exception-handler (lambda (e) 'caught) (lambda () (let loop () (write-string \"0123456789\") (loop))))");
  assert.equal(status, SCHEME_ERROR);
  assert.ok(h.x.sucheme_output_len() <= OUTPUT_CAPACITY);
  assert.ok(h.output().endsWith("error: output buffer full\n"), h.output().slice(-60));
  h.x.sucheme_output_clear();
  assert.deepEqual(h.run("(+ 1 2)"), [OK, "3\n"]);
});

test("reset forgets definitions", () => {
  const h = instantiate().init();
  assert.equal(h.run("(define (fact n) (if (= n 0) 1 (* n (fact (- n 1)))))")[0], OK);
  assert.deepEqual(h.run("(fact 5)"), [OK, "120\n"]);
  assert.equal(h.x.sucheme_reset(), OK);
  assert.equal(h.x.sucheme_output_len(), 0);
  const [status, text] = h.run("(fact 5)");
  assert.equal(status, SCHEME_ERROR);
  assert.equal(text, "error: unbound variable: fact\n");
  // リセットのあとも評価できる。
  assert.deepEqual(h.run("(+ 1 2)"), [OK, "3\n"]);
});

// 非末尾再帰は、深さに比例してヒープを使う。小さい上限では溢れ、既定の上限では溢れない。
const deep_recursion = "(define (f n) (if (= n 0) 0 (+ 1 (f (- n 1))))) (f 10000)";
const small_limit = 1048576;

test("init with a small heap limit makes a deep recursion run out of heap", () => {
  const h = instantiate();
  assert.equal(h.x.sucheme_init(small_limit), OK);
  const [status, text] = h.run(deep_recursion);
  assert.equal(status, SCHEME_ERROR);
  assert.match(text, /heap limit exceeded/);
  // 同じ式は、既定の上限(0)では通る。上限が効いていることの対照である。
  const control = instantiate().init();
  assert.deepEqual(control.run(deep_recursion), [OK, "10000\n"]);
});

// 初期化は標準ライブラリを読み込み、その分も上限に計上される。入りきらない上限は、-7(この上限では
// 初期化できない)になり、同じ上限での再試行も同じ結果になる。
test("init with a limit too small for the standard libraries returns not enough memory", () => {
  const h = instantiate();
  assert.equal(h.x.sucheme_init(65536), NO_MEMORY);
  assert.equal(h.x.sucheme_init(65536), NO_MEMORY);
});

test("reset keeps the heap limit that init was given", () => {
  const h = instantiate();
  assert.equal(h.x.sucheme_init(small_limit), OK);
  assert.equal(h.x.sucheme_reset(), OK);
  const [status, text] = h.run(deep_recursion);
  assert.equal(status, SCHEME_ERROR);
  assert.match(text, /heap limit exceeded/);
});

// 4 GiB に近い上限を渡しても、計上の上限は 1 GiB に丸められる(`heap.max_host_limit`)。
// 丸めが無いと、計上が上限に届く前に wasm32 の線形メモリ(4 GiB)が尽きて trap する。
// 上限まで使い切るので時間がかかる。
slowTest("init with a limit near 4 GiB runs the heap up to its limit and reports it, not a trap", () => {
  const h = instantiate();
  assert.equal(h.x.sucheme_init(0xffffffff), OK);
  const [status, text] = h.run("(define (f n) (+ 1 (f n))) (f 0)");
  assert.equal(status, SCHEME_ERROR);
  assert.match(text, /heap limit exceeded/);
  // 使い切ったあとも、インスタンスは使える。
  assert.deepEqual(h.run("(+ 1 2)"), [OK, "3\n"]);
});

test("reset empties an output that was not taken", () => {
  const h = instantiate().init();
  assert.equal(h.eval("(+ 1 2)"), OK);
  assert.ok(h.x.sucheme_output_len() > 0);
  assert.equal(h.x.sucheme_reset(), OK);
  assert.equal(h.x.sucheme_output_len(), 0);
});

test("characters, strings and vectors are written in the write form", () => {
  const h = instantiate().init();
  assert.deepEqual(h.run('"a\\nb" #\\a #(1 "x")'), [OK, '"a\\nb"\n#\\a\n#(1 "x")\n']);
});

test("pairs, lists, strings and vectors work in wasm32", () => {
  const h = instantiate().init();
  assert.deepEqual(h.run("(cons 1 2) (list 1 (if #f #f)) (length (list 1 2 3))"), [OK, "(1 . 2)\n(1 #<unspecified>)\n3\n"]);
  assert.deepEqual(h.run('(string-length "あい") (string-ref "あい" 1) (vector-ref (vector 1 2 3) 2)'), [OK, "2\n#\\い\n3\n"]);
  assert.deepEqual(h.run('(equal? (list 1 (vector 2 "x")) (list 1 (vector 2 "x"))) (eq? (list) (list)) (integer->char 12354)'), [OK, "#t\n#t\n#\\あ\n"]);
  assert.deepEqual(
    h.run("(define (len xs) (if (null? xs) 0 (+ 1 (len (cdr xs))))) (len (list 1 2 3 4 5 6 7 8 9 10))"),
    [OK, "10\n"],
  );
});

// 文字列を作る、書き換える、比べる手続きと、定数への書き込みの拒否が、wasm32 でも動く(スライス 3d)。
// 大きさと位置は 64 ビットの整数で、wasm32 の usize は 32 ビットなので、2^32 を超える大きさが、
// 小さな大きさに化けて成功しないことも固定する。
test("strings are made, written and compared in wasm32, and a constant is refused", () => {
  const h = instantiate().init();
  assert.deepEqual(h.run('(string-append "ab" "cd") (make-string 3 #\\λ) (substring "aλあ𐀀z" 1 4)'), [OK, '"abcd"\n"λλλ"\n"λあ𐀀"\n']);
  assert.deepEqual(
    h.run('(define s (make-string 3 #\\a)) (string-set! s 1 #\\λ) (string-copy! s 0 "あ") (list s (string-length s) (string=? s "あλa") (string<? "a" s))'),
    [OK, '("あλa" 3 #t #t)\n'],
  );
  assert.deepEqual(h.run('(list->string (string->list "aλあ")) (vector->string (string->vector "xy"))'), [OK, '"aλあ"\n"xy"\n']);
  assert.deepEqual(h.run('(string-set! "abc" 0 #\\x)'), [SCHEME_ERROR, 'error: cannot modify a constant in string-set! "abc" 0 #\\x\n']);
  assert.deepEqual(h.run("(set-car! '(1 2) 0)"), [SCHEME_ERROR, "error: cannot modify a constant in set-car! (1 2) 0\n"]);
  assert.deepEqual(h.run("(string-set! (symbol->string 'abc) 0 #\\x)"), [SCHEME_ERROR, 'error: cannot modify a constant in string-set! "abc" 0 #\\x\n']);
  assert.deepEqual(h.run("(define l (list 1 2)) (set-car! l 0) l"), [OK, "(0 2)\n"]);
  // 2^32 を切り捨てると 0 になる大きさと位置。
  assert.deepEqual(h.run("(make-string 4294967296 #\\a)"), [SCHEME_ERROR, "error: heap limit exceeded\n"]);
  assert.deepEqual(h.run('(string-copy "abc" 4294967296)'), [SCHEME_ERROR, 'error: argument out of range in string-copy "abc" 4294967296\n']);
  assert.deepEqual(h.run('(string-set! (make-string 3 #\\a) 4294967296 #\\b)'), [SCHEME_ERROR, 'error: argument out of range in string-set! "aaa" 4294967296 #\\b\n']);
  assert.deepEqual(h.run('(string-copy! (make-string 3 #\\a) 4294967296 "x")'), [SCHEME_ERROR, 'error: argument out of range in string-copy! "aaa" 4294967296 "x"\n']);
  // エラーのあとも、同じインスタンスが使える。
  assert.deepEqual(h.run('(string-append "a" "b")'), [OK, '"ab"\n']);
});

// バイトベクタ(スライス 3e)。大きさと位置は 64 ビットの整数で、wasm32 の usize は 32 ビットなので、
// 2^32 を超える値が、小さな値に化けて成功しないことを固定する。
test("bytevectors are made, written and converted in wasm32, and a constant is refused", () => {
  const h = instantiate().init();
  assert.deepEqual(h.run("#u8(1 2 3) (bytevector-u8-ref (bytevector 1 2 3) 1) (make-bytevector 2 12)"), [OK, "#u8(1 2 3)\n2\n#u8(12 12)\n"]);
  assert.deepEqual(
    h.run('(define b (bytevector 10 20 30 40 50)) (bytevector-copy! b 1 (bytevector 1 2 3 4 5) 0 2) (list b (bytevector-append b #u8(9)) (bytevector-copy b 3))'),
    [OK, "(#u8(10 1 2 40 50) #u8(10 1 2 40 50 9) #u8(40 50))\n"],
  );
  assert.deepEqual(h.run('(string->utf8 "aλあ𐀀") (utf8->string (string->utf8 "aλあ𐀀")) (utf8->string #u8(97 206 187) 1)'), [OK, '#u8(97 206 187 227 129 130 240 144 128 128)\n"aλあ𐀀"\n"λ"\n']);
  assert.deepEqual(h.run("(equal? #u8(1 2) (bytevector 1 2)) (equal? #u8(1 2) #u8(1 3))"), [OK, "#t\n#f\n"]);
  assert.deepEqual(h.run("(bytevector-u8-set! #u8(1 2 3) 0 9)"), [SCHEME_ERROR, "error: cannot modify a constant in bytevector-u8-set! #u8(1 2 3) 0 9\n"]);
  assert.deepEqual(h.run("(bytevector-copy! '#u8(1 2 3) 0 #u8())"), [SCHEME_ERROR, "error: cannot modify a constant in bytevector-copy! #u8(1 2 3) 0 #u8()\n"]);
  assert.deepEqual(h.run("(utf8->string #u8(237 160 128))"), [SCHEME_ERROR, "error: argument out of range in utf8->string #u8(237 160 128)\n"]);
  // 2^32 を切り捨てると 0 になる大きさと位置。
  assert.deepEqual(h.run("(make-bytevector 4294967296 1)"), [SCHEME_ERROR, "error: heap limit exceeded\n"]);
  assert.deepEqual(h.run("(bytevector-u8-ref #u8(1 2 3) 4294967296)"), [SCHEME_ERROR, "error: argument out of range in bytevector-u8-ref #u8(1 2 3) 4294967296\n"]);
  assert.deepEqual(h.run("(bytevector-u8-set! (bytevector 1 2 3) 4294967296 0)"), [SCHEME_ERROR, "error: argument out of range in bytevector-u8-set! #u8(1 2 3) 4294967296 0\n"]);
  assert.deepEqual(h.run("(bytevector-copy #u8(1 2 3) 4294967296)"), [SCHEME_ERROR, "error: argument out of range in bytevector-copy #u8(1 2 3) 4294967296\n"]);
  assert.deepEqual(h.run("(bytevector-copy! (bytevector 1 2 3) 4294967296 #u8())"), [SCHEME_ERROR, "error: argument out of range in bytevector-copy! #u8(1 2 3) 4294967296 #u8()\n"]);
  assert.deepEqual(h.run('(string->utf8 "abc" 4294967296)'), [SCHEME_ERROR, 'error: argument out of range in string->utf8 "abc" 4294967296\n']);
  // エラーのあとも、同じインスタンスが使える。
  assert.deepEqual(h.run("(bytevector-append #u8(1) #u8(2))"), [OK, "#u8(1 2)\n"]);
});

// 添字は 64 ビットの整数で、wasm32 の usize は 32 ビットである。検査の前に usize へ
// 切り捨てて変えると、2^32 の倍数に近い添字が有効な添字に化ける。ネイティブ(usize が
// 64 ビット)のテストでは見えないので、ここで固定する。ネイティブの側の対応する
// ケースは tests/scheme/0025-primitive-errors.txt にある。
test("an index past 2^32 is out of range in wasm32, not truncated to a valid index", () => {
  const h = instantiate().init();
  // 報告の後ろには、irritant として呼び出しの引数が続く。
  const rangeError = (src, name, args) =>
    assert.deepEqual(h.run(src), [SCHEME_ERROR, `error: argument out of range in ${name} ${args}\n`], src);
  // 対照として、切り捨てた先の添字は有効で、値が取れる。
  assert.deepEqual(h.run('(string-ref "abc" 0) (string-ref "abc" 2)'), [OK, "#\\a\n#\\c\n"]);
  assert.deepEqual(h.run("(vector-ref (vector 5 6) 0) (vector-ref (vector 5 6) 1)"), [OK, "5\n6\n"]);
  rangeError('(string-ref "abc" 4294967296)', "string-ref", '"abc" 4294967296'); // 切り捨てると 0
  rangeError('(string-ref "abc" 4294967298)', "string-ref", '"abc" 4294967298'); // 切り捨てると 2
  rangeError('(string-ref "あいう" 4294967297)', "string-ref", '"あいう" 4294967297'); // 切り捨てると 1
  rangeError("(vector-ref (vector 1) 4294967296)", "vector-ref", "#(1) 4294967296"); // 切り捨てると 0
  rangeError("(vector-ref (vector 5 6) 4294967297)", "vector-ref", "#(5 6) 4294967297"); // 切り捨てると 1
  rangeError("(vector-ref (vector 5 6) 8589934592)", "vector-ref", "#(5 6) 8589934592"); // 2^33。切り捨てると 0
  rangeError("(vector-ref (vector 5 6) 9223372036854775807)", "vector-ref", "#(5 6) 9223372036854775807");
  rangeError("(vector-ref (vector 5 6) -9223372036854775808)", "vector-ref", "#(5 6) -9223372036854775808");
  rangeError('(string-ref "abc" -1)', "string-ref", '"abc" -1');
  // 文字の値も 32 ビットを超える整数は範囲外である。切り捨てると 'A' になる。
  rangeError("(integer->char 4294967361)", "integer->char", "4294967361");
  rangeError("(integer->char 4294967296)", "integer->char", "4294967296");
  // エラーのあとも、同じインスタンスが使える。
  assert.deepEqual(h.run("(vector-ref (vector 5 6) 1)"), [OK, "6\n"]);
});

test("integer division and 128-bit arithmetic agree with the native results in wasm32", () => {
  const h = instantiate().init();
  assert.deepEqual(
    h.run("(quotient -13 4) (quotient 13 -4) (remainder -13 4) (remainder 13 -4) (modulo -13 4) (modulo 13 -4) (modulo -13 -4)"),
    [OK, "-3\n-3\n-1\n1\n3\n-3\n-1\n"],
  );
  // 64 ビットの境界の値。除算は 128 ビットで行う。
  assert.deepEqual(h.run("(modulo -9223372036854775807 4) (modulo 9223372036854775807 -4) (quotient 9223372036854775807 -1)"), [
    OK,
    "1\n-1\n-9223372036854775807\n",
  ]);
  assert.deepEqual(h.run("(remainder -9223372036854775808 -1) (modulo -9223372036854775808 -1) (quotient -9223372036854775808 2)"), [
    OK,
    "0\n0\n-4611686018427387904\n",
  ]);
  // 最小の整数を -1 で割る quotient は、結果が 64 ビットに収まらず、bignum になる。
  assert.deepEqual(h.run("(quotient -9223372036854775808 -1)"), [OK, "9223372036854775808\n"]);
  assert.deepEqual(h.run("(quotient 1 0)"), [SCHEME_ERROR, "error: division by zero in quotient 1 0\n"]);
  assert.deepEqual(h.run("(modulo -9223372036854775808 0)"), [SCHEME_ERROR, "error: division by zero in modulo -9223372036854775808 0\n"]);
  // 128 ビットの積と和。途中の値が 64 ビットを超えても、結果が収まれば値を返す。
  assert.deepEqual(h.run("(* 4294967296 2147483647) (+ 9223372036854775807 1 -1) (- -9223372036854775808 1 -1)"), [
    OK,
    "9223372032559808512\n9223372036854775807\n-9223372036854775808\n",
  ]);
  // 結果が 64 ビットに収まらなければ bignum になる。wasm32 ではlimbs の 1 要素が 32 ビットである。
  assert.deepEqual(h.run("(* 3037000500 3037000500) (+ 9223372036854775807 1) (* 4294967296 4294967296 4294967296)"), [
    OK,
    "9223372037000250000\n9223372036854775808\n79228162514264337593543950336\n",
  ]);
  // bignum が fixnum に戻る。有理数は約分され、分母が 1 なら整数になる。
  assert.deepEqual(h.run("(- (* 4294967296 4294967296) (* 4294967296 4294967296)) (/ 1 3) (/ 6 4) (/ 6 3) (+ (/ 1 2) (/ 1 3))"), [
    OK,
    "0\n1/3\n3/2\n2\n5/6\n",
  ]);
  assert.deepEqual(h.run("(< (/ 1 3) (/ 1 2) (+ 9223372036854775807 1)) (= (* 4294967296 4294967296) (* 4294967296 4294967296))"), [OK, "#t\n#t\n"]);
  assert.deepEqual(h.run("(/ 1 0)"), [SCHEME_ERROR, "error: division by zero in / 1 0\n"]);
});

test("a tail-recursive loop of 100000 iterations completes", () => {
  const h = instantiate().init();
  const [status, text] = h.run("(define (loop n) (if (= n 0) 'done (loop (- n 1)))) (loop 100000)");
  assert.equal(status, OK);
  assert.equal(text, "done\n");
});

test("a region allocated before reset is still the host's: it can be used and freed", () => {
  const h = instantiate().init();
  const source = new TextEncoder().encode("(+ 1 2)");
  const ptr = h.x.sucheme_alloc(source.length);
  assert.notEqual(ptr, 0);
  h.bytes(ptr, source.length).set(source);
  assert.equal(h.x.sucheme_reset(), OK);
  assert.equal(h.x.sucheme_eval_begin(ptr, source.length), CONTINUE);
  assert.equal(h.x.sucheme_step(0xffffffff), OK);
  assert.equal(h.output(), "3\n");
  // free は panic しない。リセットが領域の記録を捨てていると、ここで trap する。
  h.x.sucheme_free(ptr, source.length);
});

// ページのサンプル(web/samples.mjs)。どれも評価できて、期待する出力になる。期待は、サンプルの
// 識別子で引く。サンプルを足して期待を足し忘れても、期待だけが残っても、落ちる。
const sampleOutputs = {
  factorial: "3628800\n",
  "tail-loop": "5000050000\n",
  counter: "1\n2\n1\n3\n",
  lists: "(9 1 4)\n(3 1 2 4 5)\n(2 1 3)\n(b 2)\n(1 2)\n",
  record: "3\n10\n#t\n#f\n",
  escape: '42\n4\n"boom"\n',
  "numeric-tower": "265252859812191058636308480000000\n1267650600228229401496703205376\n1/3\n1/2\n0.3333333333333333\n4\n1.4142135623730951\n",
  strings: '"Scheme λ"\n"HELLO"\n5\n"cba"\n"world"\n#t\n1000.0\nfoo\n',
  "string-ports": '"sym and \\"text\\""\n(a b)\n42\n"s"\n#t\n',
  "dynamic-wind": "escaped\n(in body out)\n",
  library: "2\n1\n",
};

test("every sample of the page evaluates to its expected output, and the table matches the samples", () => {
  const ids = samples.map((sample) => sample.id);
  assert.equal(new Set(ids).size, ids.length, "sample ids are unique");
  assert.deepEqual([...ids].sort(), Object.keys(sampleOutputs).sort());
  for (const sample of samples) {
    assert.ok(sample.title.length > 0 && sample.source.length > 0, `${sample.id} has a title and a source`);
    // 「リセット」のあとと同じく、サンプルは何も定義していない状態から走る。
    const h = instantiate().init();
    assert.deepEqual(h.run(sample.source), [OK, sampleOutputs[sample.id]], sample.id);
  }
});

// プログラム集(docs/manual/programs/)を、同じ WASM で走らせ、`.out` と比べる(計画書 0030 の決定6)。
// 対象は、ファイル、コマンドライン、標準入力を使わないもの、つまり `.args` `.in` `.files/` の
// どれも持たないもので、下の除外の一覧に無いものである。WASM の入口は、`.scm` の全体を1回の評価で
// 走らせる。`.out` の最後の行が `[exit N]` なら、状態コードは EXITED で、終了コードは N である。
const programsDir = new URL("../../docs/manual/programs/", import.meta.url);
// 除外の一覧。WASM では出力が `.out` と一致しないプログラムと、その理由である。
// 理由の2つの類型: 「値の出力」は、WASM の入口が、トップレベルの式の値を(未指定を除いて)
// 出力に書くが、ファイルの実行は書かないこと。「ファイル」は、WASM にファイルの表が無いこと。
const programExclusions = {
  "bank-account": "値の出力: トップレベルの式の値が出力に加わる",
  "control-macros": "値の出力: トップレベルの式の値が出力に加わる",
  "early-exit": "値の出力: トップレベルの式の値が出力に加わる",
  memoize: "値の出力: トップレベルの式の値が出力に加わる",
  "file-roundtrip": "ファイル: ファイルの表が無い(作業ディレクトリへの書き込みが失敗する)",
};

function programNames() {
  const entries = readdirSync(programsDir);
  const names = entries.filter((f) => f.endsWith(".scm")).map((f) => f.slice(0, -".scm".length)).sort();
  const aux = (name) => [".args", ".in", ".files"].some((ext) => entries.includes(name + ext));
  return names.filter((name) => !aux(name));
}

test("the programs of the manual that use no files, arguments or input give their .out in wasm", () => {
  const names = programNames();
  // 対象(`.args` `.in` `.files/` を持たない本)の下限と、除外の本数の上限。実際に走らせる本が、
  // 検査の対象から静かに減らないようにする。本が増えても、直さずに済む形にしてある。
  const excluded = Object.keys(programExclusions).length;
  assert.ok(names.length >= 40, `found ${names.length} programs that qualify`);
  assert.ok(names.length - excluded >= 35, `only ${names.length - excluded} programs are run`);
  assert.ok(excluded * 4 <= names.length, `${excluded} exclusions out of ${names.length}`);
  for (const name of Object.keys(programExclusions)) {
    assert.ok(names.includes(name), `the exclusion ${name} names a program that does not exist or does not qualify`);
  }
  for (const name of names) {
    if (name in programExclusions) continue;
    let expected = readFileSync(new URL(`${name}.out`, programsDir), "utf8");
    const exit = /\[exit (\d+)\]\n?$/.exec(expected);
    if (exit) expected = expected.slice(0, exit.index);
    const h = instantiate().init();
    const [status, text] = h.run(readFileSync(new URL(`${name}.scm`, programsDir), "utf8"));
    // 比較は厳密である(末尾の改行を含む)。`trimEnd()` などで緩めない。
    assert.equal(text, expected, name);
    assert.equal(status, exit ? EXITED : OK, name);
    if (exit) assert.equal(h.x.sucheme_exit_code(), Number(exit[1]), name);
  }
});

test("each program excluded from the wasm run really differs there (the list holds no stale entry)", () => {
  for (const name of Object.keys(programExclusions)) {
    let expected = readFileSync(new URL(`${name}.out`, programsDir), "utf8");
    const exit = /\[exit (\d+)\]\n?$/.exec(expected);
    if (exit) expected = expected.slice(0, exit.index);
    const h = instantiate().init();
    const [status, text] = h.run(readFileSync(new URL(`${name}.scm`, programsDir), "utf8"));
    assert.ok(text !== expected || status !== (exit ? EXITED : OK), `${name} now matches; remove it from programExclusions`);
  }
});

// 編集の補助(web/parens.mjs、web/history.mjs)。DOM に触れない部分を試す。
// 括弧の対応は、src/line_editor/parens.zig と同じ一覧(tests/parens/cases.tsv)を読む。
function unescapeCase(field) {
  return field.replace(/\\([\\ntr])/g, (_, c) => ({ "\\": "\\", n: "\n", t: "\t", r: "\r" })[c]);
}

test("matching agrees with the list shared with parens.zig for every cursor", () => {
  const lines = readFileSync(new URL("../../tests/parens/cases.tsv", import.meta.url), "utf8").split("\n").filter((l) => l !== "");
  assert.ok(lines.length > 50);
  for (const line of lines) {
    const tab = line.indexOf("\t");
    const text = unescapeCase(line.slice(0, tab));
    const expected = line.slice(tab + 1).split(" ").map((f) => (f === "-" ? null : Number(f)));
    assert.equal(expected.length, text.length + 1, JSON.stringify(text));
    for (let cursor = 0; cursor < expected.length; cursor++) {
      assert.equal(matching(text, cursor), expected[cursor], `${JSON.stringify(text)} at ${cursor}`);
    }
  }
});

test("matching counts positions in UTF-16 units, also after a character literal outside the BMP", () => {
  assert.equal(matching("(あ (い) う)", 0), 8);
  assert.equal(matching("(あ)", 3), 0);
  // 補助面の文字(サロゲートペア)が `#\` の本体のとき、その2単位を1文字として読む。
  assert.equal(matching("(#\\𝄞 (b))", 0), 9);
  assert.equal(matching("(#\\𝄞)", 0), 5);
  // 上限の補助面の文字(上位サロゲートが U+DBFF)も、同じである。
  assert.equal(matching("(#\\\u{10FFFF}(b))", 0), 8);
  // 範囲外と、整数でない位置は、何も見つけない。
  assert.equal(matching("(a)", 4), null);
  assert.equal(matching("(a)", -1), null);
  assert.equal(matching("(a)", 1.5), null);
  assert.equal(matching("(a)", undefined), null);
});

test("highlightPair returns the pair in ascending order, from either side", () => {
  assert.deepEqual(highlightPair("(a (b) c)", 0), [0, 8]);
  assert.deepEqual(highlightPair("(a (b) c)", 9), [0, 8]);
  assert.deepEqual(highlightPair("(a (b) c)", 3), [3, 5]);
  assert.deepEqual(highlightPair("(a (b) c)", 6), [3, 5]);
  // `)(` の間では、直前の `)` が先に効く。
  assert.deepEqual(highlightPair("(a)(b)", 3), [0, 2]);
  // 直前の `)` に相手が無ければ、直後の `(` を見る。
  assert.deepEqual(highlightPair("a)(b)", 2), [2, 4]);
  assert.equal(highlightPair("(a b)", 2), null);
  assert.equal(highlightPair("(a", 0), null);
});

test("changeIndent inserts at the caret, indents and outdents whole lines, and keeps the selection on the same text", () => {
  // 選択が無いときは、カーソルの位置に挿入する。
  assert.deepEqual(changeIndent("ab", 1, 1, false), { text: "a  b", start: 3, end: 3 });
  // 1行の中の選択は、置き換える。
  assert.deepEqual(changeIndent("abc", 0, 2, false), { text: "  c", start: 2, end: 2 });
  // 複数行の選択は、掛かる行すべての先頭に足す(空の行には足さない)。
  assert.deepEqual(changeIndent("a\n\nb", 0, 4, false), { text: "  a\n\n  b", start: 0, end: 8 });
  // 選択の終わりが行の先頭ちょうどなら、その行は含めない。
  assert.deepEqual(changeIndent("a\nb\n", 0, 2, false), { text: "  a\nb\n", start: 0, end: 4 });
  // 選択の途中の端は、変えた行の分だけずれる。
  assert.deepEqual(changeIndent("ab\ncd", 1, 4, false), { text: "  ab\n  cd", start: 3, end: 8 });
  // Shift+Tab は、カーソルだけでも、その行の字下げを取る。
  assert.deepEqual(changeIndent("    a", 5, 5, true), { text: "  a", start: 3, end: 3 });
  assert.deepEqual(changeIndent("\ta\n b", 0, 5, true), { text: "a\nb", start: 0, end: 3 });
  // 字下げの無い行は、そのまま。カーソルは、行の先頭より前に戻さない。
  assert.deepEqual(changeIndent("a", 1, 1, true), { text: "a", start: 1, end: 1 });
  assert.deepEqual(changeIndent("  a", 1, 1, true), { text: "a", start: 0, end: 0 });
  // 取るのは INDENT 1つ分までである。
  assert.deepEqual(changeIndent("      a", 7, 7, true), { text: "    a", start: 5, end: 5 });
});

test("Esc arms the Tab that moves focus, modifier keys alone keep it, and any other key disarms it", () => {
  assert.equal(nextTabMovesFocus(false, "Escape", "ready"), true);
  // 評価中の Esc は停止に使う。
  assert.equal(nextTabMovesFocus(false, "Escape", "running"), false);
  // Esc のあとの Shift+Tab: Shift 自体の keydown は、状態を変えない。
  for (const key of ["Shift", "Control", "Alt", "Meta"]) {
    assert.equal(nextTabMovesFocus(true, key, "ready"), true, key);
    assert.equal(nextTabMovesFocus(false, key, "ready"), false, key);
  }
  for (const key of ["a", "ArrowUp", "Enter", " "]) assert.equal(nextTabMovesFocus(true, key, "ready"), false, key);
});

test("the history walks back and forth, and keeps what was being typed", () => {
  const h = createHistory();
  assert.equal(h.previous("draft"), null);
  assert.equal(h.next(), null);
  h.push("(+ 1 2)");
  h.push("(display 3)");
  assert.equal(h.previous("typing"), "(display 3)");
  assert.equal(h.previous("ignored"), "(+ 1 2)");
  assert.equal(h.previous("ignored"), null); // いちばん古い
  assert.equal(h.next(), "(display 3)");
  assert.equal(h.next(), "typing"); // 下書きに戻る
  assert.equal(h.next(), null);
  // 実行すると、位置は下書きに戻り、下書きは捨てる。
  assert.equal(h.previous("another"), "(display 3)");
  h.push("x");
  assert.equal(h.previous(""), "x");
  assert.equal(h.next(), "");
});

test("the history skips an empty input and a repeat of the last input, and drops the oldest past its limit", () => {
  const h = createHistory(3);
  h.push("");
  h.push("  \n");
  assert.equal(h.length, 0);
  h.push("a");
  h.push("a");
  assert.equal(h.length, 1);
  h.push("b");
  h.push("a"); // 直前と違えば、同じ入力でも足す
  assert.equal(h.length, 3);
  h.push("c");
  assert.equal(h.length, 3);
  assert.equal(h.previous(""), "c");
  assert.equal(h.previous(""), "a");
  assert.equal(h.previous(""), "b");
  assert.equal(h.previous(""), null);
});

test("onFirstLine and onLastLine look for a newline before and after the caret", () => {
  assert.ok(onFirstLine("a\nb", 1));
  assert.ok(!onFirstLine("a\nb", 2));
  assert.ok(onFirstLine("", 0));
  assert.ok(onLastLine("a\nb", 2));
  assert.ok(!onLastLine("a\nb", 1));
  assert.ok(!onLastLine("a\n", 1));
  assert.ok(onLastLine("a\n", 2));
});

// 共有リンク(web/share.mjs): `#code=<UTF-8 の base64url>`。
test("a share fragment round-trips any source, and is a url-safe form", () => {
  for (const source of ["", "a", "(+ 1 2)", "日本語 ✓ 𝄞\n(define x 1)", "x".repeat(3000), "\u0000\u00ff~?>"]) {
    const fragment = encodeFragment(source);
    assert.match(fragment, /^#code=[A-Za-z0-9_-]*$/);
    assert.equal(decodeFragment(fragment), source);
  }
  // 既知の値で、符号化そのものを固定する(往復だけでは、対の誤りが打ち消し合う)。
  assert.equal(encodeFragment("(+ 1 2)"), "#code=KCsgMSAyKQ");
  assert.equal(encodeFragment("\u00ff\u00fe"), "#code=w7_Dvg");
});

test("a fragment that is not a share link is read as null, and so is one that is too long", () => {
  for (const bad of ["", "#", "#code", "#x=KCsgMSAyKQ", "code=KCsgMSAyKQ", "#code=!!", "#code=a", "#code=KCsgMSAyKQ==", "#code=_w", "#code=KCsgMSAy+Q", undefined, 5]) {
    assert.equal(decodeFragment(bad), null, String(bad));
  }
  // 空のソースは、正しいリンクである。
  assert.equal(decodeFragment("#code="), "");
  // 上限は、作るときも読むときも同じである。
  const longest = "x".repeat(Math.floor(((MAX_FRAGMENT_LENGTH - "#code=".length) * 3) / 4));
  assert.ok(encodeFragment(longest) !== null);
  assert.equal(decodeFragment(encodeFragment(longest)), longest);
  assert.equal(encodeFragment(longest + "xxxx"), null);
  assert.equal(decodeFragment("#code=" + "A".repeat(MAX_FRAGMENT_LENGTH)), null);
});

// 停止の操作(web/stop.mjs)。
test("formatElapsed shows seconds below a minute, then minutes and hours", () => {
  assert.equal(formatElapsed(0), "0.0 s");
  assert.equal(formatElapsed(99), "0.0 s");
  assert.equal(formatElapsed(100), "0.1 s");
  assert.equal(formatElapsed(1234), "1.2 s");
  assert.equal(formatElapsed(59999), "59.9 s");
  assert.equal(formatElapsed(60000), "1:00");
  assert.equal(formatElapsed(65999), "1:05");
  assert.equal(formatElapsed(3599999), "59:59");
  assert.equal(formatElapsed(3600000), "1:00:00");
  assert.equal(formatElapsed(3723000), "1:02:03");
  // 異常な値は 0 として扱う。
  assert.equal(formatElapsed(-5), "0.0 s");
  assert.equal(formatElapsed(NaN), "0.0 s");
  assert.equal(formatElapsed(Infinity), "0.0 s");
});

test("the stop messages say that definitions are kept, and that they are lost only when the worker was restarted", () => {
  assert.match(stopWarning.before, /Definitions made so far are kept/);
  assert.match(stopWarning.lost, /did not respond/);
  assert.match(stopWarning.lost, /all definitions were lost/);
  assert.equal(restartedMessage(2500), `${stopWarning.lost} (ran for 2.5 s)`);
  assert.ok(stopTimeoutMs >= 1000 && stopTimeoutMs <= 10000);
});

test("describeStopped keeps the output and the time, and tells that definitions were kept", () => {
  const d = describeStopped("abc", 1500);
  assert.equal(d.output, "abc");
  assert.equal(d.error.title, "Stopped");
  assert.equal(d.error.message, "ran for 1.5 s");
  assert.match(d.error.hint, /Definitions made so far were kept/);
});

test("isStopKey stops only on Escape while running and not while composing", () => {
  assert.equal(isStopKey({ key: "Escape" }, "running"), true);
  assert.equal(isStopKey({ key: "Escape", isComposing: false }, "running"), true);
  assert.equal(isStopKey({ key: "Escape", isComposing: true }, "running"), false);
  assert.equal(isStopKey({ key: "Escape" }, "ready"), false);
  assert.equal(isStopKey({ key: "Escape" }, "loading"), false);
  assert.equal(isStopKey({ key: "Enter" }, "running"), false);
});

// 歩数ごとに制御を戻す評価(sucheme_step、sucheme_abort。計画書 0030 の 8e-2)。
test("eval_begin goes on with 1, step(0) moves nothing, and step finishes with 0 and the same output as one run", () => {
  const h = instantiate().init();
  const program = "(define (f n) (if (= n 0) 'done (f (- n 1)))) (write-string \"a\") (f 50000)";
  assert.equal(h.begin(program), CONTINUE);
  assert.equal(h.x.sucheme_step(0), CONTINUE);
  assert.equal(h.x.sucheme_step(0), CONTINUE);
  let rounds = 0;
  let status;
  do {
    status = h.x.sucheme_step(1000);
    rounds += 1;
  } while (status === CONTINUE);
  assert.equal(status, OK);
  assert.ok(rounds > 10, `the evaluation was split into ${rounds} steps`);
  const split = h.output();
  const whole = instantiate().init().run(program);
  assert.deepEqual([OK, split], whole);
});

test("what needs no machine step finishes in eval_begin: an empty input, a comment, and a library declaration", () => {
  const h = instantiate().init();
  assert.equal(h.begin(""), OK);
  assert.equal(h.begin("; only a comment\n"), OK);
  assert.equal(h.begin("(define-library (x) (import (scheme base)) (export f) (begin (define (f) 5)))"), OK);
  assert.equal(h.x.sucheme_step(10), WRONG_ORDER);
});

test("the output of each step can be taken between steps, so a run may write more than the buffer holds", () => {
  const h = instantiate().init();
  // 1回の書き込みは 1000 バイト、400 回で 400000 バイトで、出力バッファ(262144 バイト)を超える。
  const program = '(define (go n) (if (> n 0) (begin (write-string (make-string 1000 #\\x)) (go (- n 1))))) (go 400)';
  assert.equal(h.begin(program), CONTINUE);
  let total = 0;
  let status;
  do {
    status = h.x.sucheme_step(500);
    total += h.x.sucheme_output_len();
    h.x.sucheme_output_clear();
  } while (status === CONTINUE);
  assert.equal(status, OK);
  assert.equal(total, 400000);
});

test("steps of a few machine steps keep every value alive across the collections between them", () => {
  const h = instantiate().init();
  const program =
    "(define (build n acc) (if (= n 0) acc (build (- n 1) (cons (make-vector 3 n) acc)))) " +
    "(define big (build 3000 '())) (define (sum l a) (if (null? l) a (sum (cdr l) (+ a (vector-ref (car l) 0))))) (sum big 0)";
  assert.equal(h.begin(program), CONTINUE);
  let status;
  do status = h.x.sucheme_step(37);
  while (status === CONTINUE);
  assert.equal(status, OK);
  assert.equal(h.output(), "4501500\n");
});

test("abort drops the evaluation and keeps the definitions, and the next evaluation can start", () => {
  const h = instantiate().init();
  assert.equal(h.begin("(define x 42) (write-string \"before\") (define (spin) (spin)) (spin) (define never 1)"), CONTINUE);
  assert.equal(h.x.sucheme_step(100000), CONTINUE);
  // 止まらない評価の途中までの出力が残っている。
  assert.equal(h.output(), "before");
  h.x.sucheme_output_clear();
  assert.equal(h.x.sucheme_abort(), OK);
  assert.deepEqual(h.run("x"), [OK, "42\n"]);
  // 捨てた評価の続きは、実行されていない。
  const [status, text] = h.run("never");
  assert.equal(status, SCHEME_ERROR);
  assert.match(text, /^error: /);
});

test("abort and step with no evaluation return wrong_order and leave the state alone", () => {
  const h = instantiate().init();
  assert.equal(h.run("(define y 7)")[0], OK);
  assert.equal(h.x.sucheme_abort(), WRONG_ORDER);
  assert.match(h.output(), /no evaluation is in progress/);
  h.x.sucheme_output_clear();
  assert.equal(h.x.sucheme_step(10), WRONG_ORDER);
  assert.match(h.output(), /no evaluation is in progress/);
  h.x.sucheme_output_clear();
  assert.deepEqual(h.run("y"), [OK, "7\n"]);
  // 完了のあとの step も同じである。
  assert.equal(h.begin("(+ 1 2)"), CONTINUE);
  assert.equal(h.x.sucheme_step(0xffffffff), OK);
  assert.equal(h.x.sucheme_step(10), WRONG_ORDER);
});

test("before init, step and abort return not_initialized and say why", () => {
  const h = instantiate();
  assert.equal(h.x.sucheme_step(1), NOT_INITIALIZED);
  assert.match(h.output(), /not initialized/);
  h.x.sucheme_output_clear();
  assert.equal(h.x.sucheme_abort(), NOT_INITIALIZED);
  assert.match(h.output(), /not initialized/);
});

test("eval_begin while an evaluation goes on returns wrong_order, and that evaluation is unharmed", () => {
  const h = instantiate().init();
  assert.equal(h.begin("(define (f n) (if (= n 0) 'ok (f (- n 1)))) (f 100000) (write-string \"end\")"), CONTINUE);
  assert.equal(h.x.sucheme_step(10), CONTINUE);
  h.x.sucheme_output_clear();
  assert.equal(h.begin("(display 1)"), WRONG_ORDER);
  assert.match(h.output(), /an evaluation is in progress/);
  h.x.sucheme_output_clear();
  let status;
  do status = h.x.sucheme_step(0xffffffff);
  while (status === CONTINUE);
  assert.equal(status, OK);
  assert.equal(h.output(), "ok\nend");
});

test("set_command_line is refused while an evaluation goes on, and works after it", () => {
  const h = instantiate().init();
  assert.equal(h.begin("(import (scheme process-context)) (define (f n) (if (= n 0) (command-line) (f (- n 1)))) (f 100000)"), CONTINUE);
  const bytes = new TextEncoder().encode("prog\nx");
  const ptr = h.x.sucheme_alloc(bytes.length);
  h.bytes(ptr, bytes.length).set(bytes);
  assert.equal(h.x.sucheme_set_command_line(ptr, bytes.length), 0);
  let status;
  do status = h.x.sucheme_step(0xffffffff);
  while (status === CONTINUE);
  assert.equal(status, OK);
  assert.equal(h.output(), "(\"sucheme\")\n");
  assert.equal(h.x.sucheme_set_command_line(ptr, bytes.length), 1);
  h.x.sucheme_free(ptr, bytes.length);
});

test("an error in a later step returns -1 with the line after the output so far, and evaluation can continue", () => {
  const h = instantiate().init();
  assert.equal(h.begin("(define (f n) (if (= n 0) (car 5) (f (- n 1)))) (write-string \"x\") (f 10000)"), CONTINUE);
  let status;
  do status = h.x.sucheme_step(100);
  while (status === CONTINUE);
  assert.equal(status, SCHEME_ERROR);
  assert.match(h.output(), /^xerror: /);
  h.x.sucheme_output_clear();
  // 終わった評価のあとは、ふつうに次を評価できる。
  assert.deepEqual(h.run("(+ 1 2)"), [OK, "3\n"]);
});

test("exit in a later step returns -6, and only a reset goes on", () => {
  const h = instantiate().init();
  assert.equal(h.begin("(import (scheme process-context)) (define (f n) (if (= n 0) (exit 3) (f (- n 1)))) (f 10000)"), CONTINUE);
  let status;
  do status = h.x.sucheme_step(100);
  while (status === CONTINUE);
  assert.equal(status, EXITED);
  assert.equal(h.x.sucheme_exit_code(), 3);
  assert.equal(h.begin("1"), WRONG_ORDER);
  assert.equal(h.x.sucheme_step(1), WRONG_ORDER);
  assert.equal(h.x.sucheme_reset(), OK);
  assert.deepEqual(h.run("1"), [OK, "1\n"]);
});

test("a reset during an evaluation drops it and the definitions", () => {
  const h = instantiate().init();
  assert.equal(h.run("(define z 1)")[0], OK);
  assert.equal(h.begin("(define (spin) (spin)) (spin)"), CONTINUE);
  assert.equal(h.x.sucheme_step(1000), CONTINUE);
  assert.equal(h.x.sucheme_reset(), OK);
  assert.equal(h.x.sucheme_step(1), WRONG_ORDER);
  assert.equal(h.run("z")[0], SCHEME_ERROR);
  assert.deepEqual(h.run("(+ 1 1)"), [OK, "2\n"]);
});

test("the step limit of a non-terminating input is not an issue: stop by abort leaves no leak across 200 rounds", () => {
  // 評価ごとに入力の写しとアリーナを作って捨てる。捨て忘れは、200 回で線形メモリを膨らませる。
  const h = instantiate().init();
  const before = h.x.memory.buffer.byteLength;
  for (let i = 0; i < 200; i += 1) {
    assert.equal(h.begin("(define (spin) (spin)) (spin)"), CONTINUE);
    assert.equal(h.x.sucheme_step(100), CONTINUE);
    assert.equal(h.x.sucheme_abort(), OK);
  }
  assert.ok(h.x.memory.buffer.byteLength - before < 4 * 1024 * 1024, "the memory did not grow without bound");
});

// 入力待ち(スライス 8f-1、docs/design/platform-and-web.md の再開可能性)。
const WAITING = 2;
/** The libraries the programs of these tests import: `write` and `read` are not in the standard environment of the top level. */
const W = "(import (scheme write) (scheme read)) ";

/** Gives the waiting read `text` through alloc, provide_input and free, and returns the status. */
function provide(h, text) {
  const bytes = new TextEncoder().encode(text);
  const ptr = h.x.sucheme_alloc(bytes.length);
  assert.notEqual(ptr, 0);
  h.bytes(ptr, bytes.length).set(bytes);
  const status = h.x.sucheme_provide_input(ptr, bytes.length);
  h.x.sucheme_free(ptr, bytes.length);
  return status;
}

test("a read that finds no input stops with 2, takes the input that arrives, and the same read goes on", () => {
  const h = instantiate().init();
  assert.equal(h.begin(W + '(write-string "name? ") (write (read-line))'), CONTINUE);
  assert.equal(h.x.sucheme_step(1000), WAITING);
  // 待つ前までの出力は取れる。
  assert.equal(h.output(), "name? ");
  h.x.sucheme_output_clear();
  assert.equal(provide(h, "Ada\n"), CONTINUE);
  assert.equal(h.x.sucheme_step(1000), OK);
  assert.equal(h.output(), '"Ada"');
});

test("provide_input and provide_eof return wrong_order unless a read waits, and change nothing", () => {
  const h = instantiate().init();
  assert.equal(provide(h, "x"), WRONG_ORDER);
  assert.match(h.output(), /no read is waiting/);
  h.x.sucheme_output_clear();
  assert.equal(h.x.sucheme_provide_eof(), WRONG_ORDER);
  h.x.sucheme_output_clear();
  // 評価が続いていても、待っていなければ同じである。
  assert.equal(h.begin("(define (f n) (if (= n 0) 'ok (f (- n 1)))) (f 100000) (read-char)"), CONTINUE);
  assert.equal(h.x.sucheme_step(10), CONTINUE);
  assert.equal(provide(h, "x"), WRONG_ORDER);
  h.x.sucheme_output_clear();
  // 待つところまで進めれば、受け取る。渡した入力は、ここで捨てられていない。
  let status;
  do status = h.x.sucheme_step(1000);
  while (status === CONTINUE);
  assert.equal(status, WAITING);
  assert.equal(provide(h, "xy"), CONTINUE);
  assert.equal(h.x.sucheme_step(1000), OK);
  // 評価が終わると、また受け取らない。
  assert.equal(provide(h, "z"), WRONG_ORDER);
});

test("before init, provide_input and provide_eof return not_initialized and say why", () => {
  const h = instantiate();
  assert.equal(h.x.sucheme_provide_input(0, 0), NOT_INITIALIZED);
  assert.match(h.output(), /not initialized/);
  h.x.sucheme_output_clear();
  assert.equal(h.x.sucheme_provide_eof(), NOT_INITIALIZED);
  assert.match(h.output(), /not initialized/);
});

test("provide_input rejects what is not UTF-8 or not a region, and the read goes on waiting", () => {
  const h = instantiate().init();
  assert.equal(h.begin(W + "(write (read-char))"), CONTINUE);
  assert.equal(h.x.sucheme_step(1000), WAITING);
  const ptr = h.x.sucheme_alloc(2);
  h.bytes(ptr, 2).set([0xc3, 0x28]);
  assert.equal(h.x.sucheme_provide_input(ptr, 2), INVALID_UTF8);
  assert.match(h.output(), /invalid UTF-8 at byte 0/);
  h.x.sucheme_output_clear();
  assert.equal(h.x.sucheme_provide_input(ptr, 4096 * 64), BAD_REGION);
  h.x.sucheme_output_clear();
  h.x.sucheme_free(ptr, 2);
  // 状態は変わっていない。待ちのままで、正しい入力を受け取れる。
  assert.equal(h.x.sucheme_step(1000), WAITING);
  assert.equal(provide(h, "é"), CONTINUE);
  assert.equal(h.x.sucheme_step(1000), OK);
  assert.equal(h.output(), "#\\é");
});

test("input longer than one read is kept for the next, and an empty input gives nothing", () => {
  const h = instantiate().init();
  assert.equal(h.begin(W + "(write (list (read-char) (read-char) (read-char)))"), CONTINUE);
  assert.equal(h.x.sucheme_step(1000), WAITING);
  assert.equal(provide(h, ""), CONTINUE);
  assert.equal(h.x.sucheme_step(1000), WAITING);
  assert.equal(provide(h, "ab"), CONTINUE);
  // 2文字では足りない。3つ目の読み取りで、また待つ。1つ目と2つ目は、やり直されていない。
  assert.equal(h.x.sucheme_step(1000), WAITING);
  assert.equal(provide(h, "c"), CONTINUE);
  assert.equal(h.x.sucheme_step(1000), OK);
  assert.equal(h.output(), "(#\\a #\\b #\\c)");
});

test("provide_eof ends the input for this and every later read, until reset", () => {
  const h = instantiate().init();
  assert.equal(h.begin("(let loop ((n 0)) (let ((c (read-char))) (if (eof-object? c) n (loop (+ n 1)))))"), CONTINUE);
  assert.equal(h.x.sucheme_step(1000), WAITING);
  assert.equal(provide(h, "xyz"), CONTINUE);
  assert.equal(h.x.sucheme_step(1000), WAITING);
  assert.equal(h.x.sucheme_provide_eof(), CONTINUE);
  assert.equal(h.x.sucheme_step(1000), OK);
  assert.equal(h.output(), "3\n");
  h.x.sucheme_output_clear();
  // 終端のあとは、待たずに終端を返す。
  assert.equal(h.run("(import (scheme read))")[0], OK);
  assert.deepEqual(h.run("(list (eof-object? (read-char)) (eof-object? (read-line)) (eof-object? (read)))"), [OK, "(#t #t #t)\n"]);
  // reset は終端を忘れる。
  assert.equal(h.x.sucheme_reset(), OK);
  assert.equal(h.begin("(read-char)"), CONTINUE);
  assert.equal(h.x.sucheme_step(1000), WAITING);
});

test("abort drops a waiting evaluation and keeps the definitions, and so does an evaluation that gives up on a refused input", () => {
  const h = instantiate().init();
  assert.equal(h.begin("(define kept 5) (read-line)"), CONTINUE);
  assert.equal(h.x.sucheme_step(1000), WAITING);
  assert.equal(h.x.sucheme_abort(), OK);
  assert.deepEqual(h.run("kept"), [OK, "5\n"]);
  // 待っている間に step を呼んでも、入力が無ければ、また 2 である。
  assert.equal(h.begin("(read-char)"), CONTINUE);
  assert.equal(h.x.sucheme_step(1000), WAITING);
  assert.equal(h.x.sucheme_step(1000), WAITING);
  assert.equal(h.x.sucheme_abort(), OK);
  assert.equal(h.x.sucheme_abort(), WRONG_ORDER);
});

test("a long input is counted against the heap limit: provide_input refuses it with -1 and drops the evaluation", () => {
  const h = instantiate();
  assert.equal(h.x.sucheme_init(small_limit), OK);
  assert.equal(h.begin("(define kept 1) (read-string 10)"), CONTINUE);
  assert.equal(h.x.sucheme_step(1000), WAITING);
  assert.equal(provide(h, "x".repeat(small_limit * 2)), SCHEME_ERROR);
  assert.match(h.output(), /heap limit exceeded/);
  h.x.sucheme_output_clear();
  // 評価は捨てられ、定義は残り、次の評価は走る。
  assert.deepEqual(h.run("kept"), [OK, "1\n"]);
  // 入力が収まる範囲なら、受け取る。
  assert.equal(h.begin("(read-string 3)"), CONTINUE);
  assert.equal(h.x.sucheme_step(1000), WAITING);
  assert.equal(provide(h, "abc"), CONTINUE);
  assert.equal(h.x.sucheme_step(1000), OK);
  assert.equal(h.output(), '"abc"\n');
});

test("Sucheme.provideInput and provideEof drive a read through the wrapper, and runEvaluation reports the wait", async () => {
  const s = await loadSucheme();
  assert.equal(s.begin(W + "(write (read-line))").status, Status.CONTINUE);
  assert.equal(s.step(1000).status, Status.WAITING_INPUT);
  assert.equal(s.provideInput("hi there\n").status, Status.CONTINUE);
  assert.deepEqual(s.step(1000), { status: OK, output: '"hi there"' });
  assert.equal(s.provideInput("late").status, WRONG_ORDER);
  assert.equal(s.begin(W + "(write (read-char))").status, Status.CONTINUE);
  assert.equal(s.step(1000).status, Status.WAITING_INPUT);
  assert.equal(s.provideEof().status, Status.CONTINUE);
  assert.deepEqual(s.step(1000), { status: OK, output: "#<eof>" });
  // runEvaluation は、待ちを終わりとして返す(画面での入力の受け取りは 8f-2)。
  // 終端は reset まで残るので、新しいインスタンスで試す。
  const t = await loadSucheme();
  const result = await runEvaluation(t, "(read-char)", { shouldStop: () => false, yieldControl: async () => {} });
  assert.equal(result.status, Status.WAITING_INPUT);
  assert.equal(t.abort(), OK);
});

// 実行の進め方(web/runner.mjs)。Sucheme(web/sucheme.js)を通して、本物の WASM で試す。
async function loadSucheme() {
  const s = await Sucheme.load(readFileSync(wasmPath));
  assert.equal(s.init(), OK);
  return s;
}

test("runEvaluation gives control back between slices, and gives the same result as eval", async () => {
  const s = await loadSucheme();
  const program = "(define (f n) (if (= n 0) 'done (f (- n 1)))) (write-string \"a\") (f 200000)";
  let yields = 0;
  const result = await runEvaluation(s, program, {
    shouldStop: () => false,
    yieldControl: async () => {
      yields += 1;
    },
    budget: 1000,
    // 時計は進めない。1スライス = 1回の step になる。
    now: () => 0,
    sliceMs: 0,
  });
  assert.equal(result.stopped, false);
  assert.equal(result.status, OK);
  assert.ok(yields > 50, `control came back ${yields} times`);
  const whole = (await loadSucheme()).eval(program);
  assert.deepEqual({ status: result.status, output: result.output }, whole);
});

test("runEvaluation stops a non-terminating evaluation at a slice, keeps the definitions and the output so far", async () => {
  const s = await loadSucheme();
  let yields = 0;
  const result = await runEvaluation(s, "(define kept 99) (write-string \"hello\") (define (spin) (spin)) (spin)", {
    shouldStop: () => yields >= 5,
    yieldControl: async () => {
      yields += 1;
    },
    budget: 1000,
  });
  assert.deepEqual(result, { status: OK, output: "hello", stopped: true });
  assert.deepEqual(s.eval("kept"), { status: OK, output: "99\n" });
  // 次の評価が始められる(前の評価が残っていない)。
  assert.deepEqual(s.eval("(+ 1 2)"), { status: OK, output: "3\n" });
});

test("a stop that is requested before the first slice drops the evaluation without a step", async () => {
  const s = await loadSucheme();
  const result = await runEvaluation(s, "(define (spin) (spin)) (spin)", {
    shouldStop: () => true,
    yieldControl: async () => {},
  });
  assert.equal(result.stopped, true);
  assert.deepEqual(s.eval("(+ 1 2)"), { status: OK, output: "3\n" });
});

test("a stop that arrives after the evaluation finished is not a stop, and an input that needs no step is never stopped", async () => {
  const s = await loadSucheme();
  const done = await runEvaluation(s, "(+ 1 2)", {
    // 最初の確認では要求が無く、評価は1スライスで終わる。
    shouldStop: (() => {
      let calls = 0;
      return () => (calls++ >= 2);
    })(),
    yieldControl: async () => {},
  });
  assert.deepEqual(done, { status: OK, output: "3\n", stopped: false });
  const empty = await runEvaluation(s, "", { shouldStop: () => true, yieldControl: async () => {} });
  assert.deepEqual(empty, { status: OK, output: "", stopped: false });
});

test("runEvaluation reports an error and exit as eval does, and stops being asked once the evaluation ended", async () => {
  const s = await loadSucheme();
  const failed = await runEvaluation(s, "(write-string \"x\") (car 5)", {
    shouldStop: () => false,
    yieldControl: async () => {},
  });
  assert.equal(failed.status, SCHEME_ERROR);
  assert.match(failed.output, /^xerror: /);
  const exited = await runEvaluation(s, "(import (scheme process-context)) (exit 4)", { shouldStop: () => false, yieldControl: async () => {} });
  assert.equal(exited.status, EXITED);
  assert.equal(s.exitCode(), 4);
});

// エラーの表示(web/errors.mjs)。出力とエラーの説明を分け、エラーの前の出力を残す。
test("splitError separates the error line from the output before it, which has no newline", () => {
  assert.deepEqual(splitError("abcerror: boom\n"), { output: "abc", message: "boom" });
  assert.deepEqual(splitError("abc\nerror: boom\n"), { output: "abc\n", message: "boom" });
  assert.deepEqual(splitError("error: boom\n"), { output: "", message: "boom" });
  // 出力が `error: ` を含んでいても、境目は最後の `error: ` である。
  assert.deepEqual(splitError("error: shown\nerror: boom\n"), { output: "error: shown\n", message: "boom" });
  // 取るのは末尾の改行1つだけで、説明の先頭の空白と、ほかの末尾の改行は残る。
  assert.deepEqual(splitError("error: a\n\n\n"), { output: "", message: "a\n\n" });
  assert.deepEqual(splitError("error:   spaced\n"), { output: "", message: "  spaced" });
  assert.deepEqual(splitError("no error line"), { output: "no error line", message: null });
  // 説明が改行を含んでも、末尾の1つの改行だけを取る。
  assert.deepEqual(splitError("error: a\nb 1\n"), { output: "", message: "a\nb 1" });
});

// 限界の記録: 説明が `error: ` を含むと、境目を誤り、説明の前半が出力に回る。
// 将来、src/wasm.zig がエラーの行の位置を渡すようになったら、このテストを正しい分割に直す。
test("known limit: a message that contains the error prefix is split inside the message", () => {
  const h = instantiate().init();
  const [status, text] = h.run('(error "boom" "error: x")');
  assert.equal(status, SCHEME_ERROR);
  assert.equal(text, 'error: boom "error: x"\n');
  assert.deepEqual(splitError(text), { output: 'error: boom "', message: 'x"' });
});

// 状態コードごとの見出しと次の操作を、文言ごと固定する。
test("describeResult gives each status code its own title and hint", () => {
  const expected = [
    [Status.SCHEME_ERROR, "Error", null],
    [
      Status.UNRECOVERABLE,
      "Unrecoverable error",
      "The interpreter cannot go on. Press Reset to continue; definitions made so far are lost.",
    ],
    [Status.INVALID_UTF8, "Invalid input", "Nothing was evaluated. The input must be valid UTF-8."],
    [
      Status.WRONG_ORDER,
      "The interpreter has stopped",
      "Press Reset to start again; definitions made so far are lost.",
    ],
    [Status.NOT_INITIALIZED, "Not initialized", "Reload the page."],
    [Status.OUT_OF_MEMORY, "Out of memory", "Press Reset to start again; definitions made so far are lost."],
    [Status.BAD_REGION, "Internal error", "Reload the page."],
    [Status.CONTINUE, "Unexpected status 1", "Press Reset, or reload the page."],
    [Status.WAITING_INPUT, "Unexpected status 2", "Press Reset, or reload the page."],
    [-99, "Unexpected status -99", "Press Reset, or reload the page."],
  ];
  for (const [status, title, hint] of expected) {
    assert.deepEqual(
      describeResult(status, "out" + "error: why\n"),
      { output: "out", error: { title, message: "why", hint } },
      String(status),
    );
    // エラーの行が無いときは、出力をそのまま残し、説明は空にする。
    assert.deepEqual(
      describeResult(status, "only output"),
      { output: "only output", error: { title, message: "", hint } },
      String(status),
    );
  }
});

test("describeResult keeps the output before an error and explains each status code", () => {
  assert.deepEqual(describeResult(Status.OK, "3\n"), { output: "3\n", error: null });
  assert.deepEqual(describeResult(Status.OK, ""), { output: "", error: null });
  assert.deepEqual(describeResult(Status.SCHEME_ERROR, "1\nerror: unbound variable: x\n"), {
    output: "1\n",
    error: { title: "Error", message: "unbound variable: x", hint: null },
  });
  assert.deepEqual(describeResult(Status.EXITED, "bye", 3).error, {
    title: "Program exited",
    message: "exit code 3",
    hint: "Press Reset to run again.",
  });
  assert.equal(describeResult(Status.EXITED, "bye", 3).output, "bye");
  // 表にある状態コードは、すべて説明を持つ(未知のコードは、コードの値を見出しに出す)。
  for (const [name, code] of Object.entries(Status)) {
    if (code === Status.OK) continue;
    const { error } = describeResult(code, "error: why\n", 0);
    assert.ok(error !== null && error.title !== "", name);
    if (code === Status.CONTINUE || code === Status.WAITING_INPUT) {
      assert.match(error.title, /^Unexpected status/, name);
    } else {
      assert.doesNotMatch(error.title, /^Unexpected status/, name);
    }
  }
  assert.equal(describeResult(-99, "").error.title, "Unexpected status -99");
});

test("a real error after output keeps that output apart from the message", () => {
  const h = instantiate().init();
  const [status, text] = h.run('(import (scheme base) (scheme write)) (display "abc") (car 5)');
  assert.equal(status, SCHEME_ERROR);
  assert.deepEqual(describeResult(status, text), {
    output: "abc",
    error: { title: "Error", message: "wrong type of argument to car 5", hint: null },
  });
  const [status2, text2] = h.run("(+ 1");
  assert.equal(status2, SCHEME_ERROR);
  assert.deepEqual(describeResult(status2, text2).error.message, "unexpected end of input");
});

// web/serve.mjs の自己検査(パストラバーサルなど)は、ほかの検証コマンドに結ばれていないので、
// ここから走らせる。
test("web/serve.mjs --self-test passes", () => {
  // `URL.pathname` は空白や非 ASCII を %XX のまま返すので、ファイルパスには使えない。
  const script = fileURLToPath(new URL("../../web/serve.mjs", import.meta.url));
  // 自己検査は1秒かからない。待ち続けて検証を止めないよう、30 秒で打ち切る。
  const r = spawnSync(process.execPath, [script, "--self-test"], {
    encoding: "utf8",
    timeout: 30_000,
  });
  // 打ち切られると status は null で、理由は error に入る。
  assert.equal(r.status, 0, `${r.error ?? ""}${r.stdout}${r.stderr}`);
  assert.match(r.stdout, /self-test passed/);
});

let passed = 0;
let failed = 0;
let skipped = 0;
for (const { name, body, slow } of tests) {
  if (slow && !slowTier) {
    skipped += 1;
    console.log(`skip ${name} (slow tier)`);
    continue;
  }
  try {
    await body();
    passed += 1;
    console.log(`ok   ${name}`);
  } catch (e) {
    failed += 1;
    console.log(`FAIL ${name}`);
    console.log(String(e && e.stack ? e.stack : e).replace(/^/gm, "     "));
  }
}

if (failed > 0) {
  console.log(`test-wasm: ${passed} passed, ${failed} failed, ${skipped} skipped`);
  process.exit(1);
}
console.log(`test-wasm: ${passed} passed, ${skipped} skipped`);
