# Cost-Engine Slice B — Cascade Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship the draft→finish cascade: cheap models draft, a frontier model finishes, and a judge-scored good-enough draft skips the frontier pass entirely.

**Architecture:** New `scripts/routing-cascade.ps1` lib (slice-per-file convention) reusing `Invoke-RoutedCandidate` for dispatch+grade+journal+gate. `Select-Capability` passes through new optional `role`/`platform` registry fields (ranking untouched). The journal gains a `stage` field. Spec: `docs/superpowers/specs/2026-06-11-cost-engine-slice-b-cascade-design.md`.

**Tech Stack:** PowerShell 7, hand-rolled `Check` test suites (see `scripts/test-routing-dispatch.ps1` for the pattern), temp-dir fixtures, injected `-Dispatcher`/`-Grader`/`-GateNow` (zero live model calls, zero clock dependence).

**Branch:** `feat/slice-b-cascade` off master. Gated merge: PR → master at the end.

**Execution style (Kevin's standing prefs):** fresh subagent per task, NO per-task spec/quality reviewers; one comprehensive adversarial review at the end (Task 8). Never run tests against the real `~/.baton` — every suite uses a temp dir via explicit `-ToolsPath/-FleetPath/-JournalPath` params (the routing suites never touch `BATON_HOME` defaults). Shell commands stay under 965 bytes — run scripts by file, never inline long code.

---

### Task 1: Selector passthrough — `role`/`platform` on candidates

**Files:**
- Modify: `scripts/routing-lib.ps1` (both candidate constructions in `Select-Capability`, ~lines 105-110 and 121-126)
- Test: `scripts/test-routing-lib.ps1` (append cases at the end, before the exit-code footer)

- [ ] **Step 1: Write the failing tests.** Open `scripts/test-routing-lib.ps1`, find the final `if ($script:fail ...)` exit block, and insert BEFORE it (inside the existing `try` if the suite has one, matching the file's layout):

```powershell
# ===== Slice B: role/platform passthrough =====
$tmpB = Join-Path ([System.IO.Path]::GetTempPath()) ("routing-roleb-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $tmpB | Out-Null
try {
    $toolsB = @"
tools:
  - name: anno-tool
    kind: cli
    enabled: true
    cost_tier: local
    capability: cap-b
    role: draft
    platform: local
    command_template: 'x'
"@
    $fleetB = @"
general_capabilities: [cap-b]

providers:
  - name: anno-paid
    kind: cli
    enabled: true
    cost_tier: paid
    role: finisher
    platform: codex
    command_template: 'x "{{prompt}}"'
  - name: bare-local
    kind: cli
    enabled: true
    cost_tier: local
    command_template: 'x "{{prompt}}"'
"@
    $tpB = Join-Path $tmpB 'tools.yaml';  Set-Content -Path $tpB -Value $toolsB -Encoding utf8
    $fpB = Join-Path $tmpB 'fleet.yaml';  Set-Content -Path $fpB -Value $fleetB -Encoding utf8
    $jpB = Join-Path $tmpB 'j.jsonl'

    $cB = Select-Capability -Capability 'cap-b' -ToolsPath $tpB -FleetPath $fpB -JournalPath $jpB
    $annoTool = @($cB | Where-Object { $_.name -eq 'anno-tool' })[0]
    $annoPaid = @($cB | Where-Object { $_.name -eq 'anno-paid' })[0]
    $bare     = @($cB | Where-Object { $_.name -eq 'bare-local' })[0]
    Check 'tools candidate exposes role'      ($annoTool.role -eq 'draft')
    Check 'tools candidate exposes platform'  ($annoTool.platform -eq 'local')
    Check 'fleet candidate exposes role'      ($annoPaid.role -eq 'finisher')
    Check 'fleet candidate exposes platform'  ($annoPaid.platform -eq 'codex')
    Check 'unannotated role is null'          ($null -eq $bare.role)
    Check 'unannotated platform is null'      ($null -eq $bare.platform)
    # Ranking unchanged: cost-ascending — the two locals (tool first within tier by
    # quality/name rules) precede paid regardless of role fields.
    Check 'role fields do not affect ranking' ($cB[-1].name -eq 'anno-paid')
}
finally { Remove-Item -Recurse -Force $tmpB -ErrorAction SilentlyContinue }
```

- [ ] **Step 2: Run to verify the new checks fail.**

Run: `pwsh -NoProfile -File scripts/test-routing-lib.ps1`
Expected: `FAIL: tools candidate exposes role` (and the 3 other role/platform checks), suite exits 1. Pre-existing checks still PASS.

- [ ] **Step 3: Implement the passthrough.** In `scripts/routing-lib.ps1`, in `Select-Capability`, add `role`/`platform` to BOTH candidate objects. Tools branch becomes:

```powershell
            [void]$candidates.Add([pscustomobject]@{
                name = [string]$t.name; kind = [string]$t.kind; source = 'tools'
                cost_tier = [string]$t.cost_tier; quality = $detail.quality
                quality_detail = $detail
                role = $t.role; platform = $t.platform   # Slice B passthrough (null when absent)
                why = "specialized tool for $Capability ($($t.cost_tier))"
            })
```

Fleet branch becomes:

```powershell
            [void]$candidates.Add([pscustomobject]@{
                name = [string]$p.name; kind = [string]$p.kind; source = 'fleet'
                cost_tier = [string]$p.cost_tier; quality = $detail.quality
                quality_detail = $detail
                role = $p.role; platform = $p.platform   # Slice B passthrough (null when absent)
                why = "general model for $Capability ($($p.cost_tier) tier)"
            })
```

Do NOT touch the filter, ranking, or `score` expression.

- [ ] **Step 4: Run the suite — all green.**

Run: `pwsh -NoProfile -File scripts/test-routing-lib.ps1`
Expected: `ALL PASS`, exit 0.

- [ ] **Step 5: Commit.**

```bash
git add scripts/routing-lib.ps1 scripts/test-routing-lib.ps1
git commit -m "feat(cascade): Select-Capability passes through role/platform registry fields"
```

---

### Task 2: Journal `stage` + grader tag on attempts

**Files:**
- Modify: `scripts/routing-dispatch.ps1` (`Write-RoutingJournalLine` param block + row; `Invoke-RoutedCandidate` param block, all three `Write-RoutingJournalLine` call sites, and all three attempt constructions)
- Test: `scripts/test-routing-dispatch.ps1` (append cases before the `finally`)

- [ ] **Step 1: Write the failing tests.** In `scripts/test-routing-dispatch.ps1`, after the rank-1 check (~line 177), insert:

```powershell
    # ===== Slice B: stage field + grader tag =====
    $journalS = Join-Path $tmp 'stage-journal.jsonl'
    Write-RoutingJournalLine -Capability 'code-gen' -Candidate 'local-a' `
        -Source 'fleet' -Kind 'cli' -CostTier 'local' -ExitCode 0 -DurationS 1 `
        -Passed $true -Score 0.8 -Reason 'ok' -Stage 'draft' -JournalPath $journalS `
        -Timestamp '2026-06-11T00:00:00.0000000-06:00'
    $sObj = (Get-Content $journalS)[0] | ConvertFrom-Json
    Check 'journal row carries stage'    ($sObj.stage -eq 'draft')

    Write-RoutingJournalLine -Capability 'code-gen' -Candidate 'local-a' `
        -Source 'fleet' -Kind 'cli' -CostTier 'local' -ExitCode 0 -DurationS 1 `
        -Passed $true -Score 0.8 -Reason 'ok' -JournalPath $journalS `
        -Timestamp '2026-06-11T00:00:01.0000000-06:00'
    $sObj2 = (Get-Content $journalS)[1] | ConvertFrom-Json
    Check 'no -Stage -> no stage field'  ($null -eq $sObj2.PSObject.Properties['stage'])

    # Invoke-RoutedCandidate: -Stage flows to the journal; attempt carries the grader tag.
    $candS = @(Select-Capability -Capability 'code-gen' -ToolsPath $toolsPath -FleetPath $fleetPath -JournalPath $journalS)[0]
    $journalS2 = Join-Path $tmp 'stage-journal2.jsonl'
    $rcS = Invoke-RoutedCandidate -Capability 'code-gen' -Candidate $candS -Prompt 'x' `
        -Dispatcher $dispAllPass -ToolsPath $toolsPath -FleetPath $fleetPath `
        -JournalPath $journalS2 -Stage 'finish'
    $sRow = (Get-Content $journalS2)[0] | ConvertFrom-Json
    Check 'RoutedCandidate journals stage'   ($sRow.stage -eq 'finish')
    Check 'attempt carries grader tag'       ($rcS.attempt.grader -eq 'heuristic')
```

- [ ] **Step 2: Run to verify the new checks fail.**

Run: `pwsh -NoProfile -File scripts/test-routing-dispatch.ps1`
Expected: FAIL on the 4 new checks (the first errors because `-Stage` is not a parameter — that error counts as the failure signal; if the suite hard-stops on it under `$ErrorActionPreference='Stop'`, that IS the red state). Pre-existing checks unaffected.

- [ ] **Step 3: Implement.** In `scripts/routing-dispatch.ps1`:

(a) `Write-RoutingJournalLine`: add a parameter `[string]$Stage` after `$Grader = 'heuristic'`, and after the `$row = [ordered]@{...}` assignment add:

```powershell
    if ($Stage) { $row['stage'] = $Stage }
```

(b) `Invoke-RoutedCandidate`: add parameter `[string]$Stage` after `$GateNow`. Append `` -Stage $Stage`` to ALL THREE `Write-RoutingJournalLine` calls inside it (unsupported-kind, gate-deferred, and the main post-grade call) — an empty `$Stage` is a no-op in (a), so unconditional passing is safe.

(c) Attempt objects: add `grader=...` to all three attempt constructions:
   - unsupported-kind path: `grader='heuristic'`
   - gate-deferred path: `grader=$null` (nothing was graded)
   - main path: `grader=$graderTag`

- [ ] **Step 4: Run the dispatch suite AND its dependents — all green.**

Run: `pwsh -NoProfile -File scripts/test-routing-dispatch.ps1`
Expected: `ALL PASS`, exit 0.
Run: `pwsh -NoProfile -File scripts/test-routing-calibrate.ps1`
Expected: `ALL PASS` (calibrate consumes Invoke-RoutedCandidate; additive params must not break it).

- [ ] **Step 5: Commit.**

```bash
git add scripts/routing-dispatch.ps1 scripts/test-routing-dispatch.ps1
git commit -m "feat(cascade): journal stage field + grader tag on dispatch attempts"
```

---

### Task 3: Cascade lib — roles, drafting, short-circuit

**Files:**
- Create: `scripts/routing-cascade.ps1`
- Create: `scripts/test-routing-cascade.ps1`

- [ ] **Step 1: Write the failing test suite skeleton + Task 3 cases.** Create `scripts/test-routing-cascade.ps1`:

```powershell
#!/usr/bin/env pwsh
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/routing-cascade.ps1"

$script:fail = 0
function Check($n,$c){ if($c){Write-Host "PASS: $n"} else {Write-Host "FAIL: $n"; $script:fail++} }

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("routing-casc-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null

try {
    # Fixture: 2 locals (draft by inference), 1 cheap-paid explicitly role:draft,
    # 1 paid finisher (inference), 1 paid explicitly bulk (draft-eligible).
    $fleetYaml = @"
general_capabilities: [code-gen]

providers:
  - name: local-a
    kind: cli
    enabled: true
    cost_tier: local
    command_template: 'x "{{prompt}}"'
  - name: local-b
    kind: cli
    enabled: true
    cost_tier: local
    command_template: 'x "{{prompt}}"'
  - name: cheap-paid-draft
    kind: cli
    enabled: true
    cost_tier: paid
    role: draft
    platform: claude
    command_template: 'x "{{prompt}}"'
  - name: bulk-paid
    kind: cli
    enabled: true
    cost_tier: paid
    role: bulk
    command_template: 'x "{{prompt}}"'
  - name: frontier
    kind: cli
    enabled: true
    cost_tier: paid
    platform: codex
    command_template: 'x "{{prompt}}"'
"@
    $fleetPath = Join-Path $tmp 'fleet.yaml'; Set-Content -Path $fleetPath -Value $fleetYaml -Encoding utf8
    $toolsPath = Join-Path $tmp 'tools.yaml'; Set-Content -Path $toolsPath -Value "tools:" -Encoding utf8
    $journal   = Join-Path $tmp 'journal.jsonl'
    $common    = @{ ToolsPath = $toolsPath; FleetPath = $fleetPath; JournalPath = $journal }

    # ===== Task 3: role partition =====
    Check 'explicit draft beats paid inference'  ((Get-CascadeRole ([pscustomobject]@{ role='draft';   cost_tier='paid'  })) -eq 'draft')
    Check 'bulk is draft-eligible'               ((Get-CascadeRole ([pscustomobject]@{ role='bulk';    cost_tier='paid'  })) -eq 'draft')
    Check 'explicit finisher beats local'        ((Get-CascadeRole ([pscustomobject]@{ role='finisher';cost_tier='local' })) -eq 'finisher')
    Check 'paid infers finisher'                 ((Get-CascadeRole ([pscustomobject]@{ role=$null;     cost_tier='paid'  })) -eq 'finisher')
    Check 'local infers draft'                   ((Get-CascadeRole ([pscustomobject]@{ role=$null;     cost_tier='local' })) -eq 'draft')
    Check 'free infers draft'                    ((Get-CascadeRole ([pscustomobject]@{ role=$null;     cost_tier='free'  })) -eq 'draft')
    Check 'unknown role falls back to inference' ((Get-CascadeRole ([pscustomobject]@{ role='wizard';  cost_tier='local' })) -eq 'draft')

    # ===== Task 3: drafting + short-circuit =====
    # Judge-style grader: scores by candidate name, tags llm-judge.
    $scoreMap = @{ 'local-a' = 0.95; 'local-b' = 0.5; 'cheap-paid-draft' = 0.5; 'bulk-paid' = 0.5 }
    $judgeGrader = {
        param($Capability, $Result)
        $name = ([string]$Result.stdout).Trim()
        $s = if ($scoreMap.ContainsKey($name)) { [double]$scoreMap[$name] } else { 0.3 }
        @{ passed = ($s -ge 0.6); score = $s; reason = 'judged'; grader = 'llm-judge' }
    }.GetNewClosure()
    # Dispatcher echoes the candidate name so the grader can score per-candidate.
    $echoName = { param($cand,$prompt) @{ stdout=$cand.name; stderr=''; exit_code=0; duration_s=1 } }
    $script:finisherCalls = 0
    $countingEcho = { param($cand,$prompt) if ($cand.name -eq 'frontier') { $script:finisherCalls++ }; @{ stdout=$cand.name; stderr=''; exit_code=0; duration_s=1 } }

    # local-a judge-scores 0.95 >= 0.9 -> draft-sufficient, finisher never dispatched.
    $r1 = Invoke-CapabilityCascade -Capability 'code-gen' -Prompt 'do x' `
        -Grader $judgeGrader -Dispatcher $countingEcho @common
    Check 'short-circuit fires'            ($r1.status -eq 'draft-sufficient')
    Check 'short-circuit winner is draft'  ($r1.winner -eq 'local-a')
    Check 'short-circuit zero frontier'    ($r1.frontier_spent -eq $false)
    Check 'finisher never dispatched'      ($script:finisherCalls -eq 0)
    Check 'draft attempts recorded'        (@($r1.draft_attempts).Count -ge 1)

    # DraftCount caps the fan-out in selector order.
    $r2 = Invoke-CapabilityCascade -Capability 'code-gen' -Prompt 'do x' `
        -DraftCount 1 -Grader $judgeGrader -Dispatcher $echoName @common
    Check 'DraftCount caps fan-out'        (@($r2.draft_attempts).Count -eq 1)

    # -NoShortCircuit forces the finisher past a 0.95 draft.
    $r3 = Invoke-CapabilityCascade -Capability 'code-gen' -Prompt 'do x' `
        -NoShortCircuit -Grader $judgeGrader -Dispatcher $echoName @common
    Check 'NoShortCircuit forces finish'   ($r3.status -eq 'finished')

    # Heuristic (binary) verdict suppresses the short-circuit -> finisher runs.
    $heurGrader = { param($Capability,$Result) @{ passed=$true; score=1.0; reason='ok'; grader='heuristic' } }
    $r4 = Invoke-CapabilityCascade -Capability 'code-gen' -Prompt 'do x' `
        -Grader $heurGrader -Dispatcher $echoName @common
    Check 'heuristic verdict never short-circuits' ($r4.status -eq 'finished')

    # Unknown capability -> no-candidate.
    $r5 = Invoke-CapabilityCascade -Capability 'nope' -Prompt 'x' -Grader $heurGrader -Dispatcher $echoName @common
    Check 'unknown cap -> no-candidate'    ($r5.status -eq 'no-candidate')

    # Journal rows carry stage=draft for draft dispatches.
    $stages = @(Get-Content $journal | ForEach-Object { ($_ | ConvertFrom-Json).stage } | Where-Object { $_ -eq 'draft' })
    Check 'journal has stage=draft rows'   ($stages.Count -ge 1)
}
finally {
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}

if ($script:fail -gt 0) { Write-Host "`n$script:fail FAILED" -ForegroundColor Red; exit 1 } else { Write-Host "`nALL PASS" -ForegroundColor Green; exit 0 }
```

- [ ] **Step 2: Run to verify it fails.**

Run: `pwsh -NoProfile -File scripts/test-routing-cascade.ps1`
Expected: hard error — `routing-cascade.ps1` does not exist yet. That is the red state.

- [ ] **Step 3: Implement the lib.** Create `scripts/routing-cascade.ps1`:

```powershell
#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Capability-routing cascade (Engine Slice B). Cheap draft-eligible candidates draft;
  a frontier finisher takes-and-extends the best draft; a judge-scored good-enough
  draft short-circuits the finisher entirely (zero frontier spend).
.DESCRIPTION
  Dot-sources routing-dispatch.ps1 (which pulls routing-lib -> routing-learn + fleet-lib),
  so Select-Capability, Invoke-RoutedCandidate, and Get-LlmJudgeGrader are in scope.
  See docs/superpowers/specs/2026-06-11-cost-engine-slice-b-cascade-design.md.
#>

. "$PSScriptRoot/baton-home.ps1"
. "$PSScriptRoot/routing-dispatch.ps1"

function Get-CascadeRole {
    <# Effective cascade role for a Select-Capability candidate. Explicit role field
       wins (draft|bulk|finisher; bulk is draft-eligible); unknown/absent values fall
       back to cost-tier inference: paid -> finisher, local/free -> draft (fail-open).
       Explicit-beats-inferred is how cheap-paid (Haiku/Sonnet-class) entries draft. #>
    param([Parameter(Mandatory)]$Candidate)
    switch ([string]$Candidate.role) {
        'draft'    { return 'draft' }
        'bulk'     { return 'draft' }
        'finisher' { return 'finisher' }
    }
    if ($Candidate.cost_tier -eq 'paid') { return 'finisher' }
    return 'draft'
}

function Get-CascadeFinisherPrompt {
    <# Single source of truth for the take-and-extend finisher prompt (test-asserted). #>
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [Parameter(Mandatory)][string]$Draft
    )
    return @"
You are finishing another model's draft. TASK:
$Prompt

DRAFT (may be incomplete or flawed — keep what is good, fix what is not,
extend to fully satisfy the TASK; output ONLY the finished result):
$Draft
"@
}

function Invoke-CapabilityCascade {
    <# Draft -> good-enough gate -> finish. Statuses: draft-sufficient | finished |
       finisher-deferred | no-finisher | no-candidate | escalate-to-conductor.
       frontier_spent is true only when a paid finisher actually dispatched.
       The short-circuit requires an llm-judge verdict: the heuristic grader is binary
       (pass = 1.0) and would skip the finisher on every pass (spec decision 2). #>
    param(
        [Parameter(Mandatory)][string]$Capability,
        [Parameter(Mandatory)][string]$Prompt,
        [int]$DraftCount = 3,
        [double]$GoodEnough = 0.9,
        [switch]$NoShortCircuit,
        [scriptblock]$Grader,
        [string]$JudgeModel,
        [scriptblock]$JudgeDispatcher,
        [scriptblock]$Dispatcher,
        [int]$Rank = [int]::MinValue,
        [string]$PrimeHoursConfig,
        [datetime]$GateNow,
        [ValidateSet('local','free','paid')][string]$MaxCostTier,
        [switch]$RequireLocal,
        [int]$TimeoutS = 120,
        [string]$ToolsPath = (Join-Path (Get-BatonHome) 'tools.yaml'),
        [string]$FleetPath = (Join-Path (Get-BatonHome) 'fleet.yaml'),
        [string]$JournalPath = (Join-Path (Get-BatonHome) 'routing-journal.jsonl')
    )
    $sel = @{ Capability = $Capability; ToolsPath = $ToolsPath; FleetPath = $FleetPath }
    if ($RequireLocal) { $sel['RequireLocal'] = $true }
    if ($MaxCostTier)  { $sel['MaxCostTier']  = $MaxCostTier }
    $candidates = Select-Capability @sel
    if (-not $candidates -or $candidates.Count -eq 0) {
        return [pscustomobject]@{ status='no-candidate'; capability=$Capability; winner=$null
                                  result=$null; draft_attempts=@(); finish_attempt=$null; frontier_spent=$false }
    }

    # Grader: -Grader wins (tests); else judge by default — the short-circuit needs a
    # scored verdict, and Get-LlmJudgeGrader itself falls back to heuristic (tagged so).
    $effGrader = if ($Grader) { $Grader }
                 else { Get-LlmJudgeGrader -JudgeModel $JudgeModel -FleetPath $FleetPath -JudgeDispatcher $JudgeDispatcher }

    $drafters  = @($candidates | Where-Object { (Get-CascadeRole $_) -eq 'draft' } | Select-Object -First $DraftCount)
    $finishers = @($candidates | Where-Object { (Get-CascadeRole $_) -eq 'finisher' })

    # Common Invoke-RoutedCandidate args (gate params flow to drafts too: a paid
    # draft-by-explicit-role is still a paid dispatch and gets rank-gated as such).
    $rcCommon = @{
        Capability = $Capability; EffGrader = $effGrader; Dispatcher = $Dispatcher
        TimeoutS = $TimeoutS; ToolsPath = $ToolsPath; FleetPath = $FleetPath; JournalPath = $JournalPath
    }
    if ($Rank -ne [int]::MinValue)                 { $rcCommon['Rank'] = $Rank }
    if ($PrimeHoursConfig)                         { $rcCommon['PrimeHoursConfig'] = $PrimeHoursConfig }
    if ($PSBoundParameters.ContainsKey('GateNow')) { $rcCommon['GateNow'] = $GateNow }

    # ── Draft stage (serial; parallel fan-out is Slice C) ──
    $draftAttempts = [System.Collections.ArrayList]@()
    $best = $null   # @{ attempt; result } — passed beats unpassed, then higher score wins
    foreach ($d in $drafters) {
        $rc = Invoke-RoutedCandidate @rcCommon -Candidate $d -Prompt $Prompt -Stage 'draft'
        [void]$draftAttempts.Add($rc.attempt)
        $better = if ($null -eq $best) { $true }
                  elseif ([bool]$rc.attempt.passed -ne [bool]$best.attempt.passed) { [bool]$rc.attempt.passed }
                  else { $rc.attempt.score -gt $best.attempt.score }
        if ($better) { $best = $rc }
    }

    # ── Short-circuit: judge-scored good-enough draft ships, zero frontier spend ──
    if (-not $NoShortCircuit -and $best -and $best.attempt.passed -and
        $best.attempt.score -ge $GoodEnough -and $best.attempt.grader -eq 'llm-judge') {
        return [pscustomobject]@{ status='draft-sufficient'; capability=$Capability
                                  winner=$best.attempt.candidate; result=$best.result
                                  draft_attempts=$draftAttempts.ToArray(); finish_attempt=$null; frontier_spent=$false }
    }

    # ── Finisher stage ──
    $bestPassedName   = if ($best -and $best.attempt.passed) { $best.attempt.candidate } else { $null }
    $bestPassedResult = if ($best -and $best.attempt.passed) { $best.result } else { $null }
    if ($finishers.Count -eq 0) {
        return [pscustomobject]@{ status='no-finisher'; capability=$Capability
                                  winner=$bestPassedName; result=$bestPassedResult
                                  draft_attempts=$draftAttempts.ToArray(); finish_attempt=$null; frontier_spent=$false }
    }
    $f = $finishers[0]   # selector order = cheapest capable finisher first
    $draftText = if ($best -and -not [string]::IsNullOrWhiteSpace([string]$best.result.stdout)) { [string]$best.result.stdout } else { $null }
    $fPrompt = if ($draftText) { Get-CascadeFinisherPrompt -Prompt $Prompt -Draft $draftText } else { $Prompt }
    $frc = Invoke-RoutedCandidate @rcCommon -Candidate $f -Prompt $fPrompt -Stage 'finish'

    if ($frc.attempt.reason -match '^deferred: prime-hours') {
        # Slice A gate deferred the paid step. Best draft is the provisional result.
        return [pscustomobject]@{ status='finisher-deferred'; capability=$Capability
                                  winner=$bestPassedName; result=$bestPassedResult
                                  draft_attempts=$draftAttempts.ToArray(); finish_attempt=$frc.attempt; frontier_spent=$false }
    }
    $spent = ($f.cost_tier -eq 'paid')   # it dispatched; pass or fail, paid was spent
    if ($frc.attempt.passed) {
        return [pscustomobject]@{ status='finished'; capability=$Capability
                                  winner=$f.name; result=$frc.result
                                  draft_attempts=$draftAttempts.ToArray(); finish_attempt=$frc.attempt; frontier_spent=$spent }
    }
    return [pscustomobject]@{ status='escalate-to-conductor'; capability=$Capability
                              winner=$null; result=$bestPassedResult
                              draft_attempts=$draftAttempts.ToArray(); finish_attempt=$frc.attempt; frontier_spent=$spent }
}
```

- [ ] **Step 4: Run the suite — Task 3 cases green.**

Run: `pwsh -NoProfile -File scripts/test-routing-cascade.ps1`
Expected: `ALL PASS`, exit 0.

- [ ] **Step 5: Commit.**

```bash
git add scripts/routing-cascade.ps1 scripts/test-routing-cascade.ps1
git commit -m "feat(cascade): Invoke-CapabilityCascade — roles, draft fan-out, judge-gated short-circuit"
```

---

### Task 4: Cascade finisher paths — deferral, no-finisher, escalation, prompt template

**Files:**
- Modify: `scripts/test-routing-cascade.ps1` (append cases inside the `try`, after the Task 3 block)
- Modify (only if a test exposes a bug): `scripts/routing-cascade.ps1`

The lib code from Task 3 already implements these paths; this task proves them. TDD here means: add the cases, expect green; any red is a real bug to fix in the lib.

- [ ] **Step 1: Append the finisher-path cases** to `scripts/test-routing-cascade.ps1` before the `finally`:

```powershell
    # ===== Task 4: finisher paths =====
    # Below-threshold drafts -> finisher runs with the take-and-extend prompt.
    $script:finisherPrompt = $null
    $lowMap = @{ 'local-a' = 0.7; 'local-b' = 0.6; 'cheap-paid-draft' = 0.6; 'bulk-paid' = 0.6 }
    $lowJudge = {
        param($Capability, $Result)
        $name = ([string]$Result.stdout).Trim()
        if ($name -eq 'FINISHED') { return @{ passed=$true; score=0.97; reason='judged'; grader='llm-judge' } }
        $s = if ($lowMap.ContainsKey($name)) { [double]$lowMap[$name] } else { 0.3 }
        @{ passed = ($s -ge 0.6); score = $s; reason = 'judged'; grader = 'llm-judge' }
    }.GetNewClosure()
    $captureFinish = {
        param($cand,$prompt)
        if ($cand.name -eq 'frontier') { $script:finisherPrompt = $prompt; return @{ stdout='FINISHED'; stderr=''; exit_code=0; duration_s=1 } }
        @{ stdout=$cand.name; stderr=''; exit_code=0; duration_s=1 }
    }
    $f1 = Invoke-CapabilityCascade -Capability 'code-gen' -Prompt 'TASK-MARKER do x' `
        -Grader $lowJudge -Dispatcher $captureFinish @common
    Check 'below threshold -> finished'      ($f1.status -eq 'finished')
    Check 'finisher wins'                    ($f1.winner -eq 'frontier')
    Check 'frontier_spent true'              ($f1.frontier_spent -eq $true)
    Check 'finisher prompt has task'         ($script:finisherPrompt -match 'TASK-MARKER do x')
    Check 'finisher prompt has best draft'   ($script:finisherPrompt -match 'local-a')
    Check 'finisher prompt is the template'  ($script:finisherPrompt -match "finishing another model's draft")
    Check 'finish_attempt recorded'          ($f1.finish_attempt.candidate -eq 'frontier')

    # All drafts fail -> finisher gets the ORIGINAL prompt alone.
    $script:finisherPrompt = $null
    $allFailJudge = {
        param($Capability, $Result)
        $name = ([string]$Result.stdout).Trim()
        if ($name -eq 'FINISHED') { return @{ passed=$true; score=0.97; reason='judged'; grader='llm-judge' } }
        @{ passed=$false; score=0.0; reason='judged-bad'; grader='llm-judge' }
    }
    $failDrafts = {
        param($cand,$prompt)
        if ($cand.name -eq 'frontier') { $script:finisherPrompt = $prompt; return @{ stdout='FINISHED'; stderr=''; exit_code=0; duration_s=1 } }
        @{ stdout=''; stderr=''; exit_code=1; duration_s=1 }
    }
    $f2 = Invoke-CapabilityCascade -Capability 'code-gen' -Prompt 'ORIGINAL-ONLY' `
        -Grader $allFailJudge -Dispatcher $failDrafts @common
    Check 'all drafts fail -> still finishes'   ($f2.status -eq 'finished')
    Check 'failed drafts -> original prompt'    ($script:finisherPrompt -eq 'ORIGINAL-ONLY')

    # Finisher fails grading -> escalate-to-conductor, paid spend still recorded.
    $allBad = { param($Capability,$Result) @{ passed=$false; score=0.2; reason='judged-bad'; grader='llm-judge' } }
    $f3 = Invoke-CapabilityCascade -Capability 'code-gen' -Prompt 'x' `
        -Grader $allBad -Dispatcher $echoName @common
    Check 'finisher fails -> escalate'       ($f3.status -eq 'escalate-to-conductor')
    Check 'escalate still spent frontier'    ($f3.frontier_spent -eq $true)

    # -RequireLocal -> no paid candidates -> no finisher-eligible -> no-finisher,
    # best passing draft returned.
    $okJudge = { param($Capability,$Result) @{ passed=$true; score=0.7; reason='judged'; grader='llm-judge' } }
    $f4 = Invoke-CapabilityCascade -Capability 'code-gen' -Prompt 'x' `
        -RequireLocal -Grader $okJudge -Dispatcher $echoName @common
    Check 'RequireLocal -> no-finisher'      ($f4.status -eq 'no-finisher')
    Check 'no-finisher returns best draft'   ($f4.winner -in @('local-a','local-b'))
    Check 'no-finisher zero frontier'        ($f4.frontier_spent -eq $false)

    # Gate defers the finisher (all-day peak, rank 3) -> finisher-deferred + provisional draft.
    $phYaml = @"
timezone: local
default_rank: 3
windows:
  - name: peak
    days: [Mon, Tue, Wed, Thu, Fri, Sat, Sun]
    start: "00:00"
    end: "23:59"
    kind: peak
"@
    $phCfg = Join-Path $tmp 'prime-hours.yaml'; Set-Content -Path $phCfg -Value $phYaml -Encoding utf8
    $f5 = Invoke-CapabilityCascade -Capability 'code-gen' -Prompt 'x' `
        -Grader $lowJudge -Dispatcher $captureFinish `
        -Rank 3 -PrimeHoursConfig $phCfg -GateNow ([datetime]'2026-06-10T12:00:00') `
        -DraftCount 2 @common
    Check 'peak rank3 -> finisher-deferred'  ($f5.status -eq 'finisher-deferred')
    Check 'deferred keeps best draft'        ($f5.winner -eq 'local-a')
    Check 'deferred zero frontier'           ($f5.frontier_spent -eq $false)
    Check 'deferred finish_attempt gated'    ($f5.finish_attempt.gate -in @('defer','ask'))

    # Journal rows carry stage=finish for finisher dispatches.
    $finRows = @(Get-Content $journal | ForEach-Object { ($_ | ConvertFrom-Json).stage } | Where-Object { $_ -eq 'finish' })
    Check 'journal has stage=finish rows'    ($finRows.Count -ge 1)
```

Note on `$f5`: `-DraftCount 2` keeps the drafters to the two locals — the explicitly-draft cheap-paid entries would otherwise be rank-gated drafts, which is Task 3 behavior, not what this case isolates.

- [ ] **Step 2: Run the suite.**

Run: `pwsh -NoProfile -File scripts/test-routing-cascade.ps1`
Expected: `ALL PASS`, exit 0. Any FAIL here is a lib bug — fix `scripts/routing-cascade.ps1` minimally and re-run until green.

- [ ] **Step 3: Commit.**

```bash
git add scripts/test-routing-cascade.ps1 scripts/routing-cascade.ps1
git commit -m "test(cascade): finisher paths — deferral, no-finisher, escalation, prompt template"
```

---

### Task 5: Seed registry annotations

**Files:**
- Modify: `references/fleet.yaml` (field docs header + every provider entry)
- Modify: `references/tools.yaml` (field docs header + every tool entry)

- [ ] **Step 1: Annotate `references/fleet.yaml`.** Add to the header comment block (after the `base_url` line):

```yaml
#   role              (optional) draft | bulk | finisher — cascade stage (Slice B).
#                     Absent -> inferred: local/free = draft, paid = finisher.
#   platform          (optional) claude | codex | gemini | github | local — Lever 4
#                     identity; journaled now, consumed by the cost/speed advisor later.
```

Then annotate each provider (insert after each `cost_tier` line):

| provider | role | platform |
|---|---|---|
| claude-cli | finisher | claude |
| codex | finisher | codex |
| gemini-antigravity | finisher | gemini |
| gh-copilot | bulk | github |
| opencode | draft | *(none)* |
| ollama-local | draft | local |
| ollama-box2 | draft | local |
| lm-studio | draft | local |

Example (claude-cli):

```yaml
  - name: claude-cli
    kind: cli
    enabled: true
    cost_tier: paid
    role: finisher
    platform: claude
    command_template: 'claude -p "{{prompt}}"'
```

- [ ] **Step 2: Annotate `references/tools.yaml`.** Header addition (after the `command_template / base_url` line):

```yaml
#   role         (optional) draft | bulk | finisher — cascade stage (Slice B); these
#                specialized local tools are all draft-class.
#   platform     (optional) platform identity (Lever 4); local for on-box tools.
```

Add `role: draft` + `platform: local` to all four entries (docling, git-commit-message, nuextract, deepseek-ocr), each inserted after the entry's `cost_tier` line.

- [ ] **Step 3: Prove the annotated seeds parse and route.** Run (one line, well under 965 bytes):

Run: `pwsh -NoProfile -Command ". ./scripts/routing-lib.ps1; $c = Select-Capability -Capability 'code-gen' -ToolsPath ./references/tools.yaml -FleetPath ./references/fleet.yaml -JournalPath \$env:TEMP/nope.jsonl; $c | Format-Table name, cost_tier, role, platform; if ($c[0].cost_tier -ne 'local') { exit 1 }"`
Expected: table shows the new columns populated; exit 0 (cheapest-first ordering intact).

- [ ] **Step 4: Run the routing suites — regression check.**

Run: `pwsh -NoProfile -File scripts/test-routing-lib.ps1`
Expected: `ALL PASS`.

- [ ] **Step 5: Commit.**

```bash
git add references/fleet.yaml references/tools.yaml
git commit -m "feat(cascade): role/platform annotations on seed fleet.yaml + tools.yaml"
```

---

### Task 6: Bootstrap deploys the cascade lib

**Files:**
- Modify: `scripts/bootstrap.ps1:259` (deploy list)
- Modify: `scripts/test-bootstrap.ps1` (deployed-scripts assertion)

- [ ] **Step 1: Write the failing test.** In `scripts/test-bootstrap.ps1`, find where deployed scripts are asserted (search for `'routing-calibrate.ps1'` — there is a list or per-file check mirroring bootstrap's deploy list) and add `'routing-cascade.ps1'` the same way the others appear.

- [ ] **Step 2: Run to verify it fails.**

Run: `pwsh -NoProfile -File scripts/test-bootstrap.ps1`
Expected: FAIL on the routing-cascade.ps1 deploy check.

- [ ] **Step 3: Implement.** In `scripts/bootstrap.ps1` line 259, add `'routing-cascade.ps1'` to the deploy array immediately after `'routing-calibrate.ps1'`.

- [ ] **Step 4: Run to verify green.**

Run: `pwsh -NoProfile -File scripts/test-bootstrap.ps1`
Expected: `ALL PASS` (or the suite's equivalent success footer), exit 0.

- [ ] **Step 5: Run the stale-literal guard** (the new lib must resolve state via `Get-BatonHome`, which it does by construction):

Run: `pwsh -NoProfile -File scripts/test-baton-home.ps1`
Expected: `ALL PASS`, exit 0.

- [ ] **Step 6: Commit.**

```bash
git add scripts/bootstrap.ps1 scripts/test-bootstrap.ps1
git commit -m "feat(cascade): bootstrap deploys routing-cascade.ps1"
```

---

### Task 7: `/baton:route --cascade` command surface

**Files:**
- Modify: `commands/route.md` (frontmatter description + argument-hint; new Steps section)

- [ ] **Step 1: Update the frontmatter.** Append to `description:` (one sentence, keep the existing text): `--cascade drafts on cheap models and pays a frontier finisher only for the final delta — a judge-scored good-enough draft skips the frontier pass entirely.` Extend `argument-hint:` with: `| --cascade "<prompt>" [--drafts N] [--good-enough 0.9] [--rank <1-5>]`.

- [ ] **Step 2: Add the cascade section.** After the `--run` section (step 3) in `commands/route.md`, insert:

````markdown
4. **With `--cascade "<prompt>"` (draft→finish mode, Engine Slice B):**

   ```powershell
   . "$HOME/.claude/scripts/routing-cascade.ps1"
   $opt = @{ Capability = '<capability>'; Prompt = '<prompt>' }
   if ($draftsArg)     { $opt['DraftCount'] = [int]$draftsArg }
   if ($goodEnoughArg) { $opt['GoodEnough'] = [double]$goodEnoughArg }
   if ($local)         { $opt['RequireLocal'] = $true }
   if ($maxTier)       { $opt['MaxCostTier']  = '<tier>' }
   $opt['Rank'] = if ($rankArg) { [int]$rankArg } else { 3 }
   $out = Invoke-CapabilityCascade @opt
   foreach ($a in $out.draft_attempts) {
       $mark = if ($a.passed) { 'PASS' } else { 'fail' }
       Write-Host ("  draft  {0,-5} {1,-22} {2}  score {3:0.00}  ({4}s)  {5}" -f $a.cost_tier, $a.candidate, $mark, $a.score, $a.duration_s, $a.reason)
   }
   if ($out.finish_attempt) {
       $fa = $out.finish_attempt
       $mark = if ($fa.passed) { 'PASS' } else { 'fail' }
       Write-Host ("  finish {0,-5} {1,-22} {2}  score {3:0.00}  ({4}s)  {5}" -f $fa.cost_tier, $fa.candidate, $mark, $fa.score, $fa.duration_s, $fa.reason)
   }
   ```

   Then report by `$out.status`, always closing with the cost line:
   - `draft-sufficient` → *"Draft from `<winner>` scored ≥ the good-enough bar — shipped as-is."* Show `$out.result.stdout`. Cost line: **`frontier spend: none (draft-sufficient)`**.
   - `finished` → *"`<winner>` finished the best draft."* Show `$out.result.stdout`. Cost line: **`frontier spend: 1 finisher pass (<winner>)`**.
   - `finisher-deferred` → the prime-hours gate deferred the paid finisher; show the best draft as a PROVISIONAL result and say re-running off-peak (or `--rank 1`) will finish it. Cost line: **`frontier spend: none (finisher deferred to off-peak)`**.
   - `no-finisher` → no finisher-eligible candidate under the current constraints (e.g. `--local`); show the best draft if one passed.
   - `no-candidate` → nothing serves `<capability>`; list `Get-KnownCapabilities`.
   - `escalate-to-conductor` → drafts and finisher both failed; escalate to the conductor (you, Claude) with the per-attempt reasons above.

   **Prime-hours ask (interactive):** same semantics as `--run` — an `ask` gate on the
   finisher attempt means confirm with the user before treating the deferral as final.
````

- [ ] **Step 3: Sanity-check the embedded PowerShell** (extract and parse — protects against typos):

Run: `pwsh -NoProfile -Command "$null = [scriptblock]::Create((Get-Content ./commands/route.md -Raw)); 'md not parsed as ps — manual check only'; exit 0"`
This is markdown, not executable — instead verify by eyeball that every variable referenced (`$draftsArg`, `$goodEnoughArg`, `$rankArg`, `$local`, `$maxTier`) is introduced in the parse step (step 1 of the command doc). Update the command doc's step 1 parse list to include `--cascade "<prompt>"`, `--drafts N`, `--good-enough X`.

- [ ] **Step 4: Commit.**

```bash
git add commands/route.md
git commit -m "feat(cascade): /baton:route --cascade command surface"
```

---

### Task 8: Final gate, comprehensive review, merge, deploy, closeout

**Files:**
- Modify: `docs/next-session.md` (Slice B → SHIPPED entry), `.claude-plugin/plugin.json` (version bump)
- No other code changes unless the review finds bugs.

- [ ] **Step 1: Full PS battery** (the suites this slice could plausibly affect):

Run each; ALL must exit 0:
```
pwsh -NoProfile -File scripts/test-routing-lib.ps1
pwsh -NoProfile -File scripts/test-routing-dispatch.ps1
pwsh -NoProfile -File scripts/test-routing-learn.ps1
pwsh -NoProfile -File scripts/test-routing-calibrate.ps1
pwsh -NoProfile -File scripts/test-routing-cascade.ps1
pwsh -NoProfile -File scripts/test-prime-hours.ps1
pwsh -NoProfile -File scripts/test-fleet-backlog.ps1
pwsh -NoProfile -File scripts/test-bootstrap.ps1
pwsh -NoProfile -File scripts/test-baton-home.ps1
pwsh -NoProfile -File scripts/test-mcp-bridge.ps1
```

- [ ] **Step 2: Comprehensive adversarial review** (single reviewer at the end per Kevin's execution style — dispatch a code-review subagent over the full branch diff vs master, spec in hand). BLOCKs fixed before merge; NITs fixed or explicitly deferred with a note.

- [ ] **Step 3: Bump plugin version** in `.claude-plugin/plugin.json`: `1.2.0-rc.4` → `1.2.0-rc.5` (commands/route.md ships with the plugin).

- [ ] **Step 4: PR + gated merge.**

```bash
git push -u origin feat/slice-b-cascade
gh pr create --title "feat(engine): Slice B — model-role registry + draft->finish cascade" --body "<summary + spec link>"
gh pr merge --merge --delete-branch
```

- [ ] **Step 5: Live deploy.** `pwsh -NoProfile -File scripts/bootstrap.ps1 -Force -NonInteractive` (redeploys `~/.claude/scripts` incl. routing-cascade.ps1; seeds untouched by design — annotations reach existing machines only via doc'd manual edit or fresh setup; note this in the closeout). Then `claude plugin update baton` (or note that the next session picks up rc.5).

- [ ] **Step 6: Closeout.** Update `docs/next-session.md` (Slice B SHIPPED entry + Slice C now next), memory `project_orchestrator`-adjacent file if needed; decision d041 already captured at spec time; push everything (repo + KB per backup order); confirm checklist and prompt to `/compact`.

---

## Self-review (done at plan time)

- **Spec coverage:** B.1 → Tasks 1+5; B.2 → Task 2; B.3 → Tasks 3+4 (all six statuses tested: no-candidate T3, draft-sufficient T3, finished T4, finisher-deferred T4, no-finisher T4, escalate T4; prompt template T4; DraftCount T3; NoShortCircuit T3; heuristic-suppression T3); B.4 → Task 7; B.5 edge cases → T3 (unknown cap), T4 (all-fail, RequireLocal), inference fallback T3 role tests; B.6 → suite mirrors the spec's 12 cases; bootstrap/stale-guard → Task 6. Out-of-scope items honored (no MCP op, serial only).
- **Type consistency:** `Get-CascadeRole`/`Get-CascadeFinisherPrompt`/`Invoke-CapabilityCascade` names used identically in Tasks 3/4/7; attempt `grader` tag added in Task 2 and consumed in Task 3's short-circuit; `-Stage` added in Task 2, used in Tasks 3/4; return-object property names (`draft_attempts`, `finish_attempt`, `frontier_spent`) consistent across Tasks 3/4/7.
- **Placeholder scan:** none — every code step shows the code; Task 6 step 1 references a concrete search anchor (`'routing-calibrate.ps1'`) because the exact assertion shape must mirror what's in that file.
