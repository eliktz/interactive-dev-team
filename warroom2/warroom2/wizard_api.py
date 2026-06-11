"""warroom2.wizard_api — admin "mount new agent" wizard backend.

4 endpoints under ``/api/admin/wizard/*``, all gated by:
- existing basic-auth dependency
- ``X-Admin-Token`` header matching ``settings.admin_token``

If ``settings.admin_token`` is empty, every wizard endpoint returns 503 with
``{"error": "admin token not configured"}``.

File mutations are atomic (write to ``.tmp`` then ``os.replace``) and create a
``.bak-<utc-iso>-<pid>-<seq>`` backup of the original (when present) before
any write (pid + monotonic seq make same-second backups collision-proof).

The wizard mutates files inside ``settings.squad_home`` — the squad instance
dir (``${SQUAD_HOME}`` on the host) mounted rw into warroom2.

Apply path (v2 — agents.json era):
- ``launch.sh`` is NEVER patched anymore. The canonical roster lives in
  ``config/agents.json`` (schema version 1); launch.sh and the warroom2
  registry both read it.
- A new agent = persona files (create) + an appended entry in
  ``config/agents.json`` (atomic full rewrite) + — only when a Telegram token
  was provided — an appended ``KEY=value`` line in
  ``private/agent-tokens.env`` (mode 0600, gitignored).
- Tokens are SECRETS: the raw value is never logged and never echoed back in
  any response. Previews show ``TOKEN REDACTED (N chars)``.
- Token is OPTIONAL: an empty token means a CLI-only agent — no ``token_env``
  in agents.json and no tokens-file write (launch.sh then omits
  ``--channels`` for that agent).
"""

from __future__ import annotations

import copy
import datetime as _dt
import itertools
import json
import logging
import os
import re
import shutil
import threading
from typing import Dict, List, NamedTuple, Optional, Tuple

import httpx
from fastapi import APIRouter, Depends, Header, HTTPException, Request, status
from pydantic import BaseModel, Field, field_validator

from .agent_registry import list_agents as _registry_list_agents
from .auth import basic_auth_dependency
from .settings import settings
from .templates import (
    ALLOWED_TOOLS,
    TEMPLATES,
    render_agents_md,
    render_soul_md,
    render_tools_md,
)

log = logging.getLogger(__name__)

# SECURITY: httpx logs every request at INFO on the "httpx" logger, including
# the FULL request URL. For /getme that URL embeds the raw bot token
# (api.telegram.org/bot<token>/getMe), and app.create_app() configures the
# root logger at INFO — without this, the token would land verbatim in the
# docker-captured log stream, violating the "raw value is never logged"
# guarantee above. Silence request-level records from httpx and httpcore.
logging.getLogger("httpx").setLevel(logging.WARNING)
logging.getLogger("httpcore").setLevel(logging.WARNING)

router = APIRouter(prefix="/api/admin/wizard")

# Serializes the agents.json read-modify-write inside apply() (plan reads the
# file, the write loop os.replace's it). Without this, two concurrent applies
# lose an entry or collide on _next_window. Today requests are ALSO serialized
# by accident — apply() is async with zero awaits between read and write, and
# __main__ runs uvicorn with a single worker — but do NOT rely on that
# invariant: keep this lock, and if uvicorn ever runs workers>1 (separate
# PROCESSES, which a threading.Lock cannot span) replace it with fcntl.flock
# on the agents.json fd.
_APPLY_LOCK = threading.Lock()

# Monotonic per-process counter for backup/tmp filename suffixes — two writes
# within the same wall-clock second previously produced IDENTICAL
# .bak-/.tmp- names (silent backup overwrite + O_EXCL FileExistsError).
_WRITE_SEQ = itertools.count()

ALLOWED_MODELS = ["sonnet", "opus", "haiku", "gpt-5.5"]
SLUG_RE = re.compile(r"^[a-z][a-z0-9-]{2,30}$")
COLOR_RE = re.compile(r"^#[0-9a-fA-F]{6}$")
TG_TOKEN_RE = re.compile(r"^\d+:[\w-]+$")
TG_ID_RE = re.compile(r"^-?\d+$")

AGENTS_JSON_VERSION = 1


