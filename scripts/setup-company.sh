#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# setup-company.sh -- Register a squad's company + worker agents in Paperclip
#
# Called by `squadctl new <slug>` during the STAGED bring-up: after the
# squad's paperclip container is healthy and BEFORE war-room/warroom2 start,
# so the PAPERCLIP_COMPANY_ID written back here is already in war-room's env
# on its first boot (no post-hoc restart).
#
# Safe to run multiple times (idempotent: existing company/agents are looked
# up by name before anything is created).
#
# Usage:
#   scripts/setup-company.sh --slug <slug> --name "<display name>" \
#       [--env-file <path>] [--agents-json <path>] [--paperclip-url <url>]
#
#   --slug          squad slug (^[a-z][a-z0-9-]{1,22}$)
#   --name          company display name in Paperclip
#   --env-file      squad .env (e.g. /srv/squads/<slug>/.env). After the
#                   company is registered, PAPERCLIP_COMPANY_ID=<uuid> is
#                   written back into this file (updated in place when the
#                   key exists, appended otherwise). Also used to derive
#                   defaults: SQUAD_PAPERCLIP_PORT (paperclip URL) and
#                   SQUAD_HOME (-> config/agents.json roster).
#   --agents-json   roster file; its agents become Paperclip workers.
#                   Default: $SQUAD_HOME/config/agents.json when resolvable.
#                   Missing/unreadable roster -> ONE generic "Captain" worker
#                   (no hardcoded multi-agent roster).
#   --paperclip-url override the Paperclip base URL.
#                   Default: http://127.0.0.1:${SQUAD_PAPERCLIP_PORT:-3100}
# =============================================================================

SLUG=""
NAME=""
ENV_FILE=""
AGENTS_JSON=""
PAPERCLIP_URL="${PAPERCLIP_URL:-}"
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-60}"

info() { echo "[setup-company] $*"; }
warn() { echo "[setup-company] WARNING: $*" >&2; }
die()  { echo "[setup-company] ERROR: $*" >&2; exit 1; }

usage() {
  sed -n '/^# Usage:/,/^# ====/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

# ---------------------------------------------------------------------------
# Parse flags
# ---------------------------------------------------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    --slug)          SLUG="${2:?--slug needs a value}"; shift 2 ;;
    --name)          NAME="${2:?--name needs a value}"; shift 2 ;;
    --env-file)      ENV_FILE="${2:?--env-file needs a value}"; shift 2 ;;
    --agents-json)   AGENTS_JSON="${2:?--agents-json needs a value}"; shift 2 ;;
    --paperclip-url) PAPERCLIP_URL="${2:?--paperclip-url needs a value}"; shift 2 ;;
    --help|-h)       usage; exit 0 ;;
    *)               die "unknown option: $1 (see --help)" ;;
  esac
done

[ -n "$SLUG" ] || die "--slug is required"
[ -n "$NAME" ] || die "--name is required"
[[ "$SLUG" =~ ^[a-z][a-z0-9-]{1,22}$ ]] || die "invalid slug '$SLUG' (^[a-z][a-z0-9-]{1,22}\$)"

