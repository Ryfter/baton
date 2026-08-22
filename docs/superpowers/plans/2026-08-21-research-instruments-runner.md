# Research Instruments — Runner + Transcribe Chain Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `tools.yaml` executable — build the runner that selects and invokes non-LLM tools by capability, and prove it end-to-end by transcribing a YouTube URL to markdown.

**Architecture:** A two-layer build. `tools/invoke.py` filters enabled + host-compatible rows for a capability, ranks them (`cost_tier`, then `priority`), and executes the winner by `kind`, falling through to the next row on failure. `/baton:ingest` sits on top, sniffing source and media class and walking a capability chain. Library-specific API shapes are absorbed by thin adapters in `tools/adapters/`, never by the runner.

**Tech Stack:** Python 3.11+, PyYAML, pytest. External tools: `yt-dlp`, `ffmpeg` (present), `whisper-turbo-mlx` (`wtm`).

**Spec:** `docs/superpowers/specs/2026-08-21-research-tools-design.md`

## Global Constraints

- **`host:` is a NEW registry field.** Never overload `platform:` — it already means provider identity (`claude | codex | gemini | grok | github | local`, Lever 4).
- Host tokens are exactly: `darwin-arm64`, `darwin-x64`, `win-x64`, `linux-x64`, `linux-arm64`, `any`. Absent `host` means `any`.
- Ranking order is: host-compatible (filter, not a penalty) → `cost_tier` (`local` < `free` < `paid`) → `priority` (int, lower first, default 100).
- All transcribe rows pin **Whisper large-v3-turbo**. `wtm --quick` is **never** used (documented as "faster but choppier"). Weights are fp16, not 4-bit quantized.
- A zero-byte or whitespace-only extraction is a **failure**, never a result.
- Transports reuse `fleet.yaml` conventions: `command_template`, `stdin:`, `{{...}}` substitution.
- `references/tools.yaml` is the shared **seed**. Never put credentials, endpoints, or `enabled: true` promo rows in it.
- Test style follows `tools/tests/test_registry.py`: `from __future__ import annotations`, a `FIXTURE` YAML string, a `_write(tmp_path)` helper, `-> None` on every test.
- Run tests from the repo root: `python -m pytest tools/tests/ -v`

**Scope note:** This plan covers spec build-order steps 1–2. `kind: http` (and therefore the `ocr-5090` rows) is deferred to the next plan — it is blocked on the 5090's ollama endpoint, an open item in the spec. `kind: mcp`, documents, spreadsheets and video follow in later plans.

---

### Task 1: The `host` field and host detection

**Files:**
- Modify: `tools/registry.py:20-33` (add fields to `ToolSpec`), `tools/registry.py:44-58` (parse them)
- Create: `tools/hostinfo.py`
- Test: `tools/tests/test_hostinfo.py`, `tools/tests/test_registry.py`

**Interfaces:**
- Consumes: `ToolSpec` from `tools.registry`
- Produces: `tools.hostinfo.current_host() -> str`; `ToolSpec.host: str` (default `"any"`), `ToolSpec.priority: int` (default `100`), `ToolSpec.entrypoint: str | None`, `ToolSpec.stdin: bool`, `ToolSpec.probe_args: str | None`

- [ ] **Step 1: Write the failing test for host detection**

```python
# tools/tests/test_hostinfo.py
from __future__ import annotations

import pytest

from tools.hostinfo import current_host, host_matches


def test_current_host_is_a_known_token() -> None:
    assert current_host() in {
        "darwin-arm64", "darwin-x64", "win-x64", "linux-x64", "linux-arm64", "unknown",
    }


@pytest.mark.parametrize(
    "row_host,host,expected",
    [
        ("any", "darwin-arm64", True),
        ("darwin-arm64", "darwin-arm64", True),
        ("darwin-arm64", "win-x64", False),
        ("", "win-x64", True),          # absent host means any
    ],
)
def test_host_matches(row_host: str, host: str, expected: bool) -> None:
    assert host_matches(row_host, host) is expected
```

- [ ] **Step 2: Run it to verify it fails**

Run: `python -m pytest tools/tests/test_hostinfo.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'tools.hostinfo'`

- [ ] **Step 3: Implement `tools/hostinfo.py`**

```python
"""Host identity for tools.yaml row filtering.

Deliberately NOT `platform:` — that field already means provider identity
(claude | codex | gemini | grok | github | local, Lever 4). A row pinned to a
host you are not on is REMOVED from candidacy, never merely deprioritized.
"""
from __future__ import annotations

import platform

_SYSTEMS = {"darwin": "darwin", "windows": "win", "linux": "linux"}
_MACHINES = {
    "arm64": "arm64", "aarch64": "arm64",
    "x86_64": "x64", "amd64": "x64",
}


def current_host() -> str:
    system = _SYSTEMS.get(platform.system().lower())
    machine = _MACHINES.get(platform.machine().lower())
    if not system or not machine:
        return "unknown"
    return f"{system}-{machine}"


def host_matches(row_host: str | None, host: str | None = None) -> bool:
    """A row with no host (or 'any') runs anywhere; otherwise it must match."""
    if not row_host or row_host == "any":
        return True
    return row_host == (host or current_host())
```

- [ ] **Step 4: Run it to verify it passes**

Run: `python -m pytest tools/tests/test_hostinfo.py -v`
Expected: PASS (5 tests)

- [ ] **Step 5: Write the failing test for the new ToolSpec fields**

Append to `tools/tests/test_registry.py`:

