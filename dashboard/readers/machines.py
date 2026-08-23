"""Machines page — one card per computer, pinned/loaded first, catalog collapsed.

Reads fleet.yaml (no PyYAML) plus optional model-inventory.json and
coordination/config.json. Does not probe remote boxes.
"""
from __future__ import annotations

import json
import re
from pathlib import Path
from typing import Any, Optional
from urllib.parse import urlparse


_LOCAL_HOSTS = frozenset({"localhost", "127.0.0.1", "::1", "droid"})
_HOST_LABELS = {
    "localhost": "droid · Mac mini",
    "127.0.0.1": "droid · Mac mini",
    "::1": "droid · Mac mini",
    "droid": "droid · Mac mini",
}


def _unquote(value: str) -> str:
    v = value.strip()
    if len(v) >= 2 and v[0] == v[-1] and v[0] in ("'", '"'):
        return v[1:-1]
    if v in ("true", "True"):
        return "true"
    if v in ("false", "False"):
        return "false"
    return v


def parse_fleet_providers(text: str) -> list[dict[str, str]]:
    """Minimal fleet.yaml provider-block parser (top-level scalars only)."""
    providers: list[dict[str, str]] = []
    current: Optional[dict[str, str]] = None
    in_providers = False
    for raw in text.splitlines():
        line = raw.split("#", 1)[0].rstrip()
        if not line.strip():
            continue
        if line.startswith("providers:"):
            in_providers = True
            continue
        if not in_providers:
            continue
        if line and not line[0].isspace() and not line.startswith("-"):
            break
        named = re.match(r"^  - name:\s*(.+)$", line)
        if named:
            if current:
                providers.append(current)
            current = {"name": _unquote(named.group(1)), "enabled": "true"}
            continue
        if current:
            field = re.match(r"^    ([a-z_]+):\s*(.+)$", line)
            if field:
                current[field.group(1)] = _unquote(field.group(2))
    if current:
        providers.append(current)
    return providers


def _hostname(url: str) -> str:
    parsed = urlparse(url)
    return (parsed.hostname or url or "").strip().lower()


def _label_for_host(host: str, extra: dict[str, str] | None = None) -> str:
    if extra and host in extra:
        return extra[host]
    if host in _HOST_LABELS:
        return _HOST_LABELS[host]
    return host


def _is_local_host(host: str) -> bool:
    return host in _LOCAL_HOSTS or host.endswith(".local")


def _canonical_host(host: str) -> str:
    if _is_local_host(host):
        return "droid"
    return host


def _read_json(path: Path) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None


def default_fleet_path(baton_home: Path) -> Path:
    for candidate in (
        baton_home / "fleet.yaml",
        Path.home() / ".baton" / "fleet.yaml",
    ):
        if candidate.is_file():
            return candidate
    return baton_home / "fleet.yaml"


