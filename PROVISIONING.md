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
bootstrap-owned (§13; #239).

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
  | kioskd | `rpm-signing` | **follows kioskd's merged release trigger**: tag `v*` while kioskd's `main` still releases on `v*` tags; branch `main` once kioskd#34 (reviewed release PR on `main`, the workflow creates the tag) is merged | `github-environments.sh` reads kioskd's `release.yml` on `main` and applies exactly the matching policy, so the signing job is never locked out mid-transition |
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
- AWS (for §13 only): the AWS CLI v2 and an IAM Identity Center profile whose
  permission set can administer IAM roles and policies. **`portaj` today signs
  in as `PowerUserAccess`, which has no IAM rights** (verified 2026-09-26: it is
  denied even `iam:GetOpenIDConnectProvider`), so §13 needs a profile on an
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

  Run `unset BWS_ACCESS_TOKEN` at the end of Batch B (§9); `$KEYS` is deleted only in §11, after §10 verifies every vault key.

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
| `repository.sec.asc` | `PACKAGES_REPO_SIGNING_KEY` | `packages.porta.codes-repo-signing` |
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
  `packages.porta.codes-candidate-ingest` domain).
- Repository access: **Only select repositories** → `JonathanPorta/kioskd`,
  `JonathanPorta/corpus`, `JonathanPorta/keysprout`.
- Repository permissions: **Contents: Read-only** (Metadata: Read-only is
  added automatically). Nothing else. No account permissions.

Copy it straight into the Bitwarden web vault in §9 (row B1); do not store it
anywhere else.

## 3b. The Cloudflare token (Cloudflare dashboard)

dash.cloudflare.com → My Profile → API Tokens → Create Token → **Custom token**:

- Name `packages-porta-codes-terraform`.
- Permissions: **Account → Workers Scripts → Edit**; **Zone → Workers Routes →
  Edit**; **Zone → DNS → Edit**; **Zone → Zone → Read**.
- Account resources: the account that owns `porta.codes` only. Zone
  resources: **Specific zone → `porta.codes`** only. No IP filter needed; TTL
  optional (put any expiry date in your calendar).

Copy it straight into the Bitwarden web vault in §5 (row 0); do not store it
anywhere else. `CLOUDFLARE_ACCOUNT_ID` already exists in `_shared-ci`; nothing
to do for it.

## 4. Three kinds of token — never interchangeable

| Token | What it is | The ONLY place it goes | Lifetime here |
|---|---|---|---|
| **BWS admin (bootstrapper) token** | your Bitwarden admin/org access token, which can create projects | exported in the shell: `read -rs BWS_ACCESS_TOKEN && export BWS_ACCESS_TOKEN` | one terminal session; `unset` at the end of Batch B |
| **Machine-account access token** | minted in the web vault for `<project>-ci` | pasted at the bootstrapper's **hidden prompt**, which stores it as GitHub secret `BWS_ACCESS_TOKEN` (row 0: repository secret; every other row: that row's **Environment** secret) | stays in GitHub; never in a file, chat or command |
| **Service secret** | a private key file's CONTENTS, the candidate-read PAT, or the Cloudflare API token | pasted **only** into the Bitwarden web vault, as the named secret in the named project | stays in Bitwarden |

The bootstrapper never receives a service secret (`--no-secret-values`), and no
command below takes any token as an argument.

## 5. Row 0 — the default domain (done first; unchanged)

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
the checkpoint (§8)**.
For row 0 the bootstrapper's `Cloudflare token packages.porta.codes-ci` summary
line is just its suggested token name — the §3b name is fine.

After row 0: stop, tell me "row 0 done" (checkpoint rule, §8).

## 6. Batch K — the new keys and the read token (one sitting, no BWS)

Do §2 (generate the six new keys into one fresh 0700 directory) and §3 (the
candidate-read PAT) now, in the same terminal you will use for Batches A and B,
so `$KEYS` stays set:

```sh
cd /Users/portaj/devel/portaj/packages.porta.codes
git switch main && git pull --ff-only
KEYS=~/ppc-keys-$(date +%F)                 # must not exist yet
bash scripts/provision/generate-keys.sh "$KEYS"
```

