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
   | plan | none | validates; reads the live **activation revision** (what this run's activation must replace) and the inventory's commit time |
   | fetch | `candidate-ingest` | retained packages from `https://packages.porta.codes/`, new ones from producer releases; every byte checked against the inventory |
   | generate | none | pinned tools image (`tools/`), deterministic, unsigned |
   | sign | `repository-signing` | `InRelease`, `Release.gpg`, `repomd.xml.asc` with the repository key only |
   | staged | none | verifies with public keys only; publishes into a local directory store with the same publisher; then, per supported row, real apt/dnf **install → check → upgrade → remove** through the real router in front of that store, answering as `https://packages.porta.codes/` on a private network (throwaway CA trusted by the clients only — the published `.sources`/`.repo` are tested byte for byte) |
   | publish | `repository-publication` (AWS OIDC) | creates every object once, then ONE conditional write of the activation pointer; records the new revision in the run summary |
   | read-back | none | the live pointer is this activation; a stable entrypoint is routed to it and served `no-cache`, generation objects are immutable; every row again against the real endpoint |

   Runs are serialized. A run whose activation loses its compare-and-swap
   fails: that attempt is void and is not retried; the next run re-plans.
   Re-running a run that failed before activating resumes it (objects already
   created are skipped); a completed one is a no-op.

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

The complete, itemized package — resources, costs, role policies, keys (new vs
existing) and the ordered steps — is **[`APPROVAL.md`](APPROVAL.md)**. In short:

1. **Domain and repository** — approve `packages.porta.codes` (zone
   `porta.codes`) and a new repository `JonathanPorta/packages.porta.codes`
   owning it.
2. **Infrastructure and spend** — one S3 website bucket + Cloudflare proxied
   CNAME via `s3-static-site` 1.5.0 and one read-only router Worker
   (`make plan TF_WORKSPACE=production`, then `make deploy`); itemized in
   `APPROVAL.md`. Plus one bootstrap-owned IAM role
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
edit them here; all three come from their released tarballs, MANIFEST verified.
`tests/fixtures/{router-harness.mjs,fake-store-adapter.sh}` are copied from
blessed-cicd at the release-v0.5.0 merge (`a250255`). `pkgrepo-publish.sh`'s S3 adapter needs an AWS CLI v2
with conditional writes (`--if-match`, `--if-none-match`), as on current
GitHub-hosted runners.

## Guarantees and limits

- **Nothing a client is served is overwritten.** Every object is created once:
  shared immutables (packages, by-hash indexes, checksum-named repodata) at
  their advertised paths, each generation's entrypoints (`InRelease`,
  `Release`, indexes, `repomd.xml(.asc)`, `.sources`, `.repo`, keys) under
  `_generations/<generation_id>/`. The bucket policy refuses any publisher
  write without `If-None-Match` — except the activation pointer, which must
  carry `If-Match` or `If-None-Match` — and any delete.
- **Activation is one conditional write, atomic per request.** The router
  Worker resolves each request for a stable entrypoint URL against the pointer,
  read uncached, and serves it `no-cache`. An APT/DNF transaction spans several
  requests and is not atomic: a DNF client whose `repomd.xml` and signature
  straddle an activation refuses the pair and recovers on refresh.
- **Every advertised URL stays addressable.** Older generations' by-hash
  indexes, packages and repodata remain at their URLs; rollback is a new
  activation of an older generation.
- No APT `Valid-Until` in the pilot, so there is no forced re-signing schedule;
  the freeze-attack exposure this leaves is accepted and documented.
- Automated, not unattended: each admission needs CI on its PR and an
  independent review (see `APPROVAL.md` for how admission-PR checks are proven).
