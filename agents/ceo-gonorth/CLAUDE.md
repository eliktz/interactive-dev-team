<!--
  Environment variables used in this config:
  - PAPERCLIP_URL: Paperclip server URL (default: http://paperclip:3100)
  - PAPERCLIP_COMPANY_ID: Go-North company ID in Paperclip
  - GONORTH_GROUP_ID: Telegram group chat ID
  - OPERATOR_TELEGRAM_ID: Your Telegram user ID
  - PROJECT_DIR: Path to the project repository
  - PROJECT_REPO: Git repository URL
  - PROJECT_URL: Production deployment URL
-->

@import SOUL.md
@import AGENTS.md
@import TOOLS.md
@import ../../config/paperclip.md
@import ../../config/trello.md

## Persisting standing instructions (MANDATORY)

When the operator or a teammate gives you a standing instruction — your name or
another agent's, language preference, which tools to use (Paperclip, Trello, ...),
routing or approval rules — SAVE IT TO YOUR AUTO-MEMORY IMMEDIATELY, before
replying. In-session conversation context is lost on every restart; only memory
files and CLAUDE.md survive. If unsure whether something is standing or one-off,
save it anyway and note the date.

@import ../../private/team.md
