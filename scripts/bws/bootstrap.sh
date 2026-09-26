#!/usr/bin/env bash
# scripts/bws/bootstrap.sh
#
# Wizard that bootstraps Bitwarden Secrets Manager (BWSM) + GitHub Actions
# for a portfolio static-site repo. Idempotent — re-running only creates
# resources that don't already exist.
#
# Usage:
#   ./scripts/bws/bootstrap.sh [--app-name foo.com] [--dry-run] [--rotate-token]
#
# Bash 3.2 compatible (macOS /bin/bash). Tested with bash 3.2.57 and 5.x.
#
# Secret-handling caveat:
#   The Bitwarden CLI (`bws secret create KEY VALUE PROJECT_ID`) takes the
#   secret value as a positional argument, so for the brief duration of each
#   create call the value is visible in the process table on the local
#   machine. Run this on a trusted single-user workstation; do not run it
#   during screen-share, on a multi-tenant host, or with shell trace logging
#   enabled. Existing secrets are never re-created, so this exposure is
#   only present on the first bootstrap of a given project.
#
#   To eliminate the exposure entirely, pass `--no-secret-values`: the
#   wizard will create the BWS project and the GH access token but will
#   NOT call `bws secret create` for any secret value. Each missing
#   secret gets explicit instructions for adding the value via the
#   Bitwarden vault web UI. On the next run, the wizard sees those
#   secrets exist in BWSM and proceeds with file edits as normal.

# Self-promote to bash if we ended up running under another shell. The shebang
# above usually handles this, but if the script is sourced from zsh, or invoked
# via a wrapper that doesn't honor the shebang, we end up with zsh's `read -p`
# interpretation (which means "read from coprocess", not "show prompt"). This
# guard re-execs under bash so the rest of the script can rely on bash builtins.
if [ -z "${BASH_VERSION:-}" ]; then
  exec bash "$0" "$@"
fi

set -euo pipefail
# `set -E` propagates the ERR trap into shell functions and command
# substitutions; without it, the trap below would not fire inside our
# helper functions (which is where the silent bails actually happen).
set -E
umask 077

# Diagnostic trap. Under `set -euo pipefail`, a propagated non-zero exit
# (typically a `grep` inside a pipeline finding nothing → pipefail →
# `set -e` exit) terminates the script with no context. Without this
# trap, the operator sees `make: *** Error 1` and has to read source to
# figure out which line, function, or command failed. With it, every
# bail surfaces the file, line, exit code, and command that triggered.
# shellcheck disable=SC2154  # `rc` is assigned at trap-fire time via $?.
trap 'rc=$?; printf "\nERROR: %s line %s exit %s\n  while running: %s\n" \
  "${BASH_SOURCE[0]}" "$LINENO" "$rc" "$BASH_COMMAND" >&2; exit $rc' ERR

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
# Family of patterns the wizard *accepts* as a placeholder when reading.
# A consumer's templated file may use any of these (the all-zeros
# canonical form, a monotonically-incrementing-suffix variant for visual
# distinguishability, the literal "<UUID>" stub, or the BWS-docs
# "xxxxxxxx-..." stub) — any value matching the family is treated as
# unfilled and rewritten to the real UUID. Anything else is treated as
# a real, already-populated value and left alone.
#
# The PATTERNS form (no anchors, used inside larger sed regexes) and the
# REGEX form (anchored, used for whole-string bash comparisons) are kept
# in sync. See `is_placeholder_uuid` below.
PLACEHOLDER_PATTERNS='(00000000-0000-0000-0000-[0-9a-fA-F]{12}|<UUID>|xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx)'
PLACEHOLDER_REGEX="^${PLACEHOLDER_PATTERNS}$"

# Pattern for "any value the extract helpers should pull off a UUID-
# bearing line": real UUIDs (36-char hex form) PLUS every member of
# PLACEHOLDER_PATTERNS that isn't already covered by the hex form (i.e.
# `<UUID>` and `xxxxxxxx-…`). The hex form already covers the
# all-zeros + monotonic-suffix placeholders. Kept separate from
# PLACEHOLDER_PATTERNS because the placeholder check itself is a
# strict subset — a real UUID extracts fine but is not a placeholder.
EXTRACTABLE_PATTERNS='([0-9a-fA-F-]{36}|<UUID>|xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx)'

is_placeholder_uuid() {
  [[ "${1:-}" =~ $PLACEHOLDER_REGEX ]]
}

# Default key list. This is the static-site portfolio's canonical set —
# AWS access for the Terraform-managed S3 site, Cloudflare for DNS/page-
# rules, BetterUptime for monitors. A consumer repo whose CI needs a
# different set (e.g. a Chrome extension that needs RELEASE_TOKEN +
# OPENAI_API_KEY, or a site that still wants the deprecated per-repo
# Slack webhook) can override by dropping a `.bws-secrets-list` file at
# the repo root; the override loader below replaces this array if
# present.
#
# Note: SLACK_WEBHOOK_URL is intentionally NOT in the default set.
# Portfolio Slack notifications flow through github-slack-router (see
# docs/slack-notifications.md); new repos should not carry a per-repo
# Slack webhook. Repos that still need one for legitimate self-notify
# (e.g. github-slack-router itself) can opt in via .bws-secrets-list.
DEFAULT_KEYS=(
  AWS_ACCESS_KEY_ID
  AWS_SECRET_ACCESS_KEY
  CLOUDFLARE_ACCOUNT_ID
  CLOUDFLARE_API_TOKEN
  BETTERUPTIME_API_TOKEN
)
# Of the default set, these two are `shared` — identical across every site,
# so they live in the _shared-ci project, not the per-project one. This must
# match the canonical load-secrets template (which bakes their _shared-ci
# UUIDs) so the no-`.bws-secrets-list` default path stays consistent with CI:
# bootstrap skips creating them, and load.sh merges _shared-ci. A repo that
# overrides via .bws-secrets-list controls `shared` per-key there instead.
# See docs/shared-secrets.md.
DEFAULT_SHARED_KEYS=(
  CLOUDFLARE_ACCOUNT_ID
  BETTERUPTIME_API_TOKEN
)
KEYS=("${DEFAULT_KEYS[@]}")

# Set true by load_keys_override if any key is marked `shared` in
# .bws-secrets-list. Gates the "grant read on _shared-ci" reminder in
# the machine-account step. See docs/shared-secrets.md.
HAS_SHARED=false
# Set true when a bare `shared` key (→ default _shared-ci) is present; and a
# space-delimited deduped set of named `shared:PROJECT` projects (#126). Used to
# point the "grant the machine account read on <project>" reminder at the right
# projects.
HAS_BARE_SHARED=false
NAMED_SHARED_PROJECTS=""
# Canonical shared BWS project (id + name) — only referenced in operator
# guidance text; bootstrap never writes to it. See docs/shared-secrets.md.
SHARED_PROJECT_ID="56910430-4974-4845-b42b-b458007d71be"
SHARED_PROJECT_NAME="_shared-ci"
# Tracked, repository-owned application identity. One line, the app name.
APP_NAME_FILE=".bws-app-name"
# Managed deliveries (`deliver:dependabot@OWNER/REPO` in .bws-secrets-list).
# LOADER_KEYS are the keys CI loads through the generated Actions loader — the
# historical meaning of "a declared key". DELIVERED_KEYS are copied by this
# wizard into a GitHub Dependabot secrets namespace instead, because Dependabot
# cannot read Bitwarden. A repository whose every key is delivered has NO
# Actions consumer, so it gets no machine account, no BWS_ACCESS_TOKEN and no
# loader file: those exist to let Actions read Bitwarden, and nothing here does.
LOADER_KEYS=()
DELIVERED_KEYS=()
HAS_DELIVERIES=false
HAS_LOADER_KEYS=true

# Source the shared parser. Both this script and load-bws-secrets.sh
# delegate to `_bws_parse_secrets_list` so the format is interpreted
# identically by both consumers — see scripts/bws/_lib.sh
# and CENTRALIZED-SECRETS.md for the format spec.
# shellcheck source=scripts/bws/_lib.sh
. "$(dirname "$0")/_lib.sh"

