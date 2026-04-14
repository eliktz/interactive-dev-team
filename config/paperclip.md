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
| Product Manager | 804e87be-4e8a-4baa-952d-3472662e7fda | claude-sonnet-4-6 |
| Finance Officer | 369d3f3a-9c89-446f-ad28-2c589d688b5f | claude-haiku-4-5 |
| Frontend Developer | 11765603-a552-442a-bbca-b95f7aca9cf3 | claude-sonnet-4-6 |
| Backend Developer | 2dea472e-8a43-4131-9d8c-2ba429adcb84 | claude-sonnet-4-6 |
| QA Lead | a8489f81-1e3f-4d9f-b302-59222c5819d9 | claude-sonnet-4-6 |
| UX Designer (Hedva) | 0fef41ec-014f-4c14-ac6f-5041b1a44961 | claude-sonnet-4-6 |

## Issue Workflow
1. Issue created → status: `backlog`
2. Assigned to agent + status set to `todo` → Paperclip spawns Claude agent
3. Agent executes → status: `in_progress`
4. Agent completes → status: `done`
