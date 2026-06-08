"""warroom2.tmux_bridge — attach to existing tmux panes inside the war-room container.

Per plan §6.2 we don't spawn fresh PTYs. We:
- ``tmux pipe-pane -o -t <target> 'cat >> /tmp/warroom2/<agent>.log'`` to mirror
  pane output to a log file (idempotent; ``-o`` toggles, so we use a marker
  file to make initialization once-per-agent).
- ``docker exec ... tail -F /tmp/warroom2/<agent>.log`` to stream the log.
- ``tmux send-keys -t <target> -l <data>`` to write input (literal mode).

Resize is best-effort — tmux honors the smallest connected client, so we issue
``resize-pane`` for completeness but don't fail the WS if it errors.
"""

from __future__ import annotations

import asyncio
import logging
from typing import AsyncIterator, Dict, Optional

from .agent_registry import Agent
from . import docker_client

log = logging.getLogger(__name__)

_PIPE_DIR = "/tmp/warroom2"


def _log_path(agent_id: str) -> str:
    return f"{_PIPE_DIR}/{agent_id}.log"


def _marker_path(agent_id: str) -> str:
    return f"{_PIPE_DIR}/{agent_id}.piped"


class TmuxSession:
    """Manages pipe-pane setup + tail process for a single tmux-backed agent."""

    def __init__(self, agent: Agent) -> None:
        if agent.attach != "tmux" or not agent.tmux_target:
            raise ValueError(f"Agent {agent.id} is not a tmux agent")
        self.agent = agent
        self._tail_proc: Optional[asyncio.subprocess.Process] = None

    async def ensure_pipe(self) -> None:
        """Idempotent setup: mkdir, ensure pipe-pane attached once.

        We use a marker file so subsequent attaches (reload, multi-tab) don't
        toggle ``pipe-pane -o`` off.
        """
        container = self.agent.container
        target = self.agent.tmux_target
        log_path = _log_path(self.agent.id)
        marker = _marker_path(self.agent.id)
        # mkdir + check marker + (maybe) pipe-pane. All in one shell so it's
        # one docker exec round-trip.
        script = (
            f"mkdir -p {_PIPE_DIR} && "
            f"if [ ! -f {marker} ]; then "
            f"  : > {log_path} && "
            f"  tmux pipe-pane -o -t {target} "
            f"    'cat >> {log_path}' && "
            f"  touch {marker}; "
            f"fi"
        )
        await docker_client.exec_text_async(
            container, "sh", "-c", script, timeout=10.0
        )

    async def attach(self) -> AsyncIterator[bytes]:
        """Async generator that yields pane output bytes as they arrive."""
        await self.ensure_pipe()
        # tail -F follows file rotation. ``-n 0`` so we don't re-flood every
        # reconnect; scrollback replay is a separate /api/.../scrollback call.
        gen = docker_client.exec_streaming(
            self.agent.container,
            "tail",
            "-F",
            "-n",
            "0",
            _log_path(self.agent.id),
        )
        async for chunk in gen:
            yield chunk

    async def send_input(self, data: str, literal: bool = True) -> None:
        """Send keystrokes via ``tmux send-keys``.

        ``literal=True`` uses ``-l`` so the data is sent verbatim (no key
        interpretation). For Enter / control sequences, call with
        ``literal=False`` and pass a tmux key name (e.g. ``"Enter"``).
        """
        cmd = ["tmux", "send-keys", "-t", self.agent.tmux_target or ""]
        if literal:
            cmd.append("-l")
        cmd.append(data)
        await docker_client.exec_text_async(
            self.agent.container, *cmd, timeout=5.0
        )

    async def resize(self, cols: int, rows: int) -> None:
        """Best-effort pane resize. tmux smallest-client-wins; we don't fail."""
        try:
            await docker_client.exec_text_async(
                self.agent.container,
                "tmux",
                "resize-pane",
                "-t",
                self.agent.tmux_target or "",
                "-x",
                str(cols),
                "-y",
                str(rows),
                timeout=3.0,
            )
        except Exception as e:  # pragma: no cover — best effort
            log.debug("resize ignored for %s: %s", self.agent.id, e)

    async def close(self) -> None:
        """Stop the tail process; leave pipe-pane running for the next attach."""
        if self._tail_proc and self._tail_proc.returncode is None:
            try:
                self._tail_proc.terminate()
                await asyncio.wait_for(self._tail_proc.wait(), timeout=2.0)
            except Exception:
                self._tail_proc.kill()
                await self._tail_proc.wait()
        self._tail_proc = None


class TmuxSessionManager:
    """Process-wide cache of TmuxSession instances, one per agent id."""

    def __init__(self) -> None:
        self._sessions: Dict[str, TmuxSession] = {}

    def get(self, agent: Agent) -> TmuxSession:
        sess = self._sessions.get(agent.id)
        if sess is None:
            sess = TmuxSession(agent)
            self._sessions[agent.id] = sess
        return sess

    async def close_all(self) -> None:
        for sess in self._sessions.values():
            await sess.close()
        self._sessions.clear()


manager = TmuxSessionManager()
