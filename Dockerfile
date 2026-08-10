# Production Dockerfile: AI agent war room
# Single container running the squad's Claude Code agents in tmux (one window
# per agent, roster-driven from the squad's config/agents.json).
# The browser UI is served separately by the warroom2 container (PTY-attach
# over WebSocket); this container exposes no web port. (Legacy ttyd :7681
# retired 2026-06-10.)
#
# Build:  docker build -t interactive-dev-team .
# Run:    docker run -d --env-file .env interactive-dev-team

FROM node:22-slim

# --- system deps ---
RUN apt-get update && apt-get install -y --no-install-recommends \
      tmux \
      curl \
      git \
      ca-certificates \
      unzip \
      rsync \
      openssh-client \
    && rm -rf /var/lib/apt/lists/*

# --- (ttyd web terminal removed 2026-06-10; UI is now the warroom2 container) ---

# --- create non-root user ---
# CRITICAL: Claude Code refuses --dangerously-skip-permissions when running as root
RUN useradd -m -s /bin/bash claude

# --- install Bun (required by Telegram plugin for grammy) + Claude Code CLI ---
# Claude Code uses the native installer AS THE claude USER (~/.local/share/claude)
# so the auto-updater can write to its own install. A root-owned npm -g install
# pins the version forever: auto-update fails with EACCES for uid 1001 and the
# container silently falls behind (observed stuck at 2.1.112 while Fable 5
# required 2.1.170+).
USER claude
RUN curl -fsSL https://bun.sh/install | bash
RUN curl -fsSL https://claude.ai/install.sh | bash
USER root

# Keep `claude` resolvable from the original PATH (tmux server env, scripts)
RUN ln -sfn /home/claude/.local/bin/claude /usr/local/bin/claude

# --- pre-create state directories ---
RUN mkdir -p /home/claude/.claude/channels/telegram/inbox \
             /home/claude/.claude/channels/telegram/approved \
             /home/claude/.claude/plugins/data \
             /home/claude/.claude/plugins/cache \
             /home/claude/.ssh \
    && chown -R claude:claude /home/claude/.claude /home/claude/.ssh \
    && chmod 700 /home/claude/.ssh

# --- environment ---
ENV CLAUDE_CODE_ENABLE_TELEMETRY=0
ENV TERM=xterm-256color
ENV LANG=C.utf8
ENV LC_ALL=C.utf8
ENV COLORTERM=truecolor
ENV FORCE_COLOR=3
ENV PATH="/home/claude/.local/bin:/home/claude/.bun/bin:${PATH}"

# --- working directory ---
WORKDIR /workspace
RUN chown claude:claude /workspace

# --- waiting-notes dir (CAP-20): agents park durable wake-notes here; the
# platform's 10-minute host sweep execs their check_cmd and wakes them ---
RUN mkdir -p /workspace/.waiting && chown claude:claude /workspace/.waiting

# --- copy agents and launch script ---
COPY --chown=claude:claude agents/ /workspace/agents/
COPY --chown=claude:claude launch.sh /workspace/launch.sh
COPY --chown=claude:claude tmux.conf /home/claude/.tmux.conf
COPY --chown=claude:claude config/ /workspace/config/
COPY --chown=claude:claude scripts/ /workspace/scripts/
# Proven live-container fixes baked as image payloads. launch.sh applies them at
# boot because their runtime targets live on VOLUMES/bind-mounts, not image fs:
#   telegram-server-patched.ts -> plugins cache (war-room-state volume)
#   inbox-cleanup.js           -> run in place (7d telegram-inbox retention)
#   emit-task-event.sh         -> /workspace/config (squad bind-mount)
COPY --chown=claude:claude fixes/ /opt/warroom-fixes/
RUN chmod +x /workspace/launch.sh /workspace/scripts/*.sh

# --- Channel-plugin allowlist (CAP-12 slack recipe, piece 1 of 3) ---
# Without this file claude logs "Channel notifications skipped" and silently
# DROPS inbound channel events (outbound tools still work — deceptive). Lists
# BOTH the official telegram plugin and the hardened tlk-local slack-channel
# fork; the slack entry stays inert until that fork's marketplace is installed.
# NEVER use --dangerously-load-development-channels instead (crash-loops claude).
RUN mkdir -p /etc/claude-code && \
    printf '{ "allowedChannelPlugins": [\n    { "marketplace": "claude-plugins-official", "plugin": "telegram" },\n    { "marketplace": "tlk-local", "plugin": "slack-channel" } ] }\n' \
      > /etc/claude-code/managed-settings.json

# --- switch to non-root user ---
USER claude

# --- pre-populate onboarding + trust state ---
# Skips first-run wizard, workspace trust dialog, and pre-approves all tools
# to prevent the Telegram plugin's permission relay from prompting the operator.
# Only GENERIC paths are baked here (workspace, project clone, the captain
# seed persona) — launch.sh pre-trusts every roster persona dir dynamically
# at boot, so per-squad agents never need image changes.
RUN node -e ' \
  const tools = [ \
    "mcp__plugin_telegram_telegram__reply", \
    "mcp__plugin_telegram_telegram__download_attachment", \
    "Bash","Read","Write","Edit","Grep","Glob","WebFetch","WebSearch", \
    "mcp__bitbucket__*","mcp__trello__*","mcp__playwright__*" \
  ]; \
  const proj = (p) => ({ hasTrustDialogAccepted: true, allowedTools: tools, hasCompletedProjectOnboarding: true }); \
  const config = { \
    hasCompletedOnboarding: true, \
    lastOnboardingVersion: "2.1.96", \
    tipsHistory: { "new-user-warmup": 1, "plan-mode-for-complex-tasks": 2, "memory-command": 3, "theme-command": 4, "artifact-publish-plan": 6, "status-line": 6, "enter-to-steer-in-relatime": 6 }, \
    remoteControlUpsellSeenCount: 3, \
    projects: { \
      "/workspace": proj(), \
      "/workspace/project": proj(), \
      "/workspace/agents/captain": proj() \
    } \
  }; \
  require("fs").writeFileSync("/home/claude/.claude.json", JSON.stringify(config)); \
'

# --- verify installation ---
RUN claude --version

# --- no web port: UI served by the warroom2 container, not this one ---

# --- health check: verify tmux war-room session exists ---
HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
  CMD tmux has-session -t war-room 2>/dev/null || exit 1

ENTRYPOINT ["./launch.sh"]
