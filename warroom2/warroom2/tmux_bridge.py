"""warroom2.tmux_bridge — Phase B PTY-attach bridge for tmux-backed agents.

Phase A used ``tmux pipe-pane → tail -F → WebSocket`` to mirror pre-rendered
tmux output to the browser. That model is fundamentally wrong: tmux's escape
codes target the pane's geometry (200x49), but xterm.js in the browser has a
different size, so cursor-positioning codes landed at wrong coordinates and
produced the stacked/garbled rendering operators saw on long-running panes.

Phase B replaces that mirror with a per-WS ``docker exec -i -t tmux attach``
subprocess attached to its own PTY. Each browser tab becomes a real tmux
client; tmux's ``aggressive-resize on`` (set in launch.sh) gives each client
its own per-window geometry, so escape codes are sized for the receiver.

Key contract change from Phase A:
- ``TmuxSession`` (cached one-per-agent.id in a process-wide manager) is gone.
- ``TmuxPtySession`` is per-WebSocket. Sharing one PTY across tabs would
  collapse them into one tmux client and defeat per-tab resize.
- The module-level ``manager`` name is preserved so ``ws_relay`` and
  ``agents_api`` imports still work, but ``manager.get(agent)`` now returns a
  FRESH session every call — no caching.

Reads/writes are raw bytes. The pipe-pane log path and ``ensure_pipe`` setup
are deleted entirely; ``capture-pane`` remains available as a side-channel
snapshot helper but is independent of the PTY stream.
"""

from __future__ import annotations

import asyncio
import logging
import os
import time
import uuid
from typing import Dict, Optional

from .agent_registry import Agent
from . import docker_client

log = logging.getLogger(__name__)

# ── Live-client registry ─────────────────────────────────────────────────────
# Maps a per-WS linked session name (``<base>-cli-<uuid>``) to its last heartbeat
# (monotonic), or ``None`` while the WS is open but hasn't heartbeated yet.
# PRESENCE in this dict means "warroom2 has an open WebSocket for this session";
# the value adds liveness once the client (new JS) starts sending ``hb`` frames.
#
# ``sweep_stale_clients`` keeps a session iff EITHER (a) its WS is open and it has
# never heartbeated (value ``None`` — e.g. a tab on cached old JS: transition-safe,
# never wrongly reaped), or (b) its last heartbeat is fresh. It reaps a session
# when its WS is gone (absent from the dict) OR it once heartbeated but went silent
# (half-open WS from a tunnel drop). This catches the attached-but-dead phantom
# clients the zero-client ``_prune_orphan_clients`` can't see, which otherwise
# survive until the next warroom2 restart and corrupt window geometry.
_LIVE_CLIENTS: Dict[str, Optional[float]] = {}


def register_client(linked: str) -> None:
    _LIVE_CLIENTS[linked] = None  # WS open; no heartbeat seen yet


def touch_client(linked: Optional[str]) -> None:
    if linked and linked in _LIVE_CLIENTS:
        _LIVE_CLIENTS[linked] = time.monotonic()


def unregister_client(linked: Optional[str]) -> None:
    if linked:
        _LIVE_CLIENTS.pop(linked, None)


def _is_live(name: str, now: float, stale_s: float) -> bool:
    """True if the session has an open WS and (no heartbeat yet OR a fresh one)."""
    if name not in _LIVE_CLIENTS:
        return False                       # no open WS → orphan
    hb = _LIVE_CLIENTS[name]
    if hb is None:
        return True                        # WS open, pre-heartbeat (old JS) → keep
    return (now - hb) <= stale_s           # heartbeated; fresh = live, stale = half-open


async def sweep_stale_clients(
    container: str, base: str, stale_s: float = 75.0, grace_s: float = 30.0
) -> int:
    """Reap ``<base>-cli-*`` sessions whose WS is gone or whose heartbeat is stale.

    Kept iff :func:`_is_live` (open WS, and either no heartbeat yet or a fresh one),
    and only ever killed once older than ``grace_s`` so a tab mid-connect is never
    caught. Ignores ``session_attached``, so it reaps the attached-but-dead phantom
    clients that tunnel drops leave behind.
    """
    now = time.monotonic()
    script = (
        "now=$(date +%s); "
        "tmux list-sessions -F '#{session_name} #{session_created}' 2>/dev/null | "
        f"while read n c; do case \"$n\" in {base}-cli-*) "
        f"if [ $((now - c)) -gt {int(grace_s)} ]; then echo \"$n\"; fi ;; esac; done"
    )
    try:
        out = await docker_client.exec_text_async(container, "sh", "-c", script, timeout=5.0)
    except Exception as e:  # pragma: no cover — best effort
        log.debug("sweep_stale_clients list failed for %s: %s", container, e)
        return 0
    candidates = [ln.strip() for ln in out.splitlines() if ln.strip()]
    stale = [n for n in candidates if not _is_live(n, now, stale_s)]
    killed = 0
    for name in stale:
        try:
            await docker_client.exec_text_async(
                container, "tmux", "kill-session", "-t", name, timeout=2.0
            )
            unregister_client(name)
            killed += 1
        except Exception as e:  # pragma: no cover
            log.debug("sweep kill %s failed: %s", name, e)
    if killed:
        log.info("swept %d stale tmux client session(s) in %s: %s",
                 killed, container, ", ".join(stale))
    return killed


