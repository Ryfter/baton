"""Claude 5h label must be remaining time, never a stub that looks like '5h to reset'."""
from __future__ import annotations

from datetime import datetime, timedelta, timezone
from pathlib import Path

from dashboard.readers.claude_quota import format_remaining, read_claude_quota
from dashboard.readers.maestro_jobs import budget_for


def test_format_remaining_under_an_hour():
    now = datetime(2026, 8, 23, 2, 31, tzinfo=timezone.utc)
    reset = now + timedelta(minutes=47)
    assert format_remaining(reset, now) == "47m"


def test_format_remaining_hours_and_minutes():
    now = datetime(2026, 8, 23, 2, 31, tzinfo=timezone.utc)
    reset = now + timedelta(hours=2, minutes=5)
    assert format_remaining(reset, now) == "2h 5m"


def test_budget_for_never_says_empty_until_reset(tmp_path: Path):
    budget = budget_for(tmp_path)
    assert budget.get("claude_5h") != "empty-until-reset"
    assert "5h to reset" not in str(budget.get("claude_5h") or "")


def test_read_quota_snapshot_shows_minutes_left(tmp_path: Path):
    now = datetime(2026, 8, 23, 8, 31, tzinfo=timezone.utc)
    reset = now + timedelta(minutes=42)
    (tmp_path / "claude-quota.json").write_text(
        '{"schema":1,"observed_at":"2026-08-23T08:30:00Z",'
        f'"five_hour":{{"used_pct":100,"resets_at":"{reset.isoformat()}"}}}}\n',
        encoding="utf-8",
    )
    q = read_claude_quota(tmp_path, now=now)
    assert q["five_hour_label"] == "empty · resets in 42m"
    assert "empty-until-reset" not in q["five_hour_label"]


def test_read_quota_accepts_unix_reset_from_statusline(tmp_path: Path):
    now = datetime(2026, 8, 23, 8, 31, tzinfo=timezone.utc)
    reset = now + timedelta(minutes=19)
    (tmp_path / "claude-quota.json").write_text(
        '{"schema":1,"five_hour":{"used_pct":100,"resets_at_unix":"%d"}}\n'
        % int(reset.timestamp()),
        encoding="utf-8",
    )
    q = read_claude_quota(tmp_path, now=now)
    assert q["five_hour_label"] == "empty · resets in 19m"


def test_budget_for_uses_snapshot(tmp_path: Path):
    now = datetime(2026, 8, 23, 8, 31, tzinfo=timezone.utc)
    reset = now + timedelta(minutes=18)
    (tmp_path / "claude-quota.json").write_text(
        '{"schema":1,"five_hour":{"used_pct":88,'
        f'"resets_at":"{reset.isoformat()}"}}}}\n',
        encoding="utf-8",
    )
    budget = budget_for(tmp_path, now=now)
    assert budget["claude_5h"] == "88% · resets in 18m"
