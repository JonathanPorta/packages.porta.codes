# packages.porta.codes — the command surface. CI and operators call these
# targets, never raw tools. A target is public iff it carries a `## ` help
# description, so `make help` IS the contract:
#
#   makefile.core@1           help deps install dev format check test build docs clean
#   makefile.profiles@1       static site: plan deploy verify-edge
#   makefile.capability-verbs blessed scripts: sync-scripts verify-scripts
#                             Bitwarden Secrets Manager: bws-bootstrap bws-load
#
# There is no RUAM user and no AWS key: every AWS call runs as a GitHub OIDC
# role session (blessed-cicd #9). The roles are bootstrap-owned
# (scripts/provision/aws-oidc-bootstrap.sh, operator SSO; #239).
#
# This is a superset of the static-site class surface (blessed-cicd
# templates/Makefile: build check clean deploy dev help plan test verify-edge).
# `validate` and `tools-image` are internal.
.DEFAULT_GOAL := help
SHELL := bash

SCRIPT_CATEGORIES := bws signing release
OWN_SCRIPTS := $(wildcard scripts/surface/*.sh scripts/provision/*.sh tests/*.sh tests/lib/*.sh tests/fixtures/*.sh) scripts/sync-blessed-scripts.sh
TOOLS_IMAGE ?= ppc-tools
# The default BWS domain's project is `packages.porta.codes` (machine account
# packages.porta.codes-ci): Cloudflare only. Other domains pass their own
# APP_NAME and ARGS (PROVISIONING.md).
APP_NAME ?= $(notdir $(CURDIR))

.PHONY: help deps install dev format check test build docs clean plan deploy verify-edge \
	sync-scripts verify-scripts bws-bootstrap bws-load \
	validate tools-image

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
	bash scripts/provision/aws-oidc-bootstrap.sh --self-test
	bash tests/aws-oidc-bootstrap-env.sh
	bash tests/bws-loader-bootstrap.sh
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

bws-bootstrap: verify-scripts ## Bootstrap a BWS authority domain (default: APP_NAME=packages.porta.codes, repo-level token); others: APP_NAME=… ARGS="…" (PROVISIONING.md)
	scripts/bws/bootstrap.sh --app-name $(APP_NAME) $(ARGS)

bws-load: ## Print local shell commands for loading BWS secrets
	@echo "BWS load.sh must be sourced, not executed. The default domain (Cloudflare only):"
	@echo "    read -rs BWS_ACCESS_TOKEN && export BWS_ACCESS_TOKEN   # the packages.porta.codes-ci token"
	@echo "    source scripts/bws/load.sh"
	@echo "Any other domain: BWS_SECRETS_LIST_FILE=.bws/<domain>.list source scripts/bws/load.sh"
	@echo "See scripts/bws/README.md and PROVISIONING.md."

# Terraform runs in CI (terraform-plan.yml / terraform-apply.yml) with GitHub
# OIDC roles — no AWS key exists for this stack (blessed-cicd #9). These targets
# use whatever credentials the environment already holds: the job's role
# session and the Cloudflare token the load-secrets action exported. One
# workspace: the default (backend.tf).
export TF_VAR_cloudflare_account_id ?= $(CLOUDFLARE_ACCOUNT_ID)

plan: ## Terraform plan (read-only, no state lock) → plan.tmp + plan.out
	terraform init -input=false
	terraform plan -input=false -lock=false -out=plan.tmp
	terraform show -no-color plan.tmp > plan.out

deploy: ## Apply exactly the reviewed plan.tmp (infrastructure only; packages are published by CI)
	@[ -f plan.tmp ] || { echo "refusing: no plan.tmp — apply only a reviewed plan (terraform-apply.yml)"; exit 1; }
	terraform init -input=false
	terraform apply -input=false plan.tmp

verify-edge: ## Live edge as approved: route fails closed, entrypoints routed no-cache, v2 pointer (needs CLOUDFLARE_API_TOKEN)
	@bash scripts/surface/verify-edge.sh
