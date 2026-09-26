#!/usr/bin/env bash
# signing-lib.sh — shared implementation for the blessed `signing` category.
#
# Implements the ed25519-detached-v1 profile (standards/signing/ed25519-detached.md):
# a detached Ed25519 signature over the EXACT bytes of a file, encoded as standard
# padded base64 on one line with no trailing newline. OpenSSL 3 is the v0.1 backend;
# consumers call sign.sh / verify.sh / keygen.sh, NEVER openssl directly.
#
# This file is SOURCED, not executed. Functions print an error to stderr and return
# non-zero on failure; the CLI wrappers turn that into an exit. No secret ever
# reaches argv, a log line, or `set -x` output.

SIG_PROFILE="ed25519-detached-v1"

# Fixed standard-base64 of the 12-byte Ed25519 SubjectPublicKeyInfo DER prefix
# (302a300506032b6570032100). Because the prefix is exactly 12 bytes (a multiple of
# 3), base64(prefix || raw32key) == this constant concatenated with base64(raw32key),
# so a raw 32-byte public key becomes an OpenSSL-loadable SPKI with no hex tooling.
SIG_SPKI_PREFIX_B64="MCowBQYDK2VwAyEA"

sig_openssl() { printf '%s' "${OPENSSL_BIN:-openssl}"; }

# Require OpenSSL >= 3; reject LibreSSL and anything unparseable.
sig_require_openssl3() {
  local bin ver major
  bin="$(sig_openssl)"
  command -v "$bin" >/dev/null 2>&1 || {
    printf 'signing: openssl not found: %s (set OPENSSL_BIN)\n' "$bin" >&2
    return 1
  }
  ver="$("$bin" version 2>/dev/null)" || {
    printf 'signing: cannot run %s version\n' "$bin" >&2
    return 1
  }
  case "$ver" in
    LibreSSL*)
      printf 'signing: LibreSSL is not supported; need OpenSSL >=3 (set OPENSSL_BIN)\n' >&2
      return 1
      ;;
  esac
  major="$(printf '%s' "$ver" | sed -n 's/^OpenSSL \([0-9][0-9]*\)\..*/\1/p')"
  [ -n "$major" ] || {
    printf 'signing: unrecognized openssl: %s\n' "$ver" >&2
    return 1
  }
  [ "$major" -ge 3 ] || {
    printf 'signing: need OpenSSL >=3 (got: %s)\n' "$ver" >&2
    return 1
  }
}

# Strict format checks — run BEFORE any base64 decode, because OpenSSL's decoder
# tolerates whitespace and we must not. Pure bash; reject url-safe chars, embedded
# or trailing whitespace, wrong length, and wrong padding.
sig_is_valid_sig_b64() { # exactly 88 chars, standard base64, "==" padding only
  case "$1" in *[!A-Za-z0-9+/=]*) return 1 ;; esac
  [ "${#1}" -eq 88 ] || return 1
  case "$1" in *==) ;; *) return 1 ;; esac
  local body="${1%==}"
  case "$body" in *=*) return 1 ;; esac
  [ "${#body}" -eq 86 ]
}
sig_is_valid_pub_b64() { # exactly 44 chars, standard base64, single "=" padding
  case "$1" in *[!A-Za-z0-9+/=]*) return 1 ;; esac
  [ "${#1}" -eq 44 ] || return 1
  case "$1" in *=) ;; *) return 1 ;; esac
  local body="${1%=}"
  case "$body" in *=*) return 1 ;; esac
  [ "${#body}" -eq 43 ]
}

# Reject NONCANONICAL base64: a valid length/alphabet/padding does not force the
# unused pad bits to zero, so two distinct encodings can decode to the same bytes.
# Decode then re-encode and require exact equality — canonical(decode(x)) == x iff
# x is already canonical. This makes each key/signature have exactly one encoding.
sig_is_canonical_b64() {
  local bin reenc
  bin="$(sig_openssl)"
  reenc="$(printf '%s' "$1" | "$bin" base64 -d -A 2>/dev/null | "$bin" base64 -A 2>/dev/null)"
  [ -n "$reenc" ] && [ "$reenc" = "$1" ]
}

# Raw 32-byte base64 public key -> PEM (SubjectPublicKeyInfo) on stdout.
sig_pub_b64_to_pem() {
  printf -- '-----BEGIN PUBLIC KEY-----\n%s%s\n-----END PUBLIC KEY-----\n' "$SIG_SPKI_PREFIX_B64" "$1"
}

# Raw 32-byte base64 public key extracted from a private-key PEM, on stdout.
sig_pub_b64_from_key() {
  local bin
  bin="$(sig_openssl)"
  "$bin" pkey -in "$1" -pubout -outform DER 2>/dev/null | tail -c 32 | "$bin" base64 -A
}

