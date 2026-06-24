# Admin Console — single-tab, cross-squad platform admin

> One browser tab — same look and feel as a squad war-room dashboard — that drives a
> **single Claude admin agent** with full `squadctl` + Docker reach. From this one screen a
> live operator can **create new companies** and **debug/fix any squad**, while the existing
> load-bearing containers and every live squad stay untouched.
>
> Onboarding/day-2 of individual squads is [`squadctl`](../squadctl) +
> [docs/MULTI_SQUAD.md](MULTI_SQUAD.md); this page is the admin console that runs *above* the
> squads.

---

## 1. What it is

The admin console is its **own, dedicated, load-bearing compose project** named
`platform-admin` — deliberately separate from the squad `docker-compose.yml` so that no
squad-scoped `squadctl <verb> <slug>` (which is always `-p <slug>`) can ever see, recreate, or
prune it. The project has three containers:

| Container | Image | Role |
|---|---|---|
| `platform-admin` | `warroom/platform-admin:latest` | The agent. tmux + one Claude Code agent (`--dangerously-skip-permissions`), `squadctl` on `PATH`, the repo mounted **read-only**, `/srv/squads` + `/srv/platform-admin` **read-write**, Docker via the admin socket-proxy. Runs `network_mode: host`. The load-bearing piece. |
| `admin-warroom2` | `warroom/warroom2:latest` | The view — the stock warroom2 dashboard image (no rebuild), pointed by env at the `platform-admin` container's tmux window. A single "Platform Admin" tab. |
| `admin-docker-proxy` | `tecnativa/docker-socket-proxy:latest` | A second, admin-only socket-proxy with a broader ACL (`deploy/docker-proxy/haproxy.admin.cfg`), published on the host loopback `127.0.0.1:2380`. |

All three names are registered in `SQUADCTL_PLATFORM_CONTAINERS` so `squadctl doctor` tracks
them and no squad bring-up can ever touch them. The full load-bearing set is now **seven**:
the original four (`openclaw`, `agency-tick`, `claim-watcher`, `deploy-webhook`) plus these three.

### The single tab

The dashboard is served at **`http://admin.localhost:7900`** internally
(`ADMIN_DASH_PORT`/`SQUAD_DASH_PORT=7900`, loopback-only) and reached through the **existing**
SSH tunnel at `http://admin.localhost:8800` — the host Caddy routes by Host header, so no new
port-forward is needed:

```bash
ssh -p 22 -L 8800:127.0.0.1:8800 <vm-user>@<vm-host>
# browser: http://admin.localhost:8800   (basic-auth)
```

`admin.localhost` resolves to loopback natively (RFC 6761). The tab is a PTY attach onto the
admin agent's tmux window — the operator types `squadctl` verbs there; there is no Telegram,
no bus, no multi-agent chat.

---

## 2. The two capabilities

### CREATE a new company

The operator types in the tab; the admin agent runs `./squadctl new <slug>`. Because the
container exports `SQUADCTL_NO_BUILD=1`, the staged bring-up uses the prebuilt shared
`warroom/*:latest` images (`up -d`, **no** `--build`) — so no BUILD call is ever issued to
the BUILD-denied proxy. Because the agent runs `network_mode: host`, `127.0.0.1` *is* the host
loopback, so `squadctl`'s paperclip health-checks and `setup-company.sh` reach the
freshly-published squad paperclip exactly as a host-run `squadctl` would. Secrets are generated
by `squadctl` straight into the squad's `0600 .env`; the caddy snippet is rendered and reloaded
host-side; `squadctl doctor` polls the caddy admin API to confirm the route is loaded.

New squads default to **authenticated paperclip with self-bootstrap** — see §5.

### DEBUG / FIX a squad

The operator types `./squadctl doctor` / `status` / `logs` / `apply` / `respawn` / `upgrade`.
Read verbs (`ps`, `logs`, `stats`, exec for respawn) and write verbs (`up --no-deps`,
`down -v` on destroy, throwaway `docker run` for apply-sweep/backup) all route through the admin
proxy, which permits the full container/network/volume surface. None of these can touch the
load-bearing seven (separate project) and none carry `--remove-orphans`.

---

## 3. Security posture — be honest

> **`platform-admin` is a host-equivalent trust boundary.** `network_mode: host` + the right
> to create containers + a host-volume RW mount on `/srv` make the admin agent effectively
> **root on the VM**. The socket-proxy is **defense-in-depth, not a sandbox.**

What the broad socket-proxy actually buys is the removal of the highest-blast-radius API
surface — it **denies** `swarm | secrets | configs | plugins | system | distribution |
session | build` — and gives one auditable file (`deploy/docker-proxy/haproxy.admin.cfg`)
documenting exactly what the admin may call. It does **not** isolate the admin; with
host-create + host-net + `/srv` RW, isolation was never the proxy's job.

