#!/usr/bin/env bash
# pkgrepo-sign.sh — sign one generation's repository metadata with the surface's
# repository key (standards/releases/package-repositories.md PR-5).
#
# The isolated signing step: it receives ONLY the repository key, and signs only
# what the unsigned generation manifest already names, after proving those files
# are still the bytes the manifest recorded. APT `Release` gains `InRelease`
# (clearsigned) and `Release.gpg` (detached); DNF `repomd.xml` gains
# `repomd.xml.asc` (detached, armored). All are generation ENTRYPOINTS. It never
# rebuilds, re-reads a package, or signs a package — producers sign RPMs before
# their candidate is sealed (linux-packaging LP-9).
#
# Key handling follows scripts/signing/sign.sh: by env-var NAME or file, scrubbed
# from the environment before any external command, imported over stdin into an
# ephemeral GNUPGHOME.
#
# Exit: 0 signed · 1 refused · 2 tooling/usage.
# shellcheck disable=SC2016  # jq programs: $-names are jq variables, not shell
set -euo pipefail
set +x
set +a
export -n __blessed_pkgrepo_key 2>/dev/null || true
unset __blessed_pkgrepo_key 2>/dev/null || true
__blessed_pkgrepo_key=""
_scan=("$@")
_si=0
while [ "$_si" -lt "${#_scan[@]}" ]; do
  if [ "${_scan[$_si]}" = "--private-key-env" ]; then
    _nm="${_scan[$((_si + 1))]:-}"
    case "$_nm" in
      __blessed_pkgrepo_key | "" | [!A-Za-z_]* | *[!A-Za-z0-9_]*)
        printf 'pkgrepo-sign: invalid --private-key-env name\n' >&2
        exit 2
        ;;
    esac
    __blessed_pkgrepo_key="${!_nm-}"
    unset "$_nm" 2>/dev/null || true
    unset _nm
    break
  fi
  _si=$((_si + 1))
done
unset _scan _si

JQ="${JQ_BIN:-jq}"
export JQ
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
die() {
  printf 'pkgrepo-sign: %s\n' "$1" >&2
  exit 2
}
refuse() {
  printf 'pkgrepo-sign: REFUSED — %s\n' "$1" >&2
  exit 1
}
usage() {
  printf 'Usage: pkgrepo-sign.sh --generation DIR --key-fingerprint FPR40 (--private-key-env NAME | --private-key-file PATH)\n' >&2
  exit 2
}
gen="" fpr="" key_file="" key_env=""
while [ $# -gt 0 ]; do
  case "$1" in
    --generation)
      gen="${2:-}"
      shift 2
      ;;
    --key-fingerprint)
      fpr="${2:-}"
      shift 2
      ;;
    --private-key-file)
      key_file="${2:-}"
      shift 2
      ;;
    --private-key-env)
      key_env="${2:-}"
      shift 2
      ;;
    -h | --help) usage ;;
    *) die "unknown argument: $1" ;;
  esac
done
if [ -z "$gen" ] || [ -z "$fpr" ]; then usage; fi
[ -n "$key_env" ] || [ -n "$key_file" ] || usage
case "$fpr" in *[!0-9A-F]* | "") die "--key-fingerprint must be 40 uppercase hex" ;; esac
[ "${#fpr}" -eq 40 ] || die "--key-fingerprint must be 40 uppercase hex"
M="$gen/.generation.json"
[ -f "$M" ] || die "no generation manifest at $M"
for t in "$JQ" gpg sha256sum cmp; do command -v "$t" >/dev/null 2>&1 || die "required tool not found: $t"; done
# shellcheck source=scripts/release/lib/pkgrepo-lib.sh
. "$HERE/lib/pkgrepo-lib.sh" || die "packaged library not found: $HERE/lib/pkgrepo-lib.sh"

[ "$("$JQ" -r .signed "$M")" = false ] || refuse "this generation is already signed"
sha() { sha256sum "$1" | cut -d' ' -f1; }
size() { wc -c <"$1" | tr -d ' '; }

# Every object is still the byte the generator recorded — a metadata file
# edited between generation and signing would otherwise be signed as-is.
while IFS=$'\t' read -r p h; do
  [ -f "$gen/$p" ] || refuse "generation object $p is missing"
  [ "$(sha "$gen/$p")" = "$h" ] || refuse "generation object $p changed after generation"
done < <("$JQ" -r '.objects[] | [.path, .sha256] | @tsv' "$M")

# The repository key's public half ships in the generation; the private key
# must be that key.
repo_pub="$("$JQ" -r '.objects[] | select(.content_type == "application/pgp-keys") | .path' "$M")"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
chmod 700 "$work"
export GNUPGHOME="$work/g"
mkdir -m 700 "$GNUPGHOME"
if [ -n "$key_file" ]; then
  gpg --batch --quiet --import <"$key_file" 2>/dev/null || refuse "the private key could not be imported"
