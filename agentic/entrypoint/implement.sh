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

meta="$(gh issue view "$ISSUE" --repo "$REPO" --json number,title,body,labels)"
labels="$(jq -r '.labels[].name' <<<"$meta")"
grep -qx  'tests-ready'            <<<"$labels" || die "#$ISSUE is not in tests-ready state"
grep -qxE 'agent-skip|agent-failed' <<<"$labels" && die "#$ISSUE opted out"

title="$(jq -r .title <<<"$meta")"
slug="$(tr '[:upper:]' '[:lower:]' <<<"$title" | tr -cs 'a-z0-9' '-' | sed 's/^-//;s/-$//' | cut -c1-40)"
tests_branch="agent/tests/${ISSUE}-${slug}"
impl_branch="agent/impl/${ISSUE}-${slug}"

workdir="$(clone_repo)"; cd "$workdir"
base="$(default_branch)"
git rev-parse --verify "origin/$tests_branch" >/dev/null 2>&1 || die "missing tests branch $tests_branch"

git checkout -b "$impl_branch" "origin/$tests_branch"
if ! git rebase "origin/$base"; then
  git rebase --abort || true
  gh issue edit "$ISSUE" --repo "$REPO" --remove-label tests-ready --add-label agent-failed
  gh issue comment "$ISSUE" --repo "$REPO" --body "**Stage 3 aborted** — \`$tests_branch\` does not rebase cleanly onto \`$base\`. A human needs to resolve conflicts."
  jlog "$STAGE" "\"issue\":$ISSUE,\"status\":\"rebase-conflict\""
  die "rebase conflict"
fi

gh issue edit "$ISSUE" --repo "$REPO" --remove-label tests-ready --add-label in-progress

mkdir -p .agent
jq -r .body <<<"$meta" > .agent/issue.md
git diff "origin/$base...HEAD" -- tests/ conftest.py > .agent/tests.patch || true

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
gate_ok=1
pytest -q                                   || gate_ok=0
if command -v ruff  >/dev/null; then ruff check .      || gate_ok=0; fi
if command -v black >/dev/null; then black --check .   || gate_ok=0; fi
if command -v mypy  >/dev/null && { [[ -f mypy.ini ]] || grep -q '\[tool.mypy\]' pyproject.toml 2>/dev/null; }; then
  mypy . || gate_ok=0
fi

# tests must be untouched vs the Stage 2 branch unless the agent justified edits
test_delta="$(git diff "origin/$tests_branch...HEAD" -- tests/ conftest.py | wc -l)"
justified="$(jq -r '.test_edits | length' .agent/impl.json 2>/dev/null || echo 0)"
if (( test_delta > 0 && justified == 0 )); then
  gate_ok=0
  log "$STAGE" "tests changed ($test_delta lines) with no justification in impl.json"
fi

git add -A

if (( gate_ok == 1 )) && [[ -f .agent/impl.json ]]; then
  git commit -m "feat: implement #${ISSUE}

Closes #${ISSUE}"
  git push -u origin "$impl_branch"

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

<!-- agent-pipeline: stage3 -->
_Opened by agentic-dev. Human review required — no auto-merge._" \
    --label agent-pr-open)"

  gh issue edit "$ISSUE" --repo "$REPO" --remove-label in-progress --add-label agent-pr-open
  gh issue comment "$ISSUE" --repo "$REPO" --body "**Stage 3 complete** — PR: $pr_url"
  jlog "$STAGE" "\"issue\":$ISSUE,\"branch\":\"$impl_branch\",\"pr\":\"$pr_url\",\"status\":\"open\""
  log "$STAGE" "done #$ISSUE -> $pr_url"
else
  git commit -m "wip: partial work for #${ISSUE} (agent did not reach green)

Refs #${ISSUE}" || true
  git push -u origin "$impl_branch" || true
  pr_url="$(gh pr create --repo "$REPO" --base "$base" --head "$impl_branch" --draft \
    --title "[WIP] $title" \
    --body "Refs #${ISSUE}

The agent could not reach a green build within budget. Last state is pushed here
for a human to take over.

<!-- agent-pipeline: stage3 -->" 2>/dev/null || echo "(no PR created)")"

  gh issue edit "$ISSUE" --repo "$REPO" --remove-label in-progress --add-label agent-failed
  gh issue comment "$ISSUE" --repo "$REPO" --body "**Stage 3 FAILED** — draft: $pr_url

Last test output:
\`\`\`
$(pytest -q 2>&1 | tail -n 40)
\`\`\`"
  jlog "$STAGE" "\"issue\":$ISSUE,\"branch\":\"$impl_branch\",\"pr\":\"$pr_url\",\"status\":\"failed\""
  die "acceptance gate failed for #$ISSUE"
fi
