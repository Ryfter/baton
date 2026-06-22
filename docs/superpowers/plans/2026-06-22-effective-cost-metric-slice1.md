# Effective Cost Metric — Slice 1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Compute a run-level quality-adjusted effective cost (`realized_cost ÷ realized_quality`) and emit it as a 6th `/baton:go` run artifact (`effective-cost.json`) plus an `## Effective cost` report section, strictly when the d058 acceptance gate produced a verdict.

**Architecture:** A new pure library `scripts/effective-cost-lib.ps1` (six functions, no I/O) holds all the math: a banded quality scalar from the gate verdict+counts, a per-task cost sum, the cost÷quality division, a per-worker contribution breakdown, the record assembler, and the report-section formatter. `conductor-lib.ps1` dot-sources it; the DAG walk in `Invoke-Conductor` accumulates a per-task cost list `@[{id;worker;cost}]` and passes it to `Complete-Run`, which — when a gate verdict exists — builds the record, writes `effective-cost.json`, and appends the section. No gate verdict → nothing changes (byte-for-byte).

**Tech Stack:** PowerShell 7 (pwsh). Hermetic `Check`/`Assert`-harness tests (temp dirs, try/finally, zero network, never touches real `~/.baton` or `~/.claude`). Mirrors the `saturation-lib.ps1` / d058 patterns.

## Global Constraints

- **Pure layer is I/O-free** — `effective-cost-lib.ps1` does no file/network/dispatch work; all inputs arrive as parameters (mirrors `saturation-lib.ps1`).
- **Quality scalar is banded, refined, floored** — `accept ∈ [0.7,1.0]`, `polish ∈ [0.3,0.7)`, `reject ∈ (0,0.3]`; refined within band by counts (weights `critical=0.5`, `important=0.2`, `minor=0.05`); global floor `0.05`. Never returns ≤ 0.
- **Cost numerator is a labelled estimate** — v1 `basis='estimate'` (sum of per-task cost-tier estimate); `-CostResolver` seam flips basis to `'measured'`. `attempts` is a first-class field, default `1`, **not** yet a multiplier.
- **No behavior change without a gate** — a run with no resolved gate artifact produces no `effective-cost.json` and an unchanged `report.md`. This extends the d058 invariant.
- **Box-private** — `effective-cost.json` lives under `$BATON_HOME/runs/…`. Never written to the knowledge repo or any shared seed. `references/fleet.yaml` is untouched.
- **No divide-by-zero** — `Get-EffectiveCost` guards `Quality -le 0` → `[double]::PositiveInfinity`.
- **PowerShell traps (house rules):** never name a param/local `$args`, `$input`, `$event`, `$matches`, `$host`; parenthesize function calls inside comparisons; guard unary-comma array-flatten on empty collections; encode files `utf8NoBOM`.
- **Plugin version:** `.claude-plugin/plugin.json` `1.4.0-rc.2 → 1.4.0-rc.3`.

---

### Task 1: Pure library `effective-cost-lib.ps1` + its test suite

**Files:**
- Create: `D:\Dev\Baton\scripts\effective-cost-lib.ps1`
- Test: `D:\Dev\Baton\scripts\test-effective-cost-lib.ps1`

**Interfaces:**
- Consumes: nothing (pure; all inputs are parameters).
- Produces (exact signatures later tasks rely on):
  - `Get-QualityScalar -Verdict <string> [-Counts <obj>] [-Weights <hashtable>] [-Bands <hashtable>] [-Floor <double>] → [double]` in `(0,1]`
  - `Get-RunCost -Tasks <object[]> [-CostResolver <scriptblock>] [-Attempts <int>] → @{cost=<double>;basis=<string>;attempts=<int>}`
  - `Get-EffectiveCost -Cost <double> -Quality <double> → [double]`
  - `Get-WorkerBreakdown -Tasks <object[]> → @[ @{worker=<string>;share=<double>} ]` (shares sum to 1.0; empty → `@()`)
  - `New-EffectiveCostRecord -RunId <string> -Verdict <string> -Quality <double> -Cost <double> [-CostBasis <string>] [-Attempts <int>] [-EffectiveCost <double>] [-Workers <object[]>] → [ordered]hashtable`
  - `Format-EffectiveCostSection -Record <obj> → [string]` (begins with `## Effective cost`)

