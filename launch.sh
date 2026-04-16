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
# Auth comes from claude.ai OAuth (/login) stored in the war-room-state volume.
# ANTHROPIC_API_KEY is intentionally NOT required — it conflicts with OAuth tokens.
# Bedrock is an alternative provider that doesn't conflict.
if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
  echo "[war-room] WARNING: ANTHROPIC_API_KEY is set — this conflicts with claude.ai OAuth."
  echo "[war-room]          Unset it in docker-compose.yml to use claude.ai subscription."
fi

for token_var in CAPTAIN_TELEGRAM_TOKEN CEO_GONORTH_TELEGRAM_TOKEN UX_GONORTH_TELEGRAM_TOKEN; do
  if [ -z "${!token_var:-}" ]; then
    echo "[war-room] WARNING: $token_var not set — that agent's Telegram channel will fail"
  fi
done

echo "[war-room] Claude Code version: $(claude --version)"
echo "[war-room] Bun version: $(bun --version)"
echo "[war-room] Running as: $(whoami) (uid=$(id -u))"

# --- Clone project repo (Go-North) ---
PROJECT_DIR="/workspace/project"
# Allow any user to use this repo (important when shared volume is root-owned)
git config --global --add safe.directory "$PROJECT_DIR" 2>/dev/null || true
git config --global --add safe.directory "*" 2>/dev/null || true

if [ -n "${GONORTH_REPO_URL:-}" ]; then
  if [ -d "$PROJECT_DIR/.git" ]; then
    echo "[war-room] Project repo already cloned, pulling latest..."
    cd "$PROJECT_DIR" && git pull --ff-only 2>&1 || echo "[war-room] WARNING: git pull failed (non-fatal)"
    cd /workspace
  else
    echo "[war-room] Cloning project repo..."
    # Build clone URL with token auth if BITBUCKET_TOKEN is set
    CLONE_URL="$GONORTH_REPO_URL"
    if [ -n "${BITBUCKET_TOKEN:-}" ] && echo "$CLONE_URL" | grep -q "bitbucket.org"; then
      CLONE_URL=$(echo "$CLONE_URL" | sed "s|https://|https://x-token-auth:${BITBUCKET_TOKEN}@|")
    fi
    # Clone into a temp dir first (in case PROJECT_DIR is a non-empty volume mount)
    TMP_CLONE=$(mktemp -d)
    if git clone "$CLONE_URL" "$TMP_CLONE" 2>&1; then
      # Clear PROJECT_DIR contents (but keep the dir itself, since it's a mount point)
      find "$PROJECT_DIR" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true
      # Copy the clone (including .git) into PROJECT_DIR
      cp -rT "$TMP_CLONE" "$PROJECT_DIR"
      rm -rf "$TMP_CLONE"
    else
      echo "[war-room] WARNING: git clone failed (non-fatal)"
      rm -rf "$TMP_CLONE"
    fi
  fi

  # Configure git user for commits
  if [ -d "$PROJECT_DIR/.git" ]; then
    cd "$PROJECT_DIR"
    git config user.email "war-room@gonorth.ai"
    git config user.name "War Room Agent"
    # Set push URL with token so agents can push
    if [ -n "${BITBUCKET_TOKEN:-}" ] && echo "$GONORTH_REPO_URL" | grep -q "bitbucket.org"; then
      PUSH_URL=$(echo "$GONORTH_REPO_URL" | sed "s|https://|https://x-token-auth:${BITBUCKET_TOKEN}@|")
      git remote set-url origin "$PUSH_URL"
    fi
    cd /workspace
    echo "[war-room] Project repo ready at $PROJECT_DIR"
  fi
else
  echo "[war-room] GONORTH_REPO_URL not set — skipping project repo clone"
fi
export PROJECT_DIR

