#!/usr/bin/env bash
# bootstrap-company.sh — M5.
# Scaffold a new company namespace from templates/.
#
# Usage:
#   scripts/bootstrap-company.sh <slug> [--language he|en]
#                                       [--north-star "..."]
#                                       [--display-name "..."]
#                                       [--telegram-group-id "..."]
#                                       [--paperclip-company-id "..."]
#                                       [--operator-tz "Asia/Jerusalem"]
#                                       [--force]
#                                       [--no-paperclip]
#
# Renders companies/<slug>/ from companies/_template/ and per-persona
# agents/<slug>-<persona>/ dirs from templates/agent-base/, substituting
# {{COMPANY_*}}, {{PERSONA_*}} variables.
#
# Default persona list: ceo, captain, ux. (Match company.yml persona_list.)
#
# Operator follow-up actions are NOT performed automatically:
#   - Telegram bot creation + group attach
#   - L5 policy ack signing
#   - Paperclip company row insert (use --no-paperclip to skip the API call)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

LANG_DEFAULT="he"
TZ_DEFAULT="Asia/Jerusalem"

SLUG=""
LANGUAGE="$LANG_DEFAULT"
NORTH_STAR="(north star — operator to define)"
DISPLAY_NAME=""
TELEGRAM_GROUP_ID=""
PAPERCLIP_COMPANY_ID=""
OPERATOR_TZ="$TZ_DEFAULT"
FORCE=0
NO_PAPERCLIP=0

usage() {
  sed -n '2,18p' "$0" >&2
  exit "${1:-2}"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --language) LANGUAGE="$2"; shift 2 ;;
    --north-star) NORTH_STAR="$2"; shift 2 ;;
    --display-name) DISPLAY_NAME="$2"; shift 2 ;;
    --telegram-group-id) TELEGRAM_GROUP_ID="$2"; shift 2 ;;
    --paperclip-company-id) PAPERCLIP_COMPANY_ID="$2"; shift 2 ;;
    --operator-tz) OPERATOR_TZ="$2"; shift 2 ;;
    --force) FORCE=1; shift ;;
    --no-paperclip) NO_PAPERCLIP=1; shift ;;
    -h|--help) usage 0 ;;
    -*) echo "unknown flag: $1" >&2; usage 2 ;;
    *) if [ -z "$SLUG" ]; then SLUG="$1"; shift; else echo "unexpected arg: $1" >&2; usage 2; fi ;;
  esac
done

[ -n "$SLUG" ] || { echo "missing <slug>" >&2; usage 2; }
[[ "$SLUG" =~ ^[a-z][a-z0-9-]*$ ]] || { echo "slug must be lowercase alphanumeric+dashes (got: $SLUG)" >&2; exit 2; }
SLUG_UPPER="$(echo "$SLUG" | tr '[:lower:]' '[:upper:]' | tr - _)"
[ -n "$DISPLAY_NAME" ] || DISPLAY_NAME="$(echo "$SLUG" | sed 's/-/ /g; s/.*/\u&/')"

COMPANY_DIR="${REPO_ROOT}/companies/${SLUG}"
TPL_COMPANY="${REPO_ROOT}/companies/_template"
TPL_AGENT="${REPO_ROOT}/templates/agent-base"
LOG="${COMPANY_DIR}/bootstrap.log"
TS="$(date -u +%FT%TZ)"

PERSONAS_DEFAULT="ceo captain ux"

if [ -d "$COMPANY_DIR" ] && [ "$FORCE" != "1" ]; then
  echo "ERROR: $COMPANY_DIR already exists. Use --force to overwrite." >&2
  exit 3
fi

[ -d "$TPL_COMPANY" ] || { echo "missing $TPL_COMPANY" >&2; exit 4; }
[ -d "$TPL_AGENT" ] || { echo "missing $TPL_AGENT" >&2; exit 4; }

# Pre-flight: ensure none of the per-persona dirs exist (or --force them).
for p in $PERSONAS_DEFAULT; do
  d="${REPO_ROOT}/agents/${SLUG}-${p}"
  if [ -d "$d" ] && [ "$FORCE" != "1" ]; then
    echo "ERROR: $d already exists. Use --force to overwrite." >&2
    exit 3
  fi
done

mkdir -p "$COMPANY_DIR"

