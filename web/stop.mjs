// 停止の操作の部品。DOM に触れず、Node から試せる。
//
// 停止は、Worker に要求を送り、評価を歩数の区切りで捨てる。それまでの定義は残る。
// Worker が応答しない場合(ライブラリの `import` の途中など、区切りの無い間)だけ、
// Worker を捨てて作り直す。そのとき、定義は失われる。

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

// 停止の注意と知らせの文言。
export const stopWarning = {
  // 評価中に、停止の近くに出す。
  before: "Stop ends the evaluation. Definitions made so far are kept.",
  // 停止を要求してから、評価が止まるまで。
  waiting: "Stopping…",
  // 評価を捨てて、定義が残ったとき。
  kept: "Stopped. Definitions made so far were kept.",
  // Worker が応答せず、作り直したとき。
  lost: "Stopped. The evaluation did not respond, so the interpreter was restarted and all definitions were lost.",
};

// Worker が停止の要求に応えるのを待つ時間(ミリ秒)。これを過ぎたら、Worker を作り直す。
export const stopTimeoutMs = 3000;

// 停止の知らせ。経過時間を添える。
export function stoppedMessage(elapsedMs) {
  return `${stopWarning.kept} (ran for ${formatElapsed(elapsedMs)})`;
}

// Worker を作り直したときの知らせ。経過時間を添える。
export function restartedMessage(elapsedMs) {
  return `${stopWarning.lost} (ran for ${formatElapsed(elapsedMs)})`;
}

// 停止で捨てた評価の表示。`describeResult`(errors.mjs)と同じ形の `{ output, error }` を返す。
// 止めるまでの出力は残す。停止は失敗ではないので、画面側は、エラーの色にしない。
export function describeStopped(output, elapsedMs) {
  return {
    output,
    error: {
      title: "Stopped",
      message: `ran for ${formatElapsed(elapsedMs)}`,
      hint: "The evaluation was dropped. Definitions made so far were kept.",
    },
  };
}

// 評価中に Esc で停止するかの判定。変換中の入力(IME)の Esc は、確定の取り消しに使われるので、
// 停止にしない。
export function isStopKey(event, phase) {
  return phase === "running" && event.key === "Escape" && event.isComposing !== true;
}
