#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# test-socket-proxy-exec.sh -- M5 empirical exec-hijack gate (plan §7.4)
#
# Question this answers EMPIRICALLY: does `docker exec` survive a Tecnativa
# docker-socket-proxy (HAProxy) in between? Docker's exec-attach protocol is
# an HTTP connection HIJACK (Upgrade: tcp) — not a WebSocket — which HAProxy
# cannot be assumed to relay. The `socket-proxy` compose profile must NOT be
# enabled for any squad unless this test PASSES.
#
# What it does (LOCAL docker ONLY — never ssh, never the VM):
#   0. CONTROL: PTY exec round-trip against the raw local socket — proves the
#      harness itself works (a FAIL without a passing control is meaningless).
#   1. Starts a throwaway target container (alpine sleep).
#   2. Starts tecnativa/docker-socket-proxy with CONTAINERS=1 EXEC=1 POST=1
#      publishing 127.0.0.1:<free port>:2375.
#   3. Drives `DOCKER_HOST=tcp://127.0.0.1:<port> docker exec -it <target>
#      sh -c 'read x; echo got:$x'` through a REAL PTY (`script -q /dev/null`
#      on macOS, `script -qec` on Linux), sends a line, asserts the echoed
#      round-trip.
#   4. Same exec WITHOUT a TTY (`docker exec -i`) for comparison.
#   5. SQUAD-SCOPE ACL STAGE: starts a SECOND proxy with the repo's custom
#      deploy/docker-proxy/haproxy.cfg mounted over the image's template path
#      and SQUAD_EXEC_ALLOW_REGEX in its environment (exactly like the
#      compose `docker-proxy` service). Asserts the substitution path the
#      full-diff review questioned: the regex is expanded by HAPROXY ITSELF
#      at config-parse time (the Tecnativa entrypoint seds ONLY
#      ${BIND_CONFIG} — see the cfg's ENV SUBSTITUTION header note):
#        - inspect of the ALLOWED-name target  -> 200 (passes to dockerd)
#        - inspect of a FOREIGN name           -> 403 (proxy denies; a 404
#          here would mean the request leaked through to dockerd)
#        - POST /containers/create             -> 403 (hard deny)
#        - plain exec round-trip into the allowed target through the ACL cfg
#   6. Prints PASS/FAIL per stage and writes the verdict + environment to
#      deploy/docker-proxy/EXEC_TEST_RESULT.md.
#
# Verdict: PASS only if BOTH exec modes round-trip (warroom2 uses both: plain
# exec_text and PTY attach — see warroom2/warroom2/docker_client.py) AND the
# squad-scope ACL stage holds.
# On FAIL the socket-proxy profile stays "do not enable — follow-up"
# (deploy/templates/squad.env.template); the raw-socket default is unaffected.
#
# Exit codes: 0 = ran to a verdict (PASS or FAIL — read the report),
#             2 = INCONCLUSIVE (control failed / docker unavailable).
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
RESULT_MD="$PROJECT_DIR/deploy/docker-proxy/EXEC_TEST_RESULT.md"

PROXY_IMAGE="${PROXY_IMAGE:-tecnativa/docker-socket-proxy:latest}"
TARGET_IMAGE="${TARGET_IMAGE:-alpine:latest}"
SUFFIX="$$-$RANDOM"
TARGET="m5-exec-test-target-$SUFFIX"
PROXY="m5-exec-test-proxy-$SUFFIX"
PROXY_ACL="m5-exec-test-proxy-acl-$SUFFIX"
PROXY_ADMIN="m5-exec-test-proxy-admin-$SUFFIX"
# Deliberately NEVER created: a 404 on it would mean the request leaked
# through the ACL to dockerd; the proxy must answer 403 itself.
DECOY="m5-exec-test-decoy-$SUFFIX"
ACL_CFG="$PROJECT_DIR/deploy/docker-proxy/haproxy.cfg"
ADMIN_CFG="$PROJECT_DIR/deploy/docker-proxy/haproxy.admin.cfg"
# Throwaway resources created+deleted THROUGH the admin proxy (DELETE path proof).
ADMIN_NET_PROBE="m5-admin-probe-ctr-$SUFFIX"
ADMIN_NET_PROBE_NET="m5-admin-probe-net-$SUFFIX"
ADMIN_VOL_PROBE="m5-admin-probe-vol-$SUFFIX"
ATTEMPT_TIMEOUT="${ATTEMPT_TIMEOUT:-30}"

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/m5-exec-test.XXXXXX")"

