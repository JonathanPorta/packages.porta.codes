#!/usr/bin/env bash
# validate-surfaces.sh — validate a repo-local blessed/release-surfaces/v1 declaration.
#
# One pinned Mike Farah yq v4 converts YAML to JSON exactly once, guarded by a
# bounded preflight, and the packaged JSON-Schema validator plus semantic checks
# do the rest. There is no second YAML parser anywhere in this path.
#
# WHY THE PREFLIGHT EXISTS: several YAML constructs are ERASED by conversion, so
# a post-conversion JSON check provably cannot see them. Duplicate keys are the
# sharpest case — yq emits duplicate JSON keys and exits 0, and jq then silently
# keeps the last one. Anchors, aliases, merge keys, and custom tags likewise
# vanish into ordinary values. Each is detected BEFORE/AS we convert, using yq
# itself.
#
# This validator is STATIC. It never writes, never resolves a path on disk, and
# makes no claim about symlink safety or atomicity — those belong to the
# generator (Project B).
#
# Exit codes:
#   0 — valid
#   1 — invalid (schema, semantic, or preflight violation)
#   2 — tooling/usage error (fail closed)
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# The canonical schema is PACKAGED and not overridable. A --schema flag would let
# a caller swap in a permissive schema and have this CLI report OK for a document
# that is not a release-surfaces declaration at all.
SCHEMA="$HERE/references/release-surfaces.schema.json"
YQ="${YQ_BIN:-yq}"
# Indirection mirrors YQ_BIN so the jq-side failure paths are testable too.
JQ="${JQ_BIN:-jq}"
# EXACT version CI actually executes. Advertising a RANGE would claim coverage the
# preflight suite has never run against real binaries; widen only after it has.
YQ_EXACT="4.53.2"
# HARD maximum. The environment may lower it but must never raise it.
MAX_BYTES_HARD=262144
MAX_BYTES="${SURFACES_MAX_BYTES:-$MAX_BYTES_HARD}"
case "$MAX_BYTES" in *[!0-9]* | "") MAX_BYTES="$MAX_BYTES_HARD" ;; esac
[ "$MAX_BYTES" -le "$MAX_BYTES_HARD" ] || MAX_BYTES="$MAX_BYTES_HARD"
ALLOWED_TAGS='!!map|!!seq|!!str|!!int|!!float|!!bool|!!null'

usage() {
  cat >&2 <<'EOF'
Usage: validate-surfaces.sh --file release-surfaces.yaml

Validates a blessed/release-surfaces/v1 declaration: bounded YAML preflight,
one yq v4 conversion, packaged JSON-Schema validation, then semantic checks.
The canonical schema is packaged and CANNOT be overridden.
Exit 0 = valid; 1 = invalid; 2 = tooling/usage error.
EOF
  exit 2
}

file=""
while [ $# -gt 0 ]; do
  case "$1" in
    --file)
      file="${2:-}"
      shift 2
      ;;
    -h | --help) usage ;;
    *)
      printf 'surfaces: unexpected arg: %s\n' "$1" >&2
      usage
      ;;
  esac
done
[ -n "$file" ] || usage

fail=0
violation() {
  printf 'surfaces: %s\n' "$1" >&2
  fail=1
}
die() {
  printf 'surfaces: %s\n' "$1" >&2
  exit 2
}

# ── tooling: flavor + tested version range ──────────────────────────────────
command -v "$YQ" >/dev/null 2>&1 || die "yq not found (need Mike Farah yq v4; set YQ_BIN)"
yq_ver_raw="$("$YQ" --version 2>/dev/null)" || die "cannot run '$YQ --version'"
case "$yq_ver_raw" in
  *mikefarah*) ;;
  *) die "wrong yq flavor: '$yq_ver_raw'. The python yq is NOT supported; install mikefarah/yq v4" ;;
