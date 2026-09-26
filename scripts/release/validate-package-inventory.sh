#!/usr/bin/env bash
# validate-package-inventory.sh — validate a blessed/package-repository-inventory/v1
# document (standards/releases/package-repositories.md PR-3, PR-14).
#
# The inventory is the authoritative state of a package-repository-surface:
# repository metadata is generated from it and nothing else. So every
# publication identity must be IN it — product, producer, channel, format,
# architecture and approved distro releases on each repository, and each package
# tied to exactly one repository — and every relation a JSON Schema cannot
# express is checked here, fail closed.
#
# Static: never writes, never reads package bytes, never touches the network.
#
# Exit: 0 valid · 1 invalid · 2 tooling/usage error.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCHEMA="$HERE/references/package-repository-inventory.schema.json"
JQ="${JQ_BIN:-jq}"
MAX_BYTES=4194304

die() {
  printf 'inventory: %s\n' "$1" >&2
  exit 2
}
usage() {
  printf 'Usage: validate-package-inventory.sh --file INVENTORY.json\n' >&2
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
    *) die "unknown argument: $1" ;;
  esac
done
[ -n "$file" ] || usage
command -v "$JQ" >/dev/null 2>&1 || die "jq not found"
[ -f "$SCHEMA" ] || die "packaged canonical schema not found: $SCHEMA"
{ [ -f "$file" ] && [ ! -L "$file" ]; } || die "--file must be a regular file: $file"
size="$(wc -c <"$file" | tr -d ' ')"
[ "$size" -le "$MAX_BYTES" ] || die "input exceeds $MAX_BYTES bytes (got $size)"

tmp="$(mktemp -d)" || die "cannot create temp dir"
trap 'rm -rf "$tmp"' EXIT INT TERM HUP

"$JQ" -e . "$file" >"$tmp/doc.json" 2>/dev/null || {
  printf 'inventory: not valid JSON\n' >&2
  printf 'inventory: INVALID %s\n' "$file" >&2
  exit 1
}

# DUPLICATE KEYS. jq keeps the last of a repeated key without a word, so a
# reviewed inventory could show one value while generation reads another. The
# streaming form emits every leaf's full path; a repeated key repeats a path.
dups="$("$JQ" -c --stream 'select(length == 2) | .[0]' "$file" 2>/dev/null | sort | uniq -d | head -5)"
if [ -n "$dups" ]; then
  printf 'inventory: duplicate JSON keys at %s\n' "$(printf '%s' "$dups" | tr '\n' ' ')" >&2
  printf 'inventory: INVALID %s\n' "$file" >&2
  exit 1
fi

LIB="$HERE/lib/lib-json-schema.sh"
[ -f "$LIB" ] || die "packaged schema library not found: $LIB"
# shellcheck source=scripts/release/lib/lib-json-schema.sh
. "$LIB" || die "packaged schema library failed to source: $LIB"
command -v json_schema_validate_file >/dev/null 2>&1 || die "packaged schema library did not define json_schema_validate_file"
schema_out="$(json_schema_validate_file "$tmp/doc.json" "$SCHEMA")"
schema_rc=$?
if [ "$schema_rc" -ne 0 ] && [ -z "$schema_out" ]; then
  die "schema validator exited $schema_rc with no diagnostics — a tooling failure, not a result"
fi
if [ -n "$schema_out" ]; then
  printf '%s\n' "$schema_out" | sed 's/^/inventory: /' >&2
  printf 'inventory: INVALID %s\n' "$file" >&2
  exit 1
fi
[ "$schema_rc" -eq 0 ] || die "schema validator returned unexpected status $schema_rc"