# --- Configure SSH deploy key (if mounted) ---
DEPLOY_KEY="$HOME/.ssh/deploy_key"
if [ -f "$DEPLOY_KEY" ] && [ -s "$DEPLOY_KEY" ]; then
  # Dockerfile pre-creates /home/claude/.ssh owned by claude. If Docker's mount
  # auto-created it as root instead, silently ignore the chmod (mount perms are already 700).
  mkdir -p "$HOME/.ssh" 2>/dev/null || true
  chmod 700 "$HOME/.ssh" 2>/dev/null || true
  # The deploy_key is bind-mounted :ro so chmod is a no-op / may fail — that's fine
  chmod 600 "$DEPLOY_KEY" 2>/dev/null || true
  # Create SSH config for the deploy host
  cat > "$HOME/.ssh/config" << SSHEOF
Host deploy-plesk
  HostName 34.165.203.65
  User gonorthdev
  IdentityFile $DEPLOY_KEY
  StrictHostKeyChecking no
SSHEOF
  chmod 600 "$HOME/.ssh/config"
  echo "[war-room] SSH deploy key configured"
else
  echo "[war-room] No SSH deploy key found — deploy to Plesk not available"
fi

# --- Override agent files from project repo ---
# If the project repo has ./agents/{name}/ directory, it FULLY REPLACES the
# baked-in war-room version. This prevents stale/orphaned files when the project
# repo uses a different file schema (e.g., monolithic CLAUDE.md vs split files).
#
# Safety: if the project repo has a legacy monolithic CLAUDE.md (no @import),
# the war room's SOUL.md/AGENTS.md/TOOLS.md are removed so they don't silently
# coexist with a monolith that ignores them.
if [ -d "$PROJECT_DIR/agents" ]; then
  for agent_dir in /workspace/agents/*/; do
    agent_name=$(basename "$agent_dir")
    project_agent_dir="$PROJECT_DIR/agents/${agent_name}"
    if [ -d "$project_agent_dir" ]; then
      # Remove ALL .md files from war-room version first (full replace, not merge)
      rm -f "${agent_dir}"*.md
      # Copy ALL .md files from project repo
      for md_file in "$project_agent_dir"/*.md; do
        [ -f "$md_file" ] || continue
        cp "$md_file" "${agent_dir}"
      done
      echo "[war-room] [$agent_name] agent files replaced from project repo"
    fi
  done
fi

# --- Override shared config from project repo ---
# Copy config/*.md files (paperclip.md, trello.md, etc.) from project repo
if [ -d "$PROJECT_DIR/config" ]; then
  mkdir -p /workspace/config
  for cfg_file in "$PROJECT_DIR/config"/*.md; do
    [ -f "$cfg_file" ] || continue
    cp "$cfg_file" /workspace/config/
  done
  echo "[war-room] Shared config files overridden from project repo"
fi

# --- Pre-accept API key dialog (only if API key is set) ---
CLAUDE_JSON="$HOME/.claude.json"
if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
  KEY_SUFFIX="${ANTHROPIC_API_KEY: -20}"
  if [ -f "$CLAUDE_JSON" ]; then
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

# --- Configure MCP servers ---
SETTINGS_JSON="$HOME/.claude/settings.json"
mkdir -p "$HOME/.claude"

# Build MCP config dynamically (env vars resolved at runtime)
MCP_CONFIG=$(node -e "
const config = { mcpServers: {} };

// Playwright browser (always available)
config.mcpServers.playwright = { url: 'http://playwright:8931/mcp' };

// Bitbucket Cloud (token OR username/password)
if (process.env.BITBUCKET_TOKEN || (process.env.BITBUCKET_USERNAME && process.env.BITBUCKET_PASSWORD)) {
  const bbEnv = { BITBUCKET_URL: process.env.BITBUCKET_URL || 'https://api.bitbucket.org/2.0' };
  if (process.env.BITBUCKET_TOKEN) {
    bbEnv.BITBUCKET_TOKEN = process.env.BITBUCKET_TOKEN;
  } else {
    bbEnv.BITBUCKET_USERNAME = process.env.BITBUCKET_USERNAME;
    bbEnv.BITBUCKET_PASSWORD = process.env.BITBUCKET_PASSWORD;
  }
  config.mcpServers.bitbucket = {
    command: 'npx',
    args: ['-y', 'bitbucket-mcp@latest'],
    env: bbEnv
  };
}

// Trello (if credentials provided)
if (process.env.TRELLO_API_KEY && process.env.TRELLO_API_TOKEN) {
  config.mcpServers.trello = {
    command: 'npx',
    args: ['-y', 'trello-mcp-server'],
    env: {
      TRELLO_API_KEY: process.env.TRELLO_API_KEY,
      TRELLO_API_TOKEN: process.env.TRELLO_API_TOKEN
    }
  };
}

console.log(JSON.stringify(config, null, 2));
")

if [ -f "$SETTINGS_JSON" ]; then
  TMP_SETTINGS=$(mktemp)
  node -e "
    const existing = JSON.parse(require('fs').readFileSync('$SETTINGS_JSON', 'utf8'));
    const mcp = JSON.parse(process.argv[1]);
    existing.mcpServers = { ...(existing.mcpServers || {}), ...(mcp.mcpServers || {}) };
    // Ensure critical settings survive across restarts
    existing.skipDangerousModePermissionPrompt = true;
    existing.enabledPlugins = { ...(existing.enabledPlugins || {}), 'telegram@claude-plugins-official': true };
    require('fs').writeFileSync('$TMP_SETTINGS', JSON.stringify(existing, null, 2));
  " "$MCP_CONFIG" && mv "$TMP_SETTINGS" "$SETTINGS_JSON"
  echo "[war-room] MCP servers merged into settings.json"
else
  # Fresh build — create settings.json with MCP + critical settings
  TMP_SETTINGS=$(mktemp)
  node -e "
    const mcp = JSON.parse(process.argv[1]);
    const settings = {
      ...mcp,
      skipDangerousModePermissionPrompt: true,
      enabledPlugins: { 'telegram@claude-plugins-official': true }
    };
    require('fs').writeFileSync('$TMP_SETTINGS', JSON.stringify(settings, null, 2));
  " "$MCP_CONFIG" && mv "$TMP_SETTINGS" "$SETTINGS_JSON"
  echo "[war-room] MCP settings.json created"
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
    # All agents see all messages (bot-to-bot @mentions don't work on Telegram,
    # so agents must read all messages and decide whether to respond based on
    # their CLAUDE.md instructions)
    require_mention="false"

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

# --- Generate per-agent start scripts ---
# These ensure agents always restart with the correct flags.
# If someone manually restarts an agent, they can just run ./start.sh
for agent_def in "${AGENTS[@]}"; do
  IFS=':' read -r name token_var model <<< "$agent_def"
  state_dir="$HOME/.claude/channels/telegram-${name}"
  start_script="/workspace/agents/${name}/start.sh"
  cat > "$start_script" << STARTEOF
#!/usr/bin/env bash
# Auto-generated start script for agent: ${name}
# Run this to restart the agent with the correct flags.
#
# SAFETY: refuses to start if another claude is already running in this agent's dir.
# This prevents the duplicate-process Telegram bot conflict that happened 2026-04-16.
AGENT_DIR=/workspace/agents/${name}
EXISTING=\$(pgrep -f "claude" -a 2>/dev/null | awk -v d="\$AGENT_DIR" '\$0 ~ d {print \$1}' | head -1)
if [ -n "\$EXISTING" ] && [ "\$EXISTING" != "\$\$" ]; then
  # Check if the existing claude has this dir as CWD
  for pid in \$(pgrep -x claude 2>/dev/null); do
    pid_cwd=\$(readlink /proc/\$pid/cwd 2>/dev/null)
    if [ "\$pid_cwd" = "\$AGENT_DIR" ]; then
      echo "[${name}] REFUSED: Claude is already running as PID \$pid in \$AGENT_DIR."
      echo "[${name}] To force restart: kill \$pid (start.sh loop will respawn it)."
      exit 1
    fi
  done
fi
cd "\$AGENT_DIR"
export TELEGRAM_STATE_DIR=${state_dir}
while true; do
  echo "[${name}] Starting Claude Code (model: ${model})..."
  claude --dangerously-skip-permissions --model ${model} --channels plugin:telegram@claude-plugins-official
  EXIT_CODE=\$?
  echo "[${name}] Claude Code exited (code \$EXIT_CODE). Restarting in 5s... (Ctrl+C to stop)"
  sleep 5
done
STARTEOF
  chmod +x "$start_script"
  echo "[war-room] [$name] start.sh created"
done

# --- Create tmux session with 3 agent panes ---
echo "[war-room] Creating tmux session '$SESSION'..."

# Each agent runs from its own directory so Claude Code auto-discovers CLAUDE.md.
# No --input/output-format stream-json (shows normal REPL UI).
# No -p flag (CLAUDE.md is picked up automatically).
# Channels plugin keeps the process alive as a long-running listener.
# Agents auto-restart on exit via start.sh wrapper.
PANE_LABELS=("Captain (${CAPTAIN_MODEL:-sonnet})" "CEO Yefet (${CEO_MODEL:-opus})" "UX Hedva (${UX_MODEL:-sonnet})")

# Create first agent's tmux session
IFS=':' read -r name token_var model <<< "${AGENTS[0]}"
tmux new-session -d -s "$SESSION" -x 200 -y 50 \
  "/workspace/agents/${name}/start.sh"
tmux set-option -t "$SESSION" remain-on-exit on

# Remaining agents get split panes
for i in 1 2; do
  IFS=':' read -r name token_var model <<< "${AGENTS[$i]}"
  tmux split-window -t "$SESSION" \
    "/workspace/agents/${name}/start.sh"
done
tmux select-layout -t "$SESSION" tiled

# Label panes (use pane IDs to avoid base-index issues from tmux.conf)
PANE_IDS=($(tmux list-panes -t "$SESSION" -F '#{pane_id}'))
for i in 0 1 2; do
  if [ -n "${PANE_IDS[$i]:-}" ] && [ -n "${PANE_LABELS[$i]:-}" ]; then
    tmux select-pane -t "${PANE_IDS[$i]}" -T "${PANE_LABELS[$i]}"
  fi
done

echo "[war-room] tmux session '$SESSION' created with ${#AGENTS[@]} panes"

# --- Start ttyd ---
TTYD_ARGS=(--writable --port 7681)

# Catppuccin Mocha theme for ttyd (matches .tmux.conf)
TTYD_ARGS+=(
  -t 'theme={"background":"#1e1e2e","foreground":"#cdd6f4","cursor":"#f5e0dc","cursorAccent":"#1e1e2e","selectionBackground":"#45475a","selectionForeground":"#cdd6f4","black":"#45475a","red":"#f38ba8","green":"#a6e3a1","yellow":"#f9e2af","blue":"#89b4fa","magenta":"#cba6f7","cyan":"#89dceb","white":"#bac2de","brightBlack":"#585b70","brightRed":"#f38ba8","brightGreen":"#a6e3a1","brightYellow":"#f9e2af","brightBlue":"#89b4fa","brightMagenta":"#cba6f7","brightCyan":"#89dceb","brightWhite":"#a6adc8"}'
  -t "fontFamily='Menlo','Monaco','Consolas','Liberation Mono','Courier New',monospace"
  -t 'fontSize=12'
  -t 'letterSpacing=0'
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

# --- Keep pane titles pinned (Claude Code overrides them via escape sequences) ---
(
  while true; do
    sleep 10
    PANE_IDS_BG=($(tmux list-panes -t "$SESSION" -F '#{pane_id}' 2>/dev/null)) || break
    for i in 0 1 2; do
      if [ -n "${PANE_IDS_BG[$i]:-}" ] && [ -n "${PANE_LABELS[$i]:-}" ]; then
        tmux select-pane -t "${PANE_IDS_BG[$i]}" -T "${PANE_LABELS[$i]}" 2>/dev/null
      fi
    done
  done
) &

# --- Keep container alive by waiting on ttyd ---
wait "$TTYD_PID"
