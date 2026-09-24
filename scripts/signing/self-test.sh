#!/usr/bin/env bash
# self-test.sh — conformance suite for the blessed `signing` category
# (ed25519-detached-v1). Run standalone or via the repo's `make test`. Proves the
# positive path AND every fail-closed negative from standards/signing/ed25519-detached.md.
# Exit 0 = all green; 1 = a conformance regression; 0 (skip) if OpenSSL 3 absent.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/signing/lib/signing-lib.sh
. "$HERE/lib/signing-lib.sh"

P="ed25519-detached-v1"
pass=0 fail=0
ok() {
  echo "  ✓ $1"
  pass=$((pass + 1))
}
no() {
  echo "  ✗ $1"
  fail=1
}
# expect_rc DESC WANT CMD...
expect_rc() {
  local desc="$1" want="$2" rc
  shift 2
  "$@" >/dev/null 2>&1
  rc=$?
  if [ "$rc" -eq "$want" ]; then ok "$desc"; else no "$desc (rc=$rc, want $want)"; fi
}

if ! sig_require_openssl3 2>/dev/null; then
  # Fail by default so a runner that loses OpenSSL 3 can't turn `make test` green
  # without testing signing. Skipping is a LOCAL-DEV override only; CI never sets it.
  if [ "${SIGNING_SELFTEST_ALLOW_SKIP:-}" = "1" ]; then
    echo "signing self-test: OpenSSL 3 unavailable — SKIPPED (SIGNING_SELFTEST_ALLOW_SKIP=1)"
    exit 0
  fi
  echo "signing self-test: OpenSSL 3 REQUIRED but unavailable — FAIL (set SIGNING_SELFTEST_ALLOW_SKIP=1 for local dev only)" >&2
  exit 1
fi

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT INT TERM HUP

# ── 1. known-answer vector (committed fixture): verify recorded sig+pub ──
FXPUB="$(cat "$HERE/tests/fixtures/public-key.base64")"
expect_rc "known-answer fixture verifies" 0 \
  "$HERE/verify.sh" --profile "$P" --input "$HERE/tests/fixtures/message.txt" \
  --signature "$HERE/tests/fixtures/message.txt.sig" --public-key-base64 "$FXPUB"

# ── 2. generated-key round trip (sign path, ephemeral key) ──
"$HERE/keygen.sh" --out-private "$T/k.pem" --out-public-base64 "$T/k.pub" --key-id self-test >/dev/null 2>&1
pub="$(cat "$T/k.pub")"
printf 'the exact candidate manifest bytes' >"$T/in"
"$HERE/sign.sh" --profile "$P" --input "$T/in" --private-key-file "$T/k.pem" --output "$T/in.sig" >/dev/null 2>&1
sig="$(cat "$T/in.sig")"
expect_rc "generated-key round trip verifies" 0 \
  "$HERE/verify.sh" --profile "$P" --input "$T/in" --signature "$T/in.sig" --public-key-base64 "$pub"

# ── 3. trust store: active + verify-only accepted, revoked/unknown rejected ──
cat >"$T/ts.json" <<EOF
{"schema":"blessed/signing-trust-store/v1","keys":{
  "active-key":{"profile":"ed25519-detached-v1","public_key_base64":"$pub","status":"active"},
  "rotated":{"profile":"ed25519-detached-v1","public_key_base64":"$pub","status":"verify-only"},
  "dead":{"profile":"ed25519-detached-v1","public_key_base64":"$pub","status":"revoked"}}}
EOF
tsv=("$HERE/verify.sh" --profile "$P" --input "$T/in" --signature "$T/in.sig" --trust-store "$T/ts.json" --key-id)
expect_rc "trust-store active key verifies" 0 "${tsv[@]}" active-key
expect_rc "trust-store verify-only key verifies" 0 "${tsv[@]}" rotated
expect_rc "trust-store revoked key rejected" 1 "${tsv[@]}" dead
expect_rc "trust-store unknown key_id rejected" 1 "${tsv[@]}" ghost

# unsupported profile inside the store
cat >"$T/badprof.json" <<EOF
{"schema":"blessed/signing-trust-store/v1","keys":{"k":{"profile":"rsa-pss","public_key_base64":"$pub","status":"active"}}}
EOF
expect_rc "store entry with unsupported profile rejected" 1 \
  "$HERE/verify.sh" --profile "$P" --input "$T/in" --signature "$T/in.sig" --trust-store "$T/badprof.json" --key-id k

