// router-harness.mjs STORE PORTFILE — run scripts/release/pkgrepo-router.js
// (the real Worker module) in Node against a fake-store directory, for the
// routing controls in tests/test-pkgrepo.sh and tests/test-pkgrepo-clients.sh.
//
//   origin  STORE/o/<key> over HTTP, like the S3 website endpoint: ETag = MD5
//           of the body (as S3 single-part), Cache-Control from the metadata the
//           fake adapter recorded (STORE/m/<key>.cache), 404 for a missing key,
//           304 for a matching If-None-Match.
//   router  the Worker's fetch() with env.ORIGIN = that origin.
//
// Cloudflare's edge cache is MODELLED, not dropped: a subrequest with
// `cf.cacheEverything` is looked up in an in-memory edge cache keyed by URL, and
// a GET response is stored for the TTL Cloudflare would give it —
// `cf.cacheTtlByStatus` (a negative TTL: not cached) or, when set,
// `cf.cacheTtl`, which applies to EVERY status. `cache: "no-store"` bypasses
// it. HEAD is answered from a cached GET. Origin faults: a file
// STORE/faults/<key> holding a status makes the origin answer that status for
// the key until the file is removed. Every origin request is appended to
// STORE/origin.log ("METHOD key"). It writes the router's port to PORTFILE
// and serves until killed.
// ROUTER_BIND (default 127.0.0.1) and ROUTER_PORT (default: any) set where the
// router listens.
import http from "node:http";
import fs from "node:fs";
import path from "node:path";
import crypto from "node:crypto";
import { fileURLToPath } from "node:url";

const [store, portFile] = process.argv.slice(2);
if (!store || !portFile) {
  console.error("usage: router-harness.mjs STORE PORTFILE");
  process.exit(2);
}
const here = path.dirname(fileURLToPath(import.meta.url));
const routerPath = process.env.ROUTER || path.join(here, "../../../scripts/release/pkgrepo-router.js");
// Imported from its source as a module: a `.js` file outside a
// "type": "module" package is CommonJS to Node before 22.
const worker = (await import("data:text/javascript," + encodeURIComponent(fs.readFileSync(routerPath, "utf8")))).default;
const root = path.resolve(store, "o");

const origin = http.createServer((req, res) => {
  let key;
  try {
    key = decodeURIComponent(new URL(req.url, "http://origin").pathname).replace(/^\/+/, "");
  } catch {
    res.writeHead(400).end();
    return;
  }
  // Best effort: a store mounted read-only simply has no origin log.
  try {
    fs.appendFileSync(path.join(store, "origin.log"), `${req.method} ${key}\n`);
  } catch {}
  const fault = path.join(store, "faults", key);
  if (fs.existsSync(fault)) {
    res.writeHead(Number(fs.readFileSync(fault, "utf8").trim()), { "content-type": "text/plain" }).end("fault\n");
    return;
  }
  const file = path.resolve(root, key);
  if (!file.startsWith(root + path.sep) || !fs.existsSync(file) || !fs.statSync(file).isFile()) {
    res.writeHead(404, { "content-type": "text/plain" }).end("NoSuchKey\n");
    return;
  }
  const body = fs.readFileSync(file);
  const etag = `"${crypto.createHash("md5").update(body).digest("hex")}"`;
  let cc = "no-cache";
  try {
    cc = fs.readFileSync(path.join(store, "m", key + ".cache"), "utf8").trim();
  } catch {}
  const headers = { etag, "cache-control": cc, "content-type": "application/octet-stream" };
  if (req.headers["if-none-match"] === etag) {
    res.writeHead(304, headers).end();
    return;
  }
  res.writeHead(200, { ...headers, "content-length": body.length });
  res.end(req.method === "HEAD" ? undefined : body);
});
await new Promise((r) => origin.listen(0, "127.0.0.1", r));
const ORIGIN = `http://127.0.0.1:${origin.address().port}`;

function edgeTtl(cf, status) {
  if (typeof cf.cacheTtl === "number") return cf.cacheTtl;
  for (const [range, ttl] of Object.entries(cf.cacheTtlByStatus || {})) {
    const [lo, hi] = range.split("-").map(Number);
    if (status >= lo && status <= (hi || lo)) return ttl;
  }
  return 0;
}
const edge = new Map();
const realFetch = globalThis.fetch;
globalThis.fetch = async (url, init = {}) => {
  const { cf, cache, ...rest } = init;
  const method = rest.method || "GET";
  if (cache === "no-store" || !cf || !cf.cacheEverything) return realFetch(url, rest);
  const hit = edge.get(url);
  if (hit && hit.expires > Date.now()) {
    return new Response(method === "HEAD" ? null : hit.body, { status: hit.status, headers: hit.headers });
  }
  const r = await realFetch(url, rest);
  const ttl = edgeTtl(cf, r.status);
  if (method !== "GET" || ttl <= 0 || r.status === 304) return r;
  const body = await r.arrayBuffer();
  const headers = [...r.headers];
  edge.set(url, { status: r.status, headers, body, expires: Date.now() + ttl * 1000 });
  return new Response(body, { status: r.status, headers });
};

const router = http.createServer(async (req, res) => {
  try {
    const request = new Request(`http://router${req.url}`, { method: req.method, headers: req.headers });
    const resp = await worker.fetch(request, { ORIGIN });
    const body = req.method === "HEAD" ? null : Buffer.from(await resp.arrayBuffer());
    const headers = Object.fromEntries(resp.headers);
    if (body) headers["content-length"] = body.length;
    delete headers["transfer-encoding"];
    delete headers["content-encoding"];
    res.writeHead(resp.status, headers);
    res.end(body ?? undefined);
  } catch (e) {
    res.writeHead(502, { "content-type": "text/plain" }).end(String(e) + "\n");
  }
});
await new Promise((r) => router.listen(Number(process.env.ROUTER_PORT || 0), process.env.ROUTER_BIND || "127.0.0.1", r));
fs.writeFileSync(portFile, String(router.address().port));
