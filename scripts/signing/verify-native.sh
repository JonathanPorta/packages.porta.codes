#!/usr/bin/env bash
# verify-native.sh — verify a tauri-minisign-v1 artifact signature, FAIL CLOSED.
#
# This is the adapter the release category dispatches to when a candidate artifact
# declares `signature_profile: tauri-minisign-v1` (see
# scripts/release/validate-candidate.sh). Its argv contract is fixed by that caller.
#
# It is NOT the candidate-envelope signature path — that remains
# ed25519-detached-v1 through verify.sh. A key trusted for one profile is never
# accepted for the other: this script resolves the trust store through the
# native-only resolver, which requires the entry's profile to be
# tauri-minisign-v1.
#
# What "valid" means here (all must hold):
#   1. the sidecar is a minisign document (base64-wrapped, as Tauri publishes it,
#      or raw);
#   2. its algorithm is "ED" — PREHASHED. Legacy "Ed" (signature over raw payload
#      bytes) is rejected: accepting it would verify a different contract;
#   3. the document's embedded key id equals the declared --key-id, so a sidecar
#      signed by some other key already in the trust store cannot be substituted;
#   4. Ed25519 verifies the signature over BLAKE2b-512(payload);
#   5. Ed25519 verifies the global signature over (signature || trusted comment),
#      without which the trusted comment is unauthenticated attacker-controlled
#      text.
#
# Exit 0 == valid signature by a trusted key; non-zero otherwise (fail closed).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/signing/lib/signing-lib.sh
. "$HERE/lib/signing-lib.sh"

usage() {
  cat >&2 <<'EOF'
Usage:
  verify-native.sh --profile tauri-minisign-v1 --input FILE --signature FILE.sig \
                   --trust-store STORE.json --key-id KEY_ID

  verify-native.sh --profile tauri-minisign-v1 --input FILE --signature FILE.sig \
                   --public-key-base64 B64      # explicit test/dev key (not production)

KEY_ID is the minisign key id: 16 uppercase hex characters, as displayed by
minisign and as declared in the candidate's signature_key_id.

Exit 0 == valid signature by a trusted key; non-zero otherwise (fail closed).
EOF
  exit 2
}

profile="" input="" sigfile="" store="" key_id="" raw_pub=""
while [ $# -gt 0 ]; do
  case "$1" in
    --profile)
      profile="${2:-}"
      shift 2
      ;;
    --input)
      input="${2:-}"
      shift 2
      ;;
    --signature)
      sigfile="${2:-}"
      shift 2
      ;;
    --trust-store)
      store="${2:-}"
      shift 2
      ;;
    --key-id)
      key_id="${2:-}"
      shift 2
      ;;
    --public-key-base64)
      raw_pub="${2:-}"
      shift 2
      ;;
    -h | --help) usage ;;
    --)
      shift
      break
      ;;
    -*)
      printf 'signing: unknown option: %s\n' "$1" >&2
      usage
      ;;
    *)
      printf 'signing: unexpected argument: %s\n' "$1" >&2
      usage
      ;;
  esac
done

[ "$profile" = "$SIG_NATIVE_PROFILE" ] || {
  printf 'signing: --profile must be %s\n' "$SIG_NATIVE_PROFILE" >&2
  exit 2
}
{ [ -f "$input" ] && [ ! -L "$input" ]; } || {
  printf 'signing: --input must be a regular file\n' >&2
  exit 2
}
{ [ -f "$sigfile" ] && [ ! -L "$sigfile" ]; } || {
  printf 'signing: --signature must be a regular file\n' >&2
  exit 2
}
if [ -n "$raw_pub" ]; then
  [ -z "$store" ] || {
    printf 'signing: --public-key-base64 cannot combine with --trust-store\n' >&2
    exit 2
  }
else
  { [ -n "$store" ] && [ -n "$key_id" ]; } || {
    printf 'signing: provide --trust-store + --key-id (production) or --public-key-base64 (test)\n' >&2
    exit 2
  }
fi
# The declared key id is bound to the document below, so its shape is enforced.
if [ -n "$key_id" ]; then
  case "$key_id" in
    *[!0-9A-Fa-f]* | "")
      printf 'signing: --key-id must be 16 hex characters (minisign key id)\n' >&2
      exit 2
      ;;
  esac
  [ "${#key_id}" -eq 16 ] || {
    printf 'signing: --key-id must be 16 hex characters (minisign key id)\n' >&2
    exit 2
  }
fi

sig_require_openssl3 || exit 1

TMP="$(mktemp -d)" || exit 1
trap 'rm -rf "$TMP"' EXIT INT TERM HUP

# ── 1. parse the document ────────────────────────────────────────────────────
sig_native_read_document "$sigfile" >"$TMP/doc" || exit 1

