from __future__ import annotations

from pathlib import Path

import pytest

from tools.doctor import probe_tool, run_doctor
from tools.registry import ToolSpec

FIXTURE = """\
tools:
  - name: docling
    kind: python
    enabled: true
    cost_tier: local
    capability: pdf-extract
    module: tools.registry
  - name: ghost
    kind: python
    enabled: true
    cost_tier: local
    capability: pdf-extract
    module: this_module_does_not_exist_xyz
  - name: off
    kind: cli
    enabled: false
    cost_tier: paid
    capability: pdf-extract
    command_template: 'x {{file}}'
"""


def _write(tmp_path: Path) -> Path:
    p = tmp_path / "tools.yaml"
    p.write_text(FIXTURE, encoding="utf-8")
    return p


def test_probe_python_importable_ok() -> None:
    spec = ToolSpec(name="docling", kind="python", enabled=True,
                    cost_tier="local", module="tools.registry")
    status, _ = probe_tool(spec)
    assert status == "ok"


def test_probe_python_missing_module_err() -> None:
    spec = ToolSpec(name="ghost", kind="python", enabled=True,
                    cost_tier="local", module="nope_xyz_123")
    status, _ = probe_tool(spec)
    assert status == "err"


def test_probe_disabled_skips() -> None:
    spec = ToolSpec(name="off", kind="cli", enabled=False,
                    cost_tier="paid", command_template="x")
    status, _ = probe_tool(spec)
    assert status == "skip"


def test_run_doctor_nonzero_when_any_err(tmp_path: Path, capsys: pytest.CaptureFixture) -> None:
    code = run_doctor(path=_write(tmp_path))
    out = capsys.readouterr().out
    assert "docling" in out and "ghost" in out
    assert code == 1  # ghost errs


def test_run_doctor_zero_when_all_ok(tmp_path: Path) -> None:
    p = tmp_path / "tools.yaml"
    p.write_text(
        "tools:\n"
        "  - name: docling\n"
        "    kind: python\n"
        "    enabled: true\n"
        "    cost_tier: local\n"
        "    module: tools.registry\n",
        encoding="utf-8",
    )
    assert run_doctor(path=p) == 0
