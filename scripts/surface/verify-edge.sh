#!/usr/bin/env bash
# verify-edge.sh — prove the live edge is what the approved plan says it is.
#
#   1. The Worker route packages.porta.codes/* runs packages-porta-codes-router
#      and FAILS CLOSED when the Workers Free daily allowance is exhausted:
#      request_limit_fail_open must be present and false. (The Cloudflare
#      Terraform provider cannot set this field; false is the API default. It is
#      asserted here from the live API, never assumed.)
#   2. A stable entrypoint URL is answered by the router: it carries
#      x-pkgrepo-generation and Cache-Control: no-cache.
#   3. The activation pointer is readable and is a v2 pointer.
#
# Needs CLOUDFLARE_API_TOKEN with Zone → Workers Routes: Read on porta.codes
# (read-only; the value is read from the environment, never an argument), curl
# and jq. Exit 0 verified · 1 not as approved · 2 usage/tooling.
set -uo pipefail
HOST="${PPC_HOST:-packages.porta.codes}"
ZONE="${PPC_ZONE:-porta.codes}"
SCRIPT="${PPC_ROUTER_SCRIPT:-packages-porta-codes-router}"
ENTRYPOINT="${PPC_ENTRYPOINT:-keys/repository.asc}"
die() {
  printf 'verify-edge: %s\n' "$1" >&2
  exit 2
}
fail() {
  printf 'verify-edge: NOT AS APPROVED — %s\n' "$1" >&2
  exit 1
}
for t in curl jq; do command -v "$t" >/dev/null 2>&1 || die "required tool not found: $t"; done
[ -n "${CLOUDFLARE_API_TOKEN:-}" ] || die "CLOUDFLARE_API_TOKEN (Workers Routes: Read) is not set"

cf() { # GET an API path; the token goes in a header read from a file descriptor, not argv
  curl -fsS -H @<(printf 'Authorization: Bearer %s\n' "$CLOUDFLARE_API_TOKEN") "https://api.cloudflare.com/client/v4/$1"
}

zone_id="$(cf "zones?name=$ZONE" | jq -r '.result[0].id // empty')" || die "cannot read zone $ZONE"
[ -n "$zone_id" ] || die "zone $ZONE not found"
route="$(cf "zones/$zone_id/workers/routes" | jq -c --arg p "$HOST/*" '[.result[] | select(.pattern == $p)]')" ||
  die "cannot read the zone's Worker routes"
[ "$(jq length <<<"$route")" = 1 ] || fail "expected exactly one route $HOST/*, found $(jq length <<<"$route")"
[ "$(jq -r '.[0].script' <<<"$route")" = "$SCRIPT" ] || fail "route $HOST/* runs $(jq -r '.[0].script' <<<"$route"), not $SCRIPT"
[ "$(jq -r '.[0] | has("request_limit_fail_open")' <<<"$route")" = true ] ||
  fail "the route does not report request_limit_fail_open; fail-closed cannot be proven"
[ "$(jq -r '.[0].request_limit_fail_open' <<<"$route")" = false ] ||
  fail "route $HOST/* FAILS OPEN when the allowance is exhausted (request_limit_fail_open=true)"
printf 'verify-edge: route %s/* → %s, fails closed (request_limit_fail_open=false)\n' "$HOST" "$SCRIPT"

headers="$(curl -fsS -o /dev/null -D - "https://$HOST/$ENTRYPOINT" | tr -d '\r')" || fail "https://$HOST/$ENTRYPOINT is not served"
gen="$(sed -n 's/^x-pkgrepo-generation: //Ip' <<<"$headers" | head -1)"
[ -n "$gen" ] || fail "https://$HOST/$ENTRYPOINT was not answered by the router (no x-pkgrepo-generation)"
[ "$(sed -n 's/^cache-control: //Ip' <<<"$headers" | head -1)" = no-cache ] || fail "https://$HOST/$ENTRYPOINT is not served no-cache"
printf 'verify-edge: %s served by the router from generation %s (no-cache)\n' "$ENTRYPOINT" "${gen:0:12}"

pointer="$(curl -fsS -H 'Cache-Control: no-cache' "https://$HOST/_state/generation.json")" || fail "the activation pointer is not readable"
jq -e --arg g "$gen" '.schema == "blessed/package-repository-pointer/v2" and .generation_id == $g' <<<"$pointer" >/dev/null ||
  fail "the pointer is not a v2 pointer naming generation ${gen:0:12}"
printf 'verify-edge: OK — activation %s\n' "$(jq -r .activation_revision <<<"$pointer")"
