# Paperclip Integration

## Connection
- **Internal URL**: http://paperclip:3100 (from inside Docker network)
- **External URL**: https://paperclip.tlk.solutions (from browser/external)
- **Company ID**: a951bb35-24a9-412a-bbcc-629c5acae619
- **Company slug**: GON (issue prefix: GON-1, GON-2, ...)

## Authentication

Paperclip requires session auth with Host and Origin headers. Run this once per session:

```bash
# Sign in and capture session token
PAPERCLIP_SESSION=$(curl -v -s -X POST \
  -H "Host: paperclip.tlk.solutions" \
  http://paperclip:3100/api/auth/sign-in/email \
  -H "Content-Type: application/json" \
  -d '{"email":"admin@gonorth.dev","password":"GoNorth2026!"}' \
  2>&1 | grep -oi "session_token=[^;]*" | head -1)

# Reusable curl prefix for all Paperclip API calls
PAPERCLIP_CURL="curl -s -H 'Host: paperclip.tlk.solutions' -H 'Origin: https://paperclip.tlk.solutions' -H 'Cookie: __Secure-better-auth.${PAPERCLIP_SESSION}'"
```

**Why the workaround?** The Docker hostname `paperclip` is not in Paperclip's allowed list. The `Host` header makes Paperclip accept the request. The `Origin` header is required for mutations (POST/PATCH/DELETE). The `Secure` cookie flag prevents `-c` cookie files over HTTP, so we extract the token manually.

## API Commands

```bash
# List all agents
eval $PAPERCLIP_CURL http://paperclip:3100/api/companies/a951bb35-24a9-412a-bbcc-629c5acae619/agents

# List all issues
eval $PAPERCLIP_CURL http://paperclip:3100/api/companies/a951bb35-24a9-412a-bbcc-629c5acae619/issues

# Create an issue
eval $PAPERCLIP_CURL -X POST http://paperclip:3100/api/companies/a951bb35-24a9-412a-bbcc-629c5acae619/issues \
  -H "Content-Type: application/json" \
  -d '{"title":"Issue title","description":"Details...","priority":"medium"}'

# Assign an issue to an agent
eval $PAPERCLIP_CURL -X PATCH http://paperclip:3100/api/issues/{issueId} \
  -H "Content-Type: application/json" \
  -d '{"assigneeAgentId":"{agentId}","status":"todo"}'

# Check a specific agent
eval $PAPERCLIP_CURL http://paperclip:3100/api/agents/{agentId}
```

## Agent IDs

| Role | Agent ID | Model |
|------|----------|-------|
| Product Manager | 804e87be-4e8a-4baa-952d-3472662e7fda | gpt-5.3-codex |
| Finance Officer | 369d3f3a-9c89-446f-ad28-2c589d688b5f | gpt-5.3-codex |
| Frontend Developer | 11765603-a552-442a-bbca-b95f7aca9cf3 | gpt-5.3-codex |
| Backend Developer | 2dea472e-8a43-4131-9d8c-2ba429adcb84 | gpt-5.3-codex |
| QA Lead | a8489f81-1e3f-4d9f-b302-59222c5819d9 | gpt-5.3-codex |
| UX Designer (Hedva) | 0fef41ec-014f-4c14-ac6f-5041b1a44961 | gpt-5.3-codex |

## Azure OpenAI configuration

As of 2026-04-18, all six agents run via the `codex_local` adapter backed by Azure OpenAI (model `gpt-5.3-codex`). Anthropic-direct is retained only as a rollback path.

- **API key env var**: `AZURE_OPENAI_API_KEY` — lives in `.env` (gitignored). It is injected into the Paperclip container via `docker-compose.yml` and passed through per-agent via `adapter_config.env.AZURE_OPENAI_API_KEY` in the Paperclip control plane.
- **Codex config**: `config/codex-config.toml` is bind-mounted to `/paperclip/.codex/config.toml` inside the container. It declares the `azure` model provider pointing at `https://tlk-ai-agents.cognitiveservices.azure.com/openai/v1`.
- **api-version gotcha**: `query_params = { api-version = "preview" }` is the literal string `preview`. The unified `/openai/v1` endpoint does not accept dated versions (e.g. `2025-04-01-preview` returns HTTP 400). Do not "fix" this to a dated string.
- **Per-agent env override**: An agent's `adapter_config.env.AZURE_OPENAI_API_KEY` overrides the container-level env var. This lets us rotate keys per-agent or point an agent at a different Azure deployment without restarting Paperclip.

### Rollback

If Azure OpenAI is unavailable, flip each agent back to Claude direct with a PATCH on the agent:

```bash
# Example for a sonnet agent
eval $PAPERCLIP_CURL -X PATCH http://paperclip:3100/api/agents/{agentId} \
  -H "Content-Type: application/json" \
  -d '{"adapterType":"claude_local","adapterConfig":{"model":"claude-sonnet-4-6","dangerouslySkipPermissions":true,"workingDirectory":"/workspace/project"}}'

# Finance Officer uses haiku instead
#   "model":"claude-haiku-4-5-20251001"
```

The pre-migration snapshot of all six agents' adapter configs is at `openclaw/.a5c/processes/paperclip-codex-migration-execute-output/rollback-snapshot.json` (sibling repo, for reference).

## Issue Workflow

**CRITICAL:** Assigning an issue does NOT start the agent. You MUST explicitly wake the agent after assignment.

1. **Create issue** via `POST /api/companies/{companyId}/issues` → status: `backlog`
2. **Assign agent** via `PATCH /api/issues/{issueId}` with `assigneeAgentId` + `status: "todo"`
3. **WAKE THE AGENT** via `POST /api/agents/{agentId}/wakeup` ← **DON'T FORGET THIS**
   ```bash
   eval $PAPERCLIP_CURL -X POST http://paperclip:3100/api/agents/{agentId}/wakeup \
     -H "Content-Type: application/json" \
     -d '{"source":"on_demand","reason":"Pick up GON-XX"}'
   ```
   Response includes `id` (runId) and `status: "queued"`. Agent starts shortly after.
4. **Monitor run** via `GET /api/heartbeat-runs/{runId}` and `GET /api/heartbeat-runs/{runId}/log?offset=0&limitBytes=100000`
5. Agent runs → issue status: `in_progress`
6. Agent completes + pushes code → issue status: `done`

### Monitoring an agent run

```bash
# Check if agent is running
eval $PAPERCLIP_CURL http://paperclip:3100/api/agents/{agentId} | jq '{status, spentMonthlyCents}'

# Get all active runs for this company
eval $PAPERCLIP_CURL http://paperclip:3100/api/companies/a951bb35-24a9-412a-bbcc-629c5acae619/live-runs

# Tail agent logs
eval $PAPERCLIP_CURL "http://paperclip:3100/api/heartbeat-runs/{runId}/log?offset=0&limitBytes=100000" | tail -c 3000

# Get run status + exit code
eval $PAPERCLIP_CURL http://paperclip:3100/api/heartbeat-runs/{runId} | jq '{status, exitCode, error}'
```

### Scheduling periodic wakeups (for CEO monitoring)

Use CronCreate at session start to poll every 5 minutes:
```
CronCreate: "*/5 * * * *" → "check all live-runs in Paperclip + report blocked/done issues to Telegram group"
```
