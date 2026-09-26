# signing — `ed25519-detached-v1` sign / verify

A first-class, independently versioned blessed script category (peer of `bws` and
`ruam`) that implements the **`ed25519-detached-v1`** signing profile
([`standards/signing/ed25519-detached.md`](../../standards/signing/ed25519-detached.md)):
a detached Ed25519 signature over the **exact bytes** of a file.

One narrow primitive — **not** Apple/Authenticode/cosign/notarization/git-tag
signing. OpenSSL 3 is the v0.1 backend behind a stable CLI; **consumers never call
`openssl` directly**, so the backend can change without touching any workflow.

## Boundary

- **`signing`** signs and verifies bytes and resolves trust stores. It knows
  nothing about BWS, GitHub secrets, or release candidates.
- **Secret retrieval is the caller's job** — pass the key by `--private-key-env`
  (only the *name* on argv) or `--private-key-file`.
- Candidate assembly / hashing / provenance is the separate `release` category.

## Commands

```bash
# generate a keypair (private PEM chmod 600; prints a trust-store entry)
signing/keygen.sh --out-private key.pem --out-public-base64 key.pub --key-id docsort-2026-01

# sign the exact bytes of a file -> 88-char base64 detached signature (no newline)
signing/sign.sh --profile ed25519-detached-v1 --input release-candidate.json \
  --private-key-env DOCSORT_RELEASE_SIGNING_KEY --output release-candidate.json.sig

# verify (production): resolve key_id from a pinned trust store, FAIL CLOSED
signing/verify.sh --profile ed25519-detached-v1 --input release-candidate.json \
  --signature release-candidate.json.sig --trust-store trust.json --key-id docsort-2026-01

# verify (test/dev): explicit public key instead of a trust store
signing/verify.sh --profile ed25519-detached-v1 --input msg --signature msg.sig \
  --public-key-base64 <44-char-b64>

# run the conformance suite (known vector + full fail-closed negatives)
signing/self-test.sh
```

### `tauri-minisign-v1` (client-native artifact adapter)

```sh
signing/verify-native.sh --profile tauri-minisign-v1 --input DocSort.app.tar.gz \
  --signature DocSort.app.tar.gz.sig --trust-store trust.json --key-id 0329307E2A827219
```

Verifies a Tauri updater sidecar (minisign `ED` = Ed25519 over a BLAKE2b-512
prehash) and the global signature that binds its trusted comment. `--key-id` is
the 16-hex minisign key id and MUST match the id embedded in the signature, so a
sidecar signed by another trusted key cannot be substituted. Verify-only, no
signing: producing these signatures is the pinned Tauri signer's job.

This is NOT the candidate-envelope path — that stays `ed25519-detached-v1`
through `verify.sh`. Trust-store entries are profile-bound and the two resolvers
never accept each other's keys.

### Native RPM finalization (`rpm-finalize.sh`)

```sh
signing/rpm-finalize.sh --input kioskitd-0.1.5-1.x86_64.rpm --input-sha256 <build digest> \
  --key-fingerprint <40-hex> --public-key kioskd-rpm.asc --private-key-env RPM_SIGNING_KEY \
  --output signed/kioskitd-0.1.5-1.x86_64.rpm --record signed/kioskitd-0.1.5-1.x86_64.rpm.finalization.json
```

Implements [`releases.linux-packaging`](../../standards/releases/linux-packaging.md)
LP-9. Native RPM signing rewrites the file, so this is not a detached signer
and cannot prove byte invariance. Instead:

- it **snapshots** the input into private storage and verifies THAT copy
  against the build's recorded digest before the key reaches any tool; every
  later check and the signing itself read only the snapshot, so a file
  swapped at the caller's path afterwards is never signed;
- the input must be unsigned in ANY form (RSA, DSA, EdDSA, rpm 6 OpenPGP), a
  v4 package, and the declared key an OpenPGP **RSA key of at least 3072
  bits** — the supported signing profile; anything else is refused before key
  use;
- the result must differ only in its signature header: identical NEVRA, every
  byte after the signature header (main header + payload) identical, and
  every signature `rpmkeys -Kv` reports OK against an rpmdb holding ONLY the
  declared key, naming that key;
- `--output` and `--record` must be distinct canonical paths, neither
  existing; each is created by an atomic hard link that never overwrites, and
  if the record cannot be created the signed RPM is withdrawn — never half a
  pair.

It writes the signed RPM and a `blessed/rpm-finalization/v1` record binding
input, output and immutable-region digests and the signer. Needs `rpm`,
`rpmsign`, `rpmkeys`, `gpg` and `realpath`; tested on rpm 4.18 (Ubuntu 24.04)
and 6.0 (Fedora 44).

## Guarantees

- Requires **OpenSSL ≥ 3** (rejects LibreSSL); honors `OPENSSL_BIN`.
- Signature = raw 64-byte Ed25519, standard padded base64, **one line, no trailing
  newline**; wire format is checked **before** any base64 decode.
- Verification resolves `key_id` against a pinned trust store
  (`blessed/signing-trust-store/v1`) and **fails closed** on missing/unknown/`revoked`
  keys, unsupported profiles, malformed keys/signatures, wrong length, or trailing
  whitespace. `active` and `verify-only` keys are accepted.
- Key hygiene: `--private-key-env` is scrubbed from the environment **before any
  child process runs** (so `dirname`/`openssl`/`mktemp` never inherit it); `umask
  077`, `chmod 600` temp key, no key on argv or in logs, temp removed on every exit.
- Output safety: `sign.sh` refuses a symlink, a directory, or an existing output
  file; `--force` atomically replaces a regular file. `keygen.sh` normalizes
  destinations (rejecting lexical/symlink aliases), generates + validates the pair
  in a private temp dir, then publishes.

`API_VERSION` (the stable CLI contract) is `1`; the artifact `VERSION` is released
independently. See [`INSTALL.md`](INSTALL.md).
