"""Agent observability — declared vs observed (AgentTrail) + trajectory (AgentPulse-style).

Pure filesystem / optional localhost probe. Does not vendor AgentTrail or AgentPulse;
reads PLAN.md, ~/.agenttrail persisted state, optional sidecar JSON, and Baton snapshots.
"""
from __future__ import annotations

import hashlib
import json
import os
import re
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Optional

from dashboard.readers.maestro_jobs import projects_root

_NODE_RE = re.compile(r"^##\s+(.+?)\s*\{#([a-z0-9][a-z0-9-]*)\}\s*$", re.I)
_TASK_RE = re.compile(r"^\s*[-*]\s+\[( |x|~|!)\]\s+(.+?)\s*\{#([a-z0-9][a-z0-9-]*)\}\s*$", re.I)
_NEEDS_RE = re.compile(r"^needs:\s*\[([^\]]*)\]\s*$", re.I)
_LINKS_RE = re.compile(r"^links:\s*\[([^\]]*)\]\s*$", re.I)
_FILES_RE = re.compile(r"^files:\s*\[([^\]]*)\]\s*$", re.I)
_TECH_RE = re.compile(r"^\s*tech:\s*(.+?)\s*$", re.I)
_BY_RE = re.compile(r"^\s*by:\s*(.+?)\s*$", re.I)
_FROM_RE = re.compile(r"^\s*(?:from|horizon):\s*(agent|roadmap|now|backlog)\s*$", re.I)
_DECISIONS_RE = re.compile(r"^##\s+decisions\s*$", re.I)

_AGENTTRAIL_PORTS = tuple(range(5330, 5345))
_REGRESSION_WINDOW_MS = 15 * 60 * 1000
_TOUCH_STALE_MS = 5 * 60 * 1000


def _id_list(raw: str) -> list[str]:
    return [x.strip() for x in raw.split(",") if x.strip()]


def parse_plan_md(text: str) -> dict[str, Any]:
    """Parse AgentTrail PLAN.md convention (v2)."""
    nodes: list[dict[str, Any]] = []
    decisions: list[str] = []
    title = ""
    cur_component: Optional[dict[str, Any]] = None
    last_node: Optional[dict[str, Any]] = None
    in_decisions = False

    for raw in (text or "").split("\n"):
        line = raw.rstrip()
        if not title and line.startswith("# "):
            title = line[2:].strip()
            continue
        if _DECISIONS_RE.match(line):
            in_decisions = True
            cur_component = None
            last_node = None
            continue

        m = _NODE_RE.match(line)
        if m:
            in_decisions = False
            cur_component = {
                "id": m.group(2),
                "title": m.group(1),
                "level": "component",
                "parent": None,
                "needs": [],
                "links": [],
                "files": [],
                "tech": "",
                "by": "",
                "status": "pending",
            }
            last_node = cur_component
            nodes.append(cur_component)
            continue

        if in_decisions:
            if re.match(r"^\s*[-*]\s+", line):
                decisions.append(re.sub(r"^\s*[-*]\s+", "", line))
            continue

        m = _TASK_RE.match(line)
        if m:
            mark = m.group(1)
            status = (
                "done"
                if mark == "x"
                else "active"
                if mark == "~"
                else "blocked"
                if mark == "!"
                else "pending"
            )
            last_node = {
                "id": m.group(3),
                "title": m.group(2),
                "level": "task",
                "parent": cur_component["id"] if cur_component else None,
                "needs": [],
                "links": [],
                "tech": "",
                "by": "",
                "src": "",
                "status": status,
            }
            nodes.append(last_node)
            continue

        for rx, key in (
            (_TECH_RE, "tech"),
            (_BY_RE, "by"),
        ):
            m = rx.match(line)
            if m and last_node:
                last_node[key] = m.group(1)
                break
        else:
            m = _FROM_RE.match(line)
            if m and last_node:
                v = m.group(1).lower()
                last_node["src"] = "agent" if v == "now" else "roadmap" if v == "backlog" else v
                continue
            m = _NEEDS_RE.match(line)
            if m and cur_component:
                cur_component["needs"] = _id_list(m.group(1))
                continue
            m = _LINKS_RE.match(line)
            if m and cur_component:
                cur_component["links"] = _id_list(m.group(1))
                continue
            m = _FILES_RE.match(line)
            if m and cur_component:
                cur_component["files"] = _id_list(m.group(1))

    for comp in [n for n in nodes if n.get("level") == "component"]:
        kids = [n for n in nodes if n.get("parent") == comp["id"]]
        if any(k.get("status") == "blocked" for k in kids):
            comp["status"] = "blocked"
        elif any(k.get("status") == "active" for k in kids):
            comp["status"] = "active"
        elif kids and all(k.get("status") == "done" for k in kids):
            comp["status"] = "done"

    return {"nodes": nodes, "decisions": decisions, "title": title}


