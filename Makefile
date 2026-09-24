# packages.porta.codes — the command surface (blessed makefile.core@1 plus the
# static-site plan/deploy/verify-edge verbs). CI and operators call these
# targets, never raw tools. `make help` lists the public contract.
.DEFAULT_GOAL := help
SHELL := bash

SCRIPT_CATEGORIES := bws signing release
OWN_SCRIPTS := $(wildcard scripts/surface/*.sh scripts/provision/*.sh tests/*.sh tests/lib/*.sh tests/fixtures/*.sh) scripts/sync-blessed-scripts.sh
TOOLS_IMAGE ?= ppc-tools
# Terraform acts on exactly one declared workspace; nothing is inferred.
TF_WORKSPACE ?=

.PHONY: help deps check test build clean plan deploy verify-edge validate \
	sync-scripts verify-scripts tools-image require-workspace

help: ## Show available targets
	@awk 'BEGIN {FS = ":.*##"; printf "Usage: make <target>\n\n"} /^[a-zA-Z_-]+:.*?##/ { printf "  %-16s %s\n", $$1, $$2 }' $(MAKEFILE_LIST)

deps: ## Check the local toolchain (jq, yq, shellcheck, shfmt, actionlint, terraform, docker)
	@missing=0; for t in jq yq shellcheck shfmt actionlint terraform docker; do \
	  command -v $$t >/dev/null 2>&1 || { echo "missing: $$t"; missing=1; }; done; \
	[ $$missing -eq 0 ] && echo "deps OK"

tools-image: ## Build the pinned toolchain image (tools/Dockerfile)
	docker build -q -t $(TOOLS_IMAGE) tools

check: verify-scripts validate ## Static checks: scripts, workflows, Terraform, surface and inventory
	shellcheck -x $(OWN_SCRIPTS)
	shfmt -i 2 -ci -d $(OWN_SCRIPTS)
	actionlint
	terraform fmt -check -recursive
	@if [ -d .terraform ]; then terraform validate; else echo "terraform validate: skipped (run terraform init with backend access first)"; fi

validate: ## Validate release-surfaces.yaml and, when present, the inventory
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

require-workspace:
	@[ "$(TF_WORKSPACE)" = production ] || { echo "refusing: set TF_WORKSPACE=production explicitly (this surface has one workspace)"; exit 1; }

plan: require-workspace ## Terraform plan for TF_WORKSPACE=production → plan.tmp + plan.out
	terraform init -input=false
	terraform workspace select -or-create $(TF_WORKSPACE)
	terraform plan -input=false -out=plan.tmp
	terraform show -no-color plan.tmp > plan.out

deploy: require-workspace ## Apply the reviewed plan.tmp (infrastructure only; packages are published by CI)
	@[ -f plan.tmp ] || { echo "refusing: no plan.tmp — run make plan and review plan.out first"; exit 1; }
	terraform apply -input=false plan.tmp

verify-edge: ## Read the live pointer and entrypoint headers from https://packages.porta.codes/
	curl -fsS -H 'Cache-Control: no-cache' https://packages.porta.codes/_state/generation.json | jq .
	curl -fsSI https://packages.porta.codes/keys/repository.asc | grep -iE '^(HTTP|cache-control|content-type)'