# ── 4. payload / signature / key tampering ──
printf 'tampered payload' >"$T/in2"
expect_rc "changed payload rejected" 1 \
  "$HERE/verify.sh" --profile "$P" --input "$T/in2" --signature "$T/in.sig" --public-key-base64 "$pub"
# Flip the first char to a DIFFERENT valid base64 char, so the signature stays
# well-encoded but is cryptographically wrong — a guaranteed change (prepending a
# fixed 'A' is a no-op when the signature already starts with 'A').
if [ "${sig:0:1}" = "A" ]; then badsig="B${sig:1}"; else badsig="A${sig:1}"; fi
printf '%s' "$badsig" >"$T/badsig"
expect_rc "changed signature rejected" 1 \
  "$HERE/verify.sh" --profile "$P" --input "$T/in" --signature "$T/badsig" --public-key-base64 "$pub"
"$HERE/keygen.sh" --out-private "$T/k2.pem" --out-public-base64 "$T/k2.pub" >/dev/null 2>&1
expect_rc "wrong key rejected" 1 \
  "$HERE/verify.sh" --profile "$P" --input "$T/in" --signature "$T/in.sig" --public-key-base64 "$(cat "$T/k2.pub")"

# ── 5. wire-format negatives (rejected before decode) ──
{
  cat "$T/in.sig"
  printf '\n'
} >"$T/sig-nl"
expect_rc "trailing newline in sig rejected" 1 \
  "$HERE/verify.sh" --profile "$P" --input "$T/in" --signature "$T/sig-nl" --public-key-base64 "$pub"
printf '%s' "${sig%??}" >"$T/sig-short" # 86 bytes
expect_rc "wrong signature length rejected" 1 \
  "$HERE/verify.sh" --profile "$P" --input "$T/in" --signature "$T/sig-short" --public-key-base64 "$pub"
printf '%s' "-${sig:1}" >"$T/sig-urlsafe" # url-safe char, still 88 bytes
expect_rc "url-safe base64 in sig rejected" 1 \
  "$HERE/verify.sh" --profile "$P" --input "$T/in" --signature "$T/sig-urlsafe" --public-key-base64 "$pub"
expect_rc "unsupported --profile rejected" 2 \
  "$HERE/verify.sh" --profile "bogus" --input "$T/in" --signature "$T/in.sig" --public-key-base64 "$pub"
expect_rc "malformed public key (short) rejected" 1 \
  "$HERE/verify.sh" --profile "$P" --input "$T/in" --signature "$T/in.sig" --public-key-base64 "tooShort"

# ── 6. OpenSSL gate: LibreSSL and OpenSSL <3 fail clearly ──
# shellcheck disable=SC2016  # $1 is the FAKE script's arg, intentionally unexpanded
mkfake() {
  printf '#!/bin/sh\n[ "$1" = version ] && { echo "%s"; exit 0; }\nexit 1\n' "$1" >"$T/fake"
  chmod +x "$T/fake"
}
# gate DESC VERSION_STRING WANT(accept|reject)
gate() {
  local got=reject
  mkfake "$2"
  (OPENSSL_BIN="$T/fake" sig_require_openssl3) >/dev/null 2>&1 && got=accept
  if [ "$got" = "$3" ]; then ok "$1"; else no "$1 (got $got, want $3)"; fi
}
gate "LibreSSL rejected" "LibreSSL 3.3.6" reject
gate "OpenSSL <3 rejected" "OpenSSL 1.1.1w  11 Sep 2023" reject
gate "OpenSSL 3 accepted" "OpenSSL 3.0.0  7 Sep 2021" accept

# ── 7. key hygiene: temp key cleaned up, key material not leaked to logs ──
KT="$T/tmpcheck"
mkdir -p "$KT"
TMPDIR="$KT" "$HERE/sign.sh" --profile "$P" --input "$T/in" --private-key-file "$T/k.pem" --output "$T/in.sig3" >/dev/null 2>&1
if [ "$(find "$KT" -mindepth 1 | wc -l | tr -d ' ')" -eq 0 ]; then ok "temp key dir cleaned after success"; else no "temp key dir cleaned after success"; fi
mkdir -p "$KT"
printf 'not a key' >"$T/notkey.pem"
TMPDIR="$KT" "$HERE/sign.sh" --profile "$P" --input "$T/in" --private-key-file "$T/notkey.pem" --output "$T/nope.sig" >/dev/null 2>&1
if [ "$(find "$KT" -mindepth 1 | wc -l | tr -d ' ')" -eq 0 ]; then ok "temp key dir cleaned after failure"; else no "temp key dir cleaned after failure"; fi
errout="$("$HERE/sign.sh" --profile "$P" --input "$T/in" --private-key-file "$T/k.pem" --output "$T/in.sig4" 2>&1 >/dev/null)"
case "$errout" in *"PRIVATE KEY"* | *"BEGIN"*) no "private key not leaked to stderr" ;; *) ok "private key not leaked to stderr" ;; esac