```python
HOST_FIXTURE = """\
tools:
  - name: wtm
    kind: cli
    enabled: true
    cost_tier: local
    capability: transcribe
    host: darwin-arm64
    priority: 10
    command_template: 'wtm {{input}}'
  - name: whisper-cpp
    kind: cli
    enabled: true
    cost_tier: local
    capability: transcribe
    command_template: 'whisper-cli -f {{input}}'
"""


def test_host_and_priority_parse(tmp_path: Path) -> None:
    p = _write(tmp_path, HOST_FIXTURE)
    wtm, cpp = read_tools(p)
    assert wtm.host == "darwin-arm64"
    assert wtm.priority == 10
    assert cpp.host == "any"      # absent -> any
    assert cpp.priority == 100    # absent -> default
```

- [ ] **Step 6: Run it to verify it fails**

Run: `python -m pytest tools/tests/test_registry.py::test_host_and_priority_parse -v`
Expected: FAIL — `AttributeError: 'ToolSpec' object has no attribute 'host'`

- [ ] **Step 7: Add the fields to `ToolSpec`**

In `tools/registry.py`, add to the `@dataclass ToolSpec` after `base_url`:

```python
    host: str = "any"              # darwin-arm64 | win-x64 | ... | any
    priority: int = 100            # lower runs first; tiebreak after cost_tier
    entrypoint: str | None = None  # kind:python — "module:function" adapter
    stdin: bool = False            # kind:cli — pipe payload via stdin
    probe_args: str | None = None  # doctor: model-level probe command
    endpoint: str | None = None    # kind:http
    tool_name: str | None = None   # kind:mcp
```

And in `read_tools`, inside the `ToolSpec(...)` construction:

```python
                host=str(entry.get("host", "any") or "any"),
                priority=int(entry.get("priority", 100)),
                entrypoint=entry.get("entrypoint"),
                stdin=bool(entry.get("stdin", False)),
                probe_args=entry.get("probe_args"),
                endpoint=entry.get("endpoint"),
                tool_name=entry.get("tool_name"),
```

- [ ] **Step 8: Run the whole registry suite**

Run: `python -m pytest tools/tests/ -v`
Expected: PASS — all prior tests still green (the new fields all have defaults)

- [ ] **Step 9: Commit**

```bash
git add tools/hostinfo.py tools/registry.py tools/tests/test_hostinfo.py tools/tests/test_registry.py
git commit -m "feat(tools): add host/priority/entrypoint fields and host detection

host: is deliberately separate from platform:, which already means provider
identity (Lever 4). A row pinned to another host is removed from candidacy."
```

---

### Task 2: Selection and ranking

**Files:**
- Create: `tools/invoke.py`
- Test: `tools/tests/test_invoke_select.py`

**Interfaces:**
- Consumes: `read_tools`, `ToolSpec` (`tools.registry`); `current_host`, `host_matches` (`tools.hostinfo`)
- Produces: `tools.invoke.select_tools(capability, *, path=None, host=None, prefer=None) -> list[ToolSpec]`

**Why this is its own task:** ranking is pure logic over fabricated rows, so it is fully testable on a machine where none of these tools are installed. That is the point of splitting it from execution.

- [ ] **Step 1: Write the failing tests**

```python
# tools/tests/test_invoke_select.py
from __future__ import annotations

from pathlib import Path

from tools.invoke import select_tools

FIXTURE = """\
tools:
  - name: wtm
    kind: cli
    enabled: true
    cost_tier: local
    capability: transcribe
    host: darwin-arm64
    priority: 10
    command_template: 'wtm {{input}}'
  - name: mlx-whisper
    kind: cli
    enabled: true
    cost_tier: local
    capability: transcribe
    host: darwin-arm64
    priority: 20
    command_template: 'mlx_whisper {{input}}'
  - name: whisper-cloud
    kind: http
    enabled: true
    cost_tier: paid
    capability: transcribe
    base_url: 'https://example.invalid'
  - name: whisper-cpp
    kind: cli
    enabled: true
    cost_tier: local
    capability: transcribe
    command_template: 'whisper-cli -f {{input}}'
  - name: disabled-row
    kind: cli
    enabled: false
    cost_tier: local
    capability: transcribe
    command_template: 'nope'
"""


def _write(tmp_path: Path) -> Path:
    p = tmp_path / "tools.yaml"
    p.write_text(FIXTURE, encoding="utf-8")
    return p


def test_apple_silicon_prefers_mlx(tmp_path: Path) -> None:
    names = [s.name for s in select_tools("transcribe", path=_write(tmp_path), host="darwin-arm64")]
    assert names == ["wtm", "mlx-whisper", "whisper-cpp", "whisper-cloud"]


def test_non_apple_host_filters_mlx_out(tmp_path: Path) -> None:
    names = [s.name for s in select_tools("transcribe", path=_write(tmp_path), host="win-x64")]
    assert names == ["whisper-cpp", "whisper-cloud"]


def test_unknown_host_falls_back_to_portable(tmp_path: Path) -> None:
    names = [s.name for s in select_tools("transcribe", path=_write(tmp_path), host="unknown")]
    assert names[0] == "whisper-cpp"


def test_disabled_rows_never_selected(tmp_path: Path) -> None:
    names = [s.name for s in select_tools("transcribe", path=_write(tmp_path), host="darwin-arm64")]
    assert "disabled-row" not in names


def test_prefer_pins_one_row(tmp_path: Path) -> None:
    names = [s.name for s in select_tools(
        "transcribe", path=_write(tmp_path), host="darwin-arm64", prefer="whisper-cpp")]
    assert names == ["whisper-cpp"]


def test_unknown_capability_is_empty(tmp_path: Path) -> None:
    assert select_tools("nope", path=_write(tmp_path)) == []
```

- [ ] **Step 2: Run to verify it fails**

Run: `python -m pytest tools/tests/test_invoke_select.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'tools.invoke'`

- [ ] **Step 3: Implement `select_tools`**

