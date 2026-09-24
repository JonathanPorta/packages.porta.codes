#!/usr/bin/env bash
# rpm-finalize.sh — native RPM finalization (standards/releases/linux-packaging.md
# LP-9). Adds an OpenPGP signature to an UNSIGNED RPM and proves the change was
# ONLY a signature, then records the input/output binding for candidate
# assembly.
#
# Native RPM signing rewrites the file, so this is not a detached signer and
# cannot prove byte invariance. It proves instead, in this order:
#
#   1. the input's SHA-256 equals the digest the secret-free build recorded —
#      checked BEFORE the key is given to any tool;
#   2. the input is unsigned, and the declared public key has the declared
#      fingerprint;
#   3. after signing: the NEVRA is unchanged, EVERY byte after the signature
#      header (the main header and the payload) is identical, and `rpmkeys -K`
#      verifies the package against an rpmdb holding ONLY the declared key,
#      whose key id matches the signature's.
#
# The private key is taken by env-var NAME (or file path), captured into an
# unexported variable and scrubbed from the environment before any external
# command runs — the same discipline as sign.sh. It reaches gpg, over stdin,
# only after (1) and (2) pass, in an ephemeral GNUPGHOME removed on exit.
set -euo pipefail
set +x # never xtrace: this script handles private-key material
set +a

export -n __blessed_rpm_finalize_key 2>/dev/null || true
unset __blessed_rpm_finalize_key 2>/dev/null || true
__blessed_rpm_finalize_key=""

_n=0
for _a in "$@"; do [ "$_a" = "--private-key-env" ] && _n=$((_n + 1)); done
[ "$_n" -le 1 ] || {
  printf 'rpm-finalize: --private-key-env given more than once\n' >&2
  exit 2
}
unset _a _n

# Scrub the key env var BEFORE any external command (pure bash only above here).
_scan=("$@")
_si=0
while [ "$_si" -lt "${#_scan[@]}" ]; do
  if [ "${_scan[$_si]}" = "--private-key-env" ]; then
    _nm="${_scan[$((_si + 1))]:-}"
    case "$_nm" in
      __blessed_rpm_finalize_key | "" | [!A-Za-z_]* | *[!A-Za-z0-9_]*)
        printf 'rpm-finalize: invalid --private-key-env name\n' >&2
        exit 2
        ;;
    esac
    __blessed_rpm_finalize_key="${!_nm-}"
    unset "$_nm" 2>/dev/null || true
    unset _nm
    break
  fi
  _si=$((_si + 1))
done
unset _scan _si

usage() {
  cat >&2 <<'EOF'
Usage:
  rpm-finalize.sh --input UNSIGNED.rpm --input-sha256 HEX \
                  --key-fingerprint FPR40 --public-key PUB.asc \
                  (--private-key-env NAME | --private-key-file PATH) \
                  --output SIGNED.rpm --record RECORD.json

Exit 0 finalized · 1 refused (digest, key, signature or transformation check)
     · 2 usage or tooling error. Nothing is written unless every check passes.
EOF
  exit 2
}

die() {
  printf 'rpm-finalize: %s\n' "$1" >&2
  exit 2
}
refuse() {
  printf 'rpm-finalize: REFUSED — %s\n' "$1" >&2
  exit 1
}

input="" input_sha="" fpr="" pub="" key_file="" key_env="" output="" record=""
while [ $# -gt 0 ]; do
  case "$1" in
    --input)
      input="${2:-}"
      shift 2
      ;;
    --input-sha256)
      input_sha="${2:-}"
      shift 2
      ;;
    --key-fingerprint)
      fpr="${2:-}"
      shift 2
      ;;
    --public-key)
      pub="${2:-}"
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
    --output)
      output="${2:-}"
      shift 2
      ;;
    --record)
      record="${2:-}"
      shift 2
      ;;
    -h | --help) usage ;;
    *) die "unknown argument: $1" ;;
  esac
