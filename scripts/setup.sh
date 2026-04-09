#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# setup.sh -- One-time onboarding for Interactive Dev Team (AI Agent War Room)
#
# Checks prerequisites, clones Paperclip, starts the control plane,
# registers the Go-North company and its agents, and writes IDs to
# .env.generated so docker-compose can wire everything together.
#
# Safe to run multiple times (idempotent).
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

PAPERCLIP_PORT="${PAPERCLIP_PORT:-3100}"
PAPERCLIP_URL="http://localhost:${PAPERCLIP_PORT}"
HEALTH_ENDPOINT="${PAPERCLIP_URL}/api/health"
HEALTH_TIMEOUT=60

ENV_FILE="${PROJECT_DIR}/.env"
ENV_EXAMPLE="${PROJECT_DIR}/.env.example"
ENV_GENERATED="${PROJECT_DIR}/.env.generated"

# ---------------------------------------------------------------------------
# Color helpers (disabled when TERM is dumb or unset)
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

die() { error "$@"; exit 1; }

# ---------------------------------------------------------------------------
# 1. Prerequisites
# ---------------------------------------------------------------------------
section "Checking prerequisites"

check_cmd() {
  if ! command -v "$1" &>/dev/null; then
    die "$1 is required but not found. Please install it first."
  fi
  info "$1 found: $(command -v "$1")"
}

check_cmd docker
check_cmd git

# Docker Compose v2 (docker compose, not docker-compose)
if docker compose version &>/dev/null; then
  COMPOSE_VERSION=$(docker compose version --short 2>/dev/null || docker compose version 2>/dev/null)
  info "docker compose v2 found: ${COMPOSE_VERSION}"
else
  die "docker compose v2 is required. Install Docker Desktop or the compose plugin."
fi

# Docker daemon running?
if ! docker info &>/dev/null; then
  die "Docker daemon is not running. Please start Docker Desktop or dockerd."
fi

# ---------------------------------------------------------------------------
# 2. .env file
# ---------------------------------------------------------------------------
section "Environment configuration"

if [[ -f "$ENV_FILE" ]]; then
  info ".env already exists -- skipping copy"
else
  if [[ ! -f "$ENV_EXAMPLE" ]]; then
    die ".env.example not found at ${ENV_EXAMPLE}"
  fi
  cp "$ENV_EXAMPLE" "$ENV_FILE"
  info "Copied .env.example -> .env"
  echo
  warn "ACTION REQUIRED: Open ${ENV_FILE} and fill in at least:"
  warn "  - ANTHROPIC_API_KEY (or Bedrock credentials)"
  warn "  - CAPTAIN_TELEGRAM_TOKEN"
  warn "  - CEO_GONORTH_TELEGRAM_TOKEN"
  warn "  - UX_GONORTH_TELEGRAM_TOKEN"
  warn "  - GONORTH_GROUP_ID"
  echo
  read -rp "Press Enter once you have saved .env, or Ctrl+C to abort... "
fi

# Quick sanity: at least one LLM provider must be set
# shellcheck disable=SC1090
source "$ENV_FILE" 2>/dev/null || true
if [[ -z "${ANTHROPIC_API_KEY:-}" ]] && [[ -z "${CLAUDE_CODE_USE_BEDROCK:-}" ]]; then
  warn "Neither ANTHROPIC_API_KEY nor CLAUDE_CODE_USE_BEDROCK is set in .env"
  warn "The war-room container will fail to start without an LLM provider."
fi

# ---------------------------------------------------------------------------
# 3. Clone Paperclip (if needed)
# ---------------------------------------------------------------------------
section "Paperclip source"

PAPERCLIP_SOURCE="${PAPERCLIP_SOURCE:-${PROJECT_DIR}/paperclip}"

if [[ -d "$PAPERCLIP_SOURCE" ]] && [[ -f "$PAPERCLIP_SOURCE/Dockerfile" ]]; then
  info "Paperclip source found at ${PAPERCLIP_SOURCE}"
else
  info "Cloning Paperclip into ${PAPERCLIP_SOURCE} ..."
  git clone https://github.com/paperclipai/paperclip.git "$PAPERCLIP_SOURCE"
  info "Clone complete"
fi

# ---------------------------------------------------------------------------
# 4. Build and start Paperclip
# ---------------------------------------------------------------------------
section "Starting Paperclip"

cd "$PROJECT_DIR"

