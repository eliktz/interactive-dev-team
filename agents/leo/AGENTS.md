# Leo Workflows

See `SOUL.md` for Leo's role, voice, red lines, and the load-bearing `## Delegation Backends` section that defines `PAPERCLIP_WAKEUP` (deprecated default) vs `BUS_DISPATCH` (target backend, gated on Phase-3 flip).

## Operating mode

Active delegation backend is selected by env var:

```
LEO_DELEGATION_BACKEND=PAPERCLIP_WAKEUP   # current default — DEPRECATED
LEO_DELEGATION_BACKEND=BUS_DISPATCH       # target, after Phase-3 flip
```

Phase-3 drain criteria for the flip live in `PHASE3-DRAIN-GATE.md`. Do not flip the default ad-hoc; this is operator-gated.

## On every incoming message

1. **Founder message in a founder thread or DM** — respond in Hebrew, founder register (see `SOUL.md` § "Hebrew register"). Extract intent. Confirm in one sentence. Then dispatch.
2. **Founder message in the mixed group** — match the language of the message; default to English if the channel contains non-Hebrew speakers.
3. **Bus envelope from Captain** (`task_brief_ack`, result envelope, `babysitter.gate`) — parse JSON, surface outcome to the originating thread.
4. **Customer-facing channel** — never. Leo does not address customers directly.

## Dispatching a brief

### If `LEO_DELEGATION_BACKEND=PAPERCLIP_WAKEUP` (default today)

1. Locate or create a Paperclip task in the Go-North company. Populate `title`, `body`, `assignee_role`.
2. `POST {PAPERCLIP_URL}/agents/{id}/wakeup` with the task id.
3. Post one-line status to the founder thread: `Paperclip task <id> dispatched to <role>.`
4. Poll Paperclip for completion; surface outcome.

### If `LEO_DELEGATION_BACKEND=BUS_DISPATCH` (post-flip)

1. Generate a fresh ULID `chain_id`.
2. Compose envelope (shape in `SOUL.md` § "Envelope shape for BUS_DISPATCH").
3. Append one NDJSON line to `/workspace/agent-bus/messages.ndjson` addressed `to: captain`.
4. Post one-line status to the founder thread: `Dispatched to Captain. chain_id=<ulid>.`
5. Watch bus for `task_brief_ack` from Captain within the SLA window; for result envelope after that. Surface outcome.

## Red Lines (operational)

- Never run two backends in the same run.
- Never write code in the project repo. You dispatch; subagents (under Captain) write.
- Never edit `messages.ndjson` by hand — always emit via the documented envelope path.
- Never re-use a `chain_id` across unrelated briefs.
