#!/usr/bin/env bash
# verify-category-manifest.sh — closed-set MANIFEST.sha256 verifier that SHIPS
# INSIDE the bws category, so a consumer installed only from the released tarball
# (scripts/bws/ + scripts/signing/, WITHOUT the source-tree scripts/manifest.sh)
# can still verify category integrity at rotation preflight and inside the smoke
# workflow before the private signing key is ever loaded.
#
# This is the verify half of the source-side scripts/manifest.sh, with identical
# semantics — generation stays a source/dev concern (`make scripts-manifest`).
# Verification fails on:
#   * a listed file whose contents changed (drift);
#   * an EXTRA file present but not listed (closed-set violation);
#   * a listed file that is missing;
#   * any symlink or non-file/dir entry anywhere in the category;
#   * an unsafe filename that cannot be represented in the manifest.
#
# Usage: verify-category-manifest.sh <category-dir>
set -euo pipefail

die() {
  printf 'verify-category-manifest: %s\n' "$*" >&2
  exit 1
}

sha256() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$@"; else shasum -a 256 "$@"; fi
}

# Relative paths (no leading ./) of all regular files except the TOP-LEVEL
# manifest, sorted. `! -path ./MANIFEST.sha256` (not `! -name`) so a NESTED file
# named MANIFEST.sha256 cannot escape the listing while still shipping.
list_files() {
  find . -type f ! -path ./MANIFEST.sha256 | sed 's#^\./##' | LC_ALL=C sort
}

reject_symlinks() {
  local links
  links="$(find . -type l | sed 's#^\./##')"
  [ -z "$links" ] || die "symlinks are not allowed in a category: $(printf '%s' "$links" | tr '\n' ' ')"
}

# Reject anything that cannot be represented unambiguously in a newline/space-
# delimited manifest, and any non-file/dir entry that would ship but never hash.
reject_unsafe_names() {
  local n path rel component old_ifs
  n="$(find . ! -type f ! -type d ! -type l | wc -l | tr -d ' ')"
  [ "$n" -eq 0 ] || die "special (non-file/dir) entry in category"
  while IFS= read -r -d '' path; do
    rel="${path#./}"
    [ -n "$rel" ] || continue
    case "$rel" in
      *[!A-Za-z0-9._/+-]*) die "unsafe character in category path: $(printf '%q' "$rel")" ;;
    esac
    old_ifs="$IFS"
    IFS='/'
    # shellcheck disable=SC2086  # intentional split of the path on '/'
    for component in $rel; do
      case "$component" in
        -*) die "category path component starts with '-': $rel" ;;
      esac
    done
    IFS="$old_ifs"
  done < <(find . -print0)
}

verify() {
  local dir="$1"
  [ -d "$dir" ] || die "not a directory: $dir"
  [ -f "$dir/MANIFEST.sha256" ] || die "no MANIFEST.sha256 in $dir"
  (
    cd "$dir" || exit 1
    reject_symlinks
    reject_unsafe_names
    # 1. every listed file exists and matches its recorded hash
    sha256 -c MANIFEST.sha256 >/dev/null 2>&1 || die "DRIFT in $dir — a listed file is missing or changed"
    # 2. closed set — the listed names must equal the actual names exactly
    local listed actual
    listed="$(awk '{ $1=""; sub(/^ +/, ""); print }' MANIFEST.sha256 | LC_ALL=C sort)"
    actual="$(list_files)"
    if [ "$listed" != "$actual" ]; then
      printf 'verify-category-manifest: CLOSED-SET violation in %s (< listed, > actual):\n' "$dir" >&2
      diff <(printf '%s\n' "$listed") <(printf '%s\n' "$actual") >&2 || true
      exit 1
    fi
  )
}

dir="${1:-}"
[ -n "$dir" ] || die "usage: verify-category-manifest.sh <category-dir>"
verify "$dir"
