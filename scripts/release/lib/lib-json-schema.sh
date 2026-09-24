#!/usr/bin/env bash
# lib-json-schema.sh — generic Draft 2020-12 JSON Schema subset validator.
# Sourced, not executed. Requires: jq.
#
# Covers the keywords used by Blessed-CICD reference schemas:
#   type, const, enum, pattern, minLength, maxLength, minimum, maximum,
#   minItems, maxItems, uniqueItems, required, minProperties,
#   additionalProperties (both `false` and a schema), propertyNames, properties,
#   items, $ref → #/$defs/*, allOf, anyOf, oneOf, not, if/then/else,
#   format: date-time (RFC 3339, incl. calendar + leap-second rules) and
#   uri (RFC 3986, incl. percent-escapes and a single fragment delimiter)
#
# FAILS CLOSED on anything else, via a SCHEMA-SUPPORT PREFLIGHT that runs before
# any instance validation. The silent direction is the dangerous one: a schema
# author would otherwise get a clean result while their constraint sat inert.
#
# The preflight is DATA-INDEPENDENT — it walks the schema document itself, so a
# construct is caught whether or not any document happens to reach it. It visits
# only real schema-bearing positions: $defs.*, properties.*, a schema-valued
# additionalProperties, propertyNames, an object-valued items, allOf/anyOf/oneOf
# elements, and not/if/then/else.
#
# It does NOT dereference $ref. Walking every $defs entry covers every reference
# target anyway, and staying on the literal document tree makes the walk
# inherently cycle-safe — a self-recursive schema cannot hang it.
#
# It rejects: unsupported keywords, constraints sitting alongside a $ref (which
# resolution silently drops, since a $ref REPLACES the schema), unsupported
# `type` values, unsupported `format` values, and boolean schemas (`true`/`false`
# as a schema) which this subset does not implement. Annotations ($schema, $id,
# title, description, $comment, default, examples, deprecated) carry no
# constraint and are allowed.
#
# Runtime $ref resolution behavior is unchanged: still #/$defs/* only, no remote
# refs, no general JSON Pointer. `maxProperties` stays deliberately unimplemented
# — it is the negative sentinel these controls are proven against.
#
# Empty stdout means valid. One violation message per line otherwise. A jq
# failure prints a violation and returns non-zero, so a caller testing for empty
# output can never read a crashed validator as "valid".

# json_schema_validate_file DOC_JSON_FILE SCHEMA_JSON_FILE
json_schema_validate_file() {
  local doc="$1" schema="$2" pre out rc
  pre="$(json_schema_preflight "$schema")" || {
    printf '%s\n' "$pre"
    return 1
  }
  if [ -n "$pre" ]; then
    printf '%s\n' "$pre"
    return 1
  fi
  out="$(jq -r --slurpfile schema "$schema" "$(json_schema_jq_program)" "$doc")"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    printf 'schema: validator failed (jq exit %s) — treating as INVALID\n' "$rc"
    return 1
  fi
  [ -n "$out" ] && printf '%s\n' "$out"
  [ -z "$out" ]
}

# json_schema_validate_json DOC_JSON_STRING SCHEMA_JSON_FILE
# Always uses jq -n so an empty/piped stdin cannot hang or suppress evaluation.
json_schema_validate_json() {
  local doc_json="$1" schema="$2" pre out rc
  pre="$(json_schema_preflight "$schema")" || {
    printf '%s\n' "$pre"
    return 1
  }
  if [ -n "$pre" ]; then
    printf '%s\n' "$pre"
    return 1
  fi
  out="$(jq -nr --slurpfile schema "$schema" --argjson doc "$doc_json" \
    '$doc | '"$(json_schema_jq_program)")"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    printf 'schema: validator failed (jq exit %s) — treating as INVALID\n' "$rc"
    return 1
  fi
  [ -n "$out" ] && printf '%s\n' "$out"
  [ -z "$out" ]
}

