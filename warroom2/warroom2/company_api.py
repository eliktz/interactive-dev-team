"""warroom2.company_api — expose THIS squad's COMPANY.md.

Read-only. Resolves the squad's company package via the shared
``settings.company_dir()`` helper (same slug logic other endpoints reuse, never
cross-squad), reads its ``COMPANY.md``, and applies the same cheap line-by-line
token redaction the file browser uses. Fail-soft: 404 with an empty body when no
company package resolves.
"""

from __future__ import annotations

import logging
import os
from typing import Dict

from fastapi import APIRouter, Depends, HTTPException, status

from .auth import basic_auth_dependency
from .files_api import _REDACT_LINE_RE, _redact_text
from .settings import settings

log = logging.getLogger(__name__)

router = APIRouter()

MAX_BYTES = 200 * 1024


@router.get("/api/company")
async def get_company(_user: str = Depends(basic_auth_dependency)) -> Dict:
    company_dir = settings.company_dir()
    if not company_dir:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="no company package for this squad",
        )

    path = os.path.join(company_dir, "COMPANY.md")
    if not os.path.isfile(path):
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND, detail="COMPANY.md not found"
        )

    try:
        size = os.path.getsize(path)
        with open(path, "rb") as f:
            raw = f.read(MAX_BYTES)
        truncated = size > MAX_BYTES
    except OSError as e:
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR, detail=str(e)
        )

    text = raw.decode("utf-8", errors="replace")
    redacted = False
    # COMPANY.md is meant to be secret-free, but redact defensively (cheap) so a
    # mistaken token paste never surfaces in the dashboard.
    if _REDACT_LINE_RE.search(text):
        text = _redact_text(text)
        redacted = True

    return {
        "slug": settings.squad_slug,
        "path": path,
        "size": size,
        "truncated": truncated,
        "redacted": redacted,
        "content": text,
    }