def read_machines(
    fleet_path: Path,
    *,
    inventory_path: Optional[Path] = None,
    coordination_path: Optional[Path] = None,
    loaded_lms: Optional[list[Any]] = None,
) -> dict[str, Any]:
    text = ""
    if fleet_path.is_file():
        try:
            text = fleet_path.read_text(encoding="utf-8")
        except OSError:
            text = ""
    providers = parse_fleet_providers(text)

    host_notes: dict[str, str] = {}
    coord = _read_json(coordination_path) if coordination_path else None
    hosts_cfg = (coord or {}).get("hosts") if isinstance(coord, dict) else None
    if isinstance(hosts_cfg, dict):
        for hid, spec in hosts_cfg.items():
            bits = []
            if isinstance(spec, dict):
                if spec.get("vram_gb"):
                    bits.append(f"{spec['vram_gb']} GB VRAM")
                if spec.get("note"):
                    bits.append(str(spec["note"]))
            host_notes[str(hid)] = " · ".join(bits)

    inventory_by_url: dict[str, list[dict[str, Any]]] = {}
    inv = _read_json(inventory_path) if inventory_path else None
    if isinstance(inv, dict):
        for box in inv.get("boxes") or []:
            if not isinstance(box, dict):
                continue
            url = str(box.get("base_url") or "")
            models = []
            for m in box.get("models") or []:
                if isinstance(m, dict) and m.get("id"):
                    models.append(
                        {
                            "id": str(m["id"]),
                            "loaded": bool(m.get("loaded")),
                            "pinned": False,
                        }
                    )
            inventory_by_url[url] = models

    boxes: dict[str, dict[str, Any]] = {}

    def box_for(host: str, *, kind: str, url: str = "") -> dict[str, Any]:
        if host not in boxes:
            boxes[host] = {
                "id": host,
                "name": _label_for_host(host),
                "kind": kind,
                "local": _is_local_host(host),
                "note": host_notes.get(host, ""),
                "base_url": url,
                "providers": [],
                "installed": [],
                "catalog": [],
                "loaded": [],
            }
        box = boxes[host]
        if url and not box.get("base_url"):
            box["base_url"] = url
        return box

    def add_model(box: dict[str, Any], mid: str, *, pinned: bool = False, loaded: bool = False) -> None:
        if not mid or mid == "auto":
            return
        existing = next((m for m in box["installed"] + box["catalog"] if m["id"] == mid), None)
        if existing:
            existing["pinned"] = existing["pinned"] or pinned
            existing["loaded"] = existing["loaded"] or loaded
            if pinned or loaded:
                if existing in box["catalog"]:
                    box["catalog"].remove(existing)
                    box["installed"].append(existing)
            return
        row = {"id": mid, "pinned": pinned, "loaded": loaded}
        if pinned or loaded:
            box["installed"].append(row)
        else:
            box["catalog"].append(row)
        if loaded:
            box["loaded"].append(row)

    cloud = {
        "id": "cloud",
        "name": "Cloud seats",
        "kind": "cloud",
        "local": False,
        "note": "Pinned paid / prepaid instruments — not a computer.",
        "base_url": "",
        "providers": [],
        "installed": [],
        "catalog": [],
        "loaded": [],
    }

    for p in providers:
        if p.get("enabled") == "false":
            continue
        name = p.get("name") or ""
        kind = p.get("kind") or ""
        tier = p.get("cost_tier") or ""
        url = p.get("base_url") or ""
        pin = p.get("model_default") or ""

        if kind == "http" and tier == "local" and url:
            host = _canonical_host(_hostname(url))
            box = box_for(host, kind="local", url=url)
            if name not in box["providers"]:
                box["providers"].append(name)
            add_model(box, pin, pinned=True)
            for inv_model in inventory_by_url.get(url, []):
                add_model(
                    box,
                    inv_model["id"],
                    pinned=inv_model["id"] == pin,
                    loaded=bool(inv_model.get("loaded")),
                )
            continue

        if kind == "cli" and tier == "local":
            box = box_for("droid", kind="local")
            if name not in box["providers"]:
                box["providers"].append(name)
            add_model(box, pin, pinned=True)
            continue

        if name not in cloud["providers"]:
            cloud["providers"].append(name)
        add_model(cloud, pin or name, pinned=True)

    # This-box LMS loaded list (OpenAI-compat = currently loaded, not the catalog).
    this_box = boxes.get("droid") or box_for("droid", kind="local")
    for item in loaded_lms or []:
        mid = item.id if hasattr(item, "id") else (item.get("id") if isinstance(item, dict) else "")
        if mid:
            add_model(this_box, str(mid), loaded=True)

    # Coordination hosts that have no fleet row still get a card.
    for hid, note in host_notes.items():
        box = box_for(hid, kind="local")
        if note and not box["note"]:
            box["note"] = note

    machines = sorted(
        (b for b in boxes.values() if b["kind"] == "local"),
        key=lambda b: (0 if b["local"] else 1, b["name"].lower()),
    )
    if cloud["providers"]:
        machines.append(cloud)

    return {
        "schema": 1,
        "fleet_path": str(fleet_path) if fleet_path.is_file() else "",
        "machines": machines,
    }
