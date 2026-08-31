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
  local f n=0
  f="$RUNS_DIR/$1/$(date +%F).jsonl"
  [[ -f "$f" ]] && n=$(wc -l < "$f")
  (( n >= ${MAX_PER_DAY:-10} ))
}

# Run a command under a hard wallclock cap; SIGKILL so a wedged agent cannot
# trap its way out.
budget_guard() {
  timeout --signal=SIGKILL "${CONTAINER_TIMEOUT:-1200}" "$@"
}

# Which agent runtime the stages drive: 'claude' (Anthropic) or 'grok' (xAI).
# Set it in the env file. The image is built for one backend, so this must match
# the image the container was started from.
AGENT_BACKEND="${AGENT_BACKEND:-claude}"

# Fail fast unless the API key for the selected backend is present AND that
# backend's CLI is actually in this image. Each backend needs only its own key,
# so a Grok-only host never has to carry an Anthropic one. The CLI check turns an
# env-file/image mismatch into a clear error at startup rather than a bare
# "command not found" once the stage is already mid-run.
require_agent_env() {
  local cli
  case "$AGENT_BACKEND" in
    claude) require_env ANTHROPIC_API_KEY; cli=claude ;;
    grok)   require_env XAI_API_KEY;       cli=grok ;;
    *) die "unknown AGENT_BACKEND '$AGENT_BACKEND' (expected 'claude' or 'grok')" ;;
  esac
  command -v "$cli" >/dev/null \
    || die "AGENT_BACKEND=$AGENT_BACKEND but '$cli' is not in this image; run the matching image (make build-$AGENT_BACKEND)"
}

# Wrapper around the agent CLI used by every stage. The prompt goes in on the
# command line and results come back as files the agent writes into the checkout
# (.agent/*.json), so the CLI's own stdout is discarded for both backends.
#
# Auto-approval (`--dangerously-skip-permissions` / `--yolo`) is acceptable ONLY
# because the container is disposable, network-restricted, and has no host mounts
# beyond the checkout and the write-only runs/ dir.
run_agent() { # run_agent <prompt> [extra agent args...]
  local prompt="$1"; shift

  # Resolve the turn cap once instead of emitting --max-turns twice and relying
  # on each CLI's last-flag-wins parsing:
  #   AGENT_MAX_TURNS (env) > the caller's per-stage --max-turns > 60.
  local turns=''
  local -a args=()
  while (( $# )); do
    case "$1" in
      --max-turns)   turns="$2"; shift 2 ;;
      --max-turns=*) turns="${1#*=}"; shift ;;
      *)             args+=("$1"); shift ;;
    esac
  done
  turns="${AGENT_MAX_TURNS:-${CLAUDE_MAX_TURNS:-${turns:-60}}}"

  local -a cmd
  case "$AGENT_BACKEND" in
    claude)
      cmd=(claude -p "$prompt"
           --output-format json
           --dangerously-skip-permissions
           --max-turns "$turns")
      ;;
    grok)
      # `grok` prefers a session token in ~/.grok/auth.json over XAI_API_KEY; the
      # image ships no such file, so the key is always what authenticates.
      # --no-auto-update stops a disposable container re-downloading the binary.
      cmd=(grok -p "$prompt"
           --output-format json
           --yolo
           --no-auto-update
           --max-turns "$turns")
      if [[ -n "${GROK_MODEL:-}" ]]; then cmd+=(--model "$GROK_MODEL"); fi
      ;;
    *)
      die "unknown AGENT_BACKEND '$AGENT_BACKEND' (expected 'claude' or 'grok')"
      ;;
  esac

  # ${args[@]+...} keeps an empty array safe under `set -u` on bash < 4.4.
  cmd+=(${args[@]+"${args[@]}"})
  budget_guard "${cmd[@]}" >/dev/null
}

jlog() { # jlog <stage> <json-object-without-braces>
  local stage="$1"; shift
  mkdir -p "$RUNS_DIR/$stage"
  printf '{"ts":"%s","stage":"%s",%s}\n' "$(date -Iseconds)" "$stage" "$*" \
    >> "$RUNS_DIR/$stage/$(date +%F).jsonl"
}