# --- bulletproof cleanup -----------------------------------------------------
cleanup() {
  docker rm -f "$TARGET" >/dev/null 2>&1 || true
  docker rm -f "$PROXY" >/dev/null 2>&1 || true
  docker rm -f "$PROXY_ACL" >/dev/null 2>&1 || true
  docker rm -f "$PROXY_ADMIN" >/dev/null 2>&1 || true
  docker rm -f "$ADMIN_NET_PROBE" >/dev/null 2>&1 || true
  docker volume rm -f "$ADMIN_VOL_PROBE" >/dev/null 2>&1 || true
  docker network rm "$ADMIN_NET_PROBE_NET" >/dev/null 2>&1 || true
  rm -rf "$WORK_DIR" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

note() { printf '[exec-test] %s\n' "$*"; }
die()  { printf '[exec-test] FATAL: %s\n' "$*" >&2; exit 2; }

# --- guards: LOCAL docker only ----------------------------------------------
command -v docker >/dev/null 2>&1 || die "docker CLI not found"
case "${DOCKER_HOST:-}" in
  ''|unix://*) : ;;
  *) die "DOCKER_HOST=${DOCKER_HOST} points at a non-local daemon — this gate runs against LOCAL docker only" ;;
esac
docker info >/dev/null 2>&1 || die "local docker daemon not reachable"

# --- OS-specific real-PTY wrapper (macOS vs Linux `script`) -------------------
OS="$(uname -s)"
case "$OS" in Darwin|Linux) : ;; *) die "unsupported OS for PTY harness: $OS" ;; esac
pty_run() {
  # Runs "$@" attached to a REAL PTY; the caller pipes stdin into the pty.
  if [ "$OS" = Darwin ]; then
    script -q /dev/null "$@"
  else
    local cmd
    cmd="$(printf '%q ' "$@")"
    script -qec "$cmd" /dev/null
  fi
}

# Run a shell function in the background with a hard timeout (macOS has no
# `timeout`); returns 124 on timeout, else the function's exit code.
run_with_timeout() {
  local secs="$1"; shift
  "$@" &
  local pid=$! waited=0
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$waited" -ge "$secs" ]; then
      kill "$pid" 2>/dev/null || true
      sleep 1
      kill -9 "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      return 124
    fi
    sleep 1
    waited=$((waited + 1))
  done
  wait "$pid"
}

# --- exec attempts (TOKEN round-trips through `read x; echo got:$x`) ----------
# Both attempts run in a BACKGROUND SUBSHELL (via run_with_timeout), so
# exporting DOCKER_HOST inside them never leaks into the parent script.
TOKEN_TTY="hello-tty-$SUFFIX"
TOKEN_PLAIN="hello-plain-$SUFFIX"

run_tty() {  # $1=DOCKER_HOST (''=raw local socket)  $2=token  $3=outfile
  local dh="$1" token="$2" out="$3"
  if [ -n "$dh" ]; then export DOCKER_HOST="$dh"; else unset DOCKER_HOST; fi
  {
    printf '%s\n' "$token"
    sleep 4
  } | pty_run docker exec -it "$TARGET" sh -c 'read x; echo "got:$x"' \
      >"$out" 2>&1 || true
}

run_plain() {  # $1=DOCKER_HOST (''=raw local socket)  $2=token  $3=outfile
  local dh="$1" token="$2" out="$3"
  if [ -n "$dh" ]; then export DOCKER_HOST="$dh"; else unset DOCKER_HOST; fi
  printf '%s\n' "$token" \
    | docker exec -i "$TARGET" sh -c 'read x; echo "got:$x"' \
      >"$out" 2>&1 || true
}

# --- setup --------------------------------------------------------------------
free_port() {
  python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()'
}

