#!/usr/bin/env bash
# authority-domains-test.sh — exercise the checkpoint rotation transaction against a
# fixture repo + a STATEFUL fake GitHub that models correlated smoke runs and the
# release branch. Covers: plan-no-state (+plan-then-rotate executes), key-id grammar/
# traversal, reuse/precondition guards, the 3-stage happy path with remote checkpoint
# verification, trust-deploy / activate-deploy blocking, correlated smoke-run success
# (and a failed run blocking), both-keys trust verification (both-active rejected),
# rotation immutability (reason mismatch), resume-id path safety, staged-INDEX secret
# refusal, no-secret-in-state, and generic install-smoke-workflow rendering.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOL="$HERE/authority-domains.sh"
SIGNING="$HERE/../signing"

pass=0 fail=0
ok() {
  echo "  ✓ $1"
  pass=$((pass + 1))
}
no() {
  echo "  ✗ $1"
  fail=1
}
expect_rc() {
  local desc="$1" want="$2" rc
  shift 2
  "$@" >/dev/null 2>&1
  rc=$?
  if [ "$rc" -eq "$want" ]; then ok "$desc"; else no "$desc (rc=$rc want $want)"; fi
}
for t in jq yq git openssl base64; do command -v "$t" >/dev/null 2>&1 || {
  echo "authority-domains-test: $t required" >&2
  exit 1
}; done

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT INT TERM HUP
MOCKBIN="$T/mockbin"
mkdir -p "$MOCKBIN"
LOADER_UUID="d6deabc9-9199-4745-8bf8-b48d0043e41f"

