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
#   JonathanPorta/kioskd                rpm-signing                   → tag v* ONLY
#                                       (kioskd's release.yml runs on v* tag pushes;
#                                       no branch may deploy to it. The signing job
#                                       itself asserts the tagged commit is an
#                                       ancestor of origin/main — reviewed code only)
#   JonathanPorta/corpus                rpm-signing, release-signing  → branch main
#   JonathanPorta/keysprout             rpm-signing, release-signing  → branch main
#                                       (both release on push to main / dispatch on main)
#
# No Environment is broadened to accommodate another. Each gets custom
# deployment policies (never "all branches"), and nothing else — required
# reviewers are not added (the reviewed-merge gate is the branch/tag rule).
# Default is a DRY RUN that prints what it would set; --apply makes the calls.
# Needs gh authenticated with admin on the four repositories. Idempotent.
set -euo pipefail
APPLY=false
[ "${1:-}" != --apply ] || APPLY=true
ROWS=(
  "JonathanPorta/packages.porta.codes repository-signing branch main"
  "JonathanPorta/packages.porta.codes candidate-ingest branch main"
  "JonathanPorta/packages.porta.codes repository-publication branch main"
  "JonathanPorta/packages.porta.codes infrastructure-plan branch main"
  "JonathanPorta/packages.porta.codes infrastructure branch main"
  "JonathanPorta/kioskd rpm-signing tag v*"
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
