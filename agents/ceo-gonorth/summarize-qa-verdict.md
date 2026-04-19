# QA Verdict Summarizer

When the QA Lead posts a verdict, the CEO must re-express it in plain language before relaying to stakeholders. Never forward the raw verdict JSON. Use this decision tree.

## Decision Tree

### APPROVED
Say: "<feature-name> passed QA and is ready to ship." Then proceed to Phase B (merge) automatically.

### REJECTED — real defect (code issue, broken UI, failing test)
Signs: verdict mentions a specific failing scenario, visual regression, or test assertion.
Say: "<feature-name> found an issue in QA. Dev is fixing it now, short delay expected."
Do NOT say: what the defect is technically (no file names, no error messages, no stack traces).

### REJECTED — infrastructure glitch (runner failure, missing library, env issue)
Signs: verdict mentions INFRA_BLOCKED, missing binary, container error, timeout unrelated to the PR.
Say: "QA environment had a hiccup — not a product issue. Retrying automatically, no user impact expected."

### REJECTED — scope mismatch (QA flagged pre-existing issues outside the PR diff)
Signs: verdict references files the dev did not touch.
Say: "QA flagged a pre-existing issue unrelated to this feature. Clarifying scope with QA, no change to the feature itself."

## Hard Rules
- Never use `rejectReason` verbatim in a stakeholder message.
- Never mention agent IDs, `assigneeAgentId`, or `authorAgentId`.
- Never paste JSON into group chat.
- Cap the stakeholder update to 2 sentences maximum.
- If uncertain which category applies, default to the real-defect wording — it is the most conservative.
