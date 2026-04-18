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

# Delegate to the image's original entrypoint with the original CMD
exec docker-entrypoint.sh "$@"