# ── 8. hardening (security review) ──
# canonical base64: a noncanonical encoding of the SAME bytes is rejected even
# though it passes the length/alphabet/padding checks.
canon="$(head -c 43 </dev/zero | tr '\0' A)="
noncanon="$(head -c 42 </dev/zero | tr '\0' A)B="
if sig_is_valid_pub_b64 "$noncanon"; then ok "noncanonical passes the plain format check (so canonicalization matters)"; else no "noncanonical format precondition"; fi
if sig_is_canonical_b64 "$canon"; then ok "canonical base64 accepted"; else no "canonical base64 accepted"; fi
if sig_is_canonical_b64 "$noncanon"; then no "noncanonical base64 rejected"; else ok "noncanonical base64 rejected"; fi
# invalid --private-key-env name rejected BEFORE indirect expansion
expect_rc "invalid --private-key-env name rejected" 2 \
  "$HERE/sign.sh" --profile "$P" --input "$T/in" --private-key-env 'bad;name' --output "$T/x.sig"
# keygen safety: same path, overwrite, malformed key_id
expect_rc "keygen refuses same priv/pub path" 2 "$HERE/keygen.sh" --out-private "$T/same" --out-public-base64 "$T/same"
touch "$T/existing"
expect_rc "keygen refuses to overwrite a file" 2 "$HERE/keygen.sh" --out-private "$T/existing" --out-public-base64 "$T/np"
expect_rc "keygen rejects malformed key_id" 2 "$HERE/keygen.sh" --out-private "$T/kp" --out-public-base64 "$T/kpub" --key-id 'bad/id'

# ── 9. security review pass 2 ──
# Fix 1: --private-key-env is scrubbed BEFORE any child process. A delegating fake
# OPENSSL_BIN records if the secret var was visible when it ran.
real_ossl="$(command -v "${OPENSSL_BIN:-openssl}")"
# A fake OPENSSL_BIN that scans its COMPLETE environment for the private key on
# every invocation (not just one caller variable), then delegates to real openssl.
# shellcheck disable=SC2016  # $@ belongs to the generated fake script, not this one
printf '#!/bin/sh\nenv | grep -q "PRIVATE KEY" && printf leaked >>"%s"\nexec "%s" "$@"\n' "$T/leak" "$real_ossl" >"$T/fakeossl"
chmod +x "$T/fakeossl"
# (a) normal invocation: the env var is scrubbed before any child sees it
rm -f "$T/leak"
SIGN_SELFTEST_KEY="$(cat "$T/k.pem")"
export SIGN_SELFTEST_KEY
OPENSSL_BIN="$T/fakeossl" "$HERE/sign.sh" --profile "$P" --input "$T/in" --private-key-env SIGN_SELFTEST_KEY --output "$T/env.sig" >/dev/null 2>&1
if [ -f "$T/leak" ]; then no "private-key scrubbed before any child (whole-env scan)"; else ok "private-key scrubbed before any child (whole-env scan)"; fi
unset SIGN_SELFTEST_KEY
# (b) allexport: `bash -a` must not export the scratch value to children
rm -f "$T/leak"
SIGN_A_KEY="$(cat "$T/k.pem")"
export SIGN_A_KEY
OPENSSL_BIN="$T/fakeossl" bash -a "$HERE/sign.sh" --profile "$P" --input "$T/in" --private-key-env SIGN_A_KEY --output "$T/a.sig" >/dev/null 2>&1 || true
if [ -f "$T/leak" ]; then no "bash -a does not export the private key to children"; else ok "bash -a does not export the private key to children"; fi
unset SIGN_A_KEY
# (c) a pre-exported internal scratch var is de-exported before the PEM is assigned
rm -f "$T/leak"
__blessed_signing_private_key_value="$(cat "$T/k.pem")"
export __blessed_signing_private_key_value
OPENSSL_BIN="$T/fakeossl" "$HERE/sign.sh" --profile "$P" --input "$T/in" --private-key-file "$T/k.pem" --output "$T/pe.sig" >/dev/null 2>&1 || true
if [ -f "$T/leak" ]; then no "pre-exported internal scratch var is de-exported"; else ok "pre-exported internal scratch var is de-exported"; fi
unset __blessed_signing_private_key_value
# Fix 6: output refusal + --force + directory rejection
"$HERE/sign.sh" --profile "$P" --input "$T/in" --private-key-file "$T/k.pem" --output "$T/o1.sig" >/dev/null 2>&1
expect_rc "sign refuses an existing output without --force" 2 "$HERE/sign.sh" --profile "$P" --input "$T/in" --private-key-file "$T/k.pem" --output "$T/o1.sig"
expect_rc "sign --force replaces a regular output" 0 "$HERE/sign.sh" --profile "$P" --input "$T/in" --private-key-file "$T/k.pem" --output "$T/o1.sig" --force
mkdir -p "$T/adir"
expect_rc "sign refuses a directory output" 2 "$HERE/sign.sh" --profile "$P" --input "$T/in" --private-key-file "$T/k.pem" --output "$T/adir"
# Fix 2: keygen rejects lexical alias and symlinked-parent collisions
expect_rc "keygen rejects a lexical-alias collision (./x)" 2 "$HERE/keygen.sh" --out-private "$T/alias" --out-public-base64 "$T/./alias"
mkdir -p "$T/realdir"
ln -s realdir "$T/linkdir"
expect_rc "keygen rejects a symlinked-parent collision" 2 "$HERE/keygen.sh" --out-private "$T/realdir/kk" --out-public-base64 "$T/linkdir/kk"

