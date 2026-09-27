#!/usr/bin/env bash
# bws-loader-bootstrap.sh — the committed loader, run through the PRODUCTION
# bootstrapper (vendored scripts/bws/bootstrap.sh) with recording fakes for
# `bws` and `gh`, domain by domain as PROVISIONING.md §5–§9 prescribe.
#
# Proves (review F3/F2 on PR #1):
#   · the default (Cloudflare) domain becomes usable: CLOUDFLARE_API_TOKEN gets
#     its minted id and CLOUDFLARE_ACCOUNT_ID keeps the canonical _shared-ci id
#     (the bootstrapper never rewrites shared lines — it is baked in);
#   · each profile's bootstrap fills ONLY its own line; the other profiles'
#     mappings are byte-identical afterwards;
#   · the per-domain checkpoint is required: running the next domain while the
#     previous fill is uncommitted refuses to edit the loader, and after the
#     checkpoint (commit) it fills;
#   · no secret value is ever passed to the fakes' mutation log.
# Nothing here touches a network or a real vault.
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
command -v jq >/dev/null 2>&1 || {
  echo "bws-loader-bootstrap: jq is required"
  exit 1
}
W="$(mktemp -d)"
trap 'rm -rf "$W"' EXIT
R="$W/repo" BIN="$W/bin"
mkdir -p "$R" "$BIN"
LOADER=.github/actions/load-secrets/action.yml
SHARED_ACCOUNT_ID=6c68ee9e-c577-44c5-a5e6-b458007ddc2a

# A clean checkout of exactly the committed files the walkthrough touches.
(cd "$ROOT" && tar -cf - scripts/bws "$LOADER" .bws-secrets-list .env-sample .bws) | tar -xf - -C "$R"
git -C "$R" init -q
git -C "$R" -c user.email=t@t -c user.name=t add -A
git -C "$R" -c user.email=t@t -c user.name=t commit -qm base

# ── fakes ──────────────────────────────────────────────────────────────────
# bws: projects exist once created; each project already holds its declared
# secrets (the operator entered them in the web vault) with deterministic ids.
cat >"$BIN/bws" <<'FAKE'
#!/usr/bin/env bash
set -uo pipefail
id_for() { printf '%s' "$1" | sha256sum | cut -c1-32 | sed -E 's/(.{8})(.{4})(.{4})(.{4})(.{12})/\1-\2-\3-\4-\5/'; }
case "${1:-} ${2:-}" in
  "project list")
    jq -cn --arg p "$FAKE_PROJECT" --arg id "$(id_for "project:$FAKE_PROJECT")" '[{id: $id, name: $p}]' ;;
  "project create") jq -cn --arg p "$3" --arg id "$(id_for "project:$3")" '{id: $id, name: $p}' ;;
  "secret list")
    printf '%s\n' $FAKE_KEYS | jq -R . | jq -cs --arg p "$3" 'map({key: ., id: ., revisionDate: "2026-01-01T00:00:00Z", note: ""})' |
      while IFS= read -r arr; do
        printf '%s' "$arr" | jq -c '.[]' | while IFS= read -r o; do
          k="$(printf '%s' "$o" | jq -r .key)"
          printf '%s' "$o" | jq -c --arg id "$(id_for "secret:$3:$k")" '.id = $id'
        done | jq -cs .
      done ;;
  *) printf '{}\n' ;;
esac
FAKE
cat >"$BIN/gh" <<'FAKE'
#!/usr/bin/env bash
set -uo pipefail
case "${1:-}" in
  auth) exit 0 ;;
  repo) printf 'JonathanPorta/packages.porta.codes\n' ;;
  api) exit 0 ;;
  secret)
    case "${2:-}" in
      list) printf 'BWS_ACCESS_TOKEN\n' ;;
      set) cat >/dev/null; printf 'set %s\n' "$*" >>"$GH_LOG" ;;
    esac ;;
esac
exit 0
FAKE
chmod +x "$BIN/bws" "$BIN/gh"
GH_LOG="$W/gh.log"
: >"$GH_LOG"

idline() { sed -nE "s/^[[:space:]]*([0-9a-fA-F-]{36})[[:space:]]+>[[:space:]]+$1[[:space:]]*\$/\1/p" "$R/$LOADER" | head -1; }
expected_id() { printf '%s' "secret:$(printf '%s' "project:$1" | sha256sum | cut -c1-32 | sed -E 's/(.{8})(.{4})(.{4})(.{4})(.{12})/\1-\2-\3-\4-\5/'):$2" | sha256sum | cut -c1-32 | sed -E 's/(.{8})(.{4})(.{4})(.{4})(.{12})/\1-\2-\3-\4-\5/'; }
# boot PROJECT KEYS [bootstrap args...]
boot() {
  local project="$1" keys="$2"
  shift 2
  (cd "$R" && printf 'y\n' | PATH="$BIN:$PATH" BWS_ACCESS_TOKEN=fake-admin FAKE_PROJECT="$project" FAKE_KEYS="$keys" GH_LOG="$GH_LOG" \
    bash scripts/bws/bootstrap.sh --app-name "$project" --no-secret-values "$@" 2>&1)
}
commit() { git -C "$R" -c user.email=t@t -c user.name=t commit -qam "$1"; }

