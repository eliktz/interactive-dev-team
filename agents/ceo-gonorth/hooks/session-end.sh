#!/usr/bin/env bash
# SessionEnd hook — rsync container memory into the git-tracked persona dir,
# commit under flock, and (in M3+) POST to paperclip team-memory flush endpoint.
# M1: flush endpoint is pending, so we just log.

set -euo pipefail

# shellcheck source=../../_common/hooks/lib.sh
. "$(cd "$(dirname "$0")/../../_common/hooks" && pwd)/lib.sh"

PERSONA="$(cc_persona_slug "$0")"
PERSONA_DIR="$(cc_persona_dir "$0")"
cc_hook_enter "SessionEnd"
cc_log_init "$PERSONA"
cc_log "$PERSONA" "SessionEnd fire"

# Consume stdin (often empty on SessionEnd).
CC_STDIN_PAYLOAD="$(cc_read_stdin || true)"
: "${CC_STDIN_PAYLOAD:=}"

CONTAINER_MEM_DIR="${CC_CONTAINER_MEMORY_DIR:-/home/claude/.claude/projects/-workspace-agents-${PERSONA}/memory}"
REPO_MEM_DIR="${PERSONA_DIR}/memory"
REPO_ROOT="$(cd "${PERSONA_DIR}/../.." && pwd)"
LOCK_FILE="${REPO_ROOT}/.git/index.lock"

mkdir -p "$REPO_MEM_DIR"

# 1. rsync container memory → repo memory (best-effort; skip if source absent)
if [ -d "$CONTAINER_MEM_DIR" ]; then
  if command -v rsync >/dev/null 2>&1; then
    rsync -a --delete "${CONTAINER_MEM_DIR}/" "${REPO_MEM_DIR}/" \
      >>"$CC_LOG_FILE" 2>&1 || cc_log "$PERSONA" "rsync warning (non-fatal)"
  else
    cc_log "$PERSONA" "rsync missing — using cp -R fallback"
    cp -R "${CONTAINER_MEM_DIR}/." "${REPO_MEM_DIR}/" 2>>"$CC_LOG_FILE" || true
  fi
else
  cc_log "$PERSONA" "container memory dir absent ($CONTAINER_MEM_DIR) — skipping sync"
fi

# 2. git add + commit under flock. Non-fatal if nothing changed.
TS="$(date -u +%FT%TZ)"
COMMIT_MSG="[${PERSONA}] session end ${TS}"

if [ -d "${REPO_ROOT}/.git" ]; then
  (
    # Serialise commits across concurrent persona SessionEnd hooks.
    if command -v flock >/dev/null 2>&1; then
      exec 9>"$LOCK_FILE"
      flock -w 10 9 || { cc_log "$PERSONA" "flock timeout — skipping commit"; exit 0; }
    fi
    cd "$REPO_ROOT"
    git add "agents/${PERSONA}/memory" 2>>"$CC_LOG_FILE" || true
    if ! git diff --cached --quiet 2>/dev/null; then
      git commit --no-verify -m "$COMMIT_MSG" >>"$CC_LOG_FILE" 2>&1 \
        || cc_log "$PERSONA" "git commit failed (non-fatal)"
    else
      cc_log "$PERSONA" "no memory changes to commit"
    fi
  ) || cc_log "$PERSONA" "commit subshell returned non-zero (non-fatal)"
else
  cc_log "$PERSONA" "no .git at $REPO_ROOT — skipping commit"
fi

# 3. POST to paperclip team-memory flush — M3 only.
cc_log "$PERSONA" "(flush endpoint pending M3)"

cc_hook_exit
