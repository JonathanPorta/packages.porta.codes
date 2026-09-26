# shellcheck shell=bash
# shellcheck disable=SC2016  # jq programs: $-names are jq variables, not shell
# pkgrepo-lib.sh — shared by pkgrepo-generate.sh, pkgrepo-verify.sh,
# pkgrepo-sign.sh and pkgrepo-client-check.sh (releases.package-repositories@1).
#
# One implementation of each rule, so the generator and the verifier cannot
# disagree about what a correct generation contains:
#
#   pkgrepo_exact_key FILE FPR     a key file holds EXACTLY ONE primary key, and
#                                  it is FPR (its subkeys are allowed)
#   pkgrepo_apt_sources INV ID     the deb822 source for APT repository ID
#   pkgrepo_dnf_repo INV PRODUCT   the .repo for PRODUCT's DNF repositories
#   pkgrepo_dnf_repo_path INV PRODUCT
#   pkgrepo_content_type PATH
#   pkgrepo_generation_id INV_SHA256 OBJECTS   a generation's identity, from content
#
# Requires jq (JQ may name it) and gpg.

# pkgrepo_exact_key FILE FPR — prints a reason and returns 1 unless FILE holds
# exactly one primary key whose fingerprint is FPR. Checking only the FIRST
# fingerprint and then trusting the whole file would let a bundle that begins
# with the declared key add another signer.
pkgrepo_exact_key() {
  local list n got
  list="$(gpg --batch --with-colons --show-keys "$1" 2>/dev/null)" || {
    printf 'not a readable OpenPGP key file'
    return 1
  }
  n="$(printf '%s\n' "$list" | grep -c '^pub:' || true)"
  [ "$n" = 1 ] || {
    printf 'holds %s primary keys; it must hold exactly the declared key' "$n"
    return 1
  }
  got="$(printf '%s\n' "$list" | awk -F: '/^pub:/{p=1; next} p && /^fpr:/{print $10; exit}')"
  [ "$got" = "$2" ] || {
    printf 'is %s, not the declared %s' "${got:-<none>}" "$2"
    return 1
  }
}

# pkgrepo_apt_sources INV REPO_ID — deb822, scoped Signed-By, never trusted=yes.
pkgrepo_apt_sources() {
  "${JQ:-jq}" -r --arg id "$2" '
    .public_base_url as $b | .surface_id as $s
    | (.repository_key.public_key_path | split("/") | last | sub("\\.asc$"; "")) as $k
    | .repositories[] | select(.id == $id and .format == "apt")
    | "Types: deb\nURIs: \($b)\(.path)\nSuites: \(.suite)\nComponents: \(.component)\nSigned-By: /etc/apt/keyrings/\($s)-\($k).asc"' "$1"
}
pkgrepo_apt_sources_path() {
  "${JQ:-jq}" -r --arg id "$2" '.repositories[] | select(.id == $id) | "\(.path)\(.product).sources"' "$1"
}

# pkgrepo_dnf_repo_prefix INV PRODUCT — the common <prefix> of PRODUCT's DNF
# repositories laid out as <prefix><arch>/, or "!" when they are not.
pkgrepo_dnf_repo_prefix() {
  "${JQ:-jq}" -r --arg p "$2" '
    [.repositories[] | select(.format == "dnf" and .product == $p) | .path as $x | .arch as $a
      | if ($x | endswith($a + "/")) then ($x | .[0:(length - ($a | length) - 1)]) else "!" end]
    | unique | if length == 1 then .[0] else "!" end' "$1"
}
pkgrepo_dnf_repo_path() {
  local p
  p="$(pkgrepo_dnf_repo_prefix "$1" "$2")"
  [ "$p" != "!" ] || return 1
  printf '%s%s.repo' "$p" "$2"
}

