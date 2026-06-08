# Tools registry + Docling PDF call-out — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stand up a `tools.yaml` capability registry (the non-LLM sibling of `fleet.yaml`) and wire Docling PDF-extraction into the KB ingest pipeline so dropped PDFs become searchable with zero Claude tokens.

**Architecture:** A new `tools/` Python package reads `tools.yaml` and reports tool health. A new `kb/extractors/` package converts a corpus file to text (markdown→read, PDF→Docling via a lazy import gated by the registry). The chunker is split into a pure `chunk_text` + a `chunk_file` that pulls text through the extractor; the indexer learns to discover `*.pdf` and to count extractor skips/errors. A `/tools` command and a bootstrap step expose and deploy the registry.

**Tech Stack:** Python 3.14 + pytest + pyyaml 6.0.3 (present); PowerShell (bootstrap + command-prompt); Docling (optional, lazy import — never a hard dep).

**Spec:** `docs/superpowers/specs/2026-06-07-tools-registry-docling-design.md`

---

## Conventions (read once)

- **Run from repo root:** `python -m tools.doctor`, `python -m kb.index` (cwd = repo).
- **Lib-root resolution:** param > `$TOOLS_FILE` env > `~/.claude/tools.yaml` default (mirrors `kb` corpus-root args and the PS `Get-*Root` helpers).
- **PS test harness:** `Check($name,$cond)` increments `$script:fail`; `exit 1` if any fail else `exit 0`.
- **Bootstrap smoke** runs in **dry-run** (writes nothing) → assert against **stdout**, never `Test-Path`.
- **Docling is optional.** Never add it to any always-installed dep list. All Docling use is behind a lazy `import` inside a function.
- Run the full Python suite with `python -m pytest -q` from repo root. Tests that embed require a running Ollama (existing convention); the new tests in this plan do **not** require Docling.

## File Structure

| File | Responsibility |
|---|---|
| `tools/__init__.py` (create) | Marks the package. Empty. |
| `tools/registry.py` (create) | `ToolSpec` dataclass; `read_tools`, `get_tool`, `tools_for_capability`; path resolution. |
| `tools/doctor.py` (create) | `python -m tools.doctor` — availability table + exit code. |
| `tools/list.py` (create) | `python -m tools.list` — registry table. |
| `tools/tests/__init__.py` (create) | Empty. |
| `tools/tests/test_registry.py` (create) | Registry parsing + resolution + lookups. |
| `tools/tests/test_doctor.py` (create) | Doctor probe + table + exit code. |
| `references/tools.yaml` (create) | Registry seed (Docling entry). Deployed by bootstrap. |
| `kb/extractors/__init__.py` (create) | `extract_to_text` dispatch + `ExtractorUnavailable`/`ExtractorError`. |
| `kb/extractors/pdf_docling.py` (create) | `extract_pdf` — lazy Docling import. |
| `kb/tests/test_extractors.py` (create) | Dispatch + Docling stub/unavailable/disabled. |
| `kb/chunker.py` (modify) | Split into `chunk_text` (pure) + `chunk_file` (extractor-fed). |
| `kb/tests/test_chunker.py` (modify) | Add a direct `chunk_text` test; existing tests stay green. |
| `kb/index.py` (modify) | Discover `*.pdf`; count `extractor_skips`/`extractor_errors`; exit code. |
| `kb/tests/test_index_incremental.py` (modify) | PDF end-to-end (monkeypatched) + skip-on-unavailable. |
| `commands/tools.md` (create) | `/tools list|doctor`. |
| `scripts/bootstrap.ps1` (modify) | Step 5b4 deploy `tools.yaml`; add `tools.md` to commands array. |
| `scripts/test-bootstrap.ps1` (modify) | Dry-run stdout assertions for `tools.yaml` + `tools.md`. |

---

### Task 1: Tools registry reader

**Files:**
- Create: `tools/__init__.py` (empty), `tools/registry.py`, `tools/tests/__init__.py` (empty)
- Test: `tools/tests/test_registry.py`

- [ ] **Step 1: Write the failing test**

Create `tools/tests/test_registry.py`:

