// A thin layer over the exports of sucheme.wasm (src/wasm.zig).
//
// 状態コードの値は docs/design/platform-and-web.md の表が正である。この層は
// src/wasm.zig が公開している関数だけを呼ぶ(sucheme_step などは未実装)。
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
   * `onStderr(text)` は、モジュールがパニックしたときに説明を受け取る(1i ではこれが唯一の import)。
   */
  static async load(bytes, { onStderr = () => {} } = {}) {
    let instance = null;
    const imports = {
      env: {
        host_write_stderr(ptr, len) {
          const memory = instance.exports.memory;
          onStderr(decoder.decode(new Uint8Array(memory.buffer, ptr, len)));
        },
      },
    };
    const result = await WebAssembly.instantiate(bytes, imports);
    instance = result.instance;
    return new Sucheme(instance.exports);
  }

  #bytes(ptr, len) {
    return new Uint8Array(this.#exports.memory.buffer, ptr, len);
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
   * Evaluate every expression in `text`.
   *
   * 戻り値は `{ status, output }`。-1(Scheme のエラー)と -3(不正な UTF-8)でも
   * 出力に説明が入るので、呼び出し側はそのまま表示できる。
   */
  eval(text) {
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
