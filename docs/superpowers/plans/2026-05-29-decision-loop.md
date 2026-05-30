# Decision Loop Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Auto-captured structured decision records with self-assessment, per-decision feedback (human + Claude), and a two-layer (universal + per-project) consolidation that distills "how to decide" with explicit deviation tracking. Closes the self-improvement loop.

**Architecture:** `scripts/decisions-lib.ps1` provides `Add-DecisionRecord` (sequentially numbered `dNNN-<slug>.md` files in `~/.claude/knowledge/projects/<id>/decisions/`), `Append-DecisionFeedback`, and `Read-Decisions`. Claude calls `Add-DecisionRecord` per a CLAUDE.md capture rule (discipline-enforced, opt-out-able via marker files). `/decision-feedback` attaches human feedback. `/consolidate-decisions` distills records+feedback into `projects/<id>/decision-guidance.md` and `universal/decision-guidance.md`, promoting only patterns with explicit positive feedback across ≥2 projects, recording deviations + reasons. `/project-init` calibrates universal guidance for a new project. `/job-phase done` (Plan 3) is extended with a decision retro.

**Tech Stack:** PowerShell 7+ (pwsh). Reuses Plan 3's `Resolve-ProjectId`, `ConvertTo-JobSlug`, `Read-CurrentJob` from `job-lib.ps1`. No new dependencies.

---

## Spec reference

`docs/superpowers/specs/2026-05-29-decision-loop-design.md`.

## Key contracts (from spec)

- **Record schema:** YAML front matter (`id`, `timestamp`, `project`, `job`, `phase`, `status`, `confidence`, `revisit-if`, `flag`) + markdown body (`# Title`, `**Chosen:**`, `**Alternatives:**`, `**Rationale:**`, `## Feedback`).
- **Record path:** `~/.claude/knowledge/projects/<project-id>/decisions/d<NNN>-<slug>.md`. NNN is per-project sequential, derived from filesystem (highest existing `dNNN` + 1).
- **Opt-out files:** `~/.claude/decisions-off` (global) or `~/.claude/knowledge/projects/<id>/decisions-off` (per-project) — when present, `Add-DecisionRecord` no-ops silently.
- **Feedback append:** appends a timestamped entry to the record's `## Feedback` section. Negative outcome (`didnt`|`mixed`) sets front-matter `flag: review-needed`. `--urgent` writes a `dashboard | decision-flag | <id>` journal line.
- **Consolidation thresholds:**
  - Project guidance promotes any pattern observed in that project's records (curated, qualitative).
  - **Universal promotion requires explicit positive feedback (`outcome:worked`) on records from ≥2 distinct projects.** Silence does NOT promote.
  - Deviations recorded in `projects/<id>/decision-guidance.md` under `## Deviations from universal` with: universal default, project actual, reason.
- **Project-init:** surfaces `universal/decision-guidance.md`, captures per-project overrides → `projects/<id>/decision-guidance.md` with header `<!-- calibrated YYYY-MM-DD from universal -->`.
- **End-of-job retro:** `/job-phase done` lists this job's decisions (filter by `job:<id>` front-matter), prompts for late feedback. Non-blocking.

---

## File structure

| Path | Responsibility |
|---|---|
| `scripts/decisions-lib.ps1` | NEW: `Add-DecisionRecord`, `Get-NextDecisionId`, `Append-DecisionFeedback`, `Read-Decisions`. Dot-sources `job-lib.ps1` for `Resolve-ProjectId`, `ConvertTo-JobSlug`, `Read-CurrentJob`. |
| `scripts/consolidate-decisions.ps1` | NEW: distill records → 2-layer guidance + deviations + consolidated markers. |
| `scripts/test-decisions-lib.ps1` | NEW: tests for Add/Append/Read/Get-NextId + opt-out. |
| `scripts/test-consolidate-decisions.ps1` | NEW: tests for promotion threshold + deviation tracking + idempotency. |
| `commands/decision-feedback.md` | NEW: `/decision-feedback <id> "<text>" [--outcome worked\|didnt\|mixed] [--urgent]` |
| `commands/consolidate-decisions.md` | NEW: wraps the script. |
| `commands/project-init.md` | NEW: calibration flow (Claude surfaces universal, writes per-project overrides). |
| `commands/job-phase.md` | MODIFY: add decision retro to the `done` subcommand. |
| `references/CLAUDE-decision-capture-rule.md` | NEW: canonical capture-rule paragraph deployed into project root `CLAUDE.md`. |
| `scripts/bootstrap.ps1` | MODIFY: deploy libs + commands + seed universal guidance + CLAUDE.md insertion + auto-trigger /project-init first time. |
| `README.md` | MODIFY: Decision Loop section. |

---

## Task ordering

Sequential. Foundation first (Tasks 1-2), commands (3-6), CLAUDE.md rule + bootstrap (7-8), README + smoke (9).

---

## Task 1: `decisions-lib.ps1` foundation — Add-DecisionRecord + Get-NextDecisionId + opt-out

**Files:**
- Create: `scripts/decisions-lib.ps1`
- Create: `scripts/test-decisions-lib.ps1`

- [ ] **Step 1: Write the failing test — `scripts/test-decisions-lib.ps1`**

```powershell
#!/usr/bin/env pwsh
# Tests for scripts/decisions-lib.ps1
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'decisions-lib.ps1')

$failures = 0
function Assert($label, $cond) {
    if ($cond) { Write-Host "PASS  $label" -ForegroundColor Green }
    else { Write-Host "FAIL  $label" -ForegroundColor Red; $script:failures++ }
}

$tmpKb = Join-Path $env:TEMP "dec-kb-$(Get-Random)"
New-Item -ItemType Directory -Force -Path $tmpKb | Out-Null

# --- Get-NextDecisionId: empty dir → d001 ---
$decDir = Join-Path $tmpKb 'projects/testproj/decisions'
New-Item -ItemType Directory -Force -Path $decDir | Out-Null
$id1 = Get-NextDecisionId -ProjectDecisionsDir $decDir
Assert "empty dir returns d001" ($id1 -eq 'd001')

# Seed an existing record and verify increment
Set-Content -Path (Join-Path $decDir 'd001-first.md') -Value '' -Encoding utf8NoBOM
Set-Content -Path (Join-Path $decDir 'd003-skipped.md') -Value '' -Encoding utf8NoBOM
$id2 = Get-NextDecisionId -ProjectDecisionsDir $decDir
Assert "next after d001+d003 is d004" ($id2 -eq 'd004')

# --- Add-DecisionRecord ---
$rec = Add-DecisionRecord `
    -Title "Use Start-Job for ensemble concurrency" `
    -Chosen "Process-isolated Start-Job per provider." `
    -Alternatives @("Claude-native subagents — heavier dispatch", "ForEach-Object -Parallel — runspace env collision") `
    -Rationale "Env isolation + crash isolation; lean dispatch." `
    -Confidence 'med' `
    -RevisitIf "Ensemble grows beyond 5 providers" `
    -Project 'testproj' `
    -Job 'j-test-123' `
    -Phase 'design' `
    -KbRoot $tmpKb

Assert "Add-DecisionRecord returns an id" ($rec.id -match '^d\d{3}$')
Assert "record file exists" (Test-Path $rec.path)
$content = Get-Content $rec.path -Raw
Assert "front-matter id matches" ($content -match "(?m)^id:\s+$($rec.id)")
Assert "front-matter has project" ($content -match "(?m)^project:\s+testproj")
Assert "front-matter has job" ($content -match "(?m)^job:\s+j-test-123")
Assert "front-matter has phase" ($content -match "(?m)^phase:\s+design")
Assert "front-matter has confidence" ($content -match "(?m)^confidence:\s+med")
Assert "front-matter has revisit-if" ($content -match 'revisit-if:\s+"Ensemble grows beyond 5 providers"')
Assert "body has title" ($content -match '(?m)^# Use Start-Job for ensemble concurrency')
Assert "body has Chosen" ($content -match '\*\*Chosen:\*\* Process-isolated Start-Job')
Assert "body has alternatives" ($content -match 'Claude-native subagents')
Assert "body has Rationale" ($content -match '\*\*Rationale:\*\* Env isolation')
Assert "body has empty Feedback section" ($content -match '## Feedback')

# --- Opt-out: global decisions-off file suppresses capture ---
$optOut = Join-Path $tmpKb 'decisions-off'
Set-Content -Path $optOut -Value '' -Encoding utf8NoBOM
$rec2 = Add-DecisionRecord `
    -Title "should be skipped" -Chosen "x" -Alternatives @("y") `
    -Rationale "z" -Confidence 'high' -RevisitIf "never" `
    -Project 'testproj' -KbRoot $tmpKb -OptOutPath $optOut
