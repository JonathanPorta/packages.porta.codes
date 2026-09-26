# Provisioning walkthrough — signing and ingestion authority

The owner follows this verbatim, once, after the preconditions in §0 are done.
Every command below was checked against the vendored bootstrapper
(`scripts/bws/bootstrap.sh`, bws category **1.9.1**) and
`scripts/provision/generate-keys.sh` in this repository.

**Secret values never go into chat, logs, commits, shell history or command
arguments.** Every secret VALUE is pasted in exactly one place: the Bitwarden
web vault (Secrets Manager → project → secret). The only other secret input is
a machine-account access token, typed at the bootstrapper's **hidden** prompt,
which pipes it to `gh secret set` over stdin. No step prints a secret.

Existing identities are kept: kioskd's candidate signing key
(`RELEASE_SIGNING_KEY`, BWS project `kioskd`, its repository-level
`BWS_ACCESS_TOKEN` and `.github/actions/load-secrets/action.yml`) and every
other existing credential are **not touched**. Nothing here rotates anything.

## 0. Preconditions (done by me before you start; I will confirm each)

- [ ] `JonathanPorta/packages.porta.codes` exists, `main` carries this
      repository, and its `main` ruleset is active.
- [ ] Every Environment below exists with exactly its deployment policy
      (`scripts/provision/github-environments.sh --apply`, verified by the
      same script):

  | Repository | Environment | May deploy | Why |
  |---|---|---|---|
  | packages.porta.codes | `repository-signing` | branch `main` | publish runs on merge to main |
  | packages.porta.codes | `candidate-ingest` | branch `main` | admission/publish run from main |
  | packages.porta.codes | `repository-publication` | branch `main` | AWS OIDC role is bound to this Environment |
  | kioskd | `rpm-signing` | **tag `v*` only** | kioskd's `release.yml` runs on `v*` tag pushes; its signing job also asserts the tagged commit is an ancestor of `origin/main` |
  | corpus | `rpm-signing`, `release-signing` | branch `main` | `release.yml` runs on push to main |
  | keysprout | `rpm-signing`, `release-signing` | branch `main` | `release.yml` runs on push to main (and dispatch from main) |

- [ ] The producers' **declaration PRs** are merged, so each producer's `main`
      carries its `.bws/<domain>.list`, `.bws/<domain>.env` (placeholder
      project id) and `.github/actions/load-<domain>/action.yml` (placeholder
      secret UUID) — the files the bootstrapper fills in:

  | Repository | Files (placeholders) | Secret name in the list |
  |---|---|---|
  | packages.porta.codes | `.bws/repository-signing.{list,env}`, `.github/actions/load-repository-signing/action.yml` | `PACKAGES_REPO_SIGNING_KEY` |
  | packages.porta.codes | `.bws/candidate-ingest.{list,env}`, `.github/actions/load-candidate-ingest/action.yml` | `PACKAGES_CANDIDATE_READ_TOKEN` |
  | kioskd | `.bws/rpm-signing.{list,env}`, `.github/actions/load-rpm-signing/action.yml` | `KIOSKD_RPM_SIGNING_KEY` |
  | corpus | `.bws/rpm-signing.{list,env}`, `.github/actions/load-rpm-signing/action.yml` | `CORPUS_RPM_SIGNING_KEY` |
  | corpus | `.bws/release-signing.{list,env}`, `.github/actions/load-release-signing/action.yml` | `CORPUS_RELEASE_SIGNING_KEY` |
  | keysprout | `.bws/rpm-signing.{list,env}`, `.github/actions/load-rpm-signing/action.yml` | `KEYSPROUT_RPM_SIGNING_KEY` |
  | keysprout | `.bws/release-signing.{list,env}`, `.github/actions/load-release-signing/action.yml` | `KEYSPROUT_RELEASE_SIGNING_KEY` |

## 1. Your prerequisites

- Your own macOS workstation (single user, not screen-shared, no shell
  tracing). All commands run in your normal terminal, from the clones at
  `/Users/portaj/devel/portaj/<repo>` on an up-to-date `main`.
- Tools: `bws` CLI (2.0.0 is installed), `gh` ≥ 2.40 logged in as
  JonathanPorta with the `repo` scope (it is; `gh auth status`), `jq`, `gpg`
  (2.5.20 installed), `openssl` 3.x (3.6.3 installed).