# Check if paperclip container is already running and healthy
if docker compose ps --format json 2>/dev/null | grep -q '"paperclip"'; then
  PAPERCLIP_STATE=$(docker compose ps --format '{{.State}}' paperclip 2>/dev/null || echo "unknown")
  if [[ "$PAPERCLIP_STATE" == "running" ]]; then
    info "Paperclip container is already running"
  else
    info "Paperclip container exists but state=${PAPERCLIP_STATE}, restarting..."
    docker compose up -d --build paperclip
  fi
else
  info "Building and starting Paperclip (first time may take a few minutes)..."
  docker compose up -d --build paperclip
fi

# ---------------------------------------------------------------------------
# 5. Wait for Paperclip health
# ---------------------------------------------------------------------------
section "Waiting for Paperclip to be healthy"

elapsed=0
while (( elapsed < HEALTH_TIMEOUT )); do
  if curl -sf "$HEALTH_ENDPOINT" &>/dev/null; then
    info "Paperclip is healthy at ${PAPERCLIP_URL}"
    break
  fi
  sleep 2
  elapsed=$((elapsed + 2))
  printf "\r  waiting... %ds / %ds" "$elapsed" "$HEALTH_TIMEOUT"
done
echo

if (( elapsed >= HEALTH_TIMEOUT )); then
  die "Paperclip did not become healthy within ${HEALTH_TIMEOUT}s. Check: docker compose logs paperclip"
fi

# ---------------------------------------------------------------------------
# 6 & 7. Register Go-North company and agents in Paperclip
# ---------------------------------------------------------------------------
section "Registering Go-North company in Paperclip"

api() {
  local method="$1" path="$2"
  shift 2
  curl -sf -X "$method" \
    -H "Content-Type: application/json" \
    "${PAPERCLIP_URL}/api${path}" \
    "$@"
}

