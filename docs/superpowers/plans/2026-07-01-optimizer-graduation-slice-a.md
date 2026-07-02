# Optimizer Graduation Slice A Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Graduate `/baton:optimize-prompt` from single-shot reflect-and-propose to a real GEPA loop: persistent candidate pool + two-model reflect/mutate split + plan-only minibatch judged against recorded gate findings + dual acceptance gate; human `--apply` stays the deployment gate.

**Architecture:** New `scripts/prompt-pool-lib.ps1` owns pool state (manifest + per-candidate text files under `BATON_HOME/prompts/pool/`), Pareto math, parent selection, and the dual gate — all pure/seamed. `scripts/optimize-prompt-lib.ps1` gains the minibatch evaluator and `Invoke-PromptEvolution`, which **replaces** `Invoke-PromptOptimizer` (`-Generations 1` on an empty pool reproduces v1's observable behavior). The CLI grows `-Generations`, `-ReflectTier`, `-Pool`.

**Tech Stack:** PowerShell 7 (pwsh), house Assert/PASS-FAIL test suites, existing fleet routing (`Select-Capability` / `Invoke-Fleet`).

**Spec:** `docs/superpowers/specs/2026-07-01-optimizer-graduation-design.md` — read it if a requirement here seems ambiguous.

## Global Constraints

- Every shell command argument must stay under **965 bytes** (silent failure above) — large text always moves via files or in-process function parameters, never inline args.
- Never use `Write-Error` (throws under `$ErrorActionPreference='Stop'`); log failures via `[Console]::Error.WriteLine(...)`; CLI hard-fails with `exit 2`.
- All file writes use `-Encoding utf8NoBOM`.
- Unary-comma array returns need the empty guard: `,([array]$x)` on an EMPTY array wraps it (Count=1, not 0) — return plain `@()` for the empty case.
- Never name variables `$args`, `$input`, `$event`, `$matches`, `$host` (reading the automatic `$Matches` after `-match` is fine).
- Parenthesize function calls used inside comparisons: `(@($x).Count -eq 0)`, `(([int]$r.exit_code) -ne 0)`.
- Tests are hermetic: temp `BATON_HOME`, temp dirs, dispatcher seams — **never** read or write the real `~/.baton` or `~/.claude`.
- The pool is **box-private** (`BATON_HOME/prompts/pool/`): never seeded by bootstrap, never enters the knowledge repo.
- Exactly **one** pool member has `status = 'champion'` at all times.
- The live prompt file (`conductor-planner.txt`) remains the single source the Conductor reads; the pool is bookkeeping around it. `--apply` (human) is the only path that writes it. (d070)
- Dispatcher seam contract everywhere: a `[scriptblock]` receiving ONE string prompt and returning `@{ stdout = <string>; exit_code = <int> }` (same shape as `Invoke-Fleet`).
- Plugin version target: `1.6.0-rc.1`.

---

### Task 1: prompt-pool-lib.ps1 — pool state, Pareto front, parent selection, dual gate

**Files:**
- Create: `scripts/prompt-pool-lib.ps1`
- Create: `scripts/test-prompt-pool-lib.ps1`

**Interfaces:**
- Consumes: `Get-BatonHome` from `scripts/baton-home.ps1`.
- Produces (used by Tasks 3–4):
  - `Get-PromptPoolDir([string]$BatonHome)` → `[string]` (default `BATON_HOME/prompts/pool`)
  - `Get-PromptTokenEstimate([string]$Text)` → `[int]` (`ceil(chars/4)`)
  - `Get-PromptPool([string]$PoolDir)` → `@{ ok; pool; reason }` (`reason` = `'absent'` | `'loaded'` | `"corrupt manifest at <path>: <msg>"`)
  - `Save-PromptPool([hashtable]$Pool, [string]$PoolDir)` → writes `pool.json`
  - `New-PoolCandidateRecord(-Id -Parent -Origin -Status -PromptTokens)` → candidate `[hashtable]` per spec schema
  - `Initialize-PromptPool(-SeedPromptPath [-PoolDir])` → `@{ ok; pool; reason }`, seeds `p001` champion
  - `Get-NextCandidateId([hashtable]$Pool)` → `'pNNN'`
  - `Get-ParetoFront([array]$Candidates)` → `[array]` of non-dominated active members
  - `Select-ParentCandidate([hashtable]$Pool, [scriptblock]$Draw)` → candidate `[hashtable]`
  - `Test-DualGate(-Child -WinRateVsParent -Pool)` → `@{ pass; reasons }`

- [ ] **Step 1: Write the failing test suite**

Create `scripts/test-prompt-pool-lib.ps1`:

```powershell
#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Tests for prompt-pool-lib.ps1 (house Check/PASS-FAIL style, exit-code gated).
.DESCRIPTION
  Hermetic: temp pool dirs only; never touches the real ~/.baton or ~/.claude.
#>
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'prompt-pool-lib.ps1')

$script:fail = 0
function Check($n, $c) { if ($c) { Write-Host "PASS: $n" } else { Write-Host "FAIL: $n"; $script:fail++ } }

function New-TempDir {
    $d = Join-Path ([System.IO.Path]::GetTempPath()) ("pool-lib-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $d | Out-Null
    return $d
}

# Helper: minimal active candidate for Pareto/gate tests.
function New-TestCand($id, $status, $wr, $tokens) {
    $c = New-PoolCandidateRecord -Id $id -Parent $null -Origin 'mutation' -Status $status -PromptTokens $tokens
    $c.offline.minibatch.win_rate_vs_champion = $wr
    return $c
}

# ---- Token estimate ----
Check 'P1 empty text -> 0 tokens' ((Get-PromptTokenEstimate '') -eq 0)
Check 'P2 4 chars -> 1 token' ((Get-PromptTokenEstimate 'abcd') -eq 1)
Check 'P3 5 chars -> 2 tokens (ceil)' ((Get-PromptTokenEstimate 'abcde') -eq 2)

# ---- Get-PromptPool: absent ----
$absentDir = Join-Path (New-TempDir) 'nope'
$resAbsent = Get-PromptPool -PoolDir $absentDir
Check 'P4 absent pool -> ok=false, reason=absent' ((-not $resAbsent.ok) -and ($resAbsent.reason -eq 'absent'))

# ---- Initialize-PromptPool: seed ----
$seedDir = New-TempDir
$seedPath = Join-Path $seedDir 'conductor-planner.txt'
Set-Content -LiteralPath $seedPath -Value "SEED {{schema}} {{evi}} {{Goal}}" -Encoding utf8NoBOM
$poolDir = Join-Path $seedDir 'pool'
$init = Initialize-PromptPool -SeedPromptPath $seedPath -PoolDir $poolDir
Check 'P5 seed init ok' ($init.ok)
Check 'P6 champion is p001' ($init.pool.champion -eq 'p001')
Check 'P7 seed candidate status champion, origin seed' (($init.pool.candidates[0].status -eq 'champion') -and ($init.pool.candidates[0].origin -eq 'seed'))
Check 'P8 champion win rate is 0.5 by definition' (([double]$init.pool.candidates[0].offline.minibatch.win_rate_vs_champion) -eq 0.5)
Check 'P9 p001.txt written with seed text' ((Get-Content -Raw (Join-Path $poolDir 'p001.txt')) -match 'SEED \{\{schema\}\}')
Check 'P10 live fields present at zero' (([int]$init.pool.candidates[0].live.runs) -eq 0)

# ---- Initialize-PromptPool: missing seed ----
$initMiss = Initialize-PromptPool -SeedPromptPath (Join-Path $seedDir 'missing.txt') -PoolDir (Join-Path $seedDir 'pool2')
Check 'P11 missing seed prompt -> ok=false' (-not $initMiss.ok)

# ---- Round trip ----
$rt = Get-PromptPool -PoolDir $poolDir
Check 'P12 round trip loads seeded pool' ($rt.ok -and ($rt.pool.champion -eq 'p001'))

# ---- Corrupt manifest ----
$corruptDir = New-TempDir
Set-Content -LiteralPath (Join-Path $corruptDir 'pool.json') -Value '{ not json !!!' -Encoding utf8NoBOM
$resCorrupt = Get-PromptPool -PoolDir $corruptDir
Check 'P13 corrupt manifest -> ok=false, corrupt reason' ((-not $resCorrupt.ok) -and ($resCorrupt.reason -match 'corrupt'))
Check 'P14 corrupt manifest untouched on load' ((Get-Content -Raw (Join-Path $corruptDir 'pool.json')) -match 'not json')

# ---- Get-NextCandidateId ----
Check 'P15 next id after p001 is p002' ((Get-NextCandidateId -Pool $rt.pool) -eq 'p002')
$gapPool = @{ schema = 1; champion = 'p001'; candidates = @((New-TestCand 'p001' 'champion' 0.5 100), (New-TestCand 'p007' 'retired' 0.4 90)) }
Check 'P16 next id skips past highest (p007 -> p008)' ((Get-NextCandidateId -Pool $gapPool) -eq 'p008')

# ---- Get-ParetoFront ----
$a = New-TestCand 'p001' 'champion' 0.6 100
$b = New-TestCand 'p002' 'candidate' 0.5 120
$c = New-TestCand 'p003' 'candidate' 0.7 80
$front1 = Get-ParetoFront -Candidates @($a, $b, $c)
Check 'P17 dominated members excluded (only p003 survives)' ((@($front1).Count -eq 1) -and (@($front1)[0].id -eq 'p003'))
$d = New-TestCand 'p004' 'candidate' 0.7 150
$front2 = Get-ParetoFront -Candidates @($a, $d)
Check 'P18 trade-off pair both on front' (@($front2).Count -eq 2)
$r = New-TestCand 'p005' 'retired' 0.9 10
$front3 = Get-ParetoFront -Candidates @($a, $r)
Check 'P19 retired members excluded from front' ((@($front3).Count -eq 1) -and (@($front3)[0].id -eq 'p001'))
$u = New-TestCand 'p006' 'candidate' $null 10
$front4 = Get-ParetoFront -Candidates @($a, $u)
Check 'P20 unscored (null win rate) members excluded' ((@($front4).Count -eq 1) -and (@($front4)[0].id -eq 'p001'))
Check 'P21 empty input -> empty front (Count 0, not 1)' (@((Get-ParetoFront -Candidates @())).Count -eq 0)

# ---- Select-ParentCandidate ----
$selPool = @{ schema = 1; champion = 'p001'; candidates = @($a, $d) }   # both on front
$pick0 = Select-ParentCandidate -Pool $selPool -Draw { param($total) 0.0 }
Check 'P22 draw 0.0 picks first front member' ($pick0.id -eq 'p001')
$a2 = New-TestCand 'p001' 'champion' 0.6 100
$a2.offline.times_selected = 9   # weight 0.1 vs p004 weight 1.0
$selPool2 = @{ schema = 1; champion = 'p001'; candidates = @($a2, $d) }
$pickW = Select-ParentCandidate -Pool $selPool2 -Draw { param($total) 0.5 }
Check 'P23 frequency weighting shifts pick to less-selected member' ($pickW.id -eq 'p004')
$unscored = @{ schema = 1; champion = 'p001'; candidates = @((New-TestCand 'p001' 'champion' $null 100)) }
$pickFallback = Select-ParentCandidate -Pool $unscored -Draw { param($total) 0.0 }
Check 'P24 empty front falls back to champion' ($pickFallback.id -eq 'p001')

# ---- Test-DualGate ----
$gatePool = @{ schema = 1; champion = 'p001'; candidates = @((New-TestCand 'p001' 'champion' 0.5 100)) }
$childGood = New-TestCand 'p002' 'candidate' 0.8 90
$g1 = Test-DualGate -Child $childGood -WinRateVsParent 0.8 -Pool $gatePool
Check 'P25 beats parent + non-dominated -> pass' ($g1.pass)
$childDom = New-TestCand 'p003' 'candidate' 0.4 110   # champion dominates: 0.5>0.4, 100<110
$g2 = Test-DualGate -Child $childDom -WinRateVsParent 0.6 -Pool $gatePool
Check 'P26 dominated child -> fail with Pareto reason' ((-not $g2.pass) -and ((@($g2.reasons) -join ';') -match 'dominated'))
$g3 = Test-DualGate -Child $childGood -WinRateVsParent 0.5 -Pool $gatePool
Check 'P27 exactly 0.5 vs parent -> fail (must BEAT parent)' (-not $g3.pass)
$g4 = Test-DualGate -Child $childGood -WinRateVsParent $null -Pool $gatePool
Check 'P28 null vs parent (all ties) -> fail, no-evidence reason' ((-not $g4.pass) -and ((@($g4.reasons) -join ';') -match 'no evidence'))
$childUnscored = New-TestCand 'p004' 'candidate' $null 90
$g5 = Test-DualGate -Child $childUnscored -WinRateVsParent 0.9 -Pool $gatePool
Check 'P29 null vs champion -> fail, no-evidence reason' ((-not $g5.pass) -and ((@($g5.reasons) -join ';') -match 'no evidence'))

if ($script:fail -gt 0) { Write-Host "`n$script:fail check(s) FAILED"; exit 1 }
Write-Host "`nAll checks passed."
exit 0
```

- [ ] **Step 2: Run the suite to verify it fails**

Run: `pwsh -NoProfile -File scripts/test-prompt-pool-lib.ps1`
Expected: hard error — `prompt-pool-lib.ps1` does not exist yet.

- [ ] **Step 3: Implement the library**

Create `scripts/prompt-pool-lib.ps1`:

```powershell
#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Candidate-pool state + Pareto math for the GEPA optimizer graduation.
.DESCRIPTION
  Pool = BATON_HOME/prompts/pool/pool.json manifest + one pNNN.txt per
  candidate. Box-private: never seeded by bootstrap, never leaves the box.
  Exactly one member has status 'champion' (the live prompt's bookkeeping
  twin); 'candidate' = gate survivor awaiting human --apply; 'retired'
  members are kept as reflection fuel, never deleted.
.NOTES
  House trap: under $ErrorActionPreference = 'Stop', Write-Error THROWS —
  failures are reported via the returned reason strings instead.
#>

. "$PSScriptRoot/baton-home.ps1"

function Get-PromptPoolDir {
    param([string]$BatonHome = (Get-BatonHome))
    return (Join-Path $BatonHome 'prompts/pool')
}

function Get-PromptTokenEstimate {
    <# ceil(chars/4): no tokenizer in PowerShell; the estimate only needs to
       be monotone and consistent across candidates. #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    return [int][math]::Ceiling($Text.Length / 4.0)
}

function Get-PromptPool {
    param([string]$PoolDir = (Get-PromptPoolDir))
    $manifest = Join-Path $PoolDir 'pool.json'
    if (-not (Test-Path $manifest)) { return @{ ok = $false; pool = $null; reason = 'absent' } }
    try {
        $pool = Get-Content -Raw $manifest | ConvertFrom-Json -AsHashtable
    } catch {
        return @{ ok = $false; pool = $null; reason = "corrupt manifest at ${manifest}: $($_.Exception.Message)" }
    }
    if (($null -eq $pool) -or ($null -eq $pool.candidates)) {
        return @{ ok = $false; pool = $null; reason = "corrupt manifest at ${manifest}: missing candidates" }
    }
    return @{ ok = $true; pool = $pool; reason = 'loaded' }
}

function Save-PromptPool {
    param([Parameter(Mandatory)][hashtable]$Pool, [string]$PoolDir = (Get-PromptPoolDir))
    if (-not (Test-Path $PoolDir)) { New-Item -ItemType Directory -Force -Path $PoolDir | Out-Null }
    ConvertTo-Json -InputObject $Pool -Depth 10 |
        Set-Content -LiteralPath (Join-Path $PoolDir 'pool.json') -Encoding utf8NoBOM
}

function New-PoolCandidateRecord {
    <# Schema v1 candidate record (spec: pool schema). live.* is written only
       by Slice B (shadow A/B); Slice A creates the fields at zero. #>
    param(
        [Parameter(Mandatory)][string]$Id,
        [AllowNull()][string]$Parent,
        [Parameter(Mandatory)][ValidateSet('seed','mutation')][string]$Origin,
        [Parameter(Mandatory)][ValidateSet('champion','candidate','retired')][string]$Status,
        [Parameter(Mandatory)][int]$PromptTokens
    )
    return @{
        id = $Id; file = "$Id.txt"; parent = $Parent; origin = $Origin
        created = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        status = $Status
        retired_reason = $null
        offline = @{
            times_selected = 0
            prompt_tokens = $PromptTokens
            minibatch = @{ wins = 0; losses = 0; ties = 0; win_rate_vs_champion = $null; examples = @() }
        }
        live = @{ runs = 0; accept = 0; polish = 0; reject = 0; realized_cost_usd = 0.0; rework_cost_usd = 0.0 }
    }
}

function Initialize-PromptPool {
    <# Seed the pool from the live planner prompt as p001/champion.
       The champion's win_rate_vs_champion is 0.5 by definition (it is the
       reference every minibatch measures against). #>
    param([Parameter(Mandatory)][string]$SeedPromptPath, [string]$PoolDir = (Get-PromptPoolDir))
    if (-not (Test-Path $SeedPromptPath)) {
        return @{ ok = $false; pool = $null; reason = "seed prompt not found at $SeedPromptPath" }
    }
    $seedText = Get-Content -Raw $SeedPromptPath
    if (-not (Test-Path $PoolDir)) { New-Item -ItemType Directory -Force -Path $PoolDir | Out-Null }
    $seed = New-PoolCandidateRecord -Id 'p001' -Parent $null -Origin 'seed' -Status 'champion' `
        -PromptTokens (Get-PromptTokenEstimate -Text $seedText)
    $seed.offline.minibatch.win_rate_vs_champion = 0.5
    Set-Content -LiteralPath (Join-Path $PoolDir 'p001.txt') -Value $seedText -Encoding utf8NoBOM
    $pool = @{ schema = 1; champion = 'p001'; candidates = @($seed) }
    Save-PromptPool -Pool $pool -PoolDir $PoolDir
    return @{ ok = $true; pool = $pool; reason = 'seeded' }
}

function Get-NextCandidateId {
    param([Parameter(Mandatory)][hashtable]$Pool)
    $max = 0
    foreach ($c in @($Pool.candidates)) {
        if (([string]$c.id) -match '^p(\d+)$') {
            $n = [int]$Matches[1]
            if ($n -gt $max) { $max = $n }
        }
    }
    return ('p{0:d3}' -f ($max + 1))
}

function Get-ParetoFront {
    <# Non-dominated set of ACTIVE (champion|candidate) members on the axes
       (win_rate_vs_champion: higher better, prompt_tokens: lower better).
       Unscored members (null win rate — e.g. stale after a champion swap)
       are excluded until re-evaluated. #>
    param([Parameter(Mandatory)][AllowEmptyCollection()][array]$Candidates)
    $active = @($Candidates | Where-Object {
        ($_.status -in @('champion', 'candidate')) -and ($null -ne $_.offline.minibatch.win_rate_vs_champion)
    })
    if ($active.Count -eq 0) { return @() }
    $front = [System.Collections.ArrayList]@()
    foreach ($a in $active) {
        $awr = [double]$a.offline.minibatch.win_rate_vs_champion
        $at = [int]$a.offline.prompt_tokens
        $dominated = $false
        foreach ($b in $active) {
            if ($b.id -eq $a.id) { continue }
            $bwr = [double]$b.offline.minibatch.win_rate_vs_champion
            $bt = [int]$b.offline.prompt_tokens
            if (($bwr -ge $awr) -and ($bt -le $at) -and (($bwr -gt $awr) -or ($bt -lt $at))) {
                $dominated = $true; break
            }
        }
        if (-not $dominated) { [void]$front.Add($a) }
    }
    if ($front.Count -eq 0) { return @() }
    return ,([array]$front)
}

function Select-ParentCandidate {
    <# Frequency-weighted random pick from the Pareto front (DeepEval):
       weight = 1/(1+times_selected) spreads exploration. Empty front (young
       or all-stale pool) degenerates to the champion. -Draw is the
       determinism seam: receives the total weight, returns [0,total). #>
    param(
        [Parameter(Mandatory)][hashtable]$Pool,
        [scriptblock]$Draw = { param($total) Get-Random -Minimum 0.0 -Maximum $total }
    )
    $front = Get-ParetoFront -Candidates @($Pool.candidates)
    if (@($front).Count -eq 0) {
        return @($Pool.candidates | Where-Object { $_.id -eq $Pool.champion })[0]
    }
    $total = 0.0
    foreach ($c in @($front)) { $total += 1.0 / (1.0 + [int]$c.offline.times_selected) }
    $x = [double](& $Draw $total)
    foreach ($c in @($front)) {
        $x -= 1.0 / (1.0 + [int]$c.offline.times_selected)
        if ($x -lt 0) { return $c }
    }
    return @($front)[-1]
}

function Test-DualGate {
    <# Spec dual gate: (a) child BEATS its parent on the minibatch
       (win_rate_vs_parent strictly > 0.5; null = all ties/no examples = no
       evidence = fail), AND (b) child is Pareto-non-dominated among the
       pool's active scored members. Returns @{ pass; reasons }. #>
    param(
        [Parameter(Mandatory)][hashtable]$Child,
        [Parameter(Mandatory)][AllowNull()][object]$WinRateVsParent,
        [Parameter(Mandatory)][hashtable]$Pool
    )
    $reasons = [System.Collections.ArrayList]@()
    if ($null -eq $WinRateVsParent) {
        [void]$reasons.Add('no evidence vs parent (all ties or no scoreable examples)')
    } elseif (([double]$WinRateVsParent) -le 0.5) {
        [void]$reasons.Add("did not beat parent (win rate $WinRateVsParent)")
    }
    if ($null -eq $Child.offline.minibatch.win_rate_vs_champion) {
        [void]$reasons.Add('no evidence vs champion (all ties or no scoreable examples)')
    } else {
        $cwr = [double]$Child.offline.minibatch.win_rate_vs_champion
        $ct = [int]$Child.offline.prompt_tokens
        $active = @($Pool.candidates | Where-Object {
            ($_.status -in @('champion', 'candidate')) -and ($null -ne $_.offline.minibatch.win_rate_vs_champion)
        })
        foreach ($b in $active) {
            $bwr = [double]$b.offline.minibatch.win_rate_vs_champion
            $bt = [int]$b.offline.prompt_tokens
            if (($bwr -ge $cwr) -and ($bt -le $ct) -and (($bwr -gt $cwr) -or ($bt -lt $ct))) {
                [void]$reasons.Add("Pareto-dominated by $($b.id)")
                break
            }
        }
    }
    if ($reasons.Count -eq 0) { return @{ pass = $true; reasons = @() } }
    return @{ pass = $false; reasons = ,([array]$reasons) }
}
```

- [ ] **Step 4: Run the suite to verify it passes**

Run: `pwsh -NoProfile -File scripts/test-prompt-pool-lib.ps1`
Expected: `PASS` × 29, exit 0.

- [ ] **Step 5: Commit**

```bash
git add scripts/prompt-pool-lib.ps1 scripts/test-prompt-pool-lib.ps1
git commit -m "feat(optimizer): prompt-pool-lib — pool state, Pareto front, parent selection, dual gate"
```

---

### Task 2: Minibatch evaluator (plan-only head-to-head + judge)

**Files:**
- Modify: `scripts/optimize-prompt-lib.ps1` (add functions; do NOT remove `Invoke-PromptOptimizer` yet — Task 3 does)
- Modify: `scripts/test-optimize-prompt-lib.ps1` (append M-series checks before the exit-gate lines)

**Interfaces:**
- Consumes: `Get-HistoricalRuns` run shape (`@{ run_id; goal; plan_tasks; verdict; reason; findings; polish_brief }`).
- Produces (used by Task 3):
  - `Build-HydratedPlannerPrompt(-Template [string], -Goal [string])` → `[string]` (literal `[string]::Replace`, never regex)
  - `Build-JudgePrompt(-Run [hashtable], -PlanA [string], -PlanB [string])` → `[string]` (instructs `<verdict>A|B|tie</verdict>`)
  - `Invoke-MinibatchEval(-CandidatePrompt -ReferencePrompt -Runs -PlanDispatcher -JudgeDispatcher)` → `@{ wins; losses; ties; dropped; win_rate; examples }` (`win_rate` = `wins/(wins+losses)` rounded 4dp, ties excluded; `$null` when `wins+losses -eq 0`)

- [ ] **Step 1: Append the failing M-series checks**

In `scripts/test-optimize-prompt-lib.ps1`, the suite ends with a `finally` block restoring `$env:BATON_HOME` and then exit-gate lines (`if ($script:fail -gt 0) ... exit 1` / `exit 0`). Insert the following INSIDE the `try` block, after the last existing check:

```powershell
    # ==== M-series: minibatch evaluator ====
    $mbRuns = @(
        @{ run_id = 'go-1'; goal = 'Goal one'; verdict = 'reject'; reason = 'R1'; findings = '{}'; polish_brief = 'P1' },
        @{ run_id = 'go-2'; goal = 'Goal two'; verdict = 'polish'; reason = 'R2'; findings = '{}'; polish_brief = $null }
    )

    # Hydration is literal (injection-safe) and total.
    $hyd = Build-HydratedPlannerPrompt -Template 'T {{schema}} | {{evi}} | {{Goal}}' -Goal 'costs $1 and $$'
    Check 'M1 hydration replaces Goal literally (no regex corruption)' ($hyd -match [regex]::Escape('costs $1 and $$'))
    Check 'M2 hydration removes all placeholders' (-not ($hyd -match '\{\{(schema|evi|Goal)\}\}'))

    $jp = Build-JudgePrompt -Run $mbRuns[0] -PlanA 'PLAN_A_TEXT' -PlanB 'PLAN_B_TEXT'
    Check 'M3 judge prompt carries goal, feedback, both plans, verdict tag' (
        ($jp -match 'Goal one') -and ($jp -match 'R1') -and ($jp -match 'PLAN_A_TEXT') -and
        ($jp -match 'PLAN_B_TEXT') -and ($jp -match '<verdict>')
    )

    # Plan dispatcher echoes its prompt so the judge stub can tell sides apart.
    $echoPlan = { param($p) @{ stdout = $p; exit_code = 0 } }

    # Judge stub: verdict goes to whichever side's plan contains CAND_MARK.
    $judgeCand = { param($p)
        $aIdx = $p.IndexOf('## Plan A'); $bIdx = $p.IndexOf('## Plan B')
        $aTxt = $p.Substring($aIdx, $bIdx - $aIdx)
        $v = if ($aTxt.Contains('CAND_MARK')) { 'A' } else { 'B' }
        @{ stdout = "<verdict>$v</verdict>"; exit_code = 0 }
    }
    $mb1 = Invoke-MinibatchEval -CandidatePrompt 'CAND_MARK {{schema}} {{evi}} {{Goal}}' `
        -ReferencePrompt 'REF {{schema}} {{evi}} {{Goal}}' -Runs $mbRuns `
        -PlanDispatcher $echoPlan -JudgeDispatcher $judgeCand
    Check 'M4 candidate-favoring judge -> win rate 1 across position swap' (
        ($mb1.wins -eq 2) -and ($mb1.losses -eq 0) -and (([double]$mb1.win_rate) -eq 1.0)
    )

    # Position-bias probe: a judge that ALWAYS answers A splits with the swap.
    $judgeAlwaysA = { param($p) @{ stdout = '<verdict>A</verdict>'; exit_code = 0 } }
    $mb2 = Invoke-MinibatchEval -CandidatePrompt 'CAND_MARK {{schema}} {{evi}} {{Goal}}' `
        -ReferencePrompt 'REF {{schema}} {{evi}} {{Goal}}' -Runs $mbRuns `
        -PlanDispatcher $echoPlan -JudgeDispatcher $judgeAlwaysA
    Check 'M5 position swap cancels an always-A judge (1 win, 1 loss)' (
        ($mb2.wins -eq 1) -and ($mb2.losses -eq 1) -and (([double]$mb2.win_rate) -eq 0.5)
    )

    $judgeTie = { param($p) @{ stdout = '<verdict>tie</verdict>'; exit_code = 0 } }
    $mb3 = Invoke-MinibatchEval -CandidatePrompt 'C {{schema}} {{evi}} {{Goal}}' `
        -ReferencePrompt 'R {{schema}} {{evi}} {{Goal}}' -Runs $mbRuns `
        -PlanDispatcher $echoPlan -JudgeDispatcher $judgeTie
    Check 'M6 all ties -> win_rate null, ties counted' (($null -eq $mb3.win_rate) -and ($mb3.ties -eq 2))

    $judgeGarbage = { param($p) @{ stdout = 'no tag here'; exit_code = 0 } }
    $mb4 = Invoke-MinibatchEval -CandidatePrompt 'C {{schema}} {{evi}} {{Goal}}' `
        -ReferencePrompt 'R {{schema}} {{evi}} {{Goal}}' -Runs $mbRuns `
        -PlanDispatcher $echoPlan -JudgeDispatcher $judgeGarbage
    Check 'M7 unparseable judge output -> examples dropped and counted' (($mb4.dropped -eq 2) -and ($null -eq $mb4.win_rate))

    $planFail = { param($p) @{ stdout = ''; exit_code = 1 } }
    $mb5 = Invoke-MinibatchEval -CandidatePrompt 'C {{schema}} {{evi}} {{Goal}}' `
        -ReferencePrompt 'R {{schema}} {{evi}} {{Goal}}' -Runs $mbRuns `
        -PlanDispatcher $planFail -JudgeDispatcher $judgeTie
    Check 'M8 failed plan generation -> example dropped' ($mb5.dropped -eq 2)
```

- [ ] **Step 2: Run the suite to verify the new checks fail**

Run: `pwsh -NoProfile -File scripts/test-optimize-prompt-lib.ps1`
Expected: hard error (`Build-HydratedPlannerPrompt` not defined) or FAILs on M1–M8; the pre-existing checks still PASS.

- [ ] **Step 3: Implement the evaluator**

In `scripts/optimize-prompt-lib.ps1`: add `. "$PSScriptRoot/prompt-pool-lib.ps1"` to the dot-source block at the top, then add below `Build-ReflectionPrompt`:

```powershell
# Offline-eval stand-in for the production plan schema. Both sides of every
# head-to-head are hydrated with the SAME text, so the judge's A/B comparison
# stays fair even though this is not byte-identical to conductor-lib's live
# schema (kept decoupled on purpose — sourcing conductor-lib here would drag
# in the whole run engine).
$script:MinibatchPlanSchema = @'
{
  "run_id": "<id>",
  "goal": "<the goal>",
  "tasks": [
    { "id": "<unique>", "desc": "<what>", "depends_on": [], "est_cost_tier": "local|free|paid", "reversible": true }
  ]
}
'@

function Build-HydratedPlannerPrompt {
    <# Literal [string]::Replace — never regex: goals are untrusted user text
       and '$1'/'$&' in a regex replacement would corrupt the prompt. #>
    param([Parameter(Mandatory)][string]$Template, [Parameter(Mandatory)][string]$Goal)
    $evi = 'Tools already wired locally: (none - offline evaluation)'
    return $Template.Replace('{{schema}}', $script:MinibatchPlanSchema).Replace('{{evi}}', $evi).Replace('{{Goal}}', $Goal)
}

function Build-JudgePrompt {
    param(
        [Parameter(Mandatory)][hashtable]$Run,
        [Parameter(Mandatory)][string]$PlanA,
        [Parameter(Mandatory)][string]$PlanB
    )
    $brief = if ($Run.polish_brief) { "Polish brief:`n$($Run.polish_brief)" } else { '' }
    return @"
You are judging two candidate task plans produced for the same goal by an autonomous software agent.
This goal previously FAILED its acceptance gate; the recorded feedback below tells you what a better plan must address.

## Goal
$($Run.goal)

## Acceptance-gate feedback from the failed run
Verdict: $($Run.verdict)
Reason: $($Run.reason)
Findings: $($Run.findings)
$brief

## Plan A
$PlanA

## Plan B
$PlanB

Which plan better addresses the recorded feedback (avoids the same failures, tighter scope, correct ordering)?
Answer with EXACTLY one of A, B, or tie inside a <verdict> tag, e.g. <verdict>A</verdict>. No other output.
"@
}

