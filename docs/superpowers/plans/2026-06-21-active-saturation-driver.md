# Active Saturation Driver (d-wa-5) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Teach `Select-Capability` to actively up-rank an under-utilized, opt-in, budgeted fleet worker so the cost-optimal selector spends its pre-paid/free allotment first (toward the 99.9%-utilization north star).

**Architecture:** One new pure lib (`saturation-lib.ps1`) plus a surgical, symmetric extension to the existing route-around seam in `routing-lib.ps1` §3b. Route-around down-ranks/excludes unavailable workers; saturation up-ranks an under-used budgeted one by flooring its *effective* cost-tier rank to −1 (below `local`) while it qualifies. Selection-time ranking only — no dispatch, no filler work.

**Tech Stack:** PowerShell 7 (pwsh). Hermetic `Check`-harness tests (temp dirs, try/finally, zero network). YAML seed config. Plugin manifest JSON.

## Global Constraints

- **Box-private:** the real `budget` and a real `saturate: true` live ONLY in live `~/.baton/fleet.yaml`. The seed (`references/fleet.yaml`) carries field docs + a `saturate: false` example; never a real budget. (spec §7)
- **Opt-in, default off:** only a provider with `saturate: true` AND `budget > 0` is ever boosted; absent flag/budget → unchanged behavior. (d-sat-2)
- **Effective-tier floor:** a boosted candidate's effective cost-tier rank = −1 (below `local`'s 0). (d-sat-1)
- **Binary threshold:** `utilization < saturation_target` → boost; per-worker `saturation_target` float, default `99.9`. (d-sat-3)
- **Economy-only, conserve-suppressed:** boost applies only when `SelectionMode = economy` and conserve mode is off. Champion mode untouched. (d-sat-4)
- **Never un-filters:** saturation runs after cost-cap / `RequireLocal` / route-around and only re-orders survivors; a `limited`/`exhausted`/`cooling_down`/`waiting_for_reset` worker is never boosted. (d-sat-5)
- **Invariant preserved:** non-saturating selection must rank EXACTLY as today (rank ≠ tier; the route-around `×0.5` down-rank and economy/champion ordering unchanged).
- **PowerShell traps:** never name a param/local `$args`/`$input`/`$event`/`$matches`/`$host`. Wrap function calls in parentheses inside comparisons: `(Get-CostTierRank $x) -eq 0`, never `Get-CostTierRank $x -eq 0`. Guard empty collections before a unary-comma return.
- **Version:** plugin `1.3.0 → 1.4.0-rc.1` (opens the v1.4 line).

---

### Task 1: `saturation-lib.ps1` — pure decision layer

**Files:**
- Create: `scripts/saturation-lib.ps1`
- Create (test): `scripts/test-saturation-lib.ps1`

**Interfaces:**
- Consumes: `ConvertTo-UsageDateTime` (from `usage-lib.ps1`), `Get-CostTierRank` (from `routing-lib.ps1` — available at runtime; the test dot-sources `routing-lib.ps1` to resolve it).
- Produces:
  - `Get-CandidateUtilization([object[]]$Rows, [string]$Worker, [int]$Budget=0, [datetime]$Now) -> @{consumed=[int]; budget=[int]; utilization=[double|$null]}`
  - `Get-SaturationDecision([bool]$Saturate, [int]$Budget, [int]$Consumed, [double]$Target, [string]$State, [string]$SelectionMode, [bool]$Conserve) -> @{apply=[bool]; utilization=[double|$null]; reason=[string|$null]}`
  - `Get-EffectiveTierRank([string]$CostTier, [bool]$Saturating=$false) -> [int]` (−1 when saturating, else `Get-CostTierRank $CostTier`)

- [ ] **Step 1: Write the failing test**

Create `scripts/test-saturation-lib.ps1`:

