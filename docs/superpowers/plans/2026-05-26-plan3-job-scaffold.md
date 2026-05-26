# Plan 3: Job & Phase Scaffold + KB Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make a *job* a persistent, phase-tracked thing on disk. Add slash commands to drive its lifecycle. Extend the Plan 1 hook to tag every journal line with `job:` + `phase:`. Lay down a two-layer (universal + per-project) knowledge base populated by `/job-lesson` capture and `/consolidate-lessons` rollup. Add a read-only Jobs panel + drill-in to the Plan 2 dashboard.

**Architecture:** Claude Code is the orchestrator. Job state lives under `~/.claude/jobs/<id>/` as `manifest.yaml` + `brief.md` + `phase-log.md` + `lessons.md`. A small **JSON state file** at `~/.claude/current-job.json` carries the "which job/phase is active" signal across processes — slash commands write it; the hook reads it on each invocation. (The spec's `$env:CAO_JOB_ID` language is implemented this way because Claude Code's slash-command subprocesses can't mutate the parent process's environment.) The KB lives at `~/.claude/knowledge/{universal,projects/<id>}/`. Plan 1's `model-routing.md` is migrated into `knowledge/universal/routing.md` during bootstrap. The dashboard gains a `dashboard/routers/jobs.py` + `dashboard/readers/jobs.py` pair plus two templates.

**Tech Stack:** PowerShell 7+ (pwsh), Python 3.11+, FastAPI 0.115+, Jinja2, htmx 2.x (CDN), pytest 8.3+, pydantic 2.x. No new dependencies.

---

## API Contract — read before diverging

### State file (the source of "active job" truth)

**Path:** `~/.claude/current-job.json`

```json
{
  "job_id": "j-2026-05-26-feature-flags",
  "phase": "research"
}
```

Rules:
- Slash commands `/job-start`, `/job-phase`, `/job-resume` write it.
- `/job-phase done` deletes it.
- Hook + `parse-otel.ps1` read it on every invocation; if missing/corrupted/empty, fall back to untagged journal line format (backward compat with Plan 1).

### Journal line format (extends Plan 2's contract)

```
# Plan 1/2 formats (still valid when no job active):
2026-05-23T10:00:00-06:00 | hook | bash:ollama run devstral:24b 'Hello' | 2s | exit:0
2026-05-23T10:25:00-06:00 | hook | agent:claude-subagent | 0s | exit:0 | "spec review task"
2026-05-23T10:05:00-06:00 | otel | claude-sonnet-4-6 | in:3214 out:892 | $0.0231 | api_request
2026-05-23T10:10:00-06:00 | note | devstral | "used for smoke test"

# Plan 3: same lines gain TRAILING ` | job:<id> | phase:<phase>` when a job is active:
2026-05-26T11:00:00-06:00 | hook | bash:ollama list | 1s | exit:0 | job:j-2026-05-26-feature-flags | phase:research
2026-05-26T11:05:00-06:00 | otel | claude-sonnet-4-6 | in:3214 out:892 | $0.0231 | api_request | job:j-2026-05-26-feature-flags | phase:research

# Plan 3: NEW `lesson` line type:
2026-05-26T11:20:00-06:00 | lesson | knowledge | "Feature flags split into release vs ops toggles" | job:j-2026-05-26-feature-flags | phase:research

# Plan 3: NEW `dashboard | phase-transition` line:
2026-05-26T11:35:00-06:00 | dashboard | phase-transition | research → design | job:j-2026-05-26-feature-flags
```

Parsing rules:
- `job:` and `phase:` are always trailing fields if present, always last on the line.
- Older lines without them must still parse (graceful absence).
- The Plan 2 pipe-sanitization rule still applies — payload pipes are `¦`.

### Phase sequence (hardcoded constant in `job-lib.ps1`)

```
research → design → code.sprint-1 → review → code.sprint-2 → review → ... → done
```

- `/job-phase next` advances along this sequence.
- At `review`, `next` prompts: *"Start `code.sprint-N+1` or `/job-phase done`?"*
- Loop-backs use explicit naming (`/job-phase design`), recorded as `loop-back` in `phase-log.md`.
- `sprint_count` in `manifest.yaml` tracks how many code sprints have been entered.

### Lesson categories + default scope

| Category | Default scope | KB file |
|---|---|---|
| `routing` | universal | `universal/routing.md` |
| `user-pref` | universal | `universal/user-prefs.md` |
| `reasoning` | universal | `universal/reasoning.md` |
| `mistake` | project | `projects/<id>/mistakes.md` |
| `winner` | project | `projects/<id>/winners.md` |
| `convention` | project | `projects/<id>/conventions.md` |
| `decision` | project | `projects/<id>/decisions.md` |
| `architecture` | project | `projects/<id>/architecture.md` |
| `knowledge` | project | `projects/<id>/topics/general.md` *(`--scope universal` → `universal/topics/general.md`)* |

---

## File structure

**New files in repo:**

| Path | Responsibility |
|---|---|
| `scripts/job-lib.ps1` | Shared PowerShell library: slugify, project-detect, manifest R/W, state-file R/W, phase sequence, phase-log appends |
| `scripts/consolidate-lessons.ps1` | Implements `/consolidate-lessons` |
| `scripts/test-job-lib.ps1` | Unit-style tests for `job-lib.ps1` functions |
| `scripts/test-jobs.ps1` | End-to-end lifecycle test: start → next → next → back → next → done |
| `scripts/test-consolidate-lessons.ps1` | Tests for consolidation routing + idempotency |
| `commands/job-start.md` | `/job-start` slash command |
| `commands/job-status.md` | `/job-status` slash command |
| `commands/job-list.md` | `/job-list` slash command |
| `commands/job-phase.md` | `/job-phase` slash command (next/back/explicit/done) |
| `commands/job-resume.md` | `/job-resume` slash command |
| `commands/job-lesson.md` | `/job-lesson` slash command |
| `commands/consolidate-lessons.md` | `/consolidate-lessons` slash command |
| `dashboard/readers/jobs.py` | Reads job folders, computes summaries + drill-in details |
| `dashboard/routers/jobs.py` | FastAPI routes: `/jobs` (list partial) + `/jobs/<id>` (detail) |
| `dashboard/templates/partials/jobs_list.html` | Htmx-poll target for the Jobs card |
| `dashboard/templates/job_detail.html` | Drill-in page |
| `dashboard/tests/test_jobs_reader.py` | Tests for `dashboard/readers/jobs.py` |
| `dashboard/tests/test_jobs_router.py` | Tests for `dashboard/routers/jobs.py` |

**Modified files in repo:**

| Path | Change |
|---|---|
| `scripts/hooks/log-tool-call.ps1` | Read state file; append trailing `\| job:... \| phase:...` when set |
| `scripts/parse-otel.ps1` | Read state file at parse time; tag emitted lines with current job/phase |
| `scripts/test-hook.ps1` | Add test cases for state-file-set and state-file-unset paths |
| `scripts/bootstrap.ps1` | Create new dirs, migrate `model-routing.md`, deploy new commands + lib scripts |
| `dashboard/readers/journal.py` | Parse trailing `job:` / `phase:` tags; parse new `lesson` line type |
| `dashboard/models/events.py` | Add `job_id` + `phase` optional fields to HookEntry/OtelEntry/NoteEntry; add `LessonEntry`; add `JobSummary`, `JobDetail`, `PhaseLogEntry` |
| `dashboard/main.py` | Wire `jobs_router` into the FastAPI app |
| `dashboard/templates/index.html` | Add Jobs card with htmx poll on 30 s |

---

## Task ordering

Tasks run sequentially. PowerShell foundation first (Tasks 1-11), Python dashboard layer next (Tasks 12-17), bootstrap + integration last (Tasks 18-19). This avoids needing fake sample journal lines to develop the Python side.

---

## Task 1: `job-lib.ps1` skeleton + state file R/W

**Files:**
- Create: `scripts/job-lib.ps1`
- Create: `scripts/test-job-lib.ps1`

- [ ] **Step 1: Write the failing test**

Create `scripts/test-job-lib.ps1`:

```powershell
#!/usr/bin/env pwsh
# Unit-style tests for job-lib.ps1 functions.
# Each section dot-sources the lib and runs assertions; throws on failure.

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here 'job-lib.ps1')

function Assert-Equal($expected, $actual, $msg) {
    if ($expected -ne $actual) {
        throw "FAIL: $msg`n  expected: $expected`n  actual:   $actual"
    }
}

function Assert-Null($actual, $msg) {
    if ($null -ne $actual) {
        throw "FAIL: $msg`n  expected null, got: $actual"
    }
}

# --- State file R/W ---
Write-Host "=== State file R/W ===" -ForegroundColor Cyan
$tmpDir = New-Item -ItemType Directory -Path (Join-Path $env:TEMP "cao-test-$(Get-Random)") -Force
$statePath = Join-Path $tmpDir 'current-job.json'

# Read when file missing → returns $null
$state = Read-CurrentJob -StatePath $statePath
Assert-Null $state.job_id 'missing state file: job_id is null'
Assert-Null $state.phase 'missing state file: phase is null'

# Write then read
Write-CurrentJob -StatePath $statePath -JobId 'j-test-foo' -Phase 'research'
$state = Read-CurrentJob -StatePath $statePath
Assert-Equal 'j-test-foo' $state.job_id 'after write: job_id matches'
Assert-Equal 'research'   $state.phase  'after write: phase matches'

# Clear
Clear-CurrentJob -StatePath $statePath
$state = Read-CurrentJob -StatePath $statePath
Assert-Null $state.job_id 'after clear: job_id is null'

# Corrupted file → read returns null, no throw
Set-Content $statePath '{ broken json'
$state = Read-CurrentJob -StatePath $statePath
Assert-Null $state.job_id 'corrupted file: job_id is null'

Remove-Item $tmpDir -Recurse -Force

Write-Host "All tests passed." -ForegroundColor Green
```

- [ ] **Step 2: Run to verify it fails**

```powershell
pwsh -NoProfile -File scripts\test-job-lib.ps1
```

Expected: error like *"Could not find … job-lib.ps1"* or *"The term 'Read-CurrentJob' is not recognized"*.

- [ ] **Step 3: Create `scripts/job-lib.ps1` with the state-file functions**

```powershell
#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Shared PowerShell library for job lifecycle. Dot-source from slash command
  scripts and the hook.

.DESCRIPTION
  Functions:
    Read-CurrentJob   — returns @{ job_id; phase } from state file
    Write-CurrentJob  — writes state file
    Clear-CurrentJob  — deletes state file
    (more added in later tasks)
#>

$script:DefaultStatePath = (Join-Path $HOME '.claude/current-job.json')

function Read-CurrentJob {
    param([string]$StatePath = $script:DefaultStatePath)
    $result = @{ job_id = $null; phase = $null }
    if (-not (Test-Path $StatePath)) { return $result }
    try {
        $raw = Get-Content $StatePath -Raw -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($raw)) { return $result }
        $obj = $raw | ConvertFrom-Json -ErrorAction Stop
        $result.job_id = $obj.job_id
        $result.phase  = $obj.phase
    } catch {
        # Corrupted or unreadable → treat as no active job
    }
    return $result
}

function Write-CurrentJob {
    param(
        [Parameter(Mandatory)][string]$JobId,
        [Parameter(Mandatory)][string]$Phase,
        [string]$StatePath = $script:DefaultStatePath
    )
    $dir = Split-Path -Parent $StatePath
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    @{ job_id = $JobId; phase = $Phase } | ConvertTo-Json | Set-Content -Path $StatePath -Encoding utf8
}

function Clear-CurrentJob {
    param([string]$StatePath = $script:DefaultStatePath)
    if (Test-Path $StatePath) { Remove-Item $StatePath -Force }
}
```

- [ ] **Step 4: Run to verify it passes**

```powershell
pwsh -NoProfile -File scripts\test-job-lib.ps1
```

Expected: `All tests passed.` in green.

- [ ] **Step 5: Commit**

```powershell
git add scripts/job-lib.ps1 scripts/test-job-lib.ps1
git commit -m "feat(plan3): job-lib.ps1 state-file R/W + tests"
```

---

## Task 2: `job-lib.ps1` — slugify + project detection

**Files:**
- Modify: `scripts/job-lib.ps1`
- Modify: `scripts/test-job-lib.ps1`

- [ ] **Step 1: Add failing tests**

Append to `scripts/test-job-lib.ps1` (before the final `Write-Host "All tests passed."`):

```powershell
# --- Slugify ---
Write-Host "=== Slugify ===" -ForegroundColor Cyan
Assert-Equal 'feature-flag-system-orchestrator' (ConvertTo-JobSlug "build a feature flag system for the orchestrator") 'normal brief'
Assert-Equal 'rewrite-auth-middleware' (ConvertTo-JobSlug "Rewrite the auth middleware") 'simple brief'
Assert-Equal 'fix-bug' (ConvertTo-JobSlug "fix bug") 'short brief, single token after stops'
Assert-Equal 'fix-bug-in-login-flow' (ConvertTo-JobSlug "fix a bug in the login flow") 'stop-word filtering'

# Length cap (40)
$long = ConvertTo-JobSlug "implement comprehensive multi-tenant role-based access control"
if ($long.Length -gt 40) { throw "FAIL: slug length exceeded 40: $long ($($long.Length) chars)" }

# --- Project detection ---
Write-Host "=== Project detection ===" -ForegroundColor Cyan
$projTmp = New-Item -ItemType Directory -Path (Join-Path $env:TEMP "cao-proj-$(Get-Random)") -Force
Push-Location $projTmp
try {
    # cwd-folder fallback (no git remote)
    Assert-Equal (Split-Path -Leaf $projTmp) (Resolve-ProjectId) 'cwd folder fallback'

    # Explicit override always wins
    Assert-Equal 'custom-project' (Resolve-ProjectId -Override 'custom-project') 'explicit override'
} finally {
    Pop-Location
    Remove-Item $projTmp -Recurse -Force
}
```

- [ ] **Step 2: Run to verify failure**

```powershell
pwsh -NoProfile -File scripts\test-job-lib.ps1
```

Expected: *"The term 'ConvertTo-JobSlug' is not recognized"*.

- [ ] **Step 3: Add slugify + project-detection to `scripts/job-lib.ps1`**

Append to the file (before any final comment):

```powershell
$script:StopWords = @('a','an','the','for','to','of','and','build','make','create','add','my','this','that')

function ConvertTo-JobSlug {
    param([Parameter(Mandatory)][string]$Brief)
    $lower = $Brief.ToLowerInvariant()
    # Replace any non-alphanumeric with space, then split on whitespace
    $cleaned = ($lower -replace '[^a-z0-9]+', ' ').Trim()
    $tokens = $cleaned -split '\s+' | Where-Object { $_ -and ($script:StopWords -notcontains $_) }
    $slugTokens = @($tokens | Select-Object -First 4)
    $slug = ($slugTokens -join '-')
    if ($slug.Length -gt 40) { $slug = $slug.Substring(0, 40).TrimEnd('-') }
    if (-not $slug) { $slug = 'untitled' }
    return $slug
}

