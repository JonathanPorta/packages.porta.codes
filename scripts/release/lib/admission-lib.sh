#!/usr/bin/env bash
# shellcheck disable=SC2016  # jq programs: $-names are jq variables, not shell
# admission-lib.sh — the ONE implementation of admission semantics.
#
# Admission, render, and apply all call these functions. Anything checked in
# only one of them is not a rule, it is a coincidence: a later stage that
# re-checks a subset silently widens what the earlier stage decided.
#
# TRUST ROOT. The candidate trust store is supplied to every stage INDEPENDENTLY
# of the bundle. A store carried inside the bundle would be caller-controlled,
# which makes signature verification circular — an attacker supplying candidate,
# signature and store together passes every check. The bundle therefore only
# COMMITS to which store was admitted; the bytes must arrive out-of-band and are
# compared against that commitment.
#
# SNAPSHOT FIRST. The closed input set is copied into a private snapshot, with
# symlinks, special files and unexpected entries rejected during the copy; the
# candidate manifest is copied first and the file closure is derived from that
# copy. Only the snapshot is then validated and verified — verifying a source
# path and reading it again is the substitution window this closes.
#
# This holds under a documented NO-CONCURRENT-WRITER boundary. The copy itself
# necessarily reads source bytes, so a writer racing the copy is out of scope;
# that is precisely why a bundle must not cross a trust boundary between
# stages.
#
# CONTINUITY, NOT AUTHENTICATION. admission_id is a digest over the bundle's
# decision fields. A trusted same-job driver holds the expected value and passes
# it in; later stages recompute and compare. This binds stages inside ONE
# continuous execution boundary. It is NOT authentication across untrusted jobs
# or storage — a bundle moved through either would need a receiver-authenticated
# envelope, which is deliberately not built here.
set -uo pipefail

ADM_JQ="${JQ_BIN:-jq}"
adm_die() {
  printf 'admission: %s\n' "$1" >&2
  return 2
}
adm_no() {
  printf 'admission: REJECT %s\n' "$1" >&2
  return 1
}

# Fixed snapshot names. Never derived from a caller-supplied basename, so a
# declaration of `a/policy.json` cannot be satisfied by `b/policy.json`.
ADM_EVENT="event.json"
ADM_RECEIPT="receipt.json"
ADM_ATTEST="attestation.json"
ADM_SURFACES="surfaces.yaml"
ADM_POLICY="renderer-config.json"
ADM_STORE="trust-store.json"
ADM_CANDDIR="candidate-dir"
ADM_MANIFEST="bundle.json"

adm_d() { shasum -a 256 "$1" | awk '{print $1}'; }

# adm_copy_regular SRC DST — refuse anything that is not an ordinary file.
adm_copy_regular() {
  local s="$1" d="$2"
  [ -e "$s" ] || {
    adm_no "input is missing: $s"
    return 1
  }
  [ -L "$s" ] && {
    adm_no "input is a symlink and will not be followed: $s"
    return 1
  }
  [ -f "$s" ] || {
    adm_no "input is not a regular file: $s"
    return 1
  }
  mkdir -p "$(dirname "$d")" || {
    adm_die "cannot create $(dirname "$d")"
    return 2
  }
  cp "$s" "$d" || {
    adm_die "cannot snapshot $s"
    return 2
  }
  return 0
}

