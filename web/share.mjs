// Making and reading the share link: the source of the input, kept in the URL fragment.
//
// 形は `#code=<UTF-8 の base64url>` である。圧縮はしない。依存パッケージを使わず、
// ブラウザと Node.js のどちらでも動く(`btoa` と `atob` と `TextEncoder` は、どちらにもある)。
// フラグメントはサーバに送られない。リンクを開いたときの扱い(入力欄に戻すだけで、実行は
// しない)は、app.js が決める。

/** The longest fragment, in characters, that makes or reads. */
export const MAX_FRAGMENT_LENGTH = 16 * 1024;

const prefix = "#code=";
const encoder = new TextEncoder();
const decoder = new TextDecoder("utf-8", { fatal: true });

/**
 * The fragment that carries `source`, or null when it would be longer than
 * `MAX_FRAGMENT_LENGTH`.
 */
export function encodeFragment(source) {
  const bytes = encoder.encode(source);
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  const body = btoa(binary).replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/, "");
  const fragment = prefix + body;
  return fragment.length > MAX_FRAGMENT_LENGTH ? null : fragment;
}

/**
 * The source a fragment carries, or null when the fragment is not a share link: another
 * form, base64url that is broken, bytes that are not UTF-8, or longer than
 * `MAX_FRAGMENT_LENGTH`. An empty source is a valid link.
 */
export function decodeFragment(fragment) {
  if (typeof fragment !== "string") return null;
  if (fragment.length > MAX_FRAGMENT_LENGTH || !fragment.startsWith(prefix)) return null;
  const body = fragment.slice(prefix.length);
  // 末尾の `=` は付けない形だけを受ける。文字の集合の外は壊れている。長さが 4n+1 のものは、
  // 下の `atob` が断る。
  if (!/^[A-Za-z0-9_-]*$/.test(body)) return null;
  const padded = body.replaceAll("-", "+").replaceAll("_", "/") + "=".repeat((4 - (body.length % 4)) % 4);
  try {
    const binary = atob(padded);
    const bytes = new Uint8Array(binary.length);
    for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
    return decoder.decode(bytes);
  } catch {
    return null;
  }
}
