# Routing Slice 4 — Calibration Mode Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `/route --calibrate` mode that dispatches *all* candidates for a capability on one prompt, judge-scores each, displays them side-by-side, and records a per-candidate human rating to seed the learning loop.

**Architecture:** Extract the per-candidate dispatch→grade→journal body out of `Invoke-RoutedCapability` into a shared `Invoke-RoutedCandidate` helper (regression-first). A new `routing-calibrate.ps1` adds `Invoke-CapabilityCalibration` (fan-out, no short-circuit) and `Add-CalibrationRatings` (batch ratings). `commands/route.md` gains a two-phase `--calibrate` mode. Bootstrap deploys the new lib.

**Tech Stack:** PowerShell 7 (pwsh), JSONL stores, existing fleet/tools/routing libs. Tests use the `Check($n,$c)` harness with scriptblock-injected dispatchers/graders (zero real model calls).

**Spec:** `docs/superpowers/specs/2026-06-09-routing-s4-calibration-mode-design.md`

## File Structure

- **`scripts/routing-dispatch.ps1`** *(modify)* — add `Invoke-RoutedCandidate`; refactor `Invoke-RoutedCapability` to call it. Observable contract unchanged.
- **`scripts/routing-calibrate.ps1`** *(create)* — `Invoke-CapabilityCalibration` + `Add-CalibrationRatings`. Header dot-sources `routing-dispatch.ps1` (pulls the whole chain: routing-lib → routing-learn + fleet-lib).
- **`scripts/test-routing-calibrate.ps1`** *(create)* — fan-out, no-candidate, journaling, tier-cap, batch-rating checks.
- **`scripts/test-routing-dispatch.ps1`** *(unchanged)* — the 31-check regression net for the extraction; must stay green.
- **`scripts/bootstrap.ps1`** *(modify)* — add `routing-calibrate.ps1` to the libs manifest (line ~250).
- **`scripts/test-bootstrap.ps1`** *(modify)* — assert the dry-run deploys `routing-calibrate.ps1`.
- **`commands/route.md`** *(modify)* — two-phase `--calibrate` mode.

---

### Task 1: Extract `Invoke-RoutedCandidate` (regression-first refactor)

**Files:**
- Modify: `scripts/routing-dispatch.ps1` (add helper before `Invoke-RoutedCapability`; rewrite the loop body of `Invoke-RoutedCapability`)
- Test: `scripts/test-routing-dispatch.ps1` (existing — the regression net, do not edit)

- [ ] **Step 1: Run the existing suite to confirm a green baseline**

Run: `pwsh -NoProfile -File scripts/test-routing-dispatch.ps1`
Expected: all PASS, exit 0 (31 checks).

- [ ] **Step 2: Add `Invoke-RoutedCandidate` above `Invoke-RoutedCapability`**

Insert this function immediately before `function Invoke-RoutedCapability {` in `scripts/routing-dispatch.ps1`:

```powershell
function Invoke-RoutedCandidate {
    <# Dispatch ONE candidate, grade it with the effective grader, journal the row, and
       return both the attempt summary and the raw result. Shared by Invoke-RoutedCapability
       (escalate-and-stop) and Invoke-CapabilityCalibration (fan-out). The caller decides
       whether to stop on a pass. -EffGrader is the already-resolved grader ($null = heuristic
       default). -Dispatcher is test injection. #>
    param(
        [Parameter(Mandatory)][string]$Capability,
        [Parameter(Mandatory)]$Candidate,
        [Parameter(Mandatory)][string]$Prompt,
        [scriptblock]$EffGrader,
        [scriptblock]$Dispatcher,
        [int]$TimeoutS = 120,
        [string]$ToolsPath = (Join-Path $HOME '.claude/tools.yaml'),
        [string]$FleetPath = (Join-Path $HOME '.claude/fleet.yaml'),
        [string]$JournalPath = (Join-Path $HOME '.claude/routing-journal.jsonl')
    )
    $c = $Candidate
    # Slice 2 dispatches only cli tools + fleet models. Skip other tool kinds.
    if ($c.source -eq 'tools' -and $c.kind -ne 'cli') {
        $reason = "unsupported kind $($c.kind) in Slice 2"
        $attempt = [pscustomobject]@{ candidate=$c.name; source=$c.source; kind=$c.kind; cost_tier=$c.cost_tier; passed=$false; score=0.0; reason=$reason; duration_s=0 }
        Write-RoutingJournalLine -Capability $Capability -Candidate $c.name -Source $c.source -Kind $c.kind -CostTier $c.cost_tier -ExitCode -1 -DurationS 0 -Passed $false -Score 0.0 -Reason $reason -JournalPath $JournalPath
        return @{ attempt = $attempt; result = @{ stdout=''; stderr=''; exit_code=-1; duration_s=0 } }
    }

    # Dispatch (injected for tests, else real).
    try {
        if ($Dispatcher) {
            $result = & $Dispatcher $c $Prompt
        } elseif ($c.source -eq 'tools') {
            $tool = Read-Tools -Path $ToolsPath | Where-Object { $_.name -eq $c.name } | Select-Object -First 1
            $result = Invoke-Tool -Tool $tool -Prompt $Prompt -TimeoutS $TimeoutS
        } else {
            $result = Invoke-Fleet -Name $c.name -Prompt $Prompt -Path $FleetPath -NoJournal
        }
    } catch {
        $result = @{ stdout=''; stderr=$_.Exception.Message; exit_code=-1; duration_s=0 }
    }

    # Verify (effective grader: resolved -Grader/-Judge, else heuristic default).
    try {
        if ($EffGrader) { $verdict = & $EffGrader -Capability $Capability -Result $result }
        else            { $verdict = Test-RoutingOutputHeuristic -Capability $Capability -Result $result }
    } catch {
        $verdict = @{ passed=$false; score=0.0; reason="grader error: $($_.Exception.Message)" }
    }
    $graderTag = if ($verdict.grader) { [string]$verdict.grader } else { 'heuristic' }

    $attempt = [pscustomobject]@{
        candidate=$c.name; source=$c.source; kind=$c.kind; cost_tier=$c.cost_tier
        passed=[bool]$verdict.passed; score=[double]$verdict.score; reason=[string]$verdict.reason
        duration_s=[int]$result.duration_s
    }
    Write-RoutingJournalLine -Capability $Capability -Candidate $c.name -Source $c.source -Kind $c.kind `
        -CostTier $c.cost_tier -ExitCode ([int]$result.exit_code) -DurationS ([int]$result.duration_s) `
        -Passed ([bool]$verdict.passed) -Score ([double]$verdict.score) -Reason ([string]$verdict.reason) `
        -Grader $graderTag -JournalPath $JournalPath
    return @{ attempt = $attempt; result = $result }
}
```

- [ ] **Step 3: Replace the `foreach` loop body in `Invoke-RoutedCapability`**

In `Invoke-RoutedCapability`, replace the entire `foreach ($c in $candidates) { ... }` block (the unsupported-kind skip, dispatch try/catch, verify try/catch, `$graderTag`, `$attempts.Add`, journal call, and `if ($verdict.passed) { return … }`) with this shorter loop that delegates to the helper:

```powershell
    foreach ($c in $candidates) {
        $rc = Invoke-RoutedCandidate -Capability $Capability -Candidate $c -Prompt $Prompt `
            -EffGrader $effGrader -Dispatcher $Dispatcher -TimeoutS $TimeoutS `
            -ToolsPath $ToolsPath -FleetPath $FleetPath -JournalPath $JournalPath
        [void]$attempts.Add($rc.attempt)
        if ($rc.attempt.passed) {
            return [pscustomobject]@{ status='passed'; capability=$Capability; winner=$c.name; result=$rc.result; attempts=$attempts.ToArray() }
        }
    }
```

Leave everything else in `Invoke-RoutedCapability` unchanged: the param block, the `Select-Capability` call, the `$effGrader = if ($Grader) {…} elseif ($Judge) {…} else {$null}` resolution, the `$attempts = [System.Collections.ArrayList]@()` line, the `no-candidate` early return, and the final `escalate-to-conductor` return.

- [ ] **Step 4: Run the regression suite — it must still pass unchanged**

Run: `pwsh -NoProfile -File scripts/test-routing-dispatch.ps1`
Expected: all PASS, exit 0 (same 31 checks: `escalates to 3rd candidate`, `cheapest wins first`, `custom grader overrides`, `non-cli kind skipped`, `loop journaled 3 rows`, etc.).

If any check fails, the extraction changed observable behavior — diff the attempt object fields and journal call args against the original body until green. Do not edit the test.

- [ ] **Step 5: Commit**

```bash
git add scripts/routing-dispatch.ps1
git commit -m "refactor(routing): extract Invoke-RoutedCandidate shared by dispatch + calibration

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: `Invoke-CapabilityCalibration` (fan-out, no short-circuit)

