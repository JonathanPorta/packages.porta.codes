# `signed/` — the real signed-chain fixture

These bytes are a genuine, cryptographically verifiable candidate. The manifest
is signed with `ed25519-detached-v1` by `pilot-fixture-2026-08`, whose public
key is pinned in `trust-store.json`. **The private key was generated
ephemerally and destroyed** — it is deliberately not recoverable and must never
be committed.

**Editing any file here breaks the signature**, and the failure will look like
an unrelated verification bug. To change the fixture you must generate a new
keypair, rebuild the candidate, re-sign it, replace `trust-store.json`, and
destroy the new private key:

```bash
K=$(mktemp -d)
bash scripts/signing/keygen.sh --out-private "$K/priv.pem" \
  --out-public-base64 "$K/pub.b64" --key-id pilot-fixture-2026-08
bash scripts/release/build-candidate.sh --plan plan.json --candidate-dir candidate-dir \
  --output candidate-dir/release-candidate.json --builder fixture
bash scripts/signing/sign.sh --profile ed25519-detached-v1 \
  --input candidate-dir/release-candidate.json --private-key-file "$K/priv.pem" \
  --output candidate-dir/release-candidate.json.sig --force
# paste the new public key into trust-store.json, then:
rm -rf "$K"
```

This fixture drives the binding controls, where real signature verification is
the point. The separate `golden/` fixture mirrors the published docsort.io
asset values for byte-equivalence and is exercised at the adapter boundary,
where inputs are data rather than verified payloads on disk. No single fixture
can do both: verification recomputes payload hashes, and the real published
sizes belong to files far too large to commit.
