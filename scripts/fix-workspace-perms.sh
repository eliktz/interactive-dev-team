#!/usr/bin/env bash
# Fix ownership of Paperclip agent workspaces.
#
# Background: Paperclip container runs as root, but spawns agent subprocesses
# as the `node` user (uid 1000). Workspaces at /paperclip/instances/default/workspaces/
# must be owned by node:node. If any commands were run as root inside a workspace,
# files can get root-owned and the agent (as node) can't update them — especially
# .git/refs/remotes/origin/ which breaks git push silently.
#
# Usage: ./scripts/fix-workspace-perms.sh
# Run this if agents are completing tasks but their branches aren't on Bitbucket.
#
# Safe to run anytime (idempotent).

set -e

PAPERCLIP_CONTAINER="${PAPERCLIP_CONTAINER:-interactive-dev-team-paperclip-1}"

echo "[fix-perms] Fixing workspace ownership in $PAPERCLIP_CONTAINER..."

docker exec -u root "$PAPERCLIP_CONTAINER" bash -c '
if [ -d /paperclip/instances/default/workspaces ]; then
  for ws in /paperclip/instances/default/workspaces/*/; do
    if [ -d "$ws" ]; then
      owner_changed=$(find "$ws" -not -user 1000 -print -quit 2>/dev/null)
      if [ -n "$owner_changed" ]; then
        chown -R 1000:1000 "$ws"
        echo "  Fixed: $ws (had root-owned files)"
      else
        echo "  OK: $ws"
      fi
    fi
  done
else
  echo "  No workspaces directory found"
fi
'

echo "[fix-perms] Done."
