"""Plan 7: tests for dashboard/readers/projects.py."""
from __future__ import annotations

from pathlib import Path

from dashboard.readers.projects import (
    discover_projects,
    read_project_cost,
    read_project_decisions,
    read_project_detail,
    read_project_ensembles,
)


def _setup_project(kb_root: Path, project_id: str, *,
                   title: str | None = None,
                   cost_total: float | None = None,
                   decisions: list[tuple[str, str, str]] | None = None) -> Path:
    """Create a synthetic project tree. Returns the project dir."""
    pdir = kb_root / 'projects' / project_id
    pdir.mkdir(parents=True, exist_ok=True)
    if title:
        (pdir / 'decision-guidance.md').write_text(
            f"# {title}\n\nGuidance body.\n", encoding='utf-8'
        )
    if cost_total is not None:
        (pdir / 'cost.md').write_text(
            f"**Current total: ${cost_total:.2f}** (as of 2026-05-30)\n\n"
            "| Date | Total | Delta | Source | Note |\n"
            "|---|---|---|---|---|\n"
            f"| 2026-05-30 | ${cost_total:.2f} | +${cost_total:.2f} | seed | initial |\n",
            encoding='utf-8'
        )
    if decisions:
        ddir = pdir / 'decisions'
        ddir.mkdir(exist_ok=True)
        for did, title, conf in decisions:
            (ddir / f'{did}-{title.lower().replace(" ", "-")}.md').write_text(
                f"---\nid: {did}\ntimestamp: 2026-05-30T10:00:00+00:00\nproject: {project_id}\n"
                f"job: null\nphase: null\nstatus: active\nconfidence: {conf}\n"
                f"revisit-if: \"never\"\nflag: null\n---\n\n# {title}\n",
                encoding='utf-8'
            )
    return pdir


def _setup_job(jobs_root: Path, job_id: str, project_id: str, status: str = 'active') -> Path:
    jdir = jobs_root / job_id
    jdir.mkdir(parents=True, exist_ok=True)
    (jdir / 'manifest.yaml').write_text(
        f"id: {job_id}\ntitle: synthetic job\nproject: {project_id}\n"
        f"current_phase: research\nstatus: {status}\ncreated_at: 2026-05-30T08:00:00+00:00\n"
        "sprint_count: 0\n",
        encoding='utf-8'
    )
    (jdir / 'brief.md').write_text('brief', encoding='utf-8')
    return jdir


def test_discover_projects_empty(tmp_path: Path) -> None:
    kb = tmp_path / 'kb'
    jobs = tmp_path / 'jobs'
    journal = tmp_path / 'journal.md'
    assert discover_projects(kb, jobs, journal) == []


def test_discover_projects_basic(tmp_path: Path) -> None:
    kb = tmp_path / 'kb'
    jobs = tmp_path / 'jobs'
    journal = tmp_path / 'journal.md'
    journal.write_text('', encoding='utf-8')
    _setup_project(kb, 'alpha', title='Alpha Project', cost_total=12.50,
                   decisions=[('d001', 'First call', 'high')])
    _setup_project(kb, 'beta', title='Beta', cost_total=0.0,
                   decisions=[])
    _setup_job(jobs, 'j001-x', 'alpha', status='active')
    summaries = discover_projects(kb, jobs, journal)
    assert len(summaries) == 2
    ids = {s.id for s in summaries}
    assert ids == {'alpha', 'beta'}
    alpha = next(s for s in summaries if s.id == 'alpha')
    assert alpha.title == 'Alpha Project'
    assert alpha.cost_total_usd == 12.50
    assert alpha.decision_count == 1
    assert alpha.active_job_count == 1
    beta = next(s for s in summaries if s.id == 'beta')
    assert beta.cost_total_usd == 0.0
    assert beta.decision_count == 0
    assert beta.active_job_count == 0


def test_read_project_cost_missing(tmp_path: Path) -> None:
    kb = tmp_path / 'kb'
    cost = read_project_cost(kb, 'nope')
    assert cost.current_usd == 0.0
    assert cost.entries == []
    assert cost.last_entry_date is None


