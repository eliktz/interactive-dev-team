#!/bin/sh
# emit-task-event.sh — CAP-19 task-lifecycle ledger (image template).
# launch.sh installs this to /workspace/config/emit-task-event.sh if the squad
# doesn't already ship one; agent personas call it for every substantive task.
# Usage: sh /workspace/config/emit-task-event.sh <agent> <event> '<json-body>'
# Events: task_assigned|task_result|qa_verdict|human_feedback|task_closed
# Requires: SQUAD_SLUG env (compose sets it from COMPOSE_PROJECT_NAME) and the
# container joined to the obs-net docker network so obs-loki resolves.
SQUAD="${SQUAD_SLUG:-unknown}"
AGENT="$1"; EVENT="$2"; BODY="$3"
LOKI="${LOKI_URL:-http://obs-loki:3100}"
case "$EVENT" in task_assigned|task_result|qa_verdict|human_feedback|task_closed) ;; *) echo "bad event" >&2; exit 1;; esac
NS=$(date +%s%N)
LINE=$(node -e 'const b=JSON.parse(process.argv[1]||"{}");b.event=process.argv[2];b.ts=new Date().toISOString();console.log(JSON.stringify(b));' "$BODY" "$EVENT") || { echo "bad json" >&2; exit 1; }
RESP=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$LOKI/loki/api/v1/push" -H 'Content-Type: application/json' \
  -d "{\"streams\":[{\"stream\":{\"job\":\"agent-tasks\",\"squad\":\"$SQUAD\",\"agent\":\"$AGENT\",\"event\":\"$EVENT\"},\"values\":[[\"$NS\",$(node -e 'console.log(JSON.stringify(process.argv[1]))' "$LINE")]]}]}")
[ "$RESP" = "204" ] && exit 0
echo "loki push failed $RESP" >&2; exit 2