function Resolve-ProjectId {
    param([string]$Override)
    if ($Override) { return $Override }

    # Try git remote
    try {
        $remote = (& git remote get-url origin 2>$null)
        if ($LASTEXITCODE -eq 0 -and $remote) {
            # Strip protocol, .git suffix; take host/repo
            $clean = $remote -replace '^(https?://|git@)', '' `
                              -replace ':', '/' `
                              -replace '\.git$', ''
            $parts = $clean -split '/' | Where-Object { $_ }
            if ($parts.Count -ge 2) {
                $repo = $parts[-1]
                return ($repo.ToLowerInvariant() -replace '[^a-z0-9-]+', '-').Trim('-')
            }
        }
    } catch { }

    # Fallback: cwd folder name (slugified)
    $folder = Split-Path -Leaf (Get-Location).Path
    return ($folder.ToLowerInvariant() -replace '[^a-z0-9-]+', '-').Trim('-')
}
```

- [ ] **Step 4: Run to verify pass**

```powershell
pwsh -NoProfile -File scripts\test-job-lib.ps1
```

Expected: `All tests passed.`.

- [ ] **Step 5: Commit**

```powershell
git add scripts/job-lib.ps1 scripts/test-job-lib.ps1
git commit -m "feat(plan3): job-lib.ps1 — slugify + project detection"
```

---

## Task 3: `job-lib.ps1` — manifest + phase-log R/W + phase sequence

**Files:**
- Modify: `scripts/job-lib.ps1`
- Modify: `scripts/test-job-lib.ps1`

- [ ] **Step 1: Add failing tests**

Append to `scripts/test-job-lib.ps1` (before `All tests passed.`):

```powershell
# --- Phase sequence ---
Write-Host "=== Phase sequence ===" -ForegroundColor Cyan
Assert-Equal 'design'        (Get-NextPhase 'research'      0) 'research → design'
Assert-Equal 'code.sprint-1' (Get-NextPhase 'design'        0) 'design → code.sprint-1'
Assert-Equal 'review'        (Get-NextPhase 'code.sprint-1' 1) 'code.sprint-1 → review'
Assert-Equal 'code.sprint-2' (Get-NextPhase 'review'        1) 'review → code.sprint-2 (sprint_count=1)'
Assert-Equal 'design'        (Get-PrevPhase 'code.sprint-1' 1) 'code.sprint-1 → design (back)'
Assert-Equal 'research'      (Get-PrevPhase 'design'        0) 'design → research (back)'
Assert-Null  (Get-PrevPhase 'research' 0) 'no back from research'

# --- Manifest R/W ---
Write-Host "=== Manifest R/W ===" -ForegroundColor Cyan
$manifestTmp = New-Item -ItemType Directory -Path (Join-Path $env:TEMP "cao-mani-$(Get-Random)") -Force
$jobDir = Join-Path $manifestTmp 'j-test-123'
New-Item -ItemType Directory -Path $jobDir | Out-Null

$now = (Get-Date -Format 'yyyy-MM-ddTHH:mm:sszzz')
Write-Manifest -JobDir $jobDir -Manifest @{
    id = 'j-test-123'; title = 'test job'; created_at = $now
    status = 'active'; project = 'test-project'
    current_phase = 'research'; phase_started_at = $now
    sprint_count = 0; last_updated = $now
}
$mani = Read-Manifest -JobDir $jobDir
Assert-Equal 'j-test-123'   $mani.id            'manifest id'
Assert-Equal 'research'     $mani.current_phase 'manifest current_phase'
Assert-Equal 0              $mani.sprint_count  'manifest sprint_count'

# --- Phase log append ---
Write-Host "=== Phase log ===" -ForegroundColor Cyan
Append-PhaseLog -JobDir $jobDir -Kind 'created'    -Detail 'research'
Append-PhaseLog -JobDir $jobDir -Kind 'transition' -Detail 'research → design'
$log = Get-Content (Join-Path $jobDir 'phase-log.md') -Raw
if ($log -notmatch 'created\s+\|\s+research')      { throw "FAIL: phase-log missing created line" }
if ($log -notmatch 'transition\s+\|\s+research → design') { throw "FAIL: phase-log missing transition" }

Remove-Item $manifestTmp -Recurse -Force
```

- [ ] **Step 2: Run to verify failure**

```powershell
pwsh -NoProfile -File scripts\test-job-lib.ps1
```

Expected: *"The term 'Get-NextPhase' is not recognized"*.

- [ ] **Step 3: Implement in `scripts/job-lib.ps1`**

Append:

```powershell
# Phase model — keep in lock-step with docs/superpowers/specs/2026-05-26-plan3-job-scaffold-design.md.
$script:LinearPhases = @('research', 'design', 'code.sprint-1', 'review')

function Get-NextPhase {
    param(
        [Parameter(Mandatory)][string]$Current,
        [Parameter(Mandatory)][int]$SprintCount
    )
    # `review` advances to the next sprint: code.sprint-(SprintCount+1).
    # All other phases follow the linear sequence (research → design → code.sprint-1 → review).
    if ($Current -eq 'review') {
        return "code.sprint-$($SprintCount + 1)"
    }
    if ($Current -match '^code\.sprint-\d+$') {
        return 'review'
    }
    $idx = $script:LinearPhases.IndexOf($Current)
    if ($idx -lt 0 -or $idx -ge ($script:LinearPhases.Count - 1)) { return $null }
    return $script:LinearPhases[$idx + 1]
}

function Get-PrevPhase {
    param(
        [Parameter(Mandatory)][string]$Current,
        [Parameter(Mandatory)][int]$SprintCount
    )
    if ($Current -eq 'review' -and $SprintCount -ge 1) { return "code.sprint-$SprintCount" }
    if ($Current -match '^code\.sprint-(\d+)$') {
        $n = [int]$matches[1]
        if ($n -le 1) { return 'design' }
        return 'review'  # back from sprint-N goes to the review that preceded it
    }
    $idx = $script:LinearPhases.IndexOf($Current)
    if ($idx -le 0) { return $null }
    return $script:LinearPhases[$idx - 1]
}

function Read-Manifest {
    param([Parameter(Mandatory)][string]$JobDir)
    $path = Join-Path $JobDir 'manifest.yaml'
    if (-not (Test-Path $path)) { return $null }
    # Manifest is small + structured. Parse manually — no YAML module dependency.
    $manifest = @{}
    foreach ($line in (Get-Content $path)) {
        if ($line -match '^(\w+):\s*(.+?)\s*$') {
            $key = $matches[1]
            $val = $matches[2].Trim('"', "'")
            # Coerce numeric fields
            if ($key -in @('sprint_count')) { $val = [int]$val }
            $manifest[$key] = $val
        }
    }
    return $manifest
}

