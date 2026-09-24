#!/usr/bin/env bash
# gh-pr-adapter.sh — the credentialed publication adapter for apply's upsert.
#
# Apply never runs git or gh for remote work directly; it calls an adapter with
# this fixed contract, so the state machine is exercisable offline against a
# fake. This is the real one, for a CI job configured to publish promotion PRs.
#
#   snapshot   OWNER_REPO HEAD_REF_PREFIX   -> blessed/pr-state-snapshot/v1 JSON
#   push       REPO_DIR BRANCH EXPECTED_SHA
#   create-pr  OWNER_REPO BRANCH BASE_REF TITLE BODY_FILE EXPECTED_SHA
#   update-pr  OWNER_REPO BRANCH BODY_FILE EXPECTED_SHA
#
# EXPECTED_SHA is the exact commit apply prepared and verified. Both mutating
# commands re-read the remote ref before touching GitHub and refuse if it is
# anything else.
#
# HONEST LIMIT: that read and the create/edit are SEPARATE API operations.
# GitHub exposes no compare-and-create for pull requests, so another writer can
# move the ref between them. This narrows the window; it does not close it, and
# the post-publication read-back detects such a move only after the fact. Safe
# operation therefore assumes a SERIALIZED WRITER for promotion branches — a
# protected ref, or a single publishing job — which is an explicit Project C
# adoption precondition, not something this tooling can manufacture.
#
# It creates or updates exactly one PR and NEVER approves, merges, or closes
# one. Interactive agent sessions must not run this; rules/09 permits it only
# inside a trusted automation workflow.
#
# EVERY QUERY FAILURE IS FATAL. Reporting "no PRs found" from a failed API call
# would open a duplicate promotion precisely when the API is unreachable, which
# is when nobody is watching.
set -uo pipefail
die() {
  printf 'gh-adapter: %s\n' "$1" >&2
  exit 2
}
# The remote ref must still be the verified commit at the instant of mutation.
remote_sha_must_be() { # $1=owner/repo $2=branch $3=expected
  local got
  if ! got="$(gh api "repos/$1/git/ref/heads/$2" --jq '.object.sha' 2>&1)"; then
    printf '%s\n' "$got" >&2
    die "cannot read remote ref $2; refusing to mutate a PR blind"
  fi
  [ "$got" = "$3" ] || die "remote $2 is at $got, not the verified commit $3"
}