**Files:**
- Create: `scripts/routing-calibrate.ps1`
- Create: `scripts/test-routing-calibrate.ps1`

- [ ] **Step 1: Create the test file with the fan-out checks**

Create `scripts/test-routing-calibrate.ps1`:

```powershell
#!/usr/bin/env pwsh
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/routing-calibrate.ps1"

$script:fail = 0
function Check($n,$c){ if($c){Write-Host "PASS: $n"} else {Write-Host "FAIL: $n"; $script:fail++} }

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("routing-cal-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null

try {
    # ---- fixtures: tools.yaml (one non-cli kind) + fleet.yaml (local/free/paid for code-gen) ----
    $toolsYaml = @"
tools:
  - name: docling
    capability: pdf-extract
    kind: python
    enabled: true
    cost_tier: local
    module: docling.document_converter
"@
    $toolsPath = Join-Path $tmp 'tools.yaml'
    Set-Content -Path $toolsPath -Value $toolsYaml -Encoding utf8

    $fleetYaml = @"
general_capabilities: [code-gen]

providers:
  - name: local-a
    kind: cli
    enabled: true
    cost_tier: local
    command_template: 'x "{{prompt}}"'
  - name: free-b
    kind: cli
    enabled: true
    cost_tier: free
    command_template: 'x "{{prompt}}"'
  - name: paid-c
    kind: cli
    enabled: true
    cost_tier: paid
    command_template: 'x "{{prompt}}"'
"@
    $fleetPath = Join-Path $tmp 'fleet.yaml'
    Set-Content -Path $fleetPath -Value $fleetYaml -Encoding utf8

    $journal = Join-Path $tmp 'cal-journal.jsonl'
    $common  = @{ ToolsPath = $toolsPath; FleetPath = $fleetPath; JournalPath = $journal }

    # ===== fan-out: every candidate dispatched even though the first one passes =====
    $script:calls = 0
    $dispAll = { param($c,$p) $script:calls++; @{ stdout="out-$($c.name)"; stderr=''; exit_code=0; duration_s=1 } }

    # default --max-tier paid so all three fleet candidates are in scope
    $o1 = Invoke-CapabilityCalibration -Capability 'code-gen' -Prompt 'do x' -Dispatcher $dispAll -MaxCostTier 'paid' @common
    Check 'calibrated status'            ($o1.status -eq 'calibrated')
    Check 'fan-out dispatched all 3'     ($script:calls -eq 3)
    Check 'returns one row per candidate'($o1.candidates.Count -eq 3)
    Check 'all rows passed (heuristic)'  (@($o1.candidates | Where-Object { -not $_.passed }).Count -eq 0)
    Check 'rows carry an excerpt'        (-not [string]::IsNullOrWhiteSpace($o1.candidates[0].excerpt))
    Check 'journal has 3 rows'           (@(Get-Content $journal).Count -eq 3)

    # ===== tier cap: default free excludes the paid candidate =====
    $script:calls = 0
    $o2 = Invoke-CapabilityCalibration -Capability 'code-gen' -Prompt 'x' -Dispatcher $dispAll -MaxCostTier 'free' @common
    Check 'tier cap free excludes paid'  ($o2.candidates.Count -eq 2 -and @($o2.candidates | Where-Object { $_.cost_tier -eq 'paid' }).Count -eq 0)

    # ===== no-candidate =====
    $o3 = Invoke-CapabilityCalibration -Capability 'nope-cap' -Prompt 'x' -Dispatcher $dispAll @common
    Check 'unknown cap -> no-candidate'  ($o3.status -eq 'no-candidate' -and $o3.candidates.Count -eq 0)

    # ===== injected judge tags journal rows grader=llm-judge =====
    $judgeDisp = { param($model,$prompt) '{"score": 0.8, "reason": "good"}' }
    $journal2 = Join-Path $tmp 'cal-journal2.jsonl'
    $common2  = @{ ToolsPath = $toolsPath; FleetPath = $fleetPath; JournalPath = $journal2 }
    $o4 = Invoke-CapabilityCalibration -Capability 'code-gen' -Prompt 'x' -Dispatcher $dispAll `
            -MaxCostTier 'paid' -Judge -JudgeModel 'fake-judge' -JudgeDispatcher $judgeDisp @common2
    $rows4 = @(Get-Content $journal2 | ForEach-Object { $_ | ConvertFrom-Json })
    Check 'judge tags rows llm-judge'    (@($rows4 | Where-Object { $_.grader -eq 'llm-judge' }).Count -eq 3)
    Check 'judge score flows to rows'    ([math]::Abs([double]$o4.candidates[0].score - 0.8) -lt 0.001)

    Write-Host ""
    if ($script:fail -gt 0) { Write-Host "$script:fail check(s) FAILED"; exit 1 }
    Write-Host "All routing-calibrate checks passed."; exit 0
}
finally {
    Remove-Item -Recurse -Force -Path $tmp -ErrorAction SilentlyContinue
}
```

- [ ] **Step 2: Run the test to verify it fails (function not defined)**

Run: `pwsh -NoProfile -File scripts/test-routing-calibrate.ps1`
Expected: FAIL — `The term 'Invoke-CapabilityCalibration' is not recognized` (the file `routing-calibrate.ps1` does not exist yet, so the dot-source at the top errors).

- [ ] **Step 3: Create `routing-calibrate.ps1` with `Invoke-CapabilityCalibration`**

Create `scripts/routing-calibrate.ps1`:

```powershell
#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Capability-routing calibration (Slice 4). Fans out across ALL candidates for a capability
  on one prompt, judge-scores each, and records per-candidate human ratings. The exploration
  twin of Slice 2's escalate-and-stop dispatch.