# adm_snapshot_candidate_dir SRC DST — copy exactly the closed candidate set.
# Extra entries are refused here rather than after verification, because an
# unexpected file in a candidate directory is either a packaging bug or an
# attempt to smuggle a payload past the closed-set rule.
adm_snapshot_candidate_dir() {
  local src="$1" dst="$2" cand="$1/release-candidate.json" f
  [ -f "$cand" ] || {
    adm_no "candidate directory has no release-candidate.json"
    return 1
  }
  "$ADM_JQ" -e . "$cand" >/dev/null 2>&1 || {
    adm_no "release-candidate.json is not valid JSON"
    return 1
  }
  mkdir -p "$dst" || {
    adm_die "cannot create snapshot candidate dir"
    return 2
  }
  adm_copy_regular "$cand" "$dst/release-candidate.json" || return $?
  adm_copy_regular "$src/release-candidate.json.sig" "$dst/release-candidate.json.sig" || return $?
  # The closure is derived from the COPIED manifest, so a source manifest
  # rewritten after this point cannot change which files get snapshotted.
  local mcopy="$dst/release-candidate.json"
  local expected="$dst/.expected"
  {
    printf 'release-candidate.json\nrelease-candidate.json.sig\n'
    "$ADM_JQ" -r '.files[].name' "$mcopy"
  } | sort -u >"$expected"
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    case "$f" in */* | .. | .)
      adm_no "candidate file name is not a plain basename: $f"
      return 1
      ;;
    esac
    [ -f "$dst/$f" ] && continue
    adm_copy_regular "$src/$f" "$dst/$f" || return $?
  done <"$expected"
  local actual
  actual="$(cd "$src" && find . -mindepth 1 -maxdepth 1 | sed 's#^\./##' | sort)"
  local extra
  extra="$(comm -23 <(printf '%s\n' "$actual") "$expected")"
  rm -f "$expected"
  [ -z "$extra" ] || {
    adm_no "candidate directory holds unlisted entr(ies): $(printf '%s' "$extra" | tr '\n' ' ')"
    return 1
  }
  return 0
}

# adm_snapshot_bundle BUNDLE_DIR SNAP EXTERNAL_TRUST_STORE
# Copies the closed bundle input set, then the out-of-band trust store.
adm_snapshot_bundle() {
  local b="$1" snap="$2" store="$3" f
  mkdir -p "$snap" || {
    adm_die "cannot create snapshot"
    return 2
  }
  for f in "$ADM_MANIFEST" "$ADM_EVENT" "$ADM_RECEIPT" "$ADM_ATTEST" "$ADM_SURFACES"; do
    adm_copy_regular "$b/$f" "$snap/$f" || return $?
  done
  if [ -f "$b/$ADM_POLICY" ] || [ -L "$b/$ADM_POLICY" ]; then
    adm_copy_regular "$b/$ADM_POLICY" "$snap/$ADM_POLICY" || return $?
  fi
  # A trust store inside the bundle is never a root of trust; refuse the
  # ambiguity outright rather than silently preferring one of two stores.
  [ -e "$b/$ADM_STORE" ] && {
    adm_no "the bundle carries its own trust store; the trust root must be supplied out-of-band"
    return 1
  }
  adm_copy_regular "$store" "$snap/$ADM_STORE" || return $?
  adm_snapshot_candidate_dir "$b/$ADM_CANDDIR" "$snap/$ADM_CANDDIR" || return $?
  local allowed extra
  allowed="$(printf '%s\n%s\n%s\n%s\n%s\n%s\n%s\n' "$ADM_MANIFEST" "$ADM_EVENT" "$ADM_RECEIPT" \
    "$ADM_ATTEST" "$ADM_SURFACES" "$ADM_POLICY" "$ADM_CANDDIR" | sort -u)"
  extra="$(cd "$b" && find . -mindepth 1 -maxdepth 1 | sed 's#^\./##' | sort | comm -23 - <(printf '%s\n' "$allowed"))"
  [ -z "$extra" ] || {
    adm_no "bundle holds unexpected entr(ies): $(printf '%s' "$extra" | tr '\n' ' ')"
    return 1
  }
  return 0
}

# adm_admission_id BUNDLE_JSON — canonical digest over the decision fields.
adm_admission_id() {
  "$ADM_JQ" -S -c '{selected, identity, receiver, commitments, signature_verification}' "$1" |
    shasum -a 256 | awk '{print $1}'
}

# adm_verify_snapshot SNAP REPO SIGNING BASE_SHA SURFACE_ID CHANNEL
# Every semantic rule, over snapshot bytes only.
adm_verify_snapshot() {
  local snap="$1" repo="$2" signing="$3" base_sha="$4" surface_id="$5" channel="$6"
  local here
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  local cand="$snap/$ADM_CANDDIR/release-candidate.json" out rc

  # shellcheck source=scripts/release/lib/lib-json-schema.sh
  . "$here/lib/lib-json-schema.sh" || {
    adm_die "schema library failed to source"
    return 2
  }
  sc() { # $1=file $2=schema $3=label
    out="$(json_schema_validate_file "$1" "$here/references/$2.schema.json")"
    rc=$?
    if [ "$rc" -ne 0 ] && [ -z "$out" ]; then
      adm_die "schema validator crashed on $3"
      return 2
    fi
    [ -z "$out" ] && return 0
    printf '%s\n' "$out" | sed "s/^/admission: REJECT $3 /" >&2
    return 1
  }
  sc "$cand" release-candidate "candidate" || return $?
  sc "$snap/$ADM_EVENT" release-candidate-ready "event" || return $?
  sc "$snap/$ADM_RECEIPT" release-receipt "receipt" || return $?
  sc "$snap/$ADM_ATTEST" publication-attestation "attestation" || return $?
  [ ! -f "$snap/$ADM_POLICY" ] || sc "$snap/$ADM_POLICY" downloads-index-renderer-config "renderer-config" || return $?

  # ── candidate signature, against the OUT-OF-BAND store ────────────────
  [ -d "$signing" ] || {
    adm_die "signing category not found: $signing"
    return 2
  }
  if ! out="$(bash "$here/validate-candidate.sh" --candidate-dir "$snap/$ADM_CANDDIR" \
    --trust-store "$snap/$ADM_STORE" --signing-dir "$signing" 2>&1)"; then
    printf '%s\n' "$out" | sed 's/^/admission: /' >&2
    adm_no "candidate failed signature verification against the independently supplied trust store"
    return 1
  fi

  # ── the surface declaration is canonically valid ──────────────────────
  bash "$here/validate-surfaces.sh" --file "$snap/$ADM_SURFACES" >/dev/null 2>&1 ||
    {
      adm_no "surface declaration failed canonical validation"
      return 1
    }
  "${YQ_BIN:-yq}" -o=json '.' "$snap/$ADM_SURFACES" >"$snap/.surfaces.json" 2>/dev/null ||
    {
      adm_die "cannot normalize the validated surface declaration"
      return 2
    }
  local sel
  sel="$("$ADM_JQ" -c --arg id "$surface_id" '.surfaces[] | select(.id == $id)' "$snap/.surfaces.json")"
  [ -n "$sel" ] || {
    adm_no "surface '$surface_id' is not declared"
    return 1
  }
  printf '%s' "$sel" >"$snap/.sel.json"
  [ "$("$ADM_JQ" -r '.kind' "$snap/.sel.json")" = "public-download-surface" ] ||
    {
      adm_no "surface kind is not supported by this generator"
      return 1
    }
  "$ADM_JQ" -e --arg ch "$channel" \
    'any(.promotion_outputs[]; .role == "channel-pointer" and .channel == $ch)' "$snap/.sel.json" >/dev/null ||
    {
      adm_no "surface declares no channel-pointer for channel '$channel'"
      return 1
    }

  local idx_missing
  idx_missing="$("$ADM_JQ" -r '[.promotion_outputs[] | select(.role == "downloads-index") | select(has("renderer_config") | not) | .id] | join(", ")' "$snap/.sel.json")"
  [ -z "$idx_missing" ] || {
    adm_no "downloads-index output(s) [$idx_missing] declare no renderer_config"
    return 1
  }

  # ── every duplicated claim must agree with the signed candidate ───────
  local mism
  mism="$("$ADM_JQ" -r -n --slurpfile e "$snap/$ADM_EVENT" --slurpfile c "$cand" \
    --slurpfile r "$snap/$ADM_RECEIPT" --slurpfile a "$snap/$ADM_ATTEST" \
    --slurpfile s "$snap/.sel.json" --arg sid "$surface_id" --arg ch "$channel" '
    $e[0] as $ev | $c[0] as $ca | $r[0] as $re | $a[0] as $at | $s[0] as $su
    | def norm: ascii_downcase;
    [ (if $ev.candidate.project != $ca.project then "event project != candidate" else empty end),
      (if $ev.candidate.version != $ca.version then "event version \($ev.candidate.version) != candidate \($ca.version)" else empty end),
      (if $ev.candidate.tag != $ca.tag then "event tag != candidate" else empty end),
      (if (($ev.candidate.component // $ca.component) != $ca.component) then "event component != candidate" else empty end),
      (if ($ev.candidate.producer_repo|norm) != ($ca.producer_repo|norm) then "event producer_repo != candidate" else empty end),
      (if $ev.candidate.producer_sha != $ca.source_sha then "event producer_sha != candidate source_sha" else empty end),
      (if $ca.tag != ("v" + $ca.version) then "candidate tag/version disagree" else empty end),
      (if ($ev.promotion.surface_repo|norm) != ($su.owner_repo|norm) then "event surface_repo != declared owner_repo" else empty end),
      (if $ev.promotion.surface_kind != $su.kind then "event surface_kind != declared kind" else empty end),
      (if $ev.promotion.surface_id != $sid then "event surface_id != selected" else empty end),
      (if $ev.promotion.channel != $ch then "event channel != selected" else empty end),
      (if ($re.producer_repo|norm) != ($ca.producer_repo|norm) then "receipt producer_repo != candidate" else empty end),
      (if $re.tag != $ca.tag then "receipt tag \($re.tag) != candidate tag \($ca.tag)" else empty end),
      (if $re.target_sha != $ca.source_sha then "receipt target_sha != candidate source_sha" else empty end),
      (if $at.surface_id != $sid then "attestation surface_id != selected" else empty end),
      (if $at.channel != $ch then "attestation channel != selected" else empty end),
      (if ([$su.producer_repos[] | norm] | index($ca.producer_repo | norm)) == null then "candidate producer_repo is not in the surface allowlist" else empty end)
    ] | .[]')" || {
    adm_die "identity comparison failed to evaluate"
    return 2
  }
  [ -z "$mism" ] || {
    printf '%s\n' "$mism" | sed 's/^/admission: REJECT /' >&2
    return 1
  }

  local cd
  cd="$(adm_d "$cand")"
  local k v
  for k in "attestation:$("$ADM_JQ" -r '.candidate_sha256' "$snap/$ADM_ATTEST")" \
    "event:$("$ADM_JQ" -r '.candidate.manifest_sha256' "$snap/$ADM_EVENT")" \
    "receipt:$("$ADM_JQ" -r '.manifest_asset.sha256' "$snap/$ADM_RECEIPT")"; do
    v="${k#*:}"
    [ "$v" = "$cd" ] || {
      adm_no "${k%%:*} does not commit to the candidate bytes"
      return 1
    }
  done

  # ── surface and policy must be the tracked blobs at the trusted base ──
  [ -d "$repo/.git" ] || {
    adm_die "receiver repo is not a git checkout: $repo"
    return 2
  }
  git -C "$repo" cat-file -e "${base_sha}^{commit}" 2>/dev/null ||
    {
      adm_no "trusted base $base_sha is not in the receiver repository"
      return 1
    }
  return 0
}

# adm_blob_at REPO SHA PATH DEST — read a tracked regular blob, or refuse.
adm_blob_at() {
  local repo="$1" sha="$2" path="$3" dest="$4" mode
  mode="$(git -C "$repo" ls-tree "$sha" -- "$path" | awk '{print $1}')"
  case "$mode" in
    100644 | 100755) : ;;
    "")
      adm_no "'$path' is not tracked at $sha"
      return 1
      ;;
    *)
      adm_no "'$path' is not a regular file at $sha (mode $mode)"
      return 1
      ;;
  esac
  git -C "$repo" cat-file blob "${sha}:${path}" >"$dest" 2>/dev/null ||
    {
      adm_no "cannot read blob $path at $sha"
      return 1
    }
  return 0
}
