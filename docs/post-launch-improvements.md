# Post-Launch Improvements

Changes made after the initial GitHub release, based on real-world deployment
on an Azure VM with a third-party devops team.

## Cloud Deployment Docs

- Added **Azure deployment guide** (`docs/azure-deployment.md`) -- Standard_B2s VM,
  `az` CLI commands, NSG rules, managed disk setup
- Added **AWS deployment guide** (`docs/aws-deployment.md`) -- EC2 t3.medium, Security
  Groups, EBS volumes, and a dedicated **Bedrock section** with IAM Instance Profile
  (no static API keys needed on AWS)
- Added cleanup section to `docs/gcp-deployment.md` for consistency with Azure/AWS
- Expanded README with "Cloud Deployment" section linking all 3 guides and an
  "Updating" section warning about `docker compose restart` vs `--build`

## Critical Headless Startup Fixes

- **Removed `CI=1`** from Dockerfile -- this environment variable was disabling all
  colors and Unicode output in Claude Code, making the terminal monochrome
- **Added `FORCE_COLOR=3` and `COLORTERM=truecolor`** -- enables full truecolor output
  in Claude Code
- **Added `LANG=C.utf8` and `LC_ALL=C.utf8`** -- fixes Unicode rendering (Claude Code
  logo, status symbols like `⏵⏵`)
- **Pre-accept API key dialog** in `launch.sh` -- Claude Code v2.1.98+ shows an
  interactive prompt asking to confirm the API key. The launch script now writes
  `customApiKeyResponses` to `.claude.json` at startup to skip this
- **Auto-generate `access.json`** for Telegram on first startup -- whitelists the
  group (`GONORTH_GROUP_ID`) and operator (`OPERATOR_TELEGRAM_ID`). Captain gets
  `requireMention: false` (sees all messages), other agents require `@mention`

## Agent Launch Rewrite

The original agent launch used `--input-format stream-json`, `--output-format stream-json`,
a `-p` flag with the entire CLAUDE.md as a command-line argument, and a FIFO pipe to keep
the process alive. This caused multiple issues:

- `stream-json` output dumped raw JSON to the terminal instead of the normal Claude Code
  REPL UI (colored logo, status bar, interactive prompt)
- The `-p` flag with multi-line CLAUDE.md content broke bash quoting (special characters
  like single quotes, backticks, pipes in the prompt caused syntax errors)
- The FIFO approach was unnecessary since the Telegram channels plugin keeps the process
  alive as a long-running listener

**New approach:**

- Agents run from their own directory (`cd /workspace/agents/{name}`) so Claude Code
  auto-discovers `CLAUDE.md` -- no `-p` flag needed
- No `stream-json` flags -- shows the normal interactive REPL UI
- No FIFO wrapper -- channels plugin keeps the process alive
- Added `; bash` fallback so the pane stays alive if the agent exits
- Added `remain-on-exit on` so tmux panes survive agent crashes (shows the error
  instead of disappearing)

## tmux Theme and UX

- **Catppuccin Mocha theme** in `tmux.conf` -- self-contained, no plugin manager (TPM)
  or external dependencies needed
  - Blue accent on active pane borders, muted grey on inactive
  - Powerline-style status bar with session name, window, date/time, hostname
  - 50,000 line scrollback history
- **Pane labels** showing agent name and model in the pane border header:
  "Captain (sonnet)", "CEO Yefet (opus)", "UX Hedva (sonnet)"
- **Background title pinner** -- a loop that re-sets pane titles every 10 seconds,
  because Claude Code overrides pane titles via terminal escape sequences
- **Pane IDs** used instead of hardcoded indices to avoid issues with tmux's
  `base-index 1` setting
- **Mouse support** enabled with `Ctrl+b m` to toggle (off = free text selection
  in browser, on = pane switching)
- **Vi copy mode** -- `v` to start selection, `y` to yank, OSC 52 clipboard passthrough
- **Copy workflow**: `Ctrl+b z` to zoom a pane (full screen), select text, `Ctrl+b z`
  to unzoom. Or `Ctrl+b m` to toggle mouse off, select, toggle back on
- **ttyd font** -- Menlo/Monaco/Consolas font stack at size 12, with Catppuccin
  background color matching the tmux theme

## Deployment Lessons Learned

### Rebuild vs Restart

`docker compose restart` reuses the existing image and does NOT pick up code changes.
After pulling new code, always use:

```bash
git pull
docker compose up -d --build
```

### Telegram Channels Auth

The `--channels plugin:telegram` flag requires **claude.ai OAuth authentication**
(Pro/Max/Team plan), not just an `ANTHROPIC_API_KEY`. After first startup:

```bash
docker exec -it <war-room-container> claude
# Type: /login
# Follow the URL in your browser to authenticate
# Type: /exit
```

Auth tokens persist in the `war-room-state` Docker volume and survive rebuilds
(unless `docker compose down -v` deletes the volume).

### Paperclip Deployment Mode

Paperclip's `local_trusted` mode requires binding to `127.0.0.1` (loopback only),
which is incompatible with Docker's `0.0.0.0` binding needed for inter-container
networking. Use `authenticated` mode for Docker deployments. The setup script
creates the company and agents via the authenticated API with proper session cookies.