# Verify a detached signature. $1=pub_b64  $2=input_file  $3=sig_b64
# Returns 0 on a valid signature; a distinct non-zero code otherwise.
sig_verify_raw() {
  local pub_b64="$1" input="$2" sig_b64="$3" bin tmp pem sigraw rc
  sig_is_valid_pub_b64 "$pub_b64" || return 3
  sig_is_canonical_b64 "$pub_b64" || return 3
  sig_is_valid_sig_b64 "$sig_b64" || return 4
  sig_is_canonical_b64 "$sig_b64" || return 4
  [ -f "$input" ] || return 5
  bin="$(sig_openssl)"
  tmp="$(mktemp -d)" || return 6
  pem="$tmp/pub.pem"
  sigraw="$tmp/sig.raw"
  sig_pub_b64_to_pem "$pub_b64" >"$pem"
  if ! printf '%s' "$sig_b64" | "$bin" base64 -d -A >"$sigraw" 2>/dev/null; then
    rm -rf "$tmp"
    return 7
  fi
  [ "$(wc -c <"$sigraw" | tr -d ' ')" -eq 64 ] || {
    rm -rf "$tmp"
    return 8
  }
  "$bin" pkey -pubin -in "$pem" -noout 2>/dev/null || {
    rm -rf "$tmp"
    return 9
  } # malformed/incorrectly-wrapped key
  "$bin" pkeyutl -verify -pubin -inkey "$pem" -rawin -sigfile "$sigraw" -in "$input" >/dev/null 2>&1
  rc=$?
  rm -rf "$tmp"
  [ "$rc" -eq 0 ] || return 1
  return 0
}

# Sign a file with a private-key PEM. $1=key_pem  $2=input_file
# Prints the base64 signature (no trailing newline) on stdout; verifies before emitting.
sig_sign_file() {
  local key="$1" input="$2" bin tmp sigraw sig_b64 pub_b64
  bin="$(sig_openssl)"
  [ -f "$input" ] || {
    printf 'signing: input not found\n' >&2
    return 5
  }
  tmp="$(mktemp -d)" || return 6
  sigraw="$tmp/sig.raw"
  if ! "$bin" pkeyutl -sign -rawin -inkey "$key" -in "$input" -out "$sigraw" 2>/dev/null; then
    rm -rf "$tmp"
    printf 'signing: openssl sign failed\n' >&2
    return 7
  fi
  [ "$(wc -c <"$sigraw" | tr -d ' ')" -eq 64 ] || {
    rm -rf "$tmp"
    printf 'signing: signature is not 64 bytes\n' >&2
    return 8
  }
  sig_b64="$("$bin" base64 -A <"$sigraw")"
  sig_is_valid_sig_b64 "$sig_b64" || {
    rm -rf "$tmp"
    printf 'signing: produced malformed base64\n' >&2
    return 9
  }
  rm -rf "$tmp"
  # verify-after-sign through the real verify path
  pub_b64="$(sig_pub_b64_from_key "$key")"
  sig_verify_raw "$pub_b64" "$input" "$sig_b64" || {
    printf 'signing: verify-after-sign failed\n' >&2
    return 10
  }
  printf '%s' "$sig_b64"
}

# Resolve a key_id against a pinned trust store; print its public_key_base64.
# Fails closed on: bad store, unknown key_id, unsupported profile, revoked/other
# status, or malformed public key. $1=trust_store_json  $2=key_id
sig_resolve_trust_key() {
  local ts="$1" kid="$2" entry profile status pub
  command -v jq >/dev/null 2>&1 || {
    printf 'signing: jq required for trust-store resolution\n' >&2
    return 2
  }
  [ -f "$ts" ] || {
    printf 'signing: trust store not found: %s\n' "$ts" >&2
    return 2
  }
  jq -e . "$ts" >/dev/null 2>&1 || {
    printf 'signing: trust store is not valid JSON\n' >&2
    return 2
  }
  [ "$(jq -r '.schema // empty' "$ts")" = "blessed/signing-trust-store/v1" ] || {
    printf 'signing: bad trust-store schema\n' >&2
    return 2
  }
  entry="$(jq -c --arg k "$kid" '.keys[$k] // empty' "$ts")"
  [ -n "$entry" ] || {
    printf 'signing: unknown key_id: %s\n' "$kid" >&2
    return 2
  }
  profile="$(printf '%s' "$entry" | jq -r '.profile // empty')"
  [ "$profile" = "$SIG_PROFILE" ] || {
    printf 'signing: unsupported profile for %s: %s\n' "$kid" "$profile" >&2
    return 2
  }
  status="$(printf '%s' "$entry" | jq -r '.status // empty')"
  case "$status" in
    active | verify-only) ;;
    *)
      printf 'signing: key_id %s not usable for verification (status=%s)\n' "$kid" "$status" >&2
      return 2
      ;;
  esac
  pub="$(printf '%s' "$entry" | jq -r '.public_key_base64 // empty')"
  sig_is_valid_pub_b64 "$pub" || {
    printf 'signing: malformed public key for %s\n' "$kid" >&2
    return 2
  }
  printf '%s' "$pub"
}

