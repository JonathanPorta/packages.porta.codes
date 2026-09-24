#!/usr/bin/env bash
# sm-action-run.sh — fetch, VERIFY, and execute the bitwarden/sm-action native
# binary. Replaces `uses: bitwarden/sm-action@<sha>` in the blessed loader.
#
# WHAT THIS FIXES
#
# sm-action v3's index.js is a ~6KB downloader: it fetches a release asset,
# chmod 0755's it, and execSync's it — with no digest check and no signature. So
# a commit pin on the action pins the downloader while the executed bytes stay
# unpinned and mutable. It also honours SM_ACTION_VERSION from the environment
# (any earlier step can redirect the download) and silently falls back to
# `cargo build` when the download fails.
#
# This script closes all three:
#
#   * the version comes from the committed pins file, never the environment;
#   * the downloaded bytes must match a committed sha256 or we DIE;
#   * there is no build-from-source fallback, ever. A failure is a failure.
#
# The secret VALUES are never printed, and the binary itself does the masking
# and GITHUB_ENV export exactly as before, so behaviour for callers is unchanged.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The pins file is resolved BESIDE this script, never from the environment.
# An override here would reintroduce exactly the class removed by the
# `unset SM_ACTION_VERSION` below: the pins file carries both the VERSION and
# the accepted digests, so an earlier step could swap the whole trust anchor
# and silently redirect this fetch to another upstream release. Tests copy
# this runner next to a fixture pins file instead (see tests/).
PINS="$HERE/sm-action.pins"
REPO="bitwarden/sm-action"

die() {
  echo "::error::sm-action-run: $*" >&2
  exit 1
}
log() { echo "sm-action-run: $*"; }

[ -f "$PINS" ] || die "pins file not found: $PINS"

# ── the version is COMMITTED, never inherited ────────────────────────────────
# sm-action reads SM_ACTION_VERSION from the environment and interpolates it
# straight into the download URL. Unsetting it means a compromised or careless
# earlier step cannot redirect which binary we fetch — and cannot redirect the
# child process either, since it inherits this environment.
unset SM_ACTION_VERSION

# Exactly one declaration. `head -1` would silently prefer the first of several,
# so a second VERSION= line — appended by a bad merge, or deliberately — could sit
# in the file unnoticed while a reviewer read the other one.
_vcount="$(grep -c '^VERSION=' "$PINS" || true)"
[ "${_vcount:-0}" -le 1 ] || die "pins file declares VERSION $_vcount times — exactly one is required"

# No `| head -1`: the count check above already guarantees at most one
# declaration, so the pipe bought nothing. Dropping it is tidiness, not a fix —
# see the note on the PROVEN_TARGETS match below for why the SIGPIPE hazard these
# rewrites guard against cannot actually fire on single-line values.
VERSION="$(sed -n 's/^VERSION=//p' "$PINS")"
[ -n "$VERSION" ] || die "pins file declares no VERSION"

# ── the version is INTERPOLATED INTO A URL, so validate its shape FIRST ───────
# This runs BEFORE any network access. VERSION comes from a committed,
# manifest-verified file, so this is defence in depth rather than the primary
# control — but the primary control (the digest) only governs what EXECUTES, not
# where the request GOES. A value carrying `/`, `?`, `#`, or whitespace could
# retarget the fetch to another path, host-relative location, or query while the
# digest check stayed perfectly happy about refusing whatever came back.
#
# Bare three-part semver only: no `v` prefix (the URL adds its own), no
# prerelease or build suffix, no whitespace. If upstream ever ships `3.1.0-rc.1`,
# widening this is a deliberate, reviewed edit — not something a pins file may
# decide on its own.
case "$VERSION" in
  *[!0-9.]* | *..* | .* | *. | '')
    die "pins VERSION '$VERSION' is not a bare MAJOR.MINOR.PATCH — refusing before any network access"
    ;;