wait_ping() { # wait_ping PORT NAME
  local p="$1" name="$2" i
  for i in $(seq 1 30); do
    if curl -fsS "http://127.0.0.1:$p/_ping" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  die "$name never answered /_ping on 127.0.0.1:$p"
}

note "pulling images (if needed): $TARGET_IMAGE, $PROXY_IMAGE"
docker pull -q "$TARGET_IMAGE" >/dev/null 2>&1 || true
docker pull -q "$PROXY_IMAGE" >/dev/null 2>&1 || true

note "starting throwaway target container: $TARGET"
docker run -d --name "$TARGET" "$TARGET_IMAGE" sh -c 'sleep 600' >/dev/null

FREE_PORT="$(free_port)"
note "starting socket proxy: $PROXY (127.0.0.1:$FREE_PORT -> :2375, CONTAINERS=1 EXEC=1 POST=1)"
docker run -d --name "$PROXY" \
  -e CONTAINERS=1 -e EXEC=1 -e POST=1 \
  -p "127.0.0.1:$FREE_PORT:2375" \
  -v /var/run/docker.sock:/var/run/docker.sock:ro \
  "$PROXY_IMAGE" >/dev/null

note "waiting for proxy readiness (GET /_ping)"
wait_ping "$FREE_PORT" "proxy"

PROXY_URL="tcp://127.0.0.1:$FREE_PORT"

# --- 0) CONTROL: raw socket, real PTY ------------------------------------------
note "CONTROL: PTY exec round-trip via raw local socket"
CONTROL_OUT="$WORK_DIR/control.out"
run_with_timeout "$ATTEMPT_TIMEOUT" run_tty "" "control-$TOKEN_TTY" "$CONTROL_OUT" || true
if grep -q "got:control-$TOKEN_TTY" "$CONTROL_OUT"; then
  note "CONTROL: PASS (harness is sound)"
else
  note "CONTROL output was:"; sed 's/^/    /' "$CONTROL_OUT" || true
  die "CONTROL round-trip failed — harness broken, verdict would be meaningless"
fi

# --- 1) TTY exec through the proxy ---------------------------------------------
note "TEST 1/3: docker exec -it through proxy ($PROXY_URL), real PTY"
TTY_OUT="$WORK_DIR/tty.out"
TTY_RC=0
run_with_timeout "$ATTEMPT_TIMEOUT" run_tty "$PROXY_URL" "$TOKEN_TTY" "$TTY_OUT" || TTY_RC=$?
if grep -q "got:$TOKEN_TTY" "$TTY_OUT"; then
  TTY_VERDICT="PASS"
else
  TTY_VERDICT="FAIL"
fi
note "TTY mode: $TTY_VERDICT$([ "$TTY_RC" = 124 ] && echo ' (timed out after '"$ATTEMPT_TIMEOUT"'s)')"

# --- 2) plain (non-TTY) exec through the proxy ----------------------------------
note "TEST 2/3: docker exec -i (no TTY) through proxy"
PLAIN_OUT="$WORK_DIR/plain.out"
PLAIN_RC=0
run_with_timeout "$ATTEMPT_TIMEOUT" run_plain "$PROXY_URL" "$TOKEN_PLAIN" "$PLAIN_OUT" || PLAIN_RC=$?
if grep -q "got:$TOKEN_PLAIN" "$PLAIN_OUT"; then
  PLAIN_VERDICT="PASS"
else
  PLAIN_VERDICT="FAIL"
fi
note "non-TTY mode: $PLAIN_VERDICT$([ "$PLAIN_RC" = 124 ] && echo ' (timed out after '"$ATTEMPT_TIMEOUT"'s)')"