- [ ] **Step 1: Write the failing test file**

Create `D:\Dev\Baton\scripts\test-effective-cost-lib.ps1` with this exact content:

```powershell
#!/usr/bin/env pwsh
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/effective-cost-lib.ps1"

$script:fail = 0
function Check($n,$c){ if($c){Write-Host "PASS: $n"} else {Write-Host "FAIL: $n"; $script:fail++} }

function Approx($a,$b){ [math]::Abs([double]$a - [double]$b) -lt 0.0005 }

try {
    # ---- Get-QualityScalar: bands ----
    $qAccept = Get-QualityScalar -Verdict 'accept' -Counts @{ critical=0; important=0; minor=0 }
    Check 'E1 clean accept -> top of band (1.0)' (Approx $qAccept 1.0)
    $qPolish = Get-QualityScalar -Verdict 'polish' -Counts @{ critical=0; important=0; minor=0 }
    Check 'E2 clean polish -> top of polish band (0.7)' (Approx $qPolish 0.7)
    $qReject = Get-QualityScalar -Verdict 'reject' -Counts @{ critical=1; important=0; minor=0 }
    Check 'E3 reject in (0,0.3] and floored > 0' (($qReject -gt 0) -and ($qReject -le 0.3))

    # ---- Get-QualityScalar: monotonic within band, never crosses boundary ----
    $qAcceptMinor = Get-QualityScalar -Verdict 'accept' -Counts @{ critical=0; important=0; minor=3 }
    Check 'E4 minors lower the accept score' ($qAcceptMinor -lt $qAccept)
    Check 'E5 refined accept stays in band (>=0.7)' ($qAcceptMinor -ge 0.7)
    $qAcceptManyMinor = Get-QualityScalar -Verdict 'accept' -Counts @{ critical=0; important=0; minor=999 }
    Check 'E6 saturated penalty clamps at band floor (0.7)' (Approx $qAcceptManyMinor 0.7)

    # ---- Get-QualityScalar: floor + unknown verdict + null counts ----
    $qWorst = Get-QualityScalar -Verdict 'reject' -Counts @{ critical=999; important=0; minor=0 }
    Check 'E7 reject penalty never goes below global floor 0.05' (Approx $qWorst 0.05)
    $qUnknown = Get-QualityScalar -Verdict 'banana' -Counts @{}
    Check 'E8 unknown verdict -> reject band (<=0.3)' ($qUnknown -le 0.3 -and $qUnknown -gt 0)
    $qNullCounts = Get-QualityScalar -Verdict 'accept' -Counts $null
    Check 'E9 null counts -> clean (1.0)' (Approx $qNullCounts 1.0)

    # ---- Get-RunCost ----
    $tasks = @(
        @{ id='t1'; worker='haiku';  cost=2.0 }
        @{ id='t2'; worker='sonnet'; cost=1.0 }
    )
    $rc = Get-RunCost -Tasks $tasks
    Check 'E10 estimate basis sums per-task cost' (Approx $rc.cost 3.0)
    Check 'E11 default basis = estimate' ($rc.basis -eq 'estimate')
    Check 'E12 default attempts = 1' ($rc.attempts -eq 1)
    $rcMeasured = Get-RunCost -Tasks $tasks -CostResolver { param($t) 10.0 }
    Check 'E13 CostResolver overrides cost' (Approx $rcMeasured.cost 20.0)
    Check 'E14 CostResolver flips basis to measured' ($rcMeasured.basis -eq 'measured')
    $rcEmpty = Get-RunCost -Tasks @()
    Check 'E15 empty tasks -> cost 0' (Approx $rcEmpty.cost 0.0)

    # ---- Get-EffectiveCost ----
    Check 'E16 cost / quality' (Approx (Get-EffectiveCost -Cost 3.0 -Quality 0.5) 6.0)
    Check 'E17 quality <= 0 guard -> +Inf' ((Get-EffectiveCost -Cost 3.0 -Quality 0.0) -eq [double]::PositiveInfinity)

    # ---- Get-WorkerBreakdown ----
    $bd = Get-WorkerBreakdown -Tasks $tasks
    Check 'E18 one entry per worker' (@($bd).Count -eq 2)
    $sumShare = (@($bd) | Measure-Object -Property share -Sum).Sum
    Check 'E19 shares sum to 1.0' (Approx $sumShare 1.0)
    $haiku = @($bd | Where-Object { $_.worker -eq 'haiku' })[0]
    Check 'E20 share is cost-weighted (haiku 2/3)' (Approx $haiku.share 0.6667)
    $single = Get-WorkerBreakdown -Tasks @(@{ id='t1'; worker='solo'; cost=5.0 })
    Check 'E21 single producer -> one worker at 1.0' (@($single).Count -eq 1 -and (Approx $single[0].share 1.0))
    $zeroCost = Get-WorkerBreakdown -Tasks @(@{id='a';worker='x';cost=0.0}; @{id='b';worker='y';cost=0.0})
    Check 'E22 zero total cost -> count-share fallback (0.5/0.5)' (Approx ($zeroCost | Where-Object {$_.worker -eq 'x'})[0].share 0.5)
    $noWorker = Get-WorkerBreakdown -Tasks @(@{ id='t1'; worker=''; cost=2.0 })
    Check 'E23 tasks without a worker are excluded' (@($noWorker).Count -eq 0)
    $bdEmpty = Get-WorkerBreakdown -Tasks @()
    Check 'E24 empty tasks -> empty array' (@($bdEmpty).Count -eq 0)

    # ---- New-EffectiveCostRecord ----
    $rec = New-EffectiveCostRecord -RunId 'go-x' -Verdict 'polish' -Quality 0.52 -Cost 3.0 -CostBasis 'estimate' -Attempts 1 -EffectiveCost 5.77 -Workers $bd
    Check 'E25 record carries run_id' ($rec.run_id -eq 'go-x')
    Check 'E26 record carries effective_cost' (Approx $rec.effective_cost 5.77)
    Check 'E27 single_producer false for 2 workers' ($rec.single_producer -eq $false)
    $recSolo = New-EffectiveCostRecord -RunId 'go-y' -Verdict 'accept' -Quality 1.0 -Cost 1.0 -EffectiveCost 1.0 -Workers $single
    Check 'E28 single_producer true for 1 worker' ($recSolo.single_producer -eq $true)
    $recJson = $rec | ConvertTo-Json -Depth 8
    Check 'E29 record round-trips through JSON' (($recJson | ConvertFrom-Json).run_id -eq 'go-x')

    # ---- Format-EffectiveCostSection ----
    $sec = Format-EffectiveCostSection -Record $rec
    Check 'E30 section starts with the heading' ($sec -match '(?m)^## Effective cost')
    Check 'E31 section shows the effective cost number' ($sec -match '5\.77')
    Check 'E32 section names the basis honestly' ($sec -match 'estimate')
    Check 'E33 section shows per-worker share' ($sec -match 'haiku')
}
finally {
    if ($script:fail -gt 0) { Write-Host "`n$($script:fail) CHECK(S) FAILED" -ForegroundColor Red; exit 1 }
    Write-Host "`nALL CHECKS PASS" -ForegroundColor Green; exit 0
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `pwsh -NoProfile -File D:\Dev\Baton\scripts\test-effective-cost-lib.ps1`
Expected: FAIL — the lib does not exist yet (`The term '...effective-cost-lib.ps1' is not recognized` / dot-source error), non-zero exit.

