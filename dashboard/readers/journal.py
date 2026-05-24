from __future__ import annotations

import re
from datetime import datetime
from pathlib import Path
from typing import Optional, Union

from dashboard.models.events import HookEntry, NoteEntry, OtelEntry

JournalEntry = Union[HookEntry, OtelEntry, NoteEntry]

_TS_RE = re.compile(
    r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})"
)
_DURATION_RE = re.compile(r"(-?\d+)s")
_EXIT_RE = re.compile(r"exit:(-?\d+)")
_OTEL_TOKENS_RE = re.compile(r"in:(\d+)\s+out:(\d+)")
_OTEL_COST_RE = re.compile(r"\$([0-9]+(?:\.[0-9]+)?)")


def _strip_quotes(value: str) -> str:
    value = value.strip()
    if len(value) >= 2 and value[0] == value[-1] == '"':
        return value[1:-1]
    return value


def parse_journal_line(line: str) -> Optional[JournalEntry]:
    line = line.strip()
    if not line or not _TS_RE.match(line):
        return None

    parts = [p.strip() for p in line.split("|")]
    if len(parts) < 3:
        return None

    try:
        timestamp = datetime.fromisoformat(parts[0].replace("Z", "+00:00"))
    except ValueError:
        return None

    source = parts[1]
    if source == "hook":
        if len(parts) < 5:
            return None
        duration_match = _DURATION_RE.search(parts[3])
        exit_match = _EXIT_RE.search(parts[4])
        if not duration_match or not exit_match:
            return None

        brief = None
        if len(parts) > 5 and parts[5]:
            brief = _strip_quotes(parts[5])

        return HookEntry(
            timestamp=timestamp,
            target=parts[2],
            duration_s=int(duration_match.group(1)),
            exit_code=int(exit_match.group(1)),
            brief=brief,
        )

    if source == "otel":
        if len(parts) < 5:
            return None
        tokens_match = _OTEL_TOKENS_RE.search(parts[3])
        cost_match = _OTEL_COST_RE.search(parts[4])
        if not tokens_match or not cost_match:
            return None

        return OtelEntry(
            timestamp=timestamp,
            model=parts[2],
            input_tokens=int(tokens_match.group(1)),
            output_tokens=int(tokens_match.group(2)),
            cost_usd=float(cost_match.group(1)),
        )

    if source == "note":
        if len(parts) < 4:
            return None
        return NoteEntry(
            timestamp=timestamp,
            target=parts[2],
            text=_strip_quotes(parts[3]),
        )

    return None


def read_journal(path: Path) -> list[JournalEntry]:
    if not path.exists():
        return []

    entries: list[JournalEntry] = []
    for line in path.read_text(encoding="utf-8").splitlines():
        entry = parse_journal_line(line)
        if entry is not None:
            entries.append(entry)
    return entries