# --- 3) squad-scope ACL stage: the repo cfg + SQUAD_EXEC_ALLOW_REGEX -------------
# Mirrors the compose `docker-proxy` service exactly: the custom haproxy.cfg
# is mounted over the image's haproxy.cfg.template (the Tecnativa entrypoint
# seds ONLY ${BIND_CONFIG} there) and SQUAD_EXEC_ALLOW_REGEX rides the
# container environment, from which HAPROXY ITSELF expands it at config-parse
# time (manual §2.3). PING/VERSION/EVENTS come from the image's env defaults,
# same as in compose.
[ -f "$ACL_CFG" ] || die "missing ACL config: $ACL_CFG"
note "TEST 3/3: squad-scope ACL stage (custom cfg, SQUAD_EXEC_ALLOW_REGEX=$TARGET)"
FREE_PORT_ACL="$(free_port)"
docker run -d --name "$PROXY_ACL" \
  -e CONTAINERS=1 -e EXEC=1 -e POST=1 \
  -e SQUAD_EXEC_ALLOW_REGEX="$TARGET" \
  -p "127.0.0.1:$FREE_PORT_ACL:2375" \
  -v "$ACL_CFG":/usr/local/etc/haproxy/haproxy.cfg.template:ro \
  -v /var/run/docker.sock:/var/run/docker.sock:ro \
  "$PROXY_IMAGE" >/dev/null
note "waiting for ACL proxy readiness (GET /_ping)"
wait_ping "$FREE_PORT_ACL" "ACL proxy"

acl_code() { # acl_code METHOD PATH -> HTTP status (000 on connection failure)
  curl -s -o /dev/null -w '%{http_code}' -X "$1" "http://127.0.0.1:$FREE_PORT_ACL$2" 2>/dev/null || echo 000
}
ACL_ALLOW_CODE="$(acl_code GET "/containers/$TARGET/json")"      # expect 200
ACL_DENY_CODE="$(acl_code GET "/containers/$DECOY/json")"        # expect 403 (404 = leaked)
ACL_CREATE_CODE="$(acl_code POST "/containers/create")"          # expect 403

TOKEN_ACL="hello-acl-$SUFFIX"
ACL_OUT="$WORK_DIR/acl.out"
ACL_RC=0
run_with_timeout "$ATTEMPT_TIMEOUT" run_plain "tcp://127.0.0.1:$FREE_PORT_ACL" "$TOKEN_ACL" "$ACL_OUT" || ACL_RC=$?
if grep -q "got:$TOKEN_ACL" "$ACL_OUT"; then
  ACL_EXEC_VERDICT="PASS"
else
  ACL_EXEC_VERDICT="FAIL"
fi

if [ "$ACL_ALLOW_CODE" = "200" ] && [ "$ACL_DENY_CODE" = "403" ] \
   && [ "$ACL_CREATE_CODE" = "403" ] && [ "$ACL_EXEC_VERDICT" = "PASS" ]; then
  ACL_VERDICT="PASS"
else
  ACL_VERDICT="FAIL"
fi
note "ACL stage: $ACL_VERDICT (allowed inspect=$ACL_ALLOW_CODE foreign inspect=$ACL_DENY_CODE create=$ACL_CREATE_CODE exec=$ACL_EXEC_VERDICT)"

# --- 4) admin-ACL stage: the BROAD admin cfg (no name regex) --------------------
# Mirrors the admin-docker-proxy service: deploy/docker-proxy/haproxy.admin.cfg
# mounted over the image template, broad allow set, NO SQUAD_EXEC_ALLOW_REGEX.
# Proves what the squad ACL stage cannot: the admin legitimately CREATES and (via
# `compose down -v`) DELETES containers/networks/volumes — so we assert the FULL
# create->DELETE round-trip returns 2xx (not just create=201), AND that BUILD +
# the host-takeover surface stay 403 (review suggestion #5, plan §2.2).
ADMIN_VERDICT="SKIP"
ADMIN_BUILD_CODE="-" ADMIN_SWARM_CODE="-" ADMIN_SECRETS_CODE="-"
ADMIN_CTR_CREATE_CODE="-" ADMIN_CTR_DELETE_CODE="-"
ADMIN_NET_CREATE_CODE="-" ADMIN_NET_DELETE_CODE="-"
ADMIN_VOL_CREATE_CODE="-" ADMIN_VOL_DELETE_CODE="-"
if [ ! -f "$ADMIN_CFG" ]; then
  note "TEST 4/4: admin-ACL stage SKIPPED (missing $ADMIN_CFG)"