```python
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `python -m pytest tools/tests/test_registry.py -q`
Expected: FAIL — `ModuleNotFoundError: No module named 'tools'`.

- [ ] **Step 3: Write minimal implementation**

Create `tools/__init__.py` (empty file) and `tools/tests/__init__.py` (empty file).

Create `tools/registry.py`:

```python
"""Reader for tools.yaml — the non-LLM capability registry (sibling of fleet.yaml).

Lean by design: only what's needed to SELECT and INVOKE a tool. Path resolution
mirrors the KB/PS convention: explicit param > $TOOLS_FILE env > ~/.claude/tools.yaml.
A missing registry yields [] (never raises) so the .md pipeline survives its absence.
"""
from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path

import yaml


@dataclass
class ToolSpec:
    name: str
    kind: str                      # python | cli | http
    enabled: bool
    cost_tier: str                 # paid | free | local
    capability: str | None = None  # the routing key, e.g. pdf-extract
    module: str | None = None      # kind:python — importable module path
    command_template: str | None = None  # kind:cli
    base_url: str | None = None    # kind:http


def _resolve_path(path: Path | None) -> Path:
    if path is not None:
        return Path(path)
    env = os.environ.get("TOOLS_FILE")
    if env:
        return Path(env)
    return Path.home() / ".claude" / "tools.yaml"


def read_tools(path: Path | None = None) -> list[ToolSpec]:
    p = _resolve_path(path)
    if not p.exists():
        return []
    data = yaml.safe_load(p.read_text(encoding="utf-8")) or {}
    out: list[ToolSpec] = []
    for entry in data.get("tools", []) or []:
        out.append(
            ToolSpec(
                name=str(entry.get("name", "")),
                kind=str(entry.get("kind", "")),
                enabled=bool(entry.get("enabled", False)),
                cost_tier=str(entry.get("cost_tier", "")),
                capability=entry.get("capability"),
                module=entry.get("module"),
                command_template=entry.get("command_template"),
                base_url=entry.get("base_url"),
            )
        )
    return out


def get_tool(name: str, *, path: Path | None = None) -> ToolSpec | None:
    for t in read_tools(path):
        if t.name == name:
            return t
    return None


def tools_for_capability(
    capability: str, *, path: Path | None = None, enabled_only: bool = True
) -> list[ToolSpec]:
    out = [t for t in read_tools(path) if t.capability == capability]
    if enabled_only:
        out = [t for t in out if t.enabled]
    return out
```

- [ ] **Step 4: Run test to verify it passes**

Run: `python -m pytest tools/tests/test_registry.py -q`
Expected: PASS (6 passed).

- [ ] **Step 5: Commit**

```bash
git add tools/__init__.py tools/registry.py tools/tests/__init__.py tools/tests/test_registry.py
git commit -m "feat(tools): tools.yaml registry reader"
```

---

### Task 2: tools.yaml registry seed

**Files:**
- Create: `references/tools.yaml`

- [ ] **Step 1: Write the seed file**

Create `references/tools.yaml`:

```yaml
# tools.yaml — non-LLM callable capabilities, co-equal with fleet.yaml models.
# Lean by design: only what's needed to SELECT and INVOKE a tool lives here.
# "Which tool for what" qualitative notes live in
# ~/.claude/knowledge/universal/routing.md and evolve via /consolidate-routing.
#
# Fields:
#   name         unique key, [a-z0-9-]+
#   kind         python | cli | http   (how it is invoked)
#   enabled      true | false          (disabled tools are skipped, not invoked)
#   cost_tier    paid | free | local
#   capability   the need it serves (the routing key), e.g. pdf-extract
#   module       (kind:python) importable module path used by the invoker
#   command_template / base_url   (cli/http, future tools)

tools:
  - name: docling
    kind: python
    enabled: true
    cost_tier: local
    capability: pdf-extract
    module: docling.document_converter
