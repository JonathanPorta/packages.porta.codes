#!/usr/bin/env bash
# fake-gh.sh — the few `gh` calls scripts/surface/admission-open-pr.sh makes,
# answered from a state directory FAKE_GH (tests/admission-open-pr.sh):
#
#   refs/<branch>             the commit SHA a branch points at (main included)
#   commits/<sha>.json        {"sha", "parents": [{"sha"}]}
#   compare/<a>...<b>.json    {"status", "files": [{"status", "filename"}]}
#   contents/<sha>.json       inventory/inventory.json at that commit: {"content", "sha"}
#   prs.json                  open PRs: [{number, headRefName, baseRefName, headRefOid, isCrossRepository}]
#   mutations.log             one line per write (ref create, commit, PR create)
#
# A missing object is a 404: exit 1. `--jq` is applied with jq.
set -uo pipefail
S="${FAKE_GH:?}"
nf() {
  echo "gh: Not Found (HTTP 404)" >&2
  exit 1
}
out() { if [ -n "$jq" ]; then jq -r "$jq" "$1"; elif [ "$silent" = 0 ]; then cat "$1"; fi; }
ref_sha() { [ -f "$S/refs/$1" ] && cat "$S/refs/$1"; }
jq="" silent=0 method=GET ep="" fields=()
cmd="$1 ${2:-}"
case "$cmd" in
  "api "*)
    shift
    while [ $# -gt 0 ]; do
      case "$1" in
        --jq)
          jq="$2"
          shift 2
          ;;
        --silent)
          silent=1
          shift
          ;;
        -X)
          method="$2"
          shift 2
          ;;
        -f)
          fields+=("$2")
          shift 2
          ;;
        *)
          ep="$1"
          shift
          ;;
      esac
    done
    field() { for f in "${fields[@]}"; do case "$f" in "$1="*) printf '%s' "${f#*=}" ;; esac done }
    ep="${ep#repos/*/*/}"
    case "$method $ep" in
      "GET git/ref/heads/"*)
        s="$(ref_sha "${ep#git/ref/heads/}")" || nf
        printf '{"object":{"sha":"%s"}}' "$s" >"$S/tmp.json"
        out "$S/tmp.json"
        ;;
      "GET commits/"*)
        [ -f "$S/commits/${ep#commits/}.json" ] || nf
        out "$S/commits/${ep#commits/}.json"
        ;;
      "GET compare/"*)
        c="${ep#compare/}"
        [ -f "$S/compare/$c.json" ] || nf
        out "$S/compare/$c.json"
        ;;
      "GET contents/inventory/inventory.json?ref="*)
        r="${ep#*ref=}"
        s="$(ref_sha "$r")" || s="$r"
        [ -f "$S/contents/$s.json" ] || nf
        out "$S/contents/$s.json"
        ;;
      "POST git/refs")
        b="$(field ref)"
        b="${b#refs/heads/}"
        [ ! -f "$S/refs/$b" ] || {
          echo "gh: Reference already exists (HTTP 422)" >&2
          exit 1
        }
        mkdir -p "$(dirname "$S/refs/$b")"
        field sha >"$S/refs/$b"
        echo "create-ref $b $(field sha)" >>"$S/mutations.log"
        ;;
      "PUT contents/inventory/inventory.json")
        b="$(field branch)"
        p="$(ref_sha "$b")" || nf
        n="$(printf '%s %s' "$p" "$(field content)" | sha1sum | cut -d' ' -f1)"
        jq -n --arg n "$n" --arg p "$p" '{sha: $n, parents: [{sha: $p}]}' >"$S/commits/$n.json"
        st=modified
        [ -f "$S/contents/$p.json" ] || st=added
        jq -n --arg st "$st" '{status: "ahead", files: [{status: $st, filename: "inventory/inventory.json"}]}' >"$S/compare/$p...$n.json"
        jq -n --arg c "$(field content)" --arg n "$n" '{content: $c, sha: ("blob-" + $n)}' >"$S/contents/$n.json"
        echo "$n" >"$S/refs/$b"
        echo "commit $b $n parent=$p old=$(field sha)" >>"$S/mutations.log"
        ;;
      *)
        echo "fake-gh: unexpected api call: $method $ep" >&2
        exit 2
        ;;
    esac
    ;;
  "pr list")
    shift 2
    while [ $# -gt 0 ]; do
      case "$1" in
        --head)
          h="$2"
          shift 2
          ;;
        --jq)
          jq="$2"
          shift 2
          ;;
        --repo | --state | --json) shift 2 ;;
        *) shift ;;
      esac
    done
    jq -r --arg h "$h" "[.[] | select(.headRefName == \$h)] | $jq" "$S/prs.json"
    ;;
  "pr create")
    echo "create-pr $*" >>"$S/mutations.log"
    echo "https://github.com/fake/pull/99"
    ;;
  *)
    echo "fake-gh: unexpected: $*" >&2
    exit 2
    ;;
esac
