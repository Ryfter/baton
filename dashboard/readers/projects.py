"""Plan 7: project discovery + per-project drill-in reader.

Pure-Python; no shell-out. Reuses readers/jobs.py for the project-filtered
job list. Hand-rolled YAML front-matter parser to avoid adding PyYAML.
"""
from __future__ import annotations

import re
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional

from dashboard.models.events import (
    CostEntry,
    DecisionRow,
    EnsembleRow,
    ProjectCost,
    ProjectDetail,
    ProjectSummary,
)
from dashboard.readers.jobs import list_job_summaries

_COST_ROW_RE = re.compile(
    r'^\|\s*(\d{4}-\d{2}-\d{2})\s*\|\s*\$([\d.]+)\s*\|\s*([+\-]?\$?[\d.]+)\s*\|\s*(.*?)\s*\|\s*(.*?)\s*\|'
)
_CURRENT_TOTAL_RE = re.compile(
    r'^\*\*Current total:\s*\$([\d.]+)\*\*\s*\(as of\s*([\d-]+)\)'
)
_H1_RE = re.compile(r'^#\s+(.+)$')
_FRONTMATTER_KEY_RE = re.compile(r'^([a-zA-Z_-]+):\s*"?([^"]*?)"?\s*$')
_ENSEMBLE_DIR_RE = re.compile(r'^(ensemble|six-hats|council)-(\d{4}-\d{2}-\d{2}T[\d-]+)')


def _read_text(path: Path) -> str:
    try:
        return path.read_text(encoding='utf-8')
    except (FileNotFoundError, OSError):
        return ''


def _parse_frontmatter(text: str) -> dict[str, str]:
    """Parse a leading `---`-fenced YAML block as flat key/value pairs."""
    if not text.startswith('---'):
        return {}
    lines = text.splitlines()
    out: dict[str, str] = {}
    in_fm = False
    for line in lines:
        if line.strip() == '---':
            if in_fm:
                break
            in_fm = True
            continue
        if not in_fm:
            continue
        m = _FRONTMATTER_KEY_RE.match(line)
        if m:
            key = m.group(1)
            val = m.group(2).strip()
            out[key] = val
    return out


def _file_mtime(path: Path) -> Optional[datetime]:
    try:
        return datetime.fromtimestamp(path.stat().st_mtime, tz=timezone.utc).astimezone()
    except (FileNotFoundError, OSError):
        return None


def _max_dt(*dts: Optional[datetime]) -> Optional[datetime]:
    valid = [d for d in dts if d is not None]
    return max(valid) if valid else None


def _read_project_title(project_dir: Path) -> str:
    """First H1 of decision-guidance.md; fall back to a humanised id."""
    guidance = project_dir / 'decision-guidance.md'
    if guidance.exists():
        for line in _read_text(guidance).splitlines():
            m = _H1_RE.match(line.strip())
            if m:
                return m.group(1).strip()
    return project_dir.name.replace('-', ' ').title()


def read_project_cost(kb_root: Path, project_id: str) -> ProjectCost:
    cost_path = kb_root / 'projects' / project_id / 'cost.md'
    if not cost_path.exists():
        return ProjectCost()
    current = 0.0
    last_date: Optional[str] = None
    entries: list[CostEntry] = []
    for line in _read_text(cost_path).splitlines():
        m_head = _CURRENT_TOTAL_RE.match(line.strip())
        if m_head:
            try:
                current = float(m_head.group(1))
            except ValueError:
                pass
            last_date = m_head.group(2)
            continue
        m_row = _COST_ROW_RE.match(line)
        if m_row:
            try:
                total = float(m_row.group(2))
            except ValueError:
                total = 0.0
            entries.append(CostEntry(
                date=m_row.group(1),
                total=total,
                delta=m_row.group(3),
                source=m_row.group(4),
                note=m_row.group(5),
            ))
            # Fall back current/last_date from entries if header missing
            if current == 0.0:
                current = total
            if last_date is None:
                last_date = m_row.group(1)
    return ProjectCost(current_usd=current, last_entry_date=last_date, entries=entries)


def read_project_decisions(kb_root: Path, project_id: str) -> list[DecisionRow]:
    dec_dir = kb_root / 'projects' / project_id / 'decisions'
    if not dec_dir.exists():
        return []
    rows: list[DecisionRow] = []
    for f in sorted(dec_dir.glob('d*.md')):
        text = _read_text(f)
        fm = _parse_frontmatter(text)
        # Title is the first H1 below the front-matter
        title = '(no title)'
        for line in text.splitlines():
            m = _H1_RE.match(line.strip())
            if m:
                title = m.group(1).strip()
                break
        ts: Optional[datetime] = None
        ts_str = fm.get('timestamp')
        if ts_str:
            try:
                ts = datetime.fromisoformat(ts_str)
            except ValueError:
                ts = None
        if ts is None:
            ts = _file_mtime(f)
        job_val = fm.get('job') or None
        if job_val == 'null':
            job_val = None
        rows.append(DecisionRow(
            id=fm.get('id', f.stem.split('-', 1)[0]),
            title=title,
            confidence=fm.get('confidence', 'unknown'),
            flag=fm.get('flag', 'null') or 'null',
            timestamp=ts,
            job=job_val,
            path=str(f),
        ))
    rows.sort(key=lambda r: r.timestamp or datetime.min.replace(tzinfo=timezone.utc), reverse=True)
    return rows


