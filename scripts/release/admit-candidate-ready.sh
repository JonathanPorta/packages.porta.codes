#!/usr/bin/env bash
# shellcheck disable=SC2016  # jq programs: $-names are jq variables, not shell
# admit-candidate-ready.sh — the trust boundary for a promotion.
#
# THE EVENT IS A SIGNAL, NOT AUTHENTICATION. GitHub authenticates no source
# repository for a repository_dispatch, and github.actor proves nothing about
# the producer. Authority comes from a VERIFIED candidate signature checked
# against an out-of-band trust store, the validated surface declaration read
# from a tracked blob at an explicitly trusted base SHA, an allowlisted
# producer, the exact Release, and equality of every duplicated claim.
#
# Output is a CLOSED BUNDLE plus an admission_id printed on stdout. The manifest
# is NOT a credential: it is a plain file, and its hashes recomputing proves only
# self-consistency. A trusted same-job driver keeps the admission_id and the
# expected base/surface/channel, and passes them to later stages, which re-run
# the whole of admission over the bundle's bytes. The trust store is deliberately
# NOT written into the bundle — a store carried alongside the artifact it
# validates is not a root of trust.
#
# Exit: 0 admitted (admission_id on stdout) | 1 rejected | 2 tooling/usage.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JQ="${JQ_BIN:-jq}"

usage() {
  cat >&2 <<'EOF'
Usage: admit-candidate-ready.sh --event E.json --candidate-dir DIR \
         --receipt R.json --attestation A.json \
         --receiver-repo DIR --receiver-base-sha SHA \
         --surfaces-path PATH --surface-id ID --channel CH \
         [--renderer-config-path PATH] \
         --trust-store STORE.json --signing-dir DIR \
         --bundle-out DIR

Prints the admission_id on stdout. Admission requires a verified candidate
signature; there is no non-actionable mode. Exit 0 = admitted; 1 = rejected; 2 = tooling/usage.
EOF
  exit 2
}

event="" cdir="" receipt="" attest="" repo="" base_sha="" spath="" rcpath=""
surface_id="" channel="" store="" signing_dir="" bout=""
while [ $# -gt 0 ]; do
  case "$1" in
    --event)
      event="${2:-}"
      shift 2
      ;;
    --candidate-dir)
      cdir="${2:-}"
      shift 2
      ;;
    --receipt)
      receipt="${2:-}"
      shift 2
      ;;
    --attestation)
      attest="${2:-}"
      shift 2
      ;;
    --receiver-repo)
      repo="${2:-}"
      shift 2
      ;;
    --receiver-base-sha)
      base_sha="${2:-}"
      shift 2
      ;;
    --surfaces-path)
      spath="${2:-}"
      shift 2
      ;;
    --renderer-config-path)
      rcpath="${2:-}"
      shift 2
      ;;
    --surface-id)
      surface_id="${2:-}"
      shift 2
      ;;
    --channel)
      channel="${2:-}"
      shift 2
      ;;
    --trust-store)
      store="${2:-}"
      shift 2
      ;;
    --signing-dir)
      signing_dir="${2:-}"
      shift 2
      ;;
    --bundle-out)
      bout="${2:-}"
      shift 2
      ;;
    -h | --help) usage ;;
    *)
      printf 'admit: unexpected arg: %s\n' "$1" >&2
      usage
      ;;
  esac
done
for r in "$event" "$cdir" "$receipt" "$attest" "$repo" "$base_sha" "$spath" "$surface_id" "$channel" "$bout"; do
  [ -n "$r" ] || usage
done
die() {
  printf 'admit: %s\n' "$1" >&2
  exit 2
}
reject() {
  printf 'admit: REJECT %s\n' "$1" >&2
  exit 1
}
command -v "$JQ" >/dev/null 2>&1 || die "jq not found"
command -v git >/dev/null 2>&1 || die "git not found"
if [ -z "$store" ] || [ -z "$signing_dir" ]; then
  die "--trust-store and --signing-dir are required; admission has no unsigned path"
fi
printf '%s' "$base_sha" | grep -Eq '^[0-9a-f]{40}$' || die "--receiver-base-sha must be a full 40-hex commit sha"
[ -d "$repo/.git" ] || die "receiver repo is not a git checkout: $repo"

# shellcheck source=scripts/release/lib/admission-lib.sh
. "$HERE/lib/admission-lib.sh" || die "admission library failed to source"

tmp="$(mktemp -d)" || die "cannot create temp dir"
trap 'rm -rf "$tmp"' EXIT INT TERM HUP
snap="$tmp/snap"
mkdir -p "$snap"

