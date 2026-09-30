#!/usr/bin/env bash
# tooling-flow.sh WORK — the surface's whole flow, offline, with EPHEMERAL keys:
# admit → fetch → generate → sign → verify → publish (directory store) →
# replay → interrupted resume → stale and void activations. Run by tests/e2e.sh
# inside the pinned tools image (tools/Dockerfile) plus rpm-build/rpm-sign for
# the demo packages.
#
# Leaves for the client phase, which serves each through the REAL router:
# WORK/served-g1 and WORK/served-g2 (snapshots of the whole store after each
# activation), WORK/served-bad (g1's store with its generation's InRelease
# re-signed by a stranger), WORK/fingerprints and a TLS certificate for
# packages.porta.codes.
#
# Every negative control must be refused FOR ITS OWN REASON (the message is
# matched); a refusal for another reason is a failure.
set -uo pipefail
WORK="${1:?usage: tooling-flow.sh WORK}"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
pass=0 failed=0
ok() {
  echo "  ✓ $1"
  pass=$((pass + 1))
}
bad() {
  echo "  ✗ $1"
  failed=$((failed + 1))
}
note() { printf '%s\n' "$1" | sed 's/^/      /' | tail -6; }
expect_refusal() { # label, wanted text, command...
  local label="$1" want="$2" out rc=0
  shift 2
  out="$("$@" 2>&1)" || rc=$?
  if [ "$rc" -eq 0 ]; then
    bad "$label (accepted)"
  elif [ "$rc" -ne 1 ]; then
    bad "$label (exit $rc, not a refusal)"
    note "$out"
  elif ! printf '%s' "$out" | grep -qF -- "$want"; then
    bad "$label (WRONG reason)"
    note "$out"
  else ok "$label"; fi
}
s256() { sha256sum "$1" | cut -d' ' -f1; }

rm -rf "$WORK"
mkdir -p "$WORK"
R="$WORK/root" # a copy of this repository with test keys and a demo layout
cp -a "$REPO" "$R"
rm -rf "$R/.git" "$R/inventory/inventory.json"
export GNUPGHOME="$WORK/gnupg"
mkdir -m 700 "$GNUPGHOME"
genkey() {
  gpg --batch --quiet --passphrase '' --quick-gen-key "$1" rsa3072 sign never 2>/dev/null
  gpg --batch --with-colons --list-keys "$1" | awk -F: '/^fpr:/{print $10; exit}'
}
RK="$(genkey 'Test Repository <repo@test.invalid>')"
PK="$(genkey 'Test Producer RPM <prod@test.invalid>')"
XK="$(genkey 'Stranger <x@test.invalid>')"
printf 'REPO=%s\nPRODUCER=%s\nSTRANGER=%s\n' "$RK" "$PK" "$XK" >"$WORK/fingerprints"
rm -rf "$R/keys"
mkdir -p "$R/keys/candidates"
gpg --batch --armor --export "$RK" >"$R/keys/repository.asc"
gpg --batch --armor --export "$PK" >"$R/keys/demo-rpm.asc"
gpg --batch --armor --export-secret-keys "$RK" >"$WORK/repo.sec"
# Candidate (ed25519) keys: the producer's, and a stranger's.
S="$R/scripts/signing"
bash "$S/keygen.sh" --out-private "$WORK/cand.pem" --out-public-base64 "$WORK/cand.pub" --key-id demo-2026-01 >/dev/null 2>&1
bash "$S/keygen.sh" --out-private "$WORK/cand-x.pem" --out-public-base64 "$WORK/cand-x.pub" --key-id demo-2026-01 >/dev/null 2>&1
jq -n --arg k "$(cat "$WORK/cand.pub")" '{schema: "blessed/signing-trust-store/v1", keys: {"demo-2026-01": {profile: "ed25519-detached-v1", public_key_base64: $k, status: "active"}}}' >"$R/keys/candidates/demo.json"
jq -n '{schema: "packages-porta-codes/admission-policy/v1", producers: {"JonathanPorta/demo": {trust_store: "keys/candidates/demo.json", package_names: ["demo-cli"], smoke: "demo-cli", systemd: true}}}' >"$R/surface/admission.json"
jq --arg RK "$RK" --arg PK "$PK" '
  .repository_key.fingerprint = $RK
  | .producer_keys = [{producer_repo: "JonathanPorta/demo", fingerprint: $PK, public_key_path: "keys/demo-rpm.asc"}]
  | .repositories = [
      {id: "demo-apt", format: "apt", path: "apt/demo/", product: "demo", producer_repo: "JonathanPorta/demo", channel: "stable",
       targets: [{distro: "debian", release: "13"}], suite: "stable", component: "main", architectures: ["amd64", "arm64"]},
      {id: "demo-rpm-x86-64", format: "dnf", path: "rpm/demo/x86_64/", product: "demo", producer_repo: "JonathanPorta/demo", channel: "stable",
       targets: [{distro: "fedora", release: "44"}], arch: "x86_64"},
      {id: "demo-rpm-aarch64", format: "dnf", path: "rpm/demo/aarch64/", product: "demo", producer_repo: "JonathanPorta/demo", channel: "stable",
       targets: [{distro: "fedora", release: "44"}], arch: "aarch64"},
      {id: "later-rpm-x86-64", format: "dnf", path: "rpm/later/x86_64/", product: "later", producer_repo: "JonathanPorta/later", channel: "stable",
       targets: [{distro: "fedora", release: "44"}], arch: "x86_64"}]' "$REPO/inventory/layout.json" >"$R/inventory/layout.json"
