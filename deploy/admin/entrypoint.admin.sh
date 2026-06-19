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

# Build the persona flag only when the seed file is present.
PERSONA_FLAG=""
if [ -f "$PERSONA" ]; then
  PERSONA_FLAG="--append-system-prompt-file $PERSONA"
  echo "[admin] using persona: $PERSONA"
else
  echo "[admin] WARNING: persona file not found at $PERSONA — starting without it"
fi

# A small restart loop (mirrors launch.sh resilience): if claude exits, restart
# it inside the same window rather than letting the tab go dead.
RUN_SCRIPT="$(mktemp /tmp/admin-run.XXXXXX.sh)"
cat > "$RUN_SCRIPT" <<EOF
#!/usr/bin/env bash
cd /home/ravi/interactive-dev-team
RESUME="--continue"
while true; do
  echo "[admin] Starting Claude Code (model: ${MODEL})\${RESUME:+ [resuming previous session]}..."
  START_TS=\$(date +%s)
  claude \$RESUME --dangerously-skip-permissions --model ${MODEL} ${PERSONA_FLAG}
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