else
  note "TEST 4/4: admin-ACL stage (broad cfg, no name regex; create + compose-down-v DELETE path)"
  FREE_PORT_ADMIN="$(free_port)"
  docker run -d --name "$PROXY_ADMIN" \
    -e CONTAINERS=1 -e EXEC=1 -e POST=1 -e NETWORKS=1 -e VOLUMES=1 -e IMAGES=1 \
    -p "127.0.0.1:$FREE_PORT_ADMIN:2375" \
    -v "$ADMIN_CFG":/usr/local/etc/haproxy/haproxy.cfg.template:ro \
    -v /var/run/docker.sock:/var/run/docker.sock:ro \
    "$PROXY_IMAGE" >/dev/null
  note "waiting for admin proxy readiness (GET /_ping)"
  wait_ping "$FREE_PORT_ADMIN" "admin proxy"

  admin_url="tcp://127.0.0.1:$FREE_PORT_ADMIN"

  # --- DENY assertions (raw HTTP, no docker CLI needed) ---------------------
  acode() { # acode METHOD PATH -> HTTP status (000 on connection failure)
    curl -s -o /dev/null -w '%{http_code}' -X "$1" "http://127.0.0.1:$FREE_PORT_ADMIN$2" 2>/dev/null || echo 000
  }
  ADMIN_BUILD_CODE="$(acode POST "/build")"             # expect 403 (out-of-band)
  ADMIN_SWARM_CODE="$(acode POST "/swarm/init")"        # expect 403 (host-takeover)
  ADMIN_SECRETS_CODE="$(acode POST "/secrets/create")"  # expect 403 (host-takeover)

  # --- ALLOW + DELETE round-trip via the docker CLI through the admin proxy ---
  # container create -> start -> DELETE (force) ; network create -> DELETE ;
  # volume create -> DELETE. Each `docker rc==0` proves the proxy returned 2xx
  # for both the create and the DELETE (the destructive surface squadctl uses).
  ok2xx() { [ "$1" = "0" ] && echo "2xx" || echo "ERR"; }

  ( export DOCKER_HOST="$admin_url"
    docker create --name "$ADMIN_NET_PROBE" "$TARGET_IMAGE" sh -c 'sleep 60' >/dev/null 2>&1
  ) ; ADMIN_CTR_CREATE_CODE="$(ok2xx $?)"
  ( export DOCKER_HOST="$admin_url"; docker rm -f "$ADMIN_NET_PROBE" >/dev/null 2>&1
  ) ; ADMIN_CTR_DELETE_CODE="$(ok2xx $?)"

  ( export DOCKER_HOST="$admin_url"; docker network create "$ADMIN_NET_PROBE_NET" >/dev/null 2>&1
  ) ; ADMIN_NET_CREATE_CODE="$(ok2xx $?)"
  ( export DOCKER_HOST="$admin_url"; docker network rm "$ADMIN_NET_PROBE_NET" >/dev/null 2>&1
  ) ; ADMIN_NET_DELETE_CODE="$(ok2xx $?)"

  ( export DOCKER_HOST="$admin_url"; docker volume create "$ADMIN_VOL_PROBE" >/dev/null 2>&1
  ) ; ADMIN_VOL_CREATE_CODE="$(ok2xx $?)"
  ( export DOCKER_HOST="$admin_url"; docker volume rm -f "$ADMIN_VOL_PROBE" >/dev/null 2>&1
  ) ; ADMIN_VOL_DELETE_CODE="$(ok2xx $?)"

  if [ "$ADMIN_BUILD_CODE" = "403" ] && [ "$ADMIN_SWARM_CODE" = "403" ] \
     && [ "$ADMIN_SECRETS_CODE" = "403" ] \
     && [ "$ADMIN_CTR_CREATE_CODE" = "2xx" ] && [ "$ADMIN_CTR_DELETE_CODE" = "2xx" ] \
     && [ "$ADMIN_NET_CREATE_CODE" = "2xx" ] && [ "$ADMIN_NET_DELETE_CODE" = "2xx" ] \
     && [ "$ADMIN_VOL_CREATE_CODE" = "2xx" ] && [ "$ADMIN_VOL_DELETE_CODE" = "2xx" ]; then
    ADMIN_VERDICT="PASS"
  else
    ADMIN_VERDICT="FAIL"
  fi
  note "admin-ACL stage: $ADMIN_VERDICT (build=$ADMIN_BUILD_CODE swarm=$ADMIN_SWARM_CODE secrets=$ADMIN_SECRETS_CODE ctr=$ADMIN_CTR_CREATE_CODE/$ADMIN_CTR_DELETE_CODE net=$ADMIN_NET_CREATE_CODE/$ADMIN_NET_DELETE_CODE vol=$ADMIN_VOL_CREATE_CODE/$ADMIN_VOL_DELETE_CODE)"
