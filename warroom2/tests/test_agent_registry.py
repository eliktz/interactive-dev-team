"""warroom2.tests.test_agent_registry — fail-loud roster, no default fallback.

The registry must NEVER invent agents: a missing or invalid agents.json
yields an EMPTY roster plus a surfaced error — not a hardcoded squad.
Runs without docker; the squad home is pointed at a pytest tmp dir.
"""

import json

from warroom2 import agent_registry


def _point_squad_home(monkeypatch, tmp_path):
    monkeypatch.setenv("WARROOM2_SQUAD_HOME", str(tmp_path))
    monkeypatch.delenv("WARROOM2_REPO_ROOT", raising=False)


def _write_roster(tmp_path, doc):
    config_dir = tmp_path / "config"
    config_dir.mkdir(parents=True, exist_ok=True)
    path = config_dir / "agents.json"
    path.write_text(json.dumps(doc), encoding="utf-8")
    return path


_VALID_DOC = {
    "version": 1,
    "agents": [
        {
            "id": "captain",
            "name": "Captain",
            "label": "Captain",
            "attach": "tmux",
            "window": 1,
            "persona_dir": "captain",
            "model_default": "sonnet",
            "color": "#7fd3ff",
        },
    ],
}


def test_list_agents_empty_when_agents_json_absent(tmp_path, monkeypatch):
    _point_squad_home(monkeypatch, tmp_path)
    assert agent_registry.list_agents() == []
    # The failure is surfaced, not swallowed: the API layer turns this into
    # a UI banner.
    assert agent_registry.roster_error()
    assert "not found" in agent_registry.roster_error()


def test_list_agents_empty_when_agents_json_invalid(tmp_path, monkeypatch):
    _point_squad_home(monkeypatch, tmp_path)
    _write_roster(tmp_path, {"version": 99, "agents": "nope"})
    assert agent_registry.list_agents() == []
    assert agent_registry.roster_error()
    assert "invalid" in agent_registry.roster_error()


def test_list_agents_parses_valid_roster(tmp_path, monkeypatch):
    _point_squad_home(monkeypatch, tmp_path)
    monkeypatch.setenv("WARROOM2_WARROOM_CONTAINER", "acme-war-room-1")
    _write_roster(tmp_path, _VALID_DOC)
    agents = agent_registry.list_agents()
    assert [a.id for a in agents] == ["captain"]
    assert agents[0].tmux_target == "war-room:1"
    # Container is squad-scoped via env — never a baked-in name.
    assert agents[0].container == "acme-war-room-1"
    assert agent_registry.roster_error() is None


def test_container_empty_when_env_unset(tmp_path, monkeypatch):
    _point_squad_home(monkeypatch, tmp_path)
    monkeypatch.delenv("WARROOM2_WARROOM_CONTAINER", raising=False)
    _write_roster(tmp_path, _VALID_DOC)
    agents = agent_registry.list_agents()
    assert agents[0].container == ""  # fail-loud at exec time, no fallback


def test_legacy_repo_root_env_still_honored(tmp_path, monkeypatch):
    monkeypatch.delenv("WARROOM2_SQUAD_HOME", raising=False)
    monkeypatch.setenv("WARROOM2_REPO_ROOT", str(tmp_path))
    _write_roster(tmp_path, _VALID_DOC)
    assert [a.id for a in agent_registry.list_agents()] == ["captain"]


def test_default_roster_is_gone():
    # M2 deleted the hardcoded fallback roster and its compat alias.
    assert not hasattr(agent_registry, "DEFAULT_AGENTS")
    assert not hasattr(agent_registry, "AGENTS")
