#!/usr/bin/env bash
# Shared helpers for per-persona hook scripts (M1 build-in-repo).
# Sourced by every hook; keep dependency-free (bash + coreutils + jq).

set -euo pipefail

# -----------------------------------------------------------------------------
# Recursion guard — prevent a hook that shells out to another claude-like call
# from re-firing us forever. Callers MUST `cc_hook_enter` at the top and
# `cc_hook_exit` on success.
# -----------------------------------------------------------------------------
cc_hook_enter() {
  local depth="${CC_HOOK_DEPTH:-0}"
  if [ "$depth" -ge 2 ]; then
    echo "{\"hookSpecificOutput\":{\"hookEventName\":\"${1:-unknown}\",\"additionalContext\":\"(recursion guard: CC_HOOK_DEPTH=$depth, skipping)\"}}"
    exit 0
  fi
  export CC_HOOK_DEPTH=$((depth + 1))
}

cc_hook_exit() {
  :
}

# -----------------------------------------------------------------------------
# Logger — every hook appends to ${CC_HOOK_LOG_DIR:-/tmp}/hooks-<persona>.log
# -----------------------------------------------------------------------------
cc_log_init() {
  local persona="$1"
  local dir="${CC_HOOK_LOG_DIR:-/tmp}"
  mkdir -p "$dir"
  CC_LOG_FILE="$dir/hooks-${persona}.log"
  export CC_LOG_FILE
}

cc_log() {
  local persona="$1"; shift
  if [ -z "${CC_LOG_FILE:-}" ]; then
    cc_log_init "$persona"
  fi
  printf '[%s] [%s] %s\n' "$(date -u +%FT%TZ)" "$persona" "$*" >>"$CC_LOG_FILE" 2>/dev/null || true
}

# -----------------------------------------------------------------------------
# Persona directory discovery — resolves from the hook's own path:
#   agents/<persona>/hooks/<script>.sh   →   agents/<persona>/
# -----------------------------------------------------------------------------
cc_persona_dir() {
  # $1 = path of the calling script ($0)
  local script_path="$1"
  # shellcheck disable=SC2155
  local hook_dir="$(cd "$(dirname "$script_path")" && pwd)"
  dirname "$hook_dir"
}

cc_persona_slug() {
  basename "$(cc_persona_dir "$1")"
}

# -----------------------------------------------------------------------------
# Read stdin into a variable, failing fast on EOF.
# -----------------------------------------------------------------------------
cc_read_stdin() {
  # If stdin is a TTY, there's no hook payload — fail visibly.
  if [ -t 0 ]; then
    echo "ERROR: hook requires stdin JSON payload from Claude Code harness" >&2
    return 64
  fi
  cat
}

# -----------------------------------------------------------------------------
# IDENTITY.md loader — extracts a YAML scalar field. Minimal parser: scans for
# "^<key>:" at column 0 and returns the value, quotes stripped.
# -----------------------------------------------------------------------------
cc_identity_field() {
  local identity_path="$1" key="$2"
  [ -f "$identity_path" ] || { echo ""; return 0; }
  awk -v k="$key" '
    /^---[[:space:]]*$/ { in_yaml = !in_yaml; next }
    in_yaml && $0 ~ "^"k":" {
      sub("^"k":[[:space:]]*","",$0)
      gsub(/^"|"$/,"",$0)
      gsub(/^'\''|'\''$/,"",$0)
      print
      exit
    }
  ' "$identity_path"
}

# -----------------------------------------------------------------------------
# JSON-escape a string for safe inclusion in an additionalContext value.
# Uses jq if available; falls back to a naive escaper (safe for our inputs).
# -----------------------------------------------------------------------------
cc_jsonesc() {
  if command -v jq >/dev/null 2>&1; then
    jq -Rs .
  else
    # Minimal fallback: escape backslash, double quote, newline, tab.
    python3 -c 'import sys,json; sys.stdout.write(json.dumps(sys.stdin.read()))' 2>/dev/null \
      || awk 'BEGIN{ORS=""; print "\""} {gsub(/\\/,"\\\\"); gsub(/"/,"\\\""); gsub(/\t/,"\\t"); printf "%s\\n",$0} END{print "\""}'
  fi
}

# -----------------------------------------------------------------------------
# Feed the current hook's result as a SessionStart-style JSON stanza.
# -----------------------------------------------------------------------------
cc_emit_context() {
  local event="$1" body_path="$2"
  local escaped
  escaped="$(cat "$body_path" | cc_jsonesc)"
  printf '{"hookSpecificOutput":{"hookEventName":"%s","additionalContext":%s}}\n' "$event" "$escaped"
}
