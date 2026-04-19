#!/usr/bin/env bash
# Mirror Paperclip issues to Trello cards. Idempotent. Runs as a step inside
# the CEO's 5-min Paperclip polling cron (NOT a separate cron).
#
# Required env:
#   TRELLO_KEY, TRELLO_TOKEN, TRELLO_BOARD_ID
#   TRELLO_LIST_IDS       — minified JSON mapping paperclip-status → trello-listId,
#                            e.g. '{"todo":"<id>","in_progress":"<id>","in_review":"<id>","done":"<id>","blocked":"<id>"}'
#   PAPERCLIP_API_KEY     — or PAPERCLIP_CEO_AGENT_TOKEN once CEO is a real agent
#   PAPERCLIP_COMPANY_ID  — a951bb35-24a9-412a-bbcc-629c5acae619 for Go-North
#   PAPERCLIP_BASE_URL    — default http://localhost:3000
#
# Dedup: card description line 1 must begin with [GON-XX] — the sync script
# searches all cards for this string and upserts instead of recreating.

set -euo pipefail
PAPERCLIP_BASE_URL="${PAPERCLIP_BASE_URL:-http://localhost:3000}"

MISSING=()
for V in TRELLO_KEY TRELLO_TOKEN TRELLO_BOARD_ID TRELLO_LIST_IDS PAPERCLIP_API_KEY PAPERCLIP_COMPANY_ID; do
  [[ -z "${!V:-}" ]] && MISSING+=("$V")
done
if [[ ${#MISSING[@]} -gt 0 ]]; then
  echo "[ceo-trello-sync] ERROR: missing env vars: ${MISSING[*]}" >&2
  echo "[ceo-trello-sync] See agents/ceo-gonorth/config/trello.md" >&2
  exit 1
fi

TRELLO_BASE="https://api.trello.com/1"
AUTH="key=${TRELLO_KEY}&token=${TRELLO_TOKEN}"

log() { echo "[ceo-trello-sync] $*"; }

ISSUES_JSON=$(curl -sf -H "Authorization: Bearer ${PAPERCLIP_API_KEY}" \
  "${PAPERCLIP_BASE_URL}/api/companies/${PAPERCLIP_COMPANY_ID}/issues" || true)
[[ -z "$ISSUES_JSON" || "$ISSUES_JSON" == "null" ]] && { log "no issues; skipping"; exit 0; }

CARDS_JSON=$(curl -sf "${TRELLO_BASE}/boards/${TRELLO_BOARD_ID}/cards?${AUTH}&fields=id,name,desc,idList" || echo "[]")

list_for_status() {
  echo "$TRELLO_LIST_IDS" | python3 -c "import json,sys; m=json.load(sys.stdin); print(m.get('$1', m.get('todo','')))"
}

find_card() {
  echo "$CARDS_JSON" | python3 -c "
import json,sys
cards=json.load(sys.stdin); key='$1'
for c in cards:
    if key in (c.get('desc') or '') or key in (c.get('name') or ''):
        print(c['id']+'|'+c['idList']); sys.exit(0)
print('')"
}

post_comment_if_new() {
  local card_id="$1" text="$2" sig="$3"
  local existing
  existing=$(curl -sf "${TRELLO_BASE}/cards/${card_id}/actions?filter=commentCard&${AUTH}" || echo "[]")
  local already
  already=$(echo "$existing" | python3 -c "
import json,sys
a=json.load(sys.stdin); s='$sig'
for x in a:
    if s in (x.get('data',{}).get('text') or ''): print('yes'); sys.exit(0)
print('no')")
  [[ "$already" == "yes" ]] && return 0
  curl -sf -X POST "${TRELLO_BASE}/cards/${card_id}/actions/comments?${AUTH}" -d "text=${text}" > /dev/null
  log "  commentCard posted (sig: $sig)"
}

status_comment() {
  local key="$1" title="$2" st="$3"
  case "$st" in
    in_progress) echo "${key}: Work has started on \"${title}\". The team is building." ;;
    in_review)   echo "${key}: \"${title}\" is now in quality review." ;;
    done)        echo "${key}: \"${title}\" is complete and live." ;;
    blocked)     echo "${key}: \"${title}\" is on hold while we resolve a blocker." ;;
    *)           echo "${key}: Status updated to ${st}." ;;
  esac
}

echo "$ISSUES_JSON" | python3 -c "
import json,sys
d=json.load(sys.stdin)
issues=d['issues'] if isinstance(d,dict) and 'issues' in d else d
for i in issues:
    key=i.get('key') or i.get('issueKey') or ''
    title=i.get('title') or 'Untitled'
    status=i.get('status') or 'todo'
    pr=''
    for c in (i.get('comments') or []):
        b=c.get('body') or ''
        if 'bitbucket.org' in b and '/pullrequests/' in b:
            import re; m=re.search(r'https://[^\s]+/pullrequests/\d+',b)
            if m: pr=m.group(0); break
    print(json.dumps({'key':key,'title':title,'status':status,'pr':pr}))
" | while IFS= read -r LINE; do
  KEY=$(echo "$LINE"   | python3 -c "import json,sys;print(json.load(sys.stdin)['key'])")
  TITLE=$(echo "$LINE" | python3 -c "import json,sys;print(json.load(sys.stdin)['title'])")
  ST=$(echo "$LINE"    | python3 -c "import json,sys;print(json.load(sys.stdin)['status'])")
  PR=$(echo "$LINE"    | python3 -c "import json,sys;print(json.load(sys.stdin)['pr'])")
  [[ -z "$KEY" ]] && continue
  TARGET=$(list_for_status "$ST")
  [[ -z "$TARGET" ]] && { log "  no list for $ST; skip $KEY"; continue; }

  FOUND=$(find_card "$KEY")
  CARD_ID="" CUR_LIST=""
  [[ -n "$FOUND" ]] && { CARD_ID="${FOUND%%|*}"; CUR_LIST="${FOUND##*|}"; }

  PR_LINE=""; [[ -n "$PR" ]] && PR_LINE=$'\nPR: '"$PR"
  DESC="[${KEY}]
Paperclip issue: ${KEY}
Status: ${ST}${PR_LINE}"

  if [[ -z "$CARD_ID" ]]; then
    log "Creating card for $KEY"
    CARD_ID=$(curl -sf -X POST "${TRELLO_BASE}/cards?${AUTH}" \
      -d "name=[${KEY}] ${TITLE}" -d "desc=${DESC}" -d "idList=${TARGET}" \
      | python3 -c "import json,sys;print(json.load(sys.stdin)['id'])")
    post_comment_if_new "$CARD_ID" "$(status_comment "$KEY" "$TITLE" "$ST")" "status:${ST}"
  else
    curl -sf -X PUT "${TRELLO_BASE}/cards/${CARD_ID}?${AUTH}" -d "desc=${DESC}" > /dev/null
    if [[ "$CUR_LIST" != "$TARGET" ]]; then
      log "Moving $KEY card → list $TARGET (was $CUR_LIST)"
      curl -sf -X PUT "${TRELLO_BASE}/cards/${CARD_ID}?${AUTH}" -d "idList=${TARGET}" > /dev/null
      post_comment_if_new "$CARD_ID" "$(status_comment "$KEY" "$TITLE" "$ST")" "status:${ST}"
    fi
  fi
done
log "Sync complete."
