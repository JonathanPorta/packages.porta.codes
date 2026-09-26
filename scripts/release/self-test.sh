#!/usr/bin/env bash
# self-test.sh — conformance suite for the blessed `release` category. Proves
# deterministic assembly, schema + closure + on-disk recompute, and the full
# build → sign → validate flow through the signing category's CLI (API v1).
# Run standalone or via `make test`. Exit 0 = green; 1 = regression; 0 (skip) if
# jq or the signing category is unavailable.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/release/lib/release-lib.sh
. "$HERE/lib/release-lib.sh"
SIGNING="$HERE/../signing"

pass=0 fail=0
ok() {
  echo "  ✓ $1"
  pass=$((pass + 1))
}
no() {
  echo "  ✗ $1"
  fail=1
}
expect_rc() {
  local desc="$1" want="$2" rc
  shift 2
  "$@" >/dev/null 2>&1
  rc=$?
  if [ "$rc" -eq "$want" ]; then ok "$desc"; else no "$desc (rc=$rc, want $want)"; fi
}

# Fail by default if a prerequisite is missing, so a runner that loses jq or the
# signing category can't turn `make test` green without testing release. Skipping
# is a LOCAL-DEV override only; CI never sets it.
if ! command -v jq >/dev/null 2>&1 || [ ! -x "$SIGNING/sign.sh" ]; then
  if [ "${RELEASE_SELFTEST_ALLOW_SKIP:-}" = "1" ]; then
    echo "release self-test: jq or the signing category unavailable — SKIPPED (RELEASE_SELFTEST_ALLOW_SKIP=1)"
    exit 0
  fi
  echo "release self-test: jq + the signing category are REQUIRED but unavailable — FAIL (set RELEASE_SELFTEST_ALLOW_SKIP=1 for local dev only)" >&2
  exit 1
fi

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT INT TERM HUP
CD="$T/dist"
mkdir -p "$CD"
PLAN="$HERE/tests/fixtures/plan.json"

# fake payload referenced by the fixture plan
for a in DocSort_0.4.1_x64-setup.exe DocSort_0.4.1_universal.dmg DocSort_0.4.1_amd64.AppImage; do
  head -c 2048 /dev/zero | tr '\0' "$(printf '%s' "$a" | cut -c1)" >"$CD/$a"
  printf '{"bomFormat":"CycloneDX","for":"%s"}\n' "$a" >"$CD/$a.cdx.json"
done
printf '# DocSort 0.4.1\n\nPublic-safe notes.\n' >"$CD/release-notes-public.md"

# 1. plan validates
expect_rc "plan conforms to release-candidate-plan/v1" 0 "$HERE/validate-plan.sh" --plan "$PLAN"

# 2. build candidate
"$HERE/build-candidate.sh" --plan "$PLAN" --candidate-dir "$CD" --output "$CD/release-candidate.json" --builder ci >/dev/null 2>&1
if [ -f "$CD/release-candidate.json" ] && [ -f "$CD/provenance.json" ] && [ -f "$CD/SHA256SUMS" ]; then ok "build-candidate emits manifest + provenance + SHA256SUMS"; else no "build-candidate outputs"; fi

# 3. determinism: rebuild is byte-identical
cp "$CD/release-candidate.json" "$T/rc1.json"
rm -f "$CD/provenance.json" "$CD/SHA256SUMS"
"$HERE/build-candidate.sh" --plan "$PLAN" --candidate-dir "$CD" --output "$CD/release-candidate.json" --builder ci >/dev/null 2>&1
if diff -q "$T/rc1.json" "$CD/release-candidate.json" >/dev/null; then ok "rebuild is byte-identical (deterministic)"; else no "rebuild is byte-identical"; fi

# 3b. determinism is independent of locale
LC_ALL=C "$HERE/build-candidate.sh" --plan "$PLAN" --candidate-dir "$CD" --output "$T/rc-c.json" --builder ci >/dev/null 2>&1
if diff -q "$T/rc1.json" "$T/rc-c.json" >/dev/null; then ok "output is locale-independent"; else no "output is locale-independent"; fi

