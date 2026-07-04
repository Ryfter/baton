# Gate-Escalation Routing (Slice 1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When a `/baton:go` run's acceptance gate returns `reject` and the operator opted in with `-Escalate`, retry the whole goal ONCE with a raised cost-tier floor, then let the second verdict stand — with full event/decision/report legibility and both attempts costed into `effective-cost.json`.

**Architecture:** A new hard `-MinTier` filter in `Select-Capability` (routing-lib §3), a pure floor calculator + report-section renderer in conductor-lib, and `Invoke-Conductor` restructured from straight-line to a `while` attempt loop (max 2 iterations) that carries spend/decisions/taskCosts across attempts and calls `Complete-Run` exactly once. CLI grows `-Escalate` plus test seams. Spec: `docs/superpowers/specs/2026-07-04-gate-escalation-routing-design.md`.

**Tech Stack:** PowerShell 7 (pwsh), house Assert-style test suites (`Check` + exit codes), no new dependencies.

## Global Constraints

- Every shell command argument stays **under 965 bytes** (silent failure above).
- All file writes use `-Encoding utf8NoBOM`.
- CLI usage errors: `[Console]::Error.WriteLine(...)` + `exit 2` — NEVER `Write-Error; exit 2` (throws exit 1 first under `$ErrorActionPreference='Stop'`).
- Never name variables `$args`, `$input`, `$event`, `$matches`, `$host` (PowerShell automatic variables).
- Unary-comma return wrap (`return ,([object[]]$x)`) ONLY for direct-assignment consumers; use `return @($out)` when callers pipe. Do not re-wrap a comma-returned array in `@()` at the call site.
- Tests are hermetic: temp `BATON_HOME` set inside `try` and restored in `finally`; NEVER touch real `~/.baton` or `~/.claude`.
- **The no-flag path must be byte-for-byte unchanged**: a run without `-Escalate` must produce identical events.jsonl, decisions.jsonl, plan.json, report.md, acceptance.json, and effective-cost.json to today's code. Concretely: no new event fields on attempt 1, no event-id suffixes on attempt 1, `Complete-Run` defaults (`-Escalation $null -Attempts 1`) must not alter output.
- Escalation logic is fail-open: any internal error in the escalation decision degrades to today's `rejected` ending (warn event at most).
- Branch: `feature/gate-escalation-routing` (create from master before Task 1).

---

### Task 1: `Select-Capability -MinTier` hard filter

**Files:**
- Modify: `scripts/routing-lib.ps1` (param block ~line 109-119, filter §3 ~line 171-176)
- Test: `scripts/test-routing-lib.ps1` (append a new `MT` block before the final summary line)

**Interfaces:**
- Produces: `Select-Capability ... [-MinTier local|free|paid]` — candidates whose `cost_tier` ranks BELOW the floor are hard-filtered in §3, before usage governance (§3b) and learned re-rank (§3c), so a floored-out candidate can never be saturation-boosted back in. Unknown tiers (rank 3) are never filtered by the floor. Callers must OMIT the parameter rather than pass `''` (ValidateSet rejects empty string) — use a conditional splat.

- [ ] **Step 1: Add the parameter**

In `scripts/routing-lib.ps1`, in the `Select-Capability` param block, insert directly under the `MaxCostTier` line:

```powershell
        [ValidateSet('local','free','paid')][string]$MaxCostTier,
        [ValidateSet('local','free','paid')][string]$MinTier,
```

- [ ] **Step 2: Add the hard filter in §3**

Replace the §3 filter block:

```powershell
    # 3. Filter by constraints
    $filtered = foreach ($c in $candidates) {
        if ($RequireLocal -and $c.cost_tier -ne 'local') { continue }
        if ($MaxCostTier -and (Get-CostTierRank $c.cost_tier) -gt (Get-CostTierRank $MaxCostTier)) { continue }
        $c
    }
```

with:

```powershell
    # 3. Filter by constraints. -MinTier is the gate-escalation floor (hard filter,
    #    applied BEFORE saturation/learned re-rank so a floored-out candidate can
    #    never be boosted back in). Unknown tiers rank 3 -> never floor-filtered.
    $filtered = foreach ($c in $candidates) {
        if ($RequireLocal -and $c.cost_tier -ne 'local') { continue }
        if ($MaxCostTier -and (Get-CostTierRank $c.cost_tier) -gt (Get-CostTierRank $MaxCostTier)) { continue }
        if ($MinTier -and (Get-CostTierRank $c.cost_tier) -lt (Get-CostTierRank $MinTier)) { continue }
        $c
    }
```

- [ ] **Step 3: Add the MT test block**

In `scripts/test-routing-lib.ps1`, insert this block immediately BEFORE the final line (`if ($fail -gt 0) { ... }`):

```powershell
# ===== MT: -MinTier hard filter (gate-escalation floor) =====
$tmpM = Join-Path ([System.IO.Path]::GetTempPath()) ("routing-mintier-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $tmpM | Out-Null
try {
    $mtFleet = @"
general_capabilities: []

providers:
  - name: localw
    kind: cli
    enabled: true
    cost_tier: local
    capabilities: [code]
    command_template: 'echo x'
    saturate: true
    budget: 10
  - name: freew
    kind: cli
    enabled: true
    cost_tier: free
    capabilities: [code]
    command_template: 'echo x'
  - name: paidw
    kind: cli
    enabled: true
    cost_tier: paid
    capabilities: [code]
    command_template: 'echo x'
"@
    $ftM = Join-Path $tmpM 'fleet.yaml'; $mtFleet | Set-Content -LiteralPath $ftM -Encoding utf8NoBOM
    $mtNo = Join-Path $tmpM 'nope.jsonl'
    $mtArgs = @{ Capability='code'; FleetPath=$ftM; ToolsPath=(Join-Path $tmpM 'none.yaml')
                 RatingsPath=$mtNo; JournalPath=$mtNo; UsagePath=$mtNo; RunsRoot=(Join-Path $tmpM 'runs') }

    $mt0 = Select-Capability @mtArgs
    Check 'MT3 no floor: local first (regression)' (@($mt0)[0].name -eq 'localw' -and @($mt0).Count -eq 3)

    $mt1 = Select-Capability @mtArgs -MinTier free
    Check 'MT1 floor free excludes local' ((@($mt1).Count -eq 2) -and (@($mt1)[0].name -eq 'freew') -and (-not (@($mt1).name -contains 'localw')))

    $mt2 = Select-Capability @mtArgs -MinTier paid
    Check 'MT2 floor paid leaves only paid' ((@($mt2).Count -eq 1) -and (@($mt2)[0].name -eq 'paidw'))

    $mt4 = Select-Capability @mtArgs -MinTier free -MaxCostTier free
    Check 'MT4 floor+ceiling window leaves only free' ((@($mt4).Count -eq 1) -and (@($mt4)[0].name -eq 'freew'))

    # localw is saturate:true budget:10 — the boost must NOT resurrect a floored-out candidate.
    $mt5 = Select-Capability @mtArgs -MinTier free
    Check 'MT5 saturation cannot resurrect a floored-out local' (-not (@($mt5).name -contains 'localw'))
}
finally { Remove-Item -Recurse -Force $tmpM -ErrorAction SilentlyContinue }
```

