#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# health-check.sh -- Quick health check for one squad's services
#
# Checks: docker compose services, Paperclip API, war-room tmux, dashboard.
# Prints pass/fail per service with an overall status.
#
# Works for ANY compose project — everything is env-driven:
#   COMPOSE_PROJECT_NAME   compose project to scope to (-p); default: the
#                          repo-dir default project (legacy single-squad)
#   SQUAD_ENV_FILE         squad .env passed to compose (--env-file)
#   SQUAD_PAPERCLIP_PORT   host port of this squad's Paperclip (default 3100)
#   SQUAD_DASH_PORT        host port of this squad's dashboard (default 7682)
#   WAR_ROOM_SERVICE       compose service name of the agent container
#                          (default war-room)
#   WAR_ROOM_TMUX_SESSION  tmux session inside it (default war-room — the
#                          session name is container-internal and identical
#                          for every squad)
#
# Example: COMPOSE_PROJECT_NAME=acme SQUAD_ENV_FILE=/srv/squads/acme/.env \
#          SQUAD_PAPERCLIP_PORT=7802 SQUAD_DASH_PORT=7801 scripts/health-check.sh
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

PAPERCLIP_PORT="${SQUAD_PAPERCLIP_PORT:-${PAPERCLIP_PORT:-3100}}"
DASH_PORT="${SQUAD_DASH_PORT:-7682}"
PAPERCLIP_URL="http://localhost:${PAPERCLIP_PORT}"
DASH_URL="http://localhost:${DASH_PORT}"
WAR_ROOM_SERVICE="${WAR_ROOM_SERVICE:-war-room}"
TMUX_SESSION="${WAR_ROOM_TMUX_SESSION:-war-room}"

# Scope compose to the squad's project/env when provided (squadctl sets both).
COMPOSE_ARGS=()
[ -n "${COMPOSE_PROJECT_NAME:-}" ] && COMPOSE_ARGS+=(-p "$COMPOSE_PROJECT_NAME")
[ -n "${SQUAD_ENV_FILE:-}" ] && COMPOSE_ARGS+=(--env-file "$SQUAD_ENV_FILE")
compose() {
  # ${arr[@]+...} keeps `set -u` happy on bash 3.2 when the array is empty
  docker compose ${COMPOSE_ARGS[@]+"${COMPOSE_ARGS[@]}"} "$@"
}

# ---------------------------------------------------------------------------
# Color helpers
# ---------------------------------------------------------------------------
if [[ "${TERM:-dumb}" != "dumb" ]] && command -v tput &>/dev/null; then
  BOLD=$(tput bold)
  GREEN=$(tput setaf 2)
  YELLOW=$(tput setaf 3)
  RED=$(tput setaf 1)
  CYAN=$(tput setaf 6)
  RESET=$(tput sgr0)
else
  BOLD="" GREEN="" YELLOW="" RED="" CYAN="" RESET=""
fi

PASS="${GREEN}PASS${RESET}"
FAIL="${RED}FAIL${RESET}"
WARN="${YELLOW}WARN${RESET}"

OVERALL=0   # 0 = all pass, non-zero = at least one failure

check() {
  local label="$1"
  local result="$2"  # 0 = pass
  local detail="${3:-}"

  if [[ "$result" -eq 0 ]]; then
    printf "  %-35s %s" "$label" "$PASS"
  else
    printf "  %-35s %s" "$label" "$FAIL"
    OVERALL=1
  fi
  if [[ -n "$detail" ]]; then
    printf "  %s" "$detail"
  fi
  echo
}

echo
echo "${BOLD}${CYAN}=== Interactive Dev Team Health Check ===${RESET}"
echo

# ---------------------------------------------------------------------------
# 1. Docker Compose services
# ---------------------------------------------------------------------------
echo "${BOLD}Docker Compose Services${RESET}"

cd "$PROJECT_DIR"

# Get running service names
COMPOSE_OUTPUT=$(compose ps --format '{{.Name}} {{.State}} {{.Health}}' 2>/dev/null || echo "")

if [[ -z "$COMPOSE_OUTPUT" ]]; then
  check "docker compose" 1 "no services found -- is the squad up? (docker compose up -d)"