def _token_env_name(slug: str) -> str:
    return f"{slug.upper().replace('-', '_')}_TELEGRAM_TOKEN"


def _model_env_name(slug: str) -> str:
    return f"{slug.upper().replace('-', '_')}_MODEL"


# Generic single-captain seed. Used ONLY when config/agents.json does not
# exist yet: the wizard then creates the file as seed + new agent so the
# roster is complete. Tenant-neutral by design — a squad's real roster is
# data in its own config/agents.json (scaffolded by squadctl), never code.
SEED_SLUG = "captain"

SEED_AGENTS: Dict = {
    "version": AGENTS_JSON_VERSION,
    "agents": [
        {
            "id": SEED_SLUG,
            "name": "Captain",
            "label": "Captain",
            "attach": "tmux",
            "window": 1,
            "persona_dir": SEED_SLUG,
            "model_env": _model_env_name(SEED_SLUG),
            "model_default": "sonnet",
            "token_env": _token_env_name(SEED_SLUG),
            "color": "#7fd3ff",
        },
    ],
}


# ---------- Pydantic models ----------


class TelegramSpec(BaseModel):
    token: str = ""
    group_id: str = ""
    operator_id: str = ""

    # Strip pasted whitespace/newlines BEFORE validation. Python's '$' regex
    # anchor matches before a string-final '\n', so without this a value like
    # "123:abc\n" used to pass the shape checks and then corrupt downstream
    # files (the regexes below now also use fullmatch — defense in depth).
    @field_validator("token", "group_id", "operator_id")
    @classmethod
    def _strip_ws(cls, v: str) -> str:
        return v.strip()


class PersonaSpec(BaseModel):
    template: str = "default"
    role: str = ""
    tools: List[str] = Field(default_factory=list)


class AgentSpec(BaseModel):
    slug: str
    display_name: str
    model: str
    color: str = "#7ee787"
    telegram: TelegramSpec = Field(default_factory=TelegramSpec)
    persona: PersonaSpec = Field(default_factory=PersonaSpec)

    # See TelegramSpec._strip_ws — a trailing "\n" on slug/color slipped past
    # the '$'-anchored regexes and produced a persona dir literally named
    # "agents/nora\n/" plus an agents.json id with an embedded newline that
    # made launch.sh's roster parser reject the WHOLE file (fallback roster =
    # every wizard agent silently gone from tmux).
    @field_validator("slug", "color")
    @classmethod
    def _strip_ws(cls, v: str) -> str:
        return v.strip()


class GetMeBody(BaseModel):
    token: str


class WizardBody(BaseModel):
    agent: AgentSpec


# ---------- Gate dependency ----------


def wizard_gate(
    request: Request,
    _user: str = Depends(basic_auth_dependency),
    x_admin_token: Optional[str] = Header(default=None, alias="X-Admin-Token"),
) -> str:
    if not settings.admin_token:
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="admin token not configured",
        )
    if not x_admin_token or x_admin_token != settings.admin_token:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="missing or invalid X-Admin-Token",
        )
    return "admin"


# ---------- Paths ----------


def _today_iso() -> str:
    return _dt.date.today().isoformat()


def _utc_ts() -> str:
    # ISO without colons (safe for filenames on all FS).
    return _dt.datetime.utcnow().strftime("%Y%m%dT%H%M%SZ")


def _unique_suffix() -> str:
    """Collision-proof suffix for .bak-/.tmp- filenames.

    _utc_ts() alone has second resolution: two applies inside the same second
    used to overwrite each other's backup (shutil.copy2 onto the same .bak
    name) and crash mid-apply on the tokens tmp file (O_EXCL on the same
    .tmp name -> FileExistsError -> 500 with partial state). pid + a
    monotonic per-process counter de-duplicates across threads AND processes
    while keeping the sortable timestamp prefix.
    """
    return f"{_utc_ts()}-{os.getpid()}-{next(_WRITE_SEQ)}"


def _root() -> str:
    return settings.squad_home


def _agent_dir(slug: str) -> str:
    return os.path.join(_root(), "agents", slug)


def _agents_json_path() -> str:
    return os.path.join(_root(), "config", "agents.json")


