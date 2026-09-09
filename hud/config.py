"""Read/write hud/config.json — {"default_frontend": name | null}."""
from __future__ import annotations

import json
import os
import tempfile
from pathlib import Path
from typing import Any, Optional

_DEFAULT = {"default_frontend": None}


def config_path() -> Path:
    env = os.environ.get("HUD_CONFIG")
    if env:
        return Path(env)
    return Path(__file__).resolve().parent / "config.json"


def read_config() -> dict[str, Any]:
    path = config_path()
    try:
        raw = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return dict(_DEFAULT)
    if not isinstance(raw, dict):
        return dict(_DEFAULT)
    val = raw.get("default_frontend", None)
    if val is not None:
        val = str(val)
    return {"default_frontend": val}


def write_config(default_frontend: Optional[str]) -> dict[str, Any]:
    if default_frontend is not None:
        default_frontend = str(default_frontend)
        if default_frontend == "" or default_frontend.lower() == "null":
            default_frontend = None
    data = {"default_frontend": default_frontend}
    path = config_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix="hud-config-", suffix=".json", dir=str(path.parent))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump(data, fh)
            fh.write("\n")
        os.replace(tmp, path)
    except Exception:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise
    return data
