// The controller of the page: owns the worker and the buttons.
//
// 状態は loading(WASM を読み込み中)・ready(入力を受け付ける)・running(評価中)の3つ。
// 「停止」は Worker を捨てて作り直す(worker.terminate())。作り直した処理系は初期状態なので、
// 定義はすべて失われる。
//
// 画面の文言は英語にする(AGENTS.md の言語ルール)。結果の説明は errors.mjs が作る。

import { Status } from "./sucheme.js";
import { describeResult } from "./errors.mjs";
import { samples } from "./samples.mjs";
import { encodeFragment, decodeFragment } from "./share.mjs";

const form = document.getElementById("form");
const source = document.getElementById("source");
const runButton = document.getElementById("run");
const stopButton = document.getElementById("stop");
const resetButton = document.getElementById("reset");
const output = document.getElementById("output");
const errorPanel = document.getElementById("error");
const errorTitle = document.getElementById("error-title");
const errorMessage = document.getElementById("error-message");
const errorHint = document.getElementById("error-hint");
const versionLabel = document.getElementById("version");
const sampleSelect = document.getElementById("samples");
const shareButton = document.getElementById("share");
const shareUrl = document.getElementById("share-url");
const shareStatus = document.getElementById("share-status");

// sucheme.wasm は、このファイルと同じ階層から相対パスで取る。
const wasmUrl = new URL("./sucheme.wasm", import.meta.url).href;
const workerUrl = new URL("./worker.js", import.meta.url);

let worker = null;
let phase = "loading";
let nextId = 1;
let runningId = 0;

// 状態の知らせ(読み込み中、停止など)を出力欄に出す。エラーの欄は閉じる。
function show(text, status = "ok") {
  output.textContent = text;
  output.dataset.status = status;
  errorPanel.hidden = true;
}

// 評価の結果を出す。プログラムの出力は出力欄に、エラーの説明は別の欄に出す。
// エラーの前に出た出力は、出力欄に残る。
function showResult(status, text, exitCode) {
  const { output: out, error } = describeResult(status, text, exitCode);
  output.textContent = out === "" && error === null ? "(no output)" : out;
  output.dataset.status = error === null ? "ok" : "partial";
  if (error === null) {
    errorPanel.hidden = true;
    return;
  }
  errorTitle.textContent = error.title;
  errorMessage.textContent = error.message;
  errorMessage.hidden = error.message === "";
  errorHint.textContent = error.hint ?? "";
  errorHint.hidden = error.hint === null;
  // 終了は失敗ではないので、エラーの色にしない。
  errorPanel.dataset.kind = status === Status.EXITED ? "exit" : "error";
  errorPanel.hidden = false;
}

function setPhase(next) {
  phase = next;
  runButton.disabled = next !== "ready";
  resetButton.disabled = next !== "ready";
  stopButton.disabled = next !== "running";
  output.setAttribute("aria-busy", next === "running" ? "true" : "false");
}

function openedFromFile() {
  return location.protocol === "file:";
}

const fileHint = "Open this page through a local server: node web/serve.mjs";