# 4. emitted candidate conforms to the packaged schema
if [ -z "$(rel_schema_validate "$CD/release-candidate.json" "$HERE/references/release-candidate.schema.json")" ]; then ok "candidate conforms to release-candidate/v1"; else no "candidate conforms to release-candidate/v1"; fi

# 5. packaged schema equals the normative source (no drift)
if diff -q "$HERE/references/release-candidate.schema.json" "$HERE/../../standards/releases/references/release-candidate.schema.json" >/dev/null 2>&1; then ok "packaged schema == normative standards/ copy"; else no "packaged schema == normative standards/ copy"; fi

# 5a. The packaged validator must be byte-identical to the repo's shared copy.
# The category ships its own so the released tarball is dependency-closed
# (blessed-cicd#252 F3); this control is what stops the two from drifting apart.
if diff -q "$HERE/lib/lib-json-schema.sh" "$HERE/../lib-json-schema.sh" >/dev/null 2>&1; then
  ok "packaged validator == shared scripts/lib-json-schema.sh"
else
  no "packaged validator == shared scripts/lib-json-schema.sh"
fi

# 5c. The packaged release-surfaces schema must match its normative original.
if diff -q "$HERE/references/release-surfaces.schema.json" "$HERE/../../standards/releases/references/release-surfaces.schema.json" >/dev/null 2>&1; then
  ok "packaged release-surfaces schema == normative standards/ copy"
else
  no "packaged release-surfaces schema == normative standards/ copy"
fi

# 5b. native updater signature overrides are an all-or-nothing semantic tuple.
# Drive the shipped helper itself so these controls cannot pass by duplicating
# its jq expression in the test.
jq '.artifacts[0] += {
  "signature":"DocSort_0.4.1_x64-setup.exe.sig",
  "signature_profile":"tauri-minisign-v1",
  "signature_key_id":"0329307E2A827219"
} | .files += [{
  "name":"DocSort_0.4.1_x64-setup.exe.sig",
  "role":"signature",
  "size":1,
  "sha256":"0000000000000000000000000000000000000000000000000000000000000000"
}]' "$CD/release-candidate.json" >"$T/native-complete.json"
if [ -z "$(rel_semantic_checks "$T/native-complete.json")" ]; then
  ok "complete native signature override accepted"
else
  no "complete native signature override accepted"
fi
for field in signature signature_profile signature_key_id; do
  jq --arg f "$field" 'del(.artifacts[0][$f])' "$T/native-complete.json" >"$T/native-missing-$field.json"
  out="$(rel_semantic_checks "$T/native-missing-$field.json")"
  case "$out" in
    *"incomplete artifact signature override:"*) ok "native signature override missing $field rejected" ;;
    *) no "native signature override missing $field rejected" ;;
  esac
done

# 6. validate pre-sign (no crypto): schema + closure + recompute
expect_rc "validate-candidate (pre-sign) passes" 0 "$HERE/validate-candidate.sh" --candidate-dir "$CD"

# 7. sign the manifest through the signing CLI, build a trust store, validate with verification
"$SIGNING/keygen.sh" --out-private "$T/key.pem" --out-public-base64 "$T/key.pub" --key-id docsort-2026-01 >/dev/null 2>&1
pub="$(cat "$T/key.pub")"
"$SIGNING/sign.sh" --profile ed25519-detached-v1 --input "$CD/release-candidate.json" --private-key-file "$T/key.pem" --output "$CD/release-candidate.json.sig" >/dev/null 2>&1
cat >"$T/trust.json" <<EOF
{"schema":"blessed/signing-trust-store/v1","keys":{"docsort-2026-01":{"profile":"ed25519-detached-v1","public_key_base64":"$pub","status":"active"}}}
EOF
expect_rc "validate-candidate with signature verifies" 0 "$HERE/validate-candidate.sh" --candidate-dir "$CD" --trust-store "$T/trust.json" --signing-dir "$SIGNING"

