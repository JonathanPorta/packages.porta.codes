#!/usr/bin/env bash
# candidate-created-at.test.sh — the bundle's candidate_created_at must accept
# exactly what a conforming candidate may carry, and nothing looser.
#
# WHY THIS EXISTS
#
# admitted-bundle.schema.json used to require a `Z` suffix on this field while
# release-candidate.schema.json and candidate-plan.schema.json declare
# `created_at` as `format: date-time` with no pattern. A producer emitting a
# legal RFC 3339 numeric offset — which `git show %cI` does — therefore built a
# VALID candidate that could never be admitted, because bundle-verify.sh binds
# this field to the candidate's value verbatim. DocSort v0.4.4 hit it in
# production.
#
# Removing the pattern must not weaken anything, so this asserts both halves:
# offsets and Z are accepted, malformed values are still rejected by
# `format: date-time`, and the verbatim binding still catches a bundle whose
# timestamp differs from its candidate.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CAT="$(cd "$HERE/.." && pwd)"
# shellcheck source=../lib/release-lib.sh
. "$CAT/lib/release-lib.sh"
SCHEMA="$CAT/references/admitted-bundle.schema.json"

pass=0 fail=0
ok() { printf '  ✓ %s\n' "$1"; pass=$((pass + 1)); }
no() { printf '  ✗ %s\n' "$1"; fail=$((fail + 1)); }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT INT TERM HUP

# Validate a document carrying just this field and report whether the validator
# complained about THIS field. Other missing-required errors are expected and
# irrelevant here.
field_rejected() { # field_rejected <value> -> 0 if the validator flagged it
  local v="$1"
  jq -n --arg v "$v" '{identity:{candidate_created_at:$v}}' >"$T/doc.json"
  rel_schema_validate "$T/doc.json" "$SCHEMA" 2>&1 | grep -q 'candidate_created_at'
}

echo "── a conforming candidate's timestamp is admissible ──"
for good in "2026-09-15T09:10:20Z" "2026-09-15T03:10:20-06:00" "2026-09-15T15:10:20+06:00" "2026-09-15T09:10:20.123Z"; do
  if field_rejected "$good"; then
    no "REJECTED a legal RFC 3339 value: $good"
  else
    ok "accepted $good"
  fi
done

echo "── malformed values are still rejected (format: date-time, not the pattern) ──"
for bad in "not-a-timestamp" "2026-09-15" "2026-13-15T09:10:20Z" "2026-09-31T09:10:20Z" "2026-09-15T25:10:20Z" ""; do
  if field_rejected "$bad"; then
    ok "rejected ${bad:-<empty>}"
  else
    no "ACCEPTED a malformed value: ${bad:-<empty>} — removing the pattern weakened this field"
  fi
done

echo "── the verbatim binding is enforced by bundle-verify.sh itself ──"
# The pattern this change removed was mistaken for the binding. The binding is a
# DIFFERENT mechanism and must still fire, so this drives the shipped
# bundle_verify against a real admitted bundle rather than restating its jq —
# a restatement would pass even if bundle-verify.sh stopped checking.
S="$CAT/tests/fixtures/promotion/signed"
STORE="$S/trust-store.json"
if [ ! -d "$S/candidate-dir" ] || [ ! -f "$STORE" ]; then
  no "the signed promotion fixture is missing — the binding cannot be exercised"
