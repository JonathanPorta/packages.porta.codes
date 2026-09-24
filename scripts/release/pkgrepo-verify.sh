#!/usr/bin/env bash
# pkgrepo-verify.sh — verify a SIGNED generation with public keys only, before it
# can be staged or activated (standards/releases/package-repositories.md PR-5,
# PR-6, PR-9, PR-14).
#
# THE UNSIGNED MANIFEST IS NOT TRUSTED. It is written by the generator and
# carried beside the generation; anything in it could have been rewritten
# along with the bytes it describes. So this verifier DERIVES the complete set
# of objects a correct generation contains — every path, its class, and its
# content — from only two authenticated sources:
#
#   · the reviewed inventory: package paths, digests and sizes; key paths and
#     fingerprints; repository layout — and the client configuration, which is
#     re-rendered from it by the library the generator uses (lib/pkgrepo-lib.sh);
#   · the SIGNED repository metadata: APT InRelease/Release lists every index
#     and its digest; DNF repomd.xml lists every repodata file and its digest.
#
# Every derived object is checked against the ACTUAL bytes: packages against
# the inventory, indexes and their by-hash copies (by content) against signed
# Release, repodata against signed repomd, each key file against exactly one
# primary key with the declared fingerprint, configuration against the
# re-render. The tree must be exactly that set — nothing missing, nothing
# extra, no symlink or special file. Only then is the manifest read, and it must
# agree in every path, class, digest and size: it can confirm, never redefine.
#
# --emit-objects FILE writes the verified object list (path, class, content
# type, digest, size). pkgrepo-publish.sh publishes from that list, never from
# the manifest.
#
# Exit: 0 verified · 1 refused · 2 tooling/usage.
# shellcheck disable=SC2016  # jq programs: $-names are jq variables, not shell
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JQ="${JQ_BIN:-jq}"
export JQ
die() {
  printf 'pkgrepo-verify: %s\n' "$1" >&2
  exit 2
}
fails=0
fail() {
  printf 'pkgrepo-verify: %s\n' "$1" >&2
  fails=$((fails + 1))
}
refused() {
  printf 'pkgrepo-verify: REFUSED — %s\n' "$1" >&2
  exit 1
}
usage() {
  printf 'Usage: pkgrepo-verify.sh --generation DIR --inventory INVENTORY.json [--emit-objects FILE]\n' >&2
  exit 2
}
gen="" inv="" emit=""
while [ $# -gt 0 ]; do
  case "$1" in
    --generation)
      gen="${2:-}"
      shift 2
      ;;
    --inventory)
      inv="${2:-}"
      shift 2
      ;;
    --emit-objects)
      emit="${2:-}"
      shift 2
      ;;
    -h | --help) usage ;;
    *) die "unknown argument: $1" ;;
  esac
done
if [ -z "$gen" ] || [ -z "$inv" ]; then usage; fi
[ -d "$gen" ] || die "--generation is not a directory"
M="$gen/.generation.json"
for t in "$JQ" gpg gpgv sha256sum gzip find; do command -v "$t" >/dev/null 2>&1 || die "required tool not found: $t"; done
# shellcheck source=scripts/release/lib/pkgrepo-lib.sh
. "$HERE/lib/pkgrepo-lib.sh" || die "packaged library not found: $HERE/lib/pkgrepo-lib.sh"
sha() { sha256sum "$1" | cut -d' ' -f1; }
size() { wc -c <"$1" | tr -d ' '; }

bash "$HERE/validate-package-inventory.sh" --file "$inv" >/dev/null 2>&1 || refused "the inventory is not valid"

work="$(mktemp -d)" || die "cannot create a work directory"
trap 'rm -rf "$work"' EXIT
export GNUPGHOME="$work/gnupg"
mkdir -m 700 "$GNUPGHOME"
E="$work/expected.tsv" # path <TAB> class, one line per derived object
: >"$E"
expect() { printf '%s\t%s\n' "$1" "$2" >>"$E"; }
present() { [ -f "$gen/$1" ] && [ ! -L "$gen/$1" ]; }