done
if [ -z "$input" ] || [ -z "$input_sha" ] || [ -z "$fpr" ] || [ -z "$pub" ] || [ -z "$output" ] || [ -z "$record" ]; then usage; fi
if [ -z "$key_env" ] && [ -z "$key_file" ]; then usage; fi
if [ -n "$key_env" ] && [ -n "$key_file" ]; then die "give --private-key-env or --private-key-file, not both"; fi
case "$input_sha" in *[!0-9a-f]* | "") die "--input-sha256 must be 64 lowercase hex" ;; esac
[ "${#input_sha}" -eq 64 ] || die "--input-sha256 must be 64 lowercase hex"
case "$fpr" in *[!0-9A-F]* | "") die "--key-fingerprint must be 40 uppercase hex" ;; esac
[ "${#fpr}" -eq 40 ] || die "--key-fingerprint must be 40 uppercase hex"
if [ ! -f "$input" ] || [ -L "$input" ]; then die "input is not a regular file: $input"; fi
[ -f "$pub" ] || die "public key not found: $pub"
for t in rpm rpmkeys rpmsign gpg sha256sum od jq realpath; do
  command -v "$t" >/dev/null 2>&1 || die "required tool not found: $t"
done

# ── destinations: two DISTINCT canonical paths, neither existing ───────────
# Canonicalized through the (existing) parent directory, so a symlinked or
# dot-segment alias of the same path is caught, not just a literal repeat.
canon() {
  local d
  d="$(cd "$(dirname "$1")" 2>/dev/null && pwd -P)" || die "destination directory does not exist: $(dirname "$1")"
  printf '%s/%s' "$d" "$(basename "$1")"
}
out_c="$(canon "$output")"
rec_c="$(canon "$record")"
[ "$out_c" != "$rec_c" ] || die "--output and --record name the same file ($out_c)"
if [ -e "$out_c" ] || [ -L "$out_c" ]; then die "output already exists: $output"; fi
if [ -e "$rec_c" ] || [ -L "$rec_c" ]; then die "record already exists: $record"; fi

sha() { sha256sum "$1" | cut -d' ' -f1; }

# Byte offset where the main header begins: 96-byte lead, then the signature
# header (16-byte intro + 16 bytes per index entry + data), padded to 8.
main_header_offset() {
  local m a b c d e f g h n s
  m="$(od -An -tx1 -j96 -N3 "$1" | tr -d ' \n')"
  [ "$m" = "8eade8" ] || refuse "$(basename "$1") has no RPM signature header where one must be"
  # shellcheck disable=SC2046
  set -- $(od -An -tu1 -j104 -N8 "$1")
  a=$1 b=$2 c=$3 d=$4 e=$5 f=$6 g=$7 h=$8
  n=$(((a << 24) | (b << 16) | (c << 8) | d))
  s=$(((e << 24) | (f << 16) | (g << 8) | h))
  s=$((16 + 16 * n + s))
  printf '%s' $((96 + s + ((8 - s % 8) % 8)))
}
region_sha() { tail -c +$(($(main_header_offset "$1") + 1)) "$1" | sha256sum | cut -d' ' -f1; }

work="$(mktemp -d)" || die "cannot create a private work directory"
trap 'rm -rf "$work"' EXIT
chmod 700 "$work"
IN="$work/input.rpm"
PKG="$work/pkg.rpm"

# ── 1. SNAPSHOT, then verify the snapshot ──────────────────────────────────
# Everything below reads ONLY this private copy. Hashing the caller's path and
# later reading it again would let a file swapped in between be signed under
# the approved digest.
cp -- "$input" "$IN" || die "cannot snapshot the input"
got="$(sha "$IN")"
[ "$got" = "$input_sha" ] ||
  refuse "input digest $got is not the recorded build digest $input_sha; the key was not used"
[ "${RPM_FINALIZE_TEST_SWAP:-}" = "" ] || cp -- "$RPM_FINALIZE_TEST_SWAP" "$input" # test hook: the caller's file changes now

# ── 2. supported, unsigned input; the declared key is a supported key ──────
# rpm 6 reports the package format; rpm 4 cannot read a v6 package at all.
# rpm 4 does not know the tag and prints nothing (it exits 0), so only a
# REPORTED format other than 4 is refused.
fmt="$(rpm -qp --nosignature --qf '%{RPMFORMAT}' "$IN" 2>/dev/null || true)"
case "$fmt" in
  "" | 4) ;;
  *) refuse "RPM v$fmt package format is not supported; finalization handles v4 packages" ;;
