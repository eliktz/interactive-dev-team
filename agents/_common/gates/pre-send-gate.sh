#!/usr/bin/env bash
# pre-send-gate.sh — M2 PreToolUse gate for war-room operator-facing surfaces.
#
# Wired by the per-persona PreToolUse hook (settings.json matcher targets the
# Telegram/Trello/Paperclip outbound tools). Reads the Claude Code PreToolUse
# JSON envelope from stdin, applies the checks below, and returns a hook
# decision per `GATE_MODE`:
#
#   GATE_MODE=log     — pass through, append to $TONE_LOG. Always: {"decision":"continue"}.
#                       Latency target: <500ms p99 (no LLM call).
#   GATE_MODE=rewrite — on violation, ask Anthropic Haiku to rewrite the body and
#                       return {"decision":"modify","modified_input":{...}}.
#                       Latency target: <3s p99 (Haiku timeout 3000ms; on timeout
#                       degrade to log + pass-through).
#   GATE_MODE=block   — on HARD violation, return {"decision":"block","reason":...}
#                       so the agent re-drafts. SOFT still routes to rewrite.
#
# Checks (first hit wins):
#   1. Audience detection — operator vs. internal. Internal channels get a
#      relaxed pass; only stakeholder/operator audiences enforce E1/E2/banlist.
#   2. E1 Telegram bold check (pm-behavior §1.3) — count bold spans + ratio.
#       HARD: > 2 spans, OR full-sentence bold, OR ratio > 30%.
#       SOFT: 1-2 spans but visually noisy.
#   3. E2 language consistency (pm-behavior §1.2b) — Hebrew vs Latin char
#       balance, excluding URLs + whitelist proper nouns.
#       HARD: > 10% opposite-script chars in operator-facing.
#       SOFT: 1-10%.
#   4. Banlist scan (pm-behavior §1.2 / §2.2 via banlist.yml).
#       HARD: any HARD-banlist token.
#       SOFT: any SOFT-banlist token.
#   5. Length + format — Telegram message line cap, no code fences in
#       operator-facing.
#
# Fail-soft behaviour:
#   - missing jq         → log "jq unavailable" + pass-through (continue)
#   - missing Haiku key  → degrade to log mode automatically
#   - Haiku timeout      → return original + log
#   - bad stdin JSON     → continue (don't block on harness flake)
#
# Side-effects:
#   - Appends one ndjson line per fired check to ${GATE_LOG:-/tmp/pre-send-gate.ndjson}
#   - Appends a human-readable line to ${TONE_LOG:-/tmp/tone-rewrites.log}

set -euo pipefail

# ----------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------

_psg_log() {
  # $1 = level, $2... = message
  local lvl="$1"; shift
  local ts; ts="$(date -u +%FT%TZ)"
  printf '[%s] [pre-send-gate] [%s] %s\n' "$ts" "$lvl" "$*" \
    >>"${PSG_DEBUG_LOG:-/tmp/pre-send-gate.debug.log}" 2>/dev/null || true
}

_psg_emit_continue() {
  printf '{"decision":"continue"}\n'
}

_psg_emit_modify() {
  # $1 = JSON-encoded modified_input object, e.g. {"text":"..."}
  printf '{"decision":"modify","modified_input":%s}\n' "$1"
}

_psg_emit_block() {
  # $1 = reason string (will be JSON-escaped via jq)
  local reason
  if command -v jq >/dev/null 2>&1; then
    reason="$(printf '%s' "$1" | jq -Rs .)"
  else
    reason="\"$(printf '%s' "$1" | tr -d '"\n')\""
  fi
  printf '{"decision":"block","reason":%s}\n' "$reason"
}

_psg_append_gate_log() {
  # $1 = ndjson line (already encoded). Append-only.
  local target="${GATE_LOG:-/tmp/pre-send-gate.ndjson}"
  printf '%s\n' "$1" >>"$target" 2>/dev/null || true
}

_psg_append_tone_log() {
  # $1 = persona, $2 = level, $3 = check, $4 = detail
  local target="${TONE_LOG:-/tmp/tone-rewrites.log}"
  local ts; ts="$(date -u +%FT%TZ)"
  printf '%s  %s  %s-%s  %s\n' "$ts" "${1:-unknown}" "$3" "$2" "$4" \
    >>"$target" 2>/dev/null || true
}

