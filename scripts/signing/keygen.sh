#!/usr/bin/env bash
# keygen.sh — generate an ed25519-detached-v1 keypair for LOCAL use. Generates and
# validates the pair in a private temporary directory, then publishes the private
# PEM (chmod 600) and the raw 32-byte public key (standard base64) to their final
# paths, and prints a ready-to-paste trust-store entry. It NEVER uploads anything
# (no BWS, no network).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/signing/lib/signing-lib.sh
. "$HERE/lib/signing-lib.sh"

usage() {
  cat >&2 <<'EOF'
Usage:
  keygen.sh --out-private KEY.pem --out-public-base64 PUB.b64 [--key-id KEY_ID]

Generates an Ed25519 keypair. The private PEM is written with mode 600. Prints a
blessed/signing-trust-store/v1 entry for KEY_ID (default: unnamed-key).
EOF
  exit 2
}

out_priv="" out_pub="" key_id="unnamed-key"
while [ $# -gt 0 ]; do
  case "$1" in
    --out-private)
      out_priv="${2:-}"
      shift 2
      ;;
    --out-public-base64)
      out_pub="${2:-}"
      shift 2
      ;;
    --key-id)
      key_id="${2:-}"
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
[ -n "$out_priv" ] || usage
[ -n "$out_pub" ] || usage
case "$key_id" in [A-Za-z0-9]*) ;; *)
  printf 'signing: --key-id must start alphanumeric\n' >&2
  exit 2
  ;;
esac
case "$key_id" in *[!A-Za-z0-9._-]*)
  printf 'signing: --key-id has invalid characters: %s\n' "$key_id" >&2
  exit 2
  ;;
esac

sig_require_openssl3 || exit 1

# Normalize each destination to <canonical-parent>/<basename>, so a lexical alias
# (./key) or a symlinked parent cannot make two different strings name one file —
# which would let the public-key write destroy the private key.
norm_dest() {
  local p="$1" d b
  d="$(cd "$(dirname -- "$p")" 2>/dev/null && pwd -P)" || {
    printf 'signing: parent directory of %s does not exist\n' "$p" >&2
    exit 2
  }
  b="$(basename -- "$p")"
  case "$b" in "" | "." | "..")
    printf 'signing: invalid output filename: %s\n' "$p" >&2
    exit 2
    ;;
  esac
  printf '%s/%s' "$d" "$b"
}
np="$(norm_dest "$out_priv")"
nu="$(norm_dest "$out_pub")"
[ "$np" = "$nu" ] && {
  printf 'signing: --out-private and --out-public-base64 resolve to the same path: %s\n' "$np" >&2
  exit 2
}
for f in "$np" "$nu"; do
  [ -L "$f" ] && {
    printf 'signing: refusing to write through a symlink: %s\n' "$f" >&2
    exit 2
  }
  [ -e "$f" ] && {
    printf 'signing: refusing to overwrite existing file: %s\n' "$f" >&2
    exit 2
  }
done

umask 077
TMPK="$(mktemp -d)"
pt=""
ut=""
trap 'rm -rf "$TMPK"; rm -f "$pt" "$ut"' EXIT INT TERM HUP
"$(sig_openssl)" genpkey -algorithm ed25519 -out "$TMPK/priv.pem" 2>/dev/null || {
  printf 'signing: key generation failed\n' >&2
  exit 1
}
chmod 600 "$TMPK/priv.pem"
pub_b64="$(sig_pub_b64_from_key "$TMPK/priv.pem")"
sig_is_valid_pub_b64 "$pub_b64" || {
  printf 'signing: generated an unexpected public key\n' >&2
  exit 1
}
sig_is_canonical_b64 "$pub_b64" || {
  printf 'signing: generated a noncanonical public key\n' >&2
  exit 1
}
printf '%s' "$pub_b64" >"$TMPK/pub.b64"

# Publish atomically and no-clobber: stage into a destination-local temp (same
# filesystem as the final path, so the link is atomic and never crosses a device),
# then hard-link into place (ln fails if the destination now exists), rolling back
# the private key if the public link fails so a partial pair is never left behind.
pt="$(mktemp "$(dirname "$np")/.keygen.XXXXXX")"
ut="$(mktemp "$(dirname "$nu")/.keygen.XXXXXX")"
cp "$TMPK/priv.pem" "$pt"
chmod 600 "$pt"
cp "$TMPK/pub.b64" "$ut"
ln "$pt" "$np" 2>/dev/null || {
  printf 'signing: private-key destination appeared: %s\n' "$np" >&2
  exit 1
}
if ! ln "$ut" "$nu" 2>/dev/null; then
  rm -f "$np"
  printf 'signing: public-key destination appeared: %s (rolled back the private key)\n' "$nu" >&2
  exit 1
fi
rm -f "$pt" "$ut"
printf 'signing: wrote private key %s (mode 600) and public key %s\n' "$np" "$nu" >&2
cat <<EOF
Trust-store entry (blessed/signing-trust-store/v1):

  "keys": {
    "$key_id": {
      "profile": "ed25519-detached-v1",
      "public_key_base64": "$pub_b64",
      "status": "active"
    }
  }
EOF