```

- [ ] **Step 2: Verify it parses**

Run: `python -c "from tools.registry import read_tools; print([t.name for t in read_tools('references/tools.yaml')])"`
Expected: `['docling']`

- [ ] **Step 3: Commit**

```bash
git add references/tools.yaml
git commit -m "feat(tools): tools.yaml seed with Docling pdf-extract entry"
```

---

### Task 3: tools doctor + list

**Files:**
- Create: `tools/doctor.py`, `tools/list.py`
- Test: `tools/tests/test_doctor.py`

- [ ] **Step 1: Write the failing test**

Create `tools/tests/test_doctor.py`:

```python
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `python -m pytest tools/tests/test_doctor.py -q`
Expected: FAIL — `ModuleNotFoundError: No module named 'tools.doctor'`.

- [ ] **Step 3: Write minimal implementation**

Create `tools/doctor.py`:

```python
"""python -m tools.doctor — health-check every enabled tool in tools.yaml.

Probe by kind: python → module importable? cli → command on PATH? http → base_url
reachable? Prints a NAME/STATUS/DETAIL table; exits 1 if any enabled tool errs.
"""
from __future__ import annotations

import importlib.util
import shutil
import sys
import urllib.request
from pathlib import Path

from tools.registry import ToolSpec, read_tools


def probe_tool(spec: ToolSpec) -> tuple[str, str]:
    """Return (status, detail) where status is ok | err | skip."""
    if not spec.enabled:
        return "skip", "disabled in tools.yaml"
    if spec.kind == "python":
        if not spec.module:
            return "err", "no module declared"
        try:
            found = importlib.util.find_spec(spec.module) is not None
        except (ImportError, ValueError, ModuleNotFoundError):
            found = False
        return ("ok", f"import {spec.module}") if found else ("err", f"cannot import {spec.module}")
    if spec.kind == "cli":
        exe = (spec.command_template or "").split()[0] if spec.command_template else spec.name
        path = shutil.which(exe)
        return ("ok", f"{exe} on PATH") if path else ("err", f"{exe} not on PATH")
    if spec.kind == "http":
        if not spec.base_url:
            return "err", "no base_url declared"
        try:
            urllib.request.urlopen(spec.base_url, timeout=2)  # noqa: S310
            return "ok", f"{spec.base_url} alive"
        except Exception:  # noqa: BLE001 — any failure = unreachable
            return "err", f"{spec.base_url} unreachable"
    return "err", f"unknown kind: {spec.kind}"


def run_doctor(*, path: Path | None = None) -> int:
    specs = read_tools(path)
    rows = [(s.name, *probe_tool(s)) for s in specs]
    width = max((len(r[0]) for r in rows), default=4)
    print(f"{'NAME'.ljust(width)}  STATUS  DETAIL")
    print(f"{'-' * width}  ------  ------")
    any_err = False
    for name, status, detail in rows:
        if status == "err":
            any_err = True
        print(f"{name.ljust(width)}  {status.ljust(6)}  {detail}")
    enabled = sum(1 for s in specs if s.enabled)
    print(f"\n{enabled} enabled tool(s).")
    return 1 if any_err else 0


def main(argv: list[str] | None = None) -> int:
    return run_doctor()


if __name__ == "__main__":
    raise SystemExit(main())
```

Create `tools/list.py`:

```python
"""python -m tools.list — print the tools.yaml registry as a table."""
from __future__ import annotations

from pathlib import Path

from tools.registry import read_tools


def run_list(*, path: Path | None = None) -> int:
    specs = read_tools(path)
    cols = ("name", "kind", "enabled", "cost_tier", "capability")
    rows = [
        (s.name, s.kind, str(s.enabled), s.cost_tier, s.capability or "")
        for s in specs
    ]
    widths = [max(len(c), *(len(r[i]) for r in rows)) if rows else len(c)
              for i, c in enumerate(cols)]
    line = "  ".join(c.ljust(widths[i]) for i, c in enumerate(cols))
    print(line)
    print("  ".join("-" * widths[i] for i in range(len(cols))))
    for r in rows:
        print("  ".join(r[i].ljust(widths[i]) for i in range(len(cols))))
    return 0


def main(argv: list[str] | None = None) -> int:
    return run_list()


if __name__ == "__main__":
    raise SystemExit(main())
```

- [ ] **Step 4: Run test to verify it passes**

Run: `python -m pytest tools/tests/test_doctor.py -q`
Expected: PASS (5 passed).

