# agentic-dev:latest — disposable runner for all three pipeline stages.
#
#   docker build -t agentic-dev:latest .
#
# One container does one unit of work (Stage 1 once/day; Stage 2/3 one issue
# each) then exits. It is given only: env vars for auth, a network policy, and a
# write-through mount at /runs. No source is baked in — every run clones fresh.

FROM python:3.12-slim

ARG CLAUDE_CODE_VERSION=latest
ARG NODE_MAJOR=20
ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    AGENT_WORKDIR=/work \
    RUNS_DIR=/runs

# --- system deps: git, gh CLI, node (for the Claude Code CLI), jq -------------
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        ca-certificates curl gnupg git jq coreutils tini; \
    install -m 0755 -d /etc/apt/keyrings; \
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        -o /etc/apt/keyrings/githubcli-archive-keyring.gpg; \
    chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg; \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
        > /etc/apt/sources.list.d/github-cli.list; \
    curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | bash -; \
    apt-get update; \
    apt-get install -y --no-install-recommends gh nodejs; \
    npm install -g "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}"; \
    npm cache clean --force; \
    apt-get purge -y gnupg; apt-get autoremove -y; \
    rm -rf /var/lib/apt/lists/*

# --- python tooling used by the Stage 3 acceptance gate ----------------------
RUN pip install --no-cache-dir \
        pytest pytest-cov coverage ruff black mypy

# --- pipeline scripts -------------------------------------------------------
COPY agentic/ /opt/agentic/
RUN chmod +x /opt/agentic/entrypoint/*.sh /opt/agentic/lib/*.sh /opt/agentic/lib/*.py \
 && useradd -m -u 10001 -s /bin/bash agent \
 && mkdir -p /work /runs \
 && chown agent:agent /work /runs

ENV PATH="/opt/agentic/entrypoint:${PATH}"
USER agent
WORKDIR /work

# `tini` reaps the Claude/pytest child tree cleanly on SIGKILL from budget_guard.
ENTRYPOINT ["/usr/bin/tini", "--"]
# No CMD: the launcher passes the stage entrypoint, e.g.
#   docker run ... agentic-dev:latest slice.sh
#   docker run ... -e ISSUE=42 agentic-dev:latest write-tests.sh
#   docker run ... -e ISSUE=42 agentic-dev:latest implement.sh
