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
                  [tmux session, observed via the
                  warroom2 dashboard (loopback port)]
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

# 2. (Optional) Create Telegram bot(s) via @BotFather (see docs/telegram-setup.md)
#    Agents run CLI-only without a token.

# 3. Onboard a squad — scaffolds /srv/squads/<slug>/ (env + config + persona seeds),
#    generates per-squad secrets, registers the Paperclip company, and brings the
#    stack up in the right order:
./squadctl new acme
```

See [REPRODUCING.md](REPRODUCING.md) for the full fresh-host walkthrough
(prerequisites, prompts, what to fill, and how to access the dashboard + Paperclip UI
through one SSH tunnel: `http://dash.acme.localhost:8800` /
`http://paperclip.acme.localhost:8800`).

> **Important:** Telegram channels require claude.ai authentication (Pro/Max/Team plan).
> After first startup, run `docker exec -it <slug>-war-room-1 claude` inside the
> container and type `/login` to authenticate. This is a one-time step — auth tokens
> persist across restarts via the Docker volume.

### Updating

```bash
git pull --ff-only && ./squadctl upgrade --all   # rebuilds once, rolls every squad
```

Do **not** use `docker compose restart` — it reuses the old image (and does not reload
env). Use `./squadctl apply <slug> <service>` for env reloads, and never pass
`--remove-orphans` (see [docs/MULTI_SQUAD.md](docs/MULTI_SQUAD.md)).

## Multiple squads (multi-tenancy)

One repo checkout runs N independent squads on the same host — one compose project per
squad, all per-squad state (env, config, personas, bus, secrets) in
`/srv/squads/<slug>/`, **outside the git tree**. `squadctl` is the front door:

```bash
./squadctl new acme            # onboard a squad end-to-end
./squadctl ls                  # fleet view
./squadctl status acme         # health + memory vs limits
./squadctl logs acme war-room  # follow logs
./squadctl apply acme war-room # reload env / recreate one service (--no-deps hardwired)
./squadctl backup acme         # squad home + volume snapshots
./squadctl destroy acme        # tear down (typed-slug confirmation)
```

- **Operator manual** (naming, URLs + the single SSH tunnel, day-2 runbook, capacity,
  hard warnings): [docs/MULTI_SQUAD.md](docs/MULTI_SQUAD.md)
- **Fresh-host bring-up:** [REPRODUCING.md](REPRODUCING.md)
- **Migrating a pre-multi-tenancy install:**
  [deploy/MIGRATION_GONORTH.md](deploy/MIGRATION_GONORTH.md)

## What You Get

| Service | Port | Description |
|---------|------|-------------|
| **warroom2 dashboard** | `127.0.0.1:<dash port>` | Tabbed browser dashboard: live agent terminals (PTY), bus feed, agent wizard |
| **Paperclip** | `127.0.0.1:<paperclip port>` | Control plane web UI for managing workers, tasks, and company state |
| **Telegram** | -- | The squad's bots in your Telegram group that you chat with directly |

All ports bind loopback only — access is through one SSH tunnel
(`http://dash.<slug>.localhost:8800`, see [docs/MULTI_SQUAD.md](docs/MULTI_SQUAD.md)).

## Prerequisites

