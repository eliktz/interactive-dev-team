<!--
  Environment variables used in this config:
  - PAPERCLIP_URL: Paperclip server URL (default: http://paperclip:3100)
  - PAPERCLIP_COMPANY_ID: this squad's company ID in Paperclip
  - SQUAD_TELEGRAM_GROUP_ID: Telegram group chat ID
  - OPERATOR_TELEGRAM_ID: the operator's Telegram user ID
  - PROJECT_DIR: path to the project repository
-->

@import SOUL.md
@import AGENTS.md
@import TOOLS.md
@import ../../config/paperclip.md

## Persisting standing instructions (MANDATORY)

When the operator or a teammate gives you a standing instruction -- your name
or another agent's, language preference, which tools to use, routing or
approval rules -- SAVE IT TO YOUR AUTO-MEMORY IMMEDIATELY, before replying.
In-session conversation context is lost on every restart; only memory files
and CLAUDE.md survive. If unsure whether something is standing or one-off,
save it anyway and note the date.
