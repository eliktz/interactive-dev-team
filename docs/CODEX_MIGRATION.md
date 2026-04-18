# Codex Migration — Paperclip agents to Azure OpenAI

**Date**: 2026-04-18
**Status**: Live. All six Go-North Paperclip agents are running on `codex_local` + Azure OpenAI.
**Owner**: Platform (Elik Katz)

## Why

The Go-North Paperclip installation ran all six agents (Product Manager, Finance Officer, Frontend Dev, Backend Dev, QA Lead, UX Designer) through the `claude_local` adapter against the Anthropic API. As of mid-April 2026 the Anthropic quota for this installation was exhausted and the next refresh window put active development on hold.

Taboola has ample unused quota on its Azure OpenAI deployment (`tlk-agents-east-2`). Paperclip's `codex_local` adapter can target Azure via the Codex CLI's `model_provider` configuration, so migrating unblocks the team without paying Anthropic overage pricing.

## What changed

Three coordinated changes, plus repo-level configuration committed here:

1. **Paperclip control plane** — PATCH on each of the six agents to:
   - `adapterType: "codex_local"` (was `claude_local`)
   - `adapterConfig.model: "gpt-5.3-codex"` (was `claude-sonnet-4-6` or `claude-haiku-4-5-20251001`)
   - `adapterConfig.env.AZURE_OPENAI_API_KEY: "<key>"` — per-agent, so the Azure key is scoped to each agent's run env and does not need to be read from the container env
   - `adapterConfig.extraArgs: ["--skip-git-repo-check"]` — the Codex CLI refuses to run in a non-git directory by default, and the Paperclip working directory `/paperclip` is not a git repo
   - `adapterConfig.dangerouslyBypassApprovalsAndSandbox: true` translated from the `claude_local` flag `dangerouslySkipPermissions: true`. The field name is different between adapters; the meaning (auto-approve all tool invocations, disable the sandbox) is the same.
2. **Codex CLI config** — `config/codex-config.toml` bind-mounted into the Paperclip container at `/paperclip/.codex/config.toml`. Declares the `azure` model provider with the `/openai/v1` unified endpoint and `api-version=preview`.
3. **docker-compose.yml** — added `AZURE_OPENAI_API_KEY` to the paperclip service env block (container-wide fallback) and the codex-config.toml bind mount.

### Files touched in this commit

| Path | Change |
|------|--------|
| `config/codex-config.toml` | New — Codex CLI provider + model config |
| `docker-compose.yml` | Added `AZURE_OPENAI_API_KEY` env + `codex-config.toml` volume mount |
| `.env.example` | Added `AZURE_OPENAI_API_KEY` placeholder with note |
| `companies/go-north/.paperclip.yaml` | Flipped adapter_defaults + all six per-agent overrides |
| `config/paperclip.md` | Agent IDs table + new "Azure OpenAI configuration" section |
| `docs/CODEX_MIGRATION.md` | This file |

The actual API key is in `.env` (gitignored) and in the per-agent Paperclip DB records. It is **not** in this repo.

## Verification

The canary run was a trivial codebase-touching task (GON-20: add a timestamp comment to the Go-North migration runbook) assigned to the Backend Dev agent once it was flipped to `codex_local`.

| Metric | Value |
|--------|-------|
| Issue | GON-20 |
| Agent | Backend Developer (`2dea472e-8a43-4131-9d8c-2ba429adcb84`) |
| Model | `gpt-5.3-codex` (provider: openai, via Azure `tlk-agents-east-2`) |
| Duration | 190s |
| Exit code | 0 |
| Commit | `9ea535a` on `feature/GON-20-migration-timestamp-comment` |
| PR | #8 |
| Build | `pnpm install && pnpm build` — passed |

Heartbeat log showed the Codex CLI successfully resolving the Azure endpoint, invoking `responses` wire API, writing the expected diff, and pushing. No auth errors, no `--skip-git-repo-check` trips, no sandbox denials.

After the canary succeeded, the remaining five agents were patched and a smoke-check run was issued on each to confirm adapter health (listing files in `/workspace/project`, no git side effects).

## Known quirks

### `api-version = "preview"`

The Azure unified `/openai/v1` endpoint expects the literal string `preview` as `api-version`. Setting a dated version (`2025-04-01-preview`, etc.) returns:

```
HTTP/1.1 400 Bad Request
{"error": {"code": "InvalidApiVersion", ...}}
```