# Per-repo override loader. Reads `.bws-secrets-list` via the shared
# parser, overwrites the static-site default KEYS array, and stashes
# each key's type in `TYPE_<KEY>` and shared-flag in `SHARED_<KEY>` at
# the global scope so `help_blurb` can dispatch by type and the create
# loop can skip shared keys (which live in the _shared-ci project, not
# this one — see docs/shared-secrets.md).
load_keys_override() {
  local file="${SECRETS_LIST_OPT:-${BWS_SECRETS_LIST_FILE:-.bws-secrets-list}}"
  # A relative declaration path belongs to the REPOSITORY, not to whatever
  # directory the operator happened to be standing in. Resolved against the cwd
  # it silently vanished from any subdirectory, and the wizard then ran the
  # static-site DEFAULT key set — reporting success over a key set the repository
  # never declared. Same failure shape as the basename identity bug: a
  # repository-owned fact read from the ambient filesystem.
  case "$file" in
    /*) ;;
    *) [[ -f "$file" ]] || file="${REPO_ROOT:-.}/$file" ;;
  esac
  if [[ ! -f "$file" ]]; then
    # No override → apply the static-site default `shared` markers so the
    # default path matches the canonical template + load.sh. Without this,
    # bootstrap would create per-project copies of keys CI loads from
    # _shared-ci. See docs/shared-secrets.md.
    local sk
    for sk in "${DEFAULT_SHARED_KEYS[@]}"; do
      printf -v "SHARED_$sk" '%s' "true"
      HAS_SHARED=true
      HAS_BARE_SHARED=true
    done
    LOADER_KEYS=("${KEYS[@]}")
    return 0
  fi

  _bws_parse_secrets_list "$file" || die "Failed to parse $file (see error above)."

  local i
  for ((i = 0; i < ${#_BWS_PARSED_KEYS[@]}; i++)); do
    printf -v "TYPE_${_BWS_PARSED_KEYS[$i]}" '%s' "${_BWS_PARSED_TYPE[$i]}"
    printf -v "SHARED_${_BWS_PARSED_KEYS[$i]}" '%s' "${_BWS_PARSED_SHARED[$i]}"
    printf -v "SHARED_PROJECT_${_BWS_PARSED_KEYS[$i]}" '%s' "${_BWS_PARSED_SHARED_PROJECT[$i]}"
    printf -v "REQ_${_BWS_PARSED_KEYS[$i]}" '%s' "${_BWS_PARSED_REQ[$i]}"
    printf -v "DELIVER_${_BWS_PARSED_KEYS[$i]}" '%s' "${_BWS_PARSED_DELIVER[$i]}"
    if [[ -n "${_BWS_PARSED_DELIVER[$i]}" ]]; then
      DELIVERED_KEYS+=("${_BWS_PARSED_KEYS[$i]}")
      HAS_DELIVERIES=true
    else
      LOADER_KEYS+=("${_BWS_PARSED_KEYS[$i]}")
    fi
    if [[ "${_BWS_PARSED_SHARED[$i]}" == "true" ]]; then
      HAS_SHARED=true
      if [[ -n "${_BWS_PARSED_SHARED_PROJECT[$i]}" ]]; then
        case " $NAMED_SHARED_PROJECTS " in
          *" ${_BWS_PARSED_SHARED_PROJECT[$i]} "*) ;;
          *) NAMED_SHARED_PROJECTS="${NAMED_SHARED_PROJECTS:+$NAMED_SHARED_PROJECTS }${_BWS_PARSED_SHARED_PROJECT[$i]}" ;;
        esac
      else
        HAS_BARE_SHARED=true
      fi
    fi
  done

  KEYS=("${_BWS_PARSED_KEYS[@]}")
  [[ ${#LOADER_KEYS[@]} -gt 0 ]] || HAS_LOADER_KEYS=false
  info "Using $file override (${#KEYS[@]} keys: ${KEYS[*]})"
  if $HAS_DELIVERIES; then
    info "Managed deliveries: ${DELIVERED_KEYS[*]-} (copied into a Dependabot secrets namespace; not loaded by Actions)"
    $HAS_LOADER_KEYS || info "No key is consumed through the Actions loader — machine account, BWS_ACCESS_TOKEN and the loader file are not applicable to this repository"
  fi
  # NOTE: must be `if/then/fi`, not `$HAS_SHARED && info ...`. When the override
  # file exists with NO `shared`-marked keys, HAS_SHARED stays `false`; that
  # short-circuit evaluates as `false && ...` and the function would return 1.
  # With `set -E`, callers see ERR fire on a successful parse with no shared
  # keys (regression introduced in 1.0.2 when shared-keys support landed).
  if $HAS_SHARED; then
    if [[ -n "$NAMED_SHARED_PROJECTS" ]]; then
      local _projlist=""
      $HAS_BARE_SHARED && _projlist="$SHARED_PROJECT_NAME"
      _projlist="${_projlist:+$_projlist, }$NAMED_SHARED_PROJECTS"
      info "  shared keys live in: $_projlist — skipping their per-project create."
      info "  the machine account needs read access on each of those projects."
    else
      info "  shared keys live in $SHARED_PROJECT_NAME — skipping their per-project create."
    fi
  fi
}
# Invocation deferred until after helpers + CLI-arg parsing run; see
# call site below the resolved-values banner.

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------
say() { printf '%s\n' "$*"; }
info() { printf '==> %s\n' "$*"; }
ok() { printf '    ✓ %s\n' "$*"; }
warn() { printf '    ! %s\n' "$*" >&2; }
err() { printf 'ERROR: %s\n' "$*" >&2; }
die() {
  err "$*"
  exit 1
}

print_usage() {
  cat <<'EOF'
bws-bootstrap.sh — BWSM + GitHub bootstrap wizard

Usage:
  scripts/bws/bootstrap.sh [options]

Options:
  --app-name NAME      Override APP_NAME (default: APP_NAME env or basename of repo).
                       Must match: ^[a-z0-9][a-z0-9.-]*[a-z0-9]$
  --plan               READ-ONLY inventory. Reads the BWS project and secret
                       NAMES and the repository's GitHub secret NAMES, then
                       prints one consolidated operator block: every declared
                       credential's status and its exact next action. Creates
                       nothing, sets nothing, prompts for nothing, edits no
                       file, and requests no secret VALUE. Requires the same
                       tools and BWS_ACCESS_TOKEN a real run does — that is
                       what lets it report `present` instead of guessing.
                       Cannot be combined with any mutating option.
  --dry-run            Print what would happen. No external calls. No file edits.
                       Does NOT require BWS_ACCESS_TOKEN, gh auth, bws, gh, or jq.
  --rotate-token       Force re-prompt and overwrite of GH BWS_ACCESS_TOKEN even if
                       already set. Useful if the machine-account token leaked.
  --rotate-secret KEY  Replace the VALUE of the existing BWS secret KEY (its UUID
                       and every mapping that names it are preserved), prompting
                       hidden or reading $KEY from the environment. With
                       --no-secret-values it prints the vault edit instructions
                       instead. A key with a managed delivery is re-synchronised
                       to its destination in the same run (the delivery copy is
                       older than the new Bitwarden revision). Repeatable.
  --resync-deliveries  Re-deliver every `deliver:` key even when the destination
                       copy is already newer than the Bitwarden revision. Use
                       after a destination secret was deleted or overwritten
                       outside this wizard.
  --no-secret-values   Create the BWS project and GH access token, but do NOT
                       call `bws secret create` for any secret value. Each
                       missing secret gets instructions for adding the value
                       via the Bitwarden vault web UI. Eliminates the brief
                       argv-exposure window inherent to `bws secret create`.
                       Re-run the wizard after pasting values in the web UI:
                       it will detect the now-existing secrets and proceed
                       with file edits.
  --test-scaffold-to DIR  TEST-ONLY. Run the real scaffold path and write ONLY
                       beneath DIR, then exit. No BWS/GitHub/auth/interactive
                       calls. Cannot be combined with mutating options.
  --secrets-list PATH  Read the key declaration from PATH instead of
                       .bws-secrets-list. Lets one repository carry a second,
                       deployment-only declaration.
  --loader PATH        Write the generated loader to PATH instead of
                       .github/actions/load-secrets/action.yml, so a second
                       profile cannot overwrite the first profile's loader.
  --project-id-file PATH
                       Write/read the BWS_PROJECT_ID line in PATH instead of
                       .env-sample.
  --gh-environments LIST
                       Comma-separated GitHub Environments. Sets BWS_ACCESS_TOKEN
                       as an ENVIRONMENT secret in each one instead of a
                       repository secret, and never touches the repository-scoped
                       secret. The environments must already exist.
  --scaffold           Before the placeholder-fill step, create any of these tracked
                       target files that don't already exist in the consumer repo:
                         .env-sample
                         .github/actions/load-secrets/action.yml (built from the
                                 active KEYS array — respects .bws-secrets-list)
                       Never overwrites existing files; .env is never scaffolded
                       (gitignored, operator-managed). Default: off — safer for
                       already-bootstrapped repos.
  -h, --help           Print this help.

Environment:
  APP_NAME                 Site domain (e.g. example.com). Required if --app-name not given.
  BWS_ACCESS_TOKEN         BWSM admin/org token with project-create permission.
                           Required except in --dry-run.
  AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY,
  CLOUDFLARE_ACCOUNT_ID, CLOUDFLARE_API_TOKEN,
  BETTERUPTIME_API_TOKEN
                           Optional. If set, used silently for any secret that
                           doesn't already exist in BWS. Otherwise prompts.
                           SLACK_WEBHOOK_URL is no longer in the default key
                           set — portfolio Slack flows through
                           github-slack-router. Add it via .bws-secrets-list
                           if a repo legitimately self-notifies.

What it does (idempotent):
  1. Resolves APP_NAME and target GitHub repo.
  2. Ensures BWS project "$APP_NAME" exists.
  3. Ensures each secret in .bws-secrets-list (default: AWS×2, Cloudflare×2,
     BetterUptime) exists; prompts for missing values. Keys marked `shared`
     live in the _shared-ci project and are skipped here (see docs/shared-secrets.md).
  4. If GH repo secret BWS_ACCESS_TOKEN is missing, prints web-UI instructions
     for creating the BWS machine account, then sets the GH secret.
  5. Auto-fills placeholder UUIDs in .env-sample, .env (with backup),
     and .github/actions/load-secrets/action.yml. Never overwrites real UUIDs.
     Steps 4-5 are skipped as "not applicable" when every declared key is a
     managed delivery (no Actions consumer).
  6. Managed deliveries: for each `deliver:dependabot@OWNER/REPO` key, keeps a
     copy of the Bitwarden value in that repository's Dependabot secrets
     (same name). Bitwarden is authoritative; the copy is re-synchronised when
     the Bitwarden revision is newer, and verified after every write. A
     github_pat is proved able to read its declared repositories first, and
     its GitHub-reported expiry is recorded in the secret's note.
  7. Prints a summary with per-resource status.

What it does NOT do:
  - Create the AWS IAM user (use scripts/ruam/ruam.sh).
  - Create the BWS machine account or its access token (web-UI only).
  - Create the Cloudflare API token (web-UI only — guidance is printed).
  - Create the BetterUptime token or Slack webhook (web-UI only).
  - Scaffold missing repo files unless --scaffold is passed. Without the
    flag, the wizard edits .env-sample, .env, and
    .github/actions/load-secrets/action.yml in place and reports
    "not-found" in the summary if any are absent.
EOF
}

# ---------------------------------------------------------------------------
# Arg parse
# ---------------------------------------------------------------------------
APP_NAME="${APP_NAME:-}"
APP_NAME_FROM_FLAG=false
DRY_RUN=false
# --plan: a genuinely read-only inventory. It performs the SAME live reads a
# real run performs (so it can say `present` or `missing` rather than guessing),
# and NO write of any kind. Distinct from --dry-run, whose contract is "no
# external calls" — that contract is what makes --dry-run unable to answer the
# only question an operator actually has before a ceremony: which credentials
# already exist. Every mutation in this script is gated on $MUTATE.
PLAN=false
MUTATE=true
SCAFFOLD_ONLY=false
TEST_SCAFFOLD_TO=""
ROTATE_TOKEN=false
ROTATE_SECRETS=""
RESYNC_DELIVERIES=false
NO_SECRET_VALUES=false
SCAFFOLD=false
# Deployment-profile options. Empty means "the repository's single default
# profile", which is exactly the historical behaviour — every one of these is
# opt-in, so an existing consumer's invocation is unchanged.
SECRETS_LIST_OPT=""
LOADER_OPT=""
PROJECT_ID_FILE_OPT=""
GH_ENVIRONMENTS=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app-name)
      [[ $# -ge 2 ]] || die "--app-name requires a value"
      APP_NAME="$2"
      APP_NAME_FROM_FLAG=true
      shift 2
      ;;
    --plan)
      PLAN=true
      MUTATE=false
      shift
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --rotate-token)
      ROTATE_TOKEN=true
      shift
      ;;
    --rotate-secret)
      [[ $# -ge 2 ]] || die "--rotate-secret requires a KEY"
      [[ "$2" =~ ^[A-Z][A-Z0-9_]*$ ]] || die "--rotate-secret: '$2' is not a declared-key name"
      ROTATE_SECRETS="${ROTATE_SECRETS:+$ROTATE_SECRETS }$2"
      shift 2
      ;;
    --resync-deliveries)
      RESYNC_DELIVERIES=true
      shift
      ;;
    --no-secret-values)
      NO_SECRET_VALUES=true
      shift
      ;;
    --test-scaffold-to)
      # TEST-ONLY seam. Runs the REAL SCRIPT_DIR -> TEMPLATES_DIR ->
      # scaffold_files -> emitter path, writing ONLY beneath DIR, then exits.
      # Makes no BWS, GitHub, auth, or interactive call.
      #
      # ONE flag, not two: an independent --out-root could be combined with a
      # normal mutating run and silently redirect a real bootstrap's writes. A
      # single exclusive option cannot be half-applied.
      #
      # It is NOT "no file edits" — it writes beneath DIR. Saying otherwise
      # would be the same overstated-guarantee habit this branch keeps fixing.
      TEST_SCAFFOLD_TO="${2:-}"
      [[ -n "$TEST_SCAFFOLD_TO" ]] || die "--test-scaffold-to requires a directory argument"
      case "$TEST_SCAFFOLD_TO" in
        -*) die "--test-scaffold-to got what looks like a flag: '$TEST_SCAFFOLD_TO'" ;;
      esac
      SCAFFOLD_ONLY=true
      SCAFFOLD=true
      DRY_RUN=true # ride DRY_RUN's existing external/interactive suppression
      shift 2
      ;;
    --scaffold)
      SCAFFOLD=true
      shift
      ;;
    --secrets-list)
      [[ $# -ge 2 ]] || die "--secrets-list requires a path"
      SECRETS_LIST_OPT="$2"
      shift 2
      ;;
    --loader)
      [[ $# -ge 2 ]] || die "--loader requires a path"
      LOADER_OPT="$2"
      shift 2
      ;;
    --project-id-file)
      [[ $# -ge 2 ]] || die "--project-id-file requires a path"
      PROJECT_ID_FILE_OPT="$2"
      shift 2
      ;;
    --gh-environments)
      [[ $# -ge 2 ]] || die "--gh-environments requires a comma-separated list"
      GH_ENVIRONMENTS="$2"
      shift 2
      ;;
    -h | --help)
      print_usage
      exit 0
      ;;
    *) die "Unknown argument: $1 (see --help)" ;;
  esac
done

# ---------------------------------------------------------------------------
# Pre-flight guards
# ---------------------------------------------------------------------------

# Refuse to run with shell xtrace enabled — secret values would echo to terminal/logs.
if [[ -o xtrace ]]; then
  die "Refusing to run with 'set -x' / xtrace enabled (would leak secrets). Re-run without xtrace."
fi

# --plan promises zero mutations. Reject every option that would make that false
# BEFORE anything runs, rather than letting a combination half-apply.
if $PLAN; then
  [[ -z "$ROTATE_SECRETS" ]] || die "--plan cannot be combined with --rotate-secret (--plan makes no change of any kind)"
  for _pair in "DRY_RUN:--dry-run" "ROTATE_TOKEN:--rotate-token" "RESYNC_DELIVERIES:--resync-deliveries" \
    "NO_SECRET_VALUES:--no-secret-values" "SCAFFOLD:--scaffold" "SCAFFOLD_ONLY:--test-scaffold-to"; do
    _var="${_pair%%:*}"
    _flag="${_pair#*:}"
    [[ "${!_var:-false}" == true ]] &&
      die "--plan cannot be combined with $_flag (--plan makes no change of any kind)"
  done
fi

# Must be inside a git repo (we resolve APP_NAME from cwd, edit files relative to repo root).
if $SCAFFOLD_ONLY; then
  # Reject every mutating combination BEFORE creating anything.
  # Explicit variable→flag pairs, not a case-folded derivation.
  #
  # `${_bad,,}` was two bugs in one expansion. It is bash 4.0+, so on macOS's
  # system bash 3.2 — which is what `bash` resolves to on a stock Mac, and what
  # runs this repo's tests there — it raised `bad substitution` instead of the
  # intended message. And even where it worked it produced the WRONG name:
  # ROTATE_TOKEN case-folds to `rotate_token`, so the diagnostic pointed at
  # `--rotate_token`, a flag that does not exist. Deriving a user-facing flag
  # name from a variable name only looks equivalent while the two happen to
  # match; spell the pairs out.
  # Indirect expansion (`${!var}`) is bash 2.0+, so it was never the problem and
  # stays; only the case folding had to go.
  for _pair in "ROTATE_TOKEN:--rotate-token" "NO_SECRET_VALUES:--no-secret-values"; do
    _var="${_pair%%:*}"
    _flag="${_pair#*:}"
    [[ "${!_var:-false}" == true ]] &&
      die "--test-scaffold-to cannot be combined with $_flag (test-only mode makes no external change)"
  done
  # The path flags select where generated artifacts land, and an absolute or
  # parent-traversing value would resolve OUTSIDE the scratch root while the
  # summary still claimed everything was written beneath it. Test-only mode
  # exists to bound local writes, so those values are refused before any file is
  # created rather than silently escaping.
  for _pair in "LOADER_OPT:--loader" "PROJECT_ID_FILE_OPT:--project-id-file"; do
    _var="${_pair%%:*}"
    _flag="${_pair#*:}"
    _val="${!_var:-}"
    [[ -n "$_val" ]] || continue
    case "$_val" in
      /*)
        die "--test-scaffold-to refuses an absolute $_flag ('$_val'): it would write outside the test root"
        ;;
      *..*)
        die "--test-scaffold-to refuses a parent-traversing $_flag ('$_val'): it would write outside the test root"
        ;;
    esac
  done
  [[ "$TEST_SCAFFOLD_TO" != /dev/* ]] || die "--test-scaffold-to refuses a device path"
  if [[ -e "$TEST_SCAFFOLD_TO" && ! -d "$TEST_SCAFFOLD_TO" ]]; then
    die "--test-scaffold-to '$TEST_SCAFFOLD_TO' exists and is not a directory"
  fi
fi

if [[ -n "$TEST_SCAFFOLD_TO" ]]; then
  # Scaffold into an explicit directory instead of the repo. Only meaningful
  # with --scaffold-only; keeps the test off the real working tree.
  mkdir -p "$TEST_SCAFFOLD_TO" || die "could not create --test-scaffold-to: $TEST_SCAFFOLD_TO"
  REPO_ROOT="$(cd "$TEST_SCAFFOLD_TO" && pwd -P)"
elif ! REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null); then
  die "Not inside a git repository."
fi

# Resolve APP_NAME, and record WHERE it came from.
#
# This used to be `basename "$REPO_ROOT"` and nothing else, which made the
# application identity — and therefore the BWS project this wizard reads and
# writes — a property of what the checkout directory happens to be CALLED. A
# git worktree is named by whoever created it, so `git worktree add ../wt-emit`
# silently retargeted the whole ceremony at a BWS project named `wt-emit`, and
# the only way back was to know to pass `--app-name`. Identity that a normal
# clone and an arbitrarily named worktree disagree about is not identity.
#
# So the repository declares its own name in a tracked file, and the directory
# is only consulted when it does not. The basename fallback stays because
# consumer repos of the released script rely on it, but it now says so out loud.
APP_NAME_SOURCE=""
if [[ -n "$APP_NAME" ]]; then
  if $APP_NAME_FROM_FLAG; then
    APP_NAME_SOURCE="--app-name flag"
  else
    APP_NAME_SOURCE="APP_NAME environment variable"
  fi
else
  # The declaration is TRACKED, so git materializes it in the main checkout and
  # in every linked worktree alike — which is exactly why it is the right home
  # for an identity the two must agree on. Reading it from $REPO_ROOT needs no
  # worktree special case at all.
  _app_decl=""
  [[ -f "$REPO_ROOT/$APP_NAME_FILE" ]] && _app_decl="$REPO_ROOT/$APP_NAME_FILE"
  if [[ -n "$_app_decl" ]]; then
    # First non-comment, non-blank line; trimmed.
    APP_NAME="$(sed -e 's/#.*//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' "$_app_decl" | grep -v '^$' | head -n1)"
    APP_NAME_SOURCE="$APP_NAME_FILE (declared by the repository)"
    [[ -n "$APP_NAME" ]] || die "$_app_decl is present but declares no application name."
  else
    APP_NAME=$(basename "$REPO_ROOT")
    APP_NAME_SOURCE="basename of $REPO_ROOT — no $APP_NAME_FILE in this repository"
  fi
fi

# Validate APP_NAME — strict domain-style, lowercase, no shell metachars.
if [[ ! "$APP_NAME" =~ ^[a-z0-9][a-z0-9.-]*[a-z0-9]$ ]]; then
  die "APP_NAME '$APP_NAME' is invalid. Must match ^[a-z0-9][a-z0-9.-]*[a-z0-9]$ (lowercase, dots/hyphens internal)."
fi

require_cmd() {
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || die "Required command not found: $c"
  done
}

if $DRY_RUN; then
  REPO="<dry-run: not resolved>"
  PROJECT_NAME="$APP_NAME"
  CI_NAME="${APP_NAME}-ci"
else
  require_cmd bws gh jq
  [[ -n "${BWS_ACCESS_TOKEN:-}" ]] || die "BWS_ACCESS_TOKEN env var is required (except in --dry-run)."
  gh auth status >/dev/null 2>&1 || die "gh CLI not authenticated. Run 'gh auth login' first."
  PROJECT_NAME="$APP_NAME"
  CI_NAME="${APP_NAME}-ci"
  REPO=$(gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null) ||
    die "gh repo view failed. Are you in a repo with a configured GitHub remote?"
fi

# Print resolved values and confirm.
#
# This block is the first thing an operator reads, so it answers the questions
# that decide whether to continue AT ALL — which checkout, which branch, which
# identity and where that identity came from, which BWS project, which mode, and
# what this invocation is about to change. A previous run of this wizard was
# completed from the default branch, where the credential the operator was
# there to store is not declared. The wizard found nothing to do, said nothing
# about it, and the ceremony "succeeded" while changing nothing. Naming the
# branch and the mode up front is what makes that visible.
# Apply the per-repo .bws-secrets-list override BEFORE the header: the header
# has to say which keys are managed deliveries and whether the Actions surface
# (machine account, BWS_ACCESS_TOKEN, loader) applies to this repository at all.
load_keys_override

# Managed deliveries are validated before anything is confirmed or mutated:
#   - the destination must be the repository this wizard is running in. The
#     declaration names it explicitly so that a copy can never land in another
#     repository by accident, and this check is what makes that promise hold;
#   - a deployment profile (--gh-environments) has no delivery semantics.
if $HAS_DELIVERIES; then
  [[ -z "$GH_ENVIRONMENTS" ]] || die "--gh-environments cannot be combined with a declaration that carries deliver: keys"
  for _dk in ${DELIVERED_KEYS[@]+"${DELIVERED_KEYS[@]}"}; do
    _dv="DELIVER_$_dk"
    _dest="${!_dv#*@}"
    if ! $DRY_RUN && [[ "$_dest" != "$REPO" ]]; then
      die "$_dk declares deliver:${!_dv} but this wizard is running in $REPO. A managed copy is only ever delivered to the repository that declares it; fix the declaration or run from $_dest."
    fi
  done
fi
for _rk in $ROTATE_SECRETS; do
  case " ${KEYS[*]} " in
    *" $_rk "*) ;;
    *) die "--rotate-secret $_rk: not a declared key (declared: ${KEYS[*]})" ;;
  esac
  _rsv="SHARED_$_rk"
  [[ "${!_rsv:-false}" != "true" ]] || die "--rotate-secret $_rk: a shared key is rotated in its shared project, not here (docs/shared-secrets.md)"
done