.DESCRIPTION
  Dot-sources routing-dispatch.ps1 (which pulls routing-lib -> routing-learn + fleet-lib), so
  Select-Capability, Invoke-RoutedCandidate, Get-LlmJudgeGrader, and Add-CapabilityRating are
  all in scope. Ratings persist to the GitHub-backed knowledge repo; the journal stays local.
  See docs/superpowers/specs/2026-06-09-routing-s4-calibration-mode-design.md.
#>

. "$PSScriptRoot/routing-dispatch.ps1"

function Invoke-CapabilityCalibration {
    <# Dispatch EVERY candidate serving -Capability (within the tier cap), grade each, journal
       each, and return all rows ranked by score desc. Never short-circuits. -Grader wins; else
       -Judge wires the LLM-judge; else heuristic. -Dispatcher/-JudgeDispatcher are test injection. #>
    param(
        [Parameter(Mandatory)][string]$Capability,
        [Parameter(Mandatory)][string]$Prompt,
        [ValidateSet('local','free','paid')][string]$MaxCostTier,
        [switch]$RequireLocal,
        [int]$TimeoutS = 120,
        [scriptblock]$Grader,
        [scriptblock]$Dispatcher,
        [switch]$Judge,
        [string]$JudgeModel,
        [scriptblock]$JudgeDispatcher,
        [int]$ExcerptChars = 280,
        [string]$ToolsPath = (Join-Path $HOME '.claude/tools.yaml'),
        [string]$FleetPath = (Join-Path $HOME '.claude/fleet.yaml'),
        [string]$JournalPath = (Join-Path $HOME '.claude/routing-journal.jsonl')
    )
    $sel = @{ Capability = $Capability; ToolsPath = $ToolsPath; FleetPath = $FleetPath }
    if ($RequireLocal) { $sel['RequireLocal'] = $true }
    if ($MaxCostTier)  { $sel['MaxCostTier']  = $MaxCostTier }
    $candidates = @(Select-Capability @sel)

    # Same grader resolution as Invoke-RoutedCapability: -Grader wins; -Judge wires the judge; else heuristic.
    $effGrader = if ($Grader) { $Grader }
                 elseif ($Judge) { Get-LlmJudgeGrader -JudgeModel $JudgeModel -FleetPath $FleetPath -JudgeDispatcher $JudgeDispatcher }
                 else { $null }

    if ($candidates.Count -eq 0) {
        return [pscustomobject]@{ status='no-candidate'; capability=$Capability; candidates=@() }
    }

    $rows = [System.Collections.ArrayList]@()
    foreach ($c in $candidates) {
        $rc = Invoke-RoutedCandidate -Capability $Capability -Candidate $c -Prompt $Prompt `
            -EffGrader $effGrader -Dispatcher $Dispatcher -TimeoutS $TimeoutS `
            -ToolsPath $ToolsPath -FleetPath $FleetPath -JournalPath $JournalPath
        $excerpt = (([string]$rc.result.stdout) -replace '\s+', ' ').Trim()
        if ($excerpt.Length -gt $ExcerptChars) { $excerpt = $excerpt.Substring(0, $ExcerptChars) }
        [void]$rows.Add([pscustomobject]@{
            candidate  = $rc.attempt.candidate; source = $rc.attempt.source; cost_tier = $rc.attempt.cost_tier
            passed     = $rc.attempt.passed;     score  = $rc.attempt.score;  reason    = $rc.attempt.reason
            duration_s = $rc.attempt.duration_s; excerpt = $excerpt
        })
    }
    $ranked = @($rows.ToArray() | Sort-Object -Property score -Descending)
    return [pscustomobject]@{ status='calibrated'; capability=$Capability; candidates=$ranked }
}
```

- [ ] **Step 4: Run the test to verify the fan-out checks pass**

Run: `pwsh -NoProfile -File scripts/test-routing-calibrate.ps1`
Expected: all PASS, exit 0 (`fan-out dispatched all 3`, `tier cap free excludes paid`, `unknown cap -> no-candidate`, `judge tags rows llm-judge`, `judge score flows to rows`).

- [ ] **Step 5: Commit**

```bash
git add scripts/routing-calibrate.ps1 scripts/test-routing-calibrate.ps1
git commit -m "feat(routing): Invoke-CapabilityCalibration fans out over all candidates

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: `Add-CalibrationRatings` (batch per-candidate ratings)