Do not "fix" this to a dated version. If Azure ever deprecates the `preview` alias, we will need to update to whatever they point the `/openai/v1` route at, but as of 2026-04-18 `preview` is correct.

### `--skip-git-repo-check`

The Codex CLI (v0.121.0 in our image) refuses to run in a non-git working directory unless `--skip-git-repo-check` is passed. The Paperclip working directory `/paperclip` is not a git repo; it is the Paperclip install root and holds agent instructions, run logs, and config. Agents' actual code work happens under `/workspace/project` which *is* a git repo, but the Codex CLI's cwd at launch is `/paperclip`.

Solution: every agent's `adapter_config.extraArgs` includes `"--skip-git-repo-check"`. This is safe — the flag only disables the pre-flight check; it does not change git behavior inside a repo. `/workspace/project` commits still happen via normal `git` invocations inside the agent turn.

### Per-agent env vs container env

Paperclip accepts `adapter_config.env` as a map of env vars to inject into the Codex CLI subprocess. If set per-agent, it overrides the container-level env. In practice:

- `docker-compose.yml` sets `AZURE_OPENAI_API_KEY` at the container level as a fallback, so that Codex CLI invoked directly in the container (e.g. for debugging) sees the key.
- Each agent sets `adapter_config.env.AZURE_OPENAI_API_KEY` with the same key, so that the audit trail records the key-use at the agent level and we can rotate per-agent.

If you rotate the Azure key, rotate it in **both** places to stay consistent.

### Field translation (`claude_local` → `codex_local`)

| Claude field | Codex field | Notes |
|-------------|-------------|-------|
| `dangerouslySkipPermissions` | `dangerouslyBypassApprovalsAndSandbox` | Same meaning, different name |
| `model: "claude-sonnet-4-6"` | `model: "gpt-5.3-codex"` | |
| *(N/A)* | `extraArgs: ["--skip-git-repo-check"]` | Required for `/paperclip` cwd |
| `workingDirectory` | `workingDirectory` | Same |
| `instructionsFilePath` | `instructionsFilePath` | Same |

## Rollback

The migration plan with full procedural detail lives in the sibling `openclaw` repo at:

```
openclaw/.a5c/processes/paperclip-codex-migration-output/MIGRATION_PLAN.md
```

For readers without access to that repo, the rollback procedure is:

1. Ensure `ANTHROPIC_API_KEY` is set in `.env` and has quota.
2. PATCH each agent back to Claude direct. For the five Claude-sonnet agents:

   ```bash
   eval $PAPERCLIP_CURL -X PATCH http://paperclip:3100/api/agents/{agentId} \
     -H "Content-Type: application/json" \
     -d '{
       "adapterType": "claude_local",
       "adapterConfig": {
         "model": "claude-sonnet-4-6",
         "dangerouslySkipPermissions": true,
         "workingDirectory": "/workspace/project",
         "instructionsFilePath": "/paperclip/companies/go-north/agents/{role}/AGENTS.md"
       }
     }'
   ```

   For the Finance Officer, substitute `"model": "claude-haiku-4-5-20251001"`.

3. Revert `companies/go-north/.paperclip.yaml` in this repo to the pre-migration version (adapter_type `claude_local`, models `claude-sonnet-4-6` / `claude-haiku-4-5-20251001`, field `dangerouslySkipPermissions`, no `extraArgs`).

4. Optional: remove the `AZURE_OPENAI_API_KEY` from `docker-compose.yml` env and the codex-config.toml volume mount if you want to make the rollback "hard".

The pre-migration adapter config for all six agents is captured in:

```
openclaw/.a5c/processes/paperclip-codex-migration-execute-output/rollback-snapshot.json
```

That file contains the exact adapter_type / adapter_config JSON to PATCH back with, agent by agent. It is intentionally outside this repo because it includes the old Anthropic-direct config as a point-in-time snapshot, not an ongoing source of truth.

## Follow-ups

- Monitor Azure quota on `tlk-agents-east-2` — currently well under 20% utilization, but six agents running concurrently on a long PR can spike.
- Re-evaluate whether Finance Officer needs a cheaper model than `gpt-5.3-codex` (previously on haiku for cost). `gpt-5.3-codex` is priced similarly to mid-tier Claude; for simple finance-ledger tasks a smaller Azure deployment could save ~40%.
- Once Anthropic quota refreshes, decide whether to stay on Azure permanently or load-balance across both providers via a router adapter (not in Paperclip today).
