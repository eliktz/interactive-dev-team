#!/usr/bin/env bash
# digest-assembler — compose the PM daily digest from the activity_feed
# (file spillover v1; PG lands in M3) per pm-behavior-contract.md §1 narrative
# template.
#
# Usage:
#   ./scripts/digest-assembler.sh [--hours N] [--force] [--stub-feed PATH]
#                                  [--spine PATH] [--company SLUG]
#
# Exit codes:
#   0  digest emitted on stdout
#   3  quiet-hours suppression (use --force to override)
#   64 bad arguments
#   65 feed unreadable

set -euo pipefail

# --- args ---
HOURS=24
FORCE=0
STUB_FEED=""
SPINE_PATH=""
COMPANY_SLUG=""

usage() {
  cat <<EOF
digest-assembler — PM daily digest composer (M1)

Options:
  --hours N               window in hours (default 24)
  --force                 emit even during quiet hours (22:00-08:00 Asia/Jerusalem)
  --stub-feed PATH        read stub NDJSON instead of live feed
  --spine PATH            PRODUCT-SPINE.md path (default: companies/\$COMPANY/PRODUCT-SPINE.md)
  --company SLUG          company slug (default: go-north)
  -h | --help             print this and exit

Language: reads operator_language from PRODUCT-SPINE.md frontmatter (default: he).

EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --hours) HOURS="$2"; shift 2 ;;
    --hours=*) HOURS="${1#*=}"; shift ;;
    --force) FORCE=1; shift ;;
    --stub-feed) STUB_FEED="$2"; shift 2 ;;
    --stub-feed=*) STUB_FEED="${1#*=}"; shift ;;
    --spine) SPINE_PATH="$2"; shift 2 ;;
    --spine=*) SPINE_PATH="${1#*=}"; shift ;;
    --company) COMPANY_SLUG="$2"; shift 2 ;;
    --company=*) COMPANY_SLUG="${1#*=}"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown arg: $1" >&2; usage >&2; exit 64 ;;
  esac
done

: "${COMPANY_SLUG:=go-north}"

# --- locate repo + spine ---
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
[ -n "$SPINE_PATH" ] || SPINE_PATH="$REPO_ROOT/companies/$COMPANY_SLUG/PRODUCT-SPINE.md"

# --- resolve display_name (M5-revise) ---
# Prefer companies/<slug>/company.yml `display_name:`; fallback to titlecased slug.
COMPANY_YML="$REPO_ROOT/companies/$COMPANY_SLUG/company.yml"
COMPANY_DISPLAY_NAME=""
if [ -f "$COMPANY_YML" ]; then
  if command -v yq >/dev/null 2>&1; then
    COMPANY_DISPLAY_NAME="$(yq -r '.display_name // ""' "$COMPANY_YML" 2>/dev/null || true)"
  fi
  if [ -z "$COMPANY_DISPLAY_NAME" ]; then
    # Lightweight YAML grep fallback (single-line `display_name: "..."` form).
    COMPANY_DISPLAY_NAME="$(grep -E '^display_name:' "$COMPANY_YML" 2>/dev/null \
                              | head -n1 \
                              | sed -E 's/^display_name:[[:space:]]*"?([^"]*)"?[[:space:]]*$/\1/')"
  fi
fi
if [ -z "$COMPANY_DISPLAY_NAME" ]; then
  # Final fallback: titlecase the slug (go-north → Go-North).
  COMPANY_DISPLAY_NAME="$(printf '%s' "$COMPANY_SLUG" | awk -F- 'BEGIN{OFS="-"}{for(i=1;i<=NF;i++){$i=toupper(substr($i,1,1)) substr($i,2)}; print}')"
fi

# --- quiet-hours check (Asia/Jerusalem; 22:00-08:00) ---
is_quiet_hours() {
  # Quiet if local-Jerusalem hour in [22, 23] OR in [0, 7].
  local h
  h="$(TZ=Asia/Jerusalem date +%H)"
  # strip leading zero for arithmetic
  h="${h#0}"
  [ -z "$h" ] && h=0
  if [ "$h" -ge 22 ] || [ "$h" -lt 8 ]; then
    return 0
  fi
  return 1
}

if [ "$FORCE" -eq 0 ] && is_quiet_hours; then
  echo "digest-assembler: quiet hours (22:00-08:00 Asia/Jerusalem) — use --force to override" >&2
  exit 3
fi

# --- read operator_language from PRODUCT-SPINE frontmatter ---
OPERATOR_LANG="he"
if [ -f "$SPINE_PATH" ]; then
  detected="$(awk '
    /^---[[:space:]]*$/ { in_yaml = !in_yaml; next }
    in_yaml && $0 ~ /^operator_language:/ {
      sub(/^operator_language:[[:space:]]*/,"")
      gsub(/^"|"$/,"")
      gsub(/^'\''|'\''$/,"")
      print
      exit
    }
  ' "$SPINE_PATH" || true)"
  [ -n "$detected" ] && OPERATOR_LANG="$detected"
fi

# --- select feed source ---
FEED_PATH="${CC_ACTIVITY_FEED_PATH:-$REPO_ROOT/dev-activity-feed.ndjson}"
if [ -n "$STUB_FEED" ]; then
  FEED_PATH="$STUB_FEED"
fi

if [ ! -f "$FEED_PATH" ]; then
  echo "digest-assembler: feed not found at $FEED_PATH — emitting empty-state digest" >&2
  FEED_PATH=""
fi

# --- compute cutoff timestamp ---
# Use GNU date if available (date -d); fall back to BSD date -v (macOS); else
# a python one-liner.
CUTOFF_EPOCH=""
NOW_EPOCH="$(date -u +%s)"
CUTOFF_EPOCH=$(( NOW_EPOCH - HOURS * 3600 ))

iso_from_epoch() {
  # Try GNU, then BSD, then python.
  if date -u -d "@$1" +%FT%TZ >/dev/null 2>&1; then
    date -u -d "@$1" +%FT%TZ
  elif date -u -r "$1" +%FT%TZ >/dev/null 2>&1; then
    date -u -r "$1" +%FT%TZ
  else
    python3 -c "import datetime; print(datetime.datetime.utcfromtimestamp($1).strftime('%Y-%m-%dT%H:%M:%SZ'))"
  fi
}

CUTOFF_ISO="$(iso_from_epoch "$CUTOFF_EPOCH")"

# --- parse feed, keep only events within window ---
SHIPPED=()
NEXT=()
BLOCKERS=()
DECISIONS=()
TRELLO_LINK=""

if [ -n "$FEED_PATH" ] && [ -f "$FEED_PATH" ] && command -v jq >/dev/null 2>&1; then
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    ts="$(printf '%s' "$line" | jq -r '.ts // ""' 2>/dev/null || echo "")"
    [ -n "$ts" ] || continue
    # String comparison works because both are ISO-8601 UTC with same precision.
    if [ "$ts" \< "$CUTOFF_ISO" ]; then
      continue
    fi
    verb="$(printf '%s' "$line" | jq -r '.verb // ""')"
    object="$(printf '%s' "$line" | jq -r '.object // ""')"
    issue="$(printf '%s' "$line" | jq -r '."issue-ref" // .issue_ref // ""')"
    persona="$(printf '%s' "$line" | jq -r '.persona // ""')"
    label="$object"
    [ -n "$issue" ] && [ "$issue" != "null" ] && label="$object ($issue)"
    case "$verb" in
      shipped) SHIPPED+=("$label") ;;
      proposed|routed|reviewed) NEXT+=("$label (by $persona)") ;;
      blocked|escalated) BLOCKERS+=("$label (by $persona)") ;;
      decided|approved) DECISIONS+=("$label (by $persona)") ;;
    esac
    # Opportunistically pick the most-recent trello-card as the one link.
    case "$object" in
      trello-card|*trello*) TRELLO_LINK="https://trello.com/c/$(printf '%s' "$issue" | tr -d '\n')" ;;
    esac
  done <"$FEED_PATH"