function Write-Manifest {
    param(
        [Parameter(Mandatory)][string]$JobDir,
        [Parameter(Mandatory)][hashtable]$Manifest
    )
    if (-not (Test-Path $JobDir)) { New-Item -ItemType Directory -Force -Path $JobDir | Out-Null }
    $path = Join-Path $JobDir 'manifest.yaml'
    $lines = @()
    # Stable key order for readability
    foreach ($key in @('id','title','created_at','status','project','current_phase','phase_started_at','sprint_count','last_updated')) {
        if ($Manifest.ContainsKey($key) -and $null -ne $Manifest[$key]) {
            $v = $Manifest[$key]
            # Quote strings containing spaces or special chars; leave bare for safe values
            if ($v -is [string] -and $v -match '[\s:#"]' -and $v -notmatch '^[\d.+-]') {
                $lines += "$key: `"$v`""
            } else {
                $lines += "$key: $v"
            }
        }
    }
    Set-Content -Path $path -Value ($lines -join "`n") -Encoding utf8
}

function Append-PhaseLog {
    param(
        [Parameter(Mandatory)][string]$JobDir,
        [Parameter(Mandatory)][string]$Kind,   # created | transition | loop-back
        [Parameter(Mandatory)][string]$Detail,
        [string]$Note
    )
    if (-not (Test-Path $JobDir)) { New-Item -ItemType Directory -Force -Path $JobDir | Out-Null }
    $path = Join-Path $JobDir 'phase-log.md'
    if (-not (Test-Path $path)) {
        Set-Content -Path $path -Value "# Phase Log`n" -Encoding utf8
    }
    $ts = Get-Date -Format 'yyyy-MM-ddTHH:mm:sszzz'
    $line = "$ts | $Kind | $Detail"
    if ($Note) { $line += " note: `"$Note`"" }
    Add-Content -Path $path -Value $line -Encoding utf8
}
```

- [ ] **Step 4: Run to verify pass**

```powershell
pwsh -NoProfile -File scripts\test-job-lib.ps1
```

Expected: `All tests passed.`.

- [ ] **Step 5: Commit**

```powershell
git add scripts/job-lib.ps1 scripts/test-job-lib.ps1
git commit -m "feat(plan3): job-lib.ps1 — manifest + phase-log R/W + phase sequence"
```

---

## Task 4: `/job-start` slash command + end-to-end lifecycle test

**Files:**
- Create: `commands/job-start.md`
- Create: `scripts/test-jobs.ps1`

- [ ] **Step 1: Write end-to-end lifecycle test (will be filled in as more commands ship)**

Create `scripts/test-jobs.ps1`:

```powershell
#!/usr/bin/env pwsh
# End-to-end job lifecycle tests. Each test sets up an isolated $JOBS_ROOT
# under TEMP, runs slash-command logic (or its PowerShell equivalent), and
# asserts the on-disk state.

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here 'job-lib.ps1')

function Assert-FileExists($path, $msg) {
    if (-not (Test-Path $path)) { throw "FAIL: $msg ($path missing)" }
}

function Assert-FileMissing($path, $msg) {
    if (Test-Path $path) { throw "FAIL: $msg ($path should not exist)" }
}

function Assert-Equal($expected, $actual, $msg) {
    if ($expected -ne $actual) { throw "FAIL: $msg`n  expected: $expected`n  actual:   $actual" }
}

# Isolate everything under a temp dir.
$root = New-Item -ItemType Directory -Path (Join-Path $env:TEMP "cao-e2e-$(Get-Random)") -Force
$jobsRoot  = Join-Path $root 'jobs'
$statePath = Join-Path $root 'current-job.json'
New-Item -ItemType Directory -Path $jobsRoot | Out-Null

Write-Host "=== /job-start ===" -ForegroundColor Cyan

# The slash command's PowerShell logic is replicated here for test isolation.
# When the actual /job-start runs, it sets paths to ~/.claude/...
$brief = 'build a feature flag system for the orchestrator'
$today = Get-Date -Format 'yyyy-MM-dd'
$slug = ConvertTo-JobSlug $brief
$jobId = "j-$today-$slug"
$jobDir = Join-Path $jobsRoot $jobId
$now = Get-Date -Format 'yyyy-MM-ddTHH:mm:sszzz'

New-Item -ItemType Directory -Path $jobDir | Out-Null
Set-Content -Path (Join-Path $jobDir 'brief.md') -Value "# Brief`n`n$brief" -Encoding utf8
Write-Manifest -JobDir $jobDir -Manifest @{
    id = $jobId; title = $brief; created_at = $now
    status = 'active'; project = 'coding-agent-orchestrator'
    current_phase = 'research'; phase_started_at = $now
    sprint_count = 0; last_updated = $now
}
Append-PhaseLog -JobDir $jobDir -Kind 'created' -Detail 'research'
Write-CurrentJob -StatePath $statePath -JobId $jobId -Phase 'research'

# Assertions
Assert-FileExists (Join-Path $jobDir 'manifest.yaml')   'manifest.yaml created'
Assert-FileExists (Join-Path $jobDir 'brief.md')        'brief.md created'
Assert-FileExists (Join-Path $jobDir 'phase-log.md')    'phase-log.md created'
Assert-FileExists $statePath                            'state file written'

$mani = Read-Manifest -JobDir $jobDir
Assert-Equal $jobId      $mani.id            'manifest id matches'
Assert-Equal 'research'  $mani.current_phase 'manifest current_phase = research'
Assert-Equal 'active'    $mani.status        'manifest status = active'

$state = Read-CurrentJob -StatePath $statePath
Assert-Equal $jobId     $state.job_id 'state file job_id'
Assert-Equal 'research' $state.phase  'state file phase'

# Cleanup
Remove-Item $root -Recurse -Force
Write-Host "All tests passed." -ForegroundColor Green
```

- [ ] **Step 2: Run to verify it passes (test sets up everything by itself)**

```powershell
pwsh -NoProfile -File scripts\test-jobs.ps1
```

Expected: `All tests passed.`.

- [ ] **Step 3: Create `commands/job-start.md`**

```markdown
---
description: Start a new job. Creates ~/.claude/jobs/<id>/ with manifest, brief, phase-log; sets ~/.claude/current-job.json so the hook starts phase-tagging tool calls.
argument-hint: "<brief>" [--project <id> | --no-project]
---

# /job-start

You are starting a new orchestrator job. The brief and optional flags are in
`$ARGUMENTS`.

## Steps

1. **Check no job is active.** Read `~/.claude/current-job.json`. If `job_id`
   is set, ask the user: *"Job `<id>` is active. Suspend and start new, or
   `/job-resume` and continue?"* — wait for their answer before proceeding.

2. **Parse arguments.** The brief is the quoted string (or first arg if
   unquoted). Flags: `--project <id>` (override), `--no-project` (skip
   detection).

3. **Run this PowerShell** (substitute values for `<BRIEF>`, `<PROJECT_FLAG>`):

   ```powershell
   . "$HOME/.claude/scripts/job-lib.ps1"

   $brief   = '<BRIEF>'                     # the user's brief, single-quote-escaped
   $today   = Get-Date -Format 'yyyy-MM-dd'
   $slug    = ConvertTo-JobSlug $brief
   $jobId   = "j-$today-$slug"
   $jobDir  = Join-Path $HOME ".claude/jobs/$jobId"

   # Collision handling
   $suffix = 2
   while (Test-Path $jobDir) {
       $jobDir = Join-Path $HOME ".claude/jobs/$jobId-$suffix"
       $suffix++
   }
   $jobId = Split-Path -Leaf $jobDir

   # Project resolution
   $project = $null
   if ('<PROJECT_FLAG>' -eq '--no-project') {
       $project = $null
   } elseif ('<PROJECT_FLAG>' -match '^--project (.+)$') {
       $project = $matches[1]
   } else {
       $project = Resolve-ProjectId
   }

   $now = Get-Date -Format 'yyyy-MM-ddTHH:mm:sszzz'
   New-Item -ItemType Directory -Path $jobDir | Out-Null
   New-Item -ItemType Directory -Path (Join-Path $jobDir 'phases') | Out-Null
   Set-Content -Path (Join-Path $jobDir 'brief.md') -Value "# Brief`n`n$brief" -Encoding utf8
   Set-Content -Path (Join-Path $jobDir 'lessons.md') -Value "# Lessons — $jobId`n" -Encoding utf8

   Write-Manifest -JobDir $jobDir -Manifest @{
       id = $jobId; title = $brief; created_at = $now
       status = 'active'; project = $project
       current_phase = 'research'; phase_started_at = $now
       sprint_count = 0; last_updated = $now
   }
   Append-PhaseLog -JobDir $jobDir -Kind 'created' -Detail 'research'
   Write-CurrentJob -JobId $jobId -Phase 'research'

   Write-Host ""
   Write-Host "Job started: $jobId" -ForegroundColor Green
   Write-Host "  project: $project"
   Write-Host "  phase:   research"
   Write-Host "  folder:  $jobDir"
   ```

4. **After running**, echo to the user a one-line summary plus the natural
   first question: *"What are you actually trying to solve?"*.

## Arguments

$ARGUMENTS
```

> Note: the slash command runs PowerShell that dot-sources `~/.claude/scripts/job-lib.ps1`. We'll deploy `job-lib.ps1` to that location in Task 18 (bootstrap). For local testing without bootstrap, run the lifecycle tests via `scripts/test-jobs.ps1` instead of invoking the slash command.

- [ ] **Step 4: Commit**

```powershell
git add commands/job-start.md scripts/test-jobs.ps1
git commit -m "feat(plan3): /job-start command + lifecycle test"
```

---

## Task 5: `/job-status` and `/job-list` slash commands

**Files:**
- Create: `commands/job-status.md`
- Create: `commands/job-list.md`

- [ ] **Step 1: Create `commands/job-status.md`**

```markdown
---
description: Show the active job's manifest plus recent journal entries tagged with this job ID.
argument-hint: (no arguments)
---

# /job-status

You are showing the user the current job's status. Run:

```powershell
. "$HOME/.claude/scripts/job-lib.ps1"

$state = Read-CurrentJob
if (-not $state.job_id) {
    Write-Host "No active job. Use /job-resume <id> or /job-list to see available jobs." -ForegroundColor Yellow
    return
}

$jobDir = Join-Path $HOME ".claude/jobs/$($state.job_id)"
$mani = Read-Manifest -JobDir $jobDir
$brief = (Get-Content (Join-Path $jobDir 'brief.md') -Raw)

Write-Host "Job: $($mani.id)" -ForegroundColor Cyan
Write-Host "  title:   $($mani.title)"
Write-Host "  project: $($mani.project)"
Write-Host "  phase:   $($mani.current_phase)  (started $($mani.phase_started_at))"
Write-Host "  status:  $($mani.status)"
Write-Host "  sprints: $($mani.sprint_count)"
Write-Host ""
Write-Host "Recent journal entries (last 10 tagged with this job):" -ForegroundColor Cyan

$journal = Join-Path $HOME '.claude/model-routing-log.md'
if (Test-Path $journal) {
    $tag = "job:$($state.job_id)"
    Get-Content $journal | Where-Object { $_ -like "*$tag*" } | Select-Object -Last 10 | ForEach-Object {
        Write-Host "  $_"
    }
}
```

Then echo the output to the user. No transformation.
```

- [ ] **Step 2: Create `commands/job-list.md`**

```markdown
---
description: List jobs under ~/.claude/jobs/, filtered by status.
argument-hint: [--all | --active | --done]
---

# /job-list

Show jobs in `~/.claude/jobs/`. Default filter: `--active`.

Parse `$ARGUMENTS` for one of `--all`, `--active`, `--done`. If empty, treat as `--active`.

Run:

```powershell
. "$HOME/.claude/scripts/job-lib.ps1"

$filter = '<FILTER>'   # 'all', 'active', or 'done'
$jobsRoot = Join-Path $HOME '.claude/jobs'
if (-not (Test-Path $jobsRoot)) {
    Write-Host "No jobs yet."
    return
}

$rows = @()
foreach ($d in Get-ChildItem -Path $jobsRoot -Directory) {
    $mani = Read-Manifest -JobDir $d.FullName
    if (-not $mani) { continue }
    if ($filter -ne 'all' -and $mani.status -ne $filter) { continue }
    $rows += [pscustomobject]@{
        ID      = $mani.id
        Phase   = $mani.current_phase
        Project = $mani.project
        Status  = $mani.status
        Started = $mani.created_at
    }
}

if ($rows.Count -eq 0) {
    Write-Host "No jobs match filter '$filter'."
    return
}

$rows | Sort-Object Started -Descending | Format-Table -AutoSize
```
```

- [ ] **Step 3: Commit**

```powershell
git add commands/job-status.md commands/job-list.md
git commit -m "feat(plan3): /job-status and /job-list commands"
```

---

## Task 6: `/job-phase` slash command (next/back/explicit/done)

**Files:**
- Create: `commands/job-phase.md`
- Modify: `scripts/test-jobs.ps1` (add phase-transition lifecycle test)

- [ ] **Step 1: Add lifecycle test for phase transitions**

Append to `scripts/test-jobs.ps1` (before the `Remove-Item $root` cleanup, which we'll move further down — but for now just append BEFORE the final cleanup line and let it grow):

```powershell
Write-Host "=== /job-phase next ===" -ForegroundColor Cyan

# Already have an active job from /job-start test above.
$mani = Read-Manifest -JobDir $jobDir
Assert-Equal 'research' $mani.current_phase 'precondition: phase = research'

# Replicate /job-phase next logic
$newPhase = Get-NextPhase -Current $mani.current_phase -SprintCount $mani.sprint_count
$now = Get-Date -Format 'yyyy-MM-ddTHH:mm:sszzz'
$mani.current_phase = $newPhase
$mani.phase_started_at = $now
$mani.last_updated = $now
Write-Manifest -JobDir $jobDir -Manifest $mani
Append-PhaseLog -JobDir $jobDir -Kind 'transition' -Detail "research → $newPhase"
Write-CurrentJob -StatePath $statePath -JobId $jobId -Phase $newPhase

$mani = Read-Manifest -JobDir $jobDir
Assert-Equal 'design' $mani.current_phase 'after next: phase = design'

# next again → code.sprint-1
$newPhase = Get-NextPhase -Current $mani.current_phase -SprintCount $mani.sprint_count
$mani.current_phase = $newPhase
if ($newPhase -match '^code\.sprint-(\d+)$') { $mani.sprint_count = [int]$matches[1] }
Write-Manifest -JobDir $jobDir -Manifest $mani
Append-PhaseLog -JobDir $jobDir -Kind 'transition' -Detail "design → $newPhase"
Write-CurrentJob -StatePath $statePath -JobId $jobId -Phase $newPhase

$mani = Read-Manifest -JobDir $jobDir
Assert-Equal 'code.sprint-1' $mani.current_phase 'after next: phase = code.sprint-1'
Assert-Equal 1               $mani.sprint_count  'sprint_count = 1'

Write-Host "=== /job-phase back ===" -ForegroundColor Cyan
$prev = Get-PrevPhase -Current $mani.current_phase -SprintCount $mani.sprint_count
$mani.current_phase = $prev
# Don't decrement sprint_count on back — we only count entries, not net state
Write-Manifest -JobDir $jobDir -Manifest $mani
Append-PhaseLog -JobDir $jobDir -Kind 'transition' -Detail "code.sprint-1 → $prev (back)"
Write-CurrentJob -StatePath $statePath -JobId $jobId -Phase $prev

$mani = Read-Manifest -JobDir $jobDir
Assert-Equal 'design' $mani.current_phase 'after back: phase = design'

Write-Host "=== /job-phase done ===" -ForegroundColor Cyan
$mani.status = 'done'
$mani.current_phase = 'done'
Write-Manifest -JobDir $jobDir -Manifest $mani
Append-PhaseLog -JobDir $jobDir -Kind 'transition' -Detail "$($mani.current_phase) → done"
Clear-CurrentJob -StatePath $statePath

$mani = Read-Manifest -JobDir $jobDir
Assert-Equal 'done' $mani.status 'after done: status = done'
Assert-FileMissing $statePath 'after done: state file deleted'
```

- [ ] **Step 2: Run to verify pass (the test exercises functions we already shipped)**

```powershell
pwsh -NoProfile -File scripts\test-jobs.ps1
```

Expected: `All tests passed.`.

- [ ] **Step 3: Create `commands/job-phase.md`**

```markdown
---
description: Show or transition the current job's phase. `next` advances along research→design→code.sprint-N→review→… Loop-backs use explicit phase names. `done` closes the job.
argument-hint: (no arg | next | back | done | <explicit-phase-name>)
---

# /job-phase

Manage the active job's phase.

## Steps

1. **Read state.** If no active job, print *"No active job. Use /job-resume or
   /job-list."* and stop.

2. **Parse `$ARGUMENTS`:**
   - empty → show current phase + what `next` would resolve to. Stop.
   - `next`  → compute next phase via `Get-NextPhase`. If current is `review`,
     prompt: *"Start `code.sprint-N+1` or `/job-phase done`?"* and wait for
     answer before transitioning.
   - `back`  → compute prev phase via `Get-PrevPhase`. If null (already at
     `research`), error: *"Already at the first phase."*
   - `done`  → set status=done, clear state file.
   - any other token → treat as explicit phase name. Validate against:
     `research`, `design`, `code.sprint-<N>` where N is a positive int,
     `review`, `done`. If invalid, error with list. Record as `loop-back` in
     phase-log if the named phase is "earlier" in the sequence than the
     current.

3. **Trigger OTel parser BEFORE flipping** (so events accumulated during the
   just-ended phase get tagged with the old phase):

   ```powershell
   & pwsh -NoProfile -File "$HOME/.claude/scripts/parse-otel.ps1" 2>&1 | Out-Null
   ```

   If it fails non-zero, warn but continue.

4. **Atomic transition** (manifest + state file + phase-log + journal line):

   ```powershell
   . "$HOME/.claude/scripts/job-lib.ps1"
   $state = Read-CurrentJob
   $jobDir = Join-Path $HOME ".claude/jobs/$($state.job_id)"
   $mani = Read-Manifest -JobDir $jobDir
   $oldPhase = $mani.current_phase
   $newPhase = '<RESOLVED_PHASE>'    # from step 2

   $now = Get-Date -Format 'yyyy-MM-ddTHH:mm:sszzz'
   $mani.current_phase = $newPhase
   $mani.phase_started_at = $now
   $mani.last_updated = $now
   if ($newPhase -match '^code\.sprint-(\d+)$') {
       $n = [int]$matches[1]
       if ($n -gt $mani.sprint_count) { $mani.sprint_count = $n }
   }
   if ($newPhase -eq 'done') { $mani.status = 'done' }
   Write-Manifest -JobDir $jobDir -Manifest $mani

   $kind = if ('<LOOP_BACK>' -eq '1') { 'loop-back' } else { 'transition' }
   Append-PhaseLog -JobDir $jobDir -Kind $kind -Detail "$oldPhase → $newPhase"

   if ($newPhase -eq 'done') {
       Clear-CurrentJob
   } else {
       Write-CurrentJob -JobId $state.job_id -Phase $newPhase
   }

   # Journal line for the dashboard's phase-transition view
   $ts = Get-Date -Format 'yyyy-MM-ddTHH:mm:sszzz'
   $line = "$ts | dashboard | phase-transition | $oldPhase → $newPhase | job:$($state.job_id)"
   Add-Content -Path (Join-Path $HOME '.claude/model-routing-log.md') -Value $line
   ```

5. **Prompt for lessons** at `next` and `done` transitions only:
   *"Any lessons to record before moving on? (use `/job-lesson <category>
   \"<text>\"`)"*. Don't block — just remind.

## Arguments

$ARGUMENTS
```

- [ ] **Step 4: Commit**

```powershell
git add commands/job-phase.md scripts/test-jobs.ps1
git commit -m "feat(plan3): /job-phase command (next/back/explicit/done) + lifecycle test"
```

---

## Task 7: `/job-resume` slash command + resume lifecycle test

**Files:**
- Create: `commands/job-resume.md`
- Modify: `scripts/test-jobs.ps1`

- [ ] **Step 1: Append resume test to `scripts/test-jobs.ps1`** (BEFORE the cleanup line):

```powershell
Write-Host "=== /job-resume ===" -ForegroundColor Cyan

# Set up a "previously-active" job by writing manifest then clearing state.
$resumeId = 'j-test-resume-job'
$resumeDir = Join-Path $jobsRoot $resumeId
New-Item -ItemType Directory -Path $resumeDir | Out-Null
$rNow = Get-Date -Format 'yyyy-MM-ddTHH:mm:sszzz'
Write-Manifest -JobDir $resumeDir -Manifest @{
    id = $resumeId; title = 'resume test'; created_at = $rNow
    status = 'active'; project = 'test'
    current_phase = 'code.sprint-2'; phase_started_at = $rNow
    sprint_count = 2; last_updated = $rNow
}
Set-Content -Path (Join-Path $resumeDir 'brief.md') -Value "# Brief`n`nresume test" -Encoding utf8
Clear-CurrentJob -StatePath $statePath

# Now resume — should restore state file from manifest
$mani = Read-Manifest -JobDir $resumeDir
Write-CurrentJob -StatePath $statePath -JobId $mani.id -Phase $mani.current_phase

$state = Read-CurrentJob -StatePath $statePath
Assert-Equal $resumeId       $state.job_id 'resume: job_id restored'
Assert-Equal 'code.sprint-2' $state.phase  'resume: phase restored from manifest'
```

- [ ] **Step 2: Run to verify pass**

```powershell
pwsh -NoProfile -File scripts\test-jobs.ps1
```

Expected: `All tests passed.`.

- [ ] **Step 3: Create `commands/job-resume.md`**

```markdown
---
description: Resume a previously-started job. Reads its manifest, sets the current-job state file so the hook resumes phase-tagging.
argument-hint: <job-id>
---

# /job-resume

Resume a job by ID. The ID is in `$ARGUMENTS` (e.g.,
`j-2026-05-26-feature-flags`).

## Steps

1. **Validate.** If `$ARGUMENTS` is empty, show output of `/job-list --active`
   and ask which one to resume.

2. **Check no other job is active.** Read `~/.claude/current-job.json`. If
   another job is set, prompt: *"Job `<other>` is active. Switch?"* — wait for
   confirmation.

3. **Run:**

   ```powershell
   . "$HOME/.claude/scripts/job-lib.ps1"
   $jobId = '<JOB_ID>'
   $jobDir = Join-Path $HOME ".claude/jobs/$jobId"
   if (-not (Test-Path $jobDir)) {
       Write-Host "No such job: $jobId" -ForegroundColor Red
       return
   }
   $mani = Read-Manifest -JobDir $jobDir
   if (-not $mani -or -not $mani.current_phase) {
       Write-Host "Manifest missing or corrupted for $jobId" -ForegroundColor Red
       return
   }
   Write-CurrentJob -JobId $mani.id -Phase $mani.current_phase
   Write-Host "Resumed $($mani.id)" -ForegroundColor Green
   Write-Host "  phase:   $($mani.current_phase)"
   Write-Host "  project: $($mani.project)"
   ```

4. Echo a short status to the user.

## Arguments

$ARGUMENTS
```

- [ ] **Step 4: Commit**

```powershell
git add commands/job-resume.md scripts/test-jobs.ps1
git commit -m "feat(plan3): /job-resume command + lifecycle test"
```

---

## Task 8: Hook extension — read state file, append trailing tags

**Files:**
- Modify: `scripts/hooks/log-tool-call.ps1`
- Modify: `scripts/test-hook.ps1`

- [ ] **Step 1: Read the existing `scripts/test-hook.ps1` to learn the test style**

```powershell
pwsh -NoProfile -Command "Get-Content scripts/test-hook.ps1 | Select-Object -First 60"
```

- [ ] **Step 2: Add failing tests for tagging to `scripts/test-hook.ps1`**

Append to that file (matching the existing test style):

```powershell
# --- Plan 3: tagging tests ---
Write-Host ""
Write-Host "=== Plan 3: state-file-driven job/phase tagging ===" -ForegroundColor Cyan

$tagTmp = New-Item -ItemType Directory -Path (Join-Path $env:TEMP "cao-hook-tag-$(Get-Random)") -Force
$tagJournal = Join-Path $tagTmp 'journal.md'
$tagErr     = Join-Path $tagTmp 'err.log'
$tagState   = Join-Path $tagTmp 'current-job.json'

# Helper to run the hook with a specific state path
function Invoke-HookWithState($json, $statePath) {
    $env:CAO_STATE_PATH = $statePath
    try {
        return $json | pwsh -NoProfile -File scripts/hooks/log-tool-call.ps1 `
            -JournalPath $tagJournal -ErrorPath $tagErr 2>&1
    } finally {
        Remove-Item env:CAO_STATE_PATH -ErrorAction SilentlyContinue
    }
}

$sampleEvent = @{
    tool_name = 'Bash'
    tool_input = @{ command = 'ollama run devstral:24b "hello"' }
    tool_response = @{ exit_code = 0; duration_ms = 2000 }
} | ConvertTo-Json -Depth 5 -Compress

# Case A: no state file → line has NO job: / phase: trailing tags
Remove-Item $tagJournal -ErrorAction SilentlyContinue
Invoke-HookWithState $sampleEvent $tagState | Out-Null
$line = (Get-Content $tagJournal | Where-Object { $_ -match '\| hook \|' })[-1]
if ($line -match 'job:') { throw "FAIL: no-state case should not have job: tag, got: $line" }
if ($line -match 'phase:') { throw "FAIL: no-state case should not have phase: tag, got: $line" }
Write-Host "  ok: no state file → no tags" -ForegroundColor Green

# Case B: state file present → line has both tags
Set-Content -Path $tagState -Value (@{ job_id = 'j-2026-05-26-test'; phase = 'research' } | ConvertTo-Json) -Encoding utf8
Remove-Item $tagJournal -ErrorAction SilentlyContinue
Invoke-HookWithState $sampleEvent $tagState | Out-Null
$line = (Get-Content $tagJournal | Where-Object { $_ -match '\| hook \|' })[-1]
if ($line -notmatch 'job:j-2026-05-26-test') { throw "FAIL: should contain job tag, got: $line" }
if ($line -notmatch 'phase:research')        { throw "FAIL: should contain phase tag, got: $line" }
Write-Host "  ok: state file set → trailing tags appended" -ForegroundColor Green

# Case C: corrupted state file → graceful fallback (no tags, no crash)
Set-Content -Path $tagState -Value '{ broken json' -Encoding utf8
Remove-Item $tagJournal -ErrorAction SilentlyContinue
Invoke-HookWithState $sampleEvent $tagState | Out-Null
$line = (Get-Content $tagJournal | Where-Object { $_ -match '\| hook \|' })[-1]
if ($line -match 'job:') { throw "FAIL: corrupted state should yield no tags, got: $line" }
Write-Host "  ok: corrupted state → graceful fallback, no tags" -ForegroundColor Green

Remove-Item $tagTmp -Recurse -Force
```

- [ ] **Step 3: Run to verify it fails**

```powershell
pwsh -NoProfile -File scripts\test-hook.ps1
```

Expected: failure on case B because the hook doesn't yet append tags.

- [ ] **Step 4: Modify `scripts/hooks/log-tool-call.ps1`** to read state and append tags

Add a `$StatePath` parameter (default driven by `$env:CAO_STATE_PATH` for test injection, else `~/.claude/current-job.json`). Then, after the existing line-building, append job/phase if present.

Edit the param block at the top from:
```powershell
param(
    [string]$JournalPath = (Join-Path $HOME '.claude/model-routing-log.md'),
    [string]$ErrorPath   = (Join-Path $HOME '.claude/hooks/log-tool-call.err.log')
)
```
to:
```powershell
param(
    [string]$JournalPath = (Join-Path $HOME '.claude/model-routing-log.md'),
    [string]$ErrorPath   = (Join-Path $HOME '.claude/hooks/log-tool-call.err.log'),
    [string]$StatePath   = $(if ($env:CAO_STATE_PATH) { $env:CAO_STATE_PATH } else { Join-Path $HOME '.claude/current-job.json' })
)
```

Then locate the block that builds `$line` (currently the `# Build the journal line.` comment through the `if ($brief) { $line += " | `"$brief`"" }`) and add right AFTER that block (before `Add-Content`):

```powershell
# Plan 3: trailing job: + phase: tags from state file
try {
    if (Test-Path $StatePath) {
        $raw = Get-Content $StatePath -Raw -ErrorAction Stop
        if (-not [string]::IsNullOrWhiteSpace($raw)) {
            $state = $raw | ConvertFrom-Json -ErrorAction Stop
            if ($state.job_id -and $state.phase) {
                $line += " | job:$($state.job_id) | phase:$($state.phase)"
            }
        }
    }
} catch {
    # Corrupted state file — log and skip tags. Never crash the hook.
    Write-ErrorLog "state file read failed: $($_.Exception.Message)"
}
```

- [ ] **Step 5: Run to verify pass**

```powershell
pwsh -NoProfile -File scripts\test-hook.ps1
```

Expected: all cases pass, including the original Plan 1 cases.

- [ ] **Step 6: Commit**

```powershell
git add scripts/hooks/log-tool-call.ps1 scripts/test-hook.ps1
git commit -m "feat(plan3): hook extension — read state file, append job/phase tags"
```

---

## Task 9: `/job-lesson` slash command + journal `lesson` line

**Files:**
- Create: `commands/job-lesson.md`
- Modify: `scripts/job-lib.ps1` (add valid categories + scope defaults + write helper)
- Modify: `scripts/test-job-lib.ps1`

- [ ] **Step 1: Add failing tests to `scripts/test-job-lib.ps1`**

Append before the final `All tests passed.`:

```powershell
# --- Lesson categories + scope ---
Write-Host "=== Lesson categories ===" -ForegroundColor Cyan
Assert-Equal 'universal' (Get-LessonDefaultScope 'user-pref') 'user-pref defaults to universal'
Assert-Equal 'universal' (Get-LessonDefaultScope 'routing')   'routing defaults to universal'
Assert-Equal 'project'   (Get-LessonDefaultScope 'mistake')   'mistake defaults to project'
Assert-Equal 'project'   (Get-LessonDefaultScope 'convention') 'convention defaults to project'
Assert-Equal 'project'   (Get-LessonDefaultScope 'knowledge')  'knowledge defaults to project'
if ((Test-LessonCategory 'bogus')) { throw "FAIL: bogus should not validate as a category" }
if (-not (Test-LessonCategory 'mistake')) { throw "FAIL: mistake should validate" }
```

- [ ] **Step 2: Run to verify failure**

```powershell
pwsh -NoProfile -File scripts\test-job-lib.ps1
```

Expected: *"The term 'Get-LessonDefaultScope' is not recognized"*.

- [ ] **Step 3: Add lesson functions to `scripts/job-lib.ps1`**

Append:

```powershell
# Lesson taxonomy — keep in lock-step with the spec.
$script:LessonCategories = @{
    'routing'      = 'universal'
    'user-pref'    = 'universal'
    'reasoning'    = 'universal'
    'mistake'      = 'project'
    'winner'       = 'project'
    'convention'   = 'project'
    'decision'     = 'project'
    'architecture' = 'project'
    'knowledge'    = 'project'
}

function Test-LessonCategory {
    param([Parameter(Mandatory)][string]$Category)
    return $script:LessonCategories.ContainsKey($Category)
}

function Get-LessonDefaultScope {
    param([Parameter(Mandatory)][string]$Category)
    return $script:LessonCategories[$Category]
}

function Get-LessonCategories {
    return $script:LessonCategories.Keys | Sort-Object
}

function Append-LessonToJob {
    param(
        [Parameter(Mandatory)][string]$JobDir,
        [Parameter(Mandatory)][string]$Phase,
        [Parameter(Mandatory)][string]$Category,
        [Parameter(Mandatory)][string]$Text
    )
    $path = Join-Path $JobDir 'lessons.md'
    if (-not (Test-Path $path)) {
        Set-Content -Path $path -Value "# Lessons`n" -Encoding utf8
    }
    # Find or create the `## <phase>` section
    $content = Get-Content $path -Raw
    $sectionHeader = "## $Phase"
    if ($content -notmatch [regex]::Escape($sectionHeader)) {
        Add-Content -Path $path -Value "`n$sectionHeader" -Encoding utf8
    }
    $ts = Get-Date -Format 'yyyy-MM-ddTHH:mm:sszzz'
    # Sanitize text: collapse newlines + escape pipes
    $safeText = ($Text -replace '\|', '¦' -replace "`r?`n", ' ').Trim()
    Add-Content -Path $path -Value "$ts | $Category | `"$safeText`"" -Encoding utf8
}
```

- [ ] **Step 4: Run to verify pass**

```powershell
pwsh -NoProfile -File scripts\test-job-lib.ps1
```

Expected: `All tests passed.`.

- [ ] **Step 5: Create `commands/job-lesson.md`**

```markdown
---
description: Capture a lesson into the active job's lessons.md and the journal. Categories: routing, user-pref, reasoning, mistake, winner, convention, decision, architecture, knowledge.
argument-hint: <category> "<text>" [--scope universal|project]
---

# /job-lesson

Append a lesson to the active job's `lessons.md` + write a `lesson` line to the
journal so the dashboard can show it.

## Steps

1. **Parse `$ARGUMENTS`:** first token is the category, then a quoted string is
   the text, then an optional `--scope universal|project`.

2. **Validate category.** If invalid, show the valid list and stop.

3. **Confirm active job.** If no active job, error: *"No active job — use
   /job-resume."*

4. **Run:**

   ```powershell
   . "$HOME/.claude/scripts/job-lib.ps1"
   $category = '<CATEGORY>'
   $text     = '<TEXT>'         # already single-quote-escaped
   $scope    = if ('<SCOPE>') { '<SCOPE>' } else { Get-LessonDefaultScope $category }

   if (-not (Test-LessonCategory $category)) {
       Write-Host "Invalid category. Valid: $((Get-LessonCategories) -join ', ')" -ForegroundColor Red
       return
   }

   $state = Read-CurrentJob
   if (-not $state.job_id) {
       Write-Host "No active job." -ForegroundColor Red
       return
   }
   $jobDir = Join-Path $HOME ".claude/jobs/$($state.job_id)"

   # Append to job lessons.md
   Append-LessonToJob -JobDir $jobDir -Phase $state.phase -Category $category -Text $text

   # Append a `lesson` line to the journal
   $ts = Get-Date -Format 'yyyy-MM-ddTHH:mm:sszzz'
   $safeText = ($text -replace '\|', '¦' -replace "`r?`n", ' ').Trim()
   $journalLine = "$ts | lesson | $category | `"$safeText`" | job:$($state.job_id) | phase:$($state.phase)"
   Add-Content -Path (Join-Path $HOME '.claude/model-routing-log.md') -Value $journalLine

   Write-Host "Lesson recorded ($category, scope=$scope)." -ForegroundColor Green
   ```

5. Echo confirmation to the user.

## Arguments

$ARGUMENTS
```

- [ ] **Step 6: Commit**

```powershell
git add scripts/job-lib.ps1 scripts/test-job-lib.ps1 commands/job-lesson.md
git commit -m "feat(plan3): /job-lesson + journal lesson line + tests"
```

---

## Task 10: `parse-otel.ps1` extension — tag OTel lines with current job/phase

**Files:**
- Modify: `scripts/parse-otel.ps1`
- Modify: `scripts/test-otel-parser.ps1`

- [ ] **Step 1: Read the existing OTel parser test for the style**

```powershell
pwsh -NoProfile -Command "Get-Content scripts/test-otel-parser.ps1 | Select-Object -First 60"
```

- [ ] **Step 2: Add a failing tagging test to `scripts/test-otel-parser.ps1`**

Append a test section that creates a state file, runs the parser against a fixture event, and asserts the emitted line contains the tags:

```powershell
# --- Plan 3: OTel tagging from state file ---
Write-Host ""
Write-Host "=== Plan 3: OTel events tagged with current job/phase ===" -ForegroundColor Cyan

$otelTmp = New-Item -ItemType Directory -Path (Join-Path $env:TEMP "cao-otel-tag-$(Get-Random)") -Force
$otelEvents  = Join-Path $otelTmp 'events.jsonl'
$otelJournal = Join-Path $otelTmp 'log.md'
$otelMarker  = Join-Path $otelTmp '.parse-marker'
$otelState   = Join-Path $otelTmp 'current-job.json'

# Minimal api_request event
$evt = '{"body":"claude_code.api_request","event.timestamp":"2026-05-26T11:05:00+00:00","model":"claude-sonnet-4-6","input_tokens":100,"output_tokens":50,"cost_usd":0.001}'
Set-Content -Path $otelEvents -Value $evt -Encoding utf8

# Case A: no state → untagged otel line (Plan 1 format)
$env:CAO_STATE_PATH = $otelState
try {
    & pwsh -NoProfile -File scripts/parse-otel.ps1 `
        -EventsPath $otelEvents -JournalPath $otelJournal `
        -MarkerPath $otelMarker -CatalogPath (Join-Path $otelTmp 'no-catalog.md') | Out-Null
} finally {
    Remove-Item env:CAO_STATE_PATH -ErrorAction SilentlyContinue
}
$line = (Get-Content $otelJournal | Where-Object { $_ -match '\| otel \|' })[-1]
if (-not $line) { throw "FAIL: no otel line written" }
if ($line -match 'job:') { throw "FAIL: untagged case should not have job:, got: $line" }
Write-Host "  ok: no state → untagged otel line" -ForegroundColor Green

# Case B: state present → tagged
Set-Content -Path $otelState -Value (@{ job_id = 'j-test-otel'; phase = 'research' } | ConvertTo-Json) -Encoding utf8
Remove-Item $otelJournal -ErrorAction SilentlyContinue
Remove-Item $otelMarker  -ErrorAction SilentlyContinue
$env:CAO_STATE_PATH = $otelState
try {
    & pwsh -NoProfile -File scripts/parse-otel.ps1 `
        -EventsPath $otelEvents -JournalPath $otelJournal `
        -MarkerPath $otelMarker -CatalogPath (Join-Path $otelTmp 'no-catalog.md') | Out-Null
} finally {
    Remove-Item env:CAO_STATE_PATH -ErrorAction SilentlyContinue
}
$line = (Get-Content $otelJournal | Where-Object { $_ -match '\| otel \|' })[-1]
if ($line -notmatch 'job:j-test-otel') { throw "FAIL: should have job: tag, got: $line" }
if ($line -notmatch 'phase:research')   { throw "FAIL: should have phase: tag, got: $line" }
Write-Host "  ok: state present → tagged otel line" -ForegroundColor Green

Remove-Item $otelTmp -Recurse -Force
```

- [ ] **Step 3: Run to verify failure**

```powershell
pwsh -NoProfile -File scripts\test-otel-parser.ps1
```

Expected: failure on case B.

- [ ] **Step 4: Modify `scripts/parse-otel.ps1`** to read state and append tags

Add to the param block:
```powershell
[string]$StatePath = $(if ($env:CAO_STATE_PATH) { $env:CAO_STATE_PATH } else { Join-Path $HOME '.claude/current-job.json' })
```

Right after the param block (before `$ErrorActionPreference = 'Stop'` is fine, but the read needs to be in scope of the loop), add a one-shot read at the top of the file:

```powershell
# Plan 3: read current job/phase from state file once (parser is one-shot)
$script:JobTag = ''
try {
    if (Test-Path $StatePath) {
        $raw = Get-Content $StatePath -Raw -ErrorAction Stop
        if (-not [string]::IsNullOrWhiteSpace($raw)) {
            $state = $raw | ConvertFrom-Json -ErrorAction Stop
            if ($state.job_id -and $state.phase) {
                $script:JobTag = " | job:$($state.job_id) | phase:$($state.phase)"
            }
        }
    }
} catch {
    # Corrupted state — fall back to untagged
}
```

Then update the line that emits the otel journal entry. Find:
```powershell
$newJournalLines += "$ts | otel | $model | in:$inTok out:$outTok | `$$costStr | api_request"
```
Change to:
```powershell
$newJournalLines += "$ts | otel | $model | in:$inTok out:$outTok | `$$costStr | api_request$($script:JobTag)"
```

- [ ] **Step 5: Run to verify pass**

```powershell
pwsh -NoProfile -File scripts\test-otel-parser.ps1
```

Expected: all tests pass (including existing Plan 1 cases).

- [ ] **Step 6: Commit**

```powershell
git add scripts/parse-otel.ps1 scripts/test-otel-parser.ps1
git commit -m "feat(plan3): parse-otel.ps1 — tag OTel lines with current job/phase"
```

---

## Task 11: `/consolidate-lessons` script + slash command

**Files:**
- Create: `scripts/consolidate-lessons.ps1`
- Create: `commands/consolidate-lessons.md`
- Create: `scripts/test-consolidate-lessons.ps1`

- [ ] **Step 1: Write the failing test**

Create `scripts/test-consolidate-lessons.ps1`:

```powershell
#!/usr/bin/env pwsh
# Tests for consolidate-lessons.ps1: routing by category + scope, idempotency, source tagging.

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path

function Assert-Match($pattern, $actual, $msg) {
    if ($actual -notmatch $pattern) { throw "FAIL: $msg`n  pattern: $pattern`n  actual:`n$actual" }
}
function Assert-NotMatch($pattern, $actual, $msg) {
    if ($actual -match $pattern) { throw "FAIL: $msg`n  pattern: $pattern`n  actual:`n$actual" }
}

$root      = New-Item -ItemType Directory -Path (Join-Path $env:TEMP "cao-consol-$(Get-Random)") -Force
$jobsRoot  = Join-Path $root 'jobs'
$kbRoot    = Join-Path $root 'knowledge'
New-Item -ItemType Directory -Force -Path $jobsRoot, "$kbRoot/universal", "$kbRoot/projects" | Out-Null

# Set up one job with mixed-category lessons
$jobId  = 'j-2026-05-26-test'
$jobDir = Join-Path $jobsRoot $jobId
New-Item -ItemType Directory -Path $jobDir | Out-Null

# Minimal manifest
Set-Content (Join-Path $jobDir 'manifest.yaml') -Value @"
id: $jobId
project: testproj
status: active
current_phase: review
"@ -Encoding utf8

# lessons.md with three entries — two scopes, three categories
@"
# Lessons — $jobId

## research
2026-05-26T11:20:00-06:00 | knowledge | "Feature flags split into release vs ops toggles"

## code.sprint-1
2026-05-26T12:55:00-06:00 | mistake | "devstral generated flag write without locking"
2026-05-26T13:05:00-06:00 | user-pref | "Kevin prefers single-file TOML config"
"@ | Set-Content (Join-Path $jobDir 'lessons.md') -Encoding utf8

# Run consolidate
& pwsh -NoProfile -File (Join-Path $here 'consolidate-lessons.ps1') `
    -JobsRoot $jobsRoot -KbRoot $kbRoot | Out-Null

# Assertions: routing by category
$mistakes = Get-Content "$kbRoot/projects/testproj/mistakes.md" -Raw
Assert-Match 'devstral generated flag write' $mistakes 'mistake → projects/testproj/mistakes.md'
Assert-Match "\[$jobId\]" $mistakes 'mistake line carries source job tag'

$userPrefs = Get-Content "$kbRoot/universal/user-prefs.md" -Raw
Assert-Match 'single-file TOML' $userPrefs 'user-pref → universal/user-prefs.md'

$topic = Get-Content "$kbRoot/projects/testproj/topics/general.md" -Raw
Assert-Match 'release vs ops toggles' $topic 'knowledge → projects/testproj/topics/general.md'

# Source lessons.md should be marked consolidated
$lessons = Get-Content (Join-Path $jobDir 'lessons.md') -Raw
Assert-Match '✓ consolidated' $lessons 'source entries marked consolidated'

# Idempotency: second run is a no-op (no duplicate entries)
& pwsh -NoProfile -File (Join-Path $here 'consolidate-lessons.ps1') `
    -JobsRoot $jobsRoot -KbRoot $kbRoot | Out-Null

$mistakesAfter = Get-Content "$kbRoot/projects/testproj/mistakes.md" -Raw
$count1 = ([regex]::Matches($mistakes,      'devstral generated flag write')).Count
$count2 = ([regex]::Matches($mistakesAfter, 'devstral generated flag write')).Count
if ($count1 -ne $count2) { throw "FAIL: second run duplicated entries ($count1 → $count2)" }

Remove-Item $root -Recurse -Force
Write-Host "All tests passed." -ForegroundColor Green
```

- [ ] **Step 2: Run to verify failure**

```powershell
pwsh -NoProfile -File scripts\test-consolidate-lessons.ps1
```

Expected: *"Cannot find path …\consolidate-lessons.ps1"*.

- [ ] **Step 3: Create `scripts/consolidate-lessons.ps1`**

```powershell
#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Walk job lessons.md files, route entries to KB files by category + scope,
  mark source entries consolidated. Idempotent.

.DESCRIPTION
  For each job under $JobsRoot:
    For each lesson line not already marked '✓ consolidated':
      Resolve scope (default per category, override via line metadata if present).
      Append to the appropriate KB file with timestamp + [job-id] + text.
      Mark source line consolidated.
#>

param(
    [string]$JobsRoot = (Join-Path $HOME '.claude/jobs'),
    [string]$KbRoot   = (Join-Path $HOME '.claude/knowledge')
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here 'job-lib.ps1')

if (-not (Test-Path $JobsRoot)) { Write-Host "No jobs dir."; exit 0 }
if (-not (Test-Path $KbRoot))   { New-Item -ItemType Directory -Force -Path $KbRoot | Out-Null }
New-Item -ItemType Directory -Force -Path (Join-Path $KbRoot 'universal'), (Join-Path $KbRoot 'projects') | Out-Null

function Get-KbPath {
    param([string]$Category, [string]$Scope, [string]$Project, [string]$KbRoot)
    switch ($Category) {
        'routing'      { return Join-Path $KbRoot 'universal/routing.md' }
        'user-pref'    { return Join-Path $KbRoot 'universal/user-prefs.md' }
        'reasoning'    { return Join-Path $KbRoot 'universal/reasoning.md' }
        'mistake'      {
            if ($Scope -eq 'universal') { return Join-Path $KbRoot 'universal/mistakes.md' }
            return Join-Path $KbRoot "projects/$Project/mistakes.md"
        }
        'winner'       {
            if ($Scope -eq 'universal') { return Join-Path $KbRoot 'universal/winners.md' }
            return Join-Path $KbRoot "projects/$Project/winners.md"
        }
        'convention'   { return Join-Path $KbRoot "projects/$Project/conventions.md" }
        'decision'     { return Join-Path $KbRoot "projects/$Project/decisions.md" }
        'architecture' { return Join-Path $KbRoot "projects/$Project/architecture.md" }
        'knowledge'    {
            if ($Scope -eq 'universal') { return Join-Path $KbRoot 'universal/topics/general.md' }
            return Join-Path $KbRoot "projects/$Project/topics/general.md"
        }
        default { return $null }
    }
}

$consolidatedDate = Get-Date -Format 'yyyy-MM-dd'
$lessonLineRe = '^(?<ts>\d{4}-\d{2}-\d{2}T[\d:+-]+)\s*\|\s*(?<cat>[a-z-]+)\s*\|\s*"(?<text>.+?)"\s*(?<consolidated>✓ consolidated [\d-]+)?\s*$'

foreach ($jobDir in Get-ChildItem -Path $JobsRoot -Directory) {
    $mani = Read-Manifest -JobDir $jobDir.FullName
    if (-not $mani) { continue }
    $project = $mani.project
    $lessonsPath = Join-Path $jobDir.FullName 'lessons.md'
    if (-not (Test-Path $lessonsPath)) { continue }

    $newLines = @()
    $changed = $false
    foreach ($line in Get-Content $lessonsPath) {
        $m = [regex]::Match($line, $lessonLineRe)
        if (-not $m.Success -or $m.Groups['consolidated'].Value) {
            $newLines += $line
            continue
        }
        $cat = $m.Groups['cat'].Value
        if (-not (Test-LessonCategory $cat)) {
            $newLines += $line
            continue
        }
        $text = $m.Groups['text'].Value
        $scope = Get-LessonDefaultScope $cat
        # For project-scoped categories, skip if no project on this job
        if ($scope -eq 'project' -and -not $project) {
            $newLines += $line
            continue
        }
        $kbPath = Get-KbPath -Category $cat -Scope $scope -Project $project -KbRoot $KbRoot
        if (-not $kbPath) { $newLines += $line; continue }

        $kbDir = Split-Path -Parent $kbPath
        if (-not (Test-Path $kbDir)) { New-Item -ItemType Directory -Force -Path $kbDir | Out-Null }
        if (-not (Test-Path $kbPath)) {
            Set-Content -Path $kbPath -Value "# $cat`n" -Encoding utf8
        }
        $kbLine = "$($m.Groups['ts'].Value) | [$($mani.id)] | $text"
        Add-Content -Path $kbPath -Value $kbLine -Encoding utf8
        $newLines += "$line  ✓ consolidated $consolidatedDate"
        $changed = $true
    }
    if ($changed) {
        Set-Content -Path $lessonsPath -Value ($newLines -join "`n") -Encoding utf8
    }
}

Write-Host "Consolidation complete." -ForegroundColor Green
```

- [ ] **Step 4: Run to verify pass**

```powershell
pwsh -NoProfile -File scripts\test-consolidate-lessons.ps1
```

Expected: `All tests passed.`.

- [ ] **Step 5: Create `commands/consolidate-lessons.md`**

```markdown
---
description: Walk every job's lessons.md, append entries to the right KB file by category+scope, mark sources consolidated.
argument-hint: (no arguments)
---

# /consolidate-lessons

Run the consolidation script:

```powershell
& pwsh -NoProfile -File "$HOME/.claude/scripts/consolidate-lessons.ps1"
```

Then echo the result to the user.
```

- [ ] **Step 6: Commit**

```powershell
git add scripts/consolidate-lessons.ps1 commands/consolidate-lessons.md scripts/test-consolidate-lessons.ps1
git commit -m "feat(plan3): /consolidate-lessons script + slash command + tests"
```

---

## Task 12: Dashboard journal parser — handle trailing tags + `lesson` lines

**Files:**
- Modify: `dashboard/readers/journal.py`
- Modify: `dashboard/tests/test_journal.py`

- [ ] **Step 1: Add failing tests to `dashboard/tests/test_journal.py`**

Append:

```python
def test_parse_tagged_hook_line():
    from dashboard.readers.journal import parse_journal_line
    from dashboard.models.events import HookEntry
    line = '2026-05-26T11:00:00-06:00 | hook | bash:ollama list | 1s | exit:0 | job:j-foo | phase:research'
    e = parse_journal_line(line)
    assert isinstance(e, HookEntry)
    assert e.target == 'bash:ollama list'
    assert e.job_id == 'j-foo'
    assert e.phase == 'research'
    assert e.brief is None


def test_parse_tagged_hook_with_brief():
    from dashboard.readers.journal import parse_journal_line
    from dashboard.models.events import HookEntry
    line = '2026-05-26T11:00:00-06:00 | hook | agent:Explore | 12s | exit:0 | "find patterns" | job:j-foo | phase:research'
    e = parse_journal_line(line)
    assert isinstance(e, HookEntry)
    assert e.brief == 'find patterns'
    assert e.job_id == 'j-foo'
    assert e.phase == 'research'


def test_parse_tagged_otel_line():
    from dashboard.readers.journal import parse_journal_line
    from dashboard.models.events import OtelEntry
    line = '2026-05-26T11:05:00-06:00 | otel | claude-sonnet-4-6 | in:100 out:50 | $0.0011 | api_request | job:j-foo | phase:research'
    e = parse_journal_line(line)
    assert isinstance(e, OtelEntry)
    assert e.job_id == 'j-foo'
    assert e.phase == 'research'


def test_parse_lesson_line():
    from dashboard.readers.journal import parse_journal_line
    from dashboard.models.events import LessonEntry
    line = '2026-05-26T11:20:00-06:00 | lesson | knowledge | "Feature flags split into release vs ops" | job:j-foo | phase:research'
    e = parse_journal_line(line)
    assert isinstance(e, LessonEntry)
    assert e.category == 'knowledge'
    assert 'release vs ops' in e.text
    assert e.job_id == 'j-foo'


def test_untagged_lines_still_parse():
    # Plan 1/2 format with no trailing tags must still work
    from dashboard.readers.journal import parse_journal_line
    from dashboard.models.events import HookEntry
    line = '2026-05-23T10:00:00-06:00 | hook | bash:ollama list | 2s | exit:0'
    e = parse_journal_line(line)
    assert isinstance(e, HookEntry)
    assert e.job_id is None
    assert e.phase is None
```

- [ ] **Step 2: Run to verify failure**

```powershell
python -m pytest dashboard/tests/test_journal.py -v
```

Expected: tests fail on `LessonEntry` import + `job_id` attribute.

- [ ] **Step 3: Modify `dashboard/readers/journal.py`**

Replace the existing file with:

```python
from __future__ import annotations

import re
from datetime import datetime
from pathlib import Path
from typing import Optional, Tuple, Union

from dashboard.models.events import (
    HookEntry,
    LessonEntry,
    NoteEntry,
    OtelEntry,
)

JournalEntry = Union[HookEntry, OtelEntry, NoteEntry, LessonEntry]

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


def _extract_trailing_tags(parts: list[str]) -> Tuple[list[str], Optional[str], Optional[str]]:
    """Strip trailing `job:<id>` and `phase:<phase>` fields from the end of `parts`.
    Returns (remaining_parts, job_id, phase). Either tag can be absent."""
    job_id: Optional[str] = None
    phase: Optional[str] = None
    # Tags appear at the end. Each is a single pipe field like 'job:foo' or 'phase:research'.
    while parts and (parts[-1].startswith('job:') or parts[-1].startswith('phase:')):
        last = parts.pop()
        if last.startswith('job:'):
            job_id = last[4:].strip() or None
        elif last.startswith('phase:'):
            phase = last[6:].strip() or None
    return parts, job_id, phase


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
    # Strip trailing tags from all sources uniformly before source-specific parsing.
    parts, job_id, phase = _extract_trailing_tags(parts)

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
            job_id=job_id,
            phase=phase,
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
            job_id=job_id,
            phase=phase,
        )

    if source == "note":
        if len(parts) < 4:
            return None
        return NoteEntry(
            timestamp=timestamp,
            target=parts[2],
            text=_strip_quotes(parts[3]),
            job_id=job_id,
            phase=phase,
        )

    if source == "lesson":
        if len(parts) < 4:
            return None
        return LessonEntry(
            timestamp=timestamp,
            category=parts[2],
            text=_strip_quotes(parts[3]),
            job_id=job_id,
            phase=phase,
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
```

- [ ] **Step 4: Run to verify pass (will still fail on LessonEntry import — fix in Task 13)**

Skip running the test here; it'll pass after Task 13. Just commit.

- [ ] **Step 5: Commit**

```powershell
git add dashboard/readers/journal.py dashboard/tests/test_journal.py
git commit -m "feat(plan3): dashboard journal parser — trailing tags + lesson lines"
```

---

## Task 13: Dashboard models — add `job_id`/`phase`/LessonEntry/Job models

**Files:**
- Modify: `dashboard/models/events.py`
- Modify: `dashboard/tests/test_models.py`

- [ ] **Step 1: Add failing tests to `dashboard/tests/test_models.py`**

Append:

```python
def test_hook_entry_optional_tags():
    from dashboard.models.events import HookEntry
    e = HookEntry(timestamp=datetime(2026,5,26,11), target='x', duration_s=1, exit_code=0)
    assert e.job_id is None
    assert e.phase is None

    e2 = HookEntry(timestamp=datetime(2026,5,26,11), target='x', duration_s=1, exit_code=0,
                   job_id='j-1', phase='research')
    assert e2.job_id == 'j-1'
    assert e2.phase == 'research'


def test_lesson_entry_fields():
    from dashboard.models.events import LessonEntry
    e = LessonEntry(timestamp=datetime(2026,5,26,11), category='knowledge',
                    text='things', job_id='j-1', phase='research')
    assert e.category == 'knowledge'
    assert e.text == 'things'


def test_job_summary_fields():
    from dashboard.models.events import JobSummary
    s = JobSummary(
        id='j-1', title='t', project='p', current_phase='research',
        status='active', created_at=datetime(2026,5,26,11),
        sprint_count=0, cost_usd=0.0,
    )
    assert s.id == 'j-1'
    assert s.status == 'active'


def test_phase_log_entry_fields():
    from dashboard.models.events import PhaseLogEntry
    e = PhaseLogEntry(timestamp=datetime(2026,5,26,11),
                      kind='transition', detail='research → design')
    assert e.kind == 'transition'


def test_job_detail_fields():
    from dashboard.models.events import JobDetail, JobSummary, PhaseLogEntry, LessonEntry
    summary = JobSummary(
        id='j-1', title='t', project='p', current_phase='research',
        status='active', created_at=datetime(2026,5,26,11),
        sprint_count=0, cost_usd=0.0,
    )
    detail = JobDetail(
        summary=summary,
        brief='hello',
        phase_log=[],
        journal=[],
        lessons=[],
        cost_by_phase={'research': 0.0},
    )
    assert detail.brief == 'hello'
```

(Add `from datetime import datetime` at the top of the file if not present.)

- [ ] **Step 2: Modify `dashboard/models/events.py`** to add the new fields/models

Replace the file:

```python
from __future__ import annotations

from datetime import datetime
from typing import Optional

from pydantic import BaseModel


class HookEntry(BaseModel):
    timestamp: datetime
    target: str
    duration_s: int
    exit_code: int
    brief: Optional[str] = None
    job_id: Optional[str] = None
    phase: Optional[str] = None


class OtelEntry(BaseModel):
    timestamp: datetime
    model: str
    input_tokens: int
    output_tokens: int
    cost_usd: float
    job_id: Optional[str] = None
    phase: Optional[str] = None


class NoteEntry(BaseModel):
    timestamp: datetime
    target: str
    text: str
    job_id: Optional[str] = None
    phase: Optional[str] = None


class LessonEntry(BaseModel):
    timestamp: datetime
    category: str
    text: str
    job_id: Optional[str] = None
    phase: Optional[str] = None


class OllamaModel(BaseModel):
    name: str
    status: str
    size: str


class LmStudioModel(BaseModel):
    id: str
    loaded: bool = True


class ModelStats(BaseModel):
    name: str
    calls: int
    cost_usd: float
    tokens_in: int
    tokens_out: int


# --- Plan 3: job models ---


class PhaseLogEntry(BaseModel):
    timestamp: datetime
    kind: str            # 'created' | 'transition' | 'loop-back'
    detail: str          # e.g. 'research → design'
    note: Optional[str] = None


class JobSummary(BaseModel):
    id: str
    title: str
    project: Optional[str] = None
    current_phase: str
    status: str          # 'active' | 'done' | 'abandoned'
    created_at: datetime
    sprint_count: int = 0
    cost_usd: float = 0.0


class JobDetail(BaseModel):
    summary: JobSummary
    brief: str
    phase_log: list[PhaseLogEntry]
    journal: list                          # HookEntry | OtelEntry | NoteEntry | LessonEntry (mixed)
    lessons: list[LessonEntry]
    cost_by_phase: dict[str, float]        # phase → cost_usd


class DashboardStats(BaseModel):
    today_cost_usd: float
    total_otel_calls: int
    models: list[ModelStats]
    recent_hooks: list[HookEntry]
    ollama_models: list[OllamaModel]
    lms_models: list[LmStudioModel] = []
    last_updated: datetime
```

- [ ] **Step 3: Run to verify model tests AND journal tests pass**

```powershell
python -m pytest dashboard/tests/test_models.py dashboard/tests/test_journal.py -v
```

Expected: all green.

- [ ] **Step 4: Commit**

```powershell
git add dashboard/models/events.py dashboard/tests/test_models.py
git commit -m "feat(plan3): dashboard models — job_id/phase tags, LessonEntry, Job{Summary,Detail}"
```

---

## Task 14: Jobs reader

**Files:**
- Create: `dashboard/readers/jobs.py`
- Create: `dashboard/tests/test_jobs_reader.py`
- Modify: `dashboard/tests/conftest.py` (add a `jobs_root` fixture)

- [ ] **Step 1: Add fixture to `dashboard/tests/conftest.py`**

```python
import pytest
from pathlib import Path


@pytest.fixture
def jobs_root(tmp_path: Path) -> Path:
    """Two fake jobs under a temporary jobs root."""
    root = tmp_path / 'jobs'
    root.mkdir()

    # Active job
    j1 = root / 'j-2026-05-26-feature-flags'
    j1.mkdir()
    (j1 / 'manifest.yaml').write_text(
        'id: j-2026-05-26-feature-flags\n'
        'title: "build a feature flag system"\n'
        'project: coding-agent-orchestrator\n'
        'status: active\n'
        'current_phase: research\n'
        'created_at: 2026-05-26T11:00:00-06:00\n'
        'phase_started_at: 2026-05-26T11:00:00-06:00\n'
        'sprint_count: 0\n'
        'last_updated: 2026-05-26T11:00:00-06:00\n',
        encoding='utf-8',
    )
    (j1 / 'brief.md').write_text('# Brief\n\nbuild a feature flag system', encoding='utf-8')
    (j1 / 'phase-log.md').write_text(
        '# Phase Log\n\n'
        '2026-05-26T11:00:00-06:00 | created | research\n'
        '2026-05-26T11:35:00-06:00 | transition | research → design\n',
        encoding='utf-8',
    )
    (j1 / 'lessons.md').write_text(
        '# Lessons\n\n## research\n'
        '2026-05-26T11:20:00-06:00 | knowledge | "Feature flags split into release vs ops"\n',
        encoding='utf-8',
    )

    # Done job
    j2 = root / 'j-2026-05-20-logging-fix'
    j2.mkdir()
    (j2 / 'manifest.yaml').write_text(
        'id: j-2026-05-20-logging-fix\n'
        'title: "fix logging"\n'
        'project: coding-agent-orchestrator\n'
        'status: done\n'
        'current_phase: done\n'
        'created_at: 2026-05-20T11:00:00-06:00\n'
        'phase_started_at: 2026-05-20T11:00:00-06:00\n'
        'sprint_count: 1\n'
        'last_updated: 2026-05-20T15:00:00-06:00\n',
        encoding='utf-8',
    )
    (j2 / 'brief.md').write_text('# Brief\n\nfix logging', encoding='utf-8')
    (j2 / 'phase-log.md').write_text('# Phase Log\n', encoding='utf-8')
    (j2 / 'lessons.md').write_text('# Lessons\n', encoding='utf-8')

    return root


@pytest.fixture
def tagged_journal_file(tmp_path: Path) -> Path:
    """Journal containing tagged + untagged lines spanning two jobs."""
    content = (
        '# Model Routing Log\n\n'
        # untagged Plan 1/2 lines
        '2026-05-22T09:00:00-06:00 | hook | bash:ollama list | 1s | exit:0\n'
        # tagged Plan 3 lines for j-2026-05-26-feature-flags
        '2026-05-26T11:00:00-06:00 | hook | bash:ollama run devstral | 2s | exit:0 | job:j-2026-05-26-feature-flags | phase:research\n'
        '2026-05-26T11:05:00-06:00 | otel | claude-sonnet-4-6 | in:3214 out:892 | $0.0231 | api_request | job:j-2026-05-26-feature-flags | phase:research\n'
        '2026-05-26T11:36:00-06:00 | otel | claude-sonnet-4-6 | in:1000 out:500 | $0.0150 | api_request | job:j-2026-05-26-feature-flags | phase:design\n'
        '2026-05-26T11:20:00-06:00 | lesson | knowledge | "release vs ops toggles" | job:j-2026-05-26-feature-flags | phase:research\n'
        # tagged line for the other job
        '2026-05-20T13:00:00-06:00 | otel | claude-sonnet-4-6 | in:200 out:100 | $0.0040 | api_request | job:j-2026-05-20-logging-fix | phase:code.sprint-1\n'
    )
    p = tmp_path / 'log.md'
    p.write_text(content, encoding='utf-8')
    return p
```

- [ ] **Step 2: Write failing tests in `dashboard/tests/test_jobs_reader.py`**

```python
import pytest
from pathlib import Path
from datetime import datetime

from dashboard.readers.jobs import (
    list_job_summaries,
    read_job_detail,
)


def test_list_active_jobs(jobs_root: Path, tagged_journal_file: Path):
    summaries = list_job_summaries(jobs_root, tagged_journal_file, status_filter='active')
    assert len(summaries) == 1
    assert summaries[0].id == 'j-2026-05-26-feature-flags'
    assert summaries[0].current_phase == 'research'


def test_list_all_jobs_sorted_newest_first(jobs_root: Path, tagged_journal_file: Path):
    summaries = list_job_summaries(jobs_root, tagged_journal_file, status_filter='all')
    assert len(summaries) == 2
    assert summaries[0].id == 'j-2026-05-26-feature-flags'   # newer first
    assert summaries[1].id == 'j-2026-05-20-logging-fix'


def test_summary_cost_aggregation(jobs_root: Path, tagged_journal_file: Path):
    summaries = list_job_summaries(jobs_root, tagged_journal_file, status_filter='all')
    by_id = {s.id: s for s in summaries}
    # j-2026-05-26-feature-flags has two otel entries: $0.0231 + $0.0150
    assert by_id['j-2026-05-26-feature-flags'].cost_usd == pytest.approx(0.0381)
    assert by_id['j-2026-05-20-logging-fix'].cost_usd == pytest.approx(0.0040)


def test_job_detail_loads_brief_phase_log_lessons(jobs_root: Path, tagged_journal_file: Path):
    detail = read_job_detail(jobs_root, tagged_journal_file, 'j-2026-05-26-feature-flags')
    assert detail.brief.strip().endswith('build a feature flag system')
    assert len(detail.phase_log) == 2
    assert detail.phase_log[1].detail == 'research → design'
    assert len(detail.lessons) == 1
    assert 'release vs ops' in detail.lessons[0].text


def test_job_detail_filters_journal_by_job_id(jobs_root: Path, tagged_journal_file: Path):
    detail = read_job_detail(jobs_root, tagged_journal_file, 'j-2026-05-26-feature-flags')
    # Journal should NOT include the untagged Plan 1 line, NOR the j-2026-05-20-* line
    assert all(getattr(e, 'job_id', None) == 'j-2026-05-26-feature-flags' for e in detail.journal)
    assert len(detail.journal) == 4   # 1 hook + 2 otel + 1 lesson


def test_job_detail_cost_by_phase(jobs_root: Path, tagged_journal_file: Path):
    detail = read_job_detail(jobs_root, tagged_journal_file, 'j-2026-05-26-feature-flags')
    assert detail.cost_by_phase['research'] == pytest.approx(0.0231)
    assert detail.cost_by_phase['design']   == pytest.approx(0.0150)


def test_unknown_job_id_raises(jobs_root: Path, tagged_journal_file: Path):
    with pytest.raises(FileNotFoundError):
        read_job_detail(jobs_root, tagged_journal_file, 'j-nope')
```

- [ ] **Step 3: Run to verify failure**

```powershell
python -m pytest dashboard/tests/test_jobs_reader.py -v
```

Expected: `ImportError: cannot import name 'list_job_summaries' from 'dashboard.readers.jobs'`.

- [ ] **Step 4: Implement `dashboard/readers/jobs.py`**

```python
from __future__ import annotations

import re
from collections import defaultdict
from datetime import datetime
from pathlib import Path
from typing import Optional

from dashboard.models.events import (
    JobDetail,
    JobSummary,
    LessonEntry,
    OtelEntry,
    PhaseLogEntry,
)
from dashboard.readers.journal import read_journal

_MANIFEST_LINE_RE = re.compile(r'^([a-zA-Z_]+):\s*"?([^"]+?)"?\s*$')
_PHASE_LOG_RE = re.compile(
    r'^(?P<ts>\d{4}-\d{2}-\d{2}T[\d:+-]+)\s*\|\s*(?P<kind>[a-z-]+)\s*\|\s*(?P<detail>[^|]+?)(?:\s*note:\s*"(?P<note>[^"]*)")?\s*$'
)
_LESSON_LINE_RE = re.compile(
    r'^(?P<ts>\d{4}-\d{2}-\d{2}T[\d:+-]+)\s*\|\s*(?P<cat>[a-z-]+)\s*\|\s*"(?P<text>.+?)"\s*(✓ consolidated [\d-]+)?$'
)


def _parse_manifest(path: Path) -> dict[str, str]:
    if not path.exists():
        return {}
    out: dict[str, str] = {}
    for line in path.read_text(encoding='utf-8').splitlines():
        m = _MANIFEST_LINE_RE.match(line)
        if m:
            out[m.group(1)] = m.group(2)
    return out


def _parse_phase_log(path: Path) -> list[PhaseLogEntry]:
    if not path.exists():
        return []
    out: list[PhaseLogEntry] = []
    for line in path.read_text(encoding='utf-8').splitlines():
        m = _PHASE_LOG_RE.match(line.strip())
        if not m:
            continue
        out.append(PhaseLogEntry(
            timestamp=datetime.fromisoformat(m.group('ts')),
            kind=m.group('kind'),
            detail=m.group('detail').strip(),
            note=m.group('note'),
        ))
    return out


def _parse_lessons(path: Path) -> list[LessonEntry]:
    if not path.exists():
        return []
    out: list[LessonEntry] = []
    current_phase: Optional[str] = None
    for line in path.read_text(encoding='utf-8').splitlines():
        stripped = line.strip()
        if stripped.startswith('## '):
            current_phase = stripped[3:].strip()
            continue
        m = _LESSON_LINE_RE.match(stripped)
        if not m:
            continue
        out.append(LessonEntry(
            timestamp=datetime.fromisoformat(m.group('ts')),
            category=m.group('cat'),
            text=m.group('text'),
            phase=current_phase,
        ))
    return out


def _job_cost_from_journal(journal: list, job_id: str) -> float:
    return sum(
        e.cost_usd for e in journal
        if isinstance(e, OtelEntry) and e.job_id == job_id
    )


def _job_summary_from_dir(job_dir: Path, journal: list) -> Optional[JobSummary]:
    manifest = _parse_manifest(job_dir / 'manifest.yaml')
    if not manifest:
        return None
    return JobSummary(
        id=manifest.get('id', job_dir.name),
        title=manifest.get('title', '(untitled)'),
        project=manifest.get('project') or None,
        current_phase=manifest.get('current_phase', 'research'),
        status=manifest.get('status', 'active'),
        created_at=datetime.fromisoformat(manifest.get('created_at', '2000-01-01T00:00:00+00:00')),
        sprint_count=int(manifest.get('sprint_count', 0)),
        cost_usd=round(_job_cost_from_journal(journal, manifest.get('id', '')), 4),
    )


def list_job_summaries(
    jobs_root: Path,
    journal_path: Path,
    status_filter: str = 'active',
) -> list[JobSummary]:
    if not jobs_root.exists():
        return []
    journal = read_journal(journal_path)
    summaries: list[JobSummary] = []
    for d in jobs_root.iterdir():
        if not d.is_dir():
            continue
        s = _job_summary_from_dir(d, journal)
        if s is None:
            continue
        if status_filter != 'all' and s.status != status_filter:
            continue
        summaries.append(s)
    summaries.sort(key=lambda s: s.created_at, reverse=True)
    return summaries


def read_job_detail(
    jobs_root: Path,
    journal_path: Path,
    job_id: str,
) -> JobDetail:
    job_dir = jobs_root / job_id
    if not job_dir.exists():
        raise FileNotFoundError(f'No such job: {job_id}')
    journal = read_journal(journal_path)
    summary = _job_summary_from_dir(job_dir, journal)
    if summary is None:
        raise FileNotFoundError(f'No manifest for job: {job_id}')

    # Filter journal to entries tagged with this job, newest-first
    filtered = sorted(
        [e for e in journal if getattr(e, 'job_id', None) == job_id],
        key=lambda e: e.timestamp,
        reverse=True,
    )

    # Per-phase cost from OTel entries
    cost_by_phase: dict[str, float] = defaultdict(float)
    for e in journal:
        if isinstance(e, OtelEntry) and e.job_id == job_id and e.phase:
            cost_by_phase[e.phase] += e.cost_usd
    cost_by_phase = {k: round(v, 4) for k, v in cost_by_phase.items()}

    return JobDetail(
        summary=summary,
        brief=(job_dir / 'brief.md').read_text(encoding='utf-8'),
        phase_log=_parse_phase_log(job_dir / 'phase-log.md'),
        journal=filtered,
        lessons=_parse_lessons(job_dir / 'lessons.md'),
        cost_by_phase=cost_by_phase,
    )
```

- [ ] **Step 5: Run to verify pass**

```powershell
python -m pytest dashboard/tests/test_jobs_reader.py -v
```

Expected: `7 passed`.

- [ ] **Step 6: Commit**

```powershell
git add dashboard/readers/jobs.py dashboard/tests/test_jobs_reader.py dashboard/tests/conftest.py
git commit -m "feat(plan3): jobs reader (list summaries + drill-in detail with per-phase cost)"
```

---

## Task 15: Jobs router

**Files:**
- Create: `dashboard/routers/jobs.py`
- Create: `dashboard/tests/test_jobs_router.py`

- [ ] **Step 1: Write failing tests**

`dashboard/tests/test_jobs_router.py`:

```python
import pytest
from pathlib import Path
from fastapi import FastAPI
from fastapi.responses import HTMLResponse
from fastapi.templating import Jinja2Templates
from fastapi.testclient import TestClient

from dashboard.routers.jobs import build_router


def make_app(jobs_root: Path, journal_path: Path) -> FastAPI:
    app = FastAPI()
    app.state.jobs_root = jobs_root
    app.state.journal_path = journal_path
    here = Path(__file__).parent.parent
    templates = Jinja2Templates(directory=str(here / 'templates'))
    app.include_router(build_router(templates))
    return app


def test_partial_jobs_html(jobs_root: Path, tagged_journal_file: Path):
    client = TestClient(make_app(jobs_root, tagged_journal_file))
    resp = client.get('/partials/jobs')
    assert resp.status_code == 200
    assert 'text/html' in resp.headers['content-type']
    assert 'j-2026-05-26-feature-flags' in resp.text


def test_jobs_detail_html(jobs_root: Path, tagged_journal_file: Path):
    client = TestClient(make_app(jobs_root, tagged_journal_file))
    resp = client.get('/jobs/j-2026-05-26-feature-flags')
    assert resp.status_code == 200
    assert 'feature flag system' in resp.text
    assert 'research → design' in resp.text   # phase-log
    assert 'release vs ops' in resp.text       # lesson


def test_jobs_detail_404(jobs_root: Path, tagged_journal_file: Path):
    client = TestClient(make_app(jobs_root, tagged_journal_file))
    resp = client.get('/jobs/j-nope')
    assert resp.status_code == 404
```

- [ ] **Step 2: Run to verify failure**

```powershell
python -m pytest dashboard/tests/test_jobs_router.py -v
```

Expected: `ImportError: cannot import name 'build_router'`.

- [ ] **Step 3: Implement `dashboard/routers/jobs.py`**

```python
from __future__ import annotations

from pathlib import Path

from fastapi import APIRouter, HTTPException, Request
from fastapi.responses import HTMLResponse
from fastapi.templating import Jinja2Templates

from dashboard.readers.jobs import list_job_summaries, read_job_detail


def build_router(templates: Jinja2Templates) -> APIRouter:
    """Constructor pattern so the router can share templates with the main app."""
    router = APIRouter()

    def _jobs_root(req: Request) -> Path:
        return getattr(
            req.app.state, 'jobs_root',
            Path.home() / '.claude' / 'jobs',
        )

    def _journal_path(req: Request) -> Path:
        return getattr(
            req.app.state, 'journal_path',
            Path.home() / '.claude' / 'model-routing-log.md',
        )

    @router.get('/partials/jobs', response_class=HTMLResponse)
    async def partial_jobs(request: Request) -> HTMLResponse:
        # Default filter shows active + recent done (last 10)
        active = list_job_summaries(_jobs_root(request), _journal_path(request), 'active')
        done = list_job_summaries(_jobs_root(request), _journal_path(request), 'done')[:10]
        return templates.TemplateResponse('partials/jobs_list.html', {
            'request': request,
            'active_jobs': active,
            'done_jobs': done,
        })

    @router.get('/jobs/{job_id}', response_class=HTMLResponse)
    async def job_detail(job_id: str, request: Request) -> HTMLResponse:
        try:
            detail = read_job_detail(_jobs_root(request), _journal_path(request), job_id)
        except FileNotFoundError:
            raise HTTPException(status_code=404, detail=f'no such job: {job_id}')
        return templates.TemplateResponse('job_detail.html', {
            'request': request,
            'detail': detail,
        })

    return router
```

- [ ] **Step 4: Templates required for tests to pass — drop minimal stubs**

The tests will fail with template-not-found until Task 16. Skip step 5 here and do it now via a stub: create barely-functional templates so tests pass, then flesh out in Task 16.

Create `dashboard/templates/partials/jobs_list.html`:

```html
<h2>Jobs</h2>
{% for j in active_jobs %}<div>{{ j.id }}</div>{% endfor %}
{% for j in done_jobs %}<div>{{ j.id }}</div>{% endfor %}
```

Create `dashboard/templates/job_detail.html`:

```html
<!DOCTYPE html>
<html><body>
<h1>{{ detail.summary.title }}</h1>
<pre>{{ detail.brief }}</pre>
{% for p in detail.phase_log %}<div>{{ p.detail }}</div>{% endfor %}
{% for l in detail.lessons %}<div>{{ l.text }}</div>{% endfor %}
</body></html>
```

- [ ] **Step 5: Run to verify pass**

```powershell
python -m pytest dashboard/tests/test_jobs_router.py -v
```

Expected: `3 passed`.

- [ ] **Step 6: Commit**

```powershell
git add dashboard/routers/jobs.py dashboard/tests/test_jobs_router.py dashboard/templates/partials/jobs_list.html dashboard/templates/job_detail.html
git commit -m "feat(plan3): jobs router + minimal templates (router tests green)"
```

---

## Task 16: Templates — polished Jobs panel + drill-in view

**Files:**
- Modify: `dashboard/templates/partials/jobs_list.html`
- Modify: `dashboard/templates/job_detail.html`
- Modify: `dashboard/templates/index.html`
- Modify: `dashboard/static/style.css` (small additions)

- [ ] **Step 1: Replace `dashboard/templates/partials/jobs_list.html` with the polished version**

```html
<h2>Jobs</h2>
{% if active_jobs %}
<table class="jobs-table">
  <thead>
    <tr><th>Job</th><th>Phase</th><th>Project</th><th>Cost</th><th>Started</th></tr>
  </thead>
  <tbody>
    {% for j in active_jobs %}
    <tr>
      <td><a href="/jobs/{{ j.id }}" class="job-link">🟢 {{ j.id }}</a></td>
      <td><code>{{ j.current_phase }}</code></td>
      <td>{{ j.project or '—' }}</td>
      <td class="cost">${{ '%.4f' | format(j.cost_usd) }}</td>
      <td>{{ j.created_at.strftime('%m-%d %H:%M') }}</td>
    </tr>
    {% endfor %}
  </tbody>
</table>
{% else %}
<p class="empty">No active jobs. Use <code>/job-start</code> in Claude Code to begin.</p>
{% endif %}

{% if done_jobs %}
<h3 class="recent-done">Recently completed</h3>
<table class="jobs-table dim">
  <tbody>
    {% for j in done_jobs %}
    <tr>
      <td><a href="/jobs/{{ j.id }}" class="job-link">⚫ {{ j.id }}</a></td>
      <td><code>{{ j.current_phase }}</code></td>
      <td>{{ j.project or '—' }}</td>
      <td class="cost">${{ '%.4f' | format(j.cost_usd) }}</td>
      <td>{{ j.created_at.strftime('%m-%d') }}</td>
    </tr>
    {% endfor %}
  </tbody>
</table>
{% endif %}
```

- [ ] **Step 2: Replace `dashboard/templates/job_detail.html` with the polished version**

```html
{% extends "base.html" %}
{% block title %}Job {{ detail.summary.id }}{% endblock %}
{% block content %}

<div class="card" style="grid-column: 1 / -1;">
  <h2>{{ detail.summary.title }}</h2>
  <div class="job-meta">
    <span><strong>ID:</strong> <code>{{ detail.summary.id }}</code></span>
    <span><strong>Phase:</strong> <code>{{ detail.summary.current_phase }}</code></span>
    <span><strong>Status:</strong> {{ detail.summary.status }}</span>
    <span><strong>Project:</strong> {{ detail.summary.project or '—' }}</span>
    <span><strong>Cost:</strong> ${{ '%.4f' | format(detail.summary.cost_usd) }}</span>
  </div>
</div>

<div class="card">
  <h2>Brief</h2>
  <pre class="brief-text">{{ detail.brief }}</pre>
</div>

<div class="card">
  <h2>Phase Timeline</h2>
  {% if detail.phase_log %}
  <ul class="phase-log">
    {% for p in detail.phase_log %}
    <li class="phase-{{ p.kind }}">
      <span class="ts">{{ p.timestamp.strftime('%m-%d %H:%M') }}</span>
      <span class="kind">{{ p.kind }}</span>
      <span class="detail">{{ p.detail }}</span>
      {% if p.note %}<span class="note">— {{ p.note }}</span>{% endif %}
    </li>
    {% endfor %}
  </ul>
  {% else %}
  <p class="empty">No transitions yet.</p>
  {% endif %}
</div>

<div class="card">
  <h2>Cost by Phase</h2>
  {% if detail.cost_by_phase %}
  <table class="phase-cost">
    {% for phase, cost in detail.cost_by_phase.items() %}
    <tr><td><code>{{ phase }}</code></td><td class="cost">${{ '%.4f' | format(cost) }}</td></tr>
    {% endfor %}
  </table>
  {% else %}
  <p class="empty">No OTel costs recorded for this job yet.</p>
  {% endif %}
</div>

<div class="card" style="grid-column: 1 / -1;">
  <h2>Lessons</h2>
  {% if detail.lessons %}
  <ul class="lessons-list">
    {% for l in detail.lessons %}
    <li>
      <span class="ts">{{ l.timestamp.strftime('%m-%d %H:%M') }}</span>
      <span class="cat">{{ l.category }}</span>
      {% if l.phase %}<span class="phase">[{{ l.phase }}]</span>{% endif %}
      <span class="text">{{ l.text }}</span>
    </li>
    {% endfor %}
  </ul>
  {% else %}
  <p class="empty">No lessons captured yet. Use <code>/job-lesson</code>.</p>
  {% endif %}
</div>

<div class="card" style="grid-column: 1 / -1;">
  <h2>Journal (this job)</h2>
  {% if detail.journal %}
  <div class="activity-scroll">
    {% for e in detail.journal %}
    <div class="activity-row">
      <span class="ts">{{ e.timestamp.strftime('%m-%d %H:%M:%S') }}</span>
      <span class="src">{{ e.__class__.__name__ | replace('Entry', '') | lower }}</span>
      <span class="cmd">
        {% if e.__class__.__name__ == 'HookEntry' %}{{ e.target }}{% if e.brief %} — "{{ e.brief }}"{% endif %}
        {% elif e.__class__.__name__ == 'OtelEntry' %}{{ e.model }} in:{{ e.input_tokens }} out:{{ e.output_tokens }} ${{ '%.4f' | format(e.cost_usd) }}
        {% elif e.__class__.__name__ == 'LessonEntry' %}{{ e.category }}: {{ e.text }}
        {% elif e.__class__.__name__ == 'NoteEntry' %}{{ e.target }}: {{ e.text }}{% endif %}
      </span>
      {% if e.phase %}<span class="phase-tag">{{ e.phase }}</span>{% endif %}
    </div>
    {% endfor %}
  </div>
  {% else %}
  <p class="empty">No journal entries tagged with this job yet.</p>
  {% endif %}
</div>

<p style="grid-column: 1 / -1; text-align: center; margin-top: 1rem;">
  <a href="/">← Back to dashboard</a>
</p>

{% endblock %}
```

- [ ] **Step 3: Add Jobs card to `dashboard/templates/index.html`**

Insert as the first `<div class="card …">` inside `{% block content %}` (above the existing Spend Today card):

```html
<!-- Jobs panel — polls every 30 s -->
<div class="card" style="grid-column: 1 / -1;"
     hx-get="/partials/jobs"
     hx-trigger="every 30s"
     hx-swap="innerHTML">
  {% include "partials/jobs_list.html" %}
</div>
```

- [ ] **Step 4: Append job-specific styles to `dashboard/static/style.css`**

```css
/* Plan 3: jobs panel & drill-in */
.jobs-table { width: 100%; border-collapse: collapse; font-size: 0.8rem; }
.jobs-table th { text-align: left; color: #8b949e; padding: 0.375rem 0.5rem 0.375rem 0;
                 border-bottom: 1px solid #30363d; font-weight: 500; }
.jobs-table td { padding: 0.375rem 0.5rem 0.375rem 0; border-bottom: 1px solid #21262d; }
.jobs-table.dim { opacity: 0.65; }
.jobs-table .cost { color: #3fb950; font-family: monospace; }
.job-link { color: #58a6ff; text-decoration: none; font-family: monospace; }
.job-link:hover { text-decoration: underline; }
.recent-done { font-size: 0.875rem; color: #8b949e; margin-top: 1rem; }

.job-meta { display: flex; flex-wrap: wrap; gap: 1rem; color: #8b949e; font-size: 0.85rem; }
.job-meta strong { color: #e6edf3; }

.brief-text { white-space: pre-wrap; background: #0d1117; padding: 0.75rem;
              border-radius: 4px; font-size: 0.85rem; }

.phase-log { list-style: none; padding: 0; margin: 0; font-family: monospace; font-size: 0.8rem; }
.phase-log li { padding: 0.25rem 0; border-bottom: 1px solid #21262d; display: grid;
                grid-template-columns: 100px 80px 1fr; gap: 0.5rem; }
.phase-log .ts { color: #8b949e; }
.phase-log .kind { color: #58a6ff; }
.phase-log .phase-loop-back .kind { color: #f0883e; }

.phase-cost { width: 100%; font-size: 0.85rem; }
.phase-cost td { padding: 0.25rem 0; border-bottom: 1px solid #21262d; }
.phase-cost td.cost { color: #3fb950; font-family: monospace; text-align: right; }

.lessons-list { list-style: none; padding: 0; margin: 0; font-size: 0.85rem; }
.lessons-list li { padding: 0.375rem 0; border-bottom: 1px solid #21262d;
                   display: grid; grid-template-columns: 100px 100px 1fr; gap: 0.5rem; }
.lessons-list .cat { color: #58a6ff; font-family: monospace; }
.lessons-list .phase { color: #8b949e; font-family: monospace; }

.phase-tag { color: #bc8cff; font-size: 0.7rem; margin-left: auto; }
```

- [ ] **Step 5: Run the dashboard test suite to make sure nothing broke**

```powershell
python -m pytest dashboard/tests/ -v
```

Expected: all green.

- [ ] **Step 6: Commit**

```powershell
git add dashboard/templates/ dashboard/static/style.css
git commit -m "feat(plan3): polished Jobs panel + drill-in templates + styles"
```

---

## Task 17: Wire `jobs_router` into `dashboard/main.py`

**Files:**
- Modify: `dashboard/main.py`
- Modify: `dashboard/tests/test_integration.py` (add jobs integration tests)

- [ ] **Step 1: Add failing integration tests**

Append to `dashboard/tests/test_integration.py`:

```python
def test_jobs_partial_via_main_app(client_with_jobs):
    resp = client_with_jobs.get('/partials/jobs')
    assert resp.status_code == 200
    assert 'j-2026-05-26-feature-flags' in resp.text


def test_jobs_detail_via_main_app(client_with_jobs):
    resp = client_with_jobs.get('/jobs/j-2026-05-26-feature-flags')
    assert resp.status_code == 200
    assert 'feature flag system' in resp.text


def test_index_includes_jobs_card(client_with_jobs):
    resp = client_with_jobs.get('/')
    assert resp.status_code == 200
    assert 'partials/jobs' in resp.text   # the hx-get URL of the jobs card
```

And add the fixture (likely also in `test_integration.py` near the existing `client` fixture):

```python
@pytest.fixture
def client_with_jobs(journal_file, tagged_journal_file, jobs_root, monkeypatch):
    import dashboard.main as main_module
    from dashboard.main import app
    monkeypatch.setattr(main_module, 'JOURNAL_PATH', tagged_journal_file)
    monkeypatch.setattr(main_module, 'JOBS_ROOT', jobs_root)
    app.state.journal_path = tagged_journal_file
    app.state.jobs_root = jobs_root
    return TestClient(app)
```

- [ ] **Step 2: Run to verify failure**

```powershell
python -m pytest dashboard/tests/test_integration.py -v
```

Expected: route 404 or `JOBS_ROOT` attribute missing.

- [ ] **Step 3: Modify `dashboard/main.py`**

Add near the top, after the existing `JOURNAL_PATH = …`:

```python
JOBS_ROOT = Path(
    os.environ.get('ROUTING_JOBS_ROOT', '')
    or Path.home() / '.claude' / 'jobs'
)
```

And in the app-construction block, after `app.state.journal_path = JOURNAL_PATH`:

```python
app.state.jobs_root = JOBS_ROOT
```

And after the existing `app.include_router(controls_router)`:

```python
from dashboard.routers.jobs import build_router as build_jobs_router
app.include_router(build_jobs_router(templates))
```

- [ ] **Step 4: Run to verify pass**

```powershell
python -m pytest dashboard/tests/ -v
```

Expected: all green (full suite).

- [ ] **Step 5: Commit**

```powershell
git add dashboard/main.py dashboard/tests/test_integration.py
git commit -m "feat(plan3): wire jobs router into main app + integration tests"
```

---

## Task 18: Bootstrap extensions (deploy commands, migrate routing.md, create dirs)

**Files:**
- Modify: `scripts/bootstrap.ps1`

- [ ] **Step 1: Add new bootstrap steps**

Locate the existing `# --- Step 5: Deploy slash commands ---` block. Modify the `foreach` list to include the new commands:

```powershell
foreach ($cmd in @(
    'log-routing.md','consolidate-routing.md',
    'job-start.md','job-status.md','job-list.md','job-phase.md',
    'job-resume.md','job-lesson.md','consolidate-lessons.md'
)) {
    $src = Join-Path $repoRoot "commands\$cmd"
    $dst = Join-Path $claudeDir "commands\$cmd"
    Copy-WithPrompt $src $dst "command: $cmd"
}
```

After the slash-commands block but BEFORE Step 6 (catalog/journal), insert these new steps:

```powershell
# --- Step 5b: Deploy Plan 3 library scripts ---
Write-Step "Deploying Plan 3 scripts"
$scriptsDst = Join-Path $claudeDir 'scripts'
if (-not (Test-Path $scriptsDst)) {
    if ($DryRun) { Write-Ok "[dry-run] would create $scriptsDst" }
    else { New-Item -ItemType Directory -Force -Path $scriptsDst | Out-Null; Write-Ok "created $scriptsDst" }
}
foreach ($script in @('job-lib.ps1', 'consolidate-lessons.ps1')) {
    $src = Join-Path $repoRoot "scripts\$script"
    $dst = Join-Path $scriptsDst $script
    Copy-WithPrompt $src $dst "lib script: $script"
}

# --- Step 5c: Create jobs + knowledge dirs ---
Write-Step "Creating jobs + knowledge directories"
$dirsToCreate = @(
    (Join-Path $claudeDir 'jobs'),
    (Join-Path $claudeDir 'knowledge/universal'),
    (Join-Path $claudeDir 'knowledge/universal/topics'),
    (Join-Path $claudeDir 'knowledge/projects')
)
foreach ($d in $dirsToCreate) {
    if (Test-Path $d) {
        Write-Skip "$d already exists"
    } elseif ($DryRun) {
        Write-Ok "[dry-run] would create $d"
    } else {
        New-Item -ItemType Directory -Force -Path $d | Out-Null
        Write-Ok "created $d"
    }
}

# Seed empty KB headers
$kbSeeds = @{
    'knowledge/universal/routing.md'     = "# Routing (universal)`n`nWhich model for what — populated by /consolidate-lessons.`n"
    'knowledge/universal/user-prefs.md'  = "# User Preferences (universal)`n"
    'knowledge/universal/reasoning.md'   = "# Reasoning Patterns (universal)`n"
    'knowledge/universal/mistakes.md'    = "# Mistake Patterns (universal — cross-project)`n"
    'knowledge/universal/winners.md'     = "# Winners (universal — cross-project)`n"
}
foreach ($rel in $kbSeeds.Keys) {
    $dst = Join-Path $claudeDir $rel
    if (Test-Path $dst) { Write-Skip "$rel already seeded"; continue }
    if ($DryRun) { Write-Ok "[dry-run] would seed $rel"; continue }
    Set-Content -Path $dst -Value $kbSeeds[$rel] -Encoding utf8
    Write-Ok "seeded $rel"
}

# --- Step 5d: Migrate Plan 1 model-routing.md → knowledge/universal/routing.md ---
Write-Step "Migrating model-routing.md → knowledge/universal/routing.md"
$oldRouting = Join-Path $claudeDir 'model-routing.md'
$newRouting = Join-Path $claudeDir 'knowledge/universal/routing.md'
if ((Test-Path $oldRouting) -and -not (Test-Path "$oldRouting.migrated")) {
    if ($DryRun) {
        Write-Ok "[dry-run] would migrate $oldRouting → $newRouting"
    } else {
        # If the new file is the empty seed, replace it with the old content.
        # Otherwise append the old content to preserve any updates already in the new file.
        $existing = Get-Content $newRouting -Raw -ErrorAction SilentlyContinue
        if ($existing -match 'populated by /consolidate-lessons') {
            Copy-Item $oldRouting $newRouting -Force
        } else {
            Add-Content -Path $newRouting -Value "`n# --- Migrated from model-routing.md ---`n"
            Add-Content -Path $newRouting -Value (Get-Content $oldRouting -Raw)
        }
        # Rename the source so re-running bootstrap is a no-op
        Rename-Item -Path $oldRouting -NewName 'model-routing.md.migrated'
        Write-Ok "migrated; original kept at $oldRouting.migrated"
    }
} else {
    Write-Skip "migration already done or no source file"
}
```

- [ ] **Step 2: Test the bootstrap with dry-run**

```powershell
pwsh -NoProfile -File scripts\bootstrap.ps1 -DryRun
```

Expected: each new step prints either `ok: [dry-run] would …` or `skip: …`. No errors.

- [ ] **Step 3: Run bootstrap for real (idempotent — safe even if you've already run Plan 1/2's version)**

```powershell
pwsh -NoProfile -File scripts\bootstrap.ps1
```

Expected: new dirs/scripts/commands created or skipped as already-present. Existing files preserved.

- [ ] **Step 4: Verify deployed state manually**

```powershell
Get-ChildItem $HOME\.claude\commands\job-*.md
Get-ChildItem $HOME\.claude\scripts\
Get-ChildItem $HOME\.claude\knowledge -Recurse
```

- [ ] **Step 5: Commit**

```powershell
git add scripts/bootstrap.ps1
git commit -m "feat(plan3): bootstrap — deploy new commands/scripts, create KB dirs, migrate routing.md"
```

---

## Task 19: README update + end-to-end smoke

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Append a Plan 3 section to `README.md`**

Add after the existing `## Coming in Plan 2` section (or replace it if Plan 2 is shipped, which it is):

```markdown
## What you get (Plan 3)

A persistent **job** model with phase tracking, lesson capture, and a knowledge
base — all surfacing in the dashboard.

- `~/.claude/jobs/<id>/` — per-job folders with manifest, brief, phase-log,
  lessons.
- `~/.claude/knowledge/` — two-layer KB (`universal/` + `projects/<id>/`)
  populated by `/job-lesson` capture and `/consolidate-lessons` rollup.
- Slash commands:
  - `/job-start "<brief>"` — open a new job, start phase tracking
  - `/job-status`, `/job-list` — see what's active / past
  - `/job-phase next|back|done|<name>` — advance, step back, or close
  - `/job-resume <id>` — continue a job after restarting Claude Code
  - `/job-lesson <category> "<text>"` — capture a lesson while you work
  - `/consolidate-lessons` — promote lessons into the KB
- Hook + `parse-otel.ps1` now tag every journal line with `job:` + `phase:`
  whenever a job is active.
- Dashboard adds a **Jobs panel** + drill-in route at `/jobs/<id>` with
  per-phase cost breakdown.

See [`docs/superpowers/specs/2026-05-26-plan3-job-scaffold-design.md`](docs/superpowers/specs/2026-05-26-plan3-job-scaffold-design.md).

## Coming in Plan 4

Fleet config (`~/.claude/fleet.yaml`) listing CLI providers and remote Ollama
hosts. Multi-machine local model access. Foundation for the research / code /
review phases (Plans 5-7) to actually dispatch work.
```

- [ ] **Step 2: End-to-end smoke (manual, eyeball)**

Run from a Claude Code session inside the repo:

```
/job-start "smoke test plan 3 wiring"
```

Verify:
- `~/.claude/jobs/j-<today>-smoke-test-plan-3-wiring/` exists with manifest + brief
- `~/.claude/current-job.json` has the job and phase
- Run a tool — `ls` via Bash. Check `~/.claude/model-routing-log.md` last line ends with `| job:j-… | phase:research`
- Open `http://localhost:8765` — Jobs panel shows the new job
- Click into it — drill-in shows brief, phase timeline (just `created`), empty lessons, $0 cost
- `/job-lesson knowledge "smoke test note"` — lesson appears in drill-in
- `/job-phase next` — phase flips to `design`, dashboard reflects within 30s
- `/job-phase done` — status flips, `current-job.json` removed
- `/consolidate-lessons` — `~/.claude/knowledge/projects/coding-agent-orchestrator/topics/general.md` contains the lesson

- [ ] **Step 3: Run the full suite one last time**

```powershell
pwsh -NoProfile -File scripts\test-job-lib.ps1
pwsh -NoProfile -File scripts\test-jobs.ps1
pwsh -NoProfile -File scripts\test-hook.ps1
pwsh -NoProfile -File scripts\test-otel-parser.ps1
pwsh -NoProfile -File scripts\test-consolidate-lessons.ps1
python -m pytest dashboard/tests/ -v --tb=short
```

Expected: every script ends with `All tests passed.` (PS) or `passed` (pytest). No failures.

- [ ] **Step 4: Commit + tag**

```powershell
git add README.md
git commit -m "docs: Plan 3 README — job scaffold, KB, dashboard Jobs panel"
git tag plan3-complete -m "Plan 3: job scaffold + KB foundation"
```

---

## End of plan
