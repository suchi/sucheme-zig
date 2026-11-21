// A module worker that runs the interpreter off the main thread.
//
// 長い計算の間も画面が応答し、「停止」ボタンが Worker ごと捨てられるようにするために、
// インタプリタはここで動かす。メッセージは次のとおり。
//   受信: { type: "init", wasmUrl } / { type: "eval", id, source } / { type: "reset" }
//   送信: { type: "ready", version } / { type: "result", id, status, output, exitCode }
//         { type: "reset-done", status } / { type: "error", phase, message }

import { Sucheme, Status } from "./sucheme.js";

let sucheme = null;
let stderrText = "";

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
        const { status, output } = sucheme.eval(message.source);
        // 終了コードは、exit が呼ばれたとき(状態コード -6)にだけ意味を持つ。
        const exitCode = status === Status.EXITED ? sucheme.exitCode() : 0;
        postMessage({ type: "result", id: message.id, status, output, exitCode });
        break;
      }
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
