#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# launch.sh — War room container entrypoint
# Starts 3 Claude Code agent personas in tmux panes, served via ttyd.
# =============================================================================

SESSION="war-room"

# --- Graceful shutdown ---
cleanup() {
  echo "[war-room] Shutting down..."
  tmux kill-session -t "$SESSION" 2>/dev/null || true
  if [ -n "${TTYD_PID:-}" ]; then
    kill "$TTYD_PID" 2>/dev/null || true
  fi
  exit 0
}
trap cleanup SIGTERM SIGINT

# --- Validate required env vars ---
if [ -z "${ANTHROPIC_API_KEY:-}" ] && [ -z "${CLAUDE_CODE_USE_BEDROCK:-}" ]; then
  echo "[war-room] ERROR: ANTHROPIC_API_KEY or CLAUDE_CODE_USE_BEDROCK must be set"
  exit 1
fi

for token_var in CAPTAIN_TELEGRAM_TOKEN CEO_GONORTH_TELEGRAM_TOKEN UX_GONORTH_TELEGRAM_TOKEN; do
  if [ -z "${!token_var:-}" ]; then
    echo "[war-room] WARNING: $token_var not set — that agent's Telegram channel will fail"
  fi
done

echo "[war-room] Claude Code version: $(claude --version)"
echo "[war-room] Bun version: $(bun --version)"
echo "[war-room] Running as: $(whoami) (uid=$(id -u))"

# --- Pre-accept API key and permissions dialogs ---
# Claude Code v2.1.98+ shows interactive prompts for API key confirmation and
# dangerously-skip-permissions acceptance. Pre-populate .claude.json to skip them.
CLAUDE_JSON="$HOME/.claude.json"
if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
  KEY_SUFFIX="${ANTHROPIC_API_KEY: -20}"
  if [ -f "$CLAUDE_JSON" ]; then
    # Add customApiKeyResponses if not already present
    if ! grep -q "customApiKeyResponses" "$CLAUDE_JSON" 2>/dev/null; then
      TMP_JSON=$(mktemp)
      node -e "
        const d = JSON.parse(require('fs').readFileSync('$CLAUDE_JSON','utf8'));
        d.customApiKeyResponses = { approved: ['$KEY_SUFFIX'], rejected: [] };
        require('fs').writeFileSync('$TMP_JSON', JSON.stringify(d, null, 2));
      " && mv "$TMP_JSON" "$CLAUDE_JSON"
      echo "[war-room] Pre-accepted API key in .claude.json"
    fi
  fi
fi

# --- Install Telegram plugin on first run ---
if [ ! -d "$HOME/.claude/plugins/cache" ] || [ -z "$(ls -A "$HOME/.claude/plugins/cache" 2>/dev/null)" ]; then
  echo "[war-room] Installing Telegram plugin (first run, ~20s)..."
  claude plugin marketplace add anthropics/claude-plugins-official 2>&1 || true
  if claude plugin install telegram@claude-plugins-official 2>&1; then
    echo "[war-room] Telegram plugin installed successfully"
  else
    echo "[war-room] WARNING: Plugin install failed — agents may not connect to Telegram"
  fi
else
  echo "[war-room] Telegram plugin already installed (cache present)"
fi

# --- Agent definitions ---
# Format: name:token_var:model
AGENTS=(
  "captain:CAPTAIN_TELEGRAM_TOKEN:${CAPTAIN_MODEL:-sonnet}"
  "ceo-gonorth:CEO_GONORTH_TELEGRAM_TOKEN:${CEO_MODEL:-opus}"
  "ux-gonorth:UX_GONORTH_TELEGRAM_TOKEN:${UX_MODEL:-sonnet}"
)

# --- Set up Telegram state dirs and .env files for each agent ---
for agent_def in "${AGENTS[@]}"; do
  IFS=':' read -r name token_var model <<< "$agent_def"
  state_dir="$HOME/.claude/channels/telegram-${name}"
  mkdir -p "$state_dir/inbox" "$state_dir/approved"

  token_value="${!token_var:-}"
  if [ -n "$token_value" ]; then
    echo "TELEGRAM_BOT_TOKEN=${token_value}" > "$state_dir/.env"
    chmod 600 "$state_dir/.env"
    echo "[war-room] [$name] Telegram token written to $state_dir/.env"
  fi

  # Create access.json if missing (whitelists the group and operator for Telegram)
  if [ ! -f "$state_dir/access.json" ] && [ -n "${GONORTH_GROUP_ID:-}" ]; then
    # Captain sees all messages; other agents require @mention
    require_mention="true"
    if [ "$name" = "captain" ]; then
      require_mention="false"
    fi

    cat > "$state_dir/access.json" << ACCESSEOF
{
  "dmPolicy": "allowlist",
  "allowFrom": ["${OPERATOR_TELEGRAM_ID:-}"],
  "groups": {
    "-${GONORTH_GROUP_ID}": {
      "requireMention": ${require_mention},
      "allowFrom": []
    }
  },
  "pending": {}
}
ACCESSEOF
    echo "[war-room] [$name] access.json created (requireMention: $require_mention)"
  fi