function Invoke-MinibatchEval {
    <# Head-to-head: candidate vs reference prompt over historical gated runs
       (plan-only generation — no execution). Position bias is cancelled by
       swapping which side is "A" per example. A judge reply without a
       parseable <verdict>, or a failed plan generation, drops the example
       (counted in `dropped`). win_rate = wins/(wins+losses), ties excluded;
       null when nothing scoreable (= "no evidence" upstream). #>
    param(
        [Parameter(Mandatory)][string]$CandidatePrompt,
        [Parameter(Mandatory)][string]$ReferencePrompt,
        [Parameter(Mandatory)][AllowEmptyCollection()][array]$Runs,
        [Parameter(Mandatory)][scriptblock]$PlanDispatcher,
        [Parameter(Mandatory)][scriptblock]$JudgeDispatcher
    )
    $wins = 0; $losses = 0; $ties = 0; $dropped = 0
    $examples = [System.Collections.ArrayList]@()
    $i = 0
    foreach ($run in @($Runs)) {
        $candIsA = (($i % 2) -eq 0)
        $i++
        $candRes = & $PlanDispatcher (Build-HydratedPlannerPrompt -Template $CandidatePrompt -Goal ([string]$run.goal))
        $refRes = & $PlanDispatcher (Build-HydratedPlannerPrompt -Template $ReferencePrompt -Goal ([string]$run.goal))
        if ((([int]$candRes.exit_code) -ne 0) -or (([int]$refRes.exit_code) -ne 0)) { $dropped++; continue }
        $planA = if ($candIsA) { [string]$candRes.stdout } else { [string]$refRes.stdout }
        $planB = if ($candIsA) { [string]$refRes.stdout } else { [string]$candRes.stdout }
        $judgeRes = & $JudgeDispatcher (Build-JudgePrompt -Run $run -PlanA $planA -PlanB $planB)
        $verdict = $null
        if ((([int]$judgeRes.exit_code) -eq 0) -and (([string]$judgeRes.stdout) -match '<verdict>\s*(A|B|tie)\s*</verdict>')) {
            $verdict = $Matches[1]
        }
        if ($null -eq $verdict) { $dropped++; continue }
        if ($verdict -eq 'tie') {
            $ties++
        } elseif ((($verdict -eq 'A') -and $candIsA) -or (($verdict -eq 'B') -and (-not $candIsA))) {
            $wins++
        } else {
            $losses++
        }
        [void]$examples.Add(@{
            run_id = [string]$run.run_id
            candidate_was = $(if ($candIsA) { 'A' } else { 'B' })
            verdict = $verdict
        })
    }
    $winRate = $null
    if (($wins + $losses) -gt 0) { $winRate = [math]::Round($wins / [double]($wins + $losses), 4) }
    return @{ wins = $wins; losses = $losses; ties = $ties; dropped = $dropped; win_rate = $winRate; examples = @($examples) }
}
```

- [ ] **Step 4: Run both suites to verify they pass**

Run: `pwsh -NoProfile -File scripts/test-optimize-prompt-lib.ps1; pwsh -NoProfile -File scripts/test-prompt-pool-lib.ps1`
Expected: all PASS, both exit 0.

- [ ] **Step 5: Commit**

```bash
git add scripts/optimize-prompt-lib.ps1 scripts/test-optimize-prompt-lib.ps1
git commit -m "feat(optimizer): minibatch evaluator — plan-only head-to-head with position-swapped judge"
```

---

### Task 3: Invoke-PromptEvolution — the generation loop (replaces Invoke-PromptOptimizer)

**Files:**
- Modify: `scripts/optimize-prompt-lib.ps1` — REMOVE `Build-ReflectionPrompt` and `Invoke-PromptOptimizer`; add `Build-DiagnosisPrompt`, `Build-MutationPrompt`, `Get-DefaultReflectTier`, `Invoke-TierRoutedModel`, `Invoke-PromptEvolution`.
- Modify: `scripts/test-optimize-prompt-lib.ps1` — REMOVE all checks that reference `Build-ReflectionPrompt` or `Invoke-PromptOptimizer` (keep the `Get-HistoricalRuns` O1–O5 checks and the Task-2 M-series); add the E-series below.

**Interfaces:**
- Consumes: everything from Tasks 1–2; `Get-HistoricalRuns`; `Select-Capability`/`Invoke-Fleet` (already dot-sourced).
- Produces (used by Task 4):
  - `Invoke-PromptEvolution(-MaxRuns -Generations -MaxCostTier -ReflectTier -LengthCapMultiplier -FleetPath -ToolsPath -PromptPath -PoolDir -Apply -ReflectDispatcher -MutateDispatcher -PlanDispatcher -JudgeDispatcher -Draw)` → `@{ success; applied; candidate_path; reason; generations }` where `generations` is an array of `@{ generation; parent; child; pass; reasons; win_rate_vs_champion; win_rate_vs_parent }` (child/rates `$null` when the generation failed before evaluation).

- [ ] **Step 1: Rewrite the affected tests (failing first)**

In `scripts/test-optimize-prompt-lib.ps1`:

1. DELETE the `Build-ReflectionPrompt` checks (O6–O8) and every `Invoke-PromptOptimizer` check (the stubbed-dispatcher block from the comment `---- Invoke-PromptOptimizer: stubbed dispatcher...` to the last check before the M-series). Keep O1–O5 and the M-series.
2. APPEND inside the `try` block, after the M-series:

```powershell
    # ==== E-series: Invoke-PromptEvolution ====
    # Shared hermetic fixture: temp BATON_HOME with one polish run + live prompt.
    function New-EvoFixture {
        $root = New-TempDir
        $runsRoot = Join-Path $root 'runs'
        $runDir = Join-Path $runsRoot 'go-1'
        New-Item -ItemType Directory -Force -Path $runDir | Out-Null
        @{ goal = 'G1'; tasks = @() } | ConvertTo-Json | Set-Content (Join-Path $runDir 'plan.json')
        @{ verdict = 'polish'; reason = 'R1'; counts = @{ important = 1 }; polish_brief = 'P1' } |
            ConvertTo-Json | Set-Content (Join-Path $runDir 'acceptance.json')
        $promptDir = Join-Path $root 'prompts'
        New-Item -ItemType Directory -Force -Path $promptDir | Out-Null
        $livePath = Join-Path $promptDir 'conductor-planner.txt'
        Set-Content -LiteralPath $livePath -Value 'LIVE {{schema}} {{evi}} {{Goal}}' -Encoding utf8NoBOM
        return @{ root = $root; live = $livePath; pool = (Join-Path $promptDir 'pool') }
    }
    $okReflect = { param($p) @{ stdout = '<diagnosis>too vague about ordering</diagnosis>'; exit_code = 0 } }
    $okMutate = { param($p) @{ stdout = '<new_prompt>BETTER v2 {{schema}} {{evi}} {{Goal}}</new_prompt>'; exit_code = 0 } }
    $echoPlan2 = { param($p) @{ stdout = $p; exit_code = 0 } }
    $judgeBetter = { param($p)
        $aIdx = $p.IndexOf('## Plan A'); $bIdx = $p.IndexOf('## Plan B')
        $v = if ($p.Substring($aIdx, $bIdx - $aIdx).Contains('BETTER')) { 'A' } else { 'B' }
        @{ stdout = "<verdict>$v</verdict>"; exit_code = 0 }
    }

    # E1+E2: first run seeds the pool, survivor proposed, live untouched (v1 regression).
    $fx1 = New-EvoFixture
    $env:BATON_HOME = $fx1.root
    $ev1 = Invoke-PromptEvolution -PromptPath $fx1.live -PoolDir $fx1.pool `
        -ReflectDispatcher $okReflect -MutateDispatcher $okMutate `
        -PlanDispatcher $echoPlan2 -JudgeDispatcher $judgeBetter -Draw { param($t) 0.0 }
    Check 'E1 first evolution seeds the pool (p001 champion)' ((Get-PromptPool -PoolDir $fx1.pool).pool.champion -eq 'p001')
    Check 'E2 survivor: success, candidate file written, live prompt untouched' (
        $ev1.success -and (-not $ev1.applied) -and (Test-Path $ev1.candidate_path) -and
        ((Get-Content -Raw $fx1.live) -match '^LIVE')
    )
    $pool1 = (Get-PromptPool -PoolDir $fx1.pool).pool
    $p002 = @($pool1.candidates | Where-Object { $_.id -eq 'p002' })[0]
    Check 'E3 child recorded as candidate with parent p001 and scores' (
        ($p002.status -eq 'candidate') -and ($p002.parent -eq 'p001') -and
        (([double]$p002.offline.minibatch.win_rate_vs_champion) -eq 1.0)
    )
    Check 'E4 child text file written to pool' ((Get-Content -Raw (Join-Path $fx1.pool 'p002.txt')) -match '^BETTER v2')
    Check 'E5 generation record present' ((@($ev1.generations).Count -eq 1) -and (@($ev1.generations)[0].pass))

    # E6: placeholder-dropping mutation -> retired, no proposal.
    $fx2 = New-EvoFixture
    $env:BATON_HOME = $fx2.root
    $badMutate = { param($p) @{ stdout = '<new_prompt>DROPPED THE PLACEHOLDERS</new_prompt>'; exit_code = 0 } }
    $ev2 = Invoke-PromptEvolution -PromptPath $fx2.live -PoolDir $fx2.pool `
        -ReflectDispatcher $okReflect -MutateDispatcher $badMutate `
        -PlanDispatcher $echoPlan2 -JudgeDispatcher $judgeBetter -Draw { param($t) 0.0 }
    $pool2 = (Get-PromptPool -PoolDir $fx2.pool).pool
    $ret2 = @($pool2.candidates | Where-Object { $_.status -eq 'retired' })
    Check 'E6 placeholder drop -> retired with reason, run reports no survivor' (
        (-not $ev2.success) -and (@($ret2).Count -eq 1) -and ($ret2[0].retired_reason -match 'placeholder')
    )

    # E7: length cap (seed ~8 tokens; 2x cap; give a huge mutation).
    $fx3 = New-EvoFixture
    $env:BATON_HOME = $fx3.root
    $longBody = ('x' * 400)
    $longMutate = { param($p) @{ stdout = "<new_prompt>$longBody {{schema}} {{evi}} {{Goal}}</new_prompt>"; exit_code = 0 } }.GetNewClosure()
    $ev3 = Invoke-PromptEvolution -PromptPath $fx3.live -PoolDir $fx3.pool `
        -ReflectDispatcher $okReflect -MutateDispatcher $longMutate `
        -PlanDispatcher $echoPlan2 -JudgeDispatcher $judgeBetter -Draw { param($t) 0.0 }
    $ret3 = @((Get-PromptPool -PoolDir $fx3.pool).pool.candidates | Where-Object { $_.status -eq 'retired' })
    Check 'E7 length cap -> retired with length reason' (
        (-not $ev3.success) -and (@($ret3).Count -eq 1) -and ($ret3[0].retired_reason -match 'length cap')
    )

    # E8: all-ties judge -> gate fail (no evidence).
    $fx4 = New-EvoFixture
    $env:BATON_HOME = $fx4.root
    $judgeTie2 = { param($p) @{ stdout = '<verdict>tie</verdict>'; exit_code = 0 } }
    $ev4 = Invoke-PromptEvolution -PromptPath $fx4.live -PoolDir $fx4.pool `
        -ReflectDispatcher $okReflect -MutateDispatcher $okMutate `
        -PlanDispatcher $echoPlan2 -JudgeDispatcher $judgeTie2 -Draw { param($t) 0.0 }
    Check 'E8 all ties -> no survivor, no-evidence reason recorded' (
        (-not $ev4.success) -and ((@(@($ev4.generations)[0].reasons) -join ';') -match 'no evidence')
    )

    # E9: -Apply promotes the survivor (champion swap + backup + stale-marking).
    $fx5 = New-EvoFixture
    $env:BATON_HOME = $fx5.root
    $ev5 = Invoke-PromptEvolution -PromptPath $fx5.live -PoolDir $fx5.pool -Apply `
        -ReflectDispatcher $okReflect -MutateDispatcher $okMutate `
        -PlanDispatcher $echoPlan2 -JudgeDispatcher $judgeBetter -Draw { param($t) 0.0 }
    $pool5 = (Get-PromptPool -PoolDir $fx5.pool).pool
    $old5 = @($pool5.candidates | Where-Object { $_.id -eq 'p001' })[0]
    $new5 = @($pool5.candidates | Where-Object { $_.id -eq 'p002' })[0]
    Check 'E9a apply: live prompt overwritten with survivor text' ((Get-Content -Raw $fx5.live) -match '^BETTER v2')
    Check 'E9b apply: timestamped backup of previous live prompt exists' (@(Get-ChildItem "$($fx5.live).bak-*").Count -eq 1)
    Check 'E9c apply: champion swapped, old champion retired as superseded' (
        ($pool5.champion -eq 'p002') -and ($new5.status -eq 'champion') -and
        ($old5.status -eq 'retired') -and ($old5.retired_reason -eq 'superseded')
    )
    Check 'E9d apply: new champion re-baselined to 0.5' (([double]$new5.offline.minibatch.win_rate_vs_champion) -eq 0.5)

    # E10: corrupt pool manifest -> refuse to run.
    $fx6 = New-EvoFixture
    $env:BATON_HOME = $fx6.root
    New-Item -ItemType Directory -Force -Path $fx6.pool | Out-Null
    Set-Content -LiteralPath (Join-Path $fx6.pool 'pool.json') -Value '{ broken' -Encoding utf8NoBOM
    $ev6 = Invoke-PromptEvolution -PromptPath $fx6.live -PoolDir $fx6.pool `
        -ReflectDispatcher $okReflect -MutateDispatcher $okMutate `
        -PlanDispatcher $echoPlan2 -JudgeDispatcher $judgeBetter -Draw { param($t) 0.0 }
    Check 'E10 corrupt pool -> refuses, manifest untouched' (
        (-not $ev6.success) -and ($ev6.reason -match 'corrupt') -and
        ((Get-Content -Raw (Join-Path $fx6.pool 'pool.json')) -match 'broken')
    )

    # E11: no gated runs -> honest no-op.
    $fx7 = New-EvoFixture
    Remove-Item -Recurse -Force (Join-Path $fx7.root 'runs')
    $env:BATON_HOME = $fx7.root
    $ev7 = Invoke-PromptEvolution -PromptPath $fx7.live -PoolDir $fx7.pool `
        -ReflectDispatcher $okReflect -MutateDispatcher $okMutate `
        -PlanDispatcher $echoPlan2 -JudgeDispatcher $judgeBetter -Draw { param($t) 0.0 }
    Check 'E11 no gated runs -> no-op with honest reason' ((-not $ev7.success) -and ($ev7.reason -match 'no historical runs'))

    # E12: reflection failure -> generation fail-open, pool not grown.
    $fx8 = New-EvoFixture
    $env:BATON_HOME = $fx8.root
    $failReflect = { param($p) @{ stdout = ''; exit_code = 1 } }
    $ev8 = Invoke-PromptEvolution -PromptPath $fx8.live -PoolDir $fx8.pool `
        -ReflectDispatcher $failReflect -MutateDispatcher $okMutate `
        -PlanDispatcher $echoPlan2 -JudgeDispatcher $judgeBetter -Draw { param($t) 0.0 }
    Check 'E12 reflection failure -> fail-open, only the seed in the pool' (
        (-not $ev8.success) -and (@((Get-PromptPool -PoolDir $fx8.pool).pool.candidates).Count -eq 1)
    )

    # E13: builders carry their contracts.
    $dg = Build-DiagnosisPrompt -HistoricalRuns @(@{ run_id = 'go-1'; goal = 'G'; plan_tasks = '[]'; verdict = 'reject'; reason = 'R'; findings = '{}'; polish_brief = 'P' }) `
        -ParentPrompt 'PARENT_TEXT' -PriorFates @('p009 retired: length cap')
    Check 'E13a diagnosis prompt: history + parent + prior fates + <diagnosis> tag' (
        ($dg -match 'go-1') -and ($dg -match 'PARENT_TEXT') -and ($dg -match 'p009 retired') -and ($dg -match '<diagnosis>')
    )
    $mt = Build-MutationPrompt -Diagnosis 'DIAG_TEXT' -ParentPrompt 'PARENT_TEXT'
    Check 'E13b mutation prompt: diagnosis + parent + placeholder-keep + <new_prompt> tag' (
        ($mt -match 'DIAG_TEXT') -and ($mt -match 'PARENT_TEXT') -and ($mt -match '\{\{schema\}\}') -and ($mt -match '<new_prompt>')
    )
```

