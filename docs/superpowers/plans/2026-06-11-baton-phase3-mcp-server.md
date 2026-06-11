# Baton Phase 3 — MCP Server Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A Python MCP server (`baton_mcp`) exposing Baton's core capabilities as MCP tools — `baton_route`, `baton_capabilities`, `baton_kb_search`, `baton_job_status`, `baton_job_list`, `baton_fleet_list`, `baton_fleet_doctor`, `baton_fleet_test` — bundled in the plugin via `.mcp.json` and registrable in Codex/Cursor.

**Architecture:** Thin adapter, no logic fork. One PowerShell entry script `scripts/mcp-bridge.ps1` takes `-Op <name> -ArgsPath <json-file>` (args via file = 965-byte rule), dot-sources the existing libs, and prints ONE JSON envelope `{ok, ...}` to stdout. The Python side (`baton_mcp/`) is a FastMCP stdio server whose tools call `bridge.run_op()` (subprocess → pwsh → JSON). Exception: `baton_kb_search` calls the existing `kb.search` Python module in-process (it IS the existing logic — calling Python from Python via pwsh would be the fork). Everything reads the same `BATON_HOME`.

**Tech Stack:** Python 3.14, `mcp` SDK 1.25.0 (`mcp.server.fastmcp.FastMCP`, stdio transport), PowerShell 7, pytest.

**Spec:** `docs/superpowers/specs/2026-06-11-baton-rebrand-and-packaging-design.md` (Phase 3 section).