# Gate 1 (pass 3): duplicate --private-key-env rejected
expect_rc "duplicate --private-key-env rejected" 2 \
  "$HERE/sign.sh" --profile "$P" --input "$T/in" --private-key-env A --private-key-env B --output "$T/dup.sig"
# Gate 1 (pass 3): bash -x does not leak the private key (set +x disables tracing first)
SIGN_XTRACE_KEY="$(cat "$T/k.pem")"
export SIGN_XTRACE_KEY
bash -x "$HERE/sign.sh" --profile "$P" --input "$T/in" --private-key-env SIGN_XTRACE_KEY --output "$T/xt.sig" 2>"$T/xtrace" >/dev/null || true
if LC_ALL=C grep -qE 'PRIVATE KEY|BEGIN|END' "$T/xtrace"; then no "bash -x does not leak the private key"; else ok "bash -x does not leak the private key"; fi
unset SIGN_XTRACE_KEY

# ── tauri-minisign-v1 native adapter ────────────────────────────────────────
# The adapter verifies a DIFFERENT cryptographic contract than the envelope
# profile: minisign "ED" = Ed25519 over a BLAKE2b-512 prehash, with a second
# signature binding the trusted comment. Every control below asserts one field
# of that contract, because a verifier that silently checks the wrong thing
# still exits 0.
VN="$HERE/verify-native.sh"
NF="$HERE/tests/fixtures/native"
NP="tauri-minisign-v1"
NKID="0807060504030201"
NSTORE="$NF/trust-store-synthetic.json"

expect_rc "native: known-answer vector verifies (base64-wrapped, as Tauri ships)" 0 \
  "$VN" --profile "$NP" --input "$NF/message.bin" --signature "$NF/message.bin.sig" \
  --trust-store "$NSTORE" --key-id "$NKID"
expect_rc "native: the same document raw (unwrapped) verifies" 0 \
  "$VN" --profile "$NP" --input "$NF/message.bin" --signature "$NF/message.bin.minisig" \
  --trust-store "$NSTORE" --key-id "$NKID"
expect_rc "native: legacy unprehashed \"Ed\" algorithm is rejected" 1 \
  "$VN" --profile "$NP" --input "$NF/message.bin" --signature "$NF/message.bin.legacy-ed.sig" \
  --trust-store "$NSTORE" --key-id "$NKID"

# Mutations. Each rewrites exactly one field of a known-good document.
NT="$T/native"
mkdir -p "$NT"
"${OPENSSL_BIN:-openssl}" base64 -d -A <"$NF/message.bin.sig" >"$NT/doc"
cp "$NF/message.bin" "$NT/message.bin"
rewrap() { # $1=doc -> base64-wrapped sidecar on stdout
  base64 <"$1" | tr -d '\n'
}

