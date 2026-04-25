#!/usr/bin/env bash
# l5-mount-prep.sh — generate the L5 host-mount ACK template, validate a
# signed ACK, and prepare a redaction filter for an eventual RO mount of the
# operator's host claude-projects memory dir.
#
# This script DOES NOT perform the mount. It only:
#   1) writes the per-company ACK template to
#        companies/<company>/L5-POLICY-ACK.md.tmpl
#      so the operator can copy → fill → sign.
#   2) on `--check <company>`, parses the signed ACK and prints
#        ACK-VALID  / ACK-MISSING / ACK-UNSIGNED
#   3) on `--print-mount-cmd <company>`, ONLY if ACK is valid, prints the
#      `docker run` flag plus a redaction-aware `rsync` command that the
#      M2-rest activation phase will execute. (Intended for review by the
#      operator before they kick off the activation.)
#
# Mount target (when activated, NOT NOW):
#   /home/claude/.claude/projects/<project>/memory/   (host, read-only)
#     → /workspace/agents/<persona>/host-memory       (in-container, RO)
#
# Redaction filter strips secrets before the persona sees the file:
#   - ANTHROPIC_API_KEY=
#   - BITBUCKET_TOKEN=
#   - GITHUB_TOKEN=
#   - TELEGRAM_BOT_TOKEN=
#   - PAPERCLIP_*_TOKEN=
#   - any line starting with `password:` or `secret:`

set -euo pipefail

L5_REDACTION_PATTERNS=(
  'ANTHROPIC_API_KEY='
  'BITBUCKET_TOKEN='
  'GITHUB_TOKEN='
  'TELEGRAM_BOT_TOKEN='
  'PAPERCLIP_[A-Z_]+_TOKEN='
  'TRELLO_TOKEN='
  '^password:'
  '^secret:'
  'sk-ant-[A-Za-z0-9-]+'
)

usage() {
  cat <<'EOF'
Usage:
  l5-mount-prep.sh --emit-template <company>
  l5-mount-prep.sh --check          <company>
  l5-mount-prep.sh --print-mount-cmd <company> <persona>

This script writes / validates the L5 host-mount ACK. It does NOT mount.
EOF
}

repo_root() {
  cd "$(dirname "$0")/../../.." && pwd
}

template_path() {
  local company="$1"
  printf '%s/companies/%s/L5-POLICY-ACK.md.tmpl' "$(repo_root)" "$company"
}

ack_path() {
  local company="$1"
  printf '%s/companies/%s/L5-POLICY-ACK.md' "$(repo_root)" "$company"
}

emit_template() {
  local company="$1"
  local out; out="$(template_path "$company")"
  mkdir -p "$(dirname "$out")"
  cat >"$out" <<'TMPL'
---
# L5 Host-Memory Mount — Operator Acknowledgement
# Copy this file to L5-POLICY-ACK.md, fill in the fields, sign, commit.
# Until both `acknowledged: true` AND a non-empty `signature` are present,
# the L5 mount is REFUSED by l5-mount-prep.sh.
acknowledged: false
operator_name: ""
operator_email: ""
date_signed: ""
signature: ""           # any non-empty string the operator vouches for
project_path: ""        # e.g. /home/claude/.claude/projects/-Users-elik-k-git-openclaw
allowed_personas:       # which agents may read the mounted dir
  - ceo-<company>
redact_extra: []        # additional regex patterns to strip
---

# L5 host-memory mount — what you are ACKing

By signing this ACK you confirm:

1. You have reviewed the contents of `project_path` and accept that the
   personas listed in `allowed_personas` will have **read-only** access to
   it during their war-room session.
2. The redaction filter will strip a fixed set of secret patterns
   (`ANTHROPIC_API_KEY`, `BITBUCKET_TOKEN`, `TELEGRAM_BOT_TOKEN`,
   `password:`, `secret:`, etc. — see l5-mount-prep.sh for the full list).
   You can extend this with `redact_extra`. **You are responsible for
   anything that the redaction filter misses.**
3. The mount will appear in the container at:
     /workspace/agents/<persona>/host-memory   (read-only)
4. The mount can be revoked by deleting this ACK (or setting `acknowledged:
   false`) and restarting the war-room container.

This ACK is human-only. No automation modifies it.
TMPL
  echo "wrote $out"
}