- [ ] **Step 4: Run the routing suite**

Run: `pwsh -NoProfile -File scripts/test-routing-lib.ps1`
Expected: `ALL PASS` (all pre-existing checks + MT1–MT5).

- [ ] **Step 5: Commit**

```bash
git add scripts/routing-lib.ps1 scripts/test-routing-lib.ps1
git commit -m "feat(routing): Select-Capability -MinTier hard floor for gate-escalation"
```

---

### Task 2: Conductor pure helpers — `Get-EscalationFloor`, `Format-EscalationSection`, `Complete-Run` extensions

**Files:**
- Modify: `scripts/conductor-lib.ps1` (new functions after `Test-TaskDestructive` ~line 109; `Complete-Run` param block + report assembly ~lines 392-426)
- Test: `scripts/test-conductor-lib.ps1` (append ES1–ES6 before the final summary block)

**Interfaces:**
- Produces: `Get-EscalationFloor -Tasks <array>` → `'free' | 'paid' | $null` ($null = no higher tier exists / empty). Floor = one tier above the MINIMUM `est_cost_tier` across the attempt's tasks.
- Produces: `Format-EscalationSection -Escalation <hashtable>` → `## Escalation` markdown. Escalation payload shape (created in Task 3): `@{ attempted=[bool]; floor=[string-or-$null]; verdict_attempt1=[string]; outcome=[string] }`.
- Produces: `Complete-Run` gains `$Escalation = $null` (untyped) and `[int]$Attempts = 1`; when `$Escalation` is non-null the section is appended after the Acceptance section; `$Attempts` is threaded into `Get-RunCost -Attempts` so `effective-cost.json` records it. Defaults leave all existing output byte-identical.

- [ ] **Step 1: Write the failing tests (ES1–ES6)**

In `scripts/test-conductor-lib.ps1`, insert immediately BEFORE the `Write-Host ""` / final-summary block at the end of the main `try`:

```powershell
    # ---- Gate-escalation (slice 1): pure helpers ----
    $mkEs = { param($tier) [pscustomobject]@{ id='x'; desc='x'; command=''; capability=''; model_pick=''; depends_on=@(); est_cost_tier=$tier; reversible=$true } }
    Check 'ES1 floor above local is free' ((Get-EscalationFloor -Tasks @((& $mkEs 'local'), (& $mkEs 'paid'))) -eq 'free')
    Check 'ES2 floor above free is paid' ((Get-EscalationFloor -Tasks @((& $mkEs 'free'))) -eq 'paid')
    Check 'ES3 no tier above paid -> null' ($null -eq (Get-EscalationFloor -Tasks @((& $mkEs 'paid'))))
    Check 'ES4 empty tasks -> null' ($null -eq (Get-EscalationFloor -Tasks @()))

    $escA = @{ attempted = $true; floor = 'paid'; verdict_attempt1 = 'reject'; outcome = "final verdict 'accept' on attempt 2 -> completed" }
    $secA = Format-EscalationSection -Escalation $escA
    Check 'ES5 attempted section names floor + outcome' (($secA -match '## Escalation') -and ($secA -match "'paid'") -and ($secA -match 'attempt 2'))
    $escB = @{ attempted = $false; floor = $null; verdict_attempt1 = 'reject'; outcome = 'impossible: no tier above the failed attempt within the max-cost-tier ceiling' }
    $secB = Format-EscalationSection -Escalation $escB
    Check 'ES6 impossible section says no + why' (($secB -match '\*\*Escalated:\*\* no') -and ($secB -match 'impossible'))
```

- [ ] **Step 2: Run to verify failure**

Run: `pwsh -NoProfile -File scripts/test-conductor-lib.ps1`
Expected: `ERROR: The term 'Get-EscalationFloor' is not recognized...` (exit 1).

- [ ] **Step 3: Add the two pure functions**

In `scripts/conductor-lib.ps1`, insert after the closing brace of `Test-TaskDestructive` (~line 109):

```powershell
function Get-EscalationFloor {
    <# Gate-escalation (slice 1): one tier above the CHEAPEST est_cost_tier in the
       attempt's tasks. Returns 'free' | 'paid', or $null when no higher tier
       exists (cheapest already paid/unknown) or tasks are empty. #>
    param([array]$Tasks = @())
    if (@($Tasks).Count -eq 0) { return $null }
    $minRank = 99
    foreach ($t in @($Tasks)) {
        $r = Get-CostTierRank ([string]$t.est_cost_tier)
        if ($r -lt $minRank) { $minRank = $r }
    }
    switch ($minRank) {
        0 { return 'free' }
        1 { return 'paid' }
        default { return $null }   # paid (2) or unknown (3): nothing higher to escalate to
    }
}

function Format-EscalationSection {
    <# Render the `## Escalation` markdown block from the escalation payload
       (@{attempted; floor; verdict_attempt1; outcome}). #>
    param([Parameter(Mandatory)]$Escalation)
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine('## Escalation')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine("**Attempt 1 verdict:** $($Escalation.verdict_attempt1)")
    if ($Escalation.attempted) {
        [void]$sb.AppendLine("**Escalated:** yes — tier floor raised to '$($Escalation.floor)' (attempt 1 artifacts kept as *.attempt1.json)")
    } else {
        [void]$sb.AppendLine('**Escalated:** no')
    }
    if ($Escalation.outcome) { [void]$sb.AppendLine("**Outcome:** $($Escalation.outcome)") }
    return $sb.ToString().TrimEnd()
}
```

- [ ] **Step 4: Extend `Complete-Run`**

In `Complete-Run`'s param block, replace:

```powershell
        $Gate = $null,
        [object[]]$TaskCosts = @()
