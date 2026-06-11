# Migration checklist — go-north becomes tenant #1 (`gonorth`)

> Executable, numbered, every step has a rollback. Principle: prepare everything while
> the old stack runs; ONE short planned cutover (agents resume via `--continue`); the
> old project is left **stopped but intact** until soak passes.
>
> Run on the VM as the operator user, from the repo checkout (`~/interactive-dev-team`),
> unless a step says otherwise. `<vm-user>@<vm-host>` is the VM SSH target — never
> commit the literal values to this public repo.
>
> **Invariants for the whole migration:**
> - **NEVER `--remove-orphans`** — 4 load-bearing orphan containers (`openclaw`,
>   `agency-tick`, `claim-watcher`, `deploy-webhook`) die if you do. See
>   [docs/MULTI_SQUAD.md §6](../docs/MULTI_SQUAD.md).
> - **`--no-deps` whenever a single service is targeted** with `up -d` — a bare
>   `up -d <svc>` chain-recreates its `depends_on` services.
> - The 4 orphans are never touched by any step below.
> - Old volumes/dirs are copied, never moved, until step 7's 14-day window expires.

---

## Step 0 — Reconcile the dirty VM tree

The VM checkout has uncommitted agent self-edits, possibly including a re-added
credential. Order matters: credential drop FIRST, then preserve the rest as data.

```bash
cd ~/interactive-dev-team

# 0.1 Drop any re-added Paperclip credential — ALWAYS first on any VM checkout:
git checkout -- config/paperclip.md

# 0.2 Preserve the agent self-edits AS DATA (working-tree state, post-checkout),
#     into what will become the squad instance dir:
sudo mkdir -p /srv/squads/gonorth
sudo cp -a agents config /srv/squads/gonorth/
sudo chown -R "$USER":docker /srv/squads/gonorth

# 0.3 Clean the tree completely (self-edits are now safe in /srv/squads/gonorth/):
git stash -u            # belt-and-suspenders snapshot of anything else, kept in the stash
git checkout -- .
git status --porcelain  # MUST print nothing

# 0.4 Move to main (verified byte-identical to feat/warroom2 — re-verify):
git fetch
git diff main origin/feat/warroom2 --stat   # expect: empty
git checkout main && git pull --ff-only
```

**Rollback:** self-edits live in `/srv/squads/gonorth/` and in the stash
(`git stash pop`); the old branch still exists — `git checkout feat/warroom2` restores
the previous code state.

---

## Step 1 — Pull the post-milestone code

After the multi-tenancy branch merges to `origin/main`:

```bash
PRE_PULL_SHA=$(git rev-parse HEAD)   # record for rollback
git pull --ff-only
```

Old containers keep running their old images — nothing changes yet.

**Rollback:** `git reset --hard "$PRE_PULL_SHA"`.

---

## Step 2 — Scaffold tenant #1 without starting it

```bash
# Scaffold only (no docker). --port-base is numeric-only; gonorth's REAL ports are
# grandfathered and pinned by hand right after:
./squadctl new gonorth --no-input --no-up --port-base 7600
```

### 2.1 Pin the grandfathered ports

Edit `/srv/squads/gonorth/.env`:

```bash
SQUAD_DASH_PORT=7682
SQUAD_PAPERCLIP_PORT=3100      # pinned: the existing paperclip.tlk.solutions Caddy route targets 3100
SQUAD_PLAYWRIGHT_PORT=8931
```

Then update the two `reverse_proxy 127.0.0.1:<port>` lines in
`/srv/squads/gonorth/caddy.snippet` to `7682` (dash) and `3100` (paperclip) — the
snippet was rendered from the scaffold base. (Any later `./squadctl apply gonorth …`
re-renders it from `.env` automatically.)

### 2.2 Fill the rest of `/srv/squads/gonorth/.env` from the live values

Source the values from the old `.env` next to the old compose project and from
`/var/lib/openclaw/.env`:

