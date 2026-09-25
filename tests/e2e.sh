#!/usr/bin/env bash
# e2e.sh — the surface end to end, offline, with ephemeral keys and demo
# packages: the tooling flow (tests/lib/tooling-flow.sh, in the pinned tools
# image), then REAL clients — Debian 13 apt and Fedora 44 dnf5 — installing and
# upgrading through the published store.
#
# The clients reach it as https://packages.porta.codes/ exactly: an nginx
# container answers to that name on a private Docker network with a throwaway
# certificate only the client containers trust, and proxies to the REAL router
# (pkgrepo-router.js) in front of the store the publisher wrote. So every
# entrypoint is resolved through the activation pointer, as on the live
# surface, and the published .sources and .repo are tested byte for byte — no
# URL rewriting anywhere.
#
# Evidence level: whatever this host's architecture is (native). On CI that is
# x86_64; on an arm64 workstation, arm64 — the demo packages are
# architecture-independent and the demo repositories serve both.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
command -v docker >/dev/null 2>&1 || {
  echo "e2e: docker is required"
  exit 1
}
# 22 tooling + 8 client + 2 rows (APT and DNF at this host's architecture) + 1 row refusal
EXPECTED_CONTROLS=33
W="$(mktemp -d)"
NET="ppc-e2e-$$"
cleanup() {
  docker rm -f "ppc-web-$$" "ppc-router-$$" "ppc-deb-$$" "ppc-fed-$$" >/dev/null 2>&1
  docker network rm "$NET" >/dev/null 2>&1
  rm -rf "$W"
}
trap cleanup EXIT
pass=0 failed=0
ok() {
  echo "  ✓ $1"
  pass=$((pass + 1))
}
bad() {
  echo "  ✗ $1"
  failed=$((failed + 1))
}
note() { printf '%s\n' "$1" | sed 's/^/      /' | tail -6; }

# ── tooling phase ──────────────────────────────────────────────────────────
docker build -q -t ppc-tools "$ROOT/tools" >/dev/null || {
  echo "e2e: cannot build the tools image"
  exit 1
}
printf 'FROM ppc-tools\nRUN dnf -y install rpm-build rpm-sign >/dev/null && dnf clean all\n' | docker build -q -t ppc-tools-test - >/dev/null || exit 1
docker run --rm -e HOST_UID="$(id -u)" -e HOST_GID="$(id -g)" -v "$ROOT":/repo:ro -v "$W":/out ppc-tools-test bash -c \
  'cp -a /repo /tmp/repo && bash /tmp/repo/tests/lib/tooling-flow.sh /out/work; rc=$?; chown -R "$HOST_UID:$HOST_GID" /out; exit $rc' | tee "$W/tooling.log"
tp="$(grep -c '^  ✓' "$W/tooling.log")"
tf="$(grep -c '^  ✗' "$W/tooling.log")"
pass=$((pass + tp))
failed=$((failed + tf))
[ -f "$W/work/fingerprints" ] || {
  echo "e2e: the tooling phase produced nothing to serve"
  exit 1
}
# shellcheck disable=SC1091 # written by the tooling phase
. "$W/work/fingerprints"