cmd="${1:-}"
shift || true
case "$cmd" in
  snapshot)
    or="${1:-}"
    pre="${2:-}"
    if [ -z "$or" ] || [ -z "$pre" ]; then die "snapshot OWNER_REPO HEAD_REF_PREFIX"; fi
    # The whole prefix, every state. A narrower query cannot answer "is there a
    # competing promotion for this channel?".
    # GENUINELY PAGINATED. `gh pr list --limit 200` caps BEFORE the prefix
    # filter, so an older closed-unmerged or merged promotion beyond the newest
    # 200 pull requests silently disappears — and the snapshot would still
    # advertise complete OPEN/CLOSED/MERGED coverage. The REST endpoint also
    # carries merge_commit_sha directly, which replay validation requires.
    if ! prs="$(gh api "repos/$or/pulls?state=all&per_page=100" --paginate \
      --jq '.[] | {number, state, merged_at, merge_commit_sha,
                   head_repo: .head.repo.full_name, head_ref: .head.ref, head_sha: .head.sha,
                   base_repo: .base.repo.full_name, base_ref: .base.ref, base_sha: .base.sha}' 2>&1)"; then
      printf '%s\n' "$prs" >&2
      die "gh api pulls failed; a truncated or failed query must never be reported as complete state"
    fi
    # `.[]` is REQUIRED: each page is an ARRAY, and projecting it as a single
    # object yields "expected an object but got: array" and fails every real
    # invocation. Both test stubs previously returned no branch records, so this
    # projection was never exercised.
    if ! brs="$(gh api "repos/$or/branches?per_page=100" --paginate \
      --jq '.[] | {name: .name, sha: .commit.sha}' 2>&1)"; then
      printf '%s\n' "$brs" >&2
      die "gh api branches failed"
    fi
    if ! printf '%s' "$prs" | jq -s --arg or "$or" --arg pre "$pre" \
      --slurpfile b <(printf '%s' "$brs" | jq -s '.') '
      {
        schema: "blessed/pr-state-snapshot/v1",
        repo: $or,
        query: { head_ref_prefix: $pre, states: ["OPEN","CLOSED","MERGED"] },
        pull_requests: [ .[] | select(.head_ref | startswith($pre)) | {
          number: .number,
          state: (if .merged_at != null then "MERGED"
                  elif .state == "closed" then "CLOSED" else "OPEN" end),
          head_repo: (.head_repo // $or), head_ref: .head_ref, head_sha: .head_sha,
          base_repo: (.base_repo // $or), base_ref: .base_ref, base_sha: .base_sha }
          + (if (.merge_commit_sha // "") == "" or .merged_at == null then {}
             else { merge_commit_sha: .merge_commit_sha } end) ],
        branches: [ $b[0][] | select(.name | startswith($pre)) ]
      }'; then
      die "cannot build the PR-state snapshot"
    fi
    ;;
  push)
    repo="${1:-}"
    branch="${2:-}"
    exp="${3:-}"
    # OPTIONAL 4th arg: the remote OID this push is allowed to REPLACE. Absent
    # means create-only.
    onto="${4:-}"
    if [ -z "$repo" ] || [ -z "$branch" ] || [ -z "$exp" ]; then die "push REPO_DIR BRANCH EXPECTED_SHA [EXPECTED_REMOTE_OID]"; fi
    [ "$(git -C "$repo" rev-parse HEAD)" = "$exp" ] || die "local HEAD is not the expected commit $exp"
    # THE LEASE IS THE WHOLE SAFETY PROPERTY, in both modes.
    #
    # CREATE-ONLY (no 4th arg): an empty <expect> means "this ref must not exist
    # yet", so the push succeeds only when it CREATES the branch. It cannot
    # overwrite a ref and cannot even fast-forward one. A plain push would
    # happily fast-forward a branch a concurrent actor created at the trusted
    # base, silently rewriting their PR to this run's commit.
    #
    # RECOVERY (4th arg): <expect> is the exact OID the caller observed, so the
    # push is a compare-and-swap. If anything moved the branch between the
    # snapshot and now, the lease fails and nothing is overwritten. This is NOT
    # a general force escape: it can only replace the one commit the caller
    # already verified belongs to this promotion.
    #
    # Hooks are disabled here too: a pre-push hook could otherwise amend or
    # reject the push.
    if [ -n "$onto" ]; then
      case "$onto" in
        [0-9a-f]*) [ "${#onto}" -eq 40 ] || die "expected remote oid must be a full 40-char sha: $onto" ;;
        *) die "expected remote oid is not a sha: $onto" ;;
      esac
      git -C "$repo" -c core.hooksPath=/dev/null push \
        --force-with-lease="refs/heads/${branch}:${onto}" \
        --set-upstream origin "$branch" ||
        die "push failed; $branch is no longer at $onto — refusing to overwrite a concurrently changed head"
    else
      git -C "$repo" -c core.hooksPath=/dev/null push \
        --force-with-lease="refs/heads/${branch}:" \
        --set-upstream origin "$branch" ||
        die "push failed; the promotion branch must not already exist on the remote"
    fi
    ;;
  create-pr)
    or="${1:-}"
    branch="${2:-}"
    base="${3:-}"
    title="${4:-}"
    bodyfile="${5:-}"
    exp="${6:-}"
    if [ -z "$or" ] || [ -z "$branch" ] || [ -z "$base" ] || [ -z "$title" ] || [ -z "$bodyfile" ] || [ -z "$exp" ]; then
      die "create-pr OWNER_REPO BRANCH BASE_REF TITLE BODY_FILE EXPECTED_SHA"
    fi
    [ -f "$bodyfile" ] || die "body file not found: $bodyfile"
    remote_sha_must_be "$or" "$branch" "$exp"
    if ! existing="$(gh pr list --repo "$or" --head "$branch" --state open --json number --jq 'length' 2>&1)"; then
      printf '%s\n' "$existing" >&2
      die "gh pr list failed; refusing to create a PR that may duplicate one"
    fi
    [ "$existing" = "0" ] || die "a PR for $branch already exists; refusing to open a second"
    gh pr create --repo "$or" --base "$base" --head "$branch" --title "$title" \
      --body-file "$bodyfile" || die "gh pr create failed"
    ;;
  update-pr)
    or="${1:-}"
    branch="${2:-}"
    bodyfile="${3:-}"
    exp="${4:-}"
    if [ -z "$or" ] || [ -z "$branch" ] || [ -z "$bodyfile" ] || [ -z "$exp" ]; then
      die "update-pr OWNER_REPO BRANCH BODY_FILE EXPECTED_SHA"
    fi
    [ -f "$bodyfile" ] || die "body file not found: $bodyfile"
    remote_sha_must_be "$or" "$branch" "$exp"
    if ! n="$(gh pr list --repo "$or" --head "$branch" --state open --json number --jq 'if length == 1 then .[0].number else "" end' 2>&1)"; then
      printf '%s\n' "$n" >&2
      die "gh pr list failed"
    fi
    [ -n "$n" ] || die "no single open PR for $branch to update"
    # The body is deterministic, so an equivalent re-run is a no-op edit.
    gh pr edit "$n" --repo "$or" --body-file "$bodyfile" || die "gh pr edit failed"
    printf 'gh-adapter: PR #%s updated\n' "$n" >&2
    ;;
  *) die "unknown adapter command: ${cmd:-<none>}" ;;
esac
exit 0
