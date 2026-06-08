"""Convert a corpus file to text for chunking.

Dispatch by extension: markdown/text are read directly; PDF is routed to an enabled
`pdf-extract` tool from tools.yaml (currently Docling, lazily imported). A PDF — a
type we promise to handle — is never silently zero-chunked: it returns text or raises
ExtractorUnavailable (no tool / tool not installed) or ExtractorError (bad PDF).
Unknown extensions return None (genuine, silent skip).
"""
from __future__ import annotations

from pathlib import Path

from tools.registry import tools_for_capability

from kb.extractors.pdf_docling import extract_pdf  # re-export for monkeypatching


class ExtractorUnavailable(RuntimeError):
    """No enabled/installed tool can handle this file type."""


class ExtractorError(RuntimeError):
    """A tool was available but extraction failed (e.g. corrupt PDF)."""


_TEXT_SUFFIXES = {".md", ".markdown", ".txt"}


def extract_to_text(path: Path, *, tools_path: Path | None = None) -> str | None:
    p = Path(path)
    suffix = p.suffix.lower()
    if suffix in _TEXT_SUFFIXES:
        return p.read_text(encoding="utf-8", errors="replace")
    if suffix == ".pdf":
        tools = tools_for_capability("pdf-extract", path=tools_path, enabled_only=True)
        if not tools:
            raise ExtractorUnavailable("pdf-extract: no enabled tool")
        return extract_pdf(p)  # module-level ref so tests can monkeypatch
    return None
