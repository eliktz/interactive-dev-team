# Multi-Squad Operations Manual

> The operator manual for running N agent squads on one VM from one repo checkout.
> Model: **compose-project-per-squad** — one canonical `docker-compose.yml` template,
> one squad = one compose project (`-p <slug>`), all per-squad state in
> `/srv/squads/<slug>/` (outside every git tree).
>
> Onboarding lives in [`squadctl`](../squadctl) (see also [REPRODUCING.md](../REPRODUCING.md));
> migrating the original single-squad stack is [deploy/MIGRATION_GONORTH.md](../deploy/MIGRATION_GONORTH.md).

---

## 1. Naming — one slug derives everything

Slug rules: `^[a-z][a-z0-9-]{1,22}$` (compose project-name safe). Tenant #1's slug is `gonorth`.

**Slug guidance:** pick a short bare name (`acme`, `probe`) — every container, volume,
network and URL carries the slug, so redundant prefixes like `squad-` only add noise.
The E2E acceptance run used slug `probe` (kept as the canonical example everywhere:
this doc, `squadctl help`, `deploy/templates/squad.env.test`).

| Resource | Naming template | `gonorth` example | `acme` example |
|---|---|---|---|
| Squad slug | `<slug>` | `gonorth` | `acme` |
| Compose project | `-p <slug>` (= `COMPOSE_PROJECT_NAME` in the squad `.env`) | `gonorth` | `acme` |
| Containers (derived — no `container_name:` anywhere) | `<slug>-<service>-1` | `gonorth-war-room-1`, `gonorth-warroom2-1`, `gonorth-paperclip-1`, `gonorth-playwright-1` | `acme-war-room-1`, … |
| Network (derived) | `<slug>_default` | `gonorth_default` | `acme_default` |
| Named volumes (derived) | `<slug>_<volume>` | `gonorth_war-room-state`, `gonorth_paperclip-data`, `gonorth_project-repo`, `gonorth_warroom2-state` | `acme_war-room-state`, … |
| Instance dir (`SQUAD_HOME`) | `/srv/squads/<slug>/` | `/srv/squads/gonorth/` | `/srv/squads/acme/` |
| Squad env file | `/srv/squads/<slug>/.env` (0600) | `/srv/squads/gonorth/.env` | `/srv/squads/acme/.env` |
| Squad config (roster, paperclip.md, mcp) | `/srv/squads/<slug>/config/` | `/srv/squads/gonorth/config/agents.json` | `/srv/squads/acme/config/agents.json` |
| Squad personas | `/srv/squads/<slug>/agents/<agent>/` | `/srv/squads/gonorth/agents/ceo-gonorth/` | `/srv/squads/acme/agents/captain/` |
| Squad private (extra tokens, ops creds) | `/srv/squads/<slug>/private/` | `/srv/squads/gonorth/private/agent-tokens.env` | `/srv/squads/acme/private/agent-tokens.env` |
| Squad bus | `/srv/squads/<slug>/bus/` (→ `/workspace/agent-bus` in war-room AND warroom2) | `/srv/squads/gonorth/bus/messages.ndjson` | `/srv/squads/acme/bus/messages.ndjson` |
| Squad companies (AGENTS.md instruction files, → `/paperclip/companies` ro) | `/srv/squads/<slug>/companies/` | `/srv/squads/gonorth/companies/` | `/srv/squads/acme/companies/` |
| Squad project scratch (scaffolded; the project clone itself lives in the `<slug>_project-repo` volume) | `/srv/squads/<slug>/project/` | `/srv/squads/gonorth/project/` | `/srv/squads/acme/project/` |
| Caddy snippet | `/srv/squads/<slug>/caddy.snippet` | `/srv/squads/gonorth/caddy.snippet` | `/srv/squads/acme/caddy.snippet` |
| Backups | `/srv/squads/<slug>/backups/` | `/srv/squads/gonorth/backups/` | `/srv/squads/acme/backups/` |
| Port block (loopback-only) | `SQUAD_PORT_BASE = 7700 + 100·i`; dash=`+1`, paperclip=`+2`, playwright=`+3` | grandfathered: 7682 / 3100 / 8931 (3100 pinned by the existing `paperclip.tlk.solutions` Caddy route) | base 7800 → 7801 / 7802 / 7803 |
| URLs | `http://{dash,paperclip}.<slug>.localhost:8800` | `dash.gonorth.localhost:8800` | `dash.acme.localhost:8800` |
| tmux session (container-internal — needs no per-squad name) | `war-room` | `war-room` | `war-room` |
| Day-2 verbs | `docker compose -p <slug> …` / `./squadctl <verb> <slug>` | `./squadctl logs gonorth war-room` | `./squadctl status acme` |
| Built images (shared across squads) | `warroom/<service>:latest` via `image:` + `build:` | `warroom/war-room:latest` | same image — no per-squad rebuild |

