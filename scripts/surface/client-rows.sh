#!/usr/bin/env bash
# client-rows.sh — install, upgrade and remove every product through a served
# generation with REAL native clients, one supported matrix row at a time
# (blessed releases.package-repositories@1 PR-6, PR-15; linux-packaging LP-6).
#
# A row is one inventory repository on one of its approved targets (Debian 13
# → debian:13, Fedora 44 → fedora:44) at THIS host's architecture. Rows for
# another architecture are listed as not exercised here — never as passed.
# For each package in a row: install the second-newest version (or the only
# one), run the producer's functional check (surface/admission.json `smoke`),
# upgrade to the newest, check again, remove. Trust is bootstrapped from the
# PUBLISHED configuration and keys, each key checked against the inventory's
# fingerprint (pkgrepo-client-check.sh); every signature check stays on.
#
# Staged (before publication): --serve DIR --tls-dir DIR serves DIR over HTTPS
# as the surface's own hostname on a private network, with a throwaway
# certificate only the client containers trust — so the configuration users
# will fetch is tested byte for byte. Read-back (after publication): omit
# --serve; the clients use the real endpoint.
#
# Packages whose producer sets `systemd: true` run in a client with a booted
# systemd (privileged, cgroupns=host), as their scriptlets require.
#
# Exit: 0 every exercised row passed · 1 a row failed · 2 tooling/usage.
# shellcheck disable=SC2016  # jq programs: $-names are jq variables, not shell
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
JQ="${JQ_BIN:-jq}"
die() {
  printf 'client-rows: %s\n' "$1" >&2
  exit 2
}
usage() {
  printf 'Usage: client-rows.sh --inventory INV --policy POLICY [--serve DIR --tls-dir DIR] [--only-product NAME]\n' >&2
  exit 2
}
inv="" policy="" serve="" tls="" only=""
while [ $# -gt 0 ]; do
  case "$1" in
    --inventory) inv="${2:-}" && shift 2 ;;
    --policy) policy="${2:-}" && shift 2 ;;
    --serve) serve="${2:-}" && shift 2 ;;
    --tls-dir) tls="${2:-}" && shift 2 ;;
    --only-product) only="${2:-}" && shift 2 ;;
    -h | --help) usage ;;
    *) die "unknown argument: $1" ;;
  esac
done
if [ -z "$inv" ] || [ -z "$policy" ]; then usage; fi
if [ -n "$serve" ] && [ -z "$tls" ]; then die "--serve needs --tls-dir (tls-cert.pem, tls-key.pem)"; fi
command -v docker >/dev/null 2>&1 || die "docker is required"
base="$("$JQ" -r .public_base_url "$inv")"
host="${base#https://}"
host="${host%%/*}"
case "$(uname -m)" in
  x86_64 | amd64) DEBARCH=amd64 RPMARCH=x86_64 ;;
  aarch64 | arm64) DEBARCH=arm64 RPMARCH=aarch64 ;;
  *) die "unsupported host architecture $(uname -m)" ;;
esac
NET="ppc-rows-$$"
IDS=()
cleanup() {
  [ "${#IDS[@]}" -eq 0 ] || docker rm -f "${IDS[@]}" >/dev/null 2>&1
  docker network rm "$NET" >/dev/null 2>&1
}
trap cleanup EXIT
docker network create "$NET" >/dev/null || die "cannot create a docker network"

if [ -n "$serve" ]; then
  conf="$(mktemp)"
  printf 'server {\n  listen 443 ssl;\n  server_name %s;\n  ssl_certificate /tls/tls-cert.pem;\n  ssl_certificate_key /tls/tls-key.pem;\n  root /srv;\n  autoindex off;\n}\n' "$host" >"$conf"
  chmod 644 "$conf"
  web="$(docker run -d --network "$NET" --network-alias "$host" -v "$(cd "$serve" && pwd)":/srv:ro -v "$(cd "$tls" && pwd)":/tls:ro \
    -v "$conf":/etc/nginx/conf.d/default.conf:ro \
    nginx:1.27-alpine@sha256:65645c7bb6a0661892a8b03b89d0743208a18dd2f3f17a54ef4b76fb8e2f2a10)" || die "cannot start the staging server"
  IDS+=("$web")
  up=0
  for _ in $(seq 1 20); do
    if docker exec "$web" nc -z 127.0.0.1 443 2>/dev/null; then
      up=1
      break
    fi
    sleep 1
  done
  [ "$up" = 1 ] || die "the staging server did not come up"
fi

# Client images: the distro release, plus exactly what bootstrapping trust
# needs (curl, gpg, CA store) and systemd for packages that manage a service.
client_image() { # debian13|fedora44 → tag
  local tag="ppc-client-$1"
  if ! docker image inspect "$tag" >/dev/null 2>&1; then
    case "$1" in
      debian13) printf 'FROM debian:13\nRUN apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq systemd curl gnupg ca-certificates >/dev/null && rm -rf /var/lib/apt/lists/*\nCMD ["/lib/systemd/systemd"]\n' ;;
      fedora44) printf 'FROM fedora:44\nRUN dnf -y -q install systemd gnupg2 curl ca-certificates >/dev/null && dnf clean all\nCMD ["/usr/lib/systemd/systemd"]\n' ;;
    esac | docker build -q -t "$tag" - >/dev/null || die "cannot build the $1 client image"
  fi
  printf '%s' "$tag"
}
start_client() { # image, systemd(true|false) → container id
  local id
  if [ "$2" = true ]; then
    id="$(docker run -d --network "$NET" --privileged --cgroupns=host -v /sys/fs/cgroup:/sys/fs/cgroup:rw "$1")" || return 1
    for _ in $(seq 1 60); do
      case "$(docker exec "$id" systemctl is-system-running 2>/dev/null || true)" in running | degraded) break ;; esac
      sleep 2
    done
  else
    id="$(docker run -d --network "$NET" "$1" sleep 3600)" || return 1
  fi
  if [ -n "$tls" ]; then
    docker cp "$tls/tls-cert.pem" "$id:/root/staging-ca.pem" >/dev/null
    docker exec "$id" sh -c 'if [ -d /usr/local/share/ca-certificates ]; then cp /root/staging-ca.pem /usr/local/share/ca-certificates/staging.crt && update-ca-certificates >/dev/null 2>&1; else cp /root/staging-ca.pem /etc/pki/ca-trust/source/anchors/staging.pem && update-ca-trust; fi' ||
      return 1
  fi
  docker cp "$ROOT/scripts/release/pkgrepo-client-check.sh" "$id:/usr/local/bin/pkgrepo-client-check.sh" >/dev/null
  printf '%s' "$id"
}

