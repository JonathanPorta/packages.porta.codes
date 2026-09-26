#!/usr/bin/env bash
# validate-plan.sh — validate a producer plan against blessed/release-candidate-plan/v1.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/release/lib/release-lib.sh
. "$HERE/lib/release-lib.sh"

usage() {
  echo "Usage: validate-plan.sh --plan PLAN.json" >&2
  exit 2
}

plan=""
while [ $# -gt 0 ]; do
  case "$1" in
    --plan)
      plan="${2:-}"
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
[ -f "$plan" ] || {
  printf 'release: plan not found: %s\n' "$plan" >&2
  exit 1
}
jq -e . "$plan" >/dev/null 2>&1 || {
  printf 'release: plan is not valid JSON\n' >&2
  exit 1
}

out="$(rel_schema_validate "$plan" "$HERE/references/candidate-plan.schema.json")"
if [ -n "$out" ]; then
  printf 'release: plan does not conform to blessed/release-candidate-plan/v1:\n%s\n' "$out" >&2
  exit 1
fi
# tag must be v + version (the schema can't express cross-field equality)
if [ "$(jq -r '.tag' "$plan")" != "v$(jq -r '.version' "$plan")" ]; then
  printf 'release: tag must equal "v"+version\n' >&2
  exit 1
fi
printf 'release: plan OK\n' >&2
