#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Canonical pin file, with the legacy name kept as a fallback for the duration of
# the rename (blessed-cicd scripts/INSTALL.md names .blessed-scripts-version).
VERSION_FILE="$REPO_ROOT/scripts/.blessed-scripts-version"
[[ -f "$VERSION_FILE" ]] || VERSION_FILE="$REPO_ROOT/scripts/.bws-scripts-version"

[[ -f "$VERSION_FILE" ]] || {
  echo "ERROR: no scripts/.blessed-scripts-version (or legacy .bws-scripts-version)" >&2
  exit 1
}

# shellcheck disable=SC1090
. "$VERSION_FILE"

BCICD_REPO_SLUG="${BCICD_REPO_SLUG:-JonathanPorta/blessed-cicd}"
TMP_DIR="$(mktemp -d -t blessed-scripts.XXXXXX)"
trap 'rm -rf "$TMP_DIR"' EXIT

sync_category() {
  local cat="$1"
  local version="$2"
  local tag="$3"
  local archive="${cat}-v${version}.tar.gz"

  echo "==> scripts/$cat ← $tag"
  gh release download "$tag" \
    --repo "$BCICD_REPO_SLUG" \
    --pattern "$archive" \
    --dir "$TMP_DIR" \
    --clobber

  [[ -f "$TMP_DIR/$archive" ]] || {
    echo "ERROR: expected release asset $archive from $BCICD_REPO_SLUG@$tag" >&2
    exit 1
  }

  rm -rf "$REPO_ROOT/scripts/$cat"
  mkdir -p "$REPO_ROOT/scripts"
  tar -xzf "$TMP_DIR/$archive" -C "$REPO_ROOT/scripts"
  (cd "$REPO_ROOT/scripts/$cat" && shasum -a 256 -c MANIFEST.sha256)
}

sync_category bws "$BWS_VERSION" "$BWS_TAG"
sync_category signing "$SIGNING_VERSION" "$SIGNING_TAG"
sync_category release "$RELEASE_VERSION" "$RELEASE_TAG"