# 8. negatives
printf 'x' >>"$CD/DocSort_0.4.1_x64-setup.exe" # tamper an artifact on disk
expect_rc "on-disk artifact tamper rejected (recompute)" 1 "$HERE/validate-candidate.sh" --candidate-dir "$CD"
head -c 2048 /dev/zero | tr '\0' D >"$CD/DocSort_0.4.1_x64-setup.exe" # restore original bytes
# extra UNLISTED file in the candidate dir is rejected (closed set)
touch "$CD/EXTRA-unlisted.bin"
expect_rc "extra unlisted candidate file rejected (closed dir)" 1 "$HERE/validate-candidate.sh" --candidate-dir "$CD"
rm -f "$CD/EXTRA-unlisted.bin"
# listed artifact replaced by a symlink: recompute (-f) would follow + match the
# target bytes, but the closed-dir check rejects the symlink — proves the bypass
sym_art="DocSort_0.4.1_amd64.AppImage"
mv "$CD/$sym_art" "$T/ext-$sym_art"
ln -s "$T/ext-$sym_art" "$CD/$sym_art"
expect_rc "listed artifact replaced by a symlink rejected" 1 "$HERE/validate-candidate.sh" --candidate-dir "$CD"
rm -f "$CD/$sym_art"
mv "$T/ext-$sym_art" "$CD/$sym_art"
# extra empty directory rejected
mkdir "$CD/emptydir"
expect_rc "extra empty directory rejected" 1 "$HERE/validate-candidate.sh" --candidate-dir "$CD"
rmdir "$CD/emptydir"
# extra FIFO rejected
if mkfifo "$CD/afifo" 2>/dev/null; then
  expect_rc "extra FIFO rejected" 1 "$HERE/validate-candidate.sh" --candidate-dir "$CD"
  rm -f "$CD/afifo"
else
  ok "extra FIFO check skipped (mkfifo unavailable)"
fi
# extra trailing-newline filename rejected
nlf="$CD/"$'x\n'
if touch "$nlf" 2>/dev/null; then
  expect_rc "extra trailing-newline filename rejected" 1 "$HERE/validate-candidate.sh" --candidate-dir "$CD"
  rm -f "$nlf"
else
  ok "trailing-newline filename check skipped (filesystem refuses it)"
fi
# tamper the signed manifest (created_at) -> signature must fail
jq '.created_at = "2000-01-01T00:00:00Z"' "$CD/release-candidate.json" >"$T/tampered.json"
expect_rc "manifest tamper breaks the signature" 1 "$HERE/validate-candidate.sh" --candidate-dir "$CD" --candidate "$T/tampered.json" --trust-store "$T/trust.json" --signing-dir "$SIGNING"
# unknown key_id in the trust store
echo '{"schema":"blessed/signing-trust-store/v1","keys":{"other-key":{"profile":"ed25519-detached-v1","public_key_base64":"'"$pub"'","status":"active"}}}' >"$T/trust-bad.json"
expect_rc "unknown key_id rejected" 1 "$HERE/validate-candidate.sh" --candidate-dir "$CD" --trust-store "$T/trust-bad.json" --signing-dir "$SIGNING"
# signing API mismatch
mkdir -p "$T/fakesigning"
printf '2\n' >"$T/fakesigning/API_VERSION"
cp "$SIGNING/verify.sh" "$T/fakesigning/" 2>/dev/null || true
expect_rc "wrong signing API rejected" 1 "$HERE/validate-candidate.sh" --candidate-dir "$CD" --trust-store "$T/trust.json" --signing-dir "$T/fakesigning"

# 9. Runtime-native artifact signature adapter: assembly preserves the metadata
# and validation DISPATCHES on the artifact's own profile/key id.
#
# The failure this guards against is silent: verifying a Minisign sidecar with
# the envelope's ed25519 profile and manifest key checks the wrong cryptographic
# contract while still reporting a green candidate. So the controls below assert
# the actual argv each verifier received, not just the exit code.
ND="$T/native"
mkdir -p "$ND"
for a in App_1.0.0_x64-setup.exe App_1.0.0_amd64.AppImage; do
  head -c 512 /dev/zero | tr '\0' "$(printf '%s' "$a" | cut -c5)" >"$ND/$a"
