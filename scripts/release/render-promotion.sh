#!/usr/bin/env bash
# shellcheck disable=SC2016  # jq programs: $-names are jq variables, not shell
# render-promotion.sh — render promotion outputs from a RE-ADMITTED bundle.
#
# Rendering is pure: no network, no clock, no credentials, no git writes, no
# ambient state. Read-only git anchors the surface, policy and live pointer to
# tracked blobs at the trusted base, because a working copy is editable by
# anyone holding the checkout.
#
# ALL OR NOTHING. Every output is rendered, validated and hashed inside a
# private staging tree; the caller's --outdir is created only after everything
# has succeeded. An earlier version wrote the channel pointer before validating
# the index and updater, so a bad updater or a late equal-version conflict left
# a half-promoted directory behind for the next stage to trip over.
#
# The trust store and the expected admission identity are supplied
# INDEPENDENTLY of the bundle: a bundle that carried its own trust root would
# make signature verification circular.
#
# Exit: 0 rendered | 1 refused | 2 tooling/usage.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JQ="${JQ_BIN:-jq}"

bundle="" repo="" outdir="" signing_dir="" store=""
exp_id="" exp_base="" exp_surface="" exp_channel=""
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
    --outdir)
      outdir="${2:-}"
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
    *)
      printf 'render: unexpected arg: %s\n' "$1" >&2
      exit 2
      ;;
  esac
done
die() {
  printf 'render: %s\n' "$1" >&2
  exit 2
}
refuse() {
  printf 'render: REFUSE %s\n' "$1" >&2
  exit 1
}
for r in "$bundle" "$repo" "$outdir" "$signing_dir" "$store" "$exp_id" "$exp_base" "$exp_surface" "$exp_channel"; do
  [ -n "$r" ] || die "--bundle-dir --receiver-repo --outdir --signing-dir --trust-store --expected-admission-id --expected-base-sha --expected-surface-id --expected-channel are all required"
done
command -v "$JQ" >/dev/null 2>&1 || die "jq not found"
[ -e "$outdir" ] && die "--outdir already exists; render publishes by renaming a completed tree into an absent destination"
# shellcheck source=scripts/release/lib/promotion-lib.sh
. "$HERE/lib/promotion-lib.sh" || die "promotion library failed to source"
# shellcheck source=scripts/release/lib/bundle-verify.sh
. "$HERE/lib/bundle-verify.sh" || die "bundle verifier failed to source"
# shellcheck source=scripts/release/lib/lib-json-schema.sh
. "$HERE/lib/lib-json-schema.sh" || die "schema library failed to source"

tmp="$(mktemp -d)" || die "cannot create temp dir"
trap 'rm -rf "$tmp"' EXIT INT TERM HUP
snap="$tmp/snap"
stage="$tmp/stage"
mkdir -p "$stage"

bundle_verify "$bundle" "$snap" "$signing_dir" "$repo" "$store" \
  "$exp_id" "$exp_base" "$exp_surface" "$exp_channel" || exit $?

man="$snap/bundle.json"
cand="$snap/candidate-dir/release-candidate.json"
sel="$snap/.sel.json"
version="$("$JQ" -r '.identity.version' "$man")"
tag="$("$JQ" -r '.identity.tag' "$man")"
published_at="$("$JQ" -r '.identity.published_at' "$man")"
base_url="$("$JQ" -r '.public_base_url' "$sel")"
relprefix="$("$JQ" -r '.immutable_release_prefix' "$sel")"
prefix="${base_url}${relprefix}${tag}/"
site_base="$(printf '%s' "$base_url" | sed -E 's#^https?://[^/]+##; s#/$##')"

out_path() { "$JQ" -r --arg r "$1" --arg ch "$exp_channel" \
  '[.promotion_outputs[] | select(.role == $r) | select((.channel // $ch) == $ch) | .repo_path] | first // ""' "$sel"; }

: >"$tmp/outputs.tsv"
stage_out() { # $1=role $2=repo_path $3=srcfile — into the STAGING tree only
  mkdir -p "$stage/$(dirname "$2")" || die "cannot create staging directory"
  cp "$3" "$stage/$2" || die "cannot stage $2"
  printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$(wc -c <"$stage/$2" | tr -d ' ')" \
    "$(shasum -a 256 "$stage/$2" | awk '{print $1}')" >>"$tmp/outputs.tsv"
  printf 'render: staged %-16s %s\n' "$1" "$2" >&2
}

