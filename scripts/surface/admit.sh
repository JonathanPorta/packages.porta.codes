#!/usr/bin/env bash
# admit.sh — admit one producer candidate into the reviewed inventory
# (blessed releases.package-repositories@1 PR-2, PR-3; linux-packaging LP-9).
#
# Input is a FETCHED candidate directory (the producer release's complete asset
# set) and this repository's committed policy. Nothing in the candidate is
# trusted until it has been checked against roots this repository holds:
#
#   1. the candidate is valid AND its manifest signature verifies against the
#      producer's COMMITTED trust store (surface/admission.json → keys/candidates/)
#      — a store shipped inside the candidate would be no root of trust;
#   2. it is the candidate asked for: producer_repo and tag match the request;
#   3. every rpm/deb artifact's identity is read from the package itself
#      (dpkg-deb / rpm headers) and its name must be one this producer may ship;
#   4. every RPM verifies with rpmkeys against ONLY its producer's declared key
#      (a dedicated rpm database holding that one key) — at least one signature,
#      all OK;
#   5. each package lands in the repository whose format and architecture match
#      (the inventory's repositories ARE the support matrix); an architecture
#      with no repository is reported and not admitted;
#   6. the result keeps every existing entry; an entry for the same file must be
#      byte-identical (identical re-admission is a no-op), and the new inventory
#      must pass validate-package-inventory.sh.
#
# Output: --out NEW_INVENTORY, and --pool DIR receives each admitted package at
# its inventory path. Prints a summary; never touches the network.
#
# Exit: 0 admitted (or already admitted) · 1 refused · 2 tooling/usage.
# shellcheck disable=SC2016  # jq programs: $-names are jq variables, not shell
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
JQ="${JQ_BIN:-jq}"
die() {
  printf 'admit: %s\n' "$1" >&2
  exit 2
}
refuse() {
  printf 'admit: REFUSED — %s\n' "$1" >&2
  exit 1
}
say() { printf 'admit: %s\n' "$1" >&2; }
usage() {
  cat >&2 <<'EOF'
Usage: admit.sh --candidate-dir DIR --producer-repo OWNER/REPO --tag vX.Y.Z \
                --out NEW_INVENTORY.json --pool DIR \
                [--inventory inventory/inventory.json] [--layout inventory/layout.json] \
                [--policy surface/admission.json] [--keys-dir keys]
EOF
  exit 2
}
cdir="" producer="" tag="" out="" pool=""
inv="$ROOT/inventory/inventory.json"
layout="$ROOT/inventory/layout.json"
policy="$ROOT/surface/admission.json"
keys="$ROOT/keys"
while [ $# -gt 0 ]; do
  case "$1" in
    --candidate-dir) cdir="${2:-}" && shift 2 ;;
    --producer-repo) producer="${2:-}" && shift 2 ;;
    --tag) tag="${2:-}" && shift 2 ;;
    --out) out="${2:-}" && shift 2 ;;
    --pool) pool="${2:-}" && shift 2 ;;
    --inventory) inv="${2:-}" && shift 2 ;;
    --layout) layout="${2:-}" && shift 2 ;;
    --policy) policy="${2:-}" && shift 2 ;;
    --keys-dir) keys="${2:-}" && shift 2 ;;
    -h | --help) usage ;;
    *) die "unknown argument: $1" ;;
  esac
done
if [ -z "$cdir" ] || [ -z "$producer" ] || [ -z "$tag" ] || [ -z "$out" ] || [ -z "$pool" ]; then usage; fi
[ -d "$cdir" ] || die "--candidate-dir is not a directory"
for t in "$JQ" sha256sum rpm rpmkeys dpkg-deb gpg; do command -v "$t" >/dev/null 2>&1 || die "required tool not found: $t"; done
REL="$ROOT/scripts/release"
SIG="$ROOT/scripts/signing"
sha() { sha256sum "$1" | cut -d' ' -f1; }
size() { wc -c <"$1" | tr -d ' '; }