lines="$(wc -l <"$TMP/doc" | tr -d ' ')"
[ "$lines" -ge 4 ] || {
  printf 'signing: malformed minisign document (need 4 lines, got %s)\n' "$lines" >&2
  exit 1
}
sig_b64="$(sed -n '2p' "$TMP/doc")"
tc_line="$(sed -n '3p' "$TMP/doc")"
global_b64="$(sed -n '4p' "$TMP/doc")"

case "$tc_line" in
  "trusted comment: "*) trusted_comment="${tc_line#trusted comment: }" ;;
  *)
    printf 'signing: malformed minisign document (missing trusted comment)\n' >&2
    exit 1
    ;;
esac

sig_is_canonical_b64 "$sig_b64" || {
  printf 'signing: malformed signature encoding\n' >&2
  exit 1
}
sig_is_canonical_b64 "$global_b64" || {
  printf 'signing: malformed global signature encoding\n' >&2
  exit 1
}

printf '%s' "$sig_b64" | sig_openssl_base64_d >"$TMP/blob" || {
  printf 'signing: malformed signature encoding\n' >&2
  exit 1
}
blob_len="$(wc -c <"$TMP/blob" | tr -d ' ')"
[ "$blob_len" -eq 74 ] || {
  printf 'signing: signature blob must be 74 bytes (got %s)\n' "$blob_len" >&2
  exit 1
}

# ── 2. algorithm must be PREHASHED "ED" ──────────────────────────────────────
alg="$(dd if="$TMP/blob" bs=1 count=2 2>/dev/null)"
case "$alg" in
  ED) ;;
  Ed)
    printf 'signing: legacy unprehashed minisign signature ("Ed") is not accepted by %s\n' "$SIG_NATIVE_PROFILE" >&2
    exit 1
    ;;
  *)
    printf 'signing: unknown minisign algorithm\n' >&2
    exit 1
    ;;
esac

# ── 3. embedded key id must equal the declared key id ────────────────────────
doc_key_id="$(sig_native_keyid_from_blob "$sig_b64")" || {
  printf 'signing: cannot read key id from signature\n' >&2
  exit 1
}
if [ -n "$key_id" ]; then
  want="$(printf '%s' "$key_id" | tr 'a-f' 'A-F')"
  [ "$doc_key_id" = "$want" ] || {
    printf 'signing: signature key id %s does not match declared key id %s\n' "$doc_key_id" "$want" >&2
    exit 1
  }
fi

# ── 4. resolve the public key (native profile only) ──────────────────────────
if [ -n "$raw_pub" ]; then
  pub_b64="$raw_pub"
  sig_is_valid_pub_b64 "$pub_b64" || {
    printf 'signing: malformed --public-key-base64\n' >&2
    exit 1
  }
else
  pub_b64="$(sig_native_resolve_trust_key "$store" "$key_id")" || exit 1
fi
sig_pub_b64_to_pem "$pub_b64" >"$TMP/pub.pem"

# ── 5. payload signature over the BLAKE2b-512 prehash ────────────────────────
dd if="$TMP/blob" bs=1 skip=10 count=64 2>/dev/null >"$TMP/sig.raw"
"$(sig_openssl)" dgst -blake2b512 -binary "$input" >"$TMP/hash.bin" 2>/dev/null || {
  printf 'signing: cannot compute BLAKE2b-512 prehash\n' >&2
  exit 1
}
[ "$(wc -c <"$TMP/hash.bin" | tr -d ' ')" -eq 64 ] || {
  printf 'signing: BLAKE2b-512 prehash is not 64 bytes\n' >&2
  exit 1
}
"$(sig_openssl)" pkeyutl -verify -pubin -inkey "$TMP/pub.pem" -rawin \
  -in "$TMP/hash.bin" -sigfile "$TMP/sig.raw" >/dev/null 2>&1 || {
  printf 'signing: SIGNATURE VERIFICATION FAILED\n' >&2
  exit 1
}

# ── 6. global signature binds the trusted comment ────────────────────────────
{
  cat "$TMP/sig.raw"
  printf '%s' "$trusted_comment"
} >"$TMP/global.msg"
printf '%s' "$global_b64" | sig_openssl_base64_d >"$TMP/global.sig" || {
  printf 'signing: malformed global signature encoding\n' >&2
  exit 1
}
[ "$(wc -c <"$TMP/global.sig" | tr -d ' ')" -eq 64 ] || {
  printf 'signing: global signature must be 64 bytes\n' >&2
  exit 1
}
"$(sig_openssl)" pkeyutl -verify -pubin -inkey "$TMP/pub.pem" -rawin \
  -in "$TMP/global.msg" -sigfile "$TMP/global.sig" >/dev/null 2>&1 || {
  printf 'signing: TRUSTED COMMENT VERIFICATION FAILED (global signature)\n' >&2
  exit 1
}

printf 'signing: OK — valid %s signature (key id %s)\n' "$SIG_NATIVE_PROFILE" "$doc_key_id" >&2
exit 0
