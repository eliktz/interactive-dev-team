"""warroom2.meta_api — expose THIS squad's identity for the header label.

Read-only, fail-soft. Returns the squad slug and a human display name, both
resolved via the shared ``settings`` helpers (``squad_slug`` /
``company_display_name``) so the parsing/title-casing lives in one place. Never
500s: when the slug is underivable it returns empty strings and the frontend
keeps its static "WAR ROOM 2.0" header.
"""

from __future__ import annotations

import logging
from typing import Dict

from fastapi import APIRouter, Depends

from .auth import basic_auth_dependency
from .settings import settings

log = logging.getLogger(__name__)

router = APIRouter()


@router.get("/api/meta")
async def get_meta(_user: str = Depends(basic_auth_dependency)) -> Dict:
    return {
        "slug": settings.squad_slug,
        "company": settings.company_display_name,
    }
