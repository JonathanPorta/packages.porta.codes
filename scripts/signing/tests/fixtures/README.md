# signing test fixtures — public known-answer vector

A deterministic `ed25519-detached-v1` known-answer vector for the verify path and
the wire format. **No private key is committed** — the vector is `(public key,
message, signature)`, which is safe to publish and provides **no** production
access. The sign path is exercised by `self-test.sh` with an ephemeral key.

| File | Meaning |
|---|---|
| `message.txt` | the exact signed bytes (61 bytes) |
| `message.txt.sig` | the detached signature — standard base64, 88 bytes, no trailing newline |
| `public-key.base64` | the 32-byte Ed25519 public key, standard base64 (44 chars) |

`self-test.sh` asserts `verify.sh` accepts this vector and rejects every tampered
variant. Regenerating it (new key/message) is a deliberate change, not a fixup.