Assert "global opt-out suppresses capture" ($null -eq $rec2)
Remove-Item $optOut

# --- Opt-out: per-project decisions-off file suppresses capture ---
$projOptOut = Join-Path $tmpKb 'projects/testproj/decisions-off'
Set-Content -Path $projOptOut -Value '' -Encoding utf8NoBOM
$rec3 = Add-DecisionRecord `
    -Title "should also be skipped" -Chosen "x" -Alternatives @("y") `
    -Rationale "z" -Confidence 'high' -RevisitIf "never" `
    -Project 'testproj' -KbRoot $tmpKb
Assert "project opt-out suppresses capture" ($null -eq $rec3)
Remove-Item $projOptOut

Remove-Item $tmpKb -Recurse -Force
if ($failures -gt 0) { Write-Host "`n$failures failure(s)" -ForegroundColor Red; exit 1 }
Write-Host "`nAll tests passed." -ForegroundColor Green
```

- [ ] **Step 2: Run to verify failure**

```powershell
pwsh -NoProfile -File scripts\test-decisions-lib.ps1
```

Expected: `Cannot find path …\decisions-lib.ps1` or `Get-NextDecisionId not recognized`.

- [ ] **Step 3: Create `scripts/decisions-lib.ps1`**

```powershell
#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Decision Loop foundation: auto-captured decision records + feedback append + read/filter.

.DESCRIPTION
  Records live at ~/.claude/knowledge/projects/<id>/decisions/d<NNN>-<slug>.md.
  Per-project sequential numbering derived from the filesystem.
  Reuses Plan 3's job-lib.ps1 for Resolve-ProjectId / ConvertTo-JobSlug / Read-CurrentJob.
  Opt-out: ~/.claude/decisions-off (global) or projects/<id>/decisions-off (per-project).
#>

# Dot-source job-lib for shared helpers (Resolve-ProjectId, ConvertTo-JobSlug, Read-CurrentJob).
$script:JobLibPath = Join-Path $PSScriptRoot 'job-lib.ps1'
if (Test-Path $script:JobLibPath) { . $script:JobLibPath }

$script:DefaultKbRoot = (Join-Path $HOME '.claude/knowledge')
$script:DefaultOptOut = (Join-Path $HOME '.claude/decisions-off')

function Get-NextDecisionId {
    <# Scan ProjectDecisionsDir for the highest dNNN-*.md and return the next id. #>
    param([Parameter(Mandatory)][string]$ProjectDecisionsDir)
    if (-not (Test-Path $ProjectDecisionsDir)) { return 'd001' }
    $max = 0
    foreach ($f in Get-ChildItem -Path $ProjectDecisionsDir -Filter 'd*.md' -ErrorAction SilentlyContinue) {
        if ($f.Name -match '^d(\d{3,})') {
            $n = [int]$matches[1]
            if ($n -gt $max) { $max = $n }
        }
    }
    return ('d{0:D3}' -f ($max + 1))
}

function Test-DecisionsOptOut {
    <# Returns $true if any opt-out marker is present (global or per-project). #>
    param(
        [string]$OptOutPath = $script:DefaultOptOut,
        [string]$ProjectOptOutPath
    )
    if (Test-Path $OptOutPath) { return $true }
    if ($ProjectOptOutPath -and (Test-Path $ProjectOptOutPath)) { return $true }
    return $false
}

function Add-DecisionRecord {
    <# Write a structured decision record. Returns @{ id; path } or $null if opted-out. #>
    param(
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string]$Chosen,
        [Parameter(Mandatory)][string[]]$Alternatives,
        [Parameter(Mandatory)][string]$Rationale,
        [Parameter(Mandatory)][ValidateSet('high','med','low')][string]$Confidence,
        [Parameter(Mandatory)][string]$RevisitIf,
        [string]$Project,
        [string]$Job,
        [string]$Phase,
        [string]$KbRoot = $script:DefaultKbRoot,
        [string]$OptOutPath = $script:DefaultOptOut
    )

    # Resolve project: explicit arg → Plan 3 Resolve-ProjectId → fallback "_uncategorized"
    if (-not $Project) {
        if (Get-Command Resolve-ProjectId -ErrorAction SilentlyContinue) {
            $Project = Resolve-ProjectId
        }
        if (-not $Project) { $Project = '_uncategorized' }
    }

    $projDir = Join-Path $KbRoot "projects/$Project"
    $projOptOut = Join-Path $projDir 'decisions-off'
    if (Test-DecisionsOptOut -OptOutPath $OptOutPath -ProjectOptOutPath $projOptOut) {
        return $null
    }

    $decDir = Join-Path $projDir 'decisions'
    if (-not (Test-Path $decDir)) { New-Item -ItemType Directory -Force -Path $decDir | Out-Null }

    $id = Get-NextDecisionId -ProjectDecisionsDir $decDir
    $slug = if (Get-Command ConvertTo-JobSlug -ErrorAction SilentlyContinue) {
        ConvertTo-JobSlug $Title
    } else {
        ($Title.ToLowerInvariant() -replace '[^a-z0-9]+', '-').Trim('-').Substring(0, [Math]::Min(40, $Title.Length))
    }
    $path = Join-Path $decDir "$id-$slug.md"

    $ts = Get-Date -Format 'yyyy-MM-ddTHH:mm:sszzz'
    $altLines = ($Alternatives | ForEach-Object { "- $_" }) -join "`n"

    # Quote revisit-if so YAML doesn't choke on colons/special chars
    $revisitEscaped = $RevisitIf -replace '"', '\"'

    $jobLine   = if ($Job)   { "job: $Job" }       else { "job: null" }
    $phaseLine = if ($Phase) { "phase: $Phase" }   else { "phase: null" }

    $content = @"
