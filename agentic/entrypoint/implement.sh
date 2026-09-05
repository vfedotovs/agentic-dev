#!/usr/bin/env bash
#
# Stage 3 entrypoint — issue + failing-tests branch -> green build -> PR.
# Run one container per issue. Humans are the only merge gate: no auto-merge.
#
# Env:
#   REPO   GH_TOKEN                           (required)
#   ISSUE  issue number to process             (required)
#   AGENT_BACKEND        claude | grok         (default claude)
#   ANTHROPIC_API_KEY    required when AGENT_BACKEND=claude
#   XAI_API_KEY          required when AGENT_BACKEND=grok
#   MAX_PER_DAY   daily quota for this stage   (default 10)
#
set -euo pipefail
STAGE=implement
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$HERE/../lib/common.sh"

require_env REPO GH_TOKEN ISSUE
require_agent_env

quota_reached "$STAGE" && die "daily quota (${MAX_PER_DAY:-10}) already reached"

# Stage 3 is the only stage that takes a lock on the issue (the `in-progress`
# label). Set once that label is on and cleared once the run has settled it one
# way or the other; while it is 1, an exit of any kind — a killed agent
# included — has left the issue claimed by a container that no longer exists.
LABEL_HELD=0

# Called by common.sh's exit trap before the ledger line is written.
on_stage_exit() { # on_stage_exit <rc> <status>
  local rc="$1" status="$2"
  (( LABEL_HELD == 1 )) || return 0
  log "$STAGE" "releasing in-progress on #$ISSUE (died in $PHASE, $status)"
  gh issue edit "$ISSUE" --repo "$REPO" \
    --remove-label in-progress --add-label agent-failed >/dev/null 2>&1 || true
  gh issue comment "$ISSUE" --repo "$REPO" --body "**Stage 3 ended in \`$PHASE\`** — \`$status\` (exit $rc) after ${SECONDS}s.

No PR was opened and the \`in-progress\` claim has been released. Phase trail: \`$RUN_DIR/phases.jsonl\` (run \`$RUN_ID\`)." >/dev/null 2>&1 || true
  LABEL_HELD=0
}

phase issue-fetch
meta="$(gh issue view "$ISSUE" --repo "$REPO" --json number,title,body,labels)"
labels="$(jq -r '.labels[].name' <<<"$meta")"
grep -qx  'tests-ready'            <<<"$labels" || die "#$ISSUE is not in tests-ready state"
grep -qxE 'agent-skip|agent-failed' <<<"$labels" && die "#$ISSUE opted out"

title="$(jq -r .title <<<"$meta")"
slug="$(tr '[:upper:]' '[:lower:]' <<<"$title" | tr -cs 'a-z0-9' '-' | sed 's/^-//;s/-$//' | cut -c1-40)"
tests_branch="agent/tests/${ISSUE}-${slug}"
impl_branch="agent/impl/${ISSUE}-${slug}"

phase clone
workdir="$(clone_repo)"; cd "$workdir"
base="$(default_branch)"
git rev-parse --verify "origin/$tests_branch" >/dev/null 2>&1 || die "missing tests branch $tests_branch"

# Hand the branch back to a human and stop. Used when the conflict is a real
# disagreement about the change rather than scaffolding the pipeline duplicated.
rebase_dead_end() { # rebase_dead_end <reason>
  git rebase --abort >/dev/null 2>&1 || true
  gh issue edit "$ISSUE" --repo "$REPO" --remove-label tests-ready --add-label agent-failed
  gh issue comment "$ISSUE" --repo "$REPO" --body "**Stage 3 aborted** — \`$tests_branch\` does not rebase cleanly onto \`$base\` ($1). A human needs to resolve conflicts."
  jlog "$STAGE" "\"issue\":$ISSUE,\"status\":\"rebase-conflict\",\"reason\":\"$1\""
  die "rebase conflict: $1"
}

phase rebase
git checkout -b "$impl_branch" "origin/$tests_branch"
rebase_note=""
if ! git rebase "origin/$base"; then
  # Stage 2 branches are each cut from main at their own time and each writes its
  # own test scaffolding, so the first one merged leaves every other open branch
  # with an add/add conflict on tests/conftest.py. That conflict is the
  # pipeline's own doing and it dead-ends a run that has nothing wrong with it —
  # and merging two sets of fixtures is exactly what the agent already in this
  # container is for. A conflict in application code is a real disagreement about
  # the change, so that one still goes to a human untouched.
  mapfile -t conflicts < <(git diff --name-only --diff-filter=U)
  (( ${#conflicts[@]} > 0 )) || rebase_dead_end "rebase stopped with no conflicted paths"
  if printf '%s\n' "${conflicts[@]}" | grep -qvE '^(tests/|conftest\.py$)'; then
    rebase_dead_end "conflicts outside tests/: ${conflicts[*]}"
  fi

  phase rebase-resolve
  log "$STAGE" "test-only rebase conflict, merging with the agent: ${conflicts[*]}"
  run_agent "Rebasing this issue's test branch onto '$base' stopped with conflicts
in test files that both sides added independently:

${conflicts[*]}

EDIT each of those files in place and WRITE the merged content back to disk.
Reading them is not the task; the file on disk must end up merged:
- Keep every fixture, helper and test from each side. Rename only on a genuine
  name collision, and update whatever referenced the name you changed.
- No conflict marker (<<<<<<<, =======, >>>>>>>) may remain in the file.
- Do not delete tests, and do not touch application code.
- Check your work by re-reading the file and running 'pytest --collect-only -q';
  iterate until it collects.
Do not run any git command — the pipeline stages your files and finishes the
rebase itself." --max-turns 30

  # The agent is not taken at its word: markers gone, rebase actually finished,
  # suite still collectable. Any of those failing is the human hand-off again.
  for f in "${conflicts[@]}"; do
    [[ -f "$f" ]] || continue
    grep -qE '^(<<<<<<<|>>>>>>>) ' "$f" && rebase_dead_end "conflict markers left in $f"
  done
  git add -- "${conflicts[@]}"
  if [[ -d .git/rebase-merge || -d .git/rebase-apply ]]; then
    GIT_EDITOR=true git rebase --continue || rebase_dead_end "could not finish the rebase after resolution"
  fi
  # "Resolving" by dropping one side is the cheap way out, so it is the one
  # checked mechanically: every test file either side had must still be there.
  mapfile -t want < <( { git ls-tree -r --name-only "origin/$tests_branch" -- tests/ conftest.py
                         git ls-tree -r --name-only "origin/$base"         -- tests/ conftest.py; } | sort -u )
  for f in ${want[@]+"${want[@]}"}; do
    [[ -e "$f" ]] || rebase_dead_end "resolution dropped $f"
  done
  pytest --collect-only -q >"$RUN_DIR/rebase-collect.log" 2>&1 \
    || rebase_dead_end "the merged tests do not collect (see rebase-collect.log)"

  rebase_note="Rebase onto \`$base\` conflicted in \`${conflicts[*]}\` (both branches added them); the agent merged both sides and the suite still collects."
  log "$STAGE" "rebase conflict resolved in ${conflicts[*]}"
  jlog "$STAGE" "\"issue\":$ISSUE,\"status\":\"rebase-resolved\",\"files\":\"${conflicts[*]}\""
fi

# The tests as they landed on $base. Every later "did the agent touch the tests?"
# question is asked against this, not against origin/$tests_branch: that branch
# forks at an older commit, so a three-dot diff against it reports main's own
# test changes (and any conflict resolution above) as if the agent had made them.
tests_head="$(git rev-parse HEAD)"

gh issue edit "$ISSUE" --repo "$REPO" --remove-label tests-ready --add-label in-progress
LABEL_HELD=1

mkdir -p .agent
jq -r .body <<<"$meta" > .agent/issue.md
git diff "origin/$base...HEAD" -- tests/ conftest.py > .agent/tests.patch || true

# 120 turns of edit/test iteration, and until the stream lands the whole of it
# is silent. This marker is what a stuck run is diagnosed by.
phase agent
run_agent "Read .agent/issue.md (the issue) and .agent/tests.patch (failing tests
already committed to this branch).

Implement the change so the tests pass. Rules:
- Do NOT modify the committed tests, except obvious typo-level fixes, which you
  must list explicitly.
- Keep the diff minimal and idiomatic to the surrounding code.
- Every existing test must still pass, and ruff / black --check / mypy (where
  configured) must be clean.
Iterate: run 'pytest -q', read failures, fix, repeat until green.

When green, write .agent/impl.json with keys:
  summary       - 3-5 sentences on the approach
  files_changed - array of paths you modified (excluding tests)
  test_edits    - array of strings describing any test typo fixes (usually [])" \
  --max-turns 120

# --- acceptance gate --------------------------------------------------------
# The gate used to run silently too: `pytest -q` prints nothing until it is
# finished, so a hanging suite added yet more unexplained quiet. Tee'd to the run
# dir, and PYTEST_TIMEOUT (pytest-timeout, installed in the image) makes a stuck
# test fail loudly instead of eating the container's remaining budget.
# Which check failed is the whole story of a failed run, and it used to be the
# one thing the run did not record: the issue comment quoted the tail of
# pytest.log whatever had failed, so a run rejected by ruff or by the
# tests-untouched check reported "FAILED" directly above a green "37 passed".
phase gate-pytest
gate_ok=1
gate_failed=()
PYTEST_TIMEOUT="${PYTEST_TIMEOUT:-300}" pytest -q --color=no 2>&1 \
  | tee "$RUN_DIR/pytest.log" || { gate_ok=0; gate_failed+=("pytest"); }
log "$STAGE" "gate pytest: $(tail -n 1 "$RUN_DIR/pytest.log" 2>/dev/null || echo 'no output')"

phase gate-lint
if command -v ruff  >/dev/null; then ruff check .    || { gate_ok=0; gate_failed+=("ruff"); }; fi
if command -v black >/dev/null; then black --check . || { gate_ok=0; gate_failed+=("black"); }; fi
if command -v mypy  >/dev/null && { [[ -f mypy.ini ]] || grep -q '\[tool.mypy\]' pyproject.toml 2>/dev/null; }; then
  mypy . || { gate_ok=0; gate_failed+=("mypy"); }
fi

# tests must be untouched vs the Stage 2 branch unless the agent justified edits
phase gate-tests-untouched
test_delta="$(git diff "$tests_head" -- tests/ conftest.py | wc -l)"
justified="$(jq -r '.test_edits | length' .agent/impl.json 2>/dev/null || echo 0)"
if (( test_delta > 0 && justified == 0 )); then
  gate_ok=0
  gate_failed+=("tests-untouched ($test_delta lines changed, none justified)")
  log "$STAGE" "tests changed ($test_delta lines) with no justification in impl.json"
fi

# A missing impl.json blocks the PR exactly like a failed check, so it is named
# like one rather than silently steering the run into the failure branch.
if [[ ! -f .agent/impl.json ]]; then
  gate_ok=0
  gate_failed+=("no impl.json written by the agent")
fi

gate_summary="$(printf '%s\n' ${gate_failed[@]+"${gate_failed[@]}"} | sed '/^$/d' | sed 's/^/- /')"

git add -A

if (( gate_ok == 1 )); then
  phase commit
  git commit -m "feat: implement #${ISSUE}

Closes #${ISSUE}"

  phase push
  git push -u origin "$impl_branch"

  phase pr-create
  summary="$(jq -r .summary .agent/impl.json)"
  files="$(jq -r '.files_changed[]? | "- `\(.)`"' .agent/impl.json)"
  pr_url="$(gh pr create --repo "$REPO" --base "$base" --head "$impl_branch" \
    --title "$title" \
    --body "Closes #${ISSUE}

## Approach
$summary

## Files changed
${files:-_none reported_}

## Verification
- \`pytest\` green; ruff / black / mypy clean.
- Test files unchanged from Stage 2 (or changes justified above).
${rebase_note:+
## Rebase
$rebase_note
}

<!-- agent-pipeline: stage3 -->
_Opened by agentic-dev. Human review required — no auto-merge._" \
    --label agent-pr-open)"

  phase gh-report
  gh issue edit "$ISSUE" --repo "$REPO" --remove-label in-progress --add-label agent-pr-open
  LABEL_HELD=0
  gh issue comment "$ISSUE" --repo "$REPO" --body "**Stage 3 complete** — PR: $pr_url"
  jlog "$STAGE" "\"issue\":$ISSUE,\"branch\":\"$impl_branch\",\"pr\":\"$pr_url\",\"status\":\"open\""
  log "$STAGE" "done #$ISSUE -> $pr_url"
else
  # Every step on the way out used to end in `|| true` or `2>/dev/null`, so a
  # failure here reported "(no PR created)" and nothing else -- not whether the
  # commit was empty, not whether the push was rejected, not what git said. The
  # work is on a branch nobody can find and the reason is in a container that no
  # longer exists. Each step now keeps its error and puts it in the comment.
  phase fail-commit
  handoff=()
  if ! git commit -m "wip: partial work for #${ISSUE} (agent did not reach green)

Refs #${ISSUE}" >"$RUN_DIR/fail-commit.log" 2>&1; then
    handoff+=("Nothing to commit — the agent left no changes on \`$impl_branch\`.")
    log "$STAGE" "fail-path commit: $(tail -n 1 "$RUN_DIR/fail-commit.log" 2>/dev/null)"
  fi

  phase fail-push
  if git push -u origin "$impl_branch" >"$RUN_DIR/fail-push.log" 2>&1; then
    pushed=1
  else
    pushed=0
    handoff+=("Push of \`$impl_branch\` FAILED: \`$(tail -n 2 "$RUN_DIR/fail-push.log" | tr '\n' ' ')\` — the work exists only in the container and is gone.")
    log "$STAGE" "fail-path push failed: $(tail -n 1 "$RUN_DIR/fail-push.log" 2>/dev/null)"
  fi

  phase fail-pr
  if (( pushed == 1 )); then
    pr_url="$(gh pr create --repo "$REPO" --base "$base" --head "$impl_branch" --draft \
      --title "[WIP] $title" \
      --body "Refs #${ISSUE}

The agent could not reach a green build within budget. Last state is pushed here
for a human to take over.

## Checks that failed
${gate_summary:-- _not recorded_}

<!-- agent-pipeline: stage3 -->" 2>"$RUN_DIR/fail-pr.log")" || {
      pr_url="(no PR created)"
      handoff+=("\`gh pr create\` FAILED: \`$(tail -n 2 "$RUN_DIR/fail-pr.log" | tr '\n' ' ')\`")
    }
  else
    pr_url="(no PR created — nothing was pushed)"
  fi

  phase fail-report
  gh issue edit "$ISSUE" --repo "$REPO" --remove-label in-progress --add-label agent-failed
  LABEL_HELD=0
  gh issue comment "$ISSUE" --repo "$REPO" --body "**Stage 3 FAILED** — draft: $pr_url

## Checks that failed
${gate_summary:-- _not recorded_}
$(printf '%s\n' ${handoff[@]+"${handoff[@]}"} | sed '/^$/d' | sed 's/^/- /')

Last test output (green here does NOT mean the run passed — see the failed
checks above):
\`\`\`
$(tail -n 40 "$RUN_DIR/pytest.log" 2>/dev/null || echo '(no pytest output captured)')
\`\`\`"
  jlog "$STAGE" "\"issue\":$ISSUE,\"branch\":\"$impl_branch\",\"pr\":\"$pr_url\",\"status\":\"failed\",\"failed_checks\":\"$(tr '\n' ',' <<<"${gate_failed[*]+"${gate_failed[*]}"}")\""
  die "acceptance gate failed for #$ISSUE"
fi