- [ ] **Step 5: Smoke the CLIs against the seed**

Run: `python -m tools.list --% ` then `python -m tools.doctor`
Expected: `list` prints a table with `docling`; `doctor` prints a table (docling = ok if Docling installed, err if not — either is fine here) and the "N enabled tool(s)." footer. (Note: with `references/tools.yaml` not yet deployed to `~/.claude/`, run with `TOOLS_FILE=references/tools.yaml` set, e.g. PowerShell `$env:TOOLS_FILE='references/tools.yaml'; python -m tools.list`.)

- [ ] **Step 6: Commit**

```bash
git add tools/doctor.py tools/list.py tools/tests/test_doctor.py
git commit -m "feat(tools): /tools doctor + list backends"
```

---

### Task 4: kb extractors (dispatch + lazy Docling)

**Files:**
- Create: `kb/extractors/__init__.py`, `kb/extractors/pdf_docling.py`
- Test: `kb/tests/test_extractors.py`

- [ ] **Step 1: Write the failing test**

Create `kb/tests/test_extractors.py`:

```python
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `python -m pytest kb/tests/test_extractors.py -q`
Expected: FAIL — `ModuleNotFoundError: No module named 'kb.extractors'`.

- [ ] **Step 3: Write minimal implementation**

Create `kb/extractors/__init__.py`:

```python
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
```

Create `kb/extractors/pdf_docling.py`:

```python
"""Docling PDF → markdown extractor. Docling is an OPTIONAL, lazily-imported dep."""
from __future__ import annotations

from pathlib import Path


def extract_pdf(path: Path) -> str:
    """Convert a PDF to markdown text via Docling.

    Raises kb.extractors.ExtractorUnavailable if Docling is not installed,
    kb.extractors.ExtractorError if conversion fails.
    """
    # Imported here (not at top) to avoid a circular import and to keep the
    # ExtractorUnavailable/ExtractorError types in one place.
    from kb.extractors import ExtractorError, ExtractorUnavailable

    try:
        from docling.document_converter import DocumentConverter
    except ImportError as e:
        raise ExtractorUnavailable(f"docling not installed: {e}") from e

    try:
        converter = DocumentConverter()
        result = converter.convert(str(path))
        return result.document.export_to_markdown()
    except Exception as e:  # noqa: BLE001 — any conversion failure
        raise ExtractorError(f"docling failed for {path}: {e}") from e
```

> **Circular-import note:** `kb/extractors/__init__.py` imports `extract_pdf` from
> `kb.extractors.pdf_docling`, and `pdf_docling.extract_pdf` imports the exception
> types from `kb.extractors` **inside the function body** (not at module top), so the
> package initializes cleanly. Keep that import inside the function.

- [ ] **Step 4: Run test to verify it passes**

Run: `python -m pytest kb/tests/test_extractors.py -q`
Expected: PASS (7 passed).

- [ ] **Step 5: Commit**

```bash
git add kb/extractors/__init__.py kb/extractors/pdf_docling.py kb/tests/test_extractors.py
git commit -m "feat(kb): extractor dispatch + lazy Docling pdf-extract"
```

---

### Task 5: Split the chunker (chunk_text + chunk_file)

**Files:**
- Modify: `kb/chunker.py`
- Modify: `kb/tests/test_chunker.py`

- [ ] **Step 1: Write the failing test**

Add to `kb/tests/test_chunker.py` (keep all existing tests; add the import and the new test):

```python
from kb.chunker import chunk_file, chunk_text  # noqa: F401 — chunk_text is new


def test_chunk_text_direct_string() -> None:
    chunks = chunk_text("# Sec\n\nalpha body here", source="/virtual/x.pdf")
    assert len(chunks) >= 1
    assert chunks[0].source == "/virtual/x.pdf"
    assert "alpha" in "\n\n".join(c.text for c in chunks)