_branch="$(cd "$REPO_ROOT" && git rev-parse --abbrev-ref HEAD 2>/dev/null || echo '(unknown)')"
_secrets_list_path="${SECRETS_LIST_OPT:-${BWS_SECRETS_LIST_FILE:-.bws-secrets-list}}"
case "$_secrets_list_path" in
  /*) ;;
  *) [[ -f "$_secrets_list_path" ]] || _secrets_list_path="$REPO_ROOT/$_secrets_list_path" ;;
esac
if [[ -f "$_secrets_list_path" ]]; then
  SECRETS_LIST_DISPLAY="${_secrets_list_path#"$REPO_ROOT"/}"
else
  SECRETS_LIST_DISPLAY="(none — built-in static-site default key set)"
fi
if $PLAN; then
  _mode="PLAN — read-only inventory"
elif $DRY_RUN; then
  _mode="DRY-RUN (no external calls, no file edits)"
else
  _mode="APPLY — will create and edit"
fi
say ""
say "============================================================"
say "  bws-bootstrap.sh"
say "============================================================"
say "  Mode                $_mode"
say "  Checkout            $REPO_ROOT"
say "  Branch              $_branch"
say "  GitHub repo         $REPO"
say "  Application         $APP_NAME"
say "  Identity source     $APP_NAME_SOURCE"
say "  BWS project name    $PROJECT_NAME"
if $HAS_LOADER_KEYS; then
  say "  BWS machine acct    $CI_NAME"
  say "  GH access-token     GITHUB_ACTIONS"
  say "  Cloudflare token    $CI_NAME"
else
  say "  BWS machine acct    not applicable — no Actions consumer (every key is a managed delivery)"
  say "  GH access-token     not applicable — Actions never reads Bitwarden in this repository"
fi
say "  Declaration         $SECRETS_LIST_DISPLAY"
if $HAS_DELIVERIES; then
  for _dk in ${DELIVERED_KEYS[@]+"${DELIVERED_KEYS[@]}"}; do
    _dv="DELIVER_$_dk"
    say "  Managed delivery    $_dk → ${!_dv#*@} (Dependabot secret ${_dk})"
  done
fi
say "  ------------------------------------------------------------"
if $PLAN; then
  say "  Will change local files?   NO"
  say "  Will change BWS?           NO"
  say "  Will change GitHub?        NO"
  say "  Secret VALUES              \`bws secret list\` returns them — the CLI offers"
  say "                             no values-free listing — and they are projected"
  say "                             away at the bws->jq pipe. None is assigned to a"
  say "                             variable, passed as an argument, printed, or"
  say "                             written to disk by this run."
elif $DRY_RUN; then
  say "  Will change local files?   NO"
  say "  Will change BWS?           NO"
  say "  Will change GitHub?        NO"
else
  if $HAS_LOADER_KEYS; then
    say "  Will change local files?   YES — .env-sample, .env, and the generated loader"
  else
    say "  Will change local files?   .env-sample/.env only if present (no loader is generated)"
  fi
  if [[ -n "$ROTATE_SECRETS" ]]; then
    say "  Will change BWS?           YES — creates the project and any missing secret; REPLACES the value of: $ROTATE_SECRETS"
  else
    say "  Will change BWS?           YES — creates the project and any missing secret"
  fi
  if $HAS_LOADER_KEYS && $HAS_DELIVERIES; then
    say "  Will change GitHub?        YES — sets BWS_ACCESS_TOKEN if absent; synchronises the managed Dependabot secret copies"
  elif $HAS_DELIVERIES; then
    say "  Will change GitHub?        YES — synchronises the managed Dependabot secret copies (nothing else)"
  else
    say "  Will change GitHub?        YES — sets the BWS_ACCESS_TOKEN secret if absent"
  fi
fi
if $RESYNC_DELIVERIES; then
  say "  --resync-deliveries  yes (every managed copy will be rewritten from Bitwarden)"
fi
if $ROTATE_TOKEN; then
  say "  --rotate-token      yes (will re-prompt for BWS_ACCESS_TOKEN)"
fi
if $NO_SECRET_VALUES; then
  say "  --no-secret-values  yes (will not create secret values via bws CLI;"
  say "                       paste values via Bitwarden web UI between runs)"
fi
if $SCAFFOLD; then
  say "  --scaffold          yes (will create missing tracked files from templates)"
fi
say "============================================================"
say ""

# --scaffold-only makes no external change, so there is nothing to confirm — and
# a test must be able to run it non-interactively.
if ! $DRY_RUN && $MUTATE; then
  printf 'Proceed? [y/N] '
  read -r confirm
  case "$confirm" in
    y | Y | yes | YES) ;;
    *) die "Aborted by user." ;;
  esac
fi

# ---------------------------------------------------------------------------
# Status trackers (Bash 3.2 compatible — no associative arrays)
# Pattern: printf -v "VAR_$key" '%s' "$val"; var="VAR_$key"; echo "${!var}"
# ---------------------------------------------------------------------------

# Project: STATUS_PROJECT, ID_PROJECT
# Per-secret: STATUS_<KEY>, ID_<KEY>
# GH repo secret: STATUS_GH
# Files: STATUS_FILE_<short>, NOTE_FILE_<short>
# Per-key file edit: STATUS_EDIT_<KEY>

# Initialize all secret statuses to "skipped" so the summary is well-defined
# even if we abort partway.
for k in "${KEYS[@]}"; do
  printf -v "STATUS_$k" '%s' "skipped"
  printf -v "ID_$k" '%s' ""
  printf -v "STATUS_EDIT_$k" '%s' "skipped"
done
STATUS_PROJECT="skipped"
ID_PROJECT=""
STATUS_GH="skipped"
STATUS_FILE_ENV_SAMPLE="skipped"
NOTE_FILE_ENV_SAMPLE=""
STATUS_FILE_ENV="skipped"
NOTE_FILE_ENV=""
STATUS_FILE_ACTION="skipped"
NOTE_FILE_ACTION=""
# Set true by ensure_secret if a --no-secret-values run skipped any
# create call. Gates rewrite_action_file below — we never want to
# rewrite a subset of action.yml's UUID lines and leave the rest at
# placeholders, because that produces a half-finished tracked diff.
ANY_NO_SECRET_VALUES_SKIP=false

# ---------------------------------------------------------------------------
# Step 2 — BWS project
# ---------------------------------------------------------------------------
info "Checking BWS project: $PROJECT_NAME"

if $DRY_RUN; then
  ID_PROJECT="DRY-RUN-PROJECT-ID"
  STATUS_PROJECT="would-find/create"
  ok "(dry-run) would ensure project exists"
else
  existing_id=$(bws project list -o json |
    jq -r --arg n "$PROJECT_NAME" '.[] | select(.name==$n) | .id' |
    head -n1)
  if [[ -n "$existing_id" ]]; then
    ID_PROJECT="$existing_id"
    STATUS_PROJECT="found"
    ok "found ($existing_id)"
  elif ! $MUTATE; then
    ID_PROJECT=""
    STATUS_PROJECT="MISSING"
    warn "BWS project '$PROJECT_NAME' does not exist (read-only plan — not creating it)"
  else
    info "  creating..."
    ID_PROJECT=$(bws project create "$PROJECT_NAME" -o json | jq -r '.id')
    [[ -n "$ID_PROJECT" && "$ID_PROJECT" != "null" ]] || die "bws project create returned no id"
    STATUS_PROJECT="created"
    ok "created ($ID_PROJECT)"
  fi
fi

# ---------------------------------------------------------------------------
# Step 3 — Six BWS secrets
# ---------------------------------------------------------------------------

# Per-secret guidance printed when a secret is missing. Three layers,
# checked in order:
#
#   1. Type-keyed dispatch (`help_blurb_by_type`) when the consumer's
#      `.bws-secrets-list` declared `type:VALUE` for the key. This is
#      the way consumer repos opt their custom keys into useful
#      helptext without renaming.
#   2. Built-in by-key dispatch, kept for backward compatibility with
#      the default static-site portfolio set (AWS / Cloudflare /
#      BetterUptime / Slack).
#   3. Generic "see consumer docs" pointer.
#
# To add a new type: extend `help_blurb_by_type` below.
# The requirements THIS repository declares for a credential, printed before any
# generic advice and labelled as authoritative.
#
# The type-keyed blurb below can only ever offer suggestions — "pick the consumer
# repo(s)", "1 year is a reasonable default" — because it describes a class of
# credential, not this one. That is fine on the first mint, when whoever is
# reading also made the decision. It is not fine at ROTATION, months later, when
# the only surviving record of the intended scope is whatever prose someone
# wrote at the time. So the scope lives in .bws-secrets-list, next to the key.
#
# Absent fields print nothing: a key that declares no requirements behaves
# exactly as before.
# Set by requirements_blurb to the `;field;field;` set it printed, so
# help_blurb_by_type can drop the generic line for anything the repository has
# already ruled on. Printing "1 year is a reasonable default" two lines under a
# declared `expires: 90d` does not add context — it hands the operator a second,
# contradictory instruction and no way to tell which one is policy.
REQ_PRINTED_FIELDS=""

# True when requirements_blurb already printed an authoritative line for FIELD.
_req_has() {
  case "${REQ_PRINTED_FIELDS:-}" in
    *";$1;"*) return 0 ;;
    *) return 1 ;;
  esac
}

requirements_blurb() {
  local key="$1" req var pair field value printed=false
  var="REQ_${key}"
  req="${!var-}"
  [[ -n "$req" ]] || return 0

  say "    REQUIRED BY THIS REPOSITORY for $key — these are the authoritative"
  say "    values; anything below that disagrees is generic advice, not policy:"
  REQ_PRINTED_FIELDS=""
  REQ_OWNER_VALUE=""
  local IFS=';'
  for pair in $req; do
    field="${pair%%=*}"
    value="${pair#*=}"
    [[ "$field" == "owner" ]] && REQ_OWNER_VALUE="$value"
    REQ_PRINTED_FIELDS="${REQ_PRINTED_FIELDS};${field};"
    case "$field" in
      owner) say "      Resource owner:       $value" ;;
      repos)
        # GitHub's token form has no wildcard: a `*` scope is only mintable as
        # "All repositories". Saying "Only these — JonathanPorta/*" described a
        # selection that does not exist, so an operator either guessed or picked
        # the account-wide option while believing they had picked a narrow one.
        # Print the option they will actually click, and — because the wide one
        # is a deliberate exception — the decision that approved it.
        if [[ "$value" == *'*'* ]]; then
          say "      Repository access:    ALL repositories owned by ${REQ_OWNER_VALUE:-the owner above}"
          say "                            (GitHub option: \"All repositories\"). This is"
          say "                            wider than the default rule in"
          say "                            docs/tokens-and-account-security.md and is"
          say "                            permitted ONLY by the recorded decision below."
        else
          say "      Repository access:    Only select repositories → ${value//,/, }"
          say "                            (and no others)"
        fi
        ;;
      approval) say "      Approved by:          $value" ;;
      perms)
        say "      Permissions:          ${value//,/, } (and nothing else;"
        say "                            Metadata: Read is implicit)"
        ;;
      expires) say "      Expiration:           $value — rotate on this cadence" ;;
      consumers) say "      Consumed by:          ${value//,/, }" ;;
    esac
    printed=true
  done
  $printed && say ""
  return 0
}

help_blurb() {
  REQ_PRINTED_FIELDS=""
  requirements_blurb "$1"
  local key="$1"
  local type_var="TYPE_$key"
  local type="${!type_var:-}"

  # Layer 1 — type-keyed.
  if [[ -n "$type" ]]; then
    if help_blurb_by_type "$type" "$key"; then
      return 0
    fi
    # Unknown type → fall through to by-key (still better than the
    # generic pointer), and surface a warning so the typo is visible.
    warn "Unknown type '$type' declared for $key in .bws-secrets-list; falling back to by-key helptext."
  fi

  # Layer 2 — built-in by-key, for the default static-site set.
  case "$key" in
    AWS_ACCESS_KEY_ID | AWS_SECRET_ACCESS_KEY)
      help_blurb_by_type aws_iam_key "$key"
      ;;
    CLOUDFLARE_ACCOUNT_ID)
      help_blurb_by_type cloudflare_account_id "$key"
      ;;
    CLOUDFLARE_API_TOKEN)
      help_blurb_by_type cloudflare_token_user "$key"
      ;;
    BETTERUPTIME_API_TOKEN)
      help_blurb_by_type betteruptime_token "$key"
      ;;
    SLACK_WEBHOOK_URL)
      help_blurb_by_type slack_webhook "$key"
      ;;
    *)
      # Layer 3 — generic pointer.
      say "    Custom secret introduced via .bws-secrets-list — see the"
      say "    consumer repo's docs for how to mint $key."
      say "    (Tip: add ' type:VALUE' to the .bws-secrets-list entry"
      say "    to get type-specific helptext on the next run.)"
      ;;
  esac
}

# Type-keyed helptext. Each case prints minting instructions for one
# class of credential. Returns 0 if it matched a known type; 1 otherwise
# so the caller can fall through.
#
# Supported types:
#   github_pat               GitHub fine-grained Personal Access Token
#   openai_key               OpenAI API key
#   anthropic_key            Anthropic API key
#   cloudflare_token_user    Cloudflare USER-owned API token
#   cloudflare_api_token     alias of cloudflare_token_user
#   cloudflare_account_id    Cloudflare Account ID (shared across sites)
#   slack_webhook            Slack workflow webhook URL
#   aws_iam_key              AWS IAM access key (from scripts/ruam/ruam.sh)
#   betteruptime_token       BetterUptime API token
#   google_service_account   Google Cloud service-account JSON credentials
#   cloudflare_token_worker  Cloudflare USER-owned token scoped for a Worker deploy
#   github_app_id            GitHub App numeric App ID
#   github_app_private_key   GitHub App private key (base64-encoded single line)
#   hmac_key                 Random HMAC/signing key (e.g. signed sessions)
#   cloudflare_access_aud    Cloudflare Access Application Audience (AUD) tag
#   cloudflare_access_team_domain  Cloudflare Zero Trust team domain
help_blurb_by_type() {
  local type="$1" key="$2"
  case "$type" in
    github_pat)
      say "    Fine-grained GitHub Personal Access Token. Mint at:"
      say "      https://github.com/settings/personal-access-tokens/new"
      say ""
      say "    Suggested mint settings:"
      say "      Token name:           $APP_NAME $key"
      # Everything below is generic advice about a CLASS of credential. Where
      # the repository has declared the answer for THIS credential it was
      # already printed above, as policy — repeating a softer, different version
      # of it here is how an operator ends up choosing between two instructions
      # with no way to tell which one binds.
      _req_has owner ||
        say "      Resource owner:       the account or org that owns the target repo(s)"
      if ! _req_has repos; then
        say "      Repository access:    Prefer \"Only select repositories\" and pick the"
        say "                            consumer repo(s). Use \"All repositories\" ONLY"
        say "                            when the token genuinely spans the portfolio."
      fi
      _req_has expires ||
        say "      Expiration:           1 year is a reasonable default. Calendar a rotation."
      say ""
      if _req_has perms; then
        say "    Repository permissions — grant EXACTLY the permissions listed above"
        say "    and nothing else. Metadata: Read-only is auto-checked by GitHub."
      else
        say "    Repository permissions — grant ONLY what this token will actually use."
        say "    Contents:RW across All repositories is the broadest permission GitHub"
        say "    offers; do not grant it by default. Common patterns:"
        say ""
        say "      Releases / pushing tags:    Contents: Read and write"
        say "      Webhook management:         Webhooks: Read and write (repo OR org scope)"
        say "      PR creation / review:       Pull Requests: Read and write"
        say "                                  + Contents: Read and write (for branches)"
        say "      Issue management:           Issues: Read and write"
        say ""
        say "      Metadata: Read-only is auto-checked by GitHub."
      fi
      say ""
      say "    Copy the token (starts with github_pat_); only shown once."
      return 0
      ;;
    openai_key)
      say "    OpenAI API key. Generate at:"
      say "      https://platform.openai.com/api-keys"
      say ""
      say "    Tips:"
      say "      - Create the key inside a project that has usage caps set"
      say "        so a leak can't drain billing."
      say "      - Save the value (sk-... or sk-proj-...); not shown again."
      return 0
      ;;
    anthropic_key)
      say "    Anthropic API key. Generate at:"
      say "      https://console.anthropic.com/settings/keys"
      say ""
      say "    Tips:"
      say "      - Pick the workspace whose billing pool should pay for these calls."
      say "      - Save the value (sk-ant-...); not shown again."
      return 0
      ;;
    cloudflare_account_id)
      say "    Cloudflare Account ID — stable per account, and the SAME for every"
      say "    site under this account (a shared value; see the shared-secret note)."
      say ""
      say "    Find it at:"
      say "      https://dash.cloudflare.com/  → pick the account; the ID is the hex"
      say "      string in the URL (dash.cloudflare.com/<ACCOUNT_ID>). It's also on"
      say "      any zone's Overview page → right sidebar → 'Account ID' (copy icon)."
      return 0
      ;;
    cloudflare_token_user | cloudflare_api_token)
      say "    USER-owned Cloudflare API token (NOT account-owned)."
      say "    Account-owned tokens fail the legacy Page Rules API with error 1011."
      say ""
      say "    Create at:"
      say "      https://dash.cloudflare.com/profile/api-tokens"
      say ""
      say "    Token settings:"
      say "      Name:        $CI_NAME"
      say "      Permissions: Zone:Zone Settings:Edit, Zone:DNS:Edit, Zone:Page Rules:Edit,"
      say "                   Zone:Transform Rules:Edit"
      say "      (Transform Rules:Edit is required for the dns workspace's security-headers"
      say "       ruleset — without it that apply fails with authentication error 10000.)"
      say "      Resources:   Include → Specific zone → $APP_NAME"
      say "                   (plus any redirect_domains zones if non-empty)"
      return 0
      ;;
    slack_webhook)
      say "    Slack workflow webhook URL."
      say "      Slack → Workflow Builder → New → Webhook trigger →"
      say "      Add steps → Publish → copy the webhook URL."
      return 0
      ;;
    aws_iam_key)
      say "    AWS IAM access key. From scripts/ruam/ruam.sh output — if you"
      say "    haven't run it yet:"
      say "      APP_NAME=$APP_NAME CUSTOMER_NAME=<your-customer> \\"
      say "        BASE_DOMAIN=$APP_NAME scripts/ruam/ruam.sh"
      return 0
      ;;
    betteruptime_token)
      say "    BetterUptime API token."
      say "      BetterUptime → Settings → API Tokens → Generate new."
      return 0
      ;;
    google_service_account)
      say "    Google Cloud service-account JSON credentials."
      say ""
      say "    Console:"
      say "      https://console.cloud.google.com/iam-admin/serviceaccounts"
      say ""
      say "    Steps to mint a fresh credential (≈5 min):"
      say "      1. Pick (or create) a Google Cloud project. The service-account"
      say "         lives in this project; APIs you enable below are per-project."
      say "         https://console.cloud.google.com/projectcreate"
      say ""
      say "      2. Enable the API(s) this credential will call. Most common:"
      say "           Google Sheets API   https://console.cloud.google.com/apis/library/sheets.googleapis.com"
      say "           Google Drive  API   https://console.cloud.google.com/apis/library/drive.googleapis.com"
      say "         (Drive is needed alongside Sheets for any flow that lists"
      say "          or opens Sheets by name vs. by hard-coded sheet ID.)"
      say ""
      say "      3. Create the service account:"
      say "           IAM & Admin → Service Accounts → CREATE SERVICE ACCOUNT"
      say "           Name:        $APP_NAME-ci"
      say "           Description: CI deploy / data-pipeline service account for $APP_NAME"
      say "         Skip the optional 'Grant this service account access to project'"
      say "         and 'Grant users access to this service account' steps — least"
      say "         privilege is to grant project roles only if your code actually"
      say "         uses GCP services beyond the per-resource shares in step 5."
      say ""
      say "      4. Generate a JSON key for the service account:"
      say "           Service account → Keys tab → ADD KEY → Create new key → JSON"
      say "         Downloads <project>-<hash>.json — KEEP THIS FILE OUT OF GIT."
      say "         The file's full contents are the secret value."
      say ""
      say "      5. Share the resource(s) the service account needs to read/write"
      say "         with the SA's email address (shown on the SA detail page,"
      say "         ending in @<project>.iam.gserviceaccount.com):"
      say "           Google Sheet: Share → paste the SA email → Viewer or Editor"
      say "           Drive folder: Share → paste the SA email → Viewer"
      say "         Same model as sharing a Sheet with a human, just the SA's address."
      say ""
      say "      6. The interactive prompt below is SINGLE-LINE (\`read -rs\`)."
      say "         Pretty-printed JSON pasted directly at the prompt captures"
      say "         only the first line — typically just '{' — and bootstrap"
      say "         will report \"created\" against a broken secret value."
      say ""
      say "         Two safe paths to supply the value instead:"
      say ""
      say "         (a) Env-var capture, then re-run. \$$key as an env var"
      say "             preserves the multi-line content; the wizard sees it"
      say "             and skips the prompt entirely:"
      say "               export $key=\"\$(cat ~/Downloads/<project>-<hash>.json)\""
      say "               make bws-bootstrap   # re-run; uses \$$key"
      say ""
      say "         (b) --no-secret-values mode. Pass the flag to skip the"
      say "             prompt; bootstrap prints instructions for adding the"
      say "             secret via the Bitwarden vault web UI (where you can"
      say "             paste pretty-printed JSON directly into the value"
      say "             field), then re-run without the flag to fill in the"
      say "             load-secrets action.yml UUID."
      say ""
      say "    Rotation: in step 4 you can have multiple active JSON keys at once."
      say "    Generate a new one, deploy it, then delete the old one from the"
      say "    Keys tab once the new one is confirmed working. Auto-deletion of"
      say "    leaked keys + rotation reminders live on the Service account page."
      return 0
      ;;
    cloudflare_token_worker)
      say "    USER-owned Cloudflare API token for a WORKER deploy (NOT the"
      say "    static-site zone/DNS token — different scopes). Create at:"
      say "      https://dash.cloudflare.com/profile/api-tokens"
      say ""
      say "    Token settings (least privilege for a Worker + KV + D1):"
      say "      Name:        $CI_NAME"
      say "      Permissions: Account → Workers Scripts:Edit"
      say "                   Account → Workers KV Storage:Edit"
      say "                   Account → D1:Edit"
      say "                   Account → Account Settings:Read"
      say "                   Account → Access: Apps and Policies:Edit"
      say "                   (Access: Apps and Policies:Edit is required when the worker"
      say "                    Terraform-manages a cloudflare_zero_trust_access_application;"
      say "                    without it 'terraform apply' 403s creating the Access app.)"
      say "                   (add Workers R2 Storage:Edit only if the worker uses R2)"
      say "      Resources:   Include → your account"
      say "      (No Zone / DNS / Page-Rules scopes — those are for static sites.)"
      return 0
      ;;
    github_app_id)
      say "    GitHub App ID — the numeric id under App settings → General → 'App ID'."
      say "      Manage Apps: https://github.com/settings/apps"
      say "    Low-sensitivity, but stored in BWSM so CI reads it from one place"
      say "    alongside the private key. Value is the integer shown as 'App ID'."
      return 0
      ;;
    github_app_private_key)
      say "    GitHub App private key. App settings → General → 'Private keys'"
      say "    → Generate a private key (downloads a .pem source file)."
      say "      https://github.com/settings/apps"
      say ""
      say "    Store this secret as a base64-encoded, single-line value. Do NOT store"
      say "    or paste the raw multi-line PEM in BWSM; literal newlines break"
      say "    load.sh's jq merge (issue #69) and can drop ALL loaded secrets."
      say ""
      say "    Convert the downloaded .pem before supplying the value:"
      say "      base64 < ~/Downloads/<app>.private-key.pem | tr -d '\n'"
      say ""
      say "    Supply that single-line base64 blob one of two ways:"
      say "      (a) export $key=\"\$(base64 < ~/Downloads/<app>.private-key.pem | tr -d '\n')\" then re-run"
      say "      (b) --no-secret-values mode, then paste the base64 blob in the Bitwarden web UI"
      say ""
      say "    The consumer's Worker base64-decodes it back to PEM at runtime."
      say "    KEEP THE .pem OUT OF GIT. Rotate by generating a new key + deleting the old."
      return 0
      ;;
    hmac_key)
      say "    Random HMAC / signing key (e.g. signed sessions). Not minted by any"
      say "    provider — generate a fresh high-entropy value locally:"
      say "      openssl rand -base64 48"
      say "    Paste the output as the value. Rotating it invalidates live sessions."
      return 0
      ;;
    cloudflare_access_aud)
      say "    Cloudflare Access Application Audience (AUD) tag — the per-app"
      say "    identifier a Worker checks to validate Access JWTs. It is NOT minted"
      say "    by hand: it is auto-generated when the Access application is created"
      say "    by 'terraform apply'. It is distinct per Access application."
      say ""
      say "    Get it after the application exists:"
      say "      terraform output -raw access_application_aud"
      say "      (prefix TF_WORKSPACE=production if the state is workspaced)"
      say ""
      say "    Two-phase: on the FIRST bootstrap pass the application doesn't exist"
      say "    yet, so leave this empty (the prompt accepts an empty value and skips"
      say "    it). Run 'terraform apply' to create the Access app, then re-run this"
      say "    wizard and paste the AUD it now outputs."
      return 0
      ;;
    cloudflare_access_team_domain)
      say "    Cloudflare Zero Trust team domain — the bare"
      say "    '<team>.cloudflareaccess.com' host (NOT a full URL). It is the SAME"
      say "    for every Access application under this account (a shared value; see"
      say "    the shared-secret note)."
      say ""
      say "    Find it at:"
      say "      https://one.dash.cloudflare.com/  → Settings → Custom Pages /"
      say "      Zero Trust → Settings → the team domain is shown as"
      say "      '<team>.cloudflareaccess.com'. Store just the host, no scheme."
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

# Pre-fetch the existing-secret list once (fewer API calls).
if ! $DRY_RUN; then
  if [[ -n "$ID_PROJECT" ]]; then
    # `bws secret list` returns the VALUE of every secret in the project, and the
    # CLI offers no listing that omits it — every output format carries it. So
    # the value cannot be kept out of the pipe; what CAN be controlled is how far
    # it travels, and this is the last point where that is still true.
    #
    # jq projects it away here, in the same pipeline that produced it. What the
    # wizard retains is the key→id mapping and nothing else: no value is ever
    # assigned to a shell variable, passed as an argument (visible in ps),
    # printed, or written to disk. Holding the raw document instead — which this
    # did before — is how a value reaches a trace, a core dump, or an error
    # message that quotes the variable it failed on.
    #
    # Say this precisely rather than claiming values are never read. An operator
    # deciding whether to run a credential command deserves the real boundary,
    # not a rounder one.
    EXISTING_SECRETS_JSON=$(bws secret list "$ID_PROJECT" -o json | jq '[.[] | {id, key, revisionDate, note}]')
  else
    EXISTING_SECRETS_JSON='[]'
  fi
fi

# Replace the VALUE of an existing secret — the UUID, and therefore every loader
# mapping and delivery that names it, is preserved. That is the whole point of
# rotating in place: CENTRALIZED-SECRETS.md "Rotation" has always said the UUID
# stays and the value changes, and this makes it one command instead of a
# remembered `bws secret edit`. Same argv caveat as `bws secret create` (the CLI
# takes the value positionally); --no-secret-values prints the vault edit
# instructions instead, and the next run re-synchronises any delivery because the
# Bitwarden revision is then newer than the copy.
rotate_secret_value() {
  local key="$1" id="$2" value="" envvar
  say "    --rotate-secret: replacing the VALUE of $key (UUID $id is kept)."
  help_blurb "$key"
  if $NO_SECRET_VALUES; then
    say ""
    say "    --no-secret-values is set. Replace the value in the Bitwarden vault web UI:"
    say "      1. https://vault.bitwarden.com → Secrets Manager → project $PROJECT_NAME"
    say "      2. Open secret $key → Edit → paste the new value → Save"
    say "    Then re-run this wizard: the Bitwarden revision is newer than any"
    say "    delivered copy, so every managed delivery is re-synchronised."
    printf -v "STATUS_$key" '%s' "rotate deferred (vault UI)"
    return 0
  fi
  envvar="${!key:-}"
  if [[ -n "$envvar" ]]; then
    say "    (using new value from \$$key env var)"
    value="$envvar"
  else
    printf '    Enter the NEW value for %s (input hidden): ' "$key"
    read -rs value
    say ""
  fi
  if [[ -z "$value" ]]; then
    warn "empty value entered — $key NOT rotated"
    printf -v "STATUS_$key" '%s' "found (rotate skipped: empty)"
    return 0
  fi
  bws secret edit --value "$value" "$id" -o none >/dev/null || die "bws secret edit failed for $key"
  unset value
  printf -v "STATUS_$key" '%s' "rotated"
  ok "value replaced ($id)"
  EXISTING_SECRETS_JSON=$(bws secret list "$ID_PROJECT" -o json | jq '[.[] | {id, key, revisionDate, note}]')
}

ensure_secret() {
  local key="$1"
  info "Checking BWS secret: $key"

  # Shared keys live in a shared project (default _shared-ci, or a named
  # `shared:PROJECT`), not this one. Don't create (or prompt for) them here, and
  # leave ID_$key empty so the action.yml rewrite leaves the baked shared UUID
  # alone. See docs/shared-secrets.md.
  local shared_var="SHARED_$key" shared_proj_var="SHARED_PROJECT_$key" shared_where
  if [[ "${!shared_var:-false}" == "true" ]]; then
    shared_where="${!shared_proj_var:-}"
    [[ -n "$shared_where" ]] || shared_where="$SHARED_PROJECT_NAME"
    printf -v "STATUS_$key" '%s' "shared ($shared_where)"
    printf -v "ID_$key" '%s' ""
    ok "shared — lives in $shared_where, not created here"
    return 0
  fi

  if $DRY_RUN; then
    printf -v "ID_$key" '%s' "DRY-RUN-$key"
    printf -v "STATUS_$key" '%s' "would-find/create"
    ok "(dry-run) would ensure secret exists"
    return 0
  fi

  local existing_id
  existing_id=$(printf '%s' "$EXISTING_SECRETS_JSON" |
    jq -r --arg k "$key" '.[] | select(.key==$k) | .id' |
    head -n1)
  if [[ -n "$existing_id" && "$existing_id" != "null" ]]; then
    printf -v "ID_$key" '%s' "$existing_id"
    printf -v "STATUS_$key" '%s' "found"
    ok "found ($existing_id)"
    case " $ROTATE_SECRETS " in
      *" $key "*) $MUTATE && rotate_secret_value "$key" "$existing_id" ;;
    esac
    return 0
  fi
  case " $ROTATE_SECRETS " in
    *" $key "*) warn "--rotate-secret $key: the secret does not exist yet — it will be CREATED below, not rotated" ;;
  esac

  # Read-only plan: report the gap and its exact next action, then stop. No
  # prompt, no create, and no request for a value — the point of the mode is
  # that an operator can find out what is missing without being handed a
  # ceremony they may not want to run yet.
  if ! $MUTATE; then
    printf -v "STATUS_$key" '%s' "MISSING"
    printf -v "ID_$key" '%s' ""
    warn "not found in BWS project '$PROJECT_NAME'"
    help_blurb "$key"
    return 0
  fi

  # Missing — fetch value from env var or prompt.
  say "    not found in BWS. Need a value for $key:"
  help_blurb "$key"

  # --no-secret-values mode: skip the create call entirely. Print
  # instructions for adding the value via the Bitwarden vault web UI
  # and leave $key's status "skipped (no-secret-values)". On the next
  # run, the existing-secret check at the top of this function will
  # find the now-created secret and the file-edit step proceeds
  # normally. See script header for the argv-exposure rationale.
  if $NO_SECRET_VALUES; then
    say ""
    say "    --no-secret-values is set. Add this secret manually via the Bitwarden vault web UI:"
    say "      1. https://vault.bitwarden.com → Secrets Manager"
    say "      2. Project: $PROJECT_NAME"
    say "      3. New secret →"
    say "         Key:   $key"
    say "         Value: <paste the value here>"
    say "         Project: $PROJECT_NAME"
    say "    Then re-run this wizard. The next run will detect the secret,"
    say "    skip this prompt, and fill in the matching UUID on disk."
    printf -v "STATUS_$key" '%s' "skipped (no-secret-values)"
    # Signal to Step 5 that at least one per-secret UUID is unknown;
    # rewrite_action_file gets deferred so the run doesn't leave a
    # half-filled action.yml diff (some keys with real UUIDs, some
    # still at the placeholder). See the gate just before
    # rewrite_action_file is called.
    ANY_NO_SECRET_VALUES_SKIP=true
    return 0
  fi

  local value=""
  local envvar="${!key:-}"
  if [[ -n "$envvar" ]]; then
    say "    (using value from \$$key env var)"
    value="$envvar"
  else
    # `read -rs` already disables echo; xtrace is guaranteed off (guarded at startup).
    # Prompt printed separately so this works under both bash and zsh (zsh's `-p`
    # means coprocess, not prompt).
    printf '    Enter %s (input hidden): ' "$key"
    read -rs value
    say ""
  fi

  if [[ -z "$value" ]]; then
    warn "empty value entered, skipping"
    printf -v "STATUS_$key" '%s' "skipped (empty)"
    return 0
  fi

  local new_id
  new_id=$(bws secret create "$key" "$value" "$ID_PROJECT" -o json | jq -r '.id')
  [[ -n "$new_id" && "$new_id" != "null" ]] || die "bws secret create returned no id for $key"
  printf -v "ID_$key" '%s' "$new_id"
  printf -v "STATUS_$key" '%s' "created"
  ok "created ($new_id)"

  # Refresh cache so subsequent loops don't re-create if there's a duplicate name elsewhere.
  EXISTING_SECRETS_JSON=$(bws secret list "$ID_PROJECT" -o json | jq '[.[] | {id, key, revisionDate, note}]')
}

for k in "${KEYS[@]}"; do
  ensure_secret "$k"
done

# ---------------------------------------------------------------------------
# Step 4 — GH BWS_ACCESS_TOKEN (repository scope, or GitHub Environment scope)
# ---------------------------------------------------------------------------
#
# With --gh-environments the token is written to each named GitHub Environment
# instead of the repository. That is what lets one repository hold two
# machine-account tokens under the same approved secret name: a repository-scoped
# token for ordinary pull-request validation, and an environment-scoped token
# that only jobs declaring `environment:` can resolve.
#
# The environment path deliberately NEVER touches the repository-scoped secret —
# a deployment profile must not be able to rotate or overwrite the validation
# token.
if ! $HAS_LOADER_KEYS; then
  info "GitHub repo secret BWS_ACCESS_TOKEN: not applicable"
  ok "no key is consumed through the Actions loader, so Actions never authenticates to Bitwarden here"
  STATUS_GH="not applicable (no Actions consumer)"
elif [[ -n "$GH_ENVIRONMENTS" ]]; then
  info "Checking GitHub Environment secrets: BWS_ACCESS_TOKEN ($REPO → $GH_ENVIRONMENTS)"
else
  info "Checking GitHub repo secret: BWS_ACCESS_TOKEN ($REPO)"
fi

if ! $HAS_LOADER_KEYS; then
  :
elif $DRY_RUN; then
  STATUS_GH="would-find/set"
  if [[ -n "$GH_ENVIRONMENTS" ]]; then
    ok "(dry-run) would ensure GH Environment secret BWS_ACCESS_TOKEN in: $GH_ENVIRONMENTS"
  else
    ok "(dry-run) would ensure GH repo secret BWS_ACCESS_TOKEN is set"
  fi
elif ! $MUTATE; then
  # `gh secret list` returns NAMES only — GitHub never discloses a secret's
  # value through the API — so this is a real presence check with nothing to
  # leak, and it never calls `gh secret set`.
  #
  # THREE outcomes, not two. The query can succeed and find the name, succeed and
  # not find it, or FAIL — an expired token, a revoked scope, a 5xx. Piping
  # straight into `grep -qx` erases that third case: the pipeline's exit status
  # is grep's, so an API failure produced an empty list and was reported as
  # `MISSING`. A read-only mode exists to tell an operator what is true, and
  # "I could not find out" is not the same fact as "it is not there" — one sends
  # them to create a credential that already exists.
  #
  # `local`-free and bash 3.2 safe: capture, then test the status.
  _gh_query() {
    # $1 = optional environment name. Prints names on success; returns the
    # command's own status, unswallowed.
    if [[ -n "${1:-}" ]]; then
      gh secret list --repo "$REPO" --env "$1" --json name --jq '.[].name' 2>/dev/null
    else
      gh secret list --repo "$REPO" --json name --jq '.[].name' 2>/dev/null
    fi
  }
  if [[ -n "$GH_ENVIRONMENTS" ]]; then
    _plan_envs_present=""
    _plan_envs_missing=""
    _plan_envs_unobservable=""
    _saved_ifs="$IFS"
    IFS=','
    # shellcheck disable=SC2086  # deliberate bash 3.2 comma split, as below
    set -- $GH_ENVIRONMENTS
    IFS="$_saved_ifs"
    for _env in "$@"; do
      _env="$(printf '%s' "$_env" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
      [[ -n "$_env" ]] || continue
      if _names="$(_gh_query "$_env")"; then
        if printf '%s\n' "$_names" | grep -qx 'BWS_ACCESS_TOKEN'; then
          _plan_envs_present="${_plan_envs_present:+$_plan_envs_present,}$_env"
        else
          _plan_envs_missing="${_plan_envs_missing:+$_plan_envs_missing,}$_env"
        fi
      else
        _plan_envs_unobservable="${_plan_envs_unobservable:+$_plan_envs_unobservable,}$_env"
      fi
    done
    if [[ -n "$_plan_envs_unobservable" ]]; then
      STATUS_GH="UNOBSERVABLE in: $_plan_envs_unobservable"
      warn "could not read the secret list for environment(s): $_plan_envs_unobservable"
    elif [[ -n "$_plan_envs_missing" ]]; then
      STATUS_GH="MISSING in: $_plan_envs_missing"
      warn "BWS_ACCESS_TOKEN absent in environment(s): $_plan_envs_missing"
    else
      STATUS_GH="present"
      ok "BWS_ACCESS_TOKEN present in: $_plan_envs_present"
    fi
  elif _names="$(_gh_query)"; then
    if printf '%s\n' "$_names" | grep -qx 'BWS_ACCESS_TOKEN'; then
      STATUS_GH="present"
      ok "BWS_ACCESS_TOKEN already set on $REPO"
    else
      STATUS_GH="MISSING"
      warn "BWS_ACCESS_TOKEN is not set on $REPO"
    fi
  else
    STATUS_GH="UNOBSERVABLE"
    warn "could not read the GitHub secret list for $REPO — this is NOT the same as the secret being absent"
    say "    The query itself failed (expired credential, missing scope, or API error)."
    say "    Re-run once 'gh auth status' is healthy; do not create a replacement"
    say "    credential on the strength of this run."
  fi
elif [[ -n "$GH_ENVIRONMENTS" ]]; then
  # A machine-account access token is REVEAL-ONCE: Bitwarden shows it at
  # creation and can never show it again. So an unconditional prompt-and-set
  # here is not "idempotent with an extra keystroke" — on the second run of a
  # deliberately two-run ceremony the operator no longer HAS the value, and the
  # only way past the prompt was to mint a replacement token or paste something
  # wrong. The repository-scoped path below has skipped an already-set secret
  # since it was written; the environment path simply never learned to.
  #
  # Presence is therefore established for EVERY environment BEFORE anything is
  # prompted for or written. A query that fails is a third outcome: `gh secret
  # list` returning nothing because the credential expired looks exactly like an
  # empty environment, and acting on that reading would overwrite a working
  # token with a newly minted one — or refuse to set one that is genuinely
  # absent. Unobservable state aborts the run before the first prompt.
  #
  # Bash 3.2: no `readarray`. Split the comma list with the field separator.
  _saved_ifs="$IFS"
  IFS=','
  # shellcheck disable=SC2086  # deliberate: IFS=',' splitting is how bash 3.2
  # turns the comma list into positional parameters without mapfile/readarray.
  set -- $GH_ENVIRONMENTS
  IFS="$_saved_ifs"
  _envs_set=0
  _envs_kept=0
  _envs_skipped=0
  # Newline-delimited classifications: an environment name may contain spaces.
  _envs_todo=""
  _envs_absent_count=0
  _envs_unobservable=""

  # ── pass 1: classify, mutate nothing ────────────────────────────────────────
  for _env in "$@"; do
    # Trim surrounding whitespace so "a, b" works.
    _env="$(printf '%s' "$_env" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    [[ -n "$_env" ]] || continue
    # An authoritative 404 means the environment is absent, which is a skip. Any
    # OTHER failure — authorization, transport, a 5xx — means we could not find
    # out, and "could not find out" must not be rendered as "does not exist":
    # that diagnostic is wrong, and carrying on would let the rest of the batch
    # be mutated on partial evidence.
    # `|| rc=$?`, not a bare assignment: under errexit a failing command
    # substitution takes the whole script down, which is how a deliberately
    # three-way probe became an abort with no classification at all.
    _env_probe_rc=0
    _env_probe="$(gh api "repos/$REPO/environments/$_env" 2>&1)" || _env_probe_rc=$?
    if [ "$_env_probe_rc" -ne 0 ]; then
      case "$_env_probe" in
        *"HTTP 404"* | *'"status":"404"'* | *'"status": "404"'*)
          warn "GitHub Environment '$_env' does not exist on $REPO — skipping."
          say "    Create it first (Settings → Environments), then re-run."
          _envs_skipped=$((_envs_skipped + 1))
          unset _env_probe
          continue
          ;;
        *)
          _envs_unobservable="${_envs_unobservable:+$_envs_unobservable, }$_env"
          unset _env_probe
          continue
          ;;
      esac
    fi
    unset _env_probe
    # NAMES only — GitHub never discloses a secret's value — so this is a real
    # presence check with nothing to leak.
    if _env_names="$(gh secret list --repo "$REPO" --env "$_env" --json name --jq '.[].name' 2>/dev/null)"; then
      if printf '%s\n' "$_env_names" | grep -qx 'BWS_ACCESS_TOKEN'; then
        if $ROTATE_TOKEN; then
          say "    Environment '$_env': BWS_ACCESS_TOKEN present — --rotate-token will REPLACE it."
          _envs_todo="${_envs_todo}${_env}"$'\n'
        else
          ok "BWS_ACCESS_TOKEN already set on $REPO environment '$_env' — keeping it (--rotate-token to replace)"
          _envs_kept=$((_envs_kept + 1))
        fi
      else
        _envs_todo="${_envs_todo}${_env}"$'\n'
        _envs_absent_count=$((_envs_absent_count + 1))
      fi
    else
      _envs_unobservable="${_envs_unobservable:+$_envs_unobservable, }$_env"
    fi
    unset _env_names
  done

  if [[ -n "$_envs_unobservable" ]]; then
    warn "could not observe the state of environment(s): $_envs_unobservable"
    say "    The query itself failed (expired credential, missing scope, or API"
    say "    error). That is NOT the same fact as the secret being absent, and a"
    say "    machine-account token cannot be read back once minted — so nothing"
    say "    was prompted for and nothing was written."
    say "    Re-run once 'gh auth status' is healthy."
    die "GitHub Environment secret state is UNOBSERVABLE for: $_envs_unobservable"
  fi

  # ── pass 2: prompt once per environment that actually needs a value ─────────
  # The list is fed on fd 3, NOT stdin: the token prompt below reads from stdin,
  # and a heredoc on stdin would silently answer it with the next environment
  # name instead of the operator's paste.
  while IFS= read -r _env <&3; do
    [[ -n "$_env" ]] || continue
    say ""
    say "    Environment '$_env' — paste the DEPLOY machine-account token."
    say "    This is NOT the admin/org token you are running bootstrap with, and"
    say "    NOT the repository-scoped validation token."
    printf '    Paste the deploy machine-account token (input hidden): '
    read -rs _env_token
    say ""
    if [[ -z "$_env_token" ]]; then
      warn "empty token, skipping environment '$_env'"
      _envs_skipped=$((_envs_skipped + 1))
      continue
    fi
    # stdin, never argv.
    printf '%s' "$_env_token" | gh secret set BWS_ACCESS_TOKEN --repo "$REPO" --env "$_env"
    unset _env_token
    ok "BWS_ACCESS_TOKEN set on $REPO environment '$_env'"
    _envs_set=$((_envs_set + 1))
  done 3<<EOF_ENVS_TODO
$_envs_todo
EOF_ENVS_TODO

  STATUS_GH="env: ${_envs_set} set, ${_envs_kept} kept, ${_envs_skipped} skipped"
else
  bws_already_set=false
  legacy_bw_set=false
  existing_secrets=$(gh secret list --repo "$REPO" --json name --jq '.[].name' 2>/dev/null)
  if printf '%s\n' "$existing_secrets" | grep -qx 'BWS_ACCESS_TOKEN'; then
    bws_already_set=true
  fi
  # Migration helper: detect the pre-rename `BW_ACCESS_TOKEN` (no S) and
  # tell the user how to migrate. Earlier versions of this script set
  # the secret under the BW_ name; the BWS_ name is the canonical
  # Bitwarden convention.
  if printf '%s\n' "$existing_secrets" | grep -qx 'BW_ACCESS_TOKEN'; then
    legacy_bw_set=true
  fi
  if $legacy_bw_set && ! $bws_already_set; then
    warn "Detected legacy 'BW_ACCESS_TOKEN' secret on $REPO."
    say "    This script now standardizes on 'BWS_ACCESS_TOKEN' (Bitwarden's"
    say "    official prefix). To migrate without re-minting the machine-"
    say "    account token, pipe the value via stdin so it never appears in"
    say "    process args / shell history:"
    say "      gh secret set BWS_ACCESS_TOKEN --repo \"$REPO\""
    say "        # (paste the token at the prompt, then press Enter + Ctrl-D)"
    say "      gh secret delete BW_ACCESS_TOKEN --repo \"$REPO\""
    say "    Or proceed below and the wizard will prompt for a fresh token."
    say ""
  fi

  if $bws_already_set && ! $ROTATE_TOKEN; then
    STATUS_GH="skipped (already set)"
    ok "BWS_ACCESS_TOKEN already set on $REPO (use --rotate-token to overwrite)"
  else
    say ""
    say "    bws CLI v2 doesn't manage machine accounts. Complete in the web UI:"
    say "      1. https://vault.bitwarden.com → Secrets Manager → Machine Accounts → New"
    say "         Name: $CI_NAME"
    say "      2. Grant the machine account read access to project: $PROJECT_NAME"
    if $HAS_SHARED; then
      if [[ -n "$NAMED_SHARED_PROJECTS" ]]; then
        _grant=""
        $HAS_BARE_SHARED && _grant="$SHARED_PROJECT_NAME"
        _grant="${_grant:+$_grant, }$NAMED_SHARED_PROJECTS"
        say "         ALSO grant it 'Can read' on each shared project: $_grant"
        say "         — this repo uses shared secrets. Without these grants, CI +"
        say "         local loads can't resolve them. See docs/shared-secrets.md."
      else
        say "         ALSO grant it 'Can read' on the shared project: $SHARED_PROJECT_NAME"
        say "         ($SHARED_PROJECT_ID) — this repo uses shared secrets. Without"
        say "         this grant, CI + local loads can't resolve them. See docs/shared-secrets.md."
      fi
    fi
    say "      3. Inside the machine account → Access Tokens → New"
    say "         Name: GITHUB_ACTIONS"
    say "      4. Copy the token (only shown once)."
    say ""

    bws_token=""
    printf '    Paste the GITHUB_ACTIONS token (input hidden): '
    read -rs bws_token
    say ""

    if [[ -z "$bws_token" ]]; then
      warn "empty token, skipping GH secret set"
      STATUS_GH="skipped (empty token)"
    else
      # Pipe via stdin so the token never appears in argv (visible to ps).
      printf '%s' "$bws_token" | gh secret set BWS_ACCESS_TOKEN --repo "$REPO"
      unset bws_token
      if $bws_already_set; then
        STATUS_GH="rotated"
      else
        STATUS_GH="created"
      fi
      ok "BWS_ACCESS_TOKEN set on $REPO"
    fi
  fi
fi

# ---------------------------------------------------------------------------
# Step 4b — Managed deliveries (deliver:dependabot@OWNER/REPO)
# ---------------------------------------------------------------------------
#
# Dependabot cannot read Bitwarden: its private-registry credentials are GitHub
# *Dependabot secrets*, a namespace separate from Actions secrets that no
# workflow job can see. So for a key declared `deliver:dependabot@OWNER/REPO`
# Bitwarden stays the authoritative store and this step keeps a COPY in that
# namespace, under the same name:
#
#   - the destination was validated against $REPO before anything ran;
#   - a github_pat is proved able to read every repository it declares, as the
#     declared owner, before it is ever delivered — a token that cannot do its
#     job is not copied anywhere, and the GitHub-reported expiry observed in that
#     same request is recorded in the secret's note (metadata, not the value);
#   - the copy is written when it is absent, when the Bitwarden revision is newer
#     than the copy (a rotation), or on --resync-deliveries; otherwise it is left
#     alone. Normal re-runs therefore write nothing;
#   - every write is verified by re-reading the destination's updated_at;
#   - an unreadable destination is UNOBSERVABLE and aborts BEFORE any write —
#     "could not find out" is not "absent", and the response to absent is a write.
#
# The value flows `bws secret get | jq -r .value | gh secret set` (stdin), and
# through `curl --config -` (stdin) for the probe. It is never an argument, is
# never printed, and is never written to disk. xtrace was refused at startup.

# Lexically comparable timestamp: Bitwarden emits fractional seconds and GitHub
# emits `Z`; neither BSD nor GNU `date` parses both portably, so normalise to
# YYYY-MM-DDTHH:MM:SS and compare as strings.
_ts_norm() {
  printf '%s' "${1:-}" | sed -E 's/\.[0-9]+//; s/Z$//; s/\+00:00$//' | cut -c1-19
}

# Days from today to a YYYY-MM-DD date, via Julian day numbers (no `date`
# arithmetic; identical on BSD and GNU).
_days_until() {
  awk -v d="${1:-}" -v today="$(date -u +%Y-%m-%d)" '
    function jdn(s,  y, m, dd, a, yy, mm) {
      split(s, p, "-"); y = p[1] + 0; m = p[2] + 0; dd = p[3] + 0
      a = int((14 - m) / 12); yy = y + 4800 - a; mm = m + 12 * a - 3
      return dd + int((153 * mm + 2) / 5) + 365 * yy + int(yy / 4) - int(yy / 100) + int(yy / 400) - 32045
    }
    BEGIN { if (d !~ /^[0-9]{4}-[0-9]{2}-[0-9]{2}/) { print ""; exit } print jdn(substr(d, 1, 10)) - jdn(today) }'
}

# Expiry classification with the fleet thresholds (scripts/fleet-credential-expiry.sh).
_expiry_state() {
  local days="$1"
  [[ -n "$days" ]] || {
    printf 'UNOBSERVABLE'
    return
  }
  if [[ "$days" -lt 0 ]]; then
    printf 'EXPIRED'
  elif [[ "$days" -le 7 ]]; then
    printf 'FAIL'
  elif [[ "$days" -le 14 ]]; then
    printf 'URGENT'
  elif [[ "$days" -le 30 ]]; then
    printf 'WARNING'
  else printf 'OK'; fi
}

# Destination state, printed as one word plus an optional timestamp:
#   "present <updated_at>" · "absent" (authoritative 404) · "unobservable"
# Printed rather than returned as an exit status because a non-zero return
# inside a command substitution trips the diagnostic ERR trap.
_dependabot_secret_state() {
  local repo="$1" key="$2" out
  # An absent secret is an HTTP 404, i.e. a non-zero gh exit that is an ANSWER,
  # not an error: drop the diagnostic trap inside the substitution so it does
  # not report a failure that the case below classifies.
  if out="$(
    trap - ERR
    gh api "repos/$repo/dependabot/secrets/$key" 2>&1
  )"; then
    printf 'present %s' "$(printf '%s' "$out" | jq -r '.updated_at // empty')"
    return 0
  fi
  case "$out" in
    *"HTTP 404"* | *'"status":"404"'* | *'"status": "404"'*) printf 'absent' ;;
    *) printf 'unobservable' ;;
  esac
  return 0
}

# Value-blind proof that a github_pat can do its declared job, plus the expiry
# GitHub reports for it. Sets PROBE_STATE (OK | UNUSABLE | MISMATCHED |
# UNREADABLE:<repo> | ERROR) and PROBE_EXPIRES (ISO instant or empty).
#
# The token travels bws -> jq -> a curl config document on stdin. printf is a
# builtin, so it never appears in a process argument list; `set +x` is forced
# although xtrace was already refused at startup.
_probe_github_pat() {
  local key="$1" id="$2" req var owner repos r resp status login
  PROBE_STATE="ERROR"
  PROBE_EXPIRES=""
  var="REQ_$key"
  req="${!var-}"
  owner="${req#*owner=}"
  [[ "$req" == *owner=* ]] && owner="${owner%%;*}" || owner=""
  repos="${req#*repos=}"
  [[ "$req" == *repos=* ]] && repos="${repos%%;*}" || repos=""
  set +x
  resp="$(bws secret get "$id" -o json | jq -r '.value' |
    {
      IFS= read -r _tok
      printf 'silent\nshow-error\ninclude\nurl = "https://api.github.com/user"\nheader = "Accept: application/vnd.github+json"\nheader = "Authorization: Bearer %s"\n' "$_tok"
    } |
    curl --config - 2>/dev/null)" || {
    PROBE_STATE="ERROR"
    return 0
  }
  # HTTP header lines end in CRLF; strip the CR before comparing anything.
  resp="$(printf '%s' "$resp" | tr -d '\r')"
  status="$(printf '%s' "$resp" | awk 'toupper($1) ~ /^HTTP\// {code=$2} END {print code}')"
  case "$status" in
    200) ;;
    401 | 403)
      PROBE_STATE="UNUSABLE"
      return 0
      ;;
    *)
      PROBE_STATE="ERROR"
      return 0
      ;;
  esac
  PROBE_EXPIRES="$(printf '%s' "$resp" | awk 'tolower($1) == "github-authentication-token-expiration:" {sub(/^[^:]*:[[:space:]]*/, ""); print; exit}')"
  login="$(printf '%s' "$resp" | sed -n '/^$/,$p' | jq -r '.login // empty' 2>/dev/null || true)"
  # `owner:` is the token's RESOURCE OWNER. For a personal owner that is the
  # account /user reports. For an organization it is not — the token still
  # authenticates as the minting user — so an org owner is accepted when the
  # declared repositories prove readable below (fleet-credential-expiry.sh
  # draws the same distinction).
  if [[ -n "$owner" && "$login" != "$owner" ]]; then
    local owner_type
    owner_type="$(bws secret get "$id" -o json | jq -r '.value' |
      {
        IFS= read -r _tok
        printf 'silent\nshow-error\nurl = "https://api.github.com/users/%s"\nheader = "Accept: application/vnd.github+json"\nheader = "Authorization: Bearer %s"\n' "$owner" "$_tok"
      } |
      curl --config - 2>/dev/null | tr -d '\r' | jq -r '.type // empty' 2>/dev/null || true)"
    if [[ "$owner_type" != "Organization" ]]; then
      PROBE_STATE="MISMATCHED"
      return 0
    fi
  fi
  # Every explicitly declared repository must be readable. A wildcard scope is
  # not enumerable here and is covered by the fleet expiry sweep instead.
  if [[ -n "$repos" && "$repos" != *'*'* ]]; then
    local IFS=','
    for r in $repos; do
      unset IFS
      status="$(bws secret get "$id" -o json | jq -r '.value' |
        {
          IFS= read -r _tok
          printf 'silent\nshow-error\noutput = /dev/null\nwrite-out = "%%{http_code}"\nurl = "https://api.github.com/repos/%s"\nheader = "Accept: application/vnd.github+json"\nheader = "Authorization: Bearer %s"\n' "$r" "$_tok"
        } |
        curl --config - 2>/dev/null | tr -d '\r')" || status="000"
      if [[ "$status" != "200" ]]; then
        PROBE_STATE="UNREADABLE:$r"
        return 0
      fi
    done
  fi
  PROBE_STATE="OK"
  return 0
}

