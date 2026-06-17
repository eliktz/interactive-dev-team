---
schema: agentcompanies/v1
kind: company
slug: amora
name: "Amora"
description: "Amora development team — 8-agent Paperclip-managed company shipping into the Liran_katz/amora-dev Bitbucket repo"
version: 0.1.0
goals:
  - Deliver Amora's product surface area through a small, well-coordinated agent team
  - Keep every change behind a feature branch + PR + QA gate before reaching `main`
  - Maintain Hebrew-first, mobile-first, RTL-native quality where user-facing
---

# Amora

## Mission

Build and operate Amora's product through a Paperclip-managed agent team. Every shippable change flows through the Product Manager, the right IC, the QA Lead, and the CEO before landing on `main` in `Liran_katz/amora-dev`.

## Vision

Amora's customers should feel a coherent, well-tested, well-designed product — produced by an agent team that pushes only reviewed, gated code.

## Quality Standards

- **PR-first**: every change reaches `main` via a Bitbucket feature branch and a reviewed PR — no direct pushes to `main`.
- **QA gate**: the QA Lead approves before any issue moves from `in_review` to `done`.
- **Hebrew-first / RTL where user-facing**: applies to public surfaces; internal tooling may stay in English.
- **No deploy without QA sign-off**: applies to every release.
- **Budget awareness**: the Finance Officer flags cloud and third-party API spend per feature.
- **Token-only Bitbucket auth**: git uses `https://x-token-auth:${AMORA_BITBUCKET_TOKEN}@bitbucket.org/Liran_katz/amora-dev.git`; Bitbucket REST uses `Authorization: Bearer ${AMORA_BITBUCKET_TOKEN}`.

## Tech Stack

To be defined per-feature by the PM and the responsible IC. The repo is `Liran_katz/amora-dev` on Bitbucket; the shared clone lives at `/paperclip/instances/default/workspaces/amora-app/` inside the paperclip container.

## People / Operators

Amora is a **Paperclip-managed company** with no war-room Telegram personas in this
repo — its agents are dev workers, not chat-facing personas. Human operators and
customer contacts (where applicable) live in the gitignored overlay
`private/team.md`; this public file references **roles only**.

| Person | Role | Notes |
|--------|------|-------|
| Operator | Squad operator | Owns deployment, squad `.env`, and the Bitbucket token. Telegram id in env `OPERATOR_TELEGRAM_ID`. |

## Agent Roster

Amora's agents are **Paperclip workers** (adapter `codex_local`) defined under
`agents/<slug>/AGENTS.md` and wired by `.paperclip.yaml`.

| Slug | Role | Reports to | Model | One-line responsibility |
|------|------|------------|-------|-------------------------|
| product-manager | Product Manager | _(top-level)_ | gpt-5.5 | Backlog, priorities, user stories; routes work to ICs. |
| ceo | CEO | _(top-level)_ | gpt-5.5 | Final approver before `main`; strategy and sign-off. |
| finance-officer | Finance Officer | product-manager | gpt-5.5 | Flags cloud + third-party API spend per feature. |
| frontend-dev | Frontend Developer | product-manager | gpt-5.5 | Frontend implementation. |
| backend-dev | Backend Developer | product-manager | gpt-5.5 | Backend / API implementation. |
| qa-lead | QA Lead | product-manager | gpt-5.5 | Testing + release gate; approves `in_review` → `done`. |
| ux-designer | UX Designer | product-manager | gpt-5.5 | UX flows, design handoff. |
| devops-engineer | DevOps Engineer | product-manager | gpt-5.5 | CI/CD, deployment, infra. |

Models are operator-defined Azure deployment names — see
`reference_azure_deployment_name`. Live Paperclip agent ids are
environment-specific.

Paperclip company id: `507a294e-0b3e-4594-bcaf-23208f625445`.

## Who does what / routing

A shippable change flows: **product-manager** scopes it → the responsible **IC**
(frontend/backend/ux/devops) implements on a feature branch → **qa-lead** gates →
**ceo** approves the PR into `main`. The **finance-officer** flags spend along the
way.

## Conventions

- **Repo**: `Liran_katz/amora-dev` on Bitbucket. The shared clone lives at
  `/paperclip/instances/default/workspaces/amora-app/` inside the paperclip
  container.
- **Branch / PR flow**: every change reaches `main` via a Bitbucket feature branch
  and a reviewed PR — no direct pushes to `main`.
- **QA gate**: the QA Lead approves before any issue moves from `in_review` to
  `done`; no deploy without QA sign-off.
- **Auth (Bitbucket)**: token-only — git uses
  `https://x-token-auth:${AMORA_BITBUCKET_TOKEN}@bitbucket.org/Liran_katz/amora-dev.git`;
  Bitbucket REST uses `Authorization: Bearer ${AMORA_BITBUCKET_TOKEN}`. The token
  value is env-only.
- **Paperclip**: company id `507a294e-0b3e-4594-bcaf-23208f625445`; adapter
  `codex_local` per `.paperclip.yaml`.
- **Secrets**: this is a PUBLIC repo. Reference env var NAMES only — never paste
  token/password/key values into this file.