done
printf '# App 1.0.0\n\nPublic-safe notes.\n' >"$ND/release-notes-public.md"
# native sidecar: opaque bytes (a Minisign document is NOT the 88-byte raw form)
printf 'untrusted comment: signature from tauri secret key\nRWQx...\ntrusted comment: ts\nAAAA\n' >"$ND/App_1.0.0_x64-setup.exe.sig"
# envelope-profile sidecar: a real ed25519-detached-v1 signature
"$SIGNING/sign.sh" --profile ed25519-detached-v1 --input "$ND/App_1.0.0_amd64.AppImage" \
  --private-key-file "$T/key.pem" --output "$ND/App_1.0.0_amd64.AppImage.sig" >/dev/null 2>&1

# Derive the native plan from the shipped fixture so it stays in step with the
# plan schema: two artifacts, artifact signatures REQUIRED, and one artifact
# declaring the native adapter under a key id distinct from the envelope's.
jq '.artifacts = [
      (.artifacts[0] | del(.sbom) | .id = "windows-x86-64-nsis"
        | .filename = "App_1.0.0_x64-setup.exe"
        | .signature_profile = "tauri-minisign-v1"
        | .signature_key_id = "tauri-updater-2026"),
      (.artifacts[2] | del(.sbom) | .id = "linux-x86-64-appimage"
        | .filename = "App_1.0.0_amd64.AppImage")
    ]
    | .signing.artifacts = "required"
    | .version = "1.0.0" | .tag = "v1.0.0"' \
  "$PLAN" >"$T/native-plan.json"
expect_rc "native plan conforms to release-candidate-plan/v1" 0 "$HERE/validate-plan.sh" --plan "$T/native-plan.json"
"$HERE/build-candidate.sh" --plan "$T/native-plan.json" --candidate-dir "$ND" --output "$ND/release-candidate.json" --builder ci >/dev/null 2>&1
if [ "$(jq -r '.artifacts[] | select(.id=="windows-x86-64-nsis") | "\(.signature_profile)|\(.signature_key_id)"' "$ND/release-candidate.json")" = "tauri-minisign-v1|tauri-updater-2026" ]; then
  ok "assembly preserves the artifact signature profile + key id from the plan"
else
  no "assembly preserves the artifact signature profile + key id from the plan"
fi
if [ "$(jq -r '.artifacts[] | select(.id=="linux-x86-64-appimage") | has("signature_profile")' "$ND/release-candidate.json")" = "false" ]; then
  ok "artifacts without an override inherit the envelope profile (no field emitted)"
else
  no "artifacts without an override inherit the envelope profile (no field emitted)"
fi
if [ -f "$ND/release-candidate.json" ] &&
  [ -z "$(rel_schema_validate "$ND/release-candidate.json" "$HERE/references/release-candidate.schema.json")" ] &&
  [ -z "$(rel_semantic_checks "$ND/release-candidate.json")" ]; then
  ok "native candidate is schema-valid and semantically closed"
else
  no "native candidate is schema-valid and semantically closed"
fi
"$SIGNING/sign.sh" --profile ed25519-detached-v1 --input "$ND/release-candidate.json" \
  --private-key-file "$T/key.pem" --output "$ND/release-candidate.json.sig" >/dev/null 2>&1

# Trust store carrying BOTH domains: the envelope key and a distinct native key.
cat >"$T/trust-native.json" <<EOF
{"schema":"blessed/signing-trust-store/v1","keys":{
  "docsort-2026-01":{"profile":"ed25519-detached-v1","public_key_base64":"$pub","status":"active"},
  "tauri-updater-2026":{"profile":"tauri-minisign-v1","public_key_base64":"$pub","status":"active"}}}
EOF

# Stub signing dir: both verifiers accept anything and record their argv, so the
# assertions below are about ROUTING, not about crypto.
STUB="$T/stubsigning"
mkdir -p "$STUB"
printf '1\n' >"$STUB/API_VERSION"
for v in verify verify-native; do
  cat >"$STUB/$v.sh" <<EOF
#!/usr/bin/env bash
printf '%s %s\n' "$v" "\$*" >>"$T/verify.log"
exit 0
EOF
  chmod +x "$STUB/$v.sh"
done

