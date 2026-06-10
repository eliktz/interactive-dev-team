"""warroom2.agents_api — REST endpoints for the 4 agents.

- ``GET  /api/agents``                       list agents + last-activity ts
- ``POST /api/agents/{id}/send-message``     write to tmux send-keys or bus
- ``GET  /api/agents/{id}/scrollback``       last N lines via tmux
                                              capture-pane (bus tail for Yefet)
"""

from __future__ import annotations

import json
import logging
import os
import time
from typing import Dict, List, Optional

from fastapi import APIRouter, Depends, HTTPException, status
from pydantic import BaseModel

from .agent_registry import Agent, get_agent, list_agents
from .auth import basic_auth_dependency
from . import docker_client
from .settings import settings
from .yefet_bridge import YefetBusSession

log = logging.getLogger(__name__)

router = APIRouter()


class SendMessageBody(BaseModel):
    text: str
    press_enter: bool = True


def _agent_to_json(agent: Agent, last_activity_ts: Optional[float]) -> Dict:
    return {
        "id": agent.id,
        "name": agent.name,
        "model": agent.model,
        "attach": agent.attach,
        "color": agent.color,
        "container": agent.container,
        "tmux_target": agent.tmux_target,
        "persona_path": agent.persona_path,
        "last_activity_ts": last_activity_ts,
    }


def _last_activity_for(agent: Agent) -> Optional[float]:
    """Best-effort mtime probe; returns None when unavailable."""
    try:
        if agent.attach == "tmux":
            # Pipe-pane log mtime lives inside the war-room container; we don't
            # ssh in for every list call — the per-agent /scrollback endpoint
            # is where this gets refreshed. Return None here.
            return None
        if agent.attach == "bus":
            try:
                return os.path.getmtime(settings.bus_path)
            except OSError:
                return None
    except Exception:  # pragma: no cover
        return None
    return None


@router.get("/api/agents")
async def get_agents(_user: str = Depends(basic_auth_dependency)) -> Dict:
    out: List[Dict] = []
    for agent in list_agents():
        out.append(_agent_to_json(agent, _last_activity_for(agent)))
    return {"agents": out, "ts": time.time()}


@router.post("/api/agents/{agent_id}/send-message")
async def send_message(
    agent_id: str,
    body: SendMessageBody,
    _user: str = Depends(basic_auth_dependency),
) -> Dict:
    agent = get_agent(agent_id)
    if agent is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="unknown agent")

    if agent.attach == "tmux":
        # Phase B: live PTY sessions are owned by WS handlers, so the REST
        # send-message path uses one-shot side-channel ``docker exec tmux
        # send-keys`` calls. ``-l`` sends the text verbatim; a follow-up
        # ``Enter`` key event fires submission when requested. This bypasses
        # the PTY entirely — clean and parallel-safe vs. any open WS.
        target = agent.tmux_target or ""
        await docker_client.exec_text_async(
            agent.container, "tmux", "send-keys", "-t", target, "-l", body.text,
            timeout=5.0,
        )
        if body.press_enter:
            await docker_client.exec_text_async(
                agent.container, "tmux", "send-keys", "-t", target, "Enter",
                timeout=5.0,
            )
        return {"ok": True, "via": "tmux", "agent": agent.id}

    if agent.attach == "bus":
        sess = YefetBusSession(agent)
        event = await sess.send_input(body.text)
        return {"ok": True, "via": "bus", "agent": agent.id, "event": event}

    raise HTTPException(
        status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
        detail=f"unsupported attach mode: {agent.attach}",
    )


def _read_bus_scrollback(limit: int) -> List[Dict]:
    """Return last ``limit`` Yefet-relevant entries from the bus file."""
    path = settings.bus_path
    if not os.path.exists(path):
        return []
    # Cheap tail read — fine for our bus file sizes (<100MB).
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        lines = f.readlines()
    out: List[Dict] = []
    for line in reversed(lines):
        line = line.strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
        except json.JSONDecodeError:
            continue
        if msg.get("to") == "yefet" or msg.get("from") == "yefet":
            out.append(msg)
            if len(out) >= limit:
                break
    out.reverse()
    return out


@router.get("/api/agents/{agent_id}/scrollback")
async def scrollback(
    agent_id: str,
    limit: int = 200,
    _user: str = Depends(basic_auth_dependency),
) -> Dict:
    agent = get_agent(agent_id)
    if agent is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="unknown agent")

    limit = max(1, min(int(limit), 5000))

    if agent.attach == "tmux":
        # Phase B: pipe-pane log files are gone. Capture the last ``limit``
        # lines straight from tmux's pane history via ``capture-pane -S -N``.
        # ``-e`` keeps ANSI escapes so colors survive; ``-J`` preserves
        # wrapped lines; ``-p`` prints to stdout.
        target = agent.tmux_target or ""
        try:
            text = await docker_client.exec_text_async(
                agent.container,
                "tmux", "capture-pane", "-p", "-e", "-J",
                "-t", target, "-S", f"-{limit}",
                timeout=5.0,
            )
        except Exception as e:
            log.warning("scrollback %s failed: %s", agent.id, e)
            text = ""
        return {"ok": True, "agent": agent.id, "kind": "tmux", "text": text}

    if agent.attach == "bus":
        items = _read_bus_scrollback(limit)
        return {"ok": True, "agent": agent.id, "kind": "bus", "items": items}

    raise HTTPException(
        status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
        detail=f"unsupported attach mode: {agent.attach}",
    )
