// A static file server for opening the web UI locally: `node web/serve.mjs [port] [wasm-dir]`.
//
// `web/` のファイルと、sucheme.wasm のあるディレクトリ(既定は `zig-out/web`)を同じオリジンで
// 配る。`file://` ではブラウザが wasm と Worker を読ませないので、この小さなサーバを使う
// (docs/adr/0021-no-github-pages-defer-hosting.md)。依存パッケージは無い。
//
// 127.0.0.1 だけで待ち受ける。`node web/serve.mjs --self-test` は、一時ディレクトリで起動して
// Content-Type と 404 を確かめ、終了する。

import http from "node:http";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import assert from "node:assert/strict";
import { fileURLToPath } from "node:url";

const HOST = "127.0.0.1";
const DEFAULT_PORT = 8000;

const CONTENT_TYPES = new Map([
  [".html", "text/html; charset=utf-8"],
  [".css", "text/css; charset=utf-8"],
  [".js", "text/javascript; charset=utf-8"],
  [".mjs", "text/javascript; charset=utf-8"],
  [".json", "application/json; charset=utf-8"],
  [".wasm", "application/wasm"],
  [".svg", "image/svg+xml"],
  [".txt", "text/plain; charset=utf-8"],
]);

/**
 * Finds the file a URL path names inside one of the roots, or null.
 *
 * ルートの外へ出る参照(`..`、エンコードした `..`、NUL)は null にする。ルートは順に探し、
 * 最初に見つかったファイルを返す。
 */
function resolveFile(roots, urlPath) {
  let decoded;
  try {
    decoded = decodeURIComponent(urlPath);
  } catch {
    return null;
  }
  if (decoded.includes("\0") || decoded.includes("\\")) return null;
  if (decoded.endsWith("/")) decoded += "index.html";
  for (const root of roots) {
    const file = path.resolve(root, "." + decoded);
    const relative = path.relative(root, file);
    if (relative === "" || relative.startsWith("..") || path.isAbsolute(relative)) continue;
    try {
      if (fs.statSync(file).isFile()) return file;
    } catch {
      // 次のルートを探す。
    }
  }
  return null;
}

/** Makes a server over `roots`, a list of directories searched in order. */
function createServer(roots) {
  const resolvedRoots = roots.map((r) => path.resolve(r));
  return http.createServer((req, res) => {
    if (req.method !== "GET" && req.method !== "HEAD") {
      res.writeHead(405, { Allow: "GET, HEAD" }).end();
      return;
    }
    const urlPath = (req.url ?? "/").split(/[?#]/, 1)[0];
    const file = resolveFile(resolvedRoots, urlPath);
    if (file === null) {
      res.writeHead(404, { "Content-Type": "text/plain; charset=utf-8" }).end("not found\n");
      return;
    }
    let body;
    try {
      body = fs.readFileSync(file);
    } catch {
      res.writeHead(404, { "Content-Type": "text/plain; charset=utf-8" }).end("not found\n");
      return;
    }
    const type = CONTENT_TYPES.get(path.extname(file).toLowerCase()) ?? "application/octet-stream";
    res.writeHead(200, {
      "Content-Type": type,
      "Content-Length": body.length,
      // 開発用なので、ビルドし直した wasm を次の読み込みで必ず取り直す。
      "Cache-Control": "no-store",
    });
    res.end(req.method === "HEAD" ? undefined : body);
  });
}

/** Returns the path of `sucheme.wasm` in the first root that has it, or null. */
function findWasm(roots) {
  for (const root of roots) {
    const file = path.join(root, "sucheme.wasm");
    try {
      if (fs.statSync(file).isFile()) return file;
    } catch {
      // 次のルートを探す。
    }
  }
  return null;
}

function listen(server, port) {
  return new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(port, HOST, () => resolve(server.address().port));
  });
}

/** Sends one request with the path unchanged (fetch would normalise `..` away). */
function rawGet(port, rawPath) {
  return new Promise((resolve, reject) => {
    http
      .get({ host: HOST, port, path: rawPath }, (res) => {
        const chunks = [];
        res.on("data", (c) => chunks.push(c));
        res.on("end", () => resolve({ status: res.statusCode, type: res.headers["content-type"], body: Buffer.concat(chunks) }));
      })
      .on("error", reject);
  });
}

