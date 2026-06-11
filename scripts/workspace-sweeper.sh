#!/bin/bash
# Workspace TTL sweeper — DEV_QA-5.
#
# Responsibilities:
#   1. Hourly: sweep /tmp/dev-workspaces/* and /tmp/qa-workspaces/* older than 1 day.
#   2. Nightly (when invoked with --nightly): chown -R node:node the persistent
#      ${PROJECT_WORKSPACE_NAME} workspaces' node_modules and .next, repairing
#      damage from prior `docker exec -u root` invocations (see
#      feedback_paperclip_workspace_ownership memory).
#
# Env (both optional; nightly chown is skipped when neither resolves):
#   PROJECT_WORKSPACE_NAME  workspace dir name inside each agent workspace
#   PROJECT_REPO_URL        fallback — basename (minus .git) is used
#
# Wire-up options (choose one based on ops preference):
#
#   A. cron inside the Paperclip container:
#      /etc/cron.d/workspace-sweeper:
#        0 * * * * node bash /workspace/scripts/workspace-sweeper.sh >>/var/log/workspace-sweeper.log 2>&1
#        30 3 * * * root bash /workspace/scripts/workspace-sweeper.sh --nightly >>/var/log/workspace-sweeper.log 2>&1
#
#   B. docker-compose healthcheck-style entrypoint:
#      add to entrypoint.sh: (while true; do bash /workspace/scripts/workspace-sweeper.sh; sleep 3600; done) &
#      and run the --nightly branch from a separate root-capable sidecar.
#
# Either option is acceptable. The script is idempotent — running it
# multiple times per hour is safe.

set -u

NIGHTLY=0
if [ "${1:-}" = "--nightly" ]; then
  NIGHTLY=1
fi

log() { echo "[workspace-sweeper] $(date -Iseconds) $*"; }

# Workspace dir name: explicit env wins, else derived from the repo URL.
WORKSPACE_NAME="${PROJECT_WORKSPACE_NAME:-}"
if [ -z "$WORKSPACE_NAME" ] && [ -n "${PROJECT_REPO_URL:-}" ]; then
  WORKSPACE_NAME="$(basename "${PROJECT_REPO_URL%/}" .git)"
fi

# --- 1. /tmp/{dev,qa}-workspaces/* older than 1 day ---
for BASE in /tmp/dev-workspaces /tmp/qa-workspaces; do
  if [ -d "$BASE" ]; then
    log "sweeping $BASE/* older than 1 day"
    find "$BASE" -mindepth 1 -maxdepth 1 -type d -mtime +1 -exec rm -rf {} + 2>/dev/null || true
  fi
done

# --- 2. Nightly chown of persistent workspaces ---
if [ "$NIGHTLY" = "1" ]; then
  if [ -z "$WORKSPACE_NAME" ]; then
    log "nightly: PROJECT_WORKSPACE_NAME not set (and no PROJECT_REPO_URL to derive it) — skipping persistent-workspace chown"
  else
    log "nightly: chown -R node:node on persistent $WORKSPACE_NAME node_modules + .next"
    # Requires root. If invoked as a non-root user, the chown will warn and continue.
    for WS in /paperclip/instances/default/workspaces/*/"$WORKSPACE_NAME"; do
      [ -d "$WS" ] || continue
      for SUB in node_modules .next; do
        [ -d "$WS/$SUB" ] || continue
        chown -R node:node "$WS/$SUB" 2>&1 | tail -3 || log "  chown failed on $WS/$SUB (need root?)"
      done
    done
  fi
fi

log "sweep complete (nightly=$NIGHTLY)"
