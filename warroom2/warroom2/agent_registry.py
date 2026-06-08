"""warroom2.agent_registry — hardcoded 4-agent list.

Pane mapping verified via Phase 3f pre-flight (output.json
``tmuxPaneVerificationFinding=CONFIRMED``):

- ``war-room:1.1`` → Captain   (cwd ``/workspace/agents/captain``)
- ``war-room:1.2`` → Leo       (cwd ``/workspace/agents/leo``; pane title is
  the stale ``CEO Yefet (opus)`` — disregard, identity is Leo)
- ``war-room:1.3`` → Iris      (cwd ``/workspace/agents/ux-gonorth``)

Yefet (``attach="bus"``) is intentionally NOT a tmux pane in v1. Per the spec
in 3b-backend.md, Yefet's tab is a chat-style feed over
``/workspace/agent-bus/messages.ndjson``.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import List, Optional


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


AGENTS: List[Agent] = [
    Agent(
        id="captain",
        name="Captain",
        model="sonnet",
        attach="tmux",
        tmux_target="war-room:1.1",
        container="interactive-dev-team-war-room-1",
        persona_path="/workspace/agents/captain/AGENTS.md",
        color="#7fd3ff",
    ),
    Agent(
        id="leo",
        name="Leo",
        model="opus",
        attach="tmux",
        tmux_target="war-room:1.2",
        container="interactive-dev-team-war-room-1",
        persona_path="/workspace/agents/leo/AGENTS.md",
        color="#ffa657",
    ),
    Agent(
        id="iris",
        name="Iris (Hedva)",
        model="sonnet",
        attach="tmux",
        tmux_target="war-room:1.3",
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

_BY_ID = {a.id: a for a in AGENTS}


def list_agents() -> List[Agent]:
    return list(AGENTS)


def get_agent(agent_id: str) -> Optional[Agent]:
    return _BY_ID.get(agent_id)