- [ ] **Step 2: Run the suite to verify the E-series fails**

Run: `pwsh -NoProfile -File scripts/test-optimize-prompt-lib.ps1`
Expected: hard error (`Invoke-PromptEvolution` not defined); O/M checks unaffected.

- [ ] **Step 3: Implement the evolution loop**

In `scripts/optimize-prompt-lib.ps1`: DELETE `Build-ReflectionPrompt` and `Invoke-PromptOptimizer` entirely, then add:

```powershell
function Build-DiagnosisPrompt {
    <# Reflection half of the two-model split: the cheap-side model diagnoses
       WHY the parent prompt produced gate-failing plans. Consumes the gate's
       findings/polish briefs (the ASI channel) plus the fates of prior
       candidates so the loop does not repeat dead mutations. #>
    param(
        [Parameter(Mandatory)][array]$HistoricalRuns,
        [Parameter(Mandatory)][string]$ParentPrompt,
        [array]$PriorFates = @()
    )
    $historyStr = ""
    foreach ($r in $HistoricalRuns) {
        $historyStr += "--- RUN: $($r.run_id) ---`n"
        $historyStr += "Goal: $($r.goal)`n"
        $historyStr += "Generated Plan (Tasks): $($r.plan_tasks)`n"
        $historyStr += "Acceptance Verdict: $($r.verdict)`n"
        $historyStr += "Reason: $($r.reason)`n"
        $historyStr += "Findings: $($r.findings)`n"
        if ($r.polish_brief) { $historyStr += "Polish Brief:`n$($r.polish_brief)`n" }
        $historyStr += "`n"
    }
    $fatesStr = if (@($PriorFates).Count -gt 0) {
        "Earlier mutation attempts and why they were retired (do not repeat these mistakes):`n" +
        ((@($PriorFates) | ForEach-Object { "- $_" }) -join "`n")
    } else { '(no earlier mutation attempts)' }
    return @"