# Record the observed expiry in the secret's NOTE (metadata, never the value),
# replacing only our own `expires_at=` line and keeping any operator text.
#
# Edited ONLY when the recorded value changes: `bws secret edit` advances the
# secret's revisionDate, and the delivery decision compares that revision with
# the copy's updated_at. An unconditional edit on every run would make each
# up-to-date run look like a rotation on the next, and the wizard would
# re-deliver every other run.
_record_expiry_note() {
  local id="$1" expires="$2" existing current new
  existing="$(printf '%s' "$EXISTING_SECRETS_JSON" | jq -r --arg i "$id" '.[] | select(.id==$i) | .note // ""')"
  current="$(printf '%s\n' "$existing" | sed -n 's/^expires_at=//p' | head -n1)"
  [[ "$current" != "${expires:-unobservable}" ]] || return 0
  new="$(printf '%s\n' "$existing" | grep -v '^expires_at=' | grep -v '^expiry_observed=' | grep -v '^$' || true)"
  new="${new:+$new
}expires_at=${expires:-unobservable}"
  if bws secret edit --note "$new" "$id" -o none >/dev/null 2>&1; then
    ok "recorded expires_at=${expires:-unobservable} in the secret note"
    EXISTING_SECRETS_JSON=$(bws secret list "$ID_PROJECT" -o json | jq '[.[] | {id, key, revisionDate, note}]')
  else
    warn "could not record the expiry note on $id (delivery unaffected)"
  fi
}