def _tokens_env_path() -> str:
    return os.path.join(_root(), "private", "agent-tokens.env")


def _read_or_empty(path: str) -> str:
    try:
        with open(path, "r", encoding="utf-8") as f:
            return f.read()
    except FileNotFoundError:
        return ""
    except OSError as e:
        log.warning("read failed for %s: %s", path, e)
        return ""


# ---------- agents.json helpers ----------


def _load_agents_config() -> Dict:
    """Parse config/agents.json directly (json.load, NOT the registry cache).

    Missing file → deep copy of SEED_AGENTS (the wizard will create the file).
    Present but unparseable / wrong shape → ValueError (never clobber it).
    """
    path = _agents_json_path()
    if not os.path.exists(path):
        return copy.deepcopy(SEED_AGENTS)
    try:
        with open(path, "r", encoding="utf-8") as f:
            data = json.load(f)
    except (json.JSONDecodeError, OSError) as e:
        raise ValueError(f"config/agents.json unreadable: {e}")
    if not isinstance(data, dict) or not isinstance(data.get("agents"), list):
        raise ValueError(
            "config/agents.json malformed: expected {\"version\": 1, \"agents\": [...]}"
        )
    return data


def _next_window(config: Dict) -> int:
    windows = [
        a["window"]
        for a in config.get("agents", [])
        if isinstance(a, dict)
        and a.get("attach") == "tmux"
        and isinstance(a.get("window"), int)
    ]
    return max(windows, default=0) + 1


def _agents_json_entry(spec: AgentSpec, config: Dict) -> Dict:
    entry: Dict = {
        "id": spec.slug,
        "name": spec.display_name,
        "label": spec.display_name,
        "attach": "tmux",
        "window": _next_window(config),
        "persona_dir": spec.slug,
        "model_default": spec.model,
    }
    if spec.telegram.token:
        entry["token_env"] = _token_env_name(spec.slug)
    entry["color"] = spec.color
    return entry


def _render_agents_json(spec: AgentSpec) -> Tuple[str, Dict]:
    """Return ``(full_new_file_text, appended_entry)``.

    Raises ValueError if the slug already exists in agents.json or the file
    is unreadable — this doubles as the apply-time pre-flight dry-run.
    """
    config = _load_agents_config()
    existing_ids = {
        a.get("id") for a in config.get("agents", []) if isinstance(a, dict)
    }
    if spec.slug in existing_ids:
        raise ValueError(f"slug '{spec.slug}' already present in config/agents.json")
    entry = _agents_json_entry(spec, config)
    config["agents"].append(entry)
    return json.dumps(config, indent=2) + "\n", entry


# ---------- tokens-file helpers ----------


def _tokens_file_keys(text: str) -> List[str]:
    keys: List[str] = []
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        keys.append(line.split("=", 1)[0].strip())
    return keys


def _redacted_tokens_excerpt(text: str) -> str:
    """Keys-only view of the tokens file. NEVER include values."""
    keys = _tokens_file_keys(text)
    if not keys:
        return "(empty / new file)"
    return "\n".join(f"{k}=TOKEN REDACTED" for k in keys)


# ---------- Validation ----------


def _existing_slugs() -> List[str]:
    """Union of agents.json ids, registry ids, and agents/ dir names."""
    out: List[str] = []
    try:
        cfg = _load_agents_config()
        out.extend(
            a.get("id") for a in cfg.get("agents", [])
            if isinstance(a, dict) and a.get("id")
        )
    except ValueError:
        pass  # surfaced separately in _validate_spec
    try:
        out.extend(a.id for a in _registry_list_agents())
    except Exception as e:  # registry should never fail, but don't block on it
        log.warning("registry list_agents failed: %s", e)
    agents_dir = os.path.join(_root(), "agents")
    if os.path.isdir(agents_dir):
        for name in os.listdir(agents_dir):
            if os.path.isdir(os.path.join(agents_dir, name)):
                out.append(name)
    return out


