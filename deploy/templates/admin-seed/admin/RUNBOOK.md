# Platform Runbook

The operational core for the Platform Admin. Sanitized for a public repo: **env-var
NAMES only, never values.** Read the HARD RULES in `AGENTS.md` first — they apply to
every command below.

You operate from the read-only repo mount at `/workspace/interactive-dev-team`; `squadctl`
is on your PATH (symlinked into that mount). The only writable data root is `/srv`.

---

## squadctl verbs

`squadctl` is the platform CLI: onboarding + day-2 ops for N squads on one VM. Always
prefer a verb over raw `docker` — the verbs hardwire the safe flags (`--no-deps`, no
`--remove-orphans`, typed-slug confirmations).

| Verb | What it does | When to use |
|------|--------------|-------------|
| `new <slug>` | Scaffolds `/srv/squads/<slug>/`, allocates a free port block, generates secrets into the 0600 `.env`, renders `caddy.snippet`, staged bring-up. | Onboard a new company. See §A. |
| `ls` | Fleet view: slug, port base, dashboard URL, running-container count. | Quick "what's on this box". |
| `status <slug>` | `compose ps` + `docker stats` (memory vs limits, CPU) for the squad. | Health/resource triage of one squad. |
| `logs <slug> [svc]` | Follows logs (`-f --tail 200`; default all services). | Triage a failing service. |
| `restart <slug> [svc]` | `compose restart` — **same container, NO env reload, no recreate.** | Kick a wedged process; NOT for `.env` changes. |
| `apply <slug> [svc]` | Re-renders derived files (incl. caddy snippet) + recreates ONE service with `--no-deps` (default `war-room`). **This is the env-reload path.** | After editing `/srv/squads/<slug>/.env`. |
| `upgrade <slug>` / `--all` | `git ff-only pull` + rolling `up -d`. Under `SQUADCTL_NO_BUILD=1` (you) it SKIPS the build stage and uses the prebuilt `warroom/*:latest`. | Roll a squad onto new code/images (host-built first). |
| `respawn <slug> <window>` | `tmux respawn-window` of one agent inside `<slug>-war-room-1` (window number = dashboard tab). | Restart a hung/looping agent without touching containers. |
| `stop <slug>` | `compose stop` — containers preserved. | Pause a squad, keep its state. |
| `start <slug>` | `compose start` — bring stopped containers back. | Resume a paused squad. |
| `backup <slug>` | Tars squad home (config/agents/private/.env) + volume snapshots into `backups/`. | Before risky changes / destroy. |
| `url <slug>` | Prints the squad URLs + the SSH tunnel one-liner. | Hand a working URL to the operator. |
| `doctor` | Platform health: ports listening, load-bearing containers up, caddy snippets present AND **LOADED** (polls caddy admin API `127.0.0.1:2019`), per-squad container health. | Start and END of every task. |
| `destroy <slug>` | Tears down a squad (`compose down`; volumes + instance dir unless `--keep-data`). **Typed-slug confirmation** (skip only with `--force`). | Decommission a squad. |

Useful flags: `--no-input` (never prompt), `--no-up` (`new`: scaffold only), `--port-base N`
(`new`: pin the block), `--token-file PATH` (`new`: read the Telegram token from a file —
NEVER pass a token as argv), `--group-id ID`, `--keep-data` / `--force` (`destroy`).

---

## Port scheme

`squadctl` allocates a 100-wide block per squad by scanning `/srv/squads/*/.env` for the
next free `SQUAD_PORT_BASE`:

```
SQUAD_PORT_BASE = 7700 + 100*i          # i = 0,1,2,... (first free block)
  dash       = SQUAD_PORT_BASE + 1       # SQUAD_DASH_PORT       (warroom2 dashboard)
  paperclip  = SQUAD_PORT_BASE + 2       # SQUAD_PAPERCLIP_PORT
  playwright = SQUAD_PORT_BASE + 3       # SQUAD_PLAYWRIGHT_PORT
admin dash   = 7900                      # the platform-admin dashboard (fixed)
```

All ports publish on **host loopback** (`127.0.0.1:<port>`). Caddy routes by Host header
(`dash.<slug>.localhost`, `admin.localhost`) to those loopback ports; the operator reaches
everything through the single SSH tunnel (`-L 8800:127.0.0.1:8800`).

