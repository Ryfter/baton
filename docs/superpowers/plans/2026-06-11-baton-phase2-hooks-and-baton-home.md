# Baton Phase 2 — Plugin Hooks + BATON_HOME State Re-root Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move Baton's hooks into the plugin (`hooks/hooks.json`, auto-registered, `${CLAUDE_PLUGIN_ROOT}` paths) and re-root all mutable state from `~/.claude/` to `BATON_HOME` (default `~/.baton/`), with a marker-gated one-time migration.

**Architecture:** A single new resolver lib `scripts/baton-home.ps1` (`Get-BatonHome` + `Initialize-BatonHome` + `Move-BatonState`) is dot-sourced by every PS lib; hook scripts and top-level scripts use an inline `$env:BATON_HOME` fallback because `param()` defaults evaluate before any dot-source. Python gets tiny `baton_home()` helpers (`dashboard/paths.py`, `kb/paths.py`). Hooks ship in the plugin and fire from the plugin cache; bootstrap stops registering hooks in settings.json and instead *removes* the legacy entries (plugin + settings hooks would otherwise both fire). The KB (`~/.claude/knowledge`, incl. cost ledger + routing ratings) does **not** move.

**Tech Stack:** PowerShell 7, Python (FastAPI dashboard, kb package), Claude Code plugin schema (hooks/hooks.json).

**Spec:** `docs/superpowers/specs/2026-06-11-baton-rebrand-and-packaging-design.md` (Phase 2 section).

---

## Scope decisions locked in this plan (capture as one d-record at the end)

1. **`log-tool-call.ps1` moves into the plugin too** (spec listed only decision-detect, run-feed, SessionStart) — it's a bootstrap-managed Baton hook; splitting lifecycles would be drift.
2. **`kb-autoindex.ps1` stays a user-settings hook** — it's registered manually with a *repo* path and needs the repo's Python env; the plugin cache has no venv. Out of plugin scope.
3. **Bootstrap keeps deploying lib scripts to `~/.claude/scripts/`** — the statusLine script and every agent (Codex/Gemini, model-agnostic north star) load libs from there; commands reference `$HOME/.claude/scripts/...`. The spec's "bootstrap shrinks" line is realized partially (hook deploy/registration dropped, config seeds moved to BATON_HOME init).
4. **Cost ledger does NOT move** — it lives at `knowledge/projects/<id>/cost.md`, inside the KB, which stays. Same for `routing-ratings.jsonl` (GitHub-backed, universal KB).
5. **What moves to BATON_HOME:** `jobs/`, `runs/` (incl. `current-run.json`), `ideas/`, `ensembles/`, `current-job.json`, `routing-journal.jsonl`, `model-routing-log.md`, `fleet.yaml`, `tools.yaml`, `prime-hours.yaml`. Hook error logs move to `$BATON_HOME/logs/`.
6. **Env precedence:** explicit param > existing specific env vars (`ROUTING_RUNS_ROOT`, `CAO_STATE_PATH`, `IDEAS_ROOT`, `ROUTING_JOURNAL`, `ROUTING_JOBS_ROOT`, `ROUTING_ENSEMBLES_ROOT`) > `BATON_HOME`-derived default. Nothing existing breaks.
7. **`BATON_CLAUDE_DIR` env override** for the migration source dir — exists so tests/hooks can never touch the real `~/.claude`.
8. **statusLine untouched:** plugins can't provide one; bootstrap keeps its add-only-if-absent behavior. (Kevin's live statusLine is a custom `statusline.sh` object — bootstrap must keep skipping it.)
9. **Do not touch pixel-agents hook entries** in settings.json cleanup — only entries whose command matches our three script names.

---

### Task 1: `scripts/baton-home.ps1` resolver lib (TDD)

**Files:**
- Create: `scripts/baton-home.ps1`
- Create: `scripts/test-baton-home.ps1`

- [ ] **Step 1: Write the failing test**