# (later-rpm-x86-64 belongs to a producer with nothing admitted yet: like the
# live layout, which declares all three producers before any is admitted.)

# ── demo packages and candidates ───────────────────────────────────────────
B="$WORK/build"
mkdir -p "$B"
mkdeb() { # version, name, marker → path
  local d="$B/deb-$2-$1-$3"
  mkdir -p "$d/DEBIAN" "$d/usr/share/demo" "$d/usr/bin"
  printf 'Package: %s\nVersion: %s-1\nArchitecture: all\nMaintainer: t <t@test.invalid>\nDescription: demo\n' "$2" "$1" >"$d/DEBIAN/control"
  echo "v$1$3" >"$d/usr/share/demo/version"
  printf '#!/bin/sh\ncat /usr/share/demo/version\n' >"$d/usr/bin/demo-cli"
  chmod 755 "$d/usr/bin/demo-cli"
  mkdir -p "$B/out-$3"
  dpkg-deb --root-owner-group -Zgzip --build "$d" "$B/out-$3/$2_$1-1_all.deb" >/dev/null
  printf '%s' "$B/out-$3/$2_$1-1_all.deb"
}
mkrpm() { # version, signing fingerprint → path
  local t="$B/rb-$1-$2"
  mkdir -p "$t/SPECS"
  cat >"$t/SPECS/demo.spec" <<EOF
Name: demo-cli
Version: $1
Release: 1
Summary: demo
License: MIT
BuildArch: noarch
%description
demo
%install
mkdir -p %{buildroot}/usr/share/demo %{buildroot}/usr/bin
echo v$1 > %{buildroot}/usr/share/demo/version
printf '#!/bin/sh\\ncat /usr/share/demo/version\\n' > %{buildroot}/usr/bin/demo-cli
chmod 755 %{buildroot}/usr/bin/demo-cli
%files
/usr/share/demo/version
%attr(0755,root,root) /usr/bin/demo-cli
EOF
  rpmbuild --quiet --define "_topdir $t" -bb "$t/SPECS/demo.spec" >/dev/null 2>&1
  local p="$t/RPMS/noarch/demo-cli-$1-1.noarch.rpm"
  rpmsign --addsign --define "__gpg $(command -v gpg)" --define "_gpg_name $2" --define "_openpgp_sign_id $2" "$p" >/dev/null 2>&1
  printf '%s' "$p"
}
candidate() { # dir, tag, key.pem, deb, rpm — a signed blessed/release-candidate/v1
  local dir="$1" tag="$2" v="${2#v}"
  mkdir -p "$dir"
  cp "$4" "$5" "$dir/"
  printf "# demo %s\\n" "$v" >"$dir/release-notes-public.md"
  jq -n --arg v "$v" --arg t "$tag" --arg d "$(basename "$4")" --arg r "$(basename "$5")" '{
    schema: "blessed/release-candidate-plan/v1", project: "demo", component: "cli", version: $v, tag: $t,
    producer_repo: "JonathanPorta/demo", source_sha: ("1" * 40), build_sha: ("2" * 40), created_at: "2026-09-24T00:00:00Z",
    signing: {profile: "ed25519-detached-v1", key_id: "demo-2026-01", artifacts: "optional"}, public_notes: "release-notes-public.md",
    artifacts: [{id: "linux-all-deb", filename: $d, platform: "linux/all", install_kind: "deb"},
                {id: "linux-noarch-rpm", filename: $r, platform: "linux/noarch", install_kind: "rpm"}]}' >"$B/plan-$tag.json"
  bash "$R/scripts/release/build-candidate.sh" --plan "$B/plan-$tag.json" --candidate-dir "$dir" --output "$dir/release-candidate.json" --builder test >/dev/null 2>&1 ||
    return 1
  bash "$S/sign.sh" --profile ed25519-detached-v1 --input "$dir/release-candidate.json" --private-key-file "$3" --output "$dir/release-candidate.json.sig" >/dev/null 2>&1
}
admit() { # candidate dir, tag, out inventory [producer]
  bash "$R/scripts/surface/admit.sh" --candidate-dir "$1" --producer-repo "${4:-JonathanPorta/demo}" --tag "$2" \
    --inventory "$R/inventory/inventory.json" --out "$3" --pool "$WORK/admitted-pool"
}
DEB1="$(mkdeb 1.0.0 demo-cli '')"
RPM1="$(mkrpm 1.0.0 "$PK")"
DEB2="$(mkdeb 1.1.0 demo-cli '')"
RPM2="$(mkrpm 1.1.0 "$PK")"
# The producer's releases, as the offline fetch source.
REL="$WORK/releases/JonathanPorta/demo"
mkdir -p "$REL/v1.0.0" "$REL/v1.1.0"
cp "$DEB1" "$RPM1" "$REL/v1.0.0/"
cp "$DEB2" "$RPM2" "$REL/v1.1.0/"

