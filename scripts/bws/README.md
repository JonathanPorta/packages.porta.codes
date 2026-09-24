# `bws/` — Bitwarden Secrets Manager scripts

This directory is the released BWS toolkit. Consumer repos install this folder as `./scripts/bws/` at a pinned release version.

## LLM / operator start here

- Install or update this artifact: [`INSTALL.md`](INSTALL.md)
- Fleet-wide script install model and Makefile targets: [`../INSTALL.md`](../INSTALL.md)
- Secrets architecture: [`../../CENTRALIZED-SECRETS.md`](../../CENTRALIZED-SECRETS.md)
- Detailed bootstrap CLI reference: [`../../docs/CLI - BWS-BOOTSTRAP.md`](../../docs/CLI%20-%20BWS-BOOTSTRAP.md)

Do not infer current behavior from old flat script names like `bws-bootstrap.sh` or `load-bws-secrets.sh`. The canonical consumer path is `scripts/bws/`.

## Version and integrity

- `VERSION` — SemVer for the BWS artifact. Bump when this artifact changes.
- `MANIFEST.sha256` — SHA-256 manifest for shipped runtime `*.sh` files. Verify with `cd scripts/bws && shasum -a 256 -c MANIFEST.sha256` or the fleet-standard `make verify-scripts` target.
- `CHANGELOG.md` — release notes for `bws-v*` tags.

Docs such as `README.md` and `INSTALL.md` are included in the release tarball, but the manifest intentionally covers runtime shell scripts.

## Files

| File | Run how | Purpose |
|---|---|---|
| `bootstrap.sh` | execute | Idempotent wizard: creates the BWS project and secrets, sets the GitHub repo secret `BWS_ACCESS_TOKEN`, and fills placeholder UUIDs / `BWS_PROJECT_ID` in `.env-sample`, `.env`, and `.github/actions/load-secrets/action.yml`. |
| `load.sh` | source | Local-dev loader: pulls secrets from BWS and exports them into the current shell. |
| `_lib.sh` | source internally | Shared `.bws-secrets-list` parser used by both scripts. Not run directly. |
| `authority-domains.sh` | execute | Operator tool for `secrets.bwsm-authority-domains@1`: `plan`/`rotate-signing-key`/`audit`/`resume`/`install-smoke-workflow`. Resumable, dry-run, fail-closed signing-key rotation that REUSES the existing project/machine-account/Environment. Discovers topology from `blessed.yml`; **delegates key generation to the sibling `signing` category** (which must be vendored alongside). No private key or token ever on argv/logs/state/git. |
| `verify-category-manifest.sh` | execute | Category-local closed-set MANIFEST verifier that **ships inside the bws tarball** — so a consumer installed from the release archive alone (no source-tree `scripts/manifest.sh`) can verify `scripts/bws` and `scripts/signing` at rotation preflight and in the smoke workflow before the key is loaded. Verify half of `../manifest.sh`. |
| `authority-domains-test.sh` | execute | Offline test suite (88 checks, incl. a stateful fake-GitHub integration test and a clean-install test that extracts the exact release tarball layout) for the rotate + install paths. |
| `templates/authority-domain-smoke.yml.tmpl` | render | Smoke-workflow template; rendered per-repo (generic secret name from blessed.yml) by `install-smoke-workflow`. |

## `.bws-secrets-list` contract

Both scripts read the repo-root `.bws-secrets-list` when present. That file is the consumer repo's source of truth for which secrets exist.

Default static-site key set:

- `AWS_ACCESS_KEY_ID`
- `AWS_SECRET_ACCESS_KEY`
- `CLOUDFLARE_ACCOUNT_ID`
- `CLOUDFLARE_API_TOKEN`
- `BETTERUPTIME_API_TOKEN`

`SLACK_WEBHOOK_URL` is not a default. Portfolio Slack notifications flow through `github-slack-router`, not per-repo webhooks.

Format:

```text
KEY[?] [shared] [type:VALUE]
```

- `?` means optional for `load.sh` missing-key checks.
- `shared` means the value lives in `_shared-ci`, not the consumer repo's per-project BWSM project.
- `type:VALUE` selects type-specific help text during bootstrap.

## Standard consumer targets

Repos that consume this artifact should expose these target names with fleet-standard meanings:

```make
bws-bootstrap: verify-scripts ## Bootstrap BWS project + GitHub BWS_ACCESS_TOKEN
	scripts/bws/bootstrap.sh --app-name $(APP_NAME) $(ARGS)

bws-load: ## Print local shell commands for loading BWS secrets
	@echo "BWS load.sh must be sourced, not executed."
	@echo "See scripts/bws/README.md and scripts/bws/INSTALL.md."

# Release-producer repos (secrets.bwsm-authority-domains@1) also expose:
authority-plan:    ## Preview a signing-key rotation (no mutation)
	scripts/bws/authority-domains.sh plan $(ARGS)
authority-rotate:  ## Rotate the signing key (--old-key-id/--new-key-id/--reason)
	scripts/bws/authority-domains.sh rotate-signing-key $(ARGS)
authority-audit:   ## Read-only GitHub-side authority-domain conformance check
	scripts/bws/authority-domains.sh audit $(ARGS)
```

The signing-key rotation ceremony (dedicated projects/accounts/Environments,
web-vault PEM checkpoint, trust-store two-phase activation, and the smoke workflow)
is scripted by `authority-domains.sh`; see the companion smoke template
`scripts/bws/templates/authority-domain-smoke.yml.tmpl` (installed via `authority-domains.sh install-smoke-workflow`) and `standards/secrets/bwsm-authority-domains.md`.

See [`../INSTALL.md`](../INSTALL.md) for the complete fleet-wide Makefile block, including `sync-scripts`, `verify-scripts`, and the RUAM targets.

## Usage sketch

Bootstrap once per repo:

```bash
make bws-bootstrap ARGS="--scaffold --no-secret-values"
# paste skipped values in the Bitwarden web UI
make bws-bootstrap
```

`--scaffold` creates missing tracked files (`.env-sample`, the `load-secrets` action) on first run; `--no-secret-values` keeps secret values out of the process table. Both flags and the full new-repo runbook are in [`INSTALL.md`](INSTALL.md) and [`../INSTALL.md`](../INSTALL.md).

Load secrets locally by sourcing `.env-local`, setting `BWS_ACCESS_TOKEN` to the machine-account read token, and sourcing `scripts/bws/load.sh`.

Only `BWS_ACCESS_TOKEN` should be stored as a GitHub repo secret. Everything else lives in BWSM and is loaded through the repo-local `load-secrets` composite action or `scripts/bws/load.sh` locally.
