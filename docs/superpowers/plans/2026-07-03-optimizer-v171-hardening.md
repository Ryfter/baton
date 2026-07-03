# Optimizer v1.7.1 Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close v1.7.0's three loose ends — stale-candidate re-scoring after champion swaps, shadow-verdict attribution to the assigned challenger, and a one-shot PROMOTE nudge.

**Architecture:** Three surgical changes to the existing GEPA/shadow stack: a re-score pass at the top of `Invoke-PromptEvolution` (spend stays in explicit optimize-prompt runs), an optional `-ChallengerId` on `Get-ShadowVerdict` fed from `shadow.json` in `Complete-Run`, and an additive `promote_recommended_at` stamp. Spec: `docs/superpowers/specs/2026-07-03-optimizer-v171-hardening-design.md`.

**Tech Stack:** PowerShell 7, house Check/PASS-FAIL test suites, no new dependencies.

## Global Constraints

- Branch: `feature/optimizer-v171-hardening` off `master`.
- Every shell command argument stays under 965 bytes (silent failure above).
- `[Console]::Error.WriteLine` + skip/exit 2 for error reporting — NEVER `Write-Error` (throws under `$ErrorActionPreference = 'Stop'`).
- All file writes use `-Encoding utf8NoBOM`.
- Unary-comma array flatten only on direct-assignment returns; use `@()` wrapping inside hashtable literals.
- `[AllowNull()][string]` params coerce `$null` → `''`; normalize back to `$null` where JSON null matters.
- Tests are hermetic: temp dirs only; any `$env:BATON_HOME` swap uses `try { … } finally { restore }`; never touch the real `~/.baton` or `~/.claude`.
- Fail-open on the `/baton:go` path: all `Complete-Run` changes stay inside the existing accrual `try/catch`; a pool problem never breaks a run.
- `ConvertFrom-Json -AsHashtable` auto-parses ISO8601 strings to `[datetime]` — every new timestamp field must be re-stringified in `Get-PromptPool` (`yyyy-MM-ddTHH:mm:ssZ`).
- Schema stays 1; all pool-record additions are additive with `$null` defaults (zero migration). Old records may LACK the new key — hashtable access of a missing key reads `$null`, which is the correct semantic; never assume the key exists.
- Promotion authority unchanged: promote is always human `--apply` (d070/d072). Nothing in this plan touches `pool.champion` or the live prompt on the run path.
- Never name PS variables `$args`/`$input`/`$event`/`$matches`/`$host`.

---

### Task 1: Pool primitives — `-ChallengerId` verdict override + `promote_recommended_at` field

**Files:**
- Modify: `scripts/prompt-pool-lib.ps1`
- Test: `scripts/test-prompt-pool-lib.ps1`

**Interfaces:**
- Consumes: existing `Get-ShadowVerdict`, `New-PoolCandidateRecord`, `Get-PromptPool` (all in the same file).
- Produces: `Get-ShadowVerdict -Pool <hashtable> [-ChallengerId <string>]` — when `-ChallengerId` is a non-empty string, the verdict evaluates exactly that candidate (it must exist with `status -eq 'candidate'`, else `state='no-challenger'`); empty/absent keeps today's `Select-ShadowChallenger` behavior. New per-candidate field `promote_recommended_at` (`$null` default, ISO8601 `…Z` string when stamped). Task 3 consumes both.

- [ ] **Step 1: Write the failing tests**

Append to `scripts/test-prompt-pool-lib.ps1` immediately after the `P55a` Check (before the final `if ($script:fail -gt 0)` block):

