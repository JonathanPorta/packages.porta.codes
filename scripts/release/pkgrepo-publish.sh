#!/usr/bin/env bash
# pkgrepo-publish.sh — publish one verified generation of a
# package-repository-surface and activate it (standards/releases/package-repositories.md
# PR-7…PR-11).
#
# NOTHING A CLIENT IS SERVED IS EVER OVERWRITTEN. Every object is written
# create-only:
#
#   · shared immutable objects (packages, by-hash indexes, checksum-named
#     repodata) at their advertised paths, so every URL any generation ever
#     advertised stays addressable (PR-9);
#   · the generation's ENTRYPOINTS (InRelease, Release, Release.gpg, the plain
#     Packages indexes, repomd.xml(.asc), client configuration, public keys)
#     under the generation's own prefix, `_generations/<generation_id>/<path>`.
#
# The one object that changes is the activation pointer, `_state/generation.json`.
# Clients reach entrypoints at their stable URLs through pkgrepo-router.js, a
# read-only router that resolves each stable entrypoint URL to the active
# generation's prefix by reading that pointer. So activation is ONE conditional
# write, and it is atomic: a request sees the old generation's entrypoints or
# the new one's, never a half-replaced set. (An APT/DNF transaction spans
# several requests and is not atomic; a DNF client that reads repomd.xml and
# its signature across an activation refuses the pair and recovers on refresh
# — PR-7.)
#
# The pointer records the generation, its inventory, and a fresh random
# ACTIVATION REVISION that is never reused, plus the revision it replaced. An
# activation plan is bound to the revision it expects to replace
# (--expected-activation). The pointer is read once; the plan is refused if the
# live revision is not the expected one; the pointer is then replaced by one
# compare-and-swap on the version read. If that fails, THIS ATTEMPT IS VOID:
# the publisher never re-reads the pointer and retries the same plan. Because
# every activation — a rollback to an older generation included — writes a new
# revision, the pointer's bytes never repeat, and a plan made against an
# earlier activation of the same generation can never match again (no ABA).
#
# Order:
#   0. verify with public keys only; take the VERIFIER's object list;
#   1. read the pointer once: this generation already active → no-op; the
#      same inventory already active → replay no-op (PR-11); a live revision
#      other than --expected-activation → stale plan, refuse (PR-10);
#   2. stat every object; any path that exists with other bytes → refuse
#      before writing anything (PR-9);
#   3. create what is missing (identical objects are skipped: resume);
#   4. activate: one compare-and-swap of the pointer;
#   5. read everything back from the store.
#
# Nothing is ever deleted. On success the new activation revision is printed
# on stdout.
#
# Exit: 0 active (activated, already active, or replay no-op)
#     · 1 refused (verification, stale plan, immutability, lost activation)
#     · 2 tooling/usage.
# shellcheck disable=SC2016  # jq programs: $-names are jq variables, not shell
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JQ="${JQ_BIN:-jq}"
POINTER_KEY="_state/generation.json"
GEN_PREFIX="_generations"
CC_IMMUTABLE="public, max-age=31536000, immutable"

die() {
  printf 'pkgrepo-publish: %s\n' "$1" >&2
  exit 2
}
refuse() {
  printf 'pkgrepo-publish: REFUSED — %s\n' "$1" >&2
  exit 1
}
say() { printf 'pkgrepo-publish: %s\n' "$1" >&2; }
usage() {
  printf 'Usage: pkgrepo-publish.sh --generation DIR --inventory INVENTORY.json --adapter ADAPTER --expected-activation REVISION|none\n' >&2
  exit 2
}
gen="" inv="" adapter="" expected=""
while [ $# -gt 0 ]; do
  case "$1" in
    --generation)
      gen="${2:-}"
      shift 2
      ;;
    --inventory)
      inv="${2:-}"
      shift 2
      ;;
    --adapter)
      adapter="${2:-}"
      shift 2
      ;;
    --expected-activation)
      expected="${2:-}"
      shift 2
      ;;
    -h | --help) usage ;;
    *) die "unknown argument: $1" ;;
  esac
done
if [ -z "$gen" ] || [ -z "$inv" ] || [ -z "$adapter" ] || [ -z "$expected" ]; then usage; fi
case "$expected" in none | [0-9a-f]*) ;; *) die "--expected-activation must be an activation revision or none" ;; esac
[ -x "$adapter" ] || [ -f "$adapter" ] || die "adapter not found: $adapter"
for t in "$JQ" od sha256sum grep; do command -v "$t" >/dev/null 2>&1 || die "required tool not found: $t"; done
A() { bash "$adapter" "$@"; }

# ── 0. verified, or nothing happens ────────────────────────────────────────
work="$(mktemp -d)" || die "cannot create a work directory"
trap 'rm -rf "$work"' EXIT
O="$work/verified.json"
bash "$HERE/pkgrepo-verify.sh" --generation "$gen" --inventory "$inv" --emit-objects "$O" >/dev/null 2>"$work/verify.err" || {
  sed 's/^/pkgrepo-publish: /' "$work/verify.err" >&2
  refuse "the generation did not verify"
}
gid="$("$JQ" -r .generation_id "$O")"
isha="$("$JQ" -r .inventory_sha256 "$O")"
surface="$("$JQ" -r .surface_id "$O")"
# Store key of each object: shared immutables at their path, entrypoints under
# the generation's prefix.
"$JQ" -r --arg pre "$GEN_PREFIX/$gid/" '.objects[]
  | [(if .class == "entrypoint" then $pre + .path else .path end), .path, .content_type, .sha256] | @tsv' "$O" >"$work/objects.tsv"

