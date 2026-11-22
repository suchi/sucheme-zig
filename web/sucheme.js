// A thin layer over the exports of sucheme.wasm (src/wasm.zig).
//
// 状態コードの値は docs/design/platform-and-web.md の表が正である。この層は
// src/wasm.zig が公開している関数だけを呼ぶ(`sucheme_provide_input` などは未実装)。
// 文字列はすべて UTF-8 で受け渡す。線形メモリは伸びると ArrayBuffer が差し替わるので、
// メモリの視点(Uint8Array)は使うたびに作り直す。

/** Status codes returned by the state-changing exports. */
export const Status = Object.freeze({
  OK: 0,
  CONTINUE: 1,
  WAITING_INPUT: 2,
  SCHEME_ERROR: -1,
  UNRECOVERABLE: -2,
  INVALID_UTF8: -3,
  WRONG_ORDER: -4,
  NOT_INITIALIZED: -5,
  EXITED: -6,
  OUT_OF_MEMORY: -7,
  BAD_REGION: -8,
});

/** The most steps `sucheme_step` takes at once (a `u32`). */
export const STEP_BUDGET_MAX = 0xffffffff;

const encoder = new TextEncoder();
// fatal を付けない。出力はインタプリタが妥当な UTF-8 で書くので、置換が起きるのは異常時だけである。
const decoder = new TextDecoder("utf-8");

export class Sucheme {
  #exports;

  constructor(exports) {
    this.#exports = exports;
  }

  /**
   * Instantiate the module from its bytes.
   *
   * `onStderr(text)` は、モジュールがパニックしたときに説明を受け取る。時刻の2つの import は、この層が `Date.now()` と `performance.now()` で渡す。
   */
  static async load(bytes, { onStderr = () => {} } = {}) {
    let instance = null;
    const imports = {
      env: {
        host_write_stderr(ptr, len) {
          const memory = instance.exports.memory;
          onStderr(decoder.decode(new Uint8Array(memory.buffer, ptr >>> 0, len >>> 0)));
        },
        // 絶対時刻(UNIX 時刻のミリ秒)と単調な時間(ミリ秒)。`(scheme time)` が読む
        // (docs/plans/0019-phase5-ports-and-io.md の合意を求める点の2)。
        host_now_ms() {
          return Date.now();
        },
        host_monotonic_ms() {
          return performance.now();
        },
      },
    };
    const result = await WebAssembly.instantiate(bytes, imports);
    instance = result.instance;
    return new Sucheme(instance.exports);
  }

  #bytes(ptr, len) {
    // Why: wasm32 の i32 は JS に符号つきで届く。2 GiB 以上のアドレスは負の数になるので、
    // 符号なしに直してから使う(直さないと、ヒープが大きいときに不正な範囲として落ちる)。
    return new Uint8Array(this.#exports.memory.buffer, ptr >>> 0, len >>> 0);
  }

  #takeOutput() {
    const len = this.#exports.sucheme_output_len();
    const text = len === 0 ? "" : decoder.decode(this.#bytes(this.#exports.sucheme_output_ptr(), len));
    this.#exports.sucheme_output_clear();
    return text;
  }

  /** Initialize the interpreter. Returns a status code (0 on success). */
  init(heapLimitBytes = 0) {
    return this.#exports.sucheme_init(heapLimitBytes);
  }

  /**
   * Start evaluating every expression in `text`.
   *
   * 戻り値は `{ status, output }`。status が 1(`Status.CONTINUE`)のとき、評価は続いていて、
   * `step()` で進める(`abort()` で捨てられる)。0 なら歩数を使わずに完了した。-1(Scheme のエラー)と
   * -3(不正な UTF-8)でも出力に説明が入るので、呼び出し側はそのまま表示できる。-6(`Status.EXITED`)は、
   * プログラムが `exit` を呼んだことを表し、終了コードは `exitCode()` で取る。以後は
   * `reset()` まで評価できない。
   */
  begin(text) {
    const e = this.#exports;
    const encoded = encoder.encode(text);
    const ptr = e.sucheme_alloc(encoded.length);
    if (ptr === 0) {
      // 初期化前か、確保の失敗。どちらも状態コードで説明できる。
      return { status: Status.NOT_INITIALIZED, output: this.#takeOutput() };
    }
    let status;
    try {
      this.#bytes(ptr, encoded.length).set(encoded);
      status = e.sucheme_eval_begin(ptr, encoded.length);
    } finally {
      e.sucheme_free(ptr, encoded.length);
    }
    return { status, output: this.#takeOutput() };
  }

  /**
   * Advance the evaluation `begin()` started by at most `budget` machine steps
   * (`budget` は 0 から 2^32 - 1)。
   *
   * 戻り値は `{ status, output }`。1 なら、また呼ぶ。0 は完了、-1 は Scheme のエラーである。
   * 出力は、この歩の分だけが入る。
   */
  step(budget) {
    const status = this.#exports.sucheme_step(budget);
    return { status, output: this.#takeOutput() };
  }

  /**
   * Drop the evaluation `begin()` started and `step()` has not finished.
   * それまでの定義は残る。戻り値は状態コード(0 が成功)である。
   */
  abort() {
    return this.#exports.sucheme_abort();
  }

  /**
   * Evaluate every expression in `text`, to the end.
   *
   * `begin()` と `step()` を、完了まで続けて呼ぶ。戻り値は `{ status, output }` で、
   * output は全部の出力である。途中で制御を戻したいときは、`begin()` と `step()` を使う
   * (runner.mjs)。
   */
  eval(text) {
    let { status, output } = this.begin(text);
    while (status === Status.CONTINUE) {
      const next = this.step(STEP_BUDGET_MAX);
      status = next.status;
      output += next.output;
    }
    return { status, output };
  }

  /**
   * Set what `(command-line)` gives from the next `eval`: the program's name first,
   * then its arguments. Returns whether it was set (false for text that is not
   * UTF-8 or contains a newline).
   *
   * 改行区切りで渡す(docs/design/platform-and-web.md)ので、改行を含む要素は渡せない。
   * 空の配列は、処理系の名前だけに戻す。
   */
  setCommandLine(args) {
    if (args.some((a) => a.includes("\n"))) return false;
    const e = this.#exports;
    const encoded = encoder.encode(args.join("\n"));
    const ptr = e.sucheme_alloc(encoded.length);
    if (ptr === 0) return false;
    try {
      this.#bytes(ptr, encoded.length).set(encoded);
      return e.sucheme_set_command_line(ptr, encoded.length) === 1;
    } finally {
      e.sucheme_free(ptr, encoded.length);
    }
  }

  /** The exit code of the last `eval` that returned `Status.EXITED`, or 0. */
  exitCode() {
    return this.#exports.sucheme_exit_code();
  }

  /** Discard all state and return to the freshly initialized state. */
  reset() {
    return this.#exports.sucheme_reset();
  }

  /** The version string of the interpreter. */
  version() {
    const e = this.#exports;
    return decoder.decode(this.#bytes(e.sucheme_version_ptr(), e.sucheme_version_len()));
  }
}
