#!/usr/bin/env bash
# Shared helpers for the agentic-dev entrypoints. `source` this file near the
# top of each stage script. It sets strict mode for the caller on purpose.
set -euo pipefail

log() { # log <stage> <message...>
  local stage="$1"; shift
  printf '%s [%s] %s\n' "$(date -Iseconds)" "$stage" "$*" >&2
}

die() { log "${STAGE:-entrypoint}" "FATAL: $*"; exit 1; }

require_env() { # require_env VAR VAR ...
  local v
  for v in "$@"; do
    [[ -n "${!v:-}" ]] || die "missing required env var: $v"
  done
}

default_branch() {
  gh repo view "$REPO" --json defaultBranchRef --jq '.defaultBranchRef.name'
}

clone_repo() { # echoes the checkout path on stdout; all noise goes to stderr
  local dir="${AGENT_WORKDIR:-/work}"
  rm -rf "$dir"
  gh repo clone "$REPO" "$dir" -- --depth "${CLONE_DEPTH:-50}" --no-single-branch >&2
  git -C "$dir" config user.name  "${GIT_AUTHOR_NAME:-agentic-dev bot}"
  git -C "$dir" config user.email "${GIT_AUTHOR_EMAIL:-agentic-dev@users.noreply.github.com}"
  git -C "$dir" fetch --all --prune >&2
  echo "$dir"
}

# Absolute, persistent log dir. In the container this is the write-through mount
# (`-v <host>:/runs`); on a bare checkout it falls back to ./runs.
RUNS_DIR="${RUNS_DIR:-/runs}"
[[ -d "$RUNS_DIR" || -w "$(dirname "$RUNS_DIR")" ]] 2>/dev/null || RUNS_DIR="runs"

# Daily quota: true once this stage has already logged MAX_PER_DAY runs today.
# Relies on RUNS_DIR being a persistent mount shared by all containers of the
# stage.
quota_reached() { # quota_reached <stage>
  local f="$RUNS_DIR/$1/$(date +%F).jsonl" n=0
  [[ -f "$f" ]] && n=$(wc -l < "$f")
  (( n >= ${MAX_PER_DAY:-10} ))
}

# Run a command under a hard wallclock cap; SIGKILL so a wedged agent cannot
# trap its way out.
budget_guard() {
  timeout --signal=SIGKILL "${CONTAINER_TIMEOUT:-1200}" "$@"
}

# Wrapper around the Claude CLI used by every stage. Reads ANTHROPIC_API_KEY
# from the env. `--dangerously-skip-permissions` is acceptable ONLY because the
# container is disposable, network-restricted, and has no host mounts beyond the
# checkout and the write-only runs/ dir.
run_claude() { # run_claude <prompt> [extra claude args...]
  local prompt="$1"; shift
  budget_guard claude -p "$prompt" \
    --output-format json \
    --dangerously-skip-permissions \
    --max-turns "${CLAUDE_MAX_TURNS:-60}" \
    "$@" >/dev/null
}

jlog() { # jlog <stage> <json-object-without-braces>
  local stage="$1"; shift
  mkdir -p "$RUNS_DIR/$stage"
  printf '{"ts":"%s","stage":"%s",%s}\n' "$(date -Iseconds)" "$stage" "$*" \
    >> "$RUNS_DIR/$stage/$(date +%F).jsonl"
}