def _count_provider_files(ens_dir: Path) -> int:
    """Count <label>.md files (excluding synthesis.md and round*/...) at top level."""
    if not ens_dir.exists():
        return 0
    n = 0
    for f in ens_dir.iterdir():
        if f.is_file() and f.suffix == '.md' and f.name != 'synthesis.md':
            n += 1
        elif f.is_dir() and f.name.startswith('round'):
            # Council R1/R2 sub-dirs: count the union of providers
            for sub in f.glob('*.md'):
                if sub.name != 'synthesis.md':
                    n = max(n, len(list(f.glob('*.md'))))
                    break
    return n


def read_project_ensembles(jobs_root: Path, project_id: str) -> list[EnsembleRow]:
    """Scan every job whose manifest project == project_id and enumerate
    ensemble-* / six-hats-* / council-* directories under phases/*/."""
    rows: list[EnsembleRow] = []
    if not jobs_root.exists():
        return rows
    for job_dir in jobs_root.iterdir():
        if not job_dir.is_dir():
            continue
        mf = job_dir / 'manifest.yaml'
        if not mf.exists():
            continue
        fm: dict[str, str] = {}
        for line in _read_text(mf).splitlines():
            m = _FRONTMATTER_KEY_RE.match(line.strip())
            if m:
                fm[m.group(1)] = m.group(2)
        if fm.get('project') != project_id:
            continue
        phases_dir = job_dir / 'phases'
        if not phases_dir.exists():
            continue
        for phase_dir in phases_dir.iterdir():
            if not phase_dir.is_dir():
                continue
            for ens_dir in phase_dir.iterdir():
                if not ens_dir.is_dir():
                    continue
                m = _ENSEMBLE_DIR_RE.match(ens_dir.name)
                if not m:
                    continue
                kind = m.group(1)
                ts_str = m.group(2).replace('T', 'T').replace('-', ':', 2)  # back to ISO-ish
                # Timestamp is yyyy-MM-ddTHH-mm-ss; reverse the dashes in time part
                raw = m.group(2)
                # raw = '2026-05-30T05-30-00' → ISO '2026-05-30T05:30:00'
                date_part, _, time_part = raw.partition('T')
                time_iso = time_part.replace('-', ':')
                try:
                    ts = datetime.fromisoformat(f'{date_part}T{time_iso}')
                except ValueError:
                    ts = _file_mtime(ens_dir) or datetime.now().astimezone()
                rows.append(EnsembleRow(
                    kind=kind,
                    timestamp=ts,
                    path=str(ens_dir),
                    provider_count=_count_provider_files(ens_dir),
                    job_id=job_dir.name,
                ))
    rows.sort(key=lambda r: r.timestamp, reverse=True)
    return rows


def discover_projects(
    kb_root: Path,
    jobs_root: Path,
    journal_path: Path,
) -> list[ProjectSummary]:
    projects_root = kb_root / 'projects'
    if not projects_root.exists():
        return []
    out: list[ProjectSummary] = []
    for project_dir in projects_root.iterdir():
        if not project_dir.is_dir():
            continue
        project_id = project_dir.name
        title = _read_project_title(project_dir)
        cost = read_project_cost(kb_root, project_id)
        decisions = read_project_decisions(kb_root, project_id)
        active_jobs = [
            j for j in list_job_summaries(jobs_root, journal_path, 'active')
            if j.project == project_id
        ]
        ensembles = read_project_ensembles(jobs_root, project_id)
        # last_activity: max of latest decision ts, latest active job created_at, latest ensemble ts
        last_dec = decisions[0].timestamp if decisions else None
        last_job = max((j.created_at for j in active_jobs), default=None)
        last_ens = ensembles[0].timestamp if ensembles else None
        last_act = _max_dt(last_dec, last_job, last_ens)
        out.append(ProjectSummary(
            id=project_id,
            title=title,
            cost_total_usd=cost.current_usd,
            decision_count=len(decisions),
            active_job_count=len(active_jobs),
            last_activity=last_act,
        ))
    out.sort(
        key=lambda p: p.last_activity or datetime.min.replace(tzinfo=timezone.utc),
        reverse=True,
    )
    return out


def read_project_detail(
    kb_root: Path,
    project_id: str,
    jobs_root: Path,
    journal_path: Path,
) -> ProjectDetail:
    summaries = [p for p in discover_projects(kb_root, jobs_root, journal_path) if p.id == project_id]
    if not summaries:
        raise FileNotFoundError(f'No such project: {project_id}')
    summary = summaries[0]
    all_jobs = [
        j for j in list_job_summaries(jobs_root, journal_path, 'all')
        if j.project == project_id
    ]
    return ProjectDetail(
        summary=summary,
        jobs=all_jobs,
        decisions=read_project_decisions(kb_root, project_id),
        cost=read_project_cost(kb_root, project_id),
        ensembles=read_project_ensembles(jobs_root, project_id),
    )
