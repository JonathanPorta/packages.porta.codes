#!/usr/bin/env bash
# Shared parser for `.bws-secrets-list`, sourced by both
# `bws-bootstrap.sh` (executed) and `load-bws-secrets.sh` (sourced).
#
# Function `_bws_parse_secrets_list FILE` reads the given file and
# populates five parallel arrays in the caller's scope:
#
#   _BWS_PARSED_KEYS      ('RELEASE_TOKEN' 'OPENAI_API_KEY' ...)
#   _BWS_PARSED_OPTIONAL  ('false' 'true' ...)         # one per key
#   _BWS_PARSED_TYPE      ('github_pat' 'openai_key' '' ...)
#   _BWS_PARSED_SHARED    ('false' 'true' ...)          # one per key
#   _BWS_PARSED_SHARED_PROJECT ('' 'proofglass-consumers' ...)
#   _BWS_PARSED_REQ       ('owner=X;repos=Y;perms=Z;expires=W;consumers=V' ...)
#                          # plus optional approval=<docs/DECISIONS.md anchor>,
#                          # REQUIRED when repos= names a wildcard scope.
#   _BWS_PARSED_DELIVER   ('' 'dependabot@OWNER/REPO' ...)
#                          # one per key; '' = consumed through the generated
#                          # Actions loader (the default). A value names a
#                          # MANAGED DELIVERY: Bitwarden stays the authoritative
#                          # store and bootstrap.sh keeps a copy synchronised into
#                          # the named destination. Only `dependabot@OWNER/REPO`
#                          # (that repository's Dependabot secrets namespace,
#                          # same secret name as the key) is supported.
#
# The _REQ fields carry the MINTING REQUIREMENTS for a credential — who owns it,
# which repositories it may touch, the least permission it needs, how long it may
# live, and what consumes it. They exist because a rotation happens long after
# the decision was made: without them the scope lives in whatever prose someone
# wrote once, and the next person to rotate the token has to guess or re-derive
# it. Declaring them here makes the operator instructions the repository's own.
#                          # one per key; '' = the default _shared-ci project,
#                          # a name/uuid = a specific shared project (shared:NAME)
#
# Returns 0 on success. On error, prints a single ERROR line to stderr
# and returns 1 — `return 1` rather than `exit 1` so both executed
# scripts (with their own die/set -e) and sourced scripts (which would
# kill the user's shell on `exit`) can use the same helper.
#
# Format accepted (per CENTRALIZED-SECRETS.md):
#   KEY[?] [shared] [type:VALUE]
#
#   - Lines starting with `#` are comments; blank lines ignored.
#   - KEY must match `^[A-Z][A-Z0-9_]*$`.
#   - Trailing `?` on the key marks it as optional.
#   - Fields after the key are whitespace-separated, order-independent:
#       * `shared`     — the secret lives in the shared `_shared-ci` BWS
#                        project, not this project. bootstrap.sh skips
#                        creating it; load.sh merges it from the shared
#                        project. (See docs/shared-secrets.md.)
#       * `shared:NAME`— like `shared`, but the secret lives in the named
#                        shared project NAME (a project name or uuid), not
#                        `_shared-ci`. Enables least-privilege scoped sharing
#                        (a token visible to N specific repos). NAME matches
#                        `^[A-Za-z0-9._-]+$`. Bare `shared` == the default
#                        `_shared-ci`.
#       * `type:VALUE` — selects helptext class; VALUE matches
#                        `^[a-z][a-z0-9_]*$`.
#       * `deliver:dependabot@OWNER/REPO`
#                      — managed delivery of a copy into OWNER/REPO's
#                        Dependabot secrets namespace under the same key.
#                        Dependabot cannot read Bitwarden, so the GitHub
#                        secret is a delivery COPY that bootstrap.sh creates,
#                        verifies and re-synchronises; the Bitwarden secret
#                        remains the source of truth. bootstrap.sh refuses a
#                        destination other than the repository it runs in.
#                        A delivered key is NOT loaded by load.sh and gets no
#                        line in the generated Actions loader. At most one
#                        `deliver:` per key; the only supported target is
#                        `dependabot`.
#     Any other field is rejected.
#
# Bash 3.2 compatible (macOS /bin/bash). No associative arrays; no
# `${var,,}`.