```python
"""python -m tools.invoke — execute tools.yaml rows by capability.

The registry has described "least costly effective tool" since it was written;
this module is what finally executes that policy. Selection is deliberately
separable from execution so the ranking rules are testable on a machine where
none of the tools are installed.
"""
from __future__ import annotations

from pathlib import Path

from tools.hostinfo import current_host, host_matches
from tools.registry import ToolSpec, read_tools

_COST_ORDER = {"local": 0, "free": 1, "paid": 2}


def select_tools(
    capability: str,
    *,
    path: Path | None = None,
    host: str | None = None,
    prefer: str | None = None,
) -> list[ToolSpec]:
    """Enabled, host-compatible rows for a capability, best first."""
    host = host or current_host()
    rows = [
        t for t in read_tools(path)
        if t.capability == capability and t.enabled and host_matches(t.host, host)
    ]
    if prefer:
        return [t for t in rows if t.name == prefer]
    return sorted(rows, key=lambda t: (_COST_ORDER.get(t.cost_tier, 99), t.priority, t.name))
```

- [ ] **Step 4: Run to verify it passes**

Run: `python -m pytest tools/tests/test_invoke_select.py -v`
Expected: PASS (6 tests)

- [ ] **Step 5: Commit**

```bash
git add tools/invoke.py tools/tests/test_invoke_select.py
git commit -m "feat(tools): capability selection ranked by host, cost_tier, priority

Kevin's transcription rule expressed as data: MLX rows carry host:
darwin-arm64, whisper-cpp carries host: any, so whisper.cpp is the automatic
portable default with no conditionals in the runner."
```

---

### Task 3: The doctor model-level probe

**Files:**
- Modify: `tools/doctor.py:16-40` (`probe_tool`)
- Test: `tools/tests/test_doctor.py`

**Interfaces:**
- Consumes: `ToolSpec.probe_args`, `ToolSpec.host` (Task 1)
- Produces: `probe_tool(spec) -> tuple[str, str]` — unchanged signature, new behavior

**Why now:** `doctor` currently probes `kind: cli` rows by checking the executable is on `PATH`. `ollama` is on PATH, so `deepseek-ocr`, `nuextract` and `git-commit-message` all report **`ok`** today while being unrunnable — the models were never pulled. The runner would inherit that false `ok` as a runtime failure, so this must land before any capability depends on it.

- [ ] **Step 1: Write the failing tests**

Append to `tools/tests/test_doctor.py`:

```python
def test_cli_row_with_probe_args_reports_err_when_model_absent() -> None:
    spec = ToolSpec(
        name="deepseek-ocr", kind="cli", enabled=True, cost_tier="local",
        capability="ocr", command_template="ollama run deepseek-ocr",
        probe_args="python -c \"raise SystemExit(1)\"",
    )
    status, detail = probe_tool(spec)
    assert status == "err"
    assert "probe failed" in detail


def test_cli_row_with_passing_probe_reports_ok() -> None:
    spec = ToolSpec(
        name="present", kind="cli", enabled=True, cost_tier="local",
        capability="ocr", command_template="python -c pass",
        probe_args="python -c \"raise SystemExit(0)\"",
    )
    assert probe_tool(spec)[0] == "ok"


def test_row_pinned_to_another_host_is_skipped() -> None:
    spec = ToolSpec(
        name="wtm", kind="cli", enabled=True, cost_tier="local",
        capability="transcribe", command_template="wtm {{input}}",
        host="win-x64" if __import__("tools.hostinfo", fromlist=["x"]).current_host() != "win-x64" else "linux-x64",
    )
    status, detail = probe_tool(spec)
    assert status == "skip"
    assert "host" in detail
```

- [ ] **Step 2: Run to verify it fails**

Run: `python -m pytest tools/tests/test_doctor.py -v`
Expected: FAIL — the probe-args tests report `ok` (the current binary-only probe), and the host test reports `ok` instead of `skip`

- [ ] **Step 3: Implement the probe changes**

In `tools/doctor.py`, add imports and replace the `kind == "cli"` branch:

```python
import subprocess  # noqa: S404 — probe commands come from the local registry

from tools.hostinfo import current_host, host_matches
```

At the top of `probe_tool`, after the `enabled` check:

```python
    if not host_matches(spec.host):
        return "skip", f"host {spec.host} != {current_host()}"
```

And replace the cli branch body:

```python
    if spec.kind == "cli":
        exe = (spec.command_template or "").split()[0] if spec.command_template else spec.name
        if not shutil.which(exe):
            return "err", f"{exe} not on PATH"
        if not spec.probe_args:
            return "ok", f"{exe} on PATH"
        try:
            done = subprocess.run(  # noqa: S602 — registry-declared probe
                spec.probe_args, shell=True, capture_output=True, timeout=20,
            )
        except subprocess.SubprocessError as exc:
            return "err", f"probe failed: {exc}"
        if done.returncode != 0:
            return "err", f"probe failed (rc={done.returncode}): {spec.probe_args}"
        return "ok", f"{exe} + probe ok"
```

- [ ] **Step 4: Run to verify it passes**

Run: `python -m pytest tools/tests/test_doctor.py -v`
Expected: PASS — all tests including the three new ones

- [ ] **Step 5: Add `probe_args` to the three lying rows**

In `references/tools.yaml`, add to `nuextract`, `deepseek-ocr` and `git-commit-message`:

```yaml
    probe_args: 'ollama list | grep -q <model-name>'
```

Use the model each row actually runs (`nuextract`, `deepseek-ocr`, `tavernari/git-commit-message`).

- [ ] **Step 6: Confirm doctor now tells the truth**

Run: `python -m tools.doctor`
Expected: those three rows report **`err`** on this box (local ollama holds only `devstral:24b`) instead of the previous false `ok`. This is the bug being fixed — the failure is the correct output.

- [ ] **Step 7: Commit**

```bash
git add tools/doctor.py tools/tests/test_doctor.py references/tools.yaml
git commit -m "fix(tools): doctor probes models, not just binaries

kind:cli rows were probed by executable-on-PATH, so 'ollama run deepseek-ocr'
reported ok while being unrunnable — the model was never pulled. Three rows
were in that state. Adds probe_args plus host-mismatch skip."
```