if [ -z "$PAPERCLIP_COMPANY_ID" ] && command -v uuidgen >/dev/null 2>&1; then
  PAPERCLIP_COMPANY_ID="$(uuidgen | tr '[:upper:]' '[:lower:]')"
elif [ -z "$PAPERCLIP_COMPANY_ID" ]; then
  PAPERCLIP_COMPANY_ID="00000000-0000-0000-0000-000000000000"
fi

# Render a file with placeholder substitution. Args: src dst [extra-sed-pairs]
render() {
  local src="$1" dst="$2"; shift 2
  local tmp
  tmp="$(mktemp)"
  cp "$src" "$tmp"
  sed -i \
    -e "s|{{COMPANY_SLUG}}|${SLUG}|g" \
    -e "s|{{COMPANY_SLUG_UPPER}}|${SLUG_UPPER}|g" \
    -e "s|{{COMPANY_DISPLAY_NAME}}|${DISPLAY_NAME}|g" \
    -e "s|{{NORTH_STAR}}|${NORTH_STAR}|g" \
    -e "s|{{NORTH_STAR_METRIC}}|${NORTH_STAR}|g" \
    -e "s|{{OPERATOR_LANGUAGE}}|${LANGUAGE}|g" \
    -e "s|{{OPERATOR_TZ}}|${OPERATOR_TZ}|g" \
    -e "s|{{TELEGRAM_GROUP_ID}}|${TELEGRAM_GROUP_ID}|g" \
    -e "s|{{PAPERCLIP_COMPANY_ID}}|${PAPERCLIP_COMPANY_ID}|g" \
    -e "s|{{TIMESTAMP}}|${TS}|g" \
    -e "s|{{THEME_A}}|theme-A|g" \
    -e "s|{{THEME_B}}|theme-B|g" \
    -e "s|{{THEME_C}}|theme-C|g" \
    "$tmp"
  while [ $# -ge 2 ]; do
    sed -i -e "s|$1|$2|g" "$tmp"
    shift 2
  done
  mkdir -p "$(dirname "$dst")"
  mv "$tmp" "$dst"
}

# Render company-level files.
render "${TPL_COMPANY}/COMPANY.md.tmpl"        "${COMPANY_DIR}/COMPANY.md"
render "${TPL_COMPANY}/PRODUCT-SPINE.md.tmpl"  "${COMPANY_DIR}/PRODUCT-SPINE.md"
render "${TPL_COMPANY}/company.yml.tmpl"       "${COMPANY_DIR}/company.yml"

# Render per-persona dirs. Persona attrs are read from company.yml; for the
# default 3 personas we use baked defaults to avoid a YAML parser dep.
declare -A NAMES TITLES PREFIXES VOICES ESCALATES SPEAKS
NAMES[ceo]="Galileo";        TITLES[ceo]="Product Manager";        PREFIXES[ceo]="🧭 PM · Galileo:"; VOICES[ceo]="Warm, direct, product-first. Speaks to a non-technical operator."; ESCALATES[ceo]="null";                 SPEAKS[ceo]="You see ALL group messages. Respond when addressed by name/role, when the topic is in your product lane, when Captain routes to you, or when a human asks a product question nobody else is handling."
NAMES[captain]="Captain";    TITLES[captain]="Execution Coordinator"; PREFIXES[captain]="🧭 Captain:"; VOICES[captain]="Briefing-style, short, technical-tolerant (agent-facing)."; ESCALATES[captain]="${SLUG}-ceo";  SPEAKS[captain]="You see ALL group messages. Stay silent on product chit-chat — that's the CEO's lane. Respond on sprint/scrum/coordination topics; route technical/product questions to the right persona."
NAMES[ux]="Iris";            TITLES[ux]="UX Designer";              PREFIXES[ux]="🎨 UX · Iris:";   VOICES[ux]="Visual-first, asks operator about flows, shares mockup links."; ESCALATES[ux]="${SLUG}-ceo";                 SPEAKS[ux]="Stay silent in group chat unless addressed by name/role, the topic is UX/design/layout/colors/flow/visual/mobile/RTL, Captain routes to you, or a human asks a design question nobody else is handling."

for persona in $PERSONAS_DEFAULT; do
  agent_slug="${SLUG}-${persona}"
  agent_dir="${REPO_ROOT}/agents/${agent_slug}"
  mkdir -p "${agent_dir}/.claude" "${agent_dir}/hooks" "${agent_dir}/memory"
  pname="${NAMES[$persona]}"
  ptitle="${TITLES[$persona]}"
  pprefix="${PREFIXES[$persona]}"
  pvoice="${VOICES[$persona]}"
  pesc="${ESCALATES[$persona]}"
  pspeak="${SPEAKS[$persona]}"

  for tmpl in IDENTITY CLAUDE SOUL AGENTS TOOLS; do
    render "${TPL_AGENT}/${tmpl}.md.tmpl" "${agent_dir}/${tmpl}.md" \
      "{{PERSONA_NAME}}" "${pname}" \
      "{{PERSONA_SLUG}}" "${persona}" \
      "{{PERSONA_PREFIX}}" "${pprefix}" \
      "{{PERSONA_TITLE}}" "${ptitle}" \
      "{{PERSONA_VOICE}}" "${pvoice}" \
      "{{ESCALATES_TO}}" "${pesc}" \
      "{{WHEN_TO_SPEAK}}" "${pspeak}"
  done
  render "${TPL_AGENT}/.claude/settings.json.tmpl" "${agent_dir}/.claude/settings.json" \
    "{{PERSONA_SLUG}}" "${persona}"

  # Hooks are persona-agnostic — copy verbatim.
  cp "${TPL_AGENT}/hooks/"*.sh "${agent_dir}/hooks/"
  chmod +x "${agent_dir}/hooks/"*.sh
done

# Optional: insert paperclip company row (best-effort, non-fatal).
PAPERCLIP_RESULT="skipped"
if [ "$NO_PAPERCLIP" != "1" ] && command -v psql >/dev/null 2>&1; then
  PAPERCLIP_PG_URL="${PAPERCLIP_PG_URL:-postgresql://paperclip:paperclip@127.0.0.1:54329/paperclip}"
  if psql "$PAPERCLIP_PG_URL" -c "SELECT 1 FROM information_schema.tables WHERE table_name='companies'" -tA 2>/dev/null | grep -q 1 ; then
    if psql "$PAPERCLIP_PG_URL" -c "INSERT INTO companies (id, name, description, status) VALUES ('${PAPERCLIP_COMPANY_ID}', '${DISPLAY_NAME}', 'slug:${SLUG} — ${NORTH_STAR}', 'active') ON CONFLICT (id) DO NOTHING" 2>>"$LOG" ; then
      PAPERCLIP_RESULT="inserted ${PAPERCLIP_COMPANY_ID}"
    else
      PAPERCLIP_RESULT="psql insert failed (see log)"
    fi
  else
    PAPERCLIP_RESULT="paperclip 'companies' table not found (skipped)"
  fi
fi

{
  echo "[${TS}] bootstrap-company.sh slug=${SLUG} display='${DISPLAY_NAME}' lang=${LANGUAGE} tz=${OPERATOR_TZ}"
  echo "north_star: ${NORTH_STAR}"
  echo "telegram_group_id: ${TELEGRAM_GROUP_ID:-(unset)}"
  echo "paperclip_company_id: ${PAPERCLIP_COMPANY_ID}"
  echo "paperclip_row: ${PAPERCLIP_RESULT}"
  echo "personas: ${PERSONAS_DEFAULT}"
} >> "$LOG"

cat <<EOF
[bootstrap-company] DONE — slug=${SLUG}

Created:
  - ${COMPANY_DIR}/{COMPANY.md, PRODUCT-SPINE.md, company.yml, bootstrap.log}
  - agents/${SLUG}-{ceo,captain,ux}/ (IDENTITY, SOUL, AGENTS, TOOLS, CLAUDE, .claude/settings.json, hooks/)

Paperclip row: ${PAPERCLIP_RESULT}

Next steps (operator):
  1. Create Telegram bots (one per persona) via @BotFather, set tokens
     in env vars, attach to group ${TELEGRAM_GROUP_ID:-<TBD>}.
  2. Sign L5-POLICY-ACK.md.tmpl for the operator.
  3. Edit companies/${SLUG}/PRODUCT-SPINE.md to fill in Mission, Themes,
     Milestones, Current State.
  4. (Optional) Bind-mount agents/${SLUG}-* into running war-room container,
     OR wait for next image rebuild — files are picked up on next claude run.
EOF
