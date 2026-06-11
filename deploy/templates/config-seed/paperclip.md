# Paperclip Integration

This squad runs its OWN Paperclip instance (per-squad data plane). Nothing
here is shared with other squads.

## Connection
- **Internal URL**: http://paperclip:3100 (from inside this squad's Docker network)
- **External URL**: http://paperclip.<squad>.localhost:8800 (browser, through the SSH tunnel; exact value = `PAPERCLIP_PUBLIC_URL` in the squad .env)
- **Company ID**: `$PAPERCLIP_COMPANY_ID` (environment variable — written into the squad .env by `scripts/setup-company.sh` during `squadctl new`; never hardcode it)
- **Company slug**: see Paperclip UI (issue prefix derives from it)

## Authentication

Paperclip requires session auth with Host and Origin headers. Run this once
per session. Credentials come from the ENVIRONMENT — see
`private/paperclip-ops.md` (out-of-tree, never committed). Never paste the
literal credential into this file or any other tracked file.

```bash
# The public hostname Paperclip expects (strip the scheme from PAPERCLIP_PUBLIC_URL)
PAPERCLIP_HOST="${PAPERCLIP_PUBLIC_URL#http://}"; PAPERCLIP_HOST="${PAPERCLIP_HOST#https://}"

# Sign in and capture the session token
PAPERCLIP_SESSION=$(curl -v -s -X POST \
  -H "Host: ${PAPERCLIP_HOST}" \
  http://paperclip:3100/api/auth/sign-in/email \
  -H "Content-Type: application/json" \
  -d "{\"email\":\"$PAPERCLIP_ADMIN_EMAIL\",\"password\":\"$PAPERCLIP_ADMIN_PASSWORD\"}" \
  2>&1 | grep -oi "session_token=[^;]*" | head -1)

# Reusable curl prefix for all Paperclip API calls
PAPERCLIP_CURL="curl -s -H 'Host: ${PAPERCLIP_HOST}' -H 'Origin: ${PAPERCLIP_PUBLIC_URL}' -H 'Cookie: __Secure-better-auth.${PAPERCLIP_SESSION}'"
```

**Why the workaround?** The Docker hostname `paperclip` is not in Paperclip's
allowed list. The `Host` header makes Paperclip accept the request. The
`Origin` header is required for mutations (POST/PATCH/DELETE). The `Secure`
cookie flag prevents `-c` cookie files over HTTP, so we extract the token
manually.

## API Commands

```bash
# List all agents
eval $PAPERCLIP_CURL http://paperclip:3100/api/companies/$PAPERCLIP_COMPANY_ID/agents

# List all issues
eval $PAPERCLIP_CURL http://paperclip:3100/api/companies/$PAPERCLIP_COMPANY_ID/issues

# Create an issue
eval $PAPERCLIP_CURL -X POST http://paperclip:3100/api/companies/$PAPERCLIP_COMPANY_ID/issues \
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

Live agent IDs are environment-specific — they are created by
`scripts/setup-company.sh` from this squad's `config/agents.json` and listed
in `private/paperclip-ops.md` (out-of-tree).

## Issue Workflow
1. Issue created → status: `backlog`
2. Assigned to agent + status set to `todo` → Paperclip spawns the agent
3. Agent executes → status: `in_progress`
4. Agent completes → status: `done`

@import ../private/paperclip-ops.md