Permissions: `/srv/squads/` owned `<vm-user>:<vm-user>` (on the platform VM: `ravi:ravi`),
each squad dir `0750 <vm-user>:caddy` — group `caddy` so the host Caddy's
`import /srv/squads/*/caddy.snippet` glob (ExecReload runs as `User=caddy`) can traverse
the dir and read the snippet; `squadctl new` applies the chgrp. `.env` 0600,
`private/` + `backups/` 0700, `bus/` 0770 (all enforced by `squadctl new`).

---

## 2. URLs + access — one SSH tunnel for every squad

Name-based routing through ONE tunnel, served by the **existing host Caddy**.
Nothing is internet-facing: every squad port binds `127.0.0.1` only.

```bash
# once per session — the only tunnel needed, for every squad:
ssh -p 22 -L 8800:127.0.0.1:8800 <vm-user>@<vm-host>

# then in the browser:
http://dash.gonorth.localhost:8800        # gonorth war-room dashboard (basic-auth)
http://paperclip.gonorth.localhost:8800   # gonorth Paperclip UI
http://dash.acme.localhost:8800           # second squad — same tunnel, zero extra flags
http://paperclip.acme.localhost:8800
```

Browsers resolve `*.localhost` to loopback natively (RFC 6761) — no `/etc/hosts`, no
dnsmasq. The Host header survives the tunnel, so one loopback listener routes every
squad by name.

`./squadctl url <slug>` prints the squad's URLs plus a copy-pasteable tunnel line.
The tunnel target defaults to `$USER@$(hostname)`; set **`SQUADCTL_SSH_TARGET=<vm-user>@<vm-host>`**
(e.g. in your shell profile) so the printed line is correct from any machine.

**How it's wired:** the host Caddy gets exactly one extra site block —

```caddyfile
http://:8800 {
    bind 127.0.0.1
    import /srv/squads/*/caddy.snippet
}
```

