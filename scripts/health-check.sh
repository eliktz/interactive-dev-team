#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# health-check.sh -- Quick health check for all Interactive Dev Team services
#
# Checks: docker compose services, Paperclip API, war-room tmux, ttyd
# Prints pass/fail per service with an overall status.
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

PAPERCLIP_PORT="${PAPERCLIP_PORT:-3100}"
TTYD_PORT="${TTYD_PORT:-7681}"
PAPERCLIP_URL="http://localhost:${PAPERCLIP_PORT}"
TTYD_URL="http://localhost:${TTYD_PORT}"

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
COMPOSE_OUTPUT=$(docker compose ps --format '{{.Name}} {{.State}} {{.Health}}' 2>/dev/null || echo "")

if [[ -z "$COMPOSE_OUTPUT" ]]; then
  check "docker compose" 1 "no services found -- run setup.sh first"
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
  check "Registered companies" 1 "none found -- run setup.sh"
fi

echo

# ---------------------------------------------------------------------------
# 3. War-room tmux session
# ---------------------------------------------------------------------------
echo "${BOLD}War Room (tmux)${RESET}"

WAR_ROOM_CONTAINER=$(docker compose ps -q war-room 2>/dev/null || echo "")
if [[ -n "$WAR_ROOM_CONTAINER" ]]; then
  TMUX_OUTPUT=$(docker exec "$WAR_ROOM_CONTAINER" tmux list-sessions 2>/dev/null || echo "")
  if echo "$TMUX_OUTPUT" | grep -q "war-room"; then
    PANE_COUNT=$(docker exec "$WAR_ROOM_CONTAINER" tmux list-panes -t war-room 2>/dev/null | wc -l | tr -d ' ')
    check "tmux war-room session" 0 "panes=${PANE_COUNT}"
  else
    check "tmux war-room session" 1 "session not found"
  fi
else
  check "war-room container" 1 "not running"
fi

echo

# ---------------------------------------------------------------------------
# 4. ttyd web terminal
# ---------------------------------------------------------------------------
echo "${BOLD}ttyd Web Terminal${RESET}"

TTYD_HTTP=$(curl -s -o /dev/null -w "%{http_code}" "${TTYD_URL}" 2>/dev/null || echo "000")
if [[ "$TTYD_HTTP" == "200" || "$TTYD_HTTP" == "401" ]]; then
  # 401 is expected when basic auth is enabled
  if [[ "$TTYD_HTTP" == "401" ]]; then
    check "ttyd at ${TTYD_URL}" 0 "HTTP 401 (auth enabled)"
  else
    check "ttyd at ${TTYD_URL}" 0 "HTTP ${TTYD_HTTP}"
  fi
else
  check "ttyd at ${TTYD_URL}" 1 "HTTP ${TTYD_HTTP} (expected 200 or 401)"
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
  echo "  Run 'scripts/setup.sh' to initialize, or 'docker compose up -d' to start services."
fi
echo

exit "$OVERALL"