`build` stays denied because builds go **out-of-band** on the host (§4) and the BuildKit
`session` surface is fragile through any TCP proxy. The empirical proxy gate
(`scripts/test-socket-proxy-exec.sh`, recorded in
[`deploy/docker-proxy/EXEC_TEST_RESULT.md`](../deploy/docker-proxy/EXEC_TEST_RESULT.md))
asserts the full `compose down -v` DELETE path (containers/networks/volumes = 204) and
`POST /build = 403` — because `destroy`/`apply` exercise DELETE, which a `create=201` alone does
not prove.

**Raw-socket fallback.** The owner may instead mount `/var/run/docker.sock` into
`platform-admin`, set `DOCKER_HOST=unix:///var/run/docker.sock`, and drop the
`admin-docker-proxy` service entirely (a one-line compose edit). The posture is **materially
the same** once host networking is on — you lose the residual API-surface deny and the audit
file, you gain one fewer container and zero TCP-proxy fragility.

**The real containment** is therefore: every admin port binds `127.0.0.1` only + HTTP Basic on
the dashboard + the single SSH tunnel. **Secrets live ONLY in `/srv/platform-admin/.env`
(mode 0600, owner `ravi:ravi`, never committed).** Treat the admin's credentials like root on
the VM.

---

## 4. Out-of-band image builds

The admin agent never builds. The shared `warroom/*:latest` images
(`war-room`, `paperclip`, `warroom2`, `platform-admin`) are built **out-of-band on the host**
by [`deploy/admin/bin/admin-host-build.sh`](../deploy/admin/bin/admin-host-build.sh) (run as
`ravi`, `docker compose build`) **before** an `upgrade`. The admin runs with
`SQUADCTL_NO_BUILD=1`, so `squadctl new`/`upgrade` never attempt a build through the proxy:
`new` runs `up -d` (no `--build`) and `upgrade` skips its `build` stage entirely. A first-ever
bring-up on a fresh host with the images missing will fail with an obscure pull error — run the
host build first.

---

## 5. Authenticated paperclip default + self-bootstrap (new squads)

New squads created from the admin console (and via any `squadctl new`) default to
`PAPERCLIP_DEPLOYMENT_MODE=authenticated`. This is the only mode compatible with the container
topology: `docker-compose.yml` binds the paperclip process to `HOST=0.0.0.0` so the published
`127.0.0.1:<pc_port>:3100` forward can reach it, and paperclip **rejects** `local_trusted` on a
non-loopback bind (`local_trusted mode requires loopback host binding`) — that combination
crash-loops a fresh squad's paperclip.

A fresh `authenticated` instance starts with zero instance admins, so **stage 2
(`setup-company.sh`) bootstraps the first instance admin itself**, entirely from inside the
squad over supported surfaces: it creates a one-time `bootstrap_ceo` invite via paperclip's own
`@paperclipai/db` module, signs up an admin user (credential generated locally and recorded in
`private/paperclip-admin.env`, mode 0600), accepts the invite to promote it, then registers the
company/agents with that session. The step is idempotent and a no-op for legacy `local_trusted`
instances. See [docs/MULTI_SQUAD.md §3](MULTI_SQUAD.md) for the full mechanism.

---

## 6. Bring-up / reproduce

> Builds happen **out-of-band on the host** — never through the admin. Stand up the admin
> project with `up -d --no-deps`, and **NEVER `--remove-orphans`** (it would delete the
> load-bearing seven).

1. **Build the admin image out-of-band (host, as `ravi`):**
   ```bash
   cd ~/interactive-dev-team
   deploy/admin/bin/admin-host-build.sh         # builds warroom/platform-admin:latest (+ shared images)
   ```

2. **Render the out-of-repo env file** from the committed template (placeholders only) into
   the 0600 file outside git:
   ```bash
   sudo mkdir -p /srv/platform-admin && sudo chown "$USER":caddy /srv/platform-admin
   sudo chmod 0750 /srv/platform-admin
   install -m 0600 deploy/admin/admin.env.template /srv/platform-admin/.env
   $EDITOR /srv/platform-admin/.env             # fill WARROOM2_BASIC_AUTH_PASS (openssl rand -hex 16), etc.
   chmod 0600 /srv/platform-admin/.env
   ```

3. **Seed `/srv/platform-admin`** (config + persona, out-of-repo, from the sanitized seeds):
   ```bash
   mkdir -p /srv/platform-admin/{config,agents/admin,bus}
   cp deploy/templates/admin-seed/config/agents.json   /srv/platform-admin/config/
   cp deploy/templates/admin-seed/admin/*.md           /srv/platform-admin/agents/admin/
   ```
   `bus/` must exist (compose mounts it) even though a tmux-only roster never reads it.