async function selfTest() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "sucheme-serve-"));
  const webDir = path.join(dir, "web");
  const wasmDir = path.join(dir, "wasm");
  fs.mkdirSync(webDir);
  fs.mkdirSync(wasmDir);
  fs.writeFileSync(path.join(webDir, "index.html"), "<!doctype html><title>t</title>");
  fs.writeFileSync(path.join(webDir, "style.css"), "body {}");
  fs.writeFileSync(path.join(webDir, "app.js"), "export {};");
  fs.writeFileSync(path.join(webDir, "worker.mjs"), "export {};");
  fs.writeFileSync(path.join(wasmDir, "sucheme.wasm"), Buffer.from([0x00, 0x61, 0x73, 0x6d, 1, 0, 0, 0]));
  // ルートの外にあるファイルは、どの綴りでも取れない。
  fs.writeFileSync(path.join(dir, "secret.txt"), "secret");

  const server = createServer([webDir, wasmDir]);
  const port = await listen(server, 0);
  let checks = 0;
  const check = (name, actual, expected) => {
    assert.deepEqual(actual, expected, name);
    checks += 1;
  };
  try {
    // 起動時の警告は、sucheme.wasm がどのルートにも無いときだけ出す。zip を展開して平らに
    // 置いた形(wasm が `web/` 側のルートにある)でも、wasm 専用のルートにある形でも出さない。
    const emptyDir = path.join(dir, "empty");
    fs.mkdirSync(emptyDir);
    const flatDir = path.join(dir, "flat");
    fs.mkdirSync(flatDir);
    fs.writeFileSync(path.join(flatDir, "sucheme.wasm"), Buffer.from([0x00, 0x61, 0x73, 0x6d, 1, 0, 0, 0]));
    check("wasm in the second root", findWasm([webDir, wasmDir]), path.join(wasmDir, "sucheme.wasm"));
    check("wasm in the first root", findWasm([flatDir, emptyDir]), path.join(flatDir, "sucheme.wasm"));
    check("wasm in no root", findWasm([webDir, emptyDir]), null);
    // 両方にあるときは、サーバが返すのと同じ先頭のルートのものを選ぶ。
    check("wasm in both roots", findWasm([flatDir, wasmDir]), path.join(flatDir, "sucheme.wasm"));

    const get = async (p) => {
      const r = await rawGet(port, p);
      return [r.status, r.type];
    };
    check("/", await get("/"), [200, "text/html; charset=utf-8"]);
    check("/index.html", await get("/index.html"), [200, "text/html; charset=utf-8"]);
    check("/style.css", await get("/style.css"), [200, "text/css; charset=utf-8"]);
    check("/app.js", await get("/app.js"), [200, "text/javascript; charset=utf-8"]);
    check("/worker.mjs", await get("/worker.mjs"), [200, "text/javascript; charset=utf-8"]);
    check("/sucheme.wasm", await get("/sucheme.wasm"), [200, "application/wasm"]);
    check("wasm body", [...(await rawGet(port, "/sucheme.wasm")).body.subarray(0, 4)], [0x00, 0x61, 0x73, 0x6d]);
    check("missing file", (await get("/nothing.html"))[0], 404);
    check("directory without slash", (await get("/."))[0], 404);
    check("/../etc/passwd", (await get("/../etc/passwd"))[0], 404);
    check("/../secret.txt", (await get("/../secret.txt"))[0], 404);
    check("/%2e%2e/secret.txt", (await get("/%2e%2e/secret.txt"))[0], 404);
    check("/..%2fsecret.txt", (await get("/..%2fsecret.txt"))[0], 404);
    check("/wasm/../../secret.txt", (await get("/wasm/../../secret.txt"))[0], 404);
    check("NUL byte", (await get("/index.html%00"))[0], 404);
    check("bad escape", (await get("/%zz"))[0], 404);
    check("query string is ignored", (await get("/index.html?v=1"))[0], 200);
  } finally {
    await new Promise((resolve) => server.close(resolve));
    fs.rmSync(dir, { recursive: true, force: true });
  }
  console.log(`serve: self-test passed (${checks} checks)`);
}

async function main(argv) {
  if (argv.includes("--self-test")) {
    await selfTest();
    return;
  }
  const here = path.dirname(fileURLToPath(import.meta.url));
  let port = DEFAULT_PORT;
  let wasmDir = path.resolve(here, "..", "zig-out", "web");
  for (const arg of argv) {
    if (/^\d+$/.test(arg)) {
      port = Number(arg);
    } else {
      wasmDir = path.resolve(arg);
    }
  }
  if (port > 65535) {
    console.error(`serve: invalid port ${port}`);
    process.exit(2);
  }
  const roots = [here, wasmDir];
  // PR の成果物を展開した形では、wasm は `serve.mjs` と同じディレクトリにある。どのルートにも
  // 無いときだけ警告する。
  if (findWasm(roots) === null) {
    console.error(`serve: warning: ${path.join(wasmDir, "sucheme.wasm")} does not exist; run \`zig build wasm\` first`);
  }
  const server = createServer(roots);
  const actual = await listen(server, port);
  console.log(`serving ${here} and ${wasmDir}`);
  console.log(`open http://${HOST}:${actual}/`);
}

main(process.argv.slice(2)).catch((e) => {
  console.error(`serve: ${e && e.message ? e.message : e}`);
  process.exit(1);
});
