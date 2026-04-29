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

## Agent Roster

| Slug | Role | Reports to |
|------|------|------------|
| product-manager | Product Manager | _(top-level)_ |
| ceo | CEO | _(top-level)_ |
| finance-officer | Finance Officer | product-manager |
| frontend-dev | Frontend Developer | product-manager |
| backend-dev | Backend Developer | product-manager |
| qa-lead | QA Lead | product-manager |
| ux-designer | UX Designer | product-manager |
| devops-engineer | DevOps Engineer | product-manager |

Paperclip company id: `507a294e-0b3e-4594-bcaf-23208f625445`.
