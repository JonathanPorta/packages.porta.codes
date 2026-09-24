#!/usr/bin/env bash
# shellcheck disable=SC2016  # jq programs: $-names are jq variables, not shell
# bundle-verify.sh — re-run ADMISSION at every actionable stage.
#
# An earlier version of this file re-checked a subset of admission and verified
# the candidate against a trust store carried inside the bundle. That made the
# trust root caller-controlled: anyone supplying candidate, signature and store
# together passed. Signature verification that reads its own root of trust from
# the artifact under test proves nothing.
#
# So: the trust store arrives INDEPENDENTLY, the closed input set is snapshotted
# BEFORE anything is validated, the full admission semantics run again over the
# snapshot via the shared library, admission_id is recomputed and compared with
# an expectation held outside the bundle, and every redundant identity field is
# re-derived from its authoritative input rather than read.
#
# Usage:
#   bundle_verify BUNDLE SNAP SIGNING_DIR REPO TRUST_STORE \
#                 EXPECT_ADMISSION_ID EXPECT_BASE_SHA EXPECT_SURFACE_ID EXPECT_CHANNEL
set -uo pipefail

bv_no() {
  printf 'verify: REFUSE %s\n' "$1" >&2
  return 1
}
bv_die() {
  printf 'verify: %s\n' "$1" >&2
  return 2
}

