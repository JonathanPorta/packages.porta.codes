#!/usr/bin/env bash
# Offline stand-in for the publication adapter. Records what apply asked for so
# the upsert contract can be asserted without a network, a remote, or gh.
#   FAKE_ADAPTER_LOG       file to append each invocation to
#   FAKE_ADAPTER_FAIL      command name that should fail (exercises error paths)
#   FAKE_ADAPTER_SNAPSHOT  file whose contents `snapshot` returns
#   FAKE_ADAPTER_BODY      file to copy the submitted PR body into
set -uo pipefail
log="${FAKE_ADAPTER_LOG:-/dev/null}"
printf '%s\n' "$*" >>"$log"
if [ "${FAKE_ADAPTER_FAIL:-}" = "${1:-}" ]; then
  printf 'fake-adapter: forced failure for %s\n' "$1" >&2
  exit 1
fi
# The fake enforces the same EXPECTED_SHA contract as the shipped adapter, so a
# control can prove apply passes the right commit rather than merely that it
# passes something.
case "${1:-}" in
  push) [ -n "${4:-}" ] || {
    printf 'fake-adapter: push needs EXPECTED_SHA\n' >&2
    exit 2
  } ;;
  create-pr) [ -n "${7:-}" ] || {
    printf 'fake-adapter: create-pr needs EXPECTED_SHA\n' >&2
    exit 2
  } ;;
  update-pr) [ -n "${5:-}" ] || {
    printf 'fake-adapter: update-pr needs EXPECTED_SHA\n' >&2
    exit 2
  } ;;
esac
case "${1:-}" in
  snapshot)
    if [ -n "${FAKE_ADAPTER_BRANCH_REPO:-}" ]; then
      # Stateful like the real remote: the branch does not exist until this run
      # pushes it, and the PR does not exist until create-pr is called.
      # Reporting either earlier would look like a concurrent race.
      h="$(git -C "$FAKE_ADAPTER_BRANCH_REPO" rev-parse HEAD)"
      b="${FAKE_ADAPTER_BRANCH_BASE:-}"
      pushed=0
      created=0
      grep -q '^push ' "$log" 2>/dev/null && pushed=1
      grep -q '^create-pr ' "$log" 2>/dev/null && created=1
      # RECOVERY SHAPE. With FAKE_ADAPTER_EXISTING_HEAD the branch and its PR
      # already exist at that head before this run pushes anything, and move to
      # the pushed commit afterwards — the state a recovery actually meets.
      # Without it the branch only appears after a push, which made a recovery
      # control pass while no push had occurred.
      if [ -n "${FAKE_ADAPTER_EXISTING_HEAD:-}" ]; then
        created=1
        if [ "$pushed" = "0" ]; then h="$FAKE_ADAPTER_EXISTING_HEAD"; fi
        pushed=1
      fi
      jq -n --arg pre "$3" --arg h "$h" --arg or "$2" --arg b "$b" \
        --argjson c "$created" --argjson pushed "$pushed" \
        '{schema:"blessed/pr-state-snapshot/v1",repo:$or,
          query:{head_ref_prefix:$pre,states:["OPEN","CLOSED","MERGED"]},
          pull_requests:(if $c == 1 then
            [{number:77,state:"OPEN",head_repo:$or,head_ref:($pre+"0.4.3"),head_sha:$h,
              base_repo:$or,base_ref:"main",base_sha:$b}] else [] end),
          branches:(if $pushed == 1 then [{name:($pre+"0.4.3"),sha:$h}] else [] end)}'
    elif [ -n "${FAKE_ADAPTER_PR_REPO:-}" ]; then
      # Report an existing PR at the receiver's CURRENT head. The commit apply
      # is publishing does not exist when the test starts, so a static fixture
      # cannot name it.
      h="$(git -C "$FAKE_ADAPTER_PR_REPO" rev-parse HEAD)"
      jq -n --arg pre "$3" --arg h "$h" --arg b "${FAKE_ADAPTER_PR_BASE:-}" \
        --argjson n "${FAKE_ADAPTER_PR_NUMBER:-42}" --arg or "$2" \
        '{schema:"blessed/pr-state-snapshot/v1",repo:$or,
          query:{head_ref_prefix:$pre,states:["OPEN","CLOSED","MERGED"]},
          pull_requests:[{number:$n,state:"OPEN",head_repo:$or,head_ref:($pre+"0.4.3"),
            head_sha:$h,base_repo:$or,base_ref:"main",base_sha:$b}],
          branches:[{name:($pre+"0.4.3"),sha:$h}]}'
    elif [ -n "${FAKE_ADAPTER_SNAPSHOT_AFTER_PUSH:-}" ]; then
      # Clean before the push, the supplied document afterwards — so a control
      # can target the post-push read without tripping the pre-push race guard.
      if grep -q '^push ' "$log" 2>/dev/null; then
        cat "$FAKE_ADAPTER_SNAPSHOT_AFTER_PUSH"
      else
        printf '{"schema":"blessed/pr-state-snapshot/v1","repo":"%s","query":{"head_ref_prefix":"%s","states":["OPEN","CLOSED","MERGED"]},"pull_requests":[],"branches":[]}\n' "$2" "$3"
      fi
    elif [ -n "${FAKE_ADAPTER_SNAPSHOT:-}" ]; then cat "$FAKE_ADAPTER_SNAPSHOT"; else
      printf '{"schema":"blessed/pr-state-snapshot/v1","repo":"%s","query":{"head_ref_prefix":"%s","states":["OPEN","CLOSED","MERGED"]},"pull_requests":[],"branches":[]}\n' "$2" "$3"
    fi
    ;;
  create-pr) [ -z "${FAKE_ADAPTER_BODY:-}" ] || cp "$6" "$FAKE_ADAPTER_BODY" ;;
  update-pr) [ -z "${FAKE_ADAPTER_BODY:-}" ] || cp "$4" "$FAKE_ADAPTER_BODY" ;;
esac
case "${1:-}" in
esac
exit 0
