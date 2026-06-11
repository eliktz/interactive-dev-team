"""warroom2.tests.test_tmux_bridge — PTY session wiring (docker exec mocked).

Verifies the SessionManager contract and that exec targets come from the
Agent (squad-scoped data), with docker_client monkeypatched — no docker
daemon required.
"""

import asyncio
import re

import pytest

from warroom2 import docker_client, tmux_bridge
from warroom2.agent_registry import Agent


def _agent(**overrides):
    base = dict(
        id="captain",
        name="Captain",
        model="sonnet",
        attach="tmux",
        tmux_target="war-room:1",
        container="acme-war-room-1",
        persona_path="/workspace/agents/captain/AGENTS.md",
        color="#7fd3ff",
    )
    base.update(overrides)
    return Agent(**base)


def test_manager_returns_fresh_session_per_call():
    agent = _agent()
    s1 = tmux_bridge.manager.get(agent)
    s2 = tmux_bridge.manager.get(agent)
    assert isinstance(s1, tmux_bridge.TmuxPtySession)
    # Per-WebSocket sessions, never cached (Phase B contract).
    assert s1 is not s2


def test_non_tmux_agent_rejected():
    bus_agent = _agent(attach="bus", tmux_target=None)
    with pytest.raises(ValueError):
        tmux_bridge.TmuxPtySession(bus_agent)


def test_attach_execs_into_agents_container(monkeypatch):
    calls = {}

    async def fake_exec_pty(container, *argv):
        calls["container"] = container
        calls["argv"] = argv
        return None, None  # (proc, master) placeholders

    monkeypatch.setattr(docker_client, "exec_pty", fake_exec_pty)
    session = tmux_bridge.TmuxPtySession(_agent())
    asyncio.run(session.attach())
    # Exec target is the Agent's squad-scoped container — data, not code.
    assert calls["container"] == "acme-war-room-1"
    script = " ".join(calls["argv"])
    # Grouped-session attach: linked session off the base, window from
    # the agent's tmux_target ("war-room:1").
    assert "tmux new-session -d -t war-room " in script
    assert re.search(r"select-window -t \S+:1", script)
