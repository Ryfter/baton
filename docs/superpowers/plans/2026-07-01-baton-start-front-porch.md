# /baton:start Front Porch (slice 1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship `/baton:start` (+ `/baton:init`, `/baton:initialize` aliases) — a guided, teaching, user-adaptive entry point that starts a new project or resumes an existing one, captures the user's goal and reasoning in a plain-language `CHARTER.md`, and hands off to `/baton:go` full-auto.

**Architecture:** One pure-function library (`scripts/start-lib.ps1`) holding all decision logic (mode/depth/teaching-level resolvers, CHARTER templating, next-command recommendation) plus thin, seamed I/O wrappers for two new box-private JSON stores (`project.json` per project, one `user-profile.json`). One markdown command (`commands/start.md`) is the brain that calls the lib and drives `/baton:go`; `commands/init.md` and `commands/initialize.md` are 3-line delegators pointing at it. Follows the exact house pattern of `job-lib.ps1` / `job-start.md`.

**Tech Stack:** PowerShell 7 (`pwsh`), Claude Code slash-command markdown files, existing `job-lib.ps1` (`Get-BatonHome`, `Resolve-ProjectId`, `ConvertTo-JobSlug`) and `fleet-go.ps1` (the `/baton:go` engine).

## Global Constraints

- **Box-private:** `project.json` and `user-profile.json` live under `$BATON_HOME`; never the knowledge repo or any shared seed. `CHARTER.md` is the exception — it is the user's own doc, written into *their* project folder.
- **965-byte shell-arg limit:** never pass long goal/reasoning/CHARTER text as an inline PowerShell string argument on the command line. Write it via `Set-Content`/`Add-Content` from a variable populated in-process, or via a temp file when composing from the command layer — never as a literal on a shell invocation line over ~900 bytes.
- **`utf8NoBOM`** encoding for every file this feature writes (`project.json`, `user-profile.json`, `CHARTER.md`).
- **PowerShell automatic-variable trap:** never name a param or local `$args`, `$input`, `$event`, `$matches`, or `$host`. Reading the automatic `$Matches` after a `-match` operator is fine and used below.
- **Parenthesize function calls used inside comparisons** (e.g. `if ((Test-LessonCategory 'x')) { ... }`).
- **Unary-comma array return convention:** a function returning a possibly-multi-row array uses `return ,@($x)` for non-empty and `return @()` for empty, and callers must **not** re-wrap the returned value in `@()` on direct assignment. (Not exercised by this plan's functions — none return arrays of rows — but obey it if a future edit changes that.)
- **`Write-Error` throws under `$ErrorActionPreference='Stop'`:** this plan's lib functions never set that preference and never call `Write-Error` for expected empty/absent states — a missing file returns `$null`, not a throw.
- **Tests never touch real `$BATON_HOME` or `~/.claude`:** every test uses a temp directory and passes explicit path parameters (`-ProjectsRoot`, `-ProfilePath`) — never the defaults.
- **Decision capture:** genuine onboarding decisions (e.g. adopting an existing folder as a Baton project) are captured via `Add-DecisionRecordFromFile` per `CLAUDE.md`'s decision-capture rule — this is a runtime behavior documented in the command file, not something a unit test can verify; Task 4 documents it, it is not code-tested.

---

## File Structure

| File | Responsibility |
| --- | --- |
| `scripts/start-lib.ps1` | All decision logic + I/O for the front-porch feature: mode/depth/teaching resolvers, CHARTER templating, resume-status formatting, next-command recommendation, and the two JSON stores. |
| `scripts/test-start-lib.ps1` | Hermetic unit tests for every function in `start-lib.ps1`. |
| `commands/start.md` | The command brain: parses `$ARGUMENTS`, resolves project state, drives onboarding or resume, calls `fleet-go.ps1`, narrates. |
| `commands/init.md` | Delegator: "this is `/baton:start`, run its procedure." |
| `commands/initialize.md` | Delegator: same as above. |
| `scripts/bootstrap.ps1` | Modified: deploy `start-lib.ps1` (Step 5b list) — command files ship via the plugin install, not bootstrap's flat-copy list. |
| `scripts/test-bootstrap.ps1` | Modified: assert `start-lib.ps1` is in the dry-run deploy list. |
| `.claude-plugin/plugin.json` | Modified: version bump. |
| `docs/COMMANDS.md` | Modified: document `/baton:start` (+ aliases) as the recommended entry point, in a new top section. |
| `docs/getting-started.md` | Modified: point step "1. Open a project" at `/baton:start` as the recommended on-ramp, keeping `/baton:job-start` documented as the manual alternative. |

---

## Task 1: `start-lib.ps1` — pure resolvers

**Files:**
- Create: `scripts/start-lib.ps1`
- Test: `scripts/test-start-lib.ps1`

**Interfaces:**
- Consumes: nothing (pure functions, no dot-sourcing of other libs needed for this task).
- Produces:
  - `Resolve-StartMode -ProjectRecord <object|$null>` → `[string]` `'new'` or `'resume'`.
  - `Resolve-InterviewDepth -Profile <object|$null> -Explicit <string>` → `[string]` one of `'light'`, `'adaptive'`, `'full'`.
  - `Resolve-TeachingLevel -Profile <object|$null> -Explicit <string>` → `[string]` one of `'teach'`, `'quiet'`.
  - `Get-NextCommandRecommendation -RunStatus <string>` → `[hashtable]` `@{ command = '<string>'; why = '<string>' }`.

These four are used later by Task 3 (CHARTER/status) and Task 4 (the command file), but they have zero dependency on Task 2's I/O — build and test them standalone first.

- [ ] **Step 1: Write the failing tests for the resolvers**

Create `scripts/test-start-lib.ps1` with this header and the resolver assertions (more sections are appended in later tasks — do not add a `Remove-Item`/cleanup footer yet, later tasks append more `=== ... ===` blocks to this same file):

```powershell
#!/usr/bin/env pwsh
# Unit-style tests for start-lib.ps1 functions.
# Each section dot-sources the lib and runs assertions; throws on failure.

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'start-lib.ps1')

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

function Assert-True($cond, $msg) {
    if (-not $cond) { throw "FAIL: $msg" }
}

# --- Resolve-StartMode ---
Write-Host "=== Resolve-StartMode ===" -ForegroundColor Cyan
Assert-Equal 'new'    (Resolve-StartMode -ProjectRecord $null) 'no record -> new'
Assert-Equal 'resume' (Resolve-StartMode -ProjectRecord @{ id = 'acme-api' }) 'record present -> resume'

# --- Resolve-InterviewDepth ---
Write-Host "=== Resolve-InterviewDepth ===" -ForegroundColor Cyan
Assert-Equal 'full' (Resolve-InterviewDepth -Profile $null -Explicit $null) 'no profile, no explicit -> full (new/unknown user)'
Assert-Equal 'adaptive' (Resolve-InterviewDepth -Profile @{ preferred_interview_depth = $null } -Explicit $null) 'profile present but depth unset -> adaptive'
Assert-Equal 'light' (Resolve-InterviewDepth -Profile @{ preferred_interview_depth = 'light' } -Explicit $null) 'profile says light -> light'
Assert-Equal 'full' (Resolve-InterviewDepth -Profile @{ preferred_interview_depth = 'light' } -Explicit 'full') 'explicit overrides profile'

# --- Resolve-TeachingLevel ---
Write-Host "=== Resolve-TeachingLevel ===" -ForegroundColor Cyan
Assert-Equal 'teach' (Resolve-TeachingLevel -Profile $null -Explicit $null) 'no profile, no explicit -> teach (default)'
Assert-Equal 'quiet' (Resolve-TeachingLevel -Profile @{ teaching_level = 'quiet' } -Explicit $null) 'profile says quiet -> quiet'
Assert-Equal 'quiet' (Resolve-TeachingLevel -Profile @{ teaching_level = 'teach' } -Explicit 'quiet') 'explicit overrides profile'

# --- Get-NextCommandRecommendation ---
Write-Host "=== Get-NextCommandRecommendation ===" -ForegroundColor Cyan
$rec = Get-NextCommandRecommendation -RunStatus 'completed'
Assert-True ($rec.command -match '/baton:(gate|effective-cost)') 'completed -> recommends gate or effective-cost'
Assert-True (-not [string]::IsNullOrWhiteSpace($rec.why)) 'completed -> has a why'

$rec = Get-NextCommandRecommendation -RunStatus 'interrupted-budget'
Assert-True ($rec.command -match '--budget') 'interrupted-budget -> recommends raising --budget'
Assert-True (-not [string]::IsNullOrWhiteSpace($rec.why)) 'interrupted-budget -> has a why'

$rec = Get-NextCommandRecommendation -RunStatus 'interrupted-destructive'
Assert-True (-not [string]::IsNullOrWhiteSpace($rec.command)) 'interrupted-destructive -> has a command'
Assert-True (-not [string]::IsNullOrWhiteSpace($rec.why)) 'interrupted-destructive -> has a why'

$rec = Get-NextCommandRecommendation -RunStatus 'rejected'
Assert-True ($rec.command -match '/baton:gate') 'rejected -> recommends /baton:gate'
Assert-True (-not [string]::IsNullOrWhiteSpace($rec.why)) 'rejected -> has a why'

foreach ($failStatus in @('failed', 'plan-failed', 'plan-invalid')) {
    $rec = Get-NextCommandRecommendation -RunStatus $failStatus
    Assert-True (-not [string]::IsNullOrWhiteSpace($rec.command)) "$failStatus -> has a command"
    Assert-True (-not [string]::IsNullOrWhiteSpace($rec.why)) "$failStatus -> has a why"
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pwsh -NoProfile -File scripts/test-start-lib.ps1`
Expected: FAIL — `start-lib.ps1` does not exist yet (file-not-found error dot-sourcing it).

- [ ] **Step 3: Write the minimal implementation**

Create `scripts/start-lib.ps1`:

```powershell
#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Shared PowerShell library for the /baton:start front porch (slice 1).
  Dot-source from the start/init/initialize command scripts.

.DESCRIPTION
  Pure resolvers (mode/depth/teaching-level, CHARTER content, resume status,
  next-command recommendation) plus thin seamed I/O for two box-private
  JSON stores: per-project project.json and one user-profile.json.
#>

. "$PSScriptRoot/baton-home.ps1"

function Resolve-StartMode {
    param([object]$ProjectRecord)
    if ($null -eq $ProjectRecord) { return 'new' }
    return 'resume'
}

function Resolve-InterviewDepth {
    param(
        [object]$Profile,
        [string]$Explicit
    )
    if (-not [string]::IsNullOrWhiteSpace($Explicit)) { return $Explicit }
    if ($null -eq $Profile) { return 'full' }
    if (-not [string]::IsNullOrWhiteSpace($Profile.preferred_interview_depth)) {
        return $Profile.preferred_interview_depth
    }
    return 'adaptive'
}

function Resolve-TeachingLevel {
    param(
        [object]$Profile,
        [string]$Explicit
    )
    if (-not [string]::IsNullOrWhiteSpace($Explicit)) { return $Explicit }
    if ($null -eq $Profile) { return 'teach' }
    if (-not [string]::IsNullOrWhiteSpace($Profile.teaching_level)) {
        return $Profile.teaching_level
    }
    return 'teach'
}

$script:NextCommandMap = @{
    'completed' = @{
        command = '/baton:gate (review quality) or /baton:effective-cost (see spend)'
        why     = 'the run finished — checking quality or cost is the natural next step before starting something new'
    }
    'interrupted-budget' = @{
        command = 're-run /baton:start (or /baton:go) with a higher --budget'
        why     = 'the next task would cross the budget cap you set, so it paused rather than spend past it'
    }
    'interrupted-destructive' = @{
        command = 'approve the pending step, then resume'
        why     = 'the next task touches something hard to undo (master, a force-push, an external publish), so it paused for your OK'
    }
    'rejected' = @{
        command = '/baton:gate to see the findings, then re-run'
        why     = 'the acceptance gate reviewed the finished work and flagged it — the work still ran, this is a quality verdict'
    }
    'failed' = @{
        command = 'sharpen the goal and retry /baton:start'
        why     = 'a task could not complete — a clearer or narrower goal usually unblocks it'
    }
    'plan-failed' = @{
        command = 'sharpen the goal and retry /baton:start'
        why     = 'planning could not produce a usable set of steps from the goal as stated'
    }
    'plan-invalid' = @{
        command = 'sharpen the goal and retry /baton:start'
        why     = 'planning produced a set of steps that did not check out — a sharper goal usually fixes this'
    }
}

function Get-NextCommandRecommendation {
    param([Parameter(Mandatory)][string]$RunStatus)
    if ($script:NextCommandMap.ContainsKey($RunStatus)) {
        return $script:NextCommandMap[$RunStatus]
    }
    return @{ command = '/baton:start'; why = 'status not recognized — starting fresh is the safest next step' }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pwsh -NoProfile -File scripts/test-start-lib.ps1`
Expected: all `=== ... ===` sections print PASS-equivalent (no thrown `FAIL:` lines), exit code 0.

- [ ] **Step 5: Commit**

```bash
git add scripts/start-lib.ps1 scripts/test-start-lib.ps1
git commit -m "feat(start): pure resolvers for /baton:start mode, interview depth, teaching level, next-command"
```

---

## Task 2: `start-lib.ps1` — project record + user profile stores

**Files:**
- Modify: `scripts/start-lib.ps1`
- Modify: `scripts/test-start-lib.ps1` (append a new section)

**Interfaces:**
- Consumes: `Get-BatonHome` (from `baton-home.ps1`, already dot-sourced in Task 1).
- Produces:
  - `Read-ProjectRecord -ProjectId <string> -ProjectsRoot <string>` → `[object]` (a `PSCustomObject` from `ConvertFrom-Json`) or `$null` if the file doesn't exist or is corrupt.
  - `Write-ProjectRecord -Record <hashtable> -ProjectsRoot <string>` → `[void]`. `$Record` must contain `id`. Writes `<ProjectsRoot>/<id>/project.json`, creating parent directories as needed, `utf8NoBOM`.
  - `Read-UserProfile -ProfilePath <string>` → `[object]` or `$null` if the file doesn't exist or is corrupt.
  - `Write-UserProfile -Profile <hashtable> -ProfilePath <string>` → `[void]`. Writes the file, creating the parent directory as needed, `utf8NoBOM`.

Default path parameters resolve from `Get-BatonHome` (`<BATON_HOME>/projects` and `<BATON_HOME>/user-profile.json`) but every test call passes an explicit temp path — never exercise the defaults in tests, per the Global Constraints.

- [ ] **Step 1: Write the failing tests**

Append to `scripts/test-start-lib.ps1` (after the Task 1 sections, before any prior cleanup — there is none yet):

```powershell
# --- Project record R/W ---
Write-Host "=== Project record R/W ===" -ForegroundColor Cyan
$projRoot = Join-Path $env:TEMP "cao-start-proj-$(Get-Random)"

# Read when missing -> $null, no throw
$rec = Read-ProjectRecord -ProjectId 'acme-api' -ProjectsRoot $projRoot
Assert-Null $rec 'missing project record: read returns null'

# Write then read
$now = (Get-Date -Format 'yyyy-MM-ddTHH:mm:sszzz')
Write-ProjectRecord -ProjectsRoot $projRoot -Record @{
    id = 'acme-api'; name = 'Acme API'; folder = 'D:/Dev/acme-api'
    charter_path = 'D:/Dev/acme-api/CHARTER.md'
    created_at = $now; last_updated = $now; last_run = $null
}
$rec = Read-ProjectRecord -ProjectId 'acme-api' -ProjectsRoot $projRoot
Assert-Equal 'acme-api'  $rec.id     'project record: id round-trips'
Assert-Equal 'Acme API'  $rec.name   'project record: name round-trips'
Assert-Equal 'D:/Dev/acme-api' $rec.folder 'project record: folder round-trips'

# Corrupted file -> read returns null, no throw
$corruptDir = Join-Path $projRoot 'broken-proj'
New-Item -ItemType Directory -Path $corruptDir -Force | Out-Null
Set-Content -Path (Join-Path $corruptDir 'project.json') -Value '{ not json' -Encoding utf8NoBOM
$rec = Read-ProjectRecord -ProjectId 'broken-proj' -ProjectsRoot $projRoot
Assert-Null $rec 'corrupted project record: read returns null'

Remove-Item $projRoot -Recurse -Force

# --- User profile R/W ---
Write-Host "=== User profile R/W ===" -ForegroundColor Cyan
$profTmp = Join-Path $env:TEMP "cao-start-profile-$(Get-Random)"
$profilePath = Join-Path $profTmp 'user-profile.json'

# Read when missing -> $null, no throw
$prof = Read-UserProfile -ProfilePath $profilePath
Assert-Null $prof 'missing user profile: read returns null'

# Write then read
Write-UserProfile -ProfilePath $profilePath -Profile @{
    preferred_interview_depth = 'light'; teaching_level = 'teach'; updated_at = $now
}
$prof = Read-UserProfile -ProfilePath $profilePath
Assert-Equal 'light' $prof.preferred_interview_depth 'user profile: depth round-trips'
Assert-Equal 'teach' $prof.teaching_level             'user profile: teaching_level round-trips'

Remove-Item $profTmp -Recurse -Force
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pwsh -NoProfile -File scripts/test-start-lib.ps1`
Expected: FAIL — `Read-ProjectRecord`/`Write-ProjectRecord`/`Read-UserProfile`/`Write-UserProfile` are not recognized commands.

- [ ] **Step 3: Write the minimal implementation**

Append to `scripts/start-lib.ps1` (after `Get-NextCommandRecommendation`):

```powershell
function Read-ProjectRecord {
    param(
        [Parameter(Mandatory)][string]$ProjectId,
        [string]$ProjectsRoot = (Join-Path (Get-BatonHome) 'projects')
    )
    $path = Join-Path (Join-Path $ProjectsRoot $ProjectId) 'project.json'
    if (-not (Test-Path $path)) { return $null }
    try {
        $raw = Get-Content $path -Raw -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
        return ($raw | ConvertFrom-Json -ErrorAction Stop)
    } catch {
        Write-Debug "Read-ProjectRecord: $($_.Exception.Message)"
        return $null
    }
}

function Write-ProjectRecord {
    param(
        [Parameter(Mandatory)][hashtable]$Record,
        [string]$ProjectsRoot = (Join-Path (Get-BatonHome) 'projects')
    )
    $dir = Join-Path $ProjectsRoot $Record.id
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $path = Join-Path $dir 'project.json'
    $Record | ConvertTo-Json -Depth 6 | Set-Content -Path $path -Encoding utf8NoBOM
}

function Read-UserProfile {
    param([string]$ProfilePath = (Join-Path (Get-BatonHome) 'user-profile.json'))
    if (-not (Test-Path $ProfilePath)) { return $null }
    try {
        $raw = Get-Content $ProfilePath -Raw -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
        return ($raw | ConvertFrom-Json -ErrorAction Stop)
    } catch {
        Write-Debug "Read-UserProfile: $($_.Exception.Message)"
        return $null
    }
}

function Write-UserProfile {
    param(
        [Parameter(Mandatory)][hashtable]$Profile,
        [string]$ProfilePath = (Join-Path (Get-BatonHome) 'user-profile.json')
    )
    $dir = Split-Path -Parent $ProfilePath
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $Profile | ConvertTo-Json -Depth 6 | Set-Content -Path $ProfilePath -Encoding utf8NoBOM
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pwsh -NoProfile -File scripts/test-start-lib.ps1`
Expected: all sections pass, exit code 0.

- [ ] **Step 5: Commit**

```bash
git add scripts/start-lib.ps1 scripts/test-start-lib.ps1
git commit -m "feat(start): project.json and user-profile.json seamed R/W stores"
```

---

## Task 3: `start-lib.ps1` — CHARTER content + resume status

**Files:**
- Modify: `scripts/start-lib.ps1`
- Modify: `scripts/test-start-lib.ps1` (append a new section)

**Interfaces:**
- Consumes: nothing new (pure string templating).
- Produces:
  - `New-CharterContent -Name <string> -Goal <string> -Audience <string> -Done <string> -Reasoning <string>` → `[string]` full CHARTER markdown. `Audience`, `Done`, `Reasoning` may be empty/`$null`; each renders its section body as the literal line `(to be filled in)` when empty, never a blank line.
  - `Format-ResumeStatus -ProjectRecord <object>` → `[string]` a one-paragraph, plain-language status line combining name, folder, and a human-readable rendering of `last_run.status` (or "hasn't run yet" if `last_run` is `$null`).

- [ ] **Step 1: Write the failing tests**

Append to `scripts/test-start-lib.ps1`:

```powershell
# --- New-CharterContent ---
Write-Host "=== New-CharterContent ===" -ForegroundColor Cyan
$charter = New-CharterContent -Name 'Acme API' -Goal 'A backend for the Acme mobile app' `
    -Audience 'Acme mobile team' -Done 'Endpoints match the mobile app spec and pass its test suite' `
    -Reasoning 'Existing backend is unmaintained; a clean rebuild is faster than patching it.'
Assert-True ($charter -match 'Acme API')                                   'charter: name present'
Assert-True ($charter -match 'A backend for the Acme mobile app')          'charter: goal present'
Assert-True ($charter -match 'Acme mobile team')                          'charter: audience present'
Assert-True ($charter -match 'Endpoints match the mobile app spec')       'charter: done present'
Assert-True ($charter -match 'clean rebuild is faster')                   'charter: reasoning present'

$minimal = New-CharterContent -Name 'Solo Tool' -Goal 'A CLI to rename files' -Audience $null -Done $null -Reasoning $null
Assert-True ($minimal -match '\(to be filled in\)') 'charter: empty optional sections render placeholder line'
Assert-True ($minimal -notmatch "`n`n`n")            'charter: no triple-blank-line from empty sections'

# --- Format-ResumeStatus ---
Write-Host "=== Format-ResumeStatus ===" -ForegroundColor Cyan
$noRun = Format-ResumeStatus -ProjectRecord @{ name = 'Acme API'; folder = 'D:/Dev/acme-api'; last_run = $null }
Assert-True ($noRun -match 'Acme API')          'resume status: name present, no prior run'
Assert-True ($noRun -match 'D:/Dev/acme-api')   'resume status: folder present, no prior run'
Assert-True ($noRun -match "hasn't run|has not run|no runs yet") 'resume status: says no prior run'

$withRun = Format-ResumeStatus -ProjectRecord @{
    name = 'Acme API'; folder = 'D:/Dev/acme-api'
    last_run = @{ run_id = 'run-2026-07-01-abc'; status = 'interrupted-budget'; at = '2026-07-01T09:20:00-06:00' }
}
Assert-True ($withRun -match 'Acme API')            'resume status: name present, with prior run'
Assert-True ($withRun -match 'interrupted-budget|budget') 'resume status: reflects last run status'
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pwsh -NoProfile -File scripts/test-start-lib.ps1`
Expected: FAIL — `New-CharterContent`/`Format-ResumeStatus` not recognized.

- [ ] **Step 3: Write the minimal implementation**

Append to `scripts/start-lib.ps1`:

```powershell
function New-CharterContent {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Goal,
        [string]$Audience,
        [string]$Done,
        [string]$Reasoning
    )
    $today = Get-Date -Format 'yyyy-MM-dd'
    $audienceText  = if ([string]::IsNullOrWhiteSpace($Audience))  { '(to be filled in)' } else { $Audience }
    $doneText      = if ([string]::IsNullOrWhiteSpace($Done))      { '(to be filled in)' } else { $Done }
    $reasoningText = if ([string]::IsNullOrWhiteSpace($Reasoning)) { '(to be filled in)' } else { $Reasoning }

    @"
# $Name — Project Charter

_Written by /baton:start on $today. Your plain-language record of what we're building and why._

## What we're building
$Goal

## Who it's for
$audienceText

## What "done" looks like
$doneText

## Why — the reasoning
$reasoningText

## Decisions & open questions
(to be filled in as the project moves along)

---
_Baton tracks the technical run history privately under its own home; this file is yours._
"@
}

