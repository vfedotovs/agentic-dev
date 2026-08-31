# agentic-dev — disposable runner for all three pipeline stages.
#
#   docker build --build-arg AGENT_BACKEND=claude -t agentic-dev:claude-latest .
#   docker build --build-arg AGENT_BACKEND=grok   -t agentic-dev:grok-latest   .
#
# One image carries one agent runtime. AGENT_BACKEND selects which CLI is
# installed and is baked into the image as the runtime default, so a container
# can never disagree with the binary it actually contains.
#
# One container does one unit of work (Stage 1 once/day; Stage 2/3 one issue
# each) then exits. It is given only: env vars for auth, a network policy, and a
# write-through mount at /runs. No source is baked in — every run clones fresh.

FROM python:3.12-slim

ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    AGENT_WORKDIR=/work \
    RUNS_DIR=/runs

# --- system deps: git, gh CLI, jq -------------------------------------------
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
    apt-get update; \
    apt-get install -y --no-install-recommends gh; \
    rm -rf /var/lib/apt/lists/*

# --- python tooling used by the Stage 3 acceptance gate ----------------------
RUN pip install --no-cache-dir \
        pytest pytest-cov coverage ruff black mypy

# --- agent runtime: exactly one of the two backends -------------------------
#
# claude: Node + the npm package, as before.
# grok:   the prebuilt binary from x.ai/cli/install.sh, installed under a
#         dedicated HOME=/opt/grok so the installer's sibling
#         bin/ -> downloads/ symlink layout stays intact and stays readable by
#         the unprivileged runtime user. The installer writes an auth.json only
#         when GROK_DEPLOYMENT_KEY is set — it is not, so XAI_API_KEY is what
#         authenticates at runtime (a stored session token would outrank it).
#         The `test ! -e` below turns that into a build-time assertion.
#
# Keep comments out of the RUN itself: the Dockerfile parser joins `\`-continued
# lines before the shell sees them, so an inline `#` would comment out the rest.
#
# These ARGs are declared here, not at the top, so everything above stays
# backend-independent and `make build-all` reuses one cached base + pip layer.
ARG AGENT_BACKEND=claude
ARG CLAUDE_CODE_VERSION=latest
ARG GROK_CLI_VERSION=
ARG NODE_MAJOR=20
RUN set -eux; \
    case "$AGENT_BACKEND" in \
      claude) \
        curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | bash -; \
        apt-get install -y --no-install-recommends nodejs; \
        npm install -g "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}"; \
        npm cache clean --force; \
        claude --version; \
        ;; \
      grok) \
        mkdir -p /opt/grok; \
        curl -fsSL https://x.ai/cli/install.sh -o /tmp/grok-install.sh; \
        HOME=/opt/grok bash /tmp/grok-install.sh ${GROK_CLI_VERSION:+"$GROK_CLI_VERSION"}; \
        rm -f /tmp/grok-install.sh; \
        ln -sf /opt/grok/.grok/bin/grok /usr/local/bin/grok; \
        chmod -R a+rX /opt/grok; \
        test ! -e /opt/grok/.grok/auth.json; \
        grok --version; \
        ;; \
      *) echo "unsupported AGENT_BACKEND '$AGENT_BACKEND' (expected 'claude' or 'grok')" >&2; exit 1 ;; \
    esac; \
    apt-get purge -y gnupg; apt-get autoremove -y; \
    rm -rf /var/lib/apt/lists/*
ENV AGENT_BACKEND=${AGENT_BACKEND}

# --- pipeline scripts -------------------------------------------------------
COPY agentic/ /opt/agentic/
RUN chmod +x /opt/agentic/entrypoint/*.sh /opt/agentic/lib/*.sh /opt/agentic/lib/*.py \
 && useradd -m -u 10001 -s /bin/bash agent \
 && mkdir -p /work /runs \
 && chown agent:agent /work /runs

ENV PATH="/opt/agentic/entrypoint:${PATH}"
USER agent
WORKDIR /work

# `tini` reaps the agent/pytest child tree cleanly on SIGKILL from budget_guard.
ENTRYPOINT ["/usr/bin/tini", "--"]
# No CMD: the launcher passes the stage entrypoint, e.g.
#   docker run ... agentic-dev:claude-latest slice.sh
#   docker run ... -e ISSUE=42 agentic-dev:claude-latest write-tests.sh
#   docker run ... -e ISSUE=42 agentic-dev:grok-latest   implement.sh