fi

# --- verdict --------------------------------------------------------------------
# admin-ACL stage joins the gate; SKIP (missing cfg) does NOT fail the overall run.
if [ "$TTY_VERDICT" = "PASS" ] && [ "$PLAIN_VERDICT" = "PASS" ] \
   && [ "$ACL_VERDICT" = "PASS" ] \
   && { [ "$ADMIN_VERDICT" = "PASS" ] || [ "$ADMIN_VERDICT" = "SKIP" ]; }; then
  VERDICT="PASS"
else
  VERDICT="FAIL"
fi

DOCKER_SERVER="$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo unknown)"
DOCKER_CLIENT="$(docker version --format '{{.Client.Version}}' 2>/dev/null || echo unknown)"
PROXY_DIGEST="$(docker image inspect --format '{{if .RepoDigests}}{{index .RepoDigests 0}}{{else}}(no digest){{end}}' "$PROXY_IMAGE" 2>/dev/null || echo unknown)"
RUN_DATE="$(date '+%Y-%m-%d %H:%M %Z')"

trim_out() { head -c 2000 "$1" | tr -d '\r' | sed 's/[[:space:]]*$//'; }

mkdir -p "$(dirname "$RESULT_MD")"
cat >"$RESULT_MD" <<EOF
# M5 empirical exec-hijack gate — result

**VERDICT: $VERDICT**

