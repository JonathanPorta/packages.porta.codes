# Installing the `release` category

`release` is released as `release-v<VERSION>` (a GitHub Release tarball +
`MANIFEST.sha256`) and vendored into a consumer at `scripts/release/` at a pinned
version. See the canonical [`scripts/INSTALL.md`](../INSTALL.md) for the shared sync
mechanism.

Pin exact versions in `scripts/.blessed-scripts-version` (legacy fallback:
`scripts/.bws-scripts-version`):

```sh
# Versions below are ILLUSTRATIVE. Pin whatever the catalog and the
# category's VERSION file actually say at the revision you are vendoring.
SIGNING_VERSION=0.1.0
SIGNING_TAG=signing-v0.1.0
RELEASE_VERSION=0.1.0
RELEASE_TAG=release-v0.1.0
```

Then `make sync-scripts` + `make verify-scripts`.

Dependencies:

- **jq** is required.
- **yq** (mikefarah v4) is required *only* by `validate-surfaces.sh`. It must be
  EXACTLY the version CI executes (currently `4.53.2`): the YAML preflight depends
  on version-specific reporting, so a range would claim coverage no real binary
  has run. Pin the release and verify its SHA256; the CLI checks flavor and exact
  version and fails clearly for a missing, python-flavor, or different-version yq. `build-candidate.sh`, `validate-plan.sh`, and
  `validate-candidate.sh` do not need it.
- `release` delegates all cryptography to the **`signing`** category and checks
  `scripts/signing/API_VERSION == 1` at runtime — vendor `signing` too (any host
  that signs/verifies also needs OpenSSL ≥ 3). The promotion stages verify the
  candidate signature on **every** actionable run, not only at admission, so
  `signing` is a runtime dependency of `render-promotion.sh` and
  `apply-promotion-pr.sh` as well.
- **Every promotion stage needs the candidate trust store**, passed with
  `--trust-store`. It is deliberately not carried in the admission bundle: a
  store travelling with the artifact it validates is not a root of trust. The
  bundle commits to which store was admitted, and the stages compare.
- Render and apply also need the `admission_id` printed by admission, plus the
  expected base SHA, surface id and channel. These bind one continuous
  execution; they are not a substitute for authentication across jobs.
- The promotion stages need **git** and a checkout of the receiver repository.
  They read surface, policy, and live pointer from tracked blobs at an explicit
  trusted base SHA; only `apply-promotion-pr.sh` writes, and only to a branch it
  creates. Publication is delegated to an adapter, so no promotion stage needs
  network access or credentials of its own.
- The packaged `references/release-candidate.schema.json` is an exact copy of the
  normative `standards/releases/references/` schema; `self-test.sh` fails on drift.

## Package-repository tooling (`pkgrepo-*.sh`)

Only a `package-repository-surface` repository needs these
([`releases.package-repositories@1`](../../standards/releases/package-repositories.md)).
They source `lib/pkgrepo-lib.sh`, so vendor the whole category.

| Script | Needs | Holds |
|---|---|---|
| `pkgrepo-generate.sh` | jq, gpg, gzip; `dpkg-deb` (APT) and `createrepo_c` + `rpm` (DNF) at EXACTLY the versions in the `--tool-pins` file (`dpkg-deb=…`, `createrepo_c=…`) | no secret |
| `pkgrepo-sign.sh` | jq, gpg | the repository key only |
| `pkgrepo-verify.sh` | jq, gpg, gpgv, gzip, find; `rpmkeys` (DNF) | public keys only |
| `pkgrepo-publish.sh` | jq, od, `/dev/urandom`, and an adapter (`adapters/s3-object-adapter.sh`: aws CLI v2 with conditional writes, `PKGREPO_BUCKET`) | the store credential only |
| `pkgrepo-router.js` | a Cloudflare Worker (modules), `env.ORIGIN` = the store's HTTP origin; runtime with `fetch(…, {cache: "no-store"})` | nothing |
| `pkgrepo-client-check.sh` | runs as root inside a fresh target: curl, gpg, and apt-get or dnf | nothing |

Pin the generator tools in an image or package lock: an unpinned
`createrepo_c` makes a regeneration a different generation, and the generator
refuses a version that is not the pinned one.