- [ ] **Step 3: Write the library**

Create `D:\Dev\Baton\scripts\effective-cost-lib.ps1` with this exact content:

```powershell
#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Quality-adjusted effective cost (slice 1). Pure layer: realized cost / realized
  quality per run. effective_cost = cost / quality; lower is better.
.DESCRIPTION
  Recommendation/legibility only — no dispatch, no routing change. All inputs are
  parameters (no I/O). Wired into conductor-lib.ps1 Complete-Run.
  See docs/superpowers/specs/2026-06-22-effective-cost-metric-design.md.
#>

function Get-QualityScalar {
    <# Verdict + finding counts -> (0,1] scalar. Banded by verdict, refined within
       the band by counts, floored > 0. Monotonic with the verdict. #>
    param(
        [Parameter(Mandatory)][string]$Verdict,
        $Counts = @{},
        [hashtable]$Weights = @{ critical = 0.5; important = 0.2; minor = 0.05 },
        [hashtable]$Bands = @{ accept = @(0.7, 1.0); polish = @(0.3, 0.7); reject = @(0.0, 0.3) },
        [double]$Floor = 0.05
    )
    if ($null -eq $Counts) { $Counts = @{} }
    $v = ([string]$Verdict).ToLowerInvariant()
    if (-not $Bands.Contains($v)) { $v = 'reject' }   # unknown verdict -> worst band
    $lo = [double]$Bands[$v][0]
    $hi = [double]$Bands[$v][1]
    $w  = $hi - $lo
    $crit = [int]($Counts['critical']); $imp = [int]($Counts['important']); $min = [int]($Counts['minor'])
    $penalty = ([double]$Weights['critical'] * $crit) + ([double]$Weights['important'] * $imp) + ([double]$Weights['minor'] * $min)
    if ($penalty -lt 0) { $penalty = 0.0 }
    if ($penalty -gt 1) { $penalty = 1.0 }
    $q = $hi - ($penalty * $w)
    if ($q -lt $Floor) { $q = $Floor }
    return [math]::Round($q, 4)
}

function Get-RunCost {
    <# Per-task cost list (@[{id;worker;cost}]) -> @{cost;basis;attempts}.
       v1 basis='estimate' (sum of per-task cost); -CostResolver overrides per task
       and flips basis to 'measured'. #>
    param(
        [object[]]$Tasks = @(),
        [scriptblock]$CostResolver,
        [int]$Attempts = 1
    )
    $sum = 0.0
    $basis = if ($CostResolver) { 'measured' } else { 'estimate' }
    foreach ($t in @($Tasks)) {
        if ($CostResolver) { $sum += [double](& $CostResolver $t) }
        else { $sum += [double]$t.cost }
    }
    return @{ cost = [math]::Round($sum, 4); basis = $basis; attempts = [int]$Attempts }
}

function Get-EffectiveCost {
    <# cost / quality. Quality is floored > 0 upstream; guard <= 0 -> +Inf. #>
    param(
        [Parameter(Mandatory)][double]$Cost,
        [Parameter(Mandatory)][double]$Quality
    )
    if ($Quality -le 0) { return [double]::PositiveInfinity }
    return [math]::Round($Cost / $Quality, 4)
}

function Get-WorkerBreakdown {
    <# Per-task cost list -> @[{worker; share}] summing to 1.0. Share by cost; if the
       total cost is 0, fall back to task-count share. Tasks without a worker are
       excluded. Empty -> @(). #>
    param([object[]]$Tasks = @())
    $arr = @(@($Tasks) | Where-Object { $_ -and -not [string]::IsNullOrWhiteSpace([string]$_.worker) })
    if ($arr.Count -eq 0) { return @() }
    $byWorker = [ordered]@{}
    $totalCost = 0.0
    foreach ($t in $arr) {
        $wk = [string]$t.worker
        $cost = [double]$t.cost
        if (-not $byWorker.Contains($wk)) { $byWorker[$wk] = @{ cost = 0.0; count = 0 } }
        $byWorker[$wk].cost  += $cost
        $byWorker[$wk].count += 1
        $totalCost += $cost
    }
    $useCost = ($totalCost -gt 0)
    $totalCount = $arr.Count
    $out = foreach ($wk in $byWorker.Keys) {
        $share = if ($useCost) { $byWorker[$wk].cost / $totalCost } else { $byWorker[$wk].count / $totalCount }
        @{ worker = $wk; share = [math]::Round($share, 4) }
    }
    return @($out)
}

function New-EffectiveCostRecord {
    <# Assemble the per-run outcome record — the join surface slice 2 folds over. #>
    param(
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$Verdict,
        [Parameter(Mandatory)][double]$Quality,
        [Parameter(Mandatory)][double]$Cost,
        [string]$CostBasis = 'estimate',
        [int]$Attempts = 1,
        [double]$EffectiveCost = 0.0,
        [object[]]$Workers = @()
    )
    return [ordered]@{
        run_id          = $RunId
        verdict         = $Verdict
        quality         = $Quality
        cost            = $Cost
        cost_basis      = $CostBasis
        attempts        = $Attempts
        effective_cost  = $EffectiveCost
        workers         = @($Workers)
        single_producer = (@($Workers).Count -eq 1)
    }
}

function Format-EffectiveCostSection {
    <# The '## Effective cost' report block from a record (ordered dict/hashtable). #>
    param([Parameter(Mandatory)]$Record)
    $eff = if ([double]$Record.effective_cost -eq [double]::PositiveInfinity) { '∞' } else { '{0:0.00}' -f [double]$Record.effective_cost }
    $cost = '{0:0.00}' -f [double]$Record.cost
    $q = '{0:0.00}' -f [double]$Record.quality
    $basisNote = if ($Record.cost_basis -eq 'measured') { 'cost is metered spend' } else { 'cost is a cost-tier estimate, not metered spend' }
    $shareStr = (@($Record.workers) | ForEach-Object { "$($_.worker) $([math]::Round([double]$_.share * 100))%" }) -join ', '
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine('## Effective cost')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine("Effective cost **$eff** = cost $cost ($($Record.cost_basis)) / quality $q ($($Record.verdict)).")
    [void]$sb.AppendLine("Attempts: $($Record.attempts). Basis: $($Record.cost_basis) — $basisNote.")
    if ($shareStr) { [void]$sb.AppendLine("Per-worker share: $shareStr.") }
    return $sb.ToString().TrimEnd()
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `pwsh -NoProfile -File D:\Dev\Baton\scripts\test-effective-cost-lib.ps1`
Expected: PASS — `ALL CHECKS PASS`, exit 0 (E1–E33).

- [ ] **Step 5: Commit**

```bash
git add scripts/effective-cost-lib.ps1 scripts/test-effective-cost-lib.ps1
git commit -m "feat(effective-cost): pure lib — quality scalar, run cost, breakdown, record"
```

---

### Task 2: Wire effective cost into the Conductor

**Files:**
- Modify: `D:\Dev\Baton\scripts\conductor-lib.ps1` (dot-source near the existing `gate-lib.ps1` source; `Invoke-Conductor` DAG walk; `Complete-Run`)
- Test: `D:\Dev\Baton\scripts\test-conductor-lib.ps1` (append checks)

**Interfaces:**
- Consumes (from Task 1): `Get-QualityScalar`, `Get-RunCost`, `Get-EffectiveCost`, `Get-WorkerBreakdown`, `New-EffectiveCostRecord`, `Format-EffectiveCostSection` (signatures in Task 1).
- Produces: `Complete-Run` gains `-TaskCosts <object[]>` (default `@()`); the returned run object gains an `effective_cost` field (`$null` unless a gate verdict drove a record). On a gate verdict, writes `effective-cost.json` and appends `## Effective cost` to `report.md`.

