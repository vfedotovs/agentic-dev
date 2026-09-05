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
  # .agent/ is this pipeline's scratch space: the issue body handed to the agent
  # and the report handed back. It is not the target repo's business, and until
  # it is excluded every stage sees its own scratch as work the agent did --
  # `git ls-files --others` reports .agent/issue.md and .agent/report.json to the
  # diff guard, and `git add -A` commits them. Excluded here rather than in each
  # stage so one rule covers all of them, and via info/exclude rather than the
  # upstream .gitignore because it is our mess, not the repo's.
  echo '.agent/' >> "$dir/.git/info/exclude"
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
AGENTIC_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# How the agent phase reports itself. Defaults chosen so a healthy run is
# readable rather than noisy: one line per agent event, plus a heartbeat every
# HEARTBEAT_SECS that proves the container is alive even when the agent is
# silent (a long tool call, a slow API).
HEARTBEAT_SECS="${HEARTBEAT_SECS:-30}"
AGENT_STALL_SECS="${AGENT_STALL_SECS:-300}"
AGENT_LOG_LINE_MAX="${AGENT_LOG_LINE_MAX:-200}"

# Loop detection. The stream filter raises the flag; LOOP_ABORT decides whether
# anything is done about it. It defaults to 0 (report only) on purpose: killing a
# run on a heuristic is worth doing only once the flag has been seen to be right
# on this repo's own traffic. The evidence lands in RUN_DIR/loop-suspect.json
# either way.
LOOP_WINDOW="${LOOP_WINDOW:-20}"
LOOP_REPEAT_LIMIT="${LOOP_REPEAT_LIMIT:-5}"
LOOP_ABORT="${LOOP_ABORT:-0}"
export AGENT_LOG_LINE_MAX LOOP_WINDOW LOOP_REPEAT_LIMIT

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

# ---------------------------------------------------------------------------
# Heartbeat
# ---------------------------------------------------------------------------
# Proof-of-life while the agent runs. The stream filter already prints a line per
# agent event, but a container blocked on a slow tool call or a hanging API
# request emits no events at all -- and that silence is exactly the case that
# used to be indistinguishable from a wedged run. The heartbeat is deliberately
# a separate process from the filter so it keeps ticking even if the agent
# produces nothing whatsoever.
HEARTBEAT_PID=

# Whole-container memory. `ps` is not installed in the image, and the cgroup
# figure is the one that matters anyway: it is what AGENTIC_MEM caps and what an
# OOM kill (also exit 137) would be triggered by.
container_rss() {
  local bytes
  if [[ -r /sys/fs/cgroup/memory.current ]] && read -r bytes < /sys/fs/cgroup/memory.current; then
    echo "$(( bytes / 1048576 ))M"
  else
    echo '?'
  fi
}

# Stop an agent the filter has flagged as looping. The pid comes from a file
# because the heartbeat runs in a subshell forked before budget_guard sets
# BUDGET_GUARD_PID, so it cannot see that variable. SIGTERM to `timeout` is
# propagated to the agent underneath it.
loop_abort_check() {
  [[ "$LOOP_ABORT" == "1" && -r "$RUN_DIR/loop-suspect.json" ]] || return 0
  local pid=''
  [[ -r "$RUN_DIR/agent.pid" ]] && read -r pid < "$RUN_DIR/agent.pid"
  [[ -n "$pid" ]] || return 0
  log "${STAGE:-entrypoint}" "LOOP-ABORT stopping the agent (LOOP_ABORT=1): $(loop_suspect_label)"
  kill -TERM "$pid" 2>/dev/null || true
}

loop_suspect_label() {
  [[ -r "$RUN_DIR/loop-suspect.json" ]] || return 0
  jq -r '"\(.label) x\(.repeats)"' "$RUN_DIR/loop-suspect.json" 2>/dev/null || true
}

heartbeat_tick() {
  local turns=0 events=0 last=0 quiet=-1 tag=hb note='' now
  now="$(date +%s)"
  if [[ -r "$RUN_DIR/agent-state" ]]; then
    read -r turns events last < <(jq -r '[.turns,.events,.last_ts]|@tsv' \
      "$RUN_DIR/agent-state" 2>/dev/null) || true
  fi
  [[ -n "${last:-}" && "$last" =~ ^[0-9]+$ ]] || last=0
  (( last > 0 )) && quiet=$(( now - last ))

  # Silence past AGENT_STALL_SECS is the shape a loop or a hang takes.
  if (( quiet >= AGENT_STALL_SECS )); then
    tag=STALL
    note=" -- no agent event for ${quiet}s"
  fi
  # Warn before the wallclock cap fires, so an impending SIGKILL is visible in
  # the log rather than only inferable afterwards from the exit code.
  if (( SECONDS * 100 >= ${CONTAINER_TIMEOUT:-1200} * 80 )); then
    note="$note -- past 80% of the ${CONTAINER_TIMEOUT:-1200}s budget"
  fi

  [[ -r "$RUN_DIR/loop-suspect.json" ]] && note="$note -- LOOP-SUSPECT: $(loop_suspect_label)"

  log "${STAGE:-entrypoint}" "$tag elapsed=${SECONDS}s phase=$PHASE turns=${turns:-0} events=${events:-0} quiet=$(( quiet < 0 ? 0 : quiet ))s rss=$(container_rss)$note"
  loop_abort_check
}

heartbeat_start() {
  heartbeat_stop
  ( while :; do sleep "$HEARTBEAT_SECS"; heartbeat_tick; done ) &
  HEARTBEAT_PID=$!
}

