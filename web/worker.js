// A module worker that runs the interpreter off the main thread.
//
// 長い計算の間も画面が応答するように、インタプリタはここで動かす。評価は歩数ごとに区切り
// (runner.mjs)、区切りの間に届いた停止の要求で、評価だけを捨てる(定義は残る)。
// メッセージは次のとおり。
//   受信: { type: "init", wasmUrl } / { type: "eval", id, source } / { type: "stop", id }
//         / { type: "input", id, text } / { type: "eof", id } / { type: "reset" }
//   送信: { type: "ready", version } / { type: "result", id, status, output, exitCode, stopped }
//         / { type: "needs-input", id, output } / { type: "reset-done", status }
//         / { type: "error", phase, message }
// `stopped` が真の result は、停止で評価を捨てたことを表す(status は 0、output は止めるまでの出力)。
// `needs-input` は、読み取りが入力を待っていることを表し、output は、そこまでの出力(渡した入力の写しを含む)
// である。画面は、`input`(渡す文字列。行は改行を含む)か `eof`(入力の終端)を返す。待つ間に `stop` が
// 来ると、評価を捨てる。

import { Sucheme, Status } from "./sucheme.js";
import { runEvaluation } from "./runner.mjs";

let sucheme = null;
let stderrText = "";
// 評価中の id と、それに届いた停止の要求。評価は1つだけ走る。
let runningId = 0;
let stopRequestedFor = 0;
// 入力を待っている間の、評価の id と、答えを受け取る関数。待っていなければ null。
let pendingInput = null;

// runEvaluation の requestInput。画面に待ちを知らせ、`input` か `eof` か `stop` が来るのを待つ。
function requestInput(id, output) {
  return new Promise((resolve) => {
    pendingInput = { id, resolve };
    postMessage({ type: "needs-input", id, output });
  });
}

// 待っている読み取りに答える。id が合わない、または待っていなければ、無視する。
function answerInput(id, answer) {
  if (pendingInput === null || pendingInput.id !== id) return;
  const { resolve } = pendingInput;
  pendingInput = null;
  resolve(answer);
}

// イベントループに制御を戻す。メッセージの受け取りは、マイクロタスクでなくタスクで起きる。
function yieldControl() {
  return new Promise((resolve) => {
    const channel = new MessageChannel();
    channel.port1.onmessage = () => {
      channel.port1.close();
      resolve();
    };
    channel.port2.postMessage(null);
  });
}

function fail(phase, message) {
  postMessage({ type: "error", phase, message });
}

async function init(wasmUrl) {
  const response = await fetch(wasmUrl);
  if (!response.ok) {
    throw new Error(`HTTP ${response.status} (${wasmUrl})`);
  }
  const bytes = await response.arrayBuffer();
  const instance = await Sucheme.load(bytes, {
    onStderr(text) {
      stderrText += text;
    },
  });
  const status = instance.init();
  if (status !== Status.OK) {
    throw new Error(`sucheme_init returned ${status}`);
  }
  sucheme = instance;
  postMessage({ type: "ready", version: instance.version() });
}

self.onmessage = async (event) => {
  const message = event.data;
  try {
    switch (message.type) {
      case "init":
        try {
          await init(message.wasmUrl);
        } catch (e) {
          fail("init", String(e && e.message ? e.message : e));
        }
        break;
      case "eval": {
        if (sucheme === null) {
          fail("eval", "not initialized");
          break;
        }
        runningId = message.id;
        let result;
        try {
          result = await runEvaluation(sucheme, message.source, {
            shouldStop: () => stopRequestedFor === message.id,
            yieldControl,
            requestInput: (output) => requestInput(message.id, output),
          });
        } finally {
          runningId = 0;
          stopRequestedFor = 0;
          pendingInput = null;
        }
        const { status, output, stopped } = result;
        // 終了コードは、exit が呼ばれたとき(状態コード -6)にだけ意味を持つ。
        const exitCode = status === Status.EXITED ? sucheme.exitCode() : 0;
        postMessage({ type: "result", id: message.id, status, output, exitCode, stopped });
        break;
      }
      case "stop":
        // 評価の区切りで見る。評価が無いとき、または別の評価の分は、無視する。
        if (runningId === message.id) stopRequestedFor = message.id;
        // 入力を待っているときは、待ちを止め、runEvaluation に評価を捨てさせる。
        answerInput(message.id, null);
        break;
      case "input":
        answerInput(message.id, { text: String(message.text) });
        break;
      case "eof":
        answerInput(message.id, { eof: true });
        break;
      case "reset": {
        if (sucheme === null) {
          fail("reset", "not initialized");
          break;
        }
        postMessage({ type: "reset-done", status: sucheme.reset() });
        break;
      }
    }
  } catch (e) {
    // モジュールがトラップした(パニックなど)。インスタンスは壊れているので、画面側が Worker を作り直す。
    const detail = stderrText ? `${stderrText.trim()} / ` : "";
    fail(message.type, detail + String(e && e.message ? e.message : e));
    stderrText = "";
  }
};