- [ ] **Step 1: Write the failing tests**

Append the following block to `D:\Dev\Baton\scripts\test-conductor-lib.ps1`, immediately **before** the file's final summary/`exit` block (the same place the T77–T79 d058 checks were added — find the last `Check`/`Assert` call and insert after it, before the `if ($script:fail ...)` / summary). Use the harness function the file already defines (it uses `Check`/`Assert` + a temp `BATON_HOME`; reuse whatever assertion name and temp-dir variable the surrounding code uses — the block below uses `Check` and creates its own temp run dir):

```powershell
# ---- T80-T86: effective cost wiring (slice 1) ----
$ecRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("baton-ec-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $ecRoot | Out-Null
try {
    # A run that completes with a gate verdict -> effective-cost.json + report section.
    $plan = @{ run_id = 'go-ec-1'; goal = 'demo'; budget_cap = $null; tasks = @(
        @{ id = 't1'; desc = 'do it'; deps = @(); est_cost_tier = 'paid'; reversible = $true }
    ) }
    $gate = @{ verdict = 'polish'; reason = '1 important finding(s)'; counts = @{ critical=0; important=1; minor=0 }; polish_brief = 'fix it'; findings = @(); reviews = @(); unparsed = @() }
    $taskCosts = @(@{ id='t1'; worker='claude-haiku'; cost=2.0 })
    $rd = Join-Path $ecRoot 'go-ec-1'; New-Item -ItemType Directory -Force -Path $rd | Out-Null
    $res = Complete-Run -RunDir $rd -Plan $plan -Decisions @() -Spend 2.0 -Status 'completed' -Gate $gate -TaskCosts $taskCosts
    $ecPath = Join-Path $rd 'effective-cost.json'
    Check 'T80 effective-cost.json written when gate verdict present' (Test-Path $ecPath)
    $ecObj = Get-Content $ecPath -Raw | ConvertFrom-Json
    Check 'T81 record verdict matches the gate' ($ecObj.verdict -eq 'polish')
    Check 'T82 record effective_cost = cost / quality (>0)' ($ecObj.effective_cost -gt $ecObj.cost)  # quality<1 inflates cost
    Check 'T83 record attributes the producing worker' ($ecObj.workers[0].worker -eq 'claude-haiku')
    Check 'T84 returned run object carries effective_cost' ($null -ne $res.effective_cost)
    $rep = Get-Content (Join-Path $rd 'report.md') -Raw
    Check 'T85 report.md has the ## Effective cost section' ($rep -match '(?m)^## Effective cost')

    # No gate -> no effective-cost.json, no section (byte-for-byte invariant).
    $rd2 = Join-Path $ecRoot 'go-ec-2'; New-Item -ItemType Directory -Force -Path $rd2 | Out-Null
    $plan2 = @{ run_id = 'go-ec-2'; goal = 'demo'; budget_cap = $null; tasks = @() }
    $res2 = Complete-Run -RunDir $rd2 -Plan $plan2 -Decisions @() -Spend 0.0 -Status 'completed'
    Check 'T86 no gate -> no effective-cost.json and null effective_cost' ((-not (Test-Path (Join-Path $rd2 'effective-cost.json'))) -and ($null -eq $res2.effective_cost))
}
finally {
    Remove-Item -LiteralPath $ecRoot -Recurse -Force -ErrorAction SilentlyContinue
}
```

