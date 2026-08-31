#!/usr/bin/env bash
#
# Stage 2 entrypoint — one GitHub issue -> a branch with FAILING tests only.
# Run one container per issue. No application code is written here.
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
STAGE=write-tests
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$HERE/../lib/common.sh"

require_env REPO GH_TOKEN ISSUE
require_agent_env

quota_reached "$STAGE" && die "daily quota (${MAX_PER_DAY:-10}) already reached"

phase issue-fetch
meta="$(gh issue view "$ISSUE" --repo "$REPO" --json number,title,body,labels)"
labels="$(jq -r '.labels[].name' <<<"$meta")"
grep -qxE 'feature|bug|refactor'  <<<"$labels" || die "#$ISSUE is not feature/bug/refactor"
grep -qxE 'agent-skip|agent-failed' <<<"$labels" && die "#$ISSUE opted out (agent-skip/agent-failed)"
grep -qx  'needs-tests'            <<<"$labels" || die "#$ISSUE is not in needs-tests state"

title="$(jq -r .title <<<"$meta")"
slug="$(tr '[:upper:]' '[:lower:]' <<<"$title" | tr -cs 'a-z0-9' '-' | sed 's/^-//;s/-$//' | cut -c1-40)"
branch="agent/tests/${ISSUE}-${slug}"

phase clone
workdir="$(clone_repo)"; cd "$workdir"
base="$(default_branch)"
git checkout -b "$branch" "origin/$base"

mkdir -p .agent
jq -r .body <<<"$meta" > .agent/issue.md

# The agent phase is the long one and, until its output is streamed, the silent
# one. `cat $RUN_DIR/phase` reading "agent" is what distinguishes a run that is
# thinking from one wedged on a clone or a `gh` call.
phase agent
run_agent "Read .agent/issue.md — a GitHub issue for this Python project.

Write pytest tests (under tests/) that will pass ONLY once the described change
is correctly implemented. Cover every acceptance criterion. You MAY add fixtures,
helpers, and conftest.py entries. You MUST NOT modify any application/source
file — tests and conftest.py only.

Keep your fixtures in the test module you add. Every other open issue is being
worked on its own branch cut from the same commit, and tests/conftest.py is the
one file all of them share: a whole conftest.py written here collides with
theirs the moment one of the branches merges. Touch tests/conftest.py only for
something that genuinely has to be shared across modules, append rather than
rewrite, and name what you add after this issue.

The new tests MUST FAIL now, and fail for the RIGHT reason (assertion failure or
a deliberate 'not implemented' — never a collection or import error). Fix any
scaffolding problems until each new test fails cleanly.

When done, write .agent/report.json with keys:
  new_tests  - array of pytest node ids you added
  failures   - array of {node_id, message}, one per new test, showing it is red
               for the intended reason" \
  --max-turns 60

# --- guard: only tests/ and conftest.py may change -----------------------------
phase diff-guard
changed="$( { git diff --name-only; git ls-files --others --exclude-standard; } | sort -u )"
offending="$(grep -vE '^(tests/|conftest\.py$)' <<<"$changed" || true)"
if [[ -n "$offending" ]]; then
  gh issue edit "$ISSUE" --repo "$REPO" --add-label agent-failed
  gh issue comment "$ISSUE" --repo "$REPO" --body "**Stage 2 aborted** — agent touched non-test files:
\`\`\`
$offending
\`\`\`"
  jlog "$STAGE" "\"issue\":$ISSUE,\"status\":\"non-test-files\""
  die "non-test files changed"
fi

phase report-check
[[ -f .agent/report.json ]] || die "agent produced no report.json"
mapfile -t nodes < <(jq -r '.new_tests[]' .agent/report.json)
(( ${#nodes[@]} > 0 )) || die "report.json lists no new tests"

# --- guard: the new tests must actually be red -------------------------------
phase pytest-red
if pytest -q "${nodes[@]}"; then
  gh issue edit "$ISSUE" --repo "$REPO" --add-label needs-triage
  gh issue comment "$ISSUE" --repo "$REPO" --body "**Stage 2 needs triage** — the new tests already PASS, so the behaviour may already exist. A human should confirm before implementation."
  jlog "$STAGE" "\"issue\":$ISSUE,\"status\":\"already-green\""
  die "new tests pass unexpectedly"
fi

phase commit
git add -A
git commit -m "test: add failing tests for #${ISSUE}

Refs #${ISSUE}"

phase push
git push -u origin "$branch"

phase gh-report
failures="$(jq -r '.failures[] | "- `\(.node_id)` — \(.message)"' .agent/report.json)"
gh issue comment "$ISSUE" --repo "$REPO" --body "**Stage 2 complete** — failing tests pushed to \`$branch\`:

$failures"
gh issue edit "$ISSUE" --repo "$REPO" --remove-label needs-tests --add-label tests-ready

jlog "$STAGE" "\"issue\":$ISSUE,\"branch\":\"$branch\",\"tests\":$(jq -c '.new_tests' .agent/report.json),\"status\":\"tests-ready\""
log "$STAGE" "done #$ISSUE -> $branch"
