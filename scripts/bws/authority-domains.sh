#!/usr/bin/env bash
# authority-domains.sh — operator tool for secrets.bwsm-authority-domains@1.
#
# Provision (guided) and ROTATE the high-value release authority domains (signing
# key, dispatch token). A rotation is a resumable, fail-closed, multi-checkpoint
# transaction whose boundaries correspond to REMOTE state — not the local worktree:
#
#   plan                 read-only preflight; creates NO state
#   rotate-signing-key   run/continue a rotation to the next STOP
#   audit                read-only GitHub-side conformance (partial; full auditor = #197)
#   resume <id>          continue a specific rotation
#
# Because trust distribution and activation cannot be atomic with a remote CI proof,
# the rotation STOPS for the operator to commit/merge, then VERIFIES the exact remote
# ref before proceeding:
#
#   prepare → trust-prepare(STOP) → trust-deploy(verify remote) → store
#           → smoke(dispatch + verify exact run) → activate-prepare(STOP)
#           → activate-deploy(verify remote) → finalize
#
# Rotation is IN-PLACE: the BWS secret keeps its name + UUID; only its VALUE (the
# PEM) is replaced in the vault. The loader UUID changes only at provisioning.
#
# SECURITY: no private key or access token on argv, stdout/stderr, the state file,
# or git. BWS auth is via BWS_ACCESS_TOKEN (env), never -t. Every mutation fails
# closed. State is non-secret, 0600, under an OPAQUE rotation id. Never commits/pushes.
set -uo pipefail
set +a
umask 077
case "$-" in *x*) set +x ;; esac

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${AD_REPO_ROOT:-$(cd "$HERE/../.." && pwd)}"
SIGNING_DIR="${AD_SIGNING_DIR:-$HERE/../signing}"
STATE_ROOT="${AD_STATE_ROOT:-${XDG_CACHE_HOME:-$HOME/.cache}/blessed/authority-rotations}"
LOADER="$REPO_ROOT/.github/actions/load-secrets/action.yml"
SMOKE_WORKFLOW="authority-domain-smoke.yml"
KEY_ID_RE='^[a-z0-9][a-z0-9._-]{0,63}$'

log() { printf 'authority-domains: %s\n' "$*" >&2; }
die() {
  printf 'authority-domains: %s\n' "$*" >&2
  exit 1
}
have() { command -v "$1" >/dev/null 2>&1; }
require_tools() {
  local t
  for t in "$@"; do have "$t" || die "required tool not found: $t"; done
}
valid_key_id() { [[ "$1" =~ $KEY_ID_RE ]] && [ "${1%%..*}" = "$1" ]; }

# ── topology discovery (blessed.yml is the single source of truth) ──────────────
discover_domain() { # sets AUTH_PROJECT AUTH_MACHINE AUTH_ENV AUTH_SECRET AUTH_BRANCH
  local domain="$1" m="$REPO_ROOT/blessed.yml" base
  [ -f "$m" ] || die "blessed.yml not found at repo root"
  have yq || die "mikefarah yq required"
  base=".secret_authorities.\"$domain\""
  yq -e "$base" "$m" >/dev/null 2>&1 || die "blessed.yml declares no secret_authorities domain: $domain"
  AUTH_PROJECT="$(yq -r "$base.bwsm_project" "$m")"
  AUTH_ENV="$(yq -r "$base.github_environment" "$m")"
  AUTH_SECRET="$(yq -r "$base.injects[0]" "$m")"
  AUTH_BRANCH="$(yq -r "$base.allowed_refs.branches[0] // \"release\"" "$m")"
  { [ -n "$AUTH_PROJECT" ] && [ "$AUTH_PROJECT" != null ]; } || die "$domain: bwsm_project missing"
  { [ -n "$AUTH_SECRET" ] && [ "$AUTH_SECRET" != null ]; } || die "$domain: injects[] secret missing"
  { [ -n "$AUTH_ENV" ] && [ "$AUTH_ENV" != null ]; } || die "$domain: github_environment missing"
}

repo_slug() {
  if [ -n "${AD_SLUG:-}" ]; then
    printf '%s' "$AD_SLUG"
    return
  fi
  git -C "$REPO_ROOT" remote get-url origin 2>/dev/null |
    sed -E 's#(git@github.com:|https://github.com/)##; s#\.git$##'
}

loader_uuid_for() {
  [ -f "$LOADER" ] || return 0
  grep -E "> +$1\$" "$LOADER" | awk '{print $1}' | head -n1
}

