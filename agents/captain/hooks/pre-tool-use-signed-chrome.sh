#!/usr/bin/env bash
# PreToolUse hook (signed-chrome prepend) — when the agent calls a Telegram /
# Paperclip / Trello send tool, read the persona's IDENTITY.md at hook time
# (not hardcoded) and, if the outgoing text doesn't already start with the
# persona prefix, prepend it via the CC "modify" decision.

set -euo pipefail

# shellcheck source=../../_common/hooks/lib.sh
. "$(cd "$(dirname "$0")/../../_common/hooks" && pwd)/lib.sh"

PERSONA="$(cc_persona_slug "$0")"
PERSONA_DIR="$(cc_persona_dir "$0")"
cc_hook_enter "PreToolUse"
cc_log_init "$PERSONA"

CC_STDIN_PAYLOAD="$(cc_read_stdin || true)"
if [ -z "$CC_STDIN_PAYLOAD" ]; then
  # Unknown payload — do nothing (don't block).
  echo '{}'
  exit 0
fi

if ! command -v jq >/dev/null 2>&1; then
  cc_log "$PERSONA" "pre-tool-use: jq missing — passing through"
  echo '{}'
  exit 0
fi

TOOL_NAME="$(printf '%s' "$CC_STDIN_PAYLOAD" | jq -r '.tool_name // .tool // ""')"

# Only intercept known human-reaching tools.
case "$TOOL_NAME" in
  *telegram*sendMessage*|*telegram__*|*trello__*|*paperclip*comment*|*paperclip-comment*|mcp__telegram__*|mcp__trello__*)
    : # intercept
    ;;
  *)
    echo '{}'
    exit 0
    ;;
esac

# Load prefix from IDENTITY.md at hook time.
IDENTITY_PATH="${PERSONA_DIR}/IDENTITY.md"
PREFIX="$(cc_identity_field "$IDENTITY_PATH" "signed_chrome_prefix")"
if [ -z "$PREFIX" ]; then
  cc_log "$PERSONA" "pre-tool-use: no signed_chrome_prefix in $IDENTITY_PATH — passing through"
  echo '{}'
  exit 0
fi

# Extract the message text from common tool-input field names.
MSG="$(printf '%s' "$CC_STDIN_PAYLOAD" \
  | jq -r '.tool_input.text // .tool_input.message // .tool_input.body // .tool_input.comment // .tool_input.desc // ""')"

if [ -z "$MSG" ]; then
  echo '{}'
  exit 0
fi

# If already starts with the prefix (trimmed leading whitespace), pass through.
TRIMMED="$(printf '%s' "$MSG" | sed -e 's/^[[:space:]]*//')"
case "$TRIMMED" in
  "$PREFIX"*) echo '{}'; exit 0 ;;
esac

# Prepend.
NEW_MSG="$PREFIX $MSG"
cc_log "$PERSONA" "pre-tool-use: prepended signed chrome for tool=$TOOL_NAME"

# Emit a "modify" decision. If the harness version doesn't understand
# `modify`, this falls through as informational; the harness will log and send
# the original. M2 Phase-2 upgrades the wiring for true in-flight rewrite.
NEW_TEXT_JSON="$(printf '%s' "$NEW_MSG" | cc_jsonesc)"
printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","decision":"modify","modifiedInput":{"text":%s}}}\n' "$NEW_TEXT_JSON"

cc_hook_exit
