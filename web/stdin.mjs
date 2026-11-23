// 入力待ちの部品。DOM に触れず、Node から試せる。
//
// `(read)`、`(read-line)`、`(read-char)` などが入力を待つと、画面は1行の入力欄を出す。
// 渡すのは、入力欄の1行(Enter)か、入力の終端(「End of input」か Ctrl+D)である。
// 渡した行は、端末のエコーと同じく、出力にも写る(web/runner.mjs)。

// 入力欄の1行を、処理系へ渡す文字列にする。行の終わりの改行を足す(`read-line` は、改行で1行を読み終える)。
// 空の行は "\n" 1つになる。長さ 0 の文字列は何も渡さないので(src/wasm.zig)、空行はこの形でしか渡せない。
export function lineToSend(value) {
  return `${value}\n`;
}

// 入力の終端を送るキーか。Ctrl+D だけで、Shift や Alt や Cmd との組み合わせ、変換中の入力は含めない。
// 端末の EOF と同じキーである。ブラウザは Ctrl+D をブックマークに使うので、受けたら既定の動作を止める。
export function isEofKey(event) {
  return (
    event.ctrlKey === true &&
    !event.shiftKey &&
    !event.altKey &&
    !event.metaKey &&
    event.isComposing !== true &&
    typeof event.key === "string" &&
    event.key.toLowerCase() === "d"
  );
}

// 画面の文言。
export const stdinText = {
  // 入力欄の見出し。
  label: "Input for the program",
  // 入力待ちの間の案内。
  waiting: "The program is waiting for input. Type a line and press Enter, or choose End of input (Ctrl+D).",
  // 終端を渡したあと、Reset まで残る。
  ended: "Input has ended. Reads return end-of-file until you press Reset.",
};
