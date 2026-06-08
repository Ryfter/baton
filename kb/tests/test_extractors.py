from __future__ import annotations

from pathlib import Path

import pytest

from kb.extractors import (
    extract_to_text,
    ExtractorUnavailable,
    ExtractorError,
)
from kb import extractors as ext

REG = """\
tools:
  - name: docling
    kind: python
    enabled: {enabled}
    cost_tier: local
    capability: pdf-extract
    module: docling.document_converter
"""


def _reg(tmp_path: Path, enabled: str = "true") -> Path:
    p = tmp_path / "tools.yaml"
    p.write_text(REG.format(enabled=enabled), encoding="utf-8")
    return p


def test_markdown_read_through(tmp_path: Path) -> None:
    f = tmp_path / "a.md"
    f.write_text("# Hi\n\nbody", encoding="utf-8")
    assert extract_to_text(f) == "# Hi\n\nbody"


def test_txt_read_through(tmp_path: Path) -> None:
    f = tmp_path / "a.txt"
    f.write_text("plain text", encoding="utf-8")
    assert extract_to_text(f) == "plain text"


def test_unknown_extension_returns_none(tmp_path: Path) -> None:
    f = tmp_path / "a.png"
    f.write_bytes(b"\x89PNG")
    assert extract_to_text(f) is None


def test_pdf_uses_enabled_tool(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    f = tmp_path / "doc.pdf"
    f.write_bytes(b"%PDF-1.4")
    monkeypatch.setattr(ext, "extract_pdf", lambda p: "# Extracted\n\nfrom pdf")
    assert extract_to_text(f, tools_path=_reg(tmp_path)) == "# Extracted\n\nfrom pdf"


def test_pdf_no_enabled_tool_raises_unavailable(tmp_path: Path) -> None:
    f = tmp_path / "doc.pdf"
    f.write_bytes(b"%PDF-1.4")
    with pytest.raises(ExtractorUnavailable):
        extract_to_text(f, tools_path=_reg(tmp_path, enabled="false"))


def test_pdf_docling_not_installed_raises_unavailable(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    f = tmp_path / "doc.pdf"
    f.write_bytes(b"%PDF-1.4")

    def _boom(p: Path) -> str:
        raise ExtractorUnavailable("docling not installed")

    monkeypatch.setattr(ext, "extract_pdf", _boom)
    with pytest.raises(ExtractorUnavailable):
        extract_to_text(f, tools_path=_reg(tmp_path))


def test_pdf_conversion_failure_raises_error(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    f = tmp_path / "doc.pdf"
    f.write_bytes(b"%PDF-1.4")

    def _boom(p: Path) -> str:
        raise ExtractorError("bad pdf")

    monkeypatch.setattr(ext, "extract_pdf", _boom)
    with pytest.raises(ExtractorError):
        extract_to_text(f, tools_path=_reg(tmp_path))