```powershell
# ---- v1.7.1: promote_recommended_at field + round-trip ----
Check 'P56 new records carry promote_recommended_at null' ($null -eq (New-TestCand 'p011' 'candidate' 0.5 10).promote_recommended_at)
$prDir = New-TempDir
$prSeed = Join-Path $prDir 'seed.txt'
Set-Content -LiteralPath $prSeed -Value 'S {{schema}} {{evi}} {{Goal}}' -Encoding utf8NoBOM
$prPool = Join-Path $prDir 'pool'
[void](Initialize-PromptPool -SeedPromptPath $prSeed -PoolDir $prPool)
$prP = (Get-PromptPool -PoolDir $prPool).pool
$prP.candidates[0].promote_recommended_at = '2026-07-03T01:02:03Z'
Save-PromptPool -Pool $prP -PoolDir $prPool
$prP2 = (Get-PromptPool -PoolDir $prPool).pool
Check 'P57 promote_recommended_at survives round-trip as Z string (DateTime trap)' (($prP2.candidates[0].promote_recommended_at -is [string]) -and ($prP2.candidates[0].promote_recommended_at -match 'Z$'))

# ---- v1.7.1: Get-ShadowVerdict -ChallengerId (assigned-challenger attribution) ----
function New-AttribPool {
    $ch = Set-TestLive (New-TestCand 'p001' 'champion' 0.5 100) 5 4 1 0 1.0 0.2
    $as = Set-TestLive (New-TestCand 'p002' 'candidate' 0.6 90) 5 1 2 2 3.0 2.5
    $nw = New-TestCand 'p003' 'candidate' 0.9 80   # newer, higher wr, 0 gated runs
    return @{ schema = 1; champion = 'p001'; candidates = @($ch, $as, $nw) }
}
$vAssign = Get-ShadowVerdict -Pool (New-AttribPool) -ChallengerId 'p002'
Check 'P58 -ChallengerId pins the verdict to the assigned candidate' (($vAssign.challenger_id -eq 'p002') -and ($vAssign.state -eq 'retire'))
$vDefault = Get-ShadowVerdict -Pool (New-AttribPool)
Check 'P59 no -ChallengerId keeps highest-wr selection' (($vDefault.challenger_id -eq 'p003') -and ($vDefault.state -eq 'insufficient'))
$goneAttrib = New-AttribPool
[void](Set-CandidateRetired -Pool $goneAttrib -Id 'p002' -Reason 'x')
$vGone = Get-ShadowVerdict -Pool $goneAttrib -ChallengerId 'p002'
Check 'P60 assigned challenger no longer active -> no-challenger (no action)' ($vGone.state -eq 'no-challenger')
$vEmptyId = Get-ShadowVerdict -Pool (New-AttribPool) -ChallengerId ''
Check 'P61 empty -ChallengerId degrades to selection path' ($vEmptyId.challenger_id -eq 'p003')
```

- [ ] **Step 2: Run to verify the new checks fail**

