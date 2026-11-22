// Matching parentheses and indentation helpers for the input field.
//
// DOM に触れない純粋な関数だけを置く。Node から試せる(tools/test-wasm/main.mjs)。
// `matching` は、src/line_editor/parens.zig の `matching` と同じ規則の写しである。
// 食い違わないことは、両方が読む共有の一覧(tests/parens/cases.tsv)で固定する。
// リーダの字句の規則が変わったら、Zig 側と同時に直す。
//
// 位置の単位は、JavaScript の文字列の添字(UTF-16 の符号単位)である。Zig 側はバイトの位置で、
// 共有の一覧は ASCII だけなので、両者は一致する。

function isWhitespace(c) {
  return c === " " || c === "\t" || c === "\n" || c === "\r";
}

function isDelimiter(c) {
  return isWhitespace(c) || c === "|" || c === "(" || c === ")" || c === '"' || c === ";";
}

// 括弧として数える位置を、先頭から1回ずつ返す。数えない位置(文字列、文字、コメント、
// 縦棒の識別子の中)は、読み飛ばす。
class Scanner {
  constructor(text) {
    this.text = text;
    this.pos = 0;
  }

  // 次の括弧 `{ index, open }` か、無ければ null。
  next() {
    const text = this.text;
    while (this.pos < text.length) {
      const c = text[this.pos];
      if (c === "(" || c === ")") {
        this.pos += 1;
        return { index: this.pos - 1, open: c === "(" };
      }
      if (c === ";") this.skipLine();
      else if (c === '"' || c === "|") this.skipQuoted(c);
      else if (c === "#") this.skipHash();
      else if (isWhitespace(c)) this.pos += 1;
      else this.skipAtom();
    }
    return null;
  }

  skipLine() {
    const text = this.text;
    while (this.pos < text.length && text[this.pos] !== "\n" && text[this.pos] !== "\r") this.pos += 1;
  }

  // 文字列(`"`)か縦棒の識別子(`|`)。バックスラッシュは次の符号単位を読み飛ばす。
  skipQuoted(mark) {
    const text = this.text;
    this.pos += 1;
    while (this.pos < text.length) {
      const c = text[this.pos];
      this.pos += 1;
      if (c === mark) return;
      if (c === "\\") this.pos += 1;
    }
    this.pos = text.length;
  }

  // `#|`(ブロックコメント)、`#;`、`#\`(文字)は、トークンの先頭でだけ特別である。
  // それ以外(`#(`、`#u8(`、`#t`)は `#` だけを進め、続きを通常の字句として読む。
  // `#;` の `;` は行コメントを始めない。捨てられるデータの中の括弧は数える。
  skipHash() {
    const text = this.text;
    const n = this.pos + 1 < text.length ? text[this.pos + 1] : "";
    if (n === "|") this.skipBlockComment();
    else if (n === ";") this.pos += 2;
    else if (n === "\\") this.skipCharacter();
    else this.pos += 1;
  }

  // ネストするブロックコメント。
  skipBlockComment() {
    const text = this.text;
    let depth = 0;
    while (this.pos + 1 < text.length) {
      if (text[this.pos] === "#" && text[this.pos + 1] === "|") {
        depth += 1;
        this.pos += 2;
      } else if (text[this.pos] === "|" && text[this.pos + 1] === "#") {
        depth -= 1;
        this.pos += 2;
        if (depth === 0) return;
      } else {
        this.pos += 1;
      }
    }
    this.pos = text.length;
  }

  // `#\` と、その次の1文字と、区切り文字までの続き。次の1文字が括弧でも、文字の一部である。
  // Why: Zig 側は、次の1文字の長さ(UTF-8)だけ進めてから続きを読む。こちらは1単位だけ進める。
  // 区切り文字は ASCII だけなので、サロゲートペアの2単位目は、続きとして読み飛ばされ、結果は同じである。
  skipCharacter() {
    const text = this.text;
    const start = this.pos + 2;
    if (start >= text.length) {
      this.pos = text.length;
      return;
    }
    this.pos = start + 1;
    this.skipAtom();
  }

  skipAtom() {
    const text = this.text;
    while (this.pos < text.length && !isDelimiter(text[this.pos])) this.pos += 1;
  }
}

// `close` の `)` が閉じる `(` の位置。2回走査する(parens.zig の `openerOf` と同じ)。
function openerOf(text, close) {
  let depth = 0;
  let scan = new Scanner(text);
  let found = false;
  for (let p = scan.next(); p !== null; p = scan.next()) {
    if (p.index > close) return null;
    if (p.open) {
      depth += 1;
    } else {
      if (p.index === close) {
        found = true;
        break;
      }
      if (depth === 0) continue; // 対応する `(` の無い `)` は、深さを変えない。
      depth -= 1;
    }
  }
  if (!found || depth === 0) return null;

  let level = 0;
  let candidate = null;
  scan = new Scanner(text);
  for (let p = scan.next(); p !== null; p = scan.next()) {
    if (p.index >= close) break;
    if (p.open) {
      level += 1;
      if (level === depth) candidate = p.index;
    } else if (level > 0) {
      level -= 1;
    }
  }
  return candidate;
}

