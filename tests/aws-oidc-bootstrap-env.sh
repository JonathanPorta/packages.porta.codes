#!/usr/bin/env bash
# aws-oidc-bootstrap-env.sh — the Environment preflight of
# scripts/provision/aws-oidc-bootstrap.sh fails CLOSED (review F4 on PR #1).
#
# Runs the REAL bootstrap entry point in --apply mode with recording fakes for
# `gh` and `aws`. For the Environment under test (infrastructure-plan →
# role packages-porta-codes-terraform-plan) each unobservable, malformed,
# partial or forbidden inventory must refuse BEFORE any IAM mutation of that
# role or its boundary; a complete valid inventory must let it proceed.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0 fail=0
ok() {
  echo "  ✓ $1"
  pass=$((pass + 1))
}
no() {
  echo "  ✗ $1"
  fail=$((fail + 1))
}
W="$(mktemp -d)"
trap 'rm -rf "$W"' EXIT
BIN="$W/bin"
mkdir -p "$BIN"

cat >"$BIN/aws" <<'FAKE'
#!/usr/bin/env bash
# Operator identity; the provider exists; nothing else does yet. Every
# mutation is recorded (never executed).
case "$1 $2" in
  "sts get-caller-identity") printf '{"Account":"111122223333","Arn":"arn:aws:sts::111122223333:assumed-role/AWSReservedSSO_Admin/op"}\n' ;;
  "iam get-open-id-connect-provider") printf '{"ClientIDList":["sts.amazonaws.com"]}\n' ;;
  iam\ get-* | iam\ list-*) echo "An error occurred (NoSuchEntity) when calling the operation: not found" >&2; exit 254 ;;
  iam\ *) printf '%s\n' "$*" >>"$AWS_LOG"; printf '{}\n' ;;
  *) exit 0 ;;
esac
FAKE
cat >"$BIN/gh" <<'FAKE'
#!/usr/bin/env bash
# `gh api [--paginate --slurp] PATH`; SCENARIO shapes infrastructure-plan only.
# Like gh: --paginate --slurp returns an array of pages; without --slurp only
# the first page; --jq EXPR is applied to what would be printed.
args=("$@") path="" slurp=0 jqexpr="" prev=""
for a in "${args[@]}"; do
  case "$a" in repos/*) path="$a" ;; --slurp) slurp=1 ;; esac
  [ "$prev" = --jq ] && jqexpr="$a"
  prev="$a"
done
body() { # the page array for PATH → stdout, honoring --slurp and --jq
  local pages
  pages="$(cat)"
  if [ "$slurp" = 0 ] && printf '%s' "$pages" | jq -e 'type == "array"' >/dev/null 2>&1; then
    pages="$(printf '%s' "$pages" | jq -c '.[0]')"
  fi
  if [ -n "$jqexpr" ]; then printf '%s' "$pages" | jq -r "$jqexpr"; else printf '%s\n' "$pages"; fi
}
[ "$1" = variable ] && { printf 'variable %s\n' "$*" >>"$AWS_LOG"; exit 0; }
case "$path" in
  */actions/oidc/customization/sub) cat "$SUBJECT_FILE"; exit 0 ;;
