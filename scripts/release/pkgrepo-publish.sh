#!/usr/bin/env bash
# pkgrepo-publish.sh — publish and activate one verified generation of a
# package-repository-surface (standards/releases/package-repositories.md PR-7…PR-11).
#
# Storage is reached ONLY through an adapter (adapters/s3-object-adapter.sh, or a
# fake in tests) with four verbs: stat, put, get-pointer, put-pointer. The
# surface's live generation is a pointer object written only by
# compare-and-swap, so two writers can never both believe they activated.
#
# CLAIM FIRST, AND FENCED. The live pointer names a generation, a state and a
# claim nonce. A publisher may write served entrypoints ONLY after it has moved
# the pointer, by compare-and-swap, to {its generation, activating, a fresh
# nonce}. So of two racing publishers exactly one can claim; the other refuses
# before it has touched a single served byte. Resuming an interrupted
# activation of the same generation TAKES OVER the claim with a new nonce, by
# the same compare-and-swap. And because a delayed process can still be
# holding a write it decided on long ago, every entrypoint write is itself
# conditional: on the object's version observed right after this publisher's
# claim. A superseded publisher — its claim taken over, or its generation
# already replaced by a successor — finds those versions changed and stops.
# Immutable objects are create-only and content-addressed, so a loser's
# uploads never change what anyone serves.
#
# Order, and why:
#   0. verify the generation with public keys only (pkgrepo-verify.sh), and take
#      the object list the VERIFIER derived — never the unsigned manifest;
#   1. read the live pointer.
#        · this generation, active       → nothing to do (exit 0);
#        · this generation, activating   → an interrupted claim on the same
#                                           inventory and parent: take it over;
#        · another generation activating → refuse: someone else holds the claim;
#        · the same INVENTORY, active    → a replay: nothing republished (PR-11);
#        · not the planned parent        → a stale plan: refuse and re-plan (PR-10);
#   2. stat EVERY immutable object before writing anything. One that exists
#      with different bytes is a hard failure (PR-9) — found before any write;
#   3. upload missing immutable objects, create-only (identical ones: resume);
#   4. CLAIM (or take over): CAS the pointer to {generation, activating, nonce};
#      losing means another writer moved it — refuse, having written nothing
#      served;
#   5. observe every entrypoint's version, then replace each ONLY IF it is
#      still that version, APT InRelease last (PR-7). A changed version whose
#      bytes are already ours was written by the publisher we took over from;
#      any other change means we were superseded — refuse;
#   6. CAS the pointer from our claim to {generation, active};
#   7. read everything back from the store (PR-15's store half).
#
# Nothing is ever deleted: previous generations' objects stay referenced for
# the cache window and beyond (PR-9, PR-13).
#
# Exit: 0 active (published, resumed, already active, or replay no-op)
#     · 1 refused (verification, stale plan, immutability, concurrent writer)
#     · 2 tooling/usage.
# shellcheck disable=SC2016  # jq programs: $-names are jq variables, not shell
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JQ="${JQ_BIN:-jq}"
POINTER_KEY="_state/generation.json"
CC_IMMUTABLE="public, max-age=31536000, immutable"
CC_MUTABLE="public, max-age=60, must-revalidate"

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
  printf 'Usage: pkgrepo-publish.sh --generation DIR --inventory INVENTORY.json --adapter ADAPTER --expected-parent GENERATION_ID|none\n' >&2
  exit 2
}
gen="" inv="" adapter="" parent=""
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
    --expected-parent)
      parent="${2:-}"
      shift 2
      ;;
    -h | --help) usage ;;
    *) die "unknown argument: $1" ;;
  esac
done
if [ -z "$gen" ] || [ -z "$inv" ] || [ -z "$adapter" ] || [ -z "$parent" ]; then usage; fi
[ -x "$adapter" ] || [ -f "$adapter" ] || die "adapter not found: $adapter"
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

