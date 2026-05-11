# `_envelope.md` — Canonical JSON Envelope Spec (Plan-B Phase 1, Deliverable 8)

The single source of truth for the structured JSON envelope all squad agents — galileo, captain, backend-dev, frontend-dev, qa, iris, hedva, ux — exchange over the agent-bus.

---

## 1. Two-layer model

Two layers, do not confuse them:

1. **Transport layer (bus envelope)** — the NDJSON row written to `messages.ndjson` by `bus-send.mjs` / the agent-bus MCP server. Schema enforced by `plugins/agent-bus-marketplace/agent-bus/server.ts` (`interface BusMessage`).
2. **Application layer (squad envelope)** — a structured JSON payload that lives **inside** the transport layer's `body` field. This is where `type`, `verdict`, `evidence`, `reason`, etc. live. The bus is type-agnostic; the squad's higher-level state machine reads the JSON inside `body`.

A correctly formed squad message is one bus row whose `body` parses as a squad envelope.

---

## 2. Transport envelope (bus row, enforced by `server.ts`)

```typescript
interface BusMessage {
  id: string;            // ULID, 26 ascii chars, minted by sender's agent-bus instance
  ts: string;            // ISO 8601 UTC, e.g. "2026-05-12T09:14:22.103Z"
  from: string;          // sender agent id, MUST be in AGENT_BUS_ALLOWED_SENDERS
  to: string;            // recipient agent id, MUST be in AGENT_BUS_ALLOWED_SENDERS
                         //   (broadcast `"*"` is accepted on INBOUND delivery only —
                         //    the `send` tool itself rejects `to:"*"` because it
                         //    is not in the allowlist; broadcast is therefore
                         //    realized by sending N copies, one per recipient)
  reply_to: string | null; // id of the inbound message this is a reply to, or null
  subject: string | null;  // short label for the Telegram supergroup mirror, ≤200 chars
  body: string;            // squad envelope JSON, sanitized, ≤ AGENT_BUS_MAX_BODY_BYTES (4096)
  hop_count: number;       // ≥ 0; reply increments parent.hop_count by 1
  chain_id: string;        // ULID; fresh on a no-parent send, propagated unchanged on reply
}
```

This is exactly the `interface BusMessage` declared at `plugins/agent-bus-marketplace/agent-bus/server.ts:107-117`.

### 2.1 Live example (from `/var/lib/warroom-bus/messages.ndjson`)

```json
{"id":"01KQSW60811YYPF5H8GJ9EJD1T","ts":"2026-05-04T16:12:16.513Z","from":"iris","to":"galileo","reply_to":null,"subject":"v0.2 deploy link","body":"...","hop_count":0,"chain_id":"01KQSW607Y1MVX0E6HF4DBJTAE"}
```

---

## 3. Application envelope (the JSON inside `body`)

```typescript
type SquadEnvelope = {
  // Mirror of select transport fields for receiver-side convenience. These
  // MUST match the transport row they sit inside. They are NOT a substitute
  // for the transport row — the bus validates the transport row, not the body.
  id: string;            // same ULID as the transport row's id
  ts: string;            // same ISO timestamp
  from: string;          // same sender id
  to: string;            // same recipient id (or "*" for logical broadcast intent)
  chain_id: string;      // same chain id
  hop_count: number;     // same hop count
  reply_to?: string | null;

  // Squad-level fields:
  type: SquadEnvelopeType;
  subject?: string;      // short title (≤ 200 chars); usually duplicated to transport.subject
  body?: string;         // human-readable narrative (≤ ~3500 bytes after JSON overhead)
  attachments?: Array<{
    kind: "file" | "url" | "image";
    path: string;        // relative to /workspace or a URL
    mime?: string;       // e.g. "image/png", "application/json"
  }>;

  // Type-specific (see §4 for which fields each type requires):
  verdict?: "pass" | "fail" | "override";   // qa_verdict, babysitter.gate
  ssim?: number;                              // qa:visual verdicts (0..1, fail < 0.97)
  screenshot_diff?: string;                   // path to diff image, e.g. attachments[i].path
  evidence?: string | {
    logs?: string[];      // paths to log artifacts
    tests?: string[];     // names of tests run, or paths to test reports
    commit_sha?: string;  // 40-char or 7-char abbrev sha
  };
  reason?: string;        // cancel + fallback types (see §4 for allowed enums)
};

type SquadEnvelopeType =
  | "task_brief"
  | "task_brief_ack"
  | "task_brief_cancel"
  | "task_brief_cancel_ack"
  | "qa_verdict"
  | "babysitter.gate"
  | "galileo.fallback"
  | "informational";
```