esac
env="${path#*/environments/}"; env="${env%%/*}"
tail="${path#*/environments/$env}"
good_env='{"name":"x","deployment_branch_policy":{"custom_branch_policies":true,"protected_branches":false}}'
good_branches='[{"total_count":1,"branch_policies":[{"name":"main","type":"branch"}]}]'
good_secrets='[{"total_count":0,"secrets":[]}]'
s="ok"
[ "$env" = infrastructure-plan ] && s="$SCENARIO"
case "$s:$tail" in
  env404:) echo "gh: Not Found (HTTP 404)" >&2; exit 1 ;;
  env403:) echo "gh: Forbidden (HTTP 403)" >&2; exit 1 ;;
  envmalformed:) printf '%s' '{"name":"x"}' | body ;;
  secrets403:/secrets) echo "gh: Resource not accessible by integration (HTTP 403)" >&2; exit 1 ;;
  secrets5xx:/secrets) echo "gh: Server Error (HTTP 502)" >&2; exit 1 ;;
  secretstransport:/secrets) echo "dial tcp: i/o timeout" >&2; exit 1 ;;
  secretsmalformed:/secrets) printf '%s' '[{"total_count":0}]' | body ;;
  secretsnotjson:/secrets) printf '%s' '<html>oops</html>' | body ;;
  secretspartial:/secrets) printf '%s' '[{"total_count":3,"secrets":[{"name":"A"}]}]' | body ;;
  secretslaterpage:/secrets) printf '%s' '[{"total_count":2,"secrets":[{"name":"FOO"}]},{"total_count":2,"secrets":[{"name":"aws_secret_access_key"}]}]' | body ;;
  secretsemptyitem:/secrets) printf '%s' '[{"total_count":1,"secrets":[{}]}]' | body ;;
  secretsnullname:/secrets) printf '%s' '[{"total_count":1,"secrets":[{"name":null}]}]' | body ;;
  secretsnumname:/secrets) printf '%s' '[{"total_count":1,"secrets":[{"name":7}]}]' | body ;;
  secretsstringitem:/secrets) printf '%s' '[{"total_count":1,"secrets":["AWS_SECRET_ACCESS_KEY"]}]' | body ;;
  secretsordinary:/secrets) printf '%s' '[{"total_count":1,"secrets":[{"name":"BWS_ACCESS_TOKEN"}]}]' | body ;;
  branchtypefalse:/deployment-branch-policies) printf '%s' '[{"total_count":1,"branch_policies":[{"name":"main","type":false}]}]' | body ;;
  branchtypenull:/deployment-branch-policies) printf '%s' '[{"total_count":1,"branch_policies":[{"name":"main","type":null}]}]' | body ;;
  branchtypeabsent:/deployment-branch-policies) printf '%s' '[{"total_count":1,"branch_policies":[{"name":"main"}]}]' | body ;;
  branchtypenum:/deployment-branch-policies) printf '%s' '[{"total_count":1,"branch_policies":[{"name":"main","type":0}]}]' | body ;;
  branchtypearray:/deployment-branch-policies) printf '%s' '[{"total_count":1,"branch_policies":[{"name":"main","type":["branch"]}]}]' | body ;;
  branchtypeobject:/deployment-branch-policies) printf '%s' '[{"total_count":1,"branch_policies":[{"name":"main","type":{}}]}]' | body ;;
  branchtypeunknown:/deployment-branch-policies) printf '%s' '[{"total_count":1,"branch_policies":[{"name":"main","type":"environment"}]}]' | body ;;
  branchtypetag:/deployment-branch-policies) printf '%s' '[{"total_count":1,"branch_policies":[{"name":"main","type":"tag"}]}]' | body ;;
  branchesnullname:/deployment-branch-policies) printf '%s' '[{"total_count":1,"branch_policies":[{"name":null,"type":"branch"}]}]' | body ;;
  branches403:/deployment-branch-policies) echo "gh: Forbidden (HTTP 403)" >&2; exit 1 ;;
  brancheslaterpage:/deployment-branch-policies) printf '%s' '[{"total_count":2,"branch_policies":[{"name":"main","type":"branch"}]},{"total_count":2,"branch_policies":[{"name":"release/*","type":"branch"}]}]' | body ;;
  branchesmissing:/deployment-branch-policies) printf '%s' '[{"total_count":1}]' | body ;;
  *:) printf '%s' "$good_env" | body ;;
  *:/deployment-branch-policies) printf '%s' "$good_branches" | body ;;
  *:/secrets) printf '%s' "$good_secrets" | body ;;
  *) echo "unexpected $path" >&2; exit 1 ;;
esac
FAKE
chmod +x "$BIN/aws" "$BIN/gh"

run() { # SCENARIO → output; mutations in $W/aws.log
  : >"$W/aws.log"
  (cd "$ROOT" && PATH="$BIN:$PATH" AWS_PROFILE=fake AWS_LOG="$W/aws.log" SCENARIO="$1" \
    SUBJECT_FILE="$ROOT/policies/oidc-subject.json" bash scripts/provision/aws-oidc-bootstrap.sh --apply --no-variables 2>&1)
}
# A mutation OF the plan role or its boundary (its ARN also appears inside the
# apply role's policy document, which is not a mutation of it).
touched() { grep -Eq -- '--role-name packages-porta-codes-terraform-plan( |$)|--policy-name packages-porta-codes-terraform-plan-boundary|policy/packages-porta-codes-terraform-plan-boundary' "$W/aws.log"; }

