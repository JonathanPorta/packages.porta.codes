#!/usr/bin/env bash
# release-lib.sh — shared implementation for the blessed `release` category.
#
# Deterministic release-candidate assembly + validation. It consumes an EXPLICIT
# producer plan (blessed/release-candidate-plan/v1), verifies referenced files,
# computes sizes + SHA-256, and emits a byte-deterministic release-candidate.json
# (blessed/release-candidate/v1) plus SHA256SUMS and provenance.
#
# Crypto is NOT here: `release` delegates all signing/verification to the `signing`
# category through its public CLI (API v1). This library never sources
# signing-lib.sh and never invokes openssl. Sourced, not executed.
#
# Determinism contract (see README): UTF-8, LF, `jq -S` stable key ordering,
# arrays sorted by stable identity (artifacts by id, files by name), exactly one
# trailing newline, `created_at` supplied by the caller (no clock, no fs order).

rel_die() {
  printf 'release: %s\n' "$*" >&2
  return 1
}

rel_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'; else shasum -a 256 "$1" | awk '{print $1}'; fi
}

rel_size() { wc -c <"$1" | tr -d ' '; }

# Schema validation uses ONE implementation, packaged with the category.
#
# This category previously carried its own regex-only validator, so a format
# repaired in the repo's shared validator stayed broken here — blessed-cicd#252
# found `validate-plan.sh` reporting `plan OK` for an impossible leap-second
# `created_at`. Delegating fixed the behavior but broke dependency closure: the
# released tarball is `tar -C scripts ... release`, so a consumer installing the
# pinned artifact had no sibling `scripts/lib-json-schema.sh` and every input was
# refused.
#
# So the validator is PACKAGED at lib/lib-json-schema.sh, exactly as this
# category already packages its reference schemas, and the self-test asserts the
# packaged bytes are identical to the repo's shared copy so the two cannot drift.
# Fails CLOSED if the packaged validator is missing. $1=docfile  $2=schemafile
rel_schema_validate() {
  local doc="$1" schema="$2" lib
  lib="${REL_JSON_SCHEMA_LIB:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-json-schema.sh}"
  if [ ! -f "$lib" ]; then
    printf '$: packaged schema validator not found at %s — cannot validate\n' "$lib"
    return 0
  fi
  # shellcheck source=scripts/release/lib/lib-json-schema.sh
  . "$lib"
  json_schema_validate_file "$doc" "$schema" || true
}

