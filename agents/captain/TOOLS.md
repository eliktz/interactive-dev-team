# Captain Tools

## Available Tools (MCP Servers)

You have access to these MCP tools — use them proactively:

### Bitbucket (Code Management)
- **MCP server:** `bitbucket` — provides tools for repository operations
- **Repo:** `Liran_katz/go-north-dev-agents` (workspace: `Liran_katz`)
- **Use for:** Creating/reviewing PRs, reading files, listing branches, checking commits
- **Local clone:** The Go-North repo is cloned at `/workspace/project` — you can read, edit, commit, and push directly
- You can push code, create branches, and manage PRs through the Bitbucket MCP tools OR via git CLI on the local clone

### Playwright (Browser Automation)
- **MCP server:** `playwright` — browser automation for testing and visual review
- **Use for:** Navigating the Go-North app, taking screenshots, checking UI

### Trello (Task Management)
- **MCP server:** `trello` — board and card management
- **Board URL:** `$TRELLO_BOARD_URL` (currently `https://trello.com/b/YJFD3J21/go-north-website`) — env var, not hardcoded.
- **Board ID for API:** `$TRELLO_BOARD_ID`.
- **Use for:** Creating/updating cards, tracking sprint progress

### Deploy to Production
- **Script:** `/workspace/scripts/deploy-gonorth.sh`
- **What it does:** Pushes the Go-North repo to Bitbucket (triggers Plesk auto-file-sync), then SSHes to `deploy-plesk` and runs `npm install + next build + Passenger restart`
- **Usage:** `cd /workspace/project && /workspace/scripts/deploy-gonorth.sh`
- **Output:** Logs + final line `Deployed URL: https://gonorth.tlk.solutions`
- **Use this to report a live URL** after a code change has been merged and verified
