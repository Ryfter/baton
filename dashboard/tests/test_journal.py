from pathlib import Path

import pytest

from dashboard.models.events import HookEntry, NoteEntry, OtelEntry
from dashboard.readers.journal import parse_journal_line, read_journal


def test_parse_bash_hook_line():
    line = "2026-05-23T10:00:00-06:00 | hook | bash:ollama run devstral:24b 'Hello' | 2s | exit:0"
    entry = parse_journal_line(line)
    assert isinstance(entry, HookEntry)
    assert entry.target == "bash:ollama run devstral:24b 'Hello'"
    assert entry.duration_s == 2
    assert entry.exit_code == 0
    assert entry.brief is None


def test_parse_agent_hook_line():
    line = '2026-05-23T10:25:00-06:00 | hook | agent:claude-subagent | 0s | exit:0 | "spec review task"'
    entry = parse_journal_line(line)
    assert isinstance(entry, HookEntry)
    assert entry.target == "agent:claude-subagent"
    assert entry.duration_s == 0
    assert entry.exit_code == 0
    assert entry.brief == "spec review task"


def test_parse_otel_line():
    line = "2026-05-23T10:05:00-06:00 | otel | claude-sonnet-4-6 | in:3214 out:892 | $0.0231 | api_request"
    entry = parse_journal_line(line)
    assert isinstance(entry, OtelEntry)
    assert entry.model == "claude-sonnet-4-6"
    assert entry.input_tokens == 3214
    assert entry.output_tokens == 892
    assert entry.cost_usd == pytest.approx(0.0231)


def test_parse_note_line():
    line = '2026-05-23T10:10:00-06:00 | note | devstral | "used for smoke test"'
    entry = parse_journal_line(line)
    assert isinstance(entry, NoteEntry)
    assert entry.target == "devstral"
    assert entry.text == "used for smoke test"


def test_skip_header_lines():
    assert parse_journal_line("# Model Routing Log") is None
    assert parse_journal_line("") is None
    assert parse_journal_line("## Activity") is None
    assert parse_journal_line("> append-only journal") is None


def test_skip_dashboard_and_unknown_lines():
    assert (
        parse_journal_line(
            "2026-05-23T10:30:00-06:00 | dashboard | ollama:stop-all | devstral:24b"
        )
        is None
    )
    assert parse_journal_line("2026-05-23T10:30:00-06:00 | other | value") is None


def test_read_journal_counts(journal_file: Path):
    entries = read_journal(journal_file)
    assert len(entries) == 6
    hooks = [e for e in entries if isinstance(e, HookEntry)]
    otels = [e for e in entries if isinstance(e, OtelEntry)]
    notes = [e for e in entries if isinstance(e, NoteEntry)]
    assert len(hooks) == 3
    assert len(otels) == 2
    assert len(notes) == 1


def test_read_journal_missing_file():
    entries = read_journal(Path("/nonexistent/path.md"))
    assert entries == []


def test_parse_tagged_hook_line():
    from dashboard.readers.journal import parse_journal_line
    from dashboard.models.events import HookEntry
    line = '2026-05-26T11:00:00-06:00 | hook | bash:ollama list | 1s | exit:0 | job:j-foo | phase:research'
    e = parse_journal_line(line)
    assert isinstance(e, HookEntry)
    assert e.target == 'bash:ollama list'
    assert e.job_id == 'j-foo'
    assert e.phase == 'research'
    assert e.brief is None


def test_parse_tagged_hook_with_brief():
    from dashboard.readers.journal import parse_journal_line
    from dashboard.models.events import HookEntry
    line = '2026-05-26T11:00:00-06:00 | hook | agent:Explore | 12s | exit:0 | "find patterns" | job:j-foo | phase:research'
    e = parse_journal_line(line)
    assert isinstance(e, HookEntry)
    assert e.brief == 'find patterns'
    assert e.job_id == 'j-foo'
    assert e.phase == 'research'


def test_parse_tagged_otel_line():
    from dashboard.readers.journal import parse_journal_line
    from dashboard.models.events import OtelEntry
    line = '2026-05-26T11:05:00-06:00 | otel | claude-sonnet-4-6 | in:100 out:50 | $0.0011 | api_request | job:j-foo | phase:research'
    e = parse_journal_line(line)
    assert isinstance(e, OtelEntry)
    assert e.job_id == 'j-foo'
    assert e.phase == 'research'


def test_parse_lesson_line():
    from dashboard.readers.journal import parse_journal_line
    from dashboard.models.events import LessonEntry
    line = '2026-05-26T11:20:00-06:00 | lesson | knowledge | "Feature flags split into release vs ops" | job:j-foo | phase:research'
    e = parse_journal_line(line)
    assert isinstance(e, LessonEntry)
    assert e.category == 'knowledge'
    assert 'release vs ops' in e.text
    assert e.job_id == 'j-foo'


def test_untagged_lines_still_parse():
    # Plan 1/2 format with no trailing tags must still work
    from dashboard.readers.journal import parse_journal_line
    from dashboard.models.events import HookEntry
    line = '2026-05-23T10:00:00-06:00 | hook | bash:ollama list | 2s | exit:0'
    e = parse_journal_line(line)
    assert isinstance(e, HookEntry)
    assert e.job_id is None
    assert e.phase is None