# ── secret-material guard: scan BOTH the working tree AND the staged index ───────
# (no non-portable \b; each blob is materialized to a 0600 temp before scanning so a
# grep short-circuit can't SIGPIPE a git pipe under pipefail. Reports class+path+line.)
SECRET_PRIV='BEGIN [A-Z ]*PRIVATE KEY'
SECRET_GHT='(ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})'
SECRET_BWS='0\.[0-9a-f]{8}-[0-9a-f-]{27}\.[A-Za-z0-9+/]{20,}'
skip_path() { case "$1" in *release-trusted-keys.json | *.pub) return 0 ;; *) return 1 ;; esac }
# WHOLE-FILE identity exemption. The bws test suite embedded a synthetic fake key
# (body "ZZ") inline to exercise THIS scanner, so every pre-v1.5.3 release carries a
# real BEGIN-PRIVATE-KEY marker in authority-domains-test.sh — which would make
# finalize's scan fail forever in any consumer that vendored bws. Exempt ONLY a
# BYTE-IDENTICAL copy of a KNOWN reviewed released file: private-key class only, at the
# exact test-file path only, and only when the WHOLE FILE's SHA-256 is one of the
# reviewed release hashes below. Because the check is over the entire file, ANY byte
# change — a second real marker on the same or a different line, a real key, a changed
# body, one extra byte — alters the hash and removes the exemption automatically. It
# cannot fail open (a per-line/substring test could: a line bearing the fixture AND a
# second marker would be skipped whole). v1.5.3+ builds fake markers from split strings,
# so the shipped source carries no marker and this allowlist never needs to grow.
#
# Provenance — each hash is the authority-domains-test.sh row of that release's
# MANIFEST.sha256 (== SHA-256 of that exact released file):
#   bws-v1.5.0  6582e3837e144345c765b9b86efabd5581794311fce17d310f83db4281eb118a
#   bws-v1.5.1  cfbe22936e07bf02bb8be3e3eb03f77e32c522c4d648f0584bfdcb15a47d8970
#   bws-v1.5.2  663d633fbad4a6e0ce7f25db4d821bdd4dcab0a784413ad04ee7ff27449f2f38
FIXTURE_TESTFILE='scripts/bws/authority-domains-test.sh'
FIXTURE_KNOWN_SHA256='6582e3837e144345c765b9b86efabd5581794311fce17d310f83db4281eb118a
cfbe22936e07bf02bb8be3e3eb03f77e32c522c4d648f0584bfdcb15a47d8970
663d633fbad4a6e0ce7f25db4d821bdd4dcab0a784413ad04ee7ff27449f2f38'
_sha256_of() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }
_is_known_fixture_file() { # src path → rc 0 iff a byte-identical KNOWN released test file
  local src="$1" path="$2" h
  [ "$path" = "$FIXTURE_TESTFILE" ] || return 1
  h="$(_sha256_of "$src")"
  [ -n "$h" ] || return 1
  # AD_EXTRA_FIXTURE_SHA256 is a TEST-ONLY seam to allowlist a hash the suite builds;
  # production ships only the three reviewed release hashes above.
  {
    printf '%s\n' "$FIXTURE_KNOWN_SHA256"
    [ -n "${AD_EXTRA_FIXTURE_SHA256:-}" ] && printf '%s\n' "$AD_EXTRA_FIXTURE_SHA256"
  } | grep -qxF "$h"
}
_scan_file() { # src view path → echoes "class view path:line" per REAL hit; rc 1 if any
  local src="$1" view="$2" path="$3" cls re found=0 exempt=0 hit
  _is_known_fixture_file "$src" "$path" && exempt=1
  for cls in "private-key:$SECRET_PRIV" "github-token:$SECRET_GHT" "bws-token:$SECRET_BWS"; do
    # exempt ONLY the private-key class, ONLY for a byte-identical known released file
    if [ "$exempt" = 1 ] && [ "${cls%%:*}" = "private-key" ]; then continue; fi
    re="${cls#*:}"
    while IFS= read -r hit; do
      echo "  ${cls%%:*} $view $path:${hit%%:*}"
      found=1
    done < <(grep -nE "$re" "$src" 2>/dev/null)
  done
  [ "$found" = 0 ] # rc 0 = clean; rc 1 = secret found
}
scan_secret_markers() { # prints hits (class+path+line only); return 1 if any
  local hits=0 f scratch blob repo_abs state_abs abs start c bsha bpath seen
  scratch="$(mktemp -d)" || die "scan: mktemp failed"
  chmod 700 "$scratch" 2>/dev/null || true
  blob="$scratch/blob"
  repo_abs="$(cd "$REPO_ROOT" 2>/dev/null && pwd -P)" || repo_abs="$REPO_ROOT"
  # The protected rotation state dir holds the live PEM by design; it is excluded
  # from the untracked-worktree scan so cleanup can be proved without self-tripping.
  state_abs=""
  [ -d "$STATE_ROOT" ] && state_abs="$(cd "$STATE_ROOT" && pwd -P)"
  # 1. WORKTREE — tracked AND untracked-non-ignored (an accidentally copied PEM
  #    that was never `git add`ed would otherwise sit undetected beside the repo).
  while IFS= read -r f; do
    skip_path "$f" && continue
    abs="$repo_abs/$f"
    if [ -n "$state_abs" ]; then case "$abs/" in "$state_abs"/*) continue ;; esac fi
    [ -f "$abs" ] || continue
    _scan_file "$abs" worktree "$f" || hits=1
  done < <(git -C "$REPO_ROOT" ls-files --cached --others --exclude-standard 2>/dev/null)
  # 2. INDEX — staged blobs may differ from the worktree.
  while IFS= read -r f; do
    skip_path "$f" && continue
    (umask 077 && git -C "$REPO_ROOT" show ":$f" >"$blob" 2>/dev/null) || continue
    _scan_file "$blob" index "$f" || hits=1
  done < <(git -C "$REPO_ROOT" diff --cached --name-only 2>/dev/null)
  # 3. HISTORY — every blob introduced since the rotation's starting commit. A PEM
  #    committed mid-rotation and deleted later still lives in reachable history.
  start="$(sget start_commit 2>/dev/null || true)"
  if [ -n "$start" ] && git -C "$REPO_ROOT" rev-parse -q --verify "$start^{commit}" >/dev/null 2>&1; then
    git -C "$REPO_ROOT" merge-base --is-ancestor "$start" HEAD 2>/dev/null ||
      die "finalize: HEAD is not a descendant of the rotation's starting commit $start — history boundary cannot be verified"
    seen="$scratch/seen"
    : >"$seen"
    while IFS= read -r c; do
      [ -n "$c" ] || continue
      while IFS=$'\t' read -r bsha bpath; do
        { [ -n "$bsha" ] && [ -n "$bpath" ]; } || continue
        skip_path "$bpath" && continue
        grep -qxF "$bsha" "$seen" && continue
        echo "$bsha" >>"$seen"
        (umask 077 && git -C "$REPO_ROOT" cat-file blob "$bsha" >"$blob" 2>/dev/null) || continue
        _scan_file "$blob" "history($c)" "$bpath" || hits=1
      done < <(git -C "$REPO_ROOT" diff-tree --no-commit-id -r "$c" 2>/dev/null |
        awk -F'\t' '{ n=split($1, a, " "); dst=a[4]; st=a[5]; if (dst !~ /^0+$/ && st !~ /^D/) print dst "\t" $NF }')
    done < <(git -C "$REPO_ROOT" rev-list "$start"..HEAD 2>/dev/null)
  fi
  rm -rf "$scratch"
  return "$hits"
}

# ── non-secret rotation state (atomic, verified writes) ─────────────────────────
STATE_DIR="" STATE_FILE="" RID=""
ROTATION_ID_RE='^rotation-[0-9A-Za-z._-]{1,80}$'
valid_rotation_id() { [[ "$1" =~ $ROTATION_ID_RE ]] && [ "${1%%..*}" = "$1" ] && [ "${1%%/*}" = "$1" ]; }
state_create_new() { # $1 = internally generated opaque id; refuses an existing path
  local id="$1"
  valid_rotation_id "$id" || die "internal: generated rotation-id is invalid"
  STATE_DIR="$STATE_ROOT/$id"
  STATE_FILE="$STATE_DIR/state.json"
  RID="$id"
  [ ! -e "$STATE_DIR" ] || die "state dir already exists: $id"
  mkdir -p "$STATE_ROOT" || die "cannot create state root"
  chmod 700 "$STATE_ROOT" || die "chmod state root failed"
  mkdir "$STATE_DIR" || die "cannot create state dir"
  chmod 700 "$STATE_DIR" || die "chmod state dir failed"
  echo '{"phases_done":[]}' >"$STATE_FILE" || die "state init failed"
  chmod 600 "$STATE_FILE" || die "chmod state file failed"
}
state_open_existing() { # $1 = resume id; validated + path-safe; NEVER creates
  local id="$1" root cand
  valid_rotation_id "$id" || die "resume: invalid rotation-id '$id'"
  root="$(cd "$STATE_ROOT" 2>/dev/null && pwd -P)" || die "resume: state root does not exist"
  STATE_DIR="$STATE_ROOT/$id"
  [ -d "$STATE_DIR" ] || die "resume: no rotation '$id'"
  [ ! -L "$STATE_DIR" ] || die "resume: '$id' is a symlink"
  cand="$(cd "$STATE_DIR" 2>/dev/null && pwd -P)" || die "resume: cannot open '$id'"
  case "$cand/" in "$root"/*) : ;; *) die "resume: '$id' escapes the state root" ;; esac
  STATE_FILE="$STATE_DIR/state.json"
  { [ -f "$STATE_FILE" ] && [ ! -L "$STATE_FILE" ]; } || die "resume: no state file for '$id'"
  jq -e . "$STATE_FILE" >/dev/null 2>&1 || die "resume: malformed state for '$id'"
  RID="$id"
}
sput() { # jq filter + args → atomically transform state, then re-read to verify
  local tmp="$STATE_FILE.tmp"
  jq "$@" "$STATE_FILE" >"$tmp" || die "state transform failed"
  mv "$tmp" "$STATE_FILE" || die "state rename failed"
  chmod 600 "$STATE_FILE" || die "chmod state file failed"
  jq -e . "$STATE_FILE" >/dev/null 2>&1 || die "state file corrupt after write"
}
# shellcheck disable=SC2016  # jq filters — $k/$v/$p are jq vars, must stay single-quoted
sset() { sput --arg k "$1" --arg v "$2" '.[$k]=$v'; }
sget() { jq -r --arg k "$1" '.[$k] // empty' "$STATE_FILE"; }
phase_done() { jq -e --arg p "$1" '.phases_done | index($p)' "$STATE_FILE" >/dev/null 2>&1; }
# shellcheck disable=SC2016
mark_phase() { sput --arg p "$1" '.phases_done += [$p] | .phases_done |= unique'; }

new_rotation_id() { printf 'rotation-%s-%s' "$(date -u +%Y%m%dT%H%M%SZ)" "$(openssl rand -hex 4)"; }
find_rotation() { # old new domain → prints existing (unfinished) rid or empty
  local d b
  [ -d "$STATE_ROOT" ] || return 0
  for d in "$STATE_ROOT"/*/; do
    b="$(basename "$d")"
    [ -f "$d/state.json" ] || continue
    if [ "$(jq -r '.old_key_id // empty' "$d/state.json")" = "$1" ] &&
      [ "$(jq -r '.new_key_id // empty' "$d/state.json")" = "$2" ] &&
      [ "$(jq -r '.domain // empty' "$d/state.json")" = "$3" ] &&
      ! jq -e '.phases_done | index("finalize")' "$d/state.json" >/dev/null 2>&1; then
      printf '%s' "$b"
      return 0
    fi
  done
}

