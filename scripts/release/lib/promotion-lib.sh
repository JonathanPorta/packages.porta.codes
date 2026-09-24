#!/usr/bin/env bash
# promotion-lib.sh — shared helpers for the deterministic promotion generator.
# Sourced, not executed. Requires: jq.
#
# FORWARD-ONLY ORDERING (Project B v1)
# ------------------------------------
# v1 supports canonical numeric MAJOR.MINOR.PATCH only — each component
# (0|[1-9][0-9]*). Prereleases are rejected as OPERATIONALLY unsupported even
# though the candidate schema accepts them: a prerelease has no defined promotion
# order here, and guessing one is how a downgrade slips through.
#
# Components are compared as DECIMAL STRINGS, digit by digit. Every tempting
# shortcut is wrong somewhere:
#   * shell integer arithmetic  -> overflows past u64, chokes on leading zeros
#   * jq numbers                -> IEEE-754 doubles silently lose precision
#   * lexical/string compare    -> "9" > "10"
#   * sort -V                   -> not POSIX, semantics vary by platform
# So 0.9.9 -> 0.10.0 and 9 -> 10 are handled by length-then-digits.

# prom_version_is_canonical VERSION -> 0 when MAJOR.MINOR.PATCH with no extras
prom_version_is_canonical() {
  printf '%s' "${1:-}" | grep -Eq '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'
}

# prom_num_cmp A B -> prints -1 | 0 | 1 for two decimal component strings.
# No arithmetic: the longer digit string wins; equal lengths compare lexically,
# which is correct once lengths match and leading zeros are already excluded.
prom_num_cmp() {
  local a="$1" b="$2"
  if [ "${#a}" -gt "${#b}" ]; then
    printf '1'
    return 0
  fi
  if [ "${#a}" -lt "${#b}" ]; then
    printf -- '-1'
    return 0
  fi
  if [ "$a" = "$b" ]; then
    printf '0'
    return 0
  fi
  if [ "$a" \> "$b" ]; then printf '1'; else printf -- '-1'; fi
}

# prom_version_cmp A B -> prints -1 | 0 | 1. Both MUST already be canonical.
prom_version_cmp() {
  local a="$1" b="$2" i ac bc r
  for i in 1 2 3; do
    ac="$(printf '%s' "$a" | cut -d. -f"$i")"
    bc="$(printf '%s' "$b" | cut -d. -f"$i")"
    r="$(prom_num_cmp "$ac" "$bc")"
    [ "$r" = "0" ] || {
      printf '%s' "$r"
      return 0
    }
  done
  printf '0'
}