def _validate_telegram(spec: AgentSpec) -> List[str]:
    """Telegram checks — only enforced when a token was provided.

    Empty token = CLI-only agent: the whole telegram block is ignored.
    """
    tg = spec.telegram
    if not tg.token:
        return []
    errs: List[str] = []
    if not TG_TOKEN_RE.fullmatch(tg.token):
        errs.append("telegram.token must match ^\\d+:[\\w-]+$ (or be empty for a CLI-only agent)")
    if tg.group_id and not TG_ID_RE.fullmatch(tg.group_id):
        errs.append("telegram.group_id must be numeric (with optional - prefix)")
    op_id = tg.operator_id or os.environ.get("OPERATOR_TELEGRAM_ID", "")
    if not op_id or not TG_ID_RE.fullmatch(op_id):
        errs.append("telegram.operator_id must be numeric (default from OPERATOR_TELEGRAM_ID)")
    env_name = _token_env_name(spec.slug)
    if env_name in _tokens_file_keys(_read_or_empty(_tokens_env_path())):
        errs.append(f"{env_name} already present in private/agent-tokens.env")
    return errs


def _validate_spec(spec: AgentSpec) -> List[str]:
    # NOTE: fullmatch everywhere — '$'-anchored .match() accepts a trailing
    # '\n' (Python regex semantics), which used to let "nora\n" through.
    errs: List[str] = []
    if not SLUG_RE.fullmatch(spec.slug):
        errs.append(f"slug '{spec.slug}' must match ^[a-z][a-z0-9-]{{2,30}}$")
    elif spec.slug in _existing_slugs():
        errs.append(f"slug '{spec.slug}' already in use")

    if not (1 <= len(spec.display_name) <= 40):
        errs.append("display_name must be 1-40 chars")
    elif any(c in spec.display_name for c in "|\n\r"):
        # display_name becomes the agents.json "label", which launch.sh's
        # roster parser pipe-joins: '|' or a newline would make it reject the
        # ENTIRE file and fall back to the legacy 3-agent roster.
        errs.append("display_name must not contain '|' or newline characters")

    if spec.model not in ALLOWED_MODELS:
        errs.append(f"model must be one of {ALLOWED_MODELS}")

    if not COLOR_RE.fullmatch(spec.color):
        errs.append("color must be #RRGGBB hex")

    errs.extend(_validate_telegram(spec))

    if spec.persona.template not in TEMPLATES:
        errs.append(f"persona.template must be one of {TEMPLATES}")

    for t in spec.persona.tools:
        if t not in ALLOWED_TOOLS:
            errs.append(f"persona.tools entry '{t}' not in {ALLOWED_TOOLS}")

    try:
        _load_agents_config()
    except ValueError as e:
        errs.append(str(e))

    return errs


def _resolved_operator_id(spec: AgentSpec) -> str:
    return spec.telegram.operator_id or os.environ.get("OPERATOR_TELEGRAM_ID", "")


# ---------- File planning ----------


class PlanItem(NamedTuple):
    path: str
    action: str  # "create" | "append" | "patch"
    content: str  # exact bytes to write (full file for "patch")
    secret: bool = False  # content holds a secret — redact everywhere
    excerpt: Optional[str] = None  # preview override (delta / redacted view)


def _planned_writes(spec: AgentSpec) -> List[PlanItem]:
    """Return the ordered write plan for this spec.

    Raises ValueError on agents.json / tokens-file conflicts, so calling this
    is also the pre-flight dry-run before any write.
    """
    today = _today_iso()
    spec_dict = spec.model_dump()
    plan: List[PlanItem] = []

    # agent persona files (create)
    adir = _agent_dir(spec.slug)
    plan.append(PlanItem(os.path.join(adir, "AGENTS.md"), "create", render_agents_md(spec_dict, today)))
    plan.append(PlanItem(os.path.join(adir, "SOUL.md"), "create", render_soul_md(spec_dict, today)))
    plan.append(PlanItem(os.path.join(adir, "TOOLS.md"), "create", render_tools_md(spec_dict, today)))

    # config/agents.json (atomic full rewrite; computed NOW = dry-run)
    json_text, entry = _render_agents_json(spec)
    plan.append(PlanItem(
        _agents_json_path(),
        "patch",
        json_text,
        excerpt="appended agent entry:\n" + json.dumps(entry, indent=2),
    ))

    # private/agent-tokens.env (append, secret) — only when a token was given
    token = spec.telegram.token
    if token:
        env_name = _token_env_name(spec.slug)
        if env_name in _tokens_file_keys(_read_or_empty(_tokens_env_path())):
            raise ValueError(f"{env_name} already present in private/agent-tokens.env")
        plan.append(PlanItem(
            _tokens_env_path(),
            "append",
            f"{env_name}={token}\n",
            secret=True,
            excerpt=f"{env_name}=TOKEN REDACTED ({len(token)} chars)",
        ))

    return plan