def test_chunk_file_routes_through_extractor(tmp_path, monkeypatch) -> None:
    import kb.chunker as chunker_mod
    fake = tmp_path / "doc.pdf"
    fake.write_bytes(b"%PDF-1.4")
    monkeypatch.setattr(chunker_mod, "extract_to_text", lambda p: "# T\n\nextracted body")
    chunks = chunk_file(fake)
    assert any("extracted body" in c.text for c in chunks)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `python -m pytest kb/tests/test_chunker.py -q`
Expected: FAIL — `ImportError: cannot import name 'chunk_text'`.

- [ ] **Step 3: Refactor the implementation**

In `kb/chunker.py`, add the extractor import near the top (after the existing imports):

```python
from kb.extractors import extract_to_text
```

Replace the existing `def chunk_file(...)` signature line and its body opening so the file-reading logic moves into a new `chunk_text`. Concretely, change the current:

```python
def chunk_file(
    path: Path,
    *,
    max_chars: int = 1500,
    overlap: int = 200,
) -> list[Chunk]:
    """Chunk a markdown (or plain text) file.
    ...docstring...
    """
    p = Path(path)
    raw = p.read_text(encoding='utf-8', errors='replace')
    if not raw.strip():
        return []

    src = str(p.resolve())
    sections = _find_sections(raw)
```

…into two functions — a new `chunk_file` that pulls text through the extractor, and a `chunk_text` holding the original body:

```python
def chunk_file(
    path: Path,
    *,
    max_chars: int = 1500,
    overlap: int = 200,
) -> list[Chunk]:
    """Chunk a corpus file. Markdown/text read directly; PDFs go through the
    tools-registry extractor (Docling). Returns [] for empty input or an
    unknown/unhandled extension; raises ExtractorUnavailable/ExtractorError for a
    PDF whose tool is missing/disabled or whose conversion failed."""
    p = Path(path)
    raw = extract_to_text(p)
    if raw is None:
        return []
    return chunk_text(raw, source=str(p.resolve()), max_chars=max_chars, overlap=overlap)


def chunk_text(
    raw: str,
    *,
    source: str,
    max_chars: int = 1500,
    overlap: int = 200,
) -> list[Chunk]:
    """Chunk an in-memory string. Heading-bounded, paragraph-respecting, overlap-friendly.

    Rules:
      - Chunks never cross a markdown heading boundary (sections are independent).
      - Within a section, paragraphs are accumulated until max_chars, then a new
        chunk starts with `overlap` trailing characters carried over for context.
      - Each chunk records its nearest preceding heading (section).
    """
    if not raw.strip():
        return []

    src = source
    sections = _find_sections(raw)
```

Everything from the existing `# Build section boundaries:` line to the final `return chunks` stays **unchanged** — it already references `raw`, `src`, `sections`, `max_chars`, `overlap`, all still in scope inside `chunk_text`.

> **Note:** the old `chunk_file` computed `src = str(p.resolve())`; `chunk_text` now
> takes `source` as a parameter and `chunk_file` passes `str(p.resolve())`, preserving
> the absolute-path contract the store relies on.

- [ ] **Step 4: Run tests to verify they pass**

Run: `python -m pytest kb/tests/test_chunker.py -q`
Expected: PASS (all existing tests + 2 new = 9 passed). The existing `.md` tests pass because `extract_to_text` reads `.md` exactly as the old `read_text` did.

- [ ] **Step 5: Commit**

```bash
git add kb/chunker.py kb/tests/test_chunker.py
git commit -m "refactor(kb): split chunker into chunk_text (pure) + extractor-fed chunk_file"
```

---

### Task 6: Indexer discovers PDFs + counts skips/errors

**Files:**
- Modify: `kb/index.py`
- Modify: `kb/tests/test_index_incremental.py`

- [ ] **Step 1: Write the failing test**

Add to `kb/tests/test_index_incremental.py` (keep existing tests; add these two). They monkeypatch the extractor so neither Docling nor a deployed `tools.yaml` is needed; embedding still runs (Ollama, per existing convention):

