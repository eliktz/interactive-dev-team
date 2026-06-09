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
import uuid
from typing import Optional

from .agent_registry import Agent
from . import docker_client

log = logging.getLogger(__name__)


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

    async def attach(self) -> None:
        """Spawn the docker-exec tmux-attach subprocess and capture PTY master.

        Uses a per-WS *grouped session* (tmux ``new-session -t <base>``) instead
        of attaching directly to the base session. Without grouping, multiple
        clients share one current-window pointer — so ``attach -t base:N``
        pulls every other client to window N, and whichever browser tab
        connects last wins for all of them. A grouped session shares all
        windows with the base but has its own current-window state, so each
        browser tab stays put on the window it asked for.

        ``destroy-unattached on`` makes the linked session vanish the moment
        the client detaches (browser tab close / WS error), so no GC needed.
        """
        target = self.agent.tmux_target or ""
        base, _, window = target.partition(":")
        if not base or not window:
            raise ValueError(f"tmux_target must be 'session:window', got {target!r}")
        linked = f"{base}-cli-{uuid.uuid4().hex[:8]}"
        self._linked = linked
        # One sh -c invocation: create the linked session, select the desired
        # window on it, then exec into attach (so the attach process replaces
        # the shell — no orphan sh wrapper to clean up).
        script = (
            f"tmux new-session -d -t {base} -s {linked} -x 200 -y 50 && "
            f"tmux set-option -t {linked} destroy-unattached on >/dev/null && "
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
        """Push a new geometry through to tmux via TIOCSWINSZ on the master."""
        if self._master is None or self._closed:
            return
        if cols <= 0 or rows <= 0:
            return
        try:
            docker_client.set_winsize(self._master, rows, cols)
        except OSError as e:  # pragma: no cover — best effort
            log.debug("set_winsize ignored for %s: %s", self.agent.id, e)

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
