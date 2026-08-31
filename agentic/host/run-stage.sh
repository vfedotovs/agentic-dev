#!/usr/bin/env bash
#
# Host-side launcher, invoked by cron. Selects work with `gh`, then runs one
# disposable container per unit of work.
#
#   run-stage.sh slice          # Stage 1 — once/day
#   run-stage.sh write-tests    # Stage 2 — up to MAX_PER_DAY issues
#   run-stage.sh implement      # Stage 3 — up to MAX_PER_DAY issues
#
# Config comes from the env file (default /etc/agentic-dev/agentic-dev.env),
# which must define REPO, GH_TOKEN, and the API key for the selected
# AGENT_BACKEND (ANTHROPIC_API_KEY for 'claude', XAI_API_KEY for 'grok').
# See agentic-dev.env.example.
#
set -euo pipefail

STAGE="${1:?usage: run-stage.sh <slice|write-tests|implement>}"

ENV_FILE="${AGENTIC_ENV_FILE:-/etc/agentic-dev/agentic-dev.env}"
IMAGE="${AGENTIC_IMAGE:-agentic-dev:latest}"
RUNS_DIR="${AGENTIC_RUNS_DIR:-/var/lib/agentic-dev/runs}"

[[ -f "$ENV_FILE" ]] || { echo "run-stage: missing env file $ENV_FILE" >&2; exit 1; }

# An AGENT_BACKEND already in the caller's environment (e.g. `make write-tests
# AGENT_BACKEND=grok`, which also picks the matching AGENTIC_IMAGE) must win over
# the env file — otherwise the backend could disagree with the image being run.
backend_override="${AGENT_BACKEND:-}"
# A malformed line -- an unquoted value containing a space is the usual one --
# makes bash run the tail of it as a command, and set -e then kills us with that
# command's exit status and nothing pointing back at the config file. Say it.
env_loaded=0
trap '(( env_loaded )) || echo "run-stage: failed to load $ENV_FILE (see the error above; a value containing spaces must be quoted)" >&2' EXIT
set -a; # shellcheck disable=SC1090
source "$ENV_FILE"; set +a
env_loaded=1; trap - EXIT
if [[ -n "$backend_override" ]]; then AGENT_BACKEND="$backend_override"; fi

: "${REPO:?set REPO in $ENV_FILE}"
: "${GH_TOKEN:?set GH_TOKEN in $ENV_FILE}"
export GH_TOKEN                      # used by `gh` on the host too

# Only the selected backend's key is required, so a Grok-only host never has to
# carry an Anthropic key (or the reverse).
AGENT_BACKEND="${AGENT_BACKEND:-claude}"
case "$AGENT_BACKEND" in
  claude) : "${ANTHROPIC_API_KEY:?set ANTHROPIC_API_KEY in $ENV_FILE (AGENT_BACKEND=claude)}" ;;
  grok)   : "${XAI_API_KEY:?set XAI_API_KEY in $ENV_FILE (AGENT_BACKEND=grok)}" ;;
  *) echo "run-stage: unknown AGENT_BACKEND '$AGENT_BACKEND' (expected 'claude' or 'grok')" >&2; exit 2 ;;
esac
export AGENT_BACKEND

MAX_PER_DAY="${MAX_PER_DAY:-10}"
CONTAINER_TIMEOUT="${CONTAINER_TIMEOUT:-1200}"
today="$(date +%F)"

if [[ "${AGENTIC_DISABLED:-0}" == "1" ]]; then
  echo "run-stage: pipeline disabled (AGENTIC_DISABLED=1)"; exit 0
fi
mkdir -p "$RUNS_DIR"

# ---- container invocation --------------------------------------------------
docker_run() { # docker_run <entrypoint-script> [extra docker args...]
  local entry="$1"; shift
  # A predictable name so `docker logs -f` is copy-paste rather than an ID hunt.
  # The epoch suffix keeps a retry of the same issue from colliding with a
  # container the daemon has not finished removing yet.
  local name
  name="agentic-${STAGE}-${ISSUE_LABEL:-run}-$(date +%s)"
  # Hardening you can add once verified against the agent CLI's state dir
  # (~/.claude for the claude backend, ~/.grok for grok):
  #   --read-only --tmpfs /tmp --tmpfs /work --tmpfs /home/agent
  echo "   docker logs -f $name"
  docker run --rm \
    --name "$name" \
    --log-opt max-size=50m --log-opt max-file=3 \
    --network "${AGENTIC_NET:-bridge}" \
    --memory "${AGENTIC_MEM:-4g}" --cpus "${AGENTIC_CPUS:-2}" --pids-limit 512 \
    --stop-timeout "$CONTAINER_TIMEOUT" \
    --cap-drop ALL --security-opt no-new-privileges \
    -e REPO -e GH_TOKEN \
    -e AGENT_BACKEND -e ANTHROPIC_API_KEY -e XAI_API_KEY -e GROK_MODEL \
    -e MAX_PER_DAY -e CONTAINER_TIMEOUT -e RUNS_DIR=/runs \
    -e HEARTBEAT_SECS -e AGENT_STALL_SECS -e AGENT_LOG_LINE_MAX \
    -e LOOP_WINDOW -e LOOP_REPEAT_LIMIT -e LOOP_ABORT -e PYTEST_TIMEOUT \
    -e AGENT_MAX_TURNS -e CLAUDE_MAX_TURNS -e GIT_AUTHOR_NAME -e GIT_AUTHOR_EMAIL \
    -v "$RUNS_DIR:/runs" \
    "$@" \
    "$IMAGE" "$entry"
}