---
id: $id
timestamp: $ts
project: $Project
$jobLine
$phaseLine
status: active
confidence: $Confidence
revisit-if: "$revisitEscaped"
flag: null
---

# $Title

**Chosen:** $Chosen

**Alternatives:**
$altLines

**Rationale:** $Rationale

## Feedback
"@

    Set-Content -Path $path -Value $content -Encoding utf8NoBOM
    return @{ id = $id; path = $path }
}
```

- [ ] **Step 4: Run to verify pass**

```powershell
pwsh -NoProfile -File scripts\test-decisions-lib.ps1
```

Expected: `All tests passed.`.

- [ ] **Step 5: Commit**

```powershell
git add scripts/decisions-lib.ps1 scripts/test-decisions-lib.ps1
git commit -m "feat(decision-loop): Add-DecisionRecord + Get-NextDecisionId + opt-out + tests"
```

---

## Task 2: `Append-DecisionFeedback` + `Read-Decisions`

**Files:**
- Modify: `scripts/decisions-lib.ps1`
- Modify: `scripts/test-decisions-lib.ps1`

- [ ] **Step 1: Add failing tests** — append to `scripts/test-decisions-lib.ps1` BEFORE the final `if ($failures -gt 0)...` / `All tests passed.` block (you'll need to re-add the `$tmpKb` setup if it was cleaned; structure the file so a fresh `$tmpKb2` is created for this block):

```powershell
# --- Append-DecisionFeedback + Read-Decisions ---
$tmpKb2 = Join-Path $env:TEMP "dec-kb2-$(Get-Random)"
New-Item -ItemType Directory -Force -Path $tmpKb2 | Out-Null

$r1 = Add-DecisionRecord `
    -Title "Pick storage at project level" `
    -Chosen "Project-level decisions/ dir." `
    -Alternatives @("Job-level — lost when job ends") `
    -Rationale "Decisions outlive jobs." `
    -Confidence 'high' -RevisitIf "Project structure changes" `
    -Project 'p1' -Job 'j-aaa' -KbRoot $tmpKb2

$r2 = Add-DecisionRecord `
    -Title "Pick consolidation threshold" `
    -Chosen "≥2 projects for universal promotion." `
    -Alternatives @("Any project — pollutes universal") `
    -Rationale "Prevent single-project quirks." `
    -Confidence 'med' -RevisitIf "Universal grows noisy" `
    -Project 'p1' -Job 'j-aaa' -KbRoot $tmpKb2

# Positive feedback
Append-DecisionFeedback -Id $r1.id -Project 'p1' -KbRoot $tmpKb2 `
    -Text "worked well on first project" -Outcome 'worked' -Author 'kevin'
$c1 = Get-Content $r1.path -Raw
Assert "feedback section has the entry" ($c1 -match 'worked well on first project')
Assert "feedback has author kevin" ($c1 -match '\| kevin \|')
Assert "feedback has outcome:worked" ($c1 -match 'outcome:worked')
Assert "front-matter flag unchanged on positive" ($c1 -match '(?m)^flag:\s+null')

# Negative feedback sets flag
Append-DecisionFeedback -Id $r2.id -Project 'p1' -KbRoot $tmpKb2 `
    -Text "didn't scale past 10 providers" -Outcome 'didnt' -Author 'kevin'
$c2 = Get-Content $r2.path -Raw
Assert "front-matter flag = review-needed on negative" ($c2 -match '(?m)^flag:\s+review-needed')
Assert "negative feedback recorded" ($c2 -match "didn't scale")

# Read-Decisions filters by job
$forJob = Read-Decisions -Project 'p1' -Job 'j-aaa' -KbRoot $tmpKb2
Assert "Read-Decisions -Job returns 2 records" ($forJob.Count -eq 2)
$noJob = Read-Decisions -Project 'p1' -Job 'j-other' -KbRoot $tmpKb2
Assert "Read-Decisions -Job other returns 0" ($noJob.Count -eq 0)

# Read-Decisions returns id/title/confidence/flag for retro listing
Assert "first record has id field" ($forJob[0].id -match '^d\d{3}$')
Assert "first record has title field" ($forJob[0].title.Length -gt 0)

# Append-DecisionFeedback on unknown id throws
$threw = $false
try { Append-DecisionFeedback -Id 'd999' -Project 'p1' -KbRoot $tmpKb2 -Text 'x' -Outcome 'worked' -Author 'kevin' } catch { $threw = $true }
Assert "Append on unknown id throws" $threw

Remove-Item $tmpKb2 -Recurse -Force
```

- [ ] **Step 2: Run to verify failure**

```powershell
pwsh -NoProfile -File scripts\test-decisions-lib.ps1
```

Expected: `The term 'Append-DecisionFeedback' is not recognized`.

- [ ] **Step 3: Append `Append-DecisionFeedback` and `Read-Decisions` to `scripts/decisions-lib.ps1`**

```powershell
function Find-DecisionRecordPath {
    <# Return the .md path for a given decision id within a project, or $null. #>
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$Project,
        [string]$KbRoot = $script:DefaultKbRoot
    )
    $decDir = Join-Path $KbRoot "projects/$Project/decisions"
    if (-not (Test-Path $decDir)) { return $null }
    $match = Get-ChildItem -Path $decDir -Filter "$Id-*.md" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($match) { return $match.FullName }
    return $null
}

function Append-DecisionFeedback {
    <# Append a feedback entry to a record's ## Feedback section, optionally setting flag. #>
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$Project,
        [Parameter(Mandatory)][string]$Text,
        [ValidateSet('worked','didnt','mixed')][string]$Outcome = 'worked',
        [Parameter(Mandatory)][string]$Author,
        [string]$KbRoot = $script:DefaultKbRoot
    )
    $path = Find-DecisionRecordPath -Id $Id -Project $Project -KbRoot $KbRoot
    if (-not $path) { throw "No decision record found for id '$Id' in project '$Project'." }

    $ts = Get-Date -Format 'yyyy-MM-ddTHH:mm:sszzz'
    # Sanitize text: collapse newlines + escape pipes (matches Plan 3 lesson conventions)
    $safe = ($Text -replace '\|', '¦' -replace "`r?`n", ' ').Trim()
    $entry = "$ts | $Author | outcome:$Outcome | $safe"
    Add-Content -Path $path -Value $entry -Encoding utf8NoBOM

    # On negative outcome, flip front-matter flag (line-by-line edit; YAML stays valid)
    if ($Outcome -in @('didnt','mixed')) {
        $lines = Get-Content $path
        $updated = $lines | ForEach-Object {
            if ($_ -match '^flag:\s+null\s*$') { 'flag: review-needed' } else { $_ }
        }
        Set-Content -Path $path -Value ($updated -join "`n") -Encoding utf8NoBOM
    }
}

