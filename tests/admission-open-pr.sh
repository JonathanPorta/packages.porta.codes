#!/usr/bin/env bash
# admission-open-pr.sh — scripts/surface/admission-open-pr.sh against a fake
# GitHub (tests/fixtures/fake-gh.sh): a fresh admission and an interrupted one
# are proposed; an exact retry is a no-op that writes nothing; a branch or PR
# that is anything but exactly this admission is refused before any write.
# shellcheck disable=SC2016 # jq programs, not shell
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
mkdir -p "$W/bin"
ln -s "$ROOT/tests/fixtures/fake-gh.sh" "$W/bin/gh"
BR="admit/corpus-v1.2.3"
M1=1111111111111111111111111111111111111111
printf '{"packages":["a"]}\n' >"$W/inv-a.json"
printf '{"packages":["b"]}\n' >"$W/inv-b.json"
echo "admitted" >"$W/admission.log"

# setup NAME → a fresh fake repository: main at M1 holding an older inventory
setup() {
  S="$W/$1"
  mkdir -p "$S/refs" "$S/commits" "$S/compare" "$S/contents"
  echo "$M1" >"$S/refs/main"
  jq -n '{sha: "m1", parents: [{sha: "m0"}]}' >"$S/commits/$M1.json"
  jq -n '{status: "identical", files: []}' >"$S/compare/$M1...main.json"
  jq -n --arg c "$(printf '{"packages":[]}\n' | base64 | tr -d '\n')" '{content: $c, sha: "blob-m1"}' >"$S/contents/$M1.json"
  echo '[]' >"$S/prs.json"
  : >"$S/mutations.log"
}
# run [INVENTORY] → runs the script against $S; sets rc and out
run() {
  out="$(FAKE_GH="$S" PATH="$W/bin:$PATH" GH_TOKEN=fake SELF=o/packages.porta.codes REPO=o/corpus TAG=v1.2.3 \
    BASE_SHA="$M1" INVENTORY="${1:-$W/inv-a.json}" ADMISSION_LOG="$W/admission.log" \
    bash "$ROOT/scripts/surface/admission-open-pr.sh" 2>&1)"
  rc=$?
}
head_sha() { cat "$S/refs/$BR"; }
# admitted NAME → setup NAME, then a first run that proposes it; N = its commit
admitted() {
  setup "$1"
  run
  N="$(head_sha)"
  jq -n '{status: "behind", files: []}' >"$S/compare/$N...main.json"
  jq -n --arg h "$BR" --arg n "$N" '[{number: 7, headRefName: $h, baseRefName: "main", headRefOid: $n, isCrossRepository: false}]' >"$S/prs.json"
  : >"$S/mutations.log"
}
# refused LABEL PATTERN → rc 1, PATTERN in the output, and nothing written
refused() {
  if [ "$rc" = 1 ] && grep -q -- "$2" <<<"$out" && [ ! -s "$S/mutations.log" ]; then ok "$1 → refused, nothing written"; else
    no "$1 (rc=$rc, mutations: $(tr '\n' ';' <"$S/mutations.log"))"
    printf '%s\n' "$out" | sed 's/^/      /'
  fi
}

echo "── proposed ──"
setup fresh
run
if [ "$rc" = 0 ] && [ "$(cut -d' ' -f1 "$S/mutations.log" | tr '\n' ' ')" = "create-ref commit create-pr " ] &&
  [ "$(jq -r .content "$S/contents/$(head_sha).json" | base64 -d | sha256sum)" = "$(sha256sum <"$W/inv-a.json")" ]; then
  ok "a fresh admission: branch from main, one inventory commit, one PR"
else no "a fresh admission (rc=$rc): $out"; fi

setup resume
mkdir -p "$S/refs/admit"
echo "$M1" >"$S/refs/$BR"
run
if [ "$rc" = 0 ] && [ "$(cut -d' ' -f1 "$S/mutations.log" | tr '\n' ' ')" = "commit create-pr " ]; then
  ok "an interrupted admission (branch still at main) is resumed: commit, then PR"
else no "an interrupted admission (rc=$rc): $out"; fi

echo "── an exact retry ──"
admitted retry
run
if [ "$rc" = 0 ] && [ ! -s "$S/mutations.log" ] && grep -q "PR #7 already proposes exactly this admission" <<<"$out"; then
  ok "the same branch and PR again → no-op, nothing written"
else no "an exact retry (rc=$rc, mutations: $(tr '\n' ';' <"$S/mutations.log")): $out"; fi

echo "── a branch that is not exactly this admission ──"
admitted extra-file
jq '.files += [{status: "modified", filename: ".github/workflows/publish.yml"}]' "$S/compare/$M1...$N.json" >"$S/x" && mv "$S/x" "$S/compare/$M1...$N.json"
echo '[]' >"$S/prs.json"
run
refused "the admitted inventory plus a changed workflow" "changes more than inventory/inventory.json"

admitted second-commit
E=eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
jq -n --arg n "$N" '{sha: "e", parents: [{sha: $n}]}' >"$S/commits/$E.json"
jq -n '{status: "diverged", files: []}' >"$S/compare/$E...main.json"
echo "$E" >"$S/refs/$BR"
run
refused "a second commit on top of the admission" "which is not on main"

admitted merge-commit
jq -n '{sha: "n", parents: [{sha: "p1"}, {sha: "p2"}]}' >"$S/commits/$N.json"
run
refused "a merge commit as the branch head" "not a single-parent commit"

admitted other-inventory
run "$W/inv-b.json"
refused "the branch holds a different inventory" "DIFFERENT inventory"

echo "── a PR that is not exactly this admission ──"
admitted wrong-base
jq '.[0].baseRefName = "release"' "$S/prs.json" >"$S/x" && mv "$S/x" "$S/prs.json"
run
refused "an open PR into another base" "not main"

admitted wrong-head
jq '.[0].headRefOid = "deadbeef"' "$S/prs.json" >"$S/x" && mv "$S/x" "$S/prs.json"
run
refused "an open PR at another head commit" "not the admission commit"

admitted fork
jq '.[0].isCrossRepository = true' "$S/prs.json" >"$S/x" && mv "$S/x" "$S/prs.json"
run
refused "an open PR from a fork with the same branch name" "from another repository"

admitted two-prs
jq '. += [.[0] | .number = 8]' "$S/prs.json" >"$S/x" && mv "$S/x" "$S/prs.json"
run
refused "two open PRs for the branch" "several open PRs"

echo "admission-open-pr: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