_bws_parse_secrets_list() {
  local file="$1"

  _BWS_PARSED_KEYS=()
  _BWS_PARSED_OPTIONAL=()
  _BWS_PARSED_TYPE=()
  _BWS_PARSED_SHARED=()
  _BWS_PARSED_SHARED_PROJECT=()
  _BWS_PARSED_REQ=()
  _BWS_PARSED_DELIVER=()

  if [[ ! -f "$file" ]]; then
    printf 'ERROR: %s: file not found\n' "$file" >&2
    return 1
  fi

  local raw line key_raw rest key type shared shared_project req deliver field fields_rest _req_repos _deliver_target _deliver_repo
  while IFS= read -r raw || [[ -n "$raw" ]]; do
    line="${raw%%#*}"
    # Trim leading + trailing whitespace (Bash 3.2 — no PCRE).
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -z "$line" ]] && continue

    # First whitespace-separated field = key (with optional trailing `?`).
    # Anything after the first whitespace = metadata fields (shared, type:VALUE).
    if [[ "$line" == *[[:space:]]* ]]; then
      key_raw="${line%%[[:space:]]*}"
      rest="${line#*[[:space:]]}"
      rest="${rest#"${rest%%[![:space:]]*}"}"
    else
      key_raw="$line"
      rest=""
    fi

    if [[ "$key_raw" == *"?" ]]; then
      key="${key_raw%\?}"
      _BWS_PARSED_OPTIONAL+=("true")
    else
      key="$key_raw"
      _BWS_PARSED_OPTIONAL+=("false")
    fi

    if [[ ! "$key" =~ ^[A-Z][A-Z0-9_]*$ ]]; then
      printf 'ERROR: %s: invalid key %q (expected uppercase env-var convention, optional trailing ?)\n' \
        "$file" "$key_raw" >&2
      return 1
    fi

    # Metadata fields after the key are whitespace-separated and order-
    # independent. Tokenize with parameter expansion rather than
    # `for field in $rest` — zsh does NOT word-split unquoted expansions, so
    # under zsh `$rest` would arrive as a single token and every multi-field
    # line (e.g. `shared type:x`) would be wrongly rejected. This loop behaves
    # identically under bash and zsh (load.sh is sourced into the user's shell).
    type=""
    shared="false"
    shared_project=""
    req=""
    deliver=""
    fields_rest="$rest"
    while [[ -n "$fields_rest" ]]; do
      field="${fields_rest%%[[:space:]]*}"
      if [[ "$fields_rest" == *[[:space:]]* ]]; then
        fields_rest="${fields_rest#*[[:space:]]}"
        fields_rest="${fields_rest#"${fields_rest%%[![:space:]]*}"}"
      else
        fields_rest=""
      fi
      [[ -n "$field" ]] || continue
      case "$field" in
        shared)
          shared="true"
          ;;
        shared:*)
          shared="true"
          shared_project="${field#shared:}"
          if [[ ! "$shared_project" =~ ^[A-Za-z0-9._-]+$ ]]; then
            printf 'ERROR: %s: invalid shared project %q for key %s (expected a project name or uuid)\n' \
              "$file" "$shared_project" "$key" >&2
            return 1
          fi
          ;;
        type:*)
          type="${field#type:}"
          if [[ ! "$type" =~ ^[a-z][a-z0-9_]*$ ]]; then
            printf 'ERROR: %s: invalid type %q for key %s (expected lowercase snake_case)\n' \
              "$file" "$type" "$key" >&2
            return 1
          fi
          ;;
        deliver:*)
          # Managed delivery. The value is TARGET@OWNER/REPO; the destination is
          # part of the declaration so that a copy can never land somewhere the
          # repository did not name — bootstrap.sh additionally refuses any
          # OWNER/REPO other than the repository it is running in.
          if [[ -n "$deliver" ]]; then
            printf 'ERROR: %s: duplicate deliver for key %s (a key has at most one managed delivery)\n' \
              "$file" "$key" >&2
            return 1
          fi
          deliver="${field#deliver:}"
          _deliver_target="${deliver%%@*}"
          _deliver_repo="${deliver#*@}"
          if [[ "$deliver" != *@* || "$_deliver_target" != "dependabot" ]]; then
            printf 'ERROR: %s: unsupported deliver target %q for key %s (supported: deliver:dependabot@OWNER/REPO)\n' \
              "$file" "$deliver" "$key" >&2
            return 1
          fi
          if [[ ! "$_deliver_repo" =~ ^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9._-]+$ ]]; then
            printf 'ERROR: %s: invalid deliver destination %q for key %s (expected OWNER/REPO)\n' \
              "$file" "$_deliver_repo" "$key" >&2
            return 1
          fi
          ;;
        owner:* | repos:* | perms:* | expires:* | consumers:* | approval:*)
          # Minting requirements. Values may not contain whitespace — a field is
          # whitespace-delimited — so lists use commas.
          if [[ "${field#*:}" != *[!\ ]* ]]; then
            printf 'ERROR: %s: empty %s for key %s\n' \
              "$file" "${field%%:*}" "$key" >&2
            return 1
          fi
          # An authority field may be declared ONCE. Two `repos:` on one line
          # used to be accepted and rendered as two simultaneously authoritative
          # scopes, which is not a scope at all — the operator picks whichever
          # they read first. Contradictory authority is worse than none.
          if [[ ";$req;" == *";${field%%:*}="* ]]; then
            printf 'ERROR: %s: duplicate %s for key %s (an authority field may be declared once)\n' \
              "$file" "${field%%:*}" "$key" >&2
            return 1
          fi
          req+="${req:+;}${field%%:*}=${field#*:}"
          ;;
        *)
          printf 'ERROR: %s: unknown field after key %s: %q (supported: shared, type:VALUE, deliver:dependabot@OWNER/REPO, owner:, repos:, perms:, expires:, consumers:, approval:)\n' \
            "$file" "$key" "$field" >&2
          return 1
          ;;
      esac
    done

    # A wildcard repository scope is not selectable in GitHub's token UI: the
    # operator has to choose "All repositories", which silently includes every
    # repository the owner creates from now on. That is a real widening, so it
    # may only be declared alongside an `approval:` anchor naming the recorded
    # decision that accepted it. Without the anchor the declaration promises a
    # least-privilege scope the operator cannot actually mint.
    if [[ ";$req;" == *";repos="* ]]; then
      _req_repos="${req#*repos=}"
      _req_repos="${_req_repos%%;*}"
      if [[ "$_req_repos" == *'*'* && ";$req;" != *";approval="* ]]; then
        printf 'ERROR: %s: key %s declares wildcard repository scope %q with no approval: anchor. GitHub has no wildcard selection — this can only be minted as "All repositories". Declare the exact repositories, or add approval:<recorded decision>.\n' \
          "$file" "$key" "$_req_repos" >&2
        return 1
      fi
    fi

    # A delivered key is a per-repository credential in this repository's own
    # project; a shared key lives elsewhere and has no id here to deliver.
    if [[ -n "$deliver" && "$shared" == "true" ]]; then
      printf 'ERROR: %s: key %s is both shared and deliver: — a managed delivery must be a per-repository secret\n' \
        "$file" "$key" >&2
      return 1
    fi

    _BWS_PARSED_KEYS+=("$key")
    _BWS_PARSED_TYPE+=("$type")
    _BWS_PARSED_SHARED+=("$shared")
    _BWS_PARSED_SHARED_PROJECT+=("$shared_project")
    _BWS_PARSED_REQ+=("$req")
    _BWS_PARSED_DELIVER+=("$deliver")
  done <"$file"

  if [[ ${#_BWS_PARSED_KEYS[@]} -eq 0 ]]; then
    printf 'ERROR: %s: empty after stripping comments / blank lines\n' "$file" >&2
    return 1
  fi
}