function Read-Decisions {
    <# List decision records for a project, optionally filtered by -Job. Returns lightweight objects. #>
    param(
        [Parameter(Mandatory)][string]$Project,
        [string]$Job,
        [string]$KbRoot = $script:DefaultKbRoot
    )
    $decDir = Join-Path $KbRoot "projects/$Project/decisions"
    if (-not (Test-Path $decDir)) { return @() }
    $out = @()
    foreach ($f in (Get-ChildItem -Path $decDir -Filter 'd*.md' -ErrorAction SilentlyContinue)) {
        $raw = Get-Content $f.FullName -Raw
        # Parse just what we need: id, title, confidence, flag, job
        $id    = if ($raw -match '(?m)^id:\s+(d\d{3})')          { $matches[1] } else { $f.BaseName }
        $title = if ($raw -match '(?m)^#\s+(.+)$')                { $matches[1].Trim() } else { '(no title)' }
        $conf  = if ($raw -match '(?m)^confidence:\s+(\w+)')      { $matches[1] } else { 'unknown' }
        $flag  = if ($raw -match '(?m)^flag:\s+(\S+)')            { $matches[1] } else { 'null' }
        $rjob  = if ($raw -match '(?m)^job:\s+(\S+)')             { $matches[1] } else { 'null' }
        if ($Job -and $rjob -ne $Job) { continue }
        $out += [pscustomobject]@{
            id = $id; title = $title; confidence = $conf; flag = $flag; job = $rjob; path = $f.FullName
        }
    }
    return $out
}
```

- [ ] **Step 4: Run to verify pass**

```powershell
pwsh -NoProfile -File scripts\test-decisions-lib.ps1
```

Expected: `All tests passed.`.

- [ ] **Step 5: Commit**

```powershell
git add scripts/decisions-lib.ps1 scripts/test-decisions-lib.ps1
git commit -m "feat(decision-loop): Append-DecisionFeedback + Read-Decisions + tests"
```

---

## Task 3: `/decision-feedback` slash command

**Files:**
- Create: `commands/decision-feedback.md`

- [ ] **Step 1: Create `commands/decision-feedback.md`** (literal triple-backticks in the file):

```markdown
---
description: Attach human feedback to a decision record. Outcome worked|didnt|mixed; --urgent writes a dashboard journal line for immediate visibility.
argument-hint: <id> "<text>" [--outcome worked|didnt|mixed] [--urgent]
---

# /decision-feedback

Append feedback to a decision record at
`~/.claude/knowledge/projects/<project>/decisions/<id>-*.md`.

## Steps

1. **Parse `$ARGUMENTS`:** first token is the decision id (e.g. `d014`); next a
   quoted string is the feedback text; optional `--outcome worked|didnt|mixed`
   (default `worked`); optional `--urgent`.

2. **Resolve project** via Plan 3's `Resolve-ProjectId` (auto-detect from git
   remote / cwd).

3. **Run:**

   ```powershell
   . "$HOME/.claude/scripts/job-lib.ps1"
   . "$HOME/.claude/scripts/decisions-lib.ps1"
   $id      = '<ID>'
   $text    = '<TEXT>'             # single-quote-escaped
   $outcome = '<OUTCOME>'           # 'worked' | 'didnt' | 'mixed'
   $proj    = Resolve-ProjectId
   Append-DecisionFeedback -Id $id -Project $proj -Text $text -Outcome $outcome -Author 'kevin'
   Write-Host "Feedback recorded on $id ($outcome)." -ForegroundColor Green
   ```

4. **If `--urgent`**, additionally write a journal line so the dashboard sees it:

   ```powershell
   $ts = Get-Date -Format 'yyyy-MM-ddTHH:mm:sszzz'
   $line = "$ts | dashboard | decision-flag | $id | urgent feedback: $text"
   Add-Content -Path (Join-Path $HOME '.claude/model-routing-log.md') -Value $line
   ```

5. **On error** (unknown id, no project), surface the thrown message and suggest
   the user check `~/.claude/knowledge/projects/<id>/decisions/` for valid ids.

## Arguments

$ARGUMENTS
```

- [ ] **Step 2: Commit**

```powershell
git add commands/decision-feedback.md
git commit -m "feat(decision-loop): /decision-feedback slash command"
```

---

## Task 4: `consolidate-decisions.ps1` + `/consolidate-decisions` command

**Files:**
- Create: `scripts/consolidate-decisions.ps1`
- Create: `commands/consolidate-decisions.md`
- Create: `scripts/test-consolidate-decisions.ps1`

- [ ] **Step 1: Write the failing test — `scripts/test-consolidate-decisions.ps1`**

```powershell
#!/usr/bin/env pwsh
# Tests for scripts/consolidate-decisions.ps1
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'decisions-lib.ps1')

$failures = 0
function Assert($label, $cond) {
    if ($cond) { Write-Host "PASS  $label" -ForegroundColor Green }
    else { Write-Host "FAIL  $label" -ForegroundColor Red; $script:failures++ }
}

# Build a KB with 2 projects, each having one positive-feedback record for the same pattern.
$kb = Join-Path $env:TEMP "dec-cons-$(Get-Random)"
New-Item -ItemType Directory -Force -Path $kb | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $kb 'universal') | Out-Null

# Project A — Start-Job decision, positive feedback
$rA = Add-DecisionRecord -Title "Use Start-Job for ensemble" `
    -Chosen "Start-Job per provider." -Alternatives @("subagents") `
    -Rationale "Env isolation." -Confidence 'high' -RevisitIf "scale beyond 5" `
    -Project 'projA' -KbRoot $kb
Append-DecisionFeedback -Id $rA.id -Project 'projA' -Text "worked great" -Outcome 'worked' -Author 'kevin' -KbRoot $kb

# Project B — same pattern, positive feedback
$rB = Add-DecisionRecord -Title "Use Start-Job for ensemble" `
    -Chosen "Start-Job per provider." -Alternatives @("subagents") `
    -Rationale "Env isolation." -Confidence 'med' -RevisitIf "scale beyond 5" `
    -Project 'projB' -KbRoot $kb
Append-DecisionFeedback -Id $rB.id -Project 'projB' -Text "smooth" -Outcome 'worked' -Author 'kevin' -KbRoot $kb

# Project A — solo decision (no cross-project signal), positive
$rA2 = Add-DecisionRecord -Title "Use Markdown for KB" `
    -Chosen "Markdown files." -Alternatives @("SQLite") `
    -Rationale "Inspectable." -Confidence 'high' -RevisitIf "performance issues" `
    -Project 'projA' -KbRoot $kb
Append-DecisionFeedback -Id $rA2.id -Project 'projA' -Text "fine" -Outcome 'worked' -Author 'kevin' -KbRoot $kb

# Project C — solo decision, negative
$rC = Add-DecisionRecord -Title "Use runspaces for parallel" `
    -Chosen "ForEach -Parallel." -Alternatives @("Start-Job") `
    -Rationale "Lightweight." -Confidence 'low' -RevisitIf "env collision" `
    -Project 'projC' -KbRoot $kb
