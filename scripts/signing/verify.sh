#!/usr/bin/env bash
# verify.sh — verify a detached ed25519-detached-v1 signature, FAIL CLOSED.
# Production mode resolves a key_id from a pinned trust store
# (blessed/signing-trust-store/v1); --public-key-base64 is an explicit test/dev
# escape hatch. Exit 0 only on a valid signature by a trusted key.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/signing/lib/signing-lib.sh
. "$HERE/lib/signing-lib.sh"

usage() {
  cat >&2 <<'EOF'
Usage:
  verify.sh --profile ed25519-detached-v1 --input FILE --signature FILE.sig \
            --trust-store STORE.json --key-id KEY_ID

  verify.sh --profile ed25519-detached-v1 --input FILE --signature FILE.sig \
            --public-key-base64 B64      # explicit test/dev key (not production)

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

[ "$profile" = "$SIG_PROFILE" ] || {
  printf 'signing: --profile must be %s\n' "$SIG_PROFILE" >&2
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
  [ -z "$store$key_id" ] || {
    printf 'signing: --public-key-base64 cannot combine with --trust-store/--key-id\n' >&2
    exit 2
  }
else
  { [ -n "$store" ] && [ -n "$key_id" ]; } || {
    printf 'signing: provide --trust-store + --key-id (production) or --public-key-base64 (test)\n' >&2
    exit 2
  }
fi

sig_require_openssl3 || exit 1

# Strict wire-format check BEFORE decoding: the .sig file must be EXACTLY 88 bytes
# — this alone rejects a trailing newline, leading/trailing/embedded whitespace,
# and any wrong length. Then the standard-base64 shape is enforced.
siglen="$(wc -c <"$sigfile" | tr -d ' ')"
[ "$siglen" -eq 88 ] || {
  printf 'signing: signature file must be exactly 88 bytes (got %s) — no whitespace or trailing newline\n' "$siglen" >&2
  exit 1
}
sig_b64="$(cat -- "$sigfile")"
sig_is_valid_sig_b64 "$sig_b64" || {
  printf 'signing: malformed signature encoding\n' >&2
  exit 1
}

if [ -n "$raw_pub" ]; then
  pub_b64="$raw_pub"
  sig_is_valid_pub_b64 "$pub_b64" || {
    printf 'signing: malformed --public-key-base64\n' >&2
    exit 1
  }
else
  pub_b64="$(sig_resolve_trust_key "$store" "$key_id")" || exit 1
fi

if sig_verify_raw "$pub_b64" "$input" "$sig_b64"; then
  printf 'signing: OK — valid ed25519-detached-v1 signature\n' >&2
  exit 0
else
  printf 'signing: SIGNATURE VERIFICATION FAILED\n' >&2
  exit 1
fi
