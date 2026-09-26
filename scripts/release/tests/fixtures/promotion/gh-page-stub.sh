#!/usr/bin/env bash
# A FAITHFUL `gh api --paginate --jq EXPR`: it applies the caller's own EXPR to
# each page ARRAY, exactly as gh does. Stubs that emit pre-projected objects
# hide a broken projection — which is how a snapshot that rejects every real
# GitHub branches response shipped with 238 green controls.
set -uo pipefail
expr=""
url=""
while [ $# -gt 0 ]; do
  case "$1" in
    --jq)
      expr="$2"
      shift 2
      ;;
    --paginate) shift ;;
    api) shift ;;
    *)
      [ -n "$url" ] || url="$1"
      shift
      ;;
  esac
done
case "$url" in
  *"/pulls"*) pages="${GHSTUB_PULL_PAGES:-}" ;;
  *"/branches"*) pages="${GHSTUB_BRANCH_PAGES:-}" ;;
  *) exit 1 ;;
esac
for pg in $pages; do
  [ -s "$pg" ] || continue
  jq -c "$expr" "$pg" || exit 1
done
exit 0
