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
IDENTITY_PATH="${PERSONA_DIR}/IDENTITY.md"

# Pull the "when_to_speak" rule from IDENTITY.md frontmatter so it sits at the
# very top of context — attention concentrates at the head, and the rule must
# be in scope BEFORE any incoming message is processed (Iris self-diagnosis,
# m1-rules-pin).
WHEN_TO_SPEAK="$(cc_identity_field "$IDENTITY_PATH" "when_to_speak")"
PERSONA_PREFIX="$(cc_identity_field "$IDENTITY_PATH" "signed_chrome_prefix")"

{
  echo "## When to speak"
  if [ -n "$WHEN_TO_SPEAK" ]; then
    echo "$WHEN_TO_SPEAK"
  else
    echo "_(no when_to_speak rule defined in IDENTITY.md — falling back to AGENTS.md)_"
  fi
  echo

  echo "## Persona"
  if [ -n "$PERSONA_PREFIX" ]; then
    echo "${PERSONA_PREFIX} (${PERSONA})"
  else
    echo "${PERSONA}"
  fi
  echo

  echo "## Memory snapshot"
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

  # M4 A4: cross-persona Stop sync — show recent team-wide activity.
  echo "## Team recent activity (last 20 lines from /workspace/team-recent.md)"
  if [ -f "/workspace/team-recent.md" ]; then
    tail -n 20 "/workspace/team-recent.md"
  else
    echo "_(no team-recent.md yet — populated as personas hit Stop)_"
  fi
  echo

  # M4 A1: UX→CEO design-thread inbox (CEO-only). Iris writes here when she
  # posts to a #design-tagged thread; CEO sees on next SessionStart.
  if [ "$PERSONA" = "ceo-gonorth" ] && [ -f "/workspace/agents/ceo-gonorth/memory/inbox-from-ux.md" ]; then
    echo "## Inbox from UX (Iris) — design-thread proposals"
    tail -n 20 "/workspace/agents/ceo-gonorth/memory/inbox-from-ux.md"
    echo
  fi

  # M4 A6: /compact draft continuation — detect compact-recovery files and
  # surface them so the agent can resume the in-flight draft.
  if ls "${MEM_DIR}"/compact-recovery-*.md >/dev/null 2>&1 ; then
    echo "## Draft recovery (from previous /compact)"
    LATEST_RECOVERY="$(ls -t "${MEM_DIR}"/compact-recovery-*.md 2>/dev/null | head -1)"
    if [ -n "$LATEST_RECOVERY" ]; then
      echo "Found in-flight draft from previous compact at: $LATEST_RECOVERY"
      echo "First 60 lines:"
      head -n 60 "$LATEST_RECOVERY"
      echo
      echo "_(if you want to resume this draft, read the full file; otherwise delete to dismiss.)_"
    fi
    echo
  fi

  echo "## MANDATES (from IDENTITY.md)"
  echo "- Re-read this context before answering the operator."
  echo "- Sign every outbound operator-facing message with the persona prefix."
  echo "- Never leak commit SHAs, PR hashes, file paths, or HTTP verbs/status into operator-facing surfaces."
} >"$CTX_FILE"

cc_emit_context "SessionStart" "$CTX_FILE"
cc_log "$PERSONA" "SessionStart emitted $(wc -c <"$CTX_FILE") bytes of context"
cc_hook_exit