**Files:**
- Modify: `scripts/routing-calibrate.ps1` (append the function)
- Modify: `scripts/test-routing-calibrate.ps1` (append checks before the final tally)

- [ ] **Step 1: Append batch-rating checks to the test**

In `scripts/test-routing-calibrate.ps1`, insert this block immediately **before** the `Write-Host ""` / final-tally lines:

```powershell
    # ===== Add-CalibrationRatings: batch verdicts, source re-derivation, skip unknown/bad =====
    $ratings = Join-Path $tmp 'routing-ratings.jsonl'
    $res = Add-CalibrationRatings -Capability 'code-gen' `
        -Spec 'local-a=good free-b=bad ghost=good free-b=sideways' `
        -ToolsPath $toolsPath -FleetPath $fleetPath -RatingsPath $ratings `
        -Timestamp '2026-06-09T00:00:00.0000000-06:00'
    Check 'applied 2 (local-a, free-b)'  ($res.applied -eq 2)
    Check 'skipped 2 (ghost, sideways)'  ($res.skipped -eq 2)
    $rr = @(Get-Content $ratings | ForEach-Object { $_ | ConvertFrom-Json })
    Check 'ratings file has 2 rows'      ($rr.Count -eq 2)
    Check 'good row recorded'            (@($rr | Where-Object { $_.candidate -eq 'local-a' -and $_.rating -eq 'good' }).Count -eq 1)
    Check 'bad row recorded'             (@($rr | Where-Object { $_.candidate -eq 'free-b' -and $_.rating -eq 'bad' }).Count -eq 1)
    Check 'source re-derived as fleet'   (@($rr | Where-Object { $_.source -eq 'fleet' }).Count -eq 2)
