"""warroom2.event_relay — panel-wide SSE feed of the agent-bus.

Per plan §4.2 / §5.4 the SSE channel ``/api/events`` is shared across all
tabs; it carries every bus message plus heartbeat ticks. Per-agent transport
lives on the WS endpoints.
"""

from __future__ import annotations

import asyncio
import json
import logging
import time
from typing import AsyncIterator

from fastapi import APIRouter, Depends, Request
from fastapi.responses import StreamingResponse

from .auth import basic_auth_dependency
from .bus_tail import tail_bus

log = logging.getLogger(__name__)

router = APIRouter()

_HEARTBEAT_SECS = 15.0


def _sse_frame(event: str, data) -> bytes:
    payload = data if isinstance(data, str) else json.dumps(data, ensure_ascii=False)
    return f"event: {event}\ndata: {payload}\n\n".encode("utf-8")


async def _bus_stream(request: Request) -> AsyncIterator[bytes]:
    """Multiplex bus tail and heartbeats into one byte stream."""
    yield _sse_frame("hello", {"ok": True})

    bus = tail_bus()
    bus_iter = bus.__aiter__()

    async def _next_msg():
        return await bus_iter.__anext__()

    pending = asyncio.create_task(_next_msg())
    try:
        while True:
            if await request.is_disconnected():
                break
            done, _ = await asyncio.wait(
                {pending},
                timeout=_HEARTBEAT_SECS,
                return_when=asyncio.FIRST_COMPLETED,
            )
            if not done:
                yield _sse_frame("heartbeat", {"ts": time.time()})
                continue
            try:
                msg = pending.result()
            except StopAsyncIteration:
                break
            except Exception as e:  # pragma: no cover
                log.warning("bus tail error: %s", e)
                yield _sse_frame("error", {"error": str(e)})
                break
            yield _sse_frame("bus", msg)
            pending = asyncio.create_task(_next_msg())
    finally:
        pending.cancel()
        try:
            await pending
        except (asyncio.CancelledError, Exception):
            pass
        await bus.aclose()


@router.get("/api/events")
async def events(request: Request, _user: str = Depends(basic_auth_dependency)):
    return StreamingResponse(
        _bus_stream(request),
        media_type="text/event-stream",
        headers={
            "Cache-Control": "no-cache",
            "X-Accel-Buffering": "no",
            "Connection": "keep-alive",
        },
    )
