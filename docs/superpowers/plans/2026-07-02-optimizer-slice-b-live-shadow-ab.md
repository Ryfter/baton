# Optimizer Slice B — Live Shadow A/B Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Wire the GEPA candidate pool into live `/baton:go` runs — champion/challenger alternate on real runs, CostResolver-metered realized cost (rework included) accrues per variant, and the pool answers promote/retire in dollars, auto-retiring proven losers.

**Architecture:** Assignment happens in `Invoke-PlanPhase` via a new `Resolve-ShadowVariant` (prompt-pool-lib) and a placeholder-validated `-Template` override on `Build-PlannerPrompt`; accrual + auto-retire happen in `Complete-Run` after the report is written, fail-open. One retirement door (`Set-CandidateRetired`) stamps why/when/who-beat-it on every retirement, including Slice A's existing paths.

**Tech Stack:** PowerShell 7 (pwsh), JSON state under `$BATON_HOME/prompts/pool/`, house Check/PASS-FAIL test style.

**Spec:** `docs/superpowers/specs/2026-07-02-optimizer-slice-b-live-shadow-ab-design.md` — read it for the why; this plan is the how.

## Global Constraints

- Every shell command argument must stay under **965 bytes** (silent failure above).
- Never `Write-Error` (it THROWS under `$ErrorActionPreference = 'Stop'`); CLI failures use `[Console]::Error.WriteLine(...)` + `exit 2`.
- All file writes `-Encoding utf8NoBOM`.
- Unary-comma array flatten (`,([array]$x)`) protects ONLY direct-assignment returns; inside a hashtable-literal value it NESTS — use `@($x)` there. Empty arrays: return plain `@()`, never `,@()`.
- `[AllowNull()][string]` coerces `$null` to `''` — normalize back before storing when JSON `null` is required.
- Tests are hermetic: temp dirs only; save/restore `$env:BATON_HOME`; NEVER touch the real `~/.baton` or `~/.claude`.
- Everything on the `/baton:go` path is **fail-open**: pool absent/corrupt, unreadable challenger, accrual failure → the run proceeds exactly as today, at most one `warn` event. No new exit paths.
- The pool is box-private under `$BATON_HOME` — never enters the knowledge repo or any shared seed.
- Required planner placeholders, verbatim: `{{schema}}`, `{{evi}}`, `{{Goal}}`.
- Evidence threshold constant: `$script:ShadowMinGatedRuns = 5`.
- PowerShell is case-insensitive for variables: a param `$Template` and a local `$template` are the SAME variable (Task 3 renames the existing local to `$resolved` for this reason).
- Never name PS variables `$args`/`$input`/`$event`/`$matches`/`$host`.

---

### Task 1: Slice B primitives in prompt-pool-lib (retirement door, shadow resolution, live accrual, dollars verdict)

**Files:**
- Modify: `scripts/prompt-pool-lib.ps1`
- Test: `scripts/test-prompt-pool-lib.ps1` (append P30–P55; existing P1–P29 must stay green)

**Interfaces:**
- Consumes: existing `Get-PromptPool`, `Save-PromptPool`, `New-PoolCandidateRecord`, `Get-PromptPoolDir` (unchanged signatures).
- Produces (later tasks rely on these exact names/shapes):
  - `Set-CandidateRetired -Pool <hashtable> -Id <string> -Reason <string> [-By <string>]` → `$true`/`$false` (mutates, does NOT save)
  - `Get-ShadowEnabled -Pool <hashtable>` → `[bool]` (absent key = `$true`)
  - `Select-ShadowChallenger -Pool <hashtable>` → candidate hashtable or `$null`
  - `Resolve-ShadowVariant [-PoolDir <dir>]` → `@{ shadow=$false; reason=... }` or `@{ shadow=$true; variant_id; role; template; challenger_id }`
  - `Add-LiveRunResult -Pool <hashtable> -VariantId <string> -CostUsd <double> [-Verdict accept|polish|reject]` → `$true`/`$false` (mutates, does NOT save)
  - `Get-CostPerAccept -Live <hashtable>` → `[double]` or `$null`
  - `Get-ShadowVerdict -Pool <hashtable>` → `@{ state='no-challenger'|'insufficient'|'promote'|'retire'|'stalemate'; champion_id; challenger_id; champion_cpa; challenger_cpa; champion_gated; challenger_gated; threshold }` (`no-challenger` shape carries only `state` + `threshold`)
  - `New-PoolCandidateRecord` now also creates `retired_at = $null` and `retired_by = $null`
  - `$script:ShadowMinGatedRuns = 5`

- [ ] **Step 1: Write the failing tests**

Append to the END of `scripts/test-prompt-pool-lib.ps1`, BEFORE the final exit-code block (the file ends with a fail-count gate — keep it last):

