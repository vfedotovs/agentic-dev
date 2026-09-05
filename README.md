# agentic-dev

A three-stage agentic pipeline that turns a checked-in `plan.md` into merged
pull requests, so a Python project can go from 1–2 hand-written PRs/week to
10–20+ agent-produced PRs/week — with **human review as the only merge gate**.

```
plan.md ─▶ [1 slice] ─▶ GitHub issues ─▶ [2 write-tests] ─▶ failing-tests branch ─▶ [3 implement] ─▶ PR ─▶ human review ─▶ merge
             daily              ≤10/day                          ≤10/day
                                              [gc] daily: retire stale branches/PRs, unstick dead runs
```

Each stage runs an agent CLI — `claude` (Anthropic) or `grok`
([xai-org/grok-build](https://github.com/xai-org/grok-build)), selected with
`AGENT_BACKEND` — inside a disposable Docker container, does one unit of work,
and hands off through **issues** and **branches/PRs** — never shared local
state. See [`agentic-dev-plan.md`](agentic-dev-plan.md) for the
full design rationale, label state machine, rollout plan, and failure-mode
analysis.

---

## Repository layout

```
agentic-dev-plan.md            design doc (read this for the "why")
README.md                      this file
Dockerfile                     builds agentic-dev:{claude,grok}-latest
.dockerignore                  build context is an allowlist: agentic/ only
Makefile                       build / run / operate targets (`make help`)
examples/plan.md               sample plan.md the slicer consumes
agentic/
  entrypoint/                  run INSIDE the container, one unit of work each
    slice.sh                   Stage 1  — plan.md -> issues
    write-tests.sh             Stage 2  — issue -> failing tests   (env: ISSUE)
    implement.sh               Stage 3  — failing tests -> green -> PR (env: ISSUE)
    gc.sh                      housekeeping
  lib/
    common.sh                  shared bash helpers: phases, the exit trap,
                               budget_guard, run_agent, the heartbeat
    stream_filter.py           summarises the agent's NDJSON stream to one line
                               per event; flags repeated tool calls as a loop
    parse_plan.py              plan.md checklist parser
  host/                        run ON the cron host
    run-stage.sh               selects work with gh, launches one container per unit
    crontab                    the schedule + install runbook
    agentic-dev.env.example    env-file template
```

---

## Prerequisites

- A Linux host with **Docker** and the **`gh`** CLI and **`jq`** installed
  (`run-stage.sh` uses `gh`/`jq` on the host; the containers carry their own).
- A **GitHub token** (classic or fine-grained) for the target repo with:
  `contents: read/write`, `issues: read/write`, `pull_requests: read/write`.
- An API key for the agent backend you pick, with budget for ~10–20 runs/day:
  an **Anthropic API key** (`AGENT_BACKEND=claude`, the default) **or** an
  **xAI API key** from [console.x.ai](https://console.x.ai)
  (`AGENT_BACKEND=grok`). Only the selected backend's key is needed.
- The target repo must use **`pytest`**, and ideally `ruff` / `black` / `mypy`
  (Stage 3's acceptance gate runs whichever are present).

---

## Setup

### 1. Target repo: labels, `plan.md`, branch protection

Create the pipeline labels (one-time):

```bash
REPO=your-org/your-repo
for l in \
  "agent-generated" "needs-tests" "tests-ready" "in-progress" \
  "agent-pr-open" "agent-failed" "agent-stale" "agent-skip" \
  "needs-triage" "feature" "bug" "refactor" "docs" "chore"; do
  gh label create "$l" --repo "$REPO" --force
done
```

Add a `plan.md` at the repo root — see [`examples/plan.md`](examples/plan.md)
for the format (unchecked `- [ ]` items, optional `(type)` prefix, `##`
headings for context).

Protect the default branch: **require 1 approving review + green CI**, and
disallow pushes to it. The agent only ever pushes `agent/*` branches and opens
PRs; nothing merges without a human.

### 2. Build the image

One image carries one agent runtime, so build the one matching the backend you
intend to run:

```bash
git clone <this-repo> /opt/agentic-dev
cd /opt/agentic-dev

make build-claude     # agentic-dev:claude-latest  (also tagged agentic-dev:latest)
make build-grok       # agentic-dev:grok-latest
make build-all        # both
```

Pin the CLI if you want reproducibility:

```bash
make build-claude CLAUDE_CODE_VERSION=x.y.z
make build-grok   GROK_CLI_VERSION=x.y.z
```

`make build` remains an alias for `build-claude` and still publishes the
`agentic-dev:latest` tag, so existing cron installs need no change.

### 3. Host user, directories, env file

```bash
sudo useradd -r -m -G docker agentic
sudo install -d -o agentic -g agentic /var/lib/agentic-dev/runs /var/log/agentic-dev
sudo install -d -m 750 /etc/agentic-dev
sudo cp /opt/agentic-dev/agentic/host/agentic-dev.env.example /etc/agentic-dev/agentic-dev.env
sudo chown agentic:agentic /etc/agentic-dev/agentic-dev.env
sudo chmod 600 /etc/agentic-dev/agentic-dev.env
sudoedit /etc/agentic-dev/agentic-dev.env      # set REPO, GH_TOKEN, AGENT_BACKEND
                                              # + that backend's API key
```

Key env-file settings (full list in the template):

| Var | Default | Meaning |
| --- | --- | --- |
| `REPO` | — | `owner/name` of the target repo |
| `GH_TOKEN` | — | GitHub credentials, container env only |
| `AGENT_BACKEND` | `claude` | agent runtime: `claude` or `grok`; must match the image |
| `ANTHROPIC_API_KEY` | — | required when `AGENT_BACKEND=claude`, container env only |
| `XAI_API_KEY` | — | required when `AGENT_BACKEND=grok`, container env only |
| `GROK_MODEL` | — | optional model for the `grok` backend, e.g. `grok-4.6` |
| `AGENT_MAX_TURNS` | — | override the per-stage turn cap (30/60/120) |
| `MAX_PER_DAY` | 10 | Stage 2 & 3 issue cap per day |
| `MAX_ISSUES` | 25 | Stage 1 hard cap on issues created per run |
| `SLICER_DRY_RUN` | 0 | `1` = Stage 1 prints planned issues, creates none |
| `CONTAINER_TIMEOUT` | 1200 | per-container wallclock seconds (SIGKILL) |
| `GC_DRY_RUN` | 1 | `gc` reports only until you set `0` |
| `AGENTIC_DISABLED` | 0 | `1` = pause everything (cron fires, exits early) |

### 4. Install the schedule

```bash
sudo -u agentic crontab /opt/agentic-dev/agentic/host/crontab
sudo -u agentic crontab -l          # verify
```

Default times (host-local): `gc` 02:00, `slice` 06:00, `write-tests` 08:00,
`implement` 12:00. They are spaced so each finishes before the next starts.

---

## How a change flows

| Stage | Trigger | Input | Output | Guardrails |
| --- | --- | --- | --- | --- |
| **1 slice** | daily | `plan.md` unchecked items | issues labelled `agent-generated`,`needs-tests`,`<type>` | fingerprint dedupe; `MAX_ISSUES` cap; `SLICER_DRY_RUN` |
| **2 write-tests** | daily, ≤`MAX_PER_DAY` | issue `needs-tests` + type ∈ {feature,bug,refactor} | branch `agent/tests/<n>-<slug>` with **failing** pytest tests; label → `tests-ready` | diff must stay under `tests/` + `conftest.py` **and may only add files**, in `tests/issue-<n>/`, so sibling branches cannot collide on `tests/conftest.py`; new tests must actually fail (else `needs-triage`) |
| **3 implement** | daily, ≤`MAX_PER_DAY` | issue `tests-ready` | PR `Closes #<n>`, label → `agent-pr-open` | rebases onto base first (a conflict confined to `tests/` is merged by the agent and re-checked; anything else stops for a human); gate = pytest + ruff + black + mypy + tests-unchanged + an `impl.json` report; failure → **draft** PR + `agent-failed`, with the checks that failed named in the issue comment |
| **gc** | daily | — | deletes stale/merged `agent/*` branches, closes inactive agent PRs, resets stuck `in-progress` issues | only touches `agent/tests/*` `agent/impl/*`; `GC_DRY_RUN` |

Humans interact by: reviewing/merging PRs, adding **`agent-skip`** to any issue
the pipeline should ignore, and triaging **`agent-stale`** / **`agent-failed`** /
**`needs-triage`** issues.

---

## Operations

Most of the below is wrapped by the **Makefile** — `make help` lists every
target. Examples: `make build`, `make slice-dry`, `make write-tests`,
`make gc-apply`, `make status REPO=$REPO`, `make run-issue STAGE=implement ISSUE=42`.
Override `ENV_FILE` / `IMAGE` / `RUNS_DIR` on the command line for a dev setup.
`AGENT_BACKEND=grok make write-tests` selects both the Grok image and the Grok
runtime for that run, overriding whatever the env file says.

### Watch it run

```bash
tail -f /var/log/agentic-dev/{slice,write-tests,implement,gc}.log

# structured per-unit records (issue #, branch, PR, status)
ls  /var/lib/agentic-dev/runs/*/
cat /var/lib/agentic-dev/runs/implement/$(date +%F).jsonl | jq .

# pipeline state at a glance
gh issue list  --repo "$REPO" --label needs-tests
gh issue list  --repo "$REPO" --label tests-ready
gh pr list     --repo "$REPO" --label agent-pr-open
gh issue list  --repo "$REPO" --label agent-failed --state all
```

### Diagnose a run that looks stuck

Every run writes the phase it is currently in to a one-line file, so a container
that has gone quiet can be diagnosed from the host without attaching to it:

```bash
# which containers are running, and what is each one doing?
make ps
# agentic-implement-57-1788178268  4 minutes ago  gate-pytest   docker logs -f agentic-implement-57-1788178268

# what is every run today doing right now?
make phase
# write-tests  42     agent            last change 734s ago
# implement    57     gate-pytest      last change 3s ago

# the full trail for one run, followed live
make watch STAGE=implement ISSUE=57
```

The layout under `RUNS_DIR`:

```
runs/<stage>/<date>.jsonl        ledger — one line per run that reached the agent
runs/<stage>/<date>/<issue>/
    phase                        the phase this run is in *now* (or exit:<status>)
    phases.jsonl                 every phase transition, with seconds spent in each
```

Reading `phase` answers the question directly:

| `phase` says | meaning |
|---|---|
| `clone` / `issue-fetch` / `push` / `gh-report` | blocked on GitHub, not on the agent |
| `agent` | inside the agent CLI — the phase capped by `CONTAINER_TIMEOUT` (default 1200s = 20 min) |
| `agent-item-7` (Stage 1) | the slicer is on the 7th plan item |
| `gate-pytest` | the acceptance gate is running the suite |
| `exit:timeout` | killed at the wallclock cap; `died_in` in `phases.jsonl` says where |
| `exit:error` | a guard tripped or a command failed |

`phases.jsonl` records `prev_secs` per transition, so a run that took 18 minutes
in `agent` and 4 seconds everywhere else is obvious after the fact.

Stage 3 additionally releases its `in-progress` claim on **any** exit — including
a killed agent — and comments on the issue saying which phase it died in, so a
dead container no longer leaves an issue claimed until `gc` reclaims it 24 hours
later.

### Watch the agent work

The agent's turns are streamed to the container log, one line each, so
`docker logs -f` shows what it is doing as it does it:

```
… [implement] --> agent (2s in clone, 6s total)
… [implement] init model=claude-opus-5 tools=26
… [implement] turn=1 tool=Read file_path=src/parser.py
… [implement] turn=2 tool=Bash command=pytest -q tests/test_parser.py
… [implement] result=ERR 8 failed, 2 passed in 3.1s
… [implement] hb elapsed=63s phase=agent turns=2 events=9 quiet=41s rss=612M
… [implement] turn=3 tool=Edit file_path=src/parser.py
… [implement] done status=success turns=14 cost=$0.83 tokens=41022/9317 in 184s
```

The `hb` heartbeat lands every `HEARTBEAT_SECS` regardless of what the agent is
doing, so a container blocked on a slow tool call or a hanging API request still
proves it is alive. `quiet` is seconds since the last agent event; once that
passes `AGENT_STALL_SECS` the line becomes `STALL`, which is the shape a hang or
a loop takes:

```
… [implement] STALL elapsed=780s phase=agent turns=41 events=204 quiet=331s rss=1.4G -- no agent event for 331s
… [implement] hb elapsed=990s phase=agent turns=41 events=204 quiet=541s rss=1.4G -- past 80% of the 1200s budget
```

That last warning fires at 80% of `CONTAINER_TIMEOUT`, so an impending SIGKILL is
visible before it lands rather than only inferable afterwards from exit 137.

Each run's full untruncated stream stays on disk at
`<run-dir>/agent-stream.jsonl`, and the final `result` event at
`<run-dir>/agent-result.json`. Cost and token totals are spliced into the run's
ledger line automatically, so spend is queryable per issue:

```bash
jq -s 'map(select(.cost_usd)) | {runs: length, usd: (map(.cost_usd) | add)}' \
  /var/lib/agentic-dev/runs/implement/$(date +%F).jsonl

# replay one run's stream through the same summariser (a scratch RUN_DIR, since
# the filter also re-writes its state/result files wherever you point it)
RUN_DIR=$(mktemp -d) STAGE=implement python3 agentic/lib/stream_filter.py \
  < /var/lib/agentic-dev/runs/implement/$(date +%F)/57/agent-stream.jsonl > /dev/null
```

Both backends are covered by one filter: Claude Code's `--output-format
stream-json` and Grok's `--output-format streaming-messages-json` frame their
events the same way. Anything unrecognised is still counted, stored and printed
generically — the filter is written so it can never be the reason a run fails.

### Catching a loop early

An agent stuck re-running one failing command looks, to `--max-turns` and to the
wallclock cap, exactly like an agent making progress: both only fire once the
budget is gone. What distinguishes the two is the *same* tool call coming back,
and that is visible almost immediately:

```
… [implement] LOOP-SUSPECT tool=Bash command=pytest -q tests/test_parser.py repeats=5/5 -- the same call keeps coming back
… [implement] hb elapsed=6s phase=agent turns=6 events=6 quiet=1s rss=13M -- LOOP-SUSPECT: Bash command=pytest -q tests/test_parser.py x5
```

Calls are matched on the tool name plus a hash of its arguments, over a rolling
window of the last `LOOP_WINDOW` calls, so an agent editing a different file each
turn is never flagged — only one that keeps making the identical call.

It is **report-only by default**. The flag lands in the log, in
`<run-dir>/loop-suspect.json`, and in the run's ledger line
(`"loop_suspect":{"tool":"Bash","repeats":5,"aborted":0}`), so you can see how
often it fires on your own traffic before letting it act. Set `LOOP_ABORT=1` and
it stops the agent instead:

```
… [implement] LOOP-ABORT stopping the agent (LOOP_ABORT=1): Bash command=pytest -q tests/test_parser.py x5
… [implement] EXIT rc=143 status=loop-abort died_in=agent elapsed=6s
```

The run then ends as `loop-abort` rather than riding out the full
`CONTAINER_TIMEOUT`, and Stage 3 releases its `in-progress` claim on the way out
as it does for any other early exit.

### The acceptance gate

Stage 3's gate used to run `pytest -q` silently, so a hanging suite added yet
more unexplained quiet on top of the agent's. It now streams, is tee'd to
`<run-dir>/pytest.log`, and honours `PYTEST_TIMEOUT` (via `pytest-timeout`, in
the image) so a stuck test fails loudly instead of eating whatever wallclock
budget the container has left:

```
FAILED tests/test_hang.py::test_hangs_forever - Failed: Timeout (>300.0s) from ...
… [implement] gate pytest: 1 failed, 1 passed in 300.4s
```

The failure comment posted to the issue is taken from that same log rather than
from a second `pytest` run, so it reports what actually happened.

### Run a stage now (outside cron)

```bash
sudo -u agentic /opt/agentic-dev/agentic/host/run-stage.sh slice
sudo -u agentic /opt/agentic-dev/agentic/host/run-stage.sh write-tests
sudo -u agentic /opt/agentic-dev/agentic/host/run-stage.sh implement
sudo -u agentic GC_DRY_RUN=0 /opt/agentic-dev/agentic/host/run-stage.sh gc
```

The daily `MAX_PER_DAY` budget is shared with the cron run (counted from
`runs/<stage>/<date>.jsonl`), so a manual run just consumes part of it. A run
that fails *before* the agent starts — a stale label, a missing tests branch —
costs nothing and so is not counted; it still leaves a phase trail.

### Debug one issue in a container

```bash
docker run --rm -it \
  -e REPO="$REPO" -e GH_TOKEN=… -e ISSUE=42 \
  -e AGENT_BACKEND=claude -e ANTHROPIC_API_KEY=… \
  -v /var/lib/agentic-dev/runs:/runs \
  agentic-dev:claude-latest write-tests.sh   # or implement.sh

# the same thing on the Grok backend
docker run --rm -it \
  -e REPO="$REPO" -e GH_TOKEN=… -e ISSUE=42 \
  -e AGENT_BACKEND=grok -e XAI_API_KEY=… \
  -v /var/lib/agentic-dev/runs:/runs \
  agentic-dev:grok-latest write-tests.sh
```

### Pause / resume

```bash
# hard pause: cron still fires but every stage exits immediately
sudo sed -i 's/^AGENTIC_DISABLED=.*/AGENTIC_DISABLED=1/' /etc/agentic-dev/agentic-dev.env

# or pull the schedule entirely
sudo -u agentic crontab -r
```

### Tune throughput

- Start conservative: `MAX_PER_DAY=3`, review every branch and PR.
- Raise toward 10 only when >80% of agent PRs merge with ≤1 review round and
  reviewers keep up (see the rollout table in `agentic-dev-plan.md`).
- `CONTAINER_TIMEOUT` (wallclock SIGKILL) and the per-stage `--max-turns` in the
  entrypoint scripts bound cost per run; watch `$/merged PR` in the weekly
  metrics.

### First week: dry runs

1. `SLICER_DRY_RUN=1` → run `slice`, read the `WOULD create` lines, tune
   `plan.md` phrasing.
2. Flip to `0`, let Stage 1 create issues, sanity-check their quality.
3. Enable Stage 2 at `MAX_PER_DAY=3`; review each `agent/tests/*` branch.
4. Enable Stage 3 at `MAX_PER_DAY=3`; review each PR.
5. Set `GC_DRY_RUN=0` once you've eyeballed a `gc` dry-run.

---

## Troubleshooting

| Symptom | Likely cause / fix |
| --- | --- |
| `run-stage: missing env file` | `/etc/agentic-dev/agentic-dev.env` absent or unreadable by `agentic`. |
| `gh: authentication` errors | `GH_TOKEN` missing scopes (`contents`/`issues`/`pull_requests`) or expired. |
| Stage 1 creates nothing | No `plan.md`, all items checked/already sliced, or `SLICER_DRY_RUN=1`. |
| Stage 2 labels issue `needs-triage` | New tests passed immediately — behaviour may already exist; a human decides. |
| Stage 2 aborts "non-test files changed" | The agent edited source; the issue gets `agent-failed`. Sharpen the acceptance criteria and retry. |
| Stage 2 aborts "edited existing test files" | The agent appended to a shared file (almost always `tests/conftest.py`) instead of creating `tests/issue-<n>/`. That edit is what makes two sibling branches conflict once the first one merges, so it is rejected at the source. Retry. |
| Stage 3 opens a **draft** PR + `agent-failed` | Couldn't reach green within budget; last `pytest` output is in the issue comment. Take over manually or raise `CONTAINER_TIMEOUT`. |
| Stage 3 aborts "rebase conflict" | Reported with a reason. `conflicts outside tests/` is a real clash with base — rebase by hand or re-slice. `conflict markers left` / `resolution dropped` / `do not collect` mean the agent's own merge of a test-file conflict failed its checks; the branch is untouched, so retry or merge by hand. |
| Issue stuck in `in-progress` | Stage 3 container died; next `gc` run resets it to `tests-ready` (after `GC_INPROGRESS_HOURS`). |
| Nothing runs at all | Check `AGENTIC_DISABLED`, `crontab -l` for the `agentic` user, and the `docker` group membership. |
| Daily cap hit early | `runs/<stage>/<date>.jsonl` already has `MAX_PER_DAY` lines (manual + cron share the budget). Raise `MAX_PER_DAY` or wait for tomorrow. |

---

## Security notes

- Secrets are passed as **env vars only** — never baked into the image or
  written to disk. Keep `agentic-dev.env` at `chmod 600`.
- Containers run as non-root (`uid 10001`), `--cap-drop ALL`,
  `--security-opt no-new-privileges`, `--pids-limit`, memory/CPU caps, and a
  hard wallclock `timeout` that SIGKILLs a wedged agent.
- Restrict container egress to GitHub + your backend's API via `AGENTIC_NET`
  (point it at a locked-down Docker network): `api.anthropic.com` for the
  `claude` backend, `api.x.ai` for `grok`. Building the Grok image also needs
  `x.ai` and `storage.googleapis.com` reachable, but that is build time only.
- The Grok image ships no `~/.grok/auth.json`; `grok` would prefer a stored
  session token over `XAI_API_KEY`, so the absence of that file is what keeps
  the key authoritative. The Dockerfile asserts it at build time.
- The agent can only push `agent/*` branches and open PRs. Branch protection is
  what actually prevents an unreviewed merge — configure it.