# ── remote reads (all via gh; one mock surface in tests) ────────────────────────
remote_file() { # repo ref path → prints committed bytes, or fails
  gh api "repos/$1/contents/$3?ref=$2" --jq '.content' 2>/dev/null | base64 -d 2>/dev/null
}
remote_has_path() { gh api "repos/$1/contents/$3?ref=$2" >/dev/null 2>&1; }

trust_targets_json() { jq -c '.trust_targets // []' "$STATE_FILE"; }

# ════════════════════════════════════════════════════════════════════════════════
# phases
# ════════════════════════════════════════════════════════════════════════════════
ph_preflight() { # runs every invocation; validates, never mutates
  local slug="$1"
  discover_domain "$DOMAIN"
  valid_key_id "$OLD" || die "old key_id '$OLD' violates key-id grammar"
  valid_key_id "$NEW" || die "new key_id '$NEW' violates key-id grammar"
  local store="$REPO_ROOT/release-trusted-keys.json"
  [ -f "$store" ] || die "producer trust store not found: $store"
  jq -e --arg k "$OLD" '.keys[$k]' "$store" >/dev/null 2>&1 || die "old key_id '$OLD' not in trust store"
  # INITIAL-STATE checks (old active, new absent) apply only BEFORE trust is prepared;
  # after trust-prepare the local store legitimately has old revoked/verify-only + new active.
  if ! { [ -n "$STATE_FILE" ] && [ -f "$STATE_FILE" ] && phase_done trust-prepare; }; then
    [ "$(jq -r --arg k "$OLD" '.keys[$k].status' "$store")" = active ] || die "old key_id '$OLD' is not active"
    if jq -e --arg k "$NEW" '.keys[$k]' "$store" >/dev/null 2>&1; then die "new key_id '$NEW' already exists — never reuse a key_id"; fi
  fi
  [ -n "$(loader_uuid_for "$AUTH_SECRET")" ] || die "loader has no mapping for $AUTH_SECRET"
  [ "$(loader_uuid_for "$AUTH_SECRET")" != "00000000-0000-0000-0000-000000000000" ] || die "loader still has a placeholder UUID for $AUTH_SECRET"
  # the smoke workflow must be installed locally (rotation dispatches it remotely)
  [ -f "$REPO_ROOT/.github/workflows/$SMOKE_WORKFLOW" ] ||
    die "$SMOKE_WORKFLOW not installed locally — run: authority-domains.sh install-smoke-workflow"
  # vendored-artifact integrity — FAIL CLOSED (require, don't conditionally check):
  # the consumer must pin the exact bws version+tag that ships this tool, and the
  # category MANIFEST must verify. (AD_SKIP_VENDOR_CHECK is a test-only override.)
  if [ "${AD_SKIP_VENDOR_CHECK:-0}" != 1 ]; then
    # Canonical pin file, with the documented legacy fallback (scripts/INSTALL.md):
    # a migrating repo may still carry only .bws-scripts-version; canonical wins.
    local cat="${AD_CATEGORY_DIR:-$HERE}" pinfile="$REPO_ROOT/scripts/.blessed-scripts-version"
    [ -f "$pinfile" ] || pinfile="$REPO_ROOT/scripts/.bws-scripts-version"
    # The verifier ships INSIDE the bws category (verify-category-manifest.sh), so a
    # consumer installed from the tarball alone — with no source-tree scripts/manifest.sh —
    # can still verify integrity. AD_VERIFIER is a test-only override.
    local verifier="${AD_VERIFIER:-$HERE/verify-category-manifest.sh}" ver pinv pint
    [ -f "$pinfile" ] ||
      die "preflight: no scripts/.blessed-scripts-version (or legacy .bws-scripts-version) — the consumer must pin the bws version"
    [ -f "$cat/VERSION" ] || die "preflight: $cat/VERSION missing"
    [ -f "$cat/MANIFEST.sha256" ] || die "preflight: $cat/MANIFEST.sha256 missing"
    [ -f "$verifier" ] || die "preflight: category verifier not found at $verifier"
    ver="$(cat "$cat/VERSION")"
    pinv="$(grep -E '^BWS_VERSION=' "$pinfile" | cut -d= -f2 | tr -d '[:space:]')"
    pint="$(grep -E '^BWS_TAG=' "$pinfile" | cut -d= -f2 | tr -d '[:space:]')"
    [ -n "$pinv" ] || die "preflight: BWS_VERSION missing from $pinfile"
    [ "$pinv" = "$ver" ] || die "preflight: pinned BWS_VERSION=$pinv but this tool is $ver"
    [ "$pint" = "bws-v$ver" ] || die "preflight: BWS_TAG=$pint but expected bws-v$ver"
    bash "$verifier" "$cat" >/dev/null 2>&1 || die "preflight: bws category MANIFEST does not verify"
    # the sibling signing category (the smoke workflow signs with it) must be pinned + verify
    local sver spin stag
    [ -f "$SIGNING_DIR/VERSION" ] || die "preflight: $SIGNING_DIR/VERSION missing"
    [ -f "$SIGNING_DIR/MANIFEST.sha256" ] || die "preflight: signing MANIFEST.sha256 missing"
    sver="$(cat "$SIGNING_DIR/VERSION")"
    spin="$(grep -E '^SIGNING_VERSION=' "$pinfile" | cut -d= -f2 | tr -d '[:space:]')"
    stag="$(grep -E '^SIGNING_TAG=' "$pinfile" | cut -d= -f2 | tr -d '[:space:]')"
    [ -n "$spin" ] || die "preflight: SIGNING_VERSION missing from $pinfile"
    [ "$spin" = "$sver" ] || die "preflight: pinned SIGNING_VERSION=$spin but signing is $sver"
    [ "$stag" = "signing-v$sver" ] || die "preflight: SIGNING_TAG=$stag but expected signing-v$sver"
    bash "$verifier" "$SIGNING_DIR" >/dev/null 2>&1 || die "preflight: signing category MANIFEST does not verify"
  fi
  # GitHub-side install preflight (skippable only for a fully offline plan)
  if [ "${AD_SKIP_GH:-0}" != 1 ]; then
    # workflow_dispatch is DELIVERABLE only if the workflow file exists on the repo
    # DEFAULT branch (GitHub's registration rule) — `--ref $AUTH_BRANCH` selects the
    # ref to RUN but does not remove that requirement. The default branch carries a
    # non-executable REGISTRATION SHIM (distinct run-name, no Environment/secret); the
    # EXECUTABLE workflow lives on $AUTH_BRANCH and is byte-verified at trust-deploy.
    # We require the path on BOTH branches, but do NOT require them byte-equal.
    local default_branch
    default_branch="$(gh repo view "$slug" --json defaultBranchRef --jq '.defaultBranchRef.name' 2>/dev/null || true)"
    [ -n "$default_branch" ] || die "preflight: cannot determine the default branch of $slug"
    remote_has_path "$slug" "$default_branch" ".github/workflows/$SMOKE_WORKFLOW" ||
      die "$SMOKE_WORKFLOW is not registered on the default branch $slug@$default_branch — GitHub cannot dispatch it (add the one-file registration shim to the default branch)"
    remote_has_path "$slug" "$AUTH_BRANCH" ".github/workflows/$SMOKE_WORKFLOW" ||
      die "$SMOKE_WORKFLOW (executable) not present on $slug@$AUTH_BRANCH — install it before rotating"
    audit_github "$DOMAIN" >/dev/null || die "authority-domain GitHub preconditions failed (run: audit)"
  fi
}

