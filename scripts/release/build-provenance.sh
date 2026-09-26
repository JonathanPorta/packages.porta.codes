#!/usr/bin/env bash
# build-provenance.sh — emit provenance.json (blessed/release-provenance/v1) from a
# candidate plan. Deterministic: all content comes from the plan + explicit args;
# no clock is read. `created_at` is the plan's.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/release/lib/release-lib.sh
. "$HERE/lib/release-lib.sh"

usage() {
  cat >&2 <<'EOF'
Usage: build-provenance.sh --plan PLAN.json --output provenance.json
                           [--builder ID] [--builder-run URL]
EOF
  exit 2
}

plan="" output="" builder="" run=""
while [ $# -gt 0 ]; do
  case "$1" in
    --plan)
      plan="${2:-}"
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
[ -n "$output" ] || usage
[ -f "$plan" ] || {
  printf 'release: plan not found: %s\n' "$plan" >&2
  exit 1
}

tool="$(cat "$HERE/VERSION" 2>/dev/null || echo 0.0.0)"
rel_build_provenance "$plan" "$tool" "$builder" "$run" >"$output"
printf 'release: wrote %s\n' "$output" >&2