else
  while IFS= read -r line; do
    NAME=$(echo "$line" | awk '{print $1}')
    STATE=$(echo "$line" | awk '{print $2}')
    HEALTH=$(echo "$line" | awk '{print $3}')

    if [[ "$STATE" == "running" ]]; then
      if [[ "$HEALTH" == "healthy" || "$HEALTH" == "" || "$HEALTH" == "(healthy)" ]]; then
        check "$NAME" 0 "state=${STATE} health=${HEALTH:-n/a}"
      else
        check "$NAME" 1 "state=${STATE} health=${HEALTH}"
      fi
    else
      check "$NAME" 1 "state=${STATE}"
    fi
  done <<< "$COMPOSE_OUTPUT"
fi

echo

# ---------------------------------------------------------------------------
# 2. Paperclip health endpoint
# ---------------------------------------------------------------------------
echo "${BOLD}Paperclip API${RESET}"

PAPERCLIP_HTTP=$(curl -s -o /dev/null -w "%{http_code}" "${PAPERCLIP_URL}/api/health" 2>/dev/null || echo "000")
if [[ "$PAPERCLIP_HTTP" == "200" ]]; then
  check "GET /api/health" 0 "HTTP ${PAPERCLIP_HTTP}"
else
  check "GET /api/health" 1 "HTTP ${PAPERCLIP_HTTP} (expected 200)"
fi

# Check company exists
COMPANY_COUNT=$(curl -sf "${PAPERCLIP_URL}/api/companies" 2>/dev/null \
  | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")
if [[ "$COMPANY_COUNT" -gt 0 ]]; then
  check "Registered companies" 0 "count=${COMPANY_COUNT}"
else
  check "Registered companies" 1 "none found -- run scripts/setup-company.sh"
fi

echo

# ---------------------------------------------------------------------------
# 3. War-room tmux session
# ---------------------------------------------------------------------------
echo "${BOLD}War Room (tmux)${RESET}"

WAR_ROOM_CONTAINER=$(compose ps -q "$WAR_ROOM_SERVICE" 2>/dev/null || echo "")
if [[ -n "$WAR_ROOM_CONTAINER" ]]; then
  TMUX_OUTPUT=$(docker exec "$WAR_ROOM_CONTAINER" tmux list-sessions 2>/dev/null || echo "")
  if echo "$TMUX_OUTPUT" | grep -q "$TMUX_SESSION"; then
    WINDOW_COUNT=$(docker exec "$WAR_ROOM_CONTAINER" tmux list-windows -t "$TMUX_SESSION" 2>/dev/null | wc -l | tr -d ' ')
    check "tmux $TMUX_SESSION session" 0 "windows=${WINDOW_COUNT}"
  else
    check "tmux $TMUX_SESSION session" 1 "session not found"
  fi
else
  check "$WAR_ROOM_SERVICE container" 1 "not running"
fi

echo

# ---------------------------------------------------------------------------
# 4. Dashboard (warroom2)
# ---------------------------------------------------------------------------
echo "${BOLD}Dashboard (warroom2)${RESET}"

DASH_HTTP=$(curl -s -o /dev/null -w "%{http_code}" "${DASH_URL}" 2>/dev/null || echo "000")
if [[ "$DASH_HTTP" == "200" || "$DASH_HTTP" == "401" ]]; then
  # 401 is expected when basic auth is enabled
  if [[ "$DASH_HTTP" == "401" ]]; then
    check "dashboard at ${DASH_URL}" 0 "HTTP 401 (auth enabled)"
  else
    check "dashboard at ${DASH_URL}" 0 "HTTP ${DASH_HTTP}"
  fi
else
  check "dashboard at ${DASH_URL}" 1 "HTTP ${DASH_HTTP} (expected 200 or 401)"
fi

echo

# ---------------------------------------------------------------------------
# Overall
# ---------------------------------------------------------------------------
echo "---"
if [[ "$OVERALL" -eq 0 ]]; then
  echo "${BOLD}${GREEN}Overall: ALL CHECKS PASSED${RESET}"
else
  echo "${BOLD}${RED}Overall: SOME CHECKS FAILED${RESET}"
  echo "  Run 'scripts/setup-company.sh' to register the company, or 'docker compose up -d' to start services."
fi
echo

exit "$OVERALL"