# json_schema_preflight SCHEMA_JSON_FILE
# Data-independent support check over the schema document. Empty stdout == every
# construct in the schema is one this validator actually enforces.
json_schema_preflight() {
  local schema="$1" out rc
  out="$(jq -r "$(json_schema_preflight_jq_program)" "$schema")"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    printf 'schema: preflight failed (jq exit %s) — treating as INVALID\n' "$rc"
    return 1
  fi
  [ -n "$out" ] && printf '%s\n' "$out"
  [ -z "$out" ]
}

# Emit the preflight jq program (operates on the schema document).
json_schema_preflight_jq_program() {
  cat <<'JQ'
( [ "type","const","enum","pattern","minLength","maxLength","minimum","maximum",
    "minItems","maxItems","uniqueItems","required","minProperties",
    "additionalProperties","propertyNames","properties","items","$ref",
    "allOf","anyOf","oneOf","not","if","then","else","format",
    "$defs","$schema","$id","title","description","$comment","default",
    "examples","deprecated" ] ) as $known
# Allowed beside a $ref: annotations carry no constraint, and $defs/$schema/$id
# are document containers that resolution preserves ($defs is looked up on the
# ROOT). Anything else beside a $ref is a constraint that resolution drops.
| ( [ "description","title","$comment","default","examples","deprecated",
      "$defs","$schema","$id" ] ) as $annotations
| ( [ "object","array","string","integer","number","boolean","null" ] ) as $types
| ( [ "date-time", "uri" ] ) as $formats
# Walk ONLY real schema-bearing positions. No $ref dereference: every reference
# target is a $defs entry, and every $defs entry is walked, so targets are
# covered without following edges — which is what makes this cycle-safe.
| . as $rootschema
| def walk($s; $p):
    if ($s|type) == "boolean" then
      "schema:\($p): boolean schema (\($s)) is not supported by this validator"
    elif ($s|type) != "object" then
      "schema:\($p): schema must be an object, got \($s|type)"
    else
      ( ($s|keys[]) as $k
        | select(($known | index($k)) == null)
        | "schema:\($p): unsupported schema keyword '\($k)' (validator would ignore it)" ),
      ( if ($s|has("$ref")) then
          ($s|keys[]) as $k
          | select($k != "$ref" and (($annotations | index($k)) == null))
          | "schema:\($p): '\($k)' alongside $ref is ignored by this validator"
        else empty end ),
      ( if ($s|has("type")) then
          ( if ($s.type|type) == "array" then $s.type[] else $s.type end ) as $t
          | select(($t|type) != "string" or ($types | index($t)) == null)
          | "schema:\($p): unsupported type \($t|tojson)"
        else empty end ),
      ( if ($s|has("format")) then
          $s.format as $f
          | select(($f|type) != "string" or ($formats | index($f)) == null)
          | "schema:\($p): unsupported format \($f|tojson) (validator would ignore it)"
        else empty end ),
      # A keyword whose VALUE is the wrong shape is silently skipped at runtime
      # (e.g. `uniqueItems: "yes"` never equals true), so the constraint is inert
      # exactly like an unknown keyword. Check the shape of everything accepted.
      ( ( "minLength","maxLength","minItems","maxItems","minProperties" ) as $k
        | select($s|has($k))
        | select((($s[$k]|type) != "number") or (($s[$k]|floor) != $s[$k]) or ($s[$k] < 0))
        | "schema:\($p): '\($k)' must be a non-negative integer, got \($s[$k]|tojson)" ),
      ( ( "minimum","maximum" ) as $k
        | select($s|has($k))
        | select(($s[$k]|type) != "number")
        | "schema:\($p): '\($k)' must be a number, got \($s[$k]|tojson)" ),
      ( if ($s|has("uniqueItems")) and (($s.uniqueItems|type) != "boolean") then
          "schema:\($p): 'uniqueItems' must be a boolean, got \($s.uniqueItems|tojson)" else empty end ),
      ( if ($s|has("pattern")) and (($s.pattern|type) != "string") then
          "schema:\($p): 'pattern' must be a string, got \($s.pattern|tojson)" else empty end ),
      ( if ($s|has("enum")) and ((($s.enum|type) != "array") or (($s.enum|length) == 0)) then
          "schema:\($p): 'enum' must be a non-empty array" else empty end ),
      ( if ($s|has("required")) then
          ( if ($s.required|type) != "array" then
              "schema:\($p): 'required' must be an array"
            else
              ($s.required[]) as $r
              | select(($r|type) != "string")
              | "schema:\($p): 'required' entries must be strings, got \($r|tojson)"
            end )
        else empty end ),
      ( if ($s|has("type")) and (($s.type|type) == "array")
             and (($s.type|length) != ($s.type|unique|length)) then
          "schema:\($p): 'type' entries must be unique (Draft 2020-12)" else empty end ),
      ( if ($s|has("required")) and (($s.required|type) == "array")
             and (($s.required|length) != ($s.required|unique|length)) then
          "schema:\($p): 'required' entries must be unique (Draft 2020-12)" else empty end ),
      ( ( "properties","$defs" ) as $k
        | select($s|has($k))
        | select(($s[$k]|type) != "object")
        | "schema:\($p): '\($k)' must be an object" ),
      ( ( "allOf","anyOf","oneOf" ) as $k
        | select($s|has($k))
        | select((($s[$k]|type) != "array") or (($s[$k]|length) == 0))
        | "schema:\($p): '\($k)' must be a non-empty array" ),
      # Only the documented reference syntax is supported. Anything else used to
      # fall through ltrimstr unchanged and resolve a same-named local $defs
      # entry — a remote-looking ref silently resolving locally.
      ( if ($s|has("$ref")) then
          ( if ($s["$ref"]|type) != "string" then
              "schema:\($p): '$ref' must be a string"
            elif ($s["$ref"] | test("^#/\\$defs/[^/]+$") | not) then
              "schema:\($p): unsupported $ref \($s["$ref"]|tojson) — only \"#/$defs/<name>\" is supported"
            else
              ($s["$ref"] | ltrimstr("#/$defs/")) as $n
              | select((($rootschema|has("$defs")) and ($rootschema["$defs"]|has($n))) | not)
              | "schema:\($p): $ref target '#/$defs/\($n)' does not exist"
            end )
        else empty end ),
      ( if ($s|has("$defs")) then ($s["$defs"]|keys[]) as $n | walk($s["$defs"][$n]; "\($p).$defs.\($n)") else empty end ),
      ( if ($s|has("properties")) then ($s.properties|keys[]) as $n | walk($s.properties[$n]; "\($p).properties.\($n)") else empty end ),
      ( if ($s|has("additionalProperties")) and (($s.additionalProperties|type) != "boolean") then walk($s.additionalProperties; "\($p).additionalProperties") else empty end ),
      ( if ($s|has("propertyNames")) then walk($s.propertyNames; "\($p).propertyNames") else empty end ),
      ( if ($s|has("items")) then walk($s.items; "\($p).items") else empty end ),
      ( if ($s|has("allOf")) then range(0; $s.allOf|length) as $i | walk($s.allOf[$i]; "\($p).allOf[\($i)]") else empty end ),
      ( if ($s|has("anyOf")) then range(0; $s.anyOf|length) as $i | walk($s.anyOf[$i]; "\($p).anyOf[\($i)]") else empty end ),
      ( if ($s|has("oneOf")) then range(0; $s.oneOf|length) as $i | walk($s.oneOf[$i]; "\($p).oneOf[\($i)]") else empty end ),
      ( if ($s|has("not")) then walk($s.not; "\($p).not") else empty end ),
      ( if ($s|has("if")) then walk($s["if"]; "\($p).if") else empty end ),
      ( if ($s|has("then")) then walk($s["then"]; "\($p).then") else empty end ),
      ( if ($s|has("else")) then walk($s["else"]; "\($p).else") else empty end )
    end;
  [ walk(.; "$") ] | .[]
JQ
}

