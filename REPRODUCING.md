# Reproducing — fresh-host bring-up

How to go from a clean Linux host to a running agent squad. Everything secret or
host-specific lives **outside** this repo; this page tells you exactly what gets created
where, and by what.

## 1. Prerequisites

- **Docker Engine with Compose v2** (`docker compose version` works). The compose
  template uses profiles, `deploy.resources.limits`, and env-file interpolation —
  Compose v2 is required, v1 will not work.
- **git** (cloning this repo + the project repo inside the war-room container).
- **openssl** (used by `squadctl new` to generate per-squad secrets).
- **Host Caddy — optional.** Needed only for the nice name-based URLs
  (`http://dash.<slug>.localhost:8800`). Without it, direct port tunneling works fine
  (see §6). If you install it, add this one site block to `/etc/caddy/Caddyfile`:

  ```caddyfile
  http://127.0.0.1:8800 {
      import /srv/squads/*/caddy.snippet
  }
  ```

  then `sudo caddy validate --config /etc/caddy/Caddyfile && sudo systemctl reload caddy`.
- An **LLM provider** for the agents: the default is claude.ai OAuth (you log in once,
  interactively, after first boot — Pro/Max/Team plan required for Telegram channels);
  alternatives are `ANTHROPIC_API_KEY` or AWS Bedrock creds in the squad `.env`.
- **Telegram bot token(s)** — optional at bring-up; agents run CLI-only without them.

## 2. Clone

```bash
git clone <this-repo-url> ~/interactive-dev-team
cd ~/interactive-dev-team
sudo mkdir -p /srv/squads && sudo chown "$USER" /srv/squads
```

The checkout is operator-owned platform code only. Agents never get a write mount into
it, and no secret is ever written into it.

## 3. Onboard a squad — `squadctl new` walkthrough

```bash
./squadctl new acme
```

What happens, in order:

1. **Slug validated** (`^[a-z][a-z0-9-]{1,22}$`, not taken) and a **port block
   allocated** (`7700 + 100·i`, loopback-only).
2. **`/srv/squads/acme/` scaffolded**: `.env` (0600, from
   `deploy/templates/squad.env.template`), `config/` (single-captain `agents.json`,
   credential-free `paperclip.md`, mcp + codex settings — from
   `deploy/templates/config-seed/`), `agents/captain/` (starter persona from
   `deploy/templates/agents-seed/`), `private/` `bus/` `backups/` `companies/`
   `project/`, and `caddy.snippet` (+ caddy reload when caddy is present).
3. **Per-squad secrets generated** (never echoed): `WARROOM2_BASIC_AUTH_PASS`,
   `WARROOM2_ADMIN_TOKEN`, `BETTER_AUTH_SECRET`.
4. **Prompts** (TTY only; both skippable; flags `--token-file` / `--group-id` for
   scripts; `--no-input` to never prompt):
   - *Captain Telegram bot token* — create a bot via **@BotFather** (`/newbot`), paste
     the token. Skip = the captain runs CLI-only.
   - *Telegram group ID* — the supergroup where the squad collaborates. Skip = fill
     `SQUAD_TELEGRAM_GROUP_ID` later, then `./squadctl apply acme war-room`.
5. **Staged bring-up** (skipped with `--no-up`): paperclip + playwright come up first,
   `scripts/setup-company.sh` registers the Paperclip company and writes
   `PAPERCLIP_COMPANY_ID` into the squad `.env`, then war-room + warroom2 come up
   (`--no-deps`) with the ID already in their env. No manual edits, no post-hoc restart.

Then fill before first real use (printed by `squadctl` too) in `/srv/squads/acme/.env`:

- `PROJECT_REPO_URL` (+ `BITBUCKET_TOKEN`) — the project repo war-room clones into
  `/workspace/project`.
- `OPERATOR_TELEGRAM_ID` — your personal Telegram user ID (DM notifications; get it
  from @userinfobot).
- LLM provider keys if not using claude.ai OAuth.

Apply `.env` edits with `./squadctl apply acme war-room` (restart alone does NOT reload
env).

First-boot login (claude.ai OAuth path): open the dashboard terminal (or
`docker exec -it acme-war-room-1 claude`) and run `/login` once — the token persists in
the `acme_war-room-state` volume.

## 4. What is NOT in the repo — and how each piece gets created

| Missing from the repo | Created by | Lives at |
|---|---|---|
| Squad `.env` (all secrets + ports + identity) | `squadctl new` (template + generated secrets + your prompts) | `/srv/squads/<slug>/.env` (0600) |
| `private/` (agent Telegram tokens beyond the captain's, Paperclip ops creds) | `squadctl new` scaffolds placeholders; you fill them | `/srv/squads/<slug>/private/` (0700) |
| Squad config + personas (roster, paperclip.md, agent prompts) | `squadctl new` seeds; the dashboard wizard + agents edit at runtime | `/srv/squads/<slug>/{config,agents}/` |
| Agent bus journal | `squadctl new` (empty dir); war-room writes | `/srv/squads/<slug>/bus/` |
| Caddy snippet + the `:8800` import block | snippet: `squadctl new`/`apply`; import block: you, once (§1) | `/srv/squads/<slug>/caddy.snippet`, `/etc/caddy/Caddyfile` |
| Docker named volumes (Claude OAuth, Paperclip DB, project clone, dashboard state) | `docker compose up` on first bring-up | `<slug>_{war-room-state,paperclip-data,project-repo,warroom2-state}` |
| `PAPERCLIP_COMPANY_ID` | `scripts/setup-company.sh` during the staged bring-up | written back into the squad `.env` |
| claude.ai OAuth token | you, once, via `/login` in the agent terminal | inside `<slug>_war-room-state` |
| Telegram bot tokens / group ID | you, via @BotFather / your group | squad `.env` + `private/agent-tokens.env` |

There is deliberately no global secret, and the repo ships placeholders only
(`.env.example` is a signpost; **`deploy/templates/squad.env.template` is the real,
authoritative variable list**).

## 5. Verify

```bash
./squadctl status acme     # compose ps + memory vs limits
./squadctl ls              # fleet view
./squadctl doctor          # ports, snippets, binds, headroom
./squadctl logs acme war-room
```

## 6. Access — SSH tunnel pattern

Nothing is internet-facing (every port binds `127.0.0.1`). One tunnel serves every
squad on the host:

```bash
ssh -p 22 -L 8800:127.0.0.1:8800 <user>@<vm-host>
# browser: http://dash.acme.localhost:8800  ·  http://paperclip.acme.localhost:8800
```

Set `SQUADCTL_SSH_TARGET=<user>@<vm-host>` so `./squadctl url <slug>` prints the exact
tunnel line. No-Caddy fallback: tunnel the raw squad ports directly, e.g.
`ssh -L 7801:127.0.0.1:7801 <user>@<vm-host>` → `http://localhost:7801` (ports are in
the squad `.env` and printed by `./squadctl url`).

## 7. More

- Operating N squads day-2 (upgrades, backups, capacity, hard warnings):
  [docs/MULTI_SQUAD.md](docs/MULTI_SQUAD.md)
- Migrating a pre-multi-tenancy single-squad install:
  [deploy/MIGRATION_GONORTH.md](deploy/MIGRATION_GONORTH.md)
- Telegram bot creation details: [docs/telegram-setup.md](docs/telegram-setup.md)
