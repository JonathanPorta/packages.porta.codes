#!/usr/bin/env bash
# bws-app-name.sh — the default BWS identity is packages.porta.codes whatever
# the checkout directory is called, and explicit domain overrides still win.
# Runs the real `make bws-bootstrap` entry point in --dry-run mode (no BWS, no
# GitHub, no token) from a copy whose directory has another name.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
W="$(mktemp -d)"
trap 'rm -rf "$W"' EXIT
pass=0 fail=0
ok() {
  echo "  ✓ $1"
  pass=$((pass + 1))
}
no() {
  echo "  ✗ $1"
  fail=$((fail + 1))
}
C="$W/some-other-checkout-name"
mkdir -p "$C"
rsync -a --exclude .terraform "$ROOT/" "$C/" # .git included: a real checkout, only its directory name differs
field() { sed -n "s/^  $1 *//p" | head -1; }
out="$(cd "$C" && make -s bws-bootstrap ARGS="--dry-run" 2>&1)"
if [ "$(printf '%s\n' "$out" | field 'BWS project name')" = packages.porta.codes ] &&
  [ "$(printf '%s\n' "$out" | field 'BWS machine acct')" = packages.porta.codes-ci ]; then
  ok "the default domain is packages.porta.codes / packages.porta.codes-ci from a checkout named $(basename "$C")"
else
  no "the default identity followed the checkout name"
  printf '%s\n' "$out" | grep -E 'Application|BWS project name|machine acct' | sed 's/^/      /'
fi
out="$(cd "$C" && make -s bws-bootstrap APP_NAME=packages.porta.codes-repo-signing \
  ARGS="--secrets-list .bws/repository-signing.list --project-id-file .bws/repository-signing.env --gh-environments repository-signing --dry-run" 2>&1)"
if [ "$(printf '%s\n' "$out" | field 'BWS project name')" = packages.porta.codes-repo-signing ] &&
  [ "$(printf '%s\n' "$out" | field 'BWS machine acct')" = packages.porta.codes-repo-signing-ci ]; then
  ok "an explicit domain override (repo-signing) still wins"
else
  no "the explicit domain override was not honoured"
  printf '%s\n' "$out" | grep -E 'BWS project name|machine acct' | sed 's/^/      /'
fi
echo "bws-app-name: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