```

with:

```powershell
        $Gate = $null,
        [object[]]$TaskCosts = @(),
        $Escalation = $null,
        [int]$Attempts = 1
```

Then, directly after the existing gate-section block:

```powershell
    if ($Gate) {
        $report = $report + "`n`n" + (Format-AcceptanceSection -Gate $Gate)
        ($Gate | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath (Join-Path $RunDir 'acceptance.json') -Encoding utf8NoBOM
    }
```

insert:

```powershell
    if ($Escalation) { $report = $report + "`n`n" + (Format-EscalationSection -Escalation $Escalation) }
```

Then in the effective-cost block, replace:

```powershell
        $runCost   = Get-RunCost -Tasks @($TaskCosts) -CostResolver { param($t) Get-RealizedTaskCost -Task $t -RunDir $RunDir }
```

with:

```powershell
        $runCost   = Get-RunCost -Tasks @($TaskCosts) -CostResolver { param($t) Get-RealizedTaskCost -Task $t -RunDir $RunDir } -Attempts $Attempts
```

- [ ] **Step 5: Run tests**

Run: `pwsh -NoProfile -File scripts/test-conductor-lib.ps1`
Expected: `ALL CHECKS PASS` (every pre-existing check — the byte-for-byte defaults guard — plus ES1–ES6).

- [ ] **Step 6: Commit**

```bash
git add scripts/conductor-lib.ps1 scripts/test-conductor-lib.ps1
git commit -m "feat(conductor): escalation floor + report section + Complete-Run attempts threading"
```

---

### Task 3: `Invoke-Conductor` attempt loop + `-MinTier` threading

**Files:**
- Modify: `scripts/conductor-lib.ps1` (`Invoke-PlanPhase` ~line 317, `Invoke-TaskViaFleet` ~line 369, `Invoke-Conductor` ~line 478 — full-body replacement)
- Test: `scripts/test-conductor-lib.ps1` (ES7–ES16)

**Interfaces:**
- Consumes: Task 1's `Select-Capability -MinTier` (conditional splat — never pass `''`); Task 2's `Get-EscalationFloor`, `Format-EscalationSection`, `Complete-Run -Escalation/-Attempts`.
- Produces: `Invoke-Conductor ... [-Escalate]`. Seam contract extension (backward-compatible — extra scriptblock args are ignored by `param($x)`-only seams): `& $Planner $Goal $minTier` and `& $Spawner $task $minTier`, where `$minTier` is `''` on attempt 1 and the floor string on attempt 2.
- Produces: attempt-2 ledger ids are suffixed `<task_id>#2` in events.jsonl / decisions.jsonl / the taskCosts list (so `Get-RealizedTaskCost`'s per-id event windows never collide across attempts); plan.json ids stay clean. Attempt 1 artifacts preserved as `plan.attempt1.json` + `acceptance.attempt1.json`.

- [ ] **Step 1: Write the failing tests (ES7–ES16)**

Append to `scripts/test-conductor-lib.ps1`, directly after the ES1–ES6 block from Task 2 (still inside the main `try`):

```powershell
    # ---- Gate-escalation (slice 1): Invoke-Conductor attempt loop ----
    $esHome = Join-Path ([System.IO.Path]::GetTempPath()) "cond-esc-$([System.IO.Path]::GetRandomFileName())"
    New-Item -ItemType Directory -Force -Path $esHome | Out-Null
    $esPrevHome = $env:BATON_HOME
    $env:BATON_HOME = $esHome
    try {
        $mkT = { param($id,$deps,$tier='free',$rev=$true) [pscustomobject]@{ id=$id; desc="do $id"; command='x'; capability='reasoning'; model_pick=''; depends_on=@($deps); est_cost_tier=$tier; reversible=$rev } }
        $mkGateSeq = {
            # Returns a Gater whose verdict follows the given sequence across calls.
            param([string[]]$seq)
            $st = @{ n = 0; seq = $seq }
            return {
                param($a, $g)
                $i = [math]::Min($st.n, $st.seq.Count - 1)
                $st.n++
                @{ verdict = $st.seq[$i]; reason = 'seq-stub'; counts = @{ critical = 0; important = 0; minor = 0 }; polish_brief = 'b'; findings = @(); reviews = @(); unparsed = @() }
            }.GetNewClosure()
        }

        # ES7-ES12: reject on attempt 1, accept on attempt 2.
        $esPlanner = { param($goal, $floor) @{ run_id='x'; goal=$goal; budget_cap=$null; tasks=@( (& $mkT 'e1' @() 'paid') ) } }
        $esFloors = [System.Collections.ArrayList]@()
        $esSpawner = { param($task, $floor) [void]$esFloors.Add("$($task.id):$floor"); @{ ok=$true; spend=0.0; chose='esc-stub'; why='x'; alternatives=@() } }
        $esRun1 = Join-Path $esHome 'runs/go-es-1'
        $rEs1 = Invoke-Conductor -Goal 'escalate me' -RunDir $esRun1 -Planner $esPlanner -Spawner $esSpawner `
            -GateArtifact 'art' -Gater (& $mkGateSeq @('reject','accept')) -Escalate
        Check 'ES7 reject->accept with -Escalate completes' ($rEs1.status -eq 'completed')
        Check 'ES8 attempt-1 artifacts preserved' ((Test-Path (Join-Path $esRun1 'plan.attempt1.json')) -and (Test-Path (Join-Path $esRun1 'acceptance.attempt1.json')))
        $esEv1 = Get-Content -LiteralPath (Join-Path $esRun1 'events.jsonl') -Raw
        Check 'ES9 escalation event + decision logged' (($esEv1 -match '"kind":"escalation"') -and ((Get-Content -LiteralPath (Join-Path $esRun1 'decisions.jsonl') -Raw) -match '"chose":"escalate"'))
        Check 'ES10 report carries ## Escalation' ($rEs1.report -match '## Escalation')
        Check 'ES11 attempt-2 spawn saw floor free with suffixed ledger id' (($esFloors -contains 'e1:') -and ($esFloors -contains 'e1:free') -and ($esEv1 -match '"task_id":"e1#2"'))
        $esEc1 = Get-Content -Raw -LiteralPath (Join-Path $esRun1 'effective-cost.json') | ConvertFrom-Json
        Check 'ES12 effective cost sums both attempts, attempts=2' (([double]$esEc1.cost -eq 0.1) -and ([int]$esEc1.attempts -eq 2))

        # ES13: no -Escalate -> today's rejected ending, no escalation artifacts (regression).
        $esRun2 = Join-Path $esHome 'runs/go-es-2'
        $rEs2 = Invoke-Conductor -Goal 'no flag' -RunDir $esRun2 -Planner $esPlanner -Spawner $esSpawner `
            -GateArtifact 'art' -Gater (& $mkGateSeq @('reject'))
        $esEv2 = Get-Content -LiteralPath (Join-Path $esRun2 'events.jsonl') -Raw
        Check 'ES13 no flag: rejected, no escalation traces' (($rEs2.status -eq 'rejected') -and (-not (Test-Path (Join-Path $esRun2 'plan.attempt1.json'))) -and ($esEv2 -notmatch 'escalation') -and ($rEs2.report -notmatch '## Escalation'))

        # ES14: reject on BOTH attempts -> rejected, escalation outcome in report.
        $esPlannerF = { param($goal, $floor) @{ run_id='x'; goal=$goal; budget_cap=$null; tasks=@( (& $mkT 'f1' @() 'free') ) } }
        $esRun3 = Join-Path $esHome 'runs/go-es-3'
        $rEs3 = Invoke-Conductor -Goal 'double reject' -RunDir $esRun3 -Planner $esPlannerF -Spawner $esSpawner `
            -GateArtifact 'art' -Gater (& $mkGateSeq @('reject','reject')) -Escalate
        Check 'ES14 double reject: final rejected + outcome rendered' (($rEs3.status -eq 'rejected') -and ($rEs3.report -match '## Escalation') -and ($rEs3.report -match 'attempt 2'))

        # ES15: cheapest tier already paid -> no higher floor -> escalation-impossible.
        $esRun4 = Join-Path $esHome 'runs/go-es-4'
        $rEs4 = Invoke-Conductor -Goal 'cannot escalate' -RunDir $esRun4 -Planner $esPlanner -Spawner $esSpawner `
            -GateArtifact 'art' -Gater (& $mkGateSeq @('reject','reject')) -Escalate
        $esEv4 = Get-Content -LiteralPath (Join-Path $esRun4 'events.jsonl') -Raw
        Check 'ES15 paid-floor impossible: rejected + escalation-impossible event, single attempt' (($rEs4.status -eq 'rejected') -and ($esEv4 -match 'escalation-impossible') -and (-not (Test-Path (Join-Path $esRun4 'plan.attempt1.json'))))

        # ES16: attempt-1 estimated spend carries into attempt 2's budget guard.
        # Plan: free t1 (est 0) + paid t2 (est 0.05). Cap 0.07: attempt 1 fits (0.05),
        # attempt 2 carries 0.05 -> t2#2 would hit 0.10 > 0.07 -> interrupted-budget.
        $esPlannerB = { param($goal, $floor) @{ run_id='x'; goal=$goal; budget_cap=$null; tasks=@( (& $mkT 'b1' @() 'free'), (& $mkT 'b2' @('b1') 'paid') ) } }
        $esRun5 = Join-Path $esHome 'runs/go-es-5'
        $rEs5 = Invoke-Conductor -Goal 'budget carry' -RunDir $esRun5 -BudgetCap 0.07 -Planner $esPlannerB -Spawner $esSpawner `
            -GateArtifact 'art' -Gater (& $mkGateSeq @('reject','accept')) -Escalate
        Check 'ES16 combined budget interrupts attempt 2' (($rEs5.status -eq 'interrupted-budget') -and ($rEs5.pending_task_id -eq 'b2'))
    } finally {
        $env:BATON_HOME = $esPrevHome
        Remove-Item -Recurse -Force $esHome -ErrorAction SilentlyContinue
    }
