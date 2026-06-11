"""warroom2.agent_registry — dynamic agent roster backed by config/agents.json.

Source of truth is ``$WARROOM2_SQUAD_HOME/config/agents.json`` (schema
version 1; the legacy ``WARROOM2_REPO_ROOT`` env name is honored as a
fallback). The file is mtime-cached: every :func:`list_agents` call re-stats
the file and re-parses only when the mtime (or path) changes.

FAIL-LOUD: there is NO built-in default roster. When agents.json is missing
or invalid the registry returns an EMPTY roster, logs an error (once per
offending mtime) and exposes the failure via :func:`roster_error` so the API
layer can surface it as a UI banner. A squad's roster is data — seeded by
squadctl / the admin wizard into the squad's own config — never code.

Window mapping: one agent per tmux *window* (base-index 1) inside the
squad's war-room container; ``window`` in agents.json maps to
``<WARROOM2_TMUX_SESSION>:<window>``. Agents with ``attach="bus"`` are not
tmux windows — their tab is a chat-style feed over the agent bus
(``/workspace/agent-bus/messages.ndjson``).

Model resolution note: per-agent ``model_env`` overrides live in the
*war-room* container's environment, which the warroom2 container cannot see.
``Agent.model`` therefore always displays ``model_default`` from agents.json;
the authoritative resolution happens in launch.sh inside the war-room
container.
"""

from __future__ import annotations

import json
import logging
import os
import re
import threading
from dataclasses import dataclass
from typing import Any, Dict, List, Optional

log = logging.getLogger(__name__)

_ID_RE = re.compile(r"^[a-z][a-z0-9-]{2,30}$")
_MISSING = "<missing>"  # error-once sentinel used when agents.json is absent


@dataclass(frozen=True)
class Agent:
    id: str
    name: str
    model: str
    attach: str  # "tmux" | "bus"
    tmux_target: Optional[str]
    container: str
    persona_path: str
    color: str


def _config_path() -> str:
    """agents.json path under the squad home (same env pattern as settings)."""
    root = (
        os.environ.get("WARROOM2_SQUAD_HOME")
        or os.environ.get("WARROOM2_REPO_ROOT")
        or "/workspace/interactive-dev-team"
    )
    return root + "/config/agents.json"


def _parse_agent(entry: Dict[str, Any]) -> Agent:
    """Convert one agents.json entry into an Agent. Raises on bad shape."""
    agent_id = entry["id"]
    # fullmatch, NOT match: Python's '$' matches before a string-final
    # newline, so .match() would accept ids like "nora\n" that launch.sh's
    # roster parser rejects — the two readers must agree on validity.
    if not isinstance(agent_id, str) or not _ID_RE.fullmatch(agent_id):
        raise ValueError(f"invalid agent id: {agent_id!r}")
    attach = entry["attach"]
    if attach not in ("tmux", "bus"):
        raise ValueError(f"agent {agent_id!r}: invalid attach {attach!r}")
    name = entry["name"]
    color = entry["color"]
    if not isinstance(name, str) or not isinstance(color, str):
        raise ValueError(f"agent {agent_id!r}: name/color must be strings")

    if attach == "tmux":
        window = entry["window"]
        if not isinstance(window, int) or isinstance(window, bool):
            raise ValueError(f"agent {agent_id!r}: window must be an int")
        session = os.environ.get("WARROOM2_TMUX_SESSION", "war-room")
        tmux_target: Optional[str] = f"{session}:{window}"
        # Squad-scoped exec target; EMPTY when unconfigured (fail-loud at
        # exec time) — never a baked-in container name.
        container = os.environ.get("WARROOM2_WARROOM_CONTAINER", "")
        # model_env (e.g. CAPTAIN_MODEL) lives in the war-room container's
        # env, invisible from warroom2 — display model_default only.
        model = entry["model_default"]
    else:
        tmux_target = None
        container = os.environ.get("WARROOM2_OPENCLAW_CONTAINER", "")
        model = entry.get("model_default") or entry.get("model") or ""

    # persona_path derives from persona_dir; an explicit "persona_path" key
    # overrides it (for bus agents whose AGENTS.md lives outside
    # /workspace/agents).
    persona_path = entry.get("persona_path") or (
        f"/workspace/agents/{entry['persona_dir']}/AGENTS.md"
    )
    return Agent(
        id=agent_id,
        name=name,
        model=model,
        attach=attach,
        tmux_target=tmux_target,
        container=container,
        persona_path=persona_path,
        color=color,
    )


def _parse_file(path: str) -> List[Agent]:
    """Parse + validate agents.json. Raises on any structural problem."""
    with open(path, "r", encoding="utf-8") as fh:
        doc = json.load(fh)
    if not isinstance(doc, dict) or doc.get("version") != 1:
        raise ValueError("expected top-level object with version == 1")
    raw = doc.get("agents")
    if not isinstance(raw, list) or not raw:
        raise ValueError("'agents' must be a non-empty list")
    agents = [_parse_agent(e) for e in raw]
    ids = [a.id for a in agents]
    if len(set(ids)) != len(ids):
        raise ValueError("duplicate agent ids")
    return agents


# mtime cache state (guarded by _lock; uvicorn is async single-proc but the
# lock keeps us safe under any threaded executor usage).
_lock = threading.Lock()
_cached_path: Optional[str] = None
_cached_mtime_ns: Optional[int] = None
_cached_agents: List[Agent] = []
_errored_key: Optional[object] = None  # last mtime (or _MISSING) we logged for
_roster_error: Optional[str] = None  # last load failure; see roster_error()


def list_agents() -> List[Agent]:
    """Live roster from agents.json; EMPTY roster on a missing/invalid file.

    Re-stats the file on every call; re-parses only when mtime changes.
    Failures are logged and exposed via :func:`roster_error` — there is
    deliberately no hardcoded fallback roster.
    """
    global _cached_path, _cached_mtime_ns, _cached_agents
    global _errored_key, _roster_error
    path = _config_path()
    with _lock:
        try:
            mtime_ns = os.stat(path).st_mtime_ns
        except OSError:
            _roster_error = f"agents.json not found at {path}"
            if _errored_key != _MISSING:
                log.error("%s; serving an EMPTY roster", _roster_error)
                _errored_key = _MISSING
            _cached_path, _cached_mtime_ns = None, None
            _cached_agents = []
            return []

        if path == _cached_path and mtime_ns == _cached_mtime_ns:
            return list(_cached_agents)

        try:
            agents = _parse_file(path)
            _roster_error = None
            _errored_key = None
        except (OSError, ValueError, KeyError, TypeError) as exc:
            _roster_error = f"agents.json at {path} invalid ({exc})"
            if _errored_key != mtime_ns:
                log.error("%s; serving an EMPTY roster", _roster_error)
                _errored_key = mtime_ns
            agents = []
        _cached_path, _cached_mtime_ns = path, mtime_ns
        _cached_agents = agents
        return list(_cached_agents)


def roster_error() -> Optional[str]:
    """Last roster-load failure message (None when the roster parsed cleanly).

    Surfaced by ``GET /api/agents`` so the UI can render a banner instead of
    an unexplained empty tab bar.
    """
    with _lock:
        return _roster_error


def get_agent(agent_id: str) -> Optional[Agent]:
    for agent in list_agents():
        if agent.id == agent_id:
            return agent
    return None