```

- [ ] **Step 2: Run the test to verify the new checks fail**

Run: `pwsh -NoProfile -File scripts/test-routing-calibrate.ps1`
Expected: FAIL — `The term 'Add-CalibrationRatings' is not recognized`.

- [ ] **Step 3: Append `Add-CalibrationRatings` to `routing-calibrate.ps1`**

Append to `scripts/routing-calibrate.ps1`:

```powershell
function Add-CalibrationRatings {
    <# Apply a batch of per-candidate verdicts from a "name=good name=bad ..." spec. Re-derives
       each candidate's source via Select-Capability (no dispatch), then calls Add-CapabilityRating.
       Tokens that are malformed, have a non good|bad verdict, or name an unknown candidate are
       warned and skipped. Returns @{ applied; skipped }. #>
    param(
        [Parameter(Mandatory)][string]$Capability,
        [Parameter(Mandatory)][string]$Spec,
        [string]$Note = '',
        [string]$ToolsPath = (Join-Path $HOME '.claude/tools.yaml'),
        [string]$FleetPath = (Join-Path $HOME '.claude/fleet.yaml'),
        [string]$RatingsPath = (Join-Path $HOME '.claude/knowledge/universal/routing-ratings.jsonl'),
        [string]$Timestamp
    )
    $cands = @(Select-Capability -Capability $Capability -ToolsPath $ToolsPath -FleetPath $FleetPath)
    $srcByName = @{}
    foreach ($c in $cands) { $srcByName[$c.name] = $c.source }

    $applied = 0; $skipped = 0
    foreach ($tok in @($Spec -split '\s+' | Where-Object { $_ -ne '' })) {
        $kv = $tok -split '=', 2
        if ($kv.Count -ne 2) { Write-Warning "calibration rating: malformed token '$tok'"; $skipped++; continue }
        $name = $kv[0]; $rating = $kv[1].ToLower()
        if ($rating -ne 'good' -and $rating -ne 'bad') { Write-Warning "calibration rating: bad verdict in '$tok' (use good|bad)"; $skipped++; continue }
        if (-not $srcByName.ContainsKey($name)) { Write-Warning "calibration rating: '$name' is not a candidate for $Capability"; $skipped++; continue }
        $addArgs = @{ Capability=$Capability; Candidate=$name; Source=$srcByName[$name]; Rating=$rating; Note=$Note; RatingsPath=$RatingsPath }
        if ($Timestamp) { $addArgs['Timestamp'] = $Timestamp }
        Add-CapabilityRating @addArgs
        $applied++
    }
    return @{ applied = $applied; skipped = $skipped }
}
```

- [ ] **Step 4: Run the test to verify all checks pass**

Run: `pwsh -NoProfile -File scripts/test-routing-calibrate.ps1`
Expected: all PASS, exit 0 (`applied 2`, `skipped 2`, `ratings file has 2 rows`, `source re-derived as fleet`, plus the Task 2 checks).

- [ ] **Step 5: Commit**

```bash
git add scripts/routing-calibrate.ps1 scripts/test-routing-calibrate.ps1
git commit -m "feat(routing): Add-CalibrationRatings records batch per-candidate verdicts

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: Bootstrap deploys `routing-calibrate.ps1`

**Files:**
- Modify: `scripts/test-bootstrap.ps1` (add one assert)
- Modify: `scripts/bootstrap.ps1` (line ~250 libs manifest)

- [ ] **Step 1: Add the failing bootstrap assert**

In `scripts/test-bootstrap.ps1`, alongside the existing `routing-learn.ps1` deploy assertion (search for `routing-learn\.ps1`), add:

```powershell
Assert "would deploy routing-calibrate.ps1" ($out -match 'routing-calibrate\.ps1')
```

(Use the same `$out`/`Assert` variables the neighboring assertions use — match the existing call style exactly.)

- [ ] **Step 2: Run the bootstrap test to verify it fails**

Run: `pwsh -NoProfile -File scripts/test-bootstrap.ps1`
Expected: FAIL on `would deploy routing-calibrate.ps1` (the lib is not yet in the manifest, so the dry-run stdout does not mention it).

- [ ] **Step 3: Add `routing-calibrate.ps1` to the libs manifest**

In `scripts/bootstrap.ps1` line ~250, in the `foreach ($script in @( … ))` libs array, add `'routing-calibrate.ps1',` immediately after `'routing-learn.ps1',`:

```powershell
foreach ($script in @('job-lib.ps1', 'consolidate-lessons.ps1', 'parse-otel.ps1', 'fleet-lib.ps1', 'fleet-doctor.ps1', 'fleet-ensemble.ps1', 'routing-lib.ps1', 'routing-dispatch.ps1', 'routing-learn.ps1', 'routing-calibrate.ps1', 'six-hats-lib.ps1', 'council-lib.ps1', 'code-lib.ps1', 'kb-lib.ps1', 'decisions-lib.ps1', 'consolidate-decisions.ps1', 'cost-lib.ps1', 'runs-lib.ps1', 'statusline-feed.ps1', 'fleet-runs-bridge.ps1', 'idea-lib.ps1')) {
```

- [ ] **Step 4: Run the bootstrap test to verify it passes**

Run: `pwsh -NoProfile -File scripts/test-bootstrap.ps1`
Expected: all PASS, exit 0 (now 16 asserts).