> **Note for the implementer:** if the surrounding test file uses `Assert` (not `Check`) or a different temp-root variable, rename the calls in this block to match the file's existing convention — keep the assertions identical. Verify the file's actual harness by reading the lines around the last existing check before inserting.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `pwsh -NoProfile -File D:\Dev\Baton\scripts\test-conductor-lib.ps1`
Expected: FAIL — `Complete-Run` does not accept `-TaskCosts` (parameter-binding error) and writes no `effective-cost.json`. T80–T86 fail; existing T1–T79 + T60c still pass.

- [ ] **Step 3a: Dot-source the library in `conductor-lib.ps1`**

Find the existing d058 dot-source line for the gate library (near the top of `conductor-lib.ps1`):

```powershell
. "$PSScriptRoot/gate-lib.ps1"
```

Add immediately after it:

```powershell
. "$PSScriptRoot/effective-cost-lib.ps1"
```

- [ ] **Step 3b: Accumulate the per-task cost list in the DAG walk**

In `Invoke-Conductor`, the guarded walk currently initializes (around the `# 3. Guarded walk.` comment):

```powershell
    # 3. Guarded walk.
    $spend = 0.0
    $decisions = [System.Collections.ArrayList]@()
```

Add a third accumulator:

```powershell
    # 3. Guarded walk.
    $spend = 0.0
    $decisions = [System.Collections.ArrayList]@()
    $taskCosts = [System.Collections.ArrayList]@()
```

