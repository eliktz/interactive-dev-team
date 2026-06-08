"""warroom2.ws_relay — per-agent WebSocket bridge.

Server frames (Server → Client):
- ``{"type":"data","data":"<base64>","seq":N}``           tmux pane bytes
- ``{"type":"bus","from":...,"to":...,"text":...,"ts":...}``   Yefet only
- ``{"type":"ack","seq":N}``                              flow-control ack
- ``{"type":"_stale"}``                                    on upstream EOF

Client frames (Client → Server):
- ``{"type":"input","data":"<base64>"}``                  user keystrokes
- ``{"type":"resize","cols":N,"rows":N}``                 tmux resize
- ``{"type":"ack","seq":N}``                              client ack

Routing: ``agent.attach == 'tmux'`` → ``TmuxSession``; ``'bus'`` →
``YefetBusSession``. Auth: same HTTP Basic header as the rest of the API; the
browser replays ``Authorization: Basic`` on the WS upgrade.
"""

from __future__ import annotations

import asyncio
import base64
import json
import logging
from typing import Optional

from fastapi import APIRouter, WebSocket, WebSocketDisconnect, status

from .agent_registry import get_agent
from .auth import ws_basic_auth
from .tmux_bridge import manager as tmux_manager
from .yefet_bridge import YefetBusSession

log = logging.getLogger(__name__)

router = APIRouter()


def _b64(buf: bytes) -> str:
    return base64.b64encode(buf).decode("ascii")


async def _send_json_safely(ws: WebSocket, payload: dict) -> bool:
    try:
        await ws.send_text(json.dumps(payload, ensure_ascii=False))
        return True
    except Exception as e:
        log.debug("ws send failed: %s", e)
        return False


async def _pump_tmux_output(ws: WebSocket, agent_id: str, session) -> None:
    seq = 0
    try:
        async for chunk in session.attach():
            seq += 1
            ok = await _send_json_safely(
                ws, {"type": "data", "data": _b64(chunk), "seq": seq}
            )
            if not ok:
                return
    except asyncio.CancelledError:
        raise
    except Exception as e:
        log.warning("tmux pump for %s ended: %s", agent_id, e)
    await _send_json_safely(ws, {"type": "_stale"})


async def _pump_bus_output(ws: WebSocket, agent_id: str, session) -> None:
    try:
        async for event in session.attach():
            ok = await _send_json_safely(ws, event)
            if not ok:
                return
    except asyncio.CancelledError:
        raise
    except Exception as e:
        log.warning("bus pump for %s ended: %s", agent_id, e)
    await _send_json_safely(ws, {"type": "_stale"})


async def _handle_client_frame(frame: dict, agent, session) -> None:
    ftype = frame.get("type")
    if ftype == "input":
        data_b64 = frame.get("data", "")
        try:
            payload = base64.b64decode(data_b64).decode("utf-8", errors="replace")
        except Exception:
            return
        if agent.attach == "tmux":
            await session.send_input(payload, literal=True)
        else:
            await session.send_input(payload)
    elif ftype == "resize":
        if agent.attach == "tmux":
            cols = int(frame.get("cols") or 0)
            rows = int(frame.get("rows") or 0)
            if cols > 0 and rows > 0:
                await session.resize(cols, rows)
    elif ftype == "ack":
        # v1: ack is recorded but no flow-control backpressure yet.
        return
    else:
        log.debug("unhandled client frame type=%s", ftype)


@router.websocket("/ws/agent/{agent_id}")
async def agent_ws(websocket: WebSocket, agent_id: str) -> None:
    user = await ws_basic_auth(websocket)
    if user is None:
        await websocket.close(code=status.WS_1008_POLICY_VIOLATION)
        return

    agent = get_agent(agent_id)
    if agent is None:
        await websocket.close(code=status.WS_1008_POLICY_VIOLATION)
        return

    await websocket.accept()

    if agent.attach == "tmux":
        session = tmux_manager.get(agent)
        pump = _pump_tmux_output
    elif agent.attach == "bus":
        session = YefetBusSession(agent)
        pump = _pump_bus_output
    else:
        await websocket.close(code=status.WS_1011_INTERNAL_ERROR)
        return

    pump_task: Optional[asyncio.Task] = asyncio.create_task(
        pump(websocket, agent_id, session)
    )

    try:
        while True:
            raw = await websocket.receive_text()
            try:
                frame = json.loads(raw)
            except json.JSONDecodeError:
                continue
            await _handle_client_frame(frame, agent, session)
    except WebSocketDisconnect:
        pass
    except Exception as e:
        log.warning("ws %s error: %s", agent_id, e)
    finally:
        if pump_task and not pump_task.done():
            pump_task.cancel()
            try:
                await pump_task
            except (asyncio.CancelledError, Exception):
                pass
        try:
            await session.close()
        except Exception:
            pass