Append-DecisionFeedback -Id $rC.id -Project 'projC' -Text "collisions broke it" -Outcome 'didnt' -Author 'kevin' -KbRoot $kb

# Run the consolidator
& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'consolidate-decisions.ps1') -KbRoot $kb | Out-Null

# --- Project guidance files exist for every project that had records ---
foreach ($p in @('projA','projB','projC')) {
    Assert "project $p guidance file exists" (Test-Path (Join-Path $kb "projects/$p/decision-guidance.md"))
}

# --- Project guidance: Project A's Markdown decision recorded (single-project pattern stays project-level) ---
$gA = Get-Content (Join-Path $kb 'projects/projA/decision-guidance.md') -Raw
Assert "projA guidance mentions Markdown" ($gA -match 'Markdown')

# --- Project C's runspaces decision should appear under 'Known mistakes' (negative feedback) ---
$gC = Get-Content (Join-Path $kb 'projects/projC/decision-guidance.md') -Raw
Assert "projC guidance has Known mistakes" ($gC -match '## Known mistakes')
Assert "projC mistake mentions runspaces" ($gC -match 'runspaces')

# --- Universal guidance: Start-Job pattern promoted (≥2 projects with outcome:worked) ---
$uni = Get-Content (Join-Path $kb 'universal/decision-guidance.md') -Raw
Assert "universal mentions Start-Job pattern" ($uni -match 'Start-Job')

# --- Universal guidance: Markdown decision NOT promoted (only 1 project) ---
Assert "universal does NOT mention Markdown (only 1 project)" ($uni -notmatch 'Markdown')

# --- Records marked consolidated (idempotency footer) ---
$cA = Get-Content $rA.path -Raw
Assert "rA marked consolidated" ($cA -match '<!-- consolidated \d{4}-\d{2}-\d{2} -->')

# --- Second run is a no-op: counts of pattern mentions don't grow ---
$beforeCount = ([regex]::Matches($uni, 'Start-Job')).Count
& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'consolidate-decisions.ps1') -KbRoot $kb | Out-Null
$uni2 = Get-Content (Join-Path $kb 'universal/decision-guidance.md') -Raw
$afterCount = ([regex]::Matches($uni2, 'Start-Job')).Count
Assert "second run is a no-op (universal mention count unchanged)" ($beforeCount -eq $afterCount)

Remove-Item $kb -Recurse -Force
if ($failures -gt 0) { Write-Host "`n$failures failure(s)" -ForegroundColor Red; exit 1 }
Write-Host "`nAll tests passed." -ForegroundColor Green
```

- [ ] **Step 2: Run to verify failure**

```powershell
pwsh -NoProfile -File scripts\test-consolidate-decisions.ps1
```

Expected: `Cannot find path …\consolidate-decisions.ps1`.

- [ ] **Step 3: Create `scripts/consolidate-decisions.ps1`**

```powershell
#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Distill decision records + feedback into two-layer guidance docs.

.DESCRIPTION
  For each project in $KbRoot/projects/:
    - Read its decision records.
    - Group by chosen-pattern (a stable signature derived from title+chosen).
    - Write projects/<id>/decision-guidance.md with: Established patterns
      (positive outcomes), Known mistakes (negative outcomes), Open/under-feedback,
      Deviations from universal.
  Then: promote any pattern observed in ≥2 projects with at least one
  outcome:worked feedback per project to universal/decision-guidance.md.
  Mark consolidated records with a footer comment (idempotency).
#>

param(
    [string]$KbRoot = (Join-Path $HOME '.claude/knowledge')
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'decisions-lib.ps1')

$projectsRoot = Join-Path $KbRoot 'projects'
$universalGuidance = Join-Path $KbRoot 'universal/decision-guidance.md'
if (-not (Test-Path (Split-Path $universalGuidance -Parent))) {
    New-Item -ItemType Directory -Force -Path (Split-Path $universalGuidance -Parent) | Out-Null
}
if (-not (Test-Path $universalGuidance)) {
    Set-Content -Path $universalGuidance -Value "# Universal Decision Guidance`n`n" -Encoding utf8NoBOM
}

$today = Get-Date -Format 'yyyy-MM-dd'

function Get-RecordSignature {
    <# A coarse signature for cross-project pattern matching: lowercased title + chosen. #>
    param([string]$Title, [string]$Chosen)
    $sig = "$Title|$Chosen".ToLowerInvariant()
    $sig = ($sig -replace '\s+', ' ').Trim()
    return $sig
}

function Read-RecordDetail {
    <# Parse a record file into a hashtable with id, title, chosen, alternatives, rationale, confidence,
       feedback-outcomes (string[]), already-consolidated (bool), signature, path. #>
    param([string]$Path)
    $raw = Get-Content $Path -Raw
    $id        = if ($raw -match '(?m)^id:\s+(d\d{3})')           { $matches[1] } else { 'd???' }
    $title     = if ($raw -match '(?m)^#\s+(.+)$')                 { $matches[1].Trim() } else { '(no title)' }
    $chosen    = if ($raw -match '\*\*Chosen:\*\*\s+(.+?)\r?\n')   { $matches[1].Trim() } else { '' }
    $rationale = if ($raw -match '\*\*Rationale:\*\*\s+(.+?)\r?\n') { $matches[1].Trim() } else { '' }
    $conf      = if ($raw -match '(?m)^confidence:\s+(\w+)')        { $matches[1] } else { 'unknown' }
    $already   = ($raw -match '<!-- consolidated \d{4}-\d{2}-\d{2} -->')

    # Extract outcome:<x> from any feedback line
    $outcomes = @()
    foreach ($m in [regex]::Matches($raw, 'outcome:(worked|didnt|mixed)')) {
        $outcomes += $m.Groups[1].Value
    }

    return @{
        id = $id; title = $title; chosen = $chosen; rationale = $rationale
        confidence = $conf; outcomes = $outcomes; alreadyConsolidated = $already
        signature = (Get-RecordSignature -Title $title -Chosen $chosen); path = $Path
    }
}

if (-not (Test-Path $projectsRoot)) {
    Write-Host "No projects to consolidate." -ForegroundColor Yellow
    exit 0
}

# --- Pass 1: build per-project bucket + per-signature cross-project map ---
$projectData = @{}              # project → @{ records=@(); guidancePath; recordsDir }
$signatureMap = @{}             # signature → @{ projects = [hashset]; example = $record }