Run: `pwsh -NoProfile -File scripts/test-prompt-pool-lib.ps1`
Expected: P56 FAILS (field missing); P58/P60 FAIL (parameter not found causes an error — the suite's top-level behavior on a binding error is a thrown exception; that still counts as "red").

- [ ] **Step 3: Implement**

In `scripts/prompt-pool-lib.ps1`, three edits:

(a) `New-PoolCandidateRecord` — add the field after `retired_by = $null`:

```powershell
        retired_reason = $null
        retired_at = $null
        retired_by = $null
        promote_recommended_at = $null
```

(b) `Get-PromptPool` — extend the re-stringify loop with one line after the `retired_at` line:

```powershell
            if (($c.retired_at -is [datetime])) { $c.retired_at = $c.retired_at.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') }
            if (($c.promote_recommended_at -is [datetime])) { $c.promote_recommended_at = $c.promote_recommended_at.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') }
```

(c) `Get-ShadowVerdict` — replace the param block and the challenger selection (the doc comment gains one sentence). Replace:

```powershell
    param([Parameter(Mandatory)][hashtable]$Pool)
    $champHit = @($Pool.candidates | Where-Object { $_.id -eq $Pool.champion })
    $chall = Select-ShadowChallenger -Pool $Pool
```

with:

```powershell
    param(
        [Parameter(Mandatory)][hashtable]$Pool,
        [string]$ChallengerId
    )
    $champHit = @($Pool.candidates | Where-Object { $_.id -eq $Pool.champion })
    # -ChallengerId pins the verdict to the run's ASSIGNED challenger (from
    # shadow.json) so dollars are judged against the variant that actually
    # ran; assigned-but-gone (retired mid-run) reads as no-challenger.
    $chall = $null
    if (-not [string]::IsNullOrEmpty($ChallengerId)) {
        $hit = @($Pool.candidates | Where-Object { ($_.id -eq $ChallengerId) -and ($_.status -eq 'candidate') })
        if (@($hit).Count -gt 0) { $chall = $hit[0] }
    } else {
        $chall = Select-ShadowChallenger -Pool $Pool
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `pwsh -NoProfile -File scripts/test-prompt-pool-lib.ps1`
Expected: `All checks passed.`, exit 0 (P1–P61).

- [ ] **Step 5: Regression — the other pool consumers**

Run: `pwsh -NoProfile -File scripts/test-optimize-prompt-lib.ps1` and `pwsh -NoProfile -File scripts/test-conductor-lib.ps1`
Expected: `ALL CHECKS PASS`, exit 0 on both.

- [ ] **Step 6: Commit**

```bash
git add scripts/prompt-pool-lib.ps1 scripts/test-prompt-pool-lib.ps1
git commit -m "feat(pool): assigned-challenger verdict override + promote_recommended_at field (v1.7.1)"
```

---

### Task 2: Stale-candidate re-scoring in `Invoke-PromptEvolution`

**Files:**
- Modify: `scripts/optimize-prompt-lib.ps1`
- Test: `scripts/test-optimize-prompt-lib.ps1`

**Interfaces:**
- Consumes: existing `Invoke-MinibatchEval`, `Get-PromptPool`/`Save-PromptPool` (already dot-sourced via prompt-pool-lib).
- Produces: `Invoke-PromptEvolution` return hashtable gains `rescored = @(@{ id = <string>; win_rate = <double|null> }, …)` (empty array when nothing was stale) on EVERY return path. Task 4's runner prints it.

- [ ] **Step 1: Write the failing tests**

In `scripts/test-optimize-prompt-lib.ps1`, insert after the `E13b` Check (before the `# ---- E14/E15` comment):

```powershell
    # ---- E16/E17: stale-candidate re-scoring (v1.7.1) ----
    $fx9 = New-EvoFixture
    $env:BATON_HOME = $fx9.root
    [void](Invoke-PromptEvolution -PromptPath $fx9.live -PoolDir $fx9.pool `
        -ReflectDispatcher $okReflect -MutateDispatcher $okMutate `
        -PlanDispatcher $echoPlan2 -JudgeDispatcher $judgeBetter -Draw { param($t) 0.0 })
    $pool9 = (Get-PromptPool -PoolDir $fx9.pool).pool
    $st9 = @($pool9.candidates | Where-Object { $_.id -eq 'p002' })[0]
    $st9.offline.minibatch.win_rate_vs_champion = $null   # simulate post-swap staleness
    Save-PromptPool -Pool $pool9 -PoolDir $fx9.pool
    $failReflect9 = { param($p) @{ stdout = ''; exit_code = 1 } }
    $ev9 = Invoke-PromptEvolution -PromptPath $fx9.live -PoolDir $fx9.pool `
        -ReflectDispatcher $failReflect9 -MutateDispatcher $okMutate `
        -PlanDispatcher $echoPlan2 -JudgeDispatcher $judgeBetter -Draw { param($t) 0.0 }
    $pool9b = (Get-PromptPool -PoolDir $fx9.pool).pool
    $st9b = @($pool9b.candidates | Where-Object { $_.id -eq 'p002' })[0]
    Check 'E16a stale candidate re-scored vs current champion at run start' (([double]$st9b.offline.minibatch.win_rate_vs_champion) -eq 1.0)
    Check 'E16b rescored contract names the candidate' ((@($ev9.rescored).Count -eq 1) -and (@($ev9.rescored)[0].id -eq 'p002'))
    Check 'E16c re-score persisted even though the generation failed' ((-not $ev9.success) -and ($null -ne $st9b.offline.minibatch.win_rate_vs_champion))

    # E17: unreadable stale-candidate file is skipped without aborting the run.
    $pool9c = (Get-PromptPool -PoolDir $fx9.pool).pool
    $st9c = @($pool9c.candidates | Where-Object { $_.id -eq 'p002' })[0]
    $st9c.offline.minibatch.win_rate_vs_champion = $null
    Save-PromptPool -Pool $pool9c -PoolDir $fx9.pool
    Remove-Item -LiteralPath (Join-Path $fx9.pool 'p002.txt') -Force
    $ev10 = Invoke-PromptEvolution -PromptPath $fx9.live -PoolDir $fx9.pool `
        -ReflectDispatcher $failReflect9 -MutateDispatcher $okMutate `
        -PlanDispatcher $echoPlan2 -JudgeDispatcher $judgeBetter -Draw { param($t) 0.0 }
    $pool9d = (Get-PromptPool -PoolDir $fx9.pool).pool
    $st9d = @($pool9d.candidates | Where-Object { $_.id -eq 'p002' })[0]
    Check 'E17 unreadable stale file skipped: candidate stays stale, not in rescored' (
        ($null -eq $st9d.offline.minibatch.win_rate_vs_champion) -and (@($ev10.rescored | Where-Object { $null -ne $_ }).Count -eq 0)
    )
```

- [ ] **Step 2: Run to verify the new checks fail**

Run: `pwsh -NoProfile -File scripts/test-optimize-prompt-lib.ps1`
Expected: E16a/E16b FAIL (no re-scoring, no `rescored` key).

- [ ] **Step 3: Implement**

In `scripts/optimize-prompt-lib.ps1`, inside `Invoke-PromptEvolution`:

(a) Make the `rescored` accumulator visible to every return path. Replace:

```powershell
    $fail = { param($reason, $gens)
        @{ success = $false; applied = $false; candidate_path = $null; reason = $reason; generations = @($gens) }
    }
```

with:

```powershell
    $rescored = [System.Collections.ArrayList]@()
    $fail = { param($reason, $gens)
        @{ success = $false; applied = $false; candidate_path = $null; reason = $reason; generations = @($gens); rescored = @($rescored) }
    }
```

(`& $fail` runs in a child scope of the function, so `$rescored` resolves via dynamic scoping — the array is defined before every `& $fail` call site.)

(b) Insert the re-score pass AFTER the four default-dispatcher lines (the `if (-not $JudgeDispatcher) …` line) and BEFORE the `$seedRec = …` line:

```powershell
    # -- v1.7.1: re-score stale actives (win rate nulled by a champion swap)
    # against the CURRENT champion before evolving. Spend happens only inside
    # this explicit run; the /baton:go path never re-scores. --
    $staleActives = @($pool.candidates | Where-Object {
        ($_.status -eq 'candidate') -and ($null -eq $_.offline.minibatch.win_rate_vs_champion)
    })
    if (@($staleActives).Count -gt 0) {
        $champRescoreRec = @($pool.candidates | Where-Object { $_.id -eq $pool.champion })[0]
        $champRescoreText = Get-Content -Raw (Join-Path $PoolDir ([string]$champRescoreRec.file))
        foreach ($sc in $staleActives) {
            $scText = $null
            try { $scText = Get-Content -Raw -LiteralPath (Join-Path $PoolDir ([string]$sc.file)) -ErrorAction Stop } catch { $scText = $null }
            if ([string]::IsNullOrEmpty($scText)) {
                [Console]::Error.WriteLine("optimize-prompt: re-score skipped for $($sc.id) — candidate file unreadable.")
                continue
            }
            $mb = Invoke-MinibatchEval -CandidatePrompt $scText -ReferencePrompt $champRescoreText `
                -Runs @($runs) -PlanDispatcher $PlanDispatcher -JudgeDispatcher $JudgeDispatcher
            $sc.offline.minibatch = @{
                wins = $mb.wins; losses = $mb.losses; ties = $mb.ties
                win_rate_vs_champion = $mb.win_rate; examples = @($mb.examples)
            }
            [void]$rescored.Add(@{ id = [string]$sc.id; win_rate = $mb.win_rate })
            $wrNote = if ($null -ne $mb.win_rate) { $mb.win_rate } else { 'no evidence (stays stale)' }
            Write-Host "Re-scored $($sc.id) vs champion $($pool.champion): $wrNote"
        }
        Save-PromptPool -Pool $pool -PoolDir $PoolDir
    }