count_today() { # count_today <stage>
  local f="$RUNS_DIR/$1/$today.jsonl"
  [[ -f "$f" ]] && wc -l < "$f" || echo 0
}

# ---- issue selection ------------------------------------------------------
# Emits up to <limit> open issue numbers that carry <ready-label>, do NOT carry
# agent-skip / agent-failed, and (when <type-labels> is a non-empty space list)
# carry at least one of those type labels. Needs `jq` on the host.
select_issues() { # select_issues <limit> <ready-label> [type-labels]
  local limit="$1" ready="$2" types="${3:-}"
  local types_json='[]'
  # shellcheck disable=SC2086  # $types is a space-separated list; splitting is the point
  [[ -n "$types" ]] && types_json="$(printf '%s\n' $types | jq -Rc . | jq -sc .)"

  gh issue list --repo "$REPO" --state open --label "$ready" \
     --limit 100 --json number,labels \
  | jq -r --argjson types "$types_json" '
      [ .[]
        | (.labels | map(.name)) as $n
        | select( ($n | index("agent-skip"))   == null
              and ($n | index("agent-failed")) == null )
        | select( ($types | length) == 0
              or  any($types[]; . as $t | $n | index($t)) )
        | .number ]
      | sort | .[]' \
  | head -n "$limit"
}

run_batch() { # run_batch <stage> <entrypoint> <ready-label> [type-labels]
  local stage="$1" entry="$2" ready="$3" types="${4:-}"
  local have budget
  have="$(count_today "$stage")"
  budget=$(( MAX_PER_DAY - have ))
  if (( budget <= 0 )); then
    echo "$stage: daily quota reached ($have/$MAX_PER_DAY)"; return 0
  fi
  local nums; mapfile -t nums < <(select_issues "$budget" "$ready" "$types")
  if (( ${#nums[@]} == 0 )); then
    echo "$stage: no eligible issues"; return 0
  fi
  echo "$stage: processing ${#nums[@]} issue(s): ${nums[*]}"
  local n rc
  for n in "${nums[@]}"; do
    echo ">> $stage #$n"
    rc=0
    ISSUE_LABEL="$n" docker_run "$entry" -e ISSUE="$n" || rc=$?
    # 137/143 mean the container was killed rather than failing a check, which is
    # a different problem with a different fix -- keep them distinguishable.
    case "$rc" in
      0)       ;;
      124|137) echo "!! $stage #$n killed at the wallclock cap (exit $rc)" ;;
      143)     echo "!! $stage #$n terminated (exit $rc)" ;;
      *)       echo "!! $stage #$n exited $rc" ;;
    esac
  done
}

# ---- dispatch -----------------------------------------------------------
case "$STAGE" in
  slice)
    docker_run slice.sh \
      -e SLICER_DRY_RUN="${SLICER_DRY_RUN:-0}" \
      -e MAX_ISSUES="${MAX_ISSUES:-25}"
    ;;
  write-tests)
    run_batch write-tests write-tests.sh needs-tests "feature bug refactor"
    ;;
  implement)
    run_batch implement implement.sh tests-ready ""
    ;;
  gc)
    docker_run gc.sh \
      -e GC_DRY_RUN="${GC_DRY_RUN:-1}" \
      -e GC_STALE_DAYS="${GC_STALE_DAYS:-7}" \
      -e GC_INPROGRESS_HOURS="${GC_INPROGRESS_HOURS:-24}" \
      -e GC_BRANCH_PREFIXES="${GC_BRANCH_PREFIXES:-agent/tests/ agent/impl/}"
    ;;
  *)
    echo "run-stage: unknown stage '$STAGE'" >&2; exit 2 ;;
esac
