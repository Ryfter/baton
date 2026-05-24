from datetime import datetime

import pytest

from dashboard.models.events import (
    DashboardStats,
    HookEntry,
    OllamaModel,
    OtelEntry,
)


def test_hook_entry_fields():
    e = HookEntry(
        timestamp=datetime(2026, 5, 23, 10, 0, 0),
        target="bash:ollama run devstral:24b 'Hello'",
        duration_s=2,
        exit_code=0,
    )
    assert e.target == "bash:ollama run devstral:24b 'Hello'"
    assert e.duration_s == 2
    assert e.exit_code == 0
    assert e.brief is None


def test_hook_entry_with_brief():
    e = HookEntry(
        timestamp=datetime(2026, 5, 23, 10, 25, 0),
        target="agent:claude-subagent",
        duration_s=0,
        exit_code=0,
        brief="spec review task",
    )
    assert e.brief == "spec review task"


def test_otel_entry_fields():
    e = OtelEntry(
        timestamp=datetime(2026, 5, 23, 10, 5, 0),
        model="claude-sonnet-4-6",
        input_tokens=3214,
        output_tokens=892,
        cost_usd=0.0231,
    )
    assert e.model == "claude-sonnet-4-6"
    assert e.cost_usd == pytest.approx(0.0231)


def test_ollama_model_fields():
    e = OllamaModel(name="devstral:24b", status="running", size="14GB")
    assert e.name == "devstral:24b"
    assert e.status == "running"
    assert e.size == "14GB"


def test_dashboard_stats_defaults():
    s = DashboardStats(
        today_cost_usd=0.0,
        total_otel_calls=0,
        models=[],
        recent_hooks=[],
        ollama_models=[],
        last_updated=datetime(2026, 5, 23, 10, 0, 0),
    )
    assert s.today_cost_usd == 0.0
    assert s.models == []
    assert s.ollama_models == []