> **NOT `http://127.0.0.1:8800 { … }`** (E2E finding F2): in Caddy semantics a host in
> the site address is a *Host-header matcher* — that form only matches requests whose
> Host **is** `127.0.0.1`, so `dash.<slug>.localhost` never reaches the snippets (every
> squad URL returns Caddy's hollow empty 200) — and it leaves the listener on `*:8800`.
> `http://:8800` + `bind 127.0.0.1` matches any Host while listening on loopback only.

— and each squad's `caddy.snippet` (host-matchers → `reverse_proxy 127.0.0.1:<port>`)
is rendered by `squadctl new` / re-rendered by `squadctl apply`, followed by
`systemctl reload caddy` (squadctl uses `sudo -n` when non-root and prints the manual
command + sudoers one-liner if passwordless sudo is missing). The squad dir + snippet
are `chgrp caddy` by `squadctl new` so the import glob, which runs as `User=caddy`,
can actually read them (E2E finding F3). `./squadctl doctor` verifies each snippet is
**loaded in the running Caddy** (admin API `127.0.0.1:2019/config/`), not just present
on disk. Existing Caddy site blocks are untouched.

**Auth:** basic-auth lives inside warroom2 (`WARROOM2_BASIC_AUTH_*`, per-squad realm).
The dashboard's terminal WebSocket is unauthenticated by operator decision — with all
squad ports loopback-bound it is reachable only through the SSH tunnel.

**Fallback:** direct port tunneling still works
(`ssh -L 7682:127.0.0.1:7682 <vm-user>@<vm-host>`) — raw ports are in each squad's
`.env` and printed by `./squadctl url <slug>`.

---

## 3. Onboarding a squad

```bash
./squadctl new acme
```

That validates the slug, allocates a free port block, scaffolds `/srv/squads/acme/`
(`.env` from `deploy/templates/squad.env.template`, config + captain persona seeds,
`private/ bus/ backups/`, caddy.snippet + reload), generates the per-squad secrets
(basic-auth pass, admin token, `BETTER_AUTH_SECRET`), prompts (skippably) for a captain
Telegram token + group ID, and runs the **staged bring-up**:

1. `up -d --build paperclip playwright`
2. `scripts/setup-company.sh` registers the Paperclip company and writes
   `PAPERCLIP_COMPANY_ID` back into the squad `.env`
3. `up -d --no-deps war-room warroom2` — war-room boots with the company ID already
   in its env; `--no-deps` keeps stage 3 from chain-recreating paperclip

**Paperclip deployment mode (E2E finding F4):** squad paperclips default to
`PAPERCLIP_DEPLOYMENT_MODE=local_trusted` (set in the squad `.env` from the template) —
required for stage 2 to work at all: in `authenticated` mode a fresh instance has zero
instance admins and `setup-company.sh`'s unauthenticated `/api/companies` calls 403
(bootstrap would need the full sign-up → bootstrap-CEO invite → accept dance). This is
security-equivalent at squad exposure: every squad port binds `127.0.0.1` only, behind
the SSH tunnel. Set `authenticated` ONLY for instances exposed beyond loopback —
tenant #1 (`gonorth`, public `paperclip.tlk.solutions`) pins it in its `.env`.
`setup-company.sh` sends `Origin == Host` on every call (paperclip's board-mutation
guard requires it), so it also works against already-bootstrapped authenticated
instances given a valid session.

Full fresh-host walkthrough (prerequisites, what to fill, what's not in the repo):
[REPRODUCING.md](../REPRODUCING.md).

---

## 4. Day-2 runbook

The old single-squad ceremony (`git pull → compose build <svc> → compose up -d --no-deps <svc>`)
generalizes by inserting `-p <slug> --env-file /srv/squads/<slug>/.env` — which is exactly
what `squadctl` wraps so nobody types it raw.

### Upgrade all squads

On your workstation: edit → commit → push origin. On the VM:

```bash
cd ~/interactive-dev-team && git pull --ff-only && ./squadctl upgrade --all
```

Images build once (shared `warroom/<svc>:latest` tags); each project reconciles with a
staged `up -d --no-deps` (paperclip+playwright, health-wait, then war-room+warroom2).
war-room recreation restarts agents; they resume via `--continue` — schedule in a quiet
window, or roll only the dashboard with `./squadctl apply <slug> warroom2`
(`--no-deps` hardwired).

### Logs

```bash
./squadctl logs acme war-room        # or: docker compose -p acme logs -f war-room
```

### Restart one agent

```bash
./squadctl respawn acme 2            # respawns tmux window 2 inside acme-war-room-1
```

### Restart / recreate one service

- `./squadctl restart <slug> [svc]` — `compose restart`: no recreate, **no env reload**.
- `./squadctl apply <slug> [svc]` — the env-reload path: re-renders `caddy.snippet`
  from the (possibly edited) `.env`, then `up -d --no-deps <svc>`. **Whenever a single
  service is targeted, `--no-deps` is mandatory** — `squadctl` hardwires it; if you type
  raw compose, type `--no-deps` yourself (a bare `up -d <svc>` chain-recreates the
  services it depends on).

### Reconcile the VM checkout with origin

Post-migration the VM tree is *clean by construction* — agents write only under
`/srv/squads/` — so reconcile is just `git pull --ff-only`. **Pre-migration legacy rule
still applies:** on any VM checkout, run

```bash
git checkout -- config/paperclip.md
```

**first** — agents have repeatedly self-edited that file to re-add the literal Paperclip
admin credential, and a dirty tree with a credential in it must never survive a pull.

### Backup

```bash
./squadctl backup acme               # → /srv/squads/acme/backups/<date>/
```

Tars the squad home (config, agents, private, .env — minus bus evidence) plus the named
volumes (`war-room-state` = the Claude OAuth that must not be lost, `paperclip-data`,
`warroom2-state`) via a throwaway alpine. Copying backups off-VM remains the operator's
job until `private/` gets a remote (known follow-up).

### Late-filled Telegram group

A squad can boot with `SQUAD_TELEGRAM_GROUP_ID` empty (agents run, group routing off —
launch.sh writes a minimal operator-DM-only `access.json` instead of skipping creation).
To activate the group later:

```bash
$EDITOR /srv/squads/<slug>/.env       # fill SQUAD_TELEGRAM_GROUP_ID
./squadctl apply <slug> war-room
```

`apply` knows that launch.sh creates `access.json` only-if-missing: when the group ID is
now non-empty it first purges the stale operator-DM-only `access.json` files from the
`<slug>_war-room-state` volume (only files whose `"groups"` map is empty — populated or
hand-merged files are never clobbered), so the recreate regenerates them WITH the group.
No hidden dead state.

### Roster change

Dashboard wizard (writes to `$SQUAD_HOME/config` + `$SQUAD_HOME/agents`) →
`./squadctl apply <slug> war-room`. Extra agents' Telegram tokens go in
`/srv/squads/<slug>/private/agent-tokens.env` (0600, `KEY=value` lines matching each
agent's `token_env` in `config/agents.json`; loaded by launch.sh at boot — file wins
over env).

### Fleet view + health

```bash
./squadctl ls          # slug → ports → URLs → running-count, plus docker compose ls
./squadctl doctor      # snippets↔.env drift, loopback listeners, 0.0.0.0 binds,
                       # container health, the 4 platform containers, disk/RAM headroom
```

---

## 5. Capacity — RAM is the budget

- The VM has ~12 GiB and **no swap** — the failure mode is the OOM-killer, not slowness.
- Every service carries `deploy.resources.limits` ceilings, parameterized per squad
  (`WAR_ROOM_MEM` default 2.5g — gonorth runs 3g for 3 agents + yefet; `PAPERCLIP_MEM`
  1.25g; `PLAYWRIGHT_MEM` 768m; `WARROOM2_MEM` 384m). Ceilings, not reservations:
  3 squads quiet ≈ 6.6 GiB — fits; the limits stop one squad's runaway Claude/Chromium
  from OOM-killing the host.
- **Hard rule: max ~3 squads on this VM.** `squadctl new` warns at the 3rd squad and
  refuses a 4th without `--force`. A 4th squad means a second VM (explicit non-goal here).
- `./squadctl doctor` reports RAM headroom; check it before onboarding a squad.

---

## 6. NEVER use `--remove-orphans`

> **NEVER pass `--remove-orphans` to any compose command on this VM. Not once. Not
> "to clean up".**

Four containers on the VM are **orphans by compose's definition but load-bearing in
production** — they belong to no current compose service yet the platform depends on
them:

1. `openclaw` (`interactive-dev-team-openclaw-1`) — yefet; the host cron execs into it
   and tenant #1's dashboard has an exec tab targeting it (`SQUAD_OPENCLAW_CONTAINER`).
2. `agency-tick` — scheduled agency heartbeat.
3. `claim-watcher` — claim processing watcher.
4. `deploy-webhook` — host Caddy routes `:80/bitbucket` to it (port 9000); Bitbucket
   pushes stop deploying the moment it dies.

A single compose call carrying `--remove-orphans` deletes all four. The flag appears
nowhere in `squadctl` by construction (`grep -c 'remove-orphans' squadctl` → 0 is a
release gate), and `./squadctl doctor` verifies the four are still running. Follow-up (out of scope here):
adopt them into a dedicated `platform` compose project so the trap ceases to exist.

---

## 7. The docker socket — rationale and the proxy opt-in

warroom2 genuinely needs `docker exec` (the dashboard terminal is a PTY attach into the
squad's war-room container). Two modes exist:

### Default (every squad, day one): raw socket, read-only

The template mounts `${WARROOM2_DOCKER_SOCK:-/var/run/docker.sock}:/var/run/docker.sock:ro`
into warroom2. This is today's working topology — a fresh squad's terminal works on
first boot, unconditionally. Scoping comes from squad-only exec-target env
(`WARROOM2_WARROOM_CONTAINER=<slug>-war-room-1`), per-squad basic-auth, loopback-only
ports, and the SSH tunnel. Residual risk, accepted: warroom2 holds a read-only socket
mount — the same exposure as the original single-squad stack, no worse; in this mode
squad isolation at the socket is env-scoped, not kernel-enforced.

### Opt-in hardening (per squad): the `socket-proxy` compose profile

A per-squad Tecnativa `docker-socket-proxy` (HAProxy) with a custom ACL drop-in
([`deploy/docker-proxy/haproxy.cfg`](../deploy/docker-proxy/haproxy.cfg)) that denies
`containers/create`, `images`, `build`, `volumes`, `networks`, `swarm`, … and restricts
exec/inspect to container names matching `SQUAD_EXEC_ALLOW_REGEX` (default
`<slug>-[a-z0-9-]+`; gonorth's extends it with `interactive-dev-team-openclaw-1`).
To enable for one squad: set `WARROOM2_DOCKER_SOCK=/dev/null` +
`WARROOM2_DOCKER_HOST=tcp://docker-proxy:2375` in the squad `.env` and add
`--profile socket-proxy` to that squad's compose invocations.

**Empirical gate verdict: PASS — but engine-specific.** Docker's exec-attach protocol is
an HTTP connection **hijack** (`Upgrade: tcp`), which HAProxy cannot be assumed to
relay. The M5 gate (`scripts/test-socket-proxy-exec.sh`, run 2026-06-11 against local
docker 28.5.2 / HAProxy 3.2.4) **PASSED in both modes** — real-PTY `docker exec -it`
and plain `docker exec -i` round-tripped through the proxy. Full record incl. the pinned
image digest: [`deploy/docker-proxy/EXEC_TEST_RESULT.md`](../deploy/docker-proxy/EXEC_TEST_RESULT.md).
That PASS is empirical for that engine/image combination, **not contractual** —
**re-run `scripts/test-socket-proxy-exec.sh` on the VM (and after every engine or proxy
image upgrade) before enabling the profile for any squad.** If it fails there, stay on
the default raw-socket mode — the terminal must never break on first boot.

Note even under the proxy: exec into the squad's *own* containers as `-u root` still
passes (the exec API carries the user in the request body, which HAProxy doesn't parse).

### Never `docker exec` as root in Paperclip workspaces

> **Standing operator rule:** never `docker exec -u root` (or as any non-default user)
> inside Paperclip workspace directories. Root-created files break the agents' git push
> (`fatal: detected dubious ownership` / EACCES) and have repeatedly bricked agent
> lanes. Exec as the container's default user, always.

---

## 8. Secret hygiene

- **Geometry, not .gitignore:** everything agents can write (`config/`, `agents/`,
  `private/`, the bus) bind-mounts from `/srv/squads/<slug>/` — not inside any git
  working tree. There is nothing to `git add`. The VM checkout is operator-owned
  platform code agents have no write mount into.
- **Defense in depth:** `scripts/secret-scan-pre-push.sh` (generic patterns — Telegram
  token shape, `sk-ant-`, AWS keys, PEM blocks, password-assignment shapes; the known
  leaked credential matched by SHA-256 digest, never embedded). launch.sh installs it as
  `.git/hooks/pre-push` in the project-repo clone inside war-room at boot — the one
  remote agents can push to. For any *additional* clone an agent creates, install it
  manually:

  ```bash
  cp /workspace/scripts/secret-scan-pre-push.sh <clone>/.git/hooks/pre-push \
    && chmod +x <clone>/.git/hooks/pre-push
  ```

  (Follow-up: bake a git template dir into the war-room image so every clone gets the
  hook automatically.) Audit any tree manually with
  `scripts/secret-scan-pre-push.sh --scan-tree [rev]`.
- **Scoped blast radius:** per-squad bots, basic-auth realm, admin token, Paperclip
  instance + `BETTER_AUTH_SECRET` — rotating one squad never touches another.