# ── ordering against the live pointer at the trusted base ────────────────
ptr_path="$(out_path channel-pointer)"
[ -n "$ptr_path" ] || refuse "surface declares no channel-pointer for channel '$exp_channel'"
equal_version=0
if git -C "$repo" cat-file -e "${exp_base}:${ptr_path}" 2>/dev/null; then
  git -C "$repo" cat-file blob "${exp_base}:${ptr_path}" >"$tmp/live-ptr.json" 2>/dev/null ||
    refuse "cannot read the live channel pointer at $exp_base"
  "$JQ" -e . "$tmp/live-ptr.json" >/dev/null 2>&1 ||
    refuse "live channel pointer is not valid JSON — refusing rather than skipping the ordering check"
  cur_v="$("$JQ" -r '.version // ""' "$tmp/live-ptr.json")"
  prom_version_is_canonical "$cur_v" ||
    refuse "live channel pointer declares no canonical version (got '${cur_v}') — refusing rather than assuming an empty channel"
  case "$(prom_version_cmp "$version" "$cur_v")" in
    -1) refuse "promotion would move channel '$exp_channel' BACKWARD, from $cur_v to $version" ;;
    0) equal_version=1 ;;
    1) : ;;
    *) die "version comparison produced no verdict" ;;
  esac
fi

# ── channel pointer ─────────────────────────────────────────────────────
"$JQ" -S -n --slurpfile c "$cand" --arg ch "$exp_channel" --arg pa "$published_at" --arg pre "$prefix" '{
  schema: "blessed/public-download-channel/v1",
  project: $c[0].project, channel: $ch, version: $c[0].version, tag: $c[0].tag,
  published_at: $pa, manifest_url: ($pre + "manifest.json")
}' >"$tmp/ptr.json" || die "pointer rendering failed"
vout="$(json_schema_validate_file "$tmp/ptr.json" "$HERE/references/public-download-channel.schema.json")"
[ -z "$vout" ] || {
  printf '%s\n' "$vout" | sed 's/^/render: pointer INVALID /' >&2
  die "renderer produced a non-conforming pointer"
}
stage_out channel-pointer "$ptr_path" "$tmp/ptr.json"

# ── downloads index ─────────────────────────────────────────────────────
nidx="$("$JQ" -r '[.promotion_outputs[] | select(.role == "downloads-index")] | length' "$sel")"
[ "$nidx" -le 1 ] || refuse "the surface declares $nidx downloads-index outputs; only one can be rendered"
idx_path="$(out_path downloads-index)"
if [ -n "$idx_path" ]; then
  [ -f "$snap/renderer-config.json" ] || refuse "surface declares a downloads-index but the bundle carries no renderer_config"
  notes="$snap/candidate-dir/$("$JQ" -r '.public_notes.filename' "$cand")"
  existing=""
  if git -C "$repo" cat-file -e "${exp_base}:${idx_path}" 2>/dev/null; then
    git -C "$repo" cat-file blob "${exp_base}:${idx_path}" >"$tmp/live-idx.json" 2>/dev/null || die "cannot read live index"
    existing="$tmp/live-idx.json"
  fi
  bash "$HERE/render-downloads-index.sh" --candidate "$cand" --renderer-config "$snap/renderer-config.json" \
    --notes "$notes" --base-url "$site_base" --release-prefix "$relprefix" --tag "$tag" --version "$version" \
    --published-at "$published_at" ${existing:+--existing "$existing"} >"$tmp/idx.json" || exit $?
  stage_out downloads-index "$idx_path" "$tmp/idx.json"
fi

# ── updater pointer ─────────────────────────────────────────────────────
upd_path="$(out_path updater-pointer)"
if [ -n "$upd_path" ]; then
  bash "$HERE/render-updater-pointer.sh" --candidate "$cand" \
    --candidate-dir "$snap/candidate-dir" --immutable-prefix "$prefix" \
    --version "$version" --out "$tmp/upd.json" || exit $?
  stage_out updater-pointer "$upd_path" "$tmp/upd.json"
fi

