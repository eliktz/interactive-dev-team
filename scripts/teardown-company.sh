#!/usr/bin/env bash
# teardown-company.sh — M5.
# Archive a company namespace: snapshot to _backups/, remove on-disk files,
# soft-archive paperclip rows, soft-archive team_memory rows.
#
# Usage:
#   scripts/teardown-company.sh <slug> [--keep-backups] [--no-paperclip]
#                                       [--no-team-memory]
#
# This is contained-destructive on host repo and on paperclip DB rows for the
# specified slug. Does NOT touch other companies.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

SLUG=""
KEEP_BACKUPS=1
NO_PAPERCLIP=0
NO_TEAM_MEMORY=0

usage() {
  sed -n '2,12p' "$0" >&2
  exit "${1:-2}"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --keep-backups) KEEP_BACKUPS=1; shift ;;
    --no-paperclip) NO_PAPERCLIP=1; shift ;;
    --no-team-memory) NO_TEAM_MEMORY=1; shift ;;
    -h|--help) usage 0 ;;
    -*) echo "unknown flag: $1" >&2; usage 2 ;;
    *) if [ -z "$SLUG" ]; then SLUG="$1"; shift; else echo "unexpected arg: $1" >&2; usage 2; fi ;;
  esac
done

[ -n "$SLUG" ] || { echo "missing <slug>" >&2; usage 2; }
[[ "$SLUG" =~ ^[a-z][a-z0-9-]*$ ]] || { echo "slug invalid (got: $SLUG)" >&2; exit 2; }
case "$SLUG" in
  go-north|_template) echo "refusing to teardown protected slug: $SLUG" >&2; exit 5 ;;
esac

COMPANY_DIR="${REPO_ROOT}/companies/${SLUG}"
TS="$(date -u +%Y%m%dT%H%M%SZ)"
BACKUP_DIR="${REPO_ROOT}/_backups"
TARBALL="${BACKUP_DIR}/teardown-${SLUG}-${TS}.tar.gz"

mkdir -p "$BACKUP_DIR"

# Collect targets: company dir + per-persona agent dirs.
TARGETS=()
[ -d "$COMPANY_DIR" ] && TARGETS+=("companies/${SLUG}")
for d in "${REPO_ROOT}/agents/${SLUG}-"*; do
  if [ -d "$d" ]; then
    TARGETS+=("agents/$(basename "$d")")
  fi
done

if [ ${#TARGETS[@]} -eq 0 ]; then
  echo "[teardown-company] nothing to remove for slug=${SLUG}" >&2
  exit 0
fi

# Snapshot.
( cd "$REPO_ROOT" && tar czf "$TARBALL" "${TARGETS[@]}" 2>/dev/null )
echo "[teardown-company] snapshot: $TARBALL ($(stat -c%s "$TARBALL" 2>/dev/null || stat -f%z "$TARBALL" 2>/dev/null || echo "?") bytes)"

# Read paperclip company id from company.yml (best-effort).
PAPERCLIP_COMPANY_ID=""
if [ -f "${COMPANY_DIR}/company.yml" ]; then
  PAPERCLIP_COMPANY_ID="$(grep -E '^paperclip_company_id:' "${COMPANY_DIR}/company.yml" | head -1 | sed -E 's/^paperclip_company_id:[[:space:]]*"?([^"]*)"?.*$/\1/')"
fi

# Remove on-disk targets.
for t in "${TARGETS[@]}"; do
  rm -rf "${REPO_ROOT}/${t}"
  echo "[teardown-company] removed ${t}"
done

# Soft-archive paperclip rows (best-effort).
PAPERCLIP_RESULT="skipped"
if [ "$NO_PAPERCLIP" != "1" ] && [ -n "$PAPERCLIP_COMPANY_ID" ] && command -v psql >/dev/null 2>&1; then
  PG_URL="${PAPERCLIP_PG_URL:-postgresql://paperclip:paperclip@127.0.0.1:54329/paperclip}"
  if psql "$PG_URL" -c "SELECT 1 FROM information_schema.columns WHERE table_name='companies' AND column_name='status'" -tA 2>/dev/null | grep -q 1 ; then
    if psql "$PG_URL" -c "UPDATE companies SET status = 'archived' WHERE id = '${PAPERCLIP_COMPANY_ID}' AND status != 'archived'" 2>/dev/null ; then
      PAPERCLIP_RESULT="status=archived for ${PAPERCLIP_COMPANY_ID}"
    fi
  elif psql "$PG_URL" -c "SELECT 1 FROM information_schema.columns WHERE table_name='companies' AND column_name='archived_at'" -tA 2>/dev/null | grep -q 1 ; then
    psql "$PG_URL" -c "UPDATE companies SET archived_at = now() WHERE id = '${PAPERCLIP_COMPANY_ID}' AND archived_at IS NULL" 2>/dev/null && \
      PAPERCLIP_RESULT="archived ${PAPERCLIP_COMPANY_ID}"
  else
    PAPERCLIP_RESULT="paperclip 'companies' table missing status/archived_at"
  fi
fi

# Soft-archive team_memory rows (best-effort).
TEAM_MEMORY_RESULT="skipped"
if [ "$NO_TEAM_MEMORY" != "1" ] && [ -n "$PAPERCLIP_COMPANY_ID" ] && command -v psql >/dev/null 2>&1; then
  PG_URL="${PAPERCLIP_PG_URL:-postgresql://paperclip:paperclip@127.0.0.1:54329/paperclip}"
  if psql "$PG_URL" -c "SELECT 1 FROM information_schema.columns WHERE table_name='team_memory' AND column_name='archived_at'" -tA 2>/dev/null | grep -q 1 ; then
    UPDATED="$(psql "$PG_URL" -c "UPDATE team_memory SET archived_at = now() WHERE company_id = '${PAPERCLIP_COMPANY_ID}' AND archived_at IS NULL" -tA 2>/dev/null | tail -1)"
    TEAM_MEMORY_RESULT="archived (count=${UPDATED:-?})"
  fi
fi

cat <<EOF
[teardown-company] DONE — slug=${SLUG}
  removed: ${#TARGETS[@]} dirs (${TARGETS[*]})
  backup:  ${TARBALL}
  paperclip: ${PAPERCLIP_RESULT}
  team_memory: ${TEAM_MEMORY_RESULT}
EOF
