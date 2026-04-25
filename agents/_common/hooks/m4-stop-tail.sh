#!/usr/bin/env bash
# m4-stop-tail.sh — M4 cross-persona Stop sync (A4) + UX→CEO sync (A1).
# Invoked by each persona's stop-append-activity.sh AFTER the existing NDJSON
# write. Adds two side-effects:
#
#   A4 (cross-persona Stop sync):
#     Append a 1-line summary to /workspace/team-recent.md, capped at 100 lines
#     FIFO. Each persona's SessionStart hook reads this file into its
#     additionalContext so personas see what others just did.
#
#   A1 (UX→CEO sync):
#     If persona is ux-gonorth AND the outbound was design-tagged (#design or
#     contains "design"/"mockup"/"layout" cues), append a line to
#     /workspace/agents/ceo-gonorth/memory/inbox-from-ux.md so the CEO sees
#     the proposal on next SessionStart.
#
# Inputs (all optional, falls back to defaults):
#   CC_STDIN_PAYLOAD — original Stop payload (stringified JSON)
#   PERSONA          — persona slug (caller already exported)
#   VERB / OBJECT    — derived by caller, used to compose summary line
#
# Side-effects: file writes only. Never errors out (best-effort).

set -euo pipefail

PERSONA="${PERSONA:-${1:-unknown}}"
VERB="${VERB:-${2:-replied}}"
OBJECT="${OBJECT:-${3:-unknown}}"
PAYLOAD="${CC_STDIN_PAYLOAD:-${4:-}}"

WORKSPACE_ROOT="${WORKSPACE_ROOT:-/workspace}"
TEAM_RECENT="${TEAM_RECENT_PATH:-${WORKSPACE_ROOT}/team-recent.md}"
TEAM_RECENT_CAP="${TEAM_RECENT_CAP:-100}"
CEO_INBOX="${CEO_INBOX_PATH:-${WORKSPACE_ROOT}/agents/ceo-gonorth/memory/inbox-from-ux.md}"

TS="$(date -u +%FT%TZ)"

# ---------------------------------------------------------------- A4 ---------
# Append "[ts] persona verb object" to team-recent.md (FIFO cap).
mkdir -p "$(dirname "$TEAM_RECENT")" 2>/dev/null || true
{
  printf '[%s] %-12s %s %s\n' "$TS" "$PERSONA" "$VERB" "$OBJECT"
} >>"$TEAM_RECENT" 2>/dev/null || true

# Trim to last $TEAM_RECENT_CAP lines if file grew past cap.
if [ -f "$TEAM_RECENT" ]; then
  LINES="$(wc -l <"$TEAM_RECENT" 2>/dev/null | tr -d ' ' || echo 0)"
  if [ "$LINES" -gt "$TEAM_RECENT_CAP" ]; then
    TMP_TR="$(mktemp -t team-recent.XXXXXX 2>/dev/null || echo "${TEAM_RECENT}.tmp")"
    tail -n "$TEAM_RECENT_CAP" "$TEAM_RECENT" >"$TMP_TR" 2>/dev/null
    mv "$TMP_TR" "$TEAM_RECENT" 2>/dev/null || true
  fi
fi

# ---------------------------------------------------------------- A1 ---------
# UX→CEO sync: if persona == ux-gonorth and outbound smells like a design post.
if [ "$PERSONA" = "ux-gonorth" ]; then
  IS_DESIGN=0
  # Check object/verb for #design markers OR payload for design-related cues.
  case "$OBJECT" in
    *design*|*mockup*|*layout*|*figma*) IS_DESIGN=1 ;;
  esac
  if [ "$IS_DESIGN" = "0" ] && [ -n "$PAYLOAD" ]; then
    if printf '%s' "$PAYLOAD" | grep -qiE '#design|mockup|layout|figma|wireframe|prototype' ; then
      IS_DESIGN=1
    fi
  fi

  if [ "$IS_DESIGN" = "1" ]; then
    mkdir -p "$(dirname "$CEO_INBOX")" 2>/dev/null || true
    {
      printf '[%s] UX→CEO: Iris %s %s\n' "$TS" "$VERB" "$OBJECT"
    } >>"$CEO_INBOX" 2>/dev/null || true

    # Cap inbox at 50 lines (FIFO) so it doesn't grow unbounded.
    LINES="$(wc -l <"$CEO_INBOX" 2>/dev/null | tr -d ' ' || echo 0)"
    if [ "$LINES" -gt 50 ]; then
      TMP_INB="$(mktemp -t ceo-inbox.XXXXXX 2>/dev/null || echo "${CEO_INBOX}.tmp")"
      tail -n 50 "$CEO_INBOX" >"$TMP_INB" 2>/dev/null
      mv "$TMP_INB" "$CEO_INBOX" 2>/dev/null || true
    fi
  fi
fi

exit 0
