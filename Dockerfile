# Production Dockerfile: AI agent war room
# Single container running 3 Telegram-facing Claude Code agents in tmux,
# served via ttyd for web browser access.
#
# Build:  docker build -t interactive-dev-team .
# Run:    docker run -d -p 7681:7681 --env-file .env interactive-dev-team

FROM node:22-slim

# --- system deps ---
RUN apt-get update && apt-get install -y --no-install-recommends \
      tmux \
      curl \
      git \
      ca-certificates \
      unzip \
    && rm -rf /var/lib/apt/lists/*

# --- install ttyd from GitHub releases (detect arch) ---
ARG TTYD_VERSION=1.7.7
RUN ARCH=$(dpkg --print-architecture) && \
    if [ "$ARCH" = "amd64" ]; then TTYD_ARCH="x86_64"; \
    elif [ "$ARCH" = "arm64" ]; then TTYD_ARCH="aarch64"; \
    else echo "Unsupported arch: $ARCH" && exit 1; fi && \
    curl -fSL "https://github.com/tsl0922/ttyd/releases/download/${TTYD_VERSION}/ttyd.${TTYD_ARCH}" \
      -o /usr/local/bin/ttyd && \
    chmod +x /usr/local/bin/ttyd

# --- install Claude Code CLI globally ---
RUN npm install -g @anthropic-ai/claude-code@latest

# --- create non-root user ---
# CRITICAL: Claude Code refuses --dangerously-skip-permissions when running as root
RUN useradd -m -s /bin/bash claude

# --- install Bun (required by Telegram plugin for grammy) ---
USER claude
RUN curl -fsSL https://bun.sh/install | bash
USER root

# --- pre-create state directories ---
RUN mkdir -p /home/claude/.claude/channels/telegram/inbox \
             /home/claude/.claude/channels/telegram/approved \
             /home/claude/.claude/plugins/data \
             /home/claude/.claude/plugins/cache \
    && chown -R claude:claude /home/claude/.claude

# --- environment ---
ENV CLAUDE_CODE_ENABLE_TELEMETRY=0
ENV TERM=xterm-256color
ENV LANG=C.utf8
ENV LC_ALL=C.utf8
ENV COLORTERM=truecolor
ENV FORCE_COLOR=3
ENV PATH="/home/claude/.bun/bin:${PATH}"

# --- working directory ---
WORKDIR /workspace
RUN chown claude:claude /workspace

# --- copy agents and launch script ---
COPY --chown=claude:claude agents/ /workspace/agents/
COPY --chown=claude:claude launch.sh /workspace/launch.sh
COPY --chown=claude:claude tmux.conf /home/claude/.tmux.conf
COPY --chown=claude:claude config/ /workspace/config/
RUN chmod +x /workspace/launch.sh

# --- switch to non-root user ---
USER claude

# --- pre-populate onboarding + trust state ---
# Skips first-run wizard and workspace trust dialog
RUN echo '{"hasCompletedOnboarding":true,"lastOnboardingVersion":"2.1.96","projects":{"/workspace":{"hasTrustDialogAccepted":true,"allowedTools":[],"hasCompletedProjectOnboarding":true}}}' > /home/claude/.claude.json

# --- verify installation ---
RUN claude --version

# --- expose ttyd web port ---
EXPOSE 7681

# --- health check: verify tmux war-room session exists ---
HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
  CMD tmux has-session -t war-room 2>/dev/null || exit 1

ENTRYPOINT ["./launch.sh"]