# refuse SCENARIO REASON-SUBSTRING LABEL
refuse() {
  local out
  out="$(run "$1")"
  if touched; then
    no "$3: the plan role or its boundary was mutated"
  elif ! printf '%s' "$out" | grep -qF -- "$2"; then
    no "$3: refused for the wrong reason"
    printf '%s\n' "$out" | grep -E 'FAIL|infrastructure-plan' | head -4 | sed 's/^/      /'
  else ok "$3"; fi
}
echo "── the Environment preflight fails closed ──"
refuse env404 "does not exist" "a missing Environment"
refuse env403 "UNOBSERVABLE (read failed)" "an Environment read that fails with 403"
refuse envmalformed "no readable deployment policy" "an Environment without a deployment policy"
refuse secrets403 "secret inventory is UNOBSERVABLE" "a secret inventory that fails with 403"
refuse secrets5xx "secret inventory is UNOBSERVABLE" "a secret inventory that fails with 5xx"
refuse secretstransport "secret inventory is UNOBSERVABLE" "a secret inventory lost to a transport error"
refuse secretsmalformed "secret inventory is UNOBSERVABLE" "a secret inventory without its collection"
refuse secretsnotjson "secret inventory is UNOBSERVABLE" "a secret inventory that is not JSON"
refuse secretspartial "secret inventory is UNOBSERVABLE" "a secret inventory shorter than its total_count"
refuse secretslaterpage "holds an AWS_* secret" "an AWS secret on a LATER page"
refuse secretsemptyitem "secret inventory is malformed" "a secret entry with no name"
refuse secretsnullname "secret inventory is malformed" "a secret entry whose name is null"
refuse secretsnumname "secret inventory is malformed" "a secret entry whose name is not a string"
refuse secretsstringitem "secret inventory is malformed" "a secret entry that is not an object"
refuse branchesnullname "branch policies are malformed" "a branch policy whose name is null"
refuse branchtypefalse "branch policies are malformed" "a branch policy whose type is boolean false"
refuse branchtypenull "branch policies are malformed" "a branch policy whose type is null"
refuse branchtypeabsent "branch policies are malformed" "a branch policy whose type is absent"
refuse branchtypenum "branch policies are malformed" "a branch policy whose type is a number"
refuse branchtypearray "branch policies are malformed" "a branch policy whose type is an array"
refuse branchtypeobject "branch policies are malformed" "a branch policy whose type is an object"
refuse branchtypeunknown "branch policies are malformed" "a branch policy whose type is an unknown string"
refuse branchtypetag "not exactly branch main" "a policy for TAG main (a valid type, the wrong ref kind)"
refuse branches403 "branch policies are UNOBSERVABLE" "branch policies that fail with 403"
refuse branchesmissing "branch policies are UNOBSERVABLE" "branch policies without their collection"
refuse brancheslaterpage "not exactly branch main" "an extra branch on a LATER page"
echo "── a complete, valid inventory still proceeds ──"
out="$(run ok)"
if grep -q 'create-role --role-name packages-porta-codes-terraform-plan' "$W/aws.log" &&
  printf '%s' "$out" | grep -qF 'Environment infrastructure-plan: exactly branch main, no AWS secret (complete inventory)'; then
  ok "valid empty secrets + exactly branch main: the role is created"
else
  no "a valid inventory did not proceed"
  printf '%s\n' "$out" | grep -E 'FAIL' | head -4 | sed 's/^/      /'
fi
out="$(run secretsordinary)"
if grep -q 'create-role --role-name packages-porta-codes-terraform-plan' "$W/aws.log"; then
  ok "an ordinary non-AWS secret (BWS_ACCESS_TOKEN): the role is created"
else
  no "an ordinary secret blocked the role"
  printf '%s\n' "$out" | grep -E 'FAIL' | head -4 | sed 's/^/      /'
fi
echo "aws-oidc-bootstrap-env: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
