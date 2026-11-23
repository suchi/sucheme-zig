// Turns an evaluation result (a status code and the output text) into what the page shows.
//
// DOM に触れない純粋な関数だけを置く。`tools/test-wasm/main.mjs` が Node.js から試す。
// 状態コードの値と意味は docs/design/platform-and-web.md の表が正である。

import { Status } from "./sucheme.js";
import { matching } from "./parens.mjs";

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
 * 厳密に分けるには WASM 側の変更が要る。割れると、位置が説明の先頭から外れるので、
 * 入力欄の強調は、出ないか、誤った場所に出る(8g-2)。
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
 * Reads the position that an error message starts with: `line:column: message`.
 *
 * 行と桁は1始まりで、桁は文字(コードポイント)で数える(src/positions.zig の `Cursor`)。
 * 位置の無い誤りは null である。ファイル名つきの形(`name:1:2: ...`)は、別のファイルの位置で、
 * 入力欄に示す位置ではないので、null にする(WASM の入力はファイルを持たない)。
 * 限界: 位置の無い誤りの説明が、たまたま `1:2: ` で始まるときは、位置と読んでしまう
 * (`error` の第1引数の文字列がそう始まっても、呼び出しの位置が前に付くので、先頭は呼び出しの位置になる)。
 */
export function parseSpot(message) {
  const m = /^(\d+):(\d+): /.exec(message);
  if (m === null) return null;
  const line = Number(m[1]);
  const column = Number(m[2]);
  if (!Number.isSafeInteger(line) || !Number.isSafeInteger(column) || line < 1 || column < 1) return null;
  return { line, column };
}

/**
 * Finds where `spot` is in `text`, as a range of string indexes `{ start, end }`.
 *
 * 位置は、呼び出しの開き括弧を指す。`(` を指しているときは、対応する閉じ括弧までを範囲にする
 * (閉じていなければ行末まで)。それ以外は1文字である。行の終わりは LF、CRLF、単独の CR のどれも
 * 1つと数える(リーダと同じ)。桁は文字で数えるので、サロゲートペアの文字は1桁として進める。
 * 位置が `text` の中に無いとき(行や桁が足りない)は null である。
 */
export function spotRange(text, spot) {
  let line = 1;
  let i = 0;
  while (line < spot.line) {
    if (i >= text.length) return null;
    const c = text[i];
    i += 1;
    if (c === "\r") {
      if (text[i] === "\n") i += 1;
      line += 1;
    } else if (c === "\n") {
      line += 1;
    }
  }
  const isBreak = (c) => c === "\n" || c === "\r";
  let column = 1;
  while (column < spot.column) {
    if (i >= text.length || isBreak(text[i])) return null;
    i += text.codePointAt(i) > 0xffff ? 2 : 1;
    column += 1;
  }
  if (i >= text.length || isBreak(text[i])) return null;
  const start = i;
  if (text[start] === "(") {
    // 切り出した文字列の先頭から数えるので、直前の `)` の相手とは取り違えない。
    const close = matching(text.slice(start), 0);
    if (close !== null) return { start, end: start + close + 1 };
    let end = start;
    while (end < text.length && !isBreak(text[end])) end += 1;
    return { start, end };
  }
  return { start, end: start + (text.codePointAt(start) > 0xffff ? 2 : 1) };
}

/**
 * Describes a result for display.
 *
 * 戻り値は `{ output, error }`。`output` はプログラムの出力で、エラーの前に出たものも残る。
 * `error` は、エラーが無ければ null で、あれば `{ title, message, hint, spot }` である。
 * `spot` は、説明の先頭の位置(`parseSpot`)か、無ければ null である。説明の文字列は、位置つきのまま残す。
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
        spot: null,
      },
    };
  }
  const known = explanations.get(status);
  const { output, message } = splitError(text);
  if (known === undefined) {
    return {
      output,
      error: {
        title: `Unexpected status ${status}`,
        message: message ?? "",
        hint: "Press Reset, or reload the page.",
        spot: parseSpot(message ?? ""),
      },
    };
  }
  return {
    output,
    error: { title: known.title, message: message ?? "", hint: known.hint, spot: parseSpot(message ?? "") },
  };
}
