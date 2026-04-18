# QA Tiers

The dev/QA loop uses **four tiers** of QA, selected per issue via a `qa:*` label. The QA Lead reads the label, runs the matching gate set, and emits one of three verdicts: `APPROVED`, `REJECTED`, or `INFRA_BLOCKED`.

This document covers:
1. The four tiers and when to use each.
2. How to apply a tier label via the Paperclip API.
3. Default behaviour when no label is set.
4. The `INFRA_BLOCKED` verdict protocol.
5. The circuit breaker (N=2 same-cause rejections → escalate).
6. The comment-trigger wake pattern (why direct agent-to-agent wake doesn't work).

---

## 1. The four tiers

| Label           | Gates run                                          | Typical target time | When to use                                                                 |
|-----------------|----------------------------------------------------|---------------------|-----------------------------------------------------------------------------|
| `qa:none`       | (none — auto-approve after build-not-required)      | <10 s               | Docs-only, comment-only, no runtime code change.                            |
| `qa:build`      | build + lint                                       | 1–3 min             | Refactor, dead-code cleanup, type-only changes, no behaviour delta.         |
| `qa:functional` | build + lint + unit/functional tests               | 3–7 min             | **Default.** Any backend logic, API, data, or non-visual frontend change.   |
| `qa:visual`     | build + lint + unit tests + Playwright visual diff | 7–15 min            | UI, CSS, layout, or asset changes that could affect screen rendering.       |

### Concrete examples

- **Docs PR** — "update README, add architecture diagram". → `qa:none`. No code ran, nothing to test.
- **Rename variable in 3 backend files** — pure rename, no behaviour change. → `qa:build`. Build + lint will catch a typo; tests add no signal.
- **New API route `/api/communities/nearby`** — backend logic, JSON contract, RLS policy. → `qa:functional`. Unit + integration tests are the real gate; no UI changed.
- **Replace a Tailwind utility class on the homepage CTA** — visual-only. → `qa:visual`. Build + lint will pass; unit tests may miss it; only a screenshot diff catches a broken RTL layout.
- **New onboarding wizard with form validation** — UI + logic. → `qa:visual` (covers both — visual diff exercises the UI while unit tests cover the validation).
- **Hotfix: empty-state null-check in `WelcomeBanner.tsx`** — tiny logic fix in a rendered component. → `qa:functional` is enough; a visual diff is overkill for a null-check.

### Heuristic

Pick the **cheapest** tier that actually validates the change. If the PR cannot visually regress anything, don't run `qa:visual`. If the PR cannot change behaviour, don't run tests. But **never** pick `qa:none` for code that runs at request/build time — that's what `qa:build` is for.

---

## 2. Applying a tier label via Paperclip API

Labels in Paperclip are per-company. The recipe: create the label once per company (idempotent — `POST` returns the existing one if the name collides), then PATCH it onto the issue.

Assumes `PAPERCLIP_SESSION_COOKIE` is set from the sign-in recipe in `config/paperclip.md`.

```bash
COMPANY_ID="a951bb35-24a9-412a-bbcc-629c5acae619"    # Go-North
ISSUE_ID="<paperclip issue UUID>"

# 1. Ensure the four labels exist on the company (run once at setup; idempotent)
for name in qa:none qa:build qa:functional qa:visual; do
  curl -sS -X POST \
    -H "Host: paperclip.tlk.solutions" \
    -H "Origin: https://paperclip.tlk.solutions" \
    -H "Cookie: ${PAPERCLIP_SESSION_COOKIE}" \
    -H "Content-Type: application/json" \
    "http://localhost:3100/api/companies/${COMPANY_ID}/labels" \
    -d "{\"name\":\"${name}\"}"
done

# 2. List labels to look up the UUID for the tier you want
LABELS=$(curl -sS \
  -H "Host: paperclip.tlk.solutions" \
  -H "Cookie: ${PAPERCLIP_SESSION_COOKIE}" \
  "http://localhost:3100/api/companies/${COMPANY_ID}/labels")

TIER_LABEL_ID=$(echo "$LABELS" | node -e '
  let d = JSON.parse(require("fs").readFileSync(0, "utf8"));
  let L = Array.isArray(d) ? d : (d.labels || d.items || []);
  let target = process.argv[1];
  let hit = L.find(x => x.name === target);
  console.log(hit ? hit.id : "");
' qa:functional)

# 3. Attach the label to the issue (PATCH with labelIds replaces the set)
curl -sS -X PATCH \
  -H "Host: paperclip.tlk.solutions" \
  -H "Origin: https://paperclip.tlk.solutions" \
  -H "Cookie: ${PAPERCLIP_SESSION_COOKIE}" \
  -H "Content-Type: application/json" \
  "http://localhost:3100/api/issues/${ISSUE_ID}" \
  -d "{\"labelIds\":[\"${TIER_LABEL_ID}\"]}"
```

**DELETE is unsupported.** Paperclip's `DELETE /api/companies/{id}/labels/{labelId}` endpoint does not currently remove the label from the DB — live with it. To "change" a tier on an issue, PATCH `labelIds` to the new set; the old label stays in the company catalog unused.

### Who sets the label?

- **Product Manager** picks the tier when creating the issue (the default, expected path).
- **CEO / war-room operator** can override before assigning to Dev.
- **Dev agent** can add one if it was missed, but should not downgrade (e.g. cannot change `qa:functional` → `qa:none`).

---

## 3. Default behaviour

If an issue reaches QA Lead without any `qa:*` label, the QA Lead defaults to **`qa:functional`**. This is the safest sensible default — it's fast enough for most PRs, runs real tests, and catches almost every logic bug. `qa:visual` is not the default because it's the most expensive tier and most PRs don't touch visible UI.

Product Manager is responsible for not leaving issues unlabeled; the default exists as a safety net, not as an excuse.

---

## 4. The `INFRA_BLOCKED` verdict

Traditional QA has two outcomes: pass or fail. That is a false dichotomy when the runner itself is broken. A PR that fails because `libglib-2.0.so.0` is missing from the QA container is **not** a bad PR — it's an unvalidated PR. Rejecting it sends the dev in circles trying to fix an infra problem from inside their code change.

`INFRA_BLOCKED` is the QA Lead saying: *"I could not run. Not the dev's fault. Operator, please fix."*

### Triggers

Any of the following patterns in gate output:

- `cannot open shared object file` (missing `.so`)
- `No such file or directory.*\.so`
- `ECONNREFUSED`
- `timeout` to a required service
- `command not found` for a tool the runner should provide
- `permission denied` on system paths (`/usr`, `/opt`, `/var`)
- Playwright cannot launch chromium
- Missing env var the runner itself should provide

When any of these fire, the QA Lead emits `INFRA_BLOCKED` instead of `REJECTED`.

### Protocol

- **Verdict comment** uses the `## QA Report — INFRA_BLOCKED` template (see QA Lead AGENTS.md Step 4).
- **Issue status stays `in_review`.** QA is not "done" — it is "paused, waiting for operator".
- **Assignee stays unchanged.** Dev is NOT put back on the hook.
- **Dev agents ignore `INFRA_BLOCKED`.** They acknowledge and stop. They do not push a fix, add an apt-get line, or attempt any env patch.
- **Operator fixes the runner**, then re-triggers QA via PATCH `assigneeAgentId` → QA Lead (or by posting `@qa-lead retry` as a comment).

---

## 5. Circuit breaker

Two consecutive same-cause `REJECTED` verdicts from QA Lead on the same issue mean the dev loop has gone pathological. Almost always:
- Infra is broken and QA is misclassifying it as REJECTED.
- The dev is "fixing" the wrong thing because QA's root-cause signature is too vague.
- The test the PR is failing is itself broken.

The circuit breaker catches this before it burns a 3rd iteration.

### Mechanism

1. **Before running any gate**, the QA Lead pulls its last ~6 comments on the issue.
2. It extracts the verdict + first-80-chars-of-root-cause from each.
3. If the **two most recent** are both `REJECTED` with the **same signature**, the breaker trips.

### When tripped

- QA Lead skips all gates.
- Emits `INFRA_BLOCKED` with `escalation=true`.
- Adds `@ceo` to the comment so the war-room / human operator sees it immediately.
- Issue stays `in_review`, assignee unchanged.

### Dev-side awareness

Dev agents also watch for 2 consecutive REJECTED verdicts on the same root cause and stop pushing fixes at that point — they post a comment asking the operator to investigate instead of attempting a 3rd fix.

### Why 80 characters?

Enough to disambiguate "Playwright cannot launch chromium: missing libglib-2.0.so.0" from "Playwright cannot launch chromium: missing libnss3.so" (different operator fix) but short enough that minor timestamp/PID noise doesn't prevent matching.

### Keeping signatures stable

The circuit breaker only works if QA Lead emits a **stable** root-cause signature across retries. If the same failure is reported as `"missing libglib"` once and `"Playwright can't find glib library"` the next time, the breaker cannot match and the loop spins. The QA Lead AGENTS.md enforces this: "keep the REJECTED root-cause signature stable across retries."

---

## 6. Comment-trigger wake pattern

### Why direct agent-to-agent wake doesn't work

Paperclip's `/api/agents/{id}/wakeup` route enforces (see `agents.ts:2099`):

```ts
if (actor.type === 'agent' && actor.agentId !== id) {
  return 403;
}
```

Dev agents authenticate with an agent-scoped `PAPERCLIP_API_KEY`. A dev agent calling `wakeup` on the QA Lead's agent ID triggers this check and gets a 403. Only **admin-session** callers (browser / CLI with the `__Secure-better-auth.session_token` cookie) can cross-wake agents. That is the intended security model, not a bug.

### The supported path: comment-trigger

Paperclip's heartbeat scheduler watches issues for (a) `assigneeAgentId` changes and (b) new comments that `@mention` an agent. So the dev agent does:

1. `PATCH /api/issues/{id}` with `assigneeAgentId=<QA_LEAD_ID>` (status stays `in_review`).
2. `POST /api/issues/{id}/comments` with a body like `"@qa-lead please run QA on PR {url}"`.

The heartbeat picks up the assignee change within ~10–30 seconds and wakes QA Lead. No 403, no admin cookie needed, no CEO in the critical path.

### What dev agents must NOT do

- **Do NOT POST to `/api/agents/{QA_LEAD_ID}/wakeup`** — 403.
- **Do NOT comment "CEO intervention required"** on that 403 — the comment-trigger recipe above is the supported path; the 403 is expected and uninteresting.
- **Do NOT fall back to admin auth** from a dev agent — agent shells do not have admin credentials and should not try to.

See `companies/go-north/agents/backend-dev/AGENTS.md` Step 10 and the frontend-dev equivalent for the full recipe with env-var wiring.