```

(c) Add `rescored = @($rescored)` to BOTH success returns (the `-Apply` return and the final proposed-candidate return at the end of the function) — each currently returns `@{ success = $true; applied = …; candidate_path = …; reason = …; generations = @($genRecords) }`; append `; rescored = @($rescored)` inside each hashtable.

Note: a re-score whose minibatch yields `win_rate = $null` (all ties/dropped) still overwrites the minibatch (fresh wins/losses/ties bookkeeping) and appears in `rescored` with `win_rate = $null` — but the candidate's `win_rate_vs_champion` stays null, i.e. honestly stale and still excluded from selection. Do not fabricate a score.

- [ ] **Step 4: Run tests to verify they pass**

Run: `pwsh -NoProfile -File scripts/test-optimize-prompt-lib.ps1`
Expected: `ALL CHECKS PASS`, exit 0 (O/M/E series incl. E16/E17).

- [ ] **Step 5: Regression**

Run: `pwsh -NoProfile -File scripts/test-prompt-pool-lib.ps1` and `pwsh -NoProfile -File scripts/test-conductor-lib.ps1`
Expected: exit 0 on both.

- [ ] **Step 6: Commit**

```bash
git add scripts/optimize-prompt-lib.ps1 scripts/test-optimize-prompt-lib.ps1
git commit -m "feat(optimize): re-score stale candidates vs current champion at evolution start (v1.7.1)"
```

---

### Task 3: `Complete-Run` — assigned-challenger verdict + one-shot PROMOTE nudge

**Files:**
- Modify: `scripts/conductor-lib.ps1`
- Test: `scripts/test-conductor-lib.ps1`

**Interfaces:**
- Consumes: Task 1's `Get-ShadowVerdict -ChallengerId` and `promote_recommended_at` field; `shadow.json`'s existing `challenger_id` key (written by `Invoke-PlanPhase` since v1.7.0).
- Produces: no new interfaces — behavior changes only, inside the existing fail-open accrual block.

- [ ] **Step 1: Write the failing tests**

In `scripts/test-conductor-lib.ps1`, append after the `SB10` Check (still INSIDE the `try { … } finally { $env:BATON_HOME = $sbPrevHome }` block):

```powershell
        # SB11: promote nudge is one-shot — second winning run emits no duplicate.
        $sbC7 = @($sbAfter7.candidates | Where-Object { $_.id -eq 'p002' })[0]
        Check 'SB11a first promote run stamps promote_recommended_at' (([string]$sbC7.promote_recommended_at) -match 'Z$')
        $sbRun8 = Initialize-RunDir -RunId 'go-sb-8' -Root (Join-Path $sbHome 'runs')
        @{ variant_id = 'p001'; role = 'champion'; challenger_id = 'p002'; assigned = '2026-07-03T00:00:00Z' } |
            ConvertTo-Json | Set-Content -LiteralPath (Join-Path $sbRun8 'shadow.json') -Encoding utf8NoBOM
        [void](Complete-Run -RunDir $sbRun8 -Plan @{ run_id = 'go-sb-8'; goal = 'g'; budget_cap = $null; tasks = @() } -Gate $sbGate -TaskCosts @(@{ id = 't1'; worker = 'stub'; cost = 0.10 }))
        $sbEv8 = Get-Content -LiteralPath (Join-Path $sbRun8 'events.jsonl') | ForEach-Object { $_ | ConvertFrom-Json }
        Check 'SB11b second winning run: no duplicate promote event' (@($sbEv8 | Where-Object { ($_.kind -eq 'shadow') -and ($_.message -match 'promote via') }).Count -eq 0)

        # SB12: verdict evaluates the ASSIGNED challenger, not a newer higher-wr rival.
        $sbP5 = @{ schema = 1; champion = 'p001'; candidates = @() }
        $sbX1 = New-PoolCandidateRecord -Id 'p001' -Parent $null -Origin 'seed' -Status 'champion' -PromptTokens 12
        $sbX1.offline.minibatch.win_rate_vs_champion = 0.5
        $sbX1.live = @{ runs = 5; accept = 4; polish = 1; reject = 0; realized_cost_usd = 1.0; rework_cost_usd = 0.2 }
        $sbX2 = New-PoolCandidateRecord -Id 'p002' -Parent 'p001' -Origin 'mutation' -Status 'candidate' -PromptTokens 10
        $sbX2.offline.minibatch.win_rate_vs_champion = 0.6
        $sbX2.live = @{ runs = 4; accept = 1; polish = 2; reject = 1; realized_cost_usd = 3.0; rework_cost_usd = 2.5 }
        $sbX3 = New-PoolCandidateRecord -Id 'p003' -Parent 'p001' -Origin 'mutation' -Status 'candidate' -PromptTokens 9
        $sbX3.offline.minibatch.win_rate_vs_champion = 0.9   # newer, shinier — but NOT the one that ran
        $sbP5.candidates = @($sbX1, $sbX2, $sbX3)
        Save-PromptPool -Pool $sbP5 -PoolDir $sbPoolDir
        $sbRun9 = Initialize-RunDir -RunId 'go-sb-9' -Root (Join-Path $sbHome 'runs')
        @{ variant_id = 'p002'; role = 'challenger'; challenger_id = 'p002'; assigned = '2026-07-03T00:00:00Z' } |
            ConvertTo-Json | Set-Content -LiteralPath (Join-Path $sbRun9 'shadow.json') -Encoding utf8NoBOM
        [void](Complete-Run -RunDir $sbRun9 -Plan @{ run_id = 'go-sb-9'; goal = 'g'; budget_cap = $null; tasks = @() } -Gate $sbGateRej -TaskCosts @(@{ id = 't1'; worker = 'stub'; cost = 0.10 }))
        $sbAfter9 = (Get-PromptPool -PoolDir $sbPoolDir).pool
        $sbX2b = @($sbAfter9.candidates | Where-Object { $_.id -eq 'p002' })[0]
        $sbX3b = @($sbAfter9.candidates | Where-Object { $_.id -eq 'p003' })[0]
        Check 'SB12 assigned challenger judged (auto-retired), rival untouched' `
            (($sbX2b.status -eq 'retired') -and ($sbX2b.retired_by -eq 'p001') -and ($sbX3b.status -eq 'candidate'))
```