: >"$T/verify.log"
expect_rc "native candidate validates through the stub adapter" 0 "$HERE/validate-candidate.sh" \
  --candidate-dir "$ND" --trust-store "$T/trust-native.json" --signing-dir "$STUB"
if grep -q 'verify-native .*--profile tauri-minisign-v1' "$T/verify.log" &&
  grep -q 'verify-native .*--key-id tauri-updater-2026' "$T/verify.log" &&
  grep -q 'verify-native .*App_1.0.0_x64-setup.exe' "$T/verify.log"; then
  ok "native artifact is routed to the adapter with its OWN profile + key id"
else
  no "native artifact is routed to the adapter with its OWN profile + key id"
  cat "$T/verify.log"
fi
if grep -q 'verify .*App_1.0.0_x64-setup.exe' "$T/verify.log"; then
  no "native artifact must NOT also be verified as ed25519-detached-v1"
else
  ok "native artifact is not verified with the envelope profile"
fi
if grep -q 'verify .*--profile ed25519-detached-v1 .*App_1.0.0_amd64.AppImage.*--key-id docsort-2026-01' "$T/verify.log"; then
  ok "non-overriding artifact still inherits the envelope profile + key id"
else
  no "non-overriding artifact still inherits the envelope profile + key id"
  cat "$T/verify.log"
fi

# Negative controls — every unroutable case must fail CLOSED.
# (a) no adapter for the declared native profile
NOADAPT="$T/noadapter"
mkdir -p "$NOADAPT"
printf '1\n' >"$NOADAPT/API_VERSION"
cp "$STUB/verify.sh" "$NOADAPT/verify.sh"
expect_rc "missing native adapter fails closed" 1 "$HERE/validate-candidate.sh" \
  --candidate-dir "$ND" --trust-store "$T/trust-native.json" --signing-dir "$NOADAPT"
# (b) the native key id is absent from the trust store
expect_rc "native key id absent from the trust store rejected" 1 "$HERE/validate-candidate.sh" \
  --candidate-dir "$ND" --trust-store "$T/trust.json" --signing-dir "$STUB"
# (c) the key id exists but is bound to a DIFFERENT profile (key/profile confusion)
jq '.keys["tauri-updater-2026"].profile = "ed25519-detached-v1"' "$T/trust-native.json" >"$T/trust-crossed.json"
expect_rc "native key id bound to another profile rejected" 1 "$HERE/validate-candidate.sh" \
  --candidate-dir "$ND" --trust-store "$T/trust-crossed.json" --signing-dir "$STUB"
# (d) the key id exists with the right profile but is revoked
jq '.keys["tauri-updater-2026"].status = "revoked"' "$T/trust-native.json" >"$T/trust-revoked.json"
expect_rc "revoked native key rejected" 1 "$HERE/validate-candidate.sh" \
  --candidate-dir "$ND" --trust-store "$T/trust-revoked.json" --signing-dir "$STUB"
# (e) an adapter that REJECTS the sidecar fails the candidate
REJ="$T/rejsigning"
mkdir -p "$REJ"
printf '1\n' >"$REJ/API_VERSION"
cp "$STUB/verify.sh" "$REJ/verify.sh"
printf '#!/usr/bin/env bash\nexit 1\n' >"$REJ/verify-native.sh"
chmod +x "$REJ/verify-native.sh"
expect_rc "adapter rejection fails the candidate" 1 "$HERE/validate-candidate.sh" \
  --candidate-dir "$ND" --trust-store "$T/trust-native.json" --signing-dir "$REJ"
# (f) an unrecognized profile has no route at all
jq '(.artifacts[] | select(.id=="windows-x86-64-nsis") | .signature_profile) = "made-up-v9"' \
  "$ND/release-candidate.json" >"$T/unknown-profile.json"
expect_rc "unknown artifact signature profile fails closed" 1 "$HERE/validate-candidate.sh" \
  --candidate-dir "$ND" --candidate "$T/unknown-profile.json" --trust-store "$T/trust-native.json" --signing-dir "$STUB"
