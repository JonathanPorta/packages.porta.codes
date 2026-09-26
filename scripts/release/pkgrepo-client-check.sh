#!/usr/bin/env bash
# pkgrepo-client-check.sh — prove a served repository works for a REAL native
# client (standards/releases/package-repositories.md PR-5, PR-6, PR-15).
#
# Runs inside a fresh target system (a debian/ubuntu or fedora container, or a
# VM) as root. It configures the repository exactly as a user would — from the
# published client configuration and public keys, each key's fingerprint
# checked to be exactly the expected one BEFORE it is trusted — and then asks the
# native package manager, with every signature check on, to:
#
#   install  NAME at VERSION        (dependencies resolved by apt/dnf alone)
#   run      CHECK                  (the product actually works)
#   upgrade  to the newest version  (and CHECK reports it)
#
# or, with --expect-refusal, proves the client REFUSES the repository (for
# mixed generations, altered metadata and the like).
#
# It never passes trusted=yes, --nogpgcheck, allow-insecure or similar.
#
# Exit: 0 behaved as expected · 1 did not · 2 tooling/usage.
set -uo pipefail
die() {
  printf 'pkgrepo-client-check: %s\n' "$1" >&2
  exit 2
}
fail() {
  printf 'pkgrepo-client-check: FAILED — %s\n' "$1" >&2
  exit 1
}
usage() {
  cat >&2 <<'EOF'
Usage (inside the target system, as root):
  pkgrepo-client-check.sh --format apt|dnf --config-url URL \
      --key URL=FINGERPRINT [--key URL=FINGERPRINT ...] \
      (--install NAME=VERSION [--check 'CMD'] [--upgrade-to VERSION] [--remove] | --expect-refusal)
EOF
  exit 2
}
fmt="" cfg="" install="" check="" upgrade="" remove=0 refusal=0
keys=()
while [ $# -gt 0 ]; do
  case "$1" in
    --format)
      fmt="${2:-}"
      shift 2
      ;;
    --config-url)
      cfg="${2:-}"
      shift 2
      ;;
    --key)
      keys+=("${2:-}")
      shift 2
      ;;
    --install)
      install="${2:-}"
      shift 2
      ;;
    --check)
      check="${2:-}"
      shift 2
      ;;
    --upgrade-to)
      upgrade="${2:-}"
      shift 2
      ;;
    --remove)
      remove=1
      shift
      ;;
    --expect-refusal)
      refusal=1
      shift
      ;;
    -h | --help) usage ;;
    *) die "unknown argument: $1" ;;
  esac
done
if [ -z "$fmt" ] || [ -z "$cfg" ] || [ "${#keys[@]}" -eq 0 ]; then usage; fi
[ "$refusal" = 1 ] || [ -n "$install" ] || usage
[ "$(id -u)" = 0 ] || die "must run as root in the target system"
command -v curl >/dev/null 2>&1 || die "curl is required"
command -v gpg >/dev/null 2>&1 || die "gpg is required"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
export GNUPGHOME="$work/g"
mkdir -m 700 "$GNUPGHOME"

# ── trust bootstrap: each key is the expected key, or nothing is trusted ───
i=0
for kv in "${keys[@]}"; do
  url="${kv%=*}" want="${kv##*=}"
  curl -fsSL --proto '=https,http' "$url" -o "$work/k$i.asc" || fail "cannot fetch key $url"
  # Exactly ONE primary key, and it is the expected one (its subkeys are
  # allowed): a bundle that begins with the expected key must not smuggle a
  # second signer into the trust store.
  list="$(gpg --batch --with-colons --show-keys "$work/k$i.asc" 2>/dev/null)" || fail "key $url is not a readable OpenPGP key"
  n="$(printf '%s\n' "$list" | grep -c '^pub:' || true)"
  [ "$n" = 1 ] || fail "key $url holds $n primary keys, not exactly the expected $want — refusing to trust it"
  got="$(printf '%s\n' "$list" | awk -F: '/^pub:/{p=1; next} p && /^fpr:/{print $10; exit}')"
  [ "$got" = "$want" ] || fail "key $url is ${got:-<none>}, not the expected $want — refusing to trust it"
  i=$((i + 1))
done

