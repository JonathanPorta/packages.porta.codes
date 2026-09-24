#!/usr/bin/env bash
# A STATEFUL offline remote. Unlike the record-only fake, this one keeps branch
# and PR state in a directory that survives between processes, so recovery and
# resume can be exercised across separate apply invocations — which is the only
# way to test "a failure between push and PR creation is resumable".
#
#   FAKE_REMOTE_STATE  directory holding branch/PR state (required)
#   FAKE_REMOTE_FAIL   command name to fail: snapshot | push | create-pr
#   FAKE_REMOTE_CREATE_THEN_FAIL=1  create the PR, then report failure — the
#                      "server did it, client never heard" case
#   FAKE_REMOTE_MOVE_BRANCH=<sha>   move the stored branch before answering,
#                      simulating a concurrent actor
set -uo pipefail
st="${FAKE_REMOTE_STATE:?FAKE_REMOTE_STATE is required}"
mkdir -p "$st"
br="$st/branch"
pr="$st/pr"
log="$st/log"
printf '%s\n' "$*" >>"$log"
cmd="${1:-}"

[ -z "${FAKE_REMOTE_MOVE_BRANCH:-}" ] || printf '%s\n' "$FAKE_REMOTE_MOVE_BRANCH" >"$br"

# Fail the snapshot only once the branch exists, i.e. the POST-push read —
# failing every snapshot would abort before anything was pushed, which is a
# different (and already safe) case.
# Fail the FINAL snapshot only: the create has already happened, so this is the
# "PR may or may not exist and we cannot tell" case.
if [ "${FAKE_REMOTE_FAIL:-}" = "snapshot-after-create" ] && [ "$cmd" = "snapshot" ] &&
  [ -s "$pr" ]; then
  printf 'fake-remote: forced failure for the post-publication snapshot\n' >&2
  exit 1
fi
if [ "${FAKE_REMOTE_FAIL:-}" = "snapshot-after-push" ] && [ "$cmd" = "snapshot" ] &&
  [ -s "$br" ]; then
  printf 'fake-remote: forced failure for the post-push snapshot\n' >&2
  exit 1
fi
if [ "${FAKE_REMOTE_FAIL:-}" = "$cmd" ] && [ "${FAKE_REMOTE_CREATE_THEN_FAIL:-}" != "1" ]; then
  printf 'fake-remote: forced failure for %s\n' "$cmd" >&2
  exit 1
fi

case "$cmd" in
  snapshot)
    or="$2"
    pre="$3"
    b=""
    [ -f "$br" ] && b="$(cat "$br")"
    n=""
    [ -f "$pr" ] && n="$(cat "$pr")"
    jq -n --arg or "$or" --arg pre "$pre" --arg b "$b" --arg n "$n" \
      --arg base "${FAKE_REMOTE_BASE:-}" '{
        schema: "blessed/pr-state-snapshot/v1", repo: $or,
        query: { head_ref_prefix: $pre, states: ["OPEN","CLOSED","MERGED"] },
        pull_requests: (if $n == "" then [] else
          [{number: ($n|tonumber), state: "OPEN", head_repo: $or, head_ref: ($pre + "0.4.3"),
            head_sha: $b, base_repo: $or, base_ref: "main", base_sha: $base}] end),
        branches: (if $b == "" then [] else [{name: ($pre + "0.4.3"), sha: $b}] end)
      }'
    ;;
  push)
    # Create-only, like the shipped lease: never overwrite an existing ref.
    if [ -f "$br" ] && [ -n "$(cat "$br")" ] && [ "$(cat "$br")" != "$4" ]; then
      printf 'fake-remote: refusing to overwrite %s\n' "$(cat "$br")" >&2
      exit 1
    fi
    printf '%s\n' "$4" >"$br"
    ;;
  create-pr)
    [ -f "$br" ] && [ "$(cat "$br")" = "$7" ] || {
      printf 'fake-remote: branch is not at the expected sha\n' >&2
      exit 1
    }
    [ -s "$pr" ] && {
      printf 'fake-remote: a PR already exists\n' >&2
      exit 1
    }
    printf '%s\n' "${FAKE_REMOTE_PR_NUMBER:-91}" >"$pr"
    if [ "${FAKE_REMOTE_CREATE_THEN_FAIL:-}" = "1" ]; then
      printf 'fake-remote: PR created, then the client lost the response\n' >&2
      exit 1
    fi
    ;;
  *)
    printf 'fake-remote: unknown command %s\n' "$cmd" >&2
    exit 2
    ;;
esac
exit 0
