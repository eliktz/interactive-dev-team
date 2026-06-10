"""warroom2.files_api — read-only file browser.

Whitelisted roots only:
- ``/workspace/agents``
- ``/workspace/project``
- ``/workspace/agent-bus``

Reject anything else with 400. Reject symlink escapes via real-path check.
Files >200 KB are truncated with a marker. ``.env``, ``access.json``, and any
line that contains ``TOKEN`` / ``SECRET`` / ``PASSWORD`` / ``API_KEY`` are
redacted.
"""

from __future__ import annotations

import logging
import os
import re
from typing import Dict, List, Optional

from fastapi import APIRouter, Depends, HTTPException, Query, status

from .auth import basic_auth_dependency

log = logging.getLogger(__name__)

router = APIRouter()

ALLOWED_ROOTS = (
    "/workspace/agents",
    "/workspace/project",
    "/workspace/agent-bus",
)

MAX_BYTES = 200 * 1024


def _resolve_under_root(path: str) -> Optional[str]:
    """Return the canonical absolute path if it lies under an allowed root."""
    try:
        real = os.path.realpath(path)
    except OSError:
        return None
    for root in ALLOWED_ROOTS:
        real_root = os.path.realpath(root)
        if real == real_root or real.startswith(real_root + os.sep):
            return real
    return None


@router.get("/api/files/tree")
async def files_tree(
    root: str = Query(...),
    _user: str = Depends(basic_auth_dependency),
) -> Dict:
    resolved = _resolve_under_root(root)
    if resolved is None:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="root not allowed",
        )
    if not os.path.isdir(resolved):
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND, detail="root not a directory"
        )

    entries: List[Dict] = []
    try:
        with os.scandir(resolved) as it:
            for entry in it:
                if entry.name.startswith(".git"):
                    continue
                try:
                    stat = entry.stat(follow_symlinks=False)
                except OSError:
                    continue
                entries.append(
                    {
                        "name": entry.name,
                        "path": os.path.join(resolved, entry.name),
                        "is_dir": entry.is_dir(follow_symlinks=False),
                        "is_symlink": entry.is_symlink(),
                        "size": stat.st_size if entry.is_file(follow_symlinks=False) else None,
                        "mtime": stat.st_mtime,
                    }
                )
    except OSError as e:
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR, detail=str(e)
        )

    entries.sort(key=lambda e: (not e["is_dir"], e["name"].lower()))
    return {"root": resolved, "entries": entries}


_REDACT_NAMES = ("access.json",)
_REDACT_LINE_RE = re.compile(
    r"(?i)(token|secret|password|api[_-]?key|bot[_-]?token)"
)


def _redact_value(val: str) -> str:
    n = len(val)
    prefix = val[:4] if n >= 4 else val
    return f"████ (len={n}, prefix={prefix!r})"


def _redact_text(text: str) -> str:
    out = []
    for line in text.splitlines(keepends=True):
        if _REDACT_LINE_RE.search(line):
            # KEY=VALUE style; redact RHS only.
            m = re.match(r"^(\s*[^=]+=)(.*?)(\r?\n?)$", line)
            if m:
                key, val, eol = m.group(1), m.group(2), m.group(3)
                out.append(key + _redact_value(val) + eol)
                continue
            # "key": "value" json-style; coarse mask.
            m = re.match(r'^(\s*"[^"]+"\s*:\s*")([^"]*)("\s*,?\s*\r?\n?)$', line)
            if m:
                out.append(m.group(1) + _redact_value(m.group(2)) + m.group(3))
                continue
            out.append(line)  # no obvious value; leave as-is
        else:
            out.append(line)
    return "".join(out)


def _should_redact(real_path: str) -> bool:
    base = os.path.basename(real_path)
    if base in _REDACT_NAMES:
        return True
    return base == ".env"


@router.get("/api/files/content")
async def files_content(
    path: str = Query(...),
    _user: str = Depends(basic_auth_dependency),
) -> Dict:
    resolved = _resolve_under_root(path)
    if resolved is None:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="path not allowed",
        )
    if not os.path.isfile(resolved):
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND, detail="not a file"
        )

    try:
        size = os.path.getsize(resolved)
        with open(resolved, "rb") as f:
            raw = f.read(MAX_BYTES)
        truncated = size > MAX_BYTES
    except OSError as e:
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR, detail=str(e)
        )

    text = raw.decode("utf-8", errors="replace")
    redacted = False
    if _should_redact(resolved):
        text = _redact_text(text)
        redacted = True
    else:
        # Even non-redact files get line-by-line token redaction (cheap).
        if _REDACT_LINE_RE.search(text):
            text = _redact_text(text)
            redacted = True

    return {
        "path": resolved,
        "size": size,
        "truncated": truncated,
        "redacted": redacted,
        "content": text,
    }