**Verified facts (don't re-research):** `.mcp.json` lives at plugin ROOT, schema `{"mcpServers": {"baton": {"command": ..., "args": [...], "env": {...}}}}`; `${CLAUDE_PLUGIN_ROOT}` substitutes inside command/args/env; tools surface as `mcp__baton__<tool>`; no cmd /c wrapper needed on Windows; Codex registration: `codex mcp add baton -- python -m baton_mcp` (env via `--env`); Cursor: `~/.cursor/mcp.json` same stdio shape, ~40-tool soft ceiling across servers (we add 8). `mcp` 1.25.0 is installed for the system Python that runs the repo's tests.

---

## Scope decisions locked in this plan (capture as one d-record at the end)

1. **One bridge script, not per-op wrappers** — a single `scripts/mcp-bridge.ps1` with an `-Op` switch keeps the PS surface testable in PS land and the Python side dumb.
2. **Args always via JSON file** (`-ArgsPath`), never inline shell args — the 965-byte rule by construction.
3. **`baton_kb_search` is in-process Python** — `kb.search` is already the canonical implementation; shelling pwsh→python would fork nothing but latency.
4. **Bridge errors return `{ok:false, error}` with exit 0** — MCP tools should surface failures as structured results, not crashed subprocesses; exit 1 is reserved for catastrophic launcher failures.
5. **`fleet-doctor.ps1` gains a `-Json` switch** (emit the existing `$rows` as JSON, suppress the table) — backward compatible; bridge consumes JSON instead of scraping a formatted table.
6. **`baton_route` is one tool with two modes** — no `prompt` → recommendation (Select-Capability); with `prompt` → dispatch ladder (Invoke-RoutedCapability). Mirrors `/baton:route` vs `--run`.
7. **Server name `baton`, 8 tools** — well under every client's tool budget.
8. **Cross-tool registration targets the REPO path, not the plugin cache** (cache path changes per plugin version); `.mcp.json` (Claude) uses `${CLAUDE_PLUGIN_ROOT}` since Claude re-resolves it per version.
9. **`BATON_MCP_BRIDGE` env override** lets `.mcp.json`/tests pin the bridge script; default resolves relative to the `baton_mcp` package (repo and plugin-cache layouts are identical).

---

### Task 1: `scripts/mcp-bridge.ps1` + `fleet-doctor -Json` (TDD)

**Files:**
- Create: `scripts/mcp-bridge.ps1`, `scripts/test-mcp-bridge.ps1`
- Modify: `scripts/fleet-doctor.ps1` (add `[switch]$Json` param; when set, print `$rows | ConvertTo-Json` instead of the Format-Table block and suppress all other host output; keep exit-code semantics)

- [ ] **Step 1: Write the failing test** — `scripts/test-mcp-bridge.ps1`, modeled on the repo's Assert pattern. It must isolate via `$env:BATON_HOME` = temp dir seeded with fixture `fleet.yaml`/`tools.yaml` (copy minimal fixtures the way `test-routing-lib.ps1` builds them — read that file for the fixture shapes) and a fixture job under `jobs/j-test/manifest.yaml` + `current-job.json`. Every case invokes `pwsh -NoProfile -File scripts/mcp-bridge.ps1 -Op <op> [-ArgsPath <tmp.json>]`, parses stdout as JSON, asserts:
  - `capabilities` → `ok=true`, `capabilities` is a non-empty string array
  - `route-select` (args `{"capability":"<one from fixtures>"}`) → `ok=true`, candidates array with `name/kind/source/cost_tier/quality/why`
  - `fleet-list` → `ok=true`, providers with `name/kind/enabled/cost_tier`
  - `fleet-doctor` → `ok=true`, `rows` array present, `healthy` boolean
  - `job-status` → `ok=true, active=true, job_id='j-test'`, manifest has title
  - `job-status` with no current-job.json → `active=false`
  - `job-list` (args `{"filter":"all"}`) → one job with id `j-test`
  - unknown op → `ok=false`, error mentions the op, exit 0
  - missing/garbage ArgsPath → does not crash (`ok` present)
  - `route-dispatch` with a nonexistent capability → `ok=true, status='no-candidate'` (or `ok=false` — match the lib's actual behavior, read `Invoke-RoutedCapability`)
  Run → FAIL (bridge missing).

- [ ] **Step 2: Implement `scripts/mcp-bridge.ps1`:**

```powershell
#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Single PowerShell entry for the baton_mcp MCP server (Phase 3). Thin adapter:
  dot-sources the existing libs and prints ONE JSON envelope to stdout.
.DESCRIPTION
  Args arrive via a JSON file (-ArgsPath) — never inline — per the 965-byte
  shell-argument rule. Errors are returned as {ok:false, error} with exit 0 so
  the MCP layer gets structured failures; exit 1 only if even that fails.
#>
param(
    [Parameter(Mandatory)][string]$Op,
    [string]$ArgsPath
)
$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
function Out-Json($obj) { $obj | ConvertTo-Json -Depth 8 -Compress }

try {
    $a = @{}
    if ($ArgsPath -and (Test-Path $ArgsPath)) {
        $raw = Get-Content -LiteralPath $ArgsPath -Raw
        if (-not [string]::IsNullOrWhiteSpace($raw)) {
            ($raw | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $a[$_.Name] = $_.Value }
        }
    }
    switch ($Op) {
        'capabilities' {
            . "$here/routing-lib.ps1"
            Out-Json @{ ok = $true; capabilities = @(Get-KnownCapabilities) }
        }
        'route-select' {
            . "$here/routing-lib.ps1"
            $sel = @{ Capability = [string]$a.capability }
            if ($a.max_tier)   { $sel['MaxCostTier']  = [string]$a.max_tier }
            if ($a.local_only) { $sel['RequireLocal'] = $true }
            $cands = @(Select-Capability @sel | Select-Object name, kind, source, cost_tier, quality, why)
            Out-Json @{ ok = $true; capability = [string]$a.capability; candidates = $cands }
        }
        'route-dispatch' {
            . "$here/routing-dispatch.ps1"
            $p = @{ Capability = [string]$a.capability; Prompt = [string]$a.prompt }
            if ($a.max_tier)   { $p['MaxCostTier']  = [string]$a.max_tier }
            if ($a.local_only) { $p['RequireLocal'] = $true }
            if ($a.judge)      { $p['Judge']        = $true }
            if ($a.rank)       { $p['Rank']         = [int]$a.rank }
            if ($a.timeout_s)  { $p['TimeoutS']     = [int]$a.timeout_s }
            $r = Invoke-RoutedCapability @p
            Out-Json @{
                ok = $true; status = $r.status; winner = $r.winner; result = $r.result
                attempts = @($r.attempts | Select-Object candidate, cost_tier, passed, score, reason, duration_s, gate)
            }
        }
        'fleet-list' {
            . "$here/fleet-lib.ps1"
            $rows = @(Read-Fleet | ForEach-Object {
                @{ name = $_.name; kind = $_.kind; enabled = ($_.enabled -eq $true); cost_tier = $_.cost_tier }
            })
            Out-Json @{ ok = $true; providers = $rows }
        }
        'fleet-doctor' {
            $out = (& "$here/fleet-doctor.ps1" -Json | Out-String).Trim()
            $healthy = ($LASTEXITCODE -eq 0)
            $rows = if ($out) { $out | ConvertFrom-Json } else { @() }
            Out-Json @{ ok = $true; healthy = $healthy; rows = @($rows) }
        }
        'fleet-test' {
            . "$here/fleet-lib.ps1"
            $p = @{ Name = [string]$a.name; Prompt = [string]$a.prompt }
            if ($a.model) { $p['Model'] = [string]$a.model }
            $r = Invoke-Fleet @p
            Out-Json @{ ok = $true; name = [string]$a.name; stdout = $r.stdout; stderr = $r.stderr; exit_code = $r.exit_code; duration_s = $r.duration_s }
        }
        'job-status' {
            . "$here/job-lib.ps1"
            $cur = Read-CurrentJob
            if (-not $cur.job_id) {
                Out-Json @{ ok = $true; active = $false; job_id = $null; phase = $null; manifest = $null }
                break
            }
            $jobDir = Join-Path (Join-Path (Get-BatonHome) 'jobs') $cur.job_id
            $m = if (Test-Path $jobDir) { Read-Manifest -JobDir $jobDir } else { $null }
            Out-Json @{ ok = $true; active = $true; job_id = $cur.job_id; phase = $cur.phase; manifest = $m }
        }
        'job-list' {
            . "$here/job-lib.ps1"
            $filter = if ($a.filter) { [string]$a.filter } else { 'active' }
            $jobsRoot = Join-Path (Get-BatonHome) 'jobs'
            $jobs = @()
            if (Test-Path $jobsRoot) {
                foreach ($d in (Get-ChildItem $jobsRoot -Directory)) {
                    try { $m = Read-Manifest -JobDir $d.FullName } catch { continue }
                    if (-not $m -or -not $m.id) { continue }
                    if ($filter -ne 'all' -and [string]$m.status -ne $filter) { continue }
                    $jobs += @{ id = $m.id; title = $m.title; phase = $m.current_phase; project = $m.project; status = $m.status; created_at = $m.created_at }
                }
            }
            Out-Json @{ ok = $true; jobs = $jobs }
        }
        default {
            Out-Json @{ ok = $false; error = "unknown op: $Op" }
        }
    }
} catch {
    try { Out-Json @{ ok = $false; error = $_.Exception.Message } } catch { exit 1 }
}
```
Adapt member names against the actual lib sources (e.g. `Read-Manifest` keys, `Invoke-RoutedCapability` return) — read them; the shapes above came from a source inventory but the source wins.

- [ ] **Step 3:** `fleet-doctor.ps1 -Json`: wrap the existing table/`Write-Host` output in `if (-not $Json) { ... }` and add `if ($Json) { $rows | ConvertTo-Json -Depth 4 }` before the exit logic (also suppress the red error Write-Host under -Json — emit `[]` and exit 1). Keep `$rows` construction unchanged.
- [ ] **Step 4:** Run `scripts/test-mcp-bridge.ps1` → PASS; run `scripts/test-fleet-doctor.ps1` and `scripts/test-baton-home.ps1` (stale-literal guard scans the new script — it must contain no `~/.claude` state literals) → PASS.
- [ ] **Step 5: Commit** — `feat(phase3): mcp-bridge.ps1 single PS entry + fleet-doctor -Json`

---

### Task 2: `baton_mcp` Python package (TDD)

**Files:**
- Create: `baton_mcp/__init__.py` (empty), `baton_mcp/__main__.py`, `baton_mcp/bridge.py`, `baton_mcp/server.py`, `baton_mcp/tests/__init__.py`, `baton_mcp/tests/test_bridge.py`, `baton_mcp/tests/test_server.py`

- [ ] **Step 1: Failing tests.** `test_bridge.py`: `run_op` builds the right command (monkeypatch `subprocess.run`, assert `-Op`/`-ArgsPath` and that the args file content round-trips and gets deleted), parses the LAST stdout line as JSON, returns `{ok:false, error}` on empty output / non-JSON / `TimeoutExpired`. `test_server.py`: import the tool functions from `baton_mcp.server` and call them directly with `bridge.run_op` monkeypatched — assert `baton_route` without `prompt` → op `route-select`, with `prompt` → `route-dispatch`; `baton_fleet_test` passes name/prompt/model through; `baton_kb_search` calls the kb search function (monkeypatch it) and wraps hits. Run → FAIL (package missing).

- [ ] **Step 2: `baton_mcp/bridge.py`:**

```python
"""Subprocess bridge to scripts/mcp-bridge.ps1 — the single PS entry point.

Args travel via a temp JSON file (965-byte shell-arg rule). The bridge prints one
JSON envelope; we parse the last stdout line so stray lib chatter can't break it.
"""
from __future__ import annotations

import json
import os
import subprocess
import tempfile
from pathlib import Path

DEFAULT_TIMEOUT_S = 240


def bridge_script() -> Path:
    override = os.environ.get("BATON_MCP_BRIDGE", "")
    if override:
        return Path(override)
    return Path(__file__).resolve().parent.parent / "scripts" / "mcp-bridge.ps1"


def run_op(op: str, args: dict | None = None, timeout: int = DEFAULT_TIMEOUT_S) -> dict:
    argpath: str | None = None
    try:
        if args:
            fd, argpath = tempfile.mkstemp(suffix=".json")
            os.close(fd)
            Path(argpath).write_text(json.dumps(args), encoding="utf-8")
        cmd = ["pwsh", "-NoProfile", "-File", str(bridge_script()), "-Op", op]
        if argpath:
            cmd += ["-ArgsPath", argpath]
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        out = (proc.stdout or "").strip()
        if not out:
            return {"ok": False, "error": f"bridge produced no output (exit {proc.returncode}): {(proc.stderr or '')[-400:]}"}
        try:
            return json.loads(out.splitlines()[-1])
        except json.JSONDecodeError:
            return {"ok": False, "error": f"bridge output was not JSON: {out[:400]}"}
    except subprocess.TimeoutExpired:
        return {"ok": False, "error": f"bridge op '{op}' timed out after {timeout}s"}
    except FileNotFoundError as e:
        return {"ok": False, "error": f"pwsh not found: {e}"}
    finally:
        if argpath:
            Path(argpath).unlink(missing_ok=True)
```

- [ ] **Step 3: `baton_mcp/server.py`** — FastMCP server, 8 tools. Skeleton (descriptions matter — they're what Codex/Claude see):

```python
"""Baton MCP server — cross-tool surface over the same BATON_HOME state.

Thin adapter per the Phase 3 spec: every tool shells into the existing
PowerShell libs via scripts/mcp-bridge.ps1, except baton_kb_search which calls
the kb package in-process (it is already Python).
"""
from __future__ import annotations

from mcp.server.fastmcp import FastMCP

from baton_mcp.bridge import run_op

mcp = FastMCP("baton")


@mcp.tool()
def baton_capabilities() -> dict:
    """List every capability the Baton router knows (tools.yaml + fleet general capabilities)."""
    return run_op("capabilities")


@mcp.tool()
def baton_route(capability: str, prompt: str = "", max_tier: str = "", local_only: bool = False,
                judge: bool = False, rank: int = 0, timeout_s: int = 0) -> dict:
    """Route a capability to the cheapest capable tool/model.

    Without prompt: returns the ranked candidate ladder (recommendation only).
    With prompt: dispatches up the ladder (cheapest first), verifies output, escalates
    on failure; returns winner + attempts. max_tier caps spend ('local'|'free'|'paid');
    rank (1-5) feeds the prime-hours paid gate; judge enables LLM-judge grading.
    """
    args: dict = {"capability": capability}
    if max_tier:
        args["max_tier"] = max_tier
    if local_only:
        args["local_only"] = True
    if prompt:
        args["prompt"] = prompt
        if judge:
            args["judge"] = True
        if rank:
            args["rank"] = rank
        if timeout_s:
            args["timeout_s"] = timeout_s
        return run_op("route-dispatch", args, timeout=max(timeout_s + 60, 300))
    return run_op("route-select", args)


@mcp.tool()
def baton_kb_search(query: str, k: int = 5, scope: str = "all") -> dict:
    """Semantic search over the shared knowledge base (decisions, lessons, specs).

    scope: 'all', 'universal', or a project id (e.g. 'baton')."""
    try:
        from kb.search import run_search  # in-process: kb IS the implementation
        hits = run_search(query=query, k=k, scope=scope)
        return {"ok": True, "hits": hits}
    except Exception as e:  # noqa: BLE001 — MCP tools return structured errors
        return {"ok": False, "error": str(e)}


@mcp.tool()
def baton_job_status() -> dict:
    """Show the active Baton job (id, phase, manifest) from BATON_HOME, if any."""
    return run_op("job-status")


@mcp.tool()
def baton_job_list(filter: str = "active") -> dict:
    """List Baton jobs. filter: 'active' (default), 'done', or 'all'."""
    return run_op("job-list", {"filter": filter})


@mcp.tool()
def baton_fleet_list() -> dict:
    """List the registered fleet providers (name, kind, enabled, cost tier)."""
    return run_op("fleet-list")


@mcp.tool()
def baton_fleet_doctor() -> dict:
    """Health-check every enabled fleet provider (PATH/HTTP reachability)."""
    return run_op("fleet-doctor")


@mcp.tool()
def baton_fleet_test(name: str, prompt: str, model: str = "") -> dict:
    """Dispatch one prompt to one named fleet provider and return stdout/exit/duration."""
    args = {"name": name, "prompt": prompt}
    if model:
        args["model"] = model
    return run_op("fleet-test", args, timeout=300)


def main() -> None:
    mcp.run()  # stdio transport


if __name__ == "__main__":
    main()
```
**Verify `kb.search`'s actual function signature first** (read `kb/search.py`) — if `run_search` differs (name/params/return), adapt the call and the test; do NOT change kb/search.py. `baton_mcp/__main__.py` is `from baton_mcp.server import main; main()`.

- [ ] **Step 4:** `python -m pytest baton_mcp -q` → PASS; then full `python -m pytest dashboard kb tools baton_mcp -q` → all pass.
- [ ] **Step 5: Commit** — `feat(phase3): baton_mcp package — FastMCP stdio server + pwsh bridge (8 tools)`

---

### Task 3: Plugin wiring + bootstrap prereq

**Files:**
- Create: `.mcp.json` (repo/plugin root), `requirements.txt` (repo root)
- Modify: `.claude-plugin/plugin.json` (version → `1.2.0-rc.3`), `scripts/bootstrap.ps1`, `scripts/test-bootstrap.ps1`

- [ ] **Step 1: `.mcp.json`:**

```json
{
  "mcpServers": {
    "baton": {
      "command": "python",
      "args": ["-m", "baton_mcp"],
      "env": {
        "PYTHONPATH": "${CLAUDE_PLUGIN_ROOT}",
        "BATON_MCP_BRIDGE": "${CLAUDE_PLUGIN_ROOT}/scripts/mcp-bridge.ps1"
      }
    }
  }
}
```

- [ ] **Step 2:** `requirements.txt` at repo root: one line `mcp>=1.25` plus a comment pointing at `dashboard/requirements.txt` for the dashboard extras.
- [ ] **Step 3:** plugin.json: bump `"version": "1.2.0-rc.3"` (the `hooks` field already exists; `.mcp.json` is auto-discovered at plugin root — no manifest field needed).
- [ ] **Step 4:** bootstrap.ps1: in the backend-verification step (Step 7 area), add a probe `python -c "import mcp"` → `Write-Ok "python mcp SDK present"` / `Write-Warn "python 'mcp' package missing — baton MCP server won't start. Run: pip install -r requirements.txt"`. Add a test-bootstrap assertion that the dry-run output mentions the MCP probe (match `mcp`-related text you emit).
- [ ] **Step 5:** Run `scripts/test-bootstrap.ps1` → PASS. Validate `.mcp.json` parses.
- [ ] **Step 6: Commit** — `feat(phase3): bundle baton MCP server in plugin (.mcp.json) + mcp SDK prereq check`

---

### Task 4: End-to-end stdio test + docs

**Files:**
- Create: `baton_mcp/tests/test_e2e_stdio.py`
- Modify: `README.md`, `docs/agent-handoffs.md`, `docs/next-session.md`, `docs/COMMANDS.md` (only if it lists surfaces)

- [ ] **Step 1: e2e test** — spawn the real server over stdio with the `mcp` client and a temp BATON_HOME:

```python
"""End-to-end: real stdio server, real bridge, temp BATON_HOME fixtures."""
from __future__ import annotations

import json
import os
import shutil
import sys
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parent.parent.parent

pytestmark = pytest.mark.skipif(shutil.which("pwsh") is None, reason="pwsh required")


@pytest.mark.anyio
async def test_stdio_capabilities_and_fleet_list(tmp_path, anyio_backend):
    home = tmp_path / "baton"
    home.mkdir()
    (home / "fleet.yaml").write_text(
        "providers:\n  - name: stub\n    kind: cli\n    enabled: true\n    cost_tier: local\n"
        "    command_template: 'pwsh -NoProfile -Command echo {{prompt}}'\n"
        "general_capabilities: [code-gen]\n",
        encoding="utf-8",
    )
    (home / "tools.yaml").write_text("tools: []\n", encoding="utf-8")

    from mcp import ClientSession, StdioServerParameters
    from mcp.client.stdio import stdio_client

    env = dict(os.environ)
    env["BATON_HOME"] = str(home)
    env["PYTHONPATH"] = str(REPO)
    params = StdioServerParameters(command=sys.executable, args=["-m", "baton_mcp"], env=env)
    async with stdio_client(params) as (read, write):
        async with ClientSession(read, write) as session:
            await session.initialize()
            tools = await session.list_tools()
            names = {t.name for t in tools.tools}
            assert {"baton_route", "baton_kb_search", "baton_fleet_list", "baton_job_status"} <= names

            res = await session.call_tool("baton_fleet_list", {})
            payload = json.loads(res.content[0].text)
            assert payload["ok"] is True
            assert payload["providers"][0]["name"] == "stub"
```
Adapt fixture yaml to the real parsers (read `Read-Fleet`'s expectations / existing test fixtures); adapt the anyio marker to however the repo's pytest is configured (add `anyio` dep only if already transitively present via the mcp SDK — it is). If `mcp` client import or the anyio plugin is unavailable, skip the test with a clear reason rather than failing.
- [ ] **Step 2:** Run it: `python -m pytest baton_mcp -q` → PASS (or cleanly skipped only for missing pwsh).
- [ ] **Step 3: Docs.** README: new "MCP server" section — what it is, the 8 tools, Claude (automatic via plugin), Codex (`codex mcp add baton --env PYTHONPATH=D:\Dev\Baton --env BATON_MCP_BRIDGE=D:\Dev\Baton\scripts\mcp-bridge.ps1 -- python -m baton_mcp` — note: repo path, verify exact `--env` placement against `codex mcp add --help` and write what works), Cursor (`~/.cursor/mcp.json` snippet with the repo path). agent-handoffs: Phase 3 → EXECUTED, one short paragraph (MCP server `baton`, 8 tools, same BATON_HOME, bundled `.mcp.json`, codex/cursor registration documented in README). next-session: flip the Phase 3 queued line to shipped.
- [ ] **Step 4: Commit** — `feat(phase3): e2e stdio test + MCP docs (Claude/Codex/Cursor registration)`

---

### Task 5: Final gate, review, merge, live deploy + registration

- [ ] **Step 1:** Full gate: all PS suites loop + `python -m pytest dashboard kb tools baton_mcp -q` + bootstrap dry-run smoke.
- [ ] **Step 2:** Final comprehensive adversarial review of the whole branch (single reviewer, most capable model). Fix findings, re-run gates.
- [ ] **Step 3:** PR → merge to master → pull.
- [ ] **Step 4:** Live: `pwsh scripts/bootstrap.ps1 -Force -NonInteractive` (updates plugin to rc.3 with `.mcp.json`). Then live-verify the server directly: run the e2e pytest against the real install, and register with Codex: `codex mcp add baton ...` (per the README syntax you verified) + `codex mcp list` shows it. If a full `codex exec` round-trip is cheap, try `baton_capabilities`; otherwise the stdio e2e + registration is the gate (note what was/wasn't verified).
- [ ] **Step 5:** Capture the scope d-record (the "Scope decisions" section above). Update memory + push the KB repo. Closeout checklist per the standing rule.
