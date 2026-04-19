#!/bin/bash
# QA Lead workspace-prep helper — EPHEMERAL CLONE PATTERN.
#
# Context: the persistent QA workspace at
#   /paperclip/instances/default/workspaces/<qa-agent-id>/go-north-app
# bleeds state across runs (modified files, wrong branch, .gitignored
# artifacts, dangling local branches). Every state-bleed incident caused
# QA to evaluate the WRONG tree and post a bogus REJECTED verdict.
#
# New approach: each QA run gets a FRESH shallow clone of the PR branch
# in /tmp. When the run ends, it's automatically garbage-collected by
# the next run. No reusable state, no reset-dance, no wrong-branch bugs.
#
# Usage (from QA Lead AGENTS.md Step 1b):
#   WS=$(bash /workspace/scripts/qa-prepare-workspace.sh "$ISSUE_ID" "$PR_BRANCH" "$PAPERCLIP_RUN_ID")
#   [ -z "$WS" ] && exit 0   # prep posted INFRA_BLOCKED already
#   cd "$WS"
#   # ... run gates here ...
#
# Exits:
#   On success: prints the absolute path of the fresh workspace to stdout, exits 0.
#   On failure: posts VERDICT: INFRA_BLOCKED to the Paperclip issue, prints nothing, exits 2.
#
# Env required:
#   PAPERCLIP_API_KEY, PAPERCLIP_RUN_ID, BITBUCKET_TOKEN, GONORTH_REPO_URL

set -u

ISSUE_ID="${1:?usage: qa-prepare-workspace.sh <ISSUE_ID> <PR_BRANCH> [RUN_ID]}"
PR_BRANCH="${2:?usage: qa-prepare-workspace.sh <ISSUE_ID> <PR_BRANCH> [RUN_ID]}"
RUN_ID="${3:-${PAPERCLIP_RUN_ID:-$$}}"

# Base dir for ephemeral QA workspaces
BASE=/tmp/qa-workspaces
mkdir -p "$BASE"

# Garbage collect workspaces older than 2h to keep /tmp tidy
find "$BASE" -mindepth 1 -maxdepth 1 -type d -mmin +120 -exec rm -rf {} + 2>/dev/null || true

WS_PARENT="$BASE/$RUN_ID"
WS="$WS_PARENT/go-north-app"

post_infra_blocked() {
  local reason="$1"
  local body="## QA Report — INFRA_BLOCKED

VERDICT: INFRA_BLOCKED

- Failed step: pre-gate workspace clone
- Root cause: $reason
- PR status: unchanged (do NOT reject)
- Action needed: operator — check qa-prepare-workspace.sh logs in run $RUN_ID

(posted by qa-prepare-workspace.sh ephemeral-clone mode)"
  local json_body
  json_body=$(printf '%s' "$body" | node -e 'let s=require("fs").readFileSync(0,"utf8");process.stdout.write(JSON.stringify({body:s}))' 2>/dev/null) \
    || json_body="{\"body\":\"INFRA_BLOCKED: $reason\"}"
  curl -sS -o /dev/null -X POST \
    -H "Authorization: Bearer ${PAPERCLIP_API_KEY:-}" \
    -H "X-Paperclip-Run-Id: ${PAPERCLIP_RUN_ID:-$RUN_ID}" \
    -H "Content-Type: application/json" \
    "http://localhost:3100/api/issues/${ISSUE_ID}/comments" \
    -d "$json_body" >&2 || true
  echo "[qa-prep] INFRA_BLOCKED posted to $ISSUE_ID: $reason" >&2
}

# Build the authenticated clone URL
if [ -z "${BITBUCKET_TOKEN:-}" ] || [ -z "${GONORTH_REPO_URL:-}" ]; then
  post_infra_blocked "BITBUCKET_TOKEN or GONORTH_REPO_URL not set in env"
  exit 2
fi
AUTH_URL=$(echo "$GONORTH_REPO_URL" | sed "s|https://|https://x-token-auth:${BITBUCKET_TOKEN}@|")

# Wipe any pre-existing dir for this run id (idempotent) and clone fresh
rm -rf "$WS_PARENT"
mkdir -p "$WS_PARENT"

echo "[qa-prep] Cloning $PR_BRANCH (shallow, single-branch) -> $WS" >&2
if ! git clone --depth 1 --single-branch --branch "$PR_BRANCH" "$AUTH_URL" "$WS" 2>&1 | tail -5 >&2; then
  post_infra_blocked "git clone failed for branch $PR_BRANCH (branch may not exist on origin, or auth failed)"
  exit 2
fi

cd "$WS" || { post_infra_blocked "cloned dir does not exist at $WS"; exit 2; }

# Sanity: confirm we're on the branch and at the remote tip
ACTUAL_BRANCH=$(git branch --show-current)
if [ "$ACTUAL_BRANCH" != "$PR_BRANCH" ]; then
  post_infra_blocked "post-clone branch mismatch: expected=$PR_BRANCH, actual=$ACTUAL_BRANCH"
  exit 2
fi

HEAD_COMMIT=$(git rev-parse --short HEAD)
echo "[qa-prep] ✅ Fresh clone ready — branch=$PR_BRANCH head=$HEAD_COMMIT path=$WS" >&2
echo "[qa-prep] pnpm-lock.yaml present: $(test -f pnpm-lock.yaml && echo yes || echo NO)" >&2
echo "[qa-prep] package.json present: $(test -f package.json && echo yes || echo NO)" >&2

# Emit the path on stdout for the caller to `cd` into
echo "$WS"
