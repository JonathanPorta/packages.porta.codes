#!/usr/bin/env bash
# workflow-authority.sh — the admission-PR App key is reachable from exactly one
# job (blessed releases.release-pr@1 RP-6/RP-7), checked across EVERY workflow:
#
#   A1  only admit-candidate.yml:open-pr declares Environment admission-pr
#   A2  only that job loads the admission-pr loader profile
#   A3  its only checkout is sparse (the loader, scripts/bws and the PR
#       script) and keeps no git credentials
#   A4  it runs no build, admission, packaging or signing step
#   A5  no other job mentions an ADMISSION_PR_* value
#   A6  its workflow token is read-only (the App token does the writing)
#   A7  it mints the App token for THIS repository only, with exactly
#       contents: write and pull-requests: write, from a SHA-pinned action
#   A8  the candidate read token never reaches it
#
# Each rule is then broken on a copy, one at a time, and must fail for its own
# reason. Needs yq (mikefarah v4) and jq.
# shellcheck disable=SC2016 # yq/jq programs and literal $-names in mutated YAML, never shell
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
W="$(mktemp -d)"
trap 'rm -rf "$W"' EXIT
pass=0 fail=0
ok() {
  echo "  ✓ $1"
  pass=$((pass + 1))
}
no() {
  echo "  ✗ $1"
  fail=$((fail + 1))
}
TOKEN_ACTION='actions/create-github-app-token@bcd2ba49218906704ab6c1aa796996da409d3eb1'

