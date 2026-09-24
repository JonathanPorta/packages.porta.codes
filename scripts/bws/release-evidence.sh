#!/usr/bin/env bash
# release-evidence.sh — decide whether the bws category may be PUBLISHED.
#
# Extracted from release-scripts.yml so tests execute the SHIPPED decision rather
# than a copy of it. An earlier version lived inline in the workflow while the
# test carried its own `gate()` reimplementation: neutering the production logic
# left every test green. A gate whose tests cannot fail with it is not a gate.
#
#   exit 0  evidence satisfied      -> publication permitted
#   exit 1  valid response, but evidence missing/insufficient -> WITHHOLD
#   exit 2  API/permission failure  -> FATAL, distinct from "no evidence"
#
# The 0/1/2 split is the point. Collapsing 2 into 1 would let a broken token or a
# missing `actions: read` look identical to a canary that simply never ran, and
# the release would be withheld for a reason nobody could diagnose — or worse,
# a future edit could treat "no evidence" as benign.
#
# Usage: release-evidence.sh <repo> <head-sha>
set -uo pipefail

REPO="${1:?usage: release-evidence.sh <repo> <head-sha>}"
SHA="${2:?usage: release-evidence.sh <repo> <head-sha>}"
WORKFLOW="${BWS_CANARY_WORKFLOW:-bws-loader-canary.yml}"

# Exact job names, one per OS. A count of two is NOT the property we need: two
# successes from the SAME os would satisfy a count while leaving a platform
# entirely unproven.
REQUIRED_JOBS=(
  "macos-latest · real secret round-trip"
  "ubuntu-latest · real secret round-trip"
)

fatal() {
  echo "::error title=Actions API unreadable::$*" >&2
  exit 2
}
withhold() {
  echo "::error title=bws WITHHELD::$*" >&2
  exit 1
}

api="repos/$REPO/actions"

# No `|| echo '{}'`. A failure here must terminate distinctly.
if ! runs="$(gh api "$api/workflows/$WORKFLOW/runs?event=workflow_dispatch&branch=master&head_sha=$SHA&status=completed")"; then
  fatal "could not query canary runs for $SHA (permissions? workflow absent?). This is NOT 'no evidence'."
fi
if ! rid="$(printf '%s' "$runs" | jq -r '[.workflow_runs[]? | select(.conclusion=="success")] | first | .id // empty')"; then
  fatal "canary run list was not parseable JSON"
fi
[ -n "$rid" ] || withhold "no completed successful workflow_dispatch canary on master at $SHA. Dispatch the canary from master, then re-run the release."

if ! jobs="$(gh api "$api/runs/$rid/jobs")"; then
  fatal "could not read jobs for canary run $rid — aborting rather than guessing."
fi

# Skipped jobs still produce a green WORKFLOW, so job-level conclusions are the
# only real evidence.
missing=""
for want in "${REQUIRED_JOBS[@]}"; do
  n="$(printf '%s' "$jobs" | jq --arg n "$want" \
    '[.jobs[]? | select(.name == $n) | select(.conclusion == "success")] | length')" ||
    fatal "could not evaluate jobs for run $rid"
  [ "${n:-0}" -ge 1 ] || missing="${missing}
      - ${want}"
done
[ -z "$missing" ] || withhold "canary run $rid is missing successful round-trip job(s):${missing}"

echo "publication evidence OK — canary run $rid proved both round-trip jobs at $SHA"
exit 0
