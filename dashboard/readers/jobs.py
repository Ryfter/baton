from __future__ import annotations

import re
from collections import defaultdict
from datetime import datetime
from pathlib import Path
from typing import Optional

from dashboard.models.events import (
    JobDetail,
    JobSummary,
    LessonEntry,
    OtelEntry,
    PhaseLogEntry,
)
from dashboard.readers.journal import read_journal

_MANIFEST_LINE_RE = re.compile(r'^([a-zA-Z_]+):\s*"?([^"]+?)"?\s*$')
_PHASE_LOG_RE = re.compile(
    r'^(?P<ts>\d{4}-\d{2}-\d{2}T[\d:+-]+)\s*\|\s*(?P<kind>[a-z-]+)\s*\|\s*(?P<detail>[^|]+?)(?:\s*note:\s*"(?P<note>[^"]*)")?\s*$'
)
_LESSON_LINE_RE = re.compile(
    r'^(?P<ts>\d{4}-\d{2}-\d{2}T[\d:+-]+)\s*\|\s*(?P<cat>[a-z-]+)\s*\|\s*"(?P<text>.+?)"\s*(✓ consolidated [\d-]+)?$'
)


def _parse_manifest(path: Path) -> dict[str, str]:
    if not path.exists():
        return {}
    out: dict[str, str] = {}
    for line in path.read_text(encoding='utf-8').splitlines():
        m = _MANIFEST_LINE_RE.match(line)
        if m:
            out[m.group(1)] = m.group(2)
    return out


def _parse_phase_log(path: Path) -> list[PhaseLogEntry]:
    if not path.exists():
        return []
    out: list[PhaseLogEntry] = []
    for line in path.read_text(encoding='utf-8').splitlines():
        m = _PHASE_LOG_RE.match(line.strip())
        if not m:
            continue
        out.append(PhaseLogEntry(
            timestamp=datetime.fromisoformat(m.group('ts')),
            kind=m.group('kind'),
            detail=m.group('detail').strip(),
            note=m.group('note'),
        ))
    return out


def _parse_lessons(path: Path) -> list[LessonEntry]:
    if not path.exists():
        return []
    out: list[LessonEntry] = []
    current_phase: Optional[str] = None
    for line in path.read_text(encoding='utf-8').splitlines():
        stripped = line.strip()
        if stripped.startswith('## '):
            current_phase = stripped[3:].strip()
            continue
        m = _LESSON_LINE_RE.match(stripped)
        if not m:
            continue
        out.append(LessonEntry(
            timestamp=datetime.fromisoformat(m.group('ts')),
            category=m.group('cat'),
            text=m.group('text'),
            phase=current_phase,
        ))
    return out


def _job_cost_from_journal(journal: list, job_id: str) -> float:
    return sum(
        e.cost_usd for e in journal
        if isinstance(e, OtelEntry) and e.job_id == job_id
    )


def _job_summary_from_dir(job_dir: Path, journal: list) -> Optional[JobSummary]:
    manifest = _parse_manifest(job_dir / 'manifest.yaml')
    if not manifest:
        return None
    return JobSummary(
        id=manifest.get('id', job_dir.name),
        title=manifest.get('title', '(untitled)'),
        project=manifest.get('project') or None,
        current_phase=manifest.get('current_phase', 'research'),
        status=manifest.get('status', 'active'),
        created_at=datetime.fromisoformat(manifest.get('created_at', '2000-01-01T00:00:00+00:00')),
        sprint_count=int(manifest.get('sprint_count', 0)),
        cost_usd=round(_job_cost_from_journal(journal, manifest.get('id', '')), 4),
    )


def list_job_summaries(
    jobs_root: Path,
    journal_path: Path,
    status_filter: str = 'active',
) -> list[JobSummary]:
    if not jobs_root.exists():
        return []
    journal = read_journal(journal_path)
    summaries: list[JobSummary] = []
    for d in jobs_root.iterdir():
        if not d.is_dir():
            continue
        s = _job_summary_from_dir(d, journal)
        if s is None:
            continue
        if status_filter != 'all' and s.status != status_filter:
            continue
        summaries.append(s)
    summaries.sort(key=lambda s: s.created_at, reverse=True)
    return summaries


def read_job_detail(
    jobs_root: Path,
    journal_path: Path,
    job_id: str,
) -> JobDetail:
    job_dir = jobs_root / job_id
    if not job_dir.exists():
        raise FileNotFoundError(f'No such job: {job_id}')
    journal = read_journal(journal_path)
    summary = _job_summary_from_dir(job_dir, journal)
    if summary is None:
        raise FileNotFoundError(f'No manifest for job: {job_id}')

    # Filter journal to entries tagged with this job, sorted oldest-to-newest
    filtered = sorted(
        [e for e in journal if getattr(e, 'job_id', None) == job_id],
        key=lambda e: e.timestamp,
        reverse=True,
    )

    # Per-phase cost from OTel entries
    cost_by_phase: dict[str, float] = defaultdict(float)
    for e in journal:
        if isinstance(e, OtelEntry) and e.job_id == job_id and e.phase:
            cost_by_phase[e.phase] += e.cost_usd
    cost_by_phase = {k: round(v, 4) for k, v in cost_by_phase.items()}

    return JobDetail(
        summary=summary,
        brief=(job_dir / 'brief.md').read_text(encoding='utf-8'),
        phase_log=_parse_phase_log(job_dir / 'phase-log.md'),
        journal=filtered,
        lessons=_parse_lessons(job_dir / 'lessons.md'),
        cost_by_phase=cost_by_phase,
    )