```powershell
# ---- Slice B: Set-CandidateRetired (the single retirement door) ----
function Set-TestLive($cand, $runs, $accept, $polish, $reject, $cost, $rework) {
    $cand.live.runs = $runs; $cand.live.accept = $accept; $cand.live.polish = $polish
    $cand.live.reject = $reject; $cand.live.realized_cost_usd = $cost; $cand.live.rework_cost_usd = $rework
    return $cand
}

$sbPool = @{ schema = 1; champion = 'p001'; candidates = @((New-TestCand 'p001' 'champion' 0.5 100), (New-TestCand 'p002' 'candidate' 0.7 90)) }
$retOk = Set-CandidateRetired -Pool $sbPool -Id 'p002' -Reason 'test loss' -By 'p001'
$ret = @($sbPool.candidates | Where-Object { $_.id -eq 'p002' })[0]
Check 'P30 Set-CandidateRetired stamps status/reason/at/by' ($retOk -and ($ret.status -eq 'retired') -and ($ret.retired_reason -eq 'test loss') -and ($ret.retired_at -match 'Z$') -and ($ret.retired_by -eq 'p001'))
$sbPool2 = @{ schema = 1; champion = 'p001'; candidates = @((New-TestCand 'p001' 'champion' 0.5 100), (New-TestCand 'p002' 'candidate' 0.7 90)) }
[void](Set-CandidateRetired -Pool $sbPool2 -Id 'p002' -Reason 'mechanical')
Check 'P31 -By omitted -> retired_by null' ($null -eq @($sbPool2.candidates | Where-Object { $_.id -eq 'p002' })[0].retired_by)
Check 'P32 unknown id -> false' (-not (Set-CandidateRetired -Pool $sbPool2 -Id 'p999' -Reason 'x'))
Check 'P33 new records carry retired_at/retired_by null' ((($null -eq (New-TestCand 'p009' 'candidate' 0.5 10).retired_at)) -and ($null -eq (New-TestCand 'p010' 'candidate' 0.5 10).retired_by))

# ---- Slice B: Get-ShadowEnabled ----
Check 'P34 shadow key absent -> enabled' (Get-ShadowEnabled -Pool @{ schema = 1; champion = 'p001'; candidates = @() })
Check 'P35 shadow=false -> disabled' (-not (Get-ShadowEnabled -Pool @{ schema = 1; shadow = $false; champion = 'p001'; candidates = @() }))

# ---- Slice B: Resolve-ShadowVariant truth table ----
$svAbsent = Resolve-ShadowVariant -PoolDir (Join-Path (New-TempDir) 'nope')
Check 'P36 absent pool -> shadow=false reason=absent' ((-not $svAbsent.shadow) -and ($svAbsent.reason -eq 'absent'))

# a real seeded pool for the rest of the table
$svDir = New-TempDir
$svSeed = Join-Path $svDir 'conductor-planner.txt'
Set-Content -LiteralPath $svSeed -Value 'LIVE {{schema}} {{evi}} {{Goal}}' -Encoding utf8NoBOM
$svPoolDir = Join-Path $svDir 'pool'
[void](Initialize-PromptPool -SeedPromptPath $svSeed -PoolDir $svPoolDir)

$svChampOnly = Resolve-ShadowVariant -PoolDir $svPoolDir
Check 'P37 champion only -> shadow=false reason=no challenger' ((-not $svChampOnly.shadow) -and ($svChampOnly.reason -eq 'no challenger'))

# add a scored challenger + its text file
$svLoaded = (Get-PromptPool -PoolDir $svPoolDir).pool
$svChall = New-TestCand 'p002' 'candidate' 0.8 80
$svLoaded.candidates = @($svLoaded.candidates) + @($svChall)
Set-Content -LiteralPath (Join-Path $svPoolDir 'p002.txt') -Value 'CHALL {{schema}} {{evi}} {{Goal}}' -Encoding utf8NoBOM
Save-PromptPool -Pool $svLoaded -PoolDir $svPoolDir

$svTie = Resolve-ShadowVariant -PoolDir $svPoolDir
Check 'P38 tie on live runs -> challenger takes the run, template carried' ($svTie.shadow -and ($svTie.role -eq 'challenger') -and ($svTie.variant_id -eq 'p002') -and (([string]$svTie.template) -match 'CHALL') -and ($svTie.challenger_id -eq 'p002'))

# champion behind on runs -> champion takes the run, no template
$svLoaded = (Get-PromptPool -PoolDir $svPoolDir).pool
$c1 = @($svLoaded.candidates | Where-Object { $_.id -eq 'p002' })[0]
[void](Set-TestLive $c1 3 1 1 1 0.5 0.2)
Save-PromptPool -Pool $svLoaded -PoolDir $svPoolDir
$svChampTurn = Resolve-ShadowVariant -PoolDir $svPoolDir
Check 'P39 champion fewer runs -> champion role, null template' ($svChampTurn.shadow -and ($svChampTurn.role -eq 'champion') -and ($svChampTurn.variant_id -eq 'p001') -and ($null -eq $svChampTurn.template))

# disabled kill switch
$svLoaded = (Get-PromptPool -PoolDir $svPoolDir).pool
$svLoaded.shadow = $false
Save-PromptPool -Pool $svLoaded -PoolDir $svPoolDir
$svOff = Resolve-ShadowVariant -PoolDir $svPoolDir
Check 'P40 shadow=false -> disabled' ((-not $svOff.shadow) -and ($svOff.reason -eq 'disabled'))
$svLoaded = (Get-PromptPool -PoolDir $svPoolDir).pool
$svLoaded.shadow = $true
Save-PromptPool -Pool $svLoaded -PoolDir $svPoolDir

# unreadable / invalid challenger text fails open
Set-Content -LiteralPath (Join-Path $svPoolDir 'p002.txt') -Value 'MISSING PLACEHOLDERS' -Encoding utf8NoBOM
$svBadText = Resolve-ShadowVariant -PoolDir $svPoolDir
Check 'P41 placeholder-missing challenger text -> shadow=false reason=challenger unreadable' ((-not $svBadText.shadow) -and ($svBadText.reason -eq 'challenger unreadable'))
Remove-Item -LiteralPath (Join-Path $svPoolDir 'p002.txt') -Force
$svNoFile = Resolve-ShadowVariant -PoolDir $svPoolDir
Check 'P42 missing challenger file -> shadow=false reason=challenger unreadable' ((-not $svNoFile.shadow) -and ($svNoFile.reason -eq 'challenger unreadable'))
Set-Content -LiteralPath (Join-Path $svPoolDir 'p002.txt') -Value 'CHALL {{schema}} {{evi}} {{Goal}}' -Encoding utf8NoBOM

# highest-win-rate challenger wins selection; stale (null wr) excluded
$svLoaded = (Get-PromptPool -PoolDir $svPoolDir).pool
$svLow = New-TestCand 'p003' 'candidate' 0.6 70
$svStale = New-TestCand 'p004' 'candidate' $null 60
$svLoaded.candidates = @($svLoaded.candidates) + @($svLow, $svStale)
Save-PromptPool -Pool $svLoaded -PoolDir $svPoolDir
$selChall = Select-ShadowChallenger -Pool (Get-PromptPool -PoolDir $svPoolDir).pool
Check 'P43 highest-wr scored candidate selected as challenger' ($selChall.id -eq 'p002')

# ---- Slice B: Add-LiveRunResult arithmetic ----
$arPool = @{ schema = 1; champion = 'p001'; candidates = @((New-TestCand 'p001' 'champion' 0.5 100)) }
[void](Add-LiveRunResult -Pool $arPool -VariantId 'p001' -CostUsd 0.25 -Verdict accept)
$arC = $arPool.candidates[0]
Check 'P44 accept accrual: runs/accept/realized up, rework untouched' ((([int]$arC.live.runs) -eq 1) -and (([int]$arC.live.accept) -eq 1) -and (([double]$arC.live.realized_cost_usd) -eq 0.25) -and (([double]$arC.live.rework_cost_usd) -eq 0.0))
[void](Add-LiveRunResult -Pool $arPool -VariantId 'p001' -CostUsd 0.5 -Verdict reject)
Check 'P45 reject accrual doubles into rework' ((([int]$arC.live.reject) -eq 1) -and (([double]$arC.live.realized_cost_usd) -eq 0.75) -and (([double]$arC.live.rework_cost_usd) -eq 0.5))
[void](Add-LiveRunResult -Pool $arPool -VariantId 'p001' -CostUsd 0.1)
Check 'P46 ungated accrual: cost + runs only, no verdict counters' ((([int]$arC.live.runs) -eq 3) -and (([int]$arC.live.accept) -eq 1) -and (([int]$arC.live.polish) -eq 0) -and (([double]$arC.live.realized_cost_usd) -eq 0.85))
Check 'P47 unknown variant -> false' (-not (Add-LiveRunResult -Pool $arPool -VariantId 'p999' -CostUsd 1.0))

# ---- Slice B: Get-CostPerAccept + Get-ShadowVerdict ----
Check 'P48 cost per accept null at zero accepts' ($null -eq (Get-CostPerAccept -Live @{ accept = 0; realized_cost_usd = 5.0 }))
Check 'P49 cost per accept = realized/accepts' ((Get-CostPerAccept -Live @{ accept = 4; realized_cost_usd = 1.0 }) -eq 0.25)

function New-VerdictPool($champLive, $challLive) {
    $ch = Set-TestLive (New-TestCand 'p001' 'champion' 0.5 100) @champLive
    $cl = Set-TestLive (New-TestCand 'p002' 'candidate' 0.8 90) @challLive
    return @{ schema = 1; champion = 'p001'; candidates = @($ch, $cl) }
}
# args to Set-TestLive after the record: runs accept polish reject cost rework
$vNoChall = Get-ShadowVerdict -Pool @{ schema = 1; champion = 'p001'; candidates = @((New-TestCand 'p001' 'champion' 0.5 100)) }
Check 'P50 no challenger -> state no-challenger' ($vNoChall.state -eq 'no-challenger')
$vIns = Get-ShadowVerdict -Pool (New-VerdictPool @(5,4,1,0,1.0,0.1) @(3,2,1,0,0.5,0.1))
Check 'P51 below threshold -> insufficient with counts' (($vIns.state -eq 'insufficient') -and ($vIns.challenger_gated -eq 3) -and ($vIns.champion_gated -eq 5))
$vPro = Get-ShadowVerdict -Pool (New-VerdictPool @(5,4,1,0,2.0,0.4) @(5,4,1,0,1.0,0.2))
Check 'P52 challenger cheaper per accept -> promote' (($vPro.state -eq 'promote') -and ($vPro.challenger_cpa -eq 0.25) -and ($vPro.champion_cpa -eq 0.5))
$vRet = Get-ShadowVerdict -Pool (New-VerdictPool @(5,4,1,0,1.0,0.2) @(5,4,1,0,2.0,0.4))
Check 'P53 challenger dearer per accept -> retire' ($vRet.state -eq 'retire')
$vAsym = Get-ShadowVerdict -Pool (New-VerdictPool @(5,4,1,0,1.0,0.2) @(5,0,3,2,2.0,2.0))
Check 'P54 challenger 0 accepts vs champion >0 -> retire' ($vAsym.state -eq 'retire')
$vAsym2 = Get-ShadowVerdict -Pool (New-VerdictPool @(5,0,3,2,1.0,1.0) @(5,4,1,0,1.0,0.2))
Check 'P54a champion 0 accepts vs challenger >0 -> promote' ($vAsym2.state -eq 'promote')
$vStale = Get-ShadowVerdict -Pool (New-VerdictPool @(5,0,3,2,1.0,1.0) @(5,0,4,1,1.0,1.0))
Check 'P55 both 0 accepts at threshold -> stalemate' ($vStale.state -eq 'stalemate')
$vEq = Get-ShadowVerdict -Pool (New-VerdictPool @(5,4,1,0,1.0,0.1) @(5,4,1,0,1.0,0.1))
Check 'P55a equal cost per accept -> stalemate' ($vEq.state -eq 'stalemate')
```

Note: `Set-TestLive ... @champLive` splats a positional array — that is intentional (`@(runs,accept,polish,reject,cost,rework)`).

- [ ] **Step 2: Run tests to verify the new ones fail**

Run: `pwsh -File scripts/test-prompt-pool-lib.ps1`
Expected: P1–P29 PASS; execution ERRORS at P30 (`Set-CandidateRetired` not recognized) — that is the failing state.

- [ ] **Step 3: Implement in `scripts/prompt-pool-lib.ps1`**

3a. Directly under the dot-source line (`. "$PSScriptRoot/baton-home.ps1"`), add:

```powershell
# Slice B: minimum gated live runs PER VARIANT before the dollars verdict.
$script:ShadowMinGatedRuns = 5
```

3b. In `New-PoolCandidateRecord`, add two fields right after `retired_reason = $null`:

```powershell
        retired_reason = $null
        retired_at = $null
        retired_by = $null
```

3c. Append these functions at the END of the file:

```powershell
function Set-CandidateRetired {
    <# The single retirement door (Slice B): every path that retires a
       candidate goes through here so why (reason), when (retired_at), and
       what beat/replaced it (retired_by) are always on the record. Mutates
       the in-memory pool; the caller saves. #>
    param(
        [Parameter(Mandatory)][hashtable]$Pool,
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$Reason,
        [string]$By
    )
    $hit = @($Pool.candidates | Where-Object { $_.id -eq $Id })
    if (@($hit).Count -eq 0) { return $false }
    $c = $hit[0]
    $c.status = 'retired'
    $c.retired_reason = $Reason
    $c.retired_at = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    # [string]$By coerces $null to '' — normalize back so JSON carries null.
    $c.retired_by = if ([string]::IsNullOrEmpty($By)) { $null } else { $By }
    return $true
}

function Get-ShadowEnabled {
    <# Kill switch: pool.shadow. ABSENT key reads as enabled (on by default). #>
    param([Parameter(Mandatory)][hashtable]$Pool)
    if ($Pool.ContainsKey('shadow')) { return [bool]$Pool.shadow }
    return $true
}

function Select-ShadowChallenger {
    <# The active challenger: highest offline win rate among status='candidate'
       members with a non-null (non-stale) score; tie -> highest id (newest).
       $null when nothing is live-testable. #>
    param([Parameter(Mandatory)][hashtable]$Pool)
    $scored = @($Pool.candidates | Where-Object {
        ($_.status -eq 'candidate') -and ($null -ne $_.offline.minibatch.win_rate_vs_champion)
    })
    if (@($scored).Count -eq 0) { return $null }
    return @($scored | Sort-Object `
        @{ Expression = { [double]$_.offline.minibatch.win_rate_vs_champion }; Descending = $true },
        @{ Expression = { [string]$_.id }; Descending = $true })[0]
}

function Resolve-ShadowVariant {
    <# Which prompt does THIS /baton:go run use? Fail-open by construction:
       any problem returns shadow=$false and the caller behaves exactly as
       today. Never throws; never writes the pool (assignment is not
       evidence — counters move only at accrual). #>
    param([string]$PoolDir = (Get-PromptPoolDir))
    $loaded = Get-PromptPool -PoolDir $PoolDir
    if (-not $loaded.ok) {
        $why = if ($loaded.reason -eq 'absent') { 'absent' } else { 'corrupt' }
        return @{ shadow = $false; reason = $why }
    }
    $pool = $loaded.pool
    if (-not (Get-ShadowEnabled -Pool $pool)) { return @{ shadow = $false; reason = 'disabled' } }
    $champHit = @($pool.candidates | Where-Object { $_.id -eq $pool.champion })
    if (@($champHit).Count -eq 0) { return @{ shadow = $false; reason = 'corrupt' } }
    $champ = $champHit[0]
    $chall = Select-ShadowChallenger -Pool $pool
    if ($null -eq $chall) { return @{ shadow = $false; reason = 'no challenger' } }
    # Alternation: fewer live runs takes this run; tie -> challenger (it is
    # the one needing evidence). Self-balancing across aborted/ungated runs.
    if (([int]$champ.live.runs) -lt ([int]$chall.live.runs)) {
        return @{ shadow = $true; variant_id = [string]$champ.id; role = 'champion'
                  template = $null; challenger_id = [string]$chall.id }
    }
    $textPath = Join-Path $PoolDir ([string]$chall.file)
    $text = $null
    try { if (Test-Path $textPath) { $text = Get-Content -Raw -LiteralPath $textPath } } catch { $text = $null }
    $okText = $false
    if (-not [string]::IsNullOrEmpty($text)) {
        $okText = $text.Contains('{{schema}}') -and $text.Contains('{{evi}}') -and $text.Contains('{{Goal}}')
    }
    if (-not $okText) { return @{ shadow = $false; reason = 'challenger unreadable' } }
    return @{ shadow = $true; variant_id = [string]$chall.id; role = 'challenger'
              template = $text; challenger_id = [string]$chall.id }
}

