# Provisioning walkthrough — Cloudflare, signing, ingestion and AWS OIDC authority

The owner follows this verbatim, once, after the preconditions in §0 are done.
Every command below was checked against the vendored bootstrapper
(`scripts/bws/bootstrap.sh`, bws category **1.9.1**) and
`scripts/provision/generate-keys.sh` in this repository.

**Secret values never go into chat, logs, commits, shell history or command
arguments.** Every secret VALUE is pasted in exactly one place: the Bitwarden
web vault (Secrets Manager → project → secret). The only other secret input is
a machine-account access token, typed at the bootstrapper's **hidden** prompt,
which pipes it to `gh secret set` over stdin. No step prints a secret.

**No AWS key is created anywhere** (blessed-cicd #9): every AWS call is a
GitHub OIDC role session. BWS holds only Cloudflare (the default domain),
signing keys and the candidate read token. The three AWS roles are
bootstrap-owned (§8; #239).

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
  | packages.porta.codes | `infrastructure-plan` | branch `main` | the read-only Terraform plan role trusts only this Environment |
  | packages.porta.codes | `infrastructure` | branch `main` | the Terraform apply role trusts only this Environment |
  | kioskd | `rpm-signing` | **tag `v*` only** | kioskd's `release.yml` runs on `v*` tag pushes; its signing job also asserts the tagged commit is an ancestor of `origin/main` |
  | corpus | `rpm-signing`, `release-signing` | branch `main` | `release.yml` runs on push to main |
  | keysprout | `rpm-signing`, `release-signing` | branch `main` | `release.yml` runs on push to main (and dispatch from main) |

- [ ] The producers' **declaration PRs** are merged, so each repository's
      `main` carries, per domain: `.bws/<domain>.list` (the generator's key
      declaration), `.bws/<domain>.env` (placeholder project id), the domain's
      `secret_authorities` entry in `blessed.yml`, and the domain's **profile**
      in the repository's ONE loader, `.github/actions/load-secrets/action.yml`
      (`<all-zero UUID> > <secret>` placeholder, filled by the bootstrapper —
      secrets.bwsm-authority-domains@1):

  | Repository | Domain → loader profile | Secret |
  |---|---|---|
  | packages.porta.codes | `default` (`.bws-secrets-list`, `.env-sample`) | `CLOUDFLARE_API_TOKEN` (+ shared `CLOUDFLARE_ACCOUNT_ID`) |
  | packages.porta.codes | `repository-signing` | `PACKAGES_REPO_SIGNING_KEY` |
  | packages.porta.codes | `candidate-ingest` | `PACKAGES_CANDIDATE_READ_TOKEN` |
  | kioskd | `rpm-signing` | `KIOSKD_RPM_SIGNING_KEY` |
  | corpus | `rpm-signing` | `CORPUS_RPM_SIGNING_KEY` |
  | corpus | `release-signing` | `CORPUS_RELEASE_SIGNING_KEY` |
  | keysprout | `rpm-signing` | `KEYSPROUT_RPM_SIGNING_KEY` |
  | keysprout | `release-signing` | `KEYSPROUT_RELEASE_SIGNING_KEY` |

## 1. Your prerequisites

- Your own macOS workstation (single user, not screen-shared, no shell
  tracing). All commands run in your normal terminal, from the clones at
  `/Users/portaj/devel/portaj/<repo>` on an up-to-date `main`.
- Tools: `bws` CLI (2.0.0 is installed), `gh` ≥ 2.40 logged in as
  JonathanPorta with the `repo` scope (it is; `gh auth status`), `jq`, `gpg`
  (2.5.20 installed), `openssl` 3.x (3.6.3 installed).
- AWS (for §8 only): the AWS CLI v2 and an IAM Identity Center profile whose
  permission set can administer IAM roles and policies. **`portaj` today signs
  in as `PowerUserAccess`, which has no IAM rights** (verified 2026-09-26: it is
  denied even `iam:GetOpenIDConnectProvider`), so §8 needs a profile on an
  IAM-capable permission set (e.g. `AdministratorAccess`). When I ask, run
  `aws sso login --profile <that profile>` — a browser sign-in; nothing is
  pasted anywhere. No AWS access key is created.
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

## 3b. The Cloudflare token (Cloudflare dashboard)

dash.cloudflare.com → My Profile → API Tokens → Create Token → **Custom token**:

- Name `packages-porta-codes-terraform`.
- Permissions: **Account → Workers Scripts → Edit**; **Zone → Workers Routes →
  Edit**; **Zone → DNS → Edit**; **Zone → Zone → Read**.
- Account resources: the account that owns `porta.codes` only. Zone
  resources: **Specific zone → `porta.codes`** only. No IP filter needed; TTL
  optional (put any expiry date in your calendar).

Copy it straight into the Bitwarden web vault in §4 (row 0); do not store it
anywhere else. `CLOUDFLARE_ACCOUNT_ID` already exists in `_shared-ci`; nothing
to do for it.

## 4. One authority domain at a time (1 default + 7 domains)

**Row 0 — the default domain (Cloudflare only), in
`/Users/portaj/devel/portaj/packages.porta.codes`.** Its token is the one
**repository-level** `BWS_ACCESS_TOKEN` (secrets.bwsm-authority-domains@1), so
it takes no `--gh-environments` and uses the default `.bws-secrets-list` and
`.env-sample`:

```sh
cd /Users/portaj/devel/portaj/packages.porta.codes
git switch main && git pull --ff-only && git switch -c jp/c/bws-default
make bws-bootstrap ARGS="--plan"               # (a) preview: project packages.porta.codes, machine account packages.porta.codes-ci
make bws-bootstrap ARGS="--no-secret-values"   # (b) create
```

In the web vault for row 0: machine account **`packages.porta.codes-ci`** gets
**Can read** on `packages.porta.codes` **and** on `_shared-ci` (for the shared
`CLOUDFLARE_ACCOUNT_ID`) and nothing else; its token goes to the bootstrapper's
hidden prompt, which stores it as the **repository** secret `BWS_ACCESS_TOKEN`;
the secret `CLOUDFLARE_API_TOKEN` in `packages.porta.codes` gets the §3b token.
`CLOUDFLARE_ACCOUNT_ID` is **not** created or filled here: it is a `shared`
key whose value lives in `_shared-ci`, and the loader already carries its
canonical `_shared-ci` id (`6c68ee9e-…`, the same id every static site's loader
carries — `scripts/bws/bootstrap.sh` `shared_uuid_for`). Re-run (b) once the
secret exists: it fills only the `CLOUDFLARE_API_TOKEN` line. Then **stop at
the checkpoint below**.
For row 0 the bootstrapper's `Cloudflare token packages.porta.codes-ci` summary
line is just its suggested token name — the §3b name is fine.

**Rows 1–7 — Environment-scoped domains.**

For **each row**, in the listed directory:

Through the repository's canonical `make bws-bootstrap` surface
(makefile.capability-verbs). `APP_NAME` is the domain's BWS project; the
loader is the default `.github/actions/load-secrets/action.yml`, where the
bootstrapper rewrites only this domain's `<placeholder> > <secret>` line:

```sh
cd <directory>
git switch main && git pull --ff-only && git switch -c jp/c/bws-<domain>
make bws-bootstrap APP_NAME=<project> ARGS="--secrets-list .bws/<domain>.list \
  --project-id-file .bws/<domain>.env --gh-environments <environment> --plan"            # (a) read-only preview
make bws-bootstrap APP_NAME=<project> ARGS="--secrets-list .bws/<domain>.list \
  --project-id-file .bws/<domain>.env --gh-environments <environment> --no-secret-values" # (b) create
```

(b) creates the BWS project `<project>`, then prints the web-UI steps for the
machine account. Its summary always includes a line `Cloudflare token
<project>-ci`: that is only the name it would suggest for a Cloudflare token.
Rows 1–7 declare no Cloudflare secret, so ignore it there; create no other
Cloudflare token. Do exactly these in the Bitwarden web vault:

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
in `.bws/<domain>.env` and in this domain's line of
`.github/actions/load-secrets/action.yml`. Then **stop at the checkpoint**.

### The checkpoint — after EVERY row, before the next row in the same repository

Several domains share one loader file: rows 0, 1 and 2 (packages.porta.codes),
rows 4 and 5 (corpus), rows 6 and 7 (keysprout). The bootstrapper refuses to
edit a loader that has uncommitted changes, so running the next row on top of
the previous row's uncommitted fill would leave the next UUID unfilled. So,
after each row:

1. **You stop** and tell me "row N done". Leave the fill (IDs only — no
   secret) uncommitted in that clone.
2. **I** commit exactly `.github/actions/load-secrets/action.yml` and that
   row's `.bws/<domain>.env` (or `.env-sample` for row 0) from your clone onto
   its `jp/c/bws-<domain>` branch, open the PR, take it through review and
   merge it.
3. **You** start the next row of that repository from a clean, updated main:
   `git switch main && git pull --ff-only` (the row's own command then creates
   the next branch).

Rows in different repositories do not share a loader and may run in any order
between checkpoints. `tests/bws-loader-bootstrap.sh` walks rows 0–2 through the
real bootstrapper with recording fakes: without the checkpoint the next row
refuses to edit the loader; with it, every row fills its own line and leaves
the others intact.

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

Only row 0 sets a repository-level `BWS_ACCESS_TOKEN`, and only in
packages.porta.codes (which has none today). Nothing here touches the `kioskd`
/ `corpus` / `keysprout` repository-level tokens, their existing BWS projects,
or any existing secret.

## 5. Verification (metadata only)

In each directory, per row, the read-only inventory — it reads project and
secret NAMES and GitHub secret NAMES, never a value:

```sh
make bws-bootstrap ARGS="--plan"                                                    # row 0
gh secret list --repo JonathanPorta/packages.porta.codes                            # expect: BWS_ACCESS_TOKEN (and no AWS_*)
make bws-bootstrap APP_NAME=<project> ARGS="--secrets-list .bws/<domain>.list \
  --project-id-file .bws/<domain>.env --gh-environments <environment> --plan"        # rows 1–7
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

## 8. AWS: three OIDC roles, bootstrap-owned (I run it with your SSO session)

No AWS key exists for this repository. The roles are created by the
**operator's identity**, never by one a workflow can reach (#239), with
`scripts/provision/aws-oidc-bootstrap.sh`. You authorized me to run it as part
of the approved deployment; the only thing I need from you is a live SSO
session:

```sh
aws sso login --profile <IAM-capable profile>   # you: browser sign-in; nothing to paste
```

(The script refuses, with the AWS error, if the identity cannot read IAM — an
unreadable object is never treated as absent.)

Then I run, from `/Users/portaj/devel/portaj/packages.porta.codes` on `main`:

```sh
AWS_PROFILE=<IAM-capable profile> bash scripts/provision/aws-oidc-bootstrap.sh            # --plan (read-only): what would change
AWS_PROFILE=<IAM-capable profile> bash scripts/provision/aws-oidc-bootstrap.sh --apply    # create/update, then verify
AWS_PROFILE=<IAM-capable profile> bash scripts/provision/aws-oidc-bootstrap.sh --verify   # read-only PASS/FAIL, any time
```

In order, it:

1. refuses to run as any managed role (operator identity only);
2. reads this repository's OIDC subject configuration and requires it to equal
   `policies/oidc-subject.json` (`use_default: true`, `use_immutable_subject:
   true`, prefix `repo:JonathanPorta@1451007/packages.porta.codes@1389054623`) —
   otherwise it trusts nothing;
3. reads back `infrastructure-plan`, `infrastructure` and
   `repository-publication`: each must exist, allow exactly branch `main`, and
   hold no `AWS_*` secret — before any role trusts it;
4. requires the account-global GitHub OIDC provider by its exact ARN with
   audience `sts.amazonaws.com` (it exists: docsort.io uses it; it is never
   created without `--create-provider`);
5. creates or corrects each role's trust (one exact `StringEquals` subject +
   `aud`), its boundary `<role>-boundary`, max session 3600 s, and — for plan and
   apply — its inline `permissions` from `policies/`; the publisher's inline
   policy is left to Terraform;
6. sets the repository variables `AWS_ACCOUNT_ID` and `AWS_REGION` (not secrets);
7. verifies everything from the live APIs and prints PASS/FAIL per condition.

`--self-test` (run by `make check`) proves offline that the checker rejects a
ref-scoped, wildcard or other-Environment subject, another audience,
`StringLike`, another provider, a second statement, role chaining, and
permissions with `iam:PassRole`, `s3:*` or `Resource: *`.

After it passes: I dispatch **Terraform plan** on `main`; you review the
`terraform-plan` artifact; on your approval I dispatch **Terraform apply** with
that run id (it refuses unless the plan is of `main`'s current HEAD).
