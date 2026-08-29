#!/usr/bin/env bash
#
# Housekeeping — retire stale agent branches and PRs, and unstick issues whose
# Stage 3 container died. Safe by default: reports only unless GC_DRY_RUN=0.
#
# Env:
#   REPO   GH_TOKEN                       (required)
#   GC_DRY_RUN            1 = report only (DEFAULT), 0 = actually act
#   GC_STALE_DAYS         inactivity threshold for open PRs / orphan branches (default 7)
#   GC_INPROGRESS_HOURS   reset issues stuck 'in-progress' longer than this   (default 24)
#   GC_BRANCH_PREFIXES    space-separated branch prefixes it is allowed to touch
#                         (default "agent/tests/ agent/impl/")
#
set -euo pipefail
STAGE=gc
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$HERE/../lib/common.sh"

require_env REPO GH_TOKEN

DRY_RUN="${GC_DRY_RUN:-1}"
STALE_DAYS="${GC_STALE_DAYS:-7}"
INPROGRESS_HOURS="${GC_INPROGRESS_HOURS:-24}"
read -r -a PREFIXES <<<"${GC_BRANCH_PREFIXES:-agent/tests/ agent/impl/}"

now="$(date +%s)"
stale_before=$(( now - STALE_DAYS * 86400 ))
inprogress_before=$(( now - INPROGRESS_HOURS * 3600 ))
base="$(default_branch)"

log "$STAGE" "repo=$REPO base=$base dry_run=$DRY_RUN stale_days=$STALE_DAYS"

epoch() { date -d "$1" +%s 2>/dev/null || echo 0; }

# act <human description> — returns 0 (caller should proceed) only when not dry-run
act() {
  if [[ "$DRY_RUN" == "1" ]]; then log "$STAGE" "WOULD: $*"; return 1; fi
  log "$STAGE" "DO:    $*"; return 0
}

is_agent_branch() {
  local b="$1" p
  for p in "${PREFIXES[@]}"; do [[ -n "$p" && "$b" == "$p"* ]] && return 0; done
  return 1
}

delete_branch() { # delete_branch <name> <reason>
  local b="$1" reason="$2"
  [[ "$b" == "$base" ]] && { log "$STAGE" "refuse: $b is the base branch"; return; }
  is_agent_branch "$b" || { log "$STAGE" "refuse: $b is not an agent branch"; return; }
  if act "delete branch $b ($reason)"; then
    if gh api -X DELETE "repos/$REPO/git/refs/heads/$b" >/dev/null 2>&1; then
      jlog "$STAGE" "\"action\":\"delete-branch\",\"branch\":\"$b\",\"reason\":$(jq -Rc . <<<"$reason")"
    else
      log "$STAGE" "  branch $b already gone"
    fi
  fi
}

# ---------------------------------------------------------------------------
# 1. PRs: merged/closed -> delete head (and sibling tests) branch;
#         open + inactive > STALE_DAYS -> comment, close, delete branch,
#         reset the linked issue to needs-tests + agent-stale for a human.
# ---------------------------------------------------------------------------
gh pr list --repo "$REPO" --state all --limit 500 \
   --json number,state,headRefName,updatedAt,url \
   --jq '.[] | [.number, .state, .headRefName, .updatedAt, .url] | @tsv' \
| while IFS=$'\t' read -r num state head updated url; do
    is_agent_branch "$head" || continue

    if [[ "$state" == "MERGED" || "$state" == "CLOSED" ]]; then
      delete_branch "$head" "PR #$num $state"
      [[ "$state" == "MERGED" && "$head" == agent/impl/* ]] \
        && delete_branch "agent/tests/${head#agent/impl/}" "impl PR #$num merged"
      continue
    fi

    # state == OPEN
    (( $(epoch "$updated") < stale_before )) || continue
    issue="$(gh pr view "$num" --repo "$REPO" --json closingIssuesReferences \
               --jq '.closingIssuesReferences[0].number // empty' 2>/dev/null || true)"
    if act "close stale PR #$num ($url) — no activity since $updated"; then
      gh pr comment "$num" --repo "$REPO" --body \
        "Closing automatically: no activity in ${STALE_DAYS} days. Branch \`$head\` will be deleted. Re-run the pipeline (or reopen) to resume."
      gh pr close "$num" --repo "$REPO" --delete-branch 2>/dev/null \
        || { gh pr close "$num" --repo "$REPO" || true; delete_branch "$head" "stale PR #$num"; }
      if [[ -n "$issue" ]]; then
        gh issue edit "$issue" --repo "$REPO" \
          --remove-label in-progress --remove-label agent-pr-open \
          --add-label needs-tests --add-label agent-stale 2>/dev/null || true
        gh issue comment "$issue" --repo "$REPO" --body \
          "Agent PR #$num closed as stale by gc. Reset to \`needs-tests\`; labelled \`agent-stale\` for human triage."
      fi
      jlog "$STAGE" "\"action\":\"close-stale-pr\",\"pr\":$num,\"issue\":\"${issue:-}\",\"branch\":\"$head\""
    fi
  done

# ---------------------------------------------------------------------------
# 2. Orphan agent branches: no PR (any state), and either already contained in
#    base, or tip older than STALE_DAYS.
# ---------------------------------------------------------------------------
gh api --paginate "repos/$REPO/branches?per_page=100" --jq '.[].name' \
| while read -r b; do
    is_agent_branch "$b" || continue
    prs="$(gh pr list --repo "$REPO" --state all --head "$b" --json number --jq 'length')"
    [[ "$prs" != "0" ]] && continue

    ahead="$(gh api "repos/$REPO/compare/$base...$b" --jq '.ahead_by' 2>/dev/null || echo 1)"
    if [[ "$ahead" == "0" ]]; then
      delete_branch "$b" "already contained in $base, no PR"
      continue
    fi
    tip="$(gh api "repos/$REPO/commits/$b" --jq '.commit.committer.date' 2>/dev/null || echo '')"
    [[ -n "$tip" ]] || continue
    (( $(epoch "$tip") < stale_before )) && delete_branch "$b" "orphan branch, tip $tip, no PR"
  done

# ---------------------------------------------------------------------------
# 3. Issues stuck in 'in-progress' with no open PR -> back to tests-ready.
# ---------------------------------------------------------------------------
gh issue list --repo "$REPO" --state open --label in-progress --limit 200 \
   --json number,updatedAt --jq '.[] | [.number, .updatedAt] | @tsv' \
| while IFS=$'\t' read -r num updated; do
    (( $(epoch "$updated") < inprogress_before )) || continue
    open_pr="$(gh pr list --repo "$REPO" --state open --search "$num in:body" \
                 --json number --jq 'length')"
    [[ "$open_pr" != "0" ]] && continue
    if act "reset stuck issue #$num (in-progress, last touched $updated, no open PR)"; then
      gh issue edit "$num" --repo "$REPO" --remove-label in-progress --add-label tests-ready
      gh issue comment "$num" --repo "$REPO" --body \
        "gc: stuck in \`in-progress\` since $updated with no open PR (Stage 3 container likely died). Reset to \`tests-ready\` for another attempt."
      jlog "$STAGE" "\"action\":\"reset-inprogress\",\"issue\":$num"
    fi
  done

if [[ "$DRY_RUN" == "1" ]]; then
  log "$STAGE" "done — DRY RUN, see WOULD lines above. Set GC_DRY_RUN=0 to act."
else
  f="$RUNS_DIR/gc/$(date +%F).jsonl"; n=0; [[ -f "$f" ]] && n="$(wc -l < "$f")"
  log "$STAGE" "done — $n action(s) taken today"
fi