- Bitwarden: an account that can create Secrets Manager projects and machine
  accounts in the organization, and an **admin/org access token** for the
  bootstrapper (Secrets Manager → Machine accounts → your admin account →
  Access tokens). This token is only exported into the shell, never passed as
  an argument:

  ```sh
  read -rs BWS_ACCESS_TOKEN && export BWS_ACCESS_TOKEN   # paste at the hidden prompt, Enter
  ```

  Run `unset BWS_ACCESS_TOKEN` at the end (§6).

## 2. Generate the new keys (once)

```sh
cd /Users/portaj/devel/portaj/packages.porta.codes
KEYS=~/ppc-keys-$(date +%F)            # must not exist yet
bash scripts/provision/generate-keys.sh "$KEYS"
```

It creates `$KEYS` (mode 0700) with the private files 0600, prints **only**
fingerprints and file→secret mappings, uploads nothing and touches no existing
key. Leave the terminal output for me to read (fingerprints are public) —
I commit the public halves and fingerprints.

| File in `$KEYS` | Becomes secret | In BWS project |
|---|---|---|
| `repository.sec.asc` | `PACKAGES_REPO_SIGNING_KEY` | `packages-porta-codes-repo-signing` |
| `kioskd-rpm.sec.asc` | `KIOSKD_RPM_SIGNING_KEY` | `kioskd-rpm-signing` |
| `corpus-rpm.sec.asc` | `CORPUS_RPM_SIGNING_KEY` | `corpus-rpm-signing` |
| `keysprout-rpm.sec.asc` | `KEYSPROUT_RPM_SIGNING_KEY` | `keysprout-rpm-signing` |
| `corpus-release.pem` | `CORPUS_RELEASE_SIGNING_KEY` | `corpus-release-signing` |
| `keysprout-release.pem` | `KEYSPROUT_RELEASE_SIGNING_KEY` | `keysprout-release-signing` |

(kioskd keeps its existing candidate key; no candidate key is generated for it.)

## 3. The candidate-read token (GitHub UI)

github.com → Settings → Developer settings → Fine-grained tokens → Generate:

- Name `packages-porta-codes-candidate-read`; Resource owner **JonathanPorta**;
  Expiration **180 days** (put the date in your calendar; renewal is
  `--rotate-secret PACKAGES_CANDIDATE_READ_TOKEN --no-secret-values` in the
  `packages-porta-codes-candidate-ingest` domain).
- Repository access: **Only select repositories** → `JonathanPorta/kioskd`,
  `JonathanPorta/corpus`, `JonathanPorta/keysprout`.
- Repository permissions: **Contents: Read-only** (Metadata: Read-only is
  added automatically). Nothing else. No account permissions.

Copy it straight into the Bitwarden web vault in §4 (row 2); do not store it
anywhere else.

## 4. One authority domain at a time (7 domains)

For **each row**, in the listed directory:

```sh
cd <directory>
git switch main && git pull --ff-only && git switch -c jp/c/bws-<domain>
scripts/bws/bootstrap.sh --app-name <project> --secrets-list .bws/<domain>.list \
  --loader .github/actions/load-<domain>/action.yml --project-id-file .bws/<domain>.env \
  --gh-environments <environment> --plan                      # (a) read-only preview
scripts/bws/bootstrap.sh --app-name <project> --secrets-list .bws/<domain>.list \
  --loader .github/actions/load-<domain>/action.yml --project-id-file .bws/<domain>.env \
  --gh-environments <environment> --no-secret-values          # (b) create
```

(b) creates the BWS project `<project>`, then prints the web-UI steps for the
machine account. Do exactly these in the Bitwarden web vault:

1. Secrets Manager → Machine accounts → New → name **`<project>-ci`**.
2. Projects tab of that machine account → add **only** `<project>` with
   **Can read** (never "Can read, write"; no other project).
3. Access tokens → New → name `GITHUB_ACTIONS`, no expiry change needed →
   copy it and paste it at the bootstrapper's **hidden** prompt. The
   bootstrapper stores it as the **Environment secret** `BWS_ACCESS_TOKEN` of
   `<environment>` only (never the repository secret).
4. Projects → `<project>` → New secret → name exactly `<secret>`, value = the
   CONTENTS of the file in the last column (open it in a text editor, copy,
   paste; multi-line armor is fine), or the PAT for row 2.

