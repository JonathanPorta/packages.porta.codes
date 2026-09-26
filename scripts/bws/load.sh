#!/bin/bash
# load-bws-secrets.sh
# Load secrets from Bitwarden Secrets Manager for local development.
#
# By default this exports the static-site portfolio's canonical 5-key set
# (AWS×2, Cloudflare×2, BetterUptime). There is no default optional key —
# SLACK_WEBHOOK_URL is NOT a default (Slack flows through github-slack-router);
# a repo that still needs it opts in via `.bws-secrets-list`. CLOUDFLARE_ACCOUNT_ID
# and BETTERUPTIME_API_TOKEN are `shared` (they live in the _shared-ci project),
# so the default path merges _shared-ci — see docs/shared-secrets.md. A consumer
# repo can override the list by dropping `.bws-secrets-list` at the repo
# root — same format as `scripts/bws/bootstrap.sh` reads:
#   - one key per line
#   - `#` comments + blank lines ignored
#   - trailing `?` marks a key as optional (missing → warn, not fail)

# Check if script is being sourced (not executed directly)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "❌ Error: This script must be sourced, not executed directly"
  echo "Usage: source scripts/bws/load.sh"
  echo "   or: . scripts/bws/load.sh"
  exit 1
fi

# Check if BWS_PROJECT_ID is set
if [ -z "$BWS_PROJECT_ID" ]; then
  echo "❌ Error: BWS_PROJECT_ID environment variable is required"
  echo "Please export your Bitwarden Secrets Manager project ID:"
  echo "export BWS_PROJECT_ID=\"your-project-id-here\""
  return 1
fi

# Check if BWS_ACCESS_TOKEN is set
if [ -z "$BWS_ACCESS_TOKEN" ]; then
  echo "❌ Error: BWS_ACCESS_TOKEN environment variable is required"
  echo "Please export your Bitwarden Secrets Manager access token:"
  echo "export BWS_ACCESS_TOKEN=\"your-access-token-here\""
  return 1
fi

echo "🔐 Loading secrets from Bitwarden Secrets Manager..."

# Check required commands are available
for _cmd in bws jq; do
  if ! command -v "$_cmd" &>/dev/null; then
    echo "❌ Error: $_cmd is not installed"
    if [ "$_cmd" = "bws" ]; then
      echo "Please install it from: https://github.com/bitwarden/sdk/releases"
    else
      echo "Install jq via your package manager (e.g. 'brew install jq')."
    fi
    unset _cmd
    return 1
  fi
done
unset _cmd

# Resolve the key list. The default is the static-site canonical set.
# Per-repo `.bws-secrets-list` (one key per line, `#` comments, trailing
# `?` marks optional) replaces the default when present.
_BWS_DEFAULT_REQUIRED=(
  AWS_ACCESS_KEY_ID
  AWS_SECRET_ACCESS_KEY
  CLOUDFLARE_ACCOUNT_ID
  CLOUDFLARE_API_TOKEN
  BETTERUPTIME_API_TOKEN
)
# No default optional key. SLACK_WEBHOOK_URL is opt-in via .bws-secrets-list
# only — Slack flows through github-slack-router, not per-repo webhooks.
_BWS_DEFAULT_OPTIONAL=()
_BWS_REQUIRED=()
_BWS_OPTIONAL=()
# Set true when the list marks any key `shared` → load.sh merges a shared
# project. See docs/shared-secrets.md.
_bws_has_shared=false
# Set true when any bare `shared` key (or the default set) needs the default
# shared project; named `shared:PROJECT` keys add their own projects instead.
_bws_needs_default_shared=false
# Space-delimited, deduped set of shared BWS projects to merge (#126).
_bws_shared_projects=""
_bws_add_shared_project() {
  [ -n "$1" ] || return 0
  case " $_bws_shared_projects " in
    *" $1 "*) return 0 ;;
    *) _bws_shared_projects="${_bws_shared_projects:+$_bws_shared_projects }$1" ;;
  esac
}