DELIVERY_FAILED=false
deliver_key() {
  local key="$1" dv dest id_var id type_var type bws_rev gh_updated rc=0 reason note days state expires
  dv="DELIVER_$key"
  dest="${!dv#*@}"
  id_var="ID_$key"
  id="${!id_var:-}"
  type_var="TYPE_$key"
  type="${!type_var:-}"
  info "Managed delivery: $key → $dest (Dependabot secret $key)"

  if $DRY_RUN; then
    printf -v "STATUS_DELIVER_$key" '%s' "would deliver/verify"
    ok "(dry-run) would ensure the Dependabot secret $key on $dest matches the Bitwarden value"
    return 0
  fi
  if [[ -z "$id" ]]; then
    printf -v "STATUS_DELIVER_$key" '%s' "blocked (secret missing in BWS)"
    warn "nothing to deliver: $key is not in BWS project '$PROJECT_NAME' yet"
    return 0
  fi

  bws_rev="$(printf '%s' "$EXISTING_SECRETS_JSON" | jq -r --arg i "$id" '.[] | select(.id==$i) | .revisionDate // empty')"
  note="$(printf '%s' "$EXISTING_SECRETS_JSON" | jq -r --arg i "$id" '.[] | select(.id==$i) | .note // ""')"
  expires="$(printf '%s\n' "$note" | sed -n 's/^expires_at=//p' | head -n1)"

  local dstate
  dstate="$(_dependabot_secret_state "$dest" "$key")"
  gh_updated="${dstate#present }"
  case "$dstate" in
    present*)
      rc=0
      ok "destination copy present (updated $gh_updated; Bitwarden revision ${bws_rev:-unknown})"
      ;;
    absent)
      rc=4
      gh_updated=""
      ok "destination copy absent"
      ;;
    *)
      printf -v "STATUS_DELIVER_$key" '%s' "UNOBSERVABLE"
      DELIVERY_FAILED=true
      warn "could not read repos/$dest/dependabot/secrets/$key — this is NOT the same as the copy being absent"
      say "    The query itself failed (expired gh credential, missing scope, or API"
      say "    error). Nothing was written for $key. Re-run once 'gh auth status'"
      say "    is healthy."
      return 0
      ;;
  esac

  reason=""
  if [[ $rc -eq 4 ]]; then
    reason="absent at destination"
  elif $RESYNC_DELIVERIES; then
    reason="--resync-deliveries"
  elif [[ -n "$bws_rev" && "$(_ts_norm "$bws_rev")" > "$(_ts_norm "$gh_updated")" ]]; then
    reason="Bitwarden revision is newer than the copy"
  fi

  # Expiry report from the recorded note (value-blind; available to --plan).
  if [[ "$type" == "github_pat" ]]; then
    if [[ -n "$expires" && "$expires" != "unobservable" ]]; then
      days="$(_days_until "$expires")"
      state="$(_expiry_state "$days")"
      say "    Expiry (recorded):  $expires — $state${days:+ ($days days)}"
      case "$state" in
        EXPIRED | FAIL | URGENT | WARNING)
          say "    Rotate on the declared cadence: make bws-bootstrap ARGS=\"--rotate-secret $key\""
          ;;
      esac
    else
      say "    Expiry (recorded):  none yet — observed and recorded on the next apply run"
    fi
  fi

  if ! $MUTATE; then
    if [[ -n "$reason" ]]; then
      printf -v "STATUS_DELIVER_$key" '%s' "would deliver ($reason)"
      say "    Next action: run  make bws-bootstrap  to deliver ($reason)."
    else
      printf -v "STATUS_DELIVER_$key" '%s' "up-to-date"
      ok "copy is at least as new as the Bitwarden revision — nothing to do"
    fi
    return 0
  fi

  # Apply mode: prove the credential works before copying it anywhere.
  if [[ "$type" == "github_pat" ]]; then
    _probe_github_pat "$key" "$id"
    case "$PROBE_STATE" in
      OK)
        ok "token authenticates as the declared owner and reads every declared repository"
        if [[ -n "$PROBE_EXPIRES" ]]; then
          days="$(_days_until "$PROBE_EXPIRES")"
          ok "GitHub reports expiry $PROBE_EXPIRES — $(_expiry_state "$days")${days:+ ($days days)}"
        else
          warn "GitHub reported no expiration header (not a fine-grained PAT with an expiry?)"
        fi
        _record_expiry_note "$id" "$PROBE_EXPIRES"
        ;;
      *)
        printf -v "STATUS_DELIVER_$key" '%s' "BLOCKED ($PROBE_STATE)"
        DELIVERY_FAILED=true
        case "$PROBE_STATE" in
          UNUSABLE) warn "GitHub rejected the stored token (401/403). Rotate it: make bws-bootstrap ARGS=\"--rotate-secret $key\"" ;;
          MISMATCHED) warn "the stored token belongs to a different account than the declared owner: — it will not be delivered" ;;
          UNREADABLE:*) warn "the stored token cannot read ${PROBE_STATE#UNREADABLE:} — check its repository selection and permissions; not delivered" ;;
          *) warn "could not probe GitHub with the stored token (network or API error); not delivered" ;;
        esac
        return 0
        ;;
    esac
  fi

  if [[ -z "$reason" ]]; then
    printf -v "STATUS_DELIVER_$key" '%s' "up-to-date"
    ok "copy is at least as new as the Bitwarden revision — nothing written"
    return 0
  fi

  info "  delivering ($reason)..."
  if ! bws secret get "$id" -o json | jq -r '.value' | gh secret set "$key" --app dependabot --repo "$dest" >/dev/null; then
    printf -v "STATUS_DELIVER_$key" '%s' "error (gh secret set failed)"
    DELIVERY_FAILED=true
    warn "gh secret set failed for $key on $dest — re-run to retry; nothing else depends on this write"
    return 0
  fi
  local verify vstate
  vstate="$(_dependabot_secret_state "$dest" "$key")"
  verify="${vstate#present }"
  if [[ "$vstate" == present* && ($rc -eq 4 || "$(_ts_norm "$verify")" > "$(_ts_norm "$gh_updated")") ]]; then
    if [[ $rc -eq 4 ]]; then
      printf -v "STATUS_DELIVER_$key" '%s' "delivered"
    else
      printf -v "STATUS_DELIVER_$key" '%s' "resynced"
    fi
    ok "verified: Dependabot secret $key on $dest updated $verify"
  else
    printf -v "STATUS_DELIVER_$key" '%s' "error (verify failed)"
    DELIVERY_FAILED=true
    warn "wrote $key but could not verify the destination advanced (state=$vstate) — re-run with --resync-deliveries"
  fi
}