pass=0 failed=0 skipped=0
repo_key="${base}$("$JQ" -r .repository_key.public_key_path "$inv")=$("$JQ" -r .repository_key.fingerprint "$inv")"
while IFS= read -r repo; do
  id="$("$JQ" -r .id <<<"$repo")"
  fmt="$("$JQ" -r .format <<<"$repo")"
  path="$("$JQ" -r .path <<<"$repo")"
  product="$("$JQ" -r .product <<<"$repo")"
  producer="$("$JQ" -r .producer_repo <<<"$repo")"
  [ -z "$only" ] || [ "$only" = "$product" ] || continue
  smoke="$("$JQ" -r --arg p "$producer" '.producers[$p].smoke // empty' "$policy")"
  sysd="$("$JQ" -r --arg p "$producer" '.producers[$p].systemd // false' "$policy")"
  [ -n "$smoke" ] || die "no functional check (smoke) for $producer in $policy"
  keys=(--key "$repo_key")
  if [ "$fmt" = apt ]; then
    arch="$DEBARCH"
    "$JQ" -e --arg a "$arch" '.architectures | index($a) != null' <<<"$repo" >/dev/null || {
      echo "  – $id: no $arch row; not exercised on this host"
      skipped=$((skipped + 1))
      continue
    }
    "$JQ" -e '.targets | any(.distro == "debian" and .release == "13")' <<<"$repo" >/dev/null || die "$id: no Debian 13 target to run on"
    img="$(client_image debian13)"
    cfg="${base}${path}${product}.sources"
    sel='.arch == $a or .arch == "all"'
  else
    arch="$RPMARCH"
    if [ "$("$JQ" -r .arch <<<"$repo")" != "$arch" ]; then
      echo "  – $id: $("$JQ" -r .arch <<<"$repo") row; not exercised on this $arch host"
      skipped=$((skipped + 1))
      continue
    fi
    "$JQ" -e '.targets | any(.distro == "fedora" and .release == "44")' <<<"$repo" >/dev/null || die "$id: no Fedora 44 target to run on"
    img="$(client_image fedora44)"
    cfg="${base}${path%"$arch/"}${product}.repo"
    sel='true'
    while IFS= read -r k; do keys+=(--key "$k"); done < <("$JQ" -r --arg p "$producer" --arg b "$base" '.producer_keys[] | select(.producer_repo == $p) | "\($b)\(.public_key_path)=\(.fingerprint)"' "$inv")
  fi
  while IFS= read -r name; do
    vers=()
    while IFS= read -r v; do vers+=("$v"); done < <("$JQ" -r --arg r "$id" --arg n "$name" --arg a "$arch" \
      ".packages[] | select(.repository == \$r and .name == \$n and ($sel)) | \"\\(.version)-\\(.revision)\"" "$inv" | sort -uV)
    [ "${#vers[@]}" -gt 0 ] || continue
    newest="${vers[${#vers[@]} - 1]}"
    first="$newest"
    [ "${#vers[@]}" -lt 2 ] || first="${vers[${#vers[@]} - 2]}"
    args=(--format "$fmt" --config-url "$cfg" "${keys[@]}" --install "$name=$first" --check "$smoke" --remove)
    [ "$first" = "$newest" ] || args+=(--upgrade-to "$newest")
    distro="Fedora 44"
    [ "$fmt" != apt ] || distro="Debian 13"
    label="$id ($fmt, $arch, $distro): $name $first$([ "$first" = "$newest" ] || echo " → $newest")"
    if ! cid="$(start_client "$img" "$sysd")"; then
      echo "  ✗ $label — the client could not start"
      failed=$((failed + 1))
      continue
    fi
    IDS+=("$cid")
    if out="$(docker exec "$cid" bash /usr/local/bin/pkgrepo-client-check.sh "${args[@]}" 2>&1)"; then
      echo "  ✓ $label: installed, checked, $([ "$first" = "$newest" ] || echo 'upgraded, ')removed"
      pass=$((pass + 1))
    else
      echo "  ✗ $label"
      printf '%s\n' "$out" | tail -6 | sed 's/^/      /'
      failed=$((failed + 1))
    fi
    docker rm -f "$cid" >/dev/null 2>&1
  done < <("$JQ" -r --arg r "$id" '[.packages[] | select(.repository == $r) | .name] | unique | .[]' "$inv")
done < <("$JQ" -c '.repositories[]' "$inv")
echo "client-rows: $pass passed, $failed failed, $skipped row(s) not exercised on this $(uname -m) host"
[ "$failed" -eq 0 ] && [ "$pass" -gt 0 ]
