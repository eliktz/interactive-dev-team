#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# secret-scan-pre-push.sh -- block pushes that contain secrets (plan §7.5)
#
# Install as a git pre-push hook (stdin contract: one line per ref being
# pushed: `<local_ref> <local_sha> <remote_ref> <remote_sha>`):
#   ln -sf ../../scripts/secret-scan-pre-push.sh .git/hooks/pre-push
#
# What it scans:
#   - remote_sha known   -> ADDED lines of `git diff remote_sha..local_sha`
#   - remote_sha all-0s  -> the WHOLE TREE at local_sha (new branch push)
#   - ref deletions (local_sha all-0s) are skipped
#
# Patterns (generic shapes — this file NEVER embeds a live credential):
#   high-confidence (always fatal):
#     - Telegram bot tokens        [0-9]{8,10}:[A-Za-z0-9_-]{35}
#     - Anthropic API keys         sk-ant-...
#     - AWS access key ids        AKIA + 16 chars
#     - PEM private key blocks    -----BEGIN ... PRIVATE KEY-----
#     - the known-leaked Paperclip admin password — detected by SHA-256
#       digest comparison of candidate tokens, so the literal itself never
#       appears in this (public) repo, per plan §7.5 "never embeds the live
#       credential"
#   low-confidence (skipped when the line carries a placeholder marker like
#   not-a-real / <generated / fixture / ${VAR}):
#     - password= / secret= / api_key= / token= assignment literals
#
# Modes:
#   (no args)        pre-push hook mode (reads the stdin contract above)
#   --self-test      run built-in positive+negative fixtures (in-memory only,
#                    nothing written to the repo); exit 0 iff all behave
#   --scan-tree [rev] scan the whole tree at rev (default HEAD) — manual audit
#
# Exit: 0 = clean, 1 = hits found (printed as file:line: [pattern]), 2 = usage.
# =============================================================================

ZERO_SHA="0000000000000000000000000000000000000000"

# sha256 of the known-leaked Paperclip admin password (already public in the
# repo history — see plan §7.5/§8 step 7; rotated post-migration). Stored as
# a digest so the credential itself is never re-committed by its own scanner.
KNOWN_LEAKED_SHA256="d984953ffa92e47ef910c98f88842e66d9154cdfcaa3a4a9f9eb407cb216aa50"
# Cheap prefilter for candidate lines (CompanyYear!-shaped weak passwords)
# before paying for per-token hashing.
KNOWN_LEAKED_PREFILTER='[A-Za-z]+20[0-9]{2}[[:punct:]]'

# High-confidence patterns: always fatal, content withheld from output.
HC_NAMES=(telegram-bot-token anthropic-api-key aws-access-key-id pem-private-key)
HC_RES=(
  '[0-9]{8,10}:[A-Za-z0-9_-]{35}'
  'sk-ant-[A-Za-z0-9_-]{10,}'
  'AKIA[0-9A-Z]{16}'
  '-----BEGIN [A-Z ]*PRIVATE KEY-----'
)

# Low-confidence patterns: assignment shapes; allowlist-filtered, content shown.
# Deliberately NO bare `token` keyword — it matched every code line that
# shuffles a token variable around (launch.sh, wizard.js, settings.py) and
# would block legitimate whole-tree pushes; real Telegram/Anthropic/AWS
# tokens are caught by SHAPE above regardless of the variable name.
LC_NAMES=(credential-assignment)
LC_RES=(
  '(pass(word)?|passwd|pwd|secret|api[_-]?key|auth[_-]?token|access[_-]?key)[[:space:]]*[:=][[:space:]]*["'\'']?[A-Za-z0-9!@#%^&*+./_-]{8,}'
)
# Placeholder markers + env/code indirection shapes (a value read from the
# environment or an expression is not a literal secret).
ALLOW_RE='not-a-real|change-?me|placeholder|example|fixture|dummy|sample|<generated|<slug>|fake|redacted|\$\{|process\.env|os\.environ|getenv|\.\.\.'

sha256_hex() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  else
    shasum -a 256 | awk '{print $1}'
  fi
}

# --- record producers (records are `file:line:content` lines) -----------------

