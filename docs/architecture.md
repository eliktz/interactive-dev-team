# Architecture

This document describes the internal architecture of Interactive Dev Team -- how the
containers are structured, how data flows between components, and how the different
agent types interact.

## System Overview

```
+------------------------------------------------------------------+
|                        HOST MACHINE                               |
|                                                                   |
|  +------------------------------------------------------------+  |
|  |              Docker Compose Network                         |  |
|  |                                                             |  |
|  |  +---------------------------+   +----------------------+   |  |
|  |  |     war-room container    |   | paperclip container  |   |  |
|  |  |                           |   |                      |   |  |
|  |  |  ttyd (:7681) ---------->-|---|-> browser            |   |  |
|  |  |    |                      |   |                      |   |  |
|  |  |  tmux session "war-room"  |   |  Paperclip server    |   |  |
|  |  |  +-------+-------+-----+ |   |  (:3100)             |   |  |
|  |  |  | pane0 | pane1 |pane2| |   |    |                  |   |  |
|  |  |  |Captain| CEO   | UX  | |   |  PGlite (embedded)   |   |  |
|  |  |  |claude | claude |clau.| |   |    |                  |   |  |
|  |  |  +-------+-------+-----+ |   |  Workers:            |   |  |
|  |  |          |                |   |   PM, Finance,       |   |  |
|  |  |    Telegram plugin        |   |   Frontend, Backend, |   |  |
|  |  |    (grammy via Bun)       |   |   QA, UX Designer    |   |  |
|  |  +---------------------------+   +----------------------+   |  |
|  |          |           |                      |               |  |
|  +----------|-----------|----------------------|---------------+  |
|             |           |                      |                  |
|         :7681        Telegram              :3100                  |
|        (ttyd)        Bot API             (Paperclip)              |
+------------------------------------------------------------------+
```

## Data Flow

### Human-to-Agent (Telegram)

```
Human types message in Telegram group
        |
        v
Telegram Bot API delivers to bot webhook / polling
        |
        v
Claude Code Telegram plugin (grammy, runs via Bun)
        |
        v
Plugin writes message to channel inbox:
  ~/.claude/channels/telegram-{agent}/inbox/
        |
        v
Claude Code agent picks up message (stream-json input)
        |
        v
Agent processes with its CLAUDE.md persona prompt
        |
        v
Agent sends reply via Telegram plugin -> Telegram Bot API
        |
        v
Human sees reply in Telegram group
```

### Agent-to-Worker (Paperclip)

```
CEO agent receives task from human (via Telegram)
        |
        v
CEO creates Paperclip issue via API:
  POST http://paperclip:3100/api/companies/{id}/issues
        |
        v
Paperclip assigns to registered worker agent
        |
        v
Worker executes task (code, review, test, etc.)
        |
        v
Worker updates issue status via Paperclip API
        |
        v
CEO polls/checks task status
        |
        v
CEO reports results to Telegram group
```

## Container Internals: war-room

The `war-room` container is built from `node:22-slim` and includes:

### Installed Software

| Component | Purpose |
|-----------|---------|
| **tmux** | Terminal multiplexer -- runs 3 agent panes in one session |
| **ttyd** (v1.7.7) | Web-based terminal -- exposes tmux session to browsers on port 7681 |
| **Claude Code CLI** | `@anthropic-ai/claude-code@latest` -- the AI agent runtime |
| **Bun** | JavaScript runtime required by the Telegram plugin (grammy) |
| **git, curl** | System utilities |

### Startup Sequence (launch.sh)

1. Validate environment variables (API key or Bedrock, Telegram tokens)
2. Install Telegram plugin on first run (`claude plugin marketplace add` + `claude plugin install`)
3. Create per-agent state directories under `~/.claude/channels/telegram-{name}/`
4. Write each agent's Telegram bot token to its state directory `.env` file
5. Build Claude Code commands with per-agent model, persona prompt, and Telegram channel
6. Create tmux session `war-room` with 3 panes (one per agent)
7. Start ttyd bound to port 7681, attached to the tmux session
8. Wait on ttyd process (keeps container alive)

### Agent Process Details

Each agent runs as a Claude Code CLI process:

```bash
TELEGRAM_STATE_DIR=~/.claude/channels/telegram-{name} \
claude \
  --dangerously-skip-permissions \
  --model {model} \
  --channels plugin:telegram@claude-plugins-official \
  --input-format stream-json \
  --output-format stream-json \
  --verbose \
  -p '{system prompt from CLAUDE.md}'
```