# ----------------------------------------------------------------------------
# Audience detection
# Returns one of: operator | internal | unknown
# ----------------------------------------------------------------------------
_psg_detect_audience() {
  local tool_name="$1" tool_input_json="$2"

  # Strongest signal: tool name.
  case "$tool_name" in
    *telegram*sendMessage*|mcp__telegram__*|mcp__plugin_telegram_telegram__reply)
      # Most Telegram outbound is operator-facing. The persona may target an
      # internal channel via chat_id; we'd refine here per company.
      printf 'operator'; return 0 ;;
    *trello__*)
      printf 'operator'; return 0 ;;
    *paperclip*comment*)
      # Paperclip: relax unless explicitly @operator-tagged.
      if printf '%s' "$tool_input_json" | grep -qiE '@operator|requires_human_decision' ; then
        printf 'operator'; return 0
      fi
      printf 'internal'; return 0 ;;
    mcp__bitbucket__add_pr_comment)
      printf 'internal'; return 0 ;;
    *)
      printf 'unknown'; return 0 ;;
  esac
}

# ----------------------------------------------------------------------------
# Extract message body from common tool_input shapes.
# ----------------------------------------------------------------------------
_psg_extract_message() {
  local tool_input_json="$1"
  if ! command -v jq >/dev/null 2>&1; then
    printf '%s' "$tool_input_json"
    return 0
  fi
  printf '%s' "$tool_input_json" \
    | jq -r '.text // .message // .body // .comment // .desc // .description // ""' \
    2>/dev/null || true
}

# ----------------------------------------------------------------------------
# E1 — Telegram bold check (pm-behavior §1.3)
# ----------------------------------------------------------------------------
_psg_check_bold() {
  # $1 = message body
  # Returns severity on stdout: "HARD <reason>" / "SOFT <reason>" / "" (clean)
  local msg="$1"
  [ -z "$msg" ] && return 0

  # Count bold spans. Greedy match for *...* pairs (MarkdownV2 single-asterisk),
  # then for **...** pairs. Sum.
  local single_count double_count total_spans
  single_count="$(printf '%s' "$msg" | grep -oE '\*[^*]+\*' | wc -l | tr -d ' ' || true)"
  double_count="$(printf '%s' "$msg" | grep -oE '\*\*[^*]+\*\*' | wc -l | tr -d ' ' || true)"
  total_spans=$((single_count + double_count))

  # Bold-char ratio: characters inside any bold span / total chars.
  local total_chars bold_chars ratio_pct
  total_chars="$(printf '%s' "$msg" | wc -c | tr -d ' ')"
  bold_chars="$(printf '%s' "$msg" | grep -oE '\*\*?[^*]+\*\*?' | tr -d '*' | wc -c | tr -d ' ' || true)"
  if [ "${total_chars:-0}" -gt 0 ] ; then
    ratio_pct=$(( (bold_chars * 100) / total_chars ))
  else
    ratio_pct=0
  fi

  # Whole-sentence bold detection: a span whose contents end with terminal
  # punctuation . ? ! or contain >5 words AND no surrounding non-bold text.
  if printf '%s' "$msg" | grep -qE '^\s*\*\*?[^*]+(\.|\?|\!)\s*\*\*?\s*$' ; then
    printf 'HARD whole-sentence-bold'
    return 0
  fi

  if [ "$total_spans" -gt 2 ] ; then
    printf 'HARD bold-spans=%d (>2)' "$total_spans"
    return 0
  fi
  if [ "$ratio_pct" -gt 30 ] ; then
    printf 'HARD bold-ratio=%d%% (>30%%)' "$ratio_pct"
    return 0
  fi

  # SOFT: 2 spans AND elevated ratio (visually noisy but within hard limits).
  if [ "$total_spans" -eq 2 ] && [ "$ratio_pct" -gt 20 ] ; then
    printf 'SOFT bold-ratio=%d%% spans=2 (visually-noisy)' "$ratio_pct"
    return 0
  fi
  return 0
}