```powershell
#!/usr/bin/env pwsh
$ErrorActionPreference = 'Stop'
# Dot-source routing-lib so Get-EffectiveTierRank can resolve Get-CostTierRank,
# and Task 2's Select-Capability integration checks are in scope.
. "$PSScriptRoot/routing-lib.ps1"

$script:fail = 0
function Check($n,$c){ if($c){Write-Host "PASS: $n"} else {Write-Host "FAIL: $n"; $script:fail++} }

function New-Tick([string]$worker,[string]$ts){ [pscustomobject]@{ ts=$ts; event='tick'; worker=$worker; count=1; unit='requests' } }

try {
    # ---- Get-CandidateUtilization ----
    $rows = @(New-Tick 'gh' '2026-06-21T01:00:00Z'; New-Tick 'gh' '2026-06-21T02:00:00Z'; New-Tick 'other' '2026-06-21T03:00:00Z')
    $u = Get-CandidateUtilization -Rows $rows -Worker 'gh' -Budget 50
    Check 'S1 consumed counts only this worker' ($u.consumed -eq 2)
    Check 'S2 utilization = consumed/budget*100' ($u.utilization -eq 4.0)
    $u0 = Get-CandidateUtilization -Rows $rows -Worker 'gh' -Budget 0
    Check 'S3 budget 0 -> null utilization' ($null -eq $u0.utilization)
    $uEmpty = Get-CandidateUtilization -Rows @() -Worker 'gh' -Budget 50
    Check 'S4 empty rows -> 0 consumed' ($uEmpty.consumed -eq 0 -and $uEmpty.utilization -eq 0.0)
    # consumed counts only ticks since the latest lockout|clear boundary
    $rowsB = @(
        New-Tick 'gh' '2026-06-21T01:00:00Z'
        [pscustomobject]@{ ts='2026-06-21T01:30:00Z'; event='clear'; worker='gh' }
        New-Tick 'gh' '2026-06-21T02:00:00Z'
    )
    $uB = Get-CandidateUtilization -Rows $rowsB -Worker 'gh' -Budget 50 -Now ([datetime]::Parse('2026-06-21T05:00:00Z'))
    Check 'S5 consumed resets at clear boundary' ($uB.consumed -eq 1)

    # ---- Get-SaturationDecision ----
    $dOn = Get-SaturationDecision -Saturate $true -Budget 50 -Consumed 5 -Target 99.9 -State 'available' -SelectionMode 'economy' -Conserve $false
    Check 'S6 below target + opted-in -> apply' ($dOn.apply -and $dOn.utilization -eq 10.0)
    Check 'S7 apply -> reason carries util + budget' ($dOn.reason -match 'saturate:' -and $dOn.reason -match '10' -and $dOn.reason -match '50')
    $dFull = Get-SaturationDecision -Saturate $true -Budget 50 -Consumed 50 -Target 99.9 -State 'available' -SelectionMode 'economy' -Conserve $false
    Check 'S8 consumed>=budget -> no apply' (-not $dFull.apply)
    $dAt = Get-SaturationDecision -Saturate $true -Budget 100 -Consumed 100 -Target 99.9 -State 'available' -SelectionMode 'economy' -Conserve $false
    Check 'S9 util at/above target -> no apply' (-not $dAt.apply)
    $dOff = Get-SaturationDecision -Saturate $false -Budget 50 -Consumed 5 -Target 99.9 -State 'available' -SelectionMode 'economy' -Conserve $false
    Check 'S10 not opted-in -> no apply' (-not $dOff.apply)
    $dNoBud = Get-SaturationDecision -Saturate $true -Budget 0 -Consumed 0 -Target 99.9 -State 'available' -SelectionMode 'economy' -Conserve $false
    Check 'S11 no budget -> no apply' (-not $dNoBud.apply)
    $dCons = Get-SaturationDecision -Saturate $true -Budget 50 -Consumed 5 -Target 99.9 -State 'available' -SelectionMode 'economy' -Conserve $true
    Check 'S12 conserve -> no apply' (-not $dCons.apply)
    $dChamp = Get-SaturationDecision -Saturate $true -Budget 50 -Consumed 5 -Target 99.9 -State 'available' -SelectionMode 'champion' -Conserve $false
    Check 'S13 champion mode -> no apply' (-not $dChamp.apply)
    $dLim = Get-SaturationDecision -Saturate $true -Budget 50 -Consumed 5 -Target 99.9 -State 'limited' -SelectionMode 'economy' -Conserve $false
    Check 'S14 state != available -> no apply' (-not $dLim.apply)

    # ---- Get-EffectiveTierRank ----
    Check 'S15 saturating -> -1' ((Get-EffectiveTierRank 'free' $true) -eq -1)
    Check 'S16 not saturating -> real tier rank' ((Get-EffectiveTierRank 'local' $false) -eq (Get-CostTierRank 'local'))
    Check 'S17 saturating beats local' ((Get-EffectiveTierRank 'free' $true) -lt (Get-EffectiveTierRank 'local' $false))

    Write-Host ""
    if ($script:fail -eq 0) { Write-Host 'ALL PASS' } else { Write-Host "$($script:fail) FAILED"; exit 1 }
} catch {
    Write-Host "ERROR: $($_.Exception.Message)"; exit 1
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `pwsh -NoProfile -File scripts/test-saturation-lib.ps1`
Expected: FAIL/ERROR — `Get-CandidateUtilization` not defined (file does not exist yet).

- [ ] **Step 3: Write the minimal implementation**

Create `scripts/saturation-lib.ps1`:

```powershell
#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Active Saturation Driver (d-wa-5). Pure decision layer that decides whether an
  under-utilized, opt-in, budgeted worker should be rank-boosted so routing spends
  its pre-paid/free allotment first. Wired into Select-Capability (routing-lib.ps1 §3b).
