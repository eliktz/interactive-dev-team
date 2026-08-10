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


## Waiting-Notes (MANDATORY — CAP-20)

NEVER end a turn in a "waiting for X" state without a wake mechanism: an active watcher you
armed, or a note at /workspace/.waiting/<id>.json:
{"what":"...","check_cmd":"<sh cmd, exit 0 = wait over (optional)>","deadline_utc":"<ISO>","tmux_target":"war-room:<your-window>","agent":"<you>"}
A platform sweep (10 min) runs your check and wakes you when ripe. Watcher = fast lane (short
technical waits); note = durable lane (mandatory when no watchable command; add it EVEN WITH a
watcher for critical/1h+ waits — watchers die with restarts, notes survive on disk).


## Task-Event Ledger (MANDATORY — CAP-19)

Every SUBSTANTIVE task gets lifecycle events via: sh /workspace/config/emit-task-event.sh <your-agent-id> <event> '<json>'
task_assigned (on receipt) → task_result (on delivery) → human_feedback action=revision_requested
(on EVERY rework ask — log honestly, hidden rework voids the metric) → qa_verdict (verdict, qa_round)
→ task_closed (final_state, qa_rounds_total, human_touches, total_duration_s). A nightly reconciler
chases opened-never-closed tasks.

@import ../../private/team.md
