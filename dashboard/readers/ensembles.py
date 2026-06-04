"""Reader for live fleet ensemble runs (Plan 10 cockpit).

Scans ensemble output directories for the run-level `_ensemble.json` manifest
(written by scripts/fleet-ensemble.ps1) plus per-task `<label>.live.json`
heartbeat files. Produces a structure the dashboard polls to render every
provider running concurrently in real time.

State model
----------
- A child process writes `<label>.live.json` = {state:running, started} the
  instant it starts, then overwrites it with a terminal record
  {state:done|error, started, ended, duration_s, exit} when it finishes.
- The parent writes `_ensemble.json` (state=running) at launch and rewrites it
  (state=done) at completion.
- A run whose manifest still says `running` but whose directory has not been
  touched within (timeout_s + grace) seconds is reported as `stale` — the
  parent likely crashed, so we stop animating it as live.
"""
from __future__ import annotations

import json
from datetime import datetime, timezone
from pathlib import Path

_GRACE_S = 60
_PROVIDER_PREVIEW_CHARS = 500
_SYNTHESIS_PREVIEW_CHARS = 1200


def _read_json(path: Path):
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return None


def _preview(path: Path, limit: int) -> tuple[str, bool]:
    """Return (truncated-text, was_truncated) for a .md file, or ('', False) if
    absent/empty. Powers the cockpit's partial-content + synthesis previews."""
    try:
        text = path.read_text(encoding="utf-8").strip()
    except Exception:
        return "", False
    if not text:
        return "", False
    if len(text) > limit:
        return text[:limit].rstrip(), True
    return text, False


def _parse_ts(value):
    if not value:
        return None
    try:
        return datetime.fromisoformat(str(value).replace("Z", "+00:00"))
    except Exception:
        return None


def _now() -> datetime:
    return datetime.now(timezone.utc)


def _elapsed_s(start: datetime | None, end: datetime | None = None) -> int:
    if start is None:
        return 0
    ref = end or _now()
    if start.tzinfo is None:
        start = start.replace(tzinfo=timezone.utc)
    if ref.tzinfo is None:
        ref = ref.replace(tzinfo=timezone.utc)
    return max(0, int((ref - start).total_seconds()))


def _human_ts(dt: datetime | None) -> str:
    if dt is None:
        return "—"
    return dt.astimezone().strftime("%H:%M:%S")


def _provider_states(run_dir: Path, tasks: list[dict], run_running: bool) -> list[dict]:
    out: list[dict] = []
    for t in tasks:
        label = t.get("label") or t.get("provider") or "?"
        provider = t.get("provider") or label
        # Partial content: a provider's <label>.md appears the instant that child
        # finishes (done/error/timeout), independently of its siblings — this is
        # what makes responses show up "as they arrive" (#26).
        preview, preview_trunc = _preview(run_dir / f"{label}.md", _PROVIDER_PREVIEW_CHARS)
        live = _read_json(run_dir / f"{label}.live.json")
        if live:
            state = live.get("state", "running")
            started = _parse_ts(live.get("started"))
            ended = _parse_ts(live.get("ended"))
            dur = live.get("duration_s")
            if dur is None:
                dur = _elapsed_s(started, ended)
            out.append({
                "label": label,
                "provider": provider,
                "state": state,
                "duration_s": int(dur),
                "live": state == "running",
                "preview": preview,
                "preview_truncated": preview_trunc,
            })
        else:
            # No heartbeat yet: queued if the run is still live, else unknown.
            out.append({
                "label": label,
                "provider": provider,
                "state": "queued" if run_running else "unknown",
                "duration_s": 0,
                "live": False,
                "preview": preview,
                "preview_truncated": preview_trunc,
            })
    return out


def _derive_legacy(run_dir: Path) -> dict | None:
    """Runs that predate live-status (no _ensemble.json): infer a done run from .md files."""
    md_files = [p for p in run_dir.glob("*.md") if not p.name.startswith("_")]
    if not md_files:
        return None
    providers = []
    for p in sorted(md_files):
        label = p.stem
        providers.append({"label": label, "provider": label, "state": "done",
                          "duration_s": 0, "live": False})
    for p in providers:
        prev, trunc = _preview(run_dir / f"{p['label']}.md", _PROVIDER_PREVIEW_CHARS)
        p["preview"], p["preview_truncated"] = prev, trunc
    mtime = datetime.fromtimestamp(run_dir.stat().st_mtime, tz=timezone.utc)
    synthesis, synthesis_trunc = _preview(run_dir / "synthesis.md", _SYNTHESIS_PREVIEW_CHARS)
    return {
        "run_id": run_dir.name,
        "kind": "legacy",
        "prompt": "",
        "state": "done",
        "started_human": _human_ts(mtime),
        "started_sort": mtime.timestamp(),
        "elapsed_s": 0,
        "providers": providers,
        "counts": {"running": 0, "done": len(providers), "error": 0, "queued": 0},
        "synthesis": synthesis,
        "synthesis_truncated": synthesis_trunc,
    }


def _build_run(run_dir: Path, meta: dict | None) -> dict | None:
    if meta is None:
        return _derive_legacy(run_dir)

    tasks = meta.get("tasks", [])
    declared_running = meta.get("state") == "running"
    providers = _provider_states(run_dir, tasks, declared_running)

    started = _parse_ts(meta.get("started"))
    ended = _parse_ts(meta.get("ended"))

    state = meta.get("state", "done")
    if state == "running":
        # Staleness guard: parent may have died without rewriting the manifest.
        timeout_s = int(meta.get("timeout_s", 300))
        touched = datetime.fromtimestamp(run_dir.stat().st_mtime, tz=timezone.utc)
        if _elapsed_s(touched) > timeout_s + _GRACE_S:
            state = "stale"

    counts = {"running": 0, "done": 0, "error": 0, "queued": 0}
    for p in providers:
        key = p["state"] if p["state"] in counts else "error" if p["state"] in ("timeout",) else "queued"
        counts[key] = counts.get(key, 0) + 1

    synthesis, synthesis_trunc = _preview(run_dir / "synthesis.md", _SYNTHESIS_PREVIEW_CHARS)
    return {
        "run_id": meta.get("run_id", run_dir.name),
        "kind": meta.get("kind", "ensemble"),
        "prompt": meta.get("prompt", ""),
        "state": state,
        "started_human": _human_ts(started),
        "started_sort": (started.timestamp() if started else run_dir.stat().st_mtime),
        "elapsed_s": _elapsed_s(started, ended if state != "running" else None),
        "providers": providers,
        "counts": counts,
        "synthesis": synthesis,
        "synthesis_truncated": synthesis_trunc,
    }


def read_ensembles(root: Path, recent_limit: int = 6) -> dict:
    """Return {'active': [...running runs...], 'recent': [...finished runs...]}."""
    if not root or not Path(root).exists():
        return {"active": [], "recent": []}
    runs: list[dict] = []
    for d in sorted(Path(root).iterdir()):
        if not d.is_dir():
            continue
        run = _build_run(d, _read_json(d / "_ensemble.json"))
        if run:
            runs.append(run)
    runs.sort(key=lambda r: r["started_sort"], reverse=True)
    active = [r for r in runs if r["state"] == "running"]
    recent = [r for r in runs if r["state"] != "running"][:recent_limit]
    return {"active": active, "recent": recent}