case "$fmt" in
  apt)
    command -v apt-get >/dev/null 2>&1 || die "apt-get not found"
    curl -fsSL "$cfg" -o "$work/repo.sources" || fail "cannot fetch $cfg"
    grep -qiE 'trusted|allow-insecure|allow-weak' "$work/repo.sources" && fail "the published source weakens verification"
    ring="$(sed -n 's/^Signed-By: *//p' "$work/repo.sources")"
    [ -n "$ring" ] || fail "the published source has no Signed-By"
    install -d -m 0755 "$(dirname "$ring")"
    # Signed-By names ONE keyring: the repository key (the first --key).
    cp "$work/k0.asc" "$ring"
    chmod 0644 "$ring"
    cp "$work/repo.sources" /etc/apt/sources.list.d/pkgrepo-check.sources
    if [ "$refusal" = 1 ]; then
      out="$(apt-get update -o Acquire::Retries=0 2>&1)"
      if printf '%s' "$out" | grep -qE '^(E|W): .*(pkgrepo-check|NO_PUBKEY|BADSIG|not signed|Hash Sum mismatch|File has unexpected size|invalid)'; then
        printf 'pkgrepo-client-check: OK — apt refused the repository as expected\n'
        exit 0
      fi
      fail "apt accepted a repository it should have refused: $out"
    fi
    out="$(apt-get update 2>&1)" || fail "apt-get update failed: $out"
    printf '%s' "$out" | grep -qE '^(E|W): ' && fail "apt-get update reported: $(printf '%s' "$out" | grep -E '^(E|W): ')"
    name="${install%=*}" ver="${install##*=}"
    DEBIAN_FRONTEND=noninteractive apt-get install -y "$name=$ver" >"$work/i.log" 2>&1 || fail "install $name=$ver failed: $(tail -5 "$work/i.log")"
    [ "$(dpkg-query -W -f='${Version}' "$name")" = "$ver" ] || fail "installed $name is not $ver"
    ;;
  dnf)
    command -v dnf >/dev/null 2>&1 || die "dnf not found"
    curl -fsSL "$cfg" -o "$work/repo.repo" || fail "cannot fetch $cfg"
    grep -qx 'gpgcheck=1' "$work/repo.repo" || fail "the published .repo does not enable gpgcheck"
    grep -qx 'repo_gpgcheck=1' "$work/repo.repo" || fail "the published .repo does not enable repo_gpgcheck"
    grep -qx 'skip_if_unavailable=False' "$work/repo.repo" || fail "the published .repo would let dnf skip a refused repository silently"
    cp "$work/repo.repo" /etc/yum.repos.d/pkgrepo-check.repo
    # Keys are imported from the VERIFIED local copies, not re-fetched by dnf.
    for f in "$work"/k*.asc; do rpm --import "$f" || fail "rpm --import failed"; done
    rid="$(sed -n 's/^\[\(.*\)\]$/\1/p' "$work/repo.repo" | head -1)"
    if [ "$refusal" = 1 ]; then
      if out="$(dnf -y --disablerepo='*' --enablerepo="$rid" makecache 2>&1)"; then
        fail "dnf accepted a repository it should have refused: $out"
      fi
      printf 'pkgrepo-client-check: OK — dnf refused the repository as expected\n'
      exit 0
    fi
    name="${install%=*}" ver="${install##*=}"
    dnf -y --disablerepo='*' --enablerepo="$rid" install "$name-$ver" >"$work/i.log" 2>&1 ||
      fail "install $name-$ver failed: $(tail -5 "$work/i.log")"
    [ "$(rpm -q --qf '%{VERSION}-%{RELEASE}' "$name")" = "$ver" ] || fail "installed $name is not $ver"
    ;;
  *) die "--format must be apt or dnf" ;;
esac
printf 'pkgrepo-client-check: installed %s\n' "$install"
if [ -n "$check" ]; then
  sh -c "$check" >"$work/c.log" 2>&1 || fail "the functional check failed after install: $(tail -5 "$work/c.log")"
fi
if [ -n "$upgrade" ]; then
  name="${install%=*}"
  case "$fmt" in
    apt)
      apt-get update >/dev/null 2>&1 || fail "apt-get update before upgrade failed"
      DEBIAN_FRONTEND=noninteractive apt-get install -y --only-upgrade "$name" >"$work/u.log" 2>&1 || fail "upgrade failed: $(tail -5 "$work/u.log")"
      got="$(dpkg-query -W -f='${Version}' "$name")"
      ;;
    dnf)
      dnf -y --disablerepo='*' --enablerepo="$rid" --refresh upgrade "$name" >"$work/u.log" 2>&1 || fail "upgrade failed: $(tail -5 "$work/u.log")"
      got="$(rpm -q --qf '%{VERSION}-%{RELEASE}' "$name")"
      ;;
  esac
  [ "$got" = "$upgrade" ] || fail "after upgrade $name is $got, not $upgrade"
  printf 'pkgrepo-client-check: upgraded %s to %s\n' "$name" "$upgrade"
  if [ -n "$check" ]; then
    sh -c "$check" >"$work/c.log" 2>&1 || fail "the functional check failed after upgrade: $(tail -5 "$work/c.log")"
  fi
fi
if [ "$remove" = 1 ]; then
  name="${install%=*}"
  case "$fmt" in
    apt) DEBIAN_FRONTEND=noninteractive apt-get remove -y "$name" >/dev/null 2>&1 || fail "remove failed" ;;
    dnf) dnf -y remove "$name" >/dev/null 2>&1 || fail "remove failed" ;;
  esac
  printf 'pkgrepo-client-check: removed %s\n' "$name"
fi
printf 'pkgrepo-client-check: OK\n'
