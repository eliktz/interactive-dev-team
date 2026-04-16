#!/usr/bin/env bash
# =============================================================================
# deploy-gonorth.sh — Deploy Go-North to Plesk production
#
# Runs from inside the war-room container (or any machine with SSH access to
# deploy-plesk). Pushes to Bitbucket (for auto-deploy file sync), then SSHes
# to Plesk and runs npm install + build + Passenger restart.
#
# Usage:
#   ./deploy-gonorth.sh
#
# Requirements:
#   - SSH config with Host deploy-plesk (configured by launch.sh when
#     DEPLOY_SSH_KEY_PATH is set)
#   - Current working directory is inside /workspace/project (Go-North repo)
#     — or pass the project path as first arg
#
# Output:
#   - Deploy log to stdout
#   - Final URL on last line (for agents to extract and report)
# =============================================================================

set -euo pipefail

PROJECT_DIR="${1:-/workspace/project}"
DEPLOY_HOST="${DEPLOY_HOST:-deploy-plesk}"
REMOTE_ROOT="${REMOTE_ROOT:-/var/www/vhosts/gonorth.tlk.solutions/httpdocs}"
SITE_URL="${SITE_URL:-https://gonorth.tlk.solutions}"

log() { echo "[deploy] $*"; }

# --- Step 1: Verify local state ---
log "Checking project at $PROJECT_DIR..."
if [ ! -d "$PROJECT_DIR/.git" ]; then
  echo "ERROR: $PROJECT_DIR is not a git repository" >&2
  exit 1
fi
cd "$PROJECT_DIR"

# --- Step 2: Push any uncommitted changes ---
if ! git diff-index --quiet HEAD -- 2>/dev/null; then
  log "WARNING: Uncommitted changes detected. Commit before deploying." >&2
  git status --short
  exit 2
fi

BRANCH=$(git rev-parse --abbrev-ref HEAD)
log "On branch: $BRANCH"
log "Pushing to Bitbucket (triggers Plesk auto-file-sync)..."
git push origin "$BRANCH" 2>&1 | tail -5

# --- Step 3: Trigger build on Plesk ---
log "Connecting to $DEPLOY_HOST to run npm install + build..."
ssh -o BatchMode=yes -o StrictHostKeyChecking=no "$DEPLOY_HOST" bash -s << REMOTE_EOF
set -e
cd $REMOTE_ROOT
# Use node from nodenv / plesk
export PATH=/opt/plesk/node/24/bin:\$PATH
echo "[remote] Installing dependencies..."
npm install --production=false 2>&1 | tail -3
echo "[remote] Building Next.js..."
npm run build 2>&1 | tail -5
echo "[remote] Restarting Passenger..."
mkdir -p tmp && touch tmp/restart.txt
echo "[remote] Done."
REMOTE_EOF

# --- Step 4: Verify site is live ---
log "Waiting for restart..."
sleep 5
HTTP_CODE=$(curl -sk -o /dev/null -w "%{http_code}" "$SITE_URL/" || echo "000")
log "Site HTTP status: $HTTP_CODE"

if [ "$HTTP_CODE" = "200" ]; then
  log "DEPLOY SUCCESSFUL"
  echo
  echo "Deployed URL: $SITE_URL"
  exit 0
else
  echo "ERROR: Site returned $HTTP_CODE after deploy" >&2
  exit 3
fi