| | |
|---|---|
| Date (operator's machine) | $RUN_DATE |
| Docker server / client | $DOCKER_SERVER / $DOCKER_CLIENT |
| Proxy image | \`$PROXY_IMAGE\` |
| Proxy image digest | \`$PROXY_DIGEST\` |
| Proxy env (stages 1–2) | \`CONTAINERS=1 EXEC=1 POST=1\` (stock Tecnativa ACLs) |
| Control (raw socket, PTY) | PASS |
| \`docker exec -it\` via proxy (real PTY) | $TTY_VERDICT |
| \`docker exec -i\` via proxy (no TTY) | $PLAIN_VERDICT |
| Squad-scope ACL stage (repo \`deploy/docker-proxy/haproxy.cfg\`) | $ACL_VERDICT |
| — allowed-name inspect (expect 200) | $ACL_ALLOW_CODE |
| — foreign-name inspect (expect 403; 404 = leaked to dockerd) | $ACL_DENY_CODE |
| — \`POST /containers/create\` (expect 403) | $ACL_CREATE_CODE |
| — allowed-name \`docker exec -i\` round-trip via ACL cfg | $ACL_EXEC_VERDICT |
| Admin-ACL stage (broad \`deploy/docker-proxy/haproxy.admin.cfg\`, no name regex) | $ADMIN_VERDICT |
| — \`POST /build\` (expect 403; builds go out-of-band) | $ADMIN_BUILD_CODE |
| — \`POST /swarm/init\` (expect 403) | $ADMIN_SWARM_CODE |
| — \`POST /secrets/create\` (expect 403) | $ADMIN_SECRETS_CODE |
| — container create → DELETE (\`compose down -v\`; expect 2xx/2xx) | $ADMIN_CTR_CREATE_CODE / $ADMIN_CTR_DELETE_CODE |
| — network create → DELETE (expect 2xx/2xx) | $ADMIN_NET_CREATE_CODE / $ADMIN_NET_DELETE_CODE |
| — volume create → DELETE (expect 2xx/2xx) | $ADMIN_VOL_CREATE_CODE / $ADMIN_VOL_DELETE_CODE |

Produced by \`scripts/test-socket-proxy-exec.sh\` against LOCAL docker only
(never the VM). Method: throwaway alpine target + Tecnativa
docker-socket-proxy publishing \`127.0.0.1:<free-port>:2375\`;
\`DOCKER_HOST=tcp://127.0.0.1:<port> docker exec ... sh -c 'read x; echo
got:\$x'\` driven through a real PTY (\`script\`), asserting the typed-input
echo round-trip. Docker exec-attach is an HTTP connection HIJACK
(\`Upgrade: tcp\`), which HAProxy — the engine inside the proxy — cannot be
assumed to relay (plan §7.4). The squad-scope ACL stage runs a second proxy
with the repo's custom haproxy.cfg mounted over the image template path and
\`SQUAD_EXEC_ALLOW_REGEX\` in the container environment — validating that
HAProxy expands the regex at config-parse time (manual §2.3; the Tecnativa
entrypoint seds only \`\\\${BIND_CONFIG}\`) and that the deny/allow policy
holds with the expanded value.

## Implications

EOF
if [ "$VERDICT" = "PASS" ]; then
  cat >>"$RESULT_MD" <<'EOF'
- Both exec modes round-trip through the proxy on this engine/image
  combination: the `socket-proxy` compose profile MAY be enabled per squad as
  opt-in hardening (set `WARROOM2_DOCKER_SOCK=/dev/null`,
  `WARROOM2_DOCKER_HOST=tcp://docker-proxy:2375`, add `--profile
  socket-proxy`). See deploy/templates/squad.env.template.
- The squad-scope ACL stage confirms `SQUAD_EXEC_ALLOW_REGEX` is expanded by
  HAProxy at config-parse time and enforced: allowed-name endpoints pass,
  foreign names and `containers/create` are denied by the proxy itself.
- The raw-socket DEFAULT is unchanged — new squads still boot with the raw
  socket; the proxy stays a per-squad, post-verification opt-in.
- Re-run this gate after upgrading the docker engine or the proxy image —
  PASS is empirical, not contractual.
EOF
else
  cat >>"$RESULT_MD" <<'EOF'
- The proxy does NOT reliably relay docker exec on this engine/image
  combination, OR the squad-scope ACL policy did not hold (see the table for
  which stage failed): the `socket-proxy` compose profile is **do not enable
  — follow-up** (as recorded in deploy/templates/squad.env.template).
  Enabling it would break the dashboard terminal.
- The raw-socket DEFAULT is unaffected: warroom2 keeps the read-only socket
  mount — the same exposure as the pre-multi-tenancy single-squad stack,
  scoped by squad-only exec-target env, basic-auth, loopback-only ports and
  the SSH tunnel (plan §7.4 residual-risk rationale).
- Revisit if/when the proxy (or HAProxy) gains verified support for docker's
  `Upgrade: tcp` connection hijack — then re-run this gate.
EOF
fi
{
  echo
  echo '## Raw transcripts (truncated to 2000 bytes each)'
  echo
  echo '### TTY mode (`docker exec -it` via proxy)'
  echo '```'
  trim_out "$TTY_OUT"
  echo '```'
  echo
  echo '### non-TTY mode (`docker exec -i` via proxy)'
  echo '```'
  trim_out "$PLAIN_OUT"
  echo '```'
  echo
  echo '### Squad-scope ACL stage (custom cfg via ACL proxy)'
  echo '```'
  echo "allowed-name inspect : HTTP $ACL_ALLOW_CODE (expect 200)"
  echo "foreign-name inspect : HTTP $ACL_DENY_CODE (expect 403)"
  echo "containers/create    : HTTP $ACL_CREATE_CODE (expect 403)"
  trim_out "$ACL_OUT"
  echo '```'
} >>"$RESULT_MD"

note "wrote $RESULT_MD"
note "VERDICT: $VERDICT (tty=$TTY_VERDICT, non-tty=$PLAIN_VERDICT, acl=$ACL_VERDICT, admin=$ADMIN_VERDICT)"
exit 0
