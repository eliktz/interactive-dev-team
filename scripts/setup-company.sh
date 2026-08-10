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
#       [--env-file <path>] [--agents-json <path>] [--paperclip-url <url>] \
#       [--paperclip-container <name>]
#
# Squads run paperclip in `authenticated` mode (the squad.env.template default,
# matching live squads gonorth/probe and the only mode compatible with the
# HOST=0.0.0.0 + published-loopback-port container topology). A fresh
# authenticated instance has no instance admin, so this script first bootstraps
# one from inside the squad (bootstrap_ceo invite via paperclip's own DB module
# + sign-up + accept) before registering the company — making `squadctl new`
# fully self-contained. The step is idempotent and a no-op for already-bootstrapped
# or local_trusted instances.
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
#   --paperclip-container
#                   container running this squad's paperclip, used only to seed
#                   the first instance_admin in authenticated mode.
#                   Default: <slug>-paperclip-1 (compose-derived).
# =============================================================================

SLUG=""
NAME=""
ENV_FILE=""
AGENTS_JSON=""
PAPERCLIP_URL="${PAPERCLIP_URL:-}"
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-60}"
# Container running this squad's paperclip (used only in authenticated mode to
# seed the first instance_admin via paperclip's own DB module). Defaults to the
# compose-derived name <slug>-paperclip-1; override with --paperclip-container.
PAPERCLIP_CONTAINER="${PAPERCLIP_CONTAINER:-}"

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
    --paperclip-container) PAPERCLIP_CONTAINER="${2:?--paperclip-container needs a value}"; shift 2 ;;
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
# Session cookie jar for authenticated mode. Empty in local_trusted (where the
# board principal is implicit). Populated by bootstrap_authenticated_admin().
SESSION_JAR=""

api() {
  local method="$1" path="$2"
  shift 2
  # Origin==Host is REQUIRED (E2E finding F6): paperclip's board-mutation
  # guard rejects mutations whose Origin header doesn't match the Host —
  # sending it on every call keeps this script working against BOTH the
  # authenticated squad default and any legacy local_trusted instance.
  #
  # In authenticated mode the instance admin's better-auth session cookie
  # (SESSION_JAR, set by bootstrap_authenticated_admin) is replayed on every
  # call so company/agent mutations carry instance_admin authority. In
  # local_trusted mode SESSION_JAR is empty and the implicit local board
  # principal authorizes the calls — so this one helper works for both modes.
  # bash 3.2 (macOS) errors on "${empty[@]}" under set -u, so branch instead of
  # expanding a possibly-empty array.
  if [ -n "$SESSION_JAR" ]; then
    curl -sf -X "$method" -H "Content-Type: application/json" \
      -H "Origin: ${PAPERCLIP_URL}" -b "$SESSION_JAR" \
      "${PAPERCLIP_URL}/api${path}" "$@"
  else
    curl -sf -X "$method" -H "Content-Type: application/json" \
      -H "Origin: ${PAPERCLIP_URL}" \
      "${PAPERCLIP_URL}/api${path}" "$@"
  fi
}

elapsed=0
until curl -sf "${PAPERCLIP_URL}/api/health" >/dev/null 2>&1; do
  (( elapsed >= HEALTH_TIMEOUT )) && die "Paperclip not healthy at ${PAPERCLIP_URL} after ${HEALTH_TIMEOUT}s"
  sleep 2
  elapsed=$((elapsed + 2))
done
info "Paperclip healthy at ${PAPERCLIP_URL}"

