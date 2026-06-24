# Cross-Squad Registry — how the admin becomes "aware of all companies"

The Platform Admin must know every company/squad on this VM. That awareness is
**generated at runtime from live state — never committed.** This repo is public; live
tenant data (slugs, ports, company names, health) belongs only on the VM, under `/srv`.

## Why generated, not stored
- **No tenant data in a public repo.** Committing a live "who's who" would leak the fleet
  shape and couple the repo to one machine's state.
- **Always current.** Squads come and go (`squadctl new` / `destroy`); a committed list
  goes stale immediately. Live enumeration of `/srv/squads/*` is the source of truth.
- **Single source of truth.** Each squad already declares itself in its `.env` (slug,
  ports) and its `companies/*/COMPANY.md` (company name) — the generator just reads them.

## How awareness is built
Run the generator at session start (and after any fleet change):

```
deploy/admin/bin/admin-registry.sh
```

It composes live state from:
- **`squadctl ls`** — the fleet (slug, port base, dashboard URL, running-container count).
- **`squadctl doctor`** (cheap fields) — health: load-bearing containers up, ports
  listening, caddy routes LOADED.
- **each `/srv/squads/<slug>/.env`** — `SQUAD_PORT_BASE` and the derived
  `SQUAD_DASH_PORT` / `SQUAD_PAPERCLIP_PORT` / `SQUAD_PLAYWRIGHT_PORT`, plus the slug.
- **each `/srv/squads/<slug>/companies/*/COMPANY.md`** — the `name:` / `slug:` from the
  YAML front-matter, to label each squad with its real company.
- **`/srv/platform-admin/`** — the admin's own home, listed alongside the squads (fixed
  dash port `7900`, route `admin.localhost`).

Output is a concise fleet table to stdout: slug, dash/paperclip/playwright ports, URL,
company name(s), and a health hint. **No secret VALUES ever appear** — the generator reads
only port and slug/name keys from `.env`, never tokens/passwords/keys.

## Reading the output
- **gonorth** will show off-grid ports (base ~7600) and is the only internet-exposed
  paperclip — it is grandfathered; do not assume the 7700 formula for it (see RUNBOOK).
- A squad with a company name of `?` has no `COMPANY.md` yet — create one (RUNBOOK §A.5).
- A dead/unloaded caddy route means the URL is not live even if the snippet is on disk —
  fix the host reload and re-check with `doctor`.

The persona (`AGENTS.md`) instructs you to run this at session start so your understanding
of the fleet always reflects **live** state, not a stale committed snapshot.
