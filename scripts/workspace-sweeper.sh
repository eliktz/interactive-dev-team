#!/bin/bash
# Workspace TTL sweeper — DEV_QA-5.
#
# Responsibilities:
#   1. Hourly: delete legacy /tmp/gonorth-qa* and /tmp/gon23-qa orphan clones
#      older than 1 day (workspace-audit found ~6.2 GB of these).
#   2. Hourly: sweep /tmp/dev-workspaces/* and /tmp/qa-workspaces/* older than 1 day.
#   3. Nightly (when invoked with --nightly): chown -R node:node the persistent
#      go-north-app workspaces' node_modules and .next, repairing damage from
#      prior `docker exec -u root` invocations (see
#      feedback_paperclip_workspace_ownership memory).
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

# --- 1. Legacy /tmp orphans (gonorth-qa*, gon23-qa) older than 1 day ---
log "sweeping legacy /tmp/gonorth-qa* and /tmp/gon23-qa orphans (>1d)"
find /tmp -maxdepth 1 \( -name 'gonorth-qa*' -o -name 'gon23-qa' \) -mtime +1 -exec rm -rf {} + 2>/dev/null || true

# --- 2. /tmp/{dev,qa}-workspaces/* older than 1 day ---
for BASE in /tmp/dev-workspaces /tmp/qa-workspaces; do
  if [ -d "$BASE" ]; then
    log "sweeping $BASE/* older than 1 day"
    find "$BASE" -mindepth 1 -maxdepth 1 -type d -mtime +1 -exec rm -rf {} + 2>/dev/null || true
  fi
done

# --- 3. Nightly chown of persistent workspaces ---
if [ "$NIGHTLY" = "1" ]; then
  log "nightly: chown -R node:node on persistent go-north-app node_modules + .next"
  # Requires root. If invoked as a non-root user, the chown will warn and continue.
  for WS in /paperclip/instances/default/workspaces/*/go-north-app; do
    [ -d "$WS" ] || continue
    for SUB in node_modules .next; do
      [ -d "$WS/$SUB" ] || continue
      chown -R node:node "$WS/$SUB" 2>&1 | tail -3 || log "  chown failed on $WS/$SUB (need root?)"
    done
  done
fi

log "sweep complete (nightly=$NIGHTLY)"