# (g) the real signing CLI cannot verify a native sidecar — the pre-dispatch
# behavior (envelope profile for every artifact) would have called exactly this.
expect_rc "native sidecar is not verifiable by the ed25519 CLI" 1 \
  bash "$SIGNING/verify.sh" --profile ed25519-detached-v1 \
  --input "$ND/App_1.0.0_x64-setup.exe" --signature "$ND/App_1.0.0_x64-setup.exe.sig" \
  --trust-store "$T/trust-native.json" --key-id docsort-2026-01
# End-to-end through the REAL adapter: the stub above proves ROUTING, this proves
# the routed-to verifier actually verifies. Uses the signing category's committed
# tauri-minisign-v1 known-answer vector as the artifact, so the whole chain —
# candidate assembly, dispatch on the declared profile, native verification — runs
# with no stubs anywhere.
NATFIX="$SIGNING/tests/fixtures/native"
if [ -f "$NATFIX/message.bin" ] && [ -x "$SIGNING/verify-native.sh" ]; then
  RD="$T/realnative"
  mkdir -p "$RD"
  cp "$NATFIX/message.bin" "$RD/message.bin"
  cp "$NATFIX/message.bin.sig" "$RD/message.bin.sig"
  printf '# App 1.0.0\n\nPublic-safe notes.\n' >"$RD/release-notes-public.md"
  jq '.artifacts = [
        (.artifacts[0] | del(.sbom) | .id = "native-vector"
          | .filename = "message.bin"
          | .platform = "any" | .install_kind = "other"
          | .signature_profile = "tauri-minisign-v1"
          | .signature_key_id = "0807060504030201")
      ]
      | .signing.artifacts = "required"
      | .version = "1.0.0" | .tag = "v1.0.0"' \
    "$PLAN" >"$T/real-native-plan.json"
  "$HERE/build-candidate.sh" --plan "$T/real-native-plan.json" --candidate-dir "$RD" \
    --output "$RD/release-candidate.json" --builder ci >/dev/null 2>&1
  "$SIGNING/sign.sh" --profile ed25519-detached-v1 --input "$RD/release-candidate.json" \
    --private-key-file "$T/key.pem" --output "$RD/release-candidate.json.sig" >/dev/null 2>&1
  natpub="$(jq -r '.keys["0807060504030201"].public_key_base64' "$NATFIX/trust-store-synthetic.json")"
  cat >"$T/trust-real-native.json" <<EOF
{"schema":"blessed/signing-trust-store/v1","keys":{
  "docsort-2026-01":{"profile":"ed25519-detached-v1","public_key_base64":"$pub","status":"active"},
  "0807060504030201":{"profile":"tauri-minisign-v1","public_key_base64":"$natpub","status":"active"}}}
EOF
  expect_rc "native artifact verifies end-to-end through the REAL adapter (no stubs)" 0 \
    "$HERE/validate-candidate.sh" --candidate-dir "$RD" --trust-store "$T/trust-real-native.json" --signing-dir "$SIGNING"
  # and the same candidate fails when the payload is mutated under the signature
  printf 'x' >>"$RD/message.bin"
  expect_rc "real adapter rejects a mutated native artifact" 1 \
    "$HERE/validate-candidate.sh" --candidate-dir "$RD" --trust-store "$T/trust-real-native.json" --signing-dir "$SIGNING"
  cp "$NATFIX/message.bin" "$RD/message.bin"
else
  no "real native adapter end-to-end control could not run (missing verify-native.sh or vector)"
fi

# (h) half-declared overrides never reach a candidate
rm -f "$ND/release-candidate.json" "$ND/release-candidate.json.sig" "$ND/provenance.json" "$ND/SHA256SUMS"
jq 'del(.artifacts[0].signature_key_id)' "$T/native-plan.json" >"$T/half-plan.json"
expect_rc "half-declared signature override is refused at assembly" 1 \
  "$HERE/build-candidate.sh" --plan "$T/half-plan.json" --candidate-dir "$ND" --output "$ND/release-candidate.json" --builder ci

echo "------------------------------------------------------------"
if [ "$fail" -eq 0 ]; then echo "release self-test: PASS ($pass checks)"; else echo "release self-test: FAIL"; fi
exit "$fail"
