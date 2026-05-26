import pytest
from pathlib import Path
from datetime import datetime

from dashboard.readers.jobs import (
    list_job_summaries,
    read_job_detail,
)


def test_list_active_jobs(jobs_root: Path, tagged_journal_file: Path):
    summaries = list_job_summaries(jobs_root, tagged_journal_file, status_filter='active')
    assert len(summaries) == 1
    assert summaries[0].id == 'j-2026-05-26-feature-flags'
    assert summaries[0].current_phase == 'research'


def test_list_all_jobs_sorted_newest_first(jobs_root: Path, tagged_journal_file: Path):
    summaries = list_job_summaries(jobs_root, tagged_journal_file, status_filter='all')
    assert len(summaries) == 2
    assert summaries[0].id == 'j-2026-05-26-feature-flags'   # newer first
    assert summaries[1].id == 'j-2026-05-20-logging-fix'


def test_summary_cost_aggregation(jobs_root: Path, tagged_journal_file: Path):
    summaries = list_job_summaries(jobs_root, tagged_journal_file, status_filter='all')
    by_id = {s.id: s for s in summaries}
    # j-2026-05-26-feature-flags has two otel entries: $0.0231 + $0.0150
    assert by_id['j-2026-05-26-feature-flags'].cost_usd == pytest.approx(0.0381)
    assert by_id['j-2026-05-20-logging-fix'].cost_usd == pytest.approx(0.0040)


def test_job_detail_loads_brief_phase_log_lessons(jobs_root: Path, tagged_journal_file: Path):
    detail = read_job_detail(jobs_root, tagged_journal_file, 'j-2026-05-26-feature-flags')
    assert detail.brief.strip().endswith('build a feature flag system')
    assert len(detail.phase_log) == 2
    assert detail.phase_log[1].detail == 'research → design'
    assert len(detail.lessons) == 1
    assert 'release vs ops' in detail.lessons[0].text


def test_job_detail_filters_journal_by_job_id(jobs_root: Path, tagged_journal_file: Path):
    detail = read_job_detail(jobs_root, tagged_journal_file, 'j-2026-05-26-feature-flags')
    # Journal should NOT include the untagged Plan 1 line, NOR the j-2026-05-20-* line
    assert all(getattr(e, 'job_id', None) == 'j-2026-05-26-feature-flags' for e in detail.journal)
    assert len(detail.journal) == 4   # 1 hook + 2 otel + 1 lesson


def test_job_detail_cost_by_phase(jobs_root: Path, tagged_journal_file: Path):
    detail = read_job_detail(jobs_root, tagged_journal_file, 'j-2026-05-26-feature-flags')
    assert detail.cost_by_phase['research'] == pytest.approx(0.0231)
    assert detail.cost_by_phase['design']   == pytest.approx(0.0150)


def test_unknown_job_id_raises(jobs_root: Path, tagged_journal_file: Path):
    with pytest.raises(FileNotFoundError):
        read_job_detail(jobs_root, tagged_journal_file, 'j-nope')