esac
yq_ver="$(printf '%s' "$yq_ver_raw" | sed -n 's/.*version v\{0,1\}\([0-9][0-9.]*\).*/\1/p')"
[ -n "$yq_ver" ] || die "cannot parse yq version from '$yq_ver_raw'"
[ "$yq_ver" = "$YQ_EXACT" ] || die "yq $yq_ver is not the tested version $YQ_EXACT — CI executes only $YQ_EXACT, so any other build is untested against this preflight"
command -v "$JQ" >/dev/null 2>&1 || die "jq not found"
[ -f "$SCHEMA" ] || die "packaged canonical schema not found: $SCHEMA"
{ [ -f "$file" ] && [ ! -L "$file" ]; } || die "--file must be a regular file: $file"

tmp="$(mktemp -d)" || die "cannot create temp dir"
trap 'rm -rf "$tmp"' EXIT INT TERM HUP

size="$(wc -c <"$file" | tr -d ' ')"
[ "$size" -le "$MAX_BYTES" ] || die "input exceeds $MAX_BYTES bytes (got $size)"

# ── bounded YAML preflight (constructs conversion would erase) ──────────────
# EVERY probe captures its exit status. A probe that fails silently would erase
# the construct it was meant to detect: a yq that errors only on the anchor query
# leaves an anchored document reported as OK while conversion quietly expands it.
# PROBE_OUT carries the result. Do NOT wrap these in $( ) — die() inside a
# command substitution exits only the subshell, which downgrades a tooling
# failure to a mere INVALID verdict.
PROBE_OUT=""
probe() { # $1=description  $2..=yq args
  local what="$1"
  shift
  local rc
  "$YQ" "$@" "$file" >"$tmp/probe.out" 2>/dev/null
  rc=$?
  [ "$rc" -eq 0 ] || die "YAML preflight probe '$what' failed (yq exit $rc) — cannot verify the document"
  PROBE_OUT="$(cat "$tmp/probe.out")"
}
jqprobe() { # $1=description  $2=stdin  $3..=jq args
  local what="$1" input="$2"
  shift 2
  local rc
  printf '%s' "$input" | "$JQ" "$@" >"$tmp/probe.out" 2>/dev/null
  rc=$?
  [ "$rc" -eq 0 ] || die "YAML preflight probe '$what' failed (jq exit $rc) — cannot verify the document"
  PROBE_OUT="$(cat "$tmp/probe.out")"
}

# probe() strips the trailing newline, so count records with awk rather than wc -l.
# Establish PARSEABILITY once, before any probe. A probe cannot tell "the
# document is malformed" from "the tool is broken" — both exit nonzero — so
# malformed input must be classified here as INVALID rather than as a tooling
# failure. Every later probe runs on a document already known to parse, so a
# nonzero status there really does mean the tool failed.
if ! "$YQ" 'true' "$file" >/dev/null 2>&1; then
  violation "not parseable as YAML"
  printf 'surfaces: INVALID\n' >&2
  exit 1
fi

probe 'document count' 'documentIndex'
docs="$(printf '%s' "$PROBE_OUT" | awk 'END{print NR+0}')"
[ "${docs:-0}" -le 1 ] || violation "multiple YAML documents ($docs) — exactly one is allowed"

probe 'root kind' 'kind'
root_kind="$(printf '%s' "$PROBE_OUT" | head -1)"
[ "$root_kind" = "map" ] || violation "root must be a mapping, got '${root_kind:-<unparseable>}'"

# `..` walks VALUES only; `...` includes mapping KEYS, which can carry their own
# tags, anchors, and aliases.
probe 'anchors' '[... | select(anchor != "")] | length'
anchors="$(printf '%s' "$PROBE_OUT" | head -1)"
[ "${anchors:-1}" -eq 0 ] || violation "YAML anchors are not permitted ($anchors found) — conversion erases them"
probe 'aliases' '[... | select(kind == "alias")] | length'
aliases="$(printf '%s' "$PROBE_OUT" | head -1)"
[ "${aliases:-1}" -eq 0 ] || violation "YAML aliases/merge keys are not permitted ($aliases found) — conversion erases them"

