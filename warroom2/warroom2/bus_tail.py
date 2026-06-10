"""warroom2.bus_tail — async tail of the agent-bus NDJSON journal.

Used by:
- ``yefet_bridge`` to filter messages where ``to == 'yefet'`` or
  ``from == 'yefet'`` and stream them as chat events to the Yefet tab.
- ``event_relay`` to broadcast every bus event to the panel-wide SSE feed.

Implementation: ``tail -F`` via plain subprocess (no docker exec required —
the bus path is bind-mounted into warroom2 as well per plan §9). We yield
parsed dicts; on JSON errors we yield ``{"_raw": line, "_error": str(e)}``.
"""

from __future__ import annotations

import asyncio
import json
import logging
from typing import AsyncIterator, Dict, Optional

from .settings import settings

log = logging.getLogger(__name__)


async def tail_bus(
    path: Optional[str] = None,
) -> AsyncIterator[Dict]:
    """Yield JSON-parsed lines as they're appended to the bus file.

    The async generator owns a ``tail -F`` subprocess; cancel/close it to
    terminate the tail.
    """
    bus_path = path or settings.bus_path
    proc = await asyncio.create_subprocess_exec(
        "tail",
        "-F",
        "-n",
        "0",
        bus_path,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
    )
    assert proc.stdout is not None
    try:
        while True:
            line = await proc.stdout.readline()
            if not line:
                # tail -F can briefly EOF on rotation; small sleep + continue.
                await asyncio.sleep(0.25)
                if proc.returncode is not None:
                    log.warning(
                        "tail -F %s exited (rc=%s); ending tail",
                        bus_path,
                        proc.returncode,
                    )
                    break
                continue
            text = line.decode("utf-8", errors="replace").rstrip("\n")
            if not text.strip():
                continue
            try:
                yield json.loads(text)
            except json.JSONDecodeError as e:
                yield {"_raw": text, "_error": str(e)}
    finally:
        if proc.returncode is None:
            try:
                proc.terminate()
            except ProcessLookupError:
                pass
            try:
                await asyncio.wait_for(proc.wait(), timeout=2.0)
            except asyncio.TimeoutError:
                proc.kill()
                await proc.wait()
