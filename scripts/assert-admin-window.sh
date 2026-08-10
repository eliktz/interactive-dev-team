#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# assert-admin-window.sh — static catch for the FIX #3 stale-tab class
#
# The platform-ADMIN dashboard tab attaches to `<WARROOM2_TMUX_SESSION>:<window>`
# where <window> is `window` in the admin config/agents.json. The admin agent
# runs in tmux window WINDOW set by deploy/admin/entrypoint.admin.sh (base-index
# 1 via tmux.conf). If those two integers DISAGREE, the tab can never attach and
# `_stale`s — and that only shows up in live E2E unless we catch it here.
#
# This script asserts: entrypoint WINDOW == agents.json[].window  for the admin
# agent (attach == "tmux"). It is part of the static-validation stage (plan §9)
# so the stale tab is caught BEFORE VM bring-up.
#
# Pure bash + grep/sed/awk (no jq dependency — runs in CI and on a bare box).
# Exit 0 = match; non-zero = mismatch / unparseable (with a clear message).
#
# Usage: scripts/assert-admin-window.sh
#        ENTRYPOINT=... AGENTS_JSON=... scripts/assert-admin-window.sh  (overrides)
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

ENTRYPOINT="${ENTRYPOINT:-$PROJECT_DIR/deploy/admin/entrypoint.admin.sh}"
AGENTS_JSON="${AGENTS_JSON:-$PROJECT_DIR/deploy/templates/admin-seed/config/agents.json}"

die() { printf 'assert-admin-window: error: %s\n' "$*" >&2; exit 1; }

[ -f "$ENTRYPOINT" ]  || die "entrypoint not found: $ENTRYPOINT"
[ -f "$AGENTS_JSON" ] || die "agents.json not found: $AGENTS_JSON"

# --- entrypoint WINDOW -------------------------------------------------------
# Match a bare `WINDOW=<int>` assignment (ignore comments / quoted prose).
entry_window="$(
  grep -E '^[[:space:]]*WINDOW=[0-9]+' "$ENTRYPOINT" \
    | head -1 \
    | sed -E 's/^[[:space:]]*WINDOW=([0-9]+).*/\1/'
)"
[ -n "${entry_window:-}" ] || die "could not parse a 'WINDOW=<int>' assignment in $ENTRYPOINT"

# --- agents.json window (for the tmux-attached admin agent) ------------------
# No jq: pull the integer value of the first "window": <int> key. The admin
# roster is a single tmux agent, so the first window key is the admin's.
json_window="$(
  tr -d '\n' < "$AGENTS_JSON" \
    | grep -oE '"window"[[:space:]]*:[[:space:]]*[0-9]+' \
    | head -1 \
    | sed -E 's/.*:[[:space:]]*([0-9]+)/\1/'
)"
[ -n "${json_window:-}" ] || die "could not parse a '\"window\": <int>' key in $AGENTS_JSON"

# --- assert ------------------------------------------------------------------
if [ "$entry_window" = "$json_window" ]; then
  printf 'assert-admin-window: OK — entrypoint WINDOW=%s == agents.json window=%s\n' \
    "$entry_window" "$json_window"
  exit 0
fi

printf 'assert-admin-window: MISMATCH — entrypoint WINDOW=%s but agents.json window=%s\n' \
  "$entry_window" "$json_window" >&2
printf '  the dashboard tab attaches to <session>:%s and would _stale.\n' "$json_window" >&2
printf '  fix: make %s WINDOW and %s window equal (FIX #3, plan §9).\n' \
  "$ENTRYPOINT" "$AGENTS_JSON" >&2
exit 1
