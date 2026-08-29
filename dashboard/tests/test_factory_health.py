"""Factory health alerts for Gauges banner."""
from __future__ import annotations

from datetime import datetime, timezone
from pathlib import Path

from dashboard.readers.factory_health import read_factory_health_alerts


def test_empty_alerts_when_no_active_projects(tmp_path: Path):
    (tmp_path / "projects").mkdir(parents=True, exist_ok=True)
    health = read_factory_health_alerts(
        baton_home=tmp_path,
        runs_root=tmp_path / "runs",
        now=datetime(2026, 8, 24, 12, 0, tzinfo=timezone.utc),
    )
    assert health["has_alerts"] is False
    assert health["loops"] == []
    assert health["regressions"] == []
