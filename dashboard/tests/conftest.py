import pytest
from pathlib import Path
from unittest.mock import patch
from typing import Optional

SAMPLE_JOURNAL = """\
# Model Routing Log

## Activity

2026-05-23T10:00:00-06:00 | hook | bash:ollama run devstral:24b 'Hello' | 2s | exit:0
2026-05-23T10:05:00-06:00 | otel | claude-sonnet-4-6 | in:3214 out:892 | $0.0231 | api_request
2026-05-23T10:10:00-06:00 | note | devstral | "used for smoke test"
2026-05-23T10:15:00-06:00 | otel | claude-haiku-4-5 | in:512 out:128 | $0.0011 | api_request
2026-05-23T10:20:00-06:00 | hook | bash:ollama run llava 'describe image' | 5s | exit:0
2026-05-23T10:25:00-06:00 | hook | agent:claude-subagent | 0s | exit:0 | "spec review task"
"""


@pytest.fixture(autouse=True)
def no_lms_network():
    """Prevent any test from hitting localhost:1234 — keeps the suite fast."""
    with patch("dashboard.readers.stats._get_lms_models", return_value=[]):
        yield


@pytest.fixture
def journal_file(tmp_path: Path) -> Path:
    p = tmp_path / "model-routing-log.md"
    p.write_text(SAMPLE_JOURNAL, encoding="utf-8")
    return p


@pytest.fixture
def jobs_root(tmp_path: Path) -> Path:
    """Two fake jobs under a temporary jobs root."""
    root = tmp_path / 'jobs'
    root.mkdir()

    # Active job
    j1 = root / 'j-2026-05-26-feature-flags'
    j1.mkdir()
    (j1 / 'manifest.yaml').write_text(
        'id: j-2026-05-26-feature-flags\n'
        'title: "build a feature flag system"\n'
        'project: baton\n'
        'status: active\n'
        'current_phase: research\n'
        'created_at: 2026-05-26T11:00:00-06:00\n'
        'phase_started_at: 2026-05-26T11:00:00-06:00\n'
        'sprint_count: 0\n'
        'last_updated: 2026-05-26T11:00:00-06:00\n',
        encoding='utf-8',
    )
    (j1 / 'brief.md').write_text('# Brief\n\nbuild a feature flag system', encoding='utf-8')
    (j1 / 'phase-log.md').write_text(
        '# Phase Log\n\n'
        '2026-05-26T11:00:00-06:00 | created | research\n'
        '2026-05-26T11:35:00-06:00 | transition | research → design\n',
        encoding='utf-8',
    )
    (j1 / 'lessons.md').write_text(
        '# Lessons\n\n## research\n'
        '2026-05-26T11:20:00-06:00 | knowledge | "Feature flags split into release vs ops"\n',
        encoding='utf-8',
    )

    # Done job
    j2 = root / 'j-2026-05-20-logging-fix'
    j2.mkdir()
    (j2 / 'manifest.yaml').write_text(
        'id: j-2026-05-20-logging-fix\n'
        'title: "fix logging"\n'
        'project: baton\n'
        'status: done\n'
        'current_phase: done\n'
        'created_at: 2026-05-20T11:00:00-06:00\n'
        'phase_started_at: 2026-05-20T11:00:00-06:00\n'
        'sprint_count: 1\n'
        'last_updated: 2026-05-20T15:00:00-06:00\n',
        encoding='utf-8',
    )
    (j2 / 'brief.md').write_text('# Brief\n\nfix logging', encoding='utf-8')
    (j2 / 'phase-log.md').write_text('# Phase Log\n', encoding='utf-8')
    (j2 / 'lessons.md').write_text('# Lessons\n', encoding='utf-8')

    return root


@pytest.fixture
def tagged_journal_file(tmp_path: Path) -> Path:
    """Journal containing tagged + untagged lines spanning two jobs."""
    content = (
        '# Model Routing Log\n\n'
        # untagged Plan 1/2 lines
        '2026-05-22T09:00:00-06:00 | hook | bash:ollama list | 1s | exit:0\n'
        # tagged Plan 3 lines for j-2026-05-26-feature-flags
        '2026-05-26T11:00:00-06:00 | hook | bash:ollama run devstral | 2s | exit:0 | job:j-2026-05-26-feature-flags | phase:research\n'
        '2026-05-26T11:05:00-06:00 | otel | claude-sonnet-4-6 | in:3214 out:892 | $0.0231 | api_request | job:j-2026-05-26-feature-flags | phase:research\n'
        '2026-05-26T11:36:00-06:00 | otel | claude-sonnet-4-6 | in:1000 out:500 | $0.0150 | api_request | job:j-2026-05-26-feature-flags | phase:design\n'
        '2026-05-26T11:20:00-06:00 | lesson | knowledge | "release vs ops toggles" | job:j-2026-05-26-feature-flags | phase:research\n'
        # tagged line for the other job
        '2026-05-20T13:00:00-06:00 | otel | claude-sonnet-4-6 | in:200 out:100 | $0.0040 | api_request | job:j-2026-05-20-logging-fix | phase:code.sprint-1\n'
    )
    p = tmp_path / 'log.md'
    p.write_text(content, encoding='utf-8')
    return p


@pytest.fixture
def runs_root(tmp_path: Path) -> Path:
    """Two fake runs + a global index under a temporary runs root."""
    import json
    root = tmp_path / "runs"
    root.mkdir()

    r1 = root / "run_auth-rewrite"
    r1.mkdir()
    (r1 / "run.json").write_text(json.dumps({
        "id": "run_auth-rewrite", "name": "auth-rewrite",
        "model": "claude-opus-4-8", "reasoning": "high",
        "project": "baton", "tree": "master", "worktree": False,
        "status": "running", "context_pct": 10, "cost_usd": 12.40,
        "tokens_in": 41000, "tokens_out": 7000, "files_touched": ["auth.ts"],
        "current_step": "implement grace window", "parked_question": None,
        "started_at": "2026-06-06T03:14:00+00:00", "updated_at": "2026-06-06T03:31:00+00:00",
    }), encoding="utf-8")
    (r1 / "events.jsonl").write_text(
        '{"ts":"2026-06-06T03:15:00+00:00","kind":"action","what":"read auth middleware","why":"map blast radius","status":"done"}\n'
        '{"ts":"2026-06-06T03:20:00+00:00","kind":"action","what":"wrote failing test","why":"lock the contract","status":"done"}\n',
        encoding="utf-8",
    )

    r2 = root / "run_fix-login"
    r2.mkdir()
    (r2 / "run.json").write_text(json.dumps({
        "id": "run_fix-login", "name": "fix-login", "model": "codex",
        "project": "baton", "tree": "wt/fix-14", "worktree": True,
        "status": "needs-you", "context_pct": 22, "cost_usd": 0.40,
        "parked_question": "rotate tokens without invalidating logins?",
        "updated_at": "2026-06-06T03:25:00+00:00",
    }), encoding="utf-8")
    (r2 / "events.jsonl").write_text(
        '{"ts":"2026-06-06T03:25:00+00:00","kind":"question","what":"rotate tokens without invalidating logins?","why":"two strategies","status":"open"}\n',
        encoding="utf-8",
    )

    (root / "index.json").write_text(json.dumps({
        "rate_limit_pct": 37, "rate_limit_resets_at": "21:30",
        "spend_today_usd": 128.64, "active_runs": 2,
    }), encoding="utf-8")
    return root
