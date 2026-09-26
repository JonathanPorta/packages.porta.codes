# Installing `bws/`

`bws/` is the Bitwarden Secrets Manager (BWSM) toolkit:

- `bootstrap.sh` — interactive bootstrap wizard for a consumer repo's BWSM project, secrets, GitHub `BWS_ACCESS_TOKEN`, and local UUID placeholders.
- `load.sh` — sourced local-development secret loader.
- `_lib.sh` — shared `.bws-secrets-list` parser used by both scripts.

Install this artifact only through the canonical runbook in [`../INSTALL.md`](../INSTALL.md). Do not install BWS with separate per-artifact target names, ad hoc tarball commands, git-subtree commands, or copied snippets from older consumer repos.

This file documents BWS-specific behavior after the artifact has been installed by the canonical flow.

## BWS prerequisites

The canonical install runbook lists all prerequisites. BWS-specific bootstrap requires:

- `bws` CLI
- `gh`, authenticated with `gh auth status`
- `jq`
- an admin/org `BWS_ACCESS_TOKEN` that can create projects and secrets

`make bws-bootstrap ARGS="--dry-run"` previews the bootstrap flow without external writes.

## Bootstrap flags

The two flags the fresh-repo flow leans on:

| Flag | What it does | When to use |
|---|---|---|
| `--scaffold` | Before the UUID-fill step, creates missing tracked target files (`.env-sample`, `.github/actions/load-secrets/action.yml`) from the active key set. Never overwrites existing files; never touches `.env`. Default off. | First bootstrap of a repo that does not have these files yet. Omit it on already-bootstrapped repos. |
| `--no-secret-values` | Creates the BWS project and GitHub `BWS_ACCESS_TOKEN` but does **not** call `bws secret create` for any value. It prints web-UI paste instructions instead. Eliminates the brief argv-exposure window. Re-run without it after pasting values. | Recommended default for human bootstrap. |