---

### Task 4: `ToolResult` and the `cli` transport

**Files:**
- Modify: `tools/invoke.py`
- Test: `tools/tests/test_invoke_exec.py`

**Interfaces:**
- Consumes: `select_tools` (Task 2)
- Produces: `Payload` and `ToolResult` dataclasses; `invoke(capability, payload, *, path=None, prefer=None) -> ToolResult`; `render_template(template, payload) -> str`

- [ ] **Step 1: Write the failing tests**

```python
# tools/tests/test_invoke_exec.py
from __future__ import annotations

from pathlib import Path

from tools.invoke import Payload, ToolResult, invoke, render_template

FIXTURE = """\
tools:
  - name: failing
    kind: cli
    enabled: true
    cost_tier: local
    capability: transcribe
    priority: 10
    command_template: 'python -c "raise SystemExit(3)"'
  - name: working
    kind: cli
    enabled: true
    cost_tier: local
    capability: transcribe
    priority: 20
    command_template: 'python -c "print(\\'hello transcript\\')"'
  - name: empty-output
    kind: cli
    enabled: true
    cost_tier: local
    capability: blankcap
    command_template: 'python -c "print(\\'\\')"'
"""


def _write(tmp_path: Path) -> Path:
    p = tmp_path / "tools.yaml"
    p.write_text(FIXTURE, encoding="utf-8")
    return p


def test_render_template_substitutes_input(tmp_path: Path) -> None:
    payload = Payload(input_path=tmp_path / "a.mp3")
    assert render_template("wtm {{input}}", payload) == f"wtm {tmp_path / 'a.mp3'}"


def test_first_success_wins_and_failures_fall_through(tmp_path: Path) -> None:
    result = invoke("transcribe", Payload(input_path=tmp_path / "a.mp3"), path=_write(tmp_path))
    assert result.ok is True
    assert result.tool_name == "working"
    assert "hello transcript" in result.text
    assert [a[0] for a in result.attempts] == ["failing", "working"]


def test_all_rows_failed_names_every_attempt(tmp_path: Path) -> None:
    result = invoke("transcribe", Payload(input_path=tmp_path / "a.mp3"),
                    path=_write(tmp_path), prefer="failing")
    assert result.ok is False
    assert "failing" in result.error
    assert len(result.attempts) == 1


def test_no_rows_for_capability_is_a_clear_failure(tmp_path: Path) -> None:
    result = invoke("nonexistent", Payload(input_path=tmp_path / "a.mp3"), path=_write(tmp_path))
    assert result.ok is False
    assert "no enabled tool" in result.error


def test_whitespace_only_output_is_a_failure(tmp_path: Path) -> None:
    result = invoke("blankcap", Payload(input_path=tmp_path / "a.mp3"), path=_write(tmp_path))
    assert result.ok is False
    assert "empty output" in result.error
```

- [ ] **Step 2: Run to verify it fails**

Run: `python -m pytest tools/tests/test_invoke_exec.py -v`
Expected: FAIL — `ImportError: cannot import name 'Payload' from 'tools.invoke'`

- [ ] **Step 3: Implement the dataclasses and cli execution**

Append to `tools/invoke.py`:

```python
import shlex
import subprocess  # noqa: S404 — commands come from the local registry
import time
from dataclasses import dataclass, field


@dataclass
class Payload:
    input_path: Path | None = None
    url: str | None = None
    media_class: str | None = None
    options: dict = field(default_factory=dict)


@dataclass
class ToolResult:
    ok: bool
    tool_name: str | None = None
    text: str = ""
    output_path: Path | None = None
    duration_s: float = 0.0
    error: str = ""
    attempts: list[tuple[str, str]] = field(default_factory=list)


def render_template(template: str, payload: Payload) -> str:
    out = template.replace("{{input}}", str(payload.input_path or ""))
    out = out.replace("{{url}}", payload.url or "")
    out = out.replace("{{output}}", str(payload.options.get("output", "")))
    return out.replace("{{model}}", str(payload.options.get("model", "")))


def _run_cli(spec: ToolSpec, payload: Payload) -> tuple[bool, str, str]:
    """Return (ok, text, error)."""
    cmd = render_template(spec.command_template or "", payload)
    stdin_data = payload.options.get("stdin_text", "") if spec.stdin else None
    try:
        done = subprocess.run(  # noqa: S602 — registry-declared command
            cmd, shell=True, capture_output=True, text=True,
            input=stdin_data, timeout=payload.options.get("timeout_s", 1800),
        )
    except subprocess.SubprocessError as exc:
        return False, "", f"{spec.name}: {exc}"
    if done.returncode != 0:
        return False, "", f"{spec.name}: rc={done.returncode} {done.stderr.strip()[:300]}"
    if not done.stdout.strip():
        return False, "", f"{spec.name}: empty output"
    return True, done.stdout, ""


_RUNNERS = {"cli": _run_cli}


def invoke(
    capability: str,
    payload: Payload,
    *,
    path: Path | None = None,
    prefer: str | None = None,
) -> ToolResult:
    """Run the best available tool for a capability, falling through on failure."""
    rows = select_tools(capability, path=path, prefer=prefer)
    if not rows:
        return ToolResult(ok=False, error=f"no enabled tool for capability {capability!r}")
    attempts: list[tuple[str, str]] = []
    for spec in rows:
        runner = _RUNNERS.get(spec.kind)
        if runner is None:
            attempts.append((spec.name, f"unsupported kind: {spec.kind}"))
            continue
        started = time.monotonic()
        ok, text, error = runner(spec, payload)
        elapsed = time.monotonic() - started
        attempts.append((spec.name, "ok" if ok else error))
        if ok:
            return ToolResult(ok=True, tool_name=spec.name, text=text,
                              duration_s=elapsed, attempts=attempts)
    tried = "; ".join(f"{n}: {why}" for n, why in attempts)
    return ToolResult(ok=False, error=f"all rows failed for {capability!r} — {tried}",
                      attempts=attempts)
```