for k in "${KEYS[@]}"; do
  printf -v "STATUS_DELIVER_$k" '%s' ""
done
if $HAS_DELIVERIES; then
  for k in ${DELIVERED_KEYS[@]+"${DELIVERED_KEYS[@]}"}; do
    deliver_key "$k"
  done
fi

# ---------------------------------------------------------------------------
# Step 5 — Auto-update local config files
# ---------------------------------------------------------------------------

# Returns the UUID currently on the BWS_PROJECT_ID line of "$1", or
# empty string if there is no such line. The grep + head pipeline can
# legitimately produce no output (when no match exists) — that is the
# documented "miss → not-found" contract on which callers rely. Under
# `set -euo pipefail` a grep miss propagates exit 1 through pipefail
# and aborts the whole script before the caller can act on the empty
# string; the `{ … } || true` wrapper restores the contract.
extract_env_project_id() {
  local file="$1"
  [[ -f "$file" ]] || {
    printf '%s' ""
    return
  }
  # Accept either `BWS_PROJECT_ID="…"` or `export BWS_PROJECT_ID="…"`,
  # with any value in EXTRACTABLE_PATTERNS (real hex UUID OR a
  # documented placeholder form). The downstream rewriter and
  # is_placeholder_uuid agree on the same family — if these regexes
  # ever disagree, extract reports a value the rewrite refuses (or
  # vice versa) and the script reports a confusing
  # "error (replacement-failed)" instead of a real edit.
  { grep -oE "^[[:space:]]*(export[[:space:]]+)?BWS_PROJECT_ID=\"${EXTRACTABLE_PATTERNS}\"" "$file" |
    head -n1 |
    sed -E 's/^.*BWS_PROJECT_ID="(.+)"$/\1/'; } || true
}

# Returns the UUID currently on the line ending in "> KEY" of "$1", or
# empty if no match. Same pipefail-tolerance and family pattern as
# extract_env_project_id.
extract_action_key_id() {
  local file="$1" key="$2"
  [[ -f "$file" ]] || {
    printf '%s' ""
    return
  }
  { grep -E "^[[:space:]]*${EXTRACTABLE_PATTERNS}[[:space:]]+>[[:space:]]+${key}[[:space:]]*\$" "$file" |
    head -n1 |
    sed -E "s/^[[:space:]]*${EXTRACTABLE_PATTERNS}.*/\1/"; } || true
}