You are the reflection stage of a prompt-optimization loop (GEPA) for an autonomous software agent.
The prompt under study is the "Conductor Planner Prompt", which decomposes a GOAL into an ordered task DAG.

Below are recent runs where plans produced by this prompt failed or required polish, with the acceptance-gate feedback.
$historyStr
$fatesStr

CURRENT PROMPT UNDER STUDY:
<current_prompt>
$ParentPrompt
</current_prompt>

Diagnose, in plain language, WHY this prompt produced plans that drew this feedback: which instructions are missing,
ambiguous, or misprioritized. Do NOT write a new prompt. Output your diagnosis inside a <diagnosis> XML block.
"@
}

function Build-MutationPrompt {
    <# Mutation half: the stronger model rewrites the prompt from the
       diagnosis. Placeholder preservation is instructed here AND enforced
       mechanically by the caller. #>
    param([Parameter(Mandatory)][string]$Diagnosis, [Parameter(Mandatory)][string]$ParentPrompt)
    return @"
You are the mutation stage of a prompt-optimization loop (GEPA) for an autonomous software agent.
A reflection model diagnosed the weaknesses of the current "Conductor Planner Prompt":

<diagnosis>
$Diagnosis
</diagnosis>

CURRENT PROMPT:
<current_prompt>
$ParentPrompt
</current_prompt>

Rewrite the prompt to fix the diagnosed weaknesses. Requirements:
1. KEEP the placeholders {{schema}}, {{evi}}, and {{Goal}} exactly as they are.
2. Keep it concise — do not pad; every added instruction must earn its tokens.
3. Output the complete new prompt inside a <new_prompt> XML block, and nothing else that could be confused with it.
"@
}