.DESCRIPTION
  Recommendation/ranking only — no dispatch, no filler work.
  See docs/superpowers/specs/2026-06-21-active-saturation-driver-design.md.
#>
. "$PSScriptRoot/baton-home.ps1"
. "$PSScriptRoot/usage-lib.ps1"   # ConvertTo-UsageDateTime

function Get-CandidateUtilization {
    <# consumed (ticks since the latest lockout|clear boundary at/under Now, else all)
       + budget + utilization% for a worker. Pure over the supplied rows. #>
    param(
        [object[]]$Rows,
        [Parameter(Mandatory)][string]$Worker,
        [int]$Budget = 0,
        [datetime]$Now = [datetime]::UtcNow
    )
    $nowUtc = $Now.ToUniversalTime()
    $rowsArr = @($Rows)
    $bounds = @($rowsArr | Where-Object {
        $_.worker -eq $Worker -and $_.event -in @('lockout','clear') -and (ConvertTo-UsageDateTime ([string]$_.ts)) -le $nowUtc
    })
    $windowStart = [datetime]::MinValue
    if ($bounds.Count -gt 0) {
        $windowStart = ConvertTo-UsageDateTime ([string](($bounds | Sort-Object { ConvertTo-UsageDateTime ([string]$_.ts) } | Select-Object -Last 1).ts))
    }
    $consumed = 0
    foreach ($t in @($rowsArr | Where-Object { $_.event -eq 'tick' -and $_.worker -eq $Worker })) {
        if ((ConvertTo-UsageDateTime ([string]$t.ts)) -ge $windowStart) { $consumed += [int]$t.count }
    }
    $util = $null
    if ($Budget -gt 0) { $util = [math]::Round(($consumed / $Budget) * 100, 1) }
    return @{ consumed = $consumed; budget = $Budget; utilization = $util }
}

function Get-SaturationDecision {
    <# Pure gate: should this candidate get the saturation boost? All d-sat rules. #>
    param(
        [bool]$Saturate = $false,
        [int]$Budget = 0,
        [int]$Consumed = 0,
        [double]$Target = 99.9,
        [string]$State = 'available',
        [string]$SelectionMode = 'economy',
        [bool]$Conserve = $false
    )
    $util = $null
    if ($Budget -gt 0) { $util = [math]::Round(($Consumed / $Budget) * 100, 1) }
    $apply = $Saturate -and ($Budget -gt 0) -and ($Consumed -lt $Budget) -and
             ($null -ne $util) -and ($util -lt $Target) -and
             ($State -eq 'available') -and ($SelectionMode -eq 'economy') -and (-not $Conserve)
    $reason = $null
    if ($apply) { $reason = "saturate: $util% of $Budget budget — spending pre-paid allotment first" }
    return @{ apply = [bool]$apply; utilization = $util; reason = $reason }
}

