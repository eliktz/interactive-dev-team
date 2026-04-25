#!/usr/bin/env bash
# install-crons.sh — M4. Idempotent installer for the M4 cron entries.
# Must run inside the war-room container (for compose-morning-digest) AND
# inside the paperclip container (for forgetting-detector + cost-alerts).
#
# Detects which container by hostname and installs only the relevant entries.

set -euo pipefail

HOST="${HOSTNAME:-$(hostname || echo unknown)}"
LOG=/tmp/m4-install-crons.log
echo "[$(date -u +%FT%TZ)] install-crons start (host=$HOST)" >>"$LOG"

mkdir -p /etc/cron.d 2>/dev/null || true

# Detect container role from hostname or presence of distinctive paths.
ROLE=""
if [ -d /paperclip/mcp-team-memory ] ; then
  ROLE="paperclip"
elif [ -d /workspace/agents ] && [ -f /workspace/agents/ceo-gonorth/IDENTITY.md ] ; then
  ROLE="war-room"
fi

case "$ROLE" in
  war-room)
    # 09:00 IDT = 06:00 UTC (IDT is UTC+3).
    cat > /etc/cron.d/m4-morning-digest <<'CRON'
# M4 A3 — daily compose-morning-digest at 09:00 IDT (06:00 UTC).
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
0 6 * * * root /workspace/scripts/m4-cron/compose-morning-digest.sh >>/tmp/m4-morning-digest.cron.log 2>&1
CRON
    chmod 0644 /etc/cron.d/m4-morning-digest
    echo "[$(date -u +%FT%TZ)] installed war-room cron(s)" >>"$LOG"
    # Try to start cron if not running.
    service cron start 2>/dev/null || cron 2>/dev/null || true
    ;;
  paperclip)
    cat > /etc/cron.d/m4-forgetting-detector <<'CRON'
# M4 — Sunday 09:00 IDT (06:00 UTC) weekly forgetting detector.
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
0 6 * * 0 root /workspace/scripts/m4-cron/forgetting-detector.sh >>/tmp/m4-forgetting-detector.cron.log 2>&1
CRON
    cat > /etc/cron.d/m4-cost-alerts <<'CRON'
# M4 — hourly cost alerts.
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
17 * * * * root /workspace/scripts/m4-cron/cost-alerts.sh >>/tmp/m4-cost-alerts.cron.log 2>&1
CRON
    chmod 0644 /etc/cron.d/m4-forgetting-detector /etc/cron.d/m4-cost-alerts
    echo "[$(date -u +%FT%TZ)] installed paperclip cron(s)" >>"$LOG"
    service cron start 2>/dev/null || cron 2>/dev/null || true
    ;;
  *)
    echo "[$(date -u +%FT%TZ)] unknown role — skipping cron install" >>"$LOG"
    ;;
esac

exit 0