Tell me the `$KEYS` path with "batch K done" (the path and the printed
fingerprints are public). I copy **only** the public files from it —
`*.pub.asc` and `*-trust-store.json` — and never open a `.sec.asc` or `.pem`.
Keep the PAT page open (or create it during Batch B); it is pasted only into the
vault.

## 7. Batch A — one domain in each repository (four rows, any order)

These four rows are in four different repositories, so they share no loader
file and can run back to back without a checkpoint between them. For each row,
in the same terminal (with `$KEYS` set):

```sh
read -rs BWS_ACCESS_TOKEN && export BWS_ACCESS_TOKEN   # BWS ADMIN token, once per terminal
cd <directory>
git switch main && git pull --ff-only && git switch -c jp/c/bws-<domain>
make bws-bootstrap APP_NAME=<project> ARGS="--secrets-list .bws/<domain>.list \
  --project-id-file .bws/<domain>.env --gh-environments <environment> --plan"            # (a) read-only preview
make bws-bootstrap APP_NAME=<project> ARGS="--secrets-list .bws/<domain>.list \
  --project-id-file .bws/<domain>.env --gh-environments <environment> --no-secret-values" # (b) create
```

| Row | `<directory>` | `<domain>` | `<project>` | Machine account | `<environment>` (deploys from) | Service secret ← value |
|---|---|---|---|---|---|---|
| A1 | `/Users/portaj/devel/portaj/packages.porta.codes` | `repository-signing` | `packages.porta.codes-repo-signing` | `packages.porta.codes-repo-signing-ci` | `repository-signing` (branch `main`) | `PACKAGES_REPO_SIGNING_KEY` ← contents of `$KEYS/repository.sec.asc` |
| A2 | `/Users/portaj/devel/portaj/kioskd` | `rpm-signing` | `kioskd-rpm-signing` | `kioskd-rpm-signing-ci` | `rpm-signing` (follows kioskd's release trigger — §0) | `KIOSKD_RPM_SIGNING_KEY` ← contents of `$KEYS/kioskd-rpm.sec.asc` |
| A3 | `/Users/portaj/devel/portaj/corpus` | `rpm-signing` | `corpus-rpm-signing` | `corpus-rpm-signing-ci` | `rpm-signing` (branch `main`) | `CORPUS_RPM_SIGNING_KEY` ← contents of `$KEYS/corpus-rpm.sec.asc` |
| A4 | `/Users/portaj/devel/portaj/keysprout` | `rpm-signing` | `keysprout-rpm-signing` | `keysprout-rpm-signing-ci` | `rpm-signing` (branch `main`) | `KEYSPROUT_RPM_SIGNING_KEY` ← contents of `$KEYS/keysprout-rpm.sec.asc` |

Expected preview (a): `BWS project name <project>`, `BWS machine acct
<project>-ci`, "would ensure GH Environment secret BWS_ACCESS_TOKEN in:
<environment>", and the one `Checking BWS secret: <secret>` line. Its
`Cloudflare token <project>-ci` line is only a suggested name — these domains
declare no Cloudflare secret; create none.

When (b) stops for the machine-account token, in the Bitwarden web vault
(Secrets Manager):

1. **Machine accounts → New** → name exactly the row's machine account.
2. Its **Projects** tab → add **only** `<project>`, **Can read** (never "Can
   read, write"; no other project).
3. Its **Access tokens** → New → name `GITHUB_ACTIONS` → copy it and paste it at
   the bootstrapper's **hidden** prompt. It becomes the **Environment** secret
   `BWS_ACCESS_TOKEN` of `<environment>` in that repository only.
4. **Projects → `<project>` → New secret** → name exactly the row's secret;
   value = the CONTENTS of the row's file (open it in a text editor, copy,
   paste; multi-line armor is fine).

Then re-run (b) once: it finds the secret and fills the placeholder IDs. Check
and leave them uncommitted:

```sh
git status --short    # expect exactly: M .bws/<domain>.env  and  M .github/actions/load-secrets/action.yml
```

After all four rows: tell me **"batch A done"**. Keep the terminal (and
`$KEYS`) open.

## 8. Checkpoint — I commit, review and merge (you wait)

Every repository has ONE loader, and the bootstrapper refuses to edit a loader
with uncommitted changes, so Batch B starts only after these merge. From your
clones, I commit exactly (IDs and public material only — no secret):

| Repository | ID-fill PR (branch `jp/c/bws-<domain>`) | Public material I add (from `$KEYS`, public files only) |
|---|---|---|
| packages.porta.codes | `.github/actions/load-secrets/action.yml`, `.bws/repository-signing.env` | `keys/repository.asc`, `keys/kioskd-rpm.asc`, `keys/corpus-rpm.asc`, `keys/keysprout-rpm.asc`, `keys/candidates/corpus.json`, `keys/candidates/keysprout.json`, fingerprints in `inventory/layout.json` (separate PR) |
| kioskd | `.github/actions/load-secrets/action.yml`, `.bws/rpm-signing.env` | into kioskd#32: `packaging/keys/kioskd-rpm.asc`, `packaging/keys/kioskd-rpm.fingerprint` |
| corpus | `.github/actions/load-secrets/action.yml`, `.bws/rpm-signing.env` | into corpus#282: `packaging/keys/corpus-rpm.pub.asc`, `packaging/keys/corpus-rpm.fingerprint`, `release-trusted-keys.json` (= `corpus-trust-store.json`) |
| keysprout | `.github/actions/load-secrets/action.yml`, `.bws/rpm-signing.env` | into keysprout#202: `packaging/keys/keysprout-rpm.asc`, `packaging/keys/keysprout-rpm.fpr`, `release-trusted-keys.json` (= `keysprout-trust-store.json`) |

(Row 0's checkpoint is the same, with `.env-sample` instead of a `.bws/*.env`.)
I take each PR through review and merge the ID-fill PRs; the ceremony PRs merge
only when all their keys, trust stores and Environment tokens are in place. I
then tell you **"batch B ready"**.

## 9. Batch B — the second domain in each repository (three rows)

Same terminal and commands as §7 (each row starts from a freshly pulled `main`,
so the merged Batch A fill is already in the loader):

| Row | `<directory>` | `<domain>` | `<project>` | Machine account | `<environment>` (deploys from) | Service secret ← value |
|---|---|---|---|---|---|---|
| B1 | `/Users/portaj/devel/portaj/packages.porta.codes` | `candidate-ingest` | `packages.porta.codes-candidate-ingest` | `packages.porta.codes-candidate-ingest-ci` | `candidate-ingest` (branch `main`) | `PACKAGES_CANDIDATE_READ_TOKEN` ← the §3 PAT |
| B2 | `/Users/portaj/devel/portaj/corpus` | `release-signing` | `corpus-release-signing` | `corpus-release-signing-ci` | `release-signing` (branch `main`) | `CORPUS_RELEASE_SIGNING_KEY` ← contents of `$KEYS/corpus-release.pem` |
| B3 | `/Users/portaj/devel/portaj/keysprout` | `release-signing` | `keysprout-release-signing` | `keysprout-release-signing-ci` | `release-signing` (branch `main`) | `KEYSPROUT_RELEASE_SIGNING_KEY` ← contents of `$KEYS/keysprout-release.pem` |

Vault steps 1–4 exactly as in §7; re-run (b); `git status --short` shows the
row's `.bws/<domain>.env` and the loader. Then end the BWS session — but
**keep `$KEYS`**:

```sh
unset BWS_ACCESS_TOKEN      # the admin token is no longer needed
```

and tell me **"batch B done"**. I commit those three ID fills the same way as
§8, then verify (§10). `$KEYS` holds the only copy of each private key outside
the vault until that verification passes, so do **not** delete it yet.

Only row 0 sets a repository-level `BWS_ACCESS_TOKEN`, and only in
packages.porta.codes (which has none today). Nothing here touches the `kioskd`
/ `corpus` / `keysprout` repository-level tokens, their existing BWS projects,
kioskd's existing candidate key, or any other existing secret. The producers'
`scripts/bws/bootstrap.sh` is the 1.9.1 category (merged declaration PRs);
every command in §7 and §9 was checked with `--dry-run` against each
repository's `main`.

## 10. Verification — before any key is deleted (I do this)

For each row, read-only: project and secret NAMES and GitHub secret NAMES,
never a value:

```sh
make bws-bootstrap APP_NAME=<project> ARGS="--secrets-list .bws/<domain>.list \
  --project-id-file .bws/<domain>.env --gh-environments <environment> --plan"
gh api repos/JonathanPorta/<repo>/environments/<environment>/secrets --jq '.secrets[].name'   # expect exactly: BWS_ACCESS_TOKEN
```

I then confirm: each loader's IDs are real (no placeholder left), each
Environment has exactly one secret and its one deployment policy, and a dry
signing run in each domain — the real loader, the real Environment token, the
vault secret — signs a throwaway input and reports only the signing key's
**fingerprint** (Ed25519: its public key), which must equal the one Batch K
printed for that domain.

- **All six match:** I tell you **"cleanup authorized"** → do §11.
- **One does not** (a truncated or wrong paste still passes the
  bootstrapper's name/ID lookup): I name the domain and secret; you re-paste
  the CONTENTS of that row's file from `$KEYS` into that secret in the web
  vault (vault step 4 only — no bootstrapper run, no new token), tell me
  "re-pasted <secret>", and I re-verify that domain. Nothing is deleted until
  all six match.

(The PAT and the Cloudflare token have no local copy to lose: a wrong one is
replaced by minting a new one; they are verified by a read-only call — the PAT
reads one producer's release, the Cloudflare token reads the `porta.codes`
zone.)

## 11. Cleanup — only after I say "cleanup authorized" (§10)

```sh
rm -P "$KEYS"/* && rmdir "$KEYS"      # macOS: overwrite, then delete
unset BWS_ACCESS_TOKEN                # harmless if already unset
```

Keep no other copy of any private file or of the PAT.

## 12. Admission PRs and the required check (proved, not assumed)

`GITHUB_TOKEN` cannot open pull requests here (the repository setting that
would allow it stays off — enabling it is forbidden by blessed
`releases.release-pr@1` RP-6), and the first live admission proved it:
[run 36682670203](https://github.com/JonathanPorta/packages.porta.codes/actions/runs/36682670203)
admitted corpus v1.64.1 and then failed with *"GitHub Actions is not permitted
to create or approve pull requests"*.

Admission PRs are therefore opened by this repository's **admission-PR GitHub
App** (§14), from `admit-candidate.yml`'s `open-pr` job. A PR opened by an App
starts `pull_request` workflows, so the ruleset's required checks
(`🔎 check`, `🔁 end to end (native x86_64)`) run on their own — no close/reopen,
no personal session, no `workflow_dispatch` substitute (DocSort showed that
does not satisfy a ruleset). The App is never a reviewer, CODEOWNER or bypass
actor: review stays independent.

Proof, recorded on the first real admission PR: the PR's author is the App, and
its required checks ran on its exact head and qualified (`gh pr checks`, the
merge box). Until that is recorded, RP-6 is not claimed in `blessed.yml`.

## 13. AWS: three OIDC roles, bootstrap-owned (I run it with your SSO session)

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

## 14. GitHub Apps — one per repository and role (blessed `releases.release-pr@1` RP-6/RP-7)

Four dedicated Apps, each installed on **exactly one** repository. None exists
yet; you register them (GitHub web UI — the only way to create an App or its
key), I prepare each consumer and verify.

| App (suggested name) | Installed on (only) | Repository permissions | BWS project → machine account | Secrets (key types) | Environment (default branch only) | The ONE job that can read the key |
|---|---|---|---|---|---|---|
| `packages-porta-codes-admission-pr` | JonathanPorta/packages.porta.codes | Contents: write · Pull requests: write · Metadata: read | `packages.porta.codes-admission-pr` → `packages.porta.codes-admission-pr-ci` | `ADMISSION_PR_APP_CLIENT_ID` (`github_app_id`), `ADMISSION_PR_APP_PRIVATE_KEY` (`github_app_private_key`) | `admission-pr` | `admit-candidate.yml` → `open-pr` |
| `kioskd-release-pr` | JonathanPorta/kioskd | Contents: write · Pull requests: write · Issues: write (release-PR labels) · Metadata: read | `kioskd-release-pr` → `kioskd-release-pr-ci` | `RELEASE_PR_APP_CLIENT_ID`, `RELEASE_PR_APP_PRIVATE_KEY` | `release-pr` | `release.yml` → the release-please job |
| `corpus-release-pr` | JonathanPorta/corpus | same as kioskd | `corpus-release-pr` → `corpus-release-pr-ci` | same names | `release-pr` | `release.yml` → the release-please job |
| `keysprout-release-pr` | JonathanPorta/keysprout | same as kioskd | `keysprout-release-pr` → `keysprout-release-pr-ci` | same names | `release-pr` | `release.yml` → the release-please job |

(Names follow the dot-notation rule, blessed-cicd#313: the FQDN-named surface's
BWS project is dotted; the producers' are not FQDNs.)

**Key versus token — the boundary.** Each run mints an installation token
restricted to the current repository and exactly the role's permissions, and
revokes it at the end of the job. That restriction limits **the token only**:
any code that can read an App's **private key** can mint tokens for **every**
repository the App is installed on. The boundary is therefore who can read the
key — which is why each App is installed on one repository, and why its key is
readable only by one job: the only job that declares that Environment and loads
that loader profile, which checks out nothing but the secret loader, runs no
build, admission, packaging, RPM-finalization or candidate-signing step, and
receives what it commits (an admitted inventory, a release-please change set)
from earlier keyless jobs or the API. `tests/workflow-authority.sh` (in
`make check`) enforces this for the admission App, with a mutation control per
rule; each producer's adoption PR carries the same check.

**No sharing.** One release App shared by the three producers was considered
and rejected: its key would sit in three repositories' Environments, and a
compromise of any one producer's PR-opening job would be `contents: write` on
the other two. One App per repository costs one extra registration each and a
leaked key reaches only the repository it already serves.

**Preconditions (me, before each App is installed):** the consumer's adoption PR
is merged (its `.bws/<domain>.list/.env`, loader profile and PR-opening job
exist); its Environment exists with exactly the default branch and no secret;
and its default branch has a ruleset requiring a PR and the required checks, so
even this token cannot land a change without review (RP-7). I tell you when
each App's row is ready.

### Per App: register, key, install (GitHub web UI, ~3 minutes each)

1. <https://github.com/settings/apps/new> → **GitHub App name** from the table;
   **Homepage URL** the repository URL; **Webhook → Active: unchecked** (no URL,
   no events); **Repository permissions** exactly the table's row (everything
   else "No access"); **Where can this GitHub App be installed?** "Only on this
   account" → **Create GitHub App**.
2. On the App's General page, copy the **Client ID** (starts `Iv`) — its
   `*_APP_CLIENT_ID` value.
3. **Private keys → Generate a private key**: a `.pem` downloads. Keep it only
   until §14's verification (below).
4. **Install App** → your account → **Only select repositories** → exactly the
   table's one repository → Install. Do not add the App as a reviewer,
   CODEOWNER or ruleset bypass actor anywhere.

### Per App: the bootstrapper row (same shape as §7/§9)

In the repository's clone, on a fresh branch from `main`, with the Bitwarden
**admin** token exported (`read -rs BWS_ACCESS_TOKEN && export BWS_ACCESS_TOKEN`):

```sh
make bws-bootstrap APP_NAME=<BWS project> ARGS="--secrets-list .bws/<domain>.list --project-id-file .bws/<domain>.env --gh-environments <environment> --plan"
make bws-bootstrap APP_NAME=<BWS project> ARGS="--secrets-list .bws/<domain>.list --project-id-file .bws/<domain>.env --gh-environments <environment> --no-secret-values"
```

(`<domain>`/`<environment>`: `admission-pr` here, `release-pr` in each
producer.) When it pauses, in the web vault: machine account `<project>-ci`,
**Can read** on `<project>` only, one access token pasted at the hidden prompt
(→ that Environment's `BWS_ACCESS_TOKEN`); in the project, two secrets:

- `*_APP_CLIENT_ID` ← the Client ID from step 2;
- `*_APP_PRIVATE_KEY` ← the key **base64-encoded on one line** (the
  bootstrapper's `github_app_private_key` type; a raw multi-line PEM breaks the
  loader): `base64 -i <the .pem> | tr -d '\n' | clipcopy`, paste, then
  `pbcopy < /dev/null`.

Re-run the `--no-secret-values` line to fill the IDs; `git status --short`
shows the row's `.bws/<domain>.env` and the loader. Leave them uncommitted and
tell me "<App> done": I commit them through review, then prove the App with its
real first PR (admission: the first admission PR; producers: their first
release PR) — the PR's author is the App and its required checks ran. Only
then delete that `.pem` (`rm -P <file>.pem`).