| Key in `/srv/squads/gonorth/.env` | Value |
|---|---|
| `CAPTAIN_TELEGRAM_TOKEN` | current value (unchanged) |
| `SQUAD_TELEGRAM_GROUP_ID` | the old `GONORTH_GROUP_ID` value (launch.sh accepts it with or without the leading `-`) |
| `OPERATOR_TELEGRAM_ID` | current value |
| `PROJECT_REPO_URL` | the old `GONORTH_REPO_URL` value |
| `PROJECT_WORKSPACE_NAME` | `go-north-app` |
| `BITBUCKET_TOKEN` | current value |
| `WARROOM2_BASIC_AUTH_USER` / `_PASS` / `WARROOM2_ADMIN_TOKEN` | current values (keep — operators' saved logins survive) |
| `BETTER_AUTH_SECRET` | **MUST equal the current live value** — a new secret invalidates every Paperclip session |
| `PAPERCLIP_PUBLIC_URL` | keep the live public URL (`https://paperclip.tlk.solutions`) |
| `PAPERCLIP_ALLOWED_HOSTNAMES` | current value + `paperclip.gonorth.localhost` |
| `PAPERCLIP_COMPANY_ID` | `a951bb35-24a9-412a-bbcc-629c5acae619` (existing company — do NOT re-run setup-company.sh) |
| `AZURE_OPENAI_API_KEY` | current value |
| `SQUAD_OPENCLAW_CONTAINER` | `interactive-dev-team-openclaw-1` (keeps the yefet dashboard tab) |
| `SQUAD_EXEC_ALLOW_REGEX` | `(gonorth-[a-z0-9-]+\|interactive-dev-team-openclaw-1)` (only used if the socket-proxy opt-in is ever enabled) |
| `WAR_ROOM_MEM` | `3g` (3 agents + yefet — above the 2.5g default) |

### 2.3 Telegram agent tokens go in `private/agent-tokens.env`, NOT the squad `.env`

The generic template carries only `CAPTAIN_TELEGRAM_TOKEN`. gonorth's other two bots'
token env names are roster data (`token_env` in `config/agents.json`), so they move into
the file launch.sh loads at boot (file wins over env):

```bash
install -m 0600 /dev/null /srv/squads/gonorth/private/agent-tokens.env
$EDITOR /srv/squads/gonorth/private/agent-tokens.env
```

```
CEO_GONORTH_TELEGRAM_TOKEN=<current live value>
UX_GONORTH_TELEGRAM_TOKEN=<current live value>
```

These two envs were dropped from the compose template in the multi-tenancy work — the
squad `.env` route does NOT deliver them anymore; this file is the only path.

### 2.4 Copy `private/` and pre-build images

```bash
# private ops files (Paperclip admin creds etc.) from the old location:
cp -a <old-private-location>/. /srv/squads/gonorth/private/
chmod 0700 /srv/squads/gonorth/private

# pre-build so the cutover window doesn't pay for image builds:
docker compose -p gonorth --env-file /srv/squads/gonorth/.env build
```

**Rollback (whole step):** pure additive — `rm -rf /srv/squads/gonorth` reverts.
The live squad is untouched.

---

## Step 3 — Caddy prep

The snippet exists from step 2. Add the one import block to `/etc/caddy/Caddyfile`
(existing `paperclip.tlk.solutions` and `:80/bitbucket` blocks untouched):

```caddyfile
http://127.0.0.1:8800 {
    import /srv/squads/*/caddy.snippet
}
```

```bash
sudo caddy validate --config /etc/caddy/Caddyfile && sudo systemctl reload caddy
```

**Rollback:** remove the block, `systemctl reload caddy`. Validate-before-reload makes
this near-zero-risk.

---

## Step 4 — CUTOVER (downtime starts)

```bash
docker compose -p interactive-dev-team stop warroom2 war-room paperclip playwright
```

`stop`, not `down` — containers and volumes preserved; named services only; the 4
orphans are unaffected.

**Rollback (full pre-migration state in under a minute):**

```bash
docker compose -p interactive-dev-team start paperclip playwright war-room warroom2
```

---

## Step 5 — Copy state (volumes + bus), re-point openclaw at the live bus

### 5.1 Volumes — copy (project rename means new volume names; data is copied, never moved)

```bash
for v in war-room-state paperclip-data project-repo warroom2-state; do
  docker run --rm \
    -v interactive-dev-team_$v:/from:ro \
    -v gonorth_$v:/to \
    alpine sh -c 'cd /from && cp -a . /to'
done
```

`war-room-state` carries the Claude OAuth — the thing that must not be lost. The `-v`
flags auto-create the `gonorth_*` volumes; compose adopts them at step 6. (The
alternative — `external: name:` pinning of the old names in the compose file — was
rejected by the plan: it freezes the old naming forever and breaks the slug-derives-
everything rule. Copy is the strategy.)

### 5.2 Bus — copy, then re-point yefet/openclaw at the live bus

```bash
rsync -a /var/lib/warroom-bus/ /srv/squads/gonorth/bus/
```

**Without the re-point, post-cutover bus messages written to
`/srv/squads/gonorth/bus/` are invisible to yefet — silent comms severance.**
openclaw's RO bind is `/var/lib/openclaw/bus → /opt/openclaw-bus`; swing the host path
through a symlink and restart so the bind re-resolves:

```bash
sudo mv /var/lib/openclaw/bus /var/lib/openclaw/bus.premig
sudo ln -sfn /srv/squads/gonorth/bus /var/lib/openclaw/bus
docker restart interactive-dev-team-openclaw-1
```

**Rollback (bus):**

```bash
sudo rm /var/lib/openclaw/bus
sudo mv /var/lib/openclaw/bus.premig /var/lib/openclaw/bus
docker restart interactive-dev-team-openclaw-1
```

**Rollback (rest of step):** nothing was destroyed — old volumes and
`/var/lib/warroom-bus` are intact; step 4's rollback restores the old stack.

---

## Step 6 — Start tenant #1 and verify

```bash
docker compose -p gonorth --env-file /srv/squads/gonorth/.env up -d
```

(Full-project `up -d` — `--no-deps` is only for single-service targets.)

Verification checklist — ALL must pass:

```bash
# 1. all four services healthy:
docker compose -p gonorth ps

# 2. three agent windows up, agents resumed via --continue:
docker exec gonorth-war-room-1 tmux list-windows -t war-room
#    ... and Telegram-ping each of the 3 agents.

# 3. dashboard through the tunnel (ssh -p 22 -L 8800:127.0.0.1:8800 <vm-user>@<vm-host>):
#    http://dash.gonorth.localhost:8800   (basic-auth works, terminal PTY echoes typing)

# 4. public Paperclip still serves (host Caddy → 127.0.0.1:3100, now gonorth-paperclip-1):
curl -sI https://paperclip.tlk.solutions | head -1

# 5. yefet tab streams in the dashboard (exec target over the default raw socket).

# 6. BUS SYMLINK LIVE — append a probe line and confirm yefet/openclaw sees it:
echo '{"ts":"'$(date -u +%FT%TZ)'","from":"operator","type":"probe","text":"migration bus probe"}' \
  >> /srv/squads/gonorth/bus/messages.ndjson
docker exec interactive-dev-team-openclaw-1 tail -1 /opt/openclaw-bus/messages.ndjson
#    → must show the probe line.

# 7. platform invariants — orphans alive, cron + bitbucket webhook untouched:
docker ps --format '{{.Names}}' | grep -E 'openclaw|agency-tick|claim-watcher|deploy-webhook'
curl -sI http://127.0.0.1:9000 | head -1    # deploy-webhook still answering
```

**Rollback:** `docker compose -p gonorth down` (its volumes are copies — old data
untouched) + step 5.2's bus rollback + step 4's rollback.

---

## Step 7 — Soak 48 h, then decommission and rotate

Old project stays **stopped but intact** for 48 hours of green soak. Then:

```bash
# containers only — named services, and (as always) NO --remove-orphans, ever:
docker compose -p interactive-dev-team rm -s -f war-room warroom2 paperclip playwright
```

- Keep the old `interactive-dev-team_*` volumes and `/var/lib/warroom-bus` +
  `/var/lib/openclaw/bus.premig` **frozen for 14 days**, then archive into
  `/srv/squads/gonorth/backups/` and remove.
- **Rotate the leaked Paperclip admin password NOW** — `config/paperclip.md` finally
  lives out-of-tree (`/srv/squads/gonorth/config/`), so the rotation sticks. Update
  `/srv/squads/gonorth/private/paperclip-ops.md` with the new value.

**Rollback:** within the 14-day window a full reverse remains possible from the
preserved volumes (re-`start` is gone after `rm`, but `docker compose -p
interactive-dev-team up -d` from the pre-pull sha recreates against the old volumes).

---

## Expected downtime

Steps 4–6 ≈ 5–10 minutes (volume copy dominates; images pre-built in step 2, Caddy
pre-validated in step 3). Exactly one stack restart total; nothing restarts before
step 4.