# ---------------------------------------------------------------------------
# Authenticated-mode bootstrap (idempotent, no-op for local_trusted)
#
# Squads default to PAPERCLIP_DEPLOYMENT_MODE=authenticated (squad.env.template)
# because that is the ONLY mode compatible with the container topology: compose
# binds the paperclip process to HOST=0.0.0.0 so the published
# 127.0.0.1:<port>:3100 forward can reach it, and paperclip REJECTS local_trusted
# on a non-loopback bind. Authenticated mode starts with ZERO instance admins
# (health: bootstrapStatus=bootstrap_pending) and 403s every unauthenticated
# company/agent mutation, so squadctl new could not register the company.
#
# This step makes `squadctl new` fully self-contained: it seeds the first
# instance_admin entirely from inside the squad, using ONLY supported surfaces:
#   1. create a one-time bootstrap_ceo invite via paperclip's OWN @paperclipai/db
#      module run inside the paperclip container (same insert the bundled
#      `paperclipai auth-bootstrap-ceo` CLI performs — no admin needed, and no
#      psql/extra tooling, which the image does not ship);
#   2. sign up an admin user over HTTP (POST /api/auth/sign-up/email) and keep
#      its better-auth session cookie;
#   3. accept the invite (POST /api/invites/<token>/accept {requestType:human}),
#      which promotes that user to instance_admin (bootstrapStatus -> ready).
# Thereafter SESSION_JAR carries instance_admin authority for company/agent
# creation below. Idempotent: skipped when health already reports ready.
#
# Credentials are GENERATED locally and recorded in the squad's private ops file
# (0600, out-of-tree) — never echoed, never passed on argv, never committed.
# ---------------------------------------------------------------------------
bootstrap_authenticated_admin() {
  local health bootstrap_status
  health="$(curl -sf "${PAPERCLIP_URL}/api/health" 2>/dev/null || echo '{}')"
  bootstrap_status="$(printf '%s' "$health" | python3 -c "
import sys, json
try: print(json.load(sys.stdin).get('bootstrapStatus',''))
except Exception: print('')
" 2>/dev/null || echo "")"

  # local_trusted reports no bootstrapStatus / 'ready'; authenticated-and-already
  # -bootstrapped reports 'ready'. Only 'bootstrap_pending' needs seeding.
  if [ "$bootstrap_status" != "bootstrap_pending" ]; then
    info "no admin bootstrap needed (bootstrapStatus=${bootstrap_status:-n/a})"
    return 0
  fi

  info "authenticated paperclip has no instance admin yet — bootstrapping one"
  local container="${PAPERCLIP_CONTAINER:-${SLUG}-paperclip-1}"
  command -v docker >/dev/null 2>&1 || die "docker is required to bootstrap the authenticated paperclip admin (container ${container})"
  docker inspect "$container" >/dev/null 2>&1 \
    || die "paperclip container '${container}' not found (override with --paperclip-container)"

  # Step 1: create a bootstrap_ceo invite via paperclip's own DB module. The
  # script is dropped INTO the server workspace so the workspace import
  # (@paperclipai/db -> packages/db) resolves, then removed.
  local node_script invite_token
  node_script='import { createHash, randomBytes } from "node:crypto";
import { createDb, invites, instanceUserRoles } from "@paperclipai/db";
import { and, eq, gt, isNull } from "drizzle-orm";
const port = process.env.PAPERCLIP_EMBEDDED_PG_PORT || "54329";
const url = process.env.DATABASE_URL || `postgres://paperclip:paperclip@127.0.0.1:${port}/paperclip`;
const db = createDb(url);
const now = new Date();
await db.update(invites).set({ revokedAt: now, updatedAt: now }).where(and(eq(invites.inviteType,"bootstrap_ceo"), isNull(invites.revokedAt), isNull(invites.acceptedAt), gt(invites.expiresAt, now)));
const token = "pcp_bootstrap_" + randomBytes(24).toString("hex");
await db.insert(invites).values({ inviteType:"bootstrap_ceo", tokenHash: createHash("sha256").update(token).digest("hex"), allowedJoinTypes:"human", expiresAt: new Date(Date.now()+3600*1000), invitedByUserId:"system" });
console.log("INVITE_TOKEN=" + token);
process.exit(0);'

  local marker="/app/server/.squadctl-bootstrap-$$.mjs"
  if ! printf '%s' "$node_script" | docker exec -i "$container" sh -c "cat > '$marker'"; then
    die "failed to stage bootstrap script into ${container}"
  fi
  local raw
  raw="$(docker exec -w /app/server "$container" \
        node --import /app/server/node_modules/tsx/dist/loader.mjs "$marker" 2>&1)" || {
    docker exec "$container" rm -f "$marker" >/dev/null 2>&1 || true
    die "bootstrap_ceo invite creation failed: ${raw}"
  }
  docker exec "$container" rm -f "$marker" >/dev/null 2>&1 || true
  invite_token="$(printf '%s\n' "$raw" | grep '^INVITE_TOKEN=' | tail -1 | cut -d= -f2)"
  [ -n "$invite_token" ] || die "could not obtain bootstrap invite token. Output: ${raw}"
  info "bootstrap_ceo invite created"

  # Step 2: sign up the instance admin and keep its session cookie.
  SESSION_JAR="$(mktemp)"
  # shellcheck disable=SC2064
  trap "rm -f '$SESSION_JAR'" EXIT
  local admin_email admin_pass admin_name
  admin_email="admin@${SLUG}.localhost"
  admin_pass="$(openssl rand -base64 18 | tr -d '/+=' )Aa1!"
  admin_name="${SLUG} Admin"
  local signup_body
  signup_body="$(SC_E="$admin_email" SC_P="$admin_pass" SC_N="$admin_name" python3 -c "
import json, os
print(json.dumps({'email':os.environ['SC_E'],'password':os.environ['SC_P'],'name':os.environ['SC_N']}))")"
  curl -sf -c "$SESSION_JAR" -X POST -H "Content-Type: application/json" \
    -H "Origin: ${PAPERCLIP_URL}" -d "$signup_body" \
    "${PAPERCLIP_URL}/api/auth/sign-up/email" >/dev/null \
    || die "admin sign-up failed at ${PAPERCLIP_URL}/api/auth/sign-up/email"
  info "instance admin user signed up: ${admin_email}"

  # Step 3: accept the bootstrap invite -> promotes the signed-in user to admin.
  api POST "/invites/${invite_token}/accept" -d '{"requestType":"human"}' >/dev/null \
    || die "bootstrap invite acceptance failed"

  # Confirm the promotion took effect.
  local after
  after="$(curl -sf "${PAPERCLIP_URL}/api/health" 2>/dev/null | python3 -c "
import sys, json
try: print(json.load(sys.stdin).get('bootstrapStatus',''))
except Exception: print('')" 2>/dev/null || echo "")"
  [ "$after" = "ready" ] || die "admin bootstrap did not reach 'ready' (got '${after}')"
  info "instance admin bootstrapped — paperclip is ready for company registration"

  # Record the generated admin credential in the squad's private ops file (0600,
  # out-of-tree) so an operator can sign in to the paperclip UI later.
  if [ -n "$SQUAD_HOME_VAL" ] && [ -d "${SQUAD_HOME_VAL}/private" ]; then
    local ops="${SQUAD_HOME_VAL}/private/paperclip-admin.env"
    {
      printf '# Paperclip instance admin (generated by setup-company.sh — keep private).\n'
      printf 'PAPERCLIP_ADMIN_EMAIL=%s\n' "$admin_email"
      printf 'PAPERCLIP_ADMIN_PASSWORD=%s\n' "$admin_pass"
    } > "$ops" 2>/dev/null && chmod 600 "$ops" 2>/dev/null \
      && info "admin credential recorded in ${ops} (0600)" \
      || warn "could not write admin credential to ${ops}"
  else
    info "admin credential (record it safely): email=${admin_email}"
  fi
}

