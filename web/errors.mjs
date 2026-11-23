// Turns an evaluation result (a status code and the output text) into what the page shows.
//
// DOM に触れない純粋な関数だけを置く。`tools/test-wasm/main.mjs` が Node.js から試す。
// 状態コードの値と意味は docs/design/platform-and-web.md の表が正である。

import { Status } from "./sucheme.js";

/** The prefix of the line that `sucheme_eval_begin` appends to the output on an error. */
export const ERROR_PREFIX = "error: ";

/**
 * What to tell the user for each status code that is not a plain success.
 * `title` は見出し、`hint` は次にすることである(無ければ null)。
 */
const explanations = new Map([
  [Status.SCHEME_ERROR, { title: "Error", hint: null }],
  [
    Status.UNRECOVERABLE,
    {
      title: "Unrecoverable error",
      hint: "The interpreter cannot go on. Press Reset to continue; definitions made so far are lost.",
    },
  ],
  [Status.INVALID_UTF8, { title: "Invalid input", hint: "Nothing was evaluated. The input must be valid UTF-8." }],
  [
    Status.WRONG_ORDER,
    { title: "The interpreter has stopped", hint: "Press Reset to start again; definitions made so far are lost." },
  ],
  [Status.NOT_INITIALIZED, { title: "Not initialized", hint: "Reload the page." }],
  [Status.OUT_OF_MEMORY, { title: "Out of memory", hint: "Press Reset to start again; definitions made so far are lost." }],
  [Status.BAD_REGION, { title: "Internal error", hint: "Reload the page." }],
  // 画面は入力待ちを自分で受け取る(app.js の入力欄)。結果として届くのは、受け取れなかった場合だけである。
  [
    Status.WAITING_INPUT,
    { title: "Waiting for input", hint: "The page did not take the input. Press Reset, or reload the page." },
  ],
]);

/**
 * Splits `text` into the program's output and the error message that follows it.
 *
 * エラーの行(`error: ...`)は、それまでの出力の直後に、改行を挟まずに書かれる
 * (`(display "abc") (car 5)` の出力は `abcerror: ...` になる)。出力は1本のバッファなので、
 * 区切りは目印の文字列で探すしかなく、最後の `error: ` から後ろを説明とみなす。
 * 説明そのものが `error: ` を含むとき(`(error "error: x")`)は、後ろの `error: ` から割れる。
 * 厳密に分けるには WASM 側の変更が要る。
 */
export function splitError(text) {
  const at = text.lastIndexOf(ERROR_PREFIX);
  if (at === -1) return { output: text, message: null };
  return {
    output: text.slice(0, at),
    message: text.slice(at + ERROR_PREFIX.length).replace(/\n$/, ""),
  };
}

/**
 * Describes a result for display.
 *
 * 戻り値は `{ output, error }`。`output` はプログラムの出力で、エラーの前に出たものも残る。
 * `error` は、エラーが無ければ null で、あれば `{ title, message, hint }` である。
 * `exit` を呼ぶと、状態コード -6 と終了コードが返る。これは失敗ではないが、
 * 以後の評価ができなくなるので、同じ形で知らせる。
 */
export function describeResult(status, text, exitCode = 0) {
  if (status === Status.OK) return { output: text, error: null };
  if (status === Status.EXITED) {
    return {
      output: text,
      error: {
        title: "Program exited",
        message: `exit code ${exitCode}`,
        hint: "Press Reset to run again.",
      },
    };
  }
  const known = explanations.get(status);
  const { output, message } = splitError(text);
  if (known === undefined) {
    return {
      output,
      error: { title: `Unexpected status ${status}`, message: message ?? "", hint: "Press Reset, or reload the page." },
    };
  }
  return { output, error: { title: known.title, message: message ?? "", hint: known.hint } };
}