(SB12 math: after the reject run, p002 has gated 5 = 1 accept + 2 polish + 2 reject, cost/accept 3.10 vs champion 0.25 → retire. With the OLD behavior `Select-ShadowChallenger` would pick p003 — 0 gated → `insufficient` → nothing retired, so SB12 fails red before the fix.)

- [ ] **Step 2: Run to verify the new checks fail**

Run: `pwsh -NoProfile -File scripts/test-conductor-lib.ps1`
Expected: SB11b FAILS (duplicate promote event emitted) and SB12 FAILS (p002 not retired).

- [ ] **Step 3: Implement**

In `scripts/conductor-lib.ps1`, inside `Complete-Run`'s Slice B accrual `try` block, two edits:

(a) Pin the verdict to the assigned challenger. Replace:

```powershell
                [void](Add-LiveRunResult @accrue)
                $sv = Get-ShadowVerdict -Pool $livePool
```

with:

```powershell
                [void](Add-LiveRunResult @accrue)
                # v1.7.1: judge the challenger this run was ASSIGNED (shadow.json),
                # not whoever selection would pick now — a mid-run evolution must
                # not misattribute the verdict.
                $sv = Get-ShadowVerdict -Pool $livePool -ChallengerId ([string]$assign.challenger_id)
```

(b) Make the promote nudge one-shot. Replace:

```powershell
                    } else {
                        Add-RunEvent -RunDir $RunDir -EventObj (New-RunEvent -Kind 'shadow' -Message "challenger $($sv.challenger_id) is winning in dollars (cost_per_accept $challCpa vs $champCpa) — promote via /baton:optimize-prompt --apply")
                    }
```

with:

```powershell
                    } else {
                        # v1.7.1: one nudge per candidate — the --pool report still
                        # shows the live verdict on every invocation.
                        $challNudge = @($livePool.candidates | Where-Object { $_.id -eq $sv.challenger_id })[0]
                        if ($null -eq $challNudge.promote_recommended_at) {
                            Add-RunEvent -RunDir $RunDir -EventObj (New-RunEvent -Kind 'shadow' -Message "challenger $($sv.challenger_id) is winning in dollars (cost_per_accept $challCpa vs $champCpa) — promote via /baton:optimize-prompt --apply")
                            $challNudge.promote_recommended_at = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
                        }
                    }
```

(Old pool records may lack the `promote_recommended_at` key entirely — hashtable access of a missing key reads `$null`, which is exactly the "not yet nudged" semantic, and the assignment adds the key. The existing `Save-PromptPool` at the end of the block persists the stamp.)

- [ ] **Step 4: Run tests to verify they pass**