# ── 1. the pointer, read ONCE ──────────────────────────────────────────────
rc=0
etag="$(A get-pointer "$POINTER_KEY" "$work/pointer.json")" || rc=$?
case "$rc" in
  0)
    live_gid="$("$JQ" -r '.generation_id // empty' "$work/pointer.json" 2>/dev/null)" || die "the live pointer is not JSON"
    live_isha="$("$JQ" -r '.inventory_sha256 // empty' "$work/pointer.json")"
    live_rev="$("$JQ" -r '.activation_revision // empty' "$work/pointer.json")"
    if [ -z "$live_gid" ] || [ -z "$live_rev" ]; then die "the live pointer is not a blessed/package-repository-pointer/v2"; fi
    ;;
  3) etag="none" live_gid="none" live_isha="none" live_rev="none" ;;
  *) die "the adapter could not read the live pointer" ;;
esac
if [ "$live_gid" = "$gid" ]; then
  [ "$live_isha" = "$isha" ] || refuse "the live pointer names generation ${gid:0:12} with another inventory"
  say "generation ${gid:0:12} is already active (activation ${live_rev:0:12}); nothing to do"
  exit 0
fi
if [ "$live_isha" = "$isha" ]; then
  say "replay: the live generation ${live_gid:0:12} already serves inventory ${isha:0:12}; nothing published"
  exit 0
fi
[ "$live_rev" = "$expected" ] ||
  refuse "stale plan: the live activation is ${live_rev:0:12} (generation ${live_gid:0:12}), but this plan expects ${expected:0:12}; re-plan against the live inventory"

# ── 2. every object: find every conflict before writing anything ───────────
: >"$work/missing"
conflicts=0
while IFS=$'\t' read -r key _ _ h; do
  rc=0
  have="$(A stat "$key")" || rc=$?
  case "$rc" in
    0) [ "$have" = "$h" ] || {
      say "object $key already exists with different bytes ($have ≠ $h)"
      conflicts=$((conflicts + 1))
    } ;;
    3) printf '%s\n' "$key" >>"$work/missing" ;;
    *) die "the adapter could not stat $key" ;;
  esac
done <"$work/objects.tsv"
[ "$conflicts" -eq 0 ] || refuse "$conflicts published object(s) would change; published bytes are never replaced"

# ── 3. create what is missing ──────────────────────────────────────────────
up=0
while IFS=$'\t' read -r key path t h; do
  grep -qxF -- "$key" "$work/missing" || continue
  rc=0
  A put "$key" "$gen/$path" "$t" "$CC_IMMUTABLE" "$h" create-only || rc=$?
  case "$rc" in
    0) up=$((up + 1)) ;;
    4)
      # Created concurrently since the stat: accepted only if it is these bytes.
      [ "$(A stat "$key" 2>/dev/null)" = "$h" ] ||
        refuse "object $key was created concurrently with different bytes; published bytes are never replaced"
      ;;
    *) die "the adapter failed to upload $key (nothing was activated; re-run to resume)" ;;
  esac
done <"$work/objects.tsv"
rec="_state/generations/$gid.json"
rsha="$(sha256sum "$O" | cut -d' ' -f1)"
rc=0
A put "$rec" "$O" "application/json" "$CC_IMMUTABLE" "$rsha" create-only || rc=$?
case "$rc" in
  0) ;;
  4) [ "$(A stat "$rec" 2>/dev/null)" = "$rsha" ] || refuse "the generation record $rec exists with other content" ;;
  *) die "the adapter failed to upload $rec (nothing was activated; re-run to resume)" ;;
esac

# ── 4. activate: ONE compare-and-swap, never retried ───────────────────────
rev="$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
[ "${#rev}" = 32 ] || die "cannot draw an activation revision"
"$JQ" -n --arg s "$surface" --arg g "$gid" --arg i "$isha" --arg r "$rev" --arg pr "$live_rev" --arg pg "$live_gid" --arg rs "$rsha" \
  '{schema: "blessed/package-repository-pointer/v2", surface_id: $s, generation_id: $g, inventory_sha256: $i,
    generation_record_sha256: $rs, activation_revision: $r,
    predecessor: (if $pr == "none" then null else {activation_revision: $pr, generation_id: $pg} end)}' >"$work/new-pointer.json"
rc=0
A put-pointer "$POINTER_KEY" "$work/new-pointer.json" "$etag" >/dev/null || rc=$?
case "$rc" in
  0) ;;
  4) refuse "activation lost the compare-and-swap: the pointer changed after this plan read it; this attempt is void — re-plan, do not retry it" ;;
  *) die "the adapter failed to write the activation pointer; whether it landed is unknown — read the pointer before planning again" ;;
esac

# ── 5. read back ───────────────────────────────────────────────────────────
bad=0
while IFS=$'\t' read -r key _ _ h; do
  [ "$(A stat "$key" 2>/dev/null)" = "$h" ] || {
    say "read-back: $key is not the published bytes"
    bad=$((bad + 1))
  }
done <"$work/objects.tsv"
A get-pointer "$POINTER_KEY" "$work/readback.json" >/dev/null || bad=$((bad + 1))
[ "$("$JQ" -r .activation_revision "$work/readback.json" 2>/dev/null)" = "$rev" ] || {
  say "read-back: the pointer is not this activation"
  bad=$((bad + 1))
}
[ "$bad" -eq 0 ] || refuse "read-back found $bad discrepancy(ies) after activation"
say "activated generation ${gid:0:12} as activation $rev (replacing ${live_rev:0:12}); created $up object(s)"
printf '%s\n' "$rev"