diff_records() {  # $1=remote_sha $2=local_sha -> added lines only
  git -c color.diff=false diff -U0 "$1".."$2" -- . | awk '
    /^\+\+\+ b\// { file = substr($0, 7); next }
    /^@@/         { split($3, a, ","); ln = substr(a[1], 2) + 0; next }
    /^\+/ && !/^\+\+\+/ { printf "%s:%d:%s\n", file, ln, substr($0, 2); ln++ }
  '
}

tree_records() {  # $1=rev -> every line of every blob at rev
  local rev="$1" f
  git ls-tree -r --name-only "$rev" | while IFS= read -r f; do
    git show "$rev:$f" 2>/dev/null \
      | awk -v f="$f" '{ printf "%s:%d:%s\n", f, NR, $0 }'
  done
}

# --- scanners ------------------------------------------------------------------
# All take the record stream as $1 and PRINT hits; they echo the hit count.

scan_high_confidence() {
  local records="$1" hits=0 i matches
  for i in "${!HC_NAMES[@]}"; do
    matches="$(printf '%s\n' "$records" | grep -E -- "${HC_RES[$i]}" || true)"
    [ -n "$matches" ] || continue
    hits=$((hits + $(printf '%s\n' "$matches" | grep -c .)))
    printf '%s\n' "$matches" \
      | cut -d: -f1,2 \
      | sed "s/\$/: [${HC_NAMES[$i]}] (content withheld)/" >&2
  done
  echo "$hits"
}

scan_low_confidence() {
  local records="$1" hits=0 i matches
  for i in "${!LC_NAMES[@]}"; do
    matches="$(printf '%s\n' "$records" \
      | grep -iE -- "${LC_RES[$i]}" \
      | grep -ivE -- "$ALLOW_RE" || true)"
    [ -n "$matches" ] || continue
    hits=$((hits + $(printf '%s\n' "$matches" | grep -c .)))
    printf '%s\n' "$matches" \
      | cut -c1-200 \
      | sed -E "s/^([^:]+:[0-9]+):/\1: [${LC_NAMES[$i]}] /" >&2
  done
  echo "$hits"
}

scan_known_leaked() {
  local records="$1" hits=0 candidate content tok digest
  candidate="$(printf '%s\n' "$records" | grep -E -- "$KNOWN_LEAKED_PREFILTER" || true)"
  [ -n "$candidate" ] || { echo 0; return 0; }
  while IFS= read -r rec; do
    content="${rec#*:}"; content="${content#*:}"
    # Tokenize on quotes/space/=/:/,/;/<>/() — token keeps inner punctuation.
    for tok in $(printf '%s' "$content" | tr "\"' =:,;<>()\`" '\n' | grep -E '.{6,}' || true); do
      digest="$(printf '%s' "$tok" | sha256_hex)"
      if [ "$digest" = "$KNOWN_LEAKED_SHA256" ]; then
        hits=$((hits + 1))
        printf '%s: [known-leaked-credential] (content withheld)\n' \
          "$(printf '%s' "$rec" | cut -d: -f1,2)" >&2
      fi
    done
  done <<<"$candidate"
  echo "$hits"
}

scan_records() {  # $1=records  -> echoes total hit count
  local records="$1" total=0
  [ -n "$records" ] || { echo 0; return 0; }
  total=$((total + $(scan_high_confidence "$records")))
  total=$((total + $(scan_low_confidence "$records")))
  total=$((total + $(scan_known_leaked "$records")))
  echo "$total"
}

# --- self-test -------------------------------------------------------------------
# Fixtures are built IN MEMORY only, assembled from fragments so that no line
# of THIS file matches its own patterns (the scanner stays self-clean).

