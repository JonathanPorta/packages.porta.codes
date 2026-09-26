# packages.porta.codes — the command surface. CI and operators call these
# targets, never raw tools. A target is public iff it carries a `## ` help
# description, so `make help` IS the contract:
#
#   makefile.core@1           help deps install dev format check test build docs clean
#   makefile.profiles@1       static site: plan deploy verify-edge
#   makefile.capability-verbs blessed scripts: sync-scripts verify-scripts
#                             Bitwarden Secrets Manager: bws-bootstrap bws-load
#
# This is a superset of the static-site class surface (blessed-cicd
# templates/Makefile: build check clean deploy dev help plan test verify-edge).
# `validate`, `tools-image`, `cloudflare-token` and `require-workspace` are
# internal.
.DEFAULT_GOAL := help
SHELL := bash

SCRIPT_CATEGORIES := bws signing release
OWN_SCRIPTS := $(wildcard scripts/surface/*.sh scripts/provision/*.sh tests/*.sh tests/lib/*.sh tests/fixtures/*.sh) scripts/sync-blessed-scripts.sh
TOOLS_IMAGE ?= ppc-tools
# Terraform acts on exactly one declared workspace; nothing is inferred.
TF_WORKSPACE ?=

.PHONY: help deps install dev format check test build docs clean plan deploy verify-edge \
	sync-scripts verify-scripts bws-bootstrap bws-load \
	validate cloudflare-token tools-image require-workspace

help: ## Show available targets
	@awk 'BEGIN {FS = ":.*##"; printf "Usage: make <target>\n\n"} /^[a-zA-Z_-]+:.*?##/ { printf "  %-16s %s\n", $$1, $$2 }' $(MAKEFILE_LIST)

install: deps ## Developer setup: verify the toolchain (this repo installs no hooks or local tools)
	@echo "install: nothing further to install; see README for the toolchain."

dev: ## No interactive loop: a static repository has no server here — use `make test` (offline end to end)
	@echo "dev: this repository has no local server; 'make test' runs admission → publication → real clients offline."

format: ## Apply formatting: shfmt to this repo's scripts, terraform fmt
	shfmt -i 2 -ci -w $(OWN_SCRIPTS)
	terraform fmt -recursive

docs: ## Validate the operator docs: every relative link in the top-level Markdown resolves
	@rc=0; for f in *.md; do \
	  for l in $$(grep -oE '\]\([^)]+\)' "$$f" | sed -E 's/^\]\(//; s/\)$$//; s/#.*//' | grep -v -e '://' -e '^mailto:' -e '^$$' | sort -u); do \
	    [ -e "$$l" ] || { echo "$$f: broken link $$l"; rc=1; }; \
	  done; \
	done; if [ $$rc -eq 0 ]; then echo "docs: all relative links resolve"; fi; exit $$rc

deps: ## Check the local toolchain (jq, yq, shellcheck, shfmt, actionlint, terraform, docker)
	@missing=0; for t in jq yq shellcheck shfmt actionlint terraform docker; do \
	  command -v $$t >/dev/null 2>&1 || { echo "missing: $$t"; missing=1; }; done; \
	[ $$missing -eq 0 ] && echo "deps OK"

# Internal: build the pinned toolchain image (tools/Dockerfile).
tools-image:
	docker build -q -t $(TOOLS_IMAGE) tools

check: verify-scripts validate ## Static checks: scripts, workflows, Terraform, surface and inventory
	shellcheck -x $(OWN_SCRIPTS)
	shfmt -i 2 -ci -d $(OWN_SCRIPTS)
	actionlint
	terraform fmt -check -recursive
	@if [ -d .terraform ]; then terraform validate; else echo "terraform validate: skipped (run terraform init with backend access first)"; fi

# Internal (called by check): release-surfaces.yaml and, when present, the inventory.
validate:
	bash scripts/release/validate-surfaces.sh --file release-surfaces.yaml
	@if [ -f inventory/inventory.json ]; then bash scripts/release/validate-package-inventory.sh --file inventory/inventory.json; \
	else echo "inventory/inventory.json: none yet (created by the first admission)"; fi

test: ## End to end, offline: admission → publication → real apt/dnf clients (needs docker)
	bash tests/e2e.sh

build: ## Nothing to build: generations are produced by the publish workflow
	@echo "No build output: the repository is generated from inventory/ by .github/workflows/publish.yml."

clean: ## Remove local scratch state
	rm -rf tmp .terraform plan.tmp plan.out

sync-scripts: ## Reinstall scripts/{bws,signing,release} from the pinned blessed-cicd releases
	scripts/sync-blessed-scripts.sh

verify-scripts: ## Verify vendored blessed-cicd scripts against their MANIFEST.sha256
	@rc=0; for c in $(SCRIPT_CATEGORIES); do \
	  if ( cd scripts/$$c && shasum -a 256 -c MANIFEST.sha256 >/dev/null 2>&1 ); then \
	    echo "scripts/$$c v$$(cat scripts/$$c/VERSION): OK"; \
	  else echo "scripts/$$c: DRIFT — files differ from MANIFEST.sha256"; rc=1; fi; \
	done; exit $$rc

bws-bootstrap: verify-scripts ## Bootstrap one authority domain: APP_NAME=<BWS project> ARGS="--secrets-list … --project-id-file … --gh-environments …" (PROVISIONING.md §4)
	@if [ -z "$(APP_NAME)" ] || [ -z "$(ARGS)" ]; then echo "refusing: set APP_NAME and ARGS — this repo has no default domain; see PROVISIONING.md §4"; exit 1; fi
	scripts/bws/bootstrap.sh --app-name $(APP_NAME) $(ARGS)

bws-load: ## Print how to load a domain's secrets locally (this repo's secrets are CI-only)
	@echo "Every secret here belongs to a CI-only authority domain (repository-signing,"
	@echo "candidate-ingest) and is loaded in CI by .github/actions/load-secrets with its"
	@echo "profile. None is needed locally. To inspect a domain as the operator:"
	@echo "    export BWS_ACCESS_TOKEN=<that domain's read token>   # hidden: read -rs BWS_ACCESS_TOKEN"
	@echo "    BWS_SECRETS_LIST_FILE=.bws/<domain>.list source scripts/bws/load.sh"

require-workspace:
	@[ "$(TF_WORKSPACE)" = production ] || { echo "refusing: set TF_WORKSPACE=production explicitly (this surface has one workspace)"; exit 1; }

# Operator credentials for plan/deploy/verify-edge, never in files, arguments or
# logs: AWS from the SSO profile, Cloudflare from the macOS keychain item that
# `make cloudflare-token` stores through a hidden prompt.
AWS_PROFILE ?= portaj
CF_KEYCHAIN_ITEM := packages-porta-codes-terraform-cloudflare
WITH_CREDS = AWS_PROFILE=$(AWS_PROFILE) CLOUDFLARE_API_TOKEN="$${CLOUDFLARE_API_TOKEN:-$$(security find-generic-password -s $(CF_KEYCHAIN_ITEM) -w 2>/dev/null)}"

# Internal operator helper: store the operator's Cloudflare API token in the
# macOS keychain through a hidden prompt (read by plan, deploy and verify-edge).
cloudflare-token:
	@security add-generic-password -U -s $(CF_KEYCHAIN_ITEM) -a terraform -w
	@echo "stored in keychain item $(CF_KEYCHAIN_ITEM)"

plan: require-workspace ## Terraform plan for TF_WORKSPACE=production → plan.tmp + plan.out
	@aws sts get-caller-identity --profile $(AWS_PROFILE) >/dev/null 2>&1 || { echo "refusing: AWS profile $(AWS_PROFILE) has no session — run: aws sso login --profile $(AWS_PROFILE)"; exit 1; }
	@security find-generic-password -s $(CF_KEYCHAIN_ITEM) >/dev/null 2>&1 || [ -n "$${CLOUDFLARE_API_TOKEN:-}" ] || { echo "refusing: no Cloudflare token — run: make cloudflare-token"; exit 1; }
	$(WITH_CREDS) terraform init -input=false
	$(WITH_CREDS) terraform workspace select -or-create $(TF_WORKSPACE)
	$(WITH_CREDS) terraform plan -input=false -out=plan.tmp
	$(WITH_CREDS) terraform show -no-color plan.tmp > plan.out

deploy: require-workspace ## Apply the reviewed plan.tmp (infrastructure only; packages are published by CI)
	@[ -f plan.tmp ] || { echo "refusing: no plan.tmp — run make plan and review plan.out first"; exit 1; }
	$(WITH_CREDS) terraform apply -input=false plan.tmp

verify-edge: ## Live edge as approved: route fails closed, entrypoints routed no-cache, v2 pointer (CLOUDFLARE_API_TOKEN: Workers Routes Read)
	@$(WITH_CREDS) bash scripts/surface/verify-edge.sh