foreach ($projDir in Get-ChildItem -Path $projectsRoot -Directory) {
    $projName = $projDir.Name
    $decDir = Join-Path $projDir.FullName 'decisions'
    $guide = Join-Path $projDir.FullName 'decision-guidance.md'
    if (-not (Test-Path $decDir)) { continue }
    $records = @()
    foreach ($f in (Get-ChildItem -Path $decDir -Filter 'd*.md' -ErrorAction SilentlyContinue)) {
        $rec = Read-RecordDetail -Path $f.FullName
        $records += $rec
        if (-not $signatureMap.ContainsKey($rec.signature)) {
            $signatureMap[$rec.signature] = @{ projects = @{}; example = $rec; positiveProjects = @{} }
        }
        $signatureMap[$rec.signature].projects[$projName] = $true
        if ($rec.outcomes -contains 'worked') {
            $signatureMap[$rec.signature].positiveProjects[$projName] = $true
        }
    }
    $projectData[$projName] = @{ records = $records; guidancePath = $guide; recordsDir = $decDir }
}

# --- Pass 2: write per-project guidance ---
foreach ($projName in $projectData.Keys) {
    $pd = $projectData[$projName]
    $established = @()       # records with worked outcome
    $mistakes = @()          # records with didnt/mixed outcome
    $open = @()              # records with no outcome yet

    foreach ($rec in $pd.records) {
        if ($rec.outcomes -contains 'worked') {
            $established += "- **$($rec.title)** — *chose:* $($rec.chosen) ($($rec.id), conf:$($rec.confidence))"
        } elseif (($rec.outcomes -contains 'didnt') -or ($rec.outcomes -contains 'mixed')) {
            $mistakes += "- **$($rec.title)** — *chose:* $($rec.chosen) ($($rec.id), conf:$($rec.confidence))"
        } else {
            $open += "- **$($rec.title)** — $($rec.id), conf:$($rec.confidence)"
        }
    }

    # Deviations: this project has a pattern that doesn't appear (or differs) at universal
    # For Plan 5 scope: stub the section header. The actual deviation detection runs
    # during /project-init or when guidance is manually edited; consolidation just
    # ensures the section exists if not yet present.
    $deviationsHeader = "## Deviations from universal`n`n_None recorded yet — edit this section to log per-project departures from universal guidance, with their reasons._"

    $body = @"
# Decision guidance — $projName

_Last consolidated: $today_

## Established patterns

$([string]::Join("`n", $established) -or '_None yet._')

## Known mistakes

$([string]::Join("`n", $mistakes) -or '_None yet._')

## Open / under-feedback

$([string]::Join("`n", $open) -or '_None._')

$deviationsHeader
"@

    Set-Content -Path $pd.guidancePath -Value $body -Encoding utf8NoBOM
}

# --- Pass 3: promote cross-project patterns to universal ---
$existingUniversal = Get-Content $universalGuidance -Raw -ErrorAction SilentlyContinue
if (-not $existingUniversal) { $existingUniversal = "# Universal Decision Guidance`n`n" }

foreach ($sig in $signatureMap.Keys) {
    $entry = $signatureMap[$sig]
    if ($entry.positiveProjects.Count -lt 2) { continue }  # threshold
    $line = "- **$($entry.example.title)** — *chose:* $($entry.example.chosen). Observed with positive feedback in: $($entry.positiveProjects.Keys -join ', ')."
    # Idempotency: skip if already present
    if ($existingUniversal -match [regex]::Escape($entry.example.title)) { continue }
    $existingUniversal = $existingUniversal.TrimEnd() + "`n" + $line + "`n"
}
Set-Content -Path $universalGuidance -Value $existingUniversal -Encoding utf8NoBOM

# --- Pass 4: mark records consolidated (idempotency) ---
foreach ($projName in $projectData.Keys) {
    foreach ($rec in $projectData[$projName].records) {
        if ($rec.alreadyConsolidated) { continue }
        Add-Content -Path $rec.path -Value "`n<!-- consolidated $today -->" -Encoding utf8NoBOM
    }
}

Write-Host "Decision consolidation complete." -ForegroundColor Green
```

- [ ] **Step 4: Run to verify pass**

```powershell
pwsh -NoProfile -File scripts\test-consolidate-decisions.ps1
```

Expected: `All tests passed.`.

- [ ] **Step 5: Create `commands/consolidate-decisions.md`**

```markdown
---
description: Distill decision records + feedback into two-layer guidance docs (per-project + universal), promoting patterns with ≥2 projects of positive feedback, recording deviations.
argument-hint: (no arguments)
---

# /consolidate-decisions

Run the consolidation script:

```powershell
& pwsh -NoProfile -File "$HOME/.claude/scripts/consolidate-decisions.ps1"
```

Then echo the result to the user.
```

- [ ] **Step 6: Commit**

```powershell
git add scripts/consolidate-decisions.ps1 commands/consolidate-decisions.md scripts/test-consolidate-decisions.ps1
git commit -m "feat(decision-loop): /consolidate-decisions + threshold-gated universal promotion + tests"
```

---

## Task 5: `/project-init` calibration command

**Files:**
- Create: `commands/project-init.md`

- [ ] **Step 1: Create `commands/project-init.md`** (literal triple-backticks):

```markdown
---
description: Calibrate universal decision guidance for the current project — surface universal rules, capture per-project overrides into projects/<id>/decision-guidance.md.
argument-hint: [--re-calibrate]
---

# /project-init

Initialize (or re-calibrate) per-project decision guidance from the universal layer.

## Steps

1. **Resolve project** via Plan 3 `Resolve-ProjectId` (auto-detect from git remote / cwd).

   ```powershell
   . "$HOME/.claude/scripts/job-lib.ps1"
   $proj = Resolve-ProjectId
   $projGuide = Join-Path $HOME ".claude/knowledge/projects/$proj/decision-guidance.md"
   $uniGuide  = Join-Path $HOME ".claude/knowledge/universal/decision-guidance.md"
   ```

2. **Check state:**
   - If `$projGuide` exists AND `--re-calibrate` is NOT in `$ARGUMENTS`:
     stop with *"Project '<proj>' already initialised. Use --re-calibrate to redo."*
   - Else continue.

3. **Read the universal guidance** and present it to the user verbatim:

   ```powershell
   if (-not (Test-Path $uniGuide)) {
       Write-Host "(no universal decision guidance yet — nothing to calibrate from)" -ForegroundColor Yellow
   } else {
       Write-Host "Universal decision guidance:" -ForegroundColor Cyan
       Get-Content $uniGuide -Raw | Write-Host
   }
   ```

4. **Ask the user:**
   *"For project '<proj>': anything to override or add? Reply with overrides as
   `- universal says: X; here: Y; because: Z` lines, one per override. Or say 'use as-is'."*

   Wait for their answer.

5. **Write `$projGuide`** with the calibration header + their overrides (or a
   "use as-is" note). Ensure the parent directory exists. Format:

   ```markdown
   # Decision guidance — <proj>

   <!-- calibrated <YYYY-MM-DD> from universal -->

   ## Established patterns
   _Populated by /consolidate-decisions._

   ## Known mistakes
   _Populated by /consolidate-decisions._

   ## Open / under-feedback
   _Populated by /consolidate-decisions._

   ## Deviations from universal

   <one bullet per override the user supplied>
   ```

