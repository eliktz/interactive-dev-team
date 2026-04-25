#!/usr/bin/env bash
# compose-morning-digest.sh — M4 A3 (M5 fix: PG read via paperclip sidecar HTTP).
# Daily 09:00 IDT cron in the war-room container. Composes a CEO morning
# digest from the activity_feed (PG) entries since the last digest run, and
# logs a "would-send" line. DOES NOT actually send to Telegram unless
# M4_DIGEST_REAL_SEND=1.
#
# Wired by /etc/cron.d/m4-morning-digest installed at container boot.
# Logs to /tmp/m4-morning-digest.log + /workspace/.morning-digests/<date>.md.
#
# M5: avoids the "war-room has no psql" trap by calling the paperclip-side
# UI sidecar at $M4_DIGEST_API_URL (default http://paperclip:3101). The
# endpoint /api/activity-feed?undigested=1 returns JSON. Falls back to direct
# psql (if installed in war-room) and then to the file spillover.
#
# CLI flags (all optional):
#   --dry              do not write the digest file or POST mark-digested
#   --since="<rel>"    pass a since_iso filter to /api/activity-feed
#                      (e.g. "30 minutes ago" — resolved by `date -d`)

set -euo pipefail

LOG=/tmp/m4-morning-digest.log
mkdir -p /workspace/.morning-digests 2>/dev/null || true

DRY_RUN=0
SINCE_ARG=""
for arg in "$@"; do
  case "$arg" in
    --dry) DRY_RUN=1 ;;
    --since=*) SINCE_ARG="${arg#--since=}" ;;
  esac
done

TS="$(date -u +%FT%TZ)"
TODAY="$(date +%F)"
DIGEST_PATH="/workspace/.morning-digests/${TODAY}.md"

PG_URL="${M4_DIGEST_PG_URL:-postgres://paperclip:paperclip@paperclip:54329/paperclip}"
API_URL="${M4_DIGEST_API_URL:-http://paperclip:3101}"
PERSONA_LANG="${M4_DIGEST_LANG:-he}"
PERSONA_PREFIX="${M4_DIGEST_PREFIX:-🧭 PM · Galileo:}"

echo "[$TS] morning-digest start (real_send=${M4_DIGEST_REAL_SEND:-0} dry=$DRY_RUN since=$SINCE_ARG)" >>"$LOG"

ENTRIES_FILE="$(mktemp -t digest-entries.XXXXXX)"
DIGESTED_IDS_FILE="$(mktemp -t digest-ids.XXXXXX)"
trap 'rm -f "$ENTRIES_FILE" "$DIGESTED_IDS_FILE"' EXIT

read_via_api() {
  local url="${API_URL}/api/activity-feed?undigested=1&limit=50"
  if [ -n "$SINCE_ARG" ] ; then
    local since_iso
    since_iso="$(date -u -d "$SINCE_ARG" +%FT%TZ 2>/dev/null || true)"
    if [ -n "$since_iso" ] ; then
      url="${API_URL}/api/activity-feed?since_iso=${since_iso}&limit=50"
    fi
  fi
  if ! command -v curl >/dev/null 2>&1 ; then return 1 ; fi
  local raw
  raw="$(curl -sS --max-time 10 "$url" 2>>"$LOG" || true)"
  if [ -z "$raw" ] ; then return 1 ; fi
  if ! command -v jq >/dev/null 2>&1 ; then
    # No jq — bail to next fallback rather than hand-parse.
    return 1
  fi
  local ok
  ok="$(printf '%s' "$raw" | jq -r '.ok // false' 2>/dev/null || echo "false")"
  if [ "$ok" != "true" ] ; then return 1 ; fi
  printf '%s' "$raw" | jq -c '.entries[] | {ts, source, persona: .persona_slug, verb, object, issue_ref}' > "$ENTRIES_FILE"
  printf '%s' "$raw" | jq -r '.entries[].id' > "$DIGESTED_IDS_FILE"
  return 0
}

