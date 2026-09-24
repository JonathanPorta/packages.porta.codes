#!/usr/bin/env bash
# shellcheck disable=SC2016  # jq programs: $-names are jq variables, not shell
# apply-promotion-pr.sh — decide the promotion state and upsert exactly one PR.
#
# Apply trusts nothing it is handed. It re-runs admission over the bundle,
# independently RE-RENDERS every output from those verified inputs, and compares
# the supplied manifest and every byte before touching the repository. A
# hand-edited rendered file is uncommittable.
#
# States: up-to-date | behind | adopt-open-pr | stale-open-pr | conflict |
#         unattested | dirty
#
# Exit: 0 up-to-date/adopt-open-pr/behind | 1 stopped | 2 tooling/usage.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JQ="${JQ_BIN:-jq}"

bundle="" repo="" rendered="" prs="" signing_dir="" store="" adapter="" push=0
recover_from=""
surface_manifest=""
exp_id="" exp_base="" exp_surface="" exp_channel="" base_ref=""
while [ $# -gt 0 ]; do
  case "$1" in
    --bundle-dir)
      bundle="${2:-}"
      shift 2
      ;;
    --receiver-repo)
      repo="${2:-}"
      shift 2
      ;;
    --rendered)
      rendered="${2:-}"
      shift 2
      ;;
    --surface-manifest)
      surface_manifest="${2:-}"
      shift 2
      ;;
    --pr-state)
      prs="${2:-}"
      shift 2
      ;;
    --signing-dir)
      signing_dir="${2:-}"
      shift 2
      ;;
    --trust-store)
      store="${2:-}"
      shift 2
      ;;
    --expected-admission-id)
      exp_id="${2:-}"
      shift 2
      ;;
    --expected-base-sha)
      exp_base="${2:-}"
      shift 2
      ;;
    --expected-surface-id)
      exp_surface="${2:-}"
      shift 2
      ;;
    --expected-channel)
      exp_channel="${2:-}"
      shift 2
      ;;
    --base-ref)
      base_ref="${2:-}"
      shift 2
      ;;
    --adapter)
      adapter="${2:-}"
      shift 2
      ;;
    --publish)
      push=1
      shift
      ;;
    *)
      printf 'apply: unexpected arg: %s\n' "$1" >&2
      exit 2
      ;;
  esac
done
state() { printf 'apply: STATE %s — %s\n' "$1" "$2" >&2; }
stop() {
  state "$1" "$2"
  exit 1
}
die() {
  printf 'apply: %s\n' "$1" >&2
  exit 2
}
for r in "$bundle" "$repo" "$rendered" "$prs" "$signing_dir" "$store" "$exp_id" "$exp_base" "$exp_surface" "$exp_channel" "$base_ref"; do
  [ -n "$r" ] || die "--bundle-dir --receiver-repo --rendered --pr-state --signing-dir --trust-store --expected-* and --base-ref are all required (--pr-state is mandatory even when empty: 'no snapshot' and 'no PR' are different facts)"
done
command -v "$JQ" >/dev/null 2>&1 || die "jq not found"
command -v git >/dev/null 2>&1 || die "git not found"
[ -d "$repo/.git" ] || die "receiver repo is not a git checkout: $repo"

# shellcheck source=scripts/release/lib/promotion-lib.sh
. "$HERE/lib/promotion-lib.sh" || die "promotion library failed to source"
# shellcheck source=scripts/release/lib/bundle-verify.sh
. "$HERE/lib/bundle-verify.sh" || die "bundle verifier failed to source"
# shellcheck source=scripts/release/lib/lib-json-schema.sh
. "$HERE/lib/lib-json-schema.sh" || die "schema library failed to source"

tmp="$(mktemp -d)" || die "cannot create temp dir"
trap 'rm -rf "$tmp"' EXIT INT TERM HUP
snap="$tmp/snap"
bundle_verify "$bundle" "$snap" "$signing_dir" "$repo" "$store" \
  "$exp_id" "$exp_base" "$exp_surface" "$exp_channel" || exit $?

# VERIFICATION HOOK (tests only). Rewrites the SOURCE bundle after the snapshot
# has been taken, to prove nothing downstream reads $bundle again. The library
# snapshots the closed set precisely so a caller cannot swap inputs afterwards,
# and this stage once read $bundle/receipt.json past that boundary — making a
# replaceable file the authority for consumer-visible release metadata.
if [ -n "${PROMOTION_MUTATE_SOURCE_AFTER_SNAPSHOT:-}" ] && [ -f "$bundle/receipt.json" ]; then
  "$JQ" '.published_at = "1999-01-01T00:00:00Z"' "$bundle/receipt.json" >"$bundle/.r.tmp" &&
    mv "$bundle/.r.tmp" "$bundle/receipt.json"
fi

man="$snap/bundle.json"
cand="$snap/candidate-dir/release-candidate.json"
sel="$snap/.sel.json"
owner_repo="$("$JQ" -r '.receiver.repo' "$man")"
version="$("$JQ" -r '.identity.version' "$man")"
tag="$("$JQ" -r '.identity.tag' "$man")"
project="$("$JQ" -r '.identity.project' "$man")"
producer_sha="$("$JQ" -r '.identity.producer_sha' "$man")"
cand_digest="$("$JQ" -r '.commitments.candidate' "$man")"
transport="$("$JQ" -r '.promotion_transport // "unknown"' "$sel")"
# PROMOTION AUTHORITY: the COMPLETE admitted decision, with exactly two
# exclusions, each for a stated reason:
#   - commitments.event — a repository_dispatch is a wake signal, and a
#     legitimate replay arrives on a different one;
#   - receiver.base_sha — the trusted base advances once a promotion merges.
# Everything else is included, INCLUDING the committed PATHS of the surface
# declaration and renderer policy. Hashing only their digests meant two
# byte-identical declarations at different tracked paths shared one authority,
# so adoption would accept the wrong configuration identity.
authority="$("$JQ" -S -c '{
  selected: .selected,
  identity: .identity,
  receiver: { repo: .receiver.repo },
  commitments: (.commitments | del(.event)),
  signature_verification: .signature_verification
}' "$man" | shasum -a 256 | awk '{print $1}')"
lc() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# ── 1. the receiver must BE the declared repo, at the trusted base, clean ──
# An absent origin is a failure to establish identity, never permission to skip
# the check: an unidentified checkout could be any repository at all.
url="$(git -C "$repo" remote get-url origin 2>/dev/null || printf '')"
[ -n "$url" ] || stop dirty "receiver checkout has no origin remote, so its identity cannot be established"
# The URL must MATCH an accepted GitHub form. Stripping known prefixes and
# accepting whatever remains lets a bare "owner/repo" string — or a local path
# ending in one — normalize into a valid GitHub identity.
norm=""
case "$url" in
  https://github.com/*/*) norm="${url#https://github.com/}" ;;
  git@github.com:*/*) norm="${url#git@github.com:}" ;;
  ssh://git@github.com/*/*) norm="${url#ssh://git@github.com/}" ;;
  *) stop dirty "origin '$url' is not an accepted GitHub remote form (https://github.com/o/r, git@github.com:o/r, ssh://git@github.com/o/r)" ;;
