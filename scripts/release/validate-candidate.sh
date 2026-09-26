#!/usr/bin/env bash
# validate-candidate.sh — validate an assembled candidate. Runs schema + semantic
# closure + on-disk hash recompute always; when --trust-store and --signing-dir are
# given, ALSO verifies release-candidate.json.sig (and per-artifact sigs when
# signing.artifacts==required) through the signing category's CLI (API v1).
#
# Crypto is delegated: this script calls signing/verify.sh and never sources
# signing-lib.sh or invokes openssl, so a signing-side fix can't create a second
# cryptographic interpretation here.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/release/lib/release-lib.sh
. "$HERE/lib/release-lib.sh"

usage() {
  cat >&2 <<'EOF'
Usage: validate-candidate.sh --candidate-dir DIR
                             [--candidate DIR/release-candidate.json]
                             [--trust-store STORE.json --signing-dir scripts/signing]

Without --trust-store/--signing-dir: schema + closure + on-disk recompute (pre-sign).
With them: also verifies the manifest signature (and required artifact sigs).
EOF
  exit 2
}

cdir="" candidate="" store="" signing_dir=""
while [ $# -gt 0 ]; do
  case "$1" in
    --candidate-dir)
      cdir="${2:-}"
      shift 2
      ;;
    --candidate)
      candidate="${2:-}"
      shift 2
      ;;
    --trust-store)
      store="${2:-}"
      shift 2
      ;;
    --signing-dir)
      signing_dir="${2:-}"
      shift 2
      ;;
    -h | --help) usage ;;
    *)
      printf 'release: unexpected arg: %s\n' "$1" >&2
      usage
      ;;
  esac
done
[ -n "$cdir" ] || usage
[ -d "$cdir" ] || {
  printf 'release: candidate dir not found: %s\n' "$cdir" >&2
  exit 1
}
[ -n "$candidate" ] || candidate="$cdir/release-candidate.json"
[ -f "$candidate" ] || {
  printf 'release: candidate manifest not found: %s\n' "$candidate" >&2
  exit 1
}
jq -e . "$candidate" >/dev/null 2>&1 || {
  printf 'release: candidate is not valid JSON\n' >&2
  exit 1
}
if [ -n "$store$signing_dir" ] && { [ -z "$store" ] || [ -z "$signing_dir" ]; }; then
  printf 'release: signature verification needs BOTH --trust-store and --signing-dir\n' >&2
  exit 2
fi

fail=0
report() { # $1=label  $2=violations
  if [ -n "$2" ]; then
    printf 'release: FAIL %s:\n%s\n' "$1" "$2" >&2
    fail=1
  else
    printf 'release: OK   %s\n' "$1" >&2
  fi
}

report "schema (blessed/release-candidate/v1)" "$(rel_schema_validate "$candidate" "$HERE/references/release-candidate.schema.json")"
report "semantic closure" "$(rel_semantic_checks "$candidate")"
report "on-disk hash recompute" "$(rel_recompute_check "$candidate" "$cdir")"
report "closed candidate dir (no unlisted files)" "$(rel_closed_dir_check "$candidate" "$cdir")"

# Signature verification (surface-side), delegated to the signing category.
if [ -n "$store" ]; then
  if rel_require_signing_api "$signing_dir"; then
    key_id="$(jq -r '.signing.key_id' "$candidate")"
    sig="$cdir/release-candidate.json.sig"
    if [ ! -f "$sig" ]; then
      report "manifest signature present" "release-candidate.json.sig is missing"
    elif bash "$signing_dir/verify.sh" --profile ed25519-detached-v1 \
      --input "$candidate" --signature "$sig" --trust-store "$store" --key-id "$key_id" >/dev/null 2>&1; then
      report "manifest signature (ed25519-detached-v1, $key_id)" ""
    else
      report "manifest signature (ed25519-detached-v1, $key_id)" "verification failed"
    fi
    # Per-artifact signatures when required.
    #
    # An artifact MAY declare its own runtime-native signature profile/key id
    # (releases.candidate@1 — the complete `signature` + `signature_profile` +
    # `signature_key_id` tuple enforced by rel_semantic_checks). Verification
    # dispatches on that EFFECTIVE profile/key, not on the manifest envelope's:
    # verifying a Minisign sidecar with the envelope profile and key would check
    # the wrong cryptographic contract. Absent an override, the artifact inherits
    # the envelope's profile/key. Every unroutable case fails closed.
    if [ "$(jq -r '.signing.artifacts' "$candidate")" = "required" ]; then
      env_profile="$(jq -r '.signing.profile' "$candidate")"
      while IFS="$(printf '\t')" read -r af afile aprofile akey; do
        [ -n "$af" ] || continue
        asig="$cdir/$af"
        ain="$cdir/$afile"
        label="artifact signature $af ($aprofile, $akey)"
        case "$aprofile" in
          ed25519-detached-v1)
            if bash "$signing_dir/verify.sh" --profile ed25519-detached-v1 --input "$ain" --signature "$asig" --trust-store "$store" --key-id "$akey" >/dev/null 2>&1; then
              report "$label" ""
            else
              report "$label" "verification failed"
            fi
            ;;
          tauri-minisign-v1)
            # The native profile is not verifiable by the ed25519-detached CLI.
            # Require the key id to be an active trust-store key bound to THIS
            # profile, then delegate the bytes to the profile's adapter. No
            # adapter == no verification == INVALID (never a silent pass).
            if ! jq -e --arg k "$akey" --arg p "$aprofile" \
              '.keys[$k] // empty | select(.profile == $p and .status == "active")' "$store" >/dev/null 2>&1; then
              report "$label" "key id is not an active $aprofile key in the trust store"
            elif [ ! -f "$signing_dir/verify-native.sh" ]; then
              report "$label" "no adapter for $aprofile (expected $signing_dir/verify-native.sh) — cannot verify, failing closed"
            elif bash "$signing_dir/verify-native.sh" --profile "$aprofile" --input "$ain" --signature "$asig" --trust-store "$store" --key-id "$akey" >/dev/null 2>&1; then
              report "$label" ""
            else
              report "$label" "verification failed"
            fi
            ;;
          *)
            report "$label" "unsupported artifact signature profile: $aprofile"
            ;;
        esac
      done < <(jq -r --arg dp "$env_profile" --arg dk "$key_id" '
        .artifacts[]
        | select(.signature != null)
        | [ .signature,
            .filename,
            (if ((.signature_profile // "") | length) > 0 then .signature_profile else $dp end),
            (if ((.signature_key_id // "") | length) > 0 then .signature_key_id else $dk end) ]
        | @tsv' "$candidate")
    fi
  else
    fail=1
  fi
fi

if [ "$fail" -eq 0 ]; then
  printf 'release: candidate VALID\n' >&2
  exit 0
else
  printf 'release: candidate INVALID\n' >&2
  exit 1
fi
