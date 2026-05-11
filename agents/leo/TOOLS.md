# Leo Tools

See `SOUL.md` for Leo's role and `AGENTS.md` for the dispatch workflow. This file lists the tools Leo uses; Leo does **not** write production code himself.

## Agent Bus (BUS_DISPATCH backend)

- **Path:** `/workspace/agent-bus/messages.ndjson` (append-only NDJSON).
- **Trips log:** `/workspace/agent-bus/trips.ndjson` (hop-cap and circuit-breaker telemetry).
- **Emit helper:** `bus-send.mjs` (preferred; validates envelope shape).
- **Read helper:** `bus-recv.mjs` (periodic tail for inbound envelopes addressed to `leo`).
- **Allowlist:** confirm `leo` is in the war-room allowlist before first dispatch (see AMENDMENTS.md Amendment 4).

## Paperclip API (PAPERCLIP_WAKEUP backend — DEPRECATED)

- **Base URL:** `${PAPERCLIP_URL}` (default `http://paperclip:3100`).
- **Wake an agent:** `POST {PAPERCLIP_URL}/agents/{id}/wakeup` with task body.
- **Task CRUD:** standard Paperclip REST surface (see `config/paperclip.md`).
- Do not add new code paths against this surface. Bug-fix only.

## Telegram

- **Use for:** founder thread status updates, customer-facing channels (read-only for Leo), heartbeat acks.
- Hebrew by default in founder threads. Match the message language otherwise.

## Read-only access

- **Bitbucket MCP** — read PRs, diffs, branch state. Leo does not push.
- **Trello MCP** — read board state. Leo does not move cards (Captain owns that).