Then, inside the `foreach ($task in $order)` loop, immediately **after** the decision-recording block (the `if ($r.chose) { ... [void]$decisions.Add($dec) }` block) and before the `Add-RunEvent ... -Kind 'spent'` line, add:

```powershell
        [void]$taskCosts.Add(@{ id = $task.id; worker = ([string]$r.chose); cost = $tspend })
```

Finally, on the success-path return (the last line of `Invoke-Conductor`, currently):

```powershell
    return (Complete-Run -RunDir $RunDir -Plan $plan -Decisions $decisions -Spend $spend -Status $finalStatus -Gate $gate)
```

change it to pass the accumulated costs:

```powershell
    return (Complete-Run -RunDir $RunDir -Plan $plan -Decisions $decisions -Spend $spend -Status $finalStatus -Gate $gate -TaskCosts $taskCosts)
```

(Leave the early-return `Complete-Run` calls — plan-failed, plan-invalid, interrupted-*, failed — unchanged; they pass no `-TaskCosts`, so it defaults to `@()` and no record is written.)

- [ ] **Step 3c: Compute + emit the record in `Complete-Run`**

Add the `-TaskCosts` parameter to `Complete-Run`'s `param(...)` block (after the existing `$Gate = $null`):

```powershell
        $Gate = $null,
        [object[]]$TaskCosts = @()
```

