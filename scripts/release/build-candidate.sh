#!/usr/bin/env bash
# build-candidate.sh — assemble a complete candidate from an explicit plan.
#
# Reads blessed/release-candidate-plan/v1, verifies every referenced file under
# --candidate-dir, computes sizes + SHA-256, generates provenance.json + SHA256SUMS,
# and writes a byte-deterministic release-candidate.json (blessed/release-candidate/v1).
# NO cryptography here — sign the emitted manifest separately with signing/sign.sh.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/release/lib/release-lib.sh
. "$HERE/lib/release-lib.sh"

usage() {
  cat >&2 <<'EOF'
Usage: build-candidate.sh --plan PLAN.json --candidate-dir DIR \
                          --output DIR/release-candidate.json \
                          [--builder ID] [--builder-run URL]

Verifies the plan's referenced files exist under --candidate-dir, then writes
provenance.json + SHA256SUMS into DIR and the deterministic release-candidate.json
to --output. Sign it afterwards with signing/sign.sh; validate with validate-candidate.sh.
EOF
  exit 2
}

plan="" cdir="" output="" builder="" run=""
while [ $# -gt 0 ]; do
  case "$1" in
    --plan)
      plan="${2:-}"
      shift 2
      ;;
    --candidate-dir)
      cdir="${2:-}"
      shift 2
      ;;
    --output)
      output="${2:-}"
      shift 2
      ;;
    --builder)
      builder="${2:-}"
      shift 2
      ;;
    --builder-run)
      run="${2:-}"
      shift 2
      ;;
    -h | --help) usage ;;
    *)
      printf 'release: unexpected arg: %s\n' "$1" >&2
      usage
      ;;
  esac
done
[ -n "$plan" ] || usage
[ -n "$cdir" ] || usage
[ -n "$output" ] || usage
[ -f "$plan" ] || {
  printf 'release: plan not found: %s\n' "$plan" >&2
  exit 1
}
[ -d "$cdir" ] || {
  printf 'release: candidate dir not found: %s\n' "$cdir" >&2
  exit 1
}
command -v jq >/dev/null 2>&1 || {
  printf 'release: jq required\n' >&2
  exit 1
}

# Validate the plan against its schema before trusting it.
if ! bash "$HERE/validate-plan.sh" --plan "$plan" >/dev/null 2>&1; then
  bash "$HERE/validate-plan.sh" --plan "$plan" >&2 || true
  printf 'release: plan failed schema validation\n' >&2
  exit 1
fi

tool="$(cat "$HERE/VERSION" 2>/dev/null || echo 0.0.0)"
[ -L "$output" ] && {
  printf 'release: refusing to write through a symlink: %s\n' "$output" >&2
  exit 2
}
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT INT TERM HUP
rel_build_candidate "$plan" "$cdir" "$tool" "$builder" "$run" >"$tmp"
mv -f "$tmp" "$output"
printf 'release: wrote %s (+ provenance.json, SHA256SUMS in %s)\n' "$output" "$cdir" >&2