Other flags: `--dry-run` (preview, no external calls, no token needed), `--plan` (read-only inventory), `--rotate-token` (force-overwrite the GitHub `BWS_ACCESS_TOKEN`), `--rotate-secret KEY` (replace a Bitwarden secret's value in place), `--resync-deliveries` (rewrite every managed Dependabot copy), `-h`/`--help`. See `scripts/bws/bootstrap.sh --help` for the full list.

## Deployment profiles — two secret authorities in one repository

`.github/actions/load-secrets/action.yml` is used by every job that loads secrets,
including the standards job that runs on **every pull request**. Any credential it
maps is therefore handed to every pull request, and every job presents the same
repository-scoped `BWS_ACCESS_TOKEN`, whose machine account can read the whole
project. For a repository that also deploys, that is one authority doing two jobs.

Four opt-in options let a repository run bootstrap a second time to build a
separate, deploy-only authority. `--app-name` already changes the project and
machine-account names, so nothing new was needed for those.

| Option | Effect |
|---|---|
| `--secrets-list PATH` | Read the key declaration from `PATH`. Explicit flag form of the existing `BWS_SECRETS_LIST_FILE`. |
| `--loader PATH` | Write the generated loader to `PATH`, so the second profile cannot overwrite the first profile's loader. |
| `--project-id-file PATH` | Keep this profile's `BWS_PROJECT_ID` out of `.env-sample`. |
| `--gh-environments a,b,c` | Set `BWS_ACCESS_TOKEN` as a GitHub **Environment** secret in each named environment instead of a repository secret. |

A GitHub Environment secret overrides a repository secret for jobs that declare
`environment:`, so both tokens live under the same approved name and only the
deploy job resolves the deploy one.

**The environment path never touches the repository-scoped secret** — a deployment
profile cannot rotate or overwrite the validation token. Environments must already
exist; a missing one is reported and skipped rather than created.

Example — validation profile first (the ordinary invocation), then deployment:

```bash
# 1. validation authority: repo-scoped token, BLESSED_CICD_TOKEN only
make bws-bootstrap ARGS="--no-secret-values"

# 2. deployment authority: its own project, machine account, declaration,
#    loader, project-id file, and environment-scoped token
make bws-bootstrap ARGS="--no-secret-values \
  --app-name <repo>-deploy \
  --secrets-list .bws-secrets-list.deploy \
  --loader .github/actions/load-deploy-secrets/action.yml \
  --project-id-file .env-deploy-sample \
  --gh-environments development,staging,production"
```

Grant the deploy machine account read on its own project **and** on `_shared-ci`
if the deployment declaration marks any key `shared`. Do **not** grant the
validation machine account access to the deployment project — that is the whole
point of the split.

Omitting all four options reproduces the previous single-profile behaviour
exactly; `tests/test-bws-deploy-profile.sh` asserts that.

Under `--test-scaffold-to`, `--loader` and `--project-id-file` must be relative
paths beneath the test root. An absolute or parent-traversing value is refused
before any file is created — it would escape the scratch directory the option
exists to confine writes to.

## Bootstrap flow

Use the **New repo, end to end** runbook in [`../INSTALL.md`](../INSTALL.md). The BWS-specific portion is:

```bash
export BWS_ACCESS_TOKEN='<admin/org Bitwarden Secrets Manager token>'
make bws-bootstrap APP_NAME=example.com ARGS="--scaffold --no-secret-values"
# paste skipped values into the Bitwarden web UI
make bws-bootstrap APP_NAME=example.com
make verify-scripts
```

That first pass creates the BWSM project, sets the GitHub repo's `BWS_ACCESS_TOKEN`, and scaffolds safe tracked files without passing secret values through `bws secret create` argv.

Review and commit the tracked outputs through the root runbook. Never commit `.env` or `.env-local`.

## CI usage

`--scaffold` creates `.github/actions/load-secrets/action.yml` from the active key set. That generated composite action is the only place workflow UUIDs should live.

Workflow files should call the repo-local composite action:

```yaml
- name: 🔐 Load Secrets from Bitwarden
  uses: ./.github/actions/load-secrets
  with:
    access_token: ${{ secrets.BWS_ACCESS_TOKEN }}
```

After this step, the BWS secrets listed in `.github/actions/load-secrets/action.yml` are available to later workflow steps as environment variables.

Do not duplicate `bitwarden/sm-action` blocks in each workflow. Do not paste UUIDs into workflow files.

## Non-static-site consumers

The default BWS key set is the static-site portfolio set. If a repo needs a different set, create `.bws-secrets-list` **before** running `bws-bootstrap`.

Format:

```text
KEY[?] [shared] [type:VALUE]
```

Example:

```text
RELEASE_TOKEN        type:github_pat
OPENAI_API_KEY?      type:openai_key
CLOUDFLARE_ACCOUNT_ID shared type:cloudflare_account_id
```

`bootstrap.sh` and `load.sh` use the same parser, so this file is the consumer repo's source of truth for both secret creation and local loading.

## Managed Dependabot delivery

Dependabot cannot read Bitwarden: the credentials it uses for private
registries are GitHub **Dependabot secrets**, a namespace separate from Actions
secrets that no workflow job can see. A key that Dependabot needs is declared
with a managed delivery:

```text
BLESSED_CICD_DEPENDABOT_TOKEN type:github_pat owner:JonathanPorta repos:JonathanPorta/blessed-cicd perms:contents=read expires:90d consumers:.github/dependabot.yml deliver:dependabot@JonathanPorta/example
```

Bitwarden stays the authoritative store; `bootstrap.sh` keeps the Dependabot
secret (same name, in the named repository) as a **verified copy**:

| Run | Behaviour |
|---|---|
| `make bws-bootstrap ARGS="--dry-run"` | Prints the delivery plan; no external call. |
| `make bws-plan` | Reports whether the copy is absent / up-to-date / behind the Bitwarden revision, and the recorded expiry state, without reading the value. |
| `make bws-bootstrap` | Creates the Bitwarden secret if missing (hidden prompt, `$KEY`, or vault paste with `--no-secret-values`), proves a `github_pat` can authenticate as its `owner:` and read every `repos:` entry, records the GitHub-reported expiry in the secret note, then writes the copy **only** when it is absent or older than the Bitwarden revision, and verifies the write. Re-runs write nothing. |
| `make bws-bootstrap ARGS="--rotate-secret KEY"` | Replaces the Bitwarden value in place (UUID kept) and re-delivers in the same run. |
| `make bws-bootstrap ARGS="--resync-deliveries"` | Forces every copy to be rewritten from Bitwarden. |

The destination must be the repository the wizard runs in — any other
`OWNER/REPO` is refused before anything is mutated. An unreadable destination
is `UNOBSERVABLE` (nothing written, exit 1); a token that fails its probe is
`BLOCKED` and not delivered. The value only ever travels
`bws secret get | jq | gh secret set` and `curl --config -` on stdin.

When **every** declared key is a managed delivery the repository has no Actions
consumer: the machine account, `BWS_ACCESS_TOKEN` and the generated loader are
reported `not applicable` and never created, and pull-request CI stays
secret-free. A mixed declaration keeps the loader for the loader keys only;
`load.sh` reports delivered keys as "not loaded".

## Shared secrets

Keys marked `shared` live in `_shared-ci`, not the consumer repo's per-project BWSM project. `bootstrap.sh` skips creating those keys and reminds the operator to grant the machine account read access to `_shared-ci`.

If CI or local loads cannot read shared values, check the machine account's project grants before rotating anything.

## Local loading

`load.sh` must be sourced, not executed. Use the fleet-standard target to print the exact commands:

```bash
make bws-load
```

The standard output is:

```bash
source ./.env-local
export BWS_ACCESS_TOKEN=<machine-account-read-token>
source scripts/bws/load.sh
```

The loader exports required secrets into the current shell and unsets `AWS_PROFILE` so Terraform/AWS SDK calls use BWS-provided env credentials instead of an accidental local profile.

## Updating BWS

Use the root update flow in [`../INSTALL.md`](../INSTALL.md#updating-an-existing-consumer): bump `scripts/.bws-scripts-version`, run `make sync-scripts`, run `make verify-scripts`, and commit.

Do not hand-edit installed `scripts/bws/*.sh` files in a consumer repo. Make the change in `blessed-cicd`, cut a BWS release, then bump the consumer pin.
