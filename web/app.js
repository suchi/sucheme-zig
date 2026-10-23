// The controller of the page: owns the worker and the buttons.
//
// 状態は loading(WASM を読み込み中)・ready(入力を受け付ける)・running(評価中)の3つ。
// 「停止」は Worker を捨てて作り直す(worker.terminate())。作り直した処理系は初期状態なので、
// 定義はすべて失われる。

import { Status } from "./sucheme.js";
import { samples } from "./samples.mjs";
import { encodeFragment, decodeFragment } from "./share.mjs";

const form = document.getElementById("form");
const source = document.getElementById("source");
const runButton = document.getElementById("run");
const stopButton = document.getElementById("stop");
const resetButton = document.getElementById("reset");
const output = document.getElementById("output");
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

function show(text, status = "ok") {
  output.textContent = text;
  output.dataset.status = status;
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

const fileHint = "ローカルのサーバ経由で開いてください: node web/serve.mjs";

function describeStatus(status, text) {
  switch (status) {
    case Status.OK:
      return { text: text === "" ? "(出力なし)" : text, kind: "ok" };
    case Status.SCHEME_ERROR:
    case Status.INVALID_UTF8:
      // 説明は出力に入っている。そのまま見せる。
      return { text, kind: "error" };
    default:
      return { text: `${text}状態コード ${status}`, kind: "error" };
  }
}

function startWorker() {
  if (worker !== null) worker.terminate();
  setPhase("loading");
  versionLabel.textContent = "読み込み中…";
  if (openedFromFile()) {
    show(fileHint, "error");
    return;
  }
  let w;
  try {
    w = new Worker(workerUrl, { type: "module" });
  } catch (e) {
    show(`Worker を作れませんでした: ${e.message}\n${fileHint}`, "error");
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
        if (output.dataset.status === "busy") show("準備ができました。");
        break;
      case "result": {
        if (m.id !== runningId) break;
        const shown = describeStatus(m.status, m.output);
        show(shown.text, shown.kind);
        setPhase("ready");
        break;
      }
      case "reset-done":
        show(m.status === Status.OK ? "状態を初期化しました。" : `初期化に失敗しました(状態コード ${m.status})。`,
          m.status === Status.OK ? "ok" : "error");
        setPhase("ready");
        break;
      case "error":
        if (m.phase === "init") {
          show(`WebAssembly の読み込みに失敗しました: ${m.message}\n` +
            "zig build wasm で sucheme.wasm を作り、web/ と同じ場所から配っているか確認してください。\n" + fileHint, "error");
          versionLabel.textContent = "読み込み失敗";
          // 入力は受け付けない(loading のまま)。
        } else {
          // 評価中の異常終了。インスタンスは壊れているので、作り直す。
          startWorker();
          show(`処理系が異常終了したため、状態を初期化しました: ${m.message}`, "error");
        }
        break;
    }
  };

  // スクリプトの取得や構文の失敗は、メッセージではなく error イベントで届く。
  w.onerror = (event) => {
    if (w !== worker) return;
    event.preventDefault();
    show(`Worker の読み込みに失敗しました: ${event.message || "原因不明"}\n${fileHint}`, "error");
    versionLabel.textContent = "読み込み失敗";
    setPhase("loading");
  };
  w.onmessageerror = () => {
    if (w !== worker) return;
    show("Worker からのメッセージを読み取れませんでした。", "error");
  };

  show("WebAssembly を読み込んでいます…", "busy");
  w.postMessage({ type: "init", wasmUrl });
}

form.addEventListener("submit", (event) => {
  event.preventDefault();
  if (phase !== "ready") return;
  runningId = nextId++;
  setPhase("running");
  show("実行中…", "busy");
  worker.postMessage({ type: "eval", id: runningId, source: source.value });
});

stopButton.addEventListener("click", () => {
  if (phase !== "running") return;
  startWorker();
  // startWorker が出す「読み込み中」より、停止の知らせを優先する。
  show("停止しました。状態は初期化されました", "ok");
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
    shareStatus.textContent = "共有リンクを読み取れなかったので、入力欄はそのままです。";
    return;
  }
  source.value = restored;
  shareStatus.textContent = "共有リンクから入力を戻しました。内容を確かめてから「実行」を押してください。";
}

shareButton.addEventListener("click", async () => {
  const fragment = encodeFragment(source.value);
  if (fragment === null) {
    shareStatus.textContent = "入力が長すぎて、共有リンクにできません。";
    return;
  }
  history.replaceState(null, "", fragment);
  shareUrl.value = location.href;
  try {
    await navigator.clipboard.writeText(location.href);
    shareStatus.textContent = "リンクをコピーしました。";
  } catch {
    // クリップボードが使えない文脈では、欄を選んで、手でコピーしてもらう。
    shareUrl.select();
    shareStatus.textContent = "欄のリンクをコピーしてください。";
  }
});

window.addEventListener("hashchange", restoreFromFragment);
restoreFromFragment();

startWorker();