async def _prune_orphan_clients(container: str, base: str, min_age_s: int = 15) -> int:
    """Kill leftover ``<base>-cli-*`` grouped sessions with no attached client.

    Each browser tab spawns a per-WS grouped session; ``close()`` removes it on
    a clean disconnect, but a warroom2 restart kills the process without running
    ``close()``, so those sessions orphan in the container and pile up. A
    stale/half-built one can wedge a reconnecting tab into a "can't find window"
    loop. Reaped on each new attach. Only sessions with zero clients AND older
    than ``min_age_s`` are killed, so a sibling tab mid-connect (its session is
    briefly client-less right after ``new-session -d``) is never caught.
    """
    script = (
        "now=$(date +%s); "
        "tmux list-sessions -F '#{session_name} #{session_attached} #{session_created}' "
        "2>/dev/null | while read n a c; do "
        f"case \"$n\" in {base}-cli-*) "
        f"if [ \"$a\" = 0 ] && [ $((now - c)) -gt {int(min_age_s)} ]; then "
        "tmux kill-session -t \"$n\" && echo \"$n\"; fi ;; esac; done"
    )
    try:
        out = await docker_client.exec_text_async(
            container, "sh", "-c", script, timeout=5.0
        )
        killed = [ln for ln in out.splitlines() if ln.strip()]
        if killed:
            log.info("pruned %d orphan tmux session(s) in %s: %s",
                     len(killed), container, ", ".join(killed))
        return len(killed)
    except Exception as e:  # pragma: no cover — best effort
        log.debug("prune_orphan_clients failed for %s: %s", container, e)
        return 0


async def reap_all_client_sessions(container: str, base: str) -> int:
    """Kill ALL ``<base>-cli-*`` grouped sessions unconditionally.

    Called once at warroom2 startup. Any client session present then is a
    leftover from a PRIOR warroom2 instance (no WebSocket is connected to the
    freshly-started process yet). Such leftovers stay ``session_attached==1``
    because their orphaned ``docker exec tmux attach`` process is still alive,
    so the age/detached guard in ``_prune_orphan_clients`` never reaps them and
    they pile up — corrupting window geometry. At startup it is always safe to
    drop every one; live tabs reconnect and recreate their own right after.
    """
    script = (
        "tmux list-sessions -F '#{session_name}' 2>/dev/null | "
        f"while read n; do case \"$n\" in {base}-cli-*) "
        "tmux kill-session -t \"$n\" 2>/dev/null && echo \"$n\";; esac; done"
    )
    try:
        out = await docker_client.exec_text_async(
            container, "sh", "-c", script, timeout=8.0
        )
        killed = [ln for ln in out.splitlines() if ln.strip()]
        if killed:
            log.info("startup-reaped %d leftover tmux client session(s) in %s",
                     len(killed), container)
        return len(killed)
    except Exception as e:  # pragma: no cover — best effort
        log.debug("reap_all_client_sessions failed for %s: %s", container, e)
        return 0


