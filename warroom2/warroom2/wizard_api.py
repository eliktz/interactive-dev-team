"""warroom2.wizard_api — admin "mount new agent" wizard backend.

4 endpoints under ``/api/admin/wizard/*``, all gated by:
- existing basic-auth dependency
- ``X-Admin-Token`` header matching ``settings.admin_token``

If ``settings.admin_token`` is empty, every wizard endpoint returns 503 with
``{"error": "admin token not configured"}``.

File mutations are atomic (write to ``.tmp`` then ``os.replace``) and create a
``.bak-<utc-iso>`` backup of the original (when present) before any write.

The wizard mutates files inside ``settings.interactive_dev_team_root`` which is
mounted into warroom2 as a NEW rw bind from the host.
"""

from __future__ import annotations

import datetime as _dt
import logging
import os
import re
import shutil
from typing import Dict, List, Optional, Tuple

import httpx
from fastapi import APIRouter, Depends, Header, HTTPException, Request, status
from pydantic import BaseModel, Field

from .agent_registry import AGENTS as REGISTRY_AGENTS
from .auth import basic_auth_dependency
from .settings import settings
from .templates import (
    ALLOWED_TOOLS,
    TEMPLATES,
    render_agents_md,
    render_env_block,
    render_launch_line,
    render_soul_md,
    render_tools_md,
)

log = logging.getLogger(__name__)

router = APIRouter(prefix="/api/admin/wizard")

ALLOWED_MODELS = ["sonnet", "opus", "haiku", "gpt-5.5"]
SLUG_RE = re.compile(r"^[a-z][a-z0-9-]{2,30}$")
COLOR_RE = re.compile(r"^#[0-9a-fA-F]{6}$")
TG_TOKEN_RE = re.compile(r"^\d+:[\w-]+$")
TG_ID_RE = re.compile(r"^-?\d+$")


# ---------- Pydantic models ----------


class TelegramSpec(BaseModel):
    token: str = ""
    group_id: str = ""
    operator_id: str = ""


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


# ---------- Validation ----------


def _existing_slugs() -> List[str]:
    out = [a.id for a in REGISTRY_AGENTS]
    root = settings.interactive_dev_team_root
    agents_dir = os.path.join(root, "agents")
    if os.path.isdir(agents_dir):
        for name in os.listdir(agents_dir):
            full = os.path.join(agents_dir, name)
            if os.path.isdir(full):
                out.append(name)
    return out


def _validate_spec(spec: AgentSpec) -> List[str]:
    errs: List[str] = []
    if not SLUG_RE.match(spec.slug):
        errs.append(f"slug '{spec.slug}' must match ^[a-z][a-z0-9-]{{2,30}}$")
    elif spec.slug in _existing_slugs():
        errs.append(f"slug '{spec.slug}' already in use")

    if not (1 <= len(spec.display_name) <= 40):
        errs.append("display_name must be 1-40 chars")

    if spec.model not in ALLOWED_MODELS:
        errs.append(f"model must be one of {ALLOWED_MODELS}")

    if not COLOR_RE.match(spec.color):
        errs.append("color must be #RRGGBB hex")

    tg = spec.telegram
    if not tg.token or not TG_TOKEN_RE.match(tg.token):
        errs.append("telegram.token must match ^\\d+:[\\w-]+$")
    if tg.group_id and not TG_ID_RE.match(tg.group_id):
        errs.append("telegram.group_id must be numeric (with optional - prefix)")
    op_id = tg.operator_id or os.environ.get("OPERATOR_TELEGRAM_ID", "")
    if not op_id or not TG_ID_RE.match(op_id):
        errs.append("telegram.operator_id must be numeric (default from OPERATOR_TELEGRAM_ID)")

    if spec.persona.template not in TEMPLATES:
        errs.append(f"persona.template must be one of {TEMPLATES}")

    for t in spec.persona.tools:
        if t not in ALLOWED_TOOLS:
            errs.append(f"persona.tools entry '{t}' not in {ALLOWED_TOOLS}")

    return errs


