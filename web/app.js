// The controller of the page: owns the worker and the buttons.
//
// 状態は loading(WASM を読み込み中)・ready(入力を受け付ける)・running(評価中)の3つ。
// 「停止」(ボタンと Esc)は、Worker に停止を要求する。Worker は、評価を歩数の区切りで捨てる。
// それまでの定義は残る(runner.mjs)。Worker が時間内に応えないとき(ライブラリの `import` の途中など、
// 区切りの無い間)だけ、Worker を捨てて作り直す(worker.terminate())。作り直した処理系は初期状態
// なので、定義はすべて失われ、そのことを画面に出す(stop.mjs)。
// 評価中は経過時間を出す。
//
// 評価中に `(read)` などが入力を待つと、Worker が needs-input を送り、画面は、そこまでの出力と、
// 1行の入力欄(「Send」と「End of input」。stdin.mjs)を出す。状態は running のままで、入力欄を出すかを
// `inputWaiting` で持つ(停止、経過時間、Run と Reset が無効なことは、評価中と同じだから)。渡した行は
// 出力に写される(runner.mjs)。入力の終端は、Reset(か Worker の作り直し)まで残る(`inputEnded`)。
//
// 画面の文言は英語にする(AGENTS.md の言語ルール)。結果の説明は errors.mjs が作る。

import { Status } from "./sucheme.js";
import { describeResult } from "./errors.mjs";
import { samples } from "./samples.mjs";
import { encodeFragment, decodeFragment } from "./share.mjs";
import { highlightPair, changeIndent, nextTabMovesFocus } from "./parens.mjs";
import { createHistory, onFirstLine, onLastLine } from "./history.mjs";
import { formatElapsed, stopWarning, restartedMessage, describeStopped, stopTimeoutMs, isStopKey } from "./stop.mjs";
import { lineToSend, isEofKey, stdinText } from "./stdin.mjs";

const form = document.getElementById("form");
const source = document.getElementById("source");
const mirror = document.getElementById("mirror");
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
const elapsedLabel = document.getElementById("elapsed");
const stopWarningLabel = document.getElementById("stop-warning");
const stdinForm = document.getElementById("stdin-form");
const stdinLabel = document.getElementById("stdin-label");
const stdinInput = document.getElementById("stdin");
const stdinEofButton = document.getElementById("stdin-eof");
const stdinHint = document.getElementById("stdin-hint");
const inputEndedLabel = document.getElementById("input-ended");

// sucheme.wasm は、このファイルと同じ階層から相対パスで取る。
const wasmUrl = new URL("./sucheme.wasm", import.meta.url).href;
const workerUrl = new URL("./worker.js", import.meta.url);

let worker = null;
let phase = "loading";
let nextId = 1;
let runningId = 0;
const inputHistory = createHistory();
// 停止を要求してから、Worker の応答を待つ間のタイマー。要求していなければ null。
let stopTimer = null;
// 入力欄を出しているか(読み取りが入力を待っているか)。
let inputWaiting = false;
// この評価で入力欄を使ったか。評価が終わったら、ソースの欄にフォーカスを戻す。
let usedInputField = false;
// 入力の終端を渡したか。処理系が Reset されるまで、読み取りは終端を返す。
let inputEnded = false;

// 状態の知らせ(読み込み中、停止など)を出力欄に出す。エラーの欄は閉じる。
function show(text, status = "ok") {
  output.textContent = text;
  output.dataset.status = status;
  errorPanel.hidden = true;
}

// 評価の結果を出す。プログラムの出力は出力欄に、エラーの説明は別の欄に出す。
// エラーの前に出た出力は、出力欄に残る。
function showResult(status, text, exitCode) {
  render(describeResult(status, text, exitCode), status === Status.EXITED ? "exit" : "error");
}

// `{ output, error }` を出す。`kind` は、エラーの欄の色(exit は失敗ではない)。
function render({ output: out, error }, kind) {
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
  errorPanel.dataset.kind = kind;
  errorPanel.hidden = false;
}

// 評価中の経過時間。評価を始めたときに数え始め、結果が出る、または停止すると止まる。
let evalStartedAt = 0;
let elapsedTimer = null;

function stopElapsed() {
  if (elapsedTimer !== null) clearInterval(elapsedTimer);
  elapsedTimer = null;
  const elapsed = performance.now() - evalStartedAt;
  elapsedLabel.hidden = true;
  return elapsed;
}

function startElapsed() {
  evalStartedAt = performance.now();
  const tick = () => {
    elapsedLabel.textContent = `Elapsed: ${formatElapsed(performance.now() - evalStartedAt)}`;
  };
  tick();
  elapsedLabel.hidden = false;
  // 評価は Worker で走るので、メインスレッドの時計は止まらない。
  elapsedTimer = setInterval(tick, 100);
}

