#!/usr/bin/env bash
# =============================================================================
# admin-host-build.sh — OUT-OF-BAND shared-image build helper (HOST-side)
#
# Run on the VM as `ravi` (NOT inside the admin container) to (re)build the
# shared warroom/*:latest images from the repo, so the admin agent's
# SQUADCTL_NO_BUILD=1 `up -d` / `squadctl new` / `squadctl upgrade` have images
# to start. Builds NEVER go through the admin socket-proxy (BUILD is denied
# there; the BuildKit session surface is fragile through any TCP proxy).
#
# This is the ONE thing the admin does NOT do through the proxy (plan §6.3):
# rebuild the images here on the host FIRST, then run `./squadctl upgrade <slug>`
# (which skips its own build stage under SQUADCTL_NO_BUILD).
#
# Usage:
#   deploy/admin/bin/admin-host-build.sh             # build all shared images
#   deploy/admin/bin/admin-host-build.sh --admin     # admin image only
#   deploy/admin/bin/admin-host-build.sh --squad     # squad images only
#
# Builds:
#   - warroom/war-room:latest, warroom/paperclip:latest, warroom/warroom2:latest
#     via the squad docker-compose.yml build stage.
#   - warroom/platform-admin:latest via deploy/admin/docker-compose.admin.yml.
#
# NEVER passes --remove-orphans; build does not touch running containers.
# =============================================================================
set -euo pipefail

# Repo root = two levels up from this script (deploy/admin/bin -> repo root).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"

SQUAD_COMPOSE="${REPO_ROOT}/docker-compose.yml"
ADMIN_COMPOSE="${REPO_ROOT}/deploy/admin/docker-compose.admin.yml"

build_squad=1
build_admin=1
case "${1:-}" in
  --admin) build_squad=0 ;;
  --squad) build_admin=0 ;;
  ""|--all) ;;
  *) echo "usage: $0 [--all|--admin|--squad]" >&2; exit 2 ;;
esac

if [ "$build_squad" -eq 1 ]; then
  echo "[admin-host-build] building shared squad images from ${SQUAD_COMPOSE}"
  # No project name needed for a pure build; images are tagged by the compose
  # `image:` keys (warroom/*:latest). NEVER --remove-orphans.
  docker compose -f "${SQUAD_COMPOSE}" build
fi

if [ "$build_admin" -eq 1 ]; then
  echo "[admin-host-build] building warroom/platform-admin:latest from ${ADMIN_COMPOSE}"
  docker compose -p platform-admin -f "${ADMIN_COMPOSE}" build platform-admin
fi

echo "[admin-host-build] done. Verify with: docker images | grep warroom/"