Then re-run (b) once more: it finds the secret and fills the placeholder UUIDs
in `.bws/<domain>.env` and the loader. **Leave those edits uncommitted** (they
hold IDs, not secrets); I review and open the PR for them.

| # | Directory | `<domain>` | `<project>` (machine account `<project>-ci`) | `<environment>` | `<secret>` ← value |
|---|---|---|---|---|---|
| 1 | `/Users/portaj/devel/portaj/packages.porta.codes` | `repository-signing` | `packages-porta-codes-repo-signing` | `repository-signing` | `PACKAGES_REPO_SIGNING_KEY` ← `$KEYS/repository.sec.asc` |
| 2 | `/Users/portaj/devel/portaj/packages.porta.codes` | `candidate-ingest` | `packages-porta-codes-candidate-ingest` | `candidate-ingest` | `PACKAGES_CANDIDATE_READ_TOKEN` ← the §3 PAT |
| 3 | `/Users/portaj/devel/portaj/kioskd` | `rpm-signing` | `kioskd-rpm-signing` | `rpm-signing` | `KIOSKD_RPM_SIGNING_KEY` ← `$KEYS/kioskd-rpm.sec.asc` |
| 4 | `/Users/portaj/devel/portaj/corpus` | `rpm-signing` | `corpus-rpm-signing` | `rpm-signing` | `CORPUS_RPM_SIGNING_KEY` ← `$KEYS/corpus-rpm.sec.asc` |
| 5 | `/Users/portaj/devel/portaj/corpus` | `release-signing` | `corpus-release-signing` | `release-signing` | `CORPUS_RELEASE_SIGNING_KEY` ← `$KEYS/corpus-release.pem` |
| 6 | `/Users/portaj/devel/portaj/keysprout` | `rpm-signing` | `keysprout-rpm-signing` | `rpm-signing` | `KEYSPROUT_RPM_SIGNING_KEY` ← `$KEYS/keysprout-rpm.sec.asc` |
| 7 | `/Users/portaj/devel/portaj/keysprout` | `release-signing` | `keysprout-release-signing` | `release-signing` | `KEYSPROUT_RELEASE_SIGNING_KEY` ← `$KEYS/keysprout-release.pem` |

The producers' `scripts/bws/bootstrap.sh` must be the 1.9.1 category (the
declaration PRs re-sync it where older; `--gh-environments` needs it).

Nothing in this walkthrough creates or edits `BWS_ACCESS_TOKEN` at repository
level, the `kioskd` / `corpus` / `keysprout` existing BWS projects, or any
existing secret.

## 5. Verification (metadata only)

In each directory, per row, the read-only inventory — it reads project and
secret NAMES and GitHub secret NAMES, never a value:

```sh
scripts/bws/bootstrap.sh --app-name <project> --secrets-list .bws/<domain>.list \
  --loader .github/actions/load-<domain>/action.yml --project-id-file .bws/<domain>.env \
  --gh-environments <environment> --plan
gh api repos/JonathanPorta/<repo>/environments/<environment>/secrets --jq '.secrets[].name'   # expect: BWS_ACCESS_TOKEN
```

I then confirm from my side, without any secret: each loader's UUIDs are real,
each Environment has exactly one secret and one deployment policy, and a
dry signing job in each domain reports only the loaded key's **fingerprint**.

## 6. Cleanup

```sh
unset BWS_ACCESS_TOKEN
rm -P "$KEYS"/* && rmdir "$KEYS"      # macOS: overwrite, then delete
```

Keep no other copy of any private file. Tell me "provisioning done" — nothing
more is needed in chat.

## 7. Admission PRs and the required check (proved, not assumed)

`admit-candidate.yml` opens each admission PR with `GITHUB_TOKEN`; GitHub does
not start `pull_request` workflows for events caused by `GITHUB_TOKEN`, so the
required `CI` check may not appear. DocSort showed a `workflow_dispatch` run on
the branch does **not** satisfy a PR ruleset's required check, so that is not
used as proof.

1. The first real admission PR records the ruleset's required-check state as
   opened (`gh pr checks`, the merge box).
2. If `CI` is absent, the one operator step is: **close and reopen that PR**
   in the GitHub UI (a human event, which starts `pull_request` CI on the exact
   head). I record whether that check satisfies the ruleset, and document it as
   the standing review step for admission PRs.
3. No PR-opening credential exists or is requested unless (2) demonstrably
   fails; if it does, I bring that evidence with a single request.
