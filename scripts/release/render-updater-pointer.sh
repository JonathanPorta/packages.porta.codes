#!/usr/bin/env bash
# shellcheck disable=SC2016  # jq programs: $-names are jq variables, not shell
# render-updater-pointer.sh — validate and BYTE-COPY the producer's updater feed.
#
# Blessed does not compose this file. The producer builds and signs latest.json
# into the candidate; this stage validates it and copies the exact bytes. It is
# deliberately a copy and not a re-serialization: parsing and re-emitting would
# change bytes an installed updater client may compare, and it would make Blessed
# a second author of facts the producer already signed. A reserialization control
# exists precisely to keep someone from "cleaning up" this stage later.
#
# Selection is a bounded v1 contract: the feed is the candidate file named
# exactly `latest.json`. It is never chosen by extension, glob, or heuristic.
#
# Validated BEFORE copying, against the verified candidate:
#   - conforms to blessed/updater-pointer/v1;
#   - version equals the candidate version;
#   - every platform URL is absolute HTTPS under this release's immutable prefix;
#   - every URL basename is a real candidate artifact;
#   - every signature equals that artifact's detached signature file, encoded as
#     its DECLARED signature profile encodes it (base64 of the raw bytes for
#     ed25519-detached-v1; the file verbatim for tauri-minisign-v1, whose
#     sidecar is already a base64 document).
#
# Exit: 0 copied | 1 refused | 2 tooling/usage.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JQ="${JQ_BIN:-jq}"

cand="" cdir="" prefix="" version="" out=""
while [ $# -gt 0 ]; do
  case "$1" in
    --candidate)
      cand="${2:-}"
      shift 2
      ;;
    --candidate-dir)
      cdir="${2:-}"
      shift 2
      ;;
    --immutable-prefix)
      prefix="${2:-}"
      shift 2
      ;;
    --version)
      version="${2:-}"
      shift 2
      ;;
    --out)
      out="${2:-}"
      shift 2
      ;;
    *)
      printf 'updater: unexpected arg: %s\n' "$1" >&2
      exit 2
      ;;
  esac
done
die() {
  printf 'updater: %s\n' "$1" >&2
  exit 2
}
refuse() {
  printf 'updater: REFUSE %s\n' "$1" >&2
  exit 1
}
for r in "$cand" "$cdir" "$prefix" "$version" "$out"; do
  [ -n "$r" ] || die "--candidate --candidate-dir --immutable-prefix --version --out are all required"
done
command -v "$JQ" >/dev/null 2>&1 || die "jq not found"
# shellcheck source=scripts/release/lib/lib-json-schema.sh
. "$HERE/lib/lib-json-schema.sh" || die "packaged schema library failed to source"

# ── bounded selection: the file named exactly latest.json ──────────────────
declared="$("$JQ" -r '[.files[] | select(.name == "latest.json")] | length' "$cand")"
[ "$declared" = "1" ] ||
  refuse "the candidate declares $declared files named latest.json; the updater feed is selected by that exact name, never by extension or pattern"
feed="$cdir/latest.json"
[ -f "$feed" ] || refuse "candidate declares latest.json but it is not present in the candidate directory"

want="$("$JQ" -r '.files[] | select(.name == "latest.json") | .sha256' "$cand")"
have="$(shasum -a 256 "$feed" | awk '{print $1}')"
[ "$want" = "$have" ] || refuse "latest.json digest $have does not match the signed candidate's $want"

vout="$(json_schema_validate_file "$feed" "$HERE/references/updater-pointer.schema.json")"
[ -z "$vout" ] || {
  printf '%s\n' "$vout" | sed 's/^/updater: INVALID /' >&2
  refuse "latest.json does not conform to blessed/updater-pointer/v1"
}

fv="$("$JQ" -r '.version' "$feed")"
[ "$fv" = "$version" ] || refuse "updater feed advertises version $fv, this promotion is $version"