A FIFO pipe (`/tmp/claude-stdin-{name}`) keeps stdin open so the process does not exit.

### User: claude (non-root)

The container runs as a non-root user `claude` (created during build). This is required
because Claude Code refuses `--dangerously-skip-permissions` when running as root.

### State Persistence

The Docker volume `war-room-state` is mounted at `/home/claude/.claude`, preserving:
- Telegram plugin cache
- Channel state (inbox, approved messages)
- Claude Code settings

## Container Internals: paperclip

The `paperclip` container runs the [Paperclip](https://github.com/paperclipai/paperclip)
control plane:

| Component | Detail |
|-----------|--------|
| **Server** | Paperclip application server on port 3100 |
| **Database** | PGlite (embedded PostgreSQL) -- no external DB needed |
| **Web UI** | Management interface at `:3100` |
| **API** | REST API at `:3100/api/` |
| **Health** | `GET /api/health` -- checked every 5s with 30s start period |

### State Persistence

The Docker volume `paperclip-data` is mounted at `/paperclip`, preserving the PGlite
database and application state.

## Networking

### Docker Compose Network

Both containers share the default Docker Compose network. This means:

- `war-room` can reach Paperclip at `http://paperclip:3100` (service name resolution)
- The `PAPERCLIP_URL` environment variable is set to `http://paperclip:3100` in the war-room container
- No need for host networking or explicit network configuration

### Exposed Ports

| Port | Container | Service | Access |
|------|-----------|---------|--------|
| `7681` (configurable via `TTYD_PORT`) | war-room | ttyd web terminal | Browser |
| `3100` (configurable via `PAPERCLIP_PORT`) | paperclip | Paperclip web UI + API | Browser / API |

### External Connections

| Direction | Protocol | Destination |
|-----------|----------|-------------|
| war-room -> outbound | HTTPS | Telegram Bot API (`api.telegram.org`) |
| war-room -> outbound | HTTPS | Anthropic API (`api.anthropic.com`) or AWS Bedrock |
| war-room -> internal | HTTP | Paperclip (`http://paperclip:3100`) |
| paperclip -> outbound | HTTPS | Anthropic API (for worker execution) |

## Agent Types

### Telegram Personas (war-room container)

These are the "face" of the system -- they interact with humans via Telegram.

| Agent | Telegram Behavior | Routing |
|-------|-------------------|---------|
| **Captain** | Sees ALL messages (privacy mode disabled). Routes to the correct agent. | Triage |
| **CEO** | Sees only @-mentioned messages. Delegates work to Paperclip workers. | Execution |
| **UX Designer** | Sees only @-mentioned messages. Reviews designs, guards UX quality. | Design |

Each persona has a `CLAUDE.md` file in `agents/{name}/` that defines:
- Identity and personality
- Channel behavior (when to respond, when to stay silent)
- Routing tables
- Paperclip API access patterns
- Quality standards and red lines

### Paperclip Workers (paperclip container)

These are backend agents managed by Paperclip. They do not have Telegram presence --
they execute tasks delegated by the CEO persona.

| Worker | Role | Adapter |
|--------|------|---------|
| Product Manager | Backlog, priorities, user stories | `claude_local` |
| Finance Officer | Budget, cost analysis, token monitoring | `claude_local` |
| Frontend Developer | Next.js, React, Tailwind, RTL | `claude_local` |
| Backend Developer | Supabase, AI SDK, APIs | `claude_local` |
| QA Lead | Testing, Playwright, release gates | `claude_local` |
| UX Designer | Figma, UX flows, design handoff | `claude_local` |

Workers are registered during `scripts/setup.sh` via the Paperclip REST API.

## Health Monitoring

The war-room container has a Docker health check:

```
HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3
  CMD tmux has-session -t war-room 2>/dev/null || exit 1
```

This verifies the tmux session is still running. If all 3 agent processes crash, the
health check will fail after 90 seconds (3 retries x 30s interval).

The Paperclip container health check hits `GET /api/health` every 5 seconds.

## Dependency Order

```
paperclip (starts first, must be healthy)
    |
    v
war-room (depends_on: paperclip with condition: service_healthy)
```

The war-room container waits for Paperclip to pass its health check before starting.
This ensures the Paperclip API is available when agents try to create issues or query
workers.
