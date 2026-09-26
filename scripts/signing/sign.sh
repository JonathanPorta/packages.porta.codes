#!/usr/bin/env bash
# sign.sh — produce a detached ed25519-detached-v1 signature over the EXACT bytes
# of a file (standards/signing/ed25519-detached.md). OpenSSL 3 backend; the caller
# supplies the private key by env-var NAME or file path — BWS/secret retrieval is
# out of scope. The private key never appears on argv or in logs.
set -euo pipefail
set +x # never xtrace: this script handles private-key material (bash -x would leak it)
set +a # disable allexport: a scratch assignment must NOT inherit the export attribute

# Namespaced internal scratch for the private key. Force it un-exported even if the
# caller pre-exported a variable of this name — assigning to an already-exported
# variable keeps the export attribute, which would re-leak the PEM to children.
export -n __blessed_signing_private_key_value 2>/dev/null || true
unset __blessed_signing_private_key_value 2>/dev/null || true
__blessed_signing_private_key_value=""

# ── Reject duplicate key-source flags. A second --private-key-env would leave one
#    secret exported and let the arg parser (last-wins) use a different variable
#    than the one the pre-scan captured/unset. ──
_pk_env_n=0
_pk_file_n=0
for _a in "$@"; do
  case "$_a" in
    --private-key-env) _pk_env_n=$((_pk_env_n + 1)) ;;
    --private-key-file) _pk_file_n=$((_pk_file_n + 1)) ;;
  esac
done
[ "$_pk_env_n" -le 1 ] || {
  printf 'signing: --private-key-env given more than once\n' >&2
  exit 2
}
[ "$_pk_file_n" -le 1 ] || {
  printf 'signing: --private-key-file given more than once\n' >&2
  exit 2
}
unset _a _pk_env_n _pk_file_n

# ── SCRUB the private-key env var BEFORE launching ANY external process ────────
# Every child (dirname, openssl, mktemp, ...) inherits the environment, so the
# secret must leave the environment first. Pre-scan argv in PURE BASH (no external
# command), validate the variable name, copy the value into a NON-exported shell
# variable, and unset the original — all before the HERE/openssl/mktemp lines below.
_pk_have=0
_scan=("$@")
_si=0
while [ "$_si" -lt "${#_scan[@]}" ]; do
  if [ "${_scan[$_si]}" = "--private-key-env" ]; then
    _pk_name="${_scan[$((_si + 1))]:-}"
    [ "$_pk_name" = "__blessed_signing_private_key_value" ] && {
      printf 'signing: --private-key-env may not name the reserved internal variable\n' >&2
      exit 2
    }
    case "$_pk_name" in
      [A-Za-z_]*) ;;
      *)
        printf 'signing: invalid --private-key-env name: %s\n' "$_pk_name" >&2
        exit 2
        ;;
    esac
    case "$_pk_name" in
      *[!A-Za-z0-9_]*)
        printf 'signing: invalid --private-key-env name: %s\n' "$_pk_name" >&2
        exit 2
        ;;
    esac
    __blessed_signing_private_key_value="${!_pk_name-}"
    _pk_have=1
    unset "$_pk_name" 2>/dev/null || true
    unset _pk_name
    break
  fi
  _si=$((_si + 1))
done
unset _scan _si

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/signing/lib/signing-lib.sh
. "$HERE/lib/signing-lib.sh"

usage() {
  cat >&2 <<'EOF'
Usage:
  sign.sh --profile ed25519-detached-v1 --input FILE \
          (--private-key-env NAME | --private-key-file PATH) \
          --output FILE.sig [--force]

Signs the exact bytes of FILE and writes an 88-char base64 signature (no trailing
newline) to FILE.sig. Only the ENV VAR NAME (never the key) appears in argv.
Refuses an existing output unless --force (which atomically replaces a regular file).
EOF
  exit 2
}

