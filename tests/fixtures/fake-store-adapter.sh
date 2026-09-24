#!/usr/bin/env bash
# Vendored verbatim from JonathanPorta/blessed-cicd tests/fixtures/pkgrepo/fake-store-adapter.sh
# at 778ed09 (the release 0.5.0 candidate). Same verbs and exit codes as
# scripts/release/adapters/s3-object-adapter.sh.
# Directory-backed stand-in for adapters/s3-object-adapter.sh, same verbs and
# exit codes. FAKE_STORE is the store root. Injection for the resume and race
# controls:
#   FAKE_FAIL_PUT_AFTER=N    the (N+1)th put fails (exit 2) — an interrupted publish
#   FAKE_RACE_POINTER=FILE   before the first put-pointer, a DIFFERENT writer
#                            replaces the pointer with FILE — a concurrent activation
#   FAKE_RACE_OBJECT=KEY:FILE right before the put of KEY, another writer creates
#                            KEY from FILE — a concurrent upload of the same path
#   FAKE_LOG                 every verb is appended here
#   FAKE_FAIL_PUT_MATCH=GLOB the first put of a key matching GLOB fails (exit 2) —
#                            an interruption at a chosen step
#   FAKE_PAUSE=VERB:GLOB     the first time this process reaches VERB on a key
#                            matching GLOB, it creates $FAKE_STORE/.paused-$FAKE_TAG
#                            and waits for $FAKE_STORE/.resume-$FAKE_TAG — a barrier
#                            that lets two real publishers interleave deterministically
set -uo pipefail
S="${FAKE_STORE:?}"
mkdir -p "$S/o" "$S/m"
# Every verb is logged — a put only once it has COMPLETED, so an injected
# failure is not mistaken for an upload.
log() { [ -z "${FAKE_LOG:-}" ] || printf '%s\n' "$*" >>"$FAKE_LOG"; }
[ "${1:-}" = put ] || log "$@"
verb="${1:-}"
shift || true
if [ -n "${FAKE_PAUSE:-}" ] && [ "${FAKE_PAUSE%%:*}" = "$verb" ] && [ ! -e "$S/.paused-${FAKE_TAG:?}" ]; then
  # shellcheck disable=SC2254 # the glob is the point
  case "${1:-}" in
    ${FAKE_PAUSE#*:})
      touch "$S/.paused-$FAKE_TAG"
      i=0
      while [ ! -e "$S/.resume-$FAKE_TAG" ]; do
        i=$((i + 1))
        [ "$i" -lt 600 ] || exit 2
        sleep 0.1
      done
      ;;
  esac
fi
case "$verb" in
  stat)
    [ -f "$S/o/$1" ] || exit 3
    cat "$S/m/$1.sha256"
    ;;
  put)
    n="$(cat "$S/.puts" 2>/dev/null || echo 0)"
    if [ -n "${FAKE_FAIL_PUT_AFTER:-}" ] && [ "$n" -ge "$FAKE_FAIL_PUT_AFTER" ]; then exit 2; fi
    if [ -n "${FAKE_FAIL_PUT_MATCH:-}" ] && [ ! -e "$S/.failed-match" ]; then
      # shellcheck disable=SC2254 # the glob is the point
      case "$1" in ${FAKE_FAIL_PUT_MATCH})
        touch "$S/.failed-match"
        exit 2
        ;;
      esac
    fi
    echo $((n + 1)) >"$S/.puts"
    if [ -n "${FAKE_RACE_OBJECT:-}" ] && [ "${FAKE_RACE_OBJECT%%:*}" = "$1" ] && [ ! -e "$S/.raced-object" ]; then
      mkdir -p "$(dirname "$S/o/$1")" "$(dirname "$S/m/$1")"
      cp "${FAKE_RACE_OBJECT#*:}" "$S/o/$1"
      sha256sum "$S/o/$1" | cut -d' ' -f1 >"$S/m/$1.sha256"
      touch "$S/.raced-object"
    fi
    if [ "${6:-}" = create-only ] && [ -f "$S/o/$1" ]; then exit 4; fi
    # if-match: the version is content-derived, as an S3 single-part ETag is.
    case "${6:-}" in if-match:*)
      [ -f "$S/o/$1" ] || exit 4
      [ "$(sha256sum "$S/o/$1" | cut -d' ' -f1)" = "${6#if-match:}" ] || exit 4
      ;;
    esac
    mkdir -p "$(dirname "$S/o/$1")" "$(dirname "$S/m/$1")"
    cp "$2" "$S/o/$1"
    printf '%s\n' "$5" >"$S/m/$1.sha256"
    printf '%s\n' "$3" >"$S/m/$1.type"
    printf '%s\n' "$4" >"$S/m/$1.cache"
    log put "$@"
    ;;
  etag)
    [ -f "$S/o/$1" ] || exit 3
    sha256sum "$S/o/$1" | cut -d' ' -f1
    ;;
  get-pointer)
    [ -f "$S/o/$1" ] || exit 3
    cp "$S/o/$1" "$2"
    sha256sum "$S/o/$1" | cut -d' ' -f1
    ;;
  put-pointer)
    if [ -n "${FAKE_RACE_POINTER:-}" ] && [ ! -e "$S/.raced" ]; then
      mkdir -p "$(dirname "$S/o/$1")"
      cp "$FAKE_RACE_POINTER" "$S/o/$1"
      touch "$S/.raced"
    fi
    cur="none"
    [ -f "$S/o/$1" ] && cur="$(sha256sum "$S/o/$1" | cut -d' ' -f1)"
    [ "$cur" = "$3" ] || exit 4
    mkdir -p "$(dirname "$S/o/$1")"
    cp "$2" "$S/o/$1"
    sha256sum "$S/o/$1" | cut -d' ' -f1
    ;;
  *) exit 2 ;;
esac
