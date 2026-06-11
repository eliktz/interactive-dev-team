"""warroom2.tests.test_wizard_api — the seed roster must be tenant-neutral.

SEED_AGENTS is used only when config/agents.json does not exist yet; it must
be a generic single-captain seed with nothing squad-specific baked in.
"""

import json

from warroom2.wizard_api import SEED_AGENTS, _token_env_name


def test_seed_agents_is_tenant_neutral():
    text = json.dumps(SEED_AGENTS).lower()
    assert "gonorth" not in text
    assert "interactive-dev-team-" not in text
    assert "openclaw" not in text


def test_seed_agents_is_single_captain():
    agents = SEED_AGENTS["agents"]
    assert len(agents) == 1
    captain = agents[0]
    assert captain["id"] == "captain"
    assert captain["attach"] == "tmux"
    assert captain["window"] == 1
    assert captain["persona_dir"] == "captain"


def test_seed_token_env_derived_from_slug():
    captain = SEED_AGENTS["agents"][0]
    assert captain["token_env"] == _token_env_name(captain["id"])
    assert captain["token_env"] == "CAPTAIN_TELEGRAM_TOKEN"
