#!/usr/bin/env bash
# SessionEnd hook — delegates the memory-mirror + commit to the shared
# git-mirror.sh (M2 build). Keeps a thin wrapper here so per-persona env
# overrides remain expressible.
#
# In M3+, this hook will additionally POST to the paperclip team-memory
# flush endpoint.

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

# Container source: the live persona memory dir. Honour the legacy override
# so existing operators with custom layouts keep working.
export CONTAINER_MEM_DIR="${CC_CONTAINER_MEMORY_DIR:-/workspace/agents/${PERSONA}/memory}"

# Repo root: derive from the hook path. The shared script also derives this
# from its own path; we set it here for clarity.
REPO_ROOT="$(cd "${PERSONA_DIR}/../.." && pwd)"
export GIT_MIRROR_REPO_ROOT="$REPO_ROOT"
export GIT_MIRROR_LOG="${CC_LOG_FILE:-/tmp/hooks-${PERSONA}.log}"

GIT_MIRROR_SH="${REPO_ROOT}/agents/_common/scripts/git-mirror.sh"

if [ -x "$GIT_MIRROR_SH" ] ; then
  cc_log "$PERSONA" "session-end: invoking git-mirror.sh"
  "$GIT_MIRROR_SH" "$PERSONA" \
    >>"$CC_LOG_FILE" 2>&1 \
    || cc_log "$PERSONA" "git-mirror returned non-zero (non-fatal)"
else
  cc_log "$PERSONA" "git-mirror.sh missing at $GIT_MIRROR_SH — backwards-compat no-op"
fi

# 3. POST to paperclip team-memory flush — M3 only.
cc_log "$PERSONA" "(flush endpoint pending M3)"

cc_hook_exit