_bws_secrets_list_file="${BWS_SECRETS_LIST_FILE:-.bws-secrets-list}"
if [ -f "$_bws_secrets_list_file" ]; then
  # Delegate to the shared parser so this script and bws-bootstrap.sh
  # interpret the file identically — including rejecting unknown
  # fields and invalid types. See scripts/bws/_lib.sh and
  # CENTRALIZED-SECRETS.md for the format spec.
  #
  # Portable script-dir resolution (bash AND zsh). BASH_SOURCE is
  # bash-only; in zsh it's empty so `dirname "${BASH_SOURCE[0]}"`
  # resolves to "." and the source command looks for the parser file
  # in cwd instead of next to this script. zsh exposes the current
  # script via ${(%):-%x}, but that's a syntax error in bash, so we
  # defer-via-eval. POSIX shells without either fall back to $0.
  if [ -n "${BASH_VERSION:-}" ]; then
    _bws_self_dir=$(dirname "${BASH_SOURCE[0]}")
  elif [ -n "${ZSH_VERSION:-}" ]; then
    _bws_self_dir=$(eval 'dirname "${(%):-%x}"')
  else
    _bws_self_dir=$(dirname "$0")
  fi
  # shellcheck source=scripts/bws/_lib.sh
  . "$_bws_self_dir/_lib.sh"
  unset _bws_self_dir
  if ! _bws_parse_secrets_list "$_bws_secrets_list_file"; then
    unset -f _bws_parse_secrets_list
    return 1
  fi
  # Parallel-array iteration. bash arrays are 0-indexed; zsh arrays are
  # 1-indexed by default. Without shell-detect, a hardcoded 0..N-1 loop
  # reads arr[0] (empty in zsh-default) and skips arr[N] (the last
  # element). Symptom: an empty key in _BWS_REQUIRED + the last secret
  # silently dropped from validation.
  #
  # zsh also has KSH_ARRAYS option which switches to bash-like 0-indexed.
  # Detect via [[ -o ksharrays ]] (zsh-only syntax — eval-deferred so
  # bash doesn't choke on parsing it).
  if [ -n "${ZSH_VERSION:-}" ] && eval '[[ ! -o ksharrays ]]' 2>/dev/null; then
    # zsh default (1-indexed)
    _i=1
    _imax=${#_BWS_PARSED_KEYS[@]}
  else
    # bash, or zsh with KSH_ARRAYS set (0-indexed)
    _i=0
    _imax=$((${#_BWS_PARSED_KEYS[@]} - 1))
  fi
  _BWS_DELIVERED=()
  while [ "$_i" -le "$_imax" ]; do
    # A managed delivery (deliver:dependabot@OWNER/REPO) is copied by
    # bootstrap.sh into a Dependabot secrets namespace; no shell or Actions job
    # consumes it, so it is neither required nor optional here — it is not
    # loaded at all, and its absence from the environment is not a finding.
    if [ -n "${_BWS_PARSED_DELIVER[$_i]:-}" ]; then
      _BWS_DELIVERED+=("${_BWS_PARSED_KEYS[$_i]}")
      _i=$((_i + 1))
      continue
    fi
    if [ "${_BWS_PARSED_OPTIONAL[$_i]}" = "true" ]; then
      _BWS_OPTIONAL+=("${_BWS_PARSED_KEYS[$_i]}")
    else
      _BWS_REQUIRED+=("${_BWS_PARSED_KEYS[$_i]}")
    fi
    if [ "${_BWS_PARSED_SHARED[$_i]}" = "true" ]; then
      _bws_has_shared=true
      if [ -n "${_BWS_PARSED_SHARED_PROJECT[$_i]:-}" ]; then
        _bws_add_shared_project "${_BWS_PARSED_SHARED_PROJECT[$_i]}"
      else
        _bws_needs_default_shared=true
      fi
    fi
    _i=$((_i + 1))
  done
  unset _i _imax
  unset -f _bws_parse_secrets_list
  echo "🔧 Using $_bws_secrets_list_file override"
  echo "   required: ${_BWS_REQUIRED[*]:-(none)}"
  echo "   optional: ${_BWS_OPTIONAL[*]:-(none)}"
  if [ "${#_BWS_DELIVERED[@]}" -gt 0 ]; then
    echo "   not loaded (managed Dependabot deliveries): ${_BWS_DELIVERED[*]}"
  fi
else
  _BWS_REQUIRED=("${_BWS_DEFAULT_REQUIRED[@]}")
  _BWS_OPTIONAL=("${_BWS_DEFAULT_OPTIONAL[@]}")
  # The default set's CLOUDFLARE_ACCOUNT_ID + BETTERUPTIME_API_TOKEN are shared
  # (they live in _shared-ci), matching the canonical template — so merge it.
  _bws_has_shared=true
  _bws_needs_default_shared=true
fi

# Get all secrets and export them
if ! secrets=$(bws secret list "$BWS_PROJECT_ID" --output json); then
  echo "❌ Error: Failed to retrieve secrets from Bitwarden"
  echo "Check your BWS_ACCESS_TOKEN and permissions"
  return 1
fi

# Build the set of shared BWS projects to merge on top of the per-project
# secrets (#126). Three sources, deduped:
#   1. bare `shared` keys (and the default static-site set) → the default
#      project. `${VAR-default}` takes the canonical _shared-ci only when
#      BWS_SHARED_PROJECT_ID is *unset*; set it to "" to opt out of the default.
#   2. `shared:PROJECT` keys → their named project (collected in the loop above).
#   3. BWS_SHARED_PROJECT_IDS — a space/comma-separated list of extra projects
#      to always merge (the multi-value alias of BWS_SHARED_PROJECT_ID).
_bws_default_shared="${BWS_SHARED_PROJECT_ID-56910430-4974-4845-b42b-b458007d71be}"
if [ "$_bws_needs_default_shared" = "true" ] && [ -n "$_bws_default_shared" ]; then
  _bws_add_shared_project "$_bws_default_shared"
fi
if [ -n "${BWS_SHARED_PROJECT_IDS:-}" ]; then
  _bws_ids_rest="$(printf '%s' "$BWS_SHARED_PROJECT_IDS" | tr ',' ' ')"
  while [ -n "$_bws_ids_rest" ]; do
    _bws_one="${_bws_ids_rest%%[[:space:]]*}"
    case "$_bws_ids_rest" in
      *[[:space:]]*)
        _bws_ids_rest="${_bws_ids_rest#*[[:space:]]}"
        _bws_ids_rest="${_bws_ids_rest#"${_bws_ids_rest%%[![:space:]]*}"}"
        ;;
      *) _bws_ids_rest="" ;;
    esac
    [ -n "$_bws_one" ] && _bws_add_shared_project "$_bws_one"
  done
  unset _bws_ids_rest _bws_one
fi

# Merge each shared project's secrets on top of the per-project set. Shared
# values win on key collision (the per-project copy is a duplicate being
# retired — see docs/shared-secrets.md). Non-fatal per project: if one can't be
# read, fall through and let the per-project copy (or the missing-required check
# below) handle it.
if [ -n "$_bws_shared_projects" ]; then
  _bws_proj_rest="$_bws_shared_projects"
  while [ -n "$_bws_proj_rest" ]; do
    _bws_proj="${_bws_proj_rest%%[[:space:]]*}"
    case "$_bws_proj_rest" in
      *[[:space:]]*) _bws_proj_rest="${_bws_proj_rest#*[[:space:]]}" ;;
      *) _bws_proj_rest="" ;;
    esac
    [ -n "$_bws_proj" ] || continue
    echo "🔗 Merging shared secrets from $_bws_proj..."
    if _bws_shared=$(bws secret list "$_bws_proj" --output json 2>/dev/null); then
      secrets=$(printf '%s\n%s' "$secrets" "$_bws_shared" |
        jq -s 'add | reduce .[] as $s ({}; .[$s.key] = $s) | [.[]]')
    else
      echo "⚠️  Could not read shared project $_bws_proj (machine account needs read on it) — its keys must otherwise resolve from this project."
    fi
    unset _bws_shared
  done
  unset _bws_proj_rest _bws_proj
