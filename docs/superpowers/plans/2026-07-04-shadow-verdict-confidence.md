# Shadow-Verdict Statistical Confidence Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

> **BUILD GATE:** d072's revisit condition ("threshold-count evidence
> flip-flops") has NOT yet been observed — zero live A/B verdicts exist.
> This plan is shelf-ready: hold execution until that condition fires,
> unless Kevin explicitly overrides (his named option 2 in the spec is to
> fold it into the next optimizer-adjacent branch since the diff is small).

**Goal:** Guard the live shadow A/B's one autonomous action (challenger auto-retire) with a decisive-margin rule so a single outlier run at n=5 can never retire a candidate on noise, and bound A/B spend with a 12-run cap.

**Architecture:** `Get-ShadowVerdict` (prompt-pool-lib) gains margin logic — retire needs challenger cost-per-accept ≥ 1.25× champion, promote-recommend needs ≤ 0.80×, in-between is a new `undecided` state that keeps accruing until a 12-gated-runs-per-variant cap resolves it to `stalemate` (capped), which the Conductor retires (bounded spend, stop-spending-direction autonomy). `Add-LiveRunResult` starts accruing a per-run `live.runs_cost` array (additive schema, future bootstrap upgrade). The `--pool` footer prints the margin math.

**Tech Stack:** PowerShell 7 (pwsh), house Check/PASS-FAIL test suites, no new dependencies.

**Spec:** `docs/superpowers/specs/2026-07-04-shadow-verdict-confidence-design.md` (d072 revisit).

## Ambiguities resolved (controller decisions, flag to Kevin at review)

1. **Capped stalemate retires the challenger.** The spec's "bounded spend — a mediocre challenger can't A/B forever" only holds if the cap stops the A/B; retirement is the stop-spending direction Baton is allowed to act in alone (d072 policy). `Get-ShadowVerdict` stays a pure read returning `state='stalemate', capped=$true`; the Conductor's action branch does the retiring.
2. **P55/P55a expectations change legitimately.** Equal-CPA and both-null-CPA at 5 gated runs were `stalemate` (terminal) under point-estimate logic; under margin logic they are `undecided` (keep accruing) below the cap. The two existing rows are UPDATED, not broken.
3. **`runs_cost` is appended in `Add-LiveRunResult`,** the single accrual door, not literally in `Complete-Run` — covers every caller and is unit-testable in the pool suite. `Complete-Run` reaches it through the existing call.
4. **coach-lib needs NO change.** `pool_verdict_ready` whitelists `('promote','retire','stalemate')` — `undecided` is excluded by construction, so the coach never nags on it. The existing C32 pool fixture computes as decisive-promote (ratio 0.5) and stays green.

## Global Constraints

- **Additive schema only:** `live.runs_cost` (array of per-run realized USD). Absent field on old pool files reads as empty and is created on next accrual; `schema` stays `1`; NO migration.
- **Constants, not magic numbers:** `$script:ShadowRetireMargin = 1.25`, `$script:ShadowPromoteMargin = 0.80`, `$script:ShadowRunCap = 12` at the top of prompt-pool-lib.ps1 beside `$script:ShadowMinGatedRuns`.
- **Zero-champion-CPA ratio guard:** champion CPA ≤ 0 → no ratio (leave `ratio = $null`), fall back to absolute comparison. Never produce NaN/Infinity (the d060 `0/0` lesson — NaN slips past `-lt`/`-gt`).
- **`undecided` = no autonomous action** anywhere. Retirement fires only on `retire` or capped `stalemate`; promotion stays human `--apply` (d070).
- **Verdict stays a pure read** — `Get-ShadowVerdict` never mutates the pool; callers act.
- House rules: tests hermetic (temp dirs / temp `BATON_HOME` via try/finally, never real `~/.baton` or `~/.claude`); all writes utf8NoBOM; `ConvertFrom-Json` DateTime auto-parse trap (any new date field must be re-stringified in `Get-PromptPool` — this plan adds none); never name PS vars `$args`/`$input`/`$event`/`$matches`/`$host`; CLI errors via `[Console]::Error.WriteLine` + `exit 2`; no shell command arg over 965 bytes; the unary-comma return wrap only on direct-assignment returns (this plan adds none); ASCII `x` not `×` in new console output (codepage lesson).
- Existing rows P50–P54a, P56–P61 and SB1–SB12 must stay green **except** P55/P55a (updated per Ambiguity 2).

