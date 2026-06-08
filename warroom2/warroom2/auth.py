"""warroom2.auth — HTTP Basic auth gating.

v1 only. Per plan §11 every route hangs off ``basic_auth_dependency``; v2
swaps this single file for a Tailscale-header reader.
"""

from __future__ import annotations

import logging
import secrets
from typing import Optional

from fastapi import Depends, HTTPException, status
from fastapi.security import HTTPBasic, HTTPBasicCredentials

from .settings import settings

log = logging.getLogger(__name__)
security = HTTPBasic(auto_error=False)

_warned = False


def _warn_once_if_disabled() -> None:
    global _warned
    if _warned:
        return
    _warned = True
    if not settings.auth_enabled:
        log.warning(
            "WARROOM2 AUTH DISABLED — WARROOM2_BASIC_AUTH_USER/PASS empty. "
            "Every route is open. Do not run like this in production."
        )


def basic_auth_dependency(
    credentials: Optional[HTTPBasicCredentials] = Depends(security),
) -> str:
    """FastAPI dependency. Returns the authenticated username, or empty when
    auth is disabled. Raises 401 with ``WWW-Authenticate: Basic`` on mismatch.
    """
    _warn_once_if_disabled()

    if not settings.auth_enabled:
        return ""

    if credentials is None:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Missing credentials",
            headers={"WWW-Authenticate": 'Basic realm="warroom2"'},
        )

    user_ok = secrets.compare_digest(
        credentials.username.encode("utf-8"),
        settings.basic_auth_user.encode("utf-8"),
    )
    pass_ok = secrets.compare_digest(
        credentials.password.encode("utf-8"),
        settings.basic_auth_pass.encode("utf-8"),
    )
    if not (user_ok and pass_ok):
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid credentials",
            headers={"WWW-Authenticate": 'Basic realm="warroom2"'},
        )

    return credentials.username


async def ws_basic_auth(websocket) -> Optional[str]:
    """WebSocket-side auth check.

    Browsers replay the ``Authorization: Basic`` header on the WS upgrade once
    the page is auth'd, so we just inspect the header. Returns the username on
    success, ``""`` when auth is disabled, ``None`` when the caller should
    close the socket.
    """
    _warn_once_if_disabled()

    if not settings.auth_enabled:
        return ""

    header = websocket.headers.get("authorization") or ""
    if not header.lower().startswith("basic "):
        return None

    import base64

    try:
        raw = base64.b64decode(header.split(" ", 1)[1]).decode("utf-8")
        user, _, pw = raw.partition(":")
    except Exception:
        return None

    user_ok = secrets.compare_digest(
        user.encode("utf-8"), settings.basic_auth_user.encode("utf-8")
    )
    pass_ok = secrets.compare_digest(
        pw.encode("utf-8"), settings.basic_auth_pass.encode("utf-8")
    )
    return user if (user_ok and pass_ok) else None