function Get-DefaultReflectTier {
    <# Reflection defaults one tier below mutation (spec). #>
    param([Parameter(Mandatory)][string]$MaxCostTier)
    switch ($MaxCostTier) {
        'paid' { return 'free' }
        'free' { return 'local' }
        default { return 'local' }
    }
}

function Invoke-TierRoutedModel {
    <# Default (non-seamed) dispatch: cheapest reasoning-capable worker within
       the tier, via the existing fleet routing. Same result contract as the
       dispatcher seams: @{ stdout; exit_code }. #>
    param(
        [Parameter(Mandatory)][ValidateSet('local','free','paid')][string]$Tier,
        [Parameter(Mandatory)][string]$Prompt,
        [Parameter(Mandatory)][string]$FleetPath,
        [Parameter(Mandatory)][string]$ToolsPath
    )
    $cands = Select-Capability -Capability reasoning -MaxCostTier $Tier -FleetPath $FleetPath -ToolsPath $ToolsPath
    if (($null -eq $cands) -or (@($cands | Where-Object { $null -ne $_ }).Count -lt 1)) {
        return @{ stdout = ''; exit_code = 1 }
    }
    return (Invoke-Fleet -Name @($cands)[0].name -Prompt $Prompt -Path $FleetPath -NoJournal)
}

