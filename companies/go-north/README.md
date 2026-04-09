# Go-North Company Package

This is an `agentcompanies/v1` company package for **Go-North (חשיפה לצפון)** -- an AI-powered relocation assistant for families moving to northern Israel.

## What is this?

This package defines the internal WORKER agents that Paperclip manages. These are development-team agents (Product Manager, Finance Officer, Frontend Developer, Backend Developer, QA Lead, UX Designer) -- not the external Telegram personas.

## Package Structure

```
companies/go-north/
├── COMPANY.md                         # Company definition (root entrypoint)
├── .paperclip.yaml                    # Paperclip adapter/runtime config
├── README.md                          # This file
└── agents/
    ├── product-manager/AGENTS.md      # Product Manager agent
    ├── finance-officer/AGENTS.md      # Finance Officer agent
    ├── frontend-dev/AGENTS.md         # Frontend Developer agent
    ├── backend-dev/AGENTS.md          # Backend Developer agent
    ├── qa-lead/AGENTS.md              # QA Lead agent
    └── ux-designer/AGENTS.md          # UX Designer agent
```

## How to Import

Use the Paperclip CLI or UI to import this package:

```bash
paperclip import companies/go-north
```

Paperclip will discover `COMPANY.md` as the root, resolve all agents from `agents/*/AGENTS.md` by convention, and apply adapter config from `.paperclip.yaml`.

## Agent Roster

| Agent | Role | Model |
|-------|------|-------|
| product-manager | Product Manager | claude-sonnet-4-6 |
| finance-officer | Finance Officer | claude-haiku-4-5-20251001 |
| frontend-dev | Frontend Developer | claude-sonnet-4-6 |
| backend-dev | Backend Developer | claude-sonnet-4-6 |
| qa-lead | QA Lead | claude-sonnet-4-6 |
| ux-designer | UX Designer | claude-sonnet-4-6 |

## Spec Compliance

This package follows the [agentcompanies/v1 specification](../../paperclip/docs/companies/companies-spec.md). The base markdown package is vendor-neutral and readable without Paperclip. The `.paperclip.yaml` sidecar adds Paperclip-specific adapter configuration.