# ── tree hygiene: regular files and directories only ───────────────────────
odd="$(cd "$gen" && find . -mindepth 1 ! -type f ! -type d | sed 's#^\./##' | head -5)"
[ -z "$odd" ] || refused "the generation contains symlinks or special files: $(printf '%s' "$odd" | tr '\n' ' ')"

# ── keys: each published key file is exactly its declared primary key ─────
repo_fpr="$("$JQ" -r .repository_key.fingerprint "$inv")"
repo_kp="$("$JQ" -r .repository_key.public_key_path "$inv")"
repo_ring="$work/repository.gpg"
expect "$repo_kp" immutable
if ! present "$repo_kp"; then
  fail "repository key $repo_kp is missing"
elif ! why="$(pkgrepo_exact_key "$gen/$repo_kp" "$repo_fpr")"; then
  fail "repository key $repo_kp $why"
else
  gpg --batch --yes --quiet --dearmor --output "$repo_ring" "$gen/$repo_kp" 2>/dev/null || fail "the repository key cannot be read"
  gpg --batch --quiet --import "$gen/$repo_kp" 2>/dev/null || true
fi
[ -f "$repo_ring" ] || : >"$repo_ring" # an empty keyring verifies nothing
while IFS=$'\t' read -r pf pp; do
  expect "$pp" immutable
  mkdir -p "$work/rpmdb-$pf"
  if ! present "$pp"; then
    fail "producer key $pp is missing"
  elif ! why="$(pkgrepo_exact_key "$gen/$pp" "$pf")"; then
    fail "producer key $pp $why"
  else
    : >"$work/rpmdb-$pf/.ok"
  fi
done < <("$JQ" -r '.producer_keys[] | [.fingerprint, .public_key_path] | @tsv' "$inv")

# ── packages: the actual bytes ARE the reviewed inventory's ────────────────
while IFS=$'\t' read -r f h s; do
  expect "$f" immutable
  if ! present "$f"; then
    fail "package $f is missing"
    continue
  fi
  [ "$(sha "$gen/$f")" = "$h" ] || fail "package $f is not the inventory's bytes"
  [ "$(size "$gen/$f")" = "$s" ] || fail "package $f is not the inventory's size"
done < <("$JQ" -r '.packages[] | [.file, .sha256, (.size | tostring)] | @tsv' "$inv")

