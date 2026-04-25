#!/usr/bin/env bash
# compose-morning-digest.sh — M4 A3.
# Daily 09:00 IDT cron in the war-room container. Composes a CEO morning
# digest from the activity_feed (PG) entries since the last digest run, and
# logs a "would-send" line. DOES NOT actually send to Telegram in this build.
#
# Wired by /etc/cron.d/m4-morning-digest installed at container boot.
# Logs to /tmp/m4-morning-digest.log + /workspace/.morning-digests/<date>.md.
#
# To enable real send: set M4_DIGEST_REAL_SEND=1 and the Telegram bot creds.

set -euo pipefail

LOG=/tmp/m4-morning-digest.log
mkdir -p /workspace/.morning-digests 2>/dev/null || true

TS="$(date -u +%FT%TZ)"
TODAY="$(date +%F)"
DIGEST_PATH="/workspace/.morning-digests/${TODAY}.md"

PG_URL="${M4_DIGEST_PG_URL:-postgres://paperclip:paperclip@paperclip:54329/paperclip}"
PERSONA_LANG="${M4_DIGEST_LANG:-he}"
PERSONA_PREFIX="${M4_DIGEST_PREFIX:-🧭 PM · Galileo:}"

echo "[$TS] morning-digest start (real_send=${M4_DIGEST_REAL_SEND:-0})" >>"$LOG"

# Pull undigested activity_feed rows. If psql unavailable or PG unreachable,
# fall back to the file spillover.
ENTRIES_FILE="$(mktemp -t digest-entries.XXXXXX)"
trap 'rm -f "$ENTRIES_FILE"' EXIT

if command -v psql >/dev/null 2>&1 ; then
  if psql "$PG_URL" -At -c "SELECT ts, source, persona_slug, verb, object, issue_ref FROM activity_feed WHERE digested_at IS NULL ORDER BY ts ASC LIMIT 50" > "$ENTRIES_FILE" 2>>"$LOG" ; then
    echo "[$TS] read $(wc -l <"$ENTRIES_FILE") entries from PG" >>"$LOG"
  else
    echo "[$TS] PG unreachable — falling back to file spillover" >>"$LOG"
    if [ -f /workspace/dev-activity-feed.ndjson ] ; then
      tail -n 50 /workspace/dev-activity-feed.ndjson > "$ENTRIES_FILE"
    fi
  fi
else
  if [ -f /workspace/dev-activity-feed.ndjson ] ; then
    tail -n 50 /workspace/dev-activity-feed.ndjson > "$ENTRIES_FILE"
  fi
fi

ENTRY_COUNT="$(wc -l <"$ENTRIES_FILE" | tr -d ' ' || echo 0)"

# Compose digest in operator language (he default). Stub template:
{
  echo "# Morning digest — ${TODAY} (lang=${PERSONA_LANG})"
  echo
  echo "${PERSONA_PREFIX}"
  echo
  if [ "$ENTRY_COUNT" = "0" ] ; then
    if [ "$PERSONA_LANG" = "he" ] ; then
      echo "בוקר טוב. אין שינויים חדשים מאז העדכון האחרון."
    else
      echo "Good morning. No new changes since last digest."
    fi
  else
    if [ "$PERSONA_LANG" = "he" ] ; then
      echo "בוקר טוב. הנה מה שקרה אתמול:"
    else
      echo "Good morning. Here's what shipped overnight:"
    fi
    echo
    head -20 "$ENTRIES_FILE" | while IFS= read -r line ; do
      echo "- $line"
    done
  fi
  echo
  echo "_(auto-composed by M4 A3 cron at ${TS}; would-send=${M4_DIGEST_REAL_SEND:-0})_"
} > "$DIGEST_PATH"

echo "[$TS] digest written to $DIGEST_PATH (entries=$ENTRY_COUNT)" >>"$LOG"

# Mark entries digested in PG (only if PG read succeeded).
if [ "$ENTRY_COUNT" -gt 0 ] && command -v psql >/dev/null 2>&1 ; then
  psql "$PG_URL" -c "UPDATE activity_feed SET digested_at = now() WHERE digested_at IS NULL" >>"$LOG" 2>&1 || true
fi

# REAL SEND PATH (gated). In this build we do NOT actually send.
if [ "${M4_DIGEST_REAL_SEND:-0}" = "1" ] ; then
  echo "[$TS] REAL_SEND=1 but path not wired in M4 build — log only" >>"$LOG"
else
  echo "[$TS] would-send: $(wc -c <"$DIGEST_PATH") bytes to operator (lang=$PERSONA_LANG)" >>"$LOG"
fi

exit 0