# Atomic file rewrite: replace any placeholder-family UUID on the
# BWS_PROJECT_ID line with the real uuid.
# Echoes status: replaced | already-set | not-found
rewrite_env_file() {
  local file="$1" new_id="$2"
  if [[ ! -f "$file" ]]; then
    printf '%s' "not-found"
    return
  fi
  local cur
  cur=$(extract_env_project_id "$file")
  if [[ -z "$cur" ]]; then
    printf '%s' "not-found"
    return
  fi
  if ! is_placeholder_uuid "$cur"; then
    printf '%s' "already-set"
    return
  fi
  local tmp="${file}.tmp.$$"
  # The sed accepts the same line shapes the extract recognizes:
  #   BWS_PROJECT_ID="…"
  #   export BWS_PROJECT_ID="…"
  # and matches any UUID in the PLACEHOLDER_PATTERNS family on the
  # right-hand side. Anything outside the family won't be matched and
  # so will be left intact.
  # Group numbering (ERE; PLACEHOLDER_PATTERNS contributes one group):
  #   \1 = leading whitespace + optional `export `
  #   \2 = inner `export[[:space:]]+` (or empty)
  #   \3 = matched placeholder UUID (discarded)
  #   \4 = closing `"`
  # Use `#` as the sed delimiter. PLACEHOLDER_PATTERNS contains literal
  # `|` (alternation) — using `|` as the delimiter here would make BSD
  # sed see the first inner alternation `|` as the end of the regex and
  # raise "parentheses not balanced".
  sed -E "s#^([[:space:]]*(export[[:space:]]+)?BWS_PROJECT_ID=\")${PLACEHOLDER_PATTERNS}(\")#\1${new_id}\4#" "$file" >"$tmp"
  # Verify exactly one substitution happened (sanity).
  if ! grep -qE "BWS_PROJECT_ID=\"$new_id\"" "$tmp"; then
    rm -f "$tmp"
    printf '%s' "error (replacement-failed)"
    return
  fi
  mv "$tmp" "$file"
  printf '%s' "replaced"
}

# Atomic per-key rewrite of load-secrets/action.yml. Returns one status per key via printf -v STATUS_EDIT_<key>.
# Append a `<uuid> > KEY` mapping for every declared, non-shared key that has a
# resolved BWS id and no line in the loader yet. Never rewrites or reorders an
# existing line: a key already mapped is left exactly as it is, so this is safe
# to run on every reconcile.
append_missing_action_keys() {
  local file="$1"
  local k var new_id indent last_line to_add=""

  for k in ${LOADER_KEYS[@]+"${LOADER_KEYS[@]}"}; do
    var="SHARED_$k"
    [[ "${!var:-false}" == "true" ]] && continue
    [[ -n "$(extract_action_key_id "$file" "$k")" ]] && continue
    var="ID_$k"
    new_id="${!var:-}"
    # No id means the secret is not in BWS yet. Writing a placeholder here would
    # produce a tracked diff that looks wired and loads nothing.
    [[ -n "$new_id" ]] || continue
    to_add="${to_add}${k}
"
  done
  [[ -n "$to_add" ]] || return 0

  # Anchor on the last existing mapping line and copy its indentation. If there
  # is none, there is nothing to anchor to and no safe place to guess — leave
  # the file alone and let the per-key status report "not-found".
  last_line=$(grep -nE "^[[:space:]]*[0-9a-fA-F<x-]+[[:space:]]+>[[:space:]]+[A-Z][A-Z0-9_]*[[:space:]]*$" "$file" | tail -n1 | cut -d: -f1)
  [[ -n "$last_line" ]] || return 0
  indent=$(sed -n "${last_line}p" "$file" | sed -E 's/^([[:space:]]*).*/\1/')

  local tmp
  tmp="$(mktemp)"
  {
    sed -n "1,${last_line}p" "$file"
    while IFS= read -r k; do
      [[ -n "$k" ]] || continue
      var="ID_$k"
      printf '%s%s > %s\n' "$indent" "${!var}" "$k"
      printf -v "STATUS_EDIT_$k" '%s' "added"
    done <<<"$to_add"
    sed -n "$((last_line + 1)),\$p" "$file"
  } >"$tmp"
  mv "$tmp" "$file"
  NOTE_FILE_ACTION="(added mappings for keys the loader did not carry)"
}

rewrite_action_file() {
  local file="$1"
  if [[ ! -f "$file" ]]; then
    NOTE_FILE_ACTION="(file not found)"
    STATUS_FILE_ACTION="not-found"
    for k in ${LOADER_KEYS[@]+"${LOADER_KEYS[@]}"}; do
      printf -v "STATUS_EDIT_$k" '%s' "skipped (file not found)"
    done
    return
  fi

  # Cleanliness check (committed file).
  if ! git diff --quiet -- "$file" 2>/dev/null; then
    NOTE_FILE_ACTION="(uncommitted changes — refusing to edit)"
    STATUS_FILE_ACTION="skipped (dirty)"
    for k in ${LOADER_KEYS[@]+"${LOADER_KEYS[@]}"}; do
      printf -v "STATUS_EDIT_$k" '%s' "skipped (file dirty)"
    done
    return
  fi

  # A key DECLARED in .bws-secrets-list but absent from the loader has no
  # placeholder to fill, so the rewriter below found nothing and reported
  # "not-found" — a status that reads like a diagnostic and behaves like a
  # silent no-op. The operator's only remaining move was to hand-edit generated
  # YAML, which the declaration file used to instruct in so many words. That is
  # the manual step this whole path exists to remove, so add the line instead.
  #
  # Appended in KEYS order, immediately after the last existing mapping, with
  # that mapping's indentation — so the output is a function of the declaration
  # and the resolved ids alone, and two runs produce identical bytes.
  append_missing_action_keys "$file"

  # Plan per-key actions.
  local any_replace=false
  local k cur var new_id
  for k in ${LOADER_KEYS[@]+"${LOADER_KEYS[@]}"}; do
    var="SHARED_$k"
    if [[ "${!var:-false}" == "true" ]]; then
      # Shared keys carry their shared project's UUID in action.yml (baked in,
      # not minted here) — never rewrite it.
      local proj_var="SHARED_PROJECT_$k" where
      where="${!proj_var:-}"
      [[ -n "$where" ]] || where="$SHARED_PROJECT_NAME"
      printf -v "STATUS_EDIT_$k" '%s' "shared ($where)"
      continue
    fi
    cur=$(extract_action_key_id "$file" "$k")
    if [[ -z "$cur" ]]; then
      printf -v "STATUS_EDIT_$k" '%s' "not-found"
      continue
    fi
    var="STATUS_EDIT_$k"
    if [[ "${!var:-}" == "added" ]]; then
      continue
    fi
    if ! is_placeholder_uuid "$cur"; then
      printf -v "STATUS_EDIT_$k" '%s' "already-set"
      continue
    fi
    var="ID_$k"
    new_id="${!var}"
    if [[ -z "$new_id" ]]; then
      printf -v "STATUS_EDIT_$k" '%s' "skipped (no new id)"
      continue
    fi
    printf -v "STATUS_EDIT_$k" '%s' "to-replace"
    any_replace=true
  done

  if ! $any_replace; then
    if [[ -n "$NOTE_FILE_ACTION" ]]; then
      STATUS_FILE_ACTION="updated"
    else
      NOTE_FILE_ACTION="(no placeholders to replace)"
      STATUS_FILE_ACTION="no-op"
    fi
    # Convert any "to-replace" entries back to a final state — there are none.
    return
  fi

  # Compose a sed program that replaces any placeholder-family UUID on
  # the lines for keys flagged to-replace.
  # Group numbering (ERE; PLACEHOLDER_PATTERNS contributes one group):
  #   \1 = leading whitespace
  #   \2 = matched placeholder UUID (discarded)
  #   \3 = `[[:space:]]+ > [[:space:]]+ KEY`
  #   \4 = trailing whitespace before EOL
  local sed_script=""
  for k in ${LOADER_KEYS[@]+"${LOADER_KEYS[@]}"}; do
    var="STATUS_EDIT_$k"
    if [[ "${!var}" == "to-replace" ]]; then
      var="ID_$k"
      new_id="${!var}"
      # `#` delimiter (not `|`): PLACEHOLDER_PATTERNS contains literal
      # alternation `|` and would collide with `|` as the sed delimiter.
      sed_script="${sed_script}s#^([[:space:]]*)${PLACEHOLDER_PATTERNS}([[:space:]]+>[[:space:]]+${k})([[:space:]]*)\$#\1${new_id}\3\4#;"
    fi
  done

  local tmp="${file}.tmp.$$"
  sed -E "$sed_script" "$file" >"$tmp"

  # Verify each "to-replace" line actually changed.
  local all_ok=true
  for k in ${LOADER_KEYS[@]+"${LOADER_KEYS[@]}"}; do
    var="STATUS_EDIT_$k"
    if [[ "${!var}" == "to-replace" ]]; then
      var="ID_$k"
      new_id="${!var}"
      if grep -qE "^[[:space:]]*${new_id}[[:space:]]+>[[:space:]]+${k}[[:space:]]*\$" "$tmp"; then
        printf -v "STATUS_EDIT_$k" '%s' "replaced"
      else
        printf -v "STATUS_EDIT_$k" '%s' "error (replacement-failed)"
        all_ok=false
      fi
    fi
  done

  if $all_ok; then
    mv "$tmp" "$file"
    NOTE_FILE_ACTION=""
    STATUS_FILE_ACTION="updated"
  else
    rm -f "$tmp"
    NOTE_FILE_ACTION="(at least one key failed; file not modified)"
    STATUS_FILE_ACTION="error"
  fi
}

