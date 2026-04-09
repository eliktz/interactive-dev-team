# Interactive Dev Team

> Run an AI agent team with Telegram interface, powered by Claude Code and Paperclip

Interactive Dev Team is an open-source framework for running a team of AI agents that
collaborate via Telegram, managed through a Paperclip control plane, and observed through
a browser-based terminal. Think of it as a "war room" where AI personas handle product
management, development, design, and QA -- and you interact with them through a regular
Telegram group.

## Architecture Overview

```
                          YOU (Human)
                              |
                         Telegram App
                              |
               +--------------+--------------+
               |              |              |
          Captain (Bot)  CEO (Bot)     UX Designer (Bot)
          Triage/Route   Delegate/Run  Design/Review
               |              |              |
               +--------------+--------------+
                              |
                     Docker: war-room container
                   [tmux session + ttyd on :7681]
                   [3 Claude Code agent processes]
                              |
                     Docker network (internal)
                              |
                     Docker: paperclip container
                   [Control plane + Web UI on :3100]
                   [PGlite embedded database]
                              |
               +--------------+--------------+
               |         |         |         |
             PM       Frontend  Backend     QA
            Worker    Worker    Worker    Worker
                    (Paperclip managed)
```

## Quick Start

```bash
# 1. Clone the repo
git clone https://github.com/YOUR_ORG/interactive-dev-team.git
cd interactive-dev-team

# 2. Create 3 Telegram bots via @BotFather (see docs/telegram-setup.md)
#    You need: captain bot, CEO bot, UX designer bot

# 3. Configure environment
cp .env.example .env
# Edit .env -- fill in ANTHROPIC_API_KEY and the 3 Telegram bot tokens
# See docs/telegram-setup.md for how to get GONORTH_GROUP_ID

# 4. Run the setup script (clones Paperclip, registers company & agents)
bash scripts/setup.sh

# 5. Start the full stack
docker compose up -d
```