# ── tauri-minisign-v1 (client-native artifact adapter) ───────────────────────
#
# A SEPARATE profile with its own resolver and verification path. It shares no
# code path with ed25519-detached-v1 beyond generic base64/OpenSSL helpers, so a
# key trusted for one profile can never be silently accepted for the other.
#
# Wire format (verified against production Tauri v2 output):
#   The .sig asset Tauri publishes is base64 of the WHOLE minisign document.
#   The document is four lines:
#     1  untrusted comment: ...
#     2  base64( alg[2] || key_id[8] || signature[64] )        = 74 bytes
#     3  trusted comment: ...
#     4  base64( global_signature[64] )
#   alg is "ED" (0x4544) = PREHASHED: the signature is over BLAKE2b-512(payload),
#   not over the payload bytes. Legacy "Ed" (0x4564, unprehashed) is NOT accepted.
#   key_id bytes are little-endian; minisign displays them reversed.
#   The global signature covers ( signature[64] || trusted_comment_text ), which
#   is what authenticates the trusted comment (timestamp + filename).
SIG_NATIVE_PROFILE="tauri-minisign-v1"

# Resolve a key_id in a pinned trust store for the NATIVE profile only.
# Fails closed on: bad store, unknown key_id, a key bound to a different profile,
# revoked/other status, or a malformed public key. $1=trust_store  $2=key_id
sig_native_resolve_trust_key() {
  local ts="$1" kid="$2" entry profile status pub
  command -v jq >/dev/null 2>&1 || {
    printf 'signing: jq required for trust-store resolution\n' >&2
    return 2
  }
  [ -f "$ts" ] || {
    printf 'signing: trust store not found: %s\n' "$ts" >&2
    return 2
  }
  jq -e . "$ts" >/dev/null 2>&1 || {
    printf 'signing: trust store is not valid JSON\n' >&2
    return 2
  }
  [ "$(jq -r '.schema // empty' "$ts")" = "blessed/signing-trust-store/v1" ] || {
    printf 'signing: bad trust-store schema\n' >&2
    return 2
  }
  entry="$(jq -c --arg k "$kid" '.keys[$k] // empty' "$ts")"
  [ -n "$entry" ] || {
    printf 'signing: unknown key_id: %s\n' "$kid" >&2
    return 2
  }
  profile="$(printf '%s' "$entry" | jq -r '.profile // empty')"
  [ "$profile" = "$SIG_NATIVE_PROFILE" ] || {
    printf 'signing: key_id %s is bound to profile %s, not %s\n' "$kid" "${profile:-<none>}" "$SIG_NATIVE_PROFILE" >&2
    return 2
  }
  status="$(printf '%s' "$entry" | jq -r '.status // empty')"
  case "$status" in
    active | verify-only) ;;
    *)
      printf 'signing: key_id %s not usable for verification (status=%s)\n' "$kid" "${status:-<none>}" >&2
      return 2
      ;;
  esac
  pub="$(printf '%s' "$entry" | jq -r '.public_key_base64 // empty')"
  sig_is_valid_pub_b64 "$pub" || {
    printf 'signing: malformed public key for %s\n' "$kid" >&2
    return 2
  }
  sig_is_canonical_b64 "$pub" || {
    printf 'signing: noncanonical public key encoding for %s\n' "$kid" >&2
    return 2
  }
  printf '%s' "$pub"
}

# Normalize a sidecar to a raw minisign document on stdout. Accepts either the
# base64-wrapped form Tauri publishes or an already-raw document. Fails closed on
# anything that is not a minisign document.
sig_native_read_document() {
  local f="$1" decoded
  decoded="$(sig_openssl_base64_d <"$f" 2>/dev/null || true)"
  case "$decoded" in
    "untrusted comment:"*)
      printf '%s\n' "$decoded"
      return 0
      ;;
  esac
  case "$(head -c 18 "$f" 2>/dev/null)" in
    "untrusted comment:")
      cat -- "$f"
      return 0
      ;;
  esac
  printf 'signing: not a minisign document (expected base64-wrapped or raw)\n' >&2
  return 1
}

sig_openssl_base64_d() { "$(sig_openssl)" base64 -d -A 2>/dev/null; }

# Uppercase hex key id from the 8 little-endian bytes at offset 2 of the blob.
sig_native_keyid_from_blob() {
  local blob="$1" hex rev i
  hex="$(printf '%s' "$blob" | sig_openssl_base64_d | dd bs=1 skip=2 count=8 2>/dev/null | od -An -tx1 | tr -d ' \n')"
  [ "${#hex}" -eq 16 ] || return 1
  rev=""
  i=16
  while [ "$i" -gt 0 ]; do
    rev="$rev${hex:$((i - 2)):2}"
    i=$((i - 2))
  done
  printf '%s' "$rev" | tr 'a-f' 'A-F'
}