function Invoke-PromptEvolution {
    <#
    .SYNOPSIS
      One or more GEPA generations: select -> reflect -> mutate -> evaluate ->
      dual gate. Replaces the v1 single-shot Invoke-PromptOptimizer
      (-Generations 1 on an empty pool reproduces its observable behavior).
    .DESCRIPTION
      Default: gate survivors are recorded in the pool as 'candidate' and the
      latest survivor is written to conductor-planner.candidate.txt for human
      review — the live prompt is never touched. -Apply: promotes the latest
      survivor (timestamped .bak of the live prompt, champion swap in the
      pool, other actives marked stale for re-evaluation). Every model call
      fail-opens to "no proposal this generation" with an honest reason; the
      manifest is saved once per generation, never mid-flight.
    .NOTES
      Returns @{ success; applied; candidate_path; reason; generations }.
      Seams: -ReflectDispatcher/-MutateDispatcher/-PlanDispatcher/
      -JudgeDispatcher (contract: param($prompt) -> @{ stdout; exit_code }),
      -Draw (parent-selection randomness).
    #>
    param(
        [int]$MaxRuns = 5,
        [int]$Generations = 1,
        [ValidateSet('local','free','paid')][string]$MaxCostTier = 'paid',
        [ValidateSet('local','free','paid')][string]$ReflectTier,
        [double]$LengthCapMultiplier = 2.0,
        [string]$FleetPath = (Join-Path (Get-BatonHome) 'fleet.yaml'),
        [string]$ToolsPath = (Join-Path (Get-BatonHome) 'tools.yaml'),
        [string]$PromptPath = $(
            $p = Join-Path $PSScriptRoot '../prompts/conductor-planner.txt'
            if (Test-Path $p) { $p } else { Join-Path (Get-BatonHome) 'prompts/conductor-planner.txt' }
        ),
        [string]$PoolDir = (Get-PromptPoolDir),
        [switch]$Apply,
        [scriptblock]$ReflectDispatcher,
        [scriptblock]$MutateDispatcher,
        [scriptblock]$PlanDispatcher,
        [scriptblock]$JudgeDispatcher,
        [scriptblock]$Draw
    )
    if (-not $ReflectTier) { $ReflectTier = Get-DefaultReflectTier -MaxCostTier $MaxCostTier }
    $requiredPlaceholders = @('{{schema}}', '{{evi}}', '{{Goal}}')
    $fail = { param($reason, $gens)
        @{ success = $false; applied = $false; candidate_path = $null; reason = $reason; generations = @($gens) }
    }

    # -- pool: load, seed if absent, refuse if corrupt --
    $loaded = Get-PromptPool -PoolDir $PoolDir
    if (-not $loaded.ok) {
        if ($loaded.reason -eq 'absent') {
            $loaded = Initialize-PromptPool -SeedPromptPath $PromptPath -PoolDir $PoolDir
            if (-not $loaded.ok) {
                [Console]::Error.WriteLine("optimize-prompt: $($loaded.reason)")
                return (& $fail $loaded.reason @())
            }
            Write-Host "Pool seeded from live prompt ($PromptPath) as p001/champion."
        } else {
            [Console]::Error.WriteLine("optimize-prompt: $($loaded.reason) — refusing to run.")
            return (& $fail $loaded.reason @())
        }
    }
    $pool = $loaded.pool

    $runs = Get-HistoricalRuns -MaxRuns $MaxRuns
    if (@($runs).Count -eq 0) {
        Write-Host "No historical runs requiring polish or reject found."
        return (& $fail 'no historical runs requiring polish or reject' @())
    }

    # Default live dispatchers (any seam overrides its stage).
    if (-not $ReflectDispatcher) { $ReflectDispatcher = { param($p) Invoke-TierRoutedModel -Tier $ReflectTier -Prompt $p -FleetPath $FleetPath -ToolsPath $ToolsPath }.GetNewClosure() }
    if (-not $MutateDispatcher) { $MutateDispatcher = { param($p) Invoke-TierRoutedModel -Tier $MaxCostTier -Prompt $p -FleetPath $FleetPath -ToolsPath $ToolsPath }.GetNewClosure() }
    if (-not $PlanDispatcher) { $PlanDispatcher = { param($p) Invoke-TierRoutedModel -Tier $MaxCostTier -Prompt $p -FleetPath $FleetPath -ToolsPath $ToolsPath }.GetNewClosure() }
    if (-not $JudgeDispatcher) { $JudgeDispatcher = { param($p) Invoke-TierRoutedModel -Tier $MaxCostTier -Prompt $p -FleetPath $FleetPath -ToolsPath $ToolsPath }.GetNewClosure() }

    $seedRec = @($pool.candidates | Where-Object { $_.origin -eq 'seed' })
    $seedTokens = if (@($seedRec).Count -gt 0) { [int]$seedRec[0].offline.prompt_tokens }
                  else { [int]@($pool.candidates | Where-Object { $_.id -eq $pool.champion })[0].offline.prompt_tokens }
    $lengthCap = [int][math]::Ceiling($LengthCapMultiplier * $seedTokens)

    $lastSurvivor = $null
    $genRecords = [System.Collections.ArrayList]@()
    for ($g = 1; $g -le $Generations; $g++) {
        $genRec = @{ generation = $g; parent = $null; child = $null; pass = $false; reasons = @(); win_rate_vs_champion = $null; win_rate_vs_parent = $null }
        [void]$genRecords.Add($genRec)

        $selectParams = @{ Pool = $pool }
        if ($Draw) { $selectParams.Draw = $Draw }
        $parent = Select-ParentCandidate @selectParams
        $parent.offline.times_selected = ([int]$parent.offline.times_selected) + 1
        $genRec.parent = [string]$parent.id
        $parentText = Get-Content -Raw (Join-Path $PoolDir ([string]$parent.file))
        Write-Host "Generation ${g}: parent $($parent.id) selected."

        $fates = @($pool.candidates | Where-Object { $_.status -eq 'retired' } |
            ForEach-Object { "$($_.id) retired: $($_.retired_reason)" })

        # -- reflect --
        $diagRes = & $ReflectDispatcher (Build-DiagnosisPrompt -HistoricalRuns @($runs) -ParentPrompt $parentText -PriorFates $fates)
        $diag = $null
        if ((([int]$diagRes.exit_code) -eq 0) -and (([string]$diagRes.stdout) -match '(?s)<diagnosis>(.*?)</diagnosis>')) {
            $diag = $Matches[1].Trim()
        }
        if ([string]::IsNullOrWhiteSpace($diag)) {
            $genRec.reasons = @('reflection failed (no <diagnosis> block)')
            [Console]::Error.WriteLine("optimize-prompt: generation ${g}: reflection failed — no proposal this generation.")
            Save-PromptPool -Pool $pool -PoolDir $PoolDir
            continue
        }

        # -- mutate --
        $mutRes = & $MutateDispatcher (Build-MutationPrompt -Diagnosis $diag -ParentPrompt $parentText)
        $childText = $null
        if (([int]$mutRes.exit_code) -eq 0) {
            $raw = [string]$mutRes.stdout
            $open = $raw.IndexOf('<new_prompt>')
            $close = $raw.LastIndexOf('</new_prompt>')
            if (($open -ge 0) -and ($close -gt $open)) {
                $childText = $raw.Substring($open + '<new_prompt>'.Length, $close - $open - '<new_prompt>'.Length).Trim()
            }
        }
        if ([string]::IsNullOrWhiteSpace($childText)) {
            $genRec.reasons = @('mutation failed (no <new_prompt> block)')
            [Console]::Error.WriteLine("optimize-prompt: generation ${g}: mutation failed — no proposal this generation.")
            Save-PromptPool -Pool $pool -PoolDir $PoolDir
            continue
        }

        # -- mechanical rejection: placeholders + length cap (recorded as retired) --
        $childId = Get-NextCandidateId -Pool $pool
        $childTokens = Get-PromptTokenEstimate -Text $childText
        $missing = @($requiredPlaceholders | Where-Object { -not $childText.Contains($_) })
        $mechReason = $null
        if (@($missing).Count -gt 0) { $mechReason = "mutation missing placeholder(s): $($missing -join ', ')" }
        elseif ($childTokens -gt $lengthCap) { $mechReason = "length cap exceeded ($childTokens tokens > cap $lengthCap = ${LengthCapMultiplier}x seed $seedTokens)" }
        if ($mechReason) {
            $child = New-PoolCandidateRecord -Id $childId -Parent ([string]$parent.id) -Origin 'mutation' -Status 'retired' -PromptTokens $childTokens
            $child.retired_reason = $mechReason
            Set-Content -LiteralPath (Join-Path $PoolDir "$childId.txt") -Value $childText -Encoding utf8NoBOM
            $pool.candidates = @($pool.candidates) + @($child)
            $genRec.child = $childId
            $genRec.reasons = @($mechReason)
            [Console]::Error.WriteLine("optimize-prompt: generation ${g}: $mechReason")
            Save-PromptPool -Pool $pool -PoolDir $PoolDir
            continue
        }

        # -- evaluate (minibatch): always vs champion; vs parent too when distinct --
        $championRec = @($pool.candidates | Where-Object { $_.id -eq $pool.champion })[0]
        $championText = Get-Content -Raw (Join-Path $PoolDir ([string]$championRec.file))
        $mbChampion = Invoke-MinibatchEval -CandidatePrompt $childText -ReferencePrompt $championText `
            -Runs @($runs) -PlanDispatcher $PlanDispatcher -JudgeDispatcher $JudgeDispatcher
        $wrVsParent = if ($parent.id -eq $pool.champion) { $mbChampion.win_rate }
        else {
            (Invoke-MinibatchEval -CandidatePrompt $childText -ReferencePrompt $parentText `
                -Runs @($runs) -PlanDispatcher $PlanDispatcher -JudgeDispatcher $JudgeDispatcher).win_rate
        }
        $genRec.win_rate_vs_champion = $mbChampion.win_rate
        $genRec.win_rate_vs_parent = $wrVsParent

        # -- record child + dual gate --
        $child = New-PoolCandidateRecord -Id $childId -Parent ([string]$parent.id) -Origin 'mutation' -Status 'candidate' -PromptTokens $childTokens
        $child.offline.minibatch = @{
            wins = $mbChampion.wins; losses = $mbChampion.losses; ties = $mbChampion.ties
            win_rate_vs_champion = $mbChampion.win_rate; examples = @($mbChampion.examples)
        }
        $gate = Test-DualGate -Child $child -WinRateVsParent $wrVsParent -Pool $pool
        Set-Content -LiteralPath (Join-Path $PoolDir "$childId.txt") -Value $childText -Encoding utf8NoBOM
        $genRec.child = $childId
        $genRec.pass = $gate.pass
        $genRec.reasons = @($gate.reasons)
        if ($gate.pass) {
            $lastSurvivor = $child
            Write-Host "Generation ${g}: $childId SURVIVED the dual gate (vs champion: $($mbChampion.win_rate), vs parent: $wrVsParent)."
        } else {
            $child.status = 'retired'
            $child.retired_reason = (@($gate.reasons) -join '; ')
            Write-Host "Generation ${g}: $childId retired — $($child.retired_reason)."
        }
        $pool.candidates = @($pool.candidates) + @($child)
        Save-PromptPool -Pool $pool -PoolDir $PoolDir
    }

    if ($null -eq $lastSurvivor) {
        return (& $fail 'no candidate survived the dual gate' $genRecords)
    }
    $survivorText = Get-Content -Raw (Join-Path $PoolDir ([string]$lastSurvivor.file))

    if ($Apply) {
        $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
        $backupPath = "$PromptPath.bak-$stamp"
        if (Test-Path $PromptPath) { Copy-Item -LiteralPath $PromptPath -Destination $backupPath -Force }
        Set-Content -LiteralPath $PromptPath -Value $survivorText -Encoding utf8NoBOM
        foreach ($c in @($pool.candidates)) {
            if ($c.id -eq $pool.champion) { $c.status = 'retired'; $c.retired_reason = 'superseded' }
            elseif (($c.status -eq 'candidate') -and ($c.id -ne $lastSurvivor.id)) {
                # Scores were measured against the OLD champion: mark stale
                # (excluded from the Pareto front until re-evaluated).
                $c.offline.minibatch.win_rate_vs_champion = $null
            }
        }
        $lastSurvivor.status = 'champion'
        $lastSurvivor.offline.minibatch.win_rate_vs_champion = 0.5
        $pool.champion = [string]$lastSurvivor.id
        Save-PromptPool -Pool $pool -PoolDir $PoolDir
        Write-Host "Applied: $($lastSurvivor.id) promoted to champion; live prompt deployed to $PromptPath (backup: $backupPath)."
        return @{ success = $true; applied = $true; candidate_path = $null; reason = "applied $($lastSurvivor.id) to live prompt"; generations = @($genRecords) }
    }

    $candidatePath = Join-Path (Split-Path -Parent $PromptPath) 'conductor-planner.candidate.txt'
    Set-Content -LiteralPath $candidatePath -Value $survivorText -Encoding utf8NoBOM
    Write-Host "Proposed candidate $($lastSurvivor.id) written to $candidatePath for review. Live prompt untouched."
    return @{ success = $true; applied = $false; candidate_path = $candidatePath; reason = "candidate $($lastSurvivor.id) proposed for review"; generations = @($genRecords) }
}
```

- [ ] **Step 4: Run both suites to verify everything passes**

Run: `pwsh -NoProfile -File scripts/test-optimize-prompt-lib.ps1; pwsh -NoProfile -File scripts/test-prompt-pool-lib.ps1`
Expected: all PASS (O1–O5, M-series, E-series), both exit 0.

- [ ] **Step 5: Commit**

```bash
git add scripts/optimize-prompt-lib.ps1 scripts/test-optimize-prompt-lib.ps1
git commit -m "feat(optimizer): Invoke-PromptEvolution — GEPA generation loop with two-model split and dual gate"
```

---

### Task 4: CLI — -Generations, -ReflectTier, -Pool

**Files:**
- Modify: `scripts/fleet-optimize-prompt.ps1` (full replacement below)

**Interfaces:**
- Consumes: `Invoke-PromptEvolution`, `Get-PromptPool` (Tasks 1/3 signatures).
- Produces: the `/baton:optimize-prompt` shell surface documented in Task 5.

- [ ] **Step 1: Replace the CLI**

Replace the entire content of `scripts/fleet-optimize-prompt.ps1` with:

```powershell
#!/usr/bin/env pwsh
<#
.SYNOPSIS
  /baton:optimize-prompt runner. GEPA evolution over the Conductor's planner
  prompt: candidate pool + two-model reflect/mutate + minibatch judge + dual
  acceptance gate.