esac
norm="$(lc "${norm%.git}")"
case "$norm" in
  */*/*) stop dirty "origin '$url' does not name a single owner/repo" ;;
esac
[ "$norm" = "$(lc "$owner_repo")" ] || stop dirty "receiver checkout is $norm but the surface declares $owner_repo"
head_sha="$(git -C "$repo" rev-parse HEAD 2>/dev/null || printf '')"
[ "$head_sha" = "$exp_base" ] || stop dirty "receiver HEAD is $head_sha but the admitted trusted base is $exp_base"
[ "$(git -C "$repo" rev-parse --verify --quiet "$base_ref" 2>/dev/null || printf '')" = "$exp_base" ] ||
  stop dirty "the trusted base ref '$base_ref' does not resolve to $exp_base"
if [ -n "$(git -C "$repo" status --porcelain --untracked-files=all 2>/dev/null)" ]; then
  git -C "$repo" status --porcelain --untracked-files=all | head -5 | sed 's/^/apply:   /' >&2
  stop dirty "receiver checkout has staged, unstaged, or untracked changes"
fi

# ── 2. independently re-render and compare ───────────────────────────────
[ -f "$rendered/render-manifest.json" ] || die "rendered directory carries no render-manifest.json"
vout="$(json_schema_validate_file "$rendered/render-manifest.json" "$HERE/references/render-manifest.schema.json")"
[ -z "$vout" ] || {
  printf '%s\n' "$vout" | sed 's/^/apply: manifest INVALID /' >&2
  die "render manifest does not conform"
}
[ "$("$JQ" -r '.admission_id' "$rendered/render-manifest.json")" = "$exp_id" ] ||
  stop conflict "render manifest was produced for a different admission"
rr="$tmp/rerender"
bash "$HERE/render-promotion.sh" --bundle-dir "$bundle" --receiver-repo "$repo" --outdir "$rr" \
  --signing-dir "$signing_dir" --trust-store "$store" --expected-admission-id "$exp_id" \
  --expected-base-sha "$exp_base" --expected-surface-id "$exp_surface" \
  --expected-channel "$exp_channel" >"$tmp/rr.log" 2>&1 || {
  sed 's/^/apply: /' "$tmp/rr.log" >&2
  stop conflict "independent re-render did not succeed"
}
"$JQ" -S . "$rr/render-manifest.json" >"$tmp/a.json"
"$JQ" -S . "$rendered/render-manifest.json" >"$tmp/b.json"
cmp -s "$tmp/a.json" "$tmp/b.json" || stop conflict "supplied render manifest does not equal an independent re-render"

PATHS=()
while IFS= read -r _p; do [ -n "$_p" ] && PATHS+=("$_p"); done \
  < <("$JQ" -r '.outputs[].repo_path' "$rr/render-manifest.json")
[ "${#PATHS[@]}" -gt 0 ] || die "re-render produced no outputs"
for p in "${PATHS[@]}"; do
  cmp -s "$rr/$p" "$rendered/$p" ||
    stop conflict "supplied $p does not equal the independently re-rendered bytes — a hand-edited output is not committable"
done
extra="$(cd "$rendered" && find . -type f ! -name render-manifest.json | sed 's#^\./##' | sort)"
want="$(printf '%s\n' "${PATHS[@]}" | sort)"
[ "$extra" = "$want" ] || stop conflict "the rendered directory contains files the render manifest does not declare"

# ── 3. destination preflight ────────────────────────────────────────────
declared="$("$JQ" -r --arg ch "$exp_channel" '[.promotion_outputs[] | select((.channel // $ch) == $ch) | .repo_path] | sort | .[]' "$sel")"
# Membership is not enough: the rendered set must BE the complete selected set,
# or apply would happily commit a surface missing one of its declared outputs.
[ "$(printf '%s\n' "${PATHS[@]}" | sort)" = "$(printf '%s\n' "$declared" | sort)" ] || {
  printf 'apply: declared %s\n' "$(printf '%s' "$declared" | tr '\n' ' ')" >&2
  printf 'apply: rendered %s\n' "$(printf '%s\n' "${PATHS[@]}" | tr '\n' ' ')" >&2
  stop conflict "the rendered outputs are not the complete selected output set for channel '$exp_channel'"
}
protected="$("$JQ" -r '.commitments.surfaces.path' "$man")
$("$JQ" -r '.commitments.renderer_config.path // empty' "$man")"
repo_real="$(cd "$repo" && pwd -P)"
for p in "${PATHS[@]}"; do
  case "$p" in
    /* | *..* | *\\*) stop dirty "destination '$p' is absolute or contains traversal" ;;
  esac
  printf '%s\n' "$declared" | grep -qxF "$p" ||
    stop dirty "'$p' is not a declared output for channel '$exp_channel'"
  # Case-insensitively: on a case-insensitive filesystem a differently-cased
  # path is the SAME file, so a case variant would overwrite its own authority.
  if printf '%s\n' "$protected" | tr '[:upper:]' '[:lower:]' | grep -qxF "$(lc "$p")"; then
    stop dirty "'$p' is the surface declaration or renderer policy; generated output may never overwrite its own authority"
  fi
  d="$p"
  while [ "$d" != "." ] && [ "$d" != "/" ]; do
    t="$repo/$d"
    [ -L "$t" ] && stop dirty "'$d' is a symlink; a promotion must not write through one"
    if [ -e "$t" ] && [ ! -d "$t" ] && [ ! -f "$t" ]; then stop dirty "'$d' is not a regular file or directory"; fi
    # A submodule's .git may be a FILE (gitfile) rather than a directory.
    if [ -e "$t/.git" ] && [ "$(cd "$t" && pwd -P)" != "$repo_real" ]; then
      stop dirty "'$d' is a nested repository or submodule"
    fi
    case "$(git -C "$repo" ls-tree "$exp_base" -- "$d" | awk '{print $1}')" in
      160000) stop dirty "'$d' is a gitlink (submodule) at the trusted base" ;;
      120000) stop dirty "'$d' is a symlink at the trusted base" ;;
    esac
    d="$(dirname "$d")"
  done
  coll="$(printf '%s\n' "${PATHS[@]}" | tr '[:upper:]' '[:lower:]' | grep -cxF "$(lc "$p")")"
  [ "$coll" = "1" ] || stop dirty "'$p' collides with another declared output under case-insensitive comparison"
  # On a case-insensitive filesystem a differently-cased TRACKED path is the
  # same file, so writing this output would silently replace it.
  # Permit zero tracked matches (a new path) or exactly one whose spelling IS
  # this path. An exact match PLUS a differently-cased variant is still a
  # collision — the previous check accepted that pair merely because the exact
  # spelling existed.
  git -C "$repo" ls-tree -r --name-only "$exp_base" |
    while IFS= read -r tp; do [ "$(lc "$tp")" = "$(lc "$p")" ] && printf '%s\n' "$tp"; done >"$tmp/tmatch"
  tmatch="$(cat "$tmp/tmatch")"
  # `grep -c` prints 0 AND exits 1 with no matches, so `|| printf 0` would
  # append a second zero and every path would look like a collision.
  tn="$(awk 'END{print NR}' <"$tmp/tmatch")"
  case "$tn" in
    0) : ;;
    1) [ "$tmatch" = "$p" ] || stop dirty "'$p' case-collides with tracked path '$tmatch' at the trusted base" ;;
    *) stop dirty "'$p' case-collides with $tn tracked paths at the trusted base: $(printf '%s' "$tmatch" | tr '\n' ' ')" ;;
  esac
done

# ── 4. publication must cover the EXACT required object set ─────────────
base_url="$("$JQ" -r '.public_base_url' "$sel")"
relprefix="$("$JQ" -r '.immutable_release_prefix' "$sel")"
prefix="${base_url}${relprefix}${tag}/"
origin="$(printf '%s' "$base_url" | sed -E 's#^(https?://[^/]+).*#\1#')"
attest="$snap/attestation.json"
vout="$(json_schema_validate_file "$attest" "$HERE/references/publication-attestation.schema.json")"
[ -z "$vout" ] || {
  printf '%s\n' "$vout" | sed 's/^/apply: attestation INVALID /' >&2
  stop unattested "attestation does not conform"
}
[ "$("$JQ" -r '.complete' "$attest")" = "true" ] || stop unattested "attestation is not complete"
[ "$("$JQ" -r '.candidate_sha256' "$attest")" = "$cand_digest" ] || stop unattested "attestation covers a different candidate"
if [ "$("$JQ" -r '.surface_id' "$attest")" != "$exp_surface" ] || [ "$("$JQ" -r '.channel' "$attest")" != "$exp_channel" ]; then
  stop unattested "attestation is for a different surface or channel"
fi
[ "$("$JQ" -r '.immutable_prefix_url' "$attest")" = "$prefix" ] ||
  stop unattested "attestation prefix is not this promotion's $prefix"

# The published candidate is the producer's ENVELOPE — release-candidate.json
# and its detached signature — plus every files[] payload. Omitting the
# signature would publish a manifest nobody downstream can verify.
#
# THE ENVELOPE IS NOT manifest.json. This required the envelope at
# `${prefix}manifest.json`, carrying the CANDIDATE's digest, plus a
# `manifest.json.sig` that no contract defines. Both are wrong:
# candidate.md names `manifest.json` as the SURFACE manifest, authored by the
# SURFACE OWNER — "where validated bytes are public: canonical URLs, surface
# id, publication time, channel context" — a different document from the
# producer's candidate manifest, and one the standard never says is signed.
#
# A conforming receiver therefore publishes three things this check could not
# reconcile: the envelope under its own name, its signature, and a surface
# manifest whose digest is legitimately NOT the candidate's. It refused the
# real DocSort v0.4.4 publication with
#   published .../manifest.json has digest 82622cce…, candidate says 04f79c18…
#   missing published object .../manifest.json.sig
#   unexpected attested object .../release-candidate.json
# — three symptoms of one naming error, after the candidate had already been
# validated and published.
#
# The surface manifest is REQUIRED to be present (a promotion that published no
# surface manifest would leave consumers without canonical URLs) but its bytes
# are the surface owner's, so only its presence is required here, not a digest
# the producer could not have known.
"$JQ" -r --arg pre "$prefix" '[.files[] | {url: ($pre + .name), sha256, size}]' "$cand" >"$tmp/req0.json" ||
  die "cannot derive the required object set from the signed candidate"
sig="$snap/candidate-dir/release-candidate.json.sig"
"$JQ" -n --slurpfile r "$tmp/req0.json" \
  --arg mu "${prefix}release-candidate.json" --arg ms "$cand_digest" --argjson mz "$(wc -c <"$cand" | tr -d ' ')" \
  --arg su "${prefix}release-candidate.json.sig" --arg ss "$("$JQ" -r '.commitments.candidate_signature' "$man")" \
  --argjson sz "$(wc -c <"$sig" | tr -d ' ')" \
  '$r[0] + [{url:$mu,sha256:$ms,size:$mz}, {url:$su,sha256:$ss,size:$sz}]' >"$tmp/req.json" ||
  die "cannot derive the required object set"
# ── the SURFACE manifest is VALIDATED and BOUND, never merely present ─────
# manifest_url names this document (owner decision, 2026-09-19), so a consumer
# following the channel contract reads it. It is not signed, so presence at a
# URL is not acceptance: without binding, the applier would authorize a pointer
# to bytes whose schema and candidate relationship it never checked.
#
# Three things are required, and each closes a hole the others leave open:
#   1. its BYTES match the digest the publication evidence recorded — a
#      self-declared digest inside the document proves nothing;
#   2. it CONFORMS to blessed/public-download-manifest/v1;
#   3. its CONTENT is bound to the admitted, signature-verified candidate —
#      release identity, every projected artifact's identity/size/hash, and the
#      canonical URL mapping. An internally consistent document that projects a
#      DIFFERENT candidate must fail here.
surface_manifest_url="${prefix}manifest.json"
att_sm="$("$JQ" -r --arg u "$surface_manifest_url" \
  '[.objects[] | select(.url == $u)] | if length == 1 then .[0] | "\(.sha256) \(.size)" else "" end' "$attest")"
[ -n "$att_sm" ] ||
  stop unattested "the publication evidence does not record exactly one $surface_manifest_url"
att_sm_sha="${att_sm%% *}" att_sm_size="${att_sm##* }"

[ -n "$surface_manifest" ] ||
  stop unattested "--surface-manifest is required: the surface manifest cannot be accepted on the publication evidence alone, because that records only its digest and size"
[ -f "$surface_manifest" ] || die "--surface-manifest not found: $surface_manifest"

# 1. bytes vs the trusted publication evidence
sm_sha="$(shasum -a 256 "$surface_manifest" | awk '{print $1}')"
sm_size="$(wc -c <"$surface_manifest" | tr -d ' ')"
[ "$sm_sha" = "$att_sm_sha" ] ||
  stop unattested "the supplied surface manifest digest $sm_sha is not the published $att_sm_sha"
[ "$sm_size" = "$att_sm_size" ] ||
  stop unattested "the supplied surface manifest is $sm_size bytes, the published object is $att_sm_size"

# 2. schema
smout="$(json_schema_validate_file "$surface_manifest" "$HERE/references/public-download-manifest.schema.json")"
[ -z "$smout" ] || {
  printf '%s\n' "$smout" | sed 's/^/apply:   surface manifest INVALID /' >&2
  stop unattested "the surface manifest does not conform to blessed/public-download-manifest/v1"
}

# 3. bound to the ADMITTED candidate — every comparison is against $cand, which
#    admission has already verified against the producer's signature, never
#    against the projection's own claims about itself.
smgaps="$("$JQ" -n -r --slurpfile sm "$surface_manifest" --slurpfile c "$cand" \
  --slurpfile rc "$snap/receipt.json" --slurpfile at "$attest" \
  --arg pre "$prefix" --arg cd "$cand_digest" --arg ch "$exp_channel" --arg env "${prefix}release-candidate.json" '
  ($sm[0]) as $M | ($c[0]) as $C | ($rc[0]) as $R | ($at[0].objects) as $A
  | [ (if $M.project  != $C.project  then "project \($M.project) != candidate \($C.project)" else empty end),
      (if $M.tag      != $C.tag      then "tag \($M.tag) != candidate \($C.tag)" else empty end),
      (if $M.version  != $C.version  then "version \($M.version) != candidate \($C.version)" else empty end),
      (if ($ch != "" and $M.channel != $ch) then "channel \($M.channel) != this promotion\u0027s \($ch)" else empty end),
      (if $M.candidate.manifest_sha256 != $cd then "projects candidate \($M.candidate.manifest_sha256), this promotion admitted \($cd)" else empty end),
      (if $M.candidate.source_sha != $C.source_sha then "source_sha \($M.candidate.source_sha) != candidate \($C.source_sha)" else empty end),
      (if $M.candidate.signing_key_id != $C.signing.key_id then "signing_key_id \($M.candidate.signing_key_id) != candidate \($C.signing.key_id)" else empty end),
      (if $M.candidate.manifest_url != $env then "candidate.manifest_url \($M.candidate.manifest_url) does not name the published envelope \($env)" else empty end),
      # RELEASE METADATA is consumer-visible, so every field of it is bound to
      # an authoritative input too. The receipt is read from $snap, the
      # AUTHENTICATED snapshot bundle_verify took — never from $bundle, which
      # the caller still owns and can replace after verification. The library
      # is explicit that nothing past the snapshot reads $bdir again, and this
      # was the one place that did. Checking only the prefix let a manifest
      # claim any name and timestamp and point at .../not-published.md, which
      # is in-prefix but was never published.
      (if $M.release.published_at != $R.published_at then "release.published_at \($M.release.published_at) does not match the Release receipt \($R.published_at)" else empty end),
      (if $M.release.name != ($C.project + " " + $C.tag) then "release.name \($M.release.name) is not the candidate \($C.project + " " + $C.tag)" else empty end),
      (if $M.release.notes_markdown_url != ($pre + $C.public_notes.filename) then "notes url \($M.release.notes_markdown_url) does not name the candidate public notes \($pre + $C.public_notes.filename)" else empty end),
      (if ([$A[].url] | index($M.release.notes_markdown_url) | not) then "notes url \($M.release.notes_markdown_url) is not a published object — in-prefix is not the same as attested" else empty end),
      # every projected asset must BE a candidate artifact, byte for byte
      ($M.assets[] | . as $a
        | (($C.artifacts | map(select(.filename == $a.filename)) | first) as $ca
           | if ($ca | not) then "asset \($a.filename) is not an artifact of this candidate"
             elif $a.id != $ca.id then "asset \($a.filename) id \($a.id) != candidate \($ca.id)"
             elif $a.install_kind != $ca.install_kind then "asset \($a.filename) install_kind \($a.install_kind) != candidate \($ca.install_kind)"
             elif $a.platform != $ca.platform then "asset \($a.filename) platform \($a.platform) != candidate \($ca.platform)"
             elif $a.sha256 != $ca.sha256 then "asset \($a.filename) sha256 \($a.sha256) != candidate \($ca.sha256)"
             elif $a.size_bytes != $ca.size then "asset \($a.filename) size \($a.size_bytes) != candidate \($ca.size)"
             elif $a.url != ($pre + $a.filename) then "asset \($a.filename) url \($a.url) is not the canonical \($pre + $a.filename)"
             else empty end)),
      # and every candidate artifact must be projected: a projection that drops
      # one silently hides a published artifact from every consumer
      ($C.artifacts[] | . as $ca | select([$M.assets[].filename] | index($ca.filename) | not)
        | "candidate artifact \($ca.filename) is missing from the surface manifest")
    ] | .[]')"
[ -z "$smgaps" ] || {
  printf '%s\n' "$smgaps" | sed 's/^/apply:   surface manifest /' >&2
  stop unattested "the surface manifest is not a faithful projection of this candidate"
}

# URLs are extracted per OUTPUT SCHEMA and canonicalized, because the index
# emits SITE-RELATIVE urls that a naive https:// scan would never see.
: >"$tmp/gen.txt"
for p in "${PATHS[@]}"; do
  role="$("$JQ" -r --arg p "$p" '.outputs[] | select(.repo_path == $p) | .role' "$rr/render-manifest.json")"
  case "$role" in
    channel-pointer) "$JQ" -r '.manifest_url' "$rr/$p" ;;
    updater-pointer) "$JQ" -r '.platforms[].url' "$rr/$p" ;;
    downloads-index) "$JQ" -r '.versions[0] | (.notes_url, .manifest_url, (.assets[].url))' "$rr/$p" ;;
    *) die "unknown output role '$role'; URL extraction must know every emitted schema" ;;
  esac || die "cannot extract URLs from $p"
done | while IFS= read -r u; do
  case "$u" in
    https://*) printf '%s\n' "$u" ;;
    /*) printf '%s%s\n' "$origin" "$u" ;;
    *) printf 'UNCANONICAL:%s\n' "$u" ;;
  esac
done | sort -u >"$tmp/gen.txt"
if grep -q '^UNCANONICAL:' "$tmp/gen.txt"; then
  grep '^UNCANONICAL:' "$tmp/gen.txt" | sed 's/^/apply:   /' >&2
  stop unattested "a rendered output exposes a URL that is neither absolute nor site-relative"
fi
while IFS= read -r u; do
  [ -n "$u" ] || continue
  # The surface manifest is a legitimate exposure: it is the document that
  # tells consumers where the validated bytes are, so the rendered index
  # naturally references it. It is required to be published (checked above by
  # presence) but is not in the candidate-derived required set, because its
  # bytes are the surface owner's and not something the producer could digest.
  [ "$u" = "$surface_manifest_url" ] && continue
  "$JQ" -e --arg u "$u" 'any(.[]; .url == $u)' "$tmp/req.json" >/dev/null
  case $? in
    0) : ;;
    1)
      printf 'apply:   exposed but not required: %s\n' "$u" >&2
      stop unattested "rendered outputs expose URLs outside the required published object set"
      ;;
    *) die "membership check failed to evaluate for $u" ;;
  esac
done <"$tmp/gen.txt"

gaps="$("$JQ" -n -r --slurpfile req "$tmp/req.json" --slurpfile at "$attest" --arg sm "$surface_manifest_url" '
  ($req[0]) as $R | ($at[0].objects) as $O | ($O | map(.url)) as $urls
  | [ ($urls | group_by(.) | map(select(length > 1) | .[0]) | .[] | "duplicate attested object \(.)"),
      ($R[] | . as $r | ($O | map(select(.url == $r.url)) | first) as $o
        | if ($o | not) then "missing published object \($r.url)"
          elif $o.sha256 != $r.sha256 then "published \($r.url) has digest \($o.sha256), candidate says \($r.sha256)"
          elif $o.size != $r.size then "published \($r.url) has size \($o.size), candidate says \($r.size)"
          else empty end),
      ($O[] | . as $o | select(($o.url != $sm) and ([$R[].url] | index($o.url) | not)) | "unexpected attested object \($o.url)"),
      (if ($O | map(select(.url == $sm)) | length) == 1 then empty
       else "the surface manifest \($sm) is not published exactly once" end)
    ] | .[]')" || die "attestation coverage check failed to evaluate"
[ -z "$gaps" ] || {
  printf '%s\n' "$gaps" | sed 's/^/apply:   /' >&2
  stop unattested "publication does not cover the exact required object set"
}

# ── 5. ordering re-check against live state, failing closed ────────────
ptr_path="$("$JQ" -r --arg ch "$exp_channel" '[.promotion_outputs[] | select(.role == "channel-pointer") | select(.channel == $ch) | .repo_path] | first // ""' "$sel")"
if git -C "$repo" cat-file -e "${exp_base}:${ptr_path}" 2>/dev/null; then
  git -C "$repo" cat-file blob "${exp_base}:${ptr_path}" >"$tmp/live.json" 2>/dev/null ||
    stop conflict "cannot read the live channel pointer at the trusted base"
  if ! live_v="$("$JQ" -er '.version' "$tmp/live.json" 2>/dev/null)"; then
    stop conflict "live channel pointer is unreadable or declares no version — failing closed"
  fi
  prom_version_is_canonical "$live_v" || stop conflict "live pointer version '$live_v' is not canonical — failing closed"
  [ "$(prom_version_cmp "$version" "$live_v")" != "-1" ] ||
    stop conflict "the live pointer serves $live_v; promoting $version would move '$exp_channel' backward"
fi

branch="promote/${exp_surface}/${exp_channel}/${version}"
prefix_ref="promote/${exp_surface}/${exp_channel}/"

# ── the snapshot is validated BEFORE any replay logic consumes it ───────
# Deciding a no-op from an unchecked document is the same mistake as trusting
# the bundle.
"$JQ" -e . "$prs" >/dev/null 2>&1 || die "--pr-state is not valid JSON"
vout="$(json_schema_validate_file "$prs" "$HERE/references/pr-state-snapshot.schema.json")"
[ -z "$vout" ] || {
  printf '%s\n' "$vout" | sed 's/^/apply: pr-state INVALID /' >&2
  die "pr-state snapshot does not conform"
}
[ "$(lc "$("$JQ" -r '.repo' "$prs")")" = "$(lc "$owner_repo")" ] || die "pr-state snapshot is for a different repository"
[ "$("$JQ" -r '.query.head_ref_prefix' "$prs")" = "$prefix_ref" ] ||
  die "pr-state query prefix '$("$JQ" -r '.query.head_ref_prefix' "$prs")' is not this promotion's '$prefix_ref'"
for st in OPEN CLOSED MERGED; do
  "$JQ" -e --arg s "$st" 'any(.query.states[]; . == $s)' "$prs" >/dev/null ||
    die "pr-state query omits $st; a snapshot that never looked for $st PRs cannot report their absence"
done

# ── 6. up-to-date ─────────────────────────────────────────────────────
identical=1
for p in "${PATHS[@]}"; do
  git -C "$repo" cat-file blob "${exp_base}:${p}" >"$tmp/live-cmp" 2>/dev/null || {
    identical=0
    break
  }
  cmp -s "$tmp/live-cmp" "$rr/$p" || {
    identical=0
    break
  }
done
if [ "$identical" = "1" ]; then
  # Byte-equal output is NOT proof of equal authority. The same bytes can be
  # produced by a rebuilt candidate, a recreated Release, or a changed policy
  # that happens not to affect this output — publishing that silently under one
  # version is equivocation. So a no-op requires a trusted prior promotion
  # record: an immutable PR head, present locally, whose blobs are these exact
  # outputs and whose commit records the SAME promotion authority.
  # Live outputs must be ORDINARY FILES. Equal blob text in a 100755 or 120000
  # entry is not an up-to-date release surface.
  for p in "${PATHS[@]}"; do
    lm="$(git -C "$repo" ls-tree "$exp_base" -- "$p" | awk '{print $1}')"
    [ "$lm" = "100644" ] ||
      stop conflict "the live $p has mode ${lm:-<none>}, not 100644; equal bytes in a non-regular entry are not an up-to-date surface"
  done
  # A prior promotion must be MERGED — never merely OPEN — on the exact
  # deterministic branch, with immutable merge evidence already contained in
  # this base's history. An OPEN PR proves an intent, not a published state.
  # A prior promotion must be MERGED — never merely OPEN — on the exact
  # deterministic branch, and its head, base and merge commit must provably
  # describe ONE merge. Checking each commit in isolation lets a forged
  # snapshot pair an arbitrary head carrying valid-looking trailers with any
  # base producing an allowlisted diff and merge_commit_sha set to the current
  # trusted base.
  matched=""
  while IFS="$(printf '\t')" read -r h mc pb hrepo brepo bref; do
    [ -n "$h" ] || continue
    [ -n "$mc" ] || continue
    [ "$(lc "$hrepo")" = "$(lc "$owner_repo")" ] || continue
    [ "$(lc "$brepo")" = "$(lc "$owner_repo")" ] || continue
    [ "$bref" = "$base_ref" ] || continue
    # THE PROMOTED HEAD MAY BE GONE. Deleting the branch on merge is ordinary
    # hygiene, and a squash-merged head becomes unreachable the moment it
    # happens — permanently. Requiring it here made every squash-merged
    # promotion replay as `conflict` rather than the no-op it is. When the head
    # is absent the merge commit must carry the whole proof on its own; a no-ff
    # record still requires it, because its second parent IS the head.
    have_head=1
    git -C "$repo" cat-file -e "${h}^{commit}" 2>/dev/null || have_head=0
    git -C "$repo" cat-file -e "${pb}^{commit}" 2>/dev/null || continue
    git -C "$repo" cat-file -e "${mc}^{commit}" 2>/dev/null || continue
    # The merge must already be contained in the admitted base's history.
    git -C "$repo" merge-base --is-ancestor "$mc" "$exp_base" 2>/dev/null || continue
    # A merge commit may legitimately BE the admitted base — that is exactly the
    # state right after merging. What makes `merge_commit_sha = exp_base` a
    # forgery is the topology below: the commit must genuinely have the recorded
    # base and head as parents, with the right tree and diff. It may never be
    # the PR base it is supposed to have advanced past.
    [ "$mc" != "$pb" ] || continue

    # ── the three commits must form a supported merge topology ──────────
    parents="$(git -C "$repo" rev-list --parents -n 1 "$mc" 2>/dev/null | cut -d" " -f2-)"
    np="$(printf '%s' "$parents" | wc -w | tr -d ' ')"
    topo=""
    if [ "$np" = "1" ]; then
      # SQUASH: one parent, which must be the PR base, and the merge tree must
      # equal the promoted head tree.
      [ "$parents" = "$pb" ] || continue
      if [ "$have_head" = "1" ]; then
        [ "$(git -C "$repo" rev-parse "${mc}^{tree}")" = "$(git -C "$repo" rev-parse "${h}^{tree}")" ] || continue
        topo="squash"
      else
        topo="squash (head unreachable; proven from the merge commit)"
      fi
    elif [ "$np" = "2" ]; then
      # NO-FF: first parent is the base, second is the promoted head. This
      # topology is unprovable without the head, by construction.
      [ "$have_head" = "1" ] || continue
      [ "$(printf '%s' "$parents" | cut -d" " -f1)" = "$pb" ] || continue
      [ "$(printf '%s' "$parents" | cut -d" " -f2)" = "$h" ] || continue
      topo="no-ff"
    else
      continue
    fi
    # The merge itself must change exactly the allowlist, not merely the head.
    [ "$(git -C "$repo" diff --name-only "$pb" "$mc" | sort)" = "$(printf '%s\n' "${PATHS[@]}" | sort)" ] || continue
    if [ "$have_head" = "1" ]; then
      [ "$(git -C "$repo" diff --name-only "$pb" "$h" | sort)" = "$(printf '%s\n' "${PATHS[@]}" | sort)" ] || continue
      prior_commits=("$mc" "$h")
    else
      prior_commits=("$mc")
    fi

    okblobs=1
    for p in "${PATHS[@]}"; do
      for c in "${prior_commits[@]}"; do
        git -C "$repo" cat-file blob "${c}:${p}" >"$tmp/prior.blob" 2>/dev/null || {
          okblobs=0
          break 2
        }
        cmp -s "$tmp/prior.blob" "$rr/$p" || {
          okblobs=0
          break 2
        }
        [ "$(git -C "$repo" ls-tree "$c" -- "$p" | awk '{print $1}')" = "100644" ] || {
          okblobs=0
          break 2
        }
      done
    done
    [ "$okblobs" = "1" ] || continue

    # Provenance comes from the promoted head when it survives, and otherwise
    # from the squash commit that replaced it — which carries the same trailers
    # and IS the commit in this base's history. A squash whose body dropped them
    # proves nothing and falls through to the conflict below, as it should.
    prov="$h"
    [ "$have_head" = "1" ] || prov="$mc"
    pa="$(git -C "$repo" log -1 --format=%B "$prov" 2>/dev/null | sed -n 's/^Promotion-Authority: *//p' | head -1)"
    pi="$(git -C "$repo" log -1 --format=%B "$prov" 2>/dev/null | sed -n 's/^Promotion-Admission: *//p' | head -1)"
    # Admission is run-specific provenance: it must be present and canonical,
    # but it is NOT the replay comparison — a legitimate replay has a new
    # admission id because its wake event and trusted base differ.
    printf '%s' "$pi" | grep -Eq '^[0-9a-f]{64}$' || continue
    [ "$pa" = "$authority" ] || continue
    matched="$h"
    matched_topo="$topo"
    break
  done <<EOF