# ----------------------------------------------------------------------------
# E2 — Language consistency (pm-behavior §1.2b)
# Hebrew chars: U+0590-U+05FF. Latin chars: A-Za-z.
# ----------------------------------------------------------------------------
_psg_check_language() {
  # $1 = message body
  # Returns severity on stdout: "HARD ..." / "SOFT ..." / ""
  local msg="$1"
  [ -z "$msg" ] && return 0

  # Strip URLs and whitelist proper nouns before counting (§1.2b whitelist).
  local stripped
  stripped="$(printf '%s' "$msg" \
    | sed -E 's#https?://[^[:space:]]+##g' \
    | sed -E 's#\b(Paperclip|Trello|GitHub|Bitbucket|Telegram|Galileo|Iris|Captain)\b##g' \
    | sed -E 's#GON-[0-9]+##g' )"

  # Count Hebrew chars and Latin chars in the stripped body.
  local hebrew_count latin_count
  # Hebrew block: 0x05D0-0x05EA (letters). Use a perl one-liner if available
  # for proper UTF-8 counting; fallback to grep -P / -E with \p approximations.
  if command -v perl >/dev/null 2>&1 ; then
    hebrew_count=$(printf '%s' "$stripped" | perl -CSD -ne 'BEGIN{$c=0} $c += () = /\p{Hebrew}/g; END{print $c}')
    latin_count=$(printf '%s'  "$stripped" | perl -CSD -ne 'BEGIN{$c=0} $c += () = /[A-Za-z]/g;  END{print $c}')
  else
    # crude byte-level approximation: Hebrew letters are 2-byte UTF-8 starting
    # with 0xD7 (215). Count bytes 0xD7 then divide by 1.
    hebrew_count="$(printf '%s' "$stripped" | LC_ALL=C grep -oP '\xD7.' 2>/dev/null | wc -l | tr -d ' ' || echo 0)"
    latin_count="$(printf '%s' "$stripped" | LC_ALL=C grep -oE '[A-Za-z]' | wc -l | tr -d ' ' || echo 0)"
  fi
  hebrew_count="${hebrew_count:-0}"
  latin_count="${latin_count:-0}"

  local total opposite ratio_pct
  total=$(( hebrew_count + latin_count ))
  [ "$total" -lt 4 ] && return 0   # too short to call

  # Determine dominant script and "opposite" count.
  if [ "$hebrew_count" -ge "$latin_count" ] ; then
    opposite="$latin_count"
  else
    opposite="$hebrew_count"
  fi
  ratio_pct=$(( (opposite * 100) / total ))

  if [ "$ratio_pct" -gt 10 ] ; then
    printf 'HARD opposite-script=%d%% (>10%%)' "$ratio_pct"
    return 0
  fi
  if [ "$ratio_pct" -ge 1 ] ; then
    printf 'SOFT opposite-script=%d%% (1-10%%)' "$ratio_pct"
    return 0
  fi
  return 0
}

