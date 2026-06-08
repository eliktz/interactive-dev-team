"""warroom2.yefet_bridge — chat-style feed over the agent-bus for Yefet.

Per the 3b-backend.md spec: v1 Yefet is NOT a PTY. The openclaw container PID
1 is the daemon (no REPL/tmux inside). So the tab:

- INPUT: text typed by the operator becomes one NDJSON line appended to
  ``settings.bus_path`` with ``{"from":"operator","to":"yefet","text":...}``.
- OUTPUT: a tail of the bus filtered to lines whose ``to`` or ``from`` is
  ``yefet`` is streamed as a list of chat events.

Writes are guarded by ``fcntl.flock`` to keep concurrent appenders from
interleaving partial lines. The bus file is bind-mounted into warroom2.
"""

from __future__ import annotations

import asyncio
import datetime as _dt
import fcntl
import json
import logging
import os
from typing import AsyncIterator, Dict

from .agent_registry import Agent
from .bus_tail import tail_bus
from .settings import settings

log = logging.getLogger(__name__)


def _now_iso() -> str:
    return _dt.datetime.now(_dt.timezone.utc).isoformat()


def _is_yefet_msg(msg: Dict) -> bool:
    if not isinstance(msg, dict):
        return False
    return msg.get("to") == "yefet" or msg.get("from") == "yefet"


def _to_chat_event(msg: Dict) -> Dict:
    return {
        "type": "bus",
        "from": msg.get("from"),
        "to": msg.get("to"),
        "text": msg.get("text") or msg.get("body") or "",
        "ts": msg.get("ts") or _now_iso(),
        "raw": msg,
    }


class YefetBusSession:
    """Chat-style bridge using the agent-bus as the transport."""

    def __init__(self, agent: Agent) -> None:
        if agent.attach != "bus":
            raise ValueError(f"Agent {agent.id} is not a bus agent")
        self.agent = agent

    async def attach(self) -> AsyncIterator[Dict]:
        """Yield chat events ``{type,from,to,text,ts,raw}`` for Yefet only."""
        async for msg in tail_bus():
            if _is_yefet_msg(msg):
                yield _to_chat_event(msg)

    async def send_input(self, text: str) -> Dict:
        """Append a JSON line to the bus. Returns the event written.

        Wrapped in ``flock`` so multiple writers (warroom2, bus-recv, agents
        themselves) don't interleave bytes. Runs in a thread executor because
        ``fcntl`` is blocking.
        """
        event = {
            "from": "operator",
            "to": "yefet",
            "text": text,
            "ts": _now_iso(),
        }
        line = json.dumps(event, ensure_ascii=False) + "\n"
        await asyncio.get_running_loop().run_in_executor(
            None, _append_locked, settings.bus_path, line
        )
        return event

    async def close(self) -> None:
        """No persistent resources; the tail generator owns its own subprocess."""
        return None


def _append_locked(path: str, line: str) -> None:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "a", encoding="utf-8") as f:
        fcntl.flock(f.fileno(), fcntl.LOCK_EX)
        try:
            f.write(line)
            f.flush()
            os.fsync(f.fileno())
        finally:
            fcntl.flock(f.fileno(), fcntl.LOCK_UN)