---

### Task 1: Margin verdict + `runs_cost` accrual in prompt-pool-lib

**Files:**
- Modify: `scripts/prompt-pool-lib.ps1` (constants block ~line 19; `New-PoolCandidateRecord` live block ~line 88; `Add-LiveRunResult` ~line 294; `Get-ShadowVerdict` ~line 327)
- Test: `scripts/test-prompt-pool-lib.ps1` (update P55/P55a ~line 230; append new rows before the exit block ~line 266)

**Interfaces:**
- Produces: `Get-ShadowVerdict` result gains `ratio` (double|null), `capped` (bool), `retire_margin`, `promote_margin`, `run_cap` fields and the new `undecided` state; `stalemate` now only occurs with `capped = $true` (or defensively). Task 2 and Task 3 consume these exact field names.
- Produces: `live.runs_cost` array on candidate records; `Add-LiveRunResult` appends `[math]::Round($CostUsd, 6)` per call.

- [ ] **Step 1: Add the confidence constants** directly below the existing `$script:ShadowMinGatedRuns = 5` line:

```powershell
# Confidence margins (2026-07-04 spec, d072 revisit): act only on a DECISIVE
# cost-per-accept ratio. Asymmetric on purpose — retirement is autonomous,
# promotion stays human --apply (d070).
$script:ShadowRetireMargin  = 1.25   # auto-retire: challenger cpa >= 1.25x champion
$script:ShadowPromoteMargin = 0.80   # promote-recommend: challenger cpa <= 0.80x champion
$script:ShadowRunCap        = 12     # gated runs/variant; inside-margin at cap -> stalemate (caller retires)
```

- [ ] **Step 2: Seed `runs_cost` in `New-PoolCandidateRecord`** — change the `live` line to:

```powershell
        live = @{ runs = 0; accept = 0; polish = 0; reject = 0; realized_cost_usd = 0.0; rework_cost_usd = 0.0; runs_cost = @() }
```

- [ ] **Step 3: Append per-run cost in `Add-LiveRunResult`** — after the `$live = $hit[0].live` line, insert:

```powershell
    # Additive schema: per-run realized cost list (future bootstrap-confidence
    # upgrade). Old pool files lack the field — create it on first accrual.
    if (-not $live.ContainsKey('runs_cost')) { $live.runs_cost = @() }
    $live.runs_cost = @($live.runs_cost) + @([math]::Round($CostUsd, 6))
```

- [ ] **Step 4: Replace `Get-ShadowVerdict` in full** with:

```powershell
function Get-ShadowVerdict {
    <# The dollars verdict. gated(v) = accept+polish+reject. States:
       no-challenger | insufficient | promote | retire | undecided | stalemate.
       Confidence margins (2026-07-04): act only on a DECISIVE cpa ratio —
       retire needs challenger cpa >= ShadowRetireMargin x champion, promote
       needs <= ShadowPromoteMargin x champion; inside the margins the state
       is 'undecided' (keep alternating) until ShadowRunCap gated runs per
       variant, where it resolves 'stalemate' with capped=true (the caller
       retires the challenger — bounded spend). Zero-champion-cpa falls back
       to absolute comparison (0/0=NaN lesson, d060). Pure read — the caller
       acts (Complete-Run auto-retires; promotion is always human --apply,
       d070). -ChallengerId pins the verdict to the run's ASSIGNED challenger
       (from shadow.json) so dollars are judged against the variant that
       actually ran; assigned-but-gone (retired mid-run) reads as
       no-challenger. #>
    param(
        [Parameter(Mandatory)][hashtable]$Pool,
        [string]$ChallengerId
    )
    $champHit = @($Pool.candidates | Where-Object { $_.id -eq $Pool.champion })
    $chall = $null
    if (-not [string]::IsNullOrEmpty($ChallengerId)) {
        $hit = @($Pool.candidates | Where-Object { ($_.id -eq $ChallengerId) -and ($_.status -eq 'candidate') })
        if (@($hit).Count -gt 0) { $chall = $hit[0] }
    } else {
        $chall = Select-ShadowChallenger -Pool $Pool
    }
    if ((@($champHit).Count -eq 0) -or ($null -eq $chall)) {
        return @{ state = 'no-challenger'; threshold = $script:ShadowMinGatedRuns }
    }
    $champ = $champHit[0]
    $cg = ([int]$champ.live.accept) + ([int]$champ.live.polish) + ([int]$champ.live.reject)
    $hg = ([int]$chall.live.accept) + ([int]$chall.live.polish) + ([int]$chall.live.reject)
    $capped = (($cg -ge $script:ShadowRunCap) -and ($hg -ge $script:ShadowRunCap))
    $verdict = @{
        champion_id = [string]$champ.id; challenger_id = [string]$chall.id
        champion_gated = $cg; challenger_gated = $hg
        champion_cpa = (Get-CostPerAccept -Live $champ.live)
        challenger_cpa = (Get-CostPerAccept -Live $chall.live)
        threshold = $script:ShadowMinGatedRuns
        ratio = $null; capped = $capped
        retire_margin = $script:ShadowRetireMargin
        promote_margin = $script:ShadowPromoteMargin
        run_cap = $script:ShadowRunCap
    }
    if (($cg -lt $script:ShadowMinGatedRuns) -or ($hg -lt $script:ShadowMinGatedRuns)) {
        $verdict.state = 'insufficient'
        return $verdict
    }
    $cc = $verdict.champion_cpa
    $hc = $verdict.challenger_cpa
    $inside = if ($capped) { 'stalemate' } else { 'undecided' }
    if (($null -eq $cc) -and ($null -eq $hc)) { $verdict.state = $inside }
    elseif ($null -eq $hc) { $verdict.state = 'retire' }     # 0 challenger accepts vs some: infinitely worse
    elseif ($null -eq $cc) { $verdict.state = 'promote' }    # 0 champion accepts vs some: infinitely better
    else {
        $ccD = [double]$cc; $hcD = [double]$hc
        if ($ccD -le 0.0) {
            # Zero-champion-cpa guard: ratio undefined; absolute comparison.
            if ($hcD -gt $ccD) { $verdict.state = 'retire' }
            elseif ($hcD -lt $ccD) { $verdict.state = 'promote' }
            else { $verdict.state = $inside }
        } else {
            $verdict.ratio = [math]::Round($hcD / $ccD, 4)
            if ($verdict.ratio -ge $script:ShadowRetireMargin) { $verdict.state = 'retire' }
            elseif ($verdict.ratio -le $script:ShadowPromoteMargin) { $verdict.state = 'promote' }
            else { $verdict.state = $inside }
        }
    }
    return $verdict
}
```

- [ ] **Step 5: Update P55/P55a** in `scripts/test-prompt-pool-lib.ps1` (both fixtures are now inside-margin below the cap):

```powershell
$vStale = Get-ShadowVerdict -Pool (New-VerdictPool @(5,0,3,2,1.0,1.0) @(5,0,4,1,1.0,1.0))
Check 'P55 both 0 accepts at threshold -> undecided (below cap)' ($vStale.state -eq 'undecided')
$vEq = Get-ShadowVerdict -Pool (New-VerdictPool @(5,4,1,0,1.0,0.1) @(5,4,1,0,1.0,0.1))
Check 'P55a equal cost per accept -> undecided (inside margins)' ($vEq.state -eq 'undecided')
```

- [ ] **Step 6: Append the new rows** immediately before the `if ($script:fail -gt 0)` exit block (Set-TestLive arg order after the record: runs accept polish reject cost rework):