def test_read_project_cost_present(tmp_path: Path) -> None:
    kb = tmp_path / 'kb'
    _setup_project(kb, 'alpha', cost_total=42.00)
    cost = read_project_cost(kb, 'alpha')
    assert cost.current_usd == 42.00
    assert cost.last_entry_date == '2026-05-30'
    assert len(cost.entries) == 1


def test_read_project_decisions(tmp_path: Path) -> None:
    kb = tmp_path / 'kb'
    _setup_project(kb, 'alpha', decisions=[
        ('d001', 'First call', 'high'),
        ('d002', 'Second call', 'med'),
    ])
    decs = read_project_decisions(kb, 'alpha')
    assert len(decs) == 2
    ids = {d.id for d in decs}
    assert ids == {'d001', 'd002'}
    high = next(d for d in decs if d.id == 'd001')
    assert high.confidence == 'high'
    assert high.title == 'First call'


def test_read_project_decisions_empty(tmp_path: Path) -> None:
    kb = tmp_path / 'kb'
    _setup_project(kb, 'alpha')
    assert read_project_decisions(kb, 'alpha') == []


def test_read_project_ensembles_finds_runs(tmp_path: Path) -> None:
    jobs = tmp_path / 'jobs'
    _setup_job(jobs, 'j001', 'alpha')
    # An ensemble dir under j001/phases/research/
    ens_dir = jobs / 'j001' / 'phases' / 'research' / 'ensemble-2026-05-30T10-00-00'
    ens_dir.mkdir(parents=True)
    (ens_dir / 'claude-cli.md').write_text('hi', encoding='utf-8')
    (ens_dir / 'codex.md').write_text('hi', encoding='utf-8')
    (ens_dir / 'synthesis.md').write_text('synth', encoding='utf-8')
    # And a six-hats dir
    hats_dir = jobs / 'j001' / 'phases' / 'research' / 'six-hats-2026-05-30T11-00-00'
    hats_dir.mkdir(parents=True)
    for hat in ('white', 'red', 'black', 'yellow', 'green', 'blue'):
        (hats_dir / f'{hat}.md').write_text('hi', encoding='utf-8')
    rows = read_project_ensembles(jobs, 'alpha')
    assert len(rows) == 2
    kinds = sorted([r.kind for r in rows])
    assert kinds == ['ensemble', 'six-hats']
    six = next(r for r in rows if r.kind == 'six-hats')
    assert six.provider_count == 6
    ens = next(r for r in rows if r.kind == 'ensemble')
    assert ens.provider_count == 2  # synthesis.md excluded


def test_read_project_ensembles_no_match(tmp_path: Path) -> None:
    jobs = tmp_path / 'jobs'
    _setup_job(jobs, 'j001', 'unrelated-project')
    rows = read_project_ensembles(jobs, 'alpha')
    assert rows == []


def test_read_project_detail(tmp_path: Path) -> None:
    kb = tmp_path / 'kb'
    jobs = tmp_path / 'jobs'
    journal = tmp_path / 'journal.md'
    journal.write_text('', encoding='utf-8')
    _setup_project(kb, 'alpha', title='Alpha', cost_total=5.00,
                   decisions=[('d001', 'X', 'high')])
    _setup_job(jobs, 'j001', 'alpha', status='active')
    _setup_job(jobs, 'j002', 'alpha', status='done')
    detail = read_project_detail(kb, 'alpha', jobs, journal)
    assert detail.summary.id == 'alpha'
    assert detail.summary.active_job_count == 1
    # All jobs (active + done) included in detail.jobs
    job_ids = {j.id for j in detail.jobs}
    assert job_ids == {'j001', 'j002'}
    assert detail.cost.current_usd == 5.00
    assert len(detail.decisions) == 1


def test_read_project_detail_missing_raises(tmp_path: Path) -> None:
    kb = tmp_path / 'kb'
    jobs = tmp_path / 'jobs'
    journal = tmp_path / 'journal.md'
    journal.write_text('', encoding='utf-8')
    try:
        read_project_detail(kb, 'nope', jobs, journal)
        assert False, 'expected FileNotFoundError'
    except FileNotFoundError:
        pass