# ── 1. the candidate, against the COMMITTED trust store ────────────────────
store_rel="$("$JQ" -r --arg p "$producer" '.producers[$p].trust_store // empty' "$policy")"
[ -n "$store_rel" ] || refuse "$producer is not an admitted producer (surface/admission.json)"
store="$ROOT/$store_rel"
[ -f "$store" ] || refuse "the trust store $store_rel for $producer is not provisioned"
bash "$REL/validate-candidate.sh" --candidate-dir "$cdir" --trust-store "$store" --signing-dir "$SIG" >/dev/null 2>"$pool.admit.err" || {
  sed 's/^/admit: /' "$pool.admit.err" >&2
  rm -f "$pool.admit.err"
  refuse "the candidate does not validate against $producer's committed trust store"
}
rm -f "$pool.admit.err"
C="$cdir/release-candidate.json"

# ── 2. the candidate asked for ─────────────────────────────────────────────
[ "$("$JQ" -r .producer_repo "$C")" = "$producer" ] || refuse "the candidate is from $("$JQ" -r .producer_repo "$C"), not $producer"
[ "$("$JQ" -r .tag "$C")" = "$tag" ] || refuse "the candidate is $("$JQ" -r .tag "$C"), not $tag"
msha="$(sha "$C")"

# The base: the current inventory, or the layout for the first admission.
base="$inv"
[ -f "$base" ] || base="$layout"
"$JQ" -e '.repository_key.fingerprint | test("^[0-9A-F]{40}$")' "$base" >/dev/null ||
  refuse "the repository key is not provisioned (fingerprint in $(basename "$base"))"
pfpr="$("$JQ" -r --arg p "$producer" '.producer_keys[] | select(.producer_repo == $p) | .fingerprint' "$base")"
pkey="$("$JQ" -r --arg p "$producer" '.producer_keys[] | select(.producer_repo == $p) | .public_key_path' "$base")"
work="$(mktemp -d)" || die "cannot create a work directory"
trap 'rm -rf "$work"' EXIT
new="$work/entries.jsonl"
: >"$new"

# ── 3–5. each package ──────────────────────────────────────────────────────
n_pkg=0
while IFS=$'\t' read -r fname kind; do
  f="$cdir/$fname"
  case "$kind" in
    deb)
      name="$(dpkg-deb -f "$f" Package 2>/dev/null)" || refuse "$fname is not a readable .deb"
      full="$(dpkg-deb -f "$f" Version)"
      arch="$(dpkg-deb -f "$f" Architecture)"
      case "$full" in *:*) refuse "$fname has an epoch ($full); not supported" ;; *-*) ;; *) refuse "$fname has no Debian revision ($full)" ;; esac
      ver="${full%-*}" revn="${full##*-}"
      repos="$("$JQ" -r --arg p "$producer" --arg a "$arch" '.repositories[] | select(.format == "apt" and .producer_repo == $p and ((.architectures | index($a)) != null or $a == "all")) | .id' "$layout")"
      ;;
    rpm)
      q="$(rpm -qp --nosignature --qf '%{NAME}\t%{VERSION}\t%{RELEASE}\t%{ARCH}' "$f" 2>/dev/null)" || refuse "$fname is not a readable RPM"
      IFS=$'\t' read -r name ver revn arch <<<"$q"
      repos="$("$JQ" -r --arg p "$producer" --arg a "$arch" '.repositories[] | select(.format == "dnf" and .producer_repo == $p and (.arch == $a or $a == "noarch")) | .id' "$layout")"
      ;;
  esac
  "$JQ" -e --arg p "$producer" --arg n "$name" '.producers[$p].package_names | index($n) != null' "$policy" >/dev/null ||
    refuse "$fname is package '$name', which $producer may not publish here"
  if [ -z "$repos" ]; then
    say "not admitted: $fname ($arch) — no repository for that architecture in the support matrix"
    continue
  fi
  signer=""
  if [ "$kind" = rpm ]; then
    [[ "$pfpr" =~ ^[0-9A-F]{40}$ ]] || refuse "$producer's RPM signing key is not provisioned"
    [ -f "$keys/${pkey#keys/}" ] || refuse "$producer's RPM public key $pkey is missing"
    db="$work/rpmdb"
    rm -rf "$db" && mkdir -p "$db"
    rpmkeys --dbpath "$db" --import "$keys/${pkey#keys/}" >/dev/null 2>&1 || refuse "$producer's RPM public key cannot be imported"
    sigs="$(rpmkeys --dbpath "$db" --define '_pkgverify_level all' -Kv "$f" 2>&1 | grep -i '^[[:space:]].*signature' || true)"
    if [ -z "$sigs" ] || printf '%s\n' "$sigs" | grep -qv ': OK$'; then
      refuse "$fname is not signed by ONLY $producer's declared RPM key $pfpr"
    fi
    signer="$pfpr"
  fi
  h="$(sha "$f")" s="$(size "$f")"
  for r in $repos; do
    rpath="$("$JQ" -r --arg r "$r" '.repositories[] | select(.id == $r) | .path' "$layout")"
    if [ "$kind" = deb ]; then
      file="${rpath}pool/main/${name:0:1}/$name/$fname"
    else
      file="${rpath}Packages/$fname"
    fi
    mkdir -p "$pool/$(dirname "$file")"
    cp "$f" "$pool/$file"
    "$JQ" -cn --arg r "$r" --arg pr "$producer" --arg t "$tag" --arg m "$msha" --arg n "$name" --arg v "$ver" \
      --arg rv "$revn" --arg a "$arch" --arg f "$file" --arg h "$h" --argjson s "$s" --arg sg "$signer" \
      '{repository: $r, candidate: {producer_repo: $pr, tag: $t, manifest_sha256: $m}, name: $n, version: $v,
        revision: $rv, arch: $a, file: $f, sha256: $h, size: $s} + (if $sg != "" then {signer_fingerprint: $sg} else {} end)' >>"$new"
    n_pkg=$((n_pkg + 1))
  done