```powershell
# ---- Confidence margins (2026-07-04): undecided + run cap + ratio ----
$vUnd = Get-ShadowVerdict -Pool (New-VerdictPool @(5,4,1,0,1.0,0.1) @(5,4,1,0,1.1,0.1))
Check 'P62 inside-margin at threshold -> undecided with ratio' (($vUnd.state -eq 'undecided') -and ($vUnd.ratio -eq 1.1) -and (-not $vUnd.capped))
$vB1 = Get-ShadowVerdict -Pool (New-VerdictPool @(5,4,1,0,1.0,0.1) @(5,4,1,0,1.25,0.1))
Check 'P63 exactly 1.25x -> retire (boundary inclusive)' ($vB1.state -eq 'retire')
$vB2 = Get-ShadowVerdict -Pool (New-VerdictPool @(5,4,1,0,1.0,0.1) @(5,4,1,0,0.8,0.1))
Check 'P64 exactly 0.80x -> promote (boundary inclusive)' ($vB2.state -eq 'promote')
$vCap = Get-ShadowVerdict -Pool (New-VerdictPool @(12,10,1,1,2.5,0.3) @(12,10,1,1,2.75,0.3))
Check 'P65 inside-margin at 12/12 -> stalemate, capped' (($vCap.state -eq 'stalemate') -and ($vCap.capped) -and ($vCap.ratio -eq 1.1))
$vZero = Get-ShadowVerdict -Pool (New-VerdictPool @(5,4,1,0,0.0,0.0) @(5,4,1,0,0.5,0.1))
Check 'P66 zero-champion-cpa -> absolute fallback retire, no ratio' (($vZero.state -eq 'retire') -and ($null -eq $vZero.ratio))
$vZero2 = Get-ShadowVerdict -Pool (New-VerdictPool @(5,5,0,0,0.0,0.0) @(5,5,0,0,0.0,0.0))
Check 'P67 both-zero cpa below cap -> undecided' ($vZero2.state -eq 'undecided')
$vMeta = Get-ShadowVerdict -Pool (New-VerdictPool @(5,4,1,0,1.0,0.1) @(3,2,1,0,0.5,0.1))
Check 'P70 verdict carries margin + cap metadata on every non-trivial state' (($vMeta.state -eq 'insufficient') -and ($vMeta.run_cap -eq 12) -and ($vMeta.retire_margin -eq 1.25) -and ($vMeta.promote_margin -eq 0.8))

# ---- live.runs_cost accrual (additive schema) ----
$rcPool = @{ schema = 1; champion = 'p001'; candidates = @((New-TestCand 'p001' 'champion' 0.5 100)) }
Check 'P68a new records carry empty runs_cost' ((@($rcPool.candidates[0].live.runs_cost)).Count -eq 0)
[void](Add-LiveRunResult -Pool $rcPool -VariantId 'p001' -CostUsd 0.25 -Verdict accept)
[void](Add-LiveRunResult -Pool $rcPool -VariantId 'p001' -CostUsd 0.5)
$rcArr = @($rcPool.candidates[0].live.runs_cost)
Check 'P68 runs_cost appends per accrual in order' (($rcArr.Count -eq 2) -and (([double]$rcArr[0]) -eq 0.25) -and (([double]$rcArr[1]) -eq 0.5))
$legacy = New-TestCand 'p001' 'champion' 0.5 100
$legacy.live.Remove('runs_cost')
$lgPool = @{ schema = 1; champion = 'p001'; candidates = @($legacy) }
[void](Add-LiveRunResult -Pool $lgPool -VariantId 'p001' -CostUsd 0.1 -Verdict polish)
Check 'P69 legacy record without runs_cost tolerated (created on accrual)' ((@($lgPool.candidates[0].live.runs_cost)).Count -eq 1)
$rcDir = New-TempDir
$rcSeed = Join-Path $rcDir 'seed.txt'
Set-Content -LiteralPath $rcSeed -Value 'S {{schema}} {{evi}} {{Goal}}' -Encoding utf8NoBOM
$rcPoolDir = Join-Path $rcDir 'pool'
[void](Initialize-PromptPool -SeedPromptPath $rcSeed -PoolDir $rcPoolDir)
$rcP = (Get-PromptPool -PoolDir $rcPoolDir).pool
[void](Add-LiveRunResult -Pool $rcP -VariantId 'p001' -CostUsd 0.33 -Verdict accept)
Save-PromptPool -Pool $rcP -PoolDir $rcPoolDir
$rcP2 = (Get-PromptPool -PoolDir $rcPoolDir).pool
$rcArr2 = @($rcP2.candidates[0].live.runs_cost)
Check 'P71 runs_cost survives save/load round-trip' (($rcArr2.Count -eq 1) -and (([double]$rcArr2[0]) -eq 0.33))
```

