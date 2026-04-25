#!/usr/bin/env bash
# Stop hook — appends one NDJSON line to the activity feed (file spillover v1).
# M1: write to ./dev-activity-feed.ndjson at the repo root (local test
# location — /paperclip isn't ours to touch). M3 migrates to PG.

set -euo pipefail

# shellcheck source=../../_common/hooks/lib.sh
. "$(cd "$(dirname "$0")/../../_common/hooks" && pwd)/lib.sh"

PERSONA="$(cc_persona_slug "$0")"
PERSONA_DIR="$(cc_persona_dir "$0")"
cc_hook_enter "Stop"
cc_log_init "$PERSONA"

CC_STDIN_PAYLOAD="$(cc_read_stdin || true)"
: "${CC_STDIN_PAYLOAD:=}"

REPO_ROOT="$(cd "${PERSONA_DIR}/../.." && pwd)"
FEED_PATH="${CC_ACTIVITY_FEED_PATH:-${REPO_ROOT}/dev-activity-feed.ndjson}"
mkdir -p "$(dirname "$FEED_PATH")"

TS="$(date -u +%FT%TZ)"

# Best-effort derive (verb, object) from stdin; defaults are safe.
VERB="replied"
OBJECT="operator-dm"
ISSUE_REF="null"

if [ -n "$CC_STDIN_PAYLOAD" ] && command -v jq >/dev/null 2>&1; then
  # Try to infer: last tool, last assistant message summary, issue ref.
  DERIVED_VERB="$(printf '%s' "$CC_STDIN_PAYLOAD" | jq -r '.lastToolName // .last_tool // ""' 2>/dev/null || echo "")"
  case "$DERIVED_VERB" in
    *sendMessage*|*telegram*) VERB="replied"; OBJECT="operator-dm" ;;
    *create_card*|*commentCard*|*trello*) VERB="commented"; OBJECT="trello-card" ;;
    *paperclip*comment*) VERB="commented"; OBJECT="paperclip-issue" ;;
    "") : ;;
    *) VERB="used-tool"; OBJECT="$DERIVED_VERB" ;;
  esac

  DERIVED_ISSUE="$(printf '%s' "$CC_STDIN_PAYLOAD" | jq -r '.issueRef // .issue_ref // ""' 2>/dev/null || echo "")"
  if [ -n "$DERIVED_ISSUE" ] && [ "$DERIVED_ISSUE" != "null" ]; then
    ISSUE_REF="\"$DERIVED_ISSUE\""
  fi
fi

# Compose NDJSON line. Keep keys stable — M3 PG migration depends on this shape.
LINE=$(printf '{"ts":"%s","persona":"%s","verb":"%s","object":"%s","issue-ref":%s}' \
  "$TS" "$PERSONA" "$VERB" "$OBJECT" "$ISSUE_REF")

printf '%s\n' "$LINE" >>"$FEED_PATH"

cc_log "$PERSONA" "Stop appended to $FEED_PATH"

# M4 A1+A4: cross-persona Stop sync + UX→CEO design-thread sync.
PERSONA="$PERSONA" VERB="$VERB" OBJECT="$OBJECT" CC_STDIN_PAYLOAD="$CC_STDIN_PAYLOAD" \
  bash "$(cd "$(dirname "$0")/../../_common/hooks" && pwd)/m4-stop-tail.sh" \
  >>"${CC_LOG_FILE:-/tmp/hooks-${PERSONA}.log}" 2>&1 || true

cc_hook_exit