esac
rpm -qp --nosignature --qf '%{NEVRA}' "$IN" >/dev/null 2>&1 || refuse "the input is not a readable RPM package"
# ANY signature of ANY algorithm or header form (RSA, DSA, EdDSA, rpm 6
# OPENPGP) appears as a "signature" line when checked against an empty rpmdb;
# an unsigned package lists only digests.
mkdir "$work/emptydb"
# Captured, not piped into grep: against an empty rpmdb rpmkeys exits
# NON-ZERO for a signed package (NOKEY), and under pipefail that status would
# make a matching grep read as "no signature" — accepting a signed input.
kv0="$(rpmkeys --dbpath "$work/emptydb" -Kv "$IN" 2>&1 || true)"
case "$kv0" in
  *[Ss]ignature*) refuse "input is already signed; finalization signs an unsigned build output" ;;
esac
# EXACTLY ONE primary key, and it is the declared one. Checking only the first
# fingerprint and then importing the whole file would let a bundle that BEGINS
# with the declared key smuggle another trusted signer into the verification
# below. Subkeys of the declared key are legitimate and allowed.
keylist="$(gpg --batch --with-colons --show-keys "$pub" 2>/dev/null)"
npub="$(printf '%s\n' "$keylist" | grep -c '^pub:' || true)"
[ "$npub" = 1 ] || refuse "the public key file holds $npub primary keys; it must hold exactly the declared key"
pub_line="$(printf '%s\n' "$keylist" | awk -F: '/^pub:/{print $4 " " $3; exit}')"
pub_fpr="$(printf '%s\n' "$keylist" | awk -F: '/^pub:/{p=1; next} p && /^fpr:/{print $10; exit}')"
[ "$pub_fpr" = "$fpr" ] || refuse "public key fingerprint ${pub_fpr:-<none>} is not the declared $fpr"
# Supported signing profile: OpenPGP RSA, >= 3072 bits, v4 packages — the form
# every supported rpm/dnf verifies. Anything else is refused before key use.
read -r key_algo key_bits <<<"$pub_line"
[ "${key_algo:-}" = 1 ] || refuse "key algorithm ${key_algo:-unknown} is not supported; finalization signs with OpenPGP RSA keys"
[ "${key_bits:-0}" -ge 3072 ] || refuse "RSA key of ${key_bits:-0} bits is below the supported 3072"

export GNUPGHOME="$work/gnupg"
mkdir -m 700 "$GNUPGHOME"
if [ -n "$key_file" ]; then
  [ -f "$key_file" ] || die "private key file not found"
  gpg --batch --quiet --import <"$key_file" 2>/dev/null || refuse "the private key could not be imported"
else
  [ -n "$__blessed_rpm_finalize_key" ] || die "private key env var is empty or unset"
  printf '%s' "$__blessed_rpm_finalize_key" | gpg --batch --quiet --import 2>/dev/null ||
    refuse "the private key could not be imported"
fi
__blessed_rpm_finalize_key=""
sec_fpr="$(gpg --batch --with-colons --list-secret-keys 2>/dev/null | awk -F: '/^fpr:/{print $10; exit}')"
[ "$sec_fpr" = "$fpr" ] || refuse "the private key is ${sec_fpr:-<none>}, not the declared $fpr"

# ── sign a copy OF THE SNAPSHOT ────────────────────────────────────────────
cp -- "$IN" "$PKG"
# `__gpg` is set explicitly: distributions disagree on its default (gpg vs
# gpg2 paths), and a missing binary would otherwise surface as a signing error.
if ! rpmsign --addsign \
  --define "__gpg $(command -v gpg)" \
  --define "_gpg_name $fpr" \
  --define "_openpgp_sign_id $fpr" \
  --define "_gpg_path $GNUPGHOME" \
  "$PKG" >/dev/null 2>"$work/sign.err"; then
  sed 's/^/rpm-finalize: rpmsign: /' "$work/sign.err" >&2
  refuse "rpmsign failed"
fi
[ "${RPM_FINALIZE_TEST_TAMPER:-}" != "payload" ] || printf 'X' >>"$PKG" # test hook: corrupt after signing

# ── 3. the transformation was ONLY a signature — against the snapshot ──────
nevra="$(rpm -qp --nosignature --qf '%{NEVRA}' "$IN")"
[ "$(rpm -qp --nosignature --qf '%{NEVRA}' "$PKG")" = "$nevra" ] ||
  refuse "package identity (NEVRA) changed during signing"
