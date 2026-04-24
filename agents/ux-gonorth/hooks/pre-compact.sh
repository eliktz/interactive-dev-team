#!/usr/bin/env bash
# PreCompact hook — model-directed prompt instructing the agent to serialize
# in-flight decisions before harness compaction summarises them away.

set -euo pipefail

# shellcheck source=../../_common/hooks/lib.sh
. "$(cd "$(dirname "$0")/../../_common/hooks" && pwd)/lib.sh"

PERSONA="$(cc_persona_slug "$0")"
cc_hook_enter "PreCompact"
cc_log_init "$PERSONA"
cc_log "$PERSONA" "PreCompact fire"

# Consume stdin — harness provides `trigger` / `reason` we could log.
CC_STDIN_PAYLOAD="$(cc_read_stdin || true)"
: "${CC_STDIN_PAYLOAD:=}"

TRIGGER="unknown"
if [ -n "$CC_STDIN_PAYLOAD" ] && command -v jq >/dev/null 2>&1; then
  TRIGGER="$(printf '%s' "$CC_STDIN_PAYLOAD" | jq -r '.trigger // .reason // "unknown"' 2>/dev/null || echo "unknown")"
fi

cc_log "$PERSONA" "PreCompact trigger=$TRIGGER"

MESSAGE="Before compaction: write decisions to memory/compact_<uuid>.md; if team-worthy, call team_memory.write with importance>=3; update PRODUCT-SPINE.md current-state if drifted. (trigger=${TRIGGER})"

printf '{"hookSpecificOutput":{"hookEventName":"PreCompact","additionalContext":%s}}\n' \
  "$(printf '%s' "$MESSAGE" | cc_jsonesc)"

cc_hook_exit
