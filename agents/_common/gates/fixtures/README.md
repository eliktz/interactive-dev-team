# pre-send-gate fixtures

Synthetic Claude Code PreToolUse JSON envelopes used to dry-run
`agents/_common/gates/pre-send-gate.sh`.

## Dry-run

```bash
# log mode (no LLM call, sub-500ms p99)
GATE_MODE=log \
  ./agents/_common/gates/pre-send-gate.sh \
  < agents/_common/gates/fixtures/clean-he.json

# rewrite mode (requires ANTHROPIC_API_KEY in env)
GATE_MODE=rewrite ANTHROPIC_API_KEY=sk-ant-... \
  ./agents/_common/gates/pre-send-gate.sh \
  < agents/_common/gates/fixtures/overbold-he.json

# block mode
GATE_MODE=block \
  ./agents/_common/gates/pre-send-gate.sh \
  < agents/_common/gates/fixtures/commit-hash-leak.json
```

## Expected verdicts (all in log mode unless noted)

| Fixture                              | Expected level | Expected check     | Notes |
|--------------------------------------|----------------|--------------------|-------|
| `clean-he.json`                      | `continue`     | (none)             | Single bold span, pure Hebrew + URL whitelist. Control. |
| `overbold-he.json`                   | HARD           | `bold`             | 6 bold spans → > 2 spans rule fires. |
| `mixed-langs.json`                   | HARD           | `language`         | ~50% Latin chars in a Hebrew message → > 10% threshold. |
| `commit-hash-leak.json`              | HARD           | `banlist` or `language` | Multiple HARD-banlist tokens (commit SHA, PR #, HTTP 200, /api/, deployed to prod, merged to main). |
| `internal-channel-techspeak.json`    | `continue`     | (audience=internal) | Bitbucket PR comment is internal — relaxed checks; passes. |

Verdict precedence: HARD > SOFT; first hit wins among checks (bold → language → banlist → length-format).

## Output channels

- `${GATE_LOG:-/tmp/pre-send-gate.ndjson}` — one ndjson line per violation.
- `${TONE_LOG:-/tmp/tone-rewrites.log}` — one human-readable line per violation.
- `${PSG_DEBUG_LOG:-/tmp/pre-send-gate.debug.log}` — info/warn from the gate itself.
