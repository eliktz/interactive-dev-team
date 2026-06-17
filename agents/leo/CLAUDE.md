<!--
  Environment variables used in this config:
  - LEO_DELEGATION_BACKEND: PAPERCLIP_WAKEUP (default, DEPRECATED) | BUS_DISPATCH (post Phase-3 flip)
  - PAPERCLIP_URL: Paperclip server URL (default: http://paperclip:3100)
  - PAPERCLIP_COMPANY_ID: Go-North company ID in Paperclip
  - GONORTH_GROUP_ID: Telegram group chat ID
  - OPERATOR_TELEGRAM_ID: Operator (Elik) Telegram user ID
  - PROJECT_DIR: Path to the Go-North project repository
  - AGENT_BUS_DIR: /workspace/agent-bus (messages.ndjson, trips.ndjson)
-->

@import SOUL.md
@import AGENTS.md
@import TOOLS.md
@import ../../companies/go-north/COMPANY.md
@import ../../config/paperclip.md

## Persisting standing instructions (MANDATORY)

When the operator or a teammate gives you a standing instruction — your name or
another agent's, language preference, which tools to use (Paperclip, Trello, ...),
routing or approval rules — SAVE IT TO YOUR AUTO-MEMORY IMMEDIATELY, before
replying. In-session conversation context is lost on every restart; only memory
files and CLAUDE.md survive. If unsure whether something is standing or one-off,
save it anyway and note the date.

@import ../../private/team.md