// 入力欄を出す、または隠す。出すときは、フォーカスを移す。
function setInputWaiting(on) {
  inputWaiting = on;
  stdinForm.hidden = !on;
  if (!on) return;
  usedInputField = true;
  stdinLabel.textContent = stdinText.label;
  stdinHint.textContent = stdinText.waiting;
  stdinInput.value = "";
  stdinInput.focus();
}

// 入力の終端を渡したことの表示。Reset か Worker の作り直しで消える。
function setInputEnded(ended) {
  inputEnded = ended;
  inputEndedLabel.textContent = ended ? stdinText.ended : "";
  inputEndedLabel.hidden = !ended;
}

function setPhase(next) {
  if (phase === "running" && next !== "running" && elapsedTimer !== null) stopElapsed();
  if (next !== "running") setInputWaiting(false);
  if (phase === "running" && next === "ready" && usedInputField) source.focus();
  if (next !== "running") usedInputField = false;
  // 評価を離れるとき、停止の応答待ちは要らない。
  if (next !== "running" && stopTimer !== null) clearTimeout(stopTimer);
  if (next !== "running") stopTimer = null;
  // 評価中は、停止しても定義が残ることを、停止の近くに示す。
  stopWarningLabel.textContent = next === "running" ? stopWarning.before : "";
  stopWarningLabel.hidden = next !== "running";
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

// Worker を作り直す。作れたかを返す(作れなければ、失敗の説明を出力欄に出してある)。
function startWorker() {
  if (worker !== null) worker.terminate();
  setPhase("loading");
  // 作り直した処理系は、入力の終端を知らない。
  setInputEnded(false);
  versionLabel.textContent = "Loading…";
  if (openedFromFile()) {
    show(fileHint, "error");
    return false;
  }
  let w;
  try {
    w = new Worker(workerUrl, { type: "module" });
  } catch (e) {
    show(`Could not create the worker: ${e.message}\n${fileHint}`, "error");
    return false;
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
        // 経過時間は、setPhase が時計を止める前に取る。
        const elapsed = performance.now() - evalStartedAt;
        if (m.stopped) render(describeStopped(m.output, elapsed), "exit");
        else showResult(m.status, m.output, m.exitCode);
        setPhase("ready");
        break;
      }
      case "needs-input":
        // 停止を要求したあとは、入力欄を出さない(Worker は評価を捨てる)。
        if (m.id !== runningId || phase !== "running" || stopTimer !== null) break;
        output.textContent = m.output;
        output.dataset.status = "ok";
        errorPanel.hidden = true;
        setInputWaiting(true);
        break;
      case "reset-done":
        if (m.status === Status.OK) setInputEnded(false);
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
  return true;
}

form.addEventListener("submit", (event) => {
  event.preventDefault();
  if (phase !== "ready") return;
  runningId = nextId++;
  inputHistory.push(source.value);
  setPhase("running");
  startElapsed();
  show("Running…", "busy");
  worker.postMessage({ type: "eval", id: runningId, source: source.value });
});

// 停止する。Worker に要求を送り、評価が区切りで止まるのを待つ。時間内に応えなければ、
// Worker を作り直す(定義は失われる)。経過時間は、時計を止める前に取る。
function stopEvaluation() {
  if (phase !== "running" || stopTimer !== null) return;
  stopButton.disabled = true;
  // 入力待ちの間に止めたときは、入力欄を閉じる(渡しても、Worker は受け取らない)。
  setInputWaiting(false);
  stopWarningLabel.textContent = stopWarning.waiting;
  worker.postMessage({ type: "stop", id: runningId });
  stopTimer = setTimeout(() => {
    stopTimer = null;
    const elapsed = performance.now() - evalStartedAt;
    const measured = elapsedTimer !== null;
    // 作り直せなかったときは、startWorker が出した失敗の説明を、停止の知らせで上書きしない。
    if (!startWorker()) return;
    show(measured ? restartedMessage(elapsed) : stopWarning.lost, "ok");
  }, stopTimeoutMs);
}

stopButton.addEventListener("click", stopEvaluation);

// 入力待ちの入力欄。Enter(か「Send」)で、行を改行つきで渡す。渡した行は、出力にも写す(Worker が
// 出力に足すのと同じ文字列を、次の知らせまでの間、ここで足しておく)。
stdinForm.addEventListener("submit", (event) => {
  event.preventDefault();
  if (!inputWaiting) return;
  const text = lineToSend(stdinInput.value);
  setInputWaiting(false);
  output.textContent += text;
  worker.postMessage({ type: "input", id: runningId, text });
});

// 入力の終端を渡す。以後の読み取りは、Reset まで終端を返す。
function sendEndOfInput() {
  if (!inputWaiting) return;
  setInputWaiting(false);
  setInputEnded(true);
  worker.postMessage({ type: "eof", id: runningId });
}

stdinEofButton.addEventListener("click", sendEndOfInput);

stdinInput.addEventListener("keydown", (event) => {
  // 変換の確定の Enter で、送らない(Safari は、確定のあとの keydown の isComposing が偽になる。keyCode 229 で見分ける)。
  if (event.key === "Enter" && (event.isComposing || event.keyCode === 229)) {
    event.preventDefault();
    return;
  }
  if (isEofKey(event)) {
    event.preventDefault();
    sendEndOfInput();
  }
});

// Esc でも停止する。評価中は入力欄が無効でなくフォーカスを持ちうるので、文書全体で受ける。
document.addEventListener("keydown", (event) => {
  if (!isStopKey(event, phase)) return;
  event.preventDefault();
  stopEvaluation();
});

resetButton.addEventListener("click", () => {
  if (phase !== "ready") return;
  setPhase("running");
  runningId = 0;
  worker.postMessage({ type: "reset" });
});

// 入力欄の編集の補助。
//
// 括弧の対応の強調: カーソルの隣の括弧と相手を、鏡の層(style.css の .editor-mirror)で目立たせる。
// 括弧の走査は parens.mjs(Zig の src/line_editor/parens.zig と同じ規則)である。
function renderMirror() {
  const text = source.value;
  const pair = source.selectionStart === source.selectionEnd ? highlightPair(text, source.selectionStart) : null;
  const nodes = [];
  if (pair === null) {
    nodes.push(text);
  } else {
    const [a, b] = pair;
    const mark = (i) => {
      const m = document.createElement("mark");
      m.textContent = text[i];
      return m;
    };
    nodes.push(text.slice(0, a), mark(a), text.slice(a + 1, b), mark(b), text.slice(b + 1));
  }
  // 末尾の改行の次の行にも、行の高さを持たせる。
  nodes.push("​");
  mirror.replaceChildren(...nodes);
  mirror.scrollTop = source.scrollTop;
}

// 入力欄の全体を置き換える。execCommand は、ブラウザの元に戻す操作の履歴を保つ(value への代入は消す)。
// 使えない場合は、value に代入する。
function replaceAll(text) {
  source.focus();
  source.select();
  if (!document.execCommand("insertText", false, text)) source.value = text;
  renderMirror();
}

for (const type of ["input", "keyup", "mouseup", "focus", "select"]) source.addEventListener(type, renderMirror);
source.addEventListener("scroll", () => {
  mirror.scrollTop = source.scrollTop;
});
document.addEventListener("selectionchange", () => {
  if (document.activeElement === source) renderMirror();
});

// Tab は字下げに使う。キーボードだけの利用者が入力欄から出られなくならないよう、Esc の次の Tab は、
// 通常どおりフォーカスを動かす(Shift+Tab で後ろへも出られる。修飾キーだけの keydown は、状態を変えない)。
// 次のキーで解除される。
let tabMovesFocus = false;

source.addEventListener("keydown", (event) => {
  if (event.isComposing) return;
  if (event.key === "Enter" && (event.ctrlKey || event.metaKey)) {
    event.preventDefault();
    form.requestSubmit();
    return;
  }
  const plain = !event.ctrlKey && !event.metaKey && !event.altKey;
  if (event.key === "Tab" && plain) {
    if (tabMovesFocus) {
      tabMovesFocus = false;
      return;
    }
    event.preventDefault();
    const r = changeIndent(source.value, source.selectionStart, source.selectionEnd, event.shiftKey);
    if (r.text !== source.value) replaceAll(r.text);
    source.setSelectionRange(r.start, r.end);
    renderMirror();
    return;
  }
  tabMovesFocus = nextTabMovesFocus(tabMovesFocus, event.key, phase);
  // 履歴: 選択が無く、最初の行の Up と最後の行の Down だけが、履歴を動く。
  // それ以外の Up と Down は、通常のカーソルの移動である。動けないときも、通常の移動に任せる。
  if (plain && !event.shiftKey && source.selectionStart === source.selectionEnd) {
    let recalled = null;
    if (event.key === "ArrowUp" && onFirstLine(source.value, source.selectionStart)) recalled = inputHistory.previous(source.value);
    else if (event.key === "ArrowDown" && onLastLine(source.value, source.selectionStart)) recalled = inputHistory.next();
    if (recalled !== null) {
      event.preventDefault();
      replaceAll(recalled);
      source.setSelectionRange(recalled.length, recalled.length);
      renderMirror();
    }
  }
});

source.addEventListener("blur", () => {
  tabMovesFocus = false;
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
  renderMirror();
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
  renderMirror();
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
renderMirror();

startWorker();