# shellcheck disable=SC2016  # jq program: $-names are jq variables
sem="$("$JQ" -r '
  def norm: ascii_downcase;
  def dupes: group_by(.) | map(select(length > 1) | .[0]);
  def archset: if .format == "apt" then .architectures else [.arch] end;
  (.repositories | map({key: .id, value: .}) | from_entries) as $repo
  | ( [.producer_keys[] | {k: (.producer_repo | norm), f: .fingerprint}] ) as $pk
  |
  # ── repositories ────────────────────────────────────────────────────────
  ( [.repositories[].id] | dupes | .[] | "duplicate repository id: \(.)" ),
  ( [.repositories[].path] | dupes | .[] | "duplicate repository path: \(.)" ),
  ( [.repositories[] | {id, path}] as $r
    | $r[] as $a | $r[] as $b
    | select($a.id != $b.id and ($b.path | startswith($a.path)))
    | "repository \($b.id) (\($b.path)) is nested inside repository \($a.id) (\($a.path))" ),
  # One repository per (product, format, channel, architecture): anything else
  # leaves a package-manager request with two possible answers.
  ( [ .repositories[] | . as $x | archset[] | "\($x.product)|\($x.format)|\($x.channel)|\(.)" ]
    | dupes | .[] | "ambiguous mapping: more than one repository serves product|format|channel|arch \(.)" ),
  ( .repositories[] | .id as $id | [.targets[] | "\(.distro) \(.release)"] | dupes | .[]
    | "repository \($id): duplicate target \(.)" ),
  # A repository with nothing in it would publish empty metadata (PR-14).
  ( .repositories[] | .id as $id
    | select(([ $root_pkgs[] | select(.repository == $id) ] | length) == 0)
    | "repository \($id) has no packages; an empty repository is refused, not published" ),
  # ── producer keys ───────────────────────────────────────────────────────
  ( [.producer_keys[].fingerprint] | dupes | .[] | "producer key \(.) is declared more than once" ),
  ( [.producer_keys[].fingerprint] | map(select(. == $root_repokey)) | .[]
    | "producer key \(.) is the repository key; the surface and producers are separate credential domains" ),
  # ── packages ────────────────────────────────────────────────────────────
  ( .packages[] | . as $p
    | $repo[$p.repository] as $r
    | if $r == null then "package \($p.file): unknown repository \($p.repository)"
      else
        ( if ($p.candidate.producer_repo | norm) != ($r.producer_repo | norm)
          then "package \($p.file): candidate from \($p.candidate.producer_repo), but repository \($r.id) belongs to \($r.producer_repo)" else empty end ),
        ( if ($p.file | startswith($r.path) | not)
          then "package \($p.file): not under its repository path \($r.path)" else empty end ),
        ( if $r.format == "apt" then
            ( if ($p.file | endswith(".deb") | not) then "package \($p.file): an APT repository serves .deb files" else empty end ),
            ( if ([$r.architectures[], "all"] | index($p.arch)) == null
              then "package \($p.file): arch \($p.arch) is not served by \($r.id) (\($r.architectures | join(",")))" else empty end ),
            ( if $p.signer_fingerprint != null
              then "package \($p.file): a DEB carries no package signer; APT authenticates it through signed metadata" else empty end )
          else
            ( if ($p.file | endswith(".rpm") | not) then "package \($p.file): a DNF repository serves .rpm files" else empty end ),
            ( if ($p.arch != $r.arch and $p.arch != "noarch")
              then "package \($p.file): arch \($p.arch) is not served by \($r.id) (\($r.arch))" else empty end ),
            ( if $p.signer_fingerprint == null
              then "package \($p.file): an RPM must name its native signer (linux-packaging LP-9)"
              elif ([ $pk[] | select(.k == ($r.producer_repo | norm) and .f == $p.signer_fingerprint) ] | length) == 0
              then "package \($p.file): signer \($p.signer_fingerprint) is not a declared key of \($r.producer_repo)"
              else empty end )
          end )
      end ),
  ( [.packages[] | "\(.repository) \(.file)"] | dupes | .[] | "duplicate package file: \(.)" ),
  ( [.packages[] | "\(.repository) \(.name) \(.version)-\(.revision) \(.arch)"] | dupes | .[]
    | "package identity listed twice (one identity, one set of bytes): \(.)" ),
  # ONE IDENTITY, ONE SET OF BYTES — across the WHOLE inventory, not per
  # repository (linux-packaging LP-2). The same package may be promoted into
  # several channels, but only as the same bytes: otherwise switching channel
  # would select different content under an unchanged version and revision.
  ( [ .packages[] | {k: "\(if (.file | endswith(".rpm")) then "rpm" else "deb" end) \(.name) \(.version)-\(.revision) \(.arch)", h: .sha256} ]
    | group_by(.k)[] | select((map(.h) | unique | length) > 1)
    | "package \(.[0].k) resolves to different bytes in different repositories: \(map(.h[0:12]) | unique | join(", "))" ),
  # A package name belongs to one producer: otherwise one producer could ship
  # an update to another'"'"'s package.
  ( [.packages[] | {n: .name, p: (.candidate.producer_repo | norm)}] | group_by(.n)[]
    | select((map(.p) | unique | length) > 1)
    | "package name \(.[0].n) is published by more than one producer: \(map(.p) | unique | join(", "))" )
' --argjson root_pkgs "$("$JQ" -c .packages "$tmp/doc.json")" \
  --arg root_repokey "$("$JQ" -r .repository_key.fingerprint "$tmp/doc.json")" \
  "$tmp/doc.json" 2>&1)"
sem_rc=$?
if [ "$sem_rc" -ne 0 ] && [ -z "$sem" ]; then
  die "semantic checks exited $sem_rc with no output — a tooling failure, not a result"
fi
if [ -n "$sem" ]; then
  printf '%s\n' "$sem" | sed 's/^/inventory: /' >&2
  printf 'inventory: INVALID %s\n' "$file" >&2
  exit 1
fi
[ "$sem_rc" -eq 0 ] || die "semantic checks returned unexpected status $sem_rc"
printf 'inventory: OK %s (%s repositories, %s packages)\n' "$file" \
  "$("$JQ" '.repositories | length' "$tmp/doc.json")" "$("$JQ" '.packages | length' "$tmp/doc.json")"