- [ ] **Step 5: Commit**

```bash
git add scripts/bootstrap.ps1 scripts/test-bootstrap.ps1
git commit -m "feat(routing): bootstrap deploys routing-calibrate.ps1

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 5: `/route --calibrate` command (two-phase)

**Files:**
- Modify: `commands/route.md`

- [ ] **Step 1: Update the front-matter description + argument-hint**

Replace the `description:` and `argument-hint:` lines in `commands/route.md` front-matter with:

```yaml
description: Recommend OR dispatch the optimal capability (tool or model) for a need — cheapest capable tier first ("optimal, not best"), with LEARNED quality from your ratings + an LLM-judge. --run dispatches & verifies; --rate good|bad records the last run; --judge forces judging; --calibrate dispatches ALL candidates on one prompt, judge-scores each, and collects a per-candidate rating to seed learning.
argument-hint: "<capability>" [--max-tier local|free|paid] [--local] [--run "<prompt>"] [--judge] | --rate good|bad [note] | --calibrate "<capability>" "<prompt>" | --calibrate "<capability>" --rate "<cand>=good|bad ..."
```

- [ ] **Step 2: Add the load line and the two `--calibrate` phases**

In `commands/route.md`, after the existing step 4 (`--rate good|bad`) and before the renumbered error step, insert a new section. Note `routing-calibrate.ps1` dot-sources `routing-dispatch.ps1`, so loading it alone pulls the full chain:

````markdown
5. **With `--calibrate "<capability>" "<prompt>"` (calibration — Phase 1: sample & judge):**

   Dispatches **every** candidate for the capability on one prompt, judge-scores each, and shows
   them side-by-side so you can rate them. Default tier cap is `free` (local+free); include paid
   candidates only with an explicit `--max-tier paid`.

   ```powershell
   . "$HOME/.claude/scripts/routing-calibrate.ps1"
   $tier = if ($maxTier) { $maxTier } else { 'free' }   # calibration defaults to free, not paid
   $prev = @{ Capability = '<capability>'; MaxCostTier = $tier }
   if ($local) { $prev['RequireLocal'] = $true }
   $preview = Select-Capability @prev
   if (-not $preview -or $preview.Count -eq 0) {
       Write-Host "No candidate serves '<capability>'. Known: $((Get-KnownCapabilities) -join ', ')"
   } else {
       Write-Host ("Calibrating <capability>: will dispatch {0} candidate(s) (tiers: {1})." -f `
           $preview.Count, (($preview.cost_tier | Sort-Object -Unique) -join ','))
       $opt = @{ Capability = '<capability>'; Prompt = '<prompt>'; MaxCostTier = $tier }
       if ($local) { $opt['RequireLocal'] = $true }
       # Cost-optimal judging: on if --judge OR a free local judge model is available.
       if ($judge -or (Get-CheapestLocalModel)) { $opt['Judge'] = $true }
       $cal = Invoke-CapabilityCalibration @opt
       $cal.candidates | Format-Table `
           @{n='candidate'; e={$_.candidate}}, @{n='tier'; e={$_.cost_tier}},
           @{n='judge'; e={ '{0:0.00}' -f $_.score }}, @{n='ok'; e={ if($_.passed){'PASS'}else{'fail'} }},
           @{n='excerpt'; e={$_.excerpt}} -AutoSize -Wrap
       $names = ($cal.candidates | ForEach-Object { "$($_.candidate)=good" }) -join ' '
       Write-Host ""
       Write-Host "Rate them (edit good/bad), then run:"
       Write-Host "  /route --calibrate `"<capability>`" --rate `"$names`""
       Write-Host ("Logged {0} calibration attempt(s) to ~/.claude/routing-journal.jsonl." -f $cal.candidates.Count)
   }
   ```

   Show the table to the user, then the pre-filled rate command so they only flip good→bad where
   an output was poor.

6. **With `--calibrate "<capability>" --rate "<cand>=good|bad ..."` (calibration — Phase 2: record verdicts):**

   Detected when both `--calibrate` and `--rate` are present. Records one rating per candidate.

   ```powershell
   . "$HOME/.claude/scripts/routing-calibrate.ps1"
   $res = Add-CalibrationRatings -Capability '<capability>' -Spec '<spec>'
   Write-Host ("Recorded {0} rating(s) ({1} skipped). They will weight future routing." -f $res.applied, $res.skipped)
   ```

   The ratings land in the GitHub-backed knowledge repo (`routing-ratings.jsonl`) — push it with
   the standing knowledge backup so they roll to any machine.
````

- [ ] **Step 3: Renumber the trailing error step**

The old final step ("On any error … `bootstrap.ps1 -Force`") becomes **step 7**. Update its leading number so the list reads 1–7 with no duplicate/skipped numbers.

- [ ] **Step 4: Sanity-check the command doc**

Run: `pwsh -NoProfile -Command "Get-Content commands/route.md -Raw | Select-String -Pattern '--calibrate' | Measure-Object | ForEach-Object Count"`
Expected: a count ≥ 3 (front-matter + Phase 1 + Phase 2 references present).

- [ ] **Step 5: Commit**

```bash
git add commands/route.md
git commit -m "feat(routing): /route --calibrate two-phase sample-judge-rate mode

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 6: Full gate + live deploy smoke

**Files:** none (verification only)

- [ ] **Step 1: Run the full routing + bootstrap suite**

Run each and confirm exit 0 / all PASS:

```
pwsh -NoProfile -File scripts/test-routing-lib.ps1
pwsh -NoProfile -File scripts/test-routing-dispatch.ps1
pwsh -NoProfile -File scripts/test-routing-learn.ps1
pwsh -NoProfile -File scripts/test-routing-calibrate.ps1
pwsh -NoProfile -File scripts/test-bootstrap.ps1
```

Expected: every suite green. `test-routing-dispatch.ps1` (31) and `test-routing-learn.ps1` (43) must be unchanged from before.

- [ ] **Step 2: Run the fleet suites (touched libs are dot-source ancestors)**

Run the split fleet suite set and confirm exit 0:

```
pwsh -NoProfile -File scripts/test-fleet-lib.ps1
pwsh -NoProfile -File scripts/test-fleet-dispatch.ps1
```

(Run any additional `scripts/test-fleet-*.ps1` present; do not reference a non-existent `test-fleet.ps1`.)

- [ ] **Step 3: Live deploy smoke**

Run: `pwsh -NoProfile -File scripts/bootstrap.ps1 -Force`
Then confirm the lib deployed and the function loads:

```
pwsh -NoProfile -Command ". \"$HOME/.claude/scripts/routing-calibrate.ps1\"; (Get-Command Invoke-CapabilityCalibration, Add-CalibrationRatings).Name -join ','"
```

Expected: `Invoke-CapabilityCalibration,Add-CalibrationRatings`.

- [ ] **Step 4: No commit** — verification only. Proceed to the final comprehensive review.

---

## Self-Review

**Spec coverage:**
- Fan-out dispatch all candidates → Task 2 (`Invoke-CapabilityCalibration`, `fan-out dispatched all 3`). ✓
- Shared helper extraction, regression-safe → Task 1 (`Invoke-RoutedCandidate`, 31-check net). ✓
- Judge-seeded grading + journal rows per candidate → Task 2 (`judge tags rows llm-judge`). ✓
- Batch human ratings, source re-derivation, skip unknown/bad → Task 3 (`Add-CalibrationRatings`). ✓
- Tier cap default free; paid opt-in → Task 2 check + Task 5 `$tier` default. ✓
- Two-phase command + pre-filled rate footer + preview line → Task 5. ✓
- Bootstrap deploy + test → Task 4. ✓
- Full gate + live smoke → Task 6. ✓
- No-candidate, dispatch-throw, no-judge-model fallback → covered by reused `Invoke-RoutedCandidate` paths + `no-candidate` check.

**Placeholder scan:** No TBD/TODO; every code step shows complete code; `<capability>`/`<prompt>`/`<spec>` are command-layer substitution markers (Claude fills from `$ARGUMENTS`), consistent with the existing route.md style — not plan placeholders.

**Type consistency:** `Invoke-RoutedCandidate` returns `@{ attempt; result }` everywhere; `attempt` fields (`candidate,source,kind,cost_tier,passed,score,reason,duration_s`) match the original Slice 2 attempt object the regression suite asserts on. `Invoke-CapabilityCalibration` returns `{status; capability; candidates}` with row fields `candidate,source,cost_tier,passed,score,reason,duration_s,excerpt`. `Add-CalibrationRatings` returns `@{applied;skipped}`. Names are consistent across tasks and the command layer.
