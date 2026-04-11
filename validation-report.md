# Validation Report: AGENTS.md Personality Files vs API Registration Payloads

**Generated**: 2026-04-11
**Project**: interactive-dev-team (Go-North War Room)

---

## Executive Summary

There is a **complete gap** between the rich personality definitions in `companies/go-north/agents/*/AGENTS.md` files and what `scripts/setup.sh` actually sends to the Paperclip API when registering agents. The setup script sends only structural metadata (name, role, title, adapter type, model) -- none of the behavioral rules, capabilities, domain context, or personality traits defined in the AGENTS.md files are included in the API payload.

However, this is **by design** in Paperclip's architecture. Paperclip supports a separate **instructions bundle system** (`agent-instructions` service) that reads AGENTS.md files from disk at runtime, injecting them via `--append-system-prompt-file` when the Claude adapter executes. The gap is that `setup.sh` does not configure `instructionsFilePath` or `instructionsRootPath` in the `adapterConfig` to point at the AGENTS.md files, and does not call the instructions bundle API to link them.

---

## Paperclip API Capabilities

### Agent Creation Schema (`createAgentSchema`)

The `POST /companies/:companyId/agents` endpoint accepts:

| Field | Type | Sent by setup.sh? | Notes |
|---|---|---|---|
| `name` | string (required) | Yes | Human-readable name |
| `role` | enum (ceo, cto, cmo, cfo, engineer, pm, designer, qa, devops, researcher, general) | Yes | Structural role |
| `title` | string | Yes | Display title |
| `icon` | enum | No | Agent icon |
| `reportsTo` | uuid | No | Org chart hierarchy |
| `capabilities` | string | No | **Free-text capabilities field -- unused by setup.sh** |
| `desiredSkills` | string[] | No | Skill names |
| `adapterType` | enum | Yes | e.g. "claude_local" |
| `adapterConfig` | object | Yes | Model, permissions, etc. |
| `runtimeConfig` | object | No | Runtime overrides |
| `budgetMonthlyCents` | number | No | Spending limit |
| `permissions` | object | No | e.g. canCreateAgents |
| `metadata` | object | No | Arbitrary metadata |

### Instructions Bundle System

Paperclip has a full **instructions bundle service** (`server/src/services/agent-instructions.ts`) that:

1. Reads AGENTS.md files from a configured root path
2. Supports "managed" bundles (stored in Paperclip's instance directory) or "external" bundles (arbitrary filesystem path)
3. Is configured via `adapterConfig` keys:
   - `instructionsBundleMode`: "managed" or "external"
   - `instructionsRootPath`: filesystem path to instructions directory
   - `instructionsEntryFile`: entry file name (defaults to "AGENTS.md")
   - `instructionsFilePath`: legacy single-file path
   - `promptTemplate`: legacy inline prompt string

The Claude adapter (`packages/adapters/claude-local/src/server/execute.ts`) injects the instructions file via:
```
--append-system-prompt-file <path-to-AGENTS.md>
```

### Auto-Materialization on Create

When an agent is created without explicit instructions configuration, `materializeDefaultInstructionsBundleForNewAgent()` creates a **generic default** AGENTS.md from `onboarding-assets/default/AGENTS.md` -- NOT from the project's custom AGENTS.md files.

---

## Per-Agent Comparison

### 1. product-manager

**AGENTS.md personality** (`companies/go-north/agents/product-manager/AGENTS.md`):
- Role: Product Manager for Go-North AI relocation assistant for northern Israel
- Capabilities: Backlog management, user stories, stakeholder feedback, sprint goals, competitive analysis, PRDs
- Behavior rules: User story structure, prioritize relocation features, clarify ambiguity, coordinate with Finance Officer on costs, coordinate with QA Lead on testability, backlog grooming discipline, Hebrew-first copy
- Reports to: null (top of org)

**API payload sent by setup.sh**:
```json
{
  "name": "Product Manager",
  "role": "pm",
  "title": "Product Manager",
  "adapterType": "claude_local",
  "adapterConfig": {
    "model": "claude-sonnet-4-6",
    "dangerouslySkipPermissions": true
  }
}
```

**Gap**: No capabilities, behavior rules, domain context, or Go-North personality are sent. No `instructionsFilePath` pointing to the AGENTS.md. No `reportsTo` relationship.

---

### 2. finance-officer

**AGENTS.md personality** (`companies/go-north/agents/finance-officer/AGENTS.md`):
- Role: Finance Officer for Go-North
- Capabilities: Budget tracking, LLM token cost analysis, cost-per-user estimates, billing monitoring (Supabase/Vercel/OpenAI), cost anomalies, financial summaries
- Behavior rules: Report in USD+ILS, alert PM on token overruns, recommend cost-effective model tiers, require business justification, weekly cost ledger, flag >$0.50 API calls
- Reports to: product-manager

**API payload sent by setup.sh**:
```json
{
  "name": "Finance Officer",
  "role": "cfo",
  "title": "Finance Officer",
  "adapterType": "claude_local",
  "adapterConfig": {
    "model": "claude-haiku-4-5-20251001",
    "dangerouslySkipPermissions": true
  }
}
```

**Gap**: No capabilities, behavior rules, cost thresholds, or Go-North domain context sent. No `instructionsFilePath`. No `reportsTo` linking to product-manager.

---

### 3. frontend-dev

**AGENTS.md personality** (`companies/go-north/agents/frontend-dev/AGENTS.md`):
- Role: Frontend Developer for Go-North
- Capabilities: Next.js App Router, React, Tailwind CSS with RTL, mobile-first, Supabase client SDK, AI SDK streaming, WCAG 2.1 AA
- Behavior rules: Mobile-first mandatory, RTL dir="rtl" testing, prefer server components, no hardcoded strings, follow design tokens, UX Designer visual review required, QA Lead approval required
- Tech stack: Next.js 14+, React 18+, Tailwind, Supabase Auth SSR, Hebrew fonts
- Reports to: product-manager

**API payload sent by setup.sh**:
```json
{
  "name": "Frontend Developer",
  "role": "engineer",
  "title": "Frontend Developer",
  "adapterType": "claude_local",
  "adapterConfig": {
    "model": "claude-sonnet-4-6",
    "dangerouslySkipPermissions": true
  }
}
```

**Gap**: No tech stack, RTL requirements, mobile-first rules, or collaboration constraints sent. No `instructionsFilePath`. No `reportsTo`.

---

### 4. backend-dev

**AGENTS.md personality** (`companies/go-north/agents/backend-dev/AGENTS.md`):
- Role: Backend Developer for Go-North
- Capabilities: Supabase/Postgres schemas, Next.js API routes/server actions, OpenAI AI SDK, RLS policies, Edge Functions, query optimization
- Behavior rules: RLS on every table, server actions for mutations, input validation, centralized prompt registry, log LLM calls with token counts for Finance Officer, no secrets in code, QA Lead approval required
- Tech stack: Supabase Postgres 15+, Supabase Auth/Storage, OpenAI AI SDK (Vercel), Next.js
- Reports to: product-manager

**API payload sent by setup.sh**:
```json
{
  "name": "Backend Developer",
  "role": "engineer",
  "title": "Backend Developer",
  "adapterType": "claude_local",
  "adapterConfig": {
    "model": "claude-sonnet-4-6",
    "dangerouslySkipPermissions": true
  }
}
```

**Gap**: No security rules, tech stack constraints, token logging requirements, or collaboration rules sent. No `instructionsFilePath`. No `reportsTo`.

---

### 5. qa-lead

**AGENTS.md personality** (`companies/go-north/agents/qa-lead/AGENTS.md`):
- Role: QA Lead for Go-North
- Capabilities: Playwright E2E tests, visual regression testing, RTL/Hebrew edge cases, WCAG 2.1 AA validation, AI response quality review, release gates
- Behavior rules: No deploy without QA sign-off, test on real mobile viewports (375/390/414px), RTL assertions in every suite, deliberate baseline updates, write failing test before fix, coordinate with FE/BE on testing, quarantine flaky tests within one sprint
- Reports to: product-manager

**API payload sent by setup.sh**:
```json
{
  "name": "QA Lead",
  "role": "qa",
  "title": "QA Lead",
  "adapterType": "claude_local",
  "adapterConfig": {
    "model": "claude-sonnet-4-6",
    "dangerouslySkipPermissions": true
  }
}
```

**Gap**: No release gate authority, testing standards, RTL requirements, or coordination rules sent. No `instructionsFilePath`. No `reportsTo`.

---

### 6. ux-designer

**AGENTS.md personality** (`companies/go-north/agents/ux-designer/AGENTS.md`):
- Role: UX Designer (internal) for Go-North
- Capabilities: Figma high-fidelity designs, relocation user flows, Hebrew-first design tokens, visual review of implementations, design handoff documentation, RTL-native layout design
- Behavior rules: Mobile-first mandatory, real Hebrew content (no Lorem Ipsum), single Figma source of truth, redline specs for every component, review every FE implementation before merge, coordinate with PM on UX requirements, WCAG 2.1 AA contrast ratios
- Reports to: product-manager

**API payload sent by setup.sh**:
```json
{
  "name": "UX Designer",
  "role": "designer",
  "title": "UX Designer",
  "adapterType": "claude_local",
  "adapterConfig": {
    "model": "claude-sonnet-4-6",
    "dangerouslySkipPermissions": true
  }
}
```

**Gap**: No design standards, Hebrew content requirements, Figma workflow rules, or review authority sent. No `instructionsFilePath`. No `reportsTo`.

---

## .paperclip.yaml Configuration

The file `companies/go-north/.paperclip.yaml` defines adapter defaults and per-agent model overrides, but does **not** configure any instructions-related fields:

```yaml
schema: paperclip/v1
adapter_defaults:
  adapter_type: claude_local
  adapter_config:
    dangerouslySkipPermissions: true
    model: claude-sonnet-4-6
agents:
  # Only model overrides, no instructionsFilePath or instructionsRootPath
```

Note: This YAML file is not consumed by `setup.sh` at all -- the script hardcodes the same values in its `AGENT_DEFS` associative array.

---

## Root Cause

`setup.sh` constructs agent payloads manually in the `AGENT_DEFS` bash associative array with only structural fields. It does not:

1. Read the AGENTS.md files from `companies/go-north/agents/*/AGENTS.md`
2. Include `instructionsFilePath` or `instructionsRootPath` in `adapterConfig` to point at those files
3. Use the `capabilities` field on the create schema (which accepts free-text)
4. Set `reportsTo` for org chart hierarchy
5. Call the Paperclip instructions bundle API (`PUT /agents/:id/instructions/bundle` or `PUT /agents/:id/instructions/files/:path`)

As a result, when agents are created, `materializeDefaultInstructionsBundleForNewAgent` generates a **generic default** AGENTS.md from Paperclip's built-in onboarding assets, not from the project's custom personality files.

---

## Recommendations

1. **Add `instructionsFilePath` to each agent's `adapterConfig`** in the `AGENT_DEFS` array, pointing to the absolute path of each agent's AGENTS.md file. Example:
   ```json
   "adapterConfig": {
     "model": "claude-sonnet-4-6",
     "dangerouslySkipPermissions": true,
     "instructionsFilePath": "/path/to/companies/go-north/agents/product-manager/AGENTS.md"
   }
   ```

2. **Alternatively, use external instructions bundles** by setting `instructionsBundleMode: "external"` and `instructionsRootPath` to the agent's directory.

3. **Populate `reportsTo`** to establish the org chart (all non-PM agents report to the PM).

4. **Populate `capabilities`** with a summary string for each agent.

5. **Sync `.paperclip.yaml` with `setup.sh`** so the YAML is the single source of truth, or have setup.sh read from it.