```python
def test_pdf_indexed_via_extractor(tmp_path: Path, monkeypatch) -> None:
    paths = _setup_corpus(tmp_path)
    # Drop a PDF into the corpus and make the extractor return markdown for it.
    pdf = paths["kb"] / "projects" / "alpha" / "spec.pdf"
    pdf.write_bytes(b"%PDF-1.4 fake")
    import kb.chunker as chunker_mod
    real = chunker_mod.extract_to_text

    def fake_extract(p):
        if str(p).lower().endswith(".pdf"):
            return "# Spec\n\nExtracted PDF body about routing."
        return real(p)

    monkeypatch.setattr(chunker_mod, "extract_to_text", fake_extract)
    idx = tmp_path / "index"
    summary = run_index(
        corpus_root=paths["kb"], jobs_root=paths["jobs"], index_dir=idx,
        full=True, print_progress=False,
    )
    assert summary["files_indexed"] == 3   # 2 md + 1 pdf
    assert summary["extractor_skips"] == 0
    assert summary["extractor_errors"] == []
    st = VectorStore(idx); st.load()
    assert any(s.endswith("spec.pdf") for s in {r["source"] for r in st.metadata})


def test_pdf_unavailable_tool_is_skipped(tmp_path: Path, monkeypatch) -> None:
    from kb.extractors import ExtractorUnavailable
    paths = _setup_corpus(tmp_path)
    pdf = paths["kb"] / "projects" / "alpha" / "spec.pdf"
    pdf.write_bytes(b"%PDF-1.4 fake")
    import kb.chunker as chunker_mod
    real = chunker_mod.extract_to_text

    def fake_extract(p):
        if str(p).lower().endswith(".pdf"):
            raise ExtractorUnavailable("pdf-extract: no enabled tool")
        return real(p)

    monkeypatch.setattr(chunker_mod, "extract_to_text", fake_extract)
    idx = tmp_path / "index"
    summary = run_index(
        corpus_root=paths["kb"], jobs_root=paths["jobs"], index_dir=idx,
        full=True, print_progress=False,
    )
    assert summary["extractor_skips"] == 1
    assert summary["files_indexed"] == 2   # the 2 md files
    # mtime recorded → a second incremental run does not retry the pdf
    summary2 = run_index(
        corpus_root=paths["kb"], jobs_root=paths["jobs"], index_dir=idx,
        full=False, print_progress=False,
    )
    assert summary2["extractor_skips"] == 0
    assert summary2["files_skipped"] == 3  # all 3 now have recorded mtimes
```

- [ ] **Step 2: Run test to verify it fails**