class TmuxPtySession:
    """One ``docker exec -i -t tmux attach -t <target>`` PTY per WebSocket.

    Lifetime is bound to the WS: ``attach()`` spawns the subprocess, ``close()``
    terminates it. ``read()`` returns raw bytes from the PTY master; ``write()``
    accepts raw bytes. Reads and writes are dispatched via the default executor
    because ``os.read`` / ``os.write`` on a PTY master are blocking syscalls.
    """

    def __init__(self, agent: Agent) -> None:
        if agent.attach != "tmux" or not agent.tmux_target:
            raise ValueError(f"Agent {agent.id} is not a tmux agent")
        self.agent = agent
        self._proc: Optional[asyncio.subprocess.Process] = None
        self._master: Optional[int] = None
        self._closed = False
        self._linked: Optional[str] = None
        # Resize coalescing state. Each container resize is a ~130ms `docker
        # exec stty`; an un-coalesced resize storm spawns one per frame and
        # starves keystroke writes on the shared executor. We keep at most one
        # exec in flight per session: a resize arriving while one is running
        # only updates the pending target, which the in-flight task picks up on
        # a trailing-edge pass. ``_applied_geom`` tracks the last geometry we
        # actually pushed so unchanged resizes are skipped entirely.
        self._pending_geom: Optional[tuple[int, int]] = None
        self._applied_geom: Optional[tuple[int, int]] = None
        self._resize_inflight = False
        # Focused-streaming: when paused, the pty→ws pump keeps draining the PTY
        # (so tmux never blocks) but does NOT forward output to the browser. The
        # client sends a ``focus`` frame to pause/resume; on resume we force a
        # tmux redraw so the newly-shown tab repaints its current screen. This
        # lets a multi-agent squad stream only the ONE focused agent, freeing the
        # browser's single main thread (5 live streams were starving keystroke
        # handling on the busy squad).
        self.paused = False

    async def attach(self) -> None:
        """Spawn the docker-exec tmux-attach subprocess and capture PTY master.

        Uses a per-WS *grouped session* (tmux ``new-session -t <base>``) instead
        of attaching directly to the base session. Without grouping, multiple
        clients share one current-window pointer — so ``attach -t base:N``
        pulls every other client to window N, and whichever browser tab
        connects last wins for all of them. A grouped session shares all
        windows with the base but has its own current-window state, so each
        browser tab stays put on the window it asked for.

        Cleanup of the linked session is handled by ``close()`` (kill-session
        on the linked name). We deliberately do NOT set ``destroy-unattached
        on`` here — that option destroys a session the moment it has no
        attached clients, and tmux fires it immediately after ``new-session
        -d`` (the session is created detached), wiping the linked session
        before ``select-window`` / ``attach`` can run.
        """
        target = self.agent.tmux_target or ""
        base, _, window = target.partition(":")
        if not base or not window:
            raise ValueError(f"tmux_target must be 'session:window', got {target!r}")
        linked = f"{base}-cli-{uuid.uuid4().hex[:8]}"
        self._linked = linked
        # Register in the heartbeat table immediately (before new-session) so the
        # periodic sweep treats this mid-connecting tab as live, not an orphan.
        register_client(linked)
        # Reap orphaned client sessions (prior warroom2 instances / failed
        # disconnects) before adding ours, so they can't accumulate and wedge a
        # tab into a "can't find window" loop.
        await _prune_orphan_clients(self.agent.container, base)
        # One sh -c invocation: create the linked session, select the desired
        # window on it, then exec into attach (so the attach process replaces
        # the shell — no orphan sh wrapper to clean up).
        script = (
            f"tmux new-session -d -t {base} -s {linked} -x 200 -y 50 && "
            f"tmux select-window -t {linked}:{window} && "
            f"exec tmux attach -t {linked}"
        )
        self._proc, self._master = await docker_client.exec_pty(
            self.agent.container, "sh", "-c", script,
        )

    async def read(self, max_bytes: int = 4096) -> bytes:
        """One bounded read from the PTY master. Returns ``b''`` on EOF."""
        if self._master is None or self._closed:
            return b""
        loop = asyncio.get_running_loop()
        try:
            return await loop.run_in_executor(None, os.read, self._master, max_bytes)
        except OSError:
            return b""

    async def write(self, data: bytes) -> None:
        """Write raw bytes to the PTY master, looping until fully flushed."""
        if self._master is None or self._closed or not data:
            return
        view = memoryview(data)
        loop = asyncio.get_running_loop()
        offset = 0
        while offset < len(view):
            n = await loop.run_in_executor(
                None, os.write, self._master, bytes(view[offset:])
            )
            if n <= 0:
                break
            offset += n

    def resize(self, cols: int, rows: int) -> None:
        """Push a new geometry through to the in-container tmux client.

        TIOCSWINSZ on our local PTY master does NOT reach the agent's tmux:
        ``docker exec -t`` receives no SIGWINCH here, so the in-container exec
        TTY stays frozen at the startup 80x24 and every browser resize is
        dropped. We still set the master winsize (harmless), then resize the
        in-container client's own PTS directly with ``stty`` — the exec user
        owns that pts, so no root is needed — which delivers SIGWINCH to the
        tmux client and (with aggressive-resize) the window follows.
        """
        if self._master is None or self._closed:
            return
        if cols <= 0 or rows <= 0:
            return
        try:
            docker_client.set_winsize(self._master, rows, cols)
        except OSError as e:  # pragma: no cover — best effort
            log.debug("set_winsize ignored for %s: %s", self.agent.id, e)
        if not self._linked:
            return
        # Coalesce: record the latest target and only spawn a new exec if none
        # is in flight. An in-flight task will pick up this geometry on its
        # trailing pass, so the FINAL geometry is always applied without
        # flooding the executor with one docker exec per frame.
        self._pending_geom = (cols, rows)
        if self._resize_inflight:
            return
        try:
            asyncio.get_running_loop().create_task(self._resize_drain())
        except RuntimeError:  # no running loop — skip
            pass

    async def _resize_drain(self) -> None:
        """Apply pending geometry one exec at a time until the queue settles.

        Loops trailing-edge: after each ``stty`` completes, if a newer geometry
        arrived meanwhile (and differs from what was applied), apply that too.
        Guarantees the last requested geometry is the one finally applied while
        keeping at most one ``docker exec`` in flight per session.
        """
        if self._resize_inflight:
            return
        self._resize_inflight = True
        try:
            while not self._closed:
                target = self._pending_geom
                if target is None or target == self._applied_geom:
                    break
                self._pending_geom = None
                await self._resize_container_client(target[0], target[1])
                self._applied_geom = target
        finally:
            self._resize_inflight = False

    async def _resize_container_client(self, cols: int, rows: int) -> None:
        """stty the PTS of the client attached to our grouped session."""
        linked = self._linked
        if not linked or self._closed:
            return
        script = (
            f"t=$(tmux list-clients -t {linked} -F '#{{client_tty}}' | head -n1); "
            f'[ -n "$t" ] && stty -F "$t" rows {int(rows)} cols {int(cols)} || true'
        )
        try:
            await docker_client.exec_text_async(
                self.agent.container, "sh", "-c", script, timeout=5.0
            )
        except Exception as e:  # pragma: no cover — best effort
            log.debug("container resize ignored for %s: %s", self.agent.id, e)

    async def request_redraw(self) -> None:
        """Force tmux to repaint our attached client (used on focus resume).

        While paused, the pty→ws pump discards output, so the browser's xterm is
        stale by the time the tab is shown again. ``tmux refresh-client`` forces
        a full redraw of the client's current screen, which flows through the PTY
        and the (now-unpaused) pump back to the browser.
        """
        linked = self._linked
        if not linked or self._closed:
            return
        script = (
            f"t=$(tmux list-clients -t {linked} -F '#{{client_tty}}' | head -n1); "
            f'[ -n "$t" ] && tmux refresh-client -t "$t" || true'
        )
        try:
            await docker_client.exec_text_async(
                self.agent.container, "sh", "-c", script, timeout=5.0
            )
        except Exception as e:  # pragma: no cover — best effort
            log.debug("request_redraw ignored for %s: %s", self.agent.id, e)

    async def capture_snapshot(self, lines: int = 200) -> str:
        """Best-effort scrollback capture via ``tmux capture-pane``.

        Runs as a one-shot side-channel ``docker exec`` — independent of the
        live PTY session. Used by the ``/scrollback`` REST endpoint.
        """
        target = self.agent.tmux_target or ""
        try:
            return await docker_client.exec_text_async(
                self.agent.container,
                "tmux", "capture-pane", "-p", "-e", "-J",
                "-t", target, "-S", f"-{lines}",
                timeout=5.0,
            )
        except Exception as e:  # pragma: no cover — best effort
            log.warning("capture_snapshot failed for %s: %s", self.agent.id, e)
            return ""

    async def close(self) -> None:
        """Terminate the docker-exec subprocess and release the PTY master.

        Mirrors ``exec_streaming``'s cleanup ladder: ``terminate()`` → 2s wait
        → ``kill()`` → ``await wait()``. The master fd is always closed in a
        ``finally:``-style try/except so a hung subprocess can't leak the fd.
        """
        if self._closed:
            return
        self._closed = True
        proc, master = self._proc, self._master
        self._proc, self._master = None, None
        if proc is not None and proc.returncode is None:
            try:
                proc.terminate()
                try:
                    await asyncio.wait_for(proc.wait(), timeout=2.0)
                except asyncio.TimeoutError:
                    proc.kill()
                    await proc.wait()
            except ProcessLookupError:
                pass
            except Exception as e:  # pragma: no cover — best effort
                log.debug("close terminate ignored for %s: %s", self.agent.id, e)
        if master is not None:
            try:
                os.close(master)
            except OSError:
                pass
        # Belt-and-suspenders: kill the linked grouped session in case
        # `destroy-unattached on` didn't fire (e.g., subprocess died before
        # the attach completed). Best-effort; ignore failures.
        linked = self._linked
        self._linked = None
        unregister_client(linked)
        if linked:
            try:
                await docker_client.exec_text_async(
                    self.agent.container,
                    "tmux", "kill-session", "-t", linked,
                    timeout=2.0,
                )
            except Exception:
                pass


class TmuxPtySessionManager:
    """Compat shim — preserves the ``manager.get(agent)`` import contract.

    Phase A's cache pattern (one ``TmuxSession`` per ``agent.id``) is
    intentionally abandoned. PTY sessions are per-WebSocket; ``get()`` always
    returns a fresh session that the caller owns and must ``close()``.
    """

    async def close_all(self) -> None:
        """No-op — sessions are owned by their WS handlers, not this manager."""
        return

    def get(self, agent: Agent) -> TmuxPtySession:
        return TmuxPtySession(agent)


manager = TmuxPtySessionManager()
