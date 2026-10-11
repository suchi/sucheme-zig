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
// 上限まで使い切るので 1 分以上かかる。
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
  const r = spawnSync(process.execPath, [script, "--self-test"], {
    encoding: "utf8",
  });
  assert.equal(r.status, 0, `${r.stdout}${r.stderr}`);
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
