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

# M4 A6: write a compact-recovery placeholder file so SessionStart after
# compact can detect it and offer to resume the in-flight draft. The model
# is asked (via additionalContext below) to fill this file with the current
# turn's working draft before the harness summarizes the transcript away.
PERSONA_DIR="$(cc_persona_dir "$0")"
MEM_DIR="${PERSONA_DIR}/memory"
mkdir -p "$MEM_DIR" 2>/dev/null || true
TS="$(date -u +%Y%m%dT%H%M%SZ)"
RECOVERY_PATH="${MEM_DIR}/compact-recovery-${TS}.md"
{
  echo "# Compact recovery draft — ${TS}"
  echo
  echo "_Created by PreCompact hook (trigger=${TRIGGER}). The agent should append_"
  echo "_the current turn's working draft below this line BEFORE the harness_"
  echo "_compacts. SessionStart after compact will surface this file._"
  echo
  echo "## Working draft (fill in)"
  echo
} >"$RECOVERY_PATH" 2>/dev/null || true
cc_log "$PERSONA" "PreCompact recovery file: $RECOVERY_PATH"

MESSAGE="Before compaction: (1) write decisions to memory/compact_<uuid>.md; (2) if team-worthy, call team_memory.write with importance>=3; (3) update PRODUCT-SPINE.md current-state if drifted; (4) [M4 A6] APPEND your current in-flight draft to ${RECOVERY_PATH} so the next session can resume it. (trigger=${TRIGGER})"

printf '{"hookSpecificOutput":{"hookEventName":"PreCompact","additionalContext":%s}}\n' \
  "$(printf '%s' "$MESSAGE" | cc_jsonesc)"

cc_hook_exit