def resolve_project_folder(baton_home: Path, project_id: str) -> Optional[Path]:
    rec_path = projects_root(baton_home) / project_id / "project.json"
    if not rec_path.is_file():
        return None
    try:
        rec = json.loads(rec_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None
    folder = str(rec.get("folder") or "").strip()
    if folder:
        p = Path(folder).expanduser()
        if p.is_dir():
            return p
    return None


def agenttrail_state_file(repo: Path) -> Path:
    digest = hashlib.sha1(str(repo.resolve()).encode("utf-8")).hexdigest()[:12]
    return Path.home() / ".agenttrail" / f"{digest}.json"



def read_agenttrail_persisted(repo: Path) -> dict[str, Any]:
    path = agenttrail_state_file(repo)
    if not path.is_file():
        return {}
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {}


def probe_agenttrail_sidecar(
    repo: Path,
    *,
    timeout: float = 0.25,
    ports: tuple[int, ...] = _AGENTTRAIL_PORTS,
) -> Optional[dict[str, Any]]:
    """GET / from a running agenttrail daemon bound to this repo."""
    repo_resolved = str(repo.resolve())
    for port in ports:
        url = f"http://127.0.0.1:{port}/"
        try:
            with urllib.request.urlopen(url, timeout=timeout) as resp:
                payload = json.loads(resp.read().decode("utf-8"))
        except (urllib.error.URLError, TimeoutError, json.JSONDecodeError, OSError, ValueError):
            continue
        session = payload.get("session") or {}
        cwd = str(session.get("cwd") or "")
        if cwd and cwd != repo_resolved:
            continue
        if payload.get("planTitle") or payload.get("hasPlan") or payload.get("activity"):
            payload["_port"] = port
            return payload
        # daemon exposes project basename; match folder name when cwd absent
        if session.get("project") == repo.name:
            payload["_port"] = port
            return payload
    return None


def read_baton_agenttrail_meta(baton_home: Path, project_id: str) -> dict[str, Any]:
    path = baton_home / "observability" / "agenttrail" / f"{project_id}.json"
    if not path.is_file():
        return {}
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {}


def read_agentpulse_snapshot(baton_home: Path) -> dict[str, Any]:
    path = baton_home / "observability" / "agentpulse.json"
    if not path.is_file():
        return {}
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {}


def _trajectory_for_project(snapshot: dict[str, Any], project_id: str, folder: Optional[Path]) -> Optional[dict[str, Any]]:
    sessions = snapshot.get("sessions") or snapshot.get("items") or []
    if not isinstance(sessions, list):
        return None
    folder_s = str(folder.resolve()) if folder else ""
    best: Optional[dict[str, Any]] = None
    for row in sessions:
        if not isinstance(row, dict):
            continue
        pid = str(row.get("project_id") or row.get("project") or "").strip()
        cwd = str(row.get("cwd") or row.get("repo") or row.get("root") or "").strip()
        if pid and pid == project_id:
            best = row
            break
        if folder_s and cwd and cwd.startswith(folder_s):
            best = row
    if not best:
        return None
    verdict = str(best.get("verdict") or best.get("state") or "").lower()
    if verdict not in {"stuck", "drifting", "converging", "exploring", "idle", "done"}:
        return None
    return {
        "verdict": verdict,
        "confidence": best.get("confidence"),
        "narrative": str(best.get("narrative") or best.get("summary") or "")[:220],
        "needs_attention": verdict in {"stuck", "drifting"},
    }


def _infer_trajectory_from_events(jobs_dir: Path, job_id: Optional[str], now: datetime) -> Optional[dict[str, Any]]:
    """Lightweight stuck signal when AgentPulse snapshot is absent."""
    if not job_id:
        return None
    events_path = jobs_dir / "events.jsonl"
    if not events_path.is_file():
        return None
    try:
        lines = events_path.read_text(encoding="utf-8").splitlines()[-120:]
    except OSError:
        return None

    recent: list[dict[str, Any]] = []
    for line in lines:
        line = line.strip()
        if not line:
            continue
        try:
            row = json.loads(line)
        except json.JSONDecodeError:
            continue
        if row.get("job_id") != job_id:
            continue
        ts_raw = row.get("ts")
        if not ts_raw:
            continue
        try:
            ts = datetime.fromisoformat(str(ts_raw).replace("Z", "+00:00"))
        except ValueError:
            continue
        if ts.tzinfo is None:
            ts = ts.replace(tzinfo=timezone.utc)
        if (now - ts.astimezone(timezone.utc)).total_seconds() > 1800:
            continue
        recent.append(row)

    if len(recent) < 6:
        return None

    kinds = [str(r.get("kind") or "") for r in recent]
    errors = sum(1 for k in kinds if k in {"error", "failed", "failure"})
    if errors >= 3:
        return {"verdict": "stuck", "confidence": None, "narrative": "Repeated failures in recent job events.", "needs_attention": True}

    sigs = [f"{r.get('kind')}:{r.get('what') or r.get('message') or ''}"[:80] for r in recent[-8:]]
    if len(sigs) >= 5 and len(set(sigs)) <= 2:
        return {"verdict": "stuck", "confidence": None, "narrative": "Job events looping on the same step.", "needs_attention": True}

    return None


def _regressions(
    plan: dict[str, Any],
    comp_touched: dict[str, Any],
    *,
    now_ms: int,
) -> list[dict[str, str]]:
    nodes = plan.get("nodes") or []
    comps = {n["id"]: n for n in nodes if n.get("level") == "component"}
    out: list[dict[str, str]] = []
    for cid, touched_at in (comp_touched or {}).items():
        try:
            ts = int(touched_at)
        except (TypeError, ValueError):
            continue
        if now_ms - ts > _REGRESSION_WINDOW_MS:
            continue
        comp = comps.get(cid)
        if not comp:
            continue
        if comp.get("status") == "done":
            out.append({
                "component_id": cid,
                "title": str(comp.get("title") or cid),
                "reason": "done component touched again",
            })
            continue
        done_tasks = [
            n for n in nodes
            if n.get("parent") == cid and n.get("status") == "done"
        ]
        if done_tasks and ts > now_ms - _REGRESSION_WINDOW_MS:
            out.append({
                "component_id": cid,
                "title": str(comp.get("title") or cid),
                "reason": "activity on component with finished tasks",
            })
    return out[:4]


def _declared_active(plan: dict[str, Any]) -> list[dict[str, str]]:
    rows: list[dict[str, str]] = []
    for n in plan.get("nodes") or []:
        if n.get("status") in {"active", "blocked"}:
            rows.append({
                "id": str(n.get("id") or ""),
                "title": str(n.get("title") or ""),
                "status": str(n.get("status") or ""),
                "level": str(n.get("level") or ""),
            })
    return rows[:5]


def _observed_activity(
    sidecar: Optional[dict[str, Any]],
    persisted: dict[str, Any],
    plan: dict[str, Any],
    *,
    now_ms: int,
) -> dict[str, Any]:
    activity = (sidecar or {}).get("activity") or persisted.get("activity")
    recent = (sidecar or {}).get("recentActivity") or persisted.get("recentActivity") or []
    comp_touched = (sidecar or {}).get("plan") and {
        n["id"]: n.get("touchedAt")
        for n in sidecar.get("plan", [])
        if n.get("level") == "component" and n.get("touchedAt")
    }
    if not comp_touched:
        comp_touched = persisted.get("compTouched") or {}

    live_file = ""
    live_at: Optional[int] = None
    if isinstance(activity, dict):
        live_file = str(activity.get("file") or "")
        try:
            live_at = int(activity.get("at"))
        except (TypeError, ValueError):
            live_at = None

    stale = live_at is None or (now_ms - live_at) > _TOUCH_STALE_MS
    active_comps: list[str] = []
    for cid, ts in (comp_touched or {}).items():
        try:
            t = int(ts)
        except (TypeError, ValueError):
            continue
        if now_ms - t <= _TOUCH_STALE_MS:
            comp = next((n for n in plan.get("nodes", []) if n.get("id") == cid), None)
            if comp:
                active_comps.append(str(comp.get("title") or cid))

    return {
        "live_file": live_file,
        "live_stale": stale,
        "active_components": active_comps[:3],
        "recent_files": [
            str(r.get("file") or "")
            for r in recent[:3]
            if isinstance(r, dict) and r.get("file")
        ],
        "comp_touched": comp_touched or {},
    }


def observability_for_project(
    *,
    baton_home: Path,
    project_id: str,
    jobs_dir: Path,
    job_id: Optional[str] = None,
    now: Optional[datetime] = None,
) -> dict[str, Any]:
    clock = now or datetime.now(timezone.utc)
    if clock.tzinfo is None:
        clock = clock.replace(tzinfo=timezone.utc)
    now_ms = int(clock.timestamp() * 1000)

    folder = resolve_project_folder(baton_home, project_id)
    meta = read_baton_agenttrail_meta(baton_home, project_id)
    sidecar: Optional[dict[str, Any]] = None
    if folder and os.environ.get("BATON_AGENTTRAIL", "1") != "0":
        sidecar = probe_agenttrail_sidecar(folder)
        if not sidecar and meta.get("port"):
            sidecar = probe_agenttrail_sidecar(folder, ports=(int(meta["port"]),))

    plan_text = ""
    plan: dict[str, Any] = {"nodes": [], "decisions": [], "title": ""}
    if folder:
        plan_path = folder / "PLAN.md"
        if plan_path.is_file():
            try:
                plan_text = plan_path.read_text(encoding="utf-8")
                plan = parse_plan_md(plan_text)
            except OSError:
                pass

    persisted = read_agenttrail_persisted(folder) if folder else {}
    observed = _observed_activity(sidecar, persisted, plan, now_ms=now_ms)
    regressions = _regressions(plan, observed.get("comp_touched") or {}, now_ms=now_ms)

    pulse_snap = read_agentpulse_snapshot(baton_home)
    trajectory = _trajectory_for_project(pulse_snap, project_id, folder)
    if trajectory is None:
        trajectory = _infer_trajectory_from_events(jobs_dir, job_id, clock)

    port = (sidecar or {}).get("_port") or meta.get("port")
    map_url = f"http://127.0.0.1:{port}" if port else ""

    has_plan = bool(plan.get("nodes"))
    declared = _declared_active(plan)

    return {
        "enabled": folder is not None,
        "folder": str(folder) if folder else "",
        "has_plan": has_plan,
        "plan_title": str(plan.get("title") or ""),
        "declared": declared,
        "observed": observed,
        "regressions": regressions,
        "trajectory": trajectory,
        "sidecar_live": sidecar is not None,
        "map_url": map_url,
        "blocked_tasks": [d for d in declared if d.get("status") == "blocked"],
    }


def observability_attention_items(
    *,
    baton_home: Path,
    project_id: str,
    project_name: str,
    jobs_dir: Path,
    job_id: Optional[str] = None,
    now: Optional[datetime] = None,
) -> list[dict[str, str]]:
    obs = observability_for_project(
        baton_home=baton_home,
        project_id=project_id,
        jobs_dir=jobs_dir,
        job_id=job_id,
        now=now,
    )
    items: list[dict[str, str]] = []
    traj = obs.get("trajectory") or {}
    if isinstance(traj, dict) and traj.get("needs_attention"):
        items.append({
            "project_id": project_id,
            "label": f"{project_name}: agent {traj.get('verdict', 'stuck')}",
            "pill": "needs-you",
            "kind": "trajectory",
        })
    for reg in obs.get("regressions") or []:
        items.append({
            "project_id": project_id,
            "label": f"{project_name}: revising done — {reg.get('title', 'component')}",
            "pill": "needs-you",
            "kind": "regression",
        })
    for blk in obs.get("blocked_tasks") or []:
        items.append({
            "project_id": project_id,
            "label": f"{project_name}: blocked — {blk.get('title', 'task')}",
            "pill": "needs-you",
            "kind": "blocked",
        })
    return items