Open [http://localhost:7681](http://localhost:7681) to see the war room (tmux in your browser).
Open [http://localhost:3100](http://localhost:3100) to access the Paperclip management UI.

## What You Get

| Service | Port | Description |
|---------|------|-------------|
| **ttyd** | `:7681` | Browser-based terminal showing the tmux war room with all 3 agent panes |
| **Paperclip** | `:3100` | Control plane web UI for managing workers, tasks, and company state |
| **Telegram** | -- | 3 bots in your Telegram group that you chat with directly |

## Prerequisites

- **Docker** (with Compose v2) -- [Install Docker Desktop](https://docs.docker.com/get-docker/)
- **3 Telegram bot tokens** -- see [docs/telegram-setup.md](docs/telegram-setup.md)
- **LLM provider** -- one of:
  - Anthropic API key (`ANTHROPIC_API_KEY`)
  - AWS Bedrock credentials (`CLAUDE_CODE_USE_BEDROCK=1` + AWS creds)
- **git** (for cloning Paperclip during setup)

## Architecture

The system runs on three layers:

### Layer 1: Personas (Telegram-facing agents)

Three Claude Code processes, each with its own Telegram bot, running inside a single
Docker container in a tmux session:

| Agent | Role | Default Model |
|-------|------|---------------|
| **Captain** | Triage router and scrum master -- sees all messages, routes to the right agent | `sonnet` |
| **CEO** | Company operator -- delegates work to Paperclip workers, tracks progress | `opus` |
| **UX Designer** | Design reviewer -- audits UX, creates Figma specs, guards visual consistency | `sonnet` |

### Layer 2: Engine (Paperclip control plane)

[Paperclip](https://github.com/paperclipai/paperclip) is the worker management layer.
It runs as a separate container with an embedded PGlite database (no external Postgres
needed). The CEO persona delegates tasks to Paperclip workers, and Paperclip manages
execution, status tracking, and results.

### Layer 3: Workers (Paperclip-managed agents)

Paperclip manages a roster of specialist workers registered during setup:

- Product Manager
- Finance Officer
- Frontend Developer
- Backend Developer
- QA Lead
- UX Designer

These workers are created via the Paperclip API and execute tasks delegated by the
CEO persona.

For a deep dive, see [docs/architecture.md](docs/architecture.md).

## The Go-North Example

The repo ships with a complete company package called **Go-North** -- an AI-powered
relocation assistant for families moving to northern Israel. It serves as both a working
example and a template for creating your own company.

Go-North includes:
- Company definition (`companies/go-north/COMPANY.md`) with mission, tech stack, and quality standards
- Agent personas with full prompt engineering (Captain, CEO Yefet, UX Designer Hedva)
- A Paperclip worker roster (PM, Finance, Frontend, Backend, QA, UX)
- Hebrew-first, mobile-first, RTL-native design principles

You can use Go-North as-is or replace it with your own company. See
[docs/customization.md](docs/customization.md) for how to create your own.

## Customization

- Add new agent personas
- Create your own company package
- Change models per agent
- Switch to AWS Bedrock
- Add MCP servers

See [docs/customization.md](docs/customization.md).

## GCP Deployment

Deploy to a Google Cloud VM for ~$35-45/month. Step-by-step guide:
[docs/gcp-deployment.md](docs/gcp-deployment.md).

## Telegram Setup

Create bots, configure a group, get chat IDs:
[docs/telegram-setup.md](docs/telegram-setup.md).

## Environment Variables

| Variable | Required | Description |
|----------|----------|-------------|
| `ANTHROPIC_API_KEY` | Yes* | Anthropic API key |
| `CLAUDE_CODE_USE_BEDROCK` | Yes* | Set to `1` for AWS Bedrock (alternative to API key) |
| `AWS_ACCESS_KEY_ID` | If Bedrock | AWS access key |
| `AWS_SECRET_ACCESS_KEY` | If Bedrock | AWS secret key |
| `AWS_REGION` | If Bedrock | AWS region (e.g., `us-east-1`) |
| `CAPTAIN_TELEGRAM_TOKEN` | Yes | Telegram bot token for Captain |
| `CEO_GONORTH_TELEGRAM_TOKEN` | Yes | Telegram bot token for CEO |
| `UX_GONORTH_TELEGRAM_TOKEN` | Yes | Telegram bot token for UX Designer |
| `GONORTH_GROUP_ID` | Yes | Telegram group chat ID |
| `OPERATOR_TELEGRAM_ID` | No | Your personal Telegram user ID |
| `CAPTAIN_MODEL` | No | Model for Captain (default: `sonnet`) |
| `CEO_MODEL` | No | Model for CEO (default: `opus`) |
| `UX_MODEL` | No | Model for UX Designer (default: `sonnet`) |
| `TTYD_USERNAME` | No | Basic auth username for ttyd |
| `TTYD_PASSWORD` | No | Basic auth password for ttyd |
| `TTYD_PORT` | No | Host port for ttyd (default: `7681`) |
| `PAPERCLIP_PORT` | No | Host port for Paperclip (default: `3100`) |
| `PAPERCLIP_SOURCE` | No | Path to Paperclip source (default: `./paperclip`) |
| `OPENAI_API_KEY` | No | For Paperclip Codex adapter |

\* One of `ANTHROPIC_API_KEY` or `CLAUDE_CODE_USE_BEDROCK` is required.

## Project Structure

```
interactive-dev-team/
  agents/
    captain/CLAUDE.md        # Captain persona prompt
    ceo-gonorth/CLAUDE.md    # CEO persona prompt
    ux-gonorth/CLAUDE.md     # UX Designer persona prompt
  companies/
    go-north/
      COMPANY.md             # Company definition (agentcompanies/v1)
      .paperclip.yaml        # Paperclip worker roster
  scripts/
    setup.sh                 # One-time setup (clone Paperclip, register company)
  docs/
    architecture.md          # Detailed architecture
    customization.md         # How to customize
    gcp-deployment.md        # GCP deployment guide
    telegram-setup.md        # Telegram bot setup
  docker-compose.yml         # Full stack: war-room + Paperclip
  Dockerfile                 # War room container
  launch.sh                  # Container entrypoint (tmux + ttyd)
  .env.example               # Environment variable template
```

## License

MIT

## Links

- **Paperclip**: [https://github.com/paperclipai/paperclip](https://github.com/paperclipai/paperclip)
- **Claude Code**: [https://docs.anthropic.com/en/docs/claude-code](https://docs.anthropic.com/en/docs/claude-code)
- **ttyd**: [https://github.com/tsl0922/ttyd](https://github.com/tsl0922/ttyd)
