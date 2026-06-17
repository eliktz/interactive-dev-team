"""warroom2.settings — env-driven configuration.

Read once at import time; consumers import the module-level ``settings``
singleton. The only required env vars in production are
``WARROOM2_BASIC_AUTH_USER`` and ``WARROOM2_BASIC_AUTH_PASS``; path defaults
match the container mount points from the compose template.

Tenant-neutral by design: anything squad-specific has NO baked-in fallback.
Container exec targets default EMPTY (fail-loud at the point of use) — the
compose template derives them from ``COMPOSE_PROJECT_NAME``, so a dashboard
can never silently target another squad's containers. The squad instance dir
arrives via ``WARROOM2_SQUAD_HOME`` (the legacy ``WARROOM2_REPO_ROOT`` name
is honored as a fallback for older deployments).
"""

from __future__ import annotations

import os
from dataclasses import dataclass
from typing import Optional


@dataclass(frozen=True)
class Settings:
    basic_auth_user: str = ""
    basic_auth_pass: str = ""
    bus_path: str = "/workspace/agent-bus/messages.ndjson"
    # Squad-scoped docker exec targets — EMPTY defaults are deliberate:
    # missing config must fail loud, never fall back to some other squad.
    warroom_container: str = ""
    openclaw_container: str = ""
    tmux_session: str = "war-room"
    state_db_path: str = "/var/lib/warroom2/state.db"
    admin_token: str = ""
    # Container mount point of the squad instance dir (${SQUAD_HOME} on the
    # host): config/agents.json, agents/*, private/agent-tokens.env.
    squad_home: str = "/workspace/interactive-dev-team"
    # Read-only file-browser roots (container mount points).
    agents_root: str = "/workspace/agents"
    project_root: str = "/workspace/project"

    @property
    def auth_enabled(self) -> bool:
        return bool(self.basic_auth_user) and bool(self.basic_auth_pass)

    @property
    def squad_slug(self) -> str:
        """Best-effort squad slug for THIS dashboard.

        Derived from ``warroom_container`` (``<COMPOSE_PROJECT_NAME>-war-room-1``
        per the compose template), stripping the ``-war-room-N`` suffix. Shared
        helper so other endpoints (e.g. ``/api/meta``) resolve the squad the same
        way instead of re-parsing the container name. Empty when unconfigured.
        """
        name = self.warroom_container
        if not name:
            return ""
        marker = "-war-room"
        idx = name.rfind(marker)
        return name[:idx] if idx > 0 else name

    @property
    def company_display_name(self) -> str:
        """Human display name for THIS squad's company.

        ``WARROOM2_COMPANY_NAME`` override when set; otherwise a title-cased
        version of :attr:`squad_slug` (``go-north`` -> ``Go North``), mirroring
        squadctl's ``display_name_for``. Empty when the slug is underivable
        (fail-soft — the header label is cosmetic). Shared helper so routes
        don't re-implement the title-casing.
        """
        override = os.environ.get("WARROOM2_COMPANY_NAME", "").strip()
        if override:
            return override
        slug = self.squad_slug
        if not slug:
            return ""
        return slug.replace("-", " ").replace("_", " ").title()

    def company_dir(self) -> Optional[str]:
        """Absolute path to THIS squad's company package dir, or None.

        Resolution (fail-soft, never cross-squad):
        1. ``{squad_home}/companies/<squad_slug>`` — exact slug match.
        2. If that misses (e.g. compose project ``gonorth`` vs company dir
           ``go-north``) and there is exactly ONE company package under
           ``companies/``, use it — a single-company squad is unambiguous.
        Returns None when nothing resolves.
        """
        base = os.path.join(self.squad_home, "companies")
        if not os.path.isdir(base):
            return None
        slug = self.squad_slug
        if slug:
            cand = os.path.join(base, slug)
            if os.path.isfile(os.path.join(cand, "COMPANY.md")):
                return cand
        dirs = [
            os.path.join(base, e)
            for e in os.listdir(base)
            if os.path.isfile(os.path.join(base, e, "COMPANY.md"))
        ]
        if len(dirs) == 1:
            return dirs[0]
        return None


def _squad_home_env() -> str:
    """``WARROOM2_SQUAD_HOME`` with legacy ``WARROOM2_REPO_ROOT`` fallback."""
    return (
        os.environ.get("WARROOM2_SQUAD_HOME")
        or os.environ.get("WARROOM2_REPO_ROOT")
        or "/workspace/interactive-dev-team"
    )


def _load() -> Settings:
    return Settings(
        basic_auth_user=os.environ.get("WARROOM2_BASIC_AUTH_USER", ""),
        basic_auth_pass=os.environ.get("WARROOM2_BASIC_AUTH_PASS", ""),
        bus_path=os.environ.get(
            "WARROOM2_BUS_PATH", "/workspace/agent-bus/messages.ndjson"
        ),
        warroom_container=os.environ.get("WARROOM2_WARROOM_CONTAINER", ""),
        openclaw_container=os.environ.get("WARROOM2_OPENCLAW_CONTAINER", ""),
        tmux_session=os.environ.get("WARROOM2_TMUX_SESSION", "war-room"),
        state_db_path=os.environ.get(
            "WARROOM2_STATE_DB", "/var/lib/warroom2/state.db"
        ),
        admin_token=os.environ.get("WARROOM2_ADMIN_TOKEN", ""),
        squad_home=_squad_home_env(),
        agents_root=os.environ.get("WARROOM2_AGENTS_ROOT", "/workspace/agents"),
        project_root=os.environ.get(
            "WARROOM2_PROJECT_ROOT", "/workspace/project"
        ),
    )


settings: Settings = _load()