- **Docker** (with Compose v2) -- [Install Docker Desktop](https://docs.docker.com/get-docker/)
- **Telegram bot token(s)** (optional -- agents run CLI-only without one) -- see
  [docs/telegram-setup.md](docs/telegram-setup.md)
- **LLM provider** -- one of:
  - claude.ai OAuth (default -- log in once after first boot)
  - Anthropic API key (`ANTHROPIC_API_KEY`)
  - AWS Bedrock credentials (`CLAUDE_CODE_USE_BEDROCK=1` + AWS creds)
- **git** (for cloning Paperclip during setup)

Full list: [REPRODUCING.md](REPRODUCING.md).

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

## Cloud Deployment

Deploy to any major cloud provider on a single VM for ~$30-45/month:

- **Google Cloud (GCP):** [docs/gcp-deployment.md](docs/gcp-deployment.md) — GCE e2-medium VM
- **Microsoft Azure:** [docs/azure-deployment.md](docs/azure-deployment.md) — Standard_B2s VM
- **Amazon Web Services (AWS):** [docs/aws-deployment.md](docs/aws-deployment.md) — EC2 t3.medium (includes Bedrock setup)

## Telegram Setup

Create bots, configure a group, get chat IDs:
[docs/telegram-setup.md](docs/telegram-setup.md).

## Environment Variables

Each squad is configured by its own env file at `/srv/squads/<slug>/.env` (rendered by
`squadctl new`, never inside the git tree). The authoritative, fully-commented variable
list is [`deploy/templates/squad.env.template`](deploy/templates/squad.env.template);
[.env.example](.env.example) is a short signpost. Highlights:

| Variable | Description |
|----------|-------------|
| `COMPOSE_PROJECT_NAME` / `SQUAD_HOME` | Squad identity — the slug derives everything |
| `SQUAD_DASH_PORT` / `SQUAD_PAPERCLIP_PORT` / `SQUAD_PLAYWRIGHT_PORT` | Loopback-only port block |
| `CAPTAIN_TELEGRAM_TOKEN` | Captain's bot token (other agents' tokens: `$SQUAD_HOME/private/agent-tokens.env`) |
| `SQUAD_TELEGRAM_GROUP_ID` | Telegram group chat ID (fillable later — see the runbook) |
| `OPERATOR_TELEGRAM_ID` | Your personal Telegram user ID |
| `WARROOM2_BASIC_AUTH_*` / `WARROOM2_ADMIN_TOKEN` | Dashboard auth (generated by squadctl) |
| `BETTER_AUTH_SECRET` / `PAPERCLIP_COMPANY_ID` | Per-squad Paperclip instance |
| `PROJECT_REPO_URL` / `BITBUCKET_TOKEN` | The project repo the agents work on |
| `WAR_ROOM_MEM` etc. | Per-service resource ceilings |

## Project Structure

```
interactive-dev-team/
  squadctl                   # Onboarding + day-2 CLI (new/ls/status/logs/apply/...)
  agents/
    captain/CLAUDE.md        # Captain persona prompt (example squad)
    ceo-gonorth/CLAUDE.md    # CEO persona prompt (example squad)
    ux-gonorth/CLAUDE.md     # UX Designer persona prompt (example squad)
  companies/
    go-north/
      COMPANY.md             # Company definition (agentcompanies/v1)
      .paperclip.yaml        # Paperclip worker roster
  deploy/
    templates/               # squad.env.template + config/persona seeds for squadctl new
    docker-proxy/            # Opt-in socket-proxy ACLs + empirical test result
    MIGRATION_GONORTH.md     # Migrating a pre-multi-tenancy install
  scripts/
    setup-company.sh         # Paperclip company/worker registration (run by squadctl)
    secret-scan-pre-push.sh  # Pre-push secret scanner (installed into project clones)
  docs/
    MULTI_SQUAD.md           # Multi-squad operator manual
    architecture.md          # Detailed architecture
    aws-deployment.md        # AWS deployment guide
    azure-deployment.md      # Azure deployment guide
    customization.md         # How to customize
    gcp-deployment.md        # GCP deployment guide
    telegram-setup.md        # Telegram bot setup
  REPRODUCING.md             # Fresh-host bring-up walkthrough
  docker-compose.yml         # Full stack template: war-room + warroom2 + Paperclip + playwright
  Dockerfile                 # War room container
  launch.sh                  # Container entrypoint (tmux + agents)
  .env.example               # Signpost — the real template is deploy/templates/squad.env.template
```

## Created by

- **Elik Katz** ([@eliktz](https://github.com/eliktz))
- **Ohad Levi** ([@ohadlevi22](https://github.com/ohadlevi22))

## License

MIT

## Links

- **Paperclip**: [https://github.com/paperclipai/paperclip](https://github.com/paperclipai/paperclip)
- **Claude Code**: [https://docs.anthropic.com/en/docs/claude-code](https://docs.anthropic.com/en/docs/claude-code)