done < <("$JQ" -r '.artifacts[] | select(.install_kind == "rpm" or .install_kind == "deb") | [.filename, .install_kind] | @tsv' "$C")
[ "$n_pkg" -gt 0 ] || refuse "the candidate carries no package for any supported repository"

# ── 6. merge: identical re-admission is a no-op; a changed file is refused ─
conflict="$("$JQ" -r --slurpfile n <("$JQ" -s . "$new") '
  [.packages // [] | .[]] as $old | $n[0][] as $e
  | ($old[] | select(.file == $e.file and .sha256 != $e.sha256) | .file)' "$base")"
[ -z "$conflict" ] || refuse "already-admitted file(s) would change bytes: $(printf '%s' "$conflict" | tr '\n' ' ')"
# The layout declares the whole support matrix; the inventory carries only the
# repositories that have admitted packages (an empty repository is refused,
# never published — PR-14), in the layout's order. A repository joins the
# inventory with its first admitted package.
"$JQ" -S --slurpfile n <("$JQ" -s . "$new") --slurpfile l "$layout" '
  .packages = ((.packages // []) + $n[0] | unique_by(.file) | sort_by(.repository, .name, .version, .revision, .file))
  | ([.packages[].repository] | unique) as $used
  | .repositories = [$l[0].repositories[] | select(.id as $i | $used | index($i))]' \
  "$base" >"$work/inv.json" || die "cannot merge the inventory"
bash "$REL/validate-package-inventory.sh" --file "$work/inv.json" >/dev/null 2>"$work/v.err" || {
  sed 's/^/admit: /' "$work/v.err" >&2
  refuse "the admitted inventory is not valid"
}
mv "$work/inv.json" "$out"
added="$("$JQ" -n --slurpfile a "$base" --slurpfile b "$out" '($b[0].packages | length) - (($a[0].packages // []) | length)')"
if [ "$added" -eq 0 ]; then
  say "OK — $producer $tag is already admitted; inventory unchanged"
else
  say "OK — admitted $producer $tag: $added package entr(y/ies)"
fi