else
  [ -n "$__blessed_pkgrepo_key" ] || die "private key env var is empty or unset"
  printf '%s' "$__blessed_pkgrepo_key" | gpg --batch --quiet --import 2>/dev/null || refuse "the private key could not be imported"
fi
__blessed_pkgrepo_key=""
# Exactly ONE primary secret key, and it is the declared one: a key bundle that
# begins with the declared key must not smuggle in a second signer.
seclist="$(gpg --batch --with-colons --list-secret-keys 2>/dev/null)"
nsec="$(printf '%s\n' "$seclist" | grep -c '^sec:' || true)"
[ "$nsec" = 1 ] || refuse "the private key material holds $nsec primary keys; it must hold exactly the declared repository key $fpr"
sec="$(printf '%s\n' "$seclist" | awk -F: '/^sec:/{p=1; next} p && /^fpr:/{print $10; exit}')"
[ "$sec" = "$fpr" ] || refuse "the private key is ${sec:-<none>}, not the declared repository key $fpr"
found=0
for k in $repo_pub; do
  if pkgrepo_exact_key "$gen/$k" "$fpr" >/dev/null; then found=1; fi
done
[ "$found" = 1 ] || refuse "the generation does not publish exactly the public half of $fpr"

signed="$work/signed.jsonl"
: >"$signed"
add() { "$JQ" -cn --arg p "$1" --arg t "$2" --arg h "$(sha "$gen/$1")" --argjson s "$(size "$gen/$1")" \
  '{path: $p, class: "entrypoint", content_type: $t, sha256: $h, size: $s}' >>"$signed"; }
# DETERMINISTIC SIGNATURES. Resuming an interrupted publication regenerates
# and re-signs the same generation, and immutable storage refuses a signature
# object with different bytes. An OpenPGP signature carries its creation time,
# so the creation time is fixed: the generation's own timestamp, or the key's
# creation time if that is later (a signature older than its key is invalid).
# RSA PKCS#1 v1.5, EdDSA and (libgcrypt's RFC 6979) ECDSA signatures are then
# byte-identical on every run. Each signature is made twice and compared, so a
# key whose signatures still vary (e.g. salted v6 signatures) is refused here,
# not at resume.
gts="$("$JQ" -r '.timestamp' "$M")"
case "$gts" in '' | *[!0-9]*) refuse "the generation manifest has no timestamp" ;; esac
kts="$(printf '%s\n' "$seclist" | awk -F: '/^(sec|ssb):/ && $6 > m {m = $6} END {print m + 0}')"
sts="$gts"
[ "$kts" -le "$gts" ] || sts="$kts"
G() { gpg --batch --yes --quiet --faked-system-time "${sts}!" --local-user "$fpr" --digest-algo SHA512 "$@"; }
S() { # S OUT IN MODE... — sign twice, keep the first, refuse unless identical
  local out="$1" in="$2"
  shift 2
  G "$@" --output "$out" "$in" || return 1
  G "$@" --output "$work/again" "$in" || return 1
  cmp -s "$out" "$work/again" || refuse "the signing key's signatures are not deterministic (e.g. salted v6 signatures); an interrupted publication could not resume"
}

while IFS= read -r rel; do
  d="$(dirname "$rel")"
  S "$gen/$d/InRelease" "$gen/$rel" --clearsign || refuse "clearsigning $rel failed"
  S "$gen/$d/Release.gpg" "$gen/$rel" --armor --detach-sign || refuse "signing $rel failed"
  add "$d/InRelease" "text/plain"
  add "$d/Release.gpg" "application/pgp-signature"
done < <("$JQ" -r '.objects[] | select(.path | endswith("/Release")) | .path' "$M")
while IFS= read -r rel; do
  S "$gen/$rel.asc" "$gen/$rel" --armor --detach-sign || refuse "signing $rel failed"
  add "$rel.asc" "application/pgp-signature"
done < <("$JQ" -r '.objects[] | select(.path | endswith("/repodata/repomd.xml")) | .path' "$M")

[ -s "$signed" ] || refuse "the generation has no repository metadata to sign"
"$JQ" --slurpfile add "$signed" --arg fpr "$fpr" \
  '.signed = true | .repository_key_fingerprint = $fpr | .objects = ((.objects + $add) | sort_by(.path))' "$M" >"$work/m.json"
mv -f "$work/m.json" "$M"
printf 'pkgrepo-sign: OK %s — %s signature objects (key %s)\n' "$gen" "$(wc -l <"$signed" | tr -d ' ')" "${fpr: -16}"
