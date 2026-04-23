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

# Delegate to the image's original entrypoint with the original CMD
exec docker-entrypoint.sh "$@"