def _excerpt(text: str, lines: int = 6) -> str:
    rows = text.splitlines()
    if len(rows) <= lines:
        return text
    return "\n".join(rows[:lines]) + "\n…"


# ---------- Backup + atomic write ----------


def _backup_and_write(path: str, content: str, mode: str) -> Optional[str]:
    """Write ``content`` to ``path`` atomically. Returns backup path if a
    backup was made, else None.

    mode ∈ {"create", "append", "overwrite"}.
    """
    os.makedirs(os.path.dirname(path), exist_ok=True)
    backup_path: Optional[str] = None
    if os.path.exists(path):
        backup_path = f"{path}.bak-{_unique_suffix()}"
        shutil.copy2(path, backup_path)

    if mode == "append":
        existing = _read_or_empty(path)
        final = existing + content
    else:
        final = content

    tmp = f"{path}.tmp-{_unique_suffix()}"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(final)
    os.replace(tmp, path)
    return backup_path


def _secure_append_tokens(path: str, line: str) -> Optional[str]:
    """Append one ``KEY=value`` line to the tokens file, atomically, keeping
    the file (and its backup + tmp) at mode 0600. Returns backup path or None.

    The value is a secret: this function never logs content.
    """
    os.makedirs(os.path.dirname(path), mode=0o700, exist_ok=True)
    backup_path: Optional[str] = None
    existing = ""
    if os.path.exists(path):
        backup_path = f"{path}.bak-{_unique_suffix()}"
        shutil.copy2(path, backup_path)  # copy2 preserves 0600
        os.chmod(backup_path, 0o600)
        existing = _read_or_empty(path)
        if existing and not existing.endswith("\n"):
            existing += "\n"

    key = line.split("=", 1)[0].strip()
    if key in _tokens_file_keys(existing):
        raise ValueError(f"{key} already present in {os.path.basename(path)}")

    tmp = f"{path}.tmp-{_unique_suffix()}"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(existing + line)
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)
    os.chmod(path, 0o600)
    return backup_path


def _write_plan_item(item: PlanItem) -> Optional[str]:
    if item.secret:
        return _secure_append_tokens(item.path, item.content)
    if item.action == "patch":
        return _backup_and_write(item.path, item.content, mode="overwrite")
    if item.action == "append":
        return _backup_and_write(item.path, item.content, mode="append")
    return _backup_and_write(item.path, item.content, mode="create")


# ---------- Endpoints ----------


@router.post("/getme")
async def getme(body: GetMeBody, _gate: str = Depends(wizard_gate)) -> Dict:
    token = body.token.strip()
    if not TG_TOKEN_RE.fullmatch(token):
        return {"ok": False, "error": "token shape invalid"}
    # SECRET-BEARING URL: never log it and never let it reach any other
    # logging path (httpx's own INFO request log is silenced at module top).
    url = f"https://api.telegram.org/bot{token}/getMe"
    try:
        async with httpx.AsyncClient(timeout=10.0) as client:
            r = await client.get(url)
        data = r.json()
    except Exception as e:
        # Class name ONLY — some httpx exceptions embed the full request URL
        # (and therefore the token) in str(e).
        return {"ok": False, "error": f"network: {type(e).__name__}"}
    if not data.get("ok"):
        return {"ok": False, "error": data.get("description", "telegram getMe failed")}
    result = data["result"]
    return {
        "ok": True,
        "bot_username": result.get("username"),
        "bot_id": result.get("id"),
    }


