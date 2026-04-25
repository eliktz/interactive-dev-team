#!/usr/bin/env bash
# compose-morning-digest.sh — M4 A3 (M5 fix: PG read via paperclip sidecar HTTP).
#                              (scenario5-fixups: pm-behavior narrative template).
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
# scenario5-fixups: the body now follows the pm-behavior contract §1
# narrative template (Goal / Progress / Shipped today / What next / Blocker /
# ETA / Decision needed) instead of a raw NDJSON dump. Honors operator_language
# from companies/<slug>/PRODUCT-SPINE.md and the E1 bold rule (max 2 spans).
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
COMPANY_SLUG="${M4_DIGEST_COMPANY:-go-north}"
SPINE_PATH="${M4_DIGEST_SPINE:-/workspace/companies/${COMPANY_SLUG}/PRODUCT-SPINE.md}"

# Resolve operator language from spine frontmatter (fallback to env, then he).
PERSONA_LANG="${M4_DIGEST_LANG:-}"
if [ -z "$PERSONA_LANG" ] && [ -f "$SPINE_PATH" ]; then
  PERSONA_LANG="$(awk '/^operator_language:/ { gsub(/[":\047]/,"",$2); print $2; exit }' "$SPINE_PATH" 2>/dev/null || true)"
fi
PERSONA_LANG="${PERSONA_LANG:-he}"
PERSONA_PREFIX="${M4_DIGEST_PREFIX:-🧭 PM · Galileo:}"

# Trello link from env / spine (best-effort; placeholder otherwise).
TRELLO_LINK="${M4_DIGEST_TRELLO_LINK:-}"
if [ -z "$TRELLO_LINK" ] && [ -f "$SPINE_PATH" ]; then
  TRELLO_LINK="$(awk '/trello[_-]?board[_-]?url:/ { gsub(/[",\047]/,"",$2); print $2; exit }' "$SPINE_PATH" 2>/dev/null || true)"
fi

echo "[$TS] morning-digest start (real_send=${M4_DIGEST_REAL_SEND:-0} dry=$DRY_RUN since=$SINCE_ARG lang=$PERSONA_LANG)" >>"$LOG"

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

# ---------------------------------------------------------------------------
# Narrative composition (pm-behavior §1 template).
#
# Slots: Opener · Goal · Progress · Shipped today · What next · Blocker (bold
# when present) · ETA · Decision needed (bold when present) · Trello link.
#
# Honors E1 bold rule: max 2 *bolded* spans per message. We only bold "Blocker:"
# and "Decision needed:" labels, and only when they have content. That keeps us
# at most 2.
#
# Object normalization: strip a leading "[SCENARIO*-MARKER ...] " prefix
# (synthetic test rows) before showing — operator never wants to see test
# scaffolding.
# ---------------------------------------------------------------------------

# Localized labels. Per pm-behavior §1.3 (E1), max 2 *bolded* spans per
# message. We reserve those slots for the highest-signal lines: Shipped today
# + (Blocker | Decision needed). The other slot labels (Goal / Progress / What
# next / ETA) render as plain prose. See compose_narrative() for the bold-budget
# accounting.
if [ "$PERSONA_LANG" = "he" ] ; then
  L_OPENER="בוקר טוב."
  L_GOAL="יעד:"
  L_PROGRESS="התקדמות:"
  L_SHIPPED_LABEL="שוחרר היום"
  L_WHATNEXT="הצעד הבא:"
  L_BLOCKER_LABEL="חסם"
  L_ETA="ETA:"
  L_DECISION_LABEL="החלטה נדרשת"
  L_TRELLO="לוח Trello:"
  L_QUIET="יום שקט — לא יצא דבר במהלך הלילה."
  L_NONE="—"
  L_PROGRESS_FMT_ONE="פריט אחד שוחרר"
  L_PROGRESS_FMT_MANY_PRE=""
  L_PROGRESS_FMT_MANY_POST="פריטים שוחררו"
