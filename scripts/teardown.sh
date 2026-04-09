#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# teardown.sh -- Clean removal of Interactive Dev Team services and data
#
# Stops containers, removes volumes, and optionally cleans up local files.
# Always confirms before destructive actions.
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

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

info()    { echo "${GREEN}[+]${RESET} $*"; }
warn()    { echo "${YELLOW}[!]${RESET} $*"; }
error()   { echo "${RED}[x]${RESET} $*"; }
section() { echo; echo "${BOLD}${CYAN}=== $* ===${RESET}"; }

# ---------------------------------------------------------------------------
# Parse flags
# ---------------------------------------------------------------------------
FORCE=false
REMOVE_PAPERCLIP=false
REMOVE_ENV=false
REMOVE_ALL=false

usage() {
  echo "Usage: $0 [OPTIONS]"
  echo
  echo "Options:"
  echo "  --force          Skip confirmation prompts"
  echo "  --remove-all     Remove everything (paperclip clone, .env, .env.generated)"
  echo "  --help           Show this help"
  echo
}

for arg in "$@"; do
  case "$arg" in
    --force)       FORCE=true ;;
    --remove-all)  REMOVE_ALL=true ;;
    --help|-h)     usage; exit 0 ;;
    *)             echo "Unknown option: $arg"; usage; exit 1 ;;
  esac
done

confirm() {
  local prompt="$1"
  if [[ "$FORCE" == "true" ]]; then
    return 0
  fi
  read -rp "${prompt} [y/N] " answer
  [[ "${answer,,}" == "y" ]]
}

# ---------------------------------------------------------------------------
# 1. Stop containers and remove volumes
# ---------------------------------------------------------------------------
section "Stopping services"

cd "$PROJECT_DIR"

# Check if any services are running
if docker compose ps -q 2>/dev/null | grep -q .; then
  info "Running services detected"
  docker compose ps 2>/dev/null || true
  echo
  if confirm "Stop all containers and remove volumes? This will delete Paperclip data."; then
    info "Stopping containers and removing volumes..."
    docker compose down -v
    info "Containers and volumes removed"
  else
    info "Skipped container teardown"
  fi
else
  info "No running services found"
  # Still attempt down -v to clean up orphan volumes
  docker compose down -v 2>/dev/null || true
fi

# ---------------------------------------------------------------------------
# 2. Optionally remove Paperclip clone
# ---------------------------------------------------------------------------
section "Optional cleanup"

PAPERCLIP_DIR="${PROJECT_DIR}/paperclip"
if [[ -d "$PAPERCLIP_DIR" ]]; then
  if [[ "$REMOVE_ALL" == "true" ]] || confirm "Remove Paperclip clone at ${PAPERCLIP_DIR}?"; then
    info "Removing ${PAPERCLIP_DIR} ..."
    rm -rf "$PAPERCLIP_DIR"
    info "Paperclip clone removed"
    REMOVE_PAPERCLIP=true
  else
    info "Keeping Paperclip clone"
  fi
else
  info "No Paperclip clone found at ${PAPERCLIP_DIR}"
fi

# ---------------------------------------------------------------------------
# 3. Optionally remove .env and .env.generated
# ---------------------------------------------------------------------------
if [[ -f "${PROJECT_DIR}/.env.generated" ]]; then
  if [[ "$REMOVE_ALL" == "true" ]] || confirm "Remove .env.generated?"; then
    rm -f "${PROJECT_DIR}/.env.generated"
    info "Removed .env.generated"
    REMOVE_ENV=true
  else
    info "Keeping .env.generated"
  fi
fi

if [[ -f "${PROJECT_DIR}/.env" ]]; then
  if [[ "$REMOVE_ALL" == "true" ]] || confirm "Remove .env? (contains your API keys and tokens)"; then
    rm -f "${PROJECT_DIR}/.env"
    info "Removed .env"
    REMOVE_ENV=true
  else
    info "Keeping .env"
  fi
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
section "Teardown complete"

echo
echo "  Containers & volumes:  ${GREEN}removed${RESET}"
if [[ "$REMOVE_PAPERCLIP" == "true" ]]; then
  echo "  Paperclip clone:       ${GREEN}removed${RESET}"
else
  echo "  Paperclip clone:       ${YELLOW}kept${RESET}"
fi
if [[ "$REMOVE_ENV" == "true" ]]; then
  echo "  Environment files:     ${GREEN}removed${RESET}"
else
  echo "  Environment files:     ${YELLOW}kept${RESET}"
fi
echo
echo "  To start fresh, run: ${BOLD}scripts/setup.sh${RESET}"
echo
