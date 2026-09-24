#!/usr/bin/env bash
# shellcheck disable=SC2016  # jq programs: $-names are jq variables, not shell
# render-downloads-index.sh — BOUNDED ADAPTER for docsort.io/downloads-index/v1.
#
# Emits exactly one foreign format, pinned by a const in the renderer_config
# schema. Supporting a second site's index means new code, schema, controls,
# review and a release — never a template, a plugin, or a config-driven shape.
#
# The index is a RUNNING HISTORY, so replacing it with a single freshly-rendered
# version silently deletes every prior release from the download page. The
# existing file is validated against a strict adapter-local schema, every
# historical row is preserved verbatim, and exactly one row is prepended.
#
# Authority is partitioned and never merged:
#   filenames, sizes, digests, version, tag   → the verified candidate
#   published_at                              → the Release receipt
#   base_url and the immutable prefix         → the SURFACE declaration
#   label, os, arch, kind, primary, MIME,
#   selection and ASSET ORDER                 → renderer_config ONLY
#
# receiver-publication.json is NEVER read: it governs how the receiver serves
# objects and disagrees with site-facing MIME for .dmg.
#
# Exit: 0 rendered (index on stdout) | 1 refused | 2 tooling/usage.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JQ="${JQ_BIN:-jq}"

cand="" rcfg="" notes="" base_url="" relprefix="" tag="" version="" published_at="" existing=""
while [ $# -gt 0 ]; do
  case "$1" in
    --candidate)
      cand="${2:-}"
      shift 2
      ;;
    --renderer-config)
      rcfg="${2:-}"
      shift 2
      ;;
    --notes)
      notes="${2:-}"
      shift 2
      ;;
    --base-url)
      base_url="${2:-}"
      shift 2
      ;;
    --release-prefix)
      relprefix="${2:-}"
      shift 2
      ;;
    --tag)
      tag="${2:-}"
      shift 2
      ;;
    --version)
      version="${2:-}"
      shift 2
      ;;
    --published-at)
      published_at="${2:-}"
      shift 2
      ;;
    --existing)
      existing="${2:-}"
      shift 2
      ;;
    *)
      printf 'index: unexpected arg: %s\n' "$1" >&2
      exit 2
      ;;
  esac
done
die() {
  printf 'index: %s\n' "$1" >&2
  exit 2
}
refuse() {
  printf 'index: REFUSE %s\n' "$1" >&2
  exit 1
}
for r in "$cand" "$rcfg" "$notes" "$base_url" "$relprefix" "$tag" "$version" "$published_at"; do
  [ -n "$r" ] || die "--candidate --renderer-config --notes --base-url --release-prefix --tag --version --published-at are required"
done
# The immutable prefix is DECLARED by the surface. Hard-coding "releases/" would
# emit wrong URLs for any surface that declared a different prefix.
case "$relprefix" in
  */) : ;;
  *) die "--release-prefix must end in /" ;;