read_via_psql() {
  command -v psql >/dev/null 2>&1 || return 1
  psql "$PG_URL" -At -F $'\t' -c "SELECT ts, source, COALESCE(persona_slug,''), verb, object, COALESCE(issue_ref,'') FROM activity_feed WHERE digested_at IS NULL ORDER BY ts ASC LIMIT 50" > "$ENTRIES_FILE" 2>>"$LOG"
}

read_via_file() {
  local path="${M4_DIGEST_FEED_PATH:-/workspace/dev-activity-feed.ndjson}"
  [ -f "$path" ] || return 1
  tail -n 50 "$path" > "$ENTRIES_FILE"
}

SOURCE_USED="none"
if read_via_api ; then
  SOURCE_USED="api"
  echo "[$TS] read $(wc -l <"$ENTRIES_FILE") entries via $API_URL" >>"$LOG"
elif read_via_psql ; then
  SOURCE_USED="psql"
  echo "[$TS] read $(wc -l <"$ENTRIES_FILE") entries via psql" >>"$LOG"
elif read_via_file ; then
  SOURCE_USED="file"
  echo "[$TS] read $(wc -l <"$ENTRIES_FILE") entries via file fallback" >>"$LOG"
else
  : > "$ENTRIES_FILE"
  echo "[$TS] no source available — empty digest" >>"$LOG"
fi

ENTRY_COUNT="$(wc -l <"$ENTRIES_FILE" | tr -d ' ' || echo 0)"

if [ "$DRY_RUN" = "1" ] ; then
  echo "[$TS] DRY RUN — would compose digest from $ENTRY_COUNT entries (source=$SOURCE_USED)" >>"$LOG"
  echo "--- DRY RUN BODY ---"
  echo "# Morning digest — ${TODAY} (lang=${PERSONA_LANG}) [DRY] source=$SOURCE_USED"
  echo
  echo "${PERSONA_PREFIX}"
  echo
  if [ "$ENTRY_COUNT" = "0" ] ; then
    echo "(no entries)"
  else
    head -20 "$ENTRIES_FILE" | while IFS= read -r line ; do
      echo "- $line"
    done
  fi
  echo "--- END DRY RUN ---"
  exit 0
fi

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
  echo "_(auto-composed by M4 A3 cron at ${TS}; source=${SOURCE_USED}; would-send=${M4_DIGEST_REAL_SEND:-0})_"
} > "$DIGEST_PATH"

echo "[$TS] digest written to $DIGEST_PATH (entries=$ENTRY_COUNT, source=$SOURCE_USED)" >>"$LOG"

# Mark entries digested. If we read via API, POST the id list back. Else fall
# back to psql UPDATE (best-effort).
if [ "$ENTRY_COUNT" -gt 0 ] ; then
  if [ "$SOURCE_USED" = "api" ] && [ -s "$DIGESTED_IDS_FILE" ] && command -v curl >/dev/null 2>&1 ; then
    IDS_CSV="$(paste -sd, "$DIGESTED_IDS_FILE")"
    curl -sS --max-time 10 -X POST "${API_URL}/api/activity-feed/mark-digested?ids=${IDS_CSV}" >>"$LOG" 2>&1 || true
  elif command -v psql >/dev/null 2>&1 ; then
    psql "$PG_URL" -c "UPDATE activity_feed SET digested_at = now() WHERE digested_at IS NULL" >>"$LOG" 2>&1 || true
  fi
fi

# REAL SEND PATH (gated). In this build we do NOT actually send.
if [ "${M4_DIGEST_REAL_SEND:-0}" = "1" ] ; then
  echo "[$TS] REAL_SEND=1 but path not wired in M4/M5 build — log only" >>"$LOG"
else
  echo "[$TS] would-send: $(wc -c <"$DIGEST_PATH") bytes to operator (lang=$PERSONA_LANG)" >>"$LOG"
fi

exit 0