else
  R="$T/recv"; mkdir -p "$R"
  cp "$S/surfaces.yaml" "$R/release-surfaces.yaml"
  cp "$S/receiver-downloads-index-policy.json" "$R/"
  git -C "$R" init -q 2>/dev/null
  git -C "$R" add -A >/dev/null 2>&1
  git -C "$R" -c user.email=t@t -c user.name=t commit -qm base >/dev/null 2>&1
  BASE="$(git -C "$R" rev-parse HEAD 2>/dev/null)"
  B="$T/bundle"
  if AID="$(bash "$CAT/admit-candidate-ready.sh" \
      --event "$S/event.json" --candidate-dir "$S/candidate-dir" \
      --receipt "$S/receipt.json" --attestation "$S/attestation.json" \
      --receiver-repo "$R" --receiver-base-sha "$BASE" \
      --surfaces-path release-surfaces.yaml \
      --renderer-config-path receiver-downloads-index-policy.json \
      --surface-id public-downloads --channel stable \
      --trust-store "$STORE" --signing-dir "$CAT/../signing" \
      --bundle-out "$B" 2>"$T/admit.err")"; then
    ok "the signed fixture admits, producing a real bundle"
    # shellcheck source=../lib/bundle-verify.sh
    . "$CAT/lib/bundle-verify.sh"
    if bundle_verify "$B" "$T/snap" "$CAT/../signing" "$R" "$STORE" \
         "$AID" "$BASE" public-downloads stable >"$T/bv.out" 2>&1; then
      ok "bundle_verify accepts the unmodified bundle"
    else
      no "bundle_verify rejected an unmodified bundle"; sed 's/^/        /' "$T/bv.out"
    fi
    # Mutate ONLY the bundle's copy of the timestamp, to a value that is still
    # perfectly well-formed. Only the binding to the candidate can catch this.
    mv "$B/bundle.json" "$T/b.orig" 2>/dev/null || true
    if [ -f "$T/b.orig" ]; then
      jq '.identity.candidate_created_at = "2026-01-01T00:00:00Z"' "$T/b.orig" >"$B/bundle.json"
      if bundle_verify "$B" "$T/snap" "$CAT/../signing" "$R" "$STORE" \
           "$AID" "$BASE" public-downloads stable >"$T/bv2.out" 2>&1; then
        no "bundle_verify ACCEPTED a bundle whose timestamp differs from its candidate"
      elif grep -q 'identity.candidate_created_at != candidate' "$T/bv2.out"; then
        # The REASON matters. Editing the bundle also changes the content the
        # admission id is recomputed from, so an id mismatch would reject this
        # bundle even if the binding had been deleted. Accepting any failure
        # would let that pass for the wrong reason and prove nothing.
        ok "bundle_verify rejects it BY THE BINDING, naming identity.candidate_created_at"
      else
        no "bundle_verify rejected it, but not by the candidate binding — the binding may be gone"
        sed 's/^/        /' "$T/bv2.out" | head -4
      fi
      mv "$T/b.orig" "$B/bundle.json"
    else
      no "could not locate bundle.json to mutate"
    fi
  else
    no "the signed fixture did not admit — cannot exercise the binding"
    sed 's/^/        /' "$T/admit.err" | head -4
  fi
fi

echo "── the updater pointer accepts a candidate-derived offset pub_date ──"
# pub_date is CANDIDATE-DERIVED: whatever RFC 3339 form the producer wrote into
# the candidate reaches the updater pointer, and the candidate contract permits a
# numeric offset. A conforming, correctly signed candidate carrying one validated
# cleanly and was then refused downstream — the same disagreement as
# candidate_created_at, one layer down.
#
# This exercises the schema that was changed. Driving render-updater-pointer.sh
# end to end would require REBUILDING and RE-SIGNING the fixture candidate,
# because the renderer verifies latest.json's digest against the signed manifest
# before it looks at any field — a binding worth keeping, and one that makes a
# mutated fixture the wrong instrument here.
UP="$CAT/references/updater-pointer.schema.json"
up_rejected() { # up_rejected <pub_date> -> 0 if the schema flagged pub_date
  jq -n --arg v "$1" '{version:"0.4.3", pub_date:$v, platforms:{}}' >"$T/up.json"
  rel_schema_validate "$T/up.json" "$UP" 2>&1 | grep -q 'pub_date'
}
for good in "2026-08-13T01:02:56Z" "2026-08-12T19:02:56-06:00" "2026-08-13T07:02:56+06:00"; do
  if up_rejected "$good"; then
    no "updater pointer REJECTED a legal pub_date: $good"
  else
    ok "updater pointer accepts $good"
  fi
done
for bad in "2026-13-45T99:99:99Z" "not-a-date" "2026-08-13"; do
  if up_rejected "$bad"; then
    ok "updater pointer still refuses $bad"
  else
    no "updater pointer ACCEPTED a malformed pub_date: $bad"
  fi
done

echo "── normative and shipped schema copies stay identical ──"
# Relaxing one copy and not the other is the same disagreement one level up, and
# it is how this change first went wrong.
for pair in "admitted-bundle.schema.json" "updater-pointer.schema.json"; do
  if diff -q "$CAT/references/$pair" "$CAT/../../standards/releases/references/$pair" >/dev/null 2>&1; then
    ok "$pair: normative copy matches the shipped category"
  else
    no "$pair: the two copies have drifted"
  fi
done

# The Release PUBLICATION time is a different field with a deliberate Z-only
# restriction, carried verbatim from the Release receipt. It must not move.
if grep -q 'Z\$' "$CAT/references/public-download-channel.schema.json"; then
  ok "published_at keeps its Z-only restriction (not candidate-derived)"
else
  no "published_at lost its Z-only restriction — that field is not candidate-derived"
fi

echo
if [ "$fail" -eq 0 ]; then
  echo "candidate-created-at: PASS ($pass checks)"
  exit 0
fi
echo "candidate-created-at: FAIL ($fail failed, $pass passed)"
exit 1
