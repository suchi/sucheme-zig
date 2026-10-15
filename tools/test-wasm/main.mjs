// Round-trip tests for sucheme.wasm, run from Node.js: `node main.mjs <path to sucheme.wasm>`.
//
// sucheme.wasm の往復テスト。エクスポートを Node.js から呼び、状態コードと出力バッファの
// 内容を確かめる(docs/design/platform-and-web.md の「WebAssembly の境界」、
// docs/plans/0008-slice-1i-wasm-web-ui.md)。依存パッケージは使わない。
//
// 1つの panic のあとは同じインスタンスを使えない(trap する)ので、panic を起こす
// テストは新しいインスタンスで行う。テストごとに新しいインスタンスを作るので、
// テスト同士が状態を共有しない。

import { readFileSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import assert from "node:assert/strict";

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
const BAD_REGION = -8;

const OUTPUT_CAPACITY = 256 * 1024;

const compiled = new WebAssembly.Module(readFileSync(wasmPath));

console.log(`node ${process.version}`);

/** Makes a new instance. `stderr` collects the strings passed to host_write_stderr. */
function instantiate() {
  const stderr = [];
  let memory;
  const decoder = new TextDecoder();
  const instance = new WebAssembly.Instance(compiled, {
    env: {
      host_write_stderr(ptr, len) {
        stderr.push(decoder.decode(new Uint8Array(memory.buffer, ptr, len)));
      },
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
      return new Uint8Array(memory.buffer, ptr, len);
    },
    /** Reads the output buffer as a string without clearing it. */
    output() {
      const len = x.sucheme_output_len();
      return decoder.decode(host.bytes(x.sucheme_output_ptr(), len));
    },
    /** Evaluates bytes through alloc, eval_begin and free, and returns the status. */
    evalBytes(bytes) {
      const ptr = x.sucheme_alloc(bytes.length);
      assert.notEqual(ptr, 0, "sucheme_alloc failed");
      host.bytes(ptr, bytes.length).set(bytes);
      const status = x.sucheme_eval_begin(ptr, bytes.length);
      x.sucheme_free(ptr, bytes.length);
      return status;
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
  const definition = "(define-library (t a) (export f) (import (sucheme core)) (begin (define (f) 1)))";
  assert.deepEqual(h.run(definition), [OK, ""]);
  assert.deepEqual(h.run("(import (t a)) (f)"), [OK, "1\n"]);
  assert.deepEqual(
    h.run("(define-library (t b) (export) (import (sucheme core)) (begin (define x (car 5))))"),
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

// 送出のための予約も尽きて条件を作れなかったら、回復不能(-2)を返し、リセットまで評価を
// 受け付けない(docs/design/platform-and-web.md の状態コードの表)。予約を使い切らせるため、
// メッセージが上限と予約の和より長くなる未束縛の名前を使う。
test("a raise that uses up the reserve is unrecoverable until a reset", () => {
  const h = instantiate();
  assert.equal(h.x.sucheme_init(small_limit), OK);
  const [status, text] = h.run("x".repeat(small_limit + 8192));
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
const small_limit = 65536;

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
  // 最小の整数を -1 で割る quotient は、結果が 64 ビットに収まらない。
  assert.deepEqual(h.run("(quotient -9223372036854775808 -1)"), [SCHEME_ERROR, "error: integer overflow in quotient -9223372036854775808 -1\n"]);
  assert.deepEqual(h.run("(quotient 1 0)"), [SCHEME_ERROR, "error: division by zero in quotient 1 0\n"]);
  assert.deepEqual(h.run("(modulo -9223372036854775808 0)"), [SCHEME_ERROR, "error: division by zero in modulo -9223372036854775808 0\n"]);
  // 128 ビットの積と和。途中の値が 64 ビットを超えても、結果が収まれば値を返す。
  assert.deepEqual(h.run("(* 4294967296 2147483647) (+ 9223372036854775807 1 -1) (- -9223372036854775808 1 -1)"), [
    OK,
    "9223372032559808512\n9223372036854775807\n-9223372036854775808\n",
  ]);
  assert.deepEqual(h.run("(* 3037000500 3037000500)"), [SCHEME_ERROR, "error: integer overflow in * 3037000500 3037000500\n"]);
  assert.deepEqual(h.run("(+ 9223372036854775807 1)"), [SCHEME_ERROR, "error: integer overflow in + 9223372036854775807 1\n"]);
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
  assert.equal(h.x.sucheme_eval_begin(ptr, source.length), OK);
  assert.equal(h.output(), "3\n");
  // free は panic しない。リセットが領域の記録を捨てていると、ここで trap する。
  h.x.sucheme_free(ptr, source.length);
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
    body();
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