esac
grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$' <<<"$VERSION" ||
  die "pins VERSION '$VERSION' does not match ^[0-9]+\\.[0-9]+\\.[0-9]+\$ — refusing before any network access"

# ── target triple ────────────────────────────────────────────────────────────
case "$(uname -s)" in
  Darwin) os=apple-darwin ;;
  Linux) os=unknown-linux-gnu ;;
  MINGW* | MSYS* | CYGWIN*) os=pc-windows-msvc ;;
  *) die "unsupported OS: $(uname -s)" ;;
esac
case "$(uname -m)" in
  arm64 | aarch64) arch=aarch64 ;;
  x86_64 | amd64) arch=x86_64 ;;
  *) die "unsupported architecture: $(uname -m)" ;;
esac
triple="${arch}-${os}"
[ "$os" = pc-windows-msvc ] && triple="${triple}.exe"

# UNPROVEN targets are refused, not merely labelled. The matrix is a support
# statement; without this it had no effect on behaviour and the runtime would
# happily execute a combination whose shell/platform assumptions CI has never
# exercised.
#
# ABSENT OR EMPTY MEANS NOTHING IS PROVEN — this gate must never disable itself.
# The previous `[ -n "$proven" ] &&` guard meant a missing or blank
# PROVEN_TARGETS= line silently turned the whole check off, so the one edit most
# likely to happen by accident (dropping the line in a merge, or blanking it
# while bumping the pins) was also the edit that removed the protection. A safety
# gate whose input going missing switches it off is worse than no gate, because
# the support matrix still *reads* as if it were enforced.
# EXACTLY ONE DECLARATION. `head -1` was first-wins, which is not a safe way to
# read a security gate: two disagreeing declarations would silently resolve to
# whichever came first, so a stale line still naming this target could override a
# later one that deliberately removed it — and the file would still *read* as if
# the target had been dropped. Ambiguity is not something to resolve by position;
# it is a malformed trust anchor, and malformed means refuse.
#
# This is deliberately NOT overridable. SM_ACTION_ALLOW_UNPROVEN says "I accept
# this platform is untested"; it does not say "I accept that the pins file
# contradicts itself and you may pick a reading". A duplicate declaration is a
# defect in the anchor, so it fails ahead of the override.
_pcount="$(grep -c '^PROVEN_TARGETS=' "$PINS" || true)"
case "${_pcount:-0}" in
  0)
    die "pins file declares no PROVEN_TARGETS, so NO target is proven — refusing before any network access.
      Add a PROVEN_TARGETS= line listing the targets a CI canary actually exercises."
    ;;
  1) : ;;
  *)
    die "pins file declares PROVEN_TARGETS ${_pcount} times — exactly one is required.
      Two declarations can disagree, and resolving that by position would let a
      stale line re-prove a target a later line removed. Not overridable by
      SM_ACTION_ALLOW_UNPROVEN: this is a malformed trust anchor, not an
      untested platform."
    ;;
esac

proven="$(sed -n 's/^PROVEN_TARGETS=//p' "$PINS")"

