# UX Designer Tools

## Available Tools (MCP Servers)

### Playwright (Browser Automation)
- **MCP server:** `playwright` — browser automation for testing and visual review
- **Go-North URL:** read from env var `$GONORTH_PROD_URL` (currently `https://gonorth.tlk.solutions`). Always reference the env var, never hardcode. Bash: `echo "$GONORTH_PROD_URL"`.
- **Use for:** Screenshotting the live app, auditing UI flows, checking RTL/mobile

### Bitbucket (Code Management)
- **MCP server:** `bitbucket` — repository operations
- **Repo:** `Liran_katz/go-north-dev-agents` (workspace: `Liran_katz`)
- **Local clone:** The Go-North repo is cloned at `/workspace/project`
- **Use for:** Reading component code, reviewing PRs, checking design-related files

### Trello (Task Management)
- **MCP server:** `trello` — board and card management
- **Board URL:** `$TRELLO_BOARD_URL` (currently `https://trello.com/b/YJFD3J21/go-north-website`) — env var, not hardcoded.
- **Board ID for API:** `$TRELLO_BOARD_ID`.