**gonorth is grandfathered — DO NOT apply the 7700 formula to it.** Tenant #1 (gonorth)
sits on off-grid ports (base **7600** region) and is the **only internet-exposed paperclip**
on this box. When reasoning about gonorth, read its real ports from its `.env` via the
registry; never assume the standard block.

---

## Instance-dir layout — `/srv/squads/<slug>/`

Everything a squad needs lives OUTSIDE git in its instance dir (created by `squadctl new`):

```
/srv/squads/<slug>/
  .env              # 0600 — the single interpolation source; ALL secret VALUES live here
  config/           # agents.json, paperclip.md, mcp/codex config (seeded from templates)
  agents/           # per-agent persona dirs (<persona>/AGENTS.md, SOUL.md, ...)
  private/          # 0700 — gitignored overlays: team.md, paperclip-ops.md, agent-tokens.env
  bus/              # agent-bus NDJSON journal (mounted even if unused)
  companies/        # companies/<company>/COMPANY.md — who this squad is (see below)
  project/          # the squad's project repo clone
  backups/          # 0700 — backup tarballs
  caddy.snippet     # rendered host route (chgrp caddy so caddy can read it)
```

The admin's own home is `/srv/platform-admin/` (same shape minus per-tenant noise):
`.env` (0600), `config/agents.json`, `agents/admin/{AGENTS,RUNBOOK}.md` + `registry.md`,
`bus/` (empty), `caddy.snippet` (route `admin.localhost`, imported explicitly into the host
Caddyfile — NOT via the `/srv/squads/*` glob).

### COMPANY.md convention
`/srv/squads/<slug>/companies/<company>/COMPANY.md` is the canonical "who is this squad"
doc — YAML front-matter (`slug`, `name`, `description`, `goals`) + a markdown body (mission,
quality standards, agent roster, conventions). The dashboard's `/api/company` reads it; the
registry generator reads its `name`/`slug` to label the fleet. Reference env-var NAMES only
inside it — it is public-repo-shaped.

---

## Deploy mechanism

- **Code:** push to origin → on the VM `git ff-only pull` (what `squadctl upgrade` runs).
- **Bring-up:** `squadctl new`/`upgrade` do a **staged** bring-up: `paperclip` + `playwright`
  first → `setup-company.sh` (registers the company in Paperclip, writes
  `PAPERCLIP_COMPANY_ID` back into the squad `.env`) → `war-room` + `warroom2` with
  `--no-deps`. Never `--remove-orphans`.
- **Images:** you run with `SQUADCTL_NO_BUILD=1`, so bring-up is `up -d` (no `--build`)
  against prebuilt shared `warroom/*:latest`. The **warroom2 frontend** in particular needs
  an image rebuild to pick up frontend changes — that rebuild is an **out-of-band host
  build**, never a proxy build.
- **Out-of-band host build:** when images must be (re)built, the operator runs on the HOST
  (as the VM user, not in this container):
  `deploy/admin/bin/admin-host-build.sh [--all|--admin|--squad]`
  THEN you run `./squadctl upgrade <slug>`.
- **Routing:** `squadctl` renders the `caddy.snippet` into `/srv`; a **host-side** reload
  trigger reloads caddy. You cannot reload caddy from here — verify LOADED state with
  `doctor`.

---

## Operational gotchas

- **`restart` ≠ env reload.** `compose restart` keeps the old env. To pick up `.env` edits
  use `apply` (recreates the service with `--no-deps`).
- **`up -d` reloads env, `restart`/`start` do NOT.** Single-service env refresh = `apply`.
- **Caddy reload is host-side.** Rendering a snippet from here does nothing to the running
  caddy until the host trigger fires. A new URL is "dead" until `doctor` shows the route
  LOADED in the caddy admin API. Never assert a URL works because the snippet exists.
- **`network_mode: host` on this container** is why `127.0.0.1` here IS the host loopback —
  that is what lets `squadctl` health-checks and `setup-company.sh` reach freshly-published
  squad paperclips at `127.0.0.1:<pc_port>`. Don't "fix" it.
- **The proxy is defense-in-depth, NOT a sandbox.** You are host-equivalent (see AGENTS.md).
- **Socket-proxy is fail-closed** (`build`/`swarm`/`secrets`/`configs`/`plugins`/`system`/
  `distribution`/`session` are denied). If a docker call 403s, that is by design — do it
  out-of-band on the host, don't try to route around it.