Add `import shlex` only if you use it; remove it otherwise — do not leave an unused import.

- [ ] **Step 4: Run to verify it passes**

Run: `python -m pytest tools/tests/test_invoke_exec.py -v`
Expected: PASS (5 tests)

- [ ] **Step 5: Run the full suite**

Run: `python -m pytest tools/tests/ -v`
Expected: PASS — nothing regressed

- [ ] **Step 6: Commit**

```bash
git add tools/invoke.py tools/tests/test_invoke_exec.py
git commit -m "feat(tools): ToolResult + cli transport with fall-through

Empty or whitespace-only output is a failure, never a result — the runner must
not report success for an extraction that produced nothing."
```

---

### Task 5: The `python` transport and the adapter layer

**Files:**
- Modify: `tools/invoke.py` (add `_run_python`, register it in `_RUNNERS`)
- Create: `tools/adapters/__init__.py`
- Test: `tools/tests/test_invoke_python.py`, `tools/tests/fake_adapter.py`

**Interfaces:**
- Consumes: `Payload`, `ToolResult`, `_RUNNERS` (Task 4)
- Produces: adapter contract — a callable `fn(payload: Payload) -> ToolResult`, named by `entrypoint: "module.path:function"`

**Why an adapter layer:** a library's real API is rarely a one-liner. Docling's is `DocumentConverter().convert(path).document.export_to_markdown()`, which a bare `module:` path cannot express. `module` stays as doctor's *probe* target; `entrypoint` is the *call* target. Third-party API churn is absorbed in one small file per library instead of leaking into the runner.

- [ ] **Step 1: Write the failing tests**

```python
# tools/tests/fake_adapter.py
from __future__ import annotations

from tools.invoke import Payload, ToolResult


def good(payload: Payload) -> ToolResult:
    return ToolResult(ok=True, text=f"converted {payload.input_path}")


def bad(payload: Payload) -> ToolResult:
    raise RuntimeError("adapter exploded")
```

```python
# tools/tests/test_invoke_python.py
from __future__ import annotations

from pathlib import Path

from tools.invoke import Payload, invoke

FIXTURE = """\
tools:
  - name: broken-adapter
    kind: python
    enabled: true
    cost_tier: local
    capability: pdf-extract
    priority: 10
    module: tools.registry
    entrypoint: tools.tests.fake_adapter:bad
  - name: good-adapter
    kind: python
    enabled: true
    cost_tier: local
    capability: pdf-extract
    priority: 20
    module: tools.registry
    entrypoint: tools.tests.fake_adapter:good
  - name: missing-entrypoint
    kind: python
    enabled: true
    cost_tier: local
    capability: noentry
    module: tools.registry
"""


def _write(tmp_path: Path) -> Path:
    p = tmp_path / "tools.yaml"
    p.write_text(FIXTURE, encoding="utf-8")
    return p


def test_adapter_exception_falls_through_to_next_row(tmp_path: Path) -> None:
    result = invoke("pdf-extract", Payload(input_path=Path("/tmp/a.pdf")), path=_write(tmp_path))
    assert result.ok is True
    assert result.tool_name == "good-adapter"
    assert "converted" in result.text
    assert [a[0] for a in result.attempts] == ["broken-adapter", "good-adapter"]


def test_python_row_without_entrypoint_is_an_error(tmp_path: Path) -> None:
    result = invoke("noentry", Payload(input_path=Path("/tmp/a.pdf")), path=_write(tmp_path))
    assert result.ok is False
    assert "entrypoint" in result.error
```

- [ ] **Step 2: Run to verify it fails**

Run: `python -m pytest tools/tests/test_invoke_python.py -v`
Expected: FAIL — `unsupported kind: python`

- [ ] **Step 3: Implement `_run_python`**

Create `tools/adapters/__init__.py` (empty docstring file):

```python
"""Thin per-library adapters. Each exposes fn(payload) -> ToolResult, named by a
row's `entrypoint:`. Third-party API churn is absorbed here, not in the runner."""
```

Add to `tools/invoke.py`:

```python
import importlib


def _run_python(spec: ToolSpec, payload: Payload) -> tuple[bool, str, str]:
    if not spec.entrypoint or ":" not in spec.entrypoint:
        return False, "", f"{spec.name}: no entrypoint declared (want 'module:function')"
    mod_name, _, fn_name = spec.entrypoint.partition(":")
    try:
        fn = getattr(importlib.import_module(mod_name), fn_name)
    except (ImportError, AttributeError) as exc:
        return False, "", f"{spec.name}: cannot load {spec.entrypoint} ({exc})"
    try:
        result = fn(payload)
    except Exception as exc:  # noqa: BLE001 — any adapter failure falls through
        return False, "", f"{spec.name}: {exc}"
    if not result.ok:
        return False, "", f"{spec.name}: {result.error or 'adapter reported failure'}"
    if not (result.text or "").strip() and result.output_path is None:
        return False, "", f"{spec.name}: empty output"
    return True, result.text, ""
```

Register it: `_RUNNERS = {"cli": _run_cli, "python": _run_python}`

- [ ] **Step 4: Run to verify it passes**

Run: `python -m pytest tools/tests/test_invoke_python.py -v`
Expected: PASS (2 tests)

- [ ] **Step 5: Commit**

```bash
git add tools/invoke.py tools/adapters/ tools/tests/test_invoke_python.py tools/tests/fake_adapter.py
git commit -m "feat(tools): python transport via entrypoint adapters

module: stays doctor's probe target; entrypoint: is the call target. Adapters
absorb library API shape so it never leaks into the runner."
```

