"""warroom2.docker_client — thin wrapper around ``docker exec``.

warroom2 mounts ``/var/run/docker.sock`` read-only and shells out to the
``docker`` CLI in the same container. We deliberately avoid the Python SDK
because:
- We need streaming stdio for tmux pipe-pane tails and Yefet stdio.
- The CLI is what the operator already trusts; matches debug ergonomics.

All functions assume Python 3.11+ asyncio.
"""

from __future__ import annotations

import asyncio
import subprocess
from typing import AsyncIterator, List, Tuple


def _docker_exec_cmd(container: str, *cmd: str) -> List[str]:
    return ["docker", "exec", container, *cmd]


def _docker_exec_i_cmd(container: str, *cmd: str) -> List[str]:
    return ["docker", "exec", "-i", container, *cmd]


def exec_text(container: str, *cmd: str, timeout: float = 10.0) -> str:
    """Synchronous capture of stdout. Raises CalledProcessError on non-zero exit."""
    full = _docker_exec_cmd(container, *cmd)
    result = subprocess.run(
        full,
        capture_output=True,
        text=True,
        timeout=timeout,
        check=True,
    )
    return result.stdout


async def exec_text_async(
    container: str, *cmd: str, timeout: float = 10.0
) -> str:
    """Async version of ``exec_text``."""
    full = _docker_exec_cmd(container, *cmd)
    proc = await asyncio.create_subprocess_exec(
        *full,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
    )
    try:
        stdout, stderr = await asyncio.wait_for(
            proc.communicate(), timeout=timeout
        )
    except asyncio.TimeoutError:
        proc.kill()
        await proc.wait()
        raise
    if proc.returncode != 0:
        raise RuntimeError(
            f"docker exec failed ({proc.returncode}): "
            f"{stderr.decode('utf-8', errors='replace').strip()}"
        )
    return stdout.decode("utf-8", errors="replace")


async def exec_streaming(
    container: str, *cmd: str, chunk_size: int = 4096
) -> AsyncIterator[bytes]:
    """Yield stdout bytes from ``docker exec`` as they arrive.

    Caller is responsible for terminating the async generator (close it) to
    stop the underlying subprocess.
    """
    full = _docker_exec_cmd(container, *cmd)
    proc = await asyncio.create_subprocess_exec(
        *full,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
    )
    assert proc.stdout is not None
    try:
        while True:
            chunk = await proc.stdout.read(chunk_size)
            if not chunk:
                break
            yield chunk
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


async def exec_attach_stdio(
    container: str, *cmd: str
) -> Tuple[asyncio.subprocess.Process, asyncio.StreamWriter, asyncio.StreamReader]:
    """Start ``docker exec -i`` and return ``(proc, stdin_writer, stdout_reader)``.

    Caller owns the process lifecycle. Use ``proc.terminate()`` and ``await
    proc.wait()`` to clean up.
    """
    full = _docker_exec_i_cmd(container, *cmd)
    proc = await asyncio.create_subprocess_exec(
        *full,
        stdin=asyncio.subprocess.PIPE,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
    )
    assert proc.stdin is not None and proc.stdout is not None
    return proc, proc.stdin, proc.stdout
