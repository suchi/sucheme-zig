// A module worker that runs the interpreter off the main thread.
//
// 長い計算の間も画面が応答するように、インタプリタはここで動かす。評価は歩数ごとに区切り
// (runner.mjs)、区切りの間に届いた停止の要求で、評価だけを捨てる(定義は残る)。
// メッセージは次のとおり。
//   受信: { type: "init", wasmUrl } / { type: "eval", id, source } / { type: "stop", id }
//         / { type: "reset" }
//   送信: { type: "ready", version } / { type: "result", id, status, output, exitCode, stopped }
//         { type: "reset-done", status } / { type: "error", phase, message }
// `stopped` が真の result は、停止で評価を捨てたことを表す(status は 0、output は止めるまでの出力)。

import { Sucheme, Status } from "./sucheme.js";
import { runEvaluation } from "./runner.mjs";

let sucheme = null;
let stderrText = "";
// 評価中の id と、それに届いた停止の要求。評価は1つだけ走る。
let runningId = 0;
let stopRequestedFor = 0;

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
          });
        } finally {
          runningId = 0;
          stopRequestedFor = 0;
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