# NORMALISE AND MATCH WITHOUT A PIPELINE.
#
# This was `printf '%s' "$proven" | tr … | sed …` followed by
# `printf ' %s ' "$proven" | grep -q " $triple "`.
#
# BE PRECISE ABOUT WHY THAT WAS REPLACED, because 1.6.1's notes were not. The
# hazard in the abstract is real: `grep -q` exits on its first match, the producer
# can take SIGPIPE (141), `set -o pipefail` surfaces 141 as the pipeline's status,
# the `elif` evaluates FALSE, and a target that IS proven gets refused as
# UNPROVEN. But it CANNOT fire here, and that was verified by measurement rather
# than argued from the shape of the code:
#
#   single-line input, ~1.2 MB, match in the first token   → status 0
#   the same bytes as MULTIPLE lines, match on line 1      → status 141
#   the same bytes as MULTIPLE lines, match on the last    → status 0
#
# `grep -q` cannot exit part-way through a line — it must read a whole record
# before it can evaluate the pattern against it. PROVEN_TARGETS and VERSION are
# single-line by construction (the exactly-one-declaration checks above enforce
# that), so the reader never goes away early and the producer is never stranded.
# Restoring the old pipeline under a deliberate mutation produced ZERO spurious
# refusals at 23 KB, 47 KB, 94 KB and 188 KB.
#
# So this rewrite is DEFENSIVE HARDENING, not a fix for an exploitable production
# race. It is still worth keeping: no fork, no pipe, no signal, exact membership
# expressed directly, and it stays correct if the pins format ever grows
# multi-record values — which is precisely when the hazard would become live.
# Both constructs are bash 2/3.2 features, so macOS behaves the same as Linux.
#
# The SIGPIPE defect in the TEST HARNESS was genuine and is fixed separately:
# captured runner output is multi-line, so `printf … | grep -q` over it hits the
# second row of the table above — and did, on a hosted ARM runner.
proven="${proven//$'\t'/ }" # tabs are whitespace here too
proven="${proven//$'\n'/ }"
while [[ "$proven" == *"  "* ]]; do
  proven="${proven//  / }" # collapse runs of spaces
done
proven="${proven# }"
proven="${proven% }"

# ABSENT OR EMPTY MEANS NOTHING IS PROVEN — this gate must never disable itself.
# The zero-declaration case died above; an empty single declaration lands here and
# is still treated as "nothing proven", overridable only by the explicit flag.
if [ -z "$proven" ]; then
  unproven_reason="PROVEN_TARGETS is declared but empty, so NO target is proven"
elif [[ " $proven " == *" ${triple%.exe} "* ]]; then
  unproven_reason=""
else
  unproven_reason="target '$triple' is pinned but UNPROVEN — no CI canary exercises it.
      Proven: $proven"
fi

if [ -n "$unproven_reason" ]; then
  if [ "${SM_ACTION_ALLOW_UNPROVEN:-0}" = 1 ]; then
    # Loud, on stderr, and naming the reason — an override that scrolls past
    # silently in a log is indistinguishable from the gate not existing.
    echo "::warning title=sm-action-run: UNPROVEN target::${unproven_reason%%$'\n'*} — proceeding ONLY because SM_ACTION_ALLOW_UNPROVEN=1" >&2
    log "WARNING: proceeding on an UNPROVEN target because SM_ACTION_ALLOW_UNPROVEN=1"
  else
    die "$unproven_reason
      Set SM_ACTION_ALLOW_UNPROVEN=1 to override, accepting that this platform's
      download/execute path has never been tested."
  fi
fi

# DUPLICATE ROWS FAIL CLOSED. `| head -1` was first-wins: two rows for one
# triple resolved by position, so a stale digest could silently outrank the
# corrected one while the file read as though it had been fixed. Same defect the
# PROVEN_TARGETS finding closed, one lookup further down. Ambiguity in a trust
# anchor is a malformed file, not something to resolve by position.
rows="$(awk -v t="$triple" '$1 == "sha256" && $2 == t {print $3}' "$PINS")"
count="$(grep -c . <<<"$rows" || true)"
[ "${count:-0}" -le 1 ] ||
  die "pins file declares $count rows for target '$triple' — ambiguous digest, refusing.
      Remove the duplicate; first-match-wins would let a stale digest outrank the correct one."
want="$rows"
[ -n "$want" ] || die "no pinned digest for target '$triple' in $PINS — refusing to run an unverified binary"

# ── download ─────────────────────────────────────────────────────────────────
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT INT TERM HUP
bin="$work/sm-action"
url="https://github.com/${REPO}/releases/download/v${VERSION}/sm-action-${triple}"