in_region="$(region_sha "$IN")"
out_region="$(region_sha "$PKG")"
[ "$in_region" = "$out_region" ] ||
  refuse "bytes outside the signature header changed (main header or payload); signing may only add a signature"
# Verify against an rpmdb holding ONLY the declared key: every signature line
# must be OK, at least one must exist, and it must name the declared key: rpm
# 4 prints the last 8 hex digits of its id, rpm 6 the last 16 — or, when the
# key is in the rpmdb, its full fingerprint.
mkdir "$work/rpmdb"
rpmkeys --dbpath "$work/rpmdb" --import "$pub" >/dev/null 2>&1 || die "rpmkeys could not import the public key"
kv="$(rpmkeys --dbpath "$work/rpmdb" --define '_pkgverify_level all' -Kv "$PKG" 2>&1)" ||
  refuse "rpmkeys -K failed against the declared key: $kv"
sigs="$(printf '%s\n' "$kv" | grep -i 'signature' || true)"
[ -n "$sigs" ] || refuse "the output carries no signature"
if printf '%s\n' "$sigs" | grep -qv ': OK$'; then refuse "a signature did not verify against the declared key: $sigs"; fi
id16="$(printf '%s' "${fpr: -16}" | tr 'A-F' 'a-f')"
id8="${id16: -8}"
fpr_l="$(printf '%s' "$fpr" | tr 'A-F' 'a-f')"
if printf '%s\n' "$sigs" | grep -qiv -e "key id $id16" -e "key id $id8:" -e "key fingerprint: $fpr_l"; then
  refuse "a signature's key id is not the declared key's: $sigs"
fi
sig_desc="$(printf '%s' "$sigs" | head -1 | sed 's/^ *//; s/: OK$//')"

# ── publish: never overwrite, and never leave half a pair ──────────────────
out_sha="$(sha "$PKG")"
jq -n --arg nevra "$nevra" --arg input "$input_sha" --arg output "$out_sha" --arg region "$out_region" \
  --arg fpr "$fpr" --arg sig "$sig_desc" \
  '{schema: "blessed/rpm-finalization/v1", nevra: $nevra,
    input_sha256: $input, output_sha256: $output,
    immutable_region_sha256: $region, key_fingerprint: $fpr, signature: $sig}' >"$work/record.json"
# A hard link is created ATOMICALLY and fails if the name exists, so a
# concurrent finalizer (or anything else) that created either destination
# after the checks above is never overwritten. Temporaries sit beside each
# destination so the link stays on one filesystem.
publish() { # $1 src, $2 canonical destination
  local tmp
  tmp="$(mktemp "$(dirname "$2")/.rpm-finalize.XXXXXX")" || return 1
  if ! cp -- "$1" "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  # test hook: RPM_FINALIZE_TEST_RACE=<basename>:<file|dir|dirlink|dangling>
  # — a concurrent writer creates that kind of entry at the destination now.
  case "${RPM_FINALIZE_TEST_RACE:-}" in
    "$(basename "$2")":file) printf 'someone else\n' >"$2" ;;
    "$(basename "$2")":dir) mkdir "$2" ;;
    "$(basename "$2")":dirlink) ln -s "$(dirname "$2")" "$2" ;;
    "$(basename "$2")":dangling) ln -s "$(dirname "$2")/.no-such-target" "$2" ;;
  esac
  # -T (--no-target-directory): the destination is ALWAYS the exact name. Without
  # it, an existing directory (or a symlink to one) at that name makes ln create
  # the link INSIDE it and report success — a "finalized" RPM that is not at the
  # requested path. With it, any existing entry of any type is a refusal.
  if ! ln -T -- "$tmp" "$2" 2>/dev/null; then
    rm -f "$tmp"
    return 1
  fi
  rm -f "$tmp"
}
publish "$PKG" "$out_c" || refuse "could not create $output without overwriting an existing file; nothing published"
if ! publish "$work/record.json" "$rec_c"; then
  rm -f "$out_c" # ours: created by the link above, so removing it leaves nothing half-published
  refuse "could not create $record without overwriting an existing file; the signed RPM was withdrawn"
fi
printf 'rpm-finalize: OK %s %s -> %s (key %s)\n' "$(basename "$output")" "${input_sha:0:12}" "${out_sha:0:12}" "${fpr: -16}"
