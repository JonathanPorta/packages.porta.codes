#!/usr/bin/env bash
# aws-oidc-bootstrap.sh — the BOOTSTRAP-OWNED half of this surface's AWS
# authority (blessed-cicd #9 GitHub OIDC for all AWS access; #239 role creation
# and trust are bootstrap-owned, never created by an identity a workflow runs as).
#
# Run by the OPERATOR, from this repository, with the operator's SSO profile
# (AWS_PROFILE, default `portaj`; `aws sso login --profile <profile>` first). The
# profile's permission set must administer IAM roles and policies —
# PowerUserAccess cannot. It refuses to run as any of the roles it manages, and
# stops on any AWS error other than NoSuchEntity (never "absent" by mistake).
#
# It owns, and nothing else does:
#   · the account-global GitHub OIDC provider — LOOKED UP by exact ARN; created
#     only with --create-provider when absent (it is shared account-wide);
#   · three roles, each trusting ONLY that provider, aud sts.amazonaws.com and
#     ONE exact subject `<sub_claim_prefix>:environment:<env>` (StringEquals):
#       packages-porta-codes-terraform-plan    Environment infrastructure-plan
#       packages-porta-codes-terraform-apply   Environment infrastructure
#       packages-porta-codes-publisher         Environment repository-publication
#   · each role's permissions BOUNDARY (a managed policy `<role>-boundary`),
#     max session 3600 s, no attached managed policy;
#   · the plan and apply roles' inline policy `permissions`. The publisher's
#     inline policy belongs to Terraform (main.tf), capped by its boundary.
# Policy documents are in policies/ with `<ACCOUNT_ID>` rendered from the
# caller's account; trust documents are generated here from
# policies/oidc-subject.json, which must equal the repository's LIVE subject
# configuration (fail closed otherwise).
#
# ORDER (blessed-cicd #9): each GitHub Environment is read back first — it must
# exist, allow exactly branch `main`, and hold no AWS_* secret — before any role
# is made to trust it.
#
# Modes (exactly one; default --plan):
#   --plan        read-only: preflight, then what --apply would change
#   --apply       make the live state equal the declaration, then --verify
#   --verify      read-only PASS/FAIL per condition against live AWS/GitHub
#   --self-test   offline: the trust/permission checkers reject every mutation
# Options:
#   --create-provider   with --apply: create the GitHub OIDC provider if absent
#   --no-variables      with --apply: do not set repo variables AWS_ACCOUNT_ID/AWS_REGION
#
# Exit: 0 all PASS · 1 a FAIL or refusal · 2 usage/tooling.
set -euo pipefail
set +x

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
REPO="JonathanPorta/packages.porta.codes"
AUD="sts.amazonaws.com"
MAX_SESSION=3600
AWS_PROFILE="${AWS_PROFILE:-portaj}"
REGION="${AWS_REGION:-us-east-1}"
SUBJECT_FILE="$ROOT/policies/oidc-subject.json"
PROVIDER_HOST="token.actions.githubusercontent.com"

# name|environment|permissions (script-owned inline, or "-")|boundary document
ROLES="packages-porta-codes-terraform-plan|infrastructure-plan|policies/packages-porta-codes-terraform-plan.json|policies/packages-porta-codes-terraform-plan.json
packages-porta-codes-terraform-apply|infrastructure|policies/packages-porta-codes-terraform-apply.json|policies/packages-porta-codes-terraform-apply.json
packages-porta-codes-publisher|repository-publication|-|policies/packages-porta-codes-publisher-boundary.json"
PUBLISHER_INLINE="package-repository-publication"

mode=plan create_provider=0 set_vars=1
while [ $# -gt 0 ]; do
  case "$1" in
    --plan) mode=plan ;;
    --apply) mode=apply ;;
    --verify) mode=verify ;;
    --self-test) mode=self-test ;;
    --create-provider) create_provider=1 ;;
    --no-variables) set_vars=0 ;;
    -h | --help)
      sed -n '2,45p' "$0"
      exit 0
      ;;
    *)
      echo "aws-oidc-bootstrap: unknown argument: $1" >&2
      exit 2
      ;;
  esac
  shift
done

