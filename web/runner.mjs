// Runs an evaluation a slice at a time, so that the page stays responsive and a stop request
// can end it.
//
// DOM と Worker に触れない。`web/worker.js` が使い、`tools/test-wasm/main.mjs` が Node.js から試す。
// 評価は `Sucheme.begin` と `Sucheme.step` で進める。制御を取り戻す間に、ホストは停止の
// 要求などのメッセージを受け取れる。停止は、`Sucheme.abort` で評価だけを捨てるので、
// それまでの定義は残る。

import { Status } from "./sucheme.js";

/** How many machine steps one call of `step` takes. */
export const STEP_BUDGET = 20000;

/** How long (ms) to run before giving control back to the event loop. */
export const SLICE_MS = 16;

/**
 * Evaluates `text` and resolves to `{ status, output, stopped }`.
 *
 * `stopped` は、評価を捨てたことを表す。そのとき status は 0 で、output は止めるまでの出力である。
 * 評価が終わったあとに停止が来ても、`stopped` は偽で、status は評価の結果である。
 *
 * options:
 * - `shouldStop()`: 真なら、次の歩の前に評価を捨てる。
 * - `yieldControl()`: 制御を取り戻させる(Promise を返す)。スライスの区切りごとに呼ぶ。
 * - `now()`: ミリ秒の時計。
 * - `budget`、`sliceMs`: 1回の `step` の歩数と、制御を戻す間隔。
 * - `requestInput(outputSoFar)`: 読み取りが入力を待つたびに呼ぶ(Promise を返す)。引数は、そこまでの
 *   出力である(問いを画面に出せる)。`{ text }`(渡す文字列。行は改行を含めて渡す)、`{ eof: true }`
 *   (入力の終端)、`null`(待つ間に停止が来たので、評価を捨てる)のどれかで答える。渡した `text` は、
 *   端末のエコーと同じく、出力にも写す(プログラムの出力ではなく、表示のためである)。
 *   無いときは、待ちを終わりとして返す(status は 2)。
 */
export async function runEvaluation(sucheme, text, options) {
  const {
    shouldStop,
    yieldControl,
    requestInput,
    now = () => performance.now(),
    budget = STEP_BUDGET,
    sliceMs = SLICE_MS,
  } = options;
  let { status, output } = sucheme.begin(text);
  while (status === Status.CONTINUE || (status === Status.WAITING_INPUT && requestInput !== undefined)) {
    if (shouldStop()) {
      sucheme.abort();
      return { status: Status.OK, output, stopped: true };
    }
    if (status === Status.WAITING_INPUT) {
      const answer = await requestInput(output);
      if (answer === null) {
        sucheme.abort();
        return { status: Status.OK, output, stopped: true };
      }
      const given = answer.eof === true ? sucheme.provideEof() : sucheme.provideInput(answer.text);
      // 写しは、渡した入力の説明(失敗の理由)より前に置く。
      if (answer.eof !== true) output += answer.text;
      output += given.output;
      status = given.status;
      continue;
    }
    await yieldControl();
    if (shouldStop()) continue;
    const sliceStart = now();
    do {
      const next = sucheme.step(budget);
      status = next.status;
      output += next.output;
    } while (status === Status.CONTINUE && now() - sliceStart < sliceMs);
  }
  return { status, output, stopped: false };
}