echo "── admission ──"
if candidate "$WORK/c1" v1.0.0 "$WORK/cand.pem" "$DEB1" "$RPM1" && out="$(admit "$WORK/c1" v1.0.0 "$WORK/inv1.json" 2>&1)" &&
  [ "$(jq '.packages | length' "$WORK/inv1.json")" = 3 ] &&
  [ "$(jq -c '[.repositories[].id]' "$WORK/inv1.json")" = '["demo-apt","demo-rpm-x86-64","demo-rpm-aarch64"]' ]; then
  ok "a signed candidate is admitted: its .deb to the APT repository, its noarch RPM to both DNF architectures; a layout repository with nothing admitted is left out"
else
  bad "admission of a valid candidate failed"
  note "${out:-candidate assembly failed}"
fi
cp "$WORK/inv1.json" "$R/inventory/inventory.json"
if out="$(admit "$WORK/c1" v1.0.0 "$WORK/inv1b.json" 2>&1)" && cmp -s "$WORK/inv1.json" "$WORK/inv1b.json" && printf '%s' "$out" | grep -q 'already admitted'; then
  ok "re-admitting the same candidate changes nothing"
else
  bad "re-admission was not a no-op"
  note "$out"
fi
candidate "$WORK/cx" v1.0.0 "$WORK/cand-x.pem" "$DEB1" "$RPM1"
expect_refusal "a candidate signed by a key other than the committed trust store's" "FAIL manifest signature" admit "$WORK/cx" v1.0.0 "$WORK/n.json"
cp -a "$WORK/c1" "$WORK/ct"
printf 'X' >>"$WORK/ct/$(basename "$DEB1")"
expect_refusal "a candidate whose package bytes changed after signing" "FAIL on-disk hash recompute" admit "$WORK/ct" v1.0.0 "$WORK/n.json"
expect_refusal "a candidate that is not the tag asked for" "not v9.9.9" admit "$WORK/c1" v9.9.9 "$WORK/n.json"
expect_refusal "a producer that is not admitted here" "is not an admitted producer" admit "$WORK/c1" v1.0.0 "$WORK/n.json" JonathanPorta/other
RPMX="$(mkrpm 1.2.0 "$XK")"
candidate "$WORK/c-xrpm" v1.2.0 "$WORK/cand.pem" "$(mkdeb 1.2.0 demo-cli '')" "$RPMX"
expect_refusal "an RPM natively signed by someone other than the producer's declared key" "is not signed by ONLY" admit "$WORK/c-xrpm" v1.2.0 "$WORK/n.json"
candidate "$WORK/c-evil" v1.3.0 "$WORK/cand.pem" "$(mkdeb 1.3.0 evil-tool '')" "$(mkrpm 1.3.0 "$PK")"
expect_refusal "a package name the producer may not publish" "may not publish" admit "$WORK/c-evil" v1.3.0 "$WORK/n.json"
candidate "$WORK/c-rebuilt" v1.0.0 "$WORK/cand.pem" "$(mkdeb 1.0.0 demo-cli '-rebuilt')" "$RPM1"
expect_refusal "an admitted package file re-offered with different bytes" "would change bytes" admit "$WORK/c-rebuilt" v1.0.0 "$WORK/n.json"
candidate "$WORK/c2" v1.1.0 "$WORK/cand.pem" "$DEB2" "$RPM2"
if out="$(admit "$WORK/c2" v1.1.0 "$WORK/inv2.json" 2>&1)" && [ "$(jq '.packages | length' "$WORK/inv2.json")" = 6 ] &&
  jq -e --slurpfile a "$WORK/inv1.json" '[.packages[].file] as $f | all($a[0].packages[].file; . as $x | $f | index($x))' "$WORK/inv2.json" >/dev/null; then
  ok "the next version is admitted and every earlier package is retained"
