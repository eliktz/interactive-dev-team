# Paperclip Agent Personality Fix — Process

## Problem Statement

All 6 Paperclip agents (Product Manager, Finance Officer, Frontend Dev, Backend Dev, QA Lead, UX Designer) are registered with identical generic payloads. The unique AGENTS.md files exist in the repo but their content is never passed to Paperclip during setup.

## Process Phases

### Phase 1: Validate
- Read all 6 AGENTS.md files and confirm each has unique content
- Read setup.sh and extract the exact API payloads sent to Paperclip
- Compare: what's in the file vs what's sent to the API
- Document the gap for each agent

### Phase 2: Identify Flaws
- Trace the full pipeline: AGENTS.md -> .paperclip.yaml -> setup.sh -> Paperclip API -> deployed agent
- Identify every point where personality is lost
- Check Paperclip's API schema for instruction/prompt fields
- Document root causes and severity

### Phase 3: Breakpoint (User Approval)
- Present 2-3 fix options with trade-offs
- User chooses which approach to implement
- Options may include: modify setup.sh to read/send AGENTS.md, use Paperclip import, or hybrid approach

### Phase 4: Implement
- Apply the approved fix
- Ensure setup.sh remains idempotent
- Handle edge cases (missing files, re-runs, multiline content in JSON)
- Goal: first-time deployer gets correctly personalized agents

### Phase 5: Verify
- Review changes for correctness
- Check JSON payload well-formedness
- Verify idempotency
- Confirm documentation is updated

## Agents Used
- `general-purpose` — for all research, analysis, implementation, and verification tasks

## Expected Output
- Modified `scripts/setup.sh` that passes unique AGENTS.md content to Paperclip
- Validation report documenting the original gap
- Verified, reproducible fix