def _diff_entry(item: PlanItem) -> Dict:
    """One preview row: {file, action, before_excerpt, after_excerpt}.

    Secret items get a keys-only redacted view on BOTH sides — token values
    never leave the server.
    """
    before = _read_or_empty(item.path)
    if item.secret:
        return {
            "file": item.path,
            "action": item.action,
            "before_excerpt": _redacted_tokens_excerpt(before),
            "after_excerpt": item.excerpt or "TOKEN REDACTED",
        }
    if item.action == "append":
        after = before + item.content
    else:  # create | patch — content IS the full new file
        after = item.content
    return {
        "file": item.path,
        "action": item.action,
        "before_excerpt": _excerpt(before) if before else "(empty / new file)",
        "after_excerpt": item.excerpt or _excerpt(after),
    }


@router.post("/preview")
async def preview(body: WizardBody, _gate: str = Depends(wizard_gate)) -> Dict:
    errs = _validate_spec(body.agent)
    if errs:
        raise HTTPException(status_code=422, detail={"errors": errs})

    try:
        plan = _planned_writes(body.agent)
    except ValueError as e:
        raise HTTPException(status_code=422, detail={"errors": [str(e)]})

    diff = [_diff_entry(item) for item in plan]
    return {"ok": True, "diff": diff, "operator_id": _resolved_operator_id(body.agent)}


@router.post("/apply")
async def apply(body: WizardBody, _gate: str = Depends(wizard_gate)) -> Dict:
    errs = _validate_spec(body.agent)
    if errs:
        raise HTTPException(status_code=422, detail={"errors": errs})

    # CRITICAL SECTION: _planned_writes READS config/agents.json and the
    # write loop REPLACES it — an unlocked read-modify-write. _APPLY_LOCK
    # serializes concurrent applies (lost entries / duplicate windows
    # otherwise). There are deliberately NO awaits inside this block: a
    # threading.Lock held across an await would stall the event loop.
    with _APPLY_LOCK:
        # Pre-flight dry-run: _planned_writes computes the FULL new
        # agents.json and re-checks slug / token_env conflicts — fails loud
        # BEFORE any write.
        try:
            plan = _planned_writes(body.agent)
        except ValueError as e:
            raise HTTPException(
                status_code=422,
                detail={"errors": [f"plan refused: {e}"]},
            )

        backups: List[str] = []
        written: List[str] = []
        try:
            for item in plan:
                bk = _write_plan_item(item)
                if bk:
                    backups.append(bk)
                written.append(item.path)
        except Exception as e:
            log.exception("apply failed mid-way")  # paths only — never token values
            raise HTTPException(
                status_code=500,
                detail={
                    "errors": [f"write failed: {e}"],
                    "written_so_far": written,
                    "backups_so_far": backups,
                },
            )

    return {
        "ok": True,
        "written": written,
        "backups": backups,
        "next_step": (
            f"'{body.agent.slug}' is registered in config/agents.json — it "
            "appears in the UI tab bar within seconds (registry reload). Its "
            "tmux window starts after the war-room container restarts: "
            "POST /api/admin/wizard/restart-warroom "
            "or run: docker compose restart war-room"
        ),
    }


@router.post("/restart-warroom")
async def restart_warroom(_gate: str = Depends(wizard_gate)) -> Dict:
    target = settings.warroom_container
    if not target:
        # Fail-loud: container targets have no baked-in default — the compose
        # template must inject WARROOM2_WARROOM_CONTAINER per squad.
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail={"errors": ["WARROOM2_WARROOM_CONTAINER is not configured"]},
        )
    try:
        # Use `docker restart` via the same socket the docker_client uses.
        import subprocess
        result = subprocess.run(
            ["docker", "restart", target],
            capture_output=True,
            text=True,
            timeout=30.0,
        )
        if result.returncode != 0:
            raise RuntimeError(result.stderr.strip() or "docker restart failed")
    except Exception as e:
        raise HTTPException(
            status_code=500,
            detail={"errors": [f"restart failed: {e}"]},
        )
    return {"ok": True, "container": target}


# Re-export for tests
__all__ = [
    "router",
    "_validate_spec",
    "_planned_writes",
    "_render_agents_json",
    "_token_env_name",
    "_secure_append_tokens",
    "PlanItem",
    "AgentSpec",
    "ALLOWED_MODELS",
    "SEED_AGENTS",
]