done

# --- Build per-agent Claude command ---
build_agent_cmd() {
  local name="$1"
  local model="$2"
  local state_dir="$HOME/.claude/channels/telegram-${name}"
  local prompt_file="/workspace/agents/${name}/CLAUDE.md"
  local system_prompt=""

  if [ -f "$prompt_file" ]; then
    system_prompt=$(cat "$prompt_file")
  fi

  # Compose the command with TELEGRAM_STATE_DIR set inline
  local cmd="TELEGRAM_STATE_DIR=${state_dir} "
  cmd+="claude "
  cmd+="--dangerously-skip-permissions "
  cmd+="--model ${model} "
  cmd+="--channels plugin:telegram@claude-plugins-official "
  cmd+="--input-format stream-json "
  cmd+="--output-format stream-json "
  cmd+="--verbose"

  if [ -n "$system_prompt" ]; then
    cmd+=" -p '${system_prompt}'"
  fi

  # Wrap with FIFO stdin to keep the process alive
  local fifo="/tmp/claude-stdin-${name}"
  local full_cmd="mkfifo ${fifo} 2>/dev/null || true; "
  full_cmd+="echo '[war-room] [${name}] Starting (model=${model})...'; "
  full_cmd+="${cmd} < <(cat ${fifo} & wait)"

  echo "$full_cmd"
}

# --- Create tmux session with 3 agent panes ---
echo "[war-room] Creating tmux session '$SESSION'..."

# Create session with a persistent bash shell (not the agent command directly)
# This prevents panes from dying if the agent exits
# Note: tmux.conf sets base-index=1 and pane-base-index=1
tmux new-session -d -s "$SESSION" -x 200 -y 50 bash
tmux set-option -t "$SESSION" remain-on-exit on

# Create split panes (persistent bash shells)
tmux split-window -t "$SESSION" bash
tmux split-window -t "$SESSION" bash
tmux select-layout -t "$SESSION" tiled

# Label panes and send agent commands into each
# tmux settings (mouse, clipboard, theme) are loaded from ~/.tmux.conf
PANE_LABELS=("Captain (${CAPTAIN_MODEL:-sonnet})" "CEO Yefet (${CEO_MODEL:-opus})" "UX Hedva (${UX_MODEL:-sonnet})")
PANE_IDS=($(tmux list-panes -t "$SESSION" -F '#{pane_id}'))
for i in "${!PANE_LABELS[@]}"; do
  IFS=':' read -r name token_var model <<< "${AGENTS[$i]}"
  cmd=$(build_agent_cmd "$name" "$model")
  tmux select-pane -t "${PANE_IDS[$i]}" -T "${PANE_LABELS[$i]}"
  tmux send-keys -t "${PANE_IDS[$i]}" "$cmd" Enter
done

echo "[war-room] tmux session '$SESSION' created with ${#AGENTS[@]} panes"

# --- Start ttyd ---
TTYD_ARGS=(--writable --port 7681)

# Catppuccin Mocha theme for ttyd (matches .tmux.conf)
TTYD_ARGS+=(
  -t 'theme={"background":"#1e1e2e","foreground":"#cdd6f4","cursor":"#f5e0dc","cursorAccent":"#1e1e2e","selectionBackground":"#45475a","selectionForeground":"#cdd6f4","black":"#45475a","red":"#f38ba8","green":"#a6e3a1","yellow":"#f9e2af","blue":"#89b4fa","magenta":"#cba6f7","cyan":"#89dceb","white":"#bac2de","brightBlack":"#585b70","brightRed":"#f38ba8","brightGreen":"#a6e3a1","brightYellow":"#f9e2af","brightBlue":"#89b4fa","brightMagenta":"#cba6f7","brightCyan":"#89dceb","brightWhite":"#a6adc8"}'
  -t "fontFamily='JetBrains Mono','Fira Code','Cascadia Code','Menlo','Consolas',monospace"
  -t 'fontSize=14'
  -t 'disableLeaveAlert=true'
)

if [ -n "${TTYD_USERNAME:-}" ] && [ -n "${TTYD_PASSWORD:-}" ]; then
  TTYD_ARGS+=(-c "${TTYD_USERNAME}:${TTYD_PASSWORD}")
  echo "[war-room] ttyd basic auth enabled for user: $TTYD_USERNAME"
fi

echo "[war-room] Starting ttyd on port 7681..."
ttyd "${TTYD_ARGS[@]}" tmux attach-session -t "$SESSION" &
TTYD_PID=$!

echo "[war-room] ttyd started (pid=$TTYD_PID)"
echo "[war-room] War room is live at http://localhost:7681"

# --- Keep container alive by waiting on ttyd ---
wait "$TTYD_PID"