# yq reports the SAME tag for an implicit value (`p: 5` -> !!int) and an explicit
# one (`p: !!int 5`), so tag identity cannot distinguish them. In v4.53.2
# explicitness is style "tagged" on scalars and "<unknown>" on collections, while
# untagged collections report "flow" or "". This mapping is version-specific,
# which is exactly why the version is pinned exactly.
probe 'explicit tags' -o=json '[... | select(style == "tagged" or style == "<unknown>") | tag]'
jqprobe 'explicit tag list' "$PROBE_OUT" -r 'unique | join(", ")'
tagged="$PROBE_OUT"
[ -z "$tagged" ] || violation "explicit YAML tags are not permitted: $tagged"

probe 'tag inventory' -o=json '[... | tag]'
# shellcheck disable=SC2016  # $ok is a jq variable, deliberately not shell-expanded
jqprobe 'custom tag list' "$PROBE_OUT" -r --arg ok "$ALLOWED_TAGS" '[.[] | select(test("^(" + $ok + ")$") | not)] | unique | join(", ")'
custom_tags="$PROBE_OUT"
[ -z "$custom_tags" ] || violation "custom YAML tags are not permitted: $custom_tags"

# Duplicate keys: yq counts every key it parsed; jq counts what survived. A
# mismatch at ANY depth means conversion silently dropped a key.
probe 'key counts' -o=json '[... | select(kind == "map") | keys | length]'
jqprobe 'key count sum' "$PROBE_OUT" 'add // 0'
yq_keys="$PROBE_OUT"

# ── one conversion; rc != 0 discards stdout entirely ────────────────────────
json="$("$YQ" -o=json '.' "$file" 2>/dev/null)"
rc=$?
if [ "$rc" -ne 0 ]; then
  violation "YAML conversion failed (yq exit $rc) — partial output discarded"
  printf 'surfaces: INVALID\n' >&2
  exit 1
fi
[ -n "$json" ] || violation "YAML conversion produced no output"

if [ "$fail" -eq 0 ]; then
  json_keys="$(printf '%s' "$json" | "$JQ" '[.. | objects | keys | length] | add // 0' 2>/dev/null)"
  json_keys_rc=$?
  [ "$json_keys_rc" -eq 0 ] || die "surviving-key count failed (jq exit $json_keys_rc) — cannot verify the document"
  if [ "${yq_keys:-0}" != "${json_keys:-0}" ]; then
    violation "duplicate mapping keys (parsed ${yq_keys:-?}, survived ${json_keys:-?}) — conversion would silently keep the last value"
  fi
fi

if [ "$fail" -ne 0 ]; then
  printf 'surfaces: INVALID\n' >&2
  exit 1
fi

printf '%s' "$json" >"$tmp/doc.json"

# ── structural: packaged JSON-Schema validator ──────────────────────────────
LIB="$HERE/lib/lib-json-schema.sh"
[ -f "$LIB" ] || die "packaged schema library not found: $LIB"
# shellcheck source=scripts/release/lib/lib-json-schema.sh
. "$LIB" || die "packaged schema library failed to source: $LIB"
command -v json_schema_validate_file >/dev/null 2>&1 || die "packaged schema library did not define json_schema_validate_file"

# Capture output and status INDEPENDENTLY. Only rc=0 with empty diagnostics is
# valid; a nonzero status with no output means the validator crashed, which is a
# tooling failure and must never read as "valid".
schema_out="$(json_schema_validate_file "$tmp/doc.json" "$SCHEMA")"
schema_rc=$?
if [ "$schema_rc" -ne 0 ] && [ -z "$schema_out" ]; then
  die "schema validator exited $schema_rc with no diagnostics — treating as a tooling failure, not a result"
fi
if [ -n "$schema_out" ]; then
  printf '%s\n' "$schema_out" | sed 's/^/surfaces: /' >&2
  fail=1
elif [ "$schema_rc" -ne 0 ]; then
  die "schema validator returned unexpected status $schema_rc"
fi