self_test() {
  local pass=0 fail=0
  local a35 tg ant aws pem pw leaked

  a35="$(printf 'A%.0s' $(seq 1 35))"
  tg="$(printf '%s:%s' '123456789' "$a35")"
  ant="$(printf 'sk-an%s' 't-T3stF1xtureNotARealKey00')"
  aws="$(printf 'AKI%s' 'AABCDEFGHIJKLMNOP')"
  pem="$(printf -- '-----BEGIN RSA PRIVATE %s' 'KEY-----')"
  pw="$(printf 'pass%s' 'word=Sup3rS3cretVal99')"
  leaked="$(printf 'GoNor%s' 'th2026!')"

  expect_hits() {  # $1=label $2=record $3=expected (0 or >0 as "clean"/"hit")
    local label="$1" record="$2" want="$3" got
    got="$(scan_records "$record" 2>/dev/null)"
    if { [ "$want" = hit ] && [ "$got" -gt 0 ]; } \
       || { [ "$want" = clean ] && [ "$got" -eq 0 ]; }; then
      echo "  PASS: $label (want=$want hits=$got)"
      pass=$((pass + 1))
    else
      echo "  FAIL: $label (want=$want hits=$got)"
      fail=$((fail + 1))
    fi
  }

  echo "[secret-scan] self-test: positive fixtures (must hit)"
  expect_hits "telegram bot token"        "f.env:1:BOT_TOKEN=$tg"                    hit
  expect_hits "anthropic api key"         "f.env:2:KEY=$ant"                         hit
  expect_hits "aws access key id"         "f.tf:3:access_key = \"$aws\""             hit
  expect_hits "pem private key block"     "id_rsa:1:$pem"                            hit
  expect_hits "password assignment"       "app.py:9:$pw"                             hit
  expect_hits "known-leaked credential"   "notes.md:4:admin login is $leaked here"   hit

  echo "[secret-scan] self-test: negative fixtures (must stay clean)"
  expect_hits "env-var indirection"       'c.yml:1:PASSWORD=${SECRET_FROM_ENV}'      clean
  expect_hits "placeholder password"      'e.env:2:AUTH_PASS=not-a-real-password-test-fixture' clean
  expect_hits "generated placeholder"     'e.env:3:WARROOM2_ADMIN_TOKEN=<generated-by-squadctl>' clean
  expect_hits "empty assignment"          'e.env:4:CAPTAIN_TELEGRAM_TOKEN='          clean
  expect_hits "function call, not value"  'a.js:5:const h = compute_password_hash(x)' clean
  expect_hits "year-shape but not leaked" 'doc.md:6:released in Spring2026! edition' clean
  expect_hits "process.env indirection"   'l.sh:7:bbEnv.BITBUCKET_PASSWORD = process.env.BITBUCKET_PASSWORD;' clean
  expect_hits "os.environ indirection"    's.py:8:basic_auth_pass=os.environ.get("X", "")' clean
  expect_hits "ellipsis doc placeholder"  'd.md:9:# ANTHROPIC_API_KEY=sk-ant-...'    clean
  expect_hits "token var shuffle (code)"  'w.js:10:var t = state.agent.telegram.token' clean

  echo "[secret-scan] self-test: $pass passed, $fail failed"
  [ "$fail" -eq 0 ]
}

# --- entrypoints -------------------------------------------------------------------

run_pre_push() {
  local local_ref local_sha remote_ref remote_sha records total=0 n
  while read -r local_ref local_sha remote_ref remote_sha; do
    [ -n "${local_sha:-}" ] || continue
    [ "$local_sha" = "$ZERO_SHA" ] && continue  # ref deletion — nothing to scan
    if [ "$remote_sha" = "$ZERO_SHA" ] \
       || ! git cat-file -e "$remote_sha" 2>/dev/null; then
      echo "[secret-scan] new ref $local_ref — scanning whole tree at ${local_sha:0:12}" >&2
      records="$(tree_records "$local_sha")"
    else
      echo "[secret-scan] scanning ${remote_sha:0:12}..${local_sha:0:12} ($local_ref)" >&2
      records="$(diff_records "$remote_sha" "$local_sha")"
    fi
    n="$(scan_records "$records")"
    total=$((total + n))
  done
  if [ "$total" -gt 0 ]; then
    echo "[secret-scan] BLOCKED: $total potential secret(s) found — fix (or rewrite history) before pushing." >&2
    return 1
  fi
  echo "[secret-scan] clean." >&2
  return 0
}

run_scan_tree() {
  local rev="${1:-HEAD}" records n
  echo "[secret-scan] scanning whole tree at $rev" >&2
  records="$(tree_records "$rev")"
  n="$(scan_records "$records")"
  if [ "$n" -gt 0 ]; then
    echo "[secret-scan] $n potential secret(s) found." >&2
    return 1
  fi
  echo "[secret-scan] clean." >&2
  return 0
}

case "${1:-}" in
  --self-test)  self_test ;;
  --scan-tree)  shift; run_scan_tree "${1:-HEAD}" ;;
  '')           run_pre_push ;;
  *)            echo "usage: $0 [--self-test | --scan-tree [rev]]  (no args = pre-push hook mode)" >&2
                exit 2 ;;
esac