# ── URL, artifact, and signature correspondence ───────────────────────────
# The feed's platform KEY must name the artifact's declared platform. Without
# this, a coherent swap — moving both URL and signature to another platform's
# genuine artifact — validates, and the updater serves the wrong build to a
# whole platform while every signature checks out.
# The bounded set of platform keys this v1 contract recognizes. The EXPECTED
# platform is derived from the key itself (darwin-aarch64 -> darwin/aarch64)
# rather than from a hand-written table.
#
# There used to be such a table, and it was wrong. It read
# {"darwin-aarch64":"darwin/arm64", ..., "linux-x86_64":"linux/amd64",
# "windows-x86_64":"windows/x86_64"} — note that it expected Go's `amd64` for
# linux but uname's `x86_64` for windows, which no vocabulary does. It had been
# transcribed from a v0.4.3 fixture and matched no producer declaration: the
# real v0.4.4 candidate declares darwin/aarch64 and linux/x86_64, exactly as
# JonathanPorta/docsort's release-artifacts.json has since #224, and the
# renderer refused it after its signature had already verified.
#
# The platform field is schema-free-form (^(any|[a-z0-9]+/[a-z0-9_]+)$), so both
# spellings conform and neither is canonical. What this check exists to prevent
# is a coherent swap — moving a URL and its genuine signature to another
# platform's artifact, so the updater serves the wrong build to a whole platform
# while every signature still verifies. That property is "same OS, same
# ARCHITECTURE", not "same spelling", so both sides are normalized onto one arch
# vocabulary before comparison. A cross-architecture swap is still refused;
# amd64 and x86_64 are the same machine.
PLATKEYS='["darwin-aarch64","darwin-x86_64","windows-x86_64","windows-aarch64","linux-x86_64","linux-aarch64"]'
bad="$("$JQ" -r --slurpfile c "$cand" --arg pre "$prefix" --argjson keys "$PLATKEYS" '
  def normarch: {"amd64":"x86_64","x64":"x86_64","arm64":"aarch64"}[.] // .;
  def normplat: if test("/") then (split("/") | "\(.[0])/\(.[1] | normarch)") else . end;
  ($c[0].artifacts | map({key: .filename, value: .}) | from_entries) as $byname
  | [ .platforms | to_entries[]
      | .key as $plat | .value.url as $u
      | ($u | split("/") | last) as $fn
      | if ($u | startswith($pre) | not) then "\($plat): url \($u) is outside this release'"'"'s immutable prefix \($pre)"
        elif ($u != $pre + $fn) then "\($plat): url \($u) is not a direct child of the immutable prefix"
        elif ($byname[$fn] | not) then "\($plat): \($fn) is not an artifact of this candidate"
        elif ($byname[$fn].signature | not) then "\($plat): candidate artifact \($fn) declares no detached signature"
        elif ($keys | index($plat) | not) then "\($plat): not a platform key this bounded v1 contract recognizes"
        elif (($byname[$fn].platform | normplat) != ($plat | sub("-"; "/") | normplat)) then "\($plat): expects a \($plat | sub("-"; "/")) artifact (any spelling of that architecture) but \($fn) declares platform \($byname[$fn].platform)"
        else empty end ] | .[]' "$feed")"
[ -z "$bad" ] || {
  printf '%s\n' "$bad" | sed 's/^/updater: REFUSE /' >&2
  exit 1
}

# The envelope's profile, which an artifact inherits when it declares no
# override of its own (releases.candidate@1 — heterogeneous artifact profiles).
env_profile="$("$JQ" -r '.signing.profile // "ed25519-detached-v1"' "$cand")"

