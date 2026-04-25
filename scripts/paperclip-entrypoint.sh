#!/bin/bash
# Paperclip container init wrapper.
#
# Purpose: ensure Playwright's Linux system deps are present before starting
# Paperclip. The upstream Paperclip image does not ship these libs, and QA
# Lead's qa:visual tier needs chromium to launch.
#
# This runs every container start. The apt install is idempotent — the ldconfig
# check skips re-installing when libs are already present, so subsequent starts
# are near-zero overhead.
#
# Wired via docker-compose.yml `entrypoint:` override; the image's CMD flows
# through as "$@" and is passed unchanged to docker-entrypoint.sh.

set -e

# M4 Step 0: ensure psql client present for operator-side debugging of team_memory.
# Embedded-postgres bundle ships only initdb/pg_ctl/postgres — no client.
if ! command -v psql >/dev/null 2>&1; then
  echo "[paperclip-init] Installing postgresql-client (psql)..."
  DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null 2>&1 || true
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      postgresql-client \
    >/tmp/apt-install-psql.log 2>&1 \
    || echo "[paperclip-init] psql install FAILED — see /tmp/apt-install-psql.log"
fi

if ! ldconfig -p 2>/dev/null | grep -q "libglib-2.0.so.0"; then
  echo "[paperclip-init] Installing Playwright Linux system deps (first boot or fresh container)..."
  DEBIAN_FRONTEND=noninteractive apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      libglib2.0-0 \
      libnss3 \
      libnspr4 \
      libatk1.0-0 \
      libatk-bridge2.0-0 \
      libcups2 \
      libxkbcommon0 \
      libatspi2.0-0 \
      libxcomposite1 \
      libxdamage1 \
      libxfixes3 \
      libxrandr2 \
      libgbm1 \
      libpango-1.0-0 \
      libcairo2 \
      libasound2 \
      libx11-xcb1 \
      libxcb1 \
      libxkbcommon-x11-0 \
      fonts-liberation \
    >/tmp/apt-install.log 2>&1 \
    || { echo "[paperclip-init] apt install FAILED — see /tmp/apt-install.log — continuing so Paperclip still starts"; tail -20 /tmp/apt-install.log || true; }
  echo "[paperclip-init] Playwright deps installed."
else
  echo "[paperclip-init] Playwright deps already present — skipping apt."
fi

# Self-heal /paperclip ownership before handing off.
#
# The upstream docker-entrypoint.sh only runs `chown -R node:node /paperclip`
# when it remaps the `node` user's UID (USER_UID/USER_GID env). On default-UID
# hosts (1000:1000) no remap happens, so root-owned files left in the volume
# stay unreadable by the server (which runs as `node` via gosu).
#
# This bites operators who run the paperclip CLI inside the container as root
# during onboarding — e.g. `sudo docker exec ... pnpm paperclipai onboard ...` —
# which writes instances/<name>/{.env, config.json, secrets/} as root. The
# server then crash-loops on every start with EACCES on .env (Agent JWT lookup
# in startup-banner.ts).
#
# Chowning only root-owned files keeps this cheap; nothing is touched on a
# clean instance.
if [ -d /paperclip ]; then
  if find /paperclip -uid 0 -print -quit 2>/dev/null | grep -q .; then
    echo "[paperclip-init] Self-healing: found root-owned files in /paperclip — chowning to uid 1000."
    find /paperclip -uid 0 -exec chown 1000:1000 {} + 2>/dev/null || true
  fi
fi

# M3 sidecars: launch mcp-team-memory + m3-ui in the background BEFORE handing
# off to Paperclip's entrypoint. Both are Node servers that listen on Docker-
# network-only ports (7077 + 3101) and read the same embedded PG.
# Token is rotated on first boot if missing; persists in /paperclip volume.
if [ -d /paperclip/mcp-team-memory ] && [ -f /paperclip/mcp-team-memory/server.js ]; then
  if [ ! -f /paperclip/mcp-team-memory/token ]; then
    head -c 24 /dev/urandom | xxd -p > /paperclip/mcp-team-memory/token 2>/dev/null \
      || (cat /proc/sys/kernel/random/uuid; cat /proc/sys/kernel/random/uuid) | tr -d '-\n' > /paperclip/mcp-team-memory/token
  fi
  (
    cd /paperclip/mcp-team-memory \
    && MCP_TEAM_MEMORY_TOKEN="$(cat token)" \
       MCP_TEAM_MEMORY_PG_URL="${MCP_TEAM_MEMORY_PG_URL:-postgres://paperclip:paperclip@127.0.0.1:54329/paperclip}" \
       NODE_PATH=/app/node_modules/.pnpm/pg@8.18.0/node_modules \
       nohup node server.js >>/tmp/mcp-team-memory.log 2>&1 &
  )
  echo "[paperclip-init] launched mcp-team-memory on :7077"
fi

if [ -d /paperclip/m3-ui ] && [ -f /paperclip/m3-ui/server.js ]; then
  (
    cd /paperclip/m3-ui \
    && M3_UI_PG_URL="${M3_UI_PG_URL:-postgres://paperclip:paperclip@127.0.0.1:54329/paperclip}" \
       M3_UI_ACTIVITY_NDJSON="${M3_UI_ACTIVITY_NDJSON:-/workspace/dev-activity-feed.ndjson}" \
       NODE_PATH=/app/node_modules/.pnpm/pg@8.18.0/node_modules \
       nohup node server.js >>/tmp/m3-ui.log 2>&1 &
  )
  echo "[paperclip-init] launched m3-ui on :3101"
fi

# Delegate to the image's original entrypoint with the original CMD
exec docker-entrypoint.sh "$@"