.DESCRIPTION
  Default run PROPOSES a gate-surviving candidate for human review; nothing
  is deployed. -Apply promotes the survivor to champion (timestamped backup
  kept). -Pool prints the candidate-pool report instead of evolving.
#>
param(
    [ValidateSet('local','free','paid')][string]$MaxCostTier = 'paid',
    [ValidateSet('local','free','paid')][string]$ReflectTier,
    [int]$MaxRuns = 5,
    [int]$Generations = 1,
    [switch]$Apply,
    [switch]$Pool,
    [switch]$Json
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'optimize-prompt-lib.ps1')

if ($Pool) {
    $loaded = Get-PromptPool
    if (-not $loaded.ok) {
        [Console]::Error.WriteLine("Pool unavailable: $($loaded.reason)")
        exit 2
    }
    if ($Json) { ConvertTo-Json -InputObject $loaded.pool -Depth 10; exit 0 }
    Write-Host "`n## Prompt candidate pool (champion: $($loaded.pool.champion))`n"
    $fmt = "{0,-6} {1,-9} {2,-9} {3,-7} {4,7} {5,7} {6,5} {7,10}"
    Write-Host ($fmt -f 'id', 'status', 'origin', 'parent', 'tokens', 'wr_ch', 'sel', 'live_runs')
    foreach ($c in @($loaded.pool.candidates)) {
        $wr = if ($null -ne $c.offline.minibatch.win_rate_vs_champion) { ('{0:n2}' -f [double]$c.offline.minibatch.win_rate_vs_champion) } else { '-' }
        $par = if ($c.parent) { [string]$c.parent } else { '-' }
        Write-Host ($fmt -f $c.id, $c.status, $c.origin, $par, $c.offline.prompt_tokens, $wr, $c.offline.times_selected, $c.live.runs)
        if (($c.status -eq 'retired') -and $c.retired_reason) { Write-Host ("       retired: " + $c.retired_reason) }
    }
    exit 0
}

