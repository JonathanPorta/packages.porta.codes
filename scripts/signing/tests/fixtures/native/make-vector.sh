#!/usr/bin/env bash
# make-vector.sh — regenerate the committed tauri-minisign-v1 known-answer vector.
#
# The production DocSort sidecar is the authoritative real-world vector, but its
# payload is a 10 MB release asset that cannot live in this repo. This builds an
# equivalent small vector in the SAME wire format so the offline suite can mutate
# every field (payload, prehash, signature, trusted comment, global signature,
# key id, algorithm) without a network fetch.
#
# Deterministic in format, not in key material: rerunning mints a fresh keypair
# and rewrites the fixtures. Run it only to rotate or repair the vector.
#
#   bash scripts/signing/tests/fixtures/native/make-vector.sh
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OPENSSL="${OPENSSL_BIN:-openssl}"

KEY_ID_HEX_LE="0102030405060708" # little-endian bytes; displayed reversed
KEY_ID_DISPLAY="0807060504030201"
TRUSTED_COMMENT="timestamp:1700000000	file:message.bin"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

printf 'blessed/signing tauri-minisign-v1 known-answer test vector\n' >"$HERE/message.bin"

"$OPENSSL" genpkey -algorithm ed25519 -out "$tmp/key.pem" 2>/dev/null
"$OPENSSL" pkey -in "$tmp/key.pem" -pubout -outform DER -out "$tmp/pub.der" 2>/dev/null
# raw 32-byte key = DER SPKI minus its fixed 12-byte prefix
dd if="$tmp/pub.der" bs=1 skip=12 count=32 2>/dev/null >"$tmp/pub.raw"
pub_b64="$("$OPENSSL" base64 -A <"$tmp/pub.raw")"

# payload signature is over the BLAKE2b-512 prehash (algorithm "ED")
"$OPENSSL" dgst -blake2b512 -binary "$HERE/message.bin" >"$tmp/hash.bin"
"$OPENSSL" pkeyutl -sign -inkey "$tmp/key.pem" -rawin -in "$tmp/hash.bin" -out "$tmp/sig.raw"

emit_blob() { # $1=alg literal -> base64 of alg||key_id||signature
  {
    printf '%s' "$1"
    printf '%s' "$KEY_ID_HEX_LE" | xxd -r -p
    cat "$tmp/sig.raw"
  } | "$OPENSSL" base64 -A
}

# global signature covers ( signature || trusted comment text )
{
  cat "$tmp/sig.raw"
  printf '%s' "$TRUSTED_COMMENT"
} >"$tmp/global.msg"
"$OPENSSL" pkeyutl -sign -inkey "$tmp/key.pem" -rawin -in "$tmp/global.msg" -out "$tmp/global.raw"
global_b64="$("$OPENSSL" base64 -A <"$tmp/global.raw")"

write_doc() { # $1=outfile  $2=signature blob b64
  {
    printf 'untrusted comment: signature from blessed test key\n'
    printf '%s\n' "$2"
    printf 'trusted comment: %s\n' "$TRUSTED_COMMENT"
    printf '%s\n' "$global_b64"
  } >"$1"
}

# raw document (accepted form) and the base64-wrapped form Tauri publishes
write_doc "$HERE/message.bin.minisig" "$(emit_blob ED)"
"$OPENSSL" base64 -A <"$HERE/message.bin.minisig" >"$HERE/message.bin.sig"
# legacy unprehashed algorithm — must be REJECTED
write_doc "$tmp/legacy.minisig" "$(emit_blob Ed)"
"$OPENSSL" base64 -A <"$tmp/legacy.minisig" >"$HERE/message.bin.legacy-ed.sig"

cat >"$HERE/trust-store-synthetic.json" <<EOF
{
  "schema": "blessed/signing-trust-store/v1",
  "keys": {
    "$KEY_ID_DISPLAY": {
      "profile": "tauri-minisign-v1",
      "public_key_base64": "$pub_b64",
      "status": "active",
      "comment": "synthetic tauri-minisign-v1 known-answer vector"
    }
  }
}
EOF

printf 'wrote vector for key id %s\n' "$KEY_ID_DISPLAY"