```

- [ ] **Step 2: Run to verify failure**

Run: `pwsh -NoProfile -File scripts/test-conductor-lib.ps1`
Expected: FAIL — `Invoke-Conductor` has no `-Escalate` parameter (parameter-binding error caught as `ERROR: ...`, exit 1).

- [ ] **Step 3: Thread `-MinTier` through `Invoke-PlanPhase`**

Add to `Invoke-PlanPhase`'s param block, after `[ValidateSet('local','free','paid')][string]$MaxCostTier = 'paid',`:

```powershell
        [string]$MinTier,
```

Replace the candidate-selection line:

```powershell
    $cands = Select-Capability -Capability reasoning -MaxCostTier $MaxCostTier -FleetPath $FleetPath -ToolsPath $ToolsPath
```

with:

```powershell
    $selp = @{ Capability = 'reasoning'; MaxCostTier = $MaxCostTier; FleetPath = $FleetPath; ToolsPath = $ToolsPath }
    if ($MinTier) { $selp.MinTier = $MinTier }   # ValidateSet rejects '': only splat when set
    $cands = Select-Capability @selp
```

- [ ] **Step 4: Thread `-MinTier` through `Invoke-TaskViaFleet`**

Add to `Invoke-TaskViaFleet`'s param block, after the `MaxCostTier` line:

```powershell
        [string]$MinTier,
```

Replace:

```powershell
    $cands = Select-Capability -Capability $cap -MaxCostTier $MaxCostTier -FleetPath $FleetPath -ToolsPath $ToolsPath
```

with:

```powershell
    $selp = @{ Capability = $cap; MaxCostTier = $MaxCostTier; FleetPath = $FleetPath; ToolsPath = $ToolsPath }
    if ($MinTier) { $selp.MinTier = $MinTier }
    $cands = Select-Capability @selp
