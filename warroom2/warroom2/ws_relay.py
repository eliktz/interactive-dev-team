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

Routing: ``agent.attach == 'tmux'`` → Phase B ``TmuxPtySession`` (PTY-attach
via ``docker exec -i -t tmux attach``, two-pump gather); ``'bus'`` →
``YefetBusSession`` (single pump + client-frame loop). Auth: same HTTP Basic
header as the rest of the API; the browser replays ``Authorization: Basic``
on the WS upgrade.
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


async def _pump_pty_to_ws(ws: WebSocket, agent_id: str, session) -> None:
    """Stream PTY master bytes → base64 → ``{type:data,data,seq}`` WS frames."""
    seq = 0
    try:
        while True:
            chunk = await session.read()
            if not chunk:
                break
            # Focused-streaming: keep draining the PTY (so tmux never blocks) but
            # don't forward output for an unfocused agent. The browser repaints on
            # resume via request_redraw(), so the discarded interim output is fine.
            if getattr(session, "paused", False):
                continue
            seq += 1
            ok = await _send_json_safely(
                ws, {"type": "data", "data": _b64(chunk), "seq": seq}
            )
            if not ok:
                return
    except asyncio.CancelledError:
        raise
    except Exception as e:
        log.warning("tmux pty→ws pump for %s ended: %s", agent_id, e)
    await _send_json_safely(ws, {"type": "_stale"})


async def _pump_ws_to_pty(ws: WebSocket, agent_id: str, session) -> None:
    """Consume client frames; write input bytes / apply resize to the PTY."""
    try:
        while True:
            raw = await ws.receive_text()
            try:
                frame = json.loads(raw)
            except json.JSONDecodeError:
                continue
            ftype = frame.get("type")
            if ftype == "input":
                data_b64 = frame.get("data", "")
                try:
                    payload = base64.b64decode(data_b64)
                except Exception:
                    continue
                await session.write(payload)
            elif ftype == "resize":
                cols = int(frame.get("cols") or 0)
                rows = int(frame.get("rows") or 0)
                if cols > 0 and rows > 0:
                    session.resize(cols, rows)
            elif ftype == "focus":
                # Pause/resume this agent's output stream. On resume, force a
                # redraw so the newly-shown tab repaints its current screen.
                active = bool(frame.get("active"))
                was_paused = getattr(session, "paused", False)
                session.paused = not active
                if active and was_paused:
                    try:
                        await session.request_redraw()
                    except Exception:
                        pass
            elif ftype == "ack":
                continue
            else:
                log.debug("unhandled client frame type=%s", ftype)
    except WebSocketDisconnect:
        return
    except asyncio.CancelledError:
        raise
    except Exception as e:
        log.warning("tmux ws→pty pump for %s ended: %s", agent_id, e)


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


async def _handle_bus_client_frame(frame: dict, session) -> None:
    """Client→server frame dispatch for the Yefet bus branch.

    The tmux branch handles its own client frames inside ``_pump_ws_to_pty``
    so input bytes go raw to the PTY; this helper is only for ``bus``.
    """
    ftype = frame.get("type")
    if ftype == "input":
        data_b64 = frame.get("data", "")
        try:
            payload = base64.b64decode(data_b64).decode("utf-8", errors="replace")
        except Exception:
            return
        await session.send_input(payload)
    elif ftype == "ack":
        return
    else:
        log.debug("unhandled bus client frame type=%s", ftype)


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
        await _serve_tmux(websocket, agent_id, agent)
    elif agent.attach == "bus":
        await _serve_bus(websocket, agent_id, agent)
    else:
        await websocket.close(code=status.WS_1011_INTERNAL_ERROR)


async def _serve_tmux(websocket: WebSocket, agent_id: str, agent) -> None:
    """Phase B PTY path: spawn a fresh session, run both pumps concurrently."""
    session = tmux_manager.get(agent)
    try:
        await session.attach()
    except Exception as e:
        log.warning("tmux attach failed for %s: %s", agent_id, e)
        await _send_json_safely(websocket, {"type": "_stale"})
        try:
            await session.close()
        except Exception:
            pass
        return

    pty_task = asyncio.create_task(_pump_pty_to_ws(websocket, agent_id, session))
    ws_task = asyncio.create_task(_pump_ws_to_pty(websocket, agent_id, session))
    try:
        done, pending = await asyncio.wait(
            {pty_task, ws_task},
            return_when=asyncio.FIRST_COMPLETED,
        )
        # Close the PTY first so the executor os.read unblocks with OSError
        # (TmuxPtySession.read() handles it and returns b''), then cancel the
        # peer task. Closing in the outer finally would deadlock the still-
        # blocked executor thread.
        await session.close()
        for t in pending:
            t.cancel()
            try:
                await t
            except (asyncio.CancelledError, Exception):
                pass
        # Surface any non-cancelled exception so the outer handler can log.
        for t in done:
            exc = t.exception()
            if exc is not None and not isinstance(exc, asyncio.CancelledError):
                raise exc
    finally:
        # session.close() is idempotent — calling again is safe (the _closed
        # guard makes it a no-op).
        await session.close()


async def _serve_bus(websocket: WebSocket, agent_id: str, agent) -> None:
    """Yefet bus path: single pump task + main-loop client frame consumer."""
    session = YefetBusSession(agent)
    pump_task: Optional[asyncio.Task] = asyncio.create_task(
        _pump_bus_output(websocket, agent_id, session)
    )

    try:
        while True:
            raw = await websocket.receive_text()
            try:
                frame = json.loads(raw)
            except json.JSONDecodeError:
                continue
            await _handle_bus_client_frame(frame, session)
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