# (a) payload mutated -> prehash changes -> signature no longer covers it
printf 'x' >>"$NT/message.bin"
expect_rc "native: mutated payload rejected" 1 \
  "$VN" --profile "$NP" --input "$NT/message.bin" --signature "$NF/message.bin.sig" \
  --trust-store "$NSTORE" --key-id "$NKID"
cp "$NF/message.bin" "$NT/message.bin"

# (b) signature bytes mutated (flip a byte inside the 64-byte signature)
python3 - "$NT/doc" "$NT/sig-mut" <<'EOF'
import base64,sys
d=open(sys.argv[1],'rb').read().split(b'\n')
blob=bytearray(base64.b64decode(d[1]))
blob[20]^=0x01
d[1]=base64.b64encode(bytes(blob))
open(sys.argv[2],'wb').write(b'\n'.join(d))
EOF
rewrap "$NT/sig-mut" >"$NT/sig-mut.sig"
expect_rc "native: mutated signature bytes rejected" 1 \
  "$VN" --profile "$NP" --input "$NF/message.bin" --signature "$NT/sig-mut.sig" \
  --trust-store "$NSTORE" --key-id "$NKID"

# (c) key id inside the document mutated -> no longer matches the declared id
python3 - "$NT/doc" "$NT/kid-mut" <<'EOF'
import base64,sys
d=open(sys.argv[1],'rb').read().split(b'\n')
blob=bytearray(base64.b64decode(d[1]))
blob[2]^=0xff
d[1]=base64.b64encode(bytes(blob))
open(sys.argv[2],'wb').write(b'\n'.join(d))
EOF
rewrap "$NT/kid-mut" >"$NT/kid-mut.sig"
expect_rc "native: signature key id not matching the declared key id rejected" 1 \
  "$VN" --profile "$NP" --input "$NF/message.bin" --signature "$NT/kid-mut.sig" \
  --trust-store "$NSTORE" --key-id "$NKID"

# (d) trusted comment mutated -> global signature no longer covers it
sed 's/^trusted comment: .*/trusted comment: timestamp:0\tfile:evil.bin/' "$NT/doc" >"$NT/tc-mut"
rewrap "$NT/tc-mut" >"$NT/tc-mut.sig"
expect_rc "native: mutated trusted comment rejected (global signature)" 1 \
  "$VN" --profile "$NP" --input "$NF/message.bin" --signature "$NT/tc-mut.sig" \
  --trust-store "$NSTORE" --key-id "$NKID"

# (e) global signature mutated
python3 - "$NT/doc" "$NT/gs-mut" <<'EOF'
import base64,sys
d=open(sys.argv[1],'rb').read().split(b'\n')
g=bytearray(base64.b64decode(d[3]))
g[0]^=0x01
d[3]=base64.b64encode(bytes(g))
open(sys.argv[2],'wb').write(b'\n'.join(d))
EOF
rewrap "$NT/gs-mut" >"$NT/gs-mut.sig"
expect_rc "native: mutated global signature rejected" 1 \
  "$VN" --profile "$NP" --input "$NF/message.bin" --signature "$NT/gs-mut.sig" \
  --trust-store "$NSTORE" --key-id "$NKID"

# (f) truncated / non-minisign sidecar
printf 'not a minisign document\n' >"$NT/junk.sig"
expect_rc "native: non-minisign sidecar rejected" 1 \
  "$VN" --profile "$NP" --input "$NF/message.bin" --signature "$NT/junk.sig" \
  --trust-store "$NSTORE" --key-id "$NKID"

# Profile binding: the SAME key is also registered under ed25519-detached-v1 in
# the fixture store. Resolving it for the native profile must refuse it.
# Same key id, same key bytes, but registered for the ENVELOPE profile: the
# native resolver must refuse it rather than verify across profiles.
jq '.keys[$k].profile = "ed25519-detached-v1"' --arg k "$NKID" "$NSTORE" >"$NT/crossed.json"
expect_rc "native: key bound to another profile is refused" 1 \
  "$VN" --profile "$NP" --input "$NF/message.bin" --signature "$NF/message.bin.sig" \
  --trust-store "$NT/crossed.json" --key-id "$NKID"
expect_rc "native: unknown key id refused" 1 \
  "$VN" --profile "$NP" --input "$NF/message.bin" --signature "$NF/message.bin.sig" \
  --trust-store "$NSTORE" --key-id 00AABBCCDDEEFF11