# ── equal version must be an exact replay ───────────────────────────────
if [ "$equal_version" = "1" ]; then
  while IFS=$'\t' read -r _ p _ _; do
    if git -C "$repo" cat-file -e "${exp_base}:${p}" 2>/dev/null; then
      git -C "$repo" cat-file blob "${exp_base}:${p}" >"$tmp/live-cmp" 2>/dev/null
      cmp -s "$tmp/live-cmp" "$stage/$p" ||
        refuse "version $version is already live but renders DIFFERENT bytes at $p — this is a conflict, not a replay"
    else
      refuse "version $version is already live but $p does not exist at the trusted base"
    fi
  done <"$tmp/outputs.tsv"
  printf 'render: replay version %s renders byte-identical output\n' "$version" >&2
fi

# ── the render manifest, still in staging ───────────────────────────────
"$JQ" -S -n --arg a "$exp_id" --arg sid "$exp_surface" --arg ch "$exp_channel" \
  --slurpfile o <("$JQ" -R -s 'split("\n") | map(select(length > 0) | split("\t")
     | {role: .[0], repo_path: .[1], size: (.[2]|tonumber), sha256: .[3]})' "$tmp/outputs.tsv") '{
  schema: "blessed/render-manifest/v1", admission_id: $a,
  selected: { surface_id: $sid, channel: $ch }, outputs: $o[0]
}' >"$stage/render-manifest.json" || die "cannot write the render manifest"
vout="$(json_schema_validate_file "$stage/render-manifest.json" "$HERE/references/render-manifest.schema.json")"
[ -z "$vout" ] || {
  printf '%s\n' "$vout" | sed 's/^/render: manifest INVALID /' >&2
  die "render manifest does not conform"
}

# The staged set must equal the manifest, AND the manifest must equal the
# COMPLETE selected declared output set. Being a subset is not enough: a surface
# rendered without one of its declared outputs is a partial surface.
staged="$(cd "$stage" && find . -type f ! -name render-manifest.json | sed 's#^\./##' | sort)"
manifest_paths="$("$JQ" -r '.outputs[].repo_path' "$stage/render-manifest.json" | sort)"
[ "$staged" = "$manifest_paths" ] || die "staging tree does not match the render manifest"
selected_all="$("$JQ" -r --arg ch "$exp_channel" \
  '[.promotion_outputs[] | select((.channel // $ch) == $ch) | .repo_path] | sort | .[]' "$sel")"
[ "$manifest_paths" = "$(printf '%s\n' "$selected_all" | sort)" ] || {
  printf 'render: declared %s\n' "$(printf '%s' "$selected_all" | tr '\n' ' ')" >&2
  printf 'render: rendered %s\n' "$(printf '%s' "$manifest_paths" | tr '\n' ' ')" >&2
  refuse "the rendered outputs are not the complete selected output set for channel '$exp_channel'"
}

# ── publish atomically: one rename into an absent destination ───────────
# Copying file-by-file into the caller's directory means a late failure leaves
# earlier outputs behind. The completed tree is moved in a single rename, so the
# destination either does not exist or is complete.
# `! -e` alone passes for a DANGLING symlink, which `mv` would then replace.
if [ -e "$outdir" ] || [ -L "$outdir" ]; then
  die "--outdir must not exist (a dangling symlink counts); the completed tree is published by a single rename"
fi
parent="$(dirname "$outdir")"
mkdir -p "$parent" || die "cannot create the output parent directory"
# A predictable name plus `rm -rf` would delete a pre-existing sibling that
# merely happened to match. mktemp creates a fresh directory it owns.
sibdir="$(mktemp -d "$parent/.promotion-publish.XXXXXX")" || die "cannot create the publish staging directory"
sib="$sibdir/tree"
cp -R "$stage" "$sib" || {
  rm -rf "$sibdir"
  die "cannot assemble the publish tree"
}
[ -z "${PROMOTION_FAIL_BEFORE_PUBLISH:-}" ] || {
  rm -rf "$sibdir"
  die "injected failure before publish (verification hook)"
}
mv "$sib" "$outdir" || {
  rm -rf "$sibdir"
  die "cannot publish the rendered tree"
}
rmdir "$sibdir" 2>/dev/null || :
printf 'render: published %s output(s)\n' "$(wc -l <"$tmp/outputs.tsv" | tr -d ' ')" >&2
exit 0