# Emit the jq program body (operates on input document).
json_schema_jq_program() {
  cat <<'JQ'
$schema[0] as $root
| def _isleap($y): (($y % 4) == 0 and ($y % 100) != 0) or (($y % 400) == 0);
def _dim($y; $m): [31, (if _isleap($y) then 29 else 28 end), 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][$m - 1];
# RFC 3339. The shape regex accepts the lowercase t/z the RFC permits; the
# semantic pass then rejects impossible calendar dates and a leap second that is
# not AT the leap instant (23:59:60 UTC once the offset is applied).
def _dt_ok($s):
    ($s | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}[Tt][0-9]{2}:[0-9]{2}:[0-9]{2}([.][0-9]+)?([Zz]|[+-][0-9]{2}:[0-9]{2})$"))
    and (
      ($s[0:4] | tonumber) as $y
      | ($s[5:7] | tonumber) as $mo
      | ($s[8:10] | tonumber) as $d
      | ($s[11:13] | tonumber) as $h
      | ($s[14:16] | tonumber) as $mi
      | ($s[17:19] | tonumber) as $sec
      | ($s | test("[Zz]$")) as $isz
      | (if $isz then 0
         else ((if ($s[-6:-5]) == "-" then -1 else 1 end) * (($s[-5:-3] | tonumber) * 60 + ($s[-2:] | tonumber)))
         end) as $offmin
      | ($mo >= 1 and $mo <= 12)
        and ($d >= 1 and $d <= _dim($y; $mo))
        and ($h <= 23) and ($mi <= 59)
        # A second of 60 is legal only AT a real leap instant: 23:59:60 UTC on the
        # last day of a month where a leap second was actually inserted. Checking
        # only the minute-of-day let every 23:59 in history carry one.
        and ( $sec <= 59
              or ( $sec == 60
                   and (((($h * 60 + $mi) - $offmin) + 2880) % 1440) == 1439
                   and ( (($y * 10000) + ($mo * 100) + $d) as $localymd
                         # local - offset < 0  => UTC is the PREVIOUS day
                         # local - offset >= 1440 => UTC is the NEXT day
                         | (if ((($h * 60 + $mi) - $offmin) < 0) then -1
                            elif ((($h * 60 + $mi) - $offmin) >= 1440) then 1
                            else 0 end) as $daynudge
                         | ( if $daynudge == 0 then $localymd
                             elif $daynudge == 1 then
                               (if $d < _dim($y; $mo) then $localymd + 1
                                elif $mo < 12 then (($y * 10000) + (($mo + 1) * 100) + 1)
                                else ((($y + 1) * 10000) + 101) end)
                             else
                               (if $d > 1 then $localymd - 1
                                elif $mo > 1 then (($y * 10000) + (($mo - 1) * 100) + _dim($y; $mo - 1))
                                else ((($y - 1) * 10000) + 1200 + 31) end)
                             end ) as $utcymd
                         | ( [ 19720630, 19721231, 19731231, 19741231, 19751231, 19761231,
                               19771231, 19781231, 19791231, 19810630, 19820630, 19830630,
                               19850630, 19871231, 19891231, 19901231, 19920630, 19930630,
                               19940630, 19951231, 19970630, 19981231, 20051231, 20081231,
                               20120630, 20150630, 20161231 ]
                             | index($utcymd) ) != null ) ) )
        and ( $isz or (($s[-5:-3] | tonumber) <= 23 and ($s[-2:] | tonumber) <= 59) )
    );
# RFC 3986, by COMPONENT rather than by character soup. The prior check
# recognized a permitted character set, which let brackets appear outside an
# IP-literal host, a second authority "@", and a non-numeric port through.
# Split into scheme / authority / path / query / fragment, then validate each.
def _pct_ok($t): ($t | test("%(?![0-9A-Fa-f]{2})")) | not;
# dec-octet is RFC 3986's exact production — DIGIT / %x31-39 DIGIT / "1" 2DIGIT
# / "2" %x30-34 DIGIT / "25" %x30-35 — so a leading zero ("01", "1.02.3.4") is
# NOT a valid octet. A looser branch let those through inside an IPv6 ls32.
def _ipv6_ok($a):
    $a | test("^(([0-9A-Fa-f]{1,4}:){7}[0-9A-Fa-f]{1,4}|([0-9A-Fa-f]{1,4}:){1,7}:|([0-9A-Fa-f]{1,4}:){1,6}:[0-9A-Fa-f]{1,4}|([0-9A-Fa-f]{1,4}:){1,5}(:[0-9A-Fa-f]{1,4}){1,2}|([0-9A-Fa-f]{1,4}:){1,4}(:[0-9A-Fa-f]{1,4}){1,3}|([0-9A-Fa-f]{1,4}:){1,3}(:[0-9A-Fa-f]{1,4}){1,4}|([0-9A-Fa-f]{1,4}:){1,2}(:[0-9A-Fa-f]{1,4}){1,5}|[0-9A-Fa-f]{1,4}:(:[0-9A-Fa-f]{1,4}){1,6}|:((:[0-9A-Fa-f]{1,4}){1,7}|:)|::(ffff(:0{1,4})?:)?((25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\\.){3}(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])|([0-9A-Fa-f]{1,4}:){1,4}:((25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\\.){3}(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9]))$");
def _host_ok($h):
    if ($h | test("^\\[.*\\]$")) then
      # IP-literal: RFC 3986 permits ONLY IPv6address or IPvFuture inside the
      # brackets. Character-screening the contents let [2001:::1], [abcd], and
      # [1.2.3] through, so parse the actual grammar.
      ( $h[1:-1] as $inner
        | _ipv6_ok($inner)
          or ($inner | test("^[Vv][0-9A-Fa-f]+\\.[A-Za-z0-9._~!$&'()*+,;=:-]+$")) )
    else
      # reg-name / IPv4: unreserved, sub-delims, or percent-escapes. No brackets.
      ($h | test("^[A-Za-z0-9._~!$&'()*+,;=-]*(%[0-9A-Fa-f]{2}[A-Za-z0-9._~!$&'()*+,;=-]*)*$"))
    end;
def _authority_ok($a):
    # At most one "@" splits userinfo from host[:port].
    (([$a | match("@"; "g")] | length) <= 1)
    and ( (if ($a | test("@")) then ($a | split("@")[1]) else $a end) as $hp
          | ( if ($hp | test("^\\[")) then
                # IP-literal host: port may follow the closing bracket only.
                ($hp | test("^\\[[^\\]]*\\](:[0-9]*)?$"))
                and _host_ok(($hp | capture("^(?<h>\\[[^\\]]*\\])").h))
              else
                (($hp | split(":") | length) <= 2)
                and _host_ok(($hp | split(":")[0]))
                and ( ($hp | split(":") | length) == 1
                      or ($hp | split(":")[1] | test("^[0-9]*$")) )   # port = DIGIT*
              end ) )
    and ( if ($a | test("@")) then
            ($a | split("@")[0] | test("^[A-Za-z0-9._~!$&'()*+,;=:%-]*$"))
          else true end );
def _uri_ok($u):
    ($u | test("^[A-Za-z][A-Za-z0-9+.-]*:"))
    and _pct_ok($u)
    and ( ($u | capture("^(?<scheme>[A-Za-z][A-Za-z0-9+.-]*):(?<rest>.*)$")) as $m
          | ($m.rest | split("#")) as $hashparts
          | ($hashparts | length) <= 2                      # at most one fragment
          and ( ($hashparts[1] // "") | test("^[A-Za-z0-9._~:/?@!$&'()*+,;=%-]*$") )
          and ( $hashparts[0] as $beforehash
                | ($beforehash | split("?")) as $qparts
                | ( ($qparts[1:] | join("?")) | test("^[A-Za-z0-9._~:/?@!$&'()*+,;=%-]*$") )
                and ( $qparts[0] as $hier
                      | if ($hier | test("^//")) then
                          ($hier[2:] | split("/")) as $seg
                          | _authority_ok($seg[0])
                          and (($seg[1:] | join("/")) | test("^[A-Za-z0-9._~:/@!$&'()*+,;=%-]*$"))
                        else
                          # No authority: brackets are not permitted anywhere.
                          ($hier | test("^[A-Za-z0-9._~:/@!$&'()*+,;=%-]*$"))
                        end ) ) );
def resolve($s):
    if ($s|type) == "object" and ($s|has("$ref")) then
      # ONLY "#/$defs/<name>". Previously any string fell through ltrimstr
      # unchanged and matched a same-named local definition, so a remote-looking
      # reference resolved locally instead of failing.
      if (($s["$ref"]|type) == "string") and ($s["$ref"] | test("^#/\\$defs/[^/]+$")) then
        ($s["$ref"] | ltrimstr("#/$defs/")) as $n
        | if ($root|has("$defs")) and ($root["$defs"]|has($n)) then $root["$defs"][$n]
          else { "__unresolved_ref": $s["$ref"] } end
      else { "__unresolved_ref": ($s["$ref"]|tostring) } end
    else $s end;

  # Nested matches so mutual recursion with v works in jq.
  def v($d; $s0; $p):
    def matches($d2; $s2):
      [ v($d2; $s2; "") ] | length == 0;
    resolve($s0) as $s
    | if ($s|type) == "object" and ($s|has("__unresolved_ref")) then
        "\($p): unresolved $ref \($s.__unresolved_ref)"
      else
        (
          # NOTE: unsupported-keyword and $ref-sibling detection lives in the
          # data-independent preflight, which runs before this and covers every
          # schema position including referenced $defs targets. Doing it here
          # only caught positions some document happened to reach.
          ( if ($s|has("type")) then
              $s.type as $t
              | if ($t|type) == "array" then
                  if ([ $t[] | select(. == ($d|type)
                        or (. == "integer" and ($d|type) == "number" and ($d|floor) == $d)
                        or (. == "number" and ($d|type) == "number")) ] | length) == 0
                  then "\($p): expected type in \($t|tojson), got \($d|type)"
                  else empty end
                else
                  ( if   $t == "object"  and ($d|type) != "object"  then "\($p): expected object, got \($d|type)"
                    elif $t == "array"   and ($d|type) != "array"   then "\($p): expected array, got \($d|type)"
                    elif $t == "string"  and ($d|type) != "string"  then "\($p): expected string, got \($d|type)"
                    elif $t == "integer" and (($d|type) != "number" or ($d|floor) != $d) then "\($p): expected integer"
                    elif $t == "number"  and ($d|type) != "number"  then "\($p): expected number"
                    elif $t == "boolean" and ($d|type) != "boolean" then "\($p): expected boolean"
                    elif $t == "null"    and ($d|type) != "null"    then "\($p): expected null"
                    else empty end )
                end
            else empty end ),
          ( if ($s|has("const")) and ($d != $s.const) then
              "\($p): const mismatch, want \($s.const|tojson)" else empty end ),
          ( if ($s|has("enum")) and ([ $s.enum[] | select(. == $d) ] | length) == 0 then
              "\($p): \($d|tojson) not in enum" else empty end ),
          ( if ($s|has("pattern")) and ($d|type) == "string" and (($d|test($s.pattern))|not) then
              "\($p): pattern \($s.pattern) failed for \($d)" else empty end ),
          ( if ($s|has("minLength")) and ($d|type) == "string" and (($d|length) < $s.minLength) then
              "\($p): shorter than minLength \($s.minLength)" else empty end ),
          ( if ($s|has("maxLength")) and ($d|type) == "string" and (($d|length) > $s.maxLength) then
              "\($p): longer than maxLength \($s.maxLength)" else empty end ),
          ( if ($s|has("minimum")) and ($d|type) == "number" and ($d < $s.minimum) then
              "\($p): \($d) below minimum \($s.minimum)" else empty end ),
          ( if ($s|has("maximum")) and ($d|type) == "number" and ($d > $s.maximum) then
              "\($p): \($d) above maximum \($s.maximum)" else empty end ),
          ( if ($s|has("minItems")) and ($d|type) == "array" and (($d|length) < $s.minItems) then
              "\($p): fewer than minItems \($s.minItems)" else empty end ),
          ( if ($s|has("maxItems")) and ($d|type) == "array" and (($d|length) > $s.maxItems) then
              "\($p): more than maxItems \($s.maxItems)" else empty end ),
          ( if ($s.uniqueItems == true) and ($d|type) == "array"
              and (($d|length) != ($d|unique|length)) then
              "\($p): items not unique" else empty end ),
          ( if ($s.format == "uri") and ($d|type) == "string" and ((_uri_ok($d))|not) then
              "\($p): bad uri \($d|tojson) (RFC 3986)" else empty end ),
          ( if ($s.format == "date-time") and ($d|type) == "string" and ((_dt_ok($d))|not) then
              "\($p): bad date-time \($d|tojson) (RFC 3339)" else empty end ),
          ( if ($s|has("required")) and ($d|type) == "object" then
              $s.required[] as $r
              | select(($d|has($r))|not)
              | "\($p): missing required '\($r)'"
            else empty end ),
          ( if ($s|has("minProperties")) and ($d|type) == "object"
              and (($d|keys|length) < $s.minProperties) then
              "\($p): fewer than minProperties \($s.minProperties)" else empty end ),
          ( if ($s.additionalProperties == false) and ($d|type) == "object" then
              ($s.properties // {}) as $props
              | ($d|keys[]) as $k
              | select(($props|has($k))|not)
              | "\($p): additional property '\($k)'"
            else empty end ),
          # A SCHEMA-valued additionalProperties constrains every property not
          # named in `properties`. Without this, a map schema's entire entry
          # contract is inert and any map validates clean.
          ( if ($d|type) == "object" and (($s.additionalProperties|type) == "object") then
              ($s.properties // {}) as $props
              | ($d|keys[]) as $k
              | select(($props|has($k))|not)
              | v($d[$k]; $s.additionalProperties; "\($p).\($k)")
            else empty end ),
          # propertyNames validates each property NAME (as a string) — this is
          # what enforces key-id grammar on a map.
          ( if ($s|has("propertyNames")) and ($d|type) == "object" then
              ($d|keys[]) as $k
              | v($k; $s.propertyNames; "\($p).\($k) (property name)")
            else empty end ),
          ( if ($s|has("properties")) and ($d|type) == "object" then
              $s.properties as $props
              | ($d|keys[]) as $k
              | select($props|has($k))
              | v($d[$k]; $props[$k]; "\($p).\($k)")
            else empty end ),
          ( if ($s|has("items")) and ($d|type) == "array" then
              if ($s.items|type) == "object" then
                range(0; $d|length) as $i
                | v($d[$i]; $s.items; "\($p)[\($i)]")
              else empty end
            else empty end ),
          ( if ($s|has("allOf")) then
              $s.allOf[] as $sub | v($d; $sub; $p)
            else empty end ),
          ( if ($s|has("anyOf")) then
              if ([ $s.anyOf[] as $sub | select(matches($d; $sub)) ] | length) == 0 then
                "\($p): failed anyOf"
              else empty end
            else empty end ),
          ( if ($s|has("oneOf")) then
              ([ $s.oneOf[] as $sub | select(matches($d; $sub)) ] | length) as $n
              | if $n != 1 then "\($p): failed oneOf (matched \($n))" else empty end
            else empty end ),
          ( if ($s|has("not")) and matches($d; $s.not) then
              "\($p): matched forbidden not-schema" else empty end ),
          ( if ($s|has("if")) then
              if matches($d; $s.if) then
                ( if ($s|has("then")) then v($d; $s.then; $p) else empty end )
              else
                ( if ($s|has("else")) then v($d; $s.else; $p) else empty end )
              end
            else empty end )
        )
      end;

  [ v(.; $root; "$") ] | .[]
JQ
}