fails=0
pass() { printf '  PASS  %s\n' "$1"; }
fail() {
  printf '  FAIL  %s\n' "$1"
  fails=$((fails + 1))
}
say() { printf '%s\n' "$1"; }
check() { # check LABEL TEST... → PASS or FAIL LABEL
  local label="$1"
  shift
  if "$@"; then pass "$label"; else fail "$label"; fi
}
die() {
  printf 'aws-oidc-bootstrap: %s\n' "$1" >&2
  exit 2
}
command -v jq >/dev/null 2>&1 || die "jq is required"

# ── pure checkers (also exercised offline by --self-test) ──────────────────

# trust_doc PROVIDER_ARN SUBJECT → the one trust document this surface uses.
trust_doc() {
  jq -cn --arg p "$1" --arg s "$2" --arg a "$AUD" --arg h "$PROVIDER_HOST" '{
    Version: "2012-10-17",
    Statement: [{
      Effect: "Allow",
      Principal: {Federated: $p},
      Action: "sts:AssumeRoleWithWebIdentity",
      Condition: {StringEquals: {($h + ":aud"): $a, ($h + ":sub"): $s}}
    }]}'
}

# check_trust DOC PROVIDER_ARN SUBJECT → prints each violation; returns the count.
# Exactly one Allow statement; Principal exactly {Federated: provider}; Action
# exactly sts:AssumeRoleWithWebIdentity; Condition exactly StringEquals with
# exactly aud and sub, each one exact value; no wildcard in the subject.
check_trust() {
  jq -r --arg p "$2" --arg s "$3" --arg a "$AUD" --arg h "$PROVIDER_HOST" '
    def one: if type == "array" then (if length == 1 then .[0] else null end) else . end;
    (.Statement // []) as $st
    | [ (if ($st | length) != 1 then "not exactly one trust statement" else empty end),
        ($st[] | (
          (if .Effect != "Allow" then "a statement is not Allow" else empty end),
          (if (.Principal | keys) != ["Federated"] or (.Principal.Federated | one) != $p
             then "principal is not exactly the GitHub OIDC provider" else empty end),
          (if (.Action | one) != "sts:AssumeRoleWithWebIdentity" then "action is not exactly sts:AssumeRoleWithWebIdentity" else empty end),
          (if (.Condition | keys) != ["StringEquals"] then "condition operators are not exactly StringEquals" else empty end),
          (if ((.Condition.StringEquals // {}) | keys) != ([$h + ":aud", $h + ":sub"] | sort)
             then "StringEquals keys are not exactly aud and sub" else empty end),
          (if (.Condition.StringEquals[$h + ":aud"] | one) != $a then "aud is not exactly " + $a else empty end),
          (if (.Condition.StringEquals[$h + ":sub"] | one) != $s then "sub is not exactly " + $s else empty end),
          (if ((.Condition.StringEquals[$h + ":sub"] | one) // "" | test("[*?]")) then "sub contains a wildcard" else empty end),
          (if has("NotPrincipal") or has("NotAction") then "statement uses NotPrincipal/NotAction" else empty end)
        )) ] | .[]' <<<"$1" | {
    n=0
    while IFS= read -r line; do
      printf '%s\n' "$line"
      n=$((n + 1))
    done
    return "$n"
  }
}

# check_perms DOC → violations of the absolute rules: no iam:PassRole, no sts:*,
# no wildcard service or `*` action, no `*` resource, no NotAction/NotResource.
check_perms() {
  jq -r '
    def arr: if type == "array" then . else [.] end;
    .Statement[] | . as $s
    | ((.Action // []) | arr | .[]
        | if . == "*" or test("^[a-z0-9-]+:\\*$") then "wildcard action " + .
          elif (ascii_downcase) == "iam:passrole" then "iam:PassRole"
          elif test("^sts:") then "sts action " + .
          else empty end),
      ((.Resource // []) | arr | .[] | if . == "*" then "resource *" else empty end),
      (if ($s | has("NotAction")) or ($s | has("NotResource")) then "NotAction/NotResource" else empty end)' <<<"$1" | {
    n=0
    while IFS= read -r line; do
      printf '%s\n' "$line"
      n=$((n + 1))
    done
    return "$n"
  }
}

canon() { jq -cS '.Statement |= sort_by(.Sid // "")' <<<"$1"; }

# aws_read OUTVAR -- aws ARGS… → 0 found (stdout in OUTVAR), 3 NoSuchEntity.
# ANY other error (AccessDenied above all) stops the run: an unreadable object
# must never be mistaken for an absent one.
aws_read() {
  local __var="$1" out rc=0
  shift 2
  out="$(aws "$@" 2>&1)" || rc=$?
  if [ "$rc" -eq 0 ]; then
    printf -v "$__var" '%s' "$out"
    return 0
  fi
  case "$out" in
    *NoSuchEntity*) return 3 ;;
  esac
  printf 'aws-oidc-bootstrap: aws %s failed:\n%s\n' "$1 $2" "$out" >&2
  if printf '%s' "$out" | grep -q AccessDenied; then
    printf 'aws-oidc-bootstrap: the operator identity lacks IAM authority (an IAM-capable permission set is required; PowerUserAccess has none)\n' >&2
  fi
  exit 2
}
render() { sed "s/<ACCOUNT_ID>/$ACCOUNT/g" "$ROOT/$1"; }

# ── offline self-test ──────────────────────────────────────────────────────
if [ "$mode" = self-test ]; then
  P="arn:aws:iam::111122223333:oidc-provider/$PROVIDER_HOST"
  S="repo:o@1/r@2:environment:infrastructure"
  good="$(trust_doc "$P" "$S")"
  expect_ok() {
    if out="$(check_trust "$2" "$P" "$S")"; then pass "$1"; else fail "$1 — $out"; fi
  }
  expect_bad() { # $1 label, $2 doc, $3 expected message fragment
    local out rc=0
    out="$(check_trust "$2" "$P" "$S")" || rc=$?
    if [ "$rc" -gt 0 ] && printf '%s' "$out" | grep -qF -- "$3"; then pass "$1"; else fail "$1 (rc=$rc: $out)"; fi
  }
  h="$PROVIDER_HOST"
  expect_ok "the generated trust is accepted" "$good"
  expect_bad "a ref-scoped subject is rejected" "$(trust_doc "$P" "repo:o@1/r@2:ref:refs/heads/main")" "sub is not exactly"
  expect_bad "another Environment's subject is rejected" "$(trust_doc "$P" "repo:o@1/r@2:environment:repository-publication")" "sub is not exactly"
  expect_bad "a name-based subject is rejected (immutable ids expected)" "$(trust_doc "$P" "repo:o/r:environment:infrastructure")" "sub is not exactly"
  expect_bad "a wildcard subject is rejected" "$(trust_doc "$P" "repo:o@1/r@2:environment:*")" "wildcard"
  expect_bad "another audience is rejected" "$(jq -c --arg h "$h" '.Statement[0].Condition.StringEquals[$h + ":aud"] = "sigstore"' <<<"$good")" "aud is not exactly"
  expect_bad "a missing audience is rejected" "$(jq -c --arg h "$h" 'del(.Statement[0].Condition.StringEquals[$h + ":aud"])' <<<"$good")" "keys are not exactly"
  expect_bad "StringLike is rejected" "$(jq -c '.Statement[0].Condition = {StringLike: .Statement[0].Condition.StringEquals}' <<<"$good")" "not exactly StringEquals"
  expect_bad "an extra condition operator is rejected" "$(jq -c '.Statement[0].Condition.StringLike = {"x": "y"}' <<<"$good")" "not exactly StringEquals"
  expect_bad "another provider is rejected" "$(trust_doc "arn:aws:iam::999999999999:oidc-provider/$h" "$S")" "principal is not exactly"
  expect_bad "an extra principal is rejected" "$(jq -c '.Statement[0].Principal.AWS = "*"' <<<"$good")" "principal is not exactly"
  expect_bad "a second statement is rejected" "$(jq -c '.Statement += [.Statement[0]]' <<<"$good")" "not exactly one"
  expect_bad "sts:AssumeRole chaining is rejected" "$(jq -c '.Statement[0].Action = "sts:AssumeRole"' <<<"$good")" "action is not exactly"
  for f in policies/packages-porta-codes-terraform-plan.json policies/packages-porta-codes-terraform-apply.json policies/packages-porta-codes-publisher-boundary.json; do
    ACCOUNT=111122223333
    doc="$(render "$f")"
    if printf '%s' "$doc" | grep -q '<ACCOUNT_ID>'; then fail "$f renders completely"; else pass "$f renders completely"; fi
    if out="$(check_perms "$doc")"; then pass "$f holds no PassRole/sts/wildcard"; else fail "$f — $out"; fi
    bad="$(jq -c '.Statement[0].Action = ["iam:PassRole"]' <<<"$doc")"
    if check_perms "$bad" >/dev/null; then fail "$f + iam:PassRole is rejected"; else pass "$f + iam:PassRole is rejected"; fi
    bad="$(jq -c '.Statement[0].Action = ["s3:*"]' <<<"$doc")"
    if check_perms "$bad" >/dev/null; then fail "$f + s3:* is rejected"; else pass "$f + s3:* is rejected"; fi
    bad="$(jq -c '.Statement[0].Resource = "*"' <<<"$doc")"
    if check_perms "$bad" >/dev/null; then fail "$f + Resource * is rejected"; else pass "$f + Resource * is rejected"; fi
  done
  if [ "$fails" -eq 0 ]; then
    echo "aws-oidc-bootstrap self-test: PASS"
    exit 0
  fi
  echo "aws-oidc-bootstrap self-test: FAIL ($fails)"
  exit 1
fi

# ── live preflight ─────────────────────────────────────────────────────────
command -v aws >/dev/null 2>&1 || die "aws CLI v2 is required"
command -v gh >/dev/null 2>&1 || die "gh is required"
export AWS_PROFILE

say "== caller (operator identity, not a managed role)"
caller="$(aws sts get-caller-identity --output json 2>/dev/null)" ||
  die "no AWS session for profile $AWS_PROFILE — run: aws sso login --profile $AWS_PROFILE"
ACCOUNT="$(jq -r .Account <<<"$caller")"
CALLER_ARN="$(jq -r .Arn <<<"$caller")"
case "$CALLER_ARN" in
  *":assumed-role/packages-porta-codes-"*)
    fail "refusing to run as a managed role ($CALLER_ARN): the bootstrap is the operator's authority"
    exit 1
    ;;
esac
pass "operator $CALLER_ARN in account $ACCOUNT"
PROVIDER_ARN="arn:aws:iam::$ACCOUNT:oidc-provider/$PROVIDER_HOST"

say "== the repository's OIDC subject configuration (must equal policies/oidc-subject.json)"
live_sub="$(gh api "repos/$REPO/actions/oidc/customization/sub")" || die "cannot read the OIDC subject configuration"
want_sub="$(jq -cS '{use_default, use_immutable_subject, sub_claim_prefix}' "$SUBJECT_FILE")"
got_sub="$(jq -cS '{use_default, use_immutable_subject, sub_claim_prefix}' <<<"$live_sub")"
if [ "$want_sub" = "$got_sub" ] && [ "$(jq -r .use_default <<<"$live_sub")" = true ]; then
  pass "subject configuration $got_sub"
else
  fail "subject configuration changed: live $got_sub, declared $want_sub — refusing to trust any subject"
  exit 1
fi
PREFIX="$(jq -r .sub_claim_prefix "$SUBJECT_FILE")"

say "== GitHub Environments (read back BEFORE AWS trusts them)"
# Environment evidence must be COMPLETE and OBSERVED, or AWS trusts nothing.
# A failed or partial read is never taken for an empty one: every collection is
# read with --paginate --slurp, each page must carry the collection and a
# total_count, all pages must agree on that count, and the items seen must add
# up to it. Anything else — 403/5xx/transport, a malformed or missing
# collection, a short page set — is UNOBSERVABLE and refuses that role.
gh_pages() { # $1 path, $2 collection key → the concatenated items (JSON array); rc 1 unobservable
  local raw
  raw="$(gh api --paginate --slurp "$1" 2>/dev/null)" || return 1
  jq -ce --arg k "$2" '
    if type == "array" and length > 0
       and all(.[]; type == "object" and (.[$k] | type) == "array" and (.total_count | type) == "number")
       and ([.[].total_count] | unique | length) == 1
       and ([.[][$k][]] | length) == .[0].total_count
    then [.[][$k][]] else error("incomplete") end' <<<"$raw" 2>/dev/null
}
env_ok() { # $1 environment → 0 iff exists, exactly branch main, no AWS_* secret — all observed
  local e="$1" out rc=0 pol names secrets bad=0
  out="$(gh api "repos/$REPO/environments/$e" 2>&1)" || rc=$?
  if [ "$rc" -ne 0 ]; then
    case "$out" in
      *"HTTP 404"* | *"Not Found"*) fail "Environment $e does not exist" ;;
      *) fail "Environment $e is UNOBSERVABLE (read failed) — refusing to trust it" ;;
    esac
    return 1
  fi
  if ! pol="$(jq -ce '.deployment_branch_policy | select(type == "object") | {custom_branch_policies, protected_branches}' <<<"$out" 2>/dev/null)"; then
    fail "Environment $e has no readable deployment policy — refusing to trust it"
    return 1
  fi
  [ "$pol" = '{"custom_branch_policies":true,"protected_branches":false}' ] || {
    fail "Environment $e deployment policy is $pol, not custom branch policies"
    bad=1
  }
  if ! names="$(gh_pages "repos/$REPO/environments/$e/deployment-branch-policies" branch_policies)"; then
    fail "Environment $e deployment branch policies are UNOBSERVABLE or incomplete — refusing to trust it"
    return 1
  fi
  names="$(jq -r '[.[] | "\(.type // "branch"):\(.name)"] | sort | join(",")' <<<"$names")"
  [ "$names" = "branch:main" ] || {
    fail "Environment $e may deploy from '$names', not exactly branch main"
    bad=1
  }
  if ! secrets="$(gh_pages "repos/$REPO/environments/$e/secrets" secrets)"; then
    fail "Environment $e secret inventory is UNOBSERVABLE or incomplete — refusing to trust it"
    return 1
  fi
  if jq -e 'any(.[]; (.name | ascii_downcase | startswith("aws_")))' <<<"$secrets" >/dev/null; then
    fail "Environment $e holds an AWS_* secret"
    bad=1
  fi
  [ "$bad" -eq 0 ] && pass "Environment $e: exactly branch main, no AWS secret (complete inventory)"
  return "$bad"
}
env_fail=""
while IFS='|' read -r role env _ _; do
  env_ok "$env" || env_fail="$env_fail $role"
done <<<"$ROLES"

say "== the account-global GitHub OIDC provider (by exact ARN)"
provider_ok=0
prov="" rc=0
aws_read prov -- iam get-open-id-connect-provider --open-id-connect-provider-arn "$PROVIDER_ARN" --output json || rc=$?
if [ "$rc" -eq 0 ]; then
  if jq -e --arg a "$AUD" '.ClientIDList | index($a)' <<<"$prov" >/dev/null; then
    pass "provider $PROVIDER_ARN registers audience $AUD"
    provider_ok=1
  else
    fail "provider $PROVIDER_ARN does not register audience $AUD"
  fi
elif [ "$mode" = apply ] && [ "$create_provider" = 1 ]; then
  aws iam create-open-id-connect-provider --url "https://$PROVIDER_HOST" --client-id-list "$AUD" \
    --thumbprint-list 6938fd4d98bab03faadb97b34396831e3780aea1 >/dev/null
  pass "provider created: $PROVIDER_ARN"
  provider_ok=1
else
  fail "provider $PROVIDER_ARN is absent (account-global; create it with --apply --create-provider only after confirming no other stack owns it)"
fi

# ── per role ───────────────────────────────────────────────────────────────
boundary_arn() { printf 'arn:aws:iam::%s:policy/%s-boundary' "$ACCOUNT" "$1"; }

ensure_boundary() { # $1 role, $2 document file
  local arn doc cur v
  arn="$(boundary_arn "$1")"
  doc="$(render "$2")"
  # shellcheck disable=SC2034 # filled by aws_read; only its status is used here
  local got="" rc=0
  aws_read got -- iam get-policy --policy-arn "$arn" --output json || rc=$?
  if [ "$rc" -eq 3 ]; then
    if [ "$mode" = apply ]; then
      aws iam create-policy --policy-name "$1-boundary" --policy-document "$doc" \
        --description "Bootstrap-owned permissions boundary for $1 (packages.porta.codes)" >/dev/null
      say "  created boundary $arn"
    else say "  would create boundary $arn"; fi
    return 0
  fi
  v="$(aws iam get-policy --policy-arn "$arn" --query Policy.DefaultVersionId --output text)"
  cur="$(aws iam get-policy-version --policy-arn "$arn" --version-id "$v" --query PolicyVersion.Document --output json)"
  if [ "$(canon "$cur")" != "$(canon "$doc")" ]; then
    if [ "$mode" = apply ]; then
      # A managed policy keeps at most five versions: drop the oldest non-default.
      if [ "$(aws iam list-policy-versions --policy-arn "$arn" --query 'length(Versions)' --output text)" -ge 5 ]; then
        old="$(aws iam list-policy-versions --policy-arn "$arn" --query 'Versions[?!IsDefaultVersion] | sort_by(@, &CreateDate)[0].VersionId' --output text)"
        aws iam delete-policy-version --policy-arn "$arn" --version-id "$old"
      fi
      aws iam create-policy-version --policy-arn "$arn" --policy-document "$doc" --set-as-default >/dev/null
      say "  updated boundary $arn"
    else say "  would update boundary $arn"; fi
  fi
}

ensure_role() { # $1 role, $2 environment, $3 permissions file or -, $4 boundary file
  local role="$1" sub trust cur_trust cur_b cur_s
  sub="$PREFIX:environment:$2"
  trust="$(trust_doc "$PROVIDER_ARN" "$sub")"
  ensure_boundary "$role" "$4"
  # shellcheck disable=SC2034 # filled by aws_read; only its status is used here
  local got="" rc=0
  aws_read got -- iam get-role --role-name "$role" --output json || rc=$?
  if [ "$rc" -eq 3 ]; then
    if [ "$mode" = apply ]; then
      aws iam create-role --role-name "$role" --assume-role-policy-document "$trust" \
        --permissions-boundary "$(boundary_arn "$role")" --max-session-duration "$MAX_SESSION" \
        --description "packages.porta.codes — GitHub OIDC, Environment $2 only (bootstrap-owned)" >/dev/null
      say "  created role $role"
    else say "  would create role $role (trust: $sub)"; fi
  else
    cur_trust="$(aws iam get-role --role-name "$role" --query Role.AssumeRolePolicyDocument --output json)"
    if [ "$(canon "$cur_trust")" != "$(canon "$trust")" ]; then
      if [ "$mode" = apply ]; then
        aws iam update-assume-role-policy --role-name "$role" --policy-document "$trust"
        say "  updated trust of $role"
      else say "  would update trust of $role to $sub"; fi
    fi
    cur_b="$(aws iam get-role --role-name "$role" --query 'Role.PermissionsBoundary.PermissionsBoundaryArn' --output text)"
    if [ "$cur_b" != "$(boundary_arn "$role")" ]; then
      if [ "$mode" = apply ]; then
        aws iam put-role-permissions-boundary --role-name "$role" --permissions-boundary "$(boundary_arn "$role")"
        say "  set boundary of $role"
      else say "  would set boundary of $role"; fi
    fi
    cur_s="$(aws iam get-role --role-name "$role" --query Role.MaxSessionDuration --output text)"
    if [ "$cur_s" != "$MAX_SESSION" ]; then
      if [ "$mode" = apply ]; then
        aws iam update-role --role-name "$role" --max-session-duration "$MAX_SESSION"
      else say "  would set max session of $role to $MAX_SESSION"; fi
    fi
  fi
  if [ "$3" != - ]; then
    local doc cur
    doc="$(render "$3")"
    cur='{}' rc=0
    if [ "$mode" = apply ] || aws iam get-role --role-name "$role" >/dev/null 2>&1; then
      aws_read cur -- iam get-role-policy --role-name "$role" --policy-name permissions --query PolicyDocument --output json || rc=$?
      [ "$rc" -eq 0 ] || cur='{}'
    fi
    if [ "$(canon "$cur")" != "$(canon "$doc")" ]; then
      if [ "$mode" = apply ]; then
        aws iam put-role-policy --role-name "$role" --policy-name permissions --policy-document "$doc"
        say "  set inline permissions of $role"
      else say "  would set inline permissions of $role"; fi
    fi
  fi
}

verify_role() { # read-only PASS/FAIL
  local role="$1" env="$2" sub r out inl att doc cur rc
  sub="$PREFIX:environment:$env"
  r="" rc=0
  aws_read r -- iam get-role --role-name "$role" --output json || rc=$?
  if [ "$rc" -eq 3 ]; then
    fail "$role does not exist"
    return
  fi
  if out="$(check_trust "$(jq -c .Role.AssumeRolePolicyDocument <<<"$r")" "$PROVIDER_ARN" "$sub")"; then
    pass "$role trust: provider by ARN, aud $AUD, StringEquals sub $sub"
  else
    while IFS= read -r l; do fail "$role trust: $l"; done <<<"$out"
  fi
  check "$role boundary $(boundary_arn "$role")" \
    [ "$(jq -r '.Role.PermissionsBoundary.PermissionsBoundaryArn // ""' <<<"$r")" = "$(boundary_arn "$role")" ]
  check "$role max session ≤ $MAX_SESSION s" [ "$(jq -r .Role.MaxSessionDuration <<<"$r")" -le "$MAX_SESSION" ]
  att="$(aws iam list-attached-role-policies --role-name "$role" --query 'AttachedPolicies[].PolicyName' --output text)"
  check "$role has no attached managed policy (found: '${att:-none}')" [ -z "$att" ]
  inl="$(aws iam list-role-policies --role-name "$role" --query 'PolicyNames' --output text | tr '\t' ' ')"
  if [ "$3" != - ]; then
    check "$role inline policies are exactly 'permissions' (found: '$inl')" [ "$inl" = permissions ]
    doc="$(render "$3")"
    cur="$(aws iam get-role-policy --role-name "$role" --policy-name permissions --query PolicyDocument --output json 2>/dev/null || echo '{}')"
    check "$role permissions equal $3" [ "$(canon "$cur")" = "$(canon "$doc")" ]
    if out="$(check_perms "$cur")"; then pass "$role permissions: no PassRole/sts/wildcard"; else while IFS= read -r l; do fail "$role permissions: $l"; done <<<"$out"; fi
  else
    case " $inl " in
      "  " | " $PUBLISHER_INLINE ") pass "$role inline policies: '${inl:-none yet}' (Terraform-owned)" ;;
      *) fail "$role inline policies: '$inl' (only $PUBLISHER_INLINE, owned by Terraform)" ;;
    esac
  fi
  cur="$(aws iam get-policy-version --policy-arn "$(boundary_arn "$role")" \
    --version-id "$(aws iam get-policy --policy-arn "$(boundary_arn "$role")" --query Policy.DefaultVersionId --output text 2>/dev/null)" \
    --query PolicyVersion.Document --output json 2>/dev/null || echo '{}')"
  check "$role boundary document equals $4" [ "$(canon "$cur")" = "$(canon "$(render "$4")")" ]
}

if [ "$mode" != verify ]; then
  say "== roles ($mode)"
  if [ "$provider_ok" != 1 ]; then
    fail "no role is created or changed without the provider"
  else
    while IFS='|' read -r role env perms boundary; do
      case " $env_fail " in
        *" $role "*)
          fail "$role: its Environment $env is not in order — AWS will not trust it"
          continue
          ;;
      esac
      say "-- $role (Environment $env)"
      ensure_role "$role" "$env" "$perms" "$boundary"
    done <<<"$ROLES"
  fi
  if [ "$mode" = apply ] && [ "$set_vars" = 1 ] && [ "$fails" -eq 0 ]; then
    gh variable set AWS_ACCOUNT_ID --repo "$REPO" --body "$ACCOUNT" >/dev/null
    gh variable set AWS_REGION --repo "$REPO" --body "$REGION" >/dev/null
    say "  repository variables AWS_ACCOUNT_ID, AWS_REGION set (not secrets)"
  fi
fi

if [ "$mode" != plan ]; then
  say "== verify (live)"
  while IFS='|' read -r role env perms boundary; do
    verify_role "$role" "$env" "$perms" "$boundary"
  done <<<"$ROLES"
fi

if [ "$fails" -eq 0 ]; then
  say "aws-oidc-bootstrap $mode: PASS"
  exit 0
fi
say "aws-oidc-bootstrap $mode: FAIL ($fails)"
exit 1
