#!/usr/bin/env bash
# =============================================================================
# entrypoint.admin.sh — platform ADMIN console agent entrypoint
#
# Starts a single-window tmux session holding ONE Claude admin agent running
# --dangerously-skip-permissions (locked decision 3), then idles as PID 1 so the
# container stays up (the tmux server detaches into the background).
#
# Window/session contract (FIX #3):
#   * SESSION  defaults to `war-room` and MUST equal admin-warroom2's
#     WARROOM2_TMUX_SESSION, or the dashboard tab `_stale`s.
#   * WINDOW is 1 and MUST equal `window` in the admin config/agents.json.
#   * base-index 1 comes from ~/.tmux.conf (copied by Dockerfile.admin), and is
#     ALSO asserted defensively here so the first window is window 1.
#
# The persona is provided OUT-OF-REPO by the operator seed at
# /srv/platform-admin/agents/admin/AGENTS.md (mounted via /srv/platform-admin;
# this script only REFERENCES it — it does NOT author the persona). If the
# persona file is absent the agent still starts (no --append-system-prompt-file).
# =============================================================================
set -euo pipefail

SESSION="${ADMIN_TMUX_SESSION:-war-room}"   # MUST match WARROOM2_TMUX_SESSION
WINDOW=1                                     # MUST match agents.json[].window
MODEL="${ADMIN_MODEL:-sonnet}"
PERSONA="${ADMIN_PERSONA_FILE:-/srv/platform-admin/agents/admin/AGENTS.md}"

cd /home/ravi/interactive-dev-team

# FIX #3: base-index 1 is inherited from ~/.tmux.conf, but assert it defensively
# so the first window is window 1 (matches agents.json window:1 + warroom2 attach).
tmux set -g base-index 1 2>/dev/null || true
tmux setw -g pane-base-index 1 2>/dev/null || true

# --- Persona artifacts (same set the squad bots get: SOUL/AGENTS/CLAUDE/...) --
# Squad agents auto-load their persona-dir CLAUDE.md because launch.sh cd's into
# that dir. The admin keeps cwd at the repo (so its relative squadctl/registry
# commands resolve), so we instead BRIDGE the persona into Claude's user-level
# memory: ~/.claude/CLAUDE.md @imports the persona-dir CLAUDE.md, which in turn
# @imports SOUL/AGENTS/RUNBOOK/registry (paths relative to the persona dir). Net
# effect is identical to a squad bot — all personal artifacts load every session.
PERSONA_DIR="$(dirname "$PERSONA")"
TEMPLATE_DIR="/home/ravi/interactive-dev-team/deploy/templates/admin-seed/admin"

# Self-seed: copy any MISSING persona file from the repo template. Non-destructive
# — an existing file (i.e. operator edits) is never overwritten. Makes a fresh
# recreate turnkey (SOUL.md lands automatically) and self-heals future additions.
mkdir -p "$PERSONA_DIR"
for f in SOUL AGENTS CLAUDE RUNBOOK registry; do
  if [ ! -f "$PERSONA_DIR/$f.md" ] && [ -f "$TEMPLATE_DIR/$f.md" ]; then
    cp "$TEMPLATE_DIR/$f.md" "$PERSONA_DIR/$f.md"
    echo "[admin] seeded persona file: $f.md"
  fi
done

# Upgrade guard: an existing install already has a persona CLAUDE.md from an
# OLDER template (before SOUL existed), so the non-destructive copy above skips
# it and it would never @import SOUL.md. Additively ensure the import is present
# — append-only, never rewrites or removes any other line.
if [ -f "$PERSONA_DIR/CLAUDE.md" ] && [ -f "$PERSONA_DIR/SOUL.md" ] \
   && ! grep -qF "@import SOUL.md" "$PERSONA_DIR/CLAUDE.md"; then
  printf '\n@import SOUL.md\n' >> "$PERSONA_DIR/CLAUDE.md"
  echo "[admin] added missing '@import SOUL.md' to $PERSONA_DIR/CLAUDE.md"
fi

# Bridge the persona into ~/.claude/CLAUDE.md WITHOUT clobbering anything the
# agent saved there (standing instructions persist across restarts in that file).
# Only prepends the @import line when it is not already present.
USER_CLAUDE="$HOME/.claude/CLAUDE.md"
IMPORT_LINE="@import $PERSONA_DIR/CLAUDE.md"
mkdir -p "$HOME/.claude"
if [ -f "$PERSONA_DIR/CLAUDE.md" ]; then
  if [ ! -f "$USER_CLAUDE" ] || ! grep -qF "$IMPORT_LINE" "$USER_CLAUDE" 2>/dev/null; then
    { echo "<!-- admin persona bridge (auto-managed by entrypoint.admin.sh; edits below are preserved) -->"
      echo "$IMPORT_LINE"
      echo ""
      [ -f "$USER_CLAUDE" ] && cat "$USER_CLAUDE"
    } > "$USER_CLAUDE.tmp" && mv "$USER_CLAUDE.tmp" "$USER_CLAUDE"
    echo "[admin] bridged persona into $USER_CLAUDE"
  else
    echo "[admin] persona bridge already present in $USER_CLAUDE"
  fi
fi

# Fallback: only when the persona-dir CLAUDE.md is absent (seed failed) do we use
# the old single-file system-prompt injection so the agent still boots with its
# rules. When CLAUDE.md is present, the bridge above is the loader (squad parity).
PERSONA_FLAG=""
if [ ! -f "$PERSONA_DIR/CLAUDE.md" ] && [ -f "$PERSONA" ]; then
  PERSONA_FLAG="--append-system-prompt-file $PERSONA"
  echo "[admin] FALLBACK: persona CLAUDE.md absent — using --append-system-prompt-file $PERSONA"
