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
- **Go-North URL:** `https://gonorth.tlk.solutions`
- **Use for:** Navigating the Go-North app, taking screenshots, checking UI after changes

### Trello (Task Management)
- **MCP server:** `trello` — board and card management
- **Use for:** Creating/updating cards, tracking sprint progress, reflecting project status

### Paperclip (Agent Management)
- **See:** `@import ../../config/paperclip.md` for full API details

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
