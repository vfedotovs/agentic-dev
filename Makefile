# agentic-dev — build, run, and operate the pipeline.
# `make` with no target prints help. Override any variable on the command line,
# e.g.  make slice ENV_FILE=./agentic-dev.env IMAGE=agentic-dev:dev

IMAGE               ?= agentic-dev:latest
CLAUDE_CODE_VERSION ?= latest
ENV_FILE            ?= /etc/agentic-dev/agentic-dev.env
RUNS_DIR           ?= /var/lib/agentic-dev/runs
LOG_DIR            ?= /var/log/agentic-dev
CRON_USER          ?= agentic
PLAN               ?= examples/plan.md
STAGE              ?= write-tests

HOST_RUN := $(CURDIR)/agentic/host/run-stage.sh
SCRIPTS  := $(wildcard agentic/entrypoint/*.sh agentic/host/*.sh agentic/lib/*.sh)
RUN_ENV  := AGENTIC_ENV_FILE=$(ENV_FILE) AGENTIC_IMAGE=$(IMAGE) AGENTIC_RUNS_DIR=$(RUNS_DIR)
REPO     ?= $(shell sh -c '. $(ENV_FILE) 2>/dev/null && echo $$REPO')

.DEFAULT_GOAL := help
.PHONY: help build rebuild lint parse \
        slice slice-dry write-tests implement gc gc-apply run-issue \
        status logs labels install-cron uninstall-cron pause resume clean

help: ## Show this help
	@grep -hE '^[a-zA-Z0-9_-]+:.*?## ' $(MAKEFILE_LIST) \
	  | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2}'

## --- build ---------------------------------------------------------------

build: ## Build the agentic-dev image (CLAUDE_CODE_VERSION=x.y.z to pin the CLI)
	docker build --build-arg CLAUDE_CODE_VERSION=$(CLAUDE_CODE_VERSION) -t $(IMAGE) .

rebuild: ## Build the image from scratch (--no-cache)
	docker build --no-cache --build-arg CLAUDE_CODE_VERSION=$(CLAUDE_CODE_VERSION) -t $(IMAGE) .

## --- checks --------------------------------------------------------------

lint: ## Syntax-check every script (shellcheck too, if installed)
	@for f in $(SCRIPTS); do bash -n "$$f" && echo "bash -n   ok: $$f"; done
	@if command -v shellcheck >/dev/null; then shellcheck -x $(SCRIPTS) && echo "shellcheck ok"; \
	 else echo "shellcheck not installed; skipped"; fi
	@python3 -m py_compile agentic/lib/parse_plan.py && echo "py_compile ok: parse_plan.py"

parse: ## Run the plan.md parser (PLAN=path/to/plan.md)
	python3 agentic/lib/parse_plan.py $(PLAN)

## --- run stages (via the host launcher; honours MAX_PER_DAY) ------------

slice: ## Stage 1 — slice plan.md into issues
	$(RUN_ENV) $(HOST_RUN) slice

slice-dry: ## Stage 1 dry run — print planned issues, create none
	$(RUN_ENV) SLICER_DRY_RUN=1 $(HOST_RUN) slice

write-tests: ## Stage 2 — write failing tests for up to MAX_PER_DAY issues
	$(RUN_ENV) $(HOST_RUN) write-tests

implement: ## Stage 3 — implement + open PRs for up to MAX_PER_DAY issues
	$(RUN_ENV) $(HOST_RUN) implement

gc: ## Housekeeping, dry run (report only)
	$(RUN_ENV) GC_DRY_RUN=1 $(HOST_RUN) gc

gc-apply: ## Housekeeping, for real (close/delete stale branches & PRs)
	$(RUN_ENV) GC_DRY_RUN=0 $(HOST_RUN) gc

run-issue: ## Debug one issue in a throwaway container (STAGE=write-tests ISSUE=42)
	@test -n "$(ISSUE)" || { echo "usage: make run-issue STAGE=<write-tests|implement> ISSUE=<n>"; exit 2; }
	@set -a; . $(ENV_FILE); set +a; \
	docker run --rm -it \
	  -e REPO -e GH_TOKEN -e ANTHROPIC_API_KEY -e ISSUE=$(ISSUE) \
	  -e RUNS_DIR=/runs -v $(RUNS_DIR):/runs \
	  $(IMAGE) $(STAGE).sh

## --- operations --------------------------------------------------------

status: ## Show pipeline state from GitHub (needs REPO or a readable ENV_FILE)
	@test -n "$(REPO)" || { echo "set REPO=owner/name (or make ENV_FILE readable)"; exit 2; }
	@echo "== needs-tests ==";  gh issue list --repo $(REPO) --label needs-tests
	@echo "== tests-ready ==";  gh issue list --repo $(REPO) --label tests-ready
	@echo "== in-progress ==";  gh issue list --repo $(REPO) --label in-progress
	@echo "== agent PRs ==";    gh pr list    --repo $(REPO) --label agent-pr-open
	@echo "== failed/stale =="; gh issue list --repo $(REPO) --state all --label agent-failed --label agent-stale

logs: ## Tail the stage logs
	tail -n 40 -F $(LOG_DIR)/*.log

labels: ## Create the pipeline labels in REPO (idempotent)
	@test -n "$(REPO)" || { echo "set REPO=owner/name"; exit 2; }
	@for l in agent-generated needs-tests tests-ready in-progress agent-pr-open \
	          agent-failed agent-stale agent-skip needs-triage \
	          feature bug refactor docs chore; do \
	  gh label create "$$l" --repo $(REPO) --force; \
	done

install-cron: ## Install the crontab for CRON_USER (run as root)
	crontab -u $(CRON_USER) agentic/host/crontab
	crontab -u $(CRON_USER) -l

uninstall-cron: ## Remove CRON_USER's crontab (run as root)
	crontab -u $(CRON_USER) -r

pause: ## Set AGENTIC_DISABLED=1 in ENV_FILE
	sed -i 's/^AGENTIC_DISABLED=.*/AGENTIC_DISABLED=1/' $(ENV_FILE) && echo "pipeline paused"

resume: ## Set AGENTIC_DISABLED=0 in ENV_FILE
	sed -i 's/^AGENTIC_DISABLED=.*/AGENTIC_DISABLED=0/' $(ENV_FILE) && echo "pipeline resumed"

clean: ## Remove local build artifacts (not runs/ or logs)
	rm -rf agentic/lib/__pycache__