elif [ ! -f "$PERSONA_DIR/CLAUDE.md" ]; then
  echo "[admin] WARNING: no persona CLAUDE.md and no $PERSONA — starting without persona"
fi

# --- Telegram channel (optional; mirrors launch.sh) --------------------------
# When ADMIN_TELEGRAM_TOKEN is set, wire the official Telegram plugin scoped to
# this single admin agent. SECURITY: the admin is root-equivalent on the VM, so
# access is DM-only and ALLOW-LISTED to OPERATOR_TELEGRAM_ID — no groups, nobody
# else can command it. Token absent => CLI-only (today's behavior), no --channels.
CHANNELS_FLAG=""
STATE_DIR_EXPORT="# CLI-only: ADMIN_TELEGRAM_TOKEN unset — running without --channels"
if [ -n "${ADMIN_TELEGRAM_TOKEN:-}" ]; then
  TG_STATE_DIR="$HOME/.claude/channels/telegram-admin"
  SETTINGS_JSON="$HOME/.claude/settings.json"
  mkdir -p "$TG_STATE_DIR/inbox" "$TG_STATE_DIR/approved"

  # Token -> channel .env (0600), rewritten each boot from the env var.
  printf 'TELEGRAM_BOT_TOKEN=%s\n' "$ADMIN_TELEGRAM_TOKEN" > "$TG_STATE_DIR/.env"
  chmod 600 "$TG_STATE_DIR/.env"

  # DM-only allow-list of the operator; groups {} (no group routing for admin).
  cat > "$TG_STATE_DIR/access.json" <<ACCESSEOF
{
  "dmPolicy": "allowlist",
  "allowFrom": ["${OPERATOR_TELEGRAM_ID:-}"],
  "groups": {},
  "pending": {}
}
ACCESSEOF
  [ -n "${OPERATOR_TELEGRAM_ID:-}" ] \
    || echo "[admin] WARNING: OPERATOR_TELEGRAM_ID empty — allow-list empty; nobody can DM the admin"

  # Enable the plugin in settings.json (create-or-merge; python3 is in the image).
  python3 - "$SETTINGS_JSON" <<'PY'
import json, os, sys
p = sys.argv[1]
try:
    d = json.load(open(p))
except Exception:
    d = {}
d.setdefault("enabledPlugins", {})["telegram@claude-plugins-official"] = True
d["skipDangerousModePermissionPrompt"] = True
os.makedirs(os.path.dirname(p), exist_ok=True)
json.dump(d, open(p, "w"), indent=2)
PY

  # Install the plugin on first run (needs network; idempotent thereafter).
  if [ ! -d "$HOME/.claude/plugins/cache" ] || [ -z "$(ls -A "$HOME/.claude/plugins/cache" 2>/dev/null)" ]; then
    echo "[admin] Installing Telegram plugin (first run, ~20s)..."
    claude plugin marketplace add anthropics/claude-plugins-official 2>&1 || true
    claude plugin install telegram@claude-plugins-official 2>&1 \
      && echo "[admin] Telegram plugin installed" \
      || echo "[admin] WARNING: Telegram plugin install failed — admin may not connect to Telegram"
  fi

  CHANNELS_FLAG=" --channels plugin:telegram@claude-plugins-official"
  STATE_DIR_EXPORT="export TELEGRAM_STATE_DIR=${TG_STATE_DIR}"
  echo "[admin] Telegram channel enabled (DM-only; allow-list: ${OPERATOR_TELEGRAM_ID:-<empty>})"
fi

# A small restart loop (mirrors launch.sh resilience): if claude exits, restart
# it inside the same window rather than letting the tab go dead.
RUN_SCRIPT="$(mktemp /tmp/admin-run.XXXXXX.sh)"
cat > "$RUN_SCRIPT" <<EOF
#!/usr/bin/env bash
cd /home/ravi/interactive-dev-team
${STATE_DIR_EXPORT}
RESUME="--continue"
while true; do
  echo "[admin] Starting Claude Code (model: ${MODEL})\${RESUME:+ [resuming previous session]}..."
  START_TS=\$(date +%s)
  claude \$RESUME --dangerously-skip-permissions --model ${MODEL} ${PERSONA_FLAG}${CHANNELS_FLAG}
  RAN_FOR=\$(( \$(date +%s) - START_TS ))
  if [ "\$RAN_FOR" -lt 15 ]; then
    echo "[admin] exited after \${RAN_FOR}s — will start FRESH next round"
    RESUME=""
  else
    RESUME="--continue"
  fi
  echo "[admin] Claude Code exited. Restarting in 5s..."
  sleep 5
done
EOF
chmod +x "$RUN_SCRIPT"

# One window, base-1, named for the dashboard tab.
tmux new-session -d -s "$SESSION" -x 200 -y 50 -n admin "$RUN_SCRIPT"

# Confirm the first window really is window 1 (FIX #3, defensive).
if ! tmux list-windows -t "$SESSION" -F '#{window_index}' | grep -qx "$WINDOW"; then
  echo "[admin] WARNING: expected window $WINDOW in session $SESSION but it is absent" >&2
fi

echo "[admin] tmux session '$SESSION' window $WINDOW up; idling as PID 1."

# Keepalive: PID 1 must not exit (the tmux server detaches into the background).
exec tail -f /dev/null
