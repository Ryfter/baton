"""Read-only snapshot from ~/Dev/MyDashboard for the Baton command center."""
from __future__ import annotations

import os
import re
import sqlite3
from pathlib import Path
from typing import Any, Optional


def mydashboard_root() -> Optional[Path]:
    env = os.environ.get("MYDASHBOARD_ROOT", "").strip()
    if env:
        p = Path(env).expanduser()
        if p.is_dir():
            return p
    for candidate in (
        Path.home() / "Dev" / "MyDashboard",
        Path.home() / "dev" / "MyDashboard",
    ):
        if candidate.is_dir():
            return candidate
    return None


def _settings_scalar(settings_path: Path, key: str) -> Optional[str]:
    if not settings_path.is_file():
        return None
    pat = re.compile(rf"^{re.escape(key)}:\s*(.+?)\s*(?:#.*)?$")
    for line in settings_path.read_text(encoding="utf-8").splitlines():
        m = pat.match(line.strip())
        if m:
            return m.group(1).strip().strip("'\"")
    return None


def _db_path(root: Path) -> Path:
    raw = os.environ.get("MYDASHBOARD_DB", "").strip()
    if raw:
        p = Path(raw).expanduser()
        return p if p.is_absolute() else root / p
    rel = _settings_scalar(root / "config" / "settings.yaml", "db_path") or "data/mydashboard.db"
    p = Path(rel)
    return p if p.is_absolute() else root / p


def _board_url(root: Path) -> str:
    override = os.environ.get("MYDASHBOARD_URL", "").strip()
    if override:
        return override.rstrip("/")
    host = _settings_scalar(root / "config" / "settings.yaml", "host") or "127.0.0.1"
    port = _settings_scalar(root / "config" / "settings.yaml", "port") or "8765"
    return f"http://{host}:{port}"


def _top_topics(conn: sqlite3.Connection, window: str = "1d", limit: int = 6) -> list[dict[str, Any]]:
    row = conn.execute(
        "SELECT MAX(run_at) FROM topic_scores WHERE window = ?",
        (window,),
    ).fetchone()
    if not row or not row[0]:
        return []
    latest = row[0]
    rows = conn.execute(
        """
        SELECT t.id, t.slug, t.title, ts.viral_score, ts.velocity, ts.heat
        FROM topic_scores ts
        JOIN topics t ON t.id = ts.topic_id
        WHERE ts.window = ? AND ts.run_at = ?
        ORDER BY ts.viral_score DESC, ts.velocity DESC
        LIMIT ?
        """,
        (window, latest, limit),
    ).fetchall()
    out: list[dict[str, Any]] = []
    for tid, slug, title, viral, velocity, heat in rows:
        out.append(
            {
                "id": tid,
                "slug": slug,
                "title": title,
                "viral_score": float(viral or 0),
                "velocity": float(velocity or 0),
                "heat": float(heat or 0),
            }
        )
    return out


def _counts(conn: sqlite3.Connection) -> dict[str, int]:
    topics = conn.execute("SELECT COUNT(*) FROM topics").fetchone()
    items = conn.execute("SELECT COUNT(*) FROM items").fetchone()
    return {
        "topics": int(topics[0] if topics else 0),
        "items": int(items[0] if items else 0),
    }


def read_mydashboard_intel() -> dict[str, Any]:
    root = mydashboard_root()
    if not root:
        return {
            "available": False,
            "root": None,
            "url": None,
            "topics": [],
            "counts": {"topics": 0, "items": 0},
            "window": "1d",
            "error": "MyDashboard folder not found",
        }

    db = _db_path(root)
    url = _board_url(root)
    if not db.is_file():
        return {
            "available": False,
            "root": str(root),
            "url": url,
            "topics": [],
            "counts": {"topics": 0, "items": 0},
            "window": "1d",
            "error": f"No database at {db}",
        }

    try:
        conn = sqlite3.connect(f"file:{db}?mode=ro", uri=True, timeout=2.0)
        try:
            topics = _top_topics(conn)
            counts = _counts(conn)
        finally:
            conn.close()
    except sqlite3.Error as exc:
        return {
            "available": False,
            "root": str(root),
            "url": url,
            "topics": [],
            "counts": {"topics": 0, "items": 0},
            "window": "1d",
            "error": str(exc),
        }

    return {
        "available": True,
        "root": str(root),
        "url": url,
        "topics": topics,
        "counts": counts,
        "window": "1d",
        "error": None,
    }
