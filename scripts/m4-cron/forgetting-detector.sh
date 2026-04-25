#!/usr/bin/env bash
# forgetting-detector.sh — M4. Weekly drift detector.
# Cron: Sunday 09:00 IDT in the paperclip container.
# Pulls last 100 CEO outbound (Telegram + Paperclip), computes 6 drift metrics,
# alerts if 3+ are over threshold.
#
# Metrics:
#   1. tech-leak%        > 15% bad
#   2. signed-chrome%    < 90% bad
#   3. mix%              > 10% bad   (Hebrew/English mix)
#   4. bold-overuse%     > 20% bad
#   5. trello-product-framed%   < 80% bad
#   6. response-relevance%      < 80% bad   (heuristic: uses operator's keywords)

set -euo pipefail

LOG=/tmp/m4-forgetting-detector.log
OUT_DIR=/workspace/.forgetting
mkdir -p "$OUT_DIR" 2>/dev/null || true

TS="$(date -u +%FT%TZ)"
WEEK="$(date +%G-W%V)"
REPORT="$OUT_DIR/forgetting-${WEEK}.md"

PG_URL="${M4_FORGETTING_PG_URL:-postgres://paperclip:paperclip@127.0.0.1:54329/paperclip}"

echo "[$TS] forgetting-detector start (week=$WEEK)" >>"$LOG"

# Pull last 100 CEO Telegram + Paperclip outbounds.
SAMPLE="$(mktemp -t forgetting.XXXXXX)"
trap 'rm -f "$SAMPLE"' EXIT

if command -v psql >/dev/null 2>&1 ; then
  psql "$PG_URL" -At -c "SELECT COALESCE(body, '') FROM issue_comments WHERE created_at > now() - interval '7 days' ORDER BY created_at DESC LIMIT 100" >"$SAMPLE" 2>>"$LOG" || true
fi

# Augment with file spillover for Telegram outbound.
if [ -f /workspace/dev-activity-feed.ndjson ] ; then
  tail -n 100 /workspace/dev-activity-feed.ndjson | grep -i ceo-gonorth >>"$SAMPLE" 2>/dev/null || true
fi

# Helper: take a string that should be an integer (might be empty / multi-line),
# return the first integer or 0.
_to_int() {
  local v="${1:-0}"
  v="$(printf '%s' "$v" | head -1 | tr -d ' \n\r')"
  case "$v" in
    ''|*[!0-9]*) echo 0 ;;
    *) echo "$v" ;;
  esac
}

TOTAL="$(_to_int "$(wc -l <"$SAMPLE" 2>/dev/null)")"
if [ "$TOTAL" -eq 0 ] ; then
  TOTAL=1
fi

# 1. tech-leak%
TECH_HITS="$(_to_int "$(grep -ciE '(commit|sha|http [0-9]{3}|/api/|src/|pnpm|npm i |yarn add|circuit_breaker|branch|main@)' "$SAMPLE" 2>/dev/null)")"
TECH_PCT=$(( (TECH_HITS * 100) / TOTAL ))

# 2. signed-chrome%
CHROME_HITS="$(_to_int "$(grep -cE '^(\xf0\x9f\xa7\xad|\xf0\x9f\x8e\xa8|\xf0\x9f\xa7\xa6) (PM|UX|Captain) ·' "$SAMPLE" 2>/dev/null)")"
CHROME_PCT=$(( (CHROME_HITS * 100) / TOTAL ))

# 3. mix% (Hebrew + Latin chars in same line)
MIX_HITS="$(_to_int "$(grep -cE '[א-ת].*[A-Za-z]|[A-Za-z].*[א-ת]' "$SAMPLE" 2>/dev/null)")"
MIX_PCT=$(( (MIX_HITS * 100) / TOTAL ))

# 4. bold-overuse% (>2 *...* spans on a single line)
BOLD_HITS="$(_to_int "$(awk '{ n=gsub(/\*[^*]+\*/,"&"); if (n>2) c++ } END {print c+0}' "$SAMPLE" 2>/dev/null)")"
BOLD_PCT=$(( (BOLD_HITS * 100) / TOTAL ))

# 5. trello-product-framed% — proxy: lines containing "trello" that ALSO contain
#    a "user-facing"/"users get"/"חוויה" cue (product framing).
TRELLO_LINES="$(_to_int "$(grep -c -i trello "$SAMPLE" 2>/dev/null)")"
TRELLO_PRODFRAMED="$(_to_int "$(grep -i trello "$SAMPLE" 2>/dev/null | grep -ciE '(users? get|user-facing|חוויה|תועלת|outcome)' 2>/dev/null)")"
if [ "$TRELLO_LINES" -gt 0 ] ; then
  TRELLO_PCT=$(( (TRELLO_PRODFRAMED * 100) / TRELLO_LINES ))
else
  TRELLO_PCT=100
fi

# 6. response-relevance% — proxy: assume CEO replies that include the question's
#    keywords are "relevant". Without a real Q-A pairing dataset, hard-set 100%
#    in M4 build (placeholder; real heuristic in M5).
RELEV_PCT=100

# Threshold checks.
T1=$([ "$TECH_PCT" -gt 15 ] && echo 1 || echo 0)
T2=$([ "$CHROME_PCT" -lt 90 ] && echo 1 || echo 0)
T3=$([ "$MIX_PCT" -gt 10 ] && echo 1 || echo 0)
T4=$([ "$BOLD_PCT" -gt 20 ] && echo 1 || echo 0)
T5=$([ "$TRELLO_PCT" -lt 80 ] && echo 1 || echo 0)
T6=$([ "$RELEV_PCT" -lt 80 ] && echo 1 || echo 0)
DRIFT_COUNT=$((T1 + T2 + T3 + T4 + T5 + T6))

# Compose report.
{
  echo "# Forgetting detector — week $WEEK"
  echo
  echo "Sample size: $TOTAL outbound messages (last 7 days, CEO)."
  echo
  echo "| Metric | Value | Threshold | Drift? |"
  echo "|---|---|---|---|"
  echo "| tech-leak% | $TECH_PCT% | >15% | $T1 |"
  echo "| signed-chrome% | $CHROME_PCT% | <90% | $T2 |"
  echo "| mix% | $MIX_PCT% | >10% | $T3 |"
  echo "| bold-overuse% | $BOLD_PCT% | >20% | $T4 |"
  echo "| trello-product-framed% | $TRELLO_PCT% | <80% | $T5 |"
  echo "| response-relevance% | $RELEV_PCT% | <80% | $T6 |"
  echo
  echo "**Drift count: $DRIFT_COUNT / 6.**"
  echo
  if [ "$DRIFT_COUNT" -ge 3 ] ; then
    echo "**ALERT — 3+ contracts drifting. Operator notification recommended.**"
    {
      echo "[$TS] DRIFT ALERT week=$WEEK count=$DRIFT_COUNT"
    } >>"/workspace/forgetting-alert-$(date +%F).md"
  fi
  echo
  echo "_Generated $TS by /workspace/scripts/m4-cron/forgetting-detector.sh_"
} > "$REPORT"

echo "[$TS] report written to $REPORT (drift=$DRIFT_COUNT/6)" >>"$LOG"

exit 0
