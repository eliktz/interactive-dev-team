# Adding a new company to the war-room

This document is the operator playbook for spinning up a brand-new company
namespace using the M5 templates.

## TL;DR

```bash
ssh -p 22 ravi@34.165.241.86
cd /home/ravi/interactive-dev-team
bash scripts/bootstrap-company.sh <slug> \
  --language en \
  --north-star "what your product is for the user" \
  --display-name "Acme Co" \
  --telegram-group-id "-100..." \
  --operator-tz "Asia/Jerusalem"
```

`<slug>` must be lowercase alphanumeric + dashes. The script creates:

- `companies/<slug>/COMPANY.md` — roster + operator preferences
- `companies/<slug>/PRODUCT-SPINE.md` — mission, themes, milestones (filled in later)
- `companies/<slug>/company.yml` — machine-readable manifest
- `companies/<slug>/bootstrap.log` — what the script did
- `agents/<slug>-{ceo,captain,ux}/` — three default personas, each with
  IDENTITY.md, SOUL.md, AGENTS.md, TOOLS.md, CLAUDE.md, `.claude/settings.json`,
  and a copy of the canonical hooks (`session-start.sh`, `pre-compact.sh`,
  `session-end.sh`, `user-prompt-submit.sh`, `stop-append-activity.sh`,
  `pre-tool-use-signed-chrome.sh`)

The war-room container bind-mounts `/home/ravi/interactive-dev-team` to
`/workspace` read-write, so the new persona dirs are visible immediately —
no container restart needed.

## What the script does NOT do (operator follow-up)

1. **Telegram bots.** Create one bot per persona via @BotFather, store the
   tokens in env, and attach all three to the operator group. The
   `telegram_group_id` you passed is recorded in `companies/<slug>/company.yml`
   for reference but no API call is made.
2. **L5 policy ack.** Sign `companies/_template/L5-POLICY-ACK.md.tmpl`
   for the operator and place it under `companies/<slug>/`.
3. **PRODUCT-SPINE.md content.** The template ships with `{{TODO}}`-style
   placeholders. Edit the spine to fill in Mission, Themes (3–5 named
   themes), Milestones, Current State by lane.
4. **Paperclip company row.** If `psql` is on `$PATH` and
   `PAPERCLIP_PG_URL` is reachable, the script inserts a row into the
   `companies` table. From the host (no psql) you need to run the insert
   via the paperclip container:
   ```bash
   ID=$(grep paperclip_company_id companies/<slug>/company.yml | sed -E 's/.*"([^"]+)".*/\1/')
   docker exec interactive-dev-team-paperclip-1 \
     psql postgresql://paperclip:paperclip@127.0.0.1:54329/paperclip \
     -c "INSERT INTO companies (id, name, status) VALUES ('$ID', '<Display Name>', 'active') ON CONFLICT (id) DO NOTHING"
   ```

## Verification

After bootstrap, smoke-test the SessionStart hook:

```bash
docker exec interactive-dev-team-war-room-1 sh -c \
  "echo {} | bash /workspace/agents/<slug>-ceo/hooks/session-start.sh" \
  | jq .hookSpecificOutput.additionalContext | head -20
```

The output must start with `## When to speak`. The persona prefix and the
acme product spine should follow.

Validate JSON:

```bash
docker exec interactive-dev-team-war-room-1 sh -c \
  "for p in <slug>-ceo <slug>-captain <slug>-ux; do \
     jq . /workspace/agents/\$p/.claude/settings.json >/dev/null \
       && echo \$p OK; done"
```

## Teardown

```bash
bash scripts/teardown-company.sh <slug>
```

This:
1. Snapshots `companies/<slug>/` and `agents/<slug>-*/` to
   `_backups/teardown-<slug>-<ts>.tar.gz`.
2. Removes the on-disk directories.
3. Soft-archives the paperclip company row (`status='archived'`)
   if `psql` is reachable.
4. Soft-archives `team_memory` rows for that company id.

The `go-north` and `_template` slugs are protected and cannot be torn down.

## Customizing the persona roster

The default 3 personas (ceo, captain, ux) are baked into
`scripts/bootstrap-company.sh`. To add a fourth persona for a specific
company:

1. Add an entry to `companies/<slug>/company.yml` under `persona_list:`.
2. Render the persona dir manually by re-using the same template
   substitutions (see the `render` function in `bootstrap-company.sh`).
3. Update `companies/<slug>/COMPANY.md` roster table.

A general-purpose 4th-persona flag is on the QG5 backlog.