else
  L_OPENER="Good morning."
  L_GOAL="Goal:"
  L_PROGRESS="Progress:"
  L_SHIPPED_LABEL="Shipped today"
  L_WHATNEXT="What next:"
  L_BLOCKER_LABEL="Blocker"
  L_ETA="ETA:"
  L_DECISION_LABEL="Decision needed"
  L_TRELLO="Trello:"
  L_QUIET="Quiet day — no ships overnight."
  L_NONE="—"
  L_PROGRESS_FMT_ONE="1 item shipped"
  L_PROGRESS_FMT_MANY_PRE=""
  L_PROGRESS_FMT_MANY_POST="items shipped"
fi

# Pull static spine slots (best effort). Goal = Mission first paragraph; What next
# = first row of Milestones if not TODO.
SPINE_GOAL=""
SPINE_NEXT=""
if [ -f "$SPINE_PATH" ] ; then
  SPINE_GOAL="$(awk 'BEGIN{m=0} /^## Mission/{m=1;next} /^## /{m=0} m && NF && $0 !~ /^>/ && $0 !~ /^TODO/ {print; exit}' "$SPINE_PATH" 2>/dev/null | head -c 200 || true)"
  SPINE_NEXT="$(awk 'BEGIN{m=0;skip=2} /^## Milestones/{m=1;next} /^## /{m=0} m && /^\| / { if (skip>0) {skip--; next}; print; exit }' "$SPINE_PATH" 2>/dev/null | head -c 200 || true)"
fi

# Strip SCENARIO* test markers from object text — keep operator output clean.
strip_marker() {
  # echo arg with leading [SCENARIO...-MARKER ...] removed
  printf '%s' "$1" | sed -E 's/^\[?SCENARIO[A-Z0-9_-]*-MARKER[^]]*\]?[ :|-]*//'
}

# Build groups from ENTRIES_FILE (NDJSON, one entry per line).
SHIPPED_LINES=""
DECIDED_LINES=""
BLOCKED_LINES=""
SHIP_COUNT=0
DECIDE_COUNT=0
BLOCK_COUNT=0
DECISION_TEXT=""
BLOCKER_TEXT=""

if [ "$ENTRY_COUNT" -gt 0 ] && command -v jq >/dev/null 2>&1 ; then
  # Iterate via NUL-delimited records to keep multi-word objects intact.
  while IFS=$'\t' read -r verb obj iref ; do
    obj_clean="$(strip_marker "$obj")"
    case "$verb" in
      shipped|done|verified*)
        SHIP_COUNT=$((SHIP_COUNT + 1))
        if [ "$SHIP_COUNT" -le 3 ] ; then
          if [ -n "$iref" ] ; then
            SHIPPED_LINES="${SHIPPED_LINES}- ${iref}: ${obj_clean}"$'\n'
          else
            SHIPPED_LINES="${SHIPPED_LINES}- ${obj_clean}"$'\n'
          fi
        fi
        ;;
      decided|decision)
        DECIDE_COUNT=$((DECIDE_COUNT + 1))
        [ -z "$DECISION_TEXT" ] && DECISION_TEXT="$obj_clean"
        DECIDED_LINES="${DECIDED_LINES}- ${obj_clean}"$'\n'
        ;;
      blocked|blocker)
        BLOCK_COUNT=$((BLOCK_COUNT + 1))
        [ -z "$BLOCKER_TEXT" ] && BLOCKER_TEXT="$obj_clean"
        BLOCKED_LINES="${BLOCKED_LINES}- ${obj_clean}"$'\n'
        ;;
    esac
  done < <(jq -r '[(.verb // ""), (.object // ""), (.issue_ref // "")] | @tsv' "$ENTRIES_FILE")
fi

render_progress() {
  if [ "$SHIP_COUNT" -le 0 ] ; then
    printf '%s' "$L_NONE"
  elif [ "$SHIP_COUNT" -eq 1 ] ; then
    printf '%s' "$L_PROGRESS_FMT_ONE"
  else
    printf '%s %s' "$SHIP_COUNT" "$L_PROGRESS_FMT_MANY_POST"
  fi
}

