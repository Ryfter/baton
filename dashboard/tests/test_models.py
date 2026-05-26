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


def test_hook_entry_optional_tags():
    from dashboard.models.events import HookEntry
    e = HookEntry(timestamp=datetime(2026,5,26,11), target='x', duration_s=1, exit_code=0)
    assert e.job_id is None
    assert e.phase is None

    e2 = HookEntry(timestamp=datetime(2026,5,26,11), target='x', duration_s=1, exit_code=0,
                   job_id='j-1', phase='research')
    assert e2.job_id == 'j-1'
    assert e2.phase == 'research'


def test_lesson_entry_fields():
    from dashboard.models.events import LessonEntry
    e = LessonEntry(timestamp=datetime(2026,5,26,11), category='knowledge',
                    text='things', job_id='j-1', phase='research')
    assert e.category == 'knowledge'
    assert e.text == 'things'


def test_job_summary_fields():
    from dashboard.models.events import JobSummary
    s = JobSummary(
        id='j-1', title='t', project='p', current_phase='research',
        status='active', created_at=datetime(2026,5,26,11),
        sprint_count=0, cost_usd=0.0,
    )
    assert s.id == 'j-1'
    assert s.status == 'active'


def test_phase_log_entry_fields():
    from dashboard.models.events import PhaseLogEntry
    e = PhaseLogEntry(timestamp=datetime(2026,5,26,11),
                      kind='transition', detail='research → design')
    assert e.kind == 'transition'


def test_job_detail_fields():
    from dashboard.models.events import JobDetail, JobSummary, PhaseLogEntry, LessonEntry
    summary = JobSummary(
        id='j-1', title='t', project='p', current_phase='research',
        status='active', created_at=datetime(2026,5,26,11),
        sprint_count=0, cost_usd=0.0,
    )
    detail = JobDetail(
        summary=summary,
        brief='hello',
        phase_log=[],
        journal=[],
        lessons=[],
        cost_by_phase={'research': 0.0},
    )
    assert detail.brief == 'hello'
