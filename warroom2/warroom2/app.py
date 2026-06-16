"""warroom2.app — FastAPI app factory.

Wires:
- Static files at ``/static`` + ``GET /`` → ``static/index.html``.
- Routers: ``agents_api``, ``files_api``, ``event_relay``, ``ws_relay``.
- Startup: no per-agent pre-warm — PTY sessions are spawned per WebSocket
  on demand (Phase B).
- Settings singleton from ``settings.py``.
- No CORS (same-origin only).
"""

from __future__ import annotations

import logging
import os
from contextlib import asynccontextmanager

from fastapi import Depends, FastAPI, HTTPException
from fastapi.responses import FileResponse, JSONResponse
from fastapi.staticfiles import StaticFiles

from .agents_api import router as agents_router
from .auth import basic_auth_dependency
from .event_relay import router as events_router
from .files_api import router as files_router
from .settings import settings
from .tmux_bridge import manager as tmux_manager
from .wizard_api import router as wizard_router
from .ws_relay import router as ws_router

log = logging.getLogger(__name__)


def _resolve_static_dir() -> str:
    here = os.path.dirname(os.path.abspath(__file__))
    # warroom2/warroom2/app.py → ../static is the repo layout.
    candidate = os.path.normpath(os.path.join(here, "..", "static"))
    if os.path.isdir(candidate):
        return candidate
    # When deployed via Dockerfile, static/ lives at /app/static and this file
    # at /app/warroom2/app.py — same relative path. Falls through to here.
    return candidate


@asynccontextmanager
async def _lifespan(app: FastAPI):
    log.info(
        "warroom2 starting; auth=%s, bus=%s, tmux=%s",
        "ON" if settings.auth_enabled else "OFF",
        settings.bus_path,
        settings.tmux_session,
    )
    yield
    await tmux_manager.close_all()
    log.info("warroom2 stopped")


def create_app() -> FastAPI:
    logging.basicConfig(
        level=os.environ.get("WARROOM2_LOG_LEVEL", "INFO").upper(),
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )

    app = FastAPI(
        title="warroom2",
        version="0.0.1",
        lifespan=_lifespan,
        docs_url=None,
        redoc_url=None,
    )

    @app.middleware("http")
    async def _revalidate_frontend_assets(request, call_next):
        # The SPA shell and its JS/CSS must never be served stale. StaticFiles
        # sends ETag/Last-Modified but no Cache-Control, so browsers fall back to
        # heuristic caching and can keep an old wizard.js after a deploy. no-cache
        # forces revalidation every load; the existing ETag makes the unchanged
        # case a cheap 304.
        response = await call_next(request)
        if request.url.path == "/" or request.url.path.startswith("/static/"):
            response.headers["Cache-Control"] = "no-cache"
        return response

    static_dir = _resolve_static_dir()
    if os.path.isdir(static_dir):
        app.mount("/static", StaticFiles(directory=static_dir), name="static")
    else:
        log.warning("static dir not found at %s", static_dir)

    @app.get("/", include_in_schema=False)
    async def root(_user: str = Depends(basic_auth_dependency)):
        index = os.path.join(static_dir, "index.html")
        if not os.path.isfile(index):
            raise HTTPException(status_code=503, detail="frontend not built")
        return FileResponse(index)

    @app.get("/healthz", include_in_schema=False)
    async def healthz():
        return JSONResponse({"ok": True})

    app.include_router(agents_router)
    app.include_router(files_router)
    app.include_router(events_router)
    app.include_router(ws_router)
    app.include_router(wizard_router)

    return app
