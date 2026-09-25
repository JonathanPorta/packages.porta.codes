#!/usr/bin/env bash
# live-parent.sh URL — print the generation a new publication must be planned
# on: the live generation (`none` before the first publication). Read at PLAN
# time and passed to pkgrepo-publish.sh --expected-parent, so a run whose plan
# is overtaken by another activation is refused as stale instead of
# overwriting it (PR-10).
#
# While a claim stands (state `activating`), prints that claim's parent: only
# the claimant's own generation can then proceed (a re-run takes it over);
# every other generation is refused by the publisher.
#
# URL is the pointer, e.g. https://packages.porta.codes/_state/generation.json
# (or file:// in tests). Exit 0 printed · 2 unreadable.
set -uo pipefail
url="${1:?usage: live-parent.sh POINTER_URL}"
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
    echo "live-parent: HTTP $code reading $url" >&2
    exit 2
    ;;
esac
if [ ! -s "$tmp" ]; then
  # file:// with no pointer yet
  echo none
  exit 0
fi
jq -er 'if (.state // "active") == "activating" then .parent_generation_id else .generation_id end' "$tmp" 2>/dev/null || {
  echo "live-parent: the pointer at $url is not a generation pointer" >&2
  exit 2
}