// `open` の `(` を閉じる `)` の位置。
function closerOf(text, open) {
  let depth = 0;
  const scan = new Scanner(text);
  for (let p = scan.next(); p !== null; p = scan.next()) {
    if (p.index < open) continue;
    if (p.index === open) {
      depth = 1;
      continue;
    }
    if (depth === 0) return null; // `open` を通り過ぎた。括弧として数えない位置にある。
    if (p.open) {
      depth += 1;
    } else {
      depth -= 1;
      if (depth === 0) return p.index;
    }
  }
  return null;
}

// カーソル(文字と文字の間の位置)の隣の括弧と対応する括弧の位置を返す。無ければ null。
// カーソルの直前が `)` ならその相手の `(`、そうでなく直後が `(` ならその相手の `)`。
// 直前を先に見るのは、閉じ括弧を打った直後に、その対応を示すためである。
export function matching(text, cursor) {
  if (!Number.isInteger(cursor) || cursor < 0 || cursor > text.length) return null;
  if (cursor > 0 && text[cursor - 1] === ")") {
    const open = openerOf(text, cursor - 1);
    if (open !== null) return open;
  }
  if (cursor < text.length && text[cursor] === "(") return closerOf(text, cursor);
  return null;
}

// 強調する括弧の位置の組 `[ひとつ目, ふたつ目]`(昇順)か、無ければ null。
// 画面は、この位置の文字を目立たせる。
export function highlightPair(text, cursor) {
  const other = matching(text, cursor);
  if (other === null) return null;
  // `matching` が相手を返したときの、こちら側の括弧。直前の `)` が先に効く(上と同じ順)。
  // 直前の `)` の相手は、カーソルより前にある。直後の `(` の相手は、カーソルより後ろにある。
  const here = other < cursor ? cursor - 1 : cursor;
  return here < other ? [here, other] : [other, here];
}

export const INDENT = "  ";

// 選択した範囲(カーソルだけのときは、その位置)の字下げを変える。純粋な関数である。
//
// - 選択が無く、Shift も無い: カーソルの位置に INDENT を挿入する(単語の途中でも、字下げでなく挿入)。
// - 選択が複数行にまたがる、または outdent が真: 範囲に掛かる各行の先頭に INDENT を足す(outdent は取る)。
//   取るのは、INDENT 1つ分までの先頭の空白である(タブも1つと数える)。
// 戻り値は `{ text, start, end }`。start と end は、変更後の選択である。
export function changeIndent(text, start, end, outdent) {
  if (start === end && !outdent) {
    return { text: text.slice(0, start) + INDENT + text.slice(end), start: start + INDENT.length, end: start + INDENT.length };
  }
  const multiline = text.slice(start, end).includes("\n");
  if (!multiline && !outdent) {
    // 1行の中の選択は、置き換える(通常のテキストエディタの挙動)。
    return { text: text.slice(0, start) + INDENT + text.slice(end), start: start + INDENT.length, end: start + INDENT.length };
  }
  const firstLineStart = text.lastIndexOf("\n", start - 1) + 1;
  // 選択の終わりが行の先頭にぴったり来たとき、その行は含めない(複数行の選択で、最後の行が空のとき)。
  const lastIndex = end > start && text[end - 1] === "\n" ? end - 1 : end;
  let lineEnd = text.indexOf("\n", lastIndex);
  if (lineEnd === -1) lineEnd = text.length;
  const lines = text.slice(firstLineStart, lineEnd).split("\n");
  let newStart = start;
  let newEnd = end;
  let offset = firstLineStart;
  const changed = lines.map((line) => {
    let delta;
    let result;
    if (outdent) {
      let n = 0;
      if (line[0] === "\t") n = 1;
      else while (n < INDENT.length && line[n] === " ") n += 1;
      result = line.slice(n);
      delta = -n;
    } else {
      result = line.length === 0 ? line : INDENT + line;
      delta = result.length - line.length;
    }
    // 選択の端を、変えた行の分だけずらす。行の先頭より前には戻さない。
    // (比べるのは、変更前の位置どうしである。行の先頭ちょうどは、動かさない。)
    if (delta !== 0) {
      if (start > offset) newStart += Math.max(delta, offset - start);
      if (end > offset) newEnd += Math.max(delta, offset - end);
    }
    offset += line.length + 1;
    return result;
  });
  return { text: text.slice(0, firstLineStart) + changed.join("\n") + text.slice(lineEnd), start: newStart, end: newEnd };
}

// 「次の Tab でフォーカスを動かす」状態の更新。Esc で入り(評価中の Esc は停止に使うので除く)、
// Tab で出る。Shift、Control、Alt、Meta だけの keydown は、状態を変えない(Esc のあとの
// Shift+Tab で、Shift 自体の keydown が状態を戻してしまうのを避ける)。それ以外のキーは、状態を戻す。
export function nextTabMovesFocus(current, key, phase) {
  if (key === "Shift" || key === "Control" || key === "Alt" || key === "Meta") return current;
  return key === "Escape" && phase !== "running";
}
