#!/usr/bin/env bash
# s3-object-adapter.sh — object-store adapter for pkgrepo-publish.sh, backed by S3.
#
#   stat KEY                          → prints the object's recorded sha256; exit 3 if absent
#   etag KEY                          → prints the object's current ETag; exit 3 if absent
#   put KEY FILE TYPE CACHE SHA256 [create-only | if-match:ETAG]
#                                     → uploads with Content-Type, Cache-Control and
#                                       x-amz-meta-sha256 (read back by `stat`). With
#                                       create-only it sends If-None-Match: * and exits 4
#                                       if the key already exists — the form a bucket
#                                       policy can REQUIRE for immutable prefixes, as
#                                       docsort.io's surface-publication guards do.
#                                       With if-match:ETAG it sends If-Match and exits
#                                       4 unless the object is still that version
#   get-pointer KEY OUT               → writes the object to OUT, prints its ETag; exit 3 if absent
#   put-pointer KEY FILE ETAG|none    → CONDITIONAL write: If-Match ETAG, or If-None-Match *
#                                       when none; exit 4 when the precondition fails
#                                       prints the NEW ETag on success
#
# Bucket from PKGREPO_BUCKET. Credentials are the caller's (an OIDC role scoped
# to that bucket); this adapter reads no secret.
set -uo pipefail
B="${PKGREPO_BUCKET:?PKGREPO_BUCKET is required}"
AWS="${AWS_BIN:-aws}"
verb="${1:-}"
shift || true
case "$verb" in
  stat)
    out="$("$AWS" s3api head-object --bucket "$B" --key "$1" --output json 2>&1)" || {
      case "$out" in *"Not Found"* | *"404"* | *NoSuchKey*) exit 3 ;; esac
      printf 's3-adapter: head-object %s failed: %s\n' "$1" "$out" >&2
      exit 2
    }
    h="$(printf '%s' "$out" | jq -r '.Metadata.sha256 // empty')"
    [ -n "$h" ] || {
      printf 's3-adapter: %s has no recorded sha256\n' "$1" >&2
      exit 2
    }
    printf '%s\n' "$h"
    ;;
  etag)
    out="$("$AWS" s3api head-object --bucket "$B" --key "$1" --output json 2>&1)" || {
      case "$out" in *"Not Found"* | *"404"* | *NoSuchKey*) exit 3 ;; esac
      printf 's3-adapter: head-object %s failed: %s\n' "$1" "$out" >&2
      exit 2
    }
    printf '%s' "$out" | jq -r '.ETag // empty'
    ;;
  put)
    cond=()
    case "${6:-}" in
      "") ;;
      create-only) cond=(--if-none-match '*') ;;
      if-match:?*) cond=(--if-match "${6#if-match:}") ;;
      *)
        printf 's3-adapter: unknown put condition %s\n' "$6" >&2
        exit 2
        ;;
    esac
    out="$("$AWS" s3api put-object --bucket "$B" --key "$1" --body "$2" --content-type "$3" \
      --cache-control "$4" --metadata "sha256=$5" --checksum-algorithm SHA256 "${cond[@]}" --output json 2>&1)" || {
      case "$out" in *PreconditionFailed* | *"412"* | *ConditionalRequestConflict*) exit 4 ;; esac
      printf 's3-adapter: put %s failed: %s\n' "$1" "$out" >&2
      exit 2
    }
    ;;
  get-pointer)
    out="$("$AWS" s3api get-object --bucket "$B" --key "$1" "$2" --output json 2>&1)" || {
      case "$out" in *NoSuchKey* | *"Not Found"* | *"404"*) exit 3 ;; esac
      printf 's3-adapter: get-object %s failed: %s\n' "$1" "$out" >&2
      exit 2
    }
    printf '%s' "$out" | jq -r .ETag
    ;;
  put-pointer)
    if [ "$3" = none ]; then cond=(--if-none-match '*'); else cond=(--if-match "$3"); fi
    out="$("$AWS" s3api put-object --bucket "$B" --key "$1" --body "$2" --content-type application/json \
      --cache-control 'no-cache' "${cond[@]}" --output json 2>&1)" || {
      case "$out" in *PreconditionFailed* | *"412"* | *ConditionalRequestConflict*) exit 4 ;; esac
      printf 's3-adapter: conditional put %s failed: %s\n' "$1" "$out" >&2
      exit 2
    }
    printf '%s' "$out" | jq -r .ETag
    ;;
  *)
    printf 'usage: s3-object-adapter.sh stat|etag|put|get-pointer|put-pointer ...\n' >&2
    exit 2
    ;;
esac