ph_prepare() {
  phase_done prepare && return 0
  local pem="$STATE_DIR/new-key.pem" pub="$STATE_DIR/new-key.pub" b64 len
  (umask 077 && bash "$SIGNING_DIR/keygen.sh" --out-private "$pem" --out-public-base64 "$pub" --key-id "$NEW" >/dev/null) ||
    die "keygen failed"
  chmod 600 "$pem" || die "chmod key failed"
  b64="$(cat "$pub")" || die "cannot read generated public key"
  len="$(printf '%s' "$b64" | base64 -d 2>/dev/null | wc -c | tr -d ' ')"
  [ "$len" = 32 ] || die "generated public key is $len bytes, expected 32 (ed25519)"
  sset pub_key_b64 "$b64"
  log "prepare: generated $NEW (public key validated); private PEM in protected state dir"
  mark_phase prepare
}

edit_trust_store() { # path → add NEW active, set OLD status; fail closed, verify BOTH keys
  local ts="$1" tmp b64 os
  b64="$(sget pub_key_b64)"
  [ -n "$b64" ] || die "trust: no prepared public key"
  os="$(sget old_status)"
  [ -n "$os" ] || die "trust: no expected old-key status in state"
  tmp="$ts.tmp"
  jq --arg new "$NEW" --arg old "$OLD" --arg pub "$b64" --arg os "$os" '
    .keys[$new] = {profile:"ed25519-detached-v1", public_key_base64:$pub, status:"active"}
    | (if .keys[$old] then .keys[$old].status=$os else . end)' "$ts" >"$tmp" || die "trust edit failed for $ts"
  mv "$tmp" "$ts" || die "trust rename failed for $ts"
  # verify BOTH transitions landed
  jq -e --arg n "$NEW" --arg o "$OLD" --arg p "$b64" --arg os "$os" \
    '.keys[$n].status=="active" and .keys[$n].public_key_base64==$p and .keys[$o].status==$os' \
    "$ts" >/dev/null || die "trust store $ts did not reach the expected state ($NEW active, $OLD $os)"
}