else
  bad "admission of the next version failed or dropped retained packages"
  note "$out"
fi

echo "── fetch, generate, sign, verify, publish ──"
FA="$REPO/tests/fixtures/fake-store-adapter.sh"
export FAKE_STORE="$WORK/store" FAKE_LOG="$WORK/store.log"
mkdir -p "$FAKE_STORE/o"
PINS="$R/tools/tool-pins"
build_gen() { # inventory, out, timestamp, pool
  bash "$R/scripts/release/pkgrepo-generate.sh" --inventory "$1" --pool "$4" --keys-dir "$R" --timestamp "$3" --tool-pins "$PINS" --out "$2" >/dev/null &&
    KEY="$(cat "$WORK/repo.sec")" bash "$R/scripts/release/pkgrepo-sign.sh" --generation "$2" --key-fingerprint "$RK" --private-key-env KEY >/dev/null &&
    bash "$R/scripts/release/pkgrepo-verify.sh" --generation "$2" --inventory "$1" >/dev/null
}
fetch() { bash "$R/scripts/surface/fetch-pool.sh" --inventory "$1" --pool "$2" --retained-base "file://$3/" --local-releases "$WORK/releases"; }
publish() { bash "$R/scripts/release/pkgrepo-publish.sh" --generation "$1" --inventory "$2" --adapter "$FA" --expected-activation "$3"; }
activation() { bash "$R/scripts/surface/live-activation.sh" "file://$FAKE_STORE/o/_state/generation.json"; }
if out="$(fetch "$WORK/inv1.json" "$WORK/pool1" "$FAKE_STORE/o" 2>&1)" && printf '%s' "$out" | grep -q '0 retained .* 3 new'; then
  ok "the first pool comes entirely from the producer's release, every byte checked"