4. **Add the Caddyfile import** — one line, separate from the squad glob (the admin owns its
   own import; it must NOT live under `/srv/squads/*`). Inside the existing loopback site block
   in `/etc/caddy/Caddyfile`:
   ```caddyfile
   http://:8800 {
       bind 127.0.0.1
       import /srv/squads/*/caddy.snippet        # squads (glob)
       import /srv/platform-admin/caddy.snippet  # admin (EXPLICIT)
   }
   ```
   Copy the snippet out-of-repo (group-readable so caddy can traverse):
   ```bash
   install -m 0640 -g caddy deploy/templates/admin.caddy.snippet /srv/platform-admin/caddy.snippet
   sudo caddy validate --config /etc/caddy/Caddyfile && sudo systemctl reload caddy
   ```

5. **Install the caddy-reload path-unit** so a rendered snippet becomes a live route without a
   manual reload (host-side; the container has no host systemd):
   ```bash
   sudo cp deploy/admin/bin/admin-caddy-reload.path    /etc/systemd/system/
   sudo cp deploy/admin/bin/admin-caddy-reload.service /etc/systemd/system/
   sudo systemctl daemon-reload
   sudo systemctl enable --now admin-caddy-reload.path
   ```
   (Pair with a scoped `/etc/sudoers.d/squadctl-caddy` granting passwordless
   `systemctl reload caddy` + the `chgrp caddy` grant.)

6. **Bring up the admin project** (own project name, out-of-repo env file, no orphans):
   ```bash
   docker compose -p platform-admin \
     --env-file /srv/platform-admin/.env \
     -f deploy/admin/docker-compose.admin.yml up -d --no-deps
   # NEVER --remove-orphans — it owns ONLY platform-admin + admin-warroom2 + admin-docker-proxy
   ```

7. **Register the names** so `squadctl doctor` tracks them and no squad bring-up sees them — in
   the operator's shell profile on the VM AND in the admin service env (already set in the
   compose file):
   ```bash
   export SQUADCTL_PLATFORM_CONTAINERS="openclaw agency-tick claim-watcher deploy-webhook \
     platform-admin admin-docker-proxy admin-warroom2"
   ```

8. **First-boot login** — open `http://admin.localhost:8800`, and in the tab complete the
   claude.ai `/login` once (or set `ANTHROPIC_API_KEY` in the env file). The token persists in
   the `platform-admin-state` volume.

> **RAM hard gate (swapless VM).** The admin adds ~1.2 GiB (agent 768m + warroom2 384m +
> proxy 64m). Before standing up a **3rd squad alongside the admin**, verify headroom with
> `free -m` on the VM — there is no swap, so the failure mode is the OOM-killer. Default to
> **max 2 squads + admin** until headroom is confirmed. See [REPRODUCING.md](../REPRODUCING.md).

---

## 7. Files

**In the repo:**
- `deploy/admin/docker-compose.admin.yml` — the 3-container `platform-admin` project.
- `deploy/admin/Dockerfile.admin` — agent image (Claude native-install discipline + docker CLI/compose; copies `tmux.conf` for `base-index 1`).
- `deploy/admin/entrypoint.admin.sh` — single-window tmux + the admin agent (skip-permissions).
- `deploy/admin/admin.env.template` — env NAMES/placeholders only (real values → `/srv/platform-admin/.env`).
- `deploy/admin/bin/admin-host-build.sh` — out-of-band image build helper (host-side).
- `deploy/admin/bin/admin-caddy-reload.path` / `.service` — host path-unit reload trigger.
- `deploy/admin/bin/admin-registry.sh` — runtime cross-squad "who's who" generator.
- `deploy/docker-proxy/haproxy.admin.cfg` — the broad admin ACL (denies build/swarm/secrets/configs/plugins/system/distribution/session).
- `deploy/templates/admin-seed/` — sanitized persona + roster seeds (copied out-of-repo).
- `deploy/templates/admin.caddy.snippet` — the committed `admin.localhost` snippet template.
- `scripts/assert-admin-window.sh` — static check: entrypoint tmux window == `agents.json` window.

**Out-of-repo (operator creates on the VM, NEVER committed):**
- `/srv/platform-admin/.env` (0600), `config/agents.json`, `agents/admin/{AGENTS,RUNBOOK}.md`,
  `bus/` (empty), `caddy.snippet` (chgrp caddy).
- The host Caddyfile `import` line + the host reload trigger (path-unit/sudoers).

---

## 8. See also

- Per-squad operations: [docs/MULTI_SQUAD.md](MULTI_SQUAD.md)
- Fresh-host bring-up (incl. the admin RAM gate): [REPRODUCING.md](../REPRODUCING.md)
- The proxy gate verdict: [deploy/docker-proxy/EXEC_TEST_RESULT.md](../deploy/docker-proxy/EXEC_TEST_RESULT.md)