# Check if company already exists (idempotent)
EXISTING_COMPANIES=$(api GET /companies 2>/dev/null || echo "[]")
COMPANY_ID=$(echo "$EXISTING_COMPANIES" | python3 -c "
import sys, json
companies = json.load(sys.stdin)
for c in companies:
    if 'Go-North' in c.get('name', '') or 'go-north' in c.get('name', '').lower():
        print(c['id'])
        break
" 2>/dev/null || echo "")

if [[ -n "$COMPANY_ID" ]]; then
  info "Go-North company already exists: ${COMPANY_ID}"
else
  info "Creating Go-North company..."
  COMPANY_RESPONSE=$(api POST /companies \
    -d '{
      "name": "Go-North",
      "description": "AI-powered relocation assistant for families moving to northern Israel"
    }')

  COMPANY_ID=$(echo "$COMPANY_RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")
  if [[ -z "$COMPANY_ID" ]]; then
    die "Failed to create company. Response: ${COMPANY_RESPONSE}"
  fi
  info "Company created: ${COMPANY_ID}"
fi

# --- Register agents ---
# Agent definitions matching companies/go-north/.paperclip.yaml
declare -A AGENT_DEFS=(
  ["product-manager"]='{"name":"Product Manager","role":"pm","title":"Product Manager","adapterType":"claude_local","adapterConfig":{"model":"claude-sonnet-4-6","dangerouslySkipPermissions":true}}'
  ["finance-officer"]='{"name":"Finance Officer","role":"cfo","title":"Finance Officer","adapterType":"claude_local","adapterConfig":{"model":"claude-haiku-4-5-20251001","dangerouslySkipPermissions":true}}'
  ["frontend-dev"]='{"name":"Frontend Developer","role":"engineer","title":"Frontend Developer","adapterType":"claude_local","adapterConfig":{"model":"claude-sonnet-4-6","dangerouslySkipPermissions":true}}'
  ["backend-dev"]='{"name":"Backend Developer","role":"engineer","title":"Backend Developer","adapterType":"claude_local","adapterConfig":{"model":"claude-sonnet-4-6","dangerouslySkipPermissions":true}}'
  ["qa-lead"]='{"name":"QA Lead","role":"qa","title":"QA Lead","adapterType":"claude_local","adapterConfig":{"model":"claude-sonnet-4-6","dangerouslySkipPermissions":true}}'
  ["ux-designer"]='{"name":"UX Designer","role":"designer","title":"UX Designer","adapterType":"claude_local","adapterConfig":{"model":"claude-sonnet-4-6","dangerouslySkipPermissions":true}}'
)

# Ordered list to preserve deterministic iteration
AGENT_ORDER=("product-manager" "finance-officer" "frontend-dev" "backend-dev" "qa-lead" "ux-designer")

# Fetch existing agents
EXISTING_AGENTS=$(api GET "/companies/${COMPANY_ID}/agents" 2>/dev/null || echo "[]")

declare -A AGENT_IDS=()

for slug in "${AGENT_ORDER[@]}"; do
  body="${AGENT_DEFS[$slug]}"

  # Check if agent already registered
  AGENT_ID=$(echo "$EXISTING_AGENTS" | python3 -c "
import sys, json
agents = json.load(sys.stdin)
slug = '${slug}'
name_map = {
  'product-manager': 'Product Manager',
  'finance-officer': 'Finance Officer',
  'frontend-dev': 'Frontend Developer',
  'backend-dev': 'Backend Developer',
  'qa-lead': 'QA Lead',
  'ux-designer': 'UX Designer',
}
target = name_map.get(slug, slug)
for a in agents:
    if a.get('name') == target or a.get('slug') == slug:
        print(a['id'])
        break
" 2>/dev/null || echo "")

  if [[ -n "$AGENT_ID" ]]; then
    info "Agent ${slug} already registered: ${AGENT_ID}"
  else
    AGENT_RESPONSE=$(api POST "/companies/${COMPANY_ID}/agents" -d "$body")
    AGENT_ID=$(echo "$AGENT_RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")
    if [[ -z "$AGENT_ID" ]]; then
      warn "Failed to create agent ${slug}. Response: ${AGENT_RESPONSE}"
      continue
    fi
    info "Agent ${slug} created: ${AGENT_ID}"
  fi

  AGENT_IDS["$slug"]="$AGENT_ID"
done

# ---------------------------------------------------------------------------
# 8. Write IDs to .env.generated
# ---------------------------------------------------------------------------
section "Writing generated configuration"

cat > "$ENV_GENERATED" <<EOF
# Auto-generated by scripts/setup.sh -- do not edit manually
# Re-run scripts/setup.sh to regenerate.

GONORTH_COMPANY_ID=${COMPANY_ID}
PRODUCT_MANAGER_AGENT_ID=${AGENT_IDS[product-manager]:-}
FINANCE_OFFICER_AGENT_ID=${AGENT_IDS[finance-officer]:-}
FRONTEND_DEV_AGENT_ID=${AGENT_IDS[frontend-dev]:-}
BACKEND_DEV_AGENT_ID=${AGENT_IDS[backend-dev]:-}
QA_LEAD_AGENT_ID=${AGENT_IDS[qa-lead]:-}
UX_DESIGNER_AGENT_ID=${AGENT_IDS[ux-designer]:-}
EOF

info "IDs written to ${ENV_GENERATED}"

# ---------------------------------------------------------------------------
# 9. Summary
# ---------------------------------------------------------------------------
section "Setup complete"

echo
echo "  ${BOLD}Go-North Company${RESET}"
echo "    Company ID:   ${COMPANY_ID}"
echo
echo "  ${BOLD}Agents${RESET}"
for slug in "${AGENT_ORDER[@]}"; do
  printf "    %-20s %s\n" "${slug}:" "${AGENT_IDS[$slug]:-<not created>}"
done
echo
echo "  ${BOLD}URLs${RESET}"
echo "    Paperclip UI:  ${PAPERCLIP_URL}"
echo "    War Room:      http://localhost:${TTYD_PORT:-7681}  (after full stack start)"
echo
echo "  ${BOLD}Files${RESET}"
echo "    .env            -- your secrets (do not commit)"
echo "    .env.generated  -- auto-populated agent/company IDs"
echo

# ---------------------------------------------------------------------------
# 10. Optionally start the full stack
# ---------------------------------------------------------------------------
echo "${BOLD}Next steps:${RESET}"
echo "  Start the full stack (war-room + Paperclip):"
echo "    cd ${PROJECT_DIR} && docker compose up -d"
echo
echo "  Or start now:"
read -rp "  Start full stack now? [y/N] " START_FULL
if [[ "${START_FULL,,}" == "y" ]]; then
  info "Starting full stack..."
  cd "$PROJECT_DIR"
  docker compose up -d
  info "Full stack started. Open http://localhost:${TTYD_PORT:-7681} for the war room."
else
  info "Skipped. Run 'docker compose up -d' when ready."
fi
