"""warroom2.agent_registry — dynamic agent roster backed by config/agents.json.

Source of truth is ``$WARROOM2_REPO_ROOT/config/agents.json`` (schema
version 1). The file is mtime-cached: every :func:`list_agents` call re-stats
the file and re-parses only when the mtime (or path) changes. On a missing or
invalid file the registry falls back to :data:`DEFAULT_AGENTS` — the
previously hardcoded roster — and logs a warning once per offending mtime.

Window mapping verified against the live war-room tmux session (base-index 1,
one agent per *window*, not panes):

- ``war-room:1`` → Captain  (cwd ``/workspace/agents/captain``)
- ``war-room:2`` → Leo      (cwd ``/workspace/agents/ceo-gonorth`` — the
  legacy persona dir name; the window title may still show the stale
  ``CEO Yefet (opus)`` — disregard, identity is Leo)
- ``war-room:3`` → Iris     (cwd ``/workspace/agents/ux-gonorth``)

Yefet (``attach="bus"``) is intentionally NOT a tmux window in v1. Per the
spec in 3b-backend.md, Yefet's tab is a chat-style feed over
``/workspace/agent-bus/messages.ndjson``.

Model resolution note: per-agent ``model_env`` overrides (CAPTAIN_MODEL,
CEO_MODEL, UX_MODEL, ...) live in the *war-room* container's environment,
which the warroom2 container cannot see. ``Agent.model`` therefore always
displays ``model_default`` from agents.json; the authoritative resolution
happens in launch.sh inside the war-room container.

Compatibility: the module-level :data:`AGENTS` name is kept as an alias for
:data:`DEFAULT_AGENTS` so stale ``from .agent_registry import AGENTS``
imports still resolve, but it is frozen at the fallback roster — ALL
consumers must go through :func:`list_agents` to see dynamic entries.
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
_MISSING = "<missing>"  # warn-once sentinel used when agents.json is absent


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


# Fallback roster — mirrors the live deployment as of 2026-06. Used whenever
# config/agents.json is missing or fails validation. NOTE: leo's persona dir
# is the legacy ``ceo-gonorth`` (the running war-room:2 cwd), not ``leo``.
DEFAULT_AGENTS: List[Agent] = [
    Agent(
        id="captain",
        name="Captain",
        model="sonnet",
        attach="tmux",
        tmux_target="war-room:1",
        container="interactive-dev-team-war-room-1",
        persona_path="/workspace/agents/captain/AGENTS.md",
        color="#7fd3ff",
    ),
    Agent(
        id="leo",
        name="Leo",
        model="opus",
        attach="tmux",
        tmux_target="war-room:2",
        container="interactive-dev-team-war-room-1",
        persona_path="/workspace/agents/ceo-gonorth/AGENTS.md",
        color="#ffa657",
    ),
    Agent(
        id="iris",
        name="Iris (Hedva)",
        model="sonnet",
        attach="tmux",
        tmux_target="war-room:3",
        container="interactive-dev-team-war-room-1",
        persona_path="/workspace/agents/ux-gonorth/AGENTS.md",
        color="#d2a8ff",
    ),
    Agent(
        id="yefet",
        name="Yefet",
        model="gpt-5.5",
        attach="bus",
        tmux_target=None,
        container="interactive-dev-team-openclaw-1",
        persona_path="/home/node/.openclaw/workspace-gonorth/AGENTS.md",
        color="#7ee787",
    ),
]

# Backwards-compat alias: stale imports (e.g. wizard_api's
# ``from .agent_registry import AGENTS``) keep resolving, but this is the
# static fallback only. Use list_agents() for the live roster.
AGENTS: List[Agent] = DEFAULT_AGENTS


def _config_path() -> str:
    """agents.json path under the repo root (same env pattern as settings)."""
    root = os.environ.get("WARROOM2_REPO_ROOT", "/workspace/interactive-dev-team")
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
        container = os.environ.get(
            "WARROOM2_WARROOM_CONTAINER", "interactive-dev-team-war-room-1"
        )
        # model_env (e.g. CAPTAIN_MODEL) lives in the war-room container's
        # env, invisible from warroom2 — display model_default only.
        model = entry["model_default"]
    else:
        tmux_target = None
        container = os.environ.get(
            "WARROOM2_OPENCLAW_CONTAINER", "interactive-dev-team-openclaw-1"
        )
        model = entry.get("model_default") or entry.get("model") or ""

    # persona_path derives from persona_dir; an explicit "persona_path" key
    # overrides it (needed for yefet, whose AGENTS.md lives outside
    # /workspace/agents — see DEFAULT_AGENTS).
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
_cached_agents: List[Agent] = DEFAULT_AGENTS
_warned_key: Optional[object] = None  # last mtime (or _MISSING) we warned for


def list_agents() -> List[Agent]:
    """Live roster from agents.json; DEFAULT_AGENTS on missing/invalid file.

    Re-stats the file on every call; re-parses only when mtime changes.
    """
    global _cached_path, _cached_mtime_ns, _cached_agents, _warned_key
    path = _config_path()
    with _lock:
        try:
            mtime_ns = os.stat(path).st_mtime_ns
        except OSError:
            if _warned_key != _MISSING:
                log.warning(
                    "agents.json not found at %s; using DEFAULT_AGENTS", path
                )
                _warned_key = _MISSING
            _cached_path, _cached_mtime_ns = None, None
            _cached_agents = DEFAULT_AGENTS
            return list(_cached_agents)

        if path == _cached_path and mtime_ns == _cached_mtime_ns:
            return list(_cached_agents)

        try:
            agents = _parse_file(path)
        except (OSError, ValueError, KeyError, TypeError) as exc:
            if _warned_key != mtime_ns:
                log.warning(
                    "agents.json at %s invalid (%s); using DEFAULT_AGENTS",
                    path,
                    exc,
                )
                _warned_key = mtime_ns
            agents = DEFAULT_AGENTS
        _cached_path, _cached_mtime_ns = path, mtime_ns
        _cached_agents = agents
        return list(_cached_agents)


def get_agent(agent_id: str) -> Optional[Agent]:
    for agent in list_agents():
        if agent.id == agent_id:
            return agent
    return None