# ----------------------------------------------------------------------------
# Banlist scan — pm-behavior §1.2 / §2.2 via banlist.yml.
# ----------------------------------------------------------------------------
_psg_load_banlist_patterns() {
  # Args: $1 = "hard" | "soft", $2 = banlist.yml path
  # Stdout: one extended-regex pattern per line.
  local section="$1" path="$2"
  [ -f "$path" ] || return 0
  awk -v sec="$section:" '
    BEGIN { active=0 }
    /^[a-zA-Z_]+:/ { active = ($0 == sec) ? 1 : 0; next }
    active && /^[[:space:]]*-[[:space:]]*/ {
      sub(/^[[:space:]]*-[[:space:]]*/, "")
      gsub(/^[[:space:]]*\047/, "")    # strip leading single quote
      gsub(/\047[[:space:]]*$/, "")    # strip trailing single quote
      gsub(/^[[:space:]]*"/, "")
      gsub(/"[[:space:]]*$/, "")
      print
    }
  ' "$path"
}

_psg_check_banlist() {
  # $1 = message, $2 = banlist.yml path
  # Returns severity on stdout: "HARD <hits>" / "SOFT <hits>" / ""
  local msg="$1" yml="$2"
  [ -z "$msg" ] && return 0

  local hard_hits soft_hits
  hard_hits=""
  soft_hits=""

  while IFS= read -r pat; do
    [ -z "$pat" ] && continue
    if printf '%s' "$msg" | grep -qiE -- "$pat" 2>/dev/null ; then
      hard_hits="${hard_hits}${pat};"
    fi
  done < <(_psg_load_banlist_patterns hard "$yml")

  if [ -n "$hard_hits" ] ; then
    printf 'HARD banlist-hard=%s' "$hard_hits"
    return 0
  fi

  while IFS= read -r pat; do
    [ -z "$pat" ] && continue
    if printf '%s' "$msg" | grep -qiE -- "$pat" 2>/dev/null ; then
      soft_hits="${soft_hits}${pat};"
    fi
  done < <(_psg_load_banlist_patterns soft "$yml")

  if [ -n "$soft_hits" ] ; then
    printf 'SOFT banlist-soft=%s' "$soft_hits"
    return 0
  fi
  return 0
}

# ----------------------------------------------------------------------------
# Length + format (pm-behavior §1.2)
# ----------------------------------------------------------------------------
_psg_check_length_format() {
  # $1 = message, $2 = tool_name (informs cap)
  local msg="$1" tool="$2"
  [ -z "$msg" ] && return 0

  # No code fences in operator-facing.
  if printf '%s' "$msg" | grep -q '```' ; then
    printf 'HARD code-fence-in-operator'
    return 0
  fi

  # Telegram digest cap: 8 lines (soft); event ping: 4 lines.
  case "$tool" in
    *telegram*)
      local lines; lines="$(printf '%s\n' "$msg" | wc -l | tr -d ' ')"
      if [ "$lines" -gt 12 ] ; then
        printf 'SOFT length-lines=%d (>12)' "$lines"
        return 0
      fi
      ;;
  esac
  return 0
}

# ----------------------------------------------------------------------------
# Haiku rewrite (rewrite mode only). 3s timeout. Fail-soft to original.
# ----------------------------------------------------------------------------
_psg_haiku_rewrite() {
  # $1 = original msg, $2 = reason string for context.
  local orig="$1" reason="$2"

  if [ -z "${ANTHROPIC_API_KEY:-}" ] ; then
    _psg_log warn "no ANTHROPIC_API_KEY — cannot rewrite, returning original"
    printf '%s' "$orig"
    return 0
  fi
  if ! command -v curl >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1 ; then
    _psg_log warn "curl or jq missing — cannot rewrite"
    printf '%s' "$orig"
    return 0
  fi

  local prompt
  prompt="You are a register-rewriter. Rewrite the following operator-facing message to fix this violation: ${reason}. Keep the meaning. Strip dev jargon, file paths, commit SHAs, code fences. Match the dominant language of the original (Hebrew or English). Output ONLY the rewritten message body, no preamble. Original:\n\n${orig}"

  local body
  body="$(jq -n --arg p "$prompt" '{
    model: "claude-haiku-4-5",
    max_tokens: 1024,
    messages: [ { role: "user", content: $p } ]
  }')"

  # 3s connect+read timeout. On any failure, return original.
  local resp
  if resp="$(curl -sS --max-time 3 \
    -H 'content-type: application/json' \
    -H "x-api-key: ${ANTHROPIC_API_KEY}" \
    -H 'anthropic-version: 2023-06-01' \
    -d "$body" \
    https://api.anthropic.com/v1/messages 2>/dev/null)" ; then
    local rewritten
    rewritten="$(printf '%s' "$resp" | jq -r '.content[0].text // ""' 2>/dev/null || true)"
    if [ -n "$rewritten" ] && [ "$rewritten" != "null" ] ; then
      printf '%s' "$rewritten"
      return 0
    fi
  fi
  _psg_log warn "haiku call failed/timeout — returning original"
  printf '%s' "$orig"
}

# ----------------------------------------------------------------------------
# MAIN
# ----------------------------------------------------------------------------

GATE_MODE="${GATE_MODE:-log}"
BANLIST_YML="${BANLIST_YML:-$(cd "$(dirname "$0")/../../../templates/agent-base/contracts" 2>/dev/null && pwd)/banlist.yml}"
PERSONA="${PERSONA:-${CC_PERSONA:-unknown}}"

# Read stdin once.
if [ -t 0 ] ; then
  _psg_log warn "stdin is TTY — no payload, passing through"
  _psg_emit_continue
  exit 0
fi

PSG_INPUT="$(cat 2>/dev/null || true)"
if [ -z "$PSG_INPUT" ] ; then
  _psg_emit_continue
  exit 0
fi

if ! command -v jq >/dev/null 2>&1 ; then
  _psg_log warn "jq missing — cannot parse harness JSON, passing through"
  _psg_emit_continue
  exit 0
fi

TOOL_NAME="$(printf '%s' "$PSG_INPUT" | jq -r '.tool_name // .tool // ""' 2>/dev/null || true)"
TOOL_INPUT_JSON="$(printf '%s' "$PSG_INPUT" | jq -c '.tool_input // .toolInput // {}' 2>/dev/null || echo '{}')"

# 1. Audience.
AUDIENCE="$(_psg_detect_audience "$TOOL_NAME" "$TOOL_INPUT_JSON")"
if [ "$AUDIENCE" = "internal" ] || [ "$AUDIENCE" = "unknown" ] ; then
  # Internal-channel: relaxed — pass through. Still log audience for audit.
  _psg_log info "audience=$AUDIENCE tool=$TOOL_NAME → pass-through"
  _psg_emit_continue
  exit 0
fi

MSG="$(_psg_extract_message "$TOOL_INPUT_JSON")"
if [ -z "$MSG" ] ; then
  _psg_emit_continue
  exit 0
fi