heartbeat_stop() {
  [[ -n "$HEARTBEAT_PID" ]] || return 0
  kill "$HEARTBEAT_PID" 2>/dev/null || true
  wait "$HEARTBEAT_PID" 2>/dev/null || true
  HEARTBEAT_PID=
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
  heartbeat_stop
  local status; status="$(exit_status "$rc")"
  # A loop-abort arrives as an ordinary SIGTERM; name it for what it was.
  if (( rc != 0 )) && [[ "$LOOP_ABORT" == "1" && -r "$RUN_DIR/loop-suspect.json" ]]; then
    status=loop-abort
  fi
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
  heartbeat_stop
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
  # The heartbeat subshell was forked before this assignment, so it can only
  # reach the pid through a file.
  echo "$BUDGET_GUARD_PID" > "$RUN_DIR/agent.pid" 2>/dev/null || true
  wait "$BUDGET_GUARD_PID" || rc=$?
  BUDGET_GUARD_PID=
  rm -f "$RUN_DIR/agent.pid" 2>/dev/null || true
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
# (.agent/*.json). The CLI's stdout is no longer discarded: both backends can
# emit their turns as NDJSON, which stream_filter.py summarises to stderr (so it
# reaches `docker logs`) while keeping the full stream in RUN_DIR.
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
      # stream-json requires --verbose; without it the CLI refuses the combination.
      cmd=(claude -p "$prompt"
           --output-format stream-json --verbose
           --dangerously-skip-permissions
           --max-turns "$turns")
      ;;
    grok)
      # `grok` prefers a session token in ~/.grok/auth.json over XAI_API_KEY; the
      # image ships no such file, so the key is always what authenticates.
      # --no-auto-update stops a disposable container re-downloading the binary.
      #
      # `streaming-messages-json` is Grok's NDJSON mode. It frames events with the
      # same {"type":"system"|"assistant"|"user"|"result"} envelope Claude Code
      # emits, so a single filter reads both backends.
      cmd=(grok -p "$prompt"
           --output-format streaming-messages-json
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

  # A FIFO rather than a pipeline: `budget_guard | filter` would put the guard in
  # a subshell, losing both BUDGET_GUARD_PID (so a SIGTERM could no longer stop
  # the agent) and the guard's own exit status. This way the guard stays a direct
  # child of this shell, its rc is read straight off it, and the filter is still
  # `wait`ed on so the last events are never lost to a race at exit.
  local fifo_dir fifo filter_pid rc=0
  # Stale artefacts from an earlier call would otherwise be attributed to this
  # one -- Stage 1 invokes run_agent once per plan item into the same RUN_DIR.
  rm -f "$RUN_DIR/agent-result.json" "$RUN_DIR/loop-suspect.json"
  fifo_dir="$(mktemp -d)"; fifo="$fifo_dir/agent.out"
  mkfifo "$fifo"
  RUN_DIR="$RUN_DIR" STAGE="${STAGE:-agent}" \
    python3 -u "$AGENTIC_LIB/stream_filter.py" < "$fifo" &
  filter_pid=$!

  heartbeat_start
  # </dev/null: the Claude CLI otherwise waits ~3s for piped stdin that is never
  # coming, on every single invocation.
  budget_guard "${cmd[@]}" < /dev/null > "$fifo" || rc=$?
  heartbeat_stop
  wait "$filter_pid" 2>/dev/null || true
  rm -rf "$fifo_dir"

  if [[ -r "$RUN_DIR/agent-result.json" ]]; then
    log "${STAGE:-entrypoint}" "agent finished rc=$rc$(agent_usage_human)"
  fi
  return "$rc"
}

# Cost and token totals from the stream's final `result` event, in two shapes:
# one for humans, one to splice into a ledger line. Both are empty when the agent
# never got far enough to report -- callers must stay valid without them.
agent_usage_human() {
  [[ -r "$RUN_DIR/agent-result.json" ]] || return 0
  jq -r '" cost=$\(.total_cost_usd // 0 | .*10000 | round / 10000) turns=\(.num_turns // "?") tokens=\(.usage.input_tokens // "?")/\(.usage.output_tokens // "?")"' \
    "$RUN_DIR/agent-result.json" 2>/dev/null || true
}

agent_loop_fields() {
  [[ -r "$RUN_DIR/loop-suspect.json" ]] || return 0
  jq -rc '",\"loop_suspect\":{\"tool\":\(.tool|tojson),\"repeats\":\(.repeats),\"aborted\":'"${LOOP_ABORT:-0}"'}"' \
    "$RUN_DIR/loop-suspect.json" 2>/dev/null || true
}

agent_usage_fields() {
  [[ -r "$RUN_DIR/agent-result.json" ]] || return 0
  jq -rc '",\"cost_usd\":\(.total_cost_usd // 0),\"agent_turns\":\(.num_turns // 0),\"tokens_in\":\(.usage.input_tokens // 0),\"tokens_out\":\(.usage.output_tokens // 0)"' \
    "$RUN_DIR/agent-result.json" 2>/dev/null || true
}

# Appends to the quota ledger that quota_reached() and the host launcher's
# count_today() both count lines in. Setting JLOG_WRITTEN keeps the exit trap
# from adding a second line for the same run.
jlog() { # jlog <stage> <json-object-without-braces>
  local stage="$1"; shift
  mkdir -p "$RUNS_DIR/$stage"
  printf '{"ts":"%s","run":"%s","stage":"%s",%s%s%s}\n' \
    "$(date -Iseconds)" "$RUN_ID" "$stage" "$*" "$(agent_usage_fields)" "$(agent_loop_fields)" \
    >> "$RUNS_DIR/$stage/$(date +%F).jsonl"
  JLOG_WRITTEN=1
}