function Add-LiveRunResult {
    <# Accrue one live run's realized cost (and verdict, when gated) to a
       variant's live.* fields. Rework dollars = every dollar spent on a run
       that ended polish/reject (Kevin's cost-to-accepted-outcome metric).
       Mutates the in-memory pool; the caller saves. #>
    param(
        [Parameter(Mandatory)][hashtable]$Pool,
        [Parameter(Mandatory)][string]$VariantId,
        [Parameter(Mandatory)][double]$CostUsd,
        [ValidateSet('accept','polish','reject')][string]$Verdict
    )
    $hit = @($Pool.candidates | Where-Object { $_.id -eq $VariantId })
    if (@($hit).Count -eq 0) { return $false }
    $live = $hit[0].live
    $live.runs = ([int]$live.runs) + 1
    $live.realized_cost_usd = [math]::Round(([double]$live.realized_cost_usd) + $CostUsd, 6)
    if ($Verdict) {
        $live[$Verdict] = ([int]$live[$Verdict]) + 1
        if ($Verdict -in @('polish', 'reject')) {
            $live.rework_cost_usd = [math]::Round(([double]$live.rework_cost_usd) + $CostUsd, 6)
        }
    }
    return $true
}

function Get-CostPerAccept {
    <# The north-star per-variant figure: total realized dollars per ACCEPTED
       outcome. null when nothing has been accepted yet. #>
    param([Parameter(Mandatory)]$Live)
    if (([int]$Live.accept) -le 0) { return $null }
    return [math]::Round(([double]$Live.realized_cost_usd) / [int]$Live.accept, 4)
}

function Get-ShadowVerdict {
    <# The dollars verdict. gated(v) = accept+polish+reject. States:
       no-challenger | insufficient | promote | retire | stalemate.
       Pure read — the caller acts (Complete-Run auto-retires; promotion is
       always human --apply, d070). #>
    param([Parameter(Mandatory)][hashtable]$Pool)
    $champHit = @($Pool.candidates | Where-Object { $_.id -eq $Pool.champion })
    $chall = Select-ShadowChallenger -Pool $Pool
    if ((@($champHit).Count -eq 0) -or ($null -eq $chall)) {
        return @{ state = 'no-challenger'; threshold = $script:ShadowMinGatedRuns }
    }
    $champ = $champHit[0]
    $cg = ([int]$champ.live.accept) + ([int]$champ.live.polish) + ([int]$champ.live.reject)
    $hg = ([int]$chall.live.accept) + ([int]$chall.live.polish) + ([int]$chall.live.reject)
    $verdict = @{
        champion_id = [string]$champ.id; challenger_id = [string]$chall.id
        champion_gated = $cg; challenger_gated = $hg
        champion_cpa = (Get-CostPerAccept -Live $champ.live)
        challenger_cpa = (Get-CostPerAccept -Live $chall.live)
        threshold = $script:ShadowMinGatedRuns
    }
    if (($cg -lt $script:ShadowMinGatedRuns) -or ($hg -lt $script:ShadowMinGatedRuns)) {
        $verdict.state = 'insufficient'
        return $verdict
    }
    $cc = $verdict.champion_cpa
    $hc = $verdict.challenger_cpa
    if (($null -eq $cc) -and ($null -eq $hc)) { $verdict.state = 'stalemate' }
    elseif ($null -eq $hc) { $verdict.state = 'retire' }
    elseif ($null -eq $cc) { $verdict.state = 'promote' }
    elseif (([double]$hc) -lt ([double]$cc)) { $verdict.state = 'promote' }
    elseif (([double]$hc) -gt ([double]$cc)) { $verdict.state = 'retire' }
    else { $verdict.state = 'stalemate' }
    return $verdict
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `pwsh -File scripts/test-prompt-pool-lib.ps1`
Expected: all checks P1–P55a PASS, exit 0.

- [ ] **Step 5: Regression — the two suites that dot-source this lib**

Run: `pwsh -File scripts/test-optimize-prompt-lib.ps1` and `pwsh -File scripts/test-conductor-lib.ps1`
Expected: both PASS unchanged (nothing consumes the new functions yet).

- [ ] **Step 6: Commit**

```bash
git add scripts/prompt-pool-lib.ps1 scripts/test-prompt-pool-lib.ps1
git commit -m "feat(pool): slice B primitives — retirement door, shadow resolution, live accrual, dollars verdict"
```

---

### Task 2: Route Slice A's retirement writes through the single door

**Files:**
- Modify: `scripts/optimize-prompt-lib.ps1` (three spots inside `Invoke-PromptEvolution`)
- Test: `scripts/test-optimize-prompt-lib.ps1` (append E14–E15)

**Interfaces:**
- Consumes: `Set-CandidateRetired` (Task 1, exact signature above).
- Produces: no new names — behavior change only: every retired record now carries `retired_at` (UTC `...Z` string) and, for `superseded`, `retired_by` = the new champion's id.

- [ ] **Step 1: Write the failing tests**

Append to the END of `scripts/test-optimize-prompt-lib.ps1`, BEFORE the final exit-code gate. This block is fully self-contained (own temp `BATON_HOME`, own pool, canned dispatchers):

```powershell
# ---- E14/E15: retirement provenance (Slice B single door) ----
$prevHomeSB = $env:BATON_HOME
try {
    $sbHome = Join-Path ([System.IO.Path]::GetTempPath()) ("opt-sb-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $sbHome | Out-Null
    $env:BATON_HOME = $sbHome
    $sbRun = Join-Path $sbHome 'runs/go-sb-1'
    New-Item -ItemType Directory -Force -Path $sbRun | Out-Null
    @{ verdict = 'polish'; reason = 'needs tightening'; counts = @{ critical = 0; important = 1; minor = 0 }; polish_brief = 'tighten' } |
        ConvertTo-Json | Set-Content -LiteralPath (Join-Path $sbRun 'acceptance.json') -Encoding utf8NoBOM
    @{ run_id = 'go-sb-1'; goal = 'test goal'; tasks = @(@{ id = 't1'; desc = 'd' }) } |
        ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $sbRun 'plan.json') -Encoding utf8NoBOM
    $sbPromptDir = Join-Path $sbHome 'prompts'
    New-Item -ItemType Directory -Force -Path $sbPromptDir | Out-Null
    $sbPrompt = Join-Path $sbPromptDir 'conductor-planner.txt'
    Set-Content -LiteralPath $sbPrompt -Value 'LIVE {{schema}} {{evi}} {{Goal}} padpadpadpadpadpad' -Encoding utf8NoBOM
    $sbPoolDir = Join-Path $sbPromptDir 'pool'

    $sbReflect = { param($p) @{ stdout = '<diagnosis>too vague</diagnosis>'; exit_code = 0 } }
    $sbPlan = { param($p) @{ stdout = '{"tasks":[]}'; exit_code = 0 } }
    $sbJudgeA = { param($p) @{ stdout = '<verdict>A</verdict>'; exit_code = 0 } }

    # E14: a mutation that loses the placeholders is mechanically retired — with provenance.
    $sbMutBad = { param($p) @{ stdout = '<new_prompt>missing everything</new_prompt>'; exit_code = 0 } }
    [void](Invoke-PromptEvolution -PromptPath $sbPrompt -PoolDir $sbPoolDir `
        -ReflectDispatcher $sbReflect -MutateDispatcher $sbMutBad -PlanDispatcher $sbPlan -JudgeDispatcher $sbJudgeA)
    $sbPool1 = (Get-PromptPool -PoolDir $sbPoolDir).pool
    $sbMech = @($sbPool1.candidates | Where-Object { $_.id -eq 'p002' })[0]
    Check 'E14 mechanical retirement stamps retired_at, retired_by null' `
        (($sbMech.status -eq 'retired') -and (([string]$sbMech.retired_at) -match 'Z$') -and ($null -eq $sbMech.retired_by))

    # E15: --apply supersedes the old champion — retired_by = the new champion.
    $sbMutGood = { param($p) @{ stdout = '<new_prompt>NEW {{schema}} {{evi}} {{Goal}}</new_prompt>'; exit_code = 0 } }
    [void](Invoke-PromptEvolution -PromptPath $sbPrompt -PoolDir $sbPoolDir `
        -ReflectDispatcher $sbReflect -MutateDispatcher $sbMutGood -PlanDispatcher $sbPlan -JudgeDispatcher $sbJudgeA -Apply)
    $sbPool2 = (Get-PromptPool -PoolDir $sbPoolDir).pool
    $sbOld = @($sbPool2.candidates | Where-Object { $_.id -eq 'p001' })[0]
    Check 'E15 superseded champion carries retired_by = new champion + retired_at' `
        (($sbOld.status -eq 'retired') -and ($sbOld.retired_reason -eq 'superseded') -and `
         ($sbOld.retired_by -eq $sbPool2.champion) -and (([string]$sbOld.retired_at) -match 'Z$'))
} finally { $env:BATON_HOME = $prevHomeSB }
```

- [ ] **Step 2: Run tests to verify the new ones fail**

Run: `pwsh -File scripts/test-optimize-prompt-lib.ps1`
Expected: existing checks PASS; E14 FAILs (retired_at is `$null` — the field exists via Task 1's record factory but nothing stamps it yet). E15 FAILs on `retired_by`.

- [ ] **Step 3: Refactor the three retirement spots in `scripts/optimize-prompt-lib.ps1`**

3a. **Mechanical rejection** — replace this block inside `Invoke-PromptEvolution`:

```powershell
        if ($mechReason) {
            $child = New-PoolCandidateRecord -Id $childId -Parent ([string]$parent.id) -Origin 'mutation' -Status 'retired' -PromptTokens $childTokens
            $child.retired_reason = $mechReason
            Set-Content -LiteralPath (Join-Path $PoolDir "$childId.txt") -Value $childText -Encoding utf8NoBOM
            $pool.candidates = @($pool.candidates) + @($child)
```

with:

```powershell
        if ($mechReason) {
            $child = New-PoolCandidateRecord -Id $childId -Parent ([string]$parent.id) -Origin 'mutation' -Status 'candidate' -PromptTokens $childTokens
            Set-Content -LiteralPath (Join-Path $PoolDir "$childId.txt") -Value $childText -Encoding utf8NoBOM
            $pool.candidates = @($pool.candidates) + @($child)
            [void](Set-CandidateRetired -Pool $pool -Id $childId -Reason $mechReason)
```

(The rest of that block — `$genRec.child = $childId` onward — is unchanged.)

3b. **Gate failure** — the child is currently appended to the pool AFTER the pass/fail branch. Replace:

```powershell
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
```

with:

```powershell
        $gate = Test-DualGate -Child $child -WinRateVsParent $wrVsParent -Pool $pool
        Set-Content -LiteralPath (Join-Path $PoolDir "$childId.txt") -Value $childText -Encoding utf8NoBOM
        $genRec.child = $childId
        $genRec.pass = $gate.pass
        $genRec.reasons = @($gate.reasons)
        $pool.candidates = @($pool.candidates) + @($child)
        if ($gate.pass) {
            $lastSurvivor = $child
            Write-Host "Generation ${g}: $childId SURVIVED the dual gate (vs champion: $($mbChampion.win_rate), vs parent: $wrVsParent)."
        } else {
            [void](Set-CandidateRetired -Pool $pool -Id $childId -Reason (@($gate.reasons) -join '; '))
            Write-Host "Generation ${g}: $childId retired — $($child.retired_reason)."
        }
        Save-PromptPool -Pool $pool -PoolDir $PoolDir
```

(Note the append moved ABOVE the branch so `Set-CandidateRetired` can find the record; `$child` is the same object reference the pool holds, so `$child.retired_reason` in the `Write-Host` reads the stamped value.)

3c. **Superseded champion (--apply)** — replace:

```powershell
        foreach ($c in @($pool.candidates)) {
            if ($c.id -eq $pool.champion) { $c.status = 'retired'; $c.retired_reason = 'superseded' }
            elseif (($c.status -eq 'candidate') -and ($c.id -ne $lastSurvivor.id)) {
                # Scores were measured against the OLD champion: mark stale
                # (excluded from the Pareto front until re-evaluated).
                $c.offline.minibatch.win_rate_vs_champion = $null
            }
        }
```

with:

```powershell
        [void](Set-CandidateRetired -Pool $pool -Id ([string]$pool.champion) -Reason 'superseded' -By ([string]$lastSurvivor.id))
        foreach ($c in @($pool.candidates)) {
            if (($c.status -eq 'candidate') -and ($c.id -ne $lastSurvivor.id)) {
                # Scores were measured against the OLD champion: mark stale
                # (excluded from the Pareto front until re-evaluated).
                $c.offline.minibatch.win_rate_vs_champion = $null
            }
        }
```

(Order matters: retire while `$pool.champion` still names the OLD champion; `$lastSurvivor` is not yet `status='champion'`, so the stale loop's `candidate` filter must exclude it by id — which it does.)

- [ ] **Step 4: Run tests to verify they pass**

Run: `pwsh -File scripts/test-optimize-prompt-lib.ps1`
Expected: all checks incl. E14/E15 PASS, exit 0.

- [ ] **Step 5: Regression**

Run: `pwsh -File scripts/test-prompt-pool-lib.ps1`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add scripts/optimize-prompt-lib.ps1 scripts/test-optimize-prompt-lib.ps1
git commit -m "refactor(optimize): all retirements through Set-CandidateRetired (why/when/who on the record)"
```

---

### Task 3: Conductor wiring — shadow assignment in the plan phase, accrual + auto-retire in Complete-Run

**Files:**
- Modify: `scripts/conductor-lib.ps1` (dot-source block, `Build-PlannerPrompt`, `Invoke-PlanPhase`, `Complete-Run`, `Invoke-Conductor`)
- Test: `scripts/test-conductor-lib.ps1` (append SB1–SB10; the file's existing `try { ... }` wrapper and T-numbered checks must stay green — append INSIDE the try block, before its closing brace / final exit gate)

**Interfaces:**
- Consumes (Task 1 exact signatures): `Resolve-ShadowVariant`, `Add-LiveRunResult`, `Get-ShadowVerdict`, `Set-CandidateRetired`, `Get-PromptPool`, `Save-PromptPool`, `Initialize-PromptPool`, `New-PoolCandidateRecord`.
- Produces:
  - `Build-PlannerPrompt -Goal <g> [-RegistryLines <a>] [-Template <t>]` — valid `$Template` (all three placeholders) wins; invalid/empty falls through to today's chain.
  - `Invoke-PlanPhase ... [-RunDir <dir>] [-ShadowResolver <sb>]` — on a shadow run writes `$RunDir/shadow.json` (`@{ variant_id; role; challenger_id; assigned }`) + one `kind='shadow'` event.
  - `Complete-Run` — unchanged signature; new post-report accrual/auto-retire behavior.

- [ ] **Step 1: Write the failing tests**

Append inside the try block of `scripts/test-conductor-lib.ps1`, after the last existing check:

```powershell
    # ---- Slice B: shadow A/B ----
    # SB1/SB2: -Template override on Build-PlannerPrompt
    $sbTpl = "SHADOWTPL {{schema}} {{evi}} {{Goal}}"
    $sbOut = Build-PlannerPrompt -Goal 'g1' -Template $sbTpl
    Check 'SB1 valid -Template used verbatim' ($sbOut -match 'SHADOWTPL' -and $sbOut -match 'g1')
    $sbOut2 = Build-PlannerPrompt -Goal 'g1' -Template 'BROKEN no placeholders'
    Check 'SB2 invalid -Template falls back to the normal chain' ($sbOut2 -notmatch 'BROKEN')

    # Hermetic BATON_HOME with a seeded pool + one challenger for the rest.
    $sbPrevHome = $env:BATON_HOME
    try {
        $sbHome = Join-Path ([System.IO.Path]::GetTempPath()) "cond-sb-$([System.IO.Path]::GetRandomFileName())"
        New-Item -ItemType Directory -Force -Path (Join-Path $sbHome 'prompts') | Out-Null
        $env:BATON_HOME = $sbHome
        $sbSeed = Join-Path $sbHome 'prompts/conductor-planner.txt'
        Set-Content -LiteralPath $sbSeed -Value 'LIVEPROMPT {{schema}} {{evi}} {{Goal}}' -Encoding utf8NoBOM
        $sbPoolDir = Join-Path $sbHome 'prompts/pool'
        [void](Initialize-PromptPool -SeedPromptPath $sbSeed -PoolDir $sbPoolDir)
        $sbP = (Get-PromptPool -PoolDir $sbPoolDir).pool
        $sbChall = New-PoolCandidateRecord -Id 'p002' -Parent 'p001' -Origin 'mutation' -Status 'candidate' -PromptTokens 10
        $sbChall.offline.minibatch.win_rate_vs_champion = 0.8
        $sbP.candidates = @($sbP.candidates) + @($sbChall)
        Set-Content -LiteralPath (Join-Path $sbPoolDir 'p002.txt') -Value 'CHALLPROMPT {{schema}} {{evi}} {{Goal}}' -Encoding utf8NoBOM
        Save-PromptPool -Pool $sbP -PoolDir $sbPoolDir

        # SB3: challenger assignment writes shadow.json + event and routes the template.
        $sbRun1 = Initialize-RunDir -RunId 'go-sb-1' -Root (Join-Path $sbHome 'runs')
        $sbSeen = @{ prompt = '' }
        $sbDisp = { param($cand, $prompt) $sbSeen.prompt = $prompt; @{ stdout = '{"tasks":[{"id":"t1","desc":"d"}]}'; exit_code = 0 } }.GetNewClosure()
        $sbResolver = { @{ shadow = $true; variant_id = 'p002'; role = 'challenger'
                           template = (Get-Content -Raw (Join-Path $sbPoolDir 'p002.txt')); challenger_id = 'p002' } }.GetNewClosure()
        $sbFleet = Join-Path $sbHome 'fleet.yaml'
        Set-Content -LiteralPath $sbFleet -Value "providers:`n  - name: stub`n    platform: claude`n    cost_tier: free`n    capabilities: [reasoning]" -Encoding utf8NoBOM
        $sbPlanRes = Invoke-PlanPhase -Goal 'shadow goal' -RunId 'go-sb-1' -FleetPath $sbFleet -ToolsPath (Join-Path $sbHome 'tools.yaml') `
            -Dispatcher $sbDisp -RunDir $sbRun1 -ShadowResolver $sbResolver
        $sbShadowJson = Join-Path $sbRun1 'shadow.json'
        Check 'SB3a shadow.json written with variant/role' ((Test-Path $sbShadowJson) -and ((Get-Content -Raw $sbShadowJson | ConvertFrom-Json).variant_id -eq 'p002'))
        Check 'SB3b challenger template reached the planner dispatch' ($sbSeen.prompt -match 'CHALLPROMPT' -and $sbSeen.prompt -match 'shadow goal')
        $sbEv1 = Get-Content -LiteralPath (Join-Path $sbRun1 'events.jsonl') | ForEach-Object { $_ | ConvertFrom-Json }
        Check 'SB3c shadow event logged' (@($sbEv1 | Where-Object { $_.kind -eq 'shadow' }).Count -eq 1)

        # SB4: resolver says no shadow -> no shadow.json, no event, normal prompt.
        $sbRun2 = Initialize-RunDir -RunId 'go-sb-2' -Root (Join-Path $sbHome 'runs')
        [void](Invoke-PlanPhase -Goal 'plain goal' -RunId 'go-sb-2' -FleetPath $sbFleet -ToolsPath (Join-Path $sbHome 'tools.yaml') `
            -Dispatcher $sbDisp -RunDir $sbRun2 -ShadowResolver { @{ shadow = $false; reason = 'no challenger' } })
        Check 'SB4 no-shadow run leaves no shadow.json' ((-not (Test-Path (Join-Path $sbRun2 'shadow.json'))) -and ($sbSeen.prompt -match 'LIVEPROMPT'))

        # SB5: champion role -> shadow.json role=champion, live-file prompt used.
        $sbRun3 = Initialize-RunDir -RunId 'go-sb-3' -Root (Join-Path $sbHome 'runs')
        [void](Invoke-PlanPhase -Goal 'champ goal' -RunId 'go-sb-3' -FleetPath $sbFleet -ToolsPath (Join-Path $sbHome 'tools.yaml') `
            -Dispatcher $sbDisp -RunDir $sbRun3 -ShadowResolver { @{ shadow = $true; variant_id = 'p001'; role = 'champion'; template = $null; challenger_id = 'p002' } })
        Check 'SB5 champion role recorded, live prompt used' (((Get-Content -Raw (Join-Path $sbRun3 'shadow.json') | ConvertFrom-Json).role -eq 'champion') -and ($sbSeen.prompt -match 'LIVEPROMPT'))

        # SB6: Complete-Run on a GATED shadow run accrues verdict + realized cost.
        $sbPlanObj = @{ run_id = 'go-sb-1'; goal = 'shadow goal'; budget_cap = $null; tasks = @() }
        $sbGate = @{ verdict = 'accept'; reason = 'fine'; counts = @{ critical = 0; important = 0; minor = 0 }; polish_brief = ''; findings = @(); reviews = @(); unparsed = @() }
        [void](Complete-Run -RunDir $sbRun1 -Plan $sbPlanObj -Gate $sbGate -TaskCosts @(@{ id = 't1'; worker = 'stub'; cost = 0.10 }))
        $sbAfter1 = (Get-PromptPool -PoolDir $sbPoolDir).pool
        $sbC2 = @($sbAfter1.candidates | Where-Object { $_.id -eq 'p002' })[0]
        Check 'SB6 gated shadow run accrued: runs=1 accept=1 cost=0.10 rework=0' `
            ((([int]$sbC2.live.runs) -eq 1) -and (([int]$sbC2.live.accept) -eq 1) -and (([double]$sbC2.live.realized_cost_usd) -eq 0.10) -and (([double]$sbC2.live.rework_cost_usd) -eq 0.0))

        # SB7: UNGATED shadow run accrues cost + runs only.
        $sbRun4 = Initialize-RunDir -RunId 'go-sb-4' -Root (Join-Path $sbHome 'runs')
        @{ variant_id = 'p002'; role = 'challenger'; challenger_id = 'p002'; assigned = '2026-07-02T00:00:00Z' } |
            ConvertTo-Json | Set-Content -LiteralPath (Join-Path $sbRun4 'shadow.json') -Encoding utf8NoBOM
        [void](Complete-Run -RunDir $sbRun4 -Plan @{ run_id = 'go-sb-4'; goal = 'g'; budget_cap = $null; tasks = @() } -TaskCosts @(@{ id = 't1'; worker = 'stub'; cost = 0.05 }))
        $sbC2b = @(((Get-PromptPool -PoolDir $sbPoolDir).pool).candidates | Where-Object { $_.id -eq 'p002' })[0]
        Check 'SB7 ungated shadow run: cost-only accrual' ((([int]$sbC2b.live.runs) -eq 2) -and (([int]$sbC2b.live.accept) -eq 1) -and (([double]$sbC2b.live.realized_cost_usd) -eq 0.15))

        # SB8: auto-retire fires at threshold when the challenger is losing in dollars.
        $sbP3 = (Get-PromptPool -PoolDir $sbPoolDir).pool
        $sbChampRec = @($sbP3.candidates | Where-Object { $_.id -eq 'p001' })[0]
        $sbChallRec = @($sbP3.candidates | Where-Object { $_.id -eq 'p002' })[0]
        $sbChampRec.live = @{ runs = 5; accept = 4; polish = 1; reject = 0; realized_cost_usd = 1.0; rework_cost_usd = 0.2 }
        $sbChallRec.live = @{ runs = 4; accept = 0; polish = 2; reject = 2; realized_cost_usd = 2.0; rework_cost_usd = 2.0 }
        Save-PromptPool -Pool $sbP3 -PoolDir $sbPoolDir
        $sbRun5 = Initialize-RunDir -RunId 'go-sb-5' -Root (Join-Path $sbHome 'runs')
        @{ variant_id = 'p002'; role = 'challenger'; challenger_id = 'p002'; assigned = '2026-07-02T00:00:00Z' } |
            ConvertTo-Json | Set-Content -LiteralPath (Join-Path $sbRun5 'shadow.json') -Encoding utf8NoBOM
        $sbGateRej = @{ verdict = 'reject'; reason = 'bad'; counts = @{ critical = 1; important = 0; minor = 0 }; polish_brief = ''; findings = @(); reviews = @(); unparsed = @() }
        [void](Complete-Run -RunDir $sbRun5 -Plan @{ run_id = 'go-sb-5'; goal = 'g'; budget_cap = $null; tasks = @() } -Gate $sbGateRej -TaskCosts @(@{ id = 't1'; worker = 'stub'; cost = 0.10 }))
        $sbAfter5 = (Get-PromptPool -PoolDir $sbPoolDir).pool
        $sbRetired = @($sbAfter5.candidates | Where-Object { $_.id -eq 'p002' })[0]
        Check 'SB8a losing challenger auto-retired with provenance' `
            (($sbRetired.status -eq 'retired') -and ($sbRetired.retired_reason -match 'live A/B loss vs p001') -and ($sbRetired.retired_by -eq 'p001') -and (([string]$sbRetired.retired_at) -match 'Z$'))
        $sbEv5 = Get-Content -LiteralPath (Join-Path $sbRun5 'events.jsonl') | ForEach-Object { $_ | ConvertFrom-Json }
        Check 'SB8b auto-retire logged as warn shadow event' (@($sbEv5 | Where-Object { ($_.kind -eq 'shadow') -and ($_.level -eq 'warn') }).Count -ge 1)

        # SB9: fail-open — corrupt pool never breaks the run.
        Set-Content -LiteralPath (Join-Path $sbPoolDir 'pool.json') -Value '{ not json !!!' -Encoding utf8NoBOM
        $sbRun6 = Initialize-RunDir -RunId 'go-sb-6' -Root (Join-Path $sbHome 'runs')
        @{ variant_id = 'p002'; role = 'challenger'; challenger_id = 'p002'; assigned = '2026-07-02T00:00:00Z' } |
            ConvertTo-Json | Set-Content -LiteralPath (Join-Path $sbRun6 'shadow.json') -Encoding utf8NoBOM
        $sbRes6 = Complete-Run -RunDir $sbRun6 -Plan @{ run_id = 'go-sb-6'; goal = 'g'; budget_cap = $null; tasks = @() } -Gate $sbGate -TaskCosts @()
        Check 'SB9 corrupt pool: run completes normally (fail-open)' (($sbRes6.status -eq 'completed') -and (Test-Path (Join-Path $sbRun6 'report.md')))

        # SB10: winning challenger -> promote recommendation event, NOT retired.
        $sbP4 = @{ schema = 1; champion = 'p001'; candidates = @() }
        $sbW1 = New-PoolCandidateRecord -Id 'p001' -Parent $null -Origin 'seed' -Status 'champion' -PromptTokens 12
        $sbW1.offline.minibatch.win_rate_vs_champion = 0.5
        $sbW1.live = @{ runs = 6; accept = 5; polish = 1; reject = 0; realized_cost_usd = 1.2; rework_cost_usd = 0.2 }
        $sbW2 = New-PoolCandidateRecord -Id 'p002' -Parent 'p001' -Origin 'mutation' -Status 'candidate' -PromptTokens 10
        $sbW2.offline.minibatch.win_rate_vs_champion = 0.8
        $sbW2.live = @{ runs = 5; accept = 5; polish = 0; reject = 0; realized_cost_usd = 0.5; rework_cost_usd = 0.0 }
        $sbP4.candidates = @($sbW1, $sbW2)
        Save-PromptPool -Pool $sbP4 -PoolDir $sbPoolDir
        $sbRun7 = Initialize-RunDir -RunId 'go-sb-7' -Root (Join-Path $sbHome 'runs')
        @{ variant_id = 'p001'; role = 'champion'; challenger_id = 'p002'; assigned = '2026-07-02T00:00:00Z' } |
            ConvertTo-Json | Set-Content -LiteralPath (Join-Path $sbRun7 'shadow.json') -Encoding utf8NoBOM
        [void](Complete-Run -RunDir $sbRun7 -Plan @{ run_id = 'go-sb-7'; goal = 'g'; budget_cap = $null; tasks = @() } -Gate $sbGate -TaskCosts @(@{ id = 't1'; worker = 'stub'; cost = 0.10 }))
        $sbAfter7 = (Get-PromptPool -PoolDir $sbPoolDir).pool
        $sbEv7 = Get-Content -LiteralPath (Join-Path $sbRun7 'events.jsonl') | ForEach-Object { $_ | ConvertFrom-Json }
        Check 'SB10 winning challenger: promote event, still a candidate' `
            ((@($sbAfter7.candidates | Where-Object { $_.id -eq 'p002' })[0].status -eq 'candidate') -and `
             (@($sbEv7 | Where-Object { ($_.kind -eq 'shadow') -and ($_.message -match 'promote|--apply') }).Count -ge 1))
    } finally { $env:BATON_HOME = $sbPrevHome }
```

Notes for the implementer:
- `Get-RealizedTaskCost` falls back to `$Task.cost` when no platform logs match — in the hermetic home that fallback is exactly what SB6–SB8 rely on (cost 0.10 / 0.05).
- The `$sbSeen`/`GetNewClosure()` pattern captures the prompt the dispatcher received — that is how SB3b/SB4/SB5 assert which template was routed.
- `Invoke-PlanPhase` needs `Select-Capability` to return a candidate: the stub `fleet.yaml` provides one `reasoning` provider. If the existing test file already builds a fleet stub, reuse that path instead — but do NOT reuse tabs/records from earlier T-checks.

- [ ] **Step 2: Run tests to verify the new ones fail**

Run: `pwsh -File scripts/test-conductor-lib.ps1`
Expected: existing T-checks PASS; SB1 errors (`-Template` parameter not found) — the failing state.

- [ ] **Step 3: Implement in `scripts/conductor-lib.ps1`**

3a. Add to the dot-source block (after the cost-resolver line):

```powershell
. "$PSScriptRoot/prompt-pool-lib.ps1"   # Slice B: live shadow A/B pool bookkeeping
```

3b. **`Build-PlannerPrompt`** — add the `-Template` param and the override. CAUTION: the function's existing local variable is named `$template`, which is case-insensitively THE SAME as the new param `$Template` — rename the local to `$resolved` everywhere in the function. The changed portion:

```powershell
    param([Parameter(Mandatory)][string]$Goal, [string[]]$RegistryLines = @(), [string]$Template)
```

and the resolution section becomes:

```powershell
    $requiredPlaceholders = @('{{schema}}', '{{evi}}', '{{Goal}}')
    # Slice B: a caller-supplied template (the shadow challenger) wins when it
    # carries all placeholders; anything less falls through to the live chain.
    $resolved = $null
    if (-not [string]::IsNullOrEmpty($Template)) {
        $hasAllOverride = $true
        foreach ($ph in $requiredPlaceholders) { if (-not $Template.Contains($ph)) { $hasAllOverride = $false; break } }
        if ($hasAllOverride) { $resolved = $Template }
    }
    if ($null -eq $resolved) {
        foreach ($candidatePath in @(
            (Join-Path (Get-BatonHome) 'prompts/conductor-planner.txt'),
            (Join-Path $PSScriptRoot '../prompts/conductor-planner.txt')
        )) {
            if (-not (Test-Path $candidatePath)) { continue }
            $candidate = $null
            try { $candidate = Get-Content -Raw -LiteralPath $candidatePath -ErrorAction Stop } catch { continue }
            if ([string]::IsNullOrEmpty($candidate)) { continue }
            $hasAll = $true
            foreach ($ph in $requiredPlaceholders) { if (-not $candidate.Contains($ph)) { $hasAll = $false; break } }
            if ($hasAll) { $resolved = $candidate; break }
        }
    }
    if ($null -eq $resolved) { $resolved = $script:DefaultPlannerPrompt }

    return $resolved.Replace('{{schema}}', $schema).Replace('{{evi}}', $evi).Replace('{{Goal}}', $Goal)
```

3c. **`Invoke-PlanPhase`** — add two params to the param block:

```powershell
        [string]$RunDir,
        [scriptblock]$ShadowResolver
```

and replace the single line `$prompt = Build-PlannerPrompt -Goal $Goal -RegistryLines $RegistryLines` with:

```powershell
    # Slice B: shadow A/B assignment (fail-open; no RunDir = no shadow).
    $shadowTemplate = $null
    if (-not [string]::IsNullOrWhiteSpace($RunDir)) {
        $sv = $null
        try { $sv = if ($ShadowResolver) { & $ShadowResolver } else { Resolve-ShadowVariant } } catch { $sv = $null }
        if ($sv -and $sv.shadow) {
            if ($sv.role -eq 'challenger') { $shadowTemplate = [string]$sv.template }
            try {
                @{ variant_id = [string]$sv.variant_id; role = [string]$sv.role
                   challenger_id = [string]$sv.challenger_id
                   assigned = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') } |
                    ConvertTo-Json | Set-Content -LiteralPath (Join-Path $RunDir 'shadow.json') -Encoding utf8NoBOM
                $vsOther = if ($sv.role -eq 'challenger') { 'champion' } else { "challenger $($sv.challenger_id)" }
                Add-RunEvent -RunDir $RunDir -EventObj (New-RunEvent -Kind 'shadow' -Message "prompt variant $($sv.variant_id) ($($sv.role)) — live A/B vs $vsOther")
            } catch { $shadowTemplate = $null }
        }
    }
    $promptParams = @{ Goal = $Goal; RegistryLines = $RegistryLines }
    if ($shadowTemplate) { $promptParams.Template = $shadowTemplate }
    $prompt = Build-PlannerPrompt @promptParams
```

3d. **`Invoke-Conductor`** — in the plan-phase call, add `-RunDir $RunDir`:

```powershell
            else { Invoke-PlanPhase -Goal $Goal -RunId $runId -BudgetCap $BudgetCap -MaxCostTier $MaxCostTier -FleetPath $FleetPath -ToolsPath $ToolsPath -Dispatcher $Dispatcher -RunDir $RunDir }
```

3e. **`Complete-Run`** — two changes. First, hoist the realized cost: in the effective-cost branch, after `$runCost = Get-RunCost ...`, capture it (add `$realizedRunCost = [double]$runCost.cost`), with `$realizedRunCost = $null` declared next to `$effectiveCost = $null`. Second, insert the accrual block AFTER the `Set-Content ... 'report.md'` line and BEFORE the `return`:

```powershell
    # -- Slice B: live shadow A/B accrual + auto-retire. Strictly after the
    # user-facing report; fail-open — a pool problem never breaks the run. --
    try {
        $shadowPath = Join-Path $RunDir 'shadow.json'
        if (Test-Path $shadowPath) {
            $assign = Get-Content -Raw -LiteralPath $shadowPath | ConvertFrom-Json -AsHashtable
            $poolLoaded = Get-PromptPool
            if (($null -ne $assign) -and $assign.variant_id -and $poolLoaded.ok) {
                $livePool = $poolLoaded.pool
                if ($null -eq $realizedRunCost) {
                    # Ungated run: no effective-cost pass ran, meter here — dollars are real either way.
                    $rc = Get-RunCost -Tasks @($TaskCosts) -CostResolver { param($t) Get-RealizedTaskCost -Task $t -RunDir $RunDir }
                    $realizedRunCost = [double]$rc.cost
                }
                $accrue = @{ Pool = $livePool; VariantId = [string]$assign.variant_id; CostUsd = $realizedRunCost }
                if ($Gate -and $Gate.verdict -and (([string]$Gate.verdict) -in @('accept', 'polish', 'reject'))) {
                    $accrue.Verdict = [string]$Gate.verdict
                }
                [void](Add-LiveRunResult @accrue)
                $sv = Get-ShadowVerdict -Pool $livePool
                if ($sv.state -in @('retire', 'promote')) {
                    $challCpa = if ($null -ne $sv.challenger_cpa) { '{0:n4}' -f [double]$sv.challenger_cpa } else { 'n/a (0 accepts)' }
                    $champCpa = if ($null -ne $sv.champion_cpa) { '{0:n4}' -f [double]$sv.champion_cpa } else { 'n/a (0 accepts)' }
                    if ($sv.state -eq 'retire') {
                        $why = "live A/B loss vs $($sv.champion_id): cost_per_accept $challCpa vs $champCpa over $($sv.challenger_gated)/$($sv.champion_gated) gated runs"
                        [void](Set-CandidateRetired -Pool $livePool -Id ([string]$sv.challenger_id) -Reason $why -By ([string]$sv.champion_id))
                        Add-RunEvent -RunDir $RunDir -EventObj (New-RunEvent -Kind 'shadow' -Level 'warn' -Message "challenger $($sv.challenger_id) auto-retired: $why")
                    } else {
                        Add-RunEvent -RunDir $RunDir -EventObj (New-RunEvent -Kind 'shadow' -Message "challenger $($sv.challenger_id) is winning in dollars (cost_per_accept $challCpa vs $champCpa) — promote via /baton:optimize-prompt --apply")
                    }
                }
                Save-PromptPool -Pool $livePool
            }
        }
    } catch {
        try { Add-RunEvent -RunDir $RunDir -EventObj (New-RunEvent -Kind 'shadow' -Level 'warn' -Message "shadow accrual failed (run unaffected): $($_.Exception.Message)") } catch { }
    }
```

(`$livePool`, not `$pool` — `Complete-Run` has no `$pool` today; keep it that way for grep-ability. Do NOT touch the returned hashtable.)

- [ ] **Step 4: Run tests to verify they pass**

Run: `pwsh -File scripts/test-conductor-lib.ps1`
Expected: all existing T-checks + SB1–SB10 PASS, exit 0.

- [ ] **Step 5: Full regression sweep**

Run: `pwsh -File scripts/test-prompt-pool-lib.ps1`, `pwsh -File scripts/test-optimize-prompt-lib.ps1`, `pwsh -File scripts/test-go.ps1` (if present; skip silently if the repo has no such file)
Expected: all PASS — `/baton:go` behavior without a pool is bit-identical (Resolve-ShadowVariant returns `absent` → no shadow).

- [ ] **Step 6: Commit**

```bash
git add scripts/conductor-lib.ps1 scripts/test-conductor-lib.ps1
git commit -m "feat(conductor): live shadow A/B — assignment in plan phase, cost/verdict accrual + auto-retire in Complete-Run"
```

---

### Task 4: CLI — `-Shadow on|off` kill switch + dollars in the pool report

**Files:**
- Modify: `scripts/fleet-optimize-prompt.ps1`

**Interfaces:**
- Consumes: `Get-PromptPool`, `Save-PromptPool`, `Get-ShadowEnabled`, `Get-ShadowVerdict`, `Get-CostPerAccept` (Task 1).
- Produces: `fleet-optimize-prompt.ps1 -Shadow on|off` and the extended `-Pool` report (live columns + verdict footer). `-Json` pool dump is unchanged (the pool object already carries everything).

- [ ] **Step 1: Add the `-Shadow` parameter**

In the `param(...)` block, after `[switch]$Pool,`:

```powershell
    [ValidateSet('on','off')][string]$Shadow,
```

- [ ] **Step 2: Add the kill-switch handler**

Immediately after the `$ErrorActionPreference`/dot-source lines and BEFORE the `if ($Pool)` block:

```powershell
if ($Shadow) {
    $loaded = Get-PromptPool
    if (-not $loaded.ok) {
        [Console]::Error.WriteLine("Pool unavailable: $($loaded.reason)")
        exit 2
    }
    $loaded.pool.shadow = ($Shadow -eq 'on')
    Save-PromptPool -Pool $loaded.pool
    Write-Host "Shadow A/B is now $($Shadow.ToUpper())."
    exit 0
}
```

- [ ] **Step 3: Extend the `-Pool` report**

Replace the non-Json rendering inside `if ($Pool) { ... }` (everything from `Write-Host "`n## Prompt candidate pool ..."` through the closing `exit 0`) with:

```powershell
    Write-Host "`n## Prompt candidate pool (champion: $($loaded.pool.champion))`n"
    $fmt = "{0,-6} {1,-9} {2,-9} {3,-7} {4,7} {5,6} {6,4} {7,5} {8,4} {9,4} {10,4} {11,8} {12,8} {13,9}"
    Write-Host ($fmt -f 'id', 'status', 'origin', 'parent', 'tokens', 'wr_ch', 'sel', 'runs', 'acc', 'pol', 'rej', 'real$', 'rework$', '$/accept')
    foreach ($c in @($loaded.pool.candidates)) {
        $wr = if ($null -ne $c.offline.minibatch.win_rate_vs_champion) { ('{0:n2}' -f [double]$c.offline.minibatch.win_rate_vs_champion) } else { '-' }
        $par = if ($c.parent) { [string]$c.parent } else { '-' }
        $cpa = Get-CostPerAccept -Live $c.live
        $cpaStr = if ($null -ne $cpa) { ('{0:n2}' -f [double]$cpa) } else { '-' }
        Write-Host ($fmt -f $c.id, $c.status, $c.origin, $par, $c.offline.prompt_tokens, $wr, $c.offline.times_selected, `
            $c.live.runs, $c.live.accept, $c.live.polish, $c.live.reject, `
            ('{0:n2}' -f [double]$c.live.realized_cost_usd), ('{0:n2}' -f [double]$c.live.rework_cost_usd), $cpaStr)
        if (($c.status -eq 'retired') -and $c.retired_reason) {
            $when = if ($c.retired_at) { " $($c.retired_at)" } else { '' }
            $who = if ($c.retired_by) { " by $($c.retired_by)" } else { '' }
            Write-Host ("       retired${when}${who}: " + $c.retired_reason)
        }
    }
    Write-Host ""
    Write-Host ("Shadow A/B: " + $(if (Get-ShadowEnabled -Pool $loaded.pool) { 'ON' } else { 'OFF (--shadow on to enable)' }))
    $sv = Get-ShadowVerdict -Pool $loaded.pool
    switch ($sv.state) {
        'no-challenger' { Write-Host 'Shadow verdict: no active challenger — run an evolution to produce one.' }
        'insufficient'  { Write-Host ("Shadow verdict: insufficient evidence — challenger {0}/{2}, champion {1}/{2} gated runs." -f $sv.challenger_gated, $sv.champion_gated, $sv.threshold) }
        'promote'       { Write-Host ("Shadow verdict: PROMOTE $($sv.challenger_id) — cost/accept {0} vs champion {1}. Run --apply to deploy." -f $(if ($null -ne $sv.challenger_cpa) { '{0:n4}' -f [double]$sv.challenger_cpa } else { 'n/a' }), $(if ($null -ne $sv.champion_cpa) { '{0:n4}' -f [double]$sv.champion_cpa } else { 'n/a (0 accepts)' })) }
        'retire'        { Write-Host ("Shadow verdict: challenger $($sv.challenger_id) is losing in dollars — it will auto-retire on the next gated run.") }
        'stalemate'     { Write-Host 'Shadow verdict: stalemate — no dollars separation at threshold; keep gathering.' }
    }
    exit 0
```

- [ ] **Step 4: Smoke-test hermetically**

```powershell
$prev = $env:BATON_HOME
try {
  $h = Join-Path ([IO.Path]::GetTempPath()) "cli-sb-$([IO.Path]::GetRandomFileName())"
  New-Item -ItemType Directory -Force -Path (Join-Path $h 'prompts') | Out-Null
  $env:BATON_HOME = $h
  Set-Content (Join-Path $h 'prompts/conductor-planner.txt') 'X {{schema}} {{evi}} {{Goal}}' -Encoding utf8NoBOM
  . ./scripts/prompt-pool-lib.ps1
  [void](Initialize-PromptPool -SeedPromptPath (Join-Path $h 'prompts/conductor-planner.txt'))
  pwsh -File scripts/fleet-optimize-prompt.ps1 -Shadow off
  pwsh -File scripts/fleet-optimize-prompt.ps1 -Pool
  pwsh -File scripts/fleet-optimize-prompt.ps1 -Shadow on
} finally { $env:BATON_HOME = $prev }
```

Expected: `Shadow A/B is now OFF.`; the pool table renders with the live columns, `Shadow A/B: OFF (--shadow on to enable)` and `Shadow verdict: no active challenger...`; then `Shadow A/B is now ON.` All exit 0.

- [ ] **Step 5: Regression**

Run: `pwsh -File scripts/test-optimize-prompt-lib.ps1` and `pwsh -File scripts/test-prompt-pool-lib.ps1`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add scripts/fleet-optimize-prompt.ps1
git commit -m "feat(cli): --shadow on|off kill switch + live dollars in the pool report"
```

---

### Task 5: Docs + version bump

**Files:**
- Modify: `commands/optimize-prompt.md` (shadow lifecycle section + `--shadow` flag)
- Modify: `commands/go.md` (one line: runs may carry a `shadow` event)
- Modify: `docs/COMMANDS.md` (cheat row + entry body)
- Modify: `.claude-plugin/plugin.json` (`"version": "1.6.0"` → `"version": "1.7.0-rc.1"`)

- [ ] **Step 1: `commands/optimize-prompt.md`** — add a `--shadow on|off` flag to the flag list (wording: "kill switch for live shadow A/B; ON by default once a gate survivor exists") and append this section before any closing notes:

```markdown
## Live shadow A/B (Slice B)

Once a candidate survives the offline dual gate it becomes the **challenger**:
real `/baton:go` runs alternate champion/challenger (whichever has fewer live
runs takes the run), each run's CostResolver-metered realized cost and
acceptance verdict accrue to the variant that planned it, and every dollar
spent on a `polish`/`reject` run also counts as rework. The decision figure is
**cost per accepted outcome** (`realized_cost_usd / accept`).

At ≥5 gated runs per variant:
- challenger losing in dollars → **auto-retired** (why/when/what-beat-it recorded);
- challenger winning → the pool report says `PROMOTE` — deploying still takes
  your `--apply` (never autonomous).

`--pool` shows the live columns and the current shadow verdict. `--shadow off`
pauses the A/B without touching the pool; `--shadow on` resumes it.
```

- [ ] **Step 2: `commands/go.md`** — add one line in the output/legibility notes:

```markdown
When a prompt challenger is live (see `/baton:optimize-prompt`), the run log
carries a `shadow` event naming which prompt variant planned this run.
```

- [ ] **Step 3: `docs/COMMANDS.md`** — update the cheat row to
`/baton:optimize-prompt [--generations N] [--pool] [--apply] [--shadow on|off]`
and append to that command's entry body a 2–3 sentence summary of the shadow
lifecycle (alternation, cost-per-accept, auto-retire losers, human `--apply`).

- [ ] **Step 4: `.claude-plugin/plugin.json`** — bump `"version"` to `"1.7.0-rc.1"`.

- [ ] **Step 5: Full gate**

Run all four suites: `pwsh -File scripts/test-prompt-pool-lib.ps1`, `pwsh -File scripts/test-optimize-prompt-lib.ps1`, `pwsh -File scripts/test-conductor-lib.ps1`, `pwsh -File scripts/test-bootstrap.ps1`
Expected: all PASS (bootstrap needs no changes — both libs already deploy).

- [ ] **Step 6: Commit**

```bash
git add commands/optimize-prompt.md commands/go.md docs/COMMANDS.md .claude-plugin/plugin.json
git commit -m "docs: shadow A/B lifecycle + plugin 1.7.0-rc.1"
```

---

## Execution handoff (Kevin's standing model split)

- Branch: `feature/optimizer-slice-b` off master.
- **Fable conducts only — never implements inline.** Implementers: Tasks 1, 2, 4, 5 = **haiku** (complete code above — transcription + test runs); Task 3 = **sonnet** (multi-function integration in conductor-lib).
- Streamlined ceremony (Kevin's standing rule for prescriptive plans): skip per-task reviewers; ONE final comprehensive whole-branch review on **opus**, then PR; the human merges.
- Progress ledger: `.superpowers/sdd/progress.md`.