$("$JQ" -r --arg me "$branch" '
  [ .pull_requests[] | select(.state == "MERGED") | select(.head_ref == $me)
    | [ .head_sha, (.merge_commit_sha // ""), .base_sha, .head_repo, .base_repo, .base_ref ]
    | @tsv ] | .[]' "$prs")
EOF
  if [ -n "$matched" ]; then
    state up-to-date "the trusted base already serves $version, and ${matched_topo} merge of promotion $(printf '%s' "$matched" | cut -c1-12) recorded the same authority"
    exit 0
  fi
  stop conflict "the trusted base already serves these exact bytes for $version, but no MERGED promotion on $branch — present locally, already contained in this base's history, and carrying authority $(printf '%s' "$authority" | cut -c1-12) — proves the same candidate, Release and policy produced them. This needs an owner decision rather than a silent no-op"
fi

# Checked here, before anything is created: discovering a missing adapter after
# the commit leaves a branch nobody asked for.
if [ "$push" -eq 1 ]; then
  [ -n "$adapter" ] || die "--publish requires --adapter"
  [ -x "$adapter" ] || die "adapter is not executable: $adapter"
fi

# ── 7. the PR snapshot is mandatory, closed, and must answer THIS question ──
competing="$("$JQ" -r --arg b "$prefix_ref" --arg me "$branch" '
  [ .pull_requests[] | select(.state == "OPEN") | select(.head_ref | startswith($b)) | select(.head_ref != $me)
    | "#\(.number) \(.head_ref)" ] | join(", ")' "$prs")"
[ -z "$competing" ] || stop stale-open-pr "another open promotion exists for '$exp_surface'/'$exp_channel': $competing"
closed_same="$("$JQ" -r --arg me "$branch" '[.pull_requests[] | select(.state == "CLOSED") | select(.head_ref == $me) | "#\(.number)"] | join(", ")' "$prs")"
[ -z "$closed_same" ] || stop stale-open-pr "a closed, unmerged promotion already exists for this version ($closed_same)"
mine="$("$JQ" -c --arg me "$branch" '[.pull_requests[] | select(.state == "OPEN") | select(.head_ref == $me)]' "$prs")"
mine_n="$(printf '%s' "$mine" | "$JQ" 'length')"
[ "$mine_n" -le 1 ] || stop stale-open-pr "the snapshot reports $mine_n open PRs for the same head ref; identity must be unambiguous"

if [ "$mine_n" = "1" ]; then
  pr_num="$(printf '%s' "$mine" | "$JQ" -r '.[0].number')"
  pr_head="$(printf '%s' "$mine" | "$JQ" -r '.[0].head_sha')"
  pr_base="$(printf '%s' "$mine" | "$JQ" -r '.[0].base_sha')"
  [ "$(lc "$(printf '%s' "$mine" | "$JQ" -r '.[0].head_repo')")" = "$(lc "$owner_repo")" ] ||
    stop stale-open-pr "PR #$pr_num's head is in another repository — a fork branch with the expected name is not this promotion"
  [ "$(lc "$(printf '%s' "$mine" | "$JQ" -r '.[0].base_repo')")" = "$(lc "$owner_repo")" ] ||
    stop stale-open-pr "PR #$pr_num targets another repository"
  [ "$(printf '%s' "$mine" | "$JQ" -r '.[0].base_ref')" = "$base_ref" ] ||
    stop stale-open-pr "PR #$pr_num targets base ref $(printf '%s' "$mine" | "$JQ" -r '.[0].base_ref'), not the trusted '$base_ref'"
  bsha="$("$JQ" -r --arg me "$branch" '[.branches[] | select(.name == $me) | .sha] | first // ""' "$prs")"
  [ -n "$bsha" ] || stop stale-open-pr "the snapshot reports PR #$pr_num but no remote branch $branch"
  [ "$bsha" = "$pr_head" ] || stop stale-open-pr "remote branch $branch is at $bsha but PR #$pr_num reports head $pr_head"
  for c in "$pr_head" "$pr_base"; do
    git -C "$repo" cat-file -e "${c}^{commit}" 2>/dev/null ||
      stop stale-open-pr "commit $c is not in the local object store; adoption cannot be decided from self-reported values"
  done

  # ── adopt, RECOVER, or refuse ──────────────────────────────────────────
  # Everything above established IDENTITY: this PR is ours, in this repo,
  # against the trusted base ref, on this promotion's branch, and its branch
  # and PR agree. Only past that point is it safe to consider replacing it.
  #
  # What follows separates two different kinds of disagreement:
  #
  #   RECOVERABLE — the PR is this promotion but its head is no longer the
  #   commit this run would prepare: it was built on a base `main` has since
  #   advanced past, or it carries the right outputs without head-level
  #   provenance. Both happen in normal operation. Before this, BOTH doors
  #   were shut — a re-drive refused the obsolete base and closing the PR
  #   refused as "a closed, unmerged promotion already exists" — so a
  #   promotion could get permanently stuck.
  #
  #   REFUSED — anything suggesting this is not purely this promotion: a
  #   different authority, DIFFERENT BYTES at a declared output, a missing
  #   output, or ANY change on the promotion branch outside the declared
  #   outputs. Recovery may bring a head up to date; it may never discard
  #   content that is not this promotion.
  #
  # BOTH DECISIONS COME FROM ANCESTRY, never from the snapshot's base_sha.
  # GitHub reports a PR's base as the TARGET BRANCH'S CURRENT TIP, not the
  # commit the branch forked from, so `main` can advance under an open
  # promotion while the snapshot still names the admitted base. Diffing the
  # head against that tip then counts everything `main` gained as a deletion
  # by the branch, refusing a valid promotion; and comparing against a stale
  # snapshot base says nothing about what the branch itself changed. The
  # fork point — the merge base of the trusted base and the head — is what
  # separates changes inherited from `main` from edits made on the branch:
  #
  #   fork == trusted base   the branch is current; adopt if provenance-complete
  #   fork  < trusted base   `main` advanced; recoverable
  #   diff(fork, head)       must be EXACTLY the declared outputs, whatever
  #                          the base — unrelated additions, edits, deletions
  #                          or mode changes on the branch are refused, so a
  #                          lease can never replace work that is not ours
  #
  # Recovery does NOT trust or copy anything from the existing head. It falls
  # through to the same preparation every other path uses, re-deriving the
  # outputs from the verified bundle and minting fresh trailers from $exp_id
  # and $authority, then replaces the branch under a compare-and-swap lease.
  fork="$(git -C "$repo" merge-base --all "$exp_base" "$pr_head" 2>/dev/null || true)"
  [ -n "$fork" ] ||
    stop stale-open-pr "PR #$pr_num's head shares no history with the admitted trusted base $(printf '%s' "$exp_base" | cut -c1-12)"
  [ "$(printf '%s\n' "$fork" | wc -l | tr -d ' ')" = "1" ] ||
    stop stale-open-pr "PR #$pr_num's head has more than one fork point from the trusted base; branch-only changes cannot be identified"
  why=""
  [ "$fork" = "$exp_base" ] ||
    why="it was built on $(printf '%s' "$fork" | cut -c1-12), which the admitted trusted base $(printf '%s' "$exp_base" | cut -c1-12) has advanced past"

  # BRANCH-ONLY CHANGES ARE CHECKED UNCONDITIONALLY, whatever the base.
  # Plumbing with renames off: this is a security boundary and must not bend
  # to the receiver checkout's diff configuration.
  changed="$(git -C "$repo" diff-tree -r --name-only --no-renames "$fork" "$pr_head" 2>/dev/null | sort)"
  [ "$changed" = "$(printf '%s\n' "${PATHS[@]}" | sort)" ] ||
    stop stale-open-pr "PR #$pr_num's branch-only changes are not exactly the declared outputs (changes paths outside the selected output allowlist, or omits one)"

  # OUTPUT IDENTITY IS CHECKED UNCONDITIONALLY, whatever the base.
  #
  # These were once inside an `if [ -z "$why" ]` guard, so an obsolete base —
  # which sets `why` first — skipped every one of them. A head with conflicting,
  # missing or non-regular outputs was then classified as recoverable and
  # authorized for replacement. A compare-and-swap lease proves the head has not
  # MOVED; it says nothing about whether its contents belong to this promotion.
  for p in "${PATHS[@]}"; do
    git -C "$repo" cat-file blob "${pr_head}:${p}" >"$tmp/pr-blob" 2>/dev/null ||
      stop stale-open-pr "PR #$pr_num's head does not contain $p"
    cmp -s "$tmp/pr-blob" "$rr/$p" ||
      stop stale-open-pr "PR #$pr_num's head has different bytes at $p"
    [ "$(git -C "$repo" ls-tree "$pr_head" -- "$p" | awk '{print $1}')" = "100644" ] ||
      stop stale-open-pr "PR #$pr_num carries $p with a non-regular mode; blob text equal to a symlink target is not an output file"
  done

  apa="$(git -C "$repo" log -1 --format=%B "$pr_head" 2>/dev/null | sed -n 's/^Promotion-Authority: *//p' | head -1)"
  api="$(git -C "$repo" log -1 --format=%B "$pr_head" 2>/dev/null | sed -n 's/^Promotion-Admission: *//p' | head -1)"
  # A DIFFERENT authority is never recoverable: a recreated Release or a changed
  # non-output policy can produce identical bytes, and replacing that head would
  # silently retarget someone else's promotion.
  [ -z "$apa" ] || [ "$apa" = "$authority" ] ||
    stop stale-open-pr "PR #$pr_num was promoted under a different authority ($(printf '%s' "$apa" | cut -c1-12)); a recreated Release or a changed non-output policy can produce identical bytes"
  if [ -z "$why" ]; then
    [ -n "$apa" ] || why="its head records no Promotion-Authority"
  fi
  if [ -z "$why" ]; then
    [ -n "$api" ] || why="its head records no Promotion-Admission"
  fi

  if [ -z "$why" ]; then
    state adopt-open-pr "PR #$pr_num carries exactly these bytes at $pr_head under the same authority"
    exit 0
  fi

  # RECOVER. The lease target is the head observed in the snapshot, so a
  # concurrent writer that moves the branch makes the push fail rather than be
  # overwritten.
  recover_from="$pr_head"
  printf 'apply: recovering PR #%s: %s; re-deriving from the admitted bundle at %s\n' \
    "$pr_num" "$why" "$(printf '%s' "$exp_base" | cut -c1-12)" >&2
fi
# A remote branch with no PR is the RESUMABLE state left by a failure between
# push and PR creation. Because the promotion commit is deterministic, this run
# will re-derive the same sha and can recognise its own work; whether that
# branch is ours is decided in the publication phase, not guessed here.
branch_only="$("$JQ" -r --arg me "$branch" '[.branches[] | select(.name == $me) | .sha] | first // ""' "$prs")"
[ -z "$branch_only" ] || [ -n "$recover_from" ] ||
  printf 'apply: note: remote branch %s already exists at %s; publication will resume it only if it is this run\x27s exact commit\n' \
    "$branch" "$(printf '%s' "$branch_only" | cut -c1-12)" >&2

# ── 8. prepare; any failure restores the original state completely ─────
# GIT HOOKS ARE DISABLED for EVERY git mutation, including branch creation and
# the restore path. Defining this wrapper only after the branch existed left
# `checkout -b` and rollback running hooks: a failing post-checkout hook could
# leave the new branch checked out while the error path did a plain `die`.
G() { git -C "$repo" -c core.hooksPath=/dev/null "$@"; }

G rev-parse --verify --quiet "$branch" >/dev/null 2>&1 &&
  stop dirty "branch $branch already exists locally"

restore() {
  G reset -q --hard "$exp_base" 2>/dev/null
  G clean -qfd 2>/dev/null
  G checkout -q "$base_ref" 2>/dev/null || G checkout -q "$exp_base" 2>/dev/null
  G branch -qD "$branch" 2>/dev/null
}
# Restoration is asserted, not assumed: a rollback that quietly failed would
# leave a branch the adapter could still be pointed at.
assert_restored() {
  local why="$1" bad=""
  [ "$(G rev-parse HEAD 2>/dev/null)" = "$exp_base" ] || bad="${bad}HEAD is not the trusted base; "
  [ -z "$(G branch --list "$branch")" ] || bad="${bad}the promotion branch survived; "
  [ -z "$(G status --porcelain --untracked-files=all 2>/dev/null)" ] || bad="${bad}index/worktree/untracked not clean; "
  if [ -n "$bad" ]; then
    printf 'apply: RESTORATION INCOMPLETE after %s: %s\n' "$why" "$bad" >&2
    printf 'apply: the receiver needs manual inspection before another promotion\n' >&2
    exit 2
  fi
}
# THE post-prepare finalizer. Every terminal path after the branch exists routes
# through here, so none can accidentally skip local restoration. Two paths
# previously used a bare `exit 1` and left the receiver checked out on the
# promotion branch — which made the very rerun they advertised as safe die at
# the local branch-exists preflight before it could resume.
#
# It restores LOCAL state only. Any remote branch or PR is left exactly as it
# is: that is the resumable state, and rewriting or deleting it is precisely
# what must never happen.
finalize() { # $1=exit code $2=why
  restore
  assert_restored "$2"
  printf 'apply: the receiver was restored to %s with no local promotion branch; any remote branch or PR is untouched\n' "$base_ref" >&2
  exit "$1"
}
fatal() {
  printf 'apply: %s\n' "$1" >&2
  finalize 2 "$1"
}

G checkout -q -b "$branch" || fatal "cannot create promotion branch"
[ -z "${PROMOTION_FAIL_AFTER_CHECKOUT:-}" ] || fatal "injected failure after branch creation (verification hook)"

for p in "${PATHS[@]}"; do
  mkdir -p "$repo/$(dirname "$p")" || fatal "cannot create $(dirname "$p")"
  t="$repo/$p.promotion.tmp.$$"
  cp "$rr/$p" "$t" || fatal "cannot stage $p"
  mv -f "$t" "$repo/$p" || {
    rm -f "$t"
    fatal "cannot place $p"
  }
  G add -- "$p" || fatal "cannot add $p"
done
[ -z "${PROMOTION_FAIL_AFTER_WRITE:-}" ] || fatal "injected failure after the output writes (verification hook)"

# ── staged contract: exact set, exact bytes, ordinary file mode ─────────
final="$(G diff --cached --name-only | sort)"
[ "$final" = "$(printf '%s\n' "${PATHS[@]}" | sort)" ] || {
  restore
  stop dirty "the staged change set is not exactly the selected outputs"
}
for p in "${PATHS[@]}"; do
  m="$(G ls-files --stage -- "$p" | awk '{print $1}')"
  [ "$m" = "100644" ] || {
    restore
    stop dirty "staged $p has mode ${m:-<none>}; a promotion output must be an ordinary file (100644)"
  }
  G show ":$p" >"$tmp/staged.blob" 2>/dev/null || {
    restore
    stop dirty "cannot read the staged blob for $p"
  }
  cmp -s "$tmp/staged.blob" "$rr/$p" || {
    restore
    stop dirty "staged $p does not match the independently re-rendered bytes — a hook or clean filter altered it"
  }
done

# DETERMINISTIC COMMIT. Identity and dates come from the admitted decision, not
# from the clock or the local git config, so re-preparing the same bundle on the
# same base produces the SAME commit sha. That is what makes a post-push failure
# resumable: a later run recognises the branch already at its own prepared
# commit instead of colliding with a stranger.
GIT_AUTHOR_NAME="blessed release promotion" \
  GIT_AUTHOR_EMAIL="promotion@blessed.invalid" \
  GIT_COMMITTER_NAME="blessed release promotion" \
  GIT_COMMITTER_EMAIL="promotion@blessed.invalid" \
  GIT_AUTHOR_DATE="$("$JQ" -r '.identity.published_at' "$man")" \
  GIT_COMMITTER_DATE="$("$JQ" -r '.identity.published_at' "$man")" \
  G commit -q -m "release: promote ${project} ${tag} to ${exp_channel}

Moves the ${exp_channel} channel pointer to ${version}, published ${tag}.
Every required object was verified published under ${prefix} before this
pointer moved. Rendered from the signed candidate.

Promotion-Admission: ${exp_id}
Promotion-Authority: ${authority}" ||
  fatal "cannot create the promotion commit"

# A verification hook that corrupts a committed blob AFTER the commit and
# BEFORE the gate below, so deleting that gate makes a control fail rather than
# merely shrinking the tally.
if [ -n "${PROMOTION_CORRUPT_AFTER_COMMIT:-}" ]; then
  printf 'corrupted-after-commit\n' >"$repo/${PATHS[0]}"
  G add -- "${PATHS[0]}" >/dev/null 2>&1
  G commit -q --amend --no-edit >/dev/null 2>&1
fi
# MODE-ONLY corruption, leaving the bytes correct. Without this, deleting the
# post-commit mode check would leave every control green.
if [ -n "${PROMOTION_CORRUPT_MODE_AFTER_COMMIT:-}" ]; then
  G update-index --chmod=+x -- "${PATHS[0]}" >/dev/null 2>&1
  G commit -q --amend --no-edit >/dev/null 2>&1
fi

# ── committed contract: same checks again, against HEAD ────────────────
after="$(G diff --name-only "$exp_base" HEAD | sort)"
[ "$after" = "$(printf '%s\n' "${PATHS[@]}" | sort)" ] || fatal "post-commit diff is not exactly the selected outputs"
for p in "${PATHS[@]}"; do
  m="$(G ls-tree HEAD -- "$p" | awk '{print $1}')"
  [ "$m" = "100644" ] || fatal "committed $p has mode ${m:-<none>}, not 100644"
  G show "HEAD:$p" >"$tmp/head.blob" 2>/dev/null || fatal "cannot read the committed blob for $p"
  cmp -s "$tmp/head.blob" "$rr/$p" || fatal "committed $p does not match the independently re-rendered bytes"
done
[ -z "$(G status --porcelain --untracked-files=all)" ] || fatal "the worktree is not clean after the promotion commit"

# The exact commit every later step binds to.
prepared_sha="$(G rev-parse HEAD)"
state behind "prepared $branch at $(printf '%s' "$prepared_sha" | cut -c1-12) (${#PATHS[@]} output(s))"

# ── 9. upsert exactly one PR, through the injected adapter ────────────
# The body is DETERMINISTIC and provenance-bound: re-running an equivalent
# promotion must not churn the PR with volatile run URLs.
body="$tmp/pr-body.md"
cat >"$body" <<EOF
Automated release promotion.

| | |
|---|---|
| project | \`${project}\` |
| version | \`${version}\` (\`${tag}\`) |
| producer commit | \`${producer_sha}\` |
| candidate digest | \`${cand_digest}\` |
| surface | \`${exp_surface}\` |
| channel | \`${exp_channel}\` |
| transport | \`${transport}\` |
| admission | \`${exp_id}\` |
| trusted base | \`${exp_base}\` |

Every required object was verified published under \`${prefix}\` before this
pointer moved. Review and merge is a human action.
EOF
if [ "$push" -eq 1 ]; then
  # ── the publication state machine ───────────────────────────────────
  # Every post-push state is resumable. A failure between push and PR creation
  # used to strand the branch forever: the create-only lease refuses to push
  # again and there is no update path. Because the promotion commit is
  # deterministic, a later run re-derives the same sha and can tell its own
  # stranded work from a stranger's — and resumes it rather than needing a human.
  snapcheck() { # $1=file $2=label — the invariants every snapshot must satisfy
    local f="$1" l="$2" v
    "$JQ" -e . "$f" >/dev/null 2>&1 || fatal "the $l snapshot is not valid JSON"
    v="$(json_schema_validate_file "$f" "$HERE/references/pr-state-snapshot.schema.json")"
    [ -z "$v" ] || {
      printf '%s\n' "$v" | sed "s/^/apply: $l snapshot INVALID /" >&2
      fatal "the $l snapshot does not conform"
    }
    [ "$(lc "$("$JQ" -r '.repo' "$f")")" = "$(lc "$owner_repo")" ] || fatal "the $l snapshot is for a different repository"
    [ "$("$JQ" -r '.query.head_ref_prefix' "$f")" = "$prefix_ref" ] || fatal "the $l snapshot asked about a different prefix"
    for st in OPEN CLOSED MERGED; do
      "$JQ" -e --arg s "$st" 'any(.query.states[]; . == $s)' "$f" >/dev/null || fatal "the $l snapshot omits $st"
    done
    # Another promotion for this channel is always a conflict, at every stage.
    v="$("$JQ" -r --arg b "$prefix_ref" --arg me "$branch" '
      [ .pull_requests[] | select(.state == "OPEN") | select(.head_ref | startswith($b))
        | select(.head_ref != $me) | "#\(.number)" ] | join(", ")' "$f")"
    [ -z "$v" ] || fatal "a competing promotion appeared ($l): $v"
    v="$("$JQ" -r --arg b "$prefix_ref" --arg me "$branch" \
      '[ .branches[] | select(.name | startswith($b)) | select(.name != $me) | .name ] | join(", ")' "$f")"
    [ -z "$v" ] || fatal "a competing promotion branch appeared ($l): $v"
    # Our own branch may be absent (fresh) or at our exact commit (resume). Any
    # other value is someone else's ref and must never be touched.
    v="$("$JQ" -r --arg me "$branch" '[.branches[] | select(.name == $me) | .sha] | first // ""' "$f")"
    # RECOVERY carries one extra permitted value: the exact head it verified and
    # is leased to replace. Without this the guard rejected the very ref the
    # recovery exists to update, so the supported path could never publish.
    # Anything else is still refused — including a head that moved after the
    # verification, which is what the lease then also refuses at push time.
    if [ -n "$v" ] && [ "$v" != "$prepared_sha" ] &&
      { [ -z "$recover_from" ] || [ "$v" != "$recover_from" ]; }; then
      fatal "remote branch $branch is at $v, not this run's commit $prepared_sha; refusing to touch a ref this run did not create"
    fi
    SNAP_BRANCH="$v"
    v="$("$JQ" -c --arg me "$branch" '[.pull_requests[] | select(.state == "OPEN") | select(.head_ref == $me)]' "$f")"
    [ "$(printf '%s' "$v" | "$JQ" 'length')" -le 1 ] || fatal "the $l snapshot reports more than one open PR for $branch"
    SNAP_PR="$v"
  }
  verify_commit_contents() { # $1=commit $2=base $3=label
    local c="$1" b="$2" l="$3" pth
    for pth in "$c" "$b"; do
      G cat-file -e "${pth}^{commit}" 2>/dev/null || fatal "$l commit $pth is not in the local object store"
    done
    [ "$b" = "$exp_base" ] || fatal "$l is based on $b, not the admitted trusted base $exp_base"
    for pth in "${PATHS[@]}"; do
      G cat-file blob "${c}:${pth}" >"$tmp/rc.blob" 2>/dev/null || fatal "$l lacks $pth"
      cmp -s "$tmp/rc.blob" "$rr/$pth" || fatal "$l has different bytes at $pth"
      [ "$(G ls-tree "$c" -- "$pth" | awk '{print $1}')" = "100644" ] || fatal "$l carries $pth with a non-regular mode"
    done
    [ "$(G diff --name-only "$b" "$c" | sort)" = "$(printf '%s\n' "${PATHS[@]}" | sort)" ] ||
      fatal "$l changes paths outside the selected allowlist"
  }
  # Confirm a reported PR really is this promotion, then finish.
  settle_on_pr() { # $1=pr-json $2=how
    local pr="$1" how="$2" pn ph pb
    pn="$(printf '%s' "$pr" | "$JQ" -r '.[0].number')"
    ph="$(printf '%s' "$pr" | "$JQ" -r '.[0].head_sha')"
    pb="$(printf '%s' "$pr" | "$JQ" -r '.[0].base_sha')"
    [ "$(lc "$(printf '%s' "$pr" | "$JQ" -r '.[0].head_repo')")" = "$(lc "$owner_repo")" ] || fatal "PR #$pn's head is in another repository"
    [ "$(lc "$(printf '%s' "$pr" | "$JQ" -r '.[0].base_repo')")" = "$(lc "$owner_repo")" ] || fatal "PR #$pn targets another repository"
    [ "$(printf '%s' "$pr" | "$JQ" -r '.[0].base_ref')" = "$base_ref" ] || fatal "PR #$pn targets an untrusted base ref"
    [ "$ph" = "$prepared_sha" ] || fatal "PR #$pn's head is $ph, not the prepared commit $prepared_sha"
    verify_commit_contents "$ph" "$pb" "PR #$pn"
    printf 'apply: %s: exactly one PR (#%s) at %s\n' "$how" "$pn" "$(printf '%s' "$prepared_sha" | cut -c1-12)" >&2
  }
  # Published: the remote is authoritative from here and the commit is
  # deterministic, so the local branch has no further purpose.
  settle_and_finish() { # $1=pr-json $2=how
    settle_on_pr "$1" "$2"
    finalize 0 "a successful publication"
  }
  take_snapshot() { # $1=dest $2=label
    "$adapter" snapshot "$owner_repo" "$prefix_ref" >"$1" 2>"$tmp/snap.err" && return 0
    sed 's/^/apply: /' "$tmp/snap.err" >&2
    return 1
  }

  # ── 1. where are we? ────────────────────────────────────────────────
  take_snapshot "$tmp/pre.json" "pre-push" || fatal "could not read PR state; nothing was pushed, so re-running is safe"
  snapcheck "$tmp/pre.json" "pre-push"
  verify_commit_contents "$prepared_sha" "$exp_base" "the prepared commit"

  # "Already published" means the branch is ALREADY at this run's commit. During
  # a recovery the PR exists but its branch is still the old head, so settling
  # here would return success having replaced nothing.
  if [ "$(printf '%s' "$SNAP_PR" | "$JQ" 'length')" = "1" ] &&
    { [ -z "$recover_from" ] || [ "$SNAP_BRANCH" = "$prepared_sha" ]; }; then
    settle_and_finish "$SNAP_PR" "already published"
  fi

  # ── 2. push, recover, or resume a branch this run already produced ──
  if [ -z "$SNAP_BRANCH" ]; then
    "$adapter" push "$repo" "$branch" "$prepared_sha" || fatal "adapter failed to push $branch"
  elif [ -n "$recover_from" ] && [ "$SNAP_BRANCH" = "$recover_from" ]; then
    # Replace ONLY the head we verified belongs to this promotion. The lease
    # makes a concurrently moved branch a failure, not an overwrite.
    "$adapter" push "$repo" "$branch" "$prepared_sha" "$recover_from" ||
      fatal "adapter failed to recover $branch onto $recover_from"
  elif [ "$SNAP_BRANCH" = "$prepared_sha" ]; then
    printf 'apply: resuming: %s is already at the commit this run prepared; skipping the push\n' "$branch" >&2
  else
    fatal "remote branch $branch is at $SNAP_BRANCH, which is neither this run's commit nor the head this recovery verified"
  fi

  take_snapshot "$tmp/post.json" "post-push" ||
    fatal "pushed $branch but could not re-read PR state; the branch is at this run's exact commit, so re-running resumes it"
  snapcheck "$tmp/post.json" "post-push"
  [ -n "$SNAP_BRANCH" ] || fatal "after pushing, $branch is still absent"
  if [ "$(printf '%s' "$SNAP_PR" | "$JQ" 'length')" = "1" ]; then
    settle_and_finish "$SNAP_PR" "already published"
  fi

  # ── 3. create, and RE-READ before believing a failure ───────────────
  if "$adapter" create-pr "$owner_repo" "$branch" "$base_ref" \
    "release: Promote ${project} ${tag} To ${exp_channel}" "$body" "$prepared_sha"; then
    created_ok=1
  else
    created_ok=0
    printf 'apply: create-pr reported failure; re-reading before concluding anything\n' >&2
  fi

  if ! take_snapshot "$tmp/final.json" "post-publication"; then
    printf 'apply: the PR state could not be read back. %s is at this run\x27s exact commit, so re-running resumes safely.\n' "$branch" >&2
    finalize 1 "an unreadable post-publication snapshot"
  fi
  snapcheck "$tmp/final.json" "post-publication"
  if [ "$(printf '%s' "$SNAP_PR" | "$JQ" 'length')" = "1" ]; then
    # A create that reported failure may still have succeeded server-side.
    if [ "$created_ok" = "1" ]; then
      settle_and_finish "$SNAP_PR" "created"
    else settle_and_finish "$SNAP_PR" "created despite a reported client failure"; fi
  fi
  # Definitively no PR. The branch stays, at this run's exact commit, which is
  # precisely the state a later run resumes. Nothing is deleted, so a ref that
  # moved concurrently is never touched.
  printf 'apply: no pull request exists for %s. The branch is at this run\x27s exact commit (%s); re-run to resume and create it.\n' \
    "$branch" "$(printf '%s' "$prepared_sha" | cut -c1-12)" >&2
  finalize 1 "a definitive create-pr failure"
else
  cat >&2 <<EOF
apply: NOT published. Re-run with --publish --adapter, or run:
apply:   git -C "$repo" push -u origin "$branch"
apply:   gh pr create --repo "$owner_repo" --base "$base_ref" --head "$branch" \\
apply:     --title "release: Promote ${project} ${tag} To ${exp_channel}"
EOF
fi
exit 0
