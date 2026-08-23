"""Project economics — policy C savings."""
from __future__ import annotations

from datetime import datetime, timedelta, timezone
from pathlib import Path

from dashboard.readers.maestro_jobs import create_job, maestro_root
from dashboard.readers.project_economics import economics_for_projects


def _write_journal(path: Path, lines: list[str]) -> None:
    path.write_text("# log\n\n" + "\n".join(lines) + "\n", encoding="utf-8")


def test_free_tier_shows_savings(tmp_path: Path):
    now = datetime(2026, 8, 23, 7, 40, tzinfo=timezone.utc)
    reset = now + timedelta(hours=2)
    fleet = tmp_path / "fleet.yaml"
    fleet.write_text(
        "providers:\n"
        "  - name: openrouter-ox-alpha\n"
        "    kind: http\n"
        "    enabled: true\n"
        "    cost_tier: free\n"
        "    model_default: ox-alpha\n",
        encoding="utf-8",
    )
    (tmp_path / "claude-quota.json").write_text(
        f'{{"five_hour":{{"resets_at":"{reset.isoformat()}"}}}}',
        encoding="utf-8",
    )
    mj = maestro_root(tmp_path)
    mj.mkdir(parents=True)
    job = create_job(mj, project="baton", goal="test", provider="openrouter-ox-alpha")
    inside = now - timedelta(minutes=20)
    journal = tmp_path / "model-routing-log.md"
    _write_journal(
        journal,
        [f"{inside.isoformat()} | otel | ox-alpha | in:100000 out:50000 | $0.00 | api | job:{job['id']}"],
    )
    econ = economics_for_projects(
        journal_path=journal,
        baton_home=tmp_path,
        jobs_root=tmp_path / "jobs",
        now=now,
    )
    assert econ["baton"]["total_tokens"] == 150000
    assert econ["baton"]["savings_usd"] is not None
    assert econ["baton"]["savings_usd"] > 0
