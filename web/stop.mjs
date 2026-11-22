// 停止の操作の部品。DOM に触れず、Node から試せる。
//
// 現在の停止は Worker を捨てて作り直すので、処理系の状態(定義)が失われる。
// 8e-2 で状態が残る停止になったら、warning の文言を差し替える。

// 経過時間(ミリ秒)を表示用の文字列にする。1分未満は小数第1位までの秒、
// 1分以上は「分:秒」(秒は2桁)、1時間以上は「時:分:秒」にする。
// 負の値と NaN は 0 として扱う。秒の端数は切り捨てる(表示が実際より進まないように)。
export function formatElapsed(ms) {
  const safe = Number.isFinite(ms) && ms > 0 ? ms : 0;
  if (safe < 60000) {
    return `${(Math.floor(safe / 100) / 10).toFixed(1)} s`;
  }
  const total = Math.floor(safe / 1000);
  const h = Math.floor(total / 3600);
  const m = Math.floor((total % 3600) / 60);
  const s = total % 60;
  const two = (n) => String(n).padStart(2, "0");
  return h > 0 ? `${h}:${two(m)}:${two(s)}` : `${m}:${two(s)}`;
}

// 停止すると定義が失われることの注意。停止の前(評価中)と後で文言を分ける。
export const stopWarning = {
  before: "Stop discards all definitions made so far.",
  after: "Stopped. All definitions were lost, and the interpreter was reset.",
};

// 停止の知らせ。経過時間を添える。
export function stoppedMessage(elapsedMs) {
  return `${stopWarning.after} (ran for ${formatElapsed(elapsedMs)})`;
}

// 評価中に Esc で停止するかの判定。変換中の入力(IME)の Esc は、確定の取り消しに使われるので、
// 停止にしない。
export function isStopKey(event, phase) {
  return phase === "running" && event.key === "Escape" && event.isComposing !== true;
}
