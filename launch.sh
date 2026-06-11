#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# launch.sh — War room container entrypoint
# Starts one Claude Code agent persona per tmux window, driven by the canonical
# roster in /workspace/config/agents.json (attach="tmux" agents only; attach=
# "bus" agents like yefet run in other containers and are skipped here). The UI
# is served by the warroom2 container (PTY-attach over WebSocket); this
# container only runs tmux.
#
# If agents.json is missing or fails to parse, NO agents are launched: the
# container boots a single tmux window that displays the roster error (fail
# loud) and STAYS UP (this script is PID 1) so the operator can see why and
# fix the squad's config/agents.json, then recreate the container.
# =============================================================================

SESSION="war-room"
AGENTS_JSON="/workspace/config/agents.json"
TOKENS_ENV_FILE="/workspace/private/agent-tokens.env"

# --- Graceful shutdown ---
cleanup() {
  echo "[war-room] Shutting down..."
  tmux kill-session -t "$SESSION" 2>/dev/null || true
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

# --- Load the agent roster from agents.json ---
# The node one-liner emits one line per attach="tmux" agent, sorted by window:
#   id|persona_dir|window|label|model_env|model_default|token_env
# (model_env / token_env may be empty). Bus agents are skipped entirely.
# It validates: version pin (1), required fields, id slug format, integer
# window >= 1, no duplicate ids/windows, no "|" or newline inside fields,
# persona_dir shape (single path component, ^[a-z][a-z0-9._-]+$ — no slashes,
# so it can never escape /workspace/agents), and model_env/token_env being
# LEGAL SHELL VARIABLE NAMES (^[A-Z][A-Z0-9_]*$) when non-empty — bash 5.2
# ABORTS this PID-1 script on `${!name}` with an invalid name (macOS bash 3.2
# tolerates it, so only the container is affected).
# Any violation exits non-zero -> the fail-loud boot-error window below kicks
# in (no agents are launched until the roster is fixed).
ROSTER_PARSER='try{const fs=require("fs");const j=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));if(j.version!==1)throw new Error("unsupported agents.json version: "+JSON.stringify(j.version));const t=(j.agents||[]).filter(a=>a&&a.attach==="tmux").sort((a,b)=>a.window-b.window);if(t.length===0)throw new Error("no attach=tmux agents in roster");const ids=new Set();const wins=new Set();for(const a of t){for(const k of ["id","persona_dir","window","label","model_default"]){if(a[k]===undefined||a[k]===null||a[k]==="")throw new Error("tmux agent "+(a.id||"<?>")+" missing required field "+k)}if(!/^[a-z][a-z0-9-]{2,30}$/.test(a.id))throw new Error("invalid agent id: "+a.id);if(!Number.isInteger(a.window)||a.window<1)throw new Error("invalid window for agent "+a.id);if(typeof a.persona_dir!=="string"||!/^[a-z][a-z0-9._-]+$/.test(a.persona_dir))throw new Error("invalid persona_dir for agent "+a.id);if(a.model_env!==undefined&&a.model_env!==null&&a.model_env!==""&&!/^[A-Z][A-Z0-9_]*$/.test(String(a.model_env)))throw new Error("invalid model_env (not a legal shell variable name) for agent "+a.id);if(a.token_env!==undefined&&a.token_env!==null&&a.token_env!==""&&!/^[A-Z][A-Z0-9_]*$/.test(String(a.token_env)))throw new Error("invalid token_env (not a legal shell variable name) for agent "+a.id);if(ids.has(a.id))throw new Error("duplicate agent id: "+a.id);if(wins.has(a.window))throw new Error("duplicate window index: "+a.window);ids.add(a.id);wins.add(a.window);const f=[a.id,a.persona_dir,a.window,a.label,a.model_env||"",a.model_default,a.token_env||""].map(String);if(f.some(v=>v.includes("|")||v.includes("\n")))throw new Error("field contains | or newline on agent "+a.id);console.log(f.join("|"))}}catch(e){console.error("agents.json: "+(e&&e.message?e.message:String(e)));process.exit(1)}'

AGENT_IDS=()
AGENT_DIRS=()
AGENT_WINDOWS=()
AGENT_LABEL_BASES=()
AGENT_MODEL_ENVS=()
AGENT_MODEL_DEFAULTS=()
AGENT_TOKEN_ENVS=()
ROSTER_SOURCE="agents.json"
ROSTER_OUTPUT=""

if [ -f "$AGENTS_JSON" ]; then
  if ROSTER_OUTPUT=$(node -e "$ROSTER_PARSER" "$AGENTS_JSON" 2>&1); then
    while IFS='|' read -r f_id f_dir f_win f_label f_menv f_mdef f_tenv; do
      [ -n "$f_id" ] || continue
      AGENT_IDS+=("$f_id")
      AGENT_DIRS+=("$f_dir")
      AGENT_WINDOWS+=("$f_win")
      AGENT_LABEL_BASES+=("$f_label")
      AGENT_MODEL_ENVS+=("$f_menv")
      AGENT_MODEL_DEFAULTS+=("$f_mdef")
      AGENT_TOKEN_ENVS+=("$f_tenv")
    done <<< "$ROSTER_OUTPUT"
  fi
else
  ROSTER_OUTPUT="file not found: $AGENTS_JSON"
fi

# FAIL LOUD on a bad roster: no hardcoded fallback agents. The container
# still boots (PID 1 must not exit) into a single error window — see the
# tmux session creation below — so the operator can see what broke.
ROSTER_FAILED=0
if [ "${#AGENT_IDS[@]}" -eq 0 ]; then
  ROSTER_FAILED=1
  ROSTER_SOURCE="none-roster-error"
  echo "[war-room] =================================================================="
  echo "[war-room] ERROR: failed to load agent roster from $AGENTS_JSON"
  echo "[war-room]   $ROSTER_OUTPUT"
  echo "[war-room] NO agents will be started. The container stays up with an error"
  echo "[war-room] window so this is visible. Fix config/agents.json in the squad"
  echo "[war-room] instance dir, then recreate this container."
  echo "[war-room] =================================================================="
fi

# --- Belt-and-braces guard for the ${!var} indirections below ---
# bash 5.2 ABORTS the whole script (and this is PID 1) on ${!name} when the
# name is not a legal shell variable name. The roster parser above already
# rejects bad model_env/token_env values (triggering the fallback), but
# re-check here so NO code path — today's or a future edit's — can reach an
# indirection site with a name that would kill the container.
for i in "${!AGENT_IDS[@]}"; do
  if [ -n "${AGENT_MODEL_ENVS[$i]}" ] && ! [[ "${AGENT_MODEL_ENVS[$i]}" =~ ^[A-Z][A-Z0-9_]*$ ]]; then
    echo "[war-room] WARNING: [${AGENT_IDS[$i]}] invalid model_env name — ignoring, using model_default"
    AGENT_MODEL_ENVS[$i]=""
  fi
  if [ -n "${AGENT_TOKEN_ENVS[$i]}" ] && ! [[ "${AGENT_TOKEN_ENVS[$i]}" =~ ^[A-Z][A-Z0-9_]*$ ]]; then
    echo "[war-room] WARNING: [${AGENT_IDS[$i]}] invalid token_env name — ignoring, agent will be CLI-only"
    AGENT_TOKEN_ENVS[$i]=""
  fi
done

# --- Load wizard-managed agent tokens BEFORE any token resolution ---
# private/agent-tokens.env (gitignored, 0600) holds KEY=value lines for tokens
# added via the wizard. Compose-provided env vars keep working — both paths
# resolve through the same ${!token_env} indirection below. If a KEY exists in
# both, the file wins (loaded last). Exported so the values also reach child
# processes (start.sh, claude).
#
# DELIBERATELY NOT `. "$TOKENS_ENV_FILE"`: sourcing executes arbitrary shell,
# and under `set -e` a single malformed hand-edited line (a token value with
# a space, a stray word, a syntax error) would kill PID 1 at the NEXT
# container restart — possibly weeks after the bad edit. This strict parser
# cannot execute file content and cannot fail fatally: it exports clean
# KEY=value lines (value taken verbatim after the first '=', spaces and
# further '='s preserved) and skips anything else with a warning. Malformed
# line CONTENT is never echoed — it may hold a secret.
if [ -f "$TOKENS_ENV_FILE" ]; then
  tokens_lineno=0
  while IFS='=' read -r tk tv || [ -n "$tk" ]; do
    tokens_lineno=$((tokens_lineno + 1))
    # ltrim the key (matches `source` semantics for indented lines)
    tk="${tk#"${tk%%[![:space:]]*}"}"
    [ -z "$tk" ] && continue                  # blank line
    [ "${tk:0:1}" = "#" ] && continue         # comment
    if [[ "$tk" =~ ^[A-Z][A-Z0-9_]*$ ]]; then
      export "$tk=$tv"
    else
      echo "[war-room] WARNING: skipping malformed line $tokens_lineno in $TOKENS_ENV_FILE (content not printed)"
    fi
  done < "$TOKENS_ENV_FILE"
  unset tk tv tokens_lineno
  echo "[war-room] Loaded agent tokens from $TOKENS_ENV_FILE"
fi

# --- Resolve models and window labels ---
# Resolved model = ${!model_env:-model_default}; agents without a model_env
# just use model_default. Window label = "<label> (<resolved model>)".
AGENT_MODELS=()
PANE_LABELS=()
for i in "${!AGENT_IDS[@]}"; do
  model_env="${AGENT_MODEL_ENVS[$i]}"
  model="${AGENT_MODEL_DEFAULTS[$i]}"
  if [ -n "$model_env" ]; then
    model="${!model_env:-$model}"
  fi
  AGENT_MODELS+=("$model")
  PANE_LABELS+=("${AGENT_LABEL_BASES[$i]} (${model})")
done

# --- Token validation warnings (only for agents that DECLARE a token_env) ---
for i in "${!AGENT_IDS[@]}"; do
  token_var="${AGENT_TOKEN_ENVS[$i]}"
  if [ -n "$token_var" ] && [ -z "${!token_var:-}" ]; then
    echo "[war-room] WARNING: $token_var not set — that agent's Telegram channel will fail"
  fi
done

echo "[war-room] Agent roster ($ROSTER_SOURCE): ${AGENT_IDS[*]:-<none>}"
echo "[war-room] Claude Code version: $(claude --version)"
echo "[war-room] Bun version: $(bun --version)"
echo "[war-room] Running as: $(whoami) (uid=$(id -u))"

# --- Clone the squad's project repo ---
PROJECT_DIR="/workspace/project"
# Allow any user to use this repo (important when shared volume is root-owned)
git config --global --add safe.directory "$PROJECT_DIR" 2>/dev/null || true
git config --global --add safe.directory "*" 2>/dev/null || true

if [ -n "${PROJECT_REPO_URL:-}" ]; then
  if [ -d "$PROJECT_DIR/.git" ]; then
    echo "[war-room] Project repo already cloned, pulling latest..."
    cd "$PROJECT_DIR" && git pull --ff-only 2>&1 || echo "[war-room] WARNING: git pull failed (non-fatal)"
    cd /workspace
  else
    echo "[war-room] Cloning project repo..."
    # Build clone URL with token auth if BITBUCKET_TOKEN is set
    CLONE_URL="$PROJECT_REPO_URL"
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

  # Configure git user for commits (env-driven, neutral defaults)
  if [ -d "$PROJECT_DIR/.git" ]; then
    cd "$PROJECT_DIR"
    git config user.email "${GIT_IDENTITY_EMAIL:-war-room@squad.localhost}"
    git config user.name "${GIT_IDENTITY_NAME:-War Room Agent}"
    # Set push URL with token so agents can push
    if [ -n "${BITBUCKET_TOKEN:-}" ] && echo "$PROJECT_REPO_URL" | grep -q "bitbucket.org"; then
      PUSH_URL=$(echo "$PROJECT_REPO_URL" | sed "s|https://|https://x-token-auth:${BITBUCKET_TOKEN}@|")
      git remote set-url origin "$PUSH_URL"
    fi
    cd /workspace
    echo "[war-room] Project repo ready at $PROJECT_DIR"
  fi
else
  echo "[war-room] PROJECT_REPO_URL not set — skipping project repo clone"
fi
export PROJECT_DIR

# --- Install the secret-scan pre-push hook into the project clone ---
# Defense-in-depth for the one git remote agents CAN push to: generic secret
# patterns are rejected before they leave the container. The hook script ships
# with the platform (M5); guard on existence so boot works either way.
HOOK_SRC="/workspace/scripts/secret-scan-pre-push.sh"
if [ -d "$PROJECT_DIR/.git" ] && [ -f "$HOOK_SRC" ]; then
  mkdir -p "$PROJECT_DIR/.git/hooks"
  cp "$HOOK_SRC" "$PROJECT_DIR/.git/hooks/pre-push"
  chmod +x "$PROJECT_DIR/.git/hooks/pre-push"
  echo "[war-room] secret-scan pre-push hook installed into project clone"
fi

# --- Configure SSH deploy key (if mounted) ---
# The deploy target is env-driven (DEPLOY_SSH_HOST + DEPLOY_SSH_USER in the
# squad .env); the Host block is only written when BOTH are set, so squads
# without a deploy target never get a dangling SSH config entry.
DEPLOY_KEY="$HOME/.ssh/deploy_key"
if [ -f "$DEPLOY_KEY" ] && [ -s "$DEPLOY_KEY" ]; then
  # Dockerfile pre-creates /home/claude/.ssh owned by claude. If Docker's mount
  # auto-created it as root instead, silently ignore the chmod (mount perms are already 700).
  mkdir -p "$HOME/.ssh" 2>/dev/null || true
  chmod 700 "$HOME/.ssh" 2>/dev/null || true
  # The deploy_key is bind-mounted :ro so chmod is a no-op / may fail — that's fine
  chmod 600 "$DEPLOY_KEY" 2>/dev/null || true
  if [ -n "${DEPLOY_SSH_HOST:-}" ] && [ -n "${DEPLOY_SSH_USER:-}" ]; then
    # Create SSH config for the deploy host (alias used by the deploy script)
    cat > "$HOME/.ssh/config" << SSHEOF
Host deploy-plesk
  HostName ${DEPLOY_SSH_HOST}
  User ${DEPLOY_SSH_USER}
  IdentityFile $DEPLOY_KEY
  StrictHostKeyChecking no
SSHEOF
    chmod 600 "$HOME/.ssh/config"
    echo "[war-room] SSH deploy key + deploy-plesk host configured (${DEPLOY_SSH_USER}@${DEPLOY_SSH_HOST})"
  else
    echo "[war-room] Deploy key mounted but DEPLOY_SSH_HOST/DEPLOY_SSH_USER not set — skipping SSH config block"
  fi
else
  echo "[war-room] No SSH deploy key found — SSH deploy not available"
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

# --- Pre-trust every agent's project dir (dynamic, from the roster) ---
# The Dockerfile seeds trust only for the generic paths (/workspace,
# /workspace/project, the captain seed persona); a wizard-added agent
# would otherwise hit the trust dialog on first boot and hang the pane (the
# --dangerously-skip-permissions flag does NOT skip the workspace-trust
# dialog). Merge a trusted projects[] entry for /workspace, /workspace/project,
# and each roster persona dir into the existing .claude.json (preserving OAuth
# and all other state). Idempotent: only writes when something is missing.
if [ -f "$CLAUDE_JSON" ]; then
  TRUST_DIRS="/workspace /workspace/project"
  for dir in "${AGENT_DIRS[@]}"; do
    TRUST_DIRS="$TRUST_DIRS /workspace/agents/$dir"
  done
  TMP_TRUST=$(mktemp)
  if WR_TRUST_DIRS="$TRUST_DIRS" node -e '
    const fs = require("fs");
    const p = process.env.WR_CLAUDE_JSON;
    const d = JSON.parse(fs.readFileSync(p, "utf8"));
    d.projects = d.projects || {};
    let changed = false;
    for (const dir of process.env.WR_TRUST_DIRS.trim().split(/\s+/)) {
      const cur = d.projects[dir] || {};
      if (!cur.hasTrustDialogAccepted || !cur.hasCompletedProjectOnboarding) {
        d.projects[dir] = Object.assign({}, cur, {
          hasTrustDialogAccepted: true,
          hasCompletedProjectOnboarding: true,
        });
        changed = true;
      }
    }
    if (changed) fs.writeFileSync(process.env.WR_TMP, JSON.stringify(d, null, 2));
    process.exit(changed ? 0 : 3);
  ' WR_CLAUDE_JSON="$CLAUDE_JSON" WR_TMP="$TMP_TRUST"; then
    mv "$TMP_TRUST" "$CLAUDE_JSON"
    echo "[war-room] Pre-trusted ${#AGENT_IDS[@]} agent dir(s) in .claude.json"
  else
    rm -f "$TMP_TRUST"  # exit 3 = nothing to change; any other = leave file as-is
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

# --- Set up Telegram state dirs and .env files for each agent ---
# Only agents that DECLARE a token_env in agents.json get Telegram state;
# CLI-only agents (no token_env) skip this block entirely.
# State dirs are keyed on persona_dir (NOT agent id) so existing
# telegram-<persona_dir> state dirs survive roster edits that rename ids.
for i in "${!AGENT_IDS[@]}"; do
  id="${AGENT_IDS[$i]}"
  dir="${AGENT_DIRS[$i]}"
  token_var="${AGENT_TOKEN_ENVS[$i]}"
  [ -n "$token_var" ] || continue
  state_dir="$HOME/.claude/channels/telegram-${dir}"
  mkdir -p "$state_dir/inbox" "$state_dir/approved"

  token_value="${!token_var:-}"
  if [ -n "$token_value" ]; then
    echo "TELEGRAM_BOT_TOKEN=${token_value}" > "$state_dir/.env"
    chmod 600 "$state_dir/.env"
    echo "[war-room] [$id] Telegram token written to $state_dir/.env"
  fi

  # Create access.json if missing (whitelists the group and operator for
  # Telegram). ALWAYS created — when SQUAD_TELEGRAM_GROUP_ID is empty at boot
  # a minimal operator-DM-only file is written instead of skipping creation,
  # so filling the var later activates group routing with a plain
  # `squadctl apply <slug> war-room` (no hidden never-activates state).
  if [ ! -f "$state_dir/access.json" ]; then
    if [ -n "${SQUAD_TELEGRAM_GROUP_ID:-}" ]; then
      # All agents see all messages (bot-to-bot @mentions don't work on
      # Telegram, so agents must read all messages and decide whether to
      # respond based on their CLAUDE.md instructions)
      require_mention="false"
      # Normalize the chat id: Telegram supergroup ids are negative; accept
      # the value with or without the leading "-" in the squad .env.
      group_chat_id="-${SQUAD_TELEGRAM_GROUP_ID#-}"

      cat > "$state_dir/access.json" << ACCESSEOF
{
  "dmPolicy": "allowlist",
  "allowFrom": ["${OPERATOR_TELEGRAM_ID:-}"],
  "groups": {
    "${group_chat_id}": {
      "requireMention": ${require_mention},
      "allowFrom": []
    }
  },
  "pending": {}
}
ACCESSEOF
      echo "[war-room] [$id] access.json created (requireMention: $require_mention)"
    else
      cat > "$state_dir/access.json" << ACCESSEOF
{
  "dmPolicy": "allowlist",
  "allowFrom": ["${OPERATOR_TELEGRAM_ID:-}"],
  "groups": {},
  "pending": {}
}
ACCESSEOF
      echo "[war-room] [$id] access.json created (operator-DM-only — SQUAD_TELEGRAM_GROUP_ID empty; fill it and recreate to activate group routing)"
    fi
  fi
done

# --- Per-agent .claude/ dirs so each agent is its OWN project root ---
# Without this, Claude Code walks up from /workspace/agents/<id> looking
# for a .claude/ marker and finds /workspace/.claude/ (subagent defs),
# making /workspace the shared project root. All agents then read/write
# one shared MEMORY.md pool — Leo's identity claims contaminate Captain
# and Iris on session start. Fix: each agent has its own .claude/ that
# shadows the parent's; subagent defs stay shared via symlink.
for i in "${!AGENT_IDS[@]}"; do
  AGENT_CLAUDE="/workspace/agents/${AGENT_DIRS[$i]}/.claude"
  mkdir -p "$AGENT_CLAUDE"
  if [ ! -L "$AGENT_CLAUDE/agents" ] && [ -d /workspace/.claude/agents ]; then
    ln -sf /workspace/.claude/agents "$AGENT_CLAUDE/agents"
  fi
done
echo "[war-room] per-agent .claude/ dirs ensured (memory isolation)"

# --- Generate per-agent start scripts ---
# These ensure agents always restart with the correct flags.
# If someone manually restarts an agent, they can just run ./start.sh
# Token resolution: ${!token_env:-} — if EMPTY (no token_env declared, or the
# var is unset), the agent is CLI-only: claude runs WITHOUT --channels (the
# resume loop, pgrep safety check, and model flag are unchanged).
for i in "${!AGENT_IDS[@]}"; do
  id="${AGENT_IDS[$i]}"
  dir="${AGENT_DIRS[$i]}"
  model="${AGENT_MODELS[$i]}"
  token_var="${AGENT_TOKEN_ENVS[$i]}"
  state_dir="$HOME/.claude/channels/telegram-${dir}"

  token_value=""
  if [ -n "$token_var" ]; then
    token_value="${!token_var:-}"
  fi
  if [ -n "$token_value" ]; then
    channels_flag=" --channels plugin:telegram@claude-plugins-official"
    state_dir_export="export TELEGRAM_STATE_DIR=${state_dir}"
  else
    channels_flag=""
    state_dir_export="# CLI-only agent: no Telegram token resolved at launch — running without --channels"
  fi

  start_script="/workspace/agents/${dir}/start.sh"
  cat > "$start_script" << STARTEOF
#!/usr/bin/env bash
# Auto-generated start script for agent: ${id}
# Run this to restart the agent with the correct flags.
#
# SAFETY: refuses to start if another claude is already running in this agent's dir.
# This prevents the duplicate-process Telegram bot conflict that happened 2026-04-16.
AGENT_DIR=/workspace/agents/${dir}
EXISTING=\$(pgrep -f "claude" -a 2>/dev/null | awk -v d="\$AGENT_DIR" '\$0 ~ d {print \$1}' | head -1)
if [ -n "\$EXISTING" ] && [ "\$EXISTING" != "\$\$" ]; then
  # Check if the existing claude has this dir as CWD
  for pid in \$(pgrep -x claude 2>/dev/null); do
    pid_cwd=\$(readlink /proc/\$pid/cwd 2>/dev/null)
    if [ "\$pid_cwd" = "\$AGENT_DIR" ]; then
      echo "[${id}] REFUSED: Claude is already running as PID \$pid in \$AGENT_DIR."
      echo "[${id}] To force restart: kill \$pid (start.sh loop will respawn it)."
      exit 1
    fi
  done
fi
cd "\$AGENT_DIR"
${state_dir_export}
# Resume the previous conversation on restart so operator instructions given
# in-session survive respawns/crashes (transcripts persist in the war-room-state
# volume). Self-healing: if claude exits within 15s (nothing to continue, or a
# poisoned session crash-looping), drop --continue and start fresh next round.
RESUME="--continue"
while true; do
  echo "[${id}] Starting Claude Code (model: ${model})\${RESUME:+ [resuming previous session]}..."
  START_TS=\$(date +%s)
  claude \$RESUME --dangerously-skip-permissions --model ${model}${channels_flag}
  EXIT_CODE=\$?
  RAN_FOR=\$(( \$(date +%s) - START_TS ))
  if [ "\$RAN_FOR" -lt 15 ]; then
    echo "[${id}] exited after \${RAN_FOR}s (code \$EXIT_CODE) — will start FRESH next round"
    RESUME=""
  else
    RESUME="--continue"
  fi
  echo "[${id}] Claude Code exited (code \$EXIT_CODE). Restarting in 5s... (Ctrl+C to stop)"
  sleep 5
done
STARTEOF
  chmod +x "$start_script"
  echo "[war-room] [$id] start.sh created"
done

# --- Create tmux session with one window per roster agent ---
echo "[war-room] Creating tmux session '$SESSION'..."

# Each agent runs from its own directory so Claude Code auto-discovers CLAUDE.md.
# No --input/output-format stream-json (shows normal REPL UI).
# No -p flag (CLAUDE.md is picked up automatically).
# Channels plugin keeps the process alive as a long-running listener.
# Agents auto-restart on exit via start.sh wrapper.
#
# Each agent gets its OWN tmux window (not a split pane). This way each
# window's geometry is independent of the others, so war-room 2.0 (and any
# other client) can drive each tab at the full terminal width without the
# "tiled split smallest-client-wins" cramming that produced 34-col Leo and
# 172-col Iris under the old layout. Users navigate windows via Ctrl-b n/p
# (or click in the war-room 2.0 tab bar).
#
# Note: tmux.conf sets base-index 1 + pane-base-index 1. Window indices come
# straight from the agents.json "window" field (the wizard assigns max+1) and
# each window's lone pane is at .1 — warroom2 targets war-room:<window>.
NUM_AGENTS="${#AGENT_IDS[@]}"
if [ "$ROSTER_FAILED" -eq 1 ] || [ "$NUM_AGENTS" -eq 0 ]; then
  # FAIL-LOUD BOOT: the roster is missing/invalid and NO agents launch.
  # Boot a single tmux window that displays the error on a loop so the
  # operator sees WHY through the dashboard / `tmux attach`. The session must
  # exist (Dockerfile HEALTHCHECK + the keepalive loop below probe it) and
  # this script must NOT exit — it is PID 1.
  ERROR_FILE="/tmp/war-room-roster-error.txt"
  ERROR_SCRIPT="/tmp/war-room-roster-error.sh"
  {
    echo "=================================================================="
    echo " WAR-ROOM BOOT ERROR — agent roster failed to load"
    echo "=================================================================="
    echo
    echo " roster file: $AGENTS_JSON"
    echo " error:       $ROSTER_OUTPUT"
    echo
    echo " No agents were started. Fix config/agents.json in the squad"
    echo " instance dir (\$SQUAD_HOME/config/agents.json), then recreate"
    echo " this container (e.g. ./squadctl apply <slug> war-room)."
    echo "=================================================================="
  } > "$ERROR_FILE"
  cat > "$ERROR_SCRIPT" << 'ERREOF'
#!/usr/bin/env bash
while true; do
  clear
  cat /tmp/war-room-roster-error.txt
  sleep 30
done
ERREOF
  chmod +x "$ERROR_SCRIPT"
  tmux new-session -d -s "$SESSION" -x 200 -y 50 -n "ROSTER ERROR" "$ERROR_SCRIPT"
  tmux set-option -t "$SESSION" remain-on-exit on
  tmux set-option -t "$SESSION" renumber-windows off
  echo "[war-room] tmux session '$SESSION' created with the roster-error window ONLY (no agents)"
else
  first_win="${AGENT_WINDOWS[0]}"
  tmux new-session -d -s "$SESSION" -x 200 -y 50 \
    -n "${PANE_LABELS[0]}" \
    "/workspace/agents/${AGENT_DIRS[0]}/start.sh"
  tmux set-option -t "$SESSION" remain-on-exit on
  # Window indices are OWNED by agents.json — do NOT renumber, trust the file.
  # tmux.conf sets renumber-windows on globally (legacy), which would shift
  # indices if a window is ever killed and silently break the warroom2
  # tmux_target mapping (war-room:<window>), so force it off for this session.
  tmux set-option -t "$SESSION" renumber-windows off
  # new-session always creates the first window at base-index 1; if the roster's
  # first agent lives at a different index, move it there.
  if [ "$first_win" != "1" ]; then
    tmux move-window -s "$SESSION:1" -t "$SESSION:$first_win"
  fi
  tmux set-window-option -t "$SESSION:$first_win" aggressive-resize on

  # Remaining agents each get their own window at their agents.json index
  for (( i=1; i<NUM_AGENTS; i++ )); do
    win="${AGENT_WINDOWS[$i]}"
    tmux new-window -t "$SESSION:$win" -n "${PANE_LABELS[$i]}" \
      "/workspace/agents/${AGENT_DIRS[$i]}/start.sh"
    tmux set-window-option -t "$SESSION:$win" aggressive-resize on
  done

  # Pin pane titles (each window has one pane at pane-base-index 1)
  for i in "${!AGENT_IDS[@]}"; do
    tmux select-pane -t "$SESSION:${AGENT_WINDOWS[$i]}.1" -T "${PANE_LABELS[$i]}"
  done

  # Focus the first window (default attach target for `tmux attach`)
  tmux select-window -t "$SESSION:$first_win"

  echo "[war-room] tmux session '$SESSION' created with ${NUM_AGENTS} windows (one per agent, roster: $ROSTER_SOURCE)"
fi

# NOTE: the legacy ttyd web terminal (:7681) was retired on 2026-06-10 in favor
# of war-room 2.0 (the warroom2 container, PTY-attach over WebSocket). The UI is
# now served entirely by warroom2; this container just runs the agents in tmux.
# Break-glass access without warroom2:  docker exec <war-room> tmux attach -t war-room

# --- Keep pane titles pinned + keep the container alive ---
# This loop re-pins pane titles (Claude Code overrides them via escape
# sequences) AND serves as the container keepalive: ``tmux list-panes`` returns
# non-zero once the session is gone, so ``|| break`` ends the loop, the
# entrypoint returns, and the container stops cleanly. Titles are addressed by
# window index from agents.json (one pane per window since the 2026-06-08
# layout flip) so a dead/respawned pane in one window can't shift another
# agent's title; ``|| true`` keeps a transiently-missing pane from killing
# PID 1 under set -e.
echo "[war-room] agents live in tmux session '$SESSION'; UI served by warroom2"
while true; do
  sleep 10
  tmux list-panes -a -t "$SESSION" -F '#{pane_id}' >/dev/null 2>&1 || break
  for i in "${!AGENT_IDS[@]}"; do
    tmux select-pane -t "$SESSION:${AGENT_WINDOWS[$i]}.1" -T "${PANE_LABELS[$i]}" 2>/dev/null || true
  done
done