# Each advertised signature must BE the artifact's detached signature, so the
# feed cannot pair a real version with another release's signed bytes.
#
# HOW the sidecar becomes the advertised string depends on the artifact's
# declared signature profile, and the two differ:
#
#   ed25519-detached-v1  the sidecar holds RAW signature bytes, so the feed
#                        advertises base64 of those bytes.
#   tauri-minisign-v1    the sidecar is already a base64 document (that is what
#                        the Tauri signer emits and what its updater expects),
#                        so the feed carries the file's bytes VERBATIM.
#
# This unconditionally base64'd the file, which for a Tauri artifact encodes an
# already-encoded document a second time. It therefore could never match, and
# refused the real v0.4.4 candidate whose three updater payloads declare
# signature_profile: tauri-minisign-v1 — after the signature itself had already
# verified. releases.candidate@1 allows exactly this heterogeneity, so the
# profile is read per artifact rather than assumed for the whole envelope.
#
# The comparison stays exact: each profile has ONE accepted encoding of ONE
# file. Nothing here falls back to trying the other encoding, which would let a
# mis-declared artifact match either way.
# The feed's signature is read PER PLATFORM with `jq -rj` into a file and
# compared with `cmp`, rather than carried through `@tsv`. Two reasons, both
# byte-level: `@tsv` escapes an embedded newline as a literal \n, and command
# substitution strips trailing newlines — either silently rewrites a signature
# document before it is compared.
sig_tmp="$(mktemp)" || die "cannot create a temp file"
trap 'rm -f "$sig_tmp"' EXIT
while IFS= read -r plat; do
  fn="$("$JQ" -r --arg p "$plat" '.platforms[$p].url | split("/") | last' "$feed")"
  sigfile="$("$JQ" -r --arg f "$fn" '.artifacts[] | select(.filename == $f) | .signature' "$cand")"
  [ -f "$cdir/$sigfile" ] || refuse "$plat: detached signature $sigfile is missing from the candidate directory"
  prof="$("$JQ" -r --arg f "$fn" --arg d "$env_profile" \
    '.artifacts[] | select(.filename == $f) | .signature_profile // $d' "$cand")"
  case "$prof" in
    tauri-minisign-v1)
      # BYTE-FOR-BYTE. signing.tauri-minisign@1 defines the sidecar as the exact
      # UTF-8 Minisign document and forbids extracting one base64 line,
      # normalizing comments, or rewriting newlines. An earlier version here
      # compared `tr -d '\r\n'` of the file and called the result "verbatim";
      # that deletes content-bearing newlines from a conforming multi-line
      # document, so the renderer could refuse a candidate carrying the exact
      # authenticated sidecar — the same class of blockage this file already
      # caused once. `-j` emits the decoded string with no trailing newline, so
      # cmp sees exactly the feed's bytes against exactly the file's.
      "$JQ" -rj --arg p "$plat" '.platforms[$p].signature' "$feed" >"$sig_tmp" ||
        die "could not read the advertised signature for $plat"
      # NO normalization, not even a trailing newline. releases.runtime-update@1
      # requires the advertised signature to equal the EXACT sidecar whose size
      # and digest the candidate authenticates, and signing.tauri-minisign@1
      # requires that sidecar preserved byte-for-byte. Neither exempts a file
      # terminator, so tolerating one would let a feed pass while advertising
      # bytes that are not the candidate-bound sidecar — the binding this guard
      # exists to enforce.
      #
      # An earlier revision of this fix stripped one trailing newline "because a
      # producer writing it is ordinary". No conforming artifact needs it: the
      # real v0.4.4 sidecars are 404 and 420 bytes with zero newlines. If a
      # newline-terminated producer must ever be supported, that is a change to
      # the feed/profile contract and its schema, not a receiver-only
      # equivalence added here.
      cmp -s "$sig_tmp" "$cdir/$sigfile" ||
        refuse "$plat: the advertised signature is not byte-identical to $sigfile ($(wc -c <"$sig_tmp" | tr -d ' ') bytes advertised, $(wc -c <"$cdir/$sigfile" | tr -d ' ') in the candidate) — tauri-minisign-v1 sidecars are compared exactly"
      ;;
    *)
      # ed25519-detached-v1: the sidecar is raw bytes, so the feed advertises
      # base64 of them. That encoding has no interior newlines, so a string
      # comparison is exact here.
      sig="$("$JQ" -r --arg p "$plat" '.platforms[$p].signature' "$feed")"
      actual="$(base64 <"$cdir/$sigfile" | tr -d '\n')"
      [ "$actual" = "$sig" ] ||
        refuse "$plat: advertised signature does not equal base64 of the candidate's $sigfile under its declared profile $prof — the feed pairs this version with signed bytes that are not this artifact's"
      ;;
  esac
done < <("$JQ" -r '.platforms | keys[]' "$feed")

# ── byte-copy, never re-serialize ─────────────────────────────────────────
mkdir -p "$(dirname "$out")" || die "cannot create output directory"
cp "$feed" "$out" || die "cannot write updater pointer"
cmp -s "$feed" "$out" || die "copied updater pointer does not match the source bytes"
printf 'updater: copied latest.json verbatim (%s bytes)\n' "$(wc -c <"$out" | tr -d ' ')" >&2
exit 0