$evoParams = @{ MaxRuns = $MaxRuns; Generations = $Generations; MaxCostTier = $MaxCostTier; Apply = $Apply }
if ($ReflectTier) { $evoParams.ReflectTier = $ReflectTier }
$res = Invoke-PromptEvolution @evoParams

if ($Json) {
    ConvertTo-Json -InputObject $res -Depth 10
    if (-not $res.success) { exit 2 }
} else {
    foreach ($g in @($res.generations)) {
        $status = if ($g.pass) { 'SURVIVED' } else { "retired: $((@($g.reasons)) -join '; ')" }
        Write-Host ("generation {0}: parent {1} -> child {2} — {3}" -f $g.generation, $g.parent, ($g.child ?? '-'), $status)
    }
    if ($res.success) {
        if ($res.applied) {
            Write-Host "`n## Prompt Evolution Applied`n"
            Write-Host $res.reason
            Write-Host "The previous live prompt was backed up alongside it; see -Pool for the champion swap."
        } else {
            Write-Host "`n## Prompt Evolution Proposed`n"
            Write-Host "$($res.reason): $($res.candidate_path)"
            Write-Host "Re-run with -Apply to promote it to champion and deploy."
        }
    } else {
        [Console]::Error.WriteLine("Prompt evolution produced no deployable candidate: $($res.reason)")
        exit 2
    }
}
```

- [ ] **Step 2: Smoke the CLI paths hermetically**

Run (PowerShell; single command, temp BATON_HOME so the real box state is never touched):

```powershell
$env:BATON_HOME = Join-Path ([System.IO.Path]::GetTempPath()) ("cli-smoke-" + [guid]::NewGuid().ToString('N')); pwsh -NoProfile -File scripts/fleet-optimize-prompt.ps1 -Pool; "pool-exit=$LASTEXITCODE"; pwsh -NoProfile -File scripts/fleet-optimize-prompt.ps1; "evo-exit=$LASTEXITCODE"; Remove-Item Env:BATON_HOME
```

Expected: `-Pool` prints `Pool unavailable: absent` and `pool-exit=2`; the evolution run either seeds-then-reports `no historical runs requiring polish or reject` with `evo-exit=2` (empty temp home has no runs) — both exits honest, no crash, and nothing written outside the temp dir.

- [ ] **Step 3: Run all suites**

Run: `pwsh -NoProfile -File scripts/test-optimize-prompt-lib.ps1; pwsh -NoProfile -File scripts/test-prompt-pool-lib.ps1`
Expected: all PASS.

- [ ] **Step 4: Commit**

```bash
git add scripts/fleet-optimize-prompt.ps1
git commit -m "feat(optimizer): CLI — -Generations, -ReflectTier, -Pool report"
```

---

### Task 5: Bootstrap wiring, docs, version bump

**Files:**
- Modify: `scripts/bootstrap.ps1:259` (deploy array)
- Modify: `scripts/test-bootstrap.ps1:62-63` (neighboring assertions)
- Modify: `commands/optimize-prompt.md` (full replacement below)
- Modify: `docs/COMMANDS.md` (cheat-sheet row + entry body)
- Modify: `.claude-plugin/plugin.json:4` (version)

- [ ] **Step 1: Add the failing bootstrap assertion**

In `scripts/test-bootstrap.ps1`, immediately after the line
`Assert "would deploy optimize-prompt-lib.ps1"  ($out -match 'optimize-prompt-lib\.ps1')` add:

```powershell
Assert "would deploy prompt-pool-lib.ps1"       ($out -match 'prompt-pool-lib\.ps1')
```

Run: `pwsh -NoProfile -File scripts/test-bootstrap.ps1`
Expected: FAIL on the new assertion only.

- [ ] **Step 2: Wire the deploy array**

In `scripts/bootstrap.ps1` line 259, in the `foreach ($script in @(...))` array, insert `'prompt-pool-lib.ps1', ` immediately before `'optimize-prompt-lib.ps1'` (dot-source dependency reads better in order; the copy loop itself is order-insensitive). Do NOT add any pool seeding — the pool is runtime state, created on first use.

Run: `pwsh -NoProfile -File scripts/test-bootstrap.ps1`
Expected: all assertions PASS.

- [ ] **Step 3: Replace commands/optimize-prompt.md**

Replace the entire content of `commands/optimize-prompt.md` with:

```markdown
---
description: Evolve the Conductor planner prompt (GEPA candidate pool, propose-then-apply)
argument-hint: "[--max-runs N] [--max-tier local|free|paid] [--reflect-tier T] [--generations N] [--pool] [--apply]"
---

Run the GEPA prompt-evolution loop over the Conductor's planner prompt.

Parse `$ARGUMENTS` for the optional flags, then run ONE PowerShell command
(keep it under 965 bytes):

- Default / evolve: `pwsh -NoProfile -File ~/.claude/scripts/fleet-optimize-prompt.ps1 [-MaxRuns N] [-MaxCostTier T] [-ReflectTier T] [-Generations N]`
- `--pool`: `pwsh -NoProfile -File ~/.claude/scripts/fleet-optimize-prompt.ps1 -Pool`
- `--apply`: append `-Apply` to the evolve form.

What it does:

1. Loads (or seeds, from the live prompt) the box-private candidate pool at
   `$BATON_HOME/prompts/pool/`.
2. Per generation: picks a parent from the Pareto front, a cheap reflection
   model diagnoses recent `polish`/`reject`-gated runs, a stronger mutation
   model rewrites the prompt, and the child is judged head-to-head
   (plan-only, position-swapped) against the champion over those runs.
3. Dual gate: the child must BEAT its parent on the minibatch AND be
   Pareto-non-dominated (judge win-rate vs prompt tokens). Placeholder loss
   or a blown length cap retires the child before any evaluation is spent.
4. Survivors are PROPOSED (`conductor-planner.candidate.txt`); the live
   prompt is only ever touched by `--apply`, which backs it up and promotes
   the survivor to champion in the pool.

Report the per-generation lines and the proposal/apply outcome to the user
in plain language. If the run exits 2, relay the reason honestly — "no
candidate survived the dual gate" is a normal, healthy outcome, not an error
to retry.
```

- [ ] **Step 4: Update docs/COMMANDS.md**

1. In the cheat-sheet table, replace the row
   `| /baton:optimize-prompt [--apply] | Propose (then deploy) a better planner prompt |`
   with:
   `| /baton:optimize-prompt [--generations N] [--pool] [--apply] | Evolve the planner prompt (GEPA pool, propose-then-apply) |`
2. Find the full `/baton:optimize-prompt` entry (in the "Routing journal & lessons" section) and replace its body with:

```markdown
GEPA evolution over the Conductor planner prompt. A box-private candidate
pool (`$BATON_HOME/prompts/pool/`) tracks every prompt variant: lineage,
status (champion / candidate / retired), judge scores, token estimates, and —
reserved for the shadow-A/B slice — live cost-to-acceptance stats. Each
generation: Pareto-front parent selection → cheap reflection model diagnoses
gate-failed runs → stronger mutation model rewrites the prompt → plan-only
minibatch judged head-to-head vs the champion (position-swapped) → dual gate
(beat parent AND Pareto-non-dominated on quality vs tokens; length cap).
Survivors are proposed as `conductor-planner.candidate.txt`; `--apply`
(human-gated, d070) backs up the live prompt and promotes the survivor to
champion. `--pool` prints the pool report. Flags: `--max-runs N` (default 5),
`--max-tier` (mutation/judge tier, default paid), `--reflect-tier` (default
one below max-tier), `--generations N` (default 1).
```

- [ ] **Step 5: Bump the plugin version**

In `.claude-plugin/plugin.json` line 4: `"version": "1.5.0",` → `"version": "1.6.0-rc.1",`

- [ ] **Step 6: Run the full gate**

Run: `pwsh -NoProfile -File scripts/test-prompt-pool-lib.ps1; pwsh -NoProfile -File scripts/test-optimize-prompt-lib.ps1; pwsh -NoProfile -File scripts/test-bootstrap.ps1; pwsh -NoProfile -File scripts/test-conductor-lib.ps1`
Expected: all four suites exit 0 (conductor suite proves the planner-prompt resolution chain is untouched).

- [ ] **Step 7: Commit**

```bash
git add scripts/bootstrap.ps1 scripts/test-bootstrap.ps1 commands/optimize-prompt.md docs/COMMANDS.md .claude-plugin/plugin.json
git commit -m "feat(optimizer): wire prompt-pool-lib into bootstrap, docs, 1.6.0-rc.1"
```