# ── stateful fake gh: release branch under $AD_REMOTE/release/, plus a correlated
#    smoke run written on `workflow run` and read back by `run list` + Actions REST. ──
cat >"$MOCKBIN/gh" <<'MOCK'
#!/usr/bin/env bash
set -uo pipefail
verb="${1:-}"; shift || true
case "$verb" in
  api)
    path="${1:-}"; shift || true
    jqf=""; while [ $# -gt 0 ]; do case "$1" in --jq) jqf="$2"; shift 2 ;; *) shift ;; esac; done
    emit() { if [ -n "$jqf" ]; then printf '%s' "$1" | jq -r "$jqf"; else printf '%s' "$1"; fi; }
    case "$path" in
      *"/commits/"*) emit "$(jq -n --arg s "$(cat "$AD_REMOTE/release_sha" 2>/dev/null || echo deadbeef)" '{sha:$s}')" ;;
      *"/contents/"*)
        p="${path#*/contents/}"; file="${p%%\?*}"; ref="main"
        case "$p" in *ref=*) ref="${p#*ref=}" ;; esac
        case "$ref" in
          release | main) rf="$AD_REMOTE/$ref/$file" ;;
          *) if [ -f "$AD_REMOTE/bysha/$ref/$file" ]; then rf="$AD_REMOTE/bysha/$ref/$file"; else rf="$AD_REMOTE/release/$file"; fi ;;
        esac
        [ -f "$rf" ] || { echo "404" >&2; exit 1; }
        emit "$(jq -n --arg c "$(base64 <"$rf" | tr -d '\n')" '{content:$c}')" ;;
      *"/deployment-branch-policies") emit '{"branch_policies":[{"name":"release","type":"branch"}]}' ;;
      *"/environments/"*) emit '{}' ;;
      # Actions REST: GET /repos/{owner}/{repo}/actions/runs/{id}/jobs
      *"/actions/runs/"*"/jobs"*)
        if [ -f "$AD_REMOTE/jobs.json" ]; then
          emit "$(cat "$AD_REMOTE/jobs.json")"
        else
          jc="$(cat "$AD_REMOTE/job_conclusion" 2>/dev/null || echo success)"
          js="$(cat "$AD_REMOTE/job_status" 2>/dev/null || echo completed)"
          jn="$(cat "$AD_REMOTE/job_name" 2>/dev/null || echo sign-verify)"
          emit "$(jq -n --arg n "$jn" --arg st "$js" --arg cc "$jc" \
            '{jobs:[{name:$n, status:$st, conclusion:$cc}]}')"
        fi ;;
      # Actions REST: GET /repos/{owner}/{repo}/actions/runs/{id}
      *"/actions/runs/"*)
        if [ -f "$AD_REMOTE/run.json" ]; then
          base="$(cat "$AD_REMOTE/run.json")"
          rpath="$(cat "$AD_REMOTE/run_path" 2>/dev/null || echo .github/workflows/authority-domain-smoke.yml)"
          rst="$(cat "$AD_REMOTE/run_status" 2>/dev/null || echo completed)"
          rcc="$(cat "$AD_REMOTE/run_conclusion" 2>/dev/null || echo success)"
          rev="$(cat "$AD_REMOTE/run_event" 2>/dev/null || echo workflow_dispatch)"
          rbr="$(cat "$AD_REMOTE/run_branch" 2>/dev/null || echo release)"
          emit "$(printf '%s' "$base" | jq -c \
            --arg path "$rpath" --arg st "$rst" --arg cc "$rcc" --arg ev "$rev" --arg br "$rbr" '
              {
                id: (.databaseId // 778899),
                path: $path,
                event: (if $ev == "" then (.event // "workflow_dispatch") else $ev end),
                display_title: (.displayTitle // .display_title // empty),
                head_branch: (if $br == "" then (.headBranch // .head_branch // "release") else $br end),
                head_sha: (.headSha // .head_sha // empty),
                status: $st,
                conclusion: $cc,
                workflowName: (.workflowName // "registration-shim-name")
              }
            ')"
        else
          echo "404" >&2
          exit 1
        fi ;;
      *) exit 1 ;;
    esac ;;
  secret) echo "BWS_ACCESS_TOKEN" ;;
  repo)
    jqf=""; while [ $# -gt 0 ]; do case "$1" in --jq) jqf="$2"; shift 2 ;; *) shift ;; esac; done
    out="$(jq -n --arg b "$(cat "$AD_REMOTE/default_branch" 2>/dev/null || echo main)" '{defaultBranchRef:{name:$b}}')"
    if [ -n "$jqf" ]; then printf '%s' "$out" | jq -r "$jqf"; else printf '%s' "$out"; fi ;;
  workflow)
    # Count dispatches so resume tests can prove no re-dispatch.
    n="$(cat "$AD_REMOTE/dispatch_count" 2>/dev/null || echo 0)"
    echo $((n + 1)) >"$AD_REMOTE/dispatch_count"
    rid=""; nk=""
    while [ $# -gt 0 ]; do case "$1" in -f) case "$2" in rotation_id=*) rid="${2#*=}" ;; new_key_id=*) nk="${2#*=}" ;; esac; shift 2 ;; *) shift ;; esac; done
    # workflowName deliberately differs from the executable YAML name (shim case).
    jq -n --arg t "$(cat "$AD_REMOTE/run_title_prefix" 2>/dev/null || echo authority-smoke):$rid:$nk" \
      --arg sha "$(cat "$AD_REMOTE/run_headsha" 2>/dev/null || cat "$AD_REMOTE/release_sha" 2>/dev/null || echo deadbeef)" \
      --arg wf "$(cat "$AD_REMOTE/wf_name" 2>/dev/null || echo '🔏 Authority domain smoke (registration shim)')" \
      --arg ev "$(cat "$AD_REMOTE/run_event" 2>/dev/null || echo workflow_dispatch)" \
      --arg br "$(cat "$AD_REMOTE/run_branch" 2>/dev/null || echo release)" \
      '{databaseId:778899, displayTitle:$t, event:$ev, headBranch:$br, headSha:$sha, workflowName:$wf}' >"$AD_REMOTE/run.json"
    exit 0 ;;
  run)
    sub="${1:-}"; shift || true
    jqf=""; while [ $# -gt 0 ]; do case "$1" in --json) shift 2 ;; --jq) jqf="$2"; shift 2 ;; *) shift ;; esac; done
    case "$sub" in
      list)
        if [ -f "$AD_REMOTE/run.json" ]; then arr="[$(cat "$AD_REMOTE/run.json")]"; else arr='[]'; fi
        if [ -n "$jqf" ]; then printf '%s' "$arr" | jq -r "$jqf"; else printf '%s' "$arr"; fi ;;
      view)
        run="$(cat "$AD_REMOTE/run.json" 2>/dev/null || echo '{}')"
        run="$(printf '%s' "$run" | jq --arg cc "$(cat "$AD_REMOTE/run_conclusion" 2>/dev/null || echo success)" --arg st "$(cat "$AD_REMOTE/run_status" 2>/dev/null || echo completed)" '.conclusion=$cc | .status=$st')"
        if [ -n "$jqf" ]; then printf '%s' "$run" | jq -r "$jqf"; else printf '%s' "$run"; fi ;;
    esac ;;
  *) exit 1 ;;
esac
MOCK
chmod +x "$MOCKBIN/gh"

SMOKE_WF='name: smoke
on: {workflow_dispatch: {inputs: {rotation_id: {required: true}, new_key_id: {required: true}}}}
jobs: {v: {runs-on: ubuntu-latest, steps: [{run: "true"}]}}
'
mk_repo() { # $1 dir [$2 old status] [$3 loader uuid]
  local D="$1" st="${2:-active}" uuid="${3:-$LOADER_UUID}"
  rm -rf "$D"
  mkdir -p "$D/.github/actions/load-secrets" "$D/.github/workflows"
  git -C "$D" init -q
  git -C "$D" config user.email t@t
  git -C "$D" config user.name t
  git -C "$D" remote add origin https://github.com/JonathanPorta/docsort.git
  # The harness parks rotation state at $REPO/.state (production uses ~/.cache); a
  # consumer would gitignore its local cache. Ignore it so `git add -A` never commits
  # the protected new-key.pem — otherwise the history scan (correctly) flags it.
  printf '.state/\n' >"$D/.gitignore"
  cat >"$D/blessed.yml" <<'YML'
schema: blessed/repo/v1
secret_authorities:
  release-signing:
    github_environment: release-signing
    bwsm_project: docsort-release-signing
    machine_account: docsort-release-signer
    allowed_refs: {branches: [release]}
    injects: [DOCSORT_RELEASE_SIGNING_KEY]
YML
  printf 'candidate:\n  signing:\n    key_id: docsort-2026-01\n    profile: ed25519-detached-v1\n' >"$D/release.yml"
  jq -n --arg s "$st" '{schema:"blessed/signing-trust-store/v1",keys:{"docsort-2026-01":{profile:"ed25519-detached-v1",public_key_base64:"AAAA",status:$s}}}' >"$D/release-trusted-keys.json"
  printf 'name: x\nruns:\n  using: composite\n  steps:\n    - uses: bitwarden/sm-action@x\n      with:\n        secrets: |\n          %s > DOCSORT_RELEASE_SIGNING_KEY\n' "$uuid" >"$D/.github/actions/load-secrets/action.yml"
  printf '%s' "$SMOKE_WF" >"$D/.github/workflows/authority-domain-smoke.yml"
  git -C "$D" add -A
  git -C "$D" commit -qm init
}
mk_remote() {
  local D="$1" R="$2"
  rm -rf "$R"
  mkdir -p "$R/release/.github/workflows"
  cp "$D/release-trusted-keys.json" "$R/release/"
  cp "$D/release.yml" "$R/release/"
  printf '%s' "$SMOKE_WF" >"$R/release/.github/workflows/authority-domain-smoke.yml"
  # default branch (main) carries the non-executable REGISTRATION SHIM so GitHub can
  # deliver workflow_dispatch; content differs from the executable release copy.
  echo main >"$R/default_branch"
  mkdir -p "$R/main/.github/workflows"
  printf 'name: authority-domain-registration\non: {workflow_dispatch: {inputs: {rotation_id: {required: true}, new_key_id: {required: true}}}}\njobs: {r: {runs-on: ubuntu-latest, steps: [{run: "exit 1"}]}}\n' \
    >"$R/main/.github/workflows/authority-domain-smoke.yml"
  echo aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa >"$R/release_sha"
  echo success >"$R/run_conclusion"
  echo completed >"$R/run_status"
  echo .github/workflows/authority-domain-smoke.yml >"$R/run_path"
  echo workflow_dispatch >"$R/run_event"
  echo release >"$R/run_branch"
  echo success >"$R/job_conclusion"
  echo completed >"$R/job_status"
  echo sign-verify >"$R/job_name"
  echo 0 >"$R/dispatch_count"
  rm -f "$R/run.json" "$R/jobs.json"
}
merge_to_remote() { cp "$REPO/$1" "$REMOTE/release/$1"; }

# ── synthetic fake-key fixtures (v1.5.3) ─────────────────────────────────────────
# Build the marker from SPLIT parts so this shipped test SOURCE carries no complete
# BEGIN-PRIVATE-KEY marker (the finalize scan exempts only the EXACT historical inline
# fixture; new source must not carry the trigger). Fixtures written into temp repos
# below still bear a real marker, so the scanner is genuinely exercised.
PEM_B='-----BEGIN '"PRIVATE KEY-----"
PEM_E='-----END '"PRIVATE KEY-----"
fake_pem() { printf '%s\nZZ\n%s\n' "$PEM_B" "$PEM_E"; } # real marker, real newlines
BS_N='\n'                                               # a literal backslash-n (2 chars)
HIST_INLINE="${PEM_B}${BS_N}ZZ${BS_N}${PEM_E}"          # the exact pre-v1.5.3 inline fixture
HIST_CHANGED="${PEM_B}${BS_N}NOTZZ${BS_N}${PEM_E}"      # same shape, different body → NOT exempt

run() { # [VAR=VAL ...] <command> <args>
  local -a envs=()
  while [ $# -gt 0 ] && [ "$1" != "${1#*=}" ] && [ "${1#--}" = "$1" ]; do
    envs+=("$1")
    shift
  done
  env AD_REPO_ROOT="$REPO" AD_SIGNING_DIR="$SIGNING" AD_STATE_ROOT="$REPO/.state" AD_SLUG="JonathanPorta/docsort" \
    AD_REMOTE="$REMOTE" AD_POLL_SLEEP=0 AD_ASSUME_STORE_DONE=1 AD_SKIP_VENDOR_CHECK=1 AD_SKIP_ACTIONLINT=1 \
    PATH="$MOCKBIN:$PATH" ${envs[@]+"${envs[@]}"} bash "$TOOL" "$@"
}

# ── 1. plan is read-only — no state (fix #1) ──
REPO="$T/r1"
REMOTE="$T/rem1"
mk_repo "$REPO"
mk_remote "$REPO" "$REMOTE"
expect_rc "plan succeeds (read-only)" 0 run AD_SKIP_GH=1 plan --old-key-id docsort-2026-01 --new-key-id docsort-2026-02 --reason scheduled
if [ -z "$(ls -A "$REPO/.state" 2>/dev/null)" ]; then ok "plan created no rotation state"; else no "plan leaked state"; fi
run plan --old-key-id docsort-2026-01 --new-key-id docsort-2026-02 --reason scheduled >/dev/null 2>&1
run rotate-signing-key --old-key-id docsort-2026-01 --new-key-id docsort-2026-02 --reason scheduled >/dev/null 2>&1 || true
if ls "$REPO"/.state/rotation-*/state.json >/dev/null 2>&1; then ok "real rotate after plan starts a fresh rotation"; else no "rotate after plan did not start"; fi

# ── 2. key-id grammar / traversal (fix #7) ──
REPO="$T/r2"
REMOTE="$T/rem2"
mk_repo "$REPO"
mk_remote "$REPO" "$REMOTE"
expect_rc "path-traversal new key_id rejected" 1 run AD_SKIP_GH=1 plan --old-key-id docsort-2026-01 --new-key-id "../evil" --reason scheduled
expect_rc "slash in key_id rejected" 1 run AD_SKIP_GH=1 plan --old-key-id docsort-2026-01 --new-key-id "a/b" --reason scheduled
if [ -z "$(ls -A "$REPO/.state" 2>/dev/null)" ]; then ok "bad key_ids created no state"; else no "state created for bad key_id"; fi

# ── 3. reuse/precondition guards (read-only via plan) ──
# shellcheck disable=SC2317,SC2329
guard() { run AD_SKIP_GH=1 plan "$@"; }
expect_rc "old==new rejected" 1 guard --old-key-id docsort-2026-01 --new-key-id docsort-2026-01 --reason scheduled
expect_rc "bad --reason rejected" 1 guard --old-key-id docsort-2026-01 --new-key-id docsort-2026-02 --reason nope
expect_rc "unknown domain rejected" 1 guard --domain nope --old-key-id docsort-2026-01 --new-key-id docsort-2026-02 --reason scheduled
REPO="$T/r3b"
REMOTE="$T/rem3b"
mk_repo "$REPO" verify-only
mk_remote "$REPO" "$REMOTE"
expect_rc "non-active old key rejected" 1 guard --old-key-id docsort-2026-01 --new-key-id docsort-2026-02 --reason scheduled
REPO="$T/r3c"
REMOTE="$T/rem3c"
mk_repo "$REPO" active 00000000-0000-0000-0000-000000000000
mk_remote "$REPO" "$REMOTE"
expect_rc "placeholder loader UUID rejected" 1 guard --old-key-id docsort-2026-01 --new-key-id docsort-2026-02 --reason scheduled

# ── 4. resume id path safety (fix #4) ──
REPO="$T/r4"
REMOTE="$T/rem4"
mk_repo "$REPO"
mk_remote "$REPO" "$REMOTE"
expect_rc "resume path-traversal id rejected" 1 run resume "../../etc"
expect_rc "resume nonexistent id rejected" 1 run resume "rotation-nope"
if [ -z "$(ls -A "$REPO/.state" 2>/dev/null)" ]; then ok "bad resume ids left the filesystem unchanged"; else no "resume created state"; fi

# ── 5. full 3-stage happy path with correlated smoke (fix #1,#2,#4) ──
REPO="$T/r5"
REMOTE="$T/rem5"
mk_repo "$REPO"
mk_remote "$REPO" "$REMOTE"
# shellcheck disable=SC2317,SC2329
rotate() { run rotate-signing-key --old-key-id docsort-2026-01 --new-key-id docsort-2026-02 --reason compromised; }
expect_rc "stage 1 stops at trust-prepare" 0 rotate
if [ "$(jq -r '.keys."docsort-2026-02".status' "$REPO/release-trusted-keys.json")" = active ] && [ "$(jq -r '.keys."docsort-2026-01".status' "$REPO/release-trusted-keys.json")" = revoked ]; then ok "trust store staged (new active, old revoked)"; else no "trust-prepare edit"; fi
expect_rc "trust-deploy blocks until remote updated" 1 rotate
merge_to_remote release-trusted-keys.json
expect_rc "stage 2 (trust-deploy → smoke → activate-prepare) proceeds" 0 rotate
if [ "$(yq -r '.candidate.signing.key_id' "$REPO/release.yml")" = docsort-2026-02 ]; then ok "release.yml key_id staged as new"; else no "activate-prepare edit"; fi
expect_rc "activate-deploy blocks until remote updated" 1 rotate
merge_to_remote release.yml
expect_rc "stage 3 (activate-deploy → finalize) completes" 0 rotate
rdir=""
for _d in "$REPO"/.state/rotation-*/; do
  rdir="${_d%/}"
  break
done
if jq -e '.phases_done|index("finalize")' "$rdir/state.json" >/dev/null 2>&1; then ok "rotation finalized"; else no "not finalized"; fi
if [ ! -f "$rdir/new-key.pem" ]; then ok "local private key removed at finalize"; else no "private key not removed"; fi
if grep -rqiE 'BEGIN [A-Z ]*PRIVATE KEY' "$rdir/state.json" 2>/dev/null; then no "state holds a private key"; else ok "state holds no private key"; fi

# ── 6. failed smoke run blocks (fix #4) ──
REPO="$T/r6"
REMOTE="$T/rem6"
mk_repo "$REPO"
mk_remote "$REPO" "$REMOTE"
# shellcheck disable=SC2317,SC2329
rot6() { run rotate-signing-key --old-key-id docsort-2026-01 --new-key-id docsort-2026-02 --reason scheduled; }
rot6 >/dev/null 2>&1
merge_to_remote release-trusted-keys.json
echo failure >"$REMOTE/run_conclusion"
expect_rc "failed smoke run blocks the rotation" 1 rot6
if [ "$(yq -r '.candidate.signing.key_id' "$REPO/release.yml")" = docsort-2026-01 ]; then ok "no activation after failed smoke"; else no "activated despite failed smoke"; fi

# ── 7. both-active remote trust store fails trust-deploy (fix #2) ──
REPO="$T/r7"
REMOTE="$T/rem7"
mk_repo "$REPO"
mk_remote "$REPO" "$REMOTE"
# shellcheck disable=SC2317,SC2329
rot7() { run rotate-signing-key --old-key-id docsort-2026-01 --new-key-id docsort-2026-02 --reason compromised; }
rot7 >/dev/null 2>&1
jq '.keys."docsort-2026-01".status="active"' "$REPO/release-trusted-keys.json" >"$REMOTE/release/release-trusted-keys.json"
expect_rc "trust-deploy rejects a both-active remote store" 1 rot7

# ── 8. rotation immutability — reason mismatch (fix #3) ──
REPO="$T/r8"
REMOTE="$T/rem8"
mk_repo "$REPO"
mk_remote "$REPO" "$REMOTE"
run rotate-signing-key --old-key-id docsort-2026-01 --new-key-id docsort-2026-02 --reason scheduled >/dev/null 2>&1
expect_rc "re-invoking with a different reason is rejected (immutable)" 1 \
  run rotate-signing-key --old-key-id docsort-2026-01 --new-key-id docsort-2026-02 --reason compromised

# ── 9. staged-INDEX private key refuses finalize (fix #5) ──
REPO="$T/r9"
REMOTE="$T/rem9"
mk_repo "$REPO"
mk_remote "$REPO" "$REMOTE"
# shellcheck disable=SC2317,SC2329
rot9() { run rotate-signing-key --old-key-id docsort-2026-01 --new-key-id docsort-2026-02 --reason scheduled; }
rot9 >/dev/null 2>&1
merge_to_remote release-trusted-keys.json
rot9 >/dev/null 2>&1
merge_to_remote release.yml
fake_pem >"$REPO/leaked.pem"
git -C "$REPO" add leaked.pem
echo clean >"$REPO/leaked.pem"
expect_rc "finalize refuses on a staged-index private key (clean worktree)" 1 rot9

# ── 10. install-smoke-workflow renders a GENERIC secret name (fix #7) ──
REPO="$T/r10"
REMOTE="$T/rem10"
mk_repo "$REPO"
mk_remote "$REPO" "$REMOTE"
rm -f "$REPO/.github/workflows/authority-domain-smoke.yml"
yq -i '.secret_authorities."release-signing".injects[0] = "KIOSKD_RELEASE_SIGNING_KEY"' "$REPO/blessed.yml"
expect_rc "install-smoke-workflow succeeds" 0 run install-smoke-workflow
wf="$REPO/.github/workflows/authority-domain-smoke.yml"
if grep -q 'KIOSKD_RELEASE_SIGNING_KEY' "$wf" && ! grep -q 'DOCSORT_RELEASE_SIGNING_KEY' "$wf" && ! grep -q '@@' "$wf"; then ok "rendered workflow uses the blessed.yml secret name (generic)"; else no "smoke render not generic"; fi
expect_rc "install-smoke-workflow is idempotent" 0 run install-smoke-workflow

# ── 11. trust-deploy verifies at the tip SHA, not the branch name (no TOCTOU) ──
REPO="$T/r11"
REMOTE="$T/rem11"
mk_repo "$REPO"
mk_remote "$REPO" "$REMOTE"
# shellcheck disable=SC2317,SC2329
rot11() { run rotate-signing-key --old-key-id docsort-2026-01 --new-key-id docsort-2026-02 --reason compromised; }
rot11 >/dev/null 2>&1 # stage 1 → local store is now GOOD (new active, old revoked)
sha="$(cat "$REMOTE/release_sha")"
mkdir -p "$REMOTE/bysha/$sha"
cp "$REPO/release-trusted-keys.json" "$REMOTE/bysha/$sha/"                                                                  # GOOD content pinned at the tip SHA
jq '.keys."docsort-2026-01".status="active"' "$REPO/release-trusted-keys.json" >"$REMOTE/release/release-trusted-keys.json" # BAD (both-active) at the branch name
expect_rc "trust-deploy reads the tip SHA content (good), not the branch (bad)" 0 rot11

# ── 12. smoke rejects a run whose head SHA != the verified trust commit ──
REPO="$T/r12"
REMOTE="$T/rem12"
mk_repo "$REPO"
mk_remote "$REPO" "$REMOTE"
# shellcheck disable=SC2317,SC2329
rot12() { run rotate-signing-key --old-key-id docsort-2026-01 --new-key-id docsort-2026-02 --reason scheduled; }
rot12 >/dev/null 2>&1
merge_to_remote release-trusted-keys.json
echo bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb >"$REMOTE/run_headsha" # smoke run at a DIFFERENT commit
expect_rc "smoke rejects a run whose head sha != the verified trust commit" 1 rot12

# ── 13. vendor preflight fails closed on a version-pin mismatch (fix #2) ──
REPO="$T/r13"
REMOTE="$T/rem13"
mk_repo "$REPO"
mk_remote "$REPO" "$REMOTE"
mkdir -p "$REPO/scripts/bws"
echo 9.9.9 >"$REPO/scripts/bws/VERSION"
echo dummy >"$REPO/scripts/bws/MANIFEST.sha256"
printf '#!/usr/bin/env bash\nexit 0\n' >"$REPO/scripts/verifier.sh"
chmod +x "$REPO/scripts/verifier.sh"
CAT="$REPO/scripts/bws"
VS="$REPO/scripts/verifier.sh"
SVER="$(cat "$SIGNING/VERSION")"
# shellcheck disable=SC2317,SC2329
V() { run AD_SKIP_VENDOR_CHECK=0 AD_SKIP_GH=1 AD_CATEGORY_DIR="$CAT" AD_VERIFIER="$VS" rotate-signing-key --old-key-id docsort-2026-01 --new-key-id docsort-2026-02 --reason scheduled; }
printf 'BWS_VERSION=1.1.1\nBWS_TAG=bws-v1.1.1\nSIGNING_VERSION=%s\nSIGNING_TAG=signing-v%s\n' "$SVER" "$SVER" >"$REPO/scripts/.blessed-scripts-version"
expect_rc "vendor preflight fails on a BWS version-pin mismatch" 1 V
printf 'BWS_VERSION=9.9.9\nBWS_TAG=bws-v9.9.9\nSIGNING_VERSION=0.0.0\nSIGNING_TAG=signing-v0.0.0\n' >"$REPO/scripts/.blessed-scripts-version"
expect_rc "vendor preflight fails on a SIGNING version-pin mismatch" 1 V
printf 'BWS_VERSION=9.9.9\nBWS_TAG=bws-v9.9.9\nSIGNING_VERSION=%s\nSIGNING_TAG=signing-v%s\n' "$SVER" "$SVER" >"$REPO/scripts/.blessed-scripts-version"
expect_rc "vendor preflight passes on matching bws+signing pins + verifying manifests" 0 V
rm -f "$REPO/scripts/.blessed-scripts-version"
expect_rc "vendor preflight fails when the pin file is missing" 1 V

# ── 14. activate-deploy re-verifies the trust store at the activation commit (Blocker 1) ──
REPO="$T/r14"
REMOTE="$T/rem14"
mk_repo "$REPO"
mk_remote "$REPO" "$REMOTE"
# shellcheck disable=SC2317,SC2329
rot14() { run rotate-signing-key --old-key-id docsort-2026-01 --new-key-id docsort-2026-02 --reason compromised; }
rot14 >/dev/null 2>&1
merge_to_remote release-trusted-keys.json
rot14 >/dev/null 2>&1 # → activate-prepare stop
merge_to_remote release.yml
jq '.keys."docsort-2026-01".status="active"' "$REMOTE/release/release-trusted-keys.json" >"$REMOTE/release/tk.tmp" && mv "$REMOTE/release/tk.tmp" "$REMOTE/release/release-trusted-keys.json" # tamper: old key back to active
expect_rc "activate-deploy rejects a trust store that restored the old key to active" 1 rot14

# ── 15. smoke rejects a remote workflow that differs from the installed one (Blocker 2a) ──
REPO="$T/r15"
REMOTE="$T/rem15"
mk_repo "$REPO"
mk_remote "$REPO" "$REMOTE"
# shellcheck disable=SC2317,SC2329
rot15() { run rotate-signing-key --old-key-id docsort-2026-01 --new-key-id docsort-2026-02 --reason scheduled; }
rot15 >/dev/null 2>&1
merge_to_remote release-trusted-keys.json
printf '%s# tampered no-op\n' "$SMOKE_WF" >"$REMOTE/release/.github/workflows/authority-domain-smoke.yml" # remote workflow bytes differ
expect_rc "smoke rejects a remote workflow differing from the installed (reviewed) one" 1 rot15

# ── 16. pin-file selection: canonical-first with legacy fallback (Item 3) ──
REPO="$T/r16"
REMOTE="$T/rem16"
mk_repo "$REPO"
mk_remote "$REPO" "$REMOTE"
mkdir -p "$REPO/scripts/bws"
echo 9.9.9 >"$REPO/scripts/bws/VERSION"
echo dummy >"$REPO/scripts/bws/MANIFEST.sha256"
printf '#!/usr/bin/env bash\nexit 0\n' >"$REPO/scripts/verifier16.sh"
chmod +x "$REPO/scripts/verifier16.sh"
SVER16="$(cat "$SIGNING/VERSION")"
GOODPIN="$(printf 'BWS_VERSION=9.9.9\nBWS_TAG=bws-v9.9.9\nSIGNING_VERSION=%s\nSIGNING_TAG=signing-v%s\n' "$SVER16" "$SVER16")"
BADPIN="$(printf 'BWS_VERSION=0.0.0\nBWS_TAG=bws-v0.0.0\nSIGNING_VERSION=0.0.0\nSIGNING_TAG=signing-v0.0.0\n')"
# shellcheck disable=SC2317,SC2329
P16() { run AD_SKIP_VENDOR_CHECK=0 AD_SKIP_GH=1 AD_CATEGORY_DIR="$REPO/scripts/bws" AD_VERIFIER="$REPO/scripts/verifier16.sh" plan --old-key-id docsort-2026-01 --new-key-id docsort-2026-02 --reason scheduled; }
rm -f "$REPO/scripts/.blessed-scripts-version"
printf '%s' "$GOODPIN" >"$REPO/scripts/.bws-scripts-version" # legacy only
expect_rc "pin fallback: legacy .bws-scripts-version honored when canonical absent" 0 P16
printf '%s' "$GOODPIN" >"$REPO/scripts/.blessed-scripts-version" # canonical good
printf '%s' "$BADPIN" >"$REPO/scripts/.bws-scripts-version"      # legacy bad → must be ignored
expect_rc "pin fallback: canonical wins when both pin files are present" 0 P16

# ── 17. untracked (never-added) private key blocks finalize (Item 2) ──
REPO="$T/r17"
REMOTE="$T/rem17"
mk_repo "$REPO"
mk_remote "$REPO" "$REMOTE"
# shellcheck disable=SC2317,SC2329
rot17() { run rotate-signing-key --old-key-id docsort-2026-01 --new-key-id docsort-2026-02 --reason scheduled; }
rot17 >/dev/null 2>&1
merge_to_remote release-trusted-keys.json
rot17 >/dev/null 2>&1
merge_to_remote release.yml
fake_pem >"$REPO/stray.pem" # untracked, never git-add'd
expect_rc "finalize refuses an untracked (never-staged) private key" 1 rot17

# ── 18. a PEM committed mid-rotation then deleted still blocks finalize (Item 2, history) ──
REPO="$T/r18"
REMOTE="$T/rem18"
mk_repo "$REPO"
mk_remote "$REPO" "$REMOTE"
# shellcheck disable=SC2317,SC2329
rot18() { run rotate-signing-key --old-key-id docsort-2026-01 --new-key-id docsort-2026-02 --reason scheduled; }
rot18 >/dev/null 2>&1 # start_commit recorded at current HEAD
merge_to_remote release-trusted-keys.json
fake_pem >"$REPO/oops.pem"
git -C "$REPO" add oops.pem
git -C "$REPO" commit -qm "oops: committed a key"
git -C "$REPO" rm -q oops.pem
git -C "$REPO" commit -qm "remove the key"
rot18 >/dev/null 2>&1 # → activate-prepare
merge_to_remote release.yml
expect_rc "finalize refuses a PEM committed then deleted (history scan)" 1 rot18

# ── 19. CLEAN INSTALL from the exact release tarball layout (Item 1 + Item 4) ──
# Build bws + signing archives the way release-scripts.yml does (tar -C scripts <cat>),
# extract into a fresh consumer that has NO source-tree scripts/manifest.sh, and prove
# preflight (bws + signing closed-set verify + pin selection) passes with NO AD_* overrides.
SRC="$(cd "$HERE/../.." && pwd)"
BWSVER="$(cat "$SRC/scripts/bws/VERSION")"
SVER19="$(cat "$SRC/scripts/signing/VERSION")"
COPYFILE_DISABLE=1 tar -C "$SRC/scripts" -czf "$T/bws.tgz" bws
COPYFILE_DISABLE=1 tar -C "$SRC/scripts" -czf "$T/signing.tgz" signing
CONS="$T/cons"
REMOTE="$T/rem19"
mk_repo "$CONS"
mk_remote "$CONS" "$REMOTE"
mkdir -p "$CONS/scripts"
tar -xzf "$T/bws.tgz" -C "$CONS/scripts"
tar -xzf "$T/signing.tgz" -C "$CONS/scripts"
printf 'BWS_VERSION=%s\nBWS_TAG=bws-v%s\nSIGNING_VERSION=%s\nSIGNING_TAG=signing-v%s\n' \
  "$BWSVER" "$BWSVER" "$SVER19" "$SVER19" >"$CONS/scripts/.blessed-scripts-version"
if [ ! -f "$CONS/scripts/manifest.sh" ]; then ok "clean install ships NO source-tree scripts/manifest.sh"; else no "clean install unexpectedly shipped scripts/manifest.sh"; fi
# Invoke the EXTRACTED tool so HERE, the signing dir, and the verifier all resolve
# inside the tarball layout — vendor check ON, no AD_CATEGORY_DIR/AD_VERIFIER/AD_MANIFEST override.
# shellcheck disable=SC2317,SC2329
clean_plan() {
  env AD_REPO_ROOT="$CONS" AD_SLUG="JonathanPorta/docsort" AD_REMOTE="$REMOTE" \
    AD_STATE_ROOT="$CONS/.state" AD_SKIP_GH=1 AD_POLL_SLEEP=0 \
    PATH="$MOCKBIN:$PATH" bash "$CONS/scripts/bws/authority-domains.sh" \
    plan --old-key-id docsort-2026-01 --new-key-id docsort-2026-02 --reason scheduled
}
expect_rc "clean-install preflight verifies bws+signing via the SHIPPED verifier (no manifest.sh, no overrides)" 0 clean_plan

# ── 20. preflight fails when the smoke workflow is NOT registered on the default branch ──
REPO="$T/r20"
REMOTE="$T/rem20"
mk_repo "$REPO"
mk_remote "$REPO" "$REMOTE"
rm -rf "$REMOTE/main" # default-branch registration absent → GitHub could not dispatch
expect_rc "preflight fails when the smoke workflow is not registered on the default branch" 1 \
  run rotate-signing-key --old-key-id docsort-2026-01 --new-key-id docsort-2026-02 --reason scheduled

# ── 21. preflight fails when the EXECUTABLE workflow is missing on AUTH_BRANCH ──
REPO="$T/r21"
REMOTE="$T/rem21"
mk_repo "$REPO"
mk_remote "$REPO" "$REMOTE"
rm -rf "$REMOTE/release/.github" # executable workflow gone from the release branch
expect_rc "preflight fails when the executable smoke workflow is missing on the release branch" 1 \
  run rotate-signing-key --old-key-id docsort-2026-01 --new-key-id docsort-2026-02 --reason scheduled

# ── 22. preflight PASSES with a default-branch registration + executable release workflow ──
REPO="$T/r22"
REMOTE="$T/rem22"
mk_repo "$REPO"
mk_remote "$REPO" "$REMOTE"
expect_rc "preflight passes with default-branch registration + executable release workflow" 0 \
  run plan --old-key-id docsort-2026-01 --new-key-id docsort-2026-02 --reason scheduled

# ── 23. a registration-titled run cannot satisfy authority-smoke correlation ──
REPO="$T/r23"
REMOTE="$T/rem23"
mk_repo "$REPO"
mk_remote "$REPO" "$REMOTE"
# shellcheck disable=SC2317,SC2329
rot23() { run rotate-signing-key --old-key-id docsort-2026-01 --new-key-id docsort-2026-02 --reason scheduled; }
rot23 >/dev/null 2>&1
merge_to_remote release-trusted-keys.json
echo authority-registration >"$REMOTE/run_title_prefix" # dispatched run gets a REGISTRATION title
expect_rc "a registration-titled run cannot satisfy authority-smoke correlation" 1 rot23

# ── 24. dispatch-input validation rejects injection BEFORE load-secrets (script-injection fix) ──
RTMPL="$HERE/templates/authority-domain-smoke.yml.tmpl"
RENDER="$T/rendered-smoke.yml"
sed -e 's/@@ENV@@/release-signing/g' -e 's/@@BRANCH@@/release/g' -e 's/@@SECRET@@/DOCSORT_RELEASE_SIGNING_KEY/g' -e 's/@@PROFILE@@/release-signing/g' "$RTMPL" >"$RENDER"
first_step="$(yq '.jobs.sign-verify.steps[0].name' "$RENDER")"
case "$first_step" in *Validate*) ok "input validation is the FIRST job step" ;; *) no "input validation is not the first step" ;; esac
load_idx="$(yq '.jobs.sign-verify.steps | to_entries | .[] | select(.value.uses == "./.github/actions/load-secrets") | .key' "$RENDER" 2>/dev/null || echo "")"
if [ -n "$load_idx" ] && [ "$load_idx" -ge 1 ] 2>/dev/null; then ok "load-secrets runs after validation (step index $load_idx)"; else no "load-secrets is not gated behind validation"; fi
if yq '.jobs.sign-verify.steps[].run // ""' "$RENDER" | grep -q 'inputs\.'; then no "a \${{ inputs.* }} expression leaked into a run: block"; else ok "no \${{ inputs.* }} appears in any run: block"; fi
VSTEP="$(yq '.jobs.sign-verify.steps[] | select(.name | test("Validate dispatch inputs")) | .run' "$RENDER")"
# shellcheck disable=SC2317,SC2329
inj() { ROTATION_ID="$1" NEW_KEY_ID="$2" bash -c "$VSTEP"; }
RID_OK="rotation-20260722T000000Z-abcd1234"
expect_rc "valid rotation_id + new_key_id pass validation" 0 inj "$RID_OK" "docsort-2026-02"
expect_rc "double-quote injection rejected" 1 inj "$RID_OK" 'a";id;"'
expect_rc "semicolon metacharacter rejected" 1 inj "$RID_OK" 'a;id'
# shellcheck disable=SC2016  # the single quotes are intentional: pass the literal injection payload, do NOT expand it
expect_rc "command substitution \$() rejected" 1 inj "$RID_OK" 'a$(id)'
# shellcheck disable=SC2016  # literal backtick payload — must NOT expand
expect_rc "backtick command substitution rejected" 1 inj "$RID_OK" 'a`id`'
expect_rc "whitespace rejected" 1 inj "$RID_OK" 'a b'
expect_rc "embedded newline rejected" 1 inj "$RID_OK" "$(printf 'ok\nevil')"
expect_rc "slash rejected" 1 inj "$RID_OK" 'a/b'
expect_rc "dot-dot in new_key_id rejected" 1 inj "$RID_OK" '../evil'
expect_rc "dot-dot in rotation_id rejected" 1 inj 'rotation-../x' "docsort-2026-02"
expect_rc "metacharacter in rotation_id rejected" 1 inj 'rotation-x;id' "docsort-2026-02"

# ── 25. workflowName may differ from executable YAML name (registration-shim identity) ──
# Happy path already defaults wf_name to the shim display name. Explicitly set a
# divergent workflowName and prove proof still passes when path/title/event/branch/
# sha and sign-verify job are correct.
REPO="$T/r25"
REMOTE="$T/rem25"
mk_repo "$REPO"
mk_remote "$REPO" "$REMOTE"
echo '🔏 Authority domain smoke (registration shim)' >"$REMOTE/wf_name"
# local workflow YAML name remains `smoke` (from SMOKE_WF); shim name differs.
# shellcheck disable=SC2317,SC2329
rot25() { run rotate-signing-key --old-key-id docsort-2026-01 --new-key-id docsort-2026-02 --reason scheduled; }
rot25 >/dev/null 2>&1
merge_to_remote release-trusted-keys.json
expect_rc "shim workflowName != executable YAML name still passes when path+job proof holds" 0 rot25
if [ "$(yq -r '.candidate.signing.key_id' "$REPO/release.yml")" = docsort-2026-02 ]; then
  ok "activation staged after shim-name proof"
else
  no "activation did not stage after shim-name proof"
fi

# ── 26. wrong workflow path fails proof ──
REPO="$T/r26"
REMOTE="$T/rem26"
mk_repo "$REPO"
mk_remote "$REPO" "$REMOTE"
# shellcheck disable=SC2317,SC2329
rot26() { run rotate-signing-key --old-key-id docsort-2026-01 --new-key-id docsort-2026-02 --reason scheduled; }
rot26 >/dev/null 2>&1
merge_to_remote release-trusted-keys.json
echo '.github/workflows/wrong-smoke.yml' >"$REMOTE/run_path"
expect_rc "wrong workflow path fails smoke proof" 1 rot26

# ── 27. wrong title / event / branch / sha each fail ──
REPO="$T/r27"
REMOTE="$T/rem27"
mk_repo "$REPO"
mk_remote "$REPO" "$REMOTE"
# shellcheck disable=SC2317,SC2329
rot27() { run rotate-signing-key --old-key-id docsort-2026-01 --new-key-id docsort-2026-02 --reason scheduled; }
rot27 >/dev/null 2>&1
merge_to_remote release-trusted-keys.json
echo authority-registration >"$REMOTE/run_title_prefix"
expect_rc "wrong display_title fails smoke proof" 1 rot27

REPO="$T/r27b"
REMOTE="$T/rem27b"
mk_repo "$REPO"
mk_remote "$REPO" "$REMOTE"
# shellcheck disable=SC2317,SC2329
rot27b() { run rotate-signing-key --old-key-id docsort-2026-01 --new-key-id docsort-2026-02 --reason scheduled; }
rot27b >/dev/null 2>&1
merge_to_remote release-trusted-keys.json
echo push >"$REMOTE/run_event"
# Must rewrite run.json after dispatch-shaped event override: force re-dispatch path
# by clearing smoke and re-running after trust is remote. Event is applied at dispatch
# time via run_event; clear run.json and re-enter smoke without prior smoke_run_id.
# Easier: set event override before stage 2 continues (before first dispatch).
# Here rot27b already stopped at trust-prepare; run_event is read at dispatch — set
# it now so the upcoming dispatch stamps event=push into run.json.
expect_rc "wrong event fails smoke proof" 1 rot27b

REPO="$T/r27c"
REMOTE="$T/rem27c"
mk_repo "$REPO"
mk_remote "$REPO" "$REMOTE"
# shellcheck disable=SC2317,SC2329
rot27c() { run rotate-signing-key --old-key-id docsort-2026-01 --new-key-id docsort-2026-02 --reason scheduled; }
rot27c >/dev/null 2>&1
merge_to_remote release-trusted-keys.json
echo main >"$REMOTE/run_branch"
expect_rc "wrong head_branch fails smoke proof" 1 rot27c

REPO="$T/r27d"
REMOTE="$T/rem27d"
mk_repo "$REPO"
mk_remote "$REPO" "$REMOTE"
# shellcheck disable=SC2317,SC2329
rot27d() { run rotate-signing-key --old-key-id docsort-2026-01 --new-key-id docsort-2026-02 --reason scheduled; }
rot27d >/dev/null 2>&1
merge_to_remote release-trusted-keys.json
echo bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb >"$REMOTE/run_headsha"
expect_rc "wrong head_sha fails smoke proof" 1 rot27d

# ── 28. missing / failed / cancelled / skipped sign-verify job fails ──
# shellcheck disable=SC2317,SC2329
job_case() {
  local tag="$1" jname="$2" jst="$3" jcc="$4" desc="$5"
  REPO="$T/r28-$tag"
  REMOTE="$T/rem28-$tag"
  mk_repo "$REPO"
  mk_remote "$REPO" "$REMOTE"
  # shellcheck disable=SC2317,SC2329
  rotj() { run rotate-signing-key --old-key-id docsort-2026-01 --new-key-id docsort-2026-02 --reason scheduled; }
  rotj >/dev/null 2>&1
  merge_to_remote release-trusted-keys.json
  echo "$jname" >"$REMOTE/job_name"
  echo "$jst" >"$REMOTE/job_status"
  echo "$jcc" >"$REMOTE/job_conclusion"
  expect_rc "$desc" 1 rotj
}
job_case miss other-job completed success "missing sign-verify job fails smoke proof"
job_case fail sign-verify completed failure "failed sign-verify job fails smoke proof"
job_case can sign-verify completed cancelled "cancelled sign-verify job fails smoke proof"
job_case skip sign-verify completed skipped "skipped sign-verify job fails smoke proof"

# ── 29. resume with persisted smoke_run_id performs no re-dispatch ──
REPO="$T/r29"
REMOTE="$T/rem29"
mk_repo "$REPO"
mk_remote "$REPO" "$REMOTE"
# shellcheck disable=SC2317,SC2329
rot29() { run rotate-signing-key --old-key-id docsort-2026-01 --new-key-id docsort-2026-02 --reason scheduled; }
rot29 >/dev/null 2>&1
merge_to_remote release-trusted-keys.json
# First smoke attempt: dispatch once, then fail the job so smoke does not mark done.
echo failure >"$REMOTE/job_conclusion"
expect_rc "first smoke fails on bad sign-verify (records smoke_run_id)" 1 rot29
d1="$(cat "$REMOTE/dispatch_count")"
rdir29=""
for _d in "$REPO"/.state/rotation-*/; do
  rdir29="${_d%/}"
  break
done
sid="$(jq -r '.smoke_run_id // empty' "$rdir29/state.json" 2>/dev/null || true)"
if [ -n "$sid" ]; then ok "smoke_run_id persisted after failed smoke"; else no "smoke_run_id not persisted"; fi
# Fix the job, resume — must NOT dispatch again.
echo success >"$REMOTE/job_conclusion"
expect_rc "resume revalidates persisted run without re-dispatch" 0 rot29
d2="$(cat "$REMOTE/dispatch_count")"
if [ "$d1" = "$d2" ]; then ok "resume performed no re-dispatch (count=$d2)"; else no "resume re-dispatched (before=$d1 after=$d2)"; fi

# ── 30–38. finalize scan: WHOLE-FILE identity exemption for the synthetic bws fixture ──
# Exempt ONLY a byte-identical copy of a KNOWN reviewed released authority-domains-test.sh
# (private-key class, exact path, whole-file SHA-256 match). ANY byte change removes the
# exemption — so a second real marker on the SAME or a DIFFERENT line, a one-byte change,
# a changed body, or a real PEM all still fail (the old line-substring exemption fail-
# opened on a line bearing the fixture AND a second marker). AD_EXTRA_FIXTURE_SHA256 is a
# TEST-ONLY seam to allowlist a hash the suite builds; production ships the three real
# release hashes hardcoded (proven to match each release's MANIFEST.sha256).
put_bws_testfile() { mkdir -p "$REPO/scripts/bws" && printf 'x=%s\n' "$1" >"$REPO/scripts/bws/authority-domains-test.sh"; }
commit_all() { git -C "$REPO" add -A && git -C "$REPO" commit -qm "$1"; }
sha_of() { shasum -a 256 "$1" | cut -d' ' -f1; } # matches the tool's _sha256_of
BWS_TESTFILE() { printf '%s' "$REPO/scripts/bws/authority-domains-test.sh"; }
# shellcheck disable=SC2317,SC2329
drive_finalize_allow() { # $1 = extra sha to allowlist for the finalize scan (may be empty)
  run rotate-signing-key --old-key-id docsort-2026-01 --new-key-id docsort-2026-02 --reason scheduled >/dev/null 2>&1
  merge_to_remote release-trusted-keys.json
  run rotate-signing-key --old-key-id docsort-2026-01 --new-key-id docsort-2026-02 --reason scheduled >/dev/null 2>&1
  merge_to_remote release.yml
  run AD_EXTRA_FIXTURE_SHA256="$1" rotate-signing-key --old-key-id docsort-2026-01 --new-key-id docsort-2026-02 --reason scheduled
}

# 30. exact known released file (whole-file identity) → exempt → finalize passes
REPO="$T/r30"
REMOTE="$T/rem30"
mk_repo "$REPO"
mk_remote "$REPO" "$REMOTE"
put_bws_testfile "$HIST_INLINE"
H30="$(sha_of "$(BWS_TESTFILE)")"
commit_all "known released bws test file"
expect_rc "finalize exempts a byte-identical known released test file (whole-file identity)" 0 drive_finalize_allow "$H30"

# 31. same known file entering history mid-rotation → still exempt
REPO="$T/r31"
REMOTE="$T/rem31"
mk_repo "$REPO"
mk_remote "$REPO" "$REMOTE"
# shellcheck disable=SC2317,SC2329
rot31pre() { run rotate-signing-key --old-key-id docsort-2026-01 --new-key-id docsort-2026-02 --reason scheduled; }
rot31pre >/dev/null 2>&1
merge_to_remote release-trusted-keys.json
put_bws_testfile "$HIST_INLINE"
H31="$(sha_of "$(BWS_TESTFILE)")"
commit_all "vendor known file mid-rotation"
rot31pre >/dev/null 2>&1
merge_to_remote release.yml
# shellcheck disable=SC2317,SC2329
rot31final() { run AD_EXTRA_FIXTURE_SHA256="$H31" rotate-signing-key --old-key-id docsort-2026-01 --new-key-id docsort-2026-02 --reason scheduled; }
expect_rc "finalize exempts the known file when it enters history mid-rotation" 0 rot31final

# 32. changed fixture body → not exempt → fails
REPO="$T/r32"
REMOTE="$T/rem32"
mk_repo "$REPO"
mk_remote "$REPO" "$REMOTE"
put_bws_testfile "$HIST_INLINE"
PURE32="$(sha_of "$(BWS_TESTFILE)")"
put_bws_testfile "$HIST_CHANGED"
commit_all "changed fixture body"
expect_rc "a changed fixture body removes the exemption (whole-file identity)" 1 drive_finalize_allow "$PURE32"

# 33. exact fixture PLUS a second marker on the SAME line → not exempt (old fail-open) → fails
REPO="$T/r33"
REMOTE="$T/rem33"
mk_repo "$REPO"
mk_remote "$REPO" "$REMOTE"
put_bws_testfile "$HIST_INLINE"
PURE33="$(sha_of "$(BWS_TESTFILE)")"
mkdir -p "$REPO/scripts/bws"
printf 'x=%s and a real one %sREALKEY%s\n' "$HIST_INLINE" "$PEM_B" "$PEM_E" >"$(BWS_TESTFILE)"
commit_all "fixture + second marker on the SAME line"
expect_rc "a second marker on the fixture line is NOT hidden (whole-file identity)" 1 drive_finalize_allow "$PURE33"

# 34. exact fixture PLUS a second marker on a DIFFERENT line → not exempt → fails
REPO="$T/r34"
REMOTE="$T/rem34"
mk_repo "$REPO"
mk_remote "$REPO" "$REMOTE"
put_bws_testfile "$HIST_INLINE"
PURE34="$(sha_of "$(BWS_TESTFILE)")"
{
  printf 'x=%s\n' "$HIST_INLINE"
  printf '%s\n' "$PEM_B"
  printf 'REALKEY\n'
  printf '%s\n' "$PEM_E"
} >"$(BWS_TESTFILE)"
commit_all "fixture + second marker on a DIFFERENT line"
expect_rc "a second marker on another line is NOT hidden (whole-file identity)" 1 drive_finalize_allow "$PURE34"

# 35. one-byte change to the historical file → not exempt → fails
REPO="$T/r35"
REMOTE="$T/rem35"
mk_repo "$REPO"
mk_remote "$REPO" "$REMOTE"
put_bws_testfile "$HIST_INLINE"
PURE35="$(sha_of "$(BWS_TESTFILE)")"
printf 'x' >>"$(BWS_TESTFILE)"
commit_all "one-byte change to the historical file"
expect_rc "a one-byte change removes the exemption (whole-file identity)" 1 drive_finalize_allow "$PURE35"

# 36. a REAL (multi-line) PEM in the test file's own path → not exempt → fails
REPO="$T/r36"
REMOTE="$T/rem36"
mk_repo "$REPO"
mk_remote "$REPO" "$REMOTE"
put_bws_testfile "$HIST_INLINE"
PURE36="$(sha_of "$(BWS_TESTFILE)")"
{
  printf '%s\n' "$PEM_B"
  printf 'MIIBVAIBADANBgkq\n'
  printf '%s\n' "$PEM_E"
} >"$(BWS_TESTFILE)"
commit_all "REAL multi-line PEM in the test file path"
expect_rc "a real PEM in the test file path is NOT exempt (hash differs)" 1 drive_finalize_allow "$PURE36"

# 37. real PEM elsewhere under scripts/bws → not exempt (wrong path) → fails
REPO="$T/r37"
REMOTE="$T/rem37"
mk_repo "$REPO"
mk_remote "$REPO" "$REMOTE"
put_bws_testfile "$HIST_INLINE"
PURE37="$(sha_of "$(BWS_TESTFILE)")" # the test file itself is allowlisted
mkdir -p "$REPO/scripts/bws"
{
  printf '%s\n' "$PEM_B"
  printf 'MIIBVAIBADAN\n'
  printf '%s\n' "$PEM_E"
} >"$REPO/scripts/bws/other.pem"
commit_all "real PEM elsewhere in scripts/bws"
expect_rc "a real PEM elsewhere under scripts/bws is not exempt (exact path only)" 1 drive_finalize_allow "$PURE37"

# 38. real PEM under scripts/signing → not exempt → fails
REPO="$T/r38"
REMOTE="$T/rem38"
mk_repo "$REPO"
mk_remote "$REPO" "$REMOTE"
put_bws_testfile "$HIST_INLINE"
PURE38="$(sha_of "$(BWS_TESTFILE)")"
mkdir -p "$REPO/scripts/signing"
{
  printf '%s\n' "$PEM_B"
  printf 'MIIBVAIBADAN\n'
  printf '%s\n' "$PEM_E"
} >"$REPO/scripts/signing/leaked.pem"
commit_all "real PEM under scripts/signing"
expect_rc "a real PEM under scripts/signing is not exempt" 1 drive_finalize_allow "$PURE38"

echo "------------------------------------------------------------"
if [ "$fail" -eq 0 ]; then echo "blessed authority-domains: PASS ($pass checks)"; else echo "blessed authority-domains: FAIL"; fi
exit "$fail"