bootstrap_authenticated_admin

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

# ---------------------------------------------------------------------------
# compose_company_instructions <slug>
#
# Compose the company root COMPANY.md + the agent's AGENTS.md into a generated
# INSTRUCTIONS.generated.md alongside the agent's AGENTS.md (HOST side; the
# container sees it through the same companies bind mount). Idempotent: rewrites
# the file on every run so COMPANY.md / AGENTS.md edits propagate.
#
# Returns 0 only when the generated file was written (so the caller switches
# instructionsFilePath to it); returns non-zero — leaving the bare AGENTS.md
# path untouched — when COMPANY.md is absent or the write fails. ADDITIVE: never
# deletes or mutates the source AGENTS.md.
# ---------------------------------------------------------------------------
compose_company_instructions() {
  local slug="$1"
  local company_md="${SQUAD_HOME_VAL}/companies/${SLUG}/COMPANY.md"
  local agents_md="${SQUAD_HOME_VAL}/companies/${SLUG}/agents/${slug}/AGENTS.md"
  local out="${SQUAD_HOME_VAL}/companies/${SLUG}/agents/${slug}/INSTRUCTIONS.generated.md"

  [ -f "$company_md" ] || return 1
  [ -f "$agents_md" ] || return 1

  {
    printf '<!-- GENERATED by scripts/setup-company.sh — do not edit by hand. -->\n'
    printf '<!-- Source: companies/%s/COMPANY.md + agents/%s/AGENTS.md -->\n\n' "$SLUG" "$slug"
    printf '# Shared company knowledge\n\n'
    cat "$company_md"
    printf '\n\n---\n\n# Your role\n\n'
    cat "$agents_md"
  } > "$out" 2>/dev/null || return 1

  return 0
}

build_agent_body() {
  local slug="$1" name="$2" role="$3" model="$4" caps="$5" reports_to="$6"
  local instructions=""
  # Only declare an instructionsFilePath when the file actually exists in the
  # squad home (checked on the HOST side; the container sees the same tree).
  if [ -n "$SQUAD_HOME_VAL" ] && [ -f "${SQUAD_HOME_VAL}/companies/${SLUG}/agents/${slug}/AGENTS.md" ]; then
    instructions="${INSTRUCTIONS_BASE}/${slug}/AGENTS.md"
    # Shared-knowledge injection (ADDITIVE, non-breaking): when the company
    # root COMPANY.md exists, compose COMPANY.md + the agent's AGENTS.md into a
    # generated instructions file and point the worker there instead — so every
    # worker also gets the company brain (people, roster, routing, conventions),
    # not just its own AGENTS.md. Falls back to the bare AGENTS.md path above
    # whenever COMPANY.md is missing or the compose write fails. The generated
    # file lives next to AGENTS.md in the squad home (gitignored); the container
    # sees it via the same companies bind mount.
    compose_company_instructions "$slug" && \
      instructions="${INSTRUCTIONS_BASE}/${slug}/INSTRUCTIONS.generated.md"
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