# Returns 0 + prints "ACK-VALID" if both acknowledged:true and a non-empty
# signature are present in companies/<company>/L5-POLICY-ACK.md
# Returns non-zero + prints reason on missing/unsigned.
check_ack() {
  local company="$1"
  local f; f="$(ack_path "$company")"
  if [ ! -f "$f" ] ; then
    echo "ACK-MISSING (no $f)"
    return 1
  fi
  local ack sig
  ack="$(awk -F': *' '/^acknowledged:/ {print $2; exit}' "$f" | tr -d '"' | tr -d "'")"
  sig="$(awk -F': *' '/^signature:/    {print $2; exit}' "$f" | tr -d '"' | tr -d "'")"
  if [ "$ack" != "true" ] ; then
    echo "ACK-UNSIGNED (acknowledged=$ack)"
    return 1
  fi
  if [ -z "$sig" ] ; then
    echo "ACK-UNSIGNED (signature empty)"
    return 1
  fi
  echo "ACK-VALID"
  return 0
}

print_redaction_filter() {
  # Emits a sed expression that strips matching lines.
  local pat
  local q="'"
  printf 'sed -E %s' "$q"
  for pat in "${L5_REDACTION_PATTERNS[@]}" ; do
    printf '/%s/d;' "$pat"
  done
  printf '%s' "$q"
}

# Print the docker bind-mount + redaction rsync that M2-rest would execute.
# We DO NOT execute. Operator/CI runs this command when they're ready.
print_mount_cmd() {
  local company="$1" persona="$2"
  if ! check_ack "$company" >/dev/null ; then
    echo "REFUSED — ACK not valid for company=$company. Run with --check for detail." >&2
    return 1
  fi
  local f; f="$(ack_path "$company")"
  local proj; proj="$(awk -F': *' '/^project_path:/ {print $2; exit}' "$f" | tr -d '"' | tr -d "'")"
  if [ -z "$proj" ] ; then
    echo "REFUSED — project_path missing in ACK." >&2
    return 1
  fi
  cat <<EOF
# === L5 mount plan for company=$company persona=$persona ===
# Step 1 — bind-mount RO at container boot:
docker run … \\
  -v "${proj}:/workspace/agents/${persona}/host-memory:ro" \\
  …

# Step 2 — apply redaction filter on each container start (in entrypoint):
mkdir -p /workspace/agents/${persona}/host-memory-redacted
find /workspace/agents/${persona}/host-memory -type f -name '*.md' \\
  | while read -r src ; do
      dst="/workspace/agents/${persona}/host-memory-redacted/\${src#/workspace/agents/${persona}/host-memory/}"
      mkdir -p "\$(dirname "\$dst")"
      $(print_redaction_filter) "\$src" > "\$dst"
    done

# (M2-rest will wire Step 1 into docker-compose.yml + Step 2 into entrypoint.sh.)
EOF
}

# ----------------------------------------------------------------- main ----
case "${1:-}" in
  --emit-template)
    [ -n "${2:-}" ] || { usage >&2 ; exit 64 ; }
    emit_template "$2"
    ;;
  --check)
    [ -n "${2:-}" ] || { usage >&2 ; exit 64 ; }
    check_ack "$2"
    ;;
  --print-mount-cmd)
    [ -n "${2:-}" ] && [ -n "${3:-}" ] || { usage >&2 ; exit 64 ; }
    print_mount_cmd "$2" "$3"
    ;;
  -h|--help|"")
    usage
    ;;
  *)
    usage >&2
    exit 64
    ;;
esac