# ---------------------------------------------------------------------------
# Read non-secret keys from the squad .env (NEVER sourced — it holds secrets
# and lines a shell would execute; grep only the few keys we need).
# ---------------------------------------------------------------------------
env_get() {
  # env_get KEY -> last assignment's value, empty when absent
  [ -n "$ENV_FILE" ] && [ -f "$ENV_FILE" ] || return 0
  grep -E "^${1}=" "$ENV_FILE" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

if [ -n "$ENV_FILE" ] && [ ! -f "$ENV_FILE" ]; then
  die "env file not found: $ENV_FILE"
fi

SQUAD_HOME_VAL="$(env_get SQUAD_HOME)"
if [ -z "$PAPERCLIP_URL" ]; then
  port="$(env_get SQUAD_PAPERCLIP_PORT)"
  PAPERCLIP_URL="http://127.0.0.1:${port:-3100}"
fi
if [ -z "$AGENTS_JSON" ] && [ -n "$SQUAD_HOME_VAL" ]; then
  AGENTS_JSON="${SQUAD_HOME_VAL}/config/agents.json"
fi

info "slug=$SLUG name='$NAME' paperclip=$PAPERCLIP_URL"
info "roster: ${AGENTS_JSON:-<none — generic single-captain default>}"

# ---------------------------------------------------------------------------
# Wait for Paperclip health
# ---------------------------------------------------------------------------
api() {
  local method="$1" path="$2"
  shift 2
  curl -sf -X "$method" -H "Content-Type: application/json" \
    "${PAPERCLIP_URL}/api${path}" "$@"
}

elapsed=0
until curl -sf "${PAPERCLIP_URL}/api/health" >/dev/null 2>&1; do
  (( elapsed >= HEALTH_TIMEOUT )) && die "Paperclip not healthy at ${PAPERCLIP_URL} after ${HEALTH_TIMEOUT}s"
  sleep 2
  elapsed=$((elapsed + 2))
done
info "Paperclip healthy at ${PAPERCLIP_URL}"

# ---------------------------------------------------------------------------
# Company: look up by name/slug, create when missing (idempotent)
# ---------------------------------------------------------------------------
EXISTING_COMPANIES=$(api GET /companies 2>/dev/null || echo "[]")
COMPANY_ID=$(SC_NAME="$NAME" SC_SLUG="$SLUG" python3 -c "
import sys, json, os
name, slug = os.environ['SC_NAME'], os.environ['SC_SLUG']
for c in json.load(sys.stdin):
    if c.get('name') == name or c.get('slug') == slug:
        print(c['id']); break
" <<<"$EXISTING_COMPANIES" 2>/dev/null || echo "")

if [ -n "$COMPANY_ID" ]; then
  info "company already exists: $COMPANY_ID"
else
  info "creating company '$NAME'..."
  body=$(SC_NAME="$NAME" SC_SLUG="$SLUG" python3 -c "
import json, os
print(json.dumps({'name': os.environ['SC_NAME'],
                  'description': 'Agent squad \"' + os.environ['SC_SLUG'] + '\" (registered by setup-company.sh)'}))
")
  COMPANY_RESPONSE=$(api POST /companies -d "$body")
  COMPANY_ID=$(python3 -c "import sys,json; print(json.load(sys.stdin)['id'])" <<<"$COMPANY_RESPONSE" 2>/dev/null || echo "")
  [ -n "$COMPANY_ID" ] || die "failed to create company. Response: ${COMPANY_RESPONSE}"
  info "company created: $COMPANY_ID"
fi

# ---------------------------------------------------------------------------
# Workers: derived from the squad's agents.json when present, else ONE
# generic captain (no hardcoded multi-agent roster). Emits one line per
# worker:  slug|name|role|model|capabilities
# model_default aliases (sonnet/opus/haiku) map to full Paperclip model ids;
# anything else passes through verbatim.
# ---------------------------------------------------------------------------
roster_lines() {
  if [ -n "$AGENTS_JSON" ] && [ -f "$AGENTS_JSON" ]; then
    python3 - "$AGENTS_JSON" <<'PYEOF' && return 0
import json, sys
MODEL_MAP = {"sonnet": "claude-sonnet-4-6", "opus": "claude-opus-4-6",
             "haiku": "claude-haiku-4-5"}
try:
    j = json.load(open(sys.argv[1]))
    agents = [a for a in j.get("agents", []) if a and a.get("id")]
    if not agents:
        raise ValueError("no agents in roster")
    lines = []
    for a in agents:
        slug = str(a["id"])
        name = str(a.get("label") or slug.replace("-", " ").title())
        role = str(a.get("role") or "engineer")
        model = str(a.get("model_default") or "sonnet")
        model = MODEL_MAP.get(model, model)
        caps = str(a.get("capabilities") or "")
        fields = [slug, name, role, model, caps]
        if any("|" in f or "\n" in f for f in fields):
            raise ValueError("field contains | or newline on agent " + slug)
        lines.append("|".join(fields))
    # Buffer-then-print: a failure above emits NOTHING, so the caller's
    # generic-default fallback never mixes with a partial roster.
    print("\n".join(lines))
except Exception as e:
    print("agents.json: %s" % e, file=sys.stderr)
    sys.exit(1)
PYEOF
    warn "roster $AGENTS_JSON unreadable/invalid — using the generic single-captain default"
  fi
  echo "captain|Captain|pm|claude-sonnet-4-6|Squad coordination, task triage, delegation"
}

# Container-internal base path for AGENTS.md instruction files (matches the
# ${SQUAD_HOME}/companies -> /paperclip/companies:ro bind in docker-compose).
INSTRUCTIONS_BASE="${PAPERCLIP_INSTRUCTIONS_BASE:-/paperclip/companies/${SLUG}/agents}"

build_agent_body() {
  local slug="$1" name="$2" role="$3" model="$4" caps="$5" reports_to="$6"
  local instructions=""
  # Only declare an instructionsFilePath when the file actually exists in the
  # squad home (checked on the HOST side; the container sees the same tree).
  if [ -n "$SQUAD_HOME_VAL" ] && [ -f "${SQUAD_HOME_VAL}/companies/${SLUG}/agents/${slug}/AGENTS.md" ]; then
    instructions="${INSTRUCTIONS_BASE}/${slug}/AGENTS.md"
  fi
  SC_NAME="$name" SC_ROLE="$role" SC_CAPS="$caps" SC_MODEL="$model" \
  SC_INSTR="$instructions" SC_REPORTS="$reports_to" python3 -c "
import json, os
e = os.environ
body = {
    'name': e['SC_NAME'], 'role': e['SC_ROLE'], 'title': e['SC_NAME'],
    'capabilities': e['SC_CAPS'],
    'adapterType': 'claude_local',
    'adapterConfig': {'model': e['SC_MODEL'], 'dangerouslySkipPermissions': True},
}
if e['SC_INSTR']:
    body['adapterConfig']['instructionsFilePath'] = e['SC_INSTR']
if e['SC_REPORTS']:
    body['reportsTo'] = e['SC_REPORTS']
print(json.dumps(body))
"
}

EXISTING_AGENTS=$(api GET "/companies/${COMPANY_ID}/agents" 2>/dev/null || echo "[]")
LEADER_ID=""

while IFS='|' read -r w_slug w_name w_role w_model w_caps; do
  [ -n "$w_slug" ] || continue

  # First roster entry leads; everyone else reports to it.
  reports_to=""
  [ -n "$LEADER_ID" ] && reports_to="$LEADER_ID"

  AGENT_ID=$(SC_NAME="$w_name" SC_SLUG="$w_slug" python3 -c "
import sys, json, os
name, slug = os.environ['SC_NAME'], os.environ['SC_SLUG']
for a in json.load(sys.stdin):
    if a.get('name') == name or a.get('slug') == slug:
        print(a['id']); break
" <<<"$EXISTING_AGENTS" 2>/dev/null || echo "")

  if [ -n "$AGENT_ID" ]; then
    info "worker '$w_slug' already registered: $AGENT_ID"
  else
    body=$(build_agent_body "$w_slug" "$w_name" "$w_role" "$w_model" "$w_caps" "$reports_to")
    AGENT_RESPONSE=$(api POST "/companies/${COMPANY_ID}/agents" -d "$body" || echo "")
    AGENT_ID=$(python3 -c "import sys,json; print(json.load(sys.stdin)['id'])" <<<"$AGENT_RESPONSE" 2>/dev/null || echo "")
    if [ -z "$AGENT_ID" ]; then
      warn "failed to create worker '$w_slug'. Response: ${AGENT_RESPONSE}"
      continue
    fi
    info "worker '$w_slug' created: $AGENT_ID"
  fi

  [ -n "$LEADER_ID" ] || LEADER_ID="$AGENT_ID"
done < <(roster_lines)

# ---------------------------------------------------------------------------
# Write PAPERCLIP_COMPANY_ID back into the squad .env (update-in-place keeps
# the file's mode/owner — squad .env files are 0600).
# ---------------------------------------------------------------------------
if [ -n "$ENV_FILE" ]; then
  if grep -qE '^PAPERCLIP_COMPANY_ID=' "$ENV_FILE"; then
    tmp=$(mktemp)
    awk -v id="$COMPANY_ID" '
      /^PAPERCLIP_COMPANY_ID=/ { print "PAPERCLIP_COMPANY_ID=" id; next }
      { print }
    ' "$ENV_FILE" > "$tmp"
    cat "$tmp" > "$ENV_FILE"
    rm -f "$tmp"
  else
    printf 'PAPERCLIP_COMPANY_ID=%s\n' "$COMPANY_ID" >> "$ENV_FILE"
  fi
  info "PAPERCLIP_COMPANY_ID=$COMPANY_ID written to $ENV_FILE"
else
  info "no --env-file given — PAPERCLIP_COMPANY_ID=$COMPANY_ID (export it yourself)"
fi

info "done: company '$NAME' ($COMPANY_ID) ready for squad '$SLUG'"
