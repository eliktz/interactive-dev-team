# Customization Guide

This guide covers how to extend Interactive Dev Team with new agent personas, custom
companies, different models, alternative LLM providers, and MCP servers.

## Adding a New Agent Persona

Agent personas are the Telegram-facing agents that run inside the war-room container.
Each agent is a Claude Code process with its own Telegram bot, persona prompt, and
model configuration.

### Step 1: Create the Persona Prompt

Create a directory and `CLAUDE.md` file for your new agent:

```bash
mkdir -p agents/my-agent
```

Create `agents/my-agent/CLAUDE.md` with your persona definition. Follow this structure:

```markdown
# Agent Name -- Role Title

## Identity
- **Name:** Agent Name
- **Role:** What this agent does
- **Style:** Communication style
- **Language:** Primary language(s)

## Channel Behavior
Describe when this agent should respond vs. stay silent.
- Does it see all messages (like Captain) or only @-mentions?
- What topics does it handle?

## How You Work
Step-by-step workflow for this agent's responsibilities.

## Paperclip Integration
- URL: $PAPERCLIP_URL
- Company ID: $PAPERCLIP_COMPANY_ID

## Red Lines
- What this agent must never do
```

Look at the existing agents in `agents/captain/CLAUDE.md`, `agents/ceo-gonorth/CLAUDE.md`,
or `agents/ux-gonorth/CLAUDE.md` for full examples.

### Step 2: Create a Telegram Bot