def _resolved_operator_id(spec: AgentSpec) -> str:
    return spec.telegram.operator_id or os.environ.get("OPERATOR_TELEGRAM_ID", "")


# ---------- File planning ----------


def _today_iso() -> str:
    return _dt.date.today().isoformat()


def _utc_ts() -> str:
    # ISO without colons (safe for filenames on all FS).
    return _dt.datetime.utcnow().strftime("%Y%m%dT%H%M%SZ")


def _root() -> str:
    return settings.interactive_dev_team_root


def _agent_dir(slug: str) -> str:
    return os.path.join(_root(), "agents", slug)


def _planned_writes(spec: AgentSpec) -> List[Tuple[str, str, str]]:
    """Return list of ``(path, action, new_content)`` for this spec.

    action ∈ {"create", "append", "patch"}.
    """
    today = _today_iso()
    spec_dict = spec.model_dump()
    plan: List[Tuple[str, str, str]] = []

    # .env append
    env_path = os.path.join(_root(), ".env")
    env_block = render_env_block(spec_dict, spec.telegram.token, today)
    plan.append((env_path, "append", env_block))

    # agent persona files (create)
    adir = _agent_dir(spec.slug)
    plan.append((os.path.join(adir, "AGENTS.md"), "create", render_agents_md(spec_dict, today)))
    plan.append((os.path.join(adir, "SOUL.md"), "create", render_soul_md(spec_dict, today)))
    plan.append((os.path.join(adir, "TOOLS.md"), "create", render_tools_md(spec_dict, today)))

    # launch.sh patch (full new content computed at apply time)
    plan.append((os.path.join(_root(), "launch.sh"), "patch", render_launch_line(spec_dict)))

    return plan


def _excerpt(text: str, lines: int = 6) -> str:
    rows = text.splitlines()
    if len(rows) <= lines:
        return text
    return "\n".join(rows[:lines]) + "\n…"


def _read_or_empty(path: str) -> str:
    try:
        with open(path, "r", encoding="utf-8") as f:
            return f.read()
    except FileNotFoundError:
        return ""
    except OSError as e:
        log.warning("read failed for %s: %s", path, e)
        return ""


# ---------- launch.sh patching ----------


_LAUNCH_AGENTS_BLOCK_RE = re.compile(
    r"(AGENTS=\(\n)(?P<body>(?:[^)]*\n)*?)(\))",
    re.MULTILINE,
)


def _patch_launch_sh(original: str, new_line: str) -> str:
    """Insert ``new_line`` before the closing ``)`` of the ``AGENTS=(...)``
    array. Raises ``ValueError`` if the regex doesn't match exactly once or if
    the line is already present.
    """
    matches = list(_LAUNCH_AGENTS_BLOCK_RE.finditer(original))
    if len(matches) != 1:
        raise ValueError(
            f"expected exactly one AGENTS=(...) block, found {len(matches)}"
        )
    m = matches[0]
    body = m.group("body")
    if new_line.strip() in body:
        raise ValueError("agent already present in AGENTS=(...) block")
    new_body = body
    if not new_body.endswith("\n"):
        new_body += "\n"
    new_body += new_line
    return original[: m.start()] + "AGENTS=(\n" + new_body + ")" + original[m.end():]


# ---------- Backup + atomic write ----------


def _backup_and_write(path: str, content: str, mode: str) -> Optional[str]:
    """Write ``content`` to ``path`` atomically. Returns backup path if a
    backup was made, else None.

    mode ∈ {"create", "append", "overwrite"}.
    """
    os.makedirs(os.path.dirname(path), exist_ok=True)
    backup_path: Optional[str] = None
    if os.path.exists(path):
        backup_path = f"{path}.bak-{_utc_ts()}"
        shutil.copy2(path, backup_path)

    if mode == "append":
        existing = _read_or_empty(path)
        final = existing + content
    else:
        final = content

    tmp = f"{path}.tmp-{_utc_ts()}"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(final)
    os.replace(tmp, path)
    return backup_path