# ── 1. the live pointer ────────────────────────────────────────────────────
read_pointer() { # sets LIVE_ETAG, LIVE_GID, LIVE_ISHA, LIVE_STATE
  local rc=0
  LIVE_ETAG="$(A get-pointer "$POINTER_KEY" "$work/pointer.json")" || rc=$?
  case "$rc" in
    0)
      LIVE_GID="$("$JQ" -r '.generation_id // "none"' "$work/pointer.json")" || die "the live pointer is not JSON"
      LIVE_ISHA="$("$JQ" -r '.inventory_sha256 // "none"' "$work/pointer.json")"
      LIVE_STATE="$("$JQ" -r '.state // "active"' "$work/pointer.json")"
      ;;
    3) LIVE_ETAG="none" LIVE_GID="none" LIVE_ISHA="none" LIVE_STATE="active" ;;
    *) die "the adapter could not read the live pointer" ;;
  esac
}
claim_id="$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
[ "${#claim_id}" = 32 ] || die "cannot draw a claim nonce"
pointer() { # $1 state → $work/pointer-$1.json
  "$JQ" -n --arg s "$surface" --arg g "$gid" --arg i "$isha" --arg p "$parent" --arg st "$1" --arg c "$claim_id" \
    '{schema: "blessed/package-repository-pointer/v1", surface_id: $s, generation_id: $g, inventory_sha256: $i,
      parent_generation_id: $p, state: $st, claim_id: $c}' >"$work/pointer-$1.json"
}
read_pointer
resume=0
if [ "$LIVE_GID" = "$gid" ] && [ "$LIVE_ISHA" != "$isha" ]; then
  refuse "the live pointer names generation ${gid:0:12} with another inventory; the pointer and this generation disagree"
elif [ "$LIVE_GID" = "$gid" ] && [ "$LIVE_STATE" = active ]; then
  say "generation ${gid:0:12} is already active; nothing to do"
  exit 0
elif [ "$LIVE_GID" = "$gid" ] && [ "$LIVE_STATE" = activating ]; then
  [ "$("$JQ" -r '.parent_generation_id // ""' "$work/pointer.json")" = "$parent" ] ||
    refuse "the interrupted activation of ${gid:0:12} was planned on another parent; resume it with that parent"
  say "taking over the interrupted activation of this generation"
  resume=1
elif [ "$LIVE_STATE" != active ]; then
  refuse "generation ${LIVE_GID:0:12} holds the activation claim ($LIVE_STATE); only its own publisher may finish it"
elif [ "$LIVE_ISHA" = "$isha" ]; then
  say "replay: the live generation ${LIVE_GID:0:12} already serves inventory ${isha:0:12}; nothing republished"
  exit 0
elif [ "$LIVE_GID" != "$parent" ]; then
  refuse "stale plan: the live generation is ${LIVE_GID:0:12}, but this generation was planned on ${parent:0:12}; re-plan against the live inventory"
fi

# ── 2. immutable objects: find every conflict before writing anything ──────
: >"$work/missing"
conflicts=0
while IFS=$'\t' read -r p h; do
  rc=0
  have="$(A stat "$p")" || rc=$?
  case "$rc" in
    0) [ "$have" = "$h" ] || {
      say "immutable object $p already exists with different bytes ($have ≠ $h)"
      conflicts=$((conflicts + 1))
    } ;;
    3) printf '%s\n' "$p" >>"$work/missing" ;;
    *) die "the adapter could not stat $p" ;;
  esac
done < <("$JQ" -r '.objects[] | select(.class == "immutable") | [.path, .sha256] | @tsv' "$O")
[ "$conflicts" -eq 0 ] || refuse "$conflicts immutable object(s) would change; published bytes are never replaced"

# ── 3. upload what is missing, create-only ─────────────────────────────────
up=0
while IFS=$'\t' read -r p t h; do
  # If another writer created the same path since the stat above, it is
  # accepted only if it holds exactly these bytes.
  rc=0
  A put "$p" "$gen/$p" "$t" "$CC_IMMUTABLE" "$h" create-only || rc=$?
  case "$rc" in
    0) up=$((up + 1)) ;;
    4)
      [ "$(A stat "$p" 2>/dev/null)" = "$h" ] ||
        refuse "immutable object $p was created concurrently with different bytes; published bytes are never replaced"
      ;;
    *) die "the adapter failed to upload $p" ;;
  esac