Run: `pwsh -NoProfile -File scripts/test-conductor-lib.ps1`
Expected: `ALL CHECKS PASS`, exit 0 (incl. SB1–SB12).

- [ ] **Step 5: Regression**

Run: `pwsh -NoProfile -File scripts/test-prompt-pool-lib.ps1` and `pwsh -NoProfile -File scripts/test-optimize-prompt-lib.ps1`
Expected: exit 0 on both.

- [ ] **Step 6: Commit**

```bash
git add scripts/conductor-lib.ps1 scripts/test-conductor-lib.ps1
git commit -m "feat(conductor): assigned-challenger verdict + one-shot promote nudge (v1.7.1)"
```

---

### Task 4: CLI surfacing, docs, version bump

**Files:**
- Modify: `scripts/fleet-optimize-prompt.ps1`
- Modify: `commands/optimize-prompt.md`
- Modify: `docs/COMMANDS.md`
- Modify: `.claude-plugin/plugin.json`

**Interfaces:**
- Consumes: Task 2's `rescored` result field; Task 1's `promote_recommended_at`; existing `Get-ShadowVerdict` (no `-ChallengerId` here — the CLI report shows the live pool's view by design).
- Produces: user-facing output only.

- [ ] **Step 1: Runner — print re-scores**

In `scripts/fleet-optimize-prompt.ps1`, in the final non-`$Json` branch, insert BEFORE the `foreach ($g in @($res.generations)) {` loop:

```powershell
    foreach ($r in @($res.rescored | Where-Object { $null -ne $_ })) {
        $wrOut = if ($null -ne $r.win_rate) { $r.win_rate } else { 'no evidence' }
        Write-Host ("rescored {0} vs champion: {1}" -f $r.id, $wrOut)
    }
```

- [ ] **Step 2: Runner — promote footer shows the nudge stamp**

In the `-Pool` report's verdict `switch`, replace the `'promote'` case:

```powershell
        'promote'       { Write-Host ("Shadow verdict: PROMOTE $($sv.challenger_id) — cost/accept {0} vs champion {1}. Run --apply to deploy." -f $(if ($null -ne $sv.challenger_cpa) { '{0:n4}' -f [double]$sv.challenger_cpa } else { 'n/a' }), $(if ($null -ne $sv.champion_cpa) { '{0:n4}' -f [double]$sv.champion_cpa } else { 'n/a (0 accepts)' })) }
```

with:

```powershell
        'promote'       {
            $pcRec = @($loaded.pool.candidates | Where-Object { $_.id -eq $sv.challenger_id })[0]
            $pcNote = if ($pcRec -and $pcRec.promote_recommended_at) { " (recommended $($pcRec.promote_recommended_at))" } else { '' }
            Write-Host (("Shadow verdict: PROMOTE $($sv.challenger_id) — cost/accept {0} vs champion {1}. Run --apply to deploy." -f $(if ($null -ne $sv.challenger_cpa) { '{0:n4}' -f [double]$sv.challenger_cpa } else { 'n/a' }), $(if ($null -ne $sv.champion_cpa) { '{0:n4}' -f [double]$sv.champion_cpa } else { 'n/a (0 accepts)' })) + $pcNote)
        }
```

- [ ] **Step 3: Smoke the runner**

Run: `pwsh -NoProfile -Command "$env:BATON_HOME = Join-Path ([IO.Path]::GetTempPath()) ('v171-' + [guid]::NewGuid().ToString('N')); & ./scripts/fleet-optimize-prompt.ps1 -Pool; exit $LASTEXITCODE"`
Expected: `Pool unavailable: absent` on stderr, exit 2 (parse/behavior sanity on an empty temp home; the real pool is never touched).

- [ ] **Step 4: Docs**

`commands/optimize-prompt.md` — in the "Live shadow A/B" section, append this paragraph:

> **Stale re-scoring (v1.7.1).** After `--apply` swaps the champion, other candidates' offline win rates were measured against the old champion and are nulled as stale. The next evolution run re-scores every stale active against the CURRENT champion (same minibatch evaluator, printed as `rescored pNNN vs champion: <rate>`) before evolving — so a champion swap never permanently hides the rest of the pool. Re-scoring spends model calls only inside explicit `/baton:optimize-prompt` runs, never on `/baton:go`.

And append this sentence to the paragraph describing the promote recommendation:

> The PROMOTE nudge is logged once per candidate (`promote_recommended_at` stamps the pool record); `--pool` always shows the current verdict.

`docs/COMMANDS.md` — in the `/baton:optimize-prompt` section's Shadow A/B bullet, append the sentence:

> Evolution runs re-score stale candidates (post-champion-swap) against the current champion before evolving; run verdicts are attributed to the challenger assigned at plan time.

- [ ] **Step 5: Version bump**

`.claude-plugin/plugin.json`: `"version": "1.7.0"` → `"version": "1.7.1-rc.1"`.

- [ ] **Step 6: Full test gate**

Run all suites:
`pwsh -NoProfile -File scripts/test-prompt-pool-lib.ps1`, `scripts/test-optimize-prompt-lib.ps1`, `scripts/test-conductor-lib.ps1`, `scripts/test-bootstrap.ps1`, `scripts/test-baton-home.ps1`
Expected: exit 0 on all five.

- [ ] **Step 7: Commit**

```bash
git add scripts/fleet-optimize-prompt.ps1 commands/optimize-prompt.md docs/COMMANDS.md .claude-plugin/plugin.json
git commit -m "feat(cli): surface re-scores + one-shot promote stamp; docs; bump 1.7.1-rc.1"
```

---

## Execution handoff

Subagent-driven per the standing default. Model split (Kevin's ladder): Tasks 1 and 4 are transcription-grade (complete code above) → **haiku**; Tasks 2 and 3 splice into complex control flow → **sonnet**; final whole-branch review → **opus**. Branch `feature/optimizer-v171-hardening`; PR to master; the merge word is Kevin's.