---

### Task 6: Install the transcription toolchain and register the rows

**Files:**
- Modify: `references/tools.yaml`
- Test: `tools/tests/test_transcribe_rows.py`

**Interfaces:**
- Consumes: `select_tools` (Task 2)
- Produces: capability `transcribe` with rows `wtm`, `mlx-whisper`, `whisper-cpp`

- [ ] **Step 1: Install the Apple Silicon toolchain**

```bash
uv pip install --system whisper-turbo-mlx mlx-whisper
which wtm
```
Expected: `wtm` on PATH. If `--system` is rejected, use the project's venv.

- [ ] **Step 2: Verify wtm actually transcribes**

```bash
ffmpeg -f lavfi -i "sine=frequency=440:duration=3" -ar 16000 /tmp/probe.wav -y
wtm /tmp/probe.wav
```
Expected: exits 0 and prints something. A tone yields no words — that is fine; you are proving the binary runs, not measuring accuracy.

- [ ] **Step 3: Write the failing test for row ordering**

```python
# tools/tests/test_transcribe_rows.py
from __future__ import annotations

from pathlib import Path

from tools.invoke import select_tools

SEED = Path(__file__).resolve().parents[2] / "references" / "tools.yaml"


def test_apple_silicon_ranks_wtm_first() -> None:
    names = [s.name for s in select_tools("transcribe", path=SEED, host="darwin-arm64")]
    assert names[:2] == ["wtm", "mlx-whisper"]


def test_portable_host_gets_whisper_cpp() -> None:
    names = [s.name for s in select_tools("transcribe", path=SEED, host="win-x64")]
    assert names == ["whisper-cpp"]


def test_no_row_uses_the_quick_flag() -> None:
    """--quick is documented as 'faster but choppier'; precision outranks speed."""
    text = SEED.read_text(encoding="utf-8")
    assert "--quick" not in text
```

- [ ] **Step 4: Run to verify it fails**

Run: `python -m pytest tools/tests/test_transcribe_rows.py -v`
Expected: FAIL — no `transcribe` rows exist yet

- [ ] **Step 5: Add the rows to `references/tools.yaml`**

```yaml
  # ── transcribe: Whisper large-v3-turbo everywhere. Seating is DATA, not logic —
  # the MLX rows carry host: darwin-arm64, whisper-cpp carries host: any, so on
  # Windows/Linux/unknown the MLX rows are filtered out and whisper.cpp is simply
  # what remains. NEVER add --quick ("faster but choppier"); precision outranks
  # speed here. Weights must be fp16, not 4-bit — quantized MLX repos are the
  # quiet precision cost in this stack.
  - name: wtm
    kind: cli
    enabled: true
    cost_tier: local
    role: draft
    platform: local
    host: darwin-arm64
    priority: 10
    capability: transcribe
    command_template: 'wtm "{{input}}" --timestamps'
    probe_args: 'wtm --help'
  - name: mlx-whisper
    kind: cli
    enabled: true
    cost_tier: local
    role: draft
    platform: local
    host: darwin-arm64
    priority: 20
    capability: transcribe
    command_template: 'mlx_whisper "{{input}}" --model mlx-community/whisper-large-v3-turbo'
    probe_args: 'mlx_whisper --help'
  - name: whisper-cpp
    kind: cli
    enabled: true
    cost_tier: local
    role: draft
    platform: local
    priority: 30
    capability: transcribe
    command_template: 'whisper-cli -m {{model}} -f "{{input}}"'
    probe_args: 'whisper-cli --help'
```

- [ ] **Step 6: Run to verify it passes**

Run: `python -m pytest tools/tests/test_transcribe_rows.py -v`
Expected: PASS (3 tests)

- [ ] **Step 7: Confirm doctor reports honestly**

Run: `python -m tools.doctor`
Expected: `wtm` and `mlx-whisper` report `ok`; `whisper-cpp` reports `err` (not installed — brew install is optional per Kevin) and the three ollama rows report `err`.

- [ ] **Step 8: Commit**

```bash
git add references/tools.yaml tools/tests/test_transcribe_rows.py
git commit -m "feat(tools): transcribe rows — MLX on Apple Silicon, whisper.cpp portable

All pin large-v3-turbo (first on Ryfter/asr-bench: 8.9% WER, ~65x realtime).
A regression test asserts --quick never appears in the seed."
```

---

### Task 7: `fetch-media` — URL to local audio

**Files:**
- Modify: `references/tools.yaml`
- Create: `tools/adapters/media.py`
- Test: `tools/tests/test_media_adapter.py`

**Interfaces:**
- Consumes: `Payload`, `ToolResult` (Task 4)
- Produces: `tools.adapters.media:fetch` (entrypoint for the `yt-dlp` row); `tools.adapters.media.strip_audio(video_path, out_dir) -> Path`

- [ ] **Step 1: Install yt-dlp**

```bash
brew install yt-dlp && yt-dlp --version
```

- [ ] **Step 2: Write the failing test**

```python
# tools/tests/test_media_adapter.py
from __future__ import annotations

import subprocess
from pathlib import Path

import pytest

from tools.adapters.media import strip_audio


def _make_video(path: Path) -> Path:
    subprocess.run(
        ["ffmpeg", "-f", "lavfi", "-i", "testsrc=duration=2:size=128x128:rate=10",
         "-f", "lavfi", "-i", "sine=frequency=440:duration=2",
         "-shortest", "-y", str(path)],
        check=True, capture_output=True,
    )
    return path


def test_strip_audio_produces_16k_wav(tmp_path: Path) -> None:
    video = _make_video(tmp_path / "in.mp4")
    out = strip_audio(video, tmp_path)
    assert out.exists()
    assert out.suffix == ".wav"
    assert out.stat().st_size > 0


def test_strip_audio_raises_on_missing_input(tmp_path: Path) -> None:
    with pytest.raises(FileNotFoundError):
        strip_audio(tmp_path / "nope.mp4", tmp_path)
```

