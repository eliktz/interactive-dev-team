#!/bin/bash
# Dev workspace-prep helper — EPHEMERAL CLONE PATTERN.
#
# Context: persistent-per-agent Dev workspaces at
#   /paperclip/instances/default/workspaces/<dev-agent-id>/go-north-app
# bleed state across issues. node_modules drifts from pnpm-lock.yaml,
# feature branches collide, and `node:node` ownership gets poisoned by
# prior `docker exec -u root`. Every state-bleed incident caused Dev
# to see green while QA saw red.
#
# New approach: mirror QA's `0de0e49` design. Each dev run gets a FRESH
# shallow clone of the feature branch in /tmp. When the run ends, it's
# garbage-collected by the next run. No reusable state, no stale
# node_modules, no branch contamination.
#
# Usage (from backend-dev/frontend-dev AGENTS.md Step 1b):
#   DEV_WS=$(bash /workspace/scripts/dev-prepare-workspace.sh "$ISSUE_ID" "$BRANCH" "$PAPERCLIP_RUN_ID")
#   [ -z "$DEV_WS" ] && exit 0   # prep posted INFRA_BLOCKED already
#   cd "$DEV_WS"
#   # ... make changes, commit, push ...
#
# Exits:
#   On success: prints the absolute path of the fresh workspace to stdout, exits 0.
#   On failure: posts INFRA_BLOCKED to the Paperclip issue, prints nothing, exits 2.
#
# Env required:
#   PAPERCLIP_API_KEY, PAPERCLIP_RUN_ID, BITBUCKET_TOKEN, GONORTH_REPO_URL

set -u

ISSUE_ID="${1:?usage: dev-prepare-workspace.sh <ISSUE_ID> <BRANCH> [RUN_ID]}"
BRANCH="${2:?usage: dev-prepare-workspace.sh <ISSUE_ID> <BRANCH> [RUN_ID]}"
RUN_ID="${3:-${PAPERCLIP_RUN_ID:-$$}}"

# Base dir for ephemeral Dev workspaces
BASE=/tmp/dev-workspaces
mkdir -p "$BASE"

# Garbage collect workspaces older than 4h to keep /tmp tidy. The TTL sweeper
# (workspace-sweeper.sh) handles longer-lived cleanup; this is an in-band GC.
find "$BASE" -mindepth 1 -maxdepth 1 -type d -mmin +240 -exec rm -rf {} + 2>/dev/null || true

WS_PARENT="$BASE/$RUN_ID"
WS="$WS_PARENT/go-north-app"

post_infra_blocked() {
  local reason="$1"
  local body="## Dev Prep — INFRA_BLOCKED

VERDICT: INFRA_BLOCKED

- Failed step: pre-work workspace clone
- Root cause: $reason
- Action needed: operator — check dev-prepare-workspace.sh logs in run $RUN_ID

(posted by dev-prepare-workspace.sh ephemeral-clone mode)"
  local json_body
  json_body=$(printf '%s' "$body" | node -e 'let s=require("fs").readFileSync(0,"utf8");process.stdout.write(JSON.stringify({body:s}))' 2>/dev/null) \
    || json_body="{\"body\":\"INFRA_BLOCKED: $reason\"}"
  curl -sS -o /dev/null -X POST \
    -H "Authorization: Bearer ${PAPERCLIP_API_KEY:-}" \
    -H "X-Paperclip-Run-Id: ${PAPERCLIP_RUN_ID:-$RUN_ID}" \
    -H "Content-Type: application/json" \
    "http://localhost:3100/api/issues/${ISSUE_ID}/comments" \
    -d "$json_body" >&2 || true
  echo "[dev-prep] INFRA_BLOCKED posted to $ISSUE_ID: $reason" >&2
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

echo "[dev-prep] Cloning (depth 50) -> $WS" >&2
# Try branch first; if not on origin yet (new feature branch), clone main then checkout -b
if git ls-remote --exit-code --heads "$AUTH_URL" "$BRANCH" >/dev/null 2>&1; then
  if ! git clone --depth 50 --branch "$BRANCH" "$AUTH_URL" "$WS" 2>&1 | tail -5 >&2; then
    post_infra_blocked "git clone failed for branch $BRANCH"
    exit 2
  fi
else
  echo "[dev-prep] Branch $BRANCH not on origin yet — cloning main and creating branch" >&2
  if ! git clone --depth 50 --branch main "$AUTH_URL" "$WS" 2>&1 | tail -5 >&2; then
    post_infra_blocked "git clone failed for main (fallback)"
    exit 2
  fi
  (cd "$WS" && git checkout -b "$BRANCH") || {
    post_infra_blocked "unable to create local branch $BRANCH"
    exit 2
  }
fi

cd "$WS" || { post_infra_blocked "cloned dir does not exist at $WS"; exit 2; }

# Install dependencies with frozen lockfile — same as QA so Dev sees what QA sees
echo "[dev-prep] pnpm install --frozen-lockfile" >&2
if ! pnpm install --frozen-lockfile 2>&1 | tail -5 >&2; then
  post_infra_blocked "pnpm install --frozen-lockfile failed in fresh clone (likely lockfile drift on origin)"
  exit 2
fi

HEAD_COMMIT=$(git rev-parse --short HEAD)
echo "[dev-prep] Fresh clone ready — branch=$BRANCH head=$HEAD_COMMIT path=$WS" >&2

# Emit the path on stdout for the caller to `cd` into
echo "$WS"
