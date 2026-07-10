# Codi (קודי) — the Codex/GPT Telegram agent pilot (war-room platform)

> **What this documents:** the first **non-Claude agent** on the war-room platform — "Codi", an
> OpenAI **Codex CLI**-backed Telegram agent, stood up by Liran on the multi-squad VM on
> **2026-07-10** as a pilot proving the platform is model-agnostic. Everything below was read
> live from the VM (`codex-lab-1` container) the same day. **No secrets are reproduced here.**
>
> **TL;DR of the design:** a ~4 KB dependency-free Node script (`bridge.js`) long-polls the
> Telegram Bot API, and for each operator DM runs **`codex exec`** (resuming a persistent
> thread) with a **JSON output schema** `{reaction, format, reply}`; it then sets an emoji
> reaction and sends the reply. Persona comes from **`AGENTS.md`** (Codex reads it natively from
> cwd), long-term memory is a **`memory/MEMORY.md`** file the persona tells the model to
> read/append. That's the whole trick — no MCP, no channel plugin, no framework.

---

## 1. Where it runs

| Item | Value |
|---|---|
| Container | **`codex-lab-1`** on the multi-squad VM (`34.165.241.86`) |
| Image | `warroom/war-room:latest` (the standard war-room image — reused as a sandbox) |
| Compose identity | project `gonorth`, service `war-room` (labels) — i.e. spun from the gonorth compose as a one-off; **not** in the standard 4-agent tmux roster |
| Entrypoint | `sleep infinity` (lab container; everything inside started by hand) |
| Restart policy | `unless-stopped` |
| Health | **unhealthy** (expected — the war-room image healthcheck probes the normal launch stack, which isn't running here) |
| Inside | tmux session **`codi`** with 2 windows: `bash` (manual work) and `bridge` (runs `node bridge.js 2>&1 | tee /tmp/bridge.log`) |
| Created | 2026-07-10 04:17 UTC; codex login 04:26; bridge v3 by 05:57 |

**Nothing is bind-mounted** — the container is self-contained; all state lives inside it (see §8
for the replication caveat this implies).

## 2. The pieces (5 files total)

```
/home/claude/codi/                     # the agent's working dir ("trusted" codex project)
├── bridge.js                          # Telegram <-> codex bridge (v3, ~4KB, zero npm deps)
├── AGENTS.md                          # persona — Codex CLI reads this natively from cwd
├── schema.json                        # forced JSON output shape {reaction, format, reply}
└── memory/MEMORY.md                   # long-term memory (persona-driven read/append)

/home/claude/.claude/channels/telegram-codi/   # state dir (mirrors the CC channel-dir shape)
├── .env                               # TELEGRAM_BOT_TOKEN=... (0600)
├── access.json                        # (vestigial — bridge enforces its own ACL)
├── bridge-offset                      # Telegram getUpdates offset (resume-safe)
└── thread-id                          # persistent codex thread id (conversation continuity)

/home/claude/.codex/
├── auth.json                          # auth_mode = "chatgpt" (ChatGPT-account login, not API key)
└── config.toml                        # sandbox/approval config (below)
```

### Codex CLI runtime

- **codex-cli 0.144.1** at `/usr/local/bin/codex` (installed into the container; NOT part of the war-room image).
- **Auth:** `codex login` with a **ChatGPT account** (`auth.json` has `auth_mode: "chatgpt"`) —
  i.e. subscription-backed, the Codex analog of our operator-OAuth-token pattern. No Azure, no
  API key. (The old per-squad `config/codex-config.toml` Azure files relate to the retired
  Paperclip path — irrelevant here.)
- **`~/.codex/config.toml`:**
  ```toml
  sandbox_mode = "workspace-write"
  approval_policy = "never"

  [projects."/home/claude/codi"]
  trust_level = "trusted"
  ```

## 3. The bridge (the heart — read this to replicate)

`bridge.js` v3 — "thread continuity + memory files + reaction/format". Dependency-free Node
(only `https`, `child_process`, `fs`). Flow per message:

1. **Long-poll** `getUpdates` (25 s timeout), persisting the offset to `bridge-offset` after each
   update (crash-safe resume, no double-processing).
2. **ACL, hard:** only messages where `from.id === OPERATOR` (Liran's numeric id) **and**
   `chat.type === 'private'` are processed. Everything else is dropped — so today Codi is
   **operator-DM-only**, not in any group.
3. Send `sendChatAction: typing` (UX nicety).
4. **Run codex** (the core):
   ```js
   const base = ['--dangerously-bypass-approvals-and-sandbox', '--json',
                 '--skip-git-repo-check', '--output-schema', SCHEMA];
   const args = threadId
     ? ['exec', 'resume', threadId, ...base, text]     // continue the persistent conversation
     : ['exec', ...base, text];                        // first message → new thread
   execFileSync('codex', args, { cwd: HOME, timeout: 180000, maxBuffer: 20MB });
   ```
   - `cwd: HOME` makes Codex pick up **`AGENTS.md`** (persona) automatically and gives
     workspace-write over `codi/` (which is how `memory/` works).
   - `--output-schema schema.json` **forces** the model's final message to be
     `{"reaction","format","reply"}` — no fragile text parsing.
   - Output is `--json` JSONL; the bridge scans lines for:
     - `thread.started` → capture `thread_id` (saved to `thread-id` on first run), and
     - `item.completed` with `item.type === 'agent_message'` → `JSON.parse(item.text)` = the
       structured reply.
5. **React first, then reply:** `setMessageReaction` with the schema's `reaction` (validated
   against Telegram's legal reaction set — invalid → fallback 👀), then `sendMessage` with
   `parse_mode: MarkdownV2` when `format === "markdownv2"`, **falling back to plain text if the
   MarkdownV2 send fails** (escaping errors are the #1 MarkdownV2 failure mode — the fallback
   makes them non-fatal).
6. On any codex error → apologetic Hebrew fallback reply + 👀.

### Conversation continuity (the clever bit)
`codex exec resume <thread_id>` continues one **persistent server-side thread** across bridge
restarts and container days — so within the thread Codi "already remembers everything" and no
transcript reconstruction is needed. The thread id is one 36-char file. To reset the
conversation: delete `thread-id`.

### Long-term memory (cross-thread)
`memory/MEMORY.md` + persona instructions: *read it at conversation start; append concise
lasting facts (curated facts, not transcripts)*. Enforced purely by prompt + `workspace-write`
sandbox. Verified working — the file already contains an appended operator preference.

## 4. The persona (`AGENTS.md`) — what it encodes

- **Identity:** "Codi (קודי)", explicitly framed as *"the first non-Claude agent on this
  platform (all others run on Claude Code). You prove the platform is model-agnostic."*
- **Operator:** Liran (@liranka) — single human authority.
- **Telegram etiquette (the same lessons our CC agents learned, ported):**
  - *React first* with one tone-matched emoji, then reply.
  - **Only Telegram-legal reactions** (👀 ❤ 🔥 🎉 👏 🫡 🙏 👍 😁 🤩 💯 ⚡ 🏆 🤣 😴) — anything else
    fails the API call; default 👀/🫡.
  - **Group rules pre-written** (silence unless addressed; one responder; no pile-on) — i.e. the
    persona is *ready* for the shared-group/bot-to-bot fabric even though the bridge doesn't
    join a group yet.
  - MarkdownV2 escaping rules; Hebrew default; Israel-time timestamps.
- **Pilot honesty clause:** if a tool isn't wired, say so and report to Liran — don't pretend.
- **Structured-reply contract** restated in the persona AND enforced by `--output-schema`
  (belt + suspenders: the model is told the shape, and the CLI validates it).

`schema.json` (complete):
```json
{ "type": "object", "additionalProperties": false,
  "properties": {
    "reaction": { "type": "string", "enum": ["👀","❤","🔥","🎉","👏","🫡","🙏","👍","😁","🤩","💯","⚡","🏆","🤣","😴"] },
    "format":   { "type": "string", "enum": ["markdownv2", "text"] },
    "reply":    { "type": "string" }
  },
  "required": ["reaction", "format", "reply"] }
```

## 5. How this compares to the Claude agents on the same platform

| Dimension | CC agents (Musk/Boris/Leo/Iris…) | **Codi (codex pilot)** |
|---|---|---|
| Session model | long-running `claude --continue` in tmux, channel plugin injects turns | **one-shot `codex exec resume <thread>` per message**; continuity is server-side thread state |
| Telegram inbound | official `telegram@0.0.6` channel plugin (bun `server.ts` poller) | **hand-rolled 4 KB `bridge.js` long-poll** |
| Persona | `--append-system-prompt-file` / CLAUDE.md loader | **`AGENTS.md` in cwd** (Codex-native convention) |
| Reply formatting | plugin reply tool | schema-forced `{reaction, format, reply}` + direct Bot API calls |
| ACL | `access.json` (pairing/allowlist, groups) | hardcoded operator-id + DM-only in bridge |
| Group / bot-to-bot | shared supergroup + BotFather Bot-to-Bot Mode + privacy-off | **not yet** (DM-only; persona group-rules pre-staged) |
| Auth | Claude operator OAuth | **ChatGPT-account `codex login`** |
| Memory | CC session state + per-agent `.claude/` | codex thread (in-conversation) + `memory/MEMORY.md` (long-term) |
| Supervision | start.sh restart loop + healthcheck | **none** (tmux window + tee log; bridge dies silently) |

The architecture equivalence to note: **this is Archetype B ("CLI-spawn-per-thread") from our
CC↔Slack taxonomy**, applied to Telegram + Codex — vs the CC agents' Archetype A
(channel-plugin). Codex has no channel-plugin contract, so B is the natural fit — exactly the
asymmetry we predicted in the DeeperDive bundle's `SLACK-AS-CLAUDE-CODEX-BUS.md`.

## 6. Current limitations (as-found, day-one pilot)

1. **DM-only, single operator** — hardcoded `OPERATOR` id; not in the squad group; no
   bot-to-bot participation yet (BotFather Bot-to-Bot Mode + privacy-off + group handling in the
   bridge would be needed — persona is already written for it).
2. **No supervision** — `node bridge.js` runs bare in a tmux window; if it crashes, Codi goes
   silent with no restart loop, no watchdog, no alert. (The war-room start.sh pattern was NOT
   ported.)
3. **Serial + blocking** — `execFileSync` handles one message at a time; a long `codex exec`
   (up to the 180 s timeout) blocks the poll loop; messages queue in Telegram.
4. **`--dangerously-bypass-approvals-and-sandbox`** — full-trust execution inside the
   container. Acceptable for a lab container with nothing mounted; NOT acceptable pattern for a
   squad container with workspace/repo mounts.
5. **Nothing persisted outside the container** — no bind mounts; `docker rm` loses auth,
   thread, memory, bridge. The 5 files above ARE the agent.
6. **Container reports unhealthy** — cosmetic (wrong healthcheck for this use), but it pollutes
   `docker ps` signal and would page any naive monitor.

## 7. Replication runbook (do this to stand up your own "Codi")

Prereqs: a Docker host, a NEW Telegram bot token from @BotFather, a ChatGPT account with Codex
access, your own Telegram numeric user id.

1. **Container (or any Linux box/pod):**
   ```bash
   docker run -d --name codex-lab --restart unless-stopped --entrypoint sleep \
     <any node-capable image> infinity
   docker exec -it codex-lab bash
   ```
   (On the VM they reused `warroom/war-room:latest` for familiarity; any image with Node ≥ 20
   works. For a durable agent add a volume for `/home/<user>` — see limitation #5.)
2. **Install + auth Codex CLI** (inside):
   ```bash
   npm i -g @openai/codex        # → codex-cli (pilot ran 0.144.1)
   codex login                    # ChatGPT-account device flow; writes ~/.codex/auth.json
   ```
3. **Working dir + config:**
   ```bash
   mkdir -p ~/codi/memory ~/.claude/channels/telegram-codi
   printf 'TELEGRAM_BOT_TOKEN=<your-new-bot-token>\n' > ~/.claude/channels/telegram-codi/.env
   chmod 600 ~/.claude/channels/telegram-codi/.env
   cat > ~/.codex/config.toml <<'EOF'
   sandbox_mode = "workspace-write"
   approval_policy = "never"
   [projects."/home/<user>/codi"]
   trust_level = "trusted"
   EOF
   ```
4. **Drop the 3 content files** into `~/codi/`: `AGENTS.md` (persona — copy §4's structure,
   swap identity/operator), `schema.json` (verbatim from §4), `bridge.js` (verbatim from the
   container — change `OPERATOR` to your Telegram id and `HOME`/`STATE` paths). Seed
   `memory/MEMORY.md` with a header line.
5. **Run it under tmux:**
   ```bash
   tmux new -d -s codi -n bridge "cd ~/codi && node bridge.js 2>&1 | tee /tmp/bridge.log"
   ```
6. **Test:** DM the bot. Expect: emoji reaction on your message + a reply; `thread-id` file
   appears after the first exchange; `tail -f /tmp/bridge.log` shows
   `msg / new thread / react|fmt|replied` lines.
7. **Hardening beyond the pilot** (recommended before real use): wrap step 5 in a
   crash-backoff restart loop (port `agents/*/start.sh`); replace `execFileSync` with async
   exec + per-chat queue; drop `--dangerously-bypass-approvals-and-sandbox` in favor of the
   config-file sandbox (`workspace-write` already suffices when cwd is trusted); volume-mount
   `~/.codex` + `~/codi` + the state dir; and if joining the squad group — enable **Bot-to-Bot
   Communication Mode** in BotFather + disable Group Privacy, then extend the bridge's filter
   beyond DM (the persona's group rules are already written).

## 8. Why this matters (platform + DeeperDive implications)

- **Proof the war-room platform is model-agnostic** — an agent's contract is just
  *Telegram bot + persona file + working dir + memory file*; the reasoning engine behind it is
  swappable. Total integration surface: ~4 KB of glue.
- **Validates the DeeperDive bundle's Codex-phase-2 shape** (`DECISIONS-RESOLVED.md` A1): Codex
  joins as **CLI-spawn-per-message with server-side thread resume** (Archetype B), NOT as a
  channel-plugin peer — exactly what `knowledge/SLACK-AS-CLAUDE-CODEX-BUS.md` assumed. The
  `{reaction, format, reply}` output-schema trick is directly reusable for any Codex worker we
  wire (Telegram or Slack).
- **The `--output-schema` + `exec resume` pair is the load-bearing discovery:** structured
  machine-parseable replies with zero parsing fragility, and stateless one-shot invocations that
  still behave like a persistent agent.

---
*Compiled 2026-07-10 from live inspection of `codex-lab-1` (files, processes, tmux, logs) over
SSH. Secrets (bot token, auth.json contents) intentionally omitted. Author of the pilot: Liran
(remote DevOps). This doc lives alongside `docs/CODEX_MIGRATION.md` (the older, unrelated
Paperclip/Azure codex path).*
