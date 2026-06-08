"""warroom2.app — FastAPI app factory.

Wires:
- Static files at ``/static`` + ``GET /`` → ``static/index.html``.
- Routers: ``agents_api``, ``files_api``, ``event_relay``, ``ws_relay``.
- Startup: ensure ``/tmp/warroom2`` exists in the war-room container and
  pipe-pane is set up for each tmux agent (idempotent).
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

from .agent_registry import list_agents
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


async def _bootstrap_tmux_pipes() -> None:
    for agent in list_agents():
        if agent.attach != "tmux":
            continue
        try:
            sess = tmux_manager.get(agent)
            await sess.ensure_pipe()
            log.info("pipe-pane ready for %s (%s)", agent.id, agent.tmux_target)
        except Exception as e:
            log.warning("pipe-pane setup failed for %s: %s", agent.id, e)


@asynccontextmanager
async def _lifespan(app: FastAPI):
    log.info(
        "warroom2 starting; auth=%s, bus=%s, tmux=%s",
        "ON" if settings.auth_enabled else "OFF",
        settings.bus_path,
        settings.tmux_session,
    )
    await _bootstrap_tmux_pipes()
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