(Fixture arithmetic, pre-verified: P62 cpa 0.275/0.25 = ratio 1.1; P63 0.3125/0.25 = 1.25; P64 0.2/0.25 = 0.8; P65 0.275/0.25 = 1.1 at 12/12 gated; P66 champion cpa computes to 0 — `Get-CostPerAccept` returns 0, not null, when accepts > 0 and cost is 0.)

- [ ] **Step 7: Run the pool suite**

Run: `pwsh -NoProfile -File scripts/test-prompt-pool-lib.ps1`
Expected: `All checks passed.` exit 0 (P1–P71, including updated P55/P55a and untouched P56–P61).

- [ ] **Step 8: Commit**

```bash
git add scripts/prompt-pool-lib.ps1 scripts/test-prompt-pool-lib.ps1
git commit -m "feat(pool): decisive-margin shadow verdict (undecided + run cap) + live.runs_cost accrual"
```

---

### Task 2: Conductor honors `undecided` (no act) and retires at the capped stalemate

**Files:**
- Modify: `scripts/conductor-lib.ps1` (the Slice-B accrual block in `Complete-Run`, ~lines 451–467)
- Test: `scripts/test-conductor-lib.ps1` (append SB13/SB14 after SB12 ~line 426, inside the existing `try` before its `finally`)