ph_trust_prepare() {
  phase_done trust-prepare && return 0
  local os
  os="$(sget old_status)"
  edit_trust_store "$REPO_ROOT/release-trusted-keys.json"
  git -C "$REPO_ROOT" add release-trusted-keys.json || die "trust-prepare: git add failed"
  mark_phase trust-prepare
  cat >&2 <<EOF
authority-domains: TRUST-PREPARE done — trust changes staged (NEW $NEW active, OLD $OLD $os).
  NEXT (human): review, commit, and MERGE the producer trust store to the '$AUTH_BRANCH' branch:
    - $(repo_slug)@$AUTH_BRANCH : release-trusted-keys.json
  Then resume:  authority-domains.sh resume $RID
EOF
  exit 0
}

ph_trust_deploy() {
  phase_done trust-deploy && return 0
  local slug="$1" b64 os path verified_sha content
  b64="$(sget pub_key_b64)"
  os="$(sget old_status)"
  [ -n "$os" ] || die "trust-deploy: no expected old-key status in state"
  # v1.5.0 producer-only. NO TOCTOU: read the branch tip SHA FIRST, then verify the
  # content AT that exact SHA (never at the branch name, which could move).
  path="$(trust_targets_json | jq -r '.[0].path')"
  verified_sha="$(gh api "repos/$slug/commits/$AUTH_BRANCH" --jq '.sha' 2>/dev/null || true)"
  [ -n "$verified_sha" ] || die "trust-deploy: cannot read $slug@$AUTH_BRANCH tip commit"
  content="$(remote_file "$slug" "$verified_sha" "$path")" ||
    die "trust-deploy: cannot read $slug@$verified_sha:$path — commit the trust change to $AUTH_BRANCH, then resume"
  # BOTH sides must hold: NEW active + exact bytes, AND OLD demoted to $os (rejects both-active).
  printf '%s' "$content" | jq -e --arg n "$NEW" --arg o "$OLD" --arg p "$b64" --arg os "$os" \
    '.keys[$n].status=="active" and .keys[$n].public_key_base64==$p and (.keys[$o].status // "absent")==$os' >/dev/null 2>&1 ||
    die "trust-deploy: $slug@$verified_sha:$path must pin $NEW active (exact bytes) AND $OLD as $os — commit/merge it, then resume"
  sset trust_verified_sha "$verified_sha"
  log "trust-deploy: verified $NEW active + $OLD $os at $slug@$AUTH_BRANCH commit $verified_sha"
  mark_phase trust-deploy
}

ph_store() {
  phase_done store && return 0
  local pem="$STATE_DIR/new-key.pem"
  if [ "${AD_ASSUME_STORE_DONE:-0}" != 1 ]; then
    cat >&2 <<EOF

authority-domains: STORE checkpoint (manual, web vault — the CLI takes VALUE positionally, unsafe for a PEM)
  Open Bitwarden → Secrets Manager → project '$AUTH_PROJECT' → edit secret '$AUTH_SECRET'.
  Replace its VALUE with the new private PEM WITHOUT printing it, e.g.:
        pbcopy < "$pem"        # macOS   (Linux: wl-copy / xclip -sel clip)
  Keep the SAME secret (same UUID); rotation replaces only the value. Save.
EOF
    printf '  Type "updated" once the vault value is the new PEM: ' >&2
    local ans
    read -r ans </dev/tty || true
    [ "$ans" = updated ] || die "store: not confirmed — re-run to resume after updating the vault value"
  fi
  mark_phase store
  log "store: vault value update confirmed (smoke will prove it)"
}

# Fetch one Actions run via the REST API (authoritative fields: path, event,
# display_title, head_branch, head_sha, status, conclusion). Do NOT use
# run.workflowName as a proof field — when the workflow is registered on the
# default branch as a shim but executed from AUTH_BRANCH, GitHub reports the
# shim's YAML `name:` as workflowName.
smoke_fetch_run() { # $1=slug $2=run_id → JSON on stdout
  local slug="$1" rid="$2" out
  out="$(gh api "repos/$slug/actions/runs/$rid" 2>/dev/null)" || return 1
  [ -n "$out" ] || return 1
  printf '%s' "$out"
}

# Require a completed successful job named sign-verify on the given run.
smoke_require_sign_verify_job() { # $1=slug $2=run_id
  local slug="$1" rid="$2" jobs job_ok
  jobs="$(gh api "repos/$slug/actions/runs/$rid/jobs" 2>/dev/null)" ||
    die "smoke: cannot list jobs for run $rid"
  [ -n "$jobs" ] || die "smoke: empty jobs response for run $rid (fail closed)"
  job_ok="$(printf '%s' "$jobs" | jq -r '
    [.jobs[]?
      | select(.name == "sign-verify"
          and .status == "completed"
          and .conclusion == "success")]
    | length
  ' 2>/dev/null || echo 0)"
  [ "$job_ok" = "1" ] || {
    local names
    names="$(printf '%s' "$jobs" | jq -r '
      [.jobs[]? | "\(.name):\(.status)/\(.conclusion // "null")"] | join(", ")
    ' 2>/dev/null || echo none)"
    die "smoke: run $rid has no completed successful job named sign-verify (jobs: $names)"
  }
}

# Validate the exact run against authoritative REST fields + sign-verify job.
# $1=slug $2=run_id $3=correlation $4=verified_sha
smoke_validate_run() {
  local slug="$1" rid="$2" corr="$3" verified_sha="$4"
  local run path event title branch sha status conclusion v
  local expect_path=".github/workflows/$SMOKE_WORKFLOW"
  run="$(smoke_fetch_run "$slug" "$rid")" || die "smoke: cannot fetch Actions run $rid via REST"
  path="$(printf '%s' "$run" | jq -r '.path // empty')"
  event="$(printf '%s' "$run" | jq -r '.event // empty')"
  title="$(printf '%s' "$run" | jq -r '.display_title // empty')"
  branch="$(printf '%s' "$run" | jq -r '.head_branch // empty')"
  sha="$(printf '%s' "$run" | jq -r '.head_sha // empty')"
  status="$(printf '%s' "$run" | jq -r '.status // empty')"
  conclusion="$(printf '%s' "$run" | jq -r '.conclusion // empty')"
  for v in "$path" "$event" "$title" "$branch" "$sha" "$status" "$conclusion"; do
    [ -n "$v" ] || die "smoke: run $rid REST metadata field empty (fail closed)"
  done
  [ "$path" = "$expect_path" ] ||
    die "smoke: run $rid workflow path '$path' != '$expect_path'"
  [ "$event" = workflow_dispatch ] ||
    die "smoke: run $rid event '$event' != workflow_dispatch"
  [ "$title" = "$corr" ] ||
    die "smoke: run $rid display_title '$title' != $corr"
  [ "$branch" = "$AUTH_BRANCH" ] ||
    die "smoke: run $rid head_branch '$branch' != $AUTH_BRANCH"
  [ "$sha" = "$verified_sha" ] ||
    die "smoke: run $rid head_sha '$sha' != verified trust commit $verified_sha"
  [ "$status" = completed ] ||
    die "smoke: run $rid status '$status' != completed"
  [ "$conclusion" = success ] ||
    die "smoke: run $rid conclusion '$conclusion' (not success)"
  smoke_require_sign_verify_job "$slug" "$rid"
}