- [ ] **Step 3: Run to verify it fails**

Run: `python -m pytest tools/tests/test_media_adapter.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'tools.adapters.media'`

- [ ] **Step 4: Implement the adapter**

```python
# tools/adapters/media.py
"""Media adapters: URL fetch (yt-dlp) and video audio-strip (ffmpeg).

Video never goes to a transcriber whole — the audio track is stripped to 16kHz
mono WAV first, which is what every Whisper variant wants anyway.
"""
from __future__ import annotations

import subprocess  # noqa: S404 — fixed local binaries, no user-supplied argv
from pathlib import Path

from tools.invoke import Payload, ToolResult


def strip_audio(video_path: Path, out_dir: Path) -> Path:
    if not Path(video_path).exists():
        raise FileNotFoundError(video_path)
    out = Path(out_dir) / (Path(video_path).stem + ".wav")
    subprocess.run(
        ["ffmpeg", "-i", str(video_path), "-vn", "-acodec", "pcm_s16le",
         "-ar", "16000", "-ac", "1", "-y", str(out)],
        check=True, capture_output=True,
    )
    return out


def fetch(payload: Payload) -> ToolResult:
    """Download a URL's audio track to a local mp3 via yt-dlp."""
    if not payload.url:
        return ToolResult(ok=False, error="fetch-media requires a url")
    out_dir = Path(payload.options.get("out_dir", "."))
    out_dir.mkdir(parents=True, exist_ok=True)
    template = str(out_dir / "%(id)s.%(ext)s")
    try:
        subprocess.run(
            ["yt-dlp", "-x", "--audio-format", "mp3", "--no-playlist",
             "-o", template, payload.url],
            check=True, capture_output=True, text=True, timeout=1800,
        )
    except subprocess.CalledProcessError as exc:
        return ToolResult(ok=False, error=f"yt-dlp: {exc.stderr.strip()[:300]}")
    except subprocess.SubprocessError as exc:
        return ToolResult(ok=False, error=f"yt-dlp: {exc}")
    produced = sorted(out_dir.glob("*.mp3"), key=lambda p: p.stat().st_mtime)
    if not produced:
        return ToolResult(ok=False, error="yt-dlp produced no audio file")
    return ToolResult(ok=True, output_path=produced[-1], text=str(produced[-1]))
```

- [ ] **Step 5: Run to verify it passes**

Run: `python -m pytest tools/tests/test_media_adapter.py -v`
Expected: PASS (2 tests)

- [ ] **Step 6: Register the row in `references/tools.yaml`**

```yaml
  - name: yt-dlp
    kind: python
    enabled: true
    cost_tier: local
    role: draft
    platform: local
    capability: fetch-media
    module: subprocess
    entrypoint: tools.adapters.media:fetch
    probe_args: 'yt-dlp --version'
```

- [ ] **Step 7: Commit**

```bash
git add tools/adapters/media.py tools/tests/test_media_adapter.py references/tools.yaml
git commit -m "feat(tools): fetch-media via yt-dlp + ffmpeg audio strip

Video is never handed to a transcriber whole — the audio track is stripped to
16kHz mono WAV, which is what every Whisper variant wants."
```

---

### Task 8: `/baton:ingest` — the audio and video chain end to end

**Files:**
- Create: `tools/ingest.py`, `commands/ingest.md`
- Test: `tools/tests/test_ingest.py`

**Interfaces:**
- Consumes: `invoke`, `Payload` (Task 4); `strip_audio` (Task 7)
- Produces: `tools.ingest.classify(source) -> tuple[str, str]` returning `(source_kind, media_class)`; `tools.ingest.ingest(source, *, out_dir=None, prefer=None) -> ToolResult`; `tools.ingest.to_markdown(text, *, source, tool, duration_s) -> str`

- [ ] **Step 1: Write the failing tests**

```python
# tools/tests/test_ingest.py
from __future__ import annotations

from pathlib import Path

import pytest

from tools.ingest import classify, to_markdown


@pytest.mark.parametrize(
    "source,expected",
    [
        ("https://youtube.com/watch?v=abc", ("url", "media")),
        ("/tmp/talk.mp3", ("path", "audio")),
        ("/tmp/talk.wav", ("path", "audio")),
        ("/tmp/lecture.mp4", ("path", "video")),
        ("/tmp/paper.pdf", ("path", "document")),
        ("/tmp/data.xlsx", ("path", "spreadsheet")),
        ("/tmp/slide.png", ("path", "image")),
        ("/tmp/notes.zzz", ("path", "unknown")),
    ],
)
def test_classify(source: str, expected: tuple[str, str]) -> None:
    assert classify(source) == expected


def test_markdown_carries_provenance() -> None:
    md = to_markdown("hello", source="/tmp/a.mp3", tool="wtm", duration_s=1.5)
    assert md.startswith("---")
    assert "source: /tmp/a.mp3" in md
    assert "tool: wtm" in md
    assert "hello" in md
```

- [ ] **Step 2: Run to verify it fails**

Run: `python -m pytest tools/tests/test_ingest.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'tools.ingest'`

- [ ] **Step 3: Implement `tools/ingest.py`**

