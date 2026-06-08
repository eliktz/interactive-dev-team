"""warroom2.settings — env-driven configuration.

Read once at import time; consumers import the module-level ``settings`` singleton.
Per plan §4.1 / §11 the only required env vars in production are
``WARROOM2_BASIC_AUTH_USER`` and ``WARROOM2_BASIC_AUTH_PASS``; everything else
has a sensible default that matches the VM bind-mount and compose layout.
"""

from __future__ import annotations

import os
from dataclasses import dataclass


@dataclass(frozen=True)
class Settings:
    basic_auth_user: str = ""
    basic_auth_pass: str = ""
    bus_path: str = "/workspace/agent-bus/messages.ndjson"
    warroom_container: str = "interactive-dev-team-war-room-1"
    openclaw_container: str = "interactive-dev-team-openclaw-1"
    tmux_session: str = "war-room"
    state_db_path: str = "/var/lib/warroom2/state.db"

    @property
    def auth_enabled(self) -> bool:
        return bool(self.basic_auth_user) and bool(self.basic_auth_pass)


def _load() -> Settings:
    return Settings(
        basic_auth_user=os.environ.get("WARROOM2_BASIC_AUTH_USER", ""),
        basic_auth_pass=os.environ.get("WARROOM2_BASIC_AUTH_PASS", ""),
        bus_path=os.environ.get(
            "WARROOM2_BUS_PATH", "/workspace/agent-bus/messages.ndjson"
        ),
        warroom_container=os.environ.get(
            "WARROOM2_WARROOM_CONTAINER", "interactive-dev-team-war-room-1"
        ),
        openclaw_container=os.environ.get(
            "WARROOM2_OPENCLAW_CONTAINER", "interactive-dev-team-openclaw-1"
        ),
        tmux_session=os.environ.get("WARROOM2_TMUX_SESSION", "war-room"),
        state_db_path=os.environ.get(
            "WARROOM2_STATE_DB", "/var/lib/warroom2/state.db"
        ),
    )


settings: Settings = _load()