done < <("$JQ" -r --rawfile m "$work/missing" '($m | split("\n") | map(select(. != ""))) as $w
  | .objects[] | select(.path as $p | $w | index($p)) | [.path, .content_type, .sha256] | @tsv' "$O")
# The verified object list is the immutable record of what was published.
rec="_state/generations/$gid.json"
rc=0
A stat "$rec" >/dev/null || rc=$?
case "$rc" in
  0) ;;
  3)
    rc=0
    A put "$rec" "$O" "application/json" "$CC_IMMUTABLE" "$(sha256sum "$O" | cut -d' ' -f1)" create-only || rc=$?
    [ "$rc" = 0 ] || [ "$rc" = 4 ] || die "the adapter failed to upload $rec"
    ;;
  *) die "the adapter could not stat $rec" ;;
esac

# ── 4. claim the activation (or take over an interrupted one) ──────────────
pointer activating
rc=0
LIVE_ETAG="$(A put-pointer "$POINTER_KEY" "$work/pointer-activating.json" "$LIVE_ETAG")" || rc=$?
case "$rc" in
  0) ;;
  4) refuse "activation lost the compare-and-swap: another writer moved the live generation; no entrypoint was written" ;;
  *) die "the adapter failed to write the activation claim" ;;
esac
[ -n "$LIVE_ETAG" ] || die "the adapter did not report the claim's new version"
[ "$resume" = 0 ] || say "claim taken over (nonce ${claim_id:0:8})"

# ── 5. entrypoints — fenced by the versions observed after our claim ───────
"$JQ" -r '.objects[] | select(.class == "mutable")
  | [.path, .content_type, .sha256, (if (.path | endswith("/InRelease")) then 2 elif (.path | endswith("/Release") or endswith("/Release.gpg")) then 1 else 0 end)]
  | @tsv' "$O" | sort -t$'\t' -k4,4n -k1,1 | cut -f1-3 >"$work/entrypoints"
: >"$work/observed"
while IFS=$'\t' read -r p _ _; do
  rc=0
  e="$(A etag "$p")" || rc=$?
  case "$rc" in
    0) [ -n "$e" ] || die "the adapter reported no version for $p" ;;
    3) e=absent ;;
    *) die "the adapter could not read the version of $p" ;;
  esac
  printf '%s\n' "$e" >>"$work/observed"
done <"$work/entrypoints"
while IFS=$'\t' read -r p t h e; do
  if [ "$e" = absent ]; then cond=create-only; else cond="if-match:$e"; fi
  rc=0
  A put "$p" "$gen/$p" "$t" "$CC_MUTABLE" "$h" "$cond" || rc=$?
  case "$rc" in
    0) ;;
    4)
      [ "$(A stat "$p" 2>/dev/null)" = "$h" ] ||
        refuse "entrypoint $p changed after this publisher's claim: it was superseded, and writes nothing more"
      ;;
    *) die "the adapter failed to upload $p (the claim stands; re-run to take it over)" ;;
  esac
done < <(paste "$work/entrypoints" "$work/observed")

# ── 6. confirm: from our claim to active ───────────────────────────────────
pointer active
rc=0
A put-pointer "$POINTER_KEY" "$work/pointer-active.json" "$LIVE_ETAG" >/dev/null || rc=$?
case "$rc" in
  0) ;;
  4) refuse "the activation claim was taken over or moved by another writer before it was confirmed" ;;
  *) die "the adapter failed to confirm the activation (the claim stands; re-run to take it over)" ;;
esac

# ── 7. read back ───────────────────────────────────────────────────────────
bad=0
while IFS=$'\t' read -r p h; do
  [ "$(A stat "$p" 2>/dev/null)" = "$h" ] || {
    say "read-back: $p is not the published bytes"
    bad=$((bad + 1))
  }
done < <("$JQ" -r '.objects[] | [.path, .sha256] | @tsv' "$O")
read_pointer
{ [ "$LIVE_GID" = "$gid" ] && [ "$LIVE_STATE" = active ]; } || bad=$((bad + 1))
[ "$bad" -eq 0 ] || refuse "read-back found $bad discrepancy(ies) after activation"
say "activated generation ${gid:0:12} (parent ${parent:0:12}); uploaded $up new immutable object(s)"
