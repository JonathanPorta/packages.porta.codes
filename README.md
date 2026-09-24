# packages.porta.codes

Signed static **APT** and **DNF** repositories for `kioskd` (`kioskitd`),
`corpus` (`corpus-cx`) and `keysprout` (`keysprout-keyboard`) — the
`package-repository-surface` of blessed
[`releases.package-repositories@1`](https://github.com/JonathanPorta/blessed-cicd/blob/master/standards/releases/package-repositories.md)
(trackers: blessed-cicd #74, #303, #81).

This repository is the **one owner** of the bucket, the CDN hostname and the
repository signing key. Producers keep their signed candidates; this repo
admits them by surface-pull into a reviewed inventory and publishes with its
own authority. No repository server runs: metadata is generated, signed,
verified and published in CI.

> **Status: not provisioned.** Nothing here has been applied, pushed or
> published. It waits on the owner decisions listed under
> [Decisions needed](#decisions-needed). Everything that does not need them is
> built and tested locally (`make test`).

## How a release reaches users

1. **Admit** — an operator runs **Admit candidate**
   (`.github/workflows/admit-candidate.yml`) with a producer and a tag. It
   fetches the release's complete asset set with the read-only candidate
   credential, then `scripts/surface/admit.sh`, offline in the pinned tools
   image:
   - validates the candidate and its manifest signature against the producer's
     **committed** trust store (`keys/candidates/<producer>.json`, named in
     `surface/admission.json`) — never a store carried by the candidate;
   - reads each package's identity from the package itself and refuses names
     the producer may not ship;
   - checks every RPM against **only** its producer's declared RPM key;
   - maps each package to the repository of its format and architecture — the
     repositories in `inventory/layout.json` *are* the support matrix;
   - keeps every existing entry (identical re-admission is a no-op; a changed
     file is refused) and validates the result;
   - and opens a **reviewed PR** changing `inventory/inventory.json`.
2. **Review and merge** — run **CI** on the admission branch (PRs opened with
   `GITHUB_TOKEN` do not start it) and get an independent review. Merging is the
   approval.
3. **Publish** — `.github/workflows/publish.yml`, one authority per job:

   | Job | Authority | Does |
   |---|---|---|
   | plan | none | validates; reads the live generation (the expected parent) and the inventory's commit time |
   | fetch | `candidate-ingest` | retained packages from `https://packages.porta.codes/`, new ones from producer releases; every byte checked against the inventory |
   | generate | none | pinned tools image (`tools/`), deterministic, unsigned |
   | sign | `repository-signing` | `InRelease`, `Release.gpg`, `repomd.xml.asc` with the repository key only |
   | staged | none | verifies with public keys only; then, per supported row, real apt/dnf **install → check → upgrade → remove** against the generation served as `https://packages.porta.codes/` on a private network (throwaway CA trusted by the clients only — the published `.sources`/`.repo` are tested byte for byte) |
   | publish | `repository-publication` (AWS OIDC) | create-only immutables, a fenced activation claim, conditional entrypoint writes, confirm, read back from the store |
   | read-back | none | the live pointer names the generation; every row again against the real endpoint |

   Runs are serialized. Re-running a failed run is the resume path: an
   interrupted activation is taken over, a completed one is a no-op.

## Install

_Fingerprints are published here when the keys are provisioned._

**Debian 13 / Raspberry Pi OS (trixie)** — kioskd, corpus:

```sh
sudo install -d -m 0755 /etc/apt/keyrings
sudo curl -fsSLo /etc/apt/keyrings/packages-repository.asc https://packages.porta.codes/keys/repository.asc
gpg --show-keys /etc/apt/keyrings/packages-repository.asc   # expect: <REPOSITORY KEY FINGERPRINT>
sudo curl -fsSLo /etc/apt/sources.list.d/kioskd.sources https://packages.porta.codes/apt/kioskd/kioskd.sources
sudo apt update && sudo apt install kioskitd
```

**Fedora 44** — kioskd, corpus, keysprout:

```sh
sudo curl -fsSLo /etc/yum.repos.d/keysprout.repo https://packages.porta.codes/rpm/keysprout/keysprout.repo
sudo dnf install keysprout-keyboard      # dnf shows each key's fingerprint before trusting it
```

Package and repository metadata signatures are both verified (`gpgcheck=1`,
`repo_gpgcheck=1`, `skip_if_unavailable=False`; APT `Signed-By`).

## Supported rows

From `inventory/layout.json` (blessed linux-packaging LP-1):

| Product | Format | Target | Arch | Staged/read-back clients |
|---|---|---|---|---|
| kioskd | deb | Debian 13, Raspberry Pi OS 13 | amd64, arm64 | amd64 (runners are x86_64) |
| kioskd | rpm | Fedora 44 | x86_64 | x86_64 |
| corpus | deb | Debian 13 | amd64, arm64 | amd64 |
| corpus | rpm | Fedora 44 | x86_64, aarch64 | x86_64 |
| keysprout | rpm | Fedora 44 | x86_64 | x86_64 |

arm64/aarch64 rows are served and verified, but their install evidence comes
from the producers' emulated lifecycle rows; `client-rows.sh` reports them as
"not exercised on this host", never as passed. kioskd's Fedora aarch64 RPM is
build-only upstream and has no repository here, so it is not admitted.

## Decisions needed

1. **Domain and repository** — approve `packages.porta.codes` (zone
   `porta.codes`) and a new repository `JonathanPorta/packages.porta.codes`
   owning it.
2. **Infrastructure and spend** — one S3 website bucket + Cloudflare proxied
   CNAME via `s3-static-site` 1.5.0 (`make plan TF_WORKSPACE=production`, then
   `make deploy`); negligible cost. Plus one bootstrap-owned IAM role
   `packages-porta-codes-publisher` trusting
   `repo:JonathanPorta/packages.porta.codes:environment:repository-publication`
   (Terraform owns only its permissions); set repository variables
   `AWS_ACCOUNT_ID` and `AWS_REGION`.
3. **Credential authority** — create the keys and authority domains below.

## Provisioning (one time, after the decisions)

1. Create the repository; push `main`; create Environments `candidate-ingest`,
   `repository-signing`, `repository-publication` (allowed ref: `main`).
2. `scripts/provision/generate-keys.sh <new-dir>` on a trusted workstation:
   generates the repository key and the three producer RPM keys (OpenPGP RSA
   4096) and the corpus/keysprout candidate keys (Ed25519) into 0600 files,
   prints only fingerprints and the exact bootstrap commands. It uploads
   nothing and rotates nothing; kioskd's existing candidate key is reused
   (`keys/candidates/kioskd.json`).
3. Commit the public halves and fingerprints (`keys/`, `inventory/layout.json`).
4. For each authority domain, `scripts/bws/bootstrap.sh … --no-secret-values`
   (the script prints each command), then paste the value in the Bitwarden web
   UI:

   | Domain | BWS project / machine account | Environment | Secret |
   |---|---|---|---|
   | repository signing | `packages-porta-codes-repo-signing` / `…-ci` | `repository-signing` | `PACKAGES_REPO_SIGNING_KEY` (armored private key) |
   | candidate ingest | `packages-porta-codes-candidate-ingest` / `…-ci` | `candidate-ingest` | `PACKAGES_CANDIDATE_READ_TOKEN` (fine-grained PAT, Contents: read on kioskd, corpus, keysprout) |
   | publication | none — GitHub OIDC | `repository-publication` | — |
   | producer RPM signing (in each producer) | `<repo>-rpm-signing` / `…-ci` | per producer | `<REPO>_RPM_SIGNING_KEY` |
   | producer candidate signing (corpus, keysprout) | `<repo>-release-signing` / `…-ci` | per producer | `<REPO>_RELEASE_SIGNING_KEY` |

   The loaders (`.github/actions/load-*`) carry placeholder UUIDs until the
   bootstrapper fills them; every workflow refuses to run while they do.
5. `make plan TF_WORKSPACE=production`, review `plan.out`, `make deploy`.
6. Admit the first candidates, merge, and watch **Publish**.

## Development

```sh
make help          # the command surface
make check         # vendored-script manifests, shellcheck, shfmt, actionlint, terraform fmt, validation
make test          # offline end to end: admission → publication → Debian 13 apt / Fedora 44 dnf5
make sync-scripts  # reinstall blessed scripts from the pins in scripts/.blessed-scripts-version
```

`scripts/{bws,signing,release}` are vendored blessed-cicd categories — never
edit them here. release 0.5.0 and signing 0.3.0 are not tagged yet; see
`scripts/VENDORED-FROM`. `pkgrepo-publish.sh`'s S3 adapter needs an AWS CLI v2
with conditional writes (`--if-match`, `--if-none-match`), as on current
GitHub-hosted runners.

## Guarantees and limits

- Immutable objects (packages, by-hash indexes, checksum-named repodata, keys,
  generation records) are **create-only**; the bucket policy refuses any other
  write to them and any delete by the publisher.
- Mutable entrypoints (`InRelease`, `repomd.xml(.asc)`, configuration) are
  cached for 60 s and revalidated. A DNF client that sees `repomd.xml` and its
  signature from different generations refuses and recovers on refresh.
- No APT `Valid-Until` in the pilot, so there is no forced re-signing schedule;
  the freeze-attack exposure this leaves is accepted and documented.
- Automated, not unattended: each admission needs an operator to run CI on its
  PR and an independent review.