Create a new bot via [@BotFather](https://t.me/BotFather) on Telegram
(see [docs/telegram-setup.md](telegram-setup.md) for detailed steps).

Add the bot token to your `.env`:

```
MY_AGENT_TELEGRAM_TOKEN=1234567890:ABCdefGhIjKlMnOpQrStUvWxYz
```

### Step 3: Register in launch.sh

Open `launch.sh` and add your agent to the `AGENTS` array:

```bash
AGENTS=(
  "captain:CAPTAIN_TELEGRAM_TOKEN:${CAPTAIN_MODEL:-sonnet}"
  "ceo-gonorth:CEO_GONORTH_TELEGRAM_TOKEN:${CEO_MODEL:-opus}"
  "ux-gonorth:UX_GONORTH_TELEGRAM_TOKEN:${UX_MODEL:-sonnet}"
  "my-agent:MY_AGENT_TELEGRAM_TOKEN:${MY_AGENT_MODEL:-sonnet}"  # <-- add this
)
```

The format is `name:token_env_var:model`. The `name` must match the directory name
under `agents/`.

### Step 4: Add to docker-compose.yml

Pass the new token through as an environment variable in `docker-compose.yml`:

```yaml
war-room:
  environment:
    # ... existing vars ...
    MY_AGENT_TELEGRAM_TOKEN: ${MY_AGENT_TELEGRAM_TOKEN}
    MY_AGENT_MODEL: ${MY_AGENT_MODEL:-sonnet}
```

### Step 5: Rebuild and Restart

```bash
docker compose up -d --build
```

The tmux session will now have 4 panes (one per agent) arranged in a tiled layout.

## Creating Your Own Company

A "company" is a package that defines a business context, quality standards, and a
roster of Paperclip workers. The bundled Go-North company follows the `agentcompanies/v1`
schema.

### Step 1: Create the Company Directory

```bash
mkdir -p companies/my-company
```

### Step 2: Create COMPANY.md

Create `companies/my-company/COMPANY.md` following the `agentcompanies/v1` spec:

```markdown
---
schema: agentcompanies/v1
kind: company
slug: my-company
name: "My Company"
description: "What your company does"
version: 0.1.0
goals:
  - Goal 1
  - Goal 2
---

# My Company

## Mission
What the company is building and why.

## Quality Standards
- Standard 1
- Standard 2

## Tech Stack
- **Frontend**: Your framework
- **Backend**: Your backend
- **Infrastructure**: Your infra

## Agent Roster

| Slug | Role | Responsibility |
|------|------|----------------|
| dev-1 | Developer | What they do |
| qa-1 | QA | What they do |
```

### Step 3: Create .paperclip.yaml

Create `companies/my-company/.paperclip.yaml` to define the Paperclip worker roster.
This file is used by `scripts/setup.sh` to register workers in Paperclip.

### Step 4: Update setup.sh

Modify `scripts/setup.sh` to register your company instead of (or in addition to)
Go-North. The key sections to update are:

1. **Company registration** (section 6): Change the company name and description in
   the `POST /companies` call.

2. **Agent definitions** (section 7): Update the `AGENT_DEFS` and `AGENT_ORDER` arrays
   to match your company's worker roster:

```bash
declare -A AGENT_DEFS=(
  ["dev-1"]='{"name":"Developer 1","role":"engineer","title":"Developer","adapterType":"claude_local","adapterConfig":{"model":"claude-sonnet-4-6","dangerouslySkipPermissions":true}}'
  ["qa-1"]='{"name":"QA Engineer","role":"qa","title":"QA","adapterType":"claude_local","adapterConfig":{"model":"claude-sonnet-4-6","dangerouslySkipPermissions":true}}'
)

AGENT_ORDER=("dev-1" "qa-1")
```

### Step 5: Update Agent Personas

Update the CLAUDE.md files in `agents/` to reference your company instead of Go-North.
The CEO persona in particular needs to know the company context, team roster, tech
stack, and quality standards.

## Changing Models

Each Telegram-facing agent has a configurable model. Set these in your `.env` file:

```bash
# Captain uses Sonnet by default (fast triage/routing)
CAPTAIN_MODEL=sonnet

# CEO uses Opus by default (complex coordination, delegation)
CEO_MODEL=opus

# UX Designer uses Sonnet by default
UX_MODEL=sonnet
```

### Available Model Values

The model value is passed directly to Claude Code's `--model` flag. Common values:

| Value | Model | Best For |
|-------|-------|----------|
| `sonnet` | Claude Sonnet (latest) | Fast responses, triage, routing, design review |
| `opus` | Claude Opus (latest) | Complex reasoning, coordination, strategic decisions |
| `haiku` | Claude Haiku (latest) | Quick, cheap tasks, monitoring, simple Q&A |

You can also use specific model IDs like `claude-sonnet-4-6` or
`claude-opus-4-6` if you need a pinned version.

### Paperclip Worker Models

Worker models are configured in `scripts/setup.sh` in the `AGENT_DEFS` array.
Each worker's `adapterConfig.model` field controls which model it uses:

```bash
["frontend-dev"]='{"name":"Frontend Developer","role":"engineer","title":"Frontend Developer","adapterType":"claude_local","adapterConfig":{"model":"claude-sonnet-4-6","dangerouslySkipPermissions":true}}'
```

To change a worker's model, edit the `model` value in the JSON and re-run
`scripts/setup.sh`.

## Using AWS Bedrock

To use AWS Bedrock instead of the Anthropic API:

### Step 1: Configure Credentials

In your `.env` file, comment out `ANTHROPIC_API_KEY` and set Bedrock variables:

```bash
# ANTHROPIC_API_KEY=sk-ant-...        # Comment this out

CLAUDE_CODE_USE_BEDROCK=1
AWS_ACCESS_KEY_ID=AKIA...
AWS_SECRET_ACCESS_KEY=...
AWS_REGION=us-east-1
```

### Step 2: Verify IAM Permissions

Your AWS IAM user/role needs permissions to invoke Bedrock models. At minimum:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "bedrock:InvokeModel",
        "bedrock:InvokeModelWithResponseStream"
      ],
      "Resource": "arn:aws:bedrock:*::foundation-model/anthropic.*"
    }
  ]
}
```

### Step 3: Enable Models in Bedrock Console

In the AWS Console, go to Bedrock > Model access and request access to the
Anthropic Claude models you plan to use.

### Step 4: Rebuild

```bash
docker compose up -d --build
```

The `launch.sh` entrypoint checks for either `ANTHROPIC_API_KEY` or
`CLAUDE_CODE_USE_BEDROCK` -- if neither is set, the container will not start.

## Adding MCP Servers to Agents

MCP (Model Context Protocol) servers extend agent capabilities. For example, the
UX Designer agent can use a Figma MCP server to create and edit designs directly.

### Option 1: Per-Agent MCP via CLAUDE.md

You can instruct agents to use MCP tools in their persona prompts. Add instructions
in the agent's `CLAUDE.md`:

```markdown
## MCP Tools Available
- Use the Figma MCP to create and edit designs
- Use the GitHub MCP to create pull requests
```

### Option 2: Container-Level MCP

To make MCP servers available to all agents in the war-room container:

1. Add the MCP server package to the Dockerfile:

```dockerfile
# Install an MCP server globally
RUN npm install -g @anthropic-ai/mcp-server-example
```

2. Configure the MCP server in each agent's Claude Code command. Modify the
   `build_agent_cmd` function in `launch.sh`:

```bash
build_agent_cmd() {
  # ... existing code ...
  cmd+=" --mcp-server example:npx @anthropic-ai/mcp-server-example"
  # ...
}
```

### Option 3: External MCP Servers

For MCP servers that run as separate services (e.g., database access, custom APIs),
add them as additional Docker Compose services and configure networking:

```yaml
services:
  mcp-github:
    image: ghcr.io/example/mcp-github:latest
    environment:
      GITHUB_TOKEN: ${GITHUB_TOKEN}
```

Then reference them from the war-room container using Docker service DNS
(e.g., `http://mcp-github:3000`).

## Tips

- **Start small:** Add one agent at a time and verify it works before adding more.
- **Test locally:** Use `docker compose up` (without `-d`) to see all logs in your
  terminal during development.
- **Persona iteration:** You can edit `CLAUDE.md` files and rebuild without losing
  Paperclip state (it is on a separate volume).
- **Model cost awareness:** Opus is significantly more expensive than Sonnet. Use it
  only for agents that need complex reasoning (like the CEO). Use Haiku for
  monitoring-only agents.
