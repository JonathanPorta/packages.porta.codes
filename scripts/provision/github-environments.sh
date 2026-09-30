#!/usr/bin/env bash
# github-environments.sh [--apply] — the GitHub Environments of every authority
# domain in the pilot, each allowed ONLY the ref its trusted workflow runs on.
#
#   JonathanPorta/packages.porta.codes  repository-signing, candidate-ingest,
#                                       repository-publication,
#                                       infrastructure-plan,
#                                       infrastructure                → branch main
#   (infrastructure-plan / infrastructure are the Environments the Terraform
#   OIDC roles trust; aws-oidc-bootstrap.sh reads them back BEFORE any role
#   trusts them — blessed-cicd #9 ordering.)
#   JonathanPorta/kioskd                rpm-signing                   → follows kioskd's
#                                       release trigger ON ITS MAIN (see below)
#   JonathanPorta/corpus                rpm-signing, release-signing  → branch main
#   JonathanPorta/keysprout             rpm-signing, release-signing  → branch main
#
# kioskd's rpm-signing Environment must admit exactly the ref its merged
# release.yml signs from. Owner direction (2026-09-30): no manually pushed
# tags — kioskd#34 moves kioskd to a reviewed release PR on main, after which
# the Environment is `branch main`. Until that workflow is on kioskd's main it
# still triggers on `v*` tags, and a branch-only Environment would lock its
# signing job out. So the policy is DERIVED from the release.yml on kioskd's
# main at run time: a `tags:` trigger → `tag v*`, otherwise → `branch main`.
# If that file cannot be read, nothing is applied (fail closed).
#
# No Environment is broadened to accommodate another. Each gets custom
# deployment policies (never "all branches"), and nothing else — required
# reviewers are not added (the reviewed-merge gate is the branch rule).
# Default is a DRY RUN that prints what it would set; --apply makes the calls.
# Needs gh authenticated with admin on the four repositories. Idempotent.
set -euo pipefail
APPLY=false
[ "${1:-}" != --apply ] || APPLY=true
# kioskd_trigger RELEASE_YML_TEXT → "tag v*" when its `on:` block has a tags
# trigger, "branch main" when it has only a push-to-main trigger.
kioskd_trigger() {
  awk '/^on:/{f=1; next} f && /^[^ #]/{exit} f && /^[[:space:]]+tags:/{t=1} f && /^[[:space:]]+branches:/{b=1}
       END{if (t) print "tag v*"; else if (b) print "branch main"; else print "unknown"}'
}
if ! wf="$(gh api "repos/JonathanPorta/kioskd/contents/.github/workflows/release.yml?ref=main" --jq .content 2>/dev/null | base64 -d)" || [ -z "$wf" ]; then
  echo "github-environments: cannot read kioskd's release.yml on main — refusing to guess its rpm-signing policy" >&2
  exit 1
fi
kioskd_rpm="$(printf '%s\n' "$wf" | kioskd_trigger)"
[ "$kioskd_rpm" != unknown ] || {
  echo "github-environments: kioskd's release.yml on main has neither a tags nor a branches push trigger" >&2
  exit 1
}
ROWS=(
  "JonathanPorta/packages.porta.codes repository-signing branch main"
  "JonathanPorta/packages.porta.codes candidate-ingest branch main"
  "JonathanPorta/packages.porta.codes repository-publication branch main"
  "JonathanPorta/packages.porta.codes infrastructure-plan branch main"
  "JonathanPorta/packages.porta.codes infrastructure branch main"
  "JonathanPorta/kioskd rpm-signing $kioskd_rpm"
  "JonathanPorta/corpus rpm-signing branch main"
  "JonathanPorta/corpus release-signing branch main"
  "JonathanPorta/keysprout rpm-signing branch main"
  "JonathanPorta/keysprout release-signing branch main"
)
for row in "${ROWS[@]}"; do
  read -r repo env type pattern <<<"$row"
  printf '%-36s %-24s %s %s\n' "$repo" "$env" "$type" "$pattern"
  $APPLY || continue
  gh api -X PUT "repos/$repo/environments/$env" --input - >/dev/null <<'JSON'
{"deployment_branch_policy": {"protected_branches": false, "custom_branch_policies": true}}
JSON
  existing="$(gh api "repos/$repo/environments/$env/deployment-branch-policies" \
    --jq '.branch_policies[] | "\(.type // "branch") \(.name) \(.id)"')"
  # Remove any policy that is not exactly the declared one (never broaden).
  while read -r t n id; do
    [ -n "${id:-}" ] || continue
    if [ "$t $n" != "$type $pattern" ]; then
      gh api -X DELETE "repos/$repo/environments/$env/deployment-branch-policies/$id" >/dev/null
      printf '  removed stray policy %s %s\n' "$t" "$n"
    fi
  done <<<"$existing"
  if ! grep -qxF "$type $pattern" <<<"$(cut -d' ' -f1,2 <<<"$existing")"; then
    gh api -X POST "repos/$repo/environments/$env/deployment-branch-policies" \
      -f name="$pattern" -f type="$type" >/dev/null
  fi
  got="$(gh api "repos/$repo/environments/$env/deployment-branch-policies" --jq '[.branch_policies[] | "\(.type // "branch") \(.name)"] | join(",")')"
  [ "$got" = "$type $pattern" ] || {
    echo "github-environments: $repo/$env allows [$got], not exactly [$type $pattern]" >&2
    exit 1
  }
  printf '  verified: only %s %s may deploy\n' "$type" "$pattern"
done
$APPLY || echo "(dry run — re-run with --apply to set these)"
