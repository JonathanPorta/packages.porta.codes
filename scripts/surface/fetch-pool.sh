#!/usr/bin/env bash
# fetch-pool.sh — gather every package the inventory names into a pool
# directory, each byte checked against the inventory (sha256 and size) before it
# is kept (blessed releases.package-repositories@1 PR-4, PR-9).
#
# Sources, in order:
#   1. RETAINED: already published — fetched from --retained-base (the public
#      surface, https://packages.porta.codes/). A published object whose bytes
#      are not the inventory's is REFUSED, never replaced from elsewhere:
#      published bytes are immutable, so a mismatch means something is wrong.
#   2. NEW: from the producer's release named by the package's candidate —
#      `gh release download` with GH_TOKEN (the candidate-ingest credential), or
#      --local-releases DIR/<owner>/<repo>/<tag>/<file> for offline tests.
#
# Exit: 0 complete · 1 refused (a byte mismatch, or a package found nowhere) ·
#       2 tooling/usage.
# shellcheck disable=SC2016  # jq programs: $-names are jq variables, not shell
set -uo pipefail
JQ="${JQ_BIN:-jq}"
die() {
  printf 'fetch-pool: %s\n' "$1" >&2
  exit 2
}
refuse() {
  printf 'fetch-pool: REFUSED — %s\n' "$1" >&2
  exit 1
}
usage() {
  printf 'Usage: fetch-pool.sh --inventory INVENTORY.json --pool DIR [--retained-base URL] [--local-releases DIR]\n' >&2
  exit 2
}
inv="" pool="" rbase="" local_rel=""
while [ $# -gt 0 ]; do
  case "$1" in
    --inventory) inv="${2:-}" && shift 2 ;;
    --pool) pool="${2:-}" && shift 2 ;;
    --retained-base) rbase="${2:-}" && shift 2 ;;
    --local-releases) local_rel="${2:-}" && shift 2 ;;
    -h | --help) usage ;;
    *) die "unknown argument: $1" ;;
  esac
done
if [ -z "$inv" ] || [ -z "$pool" ]; then usage; fi
for t in "$JQ" curl sha256sum; do command -v "$t" >/dev/null 2>&1 || die "required tool not found: $t"; done
[ -n "$rbase" ] || rbase="$("$JQ" -r .public_base_url "$inv")"
mkdir -p "$pool"
tmp="$(mktemp -d)" || die "cannot create a work directory"
trap 'rm -rf "$tmp"' EXIT
sha() { sha256sum "$1" | cut -d' ' -f1; }
size() { wc -c <"$1" | tr -d ' '; }
good() { [ -f "$1" ] && [ "$(sha "$1")" = "$2" ] && [ "$(size "$1")" = "$3" ]; }

n_have=0 n_ret=0 n_new=0
while IFS=$'\t' read -r f h s producer tag; do
  dst="$pool/$f"
  if good "$dst" "$h" "$s"; then
    n_have=$((n_have + 1))
    continue
  fi
  mkdir -p "$(dirname "$dst")"
  rm -f "$tmp/x"
  code="$(curl -sS -o "$tmp/x" -w '%{http_code}' "$rbase$f" 2>/dev/null || true)"
  case "$code" in
    200 | 000)
      # 000 is curl's code for file:// (used by the local harness).
      if [ -s "$tmp/x" ]; then
        good "$tmp/x" "$h" "$s" || refuse "the PUBLISHED $f is not the inventory's bytes; published objects are never replaced"
        mv "$tmp/x" "$dst"
        n_ret=$((n_ret + 1))
        continue
      fi
      ;;
    404 | 403) ;;
    *) die "unexpected HTTP $code for retained $rbase$f" ;;
  esac
  base="$(basename "$f")"
  if [ -n "$local_rel" ]; then
    src="$local_rel/$producer/$tag/$base"
    [ -f "$src" ] || refuse "$f is neither published nor in $producer's $tag release"
    cp "$src" "$tmp/x"
  else
    : "${GH_TOKEN:?GH_TOKEN (the candidate-ingest read credential) is required to fetch new packages}"
    mkdir -p "$tmp/rel"
    rm -f "$tmp/rel/$base"
    gh release download "$tag" --repo "$producer" --pattern "$base" --dir "$tmp/rel" >/dev/null 2>&1 ||
      refuse "$f is neither published nor downloadable from $producer's $tag release"
    mv "$tmp/rel/$base" "$tmp/x"
  fi
  good "$tmp/x" "$h" "$s" || refuse "$producer's $tag release asset $base is not the inventory's bytes"
  mv "$tmp/x" "$dst"
  n_new=$((n_new + 1))
done < <("$JQ" -r '.packages[] | [.file, .sha256, (.size | tostring), .candidate.producer_repo, .candidate.tag] | @tsv' "$inv")
printf 'fetch-pool: OK — %s already present, %s retained from %s, %s new from producer releases\n' "$n_have" "$n_ret" "$rbase" "$n_new"
