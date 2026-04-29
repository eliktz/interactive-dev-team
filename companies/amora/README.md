# Amora Company Package

This is an `agentcompanies/v1` company package for **Amora** — an 8-agent Paperclip-managed development team shipping into the Bitbucket repo `Liran_katz/amora-dev`.

## What is this?

This package defines the internal WORKER agents that Paperclip manages: Product Manager, CEO, Finance Officer, Frontend Developer, Backend Developer, QA Lead, UX Designer, and DevOps Engineer. These are development-team agents — not external Telegram personas.

## Package Structure

```
companies/amora/
├── COMPANY.md                         # Company definition (root entrypoint)
├── .paperclip.yaml                    # Paperclip adapter/runtime config
├── README.md                          # This file
└── agents/
    ├── product-manager/AGENTS.md      # Product Manager agent (top-level)
    ├── ceo/AGENTS.md                  # CEO agent (top-level, no reports)
    ├── finance-officer/AGENTS.md      # Finance Officer agent
    ├── frontend-dev/AGENTS.md         # Frontend Developer agent
    ├── backend-dev/AGENTS.md          # Backend Developer agent
    ├── qa-lead/AGENTS.md              # QA Lead agent
    ├── ux-designer/AGENTS.md          # UX Designer agent
    └── devops-engineer/AGENTS.md      # DevOps Engineer agent
```

## How to Import

Use the Paperclip CLI or UI to import this package:

```bash
paperclip import companies/amora
```

Paperclip will discover `COMPANY.md` as the root, resolve all agents from `agents/*/AGENTS.md` by convention, and apply adapter config from `.paperclip.yaml`.

## Agent Roster

| Agent | Role | Adapter | Model |
|-------|------|---------|-------|
| product-manager | Product Manager | codex_local | gpt-5.5 |
| ceo | CEO | codex_local | gpt-5.5 |
| finance-officer | Finance Officer | codex_local | gpt-5.5 |
| frontend-dev | Frontend Developer | codex_local | gpt-5.5 |
| backend-dev | Backend Developer | codex_local | gpt-5.5 |
| qa-lead | QA Lead | codex_local | gpt-5.5 |
| ux-designer | UX Designer | codex_local | gpt-5.5 |
| devops-engineer | DevOps Engineer | codex_local | gpt-5.5 |

Paperclip company id: `507a294e-0b3e-4594-bcaf-23208f625445`.

## Spec Compliance

This package follows the [agentcompanies/v1 specification](../../paperclip/docs/companies/companies-spec.md). The base markdown package is vendor-neutral and readable without Paperclip. The `.paperclip.yaml` sidecar adds Paperclip-specific adapter configuration.
