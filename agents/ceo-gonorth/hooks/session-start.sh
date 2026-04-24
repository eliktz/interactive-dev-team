#!/usr/bin/env bash
# SessionStart hook — hydrates persona memory, feedback files, product-spine,
# and L4 team_memory top-N into the fresh session context.
# M1 scope: L4 team_memory is a placeholder (wired in M3).

set -euo pipefail

# shellcheck source=../../_common/hooks/lib.sh
. "$(cd "$(dirname "$0")/../../_common/hooks" && pwd)/lib.sh"

PERSONA="$(cc_persona_slug "$0")"
PERSONA_DIR="$(cc_persona_dir "$0")"
cc_hook_enter "SessionStart"
cc_log_init "$PERSONA"
cc_log "$PERSONA" "SessionStart fire"

# Consume stdin (harness payload — unused in M1 but required for recursion).
CC_STDIN_PAYLOAD="$(cc_read_stdin || true)"
: "${CC_STDIN_PAYLOAD:=}"

CTX_FILE="$(mktemp -t "cc-session-start-${PERSONA}.XXXXXX")"
trap 'rm -f "$CTX_FILE"' EXIT

MEM_DIR="${PERSONA_DIR}/memory"
SPINE_PATH="${CC_PRODUCT_SPINE_PATH:-${PERSONA_DIR}/../../companies/go-north/PRODUCT-SPINE.md}"

{
  echo "# SESSION-START CONTEXT — ${PERSONA}"
  echo "_(auto-injected by hook; do not ignore)_"
  echo

  echo "## Memory TOC"
  if [ -f "${MEM_DIR}/MEMORY.md" ]; then
    cat "${MEM_DIR}/MEMORY.md"
  else
    echo "_(no MEMORY.md yet — M1 placeholder; SessionEnd rebuilds on exit)_"
  fi
  echo

  echo "## Operator feedback (persistent)"
  if ls "${MEM_DIR}"/feedback_*.md >/dev/null 2>&1; then
    for f in "${MEM_DIR}"/feedback_*.md; do
      echo "### $(basename "$f")"
      # Cap each feedback file at ~4 KB to keep share ≤ 20% of window.
      head -c 4096 "$f"
      echo
      echo
    done
  else
    echo "_(no feedback files yet)_"
  fi
  echo

  echo "## Product spine"
  if [ -f "${SPINE_PATH}" ]; then
    # Inject the last 80 lines — mission/themes/current-state re-grounding.
    tail -n 80 "${SPINE_PATH}"
  else
    echo "_(PRODUCT-SPINE.md missing at ${SPINE_PATH} — CEO must create before first operator message)_"
  fi
  echo

  echo "## Team memory (L4) — last 10 entries filtered by persona+company"
  echo "(team_memory not yet wired; M3 adds it)"
  echo

  echo "## MANDATES (from IDENTITY.md)"
  echo "- Re-read this context before answering the operator."
  echo "- Sign every outbound operator-facing message with the persona prefix."
  echo "- Never leak commit SHAs, PR hashes, file paths, or HTTP verbs/status into operator-facing surfaces."
} >"$CTX_FILE"

cc_emit_context "SessionStart" "$CTX_FILE"
cc_log "$PERSONA" "SessionStart emitted $(wc -c <"$CTX_FILE") bytes of context"
cc_hook_exit