# ── APT: every index derives from the SIGNED Release ───────────────────────
while IFS= read -r repo; do
  id="$("$JQ" -r .id <<<"$repo")"
  rpath="$("$JQ" -r .path <<<"$repo")"
  suite="$("$JQ" -r .suite <<<"$repo")"
  comp="$("$JQ" -r .component <<<"$repo")"
  archs="$("$JQ" -r '.architectures | sort | join(" ")' <<<"$repo")"
  d="${rpath}dists/$suite"
  src="$(pkgrepo_apt_sources_path "$inv" "$id")"
  for x in Release InRelease Release.gpg; do expect "$d/$x" mutable; done
  expect "$src" mutable
  if present "$src"; then
    pkgrepo_apt_sources "$inv" "$id" | cmp -s - "$gen/$src" || fail "$id: $src is not the configuration the inventory defines"
  else fail "$id: $src is missing"; fi
  if ! present "$d/InRelease" || ! present "$d/Release" || ! present "$d/Release.gpg"; then
    fail "$id: Release, InRelease or Release.gpg is missing"
    continue
  fi
  gpgv --keyring "$repo_ring" "$gen/$d/InRelease" >/dev/null 2>&1 || fail "$id: InRelease does not verify against the repository key"
  gpgv --keyring "$repo_ring" "$gen/$d/Release.gpg" "$gen/$d/Release" >/dev/null 2>&1 || fail "$id: Release.gpg does not verify against the repository key"
  gpg --batch --quiet --output "$work/$id.clear" --decrypt "$gen/$d/InRelease" 2>/dev/null || true
  cmp -s "$work/$id.clear" "$gen/$d/Release" || fail "$id: InRelease does not carry exactly Release"
  R="$gen/$d/Release"
  [ "$(sed -n 's/^Suite: //p' "$R")" = "$suite" ] || fail "$id: Release names another suite"
  [ "$(sed -n 's/^Components: //p' "$R")" = "$comp" ] || fail "$id: Release names other components"
  [ "$(sed -n 's/^Architectures: //p' "$R" | tr ' ' '\n' | sort | tr '\n' ' ' | sed 's/ $//')" = "$archs" ] ||
    fail "$id: Release names other architectures"
  grep -qx 'Acquire-By-Hash: yes' "$R" || fail "$id: Release does not enable Acquire-By-Hash"
  want_idx="$(for a in $archs; do printf '%s/binary-%s/Packages\n%s/binary-%s/Packages.gz\n' "$comp" "$a" "$comp" "$a"; done | sort)"
  have_idx="$(sed -n '/^SHA256:/,$p' "$R" | tail -n +2 | awk 'NF==3{print $3}' | sort)"
  [ "$want_idx" = "$have_idx" ] || fail "$id: Release does not list exactly the expected indexes"
  while read -r h s f; do
    case "$f" in */../* | ../* | /*) fail "$id: Release lists an index outside its tree: $f" && continue ;; esac
    bh="$(dirname "$d/$f")/by-hash/SHA256/$h"
    expect "$d/$f" mutable
    expect "$bh" immutable
    if ! present "$d/$f"; then
      fail "$id: $f is missing"
    elif [ "$(sha "$gen/$d/$f")" != "$h" ] || [ "$(size "$gen/$d/$f")" != "$s" ]; then
      fail "$id: $f does not match the signed Release"
    fi
    # By CONTENT, not by name: the by-hash object must hold the signed bytes.
    if ! present "$bh"; then
      fail "$id: $f has no by-hash copy"
    elif [ "$(sha "$gen/$bh")" != "$h" ] || [ "$(size "$gen/$bh")" != "$s" ]; then
      fail "$id: the by-hash copy of $f does not hold the bytes signed Release names"
    fi
  done < <(sed -n '/^SHA256:/,$p' "$R" | tail -n +2 | awk 'NF==3')
  for a in $archs; do
    pk="$gen/$d/$comp/binary-$a/Packages"
    if [ ! -f "$pk" ] || [ ! -f "$pk.gz" ]; then continue; fi
    gzip -dc "$pk.gz" 2>/dev/null | cmp -s - "$pk" || fail "$id: Packages.gz for $a is not Packages compressed"
    want="$("$JQ" -r --arg id "$id" --arg p "$rpath" --arg a "$a" \
      '.packages[] | select(.repository == $id and (.arch == $a or .arch == "all")) | "\(.file | ltrimstr($p)) \(.size) \(.sha256)"' "$inv" | sort)"
    have="$(awk '/^Filename: /{f=$2} /^Size: /{s=$2} /^SHA256: /{h=$2} /^$/{if(f!="")print f" "s" "h; f="";s="";h=""} END{if(f!="")print f" "s" "h}' "$pk" | sort)"
    [ "$want" = "$have" ] || fail "$id: the signed $a index does not list exactly the inventory's packages"
  done
done < <("$JQ" -c '.repositories[] | select(.format == "apt")' "$inv")

# ── DNF: every repodata file derives from the SIGNED repomd.xml ────────────
dnf_n="$("$JQ" '[.repositories[] | select(.format == "dnf")] | length' "$inv")"
if [ "$dnf_n" -gt 0 ]; then
  command -v rpmkeys >/dev/null 2>&1 || die "rpmkeys not found (DNF repositories need it)"
  # One rpm database per producer holding ONLY that producer's declared key.
  while IFS=$'\t' read -r pf pp; do
    [ -f "$work/rpmdb-$pf/.ok" ] || continue
    rpmkeys --dbpath "$work/rpmdb-$pf" --import "$gen/$pp" >/dev/null 2>&1 || fail "producer key $pf could not be loaded for verification"
  done < <("$JQ" -r '.producer_keys[] | [.fingerprint, .public_key_path] | @tsv' "$inv")
fi
while IFS= read -r repo; do
  id="$("$JQ" -r .id <<<"$repo")"
  rpath="$("$JQ" -r .path <<<"$repo")"
  rd="${rpath}repodata"
  expect "$rd/repomd.xml" mutable
  expect "$rd/repomd.xml.asc" mutable
  if ! present "$rd/repomd.xml" || ! present "$rd/repomd.xml.asc"; then
    fail "$id: repomd.xml or its signature is missing"
    continue
  fi
  gpgv --keyring "$repo_ring" "$gen/$rd/repomd.xml.asc" "$gen/$rd/repomd.xml" >/dev/null 2>&1 ||
    fail "$id: repomd.xml.asc does not verify against the repository key"
  primary=""
  while read -r typ h href; do
    case "$href" in
      repodata/"$h"-*/* | repodata/"$h"-*..*) fail "$id: repomd lists a path outside repodata: $href" && continue ;;
      repodata/"$h"-*) ;;
      *) fail "$id: repomd lists $href, which is not checksum-named repodata" && continue ;;
    esac
    expect "$rpath$href" immutable
    if ! present "$rpath$href"; then
      fail "$id: repomd lists $href, which is missing"
    elif [ "$(sha "$gen/$rpath$href")" != "$h" ]; then
      fail "$id: $href does not hold the bytes repomd.xml signs"
    fi
    [ "$typ" != primary ] || primary="$gen/$rpath$href"
  done < <(tr -d '\n' <"$gen/$rd/repomd.xml" | sed 's#<data #\n<data #g' | sed -n 's#.*<data type="\([a-z_]*\)">.*<checksum type="sha256">\([0-9a-f]*\)</checksum>.*<location href="\([^"]*\)"/>.*#\1 \2 \3#p' | awk 1)
  if [ -z "$primary" ] || [ ! -f "$primary" ]; then
    fail "$id: repomd.xml has no primary metadata"
    continue
  fi
  want="$("$JQ" -r --arg id "$id" --arg p "$rpath" '.packages[] | select(.repository == $id) | "\(.file | ltrimstr($p)) \(.sha256)"' "$inv" | sort)"
  have="$(gzip -dc "$primary" | tr -d '\n' | sed 's#<package #\n<package #g' |
    sed -n 's#.*<checksum type="sha256" pkgid="YES">\([0-9a-f]*\)</checksum>.*<location href="\([^"]*\)"/>.*#\2 \1#p' | sort)"
  [ "$want" = "$have" ] || fail "$id: the signed primary metadata does not list exactly the inventory's packages"
  # Native package signatures, each against ONLY its producer's declared key:
  # every signature line must be OK, and there must be at least one.
  while IFS=$'\t' read -r f pf; do
    present "$f" || continue
    sigs="$(rpmkeys --dbpath "$work/rpmdb-$pf" --define '_pkgverify_level all' -Kv "$gen/$f" 2>&1 | grep -i '^[[:space:]].*signature' || true)"
    if [ -z "$sigs" ] || printf '%s\n' "$sigs" | grep -qv ': OK$'; then
      fail "$id: $f does not verify against its declared signer $pf"
    fi
  done < <("$JQ" -r --arg id "$id" '.packages[] | select(.repository == $id) | [.file, .signer_fingerprint] | @tsv' "$inv")
