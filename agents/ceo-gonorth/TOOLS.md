# CEO Tools & Project Context

## Available Tools (MCP Servers)

You have access to these MCP tools — use them proactively:

### Bitbucket (Code Management)
- **MCP server:** `bitbucket` — provides tools for repository operations
- **Repo:** `Liran_katz/go-north-dev-agents` (workspace: `Liran_katz`)
- **Use for:** Creating/reviewing PRs, reading files, listing branches, checking commits
- **Local clone:** The Go-North repo is cloned at `/workspace/project` — you can read, edit, commit, and push directly

### Playwright (Browser Automation)
- **MCP server:** `playwright` — browser automation for testing and visual review
- **Go-North URL:** read from env var `$GONORTH_PROD_URL` (currently `https://gonorth.tlk.solutions`). Always reference the env var; the literal value can change per company. Bash: `echo "$GONORTH_PROD_URL"`.
- **Use for:** Navigating the Go-North app, taking screenshots, checking UI after changes

### Trello (Task Management)
- **MCP server:** `trello` — board and card management
- **Board URL:** read from env var `$TRELLO_BOARD_URL` (currently `https://trello.com/b/YJFD3J21/go-north-website`). Always reference the env var when including a Trello link in operator-facing messages — the literal URL changes per company. Bash: `echo "$TRELLO_BOARD_URL"`.
- **Board ID (for API calls):** `$TRELLO_BOARD_ID` (24-char hex, used by `scripts/trello-rewrite.sh` + `ceo-trello-sync.sh`).
- **Use for:** Creating/updating cards, tracking sprint progress, reflecting project status

### Paperclip (Agent Management)
- **See:** `@import ../../config/paperclip.md` for full API details

### Deploy to Production
- **Script:** `/workspace/scripts/deploy-gonorth.sh`
- **What it does:** Pushes Go-North to Bitbucket (Plesk auto-file-sync) → SSHes to `deploy-plesk` → runs `npm install + next build + Passenger restart` → verifies site returns HTTP 200
- **Usage:** `cd /workspace/project && /workspace/scripts/deploy-gonorth.sh`
- **Output:** Logs, final line is `Deployed URL: https://gonorth.tlk.solutions`
- **When to use:** After QA approval, to push changes live and report the URL

## Project Context

### Stack
| Layer | Technology |
|-------|-----------|
| Framework | Next.js 16, React 19 |
| Language | TypeScript 5 |
| Styling | Tailwind CSS v4 |
| Backend | Supabase (auth, DB, storage) |
| AI | OpenAI AI SDK |
| Deployment | Plesk (Phusion Passenger + Next.js, SSH deploy via `gonorthdev@34.165.203.65` running `./deploy.sh`) |
| Package Manager | pnpm |
| Node | >= 22 |

### Key Info
- Repo: $PROJECT_REPO
- Local: $PROJECT_DIR
- Production URL: $PROJECT_URL
- AI Persona: Norit -- guides families through 21-screen intake flow
- Regression tests: `npx playwright test e2e/regression.spec.ts`