# pkgrepo_dnf_repo INV PRODUCT — one .repo using $basearch. The repository key
# authenticates metadata; ONLY that product's producer keys authenticate
# packages. skip_if_unavailable=False: dnf5 would otherwise SKIP a repository
# whose repomd.xml signature fails and exit 0. Prints a reason and returns 1 if
# the product's layout or producer is ambiguous.
pkgrepo_dnf_repo() {
  local prefix producers
  prefix="$(pkgrepo_dnf_repo_prefix "$1" "$2")"
  [ "$prefix" != "!" ] || {
    printf "product %s's DNF repositories are not laid out as <prefix><arch>/ under one prefix" "$2"
    return 1
  }
  producers="$("${JQ:-jq}" -r --arg p "$2" '[.repositories[] | select(.format == "dnf" and .product == $p) | .producer_repo | ascii_downcase] | unique | .[]' "$1")"
  [ "$(printf '%s\n' "$producers" | wc -l | tr -d ' ')" = 1 ] || {
    printf "product %s's DNF repositories belong to more than one producer" "$2"
    return 1
  }
  "${JQ:-jq}" -r --arg p "$2" --arg pr "$producers" --arg pre "$prefix" '
    .public_base_url as $b | .surface_id as $s
    | ([$b + .repository_key.public_key_path]
       + [.producer_keys[] | select((.producer_repo | ascii_downcase) == $pr) | $b + .public_key_path]) as $keys
    | "[\($s)-\($p)]\nname=\($p) (\($s))\nbaseurl=\($b)\($pre)$basearch/\nenabled=1\ngpgcheck=1\nrepo_gpgcheck=1\nskip_if_unavailable=False\ngpgkey=\($keys | join("\n       "))"' "$1"
}

pkgrepo_content_type() {
  case "$1" in
    *.deb) printf 'application/vnd.debian.binary-package' ;;
    *.rpm) printf 'application/x-rpm' ;;
    *.asc) case "$1" in */repodata/*) printf 'application/pgp-signature' ;; *) printf 'application/pgp-keys' ;; esac ;;
    *.gpg) printf 'application/pgp-signature' ;;
    *.gz) printf 'application/gzip' ;;
    *.xml) printf 'application/xml' ;;
    */by-hash/*) printf 'application/octet-stream' ;;
    *) printf 'text/plain' ;;
  esac
}

# pkgrepo_generation_id INV_SHA256 OBJECTS — OBJECTS is a JSON array or JSONL of
# {path, class, sha256, size}. The identity of a generation is the inventory it
# was built from plus every UNSIGNED object's path, class and digest — the
# signed Release and repomd.xml included, so it covers every index. Signature
# objects are left out: an OpenPGP signature carries its creation time, so
# re-signing identical content must not make a different generation, and the
# signatures are bound by verifying them over that content. The generator and
# the verifier compute it with this one function, so a generation's id is a
# fact about its content, never an assertion copied from the manifest.
pkgrepo_generation_id() {
  {
    printf '%s\n' "$1"
    "${JQ:-jq}" -cS -s 'if length == 1 and (.[0] | type) == "array" then .[0] else . end
      | map(select(.path | test("/InRelease$|/Release\\.gpg$|/repodata/repomd\\.xml\\.asc$") | not) | {path, class, sha256, size})
      | sort_by(.path)' "$2"
  } | sha256sum | cut -d' ' -f1
}

# pkgrepo_is_entrypoint PATH — whether PATH is a generation ENTRYPOINT: served
# at its stable URL through the activation pointer (pkgrepo-router.js), stored
# under _generations/<generation_id>/. Everything else is a shared immutable
# object served at its own path. pkgrepo-router.js implements the SAME rule
# (ENTRYPOINT_PATTERNS); tests/test-pkgrepo-router.sh proves they agree, and the
# verifier refuses a generation whose classes disagree with it.
PKGREPO_ENTRYPOINT_ERE='(^|/)dists/[^/]+/(InRelease|Release|Release\.gpg)$|(^|/)dists/[^/]+/[^/]+/binary-[^/]+/Packages(\.gz)?$|(^|/)repodata/repomd\.xml(\.asc)?$|\.(sources|repo|asc)$'
pkgrepo_is_entrypoint() {
  printf '%s\n' "$1" | grep -Eq "$PKGREPO_ENTRYPOINT_ERE"
}
