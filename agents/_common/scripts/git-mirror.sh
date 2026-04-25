#!/usr/bin/env bash
# git-mirror.sh — M2 SessionEnd memory mirror.
#
# Called by per-persona session-end.sh. Rsyncs the live container memory
# directory into the host repo's persona memory dir, then commits.
#
# Source (container path inside the war-room container):
#   /workspace/agents/<persona>/memory/
# Destination (host repo via bind-mount):
#   /Users/elik.k/git/interactive-dev-team/agents/<persona>/memory/
#
# When run inside the host repo (M2 build / dry-run), $CONTAINER_MEM_DIR is
# overridable via env so the same script can be exercised locally.
#
# Behaviour:
#   - flock /workspace/.git/index.lock  (fall back to repo-root .git/index.lock)
#   - rsync -a --delete  (best-effort; on missing source → no-op)
#   - git add agents/<persona>/memory && git commit (unsigned, no push)
#   - Idempotent: skip commit if no changes
#   - Backwards-compat: if memory dir doesn't exist anywhere, exit 0 (silent)

set -euo pipefail

# ------------------------------------------------------------ helpers ------
_gm_log() {
  local persona="$1"; shift
  local lvl="$1"; shift
  local target="${GIT_MIRROR_LOG:-/tmp/git-mirror-${persona}.log}"
  local ts; ts="$(date -u +%FT%TZ)"
  printf '[%s] [%s] [%s] %s\n' "$ts" "$persona" "$lvl" "$*" \
    >>"$target" 2>/dev/null || true
}

# ------------------------------------------------------------ main ---------
PERSONA="${1:-${PERSONA:-${CC_PERSONA:-}}}"
if [ -z "$PERSONA" ] ; then
  # Try to derive from the calling hook's $0 if invoked from a hook.
  if [ -n "${BASH_SOURCE[1]:-}" ] ; then
    PERSONA="$(basename "$(dirname "$(dirname "${BASH_SOURCE[1]}")")")"
  fi
fi
PERSONA="${PERSONA:-unknown}"

# Container source: live memory dir.
CONTAINER_MEM_DIR="${CONTAINER_MEM_DIR:-/workspace/agents/${PERSONA}/memory}"

# Repo root: derive from this script's location, OR honour explicit env.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEFAULT_REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
REPO_ROOT="${GIT_MIRROR_REPO_ROOT:-$DEFAULT_REPO_ROOT}"
REPO_MEM_DIR="${REPO_ROOT}/agents/${PERSONA}/memory"

_gm_log "$PERSONA" info "git-mirror start (container=$CONTAINER_MEM_DIR, repo=$REPO_MEM_DIR)"

# 1. Source must exist.
if [ ! -d "$CONTAINER_MEM_DIR" ] ; then
  _gm_log "$PERSONA" info "container memory dir absent — no-op"
  exit 0
fi

# Ensure destination exists.
mkdir -p "$REPO_MEM_DIR"

# 2. flock the git index.
LOCK_FILE="${REPO_ROOT}/.git/index.lock"
if [ ! -d "${REPO_ROOT}/.git" ] ; then
  _gm_log "$PERSONA" warn "no .git at $REPO_ROOT — rsync only, skipping commit"
  if command -v rsync >/dev/null 2>&1 ; then
    rsync -a --delete "${CONTAINER_MEM_DIR}/" "${REPO_MEM_DIR}/" \
      2>>"${GIT_MIRROR_LOG:-/tmp/git-mirror-${PERSONA}.log}" || true
  else
    cp -R "${CONTAINER_MEM_DIR}/." "${REPO_MEM_DIR}/" 2>/dev/null || true
  fi
  exit 0
fi

# Use flock if available; otherwise advisory-only.
{
  if command -v flock >/dev/null 2>&1 ; then
    exec 9>"$LOCK_FILE"
    if ! flock -w 10 9 ; then
      _gm_log "$PERSONA" warn "flock timeout — skipping commit"
      exit 0
    fi
  fi

  # 3. rsync.
  if command -v rsync >/dev/null 2>&1 ; then
    rsync -a --delete "${CONTAINER_MEM_DIR}/" "${REPO_MEM_DIR}/" \
      2>>"${GIT_MIRROR_LOG:-/tmp/git-mirror-${PERSONA}.log}" \
      || _gm_log "$PERSONA" warn "rsync warning (non-fatal)"
  else
    _gm_log "$PERSONA" warn "rsync missing — using cp -R fallback"
    cp -R "${CONTAINER_MEM_DIR}/." "${REPO_MEM_DIR}/" 2>/dev/null || true
  fi

  # 4. git add + commit. Idempotent.
  cd "$REPO_ROOT"
  git add "agents/${PERSONA}/memory" 2>/dev/null || true
  if git diff --cached --quiet 2>/dev/null ; then
    _gm_log "$PERSONA" info "no memory changes — skipping commit"
    exit 0
  fi

  TS="$(date -u +%FT%TZ)"
  COMMIT_MSG="[${PERSONA}] session-end ${TS}"
  if git commit --no-verify --no-gpg-sign -m "$COMMIT_MSG" >/dev/null 2>&1 ; then
    _gm_log "$PERSONA" info "committed $COMMIT_MSG"
  else
    _gm_log "$PERSONA" warn "git commit failed (non-fatal)"
  fi

  # NB: no push. Per spec.
} || _gm_log "$PERSONA" warn "git-mirror subshell returned non-zero (non-fatal)"

exit 0
