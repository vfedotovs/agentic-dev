# Agentic Development Plan

## Goal

Move the team's throughput from **1–2 PRs/week** (hand-written) to
**10–20+ merged PRs/week** produced in an agentic pipeline, while keeping
human review as the only manual gate.

The pipeline is three independent, idempotent cron jobs. Each stage runs
Claude inside a disposable Docker container, does one job, and hands work
to the next stage through **GitHub issues** and **branches/PRs** — never
through shared local state.

```
plan.md ──▶ [1] slicer ──▶ GitHub issues ──▶ [2] test-writer ──▶ issue + failing tests branch ──▶ [3] implementer ──▶ PR ──▶ human review ──▶ merge
   (daily)                    (≤10/day)                              (≤10/day)
```

---

## Shared conventions

| Concern | Decision |
| --- | --- |
| Orchestration | 3 cron jobs on the CI host (systemd timers or crontab). Each is a shell entrypoint that runs a Docker container. |
| Agent runtime | One agent CLI inside a pinned Docker image, selected by `AGENT_BACKEND`: `claude` (Anthropic, `agentic-dev:claude-latest`) or `grok` ([xai-org/grok-build](https://github.com/xai-org/grok-build), `agentic-dev:grok-latest`). One image carries one runtime; `AGENT_BACKEND` is baked in as the image default so a container cannot disagree with the binary it holds. |
| Auth | A scoped GitHub token (`repo`, `issues`) plus the selected backend's API key — `ANTHROPIC_API_KEY` or `XAI_API_KEY` — injected as env vars from the host secret store. Never baked into the image. The Grok image deliberately ships no `~/.grok/auth.json`, since a stored session token would outrank `XAI_API_KEY`. |
| Repo access | Each job does a fresh `gh repo clone` (or `git clone --depth=50`) into a container-local workdir. No long-lived checkout. |
| Idempotency | Every stage marks its output (issue labels, branch names, PR body markers) so re-runs skip already-processed work. |
| Rate limiting | Stage 2 and Stage 3 process **at most 10 issues per calendar day**, tracked via a label + a `processed-on:<date>` marker. |
| Budget guard | Per-container wallclock timeout (e.g. 20 min) and a token/cost ceiling. Container is killed and the issue is labelled `agent-failed` on breach. |
| Observability | Each run appends a JSON line to `runs/<stage>/<date>.jsonl` (issue #, branch, PR #, tokens, cost, exit status) and posts a summary comment on the issue. |

### Labels

| Label | Meaning | Set by |
| --- | --- | --- |
| `agent-generated` | Issue was created by Stage 1 | Stage 1 |
| `needs-tests` | Ready for Stage 2 | Stage 1 |
| `tests-ready` | Failing tests committed, ready for Stage 3 | Stage 2 |
| `in-progress` | Stage 3 container running | Stage 3 |
| `agent-pr-open` | PR submitted, awaiting human review | Stage 3 |
| `agent-failed` | A stage errored or exceeded budget | any |
| `agent-stale` | `gc` retired the issue's PR/branch; needs human triage | gc |
| `agent-skip` | Human opt-out; pipeline ignores this issue | human |

### Issue type routing (Stage 2/3)

Only issues labelled one of `feature`, `bug`, `refactor` flow through the
test-first path. Issues labelled `docs`, `chore`, `spike`, or `question`
are left for humans (or a future stage).

---

## Stage 1 — `slicer.py`: plan.md → GitHub issues

**Schedule:** once per day (e.g. `0 6 * * *`).

**Container:** `agentic-dev:latest`, entrypoint `slice.sh`.

### Steps

1. `gh repo clone <owner>/<repo> /work && cd /work`.
2. If `plan.md` is absent → log "no plan" and exit 0.
3. Parse `plan.md`. Expected structure: a checklist of action items,
   each a `- [ ]` line, optionally grouped under `##` headings and
   optionally tagged inline, e.g.
   `- [ ] (feature) Add pagination to /users endpoint`.
4. For each **unchecked** action item:
   - Compute a stable fingerprint (`sha1` of the normalized item text).
   - Skip if an open or closed issue already has
     `agent-fingerprint:<hash>` in its body.
   - Otherwise call Claude to expand the one-liner into a well-formed
     issue: title, context, acceptance criteria, affected
     files/modules (Claude greps the repo), and a proposed type label.
   - `gh issue create` with body containing the fingerprint marker,
     labels `agent-generated`, `needs-tests`, and the type label.
5. Optionally: rewrite `plan.md` to convert each sliced `- [ ]` into
   `- [x] ... (#<issue>)` and open a small housekeeping PR, so the plan
   stays the source of truth without re-slicing.
6. Append run record to `runs/slicer/<date>.jsonl`.

### Guardrails

- Hard cap on issues created per run (e.g. 25) to catch a runaway plan.
- Claude prompt forbids inventing scope beyond the action item text.
- Dry-run mode (`SLICER_DRY_RUN=1`) prints planned issues without
  creating them — used for the first week.

### Claude prompt sketch (Stage 1)

> You are expanding a single action item from `plan.md` into a GitHub
> issue for a Python project. Read the referenced code. Produce: a
> concise title, a context paragraph, 3–6 testable acceptance criteria,
> a list of files likely to change, and exactly one type label from
> {feature, bug, refactor, docs, chore}. Do not propose work beyond the
> action item. Output strict JSON.

---

## Stage 2 — Test writer: issue → failing tests (no implementation)

**Schedule:** once per day, after Stage 1 (e.g. `0 8 * * *`).

**Selection:** open issues with `needs-tests` AND type in
{feature, bug, refactor}, oldest first, **max 10**. Skip any with
`agent-skip` or `agent-failed`.

### Steps (per issue, one container each)

1. Fresh clone. Create branch `agent/tests/<issue>-<slug>` off the
   default branch.
2. Run Claude with the issue body + repo access. Instruction: **write
   tests only**. Add/extend `pytest` tests that encode every acceptance
   criterion. Do **not** touch non-test source files.
3. Run the test suite. **Require the new tests to fail** (red) for the
   expected reason — not collection errors, not import errors.
   - If new tests pass already → the behaviour may exist; label
     `needs-triage`, comment, stop.
   - If they error instead of failing → Claude fixes the test scaffolding
     (fixtures, imports) and retries, up to N attempts.
4. Commit tests. Push branch. Comment on the issue with the branch name,
   the list of new test IDs, and the captured failure output.
5. Swap labels: remove `needs-tests`, add `tests-ready`. Add
   `processed-on:<date>` marker.
6. Append to `runs/test-writer/<date>.jsonl`.

### Guardrails

- CI check / lint step confirms the diff touches **only** files under
  `tests/` (or `conftest.py`). Any other path → abort, label
  `agent-failed`.
- Enforce daily budget: stop selecting once 10 issues are marked
  `processed-on:<today>`.
- Timeout per container; on breach kill, label `agent-failed`, comment.

### Claude prompt sketch (Stage 2)

> Given this GitHub issue for a Python project, write pytest tests that
> would pass only once the feature/fix/refactor is correctly
> implemented. Cover each acceptance criterion. You may add fixtures and
> test helpers. You MUST NOT modify application code. The tests must fail
> now. Report each test's name and its current failure message.

---

## Stage 3 — Implementer: failing tests → green → PR

**Schedule:** once per day, after Stage 2 (e.g. `0 12 * * *`).

**Selection:** open issues with `tests-ready`, oldest first, **max 10**.
Skip `agent-skip` / `agent-failed`.

### Steps (per issue, one container each)

1. Fresh clone. Check out the `agent/tests/<issue>-<slug>` branch from
   Stage 2. Rebase onto latest default branch; on conflict, label
   `agent-failed` and comment.
2. Label the issue `in-progress`.
3. Run Claude with: the issue body, the failing tests, and repo access.
   Instruction: implement the change so the Stage 2 tests pass **without
   editing those tests** (beyond obvious typo-level fixes, which must be
   called out).
4. Loop: run `pytest` → feed failures back to Claude → iterate, up to N
   attempts or the budget/timeout.
5. Acceptance gate — all must pass:
   - Full test suite green (not just the new tests).
   - Lint/format/type checks (`ruff`, `black --check`, `mypy` if
     configured) pass.
   - Diff to `tests/` from Stage 2 is unchanged (or changes are
     explicitly justified in the PR body).
   - Coverage does not drop below the repo threshold.
6. Push branch `agent/impl/<issue>-<slug>` (or reuse the tests branch).
   `gh pr create`:
   - Title from the issue.
   - Body: `Closes #<issue>`, summary of approach, list of files
     changed, test results, token/cost footprint, and a
     `agent-pipeline: stage3` marker.
   - Reviewers: the team's rotation. Labels: `agent-pr-open`.
7. Swap issue labels: remove `in-progress` / `tests-ready`, add
   `agent-pr-open`. Add `processed-on:<date>`.
8. Append to `runs/implementer/<date>.jsonl`.

### Guardrails

- **Humans are the merge gate.** No auto-merge. Branch protection
  requires 1 approving review + green CI.
- If the agent can't reach green within budget → push whatever exists as
  a **draft** PR, label `agent-failed`, comment with the last failure
  output so a human can take over quickly.
- Container has no write access to `main`; only branch push + PR create.
- Re-run safety: if a PR with the `stage3` marker already exists for the
  issue, update the branch instead of opening a second PR.

### Claude prompt sketch (Stage 3)

> Implement the change described in this issue so that the provided
> pytest tests pass. Do not modify the tests. Keep the diff minimal and
> idiomatic to the surrounding code. All existing tests, lint, and type
> checks must continue to pass. Explain your approach in 3–5 sentences.

---

## Repository layout (this repo)

```
agentic-dev-plan.md          # this document
Dockerfile                   # builds agentic-dev:{claude,grok}-latest
                             #   claude: python + gh + node + claude CLI
                             #   grok:   python + gh + grok CLI (prebuilt binary)
examples/plan.md             # sample plan.md the slicer consumes
agentic/
  entrypoint/                # run INSIDE the container, one unit of work each
    slice.sh                 # Stage 1
    write-tests.sh           # Stage 2  (env: ISSUE)
    implement.sh             # Stage 3  (env: ISSUE)
    gc.sh                    # housekeeping: stale branches/PRs, stuck issues
  lib/
    common.sh                # shared bash helpers (clone, quota, budget, agent-backend dispatch)
    parse_plan.py            # plan.md checklist -> TSV (fingerprint, type, text)
  host/                      # run ON the cron host
    run-stage.sh             # selects work with `gh`, launches one container per unit
    crontab                  # the three schedule lines + install notes
    agentic-dev.env.example  # env-file template (REPO, GH_TOKEN, AGENT_BACKEND,
                             #   ANTHROPIC_API_KEY / XAI_API_KEY, caps)
```

Each entrypoint expects `REPO`, `GH_TOKEN`, and the API key for the selected
`AGENT_BACKEND` in the environment; Stage 2/3 also take `ISSUE`. `run-stage.sh` sources the env file,
enforces the daily cap, and passes these through to `docker run`. See the header
comment in each script for the full contract.

## Docker image (`agentic-dev:{claude,grok}-latest`)

Contains:

- Python (matching the project's `.python-version`) + `pip`/`uv`.
- `pytest`, `ruff`, `black`, `mypy`, `coverage`.
- `git`, `gh` CLI.
- Exactly one agent CLI, pinned: `claude` (via npm, needs Node) **or** `grok`
  (prebuilt binary from `x.ai/cli/install.sh`; building it from source would
  need the pinned Rust toolchain plus DotSlash for hermetic `protoc`).
- `entrypoint/` scripts: `slice.sh`, `write-tests.sh`, `implement.sh`.

Build: `make build-claude`, `make build-grok`, or `make build-all`.
`make build` stays an alias for the Claude image and keeps publishing the
`agentic-dev:latest` tag for existing cron installs.

Runtime contract for every container (this is what `agentic/host/run-stage.sh`
issues):

```
docker run --rm \
  --network <restricted> \
  --memory 4g --cpus 2 --pids-limit 512 \
  --stop-timeout 1200 \
  --cap-drop ALL --security-opt no-new-privileges \
  -e REPO -e GH_TOKEN \
  -e AGENT_BACKEND -e ANTHROPIC_API_KEY -e XAI_API_KEY -e GROK_MODEL \
  -e MAX_PER_DAY -e CONTAINER_TIMEOUT -e RUNS_DIR=/runs \
  -e ISSUE=<n> \                         # Stage 2 / 3 only
  -v /var/lib/agentic-dev/runs:/runs \   # persistent quota + run log
  agentic-dev:<backend>-latest <slice.sh|write-tests.sh|implement.sh>
```

- Runs as non-root `agent` (uid 10001). `tini` as PID 1 reaps the
  agent/pytest tree on the budget-guard SIGKILL.
- Only mount is the write-through `/runs` dir (holds
  `runs/<stage>/<date>.jsonl`, which is also how the daily cap is
  counted). Secrets come in as env vars, never a file or image layer.
- Egress restricted to GitHub + the selected backend's API where the network
  policy allows it (`AGENTIC_NET`): `api.anthropic.com` for `claude`,
  `api.x.ai` for `grok`.

---

## Rollout

| Phase | Duration | Scope |
| --- | --- | --- |
| 0. Manual dry run | week 1 | Run each stage by hand on 1–2 issues. `SLICER_DRY_RUN=1`. Tune prompts. |
| 1. Stage 1 live | week 2 | Cron the slicer only. Humans do Stages 2–3. Verify issue quality. |
| 2. Stage 2 live | week 3 | Cron test-writer at **3 issues/day**. Review every tests branch. |
| 3. Stage 3 live | week 4 | Cron implementer at **3 PRs/day**. Every PR human-reviewed. |
| 4. Scale up | week 5+ | Raise caps toward 10/day/stage as review keeps up. |

Ramp the daily cap only when: >80% of agent PRs merge with ≤1 review
round, and reviewer load stays sustainable.

---

## Metrics (weekly)

- Merged PRs/week (target 10–20+).
- Agent PR acceptance rate (merged / opened).
- Review rounds per agent PR (target ≤1).
- Stage failure rate (`agent-failed` / attempted) per stage.
- Tokens and $ per merged PR.
- Lead time: issue created → PR merged.
- Escaped defects: reverts / hotfixes traced to an agent PR.

---

## Failure modes & mitigations

| Risk | Mitigation |
| --- | --- |
| Slicer floods the tracker | Per-run issue cap; fingerprint dedupe; dry-run first week. |
| Tests that pass trivially or test nothing | Stage 2 must show red for the right reason; human reviews tests branch during ramp; mutation-testing spot checks. |
| Implementer edits tests to force green | Stage 3 gate diffs `tests/` against Stage 2; unjustified changes abort. |
| Agent PRs overwhelm reviewers | Daily caps tied to review capacity; batch review window; `agent-skip` for anything humans want to own. |
| Flaky suite blocks the pipeline | Quarantine flaky tests; Stage 3 retries once; persistent flake → `agent-failed`. |
| Cost blowout | Per-container token ceiling + wallclock timeout; weekly $/PR tracked; kill switch env var disables all crons. |
| Secret leakage | Secrets via env only, never in image or logs; `runs/` logs scrubbed of tokens; restricted egress. |
| Merge conflicts pile up | Stage 3 rebases first; the daily `gc` job closes `agent-pr-open` PRs inactive for `GC_STALE_DAYS`, deletes the branch, and relabels the issue `needs-tests` + `agent-stale`. |
| Branches / dead PRs accumulate | `gc` deletes head branches of merged/closed agent PRs (and the sibling `agent/tests/*` once impl merges), plus orphan `agent/*` branches with no PR. |
| Stage 3 container dies mid-run | `gc` finds issues stuck `in-progress` > `GC_INPROGRESS_HOURS` with no open PR and resets them to `tests-ready`. |

---

## Open decisions

- Cron host: CI runner vs. dedicated VM vs. GitHub Actions scheduled workflows.
- One repo or many: does the slicer iterate a list of repos?
- Branch strategy: single branch carried through Stages 2→3, or separate tests/impl branches.
- Who owns prompt/versioning for the three entrypoints (checked into the repo under `agentic/`).
- Whether Stage 1 rewrites `plan.md` or treats it as read-only.