bundle_verify() {
  local bdir="$1" snap="$2" signing="$3" repo="$4" store="$5"
  local exp_id="$6" exp_base="$7" exp_surface="$8" exp_channel="$9"
  local jq="${JQ_BIN:-jq}" here rc
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

  for v in "$bdir" "$snap" "$signing" "$repo" "$store" "$exp_id" "$exp_base" "$exp_surface" "$exp_channel"; do
    [ -n "$v" ] || {
      bv_die "every expected value must be supplied independently of the bundle"
      return 2
    }
  done
  [ -d "$bdir" ] || {
    bv_die "bundle directory not found: $bdir"
    return 2
  }
  [ -f "$store" ] || {
    bv_die "trust store not found: $store"
    return 2
  }
  command -v "$jq" >/dev/null 2>&1 || {
    bv_die "jq not found"
    return 2
  }
  # shellcheck source=scripts/release/lib/admission-lib.sh
  . "$here/lib/admission-lib.sh" || {
    bv_die "admission library failed to source"
    return 2
  }
  # shellcheck source=scripts/release/lib/lib-json-schema.sh
  . "$here/lib/lib-json-schema.sh" || {
    bv_die "schema library failed to source"
    return 2
  }

  # ── 1. snapshot the closed set FIRST; nothing below reads $bdir again ──
  adm_snapshot_bundle "$bdir" "$snap" "$store"
  rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  local man="$snap/$ADM_MANIFEST"

  # ── 2. it must be an actionable bundle, by const ─────────────────────
  local sch
  sch="$("$jq" -r '.schema // ""' "$man" 2>/dev/null)"
  if [ "$sch" = "blessed/admission-inspection/v1" ]; then
    bv_no "this is a consistency-only inspection record, not an admitted bundle"
    return 1
  fi
  [ "$sch" = "blessed/admitted-bundle/v1" ] || {
    bv_no "manifest is not an admitted bundle (got '${sch}')"
    return 1
  }
  local out
  out="$(json_schema_validate_file "$man" "$here/references/admitted-bundle.schema.json")"
  [ -z "$out" ] || {
    printf '%s\n' "$out" | sed 's/^/verify: bundle INVALID /' >&2
    bv_no "bundle manifest does not conform"
    return 1
  }

  # ── 3. the caller's expectations govern; the bundle does not ─────────
  [ "$("$jq" -r '.receiver.base_sha' "$man")" = "$exp_base" ] ||
    {
      bv_no "bundle base $("$jq" -r '.receiver.base_sha' "$man") is not the independently expected $exp_base"
      return 1
    }
  [ "$("$jq" -r '.selected.surface_id' "$man")" = "$exp_surface" ] ||
    {
      bv_no "bundle surface is not the independently expected '$exp_surface'"
      return 1
    }
  [ "$("$jq" -r '.selected.channel' "$man")" = "$exp_channel" ] ||
    {
      bv_no "bundle channel is not the independently expected '$exp_channel'"
      return 1
    }

  # ── 4. committed digests must equal the SNAPSHOT bytes ───────────────
  local want have
  check_commit() { # $1=commitment key $2=snapshot file
    want="$("$jq" -r --arg k "$1" '.commitments[$k] // ""' "$man")"
    [ -n "$want" ] || {
      bv_no "bundle commits to no $1 digest"
      return 1
    }
    have="$(adm_d "$2")"
    [ "$want" = "$have" ] || {
      bv_no "$1 bytes ($have) do not match the admitted commitment ($want)"
      return 1
    }
  }
  check_commit event "$snap/$ADM_EVENT" || return 1
  check_commit receipt "$snap/$ADM_RECEIPT" || return 1
  check_commit attestation "$snap/$ADM_ATTEST" || return 1
  check_commit candidate "$snap/$ADM_CANDDIR/release-candidate.json" || return 1
  check_commit candidate_signature "$snap/$ADM_CANDDIR/release-candidate.json.sig" || return 1
  # The out-of-band store must be the one that was admitted.
  check_commit trust_store "$snap/$ADM_STORE" || return 1

  # ── 5. surface/policy: exact declared paths, tracked at the base ─────
  local spath rpath
  spath="$("$jq" -r '.commitments.surfaces.path' "$man")"
  adm_blob_at "$repo" "$exp_base" "$spath" "$snap/.blob-surfaces" || return 1
  [ "$(adm_d "$snap/.blob-surfaces")" = "$("$jq" -r '.commitments.surfaces.sha256' "$man")" ] ||
    {
      bv_no "surface declaration at $exp_base is not the admitted bytes"
      return 1
    }
  cmp -s "$snap/.blob-surfaces" "$snap/$ADM_SURFACES" ||
    {
      bv_no "the bundle's surface copy differs from the tracked blob at $exp_base"
      return 1
    }
  if [ "$("$jq" -r '.commitments.renderer_config.none // false' "$man")" != "true" ]; then
    rpath="$("$jq" -r '.commitments.renderer_config.path' "$man")"
    # The path is re-derived from the SELECTED declaration, not trusted from the
    # bundle: a rewritten commitment path would otherwise choose the blob.
    declared_rc="$("${YQ_BIN:-yq}" -o=json '.' "$snap/$ADM_SURFACES" 2>/dev/null | "$jq" -r --arg id "$exp_surface" \
      '[.surfaces[] | select(.id == $id) | .promotion_outputs[] | select(.role == "downloads-index") | .renderer_config // empty] | first // ""')"
    declared_rc="$(printf '%s' "$declared_rc" | sed -E 's#^\./##; s#//+#/#g; s#/$##')"
    [ "$rpath" = "$declared_rc" ] ||
      {
        bv_no "bundle commits to policy path '$rpath' but the selected surface declares '$declared_rc'"
        return 1
      }
    adm_blob_at "$repo" "$exp_base" "$rpath" "$snap/.blob-policy" || return 1
    [ "$(adm_d "$snap/.blob-policy")" = "$("$jq" -r '.commitments.renderer_config.sha256' "$man")" ] ||
      {
        bv_no "renderer policy at $exp_base is not the admitted bytes"
        return 1
      }
    [ -f "$snap/$ADM_POLICY" ] || {
      bv_no "bundle commits to a renderer policy but carries none"
      return 1
    }
    cmp -s "$snap/.blob-policy" "$snap/$ADM_POLICY" ||
      {
        bv_no "the bundle's policy copy differs from the tracked blob at $exp_base"
        return 1
      }
  else
    [ ! -f "$snap/$ADM_POLICY" ] || {
      bv_no "bundle carries a renderer policy it does not commit to"
      return 1
    }
  fi

  # ── 6. every admission rule, again, over the snapshot ────────────────
  adm_verify_snapshot "$snap" "$repo" "$signing" "$exp_base" "$exp_surface" "$exp_channel"
  rc=$?
  [ "$rc" -eq 0 ] || return "$rc"

  # ── 7. re-derive the redundant identity fields; never read them ──────
  local cand="$snap/$ADM_CANDDIR/release-candidate.json"
  local idmis
  idmis="$("$jq" -r -n --slurpfile m "$man" --slurpfile c "$cand" --slurpfile r "$snap/$ADM_RECEIPT" '
    $m[0] as $b | $c[0] as $ca | $r[0] as $re
    | [ (if $b.identity.version != $ca.version then "identity.version != candidate" else empty end),
        (if $b.identity.tag != $ca.tag then "identity.tag != candidate" else empty end),
        (if $b.identity.project != $ca.project then "identity.project != candidate" else empty end),
        (if ($b.identity.producer_repo|ascii_downcase) != ($ca.producer_repo|ascii_downcase) then "identity.producer_repo != candidate" else empty end),
        (if $b.identity.producer_sha != $ca.source_sha then "identity.producer_sha != candidate" else empty end),
        (if $b.identity.candidate_created_at != $ca.created_at then "identity.candidate_created_at != candidate" else empty end),
        (if $b.identity.release_id != $re.release_id then "identity.release_id != receipt" else empty end),
        (if $b.identity.published_at != $re.published_at then "identity.published_at (\($b.identity.published_at)) != receipt (\($re.published_at))" else empty end),
        (if $b.signature_verification.profile != $ca.signing.profile then "signature_verification.profile != candidate" else empty end),
        (if $b.signature_verification.key_id != $ca.signing.key_id then "signature_verification.key_id != candidate" else empty end)
      ] | .[]')" || {
    bv_die "identity re-derivation failed to evaluate"
    return 2
  }
  [ -z "$idmis" ] || {
    printf '%s\n' "$idmis" | sed 's/^/verify: REFUSE /' >&2
    return 1
  }

  # ── 8. continuity: recompute admission_id and compare with the caller's ──
  local recomputed stored
  recomputed="$(adm_admission_id "$man")"
  stored="$("$jq" -r '.admission_id' "$man")"
  [ "$recomputed" = "$stored" ] ||
    {
      bv_no "bundle admission_id $stored does not match its own contents ($recomputed)"
      return 1
    }
  [ "$recomputed" = "$exp_id" ] ||
    {
      bv_no "admission_id $recomputed is not the expected $exp_id — this bundle is not the one this run was started for"
      return 1
    }

  rm -f "$snap/.blob-surfaces" "$snap/.blob-policy"
  printf 'verify: OK re-admitted %s (signature verified against the out-of-band store)\n' \
    "$(printf '%s' "$recomputed" | cut -c1-12)" >&2
  return 0
}