Then, inside `Complete-Run`, **after** the existing `if ($Gate) { ... acceptance.json ... }` block and **before** the `Set-Content ... report.md` line, add the effective-cost block, and add an `effective_cost` field to the returned hashtable:

```powershell
    $effectiveCost = $null
    if ($Gate -and $Gate.verdict) {
        $quality   = Get-QualityScalar -Verdict ([string]$Gate.verdict) -Counts $Gate.counts
        $runCost   = Get-RunCost -Tasks @($TaskCosts)
        $effective = Get-EffectiveCost -Cost $runCost.cost -Quality $quality
        $breakdown = Get-WorkerBreakdown -Tasks @($TaskCosts)
        $record = New-EffectiveCostRecord -RunId $Plan.run_id -Verdict ([string]$Gate.verdict) `
            -Quality $quality -Cost $runCost.cost -CostBasis $runCost.basis -Attempts $runCost.attempts `
            -EffectiveCost $effective -Workers $breakdown
        $report = $report + "`n`n" + (Format-EffectiveCostSection -Record $record)
        ($record | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath (Join-Path $RunDir 'effective-cost.json') -Encoding utf8NoBOM
        $effectiveCost = $effective
    }
```

Update the return statement to include the new field:

```powershell
    return @{ status = $Status; run_id = $Plan.run_id; run_dir = $RunDir; spend = $Spend; pending_task_id = $PendingTaskId; report = $report; acceptance = $Gate; effective_cost = $effectiveCost }
```

- [ ] **Step 4: Run the full conductor suite to verify it passes**

Run: `pwsh -NoProfile -File D:\Dev\Baton\scripts\test-conductor-lib.ps1`
Expected: PASS — `ALL CHECKS PASS` (T1–T79, T60c, and new T80–T86), exit 0.

- [ ] **Step 5: Regression-check the effective-cost lib still passes**

Run: `pwsh -NoProfile -File D:\Dev\Baton\scripts\test-effective-cost-lib.ps1`
Expected: PASS — `ALL CHECKS PASS`, exit 0.