done < <("$JQ" -c '.repositories[] | select(.format == "dnf")' "$inv")
while IFS= read -r product; do
  if ! cfg="$(pkgrepo_dnf_repo_path "$inv" "$product")"; then
    fail "product $product has no single DNF configuration path"
    continue
  fi
  expect "$cfg" mutable
  if ! body="$(pkgrepo_dnf_repo "$inv" "$product")"; then
    fail "$body"
  elif ! present "$cfg"; then
    fail "$cfg is missing"
  else
    printf '%s\n' "$body" | cmp -s - "$gen/$cfg" || fail "$cfg is not the configuration the inventory defines"
  fi
done < <("$JQ" -r '[.repositories[] | select(.format == "dnf") | .product] | unique | .[]' "$inv")

# ── closed set: the tree is EXACTLY the derived set ────────────────────────
dups="$(cut -f1 "$E" | sort | uniq -d | head -3)"
[ -z "$dups" ] || fail "a path is derived twice: $(printf '%s' "$dups" | tr '\n' ' ')"
cut -f1 "$E" | sort -u >"$work/want.paths"
(cd "$gen" && find . -type f ! -path ./.generation.json | sed 's#^\./##' | sort) >"$work/have.paths"
extra="$(comm -13 "$work/want.paths" "$work/have.paths")"
missing="$(comm -23 "$work/want.paths" "$work/have.paths")"
[ -z "$extra" ] || fail "files no authenticated source accounts for: $(printf '%s' "$extra" | head -5 | tr '\n' ' ')"
[ -z "$missing" ] || fail "derived objects missing from the tree: $(printf '%s' "$missing" | head -5 | tr '\n' ' ')"