# ── client phase ───────────────────────────────────────────────────────────
echo "── real clients through https://packages.porta.codes/ ──"
cat >"$W/nginx.conf" <<'NGINX'
server {
  listen 443 ssl;
  server_name packages.porta.codes;
  ssl_certificate /tls/tls-cert.pem;
  ssl_certificate_key /tls/tls-key.pem;
  location / {
    proxy_pass http://ppc-router:8080;
    proxy_http_version 1.1;
  }
}
NGINX
docker network create "$NET" >/dev/null
# Each state is a snapshot of the whole STORE the publisher wrote, served
# through the REAL router (scripts/release/pkgrepo-router.js in the blessed Node
# harness) behind an HTTPS front — as the live surface serves it. A fresh
# router and front per state: mutating one bind mount in place can serve a
# stale view on some Docker hosts.
serve() {
  docker rm -f "ppc-web-$$" "ppc-router-$$" >/dev/null 2>&1
  docker run -d --name "ppc-router-$$" --network "$NET" --network-alias ppc-router \
    -v "$W/work/$1":/store:ro -v "$ROOT":/repo:ro -e ROUTER=/repo/scripts/release/pkgrepo-router.js \
    -e ROUTER_BIND=0.0.0.0 -e ROUTER_PORT=8080 \
    node:22-alpine@sha256:0a7108bf6c7bf5de370ffb1a3ed6be93d405b43ff159f681a8d18c0e2bc2e402 \
    node /repo/tests/fixtures/router-harness.mjs /store /tmp/port >/dev/null
  docker run -d --name "ppc-web-$$" --network "$NET" --network-alias packages.porta.codes \
    -v "$W/work":/tls:ro -v "$W/nginx.conf":/etc/nginx/conf.d/default.conf:ro \
    nginx:1.27-alpine@sha256:65645c7bb6a0661892a8b03b89d0743208a18dd2f3f17a54ef4b76fb8e2f2a10 >/dev/null
  for _ in $(seq 1 20); do
    if docker exec "ppc-web-$$" nc -z 127.0.0.1 443 2>/dev/null && docker exec "ppc-router-$$" test -s /tmp/port 2>/dev/null; then return 0; fi
    sleep 1
  done
  echo "e2e: the router or its front did not come up for $1"
  docker logs "ppc-router-$$" 2>&1 | tail -3
  exit 1
}
B=https://packages.porta.codes
CC=/repo/scripts/release/pkgrepo-client-check.sh
# shellcheck disable=SC2016 # expanded inside the client container
CHECK='/usr/bin/demo-cli | grep -qx "v$(cat /tmp/want)"'
DEB_SETUP='apt-get update -qq >/dev/null && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq curl gnupg ca-certificates >/dev/null && cp /tls/tls-cert.pem /usr/local/share/ca-certificates/ppc.crt && update-ca-certificates >/dev/null 2>&1'
FED_SETUP='dnf -q -y install gnupg2 curl >/dev/null 2>&1; cp /tls/tls-cert.pem /etc/pki/ca-trust/source/anchors/ppc.pem && update-ca-trust'
MOUNTS=(-v "$ROOT":/repo:ro -v "$W/work":/tls:ro)
serve served-g1
docker run -d --name "ppc-deb-$$" --network "$NET" "${MOUNTS[@]}" debian:13 sleep 3600 >/dev/null
docker run -d --name "ppc-fed-$$" --network "$NET" "${MOUNTS[@]}" fedora:44 sleep 3600 >/dev/null
docker exec "ppc-deb-$$" bash -c "$DEB_SETUP" || bad "debian client setup"
docker exec "ppc-fed-$$" bash -c "$FED_SETUP" || bad "fedora client setup"

docker exec "ppc-deb-$$" sh -c 'echo 1.0.0 > /tmp/want'
if out="$(docker exec "ppc-deb-$$" bash $CC --format apt --config-url $B/apt/demo/demo.sources --key "$B/keys/repository.asc=$REPO" \
  --install demo-cli=1.0.0-1 --check "$CHECK" 2>&1)"; then
  ok "Debian 13 apt installs the baseline from the published .sources, signatures on, and it runs"
else
  bad "apt baseline install failed"
  note "$out"
fi
docker exec "ppc-fed-$$" sh -c 'echo 1.0.0 > /tmp/want'
if out="$(docker exec "ppc-fed-$$" bash $CC --format dnf --config-url $B/rpm/demo/demo.repo --key "$B/keys/repository.asc=$REPO" \
  --key "$B/keys/demo-rpm.asc=$PRODUCER" --install demo-cli=1.0.0-1 --check "$CHECK" 2>&1)"; then
  ok "Fedora 44 dnf5 installs the baseline from the published .repo (gpgcheck + repo_gpgcheck), and it runs"
else
  bad "dnf baseline install failed"
  note "$out"
fi
serve served-g2
docker exec "ppc-deb-$$" sh -c 'echo 1.1.0 > /tmp/want'
if out="$(docker exec "ppc-deb-$$" bash -c "apt-get update -qq >/dev/null 2>&1 && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --only-upgrade demo-cli >/dev/null 2>&1 && dpkg-query -W -f='\${Version}' demo-cli && echo && $CHECK" 2>&1)" &&
  printf '%s' "$out" | grep -q '^1.1.0-1'; then
  ok "…apt upgrades the same system to generation 2's version"
else
  bad "apt upgrade failed"
  note "$out"
fi
G2="$(jq -r .generation_id "$W/work/g2/.generation.json")"
h="$(docker exec "ppc-deb-$$" curl -fsS -o /dev/null -D - "$B/apt/demo/dists/stable/InRelease" | tr -d '\r')"
if grep -qix "x-pkgrepo-generation: $G2" <<<"$h" && grep -qix 'cache-control: no-cache' <<<"$h"; then
  ok "…the stable InRelease URL is routed to generation 2 and served no-cache"
