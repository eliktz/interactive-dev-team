#!/usr/bin/env bash
# trello-rewrite.sh — M2 build deliverable.
#
# Rewrites Trello card descriptions on the Go-North board to match the
# pm-behavior narrative template (product-framed; tech in collapsible
# <details>). Idempotent: each rewritten description starts with the marker
# `<!-- pm-template:1.1 -->` so re-runs skip already-migrated cards.
#
# Required env:
#   TRELLO_KEY          — Trello API key
#   TRELLO_TOKEN        — Trello API token
#   TRELLO_BOARD_ID     — board id (long form)
#
# Optional:
#   COMPANY             — defaults to "go-north"
#   BACKUP_DIR          — defaults to /paperclip/companies/$COMPANY/_backups
#   DRY_RUN             — true → print diffs only (also via --dry-run)
#
# Behaviour:
#   - GET /1/boards/<board>/cards (only `id,name,desc`)
#   - For each card lacking the marker:
#       1. capture old desc → backup file
#       2. compute new desc per pm-behavior template
#       3. PUT /1/cards/<id>?desc=...
#   - On --dry-run, print unified diff to stdout, write nothing.
#   - Backup file: /paperclip/companies/<company>/_backups/trello-descriptions-<ts>.json
#       JSON array of { id, name, prev_desc }.
#
# THIS SCRIPT IS NOT EXECUTED BY M2 BUILD. It is delivered + lint-clean only.
# M2-rest will run it under operator supervision.

set -euo pipefail

DRY_RUN="${DRY_RUN:-false}"
COMPANY="${COMPANY:-go-north}"
BACKUP_DIR_DEFAULT="/paperclip/companies/${COMPANY}/_backups"
BACKUP_DIR="${BACKUP_DIR:-$BACKUP_DIR_DEFAULT}"

PM_TEMPLATE_MARKER='<!-- pm-template:1.1 -->'

usage() {
  cat <<EOF
trello-rewrite.sh — rewrite Go-North Trello card descriptions to PM template.

Usage: trello-rewrite.sh [--dry-run] [--company NAME]

Env: TRELLO_KEY, TRELLO_TOKEN, TRELLO_BOARD_ID required.
EOF
}

while [ "$#" -gt 0 ] ; do
  case "$1" in
    --dry-run) DRY_RUN=true; shift ;;
    --company) COMPANY="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown arg: $1" >&2; usage >&2; exit 64 ;;
  esac
done

# Required env.
: "${TRELLO_KEY:?TRELLO_KEY required}"
: "${TRELLO_TOKEN:?TRELLO_TOKEN required}"
: "${TRELLO_BOARD_ID:?TRELLO_BOARD_ID required}"

# Required tools.
for tool in curl jq ; do
  if ! command -v "$tool" >/dev/null 2>&1 ; then
    echo "ERROR: required tool '$tool' not found in PATH" >&2
    exit 70
  fi
done

# ----------------------------------------------------------------- helpers --

trello_auth() {
  printf 'key=%s&token=%s' "$TRELLO_KEY" "$TRELLO_TOKEN"
}

fetch_cards() {
  local board="$1"
  curl -fsSL --max-time 30 \
    "https://api.trello.com/1/boards/${board}/cards?fields=id,name,desc&$(trello_auth)"
}

# Build a PM-template description, given the card name + optional issue-ref +
# the original tech-framed description. Output: a markdown body that starts
# with the marker.
build_new_desc() {
  local name="$1" prev="$2"
  cat <<EOF
$PM_TEMPLATE_MARKER

> Why this matters: ${name} — see top-line user outcome below.

**What this is**

(One-sentence product-framed summary of what shipped or is in flight, in
operator-readable language. The PM agent fills this in on first re-run with
context from team-memory.)

**Status**

(Shipped / In progress / Scoping / Blocked.)

**Why this matters to users**

(One bullet. User outcome only — not implementation.)

**Decisions waiting**

— or — (one yes/no question with default + deadline.)

<details><summary>Technical detail (for the dev team)</summary>

\`\`\`
${prev}
\`\`\`

</details>
EOF
}

# ----------------------------------------------------------------- main ----

ts="$(date -u +%Y%m%dT%H%M%SZ)"
backup_file="${BACKUP_DIR}/trello-descriptions-${ts}.json"

if [ "$DRY_RUN" = "true" ] ; then
  echo "DRY-RUN — no Trello writes, no backup file."
else
  mkdir -p "$BACKUP_DIR"
  echo "[" >"$backup_file"
fi

cards_json="$(fetch_cards "$TRELLO_BOARD_ID")"
total="$(printf '%s' "$cards_json" | jq 'length')"
echo "Fetched $total cards from board $TRELLO_BOARD_ID"

skipped=0; rewritten=0; failed=0; first=true

# Stream-iterate so the backup file remains a valid JSON array.
while IFS=$'\t' read -r id name desc ; do
  # Skip if already migrated (idempotency).
  if printf '%s' "$desc" | grep -qF "$PM_TEMPLATE_MARKER" ; then
    skipped=$((skipped + 1))
    continue
  fi

  new_desc="$(build_new_desc "$name" "$desc")"

  if [ "$DRY_RUN" = "true" ] ; then
    echo "----- DIFF for $id ($name) -----"
    diff -u <(printf '%s' "$desc") <(printf '%s' "$new_desc") || true
    rewritten=$((rewritten + 1))
    continue
  fi

  # Append to backup as a JSON array element.
  if [ "$first" = "true" ] ; then
    first=false
  else
    echo "," >>"$backup_file"
  fi
  jq -n --arg id "$id" --arg name "$name" --arg prev_desc "$desc" \
    '{id:$id, name:$name, prev_desc:$prev_desc}' >>"$backup_file"

  # PUT the new desc.
  if curl -fsSL -X PUT --max-time 30 \
      --data-urlencode "desc=${new_desc}" \
      "https://api.trello.com/1/cards/${id}?$(trello_auth)" \
      >/dev/null ; then
    rewritten=$((rewritten + 1))
  else
    failed=$((failed + 1))
    echo "WARN: PUT failed for card $id ($name)" >&2
  fi
done < <(printf '%s' "$cards_json" | jq -r '.[] | [.id, .name, (.desc // "")] | @tsv')

if [ "$DRY_RUN" != "true" ] ; then
  echo "]" >>"$backup_file"
  echo "Backup written to $backup_file"
fi

echo "Done. rewritten=$rewritten skipped=$skipped failed=$failed total=$total"
