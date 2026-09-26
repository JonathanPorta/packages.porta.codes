#!/usr/bin/env bash
# generate-keys.sh OUT_DIR — generate, LOCALLY, every signing key the pilot is
# missing, and print only what an operator needs to install them: fingerprints,
# the public halves' destinations, and the exact BWS bootstrapper commands.
#
#   repository key    OpenPGP RSA 4096, sign-only primary — signs InRelease,
#                     Release.gpg and repomd.xml.asc (this repository)
#   RPM keys          OpenPGP RSA 4096 per producer — native RPM signatures
#                     (blessed linux-packaging LP-9: RSA ≥ 3072, v4)
#                     for kioskd, corpus and keysprout
#   candidate keys    Ed25519 (blessed signing keygen.sh) for corpus and
#                     keysprout, which have no candidate signing key yet.
#                     kioskd's exists and is reused (keys/candidates/kioskd.json).
#
# Every private file is written 0600 into OUT_DIR (created 0700, must not
# exist). Nothing is uploaded, nothing secret is printed, no existing key is
# touched or rotated. The operator pastes each private file's contents into its
# Bitwarden secret in the web UI (bootstrap --no-secret-values), never into a
# terminal command line or a chat, then shreds OUT_DIR.
#
# Exit: 0 generated · 2 tooling/usage.
set -euo pipefail
OUT="${1:?usage: generate-keys.sh OUT_DIR (must not exist)}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
for t in gpg jq openssl; do command -v "$t" >/dev/null 2>&1 || {
  echo "generate-keys: $t is required" >&2
  exit 2
}; done
[ ! -e "$OUT" ] || {
  echo "generate-keys: $OUT exists; refusing to write into it" >&2
  exit 2
}
umask 077
mkdir -m 700 "$OUT"
# A SHORT private GNUPGHOME: gpg-agent's socket lives inside it, and a long
# path (macOS temp or scratch directories) exceeds the socket path limit, which
# makes key generation fail. It is removed on exit, with its agent.
GNUPGHOME="$(mktemp -d /tmp/ppcgpg.XXXXXX)"
export GNUPGHOME
chmod 700 "$GNUPGHOME"
cleanup() {
  gpgconf --kill gpg-agent >/dev/null 2>&1 || true
  rm -rf "${GNUPGHOME:?}"
}
trap cleanup EXIT
YEAR="$(date -u +%Y)"

openpgp() { # uid, stem → fingerprint; writes stem.pub.asc (public) and stem.sec.asc (0600)
  gpg --batch --quiet --passphrase '' --quick-gen-key "$1" rsa4096 sign never >/dev/null 2>"$GNUPGHOME/err" || {
    echo "generate-keys: gpg could not generate $2: $(tail -2 "$GNUPGHOME/err")" >&2
    exit 2
  }
  local fpr
  fpr="$(gpg --batch --with-colons --list-keys "$1" 2>/dev/null | awk -F: '/^fpr:/{print $10; exit}')"
  [ "${#fpr}" = 40 ] || {
    echo "generate-keys: no fingerprint for $2" >&2
    exit 2
  }
  gpg --batch --armor --export "$fpr" >"$OUT/$2.pub.asc"
  gpg --batch --armor --export-secret-keys "$fpr" >"$OUT/$2.sec.asc"
  chmod 600 "$OUT/$2.sec.asc"
  chmod 644 "$OUT/$2.pub.asc"
  if [ ! -s "$OUT/$2.pub.asc" ] || [ ! -s "$OUT/$2.sec.asc" ]; then
    echo "generate-keys: $2 was not exported" >&2
    exit 2
  fi
  printf '%s' "$fpr"
}

REPO_FPR="$(openpgp "packages.porta.codes repository signing $YEAR <packages@porta.codes>" repository)"
# Plain variables, not an associative array: macOS ships bash 3.2.
KIOSKD_FPR="$(openpgp "kioskd RPM signing $YEAR <kioskd-rpm@porta.codes>" kioskd-rpm)"
CORPUS_FPR="$(openpgp "corpus RPM signing $YEAR <corpus-rpm@porta.codes>" corpus-rpm)"
KEYSPROUT_FPR="$(openpgp "keysprout RPM signing $YEAR <keysprout-rpm@porta.codes>" keysprout-rpm)"
for p in corpus keysprout; do
  bash "$ROOT/scripts/signing/keygen.sh" --out-private "$OUT/$p-release.pem" --out-public-base64 "$OUT/$p-release.pub" \
    --key-id "$p-$YEAR-01" >/dev/null
  chmod 600 "$OUT/$p-release.pem"
  jq -n --arg k "$(cat "$OUT/$p-release.pub")" --arg id "$p-$YEAR-01" \
    '{schema: "blessed/signing-trust-store/v1", keys: {($id): {profile: "ed25519-detached-v1", public_key_base64: $k, status: "active"}}}' \
    >"$OUT/$p-trust-store.json"
done

cat <<EOF
Generated in $OUT (private files 0600; nothing uploaded, nothing secret printed).

FINGERPRINTS — record these in the PR that installs the public halves
  repository key   $REPO_FPR
  kioskd RPM key   $KIOSKD_FPR
  corpus RPM key   $CORPUS_FPR
  keysprout RPM    $KEYSPROUT_FPR
  corpus candidate key id corpus-$YEAR-01, keysprout candidate key id keysprout-$YEAR-01 (Ed25519)

PUBLIC HALVES — commit in THIS repository
  cp $OUT/repository.pub.asc     keys/repository.asc
  cp $OUT/kioskd-rpm.pub.asc     keys/kioskd-rpm.asc
  cp $OUT/corpus-rpm.pub.asc     keys/corpus-rpm.asc
  cp $OUT/keysprout-rpm.pub.asc  keys/keysprout-rpm.asc
  cp $OUT/corpus-trust-store.json     keys/candidates/corpus.json
  cp $OUT/keysprout-trust-store.json  keys/candidates/keysprout.json
  and set the fingerprints in inventory/layout.json (repository_key, producer_keys).
  Producers commit their own public halves too (RPM key for LP-9 verification,
  trust store for candidate validation) in their release-ceremony PRs.

SECRETS — install each private file ONLY through the Bitwarden web UI, following
PROVISIONING.md step by step (directory, bootstrapper command, machine account
and Environment for every domain). Never paste a private file into a terminal
command, a chat or a commit.

  $OUT/repository.sec.asc       → PACKAGES_REPO_SIGNING_KEY      (packages.porta.codes-repo-signing)
  $OUT/kioskd-rpm.sec.asc       → KIOSKD_RPM_SIGNING_KEY         (kioskd-rpm-signing)
  $OUT/corpus-rpm.sec.asc       → CORPUS_RPM_SIGNING_KEY         (corpus-rpm-signing)
  $OUT/keysprout-rpm.sec.asc    → KEYSPROUT_RPM_SIGNING_KEY      (keysprout-rpm-signing)
  $OUT/corpus-release.pem       → CORPUS_RELEASE_SIGNING_KEY     (corpus-release-signing)
  $OUT/keysprout-release.pem    → KEYSPROUT_RELEASE_SIGNING_KEY  (keysprout-release-signing)

When every secret is pasted and verified by a dry workflow run: shred $OUT
  (rm -P on macOS, shred -u on Linux). Keep no other copy.
EOF