# check DIR → prints one line per violated rule ("A<n> …"); exit 0 iff none
check() {
  local dir="$1" jobs
  jobs="$(for f in "$dir"/*.yml; do
    yq -o=json '.' "$f" | jq -c --arg f "$(basename "$f")" '.jobs | to_entries[] | {wf: $f, job: .key, v: .value}'
  done)"
  jq -rs --arg action "$TOKEN_ACTION" '
    def env_name: (.v.environment | if type == "object" then .name else . end) // "";
    def loads($p): any(.v.steps[]?; ((.uses // "") == "./.github/actions/load-secrets") and ((.with.profile // "") == $p));
    def text: (.v | tostring);
    def is_open_pr: .wf == "admit-candidate.yml" and .job == "open-pr";
    . as $all
    | ([ $all[] | select(env_name == "admission-pr") | "\(.wf):\(.job)" ]) as $env
    | ([ $all[] | select(loads("admission-pr")) | "\(.wf):\(.job)" ]) as $prof
    | ([ $all[] | select(is_open_pr) ] | first) as $o
    | [
        (if $env != ["admit-candidate.yml:open-pr"] then "A1 Environment admission-pr is declared by: \($env | join(", "))" else empty end),
        (if $prof != ["admit-candidate.yml:open-pr"] then "A2 the admission-pr profile is loaded by: \($prof | join(", "))" else empty end),
        (if $o == null then "A1 admit-candidate.yml has no open-pr job" else
          ([ $o.v.steps[] | select((.uses // "") | startswith("actions/checkout@")) ]) as $co
          | (if ($co | length) != 1
               or ($co[0].with["sparse-checkout"] // "" | split("\n") | map(select(. != "")) | sort) != [".github/actions/load-secrets", "scripts/bws", "scripts/surface/admission-open-pr.sh"]
               or ($co[0].with["persist-credentials"] != false)
             then "A3 open-pr checkout is not exactly a credential-less sparse checkout of the loader, scripts/bws and the PR script" else empty end),
            (if any($o.v.steps[]; (.run // "") | test("\\bmake\\b|docker|admit\\.sh|pkgrepo-|rpmsign|rpm-finalize|gpg|sign\\.sh|nfpm")) then "A4 open-pr runs a build, admission or signing step" else empty end),
            (if ($o.v.permissions // {}) != {"contents": "read"} then "A6 open-pr workflow-token permissions are \($o.v.permissions // {} | tostring), not contents: read" else empty end),
            ([ $o.v.steps[] | select((.uses // "") | startswith("actions/create-github-app-token")) ]) as $tk
            | (if ($tk | length) != 1 or $tk[0].uses != $action
                 or $tk[0].with.repositories != "${{ github.event.repository.name }}"
                 or ([ $tk[0].with | to_entries[] | select(.key | startswith("permission-")) | "\(.key)=\(.value)" ] | sort) != ["permission-contents=write", "permission-pull-requests=write"]
               then "A7 open-pr does not mint a pinned, this-repository-only token with exactly contents+pull-requests write" else empty end),
            (if ($o | text | test("PACKAGES_CANDIDATE_READ_TOKEN")) then "A8 the candidate read token reaches open-pr" else empty end)
        end),
        ([ $all[] | select((is_open_pr | not) and (text | test("ADMISSION_PR_"))) | "\(.wf):\(.job)" ] as $leak
          | if ($leak | length) > 0 then "A5 ADMISSION_PR_* is mentioned by: \($leak | join(", "))" else empty end)
      ] | .[]' <<<"$jobs"
}

echo "── the committed workflows ──"
out="$(check "$ROOT/.github/workflows")"
if [ -z "$out" ]; then ok "the admission-PR App key is reachable from admit-candidate.yml:open-pr only (A1–A8)"; else
  no "the committed workflows violate the key boundary"
  printf '%s\n' "$out" | sed 's/^/      /'
fi

echo "── each rule bites (a copy, broken one way at a time) ──"
# mutate NAME RULE PYTHON-EXPR — edit a copy of admit-candidate.yml and expect RULE
mutate() {
  local label="$1" rule="$2" expr="$3" d="$W/$1"
  mkdir -p "$d"
  cp "$ROOT"/.github/workflows/*.yml "$d/"
  yq -i "$expr" "$d/admit-candidate.yml"
  out="$(check "$d")"
  if printf '%s\n' "$out" | grep -q "^$rule "; then ok "$label → refused by $rule"; else
    no "$label was not refused by $rule"
    printf '%s\n' "${out:-<no violation>}" | sed 's/^/      /'
  fi
}
mutate "the admit job also loads the admission-pr profile" A2 \
  '.jobs.admit.steps += [{"uses": "./.github/actions/load-secrets", "with": {"profile": "admission-pr"}}]'
mutate "another job declares Environment admission-pr" A1 '.jobs.admit.environment = {"name": "admission-pr"}'
mutate "open-pr checks out the whole repository" A3 'del(.jobs["open-pr"].steps[1].with["sparse-checkout"])'
mutate "open-pr keeps git credentials" A3 '.jobs["open-pr"].steps[1].with["persist-credentials"] = true'
mutate "open-pr also builds the tools image" A4 '.jobs["open-pr"].steps += [{"run": "make tools-image"}]'
mutate "the fetch job reads the App client id" A5 '.jobs.fetch.steps += [{"run": "echo $ADMISSION_PR_APP_CLIENT_ID"}]'
mutate "open-pr gets a writable workflow token" A6 '.jobs["open-pr"].permissions.contents = "write"'
mutate "open-pr mints a token for every installed repository" A7 \
  '(.jobs["open-pr"].steps[] | select(.uses == "'"$TOKEN_ACTION"'") | .with) |= del(.repositories)'
mutate "open-pr mints a token with an extra permission" A7 \
  '(.jobs["open-pr"].steps[] | select(.uses == "'"$TOKEN_ACTION"'") | .with["permission-administration"]) = "write"'
mutate "open-pr uses an unpinned token action" A7 \
  '(.jobs["open-pr"].steps[] | select(.uses == "'"$TOKEN_ACTION"'") | .uses) = "actions/create-github-app-token@v3"'
mutate "open-pr sees the candidate read token" A8 \
  '.jobs["open-pr"].steps += [{"run": "echo $PACKAGES_CANDIDATE_READ_TOKEN"}]'

echo "workflow-authority: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
