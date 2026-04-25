#!/usr/bin/env bash
# cost-alerts.sh — M4. Hourly cron in paperclip container.
# Reads /workspace/.cost/haiku-spend.ndjson, sums last-7-day spend, alerts
# operator at 80% / hard-stops at 100% of weekly budget.
#
# Hard-stop = touch /workspace/.cost/HARD_STOPPED so the pre-send-gate
# rewrite path checks for it and degrades to log-only when present.

set -euo pipefail

LOG=/tmp/m4-cost-alerts.log
COST_DIR=/workspace/.cost
SPEND_NDJSON="$COST_DIR/haiku-spend.ndjson"
ALERT_FILE="$COST_DIR/last-alert.txt"
HARD_STOP_FILE="$COST_DIR/HARD_STOPPED"
BUDGET_USD="${M4_HAIKU_BUDGET_USD:-5.00}"

mkdir -p "$COST_DIR" 2>/dev/null || true
TS="$(date -u +%FT%TZ)"

# Sum last 7 days. ndjson lines look like {"date":"YYYY-MM-DD","calls":N,"usd":F}.
TOTAL_USD=0
if [ -f "$SPEND_NDJSON" ] ; then
  TOTAL_USD="$(awk -v cutoff="$(date -u -d '7 days ago' +%F 2>/dev/null || date -u -v-7d +%F)" '
    BEGIN { sum=0 }
    {
      # crude date parse
      match($0, /"date":"([0-9-]+)"/, ad)
      match($0, /"usd":([0-9.]+)/, au)
      if (ad[1] >= cutoff) sum += au[1]
    }
    END { printf "%.4f", sum }
  ' "$SPEND_NDJSON" 2>/dev/null || echo 0)"
fi

# Compute % of budget.
PCT=$(awk -v t="$TOTAL_USD" -v b="$BUDGET_USD" 'BEGIN { if (b==0) print 0; else printf "%.0f", (t / b) * 100 }')

echo "[$TS] cost-alerts: 7d-spend=\$$TOTAL_USD budget=\$$BUDGET_USD pct=${PCT}%" >>"$LOG"

# Hard-stop at 100%
if [ "$PCT" -ge 100 ] ; then
  if [ ! -f "$HARD_STOP_FILE" ] ; then
    {
      echo "Cost hard-stop triggered at $TS"
      echo "spend=\$$TOTAL_USD budget=\$$BUDGET_USD pct=$PCT%"
    } > "$HARD_STOP_FILE"
    echo "[$TS] HARD-STOP triggered (pct=$PCT%) — rewrite path will degrade to log" >>"$LOG"
  fi
  exit 0
fi

# Alert at 80%
if [ "$PCT" -ge 80 ] ; then
  LAST_ALERT=""
  [ -f "$ALERT_FILE" ] && LAST_ALERT="$(cat "$ALERT_FILE")"
  if [ "$LAST_ALERT" != "$(date +%F)" ] ; then
    date +%F > "$ALERT_FILE"
    echo "[$TS] ALERT-80 fired: spend=\$$TOTAL_USD pct=$PCT% (would notify operator)" >>"$LOG"
  fi
fi

# Below 80% — clear hard-stop if present.
if [ "$PCT" -lt 80 ] && [ -f "$HARD_STOP_FILE" ] ; then
  rm -f "$HARD_STOP_FILE"
  echo "[$TS] HARD-STOP cleared (pct=$PCT%)" >>"$LOG"
fi

exit 0
