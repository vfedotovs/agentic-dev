# agentic-dev — build, run, and operate the pipeline.
# `make` with no target prints help. Override any variable on the command line,
# e.g.  make slice ENV_FILE=./agentic-dev.env IMAGE=agentic-dev:dev

# One image per agent backend. AGENT_BACKEND picks which one the run targets
# use; CLAUDE_IMAGE is also tagged agentic-dev:latest so cron installs that
# still reference the old tag keep working untouched.
AGENT_BACKEND       ?= claude
CLAUDE_IMAGE        ?= agentic-dev:claude-latest
GROK_IMAGE          ?= agentic-dev:grok-latest
LEGACY_IMAGE        ?= agentic-dev:latest
IMAGE               ?= $(if $(filter grok,$(AGENT_BACKEND)),$(GROK_IMAGE),$(CLAUDE_IMAGE))
CLAUDE_CODE_VERSION ?= latest
GROK_CLI_VERSION    ?=
ENV_FILE            ?= /etc/agentic-dev/agentic-dev.env
RUNS_DIR           ?= /var/lib/agentic-dev/runs
LOG_DIR            ?= /var/log/agentic-dev
CRON_USER          ?= agentic
PLAN               ?= examples/plan.md
STAGE              ?= write-tests

HOST_RUN := $(CURDIR)/agentic/host/run-stage.sh
SCRIPTS  := $(wildcard agentic/entrypoint/*.sh agentic/host/*.sh agentic/lib/*.sh)
RUN_ENV  := AGENTIC_ENV_FILE=$(ENV_FILE) AGENTIC_IMAGE=$(IMAGE) AGENTIC_RUNS_DIR=$(RUNS_DIR) AGENT_BACKEND=$(AGENT_BACKEND)
REPO     ?= $(shell sh -c '. $(ENV_FILE) 2>/dev/null && echo $$REPO')

.DEFAULT_GOAL := help
.PHONY: help build build-claude build-grok build-all \
        rebuild rebuild-claude rebuild-grok rebuild-all lint parse \
        slice slice-dry write-tests implement gc gc-apply run-issue \
        status logs phase watch labels install-cron uninstall-cron pause resume clean

help: ## Show this help
	@grep -hE '^[a-zA-Z0-9_-]+:.*?## ' $(MAKEFILE_LIST) \
	  | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

## --- build ---------------------------------------------------------------

build: build-claude ## Build the default (Claude) image

build-claude: ## Build the Claude image (CLAUDE_CODE_VERSION=x.y.z to pin the CLI)
	docker build --build-arg AGENT_BACKEND=claude \
	  --build-arg CLAUDE_CODE_VERSION=$(CLAUDE_CODE_VERSION) \
	  -t $(CLAUDE_IMAGE) -t $(LEGACY_IMAGE) .

build-grok: ## Build the Grok image (GROK_CLI_VERSION=x.y.z to pin the CLI)
	docker build --build-arg AGENT_BACKEND=grok \
	  --build-arg GROK_CLI_VERSION=$(GROK_CLI_VERSION) \
	  -t $(GROK_IMAGE) .

build-all: build-claude build-grok ## Build both backend images

rebuild: rebuild-claude ## Rebuild the default (Claude) image from scratch

rebuild-claude: ## Build the Claude image from scratch (--no-cache)
	docker build --no-cache --build-arg AGENT_BACKEND=claude \
	  --build-arg CLAUDE_CODE_VERSION=$(CLAUDE_CODE_VERSION) \
	  -t $(CLAUDE_IMAGE) -t $(LEGACY_IMAGE) .

rebuild-grok: ## Build the Grok image from scratch (--no-cache)
	docker build --no-cache --build-arg AGENT_BACKEND=grok \
	  --build-arg GROK_CLI_VERSION=$(GROK_CLI_VERSION) \
	  -t $(GROK_IMAGE) .

rebuild-all: rebuild-claude rebuild-grok ## Rebuild both backend images from scratch

## --- checks --------------------------------------------------------------

lint: ## Syntax-check every script (shellcheck too, if installed)
	@for f in $(SCRIPTS); do bash -n "$$f" && echo "bash -n   ok: $$f"; done
	@if command -v shellcheck >/dev/null; then shellcheck -x -P SCRIPTDIR $(SCRIPTS) && echo "shellcheck ok"; \
	 else echo "shellcheck not installed; skipped"; fi
	@for f in agentic/lib/*.py; do python3 -m py_compile "$$f" && echo "py_compile ok: $$(basename $$f)"; done

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
	  -e REPO -e GH_TOKEN -e ISSUE=$(ISSUE) \
	  -e AGENT_BACKEND=$(AGENT_BACKEND) -e ANTHROPIC_API_KEY -e XAI_API_KEY -e GROK_MODEL \
	  -e AGENT_MAX_TURNS -e CLAUDE_MAX_TURNS \
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

phase: ## Show what every run today is doing right now (STAGE=... to filter one)
	@d=$(RUNS_DIR); today=$$(date +%F); found=0; \
	for p in $$d/*/$$today/*/phase; do \
	  [ -e "$$p" ] || continue; \
	  run=$$(dirname $$p); stage=$$(basename $$(dirname $$(dirname $$run))); \
	  case "$(STAGE)" in "") ;; $$stage) ;; *) continue ;; esac; \
	  found=1; \
	  printf '%-12s %-6s %-16s %s\n' "$$stage" "$$(basename $$run)" "$$(cat $$p)" \
	    "last change $$(( ($$(date +%s) - $$(date -r $$p +%s)) ))s ago"; \
	done; \
	[ $$found = 1 ] || echo "no runs recorded under $$d for $$today"

watch: ## Follow one run's phase trail (STAGE=implement ISSUE=42)
	@test -n "$(ISSUE)" || { echo "usage: make watch STAGE=<stage> ISSUE=<n>"; exit 2; }
	tail -n +1 -F $(RUNS_DIR)/$(STAGE)/$$(date +%F)/$(ISSUE)/phases.jsonl

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