6. **Confirm to the user** the file path written.

## Arguments

$ARGUMENTS
```

- [ ] **Step 2: Commit**

```powershell
git add commands/project-init.md
git commit -m "feat(decision-loop): /project-init calibration command"
```

---

## Task 6: Extend `/job-phase done` with decision retro

**Files:**
- Modify: `commands/job-phase.md`

- [ ] **Step 1: Read the existing `/job-phase` command** to find the `done` subcommand block + the "any final lessons?" prompt.

```powershell
pwsh -NoProfile -Command "Get-Content commands/job-phase.md | Select-String -Pattern 'lesson|done' -Context 1,3 | Select-Object -First 30"
```

- [ ] **Step 2: Locate the `done` block** in `commands/job-phase.md` (the section that handles `/job-phase done` and prompts for lessons). Add a **new step** between "atomic transition" and the existing lesson prompt that lists decisions for retro feedback.

Insert this block (literal triple-backticks in the file):

```markdown
6. **Decision retro** (for `done` transitions only): list the decisions this job
   touched and prompt for late feedback. Non-blocking.

   ```powershell
   . "$HOME/.claude/scripts/job-lib.ps1"
   . "$HOME/.claude/scripts/decisions-lib.ps1"
   $state = Read-CurrentJob
   if (-not $state.job_id) { $jobId = '<JOB_ID>' } else { $jobId = $state.job_id }
   $proj = Resolve-ProjectId
   $decs = Read-Decisions -Project $proj -Job $jobId
   if ($decs.Count -gt 0) {
       Write-Host ""
       Write-Host "This job touched $($decs.Count) decision(s):" -ForegroundColor Cyan
       foreach ($d in $decs) {
           $flagNote = if ($d.flag -ne 'null') { " [$($d.flag)]" } else { '' }
           Write-Host "  $($d.id) ($($d.confidence)) — $($d.title)$flagNote"
       }
       Write-Host "Any retro feedback? Use /decision-feedback <id> ""<text>"" --outcome worked|didnt|mixed." -ForegroundColor Yellow
       Write-Host "(Silence = they worked.)" -ForegroundColor DarkGray
   }
   ```

   Note: `<JOB_ID>` is the just-closed job's id (captured before `Clear-CurrentJob`
   removed the state file). The slash command should substitute the resolved
   `$state.job_id` from BEFORE the state file was cleared.
```

Renumber subsequent steps (the existing "any lessons?" prompt becomes step 7).

- [ ] **Step 3: Commit**

```powershell
git add commands/job-phase.md
git commit -m "feat(decision-loop): extend /job-phase done with decision retro"
```

---

## Task 7: CLAUDE.md capture-rule template

**Files:**
- Create: `references/CLAUDE-decision-capture-rule.md`

- [ ] **Step 1: Create `references/CLAUDE-decision-capture-rule.md`**

```markdown
<!-- decision-capture-rule:v1 -->

## Decision capture (orchestrator)

