from __future__ import annotations

from pathlib import Path

import pytest

from tools.registry import (
    ToolSpec,
    read_tools,
    get_tool,
    tools_for_capability,
)

FIXTURE = """\
tools:
  - name: docling
    kind: python
    enabled: true
    cost_tier: local
    capability: pdf-extract
    module: docling.document_converter
  - name: legacy-ocr
    kind: cli
    enabled: false
    cost_tier: paid
    capability: pdf-extract
    command_template: 'ocr {{file}}'
"""


def _write(tmp_path: Path, text: str = FIXTURE) -> Path:
    p = tmp_path / "tools.yaml"
    p.write_text(text, encoding="utf-8")
    return p


def test_read_tools_parses_specs(tmp_path: Path) -> None:
    specs = read_tools(_write(tmp_path))
    assert len(specs) == 2
    d = specs[0]
    assert isinstance(d, ToolSpec)
    assert d.name == "docling"
    assert d.kind == "python"
    assert d.enabled is True
    assert d.cost_tier == "local"
    assert d.capability == "pdf-extract"
    assert d.module == "docling.document_converter"


def test_missing_file_returns_empty(tmp_path: Path) -> None:
    assert read_tools(tmp_path / "nope.yaml") == []


def test_env_override(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    p = _write(tmp_path)
    monkeypatch.setenv("TOOLS_FILE", str(p))
    specs = read_tools()  # no arg → env
    assert [s.name for s in specs] == ["docling", "legacy-ocr"]


def test_param_beats_env(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    p = _write(tmp_path)
    monkeypatch.setenv("TOOLS_FILE", str(tmp_path / "does-not-exist.yaml"))
    specs = read_tools(p)  # explicit param wins
    assert len(specs) == 2


def test_get_tool(tmp_path: Path) -> None:
    p = _write(tmp_path)
    assert get_tool("docling", path=p).name == "docling"
    assert get_tool("absent", path=p) is None


def test_tools_for_capability_filters_disabled(tmp_path: Path) -> None:
    p = _write(tmp_path)
    enabled = tools_for_capability("pdf-extract", path=p)
    assert [s.name for s in enabled] == ["docling"]  # legacy-ocr disabled
    every = tools_for_capability("pdf-extract", path=p, enabled_only=False)
    assert {s.name for s in every} == {"docling", "legacy-ocr"}
    assert tools_for_capability("nope", path=p) == []
