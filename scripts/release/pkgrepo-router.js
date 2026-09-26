// pkgrepo-router.js — the read-only router in front of a package-repository-surface
// (standards/releases/package-repositories.md PR-7, PR-8, PR-9).
//
// A Cloudflare Worker (module syntax). It never writes, holds no secret and
// keeps no state: no KV, no Durable Object, no database, no lease.
//
//   · A request for a generation ENTRYPOINT at its stable URL (InRelease,
//     Release, Release.gpg, plain Packages indexes, repomd.xml(.asc), .sources,
//     .repo, public keys — ENTRYPOINT_PATTERNS, the same rule as
//     lib/pkgrepo-lib.sh pkgrepo_is_entrypoint) reads the activation pointer
//     `_state/generation.json` from the origin, UNCACHED, on every request, and
//     serves `_generations/<generation_id>/<path>`.
//   · Every other path — packages, by-hash indexes, checksum-named repodata,
//     `_generations/…` itself — is a shared immutable object and passes through
//     to the same path, so every URL any generation ever advertised stays
//     addressable.
//
// Caching (PR-8). A SUCCESSFUL response for an immutable URL — a
// generation-prefixed object, a package, a by-hash index, checksum-named
// repodata (IMMUTABLE_PATTERNS) — may be cached at the edge for a year: that URL
// names bytes that never change. Nothing else is: every non-2xx status is
// marked uncacheable (cacheTtlByStatus), so a transient origin error or a key
// that does not exist yet is retried on the next request, never replayed from
// the edge. Other paths (`_state/`, site pages) keep the origin's own headers.
// The pointer is fetched with `cache: "no-store"`. The response to the
// client for a STABLE entrypoint URL carries `Cache-Control: no-cache` — any
// cache must revalidate it before reuse, and revalidation comes back here and is
// resolved against the pointer again — never the origin's immutable header. So
// a response that was in flight across an activation cannot be reused from a
// shared cache after it. ETag/Last-Modified are those of the generation object,
// so a revalidation of unchanged content is a 304.
//
// What this does and does not guarantee: each request is resolved against one
// pointer read, so activation is atomic per request. An APT or DNF transaction
// spans several requests and can straddle an activation; APT then fetches
// indexes by hash (immutable), and DNF refuses a repomd.xml/repomd.xml.asc pair
// from two generations and recovers on refresh (PR-7).
//
// Configuration: env.ORIGIN — the origin base URL (e.g. the S3 website
// endpoint), no trailing slash required.

export const ENTRYPOINT_PATTERNS = [
  /(^|\/)dists\/[^/]+\/(InRelease|Release|Release\.gpg)$/,
  /(^|\/)dists\/[^/]+\/[^/]+\/binary-[^/]+\/Packages(\.gz)?$/,
  /(^|\/)repodata\/repomd\.xml(\.asc)?$/,
  /\.(sources|repo|asc)$/,
];
export const IMMUTABLE_PATTERNS = [
  /^_generations\/[0-9a-f]{64}\//,
  /(^|\/)by-hash\/SHA256\/[0-9a-f]{64}$/,
  /(^|\/)repodata\/[0-9a-f]{64}-[^/]+$/,
  /\.(deb|rpm)$/,
];
// Success cached for a year; any other status never cached (negative TTL).
export const IMMUTABLE_CF = {
  cacheEverything: true,
  cacheTtlByStatus: { "200-299": 31536000, "300-599": -1 },
};
const GEN_PREFIX = "_generations/";
const POINTER = "_state/generation.json";
const PASS_REQUEST_HEADERS = ["if-none-match", "if-modified-since", "range", "if-range"];
const DROP_RESPONSE_HEADERS = ["cache-control", "expires", "age", "set-cookie"];

export function isImmutable(path) {
  return IMMUTABLE_PATTERNS.some((re) => re.test(path));
}

export function isEntrypoint(path) {
  return !path.startsWith(GEN_PREFIX) && ENTRYPOINT_PATTERNS.some((re) => re.test(path));
}

function plain(status, text, extra = {}) {
  return new Response(text + "\n", {
    status,
    headers: { "content-type": "text/plain; charset=utf-8", "cache-control": "no-store", ...extra },
  });
}

function originRequestHeaders(request) {
  const h = new Headers();
  for (const name of PASS_REQUEST_HEADERS) {
    const v = request.headers.get(name);
    if (v !== null) h.set(name, v);
  }
  return h;
}

export default {
  async fetch(request, env) {
    if (request.method !== "GET" && request.method !== "HEAD") {
      return plain(405, "method not allowed", { allow: "GET, HEAD" });
    }
    const origin = String(env.ORIGIN || "").replace(/\/+$/, "");
    if (!origin) return plain(500, "router is not configured");
    const url = new URL(request.url);
    let path;
    try {
      path = decodeURIComponent(url.pathname).replace(/^\/+/, "");
    } catch {
      return plain(400, "bad path");
    }
    if (path.split("/").some((seg) => seg === ".." || seg === ".")) return plain(400, "bad path");

    if (!isEntrypoint(path)) {
      // A shared immutable object, a generation-addressed URL, or anything
      // else in the bucket: the same path. Only immutable URLs get edge TTLs.
      const init = { method: request.method, headers: originRequestHeaders(request) };
      if (isImmutable(path)) init.cf = IMMUTABLE_CF;
      else if (path.startsWith("_state/")) init.cache = "no-store";
      return fetch(`${origin}/${url.pathname.replace(/^\/+/, "")}`, init);
    }

    // The activation pointer: read on EVERY request, never from a cache.
    let pointer;
    try {
      const r = await fetch(`${origin}/${POINTER}`, { cache: "no-store" });
      if (r.status === 404) return plain(404, "no generation is active");
      if (!r.ok) return plain(503, "activation pointer unavailable", { "retry-after": "5" });
      pointer = await r.json();
    } catch {
      return plain(503, "activation pointer unreadable", { "retry-after": "5" });
    }
    const gid = pointer && pointer.generation_id;
    if (pointer.schema !== "blessed/package-repository-pointer/v2" || typeof gid !== "string" || !/^[0-9a-f]{64}$/.test(gid)) {
      return plain(503, "activation pointer malformed", { "retry-after": "5" });
    }

    const r = await fetch(`${origin}/${GEN_PREFIX}${gid}/${url.pathname.replace(/^\/+/, "")}`, {
      method: request.method,
      headers: originRequestHeaders(request),
      cf: IMMUTABLE_CF,
    });
    const headers = new Headers(r.headers);
    for (const name of DROP_RESPONSE_HEADERS) headers.delete(name);
    headers.set("cache-control", "no-cache");
    headers.set("x-pkgrepo-generation", gid);
    if (typeof pointer.activation_revision === "string") headers.set("x-pkgrepo-activation", pointer.activation_revision);
    if (r.status === 403 || r.status === 404) {
      // S3 website endpoints answer 403 or 404 for a missing key.
      return plain(404, "not in the active generation", {
        "x-pkgrepo-generation": gid,
        "cache-control": "no-cache",
      });
    }
    return new Response(request.method === "HEAD" ? null : r.body, { status: r.status, headers });
  },
};