Whenever you make a **significant decision** that has real alternatives and shapes direction (architecture, scope, approach, tech choice — the kind of thing that would appear in a spec's "Decisions made" section), silently invoke the helper:

```powershell
. "$HOME/.claude/scripts/decisions-lib.ps1"
Add-DecisionRecord `
    -Title  "<one-line decision title>" `
    -Chosen "<what was chosen>" `
    -Alternatives @("<alt-1> — <why-not>", "<alt-2> — <why-not>") `
    -Rationale "<one paragraph why>" `
    -Confidence high|med|low `
    -RevisitIf "<one-line invalidation condition>"
```

Rules:

- **Skip micro-choices** (variable names, which file to edit, formatting). The threshold is "would this decision belong in a spec's Decisions section?".
- **Do not announce the capture to the user** — it's a background log. The Bash invocation shows in the transcript by default; that's expected.
- **If the user has opted out** (`~/.claude/decisions-off` or `~/.claude/knowledge/projects/<project>/decisions-off` exists), the helper no-ops silently — call it anyway, don't gate.
- **Confidence** is your honest self-assessment: `high` = strong evidence + alignment with established guidance; `med` = reasonable choice with real tradeoffs; `low` = best guess under uncertainty.
- **revisit-if** should describe the condition that would make this decision wrong (e.g., "ensemble grows beyond 5 providers", "second machine joins the fleet").

This rule is part of the project's Decision Loop. See `docs/superpowers/specs/2026-05-29-decision-loop-design.md`.
```

- [ ] **Step 2: Commit**

```powershell
git add references/CLAUDE-decision-capture-rule.md
git commit -m "feat(decision-loop): canonical CLAUDE.md decision-capture rule template"
```

---

## Task 8: Bootstrap extensions

**Files:**
- Modify: `scripts/bootstrap.ps1`

- [ ] **Step 1: Read `scripts/bootstrap.ps1`** to find the Plan 4/5 scripts foreach + slash-commands foreach.

- [ ] **Step 2: Add `decisions-lib.ps1` + `consolidate-decisions.ps1` to the scripts foreach.** Find:

```powershell
foreach ($script in @('job-lib.ps1', 'consolidate-lessons.ps1', 'parse-otel.ps1', 'fleet-lib.ps1', 'fleet-doctor.ps1', 'fleet-ensemble.ps1')) {
```

Change to:

```powershell
foreach ($script in @('job-lib.ps1', 'consolidate-lessons.ps1', 'parse-otel.ps1', 'fleet-lib.ps1', 'fleet-doctor.ps1', 'fleet-ensemble.ps1', 'decisions-lib.ps1', 'consolidate-decisions.ps1')) {
```

- [ ] **Step 3: Add the three new commands to the slash-commands foreach.** Find the existing list and append `'decision-feedback.md','consolidate-decisions.md','project-init.md'`:

```powershell
foreach ($cmd in @(
    'log-routing.md','consolidate-routing.md',
    'job-start.md','job-status.md','job-list.md','job-phase.md',
    'job-resume.md','job-lesson.md','consolidate-lessons.md',
    'fleet.md','ensemble.md','research.md',
    'decision-feedback.md','consolidate-decisions.md','project-init.md'
)) {
```

- [ ] **Step 4: Add new bootstrap steps** for the universal guidance seed + CLAUDE.md rule insertion. Insert AFTER the existing Plan 3 KB-seed step (where universal/routing.md/user-prefs.md/etc. get seeded). The block:

```powershell
# --- Step 5e: Seed universal decision guidance ---
Write-Step "Seeding universal decision guidance"
$uniDecGuide = Join-Path $claudeDir 'knowledge/universal/decision-guidance.md'
if (-not (Test-Path $uniDecGuide)) {
    if ($DryRun) {
        Write-Ok "[dry-run] would seed $uniDecGuide"
    } else {
        Set-Content -Path $uniDecGuide -Value "# Universal Decision Guidance`n`n_Populated by /consolidate-decisions over time._`n" -Encoding utf8NoBOM
        Write-Ok "seeded universal/decision-guidance.md"
    }
} else {
    Write-Skip "universal decision guidance already present"
}

# --- Step 5f: Insert decision-capture rule into project root CLAUDE.md ---
Write-Step "Wiring decision-capture rule into project CLAUDE.md"
$claudeMd = Join-Path $repoRoot 'CLAUDE.md'
$ruleSrc = Join-Path $repoRoot 'references\CLAUDE-decision-capture-rule.md'
$ruleMarker = '<!-- decision-capture-rule:v1 -->'
if (-not (Test-Path $ruleSrc)) {
    Write-Warn "rule source $ruleSrc missing; skipping CLAUDE.md update"
} elseif (-not (Test-Path $claudeMd)) {
    if ($DryRun) {
        Write-Ok "[dry-run] would create $claudeMd and insert capture rule"
    } else {
        $ans = Read-Host "    Project root has no CLAUDE.md. Create one with the decision-capture rule? [Y/n]"
        if ($ans -ne 'n' -and $ans -ne 'N') {
            Copy-Item $ruleSrc $claudeMd
            Write-Ok "created CLAUDE.md with the capture rule"
        } else {
            Write-Skip "kept CLAUDE.md absent"
        }
    }
} else {
    $existing = Get-Content $claudeMd -Raw
    if ($existing -match [regex]::Escape($ruleMarker)) {
        Write-Skip "capture rule already present in CLAUDE.md"
    } elseif ($DryRun) {
        Write-Ok "[dry-run] would append capture rule to $claudeMd"
    } else {
        $ruleText = Get-Content $ruleSrc -Raw
        Add-Content -Path $claudeMd -Value "`n`n$ruleText" -Encoding utf8NoBOM
        Write-Ok "appended capture rule to CLAUDE.md"
    }
}
```

- [ ] **Step 5: Dry-run**

```powershell
pwsh -NoProfile -File scripts\bootstrap.ps1 -DryRun
```

Expected: would-deploy lines for the two new scripts, three new commands, the universal guidance seed, and the CLAUDE.md rule. No errors.

- [ ] **Step 6: Real run**

```powershell
pwsh -NoProfile -File scripts\bootstrap.ps1
```

Expected: all the above deploy. The CLAUDE.md prompt may appear (answer Y to create one for this repo, or skip).

- [ ] **Step 7: Verify**

```powershell
Get-ChildItem $HOME\.claude\scripts\decisions-lib.ps1, $HOME\.claude\scripts\consolidate-decisions.ps1, $HOME\.claude\commands\decision-feedback.md, $HOME\.claude\commands\consolidate-decisions.md, $HOME\.claude\commands\project-init.md, $HOME\.claude\knowledge\universal\decision-guidance.md | Select-Object FullName
```

- [ ] **Step 8: Commit**

```powershell
git add scripts/bootstrap.ps1
git commit -m "feat(decision-loop): bootstrap deploys libs + commands + universal seed + CLAUDE.md rule"
```

---

## Task 9: README + end-to-end smoke

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Replace the `## Coming in Plan 5b / 5c` section** in `README.md` with:

```markdown
## What you get (Decision Loop)

A self-improvement loop on top of Plan 3's KB. Every significant decision I make
is auto-captured as a structured record (decision · alternatives · rationale ·
my confidence · revisit-if). Two layers consolidate over time:

- **Per-project guidance** — `~/.claude/knowledge/projects/<id>/decision-guidance.md`
- **Universal guidance** — `~/.claude/knowledge/universal/decision-guidance.md`
  (a pattern only promotes here once it has positive feedback in ≥2 projects)

Commands:
- `/decision-feedback <id> "<text>" [--outcome worked|didnt|mixed] [--urgent]` —
  attach human feedback. Silence = approval; negative outcome flags the record.
- `/consolidate-decisions` — distill records + feedback into the guidance docs,
  recording deviations + their reasons.
- `/project-init [--re-calibrate]` — on a new project, surface universal
  guidance and capture per-project overrides.
- `/job-phase done` now lists the just-closed job's decisions and prompts for
  retro feedback (non-blocking).

Capture is **discipline-enforced**, not magical — the rule lives in this
project's `CLAUDE.md` and is always loaded into context. Opt-out at any time
via `~/.claude/decisions-off` (global) or
`~/.claude/knowledge/projects/<id>/decisions-off` (per-project).

See [`docs/superpowers/specs/2026-05-29-decision-loop-design.md`](docs/superpowers/specs/2026-05-29-decision-loop-design.md).

## Coming in Plan 5b / 5c

6 Thinking Hats (each model wears a hat) and LLM Council (models critique each
other's outputs) — thin presets built on the Plan 5 ensemble primitive.
```

- [ ] **Step 2: Run the full test suite**

```powershell
pwsh -NoProfile -File scripts\test-decisions-lib.ps1
pwsh -NoProfile -File scripts\test-consolidate-decisions.ps1
pwsh -NoProfile -File scripts\test-fleet-lib.ps1
pwsh -NoProfile -File scripts\test-fleet-ensemble.ps1
pwsh -NoProfile -File scripts\test-fleet-dispatch.ps1
pwsh -NoProfile -File scripts\test-fleet-doctor.ps1
pwsh -NoProfile -File scripts\test-job-lib.ps1
pwsh -NoProfile -File scripts\test-jobs.ps1
pwsh -NoProfile -File scripts\test-hook.ps1
pwsh -NoProfile -File scripts\test-otel-parser.ps1
pwsh -NoProfile -File scripts\test-consolidate-lessons.ps1
python -m pytest dashboard/tests/ -q
```

Expected: every PS script ends with `All tests passed.`; pytest all passed.

- [ ] **Step 3: End-to-end smoke (manual)** — from a Claude Code session in the repo, after bootstrap:

```
# 1. Make a decision (Claude does this silently per CLAUDE.md rule). Verify:
Get-ChildItem $HOME\.claude\knowledge\projects\coding-agent-orchestrator\decisions\
# Expect: at least one dNNN-*.md file appears as work progresses.

# 2. Attach feedback
/decision-feedback d001 "this paid off in Plan 6" --outcome worked

# 3. Run consolidation
/consolidate-decisions
# Expect: projects/coding-agent-orchestrator/decision-guidance.md updated;
#         universal/decision-guidance.md updated if ≥2 projects show the pattern.

# 4. Project-init on a fresh project (in a different repo)
cd D:\path\to\other\repo
/project-init
# Expect: universal guidance shown; your overrides written to that project's
# decision-guidance.md.

# 5. End-of-job retro
/job-start "smoke decision loop"
# ... do work that yields decisions ...
/job-phase done
# Expect: the retro lists decisions made in this job.
```

- [ ] **Step 4: Commit + tag**

```powershell
git add README.md
git commit -m "docs: Decision Loop README"
git tag decision-loop-complete -m "Decision Loop: auto-captured records + two-layer self-improvement"
```

---

## End of plan