else
  bad "fetching the first pool failed"
  note "$out"
fi
TS=1790000000
if build_gen "$WORK/inv1.json" "$WORK/g1" "$TS" "$WORK/pool1" 2>"$WORK/err" && P="$(activation)" && [ "$P" = none ] &&
  out="$(publish "$WORK/g1" "$WORK/inv1.json" "$P" 2>/dev/null)" && [ "$(activation)" = "$out" ]; then
  ok "generation 1 is generated with the pinned tools, signed, verified and activated"
else
  bad "generation 1 failed"
  note "$(cat "$WORK/err") ${out:-}"
fi
G1="$(jq -r .generation_id "$WORK/g1/.generation.json")"
R1="$(activation)"
cp -a "$FAKE_STORE" "$WORK/served-g1"
if out="$(fetch "$WORK/inv2.json" "$WORK/pool2" "$FAKE_STORE/o" 2>&1)" && printf '%s' "$out" | grep -q '3 retained .* 3 new'; then
  ok "the next pool takes retained packages from the published surface and only new ones from the producer"
else
  bad "fetching the next pool failed"
  note "$out"
fi
cp -a "$FAKE_STORE/o" "$WORK/store-tampered"
f1="$(jq -r '.packages[0].file' "$WORK/inv1.json")"
printf 'X' >>"$WORK/store-tampered/$f1"
expect_refusal "a published package whose bytes are not the inventory's" "is not the inventory's bytes" fetch "$WORK/inv2.json" "$WORK/pool-t" "$WORK/store-tampered"
if build_gen "$WORK/inv2.json" "$WORK/g2" $((TS + 100)) "$WORK/pool2" 2>"$WORK/err" && P="$(activation)" && [ "$P" = "$R1" ] &&
  out="$(publish "$WORK/g2" "$WORK/inv2.json" "$P" 2>&1)" &&
  [ "$(jq -r .predecessor.activation_revision "$FAKE_STORE/o/_state/generation.json")" = "$R1" ]; then
  ok "generation 2 activates on the live activation read at plan time, recording it as predecessor"
else
  bad "generation 2 failed"
  note "$(cat "$WORK/err") ${out:-}"
fi
G2="$(jq -r .generation_id "$WORK/g2/.generation.json")"
R2="$(activation)"
cp -a "$FAKE_STORE" "$WORK/served-g2"
n0="$(grep -c '^put ' "$FAKE_LOG")"
out="$(publish "$WORK/g2" "$WORK/inv2.json" "$R2" 2>&1)"
if printf '%s' "$out" | grep -q 'already active' && [ "$(grep -c '^put ' "$FAKE_LOG")" = "$n0" ]; then
  ok "re-running the publication of the live generation writes nothing"
else
  bad "re-publication was not a no-op"
  note "$out"
fi
build_gen "$WORK/inv2.json" "$WORK/g2r" $((TS + 200)) "$WORK/pool2" 2>/dev/null
out="$(publish "$WORK/g2r" "$WORK/inv2.json" "$R2" 2>&1)"
if printf '%s' "$out" | grep -q 'replay' && [ "$(grep -c '^put ' "$FAKE_LOG")" = "$n0" ]; then
  ok "a replay of the served inventory, regenerated later, republishes nothing"
else
  bad "the replay was not a no-op"
  note "$out"