profile="" input="" key_env="" key_file="" output="" force=0
while [ $# -gt 0 ]; do
  case "$1" in
    --profile)
      profile="${2:-}"
      shift 2
      ;;
    --input)
      input="${2:-}"
      shift 2
      ;;
    --private-key-env)
      key_env="${2:-}"
      shift 2
      ;;
    --private-key-file)
      key_file="${2:-}"
      shift 2
      ;;
    --output)
      output="${2:-}"
      shift 2
      ;;
    --force)
      force=1
      shift
      ;;
    -h | --help) usage ;;
    --)
      shift
      break
      ;;
    -*)
      printf 'signing: unknown option: %s\n' "$1" >&2
      usage
      ;;
    *)
      printf 'signing: unexpected argument: %s\n' "$1" >&2
      usage
      ;;
  esac
done

[ "$profile" = "$SIG_PROFILE" ] || {
  printf 'signing: --profile must be %s\n' "$SIG_PROFILE" >&2
  exit 2
}
[ -n "$input" ] || usage
[ -n "$output" ] || usage
{ [ -f "$input" ] && [ ! -L "$input" ]; } || {
  printf 'signing: --input must be an existing regular file: %s\n' "$input" >&2
  exit 2
}
if { [ -n "$key_env" ] && [ -n "$key_file" ]; } || { [ -z "$key_env" ] && [ -z "$key_file" ]; }; then
  printf 'signing: provide exactly one of --private-key-env / --private-key-file\n' >&2
  exit 2
fi

# Validate the output target up front (README promises symlink/overwrite refusal).
[ -L "$output" ] && {
  printf 'signing: refusing to write through a symlink: %s\n' "$output" >&2
  exit 2
}
if [ -e "$output" ]; then
  [ -d "$output" ] && {
    printf 'signing: --output is a directory: %s\n' "$output" >&2
    exit 2
  }
  [ -f "$output" ] || {
    printf 'signing: --output exists and is not a regular file: %s\n' "$output" >&2
    exit 2
  }
  [ "$force" -eq 1 ] || {
    printf 'signing: --output already exists (use --force to replace): %s\n' "$output" >&2
    exit 2
  }
fi
if [ -e "$output" ] && [ "$input" -ef "$output" ]; then
  printf 'signing: --output must differ from --input\n' >&2
  exit 2
fi

sig_require_openssl3 || exit 1

umask 077
KEYDIR="$(mktemp -d)"
trap 'rm -rf "$KEYDIR"' EXIT INT TERM HUP
keypem="$KEYDIR/key.pem"

if [ -n "$key_env" ]; then
  [ "$_pk_have" -eq 1 ] || {
    printf 'signing: --private-key-env %s was not captured\n' "$key_env" >&2
    exit 2
  }
  [ -n "$__blessed_signing_private_key_value" ] || {
    printf 'signing: env var %s is unset or empty\n' "$key_env" >&2
    exit 2
  }
  printf '%s' "$__blessed_signing_private_key_value" >"$keypem"
  unset __blessed_signing_private_key_value
else
  { [ -f "$key_file" ] && [ ! -L "$key_file" ]; } || {
    printf 'signing: --private-key-file missing or a symlink: %s\n' "$key_file" >&2
    exit 2
  }
  cat -- "$key_file" >"$keypem"
fi
chmod 600 "$keypem"
"$(sig_openssl)" pkey -in "$keypem" -noout 2>/dev/null || {
  printf 'signing: not a valid private key\n' >&2
  exit 1
}

sig_b64="$(sig_sign_file "$keypem" "$input")" || exit 1

outdir="$(dirname -- "$output")"
tmpout="$(mktemp "$outdir/.sig.XXXXXX")"
trap 'rm -rf "$KEYDIR"; rm -f "$tmpout"' EXIT INT TERM HUP
printf '%s' "$sig_b64" >"$tmpout"
mv -f "$tmpout" "$output" # atomic within outdir; target type already validated above
printf 'signing: wrote %s\n' "$output" >&2