[ "$fails" -eq 0 ] || refused "$fails check(s) failed"

# ── the verified object list ───────────────────────────────────────────────
objs="$work/objects.jsonl"
: >"$objs"
while IFS=$'\t' read -r p c; do
  "$JQ" -cn --arg p "$p" --arg c "$c" --arg t "$(pkgrepo_content_type "$p")" --arg h "$(sha "$gen/$p")" --argjson s "$(size "$gen/$p")" \
    '{path: $p, class: $c, content_type: $t, sha256: $h, size: $s}' >>"$objs"
done < <(sort -u "$E")

# ── the manifest may only CONFIRM what was derived ─────────────────────────
if [ ! -f "$M" ] || [ -L "$M" ]; then refused "no generation manifest"; fi
"$JQ" -e '.schema == "blessed/package-repository-generation/v1" and (.generation_id | type == "string" and test("^[0-9a-f]{64}$")) and .signed == true' "$M" >/dev/null 2>&1 ||
  refused "the generation manifest is malformed or unsigned"
[ "$("$JQ" -r .inventory_sha256 "$M")" = "$(sha "$inv")" ] || refused "the generation was built from a different inventory"
[ "$("$JQ" -r .surface_id "$M")" = "$("$JQ" -r .surface_id "$inv")" ] || refused "the generation names another surface"
[ "$("$JQ" -r .repository_key_fingerprint "$M")" = "$repo_fpr" ] || refused "the manifest names another key than the inventory's repository key"
"$JQ" -cS '.objects | map({path, class, sha256, size}) | sort_by(.path)' "$M" >"$work/manifest.cmp" 2>/dev/null || refused "the manifest objects are malformed"
"$JQ" -cS -s 'map({path, class, sha256, size}) | sort_by(.path)' "$objs" >"$work/derived.cmp"
cmp -s "$work/manifest.cmp" "$work/derived.cmp" ||
  refused "the generation manifest disagrees with what the signed metadata and inventory establish (paths, classes, digests or sizes)"

# Identity from content: the id the manifest claims must be the one its
# inventory and derived objects produce. A manifest carrying another
# generation's id — to pass as "already active" or as a resume — is refused.
gid="$(pkgrepo_generation_id "$(sha "$inv")" "$objs")"
[ "$("$JQ" -r .generation_id "$M")" = "$gid" ] ||
  refused "the manifest's generation id is not the identity of this content (inventory + objects); it names another generation"
if [ -n "$emit" ]; then
  "$JQ" -s --arg g "$gid" --arg i "$(sha "$inv")" --arg s "$("$JQ" -r .surface_id "$inv")" \
    '{schema: "blessed/package-repository-verified-objects/v1", surface_id: $s, generation_id: $g, inventory_sha256: $i, objects: sort_by(.path)}' \
    "$objs" >"$emit" || die "cannot write $emit"
fi
printf 'pkgrepo-verify: OK %s — generation %s, %s objects derived and verified\n' "$gen" "${gid:0:12}" "$(wc -l <"$objs" | tr -d ' ')"
