"""Aggregate command-center metrics for the home hero strip."""
from __future__ import annotations

from pathlib import Path

from dashboard.readers.dark_factory import read_dark_factory_board
from dashboard.readers.mydashboard_intel import read_mydashboard_intel
from dashboard.readers.stats import compute_stats


def read_command_hero(baton_home: Path, journal_path: Path) -> dict:
    stats = compute_stats(journal_path)
    factory = read_dark_factory_board(baton_home)
    intel = read_mydashboard_intel()
    active = (
        int(factory.get("running") or 0)
        + int(factory.get("admitted") or 0)
        + int(factory.get("queued") or 0)
    )
    return {
        "spend_today_usd": stats.today_cost_usd,
        "otel_calls": stats.total_otel_calls,
        "jobs_total": factory.get("jobs_total") or 0,
        "jobs_running": factory.get("running") or 0,
        "jobs_queued": factory.get("queued") or 0,
        "jobs_active": active,
        "curriculum_shipped": factory.get("curriculum_shipped") or 0,
        "curriculum_pending": factory.get("curriculum_pending") or 0,
        "security_due": factory.get("security_count") or 0,
        "primary_seat": "openrouter-glm",
        "mode": "Dark factory L4",
        "mydashboard_url": intel.get("url") or "http://127.0.0.1:8765",
    }
