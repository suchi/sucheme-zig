// The history of the inputs that were run, for the input field.
//
// DOM に触れない。Node から試せる(tools/test-wasm/main.mjs)。
// 履歴は、このページを開いている間だけ持つ(保存しない)。

export const MAX_ENTRIES = 100;

// 履歴の位置は、古い順に並べた記録の添字である。末尾の次(記録の数と同じ値)は、
// 「移動を始める前に入力欄にあった文字列(下書き)」を指す。
export function createHistory(limit = MAX_ENTRIES) {
  const entries = [];
  let index = 0;
  let draft = "";

  return {
    // 実行した入力を足す。空(空白だけ)の入力と、直前と同じ入力は足さない。
    // 足すと、位置は下書きに戻る。上限を超えたら、古いものから捨てる。
    push(text) {
      draft = "";
      if (text.trim() !== "" && entries[entries.length - 1] !== text) {
        entries.push(text);
        if (entries.length > limit) entries.shift();
      }
      index = entries.length;
    },

    // 1つ古い入力に移る。`current` は、いま入力欄にある文字列である。
    // 下書きの位置から動くときだけ、下書きとして覚える。動けない(いちばん古い)ときは null。
    previous(current) {
      if (index === 0) return null;
      if (index === entries.length) draft = current;
      index -= 1;
      return entries[index];
    },

    // 1つ新しい入力に移る。いちばん新しい入力の次は、下書きに戻る。動けない(下書きにいる)ときは null。
    next() {
      if (index >= entries.length) return null;
      index += 1;
      return index === entries.length ? draft : entries[index];
    },

    // 数(テスト用)。
    get length() {
      return entries.length;
    },
  };
}

// カーソルが、最初の行にあるか(`position` より前に改行が無いか)。選択が無いときの判定に使う。
export function onFirstLine(text, position) {
  return !text.slice(0, position).includes("\n");
}

// カーソルが、最後の行にあるか(`position` 以降に改行が無いか)。
export function onLastLine(text, position) {
  return !text.slice(position).includes("\n");
}
