#!/usr/bin/env bash
# =============================================================================
# deploy-gonorth.sh — Deploy the squad's project repo to Plesk production
#
# (File name kept for compatibility with existing agent instructions; the
# deploy target itself is fully env-driven — nothing Go-North-specific left.)
#
# Runs from inside the war-room container (or any machine with SSH access to
# the deploy host). Pushes to Bitbucket (for auto-deploy file sync), then
# SSHes to Plesk and runs npm install + build + Passenger restart.
#
# Usage:
#   ./deploy-gonorth.sh [project-dir]
#
# Requirements:
#   - SSH config with Host deploy-plesk (written by launch.sh when the deploy
#     key is mounted AND DEPLOY_SSH_HOST/DEPLOY_SSH_USER are set)
#   - REMOTE_ROOT (or DEPLOY_REMOTE_ROOT): Plesk vhost docroot, e.g.
#     /var/www/vhosts/<site>/httpdocs
#   - SITE_URL (or DEPLOY_SITE_URL): public URL used for the post-deploy check
#   - Current working directory is inside /workspace/project (project repo)
#     — or pass the project path as first arg
#
# Output:
#   - Deploy log to stdout
#   - Final URL on last line (for agents to extract and report)
# =============================================================================

set -euo pipefail

PROJECT_DIR="${1:-/workspace/project}"
DEPLOY_HOST="${DEPLOY_HOST:-deploy-plesk}"
REMOTE_ROOT="${REMOTE_ROOT:-${DEPLOY_REMOTE_ROOT:-}}"
SITE_URL="${SITE_URL:-${DEPLOY_SITE_URL:-}}"

log() { echo "[deploy] $*"; }

# --- Step 0: Verify the deploy target is configured (env-driven, fail loud) ---
if [ -z "$REMOTE_ROOT" ] || [ -z "$SITE_URL" ]; then
  echo "ERROR: deploy target not configured." >&2
  echo "  Set REMOTE_ROOT (or DEPLOY_REMOTE_ROOT) and SITE_URL (or DEPLOY_SITE_URL)" >&2
  echo "  in the squad .env (see deploy/templates/squad.env.template)." >&2
  exit 1
fi

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