Run: `python -m pytest kb/tests/test_index_incremental.py -q`
Expected: FAIL — `KeyError: 'extractor_skips'` (and the PDF isn't discovered → `files_indexed == 2`).

- [ ] **Step 3: Modify the implementation**

In `kb/index.py`:

(a) Replace the `*.md`-only enumeration in `_default_corpus_paths`. Change the universal block and the per-project block to glob both extensions. Replace:

```python
    # Universal KB
    uni = corpus_root / "universal"
    if uni.exists():
        files.extend(p for p in uni.rglob("*.md") if p.is_file())
    # Per-project KB (incl. decisions/, decision-guidance.md, cost.md, etc.)
    projs = corpus_root / "projects"
    if projs.exists():
        for project_dir in projs.iterdir():
            if not project_dir.is_dir():
                continue
            files.extend(p for p in project_dir.rglob("*.md") if p.is_file())
```

with:

```python
    _CORPUS_GLOBS = ("*.md", "*.pdf")
    # Universal KB
    uni = corpus_root / "universal"
    if uni.exists():
        for glob in _CORPUS_GLOBS:
            files.extend(p for p in uni.rglob(glob) if p.is_file())
    # Per-project KB (incl. decisions/, decision-guidance.md, cost.md, etc.)
    projs = corpus_root / "projects"
    if projs.exists():
        for project_dir in projs.iterdir():
            if not project_dir.is_dir():
                continue
            for glob in _CORPUS_GLOBS:
                files.extend(p for p in project_dir.rglob(glob) if p.is_file())
```

(b) Add the import near the top of `kb/index.py` (with the other `from kb...` imports):

```python
from kb.extractors import ExtractorUnavailable, ExtractorError
```

(c) Initialize two counters alongside the existing accumulators in `run_index` (next to `embed_errors: list[str] = []`):

```python
    extractor_skips = 0
    extractor_errors: list[str] = []
```

(d) Wrap the `chunks = chunk_file(p)` call in the re-chunk loop. Replace:

```python
        # Drop any prior rows for this source before reinserting
        store.remove_source(src)
        chunks = chunk_file(p)
        if not chunks:
            store.record_source_mtime(src, _mtime_iso(p))
            continue
```

with:

```python
        # Drop any prior rows for this source before reinserting
        store.remove_source(src)
        try:
            chunks = chunk_file(p)
        except ExtractorUnavailable as e:
            extractor_skips += 1
            store.record_source_mtime(src, _mtime_iso(p))
            if print_progress:
                print(f"  ~ skipped (tool unavailable): {p.name} ({e})")
            continue
        except ExtractorError as e:
            extractor_errors.append(f"{src}: {e}")
            store.record_source_mtime(src, _mtime_iso(p))
            if print_progress:
                print(f"  ! extract failed for {src}: {e}", file=sys.stderr)
            continue
        if not chunks:
            store.record_source_mtime(src, _mtime_iso(p))
            continue
```

(e) Add the two counters to the `summary` dict (after `"embed_errors": embed_errors,`):

```python
        "extractor_skips": extractor_skips,
        "extractor_errors": extractor_errors,
```

(f) Update `main()`'s return so extractor errors also signal failure. Replace:

```python
    return 0 if not summary["embed_errors"] else 2
```

with:

```python
    return 0 if not (summary["embed_errors"] or summary["extractor_errors"]) else 2
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `python -m pytest kb/tests/test_index_incremental.py -q`
Expected: PASS (all existing + 2 new). Note `test_initial_full_index_records_mtimes` still asserts `files_indexed == 2` because that corpus has no PDF — unaffected.

- [ ] **Step 5: Run the whole KB + tools suite**

Run: `python -m pytest kb tools -q`
Expected: PASS (no regressions across kb + tools).

- [ ] **Step 6: Commit**

```bash
git add kb/index.py kb/tests/test_index_incremental.py
git commit -m "feat(kb): index discovers PDFs; count extractor skips/errors"
```

---

### Task 7: /tools command-prompt

**Files:**
- Create: `commands/tools.md`

- [ ] **Step 1: Write the command-prompt**

Create `commands/tools.md`:

```markdown
---
description: Operate the tools registry (~/.claude/tools.yaml) — the non-LLM capability sibling of /fleet. `doctor` health-checks each tool, `list` shows the registry.
argument-hint: doctor | list
---

# /tools

Operate the tool registry defined in `~/.claude/tools.yaml` — declared, cost-tiered,
capability-tagged callable capabilities (e.g. Docling for `pdf-extract`), co-equal with
the models in `/fleet`.

## Steps

1. **Parse `$ARGUMENTS`.** The first whitespace-delimited token is the subcommand:
   `doctor` or `list`. If it's neither (or empty), print usage and stop:
   *"Usage: /tools doctor | list"*.

2. **Dispatch by subcommand** (run from the repo root so `python -m tools.*` resolves):

   **`doctor`** — run:

   ```powershell
   python -m tools.doctor
   ```

   Echo the table to the user. A non-zero exit means at least one enabled tool is
   unavailable (e.g. Docling not installed) — surface which.

   **`list`** — run:

   ```powershell
   python -m tools.list
   ```

   Echo the table.

3. **On any error** (missing `tools.yaml`, etc.), surface the message and suggest
   re-running `pwsh scripts\bootstrap.ps1 -Force` to deploy the registry seed.

## Arguments

$ARGUMENTS
```

- [ ] **Step 2: Verify the backends it calls work**

Run: `$env:TOOLS_FILE='references/tools.yaml'; python -m tools.list; python -m tools.doctor; $env:TOOLS_FILE=$null`
Expected: `list` shows `docling`; `doctor` prints the table + footer.

- [ ] **Step 3: Commit**

```bash
git add commands/tools.md
git commit -m "feat(tools): /tools list|doctor command-prompt"
```

---

### Task 8: Bootstrap deploy + smoke

**Files:**
- Modify: `scripts/bootstrap.ps1`
- Modify: `scripts/test-bootstrap.ps1`

- [ ] **Step 1: Write the failing smoke assertions**

In `scripts/test-bootstrap.ps1`, next to the existing idea assertions (lines ~25-26):

```powershell
Assert "would deploy idea-lib.ps1"        ($out -match 'idea-lib\.ps1')
Assert "would deploy idea.md"             ($out -match 'idea\.md')
```

add:

```powershell
Assert "would deploy tools.yaml"          ($out -match 'tools\.yaml')
Assert "would deploy tools.md"            ($out -match 'tools\.md')
```

- [ ] **Step 2: Run the smoke to verify it fails**

Run: `pwsh -NoProfile -File scripts/test-bootstrap.ps1`
Expected: FAIL — the two new assertions fail (`tools.yaml`/`tools.md` not in dry-run stdout yet).

- [ ] **Step 3: Modify bootstrap**

(a) In `scripts/bootstrap.ps1`, add `'tools.md'` to the slash-commands deploy array (line ~232, the research-family line). Change:

```powershell
    'fleet.md','ensemble.md','research.md','six-hats.md','council.md','idea.md',
```

to:

```powershell
    'fleet.md','ensemble.md','research.md','six-hats.md','council.md','idea.md','tools.md',
```

(b) Add a new deploy step right after the Step 5b3 fleet.yaml block (after the `Copy-WithPrompt $fleetSrc $fleetDst 'fleet registry'` line):

```powershell
# --- Step 5b4: Deploy tools.yaml seed ---
Write-Step "Deploying tools.yaml seed"
$toolsSrc = Join-Path $repoRoot 'references\tools.yaml'
$toolsDst = Join-Path $claudeDir 'tools.yaml'
Copy-WithPrompt $toolsSrc $toolsDst 'tools registry'
```

- [ ] **Step 4: Run the smoke to verify it passes**

Run: `pwsh -NoProfile -File scripts/test-bootstrap.ps1`
Expected: PASS (`ALL PASS`), including the two new `tools.yaml`/`tools.md` assertions.

> If `Copy-WithPrompt` does not emit the source/destination filename in dry-run mode,
> check how it logs (it underpins the existing `fleet.yaml`/`idea` assertions, which
> already pass against dry-run stdout — match that behavior). The deployed-name string
> `tools.yaml` must appear in `$out`.

- [ ] **Step 5: Commit**

```bash
git add scripts/bootstrap.ps1 scripts/test-bootstrap.ps1
git commit -m "feat(tools): deploy tools.yaml + tools.md via bootstrap"
```

---

## Final verification (after all tasks)

- [ ] **Full Python gate:** `python -m pytest -q` → all pass (existing + new `tools/` and `kb/extractors` tests).
- [ ] **PowerShell suites:** run each of `scripts/test-idea-lib.ps1`, `scripts/test-bootstrap.ps1`, `scripts/test-run-feed-hook.ps1`, `scripts/test-statusline-feed.ps1`, and the fleet/runs suites — all `ALL PASS`.
- [ ] **Manual smoke (optional, needs Docling):** `pip install docling`, drop a real PDF under `~/.claude/knowledge/projects/<id>/sources/`, run `python -m kb.index`, then `/kb-search` a phrase from the PDF — confirm a hit. Without Docling, confirm `/kb-index` prints `skipped (tool unavailable)` and the `.md` corpus still indexes.
- [ ] **Comprehensive review** (per execution-style preference: one final review, not per-task).

## Notes for the implementer

- **Do not** add `docling` to any requirements file or always-on import. Every Docling reference is a lazy import inside `extract_pdf`.
- The `tools` package and `kb.extractors` both run from the **repo root**; there is no deploy step for Python packages (only `tools.yaml` + `tools.md` deploy to `~/.claude/`).
- Keep the exception types (`ExtractorUnavailable`, `ExtractorError`) defined **only** in `kb/extractors/__init__.py`; `pdf_docling.py` imports them inside the function to avoid a circular import.
- `chunk_text` takes `source` as a keyword-only arg; `chunk_file` supplies `str(Path(path).resolve())`. The store/search rely on `source` being the absolute path.