else
  bad "the stable entrypoint is not routed to generation 2, or is cacheable"
  note "$h"
fi
docker exec "ppc-fed-$$" sh -c 'echo 1.1.0 > /tmp/want'
rid="$(docker exec "ppc-fed-$$" sh -c "sed -n 's/^\[\(.*\)\]\$/\1/p' /etc/yum.repos.d/pkgrepo-check.repo | head -1")"
if out="$(docker exec "ppc-fed-$$" bash -c "dnf -y --disablerepo='*' --enablerepo=$rid --refresh upgrade demo-cli >/dev/null 2>&1 && rpm -q --qf '%{VERSION}-%{RELEASE}\n' demo-cli && $CHECK" 2>&1)" &&
  printf '%s' "$out" | grep -q '^1.1.0-1'; then
  ok "…dnf upgrades the same system to generation 2's version"
else
  bad "dnf upgrade failed"
  note "$out"
fi
if docker exec "ppc-deb-$$" bash -c 'DEBIAN_FRONTEND=noninteractive apt-get remove -y -qq demo-cli >/dev/null 2>&1 && [ ! -e /usr/bin/demo-cli ]' &&
  docker exec "ppc-fed-$$" bash -c 'dnf -y -q remove demo-cli >/dev/null 2>&1 && [ ! -e /usr/bin/demo-cli ]'; then
  ok "…and both remove cleanly"
else
  bad "removal failed"
fi
serve served-bad
if out="$(docker run --rm --network "$NET" "${MOUNTS[@]}" debian:13 bash -c "$DEB_SETUP && bash $CC --format apt --config-url $B/apt/demo/demo.sources --key $B/keys/repository.asc=$REPO --expect-refusal" 2>&1)"; then
  ok "apt refuses an InRelease signed by a key other than the repository key"
else
  bad "apt did not refuse the stranger-signed InRelease"
  note "$out"
fi
serve served-g2
if out="$(docker run --rm --network "$NET" "${MOUNTS[@]}" debian:13 bash -c "$DEB_SETUP && bash $CC --format apt --config-url $B/apt/demo/demo.sources --key $B/keys/repository.asc=$STRANGER --install demo-cli=1.1.0-1" 2>&1)"; then
  bad "a repository key with an unexpected fingerprint was trusted"
elif printf '%s' "$out" | grep -q 'refusing to trust it'; then
  ok "a repository key that is not the expected fingerprint is never trusted"
else
  bad "…refused for the wrong reason"
  note "$out"
fi

echo "── every row of the served generation (scripts/surface/client-rows.sh, as publish.yml runs it) ──"
docker rm -f "ppc-web-$$" "ppc-router-$$" >/dev/null 2>&1
bash "$ROOT/scripts/surface/client-rows.sh" --inventory "$W/work/inv2.json" --policy "$W/work/root/surface/admission.json" \
  --serve-store "$W/work/served-g2" --tls-dir "$W/work" | tee "$W/rows.log"
rp="$(grep -c '^  ✓' "$W/rows.log")"
rf="$(grep -c '^  ✗' "$W/rows.log")"
pass=$((pass + rp))
failed=$((failed + rf))
if out="$(bash "$ROOT/scripts/surface/client-rows.sh" --inventory "$W/work/inv1.json" --policy "$W/work/root/surface/admission.json" \
  --serve-store "$W/work/served-bad" --tls-dir "$W/work" 2>&1)"; then
  bad "the row runner passed a generation whose InRelease is signed by a stranger"
elif printf '%s' "$out" | grep -q '✗ demo-apt' && printf '%s' "$out" | grep -q '✓ demo-rpm'; then
  ok "…and fails exactly the row whose served metadata is not signed by the repository key"
else
  bad "…the row runner failed for another reason"
  note "$out"
fi

echo "------------------------------------------------------------"
total=$((pass + failed))
if [ "$failed" -ne 0 ]; then
  echo "e2e: FAIL ($failed failing of $total)"
  exit 1
fi
if [ "$total" -ne "$EXPECTED_CONTROLS" ]; then
  echo "e2e: FAIL (ran $total, expected $EXPECTED_CONTROLS)"
  exit 1
fi
echo "e2e: PASS ($total controls)"
