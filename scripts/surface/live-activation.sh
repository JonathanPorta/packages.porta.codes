#!/usr/bin/env bash
# live-activation.sh URL — print the activation a new publication must be
# planned against: the live pointer's `activation_revision` (`none` before the
# first publication). Read at PLAN time and passed to pkgrepo-publish.sh
# --expected-activation. The publisher then activates with ONE conditional
# write; if another activation lands first, that attempt is void and the job
# fails — the next run re-plans from here (PR-10). Nothing re-reads and retries.
#
# URL is the pointer, e.g. https://packages.porta.codes/_state/generation.json
# (served by the router as a pass-through), or file:// in tests.
# Exit 0 printed · 2 unreadable or not a v2 pointer.
set -uo pipefail
url="${1:?usage: live-activation.sh POINTER_URL}"
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
code="$(curl -sS -H 'Cache-Control: no-cache' -o "$tmp" -w '%{http_code}' "$url" 2>/dev/null || true)"
case "$code" in
  404 | 403)
    echo none
    exit 0
    ;;
  200 | 000) ;;
  *)
    echo "live-activation: HTTP $code reading $url" >&2
    exit 2
    ;;
esac
if [ ! -s "$tmp" ]; then
  # file:// with no pointer yet
  echo none
  exit 0
fi
jq -er 'select(.schema == "blessed/package-repository-pointer/v2") | .activation_revision | select(test("^[0-9a-f]{32}$"))' "$tmp" 2>/dev/null || {
  echo "live-activation: the pointer at $url is not a blessed/package-repository-pointer/v2" >&2
  exit 2
}