# Semantic closure checks a JSON Schema cannot express. Prints one line per
# violation; empty == pass. $1=candidate.json
rel_semantic_checks() {
  local j="$1"
  jq -r 'select(.tag != ("v" + .version)) | "tag \(.tag) != v\(.version)"' "$j"
  jq -r 'select((.version | test("\\+")) or (.tag | test("\\+"))) | "build metadata in version/tag"' "$j"
  jq -r '.files[].name | select(. == "release-candidate.json" or . == "release-candidate.json.sig") | "envelope in files: \(.)"' "$j"
  jq -r '(.public_notes.sha256, .artifacts[].sha256, .files[].sha256) | select(test("^[0-9a-f]{64}$") | not) | "bad sha256: \(.)"' "$j"
  jq -r '(.source_sha, .build_sha) | select(test("^[0-9a-f]{40}$") | not) | "bad 40-hex sha: \(.)"' "$j"
  jq -r '.files[] | select(.size < 1) | "zero-size file: \(.name)"' "$j"
  jq -r '.artifacts[] | select(.size < 1) | "zero-size artifact: \(.filename)"' "$j"
  jq -r '([.artifacts[].id] | length) as $n | ([.artifacts[].id] | unique | length) as $u | select($n != $u) | "duplicate artifact id"' "$j"
  jq -r '([.artifacts[].filename] | length) as $n | ([.artifacts[].filename] | unique | length) as $u | select($n != $u) | "duplicate artifact filename"' "$j"
  jq -r '([.files[].name] | length) as $n | ([.files[].name] | unique | length) as $u | select($n != $u) | "duplicate files name"' "$j"
  jq -r '([.artifacts[] | "\(.platform)|\(.install_kind)"]) as $k | ($k | length) as $n | ($k | unique | length) as $u | select($n != $u) | "ambiguous (platform,install_kind)"' "$j"
  jq -r '.files as $f | .artifacts[] | . as $a | ([$f[] | select(.name==$a.filename and .role=="artifact" and .size==$a.size and .sha256==$a.sha256)] | length) as $n | select($n != 1) | "unmatched artifact: \($a.filename)"' "$j"
  jq -r '.files as $f | .artifacts[] | select(.signature != null) | .signature as $s | select(([$f[]|select(.name==$s and .role=="signature")]|length) != 1) | "missing signature file: \($s)"' "$j"
  jq -r '
    .artifacts[]
    | select(has("signature_profile") or has("signature_key_id"))
    | select(
        ((.signature // "") | length) == 0 or
        ((.signature_profile // "") | length) == 0 or
        ((.signature_key_id // "") | length) == 0
      )
    | "incomplete artifact signature override: \(.id)"
  ' "$j"
  jq -r '.files as $f | .artifacts[] | select(.sbom != null) | .sbom as $s | select(([$f[]|select(.name==$s and .role=="sbom")]|length) != 1) | "missing sbom file: \($s)"' "$j"
  jq -r '.public_notes as $np | .files as $f | select(([$f[]|select(.name==$np.filename and .role=="notes" and .sha256==$np.sha256)]|length) != 1) | "public notes unmatched"' "$j"
  jq -r 'select(([.files[]|select(.role=="checksums")]|length) < 1) | "no checksums file"' "$j"
  jq -r 'select((.signing.profile != "ed25519-detached-v1") or ((.signing.key_id // "") | length == 0)) | "bad signing block"' "$j"
  jq -r 'select(.signing.artifacts == "required") | .artifacts[] | select(.signature == null) | "unsigned artifact under required: \(.id)"' "$j"
}

# Recompute every payload file's size + SHA-256 on disk and compare to the manifest
# (the surface owner does not trust the manifest's numbers — it verifies the bytes).
# Prints violations; empty == pass. $1=candidate.json  $2=candidate_dir
rel_recompute_check() {
  local j="$1" cdir="$2" name size sha asize ashas
  while IFS= read -r name; do
    size="$(jq -r --arg n "$name" '.files[] | select(.name==$n) | .size' "$j")"
    sha="$(jq -r --arg n "$name" '.files[] | select(.name==$n) | .sha256' "$j")"
    if [ ! -f "$cdir/$name" ]; then
      printf 'missing payload file on disk: %s\n' "$name"
      continue
    fi
    asize="$(rel_size "$cdir/$name")"
    ashas="$(rel_sha256 "$cdir/$name")"
    [ "$asize" = "$size" ] || printf 'size mismatch for %s (manifest %s, disk %s)\n' "$name" "$size" "$asize"
    [ "$ashas" = "$sha" ] || printf 'sha256 mismatch for %s\n' "$name"
  done < <(jq -r '.files[].name' "$j")
}

# Closed candidate dir: the dir must contain EXACTLY the envelope
# (release-candidate.json + release-candidate.json.sig) plus the manifest's `files`
# payload — nothing else ("the surface rejects anything else"). Prints one line per
# UNLISTED file; empty == closed. $1=candidate.json  $2=candidate_dir
rel_closed_dir_check() {
  local j="$1" cdir="$2" allowed rel
  allowed="$(
    printf 'release-candidate.json\nrelease-candidate.json.sig\n'
    jq -r '.files[].name' "$j"
  )"
  # Walk EVERY immediate entry — regular files, symlinks, dirs, FIFOs/sockets/
  # devices — NUL-delimited (so a trailing newline in a name can't be swallowed by
  # `$(...)` or line splitting). The candidate dir must be a FLAT envelope of the
  # declared, non-symlink regular files and nothing else. A symlink is rejected here
  # even though rel_recompute_check (which uses -f) would follow it and match the
  # target's bytes — that is the exact bypass this closes.
  while IFS= read -r -d '' path; do
    rel="${path#./}"
    { [ -n "$rel" ] && [ "$rel" != "." ]; } || continue
    case "$rel" in
      */*)
        printf 'nested entry in candidate dir: %s\n' "$rel"
        continue
        ;;
    esac
    if [ -L "$cdir/$rel" ]; then
      printf 'symlink in candidate dir: %s\n' "$rel"
      continue
    fi
    if [ ! -f "$cdir/$rel" ]; then
      printf 'non-regular entry in candidate dir: %s\n' "$rel"
      continue
    fi
    case "$rel" in
      *[!A-Za-z0-9._+-]*)
        printf 'unsafe filename in candidate dir: %s\n' "$(printf '%q' "$rel")"
        continue
        ;;
    esac
    printf '%s\n' "$allowed" | grep -qxF -- "$rel" || printf 'unlisted file in candidate dir: %s\n' "$rel"
  done < <(cd "$cdir" && find . -mindepth 1 -print0)
}

# Require the vendored signing category to speak API v1 (release delegates all
# crypto to it through its CLI). $1=signing_dir
rel_require_signing_api() {
  local dir="$1" got
  [ -f "$dir/API_VERSION" ] || {
    rel_die "signing category not found at $dir (need API_VERSION)"
    return 1
  }
  got="$(tr -d '[:space:]' <"$dir/API_VERSION")"
  [ "$got" = "1" ] || {
    rel_die "signing API mismatch: need 1, found $got"
    return 1
  }
}

# Generate provenance.json (blessed/release-provenance/v1) from the plan, on stdout.
# All content comes from the plan + explicit args — no clock.
rel_build_provenance() { # $1=plan  $2=tool_version  [$3=builder]  [$4=builder_run]
  local plan="$1" tool="$2" builder="${3:-}" run="${4:-}"
  jq -S -n --slurpfile p "$plan" --arg tool "release/$tool" --arg builder "$builder" --arg run "$run" '
    $p[0] as $plan
    | {
        schema: "blessed/release-provenance/v1",
        project: $plan.project,
        component: $plan.component,
        version: $plan.version,
        tag: $plan.tag,
        producer_repo: $plan.producer_repo,
        source_sha: $plan.source_sha,
        build_sha: $plan.build_sha,
        created_at: $plan.created_at,
        tool: $tool
      }
    + (if $builder != "" then { builder: $builder } else {} end)
    + (if $run != "" then { builder_run: $run } else {} end)'
}

# Assemble a complete candidate under a directory from a plan. Produces (in cdir):
# provenance.json, SHA256SUMS, and release-candidate.json. Verifies every
# referenced file exists first. Fails closed on a missing artifact/sbom/notes or,
# when signing.artifacts==required, a missing per-artifact .sig.
# $1=plan  $2=cdir  $3=tool_version  [$4=builder]  [$5=builder_run]
rel_build_candidate() {
  local plan="$1" cdir="$2" tool="$3" builder="${4:-}" run="${5:-}"
  [ -f "$plan" ] || {
    rel_die "plan not found: $plan"
    return 1
  }
  [ -d "$cdir" ] || {
    rel_die "candidate dir not found: $cdir"
    return 1
  }

  local artifacts_mode notes_name
  artifacts_mode="$(jq -r '.signing.artifacts' "$plan")"
  notes_name="$(jq -r '.public_notes' "$plan")"

  # Accumulate artifact objects and files entries as newline-delimited JSON.
  local art_json="" files_json="" n i id filename platform install_kind sbom
  local size sha sigfile
  n="$(jq '.artifacts | length' "$plan")"
  i=0
  while [ "$i" -lt "$n" ]; do
    id="$(jq -r ".artifacts[$i].id" "$plan")"
    filename="$(jq -r ".artifacts[$i].filename" "$plan")"
    platform="$(jq -r ".artifacts[$i].platform" "$plan")"
    install_kind="$(jq -r ".artifacts[$i].install_kind" "$plan")"
    sbom="$(jq -r ".artifacts[$i].sbom // empty" "$plan")"
    [ -f "$cdir/$filename" ] || {
      rel_die "artifact file missing: $filename"
      return 1
    }
    size="$(rel_size "$cdir/$filename")"
    sha="$(rel_sha256 "$cdir/$filename")"

    # optional per-artifact signature; REQUIRED when signing.artifacts==required
    local have_sig="" sig_ref="null"
    sigfile="${filename}.sig"
    if [ -f "$cdir/$sigfile" ]; then
      have_sig=1
      sig_ref="\"$sigfile\""
    elif [ "$artifacts_mode" = "required" ]; then
      rel_die "signing.artifacts=required but missing signature: $sigfile"
      return 1
    fi

    # sbom must exist if declared
    local sbom_ref="null"
    if [ -n "$sbom" ]; then
      [ -f "$cdir/$sbom" ] || {
        rel_die "declared sbom missing: $sbom"
        return 1
      }
      sbom_ref="\"$sbom\""
    fi

    # Runtime-native signature adapter metadata, carried through from the plan.
    # Dropping it here would make the artifact inherit the envelope profile/key
    # at validation time — the wrong cryptographic contract for a native sidecar
    # — so an override declared in the plan MUST survive assembly. It is a pair;
    # a half-declared override is rejected before the candidate is written.
    local sig_profile sig_key
    sig_profile="$(jq -r ".artifacts[$i].signature_profile // empty" "$plan")"
    sig_key="$(jq -r ".artifacts[$i].signature_key_id // empty" "$plan")"
    if [ -n "$sig_profile$sig_key" ]; then
      if [ -z "$sig_profile" ] || [ -z "$sig_key" ]; then
        rel_die "artifact $id declares half a signature override (need both signature_profile and signature_key_id)"
        return 1
      fi
      if [ -z "$have_sig" ]; then
        rel_die "artifact $id declares a signature override but has no signature sidecar: $sigfile"
        return 1
      fi
    fi

    art_json+="$(jq -c -n --arg id "$id" --arg fn "$filename" --arg pl "$platform" \
      --arg ik "$install_kind" --argjson sz "$size" --arg sha "$sha" \
      --argjson sig "$sig_ref" --argjson sbom "$sbom_ref" \
      --arg sp "$sig_profile" --arg sk "$sig_key" \
      '{id:$id,filename:$fn,platform:$pl,install_kind:$ik,size:$sz,sha256:$sha}
       + (if $sig!=null then {signature:$sig} else {} end)
       + (if ($sp|length)>0 then {signature_profile:$sp} else {} end)
       + (if ($sk|length)>0 then {signature_key_id:$sk} else {} end)
       + (if $sbom!=null then {sbom:$sbom} else {} end)')"$'\n'

    files_json+="$(jq -c -n --arg n "$filename" --argjson sz "$size" --arg sha "$sha" \
      '{name:$n,role:"artifact",size:$sz,sha256:$sha}')"$'\n'
    if [ -n "$have_sig" ]; then
      files_json+="$(jq -c -n --arg n "$sigfile" --argjson sz "$(rel_size "$cdir/$sigfile")" --arg sha "$(rel_sha256 "$cdir/$sigfile")" \
        '{name:$n,role:"signature",size:$sz,sha256:$sha}')"$'\n'
    fi
    if [ -n "$sbom" ]; then
      files_json+="$(jq -c -n --arg n "$sbom" --argjson sz "$(rel_size "$cdir/$sbom")" --arg sha "$(rel_sha256 "$cdir/$sbom")" \
        '{name:$n,role:"sbom",size:$sz,sha256:$sha}')"$'\n'
    fi
    i=$((i + 1))
  done

  # public notes
  [ -f "$cdir/$notes_name" ] || {
    rel_die "public notes missing: $notes_name"
    return 1
  }
  local notes_sha notes_size
  notes_sha="$(rel_sha256 "$cdir/$notes_name")"
  notes_size="$(rel_size "$cdir/$notes_name")"
  files_json+="$(jq -c -n --arg n "$notes_name" --argjson sz "$notes_size" --arg sha "$notes_sha" \
    '{name:$n,role:"notes",size:$sz,sha256:$sha}')"$'\n'

  # provenance.json
  rel_build_provenance "$plan" "$tool" "$builder" "$run" >"$cdir/provenance.json"
  files_json+="$(jq -c -n --arg n "provenance.json" --argjson sz "$(rel_size "$cdir/provenance.json")" --arg sha "$(rel_sha256 "$cdir/provenance.json")" \
    '{name:$n,role:"provenance",size:$sz,sha256:$sha}')"$'\n'

  # SHA256SUMS over the payload (everything so far, sorted by name; NOT the
  # envelope manifest or its signature, and not SHA256SUMS itself).
  printf '%s' "$files_json" | jq -r 'select(.name != null) | .name' | LC_ALL=C sort | while IFS= read -r nm; do
    printf '%s  %s\n' "$(rel_sha256 "$cdir/$nm")" "$nm"
  done >"$cdir/SHA256SUMS"
  files_json+="$(jq -c -n --arg n "SHA256SUMS" --argjson sz "$(rel_size "$cdir/SHA256SUMS")" --arg sha "$(rel_sha256 "$cdir/SHA256SUMS")" \
    '{name:$n,role:"checksums",size:$sz,sha256:$sha}')"$'\n'

  # Emit release-candidate.json — deterministic: sorted keys (-S), artifacts by id,
  # files by name, one trailing newline, created_at from the plan.
  jq -S -n \
    --slurpfile p "$plan" \
    --argjson artifacts "$(printf '%s' "$art_json" | jq -s 'sort_by(.id)')" \
    --argjson files "$(printf '%s' "$files_json" | jq -s 'sort_by(.name)')" \
    --arg notes_name "$notes_name" --arg notes_sha "$notes_sha" \
    '$p[0] as $plan
     | {
         schema: "blessed/release-candidate/v1",
         project: $plan.project,
         component: $plan.component,
         version: $plan.version,
         tag: $plan.tag,
         producer_repo: $plan.producer_repo,
         source_sha: $plan.source_sha,
         build_sha: $plan.build_sha,
         created_at: $plan.created_at,
         signing: {
           profile: $plan.signing.profile,
           key_id: $plan.signing.key_id,
           manifest_signature: "release-candidate.json.sig",
           artifacts: $plan.signing.artifacts
         },
         public_notes: { filename: $notes_name, sha256: $notes_sha },
         artifacts: $artifacts,
         files: $files
       }'
}