function Format-ResumeStatus {
    param([Parameter(Mandatory)][object]$ProjectRecord)
    $name = $ProjectRecord.name
    $folder = $ProjectRecord.folder
    if ($null -eq $ProjectRecord.last_run) {
        return "Project '$name' at $folder hasn't run yet — pick up where onboarding left off, or describe what to build."
    }
    $status = $ProjectRecord.last_run.status
    $at = $ProjectRecord.last_run.at
    return "Project '$name' at $folder — last run ($at) ended with status '$status'."
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pwsh -NoProfile -File scripts/test-start-lib.ps1`
Expected: all sections pass, exit code 0.

- [ ] **Step 5: Commit**

```bash
git add scripts/start-lib.ps1 scripts/test-start-lib.ps1
git commit -m "feat(start): CHARTER.md templating and plain-language resume status"
```

---

## Task 4: `commands/start.md` — the brain

**Files:**
- Create: `commands/start.md`
- Create: `commands/init.md`
- Create: `commands/initialize.md`

**Interfaces:**
- Consumes (from `start-lib.ps1`, Tasks 1-3):
  `Resolve-StartMode`, `Resolve-InterviewDepth`, `Resolve-TeachingLevel`,
  `Get-NextCommandRecommendation`, `Read-ProjectRecord`, `Write-ProjectRecord`,
  `Read-UserProfile`, `Write-UserProfile`, `New-CharterContent`, `Format-ResumeStatus`.
  Also consumes `Get-BatonHome`, `Resolve-ProjectId`, `ConvertTo-JobSlug` from `job-lib.ps1`
  (already deployed — see `scripts/job-lib.ps1:15,55,68`), and drives `scripts/fleet-go.ps1`
  exactly as `commands/go.md` does (see `commands/go.md:16-46` for the reference contract:
  `-Goal`, `-Budget`, `-MaxCostTier`, `-Json`, and reading back `status`/`run_dir`/`spend`/`pending_task_id`).
- Produces: nothing new — this is the terminal orchestration layer for slice 1.

This task is markdown-command authoring, not PowerShell unit-testable; it is validated per Step 4 below (manual dry runs) rather than an automated test file, matching how `commands/go.md` and `commands/job-start.md` are validated (no `test-go.md`/`test-job-start.md` exist in this repo — command files are prose+inlined-PowerShell prompts, not scripts with their own test harness).

- [ ] **Step 1: Write `commands/start.md`**

```markdown
---
description: The front porch — start a new project or resume one, guided in plain language, then run it full-auto via /baton:go. Aliases: /baton:init, /baton:initialize.
argument-hint: ["<name>"] [--folder <path>] [--goal "<text>"] [--budget <n>] [--max-tier local|free|paid] [--depth light|adaptive|full] [--quiet]
---

# /baton:start

You are the **Front Porch**. This is the one command someone types to begin or
resume a project — including someone who does not know what git is or how to
code. Your job: figure out what they want (in plain language, at a depth that
fits them), set up the mechanics *for* them while explaining each step, write
down their reasoning, then drive `/baton:go` full-auto and tell them what
happens next, and why.

## Steps

1. **Parse `$ARGUMENTS`.** Optional leading quoted **name**. Flags:
   `--folder <path>`, `--goal "<text>"`, `--budget <n>`,
   `--max-tier local|free|paid`, `--depth light|adaptive|full`, `--quiet`
   (forces teaching level to `quiet`). Anything not supplied is asked for (new
   path) or inferred (resume path).

2. **Resolve the project + load state:**

   ```powershell
   . "$HOME/.claude/scripts/job-lib.ps1"
   . "$HOME/.claude/scripts/start-lib.ps1"

   $name = '<NAME_OR_EMPTY>'
   $folderFlag = '<FOLDER_FLAG_OR_EMPTY>'
   $targetFolder = if ($folderFlag) { $folderFlag } else { (Get-Location).Path }

   $projectId = if ($name) { ConvertTo-JobSlug $name } else { Resolve-ProjectId -Override $null }
   $projRecord = Read-ProjectRecord -ProjectId $projectId
   $profile = Read-UserProfile
   $mode = Resolve-StartMode -ProjectRecord $projRecord
   $teachLevel = Resolve-TeachingLevel -Profile $profile -Explicit '<QUIET_FLAG_OR_EMPTY>'
   ```

3. **Resume path** (`$mode -eq 'resume'`):
   - Print `Format-ResumeStatus -ProjectRecord $projRecord` in plain language.
   - Compute `Get-NextCommandRecommendation -RunStatus $projRecord.last_run.status`
     (skip if `last_run` is `$null`) and surface it — in `teach` mode, include the
     `why`; in `quiet` mode, just the `command`.
   - Ask: *"Resume with a new outcome, or pick up the recommended next step?"*
     Wait for the answer, then either go to step 6 with a new goal, or hand off
     to the recommended command directly (do not re-run onboarding).

4. **New path onboarding** (`$mode -eq 'new'`):
   - `$depth = Resolve-InterviewDepth -Profile $profile -Explicit '<DEPTH_FLAG_OR_EMPTY>'`
   - Run the guided interview at that depth (always in plain language, never
     assuming the user knows jargon):
     - **All depths:** "What are you trying to make?" → `$goal`. If `--goal` was
       already supplied on the command line, skip asking and confirm it back to
       the user instead.
     - **`adaptive` and `full`:** also ask "Who is it for?" → `$audience`, and
       "How will we know it's working, or done?" → `$done`.
     - **`light`:** skip audience/done unless the user volunteers them; still
       offer a proactive suggestion if the goal is vague (e.g. "Want me to also
       ask who this is for, or just dive in?").
     - **All depths:** ask "Where should this live?" → `$targetFolder` (default
       to the flag/cwd from step 2 if the user has no preference; if they have
       no idea at all, recommend a sensible default under a projects directory
       and explain why).
     - Capture the user's own words on *why* they want this as `$reasoning` —
       this is the CHARTER's "Why" section; do not paraphrase away specifics.

5. **Folder — detect & branch, narrated (`teach` mode explains each line):**
   - If `$targetFolder` exists and is already a git repo → adopt it as-is.
   - If it exists and is **not** a git repo → explain ("git saves snapshots of
     your work so nothing is ever lost, and lets us go back a step if needed"),
     then `git init` inside it.
   - If it does not exist → create it, `git init` it, and seed it: write
     `CHARTER.md` (below), a minimal `.gitignore`, and a stub `README.md` with
     just the project name as an H1. Narrate each of these three files in one
     sentence each.
   - **Decision capture:** if adopting an *existing* non-empty folder as a Baton
     project was a genuine judgment call (i.e. there was a real alternative —
     e.g. the user considered starting fresh instead), capture it via the
     file-based decision intake per `CLAUDE.md`'s decision-capture rule. Skip
     for the routine "empty new folder" case — that's not a decision with
     alternatives.

6. **Write the CHARTER + register the project.** Because goal/reasoning text
   can be long, build the CHARTER string in-process and write it directly —
   never pass long text as an inline shell argument (965-byte limit):

   ```powershell
   $charterPath = Join-Path $targetFolder 'CHARTER.md'
   $charterText = New-CharterContent -Name $name -Goal $goal -Audience $audience -Done $done -Reasoning $reasoning
   Set-Content -Path $charterPath -Value $charterText -Encoding utf8NoBOM

   $now = Get-Date -Format 'yyyy-MM-ddTHH:mm:sszzz'
   Write-ProjectRecord -Record @{
       id = $projectId; name = $name; folder = $targetFolder
       charter_path = $charterPath; created_at = $now; last_updated = $now
       last_run = $null
   }

   # Best-effort supplement to Grimdex/memory if present — never required.
   # If a Grimdex project tier exists for this project, or auto-memory is
   # active in this session, record the captured reasoning there too.
   ```

   In `teach` mode, explain: *"I wrote your reasoning to CHARTER.md in your
   project folder — that's yours to read and edit any time."*

7. **Hand off to `/baton:go` full-auto:**

   ```powershell
   pwsh -NoProfile -File "$HOME/.claude/scripts/fleet-go.ps1" -Goal "<goal from step 4/6>" -Json
   # add -Budget <n> when --budget was supplied
   # add -MaxCostTier <tier> when --max-tier was supplied
   ```

   Before running, tell the user (teach mode adds the *why*): *"Now driving
   /baton:go — I'll only stop for a budget limit or an irreversible action."*

8. **Read the result and update state:**

   ```powershell
   # $result = the parsed JSON from step 7
   $rec = Read-ProjectRecord -ProjectId $projectId
   $recHash = @{
       id = $rec.id; name = $rec.name; folder = $rec.folder; charter_path = $rec.charter_path
       created_at = $rec.created_at; last_updated = (Get-Date -Format 'yyyy-MM-ddTHH:mm:sszzz')
       last_run = @{ run_id = (Split-Path -Leaf $result.run_dir); status = $result.status; at = (Get-Date -Format 'yyyy-MM-ddTHH:mm:sszzz') }
   }
   Write-ProjectRecord -Record $recHash
   ```

   Narrate the run terse-one-liner style from `<run_dir>/events.jsonl`, and
   surface autonomous choices from `<run_dir>/decisions.jsonl` (legibility).

9. **Report by `status`** using `Get-NextCommandRecommendation -RunStatus $result.status`:
   - Print the recommended command; in `teach` mode also print its `why`.
   - `completed` → also point at `<run_dir>/report.md`.
   - `interrupted-budget` / `interrupted-destructive` → describe exactly what
     is pending (from `$result.pending_task_id`) before recommending the resume
     command; wait for the user's explicit go-ahead before re-invoking.
   - `rejected` → show the `## Acceptance` section of `report.md`.
   - `failed` / `plan-failed` / `plan-invalid` → show why, then the
     recommendation.

10. **First-run profile write.** If `$profile` was `$null` at step 2 (this was
    a genuinely new user), write a starter `user-profile.json` now with
    `preferred_interview_depth = $depth` (what was actually used) and
    `teaching_level = $teachLevel`, so the *next* `/baton:start` call is
    already calibrated:

    ```powershell
    if (-not $profile) {
        Write-UserProfile -Profile @{
            preferred_interview_depth = $depth; teaching_level = $teachLevel
            updated_at = (Get-Date -Format 'yyyy-MM-ddTHH:mm:sszzz')
        }
    }
    ```

## Arguments

$ARGUMENTS
```

- [ ] **Step 2: Write `commands/init.md`**

```markdown
---
description: Alias for /baton:start — the front porch. See /baton:start for the full procedure.
argument-hint: ["<name>"] [--folder <path>] [--goal "<text>"] [--budget <n>] [--max-tier local|free|paid] [--depth light|adaptive|full] [--quiet]
---

# /baton:init

This is an alias for `/baton:start`. Execute the exact procedure documented in
`commands/start.md`, passing `$ARGUMENTS` through unchanged.

## Arguments

$ARGUMENTS
```

- [ ] **Step 3: Write `commands/initialize.md`**

```markdown
---
description: Alias for /baton:start — the front porch. See /baton:start for the full procedure.
argument-hint: ["<name>"] [--folder <path>] [--goal "<text>"] [--budget <n>] [--max-tier local|free|paid] [--depth light|adaptive|full] [--quiet]
---

# /baton:initialize

This is an alias for `/baton:start`. Execute the exact procedure documented in
`commands/start.md`, passing `$ARGUMENTS` through unchanged.

## Arguments

$ARGUMENTS
```

- [ ] **Step 4: Manually validate the lib calls the command file relies on**

Run this from the repo root to prove every function `start.md` calls actually
exists and behaves as documented end-to-end for a "new project" run, using the
`fleet-go.ps1` test seams (`BATON_GO_TEST_PLAN`/`BATON_GO_TEST_SPAWN`) so no
real fleet call happens — mirroring how `commands/go.md`'s engine is smoke-tested
elsewhere in this repo:

```powershell
$tmp = Join-Path $env:TEMP "cao-start-smoke-$(Get-Random)"
New-Item -ItemType Directory -Path $tmp -Force | Out-Null
. "$PWD/scripts/job-lib.ps1"
. "$PWD/scripts/start-lib.ps1"

$rec = Read-ProjectRecord -ProjectId 'smoke-test' -ProjectsRoot (Join-Path $tmp 'projects')
if ($null -ne $rec) { throw "expected no prior record" }

$charter = New-CharterContent -Name 'Smoke Test' -Goal 'prove the wiring works' -Audience $null -Done $null -Reasoning 'validating the plan before implementer sign-off'
Set-Content -Path (Join-Path $tmp 'CHARTER.md') -Value $charter -Encoding utf8NoBOM
if (-not (Test-Path (Join-Path $tmp 'CHARTER.md'))) { throw "CHARTER.md was not written" }

Write-ProjectRecord -ProjectsRoot (Join-Path $tmp 'projects') -Record @{
    id = 'smoke-test'; name = 'Smoke Test'; folder = $tmp
    charter_path = (Join-Path $tmp 'CHARTER.md'); created_at = (Get-Date -Format 'yyyy-MM-ddTHH:mm:sszzz')
    last_updated = (Get-Date -Format 'yyyy-MM-ddTHH:mm:sszzz'); last_run = $null
}
$rec = Read-ProjectRecord -ProjectId 'smoke-test' -ProjectsRoot (Join-Path $tmp 'projects')
if ($rec.name -ne 'Smoke Test') { throw "round-trip failed" }

Write-Host "Smoke check OK — all functions start.md relies on exist and round-trip." -ForegroundColor Green
Remove-Item $tmp -Recurse -Force
```

Run: `pwsh -NoProfile -File <this-inline-script-saved-as-a-temp-file>` (or paste
directly into a `pwsh` session).
Expected: prints `Smoke check OK ...`, no thrown errors.

- [ ] **Step 5: Commit**

```bash
git add commands/start.md commands/init.md commands/initialize.md
git commit -m "feat(start): /baton:start command brain + /baton:init and /baton:initialize aliases"
```

---

## Task 5: Bootstrap wiring + plugin version bump

**Files:**
- Modify: `scripts/bootstrap.ps1:259`
- Modify: `scripts/test-bootstrap.ps1`
- Modify: `.claude-plugin/plugin.json`

**Interfaces:**
- Consumes: nothing new.
- Produces: nothing new — this task only ensures `start-lib.ps1` is deployed and
  the version reflects the new feature. (`commands/start.md`, `init.md`,
  `initialize.md` ship automatically via the plugin install step, exactly like
  every other `commands/*.md` file — see `bootstrap.ps1:223-250`, which installs
  the whole plugin rather than flat-copying individual command files. No
  bootstrap change is needed for the three command files themselves.)

- [ ] **Step 1: Write the failing test**

In `scripts/test-bootstrap.ps1`, add this line immediately after the existing
`Assert "deploys fleet-gate script" ...` line (`scripts/test-bootstrap.ps1:60`):

```powershell
Assert "would deploy start-lib.ps1" ($out -match 'start-lib\.ps1')
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pwsh -NoProfile -File scripts/test-bootstrap.ps1`
Expected: FAIL on the new `Assert "would deploy start-lib.ps1"` line (0 matches
in dry-run output).

- [ ] **Step 3: Add `start-lib.ps1` to the bootstrap deploy list**

In `scripts/bootstrap.ps1`, find the Step 5b `foreach` script list (line 259,
ending `..., 'gate-lib.ps1', 'fleet-gate.ps1', 'fleet-effective-cost.ps1', 'idea-lib.ps1'))`)
and add `'start-lib.ps1'` to the end of that array, before the closing `))`:

```powershell
foreach ($script in @('baton-home.ps1', 'job-lib.ps1', 'consolidate-lessons.ps1', 'parse-otel.ps1', 'fleet-lib.ps1', 'fleet-doctor.ps1', 'fleet-ensemble.ps1', 'routing-lib.ps1', 'saturation-lib.ps1', 'effective-cost-lib.ps1', 'routing-dispatch.ps1', 'routing-learn.ps1', 'routing-calibrate.ps1', 'routing-cascade.ps1', 'prime-hours.ps1', 'six-hats-lib.ps1', 'council-lib.ps1', 'code-lib.ps1', 'kb-lib.ps1', 'decisions-lib.ps1', 'consolidate-decisions.ps1', 'cost-lib.ps1', 'runs-lib.ps1', 'statusline-feed.ps1', 'fleet-runs-bridge.ps1', 'fleet-orchestrate.ps1', 'fleet-backlog.ps1', 'run-backlog.ps1', 'fleet-models.ps1', 'triage-lib.ps1', 'fleet-triage.ps1', 'usage-lib.ps1', 'fleet-usage.ps1', 'projects-lib.ps1', 'fleet-projects.ps1', 'research-gate-lib.ps1', 'fleet-research-gate.ps1', 'conductor-lib.ps1', 'fleet-go.ps1', 'memory-lib.ps1', 'fleet-memory.ps1', 'worker-lib.ps1', 'fleet-worker.ps1', 'gate-lib.ps1', 'fleet-gate.ps1', 'fleet-effective-cost.ps1', 'idea-lib.ps1', 'start-lib.ps1')) {
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pwsh -NoProfile -File scripts/test-bootstrap.ps1`
Expected: exit code 0, all `Assert` lines print PASS including the new one.

- [ ] **Step 5: Bump the plugin version**

In `.claude-plugin/plugin.json`, change:

```json
  "version": "1.4.1",
```

to:

```json
  "version": "1.5.0-rc.1",
```

(Minor bump, not patch — this adds new user-facing commands, not just a fix.)

- [ ] **Step 6: Commit**

```bash
git add scripts/bootstrap.ps1 scripts/test-bootstrap.ps1 .claude-plugin/plugin.json
git commit -m "chore(start): wire start-lib.ps1 into bootstrap deploy list, bump plugin to 1.5.0-rc.1"
```

---

## Task 6: Docs — `COMMANDS.md` and `getting-started.md`

**Files:**
- Modify: `docs/COMMANDS.md`
- Modify: `docs/getting-started.md`

**Interfaces:**
- Consumes: nothing (documentation only).
- Produces: nothing (documentation only).

- [ ] **Step 1: Add a "Front porch" section to `docs/COMMANDS.md`**

Insert a new top section immediately after the "## Shared idea" block and
before the `# Jobs` header (i.e. right before line 42, `# Jobs — track a piece
of work start to finish`):

```markdown
# Front porch — the one command to begin or resume

### /baton:start
- **One-liner:** Start a new project or resume one you already began — guided in plain language, no git or coding knowledge required.
- **When you'd use it:** This is the recommended way to begin. It works whether you know exactly what you want or have no idea where to start.
- **Syntax:** `/baton:start ["<name>"] [--folder <path>] [--goal "<text>"] [--budget <n>] [--max-tier local|free|paid] [--depth light|adaptive|full] [--quiet]`
- **Arguments & flags:**
  - `"<name>"` — the project's name (optional; asked for if omitted).
  - `--folder <path>` — where it lives. Omit it and Baton either adopts your current folder or asks.
  - `--goal "<text>"` — what you want built, if you already know. Omit it and you'll be asked.
  - `--budget <n>` / `--max-tier <tier>` — passed straight through to the execution engine.
  - `--depth light|adaptive|full` — override how many questions it asks. Default adapts to you over time.
  - `--quiet` — turn off the plain-language explanations (teaching is on by default).
- **Under the hood:** Detects whether this is a new or existing Baton project. New: runs a guided interview, sets up the folder and git for you (explaining each step), writes a `CHARTER.md` in your project recording what you want and why, then hands off to `/baton:go` to build it full-auto. Existing: shows you where you left off and recommends the next command.
- **Where results land:** `CHARTER.md` in your project folder (yours to read/edit); `$BATON_HOME/projects/<id>/project.json` (box-private project record); run artifacts under `$BATON_HOME/runs/<run-id>/` (same as `/baton:go`).
- **Plain example:** `/baton:start "Acme API"` → asks a few questions, sets everything up, and starts building.
- **Gotchas:** Aliases `/baton:init` and `/baton:initialize` do exactly the same thing — pick whichever name you remember. It only stops mid-run for a budget limit or an action that's hard to undo; everything else runs on your behalf.

---
```

- [ ] **Step 2: Add `/baton:start` to the cheat sheet table**

In `docs/COMMANDS.md`'s cheat-sheet table (the `| Command | One-liner |` table
near the end), add a new first data row right after the header/separator rows:

```markdown
| `/baton:start ["<name>"]` | Start or resume a project — the front porch |
```

- [ ] **Step 3: Point `docs/getting-started.md` at `/baton:start`**

In `docs/getting-started.md`, replace the section "### 1. Open a project"
through the end of "### 2. Open a job" (currently lines 21-36) with:

```markdown
### 1. Start (or resume) a project

```powershell
cd path\to\some\repo
claude   # or your IDE's Claude integration
```

```
/baton:start "rewrite the auth middleware"
```

`/baton:start` is the recommended on-ramp — it works whether this is a brand
new project or one you've already begun, and it doesn't assume you know git or
how to structure a repo. It asks what you're building (skipping questions
you've already answered via flags), sets up the folder and git for you if
needed, writes a plain-language `CHARTER.md` recording what you want and why,
then drives the work full-auto via `/baton:go` — stopping only for a budget
limit or a hard-to-undo action.

If you'd rather track the work as a manual job without the guided interview or
full-auto execution, `/baton:job-start "<brief>"` remains available — it
creates `$BATON_HOME/jobs/<id>/` (default `~/.baton/jobs/<id>/`) with
`manifest.yaml`, `brief.md`, `phase-log.md`, `lessons.md`, starting at the
`research` phase, and you drive each phase yourself.
```

- [ ] **Step 4: Renumber the remaining steps**

The old "### 3. Research the problem" through "### 7. Wrap up" sections
(previously numbered 3-7) each get their heading number decremented by one
(3→2, 4→3, 5→4, 6→5, 7→6), since step 2 ("Open a job") was folded into the new
step 1. No body text in those sections changes — only the leading digit in
each `### N. ...` heading.

- [ ] **Step 5: Commit**

```bash
git add docs/COMMANDS.md docs/getting-started.md
git commit -m "docs(start): document /baton:start as the recommended front-porch entry point"
```

---

## Self-Review Notes (completed during authoring, not a task)

- **Spec coverage:** every function named in the spec's "start-lib.ps1 —
  functions" section (`Resolve-StartMode`, `Resolve-InterviewDepth`,
  `Resolve-TeachingLevel`, `New-CharterContent`, `Format-ResumeStatus`,
  `Get-NextCommandRecommendation`, `Read-ProjectRecord`, `Write-ProjectRecord`,
  `Read-UserProfile`, `Write-UserProfile`) is implemented in Tasks 1-3 and
  exercised by a test. The state machine, onboarding, folder detect-&-branch,
  CHARTER/decision/Grimdex documentation layering, `/baton:go` hand-off, and
  seam legibility are all covered in Task 4's `commands/start.md`. Bootstrap
  wiring (Task 5) and docs (Task 6) match the spec's file list.
- **Placeholder scan:** no TBD/TODO in any task; every step shows literal code
  or literal markdown to write, not a description of it.
- **Type consistency:** `Get-NextCommandRecommendation` returns
  `@{ command; why }` everywhere it's defined (Task 1) and everywhere it's
  consumed (Task 4, step 9). `Resolve-InterviewDepth`/`Resolve-TeachingLevel`
  signatures (`-Profile`, `-Explicit`) match between Task 1's definition and
  Task 4's call sites. `Read-ProjectRecord`/`Write-ProjectRecord` signatures
  (`-ProjectId`/`-Record`, `-ProjectsRoot`) match between Task 2's definition
  and Task 4's call sites.
- **Out of scope confirmed absent from tasks:** no language/framework scaffold
  beyond `git init` + 3 seed files; no Grimdex learning-loop code (slice 2,
  Task 4 step 6 only notes it as "best-effort... if present"); no mid-stream
  injection UI (slice 3).