# A profile may direct its generated artifacts elsewhere, so a second profile in
# the same repository cannot overwrite the first one's loader or project-id file.
# Relative paths resolve against the repository root; absolute paths are used
# as given.
# Render a resolved absolute path back as repo-relative for display. Falls back
# to the absolute path when the target genuinely lives outside the repository
# (a --test-scaffold-to root, for example), so the summary never claims a
# repo-relative path it did not write.
_display_path() {
  case "$1" in
    "$REPO_ROOT"/*) printf '%s' "${1#"$REPO_ROOT"/}" ;;
    *) printf '%s' "$1" ;;
  esac
}

_resolve_repo_path() {
  case "$1" in
    /*) printf '%s' "$1" ;;
    *) printf '%s/%s' "$REPO_ROOT" "$1" ;;
  esac
}

if [[ -n "$PROJECT_ID_FILE_OPT" ]]; then
  ENV_SAMPLE="$(_resolve_repo_path "$PROJECT_ID_FILE_OPT")"
else
  ENV_SAMPLE="$REPO_ROOT/.env-sample"
fi
ENV_LOCAL="$REPO_ROOT/.env"
if [[ -n "$LOADER_OPT" ]]; then
  ACTION_FILE="$(_resolve_repo_path "$LOADER_OPT")"
else
  ACTION_FILE="$REPO_ROOT/.github/actions/load-secrets/action.yml"
fi

# Resolve the directory containing this script so we can find the
# bundled templates/ directory regardless of how the script was invoked
# (vendored copy, symlink, absolute path, relative path). Used only by
# scaffold_files() below.
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd -P)
TEMPLATES_DIR="$SCRIPT_DIR/templates" # vendored WITH the category (scripts/bws/templates)
# Value the scaffold step writes for every UUID slot. The wizard's
# placeholder check accepts a family of forms; here we always write the
# canonical all-zeros so the diff produced on first bootstrap is
# unambiguous.
SCAFFOLD_PLACEHOLDER="00000000-0000-0000-0000-000000000000"

# Embedded fallback for .env-sample, used when this script was vendored
# into a consumer repo without the surrounding blessed-cicd layout (in
# which case `$TEMPLATES_DIR/.env-sample` won't exist). Keep this in
# sync with `templates/.env-sample` at the repo root.
emit_env_sample() {
  cat <<'EOF'
# Bitwarden Secrets Manager project ID — auto-filled by scripts/bws/bootstrap.sh.
#
# The placeholder below is rewritten to the real project UUID on first
# successful bootstrap. Once rewritten, the wizard treats this line as
# "already-set" and leaves it alone on subsequent runs.
#
# This file is tracked in git (committed). The matching .env (gitignored)
# typically duplicates these export lines verbatim so `source .env` works
# in local-dev shells without leaking real secrets to the repo.
export BWS_PROJECT_ID="00000000-0000-0000-0000-000000000000"
EOF
}

# Canonical _shared-ci secret UUIDs, keyed by secret name. A scaffolded
# action.yml needs the real shared UUID on `shared`-marked lines (bootstrap
# skips rewriting those — they live in _shared-ci, not the per-project), so
# an all-zeros placeholder would never get filled and CI would break. Keep in
# sync with docs/shared-secrets.md and
# templates/.github/actions/load-secrets/action.yml. Unknown shared keys
# return empty → the scaffold falls back to the placeholder and the operator
# fills it by hand.
shared_uuid_for() {
  case "$1" in
    CLOUDFLARE_ACCOUNT_ID) printf '%s' "6c68ee9e-c577-44c5-a5e6-b458007ddc2a" ;;
    BETTERUPTIME_API_TOKEN) printf '%s' "25397dff-4254-4360-b803-b458007df9fa" ;;
    *) printf '%s' "" ;;
  esac
}

# Emits the load-secrets composite action.yml on stdout, with one line per
# active KEY: a per-project placeholder for normal keys, or the canonical
# _shared-ci UUID for `shared`-marked keys. KEYS may have been overridden by
# .bws-secrets-list; this generator honors whatever the script is currently
# configured to manage, so consumer repos with non-default secret sets get a
# usable scaffold.
emit_load_secrets_action_yml() {
  local tmpl="$TEMPLATES_DIR/load-secrets.action.yml.tmpl"
  [[ -f "$tmpl" ]] || die "canonical loader template not found: $tmpl"

  # Build the per-key lines first, then substitute them into the ONE canonical
  # template. There is deliberately no embedded heredoc fallback any more: the
  # previous one duplicated the loader's shape, and because TEMPLATES_DIR pointed
  # at a directory that never existed, the duplicate always won — so it kept
  # scaffolding a floating `uses:` ref long after the template was fixed. A
  # missing template is now a hard error, which is noisy but honest; silently
  # emitting a second, divergent shape is what caused the problem.
  local k uuid shared_var lines=""
  for k in ${LOADER_KEYS[@]+"${LOADER_KEYS[@]}"}; do
    shared_var="SHARED_$k"
    if [[ "${!shared_var:-false}" == "true" ]]; then
      uuid=$(shared_uuid_for "$k")
      [[ -n "$uuid" ]] || uuid="$SCAFFOLD_PLACEHOLDER"
    else
      uuid="$SCAFFOLD_PLACEHOLDER"
    fi
    lines+="          $uuid > $k"$'\n'
  done

  # Strip the template-only header, then splice the generated lines in.
  #
  # The replacement is passed through a FILE, not `awk -v`. BSD awk rejects a
  # newline inside a -v assignment ("awk: newline in string"), so the previous
  # multi-line `-v repl=...` made this function fail outright on macOS — i.e.
  # `bootstrap.sh --scaffold` was broken on every Mac. GNU awk tolerates it,
  # which is why CI never noticed.
  local replfile
  replfile="$(mktemp)" || die "could not create a temp file"
  printf '%s' "${lines%$'\n'}" >"$replfile"
  awk -v replfile="$replfile" '
    /^#<<< END TEMPLATE-ONLY HEADER$/ { stripping = 0; next }
    /^#>>> TEMPLATE-ONLY HEADER/      { stripping = 1 }
    stripping                          { next }
    $0 == "__BWS_SECRET_LINES__" {
      while ((getline line < replfile) > 0) print line
      close(replfile)
      next
    }
    { print }
  ' "$tmpl"
  rm -f "$replfile"
}

# Scaffold any tracked target files that don't exist in the consumer
# repo. Never overwrites existing files. `.env` is deliberately not
# scaffolded — it's gitignored, operator-managed, and would contain
# real secrets.
#
# Both target files have an embedded fallback (heredoc), so this works
# even when the script was vendored without the surrounding
# blessed-cicd layout. The file-system template under templates/ is
# preferred when present so any local customization travels.
scaffold_files() {
  if [[ ! -f "$ENV_SAMPLE" ]]; then
    if [[ -f "$TEMPLATES_DIR/.env-sample" ]]; then
      cp "$TEMPLATES_DIR/.env-sample" "$ENV_SAMPLE"
      info "Scaffolded .env-sample (from $TEMPLATES_DIR/.env-sample)"
    else
      emit_env_sample >"$ENV_SAMPLE"
      info "Scaffolded .env-sample (embedded fallback — no $TEMPLATES_DIR/.env-sample)"
    fi
  fi
  if ! $HAS_LOADER_KEYS; then
    info "No Actions loader scaffolded: every declared key is a managed delivery"
  elif [[ ! -f "$ACTION_FILE" ]]; then
    mkdir -p "$(dirname "$ACTION_FILE")"
    emit_load_secrets_action_yml >"$ACTION_FILE"
    info "Scaffolded $ACTION_FILE (${#LOADER_KEYS[@]} keys: ${LOADER_KEYS[*]-})"
  fi
}

if $DRY_RUN; then
  STATUS_FILE_ENV_SAMPLE="dry-run"
  NOTE_FILE_ENV_SAMPLE=""
  STATUS_FILE_ENV="dry-run"
  NOTE_FILE_ENV=""
  STATUS_FILE_ACTION="dry-run"
  NOTE_FILE_ACTION=""
  if $SCAFFOLD; then
    if $SCAFFOLD_ONLY; then
      # THE SEAM UNDER TEST: the real SCRIPT_DIR -> TEMPLATES_DIR ->
      # scaffold_files -> emit_load_secrets_action_yml path, writing into
      # --out-root. `--dry-run` alone only reports; that is why the golden test
      # could never reach the emitter.
      scaffold_files
      info "--test-scaffold-to: wrote beneath $REPO_ROOT (no BWS/GitHub/auth/interactive calls made)"
      exit 0
    fi
    [[ -f "$ENV_SAMPLE" ]] || info "(dry-run) would scaffold .env-sample"
    if $HAS_LOADER_KEYS; then
      [[ -f "$ACTION_FILE" ]] || info "(dry-run) would scaffold $ACTION_FILE (${#LOADER_KEYS[@]} keys)"
    fi
  fi
  for k in "${KEYS[@]}"; do
    printf -v "STATUS_EDIT_$k" '%s' "dry-run"
  done
  for k in ${DELIVERED_KEYS[@]+"${DELIVERED_KEYS[@]}"}; do
    printf -v "STATUS_EDIT_$k" '%s' "n/a (managed delivery)"
  done
  $HAS_LOADER_KEYS || STATUS_FILE_ACTION="not applicable"
elif ! $MUTATE; then
  STATUS_FILE_ENV_SAMPLE="unchanged"
  NOTE_FILE_ENV_SAMPLE="(read-only plan)"
  STATUS_FILE_ENV="unchanged"
  NOTE_FILE_ENV="(read-only plan)"
  STATUS_FILE_ACTION="unchanged"
  NOTE_FILE_ACTION="(read-only plan)"
  # Read the loader as it stands. "Next action: run reconcile" is only the exact
  # next action while something is actually unmapped; printed unconditionally it
  # becomes a standing instruction to run an apply-mode command that would do
  # nothing, which is how an operator learns to ignore the line.
  LOADER_FULLY_MAPPED=true
  for k in ${DELIVERED_KEYS[@]+"${DELIVERED_KEYS[@]}"}; do
    printf -v "STATUS_EDIT_$k" '%s' "n/a (managed delivery)"
  done
  $HAS_LOADER_KEYS || {
    STATUS_FILE_ACTION="not applicable"
    NOTE_FILE_ACTION="(no Actions consumer)"
  }
  for k in ${LOADER_KEYS[@]+"${LOADER_KEYS[@]}"}; do
    s_var="STATUS_$k"
    shared_var="SHARED_$k"
    if [[ "${!shared_var:-false}" == "true" ]]; then
      printf -v "STATUS_EDIT_$k" '%s' "shared"
      continue
    fi
    if [[ "${!s_var}" == "MISSING" ]]; then
      printf -v "STATUS_EDIT_$k" '%s' "blocked (secret missing)"
      LOADER_FULLY_MAPPED=false
      continue
    fi
    cur="$(extract_action_key_id "$ACTION_FILE" "$k")"
    if [[ -n "$cur" ]] && ! is_placeholder_uuid "$cur"; then
      printf -v "STATUS_EDIT_$k" '%s' "mapped"
    else
      printf -v "STATUS_EDIT_$k" '%s' "would map"
      LOADER_FULLY_MAPPED=false
    fi
  done
else
  if $SCAFFOLD; then
    scaffold_files
  fi
  # --- .env-sample (tracked) ---
  if [[ -f "$ENV_SAMPLE" ]]; then
    if ! git diff --quiet -- "$ENV_SAMPLE" 2>/dev/null; then
      STATUS_FILE_ENV_SAMPLE="skipped (dirty)"
      NOTE_FILE_ENV_SAMPLE="(uncommitted changes — refusing to edit)"
    else
      STATUS_FILE_ENV_SAMPLE=$(rewrite_env_file "$ENV_SAMPLE" "$ID_PROJECT")
      NOTE_FILE_ENV_SAMPLE=""
    fi
  else
    STATUS_FILE_ENV_SAMPLE="not-found"
    NOTE_FILE_ENV_SAMPLE="(no .env-sample at repo root)"
  fi

  # --- .env (gitignored) — backup before editing ---
  if [[ -f "$ENV_LOCAL" ]]; then
    cur=$(extract_env_project_id "$ENV_LOCAL")
    if [[ -z "$cur" ]]; then
      STATUS_FILE_ENV="not-found"
      NOTE_FILE_ENV="(BWS_PROJECT_ID line not present)"
    elif ! is_placeholder_uuid "$cur"; then
      STATUS_FILE_ENV="already-set"
      NOTE_FILE_ENV="(real UUID present)"
    else
      ts=$(date +%Y%m%d-%H%M%S)
      backup="${ENV_LOCAL}.bak.${ts}"
      cp -p "$ENV_LOCAL" "$backup"
      result=$(rewrite_env_file "$ENV_LOCAL" "$ID_PROJECT")
      STATUS_FILE_ENV="$result"
      NOTE_FILE_ENV="(backed up to $(basename "$backup"))"
    fi
  else
    STATUS_FILE_ENV="not-found"
    NOTE_FILE_ENV="(no .env, that's fine)"
  fi

  # --- .github/actions/load-secrets/action.yml (tracked) ---
  for k in ${DELIVERED_KEYS[@]+"${DELIVERED_KEYS[@]}"}; do
    printf -v "STATUS_EDIT_$k" '%s' "n/a (managed delivery)"
  done
  if ! $HAS_LOADER_KEYS; then
    STATUS_FILE_ACTION="not applicable"
    NOTE_FILE_ACTION="(no Actions consumer — no loader is generated or edited)"
  elif $ANY_NO_SECRET_VALUES_SKIP; then
    # Defer action.yml rewrite until the operator has pasted values
    # via the Bitwarden vault web UI and re-run the wizard. Rewriting
    # now would leave a tracked diff with some keys filled and some
    # still at the placeholder — exactly the half-finished state the
    # two-phase --no-secret-values flow is meant to avoid. .env-sample
    # (above) does get its real BWS_PROJECT_ID, which is safe to
    # commit independently.
    STATUS_FILE_ACTION="deferred"
    NOTE_FILE_ACTION="(deferred — paste secret values in Bitwarden vault web UI, then re-run)"
    for k in ${LOADER_KEYS[@]+"${LOADER_KEYS[@]}"}; do
      printf -v "STATUS_EDIT_$k" '%s' "deferred"
    done
  else
    rewrite_action_file "$ACTION_FILE"
  fi
fi

# ---------------------------------------------------------------------------
# Step 6 — Summary
# ---------------------------------------------------------------------------
say ""
say "============================================================"
say "  Summary"
say "============================================================"
printf "  %-22s %s\n" "APP_NAME" "$APP_NAME"
printf "  %-22s %s\n" "GitHub repo" "$REPO"
printf "  %-22s %s\n" "BWS project name" "$PROJECT_NAME"
say ""
printf "  %-40s %-20s %s\n" "Resource" "Status" "ID / Notes"
printf "  %-40s %-20s %s\n" "----------------------------------------" "--------------------" "------------"
printf "  %-40s %-20s %s\n" "BWS project" "$STATUS_PROJECT" "$ID_PROJECT"
for k in "${KEYS[@]}"; do
  s_var="STATUS_$k"
  i_var="ID_$k"
  printf "  %-40s %-20s %s\n" "BWS secret $k" "${!s_var}" "${!i_var}"
done
printf "  %-40s %-20s %s\n" "GH secret BWS_ACCESS_TOKEN" "$STATUS_GH" "$REPO"
for k in ${DELIVERED_KEYS[@]+"${DELIVERED_KEYS[@]}"}; do
  s_var="STATUS_DELIVER_$k"
  d_var="DELIVER_$k"
  printf "  %-40s %-20s %s\n" "Dependabot secret $k" "${!s_var:-skipped}" "${!d_var#*@}"
done

say ""
say "  File edits"
say "  ------------------------------------------------------------"
# Report the EFFECTIVE targets, not the defaults. With --loader /
# --project-id-file the script writes elsewhere, and a summary naming
# `.env-sample` and the validation loader would send an operator to the wrong
# files — or, worse, make a deployment profile's plan indistinguishable from the
# validation profile it must never touch. The plan is the operator's evidence
# before any real write; it has to describe the writes that will happen.
printf "  %-40s %-20s %s\n" "$(_display_path "$ENV_SAMPLE")" "$STATUS_FILE_ENV_SAMPLE" "$NOTE_FILE_ENV_SAMPLE"
printf "  %-40s %-20s %s\n" "$(_display_path "$ENV_LOCAL")" "$STATUS_FILE_ENV" "$NOTE_FILE_ENV"
printf "  %-40s %-20s %s\n" "$(_display_path "$ACTION_FILE")" "$STATUS_FILE_ACTION" "$NOTE_FILE_ACTION"
for k in "${KEYS[@]}"; do
  s_var="STATUS_EDIT_$k"
  printf "    %-38s %-20s\n" "$k" "${!s_var}"
done

say ""
if $PLAN; then
  # ONE consolidated block. The operator should not have to scroll a transcript
  # and assemble the state themselves — every declared credential, its status,
  # and the single next action that changes it.
  say "  Credential inventory — $PROJECT_NAME (BWS) / $REPO (GitHub)"
  say "  ------------------------------------------------------------"
  _missing=""
  for k in "${KEYS[@]}"; do
    s_var="STATUS_$k"
    case "${!s_var}" in
      MISSING) _missing="${_missing:+$_missing }$k" ;;
    esac
  done
  if [[ "$STATUS_PROJECT" == "MISSING" ]]; then
    say "  BWS project '$PROJECT_NAME' does not exist."
    say "    Next action: run  make bws-bootstrap  from this branch."
  fi
  # The GitHub transport credential is part of the answer, not a footnote. A
  # summary that reported every BWS secret present and then said "Next action:
  # none" was describing a repository that could still not load a single one,
  # because the token CI authenticates with was absent — or, worse, because the
  # query that would have said so had failed.
  case "$STATUS_GH" in
    UNOBSERVABLE*)
      say "  GitHub secret BWS_ACCESS_TOKEN: NOT OBSERVED — the query failed."
      say "    This is not evidence of absence. Nothing below is a complete answer"
      say "    until it can be read."
      say ""
      say "    Next action: repair GitHub access ('gh auth status'), then re-run"
      say "    make bws-plan. Do not create a replacement credential on this run."
      say ""
      ;;
    MISSING*)
      say "  GitHub secret BWS_ACCESS_TOKEN: $STATUS_GH"
      say "    Without it CI cannot authenticate to Bitwarden, so every secret"
      say "    below is present and unreachable."
      say ""
      say "    Next action: run  make bws-bootstrap  and paste the machine-account"
      say "    token when prompted."
      say ""
      ;;
  esac
  _deliver_pending=""
  for k in ${DELIVERED_KEYS[@]+"${DELIVERED_KEYS[@]}"}; do
    s_var="STATUS_DELIVER_$k"
    case "${!s_var}" in
      "would deliver"* | UNOBSERVABLE*) _deliver_pending="${_deliver_pending:+$_deliver_pending }$k" ;;
    esac
  done
  if [[ -n "$_deliver_pending" ]]; then
    say "  Managed deliveries needing a run: $_deliver_pending"
    say "    Next action: run  make bws-bootstrap  — it proves each token against"
    say "    its declared scope, then copies it into the Dependabot namespace."
    say ""
  fi
  if [[ -z "$_missing" ]]; then
    say "  Every declared credential is PRESENT in BWS. Nothing to mint, nothing"
    say "  to rotate — a new session is not a reason to recreate a stored value."
    say ""
    if ! $HAS_LOADER_KEYS; then
      if [[ -n "$_deliver_pending" ]]; then
        say "    Next action: the delivery run above."
      else
        say "    Every managed delivery is up to date. Next action: none."
      fi
    elif [[ "$STATUS_GH" != "present" ]]; then
      say "    Next action: resolve the GitHub credential state above first — it"
      say "    decides whether any of this is loadable."
    elif $LOADER_FULLY_MAPPED; then
      say "    The generated loader already carries every one of them."
      say "    Next action: none. This repository is fully reconciled."
    else
      say "    Next action: run  make bws-reconcile  to resolve each secret's"
      say "    UUID into the generated loader. It reads no secret value."
    fi
  else
    say "  MISSING from BWS project '$PROJECT_NAME':"
    for k in $_missing; do
      say "    - $k   (requirements printed above, under 'Checking BWS secret: $k')"
    done
    say ""
    say "  Next action, in order:"
    say "    1. Mint each missing credential exactly as its REQUIRED BY THIS"
    say "       REPOSITORY block above specifies. Those values are authoritative."
    say "    2. Store it in the Bitwarden vault web UI:"
    say "         https://vault.bitwarden.com → Secrets Manager"
    say "         Project: $PROJECT_NAME"
    say "         Key:     <the name above, exactly>"
    say "    3. Re-run  make bws-plan  from THIS branch ($_branch) to confirm it"
    say "       is present. The declaration lives on the branch, so a run from"
    say "       another branch will not see this credential at all."
    say "    4. Run  make bws-reconcile  to generate the loader mapping."
  fi
  say ""
  say "  Mode: PLAN — nothing was created, set, prompted for, or written."
  say "  No secret value was prompted for, stored, printed, or written. Values do"
  say "  traverse the \`bws secret list\` -> jq pipe, because the CLI has no listing"
  say "  that omits them; jq discards them at that boundary and the wizard only ever"
  say "  holds the key-to-id mapping."
elif $DRY_RUN; then
  say "  Mode: DRY-RUN — nothing was changed externally or on disk."
elif $NO_SECRET_VALUES; then
  say "  Mode: --no-secret-values"
  if $ANY_NO_SECRET_VALUES_SKIP; then
    # Describe the phases this repository's declaration actually has. A
    # delivery-only consumer creates no machine account, no BWS_ACCESS_TOKEN,
    # no .env-sample and no loader, so the loader-centric wording contradicted
    # the rows printed immediately above it.
    say "    Two-phase bootstrap in progress."
    if $HAS_LOADER_KEYS; then
      say "    Phase 1 (this run): BWS project + GH BWS_ACCESS_TOKEN created."
      say "                        .env-sample updated with real BWS_PROJECT_ID."
      say "                        action.yml per-key UUIDs DEFERRED (would be"
      say "                        half-filled otherwise)."
    else
      say "    Phase 1 (this run): BWS project ensured. No machine account,"
      say "                        BWS_ACCESS_TOKEN or loader is created for this"
      say "                        repository — every declared key is a managed"
      say "                        delivery, so Actions never reads Bitwarden here."
    fi
    say "    Phase 2 (you, now):"
    say "      1. Open https://vault.bitwarden.com → Secrets Manager →"
    say "         project '$PROJECT_NAME'."
    say "      2. Paste a value for every 'skipped (no-secret-values)' entry"
    say "         in the summary above."
    if $HAS_LOADER_KEYS; then
      say "      3. Re-run this script (no flag needed). It will detect the new"
      say "         secrets and fill action.yml on disk."
    else
      say "      3. Re-run this script (no flag needed). It will detect the new"
      say "         secret, prove it against its declared scope, record its"
      say "         expiry, then deliver and verify the managed copy."
    fi
  elif $HAS_DELIVERIES; then
    say "    No secrets were skipped — every secret already existed in BWSM."
    $HAS_LOADER_KEYS && say "    File edits proceeded as normal."
    say "    Managed deliveries were reconciled; see the Dependabot secret rows above."
  else
    say "    No secrets were skipped — every secret already existed in BWSM."
    say "    File edits proceeded as normal."
  fi
  if $HAS_LOADER_KEYS; then
    say "  Review file changes:  git diff"
    say "  Note: any .env.bak.* backups are gitignored (since .env is)."
  fi
else
  say "  Review file changes:  git diff"
  say "  Note: any .env.bak.* backups are gitignored (since .env is)."
fi
if $DELIVERY_FAILED; then
  say "  One or more managed deliveries did NOT complete (see the Dependabot"
  say "  secret rows above). Nothing partial was left behind: each key is"
  say "  written atomically or not at all. Fix the reported cause and re-run;"
  say "  keys already up to date are skipped."
fi
say "============================================================"
$DELIVERY_FAILED && exit 1
exit 0