```python
"""/baton:ingest — sniff a source, walk its capability chain, emit markdown.

Documents, spreadsheets and images are classified here but their chains land in
a later plan; this module ships the audio and video paths.
"""
from __future__ import annotations

import datetime as _dt
import tempfile
from pathlib import Path

from tools.adapters.media import strip_audio
from tools.invoke import Payload, ToolResult, invoke

_MEDIA_CLASSES = {
    "audio": {".mp3", ".wav", ".m4a", ".flac", ".ogg", ".aac"},
    "video": {".mp4", ".mkv", ".webm", ".mov", ".avi"},
    "document": {".pdf", ".docx", ".pptx", ".doc", ".odt"},
    "spreadsheet": {".xlsx", ".xls", ".csv"},
    "image": {".png", ".jpg", ".jpeg", ".gif", ".webp", ".tiff"},
}


def classify(source: str) -> tuple[str, str]:
    """Return (source_kind, media_class): ('url'|'path', 'audio'|'video'|...)."""
    if "://" in source:
        return "url", "media"
    suffix = Path(source).suffix.lower()
    for media_class, suffixes in _MEDIA_CLASSES.items():
        if suffix in suffixes:
            return "path", media_class
    return "path", "unknown"


def to_markdown(text: str, *, source: str, tool: str, duration_s: float) -> str:
    stamp = _dt.datetime.now(_dt.timezone.utc).isoformat(timespec="seconds")
    return (
        "---\n"
        f"source: {source}\n"
        f"tool: {tool}\n"
        f"ingested: {stamp}\n"
        f"duration_s: {duration_s:.1f}\n"
        "---\n\n"
        f"{text.strip()}\n"
    )


def ingest(source: str, *, out_dir: Path | None = None, prefer: str | None = None) -> ToolResult:
    work = Path(out_dir or tempfile.mkdtemp(prefix="baton-ingest-"))
    work.mkdir(parents=True, exist_ok=True)
    source_kind, media_class = classify(source)

    if source_kind == "url":
        fetched = invoke("fetch-media", Payload(url=source, options={"out_dir": str(work)}))
        if not fetched.ok:
            return fetched
        local = Path(fetched.output_path)
        media_class = "audio"
    else:
        local = Path(source)
        if not local.exists():
            return ToolResult(ok=False, error=f"no such file: {local}")

    if media_class == "video":
        try:
            local = strip_audio(local, work)
        except Exception as exc:  # noqa: BLE001 — surfaced as a clean failure
            return ToolResult(ok=False, error=f"ffmpeg audio strip failed: {exc}")
        media_class = "audio"

    if media_class != "audio":
        return ToolResult(ok=False, error=f"media class {media_class!r} not yet supported")

    result = invoke("transcribe", Payload(input_path=local, media_class="audio"), prefer=prefer)
    if not result.ok:
        return result
    result.text = to_markdown(
        result.text, source=source, tool=result.tool_name or "?", duration_s=result.duration_s
    )
    return result
```

- [ ] **Step 4: Run to verify it passes**

Run: `python -m pytest tools/tests/test_ingest.py -v`
Expected: PASS (9 tests)

- [ ] **Step 5: Write the command file**

Create `commands/ingest.md`, following the shape of `commands/tools.md`:

```markdown
---
description: Convert a document, audio file, video, or URL into markdown via the least costly effective tool. Sniffs the source and walks its capability chain.
---

1. **Parse arguments.** `$ARGUMENTS` is `<path-or-url> [--out <dir>] [--tool <name>]`.
   With no arguments, print: *"Usage: /baton:ingest <path-or-url> [--out <dir>] [--tool <name>]"*.

2. **Run it** (from the repo root so `python -m tools.*` resolves):

   ```bash
   python -m tools.ingest "<source>" [--out <dir>] [--tool <name>]
   ```

3. **Report** the tool that won, the fall-through attempts if any, and where the
   markdown landed. If every row failed, show each attempt and why — never
   report success for empty output.
```

- [ ] **Step 6: Add the CLI entry to `tools/ingest.py`**

```python
def main(argv: list[str] | None = None) -> int:
    import argparse

    parser = argparse.ArgumentParser(prog="python -m tools.ingest")
    parser.add_argument("source")
    parser.add_argument("--out", default=None)
    parser.add_argument("--tool", default=None)
    args = parser.parse_args(argv)

    result = ingest(args.source, out_dir=Path(args.out) if args.out else None, prefer=args.tool)
    if not result.ok:
        print(f"FAILED: {result.error}")
        return 1
    print(f"# via {result.tool_name} in {result.duration_s:.1f}s\n")
    print(result.text)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
```

- [ ] **Step 7: Prove the whole chain end to end**

```bash
ffmpeg -f lavfi -i "sine=frequency=440:duration=3" -ar 16000 /tmp/e2e.wav -y
python -m tools.ingest /tmp/e2e.wav
```
Expected: exit 0, markdown with `tool: wtm` front-matter.

Then the real target — a short YouTube video:

```bash
python -m tools.ingest "https://www.youtube.com/watch?v=<short-video-id>"
```
Expected: yt-dlp fetches the audio, wtm transcribes it, markdown prints with provenance. **This is the plan's acceptance criterion.**

- [ ] **Step 8: Run the full suite**

Run: `python -m pytest tools/tests/ -v`
Expected: PASS — every test across all eight tasks

- [ ] **Step 9: Commit**

```bash
git add tools/ingest.py commands/ingest.md tools/tests/test_ingest.py
git commit -m "feat(baton): /baton:ingest — URL and file to markdown

Closes the loop: tools.yaml is executable and a YouTube URL becomes a
timestamped transcript through the least costly effective tool."
```

---

## Done when

- `python -m pytest tools/tests/ -v` is green.
- `python -m tools.doctor` reports honestly — including `err` for the three ollama rows that report a false `ok` today.
- `python -m tools.ingest "<youtube-url>"` produces markdown with provenance front-matter.
- `tools.yaml` is executable for the first time since it was written.

## Deferred to later plans

| Deferred | Blocked on |
|---|---|
| `kind: http` + `ocr-5090` rows | the 5090's ollama endpoint (open item in the spec) |
| `pdf-extract` + docling adapter | nothing — next plan |
| Spreadsheet schema + CSV sidecar branch | the document chain |
| `video-understand` (Gemini) | nothing — rarest path |
| `kind: mcp` + Pi containers | capability contracts proving out first |
| n8n rows | same |