# ── normalize declared paths; equality is on the whole path, not a basename ──
norm_path() { printf '%s' "$1" | sed -E 's#^\./##; s#//+#/#g; s#/$##'; }
spath="$(norm_path "$spath")"
case "$spath" in /* | *..*) die "--surfaces-path must be a relative path without traversal" ;; esac
[ -z "$rcpath" ] || {
  rcpath="$(norm_path "$rcpath")"
  case "$rcpath" in /* | *..*) die "--renderer-config-path must be a relative path without traversal" ;; esac
}

# ── snapshot the closed input set FIRST, under fixed names ──────────────────
git -C "$repo" cat-file -e "${base_sha}^{commit}" 2>/dev/null ||
  reject "trusted base $base_sha is not in the receiver repository"
adm_copy_regular "$event" "$snap/$ADM_EVENT" || exit $?
adm_copy_regular "$receipt" "$snap/$ADM_RECEIPT" || exit $?
adm_copy_regular "$attest" "$snap/$ADM_ATTEST" || exit $?
adm_snapshot_candidate_dir "$cdir" "$snap/$ADM_CANDDIR" || exit $?
adm_copy_regular "$store" "$snap/$ADM_STORE" || exit $?
adm_blob_at "$repo" "$base_sha" "$spath" "$snap/$ADM_SURFACES" || exit $?

# The policy path is taken from the DECLARATION and must equal what the caller
# named, so a differently-located file with the same basename cannot substitute.
"${YQ_BIN:-yq}" -o=json '.' "$snap/$ADM_SURFACES" >"$tmp/s.json" 2>/dev/null ||
  die "cannot read the surface declaration at $base_sha"
sel="$("$JQ" -c --arg id "$surface_id" '.surfaces[] | select(.id == $id)' "$tmp/s.json")"
[ -n "$sel" ] || reject "surface '$surface_id' is not declared at $base_sha"
declared_rc="$(printf '%s' "$sel" | "$JQ" -r '[.promotion_outputs[] | select(.role == "downloads-index") | .renderer_config // empty] | first // ""')"
declared_rc="$(norm_path "$declared_rc")"
if [ -n "$declared_rc" ] && [ -z "$rcpath" ]; then
  reject "surface declares renderer_config '$declared_rc' but no --renderer-config-path was supplied"
elif [ -n "$rcpath" ] && [ -z "$declared_rc" ]; then
  reject "--renderer-config-path supplied for a surface that declares none"
elif [ -n "$rcpath" ] && [ "$rcpath" != "$declared_rc" ]; then
  reject "supplied policy path '$rcpath' is not the declared '$declared_rc' — equality is on the whole relative path, so a same-named file elsewhere in the tree does not qualify"
fi
[ -z "$declared_rc" ] || adm_blob_at "$repo" "$base_sha" "$declared_rc" "$snap/$ADM_POLICY" || exit $?

# ── run the shared admission semantics over the snapshot ───────────────────
adm_verify_snapshot "$snap" "$repo" "$signing_dir" "$base_sha" "$surface_id" "$channel" || exit $?

# ── emit the bundle ATOMICALLY, from the SNAPSHOT, never the sources ──────
# Merging into an existing directory could report ADMITTED while retaining
# pre-existing stowaways, and a late failure could leave a partial bundle for a
# later stage to read.
# `! -e` alone passes for a DANGLING symlink, which `mv` would then replace —
# publishing the bundle through a link the caller controls.
if [ -e "$bout" ] || [ -L "$bout" ]; then
  die "--bundle-out must not exist (a dangling symlink counts); the bundle is published by a single rename"
fi
bparent="$(dirname "$bout")"
mkdir -p "$bparent" || die "cannot create the bundle parent directory"
# A predictable name plus `rm -rf` would delete a pre-existing sibling that
# merely happened to match. mktemp creates a fresh directory it owns.
bstage="$(mktemp -d "$bparent/.admit-bundle.XXXXXX")" || die "cannot create the bundle staging directory"
cleanup_stage() { rm -rf "$bstage"; }
cp -R "$snap/$ADM_CANDDIR" "$bstage/$ADM_CANDDIR" || {
  cleanup_stage
  die "cannot write candidate into the bundle"
}
for f in "$ADM_EVENT" "$ADM_RECEIPT" "$ADM_ATTEST" "$ADM_SURFACES"; do
  cp "$snap/$f" "$bstage/$f" || {
    cleanup_stage
    die "cannot write $f into the bundle"
  }
done
[ ! -f "$snap/$ADM_POLICY" ] || cp "$snap/$ADM_POLICY" "$bstage/$ADM_POLICY" || {
  cleanup_stage
  die "cannot write the policy"
}
# The trust store is deliberately NOT written into the bundle.
cand="$bstage/$ADM_CANDDIR/release-candidate.json"
rc_commit='{"none":true}'
[ -z "$declared_rc" ] || rc_commit="$("$JQ" -n --arg p "$declared_rc" --arg s "$(adm_d "$snap/$ADM_POLICY")" '{path:$p,sha256:$s}')"

"$JQ" -n -S --slurpfile c "$cand" --slurpfile r "$snap/$ADM_RECEIPT" \
  --arg sid "$surface_id" --arg ch "$channel" \
  --arg repo "$(printf '%s' "$sel" | "$JQ" -r .owner_repo)" --arg base "$base_sha" \
  --arg ev "$(adm_d "$snap/$ADM_EVENT")" --arg cd "$(adm_d "$cand")" \
  --arg cs "$(adm_d "$bstage/$ADM_CANDDIR/release-candidate.json.sig")" \
  --arg rd "$(adm_d "$snap/$ADM_RECEIPT")" --arg ad "$(adm_d "$snap/$ADM_ATTEST")" \
  --arg sp "$spath" --arg ss "$(adm_d "$snap/$ADM_SURFACES")" --argjson rcc "$rc_commit" \
  --arg ts "$(adm_d "$snap/$ADM_STORE")" '
  {
    schema: "blessed/admitted-bundle/v1",
    selected: { surface_id: $sid, channel: $ch },
    identity: {
      project: $c[0].project, component: $c[0].component, version: $c[0].version,
      tag: $c[0].tag, producer_repo: $c[0].producer_repo, producer_sha: $c[0].source_sha,
      release_id: $r[0].release_id, published_at: $r[0].published_at,
      candidate_created_at: $c[0].created_at
    },
    receiver: { repo: $repo, base_sha: $base },
    commitments: {
      event: $ev, candidate: $cd, candidate_signature: $cs,
      receipt: $rd, attestation: $ad,
      surfaces: { path: $sp, sha256: $ss },
      renderer_config: $rcc,
      trust_store: $ts
    },
    signature_verification: { verified: true, profile: $c[0].signing.profile, key_id: $c[0].signing.key_id }
  }' >"$tmp/pre.json" || die "cannot build the bundle manifest"

aid="$(adm_admission_id "$tmp/pre.json")"
"$JQ" -S --arg a "$aid" '.admission_id = $a' "$tmp/pre.json" >"$bstage/$ADM_MANIFEST" ||
  {
    cleanup_stage
    die "cannot write the bundle manifest"
  }
[ -z "${PROMOTION_FAIL_BEFORE_BUNDLE:-}" ] || {
  cleanup_stage
  die "injected failure before bundle publication (verification hook)"
}

# ── closure: exactly the expected entries, top level and candidate dir ───
{
  printf '%s\n' "$ADM_MANIFEST" "$ADM_EVENT" "$ADM_RECEIPT" "$ADM_ATTEST" "$ADM_SURFACES" "$ADM_CANDDIR"
  [ ! -f "$bstage/$ADM_POLICY" ] || printf '%s\n' "$ADM_POLICY"
} | sort >"$tmp/expect-top"
(cd "$bstage" && find . -mindepth 1 -maxdepth 1 | sed 's#^\./##') | sort >"$tmp/actual-top"
if ! cmp -s "$tmp/expect-top" "$tmp/actual-top"; then
  diff "$tmp/expect-top" "$tmp/actual-top" | sed 's/^/admit:   /' >&2
  cleanup_stage
  die "the assembled bundle does not have exactly the expected top-level entries"
fi
{
  printf 'release-candidate.json\nrelease-candidate.json.sig\n'
  "$JQ" -r '.files[].name' "$cand"
} | sort -u >"$tmp/expect-cand"
(cd "$bstage/$ADM_CANDDIR" && find . -mindepth 1 -maxdepth 1 | sed 's#^\./##') | sort >"$tmp/actual-cand"
if ! cmp -s "$tmp/expect-cand" "$tmp/actual-cand"; then
  diff "$tmp/expect-cand" "$tmp/actual-cand" | sed 's/^/admit:   /' >&2
  cleanup_stage
  die "the assembled candidate directory is not the closed candidate set"
fi

mv "$bstage" "$bout" || {
  cleanup_stage
  die "cannot publish the bundle"
}

# Read from the PUBLISHED bundle: $cand pointed into the staging directory,
# which the rename above has already moved.
printf 'admit: ADMITTED %s %s -> surface %s channel %s (bundle %s)\n' \
  "$("$JQ" -r .project "$bout/$ADM_CANDDIR/release-candidate.json")" \
  "$("$JQ" -r .tag "$bout/$ADM_CANDDIR/release-candidate.json")" \
  "$surface_id" "$channel" "$(printf '%s' "$aid" | cut -c1-12)" >&2
printf '%s\n' "$aid"
exit 0