ph_smoke() {
  phase_done smoke && return 0
  require_tools gh
  local slug="$1" corr="authority-smoke:$RID:$NEW" tries=0
  local verified_sha rid_run
  verified_sha="$(sget trust_verified_sha)"
  [ -n "$verified_sha" ] || die "smoke: no verified trust commit SHA (trust-deploy must run first)"
  # Bind the proof to EXACT reviewed bytes: the remote smoke workflow at the verified
  # trust commit must be byte-identical to the locally installed (rendered+actionlint'd)
  # workflow, so a no-op sign step can't masquerade as a successful proof.
  local local_wf="$REPO_ROOT/.github/workflows/$SMOKE_WORKFLOW" remote_wf
  [ -f "$local_wf" ] || die "smoke: local smoke workflow missing — run install-smoke-workflow"
  remote_wf="$(remote_file "$slug" "$verified_sha" ".github/workflows/$SMOKE_WORKFLOW")" ||
    die "smoke: cannot read the remote smoke workflow at $verified_sha"
  [ "$(cat "$local_wf")" = "$remote_wf" ] ||
    die "smoke: remote smoke workflow at $verified_sha differs from the installed (reviewed) workflow — refusing"
  rid_run="$(sget smoke_run_id)"
  if [ -z "$rid_run" ]; then
    # correlate: snapshot existing run IDs, dispatch with the opaque rotation id +
    # expected new key, then find the NEW run whose title == our correlation value.
    local before after new_ids
    before="$(gh run list --repo "$slug" --workflow "$SMOKE_WORKFLOW" --json databaseId 2>/dev/null | jq -c '[.[].databaseId // empty]' 2>/dev/null || echo '[]')"
    [ -n "$before" ] || before='[]'
    log "smoke: dispatching $SMOKE_WORKFLOW on $slug@$AUTH_BRANCH (rotation_id=$RID new_key_id=$NEW)"
    gh workflow run "$SMOKE_WORKFLOW" --repo "$slug" --ref "$AUTH_BRANCH" \
      -f rotation_id="$RID" -f new_key_id="$NEW" || die "smoke: dispatch failed"
    while [ "$tries" -lt 60 ]; do
      after="$(gh run list --repo "$slug" --workflow "$SMOKE_WORKFLOW" \
        --json databaseId,displayTitle,event,headBranch,headSha 2>/dev/null || echo '[]')"
      # a NEW run, correlated title, workflow_dispatch, on the branch, at the verified SHA
      new_ids="$(printf '%s' "$after" | jq -c --argjson b "$before" --arg t "$corr" --arg br "$AUTH_BRANCH" --arg sha "$verified_sha" \
        '[.[] | select((.databaseId as $i | ($b | index($i)) | not) and .displayTitle==$t and .event=="workflow_dispatch" and .headBranch==$br and .headSha==$sha) | .databaseId]' 2>/dev/null || echo '[]')"
      case "$(printf '%s' "$new_ids" | jq 'length')" in
        1)
          rid_run="$(printf '%s' "$new_ids" | jq -r '.[0]')"
          break
          ;;
        0) : ;;
        *) die "smoke: ambiguous correlation — multiple runs match $corr" ;;
      esac
      tries=$((tries + 1))
      sleep "${AD_POLL_SLEEP:-5}"
    done
    [ -n "$rid_run" ] || die "smoke: no run correlated to $corr at $verified_sha appeared"
    sset smoke_run_id "$rid_run"
  else
    log "smoke: resuming — revalidating recorded run $rid_run (no re-dispatch)"
  fi
  # Poll the EXACT run via Actions REST until completed (or timeout). Never use
  # workflowName equality — path + event + title + branch + sha + jobs are proof.
  local st=""
  tries=0
  while [ "$tries" -lt 120 ]; do
    st="$(smoke_fetch_run "$slug" "$rid_run" | jq -r '.status // empty' 2>/dev/null || true)"
    [ "$st" = completed ] && break
    tries=$((tries + 1))
    sleep "${AD_POLL_SLEEP:-5}"
  done
  [ "$st" = completed ] || die "smoke: run $rid_run did not complete"
  # Revalidate the FULL exact identity on EVERY path (fresh find OR resume).
  smoke_validate_run "$slug" "$rid_run" "$corr" "$verified_sha"
  log "smoke: correlated run $rid_run ($corr) succeeded at $verified_sha — the BWS key matches the committed $NEW public key"
  mark_phase smoke
}

ph_activate_prepare() {
  phase_done activate-prepare && return 0
  local rel="$REPO_ROOT/release.yml"
  [ -f "$rel" ] || die "activate: release.yml not found"
  yq -i ".candidate.signing.key_id = \"$NEW\"" "$rel" || die "activate: could not set key_id"
  [ "$(yq -r '.candidate.signing.key_id' "$rel")" = "$NEW" ] || die "activate: key_id did not update"
  git -C "$REPO_ROOT" add release.yml || die "activate-prepare: git add release.yml failed"
  mark_phase activate-prepare
  cat >&2 <<EOF
authority-domains: ACTIVATE-PREPARE done — release.yml key_id staged as $NEW.
  NEXT (human): review, commit, and MERGE it to '$AUTH_BRANCH'. Then resume:
    authority-domains.sh resume $RID
EOF
  exit 0
}

