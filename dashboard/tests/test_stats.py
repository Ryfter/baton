from pathlib import Path

import pytest

from dashboard.models.events import DashboardStats
from dashboard.readers.stats import compute_stats


def test_returns_dashboard_stats(journal_file: Path):
    stats = compute_stats(journal_file)
    assert isinstance(stats, DashboardStats)


def test_model_leaderboard_names(journal_file: Path):
    stats = compute_stats(journal_file)
    names = [m.name for m in stats.models]
    assert "claude-sonnet-4-6" in names
    assert "claude-haiku-4-5" in names


def test_model_cost_sonnet(journal_file: Path):
    stats = compute_stats(journal_file)
    sonnet = next(m for m in stats.models if m.name == "claude-sonnet-4-6")
    assert sonnet.calls == 1
    assert sonnet.cost_usd == pytest.approx(0.0231)
    assert sonnet.tokens_in == 3214
    assert sonnet.tokens_out == 892


def test_total_otel_calls(journal_file: Path):
    stats = compute_stats(journal_file)
    assert stats.total_otel_calls == 2


def test_recent_hooks_count(journal_file: Path):
    stats = compute_stats(journal_file)
    assert len(stats.recent_hooks) == 3
    assert stats.recent_hooks[0].target == "bash:ollama run devstral:24b 'Hello'"


def test_ollama_models_populated_elsewhere(journal_file: Path):
    stats = compute_stats(journal_file)
    assert stats.ollama_models == []


def test_missing_journal_returns_zeros():
    stats = compute_stats(Path("/nonexistent/log.md"))
    assert stats.today_cost_usd == 0.0
    assert stats.total_otel_calls == 0
    assert stats.models == []
    assert stats.recent_hooks == []


def test_models_sorted_by_cost_descending(journal_file: Path):
    stats = compute_stats(journal_file)
    costs = [m.cost_usd for m in stats.models]
    assert costs == sorted(costs, reverse=True)