echo "── row 0: the default (Cloudflare) domain ──"
before_sign="$(idline PACKAGES_REPO_SIGNING_KEY)" before_ingest="$(idline PACKAGES_CANDIDATE_READ_TOKEN)"
out="$(boot packages.porta.codes "CLOUDFLARE_API_TOKEN")"
t="$(idline CLOUDFLARE_API_TOKEN)"
if [ "$t" = "$(expected_id packages.porta.codes CLOUDFLARE_API_TOKEN)" ]; then ok "CLOUDFLARE_API_TOKEN is filled with its minted id"; else
  no "CLOUDFLARE_API_TOKEN not filled (got '$t')"
  printf '%s\n' "$out" | tail -15 | sed 's/^/      /'
fi
if [ "$(idline CLOUDFLARE_ACCOUNT_ID)" = "$SHARED_ACCOUNT_ID" ]; then ok "CLOUDFLARE_ACCOUNT_ID carries the canonical _shared-ci id"; else no "CLOUDFLARE_ACCOUNT_ID is not the shared id"; fi
if [ "$(idline PACKAGES_REPO_SIGNING_KEY)" = "$before_sign" ] && [ "$(idline PACKAGES_CANDIDATE_READ_TOKEN)" = "$before_ingest" ]; then ok "…the other profiles' mappings are untouched"; else no "…another profile's mapping changed"; fi
if grep -Eq '^ *00000000-0000-0000-0000-[0-9a-fA-F]{12} > CLOUDFLARE_(API_TOKEN|ACCOUNT_ID)$' "$R/$LOADER"; then no "the terraform-plan placeholder guard would still refuse the default domain"; else ok "the terraform-plan placeholder guard now passes for the default domain"; fi

echo "── the per-domain checkpoint ──"
out="$(boot packages.porta.codes-repo-signing "PACKAGES_REPO_SIGNING_KEY" --secrets-list .bws/repository-signing.list \
  --project-id-file .bws/repository-signing.env --gh-environments repository-signing)"
if [ "$(idline PACKAGES_REPO_SIGNING_KEY)" = "$before_sign" ] && printf '%s' "$out" | grep -q 'uncommitted changes'; then ok "without the checkpoint, the next domain refuses to edit the uncommitted loader"; else no "the next domain edited an uncommitted loader"; fi
git -C "$R" checkout -q -- .bws/repository-signing.env 2>/dev/null
commit "row 0"
out="$(boot packages.porta.codes-repo-signing "PACKAGES_REPO_SIGNING_KEY" --secrets-list .bws/repository-signing.list \
  --project-id-file .bws/repository-signing.env --gh-environments repository-signing)"
if [ "$(idline PACKAGES_REPO_SIGNING_KEY)" = "$(expected_id packages.porta.codes-repo-signing PACKAGES_REPO_SIGNING_KEY)" ]; then ok "after the checkpoint, row 1 fills PACKAGES_REPO_SIGNING_KEY"; else
  no "row 1 did not fill"
  printf '%s\n' "$out" | tail -8 | sed 's/^/      /'
fi
if [ "$(idline CLOUDFLARE_API_TOKEN)" = "$t" ] && [ "$(idline CLOUDFLARE_ACCOUNT_ID)" = "$SHARED_ACCOUNT_ID" ] && [ "$(idline PACKAGES_CANDIDATE_READ_TOKEN)" = "$before_ingest" ]; then ok "…and leaves the default and candidate-ingest mappings intact"; else no "…row 1 changed another mapping"; fi
commit "row 1"
out="$(boot packages.porta.codes-candidate-ingest "PACKAGES_CANDIDATE_READ_TOKEN" --secrets-list .bws/candidate-ingest.list \
  --project-id-file .bws/candidate-ingest.env --gh-environments candidate-ingest)"
if [ "$(idline PACKAGES_CANDIDATE_READ_TOKEN)" = "$(expected_id packages.porta.codes-candidate-ingest PACKAGES_CANDIDATE_READ_TOKEN)" ]; then ok "row 2 fills PACKAGES_CANDIDATE_READ_TOKEN"; else
  no "row 2 did not fill"
  printf '%s\n' "$out" | tail -8 | sed 's/^/      /'
fi
if [ "$(idline CLOUDFLARE_API_TOKEN)" = "$t" ] && [ "$(idline PACKAGES_REPO_SIGNING_KEY)" = "$(expected_id packages.porta.codes-repo-signing PACKAGES_REPO_SIGNING_KEY)" ]; then ok "…with every earlier mapping intact"; else no "…row 2 changed an earlier mapping"; fi
if grep -q '00000000-0000-0000-0000-000000000000' "$R/$LOADER"; then no "a placeholder remains after all three rows"; else ok "after all three rows the loader holds no placeholder"; fi
if grep -q 'fake-admin' "$GH_LOG"; then no "a token value reached a mutation argument"; else ok "no token value appears in any mutation argument"; fi

echo "bws-loader-bootstrap: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
