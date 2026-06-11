# M5 empirical exec-hijack gate — result

**VERDICT: PASS**

| | |
|---|---|
| Date (operator's machine) | 2026-06-11 08:02 IDT |
| Docker server / client | 28.5.2 / 29.1.5 |
| Proxy image | `tecnativa/docker-socket-proxy:latest` |
| Proxy image digest | `tecnativa/docker-socket-proxy@sha256:1f3a6f303320723d199d2316a3e82b2e2685d86c275d5e3deeaf182573b47476` |
| Proxy env | `CONTAINERS=1 EXEC=1 POST=1` (stock Tecnativa ACLs) |
| Control (raw socket, PTY) | PASS |
| `docker exec -it` via proxy (real PTY) | PASS |
| `docker exec -i` via proxy (no TTY) | PASS |

Produced by `scripts/test-socket-proxy-exec.sh` against LOCAL docker only
(never the VM). Method: throwaway alpine target + Tecnativa
docker-socket-proxy publishing `127.0.0.1:<free-port>:2375`;
`DOCKER_HOST=tcp://127.0.0.1:<port> docker exec ... sh -c 'read x; echo
got:$x'` driven through a real PTY (`script`), asserting the typed-input
echo round-trip. Docker exec-attach is an HTTP connection HIJACK
(`Upgrade: tcp`), which HAProxy — the engine inside the proxy — cannot be
assumed to relay (plan §7.4).

## Implications

- Both exec modes round-trip through the proxy on this engine/image
  combination: the `socket-proxy` compose profile MAY be enabled per squad as
  opt-in hardening (set `WARROOM2_DOCKER_SOCK=/dev/null`,
  `WARROOM2_DOCKER_HOST=tcp://docker-proxy:2375`, add `--profile
  socket-proxy`). See deploy/templates/squad.env.template.
- The raw-socket DEFAULT is unchanged — new squads still boot with the raw
  socket; the proxy stays a per-squad, post-verification opt-in.
- Re-run this gate after upgrading the docker engine or the proxy image —
  PASS is empirical, not contractual.

## Raw transcripts (truncated to 2000 bytes each)

### TTY mode (`docker exec -it` via proxy)
```
hello-tty-17125-20526
hello-tty-17125-20526
got:hello-tty-17125-20526
```

### non-TTY mode (`docker exec -i` via proxy)
```
got:hello-plain-17125-20526
```
