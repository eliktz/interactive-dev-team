#!/usr/bin/env bash
# =============================================================================
# admin-registry.sh — RUNTIME cross-squad fleet registry (run INSIDE the admin)
#
# Prints a concise "who's who" of every squad on this VM from LIVE state — it is
# NOT a committed list. Live tenant data (slugs, ports, company names, health)
# belongs only on the VM under /srv; this public repo never stores it. See
# deploy/templates/admin-seed/admin/registry.md for the rationale.
#
# Sources (read-only):
#   - /srv/squads/<slug>/.env             -> slug + SQUAD_PORT_BASE/DASH/PAPERCLIP/PLAYWRIGHT ports
#   - /srv/squads/<slug>/companies/*/COMPANY.md  -> company name (YAML front-matter `name:`)
#   - /srv/platform-admin/.env (+ this very host) -> the admin's own row
#   - `squadctl status <slug>` / `squadctl doctor` (cheap) -> running-container count / health hint
#
# Output: slug, dash/pc/pw ports, dashboard URL, company name(s), health hint.
# NEVER prints a secret VALUE — reads only port and slug/name keys.
#
# Usage:
#   deploy/admin/bin/admin-registry.sh            # full fleet table
#   SQUADCTL_SQUADS_ROOT=/tmp/squads deploy/admin/bin/admin-registry.sh   # override root
# =============================================================================
set -euo pipefail

SQUADS_ROOT="${SQUADCTL_SQUADS_ROOT:-/srv/squads}"
ADMIN_HOME="${ADMIN_HOME:-/srv/platform-admin}"
ADMIN_DASH_PORT="${SQUAD_DASH_PORT:-7900}"

# env_get FILE KEY -> value (empty when absent). Mirrors squadctl's helper.
env_get() {
  { grep -E "^$2=" "$1" 2>/dev/null || true; } | tail -1 | cut -d= -f2-
}

# company_names HOME -> comma-joined `name:` values from every companies/*/COMPANY.md,
# read from the YAML front-matter. Falls back to the dir name, then "?".
company_names() {
  local home="$1" md name dir out=""
  for md in "$home"/companies/*/COMPANY.md; do
    [ -f "$md" ] || continue
    # First `name:` line in the front-matter; strip quotes/whitespace. NO secrets here.
    name=$(grep -m1 -E '^name:' "$md" 2>/dev/null | cut -d: -f2- | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/^"//' -e 's/"$//')
    if [ -z "$name" ]; then
      dir=$(basename "$(dirname "$md")")
      name="$dir"
    fi
    out="${out:+$out, }$name"
  done
  printf '%s' "${out:-?}"
}

# running_count NAME_PREFIX -> number of running containers whose name starts with the prefix.
running_count() {
  command -v docker >/dev/null 2>&1 || { printf '%s' "?"; return; }
  docker ps --filter "name=^$1" --format '{{.Names}}' 2>/dev/null | grep -c . || true
}

print_row() { # print_row SLUG DASH PC PW URL COMPANY HEALTH
  printf '%-14s %-6s %-6s %-6s %-30s %-28s %s\n' "$1" "$2" "$3" "$4" "$5" "$6" "$7"
}

echo "=== Platform fleet registry (live; not committed) ==="
echo "squads root: $SQUADS_ROOT"
echo
print_row "SLUG" "DASH" "PC" "PW" "URL" "COMPANY" "HEALTH"
print_row "----" "----" "--" "--" "---" "-------" "------"

# --- the admin's own row -----------------------------------------------------
if [ -f "$ADMIN_HOME/.env" ]; then
  admin_dash=$(env_get "$ADMIN_HOME/.env" SQUAD_DASH_PORT)
  [ -n "$admin_dash" ] || admin_dash="$ADMIN_DASH_PORT"
  admin_health="up=$(running_count platform-admin)"
  print_row "platform-admin" "$admin_dash" "-" "-" "http://admin.localhost:8800" "Admin (platform)" "$admin_health"
fi

# --- every squad -------------------------------------------------------------
if [ -d "$SQUADS_ROOT" ]; then
  for d in "$SQUADS_ROOT"/*/; do
    [ -f "$d/.env" ] || continue
    slug=$(basename "$d")
    dash=$(env_get "$d/.env" SQUAD_DASH_PORT)
    pc=$(env_get "$d/.env" SQUAD_PAPERCLIP_PORT)
    pw=$(env_get "$d/.env" SQUAD_PLAYWRIGHT_PORT)
    company=$(company_names "$d")
    health="up=$(running_count "${slug}-")"
    # gonorth is grandfathered on off-grid ports (base ~7600) — flag, do not normalize.
    case "$slug" in gonorth) health="$health (grandfathered)";; esac
    print_row "$slug" "${dash:-?}" "${pc:-?}" "${pw:-?}" "http://dash.$slug.localhost:8800" "$company" "$health"
  done
else
  echo "(squads root $SQUADS_ROOT not found)"
fi

echo
echo "Health is a cheap running-container hint. For the authoritative check run:"
echo "  ./squadctl doctor        # ports listening + caddy routes LOADED + load-bearing up"
echo "  ./squadctl status <slug> # compose ps + memory/CPU vs limits for one squad"