# ---------- Endpoints ----------


@router.post("/getme")
async def getme(body: GetMeBody, _gate: str = Depends(wizard_gate)) -> Dict:
    token = body.token.strip()
    if not TG_TOKEN_RE.match(token):
        return {"ok": False, "error": "token shape invalid"}
    url = f"https://api.telegram.org/bot{token}/getMe"
    try:
        async with httpx.AsyncClient(timeout=10.0) as client:
            r = await client.get(url)
        data = r.json()
    except Exception as e:
        return {"ok": False, "error": f"network: {e}"}
    if not data.get("ok"):
        return {"ok": False, "error": data.get("description", "telegram getMe failed")}
    result = data["result"]
    return {
        "ok": True,
        "bot_username": result.get("username"),
        "bot_id": result.get("id"),
    }


@router.post("/preview")
async def preview(body: WizardBody, _gate: str = Depends(wizard_gate)) -> Dict:
    errs = _validate_spec(body.agent)
    if errs:
        raise HTTPException(status_code=422, detail={"errors": errs})

    plan = _planned_writes(body.agent)
    diff: List[Dict] = []
    for path, action, content in plan:
        before = _read_or_empty(path)
        if action == "create":
            after = content
        elif action == "append":
            after = before + content
        else:  # patch
            try:
                after = _patch_launch_sh(before, content)
            except ValueError as e:
                raise HTTPException(
                    status_code=422,
                    detail={"errors": [f"launch.sh patch: {e}"]},
                )
        diff.append(
            {
                "file": path,
                "action": action,
                "before_excerpt": _excerpt(before) if before else "(empty / new file)",
                "after_excerpt": _excerpt(after),
            }
        )
    return {"ok": True, "diff": diff, "operator_id": _resolved_operator_id(body.agent)}


@router.post("/apply")
async def apply(body: WizardBody, _gate: str = Depends(wizard_gate)) -> Dict:
    errs = _validate_spec(body.agent)
    if errs:
        raise HTTPException(status_code=422, detail={"errors": errs})

    plan = _planned_writes(body.agent)
    backups: List[str] = []
    written: List[str] = []

    # Pre-flight: compute launch.sh patched content with a dry run to fail loud
    # BEFORE we touch any other file.
    launch_path = os.path.join(_root(), "launch.sh")
    launch_orig = _read_or_empty(launch_path)
    if not launch_orig:
        raise HTTPException(
            status_code=500,
            detail={"errors": [f"launch.sh missing at {launch_path}"]},
        )
    launch_line = render_launch_line(body.agent.model_dump())
    try:
        launch_patched = _patch_launch_sh(launch_orig, launch_line)
    except ValueError as e:
        raise HTTPException(
            status_code=422,
            detail={"errors": [f"launch.sh patch refused: {e}"]},
        )

    try:
        for path, action, content in plan:
            if action == "patch":
                bk = _backup_and_write(path, launch_patched, mode="overwrite")
            elif action == "append":
                bk = _backup_and_write(path, content, mode="append")
            else:  # create
                bk = _backup_and_write(path, content, mode="create")
            if bk:
                backups.append(bk)
            written.append(path)
    except Exception as e:
        log.exception("apply failed mid-way")
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
            "POST /api/admin/wizard/restart-warroom "
            "or run: docker compose restart war-room"
        ),
    }


@router.post("/restart-warroom")
async def restart_warroom(_gate: str = Depends(wizard_gate)) -> Dict:
    target = settings.warroom_container
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
    "_patch_launch_sh",
    "_validate_spec",
    "_planned_writes",
    "AgentSpec",
    "ALLOWED_MODELS",
]