expect_rc "native: wrong --profile refused" 2 \
  "$VN" --profile ed25519-detached-v1 --input "$NF/message.bin" --signature "$NF/message.bin.sig" \
  --trust-store "$NSTORE" --key-id "$NKID"
# revoked key
jq '.keys[$k].status = "revoked"' --arg k "$NKID" "$NSTORE" >"$NT/revoked.json"
expect_rc "native: revoked key refused" 1 \
  "$VN" --profile "$NP" --input "$NF/message.bin" --signature "$NF/message.bin.sig" \
  --trust-store "$NT/revoked.json" --key-id "$NKID"
# the ed25519 CLI must not accept a minisign document either (no cross-profile drift)
expect_rc "native: the ed25519 CLI refuses a minisign document" 1 \
  "$HERE/verify.sh" --profile ed25519-detached-v1 --input "$NF/message.bin" \
  --signature "$NF/message.bin.sig" --trust-store "$NSTORE" --key-id "$NKID"

# Trust-store SCHEMA: both recognized profiles validate, anything else does not.
SCHEMA="$HERE/../../standards/signing/references/trust-store.schema.json"
if [ -f "$SCHEMA" ] && [ -f "$HERE/../lib-json-schema.sh" ]; then
  # shellcheck source=scripts/lib-json-schema.sh
  . "$HERE/../lib-json-schema.sh"
  for prof in ed25519-detached-v1 tauri-minisign-v1; do
    jq --arg p "$prof" '{schema:"blessed/signing-trust-store/v1",keys:{"k":{profile:$p,public_key_base64:"u61rs5pBdivDtdKKa4rg2e1ImjbBr88sTejFk4sCqrI=",status:"active"}}}' -n >"$NT/store-$prof.json"
    if [ -z "$(json_schema_validate_file "$NT/store-$prof.json" "$SCHEMA")" ]; then
      ok "trust-store schema accepts profile $prof"
    else
      no "trust-store schema accepts profile $prof"
    fi
  done
  # Since blessed-cicd#251 the validator descends into schema-valued
  # additionalProperties, so the closed profile set is enforced by the SCHEMA as
  # well as at resolution time. Assert both: they are independent defenses and
  # either one regressing is a real loss.
  jq '.keys[$k].profile = "made-up-v9"' --arg k "$NKID" "$NSTORE" >"$NT/store-bogus.json"
  if [ -n "$(json_schema_validate_file "$NT/store-bogus.json" "$SCHEMA")" ]; then
    ok "trust-store schema rejects an unrecognized profile (closed set)"
  else
    no "trust-store schema rejects an unrecognized profile (closed set)"
  fi
  expect_rc "unrecognized profile refused by the native resolver (closed set)" 1 \
    "$VN" --profile "$NP" --input "$NF/message.bin" --signature "$NF/message.bin.sig" \
    --trust-store "$NT/store-bogus.json" --key-id "$NKID"
  expect_rc "unrecognized profile refused by the envelope resolver (closed set)" 1 \
    "$HERE/verify.sh" --profile ed25519-detached-v1 --input "$NF/message.bin" \
    --signature "$NF/message.bin.sig" --trust-store "$NT/store-bogus.json" --key-id "$NKID"
else
  no "trust-store schema controls could not run (missing schema or validator)"
fi

# Production vector: the real DocSort v0.4.3 updater sidecar. Its payload is a
# 10 MB release asset, so the artifact is fetched on demand and the control is
# SKIPPED (loudly) when unavailable — never silently passed.
LIVE_ART="${SIGNING_NATIVE_LIVE_ARTIFACT:-}"
if [ -n "$LIVE_ART" ] && [ -f "$LIVE_ART" ]; then
  expect_rc "native: REAL docsort v0.4.3 production sidecar verifies" 0 \
    "$VN" --profile "$NP" --input "$LIVE_ART" --signature "$NF/docsort-0.4.3-app.tar.gz.sig" \
    --trust-store "$NF/trust-store.json" --key-id 0329307E2A827219
else
  echo "  ~ SKIPPED production vector (set SIGNING_NATIVE_LIVE_ARTIFACT=/path/to/DocSort.app.tar.gz)"
fi

echo "------------------------------------------------------------"
if [ "$fail" -eq 0 ]; then echo "signing self-test: PASS ($pass checks)"; else echo "signing self-test: FAIL"; fi
exit "$fail"