# Run all checks; collect first violation (HARD wins over SOFT).
VERDICT_LEVEL=""
VERDICT_CHECK=""
VERDICT_DETAIL=""

_psg_register_verdict() {
  # $1 = level ("HARD"|"SOFT"), $2 = check name, $3 = detail
  local lvl="$1" check="$2" detail="$3"
  if [ -z "$VERDICT_LEVEL" ] || { [ "$VERDICT_LEVEL" = "SOFT" ] && [ "$lvl" = "HARD" ] ; } ; then
    VERDICT_LEVEL="$lvl"
    VERDICT_CHECK="$check"
    VERDICT_DETAIL="$detail"
  fi
}

# 2. E1 bold.
out="$(_psg_check_bold "$MSG" || true)"
if [ -n "$out" ] ; then
  level="${out%% *}"; detail="${out#* }"
  _psg_register_verdict "$level" "bold" "$detail"
fi

# 3. E2 language.
out="$(_psg_check_language "$MSG" || true)"
if [ -n "$out" ] ; then
  level="${out%% *}"; detail="${out#* }"
  _psg_register_verdict "$level" "language" "$detail"
fi

# 4. Banlist.
out="$(_psg_check_banlist "$MSG" "$BANLIST_YML" || true)"
if [ -n "$out" ] ; then
  level="${out%% *}"; detail="${out#* }"
  _psg_register_verdict "$level" "banlist" "$detail"
fi

# 5. Length / format.
out="$(_psg_check_length_format "$MSG" "$TOOL_NAME" || true)"
if [ -n "$out" ] ; then
  level="${out%% *}"; detail="${out#* }"
  _psg_register_verdict "$level" "length-format" "$detail"
fi

# Clean — pass through.
if [ -z "$VERDICT_LEVEL" ] ; then
  _psg_emit_continue
  exit 0
fi

# Log the violation regardless of mode.
_psg_append_gate_log "$(jq -nc \
  --arg ts "$(date -u +%FT%TZ)" \
  --arg persona "$PERSONA" \
  --arg tool "$TOOL_NAME" \
  --arg audience "$AUDIENCE" \
  --arg mode "$GATE_MODE" \
  --arg level "$VERDICT_LEVEL" \
  --arg check "$VERDICT_CHECK" \
  --arg detail "$VERDICT_DETAIL" \
  '{ts:$ts,persona:$persona,tool:$tool,audience:$audience,mode:$mode,level:$level,check:$check,detail:$detail}')"

_psg_append_tone_log "$PERSONA" "$VERDICT_LEVEL" "$VERDICT_CHECK" "$VERDICT_DETAIL"

# Dispatch by mode.
case "$GATE_MODE" in
  log)
    _psg_emit_continue
    exit 0
    ;;
  rewrite)
    if [ -z "${ANTHROPIC_API_KEY:-}" ] ; then
      _psg_log warn "rewrite mode but no ANTHROPIC_API_KEY — degrading to log"
      _psg_emit_continue
      exit 0
    fi
    NEW_MSG="$(_psg_haiku_rewrite "$MSG" "$VERDICT_CHECK $VERDICT_DETAIL")"
    if [ "$NEW_MSG" = "$MSG" ] || [ -z "$NEW_MSG" ] ; then
      _psg_emit_continue
      exit 0
    fi
    NEW_INPUT_JSON="$(printf '%s' "$TOOL_INPUT_JSON" | jq --arg t "$NEW_MSG" '.text = $t')"
    _psg_emit_modify "$NEW_INPUT_JSON"
    exit 0
    ;;
  block)
    if [ "$VERDICT_LEVEL" = "HARD" ] ; then
      _psg_emit_block "pre-send-gate HARD violation: $VERDICT_CHECK ($VERDICT_DETAIL)"
      exit 0
    fi
    # SOFT under block mode → still rewrite if we can, else pass through.
    if [ -n "${ANTHROPIC_API_KEY:-}" ] ; then
      NEW_MSG="$(_psg_haiku_rewrite "$MSG" "$VERDICT_CHECK $VERDICT_DETAIL")"
      if [ -n "$NEW_MSG" ] && [ "$NEW_MSG" != "$MSG" ] ; then
        NEW_INPUT_JSON="$(printf '%s' "$TOOL_INPUT_JSON" | jq --arg t "$NEW_MSG" '.text = $t')"
        _psg_emit_modify "$NEW_INPUT_JSON"
        exit 0
      fi
    fi
    _psg_emit_continue
    exit 0
    ;;
  *)
    _psg_log warn "unknown GATE_MODE=$GATE_MODE — defaulting to log"
    _psg_emit_continue
    exit 0
    ;;
esac
