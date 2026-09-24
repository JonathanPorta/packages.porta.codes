# signing changelog

## [0.3.0] - 2026-09-24

Adds native RPM finalization (`releases.linux-packaging@1` LP-9). Additive;
`API_VERSION` stays 1 and no existing command changes.

- `rpm-finalize.sh` signs an UNSIGNED RPM with an OpenPGP key and proves the
  change was only a signature: the input matches the secret-free build's
  recorded SHA-256 before the key reaches any tool; the declared public key has
  the declared fingerprint and the private key is that key; after signing the
  NEVRA is unchanged, every byte after the signature header is identical, and
  `rpmkeys -K` verifies against an rpmdb holding only the declared key whose id
  matches the signature. It writes the signed RPM and a
  `blessed/rpm-finalization/v1` record (input, output and immutable-region
  digests, NEVRA, signer). The input is SNAPSHOTTED and only the verified
  snapshot is ever read or signed. Supported profile: OpenPGP RSA >= 3072
  bits, v4 packages; an input signed in any form (RSA, DSA, EdDSA, rpm 6
  OpenPGP) or a v6 package is refused before key use. Destinations must be
  distinct canonical paths and are created by atomic hard links
  (`ln -T`, so a directory or directory symlink appearing at the name is a
  refusal, never a container) that never overwrite; a record that cannot be
  created withdraws the signed RPM. The public key file must hold exactly one
  primary key — the declared one; its subkeys are allowed. Key handling follows `sign.sh`: by env-var name or
  file, scrubbed from the environment before any external command, imported
  over stdin into an ephemeral GNUPGHOME removed on exit. `__gpg` is set
  explicitly because distributions disagree on its default, and the signature
  is read from its header tag because rpm 6 prints `rpm -qi` differently.

## [0.2.1] - 2026-08-17

- **Trust-store schema enforcement is now asserted, not assumed.** blessed-cicd#251
  taught `scripts/lib-json-schema.sh` to descend into schema-valued
  `additionalProperties`, so `blessed/signing-trust-store/v1`'s per-key contract
  (profile, key encoding, status, key-id grammar, non-empty map) is enforced by
  the schema for the first time. The self-test previously noted this could only
  be proven at resolution time; it now asserts schema rejection AND resolver
  rejection of an unrecognized profile, since those are independent defenses.
  No behavior change in `verify.sh`, `verify-native.sh`, or the resolvers.

## [0.2.0] - 2026-08-17

Adds the `tauri-minisign-v1` client-native artifact adapter
(`signing.tauri-minisign@1`). `API_VERSION` stays 1 — this is additive; every
existing `ed25519-detached-v1` caller is unaffected.

- `verify-native.sh` — verifies a Tauri updater sidecar. The argv contract is the
  one `scripts/release/validate-candidate.sh` already dispatches to, so a
  candidate declaring `signature_profile: tauri-minisign-v1` now verifies instead
  of failing closed on a missing adapter.
- Wire format verified against production output, not inferred: the published
  `.sig` is base64 of the whole minisign document; algorithm `ED` means the
  signature is over **BLAKE2b-512(payload)**, not the payload bytes; key id bytes
  are little-endian; the line-4 global signature covers
  `(signature || trusted comment)`.
- Fails closed on: legacy unprehashed `Ed`, a key id that disagrees with the
  declared one, a mutated payload/prehash/signature/trusted comment/global
  signature, a non-minisign sidecar, an unknown or revoked key, and a key bound
  to a different profile.
- `sig_native_resolve_trust_key` is a SEPARATE resolver from the envelope
  profile's. Neither accepts the other's keys, so a trust-store entry can never
  be used across profiles.
- Known-answer vector committed under `tests/fixtures/native/` (regenerate with
  `make-vector.sh`), plus the real DocSort v0.4.3 production sidecar. The
  production control needs the 10 MB release artifact, so it runs when
  `SIGNING_NATIVE_LIVE_ARTIFACT` points at it and is loudly skipped otherwise.

## [0.1.0] - 2026-07-19

Initial release. Implements the `ed25519-detached-v1` profile
(`signing.ed25519-detached@1`), `API_VERSION` 1.

- `sign.sh` / `verify.sh` / `keygen.sh` + `lib/signing-lib.sh` (shared impl).
- OpenSSL 3 backend behind a stable CLI (rejects LibreSSL / OpenSSL < 3; honors
  `OPENSSL_BIN`).
- Trust-store (`blessed/signing-trust-store/v1`) `key_id` resolution; fail-closed
  verification — `active`/`verify-only` accepted; `revoked`/unknown/unsupported-
  profile/malformed/wrong-length/trailing-whitespace rejected.
- Strict base64 wire-format checks before decode; raw-32-byte→SPKI conversion;
  64-byte signature assert; verify-after-sign.
- Key hygiene: `umask 077`, `chmod 600` temp key, no key on argv or in logs, temp
  removed on every exit; atomic output; symlink/overwrite refusal.
- BWS kept out of the tool (`--private-key-env` / `--private-key-file`).
- `self-test.sh`: 21-check conformance suite (public known-answer vector +
  ephemeral round trip + the full fail-closed negative set + OpenSSL gating +
  key-hygiene assertions).