fi
expect_refusal "a publication planned before the live activation moved (stale plan)" "stale plan" publish "$WORK/g1" "$WORK/inv1.json" "$R1"
printf '{"schema":"blessed/package-repository-pointer/v2","generation_id":"other","inventory_sha256":"other","activation_revision":"%s"}' "$(printf 'f%.0s' $(seq 1 32))" >"$WORK/other.json"
expect_refusal "an activation that loses its compare-and-swap is void" "this attempt is void" \
  env FAKE_RACE_POINTER="$WORK/other.json" bash "$R/scripts/release/pkgrepo-publish.sh" --generation "$WORK/g1" --inventory "$WORK/inv1.json" --adapter "$FA" --expected-activation "$R2"
if [ "$(jq -r .generation_id "$FAKE_STORE/o/_state/generation.json")" = other ] && [ "$(grep -c '^put-pointer' "$FAKE_LOG")" -ge 1 ] &&
  [ "$(activation)" = "$(printf 'f%.0s' $(seq 1 32))" ]; then
  ok "…the other activation stands, and the void attempt was not retried; the next run re-plans from it"
else bad "…the pointer was overwritten after a lost compare-and-swap"; fi

echo "── interruption and resume ──"
export FAKE_STORE="$WORK/store-i" FAKE_LOG="$WORK/store-i.log"
mkdir -p "$FAKE_STORE/o"
publish "$WORK/g1" "$WORK/inv1.json" none >/dev/null 2>&1
RI="$(activation)"
rc=0
# Interrupted AFTER every object — the APT and DNF signatures included — was
# stored (the generation record is the last write before activation).
FAKE_FAIL_PUT_MATCH='_state/generations/*' publish "$WORK/g2" "$WORK/inv2.json" "$RI" >/dev/null 2>&1 || rc=$?
sigs="$(find "$FAKE_STORE/o/_generations/$G2" -name InRelease -o -name Release.gpg -o -name repomd.xml.asc 2>/dev/null | wc -l | tr -d ' ')"
if [ "$rc" -eq 2 ] && [ "$sigs" -ge 3 ] && [ "$(jq -r .generation_id "$FAKE_STORE/o/_state/generation.json")" = "$G1" ] && [ "$(activation)" = "$RI" ]; then
  ok "a publication interrupted after its APT and DNF signatures were stored activates nothing"
else
  bad "the interrupted publication left the wrong state (rc=$rc)"
fi
# The workflow's recovery: discard the signed tree, regenerate and re-sign
# from scratch (a later wall clock), publish again.
sleep 1
rm -rf "$WORK/g2x"
build_gen "$WORK/inv2.json" "$WORK/g2x" $((TS + 100)) "$WORK/pool2" 2>/dev/null
if out="$(publish "$WORK/g2x" "$WORK/inv2.json" "$(activation)" 2>&1)" && [ "$(jq -r .generation_id "$FAKE_STORE/o/_state/generation.json")" = "$G2" ] &&
  [ -z "$(grep '^put ' "$FAKE_LOG" | awk '{print $2}' | sort | uniq -d)" ] &&
  diff -r -x _state "$WORK/served-g2/o" "$FAKE_STORE/o" >/dev/null; then
  ok "…re-running the workflow (regenerate + re-sign) resumes with nothing rewritten and stores exactly generation 2"
else
  bad "the interrupted publication did not resume to generation 2"
  note "$out"
fi

# For the client phase: g1's store with its generation's InRelease re-signed by a stranger.
cp -a "$WORK/served-g1" "$WORK/served-bad"
gpg --batch --yes --quiet --local-user "$XK" --clearsign --output "$WORK/served-bad/o/_generations/$G1/apt/demo/dists/stable/InRelease" "$WORK/g1/apt/demo/dists/stable/Release"
openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj /CN=packages.porta.codes -addext subjectAltName=DNS:packages.porta.codes \
  -keyout "$WORK/tls-key.pem" -out "$WORK/tls-cert.pem" >/dev/null 2>&1

echo "tooling: $pass passed, $failed failed"
[ "$failed" -eq 0 ]