log "target=$triple version=$VERSION"
log "fetching $url"
# REDIRECTS. GitHub release downloads redirect to objects.githubusercontent.com,
# so redirects must be followed — but on explicit terms:
#   --proto '=https'        the initial request is HTTPS only;
#   --proto-redir '=https'  and EVERY redirect hop stays HTTPS. Without this,
#                           curl will happily follow a 302 to plain http://.
#   --max-redirs 5          bounded, so a redirect loop cannot hang the job.
# No final-host allowlist is enforced. RESIDUAL RISK, accepted deliberately: a
# redirect can send the REQUEST to an arbitrary HTTPS host, which leaks the fact
# and timing of the fetch, and lets that host serve arbitrary bytes. It cannot
# make us EXECUTE those bytes — the digest check below is what stops that, and it
# is the control we rely on. Host-pinning was rejected because GitHub's asset CDN
# hostnames are not contractual and pinning them would break on their next change,
# trading a real availability failure for a marginal privacy gain.
curl --fail --silent --show-error --location \
  --proto '=https' --proto-redir '=https' --max-redirs 5 --tlsv1.2 \
  --max-time 120 --output "$bin" "$url" ||
  die "download failed for $triple. NOT falling back to a source build — an unverifiable binary must not run."

# ── verify BEFORE it is ever executable ──────────────────────────────────────
if command -v sha256sum >/dev/null 2>&1; then
  got="$(sha256sum "$bin" | cut -d' ' -f1)"
else
  got="$(shasum -a 256 "$bin" | cut -d' ' -f1)"
fi

if [ "$got" != "$want" ]; then
  # Do not chmod, do not execute, do not "retry". A release asset can be
  # replaced under the same tag, so a mismatch is exactly the case this exists
  # to catch.
  die "DIGEST MISMATCH for $triple
        expected $want
        got      $got
      The published asset does not match the committed pin. Refusing to execute."
fi
log "digest verified: $got"

chmod 0755 "$bin" || die "could not make the verified binary executable"

# ── materialize the upstream action's INPUT DEFAULTS ────────────────────────
#
# This script REPLACES `uses: bitwarden/sm-action@...`, so it inherits that
# action's compatibility contract — including the defaults its action.yml
# declares. GitHub materializes those into INPUT_* only for `uses:` steps; a
# direct invocation gets none of them.
#
# That is not cosmetic. `set_env` defaults to "true" upstream, and without it the
# binary fetched the secret, verified fine, and exported NOTHING — the canary
# failed with "no secret was exported", and every consumer of this loader would
# have silently received no secrets at all.
#
# Fixed HERE rather than at each caller: the runner is the boundary that replaced
# `uses:`, so it owns reproducing what `uses:` provided. Three call sites each
# remembering to set INPUT_SET_ENV is the same bug waiting for a fourth caller.
#
# `${VAR=default}` assigns only when VAR is UNSET, so an explicit
# INPUT_SET_ENV=false from a caller is preserved. (`:=` would also fire on empty,
# clobbering a deliberate empty override.)
#
# Source of truth: bitwarden/sm-action action.yml at the pinned SOURCE_COMMIT.
: "${INPUT_BASE_URL=}"
: "${INPUT_IDENTITY_URL=}"
: "${INPUT_API_URL=}"
: "${INPUT_SET_ENV=true}"
export INPUT_BASE_URL INPUT_IDENTITY_URL INPUT_API_URL INPUT_SET_ENV

# ── execute ──────────────────────────────────────────────────────────────────
# The binary reads INPUT_* from the environment (GitHub Actions convention) and
# writes masked values to GITHUB_ENV itself, so the caller contract is unchanged.
#
# NOT `exec`: exec REPLACES this shell, so the EXIT trap never runs and the
# downloaded binary is left behind in $TMPDIR on every invocation. Run it as a
# child, propagate its exit status, and let the trap clean up.
"$bin"
rc=$?
exit "$rc"