---

## 4. Required fields by `type`

| `type` | Required fields (in addition to id, ts, from, to, chain_id, type) | Notes |
|---|---|---|
| `task_brief` | `hop_count`, `subject`, `body` | Originating envelope. `reply_to` MUST be null. Captain ingests and dispatches. |
| `task_brief_ack` | `hop_count`, `reply_to` | Captain → galileo, confirms receipt within `GALILEO_FALLBACK_SLA_MIN`. |
| `task_brief_cancel` | `reason` ∈ {`"sla_fallback"`, `"circuit_breaker"`, `"operator_override"`} | Galileo → captain on fallback fire; captain MUST abort matching in-flight spawn. `reply_to` MAY point at the cancelled task_brief but is not required. |
| `task_brief_cancel_ack` | `reply_to` (= cancel's `id`) | Captain → galileo, confirms abort, within 60s. |
| `qa_verdict` | `hop_count`, `reply_to`, `verdict`, `evidence` | `ssim` REQUIRED when verdict was produced by the `qa:visual` tier; `screenshot_diff` OPTIONAL but expected on `verdict="fail"` from qa:visual. |
| `babysitter.gate` | `verdict`, `evidence` | Emitted by Phase 2 bus-event emitter on every gate decision. `evidence` SHOULD include `commit_sha` + the originating babysitter process name in `logs[0]`. `reply_to` OPTIONAL; when present points at the originating `task_brief`. |
| `galileo.fallback` | `reason` ∈ {`"override"`, `"sla"`, `"circuit"`} | Galileo broadcasts on every fallback fire. Phase 4 aggregator counts these rows in `messages.ndjson`. |
| `informational` | (none beyond base) | Catch-all for human-readable status — Iris design ping, operator note, etc. |

---

## 5. Validation rules

1. **`id`** — MUST be a ULID (26 ASCII chars, Crockford base32, lexicographically sortable). Minted by the sender's agent-bus instance via `ulid()` (npm `ulid`). Monotonic per-process.

2. **`from`** — MUST be present in `AGENT_BUS_ALLOWED_SENDERS` env var. `server.ts` enforces this on outbound (line 169-174: `from === selfId`) and inbound (line 538-541: `ALLOWED_SET.has(m.from)`).

3. **`to`** — MUST be present in `AGENT_BUS_ALLOWED_SENDERS`. Broadcast `"*"` is **delivered** to all subscribers (line 295, 537) but the outbound `send` tool rejects it because `*` is not in the allowlist; broadcast is therefore realized by the sender enumerating recipients and sending N copies. (Open implementation gap — tracked.)

4. **`hop_count`** — Computed by the SENDER's bus when replying: `parent.hop_count + 1`. On a fresh chain (no `reply_to`), hop_count starts at 0. Receiver does NOT increment.

5. **Hop cap** — `server.ts` line 208 rejects when `next >= maxHops` (so with `MAX_HOPS=4`, accepted hops are 0,1,2,3; the would-be hop=4 is rejected). Galileo overrides to `MAX_HOPS=3` (accepted hops 0,1,2).

6. **`chain_id`** — Minted as a fresh ULID by the ORIGINATING sender (no parent). Propagated UNCHANGED through every reply in the chain. `server.ts` line 214 + 429.

7. **`body` size** — After `sanitizeBody()` (strips ASCII control chars except `\n`/`\t`, neutralizes literal `<channel` with a zero-width-space variant — line 140-145), the byte length MUST be ≤ `AGENT_BUS_MAX_BODY_BYTES` (default 4096). The squad-envelope JSON SHOULD therefore stay under ~3500 bytes to leave headroom for the JSON structure overhead.

8. **`reply_to`** — MUST resolve to an existing `id` in `messages.ndjson`; otherwise the bus rejects with code `unknown_reply` (line 201-206).

9. **Sanitization** — `server.ts` strips/neutralizes the body before the size check; the squad envelope JSON SHOULD therefore avoid raw `<channel` substrings and ASCII control characters.

---

## 6. Loop-breaker integration

The sender's `bus-send.mjs` (and the in-process `doSend` in `server.ts`) writes a trip row to `${AGENT_BUS_DIR}/trips.ndjson` whenever a send is rejected:

```json
{"ts":"2026-05-11T22:47:00.176Z","reason":"hop_limit","from":"leo","to":"galileo","chain_id":"01KRCKHGXFRAKBN6K8WD4SZMG3","detail":"agent-bus: hop limit reached (would be 3/3) for chain 01KRCKHGXFRAKBN6K8WD4SZMG3; message dropped."}
```

Trip rules:

- **`hop_limit`** — `next >= MAX_HOPS`. NO row written to `messages.ndjson`. Trip row written. Telegram BLOCKED notice posted (line 356-358).
- **`cooldown`** — per-`(from,to)` interval `< AGENT_BUS_COOLDOWN_SEC` (default 5s; Galileo 30s). NO row in `messages.ndjson`. Trip row written. Telegram BLOCKED posted.
- **`unknown_reply`**, **`body_too_big`**, **`bad_recipient`**, **`bus_paused`** — also rejected; only `hop_limit` and `cooldown` post the BLOCKED notice to Telegram. (Minor gap per `PLAN-A-MV-DONE-EVIDENCE.md` deviations §4 — all six rejection codes SHOULD post; tracked for follow-up.)

---

## 7. Galileo-specific overrides

- **`MAX_HOPS=3`** — Galileo's bus instance starts with `AGENT_BUS_MAX_HOPS=3` (tighter than the global default of 4). Accepted hops 0,1,2; hop=3 rejected.
- **`COOLDOWN_SEC=30`** — Galileo's cooldown is 30s per `(from,to)` pair (vs. global 5s default).
- **`galileo.fallback` envelope** — On every entry into fallback mode, galileo emits a `galileo.fallback` envelope (per BP1 Addendum A and FINAL-PLAN.md line 514). Phase 4 aggregator counts these rows.
- **Fallback flag file** — Galileo writes `${AGENT_BUS_DIR}/.fallback-mode.<chain_id>` on fallback entry. While the file exists, `MAX_HOPS` for that chain is effectively 1 (sentinel + immediate gate verdict; no further hops allowed). The flag is removed when galileo reverts to DELEGATE.

---

## 8. Example envelopes

### 8.1 `task_brief` — Galileo dispatches to Captain

Transport row in `messages.ndjson`:
```json
{"id":"01KRCM2P5N1XYHFT9G3VB6KQDC","ts":"2026-05-12T09:14:22.103Z","from":"galileo","to":"captain","reply_to":null,"subject":"GON-127: add settlement-card RTL caret","body":"<json below>","hop_count":0,"chain_id":"01KRCM2P5N1XYHFT9G3VB6KQDC"}
```

`body` (squad envelope):
```json
{
  "id": "01KRCM2P5N1XYHFT9G3VB6KQDC",
  "ts": "2026-05-12T09:14:22.103Z",
  "from": "galileo",
  "to": "captain",
  "chain_id": "01KRCM2P5N1XYHFT9G3VB6KQDC",
  "hop_count": 0,
  "reply_to": null,
  "type": "task_brief",
  "subject": "GON-127: add settlement-card RTL caret",
  "body": "Frontend: SettlementSwipe.tsx currently shows a stray LTR caret on Hebrew rows. Acceptance: RTL caret + functional tests + visual diff against /workspace/agents/ux-gonorth/mockups/gon127-rtl-caret.png. Branch: gon-127. Out of scope: backend.",
  "attachments": [
    { "kind": "file", "path": "/workspace/agents/ux-gonorth/mockups/gon127-rtl-caret.png", "mime": "image/png" }
  ]
}
```

### 8.2 `qa_verdict` — qa:visual fails Frontend's PR

Transport row:
```json
{"id":"01KRCM6KZB8X1V4S0J5N7HRWDQ","ts":"2026-05-12T09:31:08.442Z","from":"qa","to":"captain","reply_to":"01KRCM5XYZ...","subject":"GON-127 qa:visual FAIL ssim=0.943","body":"<json below>","hop_count":3,"chain_id":"01KRCM2P5N1XYHFT9G3VB6KQDC"}
```

`body`:
```json
{
  "id": "01KRCM6KZB8X1V4S0J5N7HRWDQ",
  "ts": "2026-05-12T09:31:08.442Z",
  "from": "qa",
  "to": "captain",
  "chain_id": "01KRCM2P5N1XYHFT9G3VB6KQDC",
  "hop_count": 3,
  "reply_to": "01KRCM5XYZ...",
  "type": "qa_verdict",
  "subject": "GON-127 qa:visual FAIL ssim=0.943",
  "body": "Visual diff exceeds threshold (ssim 0.943 < 0.97). Caret position 12px off in RTL. Diff attached.",
  "verdict": "fail",
  "ssim": 0.943,
  "screenshot_diff": "/workspace/agents/qa/runs/gon-127/diff.png",
  "evidence": {
    "logs": ["/workspace/agents/qa/runs/gon-127/qa-visual.log"],
    "tests": ["qa:visual:settlement-swipe-rtl"],
    "commit_sha": "a3f9c12"
  }
}
```

### 8.3 `babysitter.gate` — Phase 2 emitter announces gate pass

Transport row:
```json
{"id":"01KRCMK4WGAR3T8Z5X9YPN1EHV","ts":"2026-05-12T09:42:55.001Z","from":"captain","to":"galileo","reply_to":"01KRCM2P5N1XYHFT9G3VB6KQDC","subject":"GON-127 babysitter.gate PASS","body":"<json below>","hop_count":1,"chain_id":"01KRCM2P5N1XYHFT9G3VB6KQDC"}
```

`body`:
```json
{
  "id": "01KRCMK4WGAR3T8Z5X9YPN1EHV",
  "ts": "2026-05-12T09:42:55.001Z",
  "from": "captain",
  "to": "galileo",
  "chain_id": "01KRCM2P5N1XYHFT9G3VB6KQDC",
  "hop_count": 1,
  "reply_to": "01KRCM2P5N1XYHFT9G3VB6KQDC",
  "type": "babysitter.gate",
  "subject": "GON-127 babysitter.gate PASS",
  "verdict": "pass",
  "evidence": {
    "logs": ["babysitter:frontend-dev-gon-127", "/workspace/agents/.a5c/runs/gon-127/journal.ndjson"],
    "tests": ["lint", "build", "qa:functional", "qa:visual", "qa:quality"],
    "commit_sha": "a3f9c12e5d1b"
  }
}
```

---

## 9. Authoring checklist for agent prompts

When you author an agent prompt (`.claude/agents/*.md`) that must return an envelope, the prompt MUST:

1. Tell the agent which `type` to emit at which gate.
2. List the required fields for that `type` (copy the row from §4).
3. Show one full example (transport + body) cloned from §8.
4. Note that the agent calls `bus-send.mjs` (or the agent-bus `send` tool) with `to`, `body` (the squad JSON, stringified), `subject`, and `reply_to` — the transport `id`, `ts`, `hop_count`, `chain_id` are minted/computed by the bus, not by the agent.

---

## 10. References

- Transport implementation + validation: `plugins/agent-bus-marketplace/agent-bus/server.ts`
- Bus live state: `/var/lib/warroom-bus/messages.ndjson`, `/var/lib/warroom-bus/trips.ndjson` (on the Go-North VM)
- Spec sources: `.a5c/processes/warroom-bus-bridge-paperclip-plan-output/FINAL-PLAN.md` (Plan-B Phase 1 Deliverable 8, plus §§2-6, 10 of `phase2-improved-plan.md`)
- Deviations: `PLAN-A-MV-DONE-EVIDENCE.md` §4 (Telegram BLOCKED coverage gap)
