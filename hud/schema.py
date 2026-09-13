"""hud.event/v1 validation and Claude Code hook → envelope normalization."""
from __future__ import annotations

import json
import re
import socket
from typing import Any

SCHEMA_ID = "hud.event/v1"

REQUIRED_FIELDS = ("schema", "ts", "session_id", "source", "kind", "seq", "payload")

_HOOK_KIND = {
    "sessionstart": "session_start",
    "userpromptsubmit": "user_prompt",
    "pretooluse": "pre_tool_use",
    "posttooluse": "post_tool_use",
    "notification": "notification",
    "stop": "stop",
    "subagentstop": "subagent_stop",
    "precompact": "pre_compact",
}

_CAMEL = re.compile(r"([a-z0-9])([A-Z])")
_NON_ALNUM = re.compile(r"[^a-zA-Z0-9]+")


def slugify_kind(name: str) -> str:
    s = _CAMEL.sub(r"\1_\2", str(name or ""))
    s = _NON_ALNUM.sub("_", s).strip("_").lower()
    return s or "unknown"


def validate_envelope(event: Any) -> dict:
    if not isinstance(event, dict):
        raise ValueError("envelope must be an object")
    missing = []
    for key in REQUIRED_FIELDS:
        if key not in event or event[key] is None:
            missing.append(key)
        elif key != "payload" and key != "seq" and event[key] == "":
            missing.append(key)
    if missing:
        raise ValueError("missing required fields: " + ", ".join(missing))
    if event.get("schema") != SCHEMA_ID:
        raise ValueError("schema must be " + SCHEMA_ID)
    if not isinstance(event.get("seq"), int) or isinstance(event.get("seq"), bool):
        raise ValueError("seq must be an int")
    if not isinstance(event.get("payload"), dict):
        raise ValueError("payload must be an object")
    return event


def _hook_name(hook: dict) -> str:
    for key in ("hook_event_name", "hook_event_type", "event_name", "event"):
        val = hook.get(key)
        if val:
            return str(val)
    if hook.get("kind"):
        return str(hook["kind"])
    return ""


def _summarize_tool_input(tool_name: str, tool_input: Any) -> str:
    if isinstance(tool_input, dict):
        if tool_name == "Bash" and tool_input.get("command") is not None:
            s = str(tool_input.get("command") or "")
        elif tool_input.get("file_path"):
            s = str(tool_input.get("file_path"))
        elif tool_input.get("query"):
            s = str(tool_input.get("query"))
        elif tool_input.get("description"):
            s = str(tool_input.get("description"))
        else:
            try:
                s = json.dumps(tool_input, ensure_ascii=False)
            except TypeError:
                s = str(tool_input)
    elif tool_input is None:
        s = ""
    else:
        s = str(tool_input)
    s = " ".join(s.split())
    if len(s) > 120:
        s = s[:117] + "..."
    return s


def _post_tool_ok_error(hook: dict) -> tuple[bool, str | None]:
    ok = True
    error = None
    if hook.get("is_error") is True:
        ok = False
    resp = hook.get("tool_response")
    if isinstance(resp, dict):
        if resp.get("is_error") is True or resp.get("error"):
            ok = False
            err = resp.get("error") or resp.get("message") or "error"
            error = str(err)[:200]
    elif isinstance(resp, str) and resp.strip():
        low = resp.lower()
        if low.startswith("error") or "traceback" in low[:80]:
            ok = False
            error = resp[:200]
    if hook.get("error"):
        ok = False
        error = str(hook.get("error"))[:200]
    return ok, error


def _agent_name(hook: dict) -> str:
    for key in ("agent", "agent_name", "agent_id", "agent_type", "subagent_type"):
        val = hook.get(key)
        if val:
            return str(val)
    tool_input = hook.get("tool_input")
    if isinstance(tool_input, dict):
        for key in ("subagent_type", "description"):
            val = tool_input.get(key)
            if val and key == "subagent_type":
                return str(val)
    return "main"


def normalize_hook(hook: Any) -> dict:
    """Claude Code hook JSON → partial hud.event/v1 envelope (no seq)."""
    if not isinstance(hook, dict):
        raise ValueError("hook must be an object")
    raw_name = _hook_name(hook)
    mapped = _HOOK_KIND.get(raw_name.replace("_", "").replace("-", "").lower())
    if mapped:
        kind = mapped
    elif raw_name:
        kind = slugify_kind(raw_name)
    else:
        kind = "unknown"

    session_id = str(hook.get("session_id") or "")
    agent = _agent_name(hook)
    payload: dict[str, Any]

    if kind == "session_start":
        payload = {
            "source": str(hook.get("source") or "startup")[:64],
            "cwd": str(hook.get("cwd") or "")[:500],
        }
    elif kind == "user_prompt":
        payload = {"prompt": str(hook.get("prompt") or "")[:500]}
    elif kind == "pre_tool_use":
        tool_name = str(hook.get("tool_name") or "")[:120]
        payload = {
            "tool_name": tool_name,
            "tool_input_summary": _summarize_tool_input(tool_name, hook.get("tool_input")),
        }
    elif kind == "post_tool_use":
        tool_name = str(hook.get("tool_name") or "")[:120]
        ok, error = _post_tool_ok_error(hook)
        payload = {"tool_name": tool_name, "ok": ok}
        if error:
            payload["error"] = error
    elif kind == "notification":
        payload = {"message": str(hook.get("message") or "")[:500]}
    elif kind == "stop":
        payload = {}
    elif kind == "subagent_stop":
        payload = {"agent": agent}
    elif kind == "pre_compact":
        payload = {"trigger": str(hook.get("trigger") or "auto")[:64]}
    else:
        payload = {}
        caps = {
            "message": 500,
            "prompt": 500,
            "tool_name": 120,
            "cwd": 500,
            "source": 64,
            "trigger": 64,
        }
        for key in ("message", "prompt", "tool_name", "cwd", "source", "trigger"):
            if key in hook and hook[key] is not None:
                payload[key] = str(hook[key])[: caps[key]]

    envelope: dict[str, Any] = {
        "session_id": session_id,
        "kind": kind,
        "payload": payload,
        "machine": hook.get("machine") or socket.gethostname(),
        "agent": agent,
    }
    if hook.get("ts"):
        envelope["ts"] = hook["ts"]
    return envelope