- [ ] **Step 6: Commit**

```bash
git add scripts/conductor-lib.ps1 scripts/test-conductor-lib.ps1
git commit -m "feat(effective-cost): wire run-level effective cost into the Conductor"
```

---

### Task 3: Deploy manifest, bootstrap assert, plugin version

**Files:**
- Modify: `D:\Dev\Baton\scripts\bootstrap.ps1:259` (lib manifest)
- Modify: `D:\Dev\Baton\scripts\test-bootstrap.ps1` (deploy assert)
- Modify: `D:\Dev\Baton\.claude-plugin\plugin.json` (version)

**Interfaces:**
- Consumes: the new file name `effective-cost-lib.ps1` (Task 1).
- Produces: bootstrap deploys the lib; the test asserts it; plugin at `1.4.0-rc.3`.

- [ ] **Step 1: Write the failing bootstrap assert**

In `D:\Dev\Baton\scripts\test-bootstrap.ps1`, find the existing line:

```powershell
Assert "would deploy saturation-lib.ps1" ($out -match 'saturation-lib\.ps1')
```

Add immediately after it:

```powershell
Assert "would deploy effective-cost-lib.ps1" ($out -match 'effective-cost-lib\.ps1')
```

- [ ] **Step 2: Run the bootstrap test to verify it fails**

Run: `pwsh -NoProfile -File D:\Dev\Baton\scripts\test-bootstrap.ps1`
Expected: FAIL — `effective-cost-lib.ps1` is not in the manifest yet, so the dry-run output does not match; the new assert fails.

- [ ] **Step 3: Add the lib to the bootstrap manifest**

In `D:\Dev\Baton\scripts\bootstrap.ps1` line 259, the manifest array contains `'saturation-lib.ps1'`. Insert `'effective-cost-lib.ps1'` immediately after it so the fragment reads:

```powershell
'routing-lib.ps1', 'saturation-lib.ps1', 'effective-cost-lib.ps1', 'routing-dispatch.ps1',
```

(Only that one array element is added; leave the rest of the manifest unchanged.)

- [ ] **Step 4: Run the bootstrap test to verify it passes**

Run: `pwsh -NoProfile -File D:\Dev\Baton\scripts\test-bootstrap.ps1`
Expected: PASS — all asserts including the new `would deploy effective-cost-lib.ps1`, exit 0.

- [ ] **Step 5: Bump the plugin version**

In `D:\Dev\Baton\.claude-plugin\plugin.json`, change:

```json
"version": "1.4.0-rc.2"
```

to:

```json
"version": "1.4.0-rc.3"
```

- [ ] **Step 6: Commit**

```bash
git add scripts/bootstrap.ps1 scripts/test-bootstrap.ps1 .claude-plugin/plugin.json
git commit -m "build(effective-cost): deploy effective-cost-lib + plugin 1.4.0-rc.3"
```

---

## Final verification (after all tasks)

Run the full affected suite — all must exit 0:

```bash
pwsh -NoProfile -File D:\Dev\Baton\scripts\test-effective-cost-lib.ps1
pwsh -NoProfile -File D:\Dev\Baton\scripts\test-conductor-lib.ps1
pwsh -NoProfile -File D:\Dev\Baton\scripts\test-bootstrap.ps1
```

Then a deployed-script smoke (optional but recommended): `bootstrap.ps1 -Force`, run `/baton:go` with a `-GateArtifact`, confirm `effective-cost.json` lands beside `acceptance.json` and `report.md` carries the `## Effective cost` section.

## Notes for the executor

- This plan is **slice 1 only**. Slice 2 (`Get-WorkerEffectiveCost` fold + `/baton:effective-cost` command) and the deferred `Select-Capability` re-rank are **out of scope** — do not build them.
- `effective-cost.json` is **box-private** — under `$BATON_HOME/runs/…`, never committed or pushed to any knowledge repo.
- Decision records `d-ec-1..5` (spec §8) are captured by the controller at build closeout, not by task implementers.