# ── semantic: relational rules a JSON Schema cannot express ─────────────────
# Collision namespaces are SCOPED deliberately. Reusing an output id, a
# role/channel pair, or a raw relative path in two INDEPENDENT surfaces is
# harmless; what must be unique is the resolved destination.
if [ "$fail" -eq 0 ]; then
  # shellcheck disable=SC2016  # jq program: $-names are jq variables, not shell
  sem="$("$JQ" -r '
    def norm: ascii_downcase;
    def dupes($a): $a | group_by(.) | map(select(length > 1) | .[0]) | unique;
    def canon_base($s): $s.public_base_url;

    ( [ .surfaces[].id ] | dupes(.) | .[] | "duplicate surface id: \(.)" ),

    ( .surfaces[] as $s
      | ( [ $s.producer_repos[] | norm ] ) as $pn
      | ( $s.owner_repo | norm ) as $on
      | (
          ( $pn | dupes(.) | .[] | "surface \($s.id): case-variant duplicate producer_repos entry: \(.)" ),
          ( ( [ $pn[] | select(. != $on) ] | length > 0 ) as $cross
            | ( $s | has("publisher_model") ) as $hp
            | ( $s | has("promotion_transport") ) as $ht
            | if $cross then
                ( if ($hp | not) then "surface \($s.id): cross-repo requires publisher_model" else empty end ),
                ( if ($ht | not) then "surface \($s.id): cross-repo requires promotion_transport" else empty end ),
                ( if ($s.kind == "public-download-surface" or $s.kind == "public-github-mirror" or $s.kind == "package-repository-surface") then
                    ( if ($hp and $s.publisher_model != "surface-pull")
                      then "surface \($s.id): kind \($s.kind) cross-repo supports only publisher_model surface-pull, got \($s.publisher_model)" else empty end )
                  else
                    "surface \($s.id): cross-repo \($s.kind) has no supported publisher/transport model in v1 — fail closed until a versioned model is defined"
                  end )
              else
                ( if ($hp != $ht) then "surface \($s.id): same-repo surface must declare BOTH publisher_model and promotion_transport or NEITHER" else empty end ),
                ( if ($hp and $ht) then "surface \($s.id): same-repo surface has no explicitly supported publisher/transport pair in v1" else empty end )
              end )
        ) ),

    # OUTPUT IDENTITY: (surface_id, output.id) — ids may repeat across surfaces.
    ( [ .surfaces[] | .id as $sid | (.promotion_outputs // [])[] | "\($sid)|\(.id)" ]
      | dupes(.) | .[] | "duplicate output identity (surface, id): \(.)" ),

    # RENDERER IDENTITY: (surface_id, role, channel) — a renderer type may serve
    # many channels, and two surfaces may each have their own stable channel.
    # Channel-less roles use an explicit sentinel rather than being skipped:
    # skipping them let a surface declare two downloads-index outputs, of which
    # a generator would silently render only the first.
    ( [ .surfaces[] | .id as $sid | (.promotion_outputs // [])[] | "\($sid)|\(.role)|\(.channel // "-")" ]
      | dupes(.) | .[] | "duplicate renderer identity (surface, role, channel): \(.)" ),

    # At most ONE downloads-index per surface. A second one is unrenderable: the
    # index is the whole download page for a surface, not a per-channel view.
    ( [ .surfaces[] | .id as $sid
        | select(([ (.promotion_outputs // [])[] | select(.role == "downloads-index") ] | length) > 1)
        | "surface \($sid) declares more than one downloads-index output" ] | .[] ),

    # REPOSITORY DESTINATION: (lowercase(owner_repo), repo_path). Two surfaces in
    # DIFFERENT repositories may legitimately write the same relative path.
    ( [ .surfaces[] | (.owner_repo | norm) as $o | (.promotion_outputs // [])[] | "\($o)|\(.repo_path)" ]
      | dupes(.) | .[] | "duplicate repository destination (owner_repo, repo_path): \(.)" ),

    # PUBLIC DESTINATION: the resolved absolute URL, so different base/path splits
    # that resolve to the same URL collide.
    ( [ .surfaces[] | select(has("public_base_url")) | canon_base(.) as $b | (.promotion_outputs // [])[] | select(has("public_path")) | ($b + .public_path) ]
      | dupes(.) | .[] | "duplicate public destination URL: \(.)" ),

    # IMMUTABLE NAMESPACE: equality and nesting across surfaces.
    ( [ .surfaces[] | select(has("public_base_url") and has("immutable_release_prefix"))
        | { id: .id, ns: (canon_base(.) + .immutable_release_prefix) } ] ) as $nsl
    | ( range(0; $nsl | length) as $i
        | range(0; $nsl | length) as $j
        | select($i < $j)
        | select( ($nsl[$i].ns == $nsl[$j].ns)
                  or ($nsl[$i].ns | startswith($nsl[$j].ns))
                  or ($nsl[$j].ns | startswith($nsl[$i].ns)) )
        | "surfaces \($nsl[$i].id) and \($nsl[$j].id) claim overlapping immutable namespaces: \($nsl[$i].ns) vs \($nsl[$j].ns)" ),

    # No public output may land inside ANY surface immutable namespace.
    # NOTE: `,` binds LOOSER than `|` in jq, so this whole clause is parenthesized.
    # Without the parens the next clause would be evaluated with `.` set to an
    # element of this stream instead of the document, and would silently vanish.
    ( [ .surfaces[] | select(has("public_base_url")) | .id as $sid | .public_base_url as $b
        | (.promotion_outputs // [])[] | select(has("public_path"))
        | { url: ($b + .public_path), sid: $sid } ] ) as $outs
    | ( [ .surfaces[] | select(has("public_base_url") and has("immutable_release_prefix"))
          | { id: .id, ns: (.public_base_url + .immutable_release_prefix) } ] ) as $nss
    | ( $nss[] as $ns
        | $outs[] as $o
        | select($o.url | startswith($ns.ns))
        | "public output \($o.url) (surface \($o.sid)) lies inside the immutable namespace of surface \($ns.id) (\($ns.ns))" ),

    # A package repository owns its WHOLE base URL: APT/DNF clients resolve
    # every path under it. No other surface may share, contain, or sit inside
    # it, or two owners would be writing one namespace.
    ( [ .surfaces[] | select(has("public_base_url")) | { id: .id, kind: .kind, b: .public_base_url } ] ) as $bases
    | ( [ range(0; $bases | length) ] | combinations(2)
        | select(.[0] < .[1]) | [ $bases[.[0]], $bases[.[1]] ]
        | .[0] as $x | .[1] as $y
        | select($x.kind == "package-repository-surface" or $y.kind == "package-repository-surface")
        | select(($x.b | startswith($y.b)) or ($y.b | startswith($x.b)))
        | "surfaces \($x.id) and \($y.id) overlap at \($x.b) / \($y.b); a package-repository-surface must own its base URL alone" ),

    ( .surfaces[] | select(.kind == "public-download-surface")
      | ( if ([ .promotion_outputs[] | select(.role == "channel-pointer") ] | length) < 1
          then "surface \(.id): public-download-surface requires at least one channel-pointer output" else empty end ) )
  ' "$tmp/doc.json" 2>&1)"
  sem_rc=$?
  # A nonzero jq status with no output is a tooling failure, never "no findings".
  if [ "$sem_rc" -ne 0 ] && [ -z "$sem" ]; then
    die "semantic checks exited $sem_rc with no output — treating as a tooling failure, not a result"
  fi
  if [ -n "$sem" ]; then
    printf '%s\n' "$sem" | sed 's/^/surfaces: /' >&2
    fail=1
  elif [ "$sem_rc" -ne 0 ]; then
    die "semantic checks returned unexpected status $sem_rc"
  fi
fi

if [ "$fail" -eq 0 ]; then
  printf 'surfaces: OK %s\n' "$file" >&2
  exit 0
fi
printf 'surfaces: INVALID\n' >&2
exit 1
