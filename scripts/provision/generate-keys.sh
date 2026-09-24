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
export GNUPGHOME="$OUT/.gnupg"
mkdir -m 700 "$GNUPGHOME"
YEAR="$(date -u +%Y)"

openpgp() { # uid, stem → fingerprint; writes stem.pub.asc (public) and stem.sec.asc (0600)
  gpg --batch --quiet --passphrase '' --quick-gen-key "$1" rsa4096 sign never 2>/dev/null
  local fpr
  fpr="$(gpg --batch --with-colons --list-keys "$1" 2>/dev/null | awk -F: '/^fpr:/{print $10; exit}')"
  gpg --batch --armor --export "$fpr" 2>/dev/null >"$OUT/$2.pub.asc"
  gpg --batch --armor --export-secret-keys "$fpr" 2>/dev/null >"$OUT/$2.sec.asc"
  chmod 600 "$OUT/$2.sec.asc"
  chmod 644 "$OUT/$2.pub.asc"
  printf '%s' "$fpr"
}

REPO_FPR="$(openpgp "packages.porta.codes repository signing $YEAR <packages@porta.codes>" repository)"
declare -A RPM_FPR
for p in kioskd corpus keysprout; do
  RPM_FPR[$p]="$(openpgp "$p RPM signing $YEAR <$p-rpm@porta.codes>" "$p-rpm")"
done
for p in corpus keysprout; do
  bash "$ROOT/scripts/signing/keygen.sh" --out-private "$OUT/$p-release.pem" --out-public-base64 "$OUT/$p-release.pub" \
    --key-id "$p-$YEAR-01" >/dev/null
  chmod 600 "$OUT/$p-release.pem"
  jq -n --arg k "$(cat "$OUT/$p-release.pub")" --arg id "$p-$YEAR-01" \
    '{schema: "blessed/signing-trust-store/v1", keys: {($id): {profile: "ed25519-detached-v1", public_key_base64: $k, status: "active"}}}' \
    >"$OUT/$p-trust-store.json"
done
rm -rf "$GNUPGHOME"

cat <<EOF
Generated in $OUT (private files 0600; nothing uploaded, nothing secret printed).

FINGERPRINTS — record these in the PR that installs the public halves
  repository key   $REPO_FPR
  kioskd RPM key   ${RPM_FPR[kioskd]}
  corpus RPM key   ${RPM_FPR[corpus]}
  keysprout RPM    ${RPM_FPR[keysprout]}
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

SECRETS — one BWS project + read-only "-ci" machine account + GitHub
Environment per authority domain. Run each bootstrap with --no-secret-values,
then paste the named file's CONTENTS into the secret in the Bitwarden web UI.

  In JonathanPorta/packages.porta.codes (Environments must exist first:
  repository-signing, candidate-ingest, repository-publication; allowed ref: main):
    scripts/bws/bootstrap.sh --app-name packages-porta-codes-repo-signing \\
      --secrets-list .bws/repository-signing.list --loader .github/actions/load-repository-signing/action.yml \\
      --project-id-file .bws/repository-signing.env --gh-environments repository-signing --no-secret-values
        → machine account packages-porta-codes-repo-signing-ci
        → PACKAGES_REPO_SIGNING_KEY = contents of $OUT/repository.sec.asc
    scripts/bws/bootstrap.sh --app-name packages-porta-codes-candidate-ingest \\
      --secrets-list .bws/candidate-ingest.list --loader .github/actions/load-candidate-ingest/action.yml \\
      --project-id-file .bws/candidate-ingest.env --gh-environments candidate-ingest --no-secret-values
        → machine account packages-porta-codes-candidate-ingest-ci
        → PACKAGES_CANDIDATE_READ_TOKEN = a fine-grained PAT created in the GitHub UI:
          Contents READ on JonathanPorta/kioskd, corpus and keysprout; nothing else

  In each producer repository (its release-ceremony PR adds the .bws list,
  loader and Environment named here):
    kioskd:    --app-name kioskd-rpm-signing     → kioskd-rpm-signing-ci,     KIOSKD_RPM_SIGNING_KEY    = $OUT/kioskd-rpm.sec.asc
    corpus:    --app-name corpus-rpm-signing     → corpus-rpm-signing-ci,     CORPUS_RPM_SIGNING_KEY    = $OUT/corpus-rpm.sec.asc
               --app-name corpus-release-signing → corpus-release-signing-ci, CORPUS_RELEASE_SIGNING_KEY = $OUT/corpus-release.pem
    keysprout: --app-name keysprout-rpm-signing     → keysprout-rpm-signing-ci,     KEYSPROUT_RPM_SIGNING_KEY    = $OUT/keysprout-rpm.sec.asc
               --app-name keysprout-release-signing → keysprout-release-signing-ci, KEYSPROUT_RELEASE_SIGNING_KEY = $OUT/keysprout-release.pem
    each: scripts/bws/bootstrap.sh --app-name <name> --secrets-list .bws/<domain>.list \\
            --loader .github/actions/load-<domain>/action.yml --project-id-file .bws/<domain>.env \\
            --gh-environments <domain> --no-secret-values

When every secret is pasted and verified by a dry workflow run: shred $OUT
  (rm -P on macOS, shred -u on Linux). Keep no other copy.
EOF