fi

# --- render per language ---
render_he() {
  # Opener — bolded ONCE, via MarkdownV2 `*...*`.
  local opener="*סיכום יומי ל־${COMPANY_DISPLAY_NAME}*"
  echo "$opener"
  echo
  echo "*Goal:* (מטרה) — לקדם זרימת הצטרפות יציבה למשפחות שעוברות צפונה."
  echo "*Progress:* $(printf '%s' "${#SHIPPED[@]}") ארועי־שילוח ב־$HOURS השעות האחרונות."
  if [ "${#SHIPPED[@]}" -gt 0 ]; then
    echo "*Shipped today:*"
    for s in "${SHIPPED[@]}"; do echo "  - $s"; done
  else
    echo "*Shipped today:* —"
  fi
  if [ "${#NEXT[@]}" -gt 0 ]; then
    echo "*What next:*"
    for n in "${NEXT[@]:0:3}"; do echo "  - $n"; done
  else
    echo "*What next:* —"
  fi
  if [ "${#BLOCKERS[@]}" -gt 0 ]; then
    echo "*Blocker:* ${BLOCKERS[0]}"
  fi
  echo "*ETA:* מחר בבוקר."
  if [ "${#DECISIONS[@]}" -gt 0 ]; then
    echo "*Decision needed:* ${DECISIONS[0]}"
  fi
  if [ -n "$TRELLO_LINK" ]; then
    echo "One Trello link: $TRELLO_LINK"
  else
    echo "One Trello link: (pending Trello sync)"
  fi
}

render_en() {
  local opener="*Daily update for ${COMPANY_DISPLAY_NAME}*"
  echo "$opener"
  echo
  echo "*Goal:* keep the intake flow moving for families heading north."
  echo "*Progress:* ${#SHIPPED[@]} ship-events in the last $HOURS hours."
  if [ "${#SHIPPED[@]}" -gt 0 ]; then
    echo "*Shipped today:*"
    for s in "${SHIPPED[@]}"; do echo "  - $s"; done
  else
    echo "*Shipped today:* —"
  fi
  if [ "${#NEXT[@]}" -gt 0 ]; then
    echo "*What next:*"
    for n in "${NEXT[@]:0:3}"; do echo "  - $n"; done
  else
    echo "*What next:* —"
  fi
  if [ "${#BLOCKERS[@]}" -gt 0 ]; then
    echo "*Blocker:* ${BLOCKERS[0]}"
  fi
  echo "*ETA:* tomorrow morning."
  if [ "${#DECISIONS[@]}" -gt 0 ]; then
    echo "*Decision needed:* ${DECISIONS[0]}"
  fi
  if [ -n "$TRELLO_LINK" ]; then
    echo "One Trello link: $TRELLO_LINK"
  else
    echo "One Trello link: (pending Trello sync)"
  fi
}

case "$OPERATOR_LANG" in
  he|he-IL|heb|hebrew) render_he ;;
  *) render_en ;;
esac