ph_activate_deploy() {
  phase_done activate-deploy && return 0
  local slug="$1" sha content b64 os trust
  b64="$(sget pub_key_b64)"
  os="$(sget old_status)"
  [ -n "$os" ] || die "activate-deploy: no expected old-key status in state"
  # NO TOCTOU: tip SHA FIRST, then verify BOTH files AT that exact commit.
  sha="$(gh api "repos/$slug/commits/$AUTH_BRANCH" --jq '.sha' 2>/dev/null || true)"
  [ -n "$sha" ] || die "activate-deploy: cannot read $slug@$AUTH_BRANCH tip commit"
  content="$(remote_file "$slug" "$sha" release.yml)" ||
    die "activate-deploy: cannot read $slug@$sha:release.yml — commit the change to $AUTH_BRANCH, then resume"
  printf '%s' "$content" | yq -e ".candidate.signing.key_id == \"$NEW\"" >/dev/null 2>&1 ||
    die "activate-deploy: $slug@$sha release.yml key_id is not yet $NEW — commit/merge it, then resume"
  # RE-VERIFY the trust store at the SAME activation commit (a later commit could
  # have restored the old key to active or altered the new key).
  trust="$(remote_file "$slug" "$sha" release-trusted-keys.json)" ||
    die "activate-deploy: cannot read $slug@$sha:release-trusted-keys.json"
  printf '%s' "$trust" | jq -e --arg n "$NEW" --arg o "$OLD" --arg p "$b64" --arg os "$os" \
    '.keys[$n].status=="active" and .keys[$n].public_key_base64==$p and (.keys[$o].status // "absent")==$os' >/dev/null 2>&1 ||
    die "activate-deploy: trust store at $slug@$sha no longer pins $NEW active (exact bytes) + $OLD $os — refusing to finalize"
  sset activation_verified_sha "$sha"
  log "activate-deploy: release.yml=$NEW AND trust store ($NEW active, $OLD $os) verified at $slug@$AUTH_BRANCH commit $sha"
  mark_phase activate-deploy
}

ph_finalize() {
  phase_done finalize && return 0
  local leaks pem="$STATE_DIR/new-key.pem"
  leaks="$(scan_secret_markers || true)"
  [ -z "$leaks" ] || die "finalize: refusing — secret markers found (worktree AND/OR staged index):
$leaks"
  # secure-remove the local private key, then ASSERT it is gone (do not print COMPLETE if not)
  if [ -f "$pem" ]; then
    if have shred; then shred -u "$pem" 2>/dev/null || true; elif rm -P "$pem" 2>/dev/null; then :; else rm -f "$pem" 2>/dev/null || true; fi
  fi
  [ ! -e "$pem" ] || die "finalize: FAILED to remove the local private key $pem — rotation NOT complete"
  local ev="$STATE_DIR/rotation-evidence.json"
  jq '. + {finalized:true}' "$STATE_FILE" >"$ev" || die "finalize: evidence write failed"
  chmod 600 "$ev" || die "finalize: chmod evidence failed"
  mark_phase finalize
  cat >&2 <<EOF
authority-domains: rotation $OLD → $NEW COMPLETE (reason=$REASON). Evidence: $ev
  Local private key removed (it is in BWS; the public key is committed). The rotation
  is fully deployed and remotely verified — no further review actions.
EOF
}

# ── audit (partial GitHub-side; full auditor incl. BWS matrix = #197) ────────────
audit_github() {
  local domain="$1" slug rc=0 pols repo_secrets extra
  discover_domain "$domain"
  slug="$(repo_slug)"
  have gh || {
    log "audit: gh unavailable"
    return 1
  }
  gh api "repos/$slug/environments/$AUTH_ENV" >/dev/null 2>&1 || {
    log "audit FAIL: environment $AUTH_ENV missing"
    rc=1
  }
  pols="$(gh api "repos/$slug/environments/$AUTH_ENV/deployment-branch-policies" --jq '.branch_policies[] | .name+":"+.type' 2>/dev/null || true)"
  [ "$pols" = "$AUTH_BRANCH:branch" ] || {
    log "audit FAIL: $AUTH_ENV branch policy '$pols' (want $AUTH_BRANCH:branch)"
    rc=1
  }
  gh secret list --env "$AUTH_ENV" --repo "$slug" 2>/dev/null | awk '{print $1}' | grep -qx BWS_ACCESS_TOKEN || {
    log "audit FAIL: $AUTH_ENV has no BWS_ACCESS_TOKEN env secret"
    rc=1
  }
  repo_secrets="$(gh secret list --repo "$slug" 2>/dev/null | awk '{print $1}')"
  echo "$repo_secrets" | grep -qx BWS_ACCESS_TOKEN || {
    log "audit FAIL: repo-level BWS_ACCESS_TOKEN missing"
    rc=1
  }
  extra="$(echo "$repo_secrets" | grep -v '^BWS_ACCESS_TOKEN$' || true)"
  [ -z "$extra" ] || log "audit WARN: extra repo-level secrets (want only BWS_ACCESS_TOKEN): $(echo "$extra" | tr '\n' ' ')"
  return "$rc"
}

