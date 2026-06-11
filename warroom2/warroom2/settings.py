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
