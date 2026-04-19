#!/bin/bash
# QA Lead workspace-prep helper.
#
# Called from QA Lead's AGENTS.md Step 1b BEFORE any gate runs. Ensures the
# workspace is clean + on the PR branch we're asked to evaluate. If anything
# goes wrong, posts a real `VERDICT: INFRA_BLOCKED` comment on the Paperclip
# issue (not just a log line) so the pipeline surfaces the blocker instead
# of stalling silently.
#
# Usage:
#   bash /workspace/scripts/qa-prepare-workspace.sh <ISSUE_ID> <PR_BRANCH>
#
# Env required:
#   PAPERCLIP_API_KEY, PAPERCLIP_RUN_ID, BITBUCKET_TOKEN, GONORTH_REPO_URL
#
# Exits:
#   0 on success (workspace is on the expected branch, clean tree)
#   2 on infra failure (comment was posted; caller should exit 0 itself)

set -u

ISSUE_ID="${1:?usage: qa-prepare-workspace.sh <ISSUE_ID> <PR_BRANCH>}"
PR_BRANCH="${2:?usage: qa-prepare-workspace.sh <ISSUE_ID> <PR_BRANCH>}"

post_infra_blocked() {
  local reason="$1"
  local body="## QA Report — INFRA_BLOCKED

VERDICT: INFRA_BLOCKED

- Failed step: pre-gate workspace prep
- Root cause: $reason
- PR status: unchanged (do NOT reject)
- Action needed: operator must inspect the QA workspace and clean it manually (or identify why the branch can't be checked out)

(posted by qa-prepare-workspace.sh)"
  # jq is not guaranteed; build JSON manually, escape newlines
  local json_body
  json_body=$(printf '%s' "$body" | node -e 'let s=require("fs").readFileSync(0,"utf8");process.stdout.write(JSON.stringify({body:s}))' 2>/dev/null) || json_body="{\"body\":\"$reason\"}"
  curl -sS -o /dev/null -X POST \
    -H "Authorization: Bearer ${PAPERCLIP_API_KEY:-}" \
    -H "X-Paperclip-Run-Id: ${PAPERCLIP_RUN_ID:-}" \
    -H "Content-Type: application/json" \
    "http://localhost:3100/api/issues/${ISSUE_ID}/comments" \
    -d "$json_body" || true
  echo "[qa-prep] INFRA_BLOCKED posted: $reason"
}

# Enter the workspace
if [ ! -d go-north-app ]; then
  post_infra_blocked "go-north-app directory does not exist in QA workspace"
  exit 2
fi
cd go-north-app

# (1) Ensure remote has auth
if ! git remote get-url origin 2>/dev/null | grep -q '@bitbucket.org'; then
  if [ -n "${BITBUCKET_TOKEN:-}" ] && [ -n "${GONORTH_REPO_URL:-}" ]; then
    PUSH_URL=$(echo "$GONORTH_REPO_URL" | sed "s|https://|https://x-token-auth:${BITBUCKET_TOKEN}@|")
    git remote set-url origin "$PUSH_URL" 2>/dev/null || git remote add origin "$PUSH_URL"
  else
    post_infra_blocked "BITBUCKET_TOKEN or GONORTH_REPO_URL missing; cannot configure git remote"
    exit 2
  fi
fi

# (2) Hard reset + clean — unconditionally discard all previous run artifacts
echo "[qa-prep] Resetting workspace (discarding prior run state)..."
git reset --hard HEAD 2>&1 | tail -1
git clean -fdx 2>&1 | tail -3        # -x also removes .gitignored (test-results, .next, etc.)

# (3) Fetch + checkout the PR branch fresh
echo "[qa-prep] Fetching origin..."
if ! git fetch origin --prune 2>&1 | tail -3; then
  post_infra_blocked "git fetch origin failed"
  exit 2
fi

echo "[qa-prep] Checking out $PR_BRANCH..."
# First try: checkout the branch; if it fails, the reset may not have been enough.
if ! git checkout -B "$PR_BRANCH" "origin/$PR_BRANCH" 2>&1 | tail -3; then
  # Last resort: wipe local branch + recreate from origin
  git checkout main 2>&1 | tail -1
  git branch -D "$PR_BRANCH" 2>/dev/null || true
  if ! git checkout -b "$PR_BRANCH" "origin/$PR_BRANCH" 2>&1 | tail -3; then
    post_infra_blocked "Could not checkout $PR_BRANCH after reset+clean+branch-delete fallback"
    exit 2
  fi
fi

# (4) Fast-forward to remote tip
git reset --hard "origin/$PR_BRANCH" 2>&1 | tail -1

# (5) SANITY CHECK: verify we're actually on the branch we think we are
ACTUAL_BRANCH=$(git branch --show-current)
if [ "$ACTUAL_BRANCH" != "$PR_BRANCH" ]; then
  post_infra_blocked "Post-checkout branch mismatch: expected=$PR_BRANCH, actual=$ACTUAL_BRANCH"
  exit 2
fi

# (6) Report what we got so run logs clearly show which commit QA evaluated
HEAD_COMMIT=$(git rev-parse --short HEAD)
echo "[qa-prep] ✅ Workspace ready — branch=$PR_BRANCH head=$HEAD_COMMIT"
echo "[qa-prep] pnpm-lock.yaml present: $(test -f pnpm-lock.yaml && echo yes || echo NO)"
echo "[qa-prep] package.json present: $(test -f package.json && echo yes || echo NO)"