fi

# Helper: extract one secret's value from the cached JSON.
_bws_pick() {
  echo "$secrets" | jq -r --arg k "$1" '.[] | select(.key==$k) | .value // empty'
}

# Display helper: secrets whose name suggests sensitive material get
# fully masked; everything else shows the first 10 chars for sanity.
_bws_display() {
  local name="$1" value="$2"
  case "$name" in
    *_TOKEN | *_KEY | *_SECRET* | *_PASSWORD | *_WEBHOOK_URL)
      echo "[MASKED]"
      ;;
    *)
      if [ ${#value} -le 10 ]; then
        echo "$value"
      else
        echo "${value:0:10}..."
      fi
      ;;
  esac
}

missing_required=()
loaded_required=()
loaded_optional=()
missing_optional=()

for _key in "${_BWS_REQUIRED[@]}"; do
  _value=$(_bws_pick "$_key")
  if [ -z "$_value" ] || [ "$_value" = "null" ]; then
    missing_required+=("$_key")
    continue
  fi
  printf -v "$_key" '%s' "$_value"
  # `${_key?}` (with the parameter-set guard) quiets ShellCheck SC2163
  # without changing behavior — `_key` is always set in the for-loop
  # body. The `printf -v` above already wrote $_value into the
  # dynamically-named variable; this `export` just marks it for export.
  export "${_key?}"
  loaded_required+=("$_key")
done

for _key in "${_BWS_OPTIONAL[@]}"; do
  _value=$(_bws_pick "$_key")
  if [ -z "$_value" ] || [ "$_value" = "null" ]; then
    missing_optional+=("$_key")
    continue
  fi
  printf -v "$_key" '%s' "$_value"
  # `${_key?}` (with the parameter-set guard) quiets ShellCheck SC2163
  # without changing behavior — `_key` is always set in the for-loop
  # body. The `printf -v` above already wrote $_value into the
  # dynamically-named variable; this `export` just marks it for export.
  export "${_key?}"
  loaded_optional+=("$_key")
done

unset -f _bws_pick

# Defensively unset AWS_PROFILE so the AWS SDK / Terraform AWS provider use
# the BWS-exported AWS_ACCESS_KEY_ID + AWS_SECRET_ACCESS_KEY directly rather
# than trying to resolve a profile from ~/.aws/config. A leftover AWS_PROFILE
# — inherited from the operator's shell (e.g. an aws-plugin default) or set
# in a hand-authored consumer .env-sample — causes hard-to-debug
# `Error: failed to get shared config profile, <name>` on `terraform init`
# for any profile name the operator never wrote to ~/.aws/config (typically
# the CI deploy user name, e.g. `<APP_NAME>-ci`). Sourcing this loader is
# also the operator's signal that BWS env-credentials are now the source of
# truth, so AWS_PROFILE is both unnecessary and actively harmful. If you
# legitimately need a specific profile for an admin task (e.g. ruam.sh),
# set it INLINE at the invocation rather than in your shell or .env-sample:
#   AWS_PROFILE=<your-admin> ./scripts/ruam/ruam.sh --new
unset AWS_PROFILE

if [ ${#missing_required[@]} -gt 0 ]; then
  echo "❌ Error: Missing required secrets:"
  for secret in "${missing_required[@]}"; do
    echo "  - $secret"
  done
  unset -f _bws_display
  return 1
fi

# Indirect variable expansion. bash uses ${!_key} ("the value of the
# variable named by $_key"); zsh uses ${(P)_key} — different syntax, same
# meaning. zsh chokes on ${!_key} with "bad substitution"; bash chokes on
# ${(P)_key} the same way. Shell-detect + indirect via printf -v to a
# temp var so the display logic stays portable.
_bws_indirect() {
  local _name="$1"
  if [ -n "${BASH_VERSION:-}" ]; then
    # shellcheck disable=SC3053  # bash-only ${!name} is the point
    eval 'printf "%s" "${!_name}"'
  elif [ -n "${ZSH_VERSION:-}" ]; then
    eval 'printf "%s" "${(P)_name}"'
  else
    eval "printf '%s' \"\$$_name\""
  fi
}

echo "✅ Successfully loaded secrets from Bitwarden Secrets Manager:"
for _key in "${loaded_required[@]}"; do
  printf "  - %-25s %s\n" "$_key:" "$(_bws_display "$_key" "$(_bws_indirect "$_key")")"
done
for _key in "${loaded_optional[@]}"; do
  printf "  - %-25s %s\n" "$_key:" "$(_bws_display "$_key" "$(_bws_indirect "$_key")")"
done
for _key in "${missing_optional[@]}"; do
  printf "  - %-25s (not in BWS — consumers using this key will degrade gracefully)\n" "$_key:"
done

unset -f _bws_indirect

unset -f _bws_display
unset _BWS_REQUIRED _BWS_OPTIONAL _BWS_DEFAULT_REQUIRED _BWS_DEFAULT_OPTIONAL
unset _BWS_PARSED_KEYS _BWS_PARSED_OPTIONAL _BWS_PARSED_TYPE _BWS_PARSED_SHARED _BWS_PARSED_SHARED_PROJECT _BWS_PARSED_REQ _BWS_PARSED_DELIVER _BWS_DELIVERED
unset _bws_has_shared _bws_needs_default_shared _bws_shared_projects _bws_default_shared
unset -f _bws_add_shared_project
unset _bws_secrets_list_file _raw _line _key _value _cmd
unset missing_required loaded_required loaded_optional missing_optional secrets

echo ""
echo "🚀 Ready for local development! You can now run make commands."
