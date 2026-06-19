<!--
  CLAUDE.md — platform ADMIN persona loader (mirrors deploy/templates/agents-seed/captain/CLAUDE.md).

  Seeded OUT-OF-REPO by the operator to /srv/platform-admin/agents/admin/CLAUDE.md.
  Claude Code auto-loads the CLAUDE.md in the agent's working/persona dir; the
  @import lines pull in the full admin context so the agent boots "aware" of its
  role, the operational runbook, and the runtime registry rationale — the same
  way a squad captain loads SOUL/AGENTS/TOOLS.

  The entrypoint ALSO passes --append-system-prompt-file .../AGENTS.md as a
  belt-and-braces measure; this CLAUDE.md is what gives the agent RUNBOOK.md +
  registry.md context too.

  Environment-variable NAMES used by the admin (VALUES live ONLY in the 0600
  /srv/platform-admin/.env, never here, never committed):
    - ANTHROPIC_API_KEY      : admin LLM key (or claude.ai OAuth in the state volume)
    - ADMIN_MODEL            : default model for the admin agent (e.g. sonnet)
    - ADMIN_TMUX_SESSION     : tmux session name (MUST equal WARROOM2_TMUX_SESSION)
    - SQUADCTL_NO_BUILD       : "1" — builds go out-of-band on the host
    - SQUADCTL_SQUADS_ROOT    : /srv/squads
    - SQUADCTL_PLATFORM_CONTAINERS : load-bearing + admin container names doctor tracks
    - DOCKER_HOST            : tcp://127.0.0.1:2380 (admin socket-proxy on host loopback)
-->

@import AGENTS.md
@import RUNBOOK.md
@import registry.md

## Persisting standing instructions (MANDATORY)

When the operator gives you a standing instruction — naming, language
preference, which verbs/tools to prefer, routing or approval rules — SAVE IT TO
YOUR AUTO-MEMORY IMMEDIATELY, before replying. In-session context is lost on
every restart; only memory files and CLAUDE.md survive. If unsure whether
something is standing or one-off, save it anyway and note the date.

## Never write a secret value (MANDATORY)

Never paste a token/password/key VALUE into any file, into argv (ps-visible), or
into anything that could be committed. Real values live ONLY in 0600 `.env`
files under `/srv`. Use `--token-file`, never a token on the command line. The
repo mount (`/home/ravi/interactive-dev-team`, the same absolute path it has on
the host) is READ-ONLY; the only writable data root is `/srv`.