```

- [ ] **Step 5: Replace `Invoke-Conductor` with the attempt loop**

Replace the ENTIRE `Invoke-Conductor` function with:

```powershell
function Invoke-Conductor {
    <# Full-auto engine: plan, then walk the DAG under the two interrupt guards,
       logging events/decisions, and render a report. -Planner/-Spawner/-Dispatcher
       inject for tests; real path uses Invoke-PlanPhase + Invoke-TaskViaFleet.
       -Escalate (gate-escalation slice 1): on a gate verdict of 'reject', retry the
       whole goal ONCE with a raised tier floor (Get-EscalationFloor); the second
       verdict is final. Fail-open: any error inside the escalation decision
       degrades to today's 'rejected' ending. Seam contract: seams receive the
       floor as a second argument (& $Planner $Goal $minTier / & $Spawner $task
       $minTier) — scriptblocks declaring only param($x) ignore it. #>
    param(
        [Parameter(Mandatory)][string]$Goal,
        [string]$RunDir,
        $BudgetCap = $null,
        [double]$PaidPerCall = 0.05,
        [ValidateSet('local','free','paid')][string]$MaxCostTier = 'paid',
        [string]$FleetPath = (Join-Path (Get-BatonHome) 'fleet.yaml'),
        [string]$ToolsPath = (Join-Path (Get-BatonHome) 'tools.yaml'),
        [scriptblock]$Planner,
        [scriptblock]$Spawner,
        [scriptblock]$Dispatcher,
        [string]$GateArtifact,
        [string]$GateDiff,
        [scriptblock]$Gater,
        [switch]$Escalate
    )
    if (-not $RunDir) { $RunDir = Initialize-RunDir }
    else { New-Item -ItemType Directory -Force -Path $RunDir | Out-Null }
    $runId = Split-Path $RunDir -Leaf

    # Attempt state — spend/decisions/taskCosts accumulate ACROSS attempts so the
    # budget guard and effective-cost see the whole run, not just the last attempt.
    $spend = 0.0
    $decisions = [System.Collections.ArrayList]@()
    $taskCosts = [System.Collections.ArrayList]@()
    $attempt = 1
    $minTier = ''       # '' = no floor (attempt 1)
    $escalation = $null

    while ($true) {
        # 1. Plan phase. Attempt 2 re-plans (a stronger worker may decompose
        #    differently) but does NOT pass -RunDir: shadow A/B assignment stays
        #    attempt 1's. Known v1 edge: an escalated challenger-assigned run
        #    accrues both attempts' cost to the challenger while attempt 2 planned
        #    with the live champion chain — conservative direction (inflates
        #    challenger cost, errs toward retire).
        $plan = if ($Planner) { & $Planner $Goal $minTier }
                else {
                    $pp = @{ Goal = $Goal; RunId = $runId; BudgetCap = $BudgetCap; MaxCostTier = $MaxCostTier
                             FleetPath = $FleetPath; ToolsPath = $ToolsPath; Dispatcher = $Dispatcher }
                    if ($attempt -eq 1) { $pp.RunDir = $RunDir }
                    if ($minTier) { $pp.MinTier = $minTier }
                    Invoke-PlanPhase @pp
                }
        if ($null -eq $plan) {
            Add-RunEvent -RunDir $RunDir -EventObj (New-RunEvent -Kind 'error' -Level 'error' -Message 'planning failed')
            $empty = @{ run_id = $runId; goal = $Goal; budget_cap = $BudgetCap; tasks = @() }
            return (Complete-Run -RunDir $RunDir -Plan $empty -Decisions $decisions -Spend $spend -Status 'plan-failed' -Escalation $escalation -Attempts $attempt)
        }
        $plan.run_id = $runId
        ($plan | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath (Join-Path $RunDir 'plan.json') -Encoding utf8NoBOM
        Add-RunEvent -RunDir $RunDir -EventObj (New-RunEvent -Kind 'started' -Message "plan: $(@($plan.tasks).Count) tasks")

        # 2. Order the DAG.
        try { $order = Resolve-TaskOrder -Tasks @($plan.tasks) }
        catch {
            Add-RunEvent -RunDir $RunDir -EventObj (New-RunEvent -Kind 'error' -Level 'error' -Message $_.Exception.Message)
            return (Complete-Run -RunDir $RunDir -Plan $plan -Decisions $decisions -Spend $spend -Status 'plan-invalid' -Escalation $escalation -Attempts $attempt)
        }

        # 3. Guarded walk. Attempt-2 ledger ids get a '#2' suffix so per-id event
        #    windows (Get-RealizedTaskCost) never collide across attempts.
        foreach ($task in $order) {
            $evId = if ($attempt -gt 1) { "$($task.id)#$attempt" } else { [string]$task.id }
            $est = Get-TaskCostEstimate -Tier $task.est_cost_tier -PaidPerCall $PaidPerCall
            if (Test-BudgetExceeded -CumulativeSpend $spend -TaskEstimate $est -BudgetCap $BudgetCap) {
                Add-RunEvent -RunDir $RunDir -EventObj (New-RunEvent -TaskId $evId -Kind 'interrupt' -Level 'warn' -Message "budget: would cross cap at $($task.id)")
                return (Complete-Run -RunDir $RunDir -Plan $plan -Decisions $decisions -Spend $spend -Status 'interrupted-budget' -PendingTaskId $task.id -Escalation $escalation -Attempts $attempt)
            }
            if (Test-TaskDestructive -Task $task) {
                Add-RunEvent -RunDir $RunDir -EventObj (New-RunEvent -TaskId $evId -Kind 'interrupt' -Level 'warn' -Message "destructive: $($task.id) is reversible:false")
                return (Complete-Run -RunDir $RunDir -Plan $plan -Decisions $decisions -Spend $spend -Status 'interrupted-destructive' -PendingTaskId $task.id -Escalation $escalation -Attempts $attempt)
            }
            Add-RunEvent -RunDir $RunDir -EventObj (New-RunEvent -TaskId $evId -Kind 'started' -Message $task.desc)
            $r = if ($Spawner) { & $Spawner $task $minTier }
                 else {
                    $tv = @{ Task = $task; FleetPath = $FleetPath; ToolsPath = $ToolsPath; MaxCostTier = $MaxCostTier; Dispatcher = $Dispatcher }
                    if ($minTier) { $tv.MinTier = $minTier }
                    Invoke-TaskViaFleet @tv
                 }
            $tspend = if ($null -ne $r.spend) { [double]$r.spend } else { $est }
            $spend += $tspend
            if ($r.chose) {
                $dec = New-RunDecision -TaskId $evId -Chose ([string]$r.chose) -Alternatives (@($r.alternatives)) -Why ([string]$r.why) -CostTier $task.est_cost_tier
                Add-RunDecision -RunDir $RunDir -Decision $dec
                [void]$decisions.Add($dec)
            }
            # Numerator is the cost-tier ESTIMATE (basis='estimate'), matching the budget
            # guard and the record's label — realized spend ($tspend) is a placeholder
            # (0.0) today; realized cost arrives later via Get-RunCost's -CostResolver seam.
            [void]$taskCosts.Add(@{ id = $evId; worker = ([string]$r.chose); cost = $est })
            Add-RunEvent -RunDir $RunDir -EventObj (New-RunEvent -TaskId $evId -Kind 'spent' -Message ("{0:0.00}" -f $tspend))
            $kind = if ($r.ok) { 'finished' } else { 'error' }
            Add-RunEvent -RunDir $RunDir -EventObj (New-RunEvent -TaskId $evId -Kind $kind -Message $task.desc)
            if (-not $r.ok) {
                return (Complete-Run -RunDir $RunDir -Plan $plan -Decisions $decisions -Spend $spend -Status 'failed' -PendingTaskId $task.id -Escalation $escalation -Attempts $attempt)
            }
        }

        # 4. Acceptance phase (d058): opt-in, advisory, fail-open. Runs only after a
        #    successful walk and only when a gate target resolves.
        $gate = $null
        $finalStatus = 'completed'
        $art = Resolve-GateArtifact -Artifact $GateArtifact -Diff $GateDiff
        if (-not [string]::IsNullOrWhiteSpace($art)) {
            $gateErr = $null
            try {
                $gate = if ($Gater) { & $Gater $art $plan.goal }
                        else { Invoke-AcceptanceGate -Artifact $art -Task $plan.goal -MaxCostTier $MaxCostTier -FleetPath $FleetPath -ToolsPath $ToolsPath }
            } catch { $gate = $null; $gateErr = $_.Exception.Message }
            if ($null -eq $gate -or -not $gate.verdict) {
                $msg = if ($gateErr) { "acceptance gate failed: $gateErr" } else { 'acceptance gate produced no verdict (fail-open)' }
                Add-RunEvent -RunDir $RunDir -EventObj (New-RunEvent -Kind 'gate' -Level 'warn' -Message $msg)
                $gate = $null
            } else {
                Add-RunEvent -RunDir $RunDir -EventObj (New-RunEvent -Kind 'gate' -Message "acceptance verdict: $($gate.verdict) — $($gate.reason)")
                if ($gate.verdict -eq 'reject') { $finalStatus = 'rejected' }
            }
        }

        # 5. Gate-escalation (slice 1): reject + -Escalate + first attempt -> retry
        #    once with a raised floor. Everything here is fail-open.
        if (($finalStatus -eq 'rejected') -and $Escalate -and ($attempt -eq 1)) {
            try {
                $floor = Get-EscalationFloor -Tasks @($plan.tasks)
                $floorOk = ($null -ne $floor) -and ((Get-CostTierRank $floor) -le (Get-CostTierRank $MaxCostTier))
                $canRoute = $false
                if ($floorOk) {
                    # Pre-flight: someone must clear the floor before we spend on a
                    # re-plan. Injected seams bypass routing — skip the check then.
                    if ($Planner -or $Spawner) { $canRoute = $true }
                    else {
                        $pre = @(Select-Capability -Capability reasoning -MinTier $floor -MaxCostTier $MaxCostTier -FleetPath $FleetPath -ToolsPath $ToolsPath | Where-Object { $null -ne $_ })
                        $canRoute = (@($pre).Count -gt 0)
                    }
                }
                if ($floorOk -and $canRoute) {
                    Move-Item -LiteralPath (Join-Path $RunDir 'plan.json') -Destination (Join-Path $RunDir 'plan.attempt1.json') -Force
                    ($gate | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath (Join-Path $RunDir 'acceptance.attempt1.json') -Encoding utf8NoBOM
                    # Carry attempt 1's ESTIMATED spend into the shared budget number.
                    $estSpend = 0.0
                    foreach ($tc in $taskCosts) { $estSpend += [double]$tc.cost }
                    if ($estSpend -gt $spend) { $spend = $estSpend }
                    Add-RunEvent -RunDir $RunDir -EventObj (New-RunEvent -Kind 'escalation' -Level 'warn' -Message "gate verdict reject on attempt 1 — escalating once with tier floor '$floor'")
                    $dec = New-RunDecision -Chose 'escalate' -Alternatives @('end-rejected') -Why "attempt 1 rejected by the acceptance gate; retrying once with tier floor '$floor'" -CostTier $floor
                    Add-RunDecision -RunDir $RunDir -Decision $dec
                    [void]$decisions.Add($dec)
                    $escalation = @{ attempted = $true; floor = $floor; verdict_attempt1 = [string]$gate.verdict; outcome = '' }
                    $minTier = $floor
                    $attempt = 2
                    continue
                }
                $why = if (-not $floorOk) { 'no tier above the failed attempt within the max-cost-tier ceiling' } else { "no candidate at or above tier floor '$floor'" }
                Add-RunEvent -RunDir $RunDir -EventObj (New-RunEvent -Kind 'escalation-impossible' -Level 'warn' -Message "cannot escalate: $why — run ends rejected")
                $escalation = @{ attempted = $false; floor = $floor; verdict_attempt1 = [string]$gate.verdict; outcome = "impossible: $why" }
            } catch {
                try { Add-RunEvent -RunDir $RunDir -EventObj (New-RunEvent -Kind 'escalation' -Level 'warn' -Message "escalation failed (run unaffected): $($_.Exception.Message)") } catch { }
            }
        }
        if ($escalation -and $escalation.attempted -and (-not $escalation.outcome)) {
            $v2 = if ($gate) { [string]$gate.verdict } else { 'none' }
            $escalation.outcome = "final verdict '$v2' on attempt 2 -> $finalStatus"
        }
        return (Complete-Run -RunDir $RunDir -Plan $plan -Decisions $decisions -Spend $spend -Status $finalStatus -Gate $gate -TaskCosts $taskCosts -Escalation $escalation -Attempts $attempt)
    }
}
```

- [ ] **Step 6: Run tests**

Run: `pwsh -NoProfile -File scripts/test-conductor-lib.ps1`
Expected: `ALL CHECKS PASS` — every pre-existing check (T1–T88, SB1–SB12: the no-flag byte-for-byte guard) plus ES1–ES16.

- [ ] **Step 7: Commit**

```bash
git add scripts/conductor-lib.ps1 scripts/test-conductor-lib.ps1
git commit -m "feat(conductor): gate-escalation attempt loop — escalate-once on reject with raised tier floor"
```

---

### Task 4: CLI — `-Escalate` flag, usage validation, test seams

**Files:**
- Modify: `scripts/fleet-go.ps1`
- Test: `scripts/test-conductor-lib.ps1` (ES17–ES19, placed with the existing CLI-seam checks near T60c)

**Interfaces:**
- Consumes: Task 3's `Invoke-Conductor -Escalate`.
- Produces: `fleet-go.ps1 -Escalate`; env seams `BATON_GO_TEST_ESCALATE=1` (forces the flag on) and `BATON_GO_TEST_GATE` extended to a comma-separated verdict SEQUENCE (`'reject,accept'` → 1st gate call rejects, 2nd+ accepts; a single value behaves exactly as today — T60c must stay green).

- [ ] **Step 1: Add the param**

In `scripts/fleet-go.ps1`, add to the param block after `[string]$GateDiff,`:

```powershell
    [switch]$Escalate,
```

- [ ] **Step 2: Extend the gate seam to a verdict sequence + wire escalate**

Replace the existing gate-seam block:

```powershell
if ($env:BATON_GO_TEST_GATE) {
    $cannedVerdict = $env:BATON_GO_TEST_GATE
    $go['Gater'] = { param($art, $goal) @{ verdict = $cannedVerdict; reason = 'test-stub verdict'; counts = @{ critical = 0; important = 0; minor = 0 }; polish_brief = 'test brief'; findings = @(); reviews = @(); unparsed = @() } }.GetNewClosure()
    if (-not $go.ContainsKey('GateArtifact')) { $go['GateArtifact'] = 'test artifact' }
}
```

with:

```powershell
if ($env:BATON_GO_TEST_GATE) {
    # Verdict sequence: 'reject,accept' -> reject on the 1st gate call, accept on
    # the 2nd+. A single value is a constant (today's behavior, T60c unchanged).
    $verdictSeq = @($env:BATON_GO_TEST_GATE -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $gateCall = @{ n = 0 }
    $go['Gater'] = {
        param($art, $goal)
        $i = [math]::Min($gateCall.n, $verdictSeq.Count - 1)
        $gateCall.n++
        @{ verdict = $verdictSeq[$i]; reason = 'test-stub verdict'; counts = @{ critical = 0; important = 0; minor = 0 }; polish_brief = 'test brief'; findings = @(); reviews = @(); unparsed = @() }
    }.GetNewClosure()
    if (-not $go.ContainsKey('GateArtifact')) { $go['GateArtifact'] = 'test artifact' }
}
if ($env:BATON_GO_TEST_ESCALATE -eq '1') { $Escalate = $true }
if ($Escalate) {
    # The gate verdict is the escalation trigger: a gate target is mandatory.
    if (-not ($go.ContainsKey('GateArtifact') -or $go.ContainsKey('GateDiff'))) {
        [Console]::Error.WriteLine('-Escalate requires a gate target (-GateArtifact or -GateDiff): the gate verdict is the escalation trigger.')
        exit 2
    }
    $go['Escalate'] = $true
}
```

(The check reads `$go`, not `$PSBoundParameters`, so the `BATON_GO_TEST_GATE` seam's implicit `'test artifact'` satisfies it — the seam block above must stay ordered before this block.)

- [ ] **Step 3: Write the CLI tests (ES17–ES19)**

In `scripts/test-conductor-lib.ps1`, append after the ES7–ES16 block (still in the main `try`; a fresh temp home because the CLI reads `BATON_HOME`):

```powershell
    # ---- Gate-escalation: CLI flag + seams ----
    $ecHome = Join-Path ([System.IO.Path]::GetTempPath()) "cond-esc-cli-$([System.IO.Path]::GetRandomFileName())"
    New-Item -ItemType Directory -Force -Path $ecHome | Out-Null
    $ecPrevHome = $env:BATON_HOME
    $env:BATON_HOME = $ecHome
    try {
        $goCli = Join-Path $PSScriptRoot 'fleet-go.ps1'
        $ecPlan = '{"tasks":[{"id":"c1","desc":"work","command":"","capability":"reasoning","depends_on":[],"est_cost_tier":"free","reversible":true}]}'

        # ES17: -Escalate without any gate target -> usage error, exit 2.
        & pwsh -NoProfile -File $goCli -Goal 'g' -Escalate 2>$null | Out-Null
        Check 'ES17 CLI -Escalate without gate target exits 2' ($LASTEXITCODE -eq 2)

        # ES18: full escalation round-trip through the env seams.
        $env:BATON_GO_TEST_PLAN = $ecPlan
        $env:BATON_GO_TEST_SPAWN = '1'
        $env:BATON_GO_TEST_GATE = 'reject,accept'
        $env:BATON_GO_TEST_ESCALATE = '1'
        $outE = (& pwsh -NoProfile -File $goCli -Goal 'escalate me' 2>&1 | Out-String)
        Check 'ES18 CLI escalation completes with section' (($outE -match 'Status: completed') -and ($outE -match '## Escalation'))

        # ES19: sequence seam is backward compatible — single value + no escalate.
        Remove-Item Env:\BATON_GO_TEST_ESCALATE -ErrorAction SilentlyContinue
        $env:BATON_GO_TEST_GATE = 'reject'
        $outR = (& pwsh -NoProfile -File $goCli -Goal 'plain reject' 2>&1 | Out-String)
        Check 'ES19 single-verdict seam still rejects (no escalation)' (($outR -match 'Status: rejected') -and ($outR -notmatch '## Escalation'))
    } finally {
        foreach ($v in 'BATON_GO_TEST_PLAN','BATON_GO_TEST_SPAWN','BATON_GO_TEST_GATE','BATON_GO_TEST_ESCALATE') {
            Remove-Item "Env:\$v" -ErrorAction SilentlyContinue
        }
        $env:BATON_HOME = $ecPrevHome
        Remove-Item -Recurse -Force $ecHome -ErrorAction SilentlyContinue
    }
```

- [ ] **Step 4: Run tests**

Run: `pwsh -NoProfile -File scripts/test-conductor-lib.ps1`
Expected: `ALL CHECKS PASS` including T60c (single-verdict regression) and ES17–ES19.

- [ ] **Step 5: Commit**

```bash
git add scripts/fleet-go.ps1 scripts/test-conductor-lib.ps1
git commit -m "feat(go): -Escalate CLI flag, gate-target validation, verdict-sequence test seam"
```

---

### Task 5: Docs, version bump, regression sweep

**Files:**
- Modify: `commands/go.md`, `.claude-plugin/plugin.json`

**Interfaces:** none (docs only).

- [ ] **Step 1: Document the flag in `commands/go.md`**

Read `commands/go.md`; append this section immediately after the section documenting the acceptance gate flags (`--gate-artifact` / `--gate-diff`); if no such section heading exists, append at the end of the options/flags documentation:

```markdown
### Escalation (`--escalate`)

Opt-in, requires a gate target (`--gate-artifact` or `--gate-diff`) — the gate
verdict is the trigger. When the acceptance gate returns `reject`, the run
retries ONCE: a fresh plan and execution of the same goal with a raised
cost-tier floor (one tier above the cheapest tier the failed attempt used),
then the second verdict is final. `polish` never escalates (the polish brief /
auto-polish loop is a separate feature).

Legibility: an `escalation` event + a decision-ledger row + an `## Escalation`
report section; attempt-1 artifacts are preserved as `plan.attempt1.json` and
`acceptance.attempt1.json`; attempt-2 ledger entries carry `#2`-suffixed task
ids. Both attempts share ONE budget cap (attempt 1's estimated spend counts
against attempt 2's guard) and both attempts' costs land in
`effective-cost.json` (`attempts: 2`) — a cheap worker that needed a premium
redo is priced honestly on the leaderboard. If no worker clears the raised
floor, the run ends `rejected` with an `escalation-impossible` event.
```

- [ ] **Step 2: Bump the plugin version**

In `.claude-plugin/plugin.json`, bump `"version"` from its current value to the **next free RC on the v1.9 line at build time** (expected `1.9.0-rc.1`; if another branch already claimed it, take the next free `-rc.N`).

- [ ] **Step 3: Full regression sweep**

Run each; ALL must exit 0:

```
pwsh -NoProfile -File scripts/test-conductor-lib.ps1
pwsh -NoProfile -File scripts/test-routing-lib.ps1
pwsh -NoProfile -File scripts/test-fleet-dispatch.ps1
pwsh -NoProfile -File scripts/test-effective-cost-lib.ps1
pwsh -NoProfile -File scripts/test-prompt-pool-lib.ps1
pwsh -NoProfile -File scripts/test-cost-resolver-lib.ps1
pwsh -NoProfile -File scripts/test-bootstrap.ps1
```

Expected: `ALL PASS` / `ALL CHECKS PASS` per suite, exit 0 each.

- [ ] **Step 4: Commit**

```bash
git add commands/go.md .claude-plugin/plugin.json
git commit -m "docs(go): --escalate documentation + version bump for gate-escalation slice 1"
```

---

## Ambiguities resolved (spec → plan)

1. **"Floor = one tier above the cheapest tier actually used"** → implemented as one tier above the minimum `est_cost_tier` across attempt-1's plan tasks (chosen workers' tiers aren't recorded in taskCosts; est_cost_tier is what drove the budget guard, so it's the consistent basis).
2. **Recursion vs loop** → a `while` attempt loop with ONE terminal `Complete-Run`, because naive recursion would double-write report.md/acceptance.json/effective-cost.json and lose cross-attempt cost accumulation.
3. **`attempt: 2` stamped in events** → realized as a `#2` suffix on attempt-2 ledger task ids instead of a new event field: a new field on every event would break the no-flag byte-for-byte guarantee, and the suffix simultaneously fixes `Get-RealizedTaskCost`'s per-id event-window collision for duplicate task ids across attempts.
4. **Budget "attempt 1's spend"** → attempt 1's estimated spend (sum of its taskCosts estimates) is folded into the cumulative `$spend` at escalation time (realized `$tspend` is still the 0.0 placeholder today; estimates match the guard's existing estimate-gate semantics, d-cg-2 preserved).
5. **Shadow A/B interaction (unspecified in the spec)** → attempt 2 re-plans WITHOUT `-RunDir`, so no second shadow assignment/event; attempt 1's `shadow.json` stands. Known v1 edge documented in code: a challenger-assigned escalated run accrues both attempts' cost to the challenger while attempt 2 planned with the champion chain — errs in the stop-spending direction (inflates challenger cost).
6. **`BATON_GO_TEST_ESCALATE` seam semantics** → `'1'` forces `-Escalate` on; the second-verdict need is covered by extending `BATON_GO_TEST_GATE` to a comma-separated verdict sequence (single value = constant, backward compatible — T60c proves it).
7. **`-Escalate` without gate target under the test seam** → validation reads the assembled `$go` hashtable (not `$PSBoundParameters`), so the gate seam's implicit `'test artifact'` target satisfies it.

## Execution Handoff

Branch: `feature/gate-escalation-routing` (from master). Subagent-driven (standing default), streamlined ceremony (no per-task reviewers; one opus whole-branch final review before PR).

| Task | Content | Model |
|------|---------|-------|
| 1 | routing floor + MT tests (complete code above) | haiku (transcription) |
| 2 | pure helpers + Complete-Run params (complete code above) | haiku (transcription) |
| 3 | Invoke-Conductor attempt loop (complete code, but a full-function replacement in the engine's hot path — needs judgment if anything drifts) | sonnet |
| 4 | CLI flag + seams (complete code above) | haiku (transcription) |
| 5 | docs + bump + sweep | haiku |
| Final | whole-branch adversarial review | opus |
