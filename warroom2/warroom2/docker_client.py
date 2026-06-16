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
import fcntl
import os
import pty
import struct
import subprocess
import termios
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


def set_winsize(fd: int, rows: int, cols: int) -> None:
    """Set the window size on a PTY master fd via ``TIOCSWINSZ``.

    Used to push the browser xterm.js geometry through to tmux so its
    aggressive-resize redraw targets the receiver's actual viewport.
    """
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))


async def exec_pty(
    container: str, *cmd: str
) -> Tuple[asyncio.subprocess.Process, int]:
    """Spawn ``docker exec -i -t <container> <cmd...>`` attached to a fresh PTY.

    Returns ``(process, master_fd)``. Caller owns both — must terminate the
    process AND ``os.close(master_fd)`` on cleanup. The initial winsize is
    24x80; clients should send their real size via ``TIOCSWINSZ`` (or this
    module's ``set_winsize``) immediately after attach so tmux's first redraw
    targets the right geometry.

    The ``-i -t`` flags are both required: ``-i`` keeps stdin open so we can
    forward keystrokes, ``-t`` makes docker allocate a TTY on the container
    side. We provide our own PTY via ``pty.openpty()``; the slave fd becomes
    docker exec's stdio so the CLI's ``isatty`` check passes even though
    warroom2 itself is daemonized.

    The slave is made the docker CLI's *controlling terminal* (``setsid`` +
    ``TIOCSCTTY`` in the child). Without that, a later ``TIOCSWINSZ`` on the
    master delivers no ``SIGWINCH`` to the docker CLI, so it never calls the
    exec-resize API and the in-container tmux stays frozen at the initial
    24x80 forever — every browser resize is silently dropped. With it, resizes
    propagate the whole way: master winsize -> SIGWINCH -> docker resize ->
    in-container TTY -> tmux.
    """
    master, slave = pty.openpty()
    set_winsize(master, 24, 80)

    def _acquire_controlling_tty() -> None:
        # Runs in the child after fork, before exec. stdin/stdout/stderr are the
        # slave PTY (fd 0); become a session leader and claim it as our ctty so
        # SIGWINCH is delivered here on master-side TIOCSWINSZ.
        os.setsid()
        fcntl.ioctl(0, termios.TIOCSCTTY, 0)

    try:
        proc = await asyncio.create_subprocess_exec(
            "docker", "exec", "-i", "-t",
            "-e", "TERM=xterm-256color",
            container, *cmd,
            stdin=slave, stdout=slave, stderr=slave, close_fds=True,
            preexec_fn=_acquire_controlling_tty,
        )
    finally:
        os.close(slave)
    return proc, master


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