function Get-EffectiveTierRank {
    <# Effective cost-tier rank: -1 (below local's 0) when saturating, else the real rank. #>
    param([string]$CostTier, [bool]$Saturating = $false)
    if ($Saturating) { return -1 }
    return (Get-CostTierRank $CostTier)
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `pwsh -NoProfile -File scripts/test-saturation-lib.ps1`
Expected: PASS — `ALL PASS` (S1–S17).

- [ ] **Step 5: Commit**

```bash
git add scripts/saturation-lib.ps1 scripts/test-saturation-lib.ps1
git commit -m "feat(saturation): pure decision layer for active saturation driver (d-wa-5)"
```

---

### Task 2: Wire saturation into `Select-Capability`

**Files:**
- Modify: `scripts/routing-lib.ps1` (dot-source line ~14; §2 fleet-candidate object ~126-162; §3b usage block ~173-192; §4 economy sort ~200-204)
- Modify (test): `scripts/test-saturation-lib.ps1` (append integration checks)

**Interfaces:**
- Consumes: `Get-CandidateUtilization`, `Get-SaturationDecision`, `Get-EffectiveTierRank` (Task 1); `Get-WorkerState`, `Get-ConserveMode`, `Read-UsageJournal` (usage-lib).
- Produces: `Select-Capability` candidates now carry `budget`, `saturate`, `saturation_target`, `sat_util`; a boosted candidate has `saturate=$true`, `sat_util=<double>`, and a saturate `why`; economy ranking floors saturators below `local`, tiebroken by util asc. Non-saturating selection is byte-for-byte unchanged.

- [ ] **Step 1: Write the failing integration tests**

Append BEFORE the final `Write-Host ""` summary block in `scripts/test-saturation-lib.ps1`:

```powershell
    # ---- Select-Capability integration (Task 2) ----
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) "sat-test-$([System.IO.Path]::GetRandomFileName())"
    New-Item -ItemType Directory -Force -Path $tmp | Out-Null
    $toolsFx = Join-Path $tmp 'tools.yaml'
    Set-Content -LiteralPath $toolsFx -Encoding utf8 -Value "tools: []"
    $fleetFx = Join-Path $tmp 'fleet.yaml'
    Set-Content -LiteralPath $fleetFx -Encoding utf8 -Value @'
general_capabilities: [code-gen]
providers:
  - name: local-model
    kind: http
    enabled: true
    cost_tier: local
  - name: gh-budget
    kind: cli
    enabled: true
    cost_tier: free
    budget: 50
    saturate: true
'@
    $ratingsFx = Join-Path $tmp 'ratings.jsonl'
    $journalFx = Join-Path $tmp 'routing.jsonl'
    $usageFx   = Join-Path $tmp 'usage.jsonl'   # empty -> 0 consumed -> full headroom
    function Sel([string]$mode,[string]$usage){
        Select-Capability -Capability 'code-gen' -SelectionMode $mode -ToolsPath $toolsFx -FleetPath $fleetFx -RatingsPath $ratingsFx -JournalPath $journalFx -UsagePath $usage
    }

    # empty usage journal: gh-budget has full headroom -> boosted above local
    $econ = Sel 'economy' $usageFx
    Check 'S18 saturator ranks first (below local)' ($econ[0].name -eq 'gh-budget')
    Check 'S19 boosted candidate tagged saturate' ($econ[0].saturate -eq $true -and $null -ne $econ[0].sat_util)
    Check 'S20 boosted why explains saturation' ($econ[0].why -match 'saturate:')
    Check 'S21 local still present, not boosted' (($econ | Where-Object { $_.name -eq 'local-model' }).saturate -ne $true)

    # champion mode: no saturation -> local-vs-free ranked by quality/tier, gh not floored
    $champ = Sel 'champion' $usageFx
    Check 'S22 champion mode: saturator NOT floored' (($champ | Where-Object { $_.name -eq 'gh-budget' }).saturate -ne $true)

    # at/above target: consume the whole budget -> no boost
    1..50 | ForEach-Object { Add-Content -LiteralPath $usageFx -Encoding utf8 -Value ('{"ts":"2026-06-21T0%d:00:00Z","event":"tick","worker":"gh-budget","count":1,"unit":"requests"}' -f ($_ % 10)) }
    $full = Sel 'economy' $usageFx
    Check 'S23 fully-consumed budget -> not boosted' (($full | Where-Object { $_.name -eq 'gh-budget' }).saturate -ne $true)
    Check 'S24 fully-consumed -> local ranks first' ($full[0].name -eq 'local-model')

    # conserve mode suppresses the boost (fresh empty usage journal + conserve event)
    $usageC = Join-Path $tmp 'usage-conserve.jsonl'
    Add-Content -LiteralPath $usageC -Encoding utf8 -Value '{"ts":"2026-06-21T00:00:00Z","event":"conserve","worker":"*","on":true}'
    $cons = Sel 'economy' $usageC
    Check 'S25 conserve suppresses saturation boost' (($cons | Where-Object { $_.name -eq 'gh-budget' }).saturate -ne $true)

    # exhausted worker is excluded by route-around, never boosted
    $usageX = Join-Path $tmp 'usage-exhausted.jsonl'
    Add-Content -LiteralPath $usageX -Encoding utf8 -Value '{"ts":"2026-06-21T00:00:00Z","event":"lockout","worker":"gh-budget","reason":"manual"}'
    $exh = Sel 'economy' $usageX
    Check 'S26 exhausted saturator excluded (route-around wins)' ($null -eq ($exh | Where-Object { $_.name -eq 'gh-budget' }))

    # non-opted-in fleet ranks exactly as today: local (tier 0) before free (tier 1)
    $fleetPlain = Join-Path $tmp 'fleet-plain.yaml'
    Set-Content -LiteralPath $fleetPlain -Encoding utf8 -Value @'
general_capabilities: [code-gen]
providers:
  - name: local-model
    kind: http
    enabled: true
    cost_tier: local
  - name: free-model
    kind: cli
    enabled: true
    cost_tier: free
'@
    $plain = Select-Capability -Capability 'code-gen' -SelectionMode 'economy' -ToolsPath $toolsFx -FleetPath $fleetPlain -RatingsPath $ratingsFx -JournalPath $journalFx -UsagePath $usageFx
    Check 'S27 no opt-in: local before free (unchanged economy order)' ($plain[0].name -eq 'local-model')

    # two saturators order by utilization ascending (most headroom first)
    $fleet2 = Join-Path $tmp 'fleet-two.yaml'
    Set-Content -LiteralPath $fleet2 -Encoding utf8 -Value @'
general_capabilities: [code-gen]
providers:
  - name: gh-a
    kind: cli
    enabled: true
    cost_tier: free
    budget: 100
    saturate: true
  - name: gh-b
    kind: cli
    enabled: true
    cost_tier: free
    budget: 100
    saturate: true
'@
    $usage2 = Join-Path $tmp 'usage-two.jsonl'
    1..40 | ForEach-Object { Add-Content -LiteralPath $usage2 -Encoding utf8 -Value '{"ts":"2026-06-21T00:00:00Z","event":"tick","worker":"gh-a","count":1,"unit":"requests"}' }
    1..10 | ForEach-Object { Add-Content -LiteralPath $usage2 -Encoding utf8 -Value '{"ts":"2026-06-21T00:00:00Z","event":"tick","worker":"gh-b","count":1,"unit":"requests"}' }
    $two = Select-Capability -Capability 'code-gen' -SelectionMode 'economy' -ToolsPath $toolsFx -FleetPath $fleet2 -RatingsPath $ratingsFx -JournalPath $journalFx -UsagePath $usage2
    Check 'S28 lower-utilization saturator ranks first' ($two[0].name -eq 'gh-b')

    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `pwsh -NoProfile -File scripts/test-saturation-lib.ps1`
Expected: FAIL — S18+ fail (no saturation wiring yet: `gh-budget` is not boosted, `$econ[0].name` is `local-model`).

- [ ] **Step 3: Implement the wiring**

In `scripts/routing-lib.ps1`:

**(a)** After the `usage-lib.ps1` dot-source (currently line 14), add:

```powershell
. "$PSScriptRoot/saturation-lib.ps1"   # d-wa-5 active saturation driver
```

**(b)** In §2, extend the fleet-candidate object (the `[void]$candidates.Add([pscustomobject]@{ ... })` block) with three passthrough fields + the saturation tags. Change it to:

```powershell
            [void]$candidates.Add([pscustomobject]@{
                name = [string]$p.name; kind = [string]$p.kind; source = 'fleet'
                cost_tier = [string]$p.cost_tier; quality = $detail.quality
                quality_detail = $detail
                role = $p.role; platform = $p.platform
                budget = $p.budget; saturate = $p.saturate; saturation_target = $p.saturation_target
                sat_util = $null
                why = $why
            })
```

**(c)** Replace the entire §3b block (`# 3b. Usage governance ...` through its closing `}`) with:

```powershell
    # 3b. Usage governance (Sprint 2) + active saturation (d-wa-5).
    #     Route-around drops hard-stopped workers + down-ranks limited; saturation
    #     up-ranks an under-utilized opt-in budgeted worker (effective tier -1).
    #     Absent journal -> route-around no-op; saturation still applies (0 consumed).
    $usageRows = @()
    $conserve  = $false
    if (Get-Command Get-WorkerState -ErrorAction SilentlyContinue) {
        $usageRows = Read-UsageJournal -Path $UsagePath
        if (@($usageRows).Count -gt 0) {
            $conserve = Get-ConserveMode -Rows $usageRows
            $hardOut  = @('exhausted','cooling_down','waiting_for_reset')
            $filtered = foreach ($c in $filtered) {
                if ($c.source -ne 'fleet') { $c; continue }
                $st = (Get-WorkerState -Worker $c.name -Rows $usageRows).state
                if ($hardOut -contains $st) { continue }
                if ($st -eq 'limited') {
                    if ($conserve) { continue }
                    $c.quality = [double]$c.quality * 0.5   # soft down-rank
                }
                $c
            }
            if ($conserve) { $SelectionMode = 'economy' }
        }
        # Saturation boost: up-rank a surviving under-utilized opt-in budgeted worker.
        foreach ($c in $filtered) {
            if ($c.source -ne 'fleet') { continue }
            if (-not $c.saturate) { continue }
            $budget = if ($null -ne $c.budget) { [int]$c.budget } else { 0 }
            $target = if ($null -ne $c.saturation_target) { [double]$c.saturation_target } else { 99.9 }
            $st = (Get-WorkerState -Worker $c.name -Rows $usageRows).state
            $cu = Get-CandidateUtilization -Rows $usageRows -Worker $c.name -Budget $budget
            $decision = Get-SaturationDecision -Saturate ([bool]$c.saturate) -Budget $budget -Consumed $cu.consumed -Target $target -State $st -SelectionMode $SelectionMode -Conserve $conserve
            if ($decision.apply) {
                $c.saturate = $true
                $c.sat_util = $decision.utilization
                $c.why = $decision.reason
            } else {
                $c.saturate = $false
            }
        }
    }
```

**(d)** Replace the §4 economy ranking branch (the `else { $ranked = $filtered | ... }` block) with the effective-tier-floor version (champion branch unchanged):

```powershell
    } else {
        $ranked = $filtered |
            Select-Object *, @{n='score'; e={ (Get-EffectiveTierRank $_.cost_tier ([bool]$_.saturate)) - ($_.quality * 0.001) }} |
            Sort-Object `
                @{e={ Get-EffectiveTierRank $_.cost_tier ([bool]$_.saturate) }}, `
                @{e={ if ([bool]$_.saturate) { [double]$_.sat_util } else { 0 } }}, `
                @{e={ -$_.quality }}, `
                @{e='name'}
    }
```

> Note: for non-saturating candidates `Get-EffectiveTierRank` equals `Get-CostTierRank` and the util key is the constant `0`, so the economy order is identical to today (cost tier asc, quality desc, name). Tools candidates lack a `saturate` property; `[bool]$_.saturate` evaluates `$null → $false`, so they are never floored.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `pwsh -NoProfile -File scripts/test-saturation-lib.ps1`
Expected: PASS — `ALL PASS` (S1–S28).

- [ ] **Step 5: Run the existing routing suites to confirm no regression**

Run: `pwsh -NoProfile -File scripts/test-routing-lib.ps1`
Expected: the suite still passes (exit 0). If `test-routing-lib.ps1` is absent, run every `scripts/test-routing*.ps1` and `scripts/test-cascade*.ps1` present; each must exit 0. Non-saturating ordering and scores are unchanged.

- [ ] **Step 6: Commit**

```bash
git add scripts/routing-lib.ps1 scripts/test-saturation-lib.ps1
git commit -m "feat(saturation): wire effective-tier-floor boost into Select-Capability (d-wa-5)"
```

---

### Task 3: Seed docs, bootstrap manifest, plugin bump

**Files:**
- Modify: `references/fleet.yaml` (field-taxonomy comments ~17-37; `github-models` row ~178-190)
- Modify: `scripts/bootstrap.ps1` (manifest array, line ~259)
- Modify: `scripts/test-bootstrap.ps1` (add a `saturation-lib.ps1` assert)
- Modify: `.claude-plugin/plugin.json` (version)

**Interfaces:**
- Consumes: nothing new.
- Produces: `saturation-lib.ps1` deployed by bootstrap; seed documents `saturate`/`saturation_target`; plugin at `1.4.0-rc.1`.

- [ ] **Step 1: Add the field docs to the taxonomy comment block**

In `references/fleet.yaml`, in the per-field comment block (right after the `adapter` doc lines, before `platform`), add:

```yaml
#   saturate          (optional) true | false — opt into the active saturation driver:
#                     when this worker has a budget and is under-utilized, routing
#                     up-ranks it (economy mode) to spend its pre-paid allotment first.
#                     Default false. BOX-PRIVATE: set a real `saturate: true` (and the
#                     budget) only in your live ~/.baton/fleet.yaml.
#   saturation_target (optional, float) utilization %% the driver pushes toward before it
#                     stops boosting. Default 99.9.
```

- [ ] **Step 2: Add the example to the `github-models` seed row**

In `references/fleet.yaml`, in the `github-models` provider block, immediately after the two `# budget:` box-private comment lines, add:

```yaml
    saturate: false           # opt-in: set true (with a real budget) in live ~/.baton/fleet.yaml
    # saturation_target: 99.9 # optional; default is 99.9
```

- [ ] **Step 3: Add `saturation-lib.ps1` to the bootstrap manifest**

In `scripts/bootstrap.ps1`, in the `foreach ($script in @( ... ))` deploy manifest (line ~259), insert `'saturation-lib.ps1'` immediately after `'routing-lib.ps1'`:

```
... 'routing-lib.ps1', 'saturation-lib.ps1', 'routing-dispatch.ps1', ...
```

- [ ] **Step 4: Add the bootstrap test assert**

In `scripts/test-bootstrap.ps1`, the manifest asserts use `Assert "<label>" ($out -match '<name>\.ps1')`. Immediately after the `routing-lib.ps1` assert (currently line 32) add:

```powershell
Assert "would deploy saturation-lib.ps1" ($out -match 'saturation-lib\.ps1')
```

- [ ] **Step 5: Bump the plugin version**

In `.claude-plugin/plugin.json`, change:

```json
  "version": "1.3.0",
```
to:
```json
  "version": "1.4.0-rc.1",
```

- [ ] **Step 6: Run the bootstrap suite**

Run: `pwsh -NoProfile -File scripts/test-bootstrap.ps1`
Expected: PASS — all asserts pass including the new `saturation-lib.ps1` one, exit 0.

- [ ] **Step 7: Run the saturation suite once more (deploy-shape sanity)**

Run: `pwsh -NoProfile -File scripts/test-saturation-lib.ps1`
Expected: `ALL PASS`.

- [ ] **Step 8: Commit**

```bash
git add references/fleet.yaml scripts/bootstrap.ps1 scripts/test-bootstrap.ps1 .claude-plugin/plugin.json
git commit -m "feat(saturation): seed docs + bootstrap manifest + plugin 1.4.0-rc.1 (d-wa-5)"
```

---

## Notes for the final whole-branch review

- Confirm non-saturating selection is byte-for-byte unchanged (the route-around `×0.5`, economy `cost tier asc / quality desc`, champion ordering, and `.score` values for non-saturators).
- Confirm box-private: no real budget and no `saturate: true` in `references/fleet.yaml`.
- Confirm the saturation pass runs on an empty usage journal (0 consumed → full headroom → boost), and that an exhausted/limited budgeted worker is handled by route-around, never boosted.
- Minor follow-ups deferred by the spec (do not implement): reset-proximity urgency weighting, graded boost curve, driver-level saturation report in the cascade/run-loop.
```
