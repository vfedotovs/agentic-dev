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

# ---------------------------------------------------------------------------
# Per-run observability
# ---------------------------------------------------------------------------
# Layout, deliberately alongside the quota file rather than inside it:
#
#   $RUNS_DIR/<stage>/<date>.jsonl      quota ledger — ONE line per run, ever
#   $RUNS_DIR/<stage>/<date>/<issue>/   this run's phase trail
#       phase          one line: the phase the run is in right now
#       phases.jsonl   every phase transition, appended
#
# `phase` is a single line so a wedged run can be diagnosed from the host with
# `cat .../<issue>/phase` — no `docker exec`, no attaching to the container.
#
# Re-running the same issue on the same day reuses the directory on purpose:
# `phase` then always reflects the newest attempt. RUN_ID distinguishes the
# attempts' appended phases.jsonl lines.
RUN_ID="$(date +%s)-$$"
RUN_DIR="$RUNS_DIR/${STAGE:-entrypoint}/$(date +%F)/${ISSUE:-run}"
mkdir -p "$RUN_DIR" 2>/dev/null || RUN_DIR="$(mktemp -d)"

PHASE=start
PHASE_STARTED=$SECONDS

phase() { # phase <name> — record entry into a phase of this run
  local prev="$PHASE" prev_secs=$(( SECONDS - PHASE_STARTED ))
  PHASE="$1"; PHASE_STARTED=$SECONDS
  printf '%s\n' "$PHASE" > "$RUN_DIR/phase"
  printf '{"ts":"%s","run":"%s","stage":"%s","phase":"%s","prev":"%s","prev_secs":%d,"elapsed":%d}\n' \
    "$(date -Iseconds)" "$RUN_ID" "${STAGE:-entrypoint}" "$PHASE" "$prev" "$prev_secs" "$SECONDS" \
    >> "$RUN_DIR/phases.jsonl"
  log "${STAGE:-entrypoint}" "--> $PHASE (${prev_secs}s in $prev, ${SECONDS}s total)"
}

exit_status() { # exit_status <rc> — a word for the jsonl "status" field
  case "$1" in
    0)       echo ok ;;
    # GNU timeout reports 124 when its own SIGTERM ended the child and 128+9
    # when --signal=SIGKILL did. 137 is also what an OOM kill looks like, so the
    # heartbeat's rss line (a later PR) is what tells the two apart.
    124|137) echo timeout ;;
    130)     echo interrupted ;;
    143)     echo terminated ;;
    *)       echo error ;;
  esac
}

# Set by jlog(). The exit trap adds a ledger line only when the stage did not
# already write one, so the ledger keeps exactly one line per run that reached
# the agent — whether it succeeded, tripped a guard, or was killed mid-agent.
JLOG_WRITTEN=0

# Set by run_agent(). The ledger is what MAX_PER_DAY counts, and its purpose is
# capping spend, so a run that died before the agent ever started must NOT
# consume a slot: otherwise one bad label or a stale env file could burn the
# whole day's budget on runs that cost nothing. Such a run is still fully
# diagnosable — its phase trail is written either way.
AGENT_STARTED=0

# Guarantees a record on EVERY exit path — including `die`, a failed guard, and
# budget_guard SIGKILLing the agent out from under the stage. Stage scripts may
# define on_stage_exit() to release whatever state they took (labels, mostly);
# it is called before the ledger line is written.
on_exit() {
  local rc=$?
  set +e
  trap - EXIT
  local status; status="$(exit_status "$rc")"
  printf 'exit:%s\n' "$status" > "$RUN_DIR/phase"
  printf '{"ts":"%s","run":"%s","stage":"%s","phase":"exit","died_in":"%s","elapsed":%d,"exit":%d,"status":"%s"}\n' \
    "$(date -Iseconds)" "$RUN_ID" "${STAGE:-entrypoint}" "$PHASE" "$SECONDS" "$rc" "$status" \
    >> "$RUN_DIR/phases.jsonl"
  if declare -F on_stage_exit >/dev/null; then on_stage_exit "$rc" "$status"; fi
  if (( JLOG_WRITTEN == 0 && AGENT_STARTED == 1 )); then
    jlog "${STAGE:-entrypoint}" \
      "\"issue\":${ISSUE:-null},\"phase\":\"$PHASE\",\"elapsed\":$SECONDS,\"exit\":$rc,\"status\":\"$status\""
  fi
  log "${STAGE:-entrypoint}" "EXIT rc=$rc status=$status died_in=$PHASE elapsed=${SECONDS}s run=$RUN_ID dir=$RUN_DIR"
  exit "$rc"
}
trap on_exit EXIT

# Signals need more than `trap 'exit' TERM`. Bash does not act on a caught signal
# while a FOREGROUND child is running — it defers the handler until that child
# exits. During the agent phase that child can run for the full 20-minute
# CONTAINER_TIMEOUT, far past the SIGKILL that `docker stop` follows up with, so
# the handler would never get to run at all. budget_guard therefore backgrounds
# its child and `wait`s on it (`wait` *is* interruptible), and this handler stops
# that child before exiting through the EXIT trap above.
BUDGET_GUARD_PID=
on_signal() { # on_signal <exit-code> <signal-name>
  log "${STAGE:-entrypoint}" "received SIG$2 during phase ${PHASE:-unknown}; stopping"
  if [[ -n "$BUDGET_GUARD_PID" ]]; then
    kill -TERM "$BUDGET_GUARD_PID" 2>/dev/null || true
  fi
  exit "$1"
}
trap 'on_signal 143 TERM' TERM
trap 'on_signal 130 INT'  INT

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
# trap its way out. Backgrounded rather than run in the foreground so that this
# shell stays responsive to signals for the whole of the agent phase — see the
# on_signal comment above.
budget_guard() {
  local rc=0
  timeout --signal=SIGKILL "${CONTAINER_TIMEOUT:-1200}" "$@" &
  BUDGET_GUARD_PID=$!
  wait "$BUDGET_GUARD_PID" || rc=$?
  BUDGET_GUARD_PID=
  return "$rc"
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
  AGENT_STARTED=1

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

# Appends to the quota ledger that quota_reached() and the host launcher's
# count_today() both count lines in. Setting JLOG_WRITTEN keeps the exit trap
# from adding a second line for the same run.
jlog() { # jlog <stage> <json-object-without-braces>
  local stage="$1"; shift
  mkdir -p "$RUNS_DIR/$stage"
  printf '{"ts":"%s","run":"%s","stage":"%s",%s}\n' "$(date -Iseconds)" "$RUN_ID" "$stage" "$*" \
    >> "$RUNS_DIR/$stage/$(date +%F).jsonl"
  JLOG_WRITTEN=1
}