esac
case "$relprefix" in
  /* | *..*) die "--release-prefix must be relative and free of traversal" ;;
esac
command -v "$JQ" >/dev/null 2>&1 || die "jq not found"
# shellcheck source=scripts/release/lib/lib-json-schema.sh
. "$HERE/lib/lib-json-schema.sh" || die "packaged schema library failed to source"

[ "$("$JQ" -r '.target_format // ""' "$rcfg")" = "docsort.io/downloads-index/v1" ] ||
  die "renderer_config targets a format this adapter does not emit"

[ -f "$notes" ] || die "notes file not found: $notes"
want_notes="$("$JQ" -r '.public_notes.sha256' "$cand")"
have_notes="$(shasum -a 256 "$notes" | awk '{print $1}')"
[ "$want_notes" = "$have_notes" ] ||
  refuse "notes digest $have_notes does not match the candidate's public_notes.sha256 $want_notes"

unclassified="$("$JQ" -r --slurpfile p "$rcfg" '[.artifacts[].id] - ($p[0].artifacts | keys) | join(", ")' "$cand")"
[ -z "$unclassified" ] || refuse "renderer_config does not classify artifact(s): $unclassified"
stale="$("$JQ" -r --slurpfile c "$cand" '(.artifacts | keys) - [$c[0].artifacts[].id] | join(", ")' "$rcfg")"
[ -z "$stale" ] || refuse "renderer_config classifies artifact id(s) absent from the candidate: $stale"
included="$("$JQ" -r '[.artifacts[] | select(has("include"))] | length' "$rcfg")"
[ "$included" -gt 0 ] || refuse "renderer_config excludes every artifact — the index would offer no downloads"
# Two policy entries may not claim one OUTPUT id: the rendered row would carry
# duplicate asset ids, and a consumer keying on them would silently drop one.
dupout="$("$JQ" -r '[.artifacts[] | select(has("include")) | .include.id] | group_by(.) | map(select(length > 1) | .[0]) | join(", ")' "$rcfg")"
[ -z "$dupout" ] || refuse "renderer_config maps more than one artifact to output id(s): $dupout"

tmpd="$(mktemp -d)" || die "cannot create temp dir"
trap 'rm -rf "$tmpd"' EXIT INT TERM HUP
printf '[]\n' >"$tmpd/hist.json"
printf 'null\n' >"$tmpd/prior.json"

if [ -n "$existing" ] && [ -f "$existing" ]; then
  "$JQ" -e . "$existing" >/dev/null 2>&1 ||
    refuse "existing downloads index is not valid JSON — refusing to replace a file whose state cannot be read"
  vout="$(json_schema_validate_file "$existing" "$HERE/references/docsort-downloads-index.schema.json")"
  [ -z "$vout" ] || {
    printf '%s\n' "$vout" | sed 's/^/index: existing index INVALID /' >&2
    refuse "existing downloads index does not conform to docsort.io/downloads-index/v1"
  }
  bad="$("$JQ" -r --arg p "$("$JQ" -r .project "$cand")" --arg b "$base_url" '
    def canonok($base): . as $u
      | ($u | split("/")) as $seg
      | ($seg | length) > 1
        and ($seg[0] == "")
        and (($seg[1:] | map(select(. == "" or . == "." or . == "..")) | length) == 0)
        and ($u | startswith($base + "/"));
    # Decimal-string ordering: jq numbers are IEEE-754 doubles, so a component
    # beyond 2^53 would compare equal to its neighbours.
    def vkey: .version | split(".") | map([(length), .]);
    [ (if .project != $p then "index project \(.project) != candidate \($p)" else empty end),
      (if .base_url != $b then "index base_url \(.base_url) != surface-derived \($b)" else empty end),
      (if .latest != .versions[0].tag then "latest \(.latest) is not versions[0].tag \(.versions[0].tag)" else empty end),
      (if ([.versions[].tag] | length) != ([.versions[].tag] | unique | length) then "duplicate version tags in history" else empty end),
      (if ([.versions[].version] | length) != ([.versions[].version] | unique | length) then "duplicate versions in history" else empty end),
      (.versions[] | select(.tag != ("v" + .version)) | "row \(.version): tag and version disagree"),
      (if ([.versions[] | vkey] | . as $v | ($v | sort | reverse) != $v) then "history is not in descending version order" else empty end),
      (.versions[] | . as $r | ($r.assets | map(.id)) as $x
        | if ($x | length) != ($x | unique | length) then "row \($r.version): duplicate asset ids" else empty end),
      (.versions[] | . as $r | ($r.assets | map(.filename)) as $x
        | if ($x | length) != ($x | unique | length) then "row \($r.version): duplicate asset filenames" else empty end),
      (.versions[] | . as $r | ($r.assets | map(.url)) as $x
        | if ($x | length) != ($x | unique | length) then "row \($r.version): duplicate asset urls" else empty end),
      # Containment is decided on PATH COMPONENTS. A raw prefix test accepts
      # "/base/../elsewhere" and "/base//x", which do not resolve inside base.
      (.versions[] | . as $r | $r.assets[] | . as $a
        | select(($a.url | canonok($b)) | not) | "row \($r.version): asset \($a.id) url is not canonically inside base_url"),
      (.versions[] | select((.notes_url | canonok($b)) | not) | "row \(.version): notes_url is not canonically inside base_url"),
      (.versions[] | select((.manifest_url | canonok($b)) | not) | "row \(.version): manifest_url is not canonically inside base_url"),
      (.versions[] | . as $r | ($r.assets | map(.id)) as $x
        | if ($x | map(select(. == "" or (test("^[a-z0-9][a-z0-9._-]*$") | not))) | length) > 0
          then "row \($r.version): asset id is not a canonical token" else empty end)
    ] | .[]' "$existing")" || die "existing-index validation failed to evaluate"
  [ -z "$bad" ] || {
    printf '%s\n' "$bad" | sed 's/^/index: REFUSE /' >&2
    exit 1
  }
  "$JQ" -c --arg t "$tag" '[.versions[] | select(.tag != $t)]' "$existing" >"$tmpd/hist.json"
  "$JQ" -c --arg t "$tag" '[.versions[] | select(.tag == $t)] | first // null' "$existing" >"$tmpd/prior.json"
fi

# ── build the desired row independently of whatever is already there ──────
"$JQ" --slurpfile p "$rcfg" --arg b "$base_url" --arg pre "${base_url}/${relprefix}${tag}/" \
  --arg t "$tag" --arg v "$version" --arg pa "$published_at" --rawfile n "$notes" '
  ($p[0].artifacts) as $pol
  | ($p[0].artifacts | keys_unsorted) as $order
  | (.artifacts | map({key: .id, value: .}) | from_entries) as $art
  | {
      tag: $t, version: $v, published_at: $pa, notes: $n,
      notes_url: ($pre + .public_notes.filename),
      manifest_url: ($pre + "manifest.json"),
      assets: [ $order[]
        | select($pol[.] | has("include"))
        | . as $id | $pol[$id].include as $i | $art[$id] as $a
        | { id: $i.id, label: $i.label, os: $i.os, arch: $i.arch, kind: $i.kind,
            primary: $i.primary, filename: $a.filename, url: ($pre + $a.filename),
            content_type: $i.content_type, size_bytes: $a.size, sha256: $a.sha256 } ]
    }' "$cand" >"$tmpd/row.json" || die "row rendering failed"

# ── the completed row must be internally coherent before it goes anywhere ──
rowbad="$("$JQ" -r '
  [ (if (.tag != ("v" + .version)) then "row tag and version disagree" else empty end),
    ((.assets | map(.id)) as $x | if ($x|length) != ($x|unique|length) then "duplicate asset ids in the new row" else empty end),
    ((.assets | map(.filename)) as $x | if ($x|length) != ($x|unique|length) then "duplicate asset filenames in the new row" else empty end),
    ((.assets | map(.url)) as $x | if ($x|length) != ($x|unique|length) then "duplicate asset urls in the new row" else empty end),
    (.assets[] | select((.url | split("/") | .[1:] | map(select(. == "" or . == "." or . == "..")) | length) > 0)
      | "asset \(.id) url has an empty, . or .. component")
  ] | .[]' "$tmpd/row.json")" || die "new-row validation failed to evaluate"
[ -z "$rowbad" ] || {
  printf '%s\n' "$rowbad" | sed 's/^/index: REFUSE /' >&2
  exit 1
}

# ── a row already exists for this tag: retain if equivalent, else conflict ──
# Deleting and replacing it silently would hide a changed candidate, policy, or
# receipt behind a version consumers already have.
if [ "$("$JQ" -r 'if . == null then "no" else "yes" end' "$tmpd/prior.json")" = "yes" ]; then
  "$JQ" -S -c . "$tmpd/prior.json" >"$tmpd/a.json"
  "$JQ" -S -c . "$tmpd/row.json" >"$tmpd/b.json"
  if cmp -s "$tmpd/a.json" "$tmpd/b.json"; then
    printf 'index: existing row for %s is exactly equivalent; retained unchanged\n' "$tag" >&2
    cat "$existing"
    exit 0
  fi
  diffk="$("$JQ" -r -n --slurpfile a "$tmpd/a.json" --slurpfile b "$tmpd/b.json" '
    [ ($a[0] | keys[]), ($b[0] | keys[]) ] | unique
    | map(select(($a[0][.] // null) != ($b[0][.] // null))) | join(", ")')"
  refuse "an index row for $tag already exists and differs (fields: ${diffk:-unknown}) — a changed candidate, policy, receipt, or asset set under a published version is a conflict, not a replacement"
fi

"$JQ" --slurpfile h "$tmpd/hist.json" --slurpfile r "$tmpd/row.json" \
  --arg b "$base_url" --arg t "$tag" '{
    schema: "docsort.io/downloads-index/v1",
    project: .project,
    base_url: $b,
    latest: $t,
    versions: ([$r[0]] + $h[0])
  }' "$cand" >"$tmpd/final.json" || die "index rendering failed"

# The completed document is validated exactly as an existing one would be, so
# this adapter can never emit something it would itself refuse to read.
vout="$(json_schema_validate_file "$tmpd/final.json" "$HERE/references/docsort-downloads-index.schema.json")"
[ -z "$vout" ] || {
  printf '%s\n' "$vout" | sed 's/^/index: rendered index INVALID /' >&2
  die "the adapter produced a non-conforming index"
}
finalbad="$("$JQ" -r '
  [ (if .latest != .versions[0].tag then "latest is not versions[0].tag" else empty end),
    (if ([.versions[].tag] | length) != ([.versions[].tag] | unique | length) then "duplicate version tags" else empty end),
    (if ([.versions[] | .version | split(".") | map([(length), .])] | . as $v | ($v | sort | reverse) != $v)
      then "versions are not in descending order" else empty end)
  ] | .[]' "$tmpd/final.json")" || die "final-document validation failed to evaluate"
[ -z "$finalbad" ] || {
  printf '%s\n' "$finalbad" | sed 's/^/index: REFUSE /' >&2
  exit 1
}
cat "$tmpd/final.json"
exit 0
