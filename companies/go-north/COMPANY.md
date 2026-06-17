---
schema: agentcompanies/v1
kind: company
slug: go-north
name: "Go-North (חשיפה לצפון)"
description: "AI-powered relocation assistant for families moving to northern Israel"
version: 0.1.0
goals:
  - Build the #1 AI-powered relocation assistant for northern Israel
  - Help families discover communities, schools, employment, and housing in the north
  - Deliver a Hebrew-first, mobile-first, RTL-native experience
---

# Go-North

## Mission

Build the #1 AI-powered relocation assistant for families moving to northern Israel. Go-North helps families explore communities, compare schools, find employment, and navigate the relocation process -- all through a conversational AI experience in Hebrew.

## Vision

Every family considering a move to northern Israel should have a personal, AI-powered advisor that understands their needs, speaks their language, and guides them through every step of the journey.

## Quality Standards

- **Hebrew-first**: All user-facing content must be in Hebrew with full RTL support.
- **Mobile-first**: The primary experience targets mobile devices; desktop is secondary.
- **Accessibility**: WCAG 2.1 AA compliance for all public-facing pages.
- **No deploy without QA sign-off**: The QA Lead must approve every release before it reaches production.
- **Budget awareness**: Token usage and API costs are tracked per feature and per sprint.

## Tech Stack

- **Frontend**: Next.js, React, Tailwind CSS
- **Backend**: Supabase (Postgres, Auth, Storage), OpenAI AI SDK
- **Infrastructure**: Vercel (hosting), Supabase (managed backend)
- **Design**: Browser-based visual review (Playwright MCP), markdown specs

## People / Operators

This is the human side of Go-North. Real names, Telegram handles, and customer
contacts live in the gitignored overlay `private/team.md` (loaded per persona at
runtime) — this public file references **roles only**, never personal handles.

| Person | Role | Notes |
|--------|------|-------|
| Operator (Elik) | Squad operator | Owns deployment, the Phase-3 backend flip, and squad `.env`. Telegram id in env: `OPERATOR_TELEGRAM_ID`. |
| Founders | Product stakeholders | Direct the founder-voice agents (Leo/Yefet); Hebrew working register is the baseline. Handles in `private/team.md`. |

## Agent Roster

Go-North runs **two cooperating agent worlds**:

1. **War-room personas** — Telegram/agent-bus chat agents (the public face), launched
   from `agents/<persona_dir>/` by `launch.sh` and listed in `config/agents.json`.
2. **Paperclip workers** — the internal dev team Paperclip manages, defined in this
   package under `agents/<slug>/AGENTS.md` and wired by `.paperclip.yaml`.

### War-room personas (chat / bus)

| bus_id | Persona | persona_dir | Telegram bot (env) | Model (default) | Responsibility |
|--------|---------|-------------|--------------------|-----------------|----------------|
| captain | Captain Picard | captain | `CAPTAIN_TELEGRAM_TOKEN` | sonnet | Triage router + scrum master; sees every message, routes, never implements. |
| leo | Galileo / Leo (CEO Yefet) | ceo-gonorth | `CEO_GONORTH_TELEGRAM_TOKEN` | opus | CEO / backend founder-voice; takes briefs, dispatches work, owns delivery. |
| iris | Iris (UX Hedva) | ux-gonorth | `UX_GONORTH_TELEGRAM_TOKEN` | sonnet | UX/UI designer; visual review, flows, mobile-first RTL design handoff. |
| yefet | Yefet | _(openclaw, bus)_ | _(openclaw container)_ | gpt-5.5 | Legacy openclaw CEO agent on the bus (attach=bus); visual-sight + E2E. |

Telegram bot **token** values are env-only — see env var names above. Live agent
ids are environment-specific (`private/paperclip-ops.md`, gitignored).

### Paperclip workers (dev team)

| Slug | Role | Reports to | Model | One-line responsibility |
|------|------|------------|-------|-------------------------|
| product-manager | Product Manager | _(top-level)_ | gpt-5.3-codex | Backlog, priorities, user stories; routes work to ICs. |
| finance-officer | Finance Officer | product-manager | gpt-5.3-codex | Budget, cost analysis, token/API spend monitoring. |
| frontend-dev | Frontend Developer | product-manager | gpt-5.3-codex | Next.js, React, Tailwind, RTL. |
| backend-dev | Backend Developer | product-manager | gpt-5.3-codex | Supabase, AI SDK, APIs. |
| qa-lead | QA Lead | product-manager | gpt-5.3-codex | Testing, Playwright, release gates. |
| ux-designer | UX Designer | product-manager | gpt-5.3-codex | Visual review, UX flows, design handoff (internal). |

Paperclip adapter for workers: `codex_local` (see `.paperclip.yaml`). Models are
operator-defined Azure deployment names — see `reference_azure_deployment_name`.

## Who does what / routing

The Captain is the only war-room agent that sees every message; everyone else
acts only when @mentioned or addressed by role. Captain's routing table (the
canonical copy lives in `agents/captain/AGENTS.md`):

| Domain | Route to |
|--------|----------|
| Go-North product, relocation, Next.js, Supabase, Vercel, settlements, intake flow | CEO (Leo / Yefet) |
| Go-North UX, design, visual, layout, colors, flow | UX (Iris / Hedva) |
| UI changes (design + implementation) | BOTH UX and CEO |
| Sprint / scrum / coordination | Captain (handles directly) |
| Personal / DM-style / general | operator DM |

Dev execution: the CEO/founder hands a brief to the Paperclip **product-manager**,
which delegates to the responsible IC; **qa-lead** gates before `done`.

## Conventions

- **Repo**: the Go-North project repo — URL in env `PROJECT_REPO` / `PROJECT_REPO_URL`;
  cloned into `/workspace/project` by `launch.sh`. Production URL in env `PROJECT_URL`.
- **Branch / PR flow**: feature branch → reviewed PR → `main`. No direct pushes to `main`.
- **QA gate**: the QA Lead must approve before any issue moves to `done`; no deploy
  without QA sign-off (see Quality Standards).
- **Paperclip**: company id in env `PAPERCLIP_COMPANY_ID`; company slug `GON`
  (issue prefix `GON-`). Internal URL `http://paperclip:3100`. Auth uses session
  cookie; admin credentials are env-only (`PAPERCLIP_ADMIN_EMAIL` /
  `PAPERCLIP_ADMIN_PASSWORD`) and live in `private/paperclip-ops.md` (gitignored).
  Origin must equal Host on mutations.
- **Telegram**: per-agent bot tokens via `<AGENT_SLUG>_TELEGRAM_TOKEN`; group id in
  env `SQUAD_TELEGRAM_GROUP_ID` / `GONORTH_GROUP_ID`; operator id in
  `OPERATOR_TELEGRAM_ID`. Forum replies MUST set `reply_to` (see
  `reference_telegram_forum_reply_to`).
- **Agent bus**: NDJSON journal at `AGENT_BUS_DIR` (`/workspace/agent-bus`,
  `messages.ndjson` / `trips.ndjson`). Cross-agent comms go over the bus, not
  bot-to-bot Telegram.
- **Secrets**: this is a PUBLIC repo. Reference env var NAMES only — never paste
  token/password/key values into this file.
