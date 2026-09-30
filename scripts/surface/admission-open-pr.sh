#!/usr/bin/env bash
# admission-open-pr.sh — propose one admitted inventory as a PR, through the
# API, with the admission-PR App token in GH_TOKEN (admit-candidate.yml open-pr;
# blessed releases.release-pr@1 RP-6/RP-7). No repository code is checked out
# or run: the branch, its one commit and the PR are made by the API.
#
# The PR's scope is exact: branch admit/<producer>-<tag> is ONE commit whose
# parent is on main and whose only change is inventory/inventory.json, holding
# exactly the admitted bytes; its PR is an open, same-repository PR into main
# at that commit. On a retry:
#
#   · no branch                          → create it (ref, then the commit)
#   · a branch with no change of its own  → resume: add the commit
#     (its head is on main — a create interrupted between ref and commit)
#   · a branch that is exactly the above  → keep it
#   · any other branch                    → REFUSE (another parent, another
#     file, another inventory: never overwritten, never proposed)
#   · an open PR that is exactly the above → no-op
#   · any other open PR for the branch    → REFUSE (fork head, base, head SHA)
#
# Env: GH_TOKEN, SELF (owner/repo), REPO (producer owner/repo), TAG, BASE_SHA
# (main at this run), INVENTORY, ADMISSION_LOG. Exit: 0 proposed or already
# proposed · 1 refused · 2 usage.
# shellcheck disable=SC2016 # jq programs, not shell
set -euo pipefail
FILE="inventory/inventory.json"
die() {
  echo "::error::$1" >&2
  exit "${2:-1}"
}
for v in SELF REPO TAG BASE_SHA INVENTORY ADMISSION_LOG; do
  [ -n "${!v:-}" ] || die "admission-open-pr: $v is not set" 2
done
[ -f "$INVENTORY" ] || die "admission-open-pr: no inventory at $INVENTORY" 2
branch="admit/${REPO#*/}-$TAG"
want="$(sha256sum "$INVENTORY" | cut -d' ' -f1)"

head_of() { gh api "repos/$SELF/git/ref/heads/$branch" --jq .object.sha 2>/dev/null; }
# on_main SHA → 0 when SHA is main or an ancestor of main
on_main() {
  local s
  s="$(gh api "repos/$SELF/compare/$1...main" --jq .status)" || die "cannot compare $1 with main"
  case "$s" in identical | ahead) return 0 ;; *) return 1 ;; esac
}
commit_inventory() {
  local old=""
  if gh api "repos/$SELF/contents/$FILE?ref=$branch" --silent 2>/dev/null; then
    old="$(gh api "repos/$SELF/contents/$FILE?ref=$branch" --jq .sha)"
  fi
  local args=(-X PUT "repos/$SELF/contents/$FILE" -f message="feat: admit $REPO $TAG" -f branch="$branch"
    -f content="$(base64 <"$INVENTORY" | tr -d '\n')")
  [ -z "$old" ] || args+=(-f sha="$old")
  gh api "${args[@]}" >/dev/null
}
# verify_branch HEAD → refuses unless HEAD is exactly the admission commit
verify_branch() {
  local h="$1" parents files have
  parents="$(gh api "repos/$SELF/commits/$h" --jq '[.parents[].sha] | join(" ")')" || die "cannot read commit $h"
  case "$parents" in
    "" | *" "*) die "branch $branch head $h is not a single-parent commit; refusing it" ;;
  esac
  on_main "$parents" || die "branch $branch is based on $parents, which is not on main; refusing it"
  files="$(gh api "repos/$SELF/compare/$parents...$h" --jq '[.files[] | "\(.status) \(.filename)"] | join(",")')" ||
    die "cannot compare $parents...$h"
  [ "$files" = "modified $FILE" ] || [ "$files" = "added $FILE" ] ||
    die "branch $branch changes more than $FILE ($files); refusing it"
  have="$(gh api "repos/$SELF/contents/$FILE?ref=$h" --jq .content | base64 -d | sha256sum | cut -d' ' -f1)"
  [ "$have" = "$want" ] || die "branch $branch already exists with a DIFFERENT inventory; refusing to overwrite it"
}

head="$(head_of)" || head=""
if [ -z "$head" ]; then
  gh api -X POST "repos/$SELF/git/refs" -f ref="refs/heads/$branch" -f sha="$BASE_SHA" >/dev/null
  commit_inventory
elif on_main "$head"; then
  echo "::notice::branch $branch carries no change yet; resuming"
  commit_inventory
else
  echo "::notice::branch $branch exists; checking it is exactly this admission"
fi
head="$(head_of)" || die "branch $branch vanished"
verify_branch "$head"

prs="$(gh pr list --repo "$SELF" --head "$branch" --state open \
  --json number,baseRefName,headRefOid,isCrossRepository \
  --jq '[.[] | "\(.number) \(.baseRefName) \(.headRefOid) \(.isCrossRepository)"] | join(",")')"
if [ -n "$prs" ]; then
  case "$prs" in *,*) die "several open PRs propose $branch ($prs); refusing" ;; esac
  read -r n base phead cross <<<"$prs"
  [ "$cross" = false ] || die "PR #$n proposes $branch from another repository; refusing"
  [ "$base" = main ] || die "PR #$n proposes $branch into $base, not main; refusing"
  [ "$phead" = "$head" ] || die "PR #$n is at $phead, not the admission commit $head; refusing"
  echo "::notice::PR #$n already proposes exactly this admission"
  exit 0
fi
body="$(mktemp)"
trap 'rm -f "$body"' EXIT
{
  echo "Admits \`$REPO\` \`$TAG\` into the package inventory (blessed releases.package-repositories@1 PR-2/PR-3)."
  echo
  echo "Opened by this repository's admission-PR GitHub App (releases.release-pr@1 RP-6), so the required checks run on their own. Merging this PR is the approval; publish.yml does the rest."
  echo
  echo "Admission log:"
  echo '```'
  cat "$ADMISSION_LOG"
  echo '```'
} >"$body"
gh pr create --repo "$SELF" --base main --head "$branch" --title "feat: Admit ${REPO#*/} $TAG" --body-file "$body"