### Docker Volume Persistence

Auth tokens, Telegram state, and Paperclip data are stored in Docker volumes:
- `war-room-state` -- Claude Code auth, plugin cache, channel state
- `paperclip-data` -- company, agents, database

These persist across `docker compose up -d --build` but are deleted by
`docker compose down -v`. Never use `-v` unless you intend a full reset.

## Paperclip Agent Personality Fix

- **Problem**: All 6 Paperclip agents were registered with identical generic payloads
  (name, role, model only). The unique `AGENTS.md` personality files existed in the repo
  but were never passed to Paperclip during setup.
- **Root cause**: `setup.sh` hardcoded bare `AGENT_DEFS` without reading `AGENTS.md`
  content. Paperclip's `instructionsFilePath` adapter config was never set.
  `.paperclip.yaml` was declared but never consumed.
- **Fix (Option A — Volume-mount + instructionsFilePath)**:
  - `docker-compose.yml`: Added bind-mount `./companies:/paperclip/companies:ro` to
    make `AGENTS.md` files accessible inside the Paperclip container
  - `setup.sh`: Replaced static `AGENT_DEFS` with `build_agent_body()` function that
    generates JSON payloads including `instructionsFilePath`, `capabilities`, and
    `reportsTo` per agent. PM is created first, its ID passed to subsequent agents
  - `.paperclip.yaml`: Added `instructionsFilePath` and `reportsTo` per agent
- **Deployment mode**: Changed from `local_trusted` (crashes with Docker's `0.0.0.0`
  binding) to `authenticated` mode with `BETTER_AUTH_SECRET` env var
- **Bootstrap**: First user signed up via `/api/auth/sign-up/email` must be promoted
  to instance admin via the embedded PGlite database (user: `paperclip`, password:
  `paperclip`, database: `paperclip`, port: 54329) before they can create companies

## OAuth vs API Key Auth

- **Problem**: Setting `ANTHROPIC_API_KEY` in the war-room container alongside a
  claude.ai OAuth token causes an auth conflict warning and breaks Telegram channels
- **Fix**: Removed `ANTHROPIC_API_KEY` from the war-room service in `docker-compose.yml`.
  War-room agents use claude.ai OAuth exclusively (via `/login` in each agent pane).
  Paperclip still uses `ANTHROPIC_API_KEY` for its own Claude adapter.
- **After every rebuild**: Open ttyd and run `/login` in each agent pane to restore
  the OAuth token. Auth persists in the `war-room-state` Docker volume.

## Agent Tooling (MCP Servers)

Three MCP servers are configured dynamically in `launch.sh` at container startup:

### Playwright MCP (Browser Automation)

- **Service**: Dedicated `playwright` container in `docker-compose.yml` using the
  official Microsoft image (`mcr.microsoft.com/playwright/mcp`)
- **Access**: Headless Chromium on port 8931, accessible at `http://playwright:8931/mcp`
  from war-room and paperclip containers
- **Purpose**: All agents can navigate, screenshot, click, and inspect the Go-North
  web app. Uses accessibility-tree approach (token-efficient, no vision model needed)
- **Config**: Always enabled, no credentials needed

### Bitbucket Cloud MCP (Code Management)

- **Package**: `bitbucket-mcp` (npm, MatanYemini) -- supports Cloud and Server
- **Auth**: Token (`BITBUCKET_TOKEN`) OR username/password (`BITBUCKET_USERNAME` +
  `BITBUCKET_PASSWORD`). Token takes precedence if both are set.
- **Config**: Conditionally enabled in `launch.sh` when credentials are present
- **Setup**: Add credentials to `.env` on the deployment machine (never committed)

### Trello MCP (Task Management)

- **Package**: `trello-mcp-server` (npm)
- **Auth**: `TRELLO_API_KEY` + `TRELLO_API_TOKEN`
- **Token generation**: Visit
  `https://trello.com/1/authorize?key=YOUR_KEY&scope=read,write&expiration=never&response_type=token&name=WarRoom`
- **Config**: Conditionally enabled in `launch.sh` when credentials are present
- **Setup**: Add credentials to `.env` on the deployment machine (never committed)

### MCP Config Architecture

- `config/mcp-settings.json` contains static fallback (Playwright only)
- `launch.sh` builds the full MCP config dynamically at container startup using
  Node.js, resolving env vars at runtime. Writes to `~/.claude/settings.json`
- Bitbucket and Trello are only added when their env vars are set

## Figma Removal

- Removed all 20 Figma references across 6 agent configuration files
- Replaced with browser-based visual review using Playwright MCP + markdown design specs
- UX Designer (Hedva) now uses Playwright to screenshot the app and annotate
  issues in markdown instead of creating Figma mockups
- Files updated: `agents/captain/CLAUDE.md`, `agents/ceo-gonorth/CLAUDE.md`,
  `agents/ux-gonorth/CLAUDE.md`, `companies/go-north/COMPANY.md`,
  `companies/go-north/agents/frontend-dev/AGENTS.md`,
  `companies/go-north/agents/ux-designer/AGENTS.md`

## ttyd Password

- Avoid `#` characters in `TTYD_PASSWORD` -- they can cause issues with browser
  Basic Auth dialogs and URL encoding. Use alphanumeric passwords.