- **gonorth is special** (grandfathered ports, only exposed paperclip) — read its real
  values from the registry, never assume the 7700 formula.
- **paperclip.md credential leak** (see AGENTS.md) — keep credentials as env-var NAMES.
- **Secrets only in 0600 `.env`** — never argv, never the repo, never a file you write.

---

## RUNBOOK A — CREATE a new company

End state: a healthy squad reachable at `dash.<slug>.localhost`, all load-bearing
containers untouched.

1. **Survey.** Run `deploy/admin/bin/admin-registry.sh` and `./squadctl ls`. Confirm the
   `<slug>` is free and there is RAM headroom (swapless VM — default ceiling is **max 2
   squads + admin** until `free -m` headroom is confirmed; 3 only with verified headroom).
2. **Ensure images exist (host, out-of-band).** Confirm `warroom/war-room:latest`,
   `warroom/paperclip:latest`, `warroom/warroom2:latest` exist (`docker images | grep
   warroom/`). If missing, the operator runs `deploy/admin/bin/admin-host-build.sh` on the
   HOST first — under `SQUADCTL_NO_BUILD=1` `new` will `up -d` against a missing image with
   an obscure error otherwise.
3. **Scaffold + bring up.** `./squadctl new <slug>` — scaffolds `/srv/squads/<slug>/`,
   generates secrets straight into the 0600 `.env` (via `openssl rand`), renders the caddy
   snippet, runs the staged bring-up (paperclip+playwright → `setup-company.sh` →
   war-room+warroom2). Provide the Telegram token via `--token-file` (never argv) and
   `--group-id` if used.
4. **Caddy.** `squadctl new` renders the snippet into the `/srv` RW mount → the host reload
   trigger reloads caddy. If unattended reload is NOT configured, the run is INCOMPLETE:
   tell the operator to run the printed `sudo systemctl reload caddy` on the host.
5. **Write COMPANY.md.** Create `/srv/squads/<slug>/companies/<company>/COMPANY.md`
   (front-matter + mission/standards/roster/conventions, env-var NAMES only) so the
   dashboard and the registry can identify the squad.
6. **Verify with doctor.** `./squadctl doctor` — confirm: the `dash.<slug>.localhost` route
   is **LOADED** in caddy (admin-API poll), ports listening, new squad's containers healthy,
   and **all load-bearing containers still up**. If the route is not LOADED, the URL is dead
   — fix the host reload, re-`doctor`. Do not declare done on a snippet-only state.
7. **Hand off.** Open `http://dash.<slug>.localhost:8800` (basic-auth), confirm the tab
   attaches (not `_stale`), and log the war-room agents into claude.ai once.

---

## RUNBOOK B — DEBUG / FIX a squad

End state: the issue resolved AND `doctor` green with all load-bearing containers intact.
Every fix below ENDS with a `doctor` re-check.

1. **doctor (fleet) → status (one squad).** `./squadctl doctor` for the whole fleet, then
   `./squadctl status <slug>` (`compose ps` + memory/CPU vs limits) to localize.
2. **logs.** `./squadctl logs <slug> <svc>` (`-f --tail 200`) to see the actual failure.
3. **Fix forward, by class:**
   - **env / secret / port drift** → edit `/srv/squads/<slug>/.env` → `./squadctl apply
     <slug> <svc>` (env reload, `--no-deps`, re-renders + reloads caddy). → **doctor.**
   - **hung / looping agent** → `./squadctl respawn <slug> <window>` (tmux respawn of that
     dashboard tab's window). → **doctor.**
   - **caddy not routing** (snippet on disk but not LOADED) → `./squadctl apply <slug>`
     re-renders + triggers reload; if still not LOADED, the operator runs on the HOST
     `sudo chgrp caddy /srv/squads/<slug> /srv/squads/<slug>/caddy.snippet && sudo
     systemctl reload caddy`. → **doctor** (confirm route LOADED).
   - **image-level fix** → operator runs `deploy/admin/bin/admin-host-build.sh` on the HOST
     (out-of-band), THEN `./squadctl upgrade <slug>` (`--no-deps` staged, NO orphans, skips
     its own build under `SQUADCTL_NO_BUILD`). → **doctor.**
4. **Final doctor.** `./squadctl doctor` + a glance at `docker ps` — confirm the fix held,
   nothing else moved, and the load-bearing containers are all still up.
