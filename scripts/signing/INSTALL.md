# Installing the `signing` category

`signing` is released as `signing-v<VERSION>` (a GitHub Release tarball +
`MANIFEST.sha256`) and vendored into a consumer at `scripts/signing/` at a pinned
version. See the canonical [`scripts/INSTALL.md`](../INSTALL.md) for the shared
sync mechanism and Makefile targets.

Pin exact versions in `scripts/.blessed-scripts-version` (legacy fallback:
`scripts/.bws-scripts-version`):

```sh
SIGNING_VERSION=0.1.0
SIGNING_TAG=signing-v0.1.0
```

Then:

```sh
make sync-scripts     # installs the pinned tarball into scripts/signing/
make verify-scripts   # verifies scripts/signing/ against MANIFEST.sha256
```

Requirements and dependencies:

- **OpenSSL ≥ 3** on any host that signs or verifies (LibreSSL is rejected).
- `signing` depends on **no** other category. The `release` category depends on
  `signing` **API 1** (see `scripts/catalog.yml`); consumers still pin exact
  artifact versions of each.
