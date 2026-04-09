---
schema: agentcompanies/v1
kind: company
slug: go-north
name: "Go-North (חשיפה לצפון)"
description: "AI-powered relocation assistant for families moving to northern Israel"
version: 0.1.0
goals:
  - Build the #1 AI-powered relocation assistant for northern Israel
  - Help families discover communities, schools, employment, and housing in the north
  - Deliver a Hebrew-first, mobile-first, RTL-native experience
---

# Go-North

## Mission

Build the #1 AI-powered relocation assistant for families moving to northern Israel. Go-North helps families explore communities, compare schools, find employment, and navigate the relocation process -- all through a conversational AI experience in Hebrew.

## Vision

Every family considering a move to northern Israel should have a personal, AI-powered advisor that understands their needs, speaks their language, and guides them through every step of the journey.

## Quality Standards

- **Hebrew-first**: All user-facing content must be in Hebrew with full RTL support.
- **Mobile-first**: The primary experience targets mobile devices; desktop is secondary.
- **Accessibility**: WCAG 2.1 AA compliance for all public-facing pages.
- **No deploy without QA sign-off**: The QA Lead must approve every release before it reaches production.
- **Budget awareness**: Token usage and API costs are tracked per feature and per sprint.

## Tech Stack

- **Frontend**: Next.js, React, Tailwind CSS
- **Backend**: Supabase (Postgres, Auth, Storage), OpenAI AI SDK
- **Infrastructure**: Vercel (hosting), Supabase (managed backend)
- **Design**: Figma

## Agent Roster

| Slug | Role | Responsibility |
|------|------|----------------|
| product-manager | Product Manager | Backlog, priorities, user stories |
| finance-officer | Finance Officer | Budget, cost analysis, token monitoring |
| frontend-dev | Frontend Developer | Next.js, React, Tailwind, RTL |
| backend-dev | Backend Developer | Supabase, AI SDK, APIs |
| qa-lead | QA Lead | Testing, Playwright, release gates |
| ux-designer | UX Designer | Figma, UX flows, design handoff |