Create `scripts/test-baton-home.ps1` (model on `scripts/test-runs-lib.ps1`'s Assert pattern):

```powershell
#!/usr/bin/env pwsh
# Tests for baton-home.ps1: Get-BatonHome, Initialize-BatonHome, Move-BatonState.
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here 'baton-home.ps1')

$failures = 0
function Assert($label, $cond) {
    if ($cond) { Write-Host "PASS  $label" -ForegroundColor Green }
    else { Write-Host "FAIL  $label" -ForegroundColor Red; $script:failures++ }
}

$savedHome = $env:BATON_HOME
$savedClaude = $env:BATON_CLAUDE_DIR
try {
    # --- Get-BatonHome ---
    $env:BATON_HOME = 'X:\custom\baton'
    Assert "Get-BatonHome honors env var" ((Get-BatonHome) -eq 'X:\custom\baton')
    $env:BATON_HOME = $null
    Assert "Get-BatonHome defaults to ~/.baton" ((Get-BatonHome) -eq (Join-Path $HOME '.baton'))

    # --- Initialize-BatonHome ---
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) "baton-home-test-$([guid]::NewGuid().ToString('N'))"
    $env:BATON_HOME = Join-Path $tmp 'baton'
    $refs = Join-Path $tmp 'references'
    New-Item -ItemType Directory -Force -Path $refs | Out-Null
    foreach ($f in @('fleet.yaml','tools.yaml','prime-hours.yaml')) {
        Set-Content (Join-Path $refs $f) "seed: $f" -Encoding utf8NoBOM
    }
    $seeded = Initialize-BatonHome -ReferencesDir $refs
    Assert "creates BATON_HOME root"   (Test-Path $env:BATON_HOME)
    Assert "creates jobs dir"          (Test-Path (Join-Path $env:BATON_HOME 'jobs'))
    Assert "creates runs dir"          (Test-Path (Join-Path $env:BATON_HOME 'runs'))
    Assert "creates logs dir"          (Test-Path (Join-Path $env:BATON_HOME 'logs'))
    Assert "seeds all three configs"   (@($seeded).Count -eq 3)
    Set-Content (Join-Path $env:BATON_HOME 'fleet.yaml') 'user: edited' -Encoding utf8NoBOM
    $seeded2 = Initialize-BatonHome -ReferencesDir $refs
    Assert "second run seeds nothing"  (@($seeded2).Count -eq 0)
    Assert "never overwrites existing config" ((Get-Content (Join-Path $env:BATON_HOME 'fleet.yaml') -Raw).Trim() -eq 'user: edited')

    # --- Move-BatonState ---
    $fakeClaude = Join-Path $tmp 'claude'
    $env:BATON_CLAUDE_DIR = $fakeClaude
    $env:BATON_HOME = Join-Path $tmp 'baton2'
    New-Item -ItemType Directory -Force -Path (Join-Path $fakeClaude 'jobs/j1') | Out-Null
    Set-Content (Join-Path $fakeClaude 'current-job.json') '{"job_id":"j1"}' -Encoding utf8NoBOM
    Set-Content (Join-Path $fakeClaude 'routing-journal.jsonl') '{"x":1}' -Encoding utf8NoBOM
    # knowledge must NOT be in the move set
    New-Item -ItemType Directory -Force -Path (Join-Path $fakeClaude 'knowledge') | Out-Null
    $r = Move-BatonState
    Assert "moves jobs dir"            (Test-Path (Join-Path $env:BATON_HOME 'jobs/j1'))
    Assert "moves current-job.json"    (Test-Path (Join-Path $env:BATON_HOME 'current-job.json'))
    Assert "moves routing journal"     (Test-Path (Join-Path $env:BATON_HOME 'routing-journal.jsonl'))
    Assert "source jobs gone"          (-not (Test-Path (Join-Path $fakeClaude 'jobs')))
    Assert "knowledge left in place"   (Test-Path (Join-Path $fakeClaude 'knowledge'))
    Assert "writes marker"             (Test-Path (Join-Path $env:BATON_HOME '.migrated-from-claude.json'))
    Assert "reports migrated items"    (@($r.migrated) -contains 'jobs')

    # idempotent: marker gates a second run
    New-Item -ItemType Directory -Force -Path (Join-Path $fakeClaude 'jobs/j2') | Out-Null
    $r2 = Move-BatonState
    Assert "marker gates re-run"       ((-not (Test-Path (Join-Path $env:BATON_HOME 'jobs/j2'))) -and (Test-Path (Join-Path $fakeClaude 'jobs/j2')))

    # conflict: both exist -> source untouched, listed
    $env:BATON_HOME = Join-Path $tmp 'baton3'
    New-Item -ItemType Directory -Force -Path $env:BATON_HOME | Out-Null
    Set-Content (Join-Path $env:BATON_HOME 'fleet.yaml') 'dest' -Encoding utf8NoBOM
    Set-Content (Join-Path $fakeClaude 'fleet.yaml') 'src' -Encoding utf8NoBOM
    $r3 = Move-BatonState
    Assert "conflict leaves source"    ((Get-Content (Join-Path $fakeClaude 'fleet.yaml') -Raw).Trim() -eq 'src')
    Assert "conflict reported"         (@($r3.conflicts) -contains 'fleet.yaml')
} finally {
    $env:BATON_HOME = $savedHome
    $env:BATON_CLAUDE_DIR = $savedClaude
    if ($tmp -and (Test-Path $tmp)) { Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue }
}

# --- Stale-literal regression guard (added in Task 3; keep section here) ---

if ($failures -gt 0) { exit 1 } else { exit 0 }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pwsh -NoProfile -File scripts/test-baton-home.ps1`
Expected: FAIL — `baton-home.ps1` does not exist (dot-source error).

- [ ] **Step 3: Write the implementation**

Create `scripts/baton-home.ps1`:

```powershell
#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Single resolver for Baton's state root (BATON_HOME) + first-run seeding and the
  one-time ~/.claude -> BATON_HOME state migration. Dot-source from libs and hooks.
.DESCRIPTION
  State (jobs, runs, journals, config yamls, ideas, ensembles) lives under
  BATON_HOME (default ~/.baton). Deliberately NOT ${CLAUDE_PLUGIN_DATA}: that path
  is Claude-only and id-mangled — Baton state must stay directly readable by
  Codex/Gemini and the Phase-3 MCP server (model-agnostic north star).
  The knowledge base stays at ~/.claude/knowledge (cross-project, repo-backed) —
  it is NOT Baton state and is never migrated.
#>

function Get-BatonHome {
    if ($env:BATON_HOME) { return $env:BATON_HOME }
    return (Join-Path $HOME '.baton')
}

function Initialize-BatonHome {
    <# Create the BATON_HOME skeleton + seed config yamls from a references dir.
       Idempotent: never overwrites an existing config. Returns seeded file names. #>
    param([Parameter(Mandatory)][string]$ReferencesDir)
    $root = Get-BatonHome
    foreach ($d in @($root, (Join-Path $root 'jobs'), (Join-Path $root 'runs'), (Join-Path $root 'logs'))) {
        if (-not (Test-Path $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
    }
    $seeded = [System.Collections.ArrayList]@()
    foreach ($cfg in @('fleet.yaml', 'tools.yaml', 'prime-hours.yaml')) {
        $src = Join-Path $ReferencesDir $cfg
        $dst = Join-Path $root $cfg
        if ((Test-Path $src) -and -not (Test-Path $dst)) {
            Copy-Item $src $dst
            [void]$seeded.Add($cfg)
        }
    }
    return $seeded.ToArray()
}

function Move-BatonState {
    <# One-time migration of mutable state from ~/.claude into BATON_HOME.
       Marker-gated and idempotent. Never clobbers: if source AND destination
       exist, the source stays put and is reported as a conflict.
       Returns @{ migrated; skipped; conflicts }. #>
    param(
        [string]$ClaudeDir = $(if ($env:BATON_CLAUDE_DIR) { $env:BATON_CLAUDE_DIR } else { Join-Path $HOME '.claude' }),
        [string]$BatonHome = (Get-BatonHome)
    )
    $marker = Join-Path $BatonHome '.migrated-from-claude.json'
    $result = @{ migrated = @(); skipped = @(); conflicts = @() }
    if (Test-Path $marker) { $result.skipped = @('(marker present — already migrated)'); return $result }
    if (-not (Test-Path $BatonHome)) { New-Item -ItemType Directory -Force -Path $BatonHome | Out-Null }
    $items = @(
        'jobs', 'runs', 'ideas', 'ensembles',
        'current-job.json', 'routing-journal.jsonl', 'model-routing-log.md',
        'fleet.yaml', 'tools.yaml', 'prime-hours.yaml'
    )
    foreach ($name in $items) {
        $src = Join-Path $ClaudeDir $name
        $dst = Join-Path $BatonHome $name
        if (-not (Test-Path $src)) { $result.skipped += $name; continue }
        if (Test-Path $dst) { $result.conflicts += $name; continue }
        Move-Item -LiteralPath $src -Destination $dst
        $result.migrated += $name
    }
    @{
        at        = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        from      = $ClaudeDir
        migrated  = $result.migrated
        conflicts = $result.conflicts
    } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $marker -Encoding utf8NoBOM
    return $result
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pwsh -NoProfile -File scripts/test-baton-home.ps1`
Expected: PASS (all asserts), exit 0.

- [ ] **Step 5: Commit**

```bash
git add scripts/baton-home.ps1 scripts/test-baton-home.ps1
git commit -m "feat(phase2): baton-home resolver lib — Get-BatonHome, Initialize-BatonHome, marker-gated Move-BatonState"
```

---

### Task 2: Re-root PowerShell library defaults to BATON_HOME

**Files (Modify):** `scripts/job-lib.ps1`, `scripts/runs-lib.ps1`, `scripts/fleet-lib.ps1`, `scripts/routing-lib.ps1`, `scripts/routing-dispatch.ps1`, `scripts/routing-learn.ps1`, `scripts/routing-calibrate.ps1`, `scripts/prime-hours.ps1`, `scripts/idea-lib.ps1`, `scripts/code-lib.ps1`, `scripts/fleet-ensemble.ps1`

Pattern: each lib adds `. "$PSScriptRoot/baton-home.ps1"` immediately after its comment header (skip if the file already transitively loads it — add it anyway; re-dot-sourcing a function definition is harmless and protects standalone loads). Then swap each default. **KB paths (`knowledge/...`) and telemetry paths stay unchanged.** Existing env-var checks (`CAO_STATE_PATH`, `ROUTING_RUNS_ROOT`, `IDEAS_ROOT`) keep highest precedence.

- [ ] **Step 1: Apply the edits** — exact swaps (line numbers as of master `54a3b6f`):

`scripts/job-lib.ps1` — add dot-source after header; line 15:
```powershell
. "$PSScriptRoot/baton-home.ps1"
$script:DefaultStatePath = (Join-Path (Get-BatonHome) 'current-job.json')
```

`scripts/runs-lib.ps1` — add dot-source at top; line 8 inside `Get-RunsRoot`:
```powershell
    return (Join-Path (Get-BatonHome) 'runs')
```
Also update the file-header comment `(~/.claude/runs/)` → `($BATON_HOME/runs/)`.

`scripts/fleet-lib.ps1` — add dot-source; line 13, 158, 159, 254:
```powershell
$script:DefaultFleetPath = (Join-Path (Get-BatonHome) 'fleet.yaml')
# line 158 / 254:
        [string]$JournalPath = (Join-Path (Get-BatonHome) 'model-routing-log.md'),
# line 159:
        [string]$StatePath = $(if ($env:CAO_STATE_PATH) { $env:CAO_STATE_PATH } else { Join-Path (Get-BatonHome) 'current-job.json' }),
```

`scripts/routing-lib.ps1` — (already dot-sources fleet-lib, which now loads baton-home; still add the explicit dot-source) lines 14, 45, 61, 91, 93. Line 92 (ratings, KB) **unchanged**:
```powershell
$script:DefaultToolsPath = (Join-Path (Get-BatonHome) 'tools.yaml')
# 45/61/91:
    param([string]$FleetPath = (Join-Path (Get-BatonHome) 'fleet.yaml'))
# 93:
        [string]$JournalPath = (Join-Path (Get-BatonHome) 'routing-journal.jsonl')
```

`scripts/routing-dispatch.ps1` — add dot-source; lines 58, 128–130, 213–215 → same three swaps (`tools.yaml`, `fleet.yaml`, `routing-journal.jsonl` under `(Get-BatonHome)`).

`scripts/routing-learn.ps1` — add dot-source; lines 73, 103, 128, 138 (journal), 148, 164, 197 (fleet) → `(Get-BatonHome)`. Line 13 (ratings, KB) **unchanged**.

`scripts/routing-calibrate.ps1` — add dot-source; lines 32–34, 77–78 → `(Get-BatonHome)`. Line 79 (ratings) **unchanged**.

`scripts/prime-hours.ps1` — already dot-sources fleet-lib; add explicit dot-source; line 17:
```powershell
$script:DefaultPrimeHoursPath = (Join-Path (Get-BatonHome) 'prime-hours.yaml')
```
Also fix the `.DESCRIPTION` text `~/.claude/prime-hours.yaml` → `$BATON_HOME/prime-hours.yaml`.

`scripts/idea-lib.ps1` — add dot-source at top; line 8:
```powershell
    return (Join-Path (Get-BatonHome) 'ideas')
```

`scripts/code-lib.ps1` — add dot-source; lines 185–186:
```powershell
        [string]$JournalPath = (Join-Path (Get-BatonHome) 'model-routing-log.md'),
        [string]$StatePath = $(if ($env:CAO_STATE_PATH) { $env:CAO_STATE_PATH } else { Join-Path (Get-BatonHome) 'current-job.json' })
```

`scripts/fleet-ensemble.ps1` — add dot-source; lines 88–89, 171–172 → fleet.yaml + model-routing-log.md under `(Get-BatonHome)`.

- [ ] **Step 2: Run every existing PS suite touching these libs**

Run: `pwsh -NoProfile -Command "foreach ($t in (Get-ChildItem scripts/test-*.ps1)) { & pwsh -NoProfile -File $t.FullName | Out-Null; if ($LASTEXITCODE -ne 0) { Write-Host \"FAIL $($t.Name)\" } else { Write-Host \"PASS $($t.Name)\" } }"`
Expected: every suite PASS (tests inject paths; only defaults changed). If a suite asserts the old default literal, update that assertion to the BATON_HOME default.

- [ ] **Step 3: Commit**

```bash
git add scripts/
git commit -m "refactor(phase2): re-root PS lib state defaults to BATON_HOME via Get-BatonHome"
```

---

### Task 3: Re-root hook scripts + top-level scripts (inline defaults) + stale-literal guard

`param()` defaults run before any dot-source, so script-level params use a self-contained inline pattern instead of `Get-BatonHome`.

**Files (Modify):** `scripts/hooks/run-feed.ps1`, `scripts/hooks/log-tool-call.ps1`, `scripts/statusline-feed.ps1`, `scripts/fleet-doctor.ps1`, `scripts/parse-otel.ps1`, `scripts/consolidate-lessons.ps1`, `scripts/run-backlog.ps1`, `scripts/smoke-six-hats.ps1`, `scripts/test-baton-home.ps1` (guard), check `scripts/fleet-runs-bridge.ps1`

- [ ] **Step 1: Apply the edits**

`scripts/hooks/run-feed.ps1` lines 8–10 (keep `ROUTING_RUNS_ROOT` precedence; error log moves to `$BATON_HOME/logs/`):
```powershell
param(
    [string]$RunsRoot    = $(if ($env:ROUTING_RUNS_ROOT) { $env:ROUTING_RUNS_ROOT } elseif ($env:BATON_HOME) { Join-Path $env:BATON_HOME 'runs' } else { Join-Path $HOME '.baton/runs' }),
    [string]$PointerPath,
    [string]$ErrorPath   = $(if ($env:BATON_HOME) { Join-Path $env:BATON_HOME 'logs/run-feed.err.log' } else { Join-Path $HOME '.baton/logs/run-feed.err.log' })
)
```
Also update the `.SYNOPSIS` mention of `~/.claude/current-run.json`.

`scripts/statusline-feed.ps1` line 12 — same `$RunsRoot` pattern as run-feed.

`scripts/hooks/log-tool-call.ps1` lines 26–28 (+ fix `.SYNOPSIS`/`.PARAMETER` doc text):
```powershell
param(
    [string]$JournalPath = $(if ($env:BATON_HOME) { Join-Path $env:BATON_HOME 'model-routing-log.md' } else { Join-Path $HOME '.baton/model-routing-log.md' }),
    [string]$ErrorPath   = $(if ($env:BATON_HOME) { Join-Path $env:BATON_HOME 'logs/log-tool-call.err.log' } else { Join-Path $HOME '.baton/logs/log-tool-call.err.log' }),
    [string]$StatePath   = $(if ($env:CAO_STATE_PATH) { $env:CAO_STATE_PATH } elseif ($env:BATON_HOME) { Join-Path $env:BATON_HOME 'current-job.json' } else { Join-Path $HOME '.baton/current-job.json' })
)
```

`scripts/fleet-doctor.ps1` line 8:
```powershell
    [string]$Path = $(if ($env:BATON_HOME) { Join-Path $env:BATON_HOME 'fleet.yaml' } else { Join-Path $HOME '.baton/fleet.yaml' })
```

`scripts/parse-otel.ps1` lines 40, 48 (lines 39/41/44/45 — telemetry + KB — **unchanged**); fix the line-28 docstring:
```powershell
    [string]$JournalPath = $(if ($env:BATON_HOME) { Join-Path $env:BATON_HOME 'model-routing-log.md' } else { Join-Path $HOME '.baton/model-routing-log.md' }),
# 48:
    [string]$StatePath   = $(if ($env:CAO_STATE_PATH) { $env:CAO_STATE_PATH } elseif ($env:BATON_HOME) { Join-Path $env:BATON_HOME 'current-job.json' } else { Join-Path $HOME '.baton/current-job.json' })
```

`scripts/consolidate-lessons.ps1` line 16 (line 17 KbRoot **unchanged**):
```powershell
    [string]$JobsRoot = $(if ($env:BATON_HOME) { Join-Path $env:BATON_HOME 'jobs' } else { Join-Path $HOME '.baton/jobs' }),
```

`scripts/run-backlog.ps1` line 32 (line 30 — deployed-scripts dot-source — **unchanged**):
```powershell
if (-not $OutputRoot) { $OutputRoot = $(if ($env:BATON_HOME) { Join-Path $env:BATON_HOME 'ensembles' } else { Join-Path $HOME '.baton/ensembles' }) }
```

`scripts/smoke-six-hats.ps1` line 23 — replace `Join-Path $HOME ".claude/ensembles/six-hats-smoke-$ts"` with:
```powershell
$smokeRoot = $(if ($env:BATON_HOME) { $env:BATON_HOME } else { Join-Path $HOME '.baton' })
# then use: Join-Path $smokeRoot "ensembles/six-hats-smoke-$ts"
```

`scripts/fleet-runs-bridge.ps1` — grep it for `.claude`; if the hit is a *state* path, apply the same treatment; if it's a comment or deployed-script reference, fix the text only.

- [ ] **Step 2: Add the stale-literal regression guard** to `scripts/test-baton-home.ps1` (replace the placeholder comment section from Task 1):

```powershell
# --- Stale-literal regression guard: no script may still default state to ~/.claude ---
$stalePattern = '\.claude[/\\](jobs|runs|ideas|ensembles|current-job\.json|routing-journal|model-routing-log|fleet\.yaml|tools\.yaml|prime-hours\.yaml)'
$allowed = @('baton-home.ps1', 'bootstrap.ps1')   # migration source list lives here by design
$stale = @()
foreach ($f in (Get-ChildItem $here -Recurse -Filter *.ps1 | Where-Object { $_.Name -notlike 'test-*' -and ($allowed -notcontains $_.Name) })) {
    if ((Get-Content $f.FullName -Raw) -match $stalePattern) { $stale += $f.Name }
}
Assert "no stale ~/.claude state literals in scripts ($($stale -join ', '))" ($stale.Count -eq 0)
```

- [ ] **Step 3: Run the suites**

Run: `pwsh -NoProfile -File scripts/test-baton-home.ps1` then the full loop from Task 2 Step 2 (especially `test-run-feed-hook.ps1`, `test-statusline-feed.ps1`, `test-hook.ps1`, `test-otel-parser.ps1`, `test-consolidate-lessons.ps1`, `test-fleet-doctor.ps1`).
Expected: all PASS. Fix any test that asserted the old default text.

- [ ] **Step 4: Commit**

```bash
git add scripts/
git commit -m "refactor(phase2): inline BATON_HOME defaults for hooks + top-level scripts; stale-literal guard"
```

---

### Task 4: Re-root Python (dashboard + kb)

**Files:**
- Create: `dashboard/paths.py`, `kb/paths.py`
- Modify: `dashboard/main.py:17-40`, `dashboard/routers/runs.py:19`, `dashboard/routers/jobs.py:19,25`, `dashboard/routers/projects.py:25,31` (line 19 KB stays), `dashboard/routers/api.py:17`, `kb/index.py:225` (224/226 KB stay), `kb/ab_eval.py:156` (155 stays), `kb/search.py:17`

- [ ] **Step 1: Create the helpers**

`dashboard/paths.py`:
```python
"""Resolve Baton's state root. State lives under BATON_HOME (default ~/.baton);
the knowledge base stays under ~/.claude/knowledge and is NOT Baton state."""
from __future__ import annotations
import os
from pathlib import Path


def baton_home() -> Path:
    return Path(os.environ.get("BATON_HOME", "") or Path.home() / ".baton")
```

`kb/paths.py`: identical content (kb is an independently-importable package; a 5-line duplicate beats a cross-package import).

- [ ] **Step 2: Swap the defaults**

`dashboard/main.py` — add `from dashboard.paths import baton_home` and change the four state defaults (KB_ROOT **unchanged**):
```python
JOURNAL_PATH = Path(
    os.environ.get("ROUTING_JOURNAL", "")
    or baton_home() / "model-routing-log.md"
)

JOBS_ROOT = Path(
    os.environ.get('ROUTING_JOBS_ROOT', '')
    or baton_home() / 'jobs'
)

ENSEMBLES_ROOT = Path(
    os.environ.get('ROUTING_ENSEMBLES_ROOT', '')
    or baton_home() / 'ensembles'
)

RUNS_ROOT = Path(
    os.environ.get('ROUTING_RUNS_ROOT', '')
    or baton_home() / 'runs'
)
```

Routers — import `from dashboard.paths import baton_home` and swap the getattr fallbacks:
- `runs.py:19` → `getattr(req.app.state, "runs_root", baton_home() / "runs")`
- `jobs.py:19` → `baton_home() / 'jobs'`; `jobs.py:25` → `baton_home() / 'model-routing-log.md'`
- `projects.py:25` → `baton_home() / 'jobs'`; `projects.py:31` → `baton_home() / 'model-routing-log.md'` (line 19 `knowledge` **unchanged**)
- `api.py:17` → `baton_home() / "model-routing-log.md"`

`kb/index.py:225` → `p.add_argument("--jobs-root", default=str(baton_home() / "jobs"))` (add `from kb.paths import baton_home`)
`kb/ab_eval.py:156` → same swap.
`kb/search.py:17` → `path = current_job_path or baton_home() / "current-job.json"`

- [ ] **Step 3: Run the Python tests**

Run: `python -m pytest dashboard kb tools -q`
Expected: all pass (tests inject tmp_path/app.state). Fix any test asserting the old default string.

- [ ] **Step 4: Commit**

```bash
git add dashboard/ kb/
git commit -m "refactor(phase2): Python state defaults re-root to BATON_HOME (dashboard + kb)"
```

---

### Task 5: Plugin hooks — `hooks/hooks.json` + SessionStart init hook + plugin.json

**Files:**
- Create: `hooks/hooks.json`, `scripts/hooks/baton-init.ps1`, `scripts/test-baton-init-hook.ps1`
- Modify: `.claude-plugin/plugin.json`

- [ ] **Step 1: Write the failing hook test**

`scripts/test-baton-init-hook.ps1`:
```powershell
#!/usr/bin/env pwsh
# Tests for the SessionStart baton-init hook: seeds configs + runs migration,
# idempotent, never exits non-zero. Fully isolated via BATON_HOME/BATON_CLAUDE_DIR.
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$hook = Join-Path $here 'hooks/baton-init.ps1'

$failures = 0
function Assert($label, $cond) {
    if ($cond) { Write-Host "PASS  $label" -ForegroundColor Green }
    else { Write-Host "FAIL  $label" -ForegroundColor Red; $script:failures++ }
}

$savedHome = $env:BATON_HOME; $savedClaude = $env:BATON_CLAUDE_DIR
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) "baton-init-test-$([guid]::NewGuid().ToString('N'))"
try {
    $env:BATON_HOME = Join-Path $tmp 'baton'
    $env:BATON_CLAUDE_DIR = Join-Path $tmp 'claude'
    New-Item -ItemType Directory -Force -Path $env:BATON_CLAUDE_DIR | Out-Null
    Set-Content (Join-Path $env:BATON_CLAUDE_DIR 'current-job.json') '{"job_id":"legacy"}' -Encoding utf8NoBOM

    & pwsh -NoProfile -File $hook | Out-Null
    Assert "hook exits 0"                     ($LASTEXITCODE -eq 0)
    Assert "seeds fleet.yaml from references" (Test-Path (Join-Path $env:BATON_HOME 'fleet.yaml'))
    Assert "seeds tools.yaml"                 (Test-Path (Join-Path $env:BATON_HOME 'tools.yaml'))
    Assert "seeds prime-hours.yaml"           (Test-Path (Join-Path $env:BATON_HOME 'prime-hours.yaml'))
    Assert "migrates legacy current-job"      (Test-Path (Join-Path $env:BATON_HOME 'current-job.json'))
    Assert "writes migration marker"          (Test-Path (Join-Path $env:BATON_HOME '.migrated-from-claude.json'))

    Set-Content (Join-Path $env:BATON_HOME 'fleet.yaml') 'user: edited' -Encoding utf8NoBOM
    & pwsh -NoProfile -File $hook | Out-Null
    Assert "second run exits 0"               ($LASTEXITCODE -eq 0)
    Assert "second run keeps user config"     ((Get-Content (Join-Path $env:BATON_HOME 'fleet.yaml') -Raw).Trim() -eq 'user: edited')
} finally {
    $env:BATON_HOME = $savedHome; $env:BATON_CLAUDE_DIR = $savedClaude
    if (Test-Path $tmp) { Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue }
}
if ($failures -gt 0) { exit 1 } else { exit 0 }
```

- [ ] **Step 2: Run it to verify it fails** — `pwsh -NoProfile -File scripts/test-baton-init-hook.ps1` → FAIL (hook missing).

- [ ] **Step 3: Create `scripts/hooks/baton-init.ps1`**

```powershell
#!/usr/bin/env pwsh
<#
.SYNOPSIS
  SessionStart(startup) hook: ensure BATON_HOME exists, seed the config yamls on
  first run, and run the one-time ~/.claude -> BATON_HOME state migration.
  Non-blocking: always exits 0; errors go to $BATON_HOME/logs/baton-init.err.log.
#>
$ErrorActionPreference = 'Continue'
try {
    $scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
    $libCandidates = @(
        (Join-Path $scriptDir '../baton-home.ps1'),         # repo/plugin layout: scripts/hooks -> scripts
        (Join-Path $scriptDir '../scripts/baton-home.ps1')  # deployed layout: ~/.claude/hooks -> ~/.claude/scripts
    )
    $libPath = $libCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $libPath) { exit 0 }
    . $libPath
    $refs = [IO.Path]::GetFullPath((Join-Path $scriptDir '../../references'))
    if (Test-Path $refs) { Initialize-BatonHome -ReferencesDir $refs | Out-Null }
    Move-BatonState | Out-Null
    exit 0
} catch {
    try {
        $log = Join-Path (Get-BatonHome) 'logs/baton-init.err.log'
        $d = Split-Path -Parent $log
        if (-not (Test-Path $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
        Add-Content -Path $log -Value ((Get-Date -Format o) + " | " + $_.Exception.Message)
    } catch { }
    exit 0
}
```

- [ ] **Step 4: Run the hook test** — expect PASS.

- [ ] **Step 5: Create `hooks/hooks.json`** (plugin root; top-level key MUST be `"hooks"`; `${CLAUDE_PLUGIN_ROOT}` expands at fire time):

```json
{
  "hooks": {
    "SessionStart": [
      {
        "matcher": "startup",
        "hooks": [
          {
            "type": "command",
            "command": "pwsh -NoProfile -File \"${CLAUDE_PLUGIN_ROOT}/scripts/hooks/baton-init.ps1\""
          }
        ]
      }
    ],
    "PostToolUse": [
      {
        "matcher": "*",
        "hooks": [
          {
            "type": "command",
            "command": "pwsh -NoProfile -File \"${CLAUDE_PLUGIN_ROOT}/scripts/hooks/log-tool-call.ps1\""
          }
        ]
      },
      {
        "matcher": "*",
        "hooks": [
          {
            "type": "command",
            "command": "pwsh -NoProfile -File \"${CLAUDE_PLUGIN_ROOT}/scripts/hooks/run-feed.ps1\""
          }
        ]
      }
    ],
    "Stop": [
      {
        "matcher": "*",
        "hooks": [
          {
            "type": "command",
            "command": "pwsh -NoProfile -File \"${CLAUDE_PLUGIN_ROOT}/scripts/hooks/decision-detect.ps1\""
          }
        ]
      }
    ]
  }
}
```
(`kb-autoindex.ps1` is deliberately absent — scope decision 2.)

- [ ] **Step 6: Declare hooks in `.claude-plugin/plugin.json`** — add one field + bump version:

```json
{
  "name": "baton",
  "displayName": "Baton",
  "version": "1.2.0-rc.2",
  "description": "Pass the baton. Conduct the fleet. Claude Code as command-and-control for a fleet of coding LLMs — capability routing, cost engine, jobs, decisions, and a knowledge base.",
  "author": { "name": "Kevin Rank", "url": "https://github.com/Ryfter" },
  "repository": "https://github.com/Ryfter/baton",
  "license": "MIT",
  "keywords": ["orchestration", "multi-agent", "fleet", "routing", "cost", "mcp"],
  "hooks": "./hooks/hooks.json"
}
```

- [ ] **Step 7: Validate JSON** — `pwsh -NoProfile -Command "Get-Content hooks/hooks.json -Raw | ConvertFrom-Json | Out-Null; Get-Content .claude-plugin/plugin.json -Raw | ConvertFrom-Json | Out-Null; 'json ok'"` → `json ok`.

- [ ] **Step 8: Commit**

```bash
git add hooks/hooks.json scripts/hooks/baton-init.ps1 scripts/test-baton-init-hook.ps1 .claude-plugin/plugin.json
git commit -m "feat(phase2): plugin-provided hooks (hooks.json) + SessionStart baton-init seed/migrate hook"
```

---

### Task 6: Bootstrap rework — legacy cleanup + BATON_HOME init/migration

**Files:**
- Modify: `scripts/bootstrap.ps1`, `scripts/test-bootstrap.ps1`

- [ ] **Step 1: Replace Step 2 (hook deploy) with legacy hook-copy removal** — replace bootstrap.ps1 lines 106–123 with:

```powershell
# --- Step 2: Remove legacy deployed hook copies (hooks now ship inside the plugin) ---
Write-Step "Removing legacy deployed hooks (now plugin-provided via hooks/hooks.json)"
foreach ($h in @('log-tool-call.ps1', 'decision-detect.ps1', 'run-feed.ps1')) {
    $dst = Join-Path $claudeDir "hooks\$h"
    if (Test-Path $dst) {
        if ($DryRun) { Write-Ok "[dry-run] would remove legacy hook: $h" }
        else { Remove-Item -Force $dst; Write-Ok "removed legacy hook: $h" }
    } else { Write-Skip "legacy hook already absent: $h" }
}
```

- [ ] **Step 2: Replace Step 3 (hook registration) with legacy settings.json entry removal.** Plugin hooks + settings.json hooks BOTH fire — the legacy entries must go. Replace the `Add-HookEntry` function and the registration block (lines 125–186) with (statusLine block is **kept verbatim**):

```powershell
# --- Step 3: Remove legacy hook entries from settings.json (plugin registers them now) ---
# Plugin hooks and user-settings hooks BOTH fire; leaving the old entries would
# double-run every hook. Only entries pointing at OUR three scripts are removed —
# anything else (e.g. pixel-agents, kb-autoindex) is untouched.
Write-Step "Cleaning legacy hook registrations from settings.json"
$settingsPath = Join-Path $claudeDir 'settings.json'

function Remove-HookEntry($SettingsObj, $Event, $Marker) {
    if (-not $SettingsObj.hooks) { return $false }
    if (-not ($SettingsObj.hooks.PSObject.Properties.Name -contains $Event)) { return $false }
    $before = @($SettingsObj.hooks.$Event)
    $kept = @($before | Where-Object {
        -not (@($_.hooks) | Where-Object { $_.command -like "*$Marker*" })
    })
    if ($kept.Count -eq $before.Count) { return $false }
    $SettingsObj.hooks.$Event = $kept
    return $true
}

if (-not (Test-Path $settingsPath)) {
    Write-Skip "no settings.json — nothing to clean"
} else {
    $raw = Get-Content $settingsPath -Raw
    if ([string]::IsNullOrWhiteSpace($raw)) { $raw = '{}' }
    $settings = $raw | ConvertFrom-Json

    $removed = $false
    foreach ($pair in @(
        @{ Event = 'PostToolUse'; Marker = 'log-tool-call.ps1' },
        @{ Event = 'PostToolUse'; Marker = 'run-feed.ps1' },
        @{ Event = 'Stop';        Marker = 'decision-detect.ps1' }
    )) {
        if ($DryRun) {
            # Report-only in dry-run: detect without mutating the in-memory object's persistence
            if ($settings.hooks -and ($settings.hooks.PSObject.Properties.Name -contains $pair.Event)) {
                $hit = @($settings.hooks.($pair.Event)) | Where-Object { @($_.hooks) | Where-Object { $_.command -like "*$($pair.Marker)*" } }
                if ($hit) { Write-Ok "[dry-run] would remove legacy $($pair.Event) entry: $($pair.Marker)" }
                else { Write-Skip "no legacy $($pair.Event) entry for $($pair.Marker)" }
            }
        } elseif (Remove-HookEntry $settings $pair.Event $pair.Marker) {
            Write-Ok "removed legacy $($pair.Event) entry: $($pair.Marker)"
            $removed = $true
        } else {
            Write-Skip "no legacy $($pair.Event) entry for $($pair.Marker)"
        }
    }

    # statusLine: plugins cannot provide one — keep bootstrap-managed, add only if absent.
    $statusLineDst = Join-Path $claudeDir 'scripts\statusline-feed.ps1'
    $addedStatusLine = $false
    if (-not ($settings.PSObject.Properties.Name -contains 'statusLine') -or
        [string]::IsNullOrEmpty($settings.statusLine)) {
        $settings | Add-Member -NotePropertyName statusLine -NotePropertyValue "pwsh -NoProfile -File `"$statusLineDst`"" -Force
        $addedStatusLine = $true
        if ($DryRun) { Write-Ok "[dry-run] would set statusLine (statusline-feed)" }
    } else { Write-Skip "statusLine already configured (left as-is)" }

    if (($removed -or $addedStatusLine) -and -not $DryRun) {
        $backupPath = "$settingsPath.bak"
        Copy-Item $settingsPath $backupPath -Force
        $settings | ConvertTo-Json -Depth 10 | Set-Content $settingsPath -Encoding utf8
        Write-Ok "updated settings.json (backup: $backupPath)"
    }
}
```

- [ ] **Step 3: Replace the three config-seed steps (5b3/5b4/prime-hours, lines 282–298) and pull `jobs` out of Step 5c** with a BATON_HOME init + migration step:

```powershell
# --- Step 5b3: Initialize BATON_HOME (state root) + one-time state migration ---
Write-Step "Initializing BATON_HOME state root + migrating legacy state"
. (Join-Path $repoRoot 'scripts\baton-home.ps1')
$batonHome = Get-BatonHome
$fleetDst = Join-Path $batonHome 'fleet.yaml'   # fleet doctor (Step 7) verifies this path
if ($DryRun) {
    Write-Ok "[dry-run] would ensure $batonHome (jobs/, runs/, logs/) + seed fleet.yaml / tools.yaml / prime-hours.yaml"
    Write-Ok "[dry-run] would run the one-time ~/.claude -> BATON_HOME migration (marker-gated)"
} else {
    $seeded = Initialize-BatonHome -ReferencesDir (Join-Path $repoRoot 'references')
    foreach ($s in $seeded) { Write-Ok "seeded $s -> $batonHome" }
    if (-not $seeded -or @($seeded).Count -eq 0) { Write-Skip "configs already present in $batonHome" }
    $mig = Move-BatonState
    foreach ($m in @($mig.migrated))  { Write-Ok "migrated $m -> $batonHome" }
    foreach ($c in @($mig.conflicts)) { Write-Warn "left in place (exists in both ~/.claude and BATON_HOME): $c" }
    if (@($mig.migrated).Count -eq 0 -and @($mig.conflicts).Count -eq 0) { Write-Skip "migration already done (marker present) or nothing to move" }
}
```
In Step 5c (line 302–308) remove `(Join-Path $claudeDir 'jobs'),` from `$dirsToCreate` (knowledge dirs stay).

- [ ] **Step 4: Add `'baton-home.ps1'` to the Step 5b script deploy list** (line 262, anywhere in the array).

- [ ] **Step 5: Update `scripts/test-bootstrap.ps1`** — replace the assertion block (lines 20–34) with:

```powershell
Assert "removes legacy hooks"            ($out -match 'legacy hook')
Assert "cleans legacy settings entries"  ($out -match 'legacy (PostToolUse|Stop) entry|Cleaning legacy hook registrations')
Assert "mentions OTel env helper"        ($out -match 'OTel env')
Assert "mentions Baton plugin"           ($out -match 'Baton plugin')
Assert "mentions catalog deployment"     ($out -match 'catalog')
Assert "mentions backend verification"   ($out -match 'Verifying backends')
Assert "initializes BATON_HOME"          ($out -match 'BATON_HOME')
Assert "mentions state migration"        ($out -match 'migration')
Assert "would deploy baton-home.ps1"     ($out -match 'baton-home\.ps1')
Assert "would deploy idea-lib.ps1"        ($out -match 'idea-lib\.ps1')
Assert "would install baton plugin"       ($out -match 'baton@ryfter')
Assert "would seed tools.yaml"            ($out -match 'tools\.yaml')
Assert "would deploy routing-lib.ps1"     ($out -match 'routing-lib\.ps1')
Assert "would deploy routing-dispatch.ps1" ($out -match 'routing-dispatch\.ps1')
Assert "would deploy routing-learn.ps1"   ($out -match 'routing-learn\.ps1')
Assert "would deploy routing-calibrate.ps1" ($out -match 'routing-calibrate\.ps1')
Assert "would deploy prime-hours.ps1"   ($out -match 'prime-hours\.ps1')
Assert "would seed prime-hours.yaml"    ($out -match 'prime-hours\.yaml')
Assert "does not exit non-zero"          ($LASTEXITCODE -eq 0 -or $out -match 'Bootstrap complete')
Assert "does NOT register hooks anymore" ($out -notmatch 'would register PostToolUse')
```
Keep the existing settings.json-backup static check (it still matches the new Step 3 code).

- [ ] **Step 6: Run the bootstrap smoke** — `pwsh -NoProfile -File scripts/test-bootstrap.ps1` → all PASS (dry-run is report-only against the real HOME; the migration is gated behind `-not $DryRun`).

- [ ] **Step 7: Commit**

```bash
git add scripts/bootstrap.ps1 scripts/test-bootstrap.ps1
git commit -m "feat(phase2): bootstrap — legacy hook cleanup, BATON_HOME init + marker-gated migration; stop registering hooks"
```

---

### Task 7: Docs + command-text sweep

**Files (Modify):** `README.md`, `docs/GUIDE.md`, `docs/COMMANDS.md`, `docs/getting-started.md`, `docs/agent-handoffs.md`, `docs/next-session.md`, `docs/roadmap.md` (if it mentions state paths), and any `commands/*.md` whose prose names a state path.

- [ ] **Step 1: Sweep.** Grep: `\.claude[/\\](jobs|runs|ideas|ensembles|current-job|routing-journal|model-routing-log|fleet\.yaml|tools\.yaml|prime-hours\.yaml)` across `README.md docs/ commands/` (exclude `docs/superpowers/` and `docs/releases/` — history keeps old names). For each hit, rewrite to the BATON_HOME form, e.g. `~/.claude/jobs/<id>` → `$BATON_HOME/jobs/<id>` (default `~/.baton`). **Leave** `~/.claude/knowledge`, `~/.claude/scripts`, `~/.claude/commands`, settings/telemetry references unchanged.
- [ ] **Step 2: `docs/agent-handoffs.md`** — update the "Queued next" Phase 2 paragraph to past tense: hooks now plugin-provided via `hooks/hooks.json`; state at `BATON_HOME` (default `~/.baton`, env-overridable); migration marker `.migrated-from-claude.json`; KB unchanged; Phase 3 (MCP server) is the remaining queued item.
- [ ] **Step 3: One line in `docs/next-session.md`** under the parked-threads header noting Phase 2 shipped and where state now lives.
- [ ] **Step 4: Commit**

```bash
git add README.md docs/ commands/
git commit -m "docs(phase2): state paths now under BATON_HOME (~/.baton); handoffs updated"
```

---

### Task 8: Final gate, live deploy + decision capture

- [ ] **Step 1: Full PS suite loop** (Task 2 Step 2 command) — every suite exit 0.
- [ ] **Step 2: Python tests** — `python -m pytest dashboard kb tools -q` — all pass.
- [ ] **Step 3: Bootstrap dry-run smoke** — `pwsh -NoProfile -File scripts/test-bootstrap.ps1` — exit 0.
- [ ] **Step 4: Live deploy on this machine** — `pwsh scripts/bootstrap.ps1 -Force -NonInteractive`. Verify:
  - `~/.baton/` contains `jobs/`, `runs/`, `fleet.yaml`, `tools.yaml`, `prime-hours.yaml`, `.migrated-from-claude.json` (and the migrated `model-routing-log.md` / `routing-journal.jsonl` if they existed).
  - `~/.claude/settings.json` no longer contains entries for `log-tool-call.ps1`, `run-feed.ps1`, `decision-detect.ps1`; pixel-agents + kb-autoindex entries intact; statusLine untouched.
  - `~/.claude/hooks/` no longer has the three legacy scripts.
  - `pwsh -NoProfile -File scripts/fleet-doctor.ps1` resolves the new default and reports providers.
- [ ] **Step 5: Capture the scope d-record** (file-based intake per CLAUDE.md): title "Phase 2 scope: plugin hooks set, BATON_HOME move set, what stays at ~/.claude" — chosen/alternatives/rationale from the "Scope decisions" section above.
- [ ] **Step 6: Final comprehensive review** (single adversarial review per Kevin's execution style), fix findings, then commit any fixes and push.

**Note for the executor:** hooks fire from the *installed plugin cache*, which snapshots the repo at install time — after merging, re-run bootstrap (it does `claude plugin marketplace update ryfter` + install) and restart the Claude session before expecting the new hooks to fire. Verifying live hook firing is a post-restart manual check; everything else is covered by the suites.