**Interfaces:**
- Consumes: `Get-ShadowVerdict` fields from Task 1 (`state`, `capped`, `ratio`, `challenger_gated`, `champion_gated`, `challenger_id`, `champion_id`).
- Produces: retirement reason string starting `live A/B stalemate at run cap:` (Task 3's docs reference it).

- [ ] **Step 1: Extend the verdict-action branch.** In `Complete-Run`, the existing block reads `if ($sv.state -in @('retire', 'promote')) { ... }`. Add an `elseif` between its closing brace and the `Save-PromptPool` line:

```powershell
                } elseif (($sv.state -eq 'stalemate') -and $sv.capped) {
                    # Run cap reached with no decisive margin: stop spending on
                    # this A/B (the stop-spending-only autonomy direction) —
                    # a mediocre challenger cannot alternate forever.
                    $capRatio = if ($null -ne $sv.ratio) { '{0:n2}x' -f [double]$sv.ratio } else { 'n/a' }
                    $why = "live A/B stalemate at run cap: cpa ratio $capRatio inside margins after $($sv.challenger_gated)/$($sv.champion_gated) gated runs"
                    [void](Set-CandidateRetired -Pool $livePool -Id ([string]$sv.challenger_id) -Reason $why -By ([string]$sv.champion_id))
                    Add-RunEvent -RunDir $RunDir -EventObj (New-RunEvent -Kind 'shadow' -Level 'warn' -Message "challenger $($sv.challenger_id) retired at run cap: $why")
                }
```

`undecided` needs no code change — it is not in `@('retire','promote')` and not the capped stalemate, so the branch falls through to `Save-PromptPool` (accrual persists, no action). SB13 pins that behavior.

- [ ] **Step 2: Append SB13 + SB14** after the SB12 check (still inside the `try`, before `} finally { $env:BATON_HOME = $sbPrevHome }`). Reuses `$sbGate` (accept), `Initialize-RunDir`, `$sbHome`, `$sbPoolDir` from the existing SB section:

```powershell
        # SB13: undecided (inside decisive margins) -> NO autonomous action.
        $sbP6 = @{ schema = 1; champion = 'p001'; candidates = @() }
        $sbU1 = New-PoolCandidateRecord -Id 'p001' -Parent $null -Origin 'seed' -Status 'champion' -PromptTokens 12
        $sbU1.offline.minibatch.win_rate_vs_champion = 0.5
        $sbU1.live = @{ runs = 6; accept = 5; polish = 1; reject = 0; realized_cost_usd = 1.0; rework_cost_usd = 0.1 }
        $sbU2 = New-PoolCandidateRecord -Id 'p002' -Parent 'p001' -Origin 'mutation' -Status 'candidate' -PromptTokens 10
        $sbU2.offline.minibatch.win_rate_vs_champion = 0.8
        $sbU2.live = @{ runs = 6; accept = 5; polish = 1; reject = 0; realized_cost_usd = 1.05; rework_cost_usd = 0.1 }
        $sbP6.candidates = @($sbU1, $sbU2)
        Save-PromptPool -Pool $sbP6 -PoolDir $sbPoolDir
        $sbRun10 = Initialize-RunDir -RunId 'go-sb-10' -Root (Join-Path $sbHome 'runs')
        @{ variant_id = 'p002'; role = 'challenger'; challenger_id = 'p002'; assigned = '2026-07-04T00:00:00Z' } |
            ConvertTo-Json | Set-Content -LiteralPath (Join-Path $sbRun10 'shadow.json') -Encoding utf8NoBOM
        [void](Complete-Run -RunDir $sbRun10 -Plan @{ run_id = 'go-sb-10'; goal = 'g'; budget_cap = $null; tasks = @() } -Gate $sbGate -TaskCosts @(@{ id = 't1'; worker = 'stub'; cost = 0.10 }))
        $sbAfter10 = (Get-PromptPool -PoolDir $sbPoolDir).pool
        $sbU2b = @($sbAfter10.candidates | Where-Object { $_.id -eq 'p002' })[0]
        $sbEv10Path = Join-Path $sbRun10 'events.jsonl'
        $sbEv10 = if (Test-Path $sbEv10Path) { Get-Content -LiteralPath $sbEv10Path | ForEach-Object { $_ | ConvertFrom-Json } } else { @() }
        Check 'SB13a undecided: challenger untouched (no retire, no nudge)' `
            (($sbU2b.status -eq 'candidate') -and ($null -eq $sbU2b.promote_recommended_at))
        Check 'SB13b undecided: no autonomous shadow action events' `
            (@($sbEv10 | Where-Object { ($_.kind -eq 'shadow') -and ($_.message -match 'auto-retired|promote via|retired at run cap') }).Count -eq 0)
        Check 'SB13c accrual appended runs_cost (legacy live tolerated)' ((@($sbU2b.live.runs_cost)).Count -eq 1)

        # SB14: run cap reached inside margins -> capped stalemate retires (bounded spend).
        $sbP7 = @{ schema = 1; champion = 'p001'; candidates = @() }
        $sbV1 = New-PoolCandidateRecord -Id 'p001' -Parent $null -Origin 'seed' -Status 'champion' -PromptTokens 12
        $sbV1.offline.minibatch.win_rate_vs_champion = 0.5
        $sbV1.live = @{ runs = 12; accept = 10; polish = 1; reject = 1; realized_cost_usd = 2.0; rework_cost_usd = 0.3 }
        $sbV2 = New-PoolCandidateRecord -Id 'p002' -Parent 'p001' -Origin 'mutation' -Status 'candidate' -PromptTokens 10
        $sbV2.offline.minibatch.win_rate_vs_champion = 0.8
        $sbV2.live = @{ runs = 11; accept = 9; polish = 1; reject = 1; realized_cost_usd = 1.89; rework_cost_usd = 0.2 }
        $sbP7.candidates = @($sbV1, $sbV2)
        Save-PromptPool -Pool $sbP7 -PoolDir $sbPoolDir
        $sbRun11 = Initialize-RunDir -RunId 'go-sb-11' -Root (Join-Path $sbHome 'runs')
        @{ variant_id = 'p002'; role = 'challenger'; challenger_id = 'p002'; assigned = '2026-07-04T00:00:00Z' } |
            ConvertTo-Json | Set-Content -LiteralPath (Join-Path $sbRun11 'shadow.json') -Encoding utf8NoBOM
        [void](Complete-Run -RunDir $sbRun11 -Plan @{ run_id = 'go-sb-11'; goal = 'g'; budget_cap = $null; tasks = @() } -Gate $sbGate -TaskCosts @(@{ id = 't1'; worker = 'stub'; cost = 0.10 }))
        $sbAfter11 = (Get-PromptPool -PoolDir $sbPoolDir).pool
        $sbV2b = @($sbAfter11.candidates | Where-Object { $_.id -eq 'p002' })[0]
        $sbEv11 = Get-Content -LiteralPath (Join-Path $sbRun11 'events.jsonl') | ForEach-Object { $_ | ConvertFrom-Json }
        Check 'SB14a capped stalemate: challenger retired with cap provenance' `
            (($sbV2b.status -eq 'retired') -and ($sbV2b.retired_reason -match 'stalemate at run cap') -and ($sbV2b.retired_by -eq 'p001'))
        Check 'SB14b cap retirement logged as warn shadow event' `
            (@($sbEv11 | Where-Object { ($_.kind -eq 'shadow') -and ($_.level -eq 'warn') -and ($_.message -match 'run cap') }).Count -ge 1)
```

(Fixture arithmetic, pre-verified: SB13 — this run accrues +1 accept/+0.10 to p002 → cpa 1.15/6 ≈ 0.1917 vs champion 1.0/5 = 0.2 → ratio 0.9585, gated 7 vs 6, below cap → `undecided`. SB14 — accrual makes p002 12 gated, cpa 1.99/10 = 0.199 vs champion 0.2 → ratio 0.995, both at 12 → capped stalemate → retire.)

- [ ] **Step 3: Run the conductor suite**

Run: `pwsh -NoProfile -File scripts/test-conductor-lib.ps1`
Expected: `ALL CHECKS PASS` exit 0 (T-series + SB1–SB14).

- [ ] **Step 4: Commit**

```bash
git add scripts/conductor-lib.ps1 scripts/test-conductor-lib.ps1
git commit -m "feat(conductor): honor undecided shadow verdict; retire challenger at capped stalemate"
```

---

### Task 3: `--pool` footer margin math, docs, regression sweep

**Files:**
- Modify: `scripts/fleet-optimize-prompt.ps1` (the `switch ($sv.state)` block in the `-Pool` branch, ~lines 70–80)
- Modify: `commands/optimize-prompt.md` (verdict-states documentation)

**Interfaces:**
- Consumes: verdict fields `ratio`, `capped`, `promote_margin`, `retire_margin`, `challenger_gated`, `run_cap` (Task 1).

- [ ] **Step 1: Add the `undecided` case and replace the `stalemate` case** in the `switch ($sv.state)` block (leave `no-challenger`, `insufficient`, `promote`, `retire` untouched):

```powershell
        'undecided'     {
            $udRatio = if ($null -ne $sv.ratio) { ('{0:n2}x' -f [double]$sv.ratio) } else { 'n/a' }
            Write-Host ("Shadow verdict: UNDECIDED — challenger cpa {0} champion, inside decisive margins [{1:n2}x, {2:n2}x] — {3}/{4} gated runs, accruing." -f $udRatio, [double]$sv.promote_margin, [double]$sv.retire_margin, [int]$sv.challenger_gated, [int]$sv.run_cap)
        }
        'stalemate'     {
            if ($sv.capped) { Write-Host ("Shadow verdict: stalemate at the {0}-run cap — no decisive margin; challenger {1} auto-retires on the next gated run." -f [int]$sv.run_cap, $sv.challenger_id) }
            else { Write-Host 'Shadow verdict: stalemate — no dollars separation at threshold; keep gathering.' }
        }
```

(Multiplication sign is ASCII `x`, never `×` — console-codepage lesson. The em-dashes match the existing lines in this file, which already ship them.)

- [ ] **Step 2: Update `commands/optimize-prompt.md`.** Find the section documenting `--pool` / shadow verdict states and replace its state list with the following (if no such list exists, append this block to the `--pool` section):

```markdown
**Shadow verdict states (`--pool` footer):**

- `no-challenger` — no active scored candidate to A/B.
- `insufficient` — below 5 gated runs per variant; keep running `/baton:go`.
- `undecided` — enough runs, but the challenger/champion cost-per-accept
  ratio is inside the decisive margins `[0.80x, 1.25x]`. The A/B keeps
  alternating, up to 12 gated runs per variant. No autonomous action.
- `promote` — challenger cpa <= 0.80x champion: decisive win. Promotion
  still requires human `--apply` (one-shot nudge event fires).
- `retire` — challenger cpa >= 1.25x champion: decisive loss. The
  challenger auto-retires on the next gated run.
- `stalemate` — the 12-run cap was reached with no decisive margin; the
  challenger auto-retires (a mediocre challenger cannot A/B forever).

Retirement demands a wider margin than promotion on purpose: retiring is
autonomous (stop-spending direction), promotion stays human. Each variant
also accrues `live.runs_cost` (per-run realized dollars) — schema-additive
groundwork for a future bootstrap-confidence upgrade.
```

- [ ] **Step 3: Full regression sweep** (verdict-shape consumers included):

Run, each expecting exit 0:
```
pwsh -NoProfile -File scripts/test-prompt-pool-lib.ps1
pwsh -NoProfile -File scripts/test-optimize-prompt-lib.ps1
pwsh -NoProfile -File scripts/test-conductor-lib.ps1
pwsh -NoProfile -File scripts/test-coach-lib.ps1
pwsh -NoProfile -File scripts/test-coach-footers.ps1
pwsh -NoProfile -File scripts/test-baton-coach-hook.ps1
pwsh -NoProfile -File scripts/test-bootstrap.ps1
```
(coach suites matter: `Get-CoachContext` calls `Get-ShadowVerdict`; its C32 fixture computes ratio 0.5 → decisive promote → still `pool_verdict_ready`. `undecided` is excluded from `pool_verdict_ready` by the existing whitelist — no coach change.)

- [ ] **Step 4: Manual footer check** (no CLI-rendering harness exists for `--pool`; matches v1.7.x precedent of smoke verification). With a temp `BATON_HOME` containing a fixture pool at an inside-margin state, run `pwsh scripts/fleet-optimize-prompt.ps1 -Pool` and confirm the UNDECIDED line prints the ratio, margins, and `N/12` count. Do NOT touch the real `~/.baton`.

- [ ] **Step 5: Commit**

```bash
git add scripts/fleet-optimize-prompt.ps1 commands/optimize-prompt.md
git commit -m "feat(optimize-prompt): --pool margin math footer (undecided/capped stalemate) + verdict docs"
```

---

## Execution Handoff

Branch: `feature/shadow-verdict-confidence` off master. **Respect the BUILD GATE in the header** — execute only on Kevin's word.

Subagent-driven per Kevin's ladder, streamlined ceremony (no per-task reviewers):
- **Task 1 — haiku** (transcription-grade: complete code above).
- **Task 2 — haiku** (transcription-grade; fixture arithmetic pre-verified).
- **Task 3 — haiku** (footer + docs + sweep).
- **Final whole-branch review — opus**, then PR; merge stays human-gated.

No plugin version bump in this plan — release packaging is decided at build time (this slice may ride an optimizer-adjacent branch per the spec's fork 2).

No decision record needed beyond the spec (d072's revisit executed); capture one only if Kevin overrides an ambiguity resolution above.