# ════════════════════════════════════════════════════════════════════════════════
# commands
# ════════════════════════════════════════════════════════════════════════════════
DOMAIN="release-signing" OLD="" NEW="" REASON=""
cmd_rotate() {
  local resume_id="" plan_only=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --old-key-id)
        OLD="${2:-}"
        shift 2
        ;;
      --new-key-id)
        NEW="${2:-}"
        shift 2
        ;;
      --reason)
        REASON="${2:-}"
        shift 2
        ;;
      --domain)
        DOMAIN="${2:-}"
        shift 2
        ;;
      --resume)
        resume_id="${2:-}"
        shift 2
        ;;
      --plan-only)
        plan_only=1
        shift
        ;;
      *) die "rotate: unexpected arg: $1" ;;
    esac
  done
  require_tools git jq yq openssl
  [ -f "$SIGNING_DIR/keygen.sh" ] || die "signing category not found at $SIGNING_DIR"
  local slug
  slug="$(repo_slug)"
  [ -n "$slug" ] || die "cannot determine repo slug (git remote origin)"

  if [ -n "$resume_id" ]; then
    [ "$plan_only" = 1 ] && die "plan does not take --resume"
    state_open_existing "$resume_id"
    OLD="$(sget old_key_id)" NEW="$(sget new_key_id)" REASON="$(sget reason)" DOMAIN="$(sget domain)"
    { [ -n "$OLD" ] && [ -n "$NEW" ] && [ -n "$REASON" ]; } || die "resume: state '$resume_id' incomplete"
    log "resuming $resume_id ($OLD → $NEW, $REASON)"
  else
    [ -n "$OLD" ] || die "--old-key-id required"
    [ -n "$NEW" ] || die "--new-key-id required"
    [ "$OLD" != "$NEW" ] || die "old and new key_id must differ (never reuse a key_id)"
    case "$REASON" in scheduled | compromised) ;; *) die "--reason must be scheduled|compromised" ;; esac
    valid_key_id "$OLD" || die "old key_id '$OLD' violates key-id grammar"
    valid_key_id "$NEW" || die "new key_id '$NEW' violates key-id grammar"
    # PLAN is genuinely read-only: preflight only, no rotation state created.
    if [ "$plan_only" = 1 ]; then
      ph_preflight "$slug"
      log "plan: preflight OK; created no rotation state"
      return 0
    fi
    # find-or-continue (idempotent). An existing rotation is IMMUTABLE: the
    # invocation must match old/new/reason/domain exactly, or the operator must
    # resume the recorded id.
    local existing
    existing="$(find_rotation "$OLD" "$NEW" "$DOMAIN")"
    if [ -n "$existing" ]; then
      state_open_existing "$existing"
      { [ "$(sget old_key_id)" = "$OLD" ] && [ "$(sget new_key_id)" = "$NEW" ] &&
        [ "$(sget reason)" = "$REASON" ] && [ "$(sget domain)" = "$DOMAIN" ]; } ||
        die "rotation $existing already in progress with different parameters (reason=$(sget reason)) — resume it: authority-domains.sh resume $existing"
      log "continuing existing rotation $existing"
    else
      local os
      case "$REASON" in compromised) os=revoked ;; scheduled) os=verify-only ;; esac
      discover_domain "$DOMAIN"
      state_create_new "$(new_rotation_id)"
      sset old_key_id "$OLD"
      sset new_key_id "$NEW"
      sset reason "$REASON"
      sset domain "$DOMAIN"
      sset old_status "$os"
      # Anchor the history secret-scan: finalize scans every blob introduced since
      # this commit (a PEM briefly committed then deleted still lives in history).
      sset start_commit "$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || echo '')"
      # v1.5.0 scope: producer trust store only (multi-repo distribution → #198).
      # shellcheck disable=SC2016
      sput --argjson tt '[{"repo":"self","ref":"'"$AUTH_BRANCH"'","path":"release-trusted-keys.json"}]' '.trust_targets=$tt'
      log "started rotation $RID ($OLD → $NEW, $REASON; old → $os)"
    fi
  fi

  ph_preflight "$slug"
  ph_prepare
  ph_trust_prepare "$slug"
  ph_trust_deploy "$slug"
  ph_store
  ph_smoke "$slug"
  ph_activate_prepare
  ph_activate_deploy "$slug"
  ph_finalize
}

cmd_plan() { cmd_rotate "$@" --plan-only; } # read-only: --plan-only creates no state

cmd_install_smoke() { # render the smoke workflow from blessed.yml (generic secret name)
  local force=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --force)
        force=1
        shift
        ;;
      --domain)
        DOMAIN="${2:-}"
        shift 2
        ;;
      *) die "install-smoke-workflow: unexpected arg: $1" ;;
    esac
  done
  require_tools yq sed
  discover_domain "$DOMAIN"
  local tmpl="$HERE/templates/authority-domain-smoke.yml.tmpl"
  [ -f "$tmpl" ] || die "install-smoke-workflow: template not found: $tmpl"
  local out="$REPO_ROOT/.github/workflows/$SMOKE_WORKFLOW" rendered
  rendered="$(sed -e "s#@@ENV@@#$AUTH_ENV#g" -e "s#@@BRANCH@@#$AUTH_BRANCH#g" \
    -e "s#@@SECRET@@#$AUTH_SECRET#g" -e "s#@@PROFILE@@#$DOMAIN#g" "$tmpl")" || die "render failed"
  printf '%s' "$rendered" | grep -q '@@' && die "install-smoke-workflow: an unrendered @@placeholder@@ remains"
  printf '%s' "$rendered" | yq -e . >/dev/null 2>&1 || die "install-smoke-workflow: rendered workflow is not valid YAML"
  if [ -f "$out" ] && [ "$force" != 1 ]; then
    if diff -q <(printf '%s\n' "$rendered") "$out" >/dev/null 2>&1; then
      log "install-smoke-workflow: $out already up to date"
      return 0
    fi
    die "install-smoke-workflow: $out exists and differs — pass --force to overwrite"
  fi
  mkdir -p "$(dirname "$out")" || die "install-smoke-workflow: mkdir failed"
  printf '%s\n' "$rendered" >"$out.tmp" || die "install-smoke-workflow: write failed"
  if [ "${AD_SKIP_ACTIONLINT:-0}" != 1 ]; then
    have actionlint || {
      rm -f "$out.tmp"
      die "install-smoke-workflow: actionlint is required (install it, or AD_SKIP_ACTIONLINT=1 for tests)"
    }
    actionlint "$out.tmp" >/dev/null 2>&1 || {
      rm -f "$out.tmp"
      die "install-smoke-workflow: rendered workflow failed actionlint"
    }
  fi
  mv "$out.tmp" "$out" || die "install-smoke-workflow: rename failed"
  git -C "$REPO_ROOT" add "$out" || die "install-smoke-workflow: git add failed"
  log "install-smoke-workflow: wrote $out (env=$AUTH_ENV secret=$AUTH_SECRET branch=$AUTH_BRANCH)"
}

cmd_audit() {
  local domain="${1:-release-signing}"
  require_tools yq git
  if audit_github "$domain"; then log "audit: GitHub-side conformance PASS for $domain (BWS access matrix → #197)"; else die "audit: GitHub-side conformance FAILED for $domain"; fi
}

usage() {
  cat >&2 <<'EOF'
Usage: authority-domains.sh <command>
  plan                 --old-key-id ID --new-key-id ID --reason scheduled|compromised   (read-only)
  rotate-signing-key   --old-key-id ID --new-key-id ID --reason scheduled|compromised
                       [--domain release-signing]
  install-smoke-workflow [--force]   render authority-domain-smoke.yml from blessed.yml
  audit                [domain]
  resume <rotation-id>
Rotation stops for you to commit/merge trust + activation to the release branch, and
verifies the remote ref before continuing. See standards/secrets/bwsm-authority-domains.md.
EOF
  exit 2
}

main() {
  local cmd="${1:-}"
  [ -n "$cmd" ] || usage
  shift || true
  case "$cmd" in
    plan) cmd_plan "$@" ;;
    install-smoke-workflow) cmd_install_smoke "$@" ;;
    rotate-signing-key) cmd_rotate "$@" ;;
    audit) cmd_audit "$@" ;;
    resume)
      [ -n "${1:-}" ] || die "resume: rotation-id required"
      cmd_rotate --resume "$1"
      ;;
    provision) die "provision: guided provisioning is not yet automated (see #198); this tool automates rotation" ;;
    -h | --help) usage ;;
    *) die "unknown command: $cmd" ;;
  esac
}
main "$@"