compose_narrative() {
  # E1 bold budget: max 2 spans. Allocate by priority:
  #   1) Decision needed (highest — operator action gated)
  #   2) Blocker         (next — operator may need to unblock)
  #   3) Shipped today   (default — main visible signal)
  # Compute budget BEFORE rendering so we know which labels get bolded.
  local bold_decision=0 bold_blocker=0 bold_shipped=0 budget=2
  if [ -n "$DECISION_TEXT" ] && [ "$budget" -gt 0 ] ; then bold_decision=1; budget=$((budget-1)); fi
  if [ -n "$BLOCKER_TEXT" ]  && [ "$budget" -gt 0 ] ; then bold_blocker=1;  budget=$((budget-1)); fi
  if [ "$SHIP_COUNT" -gt 0 ] && [ "$budget" -gt 0 ] ; then bold_shipped=1;  budget=$((budget-1)); fi

  local lab_shipped="$L_SHIPPED_LABEL:"
  local lab_blocker="${L_BLOCKER_LABEL}:"
  local lab_decision="${L_DECISION_LABEL}:"
  [ "$bold_shipped"  = "1" ] && lab_shipped="*${L_SHIPPED_LABEL}:*"
  [ "$bold_blocker"  = "1" ] && lab_blocker="*${L_BLOCKER_LABEL}:*"
  [ "$bold_decision" = "1" ] && lab_decision="*${L_DECISION_LABEL}:*"

  # Opener
  echo "$L_OPENER"
  echo
  # Goal (plain — bold reserved for high-signal slots)
  if [ -n "$SPINE_GOAL" ] ; then
    echo "$L_GOAL ${SPINE_GOAL}"
  else
    echo "$L_GOAL ${L_NONE}"
  fi
  # Progress (plain)
  echo "$L_PROGRESS $(render_progress)"
  echo
  # Shipped today (bold label by E1 priority budget)
  if [ "$SHIP_COUNT" -gt 0 ] ; then
    echo "$lab_shipped"
    printf '%s' "$SHIPPED_LINES"
  else
    echo "${lab_shipped} ${L_QUIET}"
  fi
  echo
  # What next (plain)
  if [ -n "$SPINE_NEXT" ] ; then
    echo "$L_WHATNEXT ${SPINE_NEXT}"
  else
    echo "$L_WHATNEXT ${L_NONE}"
  fi
  # Blocker — only when present (label bolded by budget)
  if [ -n "$BLOCKER_TEXT" ] ; then
    echo "${lab_blocker} ${BLOCKER_TEXT}"
  fi
  # ETA (plain)
  echo "$L_ETA ${L_NONE}"
  # Decision needed — only when present (label bolded by budget)
  if [ -n "$DECISION_TEXT" ] ; then
    echo "${lab_decision} ${DECISION_TEXT}"
  fi
  # Trello link (placeholder if none)
  echo
  if [ -n "$TRELLO_LINK" ] ; then
    echo "${L_TRELLO} ${TRELLO_LINK}"
  fi
}

if [ "$DRY_RUN" = "1" ] ; then
  echo "[$TS] DRY RUN — would compose digest from $ENTRY_COUNT entries (source=$SOURCE_USED)" >>"$LOG"
  echo "--- DRY RUN BODY ---"
  echo "# Morning digest — ${TODAY} (lang=${PERSONA_LANG}) [DRY] source=$SOURCE_USED"
  echo
  echo "${PERSONA_PREFIX}"
  echo
  compose_narrative
  echo "--- END DRY RUN ---"
  exit 0
fi

# Compose digest in operator language (he default), narrative template.
{
  echo "# Morning digest — ${TODAY} (lang=${PERSONA_LANG})"
  echo
  echo "${PERSONA_PREFIX}"
  echo
  compose_narrative
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