function startWorker() {
  if (worker !== null) worker.terminate();
  setPhase("loading");
  versionLabel.textContent = "Loading…";
  if (openedFromFile()) {
    show(fileHint, "error");
    return;
  }
  let w;
  try {
    w = new Worker(workerUrl, { type: "module" });
  } catch (e) {
    show(`Could not create the worker: ${e.message}\n${fileHint}`, "error");
    return;
  }
  worker = w;

  w.onmessage = (event) => {
    if (w !== worker) return;
    const m = event.data;
    switch (m.type) {
      case "ready":
        versionLabel.textContent = m.version;
        setPhase("ready");
        if (output.dataset.status === "busy") show("Ready.");
        break;
      case "result": {
        if (m.id !== runningId) break;
        showResult(m.status, m.output, m.exitCode);
        setPhase("ready");
        break;
      }
      case "reset-done":
        show(m.status === Status.OK ? "State was reset." : `Reset failed (status code ${m.status}).`,
          m.status === Status.OK ? "ok" : "error");
        setPhase("ready");
        break;
      case "error":
        if (m.phase === "init") {
          show(`Failed to load WebAssembly: ${m.message}\n` +
            "Check that sucheme.wasm was built with zig build wasm and is served from the same place as web/.\n" + fileHint, "error");
          versionLabel.textContent = "Load failed";
          // 入力は受け付けない(loading のまま)。
        } else {
          // 評価中の異常終了。インスタンスは壊れているので、作り直す。
          startWorker();
          show(`The interpreter crashed, so its state was reset: ${m.message}`, "error");
        }
        break;
    }
  };

  // スクリプトの取得や構文の失敗は、メッセージではなく error イベントで届く。
  w.onerror = (event) => {
    if (w !== worker) return;
    event.preventDefault();
    show(`Failed to load the worker: ${event.message || "unknown cause"}\n${fileHint}`, "error");
    versionLabel.textContent = "Load failed";
    setPhase("loading");
  };
  w.onmessageerror = () => {
    if (w !== worker) return;
    show("Could not read a message from the worker.", "error");
  };

  show("Loading WebAssembly…", "busy");
  w.postMessage({ type: "init", wasmUrl });
}

form.addEventListener("submit", (event) => {
  event.preventDefault();
  if (phase !== "ready") return;
  runningId = nextId++;
  setPhase("running");
  show("Running…", "busy");
  worker.postMessage({ type: "eval", id: runningId, source: source.value });
});

stopButton.addEventListener("click", () => {
  if (phase !== "running") return;
  startWorker();
  // startWorker が出す「読み込み中」より、停止の知らせを優先する。
  show("Stopped. The state was reset.", "ok");
});

resetButton.addEventListener("click", () => {
  if (phase !== "ready") return;
  setPhase("running");
  runningId = 0;
  worker.postMessage({ type: "reset" });
});

source.addEventListener("keydown", (event) => {
  if (event.key === "Enter" && (event.ctrlKey || event.metaKey)) {
    event.preventDefault();
    form.requestSubmit();
  }
});

// サンプル: 選ぶと入力欄に入る。実行はしない。選び直せるよう、選択は先頭に戻す。
for (const sample of samples) {
  const option = document.createElement("option");
  option.value = sample.id;
  option.textContent = sample.title;
  sampleSelect.append(option);
}

sampleSelect.addEventListener("change", () => {
  const sample = samples.find((s) => s.id === sampleSelect.value);
  sampleSelect.value = "";
  if (sample === undefined) return;
  source.value = sample.source;
  shareStatus.textContent = "";
  source.focus();
});

// 共有リンク: 入力欄の内容を URL のフラグメントに入れる。リンクを開いたときは、入力欄に戻すだけで、
// 実行しない。他人が作ったリンクを開いただけで、無限ループなどのコードが走らないようにするためである。
function restoreFromFragment() {
  if (location.hash === "") return;
  const restored = decodeFragment(location.hash);
  if (restored === null) {
    shareStatus.textContent = "The share link could not be read, so the input is unchanged.";
    return;
  }
  source.value = restored;
  shareStatus.textContent = "The input was restored from the share link. Check it, then press Run.";
}

shareButton.addEventListener("click", async () => {
  const fragment = encodeFragment(source.value);
  if (fragment === null) {
    shareStatus.textContent = "The input is too long for a share link.";
    return;
  }
  history.replaceState(null, "", fragment);
  shareUrl.value = location.href;
  try {
    await navigator.clipboard.writeText(location.href);
    shareStatus.textContent = "Link copied.";
  } catch {
    // クリップボードが使えない文脈では、欄を選んで、手でコピーしてもらう。
    shareUrl.select();
    shareStatus.textContent = "Copy the link from the field.";
  }
});

window.addEventListener("hashchange", restoreFromFragment);
restoreFromFragment();

startWorker();
