#!/usr/bin/env bash
# UserPromptSubmit hook — when the operator prompt looks like a memory recall
# question ("what do we know about X", "remember", "last time", "previously"),
# grep the persona's memory dir for token overlap and inject top-5 hits.

set -euo pipefail

# shellcheck source=../../_common/hooks/lib.sh
. "$(cd "$(dirname "$0")/../../_common/hooks" && pwd)/lib.sh"

PERSONA="$(cc_persona_slug "$0")"
PERSONA_DIR="$(cc_persona_dir "$0")"
cc_hook_enter "UserPromptSubmit"
cc_log_init "$PERSONA"

CC_STDIN_PAYLOAD="$(cc_read_stdin || true)"
if [ -z "$CC_STDIN_PAYLOAD" ]; then
  echo '{}'
  exit 0
fi

PROMPT=""
if command -v jq >/dev/null 2>&1; then
  PROMPT="$(printf '%s' "$CC_STDIN_PAYLOAD" | jq -r '.user_prompt // .prompt // ""' 2>/dev/null || echo "")"
fi

if [ -z "$PROMPT" ]; then
  echo '{}'
  exit 0
fi

# Regex match — case-insensitive, word-boundary-ish.
if ! printf '%s' "$PROMPT" | grep -qiE '(^|[^[:alnum:]])(what do we know|remember|recall|last time|previously)' ; then
  echo '{}'
  exit 0
fi

cc_log "$PERSONA" "UserPromptSubmit recall-trigger matched"

MEM_DIR="${PERSONA_DIR}/memory"
if [ ! -d "$MEM_DIR" ]; then
  echo '{}'
  exit 0
fi

# Cheap tokenizer: words >=4 chars, lowercased, unique, top 20.
TOKENS="$(printf '%s' "$PROMPT" \
  | tr '[:upper:]' '[:lower:]' \
  | tr -cs 'a-z0-9\n' '\n' \
  | awk 'length >= 4' \
  | sort -u \
  | head -n 20)"

if [ -z "$TOKENS" ]; then
  echo '{}'
  exit 0
fi

# Collect files with any token match, dedupe, cap at 5.
HITS_FILE="$(mktemp -t "cc-mem-hits.XXXXXX")"
trap 'rm -f "$HITS_FILE"' EXIT

while IFS= read -r tok; do
  [ -n "$tok" ] || continue
  grep -lri --include='*.md' -F -- "$tok" "$MEM_DIR" 2>/dev/null || true
done <<<"$TOKENS" | sort -u | head -n 5 >"$HITS_FILE"

if [ ! -s "$HITS_FILE" ]; then
  echo '{}'
  exit 0
fi

ENRICH="$(mktemp -t "cc-mem-enrich.XXXXXX")"
trap 'rm -f "$HITS_FILE" "$ENRICH"' EXIT

{
  echo "## Relevant memory for this prompt (auto-injected)"
  echo "_Read before answering. Cite file + first line if used._"
  echo
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    echo "### $(basename "$f")"
    head -n 30 "$f"
    echo
  done <"$HITS_FILE"
} >"$ENRICH"

cc_emit_context "UserPromptSubmit" "$ENRICH"
cc_log "$PERSONA" "UserPromptSubmit injected $(wc -l <"$HITS_FILE") memory files"
cc_hook_exit
