"""Reader for tools.yaml — the non-LLM capability registry (sibling of fleet.yaml).

Lean by design: only what's needed to SELECT and INVOKE a tool. Path resolution
mirrors the KB/PS convention: explicit param > $TOOLS_FILE env > $BATON_HOME/tools.yaml.
A missing registry yields [] (never raises) so the .md pipeline survives its absence.
"""
from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path

import yaml

from tools.paths import baton_home


@dataclass
class ToolSpec:
    name: str
    kind: str                      # python | cli | http
    enabled: bool
    cost_tier: str                 # paid | free | local
    capability: str | None = None  # the routing key, e.g. pdf-extract
    module: str | None = None      # kind:python — importable module path
    command_template: str | None = None  # kind:cli
    base_url: str | None = None    # kind:http


def _resolve_path(path: Path | None) -> Path:
    if path is not None:
        return Path(path)
    env = os.environ.get("TOOLS_FILE")
    if env:
        return Path(env)
    return baton_home() / "tools.yaml"


def read_tools(path: Path | None = None) -> list[ToolSpec]:
    p = _resolve_path(path)
    if not p.exists():
        return []
    data = yaml.safe_load(p.read_text(encoding="utf-8")) or {}
    out: list[ToolSpec] = []
    for entry in data.get("tools", []) or []:
        out.append(
            ToolSpec(
                name=str(entry.get("name", "")),
                kind=str(entry.get("kind", "")),
                enabled=bool(entry.get("enabled", False)),
                cost_tier=str(entry.get("cost_tier", "")),
                capability=entry.get("capability"),
                module=entry.get("module"),
                command_template=entry.get("command_template"),
                base_url=entry.get("base_url"),
            )
        )
    return out


def get_tool(name: str, *, path: Path | None = None) -> ToolSpec | None:
    for t in read_tools(path):
        if t.name == name:
            return t
    return None


def tools_for_capability(
    capability: str, *, path: Path | None = None, enabled_only: bool = True
) -> list[ToolSpec]:
    out = [t for t in read_tools(path) if t.capability == capability]
    if enabled_only:
        out = [t for t in out if t.enabled]
    return out
